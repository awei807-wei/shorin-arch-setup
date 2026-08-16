#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SHORIN_DISTRO=arch
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

if resolve_target_user root; then
    fail 'root may run the installer but must never be accepted as the desktop target user'
fi

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
SNAPPER_HOME_TARGET=/home
SNAPPER_GET_CONFIG_STATUS=0
snapper() {
    local config=${6:-}

    [ "${1:-}" = --csvout ] &&
        [ "${2:-}" = --separator ] &&
        [ "${3:-}" = $'\t' ] &&
        [ "${4:-}" = --no-headers ] &&
        [ "${5:-}" = -c ] &&
        [ "${7:-}" = get-config ] &&
        [ "${8:-}" = --columns ] &&
        [ "${9:-}" = key,value ] || return 64
    [ "$SNAPPER_GET_CONFIG_STATUS" -eq 0 ] ||
        return "$SNAPPER_GET_CONFIG_STATUS"
    printf '"FSTYPE"\t"btrfs"\n'
    case "$config" in
        root) printf '"SUBVOLUME"\t"/"\n' ;;
        home) printf '"SUBVOLUME"\t"%s"\n' "$SNAPPER_HOME_TARGET" ;;
        *) return 1 ;;
    esac
}
mkdir -p "$SNAPPER_CONFIG_DIR"
for config in root home; do
    for setting in "${SNAPPER_TARGET_SETTINGS[@]}"; do
        printf '%s="%s"\n' "${setting%%=*}" "${setting#*=}"
    done > "$SNAPPER_CONFIG_DIR/$config"
done
snapper_config_matches root || fail 'declared Snapper values must pass'
SNAPPER_HOME_TARGET=/wrong-home
if snapper_config_matches home; then
    fail 'a Snapper home config targeting another subvolume must be rejected'
fi
SNAPPER_HOME_TARGET=/home
sed -i 's/^NUMBER_LIMIT="20"/NUMBER_LIMIT="99"/' \
    "$SNAPPER_CONFIG_DIR/root"
if snapper_config_matches root; then
    fail 'incorrect Snapper values must be detected'
fi
SNAPPER_GET_CONFIG_STATUS=3
status=0
snapshot_config_subvolume_matches root / || status=$?
[ "$status" -eq 2 ] ||
    fail 'Snapper command failures must remain inspection errors'
SNAPPER_GET_CONFIG_STATUS=0

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
NETWORK_START_CALLS=0
NETWORK_AUTOSTART_CALLS=0
NETWORK_QUERY_STATUS=0
NETWORK_START_STATUS=0
NETWORK_START_ACTIVATES=1
virsh() {
    case "$1 $2" in
        'net-info default')
            [ "${LC_ALL:-}" = C ] || return 3
            if [ "$NETWORK_QUERY_STATUS" -ne 0 ]; then
                return "$NETWORK_QUERY_STATUS"
            fi
            if [ "$NETWORK_DEFINED" -ne 1 ]; then
                printf 'error: Network not found: no network with matching name default\n' >&2
                return 1
            fi
            printf 'Active: %s\nAutostart: %s\n' \
                "$([ "$NETWORK_ACTIVE" -eq 1 ] && printf yes || printf no)" \
                "$([ "$NETWORK_AUTOSTART" -eq 1 ] && printf yes || printf no)"
            ;;
        'net-define '*) NETWORK_DEFINED=1 ;;
        'net-start default')
            NETWORK_START_CALLS=$((NETWORK_START_CALLS + 1))
            [ "$NETWORK_START_ACTIVATES" -eq 1 ] && NETWORK_ACTIVE=1
            return "$NETWORK_START_STATUS"
            ;;
        'net-autostart default') NETWORK_AUTOSTART_CALLS=$((NETWORK_AUTOSTART_CALLS + 1)); NETWORK_AUTOSTART=1 ;;
        *) return 1 ;;
    esac
}
ensure_virtualization_default_network
[ "$NETWORK_DEFINED:$NETWORK_ACTIVE:$NETWORK_AUTOSTART" = 1:1:1 ] ||
    fail 'missing libvirt default network must be defined, started, and enabled'
[ "$NETWORK_START_CALLS" -eq 1 ] ||
    fail 'missing libvirt default network must start exactly once'
virtualization_default_network_ready ||
    fail 'converged libvirt default network must verify'
ensure_virtualization_default_network
[ "$NETWORK_START_CALLS" -eq 1 ] ||
    fail 'active libvirt default network must not be started again'
NETWORK_AUTOSTART=0
ensure_virtualization_default_network
[ "$NETWORK_START_CALLS" -eq 1 ] ||
    fail 'active libvirt default network must not call net-start when autostart is missing'
[ "$NETWORK_AUTOSTART_CALLS" -eq 2 ] ||
    fail 'missing libvirt network autostart must be repaired idempotently'
NETWORK_QUERY_STATUS=7
status=0
virtualization_default_network_ready || status=$?
[ "$status" -eq 7 ] ||
    fail 'real virsh network query errors must remain inspection errors'
status=0
ensure_virtualization_default_network || status=$?
[ "$status" -eq 7 ] ||
    fail 'real virsh apply query errors must remain failures'
[ "$NETWORK_START_CALLS" -eq 1 ] ||
    fail 'real virsh query errors must not trigger a blind net-start'

# A concurrent libvirt start may win the race even though our net-start call
# returns non-zero.  Accept that only after a fresh net-info query; a genuine
# failure without an active network must keep its original error.
NETWORK_QUERY_STATUS=0
NETWORK_ACTIVE=0
NETWORK_AUTOSTART=1
NETWORK_START_STATUS=7
NETWORK_START_ACTIVATES=1
status=0
ensure_virtualization_default_network || status=$?
[ "$status" -eq 0 ] ||
    fail 'a concurrent activation must satisfy virtualization network apply'
virtualization_default_network_ready ||
    fail 'a concurrently activated network must verify after start race'
NETWORK_ACTIVE=0
NETWORK_START_ACTIVATES=0
status=0
ensure_virtualization_default_network || status=$?
[ "$status" -eq 7 ] ||
    fail 'a failed network start without concurrent activation must preserve its error'
NETWORK_START_STATUS=0
NETWORK_START_ACTIVATES=1

base_gpu_info() { return 2; }
status=0
base_nvidia_model_supported || status=$?
[ "$status" -eq 2 ] ||
    fail 'unavailable GPU inspection must not be treated as no NVIDIA hardware'

printf 'PASS: base, storage, and virtualization target contracts\n'
