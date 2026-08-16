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
            state_flatpak_present com.heroicgameslauncher.hgl ;;
        upscaler)
            state_flatpak_present io.gitlab.theevilskeleton.Upscaler ;;
        clash-verge-rev)
            fedora_rpm_or_command '(^|[-.])clash[-_]?verge' clash-verge ;;
        linuxqq-appimage)
            fedora_rpm_or_command '(^|[-.])linuxqq' qq ;;
        wechat-appimage)
            fedora_rpm_or_command '(^|[-.])wechat' wechat ;;
        lsfg-vk-bin)
            package_is_installed qt6-qtdeclarative &&
                package_is_installed qt6-qtbase &&
                fedora_rpm_or_command 'lsfg[-_]?vk' lsfg-vk ;;
        mangojuice-bin)
            state_flatpak_present io.github.radiolamp.mangojuice ;;
        vicinae-bin|vicinae)
            gearlever=1
            state_flatpak_present it.mijorus.gearlever || gearlever=0
            appimage=$(fedora_user_bin vicinae.AppImage "$home")
            [ "$gearlever" -eq 1 ] && [ -x "$appimage" ] &&
                fedora_vicinae_desktop_satisfied "$home" ;;
        fd-rdd-git)
            [ -x "$(fedora_user_bin fd-rdd "$home")" ] ||
                command -v fd-rdd >/dev/null 2>&1 ;;
        tsukimi-bin)
            package_is_installed tsukimi || command -v tsukimi >/dev/null 2>&1 ;;
        thorium-browser-bin)
            fedora_rpm_or_command 'thorium[-_]?browser' thorium-browser ;;
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

fedora_install_fd_rdd() {
    local user=$1 home=$2 script

    require_writable_mode || return
    if [ -n "${FEDORA_FD_RDD_INSTALL_SCRIPT:-}" ] &&
        [ -r "$FEDORA_FD_RDD_INSTALL_SCRIPT" ]; then
        script=$FEDORA_FD_RDD_INSTALL_SCRIPT
    else
        warn 'Pending Fedora target: fd-rdd-git has no verified upstream installer source.'
        warn 'Provide FEDORA_FD_RDD_INSTALL_SCRIPT with the official local installer to continue.'
        return "$RC_SKIPPED"
    fi
    grep -q '^#!' "$script" || {
        error 'Local fd-rdd installer did not contain a shebang.'
        return 1
    }
    if ! runuser -u "$user" -- env HOME="$home" bash "$script"; then
        error 'The official fd-rdd install.sh failed for the target user.'
        return 1
    fi
    fedora_application_target_satisfied fd-rdd-git "$user" "$home"
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

fedora_install_yazi() {
    local user=$1 home=$2 status=0 cargo_status=0 helper_status=0
    local cargo_output helper_output force=0 binary
    local -a cargo_args=(install --locked --registry crates-io)

    fedora_yazi_target_satisfied "$user" "$home" || status=$?
    case "$status" in
        0) return 0 ;;
        1) ;;
        *) return "$status" ;;
    esac
    # A missing target can be installed without --force.  If either binary
    # already exists, the pinned version may need to replace an older or
    # incomplete cargo install, so opt into replacement deliberately.
    for binary in yazi ya yazi-build; do
        if [ -e "$(fedora_yazi_binary_path "$binary" "$home")" ]; then
            force=1
            break
        fi
    done
    [ "$force" -eq 0 ] || cargo_args+=(--force)
    cargo_args+=(--version "$FEDORA_YAZI_CARGO_VERSION" "$FEDORA_YAZI_CARGO_CRATE")
    if cargo_output=$(runuser -u "$user" -- env HOME="$home" \
        PATH="$home/.cargo/bin:${PATH:-}" \
        cargo "${cargo_args[@]}" \
        2>&1); then
        :
    else
        cargo_status=$?
        [ -z "$cargo_output" ] || printf '%s\n' "$cargo_output" >&2
        error "Failed to install $FEDORA_YAZI_CARGO_CRATE $FEDORA_YAZI_CARGO_VERSION for $user."
        return "$cargo_status"
    fi
    if helper_output=$(runuser -u "$user" -- env HOME="$home" \
        PATH="$home/.cargo/bin:${PATH:-}" \
        yazi-build install --bin-dir "$home/.cargo/bin" 2>&1); then
        :
    else
        helper_status=$?
        [ -z "$helper_output" ] || printf '%s\n' "$helper_output" >&2
        error "Failed to run yazi-build install for $user."
        return "$helper_status"
    fi
    if fedora_yazi_target_satisfied "$user" "$home"; then
        return 0
    else
        status=$?
    fi
    error "yazi-build install did not produce both yazi and ya for $user."
    return "$status"
}

fedora_install_verified_rpm_target() {
    local package=$1 user=$2 home=$3 label=$4 pattern=$5

    fedora_install_local_rpm "$label" "$pattern" &&
        fedora_application_target_satisfied "$package" "$user" "$home"
}

fedora_install_clash_verge() {
    local package=$1 user=$2 home=$3

    fedora_install_verified_rpm_target \
        "$package" "$user" "$home" 'Clash Verge' 'Clash Verge-*.rpm' &&
        return 0
    fedora_install_verified_rpm_target \
        "$package" "$user" "$home" 'Clash Verge' 'Clash.Verge*.rpm' &&
        return 0
    fedora_install_verified_rpm_target \
        "$package" "$user" "$home" 'Clash Verge' 'clash-verge*.rpm'
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
                ensure_flatpak "$(fedora_application_provider_id "$package")" ;;
            package)
                ensure_package fd-find || return
                [ -x "$FEDORA_FD_COMMAND_PATH" ] || {
                    error "Fedora fd-find did not provide $FEDORA_FD_COMMAND_PATH."
                    return 1
                }
                ;;
            copr) fedora_install_lact "$user" "$home" ;;
            cargo) fedora_install_yazi "$user" "$home" ;;
            *)
                error "Unsupported Fedora provider for application target: $package"
                return 1
                ;;
        esac
        return
    fi
    case "$package" in
        heroic-games-launcher-bin)
            ensure_flatpak com.heroicgameslauncher.hgl ;;
        upscaler)
            ensure_flatpak io.gitlab.theevilskeleton.Upscaler ;;
        clash-verge-rev)
            fedora_install_clash_verge "$package" "$user" "$home" ;;
        linuxqq-appimage)
            fedora_install_verified_rpm_target \
                "$package" "$user" "$home" 'Linux QQ' 'linuxqq*.rpm' ;;
        wechat-appimage)
            fedora_install_verified_rpm_target \
                "$package" "$user" "$home" 'WeChat Linux' 'WeChatLinux*.rpm' ;;
        lsfg-vk-bin)
            ensure_packages qt6-qtdeclarative qt6-qtbase
            fedora_install_verified_rpm_target \
                "$package" "$user" "$home" 'lsfg-vk' 'lsfg-vk*.rpm' ;;
        mangojuice-bin)
            ensure_flatpak io.github.radiolamp.mangojuice ;;
        vicinae-bin|vicinae)
            fedora_install_vicinae "$user" "$home" ;;
        fd-rdd-git)
            fedora_install_fd_rdd "$user" "$home" ;;
        tsukimi-bin)
            dnf copr enable -y walker874/tsukimi
            ensure_package tsukimi
            fedora_application_target_satisfied "$package" "$user" "$home" ;;
        thorium-browser-bin)
            fedora_install_verified_rpm_target \
                "$package" "$user" "$home" 'Thorium Browser' 'thorium-browser*.rpm' ;;
        mark-shot)
            fedora_install_verified_rpm_target \
                "$package" "$user" "$home" 'Mark Shot' 'mark-shot-*.rpm' ;;
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
