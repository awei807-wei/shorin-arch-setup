#!/bin/bash

# ==============================================================================
# 04-niri-setup.sh - Niri Desktop (Visual Enhanced)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# --- Config ---
DEBUG=${DEBUG:-0}
CN_MIRROR=${CN_MIRROR:-0}

check_root

# --- Helper: Local Fallback ---
install_local_fallback() {
    local pkg_name="$1"
    local search_dir="$PARENT_DIR/compiled/$pkg_name"
    
    if [ ! -d "$search_dir" ]; then return 1; fi
    
    local pkg_file=$(find "$search_dir" -maxdepth 1 -name "*.pkg.tar.zst" | head -n 1)
    
    if [ -f "$pkg_file" ]; then
        warn "Network install failed. Using local fallback..."
        exe runuser -u "$TARGET_USER" -- yay -U --noconfirm "$pkg_file"
        return $?
    else
        return 1
    fi
}

log "Starting Niri Setup..."

# ------------------------------------------------------------------------------
# 0. User
# ------------------------------------------------------------------------------
log "Identifying user..."
DETECTED_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)

if [ -n "$DETECTED_USER" ]; then
    TARGET_USER="$DETECTED_USER"
else
    read -p "   Please enter target username: " TARGET_USER
fi
HOME_DIR="/home/$TARGET_USER"
info_kv "Target" "$TARGET_USER"

# ------------------------------------------------------------------------------
# 1. Niri Core
# ------------------------------------------------------------------------------
log "Installing Core Packages..."
PKGS="niri xwayland-satellite xdg-desktop-portal-gnome fuzzel kitty firefox libnotify mako polkit-gnome pciutils"
exe pacman -S --noconfirm --needed $PKGS

# Firefox Policy
log "Configuring Firefox Policies..."
FIREFOX_POLICY_DIR="/etc/firefox/policies"
exe mkdir -p "$FIREFOX_POLICY_DIR"

cat <<EOT > "$FIREFOX_POLICY_DIR/policies.json"
{
  "policies": {
    "Extensions": {
      "Install": [
        "https://addons.mozilla.org/firefox/downloads/latest/pywalfox/latest.xpi"
      ]
    }
  }
}
EOT
success "Policy written."

# ------------------------------------------------------------------------------
# 2. Nautilus & GPU
# ------------------------------------------------------------------------------
log "Configuring Nautilus..."
exe pacman -S --noconfirm --needed ffmpegthumbnailer gvfs-smb nautilus-open-any-terminal file-roller gnome-keyring gst-plugins-base gst-plugins-good gst-libav nautilus

if [ ! -f /usr/bin/gnome-terminal ] || [ -L /usr/bin/gnome-terminal ]; then
    exe ln -sf /usr/bin/kitty /usr/bin/gnome-terminal
fi

# Smart GPU Env
DESKTOP_FILE="/usr/share/applications/org.gnome.Nautilus.desktop"
if [ -f "$DESKTOP_FILE" ]; then
    log "Checking GPU..."
    GPU_COUNT=$(lspci | grep -E -i "vga|3d" | wc -l)
    HAS_NVIDIA=$(lspci | grep -E -i "nvidia" | wc -l)
    
    ENV_VARS="env GTK_IM_MODULE=fcitx"
    if [ "$GPU_COUNT" -gt 1 ] && [ "$HAS_NVIDIA" -gt 0 ]; then
        info_kv "GPU" "Hybrid Nvidia" "-> Adding GSK_RENDERER=gl"
        ENV_VARS="env GSK_RENDERER=gl GTK_IM_MODULE=fcitx"
    fi
    
    exe sed -i "s/^Exec=/Exec=$ENV_VARS /" "$DESKTOP_FILE"
fi

# ------------------------------------------------------------------------------
# 3. Network
# ------------------------------------------------------------------------------
log "Configuring Network Sources..."
exe pacman -S --noconfirm --needed flatpak gnome-software
exe flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

IS_CN_ENV=false
if [ "$CN_MIRROR" == "1" ] || [ "$DEBUG" == "1" ]; then
    IS_CN_ENV=true
    if [ "$DEBUG" == "1" ]; then warn "DEBUG MODE ACTIVE"; fi
    
    log "Enabling China Optimizations..."
    exe flatpak remote-modify flathub --url=https://mirrors.ustc.edu.cn/flathub
    
    export GOPROXY=https://goproxy.cn,direct
    if ! grep -q "GOPROXY" /etc/environment; then
        echo "GOPROXY=https://goproxy.cn,direct" >> /etc/environment
    fi
    
    log "Enabling Git Mirror..."
    exe runuser -u "$TARGET_USER" -- git config --global url."https://gitclone.com/github.com/".insteadOf "https://github.com/"
else
    log "Using Global Sources."
fi

# NOPASSWD
SUDO_TEMP_FILE="/etc/sudoers.d/99_shorin_installer_temp"
echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDO_TEMP_FILE"
chmod 440 "$SUDO_TEMP_FILE"

# ------------------------------------------------------------------------------
# 4. Dependencies
# ------------------------------------------------------------------------------
log "Installing Dependencies (AUR)..."

LIST_FILE="$PARENT_DIR/niri-applist.txt"
FAILED_PACKAGES=()

if [ -f "$LIST_FILE" ]; then
    mapfile -t PACKAGE_ARRAY < <(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | tr -d '\r')
    
    if [ ${#PACKAGE_ARRAY[@]} -gt 0 ]; then
        BATCH_LIST=""
        GIT_LIST=()

        for pkg in "${PACKAGE_ARRAY[@]}"; do
            [ "$pkg" == "imagemagic" ] && pkg="imagemagick"
            if [[ "$pkg" == *"-git" ]]; then
                GIT_LIST+=("$pkg")
            else
                BATCH_LIST+="$pkg "
            fi
        done
        
        # Phase 1: Batch
        if [ -n "$BATCH_LIST" ]; then
            log "Phase 1: Batch Install..."
            # 使用 exe 包装命令，实现可视化
            if ! exe runuser -u "$TARGET_USER" -- env GOPROXY=$GOPROXY yay -S --noconfirm --needed --answerdiff=None --answerclean=None $BATCH_LIST; then
                warn "Batch failed. Retrying with Mirror Toggle..."
                
                # Toggle Mirror Logic
                if runuser -u "$TARGET_USER" -- git config --global --get url."https://gitclone.com/github.com/".insteadOf > /dev/null; then
                    runuser -u "$TARGET_USER" -- git config --global --unset url."https://gitclone.com/github.com/".insteadOf
                else
                    runuser -u "$TARGET_USER" -- git config --global url."https://gitclone.com/github.com/".insteadOf "https://github.com/"
                fi
                
                if ! exe runuser -u "$TARGET_USER" -- env GOPROXY=$GOPROXY yay -S --noconfirm --needed --answerdiff=None --answerclean=None $BATCH_LIST; then
                    error "Batch install failed."
                else
                    success "Batch installed (Retry)."
                fi
            fi
        fi

        # Phase 2: Git Install
        if [ ${#GIT_LIST[@]} -gt 0 ]; then
            log "Phase 2: Git Install..."
            for git_pkg in "${GIT_LIST[@]}"; do
                if ! exe runuser -u "$TARGET_USER" -- env GOPROXY=$GOPROXY yay -S --noconfirm --needed --answerdiff=None --answerclean=None "$git_pkg"; then
                    warn "Install failed. Retrying..."
                    
                    # Toggle Mirror
                    if runuser -u "$TARGET_USER" -- git config --global --get url."https://gitclone.com/github.com/".insteadOf > /dev/null; then
                        runuser -u "$TARGET_USER" -- git config --global --unset url."https://gitclone.com/github.com/".insteadOf
                    else
                        runuser -u "$TARGET_USER" -- git config --global url."https://gitclone.com/github.com/".insteadOf "https://github.com/"
                    fi
                    
                    if ! exe runuser -u "$TARGET_USER" -- env GOPROXY=$GOPROXY yay -S --noconfirm --needed --answerdiff=None --answerclean=None "$git_pkg"; then
                        
                        # Local Fallback
                        warn "Network failed. Checking local cache..."
                        if install_local_fallback "$git_pkg"; then
                            :
                        else
                            error "Failed: $git_pkg"
                            FAILED_PACKAGES+=("$git_pkg")
                        fi
                    else
                        success "Installed $git_pkg"
                    fi
                fi
            done
        fi
        
        # Recovery
        log "Running Recovery Checks..."
        if ! command -v waybar &> /dev/null; then
            warn "Waybar missing. Installing stock..."
            exe pacman -S --noconfirm --needed waybar
        fi

        if ! command -v awww &> /dev/null; then
            warn "Awww not found. Will try Swaybg later."
        fi

        # Report
        if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
            DOCS_DIR="$HOME_DIR/Documents"
            REPORT_FILE="$DOCS_DIR/安装失败的软件.txt"
            if [ ! -d "$DOCS_DIR" ]; then runuser -u "$TARGET_USER" -- mkdir -p "$DOCS_DIR"; fi
            printf "%s\n" "${FAILED_PACKAGES[@]}" > "$REPORT_FILE"
            chown "$TARGET_USER:$TARGET_USER" "$REPORT_FILE"
            error "Some packages failed. See: $REPORT_FILE"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 5. Dotfiles
# ------------------------------------------------------------------------------
log "Deploying Dotfiles..."

REPO_URL="https://github.com/SHORiN-KiWATA/ShorinArchExperience-ArchlinuxGuide.git"
TEMP_DIR="/tmp/shorin-repo"
rm -rf "$TEMP_DIR"

if ! exe runuser -u "$TARGET_USER" -- git clone "$REPO_URL" "$TEMP_DIR"; then
    warn "Clone failed. Retrying with Mirror Toggle..."
    if runuser -u "$TARGET_USER" -- git config --global --get url."https://gitclone.com/github.com/".insteadOf > /dev/null; then
        runuser -u "$TARGET_USER" -- git config --global --unset url."https://gitclone.com/github.com/".insteadOf
    else
        runuser -u "$TARGET_USER" -- git config --global url."https://gitclone.com/github.com/".insteadOf "https://github.com/"
    fi
    
    if ! exe runuser -u "$TARGET_USER" -- git clone "$REPO_URL" "$TEMP_DIR"; then
        error "Clone failed."
    fi
fi

if [ -d "$TEMP_DIR/dotfiles" ]; then
    BACKUP_NAME="config_backup_$(date +%s).tar.gz"
    log "Backing up ~/.config..."
    exe runuser -u "$TARGET_USER" -- tar -czf "$HOME_DIR/$BACKUP_NAME" -C "$HOME_DIR" .config
    
    log "Applying dotfiles..."
    exe runuser -u "$TARGET_USER" -- cp -rf "$TEMP_DIR/dotfiles/." "$HOME_DIR/"
    
    if [ "$TARGET_USER" != "shorin" ]; then
        OUTPUT_KDL="$HOME_DIR/.config/niri/output.kdl"
        if [ -f "$OUTPUT_KDL" ]; then
            log "Clearing output.kdl..."
            exe runuser -u "$TARGET_USER" -- truncate -s 0 "$OUTPUT_KDL"
        fi
    fi

    # Ultimate Fallback
    if ! runuser -u "$TARGET_USER" -- command -v awww &> /dev/null; then
        warn "Awww missing. Switching to Swaybg..."
        exe pacman -S --noconfirm --needed swaybg
        SCRIPT_PATH="$HOME_DIR/.config/scripts/niri_set_overview_blur_dark_bg.sh"
        if [ -f "$SCRIPT_PATH" ]; then
            sed -i 's/^WALLPAPER_BACKEND="awww"/WALLPAPER_BACKEND="swaybg"/' "$SCRIPT_PATH"
            success "Switched to Swaybg."
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 6. Wallpapers
# ------------------------------------------------------------------------------
log "Setting up Wallpapers..."
WALL_DEST="$HOME_DIR/Pictures/Wallpapers"
if [ -d "$TEMP_DIR/wallpapers" ]; then
    exe runuser -u "$TARGET_USER" -- mkdir -p "$WALL_DEST"
    exe runuser -u "$TARGET_USER" -- cp -rf "$TEMP_DIR/wallpapers/." "$WALL_DEST/"
fi
rm -rf "$TEMP_DIR"

# ------------------------------------------------------------------------------
# 7. Hardware Tools
# ------------------------------------------------------------------------------
log "Configuring Hardware Tools..."
exe runuser -u "$TARGET_USER" -- yay -S --noconfirm --needed ddcutil-service
gpasswd -a "$TARGET_USER" i2c

exe pacman -S --noconfirm --needed swayosd
systemctl enable --now swayosd-libinput-backend.service > /dev/null 2>&1

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
log "Cleaning up..."
rm -f "$SUDO_TEMP_FILE"
runuser -u "$TARGET_USER" -- git config --global --unset url."https://gitclone.com/github.com/".insteadOf
sed -i '/GOPROXY=https:\/\/goproxy.cn,direct/d' /etc/environment

# ------------------------------------------------------------------------------
# 10. Auto-Login
# ------------------------------------------------------------------------------
if [ "$SKIP_AUTOLOGIN" = true ]; then
    log "Auto-login skipped (DM active)."
else
    log "Configuring Auto-login..."
    GETTY_DIR="/etc/systemd/system/getty@tty1.service.d"
    mkdir -p "$GETTY_DIR"
    cat <<EOT > "$GETTY_DIR/autologin.conf"
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noreset --noclear --autologin $TARGET_USER - \${TERM}
EOT

    USER_SYSTEMD_DIR="$HOME_DIR/.config/systemd/user"
    mkdir -p "$USER_SYSTEMD_DIR"
    cat <<EOT > "$USER_SYSTEMD_DIR/niri-autostart.service"
[Unit]
Description=Niri Session Autostart
After=graphical-session-pre.target

[Service]
ExecStart=/usr/bin/niri-session
Restart=on-failure

[Install]
WantedBy=default.target
EOT

    WANTS_DIR="$USER_SYSTEMD_DIR/default.target.wants"
    mkdir -p "$WANTS_DIR"
    ln -sf "../niri-autostart.service" "$WANTS_DIR/niri-autostart.service"
    
    chown -R "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.config/systemd"
    success "Auto-login configured."
fi

log "Phase 4 Completed."