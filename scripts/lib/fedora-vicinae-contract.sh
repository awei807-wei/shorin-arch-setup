#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]:-unknown}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Fedora's verified provider installs Vicinae as ~/.local/bin/vicinae.AppImage.
# Niri's config and bindings may originate from an upstream checkout that still
# invokes the Arch-style `vicinae`; convert only the exact server/toggle lines.

fedora_vicinae_niri_config_file() {
    printf '%s\n' "${1:-$HOME_DIR}/.config/niri/config.kdl"
}

fedora_vicinae_niri_binds_file() {
    printf '%s\n' "${1:-$HOME_DIR}/.config/niri/binds.kdl"
}

fedora_vicinae_niri_file_satisfied() {
    local file=$1 mode=$2 temporary status=0

    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
        return 0
    fi
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    temporary=$(mktemp)
    if ! awk -v mode="$mode" \
        -f "$SHORIN_ROOT/scripts/lib/fedora-vicinae-compatibility.awk" \
        "$file" > "$temporary"; then
        rm -f "$temporary"
        return 2
    fi
    cmp -s "$temporary" "$file" || status=$?
    rm -f "$temporary"
    [ "$status" -eq 0 ]
}

fedora_vicinae_niri_file_convert() {
    local file=$1 mode=$2 user=$3 group temporary file_mode

    require_writable_mode || return
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
        return 0
    fi
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    file_mode=$(stat -c '%a' "$file") || return 1
    group=$(id -gn "$user") || return 1
    temporary=$(mktemp "$(dirname "$file")/.vicinae.XXXXXX")
    if ! awk -v mode="$mode" \
        -f "$SHORIN_ROOT/scripts/lib/fedora-vicinae-compatibility.awk" \
        "$file" > "$temporary"; then
        rm -f "$temporary"
        return 2
    fi
    if ! install_if_changed "$temporary" "$file" "$file_mode"; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
    chown "$user:$group" "$file" || return 1
    fedora_vicinae_niri_file_satisfied "$file" "$mode"
}

fedora_vicinae_niri_command_contract_satisfied() {
    local home=${1:-${HOME_DIR:-}}

    [ -n "$home" ] || return 1
    fedora_vicinae_niri_file_satisfied \
        "$(fedora_vicinae_niri_config_file "$home")" server || return
    fedora_vicinae_niri_file_satisfied \
        "$(fedora_vicinae_niri_binds_file "$home")" toggle
}

fedora_vicinae_niri_command_contract_apply() {
    local user=$1 home=$2

    fedora_vicinae_niri_file_convert \
        "$(fedora_vicinae_niri_config_file "$home")" server "$user" || return
    fedora_vicinae_niri_file_convert \
        "$(fedora_vicinae_niri_binds_file "$home")" toggle "$user"
}
