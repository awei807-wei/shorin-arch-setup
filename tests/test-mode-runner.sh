#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CORE_LIB="$ROOT_DIR/scripts/lib/core.sh"
ENTRYPOINT="$ROOT_DIR/install.sh"
TEST_DIR=$(mktemp -d)
FIXTURE_DIR="$TEST_DIR/modules"
FIXTURE_LOG="$TEST_DIR/calls.log"
FIXTURE_STATE_DIR="$TEST_DIR/state"

cleanup() {
    find "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

assert_equal() {
    local expected=$1 actual=$2 message=$3
    [ "$expected" = "$actual" ] ||
        fail "$message (expected=$expected actual=$actual)"
}

assert_array_contains() {
    local array_name=$1 expected=$2 item
    local -n values=$array_name

    for item in "${values[@]}"; do
        [ "$item" != "$expected" ] || return 0
    done
    fail "$array_name does not contain $expected"
}

call_count() {
    local event=$1
    grep -Fxc "$event" "$FIXTURE_LOG" 2>/dev/null || true
}

create_fixture_module() {
    local module=$1 behavior=$2
    local prefix=${module//-/_}
    local path="$FIXTURE_DIR/$module.sh"

    cat > "$path" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

source "\$SHORIN_ROOT/scripts/lib/core.sh"

${prefix}_record() {
    printf '%s:%s\n' '$module' "\$1" >> "\$FIXTURE_LOG"
}

${prefix}_check() {
    ${prefix}_record check
    case '$behavior' in
        skip) module_skip 'fixture-not-applicable' ;;
        fail) module_inspection_failed 'fixture-inspection-failed' ;;
        *)
            if [ ! -f "\$FIXTURE_STATE_DIR/$module" ] ||
                [ "\$(< "\$FIXTURE_STATE_DIR/$module")" != desired ]; then
                module_drift 'fixture-state'
            fi
            ;;
    esac
}

${prefix}_apply() {
    ${prefix}_record apply
    require_writable_mode
    case '$behavior' in
        apply-skip) module_skip 'fixture-apply-skipped'; return 0 ;;
        apply-fail-converged)
            printf 'desired\n' > "\$FIXTURE_STATE_DIR/$module"
            return 1
            ;;
        apply-fail) return 1 ;;
    esac
    printf 'desired\n' > "\$FIXTURE_STATE_DIR/$module"
}

${prefix}_verify() {
    ${prefix}_record verify
    if [ '$behavior' = verify-fail ]; then
        module_verify_failed 'fixture-verification-failed'
    elif [ ! -f "\$FIXTURE_STATE_DIR/$module" ] ||
        [ "\$(< "\$FIXTURE_STATE_DIR/$module")" != desired ]; then
        module_verify_failed 'fixture-state'
    fi
}

module_main '$module' "\$@"
EOF
    chmod 755 "$path"
}

mkdir -p "$FIXTURE_DIR" "$FIXTURE_STATE_DIR"
: > "$FIXTURE_LOG"

source "$CORE_LIB"
source "$ROOT_DIR/scripts/lib/files.sh"
source "$ROOT_DIR/scripts/lib/packages.sh"
source "$ROOT_DIR/scripts/lib/systemd.sh"

MODULES_PATH=$FIXTURE_DIR
export MODULES_PATH FIXTURE_LOG FIXTURE_STATE_DIR

create_fixture_module fixture-clean clean
create_fixture_module fixture-drift drift
create_fixture_module fixture-skip skip
create_fixture_module fixture-fail fail
create_fixture_module fixture-verify-fail verify-fail
create_fixture_module fixture-apply-skip apply-skip
create_fixture_module fixture-apply-fail apply-fail
create_fixture_module fixture-apply-fail-converged apply-fail-converged
create_fixture_module fixture-after after

test_repair_applies_only_drift() {
    reset_run_state
    : > "$FIXTURE_LOG"
    printf 'desired\n' > "$FIXTURE_STATE_DIR/fixture-clean"
    rm -f "$FIXTURE_STATE_DIR/fixture-drift"
    register_module_policy fixture-clean required
    register_module_policy fixture-drift required

    run_modules repair fixture-clean fixture-drift

    assert_equal 1 "$(call_count fixture-clean:check)" \
        'repair must inspect a converged module once'
    assert_equal 0 "$(call_count fixture-clean:apply)" \
        'repair must not apply a converged module'
    assert_equal 1 "$(call_count fixture-drift:check)" \
        'repair must inspect a drifted module once'
    assert_equal 1 "$(call_count fixture-drift:apply)" \
        'repair must apply a drifted module once'
    assert_equal 1 "$(call_count fixture-drift:verify)" \
        'repair must verify a repaired module once'
    assert_equal desired "$(< "$FIXTURE_STATE_DIR/fixture-drift")" \
        'repair must converge fixture state'
}

test_audit_never_applies() {
    reset_run_state
    : > "$FIXTURE_LOG"
    printf 'desired\n' > "$FIXTURE_STATE_DIR/fixture-clean"
    rm -f "$FIXTURE_STATE_DIR/fixture-drift"

    if run_modules audit fixture-clean fixture-drift; then
        fail 'audit must report required drift as non-success'
    fi

    assert_equal 1 "$(call_count fixture-clean:check)" \
        'audit must inspect converged modules'
    assert_equal 1 "$(call_count fixture-drift:check)" \
        'audit must inspect drifted modules'
    assert_equal 0 "$(call_count fixture-clean:apply)" \
        'audit must never apply converged modules'
    assert_equal 0 "$(call_count fixture-drift:apply)" \
        'audit must never apply drifted modules'
    assert_array_contains DRIFT_MODULES fixture-drift
}

test_read_only_mutator_is_rejected() {
    local destination="$TEST_DIR/read-only-target"
    local package_marker="$TEST_DIR/package-mutator-called"
    local systemd_marker="$TEST_DIR/systemd-mutator-called"

    pacman() {
        printf 'called\n' > "$package_marker"
        return 1
    }
    systemctl() {
        printf 'called\n' > "$systemd_marker"
        return 1
    }

    if (SHORIN_READ_ONLY=1; ensure_line "$destination" forbidden) \
        >/dev/null 2>&1; then
        fail 'a file mutator must fail in read-only mode'
    fi
    [ ! -e "$destination" ] ||
        fail 'a rejected file mutator must not create or change its target'

    if (SHORIN_READ_ONLY=1; ensure_package forbidden) >/dev/null 2>&1; then
        fail 'a package mutator must fail in read-only mode'
    fi
    [ ! -e "$package_marker" ] ||
        fail 'a rejected package mutator must not invoke pacman'

    if (SHORIN_READ_ONLY=1; ensure_service_enabled forbidden.service) \
        >/dev/null 2>&1; then
        fail 'a systemd mutator must fail in read-only mode'
    fi
    [ ! -e "$systemd_marker" ] ||
        fail 'a rejected systemd mutator must not invoke systemctl'
}

test_apply_result_control_flow() {
    reset_run_state
    : > "$FIXTURE_LOG"
    rm -f "$FIXTURE_STATE_DIR/fixture-apply-skip" \
        "$FIXTURE_STATE_DIR/fixture-after"
    register_module_policy fixture-apply-skip optional
    register_module_policy fixture-after required

    run_modules install fixture-apply-skip fixture-after
    assert_array_contains OPTIONAL_SKIPS fixture-apply-skip:apply:skipped
    assert_equal 1 "$(call_count fixture-after:apply)" \
        'an optional apply skip must not stop later modules'

    reset_run_state
    : > "$FIXTURE_LOG"
    rm -f "$FIXTURE_STATE_DIR/fixture-apply-fail" \
        "$FIXTURE_STATE_DIR/fixture-after"
    register_module_policy fixture-apply-fail required
    register_module_policy fixture-after optional

    if run_modules install fixture-apply-fail fixture-after; then
        fail 'a required apply failure must stop later modules'
    fi
    assert_equal 0 "$(call_count fixture-after:check)" \
        'a module after a required failure must not run'

    reset_run_state
    : > "$FIXTURE_LOG"
    rm -f "$FIXTURE_STATE_DIR/fixture-apply-fail" \
        "$FIXTURE_STATE_DIR/fixture-after"
    register_module_policy fixture-apply-fail optional
    register_module_policy fixture-after required

    run_modules install fixture-apply-fail fixture-after
    assert_equal 1 "$(call_count fixture-after:apply)" \
        'an optional apply failure must not stop later modules'

    reset_run_state
    : > "$FIXTURE_LOG"
    register_module_policy fixture-fail required
    register_module_policy fixture-after optional
    if run_modules repair fixture-fail fixture-after; then
        fail 'a required repair check failure must stop collection'
    fi
    assert_equal 0 "$(call_count fixture-after:check)" \
        'repair must stop checking after a required inspection failure'
}

test_final_verification_reruns_without_duplicate_failures() {
    reset_run_state
    : > "$FIXTURE_LOG"
    rm -f "$FIXTURE_STATE_DIR/fixture-verify-fail"
    register_module_policy fixture-verify-fail required

    run_modules install fixture-verify-fail || true
    run_final_verification fixture-verify-fail || true

    assert_equal 2 "$(call_count fixture-verify-fail:verify)" \
        'final verification must inspect current state again'
    assert_equal 1 "${#REQUIRED_FAILURES[@]}" \
        'repeated verification must not duplicate the same failure'
}

test_final_status_uses_verified_state() {
    reset_run_state
    : > "$FIXTURE_LOG"
    rm -f "$FIXTURE_STATE_DIR/fixture-apply-fail-converged"
    register_module_policy fixture-apply-fail-converged required

    if run_modules install fixture-apply-fail-converged; then
        fail 'the process phase must still report the required apply error'
    fi
    assert_equal 1 "${#REQUIRED_FAILURES[@]}" \
        'the process failure must be visible before final verification'

    run_final_verification fixture-apply-fail-converged
    derive_final_status
    assert_equal SUCCESS "$FINAL_STATUS" \
        'final status must follow verified target state'
    assert_equal 0 "${#REQUIRED_FAILURES[@]}" \
        'a transient process error must not override final verification'
}

test_entrypoint_parse_status() {
    local status=0

    bash "$ENTRYPOINT" --help >/dev/null 2>&1 || status=$?
    assert_equal 0 "$status" '--help must exit successfully'

    status=0
    bash "$ENTRYPOINT" --not-a-real-option >/dev/null 2>&1 || status=$?
    assert_equal 64 "$status" 'an unknown option must be a usage error'

    status=0
    bash "$ENTRYPOINT" --user >/dev/null 2>&1 || status=$?
    assert_equal 64 "$status" 'a missing option value must be a usage error'
}

assert_status() {
    local expected_status=$1 expected_exit=$2
    derive_final_status
    assert_equal "$expected_status" "$FINAL_STATUS" 'final status mismatch'
    assert_equal "$expected_exit" "$FINAL_EXIT_CODE" 'final exit code mismatch'
}

test_status_matrix() {
    reset_run_state
    assert_status SUCCESS 0

    reset_run_state
    register_module_policy fixture-skip optional
    run_modules audit fixture-skip
    assert_status PARTIAL 2
    assert_array_contains OPTIONAL_SKIPS fixture-skip:check:skipped

    reset_run_state
    register_module_policy fixture-fail optional
    run_modules audit fixture-fail
    assert_status PARTIAL 2
    assert_array_contains OPTIONAL_FAILURES fixture-fail:check:rc=1

    reset_run_state
    register_module_policy fixture-fail required
    if run_modules audit fixture-fail; then
        fail 'a required inspection failure must stop the run'
    fi
    assert_status FAILED 1
    assert_array_contains REQUIRED_FAILURES fixture-fail:check:rc=1

    reset_run_state
    register_module_policy fixture-verify-fail required
    rm -f "$FIXTURE_STATE_DIR/fixture-verify-fail"
    if run_modules repair fixture-verify-fail; then
        fail 'a required verification failure must stop repair'
    fi
    assert_status FAILED 1
    assert_array_contains REQUIRED_FAILURES fixture-verify-fail:verify:rc=1
}

test_repair_applies_only_drift
test_audit_never_applies
test_read_only_mutator_is_rejected
test_apply_result_control_flow
test_final_verification_reruns_without_duplicate_failures
test_final_status_uses_verified_state
test_entrypoint_parse_status
test_status_matrix

printf 'PASS: mode runner contract\n'
