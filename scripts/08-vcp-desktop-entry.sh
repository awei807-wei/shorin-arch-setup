#!/bin/bash
# 08-vcp-desktop-entry.sh - VCPChat Desktop Entry Integration
# (v1.0 - Automatic Path Detection & Database Refresh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-utils.sh"

check_root

# --- [CONFIG] ---
TARGET_USER="${1:-$(logname 2>/dev/null || awk -F: '$3 == 1000 {print $1}' /etc/passwd | head -n1)}"
HOME_DIR="/home/$TARGET_USER"
VCP_DIR="$HOME_DIR/Downloads/VCPChat"
DESKTOP_FILE="$HOME_DIR/.local/share/applications/vchat.desktop"

section "VCP Integration" "Desktop Application Entry"

# 1. Check VCP directory
if [ ! -d "$VCP_DIR" ]; then
    warn "VCPChat directory not found at $VCP_DIR"
    log "Skipping desktop entry creation."
    exit 0
fi

# 2. Create local applications directory
as_user mkdir -p "$HOME_DIR/.local/share/applications"

# 3. Write .desktop file
log "Creating desktop entry: $DESKTOP_FILE"
as_user cat > "$DESKTOP_FILE" <<INNER_EOF
[Desktop Entry]
Name=VCPChat
Comment=Start VCPChat Environment
Exec=env WAYLAND_DISPLAY=wayland-1 npm start --prefix $VCP_DIR -- --ozone-platform=wayland --enable-features=WaylandWindowDecorations
Icon=utilities-terminal
Terminal=false
Type=Application
Categories=Development;
Keywords=vchat;vcp;npm;
INNER_EOF

# 4. Set permissions and refresh database
chmod +x "$DESKTOP_FILE"
if [ -z "${CHROOT_ACTIVE:-}" ]; then
    log "Refreshing desktop database..."
    as_user update-desktop-database "$HOME_DIR/.local/share/applications"
fi

success "VCPChat desktop entry is now available in Vicinae/Fuzzel!"
