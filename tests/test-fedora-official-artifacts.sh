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
[ "$FEDORA_MARK_SHOT_SHA256" = \
    a037e2733480cf0bb3e671472c6fe9d33b8189ff174c1f13972d1a0cfaa4d1e2 ] ||
    fail 'Mark Shot official checksum contract changed'
[ "$FEDORA_LINUXQQ_URL" = \
    https://qqdl.gtimg.cn/qqfile/QQNT/9.9.33/release/3f89efc5/QQ_3.2.32_260812_x86_64_01.rpm ] ||
    fail 'Linux QQ official URL contract changed'
[ "$FEDORA_LINUXQQ_SIZE" -eq 187341996 ] ||
    fail 'Linux QQ fixed size contract changed'
[ "$FEDORA_FD_RDD_COMMIT" = \
    44b60573129c67f4471fa70f21b4a0b70bc1fec8 ] ||
    fail 'fd-rdd source commit contract changed'

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
