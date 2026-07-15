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

lazyvim_target_satisfied() {
    local package

    for package in "${LAZYVIM_PACKAGES[@]}"; do
        state_package_present "$package" || return
    done
    [ -s "$HOME_DIR/.config/nvim/lua/config/lazy.lua" ]
}

application_entry_satisfied() {
    local entry=$1

    case "$entry" in
        AUR:*) state_package_present "${entry#AUR:}" ;;
        flatpak:*) state_flatpak_present "${entry#flatpak:}" ;;
        GitHub:focus-shift) [ -x "$HOME_DIR/.local/bin/focus-shift" ] ;;
        GitHub:niri-clip)
            [ -x "$HOME_DIR/.local/bin/niri-clip" ] &&
                state_user_unit_enabled "$TARGET_USER" niri-clip.service \
                    graphical-session.target
            ;;
        GitHub:*) return 1 ;;
        lazyvim) lazyvim_target_satisfied ;;
        *) state_package_present "$entry" ;;
    esac
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
        *) application_entry_satisfied "$entry" ;;
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
    local temporary

    require_writable_mode || return
    [ -f "$source_file" ] && [ -r "$source_file" ] ||
        die "Application source list is not readable: $source_file"
    install -d -m 755 "$(dirname "$destination")"
    temporary=$(mktemp)
    printf '# Migrated from legacy installed state.\n' > "$temporary"
    if ! collect_legacy_application_targets "$source_file" |
        sort -u >> "$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    if ! install_if_changed "$temporary" "$destination" 644; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
}
