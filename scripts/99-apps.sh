#!/bin/bash

# ==============================================================================
# 99-apps.sh - Common Applications (Visual Enhanced)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

check_root

# --- Interrupt Handler ---
trap 'echo -e "\n   ${H_YELLOW}>>> Operation cancelled by user (Ctrl+C). Skipping current item...${NC}"' INT

# ------------------------------------------------------------------------------
# 0. Identify Target User
# ------------------------------------------------------------------------------
section "Phase 5" "Common Applications"

log "Identifying target user..."
DETECTED_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)

if [ -n "$DETECTED_USER" ]; then
    TARGET_USER="$DETECTED_USER"
else
    read -p "   Please enter the target username: " TARGET_USER
fi
HOME_DIR="/home/$TARGET_USER"
info_kv "Target" "$TARGET_USER"

# ------------------------------------------------------------------------------
# 1. User Confirmation
# ------------------------------------------------------------------------------
echo ""
echo -e "   This module reads from: ${BOLD}common-applist.txt${NC}"
echo -e "   Format: ${DIM}lines starting with 'flatpak:' use Flatpak, others use Yay.${NC}"
echo -e "   ${H_YELLOW}Tip: Press Ctrl+C during any install to SKIP that package.${NC}"
echo ""

read -p "$(echo -e "   ${H_CYAN}Install common applications? [Y/n] ${NC}")" choice
choice=${choice:-Y}

if [[ ! "$choice" =~ ^[Yy]$ ]]; then
    log "Skipping application installation."
    trap - INT
    exit 0
fi

# ------------------------------------------------------------------------------
# 2. Parse App List
# ------------------------------------------------------------------------------
log "Parsing application list..."

LIST_FILE="$PARENT_DIR/common-applist.txt"
YAY_APPS=()
FLATPAK_APPS=()
FAILED_PACKAGES=()

if [ -f "$LIST_FILE" ]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(echo "$line" | tr -d '\r' | xargs)
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        if [[ "$line" == flatpak:* ]]; then
            app_id="${line#flatpak:}"
            FLATPAK_APPS+=("$app_id")
        else
            YAY_APPS+=("$line")
        fi
    done < "$LIST_FILE"
    
    info_kv "Queue" "Yay: ${#YAY_APPS[@]}" "Flatpak: ${#FLATPAK_APPS[@]}"
else
    warn "File common-applist.txt not found. Skipping."
    trap - INT
    exit 0
fi

# ------------------------------------------------------------------------------
# 3. Install Applications
# ------------------------------------------------------------------------------

# --- A. Install Yay Apps ---
if [ ${#YAY_APPS[@]} -gt 0 ]; then
    section "Step 1/2" "System Packages (Yay)"
    
    # Configure NOPASSWD
    SUDO_TEMP_FILE="/etc/sudoers.d/99_shorin_installer_apps"
    echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDO_TEMP_FILE"
    chmod 440 "$SUDO_TEMP_FILE"
    
    BATCH_LIST="${YAY_APPS[*]}"
    log "Attempting batch install..."
    
    # Attempt Batch (Using exe for visual feedback)
    # exe will print the command and run it
    exe runuser -u "$TARGET_USER" -- yay -S --noconfirm --needed --answerdiff=None --answerclean=None $BATCH_LIST
    batch_ret=$?
    
    if [ $batch_ret -eq 0 ]; then
        success "Batch install successful."
    elif [ $batch_ret -eq 130 ]; then
        warn "Batch interrupted (Ctrl+C). Switching to One-by-One..."
    else
        warn "Batch failed. Switching to One-by-One..."
    fi
    
    # Fallback / Retry One-by-One
    if [ $batch_ret -ne 0 ]; then
        for pkg in "${YAY_APPS[@]}"; do
            # Attempt 1
            if ! exe runuser -u "$TARGET_USER" -- yay -S --noconfirm --needed --answerdiff=None --answerclean=None "$pkg"; then
                ret=$?
                if [ $ret -eq 130 ]; then
                    warn "Skipped '$pkg' (User Cancelled)."
                    continue 
                fi
                
                # Retry Attempt 2
                warn "Retrying '$pkg'..."
                if ! exe runuser -u "$TARGET_USER" -- yay -S --noconfirm --needed --answerdiff=None --answerclean=None "$pkg"; then
                    ret_retry=$?
                    if [ $ret_retry -eq 130 ]; then
                        warn "Skipped '$pkg' (User Cancelled)."
                    else
                        error "Failed to install: $pkg"
                        FAILED_PACKAGES+=("yay:$pkg")
                    fi
                else
                    success "Installed $pkg (Retry)"
                fi
            else
                success "Installed $pkg"
            fi
        done
    fi
    
    rm -f "$SUDO_TEMP_FILE"
fi

# --- B. Install Flatpak Apps ---
if [ ${#FLATPAK_APPS[@]} -gt 0 ]; then
    section "Step 2/2" "Flatpak Packages"
    
    for app in "${FLATPAK_APPS[@]}"; do
        # Attempt 1
        if ! exe flatpak install -y flathub "$app"; then
            ret=$?
            if [ $ret -eq 130 ]; then
                warn "Skipped '$app' (User Cancelled)."
                continue
            fi
            
            warn "Flatpak failed. Waiting 3s to Retry..."
            sleep 3
            
            # Attempt 2
            if ! exe flatpak install -y flathub "$app"; then
                ret_retry=$?
                if [ $ret_retry -eq 130 ]; then
                    warn "Skipped '$app' (User Cancelled)."
                else
                    error "Failed to install: $app"
                    FAILED_PACKAGES+=("flatpak:$app")
                fi
            else
                success "Installed $app (Retry)"
            fi
        else
            success "Installed $app"
        fi
    done
fi

# ------------------------------------------------------------------------------
# 3.5 Generate Failure Report
# ------------------------------------------------------------------------------
if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
    DOCS_DIR="$HOME_DIR/Documents"
    REPORT_FILE="$DOCS_DIR/安装失败的软件.txt"
    
    if [ ! -d "$DOCS_DIR" ]; then runuser -u "$TARGET_USER" -- mkdir -p "$DOCS_DIR"; fi
    
    echo -e "\n--- Phase 5 (Common Apps) Failures ---" >> "$REPORT_FILE"
    printf "%s\n" "${FAILED_PACKAGES[@]}" >> "$REPORT_FILE"
    chown "$TARGET_USER:$TARGET_USER" "$REPORT_FILE"
    
    warn "Some applications failed. See: Documents/安装失败的软件.txt"
else
    success "App installation phase completed."
fi

# ------------------------------------------------------------------------------
# 4. Steam Locale Fix
# ------------------------------------------------------------------------------
section "Post-Install" "Game Environment Tweaks"

STEAM_desktop_modified=false

# Method 1: Native Steam
NATIVE_DESKTOP="/usr/share/applications/steam.desktop"
if [ -f "$NATIVE_DESKTOP" ]; then
    log "Checking Native Steam..."
    if ! grep -q "env LANG=zh_CN.UTF-8" "$NATIVE_DESKTOP"; then
        exe sed -i 's|^Exec=/usr/bin/steam|Exec=env LANG=zh_CN.UTF-8 /usr/bin/steam|' "$NATIVE_DESKTOP"
        exe sed -i 's|^Exec=steam|Exec=env LANG=zh_CN.UTF-8 steam|' "$NATIVE_DESKTOP"
        success "Patched Native Steam .desktop."
        STEAM_desktop_modified=true
    else
        log "Native Steam already patched."
    fi
fi

# Method 2: Flatpak Steam
if echo "${FLATPAK_APPS[@]}" | grep -q "com.valvesoftware.Steam" || flatpak list | grep -q "com.valvesoftware.Steam"; then
    log "Checking Flatpak Steam..."
    exe flatpak override --env=LANG=zh_CN.UTF-8 com.valvesoftware.Steam
    success "Applied Flatpak Steam override."
    STEAM_desktop_modified=true
fi

if [ "$STEAM_desktop_modified" = false ]; then
    log "Steam not found. Skipping fix."
fi

# Reset Trap
trap - INT

log "Module 99-apps completed."