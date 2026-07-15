#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# 01-base.sh - Base System Configuration
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-utils.sh"

check_root

log "Starting Phase 1: Base System Configuration..."

# ------------------------------------------------------------------------------
# 1. Set Global Default Editor
# ------------------------------------------------------------------------------
section "Step 1/6" "Global Default Editor"

TARGET_EDITOR="vim"

if command -v nvim &> /dev/null; then
    TARGET_EDITOR="nvim"
    log "Neovim detected."
elif command -v nano &> /dev/null; then
    TARGET_EDITOR="nano"
    log "Nano detected."
else
    log "Neovim or Nano not found. Installing Vim..."
    if ! command -v vim &> /dev/null; then
        exe pacman -Syu --noconfirm gvim
    fi
fi

log "Ensuring EDITOR=$TARGET_EDITOR in /etc/environment..."
ensure_key_value /etc/environment EDITOR "$TARGET_EDITOR"
success "Global EDITOR set to: ${TARGET_EDITOR}"

# ------------------------------------------------------------------------------
# 2. Enable 32-bit (multilib) Repository
# ------------------------------------------------------------------------------
section "Step 2/6" "Multilib Repository"

ensure_pacman_section /etc/pacman.conf multilib \
    'Include = /etc/pacman.d/mirrorlist'
log "Refreshing database after converging multilib..."
exe pacman -Syu --noconfirm
success "[multilib] converged."

# ------------------------------------------------------------------------------
# 3. Install Base Fonts
# ------------------------------------------------------------------------------
section "Step 3/6" "Base Fonts"

log "Installing adobe-source-han-serif-cn-fonts adobe-source-han-sans-cn-fonts noto-fonts-cjk, noto-fonts, emoji..."
ensure_packages adobe-source-han-serif-cn-fonts adobe-source-han-sans-cn-fonts \
    noto-fonts-cjk noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd
log "Base fonts installed."

log "Installing terminus-font..."
# 安装 terminus-font 包
ensure_package terminus-font

log "Setting font for current session..."
exe setfont ter-v28n

log "Configuring permanent vconsole font..."
ensure_key_value /etc/vconsole.conf FONT ter-v28n

log "Restarting systemd-vconsole-setup..."
exe systemctl restart systemd-vconsole-setup

success "TTY font configured (ter-v24n)."
# ------------------------------------------------------------------------------
# 4. Configure archlinuxcn Repository
# ------------------------------------------------------------------------------
section "Step 4/6" "ArchLinuxCN Repository"

ARCHLINUXCN_BODY='Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch
Server = https://mirrors.hit.edu.cn/archlinuxcn/$arch
Server = https://repo.huaweicloud.com/archlinuxcn/$arch'
ensure_pacman_section /etc/pacman.conf archlinuxcn "$ARCHLINUXCN_BODY"
success "ArchLinuxCN repository converged."

log "Installing archlinuxcn-keyring..."
# Keyring installation often needs -Sy specifically, but -Syu is safe too
exe pacman -Syu --noconfirm archlinuxcn-keyring
success "ArchLinuxCN configured."

# ------------------------------------------------------------------------------
# 5. Install AUR Helpers
# ------------------------------------------------------------------------------
section "Step 5/6" "AUR Helpers"

log "Installing yay and paru..."
ensure_packages base-devel yay paru
success "Helpers installed."

log "Module 01 completed."
