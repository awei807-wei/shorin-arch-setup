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

niri_user_bus_is_available() {
    return 1
}

LIST_FILE="$TEST_DIR/niri-applist.txt"
MANIFEST="$TEST_DIR/niri-packages.list"
printf 'waybar\n' > "$LIST_FILE"
printf '%s\n' imv AUR:matugen waybar \
    AUR:wlogout \
    AUR:waybar-niri-taskbar-git \
    AUR:waybar-module-pacman-updates-git > "$MANIFEST"

EMPTY_MANIFEST="$TEST_DIR/empty-niri-packages.list"
: > "$EMPTY_MANIFEST"
mapfile -t EMPTY_TARGETS < <(niri_all_package_targets "$EMPTY_MANIFEST" "$LIST_FILE")
printf '%s\n' "${EMPTY_TARGETS[@]}" | grep -Fqx quickshell ||
    fail 'an empty saved manifest must retain required desktop targets'
if printf '%s\n' "${EMPTY_TARGETS[@]}" | grep -Fqx waybar; then
    fail 'an empty saved manifest must not fall back to default optional targets'
fi

mapfile -t TARGETS < <(niri_all_package_targets "$MANIFEST" "$LIST_FILE")
for REQUIRED_TARGET in quickshell qt6-wayland qt6-multimedia bluez-utils \
    matugen awww swayidle AUR:swaylock-effects; do
    printf '%s\n' "${TARGETS[@]}" | grep -Fqx "$REQUIRED_TARGET" ||
        fail "an old manifest must not mask required target $REQUIRED_TARGET"
done
printf '%s\n' "${TARGETS[@]}" | grep -Fqx imv ||
    fail 'saved optional package choices must be preserved'
printf '%s\n' "${TARGETS[@]}" | grep -Fqx AUR:wlogout-git ||
    fail 'the legacy signed wlogout target must migrate to wlogout-git'
if printf '%s\n' "${TARGETS[@]}" | grep -Fqx AUR:wlogout; then
    fail 'the legacy wlogout target must not remain in the converged profile'
fi
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
spawn-at-startup "/usr/bin/fcitx5" "-d"
spawn-at-startup "env" "fcitx5"
binds {
    Mod+Return { spawn "kitty"; }
}
EOF

ensure_niri_quickshell_startup "$NIRI_CONFIG" "$TARGET_USER"
ensure_niri_fcitx5_startup "$NIRI_CONFIG" "$TARGET_USER"
niri_quickshell_startup_satisfied "$NIRI_CONFIG" ||
    fail 'converged config must contain one conflict-free QuickShell startup'
grep -Fqx '// user-owned marker' "$NIRI_CONFIG" ||
    fail 'QuickShell convergence must preserve unrelated user content'
grep -Fqx '    Mod+Return { spawn "kitty"; }' "$NIRI_CONFIG" ||
    fail 'QuickShell convergence must preserve user key bindings'
niri_fcitx5_startup_satisfied "$NIRI_CONFIG" ||
    fail 'converged config must contain exactly one Fcitx5 startup'
[ "$(grep -Ec '^[[:space:]]*spawn(-sh)?-at-startup.*fcitx5' "$NIRI_CONFIG")" -eq 1 ] ||
    fail 'Fcitx5 convergence must remove duplicate startup commands'
grep -Fqx 'spawn-at-startup "quickshell" "--config" "user-shell"' \
    "$NIRI_CONFIG" ||
    fail 'QuickShell convergence must preserve the first user command and arguments'
grep -Fqx 'spawn-at-startup "quickshell"' "$NIRI_CONFIG" ||
    fail 'additional QuickShell instances (e.g. a lockscreen) must be preserved'
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
ensure_niri_fcitx5_startup "$NIRI_CONFIG" "$TARGET_USER"
niri_fcitx5_startup_satisfied "$NIRI_CONFIG" ||
    fail 'Fcitx5 startup must be added without replacing the config'

NIRI_FIREFOX_POLICY_FILE="$TEST_DIR/firefox/policies.json"
NIRI_NAUTILUS_VENDOR_FILE="$TEST_DIR/vendor-nautilus.desktop"
NIRI_NAUTILUS_OVERRIDE_FILE="$HOME_DIR/.local/share/applications/org.gnome.Nautilus.desktop"
NIRI_GNOME_TERMINAL_LINK="$HOME_DIR/.local/bin/gnome-terminal"
NIRI_GNOME_TERMINAL_TARGET="$TEST_DIR/bin/kitty"
NIRI_PORTAL_CONFIG_FILE="$HOME_DIR/.config/xdg-desktop-portal/portals.conf"
NIRI_GTK4_DIR="$HOME_DIR/.config/gtk-4.0"
NIRI_GTK_THEME_DIR="$HOME_DIR/.themes/adw-gtk3-dark/gtk-4.0"
NIRI_BINDS_FILE="$HOME_DIR/.config/niri/binds.kdl"
NIRI_QUICKSHELL_DIR="$HOME_DIR/.config/quickshell"
NIRI_FISH_GUARD_FILE="$HOME_DIR/.config/fish/conf.d/shorin-env.fish"
NIRI_FISH_RUSTUP_FILE="$HOME_DIR/.config/fish/conf.d/rustup.fish"
NIRI_FISH_LOCAL_ENV_FILE="$HOME_DIR/.config/fish/conf.d/uv.env.fish"
NIRI_BASH_PROFILE="$HOME_DIR/.bash_profile"
NIRI_LEGACY_UNIT="$HOME_DIR/.config/systemd/user/niri-autostart.service"
NIRI_LEGACY_UNIT_LINK="$HOME_DIR/.config/systemd/user/default.target.wants/niri-autostart.service"
NIRI_AUTOLOGIN_FILE="$TEST_DIR/getty@tty1.service.d/autologin.conf"
export NIRI_FIREFOX_POLICY_FILE NIRI_NAUTILUS_VENDOR_FILE
export NIRI_NAUTILUS_OVERRIDE_FILE NIRI_GNOME_TERMINAL_LINK
export NIRI_GNOME_TERMINAL_TARGET NIRI_PORTAL_CONFIG_FILE
export NIRI_GTK4_DIR NIRI_GTK_THEME_DIR
export NIRI_BINDS_FILE NIRI_QUICKSHELL_DIR NIRI_FISH_GUARD_FILE
export NIRI_FISH_RUSTUP_FILE
export NIRI_FISH_LOCAL_ENV_FILE NIRI_BASH_PROFILE NIRI_LEGACY_UNIT
export NIRI_LEGACY_UNIT_LINK
export NIRI_AUTOLOGIN_FILE
desktop_niri_contract_init

mkdir -p "$(dirname "$NIRI_FIREFOX_POLICY_FILE")" \
    "$(dirname "$NIRI_NAUTILUS_OVERRIDE_FILE")" \
    "$(dirname "$NIRI_GNOME_TERMINAL_LINK")" \
    "$(dirname "$NIRI_GNOME_TERMINAL_TARGET")" \
    "$NIRI_GTK4_DIR" "$NIRI_GTK_THEME_DIR" \
    "$(dirname "$NIRI_PORTAL_CONFIG_FILE")" \
    "$NIRI_QUICKSHELL_DIR/lockscreen" \
    "$(dirname "$NIRI_FISH_RUSTUP_FILE")" \
    "$(dirname "$NIRI_LEGACY_UNIT_LINK")"
printf 'stale override\n' > "$NIRI_NAUTILUS_OVERRIDE_FILE"
status=0
niri_nautilus_override_matches || status=$?
[ "$status" -eq 1 ] ||
    fail 'a missing Nautilus vendor file must be repairable desktop drift'
rm -f "$NIRI_NAUTILUS_OVERRIDE_FILE"
cat > "$NIRI_NAUTILUS_VENDOR_FILE" <<'EOF'
[Desktop Entry]
Name=Files
DBusActivatable=true
Exec=nautilus --new-window %U

[Desktop Action new-window]
Exec=nautilus --new-window
EOF
status=0
niri_user_terminal_link_matches || status=$?
[ "$status" -eq 1 ] ||
    fail 'a missing Kitty target must be repairable desktop drift'
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

cat > "$NIRI_CONFIG_FILE" <<'EOF'
// preserve niri marker
environment {
    PATH "/usr/local/bin:/usr/bin"
}
spawn-at-startup "swww-daemon"
spawn-at-startup "quickshell"
EOF
cat > "$NIRI_BINDS_FILE" <<'EOF'
binds {
    Mod+Alt+V { spawn "clipse"; }
    Mod+ALT+V { spawn "old-clipboard"; }
    Mod+Alt+C { spawn "old-switcher"; }
    Mod+Return { spawn "kitty"; }
}
EOF
cat > "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" <<'EOF'
property string swwwTheme: "preserve-identifier"
command: ["sh", "-c", "swww query"]
EOF
printf 'source "$HOME/.cargo/env.fish"\n' > "$NIRI_FISH_RUSTUP_FILE"
printf 'test -f "$HOME/.local/bin/env.fish"; and source "$HOME/.local/bin/env.fish"\n' \
    > "$NIRI_FISH_LOCAL_ENV_FILE"
cat > "$NIRI_BASH_PROFILE" <<'EOF'
# preserve profile marker
# shorin:niri-session:start
if [ "$(tty)" = /dev/tty1 ]; then
    exec niri-session
fi
# shorin:niri-session:end
# preserve profile tail
EOF
printf '[Service]\nExecStart=/usr/bin/niri-session\n' > "$NIRI_LEGACY_UNIT"
ln -s ../niri-autostart.service "$NIRI_LEGACY_UNIT_LINK"

VALIDATE_BIN_DIR="$TEST_DIR/validate-bin"
NIRI_VALIDATE_LOG="$TEST_DIR/niri-validate.log"
mkdir -p "$VALIDATE_BIN_DIR"
cat > "$VALIDATE_BIN_DIR/niri" <<'EOF'
#!/usr/bin/env bash
[ "$1" = validate ] && [ "$2" = -c ] && [ -s "$3" ]
[ "${NIRI_VALIDATE_FAIL:-0}" != 1 ] || exit 1
printf 'validated\n' >> "$NIRI_VALIDATE_LOG"
EOF
chmod +x "$VALIDATE_BIN_DIR/niri"
export NIRI_VALIDATE_LOG
PATH="$VALIDATE_BIN_DIR:$PATH"
export PATH
RUNUSER_VALIDATE_LOG="$TEST_DIR/runuser-validate.log"
runuser() {
    printf '%s\n' "$*" >> "$RUNUSER_VALIDATE_LOG"
    [ "$1" = -u ] && [ "$3" = -- ] || return 2
    shift 3
    "$@"
}
SHORIN_FORCE_RUNUSER=1
export SHORIN_FORCE_RUNUSER

ensure_niri_session_config "$TARGET_USER"
niri_path_satisfied || fail 'Niri PATH must contain the target user local bin'
niri_wallpaper_backend_satisfied || fail 'Niri startup must migrate swww to awww'
niri_quickshell_wallpaper_backend_satisfied ||
    fail 'QuickShell commands must migrate swww to awww'
niri_bindings_satisfied || fail 'Niri clipboard and FocusShift bindings must be exact'
niri_fish_sources_satisfied || fail 'Fish environment sources must be conditional'
[ -f "$NIRI_FISH_GUARD_FILE" ] ||
    fail 'Fish guards must use a dedicated installer-managed conf.d file'
grep -Fqx '    set -gx PATH "$HOME/.cargo/bin" $PATH' "$NIRI_FISH_GUARD_FILE" ||
    fail 'managed Fish environment must add Cargo bin without generated env files'
grep -Fqx '    set -gx PATH "$HOME/.local/bin" $PATH' "$NIRI_FISH_GUARD_FILE" ||
    fail 'managed Fish environment must add local bin without generated env files'
if grep -Fq 'source "$HOME/' "$NIRI_FISH_GUARD_FILE"; then
    fail 'managed Fish environment must not depend on installer-generated env files'
fi
[ ! -e "$NIRI_FISH_RUSTUP_FILE" ] && [ ! -e "$NIRI_FISH_LOCAL_ENV_FILE" ] ||
    fail 'known legacy Fish source files must be migrated without duplicate sourcing'
niri_bash_profile_satisfied || fail 'TTY1 Niri startup must use the managed profile block'
niri_legacy_autostart_absent || fail 'legacy Niri user service must be removed'
grep -Fqx '// preserve niri marker' "$NIRI_CONFIG_FILE" ||
    fail 'Niri session convergence must preserve unrelated configuration'
grep -Fqx '    Mod+Return { spawn "kitty"; }' "$NIRI_BINDS_FILE" ||
    fail 'binding convergence must preserve unrelated key bindings'
grep -Fqx '# preserve profile marker' "$NIRI_BASH_PROFILE" ||
    fail 'profile convergence must preserve user content outside the managed block'
grep -Fqx '# preserve profile tail' "$NIRI_BASH_PROFILE" ||
    fail 'profile migration must preserve content after the legacy block'
if grep -Fq '# shorin:niri-session:' "$NIRI_BASH_PROFILE"; then
    fail 'legacy profile startup markers must be removed during migration'
fi
grep -Fq 'awww query' "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" ||
    fail 'QuickShell wallpaper query must use awww'
grep -Fqx 'property string swwwTheme: "preserve-identifier"' \
    "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" ||
    fail 'swww migration must preserve non-command identifiers'
grep -Fqx '    Mod+Alt+V hotkey-overlay-title="剪贴板 Clipboard" { spawn "niri-clip" "toggle"; }' \
    "$NIRI_BINDS_FILE" || fail 'Mod+Alt+V must invoke niri-clip toggle'
grep -Fqx '    Mod+ALT+C repeat=false hotkey-overlay-title="窗口切换 FocusShift" { spawn "focus-shift"; }' \
    "$NIRI_BINDS_FILE" || fail 'Mod+Alt+C must use the requested FocusShift binding'
[ "$(grep -Eic '^[[:space:]]*Mod\+Alt\+V[[:space:]]' "$NIRI_BINDS_FILE")" -eq 1 ] ||
    fail 'clipboard binding convergence must remove duplicates'
[ "$(wc -l < "$NIRI_VALIDATE_LOG")" -ge 1 ] ||
    fail 'Niri validation must run after managed configuration is written'
grep -Fq -- "-u $TARGET_USER -- env HOME=$HOME_DIR niri validate" \
    "$RUNUSER_VALIDATE_LOG" ||
    fail 'Niri validation must execute in the target user context'

printf 'set -gx USER_CUSTOM_ENV preserved\n' > "$NIRI_FISH_RUSTUP_FILE"
FISH_CUSTOM_COPY="$TEST_DIR/custom-rustup.fish"
cp "$NIRI_FISH_RUSTUP_FILE" "$FISH_CUSTOM_COPY"
ensure_niri_fish_sources "$TARGET_USER"
cmp -s "$NIRI_FISH_RUSTUP_FILE" "$FISH_CUSTOM_COPY" ||
    fail 'custom legacy Fish files are user-owned and must not be overwritten'
niri_fish_sources_satisfied ||
    fail 'custom legacy Fish files must coexist with the managed guard contract'

FISH_LINK_TARGET="$TEST_DIR/user-rustup-target.fish"
printf 'source "$HOME/.cargo/env.fish"\n' > "$FISH_LINK_TARGET"
rm -f "$NIRI_FISH_RUSTUP_FILE"
ln -s "$FISH_LINK_TARGET" "$NIRI_FISH_RUSTUP_FILE"
ensure_niri_fish_sources "$TARGET_USER"
[ -L "$NIRI_FISH_RUSTUP_FILE" ] &&
    [ "$(readlink "$NIRI_FISH_RUSTUP_FILE")" = "$FISH_LINK_TARGET" ] ||
    fail 'legacy Fish symlinks are user-owned and must never be deleted'
niri_fish_sources_satisfied ||
    fail 'a user-owned legacy Fish symlink must satisfy the migration boundary'

# A previously deployed tty1 block without -l loops through the login shell;
# it must drift and be upgraded in place.
cat > "$NIRI_BASH_PROFILE" <<'EOF'
# preserve upgrade marker
# >>> shorin niri tty1 >>>
if [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} && $(tty) == /dev/tty1 ]]; then
    exec niri-session
fi
# <<< shorin niri tty1 <<<
EOF
if niri_bash_profile_satisfied; then
    fail 'a tty1 startup block without -l must drift'
fi
ensure_niri_bash_profile "$TARGET_USER"
niri_bash_profile_satisfied ||
    fail 'the upgraded tty1 startup block must satisfy the contract'
grep -Fqx '    exec niri-session -l' "$NIRI_BASH_PROFILE" ||
    fail 'tty1 startup must run niri-session -l inside the login shell'
[ "$(grep -Fc 'exec niri-session' "$NIRI_BASH_PROFILE")" -eq 1 ] ||
    fail 'the tty1 startup upgrade must not duplicate the exec line'
grep -Fqx '# preserve upgrade marker' "$NIRI_BASH_PROFILE" ||
    fail 'the tty1 startup upgrade must preserve user content'

chmod 000 "$NIRI_BINDS_FILE"
if niri_session_files_accessible "$TARGET_USER"; then
    fail 'unreadable Niri session files must fail the access contract'
fi
ensure_niri_session_config "$TARGET_USER"
niri_session_files_accessible "$TARGET_USER" ||
    fail 'session apply must repair target-user ownership and readability'

SESSION_COPY_DIR="$TEST_DIR/session-copy"
mkdir -p "$SESSION_COPY_DIR"
cp "$NIRI_CONFIG_FILE" "$SESSION_COPY_DIR/config.kdl"
cp "$NIRI_BINDS_FILE" "$SESSION_COPY_DIR/binds.kdl"
cp "$NIRI_BASH_PROFILE" "$SESSION_COPY_DIR/bash_profile"
cp "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" "$SESSION_COPY_DIR/shell.qml"
ensure_niri_session_config "$TARGET_USER"
cmp -s "$NIRI_CONFIG_FILE" "$SESSION_COPY_DIR/config.kdl" &&
    cmp -s "$NIRI_BINDS_FILE" "$SESSION_COPY_DIR/binds.kdl" &&
    cmp -s "$NIRI_BASH_PROFILE" "$SESSION_COPY_DIR/bash_profile" &&
    cmp -s "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" \
        "$SESSION_COPY_DIR/shell.qml" ||
    fail 'desktop session convergence must be content-idempotent'

printf '\nspawn-at-startup "swww-daemon"\n' >> "$NIRI_CONFIG_FILE"
printf '\nrollbackCommand: ["sh", "-c", "swww query"]\n' \
    >> "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml"
sed -i 's/Mod+Alt+C repeat=false.*/Mod+Alt+C { spawn "old-switcher"; }/' \
    "$NIRI_BINDS_FILE"
cp "$NIRI_CONFIG_FILE" "$SESSION_COPY_DIR/rollback-config.kdl"
cp "$NIRI_BINDS_FILE" "$SESSION_COPY_DIR/rollback-binds.kdl"
cp "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" \
    "$SESSION_COPY_DIR/rollback-shell.qml"
NIRI_VALIDATE_FAIL=1
export NIRI_VALIDATE_FAIL
if ensure_niri_session_config "$TARGET_USER"; then
    fail 'failed Niri validation must reject the attempted convergence'
fi
cmp -s "$NIRI_CONFIG_FILE" "$SESSION_COPY_DIR/rollback-config.kdl" &&
    cmp -s "$NIRI_BINDS_FILE" "$SESSION_COPY_DIR/rollback-binds.kdl" &&
    cmp -s "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" \
        "$SESSION_COPY_DIR/rollback-shell.qml" ||
    fail 'failed validation must atomically restore Niri and QuickShell files'
NIRI_VALIDATE_FAIL=0
export NIRI_VALIDATE_FAIL
ensure_niri_session_config "$TARGET_USER"
unset SHORIN_FORCE_RUNUSER
unset -f runuser

AUTOLOGIN_SYSTEMCTL_LOG="$TEST_DIR/autologin-systemctl.log"
MOCK_DM=0
pacman() {
    [ "$1" = -Q ] && [ "$2" = gdm ] && [ "$MOCK_DM" -eq 1 ]
}
systemctl() {
    printf '%s\n' "$*" >> "$AUTOLOGIN_SYSTEMCTL_LOG"
}
mkdir -p "$(dirname "$NIRI_AUTOLOGIN_FILE")"
niri_autologin_contract "$TARGET_USER" > "$NIRI_AUTOLOGIN_FILE"
niri_autologin_state_satisfied ||
    fail 'managed target-user autologin must satisfy a display-manager-free system'
MOCK_DM=1
if niri_autologin_state_satisfied; then
    fail 'managed TTY autologin must drift when a display manager is installed'
fi
ensure_niri_autologin_state "$TARGET_USER" true
[ ! -e "$NIRI_AUTOLOGIN_FILE" ] ||
    fail 'skip mode must remove an exact installer-managed autologin override'
grep -Fqx 'daemon-reload' "$AUTOLOGIN_SYSTEMCTL_LOG" ||
    fail 'autologin override removal must reload the system manager'

printf '[Service]\n# user-owned getty customization\n' > "$NIRI_AUTOLOGIN_FILE"
AUTOLOGIN_CUSTOM_COPY="$TEST_DIR/custom-autologin.conf"
cp "$NIRI_AUTOLOGIN_FILE" "$AUTOLOGIN_CUSTOM_COPY"
ensure_niri_autologin_state "$TARGET_USER" false
cmp -s "$NIRI_AUTOLOGIN_FILE" "$AUTOLOGIN_CUSTOM_COPY" ||
    fail 'enable mode must preserve a non-managed custom getty override'
ensure_niri_autologin_state "$TARGET_USER" true
cmp -s "$NIRI_AUTOLOGIN_FILE" "$AUTOLOGIN_CUSTOM_COPY" ||
    fail 'skip mode must preserve a non-managed custom getty override'
unset -f pacman systemctl

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
if grep -Fq 'niri-autostart.service' "$APPLY_SCRIPT"; then
    fail 'desktop apply must not recreate the retired Niri user service'
fi

PROFILE_DIR="$TEST_DIR/profile"
BIN_DIR="$TEST_DIR/mock-bin"
PACKAGE_SOURCES="$TEST_DIR/package-sources"
mkdir -p "$PROFILE_DIR" "$BIN_DIR" "$PACKAGE_SOURCES"
mkdir -p "$HOME_DIR/Pictures/Wallpapers" "$HOME_DIR/Templates"
printf 'wallpaper\n' > "$HOME_DIR/Pictures/Wallpapers/default.png"
touch "$HOME_DIR/Templates/new"
printf '#!/usr/bin/env bash\n' > "$HOME_DIR/Templates/new.sh"
niri_wallpapers_deployed ||
    fail 'a deployed wallpaper tree must satisfy the wallpaper state'
niri_templates_deployed ||
    fail 'deployed template files must satisfy the template state'
printf 'imv\n' > "$PROFILE_DIR/niri-packages.list"
for package in nautilus-open-any-terminal swaylock-effects; do
    printf 'source=aur\nversion=1.0\n' > "$PACKAGE_SOURCES/$package"
done
cat > "$BIN_DIR/pacman" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = -Q ] && { [ "$2" = ddcutil ] || [ "$2" = swayosd ]; }; then
    exit 1
fi
if [ "$1" = -Q ]; then
    printf '%s 1.0\n' "$2"
    exit 0
fi
exit 1
EOF
chmod +x "$BIN_DIR/pacman"

status=0
output=$(PATH="$BIN_DIR:$PATH" SHORIN_PROFILE_DIR="$PROFILE_DIR" \
    PACKAGE_SOURCE_DIR="$PACKAGE_SOURCES" \
    bash "$ROOT_DIR/scripts/modules/desktop-niri.sh" check 2>&1) || status=$?
[ "$status" -eq 0 ] || fail 'complete desktop managed state must check successfully'

printf 'stale policy\n' > "$NIRI_FIREFOX_POLICY_FILE"
status=0
output=$(PATH="$BIN_DIR:$PATH" SHORIN_PROFILE_DIR="$PROFILE_DIR" \
    PACKAGE_SOURCE_DIR="$PACKAGE_SOURCES" \
    bash "$ROOT_DIR/scripts/modules/desktop-niri.sh" verify 2>&1) || status=$?
[ "$status" -eq 1 ] || fail 'stale managed desktop state must fail verification'
grep -Fq file:firefox-policy <<< "$output" ||
    fail 'desktop verification must identify the stale managed target'
niri_firefox_policy_contract > "$NIRI_FIREFOX_POLICY_FILE"

printf '[Service]\nExecStart=/usr/bin/niri-session\n' > "$NIRI_LEGACY_UNIT"
ln -s ../niri-autostart.service "$NIRI_LEGACY_UNIT_LINK"
status=0
output=$(PATH="$BIN_DIR:$PATH" SHORIN_PROFILE_DIR="$PROFILE_DIR" \
    PACKAGE_SOURCE_DIR="$PACKAGE_SOURCES" \
    bash "$ROOT_DIR/scripts/modules/desktop-niri.sh" check 2>&1) || status=$?
[ "$status" -eq 10 ] || fail 'legacy Niri autostart service must report drift'
grep -Fq legacy:niri-autostart-absent <<< "$output" ||
    fail 'legacy Niri service drift must identify the migration target'
RUNUSER_LOG="$TEST_DIR/runuser.log"
LEGACY_ACTIVE_STATUS=2
LEGACY_ENABLED_STATUS=1
LEGACY_DISABLE_FAIL=1
niri_user_bus_is_available() {
    return 0
}
runuser() {
    printf '%s\n' "$*" >> "$RUNUSER_LOG"
    case "$*" in
        *'systemctl --user is-active --quiet niri-autostart.service'*)
            return "$LEGACY_ACTIVE_STATUS"
            ;;
        *'systemctl --user is-enabled --quiet niri-autostart.service'*)
            return "$LEGACY_ENABLED_STATUS"
            ;;
        *'systemctl --user disable --now niri-autostart.service'*)
            [ "$LEGACY_DISABLE_FAIL" -eq 0 ]
            ;;
        *) return 0 ;;
    esac
}
if ensure_niri_bash_profile "$TARGET_USER"; then
    fail 'a user-bus activity query error must fail convergence'
fi
[ -e "$NIRI_LEGACY_UNIT" ] && [ -L "$NIRI_LEGACY_UNIT_LINK" ] ||
    fail 'a user-bus query error must preserve legacy unit files'
LEGACY_ACTIVE_STATUS=3
LEGACY_ENABLED_STATUS=2
if ensure_niri_bash_profile "$TARGET_USER"; then
    fail 'a user-bus enabled query error must fail convergence'
fi
[ -e "$NIRI_LEGACY_UNIT" ] && [ -L "$NIRI_LEGACY_UNIT_LINK" ] ||
    fail 'an enabled-state query error must preserve legacy unit files'
LEGACY_ACTIVE_STATUS=0
LEGACY_ENABLED_STATUS=1
if ensure_niri_bash_profile "$TARGET_USER"; then
    fail 'an active legacy unit that cannot be disabled must fail convergence'
fi
[ -e "$NIRI_LEGACY_UNIT" ] && [ -L "$NIRI_LEGACY_UNIT_LINK" ] ||
    fail 'failed legacy unit shutdown must preserve its files for recovery'
LEGACY_DISABLE_FAIL=0
ensure_niri_bash_profile "$TARGET_USER"
niri_legacy_autostart_absent || fail 'profile convergence must remove legacy service artifacts'
grep -Fq 'systemctl --user disable --now niri-autostart.service' "$RUNUSER_LOG" ||
    fail 'an active legacy unit must be disabled before its files are removed'
grep -Fq 'systemctl --user daemon-reload' "$RUNUSER_LOG" ||
    fail 'legacy service removal must reload an available user manager'
grep -Fq 'systemctl --user reset-failed niri-autostart.service' "$RUNUSER_LOG" ||
    fail 'legacy service removal must clear its loaded failure state'
DISABLE_LINE=$(grep -n 'systemctl --user disable --now niri-autostart.service' \
    "$RUNUSER_LOG" | tail -1 | cut -d: -f1)
RELOAD_LINE=$(grep -n 'systemctl --user daemon-reload' "$RUNUSER_LOG" |
    tail -1 | cut -d: -f1)
[ "$DISABLE_LINE" -lt "$RELOAD_LINE" ] ||
    fail 'legacy unit disable must happen before user-manager reload'
unset -f runuser
niri_user_bus_is_available() {
    return 1
}

printf 'PASS: desktop-niri desired-state contract\n'
