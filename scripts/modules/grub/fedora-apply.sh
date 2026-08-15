#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/modules/grub/contract.sh"

check_root
grub_contract_init

ensure_packages grub2-tools os-prober exfatprogs
[ -f "$GRUB_DEFAULT_FILE" ] || die "Missing GRUB defaults: $GRUB_DEFAULT_FILE"

ensure_key_value "$GRUB_DEFAULT_FILE" GRUB_DISABLE_OS_PROBER '"false"'
generator=$(grub_config_generator) || die 'Fedora GRUB generator is unavailable.'
checker=$(grub_config_checker) || die 'Fedora GRUB checker is unavailable.'
install -d -m 755 "$(dirname "$GRUB_CONFIG_FILE")"
temporary=$(mktemp "${GRUB_CONFIG_FILE}.XXXXXX")
if ! "$generator" -o "$temporary"; then
    rm -f "$temporary"
    die 'Fedora GRUB configuration generation failed.'
fi
if ! "$checker" "$temporary"; then
    rm -f "$temporary"
    die 'Generated Fedora GRUB configuration failed validation.'
fi
install_if_changed "$temporary" "$GRUB_CONFIG_FILE" 600
rm -f "$temporary"

success 'Fedora GRUB configuration converged without mkinitcpio or grub-btrfs.'
