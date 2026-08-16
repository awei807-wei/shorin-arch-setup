#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/core.sh"

FLATHUB_REPO_URL=${FLATHUB_REPO_URL:-https://dl.flathub.org/repo/}

# Keep the package contract in one place.  Both base check/verify and the
# Fedora apply path consume this function so a package cannot be installed
# without also being inspected (or inspected without being installable).
base_declared_packages() {
    if platform_is_fedora; then
        printf '%s\n' \
            adobe-source-han-sans-cn-fonts adobe-source-han-serif-cn-fonts \
            alsa-firmware alsa-ucm-conf base-devel fastfetch \
            glibc-langpack-zh fcitx5 fcitx5-chinese-addons \
            fcitx5-configtool fcitx5-gtk fcitx5-mozc fcitx5-qt fcitx5-rime \
            flatpak libva-utils noto-fonts noto-fonts-cjk noto-fonts-emoji \
            pavucontrol pciutils pipewire pipewire-alsa pipewire-jack \
            pipewire-pulse sof-firmware terminus-font \
            ttf-jetbrains-mono-nerd usbutils vim wireplumber xdg-user-dirs
        return 0
    fi

    printf '%s\n' \
        adobe-source-han-sans-cn-fonts adobe-source-han-serif-cn-fonts \
        alsa-firmware alsa-ucm-conf archlinuxcn-keyring base-devel fastfetch \
        fcitx5 fcitx5-chinese-addons fcitx5-configtool fcitx5-gtk \
        fcitx5-mozc fcitx5-qt fcitx5-rime flatpak libva-utils noto-fonts \
        noto-fonts-cjk noto-fonts-emoji pavucontrol pciutils pipewire \
        pipewire-alsa pipewire-jack pipewire-pulse power-profiles-daemon \
        sof-firmware terminus-font ttf-jetbrains-mono-nerd usbutils \
        wireplumber xdg-user-dirs yay
}

base_global_service_units() {
    if platform_is_fedora; then
        # Fedora enables the user session manager through PipeWire socket
        # activation; wireplumber is intentionally not forced as a global
        # service because its unit may be preset/static on different Fedora
        # releases.
        printf '%s\n' pipewire.socket pipewire-pulse.socket
    else
        printf '%s\n' pipewire.service pipewire-pulse.service wireplumber.service
    fi
}

# Fedora 44 exposes the power-profiles-daemon API through a provider contract.
# tuned-ppd owns the `ppd-service` capability and its unit is
# tuned-ppd.service; power-profiles-daemon provides the same capability through
# power-profiles-daemon.service.  Keep this choice outside the package array so
# the two mutually exclusive providers are never installed together.
base_power_profile_provider() {
    local tuned_status=0 power_status=0

    if ! platform_is_fedora; then
        printf '%s\n' power-profiles-daemon
        return 0
    fi

    package_is_installed tuned-ppd || tuned_status=$?
    case "$tuned_status" in
        0)
            package_is_installed power-profiles-daemon || power_status=$?
            case "$power_status" in
                0) return 3 ;; # Both providers violate the capability contract.
                1) printf '%s\n' tuned-ppd; return 0 ;;
                *) return "$power_status" ;;
            esac
            ;;
        1) ;;
        *) return "$tuned_status" ;;
    esac

    package_is_installed power-profiles-daemon || power_status=$?
    case "$power_status" in
        0) printf '%s\n' power-profiles-daemon; return 0 ;;
        1) return 1 ;;
        *) return "$power_status" ;;
    esac
}

base_power_profile_provider_available() {
    local status=0

    if ! platform_is_fedora; then
        printf '%s\n' power-profiles-daemon
        return 0
    fi

    platform_dnf_package_available tuned-ppd || status=$?
    case "$status" in
        0) printf '%s\n' tuned-ppd; return 0 ;;
        1) ;;
        *) return "$status" ;;
    esac

    status=0
    platform_dnf_package_available power-profiles-daemon || status=$?
    case "$status" in
        0) printf '%s\n' power-profiles-daemon; return 0 ;;
        1) return 1 ;;
        *) return "$status" ;;
    esac
}

base_power_profile_provider_unit() {
    case "$1" in
        tuned-ppd) printf '%s\n' tuned-ppd.service ;;
        power-profiles-daemon) printf '%s\n' power-profiles-daemon.service ;;
        *) return 1 ;;
    esac
}

base_ensure_power_profile_provider() {
    local provider provider_status=0 unit

    provider=$(base_power_profile_provider) || provider_status=$?
    case "$provider_status" in
        0)
            # Arch has one fixed package target, so its installed-state query
            # is intentionally followed by the normal idempotent ensure.
            platform_is_fedora || ensure_package "$provider" || return
            ;;
        1)
            provider_status=0
            provider=$(base_power_profile_provider_available) ||
                provider_status=$?
            case "$provider_status" in
                0) ;;
                1)
                    error 'No Fedora package provides the ppd-service capability; refusing to claim power-profile convergence.'
                    return 1
                    ;;
                *) return "$provider_status" ;;
            esac
            ensure_package "$provider" || return
            ;;
        3)
            error 'Both tuned-ppd and power-profiles-daemon are installed; refusing to alter mutually exclusive PPD providers.'
            return 1
            ;;
        *) return "$provider_status" ;;
    esac

    provider_status=0
    provider=$(base_power_profile_provider) || provider_status=$?
    [ "$provider_status" -eq 0 ] || {
        error 'The selected ppd-service provider was not visible after package convergence.'
        return "$provider_status"
    }
    unit=$(base_power_profile_provider_unit "$provider") || return
    ensure_service_started "$unit"
}

base_locale_present() {
    local locales

    if locales=$(locale -a 2>/dev/null); then
        grep -Fqi 'zh_CN.utf8' <<< "$locales"
    else
        return $?
    fi
}

base_flatpak_system_remote_named() {
    local remotes

    if remotes=$(flatpak remotes --system --columns=name 2>/dev/null); then
        grep -Fqx flathub <<< "$remotes"
    else
        return $?
    fi
}

base_gpu_info() {
    local output

    command -v lspci >/dev/null 2>&1 || return 2
    output=$(lspci -mm 2>/dev/null) || return 2
    grep -E -i 'VGA|3D|Display' <<< "$output" || true
}

base_gpu_has_vendor() {
    local vendor=$1 info=${2:-}

    if [ -z "$info" ]; then
        info=$(base_gpu_info) || return 2
    fi
    # Match a vendor token, not an arbitrary substring in lspci prose.  For
    # example, the word "compatible" contains "ATI" and previously made an
    # Intel-only machine select the AMD Mesa VA/OpenCL targets.
    grep -Eqi "(^|[^[:alnum:]])($vendor)([^[:alnum:]]|$)" <<< "$info"
}

base_gpu_count() {
    local info=${1:-}

    if [ -z "$info" ]; then
        info=$(base_gpu_info) || return 2
    fi
    awk 'NF { count++ } END { print count + 0 }' <<< "$info"
}

base_nvidia_model_supported() {
    local info=${1:-} model

    if [ -z "$info" ]; then
        info=$(base_gpu_info) || return 2
    fi
    grep -Eqi NVIDIA <<< "$info" || return 0
    model=$(awk 'BEGIN { IGNORECASE=1 } /NVIDIA/ { print; exit }' <<< "$info")
    grep -Eqi 'RTX|GTX 16|GTX 10|GTX 9(50|60|70|80)|GTX 7(45|50)|GTX 8(40|45|50|60)M|GTX 9(50|60)M|GeForce (830|840|930|940)M|Titan|Quadro GV100|GTX 6[0-9][0-9]|GTX 7(60|65|70|75|80)|GT 6[0-9][0-9]|GT (710M|720|730M|735M|740|745M|750M|755M|920M)|Quadro (410|K[0-9]+)|Tesla K(10|20|40|80)|NVS (510|1000)|Tegra (K1|X1)' <<< "$model"
}

base_gpu_target_packages() {
    local info=${1:-} model kernel
    local -a packages=(libva-utils)

    if [ -z "$info" ]; then
        info=$(base_gpu_info) || return 2
    fi
    if platform_is_fedora; then
        # Fedora has no `mesa` meta package.  Keep the concrete runtime and
        # Vulkan drivers, then add only the vendor-specific families detected
        # from lspci.  AMD VA support is supplied by RPM Fusion freeworld;
        # ensure_package enforces that repository contract before dnf runs.
        packages=(libva-utils mesa-dri-drivers mesa-vulkan-drivers)
        if base_gpu_has_vendor 'AMD|ATI' "$info"; then
            packages+=(mesa-va-drivers-freeworld mesa-libOpenCL)
        fi
        if base_gpu_has_vendor Intel "$info"; then
            packages+=(intel-media-driver intel-compute-runtime)
        fi
        if base_gpu_has_vendor NVIDIA "$info"; then
            packages+=(akmod-nvidia xorg-x11-drv-nvidia-cuda)
        fi
        printf '%s\n' "${packages[@]}" | sort -u
        return 0
    fi
    if base_gpu_has_vendor 'AMD|ATI' "$info"; then
        packages+=(mesa lib32-mesa xf86-video-amdgpu vulkan-radeon
            lib32-vulkan-radeon linux-firmware-amdgpu gst-plugin-va
            opencl-mesa lib32-opencl-mesa opencl-icd-loader
            lib32-opencl-icd-loader)
    fi
    if base_gpu_has_vendor Intel "$info"; then
        packages+=(mesa vulkan-intel lib32-mesa lib32-vulkan-intel
            gst-plugin-va linux-firmware-intel opencl-mesa
            lib32-opencl-mesa opencl-icd-loader lib32-opencl-icd-loader)
        if grep -Eqi 'Arc|Xe|UHD|Iris|Raptor|Alder|Tiger|Rocket|Ice|Comet|Coffee|Kaby|Skylake|Broadwell|Gemini|Jasper|Elkhart|HD Graphics 6|HD Graphics 5[0-9][0-9]\b' <<< "$info"; then
            packages+=(intel-media-driver)
        fi
    fi
    if [ "$(base_gpu_count "$info")" -ge 2 ]; then
        packages+=(vulkan-mesa-layers lib32-vulkan-mesa-layers)
        base_gpu_has_vendor NVIDIA "$info" &&
            packages+=(nvidia-prime switcheroo-control)
    fi
    if base_gpu_has_vendor NVIDIA "$info"; then
        model=$(awk 'BEGIN { IGNORECASE=1 } /NVIDIA/ { print; exit }' <<< "$info")
        if grep -Eqi 'RTX|GTX 16' <<< "$model"; then
            packages+=(nvidia-open-dkms nvidia-utils lib32-nvidia-utils
                opencl-nvidia lib32-opencl-nvidia libva-nvidia-driver
                vulkan-icd-loader lib32-vulkan-icd-loader opencl-icd-loader
                lib32-opencl-icd-loader)
        elif grep -Eqi 'GTX 10|GTX 9(50|60|70|80)|GTX 7(45|50)|GTX 8(40|45|50|60)M|GTX 9(50|60)M|GeForce (830|840|930|940)M|Titan X|Titan Xp|Titan V|Quadro GV100|Tegra X1' <<< "$model"; then
            packages+=(AUR:nvidia-580xx-dkms AUR:nvidia-580xx-utils
                AUR:opencl-nvidia-580xx AUR:lib32-opencl-nvidia-580xx
                AUR:lib32-nvidia-580xx-utils libva-nvidia-driver
                vulkan-icd-loader lib32-vulkan-icd-loader opencl-icd-loader
                lib32-opencl-icd-loader)
        elif base_nvidia_model_supported "$info"; then
            packages+=(AUR:nvidia-470xx-dkms AUR:nvidia-470xx-utils
                AUR:opencl-nvidia-470xx AUR:lib32-nvidia-470xx-utils
                AUR:lib32-opencl-nvidia-470xx vulkan-icd-loader
                lib32-vulkan-icd-loader libva-nvidia-driver
                opencl-icd-loader lib32-opencl-icd-loader)
        fi
        while IFS= read -r kernel; do
            [ -f "/boot/vmlinuz-$kernel" ] && packages+=("$kernel-headers")
        done < <(pacman -Qq 2>/dev/null | grep '^linux' |
            grep -vE 'headers|firmware|api|docs|tools|utils|qq' || true)
    fi
    printf '%s\n' "${packages[@]}" | sort -u
}

base_gpu_package_name() {
    printf '%s\n' "${1#AUR:}"
}

base_bluetooth_present() {
    local output available=0

    if command -v lsusb >/dev/null 2>&1; then
        if output=$(lsusb 2>/dev/null); then
            available=1
            grep -qi bluetooth <<< "$output" && return 0
        fi
    fi
    if command -v lspci >/dev/null 2>&1; then
        if output=$(lspci 2>/dev/null); then
            available=1
            grep -qi bluetooth <<< "$output" && return 0
        fi
    fi
    if command -v rfkill >/dev/null 2>&1; then
        if output=$(rfkill list bluetooth 2>/dev/null); then
            available=1
            [ -z "$output" ] || return 0
        fi
    fi
    [ "$available" -eq 1 ] || return 2
    return 1
}

base_flathub_system_remote_present() {
    local expected=${FLATHUB_REPO_URL%/}

    flatpak remotes --system --columns=name,url 2>/dev/null |
        awk -v expected="$expected" '
            $1 == "flathub" {
                actual=$2
                sub(/\/$/, "", actual)
                if (actual == expected) found=1
            }
            END { exit(found ? 0 : 1) }
        '
}

base_wheel_sudoers_valid() {
    [ -f /etc/sudoers.d/10-shorin-wheel ] &&
        grep -Fqx '%wheel ALL=(ALL:ALL) ALL' /etc/sudoers.d/10-shorin-wheel &&
        visudo -cf /etc/sudoers.d/10-shorin-wheel >/dev/null 2>&1
}
