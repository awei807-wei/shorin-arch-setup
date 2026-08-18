#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

desktop_niri_contract_init() {
    local previous_home=${NIRI_CONTRACT_HOME_DIR:-} variable value

    # Tests and repair callers may switch HOME_DIR in one shell (for example
    # when validating a real Niri fixture).  Recompute paths that still point
    # below the previous home instead of reporting a stale wallpaper/Fish
    # target as drift.  Explicit paths outside the old home are preserved.
    if [ -n "$previous_home" ] && [ "$previous_home" != "$HOME_DIR" ]; then
        for variable in \
            NIRI_FIREFOX_POLICY_FILE NIRI_NAUTILUS_OVERRIDE_FILE \
            NIRI_GNOME_TERMINAL_LINK NIRI_PORTAL_CONFIG_FILE NIRI_GTK4_DIR \
            NIRI_GTK_THEME_DIR \
            NIRI_WALLPAPER_DIR NIRI_DEFAULT_WALLPAPER_FILE \
            NIRI_STARSHIP_CONFIG_FILE NIRI_MATUGEN_CONFIG_FILE \
            NIRI_MATUGEN_STARSHIP_TEMPLATE_FILE NIRI_WAYPAPER_CONFIG_FILE \
            NIRI_TEMPLATES_DIR NIRI_LOCAL_BIN NIRI_CONFIG_FILE \
            NIRI_BINDS_FILE NIRI_QUICKSHELL_DIR NIRI_DESKTOP_STATE_DIR \
            NIRI_QUICKSHELL_BACKUP_DIR NIRI_QUICKSHELL_SOURCE_STATE_FILE \
            NIRI_FISH_CONFIG_FILE NIRI_FISH_GUARD_FILE NIRI_FISH_RUSTUP_FILE \
            NIRI_FISH_LOCAL_ENV_FILE NIRI_BASH_PROFILE NIRI_LEGACY_UNIT \
            NIRI_LEGACY_UNIT_LINK NIRI_LOCKSCREEN_SCRIPT_FILE \
            NIRI_FEDORA_WALLPAPER_SESSION_FILE \
            NIRI_FEDORA_AWWW_QUERY_WRAPPER_FILE \
            NIRI_FEDORA_LSFG_ENV_FILE NIRI_FEDORA_LSFG_WRAPPER_FILE \
            NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_AUTOSTART_FILE \
            NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_MASK_FILE \
            NIRI_FEDORA_DRKONQI_MASK_FILE \
            NIRI_WAYLAND_SESSION_FILE \
            NIRI_STATE_HOME NIRI_SHORIN_STATE_DIR; do
            value=${!variable:-}
            case "$value" in
                "$previous_home"|"$previous_home"/*) unset "$variable" ;;
            esac
        done
    fi
    NIRI_CONTRACT_HOME_DIR=$HOME_DIR
    export NIRI_CONTRACT_HOME_DIR
    NIRI_FIREFOX_POLICY_FILE=${NIRI_FIREFOX_POLICY_FILE:-/etc/firefox/policies/policies.json}
    NIRI_NAUTILUS_VENDOR_FILE=${NIRI_NAUTILUS_VENDOR_FILE:-/usr/share/applications/org.gnome.Nautilus.desktop}
    NIRI_NAUTILUS_OVERRIDE_FILE=${NIRI_NAUTILUS_OVERRIDE_FILE:-$HOME_DIR/.local/share/applications/org.gnome.Nautilus.desktop}
    NIRI_GNOME_TERMINAL_LINK=${NIRI_GNOME_TERMINAL_LINK:-$HOME_DIR/.local/bin/gnome-terminal}
    NIRI_GNOME_TERMINAL_TARGET=${NIRI_GNOME_TERMINAL_TARGET:-/usr/bin/kitty}
    NIRI_PORTAL_CONFIG_FILE=${NIRI_PORTAL_CONFIG_FILE:-$HOME_DIR/.config/xdg-desktop-portal/portals.conf}
    NIRI_GTK4_DIR=${NIRI_GTK4_DIR:-$HOME_DIR/.config/gtk-4.0}
    NIRI_GTK_THEME_DIR=${NIRI_GTK_THEME_DIR:-$HOME_DIR/.themes/adw-gtk3-dark/gtk-4.0}
    NIRI_WALLPAPER_DIR=${NIRI_WALLPAPER_DIR:-$HOME_DIR/Pictures/Wallpapers}
    NIRI_DEFAULT_WALLPAPER_FILE=${NIRI_DEFAULT_WALLPAPER_FILE:-$NIRI_WALLPAPER_DIR/black-and-white-3840x2160-21293.jpg}
    NIRI_STARSHIP_CONFIG_FILE=${NIRI_STARSHIP_CONFIG_FILE:-$HOME_DIR/.config/starship.toml}
    NIRI_MATUGEN_CONFIG_FILE=${NIRI_MATUGEN_CONFIG_FILE:-$HOME_DIR/.config/matugen/config.toml}
    NIRI_MATUGEN_STARSHIP_TEMPLATE_FILE=${NIRI_MATUGEN_STARSHIP_TEMPLATE_FILE:-$HOME_DIR/.config/matugen/templates/starship-colors.toml}
    NIRI_WAYPAPER_CONFIG_FILE=${NIRI_WAYPAPER_CONFIG_FILE:-$HOME_DIR/.config/waypaper/config.ini}
    NIRI_TEMPLATES_DIR=${NIRI_TEMPLATES_DIR:-$HOME_DIR/Templates}
    NIRI_AUTOLOGIN_FILE=${NIRI_AUTOLOGIN_FILE:-/etc/systemd/system/getty@tty1.service.d/autologin.conf}
    NIRI_WAYLAND_SESSION_FILE=${NIRI_WAYLAND_SESSION_FILE:-/usr/share/wayland-sessions/niri.desktop}
    NIRI_DISPLAY_MANAGER_UNIT=${NIRI_DISPLAY_MANAGER_UNIT:-display-manager.service}
    NIRI_STATE_HOME=${NIRI_STATE_HOME:-${XDG_STATE_HOME:-$HOME_DIR/.local/state}}
    NIRI_SHORIN_STATE_DIR=${NIRI_SHORIN_STATE_DIR:-$NIRI_STATE_HOME/shorin-arch-setup}
    niri_session_contract_init
}

niri_detect_display_manager() {
    local dm

    # Fedora's display manager is selected by the systemd alias, not by a
    # package-name guess.  Keep the old package probe for Arch, where it is
    # still used to decide whether tty1 autologin is appropriate.
    if platform_is_fedora; then
        niri_fedora_display_manager_provider && return 0
        return 1
    fi

    for dm in gdm sddm lightdm lxdm slim xorg-xdm ly greetd; do
        if package_is_installed "$dm"; then
            printf '%s\n' "$dm"
            return 0
        fi
    done
    return 1
}

niri_autologin_contract() {
    printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --noreset --noclear --autologin %s - ${TERM}\n' "$1"
}

niri_autologin_managed_user() {
    local line user actual expected

    [ -f "$NIRI_AUTOLOGIN_FILE" ] && [ ! -L "$NIRI_AUTOLOGIN_FILE" ] || return 1
    line=$(sed -n '3p' "$NIRI_AUTOLOGIN_FILE")
    user=$(printf '%s\n' "$line" | sed -n \
        's|^ExecStart=-/sbin/agetty --noreset --noclear --autologin \([^ ]*\) - ${TERM}$|\1|p')
    [ -n "$user" ] || return 1
    actual=$(< "$NIRI_AUTOLOGIN_FILE")
    expected=$(niri_autologin_contract "$user")
    [ "$actual" = "$expected" ] || return 1
    printf '%s\n' "$user"
}

niri_autologin_matches_target() {
    local actual expected

    [ -f "$NIRI_AUTOLOGIN_FILE" ] || return 1
    actual=$(< "$NIRI_AUTOLOGIN_FILE")
    expected=$(niri_autologin_contract "$TARGET_USER")
    [ "$actual" = "$expected" ]
}

niri_autologin_state_satisfied() {
    local managed_user

    # Fedora always enters Niri through the display manager.  An absent
    # autologin drop-in is therefore the desired state; any Shorin-owned old
    # drop-in is removed by ensure_niri_autologin_state below.  A non-Shorin
    # drop-in is user-owned and is intentionally preserved without turning
    # every Fedora repair into permanent drift.
    if platform_is_fedora; then
        if [ ! -e "$NIRI_AUTOLOGIN_FILE" ] && [ ! -L "$NIRI_AUTOLOGIN_FILE" ]; then
            return 0
        fi
        niri_autologin_managed_user >/dev/null && return 1
        return 0
    fi
    managed_user=$(niri_autologin_managed_user) || return 0
    if niri_detect_display_manager >/dev/null; then
        return 1
    fi
    [ "$managed_user" = "$TARGET_USER" ]
}

ensure_niri_autologin_state() {
    local user=$1 skip=$2 temporary

    if platform_is_fedora; then
        # Never create a tty fallback on Fedora.  Exact Shorin-generated
        # content is a constrained migration boundary; arbitrary drop-ins,
        # including bare niri commands, are left untouched and reported as
        # drift by the formal-session contract.
        if niri_autologin_managed_user >/dev/null; then
            rm -f "$NIRI_AUTOLOGIN_FILE"
            systemctl daemon-reload
        fi
        return 0
    fi
    if [ "$skip" = true ]; then
        if niri_autologin_managed_user >/dev/null; then
            rm -f "$NIRI_AUTOLOGIN_FILE"
            systemctl daemon-reload
        fi
        return 0
    fi
    niri_autologin_matches_target && return 0
    if [ -e "$NIRI_AUTOLOGIN_FILE" ] &&
        ! niri_autologin_managed_user >/dev/null; then
        return 0
    fi
    temporary=$(mktemp)
    niri_autologin_contract "$user" > "$temporary"
    install_if_changed "$temporary" "$NIRI_AUTOLOGIN_FILE" 644
    rm -f "$temporary"
    systemctl daemon-reload
    niri_autologin_matches_target
}

niri_firefox_policy_contract() {
    printf '%s\n' '{ "policies": { "Extensions": { "Install": ["https://addons.mozilla.org/firefox/downloads/latest/pywalfox/latest.xpi"] } } }'
}

niri_portal_config_contract() {
    printf '[preferred]\ndefault=gtk\n'
}

niri_managed_text_matches() {
    local file=$1 renderer=$2 actual expected

    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    actual=$(< "$file")
    expected=$($renderer)
    [ "$actual" = "$expected" ]
}

niri_firefox_policy_matches() {
    niri_managed_text_matches "$NIRI_FIREFOX_POLICY_FILE" \
        niri_firefox_policy_contract
}

niri_portal_config_matches() {
    niri_managed_text_matches "$NIRI_PORTAL_CONFIG_FILE" \
        niri_portal_config_contract
}

niri_nautilus_exec_prefix() {
    local gpu_count=0 has_nvidia=0

    if command -v lspci >/dev/null 2>&1; then
        gpu_count=$(lspci | awk 'BEGIN { IGNORECASE=1 } /vga|3d/ { count++ } END { print count + 0 }')
        has_nvidia=$(lspci | awk 'BEGIN { IGNORECASE=1 } /nvidia/ { count++ } END { print count + 0 }')
    fi
    if [ "$gpu_count" -gt 1 ] && [ "$has_nvidia" -gt 0 ]; then
        printf '%s\n' 'env GSK_RENDERER=gl GTK_IM_MODULE=fcitx'
    else
        printf '%s\n' 'env GTK_IM_MODULE=fcitx'
    fi
}

niri_nautilus_override_contract() {
    local prefix

    [ -r "$NIRI_NAUTILUS_VENDOR_FILE" ] || return 1
    prefix=$(niri_nautilus_exec_prefix)
    awk -v prefix="$prefix" '
        /^\[Desktop Entry\]$/ {
            print
            print "DBusActivatable=false"
            in_desktop=1
            next
        }
        /^\[/ { in_desktop=0 }
        in_desktop && /^DBusActivatable=/ { next }
        /^Exec=/ {
            print "Exec=" prefix " " substr($0, 6)
            next
        }
        { print }
    ' "$NIRI_NAUTILUS_VENDOR_FILE"
}

niri_nautilus_override_matches() {
    local actual expected status=0

    [ -f "$NIRI_NAUTILUS_OVERRIDE_FILE" ] || return 1
    actual=$(< "$NIRI_NAUTILUS_OVERRIDE_FILE")
    expected=$(niri_nautilus_override_contract) || status=$?
    [ "$status" -eq 0 ] || return "$status"
    [ "$actual" = "$expected" ] &&
        [ "$(stat -c '%U' "$NIRI_NAUTILUS_OVERRIDE_FILE")" = "$TARGET_USER" ]
}

niri_user_terminal_link_matches() {
    [ -x "$NIRI_GNOME_TERMINAL_TARGET" ] || return 1
    [ -L "$NIRI_GNOME_TERMINAL_LINK" ] &&
        [ "$(readlink "$NIRI_GNOME_TERMINAL_LINK")" = "$NIRI_GNOME_TERMINAL_TARGET" ] &&
        [ "$(stat -c '%U' "$NIRI_GNOME_TERMINAL_LINK")" = "$TARGET_USER" ]
}

niri_gtk_links_match() {
    [ -f "$NIRI_GTK_THEME_DIR/gtk.css" ] || return 1
    [ -f "$NIRI_GTK_THEME_DIR/gtk-dark.css" ] || return 1
    [ -L "$NIRI_GTK4_DIR/gtk.css" ] &&
        [ "$(readlink "$NIRI_GTK4_DIR/gtk.css")" = "$NIRI_GTK_THEME_DIR/gtk.css" ] &&
        [ -L "$NIRI_GTK4_DIR/gtk-dark.css" ] &&
        [ "$(readlink "$NIRI_GTK4_DIR/gtk-dark.css")" = "$NIRI_GTK_THEME_DIR/gtk-dark.css" ]
}

niri_wallpapers_deployed() {
    niri_path_is_safe_no_symlink "$NIRI_WALLPAPER_DIR" || return 1
    [ -d "$NIRI_WALLPAPER_DIR" ] &&
        [ "$(stat -c '%U' "$NIRI_WALLPAPER_DIR")" = "$TARGET_USER" ] &&
        [ -f "$NIRI_DEFAULT_WALLPAPER_FILE" ] &&
        [ ! -L "$NIRI_DEFAULT_WALLPAPER_FILE" ] &&
        [ -s "$NIRI_DEFAULT_WALLPAPER_FILE" ] &&
        [ "$(stat -c '%U' "$NIRI_DEFAULT_WALLPAPER_FILE")" = "$TARGET_USER" ]
}

niri_wallpaper_directory_satisfied() {
    local user=${1:-$TARGET_USER}

    niri_path_is_safe_no_symlink "$NIRI_WALLPAPER_DIR" || return 1
    [ -d "$NIRI_WALLPAPER_DIR" ] && [ ! -L "$NIRI_WALLPAPER_DIR" ] || return 1
    [ "$(stat -c '%u' "$NIRI_WALLPAPER_DIR")" -eq "$(id -u "$user")" ] ||
        return 1
    niri_run_as_user "$user" test -r "$NIRI_WALLPAPER_DIR" || return 1
    niri_run_as_user "$user" test -w "$NIRI_WALLPAPER_DIR"
}

niri_starship_config_deployed() {
    [ -f "$NIRI_STARSHIP_CONFIG_FILE" ] &&
        [ -s "$NIRI_STARSHIP_CONFIG_FILE" ] &&
        [ ! -L "$NIRI_STARSHIP_CONFIG_FILE" ] &&
        [ "$(stat -c '%U' "$NIRI_STARSHIP_CONFIG_FILE")" = "$TARGET_USER" ]
}

niri_matugen_starship_output_disabled() {
    [ -f "$NIRI_MATUGEN_CONFIG_FILE" ] || return 0
    ! grep -Eq \
        '^[[:space:]]*\[templates[.]starship\][[:space:]]*(#.*)?$' \
        "$NIRI_MATUGEN_CONFIG_FILE"
}

niri_matugen_starship_template_absent() {
    [ ! -e "$NIRI_MATUGEN_STARSHIP_TEMPLATE_FILE" ] &&
        [ ! -L "$NIRI_MATUGEN_STARSHIP_TEMPLATE_FILE" ]
}

niri_templates_deployed() {
    [ -f "$NIRI_TEMPLATES_DIR/new" ] &&
        [ ! -L "$NIRI_TEMPLATES_DIR/new" ] &&
        [ -f "$NIRI_TEMPLATES_DIR/new.sh" ] &&
        [ ! -L "$NIRI_TEMPLATES_DIR/new.sh" ] &&
        [ -s "$NIRI_TEMPLATES_DIR/new.sh" ]
}

niri_optional_hardware_targets_match() {
    local package_status=0

    state_package_present ddcutil || package_status=$?
    case "$package_status" in
        0)
            if platform_is_fedora; then
                # Fedora's ddcutil package relies on udev permissions rather
                # than an Arch-style i2c group and modules-load override.
                :
            else
                state_user_in_group "$TARGET_USER" i2c &&
                    state_line_present /etc/modules-load.d/i2c-dev.conf i2c-dev ||
                    return 1
            fi
            ;;
        1) ;;
        *) return "$package_status" ;;
    esac

    package_status=0
    state_package_present swayosd || package_status=$?
    case "$package_status" in
        0)
            state_service_enabled swayosd-libinput-backend.service &&
                state_service_active swayosd-libinput-backend.service
            ;;
        1) return 0 ;;
        *) return "$package_status" ;;
    esac
}
