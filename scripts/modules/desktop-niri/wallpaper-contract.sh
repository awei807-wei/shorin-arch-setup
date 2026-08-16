#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

niri_wallpaper_backend_name() {
    # awww is the upstream project name on every supported distribution.
    # Older profiles may still contain swww; the migration helper below
    # rewrites those legacy command references to awww.
    printf '%s\n' awww
}

niri_file_has_wallpaper_backend() {
    local file=$1 backend=${2:-$(niri_wallpaper_backend_name)}

    grep -Iq . "$file" &&
        grep -Eq "(^|[^[:alnum:]_-])${backend}(-daemon)?([^[:alnum:]_-]|$)" \
            "$file"
}

# Historical callers use this name while collecting files for rollback.  The
# actual meaning is "contains the backend opposite to this platform's target".
niri_file_has_legacy_swww() {
    niri_file_has_wallpaper_backend "$1" swww
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
        ! niri_file_has_legacy_swww "$NIRI_CONFIG_FILE" &&
        niri_file_has_wallpaper_backend "$NIRI_CONFIG_FILE"
}

niri_quickshell_wallpaper_backend_satisfied() {
    [ -d "$NIRI_QUICKSHELL_DIR" ] &&
        ! niri_tree_has_legacy_swww "$NIRI_QUICKSHELL_DIR" &&
        niri_tree_has_wallpaper_backend "$NIRI_QUICKSHELL_DIR"
}

niri_tree_has_wallpaper_backend() {
    local root=$1 file

    [ -d "$root" ] || return 1
    while IFS= read -r -d '' file; do
        niri_file_has_wallpaper_backend "$file" && return 0
    done < <(find "$root" -type f -print0)
    return 1
}

niri_waypaper_backend_satisfied() {
    [ -s "$NIRI_WAYPAPER_CONFIG_FILE" ] || return 1
    awk -v expected_backend="$(niri_wallpaper_backend_name)" '
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
            if (value == expected_backend) matches++
        }
        END { exit !(settings == 1 && backend == 1 && matches == 1) }
    ' "$NIRI_WAYPAPER_CONFIG_FILE"
}

ensure_wallpaper_backend_in_file() {
    local file=$1 user=$2 temporary mode group backend old_backend

    backend=$(niri_wallpaper_backend_name)
    old_backend=swww
    niri_file_has_wallpaper_backend "$file" "$old_backend" || return 0
    temporary=$(mktemp)
    sed -E \
        -e "s/(^|[^[:alnum:]_-])${old_backend}-daemon([^[:alnum:]_-]|$)/\\1${backend}-daemon\\2/g" \
        -e "s/(^|[^[:alnum:]_-])${old_backend}([^[:alnum:]_-]|$)/\\1${backend}\\2/g" \
        "$file" > "$temporary"
    mode=$(stat -c '%a' "$file")
    group=$(id -gn "$user")
    install_if_changed "$temporary" "$file" "$mode"
    rm -f "$temporary"
    chown "$user:$group" "$file"
}

ensure_awww_in_file() {
    ensure_wallpaper_backend_in_file "$@"
}

ensure_niri_wallpaper_backend() {
    local user=$1 file

    ensure_wallpaper_backend_in_file "$NIRI_CONFIG_FILE" "$user"
    [ -d "$NIRI_QUICKSHELL_DIR" ] || return 1
    while IFS= read -r -d '' file; do
        grep -Iq . "$file" || continue
        ensure_wallpaper_backend_in_file "$file" "$user"
    done < <(find "$NIRI_QUICKSHELL_DIR" -type f -print0)
    niri_wallpaper_backend_satisfied &&
        niri_quickshell_wallpaper_backend_satisfied
}

ensure_niri_waypaper_backend() {
    local user=$1 temporary mode group backend

    backend=$(niri_wallpaper_backend_name)

    niri_waypaper_backend_satisfied && return 0
    [ -s "$NIRI_WAYPAPER_CONFIG_FILE" ] || return 1
    temporary=$(mktemp)
    if ! awk -v expected_backend="$backend" '
        /^[[:space:]]*\[Settings\][[:space:]]*$/ {
            settings++
            in_settings=1
            backend_seen=0
            print
            next
        }
        /^[[:space:]]*\[/ {
            if (in_settings && !backend_seen) print "backend = " expected_backend
            in_settings=0
            print
            next
        }
        in_settings && /^[[:space:]]*backend[[:space:]]*=/ {
            if (!backend_seen) print "backend = " expected_backend
            backend_seen=1
            next
        }
        { print }
        END {
            if (!settings) exit 2
            if (in_settings && !backend_seen) print "backend = " expected_backend
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
