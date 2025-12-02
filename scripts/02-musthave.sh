#!/bin/bash

# ==============================================================================
# 02-musthave.sh - Essential Software, Drivers & Locale
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-utils.sh"

check_root

# ------------------------------------------------------------------------------
# 1. Btrfs & Snapper Configuration
# ------------------------------------------------------------------------------
section "Step 1/8" "Filesystem & Snapshot Setup"

ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)

if [ "$ROOT_FSTYPE" == "btrfs" ]; then
    log "Btrfs filesystem detected."
    
    # 1. Install Tools
    exe pacman -S --noconfirm --needed snapper snap-pac btrfs-assistant
    success "Snapper tools installed."

    # 2. Initialize Snapper Config
    log "Initializing Snapper 'root' configuration..."
    
    # Check if config already exists to avoid errors
    if ! snapper list-configs | grep -q "^root "; then
        # Snapper creates a subvolume at /.snapshots
        # It fails if /.snapshots already exists as a directory
        if [ -d "/.snapshots" ]; then
            warn "Removing existing /.snapshots directory for initialization..."
            exe_silent umount /.snapshots
            exe_silent rm -rf /.snapshots
        fi
        
        # Create config for root
        if exe snapper -c root create-config /; then
            success "Snapper config 'root' created."
            
            # 3. Apply Retention Policy (Prevent disk full)
            log "Applying optimized retention policy..."
            exe snapper -c root set-config \
                ALLOW_GROUPS="wheel" \
                TIMELINE_CREATE="yes" \
                TIMELINE_CLEANUP="yes" \
                NUMBER_LIMIT="10" \
                NUMBER_LIMIT_IMPORTANT="5" \
                TIMELINE_LIMIT_HOURLY="5" \
                TIMELINE_LIMIT_DAILY="7" \
                TIMELINE_LIMIT_WEEKLY="0" \
                TIMELINE_LIMIT_MONTHLY="0" \
                TIMELINE_LIMIT_YEARLY="0"
                
            success "Retention policy applied."
        else
            error "Failed to create Snapper config."
        fi
    else
        log "Snapper config 'root' already exists."
    fi
    
    # 4. Enable Cleanup Timers
    exe systemctl enable --now snapper-timeline.timer snapper-cleanup.timer

    # 5. GRUB Integration
    if [ -d "/boot/grub" ] || [ -f "/etc/default/grub" ]; then
        log "Checking GRUB directory structure..."

        # Fix /boot/grub symlink if ESP is at /efi
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

        log "Configuring grub-btrfs..."
        exe pacman -S --noconfirm --needed grub-btrfs inotify-tools
        exe systemctl enable --now grub-btrfsd

        # Mkinitcpio Hook (Overlayfs for read-only snapshots)
        if ! grep -q "grub-btrfs-overlayfs" /etc/mkinitcpio.conf; then
            log "Adding overlayfs hook to mkinitcpio..."
            sed -i 's/^HOOKS=(\(.*\))/HOOKS=(\1 grub-btrfs-overlayfs)/' /etc/mkinitcpio.conf
            exe mkinitcpio -P
        fi

        log "Regenerating GRUB..."
        exe grub-mkconfig -o /boot/grub/grub.cfg
    fi
else
    log "Root is not Btrfs. Skipping Snapper setup."
fi

# ------------------------------------------------------------------------------
# 2. Audio & Video
# ------------------------------------------------------------------------------
section "Step 2/8" "Audio & Video"

log "Installing firmware..."
exe pacman -S --noconfirm --needed sof-firmware alsa-ucm-conf alsa-firmware

log "Installing Pipewire stack..."
exe pacman -S --noconfirm --needed pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack pavucontrol

exe systemctl --global enable pipewire pipewire-pulse wireplumber
success "Audio setup complete."

# ------------------------------------------------------------------------------
# 3. Locale
# ------------------------------------------------------------------------------
section "Step 3/8" "Locale Configuration"

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
section "Step 4/8" "Input Method (Fcitx5)"

exe pacman -S --noconfirm --needed fcitx5-im fcitx5-rime rime-ice-pinyin-git fcitx5-mozc

log "Configuring Rime defaults..."
TARGET_DIR="/etc/skel/.local/share/fcitx5/rime"
exe mkdir -p "$TARGET_DIR"
cat <<EOT > "$TARGET_DIR/default.custom.yaml"
patch:
  __include: rime_ice_suggestion:/
EOT
success "Fcitx5 configured."

# ------------------------------------------------------------------------------
# 5. Bluetooth
# ------------------------------------------------------------------------------
section "Step 5/8" "Bluetooth"

exe pacman -S --noconfirm --needed bluez blueman
exe systemctl enable --now bluetooth
success "Bluetooth ready."

# ------------------------------------------------------------------------------
# 6. Power
# ------------------------------------------------------------------------------
section "Step 6/8" "Power Management"

exe pacman -S --noconfirm --needed power-profiles-daemon
exe systemctl enable --now power-profiles-daemon
success "Power profiles daemon enabled."

# ------------------------------------------------------------------------------
# 7. Fastfetch
# ------------------------------------------------------------------------------
section "Step 7/8" "Fastfetch"

exe pacman -S --noconfirm --needed fastfetch
success "Fastfetch installed."

# ------------------------------------------------------------------------------
# 8. XDG Dirs
# ------------------------------------------------------------------------------
section "Step 8/8" "User Directories"

exe pacman -S --noconfirm --needed xdg-user-dirs
success "xdg-user-dirs installed."

log "Module 02 completed."