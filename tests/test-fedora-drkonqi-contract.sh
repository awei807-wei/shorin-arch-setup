#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" "${BASH_SOURCE[0]:-unknown}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
BIN_DIR="$TEST_DIR/bin"
TARGET_USER=$(id -un)
HOME_DIR="$TEST_DIR/home"
export SHORIN_ROOT="$ROOT_DIR" SHORIN_DISTRO=fedora SHORIN_MODE=repair SHORIN_READ_ONLY=0 TARGET_USER HOME_DIR
mkdir -p "$BIN_DIR" "$HOME_DIR"
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

cat > "$BIN_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${DRKONQI_SYSTEMCTL_LOG:?}"
[ "${1:-}" = --user ] || exit 97
case "${2:-}" in
    daemon-reload) exit "${DRKONQI_RELOAD_STATUS:-0}" ;;
    stop)
        [ "${3:-}" = drkonqi-coredump-launcher.socket ] || exit 96
        [ "${4:-}" != --now ] || exit 95
        printf '%s\n' inactive > "${DRKONQI_STATE:?}"
        exit "${DRKONQI_STOP_STATUS:-0}"
        ;;
    reset-failed)
        [ "${3:-}" = drkonqi-coredump-launcher.socket ] || exit 94
        if [ "${DRKONQI_RESET_FAILED_STATUS:-0}" -ne 0 ]; then
            printf '%s\n' "${DRKONQI_RESET_FAILED_OUTPUT:-}" >&2
        fi
        exit "${DRKONQI_RESET_FAILED_STATUS:-0}"
        ;;
    is-active)
        [ "${3:-}" = --quiet ] || exit 93
        [ "${4:-}" = drkonqi-coredump-launcher.socket ] || exit 92
        [ "$(< "${DRKONQI_STATE:?}")" = active ]
        ;;
    *) exit 91 ;;
esac
EOF
chmod 755 "$BIN_DIR/systemctl"
export PATH="$BIN_DIR:$PATH"
export DRKONQI_SYSTEMCTL_LOG="$TEST_DIR/systemctl.log" DRKONQI_STATE="$TEST_DIR/state"
export DRKONQI_RELOAD_STATUS=0 DRKONQI_STOP_STATUS=0 DRKONQI_RESET_FAILED_STATUS=0
printf '%s\n' inactive > "$DRKONQI_STATE"

source "$ROOT_DIR/scripts/modules/desktop-niri/targets.sh"
desktop_niri_contract_init
niri_user_bus_is_available() { return "${DRKONQI_BUS_STATUS:-0}"; }
grep -Fq 'config:fedora-drkonqi' "$ROOT_DIR/scripts/modules/desktop-niri.sh" || fail 'desktop check/verify must expose the DrKonqi contract'

: > "$DRKONQI_SYSTEMCTL_LOG"
ensure_niri_fedora_drkonqi "$TARGET_USER" || fail 'online DrKonqi convergence failed'
[ -L "$NIRI_FEDORA_DRKONQI_MASK_FILE" ] || fail 'DrKonqi mask must be a symlink'
[ "$(readlink "$NIRI_FEDORA_DRKONQI_MASK_FILE")" = /dev/null ] || fail 'DrKonqi mask must target /dev/null'
grep -Fqx -- '--user daemon-reload' "$DRKONQI_SYSTEMCTL_LOG" || fail 'online convergence must reload the user manager'
grep -Fqx -- '--user stop drkonqi-coredump-launcher.socket' "$DRKONQI_SYSTEMCTL_LOG" || fail 'online convergence must stop the socket unit'
if grep -Fq -- '--now' "$DRKONQI_SYSTEMCTL_LOG"; then fail 'DrKonqi convergence must not use stop --now'; fi
grep -Fqx -- '--user reset-failed drkonqi-coredump-launcher.socket' "$DRKONQI_SYSTEMCTL_LOG" || fail 'online convergence must reset failures'
niri_fedora_drkonqi_satisfied "$TARGET_USER" || fail 'online DrKonqi state must satisfy verification'

mask_target=$(readlink "$NIRI_FEDORA_DRKONQI_MASK_FILE")
ensure_niri_fedora_drkonqi "$TARGET_USER" || fail 'idempotent online DrKonqi convergence failed'
[ "$(readlink "$NIRI_FEDORA_DRKONQI_MASK_FILE")" = "$mask_target" ] || fail 'idempotent convergence changed the mask target'

rm -f "$NIRI_FEDORA_DRKONQI_MASK_FILE"
: > "$DRKONQI_SYSTEMCTL_LOG"
DRKONQI_BUS_STATUS=1
ensure_niri_fedora_drkonqi "$TARGET_USER" || fail 'offline DrKonqi convergence failed'
[ ! -s "$DRKONQI_SYSTEMCTL_LOG" ] || fail 'offline convergence must not call systemctl'
niri_fedora_drkonqi_satisfied "$TARGET_USER" || fail 'offline masked DrKonqi state must satisfy verification'

rm -f "$NIRI_FEDORA_DRKONQI_MASK_FILE"
ln -s "$TEST_DIR/not-null" "$NIRI_FEDORA_DRKONQI_MASK_FILE"
status=0
ensure_niri_fedora_drkonqi "$TARGET_USER" || status=$?
[ "$status" -ne 0 ] || fail 'wrong DrKonqi symlink target must be rejected'
[ "$(readlink "$NIRI_FEDORA_DRKONQI_MASK_FILE")" = "$TEST_DIR/not-null" ] || fail 'wrong DrKonqi symlink must not be replaced'

rm -f "$NIRI_FEDORA_DRKONQI_MASK_FILE"
DRKONQI_BUS_STATUS=0 DRKONQI_RELOAD_STATUS=7
status=0
ensure_niri_fedora_drkonqi "$TARGET_USER" || status=$?
[ "$status" -eq 7 ] || fail "user-manager reload failure must remain visible (got $status)"

printf 'PASS: Fedora DrKonqi user socket mask contract\n'
