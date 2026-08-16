#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SHORIN_DISTRO=fedora SHORIN_MODE=repair SHORIN_READ_ONLY=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

# Load the real base contract without executing module_main. The module
# runner is already loaded by targets.sh, so replacing the entry point here is
# sufficient to expose the shared base inspection/apply helpers to this mock.
source "$ROOT_DIR/scripts/modules/base/targets.sh"
module_main() { :; }
source "$ROOT_DIR/scripts/modules/base.sh"

[ "$(fedora_arch_target_name tuned-ppd)" = tuned-ppd ] ||
    fail 'Fedora tuned-ppd package mapping must remain explicit'

declare -Ag INSTALLED=()
declare -Ag AVAILABLE=()
declare -Ag SERVICES_ENABLED=()
declare -Ag SERVICES_ACTIVE=()
declare -ag DNF_CALLS=()
declare -ag PACKAGE_CALLS=()
declare -ag SERVICE_CALLS=()
RPM_QUERY_ERROR_PACKAGE=''
DNF_QUERY_ERROR_PACKAGE=''
SERVICE_QUERY_ERROR=''

package_is_installed() {
    local package=$1

    [ "$package" != "$RPM_QUERY_ERROR_PACKAGE" ] || return 7
    [ "${INSTALLED[$package]:-0}" -eq 1 ]
}

platform_dnf_package_available() {
    local package=$1

    DNF_CALLS+=("repoquery:$package")
    [ "$package" != "$DNF_QUERY_ERROR_PACKAGE" ] || return 9
    [ "${AVAILABLE[$package]:-0}" -eq 1 ]
}

ensure_package() {
    local package=$1

    PACKAGE_CALLS+=("$package")
    [ "$package" != power-profiles-daemon ] ||
        ! printf '%s\n' "${DNF_CALLS[@]}" | grep -Fq -- '--allowerasing'
    INSTALLED[$package]=1
}

ensure_service_started() {
    local unit=$1

    SERVICE_CALLS+=("$unit")
    SERVICES_ENABLED[$unit]=1
    SERVICES_ACTIVE[$unit]=1
}

state_package_present() { package_is_installed "$1"; }
state_service_enabled() {
    [ "$1" != "$SERVICE_QUERY_ERROR" ] || return 11
    [ "${SERVICES_ENABLED[$1]:-0}" -eq 1 ]
}
state_service_active() { [ "${SERVICES_ACTIVE[$1]:-0}" -eq 1 ]; }

reset_case() {
    INSTALLED=()
    AVAILABLE=()
    SERVICES_ENABLED=()
    SERVICES_ACTIVE=()
    DNF_CALLS=()
    PACKAGE_CALLS=()
    SERVICE_CALLS=()
    RPM_QUERY_ERROR_PACKAGE=''
    DNF_QUERY_ERROR_PACKAGE=''
    SERVICE_QUERY_ERROR=''
    MODULE_RESULT=$RC_OK
    MODULE_REASONS=()
}

assert_check_and_verify() {
    local provider=$1 unit

    unit=$(base_power_profile_provider_unit "$provider")
    SERVICES_ENABLED[$unit]=1
    SERVICES_ACTIVE[$unit]=1
    MODULE_RESULT=$RC_OK
    MODULE_REASONS=()
    base_power_profile_inspect check
    [ "$MODULE_RESULT" -eq "$RC_OK" ] ||
        fail "check must accept installed Fedora provider: $provider"
    MODULE_RESULT=$RC_OK
    MODULE_REASONS=()
    base_power_profile_inspect verify
    [ "$MODULE_RESULT" -eq "$RC_OK" ] ||
        fail "verify must accept installed Fedora provider: $provider"
}

# An installed tuned-ppd provider satisfies the contract. Apply must not ask
# dnf to install power-profiles-daemon or pass --allowerasing.
reset_case
INSTALLED[tuned-ppd]=1
assert_check_and_verify tuned-ppd
base_ensure_power_profile_provider || fail 'tuned-ppd apply path must converge'
grep -Fqx tuned-ppd.service <<< "${SERVICE_CALLS[*]}" ||
    fail 'tuned-ppd apply path must use tuned-ppd.service'
! printf '%s\n' "${PACKAGE_CALLS[@]}" | grep -Fqx power-profiles-daemon ||
    fail 'tuned-ppd apply path must not install power-profiles-daemon'
! printf '%s\n' "${DNF_CALLS[@]}" | grep -Fq -- '--allowerasing' ||
    fail 'provider apply path must never use --allowerasing'
[ "$(base_power_profile_provider_unit tuned-ppd)" = tuned-ppd.service ] ||
    fail 'tuned-ppd must use tuned-ppd.service'

# An existing power-profiles-daemon provider remains supported for Fedora.
reset_case
INSTALLED[power-profiles-daemon]=1
assert_check_and_verify power-profiles-daemon
base_ensure_power_profile_provider ||
    fail 'power-profiles-daemon apply path must converge'
grep -Fqx power-profiles-daemon.service <<< "${SERVICE_CALLS[*]}" ||
    fail 'power-profiles-daemon apply path must use its service'
! printf '%s\n' "${PACKAGE_CALLS[@]}" | grep -Fqx tuned-ppd ||
    fail 'existing power-profiles-daemon must not install tuned-ppd'

reset_case
INSTALLED[tuned-ppd]=1
INSTALLED[power-profiles-daemon]=1
MODULE_RESULT=$RC_OK
MODULE_REASONS=()
base_power_profile_inspect check
[ "$MODULE_RESULT" -eq "$RC_FAILED" ] ||
    fail 'simultaneous Fedora providers must fail check explicitly'
grep -Fqx power-profile-provider:multiple <<< "${MODULE_REASONS[*]}" ||
    fail 'simultaneous Fedora providers must identify the conflicting providers'
MODULE_RESULT=$RC_OK
MODULE_REASONS=()
base_power_profile_inspect verify
[ "$MODULE_RESULT" -eq "$RC_FAILED" ] ||
    fail 'simultaneous Fedora providers must fail verify explicitly'
if base_ensure_power_profile_provider; then
    fail 'simultaneous Fedora providers must be rejected without package changes'
fi
[ "${#PACKAGE_CALLS[@]}" -eq 0 ] ||
    fail 'simultaneous Fedora providers must not trigger package changes'

# With neither provider installed, tuned-ppd is the preferred Fedora package.
reset_case
AVAILABLE[tuned-ppd]=1
AVAILABLE[power-profiles-daemon]=1
base_ensure_power_profile_provider ||
    fail 'missing Fedora provider must install tuned-ppd'
grep -Fqx tuned-ppd <<< "${PACKAGE_CALLS[*]}" ||
    fail 'missing Fedora provider must prefer tuned-ppd'
! printf '%s\n' "${PACKAGE_CALLS[@]}" | grep -Fqx power-profiles-daemon ||
    fail 'missing Fedora provider must not install both candidates'

reset_case
AVAILABLE[power-profiles-daemon]=1
base_ensure_power_profile_provider ||
    fail 'Fedora fallback provider must converge when tuned-ppd is unavailable'
grep -Fqx power-profiles-daemon <<< "${PACKAGE_CALLS[*]}" ||
    fail 'Fedora fallback provider must install power-profiles-daemon'
! printf '%s\n' "${PACKAGE_CALLS[@]}" | grep -Fqx tuned-ppd ||
    fail 'Fedora fallback provider must not install unavailable tuned-ppd'

# A missing capability is drift on check, but a real RPM query error is a
# failed inspection and must not be rewritten as drift.
reset_case
MODULE_RESULT=$RC_OK
MODULE_REASONS=()
base_power_profile_inspect check
[ "$MODULE_RESULT" -eq "$RC_DRIFT" ] ||
    fail 'missing Fedora provider must be DRIFT during check'
reset_case
RPM_QUERY_ERROR_PACKAGE=tuned-ppd
MODULE_RESULT=$RC_OK
MODULE_REASONS=()
base_power_profile_inspect check
[ "$MODULE_RESULT" -eq "$RC_FAILED" ] ||
    fail 'provider RPM query error must fail inspection'
grep -Fqx power-profile-provider:inspection-error:7 <<< "${MODULE_REASONS[*]}" ||
    fail 'provider RPM query error reason must preserve status'
reset_case
DNF_QUERY_ERROR_PACKAGE=tuned-ppd
if base_ensure_power_profile_provider; then
    fail 'provider DNF query error must fail apply'
fi
! printf '%s\n' "${PACKAGE_CALLS[@]}" | grep -Fqx power-profiles-daemon ||
    fail 'provider DNF query error must not fall through to the conflicting package'
reset_case
INSTALLED[tuned-ppd]=1
SERVICE_QUERY_ERROR=tuned-ppd.service
MODULE_RESULT=$RC_OK
MODULE_REASONS=()
base_power_profile_inspect check
[ "$MODULE_RESULT" -eq "$RC_FAILED" ] ||
    fail 'provider service query error must fail inspection'
grep -Fq service:power-profile-provider:tuned-ppd.service:inspection-error:11 \
    <<< "${MODULE_REASONS[*]}" ||
    fail 'provider service query error reason must preserve status'

# Arch keeps the original exact package and unit contract.
reset_case
export SHORIN_DISTRO=arch
mapfile -t ARCH_BASE_PACKAGES < <(base_declared_packages)
printf '%s\n' "${ARCH_BASE_PACKAGES[@]}" | grep -Fqx power-profiles-daemon ||
    fail 'Arch base package contract must retain power-profiles-daemon'
export SHORIN_DISTRO=fedora
mapfile -t FEDORA_BASE_PACKAGES < <(base_declared_packages)
! printf '%s\n' "${FEDORA_BASE_PACKAGES[@]}" |
    grep -Fqx power-profiles-daemon ||
    fail 'Fedora base package contract must not require a conflicting provider'
export SHORIN_DISTRO=arch
base_ensure_power_profile_provider || fail 'Arch provider must converge'
grep -Fqx power-profiles-daemon <<< "${PACKAGE_CALLS[*]}" ||
    fail 'Arch provider must install power-profiles-daemon'
grep -Fqx power-profiles-daemon.service <<< "${SERVICE_CALLS[*]}" ||
    fail 'Arch provider must start power-profiles-daemon.service'

printf 'PASS: Fedora PPD provider capability contract and Arch regression\n'
