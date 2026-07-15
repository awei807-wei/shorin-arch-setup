#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Atomic file and managed-checkout desired-state primitives.

if ! declare -F require_writable_mode >/dev/null 2>&1; then
    require_writable_mode() {
        local mode=${SHORIN_MODE:-${MODE:-install}}
        case "$mode" in
            audit|verify)
                printf 'ERROR: write operation is not allowed in %s mode\n' "$mode" >&2
                return 1
                ;;
        esac
    }
fi

file_has_line() {
    local file=$1 line=$2
    [ -f "$file" ] && grep -Fqx "$line" "$file"
}

file_matches() {
    local source=$1 destination=$2
    [ -f "$destination" ] && cmp -s "$source" "$destination"
}

file_is_nonempty() {
    [ -s "$1" ]
}

ensure_line() {
    require_writable_mode || return
    local file=$1 line=$2

    mkdir -p "$(dirname "$file")"
    touch "$file"
    file_has_line "$file" "$line" || printf '%s\n' "$line" >> "$file"
}

install_if_changed() {
    require_writable_mode || return
    local source=$1 destination=$2 mode=$3
    local staged="${destination}.new"

    if file_matches "$source" "$destination"; then
        return 0
    fi
    if ! install -D -m "$mode" "$source" "$staged"; then
        rm -f "$staged"
        return 1
    fi
    if ! mv -f "$staged" "$destination"; then
        rm -f "$staged"
        return 1
    fi
}

install_user_file_once() {
    require_writable_mode || return
    local source=$1 destination=$2 mode=$3 user=$4
    local group=${5:-$user}

    if [ -e "$destination" ] || [ -L "$destination" ]; then
        return 0
    fi
    install -D -m "$mode" -o "$user" -g "$group" "$source" "$destination"
}

deploy_user_tree_once() {
    require_writable_mode || return
    local source_root=$1 destination_root=$2 user=$3
    local group=${4:-$user}
    local source relative destination mode

    while IFS= read -r -d '' source; do
        relative=${source#"$source_root"/}
        destination="$destination_root/$relative"
        if [ -d "$source" ]; then
            install -d -o "$user" -g "$group" "$destination"
        elif [ -L "$source" ]; then
            if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
                install -d -o "$user" -g "$group" "$(dirname "$destination")"
                runuser -u "$user" -- ln -s "$(readlink "$source")" "$destination"
            fi
        elif [ -f "$source" ]; then
            mode=$(stat -c '%a' "$source")
            install_user_file_once "$source" "$destination" "$mode" "$user" "$group"
        fi
    done < <(find "$source_root" -mindepth 1 -print0)
}

git_checkout_matches() {
    local user=$1 repository=$2 branch=$3 destination=$4
    local actual branch_name

    [ -d "$destination/.git" ] || return 1
    actual=$(runuser -u "$user" -- git -C "$destination" remote get-url origin) ||
        return 1
    branch_name=$(runuser -u "$user" -- git -C "$destination" branch --show-current) ||
        return 1
    [ "${actual%/}" = "${repository%/}" ] && [ "$branch_name" = "$branch" ]
}

ensure_git_checkout() {
    require_writable_mode || return
    local user=$1 repository=$2 branch=$3 destination=$4
    local home=${5:-${HOME_DIR:-}}
    local actual parent staged

    if [ -z "$home" ]; then
        home=$(getent passwd "$user" | cut -d: -f6)
    fi
    [ -n "$home" ] || return 1

    if [ -d "$destination/.git" ]; then
        actual=$(runuser -u "$user" -- git -C "$destination" remote get-url origin)
        if [ "${actual%/}" != "${repository%/}" ]; then
            printf 'ERROR: refusing to update %s: origin is %s\n' \
                "$destination" "$actual" >&2
            return 1
        fi
        runuser -u "$user" -- env HOME="$home" \
            git -C "$destination" fetch origin "$branch"
        runuser -u "$user" -- env HOME="$home" \
            git -C "$destination" checkout "$branch"
        runuser -u "$user" -- env HOME="$home" \
            git -C "$destination" merge --ff-only "origin/$branch"
        return 0
    fi

    parent=$(dirname "$destination")
    install -d -o "$user" -g "$user" "$parent"
    staged=$(mktemp -d "$parent/.checkout.XXXXXX")
    rmdir "$staged"
    if ! runuser -u "$user" -- env HOME="$home" \
        git clone --branch "$branch" --single-branch "$repository" "$staged"; then
        [ ! -e "$staged" ] || find "$staged" -depth -delete
        return 1
    fi
    mv "$staged" "$destination"
}

key_value_matches() {
    local file=$1 key=$2 value=$3
    local count

    [ -f "$file" ] || return 1
    count=$(awk -v key="$key" -v value="$value" '
        $0 == key "=" value { matches++ }
        $0 ~ "^[[:space:]#]*" key "[[:space:]]*=" { total++ }
        END { print matches ":" total }
    ' "$file")
    [ "$count" = '1:1' ]
}

ensure_key_value() {
    require_writable_mode || return
    local file=$1 key=$2 value=$3
    local mode=${4:-644}
    local tmp parent

    parent=$(dirname "$file")
    install -d "$parent"
    tmp=$(mktemp "$parent/.managed.XXXXXX")
    if [ -f "$file" ]; then
        awk -v key="$key" '
            $0 !~ "^[[:space:]#]*" key "[[:space:]]*=" { print }
        ' "$file" > "$tmp"
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    if ! install_if_changed "$tmp" "$file" "$mode"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

install_sudoers_file() {
    require_writable_mode || return
    local source=$1 destination=$2

    visudo -cf "$source" >/dev/null
    install_if_changed "$source" "$destination" 440
    visudo -cf "$destination" >/dev/null
}

fstab_entry_matches() {
    local source=$1 target=$2 fstype=$3 options=$4
    local dump=${5:-0} pass=${6:-0}
    local fstab_file=${7:-${FSTAB_FILE:-/etc/fstab}}

    awk -v src="$source" -v dst="$target" -v type="$fstype" \
        -v opts="$options" -v dump="$dump" -v pass="$pass" '
        /^[[:space:]]*#/ || NF == 0 { next }
        $1 == src || $2 == dst {
            total++
            if ($1 == src && $2 == dst && $3 == type && $4 == opts &&
                $5 == dump && $6 == pass) matches++
        }
        END { exit !(total == 1 && matches == 1) }
    ' "$fstab_file"
}

ensure_fstab_entry() {
    require_writable_mode || return
    local source=$1 target=$2 fstype=$3 options=$4
    local dump=${5:-0} pass=${6:-0}
    local fstab_file=${7:-${FSTAB_FILE:-/etc/fstab}}
    local tmp

    tmp=$(mktemp "${fstab_file}.XXXXXX")
    awk -v src="$source" -v dst="$target" '
        /^[[:space:]]*#/ || NF == 0 { print; next }
        $1 != src && $2 != dst { print }
    ' "$fstab_file" > "$tmp"
    printf '%s %s %s %s %s %s\n' \
        "$source" "$target" "$fstype" "$options" "$dump" "$pass" >> "$tmp"
    if ! findmnt --verify --tab-file "$tmp" ||
        ! install_if_changed "$tmp" "$fstab_file" 644; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

ensure_fstab_targets_unique() {
    require_writable_mode || return
    local fstab_file=$1 target_list tmp
    shift

    state_fstab_targets_unique "$fstab_file" "$@" && return 0
    target_list=$(IFS=,; printf '%s' "$*")
    tmp=$(mktemp "${fstab_file}.XXXXXX")
    awk -v targets="$target_list" '
        BEGIN {
            count=split(targets, values, ",")
            for (i=1; i<=count; i++) wanted[values[i]]=1
        }
        {
            lines[NR]=$0
            if ($0 !~ /^[[:space:]]*#/ && NF > 0 && $2 in wanted) {
                target_at[NR]=$2
                last[$2]=NR
            }
        }
        END {
            for (i=1; i<=NR; i++) {
                target=target_at[i]
                if (target == "" || i == last[target]) print lines[i]
            }
        }
    ' "$fstab_file" > "$tmp"
    if ! findmnt --verify --tab-file "$tmp" ||
        ! install_if_changed "$tmp" "$fstab_file" 644; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    state_fstab_targets_unique "$fstab_file" "$@"
}

# Compatibility query name used by existing modules.
verify_file() {
    file_is_nonempty "$1"
}
