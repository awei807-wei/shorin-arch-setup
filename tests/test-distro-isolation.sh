#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

test_sources_platform_contract() {
    grep -Eq \
        '^[[:space:]]*(source|\.)[[:space:]]+.*scripts/lib/(core|platform)\.sh' \
        "$1"
}

test_declares_explicit_distro() {
    grep -Eq \
        '(^|[[:space:]])SHORIN_DISTRO=(arch|fedora)([[:space:]\\;]|$)' \
        "$1"
}

test_declares_arch_distro() {
    grep -Eq \
        '(^|[[:space:]])SHORIN_DISTRO=arch([[:space:]\\;]|$)' \
        "$1"
}

# A Fedora host must not alter the intended platform of an Arch contract test.
# Run every sibling test with the host-level Fedora semantic selected, while
# each test that actually loads the platform contract remains responsible for
# selecting its target distro explicitly.  Pure fixture tests do not consume
# the platform contract and therefore need no irrelevant distro declaration.
# This only changes the child-process environment; /etc/os-release is never
# written or replaced.
export SHORIN_DISTRO=fedora
before_os_release=$(sha256sum /etc/os-release | awk '{print $1}')
failures=()
arch_override_count=0
for test_script in "$ROOT_DIR"/tests/test-*.sh; do
    [ "$(basename "$test_script")" = test-distro-isolation.sh ] && continue
    if ! test_sources_platform_contract "$test_script" &&
        ! test_declares_explicit_distro "$test_script"; then
        continue
    fi
    output_file="$TEST_DIR/$(basename "$test_script").log"
    if ! test_declares_explicit_distro "$test_script"; then
        failures+=("$(basename "$test_script")")
        printf 'FAIL: missing explicit SHORIN_DISTRO selection: %s\n' \
            "$(basename "$test_script")" >&2
        continue
    fi
    if test_declares_arch_distro "$test_script"; then
        arch_override_count=$((arch_override_count + 1))
    fi
    if ! bash "$test_script" >"$output_file" 2>&1; then
        failures+=("$(basename "$test_script")")
        printf 'FAIL: Fedora-host isolation run: %s\n' \
            "$(basename "$test_script")" >&2
        sed -n '1,120p' "$output_file" >&2
    fi
done
after_os_release=$(sha256sum /etc/os-release | awk '{print $1}')
[ "$arch_override_count" -gt 0 ] ||
    fail 'No Arch platform test explicitly overrode the injected Fedora distro'
[ "$before_os_release" = "$after_os_release" ] ||
    fail 'Fedora-host isolation test must not modify /etc/os-release'
[ "${#failures[@]}" -eq 0 ] ||
    fail "Fedora-host isolation failures: ${failures[*]}"

printf 'PASS: test suite is isolated from Fedora host distro detection\n'
