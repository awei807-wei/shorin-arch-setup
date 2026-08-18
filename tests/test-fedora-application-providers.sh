#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
BIN_DIR="$TEST_DIR/bin"
HOME_DIR="$TEST_DIR/home"
APPLICATION_DESKTOP_DIR="$TEST_DIR/applications"
TARGET_USER=$(id -un)
mkdir -p "$BIN_DIR" "$HOME_DIR" "$APPLICATION_DESKTOP_DIR"
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

export SHORIN_DISTRO=fedora SHORIN_MODE=install SHORIN_READ_ONLY=0
export SHORIN_ROOT="$ROOT_DIR" TARGET_USER HOME_DIR APPLICATION_DESKTOP_DIR
export PATH="$BIN_DIR:$PATH"
source "$ROOT_DIR/scripts/modules/applications/targets.sh"
source "$ROOT_DIR/scripts/modules/applications/config-apply.sh"

declare -Ag INSTALLED_PACKAGES=()
declare -Ag INSTALLED_FLATPAKS=()
COPR_ENABLED=0
LACT_ENABLED=0
LACT_ACTIVE=0
RPM_LACT=0
STEAM_LOCALE=0
QUERY_ERROR=0
USER_SCOPE_ONLY=0
PROVIDER_CALLS="$TEST_DIR/provider-calls"
: > "$PROVIDER_CALLS"
export PROVIDER_CALLS

[ "${WINE_CONFIG_PACKAGES[*]}" = \
    'wine wine-mono mingw32-wine-gecko mingw64-wine-gecko' ] ||
    fail 'Fedora Wine contract must use the explicit mingw Gecko packages'
for wine_package in wine wine-mono mingw32-wine-gecko mingw64-wine-gecko; do
    [ "$(fedora_arch_target_name "$wine_package")" = "$wine_package" ] ||
        fail "Fedora Wine package whitelist is missing $wine_package"
done
if fedora_arch_target_name wine-gecko >/dev/null 2>&1; then
    fail 'Fedora must reject the obsolete wine-gecko target'
fi

state_package_present() {
    [ "$QUERY_ERROR" -eq 0 ] || return 2
    [ "${INSTALLED_PACKAGES[$1]:-0}" -eq 1 ]
}

state_flatpak_present() {
    [ "$QUERY_ERROR" -eq 0 ] || return 2
    [ "${INSTALLED_FLATPAKS[$1]:-0}" -eq 1 ]
}

state_service_enabled() {
    [ "$1" = "$FEDORA_LACT_SERVICE" ] && [ "$LACT_ENABLED" -eq 1 ]
}

state_service_active() {
    [ "$1" = "$FEDORA_LACT_SERVICE" ] && [ "$LACT_ACTIVE" -eq 1 ]
}

rpm() {
    [ "${1:-}" = -q ] && [ "${2:-}" = lact ] &&
        [ "$RPM_LACT" -eq 1 ]
}

platform_dnf_package_available() {
    printf 'repoquery:%s:%s\n' "$1" "$2" >> "$PROVIDER_CALLS"
    return 0
}

platform_dnf_install_from_repo() {
    printf 'dnf-install:%s:%s\n' "$1" "$2" >> "$PROVIDER_CALLS"
    RPM_LACT=1
}

ensure_package() {
    printf 'package:%s\n' "$1" >> "$PROVIDER_CALLS"
    INSTALLED_PACKAGES["$1"]=1
}

ensure_flatpak() {
    printf 'flatpak:%s\n' "$1" >> "$PROVIDER_CALLS"
    INSTALLED_FLATPAKS["$1"]=1
}

ensure_service_started() {
    printf 'service:%s\n' "$1" >> "$PROVIDER_CALLS"
    LACT_ENABLED=1
    LACT_ACTIVE=1
}

dnf() {
    printf 'dnf:%s\n' "$*" >> "$PROVIDER_CALLS"
    if [ "${1:-}" = repolist ] && [ "$COPR_ENABLED" -eq 1 ]; then
        printf 'copr:copr.fedorainfracloud.org:ilyaz:LACT\n'
    fi
    if [ "${1:-}" = copr ]; then
        COPR_ENABLED=1
    fi
}

flatpak() {
    case "$*" in
        'info --system '*| 'info --user '*)
            [ "$QUERY_ERROR" -eq 0 ] || return 2
            if [ "$USER_SCOPE_ONLY" -eq 1 ] && [ "${2:-}" = --system ]; then
                return 1
            fi
            app=${*:3}
            [ "${INSTALLED_FLATPAKS[$app]:-0}" -eq 1 ]
            ;;
        'override --system --show com.valvesoftware.Steam')
            [ "$STEAM_LOCALE" -eq 1 ] && printf 'LANG=zh_CN.UTF-8\n'
            ;;
        'override --system --env=LANG=zh_CN.UTF-8 com.valvesoftware.Steam')
            STEAM_LOCALE=1
            ;;
        'override --user --show com.valvesoftware.Steam')
            [ "$STEAM_LOCALE" -eq 1 ] && printf 'LANG=zh_CN.UTF-8\n'
            ;;
        'override --user --env=LANG=zh_CN.UTF-8 com.valvesoftware.Steam')
            STEAM_LOCALE=1
            ;;
        *) return 1 ;;
    esac
}

cat > "$BIN_DIR/flatpak" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$BIN_DIR/flatpak"

for target in code curtail mission-center steam; do
    [ "$(fedora_application_provider_kind "$target")" = flatpak ] ||
        fail "Fedora provider kind missing for $target"
done
[ "$(fedora_application_provider_kind yazi)" = release ] ||
    fail 'Yazi must use the verified Fedora release provider'
[ "$(fedora_application_provider_id yazi)" = yazi-v26.8.15 ] ||
    fail 'Yazi release provider must be pinned to v26.8.15'
for target in code curtail fd mission-center steam yazi lact; do
    if fedora_arch_target_name "$target" >/dev/null 2>&1; then
        fail "Fedora provider target leaked into generic dnf mapping: $target"
    fi
done
[ "$(fedora_application_provider_id code)" = com.visualstudio.code ] ||
    fail 'VS Code must use the official Flathub ID'
[ "$(fedora_application_provider_id curtail)" = com.github.huluti.Curtail ] ||
    fail 'Curtail must use the official Flathub ID'
[ "$(fedora_application_provider_id mission-center)" = io.missioncenter.MissionCenter ] ||
    fail 'Mission Center must use the official Flathub ID'
[ "$(fedora_application_provider_id steam)" = com.valvesoftware.Steam ] ||
    fail 'Steam must use the official Flathub ID'

for target in code curtail mission-center; do
    fedora_install_application_target "$target" "$TARGET_USER" "$HOME_DIR" ||
        fail "Flatpak provider did not converge for $target"
done
[ "$(fedora_application_provider_kind tsukimi-bin)" = copr ] ||
    fail 'Tsukimi must use the shared COPR provider registry'
[ "$(fedora_application_provider_id tsukimi-bin)" = walker874/tsukimi ] ||
    fail 'Tsukimi provider registry must expose walker874/tsukimi'
for app in com.visualstudio.code com.github.huluti.Curtail \
    io.missioncenter.MissionCenter; do
    [ "${INSTALLED_FLATPAKS[$app]:-0}" -eq 1 ] ||
        fail "Flatpak provider did not install $app"
done

mkdir -p "$TEST_DIR/flatpak-exports"
printf '[Desktop Entry]\nName=Steam\n' > \
    "$TEST_DIR/flatpak-exports/com.valvesoftware.Steam.desktop"
export FEDORA_FLATPAK_EXPORT_DIR="$TEST_DIR/flatpak-exports"
fedora_install_application_target steam "$TARGET_USER" "$HOME_DIR" ||
    fail 'Steam Flatpak provider did not converge'
ensure_application_entry_config steam ||
    fail 'Fedora Steam locale configuration did not converge'
application_entry_satisfied steam ||
    fail 'Fedora Steam payload/export/override contract did not converge'
grep -Fqx 'flatpak:com.valvesoftware.Steam' "$PROVIDER_CALLS" ||
    fail 'Steam provider must use Flatpak instead of native dnf'

unset FEDORA_FLATPAK_EXPORT_DIR
USER_SCOPE_ONLY=1
mkdir -p "$HOME_DIR/.local/share/flatpak/exports/share/applications"
printf '[Desktop Entry]\nName=Steam\n' > \
    "$HOME_DIR/.local/share/flatpak/exports/share/applications/com.valvesoftware.Steam.desktop"
STEAM_LOCALE=0
fedora_flatpak_present com.valvesoftware.Steam ||
    fail 'Fedora Flatpak provider must detect a user-scope installation'
ensure_application_entry_config steam ||
    fail 'Fedora Steam locale configuration must use the user scope when needed'
steam_flatpak_locale_satisfied ||
    fail 'Fedora Steam user-scope export/override contract did not converge'
USER_SCOPE_ONLY=0

FEDORA_FD_COMMAND_PATH="$TEST_DIR/fd"
printf '#!/usr/bin/env bash\n' > "$FEDORA_FD_COMMAND_PATH"
chmod 755 "$FEDORA_FD_COMMAND_PATH"
fedora_install_application_target fd "$TARGET_USER" "$HOME_DIR" ||
    fail 'fd provider did not converge'
[ "${INSTALLED_PACKAGES[fd-find]:-0}" -eq 1 ] ||
    fail 'fd provider must install fd-find'
fedora_application_target_satisfied fd ||
    fail 'fd provider must verify fd-find and /usr/bin/fd contract'
for lazyvim_package in "${LAZYVIM_PACKAGES[@]}"; do
    INSTALLED_PACKAGES["$lazyvim_package"]=1
done
INSTALLED_PACKAGES[fd]=0
# LazyVim's Nerd Font is now a target-user exact-family provider rather than
# the ordinary Fedora jetbrains-mono-fonts package.  Keep this application
# fixture focused on its fd-find contract and stub the independent provider.
fedora_font_target_satisfied() { return 0; }
lazyvim_config_satisfied() { return 0; }
lazyvim_target_satisfied ||
    fail 'Fedora LazyVim contract must route fd through fd-find and /usr/bin/fd'

FEDORA_LACT_COMMAND_PATH="$TEST_DIR/lact"
printf '#!/usr/bin/env bash\n' > "$FEDORA_LACT_COMMAND_PATH"
chmod 755 "$FEDORA_LACT_COMMAND_PATH"
fedora_install_application_target lact "$TARGET_USER" "$HOME_DIR" ||
    fail 'LACT provider did not converge'
[ "$COPR_ENABLED" -eq 1 ] || fail 'LACT provider must enable its COPR'
[ "$RPM_LACT" -eq 1 ] ||
    fail 'LACT provider must install the lact package'
[ "$LACT_ENABLED:$LACT_ACTIVE" = 1:1 ] ||
    fail 'LACT provider must enable and start its daemon'
first_copr_count=$(grep -c '^dnf:copr enable -y ilyaz/LACT$' "$PROVIDER_CALLS" || true)
fedora_install_application_target lact "$TARGET_USER" "$HOME_DIR" ||
    fail 'LACT provider must be idempotent'
second_copr_count=$(grep -c '^dnf:copr enable -y ilyaz/LACT$' "$PROVIDER_CALLS" || true)
[ "$first_copr_count" -eq "$second_copr_count" ] ||
    fail 'LACT provider must not re-enable an already enabled COPR'

RUNUSER_CALLS=0
runuser() {
    RUNUSER_CALLS=$((RUNUSER_CALLS + 1))
    [ "${1:-}" = -u ] && shift 2
    [ "${1:-}" = -- ] && shift
    "$@"
}
YAZI_X86_ROOT="$TEST_DIR/yazi-x86_64-unknown-linux-gnu"
YAZI_AARCH64_ROOT="$TEST_DIR/yazi-aarch64-unknown-linux-gnu"
mkdir -p "$YAZI_X86_ROOT" "$YAZI_AARCH64_ROOT"
for binary in yazi ya; do
    case "$binary" in
        yazi) title=Yazi ;;
        ya) title=Ya ;;
    esac
    cat > "$YAZI_X86_ROOT/$binary" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '$title'
printf '%s\n' '    Version: 26.8.15 (fixture)'
EOF
    cat > "$YAZI_AARCH64_ROOT/$binary" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '$title'
printf '%s\n' '    Version: 26.8.15 (fixture)'
EOF
    chmod 755 "$YAZI_X86_ROOT/$binary" "$YAZI_AARCH64_ROOT/$binary"
done
printf 'release metadata that must not be installed\\n' > \
    "$YAZI_X86_ROOT/unexpected-file"
(cd "$TEST_DIR" && zip -q -r "$TEST_DIR/yazi-x86_64.zip" \
    "yazi-x86_64-unknown-linux-gnu")
(cd "$TEST_DIR" && zip -q -r "$TEST_DIR/yazi-aarch64.zip" \
    "yazi-aarch64-unknown-linux-gnu")
YAZI_ARCHIVE_SOURCE="$TEST_DIR/yazi-x86_64.zip"
YAZI_BAD_CHECKSUM=0
FEDORA_YAZI_MACHINE=x86_64
[ "$(fedora_yazi_release_digest)" = "$FEDORA_YAZI_X86_64_SHA256" ] ||
    fail 'Yazi x86_64 release digest selector must use the pinned checksum'
[ "$FEDORA_YAZI_X86_64_SHA256" = \
    cc67eb7991550c2f9407cda52d3f5af0937627aa6884e7de99a04fcf059807e0 ] ||
    fail 'Yazi x86_64 release digest must remain pinned'
[ "$(FEDORA_YAZI_MACHINE=aarch64 fedora_yazi_release_digest)" = \
    "$FEDORA_YAZI_AARCH64_SHA256" ] ||
    fail 'Yazi aarch64 release digest selector must use the pinned checksum'
[ "$FEDORA_YAZI_AARCH64_SHA256" = \
    f5a85771f06bb0e8c488136ae0aedaec8d341a7cee995549df391d7d852fe8d1 ] ||
    fail 'Yazi aarch64 release digest must remain pinned'
fedora_yazi_release_digest() {
    if [ "$YAZI_BAD_CHECKSUM" -eq 1 ]; then
        printf '%064d\n' 0
    else
        sha256sum "$YAZI_ARCHIVE_SOURCE" | awk '{ print $1 }'
    fi
}
curl() {
    local output='' argument

    printf 'curl:%s\n' "$*" >> "$PROVIDER_CALLS"
    while [ "$#" -gt 0 ]; do
        argument=$1
        shift
        if [ "$argument" = -o ]; then
            output=$1
            shift
        fi
    done
    [ -n "$output" ] || return 2
    cp "$YAZI_ARCHIVE_SOURCE" "$output"
}
[ "$(fedora_yazi_release_url)" = \
    'https://github.com/sxyazi/yazi/releases/download/v26.8.15/yazi-x86_64-unknown-linux-gnu.zip' ] ||
    fail 'Yazi x86_64 release URL must be pinned to the official GNU ZIP'
fedora_yazi_version_output_satisfied $'Yazi\n    Version: 26.8.15 (fixture)' ||
    fail 'Yazi version parser must accept the real multi-line output'
if fedora_yazi_version_output_satisfied $'Yazi\n    Version: 26.8.16 (fixture)'; then
    fail 'Yazi version parser must reject an unpinned version'
fi
if fedora_yazi_version_output_satisfied $'Yazi\n    Version: 26.8.150 (fixture)'; then
    fail 'Yazi version parser must reject a version that only contains the pin'
fi
if fedora_yazi_version_output_satisfied $'Yazi 26.8.15'; then
    fail 'Yazi version parser must require the real Version line'
fi
fedora_yazi_version_output_satisfied $'Yazi\nVersion: 26.8.15 (fixture)' ||
    fail 'Yazi version parser must accept an unindented Version line'
fedora_application_target_satisfied yazi "$TARGET_USER" "$HOME_DIR" &&
    fail 'Yazi must be drift before release installation'
fedora_install_application_target yazi "$TARGET_USER" "$HOME_DIR" ||
    fail 'Yazi release provider did not install x86_64 binaries'
for binary in yazi ya; do
    [ -x "$HOME_DIR/.local/bin/$binary" ] ||
        fail "Yazi release provider did not install $binary"
    [ "$(stat -c '%U:%G' "$HOME_DIR/.local/bin/$binary")" = \
        "$(id -un):$(id -gn)" ] ||
        fail "Yazi release provider installed $binary with incorrect ownership"
    "$HOME_DIR/.local/bin/$binary" --version | grep -Fq 26.8.15 ||
        fail "Yazi $binary version verification failed"
done
RUNUSER_CALLS=0
fedora_yazi_target_satisfied "$TARGET_USER" "$HOME_DIR" ||
    fail 'Yazi same-user verification fixture must converge without runuser'
[ "$RUNUSER_CALLS" -eq 0 ] ||
    fail 'Yazi same-user verification must not invoke runuser'
OTHER_USER=$(awk -F: -v current_uid="$(id -u)" '$3 != current_uid { print $1; exit }' /etc/passwd)
[ -n "$OTHER_USER" ] || fail 'Yazi test requires a distinct local user fixture'
RUNUSER_CALLS=0
_fedora_yazi_run_as_target_user "$OTHER_USER" "$HOME_DIR" \
    "$HOME_DIR/.local/bin/yazi" >/dev/null ||
    fail 'Yazi different-user verification fixture must use runuser successfully'
[ "$RUNUSER_CALLS" -eq 1 ] ||
    fail 'Yazi different-user verification must invoke runuser'
cat > "$HOME_DIR/.local/bin/yazi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Yazi'
printf '%s\n' '    Version: 26.8.16 (fixture)'
EOF
chmod 755 "$HOME_DIR/.local/bin/yazi"
if fedora_application_target_satisfied yazi "$TARGET_USER" "$HOME_DIR"; then
    fail 'Yazi application verification must reject an unpinned binary version'
fi
cat > "$HOME_DIR/.local/bin/yazi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Yazi'
printf '%s\n' '    Version: 26.8.15 (fixture)'
EOF
chmod 755 "$HOME_DIR/.local/bin/yazi"
[ -x "$HOME_DIR/.local/bin/yazi" ] ||
    fail 'Yazi positive fixture must provide an executable yazi command'
rm -f "$HOME_DIR/.local/bin/ya"
if fedora_application_target_satisfied yazi "$TARGET_USER" "$HOME_DIR"; then
    fail 'Yazi application verification must reject a missing ya command'
fi
cat > "$HOME_DIR/.local/bin/ya" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Ya'
printf '%s\n' '    Version: 26.8.15 (fixture)'
EOF
chmod 755 "$HOME_DIR/.local/bin/ya"
[ "$(grep -c '^package:curl$' "$PROVIDER_CALLS" || true)" -gt 0 ] ||
    fail 'Yazi release provider must converge curl through ensure_packages'
[ "$(grep -c '^package:unzip$' "$PROVIDER_CALLS" || true)" -gt 0 ] ||
    fail 'Yazi release provider must converge unzip through ensure_packages'
[ ! -e "$HOME_DIR/.local/bin/unexpected-file" ] ||
    fail 'Yazi release provider must install only yazi and ya'
grep -Fq -- 'github.com/sxyazi/yazi/releases/download/v26.8.15/yazi-x86_64-unknown-linux-gnu.zip' \
    "$PROVIDER_CALLS" || fail 'Yazi x86_64 download URL was not used'
before_yazi_downloads=$(grep -c '^curl:' "$PROVIDER_CALLS" || true)
fedora_install_application_target yazi "$TARGET_USER" "$HOME_DIR" ||
    fail 'Yazi release provider must be idempotent'
[ "$(grep -c '^curl:' "$PROVIDER_CALLS" || true)" -eq "$before_yazi_downloads" ] ||
    fail 'Yazi idempotency must skip a correct pair of binaries'
rm -f "$HOME_DIR/.local/bin/ya"
fedora_install_application_target yazi "$TARGET_USER" "$HOME_DIR" ||
    fail 'Yazi release provider did not repair one missing binary'
[ -x "$HOME_DIR/.local/bin/yazi" ] && [ -x "$HOME_DIR/.local/bin/ya" ] ||
    fail 'Yazi missing-binary repair must restore both commands'
rm -f "$HOME_DIR/.local/bin/yazi" "$HOME_DIR/.local/bin/ya"
YAZI_BAD_CHECKSUM=1
status=0
fedora_install_application_target yazi "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -ne 0 ] || fail 'Yazi checksum mismatch must fail installation'
[ ! -e "$HOME_DIR/.local/bin/yazi" ] && [ ! -e "$HOME_DIR/.local/bin/ya" ] ||
    fail 'Yazi checksum mismatch must not install unverified binaries'
YAZI_BAD_CHECKSUM=0

TRAVERSAL_ROOT="$TEST_DIR/yazi-traversal-root"
mkdir -p "$TRAVERSAL_ROOT/root"
printf 'must not escape the archive root\n' > "$TRAVERSAL_ROOT/escape"
(cd "$TRAVERSAL_ROOT/root" && zip -q "$TEST_DIR/yazi-traversal.zip" ../escape)
YAZI_ARCHIVE_SOURCE="$TEST_DIR/yazi-traversal.zip"
status=0
fedora_install_application_target yazi "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -ne 0 ] || fail 'Yazi must reject archive entries with .. path components'
[ ! -e "$HOME_DIR/.local/bin/yazi" ] && [ ! -e "$HOME_DIR/.local/bin/ya" ] ||
    fail 'Unsafe Yazi archive must not install binaries'

REAL_UNZIP=$(command -v unzip)
ABSOLUTE_ARCHIVE="$TEST_DIR/yazi-absolute.zip"
EMPTY_ARCHIVE="$TEST_DIR/yazi-empty.zip"
touch "$ABSOLUTE_ARCHIVE" "$EMPTY_ARCHIVE"
unzip() {
    if [ "${1:-}" = -Z1 ]; then
        case "${2:-}" in
            "$ABSOLUTE_ARCHIVE") printf '/etc/passwd\n'; return 0 ;;
            "$EMPTY_ARCHIVE") printf '\n'; return 0 ;;
        esac
    fi
    "$REAL_UNZIP" "$@"
}
status=0
fedora_yazi_archive_entries_safe "$ABSOLUTE_ARCHIVE" \
    yazi-x86_64-unknown-linux-gnu || status=$?
[ "$status" -ne 0 ] || fail 'Yazi must reject absolute archive paths'
status=0
fedora_yazi_archive_entries_safe "$EMPTY_ARCHIVE" \
    yazi-x86_64-unknown-linux-gnu || status=$?
[ "$status" -ne 0 ] || fail 'Yazi must reject empty archive listings'
unset -f unzip

YAZI_ARCHIVE_SOURCE="$TEST_DIR/yazi-aarch64.zip"
FEDORA_YAZI_MACHINE=aarch64
[ "$(fedora_yazi_release_url)" = \
    'https://github.com/sxyazi/yazi/releases/download/v26.8.15/yazi-aarch64-unknown-linux-gnu.zip' ] ||
    fail 'Yazi aarch64 release URL must be pinned to the official GNU ZIP'
AARCH_HOME="$TEST_DIR/aarch64-home"
mkdir -p "$AARCH_HOME"
fedora_install_application_target yazi "$TARGET_USER" "$AARCH_HOME" ||
    fail 'Yazi release provider did not install aarch64 binaries'
[ -x "$AARCH_HOME/.local/bin/yazi" ] && [ -x "$AARCH_HOME/.local/bin/ya" ] ||
    fail 'Yazi aarch64 install must produce both commands'
for binary in yazi ya; do
    [ "$(stat -c '%U:%G' "$AARCH_HOME/.local/bin/$binary")" = \
        "$(id -un):$(id -gn)" ] ||
        fail "Yazi aarch64 installed $binary with incorrect ownership"
done
grep -Fq -- 'github.com/sxyazi/yazi/releases/download/v26.8.15/yazi-aarch64-unknown-linux-gnu.zip' \
    "$PROVIDER_CALLS" || fail 'Yazi aarch64 download URL was not used'

FEDORA_YAZI_MACHINE=riscv64
status=0
fedora_install_application_target yazi "$TARGET_USER" "$HOME_DIR" || status=$?
[ "$status" -gt 1 ] || fail 'Yazi unknown architecture must fail explicitly'
! grep -Eiq 'cargo|git clone|rust-lld' "$PROVIDER_CALLS" ||
    fail 'Yazi release provider must not use Cargo, clone, or rust-lld'
FEDORA_YAZI_MACHINE=x86_64

unset FEDORA_FD_RDD_INSTALL_SCRIPT
SAVED_PATH="$PATH"
PATH="$BIN_DIR:/usr/local/sbin:/usr/local/bin"
status=0
fedora_install_application_target fd-rdd-git "$TARGET_USER" "$HOME_DIR" ||
    status=$?
PATH="$SAVED_PATH"
[ "$status" -eq "$RC_SKIPPED" ] ||
    fail 'fd-rdd without a local installer must be pending, not a network failure'

DOWNLOAD_DIR="$HOME_DIR/下载"
mkdir -p "$HOME_DIR/.config" "$DOWNLOAD_DIR"
printf 'XDG_DOWNLOAD_DIR="$HOME/下载"\n' > "$HOME_DIR/.config/user-dirs.dirs"
touch "$DOWNLOAD_DIR/example-1.0.x86_64.rpm"
unset FEDORA_RPM_DIR SHORIN_ARTIFACT_DIR
[ "$(fedora_rpm_file 'example*.rpm')" = \
    "$DOWNLOAD_DIR/example-1.0.x86_64.rpm" ] ||
    fail 'Fedora artifact discovery must include the target user Chinese Downloads directory'

[[ " ${LUTRIS_CONFIG_PACKAGES[*]} " == *' alsa-plugins-pulseaudio '* ]] ||
    fail 'Fedora Lutris contract must use alsa-plugins-pulseaudio'
[[ " ${LUTRIS_CONFIG_PACKAGES[*]} " == *' gstreamer1-plugins-base '* ]] ||
    fail 'Fedora Lutris contract must use gstreamer1-plugins-base'
[[ " ${LUTRIS_CONFIG_PACKAGES[*]} " != *' gst-plugins-base-libs '* ]] ||
    fail 'Fedora Lutris contract must not request the nonexistent gst-plugins-base-libs package'
[[ " ${LUTRIS_CONFIG_PACKAGES[*]} " == *' openal-soft '* ]] ||
    fail 'Fedora Lutris contract must use openal-soft for 64-bit OpenAL'
[[ " ${LUTRIS_CONFIG_PACKAGES[*]} " == *' openal-soft.i686 '* ]] ||
    fail 'Fedora Lutris contract must use openal-soft.i686 for 32-bit OpenAL'
[[ " ${LUTRIS_CONFIG_PACKAGES[*]} " != *' openal '* ]] ||
    fail 'Fedora Lutris contract must not request the nonexistent openal package'
[[ " ${LUTRIS_CONFIG_PACKAGES[*]} " != *' lib32-openal '* ]] ||
    fail 'Fedora Lutris contract must translate away the Arch lib32-openal target'
for font_package in liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts; do
    [[ " ${LUTRIS_CONFIG_PACKAGES[*]} " == *" $font_package "* ]] ||
        fail "Fedora Lutris contract must use $font_package"
done
[[ " ${LUTRIS_CONFIG_PACKAGES[*]} " != *' liberation-fonts '* ]] ||
    fail 'Fedora Lutris contract must not request the nonexistent liberation-fonts package'
[[ " ${LUTRIS_CONFIG_PACKAGES[*]} " != *' ttf-liberation '* ]] ||
    fail 'Fedora Lutris contract must not request the Arch font name'
[ "$(fedora_arch_target_name gstreamer1-plugins-base)" = gstreamer1-plugins-base ] ||
    fail 'Fedora package whitelist must accept the verified Lutris GStreamer package'
if fedora_arch_target_name gst-plugins-base-libs >/dev/null 2>&1; then
    fail 'Fedora package whitelist must reject the nonexistent Lutris GStreamer package'
fi
[ "$(fedora_arch_target_name openal)" = openal-soft ] ||
    fail 'Fedora openal target must map to openal-soft'
[ "$(fedora_arch_target_name lib32-openal)" = openal-soft.i686 ] ||
    fail 'Fedora lib32-openal target must map to openal-soft.i686'
[ "$(fedora_arch_target_name openal-soft)" = openal-soft ] ||
    fail 'Fedora package whitelist must accept openal-soft'
[ "$(fedora_arch_target_name openal-soft.i686)" = openal-soft.i686 ] ||
    fail 'Fedora package whitelist must accept openal-soft.i686'
for font_package in liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts; do
    [ "$(fedora_arch_target_name "$font_package")" = "$font_package" ] ||
        fail "Fedora package whitelist must accept $font_package"
done
if fedora_arch_target_name liberation-fonts >/dev/null 2>&1; then
    fail 'Fedora package whitelist must reject the nonexistent liberation-fonts package'
fi
if fedora_arch_target_name ttf-liberation >/dev/null 2>&1; then
    fail 'Fedora package whitelist must reject the Arch-only ttf-liberation target'
fi
INSTALLED_PACKAGES[lutris]=1
for package in "${LUTRIS_CONFIG_PACKAGES[@]}"; do
    INSTALLED_PACKAGES["$package"]=1
done
ensure_lutris_config || fail 'Fedora Lutris apply must install both OpenAL architectures'
grep -Fqx 'package:openal-soft' "$PROVIDER_CALLS" ||
    fail 'Fedora Lutris apply must install openal-soft'
grep -Fqx 'package:openal-soft.i686' "$PROVIDER_CALLS" ||
    fail 'Fedora Lutris apply must install openal-soft.i686'
for font_package in liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts; do
    grep -Fqx "package:$font_package" "$PROVIDER_CALLS" ||
        fail "Fedora Lutris apply must install $font_package"
done
application_entry_satisfied lutris ||
    fail 'Fedora Lutris contract must accept both OpenAL architectures'
INSTALLED_PACKAGES[openal-soft.i686]=0
application_entry_satisfied lutris &&
    fail 'Missing Fedora 32-bit OpenAL must be reported as Lutris drift'
INSTALLED_PACKAGES[openal-soft.i686]=1
INSTALLED_PACKAGES[openal-soft]=0
application_entry_satisfied lutris &&
    fail 'Missing Fedora 64-bit OpenAL must be reported as Lutris drift'
INSTALLED_PACKAGES[openal-soft]=1

QUERY_ERROR=1
before_query_error_calls=$(wc -l < "$PROVIDER_CALLS")
status=0
fedora_install_application_target code "$TARGET_USER" "$HOME_DIR" ||
    status=$?
[ "$status" -eq 2 ] ||
    fail 'Fedora provider query errors must propagate instead of attempting installation'
[ "$(wc -l < "$PROVIDER_CALLS")" -eq "$before_query_error_calls" ] ||
    fail 'Fedora provider query errors must not trigger a provider mutation'

printf 'PASS: Fedora application provider contracts and artifact handoff\n'
