#include "DesktopWallpaper.h"
#include <QGuiApplication>
#include <QQuickWindow>
#include <QQuickItem>
#include <QMouseEvent>
#include <QQmlEngine>
#include <QQmlContext>
#include <QQmlComponent>
#include <QElapsedTimer>
#include <QThread>
#include <QScreen>
#include <QImage>
#include <QDebug>
#include <QSGRendererInterface>
#include <cmath>
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <QtGui/qscreen_platform.h>

class Fixture : public QObject {
    Q_OBJECT
    Q_PROPERTY(QRectF desktopControlRect READ desktopControlRect NOTIFY desktopGeometryChanged)
    Q_PROPERTY(QString title READ title CONSTANT)
    Q_PROPERTY(double duration READ duration CONSTANT)
    Q_PROPERTY(double progress READ progress NOTIFY playbackChanged)
    Q_PROPERTY(bool playing READ playing NOTIFY playbackChanged)
    Q_PROPERTY(bool seekable READ seekable CONSTANT)
    Q_PROPERTY(QVariantList spectrum READ spectrum NOTIFY spectrumChanged)
  public:
    DesktopWallpaper *desktop = nullptr;
    int toggles = 0, exits = 0;
    double selectedProgress = -1;
    QRectF desktopControlRect() const {
        return desktop ? desktop->controlsRect() : QRectF();
    }
    Q_INVOKABLE void attachWallpaperVideo(QVariant) {
    }
    QString title() const {
        return QStringLiteral("Desktop audio spectrum preview");
    }
    double duration() const {
        return 180000;
    }
    double progress() const {
        return .36;
    }
    bool playing() const {
        return true;
    }
    bool seekable() const {
        return true;
    }
    QVariantList spectrum() const {
        QVariantList values;
        for (int i = 0; i < 40; ++i) {
            values.append(.7 * std::exp(-std::pow((i - 15) / 10., 2)));
        }
        return values;
    }
    Q_INVOKABLE void toggleMusic() {
        ++toggles;
    }
    Q_INVOKABLE void showSettings() {
    }
    Q_INVOKABLE void seekMusic(double fraction) {
        selectedProgress = fraction;
    }
    Q_INVOKABLE void exitWallpaper() {
        ++exits;
    }
  signals:
    void desktopGeometryChanged();
    void videoCleared();
    void playbackChanged();
    void spectrumChanged();
};

int main(int argc, char **argv) {
    QGuiApplication application(argc, argv);
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Vulkan);
    if (argc < 3 || !DesktopWallpaper::supported()) {
        return 1;
    }
    QQmlEngine engine;
    Fixture fixture;
    engine.rootContext()->setContextProperty("rhineMv", &fixture);
    engine.rootContext()->setContextProperty("rhineFontFamily", "Segoe UI");
    QQmlComponent component(&engine, QUrl::fromLocalFile(QString::fromLocal8Bit(argv[1])));
    std::unique_ptr<QObject> object(component.create());
    auto wallpaper = qobject_cast<QQuickWindow *>(object.get());
    if (!wallpaper) {
        qCritical() << component.errors();
        return 1;
    }
    bool passed = true;
    int index = 0;
    qInfo() << "Desktop topology" << quintptr(FindWindowW(L"Progman", nullptr))
            << quintptr(
                   FindWindowExW(FindWindowW(L"Progman", nullptr), nullptr, L"SHELLDLL_DefView", nullptr))
            << quintptr(FindWindowExW(FindWindowW(L"Progman", nullptr), nullptr, L"WorkerW", nullptr));
    for (auto screen : QGuiApplication::screens()) {
        DesktopWallpaper desktop;
        fixture.desktop = &desktop;
        wallpaper->setColor(QColor("#31424b"));
        QString error;
        if (!desktop.attach(wallpaper, screen, &error) || !desktop.setInteractive(true)) {
            qCritical() << error;
            return 1;
        }
        emit fixture.desktopGeometryChanged();
        desktop.setVisible(true);
        emit fixture.spectrumChanged();
        QElapsedTimer clock;
        clock.start();
        while (clock.elapsed() < 500) {
            QCoreApplication::processEvents();
            QThread::msleep(5);
        }
        emit fixture.desktopGeometryChanged();
        RECT actual{};
        const auto native = reinterpret_cast<HWND>(wallpaper->winId());
        GetWindowRect(native, &actual);
        MONITORINFOEXW monitor{};
        monitor.cbSize = sizeof(monitor);
        GetMonitorInfoW(MonitorFromWindow(native, MONITOR_DEFAULTTONEAREST),
                        reinterpret_cast<MONITORINFO *>(&monitor));
        const bool geometry = EqualRect(&actual, &monitor.rcMonitor) &&
                              MonitorFromWindow(native, MONITOR_DEFAULTTONEAREST) ==
                                  screen->nativeInterface<QNativeInterface::QWindowsScreen>()->handle();
        passed &= geometry && desktop.healthy() && (GetWindowLongPtrW(native, GWL_STYLE) & WS_CHILD);
        qInfo() << "Desktop screen" << screen->name() << "physical bounds" << actual.left << actual.top
                << actual.right << actual.bottom << "controls" << desktop.controlsRect() << "visible"
                << wallpaper->isVisible() << "exposed" << wallpaper->isExposed() << "passed" << geometry;
        const auto preview = wallpaper->grabWindow();
        const auto region = desktop.controlsRect();
        const auto scale = wallpaper->devicePixelRatio();
        passed &= !preview.isNull() &&
                  preview
                      .copy(QRect(qRound(region.x() * scale), qRound(region.y() * scale),
                                  qRound(region.width() * scale), qRound(region.height() * scale)))
                      .save(QString::fromLocal8Bit(argv[2]) + QString::number(index++) + ".png");
        const auto mouse = [wallpaper](QEvent::Type type, const QPointF &point, Qt::MouseButton button,
                                       Qt::MouseButtons buttons) {
            QMouseEvent event(type, point, wallpaper->mapToGlobal(point), button, buttons, Qt::NoModifier);
            QCoreApplication::sendEvent(wallpaper, &event);
            QCoreApplication::processEvents();
        };
        const auto click = [&](const char *name) {
            auto item = wallpaper->findChild<QQuickItem *>(QString::fromLatin1(name));
            if (!item) {
                passed = false;
                return;
            }
            const auto point = item->mapToScene(QPointF(item->width() / 2, item->height() / 2));
            mouse(QEvent::MouseMove, point, Qt::NoButton, Qt::NoButton);
            mouse(QEvent::MouseButtonPress, point, Qt::LeftButton, Qt::LeftButton);
            mouse(QEvent::MouseButtonRelease, point, Qt::LeftButton, Qt::NoButton);
        };
        const auto toggles = fixture.toggles, exits = fixture.exits;
        click("desktopPauseButton");
        click("desktopExitButton");
        auto slider = wallpaper->findChild<QQuickItem *>("desktopProgress");
        if (slider) {
            const auto start = slider->mapToScene(QPointF(slider->width() * .25, slider->height() / 2));
            const auto finish = slider->mapToScene(QPointF(slider->width() * .75, slider->height() / 2));
            mouse(QEvent::MouseButtonPress, start, Qt::LeftButton, Qt::LeftButton);
            mouse(QEvent::MouseMove, finish, Qt::NoButton, Qt::LeftButton);
            mouse(QEvent::MouseButtonRelease, finish, Qt::LeftButton, Qt::NoButton);
        }
        const bool controls = fixture.toggles == toggles + 1 && fixture.exits == exits + 1 &&
                              fixture.selectedProgress > .65 && fixture.selectedProgress < .85;
        qInfo() << "Desktop controls input" << controls << "seek fraction" << fixture.selectedProgress;
        passed &= controls;
        desktop.detach();
        fixture.desktop = nullptr;
        passed &= !GetParent(native);
    }
    return passed ? 0 : 1;
}

#include "WallpaperChecks.moc"
