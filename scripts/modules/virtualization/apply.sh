#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/core.sh"
source "$SHORIN_ROOT/scripts/modules/virtualization/contract.sh"

check_root
[ -n "${TARGET_USER:-}" ] || die 'TARGET_USER is required.'

section Virtualization 'QEMU/KVM and libvirt'
ensure_packages "${VIRTUALIZATION_PACKAGES[@]}"
for command in "${VIRTUALIZATION_COMMANDS[@]}"; do
    command -v "$command" >/dev/null 2>&1 ||
        die "Required virtualization command is unavailable: $command"
done
usermod -a -G libvirt,kvm,input "$TARGET_USER"
ensure_virtualization_provider
ensure_virtualization_default_network

glib-compile-schemas /usr/share/glib-2.0/schemas/
ensure_virtualization_gsetting "$TARGET_USER" "$HOME_DIR" \
    uris "['qemu:///system']"
ensure_virtualization_gsetting "$TARGET_USER" "$HOME_DIR" \
    autoconnect "['qemu:///system']"
virtualization_provider_ready

success 'Virtualization target converged.'
