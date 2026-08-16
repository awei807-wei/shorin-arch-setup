#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SHORIN_DISTRO=arch
TEST_DIR=$(mktemp -d)
BIN_DIR="$TEST_DIR/bin"
GRUB_DEFAULT_FILE="$TEST_DIR/default-grub"
GRUB_CONFIG_FILE="$TEST_DIR/grub.cfg"
GRUB_CUSTOM_FILE="$TEST_DIR/99_custom"
GRUB_MKINITCPIO_FILE="$TEST_DIR/mkinitcpio.conf"
GRUB_THEME_SOURCE_ROOT="$TEST_DIR/theme-source"
GRUB_THEME_DEST_ROOT="$TEST_DIR/theme-destination"
GRUB_ROOT_FSTYPE=ext4
export GRUB_DEFAULT_FILE GRUB_CONFIG_FILE GRUB_CUSTOM_FILE
export GRUB_MKINITCPIO_FILE GRUB_THEME_SOURCE_ROOT GRUB_THEME_DEST_ROOT
export GRUB_ROOT_FSTYPE

cleanup() {
    find "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

mkdir -p "$BIN_DIR" "$GRUB_THEME_SOURCE_ROOT/test-theme" \
    "$GRUB_THEME_DEST_ROOT"
for command in grub-mkconfig grub-script-check; do
    cat > "$BIN_DIR/$command" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
cat > "$BIN_DIR/pacman" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -Q ]
EOF
cat > "$BIN_DIR/os-prober" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$BIN_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    is-enabled) exit 0 ;;
    is-active) [ "${GRUB_TEST_SERVICE_ACTIVE:-1}" = 1 ] ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$BIN_DIR"/*
export PATH="$BIN_DIR:$PATH"

printf 'theme\n' > "$GRUB_THEME_SOURCE_ROOT/test-theme/theme.txt"
source "$ROOT_DIR/scripts/lib/core.sh"
source "$ROOT_DIR/scripts/modules/grub/contract.sh"
grub_contract_init
theme_hash=$(grub_theme_hash "$GRUB_THEME_SOURCE_ROOT/test-theme")
theme_dir="$GRUB_THEME_DEST_ROOT/test-theme-$theme_hash"
mkdir -p "$theme_dir"
cp "$GRUB_THEME_SOURCE_ROOT/test-theme/theme.txt" "$theme_dir/theme.txt"

watchdog=''
case "$(LC_ALL=C lscpu | awk -F: '/Vendor ID/ {
    gsub(/^[[:space:]]+/, "", $2); print $2; exit
}')" in
    GenuineIntel) watchdog=' modprobe.blacklist=iTCO_wdt' ;;
    AuthenticAMD) watchdog=' modprobe.blacklist=sp5100_tco' ;;
esac
cat > "$GRUB_DEFAULT_FILE" <<EOF
GRUB_DEFAULT="saved"
GRUB_SAVEDEFAULT="true"
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=5 nowatchdog$watchdog"
GRUB_THEME="$theme_dir/theme.txt"
GRUB_TERMINAL_OUTPUT="gfxterm"
GRUB_GFXMODE="auto"
GRUB_DISABLE_OS_PROBER="false"
EOF
printf 'valid grub config\n' > "$GRUB_CONFIG_FILE"
grub_custom_contract > "$GRUB_CUSTOM_FILE"
chmod +x "$GRUB_CUSTOM_FILE"

status=0
output=$(SHORIN_ROOT="$ROOT_DIR" bash \
    "$ROOT_DIR/scripts/modules/grub.sh" verify 2>&1) || status=$?
[ "$status" -eq 0 ] || fail 'complete GRUB persistent targets must verify'

printf 'tampered\n' > "$theme_dir/theme.txt"
status=0
output=$(SHORIN_ROOT="$ROOT_DIR" bash \
    "$ROOT_DIR/scripts/modules/grub.sh" verify 2>&1) || status=$?
[ "$status" -eq 1 ] || fail 'tampered GRUB theme content must fail verification'
grep -Fq grub:theme <<< "$output" ||
    fail 'tampered GRUB theme must identify the theme target'
printf 'theme\n' > "$theme_dir/theme.txt"

printf 'HOOKS=(base grub-btrfs-overlayfs filesystems)\n' > \
    "$GRUB_MKINITCPIO_FILE"
GRUB_ROOT_FSTYPE=btrfs
export GRUB_ROOT_FSTYPE
status=0
output=$(SHORIN_ROOT="$ROOT_DIR" GRUB_TEST_SERVICE_ACTIVE=1 bash \
    "$ROOT_DIR/scripts/modules/grub.sh" verify 2>&1) || status=$?
[ "$status" -eq 0 ] || fail 'complete Btrfs GRUB targets must verify'

status=0
output=$(SHORIN_ROOT="$ROOT_DIR" GRUB_TEST_SERVICE_ACTIVE=0 bash \
    "$ROOT_DIR/scripts/modules/grub.sh" check 2>&1) || status=$?
[ "$status" -eq 10 ] || fail 'inactive grub-btrfsd must report drift'
grep -Fq service:grub-btrfsd-active <<< "$output" ||
    fail 'inactive grub-btrfsd must identify the active-service target'

GRUB_ROOT_FSTYPE=ext4
export GRUB_ROOT_FSTYPE

grep -v '^GRUB_SAVEDEFAULT=' "$GRUB_DEFAULT_FILE" > "$TEST_DIR/default-new"
mv "$TEST_DIR/default-new" "$GRUB_DEFAULT_FILE"
status=0
output=$(SHORIN_ROOT="$ROOT_DIR" bash \
    "$ROOT_DIR/scripts/modules/grub.sh" check 2>&1) || status=$?
[ "$status" -eq 10 ] || fail 'missing GRUB apply target must report drift'
grep -Fq grub:savedefault <<< "$output" ||
    fail 'GRUB drift must identify the missing persistent target'

find "$GRUB_DEFAULT_FILE" -delete
status=0
output=$(SHORIN_ROOT="$ROOT_DIR" bash \
    "$ROOT_DIR/scripts/modules/grub.sh" check 2>&1) || status=$?
[ "$status" -eq 1 ] ||
    fail 'installed GRUB with missing defaults must fail instead of skip'
grep -Fq grub-default-config-missing <<< "$output" ||
    fail 'broken GRUB installation must report the missing defaults'

printf 'PASS: GRUB module contract\n'
