#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR
# 05-nas-rime-sync.sh - Industrial NAS Mount & Rime Sync Automation
# (v6.0 - Desired-state convergence with explicit optional status)

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
                [Nn]*|"") warn "NAS/Rime setup remains incomplete."; exit 1 ;;
                *) echo "Invalid input." ;;
            esac
        done
    else
        warn "Non-interactive NAS/Rime setup failed."; exit 1
    fi
}

_on_abort() { _05_retry_or_skip; }

# --- [STATE GATES] ---
USER_OK=1
NAS_AVAILABLE=0
MODULE_PENDING=0

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
if ! ensure_package nfs-utils; then
    ask_continue "Failed to install nfs-utils"
fi

log "Configuring /etc/fstab for NAS..."
NAS_IP="${NAS_IP:-10.0.0.104}"
NAS_REMOTE_PATH="${NAS_REMOTE_PATH:-/mnt/user/115yun/arch}"
NAS_LOCAL_PATH="${NAS_LOCAL_PATH:-/mnt/nas}"
NAS_LINE="${NAS_IP}:${NAS_REMOTE_PATH} ${NAS_LOCAL_PATH} nfs defaults,_netdev,nofail 0 0"
RIME_SYNC_DIR="${NAS_LOCAL_PATH}/rime_sync"

mkdir -p "${NAS_LOCAL_PATH}"
if ! ensure_fstab_entry "${NAS_IP}:${NAS_REMOTE_PATH}" "$NAS_LOCAL_PATH" \
    nfs 'defaults,_netdev,nofail'; then
    ask_continue "Failed to converge or validate the NAS fstab entry"
else
    success "NFS entry converged and validated."
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
TEMP_YAML=$(mktemp)
if [ -f "$INSTALL_YAML" ]; then
    awk '$1 != "installation_id:" && $1 != "sync_dir:" { print }' \
        "$INSTALL_YAML" > "$TEMP_YAML"
fi
printf 'installation_id: "shiyi_arch"\nsync_dir: "%s"\n' \
    "$RIME_SYNC_DIR" >> "$TEMP_YAML"
install_if_changed "$TEMP_YAML" "$INSTALL_YAML" 644
rm -f "$TEMP_YAML"

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
        if runuser -u "$TARGET_USER" -- rime_dict_manager -s; then
            success "Initial sync completed."
        else
            ask_continue "Initial Rime sync failed"
        fi
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
    MODULE_PENDING=1
fi

if [ "$TIMER_DIR_OK" -eq 1 ] && ! mkdir -p "$TIMER_DIR" 2>/dev/null; then
    ask_continue "Failed to create systemd user directory $TIMER_DIR"
    TIMER_DIR_OK=0
fi

if [ "$TIMER_DIR_OK" -eq 1 ]; then
SERVICE_TMP=$(mktemp)
TIMER_TMP=$(mktemp)
cat > "$SERVICE_TMP" <<SERVICE
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

cat > "$TIMER_TMP" <<TIMER
[Unit]
Description=Hourly Rime Sync Timer

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
TIMER

install_if_changed "$SERVICE_TMP" "$TIMER_DIR/rime-sync.service" 644
install_if_changed "$TIMER_TMP" "$TIMER_DIR/rime-sync.timer" 644
rm -f "$SERVICE_TMP" "$TIMER_TMP"
chown "$TARGET_USER:$TARGET_USER" \
    "$TIMER_DIR/rime-sync.service" "$TIMER_DIR/rime-sync.timer"

# Verify systemd units were written (content check, not just size)
if [ ! -s "$TIMER_DIR/rime-sync.service" ] || ! grep -q "ExecStart" "$TIMER_DIR/rime-sync.service"; then
    ask_continue "rime-sync.service content verification failed"
fi
if [ ! -s "$TIMER_DIR/rime-sync.timer" ] || ! grep -q "OnCalendar" "$TIMER_DIR/rime-sync.timer"; then
    ask_continue "rime-sync.timer content verification failed"
fi
fi  # end TIMER_DIR_OK gate

# Enable linger when available, but always create the offline wants link.
if [ -z "${CHROOT_ACTIVE:-}" ]; then
    log "Enabling linger for $TARGET_USER (persistent side-effect)..."
    if ! loginctl enable-linger "$TARGET_USER" 2>/dev/null; then
        ask_continue "Failed to enable linger for $TARGET_USER"
    fi
fi
if [ "$TIMER_DIR_OK" -eq 1 ]; then
    log "Enabling rime-sync.timer for $TARGET_USER..."
    ensure_user_unit_enabled "$TARGET_USER" rime-sync.timer timers.target
    verify_file "$TIMER_DIR/rime-sync.service"
    verify_file "$TIMER_DIR/rime-sync.timer"
    verify_user_unit "$TARGET_USER" rime-sync.timer timers.target
    if [ ! -S "/run/user/$(id -u "$TARGET_USER")/bus" ]; then
        MODULE_PENDING=1
    fi
fi

else
    warn "Skipping Rime & Systemd setup (user context unavailable)."
fi  # end USER_OK gate

# --- [FINAL DECISION] ---
if [ "$WARN_COUNT" -gt 0 ]; then
    _05_retry_or_skip
elif [ "$MODULE_PENDING" -eq 1 ]; then
    warn "NAS/Rime targets are installed but pending an external prerequisite or user login."
    exit 20
else
    success "NAS & Rime Sync setup completed successfully."
fi
exit 0
