#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Distribution detection and package-name translation live in one place so the
# Arch path remains unchanged while Fedora can share the module runner.

SHORIN_DISTRO=${SHORIN_DISTRO:-}

platform_detect_distro() {
    local id_like id

    if [ -n "$SHORIN_DISTRO" ]; then
        case "${SHORIN_DISTRO,,}" in
            arch|archlinux) SHORIN_DISTRO=arch ;;
            fedora|fedoralinux) SHORIN_DISTRO=fedora ;;
            *) return 1 ;;
        esac
        export SHORIN_DISTRO
        return 0
    fi
    id=''
    id_like=''
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id=${ID:-}
        id_like=${ID_LIKE:-}
    fi
    case "${id,,}" in
        arch|archlinux) SHORIN_DISTRO=arch ;;
        fedora) SHORIN_DISTRO=fedora ;;
        *)
            case " ${id_like,,} " in
                *' arch '*) SHORIN_DISTRO=arch ;;
                *' fedora '*) SHORIN_DISTRO=fedora ;;
                *) return 1 ;;
            esac
            ;;
    esac
    export SHORIN_DISTRO
}

platform_detect_distro || true

platform_is_arch() { [ "${SHORIN_DISTRO:-}" = arch ]; }
platform_is_fedora() { [ "${SHORIN_DISTRO:-}" = fedora ]; }

platform_preflight() {
    platform_detect_distro || {
        printf 'ERROR: unsupported Linux distribution; set SHORIN_DISTRO=arch or fedora.\n' >&2
        return 1
    }
    if platform_is_fedora; then
        command -v dnf >/dev/null 2>&1 || {
            printf 'ERROR: Fedora target requires dnf.\n' >&2
            return 1
        }
        command -v rpm >/dev/null 2>&1 || {
            printf 'ERROR: Fedora target requires rpm.\n' >&2
            return 1
        }
    else
        command -v pacman >/dev/null 2>&1 || {
            printf 'ERROR: Arch target requires pacman.\n' >&2
            return 1
        }
    fi
}

platform_package_manager() {
    platform_is_fedora && printf '%s\n' dnf || printf '%s\n' pacman
}

platform_rpm_installed() {
    command -v rpm >/dev/null 2>&1 || return 2
    rpm -q "$1" >/dev/null 2>&1
}

platform_dnf_package_available() {
    command -v dnf >/dev/null 2>&1 || return 2
    dnf info "$1" >/dev/null 2>&1
}

platform_dnf_install() {
    require_writable_mode 2>/dev/null || return
    command -v dnf >/dev/null 2>&1 || return 1
    dnf install -y --setopt=install_weak_deps=False "$@"
}

# Fedora package names intentionally cover only packages selected by the
# repository manifests. Unknown Arch-only names are rejected instead of being
# passed through to dnf by accident.
fedora_package_name() {
    local package=$1
    case "$package" in
        # Arch package names with known Fedora counterparts.
        adobe-source-han-sans-cn-fonts|adobe-source-han-serif-cn-fonts)
            printf '%s\n' adobe-source-han-sans-cn-fonts ;;
        alsa-ucm-conf) printf '%s\n' alsa-ucm ;;
        base-devel) printf '%s\n' '@development-tools' ;;
        fcitx5-chinese-addons) printf '%s\n' fcitx5-chinese-addons ;;
        fcitx5-configtool) printf '%s\n' fcitx5-configtool ;;
        fcitx5-mozc) printf '%s\n' fcitx5-mozc ;;
        fcitx5-rime) printf '%s\n' fcitx5-rime ;;
        fcitx5-gtk|fcitx5-qt|fcitx5|flatpak|flatseal|fastfetch|firefox|fish|fuzzel|fzf|git|niri|vim|gdm|sddm|lightdm|lxdm|slim|ly|greetd|btrfs-progs|snapper|btrfs-assistant|\
        gnome-calendar|gnome-clocks|gnome-disk-utility|gnome-font-viewer|\
        gnome-keyring|gnome-software|gnome-text-editor|gvfs-smb|imagemagick|\
        imv|jq|kitty|less|libnotify|lact|lsof|mako|mangohud|mesa|mpv|nautilus|\
        neovim|noto-fonts|noto-fonts-cjk|noto-fonts-emoji|obs-studio|pavucontrol|\
        pciutils|pipewire|pipewire-alsa|pipewire-jack|pipewire-pulse|\
        polkit-gnome|power-profiles-daemon|quickshell|ripgrep|slurp|starship|\
        steam|swayidle|swaylock|swayosd|terminus-font|usbutils|virt-manager|\
        waypaper|wf-recorder|wine|wireplumber|xdg-desktop-portal-gnome|\
        xdg-desktop-portal-gtk|xwayland-satellite|yazi|zoxide|btop|baobab|\
        bluetui|bluez|brightnessctl|cava|curtail|dosfstools|eza|exfatprogs|f2fs-tools|\
        file-roller|fragments|gamescope|gnome-disk-utility|grub2-tools|ddcutil|dbus|fd|\
        alsa-plugins|giflib|glfw|gst-plugins-base-libs|gtk3|libjpeg-turbo|libva|libxslt|mpg123|openal|ttf-liberation|wine-gecko|wine-mono|\
        hyprpicker|libva-utils|libvirt|libvirt-daemon|libvirt-daemon-kvm|\
        libvirt-client|libvirt-daemon-config-network|librime-tools|\
        librsvg2-tools|mission-center|nwg-look|\
        ntfs-3g|opencl-icd-loader|os-prober|qemu-kvm|swtpm|dnsmasq|mesa-dri-drivers|\
        mesa-vulkan-drivers|mesa-va-drivers|mesa-libOpenCL|intel-media-driver|\
        intel-compute-runtime|akmod-nvidia|xorg-x11-drv-nvidia-cuda|\
        ffmpegthumbnailer|gst-plugins-base|gst-plugins-good|gst-libav|matugen|awww|lutris|code|grim|thefuck|\
        clipse|clipse-gui|niriswitcher|wlogout|swaylock|python3-pywalfox|\
        nautilus-open-any-terminal|\
        xdg-user-dirs|xfsprogs|udftools|breeze|breeze-gtk|breeze-icons|breeze5|lxgw-wenkai-fonts|jetbrains-mono-fonts|\
        glibc-langpack-zh|nfs-utils|tsukimi|\
        qt5ct|qt6ct|qt6-wayland|qt6-multimedia|qt6-qtbase|qt6-qtdeclarative|\
        wl-clipboard|cliphist|satty|swayosd)
            printf '%s\n' "$package" ;;
        # Common Arch spellings that differ on Fedora.
        alsa-firmware|sof-firmware) printf '%s\n' alsa-firmware ;;
        bluez-utils) printf '%s\n' bluez ;;
        lib32-*) return 1 ;;
        libva-nvidia-driver) printf '%s\n' xorg-x11-drv-nvidia-cuda ;;
        ttf-jetbrains-mono-nerd|ttf-jetbrains-maple-mono-nf-xx-xx)
            printf '%s\n' jetbrains-mono-fonts ;;
        ttf-lxgw-wenkai-screen) printf '%s\n' lxgw-wenkai-fonts ;;
        xdg-user-dirs) printf '%s\n' xdg-user-dirs ;;
        qemu-full) printf '%s\n' qemu-kvm ;;
        *) return 1 ;;
    esac
}

fedora_arch_target_name() {
    local target=$1 package
    case "$target" in
        AUR:*) package=${target#AUR:} ;;
        *) package=$target ;;
    esac
    case "$package" in
        nautilus-open-any-terminal) printf '%s\n' nautilus-open-any-terminal ;;
        swaylock-effects) printf '%s\n' swaylock ;;
        wlogout-git|wlogout) printf '%s\n' wlogout ;;
        ddcutil-service) printf '%s\n' ddcutil ;;
        python-pywalfox) printf '%s\n' python3-pywalfox ;;
        waypaper) printf '%s\n' waypaper ;;
        nir*s*witcher) printf '%s\n' niriswitcher ;;
        # NVIDIA AUR driver variants are replaced with Fedora's RPM Fusion
        # package name. Availability is still checked by dnf/rpm.
        nvidia-*|opencl-nvidia-*|lib32-nvidia-*) printf '%s\n' akmod-nvidia ;;
        *) fedora_package_name "$package" ;;
    esac
}

fedora_target_is_dnf_package() {
    local package
    package=$(fedora_arch_target_name "$1") || return 1
    [ -n "$package" ] && [ "$package" != @development-tools ]
}
