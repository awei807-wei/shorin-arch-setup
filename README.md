
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
