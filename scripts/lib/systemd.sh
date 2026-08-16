#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# System and user systemd desired-state primitives.

if ! declare -F require_writable_mode >/dev/null 2>&1; then
    require_writable_mode() {
        local mode=${SHORIN_MODE:-${MODE:-install}}
        case "$mode" in
            audit|verify)
                printf 'ERROR: write operation is not allowed in %s mode\n' "$mode" >&2
                return 1
                ;;
        esac
    }
fi

service_is_enabled() {
    local status

    systemctl is-enabled --quiet "$1" && return 0
    status=$?
    case "$status" in
        1|2|3|4|5|6|7|8|9|10) return 1 ;;
        *) return "$status" ;;
    esac
}

service_is_active() {
    local status

    systemctl is-active --quiet "$1" && return 0
    status=$?
    case "$status" in
        1|2|3|4|5|6|7|8|9|10) return 1 ;;
        *) return "$status" ;;
    esac
}

ensure_service_enabled() {
    require_writable_mode || return
    local unit=$1 status=0

    service_is_enabled "$unit" || status=$?
    case "$status" in
        0) ;;
        1) systemctl enable "$unit" || return ;;
        *) return "$status" ;;
    esac
    service_is_enabled "$unit"
}

ensure_service_started() {
    require_writable_mode || return
    local unit=$1 status=0

    ensure_service_enabled "$unit" || return
    service_is_active "$unit" || status=$?
    case "$status" in
        0) ;;
        1) systemctl start "$unit" || return ;;
        *) return "$status" ;;
    esac
    service_is_active "$unit"
}

user_unit_is_enabled() {
    local user=$1 unit=$2 target=${3:-default.target}
    local home=${4:-} unit_file link

    if [ -z "$home" ]; then
        home=$(getent passwd "$user" | cut -d: -f6)
    fi
    [ -n "$home" ] || return 1
    unit_file="$home/.config/systemd/user/$unit"
    link="$home/.config/systemd/user/${target}.wants/$unit"
    [ -s "$unit_file" ] && [ -L "$link" ] &&
        [ "$(readlink "$link")" = "../$unit" ]
}

user_unit_bus_is_available() {
    local user=$1
    local uid

    uid=$(id -u "$user")
    [ -S "/run/user/$uid/bus" ]
}

ensure_user_unit_enabled() {
    require_writable_mode || return
    local user=$1 unit=$2 target=${3:-default.target}
    local home=${4:-}
    local uid group unit_dir wants_dir runtime_dir

    if [ -z "$home" ]; then
        home=$(getent passwd "$user" | cut -d: -f6)
    fi
    [ -n "$home" ] || return 1

    uid=$(id -u "$user")
    group=$(id -gn "$user")
    unit_dir="$home/.config/systemd/user"
    wants_dir="$unit_dir/${target}.wants"
    runtime_dir="/run/user/$uid"

    install -d -o "$user" -g "$group" "$wants_dir"
    runuser -u "$user" -- ln -sfn "../$unit" "$wants_dir/$unit"

    if [ -S "$runtime_dir/bus" ]; then
        runuser -u "$user" -- env \
            XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
            systemctl --user daemon-reload
        runuser -u "$user" -- env \
            XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
            systemctl --user start "$unit"
    else
        if declare -F log >/dev/null 2>&1; then
            log "$unit enabled for $user; start is pending until the next login."
        else
            printf '%s enabled for %s; start is pending until the next login.\n' \
                "$unit" "$user"
        fi
        if ! declare -p USER_UNIT_PENDING >/dev/null 2>&1; then
            declare -g -a USER_UNIT_PENDING=()
        fi
        USER_UNIT_PENDING+=("$user:$unit")
    fi
}

# Compatibility query names used by existing modules.
verify_service() {
    service_is_enabled "$1"
}

verify_user_unit() {
    user_unit_is_enabled "$@"
}
