#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ==============================================================================
# Bootstrap Script for Shorin Arch Setup
# ==============================================================================

# --- [配置区域] ---
# 优先使用环境变量传入的分支名，如果没传，则默认使用 'main'
TARGET_BRANCH="${BRANCH:-main}"
REPO_URL="https://github.com/awei807-wei/shorin-arch-setup.git"
DIR_NAME="shorin-arch-setup"

echo -e "\033[0;34m>>> Preparing to install from branch: $TARGET_BRANCH\033[0m"

# 1. 检查并安装 git
if ! command -v git &> /dev/null; then
    echo "Git not found. Installing..."
    sudo pacman -S --noconfirm --needed git
    pacman -Q git >/dev/null 2>&1
fi

# 2. 收敛现有仓库；不删除用户已有目录或本地提交
if [ -d "$DIR_NAME" ]; then
    if [ ! -d "$DIR_NAME/.git" ]; then
        echo "Error: $DIR_NAME exists but is not a Git repository." >&2
        exit 1
    fi
    CURRENT_REMOTE=$(git -C "$DIR_NAME" remote get-url origin)
    if [ "${CURRENT_REMOTE%.git}" != "${REPO_URL%.git}" ]; then
        echo "Error: refusing to update unexpected origin: $CURRENT_REMOTE" >&2
        exit 1
    fi
    git -C "$DIR_NAME" fetch origin "$TARGET_BRANCH"
    git -C "$DIR_NAME" switch "$TARGET_BRANCH"
    git -C "$DIR_NAME" merge --ff-only "origin/$TARGET_BRANCH"
else
    STAGED_DIR=$(mktemp -d "./.${DIR_NAME}.XXXXXX")
    rmdir "$STAGED_DIR"
    git clone --branch "$TARGET_BRANCH" --single-branch "$REPO_URL" "$STAGED_DIR"
    mv "$STAGED_DIR" "$DIR_NAME"
fi

# 3. 运行安装
if [ -d "$DIR_NAME" ]; then
    cd "$DIR_NAME"
    echo "Starting installer..."
    sudo bash install.sh
else
    echo "Error: Directory not found."
    exit 1
fi
