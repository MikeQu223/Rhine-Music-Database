# MainActivity 引擎注册补丁请求（T11-S04）

- 计划卡：T11 候选 A（docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:462-469）
- 本文件原子：T11-S04（只写本文件；**不应用**补丁）
- 基线：`3aa6706f91ae7c3c963a3866f27d28e8c63b20fd`
- 状态：**PATCH REQUEST / 未应用**。MainActivity.kt 是共享文件，不在本卡写域；本文件只向 T16 的装配方提交一份可逐行核对的补丁请求。
- 证据等级：E1（直读源码行）。没有执行 build / test / analyze / run / Gradle / adb / flutter / dart / pub get / formatter / 任何项目脚本。
- 本文件**不**声称：注册已生效、PlatformView 可创建、Qt 可用、候选 A 胜出、T16 已裁决。注册只是让创建请求能被路由到工厂，见 §3 与 QtPlatformViewHost.kt:705-709。

## 0. 边界

| 项 | 结论 | 依据 |
|---|---|---|
| MainActivity.kt 谁改 | 只有 T16 的装配方（唯一 applier）。本卡只读、只请求 | docs/flutter-migration/02-adjudication.md:110-111 把生产接线判为 ARCH_BLOCKED；QtPlatformViewHost.kt:658-659 明确「本 atom 不注册 PlatformViewFactory、不改 MainActivity」 |
| 本补丁改变什么 | 仅把已存在的 `QtPlatformViewHost.registerWith(engine)` 接到引擎就绪点 | QtPlatformViewHost.kt:694-717 |
| 本补丁不改变什么 | 返回键、沉浸式、权限、媒体会话、Manifest、Gradle、Dart、业务语义 | 本文件 §5 |
| 完成判据 | 静态 diff 正确 + 单次调用；**不是**运行成功、不是画面可用、不是 T16 结论 | 本文件 §6 |

## 1. 当前事实（基线 3aa6706）

| 事实 | 文件:行 |
|---|---|
| MainActivity.kt 共 284 行；类声明 `class MainActivity : FlutterActivity()` | android/app/src/main/kotlin/rhine/music/database/MainActivity.kt:42 |
| 现有 import 到 `FlutterActivity` 与 `QtPlatformViewHost` 为止；**没有** `FlutterEngine` import | 同上 :14-15 |
| 全文**没有** `configureFlutterEngine`，**没有** `registerWith` 调用 | 同上（逐行读 1-284；全文无此标识符） |
| onCreate 只做两件事：注册返回回调、应用沉浸式；不碰 PlatformView | 同上 :54-66（:62、:65） |
| 装配入口已实现但无人调用 | android/app/src/main/kotlin/rhine/music/database/porting/QtPlatformViewHost.kt:711-717 |
| 工厂已实现 | 同上 :752-757（`QtPlatformViewFactory.create`） |
| 注册实现注释：只应在 `configureFlutterEngine`（或等价 engine 已就绪处），不能 Application.onCreate | 同上 :700-710 |
| 树内 `registerWith` 调用点：仅声明处 + 测试文件注释；**无产品调用** | grep `registerWith(` → QtPlatformViewHost.kt:711；integration_test/slice_platformview_test.dart:27、:36、:38 均为注释 |
| 测试文件已写好同一 patch 建议 | integration_test/slice_platformview_test.dart:34-41 |

## 2. 请求的补丁（精确形态）

目标文件：`android/app/src/main/kotlin/rhine/music/database/MainActivity.kt`。

插入点 A：import 区，在现有 :14 `import io.flutter.embedding.android.FlutterActivity` 之后、:15 `import rhine.music.database.porting.QtPlatformViewHost` 之前，加入 1 行：

```kotlin
import io.flutter.embedding.engine.FlutterEngine
```

插入点 B：在现有 :42 `class MainActivity : FlutterActivity() {` 之后、:43 空行保留不动；在 :43 空行之后、:44 的 KDoc `/**` 之前，加入 4 行方法 + 1 个尾空行（不新增前导空行）：

```kotlin
override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    QtPlatformViewHost.registerWith(flutterEngine)
}
```

两处合计新增 6 行（1 import + 5 行方法/尾空行）；不删除、不改写任何既有行。

补丁内容合计：+1 import、+5 方法/尾空行（override、super、registerWith、闭合括号、尾空行）。**不得改动**既有 284 行的任何一行；不得重排 import 以外的东西；不得改类声明、onCreate、onResume、HostBackDispatcher。

等价的完整方法（若 applier 手工插入）：

```kotlin
override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    QtPlatformViewHost.registerWith(flutterEngine)
}
```

## 3. 为什么必须是 `configureFlutterEngine`

| 事实 | 文件:行 |
|---|---|
| `FlutterActivity.configureFlutterEngine` 是子类配置引擎的官方 hook；基类实现自动注册 pubspec 插件（engine 由 host 显式注入时跳过，见 FlutterActivity.java:1348-1352） | /home/aibeto/flutter/engine/src/flutter/shell/platform/android/io/flutter/embedding/android/FlutterActivity.java:1335-1356（:1347 方法，:1355 registerGeneratedPlugins） |
| 该方法由 delegate 在 Activity 启动路径中、`provideFlutterEngine` 之后调用 | /home/aibeto/flutter/engine/src/flutter/shell/platform/android/io/flutter/embedding/android/FlutterActivityAndFragmentDelegate.java:228（`host.configureFlutterEngine(flutterEngine)`） |
| 引擎已就绪后才能取 `PlatformViewsController` | /home/aibeto/flutter/engine/src/flutter/shell/platform/android/io/flutter/embedding/engine/FlutterEngine.java:688-695 |
| 工厂注册的真实 API 是 `PlatformViewRegistry.registerViewFactory(viewTypeId, factory)` | /home/aibeto/flutter/engine/src/flutter/shell/platform/android/io/flutter/plugin/platform/PlatformViewRegistry.java:14-23 |
| 本项目已按此形态写好实现 | android/.../QtPlatformViewHost.kt:700-703 的 snippet 与 :711-717 的实现 |

**禁止**放在 `Application.onCreate`：那时 FlutterEngine 尚未创建，`registerWith` 没有合法实参；强接只会把未初始化引擎带进注册路径。这不是风格问题。

## 4. 调用约束

1. **每次引擎一次**：`registerWith` 内部调用 `registerViewFactory`；同一 `viewTypeId` 重复注册返回 `false`（PlatformViewRegistry.java:16-23），不抛异常，但会产生「日志说已注册、实际未替换」的假象。MainActivity 未使用 cached engine，默认一 Activity 一引擎，一次调用即可。
2. **super 必须先调**：不调 `super.configureFlutterEngine` 会跳过基类的插件自动注册（FlutterActivity.java:1339-1344 明确该语义）。本补丁保留 super。
3. **不加重试、不加 try/catch**：注册本身是内存表写入；失败会在后续创建 PlatformView 时以 `IllegalStateException`（unregistered type，PlatformViewsController.java:517-522）暴露，不应在启动路径吞掉。
4. **不注册第二个 viewType**：`VIEW_TYPE` 是 `QtPlatformViewHost` 的常量（:174），本补丁不复制字符串。
5. **不改 Manifest**：PlatformView 注册与 `<activity>`/`<service>` 声明无关。

## 5. 非目标（补丁不得携带）

| 不得做 | 原因 |
|---|---|
| 改返回键 / 沉浸式 / IME 逻辑 | 与本卡无关；MainActivity 已有 DEDUP-37/T11 之外的契约 |
| 改 Manifest、Gradle、权限、媒体会话 | 本卡写域外；且候选 A 不能顺手做产品接线 |
| 改 Dart（`lib/platform/qt_platform_view.dart`、`lib/main.dart`） | 本卡只请求 Kotlin 装配点；Dart 侧候选源码已落地但未挂载 |
| 在 Application.onCreate 注册 | 引擎未就绪 |
| 把「注册成功」写成「Qt 可用 / 候选 A 通过 / T16 裁决」 | 注册只路由创建请求；verdict 仍由 probe()/probeQtSubtree() 决定（QtPlatformViewHost.kt:705-709） |
| 以静态截图、布局图、源码常量冒充嵌入证据 | 计划 T11 Fail 出口（plan:467） |

## 6. applier 的静态验收（只读，不跑）

| # | 检查 | 期望 |
|---|---|---|
| 1 | `grep -n 'import io.flutter.embedding.engine.FlutterEngine' MainActivity.kt` | 恰好 1 行 |
| 2 | `grep -n 'override fun configureFlutterEngine' MainActivity.kt` | 恰好 1 行 |
| 3 | 方法内第一句 | `super.configureFlutterEngine(flutterEngine)` |
| 4 | 方法内第二句 | `QtPlatformViewHost.registerWith(flutterEngine)` |
| 5 | `git diff --stat` | 仅 MainActivity.kt；+6/-0（1 import + 5 行方法/尾空行） |
| 6 | 既有 284 行 | 无删除、无重排（除 import 插入） |
| 7 | 构建/测试 | **本卡不执行**；applier 若执行，另开证据，不写进本文件 |

## 7. 证据索引

| 事实 | 文件:行 |
|---|---|
| 计划卡 T11 候选 A 的 Create/Modify/Fail | docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:462-469 |
| 生产接线 ARCH_BLOCKED | docs/flutter-migration/02-adjudication.md:110-111、:120-128 |
| MainActivity 类声明 / onCreate / 无引擎注册 | android/app/src/main/kotlin/rhine/music/database/MainActivity.kt:42、:54-66、全文 |
| 工厂 / 注册入口 / 调用约束注释 | android/app/src/main/kotlin/rhine/music/database/porting/QtPlatformViewHost.kt:752-757、:711-717、:694-710 |
| Flutter 引擎 hook 与 API | FlutterActivity.java:1335-1356；FlutterActivityAndFragmentDelegate.java:228；FlutterEngine.java:688-695；PlatformViewRegistry.java:14-23 |
| 测试内同一 patch 建议（未执行） | integration_test/slice_platformview_test.dart:1-16（未执行声明）、:34-41（patch 建议） |

---

本文件是**补丁请求**，不是补丁应用记录。落盘后 MainActivity.kt 仍为 284 行、仍无 `configureFlutterEngine`；直到 T16 的 applier 合并并另行取证前，候选 A 的注册路径保持 **ARCH_BLOCKED**。
