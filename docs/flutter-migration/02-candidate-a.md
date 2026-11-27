# 候选 A（PlatformView 切片）：真实失败点与最小 Qt 适配面

- 计划卡：T11 候选 A（docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:462-469）；本文件对应 T11-S05。
- 基线：`3aa6706f91ae7c3c963a3866f27d28e8c63b20fd`
- 状态：**候选 A 失败点记录（未裁决）**。本文件不选赢家、不宣布候选 A 可用、不写 PASS。
- 证据等级：E1（直读源码行）；E0（真机安装/启动/截图/无障碍树）采集数 = **0**。
- 未执行：flutter test / dart test / build / analyze / run / Gradle / adb / Qt 编译 / pub get / formatter / 生成器 / 任何项目脚本。所有「行为」结论都标 UNMEASURED，不得读成已验证。

## 0. 状态与边界

| 项 | 逐字状态 | 依据 |
|---|---|---|
| 候选 A 是否胜出 | **未裁决**；矩阵全 UNMEASURED，赢家 UNASSIGNED | docs/flutter-migration/02-adjudication.md:72-80 |
| 候选源码可写性 | SHARED SOURCE 可写（候选源码） | 同上 :108-112 |
| 生产接线 | `ARCH_BLOCKED`（宿主/桥/平台通道的真实连线等 T16） | 同上 :110-111、:120-128 |
| 真机取证 | `DEVICE_BLOCKED`（像素、时序、旋转、IME、无障碍树） | 同上 :112、:123 |
| 本文件结论 | 候选 A 有 7 个结构失败点、9 项最小 Qt 适配面；结构性失败点已由 E1 证明，行为/像素/时序待实测，**不是**候选 A 的通过证据 | 本文件 §2-§9 |

候选 A 的声明形态是「Flutter 宿主 + Android PlatformView 承载 Qt 视图（QtQuickView 或自建 SurfaceView + Qt 渲染控制）」（02-adjudication.md:32）。本文件只核对**目前已落地的 QtQuickView 路径**；自建 SurfaceView 路径没有源码，不在本文件伪造。

## 1. 已落地但未接线（基线 3aa6706）

| 件 | 规模/入口 | 接线状态 |
|---|---|---|
| lib/platform/qt_platform_view.dart | 1116 行；`class QtPlatformView` :599；控制通道 :629；事件通道 :630；`initState` 装 handler :637-648 | 生产零构造点；只在 integration_test 里被构造（:493、:517、:650、:665、:710） |
| android/.../porting/QtPlatformViewHost.kt | 1108 行；`VIEW_TYPE` :174；`CONTROL_CHANNEL` :176；`EVENT_CHANNEL` :177；工厂 :752-757；`registerWith` :711-717 | `registerWith` 无产品调用；MainActivity.kt 全文无 `configureFlutterEngine`/`registerWith`（284 行，:42 类声明） |
| integration_test/slice_platformview_test.dart | 806 行；文件头 :1-16 声明「每一行断言一次都没跑过」；patch 建议 :34-47 | 不是运行证据；没有设备、没有 APK、没有截图 |
| lib/main.dart | 仍是 `flutter create` 计数器模板；`runApp(const MyApp())` :4 | 不引用 `QtPlatformView`，无根装配 |
| Qt android jar / .so / qt_libs | 本 Flutter 模块树内 `android/app/src/main/res` 无 `qt_libs`/`use_local_qt_libs`，`android/app/libs` 不存在 | 反射构造（QtPlatformViewHost.kt:669-688）；运行期 probe 预期 `archBlocked`，但「预期」不等于实测 |

**证据缺陷（只记录、不修改）**：docs/flutter-migration/adr/0001-host-architecture.md:120 仍写「MainActivity.kt 5 行 `class MainActivity : FlutterActivity()`，未注册任何 PlatformView」。基线实际 284 行（含返回键与沉浸式逻辑，仍无 PlatformView 注册）。该行号/行数已过期，任何复核以 MainActivity.kt 当前内容为准。

## 2. F1：QtActivity 不能作为普通 View 嵌入

| 事实 | 文件:行 |
|---|---|
| `QtActivity` 是 Activity 子类，不是 View | third_party/qt/qtbase/src/android/java/src/org/qtproject/qt/android/bindings/QtActivity.java:11（`extends QtActivityBase`） |
| `QtActivityBase` 继承 `android.app.Activity` | third_party/qt/qtbase/src/android/jar/src/org/qtproject/qt/android/QtActivityBase.java:30 |
| 可嵌入的是 `QtQuickView`：javadoc 明确「add QML content to your Android app as a View」 | third_party/qt/qtdeclarative/src/quick/platform/android/jar/src/org/qtproject/qt/android/QtQuickView.java:15-20 |
| `QtQuickView extends QtView`；`QtView` 是包内可见的 `ViewGroup` | QtQuickView.java:27；QtView.java:19 |
| 外部应用只能实例化 public 子类；QtView 本身包内可见 | QtPlatformViewHost.kt:606-609（archNotes 第 1-2 条） |
| 构造 QtQuickView 的 Context 必须是 Activity：`QtLoader` 构造器要求 baseContext 是 Activity/Service，否则抛 `IllegalArgumentException` | QtLoader.java:69-76 |
| `QtView.loadQtLibraries` 捕获该异常后直接 return：视图会建出来，但 Qt 不启动 | QtView.java:140-148 |
| 本项目的构造路径：反射 `QtQuickView(Context, qmlUri, appLibName[, qmlImportPaths])` | QtPlatformViewHost.kt:669-688；参数校验分三处：qmlUri 在 QtQuickView.java:83-86，qtAppLibraryName 在 QtView.java:79-82，qmlImportPaths 空项是宿主 validationErrors（QtPlatformViewHost.kt:742-748），不在 Qt 构造器内 |

**失败点**：把 `QtActivity` 当 View 塞进 PlatformView 在类型上不成立；若把 Application/Service 以外或非 Activity 的 Context 传给 QtQuickView，得到的是**空白 View 而非异常**。候选 A 的最小可行路径只有「Activity Context + QtQuickView」，且必须把空视图当失败上报，不能当 Qt 画面。

**判定**：结构失败点已由 E1 证明；真机表现 UNMEASURED。Qt 类 / `qt_libs` / `use_local_qt_libs` / Activity Context 缺失时 probe 给 `archBlocked`；仅 native `.so` 缺失时给 `deviceBlocked`（QtPlatformViewHost.kt:435-438）。

## 3. F2：FlutterActivity 宿主不是 QtActivityBase，窗口几何/safe area 两条闸门失效

| 事实 | 文件:行 |
|---|---|
| `QtWindow.setGeometry` 只在 `getContext() instanceof QtActivityBase` 时写 LayoutParams | QtWindow.java:338-345 |
| Flutter 宿主是 `FlutterActivity`，不是 `QtActivityBase` | MainActivity.kt:42；QtActivityBase.java:30 |
| 尺寸变化仍有一条真实路径：`QtView` 构造器注册 `addOnLayoutChangeListener`，尺寸变化时调 native `resizeWindow(windowRef,left,top,w,h)` | QtView.java:50-66（:54-66；:63 resizeWindow） |
| safe area 监听器有同一道闸门：非 `QtActivityBase` 直接 return | QtWindow.java:90-93 |
| 宿主自己的状态表已承认这两个 owner | QtPlatformViewHost.kt:634-641（resizeOwner=`qtview-layout-listener`；safeAreaOwner=`unavailable-no-qactivitybase`） |

**失败点**：候选 A 不能调用 `QtWindow.setGeometry`（被闸门丢弃），也不能从 Qt 拿到 safe-area 边距。宿主只能提供真实 View 尺寸，让 `QtView` 的 layout listener 去 resize；安全区必须由 Flutter 侧自己算，且不能假装 Qt 已经收到。**这是换宿主的代价，不是 Qt 的缺陷**（QtPlatformViewHost.kt:634）。

**判定**：结构失败点 E1；旋转/resize/safe-area 的实际像素与命中 UNMEASURED（DEVICE_BLOCKED）。

## 4. F3：输入与 IME 的唯一入口是包内可见的 QtInputDelegate，宿主拿不到

| 事实 | 文件:行 |
|---|---|
| `QtInputDelegate` 类声明无 `public`（包内可见） | third_party/qt/qtbase/src/android/jar/src/org/qtproject/qt/android/QtInputDelegate.java:34 |
| 触摸从 `QtWindow.onTouchEvent` 进入，直接调 `QtInputDelegate.sendTouchEvent(event, getId())` | QtWindow.java:246-266（:262） |
| 软键盘唯一入口是 `QtInputDelegate.showSoftwareKeyboard(Activity,...)`，由 Qt C++ 侧驱动 | QtInputDelegate.java:214-240；QtPlatformViewHost.kt:642-646（archNotes 的 imeOwner） |
| `QtEditText` 只在 `context instanceof Activity` 时创建：非 Activity 上下文没有 IME 载体 | QtWindow.java:63-74 |
| Flutter 侧把整块手势全量交给平台视图（EagerGestureRecognizer），宿主不再做坐标映射 | lib/platform/qt_platform_view.dart:849-853（textureLayer）、:898-902（viewComposition）；QtPlatformViewHost.kt:652-655 |
| 宿主已有「不得自行 show/hide 键盘、不得抢设 windowSoftInputMode」的冻结说明 | QtPlatformViewHost.kt:642-646 |

**失败点**：宿主（Kotlin/Dart）**不能**直接调用 QtInputDelegate 的触摸或 IME API；触摸只能经 Android View 分发到 QtWindow，IME 只能等 Qt 自己经 QtInputInterface 拉起。Qt 视图 ready 之前，任何「先让 Flutter 弹键盘再交给 Qt」的方案都没有入口；不能用 Flutter 的 TextField 冒充 Qt 输入。

**判定**：结构失败点 E1；触摸坐标、IME 提交/selection/focus、时延 UNMEASURED（DEVICE_BLOCKED）。

## 5. F4：Qt 生命周期由 QtEmbeddedDelegate 自己注册，宿主双写会造成状态交替

| 事实 | 文件:行 |
|---|---|
| `QtView` 构造时创建 `QtEmbeddedViewInterface` | QtView.java:50-53 |
| 工厂对 Activity 上下文创建 `QtEmbeddedDelegate` | QtEmbeddedViewInterfaceFactory.java:16-20 |
| `QtEmbeddedDelegate` 在构造器里 `registerActivityLifecycleCallbacks` | QtEmbeddedDelegate.java:28-33 |
| resumed → `ApplicationActive` + `QtWindow.updateWindows()` | 同上 :42-47 |
| paused → `ApplicationInactive`（多窗口例外） | 同上 :50-57 |
| stopped → `ApplicationSuspended` | 同上 :60-64 |
| destroyed → 反注册；非配置变更时 `terminateQtNativeApplication` | 同上 :70-81 |
| 宿主通道只记录、不驱动 Qt 状态 | QtPlatformViewHost.kt:931-938；Dart 也只上报观测值 lib/platform/qt_platform_view.dart:669-680 |

**失败点**：候选 A 若在 Flutter 生命周期里再调 `QtNative.setApplicationState`，会与 QtEmbeddedDelegate 的回调形成双写，Qt 可能看到交替状态。宿主只能观测/对账，不能成为第二驱动源。另一方面，Activity 必须是真正的前台 Activity；用 Application context 构造时工厂不会创建 delegate（QtEmbeddedViewInterfaceFactory.java:19-23），生命周期链直接缺失。

**判定**：结构约束 E1；后台/前台切换、旋转重建、多窗口的实际状态连续性 UNMEASURED（DEVICE_BLOCKED）。

## 6. F5：窗口形态（横屏/全屏/沉浸式）在 Flutter 宿主下没有对应实现，且 Qt 侧仍可能抢窗口

| 事实 | 文件:行 |
|---|---|
| Qt 原路径固定 `sensorLandscape=6`、全屏 flags、immersiveSticky | Qt/src/AndroidWindow.cpp:16、:18、:22 |
| `applyWindowShape()` 调 `setRequestedOrientation(6)`、`addFlags`、`setSystemUiVisibility` | 同上 :25-51 |
| `configureAndroidWindow` 在启动时调 `ensureStarted`、`applyWindowShape`、`showFullScreen` | 同上 :73-91 |
| 候选 A 侧没有任何 `SystemChrome`/`setPreferredOrientations`/`SystemUiOverlayStyle` 实现 | grep lib/android/test 零命中；lib/platform/qt_platform_view.dart:493-507 只有常量与 isLandscape() 纯函数，无系统调用 |
| 宿主状态注释：换 Flutter 宿主后不能再由 Qt 抢窗口，需 Flutter 侧对齐 | QtPlatformViewHost.kt:629-630 |

**失败点**：Qt 的 Android 窗口集成原本假设 QtActivity 是窗口宿主；候选 A 用 FlutterActivity 承载 QtQuickView 后，`AndroidWindow.cpp` 的 `applyWindowShape` 是否仍会被调用、由谁调用、是否会反过来锁横屏，**没有任何静态或实测证据**。在 T16 裁决与 DEDUP-39 的绑定裁决下，候选 A **不得**用「Qt 原来就锁横屏」作为理由锁横屏，也不得把 Qt 的窗口形态当作已适配。宿主必须自己拥有窗口形态（双方向、resumed 重放），并把 Qt 侧的行为当作待测风险。

**判定**：T16_PENDING + DEVICE_BLOCKED；当前无实现、无证据。

## 7. F6：合成模式选错就拿不到 Qt 像素（QtSurface vs QtTextureView）

| 事实 | 文件:行 |
|---|---|
| `QtWindow.createSurface`：`surfaceContainerType==0` → `QtSurface`（SurfaceView），否则 `QtTextureView` | QtWindow.java:303-325（:312-317） |
| Flutter 默认 `AndroidView` 走 TLHC/纹理合成；SurfaceView 无法被纹理化 | /home/aibeto/flutter/packages/flutter/lib/src/services/platform_views.dart:131-133 |
| Hybrid Composition 必须用 `initExpensiveAndroidView` | 同上 :190-194；lib/platform/qt_platform_view.dart:872-887 |
| Dart 默认合成模式是 `textureLayer` | lib/platform/qt_platform_view.dart:606、:838-856 |
| 模式不匹配时显式渲染不可用面板，不把空白当 Qt 画面 | 同上 :809-824 |
| 探针只有在视图树出现后才能判定 `surfaceContainerKind` | QtPlatformViewHost.kt:550-602（:580-591） |

**失败点**：Qt 若选 `QtSurface`，默认 `textureLayer` 一定拿不到像素；但合成模式在**创建前**必须由 Dart 决定，而 `surfaceContainerKind` 要等创建后 `refreshProbe` 才能扫描到。这是一段真实的先有鸡还是先有蛋：首帧可能只能拿到「模式不匹配」诊断，再按 probe 结果重建为 `viewComposition`。候选 A 必须接受「第一次创建可能不产生 Qt 像素」，不得用静态截图或空白 View 冒充首帧成功。

**判定**：结构失败点 E1；首帧、重建时序、像素正确性 UNMEASURED（DEVICE_BLOCKED）。

## 8. F7：Qt 产物/资源未进本 Flutter 模块，probe 静态预期 archBlocked

| 事实 | 文件:行 |
|---|---|
| probe 判定顺序：类 → 资源 → Activity → native 库 | QtPlatformViewHost.kt:399-438 |
| 缺类/缺 `qt_libs`/缺 `use_local_qt_libs`/Context 非 Activity → `archBlocked` | 同上 :430-438 |
| 缺 native Qt 库 → `deviceBlocked` | 同上 :437 |
| Qt android jar 不在本工程 classpath，故用反射；缺 Qt 应成为可读状态而不是编译失败 | 同上 :662-668 |
| 本树 `android/app/src/main/res` 无 `qt_libs`/`use_local_qt_libs`；`android/app/libs` 不存在 | 静态 grep（本文件 §1） |
| 本树 gradle 的 dependencies 只有 junit（:161），未见 Qt jar/so 依赖；:92-111 只有 SDK pin（DEDUP-43 注释） | android/app/build.gradle.kts:90-161 |

**失败点**：在当前 Flutter 模块里，probe 的静态预期是 `archBlocked`（缺 androiddeployqt 生成的 `qt_libs` 资源与 native 库），而不是「Qt 已可用」。候选 A 需要一条真实的 Qt 产物打包路径（androiddeployqt 输出、Qt android jar、.so、qml 资源）；没有它，注册与 PlatformView 创建都只会得到诊断状态。**注意**：源码树缺失不排除构建系统注入，是否注入未验证；本文件只记录「当前树内没有」。

**判定**：ARCH_BLOCKED（打包/接线）+ UNMEASURED（构建注入是否存在）。

## 9. 最小 Qt 适配面（不是修复，只是换宿主的代价）

| # | 适配点 | 最小形态 | 证据 | 状态 |
|---|---|---|---|---|
| Q1 | Activity Context | 只传真实 Activity；禁止 Application/Service 上下文；空视图按失败上报 | QtLoader.java:69-76；QtView.java:140-148；QtPlatformViewHost.kt:669-688 | E1 已证；设备表现 UNMEASURED |
| Q2 | 工厂注册 | MainActivity 在 `configureFlutterEngine` 调 `registerWith(engine)`；只此一处 | 本文件 §1；MainActivityPatch-T11.md；QtPlatformViewHost.kt:711-717 | ARCH_BLOCKED（T16 applier） |
| Q3 | 几何/resize | 不用 `QtWindow.setGeometry`；给 QtView 真实尺寸，靠它的 layout listener resize | QtWindow.java:338-345；QtView.java:54-66 | E1 约束；旋转/resize UNMEASURED |
| Q4 | safe area | Flutter 侧自己算 insets；不假装 Qt 已收到 | QtWindow.java:90-93；QtPlatformViewHost.kt:639-641 | E1 约束；边距正确性 UNMEASURED |
| Q5 | 触摸 | 不自算坐标、不消费事件；EagerGestureRecognizer 全量交出，让 QtWindow.onTouchEvent 走 Qt | QtWindow.java:246-266；qt_platform_view.dart:849-853 | E1 约束；命中/时延 UNMEASURED |
| Q6 | IME | 不自行 show/hide；等 Qt 经 QtInputInterface 拉起；视图 ready 前不承诺输入 | QtInputDelegate.java:214-240；QtPlatformViewHost.kt:642-646 | E1 约束；IME 全链 UNMEASURED |
| Q7 | 生命周期 | 只观测 Flutter 状态；不调 `QtNative.setApplicationState`；让 QtEmbeddedDelegate 驱动 | QtEmbeddedDelegate.java:33-82；QtPlatformViewHost.kt:931-938 | E1 约束；前后台/重建 UNMEASURED |
| Q8 | 合成 | probe 报 `surface-view` 时改用 `initExpensiveAndroidView`；默认 textureLayer 不假设能画 | platform_views.dart:131-133、:190-194；qt_platform_view.dart:809-824、:872-905 | E1 约束；首帧/时序 UNMEASURED |
| Q9 | 窗口形态 | Flutter 自己拥有双方向/resumed 重放；不采用 Qt 的 sensorLandscape；确认 Qt 侧不再抢窗口 | Qt/src/AndroidWindow.cpp:16-51、:73-91；QtPlatformViewHost.kt:629-630 | T16_PENDING + DEVICE_BLOCKED |

## 10. 必须实测、当前没有数据的项

| 项 | 状态 | 说明 |
|---|---|---|
| 首帧是否出现 Qt 像素 | UNMEASURED / DEVICE_BLOCKED | 无 APK、无设备、无截图 |
| 触摸坐标与命中是否一致 | UNMEASURED / DEVICE_BLOCKED | 无 MotionEvent 记录、无 hit 对照 |
| IME 提交/selection/focus | UNMEASURED / DEVICE_BLOCKED | 宿主无入口，Qt 侧未跑 |
| 旋转/前后台后状态连续性 | UNMEASURED / DEVICE_BLOCKED | 无旋转记录 |
| 无障碍树 | UNMEASURED / DEVICE_BLOCKED | QtWindow 设 `IMPORTANT_FOR_ACCESSIBILITY_NO`（QtWindow.java:54），Qt 无障碍桥默认关（QtPlatformViewHost.kt:631-633） |
| 30 分钟稳定性 | UNMEASURED / DEVICE_BLOCKED | 无长时间运行 |
| 媒体会话 | UNMEASURED / ARCH_BLOCKED | 候选 A 不启动 MediaSession；见 android-host.md 的 DEDUP-35/38/40 契约 |

## 11. 禁止的假结论

| 禁止 | 为什么 |
|---|---|
| 用静态截图、布局图、QML 预览图证明「已嵌入」 | 计划 T11 Fail 出口（plan:467）；E0 必须来自真机 |
| 把 `registerWith` 成功 / 工厂注册成功写成「Qt 可用」 | 注册只路由创建请求；verdict 由 probe 决定（QtPlatformViewHost.kt:705-709） |
| 把空白 View 或诊断面板说成「Qt 首帧」 | 未就绪时容器是空的，QtPlatformViewHost.kt 中 QtPlatformView 的类注释 :760-765 明确不放假贴图 |
| 在 surface-view 场景继续用 textureLayer 并宣称有画面 | TLHC 拿不到 SurfaceView 像素（platform_views.dart:131-133） |
| 为了「看起来像 Qt」而锁横屏 | 与 T16/DEDUP-39 的双方向裁决冲突；本文件不授权 |
| 把本文件的 7 个失败点写成「候选 A 已失败/已胜出」 | 本文件只登记结构性失败点与适配面，最终判定仍 UNMEASURED，赢家 UNASSIGNED |

## 12. 证据索引

| 事实 | 文件:行 |
|---|---|
| 候选 A 的 Create/Modify/Fail | docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:462-469 |
| 五候选未裁决、矩阵 UNMEASURED、winner UNASSIGNED | docs/flutter-migration/02-adjudication.md:30-36、:72-80 |
| 生产接线 ARCH_BLOCKED / 真机 DEVICE_BLOCKED | 同上 :108-128 |
| 候选 A 源码规模与入口 | lib/platform/qt_platform_view.dart:599、:629-630、:637-648、:744-753、:781-786、:838-856、:872-905（文件 1116 行） |
| 宿主工厂/注册/探针/反射 | android/app/src/main/kotlin/rhine/music/database/porting/QtPlatformViewHost.kt:174-177、:399-438、:550-602、:605-659、:669-688、:711-717、:752-757、:922-941（文件 1108 行） |
| MainActivity 现状 | android/app/src/main/kotlin/rhine/music/database/MainActivity.kt:42、:54-66（文件 284 行；无引擎注册） |
| 测试未执行声明与 patch 建议 | integration_test/slice_platformview_test.dart:1-16、:34-47 |
| QtActivity 不是 View / QtQuickView 是 View | QtActivity.java:11；QtActivityBase.java:30；QtQuickView.java:15-27；QtView.java:19 |
| QtLoader 的 Activity/Service 要求与 loadQtLibraries 捕获 | QtLoader.java:69-76；QtView.java:140-148 |
| QtWindow 的几何/safe-area 闸门 | QtWindow.java:90-93、:338-345 |
| QtInputDelegate 包内可见 / 触摸 / IME | QtInputDelegate.java:34、:214-240、:654-708；QtWindow.java:246-266 |
| Qt 生命周期回调 | QtEmbeddedViewInterfaceFactory.java:16-20；QtEmbeddedDelegate.java:28-33、:42-47、:50-57、:60-64、:70-81 |
| Qt 窗口形态 | Qt/src/AndroidWindow.cpp:16-22、:25-51、:73-91 |
| Flutter 合成 API | /home/aibeto/flutter/packages/flutter/lib/src/services/platform_views.dart:131-133、:190-194 |
| 已过期的 ADR 行 | docs/flutter-migration/adr/0001-host-architecture.md:120（称 MainActivity 5 行；实际 284 行） |

---

**结论（不是裁决）**：候选 A 的源码已落地但生产接线为零；上述 7 个结构失败点和 9 项最小适配面都有 file:line 证据，但没有任何 E0 数据。候选 A 仍为 **UNMEASURED**，赢家 **UNASSIGNED**；本文件不构成 T16 裁决，也不构成候选 A 的通过或失败结论。
