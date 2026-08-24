#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

grub_contract_init() {
    GRUB_DEFAULT_FILE=${GRUB_DEFAULT_FILE:-/etc/default/grub}
    if platform_is_fedora; then
        # Fedora 34+ uses one generated configuration for both BIOS and UEFI.
        # The EFI-side grub.cfg is a small vendor stub that chains to this
        # file; generating directly into the stub can make the system
        # unbootable.
        GRUB_CONFIG_FILE=${GRUB_CONFIG_FILE:-/boot/grub2/grub.cfg}
        GRUB_CUSTOM_FILE=${GRUB_CUSTOM_FILE:-/etc/grub.d/99_custom}
        GRUB_MKINITCPIO_FILE=${GRUB_MKINITCPIO_FILE:-/etc/default/grub}
    else
        GRUB_CONFIG_FILE=${GRUB_CONFIG_FILE:-/boot/grub/grub.cfg}
        GRUB_CUSTOM_FILE=${GRUB_CUSTOM_FILE:-/etc/grub.d/99_custom}
        GRUB_MKINITCPIO_FILE=${GRUB_MKINITCPIO_FILE:-/etc/mkinitcpio.conf}
    fi
    GRUB_THEME_SOURCE_ROOT=${GRUB_THEME_SOURCE_ROOT:-$SHORIN_ROOT/grub-themes}
    GRUB_THEME_DEST_ROOT=${GRUB_THEME_DEST_ROOT:-/boot/grub/themes}
}

grub_config_generator() {
    if platform_is_fedora && command -v grub2-mkconfig >/dev/null 2>&1; then
        command -v grub2-mkconfig
    else
        command -v grub-mkconfig
    fi
}

grub_config_checker() {
    if platform_is_fedora && command -v grub2-script-check >/dev/null 2>&1; then
        command -v grub2-script-check
    else
        command -v grub-script-check
    fi
}

grub_installation_state() {
    grub_config_generator >/dev/null 2>&1 || return 1
    [ -f "$GRUB_DEFAULT_FILE" ] || return 2
}

grub_root_is_btrfs() {
    local fstype=${GRUB_ROOT_FSTYPE:-}

    if [ -z "$fstype" ]; then
        command -v findmnt >/dev/null 2>&1 || return 2
        fstype=$(findmnt -n -o FSTYPE / 2>/dev/null) || return 2
    fi
    [ "$fstype" = btrfs ]
}

grub_custom_contract() {
    cat <<'EOF'
#!/bin/sh
exec tail -n +3 $0
menuentry "Reboot" { reboot }
menuentry "Shutdown" { halt }
EOF
}

grub_custom_matches() {
    local actual expected

    [ -x "$GRUB_CUSTOM_FILE" ] || return 1
    actual=$(< "$GRUB_CUSTOM_FILE")
    expected=$(grub_custom_contract)
    [ "$actual" = "$expected" ]
}

grub_key_matches() {
    key_value_matches "$GRUB_DEFAULT_FILE" "$1" "$2"
}

grub_cmdline_value() {
    awk -F= '
        /^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT[[:space:]]*=/ {
            value=substr($0, index($0, "=") + 1)
        }
        END {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (value ~ /^".*"$/) value=substr(value, 2, length(value) - 2)
            print value
        }
    ' "$GRUB_DEFAULT_FILE"
}

grub_kernel_param_present() {
    local wanted=$1 token

    for token in $(grub_cmdline_value); do
        if [[ "$wanted" == *=* ]]; then
            [ "$token" = "$wanted" ] && return 0
        else
            [ "${token%%=*}" = "$wanted" ] && return 0
        fi
    done
    return 1
}

grub_kernel_param_absent() {
    ! grub_kernel_param_present "$1"
}

grub_watchdog_param_matches() {
    local vendor

    vendor=$(LC_ALL=C lscpu | awk -F: '/Vendor ID/ {
        gsub(/^[[:space:]]+/, "", $2); print $2; exit
    }')
    case "$vendor" in
        GenuineIntel) grub_kernel_param_present modprobe.blacklist=iTCO_wdt ;;
        AuthenticAMD) grub_kernel_param_present modprobe.blacklist=sp5100_tco ;;
        *) return 0 ;;
    esac
}

grub_theme_is_available() {
    find "$GRUB_THEME_SOURCE_ROOT" -mindepth 2 -maxdepth 2 \
        -type f -name theme.txt -print -quit 2>/dev/null | grep -q .
}

grub_theme_hash() {
    local directory=$1

    [ -d "$directory" ] || return 1
    (
        cd "$directory"
        find . -type f -print0 | sort -z | xargs -0 sha256sum
        find . -type l -print0 | sort -z |
            while IFS= read -r -d '' link; do
                printf '%s  %s\n' "$(readlink "$link")" "$link"
            done
    ) | sha256sum | cut -c1-12
}

grub_current_theme_path() {
    awk -F= '$1 == "GRUB_THEME" {
        value=substr($0, index($0, "=") + 1)
        gsub(/^"|"$/, "", value)
    } END { print value }' "$GRUB_DEFAULT_FILE"
}

grub_theme_target_matches() {
    local current directory install_name source expected

    current=$(grub_current_theme_path)
    [ -f "$current" ] || return 1
    directory=$(dirname "$current")
    install_name=$(basename "$directory")
    while IFS= read -r source; do
        [ -f "$source/theme.txt" ] || continue
        expected="$(basename "$source")-$(grub_theme_hash "$source")"
        if [ "$install_name" = "$expected" ] &&
            [ "$current" = "$GRUB_THEME_DEST_ROOT/$expected/theme.txt" ] &&
            [ "$(grub_theme_hash "$directory")" = "$(grub_theme_hash "$source")" ]; then
            return 0
        fi
    done < <(find "$GRUB_THEME_SOURCE_ROOT" -mindepth 1 -maxdepth 1 \
        -type d | sort)
    return 1
}

grub_overlay_hook_present() {
    [ -r "$GRUB_MKINITCPIO_FILE" ] &&
        grep -Fqw grub-btrfs-overlayfs "$GRUB_MKINITCPIO_FILE"
}

grub_windows_detected() {
    if [ -n "${GRUB_WINDOWS_DETECTED:-}" ]; then
        [ "$GRUB_WINDOWS_DETECTED" = 1 ]
        return
    fi
    command -v os-prober >/dev/null 2>&1 || return 1
    os-prober 2>/dev/null | grep -qi windows
}
