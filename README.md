
## 使用方法

1. 安装一个archlinux系统

2. 登录之后从tty运行以下命令

    - 全球用户
        
        ```
        # 1. 安装 git
        sudo pacman -Sy git

        # 2. 克隆仓库
        git clone https://github.com/SHORiN-KiWATA/shorin-arch-setup.git

        # 3. 进入目录并运行
        cd shorin-arch-setup
        sudo bash install.sh
        ```
        - 一条命令版

            ```
            sudo pacman -S git && git clone https://github.com/SHORiN-KiWATA/shorin-arch-setup.git && cd shorin-arch-setup && sudo bash install.sh
            ```

    - 可选：使用中国大陆github镜像站
    
        如果连不上git，可以使用github镜像站，用环境变量激活

        ```
        # 1. 使用镜像站克隆仓库
        sudo pacman -Sy git
        git clone https://gitclone.com/github.com/SHORiN-KiWATA/shorin-arch-setup.git

        # 2. 进入目录
        cd shorin-arch-setup

        # 3. 开启 CN_MIRROR 环境变量运行
        sudo CN_MIRROR=1 bash install.sh
        ```
        - 一条命令版

            ```
            sudo pacman -Sy git && git clone https://gitclone.com/github.com/SHORiN-KiWATA/shorin-arch-setup.git && cd shorin-arch-setup && sudo CN_MIRROR=1 bash install.sh
            ```
3. 打开快捷键教程

    安装完成后会自动重启，由于配置了自动登录和niri自动启动（如果你没有显示管理器的话），会直接进桌面。

    按下super+shift+左斜杠打开按键教程。

## 脚本功能

- 设置全局默认编辑器，默认vim，如果已经安装了nvim或者nano则使用已经安装的

- 配置32位源

- 安装基础字体（wqy-zenhei noto-fonts noto-fonts-emoji）

- 添加archlinuxcn源

- 安装aur助手

- 如果是btrfs文件系统则自动配置snapper快照和快照启动项。

- 音视频固件和服务

- 蓝牙

- 性能模式切换

- 创建常用用户目录

- 安装和配置niri

- grub美化

- 中文输入法

- 截图编辑和屏幕分享

- 终端、waybar、壁纸切换、文档管理器、文本编辑器、锁屏、自动熄屏、浏览器等等必须功能

- 上述所有功能都可基于壁纸自动切换颜色

- 软件商城

- （可选）微信、qq、obs、markdown编辑器、任务管理器、视频播放器、图片查看器、种子下载器等等常用软件的安装

- 其他配置