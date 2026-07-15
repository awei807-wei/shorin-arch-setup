#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/scripts/lib/core.sh"

TEST_DIR=$(mktemp -d)
cleanup() {
    find "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

assert_equal() {
    local expected=$1 actual=$2 message=$3
    if [ "$expected" != "$actual" ]; then
        printf 'FAIL: %s (expected=%s actual=%s)\n' \
            "$message" "$expected" "$actual" >&2
        return 1
    fi
}

test_atomic_text_convergence() {
    local file="$TEST_DIR/environment"
    printf 'EDITOR=vim\nEDITOR=nano\nKEEP=yes\n' > "$file"

    ensure_key_value "$file" EDITOR nvim
    ensure_key_value "$file" EDITOR nvim

    assert_equal 1 "$(grep -c '^EDITOR=nvim$' "$file")" \
        'key convergence must leave one target value'
    assert_equal 1 "$(grep -c '^KEEP=yes$' "$file")" \
        'key convergence must preserve unrelated values'

    ensure_line "$file" 'EXTRA=yes'
    ensure_line "$file" 'EXTRA=yes'
    assert_equal 1 "$(grep -c '^EXTRA=yes$' "$file")" \
        'line convergence must not append duplicates'
}

test_package_convergence() {
    PACMAN_INSTALLED=0
    PACMAN_INSTALLS=0
    pacman() {
        case "$1" in
            -Q) [ "$PACMAN_INSTALLED" -eq 1 ] ;;
            -S)
                PACMAN_INSTALLED=1
                PACMAN_INSTALLS=$((PACMAN_INSTALLS + 1))
                ;;
            *) return 1 ;;
        esac
    }

    ensure_package example
    ensure_package example
    assert_equal 1 "$PACMAN_INSTALLS" \
        'package convergence must install only once'
}

test_service_convergence() {
    SERVICE_ENABLED=0
    SERVICE_ACTIVE=0
    SERVICE_ENABLES=0
    SERVICE_STARTS=0
    systemctl() {
        case "$1" in
            is-enabled) [ "$SERVICE_ENABLED" -eq 1 ] ;;
            enable)
                SERVICE_ENABLED=1
                SERVICE_ENABLES=$((SERVICE_ENABLES + 1))
                ;;
            is-active) [ "$SERVICE_ACTIVE" -eq 1 ] ;;
            start)
                SERVICE_ACTIVE=1
                SERVICE_STARTS=$((SERVICE_STARTS + 1))
                ;;
            *) return 1 ;;
        esac
    }

    ensure_service_started example.service
    ensure_service_started example.service
    assert_equal 1 "$SERVICE_ENABLES" \
        'service convergence must enable only once'
    assert_equal 1 "$SERVICE_STARTS" \
        'service convergence must start only once'
}

test_fstab_unique_keys() {
    local fstab="$TEST_DIR/fstab"
    printf '%s\n' \
        '/dev/old-root / btrfs defaults 0 0' \
        '/dev/new-root /old btrfs defaults 0 0' \
        '/dev/efi /boot vfat defaults 0 0' > "$fstab"
    findmnt() {
        [ "$1" = --verify ]
    }

    FSTAB_FILE="$fstab" ensure_fstab_entry \
        /dev/new-root / btrfs 'rw,noatime' 0 0
    FSTAB_FILE="$fstab" ensure_fstab_entry \
        /dev/new-root / btrfs 'rw,noatime' 0 0

    assert_equal 1 "$(awk '$1 == "/dev/new-root" { count++ } END { print count + 0 }' "$fstab")" \
        'fstab convergence must leave one source record'
    assert_equal 1 "$(awk '$2 == "/" { count++ } END { print count + 0 }' "$fstab")" \
        'fstab convergence must leave one target record'
}

test_pacman_section_convergence() {
    local config="$TEST_DIR/pacman.conf"
    local body='Server = https://mirror.example/$arch'
    printf '[options]\nColor\n\n[custom]\nServer = old\n' > "$config"
    pacman-conf() {
        [ "$1" = --config ] && [ -s "$2" ]
    }

    ensure_pacman_section "$config" custom "$body"
    ensure_pacman_section "$config" custom "$body"

    pacman_section_matches "$config" custom "$body"
    assert_equal 1 "$(grep -c '^\[custom\]$' "$config")" \
        'pacman convergence must leave one named section'
}

test_script_contract() {
    local script
    while IFS= read -r script; do
        assert_equal '#!/usr/bin/env bash' "$(head -n 1 "$script")" \
            "$script must use the shared bash shebang"
        grep -Fqx 'set -Eeuo pipefail' "$script"
        grep -q 'printf "ERROR: %s:%s: %s\\n"' "$script"
        bash -n "$script"
    done < <(find "$ROOT_DIR" -type f -name '*.sh' -not -path '*/.git/*' | sort)
}

test_atomic_text_convergence
test_package_convergence
test_service_convergence
test_fstab_unique_keys
test_pacman_section_convergence
test_script_contract

printf 'PASS: idempotency and strict-mode contract\n'
