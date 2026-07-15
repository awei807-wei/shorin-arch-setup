#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

nas_rime_contract_init() {
    NAS_IP=${NAS_IP:-10.0.0.104}
    NAS_REMOTE_PATH=${NAS_REMOTE_PATH:-/mnt/user/115yun/arch}
    NAS_LOCAL_PATH=${NAS_LOCAL_PATH:-/mnt/nas}
    RIME_INSTALLATION_ID=${RIME_INSTALLATION_ID:-${TARGET_USER}_arch}
    RIME_SYNC_DIR=${RIME_SYNC_DIR:-$NAS_LOCAL_PATH/rime_sync}
    RIME_DIR=${RIME_DIR:-$HOME_DIR/.local/share/fcitx5/rime}
    RIME_INSTALLATION_FILE=${RIME_INSTALLATION_FILE:-$RIME_DIR/installation.yaml}
    RIME_USER_UNIT_DIR=$HOME_DIR/.config/systemd/user
    RIME_SERVICE_FILE=$RIME_USER_UNIT_DIR/rime-sync.service
    RIME_TIMER_FILE=$RIME_USER_UNIT_DIR/rime-sync.timer
}

rime_service_contract() {
    cat <<EOF
[Unit]
Description=Rime Dictionary Sync
After=network-online.target
ConditionPathIsMountPoint="$NAS_LOCAL_PATH"

[Service]
Type=oneshot
ExecStartPre=/usr/bin/test -x /usr/bin/rime_dict_manager
ExecStartPre=/usr/bin/test -d "$RIME_SYNC_DIR"
ExecStart=/usr/bin/rime_dict_manager -s
WorkingDirectory="$RIME_DIR"

[Install]
WantedBy=default.target
EOF
}

rime_timer_contract() {
    cat <<'EOF'
[Unit]
Description=Hourly Rime Sync Timer

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

rime_installation_matches() {
    local file=${1:-$RIME_INSTALLATION_FILE}

    [ -r "$file" ] || return 1
    awk -v installation_id="\"$RIME_INSTALLATION_ID\"" \
        -v sync_dir="\"$RIME_SYNC_DIR\"" '
        /^[[:space:]]*installation_id[[:space:]]*:/ {
            value=$0
            sub(/^[[:space:]]*installation_id[[:space:]]*:[[:space:]]*/, "", value)
            installation_count++
            if (value == installation_id) installation_matches++
        }
        /^[[:space:]]*sync_dir[[:space:]]*:/ {
            value=$0
            sub(/^[[:space:]]*sync_dir[[:space:]]*:[[:space:]]*/, "", value)
            sync_count++
            if (value == sync_dir) sync_matches++
        }
        END {
            exit !(installation_count == 1 && installation_matches == 1 &&
                sync_count == 1 && sync_matches == 1)
        }
    ' "$file"
}

rime_managed_text_matches() {
    local file=$1 renderer=$2 actual expected

    [ -f "$file" ] || return 1
    actual=$(< "$file")
    expected=$($renderer)
    [ "$actual" = "$expected" ]
}

rime_service_matches() {
    rime_managed_text_matches "${1:-$RIME_SERVICE_FILE}" \
        rime_service_contract
}

rime_timer_matches() {
    rime_managed_text_matches "${1:-$RIME_TIMER_FILE}" \
        rime_timer_contract
}

rime_timer_link_matches() {
    local link=${1:-$RIME_USER_UNIT_DIR/timers.target.wants/rime-sync.timer}

    [ -L "$link" ] && [ "$(readlink "$link")" = ../rime-sync.timer ]
}

rime_timer_is_active() {
    local user=$1 uid runtime_dir

    uid=$(id -u "$user") || return 2
    runtime_dir="${SHORIN_USER_RUNTIME_ROOT:-/run/user}/$uid"
    [ -S "$runtime_dir/bus" ] || return 2
    runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime_dir" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
        systemctl --user is-active --quiet rime-sync.timer
}

nas_rime_online() {
    command -v mountpoint >/dev/null 2>&1 || return 2
    command -v timeout >/dev/null 2>&1 || return 2
    mountpoint -q "$NAS_LOCAL_PATH" || return 1
    timeout 3 ls "$NAS_LOCAL_PATH" >/dev/null 2>&1
}
