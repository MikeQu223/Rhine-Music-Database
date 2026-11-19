# Rhine 音乐库 Qt→Flutter 并行：技术现状存档（截至 2026-11-19）

> 来源：`.agents/parity-20261109/` 报告与 control JSON + 仓库实读（feat/flutter tip = 「播放条补上封面字段…」，`v0.3.1-874`；该 commit 的 hash 当天被历史重写改过多次，见 control-plane 文档 §1）。凡标"未实测"处均为证据缺口，不做推断。
>
> 该目录已于 2026-11-19 删除（见 [2026-11-19-control-plane.md](2026-11-19-control-plane.md)）。文中 `reports/<名>`、`HANDOFF-*.md`、`builds/<任务>-<日期>/` 一类路径均指删除前的控制面，属**控制面口径**，未在仓库内复核；保留它们是为了在 `git log`/分支里找回对应实验。

## 1. 现状（2026-11-19）：架构与交付物

| 层 | 归属 | 证据 |
|---|---|---|
| 曲库/播放/账号/设置/插件 | **Flutter 唯一权威**（Siren） | `reports/LEAD-EMBEDDED-AUTHORITY-20261116.md:1-6` |
| 3D 场景渲染、材质、相机、5 列×8 槽几何、拖拽/命中 | **Qt**（行为与视觉权威） | `HANDOFF-20261115-NATIVE-QT.md` |
| Android HUD | **Flutter 绘制**（`lib/basic/basic_hud.dart`）；Qt `Hud{}` 只在 `Qt/qml/Overlay.qml:81`（`Qt/src/render/PresentationShell.cpp:231` 加载），嵌入路径为死代码 | `HUD-LAYERED-MEASURE-20261118.md`（logcat `HUDFLOW sync` 出现 0 次） |
| 打包 | 单 APK `rhine.music.database`，只由 Flutter 工程产出（`83cdb2b` 封堵纯 Qt 打包） | `docs/ANDROID.md:36-55` 仍只写 Qt 侧 `npm run build:android`，Flutter 构建未进正典文档（**迁移时须补**） |
| 渲染后端 | Impeller **关闭** → Skia(OpenGL)。`android/app/src/main/AndroidManifest.xml:36-38` `EnableImpeller=false`（`46e2dc7`）；设备 `gfxinfo` 实测 `Pipeline=Skia (OpenGL)` | `VULKAN-DEVICE-LOST-CRASH-20261119.md:1-40` |
| 场景宿主 | PlatformView + ImageReader `1800x2880 maxImages=3`，`frameSwapped` 驱动，一进程一视图 | `VULKAN-…md`、`LEAD-COVER-CONTRACT-20261116.md`（禁第二个视图/播放后端） |

关键未落地项：Qt 嵌入路径仍在构造完整业务后端后才进 embedded 分支（`Qt/src/main.cpp:1055-1059` 早于 `:1066`；`Qt/src/Engine.cpp:48-66` 无条件 `app->initialize()`），render-only 闸门是 MUST 但仍未收口。竖屏 UI 已移植（`99cd87c`、`2f91a68` 等）但**只有截图证据**（`builds/PORTRAIT-PORT-20261119/device1..15`），无数字报告。

## 2. 设备实测结论表（526f6b6d）

| 实验 | 提交 | 数字 | 结论 |
|---|---|---|---|
| HUD 双纹理分层 | `9ded703`（原 `4b49667`+ `dd346ff`，合并 `d49851be`/`46dd61d`） | 54→57 fps；≥80ms 18→18；≥200ms 16→14；GPU busy 77.3% | **无实质收益**，且 Qt HUD 不在嵌入树 |
| HUD 预算 8→4 ms | `795394f` | HWUI 47→54 fps；≥80ms 20→18；≥200ms 14→16；GPU completion >100ms 38→34；冻结占比 15.5% | 节拍常量非瓶颈 |
| 帧在途上限 1 | `cf9cfcf` → revert `ea15a947` | 57→55 fps；≥80ms 18→19；GPU 等待 max 373→502.6 ms；QtThread max 460.9 ms | 无收益已回退，重编 APK 字节一致（`be38551b…`） |
| 列表惯性 | `3f6d133` | 慢滑 01→04；快抛 04→14(+250ms)→28(+2s)，松手走约 24 行 | 手感=PASS（真机） |
| 帧节奏（只读） | — | 8.39 s/306 帧 ≈28 fps；p95 50 ms；max 416.66 ms；21.2% >16.67 ms；松手尾 ≈57 fps；键盘 40 连按 39.2% >16.67 ms | 触摸拖拽最贵 |
| 3D boot 通道 | — | 20.16–33.24 s 587 帧 44.9 fps；20 个 >100 ms 空档仅 4 个真长帧（352/294/317/142 ms） | 多数空档是"没产帧" |
| GPU fence 饥饿 | — | 冻结期 GPU 900 MHz、busy 99.5–99.9%；fence 等待 261.1/261.5/262.0/262.4 ms（抖动<1.3 ms）；Qt 静止时 RenderThread max 8.0 ms | 冻结需 Qt 持续产帧；非降频/非 2 缓冲饥饿 |
| 渲染倍率 50% | `fa2d671`（倍率即时生效） | `gfxinfo-50.txt`：47 帧 **100% janky**，p50 30 ms，p95 81 ms，GPU p50 5 ms，Slow UI thread 36 | 降分辨率不动 CPU/UI 线程瓶颈（印证 `docs/ANDROID.md:447`） |
| Impeller A/B | — | Impeller 3/3 崩于 iter 10/27/58（90 s 内）；Skia GL 320 轮 0 崩 | 退回 Skia GL |

## 3. 已知缺陷与根因

| # | 缺陷 | 根因/证据 | 状态 |
|---|---|---|---|
| 1 | 竖屏 SIGSEGV（pid 29725/19309/6231，reason=2 status=11，无 tombstone） | ImageReader 3 缓冲被击穿：`AdrenoUtils Memory Layout validation failed`→`GraphicBufferAllocator Failed to allocate (4x4)`→`khr_swapchain_impl_vk.cc:492 ErrorDeviceLost`→`dequeueBuffer exceed max dequeued buffer count (3)`→`:400 Timeout`→`gpu_surface_vulkan_impeller.cc:102`→`libsigchain` SIGSEGV | 已止血（关 Impeller），根治未做；备选 `maxImages=5–6` 未验证 |
| 2 | Qt 消费端太慢（460 ms/帧、GPU 99.9%） | 同上根因的生产端：消费慢→击穿缓冲 | 未解决 |
| 3 | Qt 宿主生命周期泄漏 | 5 轮 Back 后唯一 MainActivity（destroyed/finished=1、resumed=0）仍被 JNI global `RhineQtView.mContext`/`QtWindow.mContext` 持有；2063 对象含已退休 FlutterJNI | **FAIL**；`QT-LIFETIME-172` 状态 `SDK_FAILED_FROZEN_NO_EXECUTION_LEASE` |
| 4 | 第 4 次重开 SIGABRT | `FORTIFY: pthread_mutex_lock called on a destroyed mutex (0xb400006cd8e0ee84)`：QtThread → `Surface::hook_queueBuffer` → `libvulkan QueuePresentKHR` → `QRhi::endFrame` | 代码原因未独立定位 |
| 5 | null-SurfaceFrame 崩溃 | `AndroidExternalViewEmbedder::CreateSurfaceIfNeeded`→`frame->Canvas()` 空解引用（本地 `external_view_embedder.cc:144-154` 无 null 检查） | `UNSTABLE_SECOND_SAME_SIGNATURE_SIGSEGV` |
| 6 | 手势/输入 | 未决：列表滑动、上下按钮、左右按钮绑定、唱片左右旋转；实际 controller 是 `lib/basic/siren_controller.dart`，`lib/basic/qt_scene_view.dart:46-49` 为 `const` 构造不传状态 | 部分修复（滚轮/惯性已 PASS） |
| 7 | 冷启动 70.5% 黑面 | 启动页未按舞台尺寸布局 | 已修 `2250e6b`（merge `35df20f`） |

## 4. 构建 / 测试 / 取证流程

* 工具链：`/home/aibeto/flutter/bin/flutter` 3.47.8（Dart 3.13.7，framework `737ba8f885dc`，engine `cf636b1dfb81`）；Android SDK `/home/aibeto/Android/Sdk`；NDK 30.0.16248370；JDK 21；Qt kit `output/dependencies/qt-android`。
* 构建：`RHINE_QT_ANDROID_DEPLOY_DIR=<deploy> flutter build apk --debug --target-platform android-arm64`；11-19 实际 deploy = `builds/FLUTTER-ONLY-ANDROID-20261117/qt-native/Qt/android-build`（`RENDER-SCALE-LIVE-20261119/logs/build.log`）。Gradle 强制 `patchQtAndroidJar` → `android/app/javapatch/apply.sh`，按 **class 内容 sha256** 校验三个类（`QtEmbeddedDelegate`/`QtView`/`QtClipboardManager`，`android/app/build.gradle.kts:214-222`），jar_sha256 `9159cc5e…`。
* APK 纪律：`app-debug.apk` 每次覆盖 ⇒ 必拷独立名 + 写 `apk-sha.txt`（sha256+字节数）。历史：`be38551b…`=219496714 B、`339c536c…`=`app-debug-render-scale-live.apk`、`e09`=212075609 B。**不能按文件名当证据**。
* 设备：`526f6b6d` = OPPO OPD2511 / SM8475 / Adreno 730 / SDK 36；物理 1800×2880（竖）、横屏 2880×1800 ROT_270 120 Hz（8333333 ns）；包 `rhine.music.database/.MainActivity`。
* 互斥：`flock -n /tmp/rhine-device-526f6b6d.lock`；同一时刻只允许一个执行者碰 ADB；源码作者不得 ADB。
* 禁：`uninstall`/`pm clear`/`logcat -c`/改密度或旋转/输入 helper APK/强制 GC；安装用 `install -r -t` 保数据。
* 取证：tombstone 常缺（`/data/tombstones` 最新为 11-18 14:36 vendor face-hal）；vendor 每 5 s 刷 crash buffer ⇒ 用 `logcat -b crash -G 8M` + `logcat -b main -d -t 6000`。`dumpsys gfxinfo framestats` 仅约 123 行滚动；perfetto 配置须放 `/data/misc/perfetto-configs/` 且 `--txt`，解析用 `/tmp/hitch-trace-163/tools/trace_processor_shell`（slice JOIN thread_track）。坐标换算按**每张截图各自比例**：HUD 1728×1080→fb 2880×1800 = 1.6667；预览 2590×1619→1.112（旧 1.779 错）。

## 5. 关键提交与合并

| SHA | 日期 | 主题 |
|---|---|---|
| `65af97b`/`061300a`/`4beb444` | 11-19 09:39 | 播放条补封面字段，插件页不再压歌词页（同一 commit，hash 随历史重写变化） |
| `46e2dc7` | 11-19 01:14 | 退回 Skia GL，规避 Impeller/Vulkan 丢设备 SIGSEGV（manifest +18） |
| `99cd87c` | 11-18 21:55 | 竖屏界面全页移植 |
| `fa2d671` | 11-18 19:12 | 内嵌路径渲染倍率/AA/MSAA 当场生效 |
| `3f6d133` | 11-18 | 列表松手按 Qt 同口径惯性+吸附 |
| `9ded703` | 11-18 | HUD 静态前缀/动态条带双纹理（`46dd61d` 合并） |
| `cf9cfcf` / `ea15a947` | 11-18 | 在途帧 cap 1 / 普通 revert |
| `2989480` | 11-19 | 吸收 main：329 files +40469/−13754，`lib/` **0 变更**；9 冲突手 union；`Qt/src/EmbeddedSceneHost.cpp:567` 50,100→50,200 |
| `2250e6b` | 11-18 | 启动页按舞台布局（消 70.5% 黑边） |
| `83cdb2b` | 11-18 | 封堵纯 Qt Android 打包 |

## 6. 控制面约定与教训

**有效**：一任务一卡片（`control/<TASK>.json` 记 base/route/worktree/reservedPaths/state；`reports/<TASK>-<日期>.md|json`；`builds/<TASK>-<日期>/` 存日志/截图/gfxinfo 并按 `device1..N` 分轮）；一作者一 worktree + `reservedPaths` 隔离写域；审查门分级 **PASS/FAIL/UNVERIFIABLE-FROM-BYTES**，只读叶禁 test/build/ADB，禁止用注释/测试名/旧 APK 推断 PASS；"谁执行 ADB 谁负责"单点执行；revert 用普通 revert 保留可达历史。

**硬约束**：禁 reset/clean/stash/rebase/amend/push/force；保留所有分支、脏改动、APK、日志、heap；清理只进 trash；commit 主题单行、不改 Author（唯一例外是用户点名的 6 个 Author 修正，`final-reports/restart-git-housekeeping.md:5-14`）。

**Git 整理（READY-WAIT-GATE，未执行）**：503 个 commit 的 message-only 清理 0 候选 ⇒ NO-OP；57 条 `flutter-*`→`flutter/<suffix>`，`flutter-hapi-delivery`→`flutter/delivery`，分支名禁含渠道名；需 manifest+reflog 备份、逐支 old-OID guard、不 push/不动 tag/不建备份分支（`restart-git-housekeeping.md:38-44,124-137`）。当前仍是 69 heads 的 `flutter-*`。

**失败的做法**：① 未先证瓶颈就优化（HUD 分层、在途帧 cap、8→4 ms 三连零收益；真瓶颈是 Qt 帧产出+fence 饥饿）；② 信 `QJsonArray::mid()`（Qt6 无此 API，`dd346ff` 改逐条 append）；③ 用预览图全局比例换算坐标（导致"设置面板不可点击"误判，后被真实 tap 证伪）；④ 把注释当现状（`Overlay.qml`/`PerformancePanel.qml` 保持注释停用，`FrameProfiler` 不再创建）；⑤ 自建隔离 Flutter SDK（用户 `m10863` 叫停；候选 `48f03749` 修 null-frame 却引 Vulkan 丢设备 → `CLOSED_NOT_ADOPTED`）。

## 7. 迁移时最该保留的 20 条

1. Flutter=业务唯一权威，Qt=渲染/拾取权威，禁第二个 audio backend。
2. Impeller 必关（manifest:36-38），实际走 Skia GL。
3. ImageReader `maxImages=3` + Qt 单帧 460 ms = 丢设备根因。
4. 丢设备链：Adreno layout→alloc(4x4)→ErrorDeviceLost→dequeued>3→Timeout。
5. crash buffer 被 vendor 5 s 刷掉：`-G 8M` + `-d -t 6000`。
6. 无 tombstone 不等于无崩溃，别据"没崩"结案。
7. 冻结 = GPU queueBuffer waitForever，非降频非 fence 延迟。
8. 冻结必须 Qt 持续产帧；Qt 静止即 0 次。
9. "GPU completion" 是计数信号，不是 busy 时间。
10. 降渲染倍率不解决 UI 线程 jank（p50 仍 30 ms）。
11. Android HUD 是 Flutter 画的，Qt HUD 在嵌入路径是死代码。
12. 分层/节流类"优化"先量后改，三次实测均零收益。
13. 列表惯性必须复刻 Qt 的摩擦+吸附口径（`3f6d133`）。
14. 渲染倍率/AA 改动需"当场生效"，否则设置页与实际打架（`fa2d671`）。
15. 启动页按舞台尺寸布局，否则 70.5% 黑面（`2250e6b`）。
16. 坐标换算按每张截图各自比例，禁全局乘数。
17. APK 名字不是证据：落 sha256+字节数+独立文件名。
18. 单设备锁 + 单人 ADB；源码作者不碰 adb。
19. 只读审查叶 + PASS/FAIL/UNVERIFIABLE 三级门禁。
20. 生命周期泄漏是当前唯一 FAIL 收口项：JNI global 持 MainActivity。

**证据缺口**：`reports/crash-20261119/` 为空；竖屏移植 15 轮只有截图；`reviews/` 仅 6 份 124 期文档，晚期门禁只存在于 LEAD-*/LEAF-* JSON。