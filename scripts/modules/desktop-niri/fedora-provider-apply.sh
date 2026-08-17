#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Shared Fedora provider apply paths.  The full desktop module uses the
# system path below; the standalone user entry uses the prerequisite-checking
# path and deliberately never invokes a package manager.

FEDORA_PROVIDER_APPLY_REASON=''

fedora_desktop_provider_apply_system() {
    local user=${1:-${TARGET_USER:-}} home=${2:-${HOME_DIR:-}}

    platform_is_fedora || return 0
    [ -n "$user" ] && [ -n "$home" ] || {
        FEDORA_PROVIDER_APPLY_REASON=target-user-missing
        error 'Fedora desktop provider apply requires a target user and home directory.'
        return 1
    }
    fedora_provider_architecture_satisfied || {
        FEDORA_PROVIDER_APPLY_REASON=unsupported-architecture
        error 'Fedora desktop provider apply supports x86_64 only; refusing system changes.'
        return 1
    }
    ensure_packages curl unzip xz tar util-linux fontconfig || {
        FEDORA_PROVIDER_APPLY_REASON=prerequisites-package-failed
        error 'Fedora desktop provider prerequisites did not converge; refusing provider apply.'
        return 1
    }
    fedora_install_desktop_providers "$user" "$home" || {
        FEDORA_PROVIDER_APPLY_REASON=provider-transaction-failed
        error 'Fedora target-user providers did not converge; refusing provider apply.'
        return 1
    }
    FEDORA_PROVIDER_APPLY_REASON=ok
}

fedora_desktop_provider_apply_user() {
    local user=${1:-${TARGET_USER:-}} home=${2:-${HOME_DIR:-}} prerequisite_status=0

    platform_is_fedora || {
        FEDORA_PROVIDER_APPLY_REASON=platform-not-fedora
        error "Standalone Fedora desktop provider entry requires Fedora (detected ${SHORIN_DISTRO:-unknown})."
        return 1
    }
    [ -n "$user" ] && [ -n "$home" ] || {
        FEDORA_PROVIDER_APPLY_REASON=target-user-missing
        error 'Standalone Fedora desktop provider entry requires a target user and home directory.'
        return 1
    }
    fedora_provider_architecture_satisfied || {
        FEDORA_PROVIDER_APPLY_REASON=unsupported-architecture
        error 'Standalone Fedora desktop provider entry supports x86_64 only; no assets were changed.'
        return 1
    }
    fedora_target_user_provider_prerequisites_satisfied "$user" "$home" ||
        prerequisite_status=$?
    [ "$prerequisite_status" -eq 0 ] || {
        FEDORA_PROVIDER_APPLY_REASON=prerequisites-missing
        error 'Standalone Fedora desktop provider entry requires curl, sha256sum, tar, unzip, xz, flock and fontconfig in the target-user environment; no assets were changed.'
        [ "$prerequisite_status" -gt 1 ] || prerequisite_status=2
        return "$prerequisite_status"
    }
    fedora_install_desktop_providers "$user" "$home" || {
        FEDORA_PROVIDER_APPLY_REASON=provider-transaction-failed
        error 'Standalone Fedora target-user providers did not converge; existing assets were preserved.'
        return 1
    }
    FEDORA_PROVIDER_APPLY_REASON=ok
}
