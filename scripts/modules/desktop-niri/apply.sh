#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# 04-niri-setup.sh - Niri Desktop (Restored FZF & Robust AUR)
# ==============================================================================

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"

DEBUG=${DEBUG:-0}
CN_MIRROR=${CN_MIRROR:-0}
UNDO_SCRIPT="$SCRIPT_DIR/checks/niri-rollback.sh"

check_root

section "Phase 4" "Niri Desktop Environment"

# ==============================================================================
# STEP 0: Safety Checkpoint
# ==============================================================================

# ==============================================================================
# STEP 1: Identify User & DM Check
# ==============================================================================
log "Identifying user..."
if [ -z "${TARGET_USER:-}" ]; then
  TARGET_USER=$(awk -F: '$3 == 1000 {print $1; exit}' /etc/passwd)
fi
[ -n "$TARGET_USER" ] || read -r -p "Target user: " TARGET_USER
HOME_DIR=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[ -n "$HOME_DIR" ] || die "Cannot resolve home for $TARGET_USER"
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
  if [ "${SHORIN_MODE:-install}" = install ]; then
    read -r -t 20 -p "Enable TTY auto-login? [Y/n]: " choice || choice=Y
    [[ "${choice:-Y}" =~ ^[Yy]$ ]] && SKIP_AUTOLOGIN=false || SKIP_AUTOLOGIN=true
  elif grep -q -- "--autologin $TARGET_USER" \
    /etc/systemd/system/getty@tty1.service.d/autologin.conf 2>/dev/null; then
    SKIP_AUTOLOGIN=false
  else
    SKIP_AUTOLOGIN=true
  fi
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
bash "$SCRIPT_DIR/modules/desktop-niri/packages-apply.sh"

# ==============================================================================
# STEP 6: Dotfiles
# ==============================================================================
section "Step 5/9" "Dotfiles, Wallpapers, and Templates"
bash "$SCRIPT_DIR/modules/desktop-niri/dotfiles-apply.sh"

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
  success "Enabled."
fi

log "Module 04 completed."
