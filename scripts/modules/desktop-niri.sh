#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"
source "$SHORIN_ROOT/scripts/modules/desktop-niri/targets.sh"

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
    local phase=$1 entry source_file
    local manifest=${SHORIN_PROFILE_DIR:-/etc/shorin-arch-setup}/niri-packages.list

    if [ -s "$manifest" ]; then
        source_file=$manifest
    else
        source_file="$SHORIN_ROOT/niri-applist.txt"
    fi
    if [ -f "$source_file" ] && [ -r "$source_file" ]; then
        while IFS= read -r entry; do
            desktop_niri_expect "$phase" "package-target:$entry" \
                niri_package_target_satisfied "$entry"
        done < <(niri_all_package_targets "$manifest" \
            "$SHORIN_ROOT/niri-applist.txt")
    else
        [ "$phase" = check ] && module_drift niri-package-targets ||
            module_verify_failed niri-package-targets
    fi

    if [ -z "${HOME_DIR:-}" ]; then
        [ "$phase" = check ] && module_drift target-home ||
            module_verify_failed target-home
        return
    fi
    desktop_niri_contract_init
    desktop_niri_expect "$phase" file:firefox-policy \
        niri_firefox_policy_matches
    desktop_niri_expect "$phase" file:nautilus-user-override \
        niri_nautilus_override_matches
    desktop_niri_expect "$phase" link:user-gnome-terminal \
        niri_user_terminal_link_matches
    desktop_niri_expect "$phase" file:xdg-desktop-portal \
        niri_portal_config_matches
    desktop_niri_expect "$phase" link:gtk4-theme niri_gtk_links_match
    desktop_niri_expect "$phase" hardware:optional-tools \
        niri_optional_hardware_targets_match
    desktop_niri_expect "$phase" file:niri-config \
        state_file_nonempty "$HOME_DIR/.config/niri/config.kdl"
    desktop_niri_expect "$phase" config:niri-quickshell-startup \
        niri_quickshell_startup_satisfied \
            "$HOME_DIR/.config/niri/config.kdl"
    if grep -Fq -- "--autologin $TARGET_USER" \
        /etc/systemd/system/getty@tty1.service.d/autologin.conf 2>/dev/null; then
        desktop_niri_expect "$phase" unit:niri-autostart \
            niri_autostart_unit_satisfied "$TARGET_USER" "$HOME_DIR"
    fi
}

desktop_niri_check() { desktop_niri_inspect check; }

desktop_niri_apply() {
    bash "$SHORIN_ROOT/scripts/modules/desktop-niri/apply.sh"
}

desktop_niri_verify() { desktop_niri_inspect verify; }

module_main desktop-niri "$@"
