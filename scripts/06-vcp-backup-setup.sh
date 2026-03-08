#!/bin/bash
# 06-vcp-backup-setup.sh - VCPChat NAS Backup Automation Installer
# (v1.0 - Hot-plug Mount, Whitelist Sync, 16:00 Timer)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-utils.sh"

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
  log "Skipping setup. Please ensure VCPChat is installed first."
  exit 0
fi

# 2. Sudoers Management (Scripted)
log "Configuring sudoers for passwordless mount/umount..."
cat >"$SUDOERS_FILE" <<EOF
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/mount, /usr/bin/umount, /usr/bin/mkdir
EOF
chmod 440 "$SUDOERS_FILE"
success "Sudoers entry created at $SUDOERS_FILE"

# 3. Systemd User Timer Setup
log "Setting up Systemd User Timer (Daily 16:00)..."
TIMER_DIR="$HOME_DIR/.config/systemd/user"
as_user mkdir -p "$TIMER_DIR"

# Create Service Unit
cat >"$TIMER_DIR/vcp-backup.service" <<EOF
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
cat >"$TIMER_DIR/vcp-backup.timer" <<EOF
[Unit]
Description=Run VCPChat Backup at 16:00 Daily

[Timer]
OnCalendar=*-*-* 16:00:00
Persistent=true
Unit=vcp-backup.service

[Install]
WantedBy=timers.target
EOF

chown -R "$TARGET_USER:$TARGET_USER" "$TIMER_DIR"

# 4. Enable Timer
if [ -z "${CHROOT_ACTIVE:-}" ]; then
  log "Enabling and starting vcp-backup.timer..."
  as_user env XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")" systemctl --user daemon-reload
  as_user env XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")" systemctl --user enable --now vcp-backup.timer
  success "Timer is active and scheduled for 16:00."
fi

success "VCP Backup automation setup complete!"

