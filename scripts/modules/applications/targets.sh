#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/core.sh"

if [ -z "${APPLICATION_MANIFEST:-}" ]; then
    APPLICATION_MANIFEST="${SHORIN_PROFILE_DIR:-/etc/shorin-arch-setup}/applications.list"
fi
LAZYVIM_PACKAGES=(neovim ripgrep fd ttf-jetbrains-mono-nerd git)
WINE_CONFIG_PACKAGES=(wine wine-gecko wine-mono)
LUTRIS_CONFIG_PACKAGES=(
    alsa-plugins giflib glfw gst-plugins-base-libs lib32-alsa-plugins
    lib32-giflib lib32-gst-plugins-base-libs lib32-gtk3
    lib32-libjpeg-turbo lib32-libva lib32-mpg123 lib32-openal
    libjpeg-turbo libva libxslt mpg123 openal ttf-liberation
)
if platform_is_fedora; then
    WINE_CONFIG_PACKAGES=(wine wine-mono mingw32-wine-gecko mingw64-wine-gecko)
    LUTRIS_CONFIG_PACKAGES=(
        alsa-plugins-pulseaudio giflib glfw gstreamer1-plugins-base gtk3
        libjpeg-turbo libva libxslt mpg123 openal ttf-liberation
    )
fi
APPLICATION_DESKTOP_DIR=${APPLICATION_DESKTOP_DIR:-/usr/share/applications}
WINDOWS_FONT_SOURCE=${WINDOWS_FONT_SOURCE:-$SHORIN_ROOT/resources/windows-sim-fonts}
FIREFOX_DEFAULT_SOURCE=${FIREFOX_DEFAULT_SOURCE:-$SHORIN_ROOT/resources/firefox}
FOCUS_SHIFT_REPO_URL=https://github.com/awei807-wei/FocusShift.git
NIRI_CLIP_REPO_URL=https://github.com/awei807-wei/niri-clip.git
FOCUS_SHIFT_COMMIT=cb841ebd12db77517dfe60ab0c980cf7d55ad788
NIRI_CLIP_COMMIT=81daa7b8b2044765a562e8fe30b3e7e3c10576e2
LAZYVIM_STARTER_COMMIT=803bc181d7c0d6d5eeba9274d9be49b287294d99
GITHUB_PROVENANCE_DIR=${GITHUB_PROVENANCE_DIR:-}
source "$SHORIN_ROOT/scripts/modules/applications/vicinae-contract.sh"

application_entries_from_file() {
    local file=$1

    [ -f "$file" ] && [ -r "$file" ] || return 2
    awk '
        /^[[:space:]]*(#|$)/ { next }
        {
            sub(/[[:space:]]+#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (tolower($0) == "lazyvim") $0="lazyvim"
            if (length) print
        }
    ' "$file"
}

application_manifest_entries() {
    application_entries_from_file "$APPLICATION_MANIFEST"
}

lazyvim_config_satisfied() {
    local config_dir="$HOME_DIR/.config/nvim"
    local provenance="$config_dir/.shorin-starter-commit"

    [ -s "$config_dir/init.lua" ] &&
        [ -s "$config_dir/lua/config/lazy.lua" ] || return 1
    [ ! -e "$provenance" ] ||
        [ "$(< "$provenance")" = "$LAZYVIM_STARTER_COMMIT" ]
}

lazyvim_target_satisfied() {
    application_packages_present "${LAZYVIM_PACKAGES[@]}" || return
    lazyvim_config_satisfied
}

application_packages_present() {
    local package

    for package in "$@"; do
        if platform_is_fedora && fedora_application_provider_target "$package"; then
            fedora_application_target_satisfied "$package" \
                "${TARGET_USER:-}" "${HOME_DIR:-}" || return
        else
            state_package_present "$package" || return
        fi
    done
}

wine_config_satisfied() {
    local font

    application_packages_present "${WINE_CONFIG_PACKAGES[@]}" || return
    [ -d "$HOME_DIR/.wine" ] || return 1
    [ -d "$WINDOWS_FONT_SOURCE" ] || return 0
    while IFS= read -r -d '' font; do
        [ -f "$HOME_DIR/.wine/drive_c/windows/Fonts/$(basename "$font")" ] ||
            return 1
    done < <(find "$WINDOWS_FONT_SOURCE" -maxdepth 1 -type f -print0)
}

lutris_config_satisfied() {
    application_packages_present "${LUTRIS_CONFIG_PACKAGES[@]}"
}

firefox_defaults_satisfied() {
    local source relative

    [ -d "$FIREFOX_DEFAULT_SOURCE" ] || return 0
    while IFS= read -r -d '' source; do
        relative=${source#"$FIREFOX_DEFAULT_SOURCE"/}
        [ -e "$HOME_DIR/.mozilla/$relative" ] || return 1
    done < <(find "$FIREFOX_DEFAULT_SOURCE" -type f -print0)
}

steam_native_locale_satisfied() {
    local desktop_file="$APPLICATION_DESKTOP_DIR/steam.desktop"

    [ -f "$desktop_file" ] || return 1
    awk '
        /^Exec=env LANG=zh_CN.UTF-8 (\/usr\/bin\/steam|steam)([[:space:]%]|$)/ {
            patched=1
        }
        /^Exec=(\/usr\/bin\/steam|steam)([[:space:]%]|$)/ { unpatched=1 }
        END { exit(patched && !unpatched ? 0 : 1) }
    ' "$desktop_file"
}

steam_flatpak_locale_satisfied() {
    if platform_is_fedora; then
        fedora_flatpak_desktop_export_satisfied \
            com.valvesoftware.Steam "${HOME_DIR:-}" || return 1
        fedora_flatpak_override_satisfied com.valvesoftware.Steam
        return
    fi
    command -v flatpak >/dev/null 2>&1 || return 2
    flatpak override --system --show com.valvesoftware.Steam 2>/dev/null |
        grep -Fqx 'LANG=zh_CN.UTF-8'
}

github_provenance_satisfied() {
    local app=$1 source_dir=$2 binary=$3
    local provenance_dir=${GITHUB_PROVENANCE_DIR:-$HOME_DIR/.local/share/shorin-arch-setup/github}
    local provenance="$provenance_dir/$app.build" checkout_head checkout_status
    local recorded_app recorded_commit recorded_sha binary_sha status=0

    [ -x "$binary" ] && [ -s "$provenance" ] || return 1
    checkout_head=$(state_git_command "$source_dir" "$TARGET_USER" "$HOME_DIR" \
        rev-parse HEAD 2>/dev/null) || status=$?
    [ "$status" -eq 0 ] || return "$status"
    checkout_status=$(state_git_command "$source_dir" "$TARGET_USER" "$HOME_DIR" \
        status --porcelain 2>/dev/null) || status=$?
    [ "$status" -eq 0 ] || return "$status"
    [ -z "$checkout_status" ] || return 1
    recorded_app=$(awk -F= '$1 == "app" { print substr($0, 5) }' "$provenance")
    recorded_commit=$(awk -F= '$1 == "commit" { print substr($0, 8) }' "$provenance")
    recorded_sha=$(awk -F= '$1 == "sha256" { print substr($0, 8) }' "$provenance")
    binary_sha=$(sha256sum "$binary" 2>/dev/null | awk '{ print $1 }') || return 1

    [ "$recorded_app" = "$app" ] &&
        [ "$recorded_commit" = "$checkout_head" ] &&
        [ "$recorded_sha" = "$binary_sha" ]
}

github_application_satisfied() {
    local app=$1 source_dir="$HOME_DIR/.local/src/$1"
    local binary="$HOME_DIR/.local/bin/$1"

    case "$app" in
        focus-shift)
            state_git_checkout "$source_dir" "$FOCUS_SHIFT_REPO_URL" main \
                "$FOCUS_SHIFT_COMMIT" "$TARGET_USER" "$HOME_DIR" &&
                github_provenance_satisfied "$app" "$source_dir" "$binary"
            ;;
        niri-clip)
            state_git_checkout "$source_dir" "$NIRI_CLIP_REPO_URL" main \
                "$NIRI_CLIP_COMMIT" "$TARGET_USER" "$HOME_DIR" &&
                github_provenance_satisfied "$app" "$source_dir" "$binary" &&
                state_file_matches \
                    "$source_dir/systemd/niri-clip.service" \
                    "$HOME_DIR/.config/systemd/user/niri-clip.service" &&
                state_user_unit_enabled "$TARGET_USER" niri-clip.service \
                    graphical-session.target
            ;;
        *) return 1 ;;
    esac
}

application_nodisplay_files() {
    case "$1" in
        btop) printf '%s\n' "$APPLICATION_DESKTOP_DIR/btop.desktop" ;;
        lazyvim|neovim) printf '%s\n' "$APPLICATION_DESKTOP_DIR/nvim.desktop" ;;
        mpv) printf '%s\n' "$APPLICATION_DESKTOP_DIR/mpv.desktop" ;;
        yazi) printf '%s\n' "$APPLICATION_DESKTOP_DIR/yazi.desktop" ;;
    esac
}

application_nodisplay_satisfied() {
    local entry=$1 file

    while IFS= read -r file; do
        [ -n "$file" ] || continue
        [ ! -f "$file" ] || desktop_entry_key_matches \
            "$file" NoDisplay true || return 1
    done < <(application_nodisplay_files "$entry")
}

application_entry_payload_satisfied() {
    local entry=$1

    case "$entry" in
        AUR:*) declared_package_target_satisfied "$entry" ;;
        flatpak:*) state_flatpak_present "${entry#flatpak:}" ;;
        GitHub:*) github_application_satisfied "${entry#GitHub:}" ;;
        lazyvim) lazyvim_target_satisfied ;;
        *)
            if platform_is_fedora && fedora_application_provider_target "$entry"; then
                fedora_application_target_satisfied "$entry" \
                    "${TARGET_USER:-}" "${HOME_DIR:-}"
            else
                state_package_present "$entry"
            fi
            ;;
    esac
}

application_entry_config_satisfied() {
    local entry=$1

    case "$entry" in
        wine) wine_config_satisfied || return ;;
        lutris) lutris_config_satisfied || return ;;
        steam)
            if platform_is_fedora; then
                steam_flatpak_locale_satisfied || return
            else
                steam_native_locale_satisfied || return
            fi
            ;;
        flatpak:com.valvesoftware.Steam)
            steam_flatpak_locale_satisfied || return
            ;;
        firefox) firefox_defaults_satisfied || return ;;
        AUR:vicinae|AUR:vicinae-bin) vicinae_settings_satisfied || return ;;
    esac
    application_nodisplay_satisfied "$entry"
}

desktop_entry_key_matches() {
    local file=$1 key=$2 value=$3

    awk -F= -v wanted_key="$key" -v wanted_value="$value" '
        /^\[/ { in_desktop=($0 == "[Desktop Entry]"); next }
        in_desktop && $1 == wanted_key {
            count++
            if (substr($0, index($0, "=") + 1) == wanted_value) matches++
        }
        END { exit !(count == 1 && matches == 1) }
    ' "$file"
}

application_entry_satisfied() {
    local entry=$1

    application_entry_payload_satisfied "$entry" &&
        application_entry_config_satisfied "$entry"
}

application_entry_is_valid() {
    local entry=$1

    case "$entry" in
        AUR:?*|flatpak:?*|GitHub:focus-shift|GitHub:niri-clip|lazyvim) ;;
        *:*) return 1 ;;
        ?*) ;;
        *) return 1 ;;
    esac
}

application_entry_detected() {
    local entry=$1

    case "$entry" in
        AUR:*)
            if platform_is_fedora; then
                fedora_application_target_satisfied "${entry#AUR:}" \
                    "$TARGET_USER" "$HOME_DIR"
            else
                state_package_present "${entry#AUR:}"
            fi
            ;;
        GitHub:focus-shift)
            [ -x "$HOME_DIR/.local/bin/focus-shift" ] ||
                [ -d "$HOME_DIR/.local/src/focus-shift/.git" ]
            ;;
        GitHub:niri-clip)
            [ -x "$HOME_DIR/.local/bin/niri-clip" ] ||
                [ -d "$HOME_DIR/.local/src/niri-clip/.git" ] ||
                [ -f "$HOME_DIR/.config/systemd/user/niri-clip.service" ]
            ;;
        lazyvim) [ -s "$HOME_DIR/.config/nvim/lua/config/lazy.lua" ] ;;
        *) application_entry_payload_satisfied "$entry" ;;
    esac
}

collect_legacy_application_targets() {
    local source_file=$1 entry

    while IFS= read -r entry; do
        application_entry_is_valid "$entry" || {
            error "Invalid application entry in $source_file: $entry"
            return 1
        }
        application_entry_detected "$entry" && printf '%s\n' "$entry"
    done < <(application_entries_from_file "$source_file")
    return 0
}

migrate_legacy_application_manifest() {
    local source_file=$1 destination=${2:-$APPLICATION_MANIFEST}
    local temporary detected

    require_writable_mode || return
    [ -f "$source_file" ] && [ -r "$source_file" ] ||
        die "Application source list is not readable: $source_file"
    if ! detected=$(collect_legacy_application_targets "$source_file" |
        sort -u); then
        return 1
    fi
    # An empty result usually means the installed state is gone (fresh machine
    # or a rolled-back system), not that the user wants zero applications.
    # Declaring it would permanently drop every previously selected target.
    if [ -z "$detected" ]; then
        warn 'No installed application targets were detected; refusing to declare an empty manifest. Run install mode to select applications.'
        return "$RC_SKIPPED"
    fi
    install -d -m 755 "$(dirname "$destination")"
    temporary=$(mktemp)
    {
        printf '# Migrated from legacy installed state.\n'
        printf '%s\n' "$detected"
    } > "$temporary"
    if ! install_if_changed "$temporary" "$destination" 644; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
}
