#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# All target-user providers share one lock.  The lock is deliberately outside
# the destination tree so an interrupted or concurrent provider cannot make
# the destination itself the synchronization primitive.
fedora_provider_lock_acquire() {
    local lock_fd

    [ -n "${FEDORA_PROVIDER_LOCK_FD:-}" ] && return 0
    command -v flock >/dev/null 2>&1 || {
        error 'Fedora providers require the flock utility for transactional installation.'
        return 2
    }
    exec {lock_fd}>>/tmp/shorin-fedora-providers.lock || return 2
    if ! flock -x "$lock_fd"; then
        eval "exec ${lock_fd}>&-"
        return 2
    fi
    FEDORA_PROVIDER_LOCK_FD=$lock_fd
}

fedora_provider_lock_release() {
    local lock_fd=${FEDORA_PROVIDER_LOCK_FD:-}

    [ -n "$lock_fd" ] || return 0
    flock -u "$lock_fd" >/dev/null 2>&1 || true
    eval "exec ${lock_fd}>&-"
    unset FEDORA_PROVIDER_LOCK_FD
}

# An inode plus digest identifies the exact provider output.  A digest alone
# is insufficient because a user may replace a file with identical content
# while the provider is doing post-install checks.
fedora_provider_file_identity() {
    local path=$1 inode digest

    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    inode=$(stat -c '%i' -- "$path") || return 2
    digest=$(sha256sum -- "$path" | awk '{print $1}') || return 2
    printf '%s:%s\n' "$inode" "$digest"
}

fedora_provider_directory_identity() {
    local path=$1

    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    stat -c '%i:%u:%g:%a' -- "$path"
}

fedora_provider_remove_directory_if_unchanged() {
    local path=$1 expected=$2 current

    [ -e "$path" ] || return 0
    if [ ! -d "$path" ] || [ -L "$path" ]; then
        error "Provider rollback conflict; preserving non-directory font path: $path"
        return 2
    fi
    current=$(fedora_provider_directory_identity "$path") || return 2
    if [ "$current" != "$expected" ]; then
        error "Provider rollback conflict; preserving concurrent font directory: $path"
        return 2
    fi
    if rmdir -- "$path"; then
        return 0
    fi
    error "Provider rollback conflict; preserving concurrent font files: $path"
    return 2
}

fedora_provider_remove_if_unchanged() {
    local path=$1 expected=$2 current

    [ -e "$path" ] || return 0
    if [ ! -f "$path" ] || [ -L "$path" ]; then
        error "Provider rollback conflict; preserving non-regular user path: $path"
        return 2
    fi
    current=$(fedora_provider_file_identity "$path") || return 2
    if [ "$current" = "$expected" ]; then
        rm -f -- "$path"
        return 0
    fi
    error "Provider rollback conflict; preserving concurrent user file: $path"
    return 2
}

fedora_restore_desktop_provider_transaction() {
    local user=$1 home=$2 font_dir=$3 before_dir_owner=$4 before_dir_mode=$5
    local before_dir_identity=$6 starship_path=$7 starship_present=$8
    local record path expected current='' conflict=0

    if [ "$starship_present" -eq 0 ] &&
        [ -n "${FEDORA_PROVIDER_LAST_WRITTEN_STARSHIP:-}" ]; then
        record=$FEDORA_PROVIDER_LAST_WRITTEN_STARSHIP
        path=${record%%|*}
        expected=${record#*|}
        if ! fedora_provider_remove_if_unchanged "$path" "$expected"; then
            conflict=1
        fi
    fi
    while IFS='|' read -r path expected; do
        [ -n "$path" ] || continue
        if ! fedora_provider_remove_if_unchanged "$path" "$expected"; then
            conflict=1
        fi
    done <<< "${FEDORA_PROVIDER_WRITTEN_FILES:-}"

    if [ -n "$before_dir_owner" ] && [ -d "$font_dir" ] &&
        [ ! -L "$font_dir" ]; then
        current=$(fedora_provider_directory_identity "$font_dir") || conflict=1
        if [ "$current" = "$before_dir_identity" ]; then
            chown "$before_dir_owner" "$font_dir" 2>/dev/null || conflict=1
            chmod "$before_dir_mode" "$font_dir" 2>/dev/null || conflict=1
        else
            error "Provider rollback conflict; preserving concurrent font directory: $font_dir"
            conflict=1
        fi
    elif [ -z "$before_dir_owner" ] &&
        [ -n "${FEDORA_PROVIDER_CREATED_FONT_DIR_IDENTITY:-}" ]; then
        fedora_provider_remove_directory_if_unchanged "$font_dir" \
            "$FEDORA_PROVIDER_CREATED_FONT_DIR_IDENTITY" || conflict=1
    fi
    if fedora_target_user_command_path "$user" "$home" fc-cache >/dev/null 2>&1; then
        fedora_target_user_exec "$user" "$home" fc-cache -f "$font_dir" \
            >/dev/null 2>&1 || true
    fi
    [ "$conflict" -eq 0 ]
}

fedora_install_desktop_providers() {
    platform_is_fedora || return 0
    local user=${1:-${TARGET_USER:-}} home=${2:-${HOME_DIR:-}}
    local font_dir starship_path before_dir_owner before_dir_mode before_dir_identity
    local starship_present=0 status=0

    require_writable_mode || return
    [ -n "$user" ] && [ -n "$home" ] || return 2
    fedora_provider_architecture_satisfied || return
    fedora_provider_lock_acquire || return
    FEDORA_PROVIDER_LAST_WRITTEN_STARSHIP=''
    FEDORA_PROVIDER_WRITTEN_FILES=''
    FEDORA_PROVIDER_CREATED_FONT_DIR_IDENTITY=''

    font_dir=$(fedora_shorin_font_dir "$home") || {
        fedora_provider_lock_release
        return 1
    }
    starship_path=$(fedora_starship_binary_path starship "$home") || {
        fedora_provider_lock_release
        return 1
    }
    if [ -e "$starship_path" ] || [ -L "$starship_path" ]; then
        starship_present=1
    fi
    before_dir_owner=''
    before_dir_mode=''
    before_dir_identity=''
    if [ -d "$font_dir" ] && [ ! -L "$font_dir" ]; then
        before_dir_owner=$(stat -c '%u:%g' "$font_dir" 2>/dev/null) || {
            fedora_provider_lock_release
            return 2
        }
        before_dir_mode=$(stat -c '%a' "$font_dir" 2>/dev/null) || {
            fedora_provider_lock_release
            return 2
        }
        before_dir_identity=$(fedora_provider_directory_identity "$font_dir") || {
            fedora_provider_lock_release
            return 2
        }
    fi
    if ! _fedora_install_starship_unlocked "$user" "$home"; then
        fedora_provider_lock_release
        return 1
    fi
    if ! _fedora_install_desktop_font_provider_unlocked "$user" "$home"; then
        if ! fedora_restore_desktop_provider_transaction "$user" "$home" \
            "$font_dir" "$before_dir_owner" "$before_dir_mode" \
            "$before_dir_identity" \
            "$starship_path" "$starship_present"; then
            status=1
        fi
        fedora_provider_lock_release
        return 1
    fi
    fedora_provider_lock_release
    return "$status"
}
