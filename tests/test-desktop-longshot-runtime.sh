#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
TARGET_USER=$(id -un)
HOME_DIR="$TEST_DIR/home"
BIN_DIR="$TEST_DIR/bin"
PYTHON_CALLS="$TEST_DIR/python-calls"
FORBIDDEN_CALLS="$TEST_DIR/forbidden-calls"
SHORIN_ROOT=$ROOT_DIR
SHORIN_MODE=repair
SHORIN_READ_ONLY=0
export TARGET_USER HOME_DIR SHORIN_ROOT SHORIN_MODE SHORIN_READ_ONLY
export PYTHON_CALLS FORBIDDEN_CALLS

cleanup() {
    find "$TEST_DIR" -depth -delete
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

mkdir -p "$BIN_DIR" "$HOME_DIR/.config/waybar/scripts/longshot-sh"
: > "$PYTHON_CALLS"
: > "$FORBIDDEN_CALLS"

cat > "$BIN_DIR/python3" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${PYTHON_CALLS:?}"

if [ "${1:-}" = -I ] && [ "${2:-}" = -c ]; then
    exit 0
fi
if [ "${1:-}" != -m ] || [ "${2:-}" != venv ]; then
    exit 64
fi

destination=${!#}
system_site=false
for argument in "$@"; do
    [ "$argument" != --system-site-packages ] || system_site=true
done
mkdir -p "$destination/bin"
printf 'include-system-site-packages = %s\n' "$system_site" \
    > "$destination/pyvenv.cfg"
cat > "$destination/bin/python" <<'PYTHON'
#!/usr/bin/env bash
if [ "${1:-}" = -I ] && [ "${2:-}" = -c ]; then
    [ ! -e "$(dirname "$(dirname "$0")")/.local-cv2-numpy-shadow" ] || exit 42
    exit 0
fi
exit 64
PYTHON
chmod 755 "$destination/bin/python"
EOF
chmod 755 "$BIN_DIR/python3"

for command in pip pip3 curl wget; do
    cat > "$BIN_DIR/$command" <<'EOF'
#!/usr/bin/env bash
printf '%s:%s\n' "$(basename "$0")" "$*" >> "${FORBIDDEN_CALLS:?}"
exit 99
EOF
    chmod 755 "$BIN_DIR/$command"
done
export PATH="$BIN_DIR:$PATH"

# Newly required targets must survive an empty legacy profile instead of being
# masked by the old saved selection.
EMPTY_PROFILE="$TEST_DIR/empty-niri-packages.list"
EMPTY_LIST="$TEST_DIR/empty-niri-applist.txt"
: > "$EMPTY_PROFILE"
: > "$EMPTY_LIST"
for distro in arch fedora; do
    targets=$(SHORIN_DISTRO=$distro SHORIN_ROOT="$ROOT_DIR" \
        EMPTY_PROFILE="$EMPTY_PROFILE" EMPTY_LIST="$EMPTY_LIST" \
        bash -c '
            source "$SHORIN_ROOT/scripts/modules/desktop-niri/targets.sh"
            niri_all_package_targets "$EMPTY_PROFILE" "$EMPTY_LIST"
        ')
    for required in grim slurp wf-recorder wl-clipboard python-opencv \
        python-numpy pngquant ffmpeg; do
        grep -Fqx "$required" <<< "$targets" ||
            fail "$distro legacy profile dropped required longshot target $required"
    done
    if grep -Fqx ydotool <<< "$targets"; then
        fail "$distro manual longshot contract must not require ydotool"
    fi
done

export SHORIN_DISTRO=fedora
source "$ROOT_DIR/scripts/modules/desktop-niri/targets.sh"
[ "$(fedora_arch_target_name python-opencv)" = python3-opencv ] ||
    fail 'Fedora python-opencv mapping is missing'
[ "$(fedora_arch_target_name python-numpy)" = python3-numpy ] ||
    fail 'Fedora python-numpy mapping is missing'
[ "$(fedora_arch_target_name pngquant)" = pngquant ] ||
    fail 'Fedora pngquant mapping is missing'
[ "$(fedora_arch_target_name ffmpeg)" = ffmpeg-free ] ||
    fail 'Fedora ffmpeg mapping must use the native ffmpeg-free provider'

desktop_niri_contract_init
cat > "$HOME_DIR/.config/waybar/scripts/longshot-sh/setup.sh" <<'EOF'
#!/usr/bin/env bash
printf 'setup:%s\n' "$*" >> "${FORBIDDEN_CALLS:?}"
exit 99
EOF
chmod 755 "$HOME_DIR/.config/waybar/scripts/longshot-sh/setup.sh"

ensure_niri_longshot_runtime "$TARGET_USER" ||
    fail 'missing longshot venv did not converge'
niri_longshot_runtime_satisfied "$TARGET_USER" ||
    fail 'new longshot venv does not satisfy the runtime contract'
grep -Fqx 'include-system-site-packages = true' \
    "$NIRI_LONGSHOT_VENV_DIR/pyvenv.cfg" ||
    fail 'new longshot venv must enable system site packages'
grep -Fq -- '--system-site-packages --without-pip' "$PYTHON_CALLS" ||
    fail 'longshot venv creation must use system packages without pip'
[ -z "$(find -P "$NIRI_LONGSHOT_VENV_DIR" ! -user "$TARGET_USER" -print -quit)" ] ||
    fail 'longshot venv must remain wholly owned by the target user'
[ ! -s "$FORBIDDEN_CALLS" ] ||
    fail 'longshot runtime convergence invoked setup, pip, or a network client'

calls_before=$(wc -l < "$PYTHON_CALLS")
ensure_niri_longshot_runtime "$TARGET_USER" ||
    fail 'idempotent longshot venv check failed'
[ "$(wc -l < "$PYTHON_CALLS")" -eq "$calls_before" ] ||
    fail 'satisfied longshot venv must not be recreated or upgraded'

# An old ordinary venv is upgraded in place without running pip or deleting
# unrelated user-owned contents.
find "$NIRI_LONGSHOT_VENV_DIR" -depth -delete
mkdir -p "$NIRI_LONGSHOT_VENV_DIR/bin"
printf 'include-system-site-packages = false\n' \
    > "$NIRI_LONGSHOT_VENV_DIR/pyvenv.cfg"
printf 'preserve\n' > "$NIRI_LONGSHOT_VENV_DIR/user-marker"
cat > "$NIRI_LONGSHOT_VENV_DIR/bin/python" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 755 "$NIRI_LONGSHOT_VENV_DIR/bin/python"
ensure_niri_longshot_runtime "$TARGET_USER" ||
    fail 'old longshot venv did not upgrade to system packages'
grep -Fqx preserve "$NIRI_LONGSHOT_VENV_DIR/user-marker" ||
    fail 'longshot venv upgrade must preserve user-owned contents'
grep -Fq -- '--upgrade --system-site-packages --without-pip' "$PYTHON_CALLS" ||
    fail 'old longshot venv must use the non-network upgrade path'
[ ! -s "$FORBIDDEN_CALLS" ] ||
    fail 'longshot venv upgrade invoked setup, pip, or a network client'

# A legacy venv whose local wheels shadow distribution cv2/numpy must remain
# untouched and fail with an actionable error.  The installer must never
# delete user packages to force convergence.
printf 'user wheel payload\n' > "$NIRI_LONGSHOT_VENV_DIR/local-wheel-marker"
: > "$NIRI_LONGSHOT_VENV_DIR/.local-cv2-numpy-shadow"
if niri_longshot_runtime_satisfied "$TARGET_USER"; then
    fail 'venv-local cv2/numpy shadow was accepted by the runtime contract'
fi
upgrades_before=$(grep -c -- '--upgrade' "$PYTHON_CALLS" || true)
shadow_output=
if shadow_output=$(ensure_niri_longshot_runtime "$TARGET_USER" 2>&1); then
    fail 'shadowed longshot venv was modified instead of failing closed'
fi
grep -Fq 'local cv2/numpy packages shadow distribution modules' \
    <<< "$shadow_output" ||
    fail 'shadowed longshot venv did not report an actionable error'
grep -Fqx 'user wheel payload' "$NIRI_LONGSHOT_VENV_DIR/local-wheel-marker" ||
    fail 'shadow rejection removed or modified a user package marker'
[ -e "$NIRI_LONGSHOT_VENV_DIR/.local-cv2-numpy-shadow" ] ||
    fail 'shadow rejection removed the simulated user package'
[ "$(grep -c -- '--upgrade' "$PYTHON_CALLS" || true)" -eq "$upgrades_before" ] ||
    fail 'shadowed longshot venv was upgraded before rejection'

# Refuse both a redirected venv and a redirected pyvenv.cfg without touching
# the external target.
find "$NIRI_LONGSHOT_VENV_DIR" -depth -delete
external="$TEST_DIR/external-venv"
mkdir -p "$external"
printf 'preserve external\n' > "$external/marker"
ln -s "$external" "$NIRI_LONGSHOT_VENV_DIR"
if ensure_niri_longshot_runtime "$TARGET_USER" 2>/dev/null; then
    fail 'longshot runtime must reject a venv symlink'
fi
grep -Fqx 'preserve external' "$external/marker" ||
    fail 'venv symlink rejection modified its target'
rm "$NIRI_LONGSHOT_VENV_DIR"
mkdir -p "$NIRI_LONGSHOT_VENV_DIR/bin"
ln -s "$external/marker" "$NIRI_LONGSHOT_VENV_DIR/pyvenv.cfg"
if ensure_niri_longshot_runtime "$TARGET_USER" 2>/dev/null; then
    fail 'longshot runtime must reject a pyvenv.cfg symlink'
fi
grep -Fqx 'preserve external' "$external/marker" ||
    fail 'pyvenv.cfg symlink rejection modified its target'

printf 'PASS: desktop longshot runtime contract\n'
