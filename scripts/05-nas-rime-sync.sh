#!/bin/bash
# 05-nas-rime-sync.sh - NAS Mount & Rime Sync Automation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-utils.sh"

check_root

section "NAS" "Persistent NFS Mounting"
log "Installing nfs-utils..."
exe pacman -S --noconfirm --needed nfs-utils

log "Configuring /etc/fstab for NAS..."
NAS_IP="10.0.0.104"
NAS_REMOTE_PATH="/mnt/user/115yun/arch"
NAS_LOCAL_PATH="/mnt/nas"
NAS_LINE="${NAS_IP}:${NAS_REMOTE_PATH} ${NAS_LOCAL_PATH} nfs defaults,_netdev,nofail 0 0"

if ! grep -q "${NAS_REMOTE_PATH}" /etc/fstab
then
    exe_silent mkdir -p "${NAS_LOCAL_PATH}"
    echo "$NAS_LINE" | tee -a /etc/fstab
    success "NFS entry added to fstab."
else
    log "NFS entry already exists in fstab."
fi
exe mount -a

section "Rime" "Advanced Configuration & Sync"
log "Setting up Rime sync directory..."
REAL_USER=$(logname)
RIME_DIR="/home/${REAL_USER}/.local/share/fcitx5/rime"
INSTALL_YAML="$RIME_DIR/installation.yaml"

if [ -f "$INSTALL_YAML" ]
then
    sed -i 's|^sync_dir:.*|sync_dir: "/mnt/nas/rime_sync"|' "$INSTALL_YAML"
    success "Sync directory set to /mnt/nas/rime_sync."
else
    warn "installation.yaml not found at $RIME_DIR. Skipping path patch."
fi

section "Systemd" "Automated Backup Timer"
log "Creating hourly rime-sync timer for user ${REAL_USER}..."
TIMER_DIR="/home/${REAL_USER}/.config/systemd/user"
exe_silent mkdir -p "$TIMER_DIR"

cat <<SERVICE > "$TIMER_DIR/rime-sync.service"
[Unit]
Description=Rime Dictionary Sync
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/rime_dict_manager -s
WorkingDirectory=$RIME_DIR

[Install]
WantedBy=default.target
SERVICE

cat <<TIMER > "$TIMER_DIR/rime-sync.timer"
[Unit]
Description=Hourly Rime Sync Timer

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
TIMER

chown -R "${REAL_USER}:${REAL_USER}" "$TIMER_DIR"

success "Systemd units created. User can enable them with: systemctl --user enable --now rime-sync.timer"