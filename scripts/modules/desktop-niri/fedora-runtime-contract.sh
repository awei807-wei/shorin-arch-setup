#!/usr/bin/env bash
set -Eeuo pipefail

# Fedora's Plasma runtime contract.  KWin can be installed while an older
# kscreenlocker leaves its inhibitSuspend ABI unresolved, so package presence
# alone is not enough: converge the pair and inspect kwin_wayland's links.

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

NIRI_FEDORA_KWIN_RUNTIME_REASON=unknown

niri_fedora_kwin_wayland_runtime_satisfied() {
    local binary output status=0

    NIRI_FEDORA_KWIN_RUNTIME_REASON=not-applicable
    platform_is_fedora || return 0
    binary=$(type -P kwin_wayland || true)
    if [ -z "$binary" ] || [ ! -x "$binary" ]; then
        NIRI_FEDORA_KWIN_RUNTIME_REASON=missing-kwin-wayland
        return 1
    fi
    if ! command -v ldd >/dev/null 2>&1; then
        NIRI_FEDORA_KWIN_RUNTIME_REASON=missing-ldd
        return 2
    fi
    output=$(ldd -r "$binary" 2>&1) || status=$?
    # ldd may return success while still reporting unresolved symbols, so the
    # diagnostics are authoritative.  Keep the output available to callers
    # through the normal contract reason without dumping it in check mode.
    if grep -Eqi '(undefined symbol|not found)' <<< "$output"; then
        if grep -Eqi 'undefined symbol' <<< "$output"; then
            NIRI_FEDORA_KWIN_RUNTIME_REASON=undefined-symbol
        else
            NIRI_FEDORA_KWIN_RUNTIME_REASON=missing-library
        fi
        return 1
    fi
    if [ "$status" -ne 0 ]; then
        NIRI_FEDORA_KWIN_RUNTIME_REASON=ldd-failed
        return "$status"
    fi
    NIRI_FEDORA_KWIN_RUNTIME_REASON=ok
}

niri_fedora_runtime_target_upgrade() {
    local target=$1 mapped package_status=0

    require_writable_mode || return
    platform_is_fedora || return 0
    mapped=$(fedora_arch_target_name "$target") || return 1
    package_is_installed "$target" || package_status=$?
    case "$package_status" in
        0)
            # ensure_package intentionally treats an installed RPM as
            # converged.  These two KDE runtime packages are different: a
            # mixed Plasma stack can leave kwin_wayland linked against an ABI
            # newer than kscreenlocker, so refresh the exact package from the
            # enabled Fedora repositories even when an older RPM is present.
            dnf upgrade --refresh -y --setopt=install_weak_deps=False \
                "$mapped" || return 1
            ;;
        1) ensure_package "$target" || return ;;
        *) return "$package_status" ;;
    esac
    package_is_installed "$target"
}
