#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# 00-btrfs-init.sh - Pre-install Snapshot Safety Net (Root & Home)
# ==============================================================================

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/modules/storage/targets.sh"

check_root

section "Phase 0" "System Snapshot Initialization"

# ------------------------------------------------------------------------------
# 1. Configure Root (/)
# ------------------------------------------------------------------------------
log "Checking Root filesystem..."
ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)

if [ "$ROOT_FSTYPE" == "btrfs" ]; then
    log "Root is Btrfs. Installing Snapper..."
    # Minimal install for snapshot capability
    ensure_packages "${STORAGE_PACKAGES[@]}"
    
    log "Configuring Snapper for Root..."
    if ! snapper list-configs | grep -q "^root "; then
        # Cleanup existing dir to allow subvolume creation
        if [ -d "/.snapshots" ]; then
            error "Refusing to remove existing /.snapshots without a Snapper config."
            exit 1
        fi
        
        if exe snapper -c root create-config /; then
            success "Config 'root' created."
            
        fi
    else
        log "Config 'root' already exists."
    fi
    snapper -c root get-config >/dev/null
    snapshot_config_subvolume_matches root / ||
        die "Snapper config 'root' does not target /."
else
    warn "Root is not Btrfs. Skipping Root snapshot."
fi

if snapper list-configs | grep -q "^root "; then
    exe snapper -c root set-config "${SNAPPER_TARGET_SETTINGS[@]}"
fi

# ------------------------------------------------------------------------------
# 2. Configure Home (/home)
# ------------------------------------------------------------------------------
log "Checking Home filesystem..."

# Snapper needs /home itself to be a Btrfs subvolume, not merely a directory on
# the Btrfs root filesystem.
if storage_home_is_btrfs; then
    log "Home is Btrfs. Configuring Snapper for Home..."
    
    if ! snapper list-configs | grep -q "^home "; then
        # Cleanup .snapshots in home if exists
        if [ -d "/home/.snapshots" ]; then
            error "Refusing to remove existing /home/.snapshots without a Snapper config."
            exit 1
        fi
        
        if exe snapper -c home create-config /home; then
            success "Config 'home' created."
            
        fi
    else
        log "Config 'home' already exists."
    fi
else
    if snapper list-configs | grep -q "^home "; then
        die "Snapper config 'home' exists but /home is not a Btrfs subvolume."
    fi
    log "/home is not a Btrfs subvolume. Skipping."
fi

if snapper list-configs | grep -q "^home "; then
    snapshot_config_subvolume_matches home /home ||
        die "Snapper config 'home' does not target /home."
    exe snapper -c home set-config "${SNAPPER_TARGET_SETTINGS[@]}"
fi

ensure_service_enabled snapper-cleanup.timer

# ------------------------------------------------------------------------------
# 3. Create Initial Safety Snapshots
# ------------------------------------------------------------------------------
section "Safety Net" "Creating Initial Snapshots"
SNAPSHOT_HAS_HOME=0
snapshot_config_subvolume_matches home /home && SNAPSHOT_HAS_HOME=1
SNAPSHOT_DESCRIPTION="Before Shorin Setup [run:${SHORIN_RUN_TOKEN:-$$};home:$SNAPSHOT_HAS_HOME]"

# Snapshot Root
if snapper list-configs | grep -q "root "; then
    log "Creating a fresh Root snapshot for this run..."
    if exe snapper -c root create --cleanup-algorithm number \
        --description "$SNAPSHOT_DESCRIPTION"; then
        success "Root snapshot created."
    else
        error "Failed to create Root snapshot."
        warn "Cannot proceed without a safety snapshot. Aborting."
        exit 1
    fi
fi

# Snapshot Home
if snapper list-configs | grep -q "home "; then
    log "Creating a fresh Home snapshot for this run..."
    if exe snapper -c home create --cleanup-algorithm number \
        --description "$SNAPSHOT_DESCRIPTION"; then
        success "Home snapshot created."
    else
        error "Failed to create Home snapshot."
        exit 1
    fi
fi

touch "$(storage_run_snapshot_stamp)"

log "Module 00 completed. Safe to proceed."
