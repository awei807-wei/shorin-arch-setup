#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
BIN_DIR="$TEST_DIR/bin"
INSTALLED="$TEST_DIR/installed"
METADATA="$TEST_DIR/metadata"
DNF_CALLS="$TEST_DIR/dnf-calls"
mkdir -p "$BIN_DIR"
: > "$INSTALLED"
: > "$METADATA"
: > "$DNF_CALLS"
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

cat > "$BIN_DIR/rpm" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[ "${1:-}" = -q ] || exit 2
if [ "${2:-}" = --qf ]; then
    package=${4:-}
else
    package=${2:-}
fi
if [ -n "${RPM_QUERY_ERROR_PACKAGE:-}" ] &&
    [ "$package" = "$RPM_QUERY_ERROR_PACKAGE" ]; then
    exit 7
fi
grep -Fqx "$package" "${NVIDIA_TEST_INSTALLED:?}" || exit 1
if [ "${2:-}" = --qf ]; then
    if [ -n "${RPM_METADATA_ERROR_PACKAGE:-}" ] &&
        [ "$package" = "$RPM_METADATA_ERROR_PACKAGE" ]; then
        exit 7
    fi
    if [[ ${3:-} == *VENDOR* ]]; then
        found=0
        while IFS='|' read -r name candidate_vendor candidate_packager \
            candidate_distribution candidate_url; do
            [ "$name" = "$package" ] || continue
            printf '%s\t%s\t%s\t%s\n' \
                "$candidate_vendor" "$candidate_packager" \
                "$candidate_distribution" "$candidate_url"
            found=1
        done < "${NVIDIA_TEST_METADATA:?}"
        [ "$found" -eq 1 ] || printf '%s\t%s\t%s\t%s\n' \
            '(none)' '(none)' '(none)' '(none)'
    else
        printf '1-1.fc44\n'
    fi
fi
EOF
cat > "$BIN_DIR/dnf" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'dnf:%s\n' "$*" >> "${NVIDIA_TEST_DNF_CALLS:?}"
exit 64
EOF
chmod 755 "$BIN_DIR"/*

export PATH="$BIN_DIR:$PATH"
export NVIDIA_TEST_INSTALLED="$INSTALLED" NVIDIA_TEST_METADATA="$METADATA"
export NVIDIA_TEST_DNF_CALLS="$DNF_CALLS"
export SHORIN_ROOT="$ROOT_DIR" SHORIN_SCRIPTS_DIR="$ROOT_DIR/scripts"
export SHORIN_DISTRO=fedora SHORIN_MODE=repair SHORIN_READ_ONLY=0
source "$ROOT_DIR/scripts/lib/core.sh"
source "$ROOT_DIR/scripts/modules/base/targets.sh"

reset_state() {
    : > "$INSTALLED"
    : > "$METADATA"
    unset RPM_QUERY_ERROR_PACKAGE RPM_METADATA_ERROR_PACKAGE
}

add_package() {
    local package=$1 provider=$2

    printf '%s\n' "$package" >> "$INSTALLED"
    case "$provider" in
        rpmfusion)
            printf '%s|%s|%s|%s|%s\n' "$package" \
                'RPM Fusion' 'RPM Fusion Team' 'RPM Fusion' \
                'https://www.nvidia.com/' >> "$METADATA"
            ;;
        external)
            printf '%s|%s|%s|%s|%s\n' "$package" \
                'NVIDIA Corporation' 'CUDA Installer Team' \
                'NVIDIA CUDA Repository' 'https://developer.nvidia.com/cuda-zone' \
                >> "$METADATA"
            ;;
        unknown)
            printf '%s|%s|%s|%s|%s\n' "$package" \
                'Unknown Vendor' 'Local Builder' 'Private Packages' \
                'https://rpmfusion.org/untrusted-rebuild' >> "$METADATA"
            ;;
        *) fail "unknown mock provider: $provider" ;;
    esac
}

reset_state
base_fedora_nvidia_provider_compatible ||
    fail 'clean Fedora system was rejected by the NVIDIA provider contract'
base_fedora_nvidia_provider_preflight ||
    fail 'clean Fedora system failed the NVIDIA provider preflight'
[ ! -s "$DNF_CALLS" ] || fail 'clean NVIDIA preflight invoked dnf'

reset_state
for package in akmod-nvidia xorg-x11-drv-nvidia-cuda \
    nvidia-modprobe nvidia-persistenced nvidia-settings nvidia-xconfig; do
    add_package "$package" rpmfusion
done
base_fedora_nvidia_provider_compatible ||
    fail 'RPM Fusion-only NVIDIA state was rejected'
base_fedora_nvidia_provider_preflight ||
    fail 'RPM Fusion-only NVIDIA state failed preflight'
external=$(base_fedora_nvidia_installed_external_driver_packages)
[ -z "$external" ] ||
    fail "RPM Fusion shared-name packages were misclassified: $external"
for package in akmod-nvidia xorg-x11-drv-nvidia-cuda; do
    base_fedora_nvidia_rpmfusion_package_satisfied "$package" ||
        fail "RPM Fusion target provenance was rejected: $package"
    base_gpu_package_target_satisfied "$package" ||
        fail "GPU verify rejected an RPM Fusion target: $package"
done

reset_state
cuda_packages=(
    kmod-nvidia-open-dkms
    nvidia-driver
    nvidia-driver-common
    nvidia-driver-cuda
    nvidia-driver-cuda-libs
    nvidia-driver-libs
    nvidia-kmod-common
    nvidia-modprobe
    nvidia-persistenced
)
for package in "${cuda_packages[@]}"; do
    add_package "$package" external
done
external=$(base_fedora_nvidia_installed_external_driver_packages)
for package in "${cuda_packages[@]}"; do
    grep -Fqx "$package" <<< "$external" ||
        fail "CUDA provider inventory omitted $package"
done
status=0
base_fedora_nvidia_provider_compatible || status=$?
[ "$status" -eq 1 ] ||
    fail "external NVIDIA provider must be incompatible (got $status)"
status=0
output=$(base_fedora_nvidia_provider_preflight 2>&1) || status=$?
[ "$status" -eq 1 ] ||
    fail "external NVIDIA provider preflight must fail safely (got $status)"
grep -Fq 'external Fedora NVIDIA driver provider' <<< "$output" ||
    fail 'external NVIDIA provider failure lacks a precise reason'
grep -Fq 'kmod-nvidia-open-dkms nvidia-driver' <<< "$output" ||
    fail 'external NVIDIA provider failure does not list installed conflicts'
grep -Fq 'nvidia-modprobe nvidia-persistenced' <<< "$output" ||
    fail 'external NVIDIA provider failure omits shared-name CUDA packages'
grep -Fq 'dnf remove --assumeno' <<< "$output" ||
    fail 'external NVIDIA provider failure lacks a non-mutating recovery probe'
[ ! -s "$DNF_CALLS" ] ||
    fail 'external NVIDIA provider preflight attempted a dnf transaction'

reset_state
add_package akmod-nvidia rpmfusion
add_package xorg-x11-drv-nvidia-cuda rpmfusion
add_package nvidia-driver external
add_package nvidia-modprobe external
status=0
output=$(base_fedora_nvidia_provider_preflight 2>&1) || status=$?
[ "$status" -eq 1 ] || fail 'mixed NVIDIA provider state must fail preflight'
grep -Fq 'Mixed Fedora NVIDIA providers detected' <<< "$output" ||
    fail 'mixed NVIDIA provider failure is not identified as mixed'
grep -Fq 'RPM Fusion: akmod-nvidia xorg-x11-drv-nvidia-cuda' <<< "$output" ||
    fail 'mixed NVIDIA provider failure omits the RPM Fusion side'
grep -Fq 'external: nvidia-driver nvidia-modprobe' <<< "$output" ||
    fail 'mixed NVIDIA provider failure omits the external shared-name side'

reset_state
add_package nvidia-persistenced unknown
status=0
output=$(base_fedora_nvidia_provider_preflight 2>&1) || status=$?
[ "$status" -eq 3 ] ||
    fail "unknown shared-package provenance must fail closed (got $status)"
grep -Fq 'Unable to inspect installed Fedora NVIDIA provider packages' \
    <<< "$output" || fail 'unknown shared-package provenance lacks a reason'

reset_state
add_package nvidia-modprobe rpmfusion
export RPM_METADATA_ERROR_PACKAGE=nvidia-modprobe
status=0
output=$(base_fedora_nvidia_provider_preflight 2>&1) || status=$?
[ "$status" -eq 7 ] ||
    fail "shared-package metadata query error must be preserved (got $status)"
grep -Fq 'Unable to inspect installed Fedora NVIDIA provider packages' \
    <<< "$output" || fail 'shared-package metadata error lacks a reason'

reset_state
add_package nvidia-settings rpmfusion
add_package nvidia-settings external
status=0
base_fedora_nvidia_provider_compatible || status=$?
[ "$status" -eq 4 ] ||
    fail "same-name cross-provider RPM instances must fail closed (got $status)"

reset_state
export RPM_QUERY_ERROR_PACKAGE=nvidia-driver
status=0
output=$(base_fedora_nvidia_provider_preflight 2>&1) || status=$?
[ "$status" -eq 7 ] ||
    fail "NVIDIA RPM inspection error must be preserved (got $status)"
grep -Fq 'Unable to inspect installed Fedora NVIDIA provider packages' \
    <<< "$output" || fail 'NVIDIA inspection error lacks an actionable reason'

reset_state
add_package akmod-nvidia external
status=0
base_fedora_nvidia_provider_compatible || status=$?
[ "$status" -eq 1 ] ||
    fail 'an external build using an RPM Fusion target name was accepted'
status=0
base_gpu_package_target_satisfied akmod-nvidia || status=$?
[ "$status" -eq 1 ] ||
    fail 'GPU verify accepted an externally sourced RPM Fusion target name'

reset_state
add_package xorg-x11-drv-nvidia-cuda unknown
status=0
base_fedora_nvidia_provider_compatible || status=$?
[ "$status" -eq 3 ] ||
    fail 'unknown RPM Fusion target provenance did not fail closed'
status=0
base_gpu_package_target_satisfied xorg-x11-drv-nvidia-cuda || status=$?
[ "$status" -eq 3 ] ||
    fail 'GPU verify did not preserve unknown target provenance status'

for package in cuda-drivers kmod-nvidia-latest-dkms \
    kmod-nvidia-open-dkms nvidia-driver nvidia-driver-cuda \
    nvidia-driver-cuda-libs nvidia-driver-libs nvidia-open \
    xorg-x11-nvidia; do
    base_fedora_nvidia_external_driver_packages | grep -Fqx "$package" ||
        fail "external NVIDIA provider contract omits $package"
done
for package in nvidia-modprobe nvidia-persistenced nvidia-settings \
    nvidia-xconfig; do
    base_fedora_nvidia_shared_driver_packages | grep -Fqx "$package" ||
        fail "shared NVIDIA provider contract omits $package"
done

preflight_line=$(rg -n 'base_fedora_nvidia_provider_preflight' \
    "$ROOT_DIR/scripts/modules/base/gpu-apply.sh" | head -1 | cut -d: -f1)
environment_line=$(rg -n 'ensure_key_value /etc/environment GSK_RENDERER' \
    "$ROOT_DIR/scripts/modules/base/gpu-apply.sh" | cut -d: -f1)
package_line=$(rg -n 'mapfile -t GPU_PACKAGES' \
    "$ROOT_DIR/scripts/modules/base/gpu-apply.sh" | cut -d: -f1)
[ "$preflight_line" -lt "$environment_line" ] &&
    [ "$preflight_line" -lt "$package_line" ] ||
    fail 'NVIDIA preflight must run before environment or package mutations'
grep -Fq 'gpu-provider:nvidia-rpmfusion-exclusive' \
    "$ROOT_DIR/scripts/modules/base.sh" ||
    fail 'base check/verify does not inspect NVIDIA provider exclusivity'
grep -Fq 'base_gpu_package_target_satisfied "$package"' \
    "$ROOT_DIR/scripts/modules/base.sh" ||
    fail 'base GPU package verify does not enforce RPM Fusion provenance'

printf 'PASS: Fedora NVIDIA provider preflight is exclusive and fail-safe\n'
