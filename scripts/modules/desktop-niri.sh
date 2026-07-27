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
    local phase=$1 entry source_file niri_package_status=0
    local manifest=${SHORIN_PROFILE_DIR:-/etc/shorin-arch-setup}/niri-packages.list

    if [ -f "$manifest" ] && [ -r "$manifest" ]; then
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
    desktop_niri_expect "$phase" file:wallpapers niri_wallpapers_deployed
    desktop_niri_expect "$phase" file:starship-config \
        niri_starship_config_deployed
    desktop_niri_expect "$phase" file:templates niri_templates_deployed
    desktop_niri_expect "$phase" hardware:optional-tools \
        niri_optional_hardware_targets_match
    desktop_niri_expect "$phase" file:niri-config \
        state_file_nonempty "$HOME_DIR/.config/niri/config.kdl"
    desktop_niri_expect "$phase" access:niri-session-files \
        niri_session_files_accessible "$TARGET_USER"
    desktop_niri_expect "$phase" config:niri-quickshell-startup \
        niri_quickshell_startup_satisfied \
            "$HOME_DIR/.config/niri/config.kdl"
    desktop_niri_expect "$phase" config:niri-fcitx5-startup \
        niri_fcitx5_startup_satisfied \
            "$HOME_DIR/.config/niri/config.kdl"
    desktop_niri_expect "$phase" config:niri-path niri_path_satisfied
    desktop_niri_expect "$phase" config:niri-wallpaper-backend \
        niri_wallpaper_backend_satisfied
    desktop_niri_expect "$phase" config:quickshell-wallpaper-backend \
        niri_quickshell_wallpaper_backend_satisfied
    desktop_niri_expect "$phase" config:waypaper-wallpaper-backend \
        niri_waypaper_backend_satisfied
    desktop_niri_expect "$phase" config:niri-bindings niri_bindings_satisfied
    if command -v niri >/dev/null 2>&1; then
        desktop_niri_expect "$phase" config:niri-valid \
            niri_config_valid "$TARGET_USER"
    else
        state_package_present niri || niri_package_status=$?
        if [ "$phase" = check ] && [ "$niri_package_status" -eq 1 ]; then
            module_drift config:niri-validator-missing
        elif [ "$phase" = check ]; then
            module_inspection_failed config:niri-validator-missing
        else
            module_verify_failed config:niri-validator-missing
        fi
    fi
    desktop_niri_expect "$phase" config:fish-env-sources \
        niri_fish_sources_satisfied
    desktop_niri_expect "$phase" config:tty1-niri-session \
        niri_bash_profile_satisfied
    desktop_niri_expect "$phase" legacy:niri-autostart-absent \
        niri_legacy_autostart_absent
    desktop_niri_expect "$phase" config:tty1-autologin \
        niri_autologin_state_satisfied
}

desktop_niri_check() { desktop_niri_inspect check; }

desktop_niri_apply() {
    if [ "${SHORIN_MODE:-install}" = install ]; then
        bash "$SHORIN_ROOT/scripts/modules/storage/checkpoint-apply.sh" || return
    fi
    bash "$SHORIN_ROOT/scripts/modules/desktop-niri/apply.sh"
}

desktop_niri_verify() { desktop_niri_inspect verify; }

module_main desktop-niri "$@"
