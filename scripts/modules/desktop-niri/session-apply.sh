#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ensure_niri_session_config() {
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

    ensure_niri_quickshell_startup "$NIRI_CONFIG_FILE" "$user" || status=$?
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

    ensure_niri_fish_sources "$user"
    ensure_niri_bash_profile "$user"
}
