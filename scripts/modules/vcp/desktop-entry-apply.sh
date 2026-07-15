#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/modules/vcp/contract.sh"

check_root

TARGET_USER=${1:-${TARGET_USER:-}}
[ -n "$TARGET_USER" ] || die 'Unable to resolve the VCP desktop target user.'
if [ -z "${HOME_DIR:-}" ]; then
    HOME_DIR=$(getent passwd "$TARGET_USER" | cut -d: -f6)
fi
[ -d "$HOME_DIR" ] || die "Home directory not found: $HOME_DIR"
vcp_contract_init

[ -d "$VCP_DIR" ] && [ -f "$VCP_DIR/package.json" ] ||
    die "VCPChat is incomplete: $VCP_DIR"
[ -n "$VCP_NPM" ] && [ -x "$VCP_NPM" ] ||
    die 'An absolute npm executable is required for VCPChat.'

section "VCP Integration" "Desktop Application Entry"

install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" \
    "$(dirname "$VCP_DESKTOP_FILE")"
desktop_tmp=$(mktemp)
vcp_desktop_contract > "$desktop_tmp"
install_if_changed "$desktop_tmp" "$VCP_DESKTOP_FILE" 755
rm -f "$desktop_tmp"
chown "$TARGET_USER:" "$VCP_DESKTOP_FILE"
vcp_desktop_matches

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$VCP_DESKTOP_FILE"
fi
if [ -z "${CHROOT_ACTIVE:-}" ] &&
    command -v update-desktop-database >/dev/null 2>&1; then
    runuser -u "$TARGET_USER" -- \
        update-desktop-database "$(dirname "$VCP_DESKTOP_FILE")"
fi
