#!/bin/bash

# ==============================================================================
# Shorin Arch Setup - Main Installer (v4.0 Visual)
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$BASE_DIR/scripts"
STATE_FILE="$BASE_DIR/.install_progress"

source "$SCRIPTS_DIR/00-utils.sh"

# --- Env ---
export DEBUG=${DEBUG:-0}
export CN_MIRROR=${CN_MIRROR:-0}

check_root
chmod +x "$SCRIPTS_DIR"/*.sh

# --- Banners ---
show_banner() {
    clear
    echo -e "${H_CYAN}"
    # Font: Slant (Modified for SHORIN)
cat << "EOF"
   _____ __  ______  ____  _____   __    ___    ____  ________  __
  / ___// / / / __ \/ __ \/  _/ | / /   /   |  / __ \/ ____/ / / /
  \__ \/ /_/ / / / / /_/ // //  |/ /   / /| | / /_/ / /   / /_/ / 
 ___/ / __  / /_/ / _, _// // /|  /   / ___ |/ _, _/ /___/ __  /  
/____/_/ /_/\____/_/ |_/___/_/ |_/   /_/  |_/_/ |_|\____/_/ /_/   
EOF
    echo -e "${NC}"
    echo -e "${H_PURPLE}${BOLD}         :: SHORIN ARCH SETUP :: AUTOMATION PROTOCOL ::${NC}"
    echo ""
}

# --- Dashboard ---
show_dashboard() {
    echo -e "${H_GRAY}┌── SYSTEM ────────────────────────────────────────────────────────────┐${NC}"
    printf "${H_GRAY}│${NC}  %-10s : ${H_WHITE}%-45s${NC} ${H_GRAY}│${NC}\n" "Kernel" "$(uname -r)"
    printf "${H_GRAY}│${NC}  %-10s : ${H_WHITE}%-45s${NC} ${H_GRAY}│${NC}\n" "User" "$(whoami)"
    
    if [ "$CN_MIRROR" == "1" ]; then
        printf "${H_GRAY}│${NC}  %-10s : ${H_YELLOW}%-45s${NC} ${H_GRAY}│${NC}\n" "Network" "CN Optimized (Manual)"
    elif [ "$DEBUG" == "1" ]; then
        printf "${H_GRAY}│${NC}  %-10s : ${H_RED}%-45s${NC} ${H_GRAY}│${NC}\n" "Network" "DEBUG FORCE (CN)"
    else
        printf "${H_GRAY}│${NC}  %-10s : ${H_GREEN}%-45s${NC} ${H_GRAY}│${NC}\n" "Network" "Global Standard"
    fi
    echo -e "${H_GRAY}└──────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# --- Main Loop ---

show_banner
show_dashboard

MODULES=(
    "01-base.sh"
    "02-musthave.sh"
    "03-user.sh"
    "04-niri-setup.sh"
    "07-grub-theme.sh"
    "99-apps.sh"
)

if [ ! -f "$STATE_FILE" ]; then touch "$STATE_FILE"; fi

TOTAL=${#MODULES[@]}
CURRENT=0

log "Initializing sequence..."
sleep 0.5

for module in "${MODULES[@]}"; do
    CURRENT=$((CURRENT + 1))
    script_path="$SCRIPTS_DIR/$module"
    
    if [ ! -f "$script_path" ]; then
        error "Module not found: $module"
        continue
    fi

    # Visual Separator
    section "Module $CURRENT/$TOTAL" "${module%.sh}"

    # Checkpoint
    if grep -q "^${module}$" "$STATE_FILE"; then
        echo -e "   ${H_GREEN}✔ Module previously completed.${NC}"
        read -p "$(echo -e "   ${H_YELLOW}Skip this module? [Y/n] ${NC}")" skip_choice
        skip_choice=${skip_choice:-Y}
        
        if [[ "$skip_choice" =~ ^[Yy]$ ]]; then
            log "Skipping..."
            continue
        else
            log "Force re-running..."
            sed -i "/^${module}$/d" "$STATE_FILE"
        fi
    fi

    # Execute
    bash "$script_path"
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        echo "$module" >> "$STATE_FILE"
    else
        error "CRITICAL FAILURE in $module (Exit Code: $exit_code)"
        echo -e "   See log: ${BOLD}$TEMP_LOG_FILE${NC}"
        exit 1
    fi
done

# --- End ---
clear
show_banner
echo -e "${H_GREEN}${BOLD}   >>> INSTALLATION COMPLETE <<<${NC}"
echo ""
info_kv "Status" "Success"
info_kv "Log File" "$TEMP_LOG_FILE" "(Will be moved to Documents)"

# Archive Log
FINAL_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)
if [ -n "$FINAL_USER" ]; then
    FINAL_DOCS="/home/$FINAL_USER/Documents"
    mkdir -p "$FINAL_DOCS"
    cp "$TEMP_LOG_FILE" "$FINAL_DOCS/log-shorin-arch-setup.txt"
    chown -R "$FINAL_USER:$FINAL_USER" "$FINAL_DOCS"
    log "Log archived to $FINAL_DOCS/log-shorin-arch-setup.txt"
fi

[ -f "$STATE_FILE" ] && rm "$STATE_FILE"

echo ""
echo -e "${H_YELLOW}>>> System requires a REBOOT.${NC}"
for i in {10..1}; do
    echo -ne "\r   ${DIM}Auto-rebooting in ${i}s... (Press 'n' to cancel)${NC}"
    read -t 1 -N 1 input
    if [[ "$input" == "n" || "$input" == "N" ]]; then
        echo -e "\n   ${H_BLUE}Reboot cancelled.${NC}"
        exit 0
    fi
done
echo -e "\n   ${H_GREEN}Rebooting...${NC}"
reboot