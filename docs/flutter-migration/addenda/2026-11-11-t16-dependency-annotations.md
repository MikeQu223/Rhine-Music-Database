# T16 依赖标注追加（DEDUP-11 / A-MF-02 / A-MF-09）

- 追加对象：`docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md`（869 行，tracked 历史用户计划；本追加**不修改其任何字节**，只新增本文件）
- 基线：`bf6743e8486d62964cc27a4b8573533fc00f2eb4`
- T16 状态：**UNASSIGNED / PENDING_DEVICE_EVIDENCE**（已跑候选 0/5；见 `docs/flutter-migration/02-adjudication.md:6`、`:79`，`docs/flutter-migration/adr/0001-host-architecture.md:47`、`:140`）
- 统一依赖表述（下表第 4 列逐字复用）：**须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收**
- 追加性质：只做依赖标注与风险陈述；不产生裁决、不预设赢家、不改计划顺序与标题。

```text
t16_status: UNASSIGNED/PENDING_DEVICE_EVIDENCE
dep_statement: 须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收
annotated_plan_lines: 506,507,508,510,511,608,624,631,639,647,654,662,668,669,748
read_not_tabulated: 509,512
```

## 1. 逐行依赖标注

| 计划行 | 原文逐字摘录 | 为何依赖 T16 | 正确依赖表述 | 违反后的具体风险 |
|---|---|---|---|---|
| :506 | `#### T16 架构裁决` | T16 是宿主/平台视图/窗口形态的唯一裁决出口；该卡未产出赢家前，任何引用其输出作为“已解锁”的下游都是抢跑。 | 本卡不构成解锁；下游须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收。 | 把“T16 卡存在”读成“T16 已裁决”，P2/P3 页面与桥提前接线，形成假绿状态；事后按 ADR:47 回退时需拆除已接线的宿主选择。 |
| :507 | `- Owner: ARCH · Deps: T11-T15 · Files: Create docs/flutter-migration/adr/0001-host-architecture.md、docs/flutter-migration/02-adjudication.md；Modify 无` | T16 的输入是 T11-T15 五个候选的同切片实测；输出 ADR/02-adjudication。当前 0/5 已跑，输入为空，故输出只能是“未裁决”，不能作为下游实施依据。 | 须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收；引用 ADR/02-adjudication 时必须同时引用其“未裁决”状态。 | 把 ADR/02-adjudication 当“已选型文档”使用；下游按 B 方案铺宿主，违反计划:167-168（未跑不得填指标、不得预设赢家）。 |
| :508 | `- [ ] 只汇总已跑候选的同切片数据；未跑候选标“未评估”，不得填指标。` | 该行禁止给未跑候选填指标，也就禁止以未跑候选（B）的能力推定其胜出；T41 的文件清单若按 B 落地即违反本行。 | 须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收；未跑候选只能标“未评估”，不得据其写生产文件。 | 用“B 最接近原逻辑/推荐顺序 B→A”当作已选 B（计划:168 明确推荐顺序不是预设赢家）；候选 C/E 被提前排除，返工覆盖 `lib/scene/*` 与两套 native host。 |
| :510 | `- [ ] 若全失败，结论写“未裁决”并停止 P2 页面实现。` | 该行是计划内停机规则，但只写“全失败”；当前是“全部未跑”，同样无赢家。ADR:47 已把“全部未跑”并入未裁决并保持 P2 页面 ARCH_BLOCKED，故本行必须按“未裁决（含未跑）→ 停 P2 页面”执行。 | 须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收；未裁决（含全部未跑）期间停止 P2 页面实现。 | 以“尚未全失败”为由继续 T33-T40 页面接线，直接违反计划:510 与 ADR:47/:140 的 ARCH_BLOCKED 分类。 |
| :511 | `- Pass: ADR 能让下一位工程师独立复核。Fail: 预设赢家、用全局 SSIM 代替 ROI。` | 本行把“预设赢家”定义为 T16 的 Fail；T41 在 Files 里预置候选 B 的 SceneTextureHost/SceneTextureHost.kt 就是预设赢家的具体形态。 | 须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收；不得在 T16 前按任一候选命名生产文件。 | 触发 T16 的 Fail 条件（预设赢家），使 ADR 不可独立复核；后续若换赢家，T41 的 native 文件与 `scene_surface.dart` 全部作废。 |
| :608 | `- Owner: PAGE-ARCHIVE · Deps: T30-T32、T22 · Files: Create lib/hud/pages/chrome.dart、lib/hud/pages/archive_page.dart、lib/hud/pages/directory_empty.dart、lib/hud/widgets/track_ruler.dart、test/golden/archive_default_1920.png、test/golden/archive_tabmode_1920.png` | T33 是页面接线：窗口形态（横屏 stage / 竖屏分段）、HUD frame 来源与命中坐标都随宿主通道（候选 A/B/C/D/E）而变；Deps 只列 T30-T32、T22，缺 T16。 | 须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收；T33 的页面接线以 T16 赢家与窗口形态为前提（ADR:140 已列 ARCH_BLOCKED）。 | 在宿主未定时写 archive 页面接线，宿主切换后 stage 几何、hit 坐标与 golden 全部重做；并把 ADR:140 的 ARCH_BLOCKED 误当可交付。 |
| :624 | `- Owner: PAGE-SEARCH · Deps: T30-T32、T22 · Files: Create lib/hud/modals/search_modal.dart、lib/hud/modals/search_results.dart、test/golden/search_empty_1920.png、test/golden/search_results_1920.png、test/hud/search_modal_test.dart` | T35 依赖宿主提供的 modalOffset、frame 时序与 IME 通道；这些由 T16 选定的宿主/平台视图决定，Deps 缺 T16。 | 须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收；搜索弹层的 frame/IME/命中接线以 T16 为前提。 | 按某一候选的 modalOffset/IME 假设写死，换宿主后弹层层级与输入焦点错位；golden 与命中测试需整体重做。 |
| :631 | `- Owner: PAGE-LIBRARY · Deps: T30-T32、T22、T24 · Files: Create lib/hud/modals/library_modal.dart、lib/hud/modals/login_panel.dart、lib/hud/modals/playlist_form.dart、test/golden/login_qr_1920.png、test/golden/library_logged_out_1920.png、test/hud/login_panel_test.dart` | T36 的登录面板/个人库需要宿主会话、存储与 provider 注册；provider 注册点是 T16 的宿主产物，Deps 缺 T16。账号域另有 PAUSED_BY_USER 约束。 | 须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收；登录/会话接线另受账号域 PAUSED_BY_USER 约束，不得恢复账号制作。 | 在未裁决宿主上接登录路径，既抢跑 T16，又触碰暂停的账号域（DEDUP-15/16/30/32）；返工同时覆盖 UI 与 host 会话通道。 |
| :639 | `- Owner: PAGE-SETTINGS · Deps: T30-T32、T06、T27 · Files: Create lib/hud/modals/settings_modal.dart、lib/hud/widgets/settings_row.dart、lib/hud/pages/desktop_lyrics_settings.dart、test/golden/settings_top_1920.png、test/golden/settings_bottom_1920.png、test/hud/settings_sections_test.dart` | T37 的七区依赖平台开关、诊断、更新等 host 通道（T27 平台面）；通道契约由宿主选型决定，Deps 缺 T16。 | 须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收；平台开关/诊断/更新通道以 T16 赢家为前提。 | 按错误宿主的通道签名写设置项，平台开关与诊断入口在集成期失效；golden 七区需按新宿主重拍。 |
| :647 | `- Owner: PAGE-DISCOVER · Deps: T30-T32、T22 · Files: Create lib/hud/modals/discover_modal.dart、lib/hud/widgets/discover_card.dart、test/golden/discover_1920.png、test/hud/discover_test.dart` | T38 的发现页依赖宿主网络/桥与登录态注入；HUD frame 与卡片命中同样来自宿主通道，Deps 缺 T16。 | 须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收；发现页的桥/登录态/frame 接线以 T16 为前提。 | 未定宿主时接发现页，登录态与桥 envelope 随宿主变化而返工；出现“未登录不可达却伪造数据”（计划:650 Fail）的风险。 |
| :654 | `- Owner: PAGE-PLAYER · Deps: T30-T32、T23 · Files: Create lib/hud/player/player_bar.dart、lib/hud/modals/queue_modal.dart、lib/hud/modals/lyrics_panel.dart、test/golden/player_idle_1920.png、test/golden/queue_empty_1920.png、test/hud/player_bar_test.dart` | T39 的播放栏/队列/歌词依赖媒体会话与播放器所有权；DEDUP-25 裁决要求 T16 前保双兼容，所有权不得先选边，Deps 缺 T16。 | 须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收；播放器所有权保持双兼容，不选边（DEDUP-25）。 | 提前选定 Qt 或 Dart 播放所有权，删除 PlaybackStore 或形成第二队列；违反计划:658 的 Fail（第二队列/双写）与 DEDUP-25 双兼容裁决。 |
| :662 | `- Owner: PAGE-MODALS · Deps: T30-T32、T06 · Files: Create lib/hud/modals/quality_modal.dart、lib/hud/modals/provider_modal.dart、lib/hud/modals/playlist_picker.dart、lib/hud/modals/confirm_modal.dart、lib/hud/modals/disc_warning_modal.dart、lib/hud/modals/lyrics_offset_modal.dart、lib/hud/modals/detail_sort_modal.dart、test/golden/modals_misc_1920.png、test/hud/modals_misc_test.dart` | T40 的弹层依赖窗口形态（fixed hits、modalOffset）与宿主返回键/焦点通道；Deps 缺 T16。 | 须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收；fixed hits/返回键/焦点接线以 T16 为前提。 | 在未定窗口形态下写 fixed hits 与返回键，换宿主后层级/关闭动画/焦点顺序全错；golden 需整体重做。 |
| :668 | `#### T41 3D 场景与查看器` | T41 是 3D 场景与纹理合成的直接消费者；其宿主通道（Qt 离屏/SurfaceTexture/Dart 直译）只能由 T16 选定，本卡自身也把 T16 写进 Deps。 | 须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收；T41 只可先产出候选无关的投影数学（S01），S02..S06 留待裁决。 | 把 T41 当“已具备实施条件”，提前接 SceneTextureHost；ADR:140 明确 T41-S02..S06 属 ARCH_BLOCKED。 |
| :669 | `- Owner: SCENE-3D · Deps: T30、T16 · Files: Create lib/scene/scene_frame.dart、lib/scene/scene_math.dart、lib/scene/picking.dart、lib/scene/viewer_state.dart、lib/scene/scene_surface.dart、android/app/src/main/kotlin/rhine/music/database/porting/SceneTextureHost.kt、Qt/porting/SceneTextureHost.h、Qt/porting/SceneTextureHost.cpp、test/scene/projection_test.dart、integration_test/scene_slice_test.dart；Modify Qt/porting/CMakeLists.txt` | 审计点：该 Files 已把宿主“打 preset”为候选 B（Qt 离屏渲染 → SurfaceTexture → FlutterTextureRegistry，见计划:471-476 与 02-adjudication.md §1 的 B 行）：`SceneTextureHost.kt` + `Qt/porting/SceneTextureHost.h/.cpp` + `scene_surface.dart` 只有 B（或含 B 的 D）成立才需要。Deps 虽写 T16，文件清单却先于裁决落地。 | 须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收；669 的 Files 必须拆为“候选源码（隔离 spike 写域）”与“生产接线（T16 后）”两段，候选 B 不得作为生产 preset。 | 在 T16 未裁决时按 B 建 `SceneTextureHost.kt`/`Qt/porting/SceneTextureHost.*` 并接 `lib/scene/scene_surface.dart`，等于无条件选 Qt 宿主；违反计划:167-168/:508/:511，且 `Qt/porting/CMakeLists.txt` 的 Modify 目标在 B/D 未落地时不存在（02-adjudication.md §1.1 交叉点）。 |
| :748 | `- **依赖**：契约未冻结不实现；切片未裁决不写页面；T43 未审定不铺竖屏；T53 未过不发布。` | 这是全局依赖规则文本；“切片未裁决不写页面”只提切片，未点名 T16，调度时可被读成“仅 T10 切片规格未冻结”，而放行 T33-T41 的页面/宿主接线（依赖清单本身缺 T16 标注）。 | 须待 T16 裁决（宿主/平台视图/窗口形态）后方可实施或验收；规则应读作“切片未裁决 = T16 未裁决”，未裁决不写页面。 | 规则留白被当作“T16 不在依赖链上”，批量派发 T33-T41；等 T16 出结果后整批返工，且期间产出无法作为候选证据。 |

补充：:509（裁决维度）与 :512（Commit 行）已用 read 核对，内容不含对外依赖语句，故不单列行；:506-512 整卡已覆盖。

## 2. ADR 只读佐证（A4 独占，本追加不改）

- `docs/flutter-migration/adr/0001-host-architecture.md:47`：`规则：任一候选触及其声明的失败出口即该候选失败；五候选全部失败**或全部未跑**时，按计划:170、计划:510 结论写“未裁决”并停止 P2 页面实现。当前状态为“0/5 已跑 → 未裁决”，故 P2 页面接线保持 ARCH_BLOCKED。`
- `docs/flutter-migration/adr/0001-host-architecture.md:140`：`| PRODUCTION WIRING → ARCH_BLOCKED | 需本 ADR 赢家或宿主 / 桥 / 域运行时真实接线 | 不可以 | T20-S01..、T21 桥、T25 平台通道、T33-T40 页面接线、T41-S02..S06、T42-T44 |`

ADR 自身把 T33-T40 页面接线与 T41-S02..S06 归为 ARCH_BLOCKED；本追加只是把该结论标注回计划行，不新增架构判断。

## 3. 行号核对（read 的 number 列）

| 计划行 | read 所见内容（行首） | 偏移 |
|---|---|---|
| :506 | `#### T16 架构裁决` | 无 |
| :507 | `- Owner: ARCH · Deps: T11-T15 …` | 无 |
| :508 | `- [ ] 只汇总已跑候选的同切片数据；…` | 无 |
| :510 | `- [ ] 若全失败，结论写“未裁决”并停止 P2 页面实现。` | 无 |
| :511 | `- Pass: ADR 能让下一位工程师独立复核。…` | 无 |
| :608 | `- Owner: PAGE-ARCHIVE · Deps: T30-T32、T22 …` | 无 |
| :624 | `- Owner: PAGE-SEARCH · Deps: T30-T32、T22 …` | 无 |
| :631 | `- Owner: PAGE-LIBRARY · Deps: T30-T32、T22、T24 …` | 无 |
| :639 | `- Owner: PAGE-SETTINGS · Deps: T30-T32、T06、T27 …` | 无 |
| :647 | `- Owner: PAGE-DISCOVER · Deps: T30-T32、T22 …` | 无 |
| :654 | `- Owner: PAGE-PLAYER · Deps: T30-T32、T23 …` | 无 |
| :662 | `- Owner: PAGE-MODALS · Deps: T30-T32、T06 …` | 无 |
| :668 | `#### T41 3D 场景与查看器` | 无 |
| :669 | `- Owner: SCENE-3D · Deps: T30、T16 …` | 无 |
| :748 | `- **依赖**：契约未冻结不实现；…` | 无 |

全部审计行号与真实文件一致，无需写“行号偏移：实际 :N”。

## 4. Binding ruling（收口；不得反向解释）

1. **不得据此选 QtPlatformView**：T16 = UNASSIGNED / PENDING_DEVICE_EVIDENCE；无真机证据门不得产生候选赢家/宿主/主生产接线，本追加不构成对 QtPlatformView 的授权。
2. **不得把候选 A 注册为最终产品**：候选 A（PlatformView 切片，计划:462-469）与 B/C/D/E 同为未跑候选；不得在组合根、provider 注册或依赖清单里把 A 写成最终宿主。
3. **保双方向、不锁横屏**：DEDUP-39 的固定 `sensorLandscape`/仅横屏方案与用户要求的竖屏响应式冲突；可修源生 immersive/resume 行为，但不得锁定横屏，也不得盲目套 `resizeableActivity=false`。竖屏属响应式设计，不得冒充 Qt 实测竖屏像素。
4. **账号域 PAUSED_BY_USER**：DEDUP-15/16/30/32 保持暂停；本追加与 T36 行不重启账号测试、不恢复账号制作。
5. 播放所有权（DEDUP-25）在 T16 前保持 Qt/Dart 双兼容，不删 PlaybackStore、不擅自选定独立所有权。

本追加只新增依赖标注，不修改计划、ADR、reports/、lib/、android/ 的任何文件。
