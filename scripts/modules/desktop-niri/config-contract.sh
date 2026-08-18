#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

niri_session_contract_init() {
    NIRI_LOCAL_BIN=${NIRI_LOCAL_BIN:-$HOME_DIR/.local/bin}
    NIRI_CONFIG_FILE=${NIRI_CONFIG_FILE:-$HOME_DIR/.config/niri/config.kdl}
    NIRI_BINDS_FILE=${NIRI_BINDS_FILE:-$HOME_DIR/.config/niri/binds.kdl}
    NIRI_QUICKSHELL_DIR=${NIRI_QUICKSHELL_DIR:-$HOME_DIR/.config/quickshell}
    NIRI_DESKTOP_STATE_DIR=${NIRI_DESKTOP_STATE_DIR:-$HOME_DIR/.local/state/shorin-arch-setup/desktop-niri}
    NIRI_QUICKSHELL_BACKUP_DIR=${NIRI_QUICKSHELL_BACKUP_DIR:-$NIRI_DESKTOP_STATE_DIR/quickshell-backups}
    NIRI_QUICKSHELL_SOURCE_STATE_FILE=${NIRI_QUICKSHELL_SOURCE_STATE_FILE:-$NIRI_DESKTOP_STATE_DIR/quickshell-source}
    NIRI_FISH_CONFIG_FILE=${NIRI_FISH_CONFIG_FILE:-$HOME_DIR/.config/fish/config.fish}
    NIRI_FISH_GUARD_FILE=${NIRI_FISH_GUARD_FILE:-$HOME_DIR/.config/fish/conf.d/shorin-env.fish}
    NIRI_FISH_RUSTUP_FILE=${NIRI_FISH_RUSTUP_FILE:-$HOME_DIR/.config/fish/conf.d/rustup.fish}
    NIRI_FISH_LOCAL_ENV_FILE=${NIRI_FISH_LOCAL_ENV_FILE:-$HOME_DIR/.config/fish/conf.d/uv.env.fish}
    NIRI_BASH_PROFILE=${NIRI_BASH_PROFILE:-$HOME_DIR/.bash_profile}
    NIRI_LEGACY_UNIT=${NIRI_LEGACY_UNIT:-$HOME_DIR/.config/systemd/user/niri-autostart.service}
    NIRI_LEGACY_UNIT_LINK=${NIRI_LEGACY_UNIT_LINK:-$HOME_DIR/.config/systemd/user/default.target.wants/niri-autostart.service}
    NIRI_LOCKSCREEN_SCRIPT_FILE=${NIRI_LOCKSCREEN_SCRIPT_FILE:-$NIRI_QUICKSHELL_DIR/scripts/lockscreen.sh}
    NIRI_FEDORA_WALLPAPER_SESSION_FILE=${NIRI_FEDORA_WALLPAPER_SESSION_FILE:-$NIRI_LOCAL_BIN/shorin-fedora-wallpaper-session}
    NIRI_FEDORA_AWWW_QUERY_WRAPPER_FILE=${NIRI_FEDORA_AWWW_QUERY_WRAPPER_FILE:-$NIRI_LOCAL_BIN/shorin-fedora-awww-query}
    NIRI_FEDORA_LSFG_ENV_FILE=${NIRI_FEDORA_LSFG_ENV_FILE:-$HOME_DIR/.config/environment.d/90-shorin-lsfg.conf}
    NIRI_FEDORA_LSFG_WRAPPER_FILE=${NIRI_FEDORA_LSFG_WRAPPER_FILE:-$NIRI_LOCAL_BIN/shorin-lsfg}
    NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_AUTOSTART_FILE=${NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_AUTOSTART_FILE:-$HOME_DIR/.config/autostart/org.kde.xwaylandvideobridge.desktop}
    NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_UNIT=${NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_UNIT:-app-org.kde.xwaylandvideobridge@autostart.service}
    NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_MASK_FILE=${NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_MASK_FILE:-$HOME_DIR/.config/systemd/user/$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_UNIT}
    NIRI_FEDORA_DRKONQI_UNIT=${NIRI_FEDORA_DRKONQI_UNIT:-drkonqi-coredump-launcher.socket}
    NIRI_FEDORA_DRKONQI_MASK_FILE=${NIRI_FEDORA_DRKONQI_MASK_FILE:-$HOME_DIR/.config/systemd/user/$NIRI_FEDORA_DRKONQI_UNIT}
    NIRI_FEDORA_POLKIT_AGENT_PATH=${NIRI_FEDORA_POLKIT_AGENT_PATH:-/usr/libexec/kf6/polkit-kde-authentication-agent-1}
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

niri_swayosd_startup_command_present() {
    [ -s "$NIRI_CONFIG_FILE" ] || return 1
    grep -Eq \
        '^[[:space:]]*spawn(-sh)?-at-startup.*swayosd(-server|-libinput-backend)?([[:space:]"&]|$)' \
        "$NIRI_CONFIG_FILE"
}

niri_optional_startup_satisfied() {
    local package_status=0

    platform_is_fedora || return 0
    niri_package_target_satisfied swayosd || package_status=$?
    case "$package_status" in
        0) return 0 ;;
        1) ! niri_swayosd_startup_command_present ;;
        *) return "$package_status" ;;
    esac
}

niri_optional_command_guard_contract() {
    case "$1" in
        fd-rdd|vicinae|waypaper|niriswitcher|niriswitcherctl|waybar|hyprpicker)
            printf 'command -v %s >/dev/null 2>&1 && exec %s "$@"' "$1" "$1"
            ;;
        *) return 2 ;;
    esac
}

niri_fedora_config_file_compatibility_satisfied() {
    local file=$1
    local optional_commands='fd-rdd vicinae waypaper niriswitcherctl niriswitcher waybar hyprpicker'
    local wallpaper_startup=0

    [ -s "$file" ] || return 1
    [ "$file" = "$NIRI_CONFIG_FILE" ] && wallpaper_startup=1
    awk -v optional="$optional_commands" \
        -v polkit="$NIRI_FEDORA_POLKIT_AGENT_PATH" \
        -v initializer="$NIRI_FEDORA_WALLPAPER_SESSION_FILE" \
        -v lockscreen="$NIRI_LOCKSCREEN_SCRIPT_FILE" \
        -v wallpaper_startup="$wallpaper_startup" \
        -v validate=1 \
        -f "$SHORIN_ROOT/scripts/modules/desktop-niri/fedora-config-compatibility.awk" \
        "$file" >/dev/null
}

niri_fedora_wallpaper_initializer_satisfied() {
    platform_is_fedora || return 0
    [ -f "$NIRI_FEDORA_WALLPAPER_SESSION_FILE" ] &&
        [ ! -L "$NIRI_FEDORA_WALLPAPER_SESSION_FILE" ] &&
        [ -x "$NIRI_FEDORA_WALLPAPER_SESSION_FILE" ] &&
        [ "$(stat -c '%U' "$NIRI_FEDORA_WALLPAPER_SESSION_FILE")" = "$TARGET_USER" ] &&
        grep -Fq 'fedora_wallpaper_session_main' \
            "$NIRI_FEDORA_WALLPAPER_SESSION_FILE"
}

niri_fedora_awww_query_wrapper_satisfied() {
    platform_is_fedora || return 0
    [ -f "$NIRI_FEDORA_AWWW_QUERY_WRAPPER_FILE" ] &&
        [ ! -L "$NIRI_FEDORA_AWWW_QUERY_WRAPPER_FILE" ] &&
        [ -x "$NIRI_FEDORA_AWWW_QUERY_WRAPPER_FILE" ] &&
        [ "$(stat -c '%U' "$NIRI_FEDORA_AWWW_QUERY_WRAPPER_FILE")" = "$TARGET_USER" ] &&
        grep -Fq 'fedora_wallpaper_query_wrapper' \
            "$NIRI_FEDORA_AWWW_QUERY_WRAPPER_FILE"
}

niri_fedora_wallpaper_session_satisfied() {
    niri_fedora_wallpaper_initializer_satisfied &&
        niri_fedora_awww_query_wrapper_satisfied
}

niri_fedora_xwayland_videobridge_autostart_contract() {
    printf '[Desktop Entry]\nHidden=true\n'
}

niri_fedora_xwayland_videobridge_mask_satisfied() {
    local user=${1:-$TARGET_USER}

    [ -L "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_MASK_FILE" ] || return 1
    [ "$(readlink "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_MASK_FILE")" = /dev/null ] ||
        return 1
    [ "$(stat -c '%U' "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_MASK_FILE")" = \
        "$user" ]
}

niri_fedora_user_systemctl() {
    local user=$1 uid runtime_dir
    shift

    command -v systemctl >/dev/null 2>&1 || return 2
    uid=$(id -u "$user") || return 1
    runtime_dir="${SHORIN_USER_RUNTIME_ROOT:-/run/user}/$uid"
    niri_run_as_user "$user" env \
        LC_ALL=C \
        XDG_RUNTIME_DIR="$runtime_dir" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
        systemctl --user "$@"
}

niri_fedora_xwayland_videobridge_user_systemctl() {
    niri_fedora_user_systemctl "$@"
}

niri_fedora_xwayland_videobridge_reset_failed() {
    local user=$1 output status

    if output=$(niri_fedora_xwayland_videobridge_user_systemctl "$user" \
        reset-failed "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_UNIT" 2>&1); then
        return 0
    else
        status=$?
    fi
    case "$status" in
        1|5)
            printf '%s\n' "$output" |
                grep -Eiq '(^|[[:space:]])Unit[[:space:]]+[^[:space:]]+[[:space:]]+not loaded([.:]|$)' &&
                return 0
            ;;
    esac
    return "$status"
}

niri_fedora_xwayland_videobridge_reload_user_manager() {
    local user=$1 status=0

    if niri_user_bus_is_available "$user"; then
        niri_fedora_xwayland_videobridge_user_systemctl "$user" \
            daemon-reload
    else
        status=$?
        [ "$status" -eq 1 ] || return "$status"
    fi
}

niri_fedora_xwayland_videobridge_unit_inactive() {
    local user=$1 status=0

    if niri_fedora_xwayland_videobridge_user_systemctl "$user" \
        is-active --quiet "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_UNIT"; then
        return 1
    else
        status=$?
    fi
    case "$status" in
        1|3|4) return 0 ;;
        *) return "$status" ;;
    esac
}

niri_fedora_xwayland_videobridge_process_inactive() {
    local user=$1 pid status=0

    pid=$(niri_fedora_xwayland_videobridge_user_systemctl "$user" \
        show -p MainPID --value "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_UNIT") || {
        status=$?
        case "$status" in
            1|3|4) return 0 ;;
            *) return "$status" ;;
        esac
    }
    case "$pid" in
        ''|0) return 0 ;;
        *[!0-9]*) return 2 ;;
    esac
    if kill -0 "$pid" 2>/dev/null; then
        return 1
    else
        status=$?
    fi
    [ "$status" -eq 1 ] || return "$status"
}

niri_fedora_xwayland_videobridge_service_satisfied() {
    local user=${1:-$TARGET_USER} status=0

    niri_fedora_xwayland_videobridge_mask_satisfied "$user" || return 1
    if niri_user_bus_is_available "$user"; then
        :
    else
        status=$?
        [ "$status" -eq 1 ] || return "$status"
        return 0
    fi
    niri_fedora_xwayland_videobridge_unit_inactive "$user" || return
    niri_fedora_xwayland_videobridge_process_inactive "$user"
}

niri_fedora_xwayland_videobridge_autostart_satisfied() {
    local actual expected user=${1:-$TARGET_USER}

    platform_is_fedora || return 0
    [ -f "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_AUTOSTART_FILE" ] || return 1
    [ ! -L "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_AUTOSTART_FILE" ] || return 1
    [ "$(stat -c '%U' "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_AUTOSTART_FILE")" = \
        "$user" ] || return 1
    actual=$(< "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_AUTOSTART_FILE")
    expected=$(niri_fedora_xwayland_videobridge_autostart_contract)
    [ "$actual" = "$expected" ] || return 1
    niri_fedora_xwayland_videobridge_service_satisfied "$user"
}

niri_fedora_install_if_stale_user_file() {
    local source=$1 destination=$2 user=$3 group=$4

    [ ! -L "$destination" ] || return 1
    if [ ! -f "$destination" ] || ! cmp -s "$source" "$destination" ||
        [ "$(stat -c '%a' "$destination" 2>/dev/null || printf '%s' 0)" -ne 755 ] ||
        [ "$(stat -c '%U' "$destination" 2>/dev/null || printf '%s' '')" != "$user" ]; then
        install -m 755 -o "$user" -g "$group" "$source" "$destination" || return 1
    fi
}

niri_fedora_lockscreen_binding_satisfied() {
    platform_is_fedora || return 0
    [ -s "$NIRI_BINDS_FILE" ] || return 1
    awk '
        /^[[:space:]]*(\/\/|#)/ { next }
        {
            candidate=$0
            sub(/^[[:space:]]*/, "", candidate)
            lowered=tolower(candidate)
            if (lowered ~ /^mod[+]alt[+]l([[:space:]]|[{])/) {
                binding_seen=1
                if ($0 !~ /spawn(-sh)?[[:space:]]+"([^"]*[/])?lockscreen[.]sh"/) {
                    invalid=1
                }
            }
        }
        END { exit !(binding_seen && !invalid) }
    ' "$NIRI_BINDS_FILE"
}

ensure_niri_fedora_wallpaper_session() {
    local user=$1 group source

    require_writable_mode || return
    platform_is_fedora || return 0
    source="$SHORIN_ROOT/scripts/modules/desktop-niri/fedora-wallpaper-session.sh"
    [ -f "$source" ] && [ ! -L "$source" ] && [ -x "$source" ] || return 1
    group=$(id -gn "$user") || return 1
    install -d -o "$user" -g "$group" "$NIRI_LOCAL_BIN" || return 1
    niri_fedora_install_if_stale_user_file "$source" \
        "$NIRI_FEDORA_WALLPAPER_SESSION_FILE" "$user" "$group" || return 1
    niri_fedora_install_if_stale_user_file "$source" \
        "$NIRI_FEDORA_AWWW_QUERY_WRAPPER_FILE" "$user" "$group" || return 1
    niri_fedora_wallpaper_session_satisfied
}

ensure_niri_fedora_xwayland_videobridge_autostart() {
    local user=$1 group temporary status=0 mask_file bus_available=0

    require_writable_mode || return
    platform_is_fedora || return 0
    niri_path_is_safe_no_symlink "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_AUTOSTART_FILE" ||
        return 1
    group=$(id -gn "$user") || return 1
    install -d -o "$user" -g "$group" \
        "$(dirname "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_AUTOSTART_FILE")" ||
        return 1
    [ ! -L "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_AUTOSTART_FILE" ] || return 1
    temporary=$(mktemp)
    niri_fedora_xwayland_videobridge_autostart_contract > "$temporary"
    install_if_changed "$temporary" \
        "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_AUTOSTART_FILE" 644 || {
        rm -f "$temporary"
        return 1
    }
    rm -f "$temporary"
    chown "$user:$group" "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_AUTOSTART_FILE" || return 1
    niri_path_is_safe_no_symlink \
        "$(dirname "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_MASK_FILE")" ||
        return 1
    install -d -o "$user" -g "$group" \
        "$(dirname "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_MASK_FILE")" ||
        return 1
    mask_file=$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_MASK_FILE
    if niri_user_bus_is_available "$user"; then
        bus_available=1
    else
        status=$?
        [ "$status" -eq 1 ] || return "$status"
    fi
    if [ -e "$mask_file" ] || [ -L "$mask_file" ]; then
        [ -L "$mask_file" ] || return 1
        [ "$(readlink "$mask_file")" = /dev/null ] || return 1
        if [ "$(stat -c '%U' "$mask_file")" != "$user" ]; then
            chown -h "$user:$group" "$mask_file" || return 1
        fi
    else
        niri_run_as_user "$user" ln -s /dev/null "$mask_file" || return
    fi
    if [ "$bus_available" -eq 1 ]; then
        # The order is intentional: make the mask visible to the user
        # manager, reload its cache, stop any already-running generated unit,
        # clear its failure state, then validate inactive state.  Keep stop as
        # a separate command so the operation remains auditable.
        niri_fedora_xwayland_videobridge_reload_user_manager "$user" || return
        niri_fedora_xwayland_videobridge_user_systemctl "$user" \
            stop "$NIRI_FEDORA_XWAYLAND_VIDEOBRIDGE_UNIT" || {
            status=$?
            case "$status" in
                1|3|4|5) ;;
                *) return "$status" ;;
            esac
        }
        niri_fedora_xwayland_videobridge_reset_failed "$user" || return
    fi
    niri_fedora_xwayland_videobridge_autostart_satisfied "$user"
}

ensure_niri_fedora_wallpaper_initializer() {
    ensure_niri_fedora_wallpaper_session "$@"
}

niri_fedora_lockscreen_contract_satisfied() {
    local optional_commands='fd-rdd vicinae waypaper niriswitcherctl niriswitcher waybar hyprpicker'
    local wallpaper_startup=1

    platform_is_fedora || return 0
    awk -v optional="$optional_commands" \
        -v polkit="$NIRI_FEDORA_POLKIT_AGENT_PATH" \
        -v initializer="$NIRI_FEDORA_WALLPAPER_SESSION_FILE" \
        -v lockscreen="$NIRI_LOCKSCREEN_SCRIPT_FILE" \
        -v wallpaper_startup="$wallpaper_startup" \
        -v validate=1 \
        -v require_lockscreen=1 \
        -f "$SHORIN_ROOT/scripts/modules/desktop-niri/fedora-config-compatibility.awk" \
        "$NIRI_CONFIG_FILE" >/dev/null || return 1
    # Binds are intentionally validated separately.  A user may keep a
    # wallpaper-related command as an interactive binding; only config.kdl's
    # startup entries are owned by the session initializer contract.
    awk -v optional="$optional_commands" \
        -v polkit="$NIRI_FEDORA_POLKIT_AGENT_PATH" \
        -v initializer="$NIRI_FEDORA_WALLPAPER_SESSION_FILE" \
        -v lockscreen="$NIRI_LOCKSCREEN_SCRIPT_FILE" \
        -v wallpaper_startup=0 \
        -v validate=1 \
        -f "$SHORIN_ROOT/scripts/modules/desktop-niri/fedora-config-compatibility.awk" \
        "$NIRI_BINDS_FILE" >/dev/null || return 1
    niri_fedora_lockscreen_binding_satisfied || return 1
    [ -f "$NIRI_LOCKSCREEN_SCRIPT_FILE" ] &&
        [ ! -L "$NIRI_LOCKSCREEN_SCRIPT_FILE" ] &&
        [ -x "$NIRI_LOCKSCREEN_SCRIPT_FILE" ] &&
        [ "$(stat -c '%U' "$NIRI_LOCKSCREEN_SCRIPT_FILE")" = "$TARGET_USER" ] ||
        return 1
    niri_fedora_wallpaper_session_satisfied
}

niri_fedora_session_compatibility_files_satisfied() {
    platform_is_fedora || return 0
    niri_fedora_lockscreen_contract_satisfied || return 1
    niri_fedora_config_file_compatibility_satisfied "$NIRI_CONFIG_FILE" || return 1
    niri_fedora_config_file_compatibility_satisfied "$NIRI_BINDS_FILE"
}

niri_fedora_session_compatibility_satisfied() {
    platform_is_fedora || return 0
    niri_fedora_session_compatibility_files_satisfied || return 1
    niri_fedora_xwayland_videobridge_autostart_satisfied
}

ensure_niri_fedora_config_file_compatibility() {
    local file=$1 user=$2 temporary mode group
    local optional_commands='fd-rdd vicinae waypaper niriswitcherctl niriswitcher waybar hyprpicker'
    local wallpaper_startup=0

    require_writable_mode || return
    platform_is_fedora || return 0
    [ -f "$file" ] || return 1
    [ "$file" = "$NIRI_CONFIG_FILE" ] && wallpaper_startup=1
    temporary=$(mktemp)
    if ! awk -v optional="$optional_commands" -v polkit="$NIRI_FEDORA_POLKIT_AGENT_PATH" \
        -v initializer="$NIRI_FEDORA_WALLPAPER_SESSION_FILE" \
        -v lockscreen="$NIRI_LOCKSCREEN_SCRIPT_FILE" \
        -v wallpaper_startup="$wallpaper_startup" \
        -f "$SHORIN_ROOT/scripts/modules/desktop-niri/fedora-config-compatibility.awk" \
        "$file" > "$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    mode=$(stat -c '%a' "$file")
    group=$(id -gn "$user")
    if ! install_if_changed "$temporary" "$file" "$mode"; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
    chown "$user:$group" "$file"
    niri_fedora_config_file_compatibility_satisfied "$file"
}

ensure_niri_fedora_session_compatibility_files() {
    local user=$1

    platform_is_fedora || return 0
    ensure_niri_fedora_wallpaper_session "$user" || return
    ensure_niri_fedora_config_file_compatibility "$NIRI_CONFIG_FILE" "$user" ||
        return
    ensure_niri_fedora_config_file_compatibility "$NIRI_BINDS_FILE" "$user" ||
        return
    niri_fedora_session_compatibility_files_satisfied
}

ensure_niri_fedora_session_compatibility() {
    local user=$1

    platform_is_fedora || return 0
    ensure_niri_fedora_session_compatibility_files "$user" || return
    ensure_niri_fedora_xwayland_videobridge_autostart "$user" || return
    niri_fedora_session_compatibility_satisfied
}

ensure_niri_optional_startup() {
    local user=$1 package_status=0 temporary mode group

    require_writable_mode || return
    platform_is_fedora || return 0
    niri_package_target_satisfied swayosd || package_status=$?
    case "$package_status" in
        0) return 0 ;;
        1) niri_swayosd_startup_command_present || return 0 ;;
        *) return "$package_status" ;;
    esac
    temporary=$(mktemp)
    awk '
        /^[[:space:]]*spawn(-sh)?-at-startup/ &&
            /swayosd(-server|-libinput-backend)?([[:space:]"&]|$)/ { next }
        { print }
    ' "$NIRI_CONFIG_FILE" > "$temporary"
    mode=$(stat -c '%a' "$NIRI_CONFIG_FILE")
    group=$(id -gn "$user")
    install_if_changed "$temporary" "$NIRI_CONFIG_FILE" "$mode"
    rm -f "$temporary"
    chown "$user:$group" "$NIRI_CONFIG_FILE"
    niri_optional_startup_satisfied
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
