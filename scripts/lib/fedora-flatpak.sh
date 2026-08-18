#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

fedora_flatpak_desktop_export_satisfied() {
    local app=$1 home=${2:-${HOME_DIR:-}} export_dir candidate
    local -a export_dirs=()

    export_dir=${FEDORA_FLATPAK_EXPORT_DIR:-}
    [ -n "$export_dir" ] && export_dirs+=("$export_dir")
    export_dirs+=(
        /var/lib/flatpak/exports/share/applications
        /usr/local/share/flatpak/exports/share/applications
        "$home/.local/share/flatpak/exports/share/applications"
    )
    for export_dir in "${export_dirs[@]}"; do
        candidate="$export_dir/$app.desktop"
        [ -s "$candidate" ] && return 0
    done
    return 1
}

fedora_flatpak_user_query() {
    local app=$1 user=${2:-${TARGET_USER:-}} home=${3:-${HOME_DIR:-}}
    local uid=0

    if [ -n "$user" ]; then
        uid=$(id -u "$user" 2>/dev/null) || return 2
    fi

    if [ "$(id -u)" -eq 0 ] && [ -n "$user" ] && [ "$uid" -ne 0 ] &&
        command -v runuser >/dev/null 2>&1; then
        runuser -u "$user" -- env HOME="$home" \
            XDG_CONFIG_HOME="$home/.config" flatpak info --user "$app"
    else
        HOME="$home" XDG_CONFIG_HOME="$home/.config" \
            flatpak info --user "$app"
    fi
}

fedora_flatpak_user_override_query() {
    local app=$1 user=${2:-${TARGET_USER:-}} home=${3:-${HOME_DIR:-}}
    local uid=0

    if [ -n "$user" ]; then
        uid=$(id -u "$user" 2>/dev/null) || return 2
    fi

    if [ "$(id -u)" -eq 0 ] && [ -n "$user" ] && [ "$uid" -ne 0 ] &&
        command -v runuser >/dev/null 2>&1; then
        runuser -u "$user" -- env HOME="$home" \
            XDG_CONFIG_HOME="$home/.config" flatpak override --user --show "$app"
    else
        HOME="$home" XDG_CONFIG_HOME="$home/.config" \
            flatpak override --user --show "$app"
    fi
}

fedora_flatpak_user_override_apply() {
    local app=$1 user=${2:-${TARGET_USER:-}} home=${3:-${HOME_DIR:-}}
    local uid=0
    shift 3 || true

    if [ -n "$user" ]; then
        uid=$(id -u "$user" 2>/dev/null) || return 2
    fi

    if [ "$(id -u)" -eq 0 ] && [ -n "$user" ] && [ "$uid" -ne 0 ] &&
        command -v runuser >/dev/null 2>&1; then
        runuser -u "$user" -- env HOME="$home" \
            XDG_CONFIG_HOME="$home/.config" flatpak override --user "$@" "$app"
    else
        HOME="$home" XDG_CONFIG_HOME="$home/.config" \
            flatpak override --user "$@" "$app"
    fi
}

fedora_flatpak_app_scope() {
    local app=$1 user=${2:-${TARGET_USER:-}} home=${3:-${HOME_DIR:-}}
    local system_status=0 user_status=0

    command -v flatpak >/dev/null 2>&1 || return 2
    flatpak info --system "$app" >/dev/null 2>&1 || system_status=$?
    fedora_flatpak_user_query "$app" "$user" "$home" >/dev/null 2>&1 ||
        user_status=$?
    if [ "$system_status" -gt 1 ] || [ "$user_status" -gt 1 ]; then
        return 2
    fi
    if [ "$system_status" -eq 0 ]; then
        printf '%s\n' system
        return 0
    fi
    if [ "$user_status" -eq 0 ]; then
        printf '%s\n' user
        return 0
    fi
    return 1
}

fedora_flatpak_present() {
    fedora_flatpak_app_scope "$1" "${2:-${TARGET_USER:-}}" \
        "${3:-${HOME_DIR:-}}" >/dev/null
}

fedora_ensure_flatpak_target() {
    local app=$1 user=${2:-${TARGET_USER:-}} home=${3:-${HOME_DIR:-}}
    local status=0

    if fedora_flatpak_present "$app" "$user" "$home"; then
        return 0
    else
        status=$?
    fi
    [ "$status" -eq 1 ] || return "$status"
    ensure_flatpak "$app"
}

fedora_flatpak_override_satisfied() {
    local app=$1 user=${2:-${TARGET_USER:-}} home=${3:-${HOME_DIR:-}}
    local scope status=0

    scope=$(fedora_flatpak_app_scope "$app" "$user" "$home") || status=$?
    [ "$status" -eq 0 ] || return "$status"
    if [ "$scope" = system ]; then
        flatpak override --system --show "$app" 2>/dev/null |
            grep -Fqx 'LANG=zh_CN.UTF-8'
    else
        fedora_flatpak_user_override_query "$app" "$user" "$home" 2>/dev/null |
            grep -Fqx 'LANG=zh_CN.UTF-8'
    fi
}
