#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SHORIN_DISTRO=arch
TEST_DIR=$(mktemp -d)
HOME_DIR="$TEST_DIR/home"
TARGET_USER=$(id -un)
SHORIN_ROOT="$ROOT_DIR"
SHORIN_READ_ONLY=0
VICINAE_SETTINGS_FILE="$HOME_DIR/.config/vicinae/settings.json"
export HOME_DIR TARGET_USER SHORIN_ROOT SHORIN_READ_ONLY VICINAE_SETTINGS_FILE

cleanup() {
    find "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

state_package_present() {
    case "$1" in
        vicinae|vicinae-bin) return 0 ;;
        *) return 1 ;;
    esac
}

source "$ROOT_DIR/scripts/modules/applications/targets.sh"
source "$ROOT_DIR/scripts/modules/applications/config-apply.sh"

declared_package_target_satisfied() {
    state_package_present "${1#AUR:}"
}

SIMULATE_DIRECTORY_OWNER_DRIFT=0
SIMULATE_SETTINGS_OWNER_DRIFT=0

vicinae_path_owned_by_target() {
    local path=$1 target_group

    if [ "$path" = "$(dirname "$VICINAE_SETTINGS_FILE")" ] &&
        [ "$SIMULATE_DIRECTORY_OWNER_DRIFT" -eq 1 ]; then
        return 1
    fi
    if [ "$path" = "$VICINAE_SETTINGS_FILE" ] &&
        [ "$SIMULATE_SETTINGS_OWNER_DRIFT" -eq 1 ]; then
        return 1
    fi
    target_group=$(id -gn "$TARGET_USER")
    [ "$(stat -c '%U:%G' "$path" 2>/dev/null)" = \
        "$TARGET_USER:$target_group" ]
}

chown() {
    local path=${!#}

    if [ "$path" = "$(dirname "$VICINAE_SETTINGS_FILE")" ]; then
        SIMULATE_DIRECTORY_OWNER_DRIFT=0
    fi
    if [ "$path" = "$VICINAE_SETTINGS_FILE" ]; then
        SIMULATE_SETTINGS_OWNER_DRIFT=0
    fi
    command chown "$@"
}

RUNTIME_ROOT="$HOME_DIR/.local/share/vicinae"
CACHE_ROOT="$HOME_DIR/.cache/vicinae"
mkdir -p "$RUNTIME_ROOT/extensions" "$CACHE_ROOT"
printf 'extension-state\n' > "$RUNTIME_ROOT/extensions/keep.db"
printf 'cache-state\n' > "$CACHE_ROOT/keep.cache"

application_entry_satisfied AUR:vicinae-bin &&
    fail 'missing Vicinae settings must be configuration drift'
ensure_application_entry_config AUR:vicinae-bin
application_entry_satisfied AUR:vicinae-bin ||
    fail 'the rendered Vicinae template must satisfy the target'
grep -Fq "$HOME_DIR/.local/share/applications" "$VICINAE_SETTINGS_FILE" ||
    fail 'the Vicinae template must render the target home path'
[ "$(stat -c '%a' "$VICINAE_SETTINGS_FILE")" = 600 ] ||
    fail 'new Vicinae settings must be private to the target user'
[ "$(stat -c '%U:%G' "$(dirname "$VICINAE_SETTINGS_FILE")")" = \
    "$TARGET_USER:$(id -gn "$TARGET_USER")" ] ||
    fail 'the Vicinae configuration directory must belong to the target user'
[ "$(stat -c '%U:%G' "$VICINAE_SETTINGS_FILE")" = \
    "$TARGET_USER:$(id -gn "$TARGET_USER")" ] ||
    fail 'the managed Vicinae template must belong to the target user'
[ ! -e "$VICINAE_SETTINGS_FILE.new" ] ||
    fail 'atomic deployment must not leave a staged settings file'
grep -Fqx extension-state "$RUNTIME_ROOT/extensions/keep.db" ||
    fail 'Vicinae extension data must be preserved'
grep -Fqx cache-state "$CACHE_ROOT/keep.cache" ||
    fail 'Vicinae cache data must be preserved'

FIRST_COPY="$TEST_DIR/first-settings.json"
cp "$VICINAE_SETTINGS_FILE" "$FIRST_COPY"
ensure_application_entry_config AUR:vicinae-bin
cmp -s "$FIRST_COPY" "$VICINAE_SETTINGS_FILE" ||
    fail 'repeated template deployment must be content-idempotent'
chmod 644 "$VICINAE_SETTINGS_FILE"
application_entry_satisfied AUR:vicinae-bin &&
    fail 'a managed Vicinae template with public permissions must be drift'
ensure_application_entry_config AUR:vicinae-bin
[ "$(stat -c '%a' "$VICINAE_SETTINGS_FILE")" = 600 ] ||
    fail 'Vicinae convergence must repair managed template permissions'

printf '{"close_on_focus_loss":false,"custom_user_setting":"keep"}\n' > \
    "$VICINAE_SETTINGS_FILE"
chmod 640 "$VICINAE_SETTINGS_FILE"
USER_COPY="$TEST_DIR/user-settings.json"
cp "$VICINAE_SETTINGS_FILE" "$USER_COPY"
application_entry_satisfied AUR:vicinae-bin ||
    fail 'an edited Vicinae file must be accepted as user-managed state'

chmod 000 "$VICINAE_SETTINGS_FILE"
application_entry_satisfied AUR:vicinae-bin &&
    fail 'target-user unreadability must be drift even when root could read'
SIMULATE_DIRECTORY_OWNER_DRIFT=1
SIMULATE_SETTINGS_OWNER_DRIFT=1
application_entry_satisfied AUR:vicinae-bin &&
    fail 'wrong directory or settings ownership must be drift'
ensure_application_entry_config AUR:vicinae-bin
cmp -s "$USER_COPY" "$VICINAE_SETTINGS_FILE" ||
    fail 'an edited Vicinae file must not be overwritten'
[ "$(stat -c '%a' "$VICINAE_SETTINGS_FILE")" = 400 ] ||
    fail 'custom settings repair must add only the target-user read bit'
[ "$(stat -c '%U:%G' "$VICINAE_SETTINGS_FILE")" = \
    "$TARGET_USER:$(id -gn "$TARGET_USER")" ] ||
    fail 'custom settings ownership must converge to the target user'
vicinae_settings_target_readable "$VICINAE_SETTINGS_FILE" ||
    fail 'custom settings must be readable as the target user after repair'
[ "$(stat -c '%U:%G' "$(dirname "$VICINAE_SETTINGS_FILE")")" = \
    "$TARGET_USER:$(id -gn "$TARGET_USER")" ] ||
    fail 'legacy configuration directory ownership must converge'

chmod 600 "$VICINAE_SETTINGS_FILE"
printf '// Unconfigured legacy file\n{\n  "$schema": "https://vicinae.com/schemas/config.json",\n  "imports": []\n}\n' > \
    "$VICINAE_SETTINGS_FILE"
application_entry_satisfied AUR:vicinae-bin &&
    fail 'a known legacy Vicinae shell must be migration drift'
ensure_application_entry_config AUR:vicinae-bin
application_entry_satisfied AUR:vicinae-bin ||
    fail 'a known legacy Vicinae shell must migrate to the trusted template'
[ "$(stat -c '%a' "$VICINAE_SETTINGS_FILE")" = 600 ] ||
    fail 'migrated Vicinae settings must be private to the target user'

DANGLING_TARGET="$TEST_DIR/user-managed/missing-settings.json"
rm -f "$VICINAE_SETTINGS_FILE"
ln -s "$DANGLING_TARGET" "$VICINAE_SETTINGS_FILE"
chmod 000 "$(dirname "$VICINAE_SETTINGS_FILE")"
SIMULATE_DIRECTORY_OWNER_DRIFT=1
application_entry_satisfied AUR:vicinae-bin &&
    fail 'a protected symlink with an inaccessible parent directory must be drift'
ensure_application_entry_config AUR:vicinae-bin
[ "$(stat -c '%U:%G' "$(dirname "$VICINAE_SETTINGS_FILE")")" = \
    "$TARGET_USER:$(id -gn "$TARGET_USER")" ] ||
    fail 'a dangling settings symlink parent must converge to the target user'
DIRECTORY_ACCESS=$(stat -c '%A' "$(dirname "$VICINAE_SETTINGS_FILE")")
[ "${DIRECTORY_ACCESS:1:3}" = rwx ] ||
    fail 'a dangling settings symlink parent must become writable and traversable'
application_entry_satisfied AUR:vicinae-bin ||
    fail 'a dangling Vicinae settings symlink with a valid parent must be user-managed state'
[ -L "$VICINAE_SETTINGS_FILE" ] ||
    fail 'Vicinae convergence must not replace a dangling settings symlink'
[ "$(readlink "$VICINAE_SETTINGS_FILE")" = "$DANGLING_TARGET" ] ||
    fail 'Vicinae convergence must preserve the dangling symlink target'
[ ! -e "$DANGLING_TARGET" ] ||
    fail 'Vicinae convergence must not populate a user-managed symlink target'
[ ! -e "$VICINAE_SETTINGS_FILE.new" ] ||
    fail 'Vicinae convergence must not stage a replacement for a settings symlink'

find "$HOME_DIR" -type f -not -path "$VICINAE_SETTINGS_FILE" \
    -not -path "$RUNTIME_ROOT/extensions/keep.db" \
    -not -path "$CACHE_ROOT/keep.cache" -print -quit | grep -q . &&
    fail 'Vicinae deployment must not create history or unrelated runtime data'

printf 'PASS: Vicinae settings convergence\n'
