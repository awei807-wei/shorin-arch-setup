#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"

NIRI_PACKAGES=(niri fuzzel kitty xdg-desktop-portal-gnome
    xdg-desktop-portal-gtk firefox nautilus)

desktop_niri_entry_satisfied() {
    local entry=$1
    case "$entry" in
        AUR:*) state_package_present "${entry#AUR:}" ;;
        flatpak:*) state_flatpak_present "${entry#flatpak:}" ;;
        GitHub:*) return 1 ;;
        imagemagic) state_package_present imagemagick ;;
        *) state_package_present "$entry" ;;
    esac
}

desktop_niri_expect() {
    local phase=$1 label=$2
    shift 2

    if [ "$phase" = check ]; then
        module_check_state "$label" "$@"
    elif ! "$@"; then
        module_verify_failed "$label"
    fi
}

desktop_niri_inspect() {
    local phase=$1 package entry source_file
    local manifest=${SHORIN_PROFILE_DIR:-/etc/shorin-arch-setup}/niri-packages.list

    for package in "${NIRI_PACKAGES[@]}"; do
        desktop_niri_expect "$phase" "package:$package" \
            state_package_present "$package"
    done
    if [ -s "$manifest" ]; then
        source_file=$manifest
    else
        source_file="$SHORIN_ROOT/niri-applist.txt"
    fi
    if [ -f "$source_file" ]; then
        while IFS= read -r entry; do
            entry=${entry%%#*}
            entry=$(printf '%s\n' "$entry" | xargs)
            [ -z "$entry" ] || desktop_niri_expect "$phase" \
                "package-target:$entry" desktop_niri_entry_satisfied "$entry"
        done < "$source_file"
    else
        [ "$phase" = check ] && module_drift niri-package-targets ||
            module_verify_failed niri-package-targets
    fi

    if [ -z "${HOME_DIR:-}" ]; then
        [ "$phase" = check ] && module_drift target-home ||
            module_verify_failed target-home
        return
    fi
    desktop_niri_expect "$phase" file:niri-config \
        state_file_nonempty "$HOME_DIR/.config/niri/config.kdl"
    if grep -Fq -- "--autologin $TARGET_USER" \
        /etc/systemd/system/getty@tty1.service.d/autologin.conf 2>/dev/null; then
        desktop_niri_expect "$phase" unit:niri-autostart \
            state_user_unit_enabled "$TARGET_USER" niri-autostart.service \
                default.target
    fi
}

desktop_niri_check() { desktop_niri_inspect check; }

desktop_niri_apply() {
    bash "$SHORIN_ROOT/scripts/modules/desktop-niri/apply.sh"
}

desktop_niri_verify() { desktop_niri_inspect verify; }

module_main desktop-niri "$@"
