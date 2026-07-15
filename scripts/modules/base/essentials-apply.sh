#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# 02-musthave.sh - Essential Software, Drivers & Locale
# ==============================================================================

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"

check_root

log ">>> Starting Phase 2: Essential (Must-have) Software & Drivers"

# ------------------------------------------------------------------------------
# 2. Audio & Video
# ------------------------------------------------------------------------------
section "Step 1/7" "Audio & Video"

log "Installing firmware..."
ensure_packages sof-firmware alsa-ucm-conf alsa-firmware

log "Installing Pipewire stack..."
ensure_packages pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack pavucontrol

for unit in pipewire.service pipewire-pulse.service wireplumber.service; do
    systemctl --global is-enabled --quiet "$unit" ||
        systemctl --global enable "$unit"
done
success "Audio setup complete."

# ------------------------------------------------------------------------------
# 3. Locale
# ------------------------------------------------------------------------------
section "Step 2/7" "Locale Configuration"

if locale -a | grep -iq "zh_CN.utf8"; then
    success "Chinese locale (zh_CN.UTF-8) is active."
else
    log "Generating zh_CN.UTF-8..."
    sed -i 's/^#\s*zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
    if exe locale-gen; then
        success "Locale generated."
    else
        error "Locale generation failed."
    fi
fi

# ------------------------------------------------------------------------------
# 4. Input Method
# ------------------------------------------------------------------------------
section "Step 3/7" "Input Method (Fcitx5)"

ensure_packages fcitx5 fcitx5-gtk fcitx5-qt fcitx5-configtool \
    fcitx5-chinese-addons fcitx5-rime fcitx5-mozc

success "Fcitx5 installed."

# ------------------------------------------------------------------------------
# 5. Bluetooth (Smart Detection)
# ------------------------------------------------------------------------------
section "Step 4/7" "Bluetooth"

# Ensure detection tools are present
log "Detecting Bluetooth hardware..."
ensure_packages usbutils pciutils

BT_FOUND=false

# 1. Check USB
if lsusb | grep -qi "bluetooth"; then BT_FOUND=true; fi
# 2. Check PCI
if lspci | grep -qi "bluetooth"; then BT_FOUND=true; fi
# 3. Check RFKill
if rfkill list bluetooth >/dev/null 2>&1; then BT_FOUND=true; fi

if [ "$BT_FOUND" = true ]; then
    info_kv "Hardware" "Detected"

    log "Installing Bluez "
    ensure_package bluez

    ensure_service_started bluetooth.service
    success "Bluetooth service enabled."
else
    info_kv "Hardware" "Not Found"
    warn "No Bluetooth device detected. Skipping installation."
fi

# ------------------------------------------------------------------------------
# 6. Power
# ------------------------------------------------------------------------------
section "Step 5/7" "Power Management"

ensure_package power-profiles-daemon
ensure_service_started power-profiles-daemon.service
success "Power profiles daemon enabled."

# ------------------------------------------------------------------------------
# 7. Fastfetch
# ------------------------------------------------------------------------------
section "Step 6/7" "Fastfetch"

ensure_package fastfetch
success "Fastfetch installed."

log "Module 02 completed."

# ------------------------------------------------------------------------------
# 9. flatpak
# ------------------------------------------------------------------------------

ensure_package flatpak
exe flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

CURRENT_TZ=$(readlink -f /etc/localtime)
IS_CN_ENV=false
if [[ "$CURRENT_TZ" == *"Shanghai"* ]] || [ "${CN_MIRROR:-0}" == "1" ] || [ "${DEBUG:-0}" == "1" ]; then
  IS_CN_ENV=true
  info_kv "Region" "China Optimization Active"
fi

if [ "$IS_CN_ENV" = true ] && [ "${SHORIN_MODE:-install}" = install ]; then
  select_flathub_mirror
else
  log "Using Global Sources."
fi
