#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# 04-niri-setup.sh - Niri Desktop (Restored FZF & Robust AUR)
# ==============================================================================

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/modules/desktop-niri/targets.sh"
source "$SCRIPT_DIR/modules/desktop-niri/fedora-provider-apply.sh"

DEBUG=${DEBUG:-0}
CN_MIRROR=${CN_MIRROR:-0}

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
desktop_niri_contract_init
info_kv "Target" "$TARGET_USER"

# Fedora's Starship and icon/font assets are target-user providers rather than
# DNF package aliases.  Resolve them before changing desktop configuration so
# a network, checksum, archive or fontconfig failure leaves the existing
# desktop tree untouched.
if platform_is_fedora; then
  section "Step 0/9" "Fedora Starship and Exact Fonts"
  fedora_desktop_provider_apply_system "$TARGET_USER" "$HOME_DIR" || {
    error "Fedora desktop provider apply failed; refusing desktop mutations."
    exit 1
  }
fi

# DM Check
SKIP_AUTOLOGIN=false
DM_FOUND=""
APPLY_STATUS=0
if platform_is_fedora; then
  # Fedora is a graphical-login-only platform for this module.  Never prompt
  # for, create, or preserve a tty fallback; the formal display-manager and
  # Wayland-session contracts below report missing/broken providers clearly.
  SKIP_AUTOLOGIN=true
  if DM_FOUND=$(niri_fedora_display_manager_provider); then
    info_kv "Display manager" "$DM_FOUND"
    if ! niri_fedora_display_manager_package_satisfied "$DM_FOUND"; then
      warn "Fedora display-manager provider '$DM_FOUND' has no matching installed package."
      APPLY_STATUS=1
    fi
  else
    warn "Fedora display-manager contract is missing or inactive; no TTY fallback will be created."
    APPLY_STATUS=1
  fi
elif DM_FOUND=$(niri_detect_display_manager); then
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
# Package failures must not block the user-data restoration below; the module
# still exits non-zero at the end so the runner records the failure.
bash "$SCRIPT_DIR/modules/desktop-niri/packages-apply.sh" || APPLY_STATUS=$?
if platform_is_fedora && ! niri_fedora_wayland_session_entry_satisfied; then
  warn "Fedora Niri Wayland session desktop entry is missing or does not use Exec=niri-session."
  APPLY_STATUS=1
fi
if platform_is_fedora && ! niri_fedora_kwin_wayland_runtime_satisfied; then
  warn "Fedora kwin_wayland runtime ABI check failed (${NIRI_FEDORA_KWIN_RUNTIME_REASON:-unknown}); desktop session remains failed."
  APPLY_STATUS=1
fi

log "Configuring Firefox Policies..."
POL_DIR=$(dirname "$NIRI_FIREFOX_POLICY_FILE")
exe mkdir -p "$POL_DIR"
POLICY_TMP=$(mktemp)
niri_firefox_policy_contract > "$POLICY_TMP"
install_if_changed "$POLICY_TMP" "$NIRI_FIREFOX_POLICY_FILE" 644
rm -f "$POLICY_TMP"
exe chmod 755 "$POL_DIR"
niri_firefox_policy_matches

# ==============================================================================
# STEP 3: File Manager
# ==============================================================================
section "Step 2/9" "File Manager"
install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" \
  "$(dirname "$NIRI_GNOME_TERMINAL_LINK")" \
  "$(dirname "$NIRI_NAUTILUS_OVERRIDE_FILE")"
if ! niri_user_terminal_link_matches; then
  LINK_STAGE=$(mktemp -d \
    "$(dirname "$NIRI_GNOME_TERMINAL_LINK")/.terminal-link.XXXXXX")
  ln -s "$NIRI_GNOME_TERMINAL_TARGET" "$LINK_STAGE/gnome-terminal"
  chown -h "$TARGET_USER:" "$LINK_STAGE/gnome-terminal"
  mv -Tf "$LINK_STAGE/gnome-terminal" "$NIRI_GNOME_TERMINAL_LINK"
  rmdir "$LINK_STAGE"
fi

NAUTILUS_TMP=$(mktemp)
niri_nautilus_override_contract > "$NAUTILUS_TMP"
install_if_changed "$NAUTILUS_TMP" "$NIRI_NAUTILUS_OVERRIDE_FILE" 644
rm -f "$NAUTILUS_TMP"
chown "$TARGET_USER:" "$NIRI_NAUTILUS_OVERRIDE_FILE"
niri_user_terminal_link_matches
niri_nautilus_override_matches
# ==============================================================================
# STEP 5: Dependencies (RESTORED FZF)
# ==============================================================================
section "Step 4/9" "Dependencies"
log "Required and selected desktop packages converged."

# ==============================================================================
# STEP 6: Dotfiles
# ==============================================================================
section "Step 5/9" "Dotfiles, Wallpapers, and Templates"
if niri_apply_dotfiles_and_session "$TARGET_USER" \
  "$SCRIPT_DIR/modules/desktop-niri/dotfiles-apply.sh"; then
  :
else
  APPLY_STATUS=$?
  [ "$APPLY_STATUS" -ne 0 ] || APPLY_STATUS=1
  exit "$APPLY_STATUS"
fi

# ==============================================================================
# STEP 8: Hardware Tools
# ==============================================================================
section "Step 7/9" "Hardware"
if package_is_installed ddcutil; then
  if platform_is_fedora; then
    log "Fedora ddcutil uses udev permissions; no i2c group assignment is required."
  elif getent group i2c >/dev/null 2>&1; then
    gpasswd -a "$TARGET_USER" i2c
    ensure_line /etc/modules-load.d/i2c-dev.conf i2c-dev
  else
    warn "ddcutil is installed but the Fedora i2c group is unavailable; skipping group assignment."
  fi
fi
if package_is_installed swayosd; then
  if systemctl list-unit-files swayosd-libinput-backend.service >/dev/null 2>&1; then
    ensure_service_started swayosd-libinput-backend.service
  else
    warn "swayosd is installed but swayosd-libinput-backend.service is unavailable; skipping service activation."
  fi
fi
success "Tools configured."

# ==============================================================================
# STEP 9: Cleanup & Auto-Login
# ==============================================================================
section "Final" "Cleanup & Boot"

if [ "$SKIP_AUTOLOGIN" = true ]; then
  log "Auto-login skipped."
else
  log "Configuring TTY Auto-login..."
  success "TTY1 auto-login enabled; .bash_profile starts niri-session."
fi
ensure_niri_autologin_state "$TARGET_USER" "$SKIP_AUTOLOGIN"

log "Module 04 completed."
exit "$APPLY_STATUS"
