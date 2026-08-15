#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"
source "$SHORIN_ROOT/scripts/modules/grub/contract.sh"

grub_contract_init

grub_expect() {
    local phase=$1 label=$2
    shift 2

    if [ "$phase" = check ]; then
        module_check_state "$label" "$@"
    elif ! "$@"; then
        module_verify_failed "$label"
    fi
}

grub_prerequisite_failed() {
    local phase=$1 reason=$2

    if [ "$phase" = check ]; then
        module_inspection_failed "$reason"
    else
        module_verify_failed "$reason"
    fi
}

grub_inspect_btrfs() {
    local phase=$1 root_status=0

    grub_root_is_btrfs || root_status=$?
    case "$root_status" in
        0)
            grub_expect "$phase" package:grub-btrfs \
                state_package_present grub-btrfs
            grub_expect "$phase" package:inotify-tools \
                state_package_present inotify-tools
            grub_expect "$phase" service:grub-btrfsd-enabled \
                state_service_enabled grub-btrfsd.service
            grub_expect "$phase" service:grub-btrfsd-active \
                state_service_active grub-btrfsd.service
            grub_expect "$phase" mkinitcpio:grub-btrfs-overlayfs \
                grub_overlay_hook_present
            ;;
        1) ;;
        *) grub_prerequisite_failed "$phase" root-filesystem-inspection-failed ;;
    esac
}

grub_inspect_theme() {
    local phase=$1

    if grub_theme_is_available; then
        grub_expect "$phase" grub:default \
            grub_key_matches GRUB_DEFAULT '"saved"'
        grub_expect "$phase" grub:savedefault \
            grub_key_matches GRUB_SAVEDEFAULT '"true"'
        grub_expect "$phase" grub:terminal \
            grub_key_matches GRUB_TERMINAL_OUTPUT '"gfxterm"'
        grub_expect "$phase" grub:gfxmode \
            grub_key_matches GRUB_GFXMODE '"auto"'
        grub_expect "$phase" grub:param-loglevel \
            grub_kernel_param_present loglevel=5
        grub_expect "$phase" grub:param-nowatchdog \
            grub_kernel_param_present nowatchdog
        grub_expect "$phase" grub:param-quiet-absent \
            grub_kernel_param_absent quiet
        grub_expect "$phase" grub:param-splash-absent \
            grub_kernel_param_absent splash
        grub_expect "$phase" grub:param-watchdog \
            grub_watchdog_param_matches
        grub_expect "$phase" grub:theme grub_theme_target_matches
        grub_expect "$phase" grub:custom-menu grub_custom_matches
    elif [ "$MODULE_RESULT" -eq "$RC_OK" ]; then
        module_skip grub-theme-assets-missing
    fi
}

grub_inspect() {
    local phase=$1 installation_status=0

    grub_installation_state || installation_status=$?
    case "$installation_status" in
        0) ;;
        1) module_skip grub-not-installed; return ;;
        *) grub_prerequisite_failed "$phase" grub-default-config-missing; return ;;
    esac

    if platform_is_fedora; then
        grub_expect "$phase" grub:config state_grub_config_valid "$GRUB_CONFIG_FILE"
        grub_expect "$phase" package:grub2-tools state_package_present grub2-tools
        grub_expect "$phase" package:os-prober state_package_present os-prober
        grub_expect "$phase" package:exfatprogs state_package_present exfatprogs
        grub_expect "$phase" grub:os-prober \
            grub_key_matches GRUB_DISABLE_OS_PROBER '"false"'
        return
    fi

    grub_expect "$phase" grub:config state_grub_config_valid "$GRUB_CONFIG_FILE"
    grub_expect "$phase" package:os-prober state_package_present os-prober
    grub_expect "$phase" package:exfatprogs state_package_present exfatprogs
    grub_expect "$phase" grub:os-prober \
        grub_key_matches GRUB_DISABLE_OS_PROBER '"false"'
    grub_inspect_btrfs "$phase"
    grub_inspect_theme "$phase"
}

grub_check() { grub_inspect check; }

grub_apply() {
    local status=0

    if platform_is_fedora; then
        bash "$SHORIN_ROOT/scripts/modules/grub/fedora-apply.sh"
        return
    fi
    local -a contract_env=(
        "GRUB_DEFAULT_FILE=$GRUB_DEFAULT_FILE"
        "GRUB_CONFIG_FILE=$GRUB_CONFIG_FILE"
        "GRUB_CUSTOM_FILE=$GRUB_CUSTOM_FILE"
        "GRUB_MKINITCPIO_FILE=$GRUB_MKINITCPIO_FILE"
        "GRUB_THEME_SOURCE_ROOT=$GRUB_THEME_SOURCE_ROOT"
        "GRUB_THEME_DEST_ROOT=$GRUB_THEME_DEST_ROOT"
    )

    grub_installation_state || status=$?
    case "$status" in
        0) ;;
        1) module_skip grub-not-installed; return ;;
        *) die "GRUB is installed but $GRUB_DEFAULT_FILE is missing." ;;
    esac

    env "${contract_env[@]}" \
        bash "$SHORIN_ROOT/scripts/modules/grub/btrfs-apply.sh"
    env "${contract_env[@]}" \
        bash "$SHORIN_ROOT/scripts/modules/grub/dualboot-apply.sh"
    status=0
    env "${contract_env[@]}" \
        bash "$SHORIN_ROOT/scripts/modules/grub/theme-apply.sh" || status=$?
    case "$status" in
        0|20) return 0 ;;
        *) return "$status" ;;
    esac
}

grub_verify() { grub_inspect verify; }

module_main grub "$@"
