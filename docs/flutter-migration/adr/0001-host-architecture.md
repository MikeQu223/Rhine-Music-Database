# ADR 0001：Qt → Flutter 宿主架构（pending-evidence）

> 归档说明（2026-11-19）：本文引用的 `.agents/` 目录已删除（含 227 个 worktree、控制面报告与日志）。文中的 `.agents/...` 路径仅作历史出处；控制面摘要、实测数字与残留材料见 `docs/flutter-migration/archive/2026-11-19-control-plane.md` 与 `docs/flutter-migration/archive/qt-flutter-state-2026-11-19.md`。

- 状态：**PROPOSED / PENDING_DEVICE_EVIDENCE — 未裁决**。赢家字段 UNASSIGNED。
- 计划卡：T16 架构裁决（docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:506-512）
- 本文件原子：T16-D02、T16-D03（输出 docs/flutter-migration/adr/0001-host-architecture.md）
- 裁决矩阵：docs/flutter-migration/02-adjudication.md（原子 T16-D01）
- 依赖：T11-T15 候选源码与 T10 切片规格“存在即可起草”；结论必须等 T16-D01 真机数据（GRAPH-V2-REVIEW.json next_wave W1b）。
- 日期：2026-11-10
- 本版：证据冻结（T16-D02 / T16-D03 起草）。只固定程序、契约与边界证据，不含赢家；未来裁决提交按 §7.6 另起 commit。
- 证据口径：本文所称 `reports/<名>` 一律指控制面目录 `.agents/parity-20261109/reports/<名>`（`.gitignore:17` 的 `/.agents/` 当时已忽略该目录，仓库根当时无 `reports/`；2026-11-19 起仓库根已有**未跟踪**的 `reports/`，但只放 11-19 的三份报告，历史控制面报告不在此列）；它们是控制面报告（非仓库内实现证据）；审计基线为冻结 SHA bf6743e8486d62964cc27a4b8573533fc00f2eb4（OPS78-FINAL-DEDUP.json:3 auditSha），但各报告自报的 baseSha/asOfSha 可不同（例：OPS78-COVERAGE.json:8/:9/:10 记 baseSha 8ed3067b…、asOfSha 2623b1c5…、rootMoving=true），以各报告自报字段为准。下文凡仅以 reports/ 为出处的计数与状态，均属控制面口径，未在仓库内验证。

## 1. 背景与问题

Qt Android 是参考实现与契约来源，Flutter 是新宿主。计划要求在**同一个** archive→detail→search→queue 切片上实测五种宿主候选（A PlatformView / B 离屏 Texture / C Dart HUD + 3D 移植 / D 混合 / E 本地 WebView），再由统一裁决选型；不预设赢家（计划:7、计划:42、计划:167）。

本 ADR 记录：问题、备选方案、任何赢家都必须满足的不可协商契约、以及“为什么今天不能裁决”。它**不记录赢家**，因为裁决所需的 E0 真机证据在本轮禁令下不存在。

## 2. 决策（Decision）

**未裁决。** 无赢家被选定，也无赢家被排除。

理由：计划 §3.4 规定“T16 汇总所有已跑候选的同一切片数据；没跑过的候选不得填指标，只能标‘未评估’”（计划:167）。当前已跑候选 0/5，故不存在任何可比较的同切片数据，任何选型都只能是预设赢家，被明令禁止。

本 ADR 当前固化的是裁决**程序与约束**，不是裁决**结果**。

## 3. 备选方案（五个，同一切片）

| ID | 方案 | 忠实保留点 | 必须实测 | Spike |
|---|---|---|---|---|
| A | Flutter 宿主 + PlatformView 承载 Qt 视图 | Qt 渲染 / 输入 / 业务原样 | QtActivity 不能直接塞；嵌入生命周期、触摸坐标、IME、无障碍、旋转、叠层 | T11 |
| B | Flutter 宿主 + Qt 离屏渲染到 SurfaceTexture（FlutterTextureRegistry 合成） | Qt 渲染与业务原样，合成在 Flutter | QQuickRenderControl / RHI 离屏、GL / Vulkan 纹理共享、首帧、尺寸 / 时间戳、旋转、输入转发 | T12 |
| C | Flutter 宿主 + Dart CustomPainter 直译 HUD + 真实 3D 移植 | 无 Qt 运行时依赖，长期可维护 | 17 命令、字形 JSON、命中、3D GLB / 相机 / 拾取 / 雾 / 动画、输入时延 | T13 |
| D | 混合：HUD 由 Dart 自绘，3D 暂由 Qt Texture 提供 | 渐进、可回退 | 双渲染栈同步、坐标同源、退出条件、长期成本 | T14 |
| E | Flutter 宿主 + 本地 WebView（canvas / WebGL / Three.js）完整复刻 | 命令语义可只写一次；Web 生态 | 全切片功能、IME、无障碍、纹理合成、首帧 / resize、WebView 版本差异 | T15 |

说明：A/B/D 允许保留 Qt 移植层，无强制拆除 Qt 的期限；C/E 也必须通过同一功能门，不能以“纯 Flutter”换取删功能（计划:141）。

### 3.1 失败出口（计划:509 要求逐候选记录）

| 候选 | 声明的失败出口（计划 §3.1 Fail 原文） |
|---|---|
| A | 静态截图冒充嵌入；触摸错位仍宣称可用 |
| B | 只有静态首帧；旋转黑屏仍继续 |
| C | 用 Material 列表替代 HUD |
| D | 两套状态双写导致错帧 |
| E | 只做素材展示、不跑交互 |

规则：任一候选触及其声明的失败出口即该候选失败；五候选全部失败**或全部未跑**时，按计划:170、计划:510 结论写“未裁决”并停止 P2 页面实现。当前状态为“0/5 已跑 → 未裁决”，故 P2 页面接线保持 ARCH_BLOCKED。

## 4. 任何赢家都必须满足的不可协商契约

以下为**与候选无关**的契约。裁决只决定宿主通道，不改变这些契约。每条给出 Qt 源证据。

### 4.1 HUD 协议（E1）

| 契约 | 证据 |
|---|---|
| 公开值为 commands（**数组**）/ hits（**数组**）/ frame（**对象**，其顶层键清单由 T03 从 RhiScene/Engine 冻结，本 ADR 不枚举，避免把 eye/fog 等非顶层键写成契约；计划:212）（不是 {id,opcode,args,seq} 对象，无 z / frameId） | Qt/src/NativeHud.h:74-76（:74 QJsonArray commands；:75 QJsonArray hits；**:76 QJsonObject frame**）。frame 为对象另见 Qt/src/NativeHud.cpp:239 `frame = next;`；frame 取值见 Qt/src/NativeHud.cpp:246（`const bool inDetail = frame["mode"] == "detail";`）、:257 / :267 / :269 / :272（mode / viewer 分支）、:280（`frame["detail"].toDouble()` 驱动详情淡入）。注意 :242-245 是注释块、不是取值；:295 的同名读取只出现在 Android 诊断日志，不构成契约。照“数组”实现会破坏传输契约 |
| 命令是数组，a[0] 为 op | Qt/src/Glyphs.cpp:637-639（:637 `for (const auto &v : commands) {`、:638 `const auto a = v.toArray();`、:639 `auto op = a[0].toString();`），17 op 表见计划 §4.2（源 Glyphs.cpp:637-825；:825 为 image 分支收尾、:829 关闭 dispatch 循环） |
| 17 op：save / restore / alpha / translate / scale / rotate / clip / fill / ellipse / text / art / fill-path / path / arc / right-mask / gradient / image | 计划:187-205（逐项参数下标已核对） |
| hits 必需六字段 {x,y,width,height,action,label} | Qt/src/NativeHud.cpp:102-109 |
| 仅 PlayerBar 的 hit 额外带 fixed:true | Qt/src/PlayerBar.cpp:46-53 |
| 颜色为 RGBA 数组；第五项以 calibrated 前缀标记，按 Gamma 1.8 → sRGB 转换 | Qt/src/Glyphs.cpp:35-49 |

### 4.2 文字与字形（E1）

- 素材：Assets/fonts/ 下 RhineMiSans-{light,regular,demibold,bold}.otf、NotoSansSymbols2-Regular.ttf、misans-glyphs.json（weight→glyph→{advance,path}）（计划:218）。
- 正常路径：读同一 JSON 的 advance/path，按 advance×size+tracking 逐字绘制；基线 y+size×1.044；fit() 二分截断并补省略号（计划:219）。
- 回退路径仅限缺字 / 组合字符 / 复杂文字 / RTL → QTextLayout + 系统字体；禁止用普通 Text 全量重排后宣称字宽 / 截断 / 居中一致（计划:220）。
- 颜色：亮 / 暗两套 paper / panel / ink / muted / line / soft / amber；不能用 Material ColorScheme 近似（计划:221）。

### 4.3 3D（E1）

- 必须保留真实 GLB、材质、相机、BVH 拾取、灯光、雾、动画时间、纹理准入；禁止静态背景、预渲染视频或把文字烤进 3D（计划:226）。
- 3D↔2D 隐性契约：投影偏移 0.16 / 0.20、18% 视野外扩、near 5 / far 300、竖屏 aspect<1.05 分支、viewer 34° FOV / 0.3..120 裁剪（计划:227）。

### 4.4 发布与一致性（E1）

- commands / hits / frame 必须同一状态代次发布；新增 generation 只能用于一致性校验，不得去重合法相同的命令；measure / hit / IME 使用同一 layout geometry，禁止三套坐标（计划:213）。
- 横屏舞台：stageScale = heightLogical / 1080；stageWidth = widthLogical / stageScale；旋转 / 尺寸变化只重算 stage，不重建引擎状态（计划:120、计划:178）。

### 4.5 Node 与上游运行时（E1）

桌面与移动端的桥形态不同，但暴露给上层的协议相同；这段必须先纠正旧稿的一处措辞。

- **桌面 = 子进程。** Qt/src/BridgeProcess.h:4-6：`#if !RHINE_MOBILE` 下 `using BridgeProcess = QProcess;`。
- **移动端 = 编进应用进程的常驻运行时，不是一个被 fork 出来的进程。** Qt/src/BridgeProcess.h:11-12 注释原文：「移动端没有可执行文件可以 fork：Node 以常驻运行时（iOS 为 NodeMobile.framework，Android 为 libnode.so）编进进程，Worker 按会话创建、销毁，不共享模块与环境变量。」运行时实例是函数内静态单例：Qt/src/BridgeProcessAndroid.cpp:164-168 `NodeRuntime &runtime() { ... static auto instance = new NodeRuntime; return *instance; }`。因此旧稿“Node 进程单例”**不准确**：单例是进程内的运行时对象，Worker 才是按会话生灭的实体；Android 上没有独立的 Node 进程可供观察或 kill。
- **每次 start 生成新 session 并驱动一个 Worker。** Qt/src/BridgeProcessAndroid.cpp:179-189 置 `m_state = Starting`、`m_session = QUuid::createUuid()...`、`runtime().owner = this` 后 launch；:207-211 发送 `{{"type","start"},{"session",m_session},{"script", root + "/MusicBridge/worker.cjs"},{"stderrLog",true},{"env",environment}}`；:226-235 `kill()` 用同一 session 发 `{"type","stop"}` 并清空状态，不销毁运行时。
- **libnode.so 只导出 node::Start。** Qt/src/BridgeProcessAndroid.cpp:19-24：`namespace node { int Start(int argc, char *argv[]); }`（注释说明无 `node_start`），:152 `const auto code = node::Start(4, values);`。绑定面因此只有这一个入口 + 消息循环（计划:527）。
- **环回控制与令牌。** :47 `QUuid::createUuid().toString(QUuid::WithoutBraces)` 作 token；:81-88 首条消息必须带该 token，否则 abort，握手完成后 :88 `server.close();`；:90 `socket->write(queued);` —— 握手前消息排队、不丢。
- **上限与超时。** 单条消息 48 MiB：:73 `if (input.size() > 48 * 1024 * 1024) {`（iOS 同值 Qt/src/BridgeProcessIOS.cpp:53）。启动 30 s：:213-217 `QTimer::singleShot(30000, this, [this, session] { if (m_session == session && m_state == Starting) kill(); });`（iOS 同值 :160）。
- **崩溃回传。** 运行时断开（:63-67）与 Node 退出（:155-159）都回 `{"type", "runtime-error"}`，由上层决定重试或降级。
- **协议回放。** ios-runtime.cjs / worker.cjs 与 Qt 同一份脚本（计划:529；同源注释见 Qt/src/BridgeProcessAndroid.cpp:35-39），字段名与 Qt 一致。
- **桥的位置交由裁决。** Flutter 进程内嵌 Node 或继续由 Qt 宿主承担，但**协议不变**；若选进程内嵌，条件创建 android/app/src/main/cpp/CMakeLists.txt，JNI 只封装 node::Start / 消息循环（计划:525-527）。
- **旋转 / 尺寸变化不触发重复启动**（计划:528）。

### 4.6 平台能力与缺口

- Qt 在 Android 上**关闭了无障碍桥**（前台滑动 ANR 防护）：Qt/src/AndroidWindow.cpp:53-71（:53-58 注释、:59 `void swallowAccessibilityUpdate(QAccessibleEvent *) {}`、:63-71 `configureAndroidAccessibility()` 安装该 handler 并 `QAccessible::setActive(false)`，RHINE_ANDROID_ACCESSIBILITY=1 时提前 return）。因此**不存在 Qt Android 无障碍树基线**，Flutter 侧 Semantics 标注为 NEW DESIGN，不得冒充“与 Qt 一致”（reports/T10-C01-M10.json F2）。
- boot-lettering-art.json 契约缺口：Qt/src/Glyphs.cpp:83 从 root + "/boot-lettering-art.json" 载入 art 资源，但图与 inventory 尚未纳入（GRAPH-V2-REVIEW M5）。art op 正确性依赖补齐，否则会静默漏 art 指令。

### 4.7 性能政策护栏（防伪造，计划:229-233）

- Qt 按需绘制，静止画面低 fps 正常。**不得**把“稳定 60fps / 16.6ms / jank 1% / 冷启动 +10% / 内存 +15%”写成已承诺目标；若出现，只能是“拟议待 P0/P4 基线冻结”的辅助指标（计划:231）。
- 辅助 SSIM≥0.97、ΔE≤3、像素容差、性能比例均为**拟议**，需用 Qt 同设备同场景基线冻结；它们不能代替逐 ROI / 字形 / 布局 / 动作 / 时序的人工对照，不得用大 mask 遮差异（计划:232）。
- 核心硬门是功能 / 画面 / 动作 / 状态齐全；性能不达标可以优化或记录差异，**不能删功能换分数**（计划:233）。
- 本轮零测量：本 ADR 与 02-adjudication.md 中不得出现任何被当作结果的性能数值。

### 4.8 Qt 宿主职责与 Flutter 侧边界（E1，与候选无关）

裁决只决定“谁画、怎么合成”，不改变 Qt 侧已经承担的宿主职责，也不改变 Flutter 侧的起点。逐项证据：

| 职责 | Qt 侧证据 | 对 Flutter 宿主的含义 |
|---|---|---|
| 上游访问（系统边界） | Qt/src/Host.h:18 注释「系统边界：只通过管道调用锁定的上游；凭据不进入参数、环境或日志。」；:27 `void requestJson(QString route, QJsonObject params, JsonReply callback);`、:28 schedule、:29 loadCover、:30 playOfficial；:44-49 mediaMetadata / mediaLoad / mediaControl / mediaState | 任何候选都必须保留这条边界：Flutter 侧不得直接持有上游凭据或绕过宿主直连上游 |
| 请求分发（信封） | Qt/src/Host.cpp:194 `void Host::requestJson(QString route, QJsonObject values, JsonReply callback) {`；:195-203 `remote->request("host.request", {{"route", route}, {"values", values}}, ...)`；:205-207 Host 已停止时直接返回 | 跨桥 envelope 属新设计、字段与数值拟议（计划:147）；本轮不冻结任何跨桥字段 |
| 上游运行时 | Qt/src/Host.h:128 `BridgeProcess child;`、:129 `std::unique_ptr<AudioPlayer> audio;`，运行时细节见 §4.5 | 桥的位置可变，运行时契约不变 |
| 凭据 | Qt/src/Host.h:142 `QHash<QString, QJsonObject> privateCredentials;`；:159-161 platformCredential / platformSaveCredential / platformDeleteCredential；:162 platformQR、:163 platformPlay、:164 platformActivates、:167-169 platformMediaCommands / platformMediaInfo | 凭据只在宿主内，绝不进参数 / 环境 / 日志（Host.h:18） |
| 渲染宿主 | Android 只有单窗口：Qt/src/main.cpp:1095-1096 注释「Android 的“窗口”就是全屏 Activity：没有第二窗口、没有悬浮歌词、没有呈现层接管」，:1097-1100 `const bool hasNativeWindowSystem = false;`，实际装配走 main.cpp:1261-1262 `configureAndroidWindow(window, backend.get());`。桌面离屏路径见 §4.9 | Android 上没有“第二个原生窗口”可借；需要离屏产帧的候选必须自己造路径 |
| Flutter 侧现状 | lib/main.dart 122 行仍是 `flutter create` 计数器模板（:14 `title: 'Flutter Demo',`），不引用 QtPlatformView；android/app/src/main/kotlin/rhine/music/database/MainActivity.kt 5 行 `class MainActivity : FlutterActivity()`，未注册任何 PlatformView；`Qt/porting/` 目录不存在；lib/ 内无 FlutterTextureRegistry 命中，SurfaceTexture 仅 2 处注释提及（lib/platform/qt_platform_view.dart:55、android/app/src/main/kotlin/rhine/music/database/porting/QtPlatformViewHost.kt:149），无代码级用法。**但候选 A 的通道源码已在树内**：lib/platform/qt_platform_view.dart:629 `static const MethodChannel _control = MethodChannel(qtPlatformControlChannel);`（:630 EventChannel，:641-648 initState 装 handler），android/app/src/main/kotlin/rhine/music/database/porting/QtPlatformViewHost.kt:713 `private val control = MethodChannel(messenger, QtPlatformViewHost.CONTROL_CHANNEL)`，其工厂 :688-689 在 Android 侧构造 Kotlin `QtPlatformView`；Dart 侧 `QtPlatformView` widget 的构造点只在 integration_test/slice_platformview_test.dart（:493/:517/:650/:665/:710），lib/ 生产代码零构造点 | 候选 A 有落盘宿主源码（Dart 通道 + Kotlin 视图），候选 C 的 Flutter HUD/场景机制已在树内（lib/hud/ 40 文件、lib/scene/、lib/ui/），但两者的生产接线均为零（main.dart 不用、MainActivity 不注册），仍不可跑 |

### 4.9 Qt 侧既有离屏实现与缺口（**不构成任何候选胜出**）

先纠正一个容易误读的名字：`SceneTextureHost` 在当前 Qt 源码中**不存在**。全仓唯一命中是计划 T41 的 Create 列表（docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:669 列 `Qt/porting/SceneTextureHost.h` / `.cpp`），而 `Qt/porting/` 目录尚未建立。它是计划态产物，不能当作现状证据引用。

真实存在的离屏机制是桌面前台层用的 `SceneLayerHost`：

- Qt/src/render/SceneLayerHost.h:25-29 注释「场景与 UI 的离屏宿主，共享一个 QRhi……两层离屏窗口不能 show」；:30 `class SceneLayerHost`；:48-49 `start(QQmlEngine &engine, const QUrl &scene3dUrl, const QUrl &overlayUrl, QRhi *rhi, QVulkanInstance *vulkanInstance = nullptr, QWindow *visibleWindow = nullptr)`；:52 `renderFrame()`；:57 `resize(QSize)`；:59-62（:60 `QRhiTexture *sceneTexture() const;`、:62 `QRhiTexture *overlayTexture() const;`）；:64-67 注释（FG 宿主须把输入事件转发给 UI 层，3D 层只取景不交互）与 :66 overlayWindow() / :67 sceneWindow()；:80-82 注释与 `QSize pixelSize() const;`（:82，物理像素 = 逻辑尺寸 × 设备像素比）。
- Qt/src/render/SceneLayerHost.cpp:27 注释（离屏窗口需要真实宿主窗口，供对话框定位、DPR 与输入法查询）；:28 `class LayerRenderControl final : public QQuickRenderControl`、:32 `renderWindow()` 返回 m_window；:116-122 两个场景各自一个 QQuickRenderControl 与各自 QQuickWindow（注释：一个 control 每帧换 target 会触发重建）；:124-129 两层共用 `QQuickGraphicsDevice::fromRhi(rhi)`；:131-137 Vulkan 下必须 setVulkanInstance。
- 构建注册：该实现列在根 CMakeLists.txt:239-240 的 `RHINE_APP_SOURCES`（列表 :252 收尾），不在 Qt/CMakeLists.txt（后者仅 31 行，除 :3 显式追加 `src/Gamepad.cpp` / `src/Gamepad.h` 外不枚举 C++ 源；`SceneLayerHost` 不在其中，故该实现的注册点在根 CMakeLists.txt）。见 §8 的构建注册点。

**关键限定（否则会误判候选 B 已具备条件）**：这条路径在 Android 上是关闭的。Qt/src/main.cpp:1095-1100 明确 Android 没有第二窗口、`hasNativeWindowSystem = false`；前台层的构造条件是 `fgCandidate`（main.cpp:1128-1138），其中含 `hasNativeWindowSystem`，Android 直接短路；Android 走 main.cpp:1261-1262 的单窗口装配。所以现有代码只证明「桌面 FG 能把两个 QML 场景渲染进 QRhiTexture」，**不证明** Android 上能产出 SurfaceTexture，也不证明 FlutterTextureRegistry 交接可行。

结论（证据口径）：离屏产帧 + 外部合成在 Qt 侧有可复用的设计参照，但“Android 落点”与“Flutter 交接”两段都缺实现、缺实测。本节只说明缺口位置，不作为任何候选的胜出或失败证据（计划:167-168）。

## 5. 工作面分类（三类，本 ADR 的唯一可执行结论）

| 类别 | 含义 | 本轮可否先写 | 例 |
|---|---|---|---|
| SHARED SOURCE 可写 | 契约 / fixture / 测试（只写不跑）/ 纯 Dart 领域与数学 / 候选源码 / 隔离目录页面几何与动作 builder | 可以（受独占写域与 owner 隔离约束） | T01-T07 契约、T10 切片、T11-T15 候选源码、T22/T23/T24 纯 Dart 领域、T41-S01 投影数学 |
| PRODUCTION WIRING → ARCH_BLOCKED | 需本 ADR 赢家或宿主 / 桥 / 域运行时真实接线 | 不可以 | T20-S01..、T21 桥、T25 平台通道、T33-T40 页面接线、T41-S02..S06、T42-T44 |
| MEASUREMENT → DEVICE_BLOCKED | 真机像素 / 时序 / 黄金帧 / 性能取证 | 不可以 | T16-D01、-G01 golden（13 项全 ABSENT，卡片级门见下注）、T41-T02、T44-T02、T50-T54 |

图层面计数（reports/GRAPH-V2-REVIEW.json M3 / state_recut）：W=87 / W*=73 / A=25 / D=31。本卡：T16-D01 → D；T16-D02 / T16-D03 → W。

关键澄清（针对 GRAPH-V2 M10）：下游 110 个“waits for accepted ADR (T16)”的**真实断点是 T16-D01（设备实测缺失），不是本 ADR 的文本**。本 ADR 的文本可以在无设备时写出；页面接线仍须等设备数据 + 赢家。不得把“ADR 已写”当作“接线解锁”。

- **-G01 golden 的门归属（逐条核对控制面台账；卡片级门未在仓库内验证）**：goldenMissing=13（.agents/parity-20261109/reports/OPS78-COVERAGE.json:106），13 个 -G01 条目 status 均为 `ARTIFACT_ABSENT`、historicalState 均记 `DEVICE_BLOCKED`；但卡片级 blockReason 并非统一为 `DEVICE_BLOCKED`——仅 T33（:3869）、T42（:5213）、T51（:5703）记 `DEVICE_BLOCKED`，T30（:3308）/ T34（:3999）/ T37（:4448）/ T43（:5361）记 `ARCH_BLOCKED`，T36（:4281）/ T39（:4710）/ T40（:4869）记 `SOURCE_DEPENDENCY_BLOCKED`，T31（:3547）/ T35（:4126）/ T38（:4565）无 blockReason。故“全部 -G01 golden → DEVICE_BLOCKED”不成立：golden 产物是测量件，但所属卡片当前仍被架构 / 源依赖门挡住，两类门不得互换（见上条澄清）。

## 6. 后果（Consequences）

- 正面：候选源码、契约、纯 Dart 领域、隔离页面几何可并行推进，不被本卡串行化。
- 负面：页面上线、桥接线、宿主选型在设备证据到位前保持 ARCH_BLOCKED；不可用源码推断代替实测交付。
- 中性：本 ADR 可在无设备时被独立复核（矩阵形状、契约引用、工作面分类）；它的“未裁决”是**结论**，不是缺陷。

## 7. 解锁条件（何时可以改写为“已裁决”）

1. 获得一次真机窗口授权（Lead / 用户决定；review 叶不申请）。
2. 对每个候选跑同一 docs/flutter-migration/01-slice.md 切片，产出 E0 帧与 commands / hits 导出。**前置**：该文件与 test/fixtures/slice_cases.json 属 T10 独占写域，**已由 0d329db（docs(parity): freeze forty two card parity slice）合入本树**，当前指纹为 01-slice.md 311 行 / 33817 B / sha256 897d36c7…、slice_cases.json 1459 行 / 52005 B / sha256 396cfc0f…；消费前仍应以工作树重算为准。reports/T10-C01-M10.json 的 files 字段（01-slice.md 27261 B/f0c126ee…、slice_cases.json 44957 B/2cd97957…）是合入前的历史指纹，不等于本树现值；同一报告的 reviewer.resumeHashNote 已把先前 resume 用的 39771fce… / 93d1f7e8… 标注为**过期**（F14/F15 之前），而 reports/T10-C01-M10-R.json 的 reviewedHashes 仍写着这一对过期值——因此任何报告里的摘要都不能当作当前切片指纹。
3. 逐候选按七条硬门判定；未跑候选继续标“未评估”。
4. 冻结拟议辅助指标所需的 Qt 同设备同场景基线。
5. G1（APK 哈希与 Qt 源码同 commit）闭合，否则 P1 不裁决（计划:105）。
6. 按 T16 卡的 shortest_commit 重新提交：单行标题 “docs: adjudicate qt to flutter host architecture”；返修另起新 commit，不 amend / squash（无正文、无署名、无 Coauthor、无人名、无模型供应商）。（本条描述**未来裁决提交**；本轮只冻结证据，提交标题 `docs(adr): freeze host architecture adjudication evidence`，不宣称已裁决。）

## 8. 未评估 / 未知

- 五候选的同切片实测数据：全部 UNMEASURED（0/5 已跑）。
- 器件级结论（像素、性能、旋转、稳定性）：DEVICE_BLOCKED，不可用模型假造。
- Qt 无障碍基线：不存在（AndroidWindow 关闭桥），待以新增设计处理。
- boot-lettering-art.json 契约补齐：未闭合（GRAPH-V2 M5）。
- 切片文件已在本树（0d329db 合入，指纹见 §7.2）；各控制面报告里的摘要互不一致且含已被标注 stale 的值（见 §7.2、§9），不得引用。
- Qt/CMakeLists.txt 的 owner：图中零覆盖（GRAPH-V2 M6，仅影响候选 B 的 Qt 侧注册接线）。
- 构建注册点（本卡不收口）：`Qt/src/render/SceneLayerHost.cpp` / `.h` 实际列在根 CMakeLists.txt:239-240 的 `RHINE_APP_SOURCES`（列表 :252 收尾）；Qt/CMakeLists.txt 共 31 行，:2 以 `qt_add_executable(RhineMusicDatabase WIN32 MACOSX_BUNDLE MANUAL_FINALIZATION ${RHINE_APP_SOURCES})` 消费该列表，:3 用 `target_sources(RhineMusicDatabase PRIVATE src/Gamepad.cpp src/Gamepad.h)` 追加源文件。因此计划 T12 的 “Modify Qt/CMakeLists.txt”（计划:472）是可用的注册点：`Qt/porting/*.cpp` 既可由根 `RHINE_APP_SOURCES` 收录，也可在 Qt/CMakeLists.txt 追加 `target_sources`，不存在“必须进根 CMakeLists.txt”的约束。本卡不改计划，记 GAP（计划未写明两处注册的取舍）。
- 文档与源码分歧（本卡 scope 外）：docs/ANDROID.md:528 称 Android 有两层离屏 QQuickWindow、由 PresentationShell::step() 手动驱动，与 Qt/src/main.cpp:1095-1100 冲突；以源码为准，文档待修。

## 9. 参考

- docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md
- docs/flutter-migration/02-adjudication.md（本卡矩阵）
- docs/flutter-migration/01-slice.md、test/fixtures/slice_cases.json（T10 独占写域；已由 0d329db 合入本树：311 行 / 33817 B / sha256 897d36c7…、1459 行 / 52005 B / sha256 396cfc0f…）
- .agents/parity-20261109/reports/T10-C01-M10.json、GRAPH-V2-REVIEW.json、GRAPH-001.json、T16-C14.json（控制面报告，非仓库内实现证据）
- Qt 源：Qt/src/NativeHud.h、Qt/src/NativeHud.cpp、Qt/src/Glyphs.cpp、Qt/src/PlayerBar.cpp、Qt/src/AndroidWindow.cpp、Qt/src/MusicAccount.cpp、Qt/src/SettingsSchema.cpp、Qt/src/BridgeProcess.h、Qt/src/BridgeProcessAndroid.cpp、Qt/src/BridgeProcessIOS.cpp、Qt/src/Host.h、Qt/src/Host.cpp、Qt/src/main.cpp、Qt/src/render/SceneLayerHost.h、Qt/src/render/SceneLayerHost.cpp、Qt/qml/Main.qml
- 构建：CMakeLists.txt（根，`RHINE_APP_SOURCES`）、Qt/CMakeLists.txt

---

本 ADR 为 pending-evidence 版本：结构、契约与分类完整，裁决待设备证据。
