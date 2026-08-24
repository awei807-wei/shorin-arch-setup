#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/modules/nas-rime/contract.sh"

check_root

TARGET_USER=${1:-${TARGET_USER:-}}
if [ -z "$TARGET_USER" ]; then
    TARGET_USER=$(logname 2>/dev/null ||
        awk -F: '$3 == 1000 {print $1; exit}' /etc/passwd)
fi
[ -n "$TARGET_USER" ] || die 'Unable to resolve the NAS/Rime target user.'
if [ -z "${HOME_DIR:-}" ]; then
    HOME_DIR=$(getent passwd "$TARGET_USER" | cut -d: -f6)
fi
[ -d "$HOME_DIR" ] || die "Home directory not found: $HOME_DIR"

nas_rime_contract_init
NAS_APPLY_PENDING=0

section "NAS" "Persistent NFS Mounting"

ensure_package nfs-utils
ensure_packages "${RIME_REQUIRED_PACKAGES[@]}"
install -d "$NAS_LOCAL_PATH"
ensure_fstab_entry "$NAS_IP:$NAS_REMOTE_PATH" "$NAS_LOCAL_PATH" nfs \
    defaults,_netdev,nofail 0 0 "${FSTAB_FILE:-/etc/fstab}"
nas_rime_reload_systemd_for_fstab "${FSTAB_FILE:-/etc/fstab}" || {
    error 'Failed to reload systemd after updating /etc/fstab.'
    exit 1
}

if mountpoint -q "$NAS_LOCAL_PATH"; then
    if ! timeout 2 ls "$NAS_LOCAL_PATH" >/dev/null 2>&1; then
        warn "The existing NAS mount is not responding; leaving it mounted for manual recovery."
        NAS_APPLY_PENDING=1
    fi
else
    if timeout 30 mount "$NAS_LOCAL_PATH" >/dev/null 2>&1 &&
        timeout 3 ls "$NAS_LOCAL_PATH" >/dev/null 2>&1; then
        log "NAS mounted at $NAS_LOCAL_PATH."
    else
        warn "NAS is offline; persistent targets will still be converged."
        NAS_APPLY_PENDING=1
    fi
fi

section "Rime" "Configuration & Sync"

rime_dict_manager_available ||
    die 'rime_dict_manager is required; converge the base module first.'
install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" "$RIME_DIR"

installation_tmp=$(mktemp)
if [ -f "$RIME_INSTALLATION_FILE" ]; then
    awk '$0 !~ /^[[:space:]]*(installation_id|sync_dir)[[:space:]]*:/' \
        "$RIME_INSTALLATION_FILE" > "$installation_tmp"
fi
printf 'installation_id: "%s"\nsync_dir: "%s"\n' \
    "$RIME_INSTALLATION_ID" "$RIME_SYNC_DIR" >> "$installation_tmp"
install_if_changed "$installation_tmp" "$RIME_INSTALLATION_FILE" 644
rm -f "$installation_tmp"
chown "$TARGET_USER:" "$RIME_INSTALLATION_FILE"
rime_installation_matches

if nas_rime_online && [ -d "$RIME_SYNC_DIR" ]; then
    runuser -u "$TARGET_USER" -- "$RIME_DICT_MANAGER_PATH" -s ||
        { warn 'Initial Rime dictionary synchronization failed; the timer remains enabled.'; NAS_APPLY_PENDING=1; }
fi

section "Systemd" "Automated Rime Synchronization"

# Install safe sync script with NAS ESTALE + LOCK conflict handling
install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" \
    "$HOME_DIR/.local/bin"
safe_sync_tmp=$(mktemp)
rime_safe_sync_script_contract > "$safe_sync_tmp"
install_if_changed "$safe_sync_tmp" "$HOME_DIR/.local/bin/rime-safe-sync.sh" 755
rm -f "$safe_sync_tmp"
chown "$TARGET_USER:" "$HOME_DIR/.local/bin/rime-safe-sync.sh"
chmod 755 "$HOME_DIR/.local/bin/rime-safe-sync.sh"

install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" \
    "$RIME_USER_UNIT_DIR"
service_tmp=$(mktemp)
timer_tmp=$(mktemp)
rime_service_contract > "$service_tmp"
rime_timer_contract > "$timer_tmp"
install_if_changed "$service_tmp" "$RIME_SERVICE_FILE" 644
install_if_changed "$timer_tmp" "$RIME_TIMER_FILE" 644
rm -f "$service_tmp" "$timer_tmp"
chown "$TARGET_USER:" "$RIME_SERVICE_FILE" "$RIME_TIMER_FILE"

rime_service_matches
rime_timer_matches
ensure_user_unit_enabled "$TARGET_USER" rime-sync.timer timers.target "$HOME_DIR"
rime_timer_link_matches

if ! user_unit_bus_is_available "$TARGET_USER"; then
    warn 'Rime synchronization is enabled and will start at the next user login.'
    NAS_APPLY_PENDING=1
fi

[ "$NAS_APPLY_PENDING" -eq 0 ] || exit 20
