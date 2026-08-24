#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SMOKE="$ROOT_DIR/scripts/checks/niri-runtime-smoke.sh"
TEST_DIR=$(mktemp -d)
BIN_DIR="$TEST_DIR/bin"
RUNTIME_DIR="$TEST_DIR/run/user/$(id -u)"
RENDER_DIR="$TEST_DIR/dev/dri"
PROC_DIR="$TEST_DIR/proc"
TARGET_USER=$(id -un)
mkdir -p "$BIN_DIR" "$RUNTIME_DIR" "$RENDER_DIR"

cleanup() {
    if [ -n "${SOCKET_SERVER_PID:-}" ]; then
        kill "$SOCKET_SERVER_PID" 2>/dev/null || true
        wait "$SOCKET_SERVER_PID" 2>/dev/null || true
    fi
    find "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

cat > "$BIN_DIR/loginctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

case "${1:-}" in
    list-sessions)
        [ "${NIRI_TEST_SESSION_PRESENT:-1}" -eq 1 ] || exit 0
        printf '18 %s %s seat0 4242 user tty2 no -\n' \
            "${NIRI_TEST_UID:?}" "${NIRI_TEST_USER:?}"
        ;;
    show-session)
        [ "${2:-}" = 18 ] || exit 1
        [ "${3:-}" = -p ] && [ "${5:-}" = --value ] || exit 64
        case "$4" in
            User) printf '%s\n' "${NIRI_TEST_UID:?}" ;;
            Active) printf '%s\n' "${NIRI_TEST_ACTIVE:-yes}" ;;
            State) printf '%s\n' "${NIRI_TEST_STATE:-active}" ;;
            Remote) printf '%s\n' "${NIRI_TEST_REMOTE:-no}" ;;
            Seat) printf '%s\n' "${NIRI_TEST_SEAT:-seat0}" ;;
            Type) printf '%s\n' "${NIRI_TEST_TYPE:-wayland}" ;;
            Desktop) printf '%s\n' "${NIRI_TEST_DESKTOP:-niri}" ;;
            Class) printf '%s\n' "${NIRI_TEST_CLASS:-user}" ;;
            Service) printf '%s\n' "${NIRI_TEST_SERVICE:-plasmalogin}" ;;
            VTNr) printf '%s\n' "${NIRI_TEST_VT:-2}" ;;
            *) exit 64 ;;
        esac
        ;;
    *) exit 64 ;;
esac
EOF

cat > "$BIN_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

[ "${1:-}" = --user ] || exit 64
case "${2:-}" in
    is-active)
        [ "${3:-}" = --quiet ] || exit 64
        case "${4:-}" in
            niri.service) [ "${NIRI_TEST_SERVICE_ACTIVE:-1}" -eq 1 ] ;;
            graphical-session.target)
                [ "${NIRI_TEST_GRAPHICAL_ACTIVE:-1}" -eq 1 ]
                ;;
            *) exit 64 ;;
        esac
        ;;
    show)
        [ "${3:-}" = niri.service ] && [ "${4:-}" = -p ] &&
            [ "${6:-}" = --value ] || exit 64
        case "$5" in
            MainPID) printf '%s\n' "${NIRI_TEST_PID:?}" ;;
            NRestarts) printf '%s\n' "${NIRI_TEST_RESTARTS:-0}" ;;
            *) exit 64 ;;
        esac
        ;;
    show-environment)
        printf 'NIRI_SOCKET=%s\n' \
            "${NIRI_TEST_SOCKET_OVERRIDE:-${NIRI_TEST_SOCKET:?}}"
        printf '%s\n' 'WAYLAND_DISPLAY=wayland-1' 'XDG_CURRENT_DESKTOP=niri'
        ;;
    *) exit 64 ;;
esac
EOF

cat > "$BIN_DIR/niri" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

[ "${1:-}" = msg ] && [ "${2:-}" = --json ] &&
    [ "${3:-}" = outputs ] || exit 64
[ -z "${NIRI_TEST_NIRI_SLEEP:-}" ] || sleep "$NIRI_TEST_NIRI_SLEEP"
cat "${NIRI_TEST_OUTPUTS:?}"
EOF

cat > "$BIN_DIR/journalctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [ -n "${NIRI_TEST_RENDER_NODE:-}" ]; then
    printf 'INFO niri::backend::tty: using as the render node: "%s"\n' \
        "$NIRI_TEST_RENDER_NODE"
fi
EOF
chmod 755 "$BIN_DIR/loginctl" "$BIN_DIR/systemctl" \
    "$BIN_DIR/niri" "$BIN_DIR/journalctl"

python3 - "$RUNTIME_DIR/bus" "$RUNTIME_DIR/niri.wayland-1.test.sock" <<'PY' &
import signal
import socket
import sys

sockets = []
for path in sys.argv[1:]:
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(1)
    sockets.append(server)
signal.pause()
PY
SOCKET_SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$RUNTIME_DIR/bus" ] &&
        [ -S "$RUNTIME_DIR/niri.wayland-1.test.sock" ] && break
    sleep 0.1
done
[ -S "$RUNTIME_DIR/bus" ] || fail 'fixture user bus socket was not created'
[ -S "$RUNTIME_DIR/niri.wayland-1.test.sock" ] ||
    fail 'fixture Niri socket was not created'

OUTPUTS_FILE="$TEST_DIR/outputs.json"
VALID_OUTPUTS_JSON='{"Virtual-1":{"current_mode":0,"logical":{"x":0,"y":0,"width":1280,"height":800}}}'
printf '%s\n' "$VALID_OUTPUTS_JSON" > "$OUTPUTS_FILE"
touch "$RENDER_DIR/renderD128"
mkdir -p "$PROC_DIR/$SOCKET_SERVER_PID/fd"
ln -s "$RENDER_DIR/renderD128" "$PROC_DIR/$SOCKET_SERVER_PID/fd/7"

export NIRI_TEST_UID=$(id -u) NIRI_TEST_USER="$TARGET_USER"
export NIRI_TEST_PID="$SOCKET_SERVER_PID"
export NIRI_TEST_SOCKET="$RUNTIME_DIR/niri.wayland-1.test.sock"
export NIRI_TEST_OUTPUTS="$OUTPUTS_FILE"
export NIRI_TEST_RENDER_NODE="$RENDER_DIR/renderD128"
export NIRI_RUNTIME_LOGINCTL="$BIN_DIR/loginctl"
export NIRI_RUNTIME_SYSTEMCTL="$BIN_DIR/systemctl"
export NIRI_RUNTIME_NIRI="$BIN_DIR/niri"
export NIRI_RUNTIME_JOURNALCTL="$BIN_DIR/journalctl"
export NIRI_RUNTIME_USER_ROOT="$TEST_DIR/run/user"
export NIRI_RUNTIME_RENDER_ROOT="$RENDER_DIR"
export NIRI_RUNTIME_PROC_ROOT="$PROC_DIR"
export NIRI_RUNTIME_TIMEOUT=0.2s

run_smoke() {
    local output_file=$1
    local result=0

    bash "$SMOKE" --user "$TARGET_USER" > "$output_file" 2>&1 || result=$?
    return "$result"
}

SUCCESS_OUTPUT="$TEST_DIR/success.out"
run_smoke "$SUCCESS_OUTPUT" || fail 'healthy active Niri fixture must pass'
grep -Fq 'OK: session=18 seat=seat0 service=plasmalogin vt=2' \
    "$SUCCESS_OUTPUT" || fail 'session evidence is missing from smoke output'
grep -Fq 'OK: outputs={"Virtual-1"' "$SUCCESS_OUTPUT" ||
    fail 'connected-output evidence is missing from smoke output'
grep -Fq "OK: render-node=$RENDER_DIR/renderD128" "$SUCCESS_OUTPUT" ||
    fail 'render-node evidence is missing from smoke output'

printf '%s\n' '{}' > "$OUTPUTS_FILE"
status=0
run_smoke "$TEST_DIR/no-outputs.out" || status=$?
[ "$status" -eq 1 ] || fail "empty outputs must fail an active session (got $status)"
grep -Fq 'Niri reports no connected outputs' "$TEST_DIR/no-outputs.out" ||
    fail 'empty-output failure must be actionable'

printf '%s\n' \
    '{"Virtual-1":{"current_mode":null,"logical":{"width":1280,"height":800}}}' \
    > "$OUTPUTS_FILE"
status=0
run_smoke "$TEST_DIR/null-mode.out" || status=$?
[ "$status" -eq 1 ] || fail "null current_mode must fail (got $status)"
grep -Fq 'non-negative integer current_mode' "$TEST_DIR/null-mode.out" ||
    fail 'invalid-current-mode failure must be actionable'

printf '%s\n' '{"Virtual-1":{"current_mode":0,"logical":null}}' \
    > "$OUTPUTS_FILE"
status=0
run_smoke "$TEST_DIR/null-logical.out" || status=$?
[ "$status" -eq 1 ] || fail "null logical geometry must fail (got $status)"
grep -Fq 'logical geometry object' "$TEST_DIR/null-logical.out" ||
    fail 'missing-logical-geometry failure must be actionable'

printf '%s\n' \
    '{"Virtual-1":{"current_mode":0,"logical":{"width":0,"height":800}}}' \
    > "$OUTPUTS_FILE"
status=0
run_smoke "$TEST_DIR/zero-logical-size.out" || status=$?
[ "$status" -eq 1 ] || fail "zero logical width must fail (got $status)"
grep -Fq 'positive logical width and height' \
    "$TEST_DIR/zero-logical-size.out" ||
    fail 'invalid-logical-size failure must be actionable'

printf '%s\n' '{"Virtual-1":' > "$OUTPUTS_FILE"
status=0
run_smoke "$TEST_DIR/malformed-json.out" || status=$?
[ "$status" -eq 1 ] || fail "malformed outputs JSON must fail (got $status)"
grep -Fq 'outputs response is malformed JSON' \
    "$TEST_DIR/malformed-json.out" ||
    fail 'malformed-JSON failure must be actionable'

printf '%s\n' "$VALID_OUTPUTS_JSON" > "$OUTPUTS_FILE"

export NIRI_TEST_SERVICE_ACTIVE=0
status=0
run_smoke "$TEST_DIR/inactive-service.out" || status=$?
[ "$status" -eq 1 ] || fail "inactive niri.service must fail (got $status)"
unset NIRI_TEST_SERVICE_ACTIVE

export NIRI_TEST_GRAPHICAL_ACTIVE=0
status=0
run_smoke "$TEST_DIR/inactive-graphical.out" || status=$?
[ "$status" -eq 1 ] ||
    fail "inactive graphical-session.target must fail (got $status)"
unset NIRI_TEST_GRAPHICAL_ACTIVE

export NIRI_TEST_RESTARTS=1
status=0
run_smoke "$TEST_DIR/restarted-service.out" || status=$?
[ "$status" -eq 1 ] || fail "restarted niri.service must fail (got $status)"
grep -Fq 'restarted during this user-manager lifetime: 1' \
    "$TEST_DIR/restarted-service.out" ||
    fail 'restart-count failure must be actionable'
unset NIRI_TEST_RESTARTS

export NIRI_TEST_NIRI_SLEEP=2
status=0
run_smoke "$TEST_DIR/hung-ipc.out" || status=$?
[ "$status" -eq 1 ] || fail "hung Niri IPC must fail (got $status)"
grep -Fq 'timed out after 0.2s' "$TEST_DIR/hung-ipc.out" ||
    fail 'hung Niri IPC must report its timeout'
unset NIRI_TEST_NIRI_SLEEP

export NIRI_TEST_SOCKET_OVERRIDE="$RUNTIME_DIR/missing.sock"
status=0
run_smoke "$TEST_DIR/missing-socket.out" || status=$?
[ "$status" -eq 1 ] || fail "missing NIRI_SOCKET must fail (got $status)"
unset NIRI_TEST_SOCKET_OVERRIDE

export NIRI_TEST_RENDER_NODE="$RENDER_DIR/missing-renderD129"
status=0
run_smoke "$TEST_DIR/no-render.out" || status=$?
[ "$status" -eq 1 ] || fail "missing render evidence must fail (got $status)"
grep -Fq 'no renderer or DRM device evidence' "$TEST_DIR/no-render.out" ||
    fail 'render-evidence failure must be actionable'
export NIRI_TEST_RENDER_NODE="$RENDER_DIR/renderD128"

rm -f "$PROC_DIR/$SOCKET_SERVER_PID/fd/7"
status=0
run_smoke "$TEST_DIR/no-current-drm-fd.out" || status=$?
[ "$status" -eq 1 ] ||
    fail "journal-only render evidence must fail without a current DRM fd (got $status)"
grep -Fq 'no renderer or DRM device evidence' \
    "$TEST_DIR/no-current-drm-fd.out" ||
    fail 'missing-current-DRM-fd failure must be actionable'
ln -s "$RENDER_DIR/renderD128" "$PROC_DIR/$SOCKET_SERVER_PID/fd/7"

export NIRI_TEST_SESSION_PRESENT=0
status=0
run_smoke "$TEST_DIR/greeter.out" || status=$?
[ "$status" -eq 2 ] || fail "greeter/no-session state must skip (got $status)"
grep -Fq 'SKIP: no active local Niri seat session' "$TEST_DIR/greeter.out" ||
    fail 'greeter skip must be explicit'
unset NIRI_TEST_SESSION_PRESENT

export NIRI_TEST_REMOTE=yes
status=0
run_smoke "$TEST_DIR/remote.out" || status=$?
[ "$status" -eq 2 ] || fail "remote session must not satisfy seat smoke (got $status)"
unset NIRI_TEST_REMOTE

printf 'PASS: Niri active-seat runtime smoke contract\n'
