#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/core.sh"

# Required desktop targets are independent of the user's optional package
# selection. Keep their source prefix so check, apply, and verify agree.
NIRI_REQUIRED_PACKAGE_TARGETS=(
    niri
    xdg-desktop-portal-gnome
    xdg-desktop-portal-gtk
    fuzzel
    kitty
    firefox
    libnotify
    mako
    polkit-gnome
    ffmpegthumbnailer
    gvfs-smb
    nautilus-open-any-terminal
    file-roller
    gnome-keyring
    gst-plugins-base
    gst-plugins-good
    gst-libav
    nautilus
    quickshell
    qt6-wayland
    matugen
    awww
    swayidle
    swaylock-effects
)

desktop_niri_contract_init() {
    NIRI_FIREFOX_POLICY_FILE=${NIRI_FIREFOX_POLICY_FILE:-/etc/firefox/policies/policies.json}
    NIRI_NAUTILUS_VENDOR_FILE=${NIRI_NAUTILUS_VENDOR_FILE:-/usr/share/applications/org.gnome.Nautilus.desktop}
    NIRI_NAUTILUS_OVERRIDE_FILE=${NIRI_NAUTILUS_OVERRIDE_FILE:-$HOME_DIR/.local/share/applications/org.gnome.Nautilus.desktop}
    NIRI_GNOME_TERMINAL_LINK=${NIRI_GNOME_TERMINAL_LINK:-$HOME_DIR/.local/bin/gnome-terminal}
    NIRI_GNOME_TERMINAL_TARGET=${NIRI_GNOME_TERMINAL_TARGET:-/usr/bin/kitty}
    NIRI_PORTAL_CONFIG_FILE=${NIRI_PORTAL_CONFIG_FILE:-$HOME_DIR/.config/xdg-desktop-portal/portals.conf}
    NIRI_GTK4_DIR=${NIRI_GTK4_DIR:-$HOME_DIR/.config/gtk-4.0}
    NIRI_GTK_THEME_DIR=${NIRI_GTK_THEME_DIR:-$HOME_DIR/.themes/adw-gtk3-dark/gtk-4.0}
}

niri_firefox_policy_contract() {
    printf '%s\n' '{ "policies": { "Extensions": { "Install": ["https://addons.mozilla.org/firefox/downloads/latest/pywalfox/latest.xpi"] } } }'
}

niri_portal_config_contract() {
    printf '[preferred]\ndefault=gtk\n'
}

niri_managed_text_matches() {
    local file=$1 renderer=$2 actual expected

    [ -f "$file" ] || return 1
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

    [ -r "$NIRI_NAUTILUS_VENDOR_FILE" ] || return 2
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
    [ -x "$NIRI_GNOME_TERMINAL_TARGET" ] || return 2
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

niri_optional_hardware_targets_match() {
    local package_status=0

    state_package_present ddcutil || package_status=$?
    case "$package_status" in
        0)
            state_user_in_group "$TARGET_USER" i2c &&
                state_line_present /etc/modules-load.d/i2c-dev.conf i2c-dev ||
                return 1
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

niri_required_package_targets() {
    printf '%s\n' "${NIRI_REQUIRED_PACKAGE_TARGETS[@]}"
}

niri_package_entries_from_file() {
    local file=$1

    [ -f "$file" ] && [ -r "$file" ] || return 2
    awk '
        /^[[:space:]]*(#|$)/ { next }
        {
            sub(/[[:space:]]+#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (length) print
        }
    ' "$file"
}

# A saved profile records optional choices; it must never replace the required
# package set added by a newer installer version.
niri_all_package_targets() {
    local manifest=$1 list_file=$2 source target key
    local -A seen=()

    if [ -s "$manifest" ]; then
        source=$manifest
    elif [ -f "$list_file" ] && [ -r "$list_file" ]; then
        source=$list_file
    else
        return 2
    fi

    while IFS= read -r target; do
        [ -n "$target" ] || continue
        niri_package_target_is_obsolete "$target" && continue
        key=$(niri_package_target_name "$target")
        [ -z "${seen[$key]:-}" ] || continue
        seen["$key"]=1
        printf '%s\n' "$target"
    done < <(
        niri_required_package_targets
        niri_package_entries_from_file "$source"
    )
}

niri_package_target_name() {
    case "$1" in
        AUR:*) printf '%s\n' "${1#AUR:}" ;;
        flatpak:*) printf '%s\n' "${1#flatpak:}" ;;
        imagemagic) printf '%s\n' imagemagick ;;
        *) printf '%s\n' "$1" ;;
    esac
}

niri_package_target_is_obsolete() {
    case "$(niri_package_target_name "$1")" in
        waybar|waybar-niri-taskbar-git|waybar-module-pacman-updates-git)
            return 0
            ;;
        *) return 1 ;;
    esac
}

niri_package_target_satisfied() {
    local target=$1

    case "$target" in
        AUR:*) state_package_present "${target#AUR:}" ;;
        flatpak:*) state_flatpak_present "${target#flatpak:}" ;;
        GitHub:*) return 1 ;;
        imagemagic) state_package_present imagemagick ;;
        *) state_package_present "$target" ;;
    esac
}

ensure_niri_package_target() {
    local target=$1 attempt

    niri_package_target_satisfied "$target" && return 0
    for attempt in 1 2 3; do
        [ "$attempt" -eq 1 ] || sleep 3
        case "$target" in
            AUR:*) ensure_aur_package "${target#AUR:}" "$TARGET_USER" "$HOME_DIR" ;;
            flatpak:*) ensure_flatpak "${target#flatpak:}" ;;
            GitHub:*) die "Unsupported GitHub desktop target: $target" ;;
            imagemagic) ensure_package imagemagick ;;
            *) ensure_package "$target" ;;
        esac && niri_package_target_satisfied "$target" && return 0
        warn "Failed to converge desktop target $target (attempt $attempt/3)."
    done
    die "Failed to converge desktop target $target after three attempts."
}

niri_quickshell_startup_satisfied() {
    local file=$1

    [ -s "$file" ] || return 1
    awk '
        /^[[:space:]]*spawn(-sh)?-at-startup[[:space:]]+"quickshell([[:space:]&"]|$)/ {
            quickshell++
        }
        /^[[:space:]]*spawn(-sh)?-at-startup[[:space:]]+"(waybar|ags run)([[:space:]&"]|$)/ {
            conflicts++
        }
        /^[[:space:]]*spawn-at-startup[[:space:]]+"ags"[[:space:]]+"run"([[:space:]]|$)/ {
            conflicts++
        }
        END { exit !(quickshell == 1 && conflicts == 0) }
    ' "$file"
}

ensure_niri_quickshell_startup() {
    local file=$1 user=$2 temporary mode group

    require_writable_mode || return
    [ -s "$file" ] || die "Niri config is missing or empty: $file"
    niri_quickshell_startup_satisfied "$file" && return 0

    temporary=$(mktemp)
    awk '
        function indentation(line) {
            match(line, /^[[:space:]]*/)
            return substr(line, 1, RLENGTH)
        }
        /^[[:space:]]*spawn(-sh)?-at-startup[[:space:]]+"quickshell([[:space:]&"]|$)/ {
            if (!quickshell) {
                print
                quickshell=1
            }
            next
        }
        /^[[:space:]]*spawn(-sh)?-at-startup[[:space:]]+"(waybar|ags run)([[:space:]&"]|$)/ ||
        /^[[:space:]]*spawn-at-startup[[:space:]]+"ags"[[:space:]]+"run"([[:space:]]|$)/ {
            prefix=indentation($0)
            print prefix "// shorin: disabled for QuickShell: " substr($0, length(prefix) + 1)
            next
        }
        { print }
        END {
            if (!quickshell) print "spawn-at-startup \"quickshell\""
        }
    ' "$file" > "$temporary"

    mode=$(stat -c '%a' "$file")
    group=$(id -gn "$user")
    if ! install_if_changed "$temporary" "$file" "$mode"; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
    chown "$user:$group" "$file"
    niri_quickshell_startup_satisfied "$file"
}

niri_autostart_unit_satisfied() {
    local user=$1 home=$2
    local unit="$home/.config/systemd/user/niri-autostart.service"
    local link="$home/.config/systemd/user/default.target.wants/niri-autostart.service"

    [ -f "$unit" ] && [ -L "$link" ] || return 1
    [ "$(readlink "$link")" = ../niri-autostart.service ] || return 1
    grep -Fqx 'ExecStart=/usr/bin/niri-session' "$unit" &&
        grep -Fqx 'Restart=on-failure' "$unit" &&
        grep -Fqx 'WantedBy=default.target' "$unit" &&
        [ "$(stat -c '%U' "$unit")" = "$user" ]
}
