# WinRun

本地独立维护的 Windows 程序运行器：用 Proton/Wine 运行 exe，开箱即用；支持独立网络
（配合游戏加速器）、同前缀会话共享和图形管理器。基于开源项目重构更名，运行逻辑保持一致。

命令行部分仍是 Bash 模块；图形管理器已用 Rust + Qt6（cxx-qt + QML）重写。

## 项目结构

```
bin/winrun                     主入口：默认值、模块装载、分发（163 行）
lib/                           功能模块，按序 source 装载：
                               10-core 20-usage 30-utils 40-product 50-install
                               60-launch 70-session 80-prefix 90-status 91-cli
                               92-helpers（keeper / gamescope / 输入法监听）

src/main.rs                    启动流程、单实例、托盘、--configure / --dump-scan
src/bridge.rs                  Backend：属性 + invokable，QML 的唯一数据源
src/jobs.rs                    两个工作线程 + 结果通道（扫描/图标/子进程都在这里）
src/ipc.rs                     单实例：unix 套接字唤起已运行的窗口
src/shim.cpp .h                Rust 侧没有 Qt 绑定的部分：QApplication、托盘、
                               图标转换、主题图标、无头截图
src/core/                      纯逻辑：前缀发现、.lnk 解析、应用/目录/进程扫描、
                               图标提取、配置读写、导出 .desktop
qml/Main.qml                   界面：自绘标题栏 + 侧栏 + 四页面 + 状态栏 + 弹层
build.rs / Cargo.toml          cxx-qt 把 Rust 桥接与 QML 一起编译进二进制
share/applications/            桌面文件（管理器入口 / 运行 / 设置运行环境）
icons/hicolor/                 图标（512px PNG + 可缩放 SVG）
install.sh                     安装 / 卸载脚本
```

## 构建

需要 cargo 与 Qt 6（`qt6-base` `qt6-declarative` `qt6-svg`）。

```
cargo build                     # 调试构建 → target/debug/winrun-manager
cargo build --release           # 发布构建
```

## 安装（用户级，无需 sudo）

```
./install.sh                # 安装到 ~/.local（缺产物会先 cargo build --release）
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
winrun-manager --configure 程序.exe   # 只打开某个程序的运行设置
```

Steam 游戏启动选项填 `winrun %command%`（游戏兼容性仍需选一个 Proton）。

## 图形管理器

四个页面：应用（前缀里已登记的程序，可运行 / 改配置 / 看日志 / 关闭 / 重命名 /
导出到应用列表）、Linux 程序（把原生程序放进同一前缀与网络）、进程（强制结束）、
目录（安装文件夹里的 exe 可直接生成配置）。关窗口进托盘，退出只走托盘菜单。

## 开发提示

- 只改 QML 也可以直接 `cargo build`：`build.rs` 把 QML 内容哈希塞进
  `rustc-env`，内容一变 cargo 就会重新编译并重链接（否则链接器感知不到
  qmlcachegen 产出的 .o 变化，跑的还是旧界面）。
- 无头验收（不需要开窗口）：

```
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
WINRUN_PAGE=apps WINRUN_SHOT=/tmp/shot.png \
./target/debug/winrun-manager
```

  `WINRUN_PAGE` 取 `apps|linux|procs|dirs`，`WINRUN_SHOT_DELAY` 是截图前的等待毫秒数。
- QML 报错会以 `QT:` 前缀打到 stderr。
- `winrun-manager --dump-scan ~/.proton` 直接打印扫描结果，用来核对界面为什么空。

## 独立网络（游戏加速）

`winrun --netns on` 后，前置环境里的程序运行在独立的网络命名空间。把 Windows 版
加速器（网易 UU「路由模式」/ 雷神「模式三」）和游戏装进同一前置环境即可加速；
Linux 程序也能放进同一网络（`winrun steam`）。依赖 `passt`，运行器需 WE-Proton
（内置 wintun）。

## 维护说明

本地独立维护。WE-Proton 运行器的在线安装/更新功能已移除，更新时手动解压到
`~/.local/share/Steam/compatibilitytools.d/WE-Proton Latest`；GE / DW 运行器
仍可用 `winrun --install ge|dw` 在线安装与更新。
