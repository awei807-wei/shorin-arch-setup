#!/bin/bash

# ==============================================================================
# 02-musthave.sh - Essential Software, Drivers & Locale
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-utils.sh"

check_root

log ">>> Starting Phase 2: Essential (Must-have) Software & Drivers"

# ------------------------------------------------------------------------------
# 1. Btrfs & Snapper Configuration
# ------------------------------------------------------------------------------
log "Step 1/8: Checking filesystem and Snapper configuration..."

ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)

if [ "$ROOT_FSTYPE" == "btrfs" ]; then
    log "-> Btrfs filesystem detected. Installing Snapper tools..."
    pacman -S --noconfirm --needed snapper snap-pac btrfs-assistant > /dev/null 2>&1
    success "Snapper, snap-pac, and btrfs-assistant installed."

    if [ -d "/boot/grub" ] || [ -f "/etc/default/grub" ]; then
        log "-> GRUB detected. Configuring grub-btrfs snapshot integration..."
        pacman -S --noconfirm --needed grub-btrfs inotify-tools > /dev/null 2>&1
        systemctl enable --now grub-btrfsd > /dev/null 2>&1
        success "grub-btrfs installed and daemon enabled."

        log "-> Configuring mkinitcpio for read-only snapshot booting (overlayfs)..."
        if grep -q "grub-btrfs-overlayfs" /etc/mkinitcpio.conf; then
            log "-> grub-btrfs-overlayfs hook already exists. Skipping."
        else
            sed -i 's/^HOOKS=(\(.*\))/HOOKS=(\1 grub-btrfs-overlayfs)/' /etc/mkinitcpio.conf
            log "-> Added grub-btrfs-overlayfs to HOOKS. Regenerating initramfs..."
            mkinitcpio -P > /dev/null 2>&1
            success "Initramfs regenerated."
        fi

        log "-> Regenerating GRUB configuration..."
        if [ -f "/efi/grub/grub.cfg" ]; then
            grub-mkconfig -o /efi/grub/grub.cfg > /dev/null 2>&1
        elif [ -f "/boot/grub/grub.cfg" ]; then
            grub-mkconfig -o /boot/grub/grub.cfg > /dev/null 2>&1
        fi
        success "GRUB configuration updated."
    fi
else
    log "-> Root filesystem is not Btrfs. Skipping Snapper setup."
fi

# ------------------------------------------------------------------------------
# 2. Audio & Video Firmware/Services
# ------------------------------------------------------------------------------
log "Step 2/8: Installing Audio/Video Firmware and Pipewire..."

pacman -S --noconfirm --needed sof-firmware alsa-ucm-conf alsa-firmware > /dev/null 2>&1
pacman -S --noconfirm --needed pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack pavucontrol > /dev/null 2>&1

log "-> Enabling Pipewire services globally..."
systemctl --global enable pipewire pipewire-pulse wireplumber > /dev/null 2>&1
success "Audio setup complete."

# ------------------------------------------------------------------------------
# 3. [NEW] Chinese Locale Generation
# ------------------------------------------------------------------------------
log "Step 3/8: Checking Chinese Locale (zh_CN.UTF-8)..."

# Check if zh_CN.utf8 is already available in the generated list
if locale -a | grep -iq "zh_CN.utf8"; then
    success "Chinese locale (zh_CN.UTF-8) is already generated."
else
    log "-> Chinese locale not found. Configuring /etc/locale.gen..."
    
    # Use sed to uncomment 'zh_CN.UTF-8 UTF-8'
    # The pattern matches the line starting with optional #, optional spaces, then zh_CN...
    sed -i 's/^#\s*zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
    
    log "-> Running locale-gen..."
    if locale-gen > /dev/null 2>&1; then
        success "Chinese locale generated successfully."
    else
        warn "Failed to generate locale. Please check /etc/locale.gen manually."
    fi
fi

# ------------------------------------------------------------------------------
# 4. Input Method (Fcitx5)
# ------------------------------------------------------------------------------
log "Step 4/8: Installing Fcitx5 and Rime (Ice Pinyin)..."

pacman -S --noconfirm --needed fcitx5-im fcitx5-rime rime-ice-pinyin-git fcitx5-mozc > /dev/null 2>&1

log "-> Configuring Rime defaults (Ice Pinyin) in /etc/skel..."
target_dir="/etc/skel/.local/share/fcitx5/rime"
mkdir -p "$target_dir"
cat <<EOT > "$target_dir/default.custom.yaml"
patch:
  __include: rime_ice_suggestion:/
EOT
success "Fcitx5 installed and default config prepared."

# ------------------------------------------------------------------------------
# 5. Bluetooth
# ------------------------------------------------------------------------------
log "Step 5/8: Installing and enabling Bluetooth..."

pacman -S --noconfirm --needed bluez blueman > /dev/null 2>&1
systemctl enable --now bluetooth > /dev/null 2>&1
success "Bluetooth enabled."

# ------------------------------------------------------------------------------
# 6. Power Management
# ------------------------------------------------------------------------------
log "Step 6/8: Installing Power Profiles Daemon..."

pacman -S --noconfirm --needed power-profiles-daemon > /dev/null 2>&1
systemctl enable --now power-profiles-daemon > /dev/null 2>&1
success "Power profiles daemon enabled."

# ------------------------------------------------------------------------------
# 7. Fastfetch
# ------------------------------------------------------------------------------
log "Step 7/8: Installing Fastfetch..."

pacman -S --noconfirm --needed fastfetch > /dev/null 2>&1
success "Fastfetch installed."

# ------------------------------------------------------------------------------
# 8. User Directories (xdg-user-dirs)
# ------------------------------------------------------------------------------
log "Step 8/8: Installing xdg-user-dirs..."

pacman -S --noconfirm --needed xdg-user-dirs > /dev/null 2>&1
success "xdg-user-dirs installed."

log ">>> Phase 2 (Must-have) completed."