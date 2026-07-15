#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/modules/vcp/contract.sh"

check_root

TARGET_USER=${1:-${TARGET_USER:-}}
[ -n "$TARGET_USER" ] || die 'Unable to resolve the VCP backup target user.'
if [ -z "${HOME_DIR:-}" ]; then
    HOME_DIR=$(getent passwd "$TARGET_USER" | cut -d: -f6)
fi
[ -d "$HOME_DIR" ] || die "Home directory not found: $HOME_DIR"
vcp_contract_init

[ -f "$VCP_BACKUP_SCRIPT" ] ||
    die "Python backup script not found: $VCP_BACKUP_SCRIPT"
[ -n "$VCP_PYTHON" ] && [ -x "$VCP_PYTHON" ] ||
    die 'Python is required for the VCP backup timer.'

section "VCP Backup" "Sudoers & Systemd Timer Setup"

sudoers_tmp=$(mktemp)
service_tmp=$(mktemp)
timer_tmp=$(mktemp)
vcp_sudoers_contract > "$sudoers_tmp"
vcp_backup_service_contract > "$service_tmp"
vcp_backup_timer_contract > "$timer_tmp"

install_sudoers_file "$sudoers_tmp" "$VCP_SUDOERS_FILE"
install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" \
    "$VCP_USER_UNIT_DIR"
install_if_changed "$service_tmp" "$VCP_BACKUP_SERVICE" 644
install_if_changed "$timer_tmp" "$VCP_BACKUP_TIMER" 644
rm -f "$sudoers_tmp" "$service_tmp" "$timer_tmp"
chown "$TARGET_USER:" "$VCP_BACKUP_SERVICE" "$VCP_BACKUP_TIMER"

vcp_sudoers_matches
vcp_backup_service_matches
vcp_backup_timer_matches
ensure_user_unit_enabled "$TARGET_USER" vcp-backup.timer timers.target "$HOME_DIR"
vcp_backup_link_matches

if ! user_unit_bus_is_available "$TARGET_USER"; then
    warn 'VCP backup is enabled and will start at the next user login.'
fi
