#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]:-unknown}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Small, path-oriented transaction primitive shared by dotfiles and session
# convergence.  Each target is snapshotted once, restored in reverse order,
# and removed from the transaction directory on commit or rollback.
niri_desktop_txn_begin() {
    local root=${1:-${TMPDIR:-/tmp}}

    NIRI_DESKTOP_TXN_DIR=$(mktemp -d "$root/shorin-desktop-txn.XXXXXX") ||
        return 1
    NIRI_DESKTOP_TXN_PATHS=()
    NIRI_DESKTOP_TXN_BACKUPS=()
    NIRI_DESKTOP_TXN_PRESENT=()
}

niri_desktop_txn_snapshot() {
    local path=$1 index backup existing mode

    [ -n "${NIRI_DESKTOP_TXN_DIR:-}" ] || return 1
    for existing in "${NIRI_DESKTOP_TXN_PATHS[@]:-}"; do
        [ "$existing" = "$path" ] && return 0
    done
    index=${#NIRI_DESKTOP_TXN_PATHS[@]}
    backup="$NIRI_DESKTOP_TXN_DIR/entry-$index"
    if [ -e "$path" ] || [ -L "$path" ]; then
        mode=$(stat -c '%a' "$path") || return 1
        if [ -f "$path" ] && [ ! -L "$path" ] &&
            [ ! -r "$path" ]; then
            if ! chmod u+r "$path" || ! cp -a "$path" "$backup"; then
                chmod "$mode" "$path" || true
                return 1
            fi
            chmod "$mode" "$path" || return 1
        elif [ -d "$path" ] && [ ! -L "$path" ] &&
            [ ! -r "$path" ]; then
            if ! chmod u+rx "$path" || ! cp -a "$path" "$backup"; then
                chmod "$mode" "$path" || true
                return 1
            fi
            chmod "$mode" "$path" || return 1
        elif ! cp -a "$path" "$backup"; then
            return 1
        fi
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
    find "$path" -depth -delete
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
            cp -a "$backup" "$path" || status=1
        fi
    done
    return "$status"
}

niri_desktop_txn_finish() {
    local status=${1:-0}

    if [ "$status" -ne 0 ]; then
        niri_desktop_txn_restore || status=1
    fi
    if [ -n "${NIRI_DESKTOP_TXN_DIR:-}" ]; then
        find "$NIRI_DESKTOP_TXN_DIR" -depth -delete || status=1
    fi
    unset NIRI_DESKTOP_TXN_DIR NIRI_DESKTOP_TXN_PATHS \
        NIRI_DESKTOP_TXN_BACKUPS NIRI_DESKTOP_TXN_PRESENT
    return "$status"
}
