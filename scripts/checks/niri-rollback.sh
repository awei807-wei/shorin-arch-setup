#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR
# ==============================================================================
# Script: niri-undochange.sh
# Purpose: Emergency rollback to 'Before Niri Setup' checkpoint
# ==============================================================================

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/lib/snapshots.sh"

check_root

ASSUME_YES=false
case "${1:-}" in
    --yes) ASSUME_YES=true ;;
    '') ;;
    *) die 'Usage: sudo scripts/checks/niri-rollback.sh [--yes]' ;;
esac

warn "Critical error encountered during Niri setup."
log "Initiating system rollback to checkpoint: 'Before Desktop Environments'..."

snapshot_config_subvolume_matches root / ||
    die "Snapper config 'root' does not target /."
if snapshot_config_exists home; then
    snapshot_config_subvolume_matches home /home ||
        die "Snapper config 'home' does not target /home."
fi

# ------------------------------------------------------------------------------
# Function: Perform Rollback
# ------------------------------------------------------------------------------
perform_rollback() {
    local config="$1" snap_id="$2"

    log "Reverting changes in '$config' (Target Snapshot ID: $snap_id)..."
    if snapper -c "$config" undochange "$snap_id..0"; then
        success "Successfully reverted $config."
    else
        error "Failed to revert $config. Manual intervention required."
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Execution
# ------------------------------------------------------------------------------

# Resolve both sides before changing either one, so a missing Home checkpoint
# cannot leave the machine half reverted.
ROOT_SNAPSHOT_RECORD=$(snapshot_latest_record root \
    "Before Desktop Environments") ||
    die "Root checkpoint 'Before Desktop Environments' is not available."
IFS=$'\t' read -r ROOT_SNAPSHOT_ID SNAPSHOT_DESCRIPTION <<< \
    "$ROOT_SNAPSHOT_RECORD"
HOME_MODE=$(snapshot_description_home_mode "$SNAPSHOT_DESCRIPTION")
if [ "$HOME_MODE" = required ] ||
    { [ "$HOME_MODE" = legacy ] && snapshot_config_exists home; }; then
    snapshot_config_exists home ||
        die 'The selected desktop checkpoint requires the missing Home config.'
    ROOT_SNAPSHOT_RECORD=$(snapshot_latest_paired_record root home \
        "Before Desktop Environments") ||
        die 'No complete root/home desktop checkpoint pair is available.'
    IFS=$'\t' read -r ROOT_SNAPSHOT_ID SNAPSHOT_DESCRIPTION <<< \
        "$ROOT_SNAPSHOT_RECORD"
fi
HOME_SNAPSHOT_ID=""
if [ "$(snapshot_description_home_mode "$SNAPSHOT_DESCRIPTION")" != absent ] &&
    snapshot_config_exists home; then
    HOME_SNAPSHOT_ID=$(snapshot_latest_id home "$SNAPSHOT_DESCRIPTION") ||
        die "Home has no checkpoint paired with '$SNAPSHOT_DESCRIPTION'."
fi

if [ "$ASSUME_YES" != true ]; then
    [ -t 0 ] || die 'Refusing a non-interactive rollback without --yes.'
    read -r -p 'Rollback desktop changes from both checkpoints? [y/N]: ' answer
    [[ "$answer" =~ ^[Yy]$ ]] || { log 'Rollback cancelled.'; exit 0; }
fi

perform_rollback root "$ROOT_SNAPSHOT_ID"
[ -z "$HOME_SNAPSHOT_ID" ] || perform_rollback home "$HOME_SNAPSHOT_ID"

# Reboot after both filesystems have been reverted successfully.
echo ""
echo -e "${H_YELLOW}╔═════════════════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${H_YELLOW}║                                                                                     ║${NC}"
echo -e "${H_YELLOW}║   AFTER REBOOT: LOGIN AS YOUR ORIGINAL USER -> RUN install.sh AGAIN TO RETRY        ║${NC}"
echo -e "${H_YELLOW}║   AFTER REBOOT: LOGIN AS YOUR ORIGINAL USER -> RUN install.sh AGAIN TO RETRY        ║${NC}"
echo -e "${H_YELLOW}║   AFTER REBOOT: LOGIN AS YOUR ORIGINAL USER -> RUN install.sh AGAIN TO RETRY        ║${NC}"
echo -e "${H_YELLOW}║                                                                                     ║${NC}"
echo -e "${H_YELLOW}╚═════════════════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

for i in {10..1}; do
    echo -ne "\r   ${H_RED}Rebooting in ${i}s...${NC}"
    sleep 1
done

echo ""
systemctl reboot
