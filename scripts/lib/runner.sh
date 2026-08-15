#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

if [ "${SHORIN_RUNNER_LOADED:-0}" = 1 ]; then
    return 0 2>/dev/null || exit 0
fi
readonly SHORIN_RUNNER_LOADED=1

SHORIN_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SHORIN_LIB_DIR/state.sh"

# Module result aggregation and dependency-ordered orchestration.

append_unique() {
    local array_name=$1 value=$2 current
    local -n target_array=$array_name

    for current in "${target_array[@]}"; do
        [ "$current" != "$value" ] || return 0
    done
    target_array+=("$value")
}

reset_run_state() {
    REQUIRED_FAILURES=()
    OPTIONAL_FAILURES=()
    OPTIONAL_SKIPS=()
    DRIFT_MODULES=()
    FINAL_STATUS=SUCCESS
    FINAL_EXIT_CODE=$EXIT_SUCCESS
}

register_module_policy() {
    local module=$1 policy=$2

    case "$policy" in
        required|optional) MODULE_POLICY["$module"]=$policy ;;
        *) die "Invalid policy for $module: $policy" ;;
    esac
}

module_policy() {
    local module=$1
    printf '%s\n' "${MODULE_POLICY[$module]:-required}"
}

require_writable_mode() {
    [ "${SHORIN_READ_ONLY:-0}" != 1 ] ||
        die 'A mutating operation was requested in read-only mode.'
}

module_result_reset() {
    MODULE_RESULT=$RC_OK
    MODULE_REASONS=()
}

module_drift() {
    case "$MODULE_RESULT" in
        "$RC_FAILED"|"$RC_SKIPPED") ;;
        *) MODULE_RESULT=$RC_DRIFT ;;
    esac
    append_unique MODULE_REASONS "$1"
}

module_skip() {
    [ "$MODULE_RESULT" -eq "$RC_FAILED" ] || MODULE_RESULT=$RC_SKIPPED
    append_unique MODULE_REASONS "$1"
}

module_inspection_failed() {
    MODULE_RESULT=$RC_FAILED
    append_unique MODULE_REASONS "$1"
}

module_verify_failed() {
    MODULE_RESULT=$RC_FAILED
    append_unique MODULE_REASONS "$1"
}

module_check_state() {
    local label=$1 status
    shift

    if "$@"; then
        return 0
    else
        status=$?
    fi
    case "$status" in
        1) module_drift "$label" ;;
        *) module_inspection_failed "$label:inspection-error:$status" ;;
    esac
}

module_emit_result() {
    local module=$1 phase=$2 reason
    local status=OK

    case "$MODULE_RESULT" in
        "$RC_DRIFT") status=DRIFT ;;
        "$RC_SKIPPED") status=SKIPPED ;;
        "$RC_FAILED") status=FAILED ;;
    esac
    printf 'MODULE_RESULT=%s:%s:%s\n' "$module" "$phase" "$status"
    for reason in "${MODULE_REASONS[@]}"; do
        printf 'MODULE_REASON=%s:%s:%s\n' "$module" "$phase" "$reason"
    done
}

# Module scripts call this once after defining <module>_{check,apply,verify}.
module_main() {
    local module=$1 phase=${2:-} function_prefix function_name

    function_prefix=${module//-/_}
    case "$phase" in
        check|verify)
            function_name="${function_prefix}_${phase}"
            declare -F "$function_name" >/dev/null ||
                die "Module $module does not implement $phase"
            module_result_reset
            "$function_name"
            module_emit_result "$module" "$phase"
            exit "$MODULE_RESULT"
            ;;
        apply)
            function_name="${function_prefix}_apply"
            declare -F "$function_name" >/dev/null ||
                die "Module $module does not implement apply"
            module_result_reset
            require_writable_mode
            "$function_name"
            module_emit_result "$module" "$phase"
            exit "$MODULE_RESULT"
            ;;
        *)
            error "Usage: $0 {check|apply|verify}"
            exit 64
            ;;
    esac
}

record_module_failure() {
    local module=$1 phase=$2 detail=${3:-failed}
    local item="$module:$phase:$detail"

    if [ "$(module_policy "$module")" = required ]; then
        append_unique REQUIRED_FAILURES "$item"
    else
        append_unique OPTIONAL_FAILURES "$item"
    fi
}

record_module_skip() {
    local module=$1 phase=$2

    if [ "$(module_policy "$module")" = required ]; then
        append_unique REQUIRED_FAILURES "$module:$phase:skipped"
    else
        append_unique OPTIONAL_SKIPS "$module:$phase:skipped"
    fi
}

run_module_phase() {
    local module=$1 phase=$2 module_file readonly=0 status=0

    module_file="$MODULES_PATH/$module.sh"
    if [ ! -f "$module_file" ]; then
        PHASE_RC=$RC_FAILED
        return 0
    fi
    case "$phase" in
        check|verify) readonly=1 ;;
        apply) readonly=0 ;;
        *) PHASE_RC=64; return 0 ;;
    esac

    env SHORIN_ROOT="$SHORIN_ROOT" \
        SHORIN_SCRIPTS_DIR="${SHORIN_SCRIPTS_DIR:-$SHORIN_ROOT/scripts}" \
        SHORIN_MODE="${SHORIN_MODE:-install}" \
        SHORIN_DISTRO="${SHORIN_DISTRO:-}" \
        SHORIN_PROFILE_DIR="${SHORIN_PROFILE_DIR:-/etc/shorin-arch-setup}" \
        SHORIN_RUN_TOKEN="${SHORIN_RUN_TOKEN:-$$}" \
        SHORIN_READ_ONLY="$readonly" \
        TARGET_USER="${TARGET_USER:-}" \
        HOME_DIR="${HOME_DIR:-}" \
        bash "$module_file" "$phase" || status=$?
    case "$status" in
        "$RC_OK"|"$RC_DRIFT"|"$RC_SKIPPED") PHASE_RC=$status ;;
        *) PHASE_RC=$RC_FAILED ;;
    esac
    return 0
}

verify_one_module() {
    local module=$1

    run_module_phase "$module" verify
    case "$PHASE_RC" in
        "$RC_OK") return 0 ;;
        "$RC_SKIPPED") record_module_skip "$module" verify ;;
        *) record_module_failure "$module" verify "rc=$PHASE_RC" ;;
    esac
    [ "$(module_policy "$module")" != required ]
}

apply_and_verify_module() {
    local module=$1

    run_module_phase "$module" apply
    case "$PHASE_RC" in
        "$RC_OK") verify_one_module "$module" ;;
        "$RC_SKIPPED")
            record_module_skip "$module" apply
            [ "$(module_policy "$module")" != required ]
            ;;
        *)
            record_module_failure "$module" apply "rc=$PHASE_RC"
            [ "$(module_policy "$module")" != required ]
            ;;
    esac
}

converge_module() {
    local module=$1

    run_module_phase "$module" check
    case "$PHASE_RC" in
        "$RC_OK") verify_one_module "$module" ;;
        "$RC_DRIFT") apply_and_verify_module "$module" ;;
        "$RC_SKIPPED")
            record_module_skip "$module" check
            [ "$(module_policy "$module")" != required ]
            ;;
        *)
            record_module_failure "$module" check "rc=$PHASE_RC"
            [ "$(module_policy "$module")" != required ]
            ;;
    esac
}

run_module() {
    local mode=$1 module=$2

    case "$mode" in
        install|repair) converge_module "$module" ;;
        audit)
            run_module_phase "$module" check
            case "$PHASE_RC" in
                "$RC_OK") return 0 ;;
                "$RC_DRIFT")
                    append_unique DRIFT_MODULES "$module"
                    record_module_failure "$module" check drift
                    ;;
                "$RC_SKIPPED") record_module_skip "$module" check ;;
                *) record_module_failure "$module" check "rc=$PHASE_RC" ;;
            esac
            [ "$(module_policy "$module")" != required ]
            ;;
        verify) verify_one_module "$module" ;;
        *) die "Unknown run mode: $mode" ;;
    esac
}

run_modules() {
    local mode=$1 module dependency blocked status=0
    shift

    # A failed required module no longer stops the whole run: independent
    # modules keep converging, and only declared dependents are skipped.
    local -A halted_modules=()
    for module in "$@"; do
        blocked=''
        if [[ $(declare -p MODULE_DEPENDS 2>/dev/null) == 'declare -A'* ]]; then
            for dependency in ${MODULE_DEPENDS[$module]:-}; do
                if [ -n "${halted_modules[$dependency]:-}" ]; then
                    blocked=$dependency
                    break
                fi
            done
        fi
        if [ -n "$blocked" ]; then
            record_module_failure "$module" converge "blocked-by:$blocked"
            halted_modules[$module]=1
            status=1
            continue
        fi
        if ! run_module "$mode" "$module"; then
            halted_modules[$module]=1
            status=1
        fi
    done
    return "$status"
}

derive_final_status() {
    if [ "${#REQUIRED_FAILURES[@]}" -gt 0 ]; then
        FINAL_STATUS=FAILED
        FINAL_EXIT_CODE=$EXIT_FAILED
    elif [ "${#OPTIONAL_FAILURES[@]}" -gt 0 ] ||
        [ "${#OPTIONAL_SKIPS[@]}" -gt 0 ]; then
        FINAL_STATUS=PARTIAL
        FINAL_EXIT_CODE=$EXIT_PARTIAL
    else
        FINAL_STATUS=SUCCESS
        FINAL_EXIT_CODE=$EXIT_SUCCESS
    fi
}

print_summary() {
    derive_final_status
    printf 'INSTALL_STATUS=%s\n' "$FINAL_STATUS"
    [ "${#REQUIRED_FAILURES[@]}" -eq 0 ] ||
        printf 'REQUIRED_FAILURES=%s\n' "${REQUIRED_FAILURES[*]}"
    [ "${#OPTIONAL_FAILURES[@]}" -eq 0 ] ||
        printf 'OPTIONAL_FAILURES=%s\n' "${OPTIONAL_FAILURES[*]}"
    [ "${#OPTIONAL_SKIPS[@]}" -eq 0 ] ||
        printf 'OPTIONAL_SKIPS=%s\n' "${OPTIONAL_SKIPS[*]}"
}
