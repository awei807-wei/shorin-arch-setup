#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
TARGET_USER=$(id -un)
HOME_DIR=$TEST_DIR/home
SHORIN_ROOT=$ROOT_DIR
SHORIN_MODE=repair
SHORIN_READ_ONLY=0
export TARGET_USER HOME_DIR SHORIN_ROOT SHORIN_MODE SHORIN_READ_ONLY

cleanup() {
    find "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

source "$ROOT_DIR/scripts/modules/desktop-niri/targets.sh"

LIST_FILE="$TEST_DIR/niri-applist.txt"
MANIFEST="$TEST_DIR/niri-packages.list"
printf 'waybar\n' > "$LIST_FILE"
printf '%s\n' imv AUR:matugen waybar \
    AUR:waybar-niri-taskbar-git \
    AUR:waybar-module-pacman-updates-git > "$MANIFEST"

mapfile -t TARGETS < <(niri_all_package_targets "$MANIFEST" "$LIST_FILE")
for REQUIRED_TARGET in quickshell qt6-wayland matugen awww swayidle \
    swaylock-effects; do
    printf '%s\n' "${TARGETS[@]}" | grep -Fqx "$REQUIRED_TARGET" ||
        fail "an old manifest must not mask required target $REQUIRED_TARGET"
done
printf '%s\n' "${TARGETS[@]}" | grep -Fqx imv ||
    fail 'saved optional package choices must be preserved'
printf '%s\n' "${TARGETS[@]}" | grep -Fqx matugen ||
    fail 'the required repository source must win over a stale AUR declaration'
if printf '%s\n' "${TARGETS[@]}" | grep -Fqx AUR:matugen; then
    fail 'a stale source declaration must not duplicate a required package'
fi
if printf '%s\n' "${TARGETS[@]}" | grep -Fqx waybar; then
    fail 'a legacy Waybar target must be retired when QuickShell is required'
fi
for RETIRED_TARGET in AUR:waybar-niri-taskbar-git \
    AUR:waybar-module-pacman-updates-git; do
    if printf '%s\n' "${TARGETS[@]}" | grep -Fqx "$RETIRED_TARGET"; then
        fail "a legacy QuickShell-conflicting target must be retired: $RETIRED_TARGET"
    fi
done

mkdir -p "$HOME_DIR/.config/niri"
NIRI_CONFIG="$HOME_DIR/.config/niri/config.kdl"
cat > "$NIRI_CONFIG" <<'EOF'
// user-owned marker
spawn-at-startup "waybar"
spawn-at-startup "quickshell" "--config" "user-shell"
spawn-at-startup "quickshell"
spawn-at-startup "ags" "run"
binds {
    Mod+Return { spawn "kitty"; }
}
EOF

ensure_niri_quickshell_startup "$NIRI_CONFIG" "$TARGET_USER"
niri_quickshell_startup_satisfied "$NIRI_CONFIG" ||
    fail 'converged config must contain one conflict-free QuickShell startup'
grep -Fqx '// user-owned marker' "$NIRI_CONFIG" ||
    fail 'QuickShell convergence must preserve unrelated user content'
grep -Fqx '    Mod+Return { spawn "kitty"; }' "$NIRI_CONFIG" ||
    fail 'QuickShell convergence must preserve user key bindings'
grep -Fqx 'spawn-at-startup "quickshell" "--config" "user-shell"' \
    "$NIRI_CONFIG" ||
    fail 'QuickShell convergence must preserve the first user command and arguments'
FIRST_COPY="$TEST_DIR/first-config.kdl"
cp "$NIRI_CONFIG" "$FIRST_COPY"
ensure_niri_quickshell_startup "$NIRI_CONFIG" "$TARGET_USER"
cmp -s "$FIRST_COPY" "$NIRI_CONFIG" ||
    fail 'QuickShell convergence must be content-idempotent'

printf '%s\n' 'spawn-sh-at-startup "quickshell &"' > "$NIRI_CONFIG"
ensure_niri_quickshell_startup "$NIRI_CONFIG" "$TARGET_USER"
grep -Fqx 'spawn-sh-at-startup "quickshell &"' "$NIRI_CONFIG" ||
    fail 'an existing spawn-sh QuickShell command must be preserved'
[ "$(grep -Ec '^[[:space:]]*spawn(-sh)?-at-startup.*quickshell' "$NIRI_CONFIG")" -eq 1 ] ||
    fail 'spawn-sh QuickShell must not be duplicated'

printf '// arbitrary but nonempty config\n' > "$NIRI_CONFIG"
if niri_quickshell_startup_satisfied "$NIRI_CONFIG"; then
    fail 'a nonempty config without QuickShell startup must not verify'
fi
ensure_niri_quickshell_startup "$NIRI_CONFIG" "$TARGET_USER"
niri_quickshell_startup_satisfied "$NIRI_CONFIG" ||
    fail 'QuickShell startup must be added without replacing the config'
grep -Fqx '// arbitrary but nonempty config' "$NIRI_CONFIG" ||
    fail 'startup insertion must preserve the existing config'

NIRI_FIREFOX_POLICY_FILE="$TEST_DIR/firefox/policies.json"
NIRI_NAUTILUS_VENDOR_FILE="$TEST_DIR/vendor-nautilus.desktop"
NIRI_NAUTILUS_OVERRIDE_FILE="$HOME_DIR/.local/share/applications/org.gnome.Nautilus.desktop"
NIRI_GNOME_TERMINAL_LINK="$HOME_DIR/.local/bin/gnome-terminal"
NIRI_GNOME_TERMINAL_TARGET="$TEST_DIR/bin/kitty"
NIRI_PORTAL_CONFIG_FILE="$HOME_DIR/.config/xdg-desktop-portal/portals.conf"
NIRI_GTK4_DIR="$HOME_DIR/.config/gtk-4.0"
NIRI_GTK_THEME_DIR="$HOME_DIR/.themes/adw-gtk3-dark/gtk-4.0"
export NIRI_FIREFOX_POLICY_FILE NIRI_NAUTILUS_VENDOR_FILE
export NIRI_NAUTILUS_OVERRIDE_FILE NIRI_GNOME_TERMINAL_LINK
export NIRI_GNOME_TERMINAL_TARGET NIRI_PORTAL_CONFIG_FILE
export NIRI_GTK4_DIR NIRI_GTK_THEME_DIR
desktop_niri_contract_init

mkdir -p "$(dirname "$NIRI_FIREFOX_POLICY_FILE")" \
    "$(dirname "$NIRI_NAUTILUS_OVERRIDE_FILE")" \
    "$(dirname "$NIRI_GNOME_TERMINAL_LINK")" \
    "$(dirname "$NIRI_GNOME_TERMINAL_TARGET")" \
    "$NIRI_GTK4_DIR" "$NIRI_GTK_THEME_DIR" \
    "$(dirname "$NIRI_PORTAL_CONFIG_FILE")"
cat > "$NIRI_NAUTILUS_VENDOR_FILE" <<'EOF'
[Desktop Entry]
Name=Files
DBusActivatable=true
Exec=nautilus --new-window %U

[Desktop Action new-window]
Exec=nautilus --new-window
EOF
printf '#!/usr/bin/env bash\n' > "$NIRI_GNOME_TERMINAL_TARGET"
chmod 755 "$NIRI_GNOME_TERMINAL_TARGET"

niri_firefox_policy_contract > "$NIRI_FIREFOX_POLICY_FILE"
niri_nautilus_override_contract > "$NIRI_NAUTILUS_OVERRIDE_FILE"
ln -s "$NIRI_GNOME_TERMINAL_TARGET" "$NIRI_GNOME_TERMINAL_LINK"
niri_portal_config_contract > "$NIRI_PORTAL_CONFIG_FILE"
printf 'gtk css\n' > "$NIRI_GTK_THEME_DIR/gtk.css"
printf 'gtk dark css\n' > "$NIRI_GTK_THEME_DIR/gtk-dark.css"
ln -s "$NIRI_GTK_THEME_DIR/gtk.css" "$NIRI_GTK4_DIR/gtk.css"
ln -s "$NIRI_GTK_THEME_DIR/gtk-dark.css" "$NIRI_GTK4_DIR/gtk-dark.css"

niri_firefox_policy_matches || fail 'Firefox policy must have an exact contract'
niri_nautilus_override_matches || fail 'Nautilus user override must match its source contract'
niri_user_terminal_link_matches || fail 'terminal compatibility must use an exact user link'
niri_portal_config_matches || fail 'portal selection must have an exact contract'
niri_gtk_links_match || fail 'GTK links must target the managed user theme'
grep -Fqx 'DBusActivatable=false' "$NIRI_NAUTILUS_OVERRIDE_FILE" ||
    fail 'Nautilus override must disable D-Bus activation for its Exec environment'
grep -Fqx 'Exec=env GTK_IM_MODULE=fcitx nautilus --new-window %U' \
    "$NIRI_NAUTILUS_OVERRIDE_FILE" ||
    fail 'Nautilus override must add input environment without changing the vendor file'
grep -Fqx 'DBusActivatable=true' "$NIRI_NAUTILUS_VENDOR_FILE" ||
    fail 'the vendor Nautilus desktop file must remain untouched'

APPLY_SCRIPT="$ROOT_DIR/scripts/modules/desktop-niri/apply.sh"
if grep -Eq '/usr/bin/gnome-terminal|sed[[:space:]]+-i.*Nautilus' "$APPLY_SCRIPT"; then
    fail 'desktop apply must not modify package-owned executable or desktop files'
fi
if grep -Fq 'NOPASSWD: ALL' "$APPLY_SCRIPT"; then
    fail 'desktop apply must not grant broad temporary sudo privileges'
fi

PROFILE_DIR="$TEST_DIR/profile"
BIN_DIR="$TEST_DIR/mock-bin"
mkdir -p "$PROFILE_DIR" "$BIN_DIR"
printf 'imv\n' > "$PROFILE_DIR/niri-packages.list"
cat > "$BIN_DIR/pacman" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = -Q ] && { [ "$2" = ddcutil ] || [ "$2" = swayosd ]; }; then
    exit 1
fi
[ "$1" = -Q ]
EOF
chmod +x "$BIN_DIR/pacman"

UNIT_DIR="$HOME_DIR/.config/systemd/user"
mkdir -p "$UNIT_DIR/default.target.wants"
cat > "$UNIT_DIR/niri-autostart.service" <<'EOF'
[Unit]
Description=Niri Session Autostart
[Service]
ExecStart=/usr/bin/niri-session
Restart=on-failure
[Install]
WantedBy=default.target
EOF
ln -s ../niri-autostart.service \
    "$UNIT_DIR/default.target.wants/niri-autostart.service"

status=0
output=$(PATH="$BIN_DIR:$PATH" SHORIN_PROFILE_DIR="$PROFILE_DIR" \
    bash "$ROOT_DIR/scripts/modules/desktop-niri.sh" check 2>&1) || status=$?
[ "$status" -eq 0 ] || fail 'complete desktop managed state must check successfully'

printf 'stale policy\n' > "$NIRI_FIREFOX_POLICY_FILE"
status=0
output=$(PATH="$BIN_DIR:$PATH" SHORIN_PROFILE_DIR="$PROFILE_DIR" \
    bash "$ROOT_DIR/scripts/modules/desktop-niri.sh" verify 2>&1) || status=$?
[ "$status" -eq 1 ] || fail 'stale managed desktop state must fail verification'
grep -Fq file:firefox-policy <<< "$output" ||
    fail 'desktop verification must identify the stale managed target'
niri_firefox_policy_contract > "$NIRI_FIREFOX_POLICY_FILE"

niri_autostart_unit_satisfied "$TARGET_USER" "$HOME_DIR" ||
    fail 'a complete Niri user unit must verify'
rm "$UNIT_DIR/niri-autostart.service"
if niri_autostart_unit_satisfied "$TARGET_USER" "$HOME_DIR"; then
    fail 'a dangling wants link must not verify'
fi

printf 'PASS: desktop-niri desired-state contract\n'
