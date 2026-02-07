#!/bin/bash
# ==============================================================================
# 04f-nagisa-quickshell-setup.sh - Nagisa's Industrial Niri + QuickShell Setup
# (Full Parity, Edge-Case Patches & Robust Injection v4.0)
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

UNDO_SCRIPT="$SCRIPT_DIR/niri-undochange.sh"
SUDO_TEMP_FILE="/etc/sudoers.d/99_shorin_installer_temp"
TEMP_DIR="/tmp/shorin-repo"

check_root

# --- [HELPER FUNCTIONS] ---

cleanup_handler() {
    [ -f "$SUDO_TEMP_FILE" ] && rm -f "$SUDO_TEMP_FILE" && log "Temporary sudoers privilege revoked."
    [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
}
trap cleanup_handler EXIT

critical_failure_handler() {
    local failed_reason="$1"
    trap - ERR
    echo ""
    echo -e "\033[0;31m################################################################\033[0m"
    echo -e "\033[0;31m#                                                              #\033[0m"
    echo -e "\033[0;31m#           CRITICAL INSTALLATION FAILURE DETECTED             #\033[0m"
    echo -e "\033[0;31m#                                                              #\033[0m"
    echo -e "\033[0;31m# Reason: $failed_reason\033[0m"
    echo -e "\033[0;31m#                                                              #\033[0m"
    echo -e "\033[0;31m# OPTIONS:                                                     #\033[0m"
    echo -e "\033[0;31m# 1. Restore snapshot (Undo changes & Exit)                    #\033[0m"
    echo -e "\033[0;31m# 2. Retry / Re-run script                                     #\033[0m"
    echo -e "\033[0;31m# 3. Abort (Exit immediately)                                  #\033[0m"
    echo -e "\033[0;31m#                                                              #\033[0m"
    echo -e "\033[0;31m################################################################\033[0m"
    echo ""
    while true; do
        read -p "Select an option [1-3]: " -r choice
        case "$choice" in
            1) if [ -f "$UNDO_SCRIPT" ]; then bash "$UNDO_SCRIPT"; exit 1; else error "Undo script missing!"; exit 1; fi ;;
            2) warn "Restarting script..."; exec "$0" "$@" ;;
            3) cleanup_handler; error "Installation aborted."; exit 1 ;;
            *) echo "Invalid input." ;;
        esac
    done
}

ensure_package_installed() {
    local pkg="$1"
    local context="$2"
    local max_attempts=3
    local attempt=1
    if pacman -Q "$pkg" &>/dev/null; then return 0; fi
    while [ $attempt -le $max_attempts ]; do
        log "Installing '$pkg' ($context)... (Attempt $attempt/$max_attempts)"
        if as_user yay -S --noconfirm --needed --answerdiff=None --answerclean=None "$pkg"; then
            if pacman -Q "$pkg" &>/dev/null; then return 0; fi
        fi
        ((attempt++))
        sleep 2
    done
    critical_failure_handler "Failed to install '$pkg' after $max_attempts attempts."
}

section "Phase 4-F" "Nagisa's Niri + QuickShell Industrial Setup"
trap 'critical_failure_handler "Script Error at Line $LINENO"' ERR

# --- [STEP 1: Identify User & DM Check] ---
log "Identifying user..."
DETECTED_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)
TARGET_USER="${DETECTED_USER:-shiyi}"
HOME_DIR="/home/$TARGET_USER"
info_kv "Target" "$TARGET_USER"

KNOWN_DMS=("gdm" "sddm" "lightdm" "lxdm" "slim" "xorg-xdm" "ly" "greetd")
SKIP_AUTOLOGIN=false
DM_FOUND=""
for dm in "${KNOWN_DMS[@]}"; do
    if pacman -Q "$dm" &>/dev/null; then DM_FOUND="$dm"; break; fi
done

if [ -n "$DM_FOUND" ]; then
    info_kv "Conflict" "${H_RED}$DM_FOUND${NC}"
    SKIP_AUTOLOGIN=true
else
    read -t 20 -p "$(echo -e " ${H_CYAN}Enable TTY auto-login? [Y/n] (Default Y): ${NC}")" choice || true
    [[ "${choice:-Y}" =~ ^[Yy]$ ]] && SKIP_AUTOLOGIN=false || SKIP_AUTOLOGIN=true
fi

# --- [STEP 2: Temp Sudo Privilege] ---
echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" >"$SUDO_TEMP_FILE"
chmod 440 "$SUDO_TEMP_FILE"
log "Temporary sudoers privilege granted."

# --- [STEP 3: Core Components & Firefox/Nautilus Patches] ---
section "Step 1/9" "Core Components & System Patches"
PKGS="niri xdg-desktop-portal-gnome xdg-desktop-portal-gtk fuzzel kitty firefox libnotify mako polkit-gnome nautilus gvfs-smb"
exe pacman -S --noconfirm --needed $PKGS

# 1. Firefox Policies (Parity with 04-niri)
log "Configuring Firefox Policies..."
POL_DIR="/etc/firefox/policies"
exe mkdir -p "$POL_DIR"
echo '{ "policies": { "Extensions": { "Install": ["https://addons.mozilla.org/firefox/downloads/latest/pywalfox/latest.xpi"] } } }' >"$POL_DIR/policies.json"
exe chmod 755 "$POL_DIR" && exe chmod 644 "$POL_DIR/policies.json"

# 2. Nautilus & Terminal Fixes (Parity with 04-niri)
exe pacman -S --noconfirm --needed ffmpegthumbnailer nautilus-open-any-terminal file-roller gnome-keyring gst-plugins-base gst-plugins-good gst-libav
if [ ! -f /usr/bin/gnome-terminal ] || [ -L /usr/bin/gnome-terminal ]; then
    exe ln -sf /usr/bin/kitty /usr/bin/gnome-terminal
fi

# 3. Nautilus NVIDIA/Input Patch (Parity with 04-niri)
DESKTOP_FILE="/usr/share/applications/org.gnome.Nautilus.desktop"
if [ -f "$DESKTOP_FILE" ]; then
    GPU_COUNT=$(lspci | grep -E -i "vga|3d" | wc -l)
    HAS_NVIDIA=$(lspci | grep -E -i "nvidia" | wc -l)
    ENV_VARS="env GTK_IM_MODULE=fcitx"
    [ "$GPU_COUNT" -gt 1 ] && [ "$HAS_NVIDIA" -gt 0 ] && ENV_VARS="env GSK_RENDERER=gl GTK_IM_MODULE=fcitx"
    if ! grep -q "^Exec=$ENV_VARS" "$DESKTOP_FILE"; then
        exe sed -i "s|^Exec=|Exec=$ENV_VARS |" "$DESKTOP_FILE"
    fi
fi

# --- [STEP 4: QuickShell Suite] ---
section "Step 2/9" "QuickShell Suite"
for pkg in quickshell qt6-wayland matugen-bin swww swayidle swaylock-effects; do
    ensure_package_installed "$pkg" "QuickShell Suite"
done

# --- [STEP 5: Dependencies with FZF Selection] ---
section "Step 3/9" "Applist Selection"
LIST_FILE="$PARENT_DIR/niri-applist.txt"
command -v fzf &>/dev/null || pacman -S --noconfirm fzf >/dev/null 2>&1

if [ -f "$LIST_FILE" ]; then
    mapfile -t DEFAULT_LIST < <(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | sed 's/#.*//; s/AUR://g' | xargs -n1)
    echo -e "\n ${H_YELLOW}>>> Default installation in 60s. Press ANY KEY to customize...${NC}"
    if read -t 60 -n 1 -s -r; then
        clear
        SELECTED_LINES=$(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | sed -E 's/[[:space:]]+#/\t#/' | fzf --multi --layout=reverse --header="[TAB] TOGGLE | [ENTER] INSTALL" --with-nth=1)
        if [ -z "$SELECTED_LINES" ]; then
            warn "No selection. Skipping optional apps."
            PACKAGE_ARRAY=()
        else
            PACKAGE_ARRAY=()
            while IFS= read -r line; do
                raw_pkg=$(echo "$line" | cut -f1 -d$'\t' | xargs)
                clean_pkg="${raw_pkg#AUR:}"
                [ -n "$clean_pkg" ] && PACKAGE_ARRAY+=("$clean_pkg")
            done <<<"$SELECTED_LINES"
        fi
    else
        log "Auto-confirming ALL packages."
        PACKAGE_ARRAY=("${DEFAULT_LIST[@]}")
    fi

    for pkg in "${PACKAGE_ARRAY[@]}"; do
        [[ "$pkg" =~ "waybar" ]] && continue
        ensure_package_installed "$pkg" "Applist"
    done
fi

# --- [STEP 6: Dotfiles & Verified Backup] ---
section "Step 4/9" "Dotfiles & Multi-Source"
REPO_GITHUB="https://github.com/awei807-wei/ShorinArchExperience-ArchlinuxGuide.git"
REPO_GITEE="https://gitee.com/shorinkiwata/ShorinArchExperience-ArchlinuxGuide.git"
rm -rf "$TEMP_DIR"

if ! as_user git clone "$REPO_GITHUB" "$TEMP_DIR"; then
    warn "GitHub failed, trying Gitee..."
    as_user git clone "$REPO_GITEE" "$TEMP_DIR" || critical_failure_handler "Failed to clone dotfiles."
fi

if [ -d "$TEMP_DIR/dotfiles" ]; then
    log "Backing up current .config (Verified)..."
    BACKUP_NAME="$HOME_DIR/config_backup_$(date +%s).tar.gz"
    if ! as_user tar -czf "$BACKUP_NAME" -C "$HOME_DIR" .config; then
        critical_failure_handler "Backup failed! Aborting to prevent data loss."
    fi
    success "Backup created: $BACKUP_NAME"

    # Rime-Ice
    RIME_DIR="$HOME_DIR/.local/share/fcitx5/rime"
    if [ ! -d "$RIME_DIR/.git" ]; then
        as_user mkdir -p "$(dirname "$RIME_DIR")"
        as_user git clone --depth=1 https://github.com/iDvel/rime-ice.git "$RIME_DIR"
    fi

    log "Applying configurations..."
    as_user cp -rf "$TEMP_DIR/dotfiles/." "$HOME_DIR/"
    
    # Robust Niri QuickShell Injection (Improved Logic)
    NIRI_CONFIG="$HOME_DIR/.config/niri/config.kdl"
    if [ -f "$NIRI_CONFIG" ]; then
        # 1. Disable conflicting bars
        as_user sed -i 's/spawn-at-startup "waybar"/# spawn-at-startup "waybar"/' "$NIRI_CONFIG"
        as_user sed -i 's/spawn-at-startup "ags run"/# spawn-at-startup "ags run"/' "$NIRI_CONFIG"
        # 2. Robust Injection of QuickShell
        if ! grep -q "quickshell" "$NIRI_CONFIG"; then
            log "Injecting QuickShell startup into niri config..."
            # Try to inject after any spawn-at-startup line, or just append to end
            if grep -q "spawn-at-startup" "$NIRI_CONFIG"; then
                as_user sed -i '/spawn-at-startup/a \    spawn-at-startup "quickshell"' "$NIRI_CONFIG"
            else
                as_user bash -c "echo 'spawn-at-startup \"quickshell\"' >> '$NIRI_CONFIG'"
            fi
        fi
        success "Niri config updated for QuickShell."
    fi
fi

# --- [STEP 7: Environment & Theming] ---
section "Step 5/9" "Environment Fixes"
as_user mkdir -p "$HOME_DIR/.config/xdg-desktop-portal"
as_user printf "[preferred]\ndefault=gtk\n" > "$HOME_DIR/.config/xdg-desktop-portal/portals.conf"

BOOKMARKS_FILE="$HOME_DIR/.config/gtk-3.0/bookmarks"
[ -f "$BOOKMARKS_FILE" ] && as_user sed -i "s/shorin/$TARGET_USER/g" "$BOOKMARKS_FILE"

# --- [STEP 8: Wallpapers & Permissions] ---
section "Step 6/9" "Wallpapers & Permissions"
if [ -d "$TEMP_DIR/wallpapers" ]; then
    as_user mkdir -p "$HOME_DIR/Pictures/Wallpapers"
    as_user cp -rf "$TEMP_DIR/wallpapers/." "$HOME_DIR/Pictures/Wallpapers/"
fi

pacman -Q swayosd &>/dev/null && systemctl enable --now swayosd-libinput-backend.service >/dev/null 2>&1
chown -R "$TARGET_USER" "$HOME_DIR/.config"

# --- [STEP 9: Auto-Login] ---
section "Step 7/9" "Finalizing"
if [ "$SKIP_AUTOLOGIN" = false ]; then
    mkdir -p "/etc/systemd/system/getty@tty1.service.d"
    echo -e "[Service]\nExecStart=\nExecStart=-/sbin/agetty --noreset --noclear --autologin $TARGET_USER - \${TERM}" >"/etc/systemd/system/getty@tty1.service.d/autologin.conf"
fi

success "Nagisa's Niri + QuickShell Industrial Setup Completed!"