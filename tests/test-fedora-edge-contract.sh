#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SHORIN_DISTRO=fedora
TEST_DIR=$(mktemp -d)
BIN_DIR="$TEST_DIR/bin"
CALLS="$TEST_DIR/calls.log"
INSTALLED="$TEST_DIR/installed"
HOME_DIR="$TEST_DIR/home"
FSTAB_FILE="$TEST_DIR/fstab"
RIME_DICT_MANAGER_PATH="$BIN_DIR/rime_dict_manager"
TARGET_USER=$(id -un)
mkdir -p "$BIN_DIR" "$HOME_DIR"
: > "$CALLS"
: > "$INSTALLED"
: > "$FSTAB_FILE"
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

cat > "$BIN_DIR/dnf" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'dnf:%s\n' "$*" >> "${FEDORA_EDGE_CALLS:?}"
if [ "${1:-}" = install ]; then
    printf '%s\n' "${!#}" >> "${FEDORA_EDGE_INSTALLED:?}"
fi
EOF
cat > "$BIN_DIR/rpm" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${1:-}" != -q ]; then
    exit 1
fi
package="${2:-}"
if [ "$package" = --qf ]; then
    package="${@: -1}"
    format=1
else
    format=0
fi
grep -Fqx "$package" "${FEDORA_EDGE_INSTALLED:?}" || exit 1
if [ "$format" -eq 1 ]; then
    printf '1-1\n'
fi
exit 0
EOF
cat > "$BIN_DIR/findmnt" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${1:-}" = --verify ]; then
    exit 0
fi
printf 'ext4\n'
EOF
cat > "$BIN_DIR/mountpoint" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 1
EOF
cat > "$BIN_DIR/timeout" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
shift 2
if [ "${1:-}" = mount ]; then
    exit 1
fi
exec "$@"
EOF
cat > "$BIN_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'systemctl:%s\n' "$*" >> "${FEDORA_EDGE_CALLS:?}"
action=${1:-}
unit=${!#}
case "$action" in
    show)
        case "$unit" in
            libvirtd*.socket|libvirtd.service|virt*.socket|virt*.service)
                printf 'loaded\n'
                ;;
        esac
        ;;
    is-enabled)
        case "$unit" in
            virt*.socket) printf 'enabled\n' ;;
            libvirtd*.socket|libvirtd.service|virt*.service)
                printf 'disabled\n'
                exit 1
                ;;
            *) printf 'enabled\n' ;;
        esac
        ;;
    is-active)
        case "$unit" in
            virt*.socket) exit 0 ;;
            libvirtd*.socket|libvirtd.service|virt*.service) exit 3 ;;
        esac
        ;;
esac
exit 0
EOF
cat > "$BIN_DIR/rime_dict_manager" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'rime:%s\n' "$*" >> "${FEDORA_EDGE_CALLS:?}"
exit 0
EOF
cat > "$BIN_DIR/runuser" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${1:-}" = -u ]; then
    shift 2
    [ "${1:-}" = -- ] && shift
fi
exec "$@"
EOF
cat > "$BIN_DIR/grub2-mkconfig" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${1:-}" = -o ]; then
    printf 'fedora grub config\n' > "$2"
fi
EOF
cat > "$BIN_DIR/grub2-script-check" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF
cat > "$BIN_DIR/virsh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${1:-}" = -c ]; then
    [ "${2:-}" = qemu:///system ] || exit 3
    shift 2
fi
case "${1:-}" in
    uri)
        printf 'qemu:///system\n'
        ;;
    list)
        [ "${2:-}" = --all ] && [ "${3:-}" = --name ] || exit 3
        ;;
    net-info)
        [ "${2:-}" = default ] || exit 3
        printf 'Name: default\nActive: yes\nAutostart: yes\n'
        ;;
    *) exit 3 ;;
esac
EOF
cat > "$BIN_DIR/dbus-run-session" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[ "${1:-}" = -- ] && shift
exec "$@"
EOF
cat > "$BIN_DIR/gsettings" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${1:-}" = get ]; then
    printf "['qemu:///system']\n"
fi
EOF
cat > "$BIN_DIR/usermod" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF
cat > "$BIN_DIR/glib-compile-schemas" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF
cat > "$BIN_DIR/id" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
    -nG) printf 'libvirt kvm input\n' ;;
    -gn) printf 'shiyi\n' ;;
    -u) printf '1000\n' ;;
    *) exec /usr/bin/id "$@" ;;
esac
EOF
chmod +x "$BIN_DIR"/*

export FEDORA_EDGE_CALLS="$CALLS" FEDORA_EDGE_INSTALLED="$INSTALLED"

# The Arch-only helper must be a no-op on Fedora, even when directly invoked
# with a Btrfs root.  The mock dnf/systemctl would expose any accidental
# package or service action without touching the host.
GRUB_DEFAULT_FILE="$TEST_DIR/default-grub"
GRUB_CONFIG_FILE="$TEST_DIR/grub.cfg"
GRUB_MKINITCPIO_FILE="$TEST_DIR/mkinitcpio.conf"
printf 'GRUB_DISABLE_OS_PROBER="false"\n' > "$GRUB_DEFAULT_FILE"
printf 'grub\n' > "$GRUB_CONFIG_FILE"
printf 'HOOKS=(base filesystems)\n' > "$GRUB_MKINITCPIO_FILE"
status=0
output=$(env PATH="$BIN_DIR:$PATH" \
    SHORIN_ROOT="$ROOT_DIR" SHORIN_SCRIPTS_DIR="$ROOT_DIR/scripts" \
    SHORIN_DISTRO=fedora SHORIN_MODE=install GRUB_ROOT_FSTYPE=btrfs \
    GRUB_DEFAULT_FILE="$GRUB_DEFAULT_FILE" GRUB_CONFIG_FILE="$GRUB_CONFIG_FILE" \
    GRUB_MKINITCPIO_FILE="$GRUB_MKINITCPIO_FILE" \
    bash "$ROOT_DIR/scripts/modules/grub/btrfs-apply.sh" 2>&1) || status=$?
[ "$status" -eq 0 ] || fail 'Fedora direct btrfs helper invocation must skip successfully'
grep -Fq 'Skipping Arch-only GRUB Btrfs integration on Fedora.' <<< "$output" ||
    fail 'Fedora btrfs helper skip reason is missing'
[ ! -s "$CALLS" ] ||
    fail 'Fedora btrfs helper must not invoke dnf/systemctl or other mutators'

for package in grub2-tools os-prober exfatprogs; do
    printf '%s\n' "$package" >> "$INSTALLED"
done
status=0
output=$(env PATH="$BIN_DIR:$PATH" \
    SHORIN_ROOT="$ROOT_DIR" SHORIN_DISTRO=fedora SHORIN_MODE=verify \
    GRUB_ROOT_FSTYPE=btrfs GRUB_DEFAULT_FILE="$GRUB_DEFAULT_FILE" \
    GRUB_CONFIG_FILE="$GRUB_CONFIG_FILE" \
    bash "$ROOT_DIR/scripts/modules/grub.sh" check 2>&1) || status=$?
[ "$status" -eq 0 ] || fail 'Fedora GRUB check must not enter the Arch Btrfs path'
! grep -Fq grub-btrfs <<< "$output" ||
    fail 'Fedora GRUB check must not inspect grub-btrfs'
status=0
output=$(env PATH="$BIN_DIR:$PATH" \
    SHORIN_ROOT="$ROOT_DIR" SHORIN_DISTRO=fedora SHORIN_MODE=verify \
    GRUB_ROOT_FSTYPE=btrfs GRUB_DEFAULT_FILE="$GRUB_DEFAULT_FILE" \
    GRUB_CONFIG_FILE="$GRUB_CONFIG_FILE" \
    bash "$ROOT_DIR/scripts/modules/grub.sh" verify 2>&1) || status=$?
[ "$status" -eq 0 ] || fail 'Fedora GRUB verify must not enter the Arch Btrfs path'
! grep -Fq grub-btrfs <<< "$output" ||
    fail 'Fedora GRUB verify must not inspect grub-btrfs'

# The Fedora contract must carry precise package names while Arch keeps its
# existing logical libvirt package.
ARCH_CONTRACT=$(env SHORIN_ROOT="$ROOT_DIR" SHORIN_DISTRO=arch \
    bash -c 'source "$SHORIN_ROOT/scripts/lib/core.sh"; \
        source "$SHORIN_ROOT/scripts/modules/virtualization/contract.sh"; \
        printf "%s\n" "${VIRTUALIZATION_PACKAGES[@]}"')
grep -Fqx libvirt <<< "$ARCH_CONTRACT" ||
    fail 'Arch virtualization contract must retain the libvirt package'
! grep -Fqx libvirt-daemon-kvm <<< "$ARCH_CONTRACT" ||
    fail 'Arch virtualization contract must not use Fedora split package names'

FEDORA_CONTRACT=$(env SHORIN_ROOT="$ROOT_DIR" SHORIN_DISTRO=fedora \
    bash -c 'source "$SHORIN_ROOT/scripts/lib/core.sh"; \
        source "$SHORIN_ROOT/scripts/modules/virtualization/contract.sh"; \
        source "$SHORIN_ROOT/scripts/modules/nas-rime/contract.sh"; \
        printf "virt:%s\n" "${VIRTUALIZATION_PACKAGES[*]}"; \
        printf "rime:%s\n" "${RIME_REQUIRED_PACKAGES[*]}"; \
        printf "cmd:%s\n" "${VIRTUALIZATION_COMMANDS[*]}"; \
        printf "provider:%s\n" "$VIRTUALIZATION_PROVIDER"; \
        printf "modular:%s\n" "${VIRTUALIZATION_MODULAR_REQUIRED_UNITS[*]}"; \
        printf "monolithic:%s\n" "${VIRTUALIZATION_MONOLITHIC_REQUIRED_UNITS[*]}"; \
        printf "service:%s\n" "$VIRTUALIZATION_SERVICE"; \
        printf "network:%s\n" "$VIRTUALIZATION_DEFAULT_NETWORK_XML"')
grep -Fq 'libvirt-daemon libvirt-daemon-kvm libvirt-client libvirt-daemon-config-network' \
    <<< "$FEDORA_CONTRACT" ||
    fail 'Fedora virtualization contract must declare daemon, KVM, client and network packages'
grep -Fqx 'rime:librime-tools' <<< "$FEDORA_CONTRACT" ||
    fail 'Fedora Rime contract must declare librime-tools'
grep -Fqx 'cmd:virsh' <<< "$FEDORA_CONTRACT" ||
    fail 'Virtualization contract must declare virsh as a prerequisite'
grep -Fqx 'provider:auto' <<< "$FEDORA_CONTRACT" ||
    fail 'Virtualization contract must default to automatic provider selection'
grep -Fqx \
    'modular:virtqemud.socket virtproxyd.socket virtnetworkd.socket virtinterfaced.socket virtnodedevd.socket virtnwfilterd.socket virtsecretd.socket virtstoraged.socket' \
    <<< "$FEDORA_CONTRACT" ||
    fail 'Fedora virtualization contract must declare complete modular sockets'
grep -Fqx 'monolithic:libvirtd.socket' <<< "$FEDORA_CONTRACT" ||
    fail 'Virtualization contract must retain a complete monolithic fallback'
grep -Fqx 'service:libvirtd.service' <<< "$FEDORA_CONTRACT" ||
    fail 'Virtualization compatibility alias must retain libvirtd.service'
grep -Fqx 'network:/usr/share/libvirt/networks/default.xml' <<< "$FEDORA_CONTRACT" ||
    fail 'Virtualization contract must declare the default network artifact'
! grep -Fq bridge-utils <<< "$FEDORA_CONTRACT" ||
    fail 'Fedora virtualization contract must not include bridge-utils'

# The path is rendered into both a systemd unit and a shell script. Reject
# unsafe overrides before rendering so an environment value cannot inject
# shell/systemd syntax into managed files.
export SHORIN_DISTRO=fedora
source "$ROOT_DIR/scripts/lib/core.sh"
source "$ROOT_DIR/scripts/modules/nas-rime/contract.sh"
nas_rime_contract_init
unsafe_path="$TEST_DIR/rime-manager\"; echo fedora-edge-path-injection #"
RIME_DICT_MANAGER_PATH="$unsafe_path"
if rime_dict_manager_path_is_safe; then
    fail 'Rime dictionary path validator must reject embedded quotes'
fi
if rime_service_contract > "$TEST_DIR/unsafe.service"; then
    fail 'Rime service contract must reject unsafe dictionary path'
fi
if rime_safe_sync_script_contract > "$TEST_DIR/unsafe-sync.sh"; then
    fail 'Rime safe-sync contract must reject unsafe dictionary path'
fi
! grep -Fq 'fedora-edge-path-injection' "$TEST_DIR/unsafe.service" ||
    fail 'Unsafe dictionary path must not be rendered into the service contract'
! grep -Fq 'fedora-edge-path-injection' "$TEST_DIR/unsafe-sync.sh" ||
    fail 'Unsafe dictionary path must not be rendered into the safe-sync script'
RIME_DICT_MANAGER_PATH="$BIN_DIR/rime_dict_manager"

# Fedora NAS/Rime apply uses a mock dnf and writes only into TEST_DIR.  It must
# install librime-tools explicitly and generate every command reference from
# the same absolute path.
export PATH="$BIN_DIR:$PATH"
export SHORIN_ROOT="$ROOT_DIR" SHORIN_SCRIPTS_DIR="$ROOT_DIR/scripts"
export SHORIN_DISTRO=fedora SHORIN_MODE=install SHORIN_READ_ONLY=0
export TARGET_USER HOME_DIR FSTAB_FILE RIME_DICT_MANAGER_PATH
export NAS_IP=192.0.2.10 NAS_REMOTE_PATH=/archive NAS_LOCAL_PATH="$TEST_DIR/nas"
export RIME_INSTALLATION_ID=fedora-test RIME_SYNC_DIR="$TEST_DIR/nas/rime_sync"
export RIME_DIR="$HOME_DIR/.local/share/fcitx5/rime"
export RIME_INSTALLATION_FILE="$RIME_DIR/installation.yaml"
export PACKAGE_SOURCE_DIR="$TEST_DIR/package-sources"
rm -f "$CALLS" "$INSTALLED"
: > "$CALLS"
: > "$INSTALLED"
status=0
NAS_APPLY_TEST_SCRIPT="$TEST_DIR/nas-rime-apply.sh"
sed '/^check_root$/d' "$ROOT_DIR/scripts/modules/nas-rime/apply.sh" > "$NAS_APPLY_TEST_SCRIPT"
chmod +x "$NAS_APPLY_TEST_SCRIPT"
output=$(bash "$NAS_APPLY_TEST_SCRIPT" "$TARGET_USER" 2>&1) || status=$?
[ "$status" -eq 20 ] ||
    fail 'Fedora NAS apply should report only pending user-bus state in the mock'
grep -Fq 'dnf:install -y --setopt=install_weak_deps=False librime-tools' "$CALLS" ||
    fail 'Fedora NAS apply must install librime-tools through dnf'
! grep -Fq 'fcitx5-rime' "$CALLS" ||
    fail 'Fedora NAS apply must not treat fcitx5-rime as the dictionary-tool provider'
[ -x "$RIME_DICT_MANAGER_PATH" ] ||
    fail 'Rime dictionary manager mock must be executable'
service_file="$HOME_DIR/.config/systemd/user/rime-sync.service"
grep -Fqx "ExecStartPre=/usr/bin/test -x \"$RIME_DICT_MANAGER_PATH\"" "$service_file" ||
    fail 'Rime service must use the unified command path contract'
safe_sync_file="$HOME_DIR/.local/bin/rime-safe-sync.sh"
grep -Fq "\"$RIME_DICT_MANAGER_PATH\" --sync" "$safe_sync_file" ||
    fail 'Rime safe-sync script must use the unified command path contract'
[ -L "$HOME_DIR/.config/systemd/user/timers.target.wants/rime-sync.timer" ] ||
    fail 'Rime timer user-unit link must be created'
[ "$(readlink "$HOME_DIR/.config/systemd/user/timers.target.wants/rime-sync.timer")" = \
    ../rime-sync.timer ] || fail 'Rime timer user-unit link target is incorrect'

status=0
output=$(bash "$ROOT_DIR/scripts/modules/nas-rime.sh" verify 2>&1) || status=$?
[ "$status" -eq 20 ] || fail 'Fedora NAS verify should preserve the explicit offline skip'

sed -i '/^librime-tools$/d' "$INSTALLED"
status=0
output=$(bash "$ROOT_DIR/scripts/modules/nas-rime.sh" verify 2>&1) || status=$?
[ "$status" -eq 1 ] || fail 'Missing Fedora Rime package must fail verification'
grep -Fq 'package:librime-tools' <<< "$output" ||
    fail 'Fedora NAS verify must inspect librime-tools'
printf 'librime-tools\n' >> "$INSTALLED"

status=0
output=$(RIME_DICT_MANAGER_PATH="$TEST_DIR/missing-rime-dict-manager" \
    bash "$ROOT_DIR/scripts/modules/nas-rime.sh" verify 2>&1) || status=$?
[ "$status" -eq 1 ] || fail 'Missing Rime dictionary command must fail verification'
grep -Fq 'command:rime-dict-manager' <<< "$output" ||
    fail 'Missing Rime dictionary command must identify its contract target'

# Execute Fedora virtualization check, verify, and apply paths with mocked
# package/service/virsh/gsettings primitives. No host package manager,
# systemd, libvirt, or user/group state is touched.
for package in qemu-kvm virt-manager swtpm dnsmasq dbus libvirt-daemon \
    libvirt-daemon-kvm libvirt-client libvirt-daemon-config-network; do
    printf '%s\n' "$package" >> "$INSTALLED"
done
APPLICATION_MANIFEST="$TEST_DIR/applications.list"
printf 'virt-manager\n' > "$APPLICATION_MANIFEST"
export APPLICATION_MANIFEST
status=0
output=$(env PATH="$BIN_DIR:$PATH" SHORIN_ROOT="$ROOT_DIR" \
    SHORIN_DISTRO=fedora SHORIN_MODE=verify TARGET_USER="$TARGET_USER" \
    HOME_DIR="$HOME_DIR" APPLICATION_MANIFEST="$APPLICATION_MANIFEST" \
    bash "$ROOT_DIR/scripts/modules/virtualization.sh" check 2>&1) || status=$?
[ "$status" -eq 0 ] || fail 'Fedora virtualization check mock must converge'
grep -Fq 'MODULE_RESULT=virtualization:check:OK' <<< "$output" ||
    fail 'Fedora virtualization check must execute the module contract'
status=0
output=$(env PATH="$BIN_DIR:$PATH" SHORIN_ROOT="$ROOT_DIR" \
    SHORIN_DISTRO=fedora SHORIN_MODE=verify TARGET_USER="$TARGET_USER" \
    HOME_DIR="$HOME_DIR" APPLICATION_MANIFEST="$APPLICATION_MANIFEST" \
    bash "$ROOT_DIR/scripts/modules/virtualization.sh" verify 2>&1) || status=$?
[ "$status" -eq 0 ] || fail 'Fedora virtualization verify mock must converge'
grep -Fq 'MODULE_RESULT=virtualization:verify:OK' <<< "$output" ||
    fail 'Fedora virtualization verify must execute the module contract'
VIRT_APPLY_TEST_SCRIPT="$TEST_DIR/virtualization-apply.sh"
sed '/^check_root$/d' "$ROOT_DIR/scripts/modules/virtualization/apply.sh" > \
    "$VIRT_APPLY_TEST_SCRIPT"
chmod +x "$VIRT_APPLY_TEST_SCRIPT"
status=0
output=$(env PATH="$BIN_DIR:$PATH" SHORIN_ROOT="$ROOT_DIR" \
    SHORIN_DISTRO=fedora SHORIN_MODE=install SHORIN_READ_ONLY=0 \
    TARGET_USER="$TARGET_USER" HOME_DIR="$HOME_DIR" \
    PACKAGE_SOURCE_DIR="$TEST_DIR/package-sources" \
    bash "$VIRT_APPLY_TEST_SCRIPT" 2>&1) || status=$?
[ "$status" -eq 0 ] || fail 'Fedora virtualization apply mock must converge'
grep -Fq 'Virtualization target converged.' <<< "$output" ||
    fail 'Fedora virtualization apply must execute the target implementation'

printf 'PASS: Fedora GRUB boundary, virtualization package contract, and NAS/Rime edge cases\n'
