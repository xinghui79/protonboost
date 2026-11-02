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
- **命令行入口**：`--run`（桌面入口）、`--configure`（运行设置）、`--exec`（Steam 启动选项）。

## 依赖

- Rust（构建用）、Qt 6：`qt6-base` `qt6-declarative` `qt6-svg`
- 运行时：`passt`（独立网络）、`util-linux`（nsenter / unshare）、`curl` + `tar`（下载运行器/运行时）
- 可选：`wine`（系统 Wine 运行器）、`icoextract`（图标提取）；构建机需要 `cc`（覆盖层辅助库在构建期编译嵌入）
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
protonboost --dump-scan            # 打印前缀扫描结果，排查界面为什么空
protonboost --doctor               # 环境诊断：缺什么命令、运行器在哪、前缀状态
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
| `~/.cache/protonboost/icons` | 从 exe/ico 里抠出来的图标 |
| `$PREFIX/.protonboost.conf` | 前缀自己的开关（`netns=`，侧栏前缀行右边那个小开关改的就是它） |

## 运行器

程序本身不带 Proton / Wine，启动 Windows 程序必须有一个。按这个顺序找，找到几个就列几个：

| 来源 | 位置 |
| --- | --- |
| 环境变量 | `PROTONBOOST_RUNNER` / `PROTON_GE_PATH` 指向的 proton 或 wine |
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
`$PREFIX/.protonboost.conf` 里写 `netns=1`），下次启动生效。

前缀开了独立网络后，`pasta` 建一个 network namespace，keeper 进程待在里面把网络撑住，
程序用 `nsenter` 进去；前缀里最后一个程序退出，keeper 跟着收摊。把 Windows 版加速器
（网易 UU 的「路由模式」、雷神的「模式三」）和游戏装进同一个前缀，加速器接管的就是
游戏所在的网络。

### Linux 程序也能进这个网络

`pasta` 会把用户映射成命名空间里的 root，Steam 这类程序检查到 `uid 0` 就拒绝运行
（`Cannot run as root user`）。所以 Linux 程序进会话时会**再套一层 user namespace**
（`unshare -U --map-user=<你的真实 uid>`），在里面它就是普通用户，Steam 照常能跑。

### Steam 游戏

在 Steam 里把游戏的启动选项设成：

```
protonboost --exec %command%
```

`%command%` 里 Steam 自己的运行器前缀会被剥掉，游戏改为在 ProtonBoost 的前缀里跑——
于是它和加速器共享同一个独立网络。Windows 版 Steam（装在同一个前缀里的那份）
也一样适用。

游戏通过 `127.0.0.1:57343` 找 Steam 客户端；独立网络里这个地址是命名空间自己的
回环，keeper 会把连接转给宿主上的 Steam 客户端。

Steam 覆盖层（FPS、成就）要靠 `getuid()` 找宿主客户端。命名空间里 Wine 是 root、
宿主客户端是普通用户，两边对不上，覆盖层会悄悄失效。ProtonBoost 把一个很小的辅助库
在**构建期编译好嵌进二进制**（`assets/overlay-uid/`），预加载进游戏后只让覆盖层
看到真实 uid——用户机器上不需要装 C 编译器。只有在特殊架构上构建时才会回退到
现场用 `cc` 编译。

## 构建

```bash
cargo build            # 调试版 → target/debug/protonboost
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
  overlay.rs             Steam 覆盖层的 uid 辅助库（现场编译的小 .so）
  steam_forward.rs       命名空间里的游戏连宿主 Steam 客户端（57343）
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
PROTONBOOST_PAGE=apps PROTONBOOST_SHOT=/tmp/shot.png \
./target/debug/protonboost
```

## 设计来源

独立网络机制（Linux 程序降权、Steam 覆盖层辅助库、Steam 端口转发）参照了
[SHORiN-KiWATA/proton-wrapper](https://github.com/SHORiN-KiWATA/proton-wrapper) 的实现思路，
改写为 Rust。详细差异与还没移植的部分见 [`docs/DESIGN.md`](docs/DESIGN.md)。

## 许可

MIT。独立网络部分参考了 [SHORiN-KiWATA/proton-wrapper](https://github.com/SHORiN-KiWATA/proton-wrapper)
的思路（用同样的 Proton 调用方式跑 Windows 程序），现在这套实现是重写的 Rust 版本。
