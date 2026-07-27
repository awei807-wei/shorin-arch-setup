#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

niri_file_has_legacy_swww() {
    grep -Iq . "$1" &&
        grep -Eq '(^|[^[:alnum:]_-])swww(-daemon)?([^[:alnum:]_-]|$)' "$1"
}

niri_tree_has_legacy_swww() {
    local root=$1 file

    [ -d "$root" ] || return 1
    while IFS= read -r -d '' file; do
        niri_file_has_legacy_swww "$file" && return 0
    done < <(find "$root" -type f -print0)
    return 1
}

niri_wallpaper_backend_satisfied() {
    [ -s "$NIRI_CONFIG_FILE" ] &&
        ! niri_file_has_legacy_swww "$NIRI_CONFIG_FILE"
}

niri_quickshell_wallpaper_backend_satisfied() {
    [ -d "$NIRI_QUICKSHELL_DIR" ] &&
        ! niri_tree_has_legacy_swww "$NIRI_QUICKSHELL_DIR"
}

niri_waypaper_backend_satisfied() {
    [ -s "$NIRI_WAYPAPER_CONFIG_FILE" ] || return 1
    awk '
        /^[[:space:]]*\[Settings\][[:space:]]*$/ {
            settings++
            in_settings=1
            next
        }
        /^[[:space:]]*\[/ {
            in_settings=0
            next
        }
        in_settings && /^[[:space:]]*backend[[:space:]]*=/ {
            value=$0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            backend++
            if (value == "awww") matches++
        }
        END { exit !(settings == 1 && backend == 1 && matches == 1) }
    ' "$NIRI_WAYPAPER_CONFIG_FILE"
}

ensure_awww_in_file() {
    local file=$1 user=$2 temporary mode group

    niri_file_has_legacy_swww "$file" || return 0
    temporary=$(mktemp)
    sed -E \
        -e 's/(^|[^[:alnum:]_-])swww-daemon([^[:alnum:]_-]|$)/\1awww-daemon\2/g' \
        -e 's/(^|[^[:alnum:]_-])swww([^[:alnum:]_-]|$)/\1awww\2/g' \
        "$file" > "$temporary"
    mode=$(stat -c '%a' "$file")
    group=$(id -gn "$user")
    install_if_changed "$temporary" "$file" "$mode"
    rm -f "$temporary"
    chown "$user:$group" "$file"
}

ensure_niri_wallpaper_backend() {
    local user=$1 file

    ensure_awww_in_file "$NIRI_CONFIG_FILE" "$user"
    [ -d "$NIRI_QUICKSHELL_DIR" ] || return 1
    while IFS= read -r -d '' file; do
        grep -Iq . "$file" || continue
        ensure_awww_in_file "$file" "$user"
    done < <(find "$NIRI_QUICKSHELL_DIR" -type f -print0)
    niri_wallpaper_backend_satisfied &&
        niri_quickshell_wallpaper_backend_satisfied
}

ensure_niri_waypaper_backend() {
    local user=$1 temporary mode group

    niri_waypaper_backend_satisfied && return 0
    [ -s "$NIRI_WAYPAPER_CONFIG_FILE" ] || return 1
    temporary=$(mktemp)
    if ! awk '
        /^[[:space:]]*\[Settings\][[:space:]]*$/ {
            settings++
            in_settings=1
            backend_seen=0
            print
            next
        }
        /^[[:space:]]*\[/ {
            if (in_settings && !backend_seen) print "backend = awww"
            in_settings=0
            print
            next
        }
        in_settings && /^[[:space:]]*backend[[:space:]]*=/ {
            if (!backend_seen) print "backend = awww"
            backend_seen=1
            next
        }
        { print }
        END {
            if (!settings) exit 2
            if (in_settings && !backend_seen) print "backend = awww"
        }
    ' "$NIRI_WAYPAPER_CONFIG_FILE" > "$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    mode=$(stat -c '%a' "$NIRI_WAYPAPER_CONFIG_FILE")
    group=$(id -gn "$user")
    install_if_changed "$temporary" "$NIRI_WAYPAPER_CONFIG_FILE" "$mode"
    rm -f "$temporary"
    chown "$user:$group" "$NIRI_WAYPAPER_CONFIG_FILE"
    niri_waypaper_backend_satisfied
}
