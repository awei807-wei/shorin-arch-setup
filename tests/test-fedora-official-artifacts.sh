#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SHORIN_DISTRO=fedora SHORIN_MODE=repair SHORIN_READ_ONLY=0
TEST_DIR=$(mktemp -d)
TARGET_USER=$(id -un)
HOME_DIR="$TEST_DIR/home"
mkdir -p "$HOME_DIR"
trap 'find "$TEST_DIR" -depth -delete' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    return 1
}

export TARGET_USER HOME_DIR SHORIN_ROOT
source "$ROOT_DIR/scripts/lib/core.sh"

[ "$FEDORA_VICINAE_SHA256" = \
    17a6c4c64c233cb1ae11cdc21c17fb3e6c79156b5d58080326c01cefc965d3f2 ] ||
    fail 'Vicinae official checksum contract changed'
[ "$FEDORA_CLASH_VERGE_SHA256" = \
    5b8edb94cd270b1d4655217378aeddf37a735151574ddb8853128bdd1ca86454 ] ||
    fail 'Clash Verge official checksum contract changed'
[ "$FEDORA_CLASH_VERGE_ASSET" = Clash.Verge-2.5.2-1.x86_64.rpm ] ||
    fail 'Clash Verge official asset name contract changed'
[ "$FEDORA_LSFG_VK_SHA256" = \
    77749bbd5bddd19ea38b090e0cec8912e9285a92b9345429df924dc33cc47786 ] ||
    fail 'LSFG-VK official checksum contract changed'
[ "$FEDORA_LSFG_VK_ASSET" = lsfg-vk-1.0.0.x86_64.rpm ] ||
    fail 'LSFG-VK official asset name contract changed'
[ "$FEDORA_LSFG_VK_URL" = \
    https://github.com/PancakeTAS/lsfg-vk/releases/download/v1.0.0/lsfg-vk-1.0.0.x86_64.rpm ] ||
    fail 'LSFG-VK official URL contract changed'
[ "$FEDORA_MARK_SHOT_SHA256" = \
    a037e2733480cf0bb3e671472c6fe9d33b8189ff174c1f13972d1a0cfaa4d1e2 ] ||
    fail 'Mark Shot official checksum contract changed'
[ "$FEDORA_MARK_SHOT_ASSET" = mark-shot_0.1.48_fedora_x86_64.rpm ] ||
    fail 'Mark Shot official asset name contract changed'
[ "$FEDORA_MARK_SHOT_URL" = \
    https://github.com/jswysnemc/mark-shot/releases/download/v0.1.48/mark-shot_0.1.48_fedora_x86_64.rpm ] ||
    fail 'Mark Shot official URL contract changed'
[ "$FEDORA_LINUXQQ_URL" = \
    https://qqdl.gtimg.cn/qqfile/QQNT/9.9.33/release/3f89efc5/QQ_3.2.32_260812_x86_64_01.rpm ] ||
    fail 'Linux QQ official URL contract changed'
[ "$FEDORA_LINUXQQ_SIZE" -eq 187341996 ] ||
    fail 'Linux QQ fixed size contract changed'
[ "$FEDORA_WECHAT_VERSION" = 4.1.1.8 ] ||
    fail 'WeChat fixed version contract changed'
[ "$FEDORA_WECHAT_RPM_RELEASE" -eq 1 ] ||
    fail 'WeChat RPM release contract changed'
[ "$FEDORA_WECHAT_ASSET" = WeChatLinux_x86_64.rpm ] ||
    fail 'WeChat official asset name contract changed'
[ "$FEDORA_WECHAT_URL" = \
    https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_x86_64.rpm ] ||
    fail 'WeChat official URL contract changed'
[ "$FEDORA_WECHAT_SIZE" -eq 321286358 ] ||
    fail 'WeChat fixed size contract changed'
[ "$FEDORA_WECHAT_SHA256" = \
    4aec761edac4604b0b301f9ac0385b8a9c46452e8a5783485eb3905ecdd22e8c ] ||
    fail 'WeChat official checksum contract changed'
[ "$FEDORA_THORIUM_TAG" = M151.0.7922.72 ] ||
    fail 'Thorium fixed tag contract changed'
[ "$FEDORA_THORIUM_VERSION" = 151.0.7922.72 ] ||
    fail 'Thorium fixed version contract changed'
[ "$FEDORA_THORIUM_ASSET" = thorium-browser_151.0.7922.72_SSE3.rpm ] ||
    fail 'Thorium official asset name contract changed'
[ "$FEDORA_THORIUM_URL" = \
    https://github.com/gz83/thorium/releases/download/M151.0.7922.72/thorium-browser_151.0.7922.72_SSE3.rpm ] ||
    fail 'Thorium official URL contract changed'
[ "$FEDORA_THORIUM_SIZE" -eq 228988770 ] ||
    fail 'Thorium fixed size contract changed'
[ "$FEDORA_THORIUM_SHA256" = \
    6cd793ac245ff7f0e7b76a1dc9b2c694d996b3eefb4a9ee40e39dc5e0ae11f45 ] ||
    fail 'Thorium official checksum contract changed'
[ "$FEDORA_FD_RDD_COMMIT" = \
    44b60573129c67f4471fa70f21b4a0b70bc1fec8 ] ||
    fail 'fd-rdd source commit contract changed'

# Re-sourcing the artifact library must replace attacker-controlled inherited
# values rather than preserving them as a production URL/checksum.
FEDORA_WECHAT_URL=https://attacker.invalid/wechat.rpm
FEDORA_WECHAT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
FEDORA_THORIUM_URL=https://attacker.invalid/thorium.rpm
FEDORA_THORIUM_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export FEDORA_WECHAT_URL FEDORA_WECHAT_SHA256 FEDORA_THORIUM_URL FEDORA_THORIUM_SHA256
source "$ROOT_DIR/scripts/lib/fedora-official-artifacts.sh"
[ "$FEDORA_WECHAT_URL" = \
    https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_x86_64.rpm ] ||
    fail 'WeChat URL must not be environment-overridable'
[ "$FEDORA_WECHAT_SHA256" = \
    4aec761edac4604b0b301f9ac0385b8a9c46452e8a5783485eb3905ecdd22e8c ] ||
    fail 'WeChat checksum must not be environment-overridable'
[ "$FEDORA_THORIUM_URL" = \
    https://github.com/gz83/thorium/releases/download/M151.0.7922.72/thorium-browser_151.0.7922.72_SSE3.rpm ] ||
    fail 'Thorium URL must not be environment-overridable'
[ "$FEDORA_THORIUM_SHA256" = \
    6cd793ac245ff7f0e7b76a1dc9b2c694d996b3eefb4a9ee40e39dc5e0ae11f45 ] ||
    fail 'Thorium checksum must not be environment-overridable'

RPM_IDENTITY_METADATA='wechat x86_64'
rpm() {
    [ "${1:-}" = -qp ] && [ "${2:-}" = --qf ] || return 1
    printf '%s\n' "$RPM_IDENTITY_METADATA"
}
fedora_verify_official_rpm_identity \
    "$TEST_DIR/wechat.rpm" 'WeChat Linux' '^wechat$' ||
    fail 'WeChat RPM identity must accept the exact official package name and x86_64'
RPM_IDENTITY_METADATA='wechat aarch64'
if fedora_verify_official_rpm_identity \
    "$TEST_DIR/wechat.rpm" 'WeChat Linux' '^wechat$'; then
    fail 'WeChat RPM identity must reject non-x86_64 artifacts'
fi
RPM_IDENTITY_METADATA='com.tencent.WeChat x86_64'
if fedora_verify_official_rpm_identity \
    "$TEST_DIR/wechat.rpm" 'WeChat Linux' '^wechat$'; then
    fail 'WeChat RPM identity must reject the desktop-id-like package name'
fi
RPM_IDENTITY_METADATA='wechat-helper x86_64'
if fedora_verify_official_rpm_identity \
    "$TEST_DIR/wechat.rpm" 'WeChat Linux' '^wechat$'; then
    fail 'WeChat RPM identity must reject similar package names'
fi
RPM_IDENTITY_METADATA='thorium-browser x86_64'
fedora_verify_official_rpm_identity \
    "$TEST_DIR/thorium.rpm" 'Thorium Browser' '^thorium-browser$' ||
    fail 'Thorium RPM identity must accept the exact official package name and x86_64'
RPM_IDENTITY_METADATA='malicious-browser x86_64'
if fedora_verify_official_rpm_identity \
    "$TEST_DIR/thorium.rpm" 'Thorium Browser' '^thorium-browser$'; then
    fail 'Thorium RPM identity must reject an unexpected package name'
fi

BAD_PAYLOAD="$TEST_DIR/bad"
printf 'unverified\n' > "$BAD_PAYLOAD"
export FEDORA_OFFICIAL_CACHE_DIR="$TEST_DIR/cache"
curl() {
    local output=''
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then output=$2; shift 2; else shift; fi
    done
    cp "$BAD_PAYLOAD" "$output"
}
status=0
fedora_download_verified_official_asset \
    https://example.invalid/fixed.rpm fixed.rpm \
    "$FEDORA_MARK_SHOT_SHA256" "$FEDORA_OFFICIAL_CACHE_DIR" || status=$?
[ "$status" -eq 1 ] || fail 'official checksum mismatch must fail closed'
[ ! -e "$FEDORA_OFFICIAL_CACHE_DIR/fixed.rpm" ] ||
    fail 'checksum mismatch must not leave an official cache entry'

# Pinned targets must use the fixed URL/asset/checksum/size tuple and install
# only after the verified RPM identity branch succeeds.
(
    require_writable_mode() { return 0; }
    fedora_download_verified_official_asset() {
        [ "$1" = "$FEDORA_WECHAT_URL" ] || return 1
        [ "$2" = "$FEDORA_WECHAT_ASSET" ] || return 1
        [ "$3" = "$FEDORA_WECHAT_SHA256" ] || return 1
        [ "$5" = "$FEDORA_WECHAT_SIZE" ] || return 1
        FEDORA_OFFICIAL_DOWNLOAD_RESULT="$TEST_DIR/pinned-wechat.rpm"
        : > "$FEDORA_OFFICIAL_DOWNLOAD_RESULT"
    }
    RPM_IDENTITY_METADATA='wechat x86_64'
    fedora_application_target_satisfied() { return 0; }
    dnf() {
        [ "${1:-}" = install ] || return 1
        printf '%s\n' "${!#}" > "$TEST_DIR/pinned-dnf-result"
    }
    fedora_install_official_rpm_target \
        wechat-appimage "$TARGET_USER" "$HOME_DIR" 'WeChat Linux' \
        'WeChatLinux*.rpm' "$FEDORA_WECHAT_URL" "$FEDORA_WECHAT_ASSET" \
        "$FEDORA_WECHAT_SHA256" "$FEDORA_WECHAT_SIZE" pinned
    [ "$(< "$TEST_DIR/pinned-dnf-result")" = "$TEST_DIR/pinned-wechat.rpm" ]
) || fail 'pinned WeChat RPM must download with fixed inputs and install after identity verification'

# Network failure is a pending state, while a downloaded hash drift is a hard
# failure and must not reach dnf or leave a corrupt cache entry.
(
    require_writable_mode() { return 0; }
    FEDORA_OFFICIAL_CACHE_DIR="$TEST_DIR/network-cache"
    fedora_rpm_file() { return 1; }
    curl() { return 1; }
    status=0
    fedora_install_official_rpm_target \
        thorium-browser-bin "$TARGET_USER" "$HOME_DIR" 'Thorium Browser' \
        'thorium-browser*.rpm' "$FEDORA_THORIUM_URL" "$FEDORA_THORIUM_ASSET" \
        "$FEDORA_THORIUM_SHA256" "$FEDORA_THORIUM_SIZE" pinned || status=$?
    [ "$status" -eq "$RC_SKIPPED" ] || exit 1
    [ "$FEDORA_APPLICATION_PENDING_REASON" = \
        "official-download-failed:asset=$FEDORA_THORIUM_ASSET:url=$FEDORA_THORIUM_URL" ] || exit 1
) || fail 'pinned Thorium network failure must remain pending'

HASH_DRIFT_CACHE="$TEST_DIR/hash-drift-cache"
HASH_DRIFT_CALLS="$TEST_DIR/hash-drift-dnf-calls"
mkdir -p "$HASH_DRIFT_CACHE"
(
    require_writable_mode() { return 0; }
    fedora_rpm_file() { return 1; }
    curl() {
        local output=''
        while [ "$#" -gt 0 ]; do
            if [ "$1" = -o ]; then output=$2; shift 2; else shift; fi
        done
        cp "$BAD_PAYLOAD" "$output"
    }
    dnf() { printf '%s\n' "$*" >> "$HASH_DRIFT_CALLS"; }
    status=0
    fedora_install_official_rpm_target \
        wechat-appimage "$TARGET_USER" "$HOME_DIR" 'WeChat Linux' \
        'WeChatLinux*.rpm' "$FEDORA_WECHAT_URL" "$FEDORA_WECHAT_ASSET" \
        "$FEDORA_WECHAT_SHA256" "$FEDORA_WECHAT_SIZE" pinned || status=$?
    [ "$status" -eq 1 ] || exit 1
    [ ! -e "$HASH_DRIFT_CACHE/$FEDORA_WECHAT_ASSET" ] || exit 1
    [ ! -s "$HASH_DRIFT_CALLS" ]
) || fail 'pinned WeChat hash drift must fail closed without dnf or bad cache'

# An explicit cache directory is external state.  In particular, reusing a
# mode-1777 directory such as /tmp must not be turned into a private 0755
# directory by cache preparation or by a verified download.
GOOD_PAYLOAD="$TEST_DIR/good-payload"
printf 'verified Fedora artifact\n' > "$GOOD_PAYLOAD"
GOOD_SHA256=$(sha256sum "$GOOD_PAYLOAD" | awk '{print $1}')
curl() {
    local output=''
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then output=$2; shift 2; else shift; fi
    done
    cp "$GOOD_PAYLOAD" "$output"
}
EXTERNAL_CACHE="$TEST_DIR/external-cache"
mkdir -p "$EXTERNAL_CACHE"
chmod 1777 "$EXTERNAL_CACHE"
EXTERNAL_BEFORE=$(stat -c '%a:%u:%g' "$EXTERNAL_CACHE")
export FEDORA_OFFICIAL_CACHE_DIR="$EXTERNAL_CACHE"
external_path=$(fedora_official_cache_path "$HOME_DIR" fixed.rpm "$TARGET_USER")
[ "$external_path" = "$EXTERNAL_CACHE/fixed.rpm" ] ||
    fail 'external cache path helper returned an unexpected artifact path'
fedora_download_verified_official_asset \
    https://example.invalid/fixed.rpm fixed.rpm "$GOOD_SHA256" \
    "$EXTERNAL_CACHE" '' "$TARGET_USER" "$HOME_DIR" >/dev/null ||
    fail 'verified download into an external cache must succeed'
EXTERNAL_AFTER=$(stat -c '%a:%u:%g' "$EXTERNAL_CACHE")
[ "$EXTERNAL_BEFORE" = "$EXTERNAL_AFTER" ] ||
    fail 'external cache directory mode/owner must remain unchanged'

SYMLINK_CACHE_TARGET="$TEST_DIR/symlink-target"
SYMLINK_CACHE="$TEST_DIR/symlink-cache"
mkdir -p "$SYMLINK_CACHE_TARGET"
ln -s "$SYMLINK_CACHE_TARGET" "$SYMLINK_CACHE"
export FEDORA_OFFICIAL_CACHE_DIR="$SYMLINK_CACHE"
if fedora_official_cache_path "$HOME_DIR" symlink.rpm "$TARGET_USER" >/dev/null; then
    fail 'official cache helper must reject a symlink cache directory'
fi
NON_DIRECTORY_CACHE="$TEST_DIR/non-directory-cache"
printf 'not a directory\n' > "$NON_DIRECTORY_CACHE"
export FEDORA_OFFICIAL_CACHE_DIR="$NON_DIRECTORY_CACHE"
if fedora_official_cache_path "$HOME_DIR" non-directory.rpm "$TARGET_USER" >/dev/null; then
    fail 'official cache helper must reject a non-directory cache path'
fi

# The implicit cache is project-managed: create it component by component and
# keep both the leaf and verified artifact owned by the target user's primary
# group.  This uses the real test user; root-run deployments exercise the same
# contract with the selected desktop user.
unset FEDORA_OFFICIAL_CACHE_DIR
MANAGED_HOME="$TEST_DIR/managed-home"
mkdir -p "$MANAGED_HOME"
managed_path=$(fedora_official_cache_path "$MANAGED_HOME" managed.rpm "$TARGET_USER")
MANAGED_CACHE=$(dirname "$managed_path")
MANAGED_OWNER=$(stat -c '%u:%g' "$MANAGED_CACHE")
[ "$MANAGED_OWNER" = "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" ] ||
    fail 'managed Fedora cache directory must belong to the target user primary group'
[ "$(stat -c '%a' "$MANAGED_CACHE")" = 755 ] ||
    fail 'managed Fedora cache directory must use mode 755'
chmod 700 "$MANAGED_CACHE"
fedora_official_cache_path "$MANAGED_HOME" repaired-mode.rpm "$TARGET_USER" >/dev/null ||
    fail 'managed Fedora cache helper must repair its exact leaf directory mode'
[ "$(stat -c '%a' "$MANAGED_CACHE")" = 755 ] ||
    fail 'managed Fedora cache helper must restore mode 755 on its exact leaf directory'
fedora_download_verified_official_asset \
    https://example.invalid/managed.rpm managed.rpm "$GOOD_SHA256" \
    "$MANAGED_CACHE" '' "$TARGET_USER" "$MANAGED_HOME" >/dev/null ||
    fail 'verified download into the managed cache must succeed'
[ "$(stat -c '%u:%g' "$managed_path")" = \
    "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" ] ||
    fail 'managed Fedora artifact must belong to the target user primary group'
[ "$(stat -c '%a' "$managed_path")" = 644 ] ||
    fail 'managed Fedora artifact must use mode 644'

# 直接由安装器调用下载器时必须保留待处理原因；命令替换会在子 shell 中丢失赋值。
fedora_ensure_flatpak_target() { return 0; }
fedora_rpm_file() { return 1; }
fedora_install_local_rpm() { return "$RC_SKIPPED"; }
curl() { return 1; }
VICINAE_HOME="$TEST_DIR/vicinae-home"
mkdir -p "$VICINAE_HOME"
status=0
fedora_install_official_rpm_target \
    mark-shot "$TARGET_USER" "$VICINAE_HOME" 'Mark Shot' 'mark-shot*.rpm' \
    "$FEDORA_MARK_SHOT_URL" "$FEDORA_MARK_SHOT_ASSET" \
    "$FEDORA_MARK_SHOT_SHA256" || status=$?
[ "$status" -eq "$RC_SKIPPED" ] ||
    fail 'official RPM download failure must remain a pending skip'
[ "$FEDORA_APPLICATION_PENDING_REASON" = \
    "official-download-failed:asset=$FEDORA_MARK_SHOT_ASSET:url=$FEDORA_MARK_SHOT_URL" ] ||
    fail 'official RPM download failure reason must survive direct invocation'
status=0
fedora_install_vicinae "$TARGET_USER" "$VICINAE_HOME" || status=$?
[ "$status" -eq "$RC_SKIPPED" ] ||
    fail 'Vicinae download failure must remain a pending skip'
[ "$FEDORA_APPLICATION_PENDING_REASON" = \
    "official-download-failed:asset=$FEDORA_VICINAE_ASSET:url=$FEDORA_VICINAE_URL" ] ||
    fail 'Vicinae download failure reason must survive direct invocation'

FEDORA_OFFICIAL_MACHINE=aarch64
status=0
fedora_official_x86_64_guard 'Mark Shot' || status=$?
[ "$status" -eq "$RC_SKIPPED" ] || fail 'official x86_64 guard must skip other architectures'
FEDORA_OFFICIAL_MACHINE=x86_64

FLATPAK_SYSTEM=0
FLATPAK_USER=1
FLATPAK_CALLS="$TEST_DIR/flatpak-calls"
flatpak() {
    printf '%s\n' "$*" >> "$FLATPAK_CALLS"
    case "$*" in
        'info --system '* ) [ "$FLATPAK_SYSTEM" -eq 1 ] ;;
        'info --user '* ) [ "$FLATPAK_USER" -eq 1 ] ;;
        'override --user --show '* ) printf 'LANG=zh_CN.UTF-8\n' ;;
        *) return 1 ;;
    esac
}
fedora_flatpak_app_scope com.example.Target "$TARGET_USER" "$HOME_DIR" |
    grep -Fqx user || fail 'user-scope Flatpak must be detected'
fedora_flatpak_override_satisfied com.example.Target "$TARGET_USER" "$HOME_DIR" ||
    fail 'user-scope Flatpak override must be checked'
FLATPAK_SYSTEM=1
fedora_flatpak_app_scope com.example.Target "$TARGET_USER" "$HOME_DIR" |
    grep -Fqx system || fail 'system-scope Flatpak must take precedence when both exist'
grep -Fqx 'info --system com.example.Target' "$FLATPAK_CALLS" ||
    fail 'Flatpak scope check must inspect system scope'
grep -Fqx 'info --user com.example.Target' "$FLATPAK_CALLS" ||
    fail 'Flatpak scope check must inspect target-user scope even when system exists'

printf 'PASS: Fedora official artifact, architecture, checksum, and Flatpak scope contracts\n'
