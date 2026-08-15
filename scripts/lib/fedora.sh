#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Fedora application targets. These helpers deliberately keep third-party
# artifacts out of common-applist.txt: the logical AUR entry remains in the
# shared manifest, while Fedora receives a verified Flatpak/RPM/COPR action.

FEDORA_RPM_DIR=${FEDORA_RPM_DIR:-${SHORIN_RPM_DIR:-}}
FEDORA_FD_RDD_INSTALL_URL=${FEDORA_FD_RDD_INSTALL_URL:-https://raw.githubusercontent.com/vicinae/fd-rdd/main/install.sh}

fedora_user_bin() {
    printf '%s\n' "${2:-$HOME_DIR}/.local/bin/$1"
}

fedora_rpm_file() {
    local pattern=$1 directory file match=''
    local -a directories=()

    [ -n "${FEDORA_RPM_DIR:-}" ] && directories+=("$FEDORA_RPM_DIR")
    [ -n "${SHORIN_ARTIFACT_DIR:-}" ] && directories+=("$SHORIN_ARTIFACT_DIR")
    directories+=("$PWD" "${HOME_DIR:-/nonexistent}/Downloads" /tmp)
    for directory in "${directories[@]}"; do
        [ -d "$directory" ] || continue
        match=''
        while IFS= read -r -d '' file; do
            match=$file
        done < <(find "$directory" -maxdepth 1 -type f -iname "$pattern" -print0 2>/dev/null | sort -z)
        if [ -n "$match" ]; then
            printf '%s\n' "$match"
            return 0
        fi
    done
    return 1
}

fedora_install_local_rpm() {
    local label=$1 pattern=$2 file

    require_writable_mode || return
    file=$(fedora_rpm_file "$pattern") || true
    if [ -z "$file" ]; then
        error "Fedora $label RPM was not found (pattern: $pattern)."
        warn "Place the official RPM in FEDORA_RPM_DIR, SHORIN_ARTIFACT_DIR, the target user's Downloads, or /tmp, then rerun."
        return 1
    fi
    log "Installing official Fedora RPM: $file"
    dnf install -y "$file"
}

fedora_rpm_installed_matching() {
    local pattern=$1
    command -v rpm >/dev/null 2>&1 || return 2
    rpm -qa 2>/dev/null | grep -Eqi "$pattern"
}

fedora_application_target_satisfied() {
    local package=$1 user=${2:-${TARGET_USER:-}} home=${3:-${HOME_DIR:-}}
    local appimage gearlever

    case "$package" in
        heroic-games-launcher-bin)
            state_flatpak_present com.heroicgameslauncher.hgl ;;
        upscaler)
            state_flatpak_present io.gitlab.theevilskeleton.Upscaler ;;
        clash-verge-rev)
            fedora_rpm_installed_matching '(^|[-.])clash[-_]?verge' ||
                command -v clash-verge >/dev/null 2>&1 ;;
        linuxqq-appimage)
            fedora_rpm_installed_matching '(^|[-.])linuxqq' ||
                command -v qq >/dev/null 2>&1 ;;
        wechat-appimage)
            fedora_rpm_installed_matching '(^|[-.])wechat' ||
                command -v wechat >/dev/null 2>&1 ;;
        lsfg-vk-bin)
            package_is_installed qt6-qtdeclarative &&
                package_is_installed qt6-qtbase &&
                (fedora_rpm_installed_matching 'lsfg[-_]?vk' ||
                    command -v lsfg-vk >/dev/null 2>&1) ;;
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
            fedora_rpm_installed_matching 'thorium[-_]?browser' ||
                command -v thorium-browser >/dev/null 2>&1 ;;
        mark-shot)
            fedora_rpm_installed_matching '(^|[-.])mark[-_]?shot' ||
                command -v mark-shot >/dev/null 2>&1 ;;
        typora-free)
            return 1 ;;
        *)
            local mapped
            mapped=$(fedora_arch_target_name "AUR:$package") || return 1
            package_is_installed "$mapped"
            ;;
    esac
}

fedora_vicinae_desktop_satisfied() {
    local home=$1 destination

    destination=$(fedora_user_bin vicinae.AppImage "$home")
    [ -f "$home/.local/share/applications/vicinae.desktop" ] || return 1
    grep -Fqx "Exec=\"$destination\"" \
        "$home/.local/share/applications/vicinae.desktop"
}

fedora_install_vicinae() {
    local user=$1 home=$2 file destination desktop group temporary

    require_writable_mode || return
    ensure_flatpak it.mijorus.gearlever
    destination=$(fedora_user_bin vicinae.AppImage "$home")
    desktop="$home/.local/share/applications/vicinae.desktop"
    if [ -x "$destination" ] && fedora_vicinae_desktop_satisfied "$home"; then
        return 0
    fi
    if [ -n "${FEDORA_VICINAE_APPIMAGE:-}" ] &&
        [ -f "$FEDORA_VICINAE_APPIMAGE" ]; then
        file=$FEDORA_VICINAE_APPIMAGE
    else
        file=$(fedora_rpm_file '*vicinae*.AppImage') || true
    fi
    if [ -z "$file" ]; then
        error 'Official Vicinae AppImage was not found.'
        warn 'Set FEDORA_VICINAE_APPIMAGE to the downloaded official AppImage, or place vicinae*.AppImage in FEDORA_RPM_DIR/SHORIN_ARTIFACT_DIR, the target user Downloads, or /tmp.'
        warn 'Gear Lever is installed, but no Vicinae integration is claimed until the AppImage and its managed desktop entry are present.'
        return 1
    fi
    [[ "$(basename "$file")" =~ [Vv]icinae ]] || {
        error "Artifact does not look like a Vicinae AppImage: $file"
        return 1
    }
    group=$(id -gn "$user")
    install -D -m 755 -o "$user" -g "$group" "$file" "$destination"
    install -d -o "$user" -g "$group" "$(dirname "$desktop")"
    temporary=$(mktemp)
    cat > "$temporary" <<EOF
[Desktop Entry]
Name=Vicinae
Comment=Application launcher
Exec="$destination"
Terminal=false
Type=Application
Categories=Utility;
EOF
    install_if_changed "$temporary" "$desktop" 644
    rm -f "$temporary"
    chown "$user:$group" "$desktop"
    [ -x "$destination" ] && fedora_vicinae_desktop_satisfied "$home"
}

fedora_install_fd_rdd() {
    local user=$1 home=$2 script temporary

    require_writable_mode || return
    if [ -n "${FEDORA_FD_RDD_INSTALL_SCRIPT:-}" ] &&
        [ -r "$FEDORA_FD_RDD_INSTALL_SCRIPT" ]; then
        script=$FEDORA_FD_RDD_INSTALL_SCRIPT
    else
        command -v curl >/dev/null 2>&1 || {
            error 'curl is required to fetch the official fd-rdd install.sh.'
            return 1
        }
        case "$FEDORA_FD_RDD_INSTALL_URL" in
            https://raw.githubusercontent.com/vicinae/fd-rdd/*) ;;
            *)
                error "Refusing a non-official fd-rdd installer URL: $FEDORA_FD_RDD_INSTALL_URL"
                return 1
                ;;
        esac
        temporary=$(mktemp)
        if ! curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
            "$FEDORA_FD_RDD_INSTALL_URL" -o "$temporary"; then
            rm -f "$temporary"
            error "Unable to download official fd-rdd installer: $FEDORA_FD_RDD_INSTALL_URL"
            return 1
        fi
        script=$temporary
    fi
    grep -q '^#!' "$script" || {
        [ -n "${temporary:-}" ] && rm -f "$temporary"
        error 'Downloaded fd-rdd installer did not contain a shebang.'
        return 1
    }
    if ! runuser -u "$user" -- env HOME="$home" bash "$script"; then
        [ -n "${temporary:-}" ] && rm -f "$temporary"
        error 'The official fd-rdd install.sh failed for the target user.'
        return 1
    fi
    [ -n "${temporary:-}" ] && rm -f "$temporary"
    fedora_application_target_satisfied fd-rdd-git "$user" "$home"
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
    local mapped

    require_writable_mode || return
    [ -n "$user" ] && [ -n "$home" ] || {
        error "A Fedora application target requires a target user: $package"
        return 1
    }
    if fedora_application_target_satisfied "$package" "$user" "$home"; then
        log "Skipping Fedora target already satisfied: $package"
        return 0
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
            error 'typora-free has no declared official Fedora source; install it manually and add a Fedora-specific target.'
            return 1 ;;
        *)
            mapped=$(fedora_arch_target_name "AUR:$package") || {
                error "No Fedora mapping exists for AUR target: $package"
                return 1
            }
            ensure_package "$mapped" ;;
    esac
}
