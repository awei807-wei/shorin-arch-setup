#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]:-unknown}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# KDE's DrKonqi coredump launcher is not part of the coredump capture path.
# Fedora Niri keeps systemd-coredump/coredumpctl available, but masks only the
# user socket that would otherwise launch a GUI crash reporter for every
# desktop crash.

niri_fedora_drkonqi_mask_satisfied() {
    local user=${1:-$TARGET_USER}

    platform_is_fedora || return 0
    [ -L "$NIRI_FEDORA_DRKONQI_MASK_FILE" ] || return 1
    [ "$(readlink "$NIRI_FEDORA_DRKONQI_MASK_FILE")" = /dev/null ] ||
        return 1
    [ "$(stat -c '%U' "$NIRI_FEDORA_DRKONQI_MASK_FILE")" = "$user" ]
}

niri_fedora_drkonqi_user_systemctl() {
    local user=$1
    shift

    niri_fedora_user_systemctl "$user" "$@"
}

niri_fedora_drkonqi_reload_user_manager() {
    local user=$1 status=0

    if niri_user_bus_is_available "$user"; then
        niri_fedora_drkonqi_user_systemctl "$user" daemon-reload
    else
        status=$?
        [ "$status" -eq 1 ] || return "$status"
    fi
}

niri_fedora_drkonqi_reset_failed() {
    local user=$1 output status

    if output=$(niri_fedora_drkonqi_user_systemctl "$user" \
        reset-failed "$NIRI_FEDORA_DRKONQI_UNIT" 2>&1); then
        return 0
    else
        status=$?
    fi
    case "$status" in
        1|5)
            printf '%s\n' "$output" |
                grep -Eiq '(^|[[:space:]])Unit[[:space:]]+[^[:space:]]+[[:space:]]+not loaded([.:]|$)' &&
                return 0
            ;;
    esac
    return "$status"
}

niri_fedora_drkonqi_stop() {
    local user=$1 output status

    if output=$(niri_fedora_drkonqi_user_systemctl "$user" \
        stop "$NIRI_FEDORA_DRKONQI_UNIT" 2>&1); then
        return 0
    else
        status=$?
    fi
    case "$status" in
        1|3|4|5)
            printf '%s\n' "$output" |
                grep -Eiq '(not loaded|not running|inactive|could not be found)' &&
                return 0
            ;;
    esac
    return "$status"
}

niri_fedora_drkonqi_unit_inactive() {
    local user=$1 status=0

    if niri_fedora_drkonqi_user_systemctl "$user" \
        is-active --quiet "$NIRI_FEDORA_DRKONQI_UNIT"; then
        return 1
    else
        status=$?
    fi
    case "$status" in
        1|3|4) return 0 ;;
        *) return "$status" ;;
    esac
}

niri_fedora_drkonqi_service_satisfied() {
    local user=${1:-$TARGET_USER} status=0

    niri_fedora_drkonqi_mask_satisfied "$user" || return 1
    if niri_user_bus_is_available "$user"; then
        :
    else
        status=$?
        [ "$status" -eq 1 ] || return "$status"
        return 0
    fi
    niri_fedora_drkonqi_unit_inactive "$user"
}

niri_fedora_drkonqi_satisfied() {
    local user=${1:-$TARGET_USER}

    platform_is_fedora || return 0
    niri_fedora_drkonqi_service_satisfied "$user"
}

ensure_niri_fedora_drkonqi() {
    local user=$1 group mask_file bus_available=0 status=0

    require_writable_mode || return
    platform_is_fedora || return 0
    group=$(id -gn "$user") || return 1
    mask_file=$NIRI_FEDORA_DRKONQI_MASK_FILE
    niri_path_is_safe_no_symlink "$(dirname "$mask_file")" || return 1
    install -d -o "$user" -g "$group" "$(dirname "$mask_file")" || return 1

    if [ -e "$mask_file" ] || [ -L "$mask_file" ]; then
        [ -L "$mask_file" ] || return 1
        [ "$(readlink "$mask_file")" = /dev/null ] || return 1
        if [ "$(stat -c '%U' "$mask_file")" != "$user" ]; then
            chown -h "$user:$group" "$mask_file" || return 1
        fi
    else
        niri_run_as_user "$user" ln -s /dev/null "$mask_file" || return
    fi

    if niri_user_bus_is_available "$user"; then
        bus_available=1
    else
        status=$?
        [ "$status" -eq 1 ] || return "$status"
    fi
    if [ "$bus_available" -eq 1 ]; then
        # The mask must be visible before the user manager is stopped.  Keep
        # these as separate, auditable operations; do not use `stop --now`.
        niri_fedora_drkonqi_reload_user_manager "$user" || return
        niri_fedora_drkonqi_stop "$user" || return
        niri_fedora_drkonqi_reset_failed "$user" || return
    fi
    niri_fedora_drkonqi_service_satisfied "$user"
}
