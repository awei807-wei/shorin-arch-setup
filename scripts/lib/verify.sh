#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SHORIN_LIB_DIR/state.sh"

verify_package() {
    state_package_present "$1"
}

verify_flatpak() {
    state_flatpak_present "$1"
}

verify_service() {
    state_service_enabled "$1"
}

verify_active_service() {
    state_service_enabled "$1" && state_service_active "$1"
}

verify_file() {
    state_file_nonempty "$1"
}

verify_user_unit() {
    state_user_unit_enabled "$@"
}

verify_fstab() {
    state_fstab_valid "${1:-/etc/fstab}"
}

verify_grub() {
    state_grub_config_valid "${1:-/boot/grub/grub.cfg}"
}

run_final_verification() {
    local module
    export SHORIN_READ_ONLY=1

    # Final status is derived from current state, not from an earlier command's
    # exit code. Module policies remain registered while transient results reset.
    REQUIRED_FAILURES=()
    OPTIONAL_FAILURES=()
    OPTIONAL_SKIPS=()

    for module in "$@"; do
        verify_one_module "$module" || true
    done
    derive_final_status
    [ "$FINAL_STATUS" != FAILED ]
}
