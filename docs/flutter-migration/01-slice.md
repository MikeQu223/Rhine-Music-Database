# 01 · 单一垂直切片规格（T10 / 五候选共用）

> **状态**：`FROZEN_DRAFT` — 可实施、待独立审查。本文冻结**一条**切片，供 A/B/C/D/E 五个候选共用。
> 它不是设备结论，也不声称任何候选通过。最终宿主接线仍 `ARCH_BLOCKED`；像素/设备 `DEVICE_BLOCKED`；性能 `NO_THRESHOLD`（设备受限）。
> **机器可读镜像**：`test/fixtures/slice_cases.json`（schema `slice-cases/v1`）。二者不一致时，运行期以 fixture 为判据、本文为解释，且必须在同一次提交内修正。
> **计划映射**：`docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:454-460`（T10 / C01）。执行器 `tool/parity/slice_runner.dart` 与断言 `test/slice_spec_test.dart` 属 T10-F01，不在本原子。
> **卡数口径**：计划 §7 共 42 张任务卡（`:382`：P0 7 + P1 7 + P2 8 + P3 15 + P4 5）；T10 是 P1 第 1 张，本切片即 T11–T15 五候选共用的那一条。

## 0. 边界

- 本文只规定「输入序列 + 采样点 + 比较字段 + 通过/失败判据」，不规定任何候选的实现方式。
- 五候选（计划 §3.1）：

| id | 路线 | 计划轨 |
|---|---|---|
| A | Flutter host + Android PlatformView 承载 Qt view | T11 |
| B | Flutter host + Qt 离屏渲染 SurfaceTexture（FlutterTextureRegistry） | T12 |
| C | Flutter host + Dart CustomPainter 直绘 HUD + 真实 3D 端口 | T13 |
| D | 混合：Dart HUD + Qt Texture 3D | T14 |
| E | Flutter host + 本地 WebView canvas/WebGL/Three.js 全复刻 | T15 |

- **一条切片的含义**：`steps` / `rois` / `checks` / `thresholds` / `unmeasured` 五段对五候选**逐字相同**。候选不得携带自己的 steps、ROI 或阈值；候选只能声明「无法执行某步」（记 `unsupported` + 原因），该步判 `UNMEASURED`，**不是**「另一条切片」。计划的失败判据正是这条：任一候选使用不同切片 ⇒ T10 FAIL（`:459`）。

## 1. 这条切片能证伪什么

计划给 T10 的 Pass 是「脚本步骤与 ROI 完整」，Fail 是「任一候选使用不同切片」。所以本切片可判定的只有三件事：

1. **结构完整**：五候选读到的是同一份 `steps/rois/checks`（fixture 单一数组，`candidates[].overrides` 必须不存在）。
2. **同态等价**：同一 step、同一 state 下，五候选发布的 commands/hits **token 等价**——不排序、不去重、不补默认值、不合并同值命令。
3. **采样可执行**：每步都有确定的输入 action id 与 stage 坐标 ROI，任何人按表即可复现。

像素 1:1、性能分布、真实设备时序，本切片只登记「采什么、存哪里」，**不给结论**。

## 2. 冻结输入

| 项 | 值 | 证据 |
|---|---|---|
| 设备 | serial `526f6b6d`，OPD2511，Android 16 / API 36，arm64-v8a | 计划 `:76`（设备）、`:118-125`（物理/DPR/stage） |
| 物理分辨率 | 2880 × 1800 | 同上 |
| density / DPR | 315 / `1.96875`（= 315/160） | `../T02/test/fixtures/stage_metrics.json` groups[0]（跨树引用：T02 产物，本树不复制） |
| 逻辑尺寸 | `1462.8571428571429 × 914.2857142857143` | 物理 ÷ DPR |
| stageScale | `0.8465608465608465`（= 914.2857142857143 / 1080） | `layout.md` §1.1-§1.2 |
| stageWidth / stageHeight | `1728` / `1080` | `layout.md` §1.1-§1.2 |
| physicalPerStage | `1.6666666666666665`（= 1800/1080） | `layout.md` §1.1-§1.2 |
| 主题 | 基线须设 preference `theme=dark`；Qt 默认是 light，运行期记录 `state.dark` 实际值 | `NativeHud.h:140`（`dark = false` 初值）；`NativeHudController.cpp:31-35`（`preference("theme")`，空→light）；`NativeHud.cpp:206`（state 键） |
| fontScale | 1.0（HUD 字号是 stage 绝对值，**禁止**乘 textScaler） | `layout.md` §7 |
| 亮度 | 设备侧锁定；**具体值未取证，运行期记录** | UNMEASURED |
| 语言 / 时区 | zh-CN / Asia/Shanghai | 切片需要中文 IME |
| 方向 | landscape（Qt 两个 Activity 都是 sensorLandscape） | `Qt/android/AndroidManifest.xml:89,103` |
| 资料库前置 | 「全部歌曲」≥ 17 首（运行期记录实际值；不足则 S1 判 `BLOCKED_PRECONDITION`） | 切片需要「第 17 曲」 |
| 网络 | S4 需联网；离线时 S4/S5 判 `UNMEASURED`，**不得**改用本地假数据 | — |
| 播放初态 | 未播放；Android 上 `applicationVolume = false`、`seekable = false`、`durationMs = 0`；seek/volume/lyrics 命中在播放前不存在 | `PlayerBar.cpp:148-151,203-218`；`NativeHudPlayer.cpp:18,30-31`；`MusicPlayer.cpp:161`；`PlatformFeatures.h:7-16` |

所有 stage 数字都是**手算**，未在设备上核对；容差 `1e-6`（`../T02/test/fixtures/stage_metrics.json` tolerance）。

## 3. 切片脚本

顺序即计划 `:153`：启动 → archive 全部歌曲 → 打开第 17 首详情（3D 封面）→ 返回 → 搜索输入中文并打开结果 → 加入队列/移除 → 旋转竖屏再回横屏。

### S0 冷启动
- **输入**：进程不存在 → 启动。
- **期望**：至少一个 published unit `mode=="boot"`；随后 `mode=="archive"`。
- **采样**：首个 boot unit；首个 archive unit。
- **证据**：`NativeHud.cpp:267-270`（boot 分支；`draw()` 主链 `:224-312`）；`NativeHudBoot.cpp:155-311`。

### S1 archive 选中第 17 曲（index 16）
- **前置**：archive 已有选中曲（`current` 非空）；`全部歌曲` 数量 ≥ 17；**无分组过滤**（`groupLane == -1`；分组生效时才是 `groupLane == selectedLane`，此时 `music:index:<i>` 经 `groupIndices` 映射到别的库索引，见 `MusicLibrary.cpp:193,238`、`NativeHudMusic.cpp:75,89`）。
- **输入**：若 `state.trackListMode == false` 先发 `archive:tab-mode`（并记录这次切换）；再发 `music:index:16`。
- **期望**：`frame.selected` 是 0–39 物理槽位（不是资料库索引 16），运行期记录其值并要求五候选一致；`current.kind == "song"`；`current.title` 非空。
- **注意**：`current.title` **不写死**——运行期记录，并要求五候选逐字相同。`music:index` 只选中，不切详情（`NativeHudMusic.cpp:79-95`）。
- **可执行性**：`music:index:16` 的 hit 只在行 `rowY` 落在 `titleY±270` 内且 `opacity>0.5` 时登记（`NativeHud.cpp:536-594,586-589`），index 16 未必在可视带。本步按 **action 注入**执行；若某候选只能点击驱动，先按 `next` 推进到命中登记条件成立（`NativeHud.cpp:586-589`：`rowY` 在 `titleY±270` 内、`opacity>0.5`；静止时 d=0..4 的偏移为 0/88/140/192/244，d>=5 时 opacity=0，故有效可见带为 ±4 行，但代码没有字面 `|index-position|<=4` 判断；实际次数由运行期 `position` 决定，**不得**写死），并在 summary 记 `injection: injected|tapped`。两种方式必须产出同一 state 与同一份命令流。
- **证据**：`NativeHudMusic.cpp:79-95`；`NativeHud.cpp:536-594`（archiveTrackList 命中仅在该行 y 落在 titleY±270 且 opacity>0.5 时登记）；`MusicLibrary.cpp:616-640`（`selectResult` 发出的是 physical 槽位）；`NativeSceneFrame.cpp:97`、`NativeScene.cpp:135`（`selected` 即物理槽位）。

### S2 打开第 17 曲详情（3D 封面）
- **输入**：`open`（archive 页 `open` 命中，或 ENTER）。
- **期望**：`mode=="detail"`；`viewer==false`；`frame.detail` 由 0 → 1，**500 ms 墙钟** smoothstep（`NativeHud.cpp:247-250` 记录/复位 `m_detailEnterWallMs`，`:280-288` 求值，不跟伪时钟）。
- **实际绘制不透明度** = `max(frame.detail, smoothstep(wall/500ms))`——墙钟只在伪时钟停滞时接管，保证最终收敛到 1（`NativeHud.cpp` 注释原文：「500 ms 淡入，与场景曲线同形（smoothstep）。取两者较大值」）。
- **采样**：首个 `mode=="detail"` unit；进入后 ≥500 ms 的 unit；稳定 unit。
- **证据**：`NativeHudController.cpp:624-639`；`NativeHud.cpp:247-250,280-288`；`NativeHudDetail.cpp`；`SongDetailCard.cpp`。

### S3 返回 archive
- **输入**：`back`（等价 ESC，`NativeHudController.cpp:917`）。
- **期望**：`mode=="archive"`；`current.id` 不变；`frame.selected` 不变。
- **要点**：无 directory 时 `back` 分支不 return，落到 `:682-683` 的 `m_scene.mode("archive")`——这是资料库详情页真实的返回路径（`:641-650` 只管目录栈）。
- **证据**：`NativeHudController.cpp:641-650`、`:682-683`。

### S4 搜索：中文 IME 输入
- **输入**：`search`（开面板）→ 点输入框（真实 `TextInput`，`Overlay.qml:519-520`）→ IME 组合 `ce shi` 后 commit `测试` → Enter。
- **期望**：`modal=="search"`；`query=="测试"`；700 ms 去抖后**恰好一次**检索派发；结果列表非空（若 0 结果，记录关键词并判 `UNMEASURED`，不得改词重试后当成同一份证据）。
- **IME 语义**（`Qt/tests/InputMethodChecks.cpp:31-49`）：preedit 期间 text 必须为空；commit 只插入一次并清 preedit；重复 commit 追加。
- **采样**：面板打开 unit；commit 后 unit（query 已变、结果未变）；去抖完成 unit。
- **命中替换**：modal 分支执行 `hits = {}`（`NativeHudModal.cpp:173`）⇒ 底层 archive 页仍被绘制但命中被清空，本步只有 search 命中 + PlayerBar `fixed` 命中；nav/footer 只在像素里，无命中。
- **遮罩**：search 打开时 mask 盖满 stage（dark `rgba(17,24,27,0.15)` / light `rgba(227,224,215,0.12)`）；PlayerBar 在 `modalDraw` 之后绘制，**不**受 modal alpha 影响。
- **证据**：`NativeHudController.cpp:145-163`（token 去抖）；`NativeHudSearch.cpp`；`Overlay.qml:519-552`。

### S5 打开第 1 条搜索结果
- **输入**：点结果列表第 1 行。该行 action 是 `music:result:<lane>:<entry.index>`，`entry.index` 是**该行的资料库索引**，不是行号（`NativeHudSearch.cpp:206-210`）⇒ 运行期从 `hit.action` 读取并记录，**禁止写死** `:0`。
- **前置**：第 1 条结果必须 `kind=="song"`；否则记录实际 `kind` 并判 `UNMEASURED`，**不得**换关键词重试后当同一份证据。
- **期望**：`modal==""`；`session.view.tab=="overview"`；`current` 等于该行对象；`mode=="detail"`（`selectResult` 默认 `open=true`，`kind=="song"` ⇒ `detail`；`MusicLibrary.cpp:637-639`）。
- **要点**：Android 上结果行是 **up-trigger**（`Overlay.qml:262-278`），kind/group 标签是 down-trigger；>6 **stage 单位**的纵向拖动取消点击（`Overlay.qml:248` 比较的是 item 局部即 stage 坐标 `mouse.y`；拖动在 `:252-257` 先 `mapToItem` 换算成窗口像素再喂 `wheelInput`，滚轮事件在 `:279-283` 用 `mapToItem` + `/stageScale` 换算）。
- **证据**：`NativeHudMusic.cpp:92-97`；`MusicLibrary.cpp:637-639`；`Overlay.qml:202-212,244-278`。

### S6 详情页加入队列
- **输入**：`music:enqueue`（详情 secondaryActions 第 1 个；S5 已进入详情）。
- **期望**：`mode=="detail"`；队列长度 +1。
- **证据**：`NativeHudMusic.cpp:224-230`；`NativeHudDetail.cpp:134`。

### S7 队列面板移除
- **前置**：队列长度 ≥ 2（存在非当前行；`player:remove` 只对非当前行绘制）；否则本步判 `UNMEASURED`，不得改用 `player:clear` 伪造。
- **输入**：点 `roi.player.queue`（`player:open`）→ `player:remove:<i>` → `close-modal`。
- **期望**：开面板时 `modal=="player"`；移除后队列长度 −1；关闭后 `mode=="detail"`。
- **要点**：移除命中只对非当前行绘制（`PlaybackQueueCard.cpp`）；`player:clear` 只清 pending，不在本步使用。
- **命中替换**：同 S4，`hits = {}` ⇒ 本步只有 player 面板命中 + PlayerBar `fixed` 命中；detail 页仍被绘制但无命中。
- **证据**：`NativeHudController.cpp:359-364`；`PlaybackQueueCard.cpp`；`NativeHudModal.cpp:175-179`。

### S8 旋转竖屏
- **输入**：设备侧旋转到竖屏（本原子禁止 adb，由设备操作者执行）。
- **期望**：stage 重算为竖屏候选之一（`Portrait-W` / `Portrait-Band` / `Portrait-Hybrid`，**未裁决**，三者并列记录）；**不**重登、**不**重启 Node、**不**重建 media source；`current.id`、队列、modal、query、相对滚动偏移、3D 相机/时钟连续。
- **竖屏 stage（本机手算）**：`portraitStageScale = 914.2857142857143/1080 = 0.8465608465608465`；`portraitStageWidth = 1080`；`portraitStageHeight = 1462.8571428571429/0.8465608465608465 = 1728`（`layout.md` §6 公式；**未**设备核对）。
- **ROI 政策**：竖屏几何未裁决 ⇒ **横屏 ROI 矩形一律不得套用到竖屏**；S8 只采 `roi.portrait.full`（整屏 `1080×1728`），并判 `UNMEASURED`。连续性靠 state/frame 断言，不靠像素。
- **证据**：`Main.qml:37-38`；`NativeHud.cpp:252-256`；`layout.md` §6-§7。

### S9 旋回横屏
- **输入**：旋回横屏。
- **期望**：stage 回到 `1728×1080`（容差 `1e-6`）；`state` 与 `session.view` 与 S8 前一致。
- **页面上下文**：S7 以 `close-modal` 结束，`mode` 仍是 `detail`（`close-modal` 不切 mode）⇒ 旋回横屏后仍是详情页，ROI 用**横屏详情集**（`roi.detail.*`），不是 archive 页。
- **hits 必须同代重建**：不得复用竖屏帧的命中矩形（`NativeHud.cpp:252-256`）。
- **证据**：`layout.md` §7；`NativeHud.cpp:252-256`。

## 4. 采样与导出

每个 published unit 一行 JSONL：

```json
{"schema":"slice-unit/v1","candidate":"A","step":"S2","unit":3,"generation":null,
 "tMonotonicMs":12345,"wallClock":"2026-11-10T02:00:00.000Z",
 "commands":[],"hits":[],"frame":{},"state":{},"current":{},"session":{}}
```

- `generation` 是 Flutter 桥**拟议**信封字段（`contracts/hud-protocol.md` §1.3，**不在 `frame` 对象内**）；Qt 无此字段 ⇒ 必须写 `null`，且**禁止**据此去重、排序或丢弃同值命令。不得为 `frame` 新增远端 generation 字段。
- `commands` 原序、`hits` 原序、`frame` 原样（未知 key 保留，不得裁剪成「已知字段」）。
- 每个 unit 还带 `current`（`NativeApplication.cpp:147-151` 的 `result.current`，含 kind/title/id）与 `session`（采集器在同一个 step 边界调用 `NativeApplication::sessionState()`，见 `Qt/src/MusicSession.cpp:215-235`：library/player/view；这是**采集字段，不是 Qt result 字段**）；`frame.selected` 是物理槽位 0–39，不是资料库索引。
- `frame` **不得固化键数或顺序**：`NativeSceneFrame.cpp:87-119` 写主体键，`:164-167` 追加 `actorTemplate`/`appearanceRevision`/`actors` 后交 `NativeCards::expand`；成功路径 `NativeCards.cpp:236-237`、`:303-304` 移除 `actorTemplate`/`actors`，失败提前返回则保留，`:195-213` 另设 `stats` ⇒ 成功/失败路径键集不同。消费者只按键名取用、保留全部未知键，**禁止**断言固定键数。
- 同一 unit 的 commands/hits/frame/state 必须**同代**；generation 不一致时丢弃**整个**快照，而不是某一个数组（`hud-protocol.md` §4.5）。
- step 可带可选 `notes: string[]`（仅供人读，不参与判定）；`step.rois` 是唯一采样源。
- 每步发布至少 3 个 unit（动作前 / 动作后 / 稳定后）；S2 因 500 ms 淡入额外 +1；`sampling` 只列必须命名的关键点，其余按动作前/动作后/稳定后补齐，不要求穷举。
- 文件命名：
  - `evidence/slice/<candidate>/<step>/<unit>.jsonl`
  - `evidence/slice/<candidate>/<step>/roi/<roiId>.png`
  - `evidence/slice/<candidate>/summary.json`
- 截图：整屏 2880×1800 + 每个 ROI 单独裁切；裁切用 `stage rect × physicalPerStage`，对比前统一换算到同一坐标系。
- 导出格式（与 T03 对齐）：commands = 17 种 opcode 的裸数组，原序；hits = 恰好六字段对象（`fixed` 仅 PlayerBar）；frame = 列主序矩阵，background/fogColor 为无 alpha 线性 RGB。

## 5. ROI 表

坐标一律 **stage**（1080 高，原点左上）。W = 1728。表达式是权威，取值是 W=1728 的实例；若某分量静态不可求（例如依赖运行期字体度量），必须在 `expr` 中标注 UNMEASURED，取值只作占位。

`usable = width - width*0.56 - 59`（`NativeHudDetail.cpp:56,60`）；W=1728 时 `701.32`；detail 面板宽 `usable + 48 = 749.32`。

| ROI | 步 | stage 表达式 | W=1728 取值 | 比较 | 证据 |
|---|---|---|---|---|---|
| `roi.nav.bar` | S1–S7,S9 | `(width-789, 118, 789, 54)` | `(939, 118, 789, 54)` | layout | `NativeHud.cpp:121-124`（`control(...)` → `hit(x-10, y, width+20, 54)`，命中高恒 54）、`:342-344`（navigationLeft=width-789）、`:345-356`（四次 `control` 的 y 均为 118；:348/:350/:352/:354 的 184 与 :355 的 120 是 **width 实参**，不是高度） |
| `roi.footer` | S1–S7,S9 | `(0, 960, width, 24)` | `(0, 960, 1728, 24)` | text | `NativeHud.cpp:357-373`（:358 dot 59,971,5,5；:370 session 75,967,10；:372 credit 右对齐 width-59） |
| `roi.player.bar` | S1–S7,S9 | `(0, 984, stageWidth, 96)` | `(0, 984, 1728, 96)` | layout | NativeHud.cpp:309-311; PlayerBar.h:42 |
| `roi.player.seek` | S1–S7,S9 | `(0, 978, stageWidth, 18)` | `(0, 978, 1728, 18)` | layout | PlayerBar.cpp:148-151（仅 `seekable && durationMs>0`；否则本 ROI 不存在，summary 记 `conditional:false`） |
| `roi.player.controls` | S1–S7,S9 | `(stageWidth/2-89, 1008, 178, 48)` | `(775, 1008, 178, 48)` | glyph | PlayerBar.cpp:85-87 |
| `roi.player.like` | S1–S7,S9 | `(stageWidth*0.23-24, 1008, 48, 48)` | `(373.44, 1008, 48, 48)` | glyph | `PlayerBar.cpp:167-170,239`（`favoriteX = width*0.23`；hit 48×48） |
| `roi.player.lyrics` | S1–S7,S9 | `(stageWidth-494, 1008, 48, 48)` | `(1234, 1008, 48, 48)` | glyph | `PlayerBar.cpp:201-204,247`（仅 `hasTrack`；center x = right-470；否则不存在） |
| `roi.player.mode` | S1–S7,S9 | `(stageWidth-404, 1008, 48, 48)` | `(1324, 1008, 48, 48)` | glyph | `PlayerBar.cpp:198,248`（center x = right-380） |
| `roi.player.volume` | S1–S7,S9 | `(stageWidth-300+58, 1031, 100, 28)` | `(1486, 1031, 100, 28)` | layout | `PlayerBar.cpp:208-218,238`（`outputX = right-300`；仅 `applicationVolume`；Android 恒 false ⇒ 不存在） |
| `roi.player.queue` | S1–S7,S9 | `(stageWidth-79, 1000, 54, 65)` | `(1649, 1000, 54, 65)` | glyph | `PlayerBar.cpp:219-224`（`queueX = right-65`；hit `queueX-14,y+16,54,65`） |
| `roi.boot.full` | S0 | `(0, 0, width, 1080)` | `(0, 0, 1728, 1080)` | pixels | NativeHud.cpp:267-270（boot 分支；主链 `:224-312`）; NativeHudBoot.cpp:155-311 |
| `roi.portrait.full` | S8 | `(0, 0, 1080, portraitStageHeight)` | `(0, 0, 1080, 1728)` | pixels | `layout.md` §6（竖屏形态未裁决）；`../T02/test/fixtures/stage_metrics.json` portraitCandidates[]（跨树引用） |
| `roi.archive.title` | S1,S3 | `(width-789, 509, width-(width-789)-59, 37)` | `(939, 509, 730, 37)` | text | `NativeHud.cpp:428-433,536-594`（S1/S3 的 `trackListMode=true` ⇒ `archiveTrackList`；本 ROI 取选中行 `rowY=509`、`textWidth=561`，含 `x=1568` 的 ruler；`:435` 的 title/hit 分支不执行） |
| `roi.archive.select` | S1,S3 | `(0, 840, width*0.2625+366, 130)`（整条选曲条：TRACK/SELECT、reel number、↑、8 个 slot、↓、底部提示；nav=453.6） | `(0, 840, 819.6, 130)` | glyph | `NativeHud.cpp:455-460,464-478,494-496` |
| `roi.archive.columns` | S1,S3 | `(width*0.5234375, 890, 370, 70)` | `(904.5, 890, 370, 70)` | glyph | `NativeHud.cpp:479-490`（col=width*0.5234375=904.5；← col,903,46,46；名称 col+70=974.5；→ col+310=1214.5） |
| `roi.archive.tabmode` | S1 | `(width-348, 854, 186, 48)` | `(1380, 854, 186, 48)` | text | NativeHud.cpp:500-514 |
| `roi.archive.ruler` | S1 | `(width-160, centerY-272, 1.5, 544)`；y 非静态：`centerY = 509 + bounds(音乐,28,bold).y + height/2`（`NativeHud.cpp:543-546`），依赖运行期字体度量 | `(1568, 237, 1.5, 544)`（x/width/height 确定；**y=237 是占位、UNMEASURED**） | pixels | `NativeHud.cpp:536-546,596-598` |
| `roi.detail.scene` | S2,S5,S9 | `(0, 0, width*0.56, 1080)` | `(0, 0, 967.68, 1080)` | scene3d | `NativeHudDetail.cpp:45-84`（左侧 HUD：返回 59,211@:70、ID 60,845@:71、MUSIC DATABASE 60,893@:72、DRAG TO INSPECT 60,917@:73、查看封面 60,944@:74）；`NativeHud.cpp:328-331`（brand 59,115.425/59,173）；`NativeSceneFrame.cpp:87-213` |
| `roi.detail.panel` | S2,S5,S6,S9 | `(width*0.56-24, 260, width-(width*0.56-24)-35, 696)` | `(943.68, 260, 749.32, 696)` | pixels | NativeHud.cpp:167-174（detailBounds）; NativeHudDetail.cpp:66-68（面板填充） |
| `roi.detail.back` | S2,S5,S9 | `(59, 211, 360, 54)` | `(59, 211, 360, 54)` | text | NativeHudDetail.cpp:70 |
| `roi.detail.id` | S2,S5,S9 | `(60, 845, 330, 37)` | `(60, 845, 330, 37)` | text | NativeHudDetail.cpp:71 |
| `roi.detail.viewer` | S2,S5,S9 | `(60, 944, 260, 35)` | `(60, 944, 260, 35)` | text | NativeHudDetail.cpp:74 |
| `roi.detail.header` | S2,S5,S9 | `(width*0.56-24, 260, usable+48, 210)` | `(943.68, 260, 749.32, 210)` | glyph | SongDetailCard.cpp:54-68（顶线 260、chip 280、TRACK RECORD 282、rule 314、album 332、title 366/406、artist 416/450） |
| `roi.detail.primary` | S2,S5,S9 | `(width*0.56, 476, usable, 44)` | `(967.68, 476, 701.32, 44)` | text | SongDetailCard.cpp:69; NativeHudDetail.cpp:118-133 |
| `roi.detail.secondary` | S2,S5,S6,S9 | `(width*0.56, 532, usable, 44)` | `(967.68, 532, 701.32, 44)` | text | SongDetailCard.cpp:70; NativeHudDetail.cpp:134 |
| `roi.detail.tabs` | S2,S5,S9 | `(width*0.56, tabsY, usable, 44)`，`tabsY = (tab=="history") ? 584 : 720` | `(967.68, 720, 701.32, 44)`（S2/S5/S9 tab 默认 `overview`） | text | SongDetailCard.cpp:71,100-108 |
| `roi.detail.body` | S2,S5,S9 | `(width*0.56, 786, usable, 93)` | `(967.68, 786, 701.32, 93)` | text | NativeHudDetail.cpp:194-202 |
| `roi.detail.bottom` | S2,S5,S9 | `(width*0.56, 910, usable, 44)` | `(967.68, 910, 701.32, 44)` | text | NativeHudDetail.cpp:203-213（按钮按条件绘制：official 需 `PlatformFeatures::OfficialPlayback && !local`，Android 恒 false；preview 需 provider==qq；remove-track 需可编辑歌单；基线记录实际绘制集合） |
| `roi.search.mask` | S4,S5 | `(0, 0, width, 1080)` | `(0, 0, 1728, 1080)` | pixels | NativeHudModal.cpp:163-165 |
| `roi.search.bar` | S4,S5 | `(left+53, 294, modalWidth-106, 66)` | `(917, 294, 699, 66)` | pixels | NativeHudSearch.cpp:53-59; NativeHud.cpp:140-159 |
| `roi.search.input` | S4,S5 | `stage (inputX, inputY+modalOffset, inputWidth, 54); logical = ×stageScale` | `stage (917, 302, 699, 54)` | layout | Overlay.qml:519-531; NativeHud.cpp:184-186 |
| `roi.search.kinds` | S4,S5 | `(left, 374, modalWidth, 36)` | `(864, 374, 805, 36)` | text | NativeHudSearch.cpp:73-82 |
| `roi.search.list` | S4,S5 | `(left+53, 450, modalWidth-106, 430)` | `(917, 450, 699, 430)` | text | NativeHud.cpp:188-191; NativeHudSearch.cpp:175-215 |
| `roi.search.footer` | S4,S5 | `(left+53, 900, modalWidth-106, 20)` | `(917, 900, 699, 20)` | text | NativeHudSearch.cpp:232-252（dot :234、status :235-236、label :243-250） |
| `roi.queue.panel` | S7 | `(left, 122, modalWidth, 836)` | `(234, 122, 1260, 836)` | pixels | NativeHud.cpp:140-159; NativeHudModal.cpp:175-179 |
| `roi.queue.header` | S7 | `(bounds.x+53, bounds.y, bounds.width-106, 210)` | `(287, 122, 1154, 210)` | text | PlaybackQueueCard.cpp |
| `roi.queue.modes` | S7 | `(x, y+269, width, 40)` | `(287, 391, 1154, 40)` | text | PlaybackQueueCard.cpp |
| `roi.queue.rows` | S7 | `(x, y+358, width, 7*56)` | `(287, 480, 1154, 392)` | text | PlaybackQueueCard.cpp |

ROI 集按步解析：`S1`–`S7`、`S9` 恒含十项全局 ROI（`roi.nav.bar`、`roi.footer`、`roi.player.*`）；`S0`（`mode=="boot"`）不绘制 PlayerBar / navigation / footer（`NativeHud.cpp:269-270` 是 else-if boot 分支，执行 `boot(width)` 后继续到 `:306-311`；nav/footer 只在 else 分支 `:272-277`；`:309-311` 只跳过 PlayerBar），只有 `roi.boot.full`；`S8`（竖屏）几何未裁决，只有 `roi.portrait.full`。带 `conditional` 的三项（seek / volume / lyrics）在条件不成立时不采像素，但必须在 summary 记录条件值，**不得**静默跳过。fixture 已在每个 `step.rois` 中逐步展开，runner 只读 `step.rois`。

比较类型：
- `pixels` — 整块裁切与 Qt 基线逐像素（当前 `UNMEASURED`，见 §8）。
- `text` — 文案、字号、字重、tracking、位置（命令级断言 + 裁切人工比对）。
- `glyph` — 字形路径/图标形状与 baseline 1.044 行为。
- `layout` — 矩形与边界（静态 stage 矩形容差 `1e-6`；命中矩形容差 `UNMEASURED`，见 §7）。
- `scene3d` — 真实 3D draw：`frame.draws` 非空、view/projection/eye 自洽；静态图或视频帧 = FAIL。
- `hit`/`state` — 见 §6。

## 6. 检查项

### 6.1 命中
1. 每个 hit 去掉 PlayerBar 专有的 `fixed` 后**恰好** `x,y,width,height,action,label` 六字段；非 PlayerBar 命中出现第七个键即失败；`label` 为 string，`label.isNull()` 时回落 `action`（显式空串保留），且 **PlayerBar hit 的 `label` 必须非空**（`PlayerBar::hit` 不回退）——`NativeHud.cpp:102-109`、`PlayerBar.cpp:46-53`（PlayerBar 追加 `fixed:true`）、`contracts/hud-protocol.md` §3.1 `:153-155`。
2. `fixed:true` **只**出现在 PlayerBar 命中（`player:*`、`music:like-current`）；非 PlayerBar 命中带 `fixed` = 契约失败——`PlayerBar.cpp:46-53`（唯一追加 `fixed` 的 hit 实现）、`Overlay.qml:191`（`fixed` 命中不随 `modalOffset` 平移）。
3. hits 保持 source append 顺序；不按 z/坐标/action 排序；不去重。
4. 重叠顺序是行为：搜索结果从 index 0 向上扫描、命中第一个包含点即停（`Overlay.qml:268-277`）。
5. 触摸 padding 只加在触摸层（Android 四边 +16），**不得**写回源矩形——`Overlay.qml:38-43`。
6. 尺寸变化后 hits 必须同代重建；上一帧的命中矩形不得复用（`NativeHud.cpp:252-256`）。

### 6.2 IME
1. preedit 期间 text 为空；commit 只插入一次；重复 commit 追加（`InputMethodChecks.cpp:31-49`）。
2. 700 ms 去抖后恰好一次检索派发；token 变了就丢弃旧结果（`NativeHudController.cpp:145-163`）。
3. 键盘开合**不得**改变 `stageScale/stageWidth`；真实输入框逻辑矩形 = stage 矩形 × stageScale，无第二层偏移（`layout.md` §5.4）。
4. 打开搜索面板聚焦真实输入框；关闭回到 input layer；**Android 上结果点击后焦点不回到输入框**（`restoreInputFocus` 定义在 `Overlay.qml:50-62`，只在 `#ifdef Q_OS_WIN` 下由 `PresentationShell.cpp:252,1302` 调用；非 Windows 直接 `focusInputLayer`）——这是记录项，不是待修项。
5. Android 键盘是否真的弹出：Qt 源码无显式 raise 调用 ⇒ `UNPROVEN`。

### 6.3 无障碍
1. **基线事实**：Qt 在 Android 上**主动关闭**无障碍桥——`AndroidWindow` 安装吞事件的 update handler 并 `QAccessible::setActive(false)`，日志 `"Android: Qt accessibility bridge disabled (foreground ANR safeguard)"`；只有 `RHINE_ANDROID_ACCESSIBILITY=1` 才保留（`AndroidWindow.cpp:59-71`）。头文件说明原因：滑动时递归遍历整棵 `QAccessibleQuickWindow` 树，主线程被打满；不影响功能，也不影响 Clarity（`AndroidWindow.h:10-22`）。
2. **因此**：Qt 基线不发布任何 a11y 树，role/state/节点树**无可比基线**，一律 `UNMEASURED`。
3. **label 只在数据层可比**：每个 hit 的 label 与 Qt 逐字一致（Qt 为 null 时取 action）。
4. **新设计**：把 hit label 暴露成 Flutter `Semantics` 是**偏差/新增能力**，必须显式标注为 NEW DESIGN，**不得**当成 Qt 平价要求，也不得据此声称 a11y PASS。

### 6.4 媒体会话
1. `update(playing, positionMs, durationMs, title, artist, album, coverPath)` 与同一 unit 的播放状态一致（`AndroidMediaSession.h`）。
2. 旋转**不调用 `stop()`**；旋转后的 metadata 更新仍会调用 `ensureStarted()`（重复调用无害：`RhineMediaService.java:64-70` 在 `instance != null` 时直接返回），`stop()` 只在 title 为空或 duration≤0 时发生（`PlatformAndroid.cpp:62-71`）；前台服务 `instance` 前后相同（`RhineMediaService.java:95-98,110-113,117-120`）。
3. 媒体动作走字节面语义、不依赖交互帧：`resume`/`pause` → `setPaused`，`next`/`prev` → `player.next(±1)`，其余（含 `toggle`）→ `hud.action("player:"+action)`（`NativeApplication.cpp:197-213`）。
4. 本切片脚本没有通知/锁屏按键入口，动作往返与通知渲染：`UNMEASURED`；不得把静态映射当成设备证据。

### 6.5 旋转
1. 顺序固定：metrics 变 → 重算 StageMetrics → 同代重建 commands/hits/frame → 画一帧 → 之后所有命中/IME 用同一套 metrics（`layout.md` §7）。
2. 连续性：`current.id`、队列、modal、query、相对滚动偏移、3D 相机/时钟。
3. **禁止**：重登、dispose player、清列表、重启 Node、`runApp` 重建、按设备类型分支（OrientationBuilder 判断设备形态）、把 textScaler 乘进 stage。

### 6.6 返回键
1. 资料库详情页 `back` → `mode("archive")`，`current` / `frame.selected` 不变（`:641-650` 落到 `:682-683`）。
2. modal 打开时 ESC 先关 modal（`:913-921`）；`modal` 非空时其他键不进入全局快捷键（`:923-925`）。

### 6.7 3D
1. 封面区是**真实 3D draw**：`frame.draws` 非空、view/projection/eye 自洽；静态图/视频帧 = FAIL。
2. frame/commands/hits/state 同代（`NativeApplication.cpp:98-151`）。
3. viewer 覆盖语义与 HUD 读取键 `mode/viewer/detail` 见 `contracts/hud-protocol.md` §4。

## 7. 预登记判定

| 判定项 | 状态 | 依据 |
|---|---|---|
| 结构完整（五候选同一份 steps/rois） | **DECIDABLE** | fixture 单一数组；`candidates[].overrides` 不存在 |
| 同态等价（commands/hits token 等价） | **DECIDABLE** | 同 step 同 state 直接比对 |
| stage 度量（stageScale/stageWidth/logical/DPR） | **DECIDABLE** | 容差 `1e-6` |
| 非文本派生命中矩形 | **UNMEASURED** | 计划只给 frame 投影 `1e-9`，未给命中容差；无真实噪声证据，不得自造容差或据此宣称 PASS |
| 文本派生命中矩形（标签宽度） | **UNMEASURED** | 跨引擎字形度量无对照 |
| 像素 1:1 | **UNMEASURED** | 无同设备同场景 Qt 基线；`DEVICE_BLOCKED` |
| SSIM ≥ 0.97 / ΔE ≤ 3 | **PROPOSED_UNFROZEN** | 计划 `:229-233` 标为拟议，未冻结；**不是门** |
| 性能（fps/帧间隔） | **NO_THRESHOLD** | 计划 `:162` 只记录分布 |
| 30 分钟稳定性 | **UNMEASURED** | 未执行 |
| 最终宿主接线 | **ARCH_BLOCKED** | 计划硬门 |

**禁止事后改阈值**：任何阈值只能在拿到基线后、以单独提交冻结，并写清基线来源；本文件的 `PROPOSED_UNFROZEN` 与 `UNMEASURED` 项不得被就地改成 PASS。

## 8. 未测量清单

1. 像素 1:1 —— 所有 `pixels` ROI。
2. SSIM/ΔE 阈值（拟议，未冻结）。
3. 竖屏最终形态（Portrait-W / Portrait-Band / Portrait-Hybrid 未裁决）。
4. 真实 safe-area / 刘海 / 圆角值（`../T02/test/fixtures/stage_metrics.json` 中 portraitInsets 全 0 是算术值，不是设备测量）。
5. Android 键盘弹出时窗口是否 resize（Manifest 无 `windowSoftInputMode`）。
6. 软键盘是否真的弹出（源码无显式 raise）。
7. IME 候选窗高度/位置、中文预编辑在 Android 上的视觉。
8. 搜索框 stage 高 `54×stageScale` 的物理尺寸；触摸 padding `16×stageScale` 的物理效果。
9. 真实设备 stageWidth / stageScale（手算，未核对）。
10. 媒体通知/锁屏控件渲染与动作往返。
11. 无障碍 role/state（Qt Android a11y 桥被显式关闭，无树可比）；Flutter Semantics 属新设计。
12. 性能分布（帧间隔/掉帧/内存）。
13. 30 分钟稳定性。
14. 文本度量跨引擎一致性（Qt `Glyphs::width` vs Flutter 段落度量）。

## 9. 禁止事项

- 禁止为任一候选改写 steps/ROI/阈值；禁止「候选 X 用另一套坐标」。
- 禁止把 `fixed` 推广到非 PlayerBar 命中，禁止给 hits 加 `z`/层级/页面坐标。
- 禁止对 commands 去重、排序、补默认值、裁剪未知 opcode（未知 op 整条跳过并继续）。
- 禁止把 1800 当 QML 高度、把截图坐标当 dp、把 textScaler 乘进 stage。
- 禁止用大遮罩 / 全局 SSIM / 降特征来「通过」。
- 禁止把 `PROPOSED_UNFROZEN` 或 `UNMEASURED` 直接写成 PASS。
- 禁止在设备/接线硬门未解除时宣称设备 PASS。

## 10. 溯源

| 主题 | 来源 |
|---|---|
| 切片内容与硬门 | 计划 `:147`、`:153`、`:155-163`、`:229-233`、`:454-460` |
| 设备/DPR/stage 公式 | `contracts/layout.md` §1.1-§1.2；`../T02/test/fixtures/stage_metrics.json`（跨树引用） |
| 协议 17 op / hits / frame | `contracts/hud-protocol.md` §1-§4；`Qt/src/Glyphs.cpp:530-829` |
| 命中六字段 / fixed | `Qt/src/NativeHud.cpp:102-109`；`Qt/src/PlayerBar.cpp:46-53` |
| 布局常量 | `Qt/src/NativeHud.h`；`Qt/src/NativeHud.cpp:140-196,224-360,404-594` |
| 详情/队列/搜索/资料库 | `Qt/src/NativeHudDetail.cpp`、`PlaybackQueueCard.cpp`、`NativeHudSearch.cpp`、`NativeHudLibrary.cpp`、`SongDetailCard.cpp` |
| 动作派发 | `Qt/src/NativeHudController.cpp:359-364,624-650,682-683,917-938`；`Qt/src/NativeHudMusic.cpp:61-97,220-230` |
| IME | `Qt/qml/Overlay.qml:519-552`；`Qt/tests/InputMethodChecks.cpp:31-49` |
| 媒体会话 | `Qt/src/AndroidMediaSession.h` |
| 旋转连续性 | `Qt/qml/Main.qml:37-38`；`Qt/src/NativeHud.cpp:252-256`；`contracts/layout.md` §7 |
