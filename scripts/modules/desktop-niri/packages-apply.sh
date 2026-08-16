#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/modules/desktop-niri/targets.sh"

select_desktop_packages() {
    local list_file=$1 manifest=$2 selected_lines line raw_package
    local -n selected=$3
    local -a defaults=()

    mapfile -t defaults < <(
        grep -vE '^\s*#|^\s*$' "$list_file" |
            sed 's/[[:space:]]*#.*//' | xargs -n1
    )
    if [ "${SHORIN_MODE:-install}" != install ]; then
        if [ -f "$manifest" ] && [ -r "$manifest" ]; then
            mapfile -t selected < "$manifest"
        else
            selected=("${defaults[@]}")
        fi
        return 0
    fi
    if [ ! -t 0 ] || ! command -v fzf >/dev/null 2>&1; then
        selected=("${defaults[@]}")
        return 0
    fi

    selected_lines=$(grep -vE '^\s*#|^\s*$' "$list_file" |
        sed -E 's/[[:space:]]+#/\t#/' |
        fzf --multi --layout=reverse --border --prompt='Search Pkg > ' \
            --delimiter=$'\t' --with-nth=1 --bind 'load:select-all' \
            --bind 'ctrl-a:select-all,ctrl-d:deselect-all' || true)
    selected=()
    while IFS= read -r line; do
        raw_package=$(printf '%s\n' "$line" | cut -f1 -d$'\t' | xargs)
        [ -z "$raw_package" ] || selected+=("$raw_package")
    done <<< "$selected_lines"
}

normalize_profile_packages() {
    local -n selected=$1
    local entry canonical
    local -a normalized=()

    platform_is_fedora || return 0
    for entry in "${selected[@]}"; do
        entry=$(printf '%s\n' "$entry" | sed 's/[[:space:]]*#.*//' | xargs)
        [ -n "$entry" ] || continue
        if canonical=$(niri_package_target_canonical "$entry"); then
            normalized+=("$canonical")
        fi
    done
    selected=("${normalized[@]}")
}

main() {
    local list_file="$SHORIN_ROOT/niri-applist.txt"
    local profile_dir=${SHORIN_PROFILE_DIR:-/etc/shorin-arch-setup}
    local manifest="$profile_dir/niri-packages.list"
    local entry manifest_tmp
    local -a packages=()

    [ -f "$list_file" ] || die "Package list not found: $list_file"
    command -v fzf >/dev/null 2>&1 || ensure_package fzf
    select_desktop_packages "$list_file" "$manifest" packages
    normalize_profile_packages packages
    mapfile -t packages < <(printf '%s\n' "${packages[@]}" | sed '/^$/d' | sort -u)

    if [ "${SHORIN_MODE:-install}" = install ] ||
        { platform_is_fedora && [ -f "$manifest" ]; }; then
        install -d -m 755 "$profile_dir"
        manifest_tmp=$(mktemp)
        printf '%s\n' "${packages[@]}" > "$manifest_tmp"
        install_if_changed "$manifest_tmp" "$manifest" 644
        rm -f "$manifest_tmp"
    fi

    mapfile -t packages < <(niri_all_package_targets "$manifest" "$list_file")
    local -a failed_targets=()
    for entry in "${packages[@]}"; do
        ensure_niri_package_target "$entry" || failed_targets+=("$entry")
    done
    if [ "${#failed_targets[@]}" -gt 0 ]; then
        error "Failed desktop package targets: ${failed_targets[*]}"
        return 1
    fi
}

main "$@"
