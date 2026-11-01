# WinRun

本地独立维护的 Windows 程序运行器：用 Proton/Wine 运行 exe，开箱即用；支持独立网络
（配合游戏加速器）、同前缀会话共享和一个图形管理器。基于开源项目重构后本地维护，
现在整套实现（界面 + 启动引擎）都是 Rust + Qt6，没有脚本。

## 项目结构

```
src/main.rs              启动流程、命令行模式、单实例、托盘
src/app/                 与 Qt 无关的界面配套
  jobs.rs                工作线程 + 结果通道（扫描/图标/启动/更新都在这里跑）
  ipc.rs                 单实例：unix 套接字唤起已运行的窗口

src/engine/              启动引擎（原来 CLI 的职责）
  runners.rs             从 Steam / lutris / 本地目录发现 Proton 与 Wine
  runtime.rs             Proton 需要的 Steam Linux Runtime（缺了会下一份）
  session.rs             同前缀会话与独立网络命名空间（pasta + keeper）
  launch.rs              拼环境变量与命令行、启动程序、写运行日志
  logs.rs                运行日志位置与本次运行的日志文件
  update.rs              GE / DW 运行器的版本检查与安装

src/core/                纯数据逻辑
  scan.rs prefix.rs lnk.rs icons.rs conf.rs procs.rs export.rs steam.rs paths.rs loc.rs

src/qt/                  Qt 层（cxx-qt 要求同一模块的文件放在同一个目录）
  bridge.rs              Backend：属性 + invokable，QML 的唯一数据源
  shim_bridge.rs         Rust 侧没有 Qt 绑定的部分（QApplication、托盘、图标、截图）
  shim.cpp .h

qml/Main.qml             界面：侧栏 + 四个页面 + 状态栏 + 各类弹层
build.rs Cargo.toml      cxx-qt 把 Rust 与 QML 一起编译进二进制
share/applications/      桌面入口（管理器 / 运行 / 运行设置）
icons/hicolor/           图标
install.sh               安装 / 卸载
```

## 构建

需要 cargo 与 Qt 6（`qt6-base` `qt6-declarative` `qt6-svg`）；独立网络还需要 `passt`
与 `util-linux`（nsenter）。

```
cargo build                     # 调试构建 → target/debug/winrun-manager
cargo build --release           # 发布构建
```

## 安装（用户级，无需 sudo）

```
./install.sh                    # 安装到 ~/.local
./install.sh install ~/.opt     # 自定义 PREFIX
./install.sh uninstall          # 卸载
```

## 用法

```
winrun-manager                          # 图形管理器
winrun-manager --configure 程序.exe     # 只打开某个程序的运行设置
winrun-manager --run 程序.exe           # 按保存的配置直接启动（桌面入口用）
winrun-manager --exec <命令>            # 在前缀会话里跑一条命令（Steam 启动选项用）
winrun-manager --list-runner            # 列出发现的 Proton / Wine
winrun-manager --dump-scan ~/.proton    # 打印前缀扫描结果，排查界面为什么空
```

Steam 游戏的启动选项填 `winrun-manager --exec %command%`（游戏兼容性仍然要选一个 Proton）。

## 图形管理器

四个页面：应用（运行 / 改设置 / 看日志 / 关闭 / 重命名 / 导出到应用列表）、
Linux 程序（放进同一前缀与网络）、进程（强制结束）、目录（从安装目录挑 exe 生成配置）。
关窗口进托盘，退出只走托盘菜单。前缀第一次启动会自动初始化，默认打开独立网络。

## 独立网络（游戏加速）

前缀的独立网络由 `pasta` 建 network namespace，keeper 进程待在里面把网络撑住，程序用
`nsenter` 进去；前缀里最后一个程序退出后 keeper 收摊。把 Windows 版加速器（网易 UU
「路由模式」/ 雷神「模式三」）和游戏装进同一个前置环境即可加速；Linux 程序也能放进同一
网络。开关在 `$PREFIX/.winrun.conf` 的 `netns=`。

## 开发提示

- 只改 QML 也可以直接 `cargo build`：`build.rs` 把 QML 内容哈希塞进 `rustc-env`，
  内容一变 cargo 就会重新编译并重链接。
- 无头验收（不需要开窗口）：

```
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
WINRUN_PAGE=apps WINRUN_SHOT=/tmp/shot.png \
./target/debug/winrun-manager
```

  `WINRUN_PAGE` 取 `apps|linux|procs|dirs`，`WINRUN_SHOT_DELAY` 是截图前等待的毫秒数。
- QML 报错会以 `QT:` 前缀打到 stderr。
- 运行日志在 `~/.cache/winrun/logs/<app-id>/latest.log`，会话日志在
  `~/.cache/winrun/logs/session-<id>.log`。

## 维护说明

本地独立维护。WE-Proton 是默认运行器，没有在线安装/更新：更新时手动解压到
`~/.local/share/Steam/compatibilitytools.d/WE-Proton Latest`。GE / DW 运行器如果已经装
在本地或 Steam 目录里，管理器会在有新版时提示，并且可以就地更新。
