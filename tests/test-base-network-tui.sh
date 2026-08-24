#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

export SHORIN_DISTRO=fedora SHORIN_MODE=repair SHORIN_READ_ONLY=0
source "$ROOT_DIR/scripts/modules/base/targets.sh"
module_main() { :; }
source "$ROOT_DIR/scripts/modules/base.sh"

[ "$(fedora_arch_target_name networkmanager)" = NetworkManager-tui ] ||
    fail 'Fedora must translate the Arch networkmanager target to NetworkManager-tui'

mapfile -t FEDORA_BASE_PACKAGES < <(base_declared_packages)
printf '%s\n' "${FEDORA_BASE_PACKAGES[@]}" | grep -Fqx networkmanager ||
    fail 'Fedora base must require the logical networkmanager target'
! printf '%s\n' "${FEDORA_BASE_PACKAGES[@]}" | grep -Fqx NetworkManager-tui ||
    fail 'Fedora package spelling must remain behind the platform mapper'

export SHORIN_DISTRO=arch
mapfile -t ARCH_BASE_PACKAGES < <(base_declared_packages)
printf '%s\n' "${ARCH_BASE_PACKAGES[@]}" | grep -Fqx networkmanager ||
    fail 'Arch base must retain the native networkmanager package target'
! printf '%s\n' "${ARCH_BASE_PACKAGES[@]}" | grep -Fqx NetworkManager-tui ||
    fail 'Fedora package spelling must not leak into the Arch manifest'

mapfile -t REQUIRED_COMMANDS < <(base_required_commands)
printf '%s\n' "${REQUIRED_COMMANDS[@]}" | grep -Fqx nmtui ||
    fail 'base command contract must require nmtui'

export SHORIN_DISTRO=fedora
MOCK_NETWORKMANAGER_INSTALLED=0
MOCK_DNF_TARGET=''
platform_rpm_installed() {
    [ "$1" = NetworkManager-tui ] &&
        [ "$MOCK_NETWORKMANAGER_INSTALLED" -eq 1 ]
}
platform_dnf_install() {
    MOCK_DNF_TARGET=$1
    [ "$MOCK_DNF_TARGET" = NetworkManager-tui ] || return 1
    MOCK_NETWORKMANAGER_INSTALLED=1
}
record_package_source() { :; }

ensure_package networkmanager ||
    fail 'Fedora apply must converge the logical networkmanager target'
[ "$MOCK_DNF_TARGET" = NetworkManager-tui ] ||
    fail 'Fedora apply must send NetworkManager-tui to DNF'
state_package_present networkmanager ||
    fail 'Fedora package verify must inspect NetworkManager-tui through the logical target'

EMPTY_BIN="$TEST_DIR/empty-bin"
NMTUI_BIN="$TEST_DIR/nmtui-bin"
mkdir -p "$EMPTY_BIN" "$NMTUI_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$NMTUI_BIN/nmtui"
chmod +x "$NMTUI_BIN/nmtui"

PATH="$NMTUI_BIN" base_required_command_present nmtui ||
    fail 'nmtui command must satisfy the base command contract when installed'
if PATH="$EMPTY_BIN" base_required_command_present nmtui; then
    fail 'missing nmtui command must not satisfy the base command contract'
fi

MODULE_RESULT=$RC_OK
MODULE_REASONS=()
PATH="$EMPTY_BIN" base_required_commands_inspect check
[ "$MODULE_RESULT" -eq "$RC_DRIFT" ] ||
    fail 'missing nmtui must be drift during base check'
printf '%s\n' "${MODULE_REASONS[@]}" | grep -Fqx command:nmtui ||
    fail 'base check must report command:nmtui'

MODULE_RESULT=$RC_OK
MODULE_REASONS=()
PATH="$EMPTY_BIN" base_required_commands_inspect verify
[ "$MODULE_RESULT" -eq "$RC_FAILED" ] ||
    fail 'missing nmtui must fail authoritative base verify'
printf '%s\n' "${MODULE_REASONS[@]}" | grep -Fqx command:nmtui ||
    fail 'base verify must report command:nmtui'

MODULE_RESULT=$RC_OK
MODULE_REASONS=()
PATH="$NMTUI_BIN" base_required_commands_inspect verify
[ "$MODULE_RESULT" -eq "$RC_OK" ] ||
    fail 'available nmtui must satisfy authoritative base verify'

printf 'PASS: cross-distro nmtui package and command desired state\n'
