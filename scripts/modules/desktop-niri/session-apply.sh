#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

niri_session_step() {
    local label=$1 status
    shift

    if "$@"; then
        return 0
    else
        status=$?
    fi
    [ "$status" -ne 0 ] || status=1
    error "Niri session apply step failed: $label (status $status)."
    return "$status"
}

niri_apply_dotfiles_and_session() {
    local user=$1 dotfiles_script=$2 status

    if niri_session_step 'Shorin state ownership' \
        ensure_niri_shorin_state_ownership "$user"; then
        :
    else
        status=$?
        [ "$status" -ne 0 ] || status=1
        error "Shorin state ownership repair failed (status $status)."
        return "$status"
    fi
    if bash "$dotfiles_script"; then
        log 'Dotfiles apply completed; continuing with session configuration.'
    else
        status=$?
        [ "$status" -ne 0 ] || status=1
        error "Dotfiles apply failed (status $status); session apply was not attempted."
        return "$status"
    fi
    if ensure_niri_session_config "$user"; then
        log 'Session configuration apply completed.'
        return 0
    else
        status=$?
        [ "$status" -ne 0 ] || status=1
        error "Session configuration apply failed (status $status); stopping before hardware and autologin."
        return "$status"
    fi
}

ensure_niri_managed_config_files() {
    local user=$1 config_backup binds_backup config_mode binds_mode group status=0
    local file backup index
    local -a quickshell_files=() quickshell_backups=() quickshell_modes=()

    [ -f "$NIRI_CONFIG_FILE" ] && [ -f "$NIRI_BINDS_FILE" ] || return 1
    group=$(id -gn "$user")
    chown "$user:$group" "$NIRI_CONFIG_FILE" "$NIRI_BINDS_FILE"
    chmod u+r "$NIRI_CONFIG_FILE" "$NIRI_BINDS_FILE"
    niri_session_files_accessible "$user" || return 1
    config_backup=$(mktemp)
    binds_backup=$(mktemp)
    cp "$NIRI_CONFIG_FILE" "$config_backup"
    cp "$NIRI_BINDS_FILE" "$binds_backup"
    config_mode=$(stat -c '%a' "$NIRI_CONFIG_FILE")
    binds_mode=$(stat -c '%a' "$NIRI_BINDS_FILE")
    while IFS= read -r -d '' file; do
        niri_file_has_legacy_swww "$file" || continue
        backup=$(mktemp)
        cp "$file" "$backup"
        quickshell_files+=("$file")
        quickshell_backups+=("$backup")
        quickshell_modes+=("$(stat -c '%a' "$file")")
    done < <(find "$NIRI_QUICKSHELL_DIR" -type f -print0)

    [ "$status" -ne 0 ] ||
        niri_session_step 'Fedora session compatibility' \
            ensure_niri_fedora_session_compatibility_files "$user" || status=$?
    [ "$status" -ne 0 ] ||
        niri_session_step 'QuickShell startup' \
            ensure_niri_quickshell_startup "$NIRI_CONFIG_FILE" "$user" || status=$?
    [ "$status" -ne 0 ] ||
        niri_session_step 'optional startup' ensure_niri_optional_startup \
            "$user" || status=$?
    [ "$status" -ne 0 ] ||
        niri_session_step 'Fcitx5 startup' ensure_niri_fcitx5_startup \
            "$NIRI_CONFIG_FILE" "$user" || status=$?
    [ "$status" -ne 0 ] ||
        niri_session_step 'PATH convergence' ensure_niri_path "$user" || status=$?
    [ "$status" -ne 0 ] ||
        niri_session_step 'Fedora LSFG session environment' \
            ensure_niri_fedora_lsfg_session "$user" || status=$?
    [ "$status" -ne 0 ] ||
        niri_session_step 'wallpaper backend' \
            ensure_niri_wallpaper_backend "$user" || status=$?
    [ "$status" -ne 0 ] ||
        niri_session_step 'Niri bindings' ensure_niri_bindings "$user" || status=$?
    [ "$status" -ne 0 ] ||
        niri_session_step 'Niri config validation' niri_config_valid \
            "$user" || status=$?
    if [ "$status" -ne 0 ]; then
        error 'Niri session apply failed; restoring the session transaction.'
        install_if_changed "$config_backup" "$NIRI_CONFIG_FILE" "$config_mode" || status=1
        install_if_changed "$binds_backup" "$NIRI_BINDS_FILE" "$binds_mode" || status=1
        chown "$user:$group" "$NIRI_CONFIG_FILE" "$NIRI_BINDS_FILE"
        for index in "${!quickshell_files[@]}"; do
            install_if_changed "${quickshell_backups[$index]}" \
                "${quickshell_files[$index]}" "${quickshell_modes[$index]}" || status=1
            chown "$user:$group" "${quickshell_files[$index]}"
        done
        rm -f "$config_backup" "$binds_backup"
        rm -f "${quickshell_backups[@]}"
        ensure_niri_shorin_state_ownership "$user" ||
            error 'Unable to restore Shorin state ownership after session rollback.'
        return "$status"
    fi
    rm -f "$config_backup" "$binds_backup"
    rm -f "${quickshell_backups[@]}"
}

ensure_niri_session_config() {
    local user=$1 status=0

    if ! niri_desktop_txn_begin; then
        error 'Unable to start the Niri session transaction.'
        return 1
    fi
    niri_desktop_txn_snapshot "$NIRI_CONFIG_FILE" || status=1
    niri_desktop_txn_snapshot "$NIRI_BINDS_FILE" || status=1
    niri_desktop_txn_snapshot "$NIRI_QUICKSHELL_DIR" || status=1
    niri_desktop_txn_snapshot "$NIRI_DESKTOP_STATE_DIR" || status=1
    niri_desktop_txn_snapshot "$NIRI_WAYPAPER_CONFIG_FILE" || status=1
    niri_desktop_txn_snapshot "$NIRI_FISH_GUARD_FILE" || status=1
    niri_desktop_txn_snapshot "$NIRI_FISH_CONFIG_FILE" || status=1
    niri_desktop_txn_snapshot "$NIRI_FISH_RUSTUP_FILE" || status=1
    niri_desktop_txn_snapshot "$NIRI_FISH_LOCAL_ENV_FILE" || status=1
    niri_desktop_txn_snapshot "$NIRI_BASH_PROFILE" || status=1
    niri_desktop_txn_snapshot "$NIRI_LEGACY_UNIT" || status=1
    niri_desktop_txn_snapshot "$NIRI_LEGACY_UNIT_LINK" || status=1
    niri_desktop_txn_snapshot "$NIRI_FEDORA_WALLPAPER_SESSION_FILE" || status=1
    niri_desktop_txn_snapshot "$NIRI_FEDORA_AWWW_QUERY_WRAPPER_FILE" || status=1
    if platform_is_fedora; then
        niri_desktop_txn_snapshot \
            "$(niri_fedora_lsfg_environment_file_path)" || status=1
        niri_desktop_txn_snapshot \
            "$(niri_fedora_lsfg_wrapper_path)" || status=1
        niri_desktop_txn_snapshot \
            "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_AUTOSTART_FILE" || status=1
        niri_desktop_txn_snapshot \
            "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_MASK_FILE" || status=1
        niri_desktop_txn_snapshot \
            "$NIRI_FEDORA_DRKONQI_MASK_FILE" || status=1
        niri_desktop_txn_snapshot \
            "$NIRI_FEDORA_MAKO_MASK_FILE" || status=1
    fi
    if [ "$status" -ne 0 ]; then
        error 'Unable to snapshot all Niri session targets; session apply was not attempted.'
        niri_desktop_txn_finish 1
        return 1
    fi

    if ! niri_session_step 'managed Niri config files' \
        ensure_niri_managed_config_files "$user"; then
        niri_desktop_txn_finish 1
        ensure_niri_shorin_state_ownership "$user" ||
            error 'Unable to restore Shorin state ownership after session rollback.'
        return 1
    fi
    if ! niri_session_step 'Waypaper backend' ensure_niri_waypaper_backend \
        "$user" ||
        ! niri_session_step 'Fish environment sources' ensure_niri_fish_sources \
            "$user" ||
        ! niri_session_step 'Fish config' ensure_niri_fish_config "$user" ||
        ! niri_session_step 'TTY session profile' ensure_niri_bash_profile \
            "$user"; then
        error 'Niri session post-processing failed; restoring the session transaction.'
        niri_desktop_txn_finish 1
        ensure_niri_shorin_state_ownership "$user" ||
            error 'Unable to restore Shorin state ownership after session rollback.'
        return 1
    fi
    if platform_is_fedora &&
        ! niri_session_step 'Xwayland Video Bridge shutdown' \
            ensure_niri_fedora_xwayland_videobridge_autostart "$user"; then
        error 'Xwayland Video Bridge shutdown failed; restoring the session transaction.'
        niri_desktop_txn_finish 1
        niri_fedora_xwayland_videobridge_reload_user_manager "$user" ||
            error 'Unable to reload the target user manager after Xwayland Video Bridge rollback.'
        ensure_niri_shorin_state_ownership "$user" ||
            error 'Unable to restore Shorin state ownership after session rollback.'
        return 1
    fi
    if platform_is_fedora &&
        ! niri_session_step 'DrKonqi coredump launcher mask' \
            ensure_niri_fedora_drkonqi "$user"; then
        error 'DrKonqi coredump launcher mask failed; restoring the session transaction.'
        niri_desktop_txn_finish 1
        niri_fedora_drkonqi_reload_user_manager "$user" ||
            error 'Unable to reload the target user manager after DrKonqi rollback.'
        ensure_niri_shorin_state_ownership "$user" ||
            error 'Unable to restore Shorin state ownership after session rollback.'
        return 1
    fi
    if platform_is_fedora &&
        ! niri_session_step 'Mako notification daemon shutdown' \
            ensure_niri_fedora_mako "$user"; then
        error 'Mako notification daemon shutdown failed; restoring the session transaction.'
        niri_desktop_txn_finish 1
        niri_fedora_mako_reload_user_manager "$user" ||
            error 'Unable to reload the target user manager after Mako rollback.'
        ensure_niri_shorin_state_ownership "$user" ||
            error 'Unable to restore Shorin state ownership after session rollback.'
        return 1
    fi
    niri_desktop_txn_finish 0
}
