#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

readonly -a STORAGE_PACKAGES=(btrfs-progs snapper snap-pac btrfs-assistant less)
readonly -a STORAGE_FSTAB_UNIQUE_TARGETS=(
    / /home /boot /var/cache/pacman/pkg /var/log
)
readonly -a SNAPPER_TARGET_SETTINGS=(
    'ALLOW_GROUPS=wheel'
    'TIMELINE_CREATE=no'
    'TIMELINE_CLEANUP=yes'
    'NUMBER_LIMIT=20'
    'NUMBER_LIMIT_IMPORTANT=5'
    'TIMELINE_LIMIT_HOURLY=5'
    'TIMELINE_LIMIT_DAILY=7'
    'TIMELINE_LIMIT_WEEKLY=0'
    'TIMELINE_LIMIT_MONTHLY=0'
    'TIMELINE_LIMIT_YEARLY=0'
)
SNAPPER_CONFIG_DIR=${SNAPPER_CONFIG_DIR:-/etc/snapper/configs}

storage_run_snapshot_stamp() {
    printf '/run/lock/shorin-storage-snapshot-%s\n' "${SHORIN_RUN_TOKEN:-$$}"
}

storage_root_fstype() {
    findmnt -n -o FSTYPE / 2>/dev/null
}

storage_home_is_btrfs() {
    [ "$(findmnt -n -o FSTYPE --target /home 2>/dev/null)" = btrfs ] &&
        btrfs subvolume show /home >/dev/null 2>&1
}

snapper_config_matches() {
    local config=$1 setting key value file="$SNAPPER_CONFIG_DIR/$1"
    local expected_subvolume

    [ -r "$file" ] || return 1
    case "$config" in
        root) expected_subvolume=/ ;;
        home) expected_subvolume=/home ;;
        *) return 1 ;;
    esac
    snapshot_config_subvolume_matches "$config" "$expected_subvolume" || return
    for setting in "${SNAPPER_TARGET_SETTINGS[@]}"; do
        key=${setting%%=*}
        value=${setting#*=}
        key_value_matches "$file" "$key" "\"$value\"" || return 1
    done
}

snapper_snapshot_present() {
    local config=$1 description=$2
    snapper --csvout --no-headers -c "$config" \
        list --columns description 2>/dev/null |
        awk -v wanted="$description" '
            {
                gsub(/^[[:space:]"]+|[[:space:]"]+$/, "")
                if ($0 == wanted || index($0, wanted " [run:") == 1) found=1
            }
            END { exit(found ? 0 : 1) }
        '
}
