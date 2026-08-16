#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Fedora provider contracts. These functions are sourced by fedora.sh after
# the shared artifact helpers have been defined.

# Application targets whose Fedora source is not the Arch package-manager
# namespace. Keep this contract in one place: applications check, apply and
# verify all resolve the same provider before touching a package manager.
FEDORA_FD_COMMAND_PATH=${FEDORA_FD_COMMAND_PATH:-/usr/bin/fd}
FEDORA_LACT_COMMAND_PATH=${FEDORA_LACT_COMMAND_PATH:-/usr/bin/lact}
FEDORA_LACT_SERVICE=${FEDORA_LACT_SERVICE:-lactd.service}
FEDORA_LACT_COPR=${FEDORA_LACT_COPR:-ilyaz/LACT}
# The official Yazi installation documentation requires the yazi-build
# helper; its `install` subcommand produces the yazi and ya binaries.
FEDORA_YAZI_CARGO_CRATE=${FEDORA_YAZI_CARGO_CRATE:-yazi-build}
FEDORA_YAZI_CARGO_VERSION=${FEDORA_YAZI_CARGO_VERSION:-26.8.15}

fedora_application_provider_kind() {
    case "$1" in
        code|curtail|mission-center|steam) printf '%s\n' flatpak ;;
        fd) printf '%s\n' package ;;
        lact) printf '%s\n' copr ;;
        yazi) printf '%s\n' cargo ;;
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
        yazi) printf '%s\n' "$FEDORA_YAZI_CARGO_CRATE" ;;
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
        yazi) printf '%s\n' "target-user cargo $FEDORA_YAZI_CARGO_CRATE $FEDORA_YAZI_CARGO_VERSION, then yazi-build install (yazi + ya)" ;;
        *) return 1 ;;
    esac
}

fedora_application_provider_target() {
    fedora_application_provider_kind "$1" >/dev/null 2>&1
}

fedora_flatpak_desktop_export_satisfied() {
    local app=$1 home=${2:-${HOME_DIR:-}} export_dir candidate
    local -a export_dirs=()

    export_dir=${FEDORA_FLATPAK_EXPORT_DIR:-}
    [ -n "$export_dir" ] && export_dirs+=("$export_dir")
    export_dirs+=(
        /var/lib/flatpak/exports/share/applications
        /usr/local/share/flatpak/exports/share/applications
        "$home/.local/share/flatpak/exports/share/applications"
    )
    for export_dir in "${export_dirs[@]}"; do
        candidate="$export_dir/$app.desktop"
        [ -s "$candidate" ] && return 0
    done
    return 1
}

fedora_flatpak_app_scope() {
    local app=$1 system_status=0 user_status=0

    command -v flatpak >/dev/null 2>&1 || return 2
    flatpak info --system "$app" >/dev/null 2>&1 || system_status=$?
    [ "$system_status" -eq 0 ] && {
        printf '%s\n' system
        return 0
    }
    flatpak info --user "$app" >/dev/null 2>&1 || user_status=$?
    [ "$user_status" -eq 0 ] && {
        printf '%s\n' user
        return 0
    }
    [ "$system_status" -gt 1 ] || [ "$user_status" -gt 1 ] && return 2
    return 1
}

fedora_flatpak_present() {
    fedora_flatpak_app_scope "$1" >/dev/null
}

fedora_flatpak_override_satisfied() {
    local app=$1 scope status=0

    scope=$(fedora_flatpak_app_scope "$app") || status=$?
    [ "$status" -eq 0 ] || return "$status"
    flatpak override "--$scope" --show "$app" 2>/dev/null |
        grep -Fqx 'LANG=zh_CN.UTF-8'
}
fedora_application_target_pending() {
    local package=$1 home=${2:-${HOME_DIR:-/nonexistent}}
    local pattern satisfied_status=0

    platform_is_fedora || return 1
    fedora_application_target_satisfied "$package" "${TARGET_USER:-}" \
        "$home" || satisfied_status=$?
    case "$satisfied_status" in
        0) return 1 ;;
        1) ;;
        *) return "$satisfied_status" ;;
    esac
    case "$package" in
        clash-verge-rev)
            for pattern in 'Clash Verge-*.rpm' 'Clash.Verge*.rpm' \
                'clash-verge*.rpm'; do
                fedora_rpm_file "$pattern" >/dev/null && return 1
            done
            return 0
            ;;
        linuxqq-appimage)
            fedora_rpm_file 'linuxqq*.rpm' >/dev/null && return 1
            return 0
            ;;
        wechat-appimage)
            fedora_rpm_file 'WeChatLinux*.rpm' >/dev/null && return 1
            return 0
            ;;
        lsfg-vk-bin)
            fedora_rpm_file 'lsfg-vk*.rpm' >/dev/null && return 1
            return 0
            ;;
        thorium-browser-bin)
            fedora_rpm_file 'thorium-browser*.rpm' >/dev/null && return 1
            return 0
            ;;
        mark-shot)
            fedora_rpm_file 'mark-shot-*.rpm' >/dev/null && return 1
            return 0
            ;;
        vicinae-bin|vicinae)
            if [ -n "${FEDORA_VICINAE_APPIMAGE:-}" ] &&
                [ -f "$FEDORA_VICINAE_APPIMAGE" ]; then
                return 1
            fi
            fedora_rpm_file '*vicinae*.AppImage' >/dev/null && return 1
            [ -f "$(fedora_user_bin vicinae.AppImage "$home")" ] && return 1
            return 0
            ;;
        fd-rdd-git)
            [ -n "${FEDORA_FD_RDD_INSTALL_SCRIPT:-}" ] &&
                [ -r "$FEDORA_FD_RDD_INSTALL_SCRIPT" ] && return 1
            return 0
            ;;
        typora-free)
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

fedora_yazi_binary_path() {
    printf '%s\n' "${2:-${HOME_DIR:-}}/.cargo/bin/$1"
}

fedora_yazi_target_satisfied() {
    local user=$1 home=$2 binary output status=0

    [ -n "$user" ] && [ -n "$home" ] || return 2
    for binary in yazi ya; do
        binary=$(fedora_yazi_binary_path "$binary" "$home")
        [ -x "$binary" ] || return 1
        output=$(runuser -u "$user" -- env HOME="$home" \
            PATH="$home/.cargo/bin:${PATH:-}" "$binary" --version 2>/dev/null) || {
            status=$?
            [ "$status" -gt 1 ] || status=2
            return "$status"
        }
        grep -Eq "(^|[[:space:]])${FEDORA_YAZI_CARGO_VERSION}([[:space:]]|$)" \
            <<< "$output" || return 1
    done
}

fedora_application_target_provider_satisfied() {
    local package=$1 user=${2:-${TARGET_USER:-}} home=${3:-${HOME_DIR:-}}
    local kind provider

    kind=$(fedora_application_provider_kind "$package") || return 1
    provider=$(fedora_application_provider_id "$package") || return 1
    case "$kind" in
        flatpak) fedora_flatpak_present "$provider" ;;
        package) fedora_fd_target_satisfied ;;
        copr) fedora_lact_target_satisfied ;;
        cargo) fedora_yazi_target_satisfied "$user" "$home" ;;
        *) return 1 ;;
    esac
}
