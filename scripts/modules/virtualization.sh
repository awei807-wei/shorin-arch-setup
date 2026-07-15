#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"
source "$SHORIN_ROOT/scripts/modules/virtualization/contract.sh"

APPLICATION_MANIFEST=${APPLICATION_MANIFEST:-${SHORIN_PROFILE_DIR:-/etc/shorin-arch-setup}/applications.list}

virtualization_manifest_declares_target() {
    [ -s "$APPLICATION_MANIFEST" ] || return 1
    awk '
        /^[[:space:]]*(#|$)/ { next }
        {
            sub(/[[:space:]]+#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if ($0 == "virt-manager") found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$APPLICATION_MANIFEST"
}

virtualization_is_targeted() {
    virtualization_manifest_declares_target
}

virtualization_service_enabled() {
    local status=0

    state_service_enabled "$1" || status=$?
    case "$status" in
        0) return 0 ;;
        2) return 2 ;;
        *) return 1 ;;
    esac
}

virtualization_service_active() {
    local status=0

    state_service_active "$1" || status=$?
    case "$status" in
        0) return 0 ;;
        2) return 2 ;;
        *) return 1 ;;
    esac
}

virtualization_check() {
    local package group

    virtualization_is_targeted || { module_skip not-declared; return; }
    if [ -z "${TARGET_USER:-}" ]; then
        module_inspection_failed target-user-context
        return
    fi
    for package in "${VIRTUALIZATION_PACKAGES[@]}"; do
        module_check_state "package:$package" state_package_present "$package"
        [ "$MODULE_RESULT" -ne "$RC_FAILED" ] || return 0
    done
    [ "$MODULE_RESULT" -eq "$RC_OK" ] || return 0
    module_check_state service:libvirtd \
        virtualization_service_enabled libvirtd.service
    [ "$MODULE_RESULT" -ne "$RC_FAILED" ] || return 0
    module_check_state service:libvirtd-active \
        virtualization_service_active libvirtd.service
    [ "$MODULE_RESULT" -ne "$RC_FAILED" ] || return 0
    for group in "${VIRTUALIZATION_GROUPS[@]}"; do
        module_check_state "group:$TARGET_USER:$group" \
            state_user_in_group "$TARGET_USER" "$group"
        [ "$MODULE_RESULT" -ne "$RC_FAILED" ] || return 0
    done
    module_check_state network:default virtualization_default_network_ready
    module_check_state gsettings:uris virtualization_gsettings_matches \
        "$TARGET_USER" "$HOME_DIR" uris "['qemu:///system']"
    module_check_state gsettings:autoconnect virtualization_gsettings_matches \
        "$TARGET_USER" "$HOME_DIR" autoconnect "['qemu:///system']"
}

virtualization_apply() {
    virtualization_is_targeted || return 0
    bash "$SHORIN_ROOT/scripts/modules/virtualization/apply.sh"
}

virtualization_verify() {
    local package group

    virtualization_is_targeted || { module_skip not-declared; return; }
    if [ -z "${TARGET_USER:-}" ]; then
        module_verify_failed target-user-context
        return
    fi
    for package in "${VIRTUALIZATION_PACKAGES[@]}"; do
        verify_package "$package" || module_verify_failed "package:$package"
    done
    verify_active_service libvirtd.service ||
        module_verify_failed service:libvirtd
    for group in "${VIRTUALIZATION_GROUPS[@]}"; do
        state_user_in_group "$TARGET_USER" "$group" ||
            module_verify_failed "group:$TARGET_USER:$group"
    done
    virtualization_default_network_ready ||
        module_verify_failed network:default
    virtualization_gsettings_matches "$TARGET_USER" "$HOME_DIR" \
        uris "['qemu:///system']" ||
        module_verify_failed gsettings:uris
    virtualization_gsettings_matches "$TARGET_USER" "$HOME_DIR" \
        autoconnect "['qemu:///system']" ||
        module_verify_failed gsettings:autoconnect
}

module_main virtualization "$@"
