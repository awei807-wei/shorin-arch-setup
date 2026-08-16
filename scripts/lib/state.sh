#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

if [ "${SHORIN_STATE_LOADED:-0}" = 1 ]; then
    return 0 2>/dev/null || exit 0
fi
readonly SHORIN_STATE_LOADED=1

SHORIN_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SHORIN_LIB_DIR/core.sh"

# State predicates return 0 when satisfied, 1 for drift, and 2 when inspection
# is unavailable. They never mutate the inspected target.
state_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

state_package_present() {
    if platform_is_fedora; then
        state_command_exists rpm || return 2
        package_is_installed "$1"
        return
    fi
    state_command_exists pacman || return 2
    pacman -Q "$1" >/dev/null 2>&1
}

state_flatpak_present() {
    state_command_exists flatpak || return 2
    flatpak info --system "$1" >/dev/null 2>&1
}

state_service_enabled() {
    local status

    state_command_exists systemctl || return 2
    # A missing unit (systemctl exit 4) or a disabled one is drift, not an
    # inspection error: on a fresh install the unit is not present yet.
    systemctl is-enabled --quiet "$1" && return 0
    status=$?
    case "$status" in
        1|2|3|4|5|6|7|8|9|10) return 1 ;;
        *) return "$status" ;;
    esac
}

state_global_service_enabled() {
    local status

    state_command_exists systemctl || return 2
    systemctl --global is-enabled --quiet "$1" && return 0
    status=$?
    case "$status" in
        1|2|3|4|5|6|7|8|9|10) return 1 ;;
        *) return "$status" ;;
    esac
}

state_service_active() {
    local status

    state_command_exists systemctl || return 2
    systemctl is-active --quiet "$1" && return 0
    status=$?
    case "$status" in
        1|2|3|4|5|6|7|8|9|10) return 1 ;;
        *) return "$status" ;;
    esac
}

state_file_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

state_file_nonempty() {
    [ -s "$1" ]
}

state_file_matches() {
    local expected=$1 actual=$2
    state_command_exists cmp || return 2
    [ -f "$expected" ] && [ -f "$actual" ] && cmp -s "$expected" "$actual"
}

state_line_present() {
    local file=$1 line=$2
    [ -f "$file" ] || return 1
    grep -Fqx "$line" "$file"
}

state_user_exists() {
    getent passwd "$1" >/dev/null
}

state_user_in_group() {
    local user=$1 group=$2 groups

    # Keep id's producer out of a grep -q pipeline.  A user with many group
    # memberships can otherwise make pipefail report SIGPIPE/141 after grep
    # finds the requested group.
    groups=$(id -nG "$user" 2>/dev/null) || return $?
    grep -Fqx "$group" < <(tr ' ' '\n' <<< "$groups")
}

resolve_target_user() {
    local requested=${1:-${TARGET_USER:-}} passwd_entry
    local -a candidates=()

    if [ -z "$requested" ] && [ -n "${SUDO_USER:-}" ] &&
        [ "$SUDO_USER" != root ]; then
        requested=$SUDO_USER
    fi
    if [ -z "$requested" ]; then
        mapfile -t candidates < <(
            getent passwd | awk -F: \
                '$3 >= 1000 && $3 < 60000 && $1 != "nobody" { print $1 }'
        )
        [ "${#candidates[@]}" -eq 1 ] || return 1
        requested=${candidates[0]}
    fi

    passwd_entry=$(getent passwd "$requested") || return 1
    [ "$(id -u "$requested")" -ne 0 ] || return 1
    TARGET_USER=$requested
    TARGET_UID=$(printf '%s\n' "$passwd_entry" | cut -d: -f3)
    TARGET_GID=$(printf '%s\n' "$passwd_entry" | cut -d: -f4)
    HOME_DIR=$(printf '%s\n' "$passwd_entry" | cut -d: -f6)
    export TARGET_USER TARGET_UID TARGET_GID HOME_DIR
}

state_user_unit_enabled() {
    local user=$1 unit=$2 target=${3:-default.target} home unit_file link
    home=$(getent passwd "$user" | cut -d: -f6) || return 2
    [ -n "$home" ] || return 2
    unit_file="$home/.config/systemd/user/$unit"
    link="$home/.config/systemd/user/${target}.wants/$unit"
    [ -s "$unit_file" ] && [ -L "$link" ] &&
        [ "$(readlink "$link")" = "../$unit" ]
}

state_fstab_valid() {
    local file=${1:-/etc/fstab}
    state_command_exists findmnt || return 2
    findmnt --verify --tab-file "$file" >/dev/null 2>&1
}

state_fstab_entry() {
    local source=$1 target=$2 fstype=$3 options=$4
    local file=${5:-/etc/fstab}
    [ -r "$file" ] || return 2
    awk -v src="$source" -v dst="$target" -v type="$fstype" -v opts="$options" '
        $1 == src && $2 == dst && $3 == type && $4 == opts { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$file"
}

state_fstab_targets_unique() {
    local file=$1 targets target_list
    shift
    target_list=$(IFS=,; printf '%s' "$*")
    [ -r "$file" ] || return 2
    awk -v targets="$target_list" '
        BEGIN {
            count=split(targets, values, ",")
            for (i=1; i<=count; i++) wanted[values[i]]=1
        }
        /^[[:space:]]*#/ || NF == 0 { next }
        $2 in wanted { seen[$2]++ }
        END {
            for (target in wanted) if (seen[target] > 1) exit 1
        }
    ' "$file"
}

state_grub_config_valid() {
    local file=${1:-/boot/grub/grub.cfg}
    local checker=grub-script-check
    if platform_is_fedora && state_command_exists grub2-script-check; then
        checker=grub2-script-check
    fi
    state_command_exists "$checker" || return 2
    [ -s "$file" ] && "$checker" "$file" >/dev/null 2>&1
}

# Run read-only Git inspection in the checkout owner's user context.
state_git_command() {
    local directory=$1 user=${2:-} home=${3:-}
    local current_uid target_uid
    shift 3

    state_command_exists git || return 2
    if [ -z "$user" ]; then
        git -C "$directory" "$@"
        return
    fi
    state_command_exists id || return 2
    [ -n "$home" ] || return 2
    current_uid=$(id -u) || return 2
    target_uid=$(id -u "$user") || return 2
    if [ "$current_uid" -eq "$target_uid" ]; then
        env HOME="$home" git -C "$directory" "$@"
    elif [ "$current_uid" -eq 0 ]; then
        state_command_exists runuser || return 2
        runuser -u "$user" -- env HOME="$home" git -C "$directory" "$@"
    else
        return 2
    fi
}

state_git_checkout() {
    local directory=$1 remote=$2 branch=$3 expected_commit=${4:-}
    local user=${5:-} home=${6:-}
    local actual_remote actual_branch actual_commit status=0

    [ -d "$directory/.git" ] || return 1
    actual_remote=$(state_git_command "$directory" "$user" "$home" \
        remote get-url origin 2>/dev/null) || status=$?
    [ "$status" -eq 0 ] || return "$status"
    [ "$actual_remote" = "$remote" ] || return 1
    if [ -n "$expected_commit" ]; then
        actual_commit=$(state_git_command "$directory" "$user" "$home" \
            rev-parse HEAD 2>/dev/null) || status=$?
        [ "$status" -eq 0 ] || return "$status"
        [ "$actual_commit" = "$expected_commit" ]
    else
        actual_branch=$(state_git_command "$directory" "$user" "$home" \
            branch --show-current 2>/dev/null) || status=$?
        [ "$status" -eq 0 ] || return "$status"
        [ "$actual_branch" = "$branch" ]
    fi
}
