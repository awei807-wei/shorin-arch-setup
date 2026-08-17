#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SHORIN_DISTRO=fedora
TEST_DIR=$(mktemp -d)
BIN_DIR="$TEST_DIR/bin"
RPM_INSTALLED="$TEST_DIR/rpm-installed"
RPM_GROUP_MARKER="$TEST_DIR/rpm-group-installed"
RPM_CALLS="$TEST_DIR/rpm-calls"
DNF_CALLS="$TEST_DIR/dnf-calls"
HOME_DIR="$TEST_DIR/home"
mkdir -p "$BIN_DIR" "$HOME_DIR"
: > "$RPM_INSTALLED"
: > "$RPM_CALLS"
: > "$DNF_CALLS"
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

cat > "$BIN_DIR/rpm" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf 'rpm:%s\n' "$*" >> "${RPM_CALLS:?}"
case "${1:-}" in
    -qa)
        case "${RPM_MODE:-all}" in
            sigpipe)
                # The old implementation put this producer before grep -q.
                # Simulate rpm being killed after grep closes that pipe.
                printf 'gcc-14.2.1-1.fc42.x86_64\n'
                exit 141
                ;;
            error) exit 7 ;;
            missing)
                if [ ! -e "${RPM_GROUP_MARKER:?}" ]; then
                    printf 'gcc-14.2.1-1.fc42.x86_64\nmake-4.4.1-1.fc42.x86_64\n'
                else
                    printf 'gcc-14.2.1-1.fc42.x86_64\n'
                    printf 'make-4.4.1-1.fc42.x86_64\n'
                    printf 'binutils-2.43-1.fc42.x86_64\n'
                fi
                ;;
            *)
                printf 'gcc-14.2.1-1.fc42.x86_64\n'
                printf 'make-4.4.1-1.fc42.x86_64\n'
                printf 'binutils-2.43-1.fc42.x86_64\n'
                ;;
        esac
        ;;
    -q)
        if [ "${2:-}" = --qf ]; then
            package=${4:-}
            grep -Fqx "$package" "${RPM_INSTALLED:?}" || exit 1
            printf '1-1.fc44\n'
            exit 0
        fi
        package=${2:-}
        grep -Fqx "$package" "${RPM_INSTALLED:?}"
        ;;
    *) exit 64 ;;
esac
EOF
cat > "$BIN_DIR/dnf" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'dnf:%s\n' "$*" >> "${DNF_CALLS:?}"
if [ "${DNF_STATUS:-0}" -ne 0 ]; then
    exit "$DNF_STATUS"
fi
case "${1:-}" in
    repolist)
        printf '%s\n' 'repo id                         repo name' 'fedora Fedora 44'
        if [ "${DNF_REPOS:-default}" = default ]; then
            printf '%s\n' \
                'rpmfusion-nonfree-nvidia-driver RPM Fusion NVIDIA' \
                'rpmfusion-free-updates RPM Fusion Free Updates'
        fi
        ;;
    repoquery)
        [ "${DNF_REPOQUERY_EMPTY:-0}" -eq 1 ] || printf '%s\n' "${!#}"
        ;;
    install)
        package=${!#}
        if [ "$package" = @c-development ]; then
            # The mock records the group action; subsequent rpm -qa queries
            # expose the representative RPMs that the group contract checks.
            : > "${RPM_INSTALLED:?}"
            touch "${RPM_GROUP_MARKER:?}"
        else
            printf '%s\n' "$package" >> "${RPM_INSTALLED:?}"
        fi
        ;;
esac
EOF
chmod +x "$BIN_DIR/rpm" "$BIN_DIR/dnf"

export PATH="$BIN_DIR:$PATH"
export RPM_CALLS RPM_INSTALLED RPM_GROUP_MARKER DNF_CALLS DNF_STATUS
export DNF_REPOQUERY_EMPTY DNF_REPOS
export RPM_MODE
export SHORIN_DISTRO=fedora SHORIN_MODE=repair SHORIN_READ_ONLY=0
export TARGET_USER=$(id -un) HOME_DIR
export PACKAGE_SOURCE_DIR="$TEST_DIR/package-sources"
export SHORIN_ROOT="$ROOT_DIR" SHORIN_SCRIPTS_DIR="$ROOT_DIR/scripts"

source "$ROOT_DIR/scripts/lib/core.sh"

# Reproduce the pre-fix failure: rpm is the producer in a grep -q pipeline,
# and pipefail exposes its SIGPIPE status as 141 even though grep matched.
legacy_base_devel_query() {
    rpm -qa 2>/dev/null | grep -Eqi '(^|-)gcc|(^|-)make|(^|-)binutils'
}
RPM_MODE=sigpipe
status=0
legacy_base_devel_query || status=$?
[ "$status" -eq 141 ] || fail "legacy Fedora group query must reproduce 141 (got $status)"

# The fixed query reads the producer to completion, distinguishes a missing
# group (1), and keeps a genuine rpm failure in the inspection-error range.
RPM_MODE=all
state_package_present base-devel || fail 'Fedora C development group must satisfy with all representative RPMs'
RPM_MODE=missing
status=0
state_package_present base-devel || status=$?
[ "$status" -eq 1 ] || fail "missing Fedora C development group must be drift (got $status)"
RPM_MODE=error
status=0
state_package_present base-devel || status=$?
[ "$status" -gt 1 ] || fail "rpm query failure must remain an inspection error (got $status)"
rm -f "$DNF_CALLS"
RPM_MODE=error
status=0
ensure_package base-devel || status=$?
[ "$status" -gt 1 ] || fail "ensure_package must not turn rpm query errors into drift (got $status)"
[ ! -s "$DNF_CALLS" ] || fail 'ensure_package must not invoke dnf when rpm inspection is unavailable'

# Apply must use the same logical mapping as check: @c-development is the
# Fedora group target matching Arch base-devel, never a raw Arch package name.
RPM_MODE=missing
rm -f "$RPM_GROUP_MARKER"
DNF_STATUS=0
ensure_package base-devel || fail 'Fedora base-devel apply must converge in the mock'
grep -Fqx 'dnf:install -y --setopt=install_weak_deps=False @c-development' "$DNF_CALLS" ||
    fail 'Fedora base-devel apply must install the DNF C Development Tools group'

# Fedora 44 package translations are explicit and must not silently collapse
# distinct logical targets into one package.
expect_mapping() {
    local logical=$1 expected=$2 actual
    actual=$(fedora_arch_target_name "$logical") ||
        fail "Fedora mapping is missing: $logical"
    [ "$actual" = "$expected" ] ||
        fail "Fedora mapping $logical -> $actual (expected $expected)"
}
expect_mapping adobe-source-han-sans-cn-fonts adobe-source-han-sans-cn-fonts
expect_mapping adobe-source-han-serif-cn-fonts adobe-source-han-serif-cn-fonts
expect_mapping base-devel @c-development
expect_mapping sof-firmware alsa-sof-firmware
expect_mapping noto-fonts google-noto-sans-fonts
expect_mapping noto-fonts-cjk google-noto-sans-cjk-fonts
expect_mapping noto-fonts-emoji google-noto-color-emoji-fonts
expect_mapping pipewire-pulse pipewire-pulseaudio
expect_mapping pipewire-jack pipewire-jack-audio-connection-kit
expect_mapping terminus-font terminus-fonts-console
expect_mapping terminus-fonts-console terminus-fonts-console
expect_mapping vim vim-enhanced
expect_mapping intel-media-driver libva-intel-media-driver
expect_mapping gst-plugins-base gstreamer1-plugins-base
expect_mapping gst-plugins-good gstreamer1-plugins-good
expect_mapping gst-libav gstreamer1-plugin-libav
expect_mapping qt6-wayland qt6-qtwayland
expect_mapping qt6-multimedia qt6-qtmultimedia
expect_mapping polkit-gnome polkit-kde
[ "$(fedora_package_repository akmod-nvidia)" = \
    rpmfusion-nonfree-nvidia-driver ] || fail 'NVIDIA package repository contract is missing'
[ "$(fedora_package_repository mesa-va-drivers-freeworld)" = \
    rpmfusion-free-updates ] || fail 'AMD freeworld package repository contract is missing'
if fedora_arch_target_name awww >/dev/null 2>&1; then
    fail 'Fedora awww must use the verified upstream source installer, not dnf'
fi
if fedora_arch_target_name mesa >/dev/null 2>&1; then
    fail 'Fedora must reject the nonexistent mesa meta package'
fi
if fedora_arch_target_name mesa-va-drivers >/dev/null 2>&1; then
    fail 'Fedora must reject the nonexistent mesa-va-drivers target'
fi

# Repository-backed packages must be checked in the configured (possibly
# disabled) repository before dnf install.  DNF5's empty repoquery result is
# drift, not success, and an absent repository is a clear precondition error.
: > "$RPM_INSTALLED"
: > "$DNF_CALLS"
RPM_MODE=missing
DNF_REPOS=default
DNF_REPOQUERY_EMPTY=0
DNF_STATUS=9
status=0
ensure_package niri 2>"$TEST_DIR/dnf-error" || status=$?
if [ "$status" -eq 0 ]; then
    fail 'dnf failures must not claim Fedora package convergence'
fi
[ "$status" -eq 9 ] || fail "dnf failure status must be preserved (got $status)"
DNF_STATUS=0
ensure_package akmod-nvidia || fail 'NVIDIA package must converge through RPM Fusion mock'
grep -Fq -- '--enablerepo=rpmfusion-nonfree-nvidia-driver akmod-nvidia' "$DNF_CALLS" ||
    fail 'NVIDIA dnf calls must enable the configured RPM Fusion repository'
grep -Fq -- 'dnf:install -y --setopt=install_weak_deps=False --enablerepo=rpmfusion-nonfree-nvidia-driver akmod-nvidia' "$DNF_CALLS" ||
    fail 'NVIDIA install must use the RPM Fusion repository explicitly'
: > "$DNF_CALLS"
: > "$RPM_INSTALLED"
ensure_package mesa-va-drivers-freeworld ||
    fail 'AMD Mesa VA freeworld package must converge through RPM Fusion mock'
grep -Fq -- 'dnf:install -y --setopt=install_weak_deps=False --enablerepo=rpmfusion-free-updates mesa-va-drivers-freeworld' "$DNF_CALLS" ||
    fail 'AMD freeworld install must use the RPM Fusion repository explicitly'
: > "$DNF_CALLS"
: > "$RPM_INSTALLED"
DNF_REPOS=without-nvidia-repo
if ensure_package akmod-nvidia 2>"$TEST_DIR/nvidia-repo-error"; then
    fail 'NVIDIA package must fail when its RPM Fusion repository is not configured'
fi
! grep -Fq 'dnf:install' "$DNF_CALLS" ||
    fail 'NVIDIA package must not install without its repository precondition'
grep -Fq 'rpmfusion-nonfree-nvidia-driver' "$TEST_DIR/nvidia-repo-error" ||
    fail 'NVIDIA missing-repository error must identify the required repo'
: > "$DNF_CALLS"
: > "$RPM_INSTALLED"
DNF_REPOS=default
DNF_REPOQUERY_EMPTY=1
if ensure_package akmod-nvidia 2>"$TEST_DIR/nvidia-query-error"; then
    fail 'empty Fedora repoquery output must not claim NVIDIA availability'
fi
! grep -Fq 'dnf:install' "$DNF_CALLS" ||
    fail 'empty Fedora repoquery output must block installation'
DNF_REPOQUERY_EMPTY=0

source "$ROOT_DIR/scripts/modules/base/targets.sh"
mapfile -t FEDORA_BASE_PACKAGES < <(base_declared_packages)
printf '%s\n' "${FEDORA_BASE_PACKAGES[@]}" | grep -Fqx glibc-langpack-zh ||
    fail 'Fedora base check/apply contract must include glibc-langpack-zh'
printf '%s\n' "${FEDORA_BASE_PACKAGES[@]}" | grep -Fqx terminus-fonts-console ||
    fail 'Fedora base contract must install terminus-fonts-console'

# Fedora's terminus-fonts-console package owns the exact ter-v28n file.  The
# same fixed file and result contract must drive check/apply/verify, while
# Arch retains the ter-v28n logical font name as before.
DEFAULT_VCONSOLE_FONT_FILE=$BASE_VCONSOLE_FONT_FILE
BASE_VCONSOLE_FONT_FILE="$TEST_DIR/ter-v28n.psf.gz"
printf 'font\n' > "$BASE_VCONSOLE_FONT_FILE"
[ "$(base_vconsole_font)" = ter-v28n ] ||
    fail 'Fedora vconsole contract must keep the ter-v28n font'
base_vconsole_font_file_present ||
    fail 'Fedora vconsole contract must require the ter-v28n font file'
VCONSOLE_SYSTEMCTL_RESULT=success
systemctl() {
    [ "${1:-}" = show ] || return 64
    printf '%s\n' "$VCONSOLE_SYSTEMCTL_RESULT"
}
base_vconsole_setup_succeeded ||
    fail 'successful systemd-vconsole-setup must satisfy the Fedora contract'
VCONSOLE_SYSTEMCTL_RESULT=failed
status=0
base_vconsole_setup_succeeded || status=$?
[ "$status" -eq 1 ] ||
    fail 'failed systemd-vconsole-setup must remain a verification failure'
rm -f "$BASE_VCONSOLE_FONT_FILE"
status=0
base_vconsole_font_file_present || status=$?
[ "$status" -eq 1 ] ||
    fail 'missing Fedora vconsole font file must be reported as drift'
export SHORIN_DISTRO=arch
[ "$(base_vconsole_font)" = ter-v28n ] ||
    fail 'Arch vconsole font contract must remain ter-v28n'
export SHORIN_DISTRO=fedora
[ "$DEFAULT_VCONSOLE_FONT_FILE" = /usr/lib/kbd/consolefonts/ter-v28n.psf.gz ] ||
    fail 'Fedora vconsole contract must declare the verified font path'

# Fedora GPU targets must follow detected vendors. Mesa is the common runtime;
# vendor driver families must not leak across Intel/AMD/NVIDIA hardware.
base_gpu_info() {
    printf '%s\n' '00:02.0 "VGA compatible controller" "Intel Corporation" "UHD Graphics"'
}
mapfile -t GPU_TARGETS < <(base_gpu_target_packages)
printf '%s\n' "${GPU_TARGETS[@]}" | grep -Fqx intel-media-driver ||
    fail 'Fedora Intel GPU must select intel-media-driver'
if printf '%s\n' "${GPU_TARGETS[@]}" | grep -Eq '^mesa$|akmod-nvidia|xorg-x11-drv-nvidia-cuda|mesa-va-drivers-freeworld|mesa-libOpenCL'; then
    fail 'Fedora Intel GPU must not select NVIDIA or AMD-only targets'
fi
base_gpu_info() {
    printf '%s\n' '01:00.0 "VGA compatible controller" "NVIDIA Corporation" "RTX 4060"'
}
mapfile -t GPU_TARGETS < <(base_gpu_target_packages)
printf '%s\n' "${GPU_TARGETS[@]}" | grep -Fqx akmod-nvidia ||
    fail 'Fedora NVIDIA GPU must select akmod-nvidia'
if printf '%s\n' "${GPU_TARGETS[@]}" | grep -Eq 'intel-media-driver|intel-compute-runtime|mesa-va-drivers-freeworld|mesa-libOpenCL|^mesa$'; then
    fail 'Fedora NVIDIA GPU must not select Intel or AMD-only targets'
fi
base_gpu_info() {
    printf '%s\n' '02:00.0 "VGA compatible controller" "AMD/ATI" "Radeon RX"'
}
mapfile -t GPU_TARGETS < <(base_gpu_target_packages)
printf '%s\n' "${GPU_TARGETS[@]}" | grep -Fqx mesa-va-drivers-freeworld ||
    fail 'Fedora AMD GPU must select Mesa VA drivers'
if printf '%s\n' "${GPU_TARGETS[@]}" | grep -Eq 'akmod-nvidia|intel-media-driver|intel-compute-runtime|^mesa$'; then
    fail 'Fedora AMD GPU must not select Intel or NVIDIA-only targets'
fi

# The Fedora 44 machine has Intel UHD 610 and NVIDIA GTX 1650 Mobile.  Both
# vendor families are selected, while the ATI substring in "compatible" does
# not spuriously add AMD packages.
base_gpu_info() {
    printf '%s\n' \
        '00:02.0 "VGA compatible controller" "Intel Corporation" "UHD Graphics 610"' \
        '01:00.0 "3D controller" "NVIDIA Corporation" "GTX 1650 Mobile"'
}
mapfile -t GPU_TARGETS < <(base_gpu_target_packages)
printf '%s\n' "${GPU_TARGETS[@]}" | grep -Fqx intel-media-driver ||
    fail 'hybrid Intel/NVIDIA GPU must retain Intel targets'
printf '%s\n' "${GPU_TARGETS[@]}" | grep -Fqx akmod-nvidia ||
    fail 'hybrid Intel/NVIDIA GPU must retain NVIDIA targets'
if printf '%s\n' "${GPU_TARGETS[@]}" | grep -Eq 'mesa-va-drivers-freeworld|mesa-libOpenCL'; then
    fail 'hybrid Intel/NVIDIA GPU must not select AMD-only targets from compatible text'
fi

# Fedora desktop target enumeration translates only declared mappings and
# explicitly skips unsupported optional AUR artifacts. The output consumed by
# check/apply/verify therefore contains no AUR target that could reach dnf.
source "$ROOT_DIR/scripts/modules/desktop-niri/targets.sh"
LIST_FILE="$TEST_DIR/niri-applist.txt"
MANIFEST="$TEST_DIR/niri-packages.list"
: > "$LIST_FILE"
printf '%s\n' awww polkit-gnome AUR:wlogout AUR:clipse AUR:waypaper AUR:ddcutil-service \
    AUR:ttf-jetbrains-maple-mono-nf-xx-xx AUR:swaylock-effects \
    AUR:ttf-lxgw-wenkai-screen AUR:python-pywalfox AUR:niriswitcher \
    AUR:unknown-aur-target bluetui hyprpicker nwg-look satty starship swayosd \
    breeze breeze5 breeze-icons imagemagick > "$MANIFEST"
mapfile -t TARGETS < <(niri_all_package_targets "$MANIFEST" "$LIST_FILE")
if printf '%s\n' "${TARGETS[@]}" | grep -Eq '^AUR:'; then
    fail 'Fedora desktop target contract must not expose raw AUR targets'
fi
if printf '%s\n' "${TARGETS[@]}" | grep -Fxq swww; then
    fail 'Fedora desktop target contract must not migrate awww to legacy swww'
fi
for target in wlogout ddcutil ttf-jetbrains-maple-mono-nf-xx-xx swaylock; do
    printf '%s\n' "${TARGETS[@]}" | grep -Fqx "$target" ||
        fail "Fedora desktop target translation is missing $target"
done
for target in ttf-jetbrains-mono-nerd ttf-jetbrains-maple-mono-nf-xx-xx; do
    if fedora_arch_target_name "$target" >/dev/null 2>&1; then
        fail "Fedora exact font target must not map to ordinary jetbrains-mono-fonts: $target"
    fi
done
if fedora_arch_target_name starship >/dev/null 2>&1; then
    fail 'Fedora Starship target must use the target-user provider, not DNF'
fi
for mapping in \
    'breeze=plasma-breeze' \
    'breeze5=kf5-qqc2-breeze-style' \
    'breeze-icons=breeze-icon-theme' \
    'imagemagick=ImageMagick'; do
    logical=${mapping%%=*}
    expected=${mapping#*=}
    actual=$(fedora_arch_target_name "$logical") ||
        fail "Fedora desktop mapping is missing $logical"
    [ "$actual" = "$expected" ] ||
        fail "Fedora desktop mapping $logical -> $actual (expected $expected)"
    printf '%s\n' "${TARGETS[@]}" | grep -Fqx "$logical" ||
        fail "Fedora target enumeration dropped mapped optional target $logical"
done
for target in clipse waypaper nautilus-open-any-terminal; do
    if printf '%s\n' "${TARGETS[@]}" | grep -Fqx "$target"; then
        fail "unsupported Fedora optional target must be skipped: $target"
    fi
done
for target in python-pywalfox niriswitcher ttf-lxgw-wenkai-screen; do
    if printf '%s\n' "${TARGETS[@]}" | grep -Fqx "$target"; then
        fail "unsupported Fedora optional target must be skipped: $target"
    fi
done
for target in bluetui hyprpicker nwg-look satty swayosd; do
    if printf '%s\n' "${TARGETS[@]}" | grep -Fqx "$target"; then
        fail "unavailable Fedora optional target must be skipped: $target"
    fi
done
if printf '%s\n' "$(niri_required_package_targets)" | grep -Eq '^AUR:'; then
    fail 'Fedora required desktop targets must use native package names'
fi
printf '%s\n' "$(niri_required_package_targets)" | grep -Fqx polkit-kde ||
    fail 'Fedora desktop required set must use polkit-kde'
printf '%s\n' "$(niri_required_package_targets)" | grep -Fqx awww ||
    fail 'Fedora desktop required set must keep the upstream awww target'
if printf '%s\n' "$(niri_required_package_targets)" | grep -Eq '^swww$|^polkit-gnome$'; then
    fail 'Fedora desktop required set must not require legacy swww/polkit-gnome'
fi
fedora_awww_source_contract_valid ||
    fail 'Fedora awww source contract must point to the pinned official Codeberg archive'
mkdir -p "$HOME_DIR/.local/bin"
printf '#!/usr/bin/env bash\nprintf "awww 0.12.1\\n"\n' > "$HOME_DIR/.local/bin/awww"
printf '#!/usr/bin/env bash\nprintf "awww-daemon 0.12.1\\n"\n' > "$HOME_DIR/.local/bin/awww-daemon"
chmod +x "$HOME_DIR/.local/bin/awww" "$HOME_DIR/.local/bin/awww-daemon"
fedora_awww_satisfied "$TARGET_USER" "$HOME_DIR" ||
    fail 'Fedora awww command contract must require both pinned-version binaries'
for target in $(niri_required_package_targets); do
    if [ "$target" = awww ]; then
        continue
    fi
    mapped=$(fedora_arch_target_name "$target") ||
        fail "Fedora required target has no mapping: $target"
    platform_dnf_package_available "$mapped" ||
        fail "Fedora required target has no non-empty repoquery result: $target -> $mapped"
done
for unsupported in clipse clipse-gui waypaper niriswitcher python-pywalfox \
    ttf-lxgw-wenkai-screen nautilus-open-any-terminal; do
    if fedora_arch_target_name "AUR:$unsupported" >/dev/null 2>&1; then
        fail "unsupported Fedora AUR target must not have a dnf mapping: $unsupported"
    fi
done

# Check/apply/verify must share the same Fedora wallpaper backend contract.
# Fedora QuickShell conversion belongs to the staged source deployment; the
# session path may migrate Niri/Waypaper config but must never rewrite live
# QuickShell drift.
NIRI_CONFIG_FILE="$HOME_DIR/niri.kdl"
NIRI_BINDS_FILE="$HOME_DIR/binds.kdl"
NIRI_LOCAL_BIN="$HOME_DIR/.local/bin"
NIRI_QUICKSHELL_DIR="$HOME_DIR/quickshell"
NIRI_LOCKSCREEN_SCRIPT_FILE="$NIRI_QUICKSHELL_DIR/scripts/lockscreen.sh"
NIRI_WAYPAPER_CONFIG_FILE="$HOME_DIR/waypaper.ini"
NIRI_DESKTOP_STATE_DIR="$HOME_DIR/desktop-state"
NIRI_QUICKSHELL_BACKUP_DIR="$NIRI_DESKTOP_STATE_DIR/quickshell-backups"
NIRI_QUICKSHELL_SOURCE_STATE_FILE="$NIRI_DESKTOP_STATE_DIR/quickshell-source"
FEDORA_QUICKSHELL_CHECKOUT="$TEST_DIR/fedora-quickshell-source"
desktop_niri_contract_init
mkdir -p "$FEDORA_QUICKSHELL_CHECKOUT/dotfiles/.config/quickshell/scripts" \
    "$FEDORA_QUICKSHELL_CHECKOUT/dotfiles/.config/quickshell/lockscreen" \
    "$FEDORA_QUICKSHELL_CHECKOUT/dotfiles/.config/quickshell/config"
printf 'import QtQuick 2.0\n' \
    > "$FEDORA_QUICKSHELL_CHECKOUT/dotfiles/.config/quickshell/shell.qml"
cat > "$FEDORA_QUICKSHELL_CHECKOUT/dotfiles/.config/quickshell/lockscreen/shell.qml" <<'EOF'
import QtQuick 2.0
command: ["sh", "-c", "swww query"]
EOF
printf 'module Shorin.Config\n' \
    > "$FEDORA_QUICKSHELL_CHECKOUT/dotfiles/.config/quickshell/config/qmldir"
printf '#!/usr/bin/env bash\n' \
    > "$FEDORA_QUICKSHELL_CHECKOUT/dotfiles/.config/quickshell/scripts/lockscreen.sh"
chmod 755 \
    "$FEDORA_QUICKSHELL_CHECKOUT/dotfiles/.config/quickshell/scripts/lockscreen.sh"
ln -s ../config \
    "$FEDORA_QUICKSHELL_CHECKOUT/dotfiles/.config/quickshell/lockscreen/config"
git init -q -b main "$FEDORA_QUICKSHELL_CHECKOUT"
git -C "$FEDORA_QUICKSHELL_CHECKOUT" add .
git -C "$FEDORA_QUICKSHELL_CHECKOUT" \
    -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit -q -m fixture
mkdir -p "$NIRI_QUICKSHELL_DIR"
cat > "$NIRI_CONFIG_FILE" <<'EOF'
spawn-at-startup "swww-daemon"
spawn-at-startup "quickshell -p ~/.config/quickshell/lockscreen/shell.qml"
EOF
cat > "$NIRI_BINDS_FILE" <<EOF
binds {
    Mod+Alt+L { spawn-sh "$NIRI_LOCKSCREEN_SCRIPT_FILE"; }
}
EOF
printf '[Settings]\nbackend = swww\n' > "$NIRI_WAYPAPER_CONFIG_FILE"
niri_quickshell_stage_and_deploy \
    "$FEDORA_QUICKSHELL_CHECKOUT" "$TARGET_USER" ||
    fail 'Fedora QuickShell source must convert wallpaper references in staging'
niri_quickshell_deployment_state_satisfied ||
    fail 'Fedora staged QuickShell conversion must satisfy the deployment state'
ensure_niri_fedora_session_compatibility "$TARGET_USER" ||
    fail 'Fedora session compatibility must install the initializer before wallpaper convergence'
ensure_niri_wallpaper_backend "$TARGET_USER" ||
    fail 'Fedora wallpaper apply must accept initializer-managed Niri startup without live QuickShell edits'
ensure_niri_waypaper_backend "$TARGET_USER" ||
    fail 'Fedora Waypaper contract must migrate to awww'
[ "$(niri_wallpaper_backend_name)" = awww ] ||
    fail 'Fedora wallpaper backend contract must select awww'
grep -Fq 'shorin-fedora-wallpaper-session' "$NIRI_CONFIG_FILE" ||
    fail 'Fedora Niri config must use the managed wallpaper initializer'
if grep -Eq 'awww-daemon|waypaper|niri_set_overview_blur_dark_bg|niri_auto_blur_bg' \
    "$NIRI_CONFIG_FILE"; then
    fail 'Fedora Niri config must remove the old parallel wallpaper startup chain'
fi
grep -Fq 'spawn-sh "lockscreen.sh"' "$NIRI_BINDS_FILE" ||
    fail 'Fedora lockscreen binding must use the managed wrapper'
grep -Eq 'shorin-fedora-awww-query|awww query' \
    "$NIRI_QUICKSHELL_DIR/lockscreen/shell.qml" ||
    fail 'Fedora staged QuickShell config must use the quiet awww query wrapper'
grep -Fqx 'backend = awww' "$NIRI_WAYPAPER_CONFIG_FILE" ||
    fail 'Fedora Waypaper config must use awww exactly'
if grep -R -Eq '(^|[^[:alnum:]_-])swww(-daemon)?([^[:alnum:]_-]|$)' \
    "$NIRI_CONFIG_FILE" "$NIRI_QUICKSHELL_DIR" "$NIRI_WAYPAPER_CONFIG_FILE"; then
    fail 'Fedora desktop config must not retain legacy swww command references'
fi
QUICKSHELL_STATE_BEFORE_DRIFT="$TEST_DIR/fedora-quickshell-state-before-drift"
cp "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" "$QUICKSHELL_STATE_BEFORE_DRIFT"
cat > "$NIRI_QUICKSHELL_DIR/shell.qml" <<'EOF'
import QtQuick 2.0
property string tampered: "drift"
EOF
if ensure_niri_wallpaper_backend "$TARGET_USER"; then
    fail 'Fedora wallpaper apply must reject live QuickShell drift'
fi
grep -Fq 'tampered' "$NIRI_QUICKSHELL_DIR/shell.qml" ||
    fail 'Fedora live QuickShell drift must not be rewritten by session apply'
cmp -s "$QUICKSHELL_STATE_BEFORE_DRIFT" \
    "$NIRI_QUICKSHELL_SOURCE_STATE_FILE" ||
    fail 'Fedora live QuickShell drift must not refresh source state'
if niri_quickshell_refresh_state_digest; then
    fail 'Fedora QuickShell refresh must reject an edited live tree'
fi
if niri_quickshell_deployment_state_satisfied; then
    fail 'Fedora live QuickShell drift must remain unsatisfied'
fi
niri_quickshell_stage_and_deploy \
    "$FEDORA_QUICKSHELL_CHECKOUT" "$TARGET_USER" ||
    fail 'Fedora QuickShell repair must redeploy the verified source tree'
niri_quickshell_deployment_state_satisfied ||
    fail 'Fedora QuickShell source repair must converge deployment state'

declare -Ag MOCK_DESKTOP_INSTALLED=()
state_package_present() {
    [ "${MOCK_DESKTOP_INSTALLED[$1]:-0}" -eq 1 ]
}
ensure_package() {
    MOCK_DESKTOP_INSTALLED[$1]=1
    printf 'ensure:%s\n' "$1" >> "$DNF_CALLS"
}
CANONICAL=$(niri_package_target_canonical AUR:wlogout-git)
[ "$CANONICAL" = wlogout ] || fail 'Fedora check/apply mapping must canonicalize wlogout-git to wlogout'
niri_package_target_satisfied "$CANONICAL" &&
    fail 'mock desktop package should begin as drift'
ensure_niri_package_target "$CANONICAL" ||
    fail 'Fedora desktop apply must use the canonical target'
niri_package_target_satisfied "$CANONICAL" ||
    fail 'Fedora desktop verify must use the same canonical target'
grep -Fqx 'ensure:wlogout' "$DNF_CALLS" ||
    fail 'Fedora desktop apply must install the translated package name'

# Fedora ddcutil uses udev access rules; the desktop contract must not require
# an Arch-only i2c group or modules-load file.  The Arch branch still keeps
# those checks.
MOCK_DESKTOP_INSTALLED[ddcutil]=1
state_user_in_group() { return 1; }
state_line_present() { return 1; }
niri_optional_hardware_targets_match ||
    fail 'Fedora ddcutil hardware contract must not require an i2c group'
export SHORIN_DISTRO=arch
if niri_optional_hardware_targets_match; then
    fail 'Arch ddcutil hardware contract must retain its i2c checks'
fi
export SHORIN_DISTRO=fedora

# A missing Fedora swayosd package must not leave a login-time spawn command
# behind.  The optional target remains visible in diagnostics but is never
# treated as a required package.
printf 'spawn-at-startup "swayosd-server"\nspawn-at-startup "quickshell"\n' \
    > "$NIRI_CONFIG_FILE"
if niri_optional_startup_satisfied; then
    fail 'Fedora missing swayosd must make its startup command drift'
fi
ensure_niri_optional_startup "$TARGET_USER" ||
    fail 'Fedora optional startup cleanup must converge'
! grep -Fq swayosd "$NIRI_CONFIG_FILE" ||
    fail 'Fedora optional startup cleanup must remove swayosd-server'
grep -Fq quickshell "$NIRI_CONFIG_FILE" ||
    fail 'Fedora optional startup cleanup must preserve unrelated startup commands'

if fedora_install_application_target unknown-aur-target "$TARGET_USER" "$HOME_DIR"; then
    fail 'unknown Fedora AUR target must not claim success'
fi
if grep -Fq 'unknown-aur-target' "$DNF_CALLS"; then
    fail 'unknown Fedora AUR target must never reach dnf'
fi

# --user is a selector for an existing account.  Install's interactive path
# may ask for a new username, but an explicit missing account must stop before
# any module can claim that it created one.
source "$ROOT_DIR/scripts/checks/preflight.sh"
if USER_ERROR=$(preflight_resolve_target_user install definitely-missing-user \
    2>&1); then
    fail 'explicit missing --user must fail preflight'
fi
grep -Fq -- 'explicit --user must name an existing non-root account' <<< "$USER_ERROR" ||
    fail 'missing --user error must explain the existing-account contract'
preflight_readonly() { :; }
preflight_mutating() { fail 'missing --user must fail before mutating preflight'; }
if run_preflight install definitely-missing-user 2>"$TEST_DIR/preflight-error"; then
    fail 'run_preflight must reject a missing explicit --user'
fi

COMMON_HASH=$(sha256sum "$ROOT_DIR/common-applist.txt" | awk '{print $1}')
[ "$COMMON_HASH" = 233c7908cab663fe4cbe0c96323c1bd6b1a4286c80a19051532bee60de6cbebc ] ||
    fail "common-applist.txt hash changed unexpectedly: $COMMON_HASH"

printf 'PASS: Fedora package query, base contract, GPU selection, and desktop target translation\n'
