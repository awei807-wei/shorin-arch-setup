#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]:-unknown}" "$LINENO" "$BASH_COMMAND" >&2' ERR

niri_quickshell_tree_contract() {
    local root=$1

    [ -d "$root" ] && [ ! -L "$root" ] || return 1
    [ -f "$root/shell.qml" ] && [ -s "$root/shell.qml" ] &&
        [ ! -L "$root/shell.qml" ] || return 1
    [ -f "$root/lockscreen/shell.qml" ] &&
        [ -s "$root/lockscreen/shell.qml" ] &&
        [ ! -L "$root/lockscreen/shell.qml" ] || return 1
    [ -d "$root/config" ] && [ ! -L "$root/config" ] || return 1
    [ -f "$root/config/qmldir" ] && [ -s "$root/config/qmldir" ] &&
        [ ! -L "$root/config/qmldir" ] || return 1
    [ -L "$root/lockscreen/config" ] &&
        [ "$(readlink "$root/lockscreen/config")" = ../config ] || return 1
    [ -d "$root/lockscreen/config" ] || return 1
    [ -f "$root/scripts/lockscreen.sh" ] &&
        [ -s "$root/scripts/lockscreen.sh" ] &&
        [ ! -L "$root/scripts/lockscreen.sh" ] &&
        [ -x "$root/scripts/lockscreen.sh" ] || return 1
    grep -Eq '^[[:space:]]*import[[:space:]]+(QtQuick|Quickshell)' \
        "$root/shell.qml" "$root/lockscreen/shell.qml" || return 1
}

niri_quickshell_active_swww_present() {
    local root=$1 file

    [ -d "$root" ] || return 1
    while IFS= read -r -d '' file; do
        awk '
            /^[[:space:]]*(#|\/\/)/ { next }
            /(^|[^[:alnum:]_-])swww(-daemon)?([^[:alnum:]_-]|$)/ {
                found=1
            }
            END { exit !found }
        ' "$file" && return 0
    done < <(find "$root" -type f -print0)
    return 1
}

niri_quickshell_static_contract() {
    local root=$1

    niri_quickshell_tree_contract "$root" || return 1
    ! niri_quickshell_active_swww_present "$root"
}

niri_quickshell_tree_digest() {
    local root=$1 path relative type manifest

    [ -d "$root" ] || return 1
    manifest=$(mktemp)
    while IFS= read -r -d '' path; do
        relative=${path#"$root"/}
        if [ -L "$path" ]; then
            printf 'l\t%s\t%s\n' "$relative" "$(readlink "$path")" >> "$manifest"
        elif [ -d "$path" ]; then
            printf 'd\t%s\t%s\n' "$relative" "$(stat -c '%a' "$path")" >> "$manifest"
        elif [ -f "$path" ]; then
            type=$(stat -c '%a' "$path")
            printf 'f\t%s\t%s\t' "$relative" "$type" >> "$manifest"
            sha256sum "$path" | awk '{ print $1 }' >> "$manifest"
        else
            printf '?\t%s\n' "$relative" >> "$manifest"
        fi
    done < <(find "$root" -mindepth 1 -print0 | sort -z)
    sha256sum "$manifest" | awk '{ print $1 }'
    rm -f "$manifest"
}

niri_quickshell_state_value() {
    local key=$1

    [ -f "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ] || return 1
    awk -F= -v wanted="$key" '$1 == wanted { print substr($0, length($1) + 2); exit }' \
        "$NIRI_QUICKSHELL_SOURCE_STATE_FILE"
}

niri_quickshell_deployment_state_satisfied() {
    local digest platform commit expected_platform actual_digest

    niri_quickshell_static_contract "$NIRI_QUICKSHELL_DIR" || return 1
    [ "$(stat -c '%U' "$NIRI_QUICKSHELL_DIR")" = "$TARGET_USER" ] || return 1
    [ -f "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ] &&
        [ ! -L "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ] || return 1
    [ "$(stat -c '%U' "$NIRI_QUICKSHELL_SOURCE_STATE_FILE")" = "$TARGET_USER" ] ||
        return 1
    commit=$(niri_quickshell_state_value commit)
    platform=$(niri_quickshell_state_value platform)
    digest=$(niri_quickshell_state_value digest)
    [ -n "$commit" ] && [ -n "$digest" ] || return 1
    if platform_is_fedora; then expected_platform=fedora; else expected_platform=arch; fi
    [ "$platform" = "$expected_platform" ] || return 1
    actual_digest=$(niri_quickshell_tree_digest "$NIRI_QUICKSHELL_DIR") || return 1
    [ "$actual_digest" = "$digest" ]
}
