#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"

storage_is_btrfs() {
    [ "$(findmnt -n -o FSTYPE / 2>/dev/null)" = btrfs ]
}

storage_check() {
    storage_is_btrfs || return 0
    local package
    for package in snapper snap-pac btrfs-assistant; do
        module_check_state "package:$package" state_package_present "$package"
    done
    if state_package_present snapper; then
        module_check_state snapper:root snapper -c root get-config
    fi
    module_check_state service:snapper-timeline \
        state_service_enabled snapper-timeline.timer
    module_check_state service:snapper-cleanup \
        state_service_enabled snapper-cleanup.timer
}

storage_apply() {
    local implementation="$SHORIN_ROOT/scripts/modules/storage"
    ensure_packages snapper snap-pac btrfs-assistant
    bash "$implementation/btrfs-apply.sh" || return
    if [ "${SHORIN_MODE:-install}" = install ]; then
        bash "$implementation/checkpoint-apply.sh" || return
    fi
}

storage_verify() {
    storage_is_btrfs || return 0
    local package
    for package in snapper snap-pac btrfs-assistant; do
        verify_package "$package" || module_verify_failed "package:$package"
    done
    snapper -c root get-config >/dev/null 2>&1 ||
        module_verify_failed snapper:root
    verify_service snapper-timeline.timer ||
        module_verify_failed service:snapper-timeline
    verify_service snapper-cleanup.timer ||
        module_verify_failed service:snapper-cleanup
}

module_main storage "$@"
