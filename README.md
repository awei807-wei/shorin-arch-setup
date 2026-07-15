# Shorin Arch Setup

Shorin Arch Setup 是面向 Arch Linux 的声明式系统配置工具。入口脚本只负责解析模式、执行预检、按依赖顺序调度模块、运行最终验收并汇总状态；具体变更由独立收敛模块完成。

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

先完成所选模块的只读审计，再只对存在差异的模块执行 `apply` 和 `verify`。必需模块在审计阶段发生检查错误时，不继续修复。

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
- `niri-packages.list`：Niri 附加包目标。

首次交互安装会把最终选择原子写入 profile。后续 `repair`、`audit` 和 `verify` 读取同一声明，避免把“用户没有选择”误判为“安装失败”。自定义 profile 路径必须在后续运行中保持一致。

### 旧版本 Applications 迁移

旧版 `99-apps.sh` 不保存用户当时的应用选择。升级后首次运行 `audit` 会把缺少 `applications.list` 报告为待迁移差异，但不会写入文件。首次运行 `repair` 时，applications 模块会根据当前系统中可确认的安装痕迹生成一次性清单：

- Repo 与 AUR 应用通过已安装软件包识别，并保留原始 `AUR:` 来源。
- Flatpak 通过系统级安装状态识别，并保留 `flatpak:` 来源。
- GitHub 应用通过二进制、源码 checkout 或用户单元识别。
- LazyVim 通过现有 Neovim 配置识别。

迁移是保守的，不会因为清单缺失就默认安装 `common-applist.txt` 中的全部应用。无法从当前状态证明曾被选择、且目前已经完全移除的应用不会自动加入清单。没有检测到任何旧目标时也会写入显式空清单，后续运行不再重复迁移。

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
| `desktop-niri` | 必需 | `storage base` | Niri 桌面、配置、portal、自动登录和用户单元 |
| `applications` | 可选 | `base` | Repo、AUR、Flatpak、GitHub 应用及应用配置 |
| `virtualization` | 可选 | `applications` | QEMU/KVM、libvirt、用户组和默认网络 |
| `nas-rime` | 可选 | `base` | NFS、Rime 同步和用户定时器 |
| `vcp` | 可选 | `applications` | VCPChat 桌面入口和 NAS 备份定时器 |
| `grub` | 可选 | `storage base` | GRUB、双启动、Btrfs 集成、主题及配置验收 |

不适用或缺少外部前置的可选模块会被明确标记为跳过。例如 VCPChat 尚未部署时，`vcp` 不会冒充成功，整体结果为 `PARTIAL`。

## 模块契约

每个 `scripts/modules/<name>.sh` 只暴露三个职责：

- `<name>_check`：只读检查。满足目标返回内部状态 `0`，存在差异返回 `10`，不适用或声明缺失返回 `20`。
- `<name>_apply`：调用 `ensure_*` 原语修复差异。仅允许在 `install` 或 `repair` 的可写阶段执行。
- `<name>_verify`：只读权威验收，记录未通过的具体目标。

模块通过 `module_main <name> "$@"` 接入统一 runner。`check` 和 `verify` 在独立只读子进程中运行；`apply` 在可写子进程中运行。包、文件、systemd 和结构化配置分别由 `scripts/lib/` 下的公共原语处理。

## 目录结构

```text
install.sh                       # 统一入口与调度器
scripts/
  lib/
    core.sh                      # 日志、错误传播、锁与公共上下文
    runner.sh                    # 模块执行、依赖结果与状态汇总
    state.sh                     # 只读状态谓词
    packages.sh                  # pacman、AUR 与系统级 Flatpak
    files.sh                     # 原子写入、模板和结构化文件原语
    systemd.sh                   # 系统及用户服务
    verify.sh                    # 通用验收函数
    compat.sh                    # 迁移期 apply 兼容接口
  modules/
    storage.sh
    base.sh
    desktop-niri.sh
    applications.sh
    virtualization.sh
    nas-rime.sh
    vcp.sh
    grub.sh
    <module>/                    # 较大模块按职责拆分的 apply 实现
  checks/
    preflight.sh                 # 环境、权限、锁和目标用户预检
    audit.sh                     # 只读审计编排
    niri-rollback.sh             # 独立人工回滚工具，不参与正常收敛
tests/                           # 严格模式、幂等、runner 与入口边界测试
```

`install.sh` 不直接调用 `pacman`、`systemctl` 或文件修改命令，也不包含应用或桌面的专属实现。

## 最终状态与退出码

每次运行结束都会重新验收所选模块，并输出以下之一：

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

当前 `GitHub:` 应用包括 `focus-shift` 和 `niri-clip`。源码位于目标用户的 `~/.local/src/`，可执行文件安装到 `~/.local/bin/`；`niri-clip` 同时部署并启用用户级 systemd 服务。

## 重跑与外部条件

软件包、服务、配置文件、用户单元、`fstab` 和 GRUB 都以当前状态为判断依据。安装器管理的系统配置经校验后原子替换；用户可编辑的 dotfiles、Firefox 配置、壁纸和模板默认只在首次创建，重跑不会无条件覆盖。

用户级 systemd 单元在存在用户 bus 时立即 reload/start；没有 bus 时只建立 wants 链接并记录待登录状态。NAS、VCPChat 或其他外部前置不可用时，对应可选模块会进入跳过或失败状态，并反映到最终 `PARTIAL` 结果中。
