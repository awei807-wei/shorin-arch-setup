#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/shorin-fedora-provider-apply.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

export SHORIN_ROOT="$ROOT_DIR" SHORIN_SCRIPTS_DIR="$ROOT_DIR/scripts"
export SHORIN_DISTRO=fedora SHORIN_MODE=repair SHORIN_READ_ONLY=0
export TARGET_USER=$(id -un) HOME_DIR="$TEST_DIR/home"
mkdir -p "$HOME_DIR"
source "$ROOT_DIR/scripts/lib/core.sh"
source "$ROOT_DIR/scripts/modules/desktop-niri/fedora-provider-apply.sh"

CALLS="$TEST_DIR/calls"
: > "$CALLS"
fedora_provider_architecture_satisfied() {
    printf 'architecture\n' >> "$CALLS"
}
ensure_packages() {
    printf 'ensure:%s\n' "$*" >> "$CALLS"
}
fedora_install_desktop_providers() {
    printf 'provider:%s:%s\n' "$1" "$2" >> "$CALLS"
}

# Exercise the actual desktop-niri apply helper, not a source-text grep.
fedora_desktop_provider_apply_system "$TARGET_USER" "$HOME_DIR" ||
    fail 'Fedora desktop apply helper did not converge'
mapfile -t calls < "$CALLS"
[ "${calls[0]}" = architecture ] || fail 'architecture was not checked first'
[ "${calls[1]}" = 'ensure:curl unzip xz tar util-linux fontconfig' ] ||
    fail 'desktop apply helper did not ensure the complete Fedora prerequisite set'
[ "${calls[2]}" = "provider:$TARGET_USER:$HOME_DIR" ] ||
    fail 'desktop apply helper did not invoke the provider transaction after prerequisites'

# Unsupported architecture must not invoke package installation or providers.
: > "$CALLS"
fedora_provider_architecture_satisfied() {
    printf 'architecture\n' >> "$CALLS"
    return 1
}
status=0
fedora_desktop_provider_apply_system "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -ne 0 ] || fail 'unsupported architecture was accepted by desktop apply'
[ "$(wc -l < "$CALLS")" -eq 1 ] ||
    fail 'unsupported architecture changed package/provider state'

# The standalone user path must not call ensure_packages and must fail closed
# when target-user prerequisites are unavailable.
: > "$CALLS"
fedora_provider_architecture_satisfied() { printf 'architecture\n' >> "$CALLS"; }
fedora_target_user_provider_prerequisites_satisfied() {
    printf 'prerequisites\n' >> "$CALLS"
    return 1
}
status=0
fedora_desktop_provider_apply_user "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -ne 0 ] || fail 'standalone user path accepted missing prerequisites'
! grep -Fq provider "$CALLS" || fail 'standalone user path invoked provider after prerequisite failure'
! grep -Fq ensure "$CALLS" || fail 'standalone user path invoked package installation'

# With prerequisites present, the standalone path calls the same transaction
# while still avoiding ensure_packages entirely.
: > "$CALLS"
fedora_target_user_provider_prerequisites_satisfied() {
    printf 'prerequisites\n' >> "$CALLS"
}
fedora_install_desktop_providers() {
    printf 'provider:%s:%s\n' "$1" "$2" >> "$CALLS"
}
fedora_desktop_provider_apply_user "$TARGET_USER" "$HOME_DIR" ||
    fail 'standalone user path did not invoke provider transaction'
grep -Fqx architecture "$CALLS" || fail 'standalone user path skipped architecture contract'
grep -Fqx prerequisites "$CALLS" || fail 'standalone user path skipped prerequisite contract'
grep -Fqx "provider:$TARGET_USER:$HOME_DIR" "$CALLS" ||
    fail 'standalone user path did not invoke provider transaction'
! grep -Fq ensure "$CALLS" || fail 'standalone user path invoked package installation'

# The stable CLI must fail explicitly on a non-Fedora host.
status=0
output=$(SHORIN_DISTRO=arch bash "$ROOT_DIR/scripts/fedora-desktop-providers.sh" \
    --user "$TARGET_USER" 2>&1) || status=$?
[ "$status" -ne 0 ] || fail 'standalone CLI accepted a non-Fedora host'
grep -Fqx 'MODULE_REASON=fedora-desktop-providers:apply:platform-not-fedora' <<< "$output" ||
    fail 'standalone CLI did not report the non-Fedora reason'

printf 'PASS: Fedora desktop provider apply chain and standalone entry contract\n'
