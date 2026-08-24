#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" "${BASH_SOURCE[0]:-unknown}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
TARGET_USER=$(id -un)
HOME_DIR="$TEST_DIR/home"
export SHORIN_ROOT="$ROOT_DIR" SHORIN_DISTRO=fedora SHORIN_MODE=repair SHORIN_READ_ONLY=0 TARGET_USER HOME_DIR
mkdir -p "$HOME_DIR/.config/niri" "$HOME_DIR/.local/bin" "$HOME_DIR/.local/share/applications"
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

source "$ROOT_DIR/scripts/lib/core.sh"
declare -F fedora_vicinae_niri_command_contract_apply >/dev/null || fail 'Vicinae contract must be sourced before provider calls'

fedora_ensure_flatpak_target() { return 0; }
fedora_flatpak_present() { return 0; }
printf '#!/usr/bin/env bash\n' > "$HOME_DIR/.local/bin/vicinae.AppImage"
chmod 755 "$HOME_DIR/.local/bin/vicinae.AppImage"
FEDORA_VICINAE_SHA256=$(sha256sum "$HOME_DIR/.local/bin/vicinae.AppImage" | awk '{print $1}')
cat > "$HOME_DIR/.local/share/applications/vicinae.desktop" <<EOF
[Desktop Entry]
Name=Vicinae
Exec="$HOME_DIR/.local/bin/vicinae.AppImage"
Type=Application
EOF

cat > "$HOME_DIR/.config/niri/config.kdl" <<'EOF'
// spawn "vicinae" "server"
spawn-sh-at-startup "command -v vicinae >/dev/null 2>&1 && (\"vicinae\" \"server\")"
Alt+Q { spawn-sh-at-startup "command -v vicinae >/dev/null 2>&1 && (\"vicinae\" \"server\")"; }
Alt+P { spawn-sh-at-startup "command -v vicinae >/dev/null 2>&1 && (\"vicinae.AppImage\" \"server\")"; }
spawn "vicinae" "server" // preserve vicinae server comment
spawn-sh "vicinae server-extra"
spawn-sh "vicinae.AppImage server"
EOF
cat > "$HOME_DIR/.config/niri/binds.kdl" <<'EOF'
# spawn "vicinae" "toggle"
spawn-sh "command -v vicinae >/dev/null 2>&1 && (vicinae toggle)"
Alt+R { spawn-sh "command -v vicinae >/dev/null 2>&1 && (vicinae.AppImage toggle)"; }
Alt+S { spawn-sh "command -v vicinae.AppImage >/dev/null 2>&1 && (vicinae toggle)"; }
spawn "vicinae" "toggle" // preserve vicinae toggle comment
spawn-sh "vicinae toggle-extra"
spawn-sh "vicinae.AppImage toggle"
/* spawn-sh "vicinae toggle" */
/*
Alt+Z { spawn-sh "vicinae toggle"; }
*/
EOF

status=0
fedora_application_target_satisfied vicinae-bin "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -eq 1 ] || fail 'unconverted Fedora Vicinae Niri commands must be drift'

fedora_install_vicinae "$TARGET_USER" "$HOME_DIR" || fail 'Vicinae provider existing-target path failed'
grep -Fqx 'spawn-sh-at-startup "command -v vicinae.AppImage >/dev/null 2>&1 && (\"vicinae.AppImage\" \"server\")"' "$HOME_DIR/.config/niri/config.kdl" || fail 'server guard was not converted to AppImage'
grep -Fqx 'Alt+Q { spawn-sh-at-startup "command -v vicinae.AppImage >/dev/null 2>&1 && (\"vicinae.AppImage\" \"server\")"; }' "$HOME_DIR/.config/niri/config.kdl" || fail 'prefixed server spawn was not converted'
grep -Fqx 'Alt+P { spawn-sh-at-startup "command -v vicinae.AppImage >/dev/null 2>&1 && (\"vicinae.AppImage\" \"server\")"; }' "$HOME_DIR/.config/niri/config.kdl" || fail 'partially converted server spawn was not normalized'
grep -Fqx 'spawn "vicinae.AppImage" "server" // preserve vicinae server comment' "$HOME_DIR/.config/niri/config.kdl" || fail 'direct server spawn was not converted'
grep -Fqx 'spawn-sh "command -v vicinae.AppImage >/dev/null 2>&1 && (vicinae.AppImage toggle)"' "$HOME_DIR/.config/niri/binds.kdl" || fail 'toggle guard was not converted to AppImage'
grep -Fqx 'Alt+R { spawn-sh "command -v vicinae.AppImage >/dev/null 2>&1 && (vicinae.AppImage toggle)"; }' "$HOME_DIR/.config/niri/binds.kdl" || fail 'prefixed toggle spawn was not converted'
grep -Fqx 'Alt+S { spawn-sh "command -v vicinae.AppImage >/dev/null 2>&1 && (vicinae.AppImage toggle)"; }' "$HOME_DIR/.config/niri/binds.kdl" || fail 'partially converted toggle spawn was not normalized'
grep -Fqx 'spawn "vicinae.AppImage" "toggle" // preserve vicinae toggle comment' "$HOME_DIR/.config/niri/binds.kdl" || fail 'direct toggle spawn was not converted'
grep -Fqx 'spawn-sh "vicinae server-extra"' "$HOME_DIR/.config/niri/config.kdl" || fail 'similar server command was modified'
grep -Fqx 'spawn-sh "vicinae toggle-extra"' "$HOME_DIR/.config/niri/binds.kdl" || fail 'similar toggle command was modified'
grep -Fqx '// spawn "vicinae" "server"' "$HOME_DIR/.config/niri/config.kdl" || fail 'server comment was modified'
grep -Fqx '# spawn "vicinae" "toggle"' "$HOME_DIR/.config/niri/binds.kdl" || fail 'toggle comment was modified'
grep -Fqx '/* spawn-sh "vicinae toggle" */' "$HOME_DIR/.config/niri/binds.kdl" || fail 'block comment was modified'
grep -Fqx 'Alt+Z { spawn-sh "vicinae toggle"; }' "$HOME_DIR/.config/niri/binds.kdl" || fail 'multiline block comment was modified'
fedora_application_target_satisfied vicinae-bin "$TARGET_USER" "$HOME_DIR" || fail 'converted Vicinae target must satisfy application verification'

VICINAE_DOWNLOAD_CALLS=0
fedora_download_verified_official_asset() {
    VICINAE_DOWNLOAD_CALLS=$((VICINAE_DOWNLOAD_CALLS + 1))
    return 1
}
sed -i 's#^Exec=.*#Exec="/invalid/vicinae.AppImage"#' \
    "$HOME_DIR/.local/share/applications/vicinae.desktop"
fedora_install_vicinae "$TARGET_USER" "$HOME_DIR" ||
    fail 'Vicinae integration-only repair must reuse the verified destination'
[ "$VICINAE_DOWNLOAD_CALLS" -eq 0 ] ||
    fail 'Vicinae integration-only repair must not require another download'
fedora_application_target_satisfied vicinae-bin "$TARGET_USER" "$HOME_DIR" ||
    fail 'Vicinae integration-only repair did not restore the target contract'

config_digest=$(sha256sum "$HOME_DIR/.config/niri/config.kdl")
binds_digest=$(sha256sum "$HOME_DIR/.config/niri/binds.kdl")
fedora_install_vicinae "$TARGET_USER" "$HOME_DIR" || fail 'idempotent Vicinae provider path failed'
[ "$(sha256sum "$HOME_DIR/.config/niri/config.kdl")" = "$config_digest" ] || fail 'server conversion is not idempotent'
[ "$(sha256sum "$HOME_DIR/.config/niri/binds.kdl")" = "$binds_digest" ] || fail 'toggle conversion is not idempotent'

MISSING_HOME="$TEST_DIR/missing-home"
mkdir -p "$MISSING_HOME"
fedora_vicinae_niri_command_contract_apply "$TARGET_USER" "$MISSING_HOME" || fail 'missing Niri files must be skippable'
fedora_vicinae_niri_command_contract_satisfied "$MISSING_HOME" || fail 'missing Niri files must satisfy the skipped contract'

SYMLINK_HOME="$TEST_DIR/symlink-home"
mkdir -p "$SYMLINK_HOME/.config/niri"
printf '%s\n' 'spawn "vicinae" "server"' > "$TEST_DIR/real-config.kdl"
ln -s "$TEST_DIR/real-config.kdl" "$SYMLINK_HOME/.config/niri/config.kdl"
status=0
fedora_vicinae_niri_command_contract_apply "$TARGET_USER" "$SYMLINK_HOME" || status=$?
[ "$status" -ne 0 ] || fail 'Vicinae config symlink must be rejected'
[ -L "$SYMLINK_HOME/.config/niri/config.kdl" ] || fail 'Vicinae symlink must not be replaced'

printf 'PASS: Fedora Vicinae Niri command contract\n'
