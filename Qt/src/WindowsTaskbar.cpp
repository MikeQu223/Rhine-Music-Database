#include "WindowsTaskbar.h"
#include "Engine.h"
#include "MusicData.h"
#include <QCoreApplication>
#include <QDebug>
#include <QEvent>
#include <QGuiApplication>
#include <QIcon>
#include <QPainter>
#include <QPainterPath>
#include <QPlatformSurfaceEvent>
#include <QWindow>
#include <QTimer>
#include <cstring>
#include <iterator>
#include <algorithm>
#include <dwmapi.h>

namespace {
constexpr UINT FIRST_BUTTON_ID = 0x5200;
enum Icon { Previous, Play, Pause, Next, Like, Liked };

// 创建 Windows 图标与位图
HBITMAP createBitmap(const QImage &source) {
    const auto image = source.convertToFormat(QImage::Format_ARGB32_Premultiplied);
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = image.width();
    info.bmiHeader.biHeight = -image.height();
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void *pixels = nullptr;
    const auto bitmap = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (bitmap && pixels) {
        std::memcpy(pixels, image.constBits(), image.sizeInBytes());
    }
    return bitmap;
}

// Windows 菜单栏控制配置
HICON createButtonIcon(int kind) {
    constexpr int SIZE = 32;
    QImage image(SIZE, SIZE, QImage::Format_ARGB32_Premultiplied);
    image.fill(Qt::transparent);
    QPainter painter(&image);
    painter.setRenderHint(QPainter::Antialiasing);
    QPainterPath path;
    if (kind == Like || kind == Liked) {
        path.moveTo(16, 27);
        path.cubicTo(12, 23, 3, 17, 3, 10);
        path.cubicTo(3, 2, 12, 2, 16, 8);
        path.cubicTo(20, 2, 29, 2, 29, 10);
        path.cubicTo(29, 17, 20, 23, 16, 27);
    } else if (kind == Pause) {
        path.addRect(8, 6, 5, 20);
        path.addRect(19, 6, 5, 20);
    } else {
        if (kind == Previous) {
            painter.translate(SIZE, 0);
            painter.scale(-1, 1);
        }
        path.moveTo(8, 6);
        path.lineTo(23, 16);
        path.lineTo(8, 26);
        path.closeSubpath();
        if (kind != Play) {
            path.addRect(24, 6, 4, 20);
        }
    }
    painter.setPen(QPen(QColor(30, 30, 30), 2));
    painter.setBrush(kind == Liked ? QColor(238, 75, 100) : QColor(245, 245, 245));
    painter.drawPath(path);
    if (kind == Like) {
        painter.setPen(QPen(QColor(30, 30, 30), 2));
        painter.setBrush(QColor(100, 100, 100));
        painter.drawPath(path);
    }
    painter.end();

    const auto bitmap = createBitmap(image);
    const std::array<BYTE, SIZE * SIZE / 8> maskPixels{};
    const auto mask = CreateBitmap(SIZE, SIZE, 1, 1, maskPixels.data());
    HICON icon = nullptr;
    if (bitmap && mask) {
        ICONINFO info{};
        info.fIcon = TRUE;
        info.hbmColor = bitmap;
        info.hbmMask = mask;
        icon = CreateIconIndirect(&info);
    }
    if (bitmap) {
        DeleteObject(bitmap);
    }
    if (mask) {
        DeleteObject(mask);
    }
    return icon;
}
}

WindowsTaskbar::WindowsTaskbar(Engine *engine, QWindow *window) : m_engine(engine) {
    const auto initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    m_comInitialized = SUCCEEDED(initialized);
    if (FAILED(initialized) && initialized != RPC_E_CHANGED_MODE) {
        qWarning() << "Taskbar COM initialization failed:" << initialized;
        return;
    }
    m_createdMessage = RegisterWindowMessageW(L"TaskbarButtonCreated");
    if (!m_createdMessage) {
        return;
    }
    for (int i = 0; i < int(m_icons.size()); ++i) {
        m_icons[i] = createButtonIcon(i);
    }
    QCoreApplication::instance()->installNativeEventFilter(this);
    connect(&engine->app->music.player, &MusicPlayer::changed, this, &WindowsTaskbar::updateButtons);
    connect(&engine->app->music.player, &MusicPlayer::changed, this, &WindowsTaskbar::updatePreview);
    connect(&engine->app->music, &MusicLibrary::invalidated, this, &WindowsTaskbar::updateButtons);
    bindWindow(window);
}

/** 提前监听系统就绪消息，窗口创建后再绑定；晚绑定仍可注册已经就绪的任务栏按钮。 */
void WindowsTaskbar::bindWindow(QWindow *window) {
    const auto handle = window ? reinterpret_cast<HWND>(window->winId()) : nullptr;
    if (m_window == window && m_handle == handle) {
        return;
    }
    if (m_window) {
        m_window->removeEventFilter(this);
    }
    resetToolbar();
    m_window = window;
    m_handle = handle;
    if (!m_handle) {
        return;
    }
    m_window->installEventFilter(this);
    // FancyZones requires a normal resizable top-level window. Qt removes these
    // styles for FramelessWindowHint; keep them while handling the client frame below.
    if (m_window->flags().testFlag(Qt::FramelessWindowHint)) {
        const auto style = GetWindowLongPtrW(m_handle, GWL_STYLE);
        SetWindowLongPtrW(m_handle, GWL_STYLE,
                          style | WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX);
        SetWindowPos(m_handle, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    }
    configurePreview();
    updatePreview();
    initializeToolbar();
}

void WindowsTaskbar::resetToolbar() {
    if (m_taskbar) {
        m_taskbar->Release();
        m_taskbar = nullptr;
    }
    m_buttonsAdded = false;
    m_lastState = -1;
}

/** 只在 Explorer 已确认当前 HWND 就绪后注册；重复显示沿用已有按钮。 */
void WindowsTaskbar::initializeToolbar() {
    if (!m_handle || !m_readyWindows.contains(quintptr(m_handle))) {
        return;
    }
    if (!m_taskbar) {
        auto result =
            CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&m_taskbar));
        if (SUCCEEDED(result)) {
            result = m_taskbar->HrInit();
        }
        if (FAILED(result)) {
            qWarning() << "Taskbar toolbar initialization failed:" << result;
            resetToolbar();
            return;
        }
    }
    updateButtons();
}

bool WindowsTaskbar::eventFilter(QObject *watched, QEvent *event) {
    if (watched == m_window) {
        if (event->type() == QEvent::PlatformSurface) {
            auto *surface = static_cast<QPlatformSurfaceEvent *>(event);
            if (surface->surfaceEventType() == QPlatformSurfaceEvent::SurfaceAboutToBeDestroyed) {
                m_readyWindows.remove(quintptr(m_handle));
                resetToolbar();
                m_handle = nullptr;
            } else {
                bindWindow(m_window);
            }
        } else if (event->type() == QEvent::WinIdChange) {
            if (m_window->handle()) {
                bindWindow(m_window);
            } else {
                // 句柄销毁时不能调用 winId()，否则会在析构过程中重新创建原生窗口。
                m_readyWindows.remove(quintptr(m_handle));
                resetToolbar();
                m_handle = nullptr;
            }
        } else if (event->type() == QEvent::Show) {
            QTimer::singleShot(0, this, &WindowsTaskbar::initializeToolbar);
        }
    }
    return QObject::eventFilter(watched, event);
}

// 任务栏预览配置
void WindowsTaskbar::configurePreview() {
    const BOOL enabled = TRUE;
    DwmSetWindowAttribute(m_handle, DWMWA_FORCE_ICONIC_REPRESENTATION, &enabled, sizeof(enabled));
    DwmSetWindowAttribute(m_handle, DWMWA_HAS_ICONIC_BITMAP, &enabled, sizeof(enabled));
    DwmInvalidateIconicBitmaps(m_handle);
}

void WindowsTaskbar::updatePreview() {
    const auto &player = m_engine->app->music.player;
    const auto trackKey = PlaybackQueue::identity(player.current);
    const auto coverKey = player.coverImage;
    if (trackKey == m_trackKey && coverKey == m_coverKey) {
        return;
    }
    m_trackKey = trackKey;
    m_coverKey = coverKey;
    m_cover = coverKey.isEmpty() ? QImage() : m_engine->host.image(coverKey);
    DwmInvalidateIconicBitmaps(m_handle);
}

QImage WindowsTaskbar::previewImage(QSize bounds) const {
    const int side = std::clamp(std::min(bounds.width(), bounds.height()), 1, 1024);
    QImage image(side, side, QImage::Format_ARGB32_Premultiplied);
    image.fill(QColor(30, 30, 30));
    QPainter painter(&image);
    const auto cover = m_cover.isNull() ? QGuiApplication::windowIcon().pixmap(256, 256).toImage() : m_cover;
    if (!cover.isNull()) {
        const auto size = cover.size().scaled(image.size(), Qt::KeepAspectRatio);
        const QRect target((side - size.width()) / 2, (side - size.height()) / 2, size.width(),
                           size.height());
        painter.setRenderHint(QPainter::SmoothPixmapTransform);
        painter.drawImage(target, cover);
    }
    return image;
}

bool WindowsTaskbar::sendPreview(QSize bounds, bool live) {
    if (bounds.isEmpty()) {
        return false;
    }
    const auto bitmap = createBitmap(previewImage(bounds));
    if (!bitmap) {
        return false;
    }
    const auto result = live ? DwmSetIconicLivePreviewBitmap(m_handle, bitmap, nullptr, 0)
                             : DwmSetIconicThumbnail(m_handle, bitmap, 0);
    DeleteObject(bitmap);
    return SUCCEEDED(result);
}

// 移除消息入口，释放图标与 COM 引用
WindowsTaskbar::~WindowsTaskbar() {
    QCoreApplication::instance()->removeNativeEventFilter(this);
    if (m_window) {
        m_window->removeEventFilter(this);
    }
    resetToolbar();
    for (const auto icon : m_icons) {
        if (icon) {
            DestroyIcon(icon);
        }
    }
    if (m_comInitialized) {
        CoUninitialize();
    }
}

void WindowsTaskbar::updateButtons() {
    if (!m_taskbar || !m_window) {
        return;
    }
    const auto &music = m_engine->app->music;
    const auto &player = music.player;
    const auto track = player.current;
    const bool hasTrack = !track.isEmpty();
    const bool playing = player.state["playing"].toBool();
    const bool canPlay = hasTrack && !player.loading;
    const bool canSkip = hasTrack && !player.queue.isEmpty();
    const bool canLike = hasTrack && track["kind"] == "song" && music.editable() && !music.uid.isEmpty() &&
                         !music.writeLoading && music.canMutate("/like");
    const bool liked = (music.likedIDs && MusicData::indexOf(*music.likedIDs, track["id"]) >= 0) ||
                       MusicData::indexOfId(music.lists[1], track["id"].toString()) >= 0 ||
                       music.subscriptionStates.value(track["key"].toString()) == "subscribed";
    const int state =
        int(playing) | (int(canPlay) << 1) | (int(canSkip) << 2) | (int(canLike) << 3) | (int(liked) << 4);
    if (m_buttonsAdded && state == m_lastState) {
        return;
    }
    const std::array<int, 4> icons{Previous, playing ? Pause : Play, Next, liked ? Liked : Like};
    const std::array<const wchar_t *, 4> tips{L"上一首", playing ? L"暂停" : L"播放", L"下一首",
                                              liked ? L"取消喜欢" : L"喜欢"};
    const std::array<bool, 4> enabled{canSkip, canPlay, canSkip, canLike};
    std::array<THUMBBUTTON, 4> buttons{};
    for (int i = 0; i < int(buttons.size()); ++i) {
        auto &button = buttons[i];
        button.dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
        button.iId = FIRST_BUTTON_ID + i;
        button.hIcon = m_icons[icons[i]];
        lstrcpynW(button.szTip, tips[i], int(std::size(button.szTip)));
        button.dwFlags = enabled[i] ? THBF_ENABLED : THBF_DISABLED;
    }
    const auto result = m_buttonsAdded
                            ? m_taskbar->ThumbBarUpdateButtons(m_handle, UINT(buttons.size()), buttons.data())
                            : m_taskbar->ThumbBarAddButtons(m_handle, UINT(buttons.size()), buttons.data());
    if (SUCCEEDED(result)) {
        m_buttonsAdded = true;
        m_lastState = state;
    } else {
        qWarning() << "Taskbar thumbnail toolbar update failed:" << result;
    }
}

bool WindowsTaskbar::nativeEventFilter(const QByteArray &, void *message, qintptr *result) {
    const auto event = static_cast<MSG *>(message);
    if (m_createdMessage && event->message == m_createdMessage) {
        m_readyWindows.insert(quintptr(event->hwnd));
        if (event->hwnd == m_handle) {
            resetToolbar();
            configurePreview();
            initializeToolbar();
        }
        return false;
    }
    if (event->message == WM_NCDESTROY) {
        m_readyWindows.remove(quintptr(event->hwnd));
        if (event->hwnd == m_handle) {
            resetToolbar();
            m_handle = nullptr;
        }
    }
    if (!m_window || event->hwnd != m_handle) {
        return false;
    }
    if (m_window->flags().testFlag(Qt::FramelessWindowHint)) {
        if (event->message == WM_NCCALCSIZE && event->wParam) {
            // Retain the custom title bar; maximized client geometry must exclude
            // the taskbar rather than extending to the entire monitor.
            if (IsZoomed(m_handle)) {
                MONITORINFO monitor{sizeof(MONITORINFO)};
                if (GetMonitorInfoW(MonitorFromWindow(m_handle, MONITOR_DEFAULTTONEAREST), &monitor)) {
                    reinterpret_cast<NCCALCSIZE_PARAMS *>(event->lParam)->rgrc[0] = monitor.rcWork;
                }
            }
            *result = 0;
            return true;
        }
        if (event->message == WM_NCHITTEST && m_window->visibility() != QWindow::FullScreen) {
            POINT point{short(LOWORD(event->lParam)), short(HIWORD(event->lParam))};
            ScreenToClient(m_handle, &point);
            const auto dpr = m_window->devicePixelRatio();
            const QPointF logical(point.x / dpr, point.y / dpr);
            if (logical.y() >= 5 && logical.y() < 32 && logical.x() >= 5 &&
                logical.x() < m_window->width() - 132) {
                *result = HTCAPTION;
                return true;
            }
        }
    }
    if (event->message == WM_DWMSENDICONICTHUMBNAIL || event->message == WM_DWMSENDICONICLIVEPREVIEWBITMAP) {
        const bool live = event->message == WM_DWMSENDICONICLIVEPREVIEWBITMAP;
        const QSize bounds = live ? m_window->size() : QSize(HIWORD(event->lParam), LOWORD(event->lParam));
        sendPreview(bounds, live);
        if (result) {
            *result = 0;
        }
        return true;
    }
    if (event->message == WM_DWMCOMPOSITIONCHANGED) {
        configurePreview();
    }
    if (event->message == WM_COMMAND && HIWORD(event->wParam) == THBN_CLICKED) {
        const auto id = LOWORD(event->wParam);
        if (id < FIRST_BUTTON_ID || id >= FIRST_BUTTON_ID + 4 || !m_buttonsAdded) {
            return false;
        }
        // 离开原生消息栈后再改播放状态，按钮不激活窗口，也不依赖 HUD 当前选中的歌曲。
        QTimer::singleShot(0, this, [this, id] {
            updateButtons();
            int enabledBit = 2;
            if (id == FIRST_BUTTON_ID + 1) {
                enabledBit = 1;
            } else if (id == FIRST_BUTTON_ID + 3) {
                enabledBit = 3;
            }
            if (!(m_lastState & (1 << enabledBit))) {
                return;
            }
            auto &music = m_engine->app->music;
            if (id == FIRST_BUTTON_ID + 3) {
                if (!music.player.current.isEmpty() && music.editable() && !music.uid.isEmpty() &&
                    !music.writeLoading && music.canMutate("/like")) {
                    music.like(music.player.current);
                    m_engine->wake();
                }
            } else {
                static const std::array<QString, 3> actions{"player:prev", "player:toggle", "player:next"};
                m_engine->action(actions[id - FIRST_BUTTON_ID]);
            }
            updateButtons();
        });
        if (result) {
            *result = 0;
        }
        return true;
    }
    return false;
}
