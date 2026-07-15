#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# 04-niri-setup.sh - Niri Desktop (Restored FZF & Robust AUR)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

DEBUG=${DEBUG:-0}
CN_MIRROR=${CN_MIRROR:-0}
UNDO_SCRIPT="$SCRIPT_DIR/niri-undochange.sh"

check_root

# --- [HELPER FUNCTIONS] ---


# 2. Critical Failure Handler (The "Big Red Box")
# 2. Critical Failure Handler (The "Big Red Box")
critical_failure_handler() {
  local failed_reason="$1"
  error "$failed_reason"
  return 1
}

# 3. Robust Package Installation with Retry Loop
ensure_package_installed() {
  local pkg="$1"
  local context="$2" # e.g., "Repo" or "AUR"
  local max_attempts=3
  local attempt=1
  local install_success=false

  # 1. Check if already installed
  if pacman -Q "$pkg" &>/dev/null; then
    return 0
  fi

  # 2. Retry Loop
  while [ $attempt -le $max_attempts ]; do
    if [ $attempt -gt 1 ]; then
      warn "Retrying '$pkg' ($context)... (Attempt $attempt/$max_attempts)"
      sleep 3 # Cooldown
    else
      log "Installing '$pkg' ($context)..."
    fi

    # Try installation
    if as_user yay -S --noconfirm --needed --answerdiff=None --answerclean=None "$pkg"; then
      install_success=true
      break
    else
      warn "Attempt $attempt/$max_attempts failed for '$pkg'."
    fi

    ((++attempt))
  done

  # 3. Final Verification
  if [ "$install_success" = true ] && pacman -Q "$pkg" &>/dev/null; then
    success "Installed '$pkg'."
  else
    critical_failure_handler "Failed to install '$pkg' after $max_attempts attempts."
  fi
}

section "Phase 4" "Niri Desktop Environment"

# ==============================================================================
# STEP 0: Safety Checkpoint
# ==============================================================================

# ==============================================================================
# STEP 1: Identify User & DM Check
# ==============================================================================
log "Identifying user..."
DETECTED_USER=$(awk -F: '$3 == 1000 {print $1; exit}' /etc/passwd)
if [ -n "$DETECTED_USER" ]; then
  TARGET_USER=$DETECTED_USER
else
  read -r -p "Target user: " TARGET_USER
fi
HOME_DIR="/home/$TARGET_USER"
info_kv "Target" "$TARGET_USER"

# DM Check
KNOWN_DMS=("gdm" "sddm" "lightdm" "lxdm" "slim" "xorg-xdm" "ly" "greetd")
SKIP_AUTOLOGIN=false
DM_FOUND=""
for dm in "${KNOWN_DMS[@]}"; do
  if pacman -Q "$dm" &>/dev/null; then
    DM_FOUND="$dm"
    break
  fi
done

if [ -n "$DM_FOUND" ]; then
  info_kv "Conflict" "${H_RED}$DM_FOUND${NC}"
  SKIP_AUTOLOGIN=true
else
  read -t 20 -p "$(echo -e "   ${H_CYAN}Enable TTY auto-login? [Y/n] (Default Y): ${NC}")" choice || true
  [[ "${choice:-Y}" =~ ^[Yy]$ ]] && SKIP_AUTOLOGIN=false || SKIP_AUTOLOGIN=true
fi

# ==============================================================================
# STEP 2: Core Components
# ==============================================================================
section "Step 1/9" "Core Components"
ensure_packages niri xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
  fuzzel kitty firefox libnotify polkit-gnome

log "Configuring Firefox Policies..."
POL_DIR="/etc/firefox/policies"
exe mkdir -p "$POL_DIR"
POLICY_TMP=$(mktemp)
printf '%s\n' '{ "policies": { "Extensions": { "Install": ["https://addons.mozilla.org/firefox/downloads/latest/pywalfox/latest.xpi"] } } }' > "$POLICY_TMP"
install_if_changed "$POLICY_TMP" "$POL_DIR/policies.json" 644
rm -f "$POLICY_TMP"
exe chmod 755 "$POL_DIR"

# ==============================================================================
# STEP 3: File Manager
# ==============================================================================
section "Step 2/9" "File Manager"
ensure_packages ffmpegthumbnailer gvfs-smb nautilus-open-any-terminal \
  file-roller gnome-keyring gst-plugins-base gst-plugins-good gst-libav nautilus

if [ ! -f /usr/bin/gnome-terminal ] || [ -L /usr/bin/gnome-terminal ]; then
  exe ln -sf /usr/bin/kitty /usr/bin/gnome-terminal
fi

# Nautilus Nvidia/Input Fix
DESKTOP_FILE="/usr/share/applications/org.gnome.Nautilus.desktop"
if [ -f "$DESKTOP_FILE" ]; then
  GPU_COUNT=$(lspci | awk 'BEGIN { IGNORECASE=1 } /vga|3d/ { count++ } END { print count + 0 }')
  HAS_NVIDIA=$(lspci | awk 'BEGIN { IGNORECASE=1 } /nvidia/ { count++ } END { print count + 0 }')
  ENV_VARS="env GTK_IM_MODULE=fcitx"
  [ "$GPU_COUNT" -gt 1 ] && [ "$HAS_NVIDIA" -gt 0 ] && ENV_VARS="env GSK_RENDERER=gl GTK_IM_MODULE=fcitx"

  if ! grep -q "^Exec=$ENV_VARS" "$DESKTOP_FILE"; then
    exe sed -i "s|^Exec=|Exec=$ENV_VARS |" "$DESKTOP_FILE"
  fi
fi

section "Step 3/9" "Temp sudo file"

SUDO_TEMP_FILE="/etc/sudoers.d/99_shorin_installer_temp"
SUDO_TEMP_SOURCE=$(mktemp)
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$TARGET_USER" > "$SUDO_TEMP_SOURCE"
install_sudoers_file "$SUDO_TEMP_SOURCE" "$SUDO_TEMP_FILE"
rm -f "$SUDO_TEMP_SOURCE"
cleanup_temp_sudoers() {
  [ ! -f "$SUDO_TEMP_FILE" ] || rm -f "$SUDO_TEMP_FILE"
}
trap cleanup_temp_sudoers EXIT
log "Temp sudo file created..."
# ==============================================================================
# STEP 5: Dependencies (RESTORED FZF)
# ==============================================================================
section "Step 4/9" "Dependencies"
LIST_FILE="$PARENT_DIR/niri-applist.txt"

# Ensure tools
command -v fzf &>/dev/null || ensure_package fzf

if [ -f "$LIST_FILE" ]; then
  mapfile -t DEFAULT_LIST < <(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | sed 's/[[:space:]]*#.*//' | xargs -n1)

  if [ ${#DEFAULT_LIST[@]} -eq 0 ]; then
    warn "App list is empty. Skipping."
    PACKAGE_ARRAY=()
  else
    echo -e "\n   ${H_YELLOW}>>> Default installation in 60s. Press ANY KEY to customize...${NC}"

    if read -t 60 -n 1 -s -r; then
      # --- [RESTORED] Original FZF Selection Logic ---
      clear
      log "Loading package list..."

      SELECTED_LINES=$(grep -vE "^\s*#|^\s*$" "$LIST_FILE" |
        sed -E 's/[[:space:]]+#/\t#/' |
        fzf --multi \
          --layout=reverse \
          --border \
          --margin=1,2 \
          --prompt="Search Pkg > " \
          --pointer=">>" \
          --marker="* " \
          --delimiter=$'\t' \
          --with-nth=1 \
          --bind 'load:select-all' \
          --bind 'ctrl-a:select-all,ctrl-d:deselect-all' \
          --info=inline \
          --header="[TAB] TOGGLE | [ENTER] INSTALL | [CTRL-D] DE-ALL | [CTRL-A] SE-ALL" \
          --preview "echo {} | cut -f2 -d$'\t' | sed 's/^# //'" \
          --preview-window=right:50%:wrap:border-left \
          --color=dark \
          --color=fg+:white,bg+:black \
          --color=hl:blue,hl+:blue:bold \
          --color=header:yellow:bold \
          --color=info:magenta \
          --color=prompt:cyan,pointer:cyan:bold,marker:green:bold \
          --color=spinner:yellow)

      clear

      if [ -z "$SELECTED_LINES" ]; then
        warn "User cancelled selection. Installing NOTHING."
        PACKAGE_ARRAY=()
      else
        PACKAGE_ARRAY=()
        while IFS= read -r line; do
          raw_pkg=$(echo "$line" | cut -f1 -d$'\t' | xargs)
          [ -n "$raw_pkg" ] && PACKAGE_ARRAY+=("$raw_pkg")
        done <<<"$SELECTED_LINES"
      fi
      # -----------------------------------------------
    else
      log "Auto-confirming ALL packages."
      PACKAGE_ARRAY=("${DEFAULT_LIST[@]}")
    fi
  fi

  # --- Installation Loop ---
  if [ ${#PACKAGE_ARRAY[@]} -gt 0 ]; then
    info_kv "Target" "${#PACKAGE_ARRAY[@]} packages scheduled."

    mapfile -t PACKAGE_ARRAY < <(printf '%s\n' "${PACKAGE_ARRAY[@]}" | sort -u)
    for entry in "${PACKAGE_ARRAY[@]}"; do
      case "$entry" in
        AUR:*) ensure_package_installed "${entry#AUR:}" AUR ;;
        flatpak:*) ensure_flatpak "${entry#flatpak:}" ;;
        GitHub:*) critical_failure_handler "GitHub entry is unsupported in niri-applist: $entry" ;;
        imagemagic) ensure_package_installed imagemagick Repo ;;
        *) ensure_package_installed "$entry" Repo ;;
      esac
    done

    # Waybar fallback
    if ! command -v waybar &>/dev/null; then
      warn "Waybar missing. Installing stock..."
      ensure_package waybar
    fi
  else
    warn "No packages selected."
  fi
else
  warn "niri-applist.txt not found."
fi

# ==============================================================================
# STEP 6: Dotfiles
# ==============================================================================
section "Step 5/9" "Deploying Dotfiles"

REPO_GITHUB="https://github.com/awei807-wei/ShorinArchExperience-ArchlinuxGuide.git"
REPO_GITEE="https://gitee.com/shorinkiwata/ShorinArchExperience-ArchlinuxGuide.git"
TEMP_DIR="/tmp/shorin-repo"

log "Converging configuration source checkout..."
if ! ensure_git_checkout "$TARGET_USER" "$REPO_GITHUB" main "$TEMP_DIR"; then
  if [ -e "$TEMP_DIR" ] || ! ensure_git_checkout "$TARGET_USER" "$REPO_GITEE" main "$TEMP_DIR"; then
    critical_failure_handler "Failed to update the verified dotfiles checkout."
  fi
fi

if [ -d "$TEMP_DIR/dotfiles" ]; then
  log "Installing missing user-editable dotfiles without overwriting existing files..."
  if [ "$TARGET_USER" != "shorin" ]; then
    SOURCE_BOOKMARKS="$TEMP_DIR/dotfiles/.config/gtk-3.0/bookmarks"
    if [ -f "$SOURCE_BOOKMARKS" ]; then
      BOOKMARKS_TMP=$(mktemp)
      sed "s/shorin/$TARGET_USER/g" "$SOURCE_BOOKMARKS" > "$BOOKMARKS_TMP"
      install_user_file_once "$BOOKMARKS_TMP" \
        "$HOME_DIR/.config/gtk-3.0/bookmarks" 644 "$TARGET_USER"
      rm -f "$BOOKMARKS_TMP"
    fi
  fi
  SOURCE_NIRI_CONFIG="$TEMP_DIR/dotfiles/.config/niri/config.kdl"
  if [ -f "$SOURCE_NIRI_CONFIG" ]; then
    NIRI_TMP=$(mktemp)
    sed 's/\& \/usr\/lib\/xdg-desktop-portal-gnome//' \
      "$SOURCE_NIRI_CONFIG" > "$NIRI_TMP"
    install_user_file_once "$NIRI_TMP" "$HOME_DIR/.config/niri/config.kdl" \
      644 "$TARGET_USER"
    rm -f "$NIRI_TMP"
  fi
  deploy_user_tree_once "$TEMP_DIR/dotfiles" "$HOME_DIR" "$TARGET_USER"

  # Fix Symlinks & Permissions
  GTK4="$HOME_DIR/.config/gtk-4.0"
  THEME="$HOME_DIR/.themes/adw-gtk3-dark/gtk-4.0"
  as_user rm -f "$GTK4/gtk.css" "$GTK4/gtk-dark.css"
  as_user ln -sf "$THEME/gtk-dark.css" "$GTK4/gtk-dark.css"
  as_user ln -sf "$THEME/gtk.css" "$GTK4/gtk.css"

  if command -v flatpak &>/dev/null; then
    as_user flatpak override --user --filesystem="$HOME_DIR/.themes"
    as_user flatpak override --user --filesystem=xdg-config/gtk-4.0
    as_user flatpak override --user --filesystem=xdg-config/gtk-3.0
    as_user flatpak override --user --env=GTK_THEME=adw-gtk3-dark
    as_user flatpak override --user --filesystem=xdg-config/fontconfig
  fi
  # --- [Portal Fix] Ensure GTK portal priority ---
  section "Portal Fix" "Configuring Priority"
  PORTAL_CONF_DIR="$HOME_DIR/.config/xdg-desktop-portal"
  as_user mkdir -p "$PORTAL_CONF_DIR"
  PORTAL_TMP=$(mktemp)
  printf '[preferred]\ndefault=gtk\n' > "$PORTAL_TMP"
  install_if_changed "$PORTAL_TMP" "$PORTAL_CONF_DIR/portals.conf" 644
  rm -f "$PORTAL_TMP"
  chown "$TARGET_USER:$TARGET_USER" "$PORTAL_CONF_DIR/portals.conf"

  success "Dotfiles Applied."
else
  critical_failure_handler "Dotfiles missing in the verified checkout."
fi


# ==============================================================================
# STEP 7: Wallpapers & Templates
# ==============================================================================
section "Step 6/9" "Wallpapers"
if [ -d "$TEMP_DIR/wallpapers" ]; then
  deploy_user_tree_once "$TEMP_DIR/wallpapers" \
    "$HOME_DIR/Pictures/Wallpapers" "$TARGET_USER"
  as_user touch "$HOME_DIR/Templates/new"
  TEMPLATE_TMP=$(mktemp)
  printf '#!/usr/bin/env bash\n' > "$TEMPLATE_TMP"
  install_user_file_once "$TEMPLATE_TMP" "$HOME_DIR/Templates/new.sh" 755 "$TARGET_USER"
  rm -f "$TEMPLATE_TMP"
  success "Installed."
fi

# ==============================================================================
# STEP 8: Hardware Tools
# ==============================================================================
section "Step 7/9" "Hardware"
if pacman -Q ddcutil &>/dev/null; then
  gpasswd -a "$TARGET_USER" i2c
  lsmod | grep -q i2c_dev || ensure_line /etc/modules-load.d/i2c-dev.conf i2c-dev
fi
if pacman -Q swayosd &>/dev/null; then
  ensure_service_started swayosd-libinput-backend.service
fi
success "Tools configured."

# ==============================================================================
# STEP 9: Cleanup & Auto-Login
# ==============================================================================
section "Final" "Cleanup & Boot"
rm -f "$SUDO_TEMP_FILE"

SVC_DIR="$HOME_DIR/.config/systemd/user"
SVC_FILE="$SVC_DIR/niri-autostart.service"
LINK="$SVC_DIR/default.target.wants/niri-autostart.service"

if [ "$SKIP_AUTOLOGIN" = true ]; then
  log "Auto-login skipped."
  as_user rm -f "$LINK" "$SVC_FILE"
  rm -f /tmp/shorin_niri_user_unit_required
else
  log "Configuring TTY Auto-login..."
  mkdir -p "/etc/systemd/system/getty@tty1.service.d"
  AUTOLOGIN_TMP=$(mktemp)
  printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --noreset --noclear --autologin %s - ${TERM}\n' \
    "$TARGET_USER" > "$AUTOLOGIN_TMP"
  install_if_changed "$AUTOLOGIN_TMP" \
    /etc/systemd/system/getty@tty1.service.d/autologin.conf 644
  rm -f "$AUTOLOGIN_TMP"

  SVC_TMP=$(mktemp)
  cat <<EOT >"$SVC_TMP"
[Unit]
Description=Niri Session Autostart
After=graphical-session-pre.target
[Service]
ExecStart=/usr/bin/niri-session
Restart=on-failure
[Install]
WantedBy=default.target
EOT
  install_if_changed "$SVC_TMP" "$SVC_FILE" 644
  rm -f "$SVC_TMP"
  chown "$TARGET_USER:$TARGET_USER" "$SVC_FILE"
  ensure_user_unit_enabled "$TARGET_USER" niri-autostart.service default.target
  printf '%s\n' "$TARGET_USER" > /tmp/shorin_niri_user_unit_required
  success "Enabled."
fi

log "Module 04 completed."
