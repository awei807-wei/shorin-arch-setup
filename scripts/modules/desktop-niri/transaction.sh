#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Small, path-oriented transaction primitive shared by dotfiles and session
# convergence.  The dotfiles source still has a sizeable /tmp checkout, so
# transaction backups deliberately use persistent storage outside TMPDIR.
# Fedora's default Btrfs layout can reflink HOME data into /var/tmp cheaply;
# cp falls back to a regular copy on filesystems without reflink support.
#
# Snapshot callers must register an ancestor before any of its descendants.
# A descendant is then already represented by the ancestor backup and is not
# copied again.  Registering an ancestor after a descendant is rejected: the
# descendant might already have changed, so silently folding it into a later
# recursive copy would make rollback inexact.

niri_desktop_txn_default_root() {
    printf '%s\n' /var/tmp/shorin-arch-setup/transactions
}

niri_desktop_txn_normalize_path() {
    local path=$1

    [ -n "$path" ] && [[ "$path" = /* ]] || return 1
    command -v realpath >/dev/null 2>&1 || return 1
    realpath -ms -- "$path"
}

niri_desktop_txn_path_contains() {
    local ancestor=$1 descendant=$2

    [ "$ancestor" = "$descendant" ] && return 0
    [ "$ancestor" != / ] || return 0
    case "$descendant" in
        "$ancestor"/*) return 0 ;;
        *) return 1 ;;
    esac
}

niri_desktop_txn_path_has_symlink_component() {
    local path=$1 current=/ component remainder

    path=$(niri_desktop_txn_normalize_path "$path") || return 0
    remainder=${path#/}
    while [ -n "$remainder" ]; do
        component=${remainder%%/*}
        if [ "$component" = "$remainder" ]; then
            remainder=
        else
            remainder=${remainder#*/}
        fi
        [ -n "$component" ] || continue
        current=${current%/}/$component
        [ ! -L "$current" ] || return 0
    done
    return 1
}

niri_desktop_txn_parent_is_safe() {
    local path=$1 parent mode mode_value uid

    parent=$(dirname "$path") || return 1
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    ! niri_desktop_txn_path_has_symlink_component "$parent" || return 1
    uid=$(stat -c '%u' "$parent") || return 1
    mode=$(stat -c '%a' "$parent") || return 1
    mode_value=$((8#$mode))

    # A transaction root may live below a directory owned by this process or
    # root.  Writable shared parents are only safe when protected by sticky.
    { [ "$uid" -eq "$(id -u)" ] || [ "$uid" -eq 0 ]; } || return 1
    if (( (mode_value & 0022) != 0 && (mode_value & 01000) == 0 )); then
        return 1
    fi
}

niri_desktop_txn_directory_matches() {
    local path=$1 expected_uid=$2 expected_gid=$3

    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    [ "$(stat -c '%u' "$path")" -eq "$expected_uid" ] || return 1
    [ "$(stat -c '%g' "$path")" -eq "$expected_gid" ] || return 1
    [ "$(stat -c '%a' "$path")" = 700 ]
}

niri_desktop_txn_prepare_directory() {
    local path=$1 expected_uid=$2 expected_gid=$3

    ! niri_desktop_txn_path_has_symlink_component "$path" || return 1
    if [ -e "$path" ]; then
        niri_desktop_txn_directory_matches "$path" "$expected_uid" \
            "$expected_gid"
        return
    fi
    niri_desktop_txn_parent_is_safe "$path" || return 1
    mkdir -- "$path" || return 1
    chmod 0700 "$path" || return 1
    niri_desktop_txn_directory_matches "$path" "$expected_uid" \
        "$expected_gid"
}

niri_desktop_txn_prepare_root() {
    local root=$1 expected_uid expected_gid default_root namespace

    expected_uid=$(id -u) || return 1
    expected_gid=$(id -g) || return 1
    root=$(niri_desktop_txn_normalize_path "$root") || return 1
    default_root=$(niri_desktop_txn_default_root)

    if [ "$root" = "$default_root" ]; then
        [ "$expected_uid" -eq 0 ] || {
            printf 'ERROR: The default desktop transaction root requires root.\n' >&2
            return 1
        }
        [ -d /var/tmp ] && [ ! -L /var/tmp ] || return 1
        [ "$(stat -c '%u' /var/tmp)" -eq 0 ] || return 1
        namespace=/var/tmp/shorin-arch-setup
        niri_desktop_txn_prepare_directory "$namespace" 0 0 || return 1
        niri_desktop_txn_prepare_directory "$root" 0 0 || return 1
    else
        niri_desktop_txn_prepare_directory "$root" "$expected_uid" \
            "$expected_gid" || return 1
    fi
    printf '%s\n' "$root"
}

niri_desktop_txn_begin() {
    local requested_root=${1:-${NIRI_DESKTOP_TXN_ROOT:-}} root

    [ -z "${NIRI_DESKTOP_TXN_DIR:-}" ] || {
        printf 'ERROR: A desktop transaction is already active.\n' >&2
        return 1
    }
    [ -n "$requested_root" ] || requested_root=$(niri_desktop_txn_default_root)
    root=$(niri_desktop_txn_prepare_root "$requested_root") || {
        printf 'ERROR: Unsafe desktop transaction root: %s\n' \
            "$requested_root" >&2
        return 1
    }
    NIRI_DESKTOP_TXN_ROOT_ACTIVE=$root
    NIRI_DESKTOP_TXN_DIR=$(mktemp -d "$root/txn.XXXXXX") || {
        unset NIRI_DESKTOP_TXN_ROOT_ACTIVE
        return 1
    }
    if ! chmod 0700 "$NIRI_DESKTOP_TXN_DIR" ||
        ! niri_desktop_txn_directory_matches "$NIRI_DESKTOP_TXN_DIR" \
            "$(id -u)" "$(id -g)"; then
        find -P "$NIRI_DESKTOP_TXN_DIR" -xdev -depth -delete 2>/dev/null || true
        unset NIRI_DESKTOP_TXN_DIR NIRI_DESKTOP_TXN_ROOT_ACTIVE
        return 1
    fi
    NIRI_DESKTOP_TXN_PATHS=()
    NIRI_DESKTOP_TXN_BACKUPS=()
    NIRI_DESKTOP_TXN_PRESENT=()
}

niri_desktop_txn_copy() {
    local source=$1 destination=$2 mode

    if [ -f "$source" ] && [ ! -L "$source" ] && [ ! -r "$source" ]; then
        mode=$(stat -c '%a' "$source") || return 1
        if ! chmod u+r "$source" ||
            ! cp -a --reflink=auto -- "$source" "$destination"; then
            chmod "$mode" "$source" || true
            return 1
        fi
        chmod "$mode" "$source" || return 1
    elif [ -d "$source" ] && [ ! -L "$source" ] && [ ! -r "$source" ]; then
        mode=$(stat -c '%a' "$source") || return 1
        if ! chmod u+rx "$source" ||
            ! cp -a --reflink=auto -- "$source" "$destination"; then
            chmod "$mode" "$source" || true
            return 1
        fi
        chmod "$mode" "$source" || return 1
    else
        cp -a --reflink=auto -- "$source" "$destination"
    fi
}

niri_desktop_txn_snapshot() {
    local requested_path=$1 path index backup existing

    [ -n "${NIRI_DESKTOP_TXN_DIR:-}" ] || return 1
    path=$(niri_desktop_txn_normalize_path "$requested_path") || return 1
    [ "$path" != / ] || return 1
    ! niri_desktop_txn_path_has_symlink_component "$(dirname "$path")" || {
        printf 'ERROR: Refusing a transaction target below a symlink: %s\n' \
            "$requested_path" >&2
        return 1
    }
    if niri_desktop_txn_path_contains "$path" "$NIRI_DESKTOP_TXN_DIR" ||
        niri_desktop_txn_path_contains "$NIRI_DESKTOP_TXN_DIR" "$path"; then
        printf 'ERROR: Transaction target overlaps its backup directory: %s\n' \
            "$requested_path" >&2
        return 1
    fi

    for index in "${!NIRI_DESKTOP_TXN_PATHS[@]}"; do
        existing=${NIRI_DESKTOP_TXN_PATHS[index]}
        [ "$existing" != "$path" ] || return 0
        if niri_desktop_txn_path_contains "$existing" "$path"; then
            return 0
        fi
        if niri_desktop_txn_path_contains "$path" "$existing"; then
            printf 'ERROR: Register transaction ancestors before descendants: %s\n' \
                "$requested_path" >&2
            return 1
        fi
    done

    index=${#NIRI_DESKTOP_TXN_PATHS[@]}
    backup="$NIRI_DESKTOP_TXN_DIR/entry-$index"
    if [ -e "$path" ] || [ -L "$path" ]; then
        niri_desktop_txn_copy "$path" "$backup" || return 1
        NIRI_DESKTOP_TXN_PRESENT[index]=1
    else
        NIRI_DESKTOP_TXN_PRESENT[index]=0
    fi
    NIRI_DESKTOP_TXN_PATHS[index]="$path"
    NIRI_DESKTOP_TXN_BACKUPS[index]="$backup"
}

niri_desktop_txn_remove_path() {
    local path=$1

    [ -e "$path" ] || [ -L "$path" ] || return 0
    ! niri_desktop_txn_path_has_symlink_component "$(dirname "$path")" ||
        return 1
    find -P "$path" -xdev -depth -delete
}

niri_desktop_txn_restore() {
    local index path backup status=0

    for ((index=${#NIRI_DESKTOP_TXN_PATHS[@]} - 1; index >= 0; index--)); do
        path=${NIRI_DESKTOP_TXN_PATHS[index]}
        backup=${NIRI_DESKTOP_TXN_BACKUPS[index]}
        if ! niri_desktop_txn_remove_path "$path"; then
            status=1
            continue
        fi
        if [ "${NIRI_DESKTOP_TXN_PRESENT[index]}" -eq 1 ]; then
            install -d "$(dirname "$path")" || status=1
            cp -a --reflink=auto -- "$backup" "$path" || status=1
        fi
    done
    return "$status"
}

niri_desktop_txn_cleanup() {
    local directory=${NIRI_DESKTOP_TXN_DIR:-}

    [ -n "$directory" ] || return 0
    niri_desktop_txn_directory_matches "$directory" "$(id -u)" "$(id -g)" ||
        return 1
    niri_desktop_txn_remove_path "$directory"
}

niri_desktop_txn_finish() {
    local status=${1:-0}

    if [ "$status" -ne 0 ]; then
        niri_desktop_txn_restore || status=1
    fi
    niri_desktop_txn_cleanup || status=1
    unset NIRI_DESKTOP_TXN_DIR NIRI_DESKTOP_TXN_ROOT_ACTIVE \
        NIRI_DESKTOP_TXN_PATHS NIRI_DESKTOP_TXN_BACKUPS \
        NIRI_DESKTOP_TXN_PRESENT
    return "$status"
}
