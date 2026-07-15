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

# Check if /home is a mountpoint and is btrfs
if findmnt -n -o FSTYPE /home | grep -q "btrfs"; then
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
    log "/home is not a separate Btrfs volume. Skipping."
fi

if snapper list-configs | grep -q "^home "; then
    exe snapper -c home set-config "${SNAPPER_TARGET_SETTINGS[@]}"
fi

ensure_service_enabled snapper-cleanup.timer

# ------------------------------------------------------------------------------
# 3. Create Initial Safety Snapshots
# ------------------------------------------------------------------------------
section "Safety Net" "Creating Initial Snapshots"

# Snapshot Root
if snapper list-configs | grep -q "root "; then
    if snapper_snapshot_present root 'Before Shorin Setup'; then
        log "Snapshot already created."
    else
        log "Creating Root snapshot..."
        if exe snapper -c root create --description "Before Shorin Setup"; then
            success "Root snapshot created."
        else
            error "Failed to create Root snapshot."
            warn "Cannot proceed without a safety snapshot. Aborting."
            exit 1
        fi
    fi
fi

# Snapshot Home
if snapper list-configs | grep -q "home "; then
    if snapper_snapshot_present home 'Before Shorin Setup'; then
        log "Snapshot already created."
    else
        log "Creating Home snapshot..."
        if exe snapper -c home create --description "Before Shorin Setup"; then
            success "Home snapshot created."
        else
            error "Failed to create Home snapshot."
            # This is less critical than root, but should still be a failure.
            exit 1
        fi
    fi
fi

log "Module 00 completed. Safe to proceed."
