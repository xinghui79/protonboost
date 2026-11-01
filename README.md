# WinRun

本地独立维护的 Windows 程序运行器：用 Proton/Wine 运行 exe，开箱即用；支持独立网络
（配合游戏加速器）、同前缀会话共享和图形管理器。基于开源项目重构更名，运行逻辑保持一致。

## 项目结构

```
bin/winrun                     主程序（bash）
bin/winrun-configure           「设置 Windows 程序运行环境」
bin/winrun-manager             图形管理器（GTK4）
share/applications/            桌面文件（右键打开方式 / 管理器入口）
icons/winrun.svg|.png          图标
install.sh                     安装 / 卸载脚本
```

## 安装（用户级，无需 sudo）

```
./install.sh                # 安装到 ~/.local
./install.sh install ~/.opt # 自定义 PREFIX
./install.sh uninstall      # 卸载
```

## 常用命令

```
winrun 程序.exe             # 运行 Windows 程序（首次自动初始化 ~/.proton 前置环境）
winrun steam                # 把 Linux 程序放进独立网络（先退出已开的 Steam）
winrun --status             # 前置环境 / 会话状态
winrun --doctor             # 环境诊断
winrun --netns on|off       # 开关独立网络
winrun-manager              # 图形管理器
```

Steam 游戏启动选项填 `winrun %command%`（游戏兼容性仍需选一个 Proton）。

## 独立网络（游戏加速）

`winrun --netns on` 后，前置环境里的程序运行在独立的网络命名空间。把 Windows 版
加速器（网易 UU「路由模式」/ 雷神「模式三」）和游戏装进同一前置环境即可加速；
Linux 程序也能放进同一网络（`winrun steam`）。依赖 `passt`，运行器需 WE-Proton
（内置 wintun）。

## 维护说明

本地独立维护。WE-Proton 运行器的在线安装/更新功能已移除，更新时手动解压到
`~/.local/share/Steam/compatibilitytools.d/WE-Proton Latest`；GE / DW 运行器
仍可用 `winrun --install ge|dw` 在线安装与更新。
