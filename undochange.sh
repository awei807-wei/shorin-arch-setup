#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# undochange.sh - Emergency System Rollback Tool (Silent Mode)
# ==============================================================================
# Usage: sudo ./undochange.sh [--yes]
# Description: Reverts system to the latest "Before Shorin Setup" checkpoint.
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/scripts/lib/snapshots.sh"

# 1. Check Root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root (sudo ./undochange.sh)${NC}"
    exit 1
fi

echo -e "${YELLOW}>>> Searching for safety snapshots...${NC}"

ASSUME_YES=false
case "${1:-}" in
    --yes) ASSUME_YES=true ;;
    '') ;;
    *) echo "Usage: sudo ./undochange.sh [--yes]" >&2; exit 64 ;;
esac

# 2. Find Root Snapshot ID
if ! command -v snapper &> /dev/null; then
    echo -e "${RED}Error: Snapper is not installed.${NC}"
    exit 1
fi
snapshot_config_subvolume_matches root / || {
    echo -e "${RED}Critical: Snapper config 'root' does not target /.${NC}"
    exit 1
}
if snapshot_config_exists home; then
    snapshot_config_subvolume_matches home /home || {
        echo -e "${RED}Critical: Snapper config 'home' does not target /home.${NC}"
        exit 1
    }
fi

ROOT_RECORD=$(snapshot_latest_record root "Before Shorin Setup") || {
    echo -e "${RED}Critical: Could not find a usable 'Before Shorin Setup' root snapshot.${NC}"
    exit 1
}
IFS=$'\t' read -r ROOT_ID SNAPSHOT_DESCRIPTION <<< "$ROOT_RECORD"
HOME_MODE=$(snapshot_description_home_mode "$SNAPSHOT_DESCRIPTION")
if [ "$HOME_MODE" = required ] ||
    { [ "$HOME_MODE" = legacy ] && snapshot_config_exists home; }; then
    snapshot_config_exists home || {
        echo -e "${RED}Critical: The selected snapshot requires the missing Home config.${NC}"
        exit 1
    }
    ROOT_RECORD=$(snapshot_latest_paired_record root home "Before Shorin Setup") || {
        echo -e "${RED}Critical: No complete root/home snapshot pair is available.${NC}"
        exit 1
    }
    IFS=$'\t' read -r ROOT_ID SNAPSHOT_DESCRIPTION <<< "$ROOT_RECORD"
fi

echo -e "Found Root Snapshot ID: ${GREEN}$ROOT_ID${NC}"

# 3. Find Home Snapshot ID (Optional)
HOME_ID=""
if [ "$(snapshot_description_home_mode "$SNAPSHOT_DESCRIPTION")" != absent ] &&
    snapshot_config_exists home; then
    HOME_ID=$(snapshot_latest_id home "$SNAPSHOT_DESCRIPTION") || {
        echo -e "${RED}Critical: Home has no snapshot paired with '$SNAPSHOT_DESCRIPTION'; no changes were made.${NC}"
        exit 1
    }
    echo -e "Found Home Snapshot ID: ${GREEN}$HOME_ID${NC}"
fi

# 4. Execute Rollback
if [ "$ASSUME_YES" != true ]; then
    [ -t 0 ] || {
        echo "Refusing a non-interactive rollback without --yes." >&2
        exit 64
    }
    read -r -p "Rollback all changes since these snapshots? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Rollback cancelled."; exit 0; }
fi

# Rollback Root
echo -e "${YELLOW}Reverting / (Root)...${NC}"
# undochange ID..0 means: Change from ID to Current(0) state (Revert)
snapper -c root undochange "$ROOT_ID..0"

# Rollback Home
if [ -n "$HOME_ID" ]; then
    echo -e "${YELLOW}Reverting /home...${NC}"
    snapper -c home undochange "$HOME_ID..0"
fi

echo -e "${GREEN}Rollback complete. Rebooting...${NC}"
sleep 2
reboot
