#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/modules/desktop-niri/fedora-provider-apply.sh"

usage() {
    cat <<'EOF'
Usage: bash scripts/fedora-desktop-providers.sh [--user NAME]

Install or repair Fedora target-user Starship and exact desktop fonts only.
This entry never invokes a package manager; curl, tar, unzip, xz, flock and
fontconfig must already be available in the target user's environment.
EOF
}

fail_entry() {
    local reason=$1

    printf 'MODULE_RESULT=fedora-desktop-providers:apply:FAILED\n'
    printf 'MODULE_REASON=fedora-desktop-providers:apply:%s\n' "$reason"
    return 0
}

main() {
    local target_user=${TARGET_USER:-} current_user home status=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --user)
                [ "$#" -ge 2 ] || {
                    usage >&2
                    fail_entry argument-missing 64
                    return 64
                }
                target_user=$2
                shift 2
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *)
                usage >&2
                fail_entry argument-invalid 64
                return 64
                ;;
        esac
    done

    platform_is_fedora || {
        error "Standalone Fedora desktop provider entry requires Fedora (detected ${SHORIN_DISTRO:-unknown})."
        fail_entry platform-not-fedora 1
        return 1
    }
    if [ "$(id -u)" -eq 0 ]; then
        target_user=${target_user:-${SUDO_USER:-}}
    else
        current_user=$(id -un)
        target_user=${target_user:-$current_user}
        [ "$target_user" = "$current_user" ] || {
            error "Non-root provider entry may target only the invoking user: $current_user."
            fail_entry target-user-mismatch 1
            return 1
        }
    fi
    [ -n "$target_user" ] || {
        error 'Root provider entry requires --user NAME or TARGET_USER.'
        fail_entry target-user-missing 1
        return 1
    }
    [ "$(id -u "$target_user" 2>/dev/null)" -ne 0 ] || {
        error 'The Fedora provider target must be a non-root desktop user.'
        fail_entry target-user-root 1
        return 1
    }
    home=$(getent passwd "$target_user" | cut -d: -f6)
    [ -n "$home" ] || {
        error "Unable to resolve the home directory for target user $target_user."
        fail_entry target-home-missing 1
        return 1
    }
    if [ "${SHORIN_READ_ONLY:-0}" = 1 ] ||
        [[ "${SHORIN_MODE:-repair}" =~ ^(audit|verify)$ ]]; then
        error 'The standalone Fedora provider entry requires a writable repair mode.'
        fail_entry read-only-mode 1
        return 1
    fi
    export TARGET_USER=$target_user HOME_DIR=$home
    SHORIN_MODE=${SHORIN_MODE:-repair}
    export SHORIN_MODE SHORIN_READ_ONLY=0

    fedora_desktop_provider_apply_user "$target_user" "$home" || status=$?
    if [ "$status" -ne 0 ]; then
        fail_entry "${FEDORA_PROVIDER_APPLY_REASON:-provider-apply-failed}"
        return "$status"
    fi
    printf 'MODULE_RESULT=fedora-desktop-providers:apply:OK\n'
    printf 'MODULE_REASON=fedora-desktop-providers:apply:target-user:%s\n' "$target_user"
}

if main "$@"; then
    exit 0
else
    exit $?
fi
