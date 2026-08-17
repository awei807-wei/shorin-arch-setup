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
AWEOF
    cat > "$root/bin/waypaper" <<'AWEOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf 'waypaper:%s\n' "$*" >> "${WALLPAPER_TEST_LOG:?}"
if [ "${WALLPAPER_TEST_MODE:-image}" = image ]; then
    touch "${WALLPAPER_TEST_STATE:?}/default.image"
fi
AWEOF
    cat > "$root/bin/overview-blur" <<'AWEOF'
#!/usr/bin/env bash
printf 'overview-blur:%s\n' "$*" >> "${WALLPAPER_TEST_LOG:?}"
AWEOF
    cat > "$root/bin/auto-blur" <<'AWEOF'
#!/usr/bin/env bash
printf 'auto-blur:%s\n' "$*" >> "${WALLPAPER_TEST_LOG:?}"
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
