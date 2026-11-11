# T16 宿主架构裁决：五候选同切片矩阵（pending-evidence）

- 计划卡：T16 架构裁决（docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:506-512）
- 本文件原子：T16-D01（输出 docs/flutter-migration/02-adjudication.md）
- 姊妹文档：docs/flutter-migration/adr/0001-host-architecture.md（原子 T16-D02 / T16-D03）
- 状态：**未裁决（PENDING_DEVICE_EVIDENCE）**。本轮禁令下无任何真机测量，**全部指标 UNMEASURED，不填赢家**。
- 唯一切片：docs/flutter-migration/01-slice.md 与 test/fixtures/slice_cases.json（T10 独占写域；已由 0d329db 合入本树，只读引用其公开结构计数，不复制、不改写、不伪造其夹具；当前指纹见 §2）。
- 证据口径：本文件所称 `reports/<名>` 一律指控制面目录 `.agents/parity-20261109/reports/<名>`（`.gitignore:17` 的 `/.agents/` 已忽略该目录，仓库根无 `reports/`）；属控制面报告（非仓库内实现证据）；审计基线为冻结 SHA bf6743e8486d62964cc27a4b8573533fc00f2eb4（OPS78-FINAL-DEDUP.json:3 auditSha），但各报告自报的 baseSha/asOfSha 可不同（例：OPS78-COVERAGE.json:8/:9/:10 记 baseSha 8ed3067b…、asOfSha 2623b1c5…、rootMoving=true），以各报告自报字段为准；凡仅以 reports/ 为出处的计数与状态均未在仓库内验证。

## 0. 证据纪律

| 等级 | 含义 | 在本矩阵中的可用性 |
|---|---|---|
| E0 | 真机安装 / 启动 / 截图 / 无障碍树实证 | 唯一可填指标行的等级。本轮 E0 采集数 = 0 |
| E1 | 直读源码行 | 只作契约与门槛依据，不能作候选通过证据 |
| E2 | APK / 证书 / 哈希 / 版本 | 只作发布门依据 |
| E3 | 推断 / 设计候选 / 未逐行核对 | 只作线索 |

硬规则（逐条引用计划）：

1. 没跑过的候选不得填指标，只能标“未评估”（计划:167；计划 §3.4）。
2. 不得预设赢家；“推荐评估顺序 B → A → D → C → E”仅为排期，不是预设赢家（计划:168）。
3. 不得用全局 SSIM / ΔE / 大 mask 代替逐 ROI、字形、布局、动作、时序的人工对照（计划:32、计划:232、计划:769）。
4. 不得用源码常量、QML 预览图或桌面离屏图证明 Android 像素已对齐（计划:31）。
5. 硬门是功能 / 画面 / 协议 / 输入 / 状态 / 稳定 / 可维护（计划:157-163）；性能数字一律“拟议待冻结”（计划:231-233）。
6. 全候选失败时结论写“未裁决”并停止 P2 页面实现（计划:170、计划:510）。

## 1. 候选清单（五个，共用同一切片）

| ID | 宿主结构 | Spike | 候选源码输出（计划 Files 原文：Create 与 Modify 均列出） | 声明的失败出口（计划 Fail 原文） |
|---|---|---|---|---|
| A | Flutter 宿主 + Android PlatformView 承载 Qt 视图（QtQuickView 或自建 SurfaceView + Qt 渲染控制） | T11 | Create lib/platform/qt_platform_view.dart；android/app/src/main/kotlin/rhine/music/database/porting/QtPlatformViewHost.kt；integration_test/slice_platformview_test.dart；Modify android/app/src/main/kotlin/rhine/music/database/MainActivity.kt | 静态截图冒充嵌入、触摸错位仍宣称可用 |
| B | Flutter 宿主 + Qt 离屏渲染到 SurfaceTexture，经 FlutterTextureRegistry 合成 | T12 | Create lib/platform/qt_texture.dart；Qt/porting/TextureHost.h；Qt/porting/TextureHost.cpp；Qt/porting/CMakeLists.txt；android/app/src/main/kotlin/rhine/music/database/porting/TextureBridge.kt；integration_test/slice_texture_test.dart；Modify Qt/CMakeLists.txt | 只有静态首帧、旋转黑屏仍继续 |
| C | Flutter 宿主 + Dart CustomPainter 直译 HUD，3D 另选真实移植（原生 GLES/FlutterTexture；flutter_gpu 仅独立试验） | T13 | Create lib/spike/dart_hud/hud_painter.dart；lib/spike/dart_hud/glyph_loader.dart；lib/spike/scene3d/scene_surface.dart；integration_test/slice_dart_hud_test.dart；Modify 无 | 用 Material 列表替代 HUD |
| D | 混合：HUD 由 Dart 自绘，3D 暂由 Qt Texture 提供，逐页替换 | T14 | Create lib/spike/hybrid/hybrid_host.dart；Qt/porting/HybridTextureHost.h；Qt/porting/HybridTextureHost.cpp；integration_test/slice_hybrid_test.dart；Modify Qt/porting/CMakeLists.txt | 两套状态双写导致错帧 |
| E | Flutter 宿主 + 本地 WebView（canvas/WebGL/Three.js）完整复刻 | T15 | Create web/rhine_replica/index.html；web/rhine_replica/renderer.js；web/rhine_replica/three_scene.js；lib/platform/webview_replica.dart；integration_test/slice_webview_test.dart；Modify 无 | 只做素材展示、不跑交互 |

来源：计划 §3.1（计划:131-141）与 T11-T15 卡（计划:462-505）。E 是完整候选，不是“只复用素材”（计划:141）。注意：候选 B 的 Modify Qt/CMakeLists.txt 在 reports/GRAPH-001.json 中零覆盖、零 owner（GRAPH-V2 M6），落图前无 owner 可承接该行。

共同约束（计划:143-149）：候选不得以静态背景冒充 3D、不得删减账号/搜索/队列/设置/更新/诊断/本地 Siren 收藏、不得改上游协议；跨桥 envelope 属新设计，其数值为拟议，不得冒充 Qt 原协议；候选新增第三方依赖只在独立 worktree 记录，主 pubspec.yaml 不并写；候选 spike 只改宿主适配与 Qt/porting/，不得改 Qt 业务语义、存储 schema、登录状态机。

### 1.1 候选隔离（同切片、互不借用；共享件不等于胜出）

- **文件级互斥**：五张卡的 Create 路径两两不相交（T11 计划:463、T12 计划:472、T13 计划:481、T14 计划:490、T15 计划:498）。目录可以共用——`lib/platform/` 由 A/B/E 各自新增不同文件，`Qt/porting/` 由 B/D 各自新增不同文件——但**同一文件不得由两个 owner 写**。
- **唯一交叉点**：`Qt/porting/CMakeLists.txt` 由 B **Create**（计划:472）、由 D **Modify**（计划:490）；D 的 Deps 含 T12，故该交叉已被依赖串行化。若 T12 未落地，D 的 Modify 目标不存在（记在 ADR §8 缺口）。
- **共享件与候选无关**：契约（T01-T07）、切片（T10）、纯 Dart 领域/数学（T22/T23/T24）、投影数学（T41-S01）是所有候选共同的前提，本身**不构成任何候选的胜出证据**。候选源码复用同一份契约或同一份纯 Dart 数学，是计划强制的共同约束（计划:143-149），不得读作“某候选已被选中”。
- **不得互相充数**：候选不得改写彼此源码，也不得把别候选的 spike 文件复制进自己的写域；spike 只改宿主适配与 `Qt/porting/`（计划:149）。
- 五候选当前**各自独立**且都未跑：任何“某候选已有可复用宿主代码”的说法，都必须先落到具体 file:line；本卡核对结论见 ADR §4.8-§4.9（Flutter 侧仍是 `flutter create` 模板，Qt 侧无 `SceneTextureHost`）。

## 2. 切片（唯一，禁止候选各用不同切片）

| 项 | 值 |
|---|---|
| 步骤 steps | 10 |
| ROI | 38 |
| 检查项 checks | 21 |
| 阈值 thresholds | 7 |
| 显式未测量 unmeasured | 14 |
| 候选 candidates | 5 |
| 切片串 | 启动 → archive 全部歌曲 → 打开第 17 首详情（3D 封面）→ 返回 → 搜索输入中文并打开结果 → 加入队列/移除 → 旋转竖屏再回横屏（计划:153） |
| 同时必须覆盖 | 3D 画面、HUD 文字、命中、IME、无障碍、媒体会话、旋转、返回键（计划:153） |

结构计数来源：本树 test/fixtures/slice_cases.json 与 docs/flutter-migration/01-slice.md（0d329db 合入；取数于冻结 SHA bf6743e8）：steps 10（S0–S9）、rois 38（01-slice.md §5 表 38 行；fixture rois 38）、checks 21（fixture checks 数组 21 个对象）、thresholds 7、unmeasured 14、candidates 5。切片文件当前指纹（只读引用，不复制；工作树重算）：
- docs/flutter-migration/01-slice.md — 311 行，bytes 33817，sha256 897d36c76c0f607897887d8c2fa544ba094d652e775d24b32343c78e125a61e6
- test/fixtures/slice_cases.json — 1459 行，bytes 52005，sha256 396cfc0f8a716adca8e45b9c90b7dd2d02ece22fc6ac46e74e8a9615fef279d7
- 过期值警示：reports/T10-C01-M10.json 的 files 字段（27261 B/f0c126ee…、44957 B/2cd97957…）与旧稿引用的 26202 B/39771fce…、43537 B/93d1f7e8… 都是合入前的历史指纹（后一对出自旧稿摘要 reports/T16-C14.json:54、:58；reports/T10-C01-M10.json 的 reviewer.resumeHashNote 已标注这一对 stale，而 reports/T10-C01-M10-R.json 的 reviewedHashes 仍写着这对过期值，故该复审不构成对当前磁盘内容的复核）。任何消费方以上两条当前指纹为准，不得引用报告里的历史摘要。

## 3. 裁决矩阵（每格 UNMEASURED）

行 = 候选；列 = 七条硬门 + E0 证据面。本轮全部为 UNMEASURED；不得以任何源码推断替代。

| 候选 | 功能门 | 画面门（逐 ROI） | 协议门 | 输入门 | 状态门 | 稳定门（30 min） | 可维护门 | E0 证据 |
|---|---|---|---|---|---|---|---|---|
| A PlatformView | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | 无（0 帧） |
| B 离屏 Texture | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | 无（0 帧） |
| C Dart HUD + 3D | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | 无（0 帧） |
| D 混合 | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | 无（0 帧） |
| E 本地 WebView | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | UNMEASURED | 无（0 帧） |

已跑候选：**0 / 5**。因此“赢家”字段保持 **UNASSIGNED**，本文件不构成裁决。

**用语规定**：本文件不写任何 winner / 胜出 / 选定 结论；下文出现的“赢家”一律是规则引用（如“任何赢家都必须满足”），不是选型结果。任何后续编辑若在此文件把某个候选名写成结论，即属计划:167-168 禁止的预设赢家。

## 4. 逐候选未测量项（预注册的采集点，全部尚无数据）

| 候选 | 必须实测（计划 §3.1 原文要点） | 数据 |
|---|---|---|
| A | QtActivity 不能当普通 View 直接塞；嵌入视图生命周期、触摸坐标、IME、无障碍、旋转、与 Flutter 叠层 | UNMEASURED |
| B | QQuickRenderControl / RHI 离屏、GL / Vulkan 纹理共享、首帧、尺寸 / 时间戳、旋转、输入转发 | UNMEASURED |
| C | 17 命令、字形 JSON、命中、3D GLB / 相机 / 拾取 / 雾 / 动画、输入时延 | UNMEASURED |
| D | 双渲染栈同步、坐标同源、退出条件、长期成本 | UNMEASURED |
| E | 全切片功能、IME、无障碍、纹理合成、首帧 / resize、WebView 版本差异 | UNMEASURED |

## 5. 通过 / 失败判定（预注册，禁止事后调阈值）

硬门（计划:155-163）：功能、画面、协议、输入、状态、稳定、可维护。

- 协议门细节（任一赢家都必须满足，且与候选无关）：commands / hits / frame 同代次发布；17 op 参数按 Qt 原数组核对；hits 必需六字段并按源顺序消费；frame 投影矩阵容差 1e-9；不得去重合法相同命令（计划:159、计划:211-213）。
- 画面门：逐 ROI 人工对照；不得用大 mask / 全局 SSIM 代替（计划:158、计划:232）。
- 稳定门：切片连续 30 分钟无崩溃 / ANR / OOM；性能只记录实测分布，不设自造 60fps（计划:162）。
- 拟议辅助指标（SSIM≥0.97、ΔE≤3、像素容差、性能比例）**尚未冻结**，必须用 Qt 同设备同场景基线冻结后才可写入验收（计划:231-233、计划:769）。
- hit 矩形容差当前为 PROPOSED_UNFROZEN：计划只冻结 frame 投影 1e-9（计划:159），hit 容差无计划来源（见 reports/T10-C01-M10.json 的 F1）。

## 6. 工作面分类（本文件对下游的唯一结论）

本文件不产出赢家，但明确三类工作面，避免把“调度依赖”误当“接口不可写”：

| 类别 | 含义 | 本轮可否先写 | 例 |
|---|---|---|---|
| SHARED SOURCE 可写 | 契约 / fixture / 测试（只写不跑）/ 纯 Dart 领域与数学 / 候选源码 / 隔离目录页面几何与动作 builder | 可以，受各自独占写域与 owner 隔离约束 | T01-T07 契约、T10 切片、T11-T15 候选源码、T22/T23/T24 纯 Dart 领域、T41-S01 投影数学 |
| PRODUCTION WIRING → ARCH_BLOCKED | 需 ADR 赢家或宿主 / 桥 / 域运行时真实接线 | 不可以，等 T16 裁决 | T20-S01..、T21 桥（进程内 / 进程外）、T25 平台通道、T33-T40 页面接线、T41-S02..S06、T42-T44 |
| MEASUREMENT → DEVICE_BLOCKED | 真机像素 / 时序 / 黄金帧 / 性能取证 | 不可以，等设备窗口授权 | 本卡 T16-D01、-G01 golden（13 项全 ABSENT；卡片级门见 ADR §5 末注）、T41-T02、T44-T02、T50-T54 |

图层面重切计数（证据：reports/GRAPH-V2-REVIEW.json 的 state_recut：W=87 / W*=73 / A=25 / D=31；同一组数字也记在 must_fixes M3 的 applied 字段，但 M3 的 required_change 里的 118/67/31 是重切前的三分类建议口径，勿与本四类混用）。本卡三原子：T16-D01 → D；T16-D02 / T16-D03 → W。**限定**：这两个 W 是 GRAPH-V2 的重切建议；reports/GRAPH-001.json 现仍记 T16-D01=DEVICE_BLOCKED、T16-D02/T16-D03=ARCH_BLOCKED（blockReason 自指“等待 ADR”，见 GRAPH-V2 M10），该重切须由 Lead 落图后方可当作调度事实。

**注意**：本分类只针对源码可写性。页面接线、桥接线、宿主选择仍押后；不得因“可以写源码”而接线页面。

### 6.1 门措辞（逐字使用，不得改写、不得降级）

| 门 | 逐字状态串 | 覆盖对象 | 解除条件（两者不可互相替代） |
|---|---|---|---|
| 生产接线 | `ARCH_BLOCKED` | 宿主 / 桥 / 平台通道 / 页面接线的真实连线 | 本 ADR 改写为“已裁决”**且**具备同切片实测数据 |
| 真机取证 | `DEVICE_BLOCKED` | 像素、时序、黄金帧、性能、旋转、稳定性、无障碍树 | 一次真机窗口授权并完成同切片采集 |
| 文本/契约 | 无阻塞（可写不可跑） | 契约、fixture、纯 Dart 领域与数学、候选源码 | 不需要设备 |

- 现记状态与本表一致：reports/GRAPH-001.json:2894-2895 记 T16-D01=`DEVICE_BLOCKED`；:2915-2916、:2920 起记 T16-D02 / T16-D03=`ARCH_BLOCKED`。
- 两个状态串**不得互换**：`ARCH_BLOCKED` 等的是裁决（可被文本与实测共同解除），`DEVICE_BLOCKED` 等的是设备（只能被实测解除）。把取证写成 ARCH_BLOCKED 会让下游误以为“ADR 写完就解锁”。
- “ADR 已写”“源码已核对”“契约已冻结”都不构成任何门的通过证据，也不得据此降级任一状态（GRAPH-V2 M10 的 required_change）。
- 共享件（契约 / fixture / 领域 / 数学）可写但**不计入门通过**；本文件 §6 的 SHARED SOURCE 行只表示“可以开工”，不表示“已经可用”。

## 7. 未评估清单（须在裁决时补齐）

1. 五候选的同切片真机逐 ROI 像素对照帧。
2. commands 逐条 token 等价、hits 逐项矩形与顺序等价的实测导出。
3. 输入时延与 IME 提交 / selection / focus 的实测记录。
4. 旋转前后状态连续性（不重复登录 / Node / 媒体源）实测。
5. 连续 30 分钟稳定性与性能分位分布。
6. Qt 同设备同场景基线（用于冻结拟议辅助指标）。
7. G1：APK 哈希与 Qt 源码同 commit 的出处证明（未闭合则 P1 不裁决，计划:105）。

## 8. 停止与升级

- 当前停止理由：无设备授权窗口，T16-D01 无法采集，故本卡停在“未裁决”。
- 升级路径：由 Lead / 用户决定是否申请一次真机窗口以解 T16-D01；review 叶不申请（reports/GRAPH-V2-REVIEW.json next_wave W6）。
- ADR 一旦因设备禁令不可裁决：页面接线保持 ARCH_BLOCKED，**不得用源码推断代替实测**（GRAPH-V2 M10 的 required_change）。
- 若全候选失败：结论写“未裁决”并停止 P2 页面实现（计划:170、计划:510）。

## 9. 参考

- docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md（§0 证据纪律、§3 候选与硬门、§9 验收门）
- docs/flutter-migration/adr/0001-host-architecture.md（本卡 ADR；§4.5 Node 运行时与桥、§4.8 Qt 宿主职责与 Flutter 侧边界、§4.9 既有离屏实现与缺口）
- docs/flutter-migration/01-slice.md、test/fixtures/slice_cases.json（T10；0d329db 合入本树，只读引用，指纹见 §2）
- .agents/parity-20261109/reports/T10-C01-M10.json、GRAPH-V2-REVIEW.json、GRAPH-001.json（T16 三原子状态）、T16-C14.json（旧稿指纹出处）（控制面报告，非仓库内实现证据）
- Qt 源（边界与运行时候选证据）：Qt/src/Host.h、Qt/src/Host.cpp、Qt/src/BridgeProcess.h、Qt/src/BridgeProcessAndroid.cpp、Qt/src/main.cpp、Qt/src/render/SceneLayerHost.h、Qt/src/render/SceneLayerHost.cpp

---

本文件为本轮发布的 pending-evidence 版本：它固化候选、切片、门槛、矩阵形状与工作面分类，**不包含任何赢家与任何实测指标**。
