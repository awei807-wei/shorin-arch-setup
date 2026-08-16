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

mkdir -p "$HOME_DIR/.cargo/bin"
cat > "$HOME_DIR/.cargo/bin/yazi" <<EOF
#!/usr/bin/env bash
printf 'yazi %s\\n' "$FEDORA_YAZI_CARGO_VERSION"
EOF
cat > "$HOME_DIR/.cargo/bin/ya" <<EOF
#!/usr/bin/env bash
printf 'ya %s\\n' "$FEDORA_YAZI_CARGO_VERSION"
EOF
chmod 755 "$HOME_DIR/.cargo/bin/yazi" "$HOME_DIR/.cargo/bin/ya"
runuser() {
    [ "${1:-}" = -u ] && shift 2
    [ "${1:-}" = -- ] && shift
    "$@"
}
fedora_application_target_satisfied yazi "$TARGET_USER" "$HOME_DIR" ||
    fail 'Yazi check must accept both pinned cargo binaries'
cat > "$BIN_DIR/cargo" <<'EOF'
#!/usr/bin/env bash
printf 'cargo:%s\n' "$*" >> "${PROVIDER_CALLS:?}"
mkdir -p "$HOME/.cargo/bin"
cat > "$HOME/.cargo/bin/yazi" <<'YAZI'
#!/usr/bin/env bash
printf 'yazi 26.8.15\n'
YAZI
cat > "$HOME/.cargo/bin/ya" <<'YA'
#!/usr/bin/env bash
printf 'ya 26.8.15\n'
YA
chmod 755 "$HOME/.cargo/bin/yazi" "$HOME/.cargo/bin/ya"
EOF
chmod 755 "$BIN_DIR/cargo"
rm -f "$HOME_DIR/.cargo/bin/ya"
fedora_install_application_target yazi "$TARGET_USER" "$HOME_DIR" ||
    fail 'Yazi cargo provider did not install a missing binary'
fedora_yazi_target_satisfied "$TARGET_USER" "$HOME_DIR" ||
    fail 'Yazi cargo provider must verify yazi and ya'
grep -Fq -- '--force --version 26.8.15 yazi-build' "$PROVIDER_CALLS" ||
    fail 'Yazi provider must use the official yazi-build meta-crate with a pinned version'

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
