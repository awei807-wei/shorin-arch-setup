#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR
# 06-vcp-backup-setup.sh - VCPChat NAS Backup Automation Installer
# (v1.0 - Hot-plug Mount, Whitelist Sync, 16:00 Timer)

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"

check_root

# --- [CONFIG] ---
TARGET_USER="${1:-$(logname 2>/dev/null || awk -F: '$3 == 1000 {print $1}' /etc/passwd | head -n1)}"
HOME_DIR="/home/$TARGET_USER"
VCP_SYNC_PY="$HOME_DIR/.local/share/scripts/vcp_nas_sync.py"
SUDOERS_FILE="/etc/sudoers.d/vcp-backup"

section "VCP Backup" "Sudoers & Systemd Timer Setup"

# 1. Check if Python script exists
if [ ! -f "$VCP_SYNC_PY" ]; then
  warn "Python backup script not found at $VCP_SYNC_PY"
  log "Skipping setup until VCPChat is deployed."
  exit 20
fi

# 2. Sudoers Management (Scripted)
log "Configuring sudoers for passwordless mount/umount..."
SUDOERS_TMP=$(mktemp)
cat >"$SUDOERS_TMP" <<EOF
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/mount, /usr/bin/umount, /usr/bin/mkdir
EOF
install_sudoers_file "$SUDOERS_TMP" "$SUDOERS_FILE"
rm -f "$SUDOERS_TMP"
success "Sudoers entry created at $SUDOERS_FILE"

# 3. Systemd User Timer Setup
log "Setting up Systemd User Timer (Daily 16:00)..."
TIMER_DIR="$HOME_DIR/.config/systemd/user"
as_user mkdir -p "$TIMER_DIR"

# Create Service Unit
SERVICE_TMP=$(mktemp)
TIMER_TMP=$(mktemp)
cat >"$SERVICE_TMP" <<EOF
[Unit]
Description=VCPChat NAS Daily Backup (Hot-plug Mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python $VCP_SYNC_PY
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

# Create Timer Unit (16:00)
cat >"$TIMER_TMP" <<EOF
[Unit]
Description=Run VCPChat Backup at 16:00 Daily

[Timer]
OnCalendar=*-*-* 16:00:00
Persistent=true
Unit=vcp-backup.service

[Install]
WantedBy=timers.target
EOF

install_if_changed "$SERVICE_TMP" "$TIMER_DIR/vcp-backup.service" 644
install_if_changed "$TIMER_TMP" "$TIMER_DIR/vcp-backup.timer" 644
rm -f "$SERVICE_TMP" "$TIMER_TMP"
chown "$TARGET_USER:$TARGET_USER" \
  "$TIMER_DIR/vcp-backup.service" "$TIMER_DIR/vcp-backup.timer"
ensure_user_unit_enabled "$TARGET_USER" vcp-backup.timer timers.target
verify_file "$TIMER_DIR/vcp-backup.service"
verify_file "$TIMER_DIR/vcp-backup.timer"
verify_user_unit "$TARGET_USER" vcp-backup.timer timers.target

# 4. Enable Timer
if [ -S "/run/user/$(id -u "$TARGET_USER")/bus" ]; then
  success "Timer is active and scheduled for 16:00."
else
  warn "Timer is enabled and pending the next user login."
  exit 20
fi

success "VCP Backup automation setup complete!"
