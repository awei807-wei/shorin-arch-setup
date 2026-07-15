#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"
source "$SHORIN_ROOT/scripts/modules/vcp/contract.sh"

if [ -n "${HOME_DIR:-}" ]; then
    vcp_contract_init
fi

vcp_desktop_prerequisites_present() {
    [ -d "$VCP_DIR" ] && [ -f "$VCP_DIR/package.json" ] &&
        [ -n "$VCP_NPM" ] && [ -x "$VCP_NPM" ]
}

vcp_user_bus_is_available() {
    [ -n "${TARGET_USER:-}" ] &&
        [ -S "${SHORIN_USER_RUNTIME_ROOT:-/run/user}/$(id -u "$TARGET_USER")/bus" ]
}

vcp_expect() {
    local phase=$1 label=$2
    shift 2

    if [ "$phase" = check ]; then
        module_check_state "$label" "$@"
    elif ! "$@"; then
        module_verify_failed "$label"
    fi
}

vcp_prerequisite_failed() {
    local phase=$1 reason=$2

    if [ "$phase" = check ]; then
        module_inspection_failed "$reason"
    else
        module_verify_failed "$reason"
    fi
}

vcp_inspect() {
    local phase=$1
    local backup_declared=0
    local backup_unavailable=0 desktop_unavailable=0

    if [ -z "${TARGET_USER:-}" ] || [ -z "${HOME_DIR:-}" ]; then
        vcp_prerequisite_failed "$phase" target-user-context
        return
    fi
    vcp_contract_init

    if [ -f "$VCP_BACKUP_SCRIPT" ]; then
        backup_declared=1
        if [ -z "$VCP_PYTHON" ] || [ ! -x "$VCP_PYTHON" ]; then
            vcp_prerequisite_failed "$phase" vcp-backup-python-missing
        else
            vcp_expect "$phase" file:vcp-backup-service \
                vcp_backup_service_matches
            vcp_expect "$phase" file:vcp-backup-timer \
                vcp_backup_timer_matches
            vcp_expect "$phase" file:vcp-backup-sudoers \
                vcp_sudoers_matches
            vcp_expect "$phase" unit:vcp-backup vcp_backup_link_matches
            if vcp_user_bus_is_available; then
                vcp_expect "$phase" unit:vcp-backup-active \
                    vcp_backup_timer_is_active "$TARGET_USER"
            fi
        fi
    elif vcp_backup_artifacts_exist; then
        vcp_prerequisite_failed "$phase" vcp-backup-script-missing
    else
        backup_unavailable=1
    fi

    if vcp_desktop_prerequisites_present; then
        vcp_expect "$phase" file:vcp-desktop vcp_desktop_matches
    elif vcp_desktop_artifact_exists; then
        vcp_prerequisite_failed "$phase" vcpchat-desktop-prerequisites-missing
    else
        desktop_unavailable=1
    fi

    [ "$MODULE_RESULT" -eq "$RC_OK" ] || return 0
    [ "$backup_unavailable" -eq 0 ] ||
        module_skip vcp-backup-script-not-deployed
    [ "$desktop_unavailable" -eq 0 ] ||
        module_skip vcpchat-desktop-prerequisites-missing
    if [ "$backup_declared" -eq 1 ] && ! vcp_user_bus_is_available; then
        module_skip vcp-backup-pending-login
    fi
}

vcp_check() { vcp_inspect check; }

vcp_apply() {
    local status=0 child_status=0

    vcp_contract_init
    if [ -f "$VCP_BACKUP_SCRIPT" ]; then
        [ -n "$VCP_PYTHON" ] && [ -x "$VCP_PYTHON" ] ||
            die 'Python is required for the VCP backup timer.'
        env HOME_DIR="$HOME_DIR" VCP_BACKUP_SCRIPT="$VCP_BACKUP_SCRIPT" \
            VCP_SUDOERS_FILE="$VCP_SUDOERS_FILE" \
            VCP_PYTHON="$VCP_PYTHON" \
            bash "$SHORIN_ROOT/scripts/modules/vcp/backup-apply.sh" \
                "$TARGET_USER" || child_status=$?
        [ "$child_status" -eq 0 ] || status=$child_status
    fi

    child_status=0
    if vcp_desktop_prerequisites_present; then
        env HOME_DIR="$HOME_DIR" VCP_DIR="$VCP_DIR" \
            VCP_DESKTOP_FILE="$VCP_DESKTOP_FILE" \
            VCP_NPM="$VCP_NPM" \
            bash "$SHORIN_ROOT/scripts/modules/vcp/desktop-entry-apply.sh" \
                "$TARGET_USER" || child_status=$?
        if [ "$child_status" -ne 0 ] && [ "$status" -eq 0 ]; then
            status=$child_status
        fi
    fi
    return "$status"
}

vcp_verify() { vcp_inspect verify; }

module_main vcp "$@"
