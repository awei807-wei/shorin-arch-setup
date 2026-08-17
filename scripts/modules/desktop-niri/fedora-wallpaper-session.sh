#!/usr/bin/env bash
set -Eeuo pipefail

# Fedora wallpaper session coordinator.
#
# Niri starts this file once.  It owns both awww namespaces and serializes the
# startup sequence so that a second login cannot race a daemon that is still
# initializing.  The script deliberately uses awww's query/kill protocol
# rather than process-name signals; awww kill waits for the socket to vanish,
# which also handles an older session left behind by a failed logout.

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

AWWW_BIN=${AWWW_BIN:-awww}
AWWW_DAEMON_BIN=${AWWW_DAEMON_BIN:-awww-daemon}
WAYPAPER_BIN=${WAYPAPER_BIN:-waypaper}
FEDORA_WALLPAPER_QUERY_TIMEOUT=${FEDORA_WALLPAPER_QUERY_TIMEOUT:-2}
FEDORA_WALLPAPER_READY_TIMEOUT=${FEDORA_WALLPAPER_READY_TIMEOUT:-12}
FEDORA_WALLPAPER_IMAGE_TIMEOUT=${FEDORA_WALLPAPER_IMAGE_TIMEOUT:-15}
FEDORA_WALLPAPER_WAYPAPER_TIMEOUT=${FEDORA_WALLPAPER_WAYPAPER_TIMEOUT:-30}
FEDORA_WALLPAPER_DEFAULT_NAMESPACE=${FEDORA_WALLPAPER_DEFAULT_NAMESPACE:-}
FEDORA_WALLPAPER_OVERVIEW_NAMESPACE=${FEDORA_WALLPAPER_OVERVIEW_NAMESPACE:-overview}
FEDORA_WALLPAPER_OVERVIEW_SCRIPT=${FEDORA_WALLPAPER_OVERVIEW_SCRIPT:-\
    "$HOME/.config/scripts/niri_set_overview_blur_dark_bg.sh"}
FEDORA_WALLPAPER_AUTO_BLUR_SCRIPT=${FEDORA_WALLPAPER_AUTO_BLUR_SCRIPT:-\
    "$HOME/.config/scripts/niri_auto_blur_bg.sh"}
FEDORA_WALLPAPER_STATE_DIR=${FEDORA_WALLPAPER_STATE_DIR:-\
    "${XDG_STATE_HOME:-$HOME/.local/state}/shorin-arch-setup"}
FEDORA_WALLPAPER_LOG=${FEDORA_WALLPAPER_LOG:-\
    "$FEDORA_WALLPAPER_STATE_DIR/fedora-wallpaper-session.log"}
FEDORA_WALLPAPER_LOCK=${FEDORA_WALLPAPER_LOCK:-\
    "$FEDORA_WALLPAPER_STATE_DIR/fedora-wallpaper-session.lock"}

fedora_wallpaper_log() {
    mkdir -p "$(dirname "$FEDORA_WALLPAPER_LOG")" 2>/dev/null || return 0
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$FEDORA_WALLPAPER_LOG" 2>/dev/null || true
}

fedora_wallpaper_command_help_satisfied() {
    local awww_help query_help kill_help daemon_help

    awww_help=$("$AWWW_BIN" --help 2>&1) || return 1
    query_help=$("$AWWW_BIN" query --help 2>&1) || return 1
    kill_help=$("$AWWW_BIN" kill --help 2>&1) || return 1
    daemon_help=$("$AWWW_DAEMON_BIN" --help 2>&1) || return 1
    grep -Eq '(^|[[:space:]])query([[:space:]]|$)' <<< "$awww_help" || return 1
    grep -Eq '(^|[[:space:]])kill([[:space:]]|$)' <<< "$awww_help" || return 1
    grep -Fq -- '--namespace' <<< "$query_help" || return 1
    grep -Fq -- '--namespace' <<< "$kill_help" || return 1
    grep -Fq -- '--namespace' <<< "$daemon_help" || return 1
}

fedora_wallpaper_awww_query() {
    local namespace=$1
    local -a args=(query)

    [ -n "$namespace" ] && args+=(--namespace "$namespace")
    timeout --signal=TERM "$FEDORA_WALLPAPER_QUERY_TIMEOUT" \
        "$AWWW_BIN" "${args[@]}"
}

fedora_wallpaper_awww_kill() {
    local namespace=$1
    local -a args=(kill)

    [ -n "$namespace" ] && args+=(--namespace "$namespace")
    timeout --signal=TERM "$FEDORA_WALLPAPER_QUERY_TIMEOUT" \
        "$AWWW_BIN" "${args[@]}"
}

fedora_wallpaper_query_is_ready() {
    local namespace=$1 output

    output=$(fedora_wallpaper_awww_query "$namespace" 2>/dev/null) || return 1
    grep -Eq 'currently displaying:[[:space:]]*(color|image):' <<< "$output"
}

fedora_wallpaper_query_image() {
    local namespace=$1 output

    output=$(fedora_wallpaper_awww_query "$namespace" 2>/dev/null) || return 1
    awk '
        {
            sub(/\r$/, "")
            if ($0 !~ /currently displaying:[[:space:]]*image:[[:space:]]*/) next
            value=$0
            sub(/^.*currently displaying:[[:space:]]*image:[[:space:]]*/, "", value)
            sub(/[[:space:]]+$/, "", value)
            if (length(value) > 0) {
                print value
                exit
            }
        }
    ' <<< "$output"
}

fedora_wallpaper_wait_for_ready() {
    local namespace=$1 timeout_seconds=${2:-$FEDORA_WALLPAPER_READY_TIMEOUT}
    local deadline=$((SECONDS + timeout_seconds))

    while :; do
        fedora_wallpaper_query_is_ready "$namespace" && return 0
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 0.1
    done
}

fedora_wallpaper_wait_for_image() {
    local namespace=$1 timeout_seconds=${2:-$FEDORA_WALLPAPER_IMAGE_TIMEOUT}
    local deadline=$((SECONDS + timeout_seconds)) image

    while :; do
        image=$(fedora_wallpaper_query_image "$namespace" || true)
        if [ -n "$image" ]; then
            printf '%s\n' "$image"
            return 0
        fi
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 0.1
    done
}

fedora_wallpaper_start_daemon() {
    local namespace=$1
    local -a args=(--no-cache)
    local daemon_log

    [ -n "$namespace" ] && args+=(--namespace "$namespace")
    mkdir -p "$(dirname "$FEDORA_WALLPAPER_LOG")" 2>/dev/null || true
    daemon_log="${FEDORA_WALLPAPER_LOG}.${namespace:-default}.daemon"
    "$AWWW_DAEMON_BIN" "${args[@]}" >> "$daemon_log" 2>&1 &
    fedora_wallpaper_log "started awww-daemon namespace=${namespace:-default} pid=$!"
}

fedora_wallpaper_ensure_daemon() {
    local namespace=$1

    # A configured daemon is safe to reuse.  This makes repeated invocation
    # idempotent and avoids needlessly replacing a live user's wallpaper.
    if fedora_wallpaper_query_is_ready "$namespace"; then
        return 0
    fi

    # A query can fail because an older daemon is still between Wayland setup
    # and socket readiness.  Ask that namespace to exit through awww itself;
    # timeout keeps a broken/stale socket from blocking the login forever.
    fedora_wallpaper_awww_kill "$namespace" >/dev/null 2>&1 || true
    fedora_wallpaper_start_daemon "$namespace"
    fedora_wallpaper_wait_for_ready "$namespace"
}

fedora_wallpaper_run_quietly() {
    local label=$1 timeout_seconds=$2
    shift 2

    if timeout --signal=TERM "$timeout_seconds" "$@" \
        >> "$FEDORA_WALLPAPER_LOG" 2>&1; then
        return 0
    fi
    fedora_wallpaper_log "$label skipped or timed out"
    return 1
}

fedora_wallpaper_query_wrapper() {
    # QuickShell and helper scripts may query while the daemon is still
    # configuring its Wayland socket.  Keep one invocation bounded across the
    # readiness and color-to-image transitions; on either timeout emit no
    # output so a caller cannot turn a transient daemon error into a desktop
    # notification.
    local output

    fedora_wallpaper_wait_for_ready "$FEDORA_WALLPAPER_DEFAULT_NAMESPACE" \
        "$FEDORA_WALLPAPER_READY_TIMEOUT" || return 0
    fedora_wallpaper_wait_for_image "$FEDORA_WALLPAPER_DEFAULT_NAMESPACE" \
        "$FEDORA_WALLPAPER_IMAGE_TIMEOUT" >/dev/null || return 0
    output=$(fedora_wallpaper_awww_query "$FEDORA_WALLPAPER_DEFAULT_NAMESPACE" \
        2>/dev/null) || return 0
    [ -n "$output" ] && printf '%s\n' "$output"
}

fedora_wallpaper_session_main() {
    local default_ready=0 overview_ready=0 image
    local lock_fd

    mkdir -p "$(dirname "$FEDORA_WALLPAPER_LOCK")" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        exec {lock_fd}>"$FEDORA_WALLPAPER_LOCK"
        flock -n "$lock_fd" || return 0
    fi

    if ! fedora_wallpaper_command_help_satisfied; then
        fedora_wallpaper_log 'awww namespace/query/kill help contract unavailable; startup skipped'
        return 0
    fi
    if fedora_wallpaper_ensure_daemon "$FEDORA_WALLPAPER_DEFAULT_NAMESPACE"; then
        default_ready=1
    else
        fedora_wallpaper_log 'default awww daemon did not become ready'
    fi
    if fedora_wallpaper_ensure_daemon "$FEDORA_WALLPAPER_OVERVIEW_NAMESPACE"; then
        overview_ready=1
    else
        fedora_wallpaper_log 'overview awww daemon did not become ready'
    fi
    [ "$default_ready" -eq 1 ] || return 0

    # Waypaper owns folder/wallpaper/stylesheet configuration.  The wrapper
    # only serializes its random selection after the default socket is ready.
    fedora_wallpaper_run_quietly waypaper \
        "$FEDORA_WALLPAPER_WAYPAPER_TIMEOUT" "$WAYPAPER_BIN" --random || return 0
    image=$(fedora_wallpaper_wait_for_image \
        "$FEDORA_WALLPAPER_DEFAULT_NAMESPACE" || true)
    if [ -z "$image" ]; then
        fedora_wallpaper_log 'wallpaper remained color or unavailable; blur startup skipped'
        return 0
    fi
    [ "$overview_ready" -eq 1 ] || {
        fedora_wallpaper_log 'overview daemon unavailable; blur startup skipped'
        return 0
    }

    if [ -x "$FEDORA_WALLPAPER_OVERVIEW_SCRIPT" ]; then
        fedora_wallpaper_run_quietly overview-blur 20 \
            "$FEDORA_WALLPAPER_OVERVIEW_SCRIPT" "$image" || true
    fi
    if [ -x "$FEDORA_WALLPAPER_AUTO_BLUR_SCRIPT" ]; then
        fedora_wallpaper_run_quietly auto-blur 20 \
            "$FEDORA_WALLPAPER_AUTO_BLUR_SCRIPT" || true
    fi
}

fedora_wallpaper_dispatch() {
    if [ "${0##*/}" = shorin-fedora-awww-query ]; then
        fedora_wallpaper_query_wrapper
        return
    fi
    case "${1:-}" in
        query) fedora_wallpaper_query_wrapper ;;
        session|'') fedora_wallpaper_session_main ;;
        *)
            printf 'usage: %s [query|session]\n' "${0##*/}" >&2
            return 2
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    fedora_wallpaper_dispatch "$@"
fi
