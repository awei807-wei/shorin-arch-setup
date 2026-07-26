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

test_file_metadata_convergence() {
    local source="$TEST_DIR/mode-source" destination="$TEST_DIR/mode-destination"

    printf 'same content\n' > "$source"
    cp "$source" "$destination"
    chmod 600 "$destination"
    install_if_changed "$source" "$destination" 644
    assert_equal 644 "$(stat -c '%a' "$destination")" \
        'content convergence must also repair the requested file mode'
}

test_checkout_preserves_shared_parent_mode() {
    local repository="$TEST_DIR/source-repository"
    local shared_parent="$TEST_DIR/shared-tmp"
    local checkout="$shared_parent/checkout"
    local current_user expected_commit

    current_user=$(id -un)
    mkdir -p "$repository" "$shared_parent"
    chmod 1777 "$shared_parent"
    git init -q -b main "$repository"
    printf 'fixture\n' > "$repository/file.txt"
    git -C "$repository" add file.txt
    git -C "$repository" -c user.name=Fixture \
        -c user.email=fixture@example.invalid commit -q -m fixture
    expected_commit=$(git -C "$repository" rev-parse HEAD)

    runuser() {
        [ "$1" = -u ] || return 1
        shift 2
        [ "$1" = -- ] || return 1
        shift
        "$@"
    }

    HOME_DIR=$HOME ensure_git_checkout \
        "$current_user" "$repository" main "$checkout" "$HOME" \
        "$expected_commit"
    assert_equal 1777 "$(stat -c '%a' "$shared_parent")" \
        'checkout creation must not rewrite an existing shared parent mode'
    [ -f "$checkout/file.txt" ] || {
        printf 'FAIL: checkout fixture was not cloned\n' >&2
        return 1
    }
    [ "$(git -C "$checkout" rev-parse HEAD)" = "$expected_commit" ] || {
        printf 'FAIL: checkout did not use the pinned commit\n' >&2
        return 1
    }
    mkdir -p "$shared_parent/preexisting"
    printf 'untrusted\n' > "$shared_parent/preexisting/sentinel"
    if HOME_DIR=$HOME ensure_git_checkout "$current_user" "$repository" main \
        "$shared_parent/preexisting" "$HOME" "$expected_commit" 2>/dev/null; then
        printf 'FAIL: a preexisting non-Git checkout path was accepted\n' >&2
        return 1
    fi
    [ "$(< "$shared_parent/preexisting/sentinel")" = untrusted ] || {
        printf 'FAIL: a refused checkout path was modified\n' >&2
        return 1
    }
    unset -f runuser
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

test_aur_source_routing() (
    local installed=0 runuser_called=0 aur_command=""
    PACKAGE_SOURCE_DIR="$TEST_DIR/package-sources"

    pacman() {
        case "$1" in
            -Si) [ "$2" = extra/official-example ] ;;
            -Q) [ "$installed" -eq 1 ] && printf 'official-example 1.0\n' ;;
            -S)
                [ "${*: -1}" = extra/official-example ] || return 1
                installed=1
                ;;
            *) return 1 ;;
        esac
    }
    runuser() { runuser_called=1; return 1; }
    ensure_aur_package official-example tester "$TEST_DIR/home"
    assert_equal 1 "$installed" \
        'an AUR declaration must prefer an available official package'
    assert_equal 0 "$runuser_called" \
        'official package routing must not invoke an AUR helper'

    installed=0
    pacman() {
        case "$1" in
            -Si) return 1 ;;
            -Q) [ "$installed" -eq 1 ] && printf 'aur-example 2.0\n' ;;
            *) return 1 ;;
        esac
    }
    runuser() {
        runuser_called=1
        aur_command="$*"
        installed=1
    }
    ensure_aur_package aur-example tester "$TEST_DIR/home"
    [[ " $aur_command " == *' yay -S --aur --rebuild aur-example '* ]] || {
        printf 'FAIL: a real AUR target must force yay --aur (command=%s)\n' \
            "$aur_command" >&2
        return 1
    }
)

test_package_trust_recovery() {
    local package_log="$TEST_DIR/package-trust.log"
    PACMAN_INSTALLED=0
    PACMAN_INSTALLS=0
    PACMAN_RECOVERIES=0
    PACMAN_TRUST_RECOVERY_ATTEMPTED=0
    PACMAN_TRUST_STAMP="$TEST_DIR/pacman-trust-recovered"
    pacman() {
        case "$1" in
            -Q) [ "$PACMAN_INSTALLED" -eq 1 ] ;;
            -S)
                if [ "${*: -1}" = archlinux-keyring ]; then
                    PACMAN_RECOVERIES=$((PACMAN_RECOVERIES + 1))
                    return 0
                fi
                PACMAN_INSTALLS=$((PACMAN_INSTALLS + 1))
                if [ "$PACMAN_INSTALLS" -eq 1 ]; then
                    printf '%s\n' \
                        'error: dependency: signature from "Packager" is unknown trust' >&2
                    return 1
                fi
                PACMAN_INSTALLED=1
                ;;
            *) return 1 ;;
        esac
    }
    pacman-key() {
        [ "$1" = --populate ] && [ "$2" = archlinux ] || return 1
        PACMAN_RECOVERIES=$((PACMAN_RECOVERIES + 1))
    }

    ensure_package signed-example >"$package_log" 2>&1
    assert_equal 2 "$PACMAN_INSTALLS" \
        'signature failure must retry the original package once'
    assert_equal 2 "$PACMAN_RECOVERIES" \
        'signature recovery must update and populate the official keyring'
    assert_equal 1 "$PACMAN_TRUST_RECOVERY_ATTEMPTED" \
        'signature recovery must be bounded to one attempt'
    assert_equal succeeded "$(< "$PACMAN_TRUST_STAMP")" \
        'successful trust recovery must be shared across module processes'
}

test_failed_package_trust_recovery_is_not_retried() {
    PACMAN_TRUST_RECOVERY_ATTEMPTED=0
    PACMAN_TRUST_STAMP="$TEST_DIR/pacman-trust-failed"
    PACMAN_RECOVERIES=0
    pacman() {
        case "$1" in
            -Q) return 1 ;;
            -S)
                if [ "${*: -1}" = archlinux-keyring ]; then
                    PACMAN_RECOVERIES=$((PACMAN_RECOVERIES + 1))
                    return 1
                fi
                printf '%s\n' \
                    'error: dependency: signature from "Packager" is unknown trust' >&2
                return 1
                ;;
            *) return 1 ;;
        esac
    }

    ensure_package signed-example >/dev/null 2>&1 || true
    PACMAN_TRUST_RECOVERY_ATTEMPTED=0
    ensure_package another-signed-example >/dev/null 2>&1 || true
    assert_equal 1 "$PACMAN_RECOVERIES" \
        'failed trust recovery must not repeat later in the same installer run'
    assert_equal attempted "$(< "$PACMAN_TRUST_STAMP")" \
        'failed recovery must retain a shared attempted marker'
}

test_package_non_trust_failure_does_not_recover() {
    PACMAN_TRUST_RECOVERY_ATTEMPTED=0
    PACMAN_RECOVERIES=0
    PACMAN_TRUST_STAMP="$TEST_DIR/non-trust-recovery"
    pacman() {
        case "$1" in
            -Q) return 1 ;;
            -S) printf 'error: target not found\n' >&2; return 1 ;;
            *) return 1 ;;
        esac
    }

    if ensure_package missing-example >/dev/null 2>&1; then
        printf 'FAIL: non-signature package failure must propagate\n' >&2
        return 1
    fi
    assert_equal 0 "$PACMAN_RECOVERIES" \
        'non-signature failure must not trigger trust recovery'
}

test_corrupt_signature_without_trust_error_does_not_recover() {
    PACMAN_TRUST_RECOVERY_ATTEMPTED=0
    PACMAN_RECOVERIES=0
    PACMAN_TRUST_STAMP="$TEST_DIR/corrupt-signature-recovery"
    pacman() {
        case "$1" in
            -Q) return 1 ;;
            -S)
                printf '%s\n' \
                    'error: invalid or corrupted package (PGP signature)' >&2
                return 1
                ;;
            *) return 1 ;;
        esac
    }

    if ensure_package corrupt-example >/dev/null 2>&1; then
        printf 'FAIL: corrupted package failure must propagate\n' >&2
        return 1
    fi
    assert_equal 0 "$PACMAN_TRUST_RECOVERY_ATTEMPTED" \
        'cache corruption alone must not consume the keyring recovery attempt'
}

test_package_retry_failure_propagates() {
    PACMAN_INSTALLED=0
    PACMAN_INSTALLS=0
    PACMAN_TRUST_RECOVERY_ATTEMPTED=0
    PACMAN_TRUST_STAMP="$TEST_DIR/retry-failure-recovery"
    pacman() {
        case "$1" in
            -Q) return 1 ;;
            -S)
                if [ "${*: -1}" = archlinux-keyring ]; then
                    return 0
                fi
                PACMAN_INSTALLS=$((PACMAN_INSTALLS + 1))
                if [ "$PACMAN_INSTALLS" -eq 1 ]; then
                    printf '%s\n' \
                        'error: signature from "Packager" is unknown trust' >&2
                else
                    printf '%s\n' 'error: dependency conflict' >&2
                fi
                return 1
                ;;
            *) return 1 ;;
        esac
    }
    pacman-key() { return 0; }

    if ensure_package signed-example >/dev/null 2>&1; then
        printf 'FAIL: a failed post-recovery retry must propagate\n' >&2
        return 1
    fi
    assert_equal 2 "$PACMAN_INSTALLS" \
        'trust recovery must retry the original package exactly once'
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

test_fstab_target_deduplication_preserves_btrfs_subvolumes() {
    local fstab="$TEST_DIR/fstab-duplicates"
    printf '%s\n' \
        'UUID=root / btrfs subvol=/@ 0 1' \
        'UUID=root /home btrfs subvol=/@home 0 0' \
        'UUID=old /boot vfat defaults 0 2' \
        'UUID=root / btrfs subvol=/@ 0 1' \
        'UUID=new /boot vfat defaults 0 2' > "$fstab"
    findmnt() { [ "$1" = --verify ]; }

    ensure_fstab_targets_unique "$fstab" / /home /boot
    ensure_fstab_targets_unique "$fstab" / /home /boot

    assert_equal 1 "$(awk '$2 == "/" { count++ } END { print count + 0 }' "$fstab")" \
        'fstab target convergence must remove duplicate root entries'
    assert_equal 1 "$(awk '$2 == "/boot" { count++ } END { print count + 0 }' "$fstab")" \
        'fstab target convergence must remove duplicate EFI entries'
    assert_equal 1 "$(awk '$2 == "/home" { count++ } END { print count + 0 }' "$fstab")" \
        'shared Btrfs sources on distinct targets must be preserved'
    grep -Fqx 'UUID=new /boot vfat defaults 0 2' "$fstab" ||
        { printf 'FAIL: the last declared target entry must win\n' >&2; return 1; }
}

test_pacman_section_convergence() {
    local config="$TEST_DIR/pacman.conf"
    local body='Server = https://mirror.example/$arch'
    printf '[options]\nColor\n\n[custom]\nServer = old\n' > "$config"
    pacman-conf() {
        [ "$1" = --config ] && [ -s "$2" ]
    }

    ensure_pacman_section "$config" custom "$body"
    cp "$config" "$config.first"
    ensure_pacman_section "$config" custom "$body"
    ensure_pacman_section "$config" custom "$body"

    pacman_section_matches "$config" custom "$body"
    assert_equal 1 "$(grep -c '^\[custom\]$' "$config")" \
        'pacman convergence must leave one named section'
    cmp -s "$config.first" "$config" || {
        printf 'FAIL: repeated pacman section convergence must be byte-stable\n' >&2
        return 1
    }
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
test_file_metadata_convergence
test_checkout_preserves_shared_parent_mode
test_package_convergence
test_aur_source_routing
test_package_trust_recovery
test_failed_package_trust_recovery_is_not_retried
test_package_non_trust_failure_does_not_recover
test_corrupt_signature_without_trust_error_does_not_recover
test_package_retry_failure_propagates
test_service_convergence
test_fstab_unique_keys
test_fstab_target_deduplication_preserves_btrfs_subvolumes
test_pacman_section_convergence
test_script_contract

printf 'PASS: idempotency and strict-mode contract\n'
