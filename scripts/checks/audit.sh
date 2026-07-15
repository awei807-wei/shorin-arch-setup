#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_CHECKS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SHORIN_CHECKS_DIR/../lib/verify.sh"

audit_modules() {
    local purpose=$1 module
    shift
    export SHORIN_READ_ONLY=1

    case "$purpose" in
        report)
            for module in "$@"; do
                run_module audit "$module" || true
            done
            ;;
        repair)
            collect_repair_drift "$@"
            ;;
        *) die "Unknown audit purpose: $purpose" ;;
    esac
}

run_audit() {
    export SHORIN_READ_ONLY=1
    audit_modules report "$@" || true
    run_final_verification "$@" || true
    derive_final_status
    [ "$FINAL_STATUS" != FAILED ]
}

audit_for_repair() {
    export SHORIN_READ_ONLY=1
    audit_modules repair "$@"
}
