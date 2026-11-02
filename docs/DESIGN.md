# 设计来源与差异说明

ProtonBoost 的灵感来自 [SHORiN-KiWATA/proton-wrapper](https://github.com/SHORiN-KiWATA/proton-wrapper)
（原名 shorin-proton-wrapper）。那份项目是 Bash + Python + GTK4，本项目是 Rust + Qt 6 (QML)，
两者定位相同：让 Windows 程序在 Linux 上「双击就能跑」，并把游戏加速器与游戏放进同一个
网络命名空间里。

本文记录原版的关键设计，以及本项目在移植过程中做出的差异与补充。

## 原版的关键设计

### 前置环境

- 默认 `~/.proton`，不存在时静默初始化（借鉴 Wine 的 `~/.wine`）
- 内部是 `pfx/drive_c/...`，即 Wine 的 C 盘
- 同前缀的程序共用一个 wineserver，也就共用显示方式与网络命名空间

### 运行器

- 默认 WE-Proton，装在 `~/.local/share/Steam/compatibilitytools.d`
- 也支持 GE-Proton（GitHub releases）与 DW-Proton（dawn.wine 自建 API）
- Proton 要跑在它 `toolmanifest.vdf` 指定的 Steam Linux Runtime 容器里，
  没有就自动下载
- 32 位程序默认走 Wine 的新 WoW64 模式（`PROTON_USE_WOW64=1`）

### 独立网络

这是原版最有价值的部分，也是本项目移植时补得最多的地方。

- `pasta` 建 network namespace，keeper 进程撑着不塌
- 程序用 `nsenter -t <keeper> -U -n --preserve-credentials` 进去
- 命名空间的 MAC 地址用宿主默认路由那张网卡的，否则反作弊会认为你在换机器
- DNS 服务器逐个钉一条宿主路由：加速器的 TUN 模式把所有请求塞进它的网卡，
  几百次之后节点不再应答，游戏域名就解析不出来
- D-Bus 需要一座桥：pasta 把用户映射成 root，libdbus 拿 uid 0 去认证会被总线拒绝
- Steam 客户端的 57343 端口要转给宿主

### Linux 程序在独立网络里

原版 `run_linux_target`：

```bash
exec nsenter -t "$keeper" -U -n --preserve-credentials -- \
  unshare -U --map-user="$(id -u)" --map-group="$(id -g)" -- \
  <程序>
```

**再套一层 user namespace**，把 uid 从 root 映回真实用户。Steam 这类程序检查
`id -u`，看到 0 就拒绝运行；套这一层之后它就是普通用户了。

### Steam 覆盖层（`gameoverlayrenderer.so`）

覆盖层按 `getuid()` 拼共享内存的名字（`/dev/shm/u<uid>-ValveIPCSharedObj-Steam`）。
命名空间里 Wine 是 root、宿主客户端是普通用户，两边永远碰不上，覆盖层会悄悄失效。

原版的办法是编译一个极小的共享库预加载进游戏：用 `dl_iterate_phdr` 找到覆盖层自己的
代码范围，**只有覆盖层问到 `getuid()` 时**才回答用户的真实 uid，其他调用者
（Wine、加速器的 TUN 适配器）照旧看到 root。首次用到时用系统 C 编译器编译；
没有编译器时游戏照常跑，只是没有覆盖层。

### Steam %command%

Steam 展开 `%command%` 后是：Steam 自己的运行器前缀 + `proton` + 动词 + 游戏 exe + 参数。
原版 `take_steam_command` 把 `proton <动词>` 之后的部分截出来，让游戏在 wrapper 自己的
前缀与网络里跑，而不是 Steam 给它建的那一套。

## 本项目与原版的差异

| 方面 | 原版 | 本项目 |
| --- | --- | --- |
| 实现语言 | Bash + Python + GTK4 | Rust + Qt 6 (cxx-qt + QML) |
| 前缀默认值 | `~/.proton` | `~/.local/share/protonboost/proton`（老的 `~/.proton` 仍在就沿用） |
| 界面 | GTK4，三页 | QML，侧栏 + 三个视图 + 右侧检查器 |
| 运行器更新 | 三个产品（GE / DW / WE） | GE / DW（WE 是本地维护版，无在线安装） |
| 覆盖层辅助库 | Bash 里内嵌 C 源码 | `src/engine/overlay.rs`，同样现场编译 |
| 端口转发 | keeper 里的 Python 线程 | `src/engine/steam_forward.rs` |
| D-Bus 桥 | keeper 里的 Python | 暂缺（见下） |
| 单元测试 | 无 | `src/engine/tests.rs`，12 个 |

### 本项目补充的

- **前缀路径**：默认落在 XDG 数据目录，文件管理器里看得见；老路径不搬数据
- **检查器**：点一行在右侧展开，显示路径（Windows 视角）、运行器、最近日志
- **独立网络开关**：侧栏前缀行右侧的小开关直接改 `.protonboost.conf`
- **`--doctor`**：一次列清缺什么命令、运行器在哪、前缀状态、真实 uid
- **降级策略**：独立网络起不来时退回宿主网络并说明原因，而不是拒绝启动
- **快捷方式解析**：`.lnk` 自动解析成真正的 exe（Proton 不认识 `.lnk`）

### 还没移植的

- **D-Bus 桥**：命名空间里 libdbus 拿 uid 0 去认证会被总线拒绝，托盘图标、通知会失效。
  本项目目前只在会话里设了 `DBUS_SESSION_BUS_ADDRESS`，但没有真的建那座桥
- **MAC 地址沿用**：原版用宿主默认路由网卡的 MAC，本项目也实现了，但还没验证反作弊场景
- **D-Bus 会话桥接的 fcitx5 联动**：原版能在 Gamescope 里让 fcitx5 接管显示

## 许可与致谢

原版是 MIT 许可，作者 SHORiN-KiWATA。本项目的独立网络部分（降权、覆盖层辅助库、
端口转发）参照了它的实现思路并改写为 Rust，特此致谢。
