#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
cleanup() {
    find "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

source "$ROOT_DIR/scripts/modules/base/targets.sh"

flatpak() {
    printf 'flathub\thttps://wrong.example/repo/\n'
}
if base_flathub_system_remote_present; then
    fail 'a Flathub remote with the wrong URL must not satisfy the target'
fi
flatpak() {
    printf 'flathub\thttps://dl.flathub.org/repo/\n'
}
base_flathub_system_remote_present ||
    fail 'the canonical system Flathub URL must satisfy the target'

base_gpu_info() {
    printf '%s\n' '00:02.0 "VGA compatible controller" "Intel Corporation" "UHD Graphics"'
}
pacman() {
    [ "$1" = -Qq ] && printf 'linux\n'
}
GPU_TARGETS=$(base_gpu_target_packages)
grep -Fqx vulkan-intel <<< "$GPU_TARGETS" ||
    fail 'Intel hardware must declare vulkan-intel'
grep -Fqx intel-media-driver <<< "$GPU_TARGETS" ||
    fail 'modern Intel hardware must declare intel-media-driver'

base_gpu_info() {
    printf '%s\n' '01:00.0 "VGA compatible controller" "NVIDIA Corporation" "Unknown Future GPU"'
}
if base_nvidia_model_supported; then
    fail 'unknown NVIDIA hardware must not silently pass target derivation'
fi

source "$ROOT_DIR/scripts/modules/storage/targets.sh"
SNAPPER_CONFIG_DIR="$TEST_DIR/snapper"
mkdir -p "$SNAPPER_CONFIG_DIR"
for config in root home; do
    for setting in "${SNAPPER_TARGET_SETTINGS[@]}"; do
        printf '%s="%s"\n' "${setting%%=*}" "${setting#*=}"
    done > "$SNAPPER_CONFIG_DIR/$config"
done
snapper_config_matches root || fail 'declared Snapper values must pass'
sed -i 's/^NUMBER_LIMIT="20"/NUMBER_LIMIT="99"/' \
    "$SNAPPER_CONFIG_DIR/root"
if snapper_config_matches root; then
    fail 'incorrect Snapper values must be detected'
fi

MOCK_BIN="$TEST_DIR/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/findmnt" <<'EOF'
#!/usr/bin/env bash
printf 'ext4\n'
EOF
chmod +x "$MOCK_BIN/findmnt"

status=0
OUTPUT=$(env PATH="$MOCK_BIN:$PATH" SHORIN_ROOT="$ROOT_DIR" \
    SHORIN_MODE=repair TARGET_USER=tester HOME_DIR="$TEST_DIR/home" \
    bash "$ROOT_DIR/scripts/modules/storage.sh" check 2>&1) || status=$?
[ "$status" -eq 20 ] || fail 'non-Btrfs required storage must not report OK'
grep -Fq 'root-not-btrfs' <<< "$OUTPUT" ||
    fail 'non-Btrfs storage skip must include a reason'

MANIFEST="$TEST_DIR/applications.list"
printf '# no virtualization target\n' > "$MANIFEST"
cat > "$MOCK_BIN/pacman" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -Q ] && [ "$2" = virt-manager ]
EOF
chmod +x "$MOCK_BIN/pacman"
status=0
OUTPUT=$(env PATH="$MOCK_BIN:$PATH" APPLICATION_MANIFEST="$MANIFEST" \
    SHORIN_ROOT="$ROOT_DIR" SHORIN_MODE=repair TARGET_USER=tester \
    HOME_DIR="$TEST_DIR/home" \
    bash "$ROOT_DIR/scripts/modules/virtualization.sh" check 2>&1) || status=$?
[ "$status" -eq 20 ] ||
    fail 'stale virt-manager installation must not become a declared target'
grep -Fq 'not-declared' <<< "$OUTPUT" ||
    fail 'undeclared virtualization target must explain its skip'

printf 'virt-manager\n' > "$MANIFEST"
status=0
OUTPUT=$(env PATH="$MOCK_BIN:$PATH" APPLICATION_MANIFEST="$MANIFEST" \
    SHORIN_ROOT="$ROOT_DIR" SHORIN_MODE=repair TARGET_USER=tester \
    HOME_DIR="$TEST_DIR/home" \
    bash "$ROOT_DIR/scripts/modules/virtualization.sh" check 2>&1) || status=$?
[ "$status" -eq 10 ] ||
    fail 'missing declared virtualization packages must remain repairable drift'
grep -Fq 'package:qemu-full' <<< "$OUTPUT" ||
    fail 'declared virtualization drift must identify its missing package'

source "$ROOT_DIR/scripts/modules/virtualization/contract.sh"
VIRTUALIZATION_DEFAULT_NETWORK_XML="$TEST_DIR/default.xml"
printf '<network/>\n' > "$VIRTUALIZATION_DEFAULT_NETWORK_XML"
NETWORK_DEFINED=0
NETWORK_ACTIVE=0
NETWORK_AUTOSTART=0
virsh() {
    case "$1 $2" in
        'net-info default')
            [ "${LC_ALL:-}" = C ] || return 3
            [ "$NETWORK_DEFINED" -eq 1 ] || return 1
            printf 'Active: %s\nAutostart: %s\n' \
                "$([ "$NETWORK_ACTIVE" -eq 1 ] && printf yes || printf no)" \
                "$([ "$NETWORK_AUTOSTART" -eq 1 ] && printf yes || printf no)"
            ;;
        'net-define '*) NETWORK_DEFINED=1 ;;
        'net-start default') NETWORK_ACTIVE=1 ;;
        'net-autostart default') NETWORK_AUTOSTART=1 ;;
        *) return 1 ;;
    esac
}
ensure_virtualization_default_network
[ "$NETWORK_DEFINED:$NETWORK_ACTIVE:$NETWORK_AUTOSTART" = 1:1:1 ] ||
    fail 'missing libvirt default network must be defined, started, and enabled'
virtualization_default_network_ready ||
    fail 'converged libvirt default network must verify'

base_gpu_info() { return 2; }
status=0
base_nvidia_model_supported || status=$?
[ "$status" -eq 2 ] ||
    fail 'unavailable GPU inspection must not be treated as no NVIDIA hardware'

printf 'PASS: base, storage, and virtualization target contracts\n'
