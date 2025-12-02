#!/bin/bash

# ==============================================================================
# 07-grub-theme.sh - GRUB Bootloader Theming (Dynamic)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

check_root

section "Phase 7" "GRUB Theme Customization"

# ------------------------------------------------------------------------------
# 1. Detect Theme
# ------------------------------------------------------------------------------
log "Detecting theme in 'grub-themes' folder..."

SOURCE_BASE="$PARENT_DIR/grub-themes"
DEST_DIR="/boot/grub/themes"

# Check if source base exists
if [ ! -d "$SOURCE_BASE" ]; then
    error "Directory 'grub-themes' not found in repo root."
    exit 1
fi

# Find the first directory inside grub-themes
# This allows the user to drop ANY theme folder named anything
THEME_SOURCE=$(find "$SOURCE_BASE" -mindepth 1 -maxdepth 1 -type d | head -n 1)

if [ -z "$THEME_SOURCE" ]; then
    error "No theme folder found inside '$SOURCE_BASE'."
    warn "Please put a theme folder (containing theme.txt) into 'grub-themes/'."
    exit 1
fi

THEME_NAME=$(basename "$THEME_SOURCE")
info_kv "Detected Theme" "$THEME_NAME"

# Verify theme structure
if [ ! -f "$THEME_SOURCE/theme.txt" ]; then
    error "Invalid theme: 'theme.txt' not found in '$THEME_NAME'."
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. Install Theme Files
# ------------------------------------------------------------------------------
log "Installing theme files..."

# Ensure destination exists
if [ ! -d "$DEST_DIR" ]; then
    exe mkdir -p "$DEST_DIR"
fi

# Remove old theme if it has the same name to ensure clean update
if [ -d "$DEST_DIR/$THEME_NAME" ]; then
    log "Removing existing version of $THEME_NAME..."
    exe rm -rf "$DEST_DIR/$THEME_NAME"
fi

# Copy theme
exe cp -r "$THEME_SOURCE" "$DEST_DIR/"

if [ -f "$DEST_DIR/$THEME_NAME/theme.txt" ]; then
    success "Theme installed to $DEST_DIR/$THEME_NAME"
else
    error "Failed to copy theme files."
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Configure /etc/default/grub
# ------------------------------------------------------------------------------
log "Configuring GRUB settings..."

GRUB_CONF="/etc/default/grub"
THEME_PATH="$DEST_DIR/$THEME_NAME/theme.txt"

if [ -f "$GRUB_CONF" ]; then
    # Update or Append GRUB_THEME
    if grep -q "^GRUB_THEME=" "$GRUB_CONF"; then
        log "Updating existing GRUB_THEME entry..."
        # Use a different delimiter (#) for sed to avoid slashing issues with paths
        exe sed -i "s|^GRUB_THEME=.*|GRUB_THEME=\"$THEME_PATH\"|" "$GRUB_CONF"
    else
        log "Adding GRUB_THEME entry..."
        # Append to end of file
        echo "GRUB_THEME=\"$THEME_PATH\"" >> "$GRUB_CONF"
        success "Added GRUB_THEME variable."
    fi
    
    # Enable graphical output (Comment out console output)
    if grep -q "^GRUB_TERMINAL_OUTPUT=\"console\"" "$GRUB_CONF"; then
        log "Enabling graphical terminal output..."
        exe sed -i 's/^GRUB_TERMINAL_OUTPUT="console"/#GRUB_TERMINAL_OUTPUT="console"/' "$GRUB_CONF"
    fi
    
    # Optional: Ensure GRUB_GFXMODE is set to auto or a high resolution if not set
    if ! grep -q "^GRUB_GFXMODE=" "$GRUB_CONF"; then
        echo 'GRUB_GFXMODE=auto' >> "$GRUB_CONF"
    fi
    
    success "Configuration updated."
else
    error "$GRUB_CONF not found."
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Apply Changes
# ------------------------------------------------------------------------------
log "Generating new GRUB configuration..."

# The output path was fixed in 02-musthave.sh (symlink), so /boot/grub/grub.cfg is safe
if exe grub-mkconfig -o /boot/grub/grub.cfg; then
    success "GRUB updated successfully."
else
    error "Failed to update GRUB."
    # Non-fatal for script execution, but user should know
fi

log "Module 07 completed."