#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
HOME_DIR="$TEST_DIR/home"
TARGET_USER=tester
SHORIN_MODE=repair
SHORIN_READ_ONLY=0
export HOME_DIR TARGET_USER SHORIN_MODE SHORIN_READ_ONLY

cleanup() {
    find "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

assert_contains() {
    local file=$1 expected=$2
    grep -Fqx "$expected" "$file" || fail "$file does not contain $expected"
}

assert_not_contains() {
    local file=$1 unexpected=$2
    ! grep -Fqx "$unexpected" "$file" || fail "$file unexpectedly contains $unexpected"
}

run_applications_phase() {
    local manifest=$1 phase=$2 mode=${3:-repair}
    local source_list=${4:-$SOURCE_LIST} status=0

    PHASE_OUTPUT=$(env APPLICATION_MANIFEST="$manifest" \
        APPLICATION_SOURCE_LIST="$source_list" \
        SHORIN_MODE="$mode" TARGET_USER="$TARGET_USER" HOME_DIR="$HOME_DIR" \
        SHORIN_ROOT="$ROOT_DIR" \
        bash "$ROOT_DIR/scripts/modules/applications.sh" "$phase" 2>&1) ||
        status=$?
    PHASE_STATUS=$status
}

source "$ROOT_DIR/scripts/modules/applications/targets.sh"

CUSTOM_PATH="$TEST_DIR/custom-profile/custom-applications.list"
RESOLVED_PATH=$(env APPLICATION_MANIFEST="$CUSTOM_PATH" SHORIN_ROOT="$ROOT_DIR" \
    bash -c 'source "$SHORIN_ROOT/scripts/modules/applications/targets.sh"; printf "%s\n" "$APPLICATION_MANIFEST"')
[ "$RESOLVED_PATH" = "$CUSTOM_PATH" ] ||
    fail 'the shared target loader must preserve a custom manifest path'

state_package_present() {
    case "$1" in
        neovim|vicinae-bin) return 0 ;;
        *) return 1 ;;
    esac
}

state_flatpak_present() {
    [ "$1" = it.mijorus.gearlever ]
}

state_user_unit_enabled() {
    return 1
}

SOURCE_LIST="$TEST_DIR/common-applist.txt"
APPLICATION_MANIFEST="$TEST_DIR/profile/applications.list"
export APPLICATION_MANIFEST

mkdir -p "$HOME_DIR/.local/src/focus-shift/.git"
mkdir -p "$HOME_DIR/.config/nvim/lua/config"
printf 'return {}\n' > "$HOME_DIR/.config/nvim/lua/config/lazy.lua"
cat > "$SOURCE_LIST" <<'EOF'
neovim # repository package
wine
AUR:vicinae-bin
flatpak:it.mijorus.gearlever
flatpak:com.example.Missing
GitHub:focus-shift
GitHub:niri-clip
lazyvim
EOF

migrate_legacy_application_manifest "$SOURCE_LIST" "$APPLICATION_MANIFEST"

assert_contains "$APPLICATION_MANIFEST" neovim
assert_contains "$APPLICATION_MANIFEST" AUR:vicinae-bin
assert_contains "$APPLICATION_MANIFEST" flatpak:it.mijorus.gearlever
assert_contains "$APPLICATION_MANIFEST" GitHub:focus-shift
assert_contains "$APPLICATION_MANIFEST" lazyvim
assert_not_contains "$APPLICATION_MANIFEST" wine
assert_not_contains "$APPLICATION_MANIFEST" flatpak:com.example.Missing
assert_not_contains "$APPLICATION_MANIFEST" GitHub:niri-clip

EMPTY_SOURCE="$TEST_DIR/empty-source.txt"
EMPTY_MANIFEST="$TEST_DIR/empty-profile/applications.list"
printf 'wine\n' > "$EMPTY_SOURCE"
EMPTY_STATUS=0
migrate_legacy_application_manifest "$EMPTY_SOURCE" "$EMPTY_MANIFEST" \
    2>/dev/null || EMPTY_STATUS=$?
[ "$EMPTY_STATUS" -eq 20 ] ||
    fail 'migration without detected targets must report a skip'
[ ! -e "$EMPTY_MANIFEST" ] ||
    fail 'migration must never declare an empty application manifest'

FIRST_COPY="$TEST_DIR/first-applications.list"
cp "$APPLICATION_MANIFEST" "$FIRST_COPY"
migrate_legacy_application_manifest "$SOURCE_LIST" "$APPLICATION_MANIFEST"
cmp -s "$FIRST_COPY" "$APPLICATION_MANIFEST" ||
    fail 'repeated migration must be content-idempotent'

READ_ONLY_TARGET="$TEST_DIR/read-only/applications.list"
if (SHORIN_READ_ONLY=1; migrate_legacy_application_manifest \
    "$SOURCE_LIST" "$READ_ONLY_TARGET") >/dev/null 2>&1; then
    fail 'read-only mode must reject manifest migration'
fi
[ ! -e "$READ_ONLY_TARGET" ] ||
    fail 'read-only migration must not create a manifest'

MISSING_MANIFEST="$TEST_DIR/missing-profile/applications.list"
run_applications_phase "$MISSING_MANIFEST" check repair
[ "$PHASE_STATUS" -eq 10 ] ||
    fail 'repair check must report a missing legacy manifest as drift'
grep -Fq legacy-application-manifest <<< "$PHASE_OUTPUT" ||
    fail 'repair check must identify the legacy migration reason'
[ ! -e "$MISSING_MANIFEST" ] ||
    fail 'repair check must remain read-only'

run_applications_phase "$MISSING_MANIFEST" verify repair
[ "$PHASE_STATUS" -eq 20 ] ||
    fail 'verify must skip an undeclared legacy application target'
[ ! -e "$MISSING_MANIFEST" ] ||
    fail 'verify must not create a migration manifest'

AUDIT_MANIFEST="$TEST_DIR/audit-profile/applications.list"
run_applications_phase "$AUDIT_MANIFEST" check audit
[ "$PHASE_STATUS" -eq 10 ] ||
    fail 'audit must report a missing legacy manifest as drift'
[ ! -e "$AUDIT_MANIFEST" ] ||
    fail 'audit must not create a migration manifest'

CHAIN_SOURCE="$TEST_DIR/chain-source.txt"
CHAIN_MANIFEST="$TEST_DIR/chain-profile/applications.list"
printf 'shorin-legacy-fixture-not-installed\n' > "$CHAIN_SOURCE"
run_applications_phase "$CHAIN_MANIFEST" check repair "$CHAIN_SOURCE"
[ "$PHASE_STATUS" -eq 10 ] || fail 'legacy chain check must report drift'
run_applications_phase "$CHAIN_MANIFEST" apply repair "$CHAIN_SOURCE"
[ "$PHASE_STATUS" -eq 20 ] ||
    fail 'legacy chain apply must skip when no targets are detected'
[ ! -e "$CHAIN_MANIFEST" ] ||
    fail 'legacy chain apply must not declare an empty manifest'
grep -Fq application-targets-undetected <<< "$PHASE_OUTPUT" ||
    fail 'legacy chain apply must report the undetected-target reason'
run_applications_phase "$CHAIN_MANIFEST" verify repair "$CHAIN_SOURCE"
[ "$PHASE_STATUS" -eq 20 ] ||
    fail 'legacy chain verify must skip an undeclared target'

PREEXISTING_EMPTY_MANIFEST="$TEST_DIR/preexisting-empty/applications.list"
mkdir -p "$(dirname "$PREEXISTING_EMPTY_MANIFEST")"
printf '# empty by an older migration\n' > "$PREEXISTING_EMPTY_MANIFEST"
run_applications_phase "$PREEXISTING_EMPTY_MANIFEST" apply repair
[ "$PHASE_STATUS" -eq 20 ] ||
    fail 'repair apply must skip a pre-existing empty manifest'
grep -Fq application-targets-empty <<< "$PHASE_OUTPUT" ||
    fail 'a pre-existing empty manifest must report a precise reason'

INVALID_MANIFEST="$TEST_DIR/invalid-applications.list"
printf 'AUR:\n' > "$INVALID_MANIFEST"
run_applications_phase "$INVALID_MANIFEST" check repair
[ "$PHASE_STATUS" -eq 1 ] ||
    fail 'invalid manifest entries must fail inspection'
grep -Fq application-manifest-invalid <<< "$PHASE_OUTPUT" ||
    fail 'invalid manifest entries must include a precise reason'

DIRECTORY_MANIFEST="$TEST_DIR/manifest-directory"
mkdir -p "$DIRECTORY_MANIFEST"
run_applications_phase "$DIRECTORY_MANIFEST" check repair
[ "$PHASE_STATUS" -eq 1 ] ||
    fail 'a non-file manifest must fail inspection'
grep -Fq application-manifest-unreadable <<< "$PHASE_OUTPUT" ||
    fail 'an unreadable manifest must include a precise reason'

printf 'PASS: legacy applications manifest migration\n'
