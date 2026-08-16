#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

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

_update_git_checkout() {
    local user=$1 repository=$2 branch=$3 destination=$4 home=$5
    local expected_commit=$6 actual

    [ ! -L "$destination" ] &&
        [ "$(stat -c '%U' "$destination")" = "$user" ] || return 1
    actual=$(runuser -u "$user" -- git -C "$destination" remote get-url origin) ||
        return 1
    [ "${actual%/}" = "${repository%/}" ] || return 1
    [ -z "$(runuser -u "$user" -- git -C "$destination" status --porcelain)" ] ||
        return 1

    runuser -u "$user" -- env HOME="$home" \
        git -C "$destination" fetch origin "$branch"
    if [ -n "$expected_commit" ]; then
        runuser -u "$user" -- git -C "$destination" \
            cat-file -e "$expected_commit^{commit}"
        runuser -u "$user" -- git -C "$destination" \
            checkout --detach "$expected_commit"
    else
        if ! runuser -u "$user" -- env HOME="$home" \
            git -C "$destination" show-ref --verify --quiet \
            "refs/heads/$branch"; then
            runuser -u "$user" -- env HOME="$home" \
                git -C "$destination" checkout -b "$branch" "origin/$branch"
        else
            runuser -u "$user" -- env HOME="$home" \
                git -C "$destination" checkout "$branch"
        fi
        runuser -u "$user" -- env HOME="$home" \
            git -C "$destination" merge --ff-only "origin/$branch"
    fi
}

# Converges a user-owned checkout without changing an existing parent directory.
ensure_git_checkout() {
    require_writable_mode || return
    local user=$1 repository=$2 branch=$3 destination=$4
    local home=${5:-${HOME_DIR:-}} expected_commit=${6:-}
    local parent staged

    [ -n "$home" ] || home=$(getent passwd "$user" | cut -d: -f6)
    [ -n "$home" ] || return 1
    if [ -d "$destination/.git" ]; then
        _update_git_checkout "$user" "$repository" "$branch" \
            "$destination" "$home" "$expected_commit" || {
            printf 'ERROR: refusing an untrusted or modified checkout: %s\n' \
                "$destination" >&2
            return 1
        }
        return 0
    fi
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        printf 'ERROR: refusing to replace an existing checkout path: %s\n' \
            "$destination" >&2
        return 1
    fi

    parent=$(dirname "$destination")
    [ -d "$parent" ] || install -d -o "$user" -g "$(id -gn "$user")" "$parent"
    runuser -u "$user" -- test -w "$parent" || return 1
    staged=$(mktemp -d "$parent/.checkout.XXXXXX")
    rmdir "$staged"
    if ! runuser -u "$user" -- env HOME="$home" \
        git clone --branch "$branch" --single-branch "$repository" "$staged"; then
        [ ! -e "$staged" ] || find "$staged" -depth -delete
        return 1
    fi
    if [ -n "$expected_commit" ] &&
        ! runuser -u "$user" -- git -C "$staged" \
            checkout --detach "$expected_commit"; then
        find "$staged" -depth -delete
        return 1
    fi
    mv "$staged" "$destination"
}
