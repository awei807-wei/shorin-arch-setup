#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
BIN_DIR="$TEST_DIR/bin"
INSTALLED="$TEST_DIR/installed"
CALLS="$TEST_DIR/calls"
mkdir -p "$BIN_DIR"
: > "$INSTALLED"
: > "$CALLS"
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

default_config=$(env -u GRUB_CONFIG_FILE SHORIN_DISTRO=fedora \
    SHORIN_ROOT="$ROOT_DIR" bash -c '
        source "$SHORIN_ROOT/scripts/lib/core.sh"
        source "$SHORIN_ROOT/scripts/modules/grub/contract.sh"
        unset GRUB_CONFIG_FILE
        grub_contract_init
        printf "%s\n" "$GRUB_CONFIG_FILE"
    ')
[ "$default_config" = /boot/grub2/grub.cfg ] ||
    fail "Fedora GRUB default is $default_config instead of /boot/grub2/grub.cfg"
if rg -F '/boot/efi/EFI/fedora/grub.cfg' \
    "$ROOT_DIR/scripts/modules/grub/contract.sh" \
    "$ROOT_DIR/scripts/modules/grub/fedora-apply.sh" >/dev/null; then
    fail 'Fedora GRUB implementation still selects the EFI vendor stub as output'
fi

cat > "$BIN_DIR/rpm" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[ "${1:-}" = -q ] || exit 2
if [ "${2:-}" = --qf ]; then
    package=${4:-}
    grep -Fqx "$package" "${FEDORA_GRUB_INSTALLED:?}" || exit 1
    printf '1-1.fc44\n'
else
    grep -Fqx "${2:-}" "${FEDORA_GRUB_INSTALLED:?}"
fi
EOF
cat > "$BIN_DIR/dnf" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'dnf:%s\n' "$*" >> "${FEDORA_GRUB_CALLS:?}"
exit 64
EOF
cat > "$BIN_DIR/grub2-mkconfig" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'grub2-mkconfig:%s\n' "$*" >> "${FEDORA_GRUB_CALLS:?}"
[ "${1:-}" = -o ] && [ -n "${2:-}" ]
printf 'generated Fedora GRUB configuration\n' > "$2"
EOF
cat > "$BIN_DIR/grub2-script-check" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'grub2-script-check:%s\n' "$*" >> "${FEDORA_GRUB_CALLS:?}"
grep -Fqx 'generated Fedora GRUB configuration' "$1"
EOF
chmod 755 "$BIN_DIR"/*

for package in grub2-tools os-prober exfatprogs; do
    printf '%s\n' "$package" >> "$INSTALLED"
done

default_file="$TEST_DIR/etc/default/grub"
main_config="$TEST_DIR/boot/grub2/grub.cfg"
efi_stub="$TEST_DIR/boot/efi/EFI/fedora/grub.cfg"
mkdir -p "$(dirname "$default_file")" "$(dirname "$main_config")" \
    "$(dirname "$efi_stub")"
printf 'GRUB_DISABLE_OS_PROBER="true"\n' > "$default_file"
printf 'search --fs-uuid --set=dev fedora-root\nconfigfile ($dev)/grub2/grub.cfg\n' > \
    "$efi_stub"
stub_before=$(sha256sum "$efi_stub" | awk '{ print $1 }')

apply_script="$TEST_DIR/fedora-apply.sh"
sed '/^check_root$/d' "$ROOT_DIR/scripts/modules/grub/fedora-apply.sh" > \
    "$apply_script"
chmod 755 "$apply_script"
FEDORA_GRUB_INSTALLED="$INSTALLED" FEDORA_GRUB_CALLS="$CALLS" \
    PATH="$BIN_DIR:$PATH" SHORIN_ROOT="$ROOT_DIR" \
    SHORIN_SCRIPTS_DIR="$ROOT_DIR/scripts" SHORIN_DISTRO=fedora \
    SHORIN_MODE=repair SHORIN_READ_ONLY=0 \
    PACKAGE_SOURCE_DIR="$TEST_DIR/package-sources" \
    GRUB_DEFAULT_FILE="$default_file" GRUB_CONFIG_FILE="$main_config" \
    bash "$apply_script" >/dev/null

grep -Fqx 'generated Fedora GRUB configuration' "$main_config" ||
    fail 'Fedora GRUB apply did not generate the unified main configuration'
[ "$(sha256sum "$efi_stub" | awk '{ print $1 }')" = "$stub_before" ] ||
    fail 'Fedora GRUB apply changed the EFI vendor stub'
grep -Fq "grub2-mkconfig:-o $main_config." "$CALLS" ||
    fail 'Fedora GRUB generator did not write a temporary beside the main config'
! grep -Fq "$efi_stub" "$CALLS" ||
    fail 'Fedora GRUB generator or checker received the EFI stub path'

printf 'PASS: Fedora UEFI GRUB preserves the EFI stub and generates /boot/grub2 semantics\n'
