# proton-wrapper

本地维护的分支：在上游开源项目基础上移除作者标识并更名，运行逻辑未改动。

## 功能

- 双击直接运行 Windows exe（Proton/Wine），首次运行自动初始化 `~/.proton` 前置环境
- 独立网络（`--netns on`）：前置环境的程序运行在独立的网络命名空间里，配合 Windows
  版加速器（网易 UU「路由模式」/ 雷神「模式三」）加速游戏；Linux 程序也能放进同一网络，
  例如 `proton-wrapper steam`
- 运行器管理：`--list-runner` `--install ge|dw|we` `--update` `--doctor`
- 图形管理器：`proton-wrapper-manager`（应用列表 / 进程 / 配置）

## 本地安装（用户级，无需 sudo）

```
install -Dm755 -t ~/.local/bin proton-wrapper proton-wrapper-configure proton-wrapper-manager
install -Dm644 -t ~/.local/share/applications *.desktop
install -Dm644 icons/proton-wrapper.png ~/.local/share/icons/hicolor/512x512/apps/proton-wrapper.png
update-desktop-database ~/.local/share/applications
```

## 常用命令

```
proton-wrapper --doctor          # 诊断
proton-wrapper --status          # 前置环境 / 会话状态
proton-wrapper --netns on|off    # 开关独立网络
proton-wrapper 程序.exe          # 运行 Windows 程序
proton-wrapper steam             # 把 Steam 放进独立网络（先退出已开的 Steam）
```

Steam 游戏启动选项填 `proton-wrapper %command%`（游戏兼容性仍需选一个 Proton）。

## 维护

本分支为本地独立维护版，与原作者无关。WE-Proton 运行器的在线安装/更新功能已移除，
更新时手动下载发布包并解压到 `~/.local/share/Steam/compatibilitytools.d/WE-Proton Latest`；
GE / DW 运行器仍可用 `proton-wrapper --install ge|dw` 在线安装与更新。
