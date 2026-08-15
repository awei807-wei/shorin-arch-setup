#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

RIME_DICT_MANAGER_PATH=${RIME_DICT_MANAGER_PATH:-/usr/bin/rime_dict_manager}

nas_rime_contract_init() {
    NAS_IP=${NAS_IP:-10.0.0.104}
    NAS_REMOTE_PATH=${NAS_REMOTE_PATH:-/mnt/user/115yun/arch}
    NAS_LOCAL_PATH=${NAS_LOCAL_PATH:-/mnt/nas}
    RIME_INSTALLATION_ID=${RIME_INSTALLATION_ID:-${TARGET_USER}_arch}
    RIME_SYNC_DIR=${RIME_SYNC_DIR:-$NAS_LOCAL_PATH/rime_sync}
    RIME_DIR=${RIME_DIR:-$HOME_DIR/.local/share/fcitx5/rime}
    RIME_DICT_MANAGER_PATH=${RIME_DICT_MANAGER_PATH:-/usr/bin/rime_dict_manager}
    RIME_INSTALLATION_FILE=${RIME_INSTALLATION_FILE:-$RIME_DIR/installation.yaml}
    RIME_USER_UNIT_DIR=$HOME_DIR/.config/systemd/user
    RIME_SERVICE_FILE=$RIME_USER_UNIT_DIR/rime-sync.service
    RIME_TIMER_FILE=$RIME_USER_UNIT_DIR/rime-sync.timer
}

if platform_is_fedora; then
    # Fedora's rime_dict_manager is shipped by librime-tools, not by
    # fcitx5-rime.  Arch retains its existing dependency path unchanged.
    readonly -a RIME_REQUIRED_PACKAGES=(librime-tools)
else
    readonly -a RIME_REQUIRED_PACKAGES=()
fi

rime_dict_manager_available() {
    rime_dict_manager_path_is_safe || return 1
    [ -x "$RIME_DICT_MANAGER_PATH" ]
}

rime_dict_manager_path_is_safe() {
    # The same value is emitted into a systemd unit and a generated shell
    # script. Keep the supported override an absolute path and reject syntax
    # characters that either renderer would interpret instead of preserving.
    case "$RIME_DICT_MANAGER_PATH" in
        /*) ;;
        *) return 1 ;;
    esac
    [[ "$RIME_DICT_MANAGER_PATH" != *'"'* ]] || return 1
    [[ "$RIME_DICT_MANAGER_PATH" != *'\\'* ]] || return 1
    [[ "$RIME_DICT_MANAGER_PATH" != *'%'* ]] || return 1
    [[ "$RIME_DICT_MANAGER_PATH" != *$'\n'* ]] || return 1
    [[ "$RIME_DICT_MANAGER_PATH" != *$'\r'* ]] || return 1
}

rime_service_contract() {
    rime_dict_manager_path_is_safe || return 1
    cat <<EOF
[Unit]
Description=Rime Dictionary Sync
After=network-online.target
ConditionPathIsMountPoint=$NAS_LOCAL_PATH

[Service]
Type=oneshot
ExecStartPre=/usr/bin/test -x "$RIME_DICT_MANAGER_PATH"
ExecStartPre=/usr/bin/test -x "$HOME_DIR/.local/bin/rime-safe-sync.sh"
ExecStart="$HOME_DIR/.local/bin/rime-safe-sync.sh"
WorkingDirectory=$RIME_DIR

[Install]
WantedBy=default.target
EOF
}

rime_safe_sync_script_contract() {
    rime_dict_manager_path_is_safe || return 1
    cat <<SAFE_SYNC_EOF
#!/bin/bash
# Rime 安全同步脚本
# 解决两个问题：NAS ESTALE coredump + fcitx5 LOCK 排他锁冲突

SYNC_DIR="$RIME_SYNC_DIR"
RIME_DIR="$RIME_DIR"
NAS_MOUNT="$NAS_LOCAL_PATH"
LOCK_FILE="\$RIME_DIR/rime_ice.userdb/LOCK"

# 1. 检测 NAS 挂载是否健康（非 Stale）
if ! stat "\$SYNC_DIR" >/dev/null 2>&1; then
    echo "NAS sync dir inaccessible, attempting remount..."
    sudo umount "\$NAS_MOUNT" 2>/dev/null
    sudo mount -a 2>/dev/null
    sleep 2
    if ! stat "\$SYNC_DIR" >/dev/null 2>&1; then
        echo "NAS still unavailable, skipping sync."
        exit 0
    fi
    echo "NAS remounted successfully."
fi

# 2. 处理 LOCK 排他锁
if [ -f "\$LOCK_FILE" ] && pgrep -x fcitx5 >/dev/null 2>&1; then
    rm -f "\$LOCK_FILE" 2>/dev/null
    echo "Removed stale LOCK for sync."
fi

# 3. 执行同步
cd "\$RIME_DIR" || exit 0
"$RIME_DICT_MANAGER_PATH" --sync 2>&1
SYNC_EXIT=\$?
echo "Sync completed (exit: \$SYNC_EXIT)."

# 4. coredump 检测
if [ \$SYNC_EXIT -eq 134 ]; then
    echo "rime_dict_manager crashed (likely ESTALE during sync). Will retry next cycle."
fi

exit 0
SAFE_SYNC_EOF
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
