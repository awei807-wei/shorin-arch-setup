#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]:-unknown}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# LSFG-VK is an implicit Vulkan layer.  Fedora's graphical session keeps it
# disabled by default because unrelated desktop programs can load it and
# crash during Vulkan initialisation.  Games opt in through the managed
# wrapper below.

niri_fedora_lsfg_environment_file_path() {
    printf '%s\n' "${NIRI_FEDORA_LSFG_ENV_FILE:-$HOME_DIR/.config/environment.d/90-shorin-lsfg.conf}"
}

niri_fedora_lsfg_wrapper_path() {
    printf '%s\n' "${NIRI_FEDORA_LSFG_WRAPPER_FILE:-$NIRI_LOCAL_BIN/shorin-lsfg}"
}

niri_fedora_lsfg_niri_environment_satisfied() {
    local file=${NIRI_CONFIG_FILE:-}

    platform_is_fedora || return 0
    [ -s "$file" ] && [ ! -L "$file" ] || return 1
    awk '
        /^[[:space:]]*environment[[:space:]]*\{/ {
            environment_count++
            in_environment=1
            next
        }
        in_environment && /^[[:space:]]*}/ {
            in_environment=0
            next
        }
        in_environment && /^[[:space:]]*DISABLE_LSFG[[:space:]]+"1"[[:space:]]*$/ {
            match_count++
            next
        }
        in_environment && /^[[:space:]]*DISABLE_LSFG([[:space:]]|$)/ {
            invalid=1
        }
        END {
            exit !(environment_count == 1 && match_count == 1 &&
                !invalid && !in_environment)
        }
    ' "$file"
}

niri_fedora_lsfg_environment_file_contract() {
    printf '%s\n' 'DISABLE_LSFG=1'
}

niri_fedora_lsfg_environment_file_satisfied() {
    local file user=${TARGET_USER:-}

    platform_is_fedora || return 0
    file=$(niri_fedora_lsfg_environment_file_path)
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    [ "$(stat -c '%U' "$file" 2>/dev/null)" = "$user" ] || return 1
    [ "$(stat -c '%a' "$file" 2>/dev/null)" = 644 ] || return 1
    [ "$(< "$file")" = "$(niri_fedora_lsfg_environment_file_contract)" ]
}

niri_fedora_lsfg_wrapper_contract() {
    cat <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$#" -eq 0 ]; then
    printf 'Usage: %s COMMAND [ARG ...]\n' "${0##*/}" >&2
    exit 2
fi

# The parent Fedora Niri session exports DISABLE_LSFG=1.  Unset it only for
# this explicitly requested game command so the implicit layer can activate.
exec env -u DISABLE_LSFG "$@"
EOF
}

niri_fedora_lsfg_wrapper_satisfied() {
    local file user=${TARGET_USER:-}

    platform_is_fedora || return 0
    file=$(niri_fedora_lsfg_wrapper_path)
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    [ "$(stat -c '%U' "$file" 2>/dev/null)" = "$user" ] || return 1
    [ "$(stat -c '%a' "$file" 2>/dev/null)" = 755 ] || return 1
    [ "$(< "$file")" = "$(niri_fedora_lsfg_wrapper_contract)" ]
}

niri_fedora_lsfg_user_manager_satisfied() {
    local user=$1 uid runtime output

    platform_is_fedora || return 0
    # An offline check has no user bus.  The environment.d contract is still
    # authoritative and will be consumed when the user manager starts.
    niri_user_bus_is_available "$user" || return 0
    uid=$(id -u "$user") || return 2
    runtime="${SHORIN_USER_RUNTIME_ROOT:-/run/user}/$uid"
    output=$(niri_run_as_user "$user" env XDG_RUNTIME_DIR="$runtime" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
        systemctl --user show-environment 2>/dev/null) || return 2
    grep -Fxq 'DISABLE_LSFG=1' <<< "$output"
}

niri_fedora_lsfg_session_satisfied() {
    local user=${1:-$TARGET_USER}

    platform_is_fedora || return 0
    niri_fedora_lsfg_niri_environment_satisfied || return 1
    niri_fedora_lsfg_environment_file_satisfied || return 1
    niri_fedora_lsfg_wrapper_satisfied || return 1
    niri_fedora_lsfg_user_manager_satisfied "$user"
}

niri_fedora_lsfg_install_niri_environment() {
    local user=$1 file=${NIRI_CONFIG_FILE:-} temporary mode group

    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    temporary=$(mktemp)
    awk '
        function desired() {
            print "    DISABLE_LSFG \"1\""
            lsfg_seen=1
        }
        /^[[:space:]]*environment[[:space:]]*\{/ {
            environment_seen++
            in_environment=1
            print
            next
        }
        in_environment && /^[[:space:]]*DISABLE_LSFG([[:space:]]|$)/ {
            if (!lsfg_seen) desired()
            next
        }
        in_environment && /^[[:space:]]*}/ {
            if (!lsfg_seen) desired()
            in_environment=0
            print
            next
        }
        { print }
        END {
            if (!environment_seen) {
                print ""
                print "environment {"
                desired()
                print "}"
            }
        }
    ' "$file" > "$temporary"
    mode=$(stat -c '%a' "$file")
    group=$(id -gn "$user") || {
        rm -f "$temporary"
        return 1
    }
    if ! install_if_changed "$temporary" "$file" "$mode"; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
    chown "$user:$group" "$file"
    niri_fedora_lsfg_niri_environment_satisfied
}

niri_fedora_lsfg_install_environment_file() {
    local user=$1 group temporary file

    file=$(niri_fedora_lsfg_environment_file_path)
    niri_path_is_safe_no_symlink "$file" || return 1
    group=$(id -gn "$user") || return 1
    install -d -o "$user" -g "$group" "$(dirname "$file")" || return 1
    [ ! -L "$file" ] || return 1
    temporary=$(mktemp)
    niri_fedora_lsfg_environment_file_contract > "$temporary"
    if ! install_if_changed "$temporary" "$file" 644; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
    chown "$user:$group" "$file"
    niri_fedora_lsfg_environment_file_satisfied
}

niri_fedora_lsfg_install_wrapper() {
    local user=$1 group temporary file

    file=$(niri_fedora_lsfg_wrapper_path)
    niri_path_is_safe_no_symlink "$file" || return 1
    group=$(id -gn "$user") || return 1
    install -d -o "$user" -g "$group" "$(dirname "$file")" || return 1
    [ ! -L "$file" ] || return 1
    temporary=$(mktemp)
    niri_fedora_lsfg_wrapper_contract > "$temporary"
    if ! install_if_changed "$temporary" "$file" 755; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
    chown "$user:$group" "$file"
    niri_fedora_lsfg_wrapper_satisfied
}

niri_fedora_lsfg_refresh_user_manager() {
    local user=$1 uid runtime

    niri_user_bus_is_available "$user" || return 0
    uid=$(id -u "$user") || return 2
    runtime="${SHORIN_USER_RUNTIME_ROOT:-/run/user}/$uid"
    niri_run_as_user "$user" env XDG_RUNTIME_DIR="$runtime" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
        systemctl --user set-environment DISABLE_LSFG=1
}

ensure_niri_fedora_lsfg_session() {
    local user=$1

    require_writable_mode || return
    platform_is_fedora || return 0
    niri_fedora_lsfg_install_niri_environment "$user" || return
    niri_fedora_lsfg_install_environment_file "$user" || return
    niri_fedora_lsfg_install_wrapper "$user" || return
    niri_fedora_lsfg_refresh_user_manager "$user" || return
    niri_fedora_lsfg_session_satisfied "$user"
}
