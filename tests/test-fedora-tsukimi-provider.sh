#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SHORIN_DISTRO=fedora SHORIN_MODE=install SHORIN_READ_ONLY=0
TEST_DIR=$(mktemp -d)
TARGET_USER=$(id -un)
HOME_DIR="$TEST_DIR/home"
mkdir -p "$HOME_DIR"
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

export SHORIN_ROOT="$ROOT_DIR" TARGET_USER HOME_DIR
source "$ROOT_DIR/scripts/lib/core.sh"
# Keep the host's installed Tsukimi binary from satisfying the target before
# the provider under test has installed its mapped package.
command() {
    if [ "${1:-}" = -v ] && [ "${2:-}" = tsukimi ]; then
        return 1
    fi
    builtin command "$@"
}

declare -Ag TSUKIMI_PACKAGES=()
declare -a TSUKIMI_CALLS=()
TSUKIMI_COPR_ENABLED=0

package_is_installed() {
    [ "${TSUKIMI_PACKAGES[$1]:-0}" -eq 1 ]
}

ensure_package() {
    TSUKIMI_PACKAGES["$1"]=1
    TSUKIMI_CALLS+=("package:$1")
}

dnf() {
    case "${1:-}" in
        repolist)
            if [ "$TSUKIMI_COPR_ENABLED" -eq 1 ]; then
                printf 'copr:copr.fedorainfracloud.org:walker874:tsukimi\n'
            fi
            ;;
        copr)
            [ "${2:-}" = enable ] || return 1
            TSUKIMI_COPR_ENABLED=1
            TSUKIMI_CALLS+=("copr:${!#}")
            ;;
        *) return 1 ;;
    esac
}

[ "$(fedora_application_provider_kind tsukimi-bin)" = copr ] ||
    fail 'Tsukimi provider kind must be copr'
[ "$(fedora_application_provider_id tsukimi-bin)" = walker874/tsukimi ] ||
    fail 'Tsukimi provider registry must use walker874/tsukimi'

fedora_install_application_target tsukimi-bin "$TARGET_USER" "$HOME_DIR" ||
    fail 'Tsukimi provider did not converge through the shared registry'
[ "$TSUKIMI_COPR_ENABLED" -eq 1 ] ||
    fail 'Tsukimi provider did not enable walker874/tsukimi'
[ "${TSUKIMI_PACKAGES[tsukimi]:-0}" -eq 1 ] ||
    fail 'Tsukimi provider did not install the tsukimi package'

copr_calls=${#TSUKIMI_CALLS[@]}
fedora_install_application_target tsukimi-bin "$TARGET_USER" "$HOME_DIR" ||
    fail 'Tsukimi provider was not idempotent'
[ "${#TSUKIMI_CALLS[@]}" -eq "$copr_calls" ] ||
    fail 'Tsukimi provider repeated installation after convergence'

printf 'PASS: Fedora Tsukimi provider registry and idempotency contract\n'
