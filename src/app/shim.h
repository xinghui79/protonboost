// shim.h：shim.cpp 的声明，供 cxx 桥接包含
#pragma once
#include <QApplication>
#include <QString>
#include <memory>
#include "rust/cxx.h"

void winrun_install_log_bridge();
void winrun_set_window_icon(const QString &iconPath);
std::unique_ptr<QApplication> winrun_app_new(const QString &version);
int winrun_app_exec(const QApplication &app);
void winrun_app_quit();

// 图标文件（ico/png/svg/xpm）→ PNG，最长边不超过 max_size
bool winrun_icon_convert(const QString &source, const QString &target, int max_size);

// 桌面图标名（freedesktop 主题）→ PNG
bool winrun_theme_icon(const QString &name, const QString &target, int size);

void winrun_tray_create(const QString &iconPath, rust::Fn<void()> on_open, rust::Fn<void()> on_quit);
void winrun_tray_set_menu_title(const QString &open, const QString &quit);
void winrun_tray_cleanup();

// 开发用：延时把窗口渲染结果存成 PNG，然后退出（配合 QT_QPA_PLATFORM=offscreen 做无头验收）
void winrun_grab_windows(const QString &path, int delay_ms);
