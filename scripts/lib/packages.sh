#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Package desired-state primitives. This library is safe to source in read-only
# modes; filesystem and package-manager writes happen only inside mutators.

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

package_is_installed() {
    local package=$1
    pacman -Q "$package" >/dev/null 2>&1
}

flatpak_is_installed() {
    local app=$1
    flatpak info --system "$app" >/dev/null 2>&1
}

PACMAN_TRUST_RECOVERY_ATTEMPTED=${PACMAN_TRUST_RECOVERY_ATTEMPTED:-0}
PACMAN_TRUST_STAMP=${PACMAN_TRUST_STAMP:-/run/lock/shorin-pacman-trust-${SHORIN_RUN_TOKEN:-$$}}

pacman_log_has_trust_error() {
    local log_file=$1

    grep -Eqi '(signature from .* is (unknown|marginal) trust|required key missing from keyring)' \
        "$log_file"
}

recover_pacman_trust() {
    local recovery_state

    require_writable_mode || return

    if [ -f "$PACMAN_TRUST_STAMP" ]; then
        recovery_state=$(< "$PACMAN_TRUST_STAMP")
        [ "$recovery_state" = succeeded ]
        return
    fi
    if [ "$PACMAN_TRUST_RECOVERY_ATTEMPTED" -eq 1 ]; then
        printf 'ERROR: pacman trust recovery was already attempted in this module\n' >&2
        return 1
    fi
    PACMAN_TRUST_RECOVERY_ATTEMPTED=1
    install -D -m 600 /dev/null "$PACMAN_TRUST_STAMP"
    printf 'attempted\n' > "$PACMAN_TRUST_STAMP"

    printf 'WARNING: pacman signature trust failure detected; updating the official Arch keyring before one retry\n' >&2
    # Use the already synchronized database. Refreshing it here would require
    # an unrelated full system upgrade to avoid a partial-upgrade state.
    pacman -S --noconfirm --needed archlinux-keyring || return
    pacman-key --populate archlinux || return
    printf 'succeeded\n' > "$PACMAN_TRUST_STAMP"
}

run_with_pacman_trust_recovery() {
    local label=$1 log_file status=0
    shift

    log_file=$(mktemp)
    if "$@" >"$log_file" 2>&1; then
        cat "$log_file"
        rm -f "$log_file"
        return 0
    else
        status=$?
    fi
    cat "$log_file" >&2
    if ! pacman_log_has_trust_error "$log_file"; then
        rm -f "$log_file"
        return "$status"
    fi
    rm -f "$log_file"

    recover_pacman_trust || {
        printf 'ERROR: pacman trust recovery failed while installing %s\n' "$label" >&2
        return 1
    }
    "$@"
}

ensure_package() {
    require_writable_mode || return
    local package=$1

    package_is_installed "$package" ||
        run_with_pacman_trust_recovery "$package" \
            pacman -S --noconfirm --needed "$package"
    package_is_installed "$package"
}

ensure_packages() {
    require_writable_mode || return
    local package

    for package in "$@"; do
        ensure_package "$package"
    done
}

ensure_aur_package() {
    require_writable_mode || return
    local package=$1
    local user=${2:-${TARGET_USER:-}}
    local home=${3:-${HOME_DIR:-}}

    if [ -z "$user" ]; then
        printf 'ERROR: a target user is required for AUR package %s\n' \
            "$package" >&2
        return 1
    fi
    if [ -z "$home" ]; then
        home=$(getent passwd "$user" | cut -d: -f6)
    fi
    if [ -z "$home" ]; then
        printf 'ERROR: cannot resolve home directory for %s\n' "$user" >&2
        return 1
    fi

    package_is_installed "$package" ||
        run_with_pacman_trust_recovery "$package" \
            runuser -u "$user" -- env HOME="$home" \
                yay -S --noconfirm --needed \
                --answerdiff=None --answerclean=None "$package"
    package_is_installed "$package"
}

ensure_flatpak() {
    require_writable_mode || return
    local app=$1
    local remote=${2:-flathub}

    flatpak_is_installed "$app" ||
        flatpak install --system -y "$remote" "$app"
    flatpak_is_installed "$app"
}

pacman_section_matches() {
    local file=$1 section=$2 body=$3
    local actual expected

    [ -f "$file" ] || return 1
    actual=$(awk -v wanted="$section" '
        /^\[[^]]+\]$/ {
            current=$0
            gsub(/^\[|\]$/, "", current)
            capture=(current == wanted)
            next
        }
        capture && NF && $0 !~ /^[[:space:]]*#/ { print }
    ' "$file")
    expected=$(printf '%s\n' "$body" | awk 'NF && $0 !~ /^[[:space:]]*#/')
    [ "$actual" = "$expected" ]
}

ensure_pacman_section() {
    require_writable_mode || return
    local file=$1 section=$2 body=$3
    local tmp

    tmp=$(mktemp "${file}.XXXXXX")
    awk -v wanted="$section" '
        /^\[[^]]+\]$/ {
            current=$0
            gsub(/^\[|\]$/, "", current)
            skip=(current == wanted)
        }
        !skip { print }
    ' "$file" > "$tmp"
    printf '\n[%s]\n%s\n' "$section" "$body" >> "$tmp"
    if ! pacman-conf --config "$tmp" >/dev/null ||
        ! install_if_changed "$tmp" "$file" 644; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

# Compatibility query names used by existing modules.
verify_package() {
    package_is_installed "$1"
}

verify_flatpak() {
    flatpak_is_installed "$1"
}
