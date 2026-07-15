
## 使用方法

1. 安装一个archlinux系统

2. 登录之后从tty运行以下命令
    

    ```
    # 1. 安装 git
    sudo pacman -Syu git

    # 2. 克隆仓库
    git clone https://github.com/awei807-wei/shorin-arch-setup.git

    # 3. 进入目录并运行
    cd shorin-arch-setup
    sudo bash install.sh
    ```
    一条命令版

    ```
    sudo pacman -Syu git && git clone https://github.com/awei807-wei/shorin-arch-setup.git && cd shorin-arch-setup && sudo bash install.sh
    ```

## 更新计划

- 增加更多自定义桌面套件安装脚本

## 应用列表来源

`common-applist.txt` 支持以下来源前缀：

- 无前缀：Arch 官方仓库软件包
- `AUR:`：AUR 软件包
- `flatpak:`：Flathub 应用
- `GitHub:`：仓库内已登记的自建应用，克隆源码后以目标用户身份编译并安装

当前 `GitHub:` 应用包括 `focus-shift` 和 `niri-clip`。源码保留在
`~/.local/src/`，可执行文件安装到 `~/.local/bin/`；`niri-clip` 同时安装并启用
用户级 systemd 服务。

## 收敛与重跑

安装器按目标状态执行，可以在部分失败后直接重新运行。每个模块使用严格模式；软件包、服务、配置文件和用户单元都会先检查现状，只修复缺失或漂移的部分。

- 必需模块失败会立即停止，输出 `INSTALL_STATUS=FAILED`。
- 必需项通过，但可选模块失败、被跳过或等待用户登录启动时，输出 `INSTALL_STATUS=PARTIAL`。
- 必需项和可选项均通过最终复核时，输出 `INSTALL_STATUS=SUCCESS`。

结束状态来自重新验收，而不是来自安装命令曾经返回成功。门禁会复核必需包、服务、目标用户、Niri 配置、用户单元、`fstab` 和现有 GRUB 配置。

配置文件按所有权区分：安装器管理的系统配置采用临时文件校验后原子替换；dotfiles、Firefox 配置、壁纸和用户模板只在目标文件不存在时创建，后续重跑不会覆盖用户修改。Flatpak 应用统一安装到系统层。

VCP 备份和桌面入口依赖外部部署的 VCPChat。仓库没有发现可用的 VCPChat 时，这两个模块返回跳过状态，整体结果为 `PARTIAL`，不会冒充完整成功。
