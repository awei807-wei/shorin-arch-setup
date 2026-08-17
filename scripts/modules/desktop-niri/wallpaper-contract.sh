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

# awww prints the active wallpaper with an output/display prefix, for example:
#   : eDP-1: ... currently displaying: image: /absolute/path
# Do not accept a generic "image:" line: other awww query output and stale
# swww-compatible parsers can otherwise select the wrong field.  In
# particular, a colour query has a `currently displaying: color:` payload and
# must produce no path.
niri_awww_query_path_from_output() {
    awk '
        {
            sub(/\r$/, "")
            # The leading colon and output name are part of awww query output;
            # requiring them keeps arbitrary log lines from being accepted.
            if ($0 !~ /^[[:space:]]*:[[:space:]]*[^:]+:.*currently displaying:[[:space:]]*image:[[:space:]]*/) {
                next
            }
            value=$0
            sub(/^[[:space:]]*:[[:space:]]*[^:]+:.*currently displaying:[[:space:]]*image:[[:space:]]*/, "", value)
            sub(/[[:space:]]+$/, "", value)
            if (length(value) > 0) {
                print value
                exit
            }
        }
    '
}

niri_active_swww_in_file() {
    local file=$1

    [ -f "$file" ] || return 1
    awk '
        /^[[:space:]]*(#|\/\/)/ { next }
        /(^|[^[:alnum:]_-])swww(-daemon)?([^[:alnum:]_-]|$)/ { found=1 }
        END { exit !found }
    ' "$file"
}

niri_active_wallpaper_backend_in_file() {
    local file=$1 backend=$2

    [ -f "$file" ] || return 1
    awk -v backend="$backend" '
        /^[[:space:]]*(#|\/\/)/ { next }
        {
            pattern = "(^|[^[:alnum:]_-])" backend "(-daemon)?([^[:alnum:]_-]|$)"
            if ($0 ~ pattern) found=1
        }
        END { exit !found }
    ' "$file"
}

niri_file_has_wallpaper_backend() {
    local file=$1 backend=${2:-$(niri_wallpaper_backend_name)}

    niri_active_wallpaper_backend_in_file "$file" "$backend"
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
        niri_active_swww_in_file "$file" && return 0
    done < <(find "$root" -type f -print0)
    return 1
}

niri_wallpaper_scripts_satisfied() {
    local script

    for script in \
        "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" \
        "$HOME_DIR/.config/scripts/matugen-select-type.sh" \
        "$HOME_DIR/.config/scripts/niri_set_overview_blur_dark_bg.sh" \
        "$HOME_DIR/.config/scripts/niri_auto_blur_bg.sh" \
        "$NIRI_MATUGEN_CONFIG_FILE"; do
        [ -f "$script" ] && [ ! -L "$script" ] || return 1
        ! niri_active_swww_in_file "$script" || return 1
    done
    grep -Fq 'command = "awww"' "$NIRI_MATUGEN_CONFIG_FILE" || return 1
}

niri_transform_wallpaper_file_in_place() {
    local file=$1 temporary mode

    platform_is_fedora || return 0
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    case "$file" in
        */quickshell/lockscreen/shell.qml|*/lockscreen/shell.qml|*/scripts/matugen-select-type.sh|\
        */scripts/niri_set_overview_blur_dark_bg.sh|*/scripts/niri_auto_blur_bg.sh|\
        */matugen/config.toml) ;;
        *) return 0 ;;
    esac
    temporary=$(mktemp)
    awk -f "$SHORIN_ROOT/scripts/modules/desktop-niri/fedora-wallpaper-compatibility.awk" \
        "$file" > "$temporary"
    if cmp -s "$temporary" "$file"; then
        rm -f "$temporary"
        return 0
    fi
    mode=$(stat -c '%a' "$file")
    install -m "$mode" "$temporary" "$file"
    rm -f "$temporary"
}

niri_deploy_wallpaper_compat_file() {
    local source=$1 destination=$2 user=$3 temporary mode

    [ -f "$source" ] && [ ! -L "$source" ] || return 1
    mode=$(stat -c '%a' "$source")
    if ! platform_is_fedora; then
        install_if_changed "$source" "$destination" "$mode" || return
        chown "$user:$(id -gn "$user")" "$destination"
        return 0
    fi
    temporary=$(mktemp)
    awk -f "$SHORIN_ROOT/scripts/modules/desktop-niri/fedora-wallpaper-compatibility.awk" \
        "$source" > "$temporary"
    install_if_changed "$temporary" "$destination" "$mode"
    rm -f "$temporary"
    chown "$user:$(id -gn "$user")" "$destination"
}

niri_transform_wallpaper_tree() {
    local root=$1 file

    [ -d "$root" ] || return 1
    while IFS= read -r -d '' file; do
        niri_transform_wallpaper_file_in_place "$file" || return
    done < <(find "$root" -type f -print0)
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
    [ -f "$NIRI_WAYPAPER_CONFIG_FILE" ] &&
        [ ! -L "$NIRI_WAYPAPER_CONFIG_FILE" ] &&
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
    local user=$1 file quickshell_before_digest quickshell_after_digest
    local registered_digest

    ensure_wallpaper_backend_in_file "$NIRI_CONFIG_FILE" "$user"
    [ -d "$NIRI_QUICKSHELL_DIR" ] || return 1

    # Fedora's QuickShell wallpaper compatibility is applied to the staged
    # checkout before the live tree is replaced.  Never mutate an active
    # Fedora tree during session convergence: a post-deployment edit must
    # remain drift until the source deployment repairs it.
    if platform_is_fedora; then
        niri_quickshell_deployment_state_satisfied || return 1
        niri_wallpaper_backend_satisfied &&
            niri_quickshell_wallpaper_backend_satisfied
        return
    fi

    # Arch retains the historical one-time swww -> awww migration, but only
    # when the live tree still matches the digest recorded before that
    # controlled transformation.  Arbitrary edits must fail rather than be
    # re-registered as a new source state.
    quickshell_before_digest=$(niri_quickshell_tree_digest "$NIRI_QUICKSHELL_DIR") ||
        return 1
    registered_digest=$(niri_quickshell_state_value digest) || return 1
    [ "$quickshell_before_digest" = "$registered_digest" ] || return 1
    while IFS= read -r -d '' file; do
        grep -Iq . "$file" || continue
        ensure_wallpaper_backend_in_file "$file" "$user"
    done < <(find "$NIRI_QUICKSHELL_DIR" -type f -print0)
    niri_wallpaper_backend_satisfied || return 1
    niri_quickshell_wallpaper_backend_satisfied || return 1
    quickshell_after_digest=$(niri_quickshell_tree_digest "$NIRI_QUICKSHELL_DIR") ||
        return 1
    if [ "$quickshell_after_digest" != "$quickshell_before_digest" ]; then
        niri_quickshell_refresh_state_digest "$quickshell_before_digest" ||
            return 1
    fi
}

ensure_niri_waypaper_backend() {
    local user=$1 temporary mode group backend

    backend=$(niri_wallpaper_backend_name)

    niri_waypaper_backend_satisfied && return 0
    [ -f "$NIRI_WAYPAPER_CONFIG_FILE" ] &&
        [ ! -L "$NIRI_WAYPAPER_CONFIG_FILE" ] &&
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
