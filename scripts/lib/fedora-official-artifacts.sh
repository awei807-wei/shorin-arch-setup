#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Official Fedora application assets with complete provenance evidence.  The
# values are intentionally assigned, not environment-overridable: a caller
# may change the cache/artifact location, but never the production checksum.
FEDORA_VICINAE_VERSION_PINNED=0.26.0
FEDORA_VICINAE_ASSET_PINNED=Vicinae-x86_64.AppImage
FEDORA_VICINAE_URL_PINNED=https://github.com/vicinaehq/vicinae/releases/download/v0.26.0/Vicinae-x86_64.AppImage
FEDORA_VICINAE_SHA256_PINNED=17a6c4c64c233cb1ae11cdc21c17fb3e6c79156b5d58080326c01cefc965d3f2
FEDORA_VICINAE_RELEASE_API_URL_PINNED=https://api.github.com/repos/vicinaehq/vicinae/releases/tags/v0.26.0

FEDORA_CLASH_VERGE_VERSION_PINNED=2.5.2
FEDORA_CLASH_VERGE_ASSET_PINNED=Clash.Verge-2.5.2-1.x86_64.rpm
FEDORA_CLASH_VERGE_URL_PINNED=https://github.com/clash-verge-rev/clash-verge-rev/releases/download/v2.5.2/Clash.Verge-2.5.2-1.x86_64.rpm
FEDORA_CLASH_VERGE_SHA256_PINNED=5b8edb94cd270b1d4655217378aeddf37a735151574ddb8853128bdd1ca86454

FEDORA_LSFG_VK_VERSION_PINNED=1.0.0
FEDORA_LSFG_VK_ASSET_PINNED=lsfg-vk-1.0.0-1.x86_64.rpm
FEDORA_LSFG_VK_URL_PINNED=https://github.com/PancakeTAS/lsfg-vk/releases/download/v1.0.0/lsfg-vk-1.0.0-1.x86_64.rpm
FEDORA_LSFG_VK_SHA256_PINNED=77749bbd5bddd19ea38b090e0cec8912e9285a92b9345429df924dc33cc47786

FEDORA_MARK_SHOT_VERSION_PINNED=0.1.48
FEDORA_MARK_SHOT_ASSET_PINNED=mark-shot-0.1.48-1.x86_64.rpm
FEDORA_MARK_SHOT_URL_PINNED=https://github.com/marktext/mark-shot/releases/download/v0.1.48/mark-shot-0.1.48-1.x86_64.rpm
FEDORA_MARK_SHOT_SHA256_PINNED=a037e2733480cf0bb3e671472c6fe9d33b8189ff174c1f13972d1a0cfaa4d1e2

FEDORA_LINUXQQ_VERSION_PINNED=3.2.32
FEDORA_LINUXQQ_ASSET_PINNED=QQ_3.2.32_260812_x86_64_01.rpm
FEDORA_LINUXQQ_URL_PINNED=https://qqdl.gtimg.cn/qqfile/QQNT/9.9.33/release/3f89efc5/QQ_3.2.32_260812_x86_64_01.rpm
FEDORA_LINUXQQ_SIZE_PINNED=187341996
FEDORA_LINUXQQ_SHA256_PINNED=6ce82940f7f94d18d003ed93cb3ab7feaa44a160fbdc45f8f01b4cf08bf34ddf

FEDORA_VICINAE_VERSION=$FEDORA_VICINAE_VERSION_PINNED
FEDORA_VICINAE_ASSET=$FEDORA_VICINAE_ASSET_PINNED
FEDORA_VICINAE_URL=$FEDORA_VICINAE_URL_PINNED
FEDORA_VICINAE_SHA256=$FEDORA_VICINAE_SHA256_PINNED
FEDORA_VICINAE_RELEASE_API_URL=$FEDORA_VICINAE_RELEASE_API_URL_PINNED
FEDORA_CLASH_VERGE_VERSION=$FEDORA_CLASH_VERGE_VERSION_PINNED
FEDORA_CLASH_VERGE_ASSET=$FEDORA_CLASH_VERGE_ASSET_PINNED
FEDORA_CLASH_VERGE_URL=$FEDORA_CLASH_VERGE_URL_PINNED
FEDORA_CLASH_VERGE_SHA256=$FEDORA_CLASH_VERGE_SHA256_PINNED
FEDORA_LSFG_VK_VERSION=$FEDORA_LSFG_VK_VERSION_PINNED
FEDORA_LSFG_VK_ASSET=$FEDORA_LSFG_VK_ASSET_PINNED
FEDORA_LSFG_VK_URL=$FEDORA_LSFG_VK_URL_PINNED
FEDORA_LSFG_VK_SHA256=$FEDORA_LSFG_VK_SHA256_PINNED
FEDORA_MARK_SHOT_VERSION=$FEDORA_MARK_SHOT_VERSION_PINNED
FEDORA_MARK_SHOT_ASSET=$FEDORA_MARK_SHOT_ASSET_PINNED
FEDORA_MARK_SHOT_URL=$FEDORA_MARK_SHOT_URL_PINNED
FEDORA_MARK_SHOT_SHA256=$FEDORA_MARK_SHOT_SHA256_PINNED
FEDORA_LINUXQQ_VERSION=$FEDORA_LINUXQQ_VERSION_PINNED
FEDORA_LINUXQQ_ASSET=$FEDORA_LINUXQQ_ASSET_PINNED
FEDORA_LINUXQQ_URL=$FEDORA_LINUXQQ_URL_PINNED
FEDORA_LINUXQQ_SIZE=$FEDORA_LINUXQQ_SIZE_PINNED
FEDORA_LINUXQQ_SHA256=$FEDORA_LINUXQQ_SHA256_PINNED

fedora_official_x86_64_guard() {
    local label=$1 machine=${FEDORA_OFFICIAL_MACHINE:-$(uname -m)}

    [ "$machine" = x86_64 ] || {
        FEDORA_APPLICATION_PENDING_REASON="official-asset-x86_64-only:label=$label:detected=$machine"
        warn "Pending Fedora target: $label official asset supports x86_64 only (detected $machine)."
        return "$RC_SKIPPED"
    }
}

fedora_official_cache_path() {
    local home=$1 asset=$2 cache_dir

    cache_dir=${FEDORA_OFFICIAL_CACHE_DIR:-$home/.cache/shorin-arch-setup/fedora-applications}
    install -d -m 755 "$cache_dir"
    printf '%s\n' "$cache_dir/$asset"
}

fedora_verify_official_asset_file() {
    local file=$1 expected=$2 label=$3

    [ -f "$file" ] && [ ! -L "$file" ] && [ -s "$file" ] || {
        error "$label official asset is missing or empty: $file"
        return 1
    }
    printf '%s  %s\n' "$expected" "$file" |
        sha256sum -c - >/dev/null 2>&1 || {
        error "$label official asset failed SHA-256 verification: $file"
        return 1
    }
}

fedora_download_verified_official_asset() {
    local url=$1 asset=$2 expected=$3 cache_dir=$4 expected_size=${5:-}
    local destination temporary

    [[ "$url" == https://* ]] || {
        error "Refusing non-HTTPS Fedora official asset URL: $url"
        return 1
    }
    command -v curl >/dev/null 2>&1 || {
        FEDORA_APPLICATION_PENDING_REASON="official-download-requires-curl:asset=$asset:url=$url"
        warn "Pending Fedora artifact: curl is unavailable for $asset."
        return "$RC_SKIPPED"
    }
    command -v sha256sum >/dev/null 2>&1 || {
        error "sha256sum is required to verify Fedora official asset: $asset"
        return 1
    }
    install -d -m 755 "$cache_dir"
    destination="$cache_dir/$asset"
    if fedora_verify_official_asset_file "$destination" "$expected" "$asset" &&
        { [ -z "$expected_size" ] || [ "$(stat -c '%s' "$destination")" = "$expected_size" ]; }; then
        printf '%s\n' "$destination"
        return 0
    fi
    rm -f -- "$destination"
    temporary=$(mktemp "$cache_dir/.${asset}.XXXXXX")
    if ! curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        "$url" -o "$temporary"; then
        rm -f -- "$temporary"
        FEDORA_APPLICATION_PENDING_REASON="official-download-failed:asset=$asset:url=$url"
        warn "Pending Fedora artifact: download failed for $asset ($url)."
        return "$RC_SKIPPED"
    fi
    if ! fedora_verify_official_asset_file "$temporary" "$expected" "$asset"; then
        rm -f -- "$temporary"
        return 1
    fi
    if [ -n "$expected_size" ] &&
        [ "$(stat -c '%s' "$temporary")" != "$expected_size" ]; then
        rm -f -- "$temporary"
        error "$asset failed the fixed size check (expected $expected_size bytes)."
        return 1
    fi
    chmod 644 "$temporary"
    if ! mv -f -- "$temporary" "$destination"; then
        rm -f -- "$temporary"
        error "Unable to atomically cache Fedora official asset: $destination"
        return 1
    fi
    printf '%s\n' "$destination"
}

fedora_install_official_rpm_target() {
    local package=$1 user=$2 home=$3 label=$4 pattern=$5 url=$6 asset=$7 expected=$8
    local local_file='' status=0 cache_dir downloaded

    require_writable_mode || return
    local_file=$(fedora_rpm_file "$pattern" 2>/dev/null || true)
    if [ -n "$local_file" ]; then
        fedora_install_verified_official_rpm_file \
            "$package" "$user" "$home" "$label" "$local_file" "$expected"
        return $?
    fi

    # Preserve the existing local-artifact handoff contract.  This also lets
    # downstream packagers provide a verified artifact helper without forcing
    # a network request; the real helper returns RC_SKIPPED when none exists.
    fedora_install_local_rpm "$label" "$pattern" || status=$?
    if [ "$status" -eq 0 ]; then
        fedora_application_target_satisfied "$package" "$user" "$home"
        return
    fi
    [ "$status" -eq "$RC_SKIPPED" ] || [ "$status" -eq 1 ] || return "$status"

    fedora_official_x86_64_guard "$label" || return
    cache_dir=${FEDORA_OFFICIAL_CACHE_DIR:-$home/.cache/shorin-arch-setup/fedora-applications}
    downloaded=$(fedora_download_verified_official_asset \
        "$url" "$asset" "$expected" "$cache_dir") || return
    fedora_official_rpm_identity_for_target "$package" "$downloaded" "$label" || return
    dnf install -y "$downloaded" || {
        error "Failed to install verified Fedora official RPM: $downloaded"
        return 1
    }
    fedora_application_target_satisfied "$package" "$user" "$home"
}

fedora_install_verified_official_rpm_file() {
    local package=$1 user=$2 home=$3 label=$4 file=$5 expected=$6
    local identity_pattern=${7:-}

    fedora_verify_official_asset_file "$file" "$expected" "$label" || return
    if [ -n "$identity_pattern" ]; then
        fedora_verify_official_rpm_identity \
            "$file" "$label" "$identity_pattern" || return
    else
        fedora_official_rpm_identity_for_target \
            "$package" "$file" "$label" || return
    fi
    dnf install -y "$file" || {
        error "Failed to install verified Fedora official RPM: $file"
        return 1
    }
    fedora_application_target_satisfied "$package" "$user" "$home"
}

fedora_official_rpm_identity_for_target() {
    local package=$1 file=$2 label=$3 pattern

    case "$package" in
        clash-verge-rev) pattern='([Cc]lash|[Vv]erge)' ;;
        lsfg-vk-bin) pattern='lsfg[-_]?vk' ;;
        mark-shot) pattern='[Mm]ark[-_]?shot' ;;
        *) return 0 ;;
    esac
    fedora_verify_official_rpm_identity "$file" "$label" "$pattern"
}

fedora_verify_official_rpm_identity() {
    local file=$1 label=$2 expected_pattern=$3 metadata package architecture

    command -v rpm >/dev/null 2>&1 || {
        error "rpm is required to inspect the $label package identity."
        return 1
    }
    metadata=$(rpm -qp --qf '%{NAME} %{ARCH}\n' "$file" 2>/dev/null) || {
        error "Unable to inspect RPM metadata for $label: $file"
        return 1
    }
    read -r package architecture <<< "$metadata"
    [ "$architecture" = x86_64 ] || {
        error "$label RPM is not an x86_64 package: $architecture"
        return 1
    }
    [[ "$package" =~ $expected_pattern ]] || {
        error "$label RPM has an unexpected package name: $package"
        return 1
    }
}

fedora_install_official_linuxqq() {
    local package=$1 user=$2 home=$3 pattern='QQ_*.rpm'
    local local_file='' status=0 cache_dir downloaded

    require_writable_mode || return
    local_file=$(fedora_rpm_file "$pattern" 2>/dev/null || true)
    if [ -n "$local_file" ]; then
        fedora_install_verified_official_rpm_file \
            "$package" "$user" "$home" 'Linux QQ' "$local_file" \
            "$FEDORA_LINUXQQ_SHA256"
        return
    fi
    # Keep compatibility with explicit local-artifact test/provider hooks.
    fedora_install_local_rpm 'Linux QQ' "$pattern" || status=$?
    if [ "$status" -eq 0 ]; then
        fedora_application_target_satisfied "$package" "$user" "$home"
        return
    fi
    [ "$status" -eq "$RC_SKIPPED" ] || [ "$status" -eq 1 ] || return "$status"
    fedora_official_x86_64_guard 'Linux QQ' || return
    cache_dir=${FEDORA_OFFICIAL_CACHE_DIR:-$home/.cache/shorin-arch-setup/fedora-applications}
    downloaded=$(fedora_download_verified_official_asset \
        "$FEDORA_LINUXQQ_URL" "$FEDORA_LINUXQQ_ASSET" \
        "$FEDORA_LINUXQQ_SHA256" "$cache_dir" "$FEDORA_LINUXQQ_SIZE") || return
    fedora_verify_official_rpm_identity "$downloaded" 'Linux QQ' \
        '([Qq][Qq]|[Ll]inux[Qq][Qq])' || return
    dnf install -y "$downloaded" || {
        error "Failed to install verified Fedora Linux QQ RPM: $downloaded"
        return 1
    }
    fedora_application_target_satisfied "$package" "$user" "$home"
}
