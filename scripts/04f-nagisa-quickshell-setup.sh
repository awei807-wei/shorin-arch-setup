#!/bin/bash
# ==============================================================================
# 04f-nagisa-quickshell-setup.sh - Nagisa's Industrial Niri + QuickShell Setup
# (Final Robustness, Unique Sudoers, Verified Backup & AWK Injection v8.0)
# ==============================================================================
# Capture original arguments at the very beginning
ORIGINAL_ARGS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

UNDO_SCRIPT="$SCRIPT_DIR/niri-undochange.sh"
# [FIX] Use unique filename for sudoers to avoid overwriting existing files
SUDO_ID="shorin_installer_$(date +%s%N)"
SUDO_TEMP_FILE="/etc/sudoers.d/99_${SUDO_ID}"
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
            1) cleanup_handler; if [ -f "$UNDO_SCRIPT" ]; then bash "$UNDO_SCRIPT"; exit 1; else error "Undo script missing!"; exit 1; fi ;;
            2) cleanup_handler; warn "Restarting script..."; exec "$0" "${ORIGINAL_ARGS[@]}" ;;
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

# --- [STEP 1: Identify & Validate User] ---
log "Identifying user..."
DETECTED_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)
TARGET_USER="${DETECTED_USER:-shiyi}"
if ! id "$TARGET_USER" &>/dev/null; then
    critical_failure_handler "Target user '$TARGET_USER' does not exist on this system."
fi
HOME_DIR="/home/$TARGET_USER"
info_kv "Target" "$TARGET_USER"

# --- [PRE-FLIGHT: If user's login shell is fish, ensure required tools exist] ---
LOGIN_SHELL="$(getent passwd "$TARGET_USER" | cut -d: -f7)"
if [[ "$LOGIN_SHELL" == */fish ]]; then
    log "Detected fish as login shell. Ensuring fish toolchain is installed..."
    exe pacman -S --noconfirm --needed fish starship zoxide eza thefuck
fi

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
# [FIX] Using unique filename for sudoers
echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" >"$SUDO_TEMP_FILE"
chmod 440 "$SUDO_TEMP_FILE"
log "Temporary sudoers privilege granted (${SUDO_ID})."

# --- [PRE-FLIGHT: Ensure yay exists for AUR installs] ---
if ! command -v yay &>/dev/null; then
    warn "yay not found. Installing via pacman..."
    exe pacman -S --noconfirm --needed yay
fi

# --- [STEP 3: Core Components & System Patches] ---
section "Step 1/9" "Core Components & System Patches"
PKGS="niri xdg-desktop-portal-gnome xdg-desktop-portal-gtk fuzzel kitty firefox libnotify mako polkit-gnome nautilus gvfs-smb"
exe pacman -S --noconfirm --needed $PKGS

log "Configuring Firefox Policies..."
POL_DIR="/etc/firefox/policies"
exe mkdir -p "$POL_DIR"
echo '{ "policies": { "Extensions": { "Install": ["https://addons.mozilla.org/firefox/downloads/latest/pywalfox/latest.xpi"] } } }' >"$POL_DIR/policies.json"
exe chmod 755 "$POL_DIR" && exe chmod 644 "$POL_DIR/policies.json"

exe pacman -S --noconfirm --needed ffmpegthumbnailer nautilus-open-any-terminal file-roller gnome-keyring gst-plugins-base gst-plugins-good gst-libav
if [ ! -f /usr/bin/gnome-terminal ] || [ -L /usr/bin/gnome-terminal ]; then
    exe ln -sf /usr/bin/kitty /usr/bin/gnome-terminal
fi

DESKTOP_FILE="/usr/share/applications/org.gnome.Nautilus.desktop"
if [ -f "$DESKTOP_FILE" ]; then
    if command -v lspci &>/dev/null; then
        GPU_COUNT=$(lspci | grep -E -i "vga|3d" | wc -l)
        HAS_NVIDIA=$(lspci | grep -E -i "nvidia" | wc -l)
        ENV_VARS="env GTK_IM_MODULE=fcitx"
        [ "$GPU_COUNT" -gt 1 ] && [ "$HAS_NVIDIA" -gt 0 ] && ENV_VARS="env GSK_RENDERER=gl GTK_IM_MODULE=fcitx"
        if ! grep -q "^Exec=$ENV_VARS" "$DESKTOP_FILE"; then
            exe sed -i "s|^Exec=|Exec=$ENV_VARS |" "$DESKTOP_FILE"
        fi
    else
        warn "lspci not found. Skipping Nautilus GPU/input patch."
    fi
fi

# --- [STEP 4: QuickShell Suite] ---
section "Step 2/9" "QuickShell Suite"
# matugen is now in official repo (extra). AUR name matugen-bin may not exist.
for pkg in quickshell qt6-wayland matugen swww swayidle swaylock-effects; do
    ensure_package_installed "$pkg" "QuickShell Suite"
done

# --- [STEP 5: Dependencies with FZF Selection] ---
section "Step 3/9" "Applist Selection"
LIST_FILE="$PARENT_DIR/niri-applist.txt"
# [FIX] Ensure fzf installation is explicitly verified to trigger ERR handler on failure
if ! command -v fzf &>/dev/null; then
    log "Installing fzf for interactive selection..."
    exe pacman -S --noconfirm fzf
fi

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
else
    warn "niri-applist.txt not found. Skipping optional dependency selection."
fi

# --- [STEP 6: Dotfiles & Verified Backup] ---
section "Step 4/9" "Dotfiles & Multi-Source"
REPO_GITHUB="https://github.com/awei807-wei/ShorinArchExperience-ArchlinuxGuide.git"
REPO_GITEE="https://gitee.com/shorinkiwata/ShorinArchExperience-ArchlinuxGuide.git"
rm -rf "$TEMP_DIR"

log "Cloning dotfiles from GitHub..."
if ! as_user git clone "$REPO_GITHUB" "$TEMP_DIR"; then
    warn "GitHub failed, cleaning up and trying Gitee..."
    # [FIX] Explicit cleanup before fallback clone
    rm -rf "$TEMP_DIR"
    as_user git clone "$REPO_GITEE" "$TEMP_DIR" || critical_failure_handler "Failed to clone dotfiles from any source."
fi

if [ -d "$TEMP_DIR/dotfiles" ]; then
    # [FIX] Verified backup with existence check
    if [ -d "$HOME_DIR/.config" ]; then
        log "Backing up current .config (Verified)..."
        BACKUP_NAME="$HOME_DIR/config_backup_$(date +%s).tar.gz"
        if ! as_user tar -czf "$BACKUP_NAME" -C "$HOME_DIR" .config; then
            critical_failure_handler "Backup failed! Aborting to prevent data loss."
        fi
        success "Backup created: $BACKUP_NAME"
    else
        warn ".config directory not found. Skipping backup for clean environment."
    fi

    RIME_DIR="$HOME_DIR/.local/share/fcitx5/rime"
    if [ ! -d "$RIME_DIR/.git" ]; then
        as_user mkdir -p "$(dirname "$RIME_DIR")"
        as_user git clone --depth=1 https://github.com/iDvel/rime-ice.git "$RIME_DIR"
    fi

    log "Applying configurations..."
    as_user cp -rf "$TEMP_DIR/dotfiles/." "$HOME_DIR/"

    # If dotfiles include fish config that depends on external tools, ensure they exist.
    # This prevents fish startup errors like "Unknown command: starship/zoxide/thefuck".
    if [ -f "$HOME_DIR/.config/fish/config.fish" ]; then
        log "Detected fish config. Ensuring required CLI tools are installed..."
        exe pacman -S --noconfirm --needed fish starship zoxide eza thefuck
    fi
    
    # Robust Niri QuickShell Injection (v8.0)
    NIRI_CONFIG="$HOME_DIR/.config/niri/config.kdl"
    if [ -f "$NIRI_CONFIG" ]; then
        as_user sed -i 's/spawn-at-startup "waybar"/# spawn-at-startup "waybar"/' "$NIRI_CONFIG"
        as_user sed -i 's/spawn-at-startup "ags run"/# spawn-at-startup "ags run"/' "$NIRI_CONFIG"
        
        if ! grep -q "quickshell" "$NIRI_CONFIG"; then
            log "Injecting QuickShell startup into niri config..."
            if grep -q "spawn-at-startup" "$NIRI_CONFIG"; then
                # Robust AWK injection (run redirection as target user; avoid && which can mask ERR trap)
                as_user bash -c 'set -e; f="$1"; tmp="${f}.tmp"; awk '"'"'/spawn-at-startup/ && !done { print; print "    spawn-at-startup \"quickshell\""; done=1; next } 1'"'"' "$f" >"$tmp"; mv "$tmp" "$f"' _ "$NIRI_CONFIG"
            else
                as_user bash -c "echo 'spawn-at-startup \"quickshell\"' >> '$NIRI_CONFIG'"
            fi
        fi
        success "Niri config updated for QuickShell."
    else
        warn "Niri config file not found at $NIRI_CONFIG. Skipping injection."
    fi
else
    # [FIX] Explicit warning for missing dotfiles directory
    warn "Dotfiles directory not found in cloned repository. Configuration not applied."
fi

# --- [STEP 7: Environment & Theming] ---
section "Step 5/9" "Environment Fixes"
as_user mkdir -p "$HOME_DIR/.config/xdg-desktop-portal"
as_user printf "[preferred]\ndefault=gtk\n" > "$HOME_DIR/.config/xdg-desktop-portal/portals.conf"

BOOKMARKS_FILE="$HOME_DIR/.config/gtk-3.0/bookmarks"
[ -f "$BOOKMARKS_FILE" ] && as_user sed -i "s/shorin/$TARGET_USER/g" "$BOOKMARKS_FILE"

# --- [STEP 7-B: DISPLAY Fix (fish + systemd user) for X11 apps under Wayland] ---
section "Step 5b/9" "DISPLAY Environment Fix"

# 1) fish: auto-set DISPLAY if missing and X11 socket exists; sync to systemd/dbus when possible
mkdir -p "$HOME_DIR/.config/fish/conf.d"
cat >"$HOME_DIR/.config/fish/conf.d/20-display.fish" <<'EOF'
# Auto-fix DISPLAY for X11 apps under Wayland (niri + Xwayland/xwayland-satellite)
# This runs for interactive fish sessions.
if not set -q DISPLAY
    set -l found_display ""

    # Prefer /tmp/.X11-unix (common for Xwayland); fallback to $XDG_RUNTIME_DIR if present.
    for i in (seq 0 9)
        if test -S "/tmp/.X11-unix/X$i"
            set found_display ":$i"
            break
        end
    end

    if test -z "$found_display"; and set -q XDG_RUNTIME_DIR
        for i in (seq 0 9)
            if test -S "$XDG_RUNTIME_DIR/X11-unix/X$i"
                set found_display ":$i"
                break
            end
        end
    end

    if test -n "$found_display"
        set -gx DISPLAY $found_display

        # Best-effort: propagate to desktop-activated apps (dbus/systemd user).
        if command -q dbus-update-activation-environment
            dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR >/dev/null 2>&1
        end
        if command -q systemctl
            systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR >/dev/null 2>&1
        end
    end
end
EOF
chown "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.config/fish/conf.d/20-display.fish"

# 2) systemd --user: set DISPLAY early in the session for launcher/DBus activated apps
mkdir -p "$HOME_DIR/.config/systemd/user"
cat >"$HOME_DIR/.config/systemd/user/display-env.service" <<'EOF'
[Unit]
Description=Set DISPLAY env for X11 apps under Wayland (niri)
After=default.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -lc '\
  if [ -n "${DISPLAY:-}" ]; then exit 0; fi; \
  for i in $(seq 0 9); do \
    if [ -S "/tmp/.X11-unix/X${i}" ]; then \
      systemctl --user set-environment DISPLAY=":${i}" || true; \
      dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR >/dev/null 2>&1 || true; \
      systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR >/dev/null 2>&1 || true; \
      exit 0; \
    fi; \
  done; \
  exit 0'

[Install]
WantedBy=default.target
EOF
chown "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.config/systemd/user/display-env.service"

mkdir -p "$HOME_DIR/.config/systemd/user/default.target.wants"
ln -sf "../display-env.service" "$HOME_DIR/.config/systemd/user/default.target.wants/display-env.service"
chown -h "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.config/systemd/user/default.target.wants/display-env.service"

# --- [STEP 8: Wallpapers & Permissions] ---
section "Step 6/9" "Wallpapers & Permissions"
if [ -d "$TEMP_DIR/wallpapers" ]; then
    as_user mkdir -p "$HOME_DIR/Pictures/Wallpapers"
    as_user cp -rf "$TEMP_DIR/wallpapers/." "$HOME_DIR/Pictures/Wallpapers/"
    success "Wallpapers deployed."
else
    # [FIX] Explicit warning for missing wallpapers
    warn "Wallpapers directory not found in repository. Skipping."
fi

pacman -Q swayosd &>/dev/null && systemctl enable --now swayosd-libinput-backend.service >/dev/null 2>&1
if [ -d "$HOME_DIR/.config" ]; then
    chown -R "$TARGET_USER" "$HOME_DIR/.config"
else
    warn "$HOME_DIR/.config not found. Skipping permission fix."
fi

# --- [STEP 9: Auto-Login] ---
section "Step 7/9" "Finalizing"
if [ "$SKIP_AUTOLOGIN" = false ]; then
    mkdir -p "/etc/systemd/system/getty@tty1.service.d"
    echo -e "[Service]\nExecStart=\nExecStart=-/sbin/agetty --noreset --noclear --autologin $TARGET_USER - \${TERM}" >"/etc/systemd/system/getty@tty1.service.d/autologin.conf"
fi

# [FIX] Reflect actual status in final message
if [ ! -d "$TEMP_DIR/dotfiles" ]; then
    warn "Nagisa's Niri + QuickShell Setup completed with WARNINGS (Dotfiles missing)."
else
    success "Nagisa's Niri + QuickShell Industrial Setup Completed!"
fi
