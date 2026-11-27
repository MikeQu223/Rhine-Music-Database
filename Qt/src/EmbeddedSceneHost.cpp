#include "EmbeddedSceneHost.h"

#include "Engine.h"
#include "FrameProfiler.h"
#include "NativeScene.h"

#include <QCoreApplication>
#include <QDebug>
#include <QGuiApplication>
#include <QThread>
#include <QMutexLocker>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickView>
#include <QQuickWindow>
#include <QDateTime>
#include <QTimer>
#include <algorithm>
#include <cmath>
#include <limits>
#include <QStringList>

#if defined(Q_OS_ANDROID)
#include <QJniEnvironment>
#include <QJniObject>
#include <QPointer>
#include <QtCore/qcoreapplication.h>
#include <jni.h>
#endif

namespace {
Engine *g_engine = nullptr;
FrameProfiler *g_profiler = nullptr;
QString g_fontFamily = QStringLiteral("sans-serif");

// 连续归档滚动（Qt → Flutter 方向）。
//
// Qt 的 NativeScene 持有几何与惯性，这里只把轨道条目位置的增量报给 Flutter，
// 由 Flutter 的 listPosition 当窗口真值再投影回来。三类回执：start / move / commit。
//
// origin 在起手时捕获，ticker 每帧只读它；到 move 再读全局 origin 会把 A 的惯性贴成 B。
RhineEmbedded::ScrollGesture g_gesture;
QTimer *g_scrollTicker = nullptr;
// 反回声：刚由我们报出去的位置，Flutter 会原样投影回来。若把它当外部指令再落到轨道上，
// 就等于每帧把速度清零——3D 惯性会被自己的回声吃掉。一行/600ms 内一律忽略。
double g_emittedItem = std::numeric_limits<double>::quiet_NaN();
qint64 g_emittedAtMs = 0;
// 列表窗口最后一次真的位移的时刻。149 的 projectEmbeddedCells 要一个诚实的
// "rolling" 标记：Dart 自己拖列表时没有原生手势，但窗口确实在动，这个时刻就是那个
// 证据（不是每帧都算动，450ms 内没有新位移就当停了）。
qint64 g_listMovedAtMs = 0;
double g_appliedPos = std::numeric_limits<double>::quiet_NaN();
int g_appliedLane = -1;
QJsonArray g_cellSemantics;
// 手势期间被压下的选中：不能丢（Dart 侧快照去重不会重发），commit 之后补一次。
int g_pendingIndex = -1;
// 语义表的 (lane,row) -> {kind,id} 索引，供点选回传正确身份（ 的消费者）。
QHash<int, QPair<QString, QString>> g_cellIdentity;
int g_windowSlot = -1;

// ── 画面来源（origin）───────────────────────────────────────────────────────
// 产出当前画面的平台视图与其交互上下文代次。Dart 侧每份快照带 (viewId, ctx)，随快照
// **按值**穿过 Kotlin → RhineQtViews.pushSceneState → 队列 lambda → 应用点；这里不再有
// "当前 origin" 这种可以被 JNI 线程抢先写坏的全局。
//
// 判据全部在 EmbeddedSceneOrigin.h 里（纯 QtCore，测试与宿主共用同一份）。
RhineEmbedded::OriginLedger g_originLedger;
// 场景世代：Java 侧每次 create 请求带一个单调号，destroy 只允许拆自己那一代。
RhineEmbedded::SceneEpoch g_sceneEpoch;
} // namespace

namespace RhineEmbedded {

void publish(Engine *engine, FrameProfiler *profiler, const QString &fontFamily)
{
    g_engine = engine;
    g_profiler = profiler;
    g_fontFamily = fontFamily;
}

Engine *engine()
{
    return g_engine;
}

FrameProfiler *profiler()
{
    return g_profiler;
}

QString fontFamily()
{
    return g_fontFamily;
}

OriginLedger &originLedger()
{
    return g_originLedger;
}

SceneEpoch &sceneEpoch()
{
    return g_sceneEpoch;
}

namespace {
// 最近一份来自 Flutter 的快照。平台视图可能在 qApp 建好之前就发首帧（QtThread 是异步
// 起的），那时 invokeMethod 会被静默丢掉；而 Dart 侧按 viewId 去重，同一份快照不会再发。
// 所以这里留一份，等场景真正就绪（createSceneView 末尾）再自应用一次。
QMutex g_pendingMutex;
QString g_pendingState;
// 这份待应用快照的产出者。补应用时用的是**它**，不是补应用那一刻的"当前是谁"：
// 首帧快照来自哪个视图/哪一代上下文，是它自己的属性。
ProducerOrigin g_pendingOrigin;
QString g_appliedMode;
int g_appliedIndex = -2;
int g_appliedDark = -1;
QString g_appliedKey;
// 最近一次应用的渲染设置（Flutter 是唯一真值）：值不变就一个字节都不写，
// 否则每次快照都会重写一遍 QSettings 并把 NativeHud 的字段重新赋值。
QJsonObject g_appliedSettings;
// 最近一次执行的封面查看器命令序号（Flutter 快照里的 coverViewer.seq）。
// 查看器命令不是偏好、不能落盘，但必须去重：同一份快照会被补应用一次
// （reapplyPendingState），没有这道闸就会开两次/关两次。
int g_appliedViewerSeq = -1;
} // namespace

void rememberState(const QString &json, const ProducerOrigin &origin)
{
    QMutexLocker lock(&g_pendingMutex);
    g_pendingState = json;
    g_pendingOrigin = origin;
}

bool reapplyPendingState()
{
    QString pending;
    ProducerOrigin origin;
    {
        QMutexLocker lock(&g_pendingMutex);
        pending = g_pendingState;
        origin = g_pendingOrigin;
    }
    if (pending.isEmpty())
        return false;
    // 带着快照自己的 origin 补应用（旧代码这里没有 origin，补应用后账本停在"未登记"，
    // 之后所有输入都 fail-open——首帧路径上最危险的那个洞）。
    applySceneState(pending, origin);
    return true;
}

namespace {
// 封面投影：Flutter 快照里的「当前选中」身份。空串 = 没有选中（要清旧图）。
QString g_projectedCover;
QJsonObject g_projectedCurrent;
}

QString projectedCover()
{
    return g_projectedCover;
}

QJsonObject projectedCurrent()
{
    return g_projectedCurrent;
}

void resetAppliedState(quint64 sceneEpochToken)
{
    // 只允许拆自己那一代场景：旧 host（上一轮 Activity / 已被 detached 的 RhineQtView）
    // 的 destroy 如果晚到，它会把新 host 刚应用的 origin 抹掉，之后新 host 的所有输入
    // 都被判成"旧视图"而丢弃——旧代码靠"未登记 = 放行"掩盖了这个洞，代价是迟到输入
    // 全部 fail-open。这里改成世代比对 + fail-closed。
    if (!g_sceneEpoch.owns(sceneEpochToken)) {
        qInfo("RHINE_QT_SCENE_ORIGIN_STALE_DESTROY token=%llu current=%llu",
              static_cast<unsigned long long>(sceneEpochToken),
              static_cast<unsigned long long>(g_sceneEpoch.current()));
        return;
    }
    // 账本退回 Closed（不是"未登记 = 放行"）：下一份快照自己 commit 才能重新开门，
    // 而那个 commit 只发生在 Qt 线程上真的 apply 成功之后。
    g_originLedger.close();
    g_gesture.end(); // 拆场景时不再有惯性可跟：别让下一轮的 ticker 继承旧 origin。
    g_appliedMode.clear();
    g_appliedIndex = -2;
    g_appliedDark = -1;
    g_appliedKey.clear();
    g_projectedCover.clear();
    g_projectedCurrent = QJsonObject();
    g_appliedSettings = QJsonObject();
    g_appliedViewerSeq = -1;
}

// pointerdown 时只清选中相关：Qt 自己的 NativeSceneInput 可能在这一轮里改了选中，之后
// Flutter 若推来同一份快照必须允许它重新应用，否则高亮与选中会长期漂移。
// 刻意不动 g_appliedMode/g_appliedDark——清掉它们会让下一份快照重跑 setMode()/theme()，
// 而这两个调用都会 reset 指针与动画，等于在手指还按着的瞬间把场景跳一下。
void resetSelectionState()
{
    g_appliedIndex = -2;
    g_appliedKey.clear();
}

// Qt → Dart 的动作出口（沿用已有的 RhineQtViews.emitSceneAction → MethodChannel）。
//
// origin 是**这份动作的产出者**（逐调用点传进来的值），不是"出口时刻当前是谁"：
// 旧代码在这里读全局 g_originViewId/g_originContext，排队中的 A 动作过门后就带上了
// B 的标签，Dart/Kotlin 按新标签收下 —— 这是"贴错标签"缺陷的直接来源。
void emitSceneAction(const QString &action, const ProducerOrigin &origin)
{
#if defined(Q_OS_ANDROID)
    QJniEnvironment env;
    if (!env.isValid())
        return;
    // findClass() 返回全局引用，对它 DeleteLocalRef 会让 ART 直接 abort。
    jclass viewClass = env.findClass("org/qtproject/qt/android/RhineQtViews");
    if (!viewClass)
        return;
    // 动作带着**生产者 origin** 出去：Kotlin/Dart 都要能用它拒掉"已经换页/换目录的旧视图"
    // 产生的迟到动作。未登记时传 (-1, 0)；Kotlin 侧对未登记/已 retired 的来源一律
    // fail-closed（见 QtSceneChannel.dispatchAction）。
    jmethodID method =
        env->GetStaticMethodID(viewClass, "emitSceneAction", "(IJLjava/lang/String;)V");
    if (method) {
        QJniObject argument = QJniObject::fromString(action);
        env->CallStaticVoidMethod(viewClass, method, static_cast<jint>(origin.viewId),
                                  static_cast<jlong>(origin.context), argument.object<jstring>());
        if (env->ExceptionCheck()) {
            env->ExceptionClear();
            qWarning("RHINE_QT_SCENE_ACTION threw");
        }
    }
#else
    Q_UNUSED(action);
    Q_UNUSED(origin);
#endif
}

void emitScroll(const char *phase, double delta, const ProducerOrigin &origin)
{
    // **先判 origin，再碰回声标记**（审查 M2 site 3）：一条会被 Kotlin/Dart 拒掉的旧动作
    // 不许改 g_emittedItem/g_emittedAtMs —— 那会让下一份合法快照被误判成"自己的回声"而
    // 丢掉投影（origin 只带在事件上，挡不住这类原生副作用）。
    const OriginVerdict verdict = g_originLedger.evaluate(origin);
    if (!originAccepted(verdict)) {
        qInfo("RHINE_QT_SCENE_ORIGIN_DROP scroll phase=%s %s reason=%s applied=%s", phase,
              qPrintable(describeOrigin(origin)), originVerdictName(verdict),
              qPrintable(describeOrigin(g_originLedger.applied())));
        return;
    }
    g_emittedItem = g_gesture.base + delta;
    g_emittedAtMs = QDateTime::currentMSecsSinceEpoch();
    emitSceneAction(QStringLiteral("archive-scroll:%1:%2")
                        .arg(QString::fromLatin1(phase))
                        .arg(delta, 0, 'f', 3),
                    origin);
}

void scrollTick();

// 选中条目落在 8 个物理行里的哪一行：槽位 = round(pos) % 8，与 Dart 侧基址一致；
// 绝对场景行 = 12 + item（cellPosition 与投影同一坐标系）。用 `12 + pos%8` 会把 actor
// 钉在 8 行窗口里。
int absoluteRowFor(double pos)
{
    if (!std::isfinite(pos))
        return 12;
    return 12 + static_cast<int>(std::llround(pos));
}

// 手势期间压下的选中在提交后补一次（tap 与 ticker 两条路径共用）。
void flushPendingSelection(Engine *engine)
{
    if (!engine || g_pendingIndex < 0 || g_appliedLane < 0)
        return;
    const int pending = g_pendingIndex;
    g_pendingIndex = -1;
    // 行用 pending 自己的条目号：g_appliedPos 在手势期间会比选中晚几行（回声滞后），
    // 用它摆 actor 会偏几行。
    engine->scene.select(pending,
                         QJsonObject{{QStringLiteral("cell"),
                                      QJsonObject{{QStringLiteral("lane"), g_appliedLane},
                                                  {QStringLiteral("row"), 12 + pending}}}});
}

void startScrollTicker(double reference)
{
    if (!qApp)
        return;
    // 手指抬起 → 阶段 1 交给阶段 2（ticker 跟惯性）。reference 用抬手这一帧的位置，
    // 否则第一帧会因为和拖动末帧比较而立刻算成"没动"（少报一帧惯性）。
    g_gesture.handOffToInertia(reference);
    if (!g_scrollTicker) {
        g_scrollTicker = new QTimer(qApp);
        g_scrollTicker->setInterval(33);
        QObject::connect(g_scrollTicker, &QTimer::timeout, qApp, [] { scrollTick(); });
    }
    g_scrollTicker->start();
}

// 松手之后的惯性也继续推动列表：每帧读 Qt 的轨道位置，停止变化 3 帧才 commit。
// 判定本身在 RhineEmbedded::advanceScroll()（纯函数，离线测试驱动同一份语义）；
// 这里只负责"把结论发出去"。发出去的 origin 是手势起手时捕获的那份。
void scrollTick()
{
    // ticker 只服务惯性阶段（审查 M1）：新手势按下时 ticker 已 stop()，但排队中的 timeout
    // 仍可能进来一帧——那时 g_gesture 属于一段**按住**的手势，绝不能由这里推进或收尾。
    if (!g_gesture.inertia()) {
        if (g_scrollTicker)
            g_scrollTicker->stop();
        return;
    }
    Engine *engine = g_engine;
    if (!engine) {
        if (g_scrollTicker)
            g_scrollTicker->stop();
        g_gesture.end();
        return;
    }
    const double item = engine->scene.archiveTrackItem();
    const ScrollStep step = advanceScroll(g_gesture, item);
    switch (step.kind) {
    case ScrollStepKind::None:
        return;
    case ScrollStepKind::Move:
        emitScroll("move", step.delta, step.origin);
        return;
    case ScrollStepKind::Commit:
        break;
    }
    if (g_scrollTicker)
        g_scrollTicker->stop();
    emitScroll("commit", step.delta, step.origin);
    // 手势期间压下的选中在这里补应用：否则列表显示 A、3D 高亮停在 B。
    flushPendingSelection(engine);
}

// 自己刚报出去的位置回来了吗？（见 g_emittedItem 的说明）
bool scrollEcho(double item)
{
    if (std::isnan(g_emittedItem))
        return false;
    if (QDateTime::currentMSecsSinceEpoch() - g_emittedAtMs > 600)
        return false;
    return std::abs(item - g_emittedItem) < 1.0;
}

void applySceneState(const QString &json, const ProducerOrigin &origin)
{
    Engine *engine = g_engine;
    if (!engine) {
        // 还没 publish()/场景还没建：payload 已在 rememberState() 落盘，由
        // createSceneView() 末尾的 reapplyPendingState() 补上。别删那段 replay，
        // 否则首帧快照会重新变成静默丢失。
        qWarning("RHINE_QT_SCENE_STATE ignored: no engine");
        return;
    }
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(json.toUtf8(), &error);
    if (error.error != QJsonParseError::NoError || !document.isObject()) {
        qWarning().noquote() << "RHINE_QT_SCENE_STATE bad json:" << error.errorString();
        return;
    }
    const QJsonObject payload = document.object();
    NativeScene &scene = engine->scene;

    // 逐项比对再应用：Qt 侧 setMode/select 都会 reset 指针与动画，重复应用会把正在
    // 进行的拖拽/旋转打断——这也是"手指还在屏幕上场景却跳一下"的来源。
    // 去重状态是命名空间级的（g_applied*），因为 destroySceneView() 要能清它。
    bool applied = false;

    const QString mode = payload.value("mode").toString();
    if (!mode.isEmpty() && mode != g_appliedMode) {
        g_appliedMode = mode;
        scene.setMode(mode);
        applied = true;
    }

    const bool dark = payload.value("dark").toBool(false);
    if (int(dark) != g_appliedDark) {
        g_appliedDark = int(dark);
        scene.theme(dark);
        applied = true;
    }

    // index 是 Flutter 列表行号，Qt 用 fileLocation(index) 落到本列真实行；>39 不取模映射。
    // 手势进行中的 index/pos 是拖动回声，回灌会打断捕获；松手 commit 之后才是权威位置。
    // 「换人」才退休旧手势：换视图，或同一视图的交互代次变了。
    // 普通滚动帧不在此列，必须保住合法的拖动与惯性。
    const ApplyGesturePlan plan = planApply(g_gesture, g_originLedger, origin);
    if (plan.retireGesture) {
        if (g_scrollTicker)
            g_scrollTicker->stop();
        // 上一轮压下的选中属于旧集合，不许落到 B 的选中上（flushPendingSelection 会读
        // B 的 g_appliedLane）。
        g_pendingIndex = -1;
        // 回声标记属于旧序列：留着会让 B 第一份权威快照被误判成"自己的回声"。
        g_emittedItem = std::numeric_limits<double>::quiet_NaN();
        g_emittedAtMs = 0;
        g_listMovedAtMs = 0;
        // "已应用"的基准也属于旧集合：不失效的话，B 与旧集合行号相同的 index 会被当成
        // "没有变化"跳过 select（顺带也丢掉了 select 内部唯一现成的 resetPointer ——
        // 打断旧捕获的路），相同的 pos 也会被 lane 判等吞掉，新集合的位置与选中就永远
        // 落不了地。cells/settings 自带内容比较，不必清。
        g_appliedIndex = -2;
        g_appliedLane = -1;
        qInfo("RHINE_QT_SCENE_GESTURE_RETIRED kind=%s %s previous=%s", applyKindName(plan.kind),
              qPrintable(describeOrigin(origin)),
              qPrintable(describeOrigin(g_originLedger.applied())));
    }
    const bool gestureDriving = plan.gestureDriving;
    const int index = payload.value("index").toInt(-1);
    const double indexPos = payload.value("pos").toDouble(0.0);
    const int indexLane = payload.value("lane").toInt(g_appliedLane < 0 ? 2 : g_appliedLane);
    if (index >= 0 && index != g_appliedIndex) {
        if (gestureDriving) {
            // 手势期间不 select（!m_navigating 会 resetPointer 打断捕获），但也不能丢：
            // 记成 pending，commit 之后由 scrollTick 补一次。
            g_appliedIndex = index;
            g_pendingIndex = index;
        } else {
            g_appliedIndex = index;
            g_pendingIndex = -1;
            // 显式几何槽位：index 是 Flutter 的列表行号，不再是 slots.json 的占位记录号。
            // 物理行由连续窗口真值 pos 决定（(round(pos)/8)*8 的基址 + pos%8），
            // 交给 NativeScene 的 navigation["cell"] 分支直接用，绕开 fileLocation 的
            // 占位域与 nearest 夹取（第 18 行/第 936 行都必须落在本列真实行）。
            scene.select(index,
                         QJsonObject{{QStringLiteral("cell"),
                                      QJsonObject{{QStringLiteral("lane"), indexLane},
                                                  {QStringLiteral("row"), absoluteRowFor(indexPos)}}}});
            applied = true;
        }
    }

    // 连续窗口投影（列表 → 3D）：拖动中途也会来，所以这里不做"松手才动"的判断。
    // 回声（我们刚报出去的同一个位置）不回灌，否则 3D 惯性的速度每帧被清零。
    const double pos = payload.value("pos").toDouble(0.0);
    const int lane = payload.value("lane").toInt(g_appliedLane < 0 ? 2 : g_appliedLane);
    if (!std::isnan(pos) && (std::abs(pos - g_appliedPos) > 1e-4 || lane != g_appliedLane)) {
        g_appliedPos = pos;
        g_appliedLane = lane;
        // "窗口在动"的诚实证据（见 g_listMovedAtMs）：真正位移了才更新，不是每份快照都算。
        g_listMovedAtMs = QDateTime::currentMSecsSinceEpoch();
        // 只在档案页投影：详情/歌词页的镜头由 setMode 自己的过渡管，外部窗口不该插手。
        if (scene.mode() == QLatin1String("archive") && !scrollEcho(pos) && !gestureDriving) {
            scene.projectArchiveScroll(pos, lane);
            applied = true;
        }
        // 有界诊断（只在 pos/lane 变化时打印）：打出轨道的绝对行与 archiveTrackItem 真值。
        // rail 可由 track 反解，不必另开日志；停手后看 track 是否守住即可判断回弹。
        const int row = absoluteRowFor(pos);
        if (row != g_windowSlot) {
            g_windowSlot = row;
            qInfo("RHINE_QT_SCENE_WINDOW lane=%d pos=%.3f row=%d track=%.3f index=%d cells=%d",
                  lane, pos, row, scene.archiveTrackItem(), index, int(g_cellSemantics.size()));
        }
    }

    // 40 格语义槽位（5 列 × 8 物理行）：只存身份表，几何仍然由 NativeScene 自己算。
    const QJsonArray cells = payload.value("cells").toArray();
    if (cells != g_cellSemantics) {
        g_cellSemantics = cells;
        // 语义表必须有消费者：这里建 (lane,row) -> (kind,id) 索引，点选回传时带上
        // 真实身份（不是 40 格位置冒充 identity）。行键统一成物理行 12+row。
        g_cellIdentity.clear();
        for (const auto &value : cells) {
            const QJsonObject cell = value.toObject();
            const QString kind = cell.value("k").toString();
            const QString id = cell.value("i").toString();
            if (kind.isEmpty() || id.isEmpty())
                continue;
            // 行键是绝对行偏移（0..~948），8 位不够：改成 lane<<16 | (12+r)。
            const int key = (cell.value("l").toInt() << 16) | (12 + cell.value("r").toInt());
            g_cellIdentity.insert(key, qMakePair(kind, id));
        }
        qInfo("RHINE_QT_SCENE_CELLS n=%d lane=%d pos=%.3f", int(cells.size()), lane, pos);
        applied = true;
    }

    // 设置面板的真值（Flutter 的 BasicSettingsRuntime 是唯一真值）→ Qt。
    //
    // 两条路必须都走，否则就是假开关：
    //  * 能当场生效的（唱片旋转、右侧画面遮罩）写 NativeHud 的字段：Engine::step()
    //    每帧读 hud.discRotation（Engine.cpp:1296）与 hud.archiveMaskStrength，不用重启；
    //  * 渲染分辨率/抗锯齿/超采样/MSAA 既写 QSettings 的 panel/<key>（下次进程启动的基线），
    //    也当场 qputenv：渲染器每帧读环境变量，下一帧就按新尺寸/采样数重建目标，不用重启。
    //  * 图形后端与垂直同步只能在启动时决定，只写 QSettings：Qt/src/main.cpp:680(panel/graphics-
    //    backend)、:725(panel/vsync) 下次进程启动读的是同一份文件。
    //    Flutter 自己落的是另一个 SharedPreferences 文件（rhine_basic_settings），Qt 读不到，
    //    所以这一步不是重复：它是"下次进程启动真的是新设置"的唯一凭据。
    const QJsonObject settings = payload.value("settings").toObject();
    if (!settings.isEmpty() && settings != g_appliedSettings) {
        g_appliedSettings = settings;
        const bool disc = settings.value("disc").toBool(false);
        const int mask = qBound(0, settings.value("mask").toInt(55), 100);
        if (NativeApplication *application = engine->app.get()) {
            // 立即生效：Engine::step() 每帧都从这里读，不需要重建场景。
            application->hud.discRotation = disc;
            application->hud.archiveMaskStrength = mask;
        }
        engine->host.setPreference(QStringLiteral("disc-rotation"),
                                   disc ? QStringLiteral("on") : QStringLiteral("off"));
        engine->host.setPreference(QStringLiteral("archive-mask-strength"), QString::number(mask));
        // 仅下次启动生效的项：原样落进 Qt 的 QSettings（值就是 Dart 侧选的那个词）。
        const auto writeNextLaunch = [&](const char *key, const char *preference) {
            if (!settings.contains(QLatin1String(key)))
                return;
            const QString text = settings.value(QLatin1String(key)).toVariant().toString();
            if (!text.isEmpty())
                engine->host.setPreference(QLatin1String(preference), text);
        };
        writeNextLaunch("vsync", "vsync");
        writeNextLaunch("renderScale", "render-scale");
        writeNextLaunch("backend", "graphics-backend");
        writeNextLaunch("aa", "aa-mode");
        writeNextLaunch("aaScale", "aa-scale");
        writeNextLaunch("msaa", "msaa");
        writeNextLaunch("supersample", "supersample");
        // 立即生效的项：桌面端 NativeHudController 选完就 qputenv，渲染器每帧读环境变量
        // （RhiScene::resize 会按新尺寸/采样数重建目标，不需要重启）。Android 内嵌路径原来
        // 只写偏好：唯一把偏好翻成环境变量的 applyRenderScaleSetting() 在 main() 里，一个
        // 进程只跑一次，而 Qt 运行时跨 Activity 常驻，所以改完永远不会生效。这里补上与
        // 桌面一致的即时应用；graphics-backend / vsync 仍只能下次进程启动生效。
        const auto liveScaledPercent = [&](const char *key, const char *envName, int low, int high) {
            if (!settings.contains(QLatin1String(key)))
                return;
            bool valid = false;
            const int value = settings.value(QLatin1String(key)).toVariant().toInt(&valid);
            if (!valid || value <= 0)
                return;
            qputenv(envName, QByteArray::number(std::clamp(value, low, high)));
        };
        // 上限跟随 main 抬到 200%（RhineRender::MaximumRenderPercent，桌面 NativeHudController
        // 同样 std::clamp(percent, 50, 200)）：这里若还夹在 100，选 125/150/200 会被静默压回 100。
        liveScaledPercent("renderScale", "RHINE_RENDER_SCALE", 50, 200);
        liveScaledPercent("aaScale", "RHINE_AA_SCALE", 100, 200);
        if (settings.contains(QLatin1String("aa"))) {
            // FSR 档位按用户 m03406 暂缓，这里只接受非 FSR 的抗锯齿模式。
            const QString mode = settings.value(QLatin1String("aa")).toVariant().toString();
            static const QStringList kLiveAaModes{"off", "fxaa", "ssaa", "msaa", "taa"};
            if (kLiveAaModes.contains(mode))
                qputenv("RHINE_AA_MODE", mode.toUtf8());
        }
        if (settings.contains(QLatin1String("msaa"))) {
            const int samples = settings.value(QLatin1String("msaa")).toVariant().toInt();
            if (samples == 2 || samples == 4 || samples == 8)
                qputenv("RHINE_MSAA", QByteArray::number(samples));
        }
        if (settings.contains(QLatin1String("supersample"))) {
            const int sample = settings.value(QLatin1String("supersample")).toVariant().toInt();
            if (sample > 1)
                qputenv("RHINE_SUPERSAMPLE", QByteArray::number(qMin(sample, 2)));
            else
                qunsetenv("RHINE_SUPERSAMPLE");
        }
        // FSR 档位/锐化：用户 m03406 暂缓，本阶段不接。快照里即使出现 fsrQuality /
        // fsrSharpness 也不写偏好、不 qputenv，渲染器继续走 ScenePostProcess.cpp
        // 自己的缺省（未知档位=1.0 倍，锐化 50）。
        // 这行同时打出「渲染器实际会读到的环境变量」，现场用它确认即时应用真的落下去了。
        const QByteArray liveScale = qgetenv("RHINE_RENDER_SCALE");
        const QByteArray liveAa = qgetenv("RHINE_AA_MODE");
        const QByteArray liveMsaa = qgetenv("RHINE_MSAA");
        const QByteArray liveSupersample = qgetenv("RHINE_SUPERSAMPLE");
        qInfo("RHINE_QT_SCENE_SETTINGS disc=%d mask=%d vsync=%s scale=%d backend=%s aa=%s/%d msaa=%d ss=%d "
              "live(scale=%s aa=%s msaa=%s ss=%s)",
              int(disc), mask, qPrintable(settings.value("vsync").toString()),
              settings.value("renderScale").toInt(75), qPrintable(settings.value("backend").toString()),
              qPrintable(settings.value("aa").toString()), settings.value("aaScale").toInt(125),
              settings.value("msaa").toInt(0), settings.value("supersample").toInt(1),
              liveScale.constData(), liveAa.constData(), liveMsaa.constData(), liveSupersample.constData());
        applied = true;
    }

    // 封面查看器（Qt NativeViewer）命令：打开/关闭/清晰/磨砂/复位/封面正面。
    //
    // Flutter 的 HUD 是唯一交互面，Qt 内嵌时没有自己的命中层可点，而 Flutter→Qt 只有
    // state/pointer/wheel 三条方法（QtSceneChannel.kt:123-170），所以这些动作只能贴着
    // 快照下发。这里按 seq 单调去重；动作本身交给 NativeScene 的既有入口
    // （NativeSceneInput.cpp:241-257 openViewer/coverFront/viewerAction → NativeViewer），
    // Qt 侧的查看器状态仍是唯一真值，本函数不保存第二份。
    const QJsonObject coverViewer = payload.value("coverViewer").toObject();
    if (!coverViewer.isEmpty()) {
        const int viewerSeq = coverViewer.value("seq").toInt(-1);
        if (viewerSeq != g_appliedViewerSeq) {
            g_appliedViewerSeq = viewerSeq;
            const QString viewerAction = coverViewer.value("action").toString();
            if (viewerAction == QLatin1String("open")) {
                scene.openViewer();
            } else if (viewerAction == QLatin1String("cover-front")) {
                scene.coverFront(true);
            } else if (!viewerAction.isEmpty()) {
                scene.viewerAction(viewerAction);
            }
            qInfo("RHINE_QT_SCENE_COVER_VIEWER seq=%d action=%s", viewerSeq,
                  qPrintable(viewerAction));
            applied = true;
        }
    }

    // 封面身份投影（ / 决策：URL 优先，选中身份不是播放身份）。
    // 快照带 cover 就用 cover；没有 cover 键或键为空一律清空——不能留着上一首的图。
    // 这里只**记录**，真正的下载在 Engine 的异步路径里（Host::loadCover 回调返回的
    // cache key 才是 host.image() 能命中的那个键）。
    const QJsonObject current = payload.value("current").toObject();
    const QString cover = current.value("cover").toString();
    const bool coverChanged = cover != g_projectedCover;
    if (coverChanged) {
        g_projectedCover = cover;
        // 有界诊断（只在这一字段真的变化时打印一次），用于设备侧证明封面 URL 是否到了
        // Qt 侧：URL 本身不是凭据，只截断到 96 字符。
        qInfo("RHINE_QT_SCENE_COVER len=%d url=%.96s", int(cover.size()), qPrintable(cover));
        // 快照落地即预取：不能等 Engine::step()，那条路会被 pacing Skip/休眠整段跳过。
        engine->prefetchCover(cover);
    }
    if (current != g_projectedCurrent) {
        g_projectedCurrent = current;
    }

    if (payload.contains("key")) {
        const QString key = payload.value("key").toString();
        if (key != g_appliedKey) {
            g_appliedKey = key;
            if (key.isEmpty())
                scene.musicClear();
            else
                scene.musicIdentity(key);
            applied = true;
        }
    } else if (!g_appliedKey.isEmpty()) {
        // 没有选中就不带 key：清掉上一首的封面/材质身份，避免"打开一首歌的唱片
        // 再返回列表后列表还在显示那张封面"。
        g_appliedKey.clear();
        scene.musicClear();
        applied = true;
    }

    // 应用点：只有走到这里（Qt 线程上、这份 payload 已经落到场景）才改写"当前画面来源"。
    // 旧代码在 JNI 线程上先写全局 g_originViewId/g_originContext，队列里排着的上一份快照
    // 的输入/动作过门时读到的就是新 origin——A 的动作被贴上 B 的标签，这是缺陷的根。
    // 同一 view 换了集合上下文（ctx 递增）之后，旧代次的迟到输入会被判成 DropStaleContext。
    g_originLedger.commit(origin);

    // 149 的可见格资源接口：**一份快照一次**（不是每帧），在这里交给 Engine 去投影。
    //  - contextGeneration 必须"同一份窗口内容给同一个值"：给变了会重置准入计时、把已经
    //    热的封面打回冷态，惯性帧就永远拿不到热资源。取这份快照 origin 的交互代次。
    //  - scrolling 是"列表正在快速移动"的诚实标记：原生手势（拖动/惯性）在跑，或者
    //    Dart 刚推来一个新位置（450ms 内）。它只会**并进**原生轨道自身的滚动状态。
    // 两个值都来自这份快照自己的 origin 与本次手势，不读任何"当前是谁"的全局。
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    const bool rolling =
        g_gesture.active() || (g_listMovedAtMs != 0 && nowMs - g_listMovedAtMs <= 450);
    engine->projectEmbeddedCells(cells, collectionContextFor(origin), rolling);

    // 引擎休眠时 setMode 只改目标值、不跑过渡，应用后必须自己唤醒一帧。
    if (applied) {
        engine->wake(Engine::WakeSource::Input);
    }

    // 只在真的改变了场景时打（S3）：否则每次重连都刷一条全量快照，日志里分不清"收到"
    // 与"应用"。
    if (applied) {
        qInfo("RHINE_QT_SCENE_STATE v=%d mode=%s dark=%d index=%d count=%d key=%s",
              payload.value("v").toInt(0), qPrintable(g_appliedMode), g_appliedDark, index,
              payload.value("count").toInt(0), qPrintable(g_appliedKey));
        // 应用点序号 + 这份快照的 origin + 149 的投影规模：设备上证明"哪一份快照成了当前
        // 画面、它带的是谁的标签、投影了多少格"，一条就够（不每帧刷）。
        qInfo("RHINE_QT_SCENE_ORIGIN_APPLIED n=%llu %s cells=%d ctx=%llu rolling=%d",
              static_cast<unsigned long long>(g_originLedger.commits()),
              qPrintable(describeOrigin(origin)), engine->embeddedCellCount(),
              static_cast<unsigned long long>(collectionContextFor(origin)), int(rolling));
    }
}

} // namespace RhineEmbedded

#if defined(Q_OS_ANDROID)
namespace {
// 只保留最近一次创建的场景视图：重复挂载（PlatformView 重建）时先销毁旧的，
// 避免同一进程里堆出第二个场景/第二套事件循环。
QPointer<QQuickView> g_sceneView;

// sceneEpochToken：调用方以为自己在拆的那一代场景（Java 侧的 create 世代号）。
// 0 = 内部路径（createSceneView 里先拆旧再建新），无条件生效。
void destroySceneView(quint64 sceneEpochToken = 0)
{
    // 旧 host 的 destroy 不许拆新 host 的场景：世代对不上就整段跳过。
    // 反过来说，正因为这里可能整段跳过，resetAppliedState() 的"清账"也不能被当成
    // "新 host 一定会重新收到快照"——新 host 的快照在 createSceneView 末尾由
    // reapplyPendingState() 带着自己的 origin 补应用。
    if (!RhineEmbedded::sceneEpoch().owns(sceneEpochToken)) {
        qInfo("RHINE_QT_EMBEDDED_SCENE_DESTROY_SKIPPED token=%llu current=%llu",
              static_cast<unsigned long long>(sceneEpochToken),
              static_cast<unsigned long long>(RhineEmbedded::sceneEpoch().current()));
        return;
    }
    if (!g_sceneView)
        return; // 二次排队 destroy 在这里早退，也就跳过了下面的 resetAppliedState()；
                // 无害（第一次已经清过），但改动这里的顺序时要记得这条依赖。
    // 去重状态跟着场景一起清（S5）：同进程若重建 Engine（RhineQtViews 的 sRuntimeTornDown
    // 路径），残留的 applied* 会让新场景永远收不到快照。
    RhineEmbedded::resetAppliedState(sceneEpochToken);
    QQuickView *view = g_sceneView.data();
    g_sceneView.clear();
    // 先让内核停手再拆窗口：隐藏期间不创建 GPU 资源，也不再有 resize/setVisible 打到将死的窗口上。
    if (Engine *engine = RhineEmbedded::engine()) {
        engine->setVisible(false);
        engine->setWindow(nullptr);
    }
    view->hide();
    view->deleteLater();
    // 同步排空这一个窗口的 DeferredDelete：调用方返回后 Surface 可能被释放，
    // 窗口还活着会让渲染线程在已销毁的 mutex 上 present。
    QCoreApplication::sendPostedEvents(view, QEvent::DeferredDelete);
    qInfo("RHINE_QT_EMBEDDED_SCENE_DESTROYED");
}

void createSceneView(const QJniObject &javaView, jlong parentWindowReference, jint width, jint height,
                     quint64 sceneEpochToken)
{
    // 世代号先 adopt 再做事：即使下面因为父窗口为空早退，Java 侧这一代仍然持有"当前场景"
    // 的所有权，它之后的 destroy 才能合法地拆掉进程里现存的那个场景（一个进程只有一个）。
    RhineEmbedded::sceneEpoch().adopt(sceneEpochToken);
    auto *parentWindow = reinterpret_cast<QWindow *>(parentWindowReference);
    if (!parentWindow) {
        qWarning("RHINE_QT_EMBEDDED: null parent window");
        return;
    }
    destroySceneView();

    auto *view = new QQuickView(parentWindow);
    g_sceneView = view;
    view->setResizeMode(QQuickView::SizeRootObjectToView);
    view->setColor(QColor(Qt::transparent));
    view->setWidth(width);
    view->setHeight(height);
    // 尺寸变化（旋转/分屏/键盘）不重建图形设备和场景缓存，场景状态留在原处。
    view->setPersistentSceneGraph(true);
    view->setPersistentGraphics(true);

    QQmlEngine *engine = view->engine();
    engine->rootContext()->setContextProperty(QStringLiteral("rhineFontFamily"), RhineEmbedded::fontFamily());
    engine->rootContext()->setContextProperty(QStringLiteral("rhine"), RhineEmbedded::engine());
    // 性能面板不是用户要求的功能 —— 不再向 QML 暴露 profiler。
    // engine->rootContext()->setContextProperty(QStringLiteral("profiler"), RhineEmbedded::profiler());
    QObject::connect(engine, &QQmlEngine::quit, QCoreApplication::instance(), &QCoreApplication::quit);

    // Qt 自己的 QtQuickView 就是把子窗口的 Java QtWindow 交给 QtView.addQtWindow；
    // 这里沿用同一条路：把 winId()（QAndroidPlatformWindow 里就是 QtWindow jobject）
    // 连同视图指针和父窗口一起交给 Java 侧的 QtView。
    if (Engine *engine = RhineEmbedded::engine()) {
        engine->setWindow(view);
        view->installEventFilter(engine);
        // 拾取选中回传的通道已接好，但暂时不发动作：场景槽位是 slots.json 的 40 条占位
        // 记录，没有曲目身份，而曲库权威在 Flutter。发 "music:index:<i>" 是假映射。
        Q_UNUSED(engine);
    }
    // 性能面板停用：不再把 profiler 挂到内嵌场景窗口。

    QJniEnvironment env;
    jclass viewClass = env->GetObjectClass(javaView.object());
    jmethodID addQtWindow = env->GetMethodID(viewClass, "addQtWindow",
                                             "(Lorg/qtproject/qt/android/QtWindow;JJ)V");
    if (!addQtWindow) {
        qWarning("RHINE_QT_EMBEDDED: QtView.addQtWindow not found");
        env->DeleteLocalRef(viewClass);
        return;
    }
    env->CallVoidMethod(javaView.object(), addQtWindow, reinterpret_cast<jobject>(view->winId()),
                        static_cast<jlong>(reinterpret_cast<qintptr>(view)), parentWindowReference);
    env->DeleteLocalRef(viewClass);
    if (env->ExceptionCheck()) {
        env->ExceptionDescribe();
        env->ExceptionClear();
        qWarning("RHINE_QT_EMBEDDED: addQtWindow threw");
        return;
    }

    view->loadFromModule(QStringLiteral("RhineMusic"), QStringLiteral("Embedded"));
    if (view->status() == QQuickView::Error) {
        for (const auto &error : view->errors())
            qWarning().noquote() << "RHINE_QT_EMBEDDED qml:" << error.toString();
    } else if (Engine *engine = RhineEmbedded::engine()) {
        // Embedded.qml 的 Component.onCompleted 也会 setVisible(true)；这里再确认一次，
        // 免得视图被销毁重建后内核停在被上一次 destroySceneView 设成的隐藏状态。
        engine->setVisible(true);
    }
    qInfo("RHINE_QT_EMBEDDED_SCENE_READY %dx%d", int(width), int(height));
    // 场景就绪后补应用最后一份快照（M1：首帧可能早于 qApp，被 invokeMethod 丢掉）。
    if (RhineEmbedded::reapplyPendingState())
        qInfo("RHINE_QT_SCENE_STATE replayed on scene ready");
}
} // namespace

extern "C" JNIEXPORT void JNICALL
Java_org_qtproject_qt_android_RhineQtView_createEmbeddedScene(JNIEnv *env, jobject thiz,
                                                             jlong parentWindowReference, jint width,
                                                             jint height, jlong sceneGeneration)
{
    if (!env || !thiz)
        return;
    // QJniObject 持全局引用，可以安全地跨线程（Qt 主线程）传递。
    const QJniObject javaView(thiz);
    QMetaObject::invokeMethod(
        qApp,
        [javaView, parentWindowReference, width, height, sceneGeneration] {
            createSceneView(javaView, parentWindowReference, width, height,
                            static_cast<quint64>(sceneGeneration));
        },
        Qt::AutoConnection);
}

extern "C" JNIEXPORT void JNICALL
Java_org_qtproject_qt_android_RhineQtView_destroyEmbeddedScene(JNIEnv *, jobject,
                                                               jlong sceneGeneration)
{
    // 不能阻塞：UI 线程等 Qt 线程会与 Android QPA 形成双向死锁。
    // 改为排队执行，但必须先同步停掉渲染，再拆 Surface。
    if (!qApp)
        return;
    const quint64 generation = static_cast<quint64>(sceneGeneration);
    // 世代判定只放在排队的 lambda 里：那时 create 必然已执行完，事件队列是 FIFO。
    // 提前判会把「create 已发出、尚未执行」窗口里的 destroy 丢掉，场景会无主存活。
    if (QThread::currentThread() == qApp->thread()) {
        destroySceneView(generation);
        return;
    }
    // 注意：这里**不碰 Engine**。Engine::setVisible 会 flush 指针、发 pointercancel、
    // 停定时器、emit stateChanged()，全都没有锁；从 Java 的 UI 线程直接调就是和 Qt 主
    // 线程/渲染线程抢同一批状态。整件销毁动作都在 Qt 线程上按序做（隐藏窗口 →
    // destroySceneView 里的 engine->setVisible(false) → 拆视图）。
    QMetaObject::invokeMethod(qApp, [generation] {
        if (!RhineEmbedded::sceneEpoch().owns(generation))
            return;
        if (QQuickWindow *window = qobject_cast<QQuickWindow *>(g_sceneView.data()))
            window->setVisible(false);
        destroySceneView(generation);
    }, Qt::QueuedConnection);
}

// Flutter → Kotlin(PlatformView) → RhineQtViews.pushSceneState → 这里。
// 入口在 Flutter platform thread，必须切回 Qt 主线程再碰场景。
extern "C" JNIEXPORT jboolean JNICALL
Java_org_qtproject_qt_android_RhineQtViews_nativePushSceneState(
    JNIEnv *env, jclass, jint viewId, jlong context, jstring json)
{
    if (!env || !json)
        return JNI_FALSE;
    const char *raw = env->GetStringUTFChars(json, nullptr);
    if (!raw)
        return JNI_FALSE;
    const QString payload = QString::fromUtf8(raw);
    env->ReleaseStringUTFChars(json, raw);
    // 产出者身份按值拷进这一次投递。JNI 线程**不写任何全局**：旧代码在这里写
    // g_originViewId/g_originContext，而快照是排队到 Qt 线程才 apply 的 —— 排队窗口里
    // A 的输入过门时读到的是 B 的全局 origin，于是 A 的手指动作被贴上 B 的标签。
    const RhineEmbedded::ProducerOrigin origin{
        static_cast<int>(viewId), context > 0 ? static_cast<quint64>(context) : 0};
    // 先落盘再投递：即使此刻 qApp 还没建好（首帧竞态）也不会丢，场景就绪时会带着
    // **同一份** origin 自应用。
    RhineEmbedded::rememberState(payload, origin);
    if (!qApp)
        return JNI_TRUE; // 已受理（缓存），就绪后补
    // 快照本身不按 origin 预筛：Flutter 侧只有一个 isolate，push 顺序就是这里 Qt 事件
    // 队列的顺序，apply 顺序与 push 顺序一致（后推的赢），按 origin 预筛反而会在
    // "先 push 再 createSceneView"的顺序里把新视图的首帧误杀。预筛是给**输入/动作**用的
    // （它们是另一条生产者），见 nativePushScenePointer/nativePushSceneWheel。
    QMetaObject::invokeMethod(
        qApp,
        [payload, origin] {
            // 应用点：账本在这里、Qt 线程上、apply 成功之后才前进（旧代码在 JNI 线程）。
            RhineEmbedded::applySceneState(payload, origin);
        },
        Qt::QueuedConnection);
    return JNI_TRUE;
}

// Flutter 搬运来的原始指针事件：只做线程切换 + 直通 Engine::pointer。
// 手势语义（归档拖拽 / 唱片旋转 / 选中 / momentum）完全由 Qt 的
// NativeSceneInput 决定，这里不加任何判断，也不做坐标换算（调用方给的是舞台单位）。
extern "C" JNIEXPORT void JNICALL
Java_org_qtproject_qt_android_RhineQtViews_nativePushScenePointer(
    JNIEnv *env, jclass, jint viewId, jlong context, jstring type, jdouble x, jdouble y)
{
    if (!env || !type)
        return;
    const char *raw = env->GetStringUTFChars(type, nullptr);
    if (!raw)
        return;
    const QString eventType = QString::fromUtf8(raw);
    env->ReleaseStringUTFChars(type, raw);
    if (!qApp)
        return;
    // 产出者身份按值捕获（旧代码在 lambda 里读全局 origin，等于"出口时刻当前是谁"）。
    const RhineEmbedded::ProducerOrigin origin{
        static_cast<int>(viewId), context > 0 ? static_cast<quint64>(context) : 0};
    QMetaObject::invokeMethod(
        qApp,
        [eventType, sx = static_cast<double>(x), sy = static_cast<double>(y), origin] {
            Engine *engine = RhineEmbedded::engine();
            if (!engine)
                return;
            // origin 门禁：判定发生在 Qt 线程上，也就是**应用顺序**里——排队的旧 A
            // 视图事件在 B 的快照被应用之后到达时会被拒，不会贴到 B 的画面上。
            // 场景已拆（账本 Closed）、来源未登记、view/ctx 对不上一律 fail-closed。
            const RhineEmbedded::OriginVerdict verdict =
                RhineEmbedded::originLedger().evaluate(origin);
            if (!RhineEmbedded::originAccepted(verdict)) {
                qInfo("RHINE_QT_SCENE_ORIGIN_DROP pointer %s applied=%s n=%llu",
                      qPrintable(RhineEmbedded::describeOrigin(origin)),
                      qPrintable(RhineEmbedded::describeOrigin(
                          RhineEmbedded::originLedger().applied())),
                      static_cast<unsigned long long>(RhineEmbedded::originLedger().commits()));
                return;
            }
            // 只有归档页的拖动算滚动量；详情页拖动是转唱片，不能发给列表。
            const bool browsing = engine->scene.mode() == QLatin1String("archive");
            const double before = engine->scene.archiveTrackItem();
            const int previousSelection = engine->scene.selection();
            // 选中身份回传要**在手势之前**取格：pointerup 之后 NativeScene 会 resetPointer
            // 并把 hover 清掉，事后 pick() 拿不到用户点的那个格子。
            std::optional<SceneMotion::Cell> picked;
            if (eventType == QLatin1String("pointerup"))
                picked = engine->scene.pick(sx, sy);
            // 手指落下时清掉选中相关的"已应用"记录（S3）；只清 index/key，
            // 不清 mode/dark——见 resetSelectionState() 的注释。
            if (eventType == QLatin1String("pointerdown")) {
                RhineEmbedded::resetSelectionState();
                // 新手势起手：先把上一段惯性整段退休（审查 M1）。ticker 是全进程唯一的一个
                // QTimer 实例，不 stop() 它的 timeout 会继续进来；虽然 advanceScroll 已经
                // 不会在 held 阶段收尾，但一段"还在滑"的旧 fling 仍会读到新场景的位置。
                if (g_scrollTicker)
                    g_scrollTicker->stop();
                // 手势自己的 origin：整个手势（含松手后的 ticker 惯性）都从这一个来源出口，
                // 中途即便有别的视图的快照被应用也不会被改签。
                g_gesture.begin(origin, before);
                g_gesture.tracking = browsing;
                if (browsing) {
                    RhineEmbedded::emitScroll("start", 0.0, origin);
                }
            }
            engine->pointer(eventType, sx, sy);
            const double after = engine->scene.archiveTrackItem();
            if (eventType == QLatin1String("pointermove") && g_gesture.tracking && browsing) {
                // 与 ticker 共用同一份"移动帧"语义（advanceScroll）：手指按着时只发 move，
                // 绝不因为"连续几帧没动够阈值"就把新手势 end() 掉（M1 的另一半）。
                const RhineEmbedded::ScrollStep step =
                    RhineEmbedded::advanceScroll(g_gesture, after);
                if (step.kind == RhineEmbedded::ScrollStepKind::Move)
                    RhineEmbedded::emitScroll("move", step.delta, origin);
            }
            if (eventType == QLatin1String("pointerup")
                || eventType == QLatin1String("pointercancel")
                || eventType == QLatin1String("lostpointercapture")) {
                if (g_gesture.tracking) {
                    if (std::abs(after - g_gesture.base) > 1e-3) {
                        // 有位移/有惯性：交给 ticker 继续跟，停下来再 commit。
                        RhineEmbedded::startScrollTicker(after);
                    } else {
                        g_gesture.end();
                        RhineEmbedded::emitScroll("commit", 0.0, origin);
                        // 点选路径同样要补发被压下的选中（审查 '）。
                        RhineEmbedded::flushPendingSelection(engine);
                    }
                }
                // 别的所属的卡：点它把选中还回去，3D 与列表必须停在同一个窗口。
                // 只有位移小于阈值才算点选；拖动松手不回传选中，否则列表会原地跳动一次。
                const bool tapOnly = !(std::abs(after - g_gesture.base) > 1e-3);
                // lane 只可能在 0..4（wrap(lane,5) 对负数会产生界外值），先夹再打包，
                // 避免 (lane<<16) 负左移 UB 与越界身份。
                const int pickedLane = picked ? qBound(0, picked->lane, 4) : -1;
                if (browsing && picked && tapOnly && g_appliedLane >= 0
                    && pickedLane != g_appliedLane
                    && engine->scene.selection() != previousSelection) {
                    engine->scene.select(previousSelection);
                }
                // 只要真的拾取到格子就回传身份：选中差值判定会被 8 环绕的占位槽骗过。
                // 详情页唱片转过阈值就请求切相邻一张（不自动播放，切哪张由 Dart 决定）。
                // 只在 pointerup 上判定；cancel 是手势被取消，用户没有切歌意图。
                if (!browsing && engine->scene.mode() == QLatin1String("detail")
                    && eventType == QLatin1String("pointerup")) {
                    const double rotation = engine->scene.rotationTarget();
                    if (std::abs(rotation) > 0.62) {
                        RhineEmbedded::emitSceneAction(QStringLiteral("archive-step:%1")
                                                           .arg(rotation > 0 ? QStringLiteral("next")
                                                                             : QStringLiteral("prev")),
                                                       origin);
                        engine->scene.resetRotation();
                    }
                }
                // 只有 archive 模式、只有真点选（轨道没动 + 引擎也判没动）才回传身份。
                // 详情页转唱片、横滑、取消的手势一律不回传：它们都不该改列表选中。
                if (browsing && picked && tapOnly && engine->scene.tapLike()) {
                    // 带身份回传：kind+id 来自 Flutter 的 40 格语义表（唯一真值），
                    // 位置只是几何。Dart 侧先按 (kind,id) 折回真实行，折不到才用几何。
                    const auto identity = g_cellIdentity.value(
                        (pickedLane << 16) | picked->row, qMakePair(QString(), QString()));
                    if (!identity.second.isEmpty()) {
                        RhineEmbedded::emitSceneAction(QStringLiteral("archive-select:%1|%2|%3|%4")
                                                           .arg(picked->lane)
                                                           .arg(picked->row)
                                                           .arg(identity.first)
                                                           .arg(identity.second),
                                                       origin);
                    } else {
                        RhineEmbedded::emitSceneAction(QStringLiteral("archive-select:%1:%2")
                                                           .arg(picked->lane)
                                                           .arg(picked->row),
                                                       origin);
                    }
                }
            }
        },
        Qt::AutoConnection);
}

// 双指缩放搬运：走 Engine::wheelInput 的 pixelDelta 通路（与 Overlay.qml 的
// PinchHandler 同一个入口），angleDelta 记 0。
extern "C" JNIEXPORT void JNICALL
Java_org_qtproject_qt_android_RhineQtViews_nativePushSceneWheel(
    JNIEnv *, jclass, jint viewId, jlong context, jdouble x, jdouble y, jdouble delta)
{
    if (!qApp)
        return;
    // 同 pointer：origin 按值跨队列，出口不再读"当前是谁"。
    const RhineEmbedded::ProducerOrigin origin{
        static_cast<int>(viewId), context > 0 ? static_cast<quint64>(context) : 0};
    QMetaObject::invokeMethod(
        qApp,
        [sx = static_cast<double>(x), sy = static_cast<double>(y),
         sd = static_cast<double>(delta), origin] {
            Engine *engine = RhineEmbedded::engine();
            if (!engine)
                return;
            const RhineEmbedded::OriginVerdict verdict =
                RhineEmbedded::originLedger().evaluate(origin);
            if (!RhineEmbedded::originAccepted(verdict)) {
                qInfo("RHINE_QT_SCENE_ORIGIN_DROP wheel %s reason=%s applied=%s",
                      qPrintable(RhineEmbedded::describeOrigin(origin)),
                      RhineEmbedded::originVerdictName(verdict),
                      qPrintable(RhineEmbedded::describeOrigin(
                          RhineEmbedded::originLedger().applied())));
                return;
            }
            // 滚轮是离散一跳：一次 start + commit 就够，不需要拖动那样的连续帧。
            // 详情页的滚轮不是共享窗口输入（那里是旋转/放大唱片），只驱动场景本身。
            if (engine->scene.mode() != QLatin1String("archive")) {
                engine->wheelInput(sx, sy, sd, 0);
                return;
            }
            const double before = engine->scene.archiveTrackItem();
            // 滚轮也是一次新的用户手势：先停掉上一段惯性，别让旧 ticker 与这一跳并行。
            if (g_scrollTicker)
                g_scrollTicker->stop();
            g_gesture.begin(origin, before);
            engine->wheelInput(sx, sy, sd, 0);
            const double after = engine->scene.archiveTrackItem();
            if (std::abs(after - before) > 1e-3) {
                RhineEmbedded::emitScroll("start", 0.0, origin);
                RhineEmbedded::emitScroll("commit", after - before, origin);
            }
            g_gesture.end();
        },
        Qt::AutoConnection);
}
#endif // Q_OS_ANDROID
