#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SHORIN_ROOT=${SHORIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
source "$SHORIN_ROOT/scripts/lib/verify.sh"

NAS_IP=${NAS_IP:-10.0.0.104}
NAS_REMOTE_PATH=${NAS_REMOTE_PATH:-/mnt/user/115yun/arch}
NAS_LOCAL_PATH=${NAS_LOCAL_PATH:-/mnt/nas}

nas_rime_user_bus_is_available() {
    [ -n "${TARGET_USER:-}" ] &&
        [ -S "/run/user/$(id -u "$TARGET_USER")/bus" ]
}

nas_rime_mark_pending_login() {
    if [ "$MODULE_RESULT" -eq "$RC_OK" ] &&
        ! nas_rime_user_bus_is_available; then
        module_skip rime-sync-pending-login
    fi
}

nas_rime_check() {
    if [ -z "${TARGET_USER:-}" ] || [ -z "${HOME_DIR:-}" ]; then
        module_inspection_failed target-user-context
        return
    fi
    module_check_state package:nfs-utils state_package_present nfs-utils
    module_check_state fstab:nas state_fstab_entry \
        "$NAS_IP:$NAS_REMOTE_PATH" "$NAS_LOCAL_PATH" nfs \
        defaults,_netdev,nofail
    module_check_state rime:installation \
        state_file_nonempty "$HOME_DIR/.local/share/fcitx5/rime/installation.yaml"
    module_check_state unit:rime-sync \
        state_user_unit_enabled "$TARGET_USER" rime-sync.timer timers.target
    nas_rime_mark_pending_login
}

nas_rime_apply() {
    local status=0

    bash "$SHORIN_ROOT/scripts/modules/nas-rime/apply.sh" "$TARGET_USER" || status=$?
    case "$status" in
        0|20) return 0 ;;
        *) return "$status" ;;
    esac
}

nas_rime_verify() {
    if [ -z "${TARGET_USER:-}" ] || [ -z "${HOME_DIR:-}" ]; then
        module_verify_failed target-user-context
        return
    fi
    verify_package nfs-utils || module_verify_failed package:nfs-utils
    state_fstab_entry "$NAS_IP:$NAS_REMOTE_PATH" "$NAS_LOCAL_PATH" nfs \
        defaults,_netdev,nofail || module_verify_failed fstab:nas
    verify_file "$HOME_DIR/.local/share/fcitx5/rime/installation.yaml" ||
        module_verify_failed rime:installation
    verify_user_unit "$TARGET_USER" rime-sync.timer timers.target ||
        module_verify_failed unit:rime-sync
    nas_rime_mark_pending_login
}

module_main nas-rime "$@"
