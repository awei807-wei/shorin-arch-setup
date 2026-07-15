#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"

BASE_PACKAGES=(
    adobe-source-han-sans-cn-fonts adobe-source-han-serif-cn-fonts
    alsa-firmware alsa-ucm-conf archlinuxcn-keyring base-devel fastfetch
    fcitx5 fcitx5-chinese-addons fcitx5-configtool fcitx5-gtk fcitx5-mozc
    fcitx5-qt fcitx5-rime flatpak libva-utils noto-fonts noto-fonts-cjk
    noto-fonts-emoji paru pavucontrol pciutils pipewire pipewire-alsa
    pipewire-jack pipewire-pulse power-profiles-daemon sof-firmware
    terminus-font ttf-jetbrains-mono-nerd usbutils wireplumber xdg-user-dirs
    yay
)

ARCHLINUXCN_BODY='Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch
Server = https://mirrors.hit.edu.cn/archlinuxcn/$arch
Server = https://repo.huaweicloud.com/archlinuxcn/$arch'

base_target_editor() {
    printf '%s\n' "${BASE_EDITOR:-vim}"
}

base_expect() {
    local phase=$1 label=$2
    shift 2

    if [ "$phase" = check ]; then
        module_check_state "$label" "$@"
    elif ! "$@"; then
        module_verify_failed "$label"
    fi
}

base_inspect() {
    local phase=$1 package unit editor

    for package in "${BASE_PACKAGES[@]}"; do
        base_expect "$phase" "package:$package" state_package_present "$package"
    done
    base_expect "$phase" service:power-profiles-daemon \
        state_service_enabled power-profiles-daemon.service
    for unit in pipewire.service pipewire-pulse.service wireplumber.service; do
        base_expect "$phase" "global-unit:$unit" \
            systemctl --global is-enabled --quiet "$unit"
    done
    base_expect "$phase" pacman:multilib pacman_section_matches \
        /etc/pacman.conf multilib 'Include = /etc/pacman.d/mirrorlist'
    base_expect "$phase" pacman:archlinuxcn pacman_section_matches \
        /etc/pacman.conf archlinuxcn "$ARCHLINUXCN_BODY"
    editor=$(base_target_editor)
    base_expect "$phase" "command:$editor" command -v "$editor"
    base_expect "$phase" environment:EDITOR key_value_matches \
        /etc/environment EDITOR "$editor"
    base_expect "$phase" vconsole:FONT key_value_matches \
        /etc/vconsole.conf FONT ter-v28n
    base_expect "$phase" locale:zh_CN bash -c \
        'locale -a | grep -Fqi zh_CN.utf8'

    if [ -z "${TARGET_USER:-}" ]; then
        if [ "$phase" = check ]; then
            module_drift target-user
        else
            module_verify_failed target-user
        fi
    else
        base_expect "$phase" "user:$TARGET_USER" state_user_exists "$TARGET_USER"
        if state_user_exists "$TARGET_USER"; then
            base_expect "$phase" "group:$TARGET_USER:wheel" \
                state_user_in_group "$TARGET_USER" wheel
        fi
    fi
}

base_check() { base_inspect check; }

base_apply() {
    local implementation="$SHORIN_ROOT/scripts/modules/base"
    bash "$implementation/system-apply.sh" || return
    bash "$implementation/essentials-apply.sh" || return
    bash "$implementation/user-apply.sh" || return
    bash "$implementation/gpu-apply.sh" || return
}

base_verify() { base_inspect verify; }

module_main base "$@"
