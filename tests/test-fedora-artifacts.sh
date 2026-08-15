#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
BIN_DIR="$TEST_DIR/bin"
RPM_DIR="$TEST_DIR/rpm artifacts"
ARTIFACT_DIR="$TEST_DIR/secondary artifacts"
HOME_DIR="$TEST_DIR/target home"
mkdir -p "$BIN_DIR" "$RPM_DIR" "$ARTIFACT_DIR" "$HOME_DIR"
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

cat > "$BIN_DIR/dnf" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${1:-}" = install ]; then
    printf '%s\n' "${!#}" > "${FEDORA_TEST_INSTALLED_FILE:?}"
    exit 0
fi
exit 1
EOF
cat > "$BIN_DIR/rpm" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
    -q)
        if [ "${2:-}" = --qf ]; then
            case "${@: -1}" in
                qt6-qtdeclarative|qt6-qtbase) printf '1-1\n'; exit 0 ;;
                *) exit 1 ;;
            esac
        fi
        case "${2:-}" in
            qt6-qtdeclarative|qt6-qtbase) exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    -qa)
        if [ -s "${FEDORA_TEST_INSTALLED_FILE:-}" ]; then
            basename "$(< "$FEDORA_TEST_INSTALLED_FILE")" | sed -E 's/[- ].*//'
        fi
        ;;
    *) exit 1 ;;
esac
EOF
cat > "$BIN_DIR/flatpak" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[ "${1:-}" = info ] && [ "${3:-}" = it.mijorus.gearlever ]
EOF
chmod +x "$BIN_DIR"/*

export PATH="$BIN_DIR:$PATH"
export SHORIN_DISTRO=fedora SHORIN_MODE=install SHORIN_READ_ONLY=0
export TARGET_USER=tester HOME_DIR FEDORA_RPM_DIR="$RPM_DIR" \
    SHORIN_ARTIFACT_DIR="$ARTIFACT_DIR"
export FEDORA_TEST_INSTALLED_FILE="$TEST_DIR/installed"
export PACKAGE_SOURCE_DIR="$TEST_DIR/package-sources"
source "$ROOT_DIR/scripts/lib/core.sh"

rpm_file="$RPM_DIR/linuxqq 1.2.3.x86_64.rpm"
: > "$rpm_file"
: > "$ARTIFACT_DIR/linuxqq-secondary.rpm"
found=$(fedora_rpm_file 'linuxqq*.rpm')
[ "$found" = "$rpm_file" ] || fail 'RPM discovery must preserve directories and spaces in filenames'

CALLS="$TEST_DIR/dnf-calls"
dnf() {
    printf '%s\n' "$*" >> "$CALLS"
    printf '%s\n' "${!#}" > "$FEDORA_TEST_INSTALLED_FILE"
}
export -f dnf
fedora_install_application_target linuxqq-appimage "$TARGET_USER" "$HOME_DIR" ||
    fail 'a discovered official RPM must install and satisfy its target'
grep -Fqx "install -y $rpm_file" "$CALLS" ||
    fail 'the RPM path must be passed to dnf as one quoted argument'
rm -f "$rpm_file"
fedora_install_application_target linuxqq-appimage "$TARGET_USER" "$HOME_DIR" ||
    fail 'an already satisfied Fedora RPM target must be idempotent without the artifact'

rm -f "$FEDORA_TEST_INSTALLED_FILE"
if fedora_install_application_target lsfg-vk-bin "$TARGET_USER" "$HOME_DIR"; then
    fail 'lsfg-vk must fail when its main RPM is missing'
fi

gearlever_dir="$HOME_DIR/.local/share/applications"
mkdir -p "$HOME_DIR/.local/bin" "$gearlever_dir"
touch "$HOME_DIR/.local/bin/vicinae.AppImage"
chmod 755 "$HOME_DIR/.local/bin/vicinae.AppImage"
cat > "$gearlever_dir/vicinae.desktop" <<EOF
[Desktop Entry]
Name=Vicinae
Exec=$HOME_DIR/.local/bin/vicinae.AppImage
EOF
if fedora_application_target_satisfied vicinae-bin "$TARGET_USER" "$HOME_DIR"; then
    fail 'Vicinae must not claim integration from an unquoted unmanaged desktop entry'
fi
sed -i "s#^Exec=.*#Exec=\"$HOME_DIR/.local/bin/vicinae.AppImage\"#" \
    "$gearlever_dir/vicinae.desktop"
fedora_application_target_satisfied vicinae-bin "$TARGET_USER" "$HOME_DIR" ||
    fail 'Vicinae integration must require Gear Lever, executable AppImage, and managed desktop entry'

printf 'PASS: Fedora artifact discovery, post-install verification, and Vicinae state contract\n'
