#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# 03c-snapshot-before-desktop.sh
# Creates a system snapshot before installing major Desktop Environments.
# ==============================================================================

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"

# 2. 权限检查
check_root

section "Phase 3c" "System Snapshot"

# ==============================================================================

create_checkpoint() {
    local has_home=0
    snapshot_config_subvolume_matches home /home && has_home=1
    local MARKER="Before Desktop Environments [run:${SHORIN_RUN_TOKEN:-$$};home:$has_home]"
    local root_fstype

    root_fstype=$(findmnt -n -o FSTYPE /)
    if [ "$root_fstype" != btrfs ]; then
        log "Root is not Btrfs; the snapshot target is not applicable."
        return 0
    fi
    
    # 0. 检查 snapper 是否安装
    if ! command -v snapper &>/dev/null; then
        error "Snapper tool not found; desktop safety checkpoint is required."
        return 1
    fi

    # 1. Root 分区快照
    # 检查 root 配置是否存在
    if snapper -c root get-config &>/dev/null; then
        log "Creating a fresh safety checkpoint on [root]..."
        snapper -c root create --description "$MARKER"
        success "Root snapshot created."
    else
        error "Snapper root config is missing; cannot create the required checkpoint."
        return 1
    fi

    # 2. Home 分区快照 (如果存在 home 配置)
    if snapper -c home get-config &>/dev/null; then
        log "Creating a fresh safety checkpoint on [home]..."
        snapper -c home create --description "$MARKER"
        success "Home snapshot created."
    fi
}

# ==============================================================================
# 执行
# ==============================================================================

log "Preparing to create restore point..."
create_checkpoint

log "Module 03c completed."
