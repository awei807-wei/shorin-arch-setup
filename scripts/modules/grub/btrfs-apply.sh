#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/modules/grub/contract.sh"

check_root
grub_contract_init

grub_root_is_btrfs || exit 0
[ -f "$GRUB_DEFAULT_FILE" ] || die "Missing GRUB defaults: $GRUB_DEFAULT_FILE"
command -v grub-mkconfig >/dev/null 2>&1 || exit 0

ensure_packages grub-btrfs inotify-tools
ensure_service_started grub-btrfsd.service

if ! grub_overlay_hook_present; then
    tmp=$(mktemp)
    awk '
        /^HOOKS=/ && $0 !~ /grub-btrfs-overlayfs/ {
            sub(/\)$/, " grub-btrfs-overlayfs)")
        }
        { print }
    ' "$GRUB_MKINITCPIO_FILE" > "$tmp"
    grep -Fqw grub-btrfs-overlayfs "$tmp" || {
        rm -f "$tmp"
        die "Unable to add grub-btrfs-overlayfs to $GRUB_MKINITCPIO_FILE"
    }
    install_if_changed "$tmp" "$GRUB_MKINITCPIO_FILE" 644
    rm -f "$tmp"
    mkinitcpio -P
fi
grub_overlay_hook_present

tmp=$(mktemp "${GRUB_CONFIG_FILE}.XXXXXX")
grub-mkconfig -o "$tmp"
grub-script-check "$tmp"
install_if_changed "$tmp" "$GRUB_CONFIG_FILE" 600
rm -f "$tmp"
