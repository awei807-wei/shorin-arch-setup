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
    command -v "$VIRTUALIZATION_VIRSH_COMMAND" >/dev/null 2>&1 || return 1
    LC_ALL=C "$VIRTUALIZATION_VIRSH_COMMAND" net-info default 2>/dev/null | awk -F: '
        /^Active:/ { gsub(/[[:space:]]/, "", $2); active=($2 == "yes") }
        /^Autostart:/ { gsub(/[[:space:]]/, "", $2); autostart=($2 == "yes") }
        END { exit(active && autostart ? 0 : 1) }
    '
}

ensure_virtualization_default_network() {
    require_writable_mode || return

    if ! LC_ALL=C "$VIRTUALIZATION_VIRSH_COMMAND" net-info default >/dev/null 2>&1; then
        [ -f "$VIRTUALIZATION_DEFAULT_NETWORK_XML" ] ||
            die 'libvirt default network template is not available.'
        "$VIRTUALIZATION_VIRSH_COMMAND" net-define "$VIRTUALIZATION_DEFAULT_NETWORK_XML"
    fi
    LC_ALL=C "$VIRTUALIZATION_VIRSH_COMMAND" net-info default | grep -q '^Active:.*yes' ||
        "$VIRTUALIZATION_VIRSH_COMMAND" net-start default
    LC_ALL=C "$VIRTUALIZATION_VIRSH_COMMAND" net-info default | grep -q '^Autostart:.*yes' ||
        "$VIRTUALIZATION_VIRSH_COMMAND" net-autostart default
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
