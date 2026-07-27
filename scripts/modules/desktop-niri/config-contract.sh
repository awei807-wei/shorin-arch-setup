#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

niri_session_contract_init() {
    NIRI_CONFIG_FILE=${NIRI_CONFIG_FILE:-$HOME_DIR/.config/niri/config.kdl}
    NIRI_BINDS_FILE=${NIRI_BINDS_FILE:-$HOME_DIR/.config/niri/binds.kdl}
    NIRI_QUICKSHELL_DIR=${NIRI_QUICKSHELL_DIR:-$HOME_DIR/.config/quickshell}
    NIRI_FISH_GUARD_FILE=${NIRI_FISH_GUARD_FILE:-$HOME_DIR/.config/fish/conf.d/shorin-env.fish}
    NIRI_FISH_RUSTUP_FILE=${NIRI_FISH_RUSTUP_FILE:-$HOME_DIR/.config/fish/conf.d/rustup.fish}
    NIRI_FISH_LOCAL_ENV_FILE=${NIRI_FISH_LOCAL_ENV_FILE:-$HOME_DIR/.config/fish/conf.d/uv.env.fish}
    NIRI_BASH_PROFILE=${NIRI_BASH_PROFILE:-$HOME_DIR/.bash_profile}
    NIRI_LEGACY_UNIT=${NIRI_LEGACY_UNIT:-$HOME_DIR/.config/systemd/user/niri-autostart.service}
    NIRI_LEGACY_UNIT_LINK=${NIRI_LEGACY_UNIT_LINK:-$HOME_DIR/.config/systemd/user/default.target.wants/niri-autostart.service}
    NIRI_LOCAL_BIN=${NIRI_LOCAL_BIN:-$HOME_DIR/.local/bin}
}

niri_run_as_user() {
    local user=$1
    shift

    if [ "$(id -u)" -eq "$(id -u "$user")" ] &&
        [ "${SHORIN_FORCE_RUNUSER:-0}" != 1 ]; then
        "$@"
    else
        runuser -u "$user" -- "$@"
    fi
}

niri_file_owned_and_readable_by() {
    local file=$1 user=$2

    [ -f "$file" ] &&
        [ "$(stat -c '%u' "$file")" -eq "$(id -u "$user")" ] &&
        niri_run_as_user "$user" test -r "$file"
}

niri_session_files_accessible() {
    local user=${1:-$TARGET_USER}

    niri_file_owned_and_readable_by "$NIRI_CONFIG_FILE" "$user" &&
        niri_file_owned_and_readable_by "$NIRI_BINDS_FILE" "$user"
}

niri_path_satisfied() {
    [ -s "$NIRI_CONFIG_FILE" ] || return 1
    awk -v target="$NIRI_LOCAL_BIN" '
        /^[[:space:]]*environment[[:space:]]*\{/ { in_environment=1; next }
        in_environment && /^[[:space:]]*}/ { in_environment=0; next }
        in_environment && /^[[:space:]]*PATH[[:space:]]+"/ {
            value=$0
            sub(/^[^"]*"/, "", value)
            sub(/".*$/, "", value)
            count++
            fields=split(value, paths, ":")
            for (i=1; i<=fields; i++) if (paths[i] == target) found=1
        }
        END { exit !(count == 1 && found == 1) }
    ' "$NIRI_CONFIG_FILE"
}

niri_binding_contract() {
    case "$1" in
        clipboard)
            printf '%s\n' '    Mod+Alt+V hotkey-overlay-title="剪贴板 Clipboard" { spawn "niri-clip" "toggle"; }'
            ;;
        focus-shift)
            printf '%s\n' '    Mod+ALT+C repeat=false hotkey-overlay-title="窗口切换 FocusShift" { spawn "focus-shift"; }'
            ;;
        *) return 2 ;;
    esac
}

niri_binding_matches() {
    local chord=$1 expected=$2

    [ -s "$NIRI_BINDS_FILE" ] || return 1
    awk -v chord="$(printf '%s' "$chord" | tr '[:upper:]' '[:lower:]')" \
        -v expected="$expected" '
        {
            candidate=$0
            sub(/^[[:space:]]*/, "", candidate)
            lowered=tolower(candidate)
            if (index(lowered, chord) == 1 &&
                substr(lowered, length(chord) + 1, 1) ~ /[[:space:]]/) {
                count++
                if ($0 == expected) matches++
            }
        }
        END { exit !(count == 1 && matches == 1) }
    ' "$NIRI_BINDS_FILE"
}

niri_bindings_satisfied() {
    niri_binding_matches Mod+Alt+V "$(niri_binding_contract clipboard)" &&
        niri_binding_matches Mod+Alt+C "$(niri_binding_contract focus-shift)"
}

ensure_niri_path() {
    local user=$1 temporary mode group

    niri_path_satisfied && return 0
    [ -s "$NIRI_CONFIG_FILE" ] || return 1
    temporary=$(mktemp)
    awk -v target="$NIRI_LOCAL_BIN" '
        function path_contains(value, wanted, parts, count, i) {
            count=split(value, parts, ":")
            for (i=1; i<=count; i++) if (parts[i] == wanted) return 1
            return 0
        }
        /^[[:space:]]*environment[[:space:]]*\{/ {
            environment_seen=1
            in_environment=1
            path_seen=0
            print
            next
        }
        in_environment && /^[[:space:]]*PATH[[:space:]]+/ {
            if (path_seen) next
            value=$0
            sub(/^[^"]*"/, "", value)
            sub(/".*$/, "", value)
            if (!path_contains(value, target)) value=target ":" value
            print "    PATH \"" value "\""
            path_seen=1
            next
        }
        in_environment && /^[[:space:]]*}/ {
            if (!path_seen) print "    PATH \"" target ":/usr/local/bin:/usr/bin\""
            in_environment=0
            print
            next
        }
        { print }
        END {
            if (!environment_seen) {
                print ""
                print "environment {"
                print "    PATH \"" target ":/usr/local/bin:/usr/bin\""
                print "}"
            }
        }
    ' "$NIRI_CONFIG_FILE" > "$temporary"
    mode=$(stat -c '%a' "$NIRI_CONFIG_FILE")
    group=$(id -gn "$user")
    install_if_changed "$temporary" "$NIRI_CONFIG_FILE" "$mode"
    rm -f "$temporary"
    chown "$user:$group" "$NIRI_CONFIG_FILE"
    niri_path_satisfied
}

ensure_niri_bindings() {
    local user=$1 temporary mode group clipboard focus

    niri_bindings_satisfied && return 0
    [ -s "$NIRI_BINDS_FILE" ] || return 1
    clipboard=$(niri_binding_contract clipboard)
    focus=$(niri_binding_contract focus-shift)
    temporary=$(mktemp)
    awk -v clipboard="$clipboard" -v focus="$focus" '
        {
            lines[NR]=$0
            candidate=$0
            sub(/^[[:space:]]*/, "", candidate)
            lowered=tolower(candidate)
            if (lowered ~ /^mod\+alt\+v[[:space:]]/) {
                if (!clipboard_seen) lines[NR]=clipboard
                else drop[NR]=1
                clipboard_seen=1
            } else if (lowered ~ /^mod\+alt\+c[[:space:]]/) {
                if (!focus_seen) lines[NR]=focus
                else drop[NR]=1
                focus_seen=1
            }
            if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) last_close=NR
        }
        END {
            if (!last_close) exit 2
            for (i=1; i<=NR; i++) {
                if (i == last_close) {
                    if (!clipboard_seen) print clipboard
                    if (!focus_seen) print focus
                }
                if (!drop[i]) print lines[i]
            }
        }
    ' "$NIRI_BINDS_FILE" > "$temporary"
    mode=$(stat -c '%a' "$NIRI_BINDS_FILE")
    group=$(id -gn "$user")
    install_if_changed "$temporary" "$NIRI_BINDS_FILE" "$mode"
    rm -f "$temporary"
    chown "$user:$group" "$NIRI_BINDS_FILE"
    niri_bindings_satisfied
}

niri_config_valid() {
    local user=${1:-$TARGET_USER}

    command -v niri >/dev/null 2>&1 || return 2
    niri_session_files_accessible "$user" || return 1
    niri_run_as_user "$user" env HOME="$HOME_DIR" \
        niri validate -c "$NIRI_CONFIG_FILE" >/dev/null
}
