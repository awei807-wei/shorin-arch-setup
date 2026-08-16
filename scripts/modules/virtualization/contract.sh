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
VIRTUALIZATION_SERVICE=${VIRTUALIZATION_SERVICE:-libvirtd.service}
VIRTUALIZATION_DEFAULT_NETWORK_XML=${VIRTUALIZATION_DEFAULT_NETWORK_XML:-/usr/share/libvirt/networks/default.xml}

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
    output=$(LC_ALL=C "$VIRTUALIZATION_VIRSH_COMMAND" net-info default 2>&1) ||
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

ensure_virtualization_default_network() {
    local info status=0 start_status=0

    require_writable_mode || return

    info=$(virtualization_default_network_info) || status=$?
    case "$status" in
        0) ;;
        1)
            [ -f "$VIRTUALIZATION_DEFAULT_NETWORK_XML" ] ||
                die 'libvirt default network template is not available.'
            "$VIRTUALIZATION_VIRSH_COMMAND" net-define \
                "$VIRTUALIZATION_DEFAULT_NETWORK_XML" || return
            info=$(virtualization_default_network_info) || return
            ;;
        *) return "$status" ;;
    esac
    if ! virtualization_default_network_field_is_yes "$info" Active; then
        "$VIRTUALIZATION_VIRSH_COMMAND" net-start default || start_status=$?
        if [ "$start_status" -ne 0 ]; then
            info=$(virtualization_default_network_info) || return
            virtualization_default_network_field_is_yes "$info" Active ||
                return "$start_status"
        fi
        info=$(virtualization_default_network_info) || return
    fi
    if ! virtualization_default_network_field_is_yes "$info" Autostart; then
        "$VIRTUALIZATION_VIRSH_COMMAND" net-autostart default || return
    fi
    virtualization_default_network_ready
}

virtualization_gsettings_matches() {
    local user=$1 home=$2 key=$3 expected=$4 actual

    command -v gsettings >/dev/null 2>&1 || return 2
    command -v dbus-run-session >/dev/null 2>&1 || return 2
    actual=$(runuser -u "$user" -- env HOME="$home" \
        dbus-run-session -- gsettings get \
            org.virt-manager.virt-manager.connections "$key" 2>/dev/null) ||
        return 2
    [ "$actual" = "$expected" ]
}

ensure_virtualization_gsetting() {
    local user=$1 home=$2 key=$3 value=$4

    require_writable_mode || return
    virtualization_gsettings_matches "$user" "$home" "$key" "$value" &&
        return 0
    runuser -u "$user" -- env HOME="$home" dbus-run-session -- \
        gsettings set org.virt-manager.virt-manager.connections "$key" "$value"
    virtualization_gsettings_matches "$user" "$home" "$key" "$value"
}
