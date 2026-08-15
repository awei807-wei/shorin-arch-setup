#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"
source "$SHORIN_ROOT/scripts/modules/nas-rime/contract.sh"

if [ -n "${HOME_DIR:-}" ]; then
    nas_rime_contract_init
fi

nas_rime_user_bus_is_available() {
    [ -n "${TARGET_USER:-}" ] &&
        [ -S "${SHORIN_USER_RUNTIME_ROOT:-/run/user}/$(id -u "$TARGET_USER")/bus" ]
}

nas_rime_expect() {
    local phase=$1 label=$2
    shift 2

    if [ "$phase" = check ]; then
        module_check_state "$label" "$@"
    elif ! "$@"; then
        module_verify_failed "$label"
    fi
}

nas_rime_record_external_state() {
    local phase=$1
    local online_status=0

    [ "$MODULE_RESULT" -eq "$RC_OK" ] || return 0
    if nas_rime_user_bus_is_available; then
        nas_rime_expect "$phase" unit:rime-sync-active \
            rime_timer_is_active "$TARGET_USER"
    fi
    [ "$MODULE_RESULT" -eq "$RC_OK" ] || return 0
    nas_rime_online || online_status=$?
    case "$online_status" in
        0) ;;
        1) module_skip nas-offline ;;
        *) module_inspection_failed "nas-online:inspection-error:$online_status"; return ;;
    esac
    if ! nas_rime_user_bus_is_available; then
        module_skip rime-sync-pending-login
    fi
}

nas_rime_inspect() {
    local phase=$1 package

    if [ -z "${TARGET_USER:-}" ] || [ -z "${HOME_DIR:-}" ]; then
        if [ "$phase" = check ]; then
            module_inspection_failed target-user-context
        else
            module_verify_failed target-user-context
        fi
        return
    fi
    nas_rime_contract_init
    for package in "${RIME_REQUIRED_PACKAGES[@]}"; do
        nas_rime_expect "$phase" "package:$package" \
            state_package_present "$package"
    done
    nas_rime_expect "$phase" package:nfs-utils state_package_present nfs-utils
    nas_rime_expect "$phase" command:rime-dict-manager \
        rime_dict_manager_available
    nas_rime_expect "$phase" fstab:nas state_fstab_entry \
        "$NAS_IP:$NAS_REMOTE_PATH" "$NAS_LOCAL_PATH" nfs \
        defaults,_netdev,nofail "${FSTAB_FILE:-/etc/fstab}"
    nas_rime_expect "$phase" rime:installation rime_installation_matches
    nas_rime_expect "$phase" file:rime-sync-service rime_service_matches
    nas_rime_expect "$phase" file:rime-sync-timer rime_timer_matches
    nas_rime_expect "$phase" unit:rime-sync rime_timer_link_matches
    nas_rime_record_external_state "$phase"
}

nas_rime_check() { nas_rime_inspect check; }

nas_rime_apply() {
    local status=0

    nas_rime_contract_init
    env HOME_DIR="$HOME_DIR" NAS_IP="$NAS_IP" \
        NAS_REMOTE_PATH="$NAS_REMOTE_PATH" NAS_LOCAL_PATH="$NAS_LOCAL_PATH" \
        RIME_INSTALLATION_ID="$RIME_INSTALLATION_ID" \
        RIME_SYNC_DIR="$RIME_SYNC_DIR" RIME_DIR="$RIME_DIR" \
        RIME_DICT_MANAGER_PATH="$RIME_DICT_MANAGER_PATH" \
        RIME_INSTALLATION_FILE="$RIME_INSTALLATION_FILE" \
        FSTAB_FILE="${FSTAB_FILE:-/etc/fstab}" \
        bash "$SHORIN_ROOT/scripts/modules/nas-rime/apply.sh" "$TARGET_USER" || status=$?
    case "$status" in
        0) return 0 ;;
        20) module_skip nas-apply-pending; return 0 ;;
        *) return "$status" ;;
    esac
}

nas_rime_verify() { nas_rime_inspect verify; }

module_main nas-rime "$@"
