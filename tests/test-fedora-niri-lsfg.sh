#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
TARGET_USER=$(id -un)
HOME_DIR="$TEST_DIR/home"
SHORIN_ROOT=$ROOT_DIR
SHORIN_DISTRO=fedora
SHORIN_MODE=repair
SHORIN_READ_ONLY=0
export TARGET_USER HOME_DIR SHORIN_ROOT SHORIN_DISTRO SHORIN_MODE SHORIN_READ_ONLY

cleanup() { find "$TEST_DIR" -depth -delete; }
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

source "$ROOT_DIR/scripts/modules/desktop-niri/targets.sh"

mkdir -p "$HOME_DIR/.config/niri" "$HOME_DIR/.local/bin" \
    "$TEST_DIR/bin"
desktop_niri_contract_init
cat > "$NIRI_CONFIG_FILE" <<'EOF'
input {
    keyboard { }
}

environment {
    PATH "/usr/local/bin:/usr/bin"
    DISABLE_LSFG "0"
}
EOF
printf '%s\n' 'binds {}' > "$NIRI_BINDS_FILE"

# Keep the fixture independent of a live graphical session while still
# exercising the user-manager contract and refresh command.
niri_user_bus_is_available() { return 0; }
runuser() {
    [ "$1" = -u ] && [ "$3" = -- ] || return 2
    shift 3
    "$@"
}
cat > "$TEST_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LSFG_SYSTEMCTL_LOG:?}"
case "${2:-}" in
    show-environment) printf '%s\n' 'DISABLE_LSFG=1' ;;
    set-environment) : ;;
    *) : ;;
esac
EOF
chmod 755 "$TEST_DIR/bin/systemctl"
export LSFG_SYSTEMCTL_LOG="$TEST_DIR/systemctl.log"
PATH="$TEST_DIR/bin:$PATH"
export PATH

niri_fedora_lsfg_session_satisfied "$TARGET_USER" &&
    fail 'an unconfigured Fedora Niri session must not satisfy LSFG safety'
ensure_niri_fedora_lsfg_session "$TARGET_USER" ||
    fail 'Fedora LSFG session environment must converge'
niri_fedora_lsfg_session_satisfied "$TARGET_USER" ||
    fail 'converged Fedora LSFG session environment must satisfy verification'

grep -Fqx '    DISABLE_LSFG "1"' "$NIRI_CONFIG_FILE" ||
    fail 'Niri config must disable the implicit LSFG layer'
[ "$(< "$(niri_fedora_lsfg_environment_file_path)")" = 'DISABLE_LSFG=1' ] ||
    fail 'environment.d must disable the implicit LSFG layer'
[ -x "$(niri_fedora_lsfg_wrapper_path)" ] ||
    fail 'LSFG opt-in wrapper must be executable'
grep -Fq 'set-environment DISABLE_LSFG=1' "$LSFG_SYSTEMCTL_LOG" ||
    fail 'session apply must refresh the systemd user-manager environment'

wrapper_output=$(DISABLE_LSFG=1 "$(niri_fedora_lsfg_wrapper_path)" \
    bash -c 'printf "%s\n" "${DISABLE_LSFG-unset}"')
[ "$wrapper_output" = unset ] ||
    fail 'LSFG opt-in wrapper must remove the inherited disable flag'
status=0
"$(niri_fedora_lsfg_wrapper_path)" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail 'LSFG opt-in wrapper must require a command'

printf '%s\n' 'DISABLE_LSFG=0' > "$(niri_fedora_lsfg_environment_file_path)"
if niri_fedora_lsfg_session_satisfied "$TARGET_USER"; then
    fail 'verification must reject a wrong environment.d LSFG value'
fi
ensure_niri_fedora_lsfg_session "$TARGET_USER" ||
    fail 'LSFG environment.d repair must converge'

printf '%s\n' '    DISABLE_LSFG "0"' > "$TEST_DIR/wrong-kdl-line"
sed -i 's/DISABLE_LSFG "1"/DISABLE_LSFG "0"/' "$NIRI_CONFIG_FILE"
if niri_fedora_lsfg_session_satisfied "$TARGET_USER"; then
    fail 'verification must reject a wrong Niri LSFG value'
fi
ensure_niri_fedora_lsfg_session "$TARGET_USER" ||
    fail 'Niri LSFG environment repair must converge'

ensure_niri_fish_sources "$TARGET_USER" ||
    fail 'Fedora Fish environment guard must converge'
grep -Fqx 'set -gx DISABLE_LSFG 1' "$NIRI_FISH_GUARD_FILE" ||
    fail 'Fedora Fish sessions must inherit the LSFG disable flag'

printf 'PASS: Fedora Niri LSFG session environment contract\n'
