#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"

APPLICATION_MANIFEST=${APPLICATION_MANIFEST:-${SHORIN_PROFILE_DIR:-/etc/shorin-arch-setup}/applications.list}
LAZYVIM_PACKAGES=(neovim ripgrep fd ttf-jetbrains-mono-nerd git)

application_manifest_entries() {
    awk '
        /^[[:space:]]*(#|$)/ { next }
        {
            sub(/[[:space:]]+#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (length) print
        }
    ' "$APPLICATION_MANIFEST"
}

lazyvim_target_satisfied() {
    local package

    for package in "${LAZYVIM_PACKAGES[@]}"; do
        state_package_present "$package" || return
    done
    [ -s "$HOME_DIR/.config/nvim/lua/config/lazy.lua" ]
}

application_entry_satisfied() {
    local entry=$1 name
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

applications_inspect() {
    local phase=$1 entry

    if [ -z "${TARGET_USER:-}" ] || [ -z "${HOME_DIR:-}" ]; then
        module_inspection_failed target-user-context
        return
    fi
    if [ ! -s "$APPLICATION_MANIFEST" ]; then
        if [ "$phase" = check ] && [ "${SHORIN_MODE:-install}" = install ]; then
            module_drift application-manifest
        else
            module_skip application-targets-not-declared
        fi
        return 0
    fi
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if [ "$phase" = check ]; then
            module_check_state "application:$entry" \
                application_entry_satisfied "$entry"
            [ "$MODULE_RESULT" -ne "$RC_FAILED" ] || return
        elif ! application_entry_satisfied "$entry"; then
            module_verify_failed "application:$entry"
        fi
    done < <(application_manifest_entries)

    if [ "$MODULE_RESULT" -eq "$RC_OK" ] &&
        application_manifest_entries | grep -Fqx 'GitHub:niri-clip' &&
        [ ! -S "/run/user/$(id -u "$TARGET_USER")/bus" ]; then
        module_skip user-services-pending-login
    fi
}

applications_check() { applications_inspect check; }

applications_apply() {
    local status=0

    bash "$SHORIN_ROOT/scripts/modules/applications/apply.sh" || status=$?
    case "$status" in
        0|20) return 0 ;;
        *) return "$status" ;;
    esac
}

applications_verify() { applications_inspect verify; }

module_main applications "$@"
