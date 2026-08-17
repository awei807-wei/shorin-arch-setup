#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

TARGET_USER=$(id -un)
HOME_DIR="$TEST_DIR/home"
SHORIN_ROOT="$ROOT_DIR"
export SHORIN_DISTRO=fedora
SHORIN_MODE=repair
SHORIN_READ_ONLY=0
SHORIN_USER_RUNTIME_ROOT="$TEST_DIR/runtime"
NIRI_WAYLAND_SESSION_FILE="$TEST_DIR/niri.desktop"
NIRI_AUTOLOGIN_FILE="$TEST_DIR/getty@tty1.service.d/autologin.conf"
export TARGET_USER HOME_DIR SHORIN_ROOT SHORIN_MODE SHORIN_READ_ONLY \
    SHORIN_USER_RUNTIME_ROOT
export NIRI_WAYLAND_SESSION_FILE NIRI_AUTOLOGIN_FILE
mkdir -p "$HOME_DIR" "$TEST_DIR/bin"
mkdir -p "$(dirname "$NIRI_AUTOLOGIN_FILE")"

cat > "$TEST_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    'show -p Id --value display-manager.service') printf '%s\n' sddm.service ;;
    'is-enabled --quiet display-manager.service'|'is-active --quiet display-manager.service') ;;
    'daemon-reload') ;;
    *) return 1 2>/dev/null || exit 1 ;;
esac
EOF
cat > "$TEST_DIR/bin/kwin_wayland" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TEST_DIR/bin/ldd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'linux-vdso.so.1 => /lib64/linux-vdso.so.1 (0x0)'
EOF
chmod 755 "$TEST_DIR/bin/systemctl" "$TEST_DIR/bin/kwin_wayland" \
    "$TEST_DIR/bin/ldd"
PATH="$TEST_DIR/bin:$PATH"
export PATH

source "$ROOT_DIR/scripts/modules/desktop-niri/targets.sh"
desktop_niri_contract_init
package_is_installed() { [ "$1" = sddm ]; }

cat > "$NIRI_WAYLAND_SESSION_FILE" <<'EOF'
[Desktop Entry]
Name=Niri
Exec=niri-session
Type=WaylandSession
EOF
niri_fedora_session_contract_satisfied ||
    fail 'Fedora formal display-manager and desktop-entry contract must pass'

cat > "$HOME_DIR/.bash_profile" <<'EOF'
# preserve user content
# >>> shorin niri tty1 >>>
if [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} && $(tty) == /dev/tty1 ]]; then
    exec niri-session -l
fi
# <<< shorin niri tty1 <<<
EOF
ensure_niri_bash_profile "$TARGET_USER" ||
    fail 'Fedora repair must remove the owned marker profile block'
! grep -Fq 'shorin niri tty1' "$HOME_DIR/.bash_profile" ||
    fail 'Fedora repair must not leave a TTY profile marker'
grep -Fqx '# preserve user content' "$HOME_DIR/.bash_profile" ||
    fail 'Fedora repair must preserve unrelated profile content'

printf 'user bare command\nexec niri\n' > "$HOME_DIR/.bash_profile"
before=$(< "$HOME_DIR/.bash_profile")
ensure_niri_bash_profile "$TARGET_USER" ||
    fail 'Fedora repair must tolerate user-owned bare commands'
[ "$(< "$HOME_DIR/.bash_profile")" = "$before" ] ||
    fail 'Fedora repair must not delete an arbitrary bare niri command'

mkdir -p "$(dirname "$NIRI_LEGACY_UNIT_LINK")"
printf '[Service]\nExecStart=/usr/bin/niri-session\n' > "$NIRI_LEGACY_UNIT"
ln -s ../niri-autostart.service "$NIRI_LEGACY_UNIT_LINK"
ensure_niri_bash_profile "$TARGET_USER" ||
    fail 'Fedora repair must remove the exact Shorin legacy user unit and link'
niri_legacy_autostart_absent ||
    fail 'Fedora repair must not leave Shorin legacy user service artifacts'
printf '[Service]\nExecStart=/usr/bin/custom-session\n' > "$NIRI_LEGACY_UNIT"
ln -s ../niri-autostart.service "$NIRI_LEGACY_UNIT_LINK"
if ensure_niri_bash_profile "$TARGET_USER"; then
    fail 'Fedora repair must not claim a custom legacy user unit'
fi
[ -f "$NIRI_LEGACY_UNIT" ] && [ -L "$NIRI_LEGACY_UNIT_LINK" ] ||
    fail 'Fedora repair changed a custom legacy user unit or link'
rm -f "$NIRI_LEGACY_UNIT_LINK" "$NIRI_LEGACY_UNIT"

niri_autologin_contract "$TARGET_USER" > "$NIRI_AUTOLOGIN_FILE"
ensure_niri_autologin_state "$TARGET_USER" true ||
    fail 'Fedora repair must remove an exact legacy Shorin autologin drop-in'
[ ! -e "$NIRI_AUTOLOGIN_FILE" ] ||
    fail 'Fedora must not retain the exact legacy autologin drop-in'
printf '[Service]\nExecStart=/usr/bin/niri\n' > "$NIRI_AUTOLOGIN_FILE"
custom=$(< "$NIRI_AUTOLOGIN_FILE")
ensure_niri_autologin_state "$TARGET_USER" true ||
    fail 'Fedora repair must preserve an arbitrary user drop-in'
[ "$(< "$NIRI_AUTOLOGIN_FILE")" = "$custom" ] ||
    fail 'Fedora repair changed an arbitrary user drop-in'
niri_autologin_state_satisfied ||
    fail 'a non-Shorin Fedora autologin drop-in must not create permanent drift'

mkdir -p "$HOME_DIR/.local/state/shorin-arch-setup" \
    "$HOME_DIR/.local/state/other-app"
printf 'lock\n' > "$HOME_DIR/.local/state/shorin-arch-setup/wallpaper.lock"
printf 'other\n' > "$HOME_DIR/.local/state/other-app/data"
ensure_niri_shorin_state_ownership "$TARGET_USER" ||
    fail 'Shorin state ownership must converge'
niri_shorin_state_ownership_satisfied "$TARGET_USER" ||
    fail 'Shorin state ownership must verify'

# A state-root symlink must be rejected before mkdir/chown; the external target
# must retain both its owner and contents.
external_state="$TEST_DIR/external-state"
mkdir -p "$external_state"
printf 'protected state\n' > "$external_state/protected"
state_owner_before=$(stat -c '%u:%g' "$external_state/protected")
state_content_before=$(< "$external_state/protected")
rm -rf "$HOME_DIR/.local/state-link"
ln -s "$external_state" "$HOME_DIR/.local/state-link"
NIRI_STATE_HOME="$HOME_DIR/.local/state-link"
NIRI_SHORIN_STATE_DIR="$NIRI_STATE_HOME/shorin-arch-setup"
if ensure_niri_shorin_state_ownership "$TARGET_USER"; then
    fail 'state ownership repair must reject a symlinked state root'
fi
case "$NIRI_PATH_SAFETY_REASON" in
    symlink:*) ;;
    *) fail "state symlink rejection must expose an explicit reason: $NIRI_PATH_SAFETY_REASON" ;;
esac
[ "$(< "$external_state/protected")" = "$state_content_before" ] ||
    fail 'state symlink rejection must preserve external state contents'
[ "$(stat -c '%u:%g' "$external_state/protected")" = "$state_owner_before" ] ||
    fail 'state symlink rejection must preserve external state ownership'

# A symlinked wallpaper root must fail before deployment and must not redirect
# installer ownership changes into the external directory.
source "$ROOT_DIR/scripts/modules/desktop-niri/dotfiles-apply.sh"
external_wallpapers="$TEST_DIR/external-wallpapers"
wallpaper_checkout="$TEST_DIR/wallpaper-checkout"
mkdir -p "$external_wallpapers" "$wallpaper_checkout/wallpapers" \
    "$HOME_DIR/Pictures"
printf 'protected wallpaper\n' > "$external_wallpapers/protected"
printf 'managed wallpaper\n' > \
    "$wallpaper_checkout/wallpapers/black-and-white-3840x2160-21293.jpg"
wallpaper_owner_before=$(stat -c '%u:%g' "$external_wallpapers/protected")
wallpaper_content_before=$(< "$external_wallpapers/protected")
rm -rf "$HOME_DIR/Pictures/Wallpapers"
ln -s "$external_wallpapers" "$HOME_DIR/Pictures/Wallpapers"
NIRI_WALLPAPER_DIR="$HOME_DIR/Pictures/Wallpapers"
if deploy_wallpapers_and_templates "$wallpaper_checkout"; then
    fail 'wallpaper deployment must reject a symlinked wallpaper root'
fi
case "$NIRI_PATH_SAFETY_REASON" in
    symlink:*) ;;
    *) fail "wallpaper symlink rejection must expose an explicit reason: $NIRI_PATH_SAFETY_REASON" ;;
esac
[ "$(< "$external_wallpapers/protected")" = "$wallpaper_content_before" ] ||
    fail 'wallpaper symlink rejection must preserve external contents'
[ "$(stat -c '%u:%g' "$external_wallpapers/protected")" = "$wallpaper_owner_before" ] ||
    fail 'wallpaper symlink rejection must preserve external ownership'

niri_fedora_kwin_wayland_runtime_satisfied ||
    fail 'KWin runtime ABI fixture must pass'
cat > "$TEST_DIR/bin/ldd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'undefined symbol: inhibitSuspend'
exit 1
EOF
chmod 755 "$TEST_DIR/bin/ldd"
if niri_fedora_kwin_wayland_runtime_satisfied; then
    fail 'KWin undefined symbol must report ABI drift'
fi

UPGRADE_LOG="$TEST_DIR/upgrade.log"
package_is_installed() { return 0; }
dnf() { printf '%s\n' "$*" >> "$UPGRADE_LOG"; }
niri_fedora_runtime_target_upgrade kscreenlocker ||
    fail 'Fedora runtime target must upgrade an installed package'
grep -Fqx 'upgrade --refresh -y --setopt=install_weak_deps=False kscreenlocker' \
    "$UPGRADE_LOG" || fail 'Fedora runtime upgrade must use a constrained dnf upgrade'

printf 'PASS: Fedora formal session, ownership, and KWin runtime contracts\n'
