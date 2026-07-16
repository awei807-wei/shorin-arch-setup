#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

if [ "${SHORIN_CORE_LOADED:-0}" = 1 ]; then
    return 0 2>/dev/null || exit 0
fi
readonly SHORIN_CORE_LOADED=1

readonly RC_OK=0
readonly RC_FAILED=1
readonly RC_DRIFT=10
readonly RC_SKIPPED=20
readonly EXIT_SUCCESS=0
readonly EXIT_FAILED=1
readonly EXIT_PARTIAL=2

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
MODULES_PATH=${MODULES_PATH:-$SHORIN_ROOT/scripts/modules}
SHORIN_SCRIPTS_DIR=${SHORIN_SCRIPTS_DIR:-$SHORIN_ROOT/scripts}
SHORIN_READ_ONLY=${SHORIN_READ_ONLY:-0}
export SHORIN_ROOT SHORIN_SCRIPTS_DIR MODULES_PATH SHORIN_READ_ONLY

SHORIN_LIB_DIR="$SHORIN_SCRIPTS_DIR/lib"
source "$SHORIN_LIB_DIR/files.sh"
source "$SHORIN_LIB_DIR/git.sh"
source "$SHORIN_LIB_DIR/packages.sh"
source "$SHORIN_LIB_DIR/snapshots.sh"
source "$SHORIN_LIB_DIR/systemd.sh"
source "$SHORIN_LIB_DIR/compat.sh"

declare -ag REQUIRED_FAILURES=()
declare -ag OPTIONAL_FAILURES=()
declare -ag OPTIONAL_SKIPS=()
declare -ag DRIFT_MODULES=()
declare -Ag MODULE_POLICY=()

FINAL_STATUS=SUCCESS
FINAL_EXIT_CODE=$EXIT_SUCCESS
PHASE_RC=$RC_OK
MODULE_RESULT=$RC_OK
declare -ag MODULE_REASONS=()

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

error() {
    printf 'ERROR: %s\n' "$*" >&2
}

die() {
    error "$*"
    return "$RC_FAILED"
}

acquire_run_lock() {
    local lock_file=${1:-/run/lock/shorin-arch-setup.lock}

    require_writable_mode
    command -v flock >/dev/null || die 'flock is required.'
    exec {SHORIN_LOCK_FD}>"$lock_file"
    flock -n "$SHORIN_LOCK_FD" || die 'Another Shorin setup process is running.'
    trap release_run_lock EXIT
}

release_run_lock() {
    if [ -n "${SHORIN_LOCK_FD:-}" ]; then
        flock -u "$SHORIN_LOCK_FD" || true
        exec {SHORIN_LOCK_FD}>&-
        unset SHORIN_LOCK_FD
    fi
    [ -z "${SHORIN_RUN_TOKEN:-}" ] ||
        rm -f "/run/lock/shorin-pacman-trust-$SHORIN_RUN_TOKEN"
    [ -z "${SHORIN_RUN_TOKEN:-}" ] ||
        rm -f "/run/lock/shorin-storage-snapshot-$SHORIN_RUN_TOKEN"
}

source "$SHORIN_LIB_DIR/state.sh"
source "$SHORIN_LIB_DIR/runner.sh"
source "$SHORIN_LIB_DIR/verify.sh"
