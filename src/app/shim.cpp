// shim.cpp：Qt 在 Rust 侧没有绑定的小件 —— QApplication 与系统托盘
#include <QApplication>
#include <QGuiApplication>
#include <QIcon>
#include <QPixmap>
#include <QImage>
#include <QMenu>
#include <QQuickWindow>
#include <QSystemTrayIcon>
#include <QTimer>
#include <QWindow>
#include <QDebug>
#include <functional>
#include "rust/cxx.h"
#include "shim.h"

void winrun_install_log_bridge() {
    qInstallMessageHandler([](QtMsgType type, const QMessageLogContext &context, const QString &msg) {
        Q_UNUSED(type);
        Q_UNUSED(context);
        fprintf(stderr, "QT: %s\n", msg.toUtf8().constData());
        fflush(stderr);
    });
}

std::unique_ptr<QApplication> winrun_app_new(const QString &version) {
    static int argc = 1;
    static char arg0[] = "winrun-manager";
    static char *argv[] = {arg0, nullptr};
    auto app = std::unique_ptr<QApplication>(new QApplication(argc, argv));
    QApplication::setApplicationName(QStringLiteral("WinRun"));
    QApplication::setApplicationDisplayName(QStringLiteral("WinRun"));
    QApplication::setApplicationVersion(version);
    QApplication::setDesktopFileName(QStringLiteral("winrun"));
    return app;
}

int winrun_app_exec(const QApplication &app) {
    return const_cast<QApplication &>(app).exec();
}

void winrun_app_quit() {
    QApplication::quit();
}

bool winrun_icon_convert(const QString &source, const QString &target, int max_size) {
    QImage image(source);
    if (image.isNull()) {
        return false;
    }
    const int width = image.width();
    const int height = image.height();
    if (width > max_size || height > max_size) {
        image = image.scaled(max_size, max_size, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    }
    return image.save(target, "PNG");
}

// 桌面图标名（freedesktop 主题）→ PNG；找不到主题图标时返回 false
bool winrun_theme_icon(const QString &name, const QString &target, int size) {
    const QIcon icon = QIcon::fromTheme(name);
    if (icon.isNull()) {
        return false;
    }
    const QPixmap pixmap = icon.pixmap(size, size);
    if (pixmap.isNull()) {
        return false;
    }
    return pixmap.toImage().save(target, "PNG");
}

namespace winrun_tray {
std::function<void()> on_open;
std::function<void()> on_quit;
QSystemTrayIcon *icon = nullptr;
QMenu *menu = nullptr;
} // namespace winrun_tray

void winrun_tray_create(const QString &iconPath, rust::Fn<void()> on_open, rust::Fn<void()> on_quit) {
    winrun_tray::on_open = [on_open]() { on_open(); };
    winrun_tray::on_quit = [on_quit]() { on_quit(); };
    auto *tray = new QSystemTrayIcon(QIcon(iconPath));
    winrun_tray::icon = tray;
    auto *menu = new QMenu();
    winrun_tray::menu = menu;
    auto *open_action = menu->addAction(QStringLiteral("打开 WinRun"));
    auto *quit_action = menu->addAction(QStringLiteral("退出"));
    QObject::connect(open_action, &QAction::triggered, []() {
        if (winrun_tray::on_open) {
            winrun_tray::on_open();
        }
    });
    QObject::connect(quit_action, &QAction::triggered, []() {
        if (winrun_tray::on_quit) {
            winrun_tray::on_quit();
        }
    });
    tray->setContextMenu(menu);
    tray->setToolTip(QStringLiteral("WinRun"));
    QObject::connect(tray, &QSystemTrayIcon::activated,
                     [](QSystemTrayIcon::ActivationReason reason) {
                         if (reason == QSystemTrayIcon::Trigger && winrun_tray::on_open) {
                             winrun_tray::on_open();
                         }
                     });
    tray->show();
    if (!QSystemTrayIcon::isSystemTrayAvailable()) {
        qDebug() << "winrun: system tray not available";
    }
}

void winrun_tray_set_menu_title(const QString &open, const QString &quit) {
    if (!winrun_tray::menu) {
        return;
    }
    const auto actions = winrun_tray::menu->actions();
    if (actions.size() >= 2) {
        actions[0]->setText(open);
        actions[1]->setText(quit);
    }
}

void winrun_tray_cleanup() {
    if (winrun_tray::icon) {
        winrun_tray::icon->hide();
        winrun_tray::icon->deleteLater();
        winrun_tray::icon = nullptr;
    }
    if (winrun_tray::menu) {
        winrun_tray::menu->deleteLater();
        winrun_tray::menu = nullptr;
    }
}

// 开发用截图：延时抓取所有可见窗口，保存后退出。
// 用法：QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software WINRUN_SHOT=/tmp/a.png winrun-manager
void winrun_grab_windows(const QString &path, int delay_ms) {
    QTimer::singleShot(delay_ms, [path]() {
        int index = 0;
        for (QWindow *window : QGuiApplication::topLevelWindows()) {
            auto *quick = qobject_cast<QQuickWindow *>(window);
            if (!quick || !quick->isVisible()) {
                continue;
            }
            const QImage image = quick->grabWindow();
            if (image.isNull()) {
                continue;
            }
            QString target = path;
            if (index > 0) {
                const int dot = target.lastIndexOf(QLatin1Char('.'));
                const QString suffix = QStringLiteral("-%1").arg(index);
                target = dot > 0 ? target.left(dot) + suffix + target.mid(dot) : target + suffix;
            }
            image.save(target, "PNG");
            ++index;
        }
        QApplication::quit();
    });
}
