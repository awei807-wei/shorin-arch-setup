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
FEDORA_WALLPAPER_PATH=${FEDORA_WALLPAPER_PATH:-$HOME/.local/bin:/usr/local/bin:/usr/bin}
FEDORA_WALLPAPER_QUERY_TIMEOUT=${FEDORA_WALLPAPER_QUERY_TIMEOUT:-2}
FEDORA_WALLPAPER_READY_TIMEOUT=${FEDORA_WALLPAPER_READY_TIMEOUT:-12}
FEDORA_WALLPAPER_IMAGE_TIMEOUT=${FEDORA_WALLPAPER_IMAGE_TIMEOUT:-15}
FEDORA_WALLPAPER_WAYPAPER_TIMEOUT=${FEDORA_WALLPAPER_WAYPAPER_TIMEOUT:-30}
FEDORA_WALLPAPER_DEFAULT_NAMESPACE=${FEDORA_WALLPAPER_DEFAULT_NAMESPACE:-}
FEDORA_WALLPAPER_OVERVIEW_NAMESPACE=${FEDORA_WALLPAPER_OVERVIEW_NAMESPACE:-overview}
FEDORA_WALLPAPER_OVERVIEW_SCRIPT=${FEDORA_WALLPAPER_OVERVIEW_SCRIPT:-"$HOME/.config/scripts/niri_set_overview_blur_dark_bg.sh"}
FEDORA_WALLPAPER_AUTO_BLUR_SCRIPT=${FEDORA_WALLPAPER_AUTO_BLUR_SCRIPT:-"$HOME/.config/scripts/niri_auto_blur_bg.sh"}
FEDORA_WALLPAPER_STATE_DIR_EXPLICIT=${FEDORA_WALLPAPER_STATE_DIR+x}
FEDORA_WALLPAPER_LOG_EXPLICIT=${FEDORA_WALLPAPER_LOG+x}
FEDORA_WALLPAPER_LOCK_EXPLICIT=${FEDORA_WALLPAPER_LOCK+x}
FEDORA_WALLPAPER_STATE_DIR=${FEDORA_WALLPAPER_STATE_DIR:-"${XDG_STATE_HOME:-$HOME/.local/state}/shorin-arch-setup"}
FEDORA_WALLPAPER_LOG=${FEDORA_WALLPAPER_LOG:-"$FEDORA_WALLPAPER_STATE_DIR/fedora-wallpaper-session.log"}
FEDORA_WALLPAPER_LOCK=${FEDORA_WALLPAPER_LOCK:-"$FEDORA_WALLPAPER_STATE_DIR/fedora-wallpaper-session.lock"}
FEDORA_WALLPAPER_MAX_RETRIES=${FEDORA_WALLPAPER_MAX_RETRIES:-2}

fedora_wallpaper_path_is_safe() {
    local path=$1 current=/ component
    local -a components=()

    case "$path" in
        /*) ;;
        *) return 1 ;;
    esac
    [ "$path" != / ] || return 1
    IFS=/ read -r -a components <<< "${path#/}"
    for component in "${components[@]}"; do
        [ -n "$component" ] || continue
        case "$component" in
            .|..) return 1 ;;
        esac
        if [ "$current" = / ]; then
            current="/$component"
        else
            current="$current/$component"
        fi
        [ ! -L "$current" ] || return 1
    done
}

fedora_wallpaper_state_dir_writable() {
    local state_dir=$1

    fedora_wallpaper_path_is_safe "$state_dir" || return 1
    if [ -e "$state_dir" ] && [ ! -d "$state_dir" ]; then
        return 1
    fi
    if [ ! -e "$state_dir" ]; then
        mkdir -m 700 -p -- "$state_dir" 2>/dev/null || return 1
    fi
    [ ! -L "$state_dir" ] &&
        [ "$(stat -c '%u' "$state_dir" 2>/dev/null || printf '%s' -1)" -eq "$(id -u)" ] &&
        [ -w "$state_dir" ]
}

fedora_wallpaper_prepare_state() {
    local configured_state=$FEDORA_WALLPAPER_STATE_DIR
    local runtime_root runtime_state warning

    if fedora_wallpaper_state_dir_writable "$configured_state"; then
        return 0
    fi

    warning="Fedora wallpaper state namespace is unavailable: $configured_state"
    if [ -n "${FEDORA_WALLPAPER_STATE_DIR_EXPLICIT:-}" ]; then
        printf 'WARNING: %s; explicit state directory will not be bypassed.\n' \
            "$warning" >&2
        return 1
    fi

    runtime_root=${XDG_RUNTIME_DIR:-}
    runtime_state=${runtime_root%/}/shorin-arch-setup
    if [ -z "$runtime_root" ] ||
        ! fedora_wallpaper_state_dir_writable "$runtime_root" ||
        ! fedora_wallpaper_state_dir_writable "$runtime_state"; then
        printf 'WARNING: %s; no safe XDG_RUNTIME_DIR fallback is available.\n' \
            "$warning" >&2
        return 1
    fi

    FEDORA_WALLPAPER_STATE_DIR=$runtime_state
    [ -n "${FEDORA_WALLPAPER_LOG_EXPLICIT:-}" ] ||
        FEDORA_WALLPAPER_LOG="$runtime_state/fedora-wallpaper-session.log"
    [ -n "${FEDORA_WALLPAPER_LOCK_EXPLICIT:-}" ] ||
        FEDORA_WALLPAPER_LOCK="$runtime_state/fedora-wallpaper-session.lock"
    fedora_wallpaper_log "WARNING: $warning; using session runtime state $runtime_state"
}

fedora_wallpaper_path() {
    PATH="$FEDORA_WALLPAPER_PATH" command -v "$1"
}

fedora_wallpaper_run() {
    PATH="$FEDORA_WALLPAPER_PATH" "$@"
}

fedora_wallpaper_log() {
    mkdir -p "$(dirname "$FEDORA_WALLPAPER_LOG")" 2>/dev/null || return 0
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$FEDORA_WALLPAPER_LOG" 2>/dev/null || true
}

fedora_wallpaper_command_help_satisfied() {
    local awww_help query_help kill_help daemon_help

    awww_help=$(fedora_wallpaper_run "$AWWW_BIN" --help 2>&1) || return 1
    query_help=$(fedora_wallpaper_run "$AWWW_BIN" query --help 2>&1) || return 1
    kill_help=$(fedora_wallpaper_run "$AWWW_BIN" kill --help 2>&1) || return 1
    daemon_help=$(fedora_wallpaper_run "$AWWW_DAEMON_BIN" --help 2>&1) || return 1
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
    PATH="$FEDORA_WALLPAPER_PATH" timeout --signal=TERM \
        "$FEDORA_WALLPAPER_QUERY_TIMEOUT" "$AWWW_BIN" "${args[@]}"
}

fedora_wallpaper_awww_kill() {
    local namespace=$1
    local -a args=(kill)

    [ -n "$namespace" ] && args+=(--namespace "$namespace")
    PATH="$FEDORA_WALLPAPER_PATH" timeout --signal=TERM \
        "$FEDORA_WALLPAPER_QUERY_TIMEOUT" "$AWWW_BIN" "${args[@]}"
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

fedora_wallpaper_expand_path() {
    local value=$1

    case "$value" in
        '~'/*) printf '%s/%s\n' "$HOME" "${value#'~/'}" ;;
        '~') printf '%s\n' "$HOME" ;;
        /*) printf '%s\n' "$value" ;;
        *) printf '%s\n' "$HOME/$value" ;;
    esac
}

fedora_wallpaper_configured_image() {
    local config=${FEDORA_WALLPAPER_CONFIG:-$HOME/.config/waypaper/config.ini}
    local value folder image

    [ -f "$config" ] || return 1
    value=$(awk '
        /^[[:space:]]*[#;]/ { next }
        /^[[:space:]]*(wallpaper|current_wallpaper|last_wallpaper|image)[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            gsub(/^"|"$/, "")
            gsub(/^'\''| '\''$/, "")
            if (length($0) > 0) { print; exit }
        }
    ' "$config")
    if [ -n "$value" ]; then
        image=$(fedora_wallpaper_expand_path "$value")
        [ -f "$image" ] && [ -s "$image" ] && [ ! -L "$image" ] || return 1
        printf '%s\n' "$image"
        return 0
    fi

    folder=$(awk '
        /^[[:space:]]*[#;]/ { next }
        /^[[:space:]]*folder[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            gsub(/^"|"$/, "")
            if (length($0) > 0) { print; exit }
        }
    ' "$config")
    [ -n "$folder" ] || return 1
    folder=$(fedora_wallpaper_expand_path "$folder")
    [ -d "$folder" ] || return 1
    while IFS= read -r -d '' image; do
        [ -f "$image" ] && [ -s "$image" ] && [ ! -L "$image" ] || continue
        printf '%s\n' "$image"
        return 0
    done < <(find "$folder" -maxdepth 1 -type f \( \
        -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o \
        -iname '*.webp' -o -iname '*.gif' \) -print0 | sort -z)
    return 1
}

fedora_wallpaper_apply_image() {
    local namespace=$1 image=$2
    local -a args=(img)

    [ -f "$image" ] && [ -s "$image" ] && [ ! -L "$image" ] || return 1
    [ -n "$namespace" ] && args+=(--namespace "$namespace")
    args+=("$image")
    PATH="$FEDORA_WALLPAPER_PATH" timeout --signal=TERM \
        "$FEDORA_WALLPAPER_IMAGE_TIMEOUT" "$AWWW_BIN" \
        "${args[@]}" >> "$FEDORA_WALLPAPER_LOG" 2>&1
}

fedora_wallpaper_close_lock_fd() {
    local lock_fd=${FEDORA_WALLPAPER_LOCK_FD:-}

    [ -n "$lock_fd" ] || return 0
    case "$lock_fd" in
        *[!0-9]*) return 0 ;;
    esac
    # Bash's dynamic descriptor syntax closes the numeric descriptor stored in
    # lock_fd without evaluating any text supplied through the environment.
    exec {lock_fd}>&-
}

fedora_wallpaper_start_daemon() {
    local namespace=$1
    local -a args=(--no-cache)
    local daemon_log

    [ -n "$namespace" ] && args+=(--namespace "$namespace")
    mkdir -p "$(dirname "$FEDORA_WALLPAPER_LOG")" 2>/dev/null || true
    daemon_log="${FEDORA_WALLPAPER_LOG}.${namespace:-default}.daemon"

    # The daemon is intentionally detached from the initializer's flock FD.
    # A background process retaining that descriptor would keep the lock held
    # after this script exits and block every later login until the daemon
    # dies.  Close it in the child immediately before exec, without eval.
    (
        fedora_wallpaper_close_lock_fd
        fedora_wallpaper_run "$AWWW_DAEMON_BIN" "${args[@]}"
    ) >> "$daemon_log" 2>&1 &
    fedora_wallpaper_log "started awww-daemon namespace=${namespace:-default} pid=$!"
}

fedora_wallpaper_ensure_daemon() {
    local namespace=$1 attempt

    # A stale socket is handled through awww's namespace protocol.  Retry only
    # a bounded number of times and return the final readiness error instead
    # of silently claiming a working wallpaper backend.
    for ((attempt = 1; attempt <= FEDORA_WALLPAPER_MAX_RETRIES; attempt++)); do
        if fedora_wallpaper_query_is_ready "$namespace"; then
            return 0
        fi
        fedora_wallpaper_awww_kill "$namespace" >/dev/null 2>&1 ||
            fedora_wallpaper_log "awww kill failed namespace=${namespace:-default} attempt=$attempt"
        fedora_wallpaper_start_daemon "$namespace"
        if fedora_wallpaper_wait_for_ready "$namespace"; then
            return 0
        fi
        fedora_wallpaper_log "awww daemon not ready namespace=${namespace:-default} attempt=$attempt"
    done
    return 1
}

fedora_wallpaper_run_quietly() {
    local label=$1 timeout_seconds=$2
    shift 2

    # Helper scripts can daemonize their own work.  Run timeout in a child
    # after closing the initializer's dynamic flock descriptor so those
    # descendants cannot retain the session lock either.
    if (
        fedora_wallpaper_close_lock_fd
        PATH="$FEDORA_WALLPAPER_PATH" timeout --signal=TERM "$timeout_seconds" "$@"
    ) >> "$FEDORA_WALLPAPER_LOG" 2>&1; then
        return 0
    fi
    fedora_wallpaper_log "$label skipped or timed out"
    return 1
}

fedora_wallpaper_niri_socket_is_valid() {
    local socket=${NIRI_SOCKET:-}

    [ -n "$socket" ] && [ -S "$socket" ]
}

fedora_wallpaper_find_niri_socket() {
    local runtime_dir=${XDG_RUNTIME_DIR:-}
    local wayland_display=${WAYLAND_DISPLAY:-}
    local candidate name prefix pid exe

    [ -n "$runtime_dir" ] && [ -n "$wayland_display" ] || return 1
    case "$wayland_display" in
        *[![:alnum:]_.-]*) return 1 ;;
    esac
    prefix="niri.${wayland_display}."

    for candidate in "$runtime_dir/${prefix}"*.sock; do
        [ -e "$candidate" ] || continue
        [ ! -L "$candidate" ] || continue
        [ -S "$candidate" ] || continue
        name=${candidate##*/}
        case "$name" in
            "$prefix"*.sock) ;;
            *) continue ;;
        esac
        pid=${name#"$prefix"}
        pid=${pid%.sock}
        case "$pid" in
            ''|*[!0-9]*) continue ;;
        esac
        kill -0 "$pid" 2>/dev/null || continue
        exe=$(basename -- "$(readlink -f -- "/proc/$pid/exe" 2>/dev/null || true)")
        [ "$exe" = niri ] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

fedora_wallpaper_prepare_niri_socket() {
    local current=${NIRI_SOCKET:-} candidate

    fedora_wallpaper_niri_socket_is_valid && return 0
    candidate=$(fedora_wallpaper_find_niri_socket || true)
    if [ -n "$candidate" ]; then
        export NIRI_SOCKET="$candidate"
        fedora_wallpaper_log \
            "WARNING: invalid NIRI_SOCKET=${current:-<unset>}; using active niri socket $candidate"
        return 0
    fi
    fedora_wallpaper_log \
        "WARNING: invalid NIRI_SOCKET=${current:-<unset>}; no active niri socket candidate found"
    return 1
}

fedora_wallpaper_run_niri_helper() (
    local label=$1 timeout_seconds=$2
    shift 2

    # Keep any temporary socket override inside this subshell so callers keep
    # their original NIRI_SOCKET value and export state after the helper.
    fedora_wallpaper_prepare_niri_socket || true
    fedora_wallpaper_run_quietly "$label" "$timeout_seconds" "$@"
)

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
    local default_ready=0 overview_ready=0 image configured_image
    local lock_fd

    unset FEDORA_WALLPAPER_LOCK_FD
    fedora_wallpaper_prepare_state || return 1
    mkdir -p "$(dirname "$FEDORA_WALLPAPER_LOCK")" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        if ! exec {lock_fd}>"$FEDORA_WALLPAPER_LOCK"; then
            fedora_wallpaper_log "unable to open wallpaper session lock: $FEDORA_WALLPAPER_LOCK"
            return 1
        fi
        if ! flock -n "$lock_fd"; then
            exec {lock_fd}>&-
            return 0
        fi
        FEDORA_WALLPAPER_LOCK_FD=$lock_fd
    fi

    if ! fedora_wallpaper_command_help_satisfied; then
        fedora_wallpaper_log 'awww namespace/query/kill help contract unavailable; startup skipped'
        return 1
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
    [ "$default_ready" -eq 1 ] || return 1

    # Preserve Waypaper's random-selection semantics whenever it is available.
    # Waypaper may update its config as part of --random; re-read that config
    # afterwards and ask awww to apply the selected image explicitly.  Only a
    # missing Waypaper executable takes the direct-config recovery path.
    if fedora_wallpaper_path "$WAYPAPER_BIN" >/dev/null 2>&1; then
        fedora_wallpaper_run_quietly waypaper \
            "$FEDORA_WALLPAPER_WAYPAPER_TIMEOUT" "$WAYPAPER_BIN" --random || {
            fedora_wallpaper_log 'Waypaper random selection failed'
            return 1
        }
        configured_image=$(fedora_wallpaper_configured_image || true)
        if [ -n "$configured_image" ]; then
            fedora_wallpaper_apply_image "$FEDORA_WALLPAPER_DEFAULT_NAMESPACE" \
                "$configured_image" || {
                fedora_wallpaper_log 'configured wallpaper apply failed after Waypaper selection'
                return 1
            }
        fi
    else
        configured_image=$(fedora_wallpaper_configured_image || true)
        if [ -n "$configured_image" ]; then
            fedora_wallpaper_apply_image "$FEDORA_WALLPAPER_DEFAULT_NAMESPACE" \
                "$configured_image" || {
                fedora_wallpaper_log 'direct configured wallpaper apply failed'
                return 1
            }
        else
            fedora_wallpaper_log 'Waypaper is unavailable and no configured wallpaper image was found'
            return 1
        fi
    fi
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
        fedora_wallpaper_run_niri_helper overview-blur 20 \
            "$FEDORA_WALLPAPER_OVERVIEW_SCRIPT" "$image" || true
    fi
    if [ -x "$FEDORA_WALLPAPER_AUTO_BLUR_SCRIPT" ]; then
        fedora_wallpaper_run_niri_helper auto-blur 20 \
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
