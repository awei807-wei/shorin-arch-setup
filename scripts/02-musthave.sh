#!/bin/bash

# ==============================================================================
# 02-musthave.sh - Essential Software, Drivers & Locale
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-utils.sh"

check_root

log ">>> Starting Phase 2: Essential (Must-have) Software & Drivers"
# ------------------------------------------------------------------------------
# 1. Btrfs Extras & GRUB (Config was done in 00-btrfs-init)
# ------------------------------------------------------------------------------
section "Step 1/8" "Btrfs Extras & GRUB"

ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)

if [ "$ROOT_FSTYPE" == "btrfs" ]; then
    # Install Extras (snap-pac = auto snapshot on pacman, btrfs-assistant = GUI)
    log "Installing Btrfs tools..."
    exe pacman -Syu --noconfirm --needed snap-pac btrfs-assistant
    
    # Enable Cleanup Timers (Double check)
    exe systemctl enable --now snapper-timeline.timer snapper-cleanup.timer

    # GRUB Integration
    if [ -d "/boot/grub" ] || [ -f "/etc/default/grub" ]; then
        log "Configuring GRUB snapshots..."

        # Fix symlink /boot/grub -> /efi/grub if needed
        if [ -d "/efi/grub" ]; then
            if [ ! -L "/boot/grub" ] || [ "$(readlink -f /boot/grub)" != "/efi/grub" ]; then
                warn "Fixing /boot/grub symlink..."
                if [ -d "/boot/grub" ] && [ ! -L "/boot/grub" ]; then
                    exe mv /boot/grub "/boot/grub.bak.$(date +%s)"
                fi
                exe ln -sf /efi/grub /boot/grub
                success "Symlink fix applied."
            fi
        fi

        exe pacman -Syu --noconfirm --needed grub-btrfs inotify-tools
        exe systemctl enable --now grub-btrfsd

        if ! grep -q "grub-btrfs-overlayfs" /etc/mkinitcpio.conf; then
            log "Adding overlayfs hook to mkinitcpio..."
            sed -i 's/^HOOKS=(\(.*\))/HOOKS=(\1 grub-btrfs-overlayfs)/' /etc/mkinitcpio.conf
            exe mkinitcpio -P
        fi

        log "Regenerating GRUB..."
        exe grub-mkconfig -o /boot/grub/grub.cfg
    fi
else
    log "Root is not Btrfs. Skipping."
fi

# ------------------------------------------------------------------------------
# 2. Audio & Video
# ------------------------------------------------------------------------------
section "Step 2/8" "Audio & Video"
exe pacman -Syu --noconfirm --needed sof-firmware alsa-ucm-conf alsa-firmware
exe pacman -Syu --noconfirm --needed pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack pavucontrol
exe systemctl --global enable pipewire pipewire-pulse wireplumber
success "Audio setup complete."

# ------------------------------------------------------------------------------
# 3. Locale
# ------------------------------------------------------------------------------
section "Step 3/8" "Locale Configuration"
if locale -a | grep -iq "zh_CN.utf8"; then
    success "Chinese locale active."
else
    log "Generating zh_CN.UTF-8..."
    sed -i 's/^#\s*zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
    if exe locale-gen; then success "Generated."; else error "Failed."; fi
fi

# ------------------------------------------------------------------------------
# 4. Input Method
# ------------------------------------------------------------------------------
section "Step 4/8" "Input Method (Fcitx5)"
exe pacman -Syu --noconfirm --needed fcitx5-im fcitx5-rime rime-ice-pinyin-git fcitx5-mozc
TARGET_DIR="/etc/skel/.local/share/fcitx5/rime"
exe mkdir -p "$TARGET_DIR"
cat <<EOT > "$TARGET_DIR/default.custom.yaml"
patch:
  __include: rime_ice_suggestion:/
EOT
success "Configured."

# ------------------------------------------------------------------------------
# 5. Bluetooth (Conditional)
# ------------------------------------------------------------------------------
section "Step 5/8" "Bluetooth"

if [ "$DESKTOP_ENV" == "kde" ]; then
    log "Desktop is KDE: Installing Bluez only (Bluedevil included in Plasma)..."
    exe pacman -Syu --noconfirm --needed bluez
else
    log "Desktop is Niri: Installing Bluez + Blueberry..."
    exe pacman -Syu --noconfirm --needed bluez blueberry
fi

exe systemctl enable --now bluetooth
success "Bluetooth ready."

# ------------------------------------------------------------------------------
# 6. Power
# ------------------------------------------------------------------------------
section "Step 6/8" "Power Management"
exe pacman -Syu --noconfirm --needed power-profiles-daemon
exe systemctl enable --now power-profiles-daemon
success "PPD enabled."

# ------------------------------------------------------------------------------
# 7. Fastfetch
# ------------------------------------------------------------------------------
section "Step 7/8" "Fastfetch"
exe pacman -Syu --noconfirm --needed fastfetch
success "Installed."

# ------------------------------------------------------------------------------
# 8. XDG Dirs
# ------------------------------------------------------------------------------
section "Step 8/8" "User Directories"
exe pacman -Syu --noconfirm --needed xdg-user-dirs
success "Installed."

log "Module 02 completed."