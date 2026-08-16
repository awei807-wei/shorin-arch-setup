#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SHORIN_DISTRO=arch
TEST_DIR=$(mktemp -d)
TARGET_USER=$(id -un)
HOME_DIR="$TEST_DIR/home"
FSTAB_FILE="$TEST_DIR/fstab"
BIN_DIR="$TEST_DIR/bin"
export TARGET_USER HOME_DIR FSTAB_FILE
export SHORIN_USER_RUNTIME_ROOT="$TEST_DIR/runtime"
export RIME_DICT_MANAGER_PATH="$BIN_DIR/rime_dict_manager"

cleanup() {
    find "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

mkdir -p "$BIN_DIR" "$HOME_DIR"
cat > "$BIN_DIR/pacman" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -Q ] && [ "$2" = nfs-utils ]
EOF
cat > "$BIN_DIR/rime_dict_manager" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$BIN_DIR/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$BIN_DIR/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
chmod +x "$BIN_DIR"/*
export PATH="$BIN_DIR:$PATH"

source "$ROOT_DIR/scripts/lib/core.sh"
source "$ROOT_DIR/scripts/modules/nas-rime/contract.sh"
NAS_IP=192.0.2.10
NAS_REMOTE_PATH=/archive
NAS_LOCAL_PATH="$TEST_DIR/nas"
RIME_INSTALLATION_ID=test-workstation
export NAS_IP NAS_REMOTE_PATH NAS_LOCAL_PATH RIME_INSTALLATION_ID
nas_rime_contract_init

mkdir -p "$RIME_DIR" "$RIME_USER_UNIT_DIR/timers.target.wants"
printf 'installation_id: "%s"\nsync_dir: "%s"\n' \
    "$RIME_INSTALLATION_ID" "$RIME_SYNC_DIR" > "$RIME_INSTALLATION_FILE"
rime_service_contract > "$RIME_SERVICE_FILE"
rime_timer_contract > "$RIME_TIMER_FILE"
ln -s ../rime-sync.timer \
    "$RIME_USER_UNIT_DIR/timers.target.wants/rime-sync.timer"
printf '%s %s nfs defaults,_netdev,nofail 0 0\n' \
    "$NAS_IP:$NAS_REMOTE_PATH" "$NAS_LOCAL_PATH" > "$FSTAB_FILE"

status=0
output=$(SHORIN_ROOT="$ROOT_DIR" bash \
    "$ROOT_DIR/scripts/modules/nas-rime.sh" verify 2>&1) || status=$?
[ "$status" -eq 20 ] || fail 'offline NAS must be an explicit optional state'
grep -Fq nas-offline <<< "$output" ||
    fail 'offline NAS reason must be reported'

printf 'stale service\n' > "$RIME_SERVICE_FILE"
status=0
output=$(SHORIN_ROOT="$ROOT_DIR" bash \
    "$ROOT_DIR/scripts/modules/nas-rime.sh" verify 2>&1) || status=$?
[ "$status" -eq 1 ] || fail 'nonempty stale Rime service must fail verification'
grep -Fq file:rime-sync-service <<< "$output" ||
    fail 'stale Rime service must identify its contract target'
rime_service_contract > "$RIME_SERVICE_FILE"

find "$RIME_USER_UNIT_DIR/timers.target.wants/rime-sync.timer" -delete
ln -s /wrong/target \
    "$RIME_USER_UNIT_DIR/timers.target.wants/rime-sync.timer"
status=0
output=$(SHORIN_ROOT="$ROOT_DIR" bash \
    "$ROOT_DIR/scripts/modules/nas-rime.sh" verify 2>&1) || status=$?
[ "$status" -eq 1 ] || fail 'wrong Rime timer link must fail verification'
grep -Fq unit:rime-sync <<< "$output" ||
    fail 'wrong Rime timer link must identify its contract target'
find "$RIME_USER_UNIT_DIR/timers.target.wants/rime-sync.timer" -delete
ln -s ../rime-sync.timer \
    "$RIME_USER_UNIT_DIR/timers.target.wants/rime-sync.timer"

printf 'installation_id: "wrong"\nsync_dir: "%s"\n' \
    "$RIME_SYNC_DIR" > "$RIME_INSTALLATION_FILE"
status=0
output=$(SHORIN_ROOT="$ROOT_DIR" bash \
    "$ROOT_DIR/scripts/modules/nas-rime.sh" verify 2>&1) || status=$?
[ "$status" -eq 1 ] || fail 'wrong Rime YAML must fail verification'
grep -Fq rime:installation <<< "$output" ||
    fail 'wrong Rime YAML must identify the contract target'

printf 'PASS: NAS/Rime module contract\n'
