# `.agents/` 控制面存档（2026-11-19 删除）

状态：**已归档并删除**。本文是 `.agents/` 目录在删除前的知识摘要与恢复索引；目录本身（约 65 GB、227 个 git worktree）已于 2026-11-19 从工作区移除。

- 技术现状（架构、实测数字、缺陷根因、取证流程）：[qt-flutter-state-2026-11-19.md](qt-flutter-state-2026-11-19.md)
- 未提交改动与未跟踪源码：[worktree-salvage-2026-11-19.tar.gz](worktree-salvage-2026-11-19.tar.gz)（963 KB，325 条目，含 MANIFEST.md）

## 0. 为什么可以删

`.agents/` 是本机私有的控制面目录，不是仓库内容：`.gitignore` 曾以 `/.agents/` 整目录忽略（第 17 行，已删），`git ls-files .agents` 恒为 0。它的价值只有三条，均已另存：

| 价值 | 现在在哪 |
|---|---|
| 技术结论、实测数字、缺陷根因 | [qt-flutter-state-2026-11-19.md](qt-flutter-state-2026-11-19.md) |
| 未提交的实验改动、未跟踪的新源码 | [worktree-salvage-2026-11-19.tar.gz](worktree-salvage-2026-11-19.tar.gz) |
| 历史实现 | 252 个本地分支、887 个提交，均在 `.git` 里，删除 worktree 不丢提交 |

删除后 `.gitignore` 不再忽略 `/.agents/`；`scripts/check-repository.cjs:70` 的忽略正则里仍列 `.agents`，只是防御性条目，不影响任何检查。

## 1. 时间线（2026-11-08 → 11-19）

| 日期 | 事件 | 证据 |
|---|---|---|
| 11-08 | Flutter 重写冲刺启动：多子代理并行实施 + 静态评审 + 装包，约 30 小时 | `.agents/final-reports/` 172 份 md，mtime 全在 11-08 09:13 – 11-09 15:06 |
| 11-09 15:04 | **用户叫停**：“当前界面和功能与原 APP 差距甚远，不接受继续按现路线推进”；pause revision 20，构建/提交/集成授权全部撤回 | `final-assembly-control.md:6`；`current-delivery-checkpoint.md:3,7` |
| 11-09 | 转向只读规划：7 份 `qt-plan-*.md`（合计约 333 KB）+ `task-graph.json` 42 卡 + `scheduler.json` | 本文 §3、§4 |
| 11-10 | T01 基线台账、T16 五候选裁决草案落盘（无真机测量，全部 UNMEASURED） | `docs/flutter-migration/00-baseline.md`、`02-adjudication.md`、`adr/0001-host-architecture.md` |
| 11-11 → 11-15 | basic 路线实施：151 个 parity worktree（`RUNTIME-*`、`QT-*`、`FINAL-*`、`T01`–`T53`） | `.agents/parity-20261109/worktrees/` |
| 11-15 | `HANDOFF-20261115-NATIVE-QT.md` 交接：改用原生 Qt 场景 + Flutter HUD，Worktree 规则固定 | 该文件 16 KB |
| 11-16 → 11-19 | 设备收口：HUD 双纹理、帧节奏、竖屏移植、Impeller 崩溃止血、吸收 `origin/main` | `9f1f6c5`、`46e2dc7`、`99cd87c`、`2989480` |
| 11-19 | 分支 tip = 「播放条补上封面字段，插件页不再与歌词页重叠」（`v0.3.1-874`）；归档本文并删除 `.agents/` | 该 commit 的 hash 当天被历史重写反复改过：`65af97b`（09:39 filter-branch）→ `061300a`（10:45）→ `4beb444`（10:57）；按 subject 定位，不要按 hash 定位 |

## 2. 删除前的目录原貌

| 路径 | 规模 | 内容 |
|---|---|---|
| `.agents/worktrees/` | 9.3 GB / 52 目录 | 早期 Flutter 重写的作者工作树，含多层嵌套（`worktrees/flutter-m0-android/.agents/worktrees/flutter-m1-domain/...`） |
| `.agents/parity-20261109/worktrees/` | 35 GB / 151 目录 | 任务卡工作树，一卡一树一分支 |
| `.agents/parity-20261109/builds/` | 20 GB | APK、日志、截图（`device1..N` 分轮）、`gfxinfo` 转储 |
| `.agents/parity-20261109/toolchains/` | 1.4 GB / 18183 文件 | 隔离 Flutter SDK 等（该做法已被用户叫停，见 §7） |
| `.agents/parity-20261109/reports/` | 22 MB / 1128 文件（约 30 份 md） | 控制面报告：每任务一份 `<TASK>-<日期>.md` / `.json` |
| `.agents/parity-20261109/logs/` | 336 MB / 443 | ADB、构建、gfxinfo 原始日志 |
| `.agents/parity-20261109/control/` + `control-archive/` | 4.4 MB / 525 + 488 KB / 17 | `control/<TASK>.json`：base/route/worktree/reservedPaths/state |
| `.agents/final-reports/` | 3.4 MB / 172 | 11-08 冲刺的回执流水，约 2/3 只是 ACK/授权日志 |
| `.agents/qt-flutter-parity-20261109/` | 200 KB | `scheduler.json`（maximumDepth 8、maximumLiveDescendants 500、reviewIntegrationReserve 80）、`task-graph.json` 187 KB |
| 顶层 `qt-plan-*.md` 7 份 | 333 KB | 行为/视觉/设备/草稿/终审/作者规划稿 + 若干 `*-control*.md` |

## 3. 规划期的不变式（至今仍成立）

1. 复刻对象不是一组页面，而是 Qt 每帧产出的协议：`commands`（绘制命令流）+ `hits`（与绘制同源的命中矩形）+ `state` + `frame`。Qt 是单进程自绘 HUD，绘制与命中天然同源，控件树无法复刻。
2. 域状态的所有者必须在 Qt C++（Host / MusicLibrary / MusicPlayer / PlaybackQueue / LyricsController / NativeScene / NativeHud / NativeApplication）；Flutter 只能做 shell。迁移第一风险是数据损坏，不是画面。
3. 横屏 1:1 有真实基准；竖屏在 Qt 里**不存在**，只能当“经样板审核的新增重排”，不得声称 1:1。
4. 证据分级 E0 设备 / E1 源码 / E2 产物 / E3 推断；“任何任务不得把 E3 当验收依据”。
5. 实施期唯一允许触碰的 Qt 范围：`Qt/porting/**`、CMake 注册、Manifest/Activity 胶水；不改业务语义，默认路径可关闭并回退。
6. 存储双读旧 INI 与 `session.json`，键名不变，写回同一 `panel/<key>`，否则回滚 Qt 会丢设置。
7. 播放保活走原生前台 Service + MediaSession + 通知，不依赖 Flutter 插件默认。
8. 不为迁移自造 60 fps / 16.6 ms / SSIM 承诺；未测指标一律“拟议待冻结”。

## 4. 数值契约（规划期冻结/拟议，细节见 `docs/flutter-migration/contracts/`）

| 项 | 值 |
|---|---|
| 横屏舞台 | `stageScale = height/1080`、`stageWidth = width/stageScale`、`navigationLeft = width-789`、侧栏 `clamp(width*0.23-40, 250, 340)`、详情右栏 `x = width*0.56-24` |
| 竖屏候选（Portrait-A） | `stageScale = width/1080`、播放栏贴 `stageHeight-96`、IME 整层上移 `min(insets, 底距)`；无 Qt 基准 |
| 绘制命令流 | 17 op：save、restore、alpha、translate、scale、rotate、clip、fill、ellipse、text、art、fill-path、path、arc、right-mask、gradient、image；未知 op 静默跳过，不得中断整帧 |
| 颜色 | `linear = c^1.8`；`srgb` 分段 12.92 线性段 + `1.055*linear^(1/2.4)-0.055` |
| hits | 六字段 `x/y/width/height/action/label`；`fixed` 仅播放条产生；源顺序首个命中生效；触摸外扩 `pad=16`（仅 Android）；`modalOffset` 只加非 fixed |
| 滚动步长 | settings 66、discover 60、search = ResultRowHeight、歌词 `-delta/120*65` |
| 文字 | 基线 `y + size*1.044`；行距 16/31、歌词 34/47、详情 32/40；截断用二分 + “…” |
| 会话 | `session.json` `version=1`；恢复校验 provider/edition/uid 一致、sources 恰 5、physical −1..39；每 15 s 及 ApplicationInactive/Suspended 原子写 |
| 行为阈值 | 搜索防抖 700 ms；目录 40 槽环形 `cell=(index+anchor)%40`、≤64 层；歌词 offset ±10000；缓存 ≤240000 字符；历史 ≤200；登录轮询 1 s×300 |
| 桥 | input 上限 48 MB、启动 30 s、线程栈 8 MB；读 15 s / 写 20 s；`entityKey` 正则 `^[a-z]+:[a-z]+:[A-Za-z0-9_-]{1,80}$` |
| 3D | 5 列×8 槽 = 40；`cellPosition = {(lane-2)*5.2, -4.6, (row-15.5)*0.62}`；FOV 34°、near 5、far 300、`DEFAULT_SHOT 29.1`、`ACTOR_POSITION {0,-4.6,-2.17}`；纹理准入焦点稳定 100 ms |
| 3D/2D 联动 | 浏览构图 `values[8] += 0.16*archiveOffset`、`values[9] += 0.20*archiveOffset` |
| HUD 纹理 | 脏区面积 > 92% 整窗重画；`RHINE_HUD_TEXTURE_SCALE 50..100`；`window()->update()` 才出帧 |
| 登录 | 六路径：网易云 qr/phone、QQ qr/wechat、酷狗 standard/lite 各 qr；手机号 `^1[0-9]{10}$`、验证码 `^[0-9]{4,8}$`、重发 60000 ms |
| 拟议门禁（从未执行） | 区域 SSIM ≥ 0.98、ΔE2000 ≤ 2.0/3.0、命中 IoU ≥ 0.98、首帧 ≤ Qt+150 ms、起播 ≤ Qt+300 ms、`libRhineCore.so` 增量 ≤ 15 MB、FFI p95 ≤ 2 ms |

## 5. 早期冲刺契约（2026-11-08/09）：哪些还在用

那 30 小时的产物大部分已不在现树（`lib/` 在 `2989480` 合并时 0 变更，说明后续 basic 路线重写了这些层）。删除目录前值得记住的结论：

**仍然成立 / 仍在代码里**

- 每 scope 一条 NodeHost **物理通道**是 BLOCKING；正确形态是单物理通道 + 单 MusicGateway + `withGateway(scope, action)` 作用域租约。排他的是 scope 转换（writer），同 scope 并发是 reader。
- 帧上限 **48 MiB**、握手期失败即终态、sessionExempt 白名单；worker 帧 base64、解码失败回退原文。
- QQ `__qqSessions` 每 worker 只播种一次，换号必须重启 worker；持久化快照要过滤会话。
- 传输超时：连接 15 s / 握手 10 s / worker 启动 30 s / 关机 5 s；`start` 后握手失败必须 fatal，不可重试。
- 缓存键 `scoped-response:v1:<len>:<scope>:<key>`，上限 1024 后绕过；封面缓存 `rhine_covers_v1`、30 天、256 对象。
- 系统栏只对 API 29+ 透明导航栏，状态栏不写死；Impeller 必须关闭、走 Skia GL。
- 依赖地板：Flutter 3.44.0、rxdart 0.28.0、cached_network_image 3.4.1（4.x 因上游 retracted 被拒）。

**已过时（不要按这些找代码）**

- `withGateway` / `MusicGateway` / `NodeHostBridgeChannel`、`lib/cache/`、Android `nodehost` Kotlin 目录在当前 `lib/` 与 `android/` 里都不存在。
- 交付 SHA `bd383d3`、`f3fcaa7`、`0a1f554` 不被任何分支包含（`git branch --contains` = 0），只能当“未合入历史”引用。
- `adr/0001-host-architecture.md` 里“`lib/main.dart` 仍是 flutter create 模板”等描述已过时；该 ADR 状态仍是 PROPOSED/PENDING，从未裁决。

## 6. 分支、工作树与残留材料

删除前：**227 个 worktree、252 个本地分支**（117 已并入 `feat/flutter`，135 未并入，多为 `flutter/basic/*` 历史；最新未并入为 `feat/hud-dual-texture` 11-18、`flutter/basic/qt-closure-174` 11-17）。worktree 删除不影响分支与提交。

**带未提交改动的工作树（23 个，非 generated/非锁文件，合计 762,824 字节）**

| 工作树 | 分支 | HEAD | 补丁字节 |
|---|---|---|---|
| `parity/QT-URGENT-APK-125` | `flutter/basic/urgent-apk-125` | 62a8ccd | 181558 |
| `parity/FINAL-INTEGRATION-150` | `flutter/basic/final-integration-150` | 4eacdc7 | 89330 |
| `worktrees/.../flutter-m2-shell` | `flutter-m2-shell` | b2708d5 | 51266 |
| `worktrees/flutter-final-dependency-status` | 同名 | 043686c | 47890 |
| `parity/QT-CLOSURE-174` | `flutter/basic/qt-closure-174` | ff303a1 | 47847 |
| `worktrees/flutter-m3-accounts-search` | 同名 | cc03168 | 44124 |
| `parity/SCENE-BOOT-115` | `flutter/basic/scene-boot-115` | 72abb04 | 39848 |
| `parity/QT-SCENE-121` | `flutter/basic/qt-scene-121` | 823580d | 36126 |
| `parity/RUNTIME-96` | `flutter/basic/runtime-startup-96` | b60689f | 28938 |
| `worktrees/.../flutter-app-entry` | `flutter-app-entry` | bc1c99c | 26832 |
| `parity/QT-OVERLAY-128` | `flutter/basic/native-recovery-132` | 95f8248 | 24151 |
| `worktrees/flutter/fix-audio-intent` | 同名 | b1991e0 | 20548 |
| `worktrees/.../flutter-m05-scene` | `flutter-m05-scene` | eb6f10a | 19371 |
| `parity/T01` | `flutter/p0-t01-baseline` | c25ce04 | 17181 |
| `parity/FINAL-ACCEPTANCE-157` | `flutter/basic/final-acceptance-157` | 7270bf2 | 16912 |
| `worktrees/flutter-integration` | 同名 | 19e96c2 | 14620 |
| `worktrees/flutter-m4-playback` | 同名 | 27061f1 | 13447 |
| `worktrees/flutter-m5-content-settings` | 同名 | 8ea9309 | 13398 |
| `parity/FINAL-ACCEPTANCE-155` | `flutter/basic/final-acceptance-155` | 1b5ce83 | 10428 |
| `parity/FINAL-INTEGRATION-148` | `flutter/basic/final-integration-148` | 4eacdc7 | 9416 |
| `worktrees/flutter-app-lease-closure` | 同名 | 4ae13ed | 6092 |
| `parity/T12` | `flutter/p1-t12-offscreen-texture` | dab24ad | 2577 |
| `parity/T26` | `flutter/p2-t26-storage-domain` | 665786b | 924 |

另有 `LIFECYCLE-CAPTURE-167` 的 1256 个改动经核查几乎全是 `generated/ffx_shaders`（构建噪音，已在打包时排除）。

**重放方式**：解包后 `git apply -p1 <patches/x.patch>`，务必在对应基线（表中 HEAD）上应用；跨基线不保证干净。未跟踪源码在 `untracked/` 下按原相对路径存放（104 个文本文件，2.65 MB），PNG 截图按仓库惯例不入库。

**记住某一轮实验的结论只要记住分支名**：分支仍在，`git log <branch>` 可复原全部中间提交；实验报告的部位（`builds/<TASK>-<日期>/`、`reports/<TASK>-<日期>.md`）已随目录删除，可依赖的替代是根 `reports/*.md`（11-19 的三份：`PORTRAIT-FIX-20261119.md`、`PORTRAIT-PORT-20261119.md`、`RENDER-SCALE-LIVE-20261119.md`）与本文 §4/§5 的数字表。

## 7. 控制面的工作方式（可复用的流程结论）

**有效**：一任务一卡片（`control/<TASK>.json` 记 base/route/worktree/reservedPaths/state；`reports/<TASK>-<日期>.md`；`builds/<TASK>-<日期>/` 按 `device1..N` 分轮存日志与截图）；一作者一 worktree + `reservedPaths` 隔离写域；审查门分 **PASS / FAIL / UNVERIFIABLE-FROM-BYTES** 三级，只读叶禁 test/build/ADB，禁止用注释、测试名、旧 APK 推断 PASS；“谁执行 ADB 谁负责”的单点执行；revert 用普通 revert 保住可达历史。

**硬约束**：禁 reset / clean / stash / rebase / amend / push / force；保留所有分支、脏改动、APK、日志与 heap；清理只进 trash；commit 主题单行、不改 Author（唯一例外是用户点名的 6 个 Author 修正，未执行）。

**失败的做法（五条教训）**

1. 未先证瓶颈就优化：HUD 双纹理、帧在途 cap=1、HUD 预算 8→4 ms 三次实测均零收益；真瓶颈是 Qt 帧产出与 GPU fence 饥饿（详见 [qt-flutter-state-2026-11-19.md](qt-flutter-state-2026-11-19.md) §2）。
2. 信了不存在的 API：`QJsonArray::mid()` 在 Qt6 不存在，`dd346ff` 改逐条 append。
3. 用预览图的全局比例换算设备坐标，导致“设置面板不可点击”的误判，后被真实 tap 证伪。
4. 把注释当现状：`Overlay.qml` / `PerformancePanel.qml` 保持注释停用，`FrameProfiler` 不再创建，但报告一度按“存在”描述。
5. 自建隔离 Flutter SDK（用户明确叫停）：候选 `48f03749` 修了 null-frame 却引入 Vulkan 丢设备，最终 `CLOSED_NOT_ADOPTED`。

## 8. 开放问题（未随目录删除而解决）

| 项 | 状态 |
|---|---|
| Qt 宿主生命周期泄漏（JNI global 持 MainActivity，5 轮 Back 后仍未卸载） | **FAIL**，`QT-LIFETIME-172` = `SDK_FAILED_FROZEN_NO_EXECUTION_LEASE` |
| Qt 消费端 460 ms/帧、GPU busy 99.9% | 未解决；是 ImageReader 3 缓冲击穿的生产端 |
| 竖屏 SIGSEGV 根治 | 仅止血（关 Impeller）；`maxImages=5–6` 备选未验证 |
| 第 4 次重开 SIGABRT（destroyed mutex @ `QRhi::endFrame`） | 代码原因未独立定位 |
| null-SurfaceFrame 崩溃（`external_view_embedder.cc:144-154` 无 null 检查） | `UNSTABLE_SECOND_SAME_SIGNATURE_SIGSEGV` |
| Qt 嵌入路径的 render-only 闸门 | MUST 未收口：`Qt/src/main.cpp:1055-1059` 早于 `:1066`，`Qt/src/Engine.cpp:48-66` 无条件 `app->initialize()` |
| 竖屏移植证据 | 只有截图（15 轮），无数字报告 |
| 规划期证据缺口 G1–G9、T16 架构裁决、竖屏 G1–G5 门 | 全部未闭合/未裁决（历史状态，已被 basic 路线绕过而非关闭） |
| Git 整理（57 条 `flutter-*` → `flutter/<suffix>`、6 个 Author 修正） | READY-WAIT-GATE，未执行；503 个 commit 的 message-only 清理经查 0 候选 |
| `docs/ANDROID.md` 只写 Qt 打包 | 已在 §1.3.1 补 Flutter 打包路径 |

## 9. 索引

- 技术现状：[qt-flutter-state-2026-11-19.md](qt-flutter-state-2026-11-19.md)
- 残留材料：[worktree-salvage-2026-11-19.tar.gz](worktree-salvage-2026-11-19.tar.gz)
- 基线与证据台账：`docs/flutter-migration/00-baseline.md`、`docs/flutter-migration/evidence/device-2026-11-09.md`
- 契约：`docs/flutter-migration/contracts/{domain,hud-protocol,layout,settings-platform,storage,text-color,text-shaping}.md`
- 计划：`docs/superpowers/plans/2026-11-09-qt-flutter-1to1-migration.md`（规划稿）、`2026-11-08-flutter-android-rewrite.md`（旧计划，不实施）
- 平台文档：`docs/ANDROID.md`、`docs/RENDER-ARCHITECTURE.md`

## 10. 删除后的残留引用（历史出处，不是路径依赖）

这些位置仍写着 `.agents/` 路径，用途是标注“结论从哪来”，代码与测试都不读该路径，删除目录不影响构建或测试：

| 位置 | 引用内容 | 处置 |
|---|---|---|
| `lib/hud/widgets/settings_row.dart:28` | 契约原本在 T06 工作树内 | 同一份契约已在 `docs/flutter-migration/contracts/settings-platform.md`，注释保留 |
| `test/basic/basic_settings_shared_prefs_test.dart:12` | 截图路径 `parity-20261109/logs/159/.../shot-09-after-stepper.png` | 截图未入库（仓库惯例），仅存说明 |
| `test/basic/interaction_134_native_test.dart:21` | 复现命令 `cd .agents/.../INTERACTION-134` | 历史命令，现已无法执行；同一结论见 `reports/INTERACTION-134.json` |
| `test/basic/library_scroll_inertia_test.dart:4` | 真机基线目录 `builds/LIST-INERTIA-PROFILE-20261118/` | 基线数字已写进注释正文 |
| `test/hud/t40/playlist_picker_test.dart:12` | T40 工作树绝对路径 | 同上，历史出处 |
| `test/fixtures/baseline_manifest.json:7` + `test/baseline_manifest_test.dart:124` | `worktree` 字段 = T01BASE 工作树 | 断言的是“冻结坐标记录”，与文件系统无关，保留 |
| `android/app/build.gradle.kts:195-207` | 默认 deploy 目录推导规则来自旧控制面布局 | 只影响缺省值；已注释说明必须用 `-PrhineQtAndroidDeployDir` 或 `RHINE_QT_ANDROID_DEPLOY_DIR` |
| `scripts/check-repository.cjs:70` | 忽略目录正则含 `.agents` | 防御性保留：将来若再出现同名目录，检查脚本仍会跳过 |
