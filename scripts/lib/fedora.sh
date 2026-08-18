#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Fedora application targets. These helpers deliberately keep third-party
# artifacts out of common-applist.txt: the logical AUR entry remains in the
# shared manifest, while Fedora receives a verified Flatpak/RPM/COPR action.

FEDORA_RPM_DIR=${FEDORA_RPM_DIR:-${SHORIN_RPM_DIR:-}}

fedora_user_bin() {
    printf '%s\n' "${2:-$HOME_DIR}/.local/bin/$1"
}

fedora_user_download_directory() {
    local home=${1:-${HOME_DIR:-}} directory line value

    [ -n "$home" ] || return 1
    if command -v xdg-user-dir >/dev/null 2>&1; then
        directory=$(HOME="$home" XDG_CONFIG_HOME="$home/.config" \
            xdg-user-dir DOWNLOAD 2>/dev/null) || directory=''
        case "$directory" in
            "$home"/*) printf '%s\n' "$directory"; return 0 ;;
        esac
    fi
    if [ -r "$home/.config/user-dirs.dirs" ]; then
        while IFS= read -r line; do
            case "$line" in
                XDG_DOWNLOAD_DIR=\"*\")
                    value=${line#XDG_DOWNLOAD_DIR=\"}
                    value=${value%\"}
                    case "$value" in
                        '$HOME'/*)
                            value="$home/${value#\$HOME/}" ;;
                        /*) ;;
                        *) continue ;;
                    esac
                    case "$value" in
                        "$home"/*) printf '%s\n' "$value"; return 0 ;;
                    esac
                    ;;
            esac
        done < "$home/.config/user-dirs.dirs"
    fi
    [ -d "$home/Downloads" ] && printf '%s\n' "$home/Downloads" && return 0
    [ -d "$home/下载" ] && printf '%s\n' "$home/下载" && return 0
    return 1
}

fedora_rpm_file() {
    local pattern=$1 directory file match='' download_directory
    local -a directories=()

    [ -n "${FEDORA_RPM_DIR:-}" ] && directories+=("$FEDORA_RPM_DIR")
    [ -n "${SHORIN_ARTIFACT_DIR:-}" ] && directories+=("$SHORIN_ARTIFACT_DIR")
    if download_directory=$(fedora_user_download_directory "${HOME_DIR:-}"); then
        directories+=("$download_directory")
    fi
    directories+=("$PWD" "${HOME_DIR:-/nonexistent}/Downloads" \
        "${HOME_DIR:-/nonexistent}/下载" /tmp)
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
        FEDORA_APPLICATION_PENDING_REASON="official-rpm-missing:label=$label:pattern=$pattern:search=FEDORA_RPM_DIR,SHORIN_ARTIFACT_DIR,target-Downloads,target-下载,/tmp"
        warn "Pending Fedora artifact: $label RPM was not found (pattern: $pattern)."
        warn "Place the official RPM in FEDORA_RPM_DIR, SHORIN_ARTIFACT_DIR, the target user's Downloads, or /tmp, then rerun."
        return "$RC_SKIPPED"
    fi
    log "Installing official Fedora RPM: $file"
    dnf install -y "$file"
}

fedora_rpm_installed_matching() {
    local pattern=$1
    platform_rpm_installed_matching "$pattern"
}

fedora_rpm_or_command() {
    local pattern=$1 command_name=$2 status

    if fedora_rpm_installed_matching "$pattern"; then
        return 0
    else
        status=$?
    fi
    [ "$status" -eq 1 ] || return "$status"
    command -v "$command_name" >/dev/null 2>&1
}

fedora_vicinae_desktop_satisfied() {
    local home=$1 destination

    destination=$(fedora_user_bin vicinae.AppImage "$home")
    [ -f "$home/.local/share/applications/vicinae.desktop" ] || return 1
    grep -Fqx "Exec=\"$destination\"" \
        "$home/.local/share/applications/vicinae.desktop"
}

fedora_install_vicinae() {
    local user=$1 home=$2 file destination desktop group temporary cache_dir
    local download_status=0

    require_writable_mode || return
    fedora_ensure_flatpak_target it.mijorus.gearlever "$user" "$home"
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
        fedora_official_x86_64_guard 'Vicinae' || return
        cache_dir=${FEDORA_OFFICIAL_CACHE_DIR:-$home/.cache/shorin-arch-setup/fedora-applications}
        FEDORA_OFFICIAL_DOWNLOAD_RESULT=''
        if fedora_download_verified_official_asset \
            "$FEDORA_VICINAE_URL" "$FEDORA_VICINAE_ASSET" \
            "$FEDORA_VICINAE_SHA256" "$cache_dir" '' "$user" "$home" >/dev/null; then
            file=$FEDORA_OFFICIAL_DOWNLOAD_RESULT
        else
            download_status=$?
        fi
        if [ "$download_status" -ne 0 ]; then
            warn 'Pending Fedora artifact: official Vicinae AppImage could not be downloaded.'
            warn 'Set FEDORA_VICINAE_APPIMAGE to the official AppImage, or place vicinae*.AppImage in FEDORA_RPM_DIR/SHORIN_ARTIFACT_DIR, the target user Downloads, or /tmp.'
            warn 'Gear Lever is installed, but no Vicinae integration is claimed until the AppImage and managed desktop entry are present.'
            return "$RC_SKIPPED"
        fi
    fi
    [[ "$(basename "$file")" =~ [Vv]icinae ]] || {
        error "Artifact does not look like a Vicinae AppImage: $file"
        return 1
    }
    if [ "$file" != "$destination" ]; then
        fedora_verify_official_asset_file "$file" "$FEDORA_VICINAE_SHA256" \
            'Vicinae' || return 1
    fi
    group=$(id -gn "$user")
    install -d -o "$user" -g "$group" "$home/.local"
    temporary=$(mktemp "$home/.local/.vicinae.XXXXXX")
    if ! install -m 755 -o "$user" -g "$group" "$file" "$temporary"; then
        rm -f "$temporary"
        error "Unable to stage Vicinae AppImage for target user $user."
        return 1
    fi
    install -D -m 755 -o "$user" -g "$group" "$temporary" "$destination"
    rm -f "$temporary"
    # Prefer Gear Lever's target-user integration contract.  The managed
    # desktop entry is deliberately created only when the CLI is absent or
    # rejected, so a successful Gear Lever run cannot be duplicated.
    if runuser -u "$user" -- env HOME="$home" \
        XDG_CONFIG_HOME="$home/.config" flatpak run \
        it.mijorus.gearlever --integrate "$destination" --yes \
        >/dev/null 2>&1; then
        if fedora_vicinae_desktop_satisfied "$home"; then
            return 0
        fi
    else
        warn 'Gear Lever CLI integration failed; falling back to one managed Vicinae desktop entry.'
    fi
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


# Provider and application target implementations are kept separate from
# shared Fedora artifact helpers to keep each library focused and auditable.
source "$SHORIN_LIB_DIR/fedora-flatpak.sh"
source "$SHORIN_LIB_DIR/fedora-providers.sh"
source "$SHORIN_LIB_DIR/fedora-official-artifacts.sh"
source "$SHORIN_LIB_DIR/fedora-starship-provider.sh"
source "$SHORIN_LIB_DIR/fedora-font-provider.sh"
source "$SHORIN_LIB_DIR/fedora-font-installer.sh"
source "$SHORIN_LIB_DIR/fedora-provider-transaction.sh"
source "$SHORIN_LIB_DIR/fedora-fd-rdd.sh"
source "$SHORIN_LIB_DIR/fedora-applications.sh"
