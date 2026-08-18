#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SHORIN_DISTRO=fedora
TEST_DIR=$(mktemp -d)
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

export SHORIN_DISTRO=fedora SHORIN_READ_ONLY=0
TARGET_USER=$(id -un)
export TARGET_USER HOME_DIR="$TEST_DIR/home"
export FEDORA_RPM_DIR="$TEST_DIR/rpms"
mkdir -p "$HOME_DIR" "$FEDORA_RPM_DIR"

source "$ROOT_DIR/scripts/lib/core.sh"

[ "$SHORIN_DISTRO" = fedora ] || fail 'Fedora override was not detected'
[ "$(fedora_arch_target_name qemu-full)" = qemu-kvm ] ||
    fail 'qemu-full must map to Fedora qemu-kvm'
[ "$(fedora_arch_target_name AUR:swaylock-effects)" = swaylock ] ||
    fail 'swaylock-effects must map to Fedora swaylock'
for package in bluez fzf glibc-langpack-zh nfs-utils tsukimi unzip util-linux; do
    [ "$(fedora_arch_target_name "$package")" = "$package" ] ||
        fail "Fedora package mapping is missing: $package"
done
[ "$(fedora_arch_target_name openal)" = openal-soft ] ||
    fail 'Arch openal must map to Fedora openal-soft'
[ "$(fedora_arch_target_name lib32-openal)" = openal-soft.i686 ] ||
    fail 'Arch lib32-openal must map to Fedora openal-soft.i686'
[ "$(fedora_arch_target_name openal-soft)" = openal-soft ] ||
    fail 'Fedora package mapping is missing: openal-soft'
[ "$(fedora_arch_target_name openal-soft.i686)" = openal-soft.i686 ] ||
    fail 'Fedora package mapping is missing: openal-soft.i686'
for package in liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts; do
    [ "$(fedora_arch_target_name "$package")" = "$package" ] ||
        fail "Fedora package mapping is missing: $package"
done
if fedora_arch_target_name liberation-fonts >/dev/null 2>&1; then
    fail 'Fedora must reject the nonexistent liberation-fonts package'
fi
if fedora_arch_target_name ttf-liberation >/dev/null 2>&1; then
    fail 'Fedora must keep the Arch-only ttf-liberation spelling out of DNF'
fi
[ "$(fedora_arch_target_name openal)" != openal ] ||
    fail 'Fedora must not pass the nonexistent openal package to dnf'

declare -Ag OPENAL_RPM_INSTALLED=()
OPENAL_RPM_INSTALLED[openal-soft]=1
OPENAL_RPM_INSTALLED[openal-soft.i686]=1
rpm() {
    [ "${1:-}" = -q ] || return 2
    [ "${OPENAL_RPM_INSTALLED[${2:-}]:-0}" -eq 1 ]
}
package_is_installed openal ||
    fail 'Fedora package_is_installed must accept openal-soft'
package_is_installed lib32-openal ||
    fail 'Fedora package_is_installed must accept openal-soft.i686'
OPENAL_RPM_INSTALLED[openal-soft.i686]=0
package_is_installed lib32-openal &&
    fail 'Missing Fedora openal-soft.i686 must be reported as drift'
OPENAL_RPM_INSTALLED[openal-soft.i686]=1
OPENAL_RPM_INSTALLED[openal-soft]=0
package_is_installed openal &&
    fail 'Missing Fedora openal-soft must be reported as drift'
OPENAL_RPM_INSTALLED[openal-soft]=1

OPENAL_DNF_QUERY=openal-soft.i686
OPENAL_DNF_ARGS_FILE="$TEST_DIR/openal-dnf-args"
dnf() {
    printf '%s\n' "$*" > "$OPENAL_DNF_ARGS_FILE"
    [ "${1:-}" = repoquery ] || return 1
    printf '%s\n' "$OPENAL_DNF_QUERY"
}
platform_dnf_package_available openal-soft.i686 ||
    fail 'Fedora package availability must detect the i686 OpenAL package'
OPENAL_DNF_ARGS=$(< "$OPENAL_DNF_ARGS_FILE")
[[ "$OPENAL_DNF_ARGS" == *'--qf %{name}.%{arch}'* ]] ||
    fail 'Fedora i686 package query must include the package architecture'
OPENAL_DNF_QUERY=''
platform_dnf_package_available openal-soft.i686 &&
    fail 'Empty Fedora i686 package query must report drift'

for package in libvirt-daemon libvirt-daemon-kvm libvirt-client \
    libvirt-daemon-config-network librime-tools; do
    [ "$(fedora_arch_target_name "$package")" = "$package" ] ||
        fail "Fedora package mapping is missing: $package"
done

source "$ROOT_DIR/scripts/modules/virtualization/contract.sh"
source "$ROOT_DIR/scripts/modules/nas-rime/contract.sh"
[ "${VIRTUALIZATION_SERVICE:-}" = libvirtd.service ] ||
    fail 'Fedora virtualization contract must declare libvirtd.service'
grep -Fqx virsh <<< "${VIRTUALIZATION_COMMANDS[*]}" ||
    fail 'Fedora virtualization contract must declare virsh'
for group in libvirt kvm input; do
    found=0
    for actual in "${VIRTUALIZATION_GROUPS[@]}"; do
        [ "$actual" = "$group" ] && found=1
    done
    [ "$found" -eq 1 ] || fail "Virtualization contract is missing group: $group"
done
for package in libvirt-daemon libvirt-daemon-kvm libvirt-client \
    libvirt-daemon-config-network; do
    found=0
    for actual in "${VIRTUALIZATION_PACKAGES[@]}"; do
        [ "$actual" = "$package" ] && found=1
    done
    [ "$found" -eq 1 ] ||
        fail "Fedora virtualization contract is missing package: $package"
done
for actual in "${VIRTUALIZATION_PACKAGES[@]}"; do
    [ "$actual" != bridge-utils ] ||
        fail 'Fedora virtualization contract must not add deprecated bridge-utils'
done
[ "$VIRTUALIZATION_DEFAULT_NETWORK_XML" = \
    /usr/share/libvirt/networks/default.xml ] ||
    fail 'Virtualization contract must declare the libvirt default network artifact'

RUNNER_MODULE_DIR="$TEST_DIR/modules"
mkdir -p "$RUNNER_MODULE_DIR"
cat > "$RUNNER_MODULE_DIR/fixture.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[ "${SHORIN_DISTRO:-}" = fedora ] || exit 1
printf 'fixture-distro=%s\n' "$SHORIN_DISTRO"
exit 0
EOF
chmod +x "$RUNNER_MODULE_DIR/fixture.sh"
MODULES_PATH="$RUNNER_MODULE_DIR"
RUNNER_OUTPUT=$(run_module_phase fixture check)
grep -Fqx 'fixture-distro=fedora' <<< "$RUNNER_OUTPUT" ||
    fail 'runner must propagate explicit Fedora selection to child modules'
[ "$PHASE_RC" -eq 0 ] || fail 'propagated Fedora fixture must complete successfully'
for package in yay paru archlinuxcn-keyring lib32-mesa; do
    if fedora_arch_target_name "$package" >/dev/null 2>&1; then
        fail "Arch-only package must not be translated to Fedora dnf: $package"
    fi
done

CALLS="$TEST_DIR/calls.log"
: > "$CALLS"
require_writable_mode() { return 0; }
ensure_flatpak() { printf 'flatpak:%s\n' "$1" >> "$CALLS"; }
ensure_packages() { printf 'packages:%s\n' "$*" >> "$CALLS"; }
ensure_package() { printf 'package:%s\n' "$1" >> "$CALLS"; }
dnf() { printf 'dnf:%s\n' "$*" >> "$CALLS"; return 0; }
fedora_install_local_rpm() { printf 'rpm:%s:%s\n' "$1" "$2" >> "$CALLS"; return 0; }
fedora_install_fd_rdd() { printf 'fd-rdd:%s\n' "$1" >> "$CALLS"; return 0; }
fedora_install_vicinae() { printf 'vicinae:%s\n' "$1" >> "$CALLS"; return 0; }
declare -A FEDORA_SATISFACTION_CHECKS=()
fedora_application_target_satisfied() {
    case "$1" in
        clash-verge-rev|linuxqq-appimage|wechat-appimage|lsfg-vk-bin|tsukimi-bin|thorium-browser-bin|mark-shot)
            if [ "${FEDORA_SATISFACTION_CHECKS[$1]:-0}" -eq 0 ]; then
                FEDORA_SATISFACTION_CHECKS[$1]=1
                return 1
            fi
            return 0 ;;
        *) return 1 ;;
    esac
}

export FEDORA_WECHAT_SHA256=0000000000000000000000000000000000000000000000000000000000000000
export FEDORA_THORIUM_SHA256=0000000000000000000000000000000000000000000000000000000000000000
for target in heroic-games-launcher-bin upscaler mangojuice-bin; do
    fedora_install_application_target "$target" "$TARGET_USER" "$HOME_DIR"
done
fedora_install_application_target clash-verge-rev "$TARGET_USER" "$HOME_DIR"
fedora_install_application_target linuxqq-appimage "$TARGET_USER" "$HOME_DIR"
status=0
fedora_install_application_target wechat-appimage "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -eq "$RC_SKIPPED" ] ||
    fail 'WeChat without a local RPM must remain pending even with an explicit SHA'
fedora_install_application_target lsfg-vk-bin "$TARGET_USER" "$HOME_DIR"
fedora_install_application_target vicinae-bin "$TARGET_USER" "$HOME_DIR"
fedora_install_application_target fd-rdd-git "$TARGET_USER" "$HOME_DIR"
fedora_install_application_target tsukimi-bin "$TARGET_USER" "$HOME_DIR"
status=0
fedora_install_application_target thorium-browser-bin "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -eq "$RC_SKIPPED" ] ||
    fail 'Thorium without a local RPM must remain pending even with an explicit SHA'
fedora_install_application_target mark-shot "$TARGET_USER" "$HOME_DIR"

grep -Fqx 'flatpak:com.heroicgameslauncher.hgl' "$CALLS" ||
    fail 'Heroic must use its Flathub app id'
grep -Fqx 'flatpak:io.gitlab.theevilskeleton.Upscaler' "$CALLS" ||
    fail 'Upscaler must use its Flathub app id'
grep -Fqx 'flatpak:io.github.radiolamp.mangojuice' "$CALLS" ||
    fail 'MangoJuice must use its Flathub app id'
grep -Fqx 'rpm:Clash Verge:Clash.Verge-*.rpm' "$CALLS" ||
    fail 'Clash Verge must use an official RPM glob'
grep -Fqx 'rpm:Linux QQ:QQ_*.rpm' "$CALLS" ||
    fail 'Linux QQ must use the fixed official QQ RPM glob'
! grep -Fq 'rpm:WeChat Linux:' "$CALLS" ||
    fail 'WeChat must not use the unverified local RPM installer'
grep -Fqx 'packages:qt6-qtdeclarative qt6-qtbase' "$CALLS" ||
    fail 'lsfg-vk must install both Qt6 dependencies first'
grep -Fqx 'dnf:copr enable -y walker874/tsukimi' "$CALLS" ||
    fail 'tsukimi must enable the required COPR'
! grep -Eq 'yay|paru|pacman' "$CALLS" ||
    fail 'Fedora application path must not invoke AUR tooling'

FAIL_ON=0
unset -f ensure_packages
source "$ROOT_DIR/scripts/lib/packages.sh"
ensure_package() {
    FAIL_ON=$((FAIL_ON + 1))
    return 1
}
if ensure_packages first second; then
    fail 'ensure_packages must propagate Fedora package failures'
fi
[ "$FAIL_ON" -eq 1 ] || fail 'ensure_packages must stop after the first failed package'

unset -f ensure_package
source "$ROOT_DIR/scripts/lib/packages.sh"

declare -Ag FEDORA_CONTRACT_INSTALLED=()
package_is_installed() {
    local mapped
    mapped=$(fedora_arch_target_name "$1") || return 1
    [ "${FEDORA_CONTRACT_INSTALLED[$mapped]:-0}" -eq 1 ]
}
dnf() {
    printf 'dnf:%s\n' "$*" >> "$CALLS"
    FEDORA_CONTRACT_INSTALLED["${!#}"]=1
}
record_package_source() { :; }
for logical_package in "${VIRTUALIZATION_PACKAGES[@]}" "${RIME_REQUIRED_PACKAGES[@]}"; do
    ensure_package "$logical_package" ||
        fail "Fedora contract package did not converge in mock: $logical_package"
done
for expected_package in qemu-kvm virt-manager swtpm dnsmasq dbus \
    libvirt-daemon libvirt-daemon-kvm libvirt-client \
    libvirt-daemon-config-network librime-tools; do
    grep -Fq "dnf:install -y --setopt=install_weak_deps=False $expected_package" \
        "$CALLS" || fail "dnf did not receive Fedora package: $expected_package"
done
! grep -Fq bridge-utils "$CALLS" ||
    fail 'mock Fedora dnf calls must not include deprecated bridge-utils'

BEFORE=$(sha256sum "$ROOT_DIR/common-applist.txt" | awk '{print $1}')
EXPECTED_COMMON_HASH=233c7908cab663fe4cbe0c96323c1bd6b1a4286c80a19051532bee60de6cbebc
[ "$BEFORE" = "$EXPECTED_COMMON_HASH" ] ||
    fail "common-applist.txt baseline hash changed unexpectedly: $BEFORE"
AFTER=$(sha256sum "$ROOT_DIR/common-applist.txt" | awk '{print $1}')
[ "$BEFORE" = "$AFTER" ] || fail 'common-applist.txt changed during Fedora contract test'

printf 'PASS: Fedora mapping and package-source contract\n'
