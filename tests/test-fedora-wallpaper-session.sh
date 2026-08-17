#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SHORIN_DISTRO=fedora
TEST_DIR=$(mktemp -d)
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

SESSION_SCRIPT="$ROOT_DIR/scripts/modules/desktop-niri/fedora-wallpaper-session.sh"
[ -x "$SESSION_SCRIPT" ] || fail 'Fedora wallpaper session coordinator must be executable'
! grep -Eq '(^|[[:space:]])(pkill|killall)([[:space:]]|$)' \
    "$SESSION_SCRIPT" ||
    fail 'wallpaper session coordinator must not use process-name kill commands'

make_fixture() {
    local root=$1

    mkdir -p "$root/bin" "$root/state" "$root/home" "$root/log"
    cat > "$root/bin/awww" <<'AWEOF'
#!/usr/bin/env bash
set -Eeuo pipefail

log=${WALLPAPER_TEST_LOG:?}
state=${WALLPAPER_TEST_STATE:?}
printf 'awww:%s\n' "$*" >> "$log"
if [ "${1:-}" = --help ]; then
    printf '%s\n' 'query kill --namespace'
    exit 0
fi
if [ "${2:-}" = --help ] && { [ "${1:-}" = query ] || [ "${1:-}" = kill ]; }; then
    printf '%s\n' '--namespace'
    exit 0
fi
action=${1:-}
shift || true
namespace=default
while [ "$#" -gt 0 ]; do
    case "$1" in
        --namespace) namespace=$2; shift 2 ;;
        *) shift ;;
    esac
done
case "$action" in
    img)
        touch "$state/$namespace.image"
        ;;
    query)
        if [ "${WALLPAPER_DELAY_MODE:-0}" -eq 1 ]; then
            count_file=${WALLPAPER_QUERY_COUNT_FILE:?}
            count=0
            [ -f "$count_file" ] && count=$(cat "$count_file")
            count=$((count + 1))
            printf '%s\n' "$count" > "$count_file"
            if [ "${WALLPAPER_DELAY_NEVER_READY:-0}" -eq 1 ] ||
                [ "$count" -lt "${WALLPAPER_READY_AFTER:-3}" ]; then
                exit 1
            fi
            if [ "${WALLPAPER_DELAY_NEVER_IMAGE:-0}" -eq 1 ] ||
                [ "$count" -lt "${WALLPAPER_IMAGE_AFTER:-6}" ]; then
                printf '%s\n' ': eDP-1: 1920x1080, currently displaying: color: #000000'
            else
                printf '%s\n' ': eDP-1: 1920x1080, currently displaying: image: /tmp/delayed-wallpaper.png'
            fi
            exit 0
        fi
        [ ! -e "$state/$namespace.stale" ] || exit 1
        [ -e "$state/$namespace.ready" ] || exit 1
        if [ "$namespace" = default ] && [ -e "$state/default.image" ]; then
            printf '%s\n' ': eDP-1: 1920x1080, currently displaying: image: /tmp/wallpaper.png'
        else
            printf '%s\n' ': eDP-1: 1920x1080, currently displaying: color: #000000'
        fi
        ;;
    kill)
        rm -f "$state/$namespace.stale" "$state/$namespace.ready" \
            "$state/$namespace.image"
        ;;
    *) exit 64 ;;
esac
AWEOF
    cat > "$root/bin/awww-daemon" <<'AWEOF'
#!/usr/bin/env bash
set -Eeuo pipefail

log=${WALLPAPER_TEST_LOG:?}
state=${WALLPAPER_TEST_STATE:?}
printf 'daemon:%s\n' "$*" >> "$log"
if [ "${1:-}" = --help ]; then
    printf '%s\n' '--namespace'
    exit 0
fi
namespace=default
while [ "$#" -gt 0 ]; do
    case "$1" in
        --namespace) namespace=$2; shift 2 ;;
        *) shift ;;
    esac
done
touch "$state/$namespace.ready"
if [ -n "${WALLPAPER_TEST_DAEMON_PID_DIR:-}" ]; then
    mkdir -p "$WALLPAPER_TEST_DAEMON_PID_DIR"
    printf '%s\n' "$$" > "$WALLPAPER_TEST_DAEMON_PID_DIR/$namespace.pid"
fi
if [ "${WALLPAPER_TEST_DAEMON_STAY_ALIVE:-0}" -eq 1 ]; then
    trap 'rm -f "$WALLPAPER_TEST_DAEMON_PID_DIR/$namespace.pid"' EXIT
    while :; do sleep 1; done
fi
AWEOF
    cat > "$root/bin/waypaper" <<'AWEOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf 'waypaper:%s\n' "$*" >> "${WALLPAPER_TEST_LOG:?}"
if [ -n "${WALLPAPER_TEST_CONFIG_FILE:-}" ]; then
    mkdir -p "$(dirname "$WALLPAPER_TEST_CONFIG_FILE")"
    printf 'wallpaper = %s\n' "${WALLPAPER_TEST_CONFIG_IMAGE:?}" \
        > "$WALLPAPER_TEST_CONFIG_FILE"
fi
if [ "${WALLPAPER_TEST_MODE:-image}" = image ]; then
    touch "${WALLPAPER_TEST_STATE:?}/default.image"
fi
AWEOF
    cat > "$root/bin/overview-blur" <<'AWEOF'
#!/usr/bin/env bash
printf 'overview-blur:%s\n' "$*" >> "${WALLPAPER_TEST_LOG:?}"
if [ "${WALLPAPER_TEST_BLUR_BACKGROUND:-0}" -eq 1 ]; then
    pid_dir=${WALLPAPER_TEST_BLUR_PID_DIR:?}
    mkdir -p "$pid_dir"
    (exec sleep 1000) &
    printf '%s\n' "$!" > "$pid_dir/overview.pid"
fi
AWEOF
    cat > "$root/bin/auto-blur" <<'AWEOF'
#!/usr/bin/env bash
printf 'auto-blur:%s\n' "$*" >> "${WALLPAPER_TEST_LOG:?}"
if [ "${WALLPAPER_TEST_BLUR_BACKGROUND:-0}" -eq 1 ]; then
    pid_dir=${WALLPAPER_TEST_BLUR_PID_DIR:?}
    mkdir -p "$pid_dir"
    (exec sleep 1000) &
    printf '%s\n' "$!" > "$pid_dir/auto.pid"
fi
AWEOF
    chmod 755 "$root/bin"/*
}

run_session() {
    local root=$1 mode=${2:-image}

    WALLPAPER_TEST_LOG="$root/log/events" \
        WALLPAPER_TEST_STATE="$root/state" \
        WALLPAPER_TEST_MODE="$mode" \
        AWWW_BIN="$root/bin/awww" \
        AWWW_DAEMON_BIN="$root/bin/awww-daemon" \
        WAYPAPER_BIN="$root/bin/waypaper" \
        FEDORA_WALLPAPER_STATE_DIR="$root/log" \
        FEDORA_WALLPAPER_LOG="$root/log/session.log" \
        FEDORA_WALLPAPER_LOCK="$root/log/session.lock" \
        FEDORA_WALLPAPER_OVERVIEW_SCRIPT="$root/bin/overview-blur" \
        FEDORA_WALLPAPER_AUTO_BLUR_SCRIPT="$root/bin/auto-blur" \
        FEDORA_WALLPAPER_QUERY_TIMEOUT=1 \
        FEDORA_WALLPAPER_READY_TIMEOUT=2 \
        FEDORA_WALLPAPER_IMAGE_TIMEOUT=1 \
        FEDORA_WALLPAPER_WAYPAPER_TIMEOUT=2 \
        HOME="$root/home" \
        "$SESSION_SCRIPT"
}

# The happy path starts both namespaces once, waits for a ready color, runs
# Waypaper, then waits for the color-to-image transition before blur scripts.
happy="$TEST_DIR/happy"
make_fixture "$happy"
: > "$happy/log/events"
run_session "$happy"
grep -Fqx 'waypaper:--random' "$happy/log/events" ||
    fail 'default readiness must precede Waypaper random selection'
grep -Eq '^overview-blur:/tmp/wallpaper.png$' "$happy/log/events" ||
    fail 'overview blur must receive the image returned by awww query'
grep -Eq '^auto-blur:$' "$happy/log/events" ||
    fail 'auto blur must run after the image becomes ready'
waypaper_line=$(grep -n -F 'waypaper:--random' "$happy/log/events" | cut -d: -f1)
overview_line=$(grep -n -F 'overview-blur:/tmp/wallpaper.png' "$happy/log/events" | cut -d: -f1)
[ "$waypaper_line" -lt "$overview_line" ] ||
    fail 'blur startup must be ordered after Waypaper'
grep -Fq 'awww:kill' "$happy/log/events" ||
    fail 'a missing daemon must be cleaned through awww kill before start'
grep -Fq 'daemon:--no-cache --namespace overview' "$happy/log/events" ||
    fail 'overview daemon must use its own namespace'

# An available Waypaper must still perform --random even when its config
# already has a wallpaper; the refreshed config is then applied through awww.
random_config="$TEST_DIR/random-config"
make_fixture "$random_config"
mkdir -p "$random_config/home/.config/waypaper"
printf 'selected wallpaper\n' > "$random_config/home/selected.png"
: > "$random_config/log/events"
WALLPAPER_TEST_LOG="$random_config/log/events" \
    WALLPAPER_TEST_STATE="$random_config/state" \
    WALLPAPER_TEST_CONFIG_FILE="$random_config/home/.config/waypaper/config.ini" \
    WALLPAPER_TEST_CONFIG_IMAGE="$random_config/home/selected.png" \
    AWWW_BIN="$random_config/bin/awww" \
    AWWW_DAEMON_BIN="$random_config/bin/awww-daemon" \
    WAYPAPER_BIN="$random_config/bin/waypaper" \
    FEDORA_WALLPAPER_STATE_DIR="$random_config/log" \
    FEDORA_WALLPAPER_LOG="$random_config/log/session.log" \
    FEDORA_WALLPAPER_LOCK="$random_config/log/session.lock" \
    FEDORA_WALLPAPER_OVERVIEW_SCRIPT="$random_config/bin/overview-blur" \
    FEDORA_WALLPAPER_AUTO_BLUR_SCRIPT="$random_config/bin/auto-blur" \
    FEDORA_WALLPAPER_QUERY_TIMEOUT=1 \
    FEDORA_WALLPAPER_READY_TIMEOUT=2 \
    FEDORA_WALLPAPER_IMAGE_TIMEOUT=1 \
    FEDORA_WALLPAPER_WAYPAPER_TIMEOUT=2 \
    HOME="$random_config/home" \
    "$SESSION_SCRIPT"
random_line=$(grep -n -F 'waypaper:--random' "$random_config/log/events" | cut -d: -f1)
apply_line=$(grep -n -F "awww:img $random_config/home/selected.png" \
    "$random_config/log/events" | cut -d: -f1)
[ -n "$random_line" ] && [ -n "$apply_line" ] && [ "$random_line" -lt "$apply_line" ] ||
    fail 'Waypaper random selection must precede awww application of refreshed config'

# A stale namespace is not reused blindly: query fails, awww kill removes the
# stale session, and the coordinator starts one replacement daemon.
stale="$TEST_DIR/stale"
make_fixture "$stale"
touch "$stale/state/default.stale" "$stale/state/overview.stale"
: > "$stale/log/events"
run_session "$stale"
grep -Fq 'awww:kill' "$stale/log/events" ||
    fail 'a stale daemon must be retired through awww kill'
[ "$(grep -Fc 'daemon:--no-cache' "$stale/log/events")" -eq 2 ] ||
    fail 'each stale namespace must start exactly one replacement daemon'

# Color-only startup is bounded and quiet: no blur command or desktop notify
# path is reached when Waypaper cannot produce an image.
color="$TEST_DIR/color"
make_fixture "$color"
: > "$color/log/events"
run_session "$color" color
if grep -Eq '^(overview-blur|auto-blur):' "$color/log/events"; then
    fail 'blur startup must be skipped when the wallpaper remains color'
fi
if grep -Fq 'notify' "$color/log/session.log" 2>/dev/null; then
    fail 'color timeout must not emit a desktop notification'
fi

# Waypaper is optional during recovery.  A valid image recorded in its config
# is handed directly to awww even when the Waypaper executable is absent.
direct="$TEST_DIR/direct"
make_fixture "$direct"
mkdir -p "$direct/home/.config/waypaper"
printf 'configured wallpaper\n' > "$direct/home/configured.png"
cat > "$direct/home/.config/waypaper/config.ini" <<EOF
wallpaper = $direct/home/configured.png
EOF
PATH="$direct/bin:/usr/bin:/bin" \
    WALLPAPER_TEST_LOG="$direct/log/events" \
    WALLPAPER_TEST_STATE="$direct/state" \
    AWWW_BIN="$direct/bin/awww" \
    AWWW_DAEMON_BIN="$direct/bin/awww-daemon" \
    WAYPAPER_BIN="$direct/bin/waypaper-missing" \
    FEDORA_WALLPAPER_STATE_DIR="$direct/log" \
    FEDORA_WALLPAPER_LOG="$direct/log/session.log" \
    FEDORA_WALLPAPER_LOCK="$direct/log/session.lock" \
    FEDORA_WALLPAPER_OVERVIEW_SCRIPT="$direct/bin/overview-blur" \
    FEDORA_WALLPAPER_AUTO_BLUR_SCRIPT="$direct/bin/auto-blur" \
    FEDORA_WALLPAPER_QUERY_TIMEOUT=1 \
    FEDORA_WALLPAPER_READY_TIMEOUT=2 \
    FEDORA_WALLPAPER_IMAGE_TIMEOUT=1 \
    FEDORA_WALLPAPER_WAYPAPER_TIMEOUT=2 \
    HOME="$direct/home" \
    "$SESSION_SCRIPT"
grep -Fqx "awww:img $direct/home/configured.png" \
    "$direct/log/events" ||
    fail 'a valid configured image must be applied directly when Waypaper is absent'
if grep -Fq 'waypaper:' "$direct/log/events"; then
    fail 'Waypaper must not be invoked when its executable is absent'
fi

# Waypaper stores home-relative values with a literal `~/` prefix.  Expansion
# must remove that prefix before joining HOME; otherwise the recovery path
# becomes `$HOME/~/...` and silently misses a valid image.
tilde="$TEST_DIR/tilde"
make_fixture "$tilde"
mkdir -p "$tilde/home/Pictures/Wallpapers/.hidden" \
    "$tilde/home/.config/waypaper"
printf 'tilde wallpaper\n' > "$tilde/home/Pictures/Wallpapers/selected.png"
cat > "$tilde/home/.config/waypaper/config.ini" <<'EOF'
[Settings]
wallpaper = ~/Pictures/Wallpapers/selected.png
EOF
tilde_image=$(HOME="$tilde/home" FEDORA_WALLPAPER_CONFIG="$tilde/home/.config/waypaper/config.ini" \
    bash -c 'source "$1"; fedora_wallpaper_configured_image' bash "$SESSION_SCRIPT")
[ "$tilde_image" = "$tilde/home/Pictures/Wallpapers/selected.png" ] ||
    fail 'Waypaper ~/ paths must expand without a literal ~/ segment'

# A default state namespace can be left root-owned or otherwise unwritable by
# a previous privileged repair.  The initializer must keep this login
# functional by moving only its lock/log to a safe XDG runtime namespace and
# recording an explicit warning; explicit test state overrides remain strict.
runtime_fallback="$TEST_DIR/runtime-fallback"
make_fixture "$runtime_fallback"
mkdir -p "$runtime_fallback/home/.local/state/shorin-arch-setup" \
    "$runtime_fallback/runtime"
chmod 500 "$runtime_fallback/home/.local/state/shorin-arch-setup"
WALLPAPER_TEST_LOG="$runtime_fallback/log/events" \
    WALLPAPER_TEST_STATE="$runtime_fallback/state" \
    XDG_RUNTIME_DIR="$runtime_fallback/runtime" \
    AWWW_BIN="$runtime_fallback/bin/awww" \
    AWWW_DAEMON_BIN="$runtime_fallback/bin/awww-daemon" \
    WAYPAPER_BIN="$runtime_fallback/bin/waypaper" \
    FEDORA_WALLPAPER_QUERY_TIMEOUT=1 \
    FEDORA_WALLPAPER_READY_TIMEOUT=2 \
    FEDORA_WALLPAPER_IMAGE_TIMEOUT=1 \
    FEDORA_WALLPAPER_WAYPAPER_TIMEOUT=2 \
    HOME="$runtime_fallback/home" \
    "$SESSION_SCRIPT"
grep -Fq 'using session runtime state' \
    "$runtime_fallback/runtime/shorin-arch-setup/fedora-wallpaper-session.log" ||
    fail 'unwritable default state must record a runtime fallback warning'
[ ! -e "$runtime_fallback/home/.local/state/shorin-arch-setup/fedora-wallpaper-session.lock" ] ||
    fail 'runtime fallback must not write a lock into an unwritable home state namespace'

# A daemon may outlive the initializer.  It must not retain the initializer's
# flock descriptor, otherwise the second invocation is permanently skipped.
alive="$TEST_DIR/alive-daemon"
make_fixture "$alive"
: > "$alive/log/events"
mkdir -p "$alive/log/daemon-pids"
run_session_alive() {
    WALLPAPER_TEST_LOG="$alive/log/events" \
        WALLPAPER_TEST_STATE="$alive/state" \
        WALLPAPER_TEST_DAEMON_STAY_ALIVE=1 \
        WALLPAPER_TEST_DAEMON_PID_DIR="$alive/log/daemon-pids" \
        AWWW_BIN="$alive/bin/awww" \
        AWWW_DAEMON_BIN="$alive/bin/awww-daemon" \
        WAYPAPER_BIN="$alive/bin/waypaper" \
        FEDORA_WALLPAPER_STATE_DIR="$alive/log" \
        FEDORA_WALLPAPER_LOG="$alive/log/session.log" \
        FEDORA_WALLPAPER_LOCK="$alive/log/session.lock" \
        FEDORA_WALLPAPER_OVERVIEW_SCRIPT="$alive/bin/overview-blur" \
        FEDORA_WALLPAPER_AUTO_BLUR_SCRIPT="$alive/bin/auto-blur" \
        FEDORA_WALLPAPER_QUERY_TIMEOUT=1 \
        FEDORA_WALLPAPER_READY_TIMEOUT=2 \
        FEDORA_WALLPAPER_IMAGE_TIMEOUT=1 \
        FEDORA_WALLPAPER_WAYPAPER_TIMEOUT=2 \
        HOME="$alive/home" \
        "$SESSION_SCRIPT"
}
run_session_alive
[ -s "$alive/log/daemon-pids/default.pid" ] ||
    fail 'alive daemon fixture must record its default namespace pid'
run_session_alive
[ "$(grep -Fc 'waypaper:--random' "$alive/log/events")" -eq 2 ] ||
    fail 'second initializer must run while the first daemon remains alive'
for pid_file in "$alive"/log/daemon-pids/*.pid; do
    [ -f "$pid_file" ] || continue
    kill "$(cat "$pid_file")" 2>/dev/null || true
done

# Blur helpers may daemonize work after the initializer returns.  Their
# descendants must not retain the initializer's flock descriptor, and a
# second full session must still run while those descendants remain alive.
alive_helper="$TEST_DIR/alive-helper"
make_fixture "$alive_helper"
: > "$alive_helper/log/events"
mkdir -p "$alive_helper/log/blur-pids"
run_session_alive_helper() {
    WALLPAPER_TEST_LOG="$alive_helper/log/events" \
        WALLPAPER_TEST_STATE="$alive_helper/state" \
        WALLPAPER_TEST_BLUR_BACKGROUND=1 \
        WALLPAPER_TEST_BLUR_PID_DIR="$alive_helper/log/blur-pids" \
        AWWW_BIN="$alive_helper/bin/awww" \
        AWWW_DAEMON_BIN="$alive_helper/bin/awww-daemon" \
        WAYPAPER_BIN="$alive_helper/bin/waypaper" \
        FEDORA_WALLPAPER_STATE_DIR="$alive_helper/log" \
        FEDORA_WALLPAPER_LOG="$alive_helper/log/session.log" \
        FEDORA_WALLPAPER_LOCK="$alive_helper/log/session.lock" \
        FEDORA_WALLPAPER_OVERVIEW_SCRIPT="$alive_helper/bin/overview-blur" \
        FEDORA_WALLPAPER_AUTO_BLUR_SCRIPT="$alive_helper/bin/auto-blur" \
        FEDORA_WALLPAPER_QUERY_TIMEOUT=1 \
        FEDORA_WALLPAPER_READY_TIMEOUT=2 \
        FEDORA_WALLPAPER_IMAGE_TIMEOUT=1 \
        FEDORA_WALLPAPER_WAYPAPER_TIMEOUT=2 \
        HOME="$alive_helper/home" \
        "$SESSION_SCRIPT"
}
run_session_alive_helper
for pid_file in "$alive_helper"/log/blur-pids/*.pid; do
    [ -s "$pid_file" ] || fail 'alive blur helper fixture must record a child pid'
done
exec 9>"$alive_helper/log/session.lock"
flock -n 9 || fail 'alive blur helper must not retain the initializer lock'
exec 9>&-
run_session_alive_helper
[ "$(grep -Fc 'waypaper:--random' "$alive_helper/log/events")" -eq 2 ] ||
    fail 'second initializer must complete while blur helper children remain alive'
for pid_file in "$alive_helper"/log/blur-pids/*.pid; do
    [ -f "$pid_file" ] || continue
    kill "$(cat "$pid_file")" 2>/dev/null || true
done

# A missing NIRI_SOCKET must not be replaced by a guessed path when no active
# Niri candidate exists, and the helper wrapper must restore the old value.
niri_restore="$TEST_DIR/niri-restore"
make_fixture "$niri_restore"
mkdir -p "$niri_restore/runtime"
cat > "$niri_restore/bin/niri-helper" <<'AWEOF'
#!/usr/bin/env bash
printf 'niri-socket:%s\n' "${NIRI_SOCKET-<unset>}" >> "${WALLPAPER_TEST_LOG:?}"
AWEOF
chmod 755 "$niri_restore/bin/niri-helper"
niri_restore_output=$(WALLPAPER_TEST_LOG="$niri_restore/log/events" \
    FEDORA_WALLPAPER_LOG="$niri_restore/log/session.log" \
    XDG_RUNTIME_DIR="$niri_restore/runtime" \
    WAYLAND_DISPLAY=wayland-1 \
    NIRI_SOCKET="$niri_restore/runtime/old.sock" \
    HOME="$niri_restore/home" \
    bash -c 'source "$1"; fedora_wallpaper_run_niri_helper niri-helper 1 "$2"; printf "restored:%s\\n" "${NIRI_SOCKET-<unset>}"' \
    bash "$SESSION_SCRIPT" "$niri_restore/bin/niri-helper")
grep -Fqx "niri-socket:$niri_restore/runtime/old.sock" "$niri_restore/log/events" ||
    fail 'missing NIRI_SOCKET must remain unchanged when no Niri candidate exists'
grep -Fq 'no active niri socket candidate found' "$niri_restore/log/session.log" ||
    fail 'missing Niri candidate must record a warning'
grep -Fqx "restored:$niri_restore/runtime/old.sock" <<< "$niri_restore_output" ||
    fail 'NIRI_SOCKET wrapper must restore the original value after helper execution'

# A stale socket that never becomes ready is bounded by the retry budget and
# must surface as a session failure rather than being swallowed.
failed="$TEST_DIR/failed"
make_fixture "$failed"
printf '0\n' > "$failed/log/query-count"
if WALLPAPER_TEST_LOG="$failed/log/events" \
    WALLPAPER_TEST_STATE="$failed/state" \
    WALLPAPER_DELAY_MODE=1 \
    WALLPAPER_DELAY_NEVER_READY=1 \
    WALLPAPER_QUERY_COUNT_FILE="$failed/log/query-count" \
    AWWW_BIN="$failed/bin/awww" \
    AWWW_DAEMON_BIN="$failed/bin/awww-daemon" \
    WAYPAPER_BIN="$failed/bin/waypaper" \
    FEDORA_WALLPAPER_STATE_DIR="$failed/log" \
    FEDORA_WALLPAPER_LOG="$failed/log/session.log" \
    FEDORA_WALLPAPER_LOCK="$failed/log/session.lock" \
    FEDORA_WALLPAPER_QUERY_TIMEOUT=1 \
    FEDORA_WALLPAPER_READY_TIMEOUT=1 \
    FEDORA_WALLPAPER_IMAGE_TIMEOUT=1 \
    FEDORA_WALLPAPER_MAX_RETRIES=2 \
    HOME="$failed/home" \
    "$SESSION_SCRIPT"; then
    fail 'unready stale daemon must produce a failure status'
fi
[ "$(grep -Fxc 'daemon:--no-cache' "$failed/log/events")" -eq 2 ] ||
    fail 'unready stale daemon must honor the bounded retry budget'

# QuickShell's first query is a quiet no-op while a daemon is unavailable, but
# forwards the normal query output once the namespace becomes ready.
wrapper="$TEST_DIR/shorin-fedora-awww-query"
cp "$SESSION_SCRIPT" "$wrapper"
chmod 755 "$wrapper"
query_output=$(WALLPAPER_TEST_LOG="$TEST_DIR/query.log" \
    WALLPAPER_TEST_STATE="$TEST_DIR/query-state" \
    AWWW_BIN="$happy/bin/awww" \
    FEDORA_WALLPAPER_QUERY_TIMEOUT=1 \
    FEDORA_WALLPAPER_READY_TIMEOUT=1 \
    FEDORA_WALLPAPER_IMAGE_TIMEOUT=1 \
    HOME="$happy/home" \
    "$wrapper" 2>"$TEST_DIR/query.err" || true)
[ -z "$query_output" ] && [ ! -s "$TEST_DIR/query.err" ] ||
    fail 'first QuickShell query must suppress unavailable-daemon errors'
mkdir -p "$TEST_DIR/query-state"
touch "$TEST_DIR/query-state/default.ready"
touch "$TEST_DIR/query-state/default.image"
query_output=$(WALLPAPER_TEST_LOG="$TEST_DIR/query.log" \
    WALLPAPER_TEST_STATE="$TEST_DIR/query-state" \
    AWWW_BIN="$happy/bin/awww" \
    FEDORA_WALLPAPER_QUERY_TIMEOUT=1 \
    FEDORA_WALLPAPER_READY_TIMEOUT=1 \
    FEDORA_WALLPAPER_IMAGE_TIMEOUT=1 \
    HOME="$happy/home" \
    "$wrapper")
grep -Fq 'currently displaying: image:' <<< "$query_output" ||
    fail 'ready QuickShell query must preserve awww image output'

# One wrapper call must tolerate a daemon becoming ready first and changing
# from color to image afterward.  The query counter proves both bounded waits
# happened inside the same invocation rather than through a caller retry.
delayed="$TEST_DIR/delayed-wrapper"
make_fixture "$delayed"
: > "$delayed/log/events"
printf '0\n' > "$delayed/log/query-count"
delayed_output=$(WALLPAPER_TEST_LOG="$delayed/log/events" \
    WALLPAPER_TEST_STATE="$delayed/state" \
    WALLPAPER_DELAY_MODE=1 \
    WALLPAPER_QUERY_COUNT_FILE="$delayed/log/query-count" \
    WALLPAPER_READY_AFTER=3 \
    WALLPAPER_IMAGE_AFTER=6 \
    AWWW_BIN="$delayed/bin/awww" \
    FEDORA_WALLPAPER_QUERY_TIMEOUT=1 \
    FEDORA_WALLPAPER_READY_TIMEOUT=2 \
    FEDORA_WALLPAPER_IMAGE_TIMEOUT=2 \
    HOME="$delayed/home" \
    "$wrapper" 2>"$delayed/log/query.err")
grep -Fq 'currently displaying: image: /tmp/delayed-wallpaper.png' \
    <<< "$delayed_output" ||
    fail 'one wrapper call must wait from daemon readiness through image state'
[ "$(cat "$delayed/log/query-count")" -ge 6 ] ||
    fail 'delayed wrapper test must exercise both readiness and image polling'
[ ! -s "$delayed/log/query.err" ] ||
    fail 'delayed wrapper polling must keep daemon errors quiet'

not_ready="$TEST_DIR/not-ready-wrapper"
make_fixture "$not_ready"
printf '0\n' > "$not_ready/log/query-count"
not_ready_output=$(WALLPAPER_TEST_LOG="$not_ready/log/events" \
    WALLPAPER_TEST_STATE="$not_ready/state" \
    WALLPAPER_DELAY_MODE=1 \
    WALLPAPER_DELAY_NEVER_READY=1 \
    WALLPAPER_QUERY_COUNT_FILE="$not_ready/log/query-count" \
    AWWW_BIN="$not_ready/bin/awww" \
    FEDORA_WALLPAPER_QUERY_TIMEOUT=1 \
    FEDORA_WALLPAPER_READY_TIMEOUT=1 \
    FEDORA_WALLPAPER_IMAGE_TIMEOUT=1 \
    HOME="$not_ready/home" \
    "$wrapper" 2>"$not_ready/log/query.err")
[ -z "$not_ready_output" ] && [ ! -s "$not_ready/log/query.err" ] ||
    fail 'daemon-not-ready wrapper timeout must remain silent'

color_wrapper="$TEST_DIR/color-wrapper"
make_fixture "$color_wrapper"
printf '0\n' > "$color_wrapper/log/query-count"
color_output=$(WALLPAPER_TEST_LOG="$color_wrapper/log/events" \
    WALLPAPER_TEST_STATE="$color_wrapper/state" \
    WALLPAPER_DELAY_MODE=1 \
    WALLPAPER_DELAY_NEVER_IMAGE=1 \
    WALLPAPER_QUERY_COUNT_FILE="$color_wrapper/log/query-count" \
    WALLPAPER_READY_AFTER=1 \
    WALLPAPER_IMAGE_AFTER=999 \
    AWWW_BIN="$color_wrapper/bin/awww" \
    FEDORA_WALLPAPER_QUERY_TIMEOUT=1 \
    FEDORA_WALLPAPER_READY_TIMEOUT=1 \
    FEDORA_WALLPAPER_IMAGE_TIMEOUT=1 \
    HOME="$color_wrapper/home" \
    "$wrapper" 2>"$color_wrapper/log/query.err")
[ -z "$color_output" ] && [ ! -s "$color_wrapper/log/query.err" ] ||
    fail 'color-only wrapper timeout must remain silent'

# The transform owns exactly one startup initializer, rewrites the lockscreen
# launch and leaves ordinary QuickShell startup/bind shapes intact.
initializer="$TEST_DIR/home/.local/bin/shorin-fedora-wallpaper-session"
mkdir -p "$(dirname "$initializer")"
cat > "$TEST_DIR/config.kdl" <<AWEOF
spawn-at-startup "awww-daemon"
spawn-at-startup "waypaper --random"
spawn-at-startup "niri_set_overview_blur_dark_bg.sh"
spawn-at-startup "quickshell -p ~/.config/quickshell/lockscreen/shell.qml"
spawn-at-startup "quickshell &"
AWEOF
cat > "$TEST_DIR/binds.kdl" <<'AWEOF'
binds {
    Mod+Alt+L { spawn-sh "/usr/bin/quickshell -p ~/.config/quickshell/lockscreen/shell.qml"; }
}
AWEOF
awk -v initializer="$initializer" -v wallpaper_startup=1 \
    -f "$ROOT_DIR/scripts/modules/desktop-niri/fedora-config-compatibility.awk" \
    "$TEST_DIR/config.kdl" > "$TEST_DIR/config.out"
awk -v initializer="$initializer" -v wallpaper_startup=0 \
    -f "$ROOT_DIR/scripts/modules/desktop-niri/fedora-config-compatibility.awk" \
    "$TEST_DIR/binds.kdl" > "$TEST_DIR/binds.out"
[ "$(grep -Fc "$initializer" "$TEST_DIR/config.out")" -eq 1 ] ||
    fail 'Fedora startup transform must emit one managed initializer'
if grep -Eq 'awww-daemon|waypaper|niri_set_overview_blur_dark_bg' \
    "$TEST_DIR/config.out"; then
    fail 'Fedora startup transform must remove the old parallel wallpaper chain'
fi
grep -Fq 'spawn-at-startup "lockscreen.sh"' "$TEST_DIR/config.out" ||
    fail 'Fedora startup transform must route lockscreen through its wrapper'
grep -Fq 'spawn-sh "lockscreen.sh"' "$TEST_DIR/binds.out" ||
    fail 'Mod+Alt+L must route through the lockscreen wrapper'

# Fedora-only transform is a no-op on Arch.
printf '%s\n' 'spawn-at-startup "swww-daemon"' > "$TEST_DIR/arch.kdl"
cp "$TEST_DIR/arch.kdl" "$TEST_DIR/arch.before"
awk -f "$ROOT_DIR/scripts/modules/desktop-niri/fedora-config-compatibility.awk" \
    "$TEST_DIR/arch.kdl" > "$TEST_DIR/arch.after"
cmp -s "$TEST_DIR/arch.before" "$TEST_DIR/arch.after" ||
    fail 'Arch wallpaper startup must remain untouched'

printf 'PASS: Fedora wallpaper readiness/session coordinator contract\n'
