#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
BIN_DIR="$TEST_DIR/bin"
DNF_CALLS="$TEST_DIR/dnf-calls"
mkdir -p "$BIN_DIR"
: > "$DNF_CALLS"
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

cat > "$BIN_DIR/dnf" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${FEDORA_UPGRADE_DNF_CALLS:?}"
if [ "${FEDORA_UPGRADE_FAIL_COMMAND:-}" = "${1:-}" ]; then
    exit "${FEDORA_UPGRADE_FAIL_STATUS:-23}"
fi
EOF
chmod 755 "$BIN_DIR/dnf"

export PATH="$BIN_DIR:$PATH"
export FEDORA_UPGRADE_DNF_CALLS="$DNF_CALLS"
export SHORIN_DISTRO=fedora SHORIN_MODE=repair SHORIN_READ_ONLY=0
export SHORIN_ROOT="$ROOT_DIR" SHORIN_SCRIPTS_DIR="$ROOT_DIR/scripts"
source "$ROOT_DIR/scripts/lib/core.sh"

platform_fedora_system_upgrade ||
    fail 'Fedora system upgrade helper rejected a successful transaction'
grep -Fqx \
    'upgrade --refresh -y --best --setopt=allow_vendor_change=False --setopt=allow_downgrade=False --setopt=install_weak_deps=False' \
    "$DNF_CALLS" || fail 'Fedora system upgrade command is not fail-closed'
grep -Fqx 'check' "$DNF_CALLS" ||
    fail 'Fedora system upgrade must finish with dnf check'
if grep -Eq 'distro-sync|allowerasing|skip-broken|skip-unavailable|allow_vendor_change=True|allow_downgrade=True' \
    "$DNF_CALLS"; then
    fail 'Fedora system upgrade used a destructive or permissive option'
fi

: > "$DNF_CALLS"
export FEDORA_UPGRADE_FAIL_COMMAND=upgrade FEDORA_UPGRADE_FAIL_STATUS=23
status=0
platform_fedora_system_upgrade || status=$?
[ "$status" -eq 23 ] ||
    fail "Fedora upgrade failure status was not preserved (got $status)"
[ "$(wc -l < "$DNF_CALLS")" -eq 1 ] ||
    fail 'dnf check ran after a failed Fedora upgrade'

: > "$DNF_CALLS"
export FEDORA_UPGRADE_FAIL_COMMAND=check FEDORA_UPGRADE_FAIL_STATUS=24
status=0
platform_fedora_system_upgrade || status=$?
[ "$status" -eq 24 ] ||
    fail "dnf check failure status was not preserved (got $status)"
[ "$(wc -l < "$DNF_CALLS")" -eq 2 ] ||
    fail 'Fedora upgrade/check sequence was incomplete'

: > "$DNF_CALLS"
unset FEDORA_UPGRADE_FAIL_COMMAND FEDORA_UPGRADE_FAIL_STATUS
SHORIN_DISTRO=arch platform_fedora_system_upgrade ||
    fail 'Arch no-op path failed in Fedora upgrade helper'
[ ! -s "$DNF_CALLS" ] ||
    fail 'Arch path invoked dnf through the Fedora upgrade helper'

system_apply="$ROOT_DIR/scripts/modules/base/system-apply.sh"
preflight_line=$(rg -n 'base_fedora_nvidia_provider_preflight' \
    "$system_apply" | head -1 | cut -d: -f1)
upgrade_line=$(rg -n 'platform_fedora_system_upgrade' \
    "$system_apply" | head -1 | cut -d: -f1)
install_line=$(rg -n 'ensure_packages "\$\{FEDORA_BASE_PACKAGES\[@\]\}"' \
    "$system_apply" | head -1 | cut -d: -f1)
[ "$preflight_line" -lt "$upgrade_line" ] &&
    [ "$upgrade_line" -lt "$install_line" ] ||
    fail 'Fedora provider preflight/upgrade/package-install ordering regressed'

grep -Fq 'gpu-provider:nvidia-rpmfusion-exclusive:action-required' \
    "$ROOT_DIR/scripts/modules/base.sh" ||
    fail 'external NVIDIA provider is still treated as auto-repairable drift'

printf 'PASS: Fedora system upgrade is ordered, fail-closed, and isolated\n'
