#!/bin/bash
# ==============================================================================
# 04f-nagisa-quickshell-setup.sh - Nagisa's Custom Niri + QuickShell Environment
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

check_root

# --- [1. Identify User] ---
DETECTED_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)
TARGET_USER="${DETECTED_USER:-shiyi}"
HOME_DIR="/home/$TARGET_USER"

section "Phase 4-F" "Nagisa's Niri + QuickShell Custom Setup"

# --- [2. Core Packages] ---
# 移除了 AGS，增加了 QuickShell
PKGS="niri xdg-desktop-portal-gnome xdg-desktop-portal-gtk fuzzel kitty firefox libnotify mako polkit-gnome nautilus gvfs-smb"
# QuickShell 及其常用依赖
QS_PKGS="quickshell qt6-wayland matugen-bin swww swayidle swaylock-effects"

log "Installing Core Components..."
exe pacman -S --noconfirm --needed $PKGS

log "Installing QuickShell Suite (AUR)..."
as_user yay -S --noconfirm --needed $QS_PKGS

# --- [3. Portal Priority Fix] ---
section "Step 2/5" "Portal Fix (GTK Priority)"
PORTAL_CONF_DIR="$HOME_DIR/.config/xdg-desktop-portal"
as_user mkdir -p "$PORTAL_CONF_DIR"
as_user printf "[preferred]\ndefault=gtk\n" > "$PORTAL_CONF_DIR/portals.conf"

# --- [4. Deploy Dotfiles] ---
section "Step 3/5" "Deploying Nagisa's Dotfiles"
REPO_GITHUB="https://github.com/awei807-wei/ShorinArchExperience-ArchlinuxGuide.git"
TEMP_DIR="/tmp/shorin-repo"
rm -rf "$TEMP_DIR"

log "Cloning personal repo..."
as_user git clone "$REPO_GITHUB" "$TEMP_DIR"

if [ -d "$TEMP_DIR/dotfiles" ]; then
    log "Applying configuration..."
    as_user cp -rf "$TEMP_DIR/dotfiles/." "$HOME_DIR/"
    
    # Sanitize Niri config (Remove any stray waybar/ags launches)
    NIRI_CONFIG="$HOME_DIR/.config/niri/config.kdl"
    if [ -f "$NIRI_CONFIG" ]; then
        as_user sed -i 's/& \/usr\/lib\/xdg-desktop-portal-gnome//' "$NIRI_CONFIG"
        as_user sed -i 's/spawn-at-startup "waybar"/# spawn-at-startup "waybar"/' "$NIRI_CONFIG"
        as_user sed -i 's/spawn-at-startup "ags run"/# spawn-at-startup "ags run"/' "$NIRI_CONFIG"
        # 确保启动 quickshell
        if ! grep -q "quickshell" "$NIRI_CONFIG"; then
            as_user sed -i '/spawn-at-startup "waybar"/a \    spawn-at-startup "quickshell"' "$NIRI_CONFIG"
        fi
        success "Niri config updated for QuickShell."
    fi
fi

# --- [5. Final Touches] ---
section "Step 4/5" "Hardware & Cleanup"
if pacman -Q swayosd &>/dev/null; then
    systemctl enable --now swayosd-libinput-backend.service >/dev/null 2>&1
fi

section "Step 5/5" "Auto-Login"
log "Configuring TTY Auto-login..."
mkdir -p "/etc/systemd/system/getty@tty1.service.d"
echo -e "[Service]\nExecStart=\nExecStart=-/sbin/agetty --noreset --noclear --autologin $TARGET_USER - \${TERM}" >"/etc/systemd/system/getty@tty1.service.d/autologin.conf"

success "Nagisa's Niri + QuickShell Setup Completed!"