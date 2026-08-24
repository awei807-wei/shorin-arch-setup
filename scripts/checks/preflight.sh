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
    platform_preflight || die 'Unsupported or incomplete target distribution.'
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
    if [ -n "$requested" ]; then
        die "Unable to resolve target user '$requested' for $mode: an explicit --user must name an existing non-root account."
    fi
    die "Unable to resolve the target user for $mode."
}

run_preflight() {
    local mode=$1 requested=${2:-${TARGET_USER:-}}

    preflight_readonly "$mode"
    # Resolve an explicit account before acquiring a run lock or entering any
    # mutating preflight. A missing --user must fail without even creating a
    # lock-file side effect.
    preflight_resolve_target_user "$mode" "$requested"
    case "$mode" in
        audit|verify)
            export SHORIN_READ_ONLY=1
            ;;
        install|repair)
            export SHORIN_READ_ONLY=0
            preflight_mutating "$mode"
            ;;
    esac
}

prepare_install_application_manifest() {
    local mode=$1 module selected=0 metadata
    shift

    [ "$mode" = install ] || return 0
    for module in "$@"; do
        if [ "$module" = applications ]; then
            selected=1
            break
        fi
    done
    [ "$selected" -eq 1 ] || return 0

    APPLICATION_SOURCE_LIST=${APPLICATION_SOURCE_LIST:-$SHORIN_ROOT/common-applist.txt}
    export APPLICATION_SOURCE_LIST
    source "$SHORIN_ROOT/scripts/modules/applications/targets.sh"
    [ ! -e "$APPLICATION_MANIFEST" ] || return 0
    metadata=$(application_manifest_metadata_path "$APPLICATION_MANIFEST")
    [ ! -e "$metadata" ] || {
        error "Application manifest metadata exists without its manifest: $metadata"
        return 1
    }
    if [ -t 0 ]; then
        write_application_selection_intent \
            "$APPLICATION_SOURCE_LIST" "$APPLICATION_MANIFEST" pending-selection
        log "Recorded pending interactive application selection: $(application_selection_intent_path "$APPLICATION_MANIFEST")"
        return 0
    fi
    initialize_default_application_manifest \
        "$APPLICATION_SOURCE_LIST" "$APPLICATION_MANIFEST"
}
