# 竖屏验收规格与全入口清单（T51）

- 状态：**新增设计，不是 1:1 复刻**；竖屏样板未冻结（WAIT-CANDIDATE）；像素验收未取证（DEVICE_BLOCKED）。
- 本轮**未执行**任何命令：未跑 flutter/dart/gradle/pub/adb、未构建、未测试、未 analyze、未截图、未生成 golden。本文所有结论均为**静态源码与契约证据**，不得读作「已通过」。
- 任务：竖屏验收规格与登录 fixture（计划卡 T51）。
- Owner：QA-PORTRAIT · 依赖：T43、T50、T02、T05。
- 证据日期：2026-11-10 · 计划：`docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md`（T51 见 :710-716，§6.4 见 :361-365，旋转连续性见 :369-376）。
- 产物：`docs/flutter-migration/acceptance/portrait.md`（本文件）、`test/fixtures/parity_cases/portrait_login.json`（机器可读副本）。
- 本卡原子：T51-C18（修 T51-C01-M12 的 4 项必修并同步 fixture）。fixture 与本文同批修订：补「97 = 文本出现数」口径、`physicalPerStage` 唯一定义、T43 符号/版本引用、platform-gated 排除。所有模板**只定义、未填充、未执行**。
- 不在本文件写入域：`test/golden/portrait/full_suite_1080x2400.png`（计划中列出，**未生成**，见 WAIT-GOLDEN）。

## 1. 判定口径（先读）

| 项 | 本卡立场 |
| --- | --- |
| 横屏 | 以 Qt 功能/画面/动作/状态/时序 1:1 为准（本卡不改横屏公式） |
| 竖屏 | **新增响应式重排**，保留业务语义（入口/文本/动作/状态/视觉语言），不隐藏、不裁切、不硬缩 |
| Qt 竖屏像素基线 | **不存在**。Qt 两个 Activity 均为 `sensorLandscape`，HUD 只有 1080 高度画稿；本卡不假造竖屏像素基线 |
| 旧 Flutter UI | **不是规范**，不得作为竖屏验收基准 |
| 三档尺寸 | **拟议测试矩阵**，不是已证实真机基线 |
| 未审定项 | 一律列入第 9 节 WAIT，不写「通过」 |

## 2. 范围与非目标

### 2.1 范围内

1. 竖屏可用窗口布局的三档拟议矩阵（公式 + 不变式 + 验算）。
2. 安全区 / IME / 触摸命中 / 系统字尺度的竖屏验收断言。
3. 入口/动作清单（12 个 HUD 文件内 `hit()`/`button()` 文本出现 **97** 处，含 3 处函数定义；另列 `canvas.hit` 30 处与 `control()` 12 处创建点，见 6.1。97 **不是完备入口面**）。
4. 六条真实登录路径 + 六相位 + 取消屏障 + 轮询语义的验收断言（fixture 见 `test/fixtures/parity_cases/portrait_login.json`）。
5. 旋转/尺寸变化时的状态连续性清单。

### 2.2 非目标（明确禁止）

- **不得**把竖屏写成「与 Qt 1:1」；竖屏没有 Qt 像素基线。
- **不得**预设：所有模态都用 bottom sheet、所有页面都单列、固定 48dp 触摸目标、固定 52% 3D 占比。这些必须由 T43 在同一 widget 上比较 Portrait-W / Portrait-Band / Portrait-Hybrid 的可达性、层级、触摸、字尺度之后冻结。
- **不得**以竖屏为由隐藏任何入口、裁切内容或对 stage 做硬缩（`stageWidth` 恒为 1080）。
- **不得**在竖屏把系统字体缩放乘进 stage（会破坏 Qt HUD 的绝对字号语义）。
- **不得**用 `OrientationBuilder` 按设备类型分支：只按可用尺寸判断横竖屏（T02 layout.md §7.3）。
- **不得**在旋转时 `runApp` 重建、销毁播放器、清空列表或要求重新登录。

### 2.3 竖屏响应式语义（新增定义）

「响应式」在本卡只有一个含义：**同一套舞台坐标与动作流，在可用窗口尺寸变化时只重排容器几何，语义逐项不变**。它不是「另做一套竖屏 UI」，也不是「把横屏画布拉伸」。

| 层 | 允许变化 | 明令禁止 | 证据 |
| --- | --- | --- | --- |
| L0 舞台常量 | 无 | 改 `stageWidth`；把安全区或 IME 乘进 `stageScale`；改底栏高 96、触摸扩张 16 | T02 layout.md §6；`computePortraitBands` 的 `stageScale`/`stageWidth`（T43 快照 :631,635）、`QtStageGeometry.playerBarHeight`（:391）、`touchPaddingFor`（:602-608）、`imeStage`（:658）；`Qt/qml/Overlay.qml:38-43` |
| L1 容器重锚 | 新增竖向容器的 top/bottom/height；左右安全区收窄其内容宽 | 改动作名/顺序/时序；隐藏或裁切入口；对 stage 硬缩 | T02 §6；`computePortraitBands` 的 safe→stage 换算（:654-661）、`switch (mode)` 三模式（:686-714） |
| L2 可选新容器（未冻结） | 顶栏 96 + 内容 + 底栏三段（Hybrid）；固定 1080 宽分带；单列 | 预设「所有模态 bottom sheet」「所有页面单列」「固定 48dp」「固定 52% 3D」 | plan §6.4 :361-365；`PortraitBandMode`（:41）、`PortraitImePolicy`（:44）、`switch (mode)` 三模式（:686-714） |

语义不变式（任一条不成立即不通过，与尺寸档位无关）：

| ID | 不变式 | 可判据 |
| --- | --- | --- |
| S1 | 非平台门控入口不变：§6 已枚举动作行中排除 `N/A_PLATFORM_GATED` 的每一行在三档尺寸全部可达，只允许重锚 | 每个非平台门控 action 至少一条命中矩形落在可用内容区或固定底栏内；平台门控项按 §5.1 填 `N/A_PLATFORM_GATED` 并记录门控条件，不参与可达性判定 |
| S2 | 绘制与命中分离：触摸扩张 16 stage px 只在命中层，绝不回写命令流 | 同一 action 的 draw rect 与 hit rect 可分别取出且不相等 |
| S3 | 文字语义不变：label/字号/换行取自 stage 单位；系统 `textScaler` 不乘进 stage | 同一 label 的 stage 字号不随尺寸或系统字缩放改变；同一 label 的换行/截断点在三档尺寸与 `textScaler` 变化下保持一致（逐动作记录；未取证项列 `WAIT-VISUAL-EVIDENCE`） |
| S4 | 状态机不变：登录六相位、播放、队列、歌词、设置复用同一实例 | 旋转前后为同一状态对象，相位不重置 |
| S5 | 时序不变：QR 1000 ms × 300、SMS 60000 ms 墙钟、冷却倒计时、滚动曲线 0.46 s、FadeWidth 300 均不随尺寸变化 | 常量与横屏同源，逐值相等 |
| S6 | 判定口径不变：横屏继续以 Qt 1:1 为准；竖屏只判「语义保留 + 拟议矩阵下的可达性/层级/触摸/字尺度」 | 文档与测试不得出现「竖屏 1:1」 |
| S7 | 系统返回/手势不改变应用内层级语义（plan :364） | 返回动作前后模态栈与应用内页面栈不变；不得因系统返回直接退出应用或重置状态 |

响应式输入只有三个，且都只进新容器、都不进 stage：

| 输入 | 来源 | 允许影响 | 不得影响 |
| --- | --- | --- | --- |
| `layoutWidth/layoutHeight` | `LayoutBuilder` 逻辑尺寸（未预扣 inset） | `stageScale = layoutWidth/1080`、`stageHeight`、分带数 | 动作流、字号语义 |
| `MediaQuery.padding` | 系统安全区 | `stageHeight = (layoutHeight-safe.top-safe.bottom)/stageScale`、新容器 top 与左右内容宽 | `stageWidth`、`stageScale`、横屏公式 |
| `MediaQuery.viewInsets.bottom` | 软键盘（清单为 `adjustResize`） | **无**：平台已缩小逻辑窗口，几何不得再读 `viewInsets`；`imeStage` 恒 0 | `stageScale`、`stageWidth`、`stageHeight`、底栏位置 |

横竖屏判据只按可用尺寸：`aspect = width/height < 1.05`（`Qt/src/NativeSceneCamera.cpp:56-57`；T02 §7.3）。**不得**按设备类型或 `OrientationBuilder` 分支。

## 3. 三档拟议测试矩阵

公式（竖屏，来源 T02 `docs/flutter-migration/contracts/layout.md` §6）：

```
dpr                 = density / 160
logicalWidth/Height = physical / dpr
portraitStageScale  = layoutWidth / 1080        (layoutWidth = 可用窗口逻辑宽，未预扣 inset)
physicalPerStage    = physicalWidth / 1080     (= dpr × portraitStageScale，只由物理宽定)
portraitStageWidth  = 1080                     (常量)
portraitStageHeight = (layoutHeight - safe.top - safe.bottom) / portraitStageScale
                    = 1080 * physicalHeight / physicalWidth   (safe=0 时只由物理宽高比决定)
bandHeight          = 1080 ; bandCount = ceil(stageHeight / 1080)
Hybrid: topBar = 96 ; bottomBar = 96 ; contentHeight = stageHeight - 192 - safe.top/scale - safe.bottom/scale
playerBar           = (0, stageHeight - 96, 1080, 96)   (底边 = stageHeight，落在手势区之上)
```

| 档位 | 物理 | density | dpr | 逻辑可用窗口 | stageScale | physicalPerStage | stageWidth | stageHeight | bandCount | contentHeight（Hybrid，无 inset） | 底栏 y | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| P1 | 1080×2400 | 420 | 2.625 | 411.428571 × 914.285714 | 0.380952381 | 1 | 1080 | 2400 | 3 | 2208 | 2304 | 拟议（数值取自 T02 fixture） |
| P2 | 1440×3200 | 480 | 3 | 480 × 1066.666667 | 0.444444444 | 1.333333333 | 1080 | 2400 | 3 | 2208 | 2304 | 拟议（数值取自 T02 fixture） |
| P3 | 1200×2000 | **未冻结** | — | — | — | 1.111111111 | 1080 | 1800 | 2 | 1608 | 1704 | WAIT-GEOM-1200x2000（density/dpr/logical/stageScale 未冻结） |

### 3.1 本卡做的独立验算（纯静态算术，非运行验证）

| 验算 | 结果 |
| --- | --- |
| P1 dpr = 420/160 = 2.625；1080/2.625 = 411.428571；2400/2.625 = 914.285714 | 与 T02 fixture 一致 |
| P1 stageScale = 411.428571/1080 = 0.380952381；stageHeight = 914.285714/0.380952381 = 2400 | 一致 |
| P2 dpr = 3；480/1080 = 0.444444444；1066.666667/0.444444444 = 2400 | 一致 |
| 无安全区时 stageHeight = 1080×physH/physW：1080×2400/1080 = 2400；1080×3200/1440 = 2400；1080×2000/1200 = 1800 | 三档成立（safe=0） |
| bandCount = ceil(2400/1080) = 3；ceil(1800/1080) = 2 | 成立 |
| contentHeight（safe=0）= 2400-192 = 2208；1800-192 = 1608 | 成立；有安全区时按 `stageHeight-192-safe.top/scale-safe.bottom/scale` 重算 |
| 横屏交叉核对：2880×1800 / dpr 1.96875 → 逻辑 1462.857143×914.285714；stageScale = 914.285714/1080 = 0.846561；stageWidth = 1462.857143/0.846561 = 1728 | 与 T02 冻结值一致 |

**要点**：`safe=0` 时 `stageHeight` 与 `bandCount` 只与物理宽高比有关，与 density 无关；因此 P1/P2 虽 density 不同却同为 2400/3 带。表内三档均取 `safe=0`；真机上下安全区会按 `(layoutHeight-safe.top-safe.bottom)/scale` 改 `stageHeight`。`physicalPerStage = physicalWidth/1080 = dpr×stageScale` 也只由物理宽决定，与 density 无关：P1=1、P2=1.333333333、P3=1.111111111。依赖 density 的是 `dpr`、`logicalWidth` 与 `stageScale`；P3 正是因为 density 未冻结才整行未冻结。

### 3.2 三档的语义边界（尺寸≠设备）

| 项 | 结论 |
| --- | --- |
| 三档是什么 | **拟议测试矩阵**：供静态推导与后续真机取值；不是设备枚举，不是真机基线，也不是 golden 尺寸 |
| 三档不是什么 | 不是「已测像素」；P3 的 density 未冻结（WAIT-GEOM-1200x2000），本文不得为它补一个值 |
| 可静态断言的量 | `stageHeight = (layoutHeight-safe.top-safe.bottom)/scale`（safe=0 时 = 1080×physH/physW）、`bandCount`、`physicalPerStage = physicalWidth/1080`、底栏与底栏输入层 rect、Hybrid 无 inset 时的 `contentHeight` |
| 依赖 density 的量 | `dpr`、`logicalWidth`、`stageScale`；P3 的这三项未冻结（`physicalPerStage` 不在此列） |
| 分带取整 | 用「容差 ceil」：比值落在整数 1e-6 内不得多算一带（`ceilWithTolerance`，T43 快照 :578-587；容差常量 `qtGeometryTolerance = 1e-6`，:38）。如 3×1080=3240 时 ratio=3.0 仍为 3 带 |
| 退化处理 | 安全区吃满可用高宽时进 `PortraitBands.degeneracies`，**不静默夹取**；`content.height <= 0` 时 `computePortraitBands` 抛 `FlutterError`（DEDUP-21），绝不把非正高度交给 `Positioned` |

三候选（T43 已实现为参数，**未裁决赢家**；本卡不选型、不写推荐、不据此改横屏）：

| 候选 | 内容区（stage 单位，safe 已折算；adjustResize 下无 ime 项） | 分带 | 底栏 | 状态 |
| --- | --- | --- | --- | --- |
| Portrait-W | `(safeL, safeT, 1080-safeL-safeR, stageHeight-96-safeT-safeB)` | 1 | `(0, stageHeight-96, 1080, 96)` | 未裁决 |
| Portrait-Band | `(safeL, safeT, 1080-safeL-safeR, stageHeight-safeT-safeB)`，跨带连续 | `ceilTol(stageHeight/1080)`，第 k 带 `y=k×1080` | 贴底，可覆盖最后一带 | 未裁决 |
| Portrait-Hybrid | `(safeL, safeT+96, 1080-safeL-safeR, stageHeight-192-safeT-safeB)` | 1（`[topBar, content, playerBar]`） | `(0, stageHeight-96, 1080, 96)` | 未裁决 |

无 inset 时 Hybrid 即 §3 表中的 `contentHeight = stageHeight-192`（2400→2208，1800→1608）；上表是含安全区的完整式。清单保持 `adjustResize`，平台已缩窗口，矩形公式不再出现 `ime` 项（`imeStage = imeConsumedStage = inputShiftStage = 0`）。T43 的参数化只覆盖**垂直锚点与分带**；列数/弹层形态仍属 WAIT-CANDIDATE，不得据此认定水平语义已裁决。§4 的模态宽度公式（stage 1080、模态 980/760）是 T02 冻结常量，不由候选裁决改变。

底栏输入层（不是命中层）修正：Qt `row(bounds.x(), 984, width, RowHeight=96)` 之后 `inputBounds = row.adjusted(0, -6, 0, 0)` → **(0, 978, 1080, 102)**；既不是 96 高，也不是 bottom=1074（`Qt/src/PlayerBar.cpp:241-242`；T43 快照 :399-404 已记录该修正：`QtStageGeometry.inputShieldTop=978`、`inputBoundsHeight=1080-978`）。竖屏同源换算为 `(0, stageHeight-102, 1080, 102)`，且它必须包含进度条与音量命中（`Qt/tests/NativeHudChecks.cpp:474-484`）。

## 4. 竖屏几何契约（引用 T02，不在此重新定义）

| 项 | 值/公式 | 证据 |
| --- | --- | --- |
| Portrait-W | stageScale = layoutWidth/1080；stageWidth = 1080；stageHeight = (layoutHeight-safe.top-safe.bottom)/scale；底栏 (0, stageHeight-96, 1080, 96) | T02 layout.md §6 |
| Portrait-Band | stageHeight = (layoutHeight-safe.top-safe.bottom)/scale；bandHeight = 1080；bandCount = ceil(stageHeight/1080)；bandY = k×1080 | T02 layout.md §6 |
| Portrait-Hybrid | stageHeight = (layoutHeight-safe.top-safe.bottom)/scale；topBar = 96；bottomBar = 96；content = (0, 96, 1080, stageHeight-192-safe.top/scale-safe.bottom/scale) | T02 layout.md §6；§3.2 完整式 |
| 模态宽（stageWidth=1080） | 默认 min(1260, 1080-100) = 980，left = 50 → (50, 122, 980, 836)；搜索 min(1080-100, max(760, min(1000, 1080×0.5-59 = 481))) = 760，left = 1080-760-59 = 261 → (261, 122, 760, 836) | T02 layout.md §4.1；Qt `NativeHud.cpp:140-159` |
| 候选差异 | T43 参数化各候选只改**垂直锚点**，宽度公式不变；列数/弹层形态仍属 WAIT-CANDIDATE | T02 layout.md §6；T43 快照 :686-714 |
| 3D | 项目已有 `aspect < 1.05` 分支；竖屏缺的是 HUD 布局，不是 3D 能力；竖屏 3D 占比未裁决 | plan :361-365；WAIT-3D-SHARE |
| 底栏命中 | 仅 PlayerBar 命中带 `fixed:true`；打开模态时 fixed 命中不被 modalOffset 平移 | plan :211-214；`PlayerBar.cpp:46-53` |

> 本节以 §3.2 的完整式为准（T02 §6 只给无 inset 基础形态）。分带用容差 ceil（防浮点误差多算一带）；`safe.top/safe.bottom` 只出现在 `stageHeight` 公式与内容内缩两处，Hybrid 内容高按 `stageHeight-192-safeT-safeB`，不再固定 `stageHeight-192`。清单保持 `adjustResize`，几何不读 `viewInsets`，`ime` 项恒 0；只有未来改 `adjustNothing` 才重新引入 IME 压缩项。以上都不改变本表其余常量。

## 5. 安全区 / IME / 触摸 / 字尺度 验收矩阵

| 规则 | 断言 | 证据 | 状态 |
| --- | --- | --- | --- |
| 安全区-垂直 | `stageHeight = (layoutHeight-safe.top-safe.bottom)/stageScale`；`containerTop = safe.top / stageScale`（stage 单位）；安全区在舞台高度里**只扣一次**，底栏底边 = `stageHeight`，抬到手势区之上 | T02 §6 | 规则已冻结 |
| 安全区-水平 | 左右安全区只收窄新容器内容宽度，**不改变** `stageWidth`/`stageScale` | T02 §6 | 规则已冻结 |
| 安全区-横屏 | 安全区**不得**进入横屏公式 | T02 §6 | 规则已冻结 |
| 安全区-数值 | 真实安全区数值 | 无源码证据（Qt 无安全区代码） | WAIT-SAFE-AREA |
| IME | 清单保持 `adjustResize`：平台已缩小窗口，几何**不得读** `viewInsets`；`stageScale`/`stageWidth`/`stageHeight`/底栏均不因键盘改变，`imeStage = imeConsumedStage = inputShiftStage = 0`。只有未来改 `adjustNothing` 才用 `viewInsets` 压容器 | T02 §5.4/§6 | 规则已冻结 |
| IME-横屏 | Flutter 清单为 `adjustResize`：键盘缩窗口，`stageScale` 按新逻辑高重算；禁止再用 `viewInsets` 手工缩放 | `android/app/src/main/AndroidManifest.xml:28`；T02 §5.4 | 规则已冻结 |
| 输入框 rect | 真实输入框逻辑 rect **恒等于** stage rect × stageScale，不额外加 offset/padding（搜索/账号/验证码/设置编辑同理） | T02 §5.1/§5.4 | 规则已冻结 |
| 触摸 | 扩张 **16 stage px**、四边、**仅命中层**，经 stageScale 换算为逻辑坐标；**不得写回**命令流 | T02 §3（`Overlay.qml:38-43`） | 规则已冻结 |
| 触摸下限 | 不引入 Material 48dp 规范；最小目标尺寸属于 T43 待冻结项 | plan :361-365 | WAIT-CANDIDATE / WAIT-48DP |
| 字尺度 | 系统 `textScaler` **不得**乘进 stage（Qt HUD 字号是绝对 stage 单位）；真实输入框字号同样随 stage | T02 §7.3 | 规则已冻结 |
| 可访问性字号策略 | 需要单独策略，不在本卡冻结 | plan / T32 | WAIT-ACC |

### 5.1 安全区 / IME 全动作验收模板（新增，written-not-executed）

用法：对 §6 的每个动作行各占一行。§6 的动作清单来自 12 个文件内 97 处 `hit()`/`button()` 文本出现（含 3 处定义），并**不含** `canvas.hit` 30 处与 `control()` 12 处创建点（见 §6.1）；因此它是「已枚举动作」，不是完备入口面。只有满足 (a) 落在新增竖向容器内、(b) 是真实文本输入、(c) rect 依赖 `stageHeight` 三者之一时，SAFE 与 IME 列必填；否则填 `N/A_NOT_IN_CONTAINER` 或 `N/A_NOT_INPUT` 并写理由。平台门控项（桌面歌词、`window:fullscreen`、桌面专用设置）填 `N/A_PLATFORM_GATED`，仍须填 `rot`/`measure` 与门控条件，不得据此判「入口缺失」。候选冻结前，SAFE/IME 的必填判断按三候选并集执行；冻结后按最终候选收敛。

| 列 | 取值/格式 | 说明 |
| --- | --- | --- |
| `action` | Qt 字面量，保持原序与大小写 | 取自 §6 |
| `evidence` | `file:line` | 命中创建点或分派点 |
| `drawRect` / `hitRect` | `x,y,w,h`（stage） | 必须分别记录；`hitRect` 可含四边 +16 |
| `anchor` | `band-1` / `content` / `pinned` | 竖屏锚点类别 |
| `safe` | `PASS_STATIC` / `WAIT-SAFE-AREA` / `N/A_NOT_IN_CONTAINER` / `N/A_PLATFORM_GATED` | 见下表断言 |
| `ime` | `PASS_STATIC` / `N/A_NOT_INPUT` / `N/A_PLATFORM_GATED` | 见下表断言；`adjustResize` 规则已冻结 |
| `rot` | `PASS_STATIC` / `BLOCKED_DEVICE` | 见 §8.1 |
| `measure` | `unexecuted` / `device:<model>` | 本轮一律 `unexecuted` |

状态码字典（只有前两码算「通过」，且都不等于「已测」）：

| 码 | 含义 | 允许用于 |
| --- | --- | --- |
| `PASS_STATIC` | 源码或公式可证该断言成立 | 规则类断言（stage 常量、rect 公式、状态机） |
| `PASS_MEASURED` | 真机/截图/frame 取证 | **本轮一律不得使用** |
| `WAIT-GEOM-1200x2000` / `WAIT-SAFE-AREA` / `WAIT-CANDIDATE` / `WAIT-ACC` / `WAIT-48DP` / `WAIT-3D-SHARE` / `WAIT-VISUAL-EVIDENCE` / `WAIT-TEMPLATE-EXEC` / `WAIT-GOLDEN` / `WAIT-DEVICE` | 依赖未冻结值或设备 | 安全区真实值、候选裁决、48dp、3D 占比、视觉取证、模板未执行等，按 §9 逐项对应 |
| `BLOCKED_DEVICE` | 设备取证被禁 | 像素、性能、触摸手感 |
| `FAIL` | 断言不成立 | 任意 |

安全区断言（逐动作填，不按页面整体填）：

| ID | 断言 | 判据/证据 |
| --- | --- | --- |
| SAFE-V1 | 按候选实例化：W / Band `drawRect.y ≥ safeT`；Hybrid `drawRect.y ≥ safeT+96`（顶栏占 96） | 三模式内容顶分别在快照 :689,701,709；`PortraitBands.contentTop` 只等于内容顶，`containerTop` 只等于 `safeT`（:729），不可单独用作 Hybrid 判据 |
| SAFE-V2 | 内容底按候选：W / Hybrid `= stageHeight - 96 - safeB`；Band `= stageHeight - safeB`（底栏贴底、可覆盖最后一带）。`playerBar.bottom = stageHeight`；W / Hybrid 还须 `content.bottom <= playerBar.y`，Band 不要求该不等式（允许覆盖最后一带）。`adjustResize` 下 `ime = 0` | 三模式 bottom 式见快照 :690,702,710；`PortraitBands.playerBar` 与 `content` |
| SAFE-H1 | 新容器内 `drawRect.x ≥ safe.left/stageScale` 且 `right ≤ 1080 - safe.right/stageScale` | 只作用于新增竖向容器 |
| SAFE-H2 | `stageWidth`、`stageScale`、模态宽（980/760）不因安全区改变 | 逐值相等（T02 §6） |
| SAFE-L1 | 横屏分支不读 `padding` | 代码断言，禁止把安全区带进横屏 |
| SAFE-Z0 | `safe = 0` 时结果与无安全区公式逐值相等 | 同一函数，常量偏移为 0 |
| SAFE-D1 | 左右安全区吃满宽度 → `degeneracies` 非空且不夹取 | 快照 :660-664（`contentWidth ≤ 0` 记退化，不夹取） |

IME 断言（逐动作填）：

| ID | 断言 | 判据/证据 |
| --- | --- | --- |
| IME-1 | `stageScale`、`stageWidth`、`stageHeight`、底栏与 IME 无关 | 弹出前后逐值相等（`Qt/qml/Main.qml:32` 横屏同源；竖屏公式见 §3） |
| IME-2 | `adjustResize` 下 `imeStage = 0`；几何不读 `viewInsets.bottom` | 平台缩窗口；`PortraitBands.imeStage` 恒 0 |
| IME-3 | compress / shiftUp 均不产生几何差异：`imeConsumedStage = inputShiftStage = 0` | 两策略仅为源码兼容保留，**不参与** `adjustResize` 计算 |
| IME-4 | 输入框逻辑 rect `= stage rect × stageScale`，不额外加 offset/padding | 搜索/账号/验证码/设置编辑同源（T02 §5.1/§5.4） |
| IME-5 | 底栏输入层仍为 `(0, stageHeight-102, 1080, 102)` 且包含进度条与音量命中 | `PlayerBar.cpp:241-242`；`NativeHudChecks.cpp:474-484` |
| IME-6 | 任意 `viewInsets` 变化几何逐值不变（幂等） | 两次计算深相等（`PortraitBands.operator==`，快照 :314-335） |
| IME-7 | IME 开合不产生动作副作用 | 命令流零新增（不 login/cancel/play/queue/seek） |

分组模板（12 组 = §6.1 的 12 个来源文件；数量是 `hit/button` 文本出现数，合计 97，含 3 处定义，不是完备入口面）：

| # | 组（来源文件） | `hit+button` 文本出现数 | 必填列 | 备注 |
| --- | --- | --- | --- | --- |
| G1 | `Qt/src/NativeHud.cpp` | 14 | SAFE-V1/V2、IME=`N/A_NOT_INPUT` | 归档遮罩按新容器高度重锚 |
| G2 | `Qt/src/NativeHudBoot.cpp` | 1 | SAFE-V2 | `skip` 必须重锚，禁止与底栏重叠 |
| G3 | `Qt/src/NativeHudDesktopLyrics.cpp` | 3 | `N/A_PLATFORM_GATED` | 桌面专用，Android 不出现 |
| G4 | `Qt/src/NativeHudDetail.cpp` | 22 | SAFE-V1、IME-4（歌词偏移另有输入） | 查看器沿用 `aspect<1.05` 分支 |
| G5 | `Qt/src/NativeHudDiscover.cpp` | 1 | SAFE-V1 | 垂直锚点待 T43 |
| G6 | `Qt/src/NativeHudLibrary.cpp` | 8 | SAFE-V1、IME-4（短信/账号） | 登录面板 |
| G7 | `Qt/src/NativeHudLocal.cpp` | 8 | SAFE-V1 | `y+200…767` 在 band-1 |
| G8 | `Qt/src/NativeHudModal.cpp` | 20 | SAFE-V1 | 模态垂直锚点待 T43 |
| G9 | `Qt/src/NativeHudPlayer.cpp` | 1 | SAFE-V2 | 队列面板 |
| G10 | `Qt/src/NativeHudSearch.cpp` | 4 | SAFE-V1、IME-3/4 | 模态宽 760 不变 |
| G11 | `Qt/src/NativeHudSettings.cpp` | 4 | SAFE-V1、IME-4（编辑项） | 滚动步长 120 不变 |
| G12 | `Qt/src/PlayerBar.cpp` | 11 | SAFE-V2、IME-5 | 唯一 `fixed:true` 命中组 |

**本轮状态**：模板只定义、未填充、未执行（`WAIT-TEMPLATE-EXEC`）；任何一行都不构成「已验收」。

WAIT 落点：`WAIT-SAFE-AREA` 用于真实安全区数值；`WAIT-CANDIDATE` 用于候选裁决；`WAIT-48DP` 用于最小触摸目标；`WAIT-3D-SHARE` 用于 3D 占比；`WAIT-VISUAL-EVIDENCE` 用于视觉取证；`WAIT-TEMPLATE-EXEC` 用于本模板未执行；`WAIT-ACC` 用于系统字体缩放策略。

## 6. 全入口与动作清单

### 6.1 清单生成方法与完备性

Qt HUD 层的入口创建至少有四类路径：`NativeHud::hit(...)`（`NativeHud.cpp:102`）、`NativeHud::button(...)`（`NativeHud.cpp:110-112`，内部转调 `hit`）、`NativeHud::control(...)`（`NativeHud.cpp:121-122`，内部转调 `hit`），以及 6 个 Card 文件里的 `canvas.hit`（安装为回调后转调 `NativeHud::hit`；安装点 `NativeHudSettings.cpp:190-192`、`NativeHudPlayer.cpp:68-70`、`NativeHudDesktopLyrics.cpp:87-89`）。因此只 grep `hit(`/`button(` **不是**完备入口面。

下表是 **12 个 HUD 文件内 `hit`/`button` 的字面文本出现次数**（含 3 处函数定义：`NativeHud.cpp:102`、`NativeHud.cpp:110`、`PlayerBar.cpp:46`），合计 97。它是文本出现普查，不是入口数：

| 文件 | `hit()` 文本出现 | `button()` 文本出现 | 备注 |
| --- | --- | --- | --- |
| `Qt/src/NativeHud.cpp` | 8 | 6 | 含 `hit`/`button` 两处定义与 `control()` 内的 `hit` 转调 |
| `Qt/src/NativeHudBoot.cpp` | 0 | 1 | |
| `Qt/src/NativeHudDesktopLyrics.cpp` | 1 | 2 | |
| `Qt/src/NativeHudDetail.cpp` | 5 | 17 | |
| `Qt/src/NativeHudDiscover.cpp` | 1 | 0 | |
| `Qt/src/NativeHudLibrary.cpp` | 4 | 4 | |
| `Qt/src/NativeHudLocal.cpp` | 0 | 8 | |
| `Qt/src/NativeHudModal.cpp` | 3 | 17 | |
| `Qt/src/NativeHudPlayer.cpp` | 1 | 0 | |
| `Qt/src/NativeHudSearch.cpp` | 4 | 0 | |
| `Qt/src/NativeHudSettings.cpp` | 2 | 2 | |
| `Qt/src/PlayerBar.cpp` | 11 | 0 | 含 `hit` 一处定义 |
| **合计** | **40** | **57** | **97（含 3 处定义）** |

未计入 97 的入口创建面（完备性缺口）：

| 原语 | 数量 | 位置（文件:行） | 说明 |
| --- | --- | --- | --- |
| `canvas.hit` | 30 | `DesktopLyricsSettingsPage.cpp:113,114,134,156,285,297`（6）；`CollectionDetailCard.cpp:77,87,100,110,151,184,240`（7）；`DiscoverMusicCard.cpp:123,145,214`（3）；`PlaybackQueueCard.cpp:31,90`（2）；`SettingsCard.cpp:61,75,88,130,138,142,158,172,184`（9）；`SongDetailCard.cpp:41,90,105`（3） | 经上述三处安装的 `canvas.hit` 回调转调 `NativeHud::hit`；逐条都是入口创建点 |
| `NativeHud::control` | 12 | `NativeHud.cpp:348,350,352,353,355,378,410,418,423,425,426,452` | 每次 `control(...)` 经 `:122` 的 `hit` 创建一条入口；grep `hit(` 只能数到 `:122` 一行 |

结论：§6 的动作清单是「12 文件 `hit/button` 文本出现 97（含 3 定义）」的整理结果，可用于动作词法与竖屏回归，但**不得**据此断言入口全集或覆盖完备。完备入口面还须并入 `canvas.hit` 30 处与 `control()` 12 处（以及后续新增原语）；本卡未逐条展开后两者，故 §6.2–6.7 不是完备入口表。

动作词法命名空间解析入口：`Qt/src/NativeHudController.cpp:433-926`（前缀分派：`setting:`/`update:`/`tab:`/`provider:`/`local:`/`discover:`/`player:`/`music:`/`viewer:`/`quality:set:`/`archive-mask:`/`gpu-index:`/`expand:`/`fsr-quality:`/`fsr-sharpness:`/`aa-mode:`/`msaa:`/`aa-scale:`/`render-scale:`/`desktop-lyrics:`），以及 `Qt/src/NativeHudMusic.cpp:37-376`（`music:*` 子动作）。

### 6.2 主页 / 资料库（Archive）

| 入口 | action | 证据（file:line） | stage 坐标（Qt 横屏口径） | 竖屏预期 |
| --- | --- | --- | --- | --- |
| 首页卡片 | `open` | `NativeHud.cpp:436`；分派 `NativeHudController.cpp:624` | x, 509, 414×37 | band-1 复用（509+37 < 984） |
| lane 槽位 | `music:slot:<i>` | `NativeHud.cpp:474` | x-6, 900, 26×50 | 保留（950 < 984） |
| 搜索入口 | `search` | `NativeHudController.cpp:626` | — | 保留 |
| 个人库 | `saved` | `NativeHudController.cpp` 模态白名单；`NativeHud.cpp:402` | — | 保留 |
| 设置 | `settings` | `NativeHudController.cpp:408,721,723` | — | 保留（七区块顺序不变） |
| 发现 | `discover` | `NativeHudController.cpp:678`；`NativeHudModal.cpp:300` | — | 保留；`isLocal()` 时改写为 `local`（`:73-75`） |
| Tab Mode | `archive:tab-mode` | `NativeHud.cpp:502` | x-8, 854, 186×48 | band-1 保留 |
| 翻页 | `prev` / `next` | `NativeHud.cpp:465,478` | nav…, 903, 46×46 | 保留（x 由 stageWidth 1080 计算） |
| 列切换 | `column-prev` / `column-next` | `NativeHud.cpp:480,490` | 903, 46×46 | 保留 |
| 遮罩 | `archive-mask:<v>` | `NativeHudController.cpp:729`；`SettingsSchema.cpp:495` | 裁剪 (0,0,width,984) | 竖屏需按新容器高度重锚（requires T43） |

### 6.3 底栏（PlayerBar，固定）

| 入口 | action | 证据 | stage 坐标 | 竖屏预期 |
| --- | --- | --- | --- | --- |
| 上一首 | `player:prev` | `PlayerBar.cpp:85` | x-89, y-24, 44×48 | 固定底栏 (0, stageHeight-96, 1080, 96)，`fixed:true` |
| 播放/暂停 | `player:toggle` | `PlayerBar.cpp:86` | x-23, y-23, 46×46 | 同上 |
| 下一首 | `player:next` | `PlayerBar.cpp:87` | x+45, y-24, 44×48 | 同上 |
| 歌词 | `player:lyrics` | `PlayerBar.cpp:136,204` | —, y+14, w×74 | 同上 |
| 进度 | `player:seek-fraction:0` | `PlayerBar.cpp:150` | 全宽 | 同上（宽度按 1080） |
| 收藏 | `music:like-current` | `PlayerBar.cpp:170` | x-24, y-24, 48×48 | 同上 |
| 播放模式 | `player:mode` | `PlayerBar.cpp:198` | x-24, y-24, 48×48 | 同上 |
| 音量 | `player:volume-fraction:0` | `PlayerBar.cpp:217` | 右内侧 | 同上；应用内音量在竖屏同样受 `PlatformFeatures::ApplicationVolume` 门控（`NativeHudController.cpp:436`） |
| 队列 | `player:open` | `PlayerBar.cpp:224` | queueX-14, y+16, 54×65 | 同上 |

### 6.4 详情 / 3D 查看器 / 歌词

| 入口 | action | 证据 | 竖屏预期 |
| --- | --- | --- | --- |
| 返回资料库 | `back` | `NativeHudDetail.cpp:70` | 保留（59, 211, 360×54） |
| 查看封面 | `viewer` | `NativeHudDetail.cpp:74` | 保留 |
| 曲目行 | `music:album-track:<i>` | `NativeHudDetail.cpp:178` | 保留 |
| 复制文本 | `detail:copy` | `NativeHudDetail.cpp:200`；分派 `NativeHudController.cpp:486` | 保留 |
| 官方客户端 | `music:official` | `NativeHudDetail.cpp:205` | 保留（`PlatformFeatures` 门控 `:435`） |
| 试听 | `music:preview` | `NativeHudDetail.cpp:209` | 保留（QQ 分支 `NativeHudMusic.cpp:222`） |
| 从歌单移除 | `music:remove-track` | `NativeHudDetail.cpp:212` | 保留 |
| 关闭歌词 | `player:lyrics-close` | `NativeHudDetail.cpp:225` | 保留 |
| 歌词来源 | `player:lyrics-sources` | `NativeHudDetail.cpp:227`；模态 `NativeHudController.cpp:340` | 保留 |
| 重新查找歌词 | `player:lyrics-retry` | `NativeHudDetail.cpp:249` | 保留 |
| 歌词偏移 | `player:lyrics-offset` | `NativeHudDetail.cpp:336`；模态 `:328` | 保留 |
| 回到当前句 | `player:lyrics-follow` | `NativeHudDetail.cpp:337` | 保留 |
| 目录返回 | `music:directory` | `NativeHudDetail.cpp:508` | `sideWidth` 需按 1080 重算 |
| 查看器关闭 | `viewer:close` | `NativeHudDetail.cpp:518` | 保留；竖屏走已有 `aspect<1.05` 分支 |
| 清晰/磨砂 | `viewer:clear` / `viewer:frosted` | `NativeHudDetail.cpp:523,524` | 保留 |
| 原始视角 | `viewer:reset` | `NativeHudDetail.cpp:526,528` | 保留 |
| 封面正面 | `music:cover-front` | `NativeHudDetail.cpp:527` | 保留（x = 1080/2+18） |
| 歌词偏移步进 | `player:lyrics-earlier/later/reset/apply-global` | `NativeHudModal.cpp:104-114` | 保留 |

### 6.5 搜索 / 模态 / 平台 / 音质 / 歌单

| 入口 | action | 证据 | 竖屏预期 |
| --- | --- | --- | --- |
| 搜索标签/排序/分组/结果行 | `search:*`（含 `music:group-back`） | `NativeHudSearch.cpp:75,104,126,210` | 模态宽 760、left 261（stageWidth 1080） |
| 资料库标签/排序 | `music:group-back` 等 | `NativeHudLibrary.cpp:126,156,177` | 保留 |
| 搜索结果 | `music:result` | `NativeHudMusic.cpp:92` | 保留 |
| 详情排序 | `music:sort-menu` / `music:sort` | `NativeHudDetail.cpp:406`；`NativeHudMusic.cpp:40,44`；`NativeHudModal.cpp:122-140,136` | 模态锚点按竖屏重锚 |
| 关闭模态 | `close-modal` | `NativeHudModal.cpp:96,221`；`NativeHudLibrary.cpp:321` | 保留 |
| 排序菜单遮罩 | `close-modal`（整 stage 命中） | `NativeHudModal.cpp:128` | 竖屏按新 stage 高度铺满 |
| 平台选择 | `provider:<id>` | `NativeHudModal.cpp:270`；`NativeHudController.cpp:512` | 卡片宽度按 1080 重算 |
| 音质 | `quality:set:<id>` / `quality` / `quality:open` | `NativeHudModal.cpp:344`；`NativeHudController.cpp:701-709` | 保留 |
| 歌单选择翻页 | `music:picker-prev` / `music:picker-next` | `NativeHudModal.cpp:237,238` | `usable` 按 1080 重算 |
| 歌单表单 | `music:create-playlist` / `rename-playlist` / `delete-playlist` | `NativeHudMusic.cpp:314-357` | 保留 |
| 确认删除 | `confirm:yes` / `取消` | `NativeHudModal.cpp:220,221`；`NativeHudController.cpp:525` | 保留 |
| 唱片旋转风险 | `disc-rotation:enable` / `disc-rotation:cancel` / `disc-rotation-warning` | `NativeHudModal.cpp:208,209`；`NativeHudController.cpp:711-723` | 保留 |
| 本地曲库 | `local:cancel|folder|files|rescan|browse|prev|next|remove` | `NativeHudLocal.cpp:11-46`；`NativeHudController.cpp:533` | 保留（y+200…767 均在 band-1） |
| 更新 | `update:check|cancel|release|auto` | `NativeHudController.cpp:465-477` | 保留 |
| 缓存清理 | `cache:clear` | `NativeHudController.cpp:479` | 保留 |

### 6.6 设置（七区块）

设置行由 `Qt/src/SettingsSchema.cpp:355-686` 的 descriptor 生成（`action` / `actionPrefix`），渲染与滚动在 `Qt/src/NativeHudSettings.cpp`。

| 项 | action / 前缀 | 证据 | 竖屏预期 |
| --- | --- | --- | --- |
| 七区块顺序与卡片高度 | provider-card 160 / … | `SettingsSchema.cpp:693-703`（见 plan :278-288） | **顺序与高度不变**，仅滚动容器可用高度变化 |
| 全屏 | `window:fullscreen` | `SettingsSchema.cpp:355` | 桌面项；Android 不应出现 |
| 关闭行为 | `close-behavior` / `setting:close-behavior:` | `:367-368` | 保留 |
| 主题 | `theme` / `setting:theme:` | `:379` | 保留 |
| 动效 | `motion` / `setting:motion:` | `:391-392` | 保留 |
| 启动动画 | `startup-animation` / `setting:startup-animation:` | `:403-404` | 保留 |
| 重新初始化 | `replay` | `:414` | 保留 |
| 音质 | `quality` / `quality:set:` | `:423` | 保留 |
| 备用源 | `alternative` / `setting:alternative:` | `:435-436` | 保留 |
| 官方客户端 | `music:activate` / `setting:official-player:` | `:448-449` | 保留 |
| 详情自动播放 | `detail-autoplay` / `setting:detail-autoplay:` | `:462-463` | 保留 |
| 单曲播放模式 | `single-play-mode` / `setting:single-play-mode:` | `:475-476` | 保留 |
| 桌面歌词样式 | `desktop-lyrics:open` | `:486` | 桌面专用（mac/win），Android 不出现，不得判定为入口缺失 |
| 归档遮罩 | `archive-mask:` | `:495` | 按竖屏重锚 |
| 图形后端 | `graphics-backend` / `setting:graphics-backend:` | `:510-511` | 保留 |
| GPU 选择 | `gpu-index:` | `:532` | 保留 |
| 垂直同步 | `vsync` / `setting:vsync:` | `:546` | 保留 |
| 渲染缩放 | `render-scale:` | `:560` | 保留 |
| AA 模式/缩放 | `aa-mode:` / `aa-scale:` | `:574,593` | 保留 |
| MSAA | `msaa:` | `:607` | 保留 |
| FSR | `fsr-quality:` / `fsr-sharpness:` | `:622,635` | 保留 |
| FG | `fg` / `setting:fg:` | `:652-653` | 保留 |
| 恢复默认 | `settings:restore-defaults` | `NativeHudController.cpp:447` | 保留 |
| 滚动轨 | `settings:scroll-up` / `settings:scroll-down` | `NativeHudSettings.cpp:223,224`；`NativeHudController.cpp:440-445` | 步长 120 stage px 口径不变 |

### 6.7 BOOT / 桌面歌词 / 其它

| 入口 | action | 证据 | 竖屏预期 |
| --- | --- | --- | --- |
| BOOT 跳过 | `skip` | `NativeHudBoot.cpp:310` | Qt 坐标 y=994 落在横屏底栏带 (984-1080)；**竖屏必须重锚**，避免与固定底栏重叠（requires T43） |
| BOOT 返回 | `back` | `NativeHudController.cpp:682` | 保留 |
| 桌面歌词滚动 | `desktop-lyrics:scroll-up/down` | `NativeHudDesktopLyrics.cpp:117,118,130` | 桌面专用；Android 竖屏不出现 |
| 键盘滚动 | `ArrowDown`/`ArrowUp` | `NativeHudController.cpp:891-899` | 设置/桌面歌词模态内 66 stage px/步 |

## 7. 登录六路径验收（fixture：`test/fixtures/parity_cases/portrait_login.json`）

### 7.1 六条真实路径 + 一个无登录面

| # | 路径 | provider | method | 入口 action | 关键语义 | 证据 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 网易云二维码 | netease | qr | `music:login` | `host->qr(key)`；不走 `/login/qr/create` | `MusicAccount.cpp:560-623` |
| 2 | 网易云短信 | netease | phone | `music:login-method:phone` | `/captcha/sent` → `/login/cellphone`；`^1[0-9]{10}$` / `^[0-9]{4,8}$`；重发 60000 ms | `MusicAccount.cpp:402-462` |
| 3 | QQ 扫码 | qq | qr | `music:login-method:qr` | channel=qq；`/login/qr/create {qrimg:true}`；data URI 校验 | `MusicAccount.cpp:560-623` |
| 4 | 微信扫码 | qq | wechat | `music:login-method:wechat` | channel=wechat；扫描器文案「微信」 | `MusicAccount.cpp:562-564,584-589` |
| 5 | 酷狗标准版 | kugou | qr | `music:kugou-edition:standard` | 单一 `kugou-device.json` | `NativeHudLibrary.cpp:283-291`（按钮）；`Host.cpp:380-382`（device json） |
| 6 | 酷狗概念版 | kugou | qr | `music:kugou-edition:lite` | 同上，edition 由 `RHINE_KUGOU_EDITION` 决定 | `Host.cpp:380-382`（edition）；`NativeHudLibrary.cpp:283-291`（按钮） |
| — | Siren（无登录） | siren | — | — | `isSiren()` 时 `openModal("login")` 直接 return；使用本地收藏/MSR | `NativeHudController.cpp:70-72` |

方法按钮只按 provider 呈现：netease → {qr, phone}；qq → {qr, wechat}；kugou → 版本按钮组（`NativeHudLibrary.cpp:270-300`）。`isLocal()` 时登录/音质/歌单选择/歌单表单四类模态被整体拒绝（`NativeHudController.cpp:64-68`）。

### 7.2 六相位与不变量

`idle → preparing → waiting → (confirming) → complete | failed`（字段默认见 `Qt/src/MusicLibrary.h:162-176`）。

| 断言 | 期望 | 证据 |
| --- | --- | --- |
| 可重生成 | `retrySeconds == 0 && phase != preparing && phase != confirming` | `MusicAccount.cpp:304-306` |
| 取消 | `generation += 1`，清 `qr`/`qrKey`，`phase = idle`，`accountLoading = false`；后到的旧代响应被丢弃 | `MusicAccount.cpp:352-379` |
| QQ 取消屏障 | QQ 且有旧 key 时先 `POST /login/qr/cancel {key}` 并等完成屏障；其它 provider 立即完成 | `MusicAccount.cpp:365-379` |
| 轮询 | 每 1000 ms；`pollCount >= 300` → `failLogin("二维码超时，请重新生成")` | `MusicAccount.cpp:625-631` |
| 状态码 | 800 → QQ `reportLoginFailure` / 其它 `failLogin("二维码已过期，请重新生成")`；801 继续等待；802 → `confirming`「已扫描，请在手机上确认」；803 → `confirming` + `confirmLogin` | `MusicAccount.cpp:640-667` |
| 冷却 | `reportLoginFailure` 置 `phase=failed`；`retryAfterMs>0` 写入冷却，倒计时文案附加「（请等待 N 秒）」/「，可重新生成」 | `MusicAccount.cpp:308-341` |
| 短信门控 | 仅 `provider == netease`；`cancelLogin()` 先行；`++generation`；`SMS_RESEND_INTERVAL_MS = 60000` | `MusicAccount.cpp:402-429` |
| 验证码失败 | 只写 `loginStatus`，**不** `failLogin`、**不** 置 `complete` | `MusicAccount.cpp:445-462` |
| 凭据保存失败 | 短信分支只写状态；非短信分支 `failLogin`；**不得**伪造成已登录 | `MusicAccount.cpp:475-523` |
| 成功（非短信） | 清 `qr`/`qrKey`、`phase = complete`、清除该 provider 冷却 | `MusicAccount.cpp:500-515` |
| 登出 | 仅清当前来源凭据与私有数据；其它 provider 不变 | `MusicAccount.cpp:670-717` |
| 登录切换 | 不得清空收藏、不得登出其它 provider | plan :274 |
| 模态关闭 | 关闭登录模态调用 `cancelLogin()`，不复活旧二维码 | `NativeHudController.cpp:135-140` |
| 表单提交 | `login` + `phone` 模态的字段提交 → `captchaLogin(account, captcha)` | `NativeHudController.cpp:166-169` |

### 7.3 fixture 形状

参考 plan 附录 B.3 的字段形态（`{"provider":"qq","method":"wechat","phase":"waiting","generation":7,"pollCount":12,"pollIntervalMs":1000,"retryAfterMs":0}`），本卡 fixture 用 `schema = "parity-cases/portrait-login/v1"` 承载：三档尺寸、竖屏规则、六条路径、相位机、26 条可静态断言（`L-A01…L-A26`）、入口可达性表、WAIT 清单与未执行验证清单。**该 fixture 是数据，不构成 Qt 竖屏像素基线**；消费它的 Dart 测试不在本卡写入域（T05 拥有通用六路径矩阵 `test/fixtures/login_matrix.json`，两者职责不同：T05 = 领域登录矩阵，本卡 = 竖屏验收用例）。

## 8. 旋转 / 尺寸变化的状态连续性

只允许 `MediaQuery` 重建 + 重算 `StageMetrics`；引擎/状态对象在 widget 树之外（T02 §7.1/§7.3）。必须保留：

| # | 保留项 | 来源 |
| --- | --- | --- |
| 1 | 五条 lane 与当前 lane | plan :369-376 |
| 2 | 目录栈与每层游标 | 同上 |
| 3 | 条目 key + 相对滚动偏移（非绝对） | 同上 |
| 4 | 输入文本/选区/composing/焦点 | 同上 |
| 5 | 正在编辑的设置项与光标 | 同上 |
| 6 | 二维码墙钟有效期、generation、取消完成屏障 | 同上 |
| 7 | 队列、当前曲目、进度、模式、历史 | 同上 |
| 8 | 歌词偏移与来源 | 同上 |
| 9 | 3D 相机/动画时钟/BOOT 起点/详情淡入/查看器开合/复位/清晰度 | 同上 |
| 10 | 拖拽旋转时取消拖拽并恢复交互，不丢选中卡片 | 同上 |
| 11 | 模态名、关闭进度、`modalOffset` | 同上 |
| 12 | 滚动数字曲线不重启（默认 0.46 s） | 同上 |

禁止项：`runApp` 重建、销毁播放器、清空列表、重新登录（plan :369-376）。

### 8.1 旋转 / 尺寸变化全动作验收模板（新增，written-not-executed）

对每条动作按「尺寸 A → 尺寸 B → 尺寸 A」三态记录，`rot` 列与 §5.1 同一行复用。三种转移各至少一次：P1↔P2（同宽高比、不同 density）、P1↔P3（不同宽高比）、横↔竖（aspect 跨 1.05）。

| 列 | 断言 | 判据/证据 |
| --- | --- | --- |
| R1 冷/热一致 | 同尺寸下「旋转后重算」逐值等于「冷启动重算」 | `PortraitBands` 深相等（快照 :314-335） |
| R2 命中重建 | 每帧整份重算，禁止跨帧复用命中矩形 | Qt 每帧清表重建（`Qt/src/NativeHud.cpp:224-256`；T43 快照 :3-5 文件头写明「整份重算、禁止跨帧复用命中矩形」） |
| R3 零副作用 | 旋转不产生任何命令（不 login/cancel/play/pause/queue/seek） | 命令流 diff 为空 |
| R4 模态保持 | `modal` 名、关闭进度、`modalOffset` 保留；`fixed` 命中不被 `modalOffset` 平移 | `Qt/qml/Overlay.qml:191,359,529` |
| R5 输入保持 | 文本/selection/composing/focus 与 IME 状态保留；输入框 y 仍为 `(inputY + modalOffset) × stageScale` | 同上 |
| R6 时序保持 | QR 墙钟剩余、冷却剩余、滚动曲线进度、动画时钟与 boot 起点不重启 | plan :369-376 |
| R7 无重启 | 不 `runApp`、不 dispose 播放器、不清列表、不重新登录 | plan :369-376 |

记录模板（每动作一行；`items` 引用 §8 的 1..12 项号；`R1..R7` 与 `result` 本轮一律填 `unexecuted`，符合同一空值约定）：

```text
action | items(§8 项号) | from(WxH@dpr) | to(WxH@dpr) | R1..R7 | result | evidence
music:login | 1-12 | 411x914@2.625 | 480x1066@3 | unexecuted x7 | unexecuted | code:portrait.md#7.2
```

**本轮状态**：模板行未填充、未运行（`WAIT-TEMPLATE-EXEC`）；「模板已定义」不等于「已验收」，也不构成竖屏像素基线。

## 9. 未审定 / WAIT 清单（不得写成通过）

| ID | 项 | 原因 | Owner |
| --- | --- | --- | --- |
| WAIT-GOLDEN | `test/golden/portrait/full_suite_1080x2400.png` | 未生成；样板未冻结；不得用空 PNG 冒充 | T43/T51 |
| WAIT-GEOM-1200x2000 | 1200×2000 的 density/dpr/logicalWidth/stageScale | 密度未审定；`stageHeight=1800`、`bandCount=2`、`physicalPerStage=1.111111111` 由物理尺寸推出，但 `dpr`/`logicalWidth`/`stageScale` 仍依赖 density | T43 |
| WAIT-CANDIDATE | Portrait-W / Band / Hybrid 裁决 | 需在同一 widget 比较可达性/层级/触摸/字尺度后冻结 | T43 |
| ~~WAIT-IME-LANDSCAPE~~ | ~~横屏键盘是否 resize 窗口~~ | 已冻结：Flutter 清单 `AndroidManifest.xml:28` 为 `adjustResize`；不再等待 | T02/T50 |
| WAIT-SAFE-AREA | 真实安全区数值 | Qt 无安全区代码 | T43/T51 |
| WAIT-ACC | 系统字体缩放的可访问性策略 | 乘进 stage 会破坏绝对字号语义 | T32/T51 |
| WAIT-DEVICE | 竖屏真机基线 | DEVICE_BLOCKED：本阶段不跑设备/截图/性能 | T51/T16 |
| WAIT-VISUAL-EVIDENCE | 登录后/发现/播放中等页视觉取证 | 无真机帧，只能按源码语义验收 | T50 |
| WAIT-48DP | 竖屏最小触摸目标尺寸 | Qt 无 48dp 规范 | T43 |
| WAIT-3D-SHARE | 竖屏 3D 占比 | 需候选比较后冻结，不预设 52% | T43 |
| WAIT-TEMPLATE-EXEC | §5.1 / §8.1 模板未填充、未执行 | 需真机、截图或命令流取证；模板定义本身不构成验收结论 | T51/T16 |

## 10. 未执行验证声明

- 本卡**未执行** `flutter build/test/analyze/run`、`dart test/analyze`、`pub get`、Gradle、adb、APK 安装卸载、清数据。
- **未执行** codegen/formatter/校验脚本、golden/widget/integration 测试、Qt 编译运行、截图、性能与运行协议验证。
- **未生成**任何 golden PNG；**未做**任何真机测量。
- 因此：计划 T51 的 Pass 条件「样板与全页清单通过」在本轮**只完成清单侧**（可静态审查），样板侧因样板与 golden 缺失未完成 → 本卡**不宣称 Pass**。
- 所有 fixture 断言状态为 **written-not-executed**。
- §5.1 与 §8.1 的模板只定义列/码/判据，**没有填充任何一行，也没有执行任何一行**；`PASS_MEASURED` 在本轮不可使用。
- 本文不提供、也不暗示任何 Qt 竖屏像素基线；`test/golden/portrait/full_suite_1080x2400.png` 未生成（WAIT-GOLDEN）。

## 11. 与其他卡的关系

| 卡 | 关系 |
| --- | --- |
| T02 | 提供全部竖屏几何公式与横屏常量（本卡只引用，不重定义） |
| T05 | 拥有通用六路径登录矩阵 fixture（`test/fixtures/login_matrix.json`）；本卡 fixture 是竖屏验收用例，避免与其重复 |
| T43 | 已实现 `worktrees/T43/lib/ui/layout/portrait_bands.dart`：W/Band/Hybrid 三候选与 compress/shiftUp 两策略均为**参数、未裁决**；本卡只引用其公式，不选型。引用快照：T43 工作树 @ `8ed3067b0812eb2612f7841ec127a6e8ca93231b`（该文件为未跟踪草稿，非 Git 对象，HEAD 不固定其内容；2026-11-10T10:29+08:00 实测 744 行 / 28463 bytes，sha256 `49454a547c5732fd6b31b18df092f96f18b5ec4c5260d5524d8e678c747647b9`，mtime 2026-11-10T05:13:04+08:00；旧审 2026-11-10T10:11–10:18 实测同值，草稿再变则此 sha 失效，仅作当次溯源，不作像素验证依据）；正文行号只对该快照有效，符号名为准。三档 golden 与候选裁决仍以 T43 冻结为准 |
| T50 | 横屏验收与视觉未取证清单；竖屏同口径标「视觉未取证」 |
| T33–T40 | 各页面动作实现；本卡 6.2–6.7 的清单是其竖屏回归基线 |
| T52 | 性能基线依赖 T50/T51 |

### 可释放依赖

本卡不需要设备即可推进的部分已全部完成；对 T43 的依赖是**冻结值**依赖（1200×2000 density、候选选择、golden 样板、竖屏重锚点），不是本卡可自行决定的事项。设备相关结论（安全区真实数值、竖屏真机像素）保持 DEVICE_BLOCKED，不阻塞源码侧清单与 fixture；IME 横屏已按 Flutter 清单 `adjustResize` 冻结，不再列为 WAIT。

