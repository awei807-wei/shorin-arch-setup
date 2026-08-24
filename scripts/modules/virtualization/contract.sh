#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

if platform_is_fedora; then
    # Fedora 43/44 split libvirt by daemon, hypervisor driver, client and
    # network configuration.  These are the official packages owning the
    # libvirtd service, virsh client, QEMU driver and default network XML;
    # keeping them in the shared contract makes check/apply/verify agree.
    readonly -a VIRTUALIZATION_PACKAGES=(
        qemu-full virt-manager swtpm dnsmasq dbus
        libvirt-daemon libvirt-daemon-kvm libvirt-client
        libvirt-daemon-config-network
    )
else
    readonly -a VIRTUALIZATION_PACKAGES=(
        qemu-full virt-manager swtpm dnsmasq dbus libvirt
    )
fi
readonly -a VIRTUALIZATION_GROUPS=(libvirt kvm input)
VIRTUALIZATION_VIRSH_COMMAND=${VIRTUALIZATION_VIRSH_COMMAND:-virsh}
readonly -a VIRTUALIZATION_COMMANDS=("$VIRTUALIZATION_VIRSH_COMMAND")
VIRTUALIZATION_DEFAULT_NETWORK_XML=${VIRTUALIZATION_DEFAULT_NETWORK_XML:-/usr/share/libvirt/networks/default.xml}
VIRTUALIZATION_URI=${VIRTUALIZATION_URI:-qemu:///system}
VIRTUALIZATION_PROVIDER=${VIRTUALIZATION_PROVIDER:-auto}
VIRTUALIZATION_MONOLITHIC_SERVICE=${VIRTUALIZATION_MONOLITHIC_SERVICE:-${VIRTUALIZATION_SERVICE:-libvirtd.service}}
VIRTUALIZATION_MONOLITHIC_SOCKET=${VIRTUALIZATION_MONOLITHIC_SOCKET:-libvirtd.socket}
# Retain the old variable as a compatibility alias for callers that inspect
# the contract, but do not use daemon liveness as desired state.  Both modern
# modular daemons and libvirtd may exit normally while their sockets remain
# ready to reactivate them.
VIRTUALIZATION_SERVICE=$VIRTUALIZATION_MONOLITHIC_SERVICE

readonly -a VIRTUALIZATION_COMMON_REQUIRED_UNITS=(
    virtlockd.socket virtlogd.socket
)
readonly -a VIRTUALIZATION_MONOLITHIC_REQUIRED_UNITS=(
    "$VIRTUALIZATION_MONOLITHIC_SOCKET"
)
readonly -a VIRTUALIZATION_MONOLITHIC_UNITS=(
    "$VIRTUALIZATION_MONOLITHIC_SOCKET"
    libvirtd-ro.socket libvirtd-admin.socket
    libvirtd-tcp.socket libvirtd-tls.socket
    "$VIRTUALIZATION_MONOLITHIC_SERVICE"
)
readonly -a VIRTUALIZATION_MODULAR_REQUIRED_UNITS=(
    virtqemud.socket virtproxyd.socket virtnetworkd.socket
    virtinterfaced.socket virtnodedevd.socket virtnwfilterd.socket
    virtsecretd.socket virtstoraged.socket
)
readonly -a VIRTUALIZATION_MODULAR_UNITS=(
    virtqemud.socket virtqemud-ro.socket virtqemud-admin.socket
    virtproxyd.socket virtproxyd-ro.socket virtproxyd-admin.socket
    virtproxyd-tcp.socket virtproxyd-tls.socket
    virtnetworkd.socket virtnetworkd-ro.socket virtnetworkd-admin.socket
    virtinterfaced.socket virtinterfaced-ro.socket virtinterfaced-admin.socket
    virtnodedevd.socket virtnodedevd-ro.socket virtnodedevd-admin.socket
    virtnwfilterd.socket virtnwfilterd-ro.socket virtnwfilterd-admin.socket
    virtsecretd.socket virtsecretd-ro.socket virtsecretd-admin.socket
    virtstoraged.socket virtstoraged-ro.socket virtstoraged-admin.socket
    virtqemud.service virtproxyd.service virtnetworkd.service
    virtinterfaced.service virtnodedevd.service virtnwfilterd.service
    virtsecretd.service virtstoraged.service
)

virtualization_virsh() {
    "$VIRTUALIZATION_VIRSH_COMMAND" -c "$VIRTUALIZATION_URI" "$@"
}

virtualization_unit_available() {
    local unit=$1 load_state status=0

    command -v systemctl >/dev/null 2>&1 || return 2
    load_state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null) ||
        status=$?
    if [ "$status" -ne 0 ]; then
        case "$status" in
            1|2|3|4|5|6|7|8|9|10) return 1 ;;
            *) return 2 ;;
        esac
    fi
    [ "$load_state" = loaded ]
}

virtualization_unit_explicitly_enabled() {
    local unit=$1 enabled_state status=0

    command -v systemctl >/dev/null 2>&1 || return 2
    enabled_state=$(systemctl is-enabled "$unit" 2>/dev/null) || status=$?
    case "$enabled_state" in
        enabled|enabled-runtime|linked|linked-runtime) return 0 ;;
        disabled|static|indirect|generated|transient|alias|masked|not-found|'')
            case "$status" in
                0|1|2|3|4|5|6|7|8|9|10) return 1 ;;
                *) return 2 ;;
            esac
            ;;
        *)
            [ "$status" -eq 0 ] && return 1
            return 2
            ;;
    esac
}

virtualization_unit_active() {
    local unit=$1 status=0

    command -v systemctl >/dev/null 2>&1 || return 2
    systemctl is-active --quiet "$unit" || status=$?
    case "$status" in
        0) return 0 ;;
        1|2|3|4|5|6|7|8|9|10) return 1 ;;
        *) return 2 ;;
    esac
}

virtualization_unit_selected() {
    local unit=$1 enabled_status=0 active_status=0

    virtualization_unit_explicitly_enabled "$unit" || enabled_status=$?
    virtualization_unit_active "$unit" || active_status=$?
    if [ "$enabled_status" -eq 0 ] || [ "$active_status" -eq 0 ]; then
        return 0
    fi
    if [ "$enabled_status" -eq 1 ] && [ "$active_status" -eq 1 ]; then
        return 1
    fi
    return 2
}

virtualization_provider_required_units() {
    printf '%s\n' "${VIRTUALIZATION_COMMON_REQUIRED_UNITS[@]}"
    case "$1" in
        modular) printf '%s\n' "${VIRTUALIZATION_MODULAR_REQUIRED_UNITS[@]}" ;;
        monolithic) printf '%s\n' "${VIRTUALIZATION_MONOLITHIC_REQUIRED_UNITS[@]}" ;;
        *) return 2 ;;
    esac
}

virtualization_provider_all_units() {
    case "$1" in
        modular) printf '%s\n' "${VIRTUALIZATION_MODULAR_UNITS[@]}" ;;
        monolithic) printf '%s\n' "${VIRTUALIZATION_MONOLITHIC_UNITS[@]}" ;;
        *) return 2 ;;
    esac
}

virtualization_provider_conflicting_units() {
    case "$1" in
        modular) virtualization_provider_all_units monolithic ;;
        monolithic) virtualization_provider_all_units modular ;;
        *) return 2 ;;
    esac
}

virtualization_provider_available() {
    local provider=$1 unit status=0

    while IFS= read -r unit; do
        virtualization_unit_available "$unit" || status=$?
        case "$status" in
            0) ;;
            1) return 1 ;;
            *) return 2 ;;
        esac
        status=0
    done < <(virtualization_provider_required_units "$provider")
}

virtualization_provider_has_evidence() {
    local provider=$1 unit status=0 inspection_status=0

    while IFS= read -r unit; do
        virtualization_unit_selected "$unit" || status=$?
        case "$status" in
            0) return 0 ;;
            1) ;;
            *) inspection_status=2 ;;
        esac
        status=0
    done < <(virtualization_provider_all_units "$provider")
    [ "$inspection_status" -eq 0 ] || return "$inspection_status"
    return 1
}

virtualization_detect_provider() {
    local modular_status=0 monolithic_status=0

    virtualization_provider_has_evidence modular || modular_status=$?
    virtualization_provider_has_evidence monolithic || monolithic_status=$?
    if [ "$modular_status" -gt 1 ] || [ "$monolithic_status" -gt 1 ]; then
        return 2
    fi
    if [ "$modular_status" -eq 0 ] && [ "$monolithic_status" -eq 0 ]; then
        printf '%s\n' mixed
    elif [ "$modular_status" -eq 0 ]; then
        printf '%s\n' modular
    elif [ "$monolithic_status" -eq 0 ]; then
        printf '%s\n' monolithic
    else
        printf '%s\n' none
    fi
}

virtualization_provider_required_units_ready() {
    local provider=$1 unit status=0

    while IFS= read -r unit; do
        virtualization_unit_available "$unit" || status=$?
        [ "$status" -eq 0 ] || return "$status"
        virtualization_unit_explicitly_enabled "$unit" || status=$?
        [ "$status" -eq 0 ] || return "$status"
        virtualization_unit_active "$unit" || status=$?
        [ "$status" -eq 0 ] || return "$status"
        status=0
    done < <(virtualization_provider_required_units "$provider")
}

virtualization_provider_conflicts_absent() {
    local provider=$1 unit status=0

    while IFS= read -r unit; do
        virtualization_unit_selected "$unit" || status=$?
        case "$status" in
            0) return 1 ;;
            1) ;;
            *) return 2 ;;
        esac
        status=0
    done < <(virtualization_provider_conflicting_units "$provider")
}

virtualization_provider_policy_matches() {
    case "$VIRTUALIZATION_PROVIDER" in
        auto) [ "$1" = modular ] || [ "$1" = monolithic ] ;;
        modular|monolithic) [ "$1" = "$VIRTUALIZATION_PROVIDER" ] ;;
        *) return 2 ;;
    esac
}

virtualization_resolve_provider() {
    local detected status=0 first second

    case "$VIRTUALIZATION_PROVIDER" in
        modular|monolithic)
            virtualization_provider_available "$VIRTUALIZATION_PROVIDER" || return
            printf '%s\n' "$VIRTUALIZATION_PROVIDER"
            return 0
            ;;
        auto) ;;
        *) return 2 ;;
    esac

    detected=$(virtualization_detect_provider) || status=$?
    [ "$status" -eq 0 ] || return "$status"
    case "$detected" in
        modular|monolithic)
            if virtualization_provider_available "$detected"; then
                printf '%s\n' "$detected"
                return 0
            fi
            ;;
    esac

    if platform_is_fedora; then
        first=modular
        second=monolithic
    else
        first=monolithic
        second=modular
    fi
    if virtualization_provider_available "$first"; then
        printf '%s\n' "$first"
    elif virtualization_provider_available "$second"; then
        printf '%s\n' "$second"
    else
        return 1
    fi
}

virtualization_system_connection_ready() {
    local actual status=0

    command -v "$VIRTUALIZATION_VIRSH_COMMAND" >/dev/null 2>&1 || return 2
    actual=$(LC_ALL=C virtualization_virsh uri 2>/dev/null) || status=$?
    [ "$status" -eq 0 ] || return 2
    [ "$actual" = "$VIRTUALIZATION_URI" ] || return 1
    LC_ALL=C virtualization_virsh list --all --name >/dev/null 2>&1 || return 2
}

virtualization_provider_ready() {
    local detected status=0

    detected=$(virtualization_detect_provider) || status=$?
    [ "$status" -eq 0 ] || return "$status"
    case "$detected" in
        modular|monolithic) ;;
        mixed|none) return 1 ;;
        *) return 2 ;;
    esac
    virtualization_provider_policy_matches "$detected" || return
    virtualization_provider_required_units_ready "$detected" || return
    virtualization_provider_conflicts_absent "$detected" || return
    virtualization_system_connection_ready
}

virtualization_disable_unit_if_enabled() {
    local unit=$1 status=0

    virtualization_unit_available "$unit" || status=$?
    case "$status" in
        0) ;;
        1) return 0 ;;
        *) return "$status" ;;
    esac
    status=0
    virtualization_unit_explicitly_enabled "$unit" || status=$?
    case "$status" in
        0) systemctl disable "$unit" ;;
        1) return 0 ;;
        *) return "$status" ;;
    esac
}

virtualization_stop_unit_if_active() {
    local unit=$1 status=0

    virtualization_unit_available "$unit" || status=$?
    case "$status" in
        0) ;;
        1) return 0 ;;
        *) return "$status" ;;
    esac
    status=0
    virtualization_unit_active "$unit" || status=$?
    case "$status" in
        0) systemctl stop "$unit" ;;
        1) return 0 ;;
        *) return "$status" ;;
    esac
}

virtualization_enable_start_unit() {
    local unit=$1 status=0

    virtualization_unit_available "$unit" || return
    virtualization_unit_explicitly_enabled "$unit" || status=$?
    case "$status" in
        0) ;;
        1) systemctl enable "$unit" || return ;;
        *) return "$status" ;;
    esac
    status=0
    virtualization_unit_active "$unit" || status=$?
    case "$status" in
        0) ;;
        1) systemctl start "$unit" || return ;;
        *) return "$status" ;;
    esac
    virtualization_unit_explicitly_enabled "$unit" &&
        virtualization_unit_active "$unit"
}

ensure_virtualization_provider() {
    local provider unit

    require_writable_mode || return
    provider=$(virtualization_resolve_provider) || return

    # Disable every conflicting activation path before stopping its daemon.
    # This prevents a still-listening socket from immediately reactivating the
    # provider while the selected provider is being brought online.
    while IFS= read -r unit; do
        virtualization_disable_unit_if_enabled "$unit" || return
    done < <(virtualization_provider_conflicting_units "$provider")
    while IFS= read -r unit; do
        virtualization_stop_unit_if_active "$unit" || return
    done < <(virtualization_provider_conflicting_units "$provider")
    while IFS= read -r unit; do
        virtualization_enable_start_unit "$unit" || return
    done < <(virtualization_provider_required_units "$provider")

    virtualization_provider_required_units_ready "$provider" || return
    virtualization_provider_conflicts_absent "$provider" || return
    virtualization_system_connection_ready
}

virtualization_default_network_ready() {
    local info status=0

    info=$(virtualization_default_network_info) || status=$?
    [ "$status" -eq 0 ] || return "$status"
    virtualization_default_network_field_is_yes "$info" Active || return
    virtualization_default_network_field_is_yes "$info" Autostart
}

virtualization_default_network_info() {
    local output status=0

    command -v "$VIRTUALIZATION_VIRSH_COMMAND" >/dev/null 2>&1 || return 1
    output=$(LC_ALL=C virtualization_virsh net-info default 2>&1) ||
        status=$?
    if [ "$status" -ne 0 ]; then
        if grep -Eqi 'network not found|no network with matching name' <<< "$output"; then
            return 1
        fi
        [ "$status" -gt 1 ] || status=2
        return "$status"
    fi
    printf '%s\n' "$output"
}

virtualization_default_network_field_is_yes() {
    local info=$1 field=$2

    awk -F: -v field="$field" '
        $1 == field {
            value=$2
            gsub(/[[:space:]]/, "", value)
            value=tolower(value)
            found=(value == "yes" || value == "true" || value == "1")
        }
        END { exit(found ? 0 : 1) }
    ' <<< "$info"
}

virtualization_run_user_dbus() {
    local user=$1 home=$2 uid runtime_dir
    shift 2

    command -v runuser >/dev/null 2>&1 || return 2
    uid=$(id -u "$user") || return 2
    runtime_dir="/run/user/$uid"
    if [ -S "$runtime_dir/bus" ]; then
        runuser -u "$user" -- env HOME="$home" \
            XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" "$@"
        return
    fi
    command -v dbus-run-session >/dev/null 2>&1 || return 2
    runuser -u "$user" -- env HOME="$home" \
        dbus-run-session -- "$@"
}

ensure_virtualization_default_network() {
    local info status=0 start_status=0

    require_writable_mode || return

    info=$(virtualization_default_network_info) || status=$?
    case "$status" in
        0) ;;
        1)
            [ -f "$VIRTUALIZATION_DEFAULT_NETWORK_XML" ] ||
                die 'libvirt default network template is not available.'
            virtualization_virsh net-define \
                "$VIRTUALIZATION_DEFAULT_NETWORK_XML" || return
            info=$(virtualization_default_network_info) || return
            ;;
        *) return "$status" ;;
    esac
    if ! virtualization_default_network_field_is_yes "$info" Active; then
        virtualization_virsh net-start default || start_status=$?
        if [ "$start_status" -ne 0 ]; then
            info=$(virtualization_default_network_info) || return
            virtualization_default_network_field_is_yes "$info" Active ||
                return "$start_status"
        fi
        info=$(virtualization_default_network_info) || return
    fi
    if ! virtualization_default_network_field_is_yes "$info" Autostart; then
        virtualization_virsh net-autostart default || return
    fi
    virtualization_default_network_ready
}

virtualization_gsettings_matches() {
    local user=$1 home=$2 key=$3 expected=$4 actual

    command -v gsettings >/dev/null 2>&1 || return 2
    actual=$(virtualization_run_user_dbus "$user" "$home" gsettings get \
            org.virt-manager.virt-manager.connections "$key" 2>/dev/null) ||
        return 2
    [ "$actual" = "$expected" ]
}

ensure_virtualization_gsetting() {
    local user=$1 home=$2 key=$3 value=$4

    require_writable_mode || return
    virtualization_gsettings_matches "$user" "$home" "$key" "$value" &&
        return 0
    virtualization_run_user_dbus "$user" "$home" gsettings set \
        org.virt-manager.virt-manager.connections "$key" "$value"
    virtualization_gsettings_matches "$user" "$home" "$key" "$value"
}
