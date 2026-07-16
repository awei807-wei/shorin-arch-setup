#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/modules/base/targets.sh"

check_root
[ -n "${TARGET_USER:-}" ] || die 'TARGET_USER is required for GPU package installation.'
GPU_INFO=$(base_gpu_info) || die 'Unable to inspect GPU hardware.'
base_nvidia_model_supported "$GPU_INFO" ||
    die 'The detected NVIDIA GPU has no declared driver target.'

if [ "$(base_gpu_count "$GPU_INFO")" -ge 2 ] &&
    base_gpu_has_vendor NVIDIA "$GPU_INFO"; then
    ensure_key_value /etc/environment GSK_RENDERER gl
fi

mapfile -t GPU_PACKAGES < <(base_gpu_target_packages "$GPU_INFO")

section Installation 'Installing hardware-derived GPU packages'
for package in "${GPU_PACKAGES[@]}"; do
    case "$package" in
        AUR:*) ensure_aur_package "${package#AUR:}" "$TARGET_USER" "${HOME_DIR:-}" ;;
        *) ensure_package "$package" ;;
    esac
done

if [ "$(base_gpu_count "$GPU_INFO")" -ge 2 ] &&
    base_gpu_has_vendor NVIDIA "$GPU_INFO" &&
    systemctl list-unit-files switcheroo-control.service >/dev/null 2>&1; then
    ensure_service_enabled switcheroo-control.service
fi

success 'GPU driver targets converged.'
