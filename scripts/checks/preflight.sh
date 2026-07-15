#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_CHECKS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SHORIN_CHECKS_DIR/../lib/state.sh"

preflight_readonly() {
    local mode=$1

    case "$mode" in
        install|repair|audit|verify) ;;
        *) die "Unsupported mode: $mode" ;;
    esac
    [ "${BASH_VERSINFO[0]}" -ge 4 ] || die 'Bash 4 or newer is required.'
    state_command_exists getent || die 'getent is required.'
    state_command_exists awk || die 'awk is required.'
    state_command_exists id || die 'id is required.'
    state_command_exists cut || die 'cut is required.'
}

preflight_mutating() {
    local mode=$1

    case "$mode" in
        install|repair) ;;
        *) die "Mutating preflight is not valid for $mode." ;;
    esac
    require_writable_mode
    [ "$EUID" -eq 0 ] || die "$mode must run as root."
    state_command_exists flock || die 'flock is required.'
    acquire_run_lock
}

preflight_resolve_target_user() {
    local mode=$1 requested=${2:-${TARGET_USER:-}}

    if resolve_target_user "$requested"; then
        return 0
    fi
    if [ "$mode" = install ] && [ -z "$requested" ]; then
        [ -t 0 ] || die 'Install requires --user when no target user exists.'
        read -r -p 'Target username: ' requested
        [[ "$requested" =~ ^[a-z_][a-z0-9_-]*$ ]] ||
            die "Invalid target username: $requested"
        TARGET_USER=$requested
        HOME_DIR="/home/$requested"
        export TARGET_USER HOME_DIR
        return 0
    fi
    die "Unable to resolve the target user for $mode."
}

run_preflight() {
    local mode=$1 requested=${2:-${TARGET_USER:-}}

    preflight_readonly "$mode"
    case "$mode" in
        audit|verify)
            export SHORIN_READ_ONLY=1
            ;;
        install|repair)
            export SHORIN_READ_ONLY=0
            preflight_mutating "$mode"
            ;;
    esac
    preflight_resolve_target_user "$mode" "$requested"
}
