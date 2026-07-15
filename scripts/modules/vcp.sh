#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"

VCP_DIR=${VCP_DIR:-$HOME_DIR/Downloads/VCPChat}
VCP_BACKUP_SCRIPT=${VCP_BACKUP_SCRIPT:-$HOME_DIR/.local/share/scripts/vcp_nas_sync.py}
VCP_DESKTOP_FILE=${VCP_DESKTOP_FILE:-$HOME_DIR/.local/share/applications/vchat.desktop}

vcp_desktop_is_applicable() {
    [ -d "$VCP_DIR" ] && [ -f "$VCP_DIR/package.json" ] &&
        command -v npm >/dev/null 2>&1
}

vcp_backup_is_applicable() {
    [ -f "$VCP_BACKUP_SCRIPT" ]
}

vcp_user_bus_is_available() {
    [ -n "${TARGET_USER:-}" ] &&
        [ -S "/run/user/$(id -u "$TARGET_USER")/bus" ]
}

vcp_record_unavailable_targets() {
    [ "$MODULE_RESULT" -eq "$RC_OK" ] || return 0

    vcp_backup_is_applicable || module_skip vcp-backup-script-not-deployed
    vcp_desktop_is_applicable ||
        module_skip vcpchat-desktop-prerequisites-missing
    if vcp_backup_is_applicable && ! vcp_user_bus_is_available; then
        module_skip vcp-backup-pending-login
    fi
}

vcp_check() {
    if [ -z "${TARGET_USER:-}" ] || [ -z "${HOME_DIR:-}" ]; then
        module_inspection_failed target-user-context
        return
    fi
    if vcp_desktop_is_applicable; then
        module_check_state file:vcp-desktop state_file_nonempty "$VCP_DESKTOP_FILE"
    fi
    if vcp_backup_is_applicable; then
        module_check_state file:vcp-backup-service \
            state_file_nonempty "$HOME_DIR/.config/systemd/user/vcp-backup.service"
        module_check_state file:vcp-backup-timer \
            state_file_nonempty "$HOME_DIR/.config/systemd/user/vcp-backup.timer"
        module_check_state file:vcp-backup-sudoers \
            state_file_nonempty /etc/sudoers.d/vcp-backup
        module_check_state unit:vcp-backup \
            state_user_unit_enabled "$TARGET_USER" vcp-backup.timer timers.target
    fi
    vcp_record_unavailable_targets
}

vcp_apply() {
    local status=0 child_status=0

    if vcp_backup_is_applicable; then
        bash "$SHORIN_ROOT/scripts/modules/vcp/backup-apply.sh" "$TARGET_USER" ||
            child_status=$?
        case "$child_status" in
            0|20) ;;
            *) status=$child_status ;;
        esac
    fi
    child_status=0
    if vcp_desktop_is_applicable; then
        bash "$SHORIN_ROOT/scripts/modules/vcp/desktop-entry-apply.sh" "$TARGET_USER" ||
            child_status=$?
        case "$child_status" in
            0|20) ;;
            *) [ "$status" -ne 0 ] || status=$child_status ;;
        esac
    fi
    return "$status"
}

vcp_verify() {
    if [ -z "${TARGET_USER:-}" ] || [ -z "${HOME_DIR:-}" ]; then
        module_verify_failed target-user-context
        return
    fi
    if vcp_desktop_is_applicable; then
        verify_file "$VCP_DESKTOP_FILE" || module_verify_failed file:vcp-desktop
    fi
    if vcp_backup_is_applicable; then
        verify_file "$HOME_DIR/.config/systemd/user/vcp-backup.service" ||
            module_verify_failed file:vcp-backup-service
        verify_file "$HOME_DIR/.config/systemd/user/vcp-backup.timer" ||
            module_verify_failed file:vcp-backup-timer
        verify_file /etc/sudoers.d/vcp-backup ||
            module_verify_failed file:vcp-backup-sudoers
        verify_user_unit "$TARGET_USER" vcp-backup.timer timers.target ||
            module_verify_failed unit:vcp-backup
    fi
    vcp_record_unavailable_targets
}

module_main vcp "$@"
