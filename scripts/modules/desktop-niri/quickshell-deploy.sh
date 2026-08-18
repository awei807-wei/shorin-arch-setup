#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]:-unknown}" "$LINENO" "$BASH_COMMAND" >&2' ERR

niri_quickshell_remove_tree() {
    local root=$1

    [ -e "$root" ] || [ -L "$root" ] || return 0
    find "$root" -depth -delete
}

niri_transform_quickshell_cava_file_in_place() {
    local file=$1 temporary mode

    platform_is_fedora || return 0
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    case "$file" in
        */scripts/cava.sh) ;;
        *) return 0 ;;
    esac
    temporary=$(mktemp)
    if ! awk -f "$SHORIN_ROOT/scripts/modules/desktop-niri/fedora-quickshell-cava-compatibility.awk" \
        "$file" > "$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    if cmp -s "$temporary" "$file"; then
        rm -f "$temporary"
        return 0
    fi
    mode=$(stat -c '%a' "$file")
    if ! install -m "$mode" "$temporary" "$file"; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
}

niri_transform_quickshell_cava_tree() {
    local root=$1 file

    [ -d "$root" ] || return 1
    while IFS= read -r -d '' file; do
        niri_transform_quickshell_cava_file_in_place "$file" || return
    done < <(find "$root" -type f -print0)
}

niri_quickshell_stage_source() {
    local source=$1 parent stage

    require_writable_mode || return 1
    niri_quickshell_tree_contract "$source" || return 1
    parent=$(dirname "$NIRI_QUICKSHELL_DIR")
    install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" "$parent"
    stage=$(mktemp -d "$parent/.quickshell-stage.XXXXXX")
    if ! cp -a "$source/." "$stage/"; then
        niri_quickshell_remove_tree "$stage"
        return 1
    fi
    # Fedora receives the Cava bridge hardening in staging.  Keep the source
    # checkout untouched and preserve Arch's byte-for-byte QuickShell payload.
    if platform_is_fedora && ! niri_transform_quickshell_cava_tree "$stage"; then
        niri_quickshell_remove_tree "$stage"
        return 1
    fi
    # Fedora receives the platform compatibility pass in staging.  Arch keeps
    # the checkout tree intact; its existing session migration handles the
    # common awww backend conversion after the atomic install.
    if platform_is_fedora && ! niri_transform_wallpaper_tree "$stage"; then
        niri_quickshell_remove_tree "$stage"
        return 1
    fi
    # Validate the staged copy itself before touching the live tree.  The
    # structural contract is distribution-neutral; the Fedora-only static
    # wallpaper contract below deliberately remains separate so Arch keeps
    # the upstream QuickShell payload byte-for-byte.
    if ! niri_quickshell_tree_contract "$stage"; then
        niri_quickshell_remove_tree "$stage"
        return 1
    fi
    if platform_is_fedora && ! niri_quickshell_static_contract "$stage"; then
        niri_quickshell_remove_tree "$stage"
        return 1
    fi
    printf '%s\n' "$stage"
}

niri_quickshell_write_state() {
    local state_tmp=$1 commit=$2 platform=$3 digest=$4

    if ! install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" \
        "$NIRI_DESKTOP_STATE_DIR"; then
        return 1
    fi
    cat > "$state_tmp" <<EOF
commit=$commit
platform=$platform
digest=$digest
EOF
}

niri_quickshell_update_state() {
    local commit=$1 platform=$2 digest=$3 state_tmp state_backup state_had=0
    local status=0 group state_dir_had=0

    require_writable_mode || return 1
    [ -d "$NIRI_DESKTOP_STATE_DIR" ] && state_dir_had=1
    if ! install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" \
        "$NIRI_DESKTOP_STATE_DIR"; then
        return 1
    fi
    if ! state_backup=$(mktemp); then
        if [ "$state_dir_had" -eq 0 ]; then
            rmdir "$NIRI_DESKTOP_STATE_DIR" 2>/dev/null || true
        fi
        return 1
    fi
    if ! rm -f "$state_backup"; then
        niri_quickshell_remove_tree "$state_backup" || true
        if [ "$state_dir_had" -eq 0 ] &&
            [ ! -e "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ] &&
            [ ! -L "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ]; then
            rmdir "$NIRI_DESKTOP_STATE_DIR" 2>/dev/null || true
        fi
        return 1
    fi
    if [ -e "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ] ||
        [ -L "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ]; then
        state_had=1
        cp -a "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" "$state_backup" || {
            niri_quickshell_remove_tree "$state_backup" || true
            if [ "$state_dir_had" -eq 0 ]; then
                rmdir "$NIRI_DESKTOP_STATE_DIR" 2>/dev/null || true
            fi
            return 1
        }
    fi
    if ! state_tmp=$(mktemp "$NIRI_DESKTOP_STATE_DIR/.quickshell-source.XXXXXX"); then
        niri_quickshell_remove_tree "$state_backup" || true
        if [ "$state_dir_had" -eq 0 ]; then
            rmdir "$NIRI_DESKTOP_STATE_DIR" 2>/dev/null || true
        fi
        return 1
    fi
    if ! niri_quickshell_write_state "$state_tmp" "$commit" "$platform" "$digest" ||
        ! install_if_changed "$state_tmp" "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" 644; then
        status=1
    else
        group=$(id -gn "$TARGET_USER")
        chown "$TARGET_USER:$group" "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ||
            status=1
    fi
    if ! rm -f "$state_tmp"; then
        status=1
    fi
    if [ "$status" -ne 0 ]; then
        niri_quickshell_remove_tree "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" || true
        if [ "$state_had" -eq 1 ]; then
            install -d "$(dirname "$NIRI_QUICKSHELL_SOURCE_STATE_FILE")" || status=1
            cp -a "$state_backup" "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" || status=1
        fi
    fi
    niri_quickshell_remove_tree "$state_backup" || true
    if [ "$status" -ne 0 ] && [ "$state_dir_had" -eq 0 ] &&
        [ ! -e "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ] &&
        [ ! -L "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ]; then
        rmdir "$NIRI_DESKTOP_STATE_DIR" 2>/dev/null || true
    fi
    return "$status"
}

niri_quickshell_tree_equal() {
    local left=$1 right=$2 left_digest right_digest

    [ -d "$left" ] && [ -d "$right" ] || return 1
    left_digest=$(niri_quickshell_tree_digest "$left") || return 1
    right_digest=$(niri_quickshell_tree_digest "$right") || return 1
    [ "$left_digest" = "$right_digest" ]
}

niri_quickshell_backup_live_tree() {
    local live=$1 backup=$2 target mode uid gid

    if [ -L "$live" ]; then
        # cp -a "$live/." would follow a top-level symlink and lose the
        # user's indirection.  Keep the exact link text and lstat metadata as
        # a durable recovery record while the live path is atomically replaced
        # by a directory.  The metadata also preserves relative links whose
        # target would resolve differently below the backup directory.
        target=$(readlink "$live") || return 1
        mode=$(stat -c '%a' "$live") || return 1
        uid=$(stat -c '%u' "$live") || return 1
        gid=$(stat -c '%g' "$live") || return 1
        ln -s "$target" "$backup/quickshell"
        chown -h "$uid:$gid" "$backup/quickshell" || return 1
        printf 'version=1\npath=%s\nlink_target=%s\nmode=%s\nuid=%s\ngid=%s\n' \
            "$live" "$target" "$mode" "$uid" "$gid" \
            > "$backup/quickshell.link"
        chown "$uid:$gid" "$backup/quickshell.link" || return 1
        return 0
    fi
    [ -d "$live" ] || return 1
    cp -a "$live/." "$backup/"
}

niri_quickshell_atomic_replace() {
    local staged=$1 user=$2 commit=$3 platform=$4
    local parent old_hold backup state_tmp state_backup digest live_digest group
    local had_old=0 state_had=0 status=0 state_dir_had=0 backup_dir_had=0

    require_writable_mode || return 1
    parent=$(dirname "$NIRI_QUICKSHELL_DIR")
    group=$(id -gn "$user")
    [ -d "$NIRI_DESKTOP_STATE_DIR" ] && state_dir_had=1
    [ -d "$NIRI_QUICKSHELL_BACKUP_DIR" ] && backup_dir_had=1
    digest=$(niri_quickshell_tree_digest "$staged") || return 1
    if ! state_backup=$(mktemp); then
        niri_quickshell_remove_tree "$staged" || true
        return 1
    fi
    if ! rm -f "$state_backup"; then
        niri_quickshell_remove_tree "$state_backup" || true
        niri_quickshell_remove_tree "$staged" || true
        return 1
    fi
    if [ -e "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ] ||
        [ -L "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ]; then
        state_had=1
        if ! cp -a "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" "$state_backup"; then
            niri_quickshell_remove_tree "$state_backup" || true
            niri_quickshell_remove_tree "$staged" || true
            return 1
        fi
    fi
    if [ -d "$NIRI_QUICKSHELL_DIR" ] && [ ! -L "$NIRI_QUICKSHELL_DIR" ]; then
        if ! live_digest=$(niri_quickshell_tree_digest "$NIRI_QUICKSHELL_DIR"); then
            niri_quickshell_remove_tree "$staged" || true
            niri_quickshell_remove_tree "$state_backup" || true
            return 1
        fi
    fi
    if [ -n "${live_digest:-}" ] && [ "$digest" = "$live_digest" ]; then
        if ! niri_quickshell_update_state "$commit" "$platform" "$digest"; then
            niri_quickshell_remove_tree "$staged" || true
            niri_quickshell_remove_tree "$state_backup" || true
            return 1
        fi
        niri_quickshell_remove_tree "$staged" ||
            warn 'Unable to clean the identical QuickShell staging directory; deployment is still consistent.'
        niri_quickshell_remove_tree "$state_backup" || true
        return 0
    fi

    if [ -e "$NIRI_QUICKSHELL_DIR" ] || [ -L "$NIRI_QUICKSHELL_DIR" ]; then
        had_old=1
        if ! install -d -o "$user" -g "$group" "$NIRI_QUICKSHELL_BACKUP_DIR"; then
            niri_quickshell_remove_tree "$staged" || true
            niri_quickshell_remove_tree "$state_backup" || true
            return 1
        fi
        backup="$NIRI_QUICKSHELL_BACKUP_DIR/$(date +%Y%m%d%H%M%S)-${commit:0:12}"
        [ ! -e "$backup" ] || backup="${backup}-$$"
        if ! install -d -o "$user" -g "$group" "$backup"; then
            niri_quickshell_remove_tree "$backup" || true
            niri_quickshell_remove_tree "$staged" || true
            niri_quickshell_remove_tree "$state_backup" || true
            if [ "$backup_dir_had" -eq 0 ]; then
                rmdir "$NIRI_QUICKSHELL_BACKUP_DIR" 2>/dev/null || true
            fi
            return 1
        fi
        if ! niri_quickshell_backup_live_tree "$NIRI_QUICKSHELL_DIR" \
            "$backup"; then
            niri_quickshell_remove_tree "$backup" || true
            niri_quickshell_remove_tree "$staged" || true
            niri_quickshell_remove_tree "$state_backup" || true
            return 1
        fi
        old_hold=$(mktemp -d "$parent/.quickshell-old.XXXXXX")
        rmdir "$old_hold" || {
            niri_quickshell_remove_tree "$backup" || true
            niri_quickshell_remove_tree "$staged" || true
            niri_quickshell_remove_tree "$state_backup" || true
            if [ "$backup_dir_had" -eq 0 ]; then
                rmdir "$NIRI_QUICKSHELL_BACKUP_DIR" 2>/dev/null || true
            fi
            return 1
        }
        if ! mv "$NIRI_QUICKSHELL_DIR" "$old_hold"; then
            niri_quickshell_remove_tree "$backup" || true
            niri_quickshell_remove_tree "$staged" || true
            niri_quickshell_remove_tree "$state_backup" || true
            if [ "$backup_dir_had" -eq 0 ]; then
                rmdir "$NIRI_QUICKSHELL_BACKUP_DIR" 2>/dev/null || true
            fi
            return 1
        fi
    fi

    if ! mv "$staged" "$NIRI_QUICKSHELL_DIR"; then
        [ "$had_old" -eq 0 ] || mv "$old_hold" "$NIRI_QUICKSHELL_DIR" || true
        niri_quickshell_remove_tree "$backup" || true
        niri_quickshell_remove_tree "$staged" || true
        niri_quickshell_remove_tree "$state_backup" || true
        return 1
    fi
    if ! chown -R "$user:$group" "$NIRI_QUICKSHELL_DIR"; then
        status=1
    fi

    if [ "$status" -eq 0 ] &&
        ! install -d -o "$user" -g "$group" "$NIRI_DESKTOP_STATE_DIR"; then
        status=1
    fi
    if [ "$status" -eq 0 ] &&
        ! state_tmp=$(mktemp "$NIRI_DESKTOP_STATE_DIR/.quickshell-source.XXXXXX"); then
        status=1
    fi
    if [ "$status" -eq 0 ] &&
        ! niri_quickshell_write_state "$state_tmp" "$commit" "$platform" "$digest"; then
        status=1
    fi
    if [ "$status" -eq 0 ] &&
        { ! install_if_changed "$state_tmp" "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" 644 ||
            ! chown "$user:$group" "$NIRI_QUICKSHELL_SOURCE_STATE_FILE"; }; then
        status=1
    fi
    if [ -n "${state_tmp:-}" ] && ! rm -f "$state_tmp"; then
        status=1
    fi
    if [ "$status" -ne 0 ]; then
        niri_quickshell_remove_tree "$NIRI_QUICKSHELL_DIR" || true
        if [ "$had_old" -eq 1 ]; then
            mv "$old_hold" "$NIRI_QUICKSHELL_DIR" || status=1
        fi
        niri_quickshell_remove_tree "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" || true
        if [ "$state_had" -eq 1 ]; then
            install -d "$(dirname "$NIRI_QUICKSHELL_SOURCE_STATE_FILE")" || status=1
            cp -a "$state_backup" "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" || status=1
        fi
        niri_quickshell_remove_tree "$backup" || true
        niri_quickshell_remove_tree "$staged" || true
        niri_quickshell_remove_tree "$state_backup" || true
        if [ "$backup_dir_had" -eq 0 ]; then
            rmdir "$NIRI_QUICKSHELL_BACKUP_DIR" 2>/dev/null || true
        fi
        if [ "$state_dir_had" -eq 0 ]; then
            rmdir "$NIRI_DESKTOP_STATE_DIR" 2>/dev/null || true
        fi
        return "$status"
    fi
    if [ "$had_old" -eq 1 ] &&
        ! niri_quickshell_remove_tree "$old_hold"; then
        warn 'Unable to clean the old QuickShell hold; deployment and source state remain consistent.'
    fi
    niri_quickshell_remove_tree "$state_backup" || true
    return 0
}

niri_quickshell_stage_and_deploy() {
    local checkout=$1 user=$2 source stage commit platform

    require_writable_mode || return 1
    source="$checkout/dotfiles/.config/quickshell"
    niri_quickshell_tree_contract "$source" || return 1
    stage=$(niri_quickshell_stage_source "$source") || return 1
    commit=$(git -C "$checkout" rev-parse HEAD) || {
        niri_quickshell_remove_tree "$stage"
        return 1
    }
    if platform_is_fedora; then platform=fedora; else platform=arch; fi
    niri_quickshell_atomic_replace "$stage" "$user" "$commit" "$platform"
}

niri_quickshell_refresh_state_digest() {
    local expected_before=${1:-} commit platform recorded_digest current_digest

    [ -d "$NIRI_QUICKSHELL_DIR" ] || return 1
    commit=$(niri_quickshell_state_value commit) || return 1
    platform=$(niri_quickshell_state_value platform) || return 1
    recorded_digest=$(niri_quickshell_state_value digest) || return 1
    if [ -z "$expected_before" ]; then
        expected_before=$recorded_digest
    fi
    [ "$recorded_digest" = "$expected_before" ] || return 1
    current_digest=$(niri_quickshell_tree_digest "$NIRI_QUICKSHELL_DIR") ||
        return 1
    niri_quickshell_tree_contract "$NIRI_QUICKSHELL_DIR" || return 1
    niri_quickshell_static_contract "$NIRI_QUICKSHELL_DIR" || return 1
    niri_quickshell_wallpaper_backend_satisfied || return 1
    if [ "$current_digest" = "$expected_before" ]; then
        return 0
    fi
    [ -n "${1:-}" ] || return 1
    niri_quickshell_update_state "$commit" "$platform" "$current_digest"
}
