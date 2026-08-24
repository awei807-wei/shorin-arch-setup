#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
TARGET_USER=$(id -un)
TARGET_GROUP=$(id -gn)
CHOWN_LOG=$TEST_DIR/chown.log
STAT_OVERRIDE_FILE=$TEST_DIR/stat-override
export HOME_DIR=$TEST_DIR/home

cleanup() {
    find "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

# Record ownership operations so this regression remains meaningful when the
# test itself is not running as root.  Filesystem creation remains real.
chown() {
    printf '%s\t%s\n' "$1" "$2" >> "$CHOWN_LOG"
    if [ -n "${STAT_OVERRIDE_AFTER_CHOWN:-}" ]; then
        printf '%s\t%s\n' "$2" "$STAT_OVERRIDE_AFTER_CHOWN" \
            >> "$STAT_OVERRIDE_FILE"
    fi
}

stat() {
    local value

    if [ "${1:-}" = -c ] && [ "${2:-}" = '%u:%g:%a' ] &&
        [ "${3:-}" = -- ] && [ -s "$STAT_OVERRIDE_FILE" ]; then
        value=$(awk -F '\t' -v path="${4:-}" \
            '$1 == path { value=$2 } END { if (value != "") print value }' \
            "$STAT_OVERRIDE_FILE")
        if [ -n "$value" ]; then
            printf '%s\n' "$value"
            return 0
        fi
    fi
    command stat "$@"
}

id() {
    if [ "${1:-}" = -u ] && [ "${2:-}" = fixture-user ]; then
        printf '12345\n'
        return 0
    fi
    command id "$@"
}

source "$ROOT_DIR/scripts/modules/desktop-niri/fedora-session-contract.sh"

mkdir -p "$HOME_DIR"
niri_safe_install_directory "$TARGET_USER" "$TARGET_GROUP" \
    "$HOME_DIR/Pictures/Wallpapers" ||
    fail 'a missing Pictures hierarchy must be created'
[ -d "$HOME_DIR/Pictures/Wallpapers" ] ||
    fail 'the complete requested directory hierarchy must exist'
[ "$(stat -c '%U:%G' "$HOME_DIR/Pictures")" = \
    "$TARGET_USER:$TARGET_GROUP" ] &&
    [ "$(stat -c '%U:%G' "$HOME_DIR/Pictures/Wallpapers")" = \
        "$TARGET_USER:$TARGET_GROUP" ] ||
    fail 'new home directories must have target-user filesystem ownership'
grep -Fqx "$TARGET_USER:$TARGET_GROUP"$'\t'"$HOME_DIR/Pictures" "$CHOWN_LOG" ||
    fail 'a newly created Pictures intermediate must belong to the target user'
grep -Fqx "$TARGET_USER:$TARGET_GROUP"$'\t'"$HOME_DIR/Pictures/Wallpapers" \
    "$CHOWN_LOG" ||
    fail 'a newly created destination must belong to the target user'

pictures_identity=$(stat -c '%d:%i:%a' "$HOME_DIR/Pictures")
wallpapers_identity=$(stat -c '%d:%i:%a' "$HOME_DIR/Pictures/Wallpapers")
: > "$CHOWN_LOG"
niri_safe_install_directory "$TARGET_USER" "$TARGET_GROUP" \
    "$HOME_DIR/Pictures/Wallpapers" ||
    fail 'an idempotent directory convergence must succeed'
[ "$(stat -c '%d:%i:%a' "$HOME_DIR/Pictures")" = "$pictures_identity" ] &&
    [ "$(stat -c '%d:%i:%a' "$HOME_DIR/Pictures/Wallpapers")" = \
        "$wallpapers_identity" ] ||
    fail 'an idempotent run must preserve the existing hierarchy'
if grep -Fqx "$TARGET_USER:$TARGET_GROUP"$'\t'"$HOME_DIR/Pictures" \
    "$CHOWN_LOG"; then
    fail 'an idempotent run must not claim an existing intermediate directory'
fi
[ ! -s "$CHOWN_LOG" ] ||
    fail 'an idempotent run must not reassign the existing destination'

existing_home=$TEST_DIR/existing-home
export HOME_DIR=$existing_home
mkdir -p "$HOME_DIR/Pictures"
chmod 711 "$HOME_DIR/Pictures"
printf 'preserve\n' > "$HOME_DIR/Pictures/user-marker"
existing_identity=$(stat -c '%d:%i:%a' "$HOME_DIR/Pictures")
: > "$CHOWN_LOG"
niri_safe_install_directory "$TARGET_USER" "$TARGET_GROUP" \
    "$HOME_DIR/Pictures/Wallpapers" ||
    fail 'a hierarchy below an existing user directory must converge'
[ "$(stat -c '%d:%i:%a' "$HOME_DIR/Pictures")" = "$existing_identity" ] &&
    grep -Fqx preserve "$HOME_DIR/Pictures/user-marker" ||
    fail 'an existing user directory must retain its identity, mode, and content'
if grep -Fqx "$TARGET_USER:$TARGET_GROUP"$'\t'"$HOME_DIR/Pictures" \
    "$CHOWN_LOG"; then
    fail 'an existing user directory must not be reassigned'
fi

legacy_home=$TEST_DIR/legacy-home
export HOME_DIR=$legacy_home
mkdir -p "$HOME_DIR/Pictures/Wallpapers"
STAT_OVERRIDE_AFTER_CHOWN=12345:12345:755
printf '%s\t%s\n' \
    "$HOME_DIR/Pictures" 0:0:755 \
    "$HOME_DIR/Pictures/Wallpapers" 12345:12345:755 \
    > "$STAT_OVERRIDE_FILE"
: > "$CHOWN_LOG"
niri_safe_install_directory fixture-user fixture-group \
    "$HOME_DIR/Pictures/Wallpapers" ||
    fail 'the exact legacy root-owned Pictures directory must migrate'
grep -Fqx 'fixture-user:fixture-group'$'\t'"$HOME_DIR/Pictures" \
    "$CHOWN_LOG" ||
    fail 'legacy root:root 0755 Pictures must be reassigned to the target user'
[ "$(wc -l < "$CHOWN_LOG")" -eq 1 ] ||
    fail 'legacy migration must not reassign the existing target-user destination'

: > "$CHOWN_LOG"
niri_safe_install_directory fixture-user fixture-group \
    "$HOME_DIR/Pictures/Wallpapers" ||
    fail 'the migrated legacy hierarchy must be idempotent'
[ ! -s "$CHOWN_LOG" ] ||
    fail 'an idempotent legacy migration must not repeat ownership changes'

foreign_home=$TEST_DIR/foreign-home
export HOME_DIR=$foreign_home
mkdir -p "$HOME_DIR/Pictures"
unset STAT_OVERRIDE_AFTER_CHOWN
printf '%s\t%s\n' "$HOME_DIR/Pictures" 4242:4242:755 \
    > "$STAT_OVERRIDE_FILE"
: > "$CHOWN_LOG"
if niri_safe_install_directory fixture-user fixture-group \
    "$HOME_DIR/Pictures/Wallpapers"; then
    fail 'a foreign-owned intermediate directory must be rejected'
fi
[ "$NIRI_PATH_SAFETY_REASON" = \
    "foreign-owner:$HOME_DIR/Pictures:4242:4242" ] ||
    fail 'foreign ownership rejection must expose the exact directory metadata'
[ ! -e "$HOME_DIR/Pictures/Wallpapers" ] && [ ! -s "$CHOWN_LOG" ] ||
    fail 'foreign ownership rejection must not create or reassign anything'

special_home=$TEST_DIR/special-home
export HOME_DIR=$special_home
mkdir -p "$HOME_DIR/Pictures"
printf '%s\t%s\n' "$HOME_DIR/Pictures" 0:0:700 > "$STAT_OVERRIDE_FILE"
: > "$CHOWN_LOG"
if niri_safe_install_directory fixture-user fixture-group \
    "$HOME_DIR/Pictures/Wallpapers"; then
    fail 'a root-owned intermediate directory with a special mode must be rejected'
fi
[ "$NIRI_PATH_SAFETY_REASON" = "unsafe-mode:$HOME_DIR/Pictures:700" ] ||
    fail 'special-mode rejection must expose the exact directory metadata'
[ ! -e "$HOME_DIR/Pictures/Wallpapers" ] && [ ! -s "$CHOWN_LOG" ] ||
    fail 'special-mode rejection must not create or reassign anything'

symlink_home=$TEST_DIR/symlink-home
outside=$TEST_DIR/outside
export HOME_DIR=$symlink_home
unset STAT_OVERRIDE_AFTER_CHOWN
: > "$STAT_OVERRIDE_FILE"
mkdir -p "$HOME_DIR" "$outside"
ln -s "$outside" "$HOME_DIR/Pictures"
: > "$CHOWN_LOG"
if niri_safe_install_directory "$TARGET_USER" "$TARGET_GROUP" \
    "$HOME_DIR/Pictures/Wallpapers"; then
    fail 'a symlink in the requested hierarchy must be rejected'
fi
[ "$NIRI_PATH_SAFETY_REASON" = "symlink:$HOME_DIR/Pictures" ] ||
    fail 'symlink rejection must expose the exact unsafe path'
[ -z "$(find "$outside" -mindepth 1 -print -quit)" ] ||
    fail 'symlink rejection must not write through the link target'
[ ! -s "$CHOWN_LOG" ] ||
    fail 'symlink rejection must not change ownership'

printf 'PASS: Niri safe directory creation preserves ownership boundaries\n'
