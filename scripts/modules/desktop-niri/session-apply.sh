#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

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

    ensure_niri_fedora_session_compatibility "$user" || status=$?
    [ "$status" -ne 0 ] || ensure_niri_quickshell_startup "$NIRI_CONFIG_FILE" "$user" || status=$?
    [ "$status" -ne 0 ] || ensure_niri_optional_startup "$user" || status=$?
    [ "$status" -ne 0 ] || ensure_niri_fcitx5_startup \
        "$NIRI_CONFIG_FILE" "$user" || status=$?
    [ "$status" -ne 0 ] || ensure_niri_path "$user" || status=$?
    [ "$status" -ne 0 ] || ensure_niri_wallpaper_backend "$user" || status=$?
    [ "$status" -ne 0 ] || ensure_niri_bindings "$user" || status=$?
    [ "$status" -ne 0 ] || niri_config_valid "$user" || status=$?
    if [ "$status" -ne 0 ]; then
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
        return "$status"
    fi
    rm -f "$config_backup" "$binds_backup"
    rm -f "${quickshell_backups[@]}"
}

ensure_niri_session_config() {
    local user=$1 status=0

    niri_desktop_txn_begin || return 1
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
    if [ "$status" -ne 0 ]; then
        niri_desktop_txn_finish 1
        return 1
    fi

    if ! ensure_niri_managed_config_files "$user"; then
        niri_desktop_txn_finish 1
        return 1
    fi
    if ! ensure_niri_waypaper_backend "$user" ||
        ! ensure_niri_fish_sources "$user" ||
        ! ensure_niri_fish_config "$user" ||
        ! ensure_niri_bash_profile "$user"; then
        niri_desktop_txn_finish 1
        return 1
    fi
    niri_desktop_txn_finish 0
}
