#!/bin/bash
# ==============================================================================
# install.sh - Shorin Arch Setup Entry Point
# (Reconstructed by Piko v5.0 - 2026-03-15)
# ==============================================================================

set -e
export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPTS_PATH="$SCRIPT_DIR/scripts"

# Load UI Engine
if [ -f "$SCRIPTS_PATH/00-utils.sh" ]; then
    source "$SCRIPTS_PATH/00-utils.sh"
else
    echo "Error: scripts/00-utils.sh not found!"
    exit 1
fi

check_root

# --- [MODULE DEFINITIONS] ---

BASE_MODULES=(
    "00-btrfs-init.sh"
    "01-base.sh"
    "02-musthave.sh"
    "02a-dualboot-fix.sh"
    "03-user.sh"
    "03b-gpu-driver.sh"
    "03c-snapshot-before-desktop.sh"
)

# Desktop Scripts (add your own here)
DESKTOP_SCRIPTS=(
    "Niri|04-niri-setup.sh"
)

select_desktop() {
    section "Desktop Environment" "Select your setup"
    local count=${#DESKTOP_SCRIPTS[@]}
    for i in "${!DESKTOP_SCRIPTS[@]}"; do
        local label="${DESKTOP_SCRIPTS[$i]%%|*}"
        echo -e "${H_BLUE}$((i+1)))${NC} $label"
    done
    echo -ne "${H_YELLOW}Choice [1-$count]: ${NC}"
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
        DESKTOP_SCRIPT="${DESKTOP_SCRIPTS[$((choice-1))]#*|}"
    else
        warn "Invalid choice, skipping desktop setup."
        DESKTOP_SCRIPT=""
    fi
}

# Post-install & VCP Modules
FINAL_MODULES=(
    "05-nas-rime-sync.sh"
    "06-vcp-backup-setup.sh"
    "08-vcp-desktop-entry.sh"
    "99-apps.sh"
    "07-grub-theme.sh"
)

# --- [MAIN EXECUTION] ---

clear
section "Shorin Arch Setup" "System Deployment Started"

# 1. Execute Base Modules
for script in "${BASE_MODULES[@]}"; do
    if [ -f "$SCRIPTS_PATH/$script" ]; then
        bash "$SCRIPTS_PATH/$script"
    else
        warn "Module $script not found, skipping."
    fi
done

# 2. Select & Execute Desktop Setup
select_desktop
if [ -n "$DESKTOP_SCRIPT" ] && [ -f "$SCRIPTS_PATH/$DESKTOP_SCRIPT" ]; then
    bash "$SCRIPTS_PATH/$DESKTOP_SCRIPT"
fi

# 3. Execute Finalization Modules
for script in "${FINAL_MODULES[@]}"; do
    if [ -f "$SCRIPTS_PATH/$script" ]; then
        bash "$SCRIPTS_PATH/$script"
    else
        log "Optional module $script not found, skipping."
    fi
done

success "Full system installation complete! Please reboot to enjoy your new Arch Linux."