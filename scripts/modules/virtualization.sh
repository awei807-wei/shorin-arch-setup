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

virtualization_record_state() {
    local phase=$1 label=$2 status=$3

    [ "$status" -ne 0 ] || return 0
    if [ "$phase" = check ]; then
        if [ "$status" -eq 1 ]; then
            module_drift "$label"
        else
            module_inspection_failed "$label:inspection-error:$status"
        fi
    elif [ "$status" -eq 1 ]; then
        module_verify_failed "$label"
    else
        module_verify_failed "$label:inspection-error:$status"
    fi
    return "$status"
}

virtualization_expect_state() {
    local phase=$1 label=$2 status=0
    shift 2

    "$@" || status=$?
    virtualization_record_state "$phase" "$label" "$status" || true
    return "$status"
}

virtualization_provider_phase() {
    local phase=$1 provider status=0 overall_status=0 unit

    provider=$(virtualization_detect_provider) || status=$?
    if [ "$status" -ne 0 ]; then
        virtualization_record_state "$phase" provider "$status" || true
        return "$status"
    fi
    case "$provider" in
        modular|monolithic) ;;
        mixed|none)
            virtualization_record_state "$phase" "provider:$provider" 1 || true
            return 1
            ;;
        *)
            virtualization_record_state "$phase" provider 2 || true
            return 2
            ;;
    esac

    virtualization_expect_state "$phase" "provider:$provider:policy" \
        virtualization_provider_policy_matches "$provider" || status=$?
    if [ "$status" -ne 0 ] &&
        { [ "$overall_status" -eq 0 ] || [ "$status" -gt 1 ]; }; then
        overall_status=$status
    fi
    status=0
    while IFS= read -r unit; do
        virtualization_expect_state "$phase" \
            "provider:$provider:unit:$unit:enabled" \
            virtualization_unit_explicitly_enabled "$unit" || status=$?
        if [ "$status" -ne 0 ] &&
            { [ "$overall_status" -eq 0 ] || [ "$status" -gt 1 ]; }; then
            overall_status=$status
        fi
        status=0
        virtualization_expect_state "$phase" \
            "provider:$provider:unit:$unit:active" \
            virtualization_unit_active "$unit" || status=$?
        if [ "$status" -ne 0 ] &&
            { [ "$overall_status" -eq 0 ] || [ "$status" -gt 1 ]; }; then
            overall_status=$status
        fi
        status=0
    done < <(virtualization_provider_required_units "$provider")
    virtualization_expect_state "$phase" "provider:$provider:exclusive" \
        virtualization_provider_conflicts_absent "$provider" || status=$?
    if [ "$status" -ne 0 ] &&
        { [ "$overall_status" -eq 0 ] || [ "$status" -gt 1 ]; }; then
        overall_status=$status
    fi
    [ "$overall_status" -eq 0 ] || return "$overall_status"

    virtualization_expect_state "$phase" connection:qemu-system \
        virtualization_system_connection_ready
}

virtualization_check() {
    local package group command provider_status=0

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
    for command in "${VIRTUALIZATION_COMMANDS[@]}"; do
        module_check_state "command:$command" state_command_exists "$command"
        [ "$MODULE_RESULT" -ne "$RC_FAILED" ] || return 0
    done
    for group in "${VIRTUALIZATION_GROUPS[@]}"; do
        module_check_state "group:$TARGET_USER:$group" \
            state_user_in_group "$TARGET_USER" "$group"
        [ "$MODULE_RESULT" -ne "$RC_FAILED" ] || return 0
    done
    module_check_state gsettings:uris virtualization_gsettings_matches \
        "$TARGET_USER" "$HOME_DIR" uris "['qemu:///system']"
    module_check_state gsettings:autoconnect virtualization_gsettings_matches \
        "$TARGET_USER" "$HOME_DIR" autoconnect "['qemu:///system']"
    virtualization_provider_phase check || provider_status=$?
    [ "$provider_status" -eq 0 ] || return 0
    module_check_state network:default virtualization_default_network_ready
}

virtualization_apply() {
    virtualization_is_targeted || return 0
    bash "$SHORIN_ROOT/scripts/modules/virtualization/apply.sh"
}

virtualization_verify() {
    local package group command network_status=0 provider_status=0

    virtualization_is_targeted || { module_skip not-declared; return; }
    if [ -z "${TARGET_USER:-}" ]; then
        module_verify_failed target-user-context
        return
    fi
    for package in "${VIRTUALIZATION_PACKAGES[@]}"; do
        verify_package "$package" || module_verify_failed "package:$package"
    done
    for command in "${VIRTUALIZATION_COMMANDS[@]}"; do
        state_command_exists "$command" || module_verify_failed "command:$command"
    done
    for group in "${VIRTUALIZATION_GROUPS[@]}"; do
        state_user_in_group "$TARGET_USER" "$group" ||
            module_verify_failed "group:$TARGET_USER:$group"
    done
    virtualization_gsettings_matches "$TARGET_USER" "$HOME_DIR" \
        uris "['qemu:///system']" ||
        module_verify_failed gsettings:uris
    virtualization_gsettings_matches "$TARGET_USER" "$HOME_DIR" \
        autoconnect "['qemu:///system']" ||
        module_verify_failed gsettings:autoconnect
    virtualization_provider_phase verify || provider_status=$?
    [ "$provider_status" -eq 0 ] || return 0
    virtualization_default_network_ready || network_status=$?
    if [ "$network_status" -eq 1 ]; then
        module_verify_failed network:default
    elif [ "$network_status" -ne 0 ]; then
        module_verify_failed "network:default:inspection-error:$network_status"
    fi
}

module_main virtualization "$@"
