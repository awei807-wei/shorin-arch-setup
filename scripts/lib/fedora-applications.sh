#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Fedora application target convergence. The shared RPM and artifact helpers
# are loaded by fedora.sh before this file.

fedora_application_target_satisfied() {
    local package=$1 user=${2:-${TARGET_USER:-}} home=${3:-${HOME_DIR:-}}
    local appimage gearlever

    if fedora_application_provider_target "$package"; then
        fedora_application_target_provider_satisfied "$package" "$user" "$home"
        return
    fi
    case "$package" in
        heroic-games-launcher-bin)
            fedora_flatpak_present com.heroicgameslauncher.hgl "$user" "$home" ;;
        upscaler)
            fedora_flatpak_present io.gitlab.theevilskeleton.Upscaler "$user" "$home" ;;
        clash-verge-rev)
            fedora_rpm_or_command '(^|[-.])clash[-_]?verge' clash-verge ;;
        linuxqq-appimage)
            fedora_rpm_or_command '(^|[-_.])([Ll]inux)?[Qq][Qq]($|[-_.])' qq ;;
        wechat-appimage)
            fedora_installer_sha256_valid FEDORA_WECHAT_SHA256 || return 1
            fedora_rpm_or_command '([Ww]e[Cc]hat|[Ww]x|[Cc]om\.[Tt]encent\.[Ww]e[Cc]hat)' wechat ;;
        lsfg-vk-bin)
            package_is_installed qt6-qtdeclarative &&
                package_is_installed qt6-qtbase &&
                fedora_rpm_or_command 'lsfg[-_]?vk' lsfg-vk ;;
        mangojuice-bin)
            fedora_flatpak_present io.github.radiolamp.mangojuice "$user" "$home" ;;
        vicinae-bin|vicinae)
            gearlever=1
            fedora_flatpak_present it.mijorus.gearlever "$user" "$home" || gearlever=0
            appimage=$(fedora_user_bin vicinae.AppImage "$home")
            [ "$gearlever" -eq 1 ] && [ -x "$appimage" ] &&
                fedora_vicinae_desktop_satisfied "$home" ;;
        fd-rdd-git)
            fedora_fd_rdd_binary_satisfied "$home" "$user" ;;
        tsukimi-bin)
            fedora_copr_application_target_satisfied tsukimi-bin ;;
        thorium-browser-bin)
            fedora_installer_sha256_valid FEDORA_THORIUM_SHA256 || return 1
            fedora_rpm_or_command '[Tt]horium([-_]?browser)?' thorium-browser ;;
        mark-shot)
            fedora_rpm_or_command '(^|[-.])mark[-_]?shot' mark-shot ;;
        typora-free)
            return 1 ;;
        *)
            local mapped
            mapped=$(fedora_arch_target_name "AUR:$package") || return 1
            package_is_installed "$mapped"
            ;;
    esac
}

fedora_install_lact() {
    local user=$1 home=$2 repository_status=0 repository_id

    fedora_ensure_copr_repository "$FEDORA_LACT_COPR" || return
    if rpm -q lact >/dev/null 2>&1; then
        :
    else
        repository_id=$(fedora_copr_repository_id "$FEDORA_LACT_COPR")
        platform_dnf_package_available lact "$repository_id" ||
            repository_status=$?
        [ "$repository_status" -eq 0 ] || {
            if [ "$repository_status" -eq 1 ]; then
                error "Fedora COPR $FEDORA_LACT_COPR does not provide package lact."
            else
                error "Unable to inspect Fedora COPR package lact."
            fi
            return "$repository_status"
        }
        platform_dnf_install_from_repo "$repository_id" lact || return
    fi
    ensure_service_started "$FEDORA_LACT_SERVICE" || return
    fedora_lact_target_satisfied
}

fedora_install_tsukimi() {
    local repository

    repository=$(fedora_application_provider_id tsukimi-bin) || return 1
    fedora_ensure_copr_repository "$repository" || return
    ensure_package tsukimi || return
    fedora_copr_application_target_satisfied tsukimi-bin
}

fedora_yazi_cleanup() {
    local path=$1

    [ -n "$path" ] && [ -d "$path" ] || return 0
    find "$path" -depth -delete 2>/dev/null || true
}

fedora_yazi_archive_entries_safe() {
    local archive=$1 expected_root=$2 entries entry component
    local -a components=()

    entries=$(unzip -Z1 "$archive" 2>/dev/null) || return 1
    [ -n "$entries" ] || return 1
    while IFS= read -r entry; do
        [ -n "$entry" ] || return 1
        case "$entry" in
            /*|[A-Za-z]:/*|[A-Za-z]:\\*) return 1 ;;
        esac
        IFS='/' read -r -a components <<< "$entry"
        for component in "${components[@]}"; do
            [ "$component" != .. ] || return 1
        done
        case "$entry" in
            "$expected_root"|"$expected_root"/*) ;;
            *) return 1 ;;
        esac
    done <<< "$entries"
}

fedora_install_yazi() {
    local user=$1 home=$2 status=0 archive extract_root arch root_dir url digest
    local group binary source destination

    fedora_yazi_target_satisfied "$user" "$home" || status=$?
    case "$status" in
        0) return 0 ;;
        1) ;;
        *) return "$status" ;;
    esac
    arch=$(fedora_yazi_release_arch) || return
    url=$(fedora_yazi_release_url) || return
    digest=$(fedora_yazi_release_digest) || return
    group=$(id -gn "$user" 2>/dev/null) || {
        error "Unable to resolve the primary group for target user $user."
        return 2
    }
    ensure_packages curl unzip || {
        error 'Unable to install Fedora Yazi download prerequisites: curl and unzip.'
        return 1
    }
    command -v curl >/dev/null 2>&1 || {
        error 'curl is required to download the pinned Fedora Yazi release.'
        return 1
    }
    command -v sha256sum >/dev/null 2>&1 || {
        error 'sha256sum is required to verify the pinned Fedora Yazi release.'
        return 1
    }
    command -v unzip >/dev/null 2>&1 || {
        error 'unzip is required to unpack the pinned Fedora Yazi release.'
        return 1
    }
    command -v runuser >/dev/null 2>&1 || {
        error 'runuser is required to verify Fedora Yazi as the target user.'
        return 1
    }
    archive=$(mktemp)
    extract_root=$(mktemp -d)
    if ! curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        "$url" -o "$archive"; then
        rm -f "$archive"
        fedora_yazi_cleanup "$extract_root"
        error "Unable to download the pinned Fedora Yazi release: $url"
        return 1
    fi
    if ! printf '%s  %s\n' "$digest" "$archive" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$archive"
        fedora_yazi_cleanup "$extract_root"
        error "The downloaded Fedora Yazi release failed SHA-256 verification: $url"
        return 1
    fi
    if ! fedora_yazi_archive_entries_safe \
        "$archive" "yazi-${arch}-unknown-linux-gnu"; then
        rm -f "$archive"
        fedora_yazi_cleanup "$extract_root"
        error "The Fedora Yazi release contains an unsafe or unexpected archive path: $url"
        return 1
    fi
    if ! unzip -q "$archive" -d "$extract_root"; then
        rm -f "$archive"
        fedora_yazi_cleanup "$extract_root"
        error "Unable to unpack the verified Fedora Yazi release: $url"
        return 1
    fi
    rm -f "$archive"
    root_dir="$extract_root/yazi-${arch}-unknown-linux-gnu"
    [ -d "$root_dir" ] && [ ! -L "$root_dir" ] || {
        fedora_yazi_cleanup "$extract_root"
        error "Fedora Yazi release has no expected root directory: yazi-${arch}-unknown-linux-gnu"
        return 1
    }
    for binary in yazi ya; do
        source="$root_dir/$binary"
        [ -f "$source" ] && [ ! -L "$source" ] || {
            fedora_yazi_cleanup "$extract_root"
            error "Fedora Yazi release is missing its expected binary: $binary"
            return 1
        }
    done
    if ! install -d -m 755 -o "$user" -g "$group" "$home/.local/bin"; then
        fedora_yazi_cleanup "$extract_root"
        error "Unable to create the Fedora Yazi binary directory: $home/.local/bin"
        return 1
    fi
    for binary in yazi ya; do
        source="$root_dir/$binary"
        destination=$(fedora_yazi_binary_path "$binary" "$home")
        install_if_changed "$source" "$destination" 755 || {
            fedora_yazi_cleanup "$extract_root"
            error "Unable to install Fedora Yazi binary: $destination"
            return 1
        }
        chown "$user:$group" "$destination" || {
            fedora_yazi_cleanup "$extract_root"
            error "Unable to assign Fedora Yazi binary ownership: $destination"
            return 1
        }
    done
    fedora_yazi_cleanup "$extract_root"
    if fedora_yazi_target_satisfied "$user" "$home"; then
        return 0
    else
        status=$?
    fi
    error "Fedora Yazi release did not produce two verified target-user binaries."
    return "$status"
}

fedora_install_verified_rpm_target() {
    local package=$1 user=$2 home=$3 label=$4 pattern=$5 expected_var=$6
    local identity_pattern=$7 expected file

    expected=${!expected_var:-}
    if [ -z "$expected" ]; then
        FEDORA_APPLICATION_PENDING_REASON="official-rpm-sha256-required:label=$label:env=$expected_var:sidecar=ignored"
        warn "Pending Fedora artifact: $label requires an installer-provided $expected_var; sidecar checksums are not trusted."
        return "$RC_SKIPPED"
    fi
    [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || {
        error "Invalid installer-provided SHA-256 for $label: $expected_var"
        return 1
    }
    file=$(fedora_rpm_file "$pattern" 2>/dev/null || true)
    if [ -n "$file" ]; then
        fedora_install_verified_official_rpm_file \
            "$package" "$user" "$home" "$label" "$file" "$expected" \
            "$identity_pattern"
        return $?
    fi
    FEDORA_APPLICATION_PENDING_REASON="official-rpm-missing:label=$label:pattern=$pattern:search=FEDORA_RPM_DIR,SHORIN_ARTIFACT_DIR,target-Downloads,target-下载,/tmp"
    warn "Pending Fedora artifact: $label RPM was not found (pattern: $pattern); no unverified local install is allowed."
    return "$RC_SKIPPED"
}

fedora_install_clash_verge() {
    local package=$1 user=$2 home=$3

    fedora_install_official_rpm_target \
        "$package" "$user" "$home" 'Clash Verge' 'Clash.Verge-*.rpm' \
        "$FEDORA_CLASH_VERGE_URL" "$FEDORA_CLASH_VERGE_ASSET" \
        "$FEDORA_CLASH_VERGE_SHA256"
}

fedora_install_application_target() {
    local package=$1 user=${2:-${TARGET_USER:-}} home=${3:-${HOME_DIR:-}}
    local mapped target_status=0

    require_writable_mode || return
    [ -n "$user" ] && [ -n "$home" ] || {
        error "A Fedora application target requires a target user: $package"
        return 1
    }
    fedora_application_target_satisfied "$package" "$user" "$home" ||
        target_status=$?
    case "$target_status" in
        0)
            log "Skipping Fedora target already satisfied: $package"
            return 0
            ;;
        1) ;;
        *) return "$target_status" ;;
    esac
    if fedora_application_provider_target "$package"; then
        case "$(fedora_application_provider_kind "$package")" in
            flatpak)
                fedora_ensure_flatpak_target \
                    "$(fedora_application_provider_id "$package")" \
                    "$user" "$home" ;;
            package)
                ensure_package fd-find || return
                [ -x "$FEDORA_FD_COMMAND_PATH" ] || {
                    error "Fedora fd-find did not provide $FEDORA_FD_COMMAND_PATH."
                    return 1
                }
                ;;
            copr)
                case "$package" in
                    lact) fedora_install_lact "$user" "$home" ;;
                    tsukimi-bin) fedora_install_tsukimi ;;
                    *) error "Unsupported Fedora COPR target: $package"; return 1 ;;
                esac
                ;;
            release) fedora_install_yazi "$user" "$home" ;;
            target-user) fedora_install_starship "$user" "$home" ;;
            font) fedora_install_font_provider_target "$package" "$user" "$home" ;;
            *)
                error "Unsupported Fedora provider for application target: $package"
                return 1
                ;;
        esac
        return
    fi
    case "$package" in
        heroic-games-launcher-bin)
            fedora_ensure_flatpak_target com.heroicgameslauncher.hgl \
                "$user" "$home" ;;
        upscaler)
            fedora_ensure_flatpak_target io.gitlab.theevilskeleton.Upscaler \
                "$user" "$home" ;;
        clash-verge-rev)
            fedora_install_clash_verge "$package" "$user" "$home" ;;
        linuxqq-appimage)
            fedora_install_official_linuxqq "$package" "$user" "$home" ;;
        wechat-appimage)
            fedora_install_verified_rpm_target \
                "$package" "$user" "$home" 'WeChat Linux' 'WeChatLinux*.rpm' \
                FEDORA_WECHAT_SHA256 '([Ww]e[Cc]hat|[Ww]x|[Cc]om\.[Tt]encent\.[Ww]e[Cc]hat)' ;;
        lsfg-vk-bin)
            ensure_packages qt6-qtdeclarative qt6-qtbase
            fedora_install_official_rpm_target \
                "$package" "$user" "$home" 'lsfg-vk' 'lsfg-vk*.rpm' \
                "$FEDORA_LSFG_VK_URL" "$FEDORA_LSFG_VK_ASSET" \
                "$FEDORA_LSFG_VK_SHA256" ;;
        mangojuice-bin)
            fedora_ensure_flatpak_target io.github.radiolamp.mangojuice \
                "$user" "$home" ;;
        vicinae-bin|vicinae)
            fedora_install_vicinae "$user" "$home" ;;
        fd-rdd-git)
            fedora_install_fd_rdd "$user" "$home" ;;
        tsukimi-bin)
            fedora_install_tsukimi ;;
        thorium-browser-bin)
            fedora_install_verified_rpm_target \
                "$package" "$user" "$home" 'Thorium Browser' 'thorium-browser*.rpm' \
                FEDORA_THORIUM_SHA256 '[Tt]horium([-_]?browser)?' ;;
        mark-shot)
            fedora_install_official_rpm_target \
                "$package" "$user" "$home" 'Mark Shot' 'mark-shot*.rpm' \
                "$FEDORA_MARK_SHOT_URL" "$FEDORA_MARK_SHOT_ASSET" \
                "$FEDORA_MARK_SHOT_SHA256" ;;
        typora-free)
            warn 'Pending Fedora artifact: typora-free has no declared official Fedora source; install it manually and add a Fedora-specific target.'
            return "$RC_SKIPPED" ;;
        *)
            mapped=$(fedora_arch_target_name "AUR:$package") || {
                error "No Fedora mapping exists for AUR target: $package"
                return 1
            }
            ensure_package "$mapped" ;;
    esac
}
