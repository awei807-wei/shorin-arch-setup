#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# 02-musthave.sh - Essential Software, Drivers & Locale
# ==============================================================================

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/modules/base/targets.sh"

check_root

log ">>> Starting Phase 2: Essential (Must-have) Software & Drivers"

if platform_is_fedora; then
    section "Fedora" "Audio, Locale, Bluetooth, and Flatpak"
    ensure_packages sof-firmware alsa-ucm-conf alsa-firmware glibc-langpack-zh \
        pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack \
        pavucontrol fcitx5 fcitx5-gtk fcitx5-qt fcitx5-configtool \
        fcitx5-chinese-addons fcitx5-rime fcitx5-mozc usbutils pciutils \
        fastfetch flatpak
    base_ensure_power_profile_provider
    while IFS= read -r unit; do
        systemctl --global is-enabled --quiet "$unit" ||
            systemctl --global enable "$unit"
    done < <(base_global_service_units)
    BLUETOOTH_STATUS=0
    base_bluetooth_present || BLUETOOTH_STATUS=$?
    if [ "$BLUETOOTH_STATUS" -eq 0 ]; then
        ensure_package bluez
        ensure_service_started bluetooth.service
    elif [ "$BLUETOOTH_STATUS" -eq 2 ]; then
        warn 'Bluetooth hardware inspection unavailable; continuing without bluez.'
    fi
    if base_flatpak_system_remote_named; then
        base_flathub_system_remote_present ||
            flatpak remote-modify --system --url="$FLATHUB_REPO_URL" flathub
    else
        flatpak_status=$?
        [ "$flatpak_status" -eq 1 ] || die 'Unable to inspect system Flatpak remotes.'
        flatpak remote-add --system flathub \
            https://dl.flathub.org/repo/flathub.flatpakrepo
    fi
    base_flathub_system_remote_present
    success 'Fedora essentials converged.'
    exit 0
fi

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

if base_locale_present; then
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

BLUETOOTH_STATUS=0
base_bluetooth_present || BLUETOOTH_STATUS=$?
if [ "$BLUETOOTH_STATUS" -eq 0 ]; then
    info_kv "Hardware" "Detected"

    log "Installing Bluez "
    ensure_package bluez

    ensure_service_started bluetooth.service
    success "Bluetooth service enabled."
elif [ "$BLUETOOTH_STATUS" -eq 1 ]; then
    info_kv "Hardware" "Not Found"
    warn "No Bluetooth device detected. Skipping installation."
else
    die 'Unable to inspect Bluetooth hardware.'
fi

# ------------------------------------------------------------------------------
# 6. Power
# ------------------------------------------------------------------------------
section "Step 5/7" "Power Management"

base_ensure_power_profile_provider
success "Power profile provider enabled."

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
if base_flatpak_system_remote_named; then
    base_flathub_system_remote_present ||
        exe flatpak remote-modify --system --url="$FLATHUB_REPO_URL" flathub
else
    flatpak_status=$?
    [ "$flatpak_status" -eq 1 ] || die 'Unable to inspect system Flatpak remotes.'
    exe flatpak remote-add --system flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo
fi
base_flathub_system_remote_present

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
