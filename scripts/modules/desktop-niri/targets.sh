#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/core.sh"
source "$SHORIN_ROOT/scripts/modules/desktop-niri/config-contract.sh"
source "$SHORIN_ROOT/scripts/modules/desktop-niri/wallpaper-contract.sh"
source "$SHORIN_ROOT/scripts/modules/desktop-niri/awww.sh"
source "$SHORIN_ROOT/scripts/modules/desktop-niri/session-files.sh"
source "$SHORIN_ROOT/scripts/modules/desktop-niri/session-apply.sh"
source "$SHORIN_ROOT/scripts/modules/desktop-niri/desktop-contract.sh"

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
    AUR:nautilus-open-any-terminal
    file-roller
    gnome-keyring
    gst-plugins-base
    gst-plugins-good
    gst-libav
    nautilus
    quickshell
    qt6-wayland
    qt6-multimedia
    bluez-utils
    matugen
    awww
    swayidle
    AUR:swaylock-effects
)

if platform_is_fedora; then
    # Fedora's required session contract contains native package targets.
    # Nautilus' open-terminal extension is an optional Arch/AUR convenience,
    # not a Niri session dependency, so it is intentionally not required on
    # Fedora.  swaylock-effects is represented by Fedora's swaylock package.
    NIRI_REQUIRED_PACKAGE_TARGETS=(
        niri xdg-desktop-portal-gnome xdg-desktop-portal-gtk fuzzel kitty
        firefox libnotify mako polkit-kde ffmpegthumbnailer gvfs-smb
        file-roller gnome-keyring
        gst-plugins-base gst-plugins-good gst-libav nautilus quickshell
        qt6-wayland qt6-multimedia bluez-utils matugen awww swayidle swaylock
    )
fi

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

niri_package_target_canonical() {
    case "$1" in
        awww)
            printf '%s\n' "$1"
            ;;
        polkit-gnome)
            if platform_is_fedora; then printf '%s\n' polkit-kde; else printf '%s\n' "$1"; fi
            ;;
        AUR:wlogout)
            if platform_is_fedora; then printf '%s\n' wlogout; else printf '%s\n' AUR:wlogout-git; fi
            ;;
        # Fedora keeps only targets with a declared native package mapping.
        # These translations are shared by target enumeration, check and
        # apply, so an AUR label cannot leak into a Fedora dnf invocation.
        AUR:wlogout-git)
            if platform_is_fedora; then printf '%s\n' wlogout; else printf '%s\n' "$1"; fi
            ;;
        AUR:ddcutil-service)
            if platform_is_fedora; then printf '%s\n' ddcutil; else printf '%s\n' "$1"; fi
            ;;
        AUR:swaylock-effects)
            if platform_is_fedora; then printf '%s\n' swaylock; else printf '%s\n' "$1"; fi
            ;;
        AUR:ttf-jetbrains-maple-mono-nf-xx-xx)
            if platform_is_fedora; then printf '%s\n' jetbrains-mono-fonts; else printf '%s\n' "$1"; fi
            ;;
        AUR:clipse|AUR:clipse-gui|AUR:python-pywalfox|AUR:waypaper|\
        AUR:niriswitcher|AUR:nautilus-open-any-terminal|\
        AUR:ttf-lxgw-wenkai-screen)
            if platform_is_fedora; then
                warn "Skipping Fedora desktop target without a declared reliable source: $1"
                return 1
            fi
            printf '%s\n' "$1"
            ;;
        *)
            if platform_is_fedora && [[ "$1" == AUR:* ]]; then
                warn "Skipping Fedora desktop target without a declared reliable source: $1"
                return 1
            fi
            printf '%s\n' "$1"
            ;;
    esac
}

# A saved profile records optional choices; it must never replace the required
# package set added by a newer installer version. Canonicalization also migrates
# saved targets whose upstream packaging path is no longer reliable.
niri_all_package_targets() {
    local manifest=$1 list_file=$2 source target key
    local -A seen=()

    if [ -f "$manifest" ] && [ -r "$manifest" ]; then
        source=$manifest
    elif [ -f "$list_file" ] && [ -r "$list_file" ]; then
        source=$list_file
    else
        return 2
    fi

    while IFS= read -r target; do
        [ -n "$target" ] || continue
        if ! target=$(niri_package_target_canonical "$target"); then
            continue
        fi
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
        awww)
            if platform_is_fedora; then
                fedora_awww_satisfied "${TARGET_USER:-}" "${HOME_DIR:-}"
            else
                state_package_present "$target"
            fi
            ;;
        AUR:*) declared_package_target_satisfied "$target" ;;
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
            awww)
                if platform_is_fedora; then
                    fedora_install_awww "${TARGET_USER:-}" "${HOME_DIR:-}"
                else
                    ensure_package "$target"
                fi
                ;;
            AUR:*)
                if platform_is_fedora; then
                    fedora_install_application_target "${target#AUR:}" \
                        "$TARGET_USER" "$HOME_DIR"
                else
                    ensure_aur_package "${target#AUR:}" "$TARGET_USER" "$HOME_DIR"
                fi
                ;;
            flatpak:*) ensure_flatpak "${target#flatpak:}" ;;
            GitHub:*) die "Unsupported GitHub desktop target: $target" ;;
            imagemagic) ensure_package imagemagick ;;
            *) ensure_package "$target" ;;
        esac && niri_package_target_satisfied "$target" && return 0
        warn "Failed to converge desktop target $target (attempt $attempt/3)."
    done
    error "Failed to converge desktop target $target after three attempts."
    return 1
}

niri_quickshell_startup_satisfied() {
    local file=$1

    [ -s "$file" ] || return 1
    # Multiple quickshell instances (for example a separate lockscreen config)
    # are user-owned; only require at least one and no conflicting shells.
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
        END { exit !(quickshell >= 1 && conflicts == 0) }
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
            quickshell=1
            print
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

niri_fcitx5_startup_satisfied() {
    local file=$1

    [ -s "$file" ] || return 1
    awk '
        /^[[:space:]]*spawn(-sh)?-at-startup[[:space:]].*["\/[:space:]]fcitx5([[:space:]&"]|$)/ {
            fcitx++
        }
        END { exit !(fcitx == 1) }
    ' "$file"
}

ensure_niri_fcitx5_startup() {
    local file=$1 user=$2 temporary mode group

    require_writable_mode || return
    [ -s "$file" ] || die "Niri config is missing or empty: $file"
    niri_fcitx5_startup_satisfied "$file" && return 0

    temporary=$(mktemp)
    awk '
        /^[[:space:]]*spawn(-sh)?-at-startup[[:space:]].*["\/[:space:]]fcitx5([[:space:]&"]|$)/ {
            if (!fcitx) {
                print
                fcitx=1
            }
            next
        }
        { print }
        END {
            if (!fcitx) print "spawn-at-startup \"fcitx5\""
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
    niri_fcitx5_startup_satisfied "$file"
}
