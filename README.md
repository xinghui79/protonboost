# ProtonBoost

在 Linux 上跑 Windows 程序的小工具：Proton / Wine 打底，图形管理器管前缀、程序、进程，
还能把加速器和游戏放进同一个独立网络里。整套实现是 Rust + Qt 6（cxx-qt + QML），
没有脚本、没有 Python，装完就是一个二进制 + 一个图标。

*A small Windows program runner for Linux, built on Proton/Wine. GUI in Rust + Qt 6.*

## 功能

- **开箱即用**：把一个 exe 拖给 ProtonBoost，它在默认前缀里建好环境就跑；第一次会自动初始化。
- **前缀与运行器**：自动发现 Steam、Lutris、本地目录里的 Proton / Wine，逐个程序选运行器。
  默认前缀是 `~/.local/share/protonboost/proton`；老的 `~/.proton` 只要还在就继续沿用，
  不搬家。里面 `pfx/drive_c` 就是 Wine 的 C 盘（`windows`、`Program Files`、`users` 都在），
  由 Wine 首次初始化时创建，这一层不能改名——Proton 约定它就是 `WINEPREFIX`。
- **独立网络**：前缀默认关在单独的 network namespace 里（`pasta`），加速器和游戏共享同一个
  出口；关掉就回到宿主网络。
- **会话共享**：同一前缀里的程序共用一个 wineserver，显示方式与网络保持一致。
- **图形管理器**：应用 / Linux 程序 / 进程三个页面。点一行会在右侧展开检查器（路径、运行器、
  最近日志），也能重命名、导出到应用列表、强制结束进程。添加应用可以选 exe，也可以从安装
  目录里挑。
- **运行设置**：每个程序可以单独配 Gamescope（全屏 / 分辨率 / FPS 上限 / FSR 超分 /
  额外参数）、MangoHud、Wayland 原生模式、程序参数、自定义环境变量与 Steam AppID。
- **命令行入口**：`--run`（桌面入口）、`--configure`（运行设置）、`--exec`（Steam 启动选项）。

## 依赖

- Rust（构建用）、Qt 6：`qt6-base` `qt6-declarative` `qt6-svg`
- 运行时：`passt`（独立网络）、`util-linux`（nsenter / unshare）、`curl` + `tar`（下载运行器/运行时）、`sha512sum`（校验下载）
- 可选：`wine`（系统 Wine 运行器）、`icoextract`（图标提取）、`notify-send`（运行通知）、`gamescope` / `mangohud`（按需启用）；构建机需要 `cc`（覆盖层辅助库在构建期编译嵌入）
- 运行器：GE-Proton（界面里一键下载，默认）或任意一份 Proton / Wine，详见下面「运行器」一节

## 安装

```bash
git clone <repo> && cd protonboost
./install.sh                 # 构建 release 并安装到 ~/.local
./install.sh install ~/.opt  # 自定义 PREFIX
./install.sh uninstall       # 按安装记录卸载
./install.sh help            # 用法

# 已经编过 release、只想重新装一遍文件
PROTONBOOST_NO_BUILD=1 ./install.sh
```

构建需要 Qt 6 的开发文件（脚本会先检查，缺了会给出各发行版的包名）；
只安装现成二进制则不需要。

安装脚本会记下装了哪些文件（`$PREFIX/share/protonboost/installed-files.txt`），
卸载照着删，不会漏也不会顺手删掉别的东西。

**为什么不发 Flatpak / AppImage**：这个工具要调用宿主上的 Proton（pressure-vessel
在沙盒里起不来），还要读写 Steam 的 `compatibilitytools.d` 和你的前缀目录。沙盒化之后
要么把这些权限全开（等于没沙盒），要么根本跑不起来。所以走源码 + 安装脚本这条路，
想系统级安装就把 `PREFIX` 指到 `/usr/local`（用 `sudo`）。

## 使用

```bash
protonboost                        # 图形管理器
protonboost --configure 程序.exe   # 只打开某个程序的运行设置
protonboost --run 程序.exe         # 按保存的配置直接启动
protonboost --exec <命令>          # 在前缀会话里跑一条命令（Steam 启动选项）
protonboost --list-runner          # 列出发现的 Proton / Wine
protonboost --dump-scan [前缀]     # 打印前缀扫描结果（默认看默认前缀），排查界面为什么空
protonboost --doctor               # 环境诊断：缺什么命令、运行器在哪、前缀状态
protonboost --version              # 版本
```

- **右键 exe**：装好之后（`./install.sh`），文件管理器里右键任意 exe 有「运行Windows软件」
  和「设置Windows软件运行环境」两个动作。
- **装 Windows 软件**：下载来的安装包（setup.exe 之类）用上面那个右键动作就能直接跑起来，
  安装向导和 Windows 上一样。没装桌面入口时，用管理器里的「添加应用 → 直接运行 exe」，
  跑完不会往应用列表里塞条目；装好的程序会出现在 Windows 开始菜单里，刷新列表就能看到。
- **Steam 游戏**：启动选项填 `protonboost --exec %command%`，兼容性选一个 Proton。

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
| `~/.local/share/protonboost/proton` | 默认前缀（老的 `~/.proton` 会自动沿用；可在运行设置里换成别的） |
| `~/.cache/protonboost/associations` | 每个程序的运行设置 |
| `~/.cache/protonboost/logs` | 运行日志与会话日志 |
| `~/.cache/protonboost/icons` | 从 exe/ico 里抠出来的图标（界面缓存） |
| `~/.local/share/applications/protonboost` | 导出的应用桌面入口 |
| `~/.local/share/icons/protonboost/apps` | 导出桌面入口用的图标 |
| `$PREFIX/.protonboost.conf` | 前缀自己的开关（`netns=`，侧栏前缀行右边那个小开关改的就是它） |

## 运行器

程序本身不带 Proton / Wine，启动 Windows 程序必须有一个。按这个顺序找，找到几个就列几个：

| 来源 | 位置 |
| --- | --- |
| 环境变量 | `PROTONBOOST_RUNNER` / `PROTON_GE_PATH` 指向的 proton 或 wine |
| Steam 兼容性工具 | `~/.local/share/Steam/compatibilitytools.d/<名字>/proton`（GE、WE 都在这） |
| Steam 官方 Proton | `steamapps/common/Proton *`，含其他 Steam 库 |
| 系统级 / Flatpak | `/usr/share/steam/...`、`~/.var/app/com.valvesoftware.Steam/...` |
| Lutris | `~/.local/share/lutris/runners/{proton,wine}` |
| 本地目录 | `~/.local/share/proton/runners/<名字>/proton` |
| 系统 wine | `PATH` 里的 `wine` |

不绑定任何特定版本，每个程序可以在运行设置里单独选。Proton 系的还需要 Steam Linux
Runtime（`SteamLinuxRuntime_sniper` / `soldier`），本机没有的话会自动下载。

一个都没有时，应用页会显示一条提示，点「下载 GE-Proton」会取最新版装到
`~/.local/share/Steam/compatibilitytools.d/`；也可以自己装系统 wine 或 Steam 的 Proton，
重启管理器就会列出来。

## 独立网络

在侧栏把当前前缀右边那个小开关点亮，就给它开了独立网络（等价于在
`$PREFIX/.protonboost.conf` 里写 `netns=1`），下次启动生效。把 Windows 版加速器
（网易 UU 的「路由模式」、雷神的「模式三」）和游戏装进同一个前缀，加速器接管的
就是游戏所在的网络；关掉开关就回到宿主网络。

### Steam 游戏

在 Steam 里把游戏的启动选项设成：

```
protonboost --exec %command%
```

游戏会改在 ProtonBoost 的前缀里跑，和加速器共享同一个独立网络；Windows 版 Steam
（装在同一个前缀里的那份）也一样适用。

> 网络命名空间的实现细节——keeper 生命周期、Linux 程序降权、Steam 客户端端口转发、
> 覆盖层 uid 辅助库、D-Bus 会话桥——见 [`docs/DESIGN.md`](docs/DESIGN.md)。

## 构建

```bash
cargo build            # 调试版 → target/debug/protonboost
cargo build --release  # 发布版
```

`target/` 是 Cargo 的构建缓存（不是项目结构）：`deps/` 放编译好的依赖，`build/<crate>-<hash>/out`
是各依赖构建脚本的产物，`incremental/` 是增量缓存。删掉无妨，下次构建会重新生成；
积得太大（调试版通常 1–2 GB）直接 `cargo clean` 即可。这个目录已在 `.gitignore` 里。

## 代码结构

项目结构、每个模块的职责与关键机制的设计考量见 [`docs/DESIGN.md`](docs/DESIGN.md)。

只改 QML 直接 `cargo build` 就能重链——`build.rs` 把 QML 内容哈希塞进 rustc-env，
内容一变就会重新编译。无头验收（不开窗口也能看界面）：

```bash
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
PROTONBOOST_PAGE=apps PROTONBOOST_SHOT=/tmp/shot.png \
./target/debug/protonboost
```

`PROTONBOOST_SHOT_DELAY` 可调截图前的等待毫秒数（默认 1500，等动画跑完）。

## 许可

MIT。整体设计与实现见 [`docs/DESIGN.md`](docs/DESIGN.md)。
