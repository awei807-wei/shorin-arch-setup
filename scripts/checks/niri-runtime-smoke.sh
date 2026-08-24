#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

NIRI_RUNTIME_LOGINCTL=${NIRI_RUNTIME_LOGINCTL:-loginctl}
NIRI_RUNTIME_SYSTEMCTL=${NIRI_RUNTIME_SYSTEMCTL:-systemctl}
NIRI_RUNTIME_NIRI=${NIRI_RUNTIME_NIRI:-niri}
NIRI_RUNTIME_JOURNALCTL=${NIRI_RUNTIME_JOURNALCTL:-journalctl}
NIRI_RUNTIME_RUNUSER=${NIRI_RUNTIME_RUNUSER:-runuser}
NIRI_RUNTIME_JQ=${NIRI_RUNTIME_JQ:-jq}
NIRI_RUNTIME_TIMEOUT_COMMAND=${NIRI_RUNTIME_TIMEOUT_COMMAND:-timeout}
NIRI_RUNTIME_TIMEOUT=${NIRI_RUNTIME_TIMEOUT:-5s}
NIRI_RUNTIME_USER_ROOT=${NIRI_RUNTIME_USER_ROOT:-/run/user}
NIRI_RUNTIME_RENDER_ROOT=${NIRI_RUNTIME_RENDER_ROOT:-/dev/dri}
NIRI_RUNTIME_PROC_ROOT=${NIRI_RUNTIME_PROC_ROOT:-/proc}

niri_runtime_usage() {
    cat <<'EOF'
Usage: bash scripts/checks/niri-runtime-smoke.sh [--user USER]

Validate an already-active local Niri seat session without starting one.

Exit status:
  0  Active Niri session is render/output ready.
  1  Active Niri session exists but its runtime contract failed.
  2  No active local Niri seat session exists (for example, at the greeter).
  64 Invalid command line or target user.
EOF
}

niri_runtime_fail() {
    printf 'FAIL: %s\n' "$1" >&2
}

niri_runtime_session_value() {
    "$NIRI_RUNTIME_LOGINCTL" show-session "$1" \
        -p "$2" --value 2>/dev/null
}

niri_runtime_find_session() {
    local user_uid=$1 listing id uid active state remote seat type desktop class
    local service vt

    listing=$(LC_ALL=C "$NIRI_RUNTIME_LOGINCTL" list-sessions \
        --no-legend --no-pager 2>/dev/null) || return 2
    while read -r id _; do
        [ -n "${id:-}" ] || continue
        uid=$(niri_runtime_session_value "$id" User) || continue
        [ "$uid" = "$user_uid" ] || continue
        active=$(niri_runtime_session_value "$id" Active) || continue
        state=$(niri_runtime_session_value "$id" State) || continue
        remote=$(niri_runtime_session_value "$id" Remote) || continue
        seat=$(niri_runtime_session_value "$id" Seat) || continue
        type=$(niri_runtime_session_value "$id" Type) || continue
        desktop=$(niri_runtime_session_value "$id" Desktop) || continue
        class=$(niri_runtime_session_value "$id" Class) || continue
        service=$(niri_runtime_session_value "$id" Service) || continue
        vt=$(niri_runtime_session_value "$id" VTNr) || continue
        [ "$active" = yes ] && [ "$state" = active ] &&
            [ "$remote" = no ] && [ -n "$seat" ] &&
            [ "$type" = wayland ] && [ "${desktop,,}" = niri ] &&
            [ "$class" = user ] && [ -n "$service" ] || continue
        NIRI_RUNTIME_SESSION_ID=$id
        NIRI_RUNTIME_SESSION_SEAT=$seat
        NIRI_RUNTIME_SESSION_SERVICE=$service
        NIRI_RUNTIME_SESSION_VT=$vt
        export NIRI_RUNTIME_SESSION_ID NIRI_RUNTIME_SESSION_SEAT
        export NIRI_RUNTIME_SESSION_SERVICE NIRI_RUNTIME_SESSION_VT
        return 0
    done <<< "$listing"
    return 1
}

niri_runtime_as_user() {
    local current_uid

    current_uid=$(id -u) || return 1
    if [ "$current_uid" -eq "$NIRI_RUNTIME_TARGET_UID" ]; then
        env XDG_RUNTIME_DIR="$NIRI_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$NIRI_RUNTIME_DIR/bus" \
            "$@"
    elif [ "$current_uid" -eq 0 ]; then
        "$NIRI_RUNTIME_RUNUSER" -u "$NIRI_RUNTIME_TARGET_USER" -- \
            env XDG_RUNTIME_DIR="$NIRI_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$NIRI_RUNTIME_DIR/bus" \
            "$@"
    else
        return 126
    fi
}

niri_runtime_render_evidence() {
    local pid=$1 journal render_node devices compact_devices

    devices=$(find "$NIRI_RUNTIME_PROC_ROOT/$pid/fd" -maxdepth 1 -type l \
        -printf '%l\n' 2>/dev/null |
        awk -v root="$NIRI_RUNTIME_RENDER_ROOT/" '
            index($0, root) == 1 {
                name=substr($0, length(root) + 1)
                if (name ~ /^(card|renderD)[0-9]+$/) print
            }
        ' |
        sort -u || true)
    [ -n "$devices" ] || return 1
    compact_devices=$(printf '%s\n' "$devices" | paste -sd, -)

    if command -v "$NIRI_RUNTIME_JOURNALCTL" >/dev/null 2>&1; then
        journal=$(niri_runtime_as_user "$NIRI_RUNTIME_JOURNALCTL" --user -b \
            -u niri.service "_PID=$pid" --no-pager -o cat 2>/dev/null || true)
        render_node=$(printf '%s\n' "$journal" | sed -n \
            's/.*using as the render node: "\([^"]*\)".*/\1/p' | tail -n 1)
        if [ -n "$render_node" ]; then
            case "$render_node" in
                "$NIRI_RUNTIME_RENDER_ROOT"/renderD[0-9]*) ;;
                *) return 1 ;;
            esac
            [ -e "$render_node" ] || return 1
            printf 'render-node=%s drm-fds=%s\n' \
                "$render_node" "$compact_devices"
            return 0
        fi
    fi
    printf 'drm-fds=%s\n' "$compact_devices"
}

niri_runtime_outputs_valid() {
    local outputs=$1
    local active_mode_definition='def active_mode:
        (.current_mode | type) == "number" and
        .current_mode >= 0 and
        .current_mode == (.current_mode | floor);'

    if ! printf '%s' "$outputs" |
        "$NIRI_RUNTIME_JQ" -e . >/dev/null 2>&1; then
        niri_runtime_fail 'Niri outputs response is malformed JSON'
        return 1
    fi
    if ! printf '%s' "$outputs" |
        "$NIRI_RUNTIME_JQ" -e 'type == "object"' >/dev/null; then
        niri_runtime_fail 'Niri outputs JSON must be an object'
        return 1
    fi
    if ! printf '%s' "$outputs" |
        "$NIRI_RUNTIME_JQ" -e 'length > 0' >/dev/null; then
        niri_runtime_fail 'Niri reports no connected outputs (outputs object is empty)'
        return 1
    fi
    if ! printf '%s' "$outputs" |
        "$NIRI_RUNTIME_JQ" -e \
        "$active_mode_definition any(.[]?; active_mode)" >/dev/null; then
        niri_runtime_fail \
            'no Niri output has a non-negative integer current_mode'
        return 1
    fi
    if ! printf '%s' "$outputs" | "$NIRI_RUNTIME_JQ" -e \
        "$active_mode_definition
        any(.[]?; active_mode and (.logical | type) == \"object\")" \
        >/dev/null; then
        niri_runtime_fail \
            'no active Niri output has a logical geometry object'
        return 1
    fi
    if ! printf '%s' "$outputs" | "$NIRI_RUNTIME_JQ" -e \
        "$active_mode_definition
        any(.[]?;
            active_mode and
            (.logical | type) == \"object\" and
            (.logical.width | type) == \"number\" and
            .logical.width > 0 and
            (.logical.height | type) == \"number\" and
            .logical.height > 0)" >/dev/null; then
        niri_runtime_fail \
            'no active Niri output has positive logical width and height'
        return 1
    fi
}

niri_runtime_main() {
    local user=${SUDO_USER:-$(id -un)} status=0 manager_environment socket
    local socket_count pid restarts outputs compact output_preview
    local render_evidence command

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --user)
                [ "$#" -ge 2 ] || {
                    niri_runtime_usage >&2
                    return 64
                }
                user=$2
                shift 2
                ;;
            -h|--help)
                niri_runtime_usage
                return 0
                ;;
            *)
                niri_runtime_usage >&2
                return 64
                ;;
        esac
    done

    case "$user" in
        ''|root)
            niri_runtime_fail 'specify a non-root target with --user'
            return 64
            ;;
    esac
    for command in "$NIRI_RUNTIME_LOGINCTL" "$NIRI_RUNTIME_SYSTEMCTL" \
        "$NIRI_RUNTIME_NIRI" "$NIRI_RUNTIME_JQ" \
        "$NIRI_RUNTIME_TIMEOUT_COMMAND"; do
        command -v "$command" >/dev/null 2>&1 || {
            niri_runtime_fail "required command is unavailable: $command"
            return 1
        }
    done

    NIRI_RUNTIME_TARGET_USER=$user
    NIRI_RUNTIME_TARGET_UID=$(id -u "$user") || {
        niri_runtime_fail "cannot resolve target user: $user"
        return 64
    }
    NIRI_RUNTIME_DIR="$NIRI_RUNTIME_USER_ROOT/$NIRI_RUNTIME_TARGET_UID"
    export NIRI_RUNTIME_TARGET_USER NIRI_RUNTIME_TARGET_UID NIRI_RUNTIME_DIR

    niri_runtime_find_session "$NIRI_RUNTIME_TARGET_UID" || status=$?
    case "$status" in
        0) ;;
        1)
            printf 'SKIP: no active local Niri seat session for %s\n' "$user"
            return 2
            ;;
        *)
            niri_runtime_fail 'loginctl could not inspect local sessions'
            return 1
            ;;
    esac
    [ -S "$NIRI_RUNTIME_DIR/bus" ] || {
        niri_runtime_fail "user bus is unavailable: $NIRI_RUNTIME_DIR/bus"
        return 1
    }
    niri_runtime_as_user "$NIRI_RUNTIME_SYSTEMCTL" --user \
        is-active --quiet niri.service || {
        niri_runtime_fail 'niri.service is not active in the target user manager'
        return 1
    }
    niri_runtime_as_user "$NIRI_RUNTIME_SYSTEMCTL" --user \
        is-active --quiet graphical-session.target || {
        niri_runtime_fail 'graphical-session.target is not active in the target user manager'
        return 1
    }
    pid=$(niri_runtime_as_user "$NIRI_RUNTIME_SYSTEMCTL" --user show \
        niri.service -p MainPID --value) || {
        niri_runtime_fail 'cannot read niri.service MainPID'
        return 1
    }
    case "$pid" in
        ''|0|*[!0-9]*)
            niri_runtime_fail "invalid niri.service MainPID: ${pid:-<empty>}"
            return 1
            ;;
    esac
    kill -0 "$pid" 2>/dev/null || {
        niri_runtime_fail "niri.service MainPID is not alive: $pid"
        return 1
    }
    restarts=$(niri_runtime_as_user "$NIRI_RUNTIME_SYSTEMCTL" --user show \
        niri.service -p NRestarts --value) || {
        niri_runtime_fail 'cannot read niri.service NRestarts'
        return 1
    }
    case "$restarts" in
        0) ;;
        ''|*[!0-9]*)
            niri_runtime_fail "invalid niri.service NRestarts: ${restarts:-<empty>}"
            return 1
            ;;
        *)
            niri_runtime_fail "niri.service restarted during this user-manager lifetime: $restarts"
            return 1
            ;;
    esac

    manager_environment=$(niri_runtime_as_user "$NIRI_RUNTIME_SYSTEMCTL" \
        --user show-environment) || {
        niri_runtime_fail 'cannot read the target user manager environment'
        return 1
    }
    socket_count=$(printf '%s\n' "$manager_environment" |
        grep -c '^NIRI_SOCKET=' || true)
    [ "$socket_count" -eq 1 ] || {
        niri_runtime_fail "expected one NIRI_SOCKET, found $socket_count"
        return 1
    }
    socket=$(printf '%s\n' "$manager_environment" |
        sed -n 's/^NIRI_SOCKET=//p')
    case "$socket" in
        "$NIRI_RUNTIME_DIR"/*) ;;
        *)
            niri_runtime_fail "NIRI_SOCKET is outside the target runtime dir: $socket"
            return 1
            ;;
    esac
    [ -S "$socket" ] && [ ! -L "$socket" ] || {
        niri_runtime_fail "NIRI_SOCKET is not a direct Unix socket: $socket"
        return 1
    }

    status=0
    outputs=$(niri_runtime_as_user "$NIRI_RUNTIME_TIMEOUT_COMMAND" \
        "$NIRI_RUNTIME_TIMEOUT" env NIRI_SOCKET="$socket" \
        "$NIRI_RUNTIME_NIRI" msg --json outputs) || status=$?
    if [ "$status" -ne 0 ]; then
        if [ "$status" -eq 124 ]; then
            niri_runtime_fail \
                "niri msg --json outputs timed out after $NIRI_RUNTIME_TIMEOUT"
        else
            niri_runtime_fail "niri msg --json outputs failed with status $status"
        fi
        return 1
    fi
    niri_runtime_outputs_valid "$outputs" || return 1
    compact=$(printf '%s' "$outputs" | tr -d '[:space:]')

    render_evidence=$(niri_runtime_render_evidence "$pid") || {
        niri_runtime_fail 'no renderer or DRM device evidence was found for Niri'
        return 1
    }
    output_preview=$(printf '%s' "$compact" | cut -c 1-200)
    printf 'OK: session=%s seat=%s service=%s vt=%s user=%s\n' \
        "$NIRI_RUNTIME_SESSION_ID" "$NIRI_RUNTIME_SESSION_SEAT" \
        "$NIRI_RUNTIME_SESSION_SERVICE" "$NIRI_RUNTIME_SESSION_VT" "$user"
    printf 'OK: niri.service=active graphical-session.target=active pid=%s restarts=%s\n' \
        "$pid" "$restarts"
    printf 'OK: NIRI_SOCKET=%s\n' "$socket"
    printf 'OK: outputs=%s\n' "$output_preview"
    printf 'OK: %s\n' "$render_evidence"
    printf 'RESULT: Niri runtime smoke passed\n'
}

niri_runtime_main "$@"
