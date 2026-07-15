#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

vcp_contract_init() {
    VCP_DIR=${VCP_DIR:-$HOME_DIR/Downloads/VCPChat}
    VCP_BACKUP_SCRIPT=${VCP_BACKUP_SCRIPT:-$HOME_DIR/.local/share/scripts/vcp_nas_sync.py}
    VCP_DESKTOP_FILE=${VCP_DESKTOP_FILE:-$HOME_DIR/.local/share/applications/vchat.desktop}
    VCP_USER_UNIT_DIR=$HOME_DIR/.config/systemd/user
    VCP_BACKUP_SERVICE=$VCP_USER_UNIT_DIR/vcp-backup.service
    VCP_BACKUP_TIMER=$VCP_USER_UNIT_DIR/vcp-backup.timer
    VCP_SUDOERS_FILE=${VCP_SUDOERS_FILE:-/etc/sudoers.d/vcp-backup}
    VCP_PYTHON=${VCP_PYTHON:-$(command -v python 2>/dev/null || true)}
    VCP_NPM=${VCP_NPM:-$(command -v npm 2>/dev/null || true)}
}

vcp_backup_service_contract() {
    cat <<EOF
[Unit]
Description=VCPChat NAS Daily Backup (Hot-plug Mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart="$VCP_PYTHON" "$VCP_BACKUP_SCRIPT"
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
}

vcp_backup_timer_contract() {
    cat <<'EOF'
[Unit]
Description=Run VCPChat Backup at 16:00 Daily

[Timer]
OnCalendar=*-*-* 16:00:00
Persistent=true
Unit=vcp-backup.service

[Install]
WantedBy=timers.target
EOF
}

vcp_sudoers_contract() {
    printf '%s ALL=(ALL) NOPASSWD: /usr/bin/mount, /usr/bin/umount, /usr/bin/mkdir\n' \
        "$TARGET_USER"
}

vcp_desktop_contract() {
    cat <<EOF
[Desktop Entry]
Name=VCPChat
Comment=Start VCPChat Environment
Exec="$VCP_NPM" start --prefix "$VCP_DIR" -- --ozone-platform=wayland --enable-features=WaylandWindowDecorations
Icon=utilities-terminal
Terminal=false
Type=Application
Categories=Development;
Keywords=vchat;vcp;npm;
EOF
}

vcp_managed_text_matches() {
    local file=$1 renderer=$2 actual expected

    [ -f "$file" ] || return 1
    actual=$(< "$file")
    expected=$($renderer)
    [ "$actual" = "$expected" ]
}

vcp_backup_service_matches() {
    [ -n "$VCP_PYTHON" ] &&
        vcp_managed_text_matches "$VCP_BACKUP_SERVICE" \
            vcp_backup_service_contract
}

vcp_backup_timer_matches() {
    vcp_managed_text_matches "$VCP_BACKUP_TIMER" vcp_backup_timer_contract
}

vcp_sudoers_matches() {
    vcp_managed_text_matches "$VCP_SUDOERS_FILE" vcp_sudoers_contract &&
        { ! command -v visudo >/dev/null 2>&1 ||
            visudo -cf "$VCP_SUDOERS_FILE" >/dev/null 2>&1; }
}

vcp_desktop_matches() {
    [ -n "$VCP_NPM" ] && [ -x "$VCP_NPM" ] &&
        vcp_managed_text_matches "$VCP_DESKTOP_FILE" vcp_desktop_contract
}

vcp_backup_link_matches() {
    local link="$VCP_USER_UNIT_DIR/timers.target.wants/vcp-backup.timer"

    [ -L "$link" ] && [ "$(readlink "$link")" = ../vcp-backup.timer ]
}

vcp_backup_timer_is_active() {
    local user=$1 uid runtime_dir

    uid=$(id -u "$user") || return 2
    runtime_dir="${SHORIN_USER_RUNTIME_ROOT:-/run/user}/$uid"
    [ -S "$runtime_dir/bus" ] || return 2
    runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime_dir" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
        systemctl --user is-active --quiet vcp-backup.timer
}

vcp_backup_artifacts_exist() {
    [ -e "$VCP_BACKUP_SERVICE" ] || [ -L "$VCP_BACKUP_SERVICE" ] ||
        [ -e "$VCP_BACKUP_TIMER" ] || [ -L "$VCP_BACKUP_TIMER" ] ||
        [ -e "$VCP_SUDOERS_FILE" ] || [ -L "$VCP_SUDOERS_FILE" ] ||
        [ -e "$VCP_USER_UNIT_DIR/timers.target.wants/vcp-backup.timer" ] ||
        [ -L "$VCP_USER_UNIT_DIR/timers.target.wants/vcp-backup.timer" ]
}

vcp_desktop_artifact_exists() {
    [ -e "$VCP_DESKTOP_FILE" ] || [ -L "$VCP_DESKTOP_FILE" ]
}
