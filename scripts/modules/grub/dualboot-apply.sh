#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# Script: 02a-dualboot-fix.sh
# Purpose: Auto-configure for Windows dual-boot (OS-Prober only).
# ==============================================================================

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/modules/grub/contract.sh"

check_root
grub_contract_init

# --- GRUB Installation Check ---
if ! command -v grub-mkconfig &>/dev/null; then
    warn "GRUB is not detected. Skipping dual-boot configuration."
    exit 0
fi
[ -f "$GRUB_DEFAULT_FILE" ] || die "Missing GRUB defaults: $GRUB_DEFAULT_FILE"

# --- Helper Functions ---

# Sets a GRUB key-value pair.
set_grub_value() {
    local key="$1"
    local value="$2"
    local conf_file="$GRUB_DEFAULT_FILE"

    ensure_key_value "$conf_file" "$key" "\"$value\""
}

regenerate_grub() {
    local output=$GRUB_CONFIG_FILE
    local tmp

    tmp=$(mktemp "${output}.XXXXXX")
    grub-mkconfig -o "$tmp"
    grub-script-check "$tmp"
    install_if_changed "$tmp" "$output" 600
    rm -f "$tmp"
}

# --- Main Script ---

section "Phase 2A" "Dual-Boot Configuration (Windows)"

# ------------------------------------------------------------------------------
# 1. Detect Windows
# ------------------------------------------------------------------------------
section "Step 1/2" "System Analysis"

log "Installing dual-boot detection tools (os-prober, exfatprogs)..."
ensure_packages os-prober exfatprogs

# --- Check if already configured ---
OS_PROBER_CONFIGURED=$(grep -q -E '^\s*GRUB_DISABLE_OS_PROBER\s*=\s*(false|"false")' "$GRUB_DEFAULT_FILE" && echo "true" || echo "false")

if [ "$OS_PROBER_CONFIGURED" == "true" ]; then
    log "Dual-boot settings seem to be already configured."
    echo ""
    echo -e "   ${H_YELLOW}>>> It looks like your dual-boot is already set up.${NC}"
    echo ""
fi

# ------------------------------------------------------------------------------
# 2. Configure GRUB for Dual-Boot
# ------------------------------------------------------------------------------
section "Step 2/2" "Enabling OS Prober"

log "Enabling OS prober to detect Windows..."
set_grub_value "GRUB_DISABLE_OS_PROBER" "false"

success "Dual-boot settings updated."

log "Regenerating GRUB configuration..."
if regenerate_grub; then
    success "GRUB configuration regenerated successfully."
else
    error "Failed to regenerate GRUB configuration."
    exit 1
fi

log "Module 02a completed."
