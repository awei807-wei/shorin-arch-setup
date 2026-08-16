#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# 01-base.sh - Base System Configuration
# ==============================================================================

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/modules/base/targets.sh"

check_root

log "Starting Phase 1: Base System Configuration..."

if platform_is_fedora; then
    mapfile -t FEDORA_BASE_PACKAGES < <(base_declared_packages)
    section "Fedora" "Base System Packages"
    # Fedora intentionally has no pacman.conf/multilib/ArchLinuxCN mutation.
    # The package wrapper translates logical manifest names to Fedora names and
    # dnf never receives an unapproved Arch-only target.
    ensure_packages "${FEDORA_BASE_PACKAGES[@]}"
    TARGET_EDITOR=${BASE_EDITOR:-vim}
    ensure_package "$TARGET_EDITOR"
    ensure_key_value /etc/environment EDITOR "$TARGET_EDITOR"
    if ! key_value_matches /etc/vconsole.conf FONT ter-v28n; then
        ensure_key_value /etc/vconsole.conf FONT ter-v28n
        systemctl restart systemd-vconsole-setup.service ||
            warn 'Unable to restart systemd-vconsole-setup; the vconsole font will apply on reboot.'
    fi
    if command -v localectl >/dev/null 2>&1; then
        localectl set-locale LANG=zh_CN.UTF-8 ||
            warn 'Unable to set zh_CN.UTF-8 with localectl; continuing with package convergence.'
    fi
    success 'Fedora base packages and locale prerequisites converged.'
    exit 0
fi

# ------------------------------------------------------------------------------
# 1. Set Global Default Editor
# ------------------------------------------------------------------------------
section "Step 1/6" "Global Default Editor"

TARGET_EDITOR=${BASE_EDITOR:-vim}
if ! command -v "$TARGET_EDITOR" >/dev/null 2>&1; then
    case "$TARGET_EDITOR" in
        vim) ensure_package gvim ;;
        nvim) ensure_package neovim ;;
        nano) ensure_package nano ;;
        *) die "Unsupported BASE_EDITOR: $TARGET_EDITOR" ;;
    esac
fi

log "Ensuring EDITOR=$TARGET_EDITOR in /etc/environment..."
ensure_key_value /etc/environment EDITOR "$TARGET_EDITOR"
success "Global EDITOR set to: ${TARGET_EDITOR}"

# ------------------------------------------------------------------------------
# 2. Enable 32-bit (multilib) Repository
# ------------------------------------------------------------------------------
section "Step 2/6" "Multilib Repository"

MULTILIB_BODY='Include = /etc/pacman.d/mirrorlist'
if ! pacman_section_matches /etc/pacman.conf multilib "$MULTILIB_BODY"; then
    ensure_pacman_section /etc/pacman.conf multilib "$MULTILIB_BODY"
    log "Refreshing database after changing multilib..."
    exe pacman -Syu --noconfirm
fi
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
# setfont only works on a virtual console; a re-run over SSH or from a
# graphical terminal must not abort the whole module here.
if CURRENT_TTY=$(tty 2>/dev/null) && [[ "$CURRENT_TTY" == /dev/tty[0-9]* ]]; then
    exe setfont ter-v28n
else
    log "Not on a virtual console; skipping the session font (the permanent vconsole font still converges)."
fi

log "Configuring permanent vconsole font..."
if ! key_value_matches /etc/vconsole.conf FONT ter-v28n; then
    ensure_key_value /etc/vconsole.conf FONT ter-v28n
    log "Restarting systemd-vconsole-setup after configuration change..."
    exe systemctl restart systemd-vconsole-setup
fi

success "TTY font configured (ter-v24n)."
# ------------------------------------------------------------------------------
# 4. Configure archlinuxcn Repository
# ------------------------------------------------------------------------------
section "Step 4/6" "ArchLinuxCN Repository"

ARCHLINUXCN_BODY='Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch
Server = https://mirrors.hit.edu.cn/archlinuxcn/$arch
Server = https://repo.huaweicloud.com/archlinuxcn/$arch'
ARCHLINUXCN_CHANGED=false
if ! pacman_section_matches /etc/pacman.conf archlinuxcn "$ARCHLINUXCN_BODY"; then
    ensure_pacman_section /etc/pacman.conf archlinuxcn "$ARCHLINUXCN_BODY"
    ARCHLINUXCN_CHANGED=true
fi
success "ArchLinuxCN repository converged."

log "Installing archlinuxcn-keyring..."
if [ "$ARCHLINUXCN_CHANGED" = true ]; then
    exe pacman -Syu --noconfirm archlinuxcn-keyring
else
    ensure_package archlinuxcn-keyring
fi
success "ArchLinuxCN configured."

# ------------------------------------------------------------------------------
# 5. Install AUR Helpers
# ------------------------------------------------------------------------------
section "Step 5/6" "AUR Helpers"

log "Installing the yay AUR helper..."
ensure_packages base-devel yay
success "AUR helper installed."

log "Module 01 completed."
