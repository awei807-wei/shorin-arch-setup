#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_CHECKS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SHORIN_CHECKS_DIR/../lib/state.sh"

_terminal_type_available() {
    local terminal=$1

    [[ "$terminal" =~ ^[[:alnum:]][[:alnum:]+._-]*$ ]] || return 1
    if command -v infocmp >/dev/null 2>&1; then
        infocmp "$terminal" >/dev/null 2>&1
    else
        tput -T "$terminal" longname >/dev/null 2>&1
    fi
}

# Keep recovery commands usable when the invoking terminal is not installed yet.
normalize_terminal_environment() {
    local inherited=${TERM:-} fallback

    if ! command -v infocmp >/dev/null 2>&1 &&
        ! command -v tput >/dev/null 2>&1; then
        warn "Cannot validate TERM=${inherited:-unset}; using TERM=dumb for this run."
        export TERM=dumb
        return 0
    fi
    _terminal_type_available "$inherited" && return 0
    for fallback in xterm-256color xterm dumb; do
        if _terminal_type_available "$fallback"; then
            warn "TERM=${inherited:-unset} has no usable terminfo; using TERM=$fallback for this run."
            export TERM=$fallback
            return 0
        fi
    done
    warn "No usable terminfo entry was found; using TERM=dumb for this run."
    export TERM=dumb
}

preflight_readonly() {
    local mode=$1

    normalize_terminal_environment
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
