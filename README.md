# WinRun

在 Linux 上跑 Windows 程序的小工具：Proton / Wine 打底，图形管理器管前缀、程序、进程，
还能把加速器和游戏放进同一个独立网络里。整套实现是 Rust + Qt 6（cxx-qt + QML），
没有脚本、没有 Python，装完就是一个二进制 + 一个图标。

*A small Windows program runner for Linux, built on Proton/Wine. GUI in Rust + Qt 6.*

## 功能

- **开箱即用**：把一个 exe 拖给 WinRun，它在默认前缀里建好环境就跑；第一次会自动初始化。
- **前缀与运行器**：自动发现 Steam、Lutris、本地目录里的 Proton / Wine，逐个程序选运行器。
  默认前缀是 `~/.local/share/winrun/proton`；老的 `~/.proton` 只要还在就继续沿用，
  不搬家。里面 `pfx/drive_c` 就是 Wine 的 C 盘（`windows`、`Program Files`、`users` 都在），
  由 Wine 首次初始化时创建，这一层不能改名——Proton 约定它就是 `WINEPREFIX`。
- **独立网络**：前缀默认关在单独的 network namespace 里（`pasta`），加速器和游戏共享同一个
  出口；关掉就回到宿主网络。
- **会话共享**：同一前缀里的程序共用一个 wineserver，显示方式与网络保持一致。
- **图形管理器**：应用 / Linux 程序 / 进程三个页面。点一行会在右侧展开检查器（路径、运行器、
  最近日志），也能重命名、导出到应用列表、强制结束进程。添加应用可以选 exe，也可以从安装
  目录里挑。
- **命令行入口**：`--run`（桌面入口）、`--configure`（运行设置）、`--exec`（Steam 启动选项）。

## 依赖

- Rust（构建用）、Qt 6：`qt6-base` `qt6-declarative` `qt6-svg`
- 运行时：`passt`（独立网络）、`util-linux`（nsenter）、`curl` + `tar`（下载运行器/运行时）
- 运行器：任意一份 Proton 或 Wine，详见下面「运行器」一节

## 安装

```bash
git clone <repo> && cd winrun
./install.sh                 # 构建 release 并安装到 ~/.local
./install.sh install ~/.opt  # 自定义 PREFIX
./install.sh uninstall       # 卸载
```

## 使用

```bash
winrun-manager                        # 图形管理器
winrun-manager --configure 程序.exe   # 只打开某个程序的运行设置
winrun-manager --run 程序.exe         # 按保存的配置直接启动
winrun-manager --exec <命令>          # 在前缀会话里跑一条命令（Steam 启动选项）
winrun-manager --list-runner          # 列出发现的 Proton / Wine
winrun-manager --dump-scan            # 打印前缀扫描结果，排查界面为什么空
```

- **右键 exe**：装好之后（`./install.sh`），文件管理器里右键任意 exe 有「运行Windows软件」
  和「设置Windows软件运行环境」两个动作。
- **装 Windows 软件**：下载来的安装包（setup.exe 之类）用上面那个右键动作就能直接跑起来，
  安装向导和 Windows 上一样。没装桌面入口时，用管理器里的「添加应用 → 直接运行 exe」，
  跑完不会往应用列表里塞条目；装好的程序会出现在 Windows 开始菜单里，刷新列表就能看到。
- **Steam 游戏**：启动选项填 `winrun-manager --exec %command%`，兼容性选一个 Proton。

界面里的键盘操作：

| 按键 | 作用 |
| --- | --- |
| `Ctrl+1` / `2` / `3` | 切换页面 |
| `↑` / `↓` | 选中上一行 / 下一行 |
| `Enter` | 运行选中的应用 |
| `Ctrl+F` | 搜索 |
| `Esc` | 清空搜索，再按一次收起检查器 |
| `Ctrl+R` | 刷新当前页 |
| `Ctrl+W` | 关闭窗口（有托盘就收进托盘） |
| `Ctrl+Q` | 退出程序 |

关窗口（点关闭按钮、按 `Ctrl+W`、或者用桌面的 `Super+Q`）都只是收进托盘，进程继续跑；
真正退出走托盘图标的右键菜单，或 `Ctrl+Q`。如果桌面环境没有托盘（比如没装 AppIndicator
的 GNOME），关窗口就直接退出，不会留下一个找不回来的后台进程。

数据都在本地：

| 位置 | 内容 |
| --- | --- |
| `~/.local/share/winrun/proton` | 默认前缀（老的 `~/.proton` 会自动沿用；可在运行设置里换成别的） |
| `~/.cache/winrun/associations` | 每个程序的运行设置 |
| `~/.cache/winrun/logs` | 运行日志与会话日志 |
| `~/.cache/winrun/icons` | 从 exe/ico 里抠出来的图标 |
| `$PREFIX/.winrun.conf` | 前缀自己的开关（`netns=`，侧栏前缀行右边那个小开关改的就是它） |

## 运行器

程序本身不带 Proton / Wine，启动 Windows 程序必须有一个。按这个顺序找，找到几个就列几个：

| 来源 | 位置 |
| --- | --- |
| 环境变量 | `WINRUN_RUNNER` / `PROTON_GE_PATH` 指向的 proton 或 wine |
| Steam 兼容性工具 | `~/.local/share/Steam/compatibilitytools.d/<名字>/proton`（GE、DW、WE 都在这） |
| Steam 官方 Proton | `steamapps/common/Proton *`，含其他 Steam 库 |
| 系统级 / Flatpak | `/usr/share/steam/...`、`~/.var/app/com.valvesoftware.Steam/...` |
| Lutris | `~/.local/share/lutris/runners/{proton,wine}` |
| 本地目录 | `~/.local/share/proton/runners/<名字>/proton` |
| 系统 wine | `PATH` 里的 `wine` |

不绑定任何特定版本，每个程序可以在运行设置里单独选。Proton 系的还需要 Steam Linux
Runtime（`SteamLinuxRuntime_sniper` / `soldier`），本机没有的话会自动下载。

一个都没有时，应用页会显示一条提示，点「下载 GE-Proton」会从 GitHub 取最新版装到
`~/.local/share/Steam/compatibilitytools.d/`；也可以自己装系统 wine 或 Steam 的 Proton，
重启管理器就会列出来。

## 独立网络

在侧栏把当前前缀右边那个小开关点亮，就给它开了独立网络（等价于在
`$PREFIX/.winrun.conf` 里写 `netns=1`），下次启动生效。

前缀开了独立网络后，`pasta` 建一个 network namespace，keeper 进程待在里面把网络撑住，
程序用 `nsenter` 进去；前缀里最后一个程序退出，keeper 跟着收摊。把 Windows 版加速器
（网易 UU 的「路由模式」、雷神的「模式三」）和游戏装进同一个前缀，加速器接管的就是
游戏所在的网络。

## 构建

```bash
cargo build            # 调试版 → target/debug/winrun-manager
cargo build --release  # 发布版
```

`target/` 是 Cargo 的构建缓存（不是项目结构）：`deps/` 放编译好的依赖，`build/<crate>-<hash>/out`
是各依赖构建脚本的产物，`incremental/` 是增量缓存。删掉无妨，下次构建会重新生成；
积得太大（调试版通常 1–2 GB）直接 `cargo clean` 即可。这个目录已在 `.gitignore` 里。

## 代码结构

```
src/main.rs              启动流程、命令行模式、单实例、托盘
src/app/                 QML 后端 + 任务线程（cxx-qt 要求桥接文件同目录）
  bridge.rs              Backend：属性 + invokable，QML 的唯一数据源
  jobs.rs                工作线程 + 结果通道（扫描/图标/启动/更新）
  ipc.rs                 单实例：unix 套接字唤起已运行的窗口
  shim.cpp .h            QApplication、托盘、图标转换、无头截图
src/engine/              启动引擎
  runners.rs             发现 Proton / Wine
  runtime.rs             Proton 需要的 Steam Linux Runtime
  session.rs             前缀会话与独立网络（pasta + keeper）
  launch.rs              拼环境变量与命令行、启动、写日志
  logs.rs                运行日志位置
  update.rs              GE / DW 运行器版本检查与安装
src/core/                扫描、.lnk 解析、图标、配置、进程、导出
qml/Main.qml             界面
desktop/                 桌面入口
icons/                   图标（PNG + SVG）
```

开发提示：只改 QML 也可以直接 `cargo build`——`build.rs` 把 QML 内容哈希塞进
`rustc-env`，内容一变就会重新编译并重链接。

无头验收（不开窗口也能看界面）：

```bash
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
WINRUN_PAGE=apps WINRUN_SHOT=/tmp/shot.png \
./target/debug/winrun-manager
```

## 许可

MIT。早期版本参考过 [SHORiN-KiWATA/proton-wrapper](https://github.com/SHORiN-KiWATA/proton-wrapper)
的思路（用同样的 Proton 调用方式跑 Windows 程序），现在这套实现是重写的 Rust 版本。
