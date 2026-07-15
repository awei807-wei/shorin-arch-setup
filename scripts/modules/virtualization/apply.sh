#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/core.sh"

check_root
[ -n "${TARGET_USER:-}" ] || die 'TARGET_USER is required.'

section Virtualization 'QEMU/KVM and libvirt'
ensure_packages qemu-full virt-manager swtpm dnsmasq
usermod -a -G libvirt,kvm,input "$TARGET_USER"
ensure_service_started libvirtd.service

glib-compile-schemas /usr/share/glib-2.0/schemas/
as_user gsettings set org.virt-manager.virt-manager.connections \
    uris "['qemu:///system']"
as_user gsettings set org.virt-manager.virt-manager.connections \
    autoconnect "['qemu:///system']"

if ! virsh net-info default >/dev/null 2>&1; then
    die 'libvirt default network is not defined.'
fi
virsh net-info default | grep -q '^Active:.*yes' || virsh net-start default
virsh net-info default | grep -q '^Autostart:.*yes' || virsh net-autostart default

success 'Virtualization target converged.'
