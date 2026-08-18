# Shorin Arch Setup

Shorin Arch Setup 是面向 Arch Linux 的声明式系统配置工具。入口脚本只负责解析模式、执行预检、按依赖顺序调度模块、运行最终验收并汇总状态；具体变更由独立收敛模块完成。

安装器也支持 Fedora + niri。发行版默认从 `/etc/os-release` 检测，也可以显式指定
`--distro fedora`；Fedora 路径只使用 `dnf`、Flatpak、COPR、官方 RPM、官方
AppImage，以及固定校验和的上游源码构建，不会调用 AUR、`yay` 或 `paru`。
`common-applist.txt` 是跨发行版的逻辑清单，Fedora 映射在 `scripts/lib/platform.sh`
与 `scripts/lib/fedora.sh` 中维护，不会修改该文件。
Fedora 的 `awww` 源码输入固定为上游 `v0.12.1` 对应的 Codeberg immutable commit，下载后先校验 SHA-256，再以目标用户构建。
Fedora 的 Niri 会话必须通过已启用且正在运行的正式 display manager（Plasmalogin、SDDM
或 GDM）进入，并提供 `/usr/share/wayland-sessions/niri.desktop`，其中唯一的会话命令为
`Exec=niri-session`；Fedora 不创建 tty1 自动登录或 TTY 回退。Arch 保留 tty1 的托管
`~/.bash_profile` 会话入口。

执行模型如下：

```text
check 当前状态 -> 计算差异 -> apply 必要修改 -> verify 目标状态
```

安装和修复使用同一套模块实现，不依赖“某个步骤以前是否执行过”的进度文件。系统现状与 profile 中声明的目标共同决定是否需要修改。

## 快速开始

先安装 Git 并克隆仓库：

```bash
sudo pacman -Syu git
git clone https://github.com/awei807-wei/shorin-arch-setup.git
cd shorin-arch-setup
```

首次安装：

```bash
sudo bash install.sh install --user shorin
```

Fedora + niri：

```bash
sudo bash install.sh install --distro fedora --user shorin
```

Fedora 的第三方目标按以下方式收敛：Heroic、Upscaler、MangoJuice、VS Code、
Curtail、Mission Center 和 Steam 使用 Flathub；Steam 额外在其实际安装 scope
设置 `LANG=zh_CN.UTF-8` override，并验收 system/user Flatpak desktop export，
不依赖原生 `/usr/share/applications/steam.desktop`。`fd` 使用 Fedora 的 `fd-find` 包并验收
`/usr/bin/fd`；LACT 先幂等启用 `ilyaz/LACT` COPR，再安装 `lact` 并启用/启动
`lactd.service`；Yazi 在 Fedora 使用固定的 GitHub GNU ZIP release v26.8.15，按架构校验
SHA-256（x86_64: `cc67eb7991550c2f9407cda52d3f5af0937627aa6884e7de99a04fcf059807e0`；
aarch64: `f5a85771f06bb0e8c488136ae0aedaec8d341a7cee995549df391d7d852fe8d1`），仅提取预期
根目录的 `yazi` 和 `ya` 到目标用户 `~/.local/bin` 并验证版本，下载前通过 Fedora 包合同
收敛 `curl` 和 `unzip`。Lutris 在 Fedora
使用 `alsa-plugins-pulseaudio`、`gstreamer1-plugins-base`、`openal-soft` 与
`openal-soft.i686`，分别覆盖 Fedora 的 64 位和 32 位 Wine 游戏运行时。
Fedora Wine 使用 `wine`、`wine-mono`、`mingw32-wine-gecko` 和 `mingw64-wine-gecko`，不请求已不存在的 `wine-gecko`。
Clash Verge Rev、Linux QQ、LSFG-VK 和 Mark Shot 在 Fedora x86_64 上优先从固定版本的官方
HTTPS release 下载，并在安装前校验内置 SHA-256；Linux QQ 额外校验固定文件大小和 RPM
架构/名称，缓存使用原子替换。微信、Thorium 默认保持 pending：只有 installer/root
显式提供 `FEDORA_WECHAT_SHA256` 或 `FEDORA_THORIUM_SHA256` 时，才会从
`FEDORA_RPM_DIR`、`SHORIN_ARTIFACT_DIR`、目标用户 Downloads/`下载` 与 `/tmp` 搜索并严格校验 RPM；同目录
sidecar 不会被信任。无预期 SHA 会立即报告明确 pending 原因。`tsukimi-bin` 使用统一的
`walker874/tsukimi` COPR；Vicinae 固定 v0.26.0 官方 AppImage（SHA-256 校验），以目标
用户尝试交给 Gear Lever，CLI 不可用时保留项目托管 AppImage 与 desktop entry fallback；
`lsfg-vk-bin` 先收敛 `qt6-qtdeclarative` 和 `qt6-qtbase`。
`fd-rdd-git` 使用固定 commit `44b60573129c67f4471fa70f21b4a0b70bc1fec8` 的官方仓库源码，
要求目标用户环境有 `git`、`cargo`，并强制以目标用户运行 `scripts/install.sh`；也可通过
`FEDORA_FD_RDD_INSTALL_SCRIPT` 交接经确认的本地 installer。`typora-free` 没有声明来源，
会明确标记为 skipped。找不到外部 artifact 时安装器会输出来源、glob 和可执行的交接
路径，不会把“依赖已安装”冒充为主程序已安装；这类目标会记录为 `pending/skip`，写入
`~/Documents/安装待处理的软件.txt`，且不会阻断其他独立可选模块。

Fedora 的 Starship 和桌面精确字体不走 DNF 的近似包映射，而由 target-user provider
幂等安装到目标用户目录。provider 只接受下表固定上游资产，下载到临时目录后先做
SHA-256 校验和安全解压，只复制白名单文件；安装完成后使用 `fc-match`、`fc-query`
和 `fc-scan` 验收精确 family，Material Design Icons 还必须包含 U+F0493、U+F033E
和 U+F0425。已有可运行的 Starship 或已匹配的精确字体会被保留，不会覆盖用户自装
内容；下载、校验、解压或 fontconfig 失败会 fail-closed，并回滚本次新文件。
该 Fedora provider 当前仅支持 x86_64；其他架构会在下载前明确报告不支持并保持已有资产不变。

| 目标 | 固定来源/版本 | 许可证 | 安装位置 |
| --- | --- | --- | --- |
| Starship | [`starship-x86_64-unknown-linux-musl.tar.gz`](https://github.com/starship/starship/releases/download/v1.26.0/starship-x86_64-unknown-linux-musl.tar.gz)，v1.26.0，SHA-256 `b7c232b0e8249d8e55a40beb79c5c43a7d370f3f9408bd215deb0170daeaadf3` | ISC | `~/.local/bin/starship` |
| JetBrainsMono Nerd Font | [`JetBrainsMono.tar.xz`](https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.0/JetBrainsMono.tar.xz)，v3.5.0，SHA-256 `0227b220360a6f819b9ead92343e8112b34733054782561af50cfba1e8afab63`，family `JetBrainsMono Nerd Font` | OFL | `~/.local/share/fonts/shorin/` |
| Material Design Icons | [fixed commit font](https://raw.githubusercontent.com/Templarian/MaterialDesign-Webfont/57b567a448bd579892174cd47c47f9e187ea56c6/fonts/materialdesignicons-webfont.ttf)，v7.4.47，SHA-256 `61e8aba5a4e981fe22cf7c8e8bcdbea00476e75c62c37f01bf7ee33361d68428`，family `Material Design Icons` | Apache-2.0 | `~/.local/share/fonts/shorin/` |
| Fusion JetBrainsMapleMono | [`JetBrainsMapleMono-NF-XX-XX-XX.zip`](https://github.com/SpaceTimee/Fusion-JetBrainsMapleMono/releases/download/1.2304.79/JetBrainsMapleMono-NF-XX-XX-XX.zip)，v1.2304.79，SHA-256 `50b36f9efaa3fd76de6636db6e632e537f4c5c3bdff6c783d6937493f8b4ae6e`，family `JetBrains Maple Mono` | OFL/随包 LICENSE | `~/.local/share/fonts/shorin/` |

Fusion JetBrainsMapleMono 是第三方融合上游的社区归档，不是 JetBrains 官方发布；固定 ZIP
约 152.3 MB（约 145 MiB），只有活动 Kitty 配置明确包含 `font_family JetBrains Maple Mono` 时才会下载、
校验和安装。没有该配置引用时不会下载或验收 Maple，避免为未使用的字体引入体积和来源。

如果 Fedora 的系统包前置已经存在，只需修复这些目标用户资产时，不必重复执行完整
`repair` 或触碰系统包。目标用户可直接运行：

```bash
bash scripts/fedora-desktop-providers.sh --user shiyi
```

该入口只在 Fedora、x86_64 且目标用户环境已具备 `curl`、`sha256sum`、`tar`、`unzip`、
`xz`、`flock` 和 fontconfig 时继续；缺少前置、非 Fedora 或架构不支持都会 fail-closed
并输出 `MODULE_REASON`。普通用户只能指定自己，root 可通过 `--user` 指定桌面用户；两条
路径都复用相同的 source contract、精确字体验收和跨 provider 事务，不调用包管理器。

普通 `jetbrains-mono-fonts`、Source Han 和 Noto Emoji 仍由 Fedora 包管理；
`ttf-jetbrains-mono-nerd` 与 `ttf-jetbrains-maple-mono-nf-xx-xx` 不再伪映射为普通
JetBrains Mono。Arch 继续使用原有 pacman/AUR 目标。Kitty、QuickShell 和 Fish 的
配置只在对应命令/字体合同通过后报告收敛，Starship provider 不修改
`~/.config/starship.toml`。

Vicinae 的自动收敛路径是目标用户 `~/.local/bin/vicinae.AppImage` 加托管的
`~/.local/share/applications/vicinae.desktop`，并要求 Gear Lever Flatpak 已安装；
只有这三个状态同时满足时才报告已集成。也可以通过 `FEDORA_VICINAE_APPIMAGE`
指定本地官方 AppImage；`fd-rdd` 可通过 `FEDORA_FD_RDD_INSTALL_SCRIPT` 交接本地官方
`install.sh`，避免在网络受限时把失效网络 URL 或下载失败误报为成功。

`install` 和 `repair` 必须由 root 启动，因为它们需要调用发行版包管理器（Arch 为
`pacman`，Fedora 为 `dnf`）、写入
`/etc`、管理 systemd、fstab 和 GRUB。`--user` 必须指向实际桌面普通用户，
不能填写 `root`；Git checkout、AUR 构建和用户配置操作会降权到该用户，
只有系统状态写入保留 root 权限。`audit` 和 `verify` 是只读模式，不要求 root。

入口预检会验证当前 `TERM` 是否存在可用的 terminfo。若从尚未完整安装的
Kitty 等终端继承了无效终端类型，安装器会仅在本次进程中依次回退到
`xterm-256color`、`xterm` 或 `dumb`，并输出警告；不会修改用户或系统的终端配置。
这可避免 Snapper 等系统工具在桌面终端包安装前反向阻断 `repair`。

`install` 是默认模式，因此也可以执行：

```bash
sudo bash install.sh --user shorin
```

## 运行模式

```text
sudo bash install.sh [install|repair|audit|verify] [options] [module...]
```

### `install`

收敛全部或指定模块。每个模块先执行 `check`，仅在发现差异时执行 `apply`，随后执行 `verify`。未指定模块时按默认依赖顺序处理全部模块。

```bash
sudo bash install.sh install --user shorin
```

### `repair`

按依赖顺序对每个所选模块执行 `check`，只对存在差异的模块执行 `apply` 和 `verify`，再继续下游模块。这样上游修复后才出现的下游目标能在同一次运行中被重新判断并收敛；必需模块发生检查或应用错误时立即停止。

```bash
sudo bash install.sh repair --user shorin
```

### `audit`

只运行状态检查和最终验收，不写入系统。输出差异、跳过项和失败项，适合在修复前查看当前偏差。

```bash
bash install.sh audit --user shorin
```

### `verify`

跳过差异计算和修改，直接对所选模块执行权威验收。可用于安装后门禁或自动化检查。

```bash
bash install.sh verify --user shorin
bash install.sh verify --user shorin desktop-niri grub
```

`audit` 和 `verify` 会强制启用只读门禁。即使以 root 身份运行，库中的写操作也会被拒绝。

## 命令选项

### `--user NAME`

指定已存在的目标用户。用户 home 目录从系统账户数据库读取，不假定为 `/home/NAME`。

未指定时，入口依次尝试使用 `SUDO_USER`，或唯一一个 UID 位于普通用户范围内的账户。交互式 `install` 在无法识别现有用户时可以提示创建用户名；非交互运行必须提前创建目标账户并通过 `--user` 指定。`repair`、`audit` 和 `verify` 不负责创建用户。

### `--profile-dir DIR`

指定目标状态清单目录，默认值为 `/etc/shorin-arch-setup`。

```bash
sudo bash install.sh install \
  --user shorin \
  --profile-dir /etc/shorin-arch-setup
```

当前 profile 文件包括：

- `applications.list`：通用应用目标，保留 Repo、`AUR:`、`flatpak:`、`GitHub:` 来源信息。
- `niri-packages.list`：Niri 附加包目标。必需桌面目标由安装器维护，旧清单不能屏蔽新增的必需组件。

首次交互安装会把最终选择原子写入 profile，并生成 `applications.list.meta`（schema=2、source/provider revision、manifest hash 与 mode）。后续 `repair`、`audit` 和 `verify` 读取同一声明，避免把“用户没有选择”误判为“安装失败”。自定义 profile 路径必须在后续运行中保持一致。

`niri-packages.list` 只要存在且可读就是权威的可选包清单，包括零字节空清单。空清单表示不安装任何可选桌面包，但安装器维护的必需桌面目标仍会合并并验收。

### 旧版本 Applications 迁移

旧版 `99-apps.sh` 不保存用户当时的应用选择。升级后首次运行 `audit` 会把缺少 `applications.list` 报告为待迁移差异，但不会写入文件。首次运行 `repair` 时，applications 模块会根据当前系统中可确认的安装痕迹生成一次性清单；对于带有精确 `# Migrated from legacy installed state.` 标记但尚无 metadata 的旧 installer 清单，则先生成 `.bak` 备份，再按 `common-applist.txt` 原顺序仅追加缺失条目，绝不删除、重排或覆盖自定义条目：

- Repo 与 AUR 应用通过已安装软件包识别，并保留原始 `AUR:` 来源。
- Flatpak 同时检查系统 scope 与目标用户 user scope，并保留 `flatpak:` 来源。
- GitHub 应用通过二进制、源码 checkout 或用户单元识别。
- LazyVim 通过现有 Neovim 配置识别。

迁移是保守的，不会因为清单缺失就默认安装 `common-applist.txt` 中的全部应用。无法从当前状态证明曾被选择、且目前已经完全移除的应用不会自动加入清单。没有检测到任何旧目标时不会声明空清单。若用户之后修改 manifest，校验会报告 `drift/adopt-required`，repair 不会自动恢复被删除的条目；需要显式重新选择或 adopt。

对于非空但既没有 schema=2 metadata、也没有精确旧版迁移标记的旧 `applications.list`，`check`/`verify` 会报告 `application-manifest-legacy-unmarked`，`repair` 不会隐式改写。确认要一次性追加当前 `common-applist.txt` 缺失条目时，必须显式授权并保留原条目、注释和顺序：

```bash
sudo env SHORIN_ADOPT_LEGACY_APPLICATIONS=1 bash install.sh repair --distro fedora --user <user> base applications
```

生成位置默认是：

```text
/etc/shorin-arch-setup/applications.list
```

### 指定模块

选项后可以列出一个或多个模块：

```bash
sudo bash install.sh repair --user shorin storage base desktop-niri
bash install.sh audit --user shorin applications
bash install.sh verify --user shorin grub
```

`install` 和 `repair` 的模块列表必须包含所需依赖，并按依赖顺序排列。`audit` 和 `verify` 可独立检查指定模块。

## 模块与依赖

默认顺序和策略如下：

| 模块 | 策略 | 依赖 | 职责 |
| --- | --- | --- | --- |
| `storage` | 必需 | 无 | Btrfs、Snapper 与安装安全检查点 |
| `base` | 必需 | 无 | 软件源、基础包、用户、locale、音频、输入法、电源和 GPU |
| `desktop-niri` | 必需 | `storage base` | Niri 桌面、QuickShell、portal、正式显示管理器会话（Arch 保留 tty1）和用户配置 |
| `applications` | 可选 | `base` | Repo、AUR、Flatpak、GitHub 应用及应用配置 |
| `virtualization` | 可选 | `base` | QEMU/KVM、libvirt、用户组和默认网络 |
| `nas-rime` | 可选 | `base` | NFS、Rime 同步和用户定时器 |
| `vcp` | 可选 | `applications` | VCPChat 桌面入口和 NAS 备份定时器 |
| `grub` | 必需 | `storage base` | 双启动、Btrfs 集成、主题及配置验收 |

Fedora 的 virtualization 契约会把逻辑包映射为 `qemu-kvm`、`libvirt-daemon`、
`libvirt-daemon-kvm`、`libvirt-client` 和 `libvirt-daemon-config-network`，并显式验收
`libvirtd.service`、`virsh`、`libvirt/kvm/input` 用户组及
`/usr/share/libvirt/networks/default.xml`；不会安装已弃用的 `bridge-utils`。Arch
契约显式使用 `libvirt` 包。Fedora 的 `nas-rime` 目标额外安装提供
`/usr/bin/rime_dict_manager` 的 `librime-tools`，服务、safe-sync 脚本和只读检查共享
同一命令路径契约。Fedora 的 GRUB 使用独立 apply，Arch 内部的 `grub-btrfs` Btrfs
辅助脚本在 Fedora 上明确跳过。Fedora 的 base 电源能力使用 `ppd-service` provider
契约：已安装 `tuned-ppd` 时验收并启动 `tuned-ppd.service`，否则优先安装它；仅在
该包不可用时回退到 `power-profiles-daemon.service`。两个 provider 不会同时安装，
Arch 仍使用 `power-profiles-daemon` 原始包和服务。

不适用或缺少外部前置的可选模块会被明确标记为跳过。例如 VCPChat 尚未部署时，`vcp` 不会冒充成功，整体结果为 `PARTIAL`。

`desktop-niri` 的必需目标包含 QuickShell、`qt6-wayland`、`qt6-multimedia`、`bluez-utils`、主题生成、锁屏/空闲管理及桌面核心依赖。模块会把必需集合与 `niri-packages.list` 中的用户选择合并，并确保 Niri 配置中分别只有一个有效的 QuickShell 和 Fcitx5 启动命令；已有带参数的 `spawn-sh-at-startup` 命令会被保留。旧 profile 中的 Waybar 及其两个扩展会被视为已由 QuickShell 取代，不再触发安装或修复，也不会主动卸载机器上已有的软件。

桌面修复还会收敛以下持久状态：Niri 的 `PATH` 包含目标用户 `~/.local/bin`；`Mod+Alt+V` 调用 `niri-clip toggle`；`Mod+ALT+C` 调用 `focus-shift`；Fish 直接且幂等地加入 `~/.cargo/bin` 与 `~/.local/bin`，不依赖安装器生成的 `env.fish`；`~/.config/starship.toml` 从已验证、目标用户所有的 dotfiles checkout 部署，且 Matugen 不再生成或覆盖该文件，旧 `starship-colors.toml` 模板会被清理；配置仓库声明的默认壁纸存在；Niri、QuickShell 和 Waypaper 在 Arch 与 Fedora 上统一使用上游 `awww` 后端。Fedora 不把 `awww` 冒充成 DNF 包，而是从固定版本的官方 Codeberg 源码归档校验后以目标用户构建 `awww` 与 `awww-daemon`；缺少任一命令都会保持为 DRIFT/失败，不会误报收敛。旧配置中的 `swww` 命令只作为迁移输入改写为 `awww`。Niri 配置修改后必须通过 `niri validate`，失败时会恢复原 `config.kdl` 和 `binds.kdl`。

Arch 的 tty1 会话由 `~/.bash_profile` 中的托管块启动 `niri-session -l`。`-l` 声明当前已处于登录 Shell；不带它时 `niri-session` 会重新拉起登录 Shell 导入环境，若登录 Shell 是 bash 会再次读取 `.bash_profile` 形成启动循环。旧版 `niri-autostart.service` 及 wants 链接会被清理；存在用户 bus 时同步执行 `daemon-reload` 和失败状态清理，避免后台重复启动一个没有 TTY 的 Niri 会话。

Fedora 只接受正式图形登录：display-manager service 必须 enabled 且 active，Wayland 会话文件必须存在并且只声明 `Exec=niri-session`。修复不会创建或保留 Shorin 托管的 tty1 autologin，也不会把 `graphical-session.target` 当作会话入口；缺少正式 display manager 或会话文件时保持 DRIFT/失败，不静默回退到 TTY。不要从 tty2 裸执行 `niri`。

Fedora 的壁纸会话由 Niri 启动一次 `fedora-wallpaper-session.sh`，使用 awww 的 default/overview namespace、受锁保护的状态目录和有限重试；默认 Shorin state namespace 暂不可写时，仅本次会话安全回退到 `$XDG_RUNTIME_DIR/shorin-arch-setup` 并记录 warning，正式 `apply/check` 仍会修复并审计 home state ownership。优先复用 Waypaper 的随机选择并显式应用已选图片，Waypaper 不可用时从其配置读取可用图片。awww 未就绪、图片不可用或命令合同不满足都会记录到目标用户状态日志并保持失败，不会把短暂启动成功误报为壁纸已收敛。

Fedora + Niri 会通过目标用户的 `~/.config/autostart/org.kde.xwaylandvideobridge.desktop` 写入 `Hidden=true`，禁用 X11 兼容桥的默认自动启动；这是仅针对 X11 兼容层的设置，不影响 Wayland 原生 portal。Arch 路径不写入或管理该文件。

Fedora 的 Niri 配置收敛保留现有用户文件，不会用上游树盲目覆盖 `config.kdl` 或 `binds.kdl`。事务内会备份并迁移旧的 `~/.config/quickshell/scripts/lockscreen-wait.sh` 到 `lockscreen.sh`，并替换 polkit-gnome 路径；来源 checkout 必须提供普通、可执行的 `dotfiles/.config/quickshell/scripts/lockscreen.sh`，目标文件必须归目标用户所有。缺少来源的 `fd-rdd`、`vicinae`、`waypaper`、`niriswitcher`、`niriswitcherctl`、`waybar` 和 `hyprpicker` 只改为 `command -v` shell guard，后续安装对应程序后即可自动启用，当前不会伪造命令或宣称功能已安装。迁移后的配置必须通过 `niri validate`，失败会恢复原文件。

## 模块契约

每个 `scripts/modules/<name>.sh` 只暴露三个职责：

- `<name>_check`：只读检查。满足目标返回内部状态 `0`，存在差异返回 `10`，不适用或声明缺失返回 `20`。
- `<name>_apply`：调用 `ensure_*` 原语修复差异。仅允许在 `install` 或 `repair` 的可写阶段执行。
- `<name>_verify`：只读权威验收，记录未通过的具体目标。

模块通过 `module_main <name> "$@"` 接入统一 runner。`check` 和 `verify` 在独立只读子进程中运行；`apply` 在可写子进程中运行。包、文件、systemd 和结构化配置分别由 `scripts/lib/` 下的公共原语处理。

pacman 安装若明确返回未知或缺失密钥的 PGP 信任错误，包管理原语会在整次运行中至多执行一次官方 `archlinux-keyring` 更新和 `pacman-key --populate archlinux`，然后重试原包。单纯的缓存损坏、网络错误、包不存在和依赖冲突不会触发该恢复；安装器不会关闭签名验证、使用 `TrustAll` 或在单包修复中隐式执行整机升级。

AUR 目标先检查 Arch 官方 `core`、`extra` 和 `multilib`；同名官方包存在时
使用仓库限定的 pacman 目标收敛到官方版本。真正的 AUR 目标强制使用
`yay --aur`，保留 PKGBUILD/diff 交互审阅，并通过目标用户正常的 sudo 策略完成
安装，不创建临时 NOPASSWD 规则。因此 AUR 安装需要可用 TTY 和目标用户的 sudo
凭据。ArchLinuxCN 目前仅用于引导 `yay` 等明确的第三方二进制目标，不会把应用
清单中的第三方包标记为官方包。

带来源前缀的包会在 `/var/lib/shorin-arch-setup/package-sources/` 记录来源和已安装
版本。旧安装缺少该凭据时会执行一次仓库限定的官方重装或 AUR rebuild，完成
ArchLinuxCN/AUR 到目标来源的迁移；凭据与当前版本不一致时同样报告 drift。

## 目录结构

```text
install.sh                       # 统一入口与调度器
scripts/
  fedora-desktop-providers.sh      # 无需完整 repair 的 Fedora 目标用户 provider 入口
  lib/
    core.sh                      # 日志、错误传播、锁与公共上下文
    runner.sh                    # 模块执行、依赖结果与状态汇总
    state.sh                     # 只读状态谓词
    packages.sh                  # pacman、AUR 与系统级 Flatpak
    platform.sh                  # Arch/Fedora 检测与 Fedora 包名翻译
    fedora.sh                    # Fedora Flatpak、COPR、RPM/AppImage/provider 目标
    fedora-flatpak.sh            # Fedora system/user scope Flatpak 合同
    fedora-providers.sh          # Fedora provider 合同与目标路由
    fedora-official-artifacts.sh # 固定版本官方 AppImage/RPM 下载、缓存与校验
    fedora-fd-rdd.sh             # 固定 commit 的 fd-rdd 目标用户源码安装
    fedora-starship-provider.sh  # Starship target-user provider
    fedora-font-provider.sh      # 精确字体 family/glyph 合同
    fedora-font-installer.sh     # 固定字体资产下载、解压与回滚
    fedora-provider-transaction.sh # Starship 与字体跨 provider 事务
    files.sh                     # 原子写入、模板和结构化文件原语
    git.sh                       # 降权、固定版本的 Git checkout
    snapshots.sh                 # 成对快照查找与回滚标识
    systemd.sh                   # 系统及用户服务
    verify.sh                    # 通用验收函数
    compat.sh                    # 迁移期 apply 兼容接口
  modules/
    storage.sh
    base.sh
    desktop-niri.sh
    desktop-niri/fedora-provider-apply.sh # Fedora provider 系统/目标用户 apply 入口
    desktop-niri/awww.sh        # Fedora awww 源码构建与命令合同
    applications.sh
    applications/manifest.sh     # 应用清单迁移、元数据与原子回滚
    applications/targets.sh      # 应用目标合同与执行路由
    virtualization.sh
    nas-rime.sh
    vcp.sh
    grub.sh
    <module>/                    # 较大模块按职责拆分的 apply 实现
  checks/
    preflight.sh                 # 环境、权限、锁和目标用户预检
    audit.sh                     # 只读审计编排
    niri-rollback.sh             # 独立人工回滚工具，不参与正常收敛
tests/                           # 原语、runner、入口及真实模块合同测试
```

`install.sh` 不直接调用 `pacman`、`systemctl` 或文件修改命令，也不包含应用或桌面的专属实现。

## 最终状态与退出码

每次运行结束都会重新验收所选模块，并额外执行 `findmnt --verify` 全局门禁，再输出以下之一。最终验收会叠加当前状态，但不会清除先前 `check` 或 `apply` 已记录的失败与跳过证据：

| 输出 | 退出码 | 含义 |
| --- | ---: | --- |
| `INSTALL_STATUS=SUCCESS` | `0` | 所有必需项和可选项均通过 |
| `INSTALL_STATUS=PARTIAL` | `2` | 必需项通过，但可选项失败或跳过 |
| `INSTALL_STATUS=FAILED` | `1` | 任一必需项检查、应用或验收失败 |

存在问题时还会输出对应明细：

- `REQUIRED_FAILURES=...`
- `OPTIONAL_FAILURES=...`
- `OPTIONAL_SKIPS=...`

自动化调用方应同时检查进程退出码和 `INSTALL_STATUS`，不要仅依赖某条安装命令曾经成功。

## 应用列表来源

`common-applist.txt` 和生成的 `applications.list` 支持以下来源：

- 无前缀：Arch 官方仓库软件包。
- `AUR:`：AUR 软件包。
- `flatpak:`：系统级 Flathub 应用。
- `GitHub:`：仓库内已登记的源码应用。

在 Fedora 目标上，无前缀条目会经过显式 Fedora 包名白名单翻译；`AUR:` 条目不会
进入 `dnf` 的原始 Arch 包名路径，而是交给 Fedora 映射器处理。`desktop-niri` 中
没有可靠 Fedora 来源且不属于会话核心的 `bluetui`、`hyprpicker`、`nwg-look`、
`satty` 和 `swayosd` 会记录明确的 optional/skip 原因，既不会交给
`dnf`，也不会进入 required 验收；`swayosd` 的缺失启动项会同步清理。其余未登记
可靠来源的目标会给出人工交接提示，不会静默宣称已安装。

当前 `GitHub:` 应用包括 `focus-shift` 和 `niri-clip`。源码位于目标用户的 `~/.local/src/`，可执行文件安装到 `~/.local/bin/`；`niri-clip` 同时部署并启用用户级 systemd 服务。

源码应用、桌面 dotfiles 和新部署的 LazyVim starter 各自遵循声明的来源合同。桌面
dotfiles 每次从 GitHub `main` 获取最新提交；GitHub 不可用时使用 Gitee `main` 最新
提交。GitHub 与 Gitee 是独立的最新来源，不保证两棵树完全一致；任一来源成功且通过
桌面源资产契约即可使用。新 checkout 必须由目标用户创建，已有 checkout 必须匹配来源、保持干净，并在
更新后处于本地 `main` 且与 `origin/main` 一致；脏、符号链接、错误所有者或未知来源
的 checkout 会被拒绝。Starship 保留常规的非空、普通文件和所有权检查，不再绑定某个
旧内容哈希。其余源码应用和 LazyVim 仍按各自的来源与 provenance 合同验收；`strap.sh`
不会直接执行刚拉取的分支头：首次运行只打印 commit，审核后必须通过
`SHORIN_EXPECTED_COMMIT=<commit>` 再次运行。

安装器新建的 LazyVim 配置会记录 starter commit 并参与后续验收；没有该标记的
既有配置视为用户自管，不会为了补写 provenance 而覆盖。

声明 `AUR:vicinae-bin` 或兼容的旧 `AUR:vicinae` 目标时，applications 模块会管理 `~/.config/vicinae/settings.json` 的初始化与旧空壳迁移。缺失或仅含默认 schema 的配置会从可信模板原子部署，路径按目标用户 home 渲染，权限为 `600`；已存在的真实用户配置和符号链接不会覆盖。扩展、数据库、缓存、访问历史等运行数据不属于安装器管理范围。

## 重跑与外部条件

软件包、服务、配置文件、用户单元、`fstab` 和 GRUB 都以当前状态为判断依据。Storage 会按挂载目标清理旧版本遗留的重复根分区、Home、EFI、包缓存和日志条目，同时保留同一 Btrfs 文件系统上的不同子卷；写回前必须通过 `findmnt --verify`。安装器管理的系统配置经校验后原子替换；用户可编辑的 dotfiles、Firefox 用户配置、Vicinae 用户配置、壁纸、模板和 XDG 目录配置默认只在首次创建或明确识别为旧空壳时部署，重跑不会无条件覆盖。Starship 配置属于桌面模块明确管理的例外：每次修复都会从当前已验证的 dotfiles checkout 部署，并移除 Matugen 的 Starship 输出表；默认壁纸缺失时也会触发修复，其他已有用户文件仍会保留。

每次可写安装都会创建新的 `Before Shorin Setup` 快照；真正进入 desktop-niri
前再创建新的桌面检查点，不复用旧运行的同名快照。回滚脚本会在修改前解析并
校验 root/home 两侧的最新检查点，交互确认后才执行；自动化调用必须显式传入
`--yes`。回滚不会清理 pacman、yay 或 paru 缓存。只有 `/home` 自身是 Btrfs
子卷时才创建独立 Home Snapper 配置。

用户级 systemd 单元在存在用户 bus 时立即 reload/start；没有 bus 时只建立 wants 链接并记录待登录状态。NAS、VCPChat 或其他外部前置不可用时，对应可选模块会进入跳过或失败状态，并反映到最终 `PARTIAL` 结果中。
