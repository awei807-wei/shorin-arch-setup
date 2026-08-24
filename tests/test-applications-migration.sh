#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SHORIN_DISTRO=arch
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
source "$ROOT_DIR/scripts/checks/preflight.sh"

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
[ -s "$APPLICATION_MANIFEST.meta" ] ||
    fail 'legacy migration must emit schema=2 metadata'
grep -Fqx 'schema=2' "$APPLICATION_MANIFEST.meta" ||
    fail 'legacy migration metadata must declare schema=2'
grep -Fqx 'mode=migrated' "$APPLICATION_MANIFEST.meta" ||
    fail 'legacy migration metadata must declare migrated mode'
grep -Eq '^manifest_hash=' "$APPLICATION_MANIFEST.meta" ||
    fail 'legacy migration metadata must record manifest hash'

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

MARKED_SOURCE="$TEST_DIR/marked-source.txt"
MARKED_MANIFEST="$TEST_DIR/marked-profile/applications.list"
cat > "$MARKED_SOURCE" <<'EOF'
neovim
wine
flatpak:it.mijorus.gearlever
GitHub:niri-clip
EOF
mkdir -p "$(dirname "$MARKED_MANIFEST")"
cat > "$MARKED_MANIFEST" <<'EOF'
# Migrated from legacy installed state.
custom-user-target
neovim
EOF
migrate_marked_legacy_application_manifest "$MARKED_SOURCE" "$MARKED_MANIFEST"
grep -Fqx custom-user-target "$MARKED_MANIFEST" ||
    fail 'marked legacy migration must preserve custom entries'
grep -Fqx wine "$MARKED_MANIFEST" ||
    fail 'marked legacy migration must append source entries in order'
grep -Fqx 'flatpak:it.mijorus.gearlever' "$MARKED_MANIFEST" ||
    fail 'marked legacy migration must append missing Flatpak entries'
grep -Fqx 'GitHub:niri-clip' "$MARKED_MANIFEST" ||
    fail 'marked legacy migration must append missing GitHub entries'
MARKED_BACKUP=$(find "$(dirname "$MARKED_MANIFEST")" -maxdepth 1 -type f \
    -name "$(basename "$MARKED_MANIFEST").bak.*" -print -quit)
[ -n "$MARKED_BACKUP" ] && [ -s "$MARKED_BACKUP" ] ||
    fail 'marked legacy migration must create a unique backup before switching'
cp "$MARKED_MANIFEST" "$TEST_DIR/marked-first"
migrate_marked_legacy_application_manifest "$MARKED_SOURCE" "$MARKED_MANIFEST" &&
    fail 'metadata-bearing marked manifest must not be re-adopted'
cmp -s "$TEST_DIR/marked-first" "$MARKED_MANIFEST" ||
    fail 'repeated marked migration must remain content-idempotent'
printf '%s\n' 'custom-edit' >> "$MARKED_MANIFEST"
MARKED_STATUS=0
application_manifest_metadata_status check "$MARKED_MANIFEST" || MARKED_STATUS=$?
[ "$MARKED_STATUS" -eq 10 ] ||
    fail 'modified manifest must report hash drift/adopt-required'

ROLLBACK_SOURCE="$TEST_DIR/rollback-source.txt"
ROLLBACK_MANIFEST="$TEST_DIR/rollback-profile/applications.list"
mkdir -p "$(dirname "$ROLLBACK_MANIFEST")"
printf 'neovim\nwine\n' > "$ROLLBACK_SOURCE"
cat > "$ROLLBACK_MANIFEST" <<'EOF'
# Migrated from legacy installed state.
custom-before-rollback
neovim
EOF
printf 'stale-backup-content\n' > "$ROLLBACK_MANIFEST.bak"
ROLLBACK_ORIGINAL="$TEST_DIR/rollback-original"
cp "$ROLLBACK_MANIFEST" "$ROLLBACK_ORIGINAL"
write_application_manifest_metadata() { return 1; }
ROLLBACK_STATUS=0
migrate_marked_legacy_application_manifest "$ROLLBACK_SOURCE" \
    "$ROLLBACK_MANIFEST" 2>/dev/null || ROLLBACK_STATUS=$?
unset -f write_application_manifest_metadata
source "$ROOT_DIR/scripts/modules/applications/manifest.sh"
[ "$ROLLBACK_STATUS" -eq 1 ] ||
    fail 'metadata failure must fail the marked manifest migration'
cmp -s "$ROLLBACK_ORIGINAL" "$ROLLBACK_MANIFEST" ||
    fail 'metadata failure must restore the current manifest, not a stale backup'
grep -Fqx 'stale-backup-content' "$ROLLBACK_MANIFEST.bak" ||
    fail 'migration must not overwrite a stale legacy backup path'
ROLLBACK_BACKUP=$(find "$(dirname "$ROLLBACK_MANIFEST")" -maxdepth 1 -type f \
    -name "$(basename "$ROLLBACK_MANIFEST").bak.*" -print -quit)
[ -n "$ROLLBACK_BACKUP" ] ||
    fail 'metadata failure must leave a unique transaction backup for audit'

UNMARKED_SOURCE="$TEST_DIR/unmarked-source.txt"
UNMARKED_MANIFEST="$TEST_DIR/unmarked-profile/applications.list"
cat > "$UNMARKED_SOURCE" <<'EOF'
# source comment must not enter the manifest
neovim
wine # append this target after existing entries
flatpak:it.mijorus.gearlever
EOF
mkdir -p "$(dirname "$UNMARKED_MANIFEST")"
cat > "$UNMARKED_MANIFEST" <<'EOF'
# user-owned heading
custom-user-target
neovim
# preserve this comment and order
EOF
UNMARKED_ORIGINAL="$TEST_DIR/unmarked-original"
cp "$UNMARKED_MANIFEST" "$UNMARKED_ORIGINAL"
UNMARKED_STATUS=0
application_manifest_metadata_status check "$UNMARKED_MANIFEST" ||
    UNMARKED_STATUS=$?
[ "$UNMARKED_STATUS" -eq 12 ] ||
    fail 'an unmarked non-empty manifest must require explicit adoption'
unset SHORIN_ADOPT_LEGACY_APPLICATIONS
run_applications_phase "$UNMARKED_MANIFEST" check repair "$UNMARKED_SOURCE"
[ "$PHASE_STATUS" -eq 10 ] ||
    fail 'an unmarked manifest must report drift during repair check'
grep -Fq application-manifest-legacy-unmarked <<< "$PHASE_OUTPUT" ||
    fail 'unmarked manifest drift must include its precise reason'
grep -Fq 'sudo env SHORIN_ADOPT_LEGACY_APPLICATIONS=1 bash install.sh repair --distro fedora --user <user> base applications' <<< "$PHASE_OUTPUT" ||
    fail 'unmarked manifest drift must print the explicit adoption command'
cmp -s "$UNMARKED_ORIGINAL" "$UNMARKED_MANIFEST" ||
    fail 'repair check must not change an unmarked manifest'
[ ! -e "$UNMARKED_MANIFEST.meta" ] ||
    fail 'repair check must not create metadata for an unmarked manifest'
run_applications_phase "$UNMARKED_MANIFEST" verify repair "$UNMARKED_SOURCE"
[ "$PHASE_STATUS" -eq 1 ] ||
    fail 'verify must fail an unmarked manifest'
grep -Fq application-manifest-legacy-unmarked <<< "$PHASE_OUTPUT" ||
    fail 'verify must include the unmarked manifest reason'
run_applications_phase "$UNMARKED_MANIFEST" apply repair "$UNMARKED_SOURCE"
[ "$PHASE_STATUS" -eq 20 ] ||
    fail 'repair apply must skip an unmarked manifest without authorization'
cmp -s "$UNMARKED_ORIGINAL" "$UNMARKED_MANIFEST" ||
    fail 'repair apply must not change an unmarked manifest without authorization'
[ ! -e "$UNMARKED_MANIFEST.meta" ] ||
    fail 'repair apply must not create metadata without authorization'

export SHORIN_ADOPT_LEGACY_APPLICATIONS=1
migrate_unmarked_legacy_application_manifest "$UNMARKED_SOURCE" "$UNMARKED_MANIFEST"
cat > "$TEST_DIR/unmarked-expected" <<'EOF'
# user-owned heading
custom-user-target
neovim
# preserve this comment and order
wine
flatpak:it.mijorus.gearlever
EOF
cmp -s "$TEST_DIR/unmarked-expected" "$UNMARKED_MANIFEST" ||
    fail 'explicit adoption must append missing source entries without reordering user content'
grep -Fqx 'schema=2' "$UNMARKED_MANIFEST.meta" ||
    fail 'explicit adoption must write schema=2 metadata'
grep -Fqx 'mode=migrated' "$UNMARKED_MANIFEST.meta" ||
    fail 'explicit adoption must record migrated mode'
UNMARKED_FIRST="$TEST_DIR/unmarked-first"
cp "$UNMARKED_MANIFEST" "$UNMARKED_FIRST"
UNMARKED_REPEAT_STATUS=0
migrate_unmarked_legacy_application_manifest "$UNMARKED_SOURCE" "$UNMARKED_MANIFEST" ||
    UNMARKED_REPEAT_STATUS=$?
[ "$UNMARKED_REPEAT_STATUS" -eq "$RC_SKIPPED" ] ||
    fail 'second explicit adoption must be skipped after metadata is present'
cmp -s "$UNMARKED_FIRST" "$UNMARKED_MANIFEST" ||
    fail 'second explicit adoption must be content-idempotent'
UNMARKED_BACKUP=$(find "$(dirname "$UNMARKED_MANIFEST")" -maxdepth 1 -type f \
    -name "$(basename "$UNMARKED_MANIFEST").bak.*" -print -quit)
[ -n "$UNMARKED_BACKUP" ] && [ -s "$UNMARKED_BACKUP" ] ||
    fail 'explicit adoption must create a unique backup before switching'

UNMARKED_ROLLBACK_SOURCE="$TEST_DIR/unmarked-rollback-source.txt"
UNMARKED_ROLLBACK_MANIFEST="$TEST_DIR/unmarked-rollback-profile/applications.list"
mkdir -p "$(dirname "$UNMARKED_ROLLBACK_MANIFEST")"
printf 'neovim\nwine\n' > "$UNMARKED_ROLLBACK_SOURCE"
cat > "$UNMARKED_ROLLBACK_MANIFEST" <<'EOF'
# preserve this unmarked manifest
custom-before-rollback
neovim
EOF
UNMARKED_ROLLBACK_ORIGINAL="$TEST_DIR/unmarked-rollback-original"
cp "$UNMARKED_ROLLBACK_MANIFEST" "$UNMARKED_ROLLBACK_ORIGINAL"
write_application_manifest_metadata() { return 1; }
UNMARKED_ROLLBACK_STATUS=0
migrate_unmarked_legacy_application_manifest "$UNMARKED_ROLLBACK_SOURCE" \
    "$UNMARKED_ROLLBACK_MANIFEST" 2>/dev/null ||
    UNMARKED_ROLLBACK_STATUS=$?
unset -f write_application_manifest_metadata
[ "$UNMARKED_ROLLBACK_STATUS" -eq 1 ] ||
    fail 'unmarked adoption metadata failure must fail the migration'
cmp -s "$UNMARKED_ROLLBACK_ORIGINAL" "$UNMARKED_ROLLBACK_MANIFEST" ||
    fail 'unmarked adoption metadata failure must restore the original manifest'
[ ! -e "$UNMARKED_ROLLBACK_MANIFEST.meta" ] ||
    fail 'unmarked adoption rollback must remove partial metadata'
UNMARKED_ROLLBACK_BACKUP=$(find "$(dirname "$UNMARKED_ROLLBACK_MANIFEST")" -maxdepth 1 \
    -type f -name "$(basename "$UNMARKED_ROLLBACK_MANIFEST").bak.*" -print -quit)
[ -n "$UNMARKED_ROLLBACK_BACKUP" ] ||
    fail 'unmarked adoption rollback must preserve a unique transaction backup'
unset SHORIN_ADOPT_LEGACY_APPLICATIONS

# A fresh install must declare its non-interactive default selection before an
# upstream required module can fail and block Applications.  Repair can then
# resume the same selected target instead of inferring a smaller legacy set.
INTENT_SOURCE="$TEST_DIR/intent-source.txt"
INTENT_MANIFEST="$TEST_DIR/intent-profile/applications.list"
cat > "$INTENT_SOURCE" <<'EOF'
wine # default target
neovim
wine
flatpak:it.mijorus.gearlever
EOF
(
    APPLICATION_SOURCE_LIST="$INTENT_SOURCE"
    APPLICATION_MANIFEST="$INTENT_MANIFEST"
    export APPLICATION_SOURCE_LIST APPLICATION_MANIFEST
    prepare_install_application_manifest install storage base applications
)
cat > "$TEST_DIR/intent-expected" <<'EOF'
flatpak:it.mijorus.gearlever
neovim
wine
EOF
cmp -s "$TEST_DIR/intent-expected" "$INTENT_MANIFEST" ||
    fail 'fresh install intent must persist the normalized default selection'
grep -Fqx 'mode=selected' "$INTENT_MANIFEST.meta" ||
    fail 'fresh install intent must be authoritative selected metadata'

# A terminal-backed install still owns an explicit Y/n + fzf choice.  The
# preflight recovery declaration must not silently convert that future choice
# into a full selection when an earlier module fails.
TTY_INTENT_MANIFEST="$TEST_DIR/tty-intent-profile/applications.list"
if command -v script >/dev/null 2>&1; then
    script -q -e -c \
        "env SHORIN_ROOT='$ROOT_DIR' SHORIN_DISTRO=arch SHORIN_MODE=install SHORIN_READ_ONLY=0 APPLICATION_SOURCE_LIST='$INTENT_SOURCE' APPLICATION_MANIFEST='$TTY_INTENT_MANIFEST' bash -c 'source \"\$SHORIN_ROOT/scripts/modules/applications/targets.sh\"; source \"\$SHORIN_ROOT/scripts/checks/preflight.sh\"; prepare_install_application_manifest install base applications'" \
        /dev/null >/dev/null 2>&1 ||
        fail 'TTY application-intent fixture could not run'
    [ ! -e "$TTY_INTENT_MANIFEST" ] ||
        fail 'interactive install preflight must not preselect every application'
    grep -Fqx 'state=pending-selection' "$TTY_INTENT_MANIFEST.intent" ||
        fail 'interactive install preflight must persist pending selection state'
else
    write_application_selection_intent \
        "$INTENT_SOURCE" "$TTY_INTENT_MANIFEST" pending-selection
fi

PENDING_REPAIR_MANIFEST="$TEST_DIR/pending-repair/applications.list"
write_application_selection_intent \
    "$INTENT_SOURCE" "$PENDING_REPAIR_MANIFEST" pending-selection
run_applications_phase \
    "$PENDING_REPAIR_MANIFEST" check repair "$INTENT_SOURCE"
[ "$PHASE_STATUS" -eq 10 ] ||
    fail 'repair check must retain a pending interactive selection as drift'
grep -Fq application-selection-required <<< "$PHASE_OUTPUT" ||
    fail 'pending selection drift must be explicit'
run_applications_phase \
    "$PENDING_REPAIR_MANIFEST" apply repair "$INTENT_SOURCE"
[ "$PHASE_STATUS" -eq 20 ] ||
    fail 'non-interactive repair must not guess a pending application selection'
[ ! -e "$PENDING_REPAIR_MANIFEST" ] ||
    fail 'non-interactive repair must not create a manifest from installed state'

printf 'partially-written-target\n' > "$PENDING_REPAIR_MANIFEST"
run_applications_phase \
    "$PENDING_REPAIR_MANIFEST" check repair "$INTENT_SOURCE"
grep -Fq application-selection-required <<< "$PHASE_OUTPUT" ||
    fail 'pending intent must dominate an interrupted manifest transaction'

DECLINED_MANIFEST="$TEST_DIR/declined-profile/applications.list"
write_application_selection_intent \
    "$INTENT_SOURCE" "$DECLINED_MANIFEST" declined
run_applications_phase "$DECLINED_MANIFEST" check repair "$INTENT_SOURCE"
[ "$PHASE_STATUS" -eq 20 ] ||
    fail 'a declined application selection must remain an explicit skip'
grep -Fq application-selection-declined <<< "$PHASE_OUTPUT" ||
    fail 'declined application selection reason must be preserved'

INTERRUPTED_MANIFEST="$TEST_DIR/interrupted-profile/applications.list"
# Earlier rollback fixtures temporarily replace and unset the metadata writer;
# restore the real manifest transaction helpers for commit-recovery coverage.
source "$ROOT_DIR/scripts/modules/applications/manifest.sh"
write_application_selection_intent \
    "$INTENT_SOURCE" "$INTERRUPTED_MANIFEST" selected-all
printf 'partially-committed-target\n' > "$INTERRUPTED_MANIFEST"
initialize_default_application_manifest \
    "$INTENT_SOURCE" "$INTERRUPTED_MANIFEST"
cmp -s "$TEST_DIR/intent-expected" "$INTERRUPTED_MANIFEST" ||
    fail 'selected-all intent must recover an interrupted manifest commit'
grep -Fqx 'mode=selected' "$INTERRUPTED_MANIFEST.meta" ||
    fail 'interrupted default selection recovery must commit metadata'
[ ! -e "$INTERRUPTED_MANIFEST.intent" ] ||
    fail 'completed default selection commit must clear its intent'

write_application_selection_intent \
    "$INTENT_SOURCE" "$INTERRUPTED_MANIFEST" selected-all
run_applications_phase \
    "$INTERRUPTED_MANIFEST" check repair "$INTENT_SOURCE"
[ "$PHASE_STATUS" -eq 10 ] ||
    fail 'a stale selected-all commit intent must trigger cleanup'
run_applications_phase \
    "$INTERRUPTED_MANIFEST" apply repair "$INTENT_SOURCE"
[ "$PHASE_STATUS" -eq 0 ] ||
    fail 'repair must clear a stale completed selected-all intent'
[ ! -e "$INTERRUPTED_MANIFEST.intent" ] ||
    fail 'repair did not clear the stale selected-all commit intent'

printf 'existing-user-selection\n' > "$INTENT_MANIFEST"
INTENT_BEFORE="$TEST_DIR/intent-before"
cp "$INTENT_MANIFEST" "$INTENT_BEFORE"
(
    APPLICATION_SOURCE_LIST="$INTENT_SOURCE"
    APPLICATION_MANIFEST="$INTENT_MANIFEST"
    export APPLICATION_SOURCE_LIST APPLICATION_MANIFEST
    prepare_install_application_manifest install base applications
)
cmp -s "$INTENT_BEFORE" "$INTENT_MANIFEST" ||
    fail 'early install intent must not replace a pre-existing selection'

NO_APPS_INTENT="$TEST_DIR/no-apps-profile/applications.list"
(
    APPLICATION_SOURCE_LIST="$INTENT_SOURCE"
    APPLICATION_MANIFEST="$NO_APPS_INTENT"
    export APPLICATION_SOURCE_LIST APPLICATION_MANIFEST
    prepare_install_application_manifest install storage base
)
[ ! -e "$NO_APPS_INTENT" ] ||
    fail 'an install without Applications selected must not create app intent'
REPAIR_INTENT="$TEST_DIR/repair-intent-profile/applications.list"
(
    APPLICATION_SOURCE_LIST="$INTENT_SOURCE"
    APPLICATION_MANIFEST="$REPAIR_INTENT"
    export APPLICATION_SOURCE_LIST APPLICATION_MANIFEST
    prepare_install_application_manifest repair base applications
)
[ ! -e "$REPAIR_INTENT" ] ||
    fail 'repair must not invent a fresh-install application selection'

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
