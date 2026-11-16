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

// 连续归档滚动（P0 #1 的 Qt → Flutter 方向）。
//
// Qt 的 NativeScene 是原几何与惯性的唯一持有者；这里只把"轨道条目位置"的**增量**报给
// Flutter，由 Flutter 的 listPosition 当窗口真值再投影回来。三类回执：start（记序列
// 起点）、move（拖动/惯性中的连续增量）、commit（落行选中）。
//
// origin 在**起手时**捕获进这里，之后 ticker 每帧只读它。旧代码在 move/commit 时才读
// 全局 origin，于是 A 起手的惯性在 B 的快照被应用之后会被贴成 B 的标签 —— 列表照收，
// 画面就跳到 B 的位置上去。
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
// 语义表的 (lane,row) -> {kind,id} 索引，供点选回传正确身份（MUST-4 的消费者）。
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

bool requested()
{
    return qEnvironmentVariableIntValue("RHINE_QT_EMBEDDED") == 1;
}

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
    // QJniEnvironment::findClass() 返回的是**全局**引用（Qt 自己缓存它，跨线程复用）。
    // 对全局引用调 DeleteLocalRef() 会被 ART 判成 "expected reference of kind Local but
    // found Global" 并直接 SIGABRT —— 07:17:25 真机在第一次 pointerdown 就走到了这里，
    // 整进程崩溃。所以这里既不删除它，也不假设它的生命周期归调用方。
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

// 选中条目落在 8 个物理行里的哪一行：窗口基址是 (round(pos)/8)*8，所以槽位就是
// round(pos) % 8（与 Dart 侧 qtSceneCellsOf/qtSceneRowOfCell 的基址完全一致）。
// 绝对场景行：轨道条目 item 的卡片在 NativeScene 里是 cell.row = 12 + item
// （cellPosition 的 z = (row-15.5)*0.62 与投影的 -2.17-(row-15.5)*0.62 同一个坐标系）。
// 早期这里用 `12 + pos%8` 把 actor 钉在 item∈[0,7]，导致静止 0.5s 后轨道被回吸到
// 8 行窗口（审查 MUST-2'）。
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
    // 手势期间压下的选中在这里补应用：否则列表显示 A、3D 高亮停在 B（MUST-3）。
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

    // index 是 Flutter 列表行号；Qt 归档是 5 列 × 8 槽、索引域 0..39。
    // 行号 >39 时**不取模映射**：那会把第 41 行的歌高亮到第 1 行卡片上，而 key 指向的
    // 却是另一首歌（高亮与封面身份互相矛盾）。此时只换封面身份，不动选中。
    // index 是 Flutter 列表行号，Qt 侧用 fileLocation(index) 落到本列的真实行
    // （cell{ lane, 12+row }）。40 只是占位素材的槽位数，不是曲目域：塞壬有 936 首，
    // 早先的 `index < 40` gate 会让第 41 行之后的选中整条丢掉。
    // 手势进行中（手指按着、或 3D 惯性还在滑）时，Flutter 发来的 index/pos 是本轮拖动的
    // **回声**：把它回灌给 scene.select() 会走 !m_navigating 分支 -> resetPointer() 直接把
    // 捕获打断，用户表现为"按着拖一下就没反应了"（真机日志：RHINE_QT_RESET why=select
    // captured=1 browsing=1 出现在拖动中途）。所以手势期间只记数值，动画由 NativeScene
    // 自己驱动；松手 commit 之后再来的一帧才是权威位置。
    // 真正的"换人"才退休旧手势（审查 M2）：视图换人、或同一视图的交互代次变了（= 集合
    // 被替换：换目录/换所属/窗口集合真的变了）时，旧的原生手势状态与回声标记都属于上一份
    // 画面，必须在应用 B 之前整段清掉——否则 B 的权威 index/pos 会被当成 A 的回声压下去，
    // 旧 ticker 还会继续往 B 的选中与回声标记上写。**普通滚动帧不在此列**：同一 origin 的
    // pos/cells/画质更新必须保住合法的拖动与惯性（不许每帧换代次杀掉惯性）。
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
            // 记成 pending，commit 之后由 scrollTick 补一次（MUST-3）。
            g_appliedIndex = index;
            g_pendingIndex = index;
        } else {
            g_appliedIndex = index;
            g_pendingIndex = -1;
            // 显式几何槽位：index 是 Flutter 的列表行号，不再是 slots.json 的占位记录号。
            // 物理行由连续窗口真值 pos 决定（(round(pos)/8)*8 的基址 + pos%8），
            // 交给 NativeScene 的 navigation["cell"] 分支直接用，绕开 fileLocation 的
            // 占位域与 nearest 夹取（MUST-1：第 18 行/第 936 行都必须落在本列真实行）。
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
        // 有界诊断（只在 pos/lane 真的变化时打印）：这是"列表窗口真值 → 3D 轨道"的
        // 可复现凭据，槽位与 Dart 侧 cells 用同一个基址。
        // 有界诊断：打出轨道的**绝对行**与 archiveTrackItem（真值），不再打 pos%8。
        // track 就是 m_rail 的线性读出（`NativeScene::archiveTrackItem()` =
        // `(-rail - 2.17)/0.62 + 15.5 - 12`），所以 rail 不需要再单开一条日志：
        // 反解 rail = -((track - 3.5) * 0.62 + 2.17)，"停手 1s 后是否回弹"看 track 是否守住即可。
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
    //  * 只能在启动时决定的（图形后端/垂直同步/渲染分辨率/抗锯齿/超采样/MSAA）写进
    //    QSettings 的 panel/<key>：Qt/src/main.cpp:680(panel/graphics-backend)、
    //    :725(panel/vsync)、:738(panel/supersample)、:749(panel/aa-mode/:aa-scale)、
    //    :767(panel/msaa)、:809(panel/render-scale) 下次启动读的是同一份文件。
    //    Flutter 自己落的是另一个 SharedPreferences 文件（rhine_basic_settings），Qt 读不到，
    //    所以这一步不是重复：它是"下次启动真的换了"的唯一凭据。
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
        // FSR 档位/锐化与上面几个"下次启动才生效"的项不同：渲染器**每帧**读这两个环境变量
        // （Qt/src/render/ScenePostProcess.cpp:15-20 sharpness()、:68-84 renderSize()），
        // 所以除了落进 QSettings（Qt/src/main.cpp:755-763 下次启动读同一份），还要像
        // NativeHudController.cpp:781-800 那样当场 qputenv —— 否则面板换了、画面没换，就是假开关。
        // 归一/夹取与渲染器口径逐字一致：未知档位不写（ScenePostProcess.cpp:69-84 对未知值的行为
        // 是 divisor=1.0，即原生渲染），锐化夹到 0..100（sharpness() 的 qBound）。
        int appliedFsrSharpness = -1;
        QString appliedFsrQuality;
        if (settings.contains(QLatin1String("fsrQuality"))) {
            const QString quality = settings.value(QLatin1String("fsrQuality")).toString();
            if (quality == "super" || quality == "performance" || quality == "balanced" ||
                quality == "quality" || quality == "native") {
                appliedFsrQuality = quality;
                engine->host.setPreference(QStringLiteral("fsr-quality"), quality);
                qputenv("RHINE_FSR_QUALITY", quality.toUtf8());
            }
        }
        if (settings.contains(QLatin1String("fsrSharpness"))) {
            bool valid = false;
            const int percent = settings.value(QLatin1String("fsrSharpness")).toVariant().toInt(&valid);
            if (valid) {
                appliedFsrSharpness = std::clamp(percent, 0, 100);
                engine->host.setPreference(QStringLiteral("fsr-sharpness"),
                                           QString::number(appliedFsrSharpness));
                qputenv("RHINE_FSR_SHARPNESS", QByteArray::number(appliedFsrSharpness));
            }
        }
        qInfo("RHINE_QT_SCENE_SETTINGS disc=%d mask=%d vsync=%s scale=%d backend=%s aa=%s/%d msaa=%d ss=%d "
              "fsr=%s/%d",
              int(disc), mask, qPrintable(settings.value("vsync").toString()),
              settings.value("renderScale").toInt(75), qPrintable(settings.value("backend").toString()),
              qPrintable(settings.value("aa").toString()), settings.value("aaScale").toInt(125),
              settings.value("msaa").toInt(0), settings.value("supersample").toInt(1),
              qPrintable(appliedFsrQuality.isEmpty() ? QStringLiteral("(unset)") : appliedFsrQuality),
              appliedFsrSharpness);
        applied = true;
    }

    // 封面身份投影（FINAL-RECOVERY-138 / 决策：URL 优先，选中身份不是播放身份）。
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

    // 应用完必须自己唤醒一帧：引擎休眠（m_sceneSleeping）时 setMode("detail") 只是把
    // 目标值改了，过渡一帧都不会跑。真机现场：09:03:43 收到 mode=detail 并返回 applied，
    // 但之后没有任何一帧，屏幕还停在上一次 archive 画面（盘面/封面当然看不到）。
    // 早先"能进详情"是碰巧：新封面异步下载回调里顺手把 m_sceneSleeping 清了。
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
    // 同步把 DeferredDelete 排空：调用方（Java 的 onDetachedFromWindow）返回后 Android 就可能
    // 释放 Surface，如果 QQuickWindow 还活着，渲染线程会在已销毁的 mutex 上 queueBuffer
    // （真机 Abort: "FORTIFY: pthread_mutex_lock called on a destroyed mutex"，栈经
    //  Surface::hook_queueBuffer ← QueuePresentKHR ← QRhi::endFrame）。这里就地析构，
    // QQuickWindow 的析构会与渲染线程同步，返回值即代表窗口已不存在。
    // 只排空这一个窗口的事件：进程级 flush 会把别人的 DeferredDelete 也提前执行。
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
    engine->rootContext()->setContextProperty(QStringLiteral("profiler"), RhineEmbedded::profiler());
    QObject::connect(engine, &QQmlEngine::quit, QCoreApplication::instance(), &QCoreApplication::quit);

    // Qt 自己的 QtQuickView 就是把子窗口的 Java QtWindow 交给 QtView.addQtWindow；
    // 这里沿用同一条路：把 winId()（QAndroidPlatformWindow 里就是 QtWindow jobject）
    // 连同视图指针和父窗口一起交给 Java 侧的 QtView。
    if (Engine *engine = RhineEmbedded::engine()) {
        engine->setWindow(view);
        view->installEventFilter(engine);
        // 拾取选中回传 Flutter 的通道已经接好（RhineQtViews.emitSceneAction →
        // MethodChannel('rhine.music/qt_scene').action → QtSceneActions.onAction），
        // 但**暂时不发**任何动作：场景里的槽位来自 Assets/android-3d/slots.json 的
        // 40 条占位记录（columns = 搜索结果/喜欢的歌曲/我的歌单/收藏歌单/收藏专辑，
        // records 全是 "音乐槽位"），没有 Siren 曲目身份，而曲库权威在 Flutter。
        // 早先发 "music:index:<i>" 会被 HUD 当成列表下标（basic_app.dart 的
        // music:index 分支），越界就弹“预览中尚未实现”，属于假映射。
        // 真正的动作词表等 lead / 133 定（需要能表达“归档槽位”而不是曲目下标）。
        Q_UNUSED(engine);
    }
    if (RhineEmbedded::profiler())
        RhineEmbedded::profiler()->attach(view);

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
    // 不能阻塞：这条 JNI 会被 Java 的 UI 线程调用（视图摘除 / 宿主销毁），而 Qt 的
    // Android QPA 在执行 UI 线程动作时是"Qt 线程等 UI 线程"的方向。UI 线程在这里
    // BlockingQueuedConnection 等 Qt 线程 = 双向等待死锁（真机表现：Activity 销毁后
    // 一声不响地挂住，随后输入派发超时被系统按 ANR 杀掉）。
    // 改成排队执行，但**先同步停掉渲染**：SIGABRT
    // "FORTIFY: pthread_mutex_lock called on a destroyed mutex" 是 QQuickWindow 在
    // Surface 已释放后还 present 造成的，所以禁止 presenting 必须在拆 Surface 之前发生。
    if (!qApp)
        return;
    const quint64 generation = static_cast<quint64>(sceneGeneration);
    // 这里**不能**先判一次世代：create 也是排队进 Qt 线程的（上面 createEmbeddedScene），
    // "Java 已经发出 create(gen)、Qt 线程还没排到这个 lambda"的窗口里 sceneEpoch().current()
    // 还小于 gen，提前判会把这次 destroy 整段丢掉；而 Java 侧 retireScene() 已经把
    // sceneGeneration 归零、不会重发 —— 排队的 create 随后照样执行，场景就建在一个已经
    // detach 的 javaView 上无主存活（真机面：Surface 拆了还 present 的 SIGABRT，或窗口
    // 摘除后仍在收输入的 ANR）。判定只放在排队 lambda 里：那时 create 一定已经跑完，
    // 同一条事件队列是 FIFO，[create][destroy] 的顺序天然成立；旧世代的 destroy 在那里
    // 仍会被 owns() 拒掉。
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
            // 只有归档页的"浏览拖动"才是共享窗口的输入；详情页拖动是旋转唱片，属于
            // 场景内部姿态，绝不能把它当成滚动量发给 Flutter（真机实测：详情页里拖一下
            // 会算出上百行的位移，列表直接被甩飞）。
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
                        // 点选路径同样要补发被压下的选中（审查 MUST-3'）。
                        RhineEmbedded::flushPendingSelection(engine);
                    }
                }
                // 别的所属的卡：3D 不能替列表决定"所属"。用户 06:19 的规则是所属只由
                // 列表决定（拖动 3D 只能滚动当前所属），所以点到别层的卡时把选中还回去，
                // 让 3D 与列表保持同一个窗口；08:59 真机证据：点到 lane=2 的卡会让
                // 原生光标停在 lane 2，而列表还在 lane 3，两边就此不一致。
                // 本次手势是不是一次"点选"：位移小于阈值才算。拖动松手**绝不能**回传
                // 选中——那会让列表先跳到手指处那首歌、再被惯性落点拉回，用户实测就是
                // "一定会原地跳动一次"，也是 P0#1 明文禁止的双消费。
                const bool tapOnly = !(std::abs(after - g_gesture.base) > 1e-3);
                // lane 只可能在 0..4（wrap(lane,5) 对负数会产生界外值），先夹再打包，
                // 避免 (lane<<16) 负左移 UB 与越界身份。
                const int pickedLane = picked ? qBound(0, picked->lane, 4) : -1;
                if (browsing && picked && tapOnly && g_appliedLane >= 0
                    && pickedLane != g_appliedLane
                    && engine->scene.selection() != previousSelection) {
                    engine->scene.select(previousSelection);
                }
                // 只要真的拾取到格子就回传身份：不再用 selection 差值判定。NativeScene 的
                // tap 走 select(fileAt(cell))，那个整数是 8 环绕的占位槽（0..39），同列相隔
                // 8 行的两次点击会相等 → 第二次点选静默无响应（审查 S9）。
                // 详情页把唱片转到阈值以外 → 请求切到相邻一张（不自动播放，切哪张由
                // Dart 的列表真值决定）。角度随即复位，避免停在一个偏着的姿态上。
                // 只在真正的 pointerup 上判定：pointercancel / lostpointercapture 是
                // "手势被取消"（旋屏、重挂、PlatformView 重建），那时用户没有"转到底"的
                // 意图，切歌就是越界。resetPointer 不清 m_targetRotation，所以被取消的手势
                // 仍会读到超阈值的角度。
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
