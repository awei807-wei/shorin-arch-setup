#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
CALLS="$TEST_DIR/calls.log"
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

export SHORIN_DISTRO=fedora SHORIN_MODE=repair SHORIN_READ_ONLY=0
source "$ROOT_DIR/scripts/lib/core.sh"
source "$ROOT_DIR/scripts/modules/virtualization/contract.sh"

declare -A UNIT_AVAILABLE=()
declare -A UNIT_ENABLED=()
declare -A UNIT_ACTIVE=()
VIRSH_URI_STATUS=0
VIRSH_LIST_STATUS=0
VIRSH_NETWORK_STATUS=0

systemctl() {
    local action=${1:-} unit

    case "$action" in
        show)
            unit=${!#}
            if [ "${UNIT_AVAILABLE[$unit]:-0}" -eq 1 ]; then
                printf 'loaded\n'
            else
                printf 'not-found\n'
            fi
            ;;
        is-enabled)
            unit=${2:-}
            if [ "${UNIT_ENABLED[$unit]:-0}" -eq 1 ]; then
                printf 'enabled\n'
            else
                printf 'disabled\n'
                return 1
            fi
            ;;
        is-active)
            unit=${!#}
            [ "${UNIT_ACTIVE[$unit]:-0}" -eq 1 ]
            ;;
        enable)
            unit=${2:-}
            UNIT_ENABLED[$unit]=1
            printf 'enable:%s\n' "$unit" >> "$CALLS"
            ;;
        disable)
            unit=${2:-}
            UNIT_ENABLED[$unit]=0
            if [ "$unit" = libvirtd.service ]; then
                UNIT_ENABLED[virtlockd.socket]=0
                UNIT_ENABLED[virtlogd.socket]=0
            fi
            printf 'disable:%s\n' "$unit" >> "$CALLS"
            ;;
        start)
            unit=${2:-}
            UNIT_ACTIVE[$unit]=1
            printf 'start:%s\n' "$unit" >> "$CALLS"
            ;;
        stop)
            unit=${2:-}
            UNIT_ACTIVE[$unit]=0
            printf 'stop:%s\n' "$unit" >> "$CALLS"
            ;;
        *) return 2 ;;
    esac
}

virsh() {
    [ "${1:-}" = -c ] || return 3
    [ "${2:-}" = qemu:///system ] || return 3
    shift 2
    case "${1:-}" in
        uri)
            [ "$VIRSH_URI_STATUS" -eq 0 ] || return "$VIRSH_URI_STATUS"
            printf 'qemu:///system\n'
            ;;
        list)
            [ "${2:-}" = --all ] && [ "${3:-}" = --name ] || return 3
            return "$VIRSH_LIST_STATUS"
            ;;
        net-info)
            [ "${2:-}" = default ] || return 3
            [ "$VIRSH_NETWORK_STATUS" -eq 0 ] || return "$VIRSH_NETWORK_STATUS"
            printf 'Name: default\nActive: yes\nAutostart: yes\n'
            ;;
        *) return 3 ;;
    esac
}

reset_units() {
    local unit

    UNIT_AVAILABLE=()
    UNIT_ENABLED=()
    UNIT_ACTIVE=()
    : > "$CALLS"
    VIRSH_URI_STATUS=0
    VIRSH_LIST_STATUS=0
    VIRSH_NETWORK_STATUS=0
    VIRTUALIZATION_PROVIDER=auto
    while IFS= read -r unit; do
        UNIT_AVAILABLE[$unit]=1
        UNIT_ENABLED[$unit]=0
        UNIT_ACTIVE[$unit]=0
    done < <(
        printf '%s\n' "${VIRTUALIZATION_COMMON_REQUIRED_UNITS[@]}"
        virtualization_provider_all_units modular
        virtualization_provider_all_units monolithic
    )
}

select_provider() {
    local provider=$1 unit

    while IFS= read -r unit; do
        UNIT_ENABLED[$unit]=1
        UNIT_ACTIVE[$unit]=1
    done < <(virtualization_provider_required_units "$provider")
}

reset_units
select_provider modular
[ "$(virtualization_detect_provider)" = modular ] ||
    fail 'complete modular sockets must select the modular provider'
virtualization_provider_ready ||
    fail 'complete modular sockets and qemu:///system must satisfy the provider'
virtualization_default_network_ready ||
    fail 'the modular provider must expose the active default network'
[ "${UNIT_ACTIVE[virtqemud.service]:-0}" -eq 0 ] ||
    fail 'the modular daemon fixture must remain idle for the socket test'

reset_units
select_provider monolithic
[ "$(virtualization_detect_provider)" = monolithic ] ||
    fail 'a lone libvirtd socket must select the monolithic provider'
virtualization_provider_ready ||
    fail 'an idle libvirtd daemon with a live socket must satisfy the provider'
[ "${UNIT_ACTIVE[libvirtd.service]:-0}" -eq 0 ] ||
    fail 'the monolithic daemon fixture must remain idle for the socket test'

reset_units
select_provider modular
select_provider monolithic
[ "$(virtualization_detect_provider)" = mixed ] ||
    fail 'simultaneously selected modular and monolithic sockets must be mixed'
status=0
virtualization_provider_ready || status=$?
[ "$status" -eq 1 ] ||
    fail 'a mixed provider must be drift rather than a usable configuration'

reset_units
select_provider modular
VIRSH_LIST_STATUS=7
status=0
virtualization_provider_ready || status=$?
[ "$status" -eq 2 ] ||
    fail 'healthy sockets must not hide a failed qemu:///system function probe'

reset_units
select_provider modular
select_provider monolithic
UNIT_ENABLED[libvirtd.service]=1
UNIT_ACTIVE[libvirtd.service]=1
ensure_virtualization_provider
virtualization_provider_ready ||
    fail 'Fedora mixed state must converge to one complete provider'
[ "$(virtualization_detect_provider)" = modular ] ||
    fail 'Fedora mixed state must prefer the modular provider'
grep -Fqx 'disable:libvirtd.socket' "$CALLS" ||
    fail 'mixed convergence must disable the monolithic socket'
grep -Fqx 'disable:libvirtd.service' "$CALLS" ||
    fail 'mixed convergence must disable the monolithic service'
grep -Fqx 'stop:libvirtd.socket' "$CALLS" ||
    fail 'mixed convergence must stop the monolithic socket'
grep -Fqx 'stop:libvirtd.service' "$CALLS" ||
    fail 'mixed convergence must stop the monolithic service'
grep -Fqx 'enable:virtlockd.socket' "$CALLS" ||
    fail 'provider convergence must restore the shared lock socket'
grep -Fqx 'enable:virtlogd.socket' "$CALLS" ||
    fail 'provider convergence must restore the shared log socket'

reset_units
while IFS= read -r unit; do
    UNIT_AVAILABLE[$unit]=0
done < <(printf '%s\n' "${VIRTUALIZATION_MODULAR_REQUIRED_UNITS[@]}")
ensure_virtualization_provider
[ "$(virtualization_detect_provider)" = monolithic ] ||
    fail 'a legacy-only installation must fall back to monolithic libvirt'
virtualization_provider_ready ||
    fail 'the legacy monolithic fallback must pass strict function probes'
grep -Fqx 'enable:libvirtd.socket' "$CALLS" ||
    fail 'legacy fallback must enable the libvirtd socket'
grep -Fqx 'start:libvirtd.socket' "$CALLS" ||
    fail 'legacy fallback must start the libvirtd socket'

reset_units
select_provider modular
VIRTUALIZATION_PROVIDER=monolithic
ensure_virtualization_provider
[ "$(virtualization_detect_provider)" = monolithic ] ||
    fail 'an explicit monolithic policy must converge away from modular units'
virtualization_provider_ready ||
    fail 'the explicit monolithic policy must satisfy its strict contract'

printf 'PASS: exclusive modular and monolithic virtualization providers\n'
