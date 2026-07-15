#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "ERROR: %s:%s: %s\n" \
  "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Application-specific convergence. Sourced by 99-apps.sh after packages.

# ------------------------------------------------------------------------------
# 4. Environment & Additional Configs (Virt/Wine/Steam/LazyVim)
# ------------------------------------------------------------------------------
section "Post-Install" "System & App Tweaks"

# --- [NEW] Virtualization Configuration (Virt-Manager) ---
if pacman -Qi virt-manager &>/dev/null; then
  info_kv "Config" "Virt-Manager detected"

  # 1. 安装完整依赖
  # iptables-nft 和 dnsmasq 是默认 NAT 网络必须的
  log "Installing QEMU/KVM dependencies..."
  ensure_packages qemu-full virt-manager swtpm dnsmasq

  # 2. 添加用户组 (需要重新登录生效)
  log "Adding $TARGET_USER to libvirt group..."
  usermod -a -G libvirt "$TARGET_USER"
  # 同时添加 kvm 和 input 组以防万一
  usermod -a -G kvm,input "$TARGET_USER"

  # 3. 开启服务
  log "Enabling libvirtd service..."
  ensure_service_started libvirtd.service

  # 4. [修复] 强制设置 virt-manager 默认连接为 QEMU/KVM
  # 解决第一次打开显示 LXC 或无法连接的问题
  log "Setting default URI to qemu:///system..."

  # 编译 glib schemas (防止 gsettings 报错)
  glib-compile-schemas /usr/share/glib-2.0/schemas/

  # 强制写入 Dconf 配置
  # uris: 连接列表
  # autoconnect: 自动连接的列表
  as_user gsettings set org.virt-manager.virt-manager.connections uris "['qemu:///system']"
  as_user gsettings set org.virt-manager.virt-manager.connections autoconnect "['qemu:///system']"

  # 5. 配置网络 (Default NAT)
  log "Starting default network..."
  sleep 3
  virsh net-start default >/dev/null 2>&1 || warn "Default network might be already active."
  virsh net-autostart default >/dev/null 2>&1 || true

  # 修复虚拟机安装后的dns问题
    if systemd-detect-virt -q; then
        log "Virtual Machine environment detected."

        # 1. 检测是否在中国
        if [[ $(readlink -f /etc/localtime) == *"Shanghai"* ]]; then
            # 中国：只加国内 DNS
            log "Region: China. Prepending DNS..."
            ensure_line /etc/resolv.conf "nameserver 223.5.5.5"
            ensure_line /etc/resolv.conf "nameserver 119.29.29.29"
        else
            # 非中国：加 Google DNS
            log "Region: Global. Appending Google DNS..."
            ensure_line /etc/resolv.conf "nameserver 8.8.8.8"
            ensure_line /etc/resolv.conf "nameserver 1.1.1.1"
        fi
    fi
  success "Virtualization (KVM) configured."
fi

# --- [NEW] Wine Configuration & Fonts ---
if command -v wine &>/dev/null; then
  info_kv "Config" "Wine detected"

  # 1. 安装 Gecko 和 Mono
  log "Ensuring Wine Gecko/Mono are installed..."
  ensure_packages wine wine-gecko wine-mono

  # 2. 初始化 Wine (使用 wineboot -u 在后台运行，不弹窗)
  WINE_PREFIX="$HOME_DIR/.wine"
  if [ ! -d "$WINE_PREFIX" ]; then
    log "Initializing wine prefix (This may take a minute)..."
    # WINEDLLOVERRIDES prohibits popups
    as_user env WINEDLLOVERRIDES="mscoree,mshtml=" wineboot -u
    # Wait for completion
    as_user wineserver -w
  else
    log "Wine prefix already exists."
  fi

  # 3. 复制字体
  FONT_SRC="$PARENT_DIR/resources/windows-sim-fonts"
  FONT_DEST="$WINE_PREFIX/drive_c/windows/Fonts"

  if [ -d "$FONT_SRC" ]; then
    log "Copying Windows fonts from resources..."

    # 1. 确保目标目录存在 (以用户身份创建)
    if [ ! -d "$FONT_DEST" ]; then
        as_user mkdir -p "$FONT_DEST"
    fi

    while IFS= read -r -d '' font; do
        install_if_changed "$font" "$FONT_DEST/$(basename "$font")" 644
        chown "$TARGET_USER:$TARGET_USER" "$FONT_DEST/$(basename "$font")"
    done < <(find "$FONT_SRC" -maxdepth 1 -type f -print0)
    success "Fonts converged successfully."

    # 3. 强制刷新 Wine 字体缓存 (非常重要！)
    # 字体文件放进去了，但 Wine 不一定会立刻重修构建 fntdata.dat
    # 杀死 wineserver 会强制 Wine 下次启动时重新扫描系统和本地配置
    log "Refreshing Wine font cache..."
    if command -v wineserver &> /dev/null; then
        # 必须以目标用户身份执行 wineserver -k
        as_user env WINEPREFIX="$WINE_PREFIX" wineserver -k
    fi

    success "Wine fonts installed and cache refresh triggered."
  else
    warn "Resources font directory not found at: $FONT_SRC"
  fi
fi

if command -v lutris &> /dev/null; then
    log "Lutris detected. Installing 32-bit gaming dependencies..."
    ensure_packages alsa-plugins giflib glfw gst-plugins-base-libs \
        lib32-alsa-plugins lib32-giflib lib32-gst-plugins-base-libs \
        lib32-gtk3 lib32-libjpeg-turbo lib32-libva lib32-mpg123 \
        lib32-openal libjpeg-turbo libva libxslt mpg123 openal ttf-liberation
fi
# --- Steam Locale Fix ---
STEAM_desktop_modified=false
NATIVE_DESKTOP="/usr/share/applications/steam.desktop"
if [ -f "$NATIVE_DESKTOP" ]; then
    log "Checking Native Steam..."
    if ! grep -q "env LANG=zh_CN.UTF-8" "$NATIVE_DESKTOP"; then
        exe sed -i 's|^Exec=/usr/bin/steam|Exec=env LANG=zh_CN.UTF-8 /usr/bin/steam|' "$NATIVE_DESKTOP"
        exe sed -i 's|^Exec=steam|Exec=env LANG=zh_CN.UTF-8 steam|' "$NATIVE_DESKTOP"
        success "Patched Native Steam .desktop."
        STEAM_desktop_modified=true
    else
        log "Native Steam already patched."
    fi
fi

if flatpak list --system | grep -q "com.valvesoftware.Steam"; then
    log "Checking Flatpak Steam..."
    exe flatpak override --system --env=LANG=zh_CN.UTF-8 com.valvesoftware.Steam
    success "Applied Flatpak Steam override."
    STEAM_desktop_modified=true
fi

# --- [MOVED] LazyVim Configuration ---
if [ "$INSTALL_LAZYVIM" = true ]; then
  section "Config" "Applying LazyVim Overrides"
  NVIM_CFG="$HOME_DIR/.config/nvim"

  if [ -d "$NVIM_CFG" ]; then
    BACKUP_PATH="$HOME_DIR/.config/nvim.old.apps.$(date +%s)"
    warn "Collision detected. Moving existing nvim config to $BACKUP_PATH"
    mv "$NVIM_CFG" "$BACKUP_PATH"
  fi

  log "Cloning LazyVim starter..."
  if as_user git clone https://github.com/LazyVim/starter "$NVIM_CFG"; then
    rm -rf "$NVIM_CFG/.git"
    success "LazyVim installed (Override)."
  else
    error "Failed to clone LazyVim."
  fi
fi

# --- hide desktop ---
hide_desktop_file() {

  local file="$1"

  if [[ -f "$file" ]] && ! grep -q "^NoDisplay=true$" "$file"; then

    ensure_line "$file" "NoDisplay=true"

  fi

}
section "Config" "Hiding useless .desktop files"
log "Hiding useless .desktop files"
hide_desktop_file "/usr/share/applications/avahi-discover.desktop"
hide_desktop_file "/usr/share/applications/qv4l2.desktop"
hide_desktop_file "/usr/share/applications/qvidcap.desktop"
hide_desktop_file "/usr/share/applications/bssh.desktop"
hide_desktop_file "/usr/share/applications/org.fcitx.Fcitx5.desktop"
hide_desktop_file "/usr/share/applications/org.fcitx.fcitx5-migrator.desktop"
hide_desktop_file "/usr/share/applications/xgps.desktop"
hide_desktop_file "/usr/share/applications/xgpsspeed.desktop"
hide_desktop_file "/usr/share/applications/gvim.desktop"
hide_desktop_file "/usr/share/applications/kbd-layout-viewer5.desktop"
hide_desktop_file "/usr/share/applications/bvnc.desktop"
hide_desktop_file "/usr/share/applications/yazi.desktop"
hide_desktop_file "/usr/share/applications/btop.desktop"
hide_desktop_file "/usr/share/applications/vim.desktop"
hide_desktop_file "/usr/share/applications/nvim.desktop"
hide_desktop_file "/usr/share/applications/nvtop.desktop"
hide_desktop_file "/usr/share/applications/mpv.desktop"
hide_desktop_file "/usr/share/applications/org.gnome.Settings.desktop"

# --- Firefox defaults (first install only; preserve later user edits) ---
section "Config" "Firefox UI Customization"

install -d -o "$TARGET_USER" -g "$TARGET_USER" "$HOME_DIR/.mozilla"
deploy_user_tree_once "$PARENT_DIR/resources/firefox" \
    "$HOME_DIR/.mozilla" "$TARGET_USER"
