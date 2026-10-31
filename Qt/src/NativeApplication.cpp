#include <QtGlobal>
#include "NativeApplication.h"
#include "render/HotPathProbe.h"
#include "AppStorage.h"
#include <QFile>
#include <QJsonDocument>
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

/** 建立原生音乐、HUD、场景的值接口；所有异步失效统一唤醒 Qt 帧调度。 */
NativeApplication::NativeApplication(Host *host, Glyphs *glyphs, NativeScene *scene, QJsonObject content,
                                     QObject *parent)
    : QObject(parent), music(host, content), hud(host, glyphs, &music, sceneActions(scene)), m_host(host),
      m_scene(scene) {
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
}
#ifdef Q_OS_LINUX
// RHINE_STEP_PROBE=1：拆开 app->step 内部（场景采样 / HUD 绘制 / 观察与返回对象构建）。
static double nacSampleSum = 0, nacObserveSum = 0, nacDrawSum = 0, nacRestSum = 0;
static double nacSampleMax = 0, nacObserveMax = 0, nacDrawMax = 0, nacRestMax = 0;
static int nacFrames = 0;

#endif
QJsonObject NativeApplication::step(double time, double width, bool reuseScene) {
#ifdef Q_OS_LINUX
    const bool nacProbe = qEnvironmentVariableIntValue("RHINE_STEP_PROBE") == 1;
    QElapsedTimer nacTimer;
    if (nacProbe) {
        nacTimer.start();
    }
#endif
    const auto frame = reuseScene ? music.frame : m_scene->sample(time);
#ifdef Q_OS_LINUX
    const double nacSampleMs = nacProbe ? double(nacTimer.nsecsElapsed()) / 1e6 : 0.0;
#endif
    if (frame.isEmpty()) {
        return {};
    }
    music.frame = frame;
#ifdef Q_OS_LINUX
    QElapsedTimer nacObserveClock;
    if (nacProbe) {
        nacObserveClock.start();
    }
#endif
    music.observe(frame["selected"].toInt());
    if (hud.tab != "overview" && music.wantsSongDetails && frame["mode"] == "detail") {
        music.sameAlbum();
    }
#ifdef Q_OS_LINUX
    const double nacObserveEnd = nacProbe ? double(nacTimer.nsecsElapsed()) / 1e6 : 0.0;
    QElapsedTimer nacDrawClock;
    if (nacProbe) {
        nacDrawClock.start();
    }
#endif
    hud.draw(frame, width, time);
#ifdef Q_OS_LINUX
    const double nacDrawMs = nacProbe ? double(nacDrawClock.nsecsElapsed()) / 1e6 : 0.0;
    const double nacDrawEnd = nacProbe ? double(nacTimer.nsecsElapsed()) / 1e6 : 0.0;
    RhineRender::hotPathWindow().frames.fetch_add(1);

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
            qInfo().noquote()
                << QStringLiteral("app->step 内部: 场景采样 %1/峰%2 ms | 观察+专辑 %3/峰%4 ms | "
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
    if (action == "resume" || action == "pause") {
        music.player.setPaused(action == "pause");
    } else {
        hud.action("player:" + action);
    }
}

void NativeApplication::pointer(QString type, double x, double y) {
    // 播放栏覆盖场景；在原生分发边界也隔离留白，防止后端调用穿透或残留拖动。
    if (hud.playerBounds && hud.playerBounds->contains(x, y)) {
        m_dragging = false;
        m_moved = false;
        m_scene->pointer("pointercancel", 0, 0);
        m_scene->pointer("pointerleave", 0, 0);
        return;
    }
    if (!hud.modal.isEmpty()) {
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
