#!/usr/bin/env bash
set -Eeuo pipefail

# Fedora-only session, display-manager, and Shorin state contracts.  This is
# loaded after desktop-contract.sh; the generic contract keeps Arch's tty
# behavior independent while its Fedora branches call these helpers at run
# time.

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

NIRI_PATH_SAFETY_REASON=unknown

niri_path_is_safe_no_symlink() {
    local path=$1 current=/ component
    local -a components=()

    NIRI_PATH_SAFETY_REASON=unknown
    case "$path" in
        /*) ;;
        *) NIRI_PATH_SAFETY_REASON=not-absolute; return 2 ;;
    esac
    [ "$path" != / ] || {
        NIRI_PATH_SAFETY_REASON=root-path
        return 1
    }
    IFS=/ read -r -a components <<< "${path#/}"
    for component in "${components[@]}"; do
        [ -n "$component" ] || continue
        case "$component" in
            .|..) NIRI_PATH_SAFETY_REASON=path-traversal; return 2 ;;
        esac
        if [ "$current" = / ]; then
            current="/$component"
        else
            current="$current/$component"
        fi
        if [ -L "$current" ]; then
            NIRI_PATH_SAFETY_REASON="symlink:$current"
            return 1
        fi
    done
}

niri_path_tree_has_external_symlink() {
    local path=$1 link target

    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    while IFS= read -r -d '' link; do
        target=$(readlink -f -- "$link" 2>/dev/null || true)
        case "$target" in
            "$path"|"$path"/*) ;;
            *)
                NIRI_PATH_SAFETY_REASON="external-symlink:$link"
                return 1
                ;;
        esac
    done < <(find -P "$path" -mindepth 1 -type l -print0)
}

niri_safe_install_directory() {
    local owner=$1 group=$2 path=$3 current=/ component home owner_uid
    local metadata uid gid mode
    local -a components=()

    niri_path_is_safe_no_symlink "$path" || return
    home=${HOME_DIR:-}
    [ "$home" = / ] || home=${home%/}
    if [ -n "$home" ]; then
        owner_uid=$(id -u "$owner") || return 2
    fi
    IFS=/ read -r -a components <<< "${path#/}"
    for component in "${components[@]}"; do
        [ -n "$component" ] || continue
        if [ "$current" = / ]; then
            current="/$component"
        else
            current="$current/$component"
        fi
        [ ! -L "$current" ] || {
            NIRI_PATH_SAFETY_REASON="symlink:$current"
            return 1
        }
        if [ -e "$current" ]; then
            [ -d "$current" ] || return 1
            if [ -n "$home" ]; then
                case "$current" in
                    "$home"/*)
                        metadata=$(stat -c '%u:%g:%a' -- "$current") || return 1
                        IFS=: read -r uid gid mode <<< "$metadata"
                        if [ "$uid" = "$owner_uid" ]; then
                            # A target-user directory is outside the migration
                            # boundary, including its existing mode and group.
                            continue
                        fi
                        if [ "$uid:$gid:$mode" = 0:0:755 ]; then
                            # Older installer revisions created intermediate
                            # home directories as root:root 0755.  This exact
                            # legacy footprint is safe to migrate; no broader
                            # ownership repair is attempted.
                            chown "$owner:$group" "$current" || return 1
                            continue
                        fi
                        if [ "$uid:$gid" = 0:0 ]; then
                            NIRI_PATH_SAFETY_REASON="unsafe-mode:$current:$mode"
                        else
                            NIRI_PATH_SAFETY_REASON="foreign-owner:$current:$uid:$gid"
                        fi
                        return 1
                        ;;
                esac
            fi
        else
            mkdir -m 755 -- "$current" || return 1
            # mkdir runs in the privileged installer context.  When it has
            # to create an intermediate directory below the target home (for
            # example ~/Pictures before ~/Pictures/Wallpapers), claim only
            # that newly created directory.  Existing user directories are
            # deliberately left untouched.
            if [ -n "$home" ]; then
                case "$current" in
                    "$home"|"$home"/*)
                        chown "$owner:$group" "$current" || return 1
                        ;;
                esac
            fi
        fi
    done
    if [ -n "$home" ]; then
        case "$path" in
            "$home"|"$home"/*) return 0 ;;
        esac
    fi
    chown "$owner:$group" "$path"
}

niri_systemd_service_enabled_active() {
    local unit=$1 status

    command -v systemctl >/dev/null 2>&1 || return 2
    systemctl is-enabled --quiet "$unit" || {
        status=$?
        case "$status" in
            1|2|3|4|5|6|7|8|9|10) return 1 ;;
            *) return "$status" ;;
        esac
    }
    systemctl is-active --quiet "$unit" || {
        status=$?
        case "$status" in
            1|2|3|4|5|6|7|8|9|10) return 1 ;;
            *) return "$status" ;;
        esac
    }
}

niri_fedora_display_manager_provider() {
    local provider candidate status=0

    platform_is_fedora || return 1
    command -v systemctl >/dev/null 2>&1 || return 2

    # systemd exposes the selected provider through the display-manager alias.
    # `show` is preferred because it also works when /etc is read-only in a
    # verification fixture; the symlink is a useful fallback on a live host.
    provider=$(systemctl show -p Id --value "$NIRI_DISPLAY_MANAGER_UNIT" \
        2>/dev/null || true)
    if [ -z "$provider" ] && [ -L "/etc/systemd/system/$NIRI_DISPLAY_MANAGER_UNIT" ]; then
        provider=$(readlink -f "/etc/systemd/system/$NIRI_DISPLAY_MANAGER_UNIT" \
            2>/dev/null || true)
        provider=${provider##*/}
    fi
    if [ -n "$provider" ] &&
        niri_systemd_service_enabled_active "$NIRI_DISPLAY_MANAGER_UNIT"; then
        printf '%s\n' "${provider%.service}"
        return 0
    fi

    # Plasmalogin does not always install the traditional display-manager
    # alias.  Recognise its actual Fedora service and package names explicitly
    # rather than falling back to tty1.
    for candidate in plasmalogin.service plasma-login-manager.service; do
        if niri_systemd_service_enabled_active "$candidate"; then
            printf '%s\n' "${candidate%.service}"
            return 0
        fi
        status=$?
        [ "$status" -eq 1 ] || [ "$status" -eq 2 ] || return "$status"
    done
    for candidate in gdm.service sddm.service lightdm.service; do
        if niri_systemd_service_enabled_active "$candidate"; then
            printf '%s\n' "${candidate%.service}"
            return 0
        fi
        status=$?
        [ "$status" -eq 1 ] || [ "$status" -eq 2 ] || return "$status"
    done
    return 1
}

niri_fedora_display_manager_package_satisfied() {
    local provider=$1

    platform_is_fedora || return 0
    case "$provider" in
        plasmalogin|plasma-login-manager)
            package_is_installed plasma-login-manager && return 0
            ;;
        gdm|sddm|lightdm) package_is_installed "$provider" && return 0 ;;
        *) return 1 ;;
    esac
    return 1
}

niri_fedora_display_manager_satisfied() {
    local provider

    platform_is_fedora || return 0
    provider=$(niri_fedora_display_manager_provider) || return
    niri_fedora_display_manager_package_satisfied "$provider"
}

niri_fedora_wayland_session_entry_satisfied() {
    local file=${NIRI_WAYLAND_SESSION_FILE:-/usr/share/wayland-sessions/niri.desktop}

    platform_is_fedora || return 0
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /^\[Desktop Entry\][[:space:]]*$/ { desktop=1; next }
        /^\[/ { desktop=0 }
        desktop && /^[[:space:]]*Exec=/ {
            exec_count++
            if ($0 == "Exec=niri-session") match_count++
        }
        END { exit !(exec_count == 1 && match_count == 1) }
    ' "$file"
}

niri_fedora_session_contract_satisfied() {
    platform_is_fedora || return 0
    niri_fedora_display_manager_satisfied || return 1
    niri_fedora_wayland_session_entry_satisfied
}

niri_shorin_state_path() {
    printf '%s\n' "${NIRI_SHORIN_STATE_DIR:-$HOME_DIR/.local/state/shorin-arch-setup}"
}

niri_shorin_state_ownership_satisfied() {
    local user=${1:-$TARGET_USER} state_root state_dir
    local uid

    state_root=${NIRI_STATE_HOME:-${XDG_STATE_HOME:-$HOME_DIR/.local/state}}
    state_dir=$(niri_shorin_state_path)
    niri_path_is_safe_no_symlink "$state_root" || return 1
    niri_path_is_safe_no_symlink "$state_dir" || return 1
    case "$state_dir" in
        "${state_root%/}/shorin-arch-setup") ;;
        *) NIRI_PATH_SAFETY_REASON=outside-shorin-namespace; return 1 ;;
    esac
    uid=$(id -u "$user") || return 2
    [ -d "$state_root" ] && [ "$(stat -c '%u' "$state_root")" -eq "$uid" ] || return 1
    [ -d "$state_dir" ] && [ "$(stat -c '%u' "$state_dir")" -eq "$uid" ] || return 1
    niri_path_tree_has_external_symlink "$state_dir" || return 1
    niri_run_as_user "$user" test -w "$state_root" || return 1
    niri_run_as_user "$user" test -w "$state_dir" || return 1
    while IFS= read -r -d '' path; do
        [ "$(stat -c '%u' "$path")" -eq "$uid" ] || return 1
    done < <(find "$state_dir" -mindepth 1 -print0)
}

ensure_niri_shorin_state_ownership() {
    local user=${1:-$TARGET_USER} group state_root state_dir

    require_writable_mode || return
    state_root=${NIRI_STATE_HOME:-${XDG_STATE_HOME:-$HOME_DIR/.local/state}}
    state_dir=$(niri_shorin_state_path)
    niri_path_is_safe_no_symlink "$state_root" || return 1
    niri_path_is_safe_no_symlink "$state_dir" || return 1
    case "$state_dir" in
        "${state_root%/}/shorin-arch-setup") ;;
        *) NIRI_PATH_SAFETY_REASON=outside-shorin-namespace; return 1 ;;
    esac
    if [ -d "$state_dir" ] && ! niri_path_tree_has_external_symlink "$state_dir"; then
        case "$NIRI_PATH_SAFETY_REASON" in
            external-symlink:*) ;;
            *) NIRI_PATH_SAFETY_REASON=namespace-symlink ;;
        esac
        return 1
    fi
    group=$(id -gn "$user") || return 1
    # Only the state root itself and the named Shorin namespace are managed;
    # sibling application state under ~/.local/state is never traversed.
    niri_safe_install_directory "$user" "$group" "$state_root" || return 1
    niri_safe_install_directory "$user" "$group" "$state_dir" || return 1
    find -P "$state_dir" -mindepth 1 -exec chown -h "$user:$group" {} + || return 1
    niri_shorin_state_ownership_satisfied "$user"
}
