#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"

check_root

[ "$(findmnt -n -o FSTYPE / 2>/dev/null)" = btrfs ] || exit 0
[ -f /etc/default/grub ] || exit 0
command -v grub-mkconfig >/dev/null 2>&1 || exit 0

ensure_packages grub-btrfs inotify-tools
ensure_service_started grub-btrfsd.service

if ! grep -Fqw grub-btrfs-overlayfs /etc/mkinitcpio.conf; then
    tmp=$(mktemp)
    awk '
        /^HOOKS=/ && $0 !~ /grub-btrfs-overlayfs/ {
            sub(/\)$/, " grub-btrfs-overlayfs)")
        }
        { print }
    ' /etc/mkinitcpio.conf > "$tmp"
    install_if_changed "$tmp" /etc/mkinitcpio.conf 644
    rm -f "$tmp"
    mkinitcpio -P
fi

tmp=$(mktemp /boot/grub/grub.cfg.XXXXXX)
grub-mkconfig -o "$tmp"
grub-script-check "$tmp"
install_if_changed "$tmp" /boot/grub/grub.cfg 600
rm -f "$tmp"
