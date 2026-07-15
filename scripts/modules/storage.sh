#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"
source "$SHORIN_ROOT/scripts/modules/storage/targets.sh"

storage_require_btrfs() {
    local phase=$1 fstype status=0

    fstype=$(storage_root_fstype) || status=$?
    if [ "$status" -ne 0 ] || [ -z "$fstype" ]; then
        [ "$phase" = check ] && module_inspection_failed root-filesystem ||
            module_verify_failed root-filesystem
        return 1
    fi
    if [ "$fstype" != btrfs ]; then
        module_skip root-not-btrfs
        return 1
    fi
}

storage_check() {
    storage_require_btrfs check || return 0
    local package
    module_check_state fstab:unique-targets state_fstab_targets_unique \
        "${FSTAB_FILE:-/etc/fstab}" "${STORAGE_FSTAB_UNIQUE_TARGETS[@]}"
    for package in "${STORAGE_PACKAGES[@]}"; do
        module_check_state "package:$package" state_package_present "$package"
    done
    if state_package_present snapper; then
        module_check_state snapper:root snapper_config_matches root
        module_check_state snapshot:before-shorin \
            snapper_snapshot_present root 'Before Shorin Setup'
        if storage_home_is_btrfs; then
            module_check_state snapper:home snapper_config_matches home
        fi
    fi
    module_check_state service:snapper-cleanup \
        state_service_enabled snapper-cleanup.timer
}

storage_apply() {
    local implementation="$SHORIN_ROOT/scripts/modules/storage"
    ensure_fstab_targets_unique "${FSTAB_FILE:-/etc/fstab}" \
        "${STORAGE_FSTAB_UNIQUE_TARGETS[@]}"
    ensure_packages "${STORAGE_PACKAGES[@]}"
    bash "$implementation/btrfs-apply.sh" || return
    if [ "${SHORIN_MODE:-install}" = install ]; then
        bash "$implementation/checkpoint-apply.sh" || return
    fi
}

storage_verify() {
    storage_require_btrfs verify || return 0
    local package
    state_fstab_targets_unique "${FSTAB_FILE:-/etc/fstab}" \
        "${STORAGE_FSTAB_UNIQUE_TARGETS[@]}" ||
        module_verify_failed fstab:unique-targets
    for package in "${STORAGE_PACKAGES[@]}"; do
        verify_package "$package" || module_verify_failed "package:$package"
    done
    snapper_config_matches root ||
        module_verify_failed snapper:root
    snapper_snapshot_present root 'Before Shorin Setup' ||
        module_verify_failed snapshot:before-shorin
    if storage_home_is_btrfs; then
        snapper_config_matches home || module_verify_failed snapper:home
    fi
    verify_service snapper-cleanup.timer ||
        module_verify_failed service:snapper-cleanup
}

module_main storage "$@"
