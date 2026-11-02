# ProtonBoost 架构与设计

ProtonBoost 让 Windows 程序在 Linux 上「双击就能跑」，并把游戏加速器与游戏
放进同一个网络命名空间里——加速器接管的就是游戏真正走的网络。

本文描述整体架构、关键机制的设计考量，以及当前已知的功能边界。

## 总览

Rust + Qt 6（cxx-qt + QML）。单二进制，装完即用：

```
src/
  main.rs             CLI 入口：--doctor、--exec、--dump-scan 等子命令
  app/                界面层
    shim.cpp / shim.h 托盘、窗口、文件对话框（C++ 侧）
    bridge.rs         QML 与 Rust 的桥（cxx-qt 生成的粘合层）
    jobs.rs           后台任务：扫描、下载、导出
    ipc.rs            单实例（unix 套接字，残留自愈）
  core/               与启动无关的通用件
    paths.rs          XDG 路径（前缀、缓存、日志）
    prefix.rs         前缀数据结构、进程环境反查
    scan.rs           前缀扫描：发现装过的 Windows 程序
    lnk.rs            .lnk 快捷方式解析（Proton 不认识 .lnk）
    export.rs         导出桌面入口
    steam.rs          Steam 数据目录、appid 映射
    icons.rs          图标提取
    procs.rs          进程跟踪
  engine/             启动引擎（核心链路）
    runners.rs        发现与解析 Proton / Wine
    runtime.rs        Steam Linux Runtime 的查找与下载
    session.rs        会话 + 独立网络命名空间（pasta + keeper）
    launch.rs         环境变量与命令行的组装、进程拉起
    overlay.rs        Steam 覆盖层的 uid 辅助库
    steam_forward.rs  命名空间里的游戏连宿主 Steam 客户端（57343）
    update.rs         WE-Proton 的在线安装与更新
    logs.rs           运行日志
native/overlay-uid/   覆盖层辅助库的 C 源码（构建期编译嵌入）
qml/Main.qml          全部界面
```

## 前缀

- 默认 `~/.local/share/protonboost/proton`（XDG 数据目录，文件管理器里看得见）；
  老的 `~/.proton` 只要还在就沿用，不搬用户数据；`PROTONBOOST_PREFIX` 优先级最高
- 内部是 `pfx/drive_c/...`，即 Wine 的 C 盘；同前缀的程序共用一个 wineserver，
  也就共用显示方式与网络命名空间
- 首次启动自动初始化，无向导

## 运行器

- **WE-Proton 是唯一在线安装项**（SHORiN-KiWATA 基于 GE/DW 的魔改，自带 wintun，
  加速器的 NDIS 内核驱动在 Wine 里没有实现）：GitHub releases 取最新版（直连失败自动换镜像，
  `PROTONBOOST_GH_MIRROR` 可指定），下载 → sha512 流式校验 →
  解压到 `compatibilitytools.d/Proton-GE Latest/`，界面一键完成
- 本地手动安装的运行器（WE-Proton、lutris wine、系统 wine、Steam 自带 Proton）
  照样被发现并可用，只是不提供在线更新
- Proton 要跑在它 `toolmanifest.vdf` 指定的 Steam Linux Runtime 容器里，
  找不到就自动下载；实在没有就直接跑（部分功能缺失）
- 32 位程序默认走 Wine 的新 WoW64 模式（`PROTON_USE_WOW64=1`）

## 运行设置与启动链路

每个程序的运行设置（`associations/*.conf`）在启动时由 `launch.rs` 拼成 argv + 环境：

- **Gamescope**：包裹在会话外（留在宿主命名空间），程序自己经 `nsenter` 进会话；
  选项映射为 `-f`（全屏）、`-w/-h`（分辨率）、`-r`（FPS 上限）、`-F fsr`（超分）
  及额外参数
- **MangoHud**：注入 `MANGOHUD=1`
- **Wayland 原生**：Proton 走 `PROTON_ENABLE_WAYLAND=1`，Wine 走
  `WINE_GRAPHICS_DRIVER=wayland`；与 Gamescope 互斥（开了 Gamescope 就忽略）
- **Steam AppID**：注入 `SteamAppId` / `SteamGameId`（Proton 需要）；不填时用
  `UMU_ID=protonboost` 兜底
- **环境变量**：程序自己配的优先于会话默认值；另注入四个自描述变量——
  `PROTONBOOST_APP_ID`、`PROTONBOOST_APP_PATH`、`PROTONBOOST_PREFIX`、
  `PROTONBOOST_LOG`（最近一次日志路径），脚本可以拿来定位自己的日志
- Proton 的动词固定 `waitforexitandrun`（`--verb=` 是给 pressure-vessel 的，
  不能顶替，缺了会报 `Need a verb.`）

## 独立网络

前缀默认关在单独的 network namespace 里，这是 ProtonBoost 的核心能力：

- `pasta` 建网，keeper 进程待在命名空间里撑住它；前缀里最后一个程序退出，
  keeper 跟着收摊
- 程序用 `nsenter -t <keeper> -U -n --preserve-credentials` 进入
- **Linux 程序降权**：pasta 把用户映射成命名空间里的 root，Steam 这类程序看到
  uid 0 就拒绝运行。Linux 程序进会话时再套一层 user namespace
  （`unshare -U --map-user=<真实 uid>`），在里面它是普通用户；
  Windows 程序保持 root，加速器的 TUN 驱动才装得上
- **MAC 地址**：命名空间用宿主默认路由网卡的 MAC，反作弊才不会认为你换了机器
- **DNS 钉扎**：每条宿主路由钉一个 DNS 服务器。加速器的 TUN 模式会把所有请求
  塞进它的网卡，几百次之后节点不再应答，游戏域名就解析不出来
- **Steam 客户端端口转发**：游戏通过 `127.0.0.1:57343` 找 Steam 客户端，命名空间里
  那是自己的回环；keeper 监听该端口转给宿主 Steam，宿主没有时放开给命名空间里的 Steam
- **D-Bus 会话桥**：命名空间里的程序拿 `uid 0` 去 SASL 认证，宿主总线一查对端凭证
  是 1000 就拒绝——托盘、通知、输入法全部哑火。keeper 在会话目录里起一个代理
  socket（`<会话目录>/bus`），把 `AUTH EXTERNAL` 行里的 uid 改写成真实 uid 再转给
  总线，其余字节与文件描述符（`SCM_RIGHTS`）原样透传
- **fcitx5 联动**：桥通了之后，会话里自动设 `GTK_IM_MODULE` / `QT_IM_MODULE` /
  `XMODIFIERS` / `SDL_IM_MODULE`，命名空间里的 GUI 程序连上宿主的 fcitx5；
  宿主没在跑 fcitx5 时不设，免得程序去连不存在的输入法
- 降级策略：独立网络起不来时退回宿主网络并在界面说明，而不是拒绝启动

## Steam 覆盖层

覆盖层（FPS、成就、好友）按 `getuid()` 拼共享内存名字
（`/dev/shm/u<uid>-ValveIPCSharedObj-Steam`）。命名空间里 Wine 是 root、
宿主客户端是普通用户，两边永远碰不上，覆盖层会悄悄失效。

解法是一个极小的辅助库预加载进游戏：用 `dl_iterate_phdr` 找到覆盖层自己的代码范围，
**只有覆盖层问到 `getuid()` 时**才回答真实 uid，其他调用者（Wine、TUN 适配器）
照旧看到 root。C 源码在 `native/overlay-uid/`，**构建期编译成 64/32 位 .so 嵌进
二进制**——用户机器不需要 C 编译器；只有嵌入产物缺架构时才回退到现场 `cc` 编译。

## Steam %command%

Steam 展开 `%command%` 后是：Steam 自己的运行器前缀 + `proton` + 动词 + 游戏 exe。
ProtonBoost 剥掉那层前缀，让游戏改在自己的前缀与独立网络里跑——于是和加速器
共享同一个网络。把启动选项设成 `protonboost --exec %command%` 即可。

## 界面与命令行

QML 界面：应用、Linux 程序、进程三个视图 + 右侧检查器；独立网络开关在侧栏。
命令行入口（`--run` / `--configure` / `--exec` / `--doctor` 等）的完整用法
见 README 的「使用」一节；`--doctor` 做环境诊断，`--dump-scan` 打印前缀扫描
结果，排查界面为什么是空的。

## 已知边界

- **MAC 沿用的反作弊验证**：机制已实现，尚未在各家反作弊下逐一实测
