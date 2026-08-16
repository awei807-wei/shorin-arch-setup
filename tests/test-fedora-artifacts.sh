#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SHORIN_DISTRO=fedora
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
status=0
fedora_install_application_target lsfg-vk-bin "$TARGET_USER" "$HOME_DIR" ||
    status=$?
[ "$status" -eq "$RC_SKIPPED" ] ||
    fail 'a missing manual RPM must be reported as a pending skip, not success'
fedora_application_target_pending lsfg-vk-bin "$HOME_DIR" ||
    fail 'a missing manual RPM must be classified as pending'
if fedora_install_application_target lsfg-vk-bin "$TARGET_USER" "$HOME_DIR"; then
    fail 'lsfg-vk must fail when its main RPM is missing'
fi
touch "$RPM_DIR/lsfg-vk-1.0.x86_64.rpm"
if fedora_application_target_pending lsfg-vk-bin "$HOME_DIR"; then
    fail 'an available manual RPM must not remain classified as pending'
fi
rm -f "$RPM_DIR/lsfg-vk-1.0.x86_64.rpm"

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

# Missing handoff artifacts are drift during check, but an explicit pending
# state during verify/apply. They must not be reported as successfully
# installed or turn the independent applications module into a hard failure.
module_main() { :; }
APPLICATION_MANIFEST="$TEST_DIR/applications.list"
printf 'AUR:lsfg-vk-bin\n' > "$APPLICATION_MANIFEST"
source "$ROOT_DIR/scripts/modules/applications.sh"
MODULE_RESULT=$RC_OK
MODULE_REASONS=()
applications_check
[ "$MODULE_RESULT" -eq "$RC_DRIFT" ] ||
    fail 'a missing Fedora artifact must trigger application apply as drift'
grep -Fqx 'application-pending:AUR:lsfg-vk-bin' <<< "${MODULE_REASONS[*]}" ||
    fail 'application check must explain the pending artifact'
MODULE_RESULT=$RC_OK
MODULE_REASONS=()
applications_verify
[ "$MODULE_RESULT" -eq "$RC_SKIPPED" ] ||
    fail 'application verify must classify a missing artifact as pending skip'
grep -Fqx 'application-pending:AUR:lsfg-vk-bin' <<< "${MODULE_REASONS[*]}" ||
    fail 'application verify must retain the pending artifact reason'
bash() { return "$RC_SKIPPED"; }
MODULE_RESULT=$RC_OK
MODULE_REASONS=()
applications_apply || fail 'pending application apply must not return a hard failure'
[ "$MODULE_RESULT" -eq "$RC_SKIPPED" ] ||
    fail 'pending application apply must mark the module skipped'
unset -f bash

printf 'PASS: Fedora artifact discovery, post-install verification, and Vicinae state contract\n'
