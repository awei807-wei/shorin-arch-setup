#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

VICINAE_SETTINGS_TEMPLATE=${VICINAE_SETTINGS_TEMPLATE:-$SHORIN_ROOT/resources/vicinae/settings.json}
VICINAE_SETTINGS_FILE=${VICINAE_SETTINGS_FILE:-}

vicinae_settings_path() {
    printf '%s\n' "${VICINAE_SETTINGS_FILE:-$HOME_DIR/.config/vicinae/settings.json}"
}

vicinae_config_directory_path() {
    dirname "$(vicinae_settings_path)"
}

vicinae_path_owned_by_target() {
    local target_group

    target_group=$(id -gn "$TARGET_USER") || return 2
    [ "$(stat -c '%U:%G' "$1" 2>/dev/null)" = \
        "$TARGET_USER:$target_group" ]
}

vicinae_run_as_target() {
    local current_uid target_uid

    current_uid=$(id -u)
    target_uid=$(id -u "$TARGET_USER") || return 2
    if [ "$current_uid" -eq "$target_uid" ]; then
        "$@"
    else
        runuser -u "$TARGET_USER" -- "$@"
    fi
}

vicinae_settings_target_readable() {
    vicinae_run_as_target test -r "$1"
}

vicinae_config_directory_target_accessible() {
    vicinae_run_as_target test -x "$1" &&
        vicinae_run_as_target test -w "$1"
}

vicinae_config_directory_satisfied() {
    local directory

    directory=$(vicinae_config_directory_path)
    [ -L "$directory" ] && return 0
    [ -d "$directory" ] || return 1
    vicinae_path_owned_by_target "$directory" &&
        vicinae_config_directory_target_accessible "$directory"
}

render_vicinae_settings() {
    [ -r "$VICINAE_SETTINGS_TEMPLATE" ] || return 2
    case "$HOME_DIR" in
        *'"'*|*'\'*|*'|'*|*'&'*|*$'\n'*) return 2 ;;
    esac
    sed "s|__SHORIN_HOME_DIR__|$HOME_DIR|g" "$VICINAE_SETTINGS_TEMPLATE"
}

vicinae_settings_is_legacy_shell() {
    local file=$1 normalized

    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    normalized=$(awk '
        /^[[:space:]]*\/\// { next }
        { printf "%s", $0 }
    ' "$file" | tr -d '[:space:]')
    case "$normalized" in
        ''|'{}'|\
        '{"$schema":"https://vicinae.com/schemas/config.json"}'|\
        '{"imports":[]}'|\
        '{"$schema":"https://vicinae.com/schemas/config.json","imports":[]}'|\
        '{"imports":[],"$schema":"https://vicinae.com/schemas/config.json"}'|\
        '{"$schema":"https://vicinae.com/schemas/config.json","favorites":[],"providers":{}}')
            return 0
            ;;
        *) return 1 ;;
    esac
}

vicinae_settings_matches_template() {
    local destination=$1

    render_vicinae_settings | cmp -s - "$destination"
}

vicinae_settings_mode_private() {
    [ "$(stat -c '%a' "$1" 2>/dev/null)" = 600 ]
}

vicinae_settings_satisfied() {
    local destination

    destination=$(vicinae_settings_path)
    vicinae_config_directory_satisfied || return
    [ -L "$destination" ] && return 0
    [ -r "$VICINAE_SETTINGS_TEMPLATE" ] || return 2
    [ -e "$destination" ] || return 1
    [ -f "$destination" ] || return 2
    vicinae_path_owned_by_target "$destination" || return 1
    vicinae_settings_target_readable "$destination" || return 1
    if vicinae_settings_matches_template "$destination"; then
        vicinae_settings_mode_private "$destination" &&
            vicinae_path_owned_by_target "$destination"
        return
    fi
    vicinae_settings_is_legacy_shell "$destination" && return 1
    return 0
}
