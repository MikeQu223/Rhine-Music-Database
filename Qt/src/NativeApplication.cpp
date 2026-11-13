#include <QtGlobal>
#include "NativeApplication.h"
#include "MobileTarget.h"
#include "render/HotPathProbe.h"
#if defined(Q_OS_ANDROID)
#include "render/HudPaintStats.h"
#endif
#include "AppStorage.h"
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QTimer>
#include <algorithm>
#include <cmath>

HudSceneActions NativeApplication::sceneActions(NativeScene *scene) {
    return {[scene](QString mode) { scene->setMode(mode); },
            [scene](bool dark) { scene->theme(dark); },
            [scene](bool reduced) { scene->reduced(reduced); },
            [scene](QString type, double x, double y, double delta) { scene->pointer(type, x, y, delta); },
            [scene](QString action) { scene->viewerAction(action); },
            [scene](QString key) { scene->viewerKey(key); },
            [scene]() { scene->openViewer(); },
            [scene](bool front) { scene->coverFront(front); }};
}

// 与 RhineMediaService.ACTION_SEEK 对应；会话回调的动作串形如 rhine.media.SEEK:<毫秒>。
constexpr char kSeekActionPrefix[] = "rhine.media.SEEK:";

/** 建立原生音乐、HUD、场景的值接口；所有异步失效统一唤醒 Qt 帧调度。 */
NativeApplication::NativeApplication(Host *host, Glyphs *glyphs, NativeScene *scene, QJsonObject content,
                                     QObject *parent)
    : QObject(parent), music(host, content), shortcuts(host), hud(host, glyphs, &music, sceneActions(scene)),
      m_host(host), m_scene(scene) {
    hud.shortcuts = &shortcuts;
    connect(&shortcuts, &GlobalShortcuts::changed, host, &Host::invalidate);
    connect(&shortcuts, &GlobalShortcuts::activated, this, [this](const QString &action) {
        if (action == "toggle") {
            music.player.toggle();
        } else if (action == "prev" || action == "next") {
            music.player.next(action == "next" ? 1 : -1);
        } else if (action == "volume-up" || action == "volume-down") {
            music.player.volume(std::clamp(
                music.player.state["volume"].toDouble() + (action == "volume-up" ? 0.05 : -0.05), 0., 1.));
        } else if (action == "like" && !music.player.current.isEmpty()) {
            music.like(music.player.current);
        } else if (action == "lyrics") {
            m_host->setPreference("desktop-lyrics",
                                  m_host->preference("desktop-lyrics") == "on" ? "off" : "on");
        }
        m_host->invalidate();
    });
    connect(&music, &MusicLibrary::invalidated, host, &Host::invalidate);
    connect(&music, &MusicLibrary::selectionRequested, this,
            [scene](int index, QJsonObject navigation) { scene->select(index, navigation); });
    connect(&music, &MusicLibrary::modeRequested, this, [scene](QString mode) { scene->setMode(mode); });
    connect(&music, &MusicLibrary::navigationRequested, this,
            [scene](QString axis, int direction) { scene->navigate(axis, direction); });
    connect(&music, &MusicLibrary::musicIdentityRequested, this,
            [scene](QString key) { scene->musicIdentity(key); });
    connect(&music, &MusicLibrary::musicClearRequested, this, [scene]() { scene->musicClear(); });
}
void NativeApplication::initialize() {
    m_scene->theme(hud.dark);
    m_scene->reduced(hud.reduced);
    const auto startupPreference = m_host->preference("startup-animation");
    // 仅首次启动展示动画
    const bool firstLaunch = startupPreference.isEmpty() && m_host->preference("theme").isEmpty() &&
                             m_host->preference("provider").isEmpty() &&
                             m_host->preference("volume").isEmpty();
    if (startupPreference.isEmpty()) {
        m_host->setPreference("startup-animation", "off");
    }
    if (!firstLaunch && !hud.startupAnimation) {
        m_scene->setMode("archive");
    }
    const auto saved = m_host->preference("volume");
    bool valid = false;
    const auto volume = saved.toDouble(&valid);
    if (!m_host->playbackConnection()) {
        music.player.volume(valid && std::isfinite(volume) ? volume : 0.7);
    }
    if (!m_host->offline) {
        QFile file(AppStorage::dataDirectory() + "/session.json");
        if (file.open(QIODevice::ReadOnly) && file.size() <= 64 * 1024 * 1024) {
            restoreSessionState(QJsonDocument::fromJson(file.readAll()).object());
        }
    }
    // 会话先恢复浏览与播放状态，再决定是否展示初始化页，避免旧场景模式覆盖开关。
    if (firstLaunch || hud.startupAnimation) {
        hud.action("replay");
    }
    music.restoreAccount();
    music.restoreIdentityName();
#if RHINE_MOBILE
    // 移动端没有"干净退出"：滑掉应用是 SIGKILL，aboutToQuit 永远不触发，桌面那套
    // 「退出时写 session.json」在这里一次都不会发生，表现为重启后不恢复上次状态。
    // 改成周期落盘 + 退后台立即落盘，与桌面恢复逻辑共用同一个文件与格式。
    auto *sessionSaver = new QTimer(this);
    sessionSaver->setInterval(15 * 1000);
    connect(sessionSaver, &QTimer::timeout, this, [this] { saveSession(); });
    sessionSaver->start();
    connect(qGuiApp, &QGuiApplication::applicationStateChanged, this, [this](Qt::ApplicationState state) {
        if (state == Qt::ApplicationInactive || state == Qt::ApplicationSuspended) {
            saveSession();
        }
    });
#endif
}
#if defined(Q_OS_LINUX) || defined(Q_OS_DARWIN)
// RHINE_STEP_PROBE=1：拆开 app->step 内部（场景采样 / HUD 绘制 / 观察与返回对象构建）。
static double nacSampleSum = 0, nacObserveSum = 0, nacDrawSum = 0, nacRestSum = 0;
static double nacSampleMax = 0, nacObserveMax = 0, nacDrawMax = 0, nacRestMax = 0;
static int nacFrames = 0;

#endif
QJsonObject NativeApplication::step(double time, double width, bool reuseScene) {
#if defined(Q_OS_LINUX) || defined(Q_OS_DARWIN)
#if defined(Q_OS_ANDROID)
    // Android 上无条件计时：设备设不了 RHINE_STEP_PROBE，而切歌动画的瓶颈就落在这几段里。
    // 三段各一次 nsecsElapsed，开销可忽略；数字走性能 JSON 的 step*Ms 字段。
    const bool nacProbe = false;
#else
    const bool nacProbe = qEnvironmentVariableIntValue("RHINE_STEP_PROBE") == 1;
#endif
    QElapsedTimer nacTimer;
    nacTimer.start();
#endif
    const auto frame = reuseScene ? music.frame : m_scene->sample(time);
#if defined(Q_OS_LINUX) || defined(Q_OS_DARWIN)
    const double nacSampleMs = double(nacTimer.nsecsElapsed()) / 1e6;
#endif
    if (frame.isEmpty()) {
        return {};
    }
    music.frame = frame;
#if defined(Q_OS_LINUX) || defined(Q_OS_DARWIN)
    QElapsedTimer nacObserveClock;
    nacObserveClock.start();
#endif
    music.observe(frame["selected"].toInt());
    if (hud.tab != "overview" && music.wantsSongDetails && frame["mode"] == "detail") {
        music.sameAlbum();
    }
#if defined(Q_OS_LINUX) || defined(Q_OS_DARWIN)
    const double nacObserveEnd = double(nacTimer.nsecsElapsed()) / 1e6;
    QElapsedTimer nacDrawClock;
    nacDrawClock.start();
#endif
    hud.draw(frame, width, time);
#if defined(Q_OS_LINUX) || defined(Q_OS_DARWIN)
    const double nacDrawMs = double(nacDrawClock.nsecsElapsed()) / 1e6;
    const double nacDrawEnd = double(nacTimer.nsecsElapsed()) / 1e6;
    RhineRender::hotPathWindow().frames.fetch_add(1);
#if defined(Q_OS_ANDROID)
    {
        auto &phase = RhineRender::stepPhaseStats();
        phase.count.fetch_add(1, std::memory_order_relaxed);
        phase.sceneSampleNs.fetch_add(quint64(nacSampleMs * 1e6), std::memory_order_relaxed);
        phase.observeNs.fetch_add(quint64((nacObserveEnd - nacSampleMs) * 1e6), std::memory_order_relaxed);
        phase.hudDrawNs.fetch_add(quint64(nacDrawMs * 1e6), std::memory_order_relaxed);
    }
#endif

    // 返回对象的构建会把 hud.commands 等大对象整份拷进新 QJsonObject，单独计时。
    QJsonObject nacResult{{"commands", hud.commands},
                          {"hits", hud.hits},
                          {"state", hud.state()},
                          {"current", music.current},
                          {"cover", music.coverImage}};
    if (nacProbe) {
        const double nacTotal = double(nacTimer.nsecsElapsed()) / 1e6;
        const double nacObserveMs = nacObserveEnd - nacSampleMs;
        nacSampleSum += nacSampleMs;
        nacObserveSum += nacObserveMs;
        nacDrawSum += nacDrawMs;
        nacRestSum += nacTotal - nacDrawEnd;
        nacSampleMax = std::max(nacSampleMax, nacSampleMs);
        nacObserveMax = std::max(nacObserveMax, nacObserveMs);
        nacDrawMax = std::max(nacDrawMax, nacDrawMs);
        nacRestMax = std::max(nacRestMax, nacTotal - nacDrawEnd);
        if (++nacFrames >= 60) {
            const double n = nacFrames;
            // F01（S1）：观察/专辑切换与 HUD 绘制分开计时——前者是音乐状态推进，后者才是绘制命令生成；
            // 末尾的「返回拷贝」是 QJsonObject 组装（commands/hits 的隐式共享赋值本身不深拷贝，
            // 这里量的是整体组装成本，不把赋值单独算成复制）。
            qInfo().noquote() << QStringLiteral(
                                     "app->step 内部: 场景采样 %1/峰%2 ms | 观察+专辑 %3/峰%4 ms | "
                                     "HUD 绘制 %5/峰%6 ms | 返回拷贝 %7/峰%8 ms")
                                     .arg(nacSampleSum / n, 0, 'f', 2)
                                     .arg(nacSampleMax, 0, 'f', 2)
                                     .arg(nacObserveSum / n, 0, 'f', 2)
                                     .arg(nacObserveMax, 0, 'f', 2)
                                     .arg(nacDrawSum / n, 0, 'f', 2)
                                     .arg(nacDrawMax, 0, 'f', 2)
                                     .arg(nacRestSum / n, 0, 'f', 2)
                                     .arg(nacRestMax, 0, 'f', 2);
            qInfo().noquote() << RhineRender::formatHotPathLine(RhineRender::takeHotPathSample());
            nacSampleSum = nacObserveSum = nacDrawSum = nacRestSum = 0;
            nacSampleMax = nacObserveMax = nacDrawMax = nacRestMax = 0;
            nacFrames = 0;
        }
    }
    return nacResult;
#else
    return {{"commands", hud.commands},
            {"hits", hud.hits},
            {"state", hud.state()},
            {"current", music.current},
            {"cover", music.coverImage}};
#endif
}
void NativeApplication::poll(double time, bool force) {
    music.player.tick(time, force);
}
void NativeApplication::mediaAction(QString action) {
    // 系统媒体控件的动作用字节面语义直达播放器：hud.action 的场景分派依赖交互帧，
    // 后台没有帧；且 hud 的 player:seek 是播放栏像素语义（值/20），不适用于会话回调。
    if (action == "resume" || action == "pause") {
        music.player.setPaused(action == "pause");
    } else if (action == "next" || action == "prev") {
        music.player.next(action == "next" ? 1 : -1);
    } else if (action.startsWith(kSeekActionPrefix)) {
        const auto position = action.mid(int(sizeof(kSeekActionPrefix) - 1)).toDouble();
        const auto duration = music.player.state["duration"].toDouble();
        if (duration > 0) {
            music.player.seek(qBound(0.0, position / duration, 1.0));
        }
    } else {
        hud.action("player:" + action);
    }
}

void NativeApplication::pointer(QString type, double x, double y) {
    // 一次按压从 HUD 开始就始终归 HUD，避免列表拖动穿透成场景的横向换列。
    if (type == "pointerdown") {
        m_hudPointerSequence = false;
        if (hud.compactLayout() && !hud.frame["viewer"].toBool()) {
            const double listTop = hud.state()["archiveListY"].toDouble();
            m_hudPointerSequence = listTop > 0 && y >= listTop;
            for (const auto &value : hud.hits) {
                const auto hit = value.toObject();
                const QRectF rect(hit["x"].toDouble(), hit["y"].toDouble(), hit["width"].toDouble(),
                                  hit["height"].toDouble());
                if (rect.contains(x, y)) {
                    m_hudPointerSequence = true;
                    break;
                }
            }
        }
    }
    if (m_hudPointerSequence) {
        m_dragging = false;
        m_moved = false;
        m_scene->pointer("pointercancel", 0, 0);
        if (type == "pointerup" || type == "pointercancel" || type == "pointerleave") {
            m_hudPointerSequence = false;
        }
        return;
    }
    // 窄屏阅读页面覆盖整个场景；资料库主界面仍可在列表以外拖动真实场景。
    if (hud.compactLayout() && !hud.frame["viewer"].toBool()) {
        const auto region = hud.state()["playerBounds"].toObject();
        if (!hud.modal.isEmpty() || hud.frame["mode"] == "detail" ||
            (!region.isEmpty() && y >= region["y"].toDouble())) {
            m_dragging = false;
            m_moved = false;
            m_scene->pointer("pointercancel", 0, 0);
            return;
        }
    }
    // "pan"（双指平移）的 x/y 是位移增量而不是指针位置，绝不能拿去做播放栏/弹窗
    // 的命中判定——增量值恰好落进播放栏矩形时平移会被误判吞掉。viewer 打开时
    // NativeScene::pointer 会把它直接转发给 NativeViewer。
    const bool positional = type != "pan";
    // 播放栏覆盖场景；在原生分发边界也隔离留白，防止后端调用穿透或残留拖动。
    if (positional && hud.playerBounds && hud.playerBounds->contains(x, y)) {
        m_dragging = false;
        m_moved = false;
        m_scene->pointer("pointercancel", 0, 0);
        m_scene->pointer("pointerleave", 0, 0);
        return;
    }
    if (positional && !hud.modal.isEmpty()) {
        // 弹窗外只接受完整点击，拖动、取消和面板内部留白都不触发返回。
        if (type == "pointerdown") {
            m_dragging = true;
            m_down = {x, y};
            m_moved = false;
        } else if (type == "pointermove" && m_dragging && std::hypot(x - m_down.x(), y - m_down.y()) > 6) {
            m_moved = true;
        } else if (type == "pointerup") {
            const auto bounds = hud.modalBounds(hud.width).translated(0, hud.motion.offset);
            const bool isClick = !m_moved && std::hypot(x - m_down.x(), y - m_down.y()) <= 6;
            if (m_dragging && isClick && !bounds.contains(m_down) && !bounds.contains(x, y) && !hud.closing) {
                hud.closeModal();
            }
            m_dragging = false;
        } else if (type == "pointercancel" || type == "pointerleave") {
            m_dragging = false;
        }
        return;
    }
    if (type == "pointerdown") {
        m_dragging = true;
        m_down = {x, y};
        m_moved = false;
    }
    if (type == "pointermove" && m_dragging && std::hypot(x - m_down.x(), y - m_down.y()) > 6) {
        m_moved = true;
    }
    if (type == "pointerup" && m_dragging) {
        const auto picked = m_scene->pick(x, y);
        m_scene->pointer(type, x, y);
        m_dragging = false;
        const bool isClick = !m_moved && std::hypot(x - m_down.x(), y - m_down.y()) <= 6;
        if (isClick && !hud.frame["viewer"].toBool() && hud.frame["mode"] == "detail") {
            const auto bounds = hud.detailBounds(hud.width);
            const bool isInspectingSong =
                music.current.value("kind") == "song" && picked && m_scene->isSelectedCell(*picked);
            // 详情卡片外的完整点击复用返回路径；封面检查和拖动继续交给场景。
            if (!bounds.contains(m_down) && !bounds.contains(x, y) && !isInspectingSong) {
                hud.action("back");
            }
        } else if (isClick && hud.frame["mode"] == "archive" && picked) {
            music.observe(m_scene->selection());
            if (!music.current.isEmpty() && music.current.value("kind") != "song") {
                music.enterDirectory(music.current);
            }
        }
        return;
    }
    m_scene->pointer(type, x, y);
}
