#!/usr/bin/env bash
set -Eeuo pipefail

# Fedora profile cleanup is deliberately separate from the Arch tty1 profile
# contract.  Only Shorin markers and the exact historical three-line block are
# eligible for migration; arbitrary user shell commands remain untouched.

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

niri_fedora_legacy_unit_owned() {
    local actual

    [ -f "$NIRI_LEGACY_UNIT" ] && [ ! -L "$NIRI_LEGACY_UNIT" ] || return 1
    actual=$(< "$NIRI_LEGACY_UNIT")
    case "$actual" in
        $'[Service]\nExecStart=/usr/bin/niri-session'|\
        $'[Service]\nExecStart=niri-session') return 0 ;;
        *) return 1 ;;
    esac
}

niri_fedora_legacy_link_owned() {
    [ -L "$NIRI_LEGACY_UNIT_LINK" ] &&
        [ "$(readlink "$NIRI_LEGACY_UNIT_LINK")" = ../niri-autostart.service ]
}

niri_fedora_remove_legacy_autostart() {
    local user=$1 unit_owned=0 link_owned=0 unit_present=0

    [ -e "$NIRI_LEGACY_UNIT" ] || [ -L "$NIRI_LEGACY_UNIT" ] && unit_present=1
    niri_fedora_legacy_unit_owned && unit_owned=1
    niri_fedora_legacy_link_owned && link_owned=1
    # A link is only safe to migrate alongside a known Shorin unit.  The sole
    # exception is a dangling link to the exact historical unit name.
    if [ "$unit_present" -eq 1 ] && [ "$unit_owned" -eq 0 ]; then
        link_owned=0
    fi
    [ "$unit_owned" -eq 1 ] || [ "$link_owned" -eq 1 ] || return 0
    niri_disable_legacy_user_unit "$user" || return
    [ "$link_owned" -eq 0 ] || rm -f "$NIRI_LEGACY_UNIT_LINK"
    [ "$unit_owned" -eq 0 ] || rm -f "$NIRI_LEGACY_UNIT"
    niri_reload_user_manager "$user"
}

niri_fedora_bash_profile_managed_block_satisfied() {
    local file=${NIRI_BASH_PROFILE:-$HOME_DIR/.bash_profile}

    # Fedora's graphical login must not depend on a login shell.  A missing
    # profile is valid, and an existing profile remains entirely user-owned as
    # long as no Shorin tty marker or exact legacy block is present.
    [ -f "$file" ] || return 0
    ! grep -Fq '# >>> shorin niri tty1 >>>' "$file" || return 1
    ! grep -Fq '# <<< shorin niri tty1 <<<' "$file" || return 1
    ! grep -Fq '# shorin:niri-session:start' "$file" || return 1
    ! grep -Fq '# shorin:niri-session:end' "$file" || return 1
    awk '
        $0 == "if [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} && $(tty) == /dev/tty1 ]]; then" {
            getline body
            getline end_line
            if (body == "    exec niri-session -l" && end_line == "fi") found=1
        }
        END { exit found }
    ' "$file"
}

niri_fedora_remove_bash_profile_managed_blocks() {
    local user=$1 file=${NIRI_BASH_PROFILE:-$HOME_DIR/.bash_profile}
    local begin_count end_count legacy_begin_count legacy_end_count
    local temporary filtered mode

    require_writable_mode || return
    [ -f "$file" ] || return 0
    begin_count=$(grep -Fxc '# >>> shorin niri tty1 >>>' "$file" || true)
    end_count=$(grep -Fxc '# <<< shorin niri tty1 <<<' "$file" || true)
    legacy_begin_count=$(grep -Fxc '# shorin:niri-session:start' "$file" || true)
    legacy_end_count=$(grep -Fxc '# shorin:niri-session:end' "$file" || true)
    [ "$begin_count" -eq "$end_count" ] || return 2
    [ "$legacy_begin_count" -eq "$legacy_end_count" ] || return 2
    if [ "$begin_count" -eq 0 ] && [ "$legacy_begin_count" -eq 0 ] &&
        niri_fedora_bash_profile_managed_block_satisfied; then
        return 0
    fi

    mode=$(stat -c '%a' "$file")
    temporary=$(mktemp)
    filtered=$(mktemp)
    awk '
        $0 == "# >>> shorin niri tty1 >>>" ||
        $0 == "# shorin:niri-session:start" { skip=1; next }
        $0 == "# <<< shorin niri tty1 <<<" ||
        $0 == "# shorin:niri-session:end" { skip=0; next }
        !skip { print }
    ' "$file" > "$filtered"
    awk '{ lines[NR]=$0 } END {
        last=NR
        while (last > 0 && lines[last] == "") last--
        for (i=1; i<=last; i++) print lines[i]
    }' "$filtered" > "$temporary"
    # The unmarked three-line legacy block is removed only when it is an exact
    # historical Shorin rendering.  Bare `niri` commands and other user shell
    # content are deliberately never matched here.
    awk '
        $0 == "if [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} && $(tty) == /dev/tty1 ]]; then" {
            getline body
            getline end_line
            if (body == "    exec niri-session -l" && end_line == "fi") next
            print $0
            if (body != "") print body
            if (end_line != "") print end_line
            next
        }
        { print }
    ' "$temporary" > "${temporary}.clean"
    mv -f "${temporary}.clean" "$temporary"
    install_if_changed "$temporary" "$file" "$mode"
    rm -f "$temporary" "$filtered"
    chown "$user:" "$file"
    niri_fedora_bash_profile_managed_block_satisfied
}
