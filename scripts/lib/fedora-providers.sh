#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Fedora provider contracts. Target-user implementations are sourced by
# fedora.sh from the focused Starship/font provider libraries below it.

# Application targets whose Fedora source is not the Arch package-manager
# namespace. Keep this contract in one place: applications check, apply and
# verify all resolve the same provider before touching a package manager.
FEDORA_FD_COMMAND_PATH=${FEDORA_FD_COMMAND_PATH:-/usr/bin/fd}
FEDORA_LACT_COMMAND_PATH=${FEDORA_LACT_COMMAND_PATH:-/usr/bin/lact}
FEDORA_LACT_SERVICE=${FEDORA_LACT_SERVICE:-lactd.service}
FEDORA_LACT_COPR=${FEDORA_LACT_COPR:-ilyaz/LACT}
FEDORA_TSUKIMI_COPR=${FEDORA_TSUKIMI_COPR:-walker874/tsukimi}
FEDORA_YAZI_VERSION=${FEDORA_YAZI_VERSION:-26.8.15}
FEDORA_YAZI_X86_64_SHA256=${FEDORA_YAZI_X86_64_SHA256:-cc67eb7991550c2f9407cda52d3f5af0937627aa6884e7de99a04fcf059807e0}
FEDORA_YAZI_AARCH64_SHA256=${FEDORA_YAZI_AARCH64_SHA256:-f5a85771f06bb0e8c488136ae0aedaec8d341a7cee995549df391d7d852fe8d1}

# Fedora deliberately keeps the ordinary JetBrains Mono, Source Han and Noto
# families in DNF.  The desktop assets below are different contracts:
# Starship is a target-user command, while Nerd Fonts, Maple Mono and Material
# Design Icons are target-user font assets.  Do not add these to the generic
# Fedora package-name mapper: a package with a similar name is not an exact
# family/provider match.
#
# These values are deliberately assigned, rather than initialized from the
# environment; ordinary environment variables cannot change a production
# download.
FEDORA_STARSHIP_VERSION_PINNED=1.26.0
FEDORA_STARSHIP_URL_PINNED=https://github.com/starship/starship/releases/download/v1.26.0/starship-x86_64-unknown-linux-musl.tar.gz
FEDORA_STARSHIP_SHA256_PINNED=b7c232b0e8249d8e55a40beb79c5c43a7d370f3f9408bd215deb0170daeaadf3
FEDORA_JETBRAINSMONO_NERD_VERSION_PINNED=3.5.0
FEDORA_JETBRAINSMONO_NERD_URL_PINNED=https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.0/JetBrainsMono.tar.xz
FEDORA_JETBRAINSMONO_NERD_SHA256_PINNED=0227b220360a6f819b9ead92343e8112b34733054782561af50cfba1e8afab63
FEDORA_MATERIAL_DESIGN_ICONS_VERSION_PINNED=7.4.47
FEDORA_MATERIAL_DESIGN_ICONS_URL_PINNED=https://raw.githubusercontent.com/Templarian/MaterialDesign-Webfont/57b567a448bd579892174cd47c47f9e187ea56c6/fonts/materialdesignicons-webfont.ttf
FEDORA_MATERIAL_DESIGN_ICONS_SHA256_PINNED=61e8aba5a4e981fe22cf7c8e8bcdbea00476e75c62c37f01bf7ee33361d68428
FEDORA_JETBRAINS_MAPLE_VERSION_PINNED=1.2304.79
FEDORA_JETBRAINS_MAPLE_URL_PINNED=https://github.com/SpaceTimee/Fusion-JetBrainsMapleMono/releases/download/1.2304.79/JetBrainsMapleMono-NF-XX-XX-XX.zip
FEDORA_JETBRAINS_MAPLE_SHA256_PINNED=50b36f9efaa3fd76de6636db6e632e537f4c5c3bdff6c783d6937493f8b4ae6e
FEDORA_SHORIN_FONT_DIR_NAME_PINNED=shorin
FEDORA_NERD_FONT_FAMILY_PINNED='JetBrainsMono Nerd Font'
FEDORA_MAPLE_FONT_FAMILY_PINNED='JetBrains Maple Mono'
FEDORA_MDI_FONT_FAMILY_PINNED='Material Design Icons'
FEDORA_MDI_GLYPHS_PINNED='f0493 f033e f0425'

FEDORA_STARSHIP_VERSION=$FEDORA_STARSHIP_VERSION_PINNED
FEDORA_STARSHIP_URL=$FEDORA_STARSHIP_URL_PINNED
FEDORA_STARSHIP_SHA256=$FEDORA_STARSHIP_SHA256_PINNED
FEDORA_JETBRAINSMONO_NERD_VERSION=$FEDORA_JETBRAINSMONO_NERD_VERSION_PINNED
FEDORA_JETBRAINSMONO_NERD_URL=$FEDORA_JETBRAINSMONO_NERD_URL_PINNED
FEDORA_JETBRAINSMONO_NERD_SHA256=$FEDORA_JETBRAINSMONO_NERD_SHA256_PINNED
FEDORA_MATERIAL_DESIGN_ICONS_VERSION=$FEDORA_MATERIAL_DESIGN_ICONS_VERSION_PINNED
FEDORA_MATERIAL_DESIGN_ICONS_URL=$FEDORA_MATERIAL_DESIGN_ICONS_URL_PINNED
FEDORA_MATERIAL_DESIGN_ICONS_SHA256=$FEDORA_MATERIAL_DESIGN_ICONS_SHA256_PINNED
FEDORA_JETBRAINS_MAPLE_VERSION=$FEDORA_JETBRAINS_MAPLE_VERSION_PINNED
FEDORA_JETBRAINS_MAPLE_URL=$FEDORA_JETBRAINS_MAPLE_URL_PINNED
FEDORA_JETBRAINS_MAPLE_SHA256=$FEDORA_JETBRAINS_MAPLE_SHA256_PINNED
FEDORA_SHORIN_FONT_DIR_NAME=$FEDORA_SHORIN_FONT_DIR_NAME_PINNED
FEDORA_NERD_FONT_FAMILY=$FEDORA_NERD_FONT_FAMILY_PINNED
FEDORA_MAPLE_FONT_FAMILY=$FEDORA_MAPLE_FONT_FAMILY_PINNED
FEDORA_MDI_FONT_FAMILY=$FEDORA_MDI_FONT_FAMILY_PINNED
FEDORA_MDI_GLYPHS=$FEDORA_MDI_GLYPHS_PINNED

fedora_application_provider_kind() {
    case "$1" in
        code|curtail|mission-center|steam) printf '%s\n' flatpak ;;
        fd) printf '%s\n' package ;;
        lact|tsukimi-bin) printf '%s\n' copr ;;
        yazi) printf '%s\n' release ;;
        starship) printf '%s\n' target-user ;;
        ttf-jetbrains-mono-nerd|ttf-jetbrains-maple-mono-nf-xx-xx|material-design-icons)
            printf '%s\n' font ;;
        *) return 1 ;;
    esac
}

fedora_application_provider_id() {
    case "$1" in
        code) printf '%s\n' com.visualstudio.code ;;
        curtail) printf '%s\n' com.github.huluti.Curtail ;;
        mission-center) printf '%s\n' io.missioncenter.MissionCenter ;;
        steam) printf '%s\n' com.valvesoftware.Steam ;;
        fd) printf '%s\n' fd-find ;;
        lact) printf '%s\n' lact ;;
        tsukimi-bin) printf '%s\n' "$FEDORA_TSUKIMI_COPR" ;;
        yazi) printf '%s\n' "yazi-v$FEDORA_YAZI_VERSION" ;;
        starship) printf '%s\n' "starship-v$FEDORA_STARSHIP_VERSION" ;;
        ttf-jetbrains-mono-nerd) printf '%s\n' "$FEDORA_NERD_FONT_FAMILY" ;;
        ttf-jetbrains-maple-mono-nf-xx-xx) printf '%s\n' "$FEDORA_MAPLE_FONT_FAMILY" ;;
        material-design-icons) printf '%s\n' "$FEDORA_MDI_FONT_FAMILY" ;;
        *) return 1 ;;
    esac
}

fedora_application_provider_description() {
    case "$1" in
        code) printf '%s\n' 'Flatpak com.visualstudio.code (Flathub)' ;;
        curtail) printf '%s\n' 'Flatpak com.github.huluti.Curtail (Flathub)' ;;
        mission-center) printf '%s\n' 'Flatpak io.missioncenter.MissionCenter (Flathub)' ;;
        steam) printf '%s\n' 'Flatpak com.valvesoftware.Steam (Flathub)' ;;
        fd) printf '%s\n' 'Fedora package fd-find (/usr/bin/fd)' ;;
        lact) printf '%s\n' "COPR $FEDORA_LACT_COPR, package lact, service $FEDORA_LACT_SERVICE" ;;
        tsukimi-bin) printf '%s\n' "COPR $FEDORA_TSUKIMI_COPR, package tsukimi" ;;
        yazi) printf '%s\n' "GitHub release v$FEDORA_YAZI_VERSION (verified GNU ZIP, yazi + ya)" ;;
        starship) printf '%s\n' "GitHub release v$FEDORA_STARSHIP_VERSION (verified musl x86_64, target-user ~/.local/bin/starship)" ;;
        ttf-jetbrains-mono-nerd) printf '%s\n' "Nerd Fonts JetBrainsMono v$FEDORA_JETBRAINSMONO_NERD_VERSION (target-user exact family $FEDORA_NERD_FONT_FAMILY)" ;;
        ttf-jetbrains-maple-mono-nf-xx-xx) printf '%s\n' "Fusion JetBrainsMapleMono v$FEDORA_JETBRAINS_MAPLE_VERSION (target-user exact family $FEDORA_MAPLE_FONT_FAMILY)" ;;
        material-design-icons) printf '%s\n' "Material Design Icons v$FEDORA_MATERIAL_DESIGN_ICONS_VERSION (target-user exact family $FEDORA_MDI_FONT_FAMILY)" ;;
        *) return 1 ;;
    esac
}

fedora_application_provider_target() {
    fedora_application_provider_kind "$1" >/dev/null 2>&1
}

fedora_installer_sha256_valid() {
    local variable=$1 value=${!1:-}

    [ -n "$value" ] && [[ "$value" =~ ^[[:xdigit:]]{64}$ ]]
}

fedora_application_target_pending() {
    local package=$1 home=${2:-${HOME_DIR:-/nonexistent}}
    local pattern satisfied_status=0

    platform_is_fedora || return 1
    FEDORA_APPLICATION_PENDING_REASON=''
    fedora_application_target_satisfied "$package" "${TARGET_USER:-}" \
        "$home" || satisfied_status=$?
    case "$satisfied_status" in
        0) return 1 ;;
        1) ;;
        *) return "$satisfied_status" ;;
    esac
    case "$package" in
        clash-verge-rev)
            for pattern in 'Clash.Verge-*.rpm' 'Clash Verge-*.rpm' 'Clash.Verge*.rpm' \
                'clash-verge*.rpm'; do
                fedora_rpm_file "$pattern" >/dev/null && return 1
            done
            FEDORA_APPLICATION_PENDING_REASON='official-download-at-apply:x86_64:v2.5.2'
            return 0
            ;;
        linuxqq-appimage)
            for pattern in 'QQ_*.rpm' 'linuxqq*.rpm'; do
                fedora_rpm_file "$pattern" >/dev/null && return 1
            done
            FEDORA_APPLICATION_PENDING_REASON='official-download-at-apply:x86_64:QQ_3.2.32_260812_x86_64_01.rpm'
            return 0
            ;;
        wechat-appimage)
            if ! fedora_installer_sha256_valid FEDORA_WECHAT_SHA256; then
                FEDORA_APPLICATION_PENDING_REASON='official-rpm-sha256-required:label=WeChat Linux:env=FEDORA_WECHAT_SHA256:sidecar=ignored'
                return 0
            fi
            fedora_rpm_file 'WeChatLinux*.rpm' >/dev/null && return 1
            FEDORA_APPLICATION_PENDING_REASON='official-rpm-missing:pattern=WeChatLinux*.rpm:search=FEDORA_RPM_DIR,SHORIN_ARTIFACT_DIR,target-Downloads,target-下载,/tmp'
            return 0
            ;;
        lsfg-vk-bin)
            fedora_rpm_file 'lsfg-vk*.rpm' >/dev/null && return 1
            FEDORA_APPLICATION_PENDING_REASON='official-download-at-apply:x86_64:v1.0.0:qt6-qtdeclarative+qt6-qtbase'
            return 0
            ;;
        thorium-browser-bin)
            if ! fedora_installer_sha256_valid FEDORA_THORIUM_SHA256; then
                FEDORA_APPLICATION_PENDING_REASON='official-rpm-sha256-required:label=Thorium Browser:env=FEDORA_THORIUM_SHA256:sidecar=ignored'
                return 0
            fi
            fedora_rpm_file 'thorium-browser*.rpm' >/dev/null && return 1
            FEDORA_APPLICATION_PENDING_REASON='official-rpm-missing:pattern=thorium-browser*.rpm:search=FEDORA_RPM_DIR,SHORIN_ARTIFACT_DIR,target-Downloads,target-下载,/tmp'
            return 0
            ;;
        mark-shot)
            fedora_rpm_file 'mark-shot*.rpm' >/dev/null && return 1
            FEDORA_APPLICATION_PENDING_REASON='official-download-at-apply:x86_64:v0.1.48'
            return 0
            ;;
        vicinae-bin|vicinae)
            if [ -n "${FEDORA_VICINAE_APPIMAGE:-}" ] &&
                [ -f "$FEDORA_VICINAE_APPIMAGE" ]; then
                return 1
            fi
            fedora_rpm_file '*vicinae*.AppImage' >/dev/null && return 1
            [ -f "$(fedora_user_bin vicinae.AppImage "$home")" ] && return 1
            FEDORA_APPLICATION_PENDING_REASON='official-download-at-apply:x86_64:v0.26.0:GearLever-target-user-integration'
            return 0
            ;;
        fd-rdd-git)
            if [ -x "$home/.vcp/bin/fd-rdd" ]; then
                return 1
            fi
            [ -n "${FEDORA_FD_RDD_INSTALL_SCRIPT:-}" ] &&
                [ -r "$FEDORA_FD_RDD_INSTALL_SCRIPT" ] && return 1
            FEDORA_APPLICATION_PENDING_REASON='official-source-at-apply:git+fixed-commit:44b60573129c67f4471fa70f21b4a0b70bc1fec8:scripts/install.sh'
            return 0
            ;;
        typora-free)
            FEDORA_APPLICATION_PENDING_REASON='no-declared-official-fedora-source:manual-target-required'
            return 0
            ;;
        *) return 1 ;;
    esac
}

fedora_fd_target_satisfied() {
    local package_status=0

    state_package_present fd-find || package_status=$?
    case "$package_status" in
        0) [ -x "$FEDORA_FD_COMMAND_PATH" ] ;;
        1) return 1 ;;
        *) return "$package_status" ;;
    esac
}

fedora_copr_repository_enabled() {
    local repository=$1 output status=0 repo_id

    command -v dnf >/dev/null 2>&1 || return 2
    output=$(dnf repolist --enabled 2>/dev/null) || status=$?
    [ "$status" -eq 0 ] || {
        [ "$status" -gt 1 ] || status=2
        return "$status"
    }
    repo_id=$(fedora_copr_repository_id "$repository")
    grep -Fq "$repository" <<< "$output" ||
        grep -Fq "$repo_id" <<< "$output"
}

fedora_copr_repository_id() {
    local repository=$1

    printf 'copr:copr.fedorainfracloud.org:%s\n' \
        "${repository/\//:}"
}

fedora_ensure_copr_repository() {
    local repository=$1 status=0

    fedora_copr_repository_enabled "$repository" || status=$?
    case "$status" in
        0) return 0 ;;
        1) dnf copr enable -y "$repository" ;;
        *)
            error "Unable to inspect Fedora COPR repository: $repository"
            return "$status"
            ;;
    esac
}

fedora_lact_target_satisfied() {
    local package_status=0 service_status=0 active_status=0

    command -v rpm >/dev/null 2>&1 || return 2
    rpm -q lact >/dev/null 2>&1 || package_status=$?
    [ "$package_status" -eq 1 ] || [ "$package_status" -eq 0 ] ||
        return "$package_status"
    case "$package_status" in
        0) ;;
        1) return 1 ;;
        *) return "$package_status" ;
    esac
    [ -x "$FEDORA_LACT_COMMAND_PATH" ] || return 1
    state_service_enabled "$FEDORA_LACT_SERVICE" || service_status=$?
    case "$service_status" in
        0) ;;
        1) return 1 ;;
        *) return "$service_status" ;
    esac
    state_service_active "$FEDORA_LACT_SERVICE" || active_status=$?
    case "$active_status" in
        0) return 0 ;;
        1) return 1 ;;
        *) return "$active_status" ;
    esac
}

fedora_copr_application_target_satisfied() {
    local package=$1

    case "$package" in
        lact)
            fedora_lact_target_satisfied
            ;;
        tsukimi-bin)
            package_is_installed tsukimi || command -v tsukimi >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

fedora_yazi_release_arch() {
    local machine=${FEDORA_YAZI_MACHINE:-$(uname -m)}

    case "$machine" in
        x86_64|aarch64) printf '%s\n' "$machine" ;;
        *)
            error "Unsupported Fedora Yazi release architecture: $machine"
            return 2
            ;;
    esac
}

fedora_yazi_release_url() {
    local arch

    arch=$(fedora_yazi_release_arch) || return
    printf 'https://github.com/sxyazi/yazi/releases/download/v%s/yazi-%s-unknown-linux-gnu.zip\n' \
        "$FEDORA_YAZI_VERSION" "$arch"
}

fedora_yazi_release_digest() {
    local arch

    arch=$(fedora_yazi_release_arch) || return
    case "$arch" in
        x86_64) printf '%s\n' "$FEDORA_YAZI_X86_64_SHA256" ;;
        aarch64) printf '%s\n' "$FEDORA_YAZI_AARCH64_SHA256" ;;
    esac
}

fedora_yazi_binary_path() {
    printf '%s\n' "${2:-${HOME_DIR:-}}/.local/bin/$1"
}

fedora_yazi_version_output_satisfied() {
    local output=$1 expected=${FEDORA_YAZI_VERSION:-} expected_pattern

    [[ "$expected" =~ ^[0-9]+([.][0-9]+){2}$ ]] || return 2
    expected_pattern=${expected//./\\.}
    grep -Eq "^Version:[[:space:]]+${expected_pattern}[[:space:]]+\\(" <<< "$output"
}

fedora_yazi_target_satisfied() {
    local user=$1 home=$2 binary output status=0 group owner

    [ -n "$user" ] && [ -n "$home" ] || return 2
    fedora_yazi_release_arch >/dev/null || return
    group=$(id -gn "$user" 2>/dev/null) || return 2
    for binary in yazi ya; do
        binary=$(fedora_yazi_binary_path "$binary" "$home")
        [ -x "$binary" ] || return 1
        owner=$(stat -c '%U:%G' "$binary" 2>/dev/null) || return 2
        [ "$owner" = "$user:$group" ] || return 1
        output=$(runuser -u "$user" -- env HOME="$home" \
            PATH="$home/.local/bin:${PATH:-}" "$binary" --version 2>&1) || {
            status=$?
            [ "$status" -gt 1 ] || status=2
            return "$status"
        }
        fedora_yazi_version_output_satisfied "$output" || return
    done
}

fedora_application_target_provider_satisfied() {
    local package=$1 user=${2:-${TARGET_USER:-}} home=${3:-${HOME_DIR:-}}
    local kind provider

    kind=$(fedora_application_provider_kind "$package") || return 1
    provider=$(fedora_application_provider_id "$package") || return 1
    case "$kind" in
        flatpak) fedora_flatpak_present "$provider" "$user" "$home" ;;
        package) fedora_fd_target_satisfied ;;
        copr) fedora_copr_application_target_satisfied "$package" ;;
        release) fedora_yazi_target_satisfied "$user" "$home" ;;
        target-user) fedora_starship_target_satisfied "$user" "$home" ;;
        font) fedora_font_target_satisfied "$package" "$user" "$home" ;;
        *) return 1 ;;
    esac
}
