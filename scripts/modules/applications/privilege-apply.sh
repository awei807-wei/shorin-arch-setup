#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

APPLICATIONS_TEMP_SUDOERS_FILE=${APPLICATIONS_TEMP_SUDOERS_FILE:-/etc/sudoers.d/99_shorin_installer_apps}

begin_temporary_aur_sudoers() {
    local temporary

    [ "$#" -gt 0 ] || return 0
    temporary=$(mktemp)
    printf '%s ALL=(root) NOPASSWD: /usr/bin/pacman\n' \
        "$TARGET_USER" > "$temporary"
    if ! install_sudoers_file "$temporary" "$APPLICATIONS_TEMP_SUDOERS_FILE"; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
}

end_temporary_aur_sudoers() {
    [ ! -e "$APPLICATIONS_TEMP_SUDOERS_FILE" ] ||
        rm -f "$APPLICATIONS_TEMP_SUDOERS_FILE"
}
