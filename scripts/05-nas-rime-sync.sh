#!/bin/bash
# 05-nas-rime-sync.sh - Industrial NAS Mount & Rime Sync Automation
# (v5.0 - Self-Contained Retry/Skip, always exits 0 for parent)

ORIGINAL_ARGS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-utils.sh"

check_root

# --- [SELF-CONTAINED RETRY/SKIP] ---
_05_retry_or_skip() {
    echo ""
    echo -e "${H_YELLOW}╭──────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${H_YELLOW}│  NAS/Rime setup finished with $WARN_COUNT warning(s)${NC}"
    echo -e "${H_YELLOW}╰──────────────────────────────────────────────────────────────╯${NC}"
    for w in "${WARN_SUMMARY[@]}"; do
        echo -e "    ${H_YELLOW}• $w${NC}"
    done
    echo ""
    if [ -t 0 ]; then
        while true; do
            read -p "$(echo -e " ${H_CYAN}Retry entire NAS/Rime setup? [y/N]: ${NC}")" choice
            case "${choice:-N}" in
                [Yy]*) warn "Restarting 05..."; exec "$0" "${ORIGINAL_ARGS[@]}" ;;
                [Nn]*|"") warn "Skipping NAS/Rime setup."; exit 0 ;;
                *) echo "Invalid input." ;;
            esac
        done
    else
        warn "Non-interactive. Continuing with warnings."; exit 0
    fi
}

_on_abort() { _05_retry_or_skip; }

# --- [STATE GATES] ---
USER_OK=1
NAS_AVAILABLE=0

# --- [STEP 1: Identify Target User] ---
# Priority: Argument > logname > UID 1000
TARGET_USER="${1:-$(logname 2>/dev/null || awk -F: '$3 == 1000 {print $1}' /etc/passwd | head -n1)}"
HOME_DIR="/home/$TARGET_USER"

if [ ! -d "$HOME_DIR" ]; then
    ask_continue "Home directory for $TARGET_USER not found at $HOME_DIR"
    USER_OK=0
fi

section "NAS" "Persistent NFS Mounting"

log "Installing nfs-utils..."
if ! exe pacman -S --noconfirm --needed nfs-utils; then
    ask_continue "Failed to install nfs-utils"
fi

log "Configuring /etc/fstab for NAS..."
NAS_IP="${NAS_IP:-10.0.0.104}"
NAS_REMOTE_PATH="${NAS_REMOTE_PATH:-/mnt/user/115yun/arch}"
NAS_LOCAL_PATH="${NAS_LOCAL_PATH:-/mnt/nas}"
NAS_LINE="${NAS_IP}:${NAS_REMOTE_PATH} ${NAS_LOCAL_PATH} nfs defaults,_netdev,nofail 0 0"
RIME_SYNC_DIR="${NAS_LOCAL_PATH}/rime_sync"

FSTAB_JUST_WRITTEN=0
if ! grep -v '^[[:space:]]*#' /etc/fstab | grep -qF "${NAS_IP}:${NAS_REMOTE_PATH}"; then
    if ! mkdir -p "${NAS_LOCAL_PATH}"; then
        ask_continue "Failed to create mount point ${NAS_LOCAL_PATH}"
    fi
    FSTAB_BACKUP="/etc/fstab.bak_$(date +%s)"
    if cp /etc/fstab "$FSTAB_BACKUP"; then
        if echo "$NAS_LINE" >> /etc/fstab; then
            FSTAB_JUST_WRITTEN=1
            success "NFS entry added to fstab."
        else
            warn "fstab write failed. Rolling back..."
            cp "$FSTAB_BACKUP" /etc/fstab
            ask_continue "Failed to write NFS entry to fstab (rolled back)"
        fi
    else
        ask_continue "Failed to backup fstab before modification"
    fi
else
    log "NFS entry already exists in fstab."
fi

# Handle Stale File Handle before mounting
if mountpoint -q "${NAS_LOCAL_PATH}"; then
    if ! timeout 2 ls "${NAS_LOCAL_PATH}" >/dev/null 2>&1; then
        warn "Stale NFS handle detected at ${NAS_LOCAL_PATH}. Cleaning up..."
        if ! umount -f -l "${NAS_LOCAL_PATH}" 2>/dev/null; then
            ask_continue "Failed to unmount stale NFS handle at ${NAS_LOCAL_PATH}"
        fi
    fi
fi

log "Mounting NAS..."
if mountpoint -q "${NAS_LOCAL_PATH}" 2>/dev/null && timeout 3 ls "${NAS_LOCAL_PATH}" >/dev/null 2>&1; then
    NAS_AVAILABLE=1
    success "NAS already mounted and accessible at ${NAS_LOCAL_PATH}."
elif timeout 30 mount "${NAS_LOCAL_PATH}" 2>/dev/null && timeout 3 ls "${NAS_LOCAL_PATH}" >/dev/null 2>&1; then
    NAS_AVAILABLE=1
    success "NAS mounted and accessible at ${NAS_LOCAL_PATH}."
else
    if [ "$FSTAB_JUST_WRITTEN" -eq 1 ] && [ -n "$FSTAB_BACKUP" ]; then
        warn "Mount failed after fstab write. Rolling back fstab entry."
        cp "$FSTAB_BACKUP" /etc/fstab
    fi
    ask_continue "NAS mount failed or not accessible at ${NAS_LOCAL_PATH}"
fi

if [ "$USER_OK" -eq 1 ]; then

section "Rime" "Configuration & Sync"

log "Setting up Rime sync directory for $TARGET_USER..."
RIME_DIR="$HOME_DIR/.local/share/fcitx5/rime"
INSTALL_YAML="$RIME_DIR/installation.yaml"

# Ensure directory exists and has correct ownership
if ! mkdir -p "$RIME_DIR" 2>/dev/null; then
    ask_continue "Failed to create Rime directory $RIME_DIR"
fi
if ! chown "$TARGET_USER:$TARGET_USER" "$RIME_DIR" 2>/dev/null; then
    ask_continue "Failed to set ownership on $RIME_DIR"
fi

# Robustly set installation_id and sync_dir
if [ ! -f "$INSTALL_YAML" ]; then
    cat > "$INSTALL_YAML" <<EOF
installation_id: "shiyi_arch"
sync_dir: "$RIME_SYNC_DIR"
EOF
else
    # Atomic update using temp file
    TEMP_YAML=$(mktemp) || { ask_continue "mktemp failed for installation.yaml update"; TEMP_YAML=""; }
    if [ -n "$TEMP_YAML" ]; then
        if ! cp "$INSTALL_YAML" "$TEMP_YAML"; then
            rm -f "$TEMP_YAML"
            ask_continue "Failed to copy installation.yaml to temp file"
        else
            sed -i 's|^installation_id:.*|installation_id: "shiyi_arch"|' "$TEMP_YAML"
            if ! grep -q "installation_id:" "$TEMP_YAML"; then echo 'installation_id: "shiyi_arch"' >> "$TEMP_YAML"; fi
            sed -i "s|^sync_dir:.*|sync_dir: \"$RIME_SYNC_DIR\"|" "$TEMP_YAML"
            if ! grep -q "sync_dir:" "$TEMP_YAML"; then echo "sync_dir: \"$RIME_SYNC_DIR\"" >> "$TEMP_YAML"; fi
            if ! mv "$TEMP_YAML" "$INSTALL_YAML"; then
                rm -f "$TEMP_YAML"
                ask_continue "Failed to move temp file to installation.yaml"
            fi
        fi
    fi
fi

if ! chown "$TARGET_USER:$TARGET_USER" "$INSTALL_YAML" 2>/dev/null; then
    ask_continue "Failed to set ownership on $INSTALL_YAML"
fi
if [ -f "$INSTALL_YAML" ] && grep -q 'installation_id: "shiyi_arch"' "$INSTALL_YAML" && grep -q "sync_dir:" "$INSTALL_YAML"; then
    success "Rime installation.yaml configured (ID: shiyi_arch, sync: $RIME_SYNC_DIR)."
else
    ask_continue "installation.yaml values not correctly set (expected id=shiyi_arch, sync=$RIME_SYNC_DIR)"
fi

# Trigger initial sync (gated by NAS_AVAILABLE)
if [ "$NAS_AVAILABLE" -eq 1 ] && command -v rime_dict_manager &>/dev/null; then
    if [ -d "$RIME_SYNC_DIR" ]; then
        log "Triggering initial Rime sync to restore user dictionary..."
        runuser -u "$TARGET_USER" -- rime_dict_manager -s || warn "Initial sync returned non-zero, check logs."
        success "Initial sync triggered."
    else
        warn "NAS sync directory $RIME_SYNC_DIR not found. Dictionary restore skipped."
    fi
elif [ "$NAS_AVAILABLE" -eq 0 ]; then
    warn "NAS not available. Skipping dictionary restore."
else
    warn "rime_dict_manager not found. Restore will happen after fcitx5-rime installation."
fi

section "Systemd" "Automated Backup Timer"

log "Creating hourly rime-sync timer for user $TARGET_USER..."
TIMER_DIR="$HOME_DIR/.config/systemd/user"
TIMER_DIR_OK=1

# Gate: rime_dict_manager must exist, otherwise timer will produce periodic failures
if ! command -v rime_dict_manager &>/dev/null; then
    warn "rime_dict_manager not found. Skipping systemd timer (install fcitx5-rime first, then re-run)."
    TIMER_DIR_OK=0
fi

if [ "$TIMER_DIR_OK" -eq 1 ] && ! mkdir -p "$TIMER_DIR" 2>/dev/null; then
    ask_continue "Failed to create systemd user directory $TIMER_DIR"
    TIMER_DIR_OK=0
fi

if [ "$TIMER_DIR_OK" -eq 1 ]; then
# [FIX] Added ExecStartPre mount check and improved service unit
cat > "$TIMER_DIR/rime-sync.service" <<SERVICE
[Unit]
Description=Rime Dictionary Sync
After=network-online.target
ConditionPathIsMountPoint=$NAS_LOCAL_PATH

[Service]
Type=oneshot
# Ensure dependencies and sync_dir exist before running
ExecStartPre=/usr/bin/test -x /usr/bin/rime_dict_manager
ExecStartPre=/usr/bin/test -d "$RIME_SYNC_DIR"
ExecStart=/usr/bin/rime_dict_manager -s
WorkingDirectory=$RIME_DIR

[Install]
WantedBy=default.target
SERVICE

cat > "$TIMER_DIR/rime-sync.timer" <<TIMER
[Unit]
Description=Hourly Rime Sync Timer

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
TIMER

# Verify systemd units were written (content check, not just size)
if [ ! -s "$TIMER_DIR/rime-sync.service" ] || ! grep -q "ExecStart" "$TIMER_DIR/rime-sync.service"; then
    ask_continue "rime-sync.service content verification failed"
fi
if [ ! -s "$TIMER_DIR/rime-sync.timer" ] || ! grep -q "OnCalendar" "$TIMER_DIR/rime-sync.timer"; then
    ask_continue "rime-sync.timer content verification failed"
fi
fi  # end TIMER_DIR_OK gate

if ! chown -R "$TARGET_USER:$TARGET_USER" "$TIMER_DIR" 2>/dev/null; then
    ask_continue "Failed to set ownership on $TIMER_DIR"
fi

# Enable linger and timer (persistent side-effects, soft-failure)
if [ -z "${CHROOT_ACTIVE:-}" ]; then
    log "Enabling linger for $TARGET_USER (persistent side-effect)..."
    if ! loginctl enable-linger "$TARGET_USER" 2>/dev/null; then
        ask_continue "Failed to enable linger for $TARGET_USER"
    fi
    log "Enabling rime-sync.timer for $TARGET_USER..."
    if ! runuser -u "$TARGET_USER" -- env XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")" systemctl --user enable --now rime-sync.timer 2>/dev/null; then
        ask_continue "Timer not auto-enabled (no active session). Manual: systemctl --user enable --now rime-sync.timer"
    else
        success "Timer enabled and started."
    fi
fi

else
    warn "Skipping Rime & Systemd setup (user context unavailable)."
fi  # end USER_OK gate

# --- [FINAL DECISION] ---
if [ "$WARN_COUNT" -gt 0 ]; then
    _05_retry_or_skip
else
    success "NAS & Rime Sync setup completed successfully."
fi
exit 0
