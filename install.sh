#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR
SHORIN_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export SHORIN_RUN_TOKEN=${SHORIN_RUN_TOKEN:-$(cat /proc/sys/kernel/random/uuid)}
source "$SHORIN_ROOT/scripts/lib/core.sh"
source "$SHORIN_ROOT/scripts/checks/preflight.sh"
source "$SHORIN_ROOT/scripts/checks/audit.sh"
ALL_MODULES=(
    storage
    base
    desktop-niri
    applications
    virtualization
    nas-rime
    vcp
    grub
)
declare -A DEFAULT_POLICY=(
    [storage]=required
    [base]=required
    [desktop-niri]=required
    [applications]=optional
    [virtualization]=optional
    [nas-rime]=optional
    [vcp]=optional
    [grub]=required
)
declare -A MODULE_DEPENDS=(
    [desktop-niri]='storage base'
    [applications]='base'
    [virtualization]='base'
    [nas-rime]='base'
    [vcp]='applications'
    [grub]='storage base'
)
usage() {
    cat <<'EOF'
Usage: sudo bash install.sh [install|repair|audit|verify] [options] [module...]
Modes:
  install  Converge the complete selected target (default).
  repair   Audit first, then apply only modules with drift.
  audit    Read-only drift report; never writes system state.
  verify   Read-only authoritative verification.
Options:
  --user NAME       Target user for install or repair.
  --distro NAME     Target distribution: arch or fedora (auto-detected by default).
  --profile-dir DIR Desired-state manifest directory.
  -h, --help        Show this help.
EOF
}
parse_args() {
    MODE=install
    SHOW_HELP=0
    SELECTED_MODULES=()
    if [[ "${1:-}" =~ ^(install|repair|audit|verify)$ ]]; then
        MODE=$1
        shift
    fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --user)
                [ "$#" -ge 2 ] && [ -n "$2" ] || {
                    error 'Missing value for --user'
                    return 64
                }
                TARGET_USER=$2
                shift 2
                ;;
            --profile-dir)
                [ "$#" -ge 2 ] && [ -n "$2" ] || {
                    error 'Missing value for --profile-dir'
                    return 64
                }
                SHORIN_PROFILE_DIR=$2
                shift 2
                ;;
            --distro|--platform|--target)
                [ "$#" -ge 2 ] && [ -n "$2" ] || {
                    error "Missing value for $1"
                    return 64
                }
                SHORIN_DISTRO=$2
                shift 2
                ;;
            install|repair|audit|verify) MODE=$1; shift ;;
            -h|--help) SHOW_HELP=1; return 0 ;;
            --*) error "Unknown option: $1"; return 64 ;;
            *) SELECTED_MODULES+=("$1"); shift ;;
        esac
    done
    [ "${#SELECTED_MODULES[@]}" -gt 0 ] || SELECTED_MODULES=("${ALL_MODULES[@]}")
    SHORIN_MODE=$MODE
    SHORIN_PROFILE_DIR=${SHORIN_PROFILE_DIR:-/etc/shorin-arch-setup}
    export SHORIN_MODE SHORIN_PROFILE_DIR TARGET_USER SHORIN_DISTRO
}
configure_modules() {
    local module dependency seen=' '
    for module in "${SELECTED_MODULES[@]}"; do
        if [ -z "${DEFAULT_POLICY[$module]:-}" ]; then
            error "Unknown module: $module"
            return 64
        fi
        register_module_policy "$module" "${DEFAULT_POLICY[$module]}"
        if [ "$MODE" != verify ] && [ "$MODE" != audit ]; then
            for dependency in ${MODULE_DEPENDS[$module]:-}; do
                if [[ "$seen" != *" $dependency "* ]]; then
                    error "$module requires earlier module: $dependency"
                    return 64
                fi
            done
        fi
        seen+="$module "
    done
}
main() {
    local parse_status=0; MAIN_EXIT_CODE=0
    parse_args "$@" || parse_status=$?
    [ "$parse_status" -eq 0 ] || {
        usage >&2
        MAIN_EXIT_CODE=$parse_status
        return 0
    }
    if [ "$SHOW_HELP" -eq 1 ]; then
        usage
        return 0
    fi
    reset_run_state
    configure_modules || parse_status=$?
    [ "$parse_status" -eq 0 ] || {
        usage >&2
        MAIN_EXIT_CODE=$parse_status
        return 0
    }
    run_preflight "$MODE" "${TARGET_USER:-}"
    case "$MODE" in
        install|repair) run_modules "$MODE" "${SELECTED_MODULES[@]}" || true ;;
        audit) audit_modules report "${SELECTED_MODULES[@]}" || true ;;
        verify) ;;
    esac
    run_final_verification "${SELECTED_MODULES[@]}" || true
    print_summary
    release_run_lock
    MAIN_EXIT_CODE=$FINAL_EXIT_CODE
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
    exit "$MAIN_EXIT_CODE"
fi
