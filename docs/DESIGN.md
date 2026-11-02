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
    update.rs         GE-Proton 的在线安装与更新
    logs.rs           运行日志
assets/overlay-uid/   覆盖层辅助库的 C 源码（构建期编译嵌入）
qml/Main.qml          全部界面
```

## 前缀

- 默认 `~/.local/share/protonboost/proton`（XDG 数据目录，文件管理器里看得见）；
  老的 `~/.proton` 只要还在就沿用，不搬用户数据；`PROTONBOOST_PREFIX` 优先级最高
- 内部是 `pfx/drive_c/...`，即 Wine 的 C 盘；同前缀的程序共用一个 wineserver，
  也就共用显示方式与网络命名空间
- 首次启动自动初始化，无向导

## 运行器

- **GE-Proton 是唯一在线安装项**：GitHub releases 取最新版，下载 → sha512 校验 →
  解压到 `compatibilitytools.d/Proton-GE Latest/`，界面一键完成
- 本地手动安装的运行器（WE-Proton、lutris wine、系统 wine、Steam 自带 Proton）
  照样被发现并可用，只是不提供在线更新
- Proton 要跑在它 `toolmanifest.vdf` 指定的 Steam Linux Runtime 容器里，
  找不到就自动下载；实在没有就直接跑（部分功能缺失）
- 32 位程序默认走 Wine 的新 WoW64 模式（`PROTON_USE_WOW64=1`）

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
- 降级策略：独立网络起不来时退回宿主网络并在界面说明，而不是拒绝启动

## Steam 覆盖层

覆盖层（FPS、成就、好友）按 `getuid()` 拼共享内存名字
（`/dev/shm/u<uid>-ValveIPCSharedObj-Steam`）。命名空间里 Wine 是 root、
宿主客户端是普通用户，两边永远碰不上，覆盖层会悄悄失效。

解法是一个极小的辅助库预加载进游戏：用 `dl_iterate_phdr` 找到覆盖层自己的代码范围，
**只有覆盖层问到 `getuid()` 时**才回答真实 uid，其他调用者（Wine、TUN 适配器）
照旧看到 root。C 源码在 `assets/overlay-uid/`，**构建期编译成 64/32 位 .so 嵌进
二进制**——用户机器不需要 C 编译器；只有嵌入产物缺架构时才回退到现场 `cc` 编译。

## Steam %command%

Steam 展开 `%command%` 后是：Steam 自己的运行器前缀 + `proton` + 动词 + 游戏 exe。
ProtonBoost 剥掉那层前缀，让游戏改在自己的前缀与独立网络里跑——于是和加速器
共享同一个网络。把启动选项设成 `protonboost --exec %command%` 即可。

## 界面与命令行

- QML 界面：应用、Linux 程序、进程三个视图 + 右侧检查器；独立网络开关在侧栏
- `--doctor`：一次列清缺什么命令、运行器在哪、前缀状态、真实 uid、辅助库状态
- `--dump-scan`：打印前缀扫描结果，排查界面为什么是空的
- `--exec`：给 Steam `%command%` 用的入口

## 已知边界

- **D-Bus 会话桥**：命名空间里 libdbus 拿 uid 0 去认证会被总线拒绝，
  命名空间里的 Linux 程序托盘/通知会失效（Windows 程序不受影响）
- **MAC 沿用的反作弊验证**：机制已实现，尚未在各家反作弊下逐一实测

## 许可

MIT。
