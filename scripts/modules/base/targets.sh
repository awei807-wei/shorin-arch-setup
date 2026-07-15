#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/core.sh"

FLATHUB_REPO_URL=${FLATHUB_REPO_URL:-https://dl.flathub.org/repo/}

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
    grep -Eqi "$vendor" <<< "$info"
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
    model=$(grep -i NVIDIA <<< "$info" | head -n 1)
    grep -Eqi 'RTX|GTX 16|GTX 10|GTX 9(50|60|70|80)|GTX 7(45|50)|GTX 8(40|45|50|60)M|GTX 9(50|60)M|GeForce (830|840|930|940)M|Titan|Quadro GV100|GTX 6[0-9][0-9]|GTX 7(60|65|70|75|80)|GT 6[0-9][0-9]|GT (710M|720|730M|735M|740|745M|750M|755M|920M)|Quadro (410|K[0-9]+)|Tesla K(10|20|40|80)|NVS (510|1000)|Tegra (K1|X1)' <<< "$model"
}

base_gpu_target_packages() {
    local info=${1:-} model kernel
    local -a packages=(libva-utils)

    if [ -z "$info" ]; then
        info=$(base_gpu_info) || return 2
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
        model=$(grep -i NVIDIA <<< "$info" | head -n 1)
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
