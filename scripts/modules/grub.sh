#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"

grub_is_applicable() {
    command -v grub-mkconfig >/dev/null 2>&1 && [ -f /etc/default/grub ]
}

grub_theme_is_available() {
    find "$SHORIN_ROOT/grub-themes" -mindepth 2 -maxdepth 2 \
        -type f -name theme.txt -print -quit 2>/dev/null | grep -q .
}

grub_service_enabled() {
    local status=0

    state_service_enabled "$1" || status=$?
    case "$status" in
        0) return 0 ;;
        2) return 2 ;;
        *) return 1 ;;
    esac
}

grub_mark_theme_unavailable() {
    if [ "$MODULE_RESULT" -eq "$RC_OK" ] && ! grub_theme_is_available; then
        module_skip grub-theme-assets-missing
    fi
}

grub_check() {
    grub_is_applicable || { module_skip grub-not-installed; return; }
    module_check_state grub:config state_grub_config_valid /boot/grub/grub.cfg
    [ "$MODULE_RESULT" -ne "$RC_FAILED" ] || return
    if grub_theme_is_available; then
        module_check_state grub:theme-key \
            grep -q '^GRUB_THEME=' /etc/default/grub
        [ "$MODULE_RESULT" -ne "$RC_FAILED" ] || return
    fi
    if [ "$(findmnt -n -o FSTYPE / 2>/dev/null)" = btrfs ]; then
        module_check_state package:grub-btrfs state_package_present grub-btrfs
        [ "$MODULE_RESULT" -ne "$RC_FAILED" ] || return
        module_check_state service:grub-btrfsd \
            grub_service_enabled grub-btrfsd.service
    fi
    grub_mark_theme_unavailable
}

grub_apply() {
    local status=0

    grub_is_applicable || { module_skip grub-not-installed; return; }
    bash "$SHORIN_ROOT/scripts/modules/grub/btrfs-apply.sh" || return
    bash "$SHORIN_ROOT/scripts/modules/grub/dualboot-apply.sh" || return
    bash "$SHORIN_ROOT/scripts/modules/grub/theme-apply.sh" || status=$?
    case "$status" in
        0|20) return 0 ;;
        *) return "$status" ;;
    esac
}

grub_verify() {
    grub_is_applicable || { module_skip grub-not-installed; return; }
    verify_grub /boot/grub/grub.cfg || module_verify_failed grub:config
    if grub_theme_is_available; then
        grep -q '^GRUB_THEME=' /etc/default/grub ||
            module_verify_failed grub:theme-key
    fi
    if [ "$(findmnt -n -o FSTYPE / 2>/dev/null)" = btrfs ]; then
        verify_package grub-btrfs || module_verify_failed package:grub-btrfs
        verify_service grub-btrfsd.service ||
            module_verify_failed service:grub-btrfsd
    fi
    grub_mark_theme_unavailable
}

module_main grub "$@"
