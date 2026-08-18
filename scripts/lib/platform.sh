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

# Query the complete RPM database without piping the producer into a quiet
# matcher.  A matcher that exits as soon as it finds a result can close the
# pipe while rpm is still writing, which makes bash report SIGPIPE (141) under
# pipefail.  Keeping the query and match as two steps preserves 0/1 state
# semantics while returning a real rpm failure as an inspection error.
platform_rpm_query_all() {
    local output status

    command -v rpm >/dev/null 2>&1 || return 2
    if output=$(rpm -qa 2>/dev/null); then
        printf '%s\n' "$output"
        return 0
    else
        status=$?
    fi
    # rpm normally uses 1 for a failed query as well as for a missing package
    # in -q mode.  For the database-wide query there is no normal "not found"
    # result, so normalize that failure to the inspection-error range.
    [ "$status" -gt 1 ] || status=2
    return "$status"
}

platform_rpm_installed_matching() {
    local pattern=$1 output

    output=$(platform_rpm_query_all) || return $?
    grep -Eqi "$pattern" <<< "$output"
}

platform_dnf_package_available() {
    local package=$1 repository=${2:-} output status
    local query_format='%{name}'
    local -a args

    case "$package" in
        *.i686) query_format='%{name}.%{arch}' ;;
    esac
    args=(repoquery --available --qf "$query_format")

    command -v dnf >/dev/null 2>&1 || return 2
    [ -n "$repository" ] && args+=("--enablerepo=$repository")
    args+=("$package")
    # DNF5 may return success for an unknown package while producing no
    # rows.  Treat an empty result as drift and only propagate a real query
    # failure as an inspection error.
    if output=$(dnf "${args[@]}" 2>/dev/null); then
        [ -n "$output" ] || return 1
        grep -Fqx "$package" <<< "$output"
    else
        status=$?
        [ "$status" -gt 1 ] || status=2
        return "$status"
    fi
}

platform_dnf_repo_available() {
    local repository=$1 output status

    command -v dnf >/dev/null 2>&1 || return 2
    if output=$(dnf repolist --all 2>/dev/null); then
        [ -n "$output" ] || return 1
        awk -v repository="$repository" '$1 == repository { found=1 }
            END { exit(found ? 0 : 1) }' <<< "$output"
    else
        status=$?
        [ "$status" -gt 1 ] || status=2
        return "$status"
    fi
}

platform_dnf_install() {
    require_writable_mode 2>/dev/null || return
    command -v dnf >/dev/null 2>&1 || return 1
    dnf install -y --setopt=install_weak_deps=False "$@"
}

platform_dnf_install_from_repo() {
    local repository=$1

    shift
    require_writable_mode 2>/dev/null || return
    command -v dnf >/dev/null 2>&1 || return 1
    [ -n "$repository" ] || return 1
    dnf install -y --setopt=install_weak_deps=False \
        "--enablerepo=$repository" "$@"
}

fedora_package_repository() {
    case "$1" in
        akmod-nvidia|xorg-x11-drv-nvidia-cuda)
            printf '%s\n' rpmfusion-nonfree-nvidia-driver
            ;;
        mesa-va-drivers-freeworld)
            # The package is published by RPM Fusion's free updates repo;
            # `freeworld` is part of the package name, not the repo ID.
            printf '%s\n' rpmfusion-free-updates
            ;;
        *) return 1 ;;
    esac
}

# Fedora package names intentionally cover only packages selected by the
# repository manifests. Unknown Arch-only names are rejected instead of being
# passed through to dnf by accident.
fedora_package_name() {
    local package=$1
    case "$package" in
        # Arch package names with known Fedora counterparts.
        adobe-source-han-sans-cn-fonts)
            printf '%s\n' adobe-source-han-sans-cn-fonts ;;
        adobe-source-han-serif-cn-fonts)
            printf '%s\n' adobe-source-han-serif-cn-fonts ;;
        alsa-ucm-conf) printf '%s\n' alsa-ucm ;;
        # Fedora's generic development-tools group is documentation/VCS
        # tooling and does not include gcc/make/binutils.  Arch base-devel
        # semantics match Fedora's C Development Tools group instead.
        base-devel) printf '%s\n' '@c-development' ;;
        fcitx5-chinese-addons) printf '%s\n' fcitx5-chinese-addons ;;
        fcitx5-configtool) printf '%s\n' fcitx5-configtool ;;
        fcitx5-mozc) printf '%s\n' fcitx5-mozc ;;
        fcitx5-rime) printf '%s\n' fcitx5-rime ;;
        fcitx5-gtk|fcitx5-qt|fcitx5|flatpak|flatseal|fastfetch|firefox|fish|fuzzel|fzf|git|niri|gdm|sddm|lightdm|lxdm|slim|ly|greetd|plasma-login-manager|kscreenlocker|kwin|btrfs-progs|snapper|btrfs-assistant|\
        gnome-calendar|gnome-clocks|gnome-disk-utility|gnome-font-viewer|\
        gnome-keyring|gnome-software|gnome-text-editor|gvfs-smb|\
        imv|jq|kitty|less|libnotify|lsof|mako|mangohud|mpv|nautilus|\
        neovim|obs-studio|pavucontrol|\
        pciutils|pipewire|pipewire-alsa|\
        polkit-kde|power-profiles-daemon|tuned-ppd|quickshell|ripgrep|slurp|\
        swayidle|swaylock|swayosd|usbutils|virt-manager|\
        wf-recorder|wine|wireplumber|xdg-desktop-portal-gnome|\
        xdg-desktop-portal-gtk|xwayland-satellite|zoxide|btop|baobab|\
        bluetui|bluez|brightnessctl|cava|dosfstools|eza|exfatprogs|f2fs-tools|\
        file-roller|fragments|gamescope|gnome-disk-utility|grub2-tools|ddcutil|dbus|\
        alsa-plugins|alsa-plugins-pulseaudio|fd-find|giflib|glfw|gstreamer1-plugins-base|gtk3|libjpeg-turbo|libva|libxslt|mpg123|openal-soft|openal-soft.i686|liberation-fonts|wine-mono|mingw32-wine-gecko|mingw64-wine-gecko|\
        hyprpicker|libva-utils|libvirt|libvirt-daemon|libvirt-daemon-kvm|\
        libvirt-client|libvirt-daemon-config-network|librime-tools|\
        librsvg2-tools|nwg-look|\
        ntfs-3g|opencl-icd-loader|os-prober|qemu-kvm|swtpm|dnsmasq|mesa-dri-drivers|\
        mesa-vulkan-drivers|mesa-libOpenCL|mesa-va-drivers-freeworld|\
        intel-compute-runtime|akmod-nvidia|xorg-x11-drv-nvidia-cuda|\
        ffmpegthumbnailer|matugen|lutris|grim|thefuck|\
        wlogout|\
        cargo|rust|gtk4-devel|glib2-devel|pango-devel|cairo-devel|\
        cairo-gobject-devel|gdk-pixbuf2-devel|graphene-devel|\
        gtk4-layer-shell-devel|sqlite-devel|wayland-devel|\
        wayland-protocols-devel|pkgconf-pkg-config|wtype|\
        lz4-devel|curl|unzip|xz|tar|util-linux|\
        xdg-user-dirs|xfsprogs|udftools|breeze-gtk|jetbrains-mono-fonts|fontconfig|\
        glibc-langpack-zh|nfs-utils|tsukimi|\
        qt5ct|qt6ct|qt6-qtbase|qt6-qtdeclarative|\
        wl-clipboard|cliphist|satty|swayosd)
            printf '%s\n' "$package" ;;
        # Common Arch spellings that differ on Fedora.
        alsa-firmware) printf '%s\n' alsa-firmware ;;
        sof-firmware) printf '%s\n' alsa-sof-firmware ;;
        noto-fonts) printf '%s\n' google-noto-sans-fonts ;;
        noto-fonts-cjk) printf '%s\n' google-noto-sans-cjk-fonts ;;
        noto-fonts-emoji) printf '%s\n' google-noto-color-emoji-fonts ;;
        pipewire-pulse) printf '%s\n' pipewire-pulseaudio ;;
        # The project wants PipeWire's JACK implementation.  Fedora's
        # pipewire-plugin-jack only connects PipeWire to an external JACK
        # server, while this package provides the JACK API used by clients.
        pipewire-jack) printf '%s\n' pipewire-jack-audio-connection-kit ;;
        polkit-gnome) printf '%s\n' polkit-kde ;;
        breeze) printf '%s\n' plasma-breeze ;;
        breeze5) printf '%s\n' kf5-qqc2-breeze-style ;;
        breeze-icons) printf '%s\n' breeze-icon-theme ;;
        imagemagick) printf '%s\n' ImageMagick ;;
        terminus-font) printf '%s\n' terminus-fonts-console ;;
        terminus-fonts-console) printf '%s\n' terminus-fonts-console ;;
        vim) printf '%s\n' vim-enhanced ;;
        intel-media-driver) printf '%s\n' libva-intel-media-driver ;;
        gst-plugins-base) printf '%s\n' gstreamer1-plugins-base ;;
        gst-plugins-good) printf '%s\n' gstreamer1-plugins-good ;;
        gst-libav) printf '%s\n' gstreamer1-plugin-libav ;;
        ttf-liberation) printf '%s\n' liberation-fonts ;;
        qt6-wayland) printf '%s\n' qt6-qtwayland ;;
        qt6-multimedia) printf '%s\n' qt6-qtmultimedia ;;
        bluez-utils) printf '%s\n' bluez ;;
        openal) printf '%s\n' openal-soft ;;
        lib32-openal) printf '%s\n' openal-soft.i686 ;;
        lib32-*) return 1 ;;
        libva-nvidia-driver) printf '%s\n' xorg-x11-drv-nvidia-cuda ;;
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
        swaylock-effects) printf '%s\n' swaylock ;;
        wlogout-git|wlogout) printf '%s\n' wlogout ;;
        ddcutil-service) printf '%s\n' ddcutil ;;
        # NVIDIA AUR driver variants are replaced with Fedora's RPM Fusion
        # package name. Availability is still checked by dnf/rpm.
        nvidia-*|opencl-nvidia-*|lib32-nvidia-*) printf '%s\n' akmod-nvidia ;;
        *) fedora_package_name "$package" ;;
    esac
}

fedora_target_is_dnf_package() {
    local package
    package=$(fedora_arch_target_name "$1") || return 1
    [ -n "$package" ] && [ "$package" != @c-development ]
}
