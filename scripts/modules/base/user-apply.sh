#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# 03-user.sh - User Creation & Configuration (Visual Fix)
# ==============================================================================

SCRIPT_DIR="${SHORIN_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$SCRIPT_DIR/lib/core.sh"

check_root

# ------------------------------------------------------------------------------
# 1. User Detection / Creation Logic
# ------------------------------------------------------------------------------
section "Phase 3" "User Account Setup"

EXISTING_USER=${TARGET_USER:-$(awk -F: '$3 == 1000 {print $1; exit}' /etc/passwd)}
MY_USERNAME=""
SKIP_CREATION=false

if [ -n "$EXISTING_USER" ] && getent passwd "$EXISTING_USER" >/dev/null; then
    info_kv "Detected User" "$EXISTING_USER"
    log "Using existing user configuration."
    MY_USERNAME="$EXISTING_USER"
    SKIP_CREATION=true
else
    warn "No standard user found (UID 1000)."
    if [ -n "${TARGET_USER:-}" ]; then
        MY_USERNAME=$TARGET_USER
    elif [ "${SHORIN_MODE:-install}" != install ]; then
        die 'Repair requires an existing target user.'
    else
      while true; do
        echo ""
        # 使用 echo -n 打印普通提示，避免 read -p 的兼容性问题
        echo -ne "   Please enter new username: "
        read -r INPUT_USER
        
        # 去除可能误输入的空格
        INPUT_USER=$(echo "$INPUT_USER" | xargs)
        
        if [[ -z "$INPUT_USER" ]]; then
            warn "Username cannot be empty."
            continue
        fi

        # [FIX] 分离打印和读取，确保变量和颜色正确显示
        echo -ne "   Create user '${BOLD}${INPUT_USER}${NC}'? [Y/n] "
        read -r CONFIRM
        
        CONFIRM=${CONFIRM:-Y}
        
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            MY_USERNAME="$INPUT_USER"
            break
        else
            log "Cancelled. Please re-enter."
        fi
      done
    fi
fi

# ------------------------------------------------------------------------------
# 2. Create User & Sudo
# ------------------------------------------------------------------------------
section "Step 2/3" "Account & Privileges"

if [ "$SKIP_CREATION" = true ]; then
    log "Checking permissions for $MY_USERNAME..."
    if groups "$MY_USERNAME" | grep -q "\bwheel\b"; then
        success "User is already in 'wheel' group."
    else
        log "Adding to 'wheel' group..."
        exe usermod -aG wheel "$MY_USERNAME"
    fi
else
    log "Creating new user..."
    exe useradd -m -G wheel "$MY_USERNAME"
    
    log "Setting password for $MY_USERNAME..."
    # passwd 需要交互，直接运行
    if passwd "$MY_USERNAME"; then
        success "Password set."
    else
        error "Failed to set password."
        exit 1
    fi
fi

# Configure Sudoers
log "Configuring sudoers..."
SUDOERS_TMP=$(mktemp)
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$SUDOERS_TMP"
install_sudoers_file "$SUDOERS_TMP" /etc/sudoers.d/10-shorin-wheel
rm -f "$SUDOERS_TMP"
success "Sudo access converged and validated."

# ------------------------------------------------------------------------------
# 3. Generate User Directories
# ------------------------------------------------------------------------------
section "Step 3/3" "User Directories"

ensure_package xdg-user-dirs

log "Generating directories (Downloads, Documents...)..."

# 1. 获取目标用户的真实 Home 目录路径
REAL_HOME=$(getent passwd "$MY_USERNAME" | cut -d: -f6)

# 2. 强制指定 HOME 环境变量运行更新命令
# 注意：这里加了 --force 确保即使配置文件已存在也能强制刷新目录结构
if exe runuser -u "$MY_USERNAME" -- env LANG=en_US.UTF-8 HOME="$REAL_HOME" xdg-user-dirs-update --force; then
    success "Directories created in $REAL_HOME."
else
    error "Failed to generate directories."
    exit 1
fi

log "Module 03 completed."
