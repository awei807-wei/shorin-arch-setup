#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SHORIN_DISTRO=arch
TEST_DIR=$(mktemp -d)
TARGET_USER=$(id -un)
HOME_DIR="$TEST_DIR/nonstandard-home"
BIN_DIR="$TEST_DIR/bin"
VCP_DIR="$TEST_DIR/custom/VCPChat"
VCP_BACKUP_SCRIPT="$TEST_DIR/custom/vcp-backup.py"
VCP_DESKTOP_FILE="$TEST_DIR/custom/vcp.desktop"
VCP_SUDOERS_FILE="$TEST_DIR/custom/vcp.sudoers"
VCP_PYTHON="$BIN_DIR/python"
VCP_NPM="$BIN_DIR/npm"
export TARGET_USER HOME_DIR VCP_DIR VCP_BACKUP_SCRIPT VCP_DESKTOP_FILE
export VCP_SUDOERS_FILE VCP_PYTHON VCP_NPM
export SHORIN_USER_RUNTIME_ROOT="$TEST_DIR/runtime"

cleanup() {
    find "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

mkdir -p "$HOME_DIR" "$BIN_DIR" "$VCP_DIR"
cat > "$BIN_DIR/npm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$VCP_PYTHON" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN_DIR/npm" "$VCP_PYTHON"
export PATH="$BIN_DIR:$PATH"
printf '{}\n' > "$VCP_DIR/package.json"
printf 'print("backup")\n' > "$VCP_BACKUP_SCRIPT"

source "$ROOT_DIR/scripts/lib/core.sh"
source "$ROOT_DIR/scripts/modules/vcp/contract.sh"
vcp_contract_init

status=0
vcp_backup_timer_active_status 4 || status=$?
[ "$status" -eq 1 ] ||
    fail 'a missing VCP user timer must be repairable drift'
status=0
vcp_backup_timer_active_status 1 || status=$?
[ "$status" -eq 2 ] ||
    fail 'an unexpected user systemd failure must remain an inspection error'

mkdir -p "$VCP_USER_UNIT_DIR/timers.target.wants"
vcp_backup_service_contract > "$VCP_BACKUP_SERVICE"
vcp_backup_timer_contract > "$VCP_BACKUP_TIMER"
vcp_sudoers_contract > "$VCP_SUDOERS_FILE"
vcp_desktop_contract > "$VCP_DESKTOP_FILE"
ln -s ../vcp-backup.timer \
    "$VCP_USER_UNIT_DIR/timers.target.wants/vcp-backup.timer"

status=0
output=$(SHORIN_ROOT="$ROOT_DIR" bash \
    "$ROOT_DIR/scripts/modules/vcp.sh" verify 2>&1) || status=$?
case "$status" in
    0|20) ;;
    *) fail 'exact VCP targets at custom paths must verify' ;;
esac

printf 'stale service\n' > "$VCP_BACKUP_SERVICE"
status=0
output=$(SHORIN_ROOT="$ROOT_DIR" bash \
    "$ROOT_DIR/scripts/modules/vcp.sh" verify 2>&1) || status=$?
[ "$status" -eq 1 ] || fail 'nonempty stale VCP service must fail verification'
grep -Fq file:vcp-backup-service <<< "$output" ||
    fail 'stale VCP service must identify its contract target'
vcp_backup_service_contract > "$VCP_BACKUP_SERVICE"

printf 'invalid sudoers\n' > "$VCP_SUDOERS_FILE"
status=0
output=$(SHORIN_ROOT="$ROOT_DIR" bash \
    "$ROOT_DIR/scripts/modules/vcp.sh" verify 2>&1) || status=$?
[ "$status" -eq 1 ] || fail 'nonempty stale VCP sudoers must fail verification'
grep -Fq file:vcp-backup-sudoers <<< "$output" ||
    fail 'stale VCP sudoers must identify its contract target'
vcp_sudoers_contract > "$VCP_SUDOERS_FILE"

status=0
output=$(SHORIN_ROOT="$ROOT_DIR" VCP_PYTHON="$TEST_DIR/missing-python" \
    bash "$ROOT_DIR/scripts/modules/vcp.sh" verify 2>&1) || status=$?
[ "$status" -eq 1 ] || fail 'missing Python must fail VCP backup verification'
grep -Fq vcp-backup-python-missing <<< "$output" ||
    fail 'missing Python must report the prerequisite reason'

printf 'stale desktop\n' > "$VCP_DESKTOP_FILE"
status=0
output=$(SHORIN_ROOT="$ROOT_DIR" bash \
    "$ROOT_DIR/scripts/modules/vcp.sh" verify 2>&1) || status=$?
[ "$status" -eq 1 ] || fail 'nonempty stale desktop entry must fail verification'
grep -Fq file:vcp-desktop <<< "$output" ||
    fail 'stale desktop entry must identify its contract target'

vcp_desktop_contract > "$VCP_DESKTOP_FILE"
find "$VCP_BACKUP_SCRIPT" -delete
status=0
output=$(SHORIN_ROOT="$ROOT_DIR" bash \
    "$ROOT_DIR/scripts/modules/vcp.sh" verify 2>&1) || status=$?
[ "$status" -eq 1 ] ||
    fail 'orphaned VCP timer artifacts must not be reported as skipped'
grep -Fq vcp-backup-script-missing <<< "$output" ||
    fail 'orphaned VCP timer must report the missing source script'

printf 'PASS: VCP module contract\n'
