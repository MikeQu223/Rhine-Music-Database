# 布局与舞台契约（T02）

状态：**冻结草案，P0 契约**。本文件是 Flutter 迁移中几何、层序、命中与 IME 的唯一布局规范。
冻结依据是当前仓库 Qt 源码（本 worktree，基线 `8ed3067b0812eb2612f7841ec127a6e8ca93231b`）与
`docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md`（§2.4、§4.1、§4.3、§6.4、§6.5、附录 B.1）。
凡本文件与计划冲突，以计划为准并立刻修订本文件；凡本文件与 Qt 源码冲突，以 Qt 源码为准并标注修订。
不执行构建/测试/analyze/flutter run/adb；本文件所有数字均由源码公式手算，未经设备复测。

## 0. 术语与坐标系

| 名称 | 定义 | 单位 |
|---|---|---|
| 物理像素 physical | 帧缓冲真实像素；截图、APK 验收用的坐标 | device px |
| 逻辑像素 logical | Flutter `MediaQuery.size` / QML `width,height` 的坐标；= physical / DPR | logical px |
| 舞台单位 stage | 以 1080 高归一化的绘制坐标；原点左上，y 向下 | stage unit |
| DPR | 物理/逻辑比；Android 参考 density/160；以 `MediaQuery.devicePixelRatio` 为准 | 无量纲 |
| 舞台缩放 stageScale | stage → logical 的比例 | logical px / stage unit |

硬规则：

1. **禁止**把 1800（真机截图高度）当作 QML/Flutter 高度，**禁止**把截图坐标直接当 dp（计划 §2.4）。
2. 舞台坐标永远以左上角为原点；缩放必须 `transformOrigin = TopLeft` / `canvas.scale` 从原点起，
   Qt 侧见 `Qt/qml/Overlay.qml:179-184`（`width: stageWidth; height: 1080; scale: stageScale;
   transformOrigin: Item.TopLeft`）。
3. 绘制、命中、IME 三套矩形全部由**同一个** `StageMetrics` 产生；不允许第二套像素换算。

## 1. 横屏舞台（已冻结）

### 1.1 公式

设逻辑视口 `logicalW × logicalH`，DPR 为 `dpr`：

```
stageScale = logicalH / 1080
stageWidth = logicalW / stageScale          // 等价于 logicalW * 1080 / logicalH
stageHeight = 1080                          // 横屏恒定
logicalPerStage = stageScale
physicalPerStage = stageScale * dpr
physical = stage * stageScale * dpr
stage = logical / stageScale
```

Qt 证据：`Qt/qml/Main.qml:32-33`（Window 上 `stageScale: height / 1080`、`stageWidth: width / stageScale`）；
`Qt/qml/Overlay.qml:22-23` 是同一公式的离屏回退；`Qt/src/Hud.cpp:152` 以
`painter->scale(height() / 1080, height() / 1080)` 绘制，证明 HUD 画布就是 stage 坐标。

### 1.2 冻结数值

| 场景 | physical | density | dpr | logical | stageScale | stageWidth | physicalPerStage |
|---|---|---|---|---|---|---|---|
| 真机横屏 | 2880×1800 | 315 | 1.96875 | 1462.8571428571429×914.2857142857143 | 0.8465608465608465 | 1728 | 1.6666666666666665 |
| 桌面 720p | 1280×720 | 160 | 1.0 | 1280×720 | 0.6666666666666666 | 1920 | 0.6666666666666666 |

断言容差 1e-6（计划附录 B.1）。不得对 stageScale/stageWidth 取整；取整只允许发生在最终栅格化，
命中矩形与 state 输出必须保留 double。1 stage px 在 720p 上小于 1 device px，必须抗锯齿，不得四舍五入
（计划 §2.4）。

### 1.3 舞台内的固定带

横屏舞台高度恒为 1080，以下带位是布局契约，不是某个页面的私有常量：

| 带 | stage 矩形 | 来源 |
|---|---|---|
| 主内容/资料库底边 | `y = 0 .. 984` | `NativeHud.cpp:324` 的 `clip(0,0,width,984)` |
| 播放栏 | `y = 984 .. 1080`（高 96） | `NativeHud.cpp:310` `playerBar(0, 984, width)`；`PlayerBar.h:42` `RowHeight = 96` |
| 播放栏输入底带 | `y = 978 .. 1080`（`row = (0,984,stageWidth,96)`，`adjusted(0,-6,0,0)` → y 978、h 96+6=102、bottom 仍 1080） | `PlayerBar.cpp:241-242` `row.adjusted(0,-6,0,0)` |
| 播放进度命中 | `y = 978 .. 996`，整行宽 | `PlayerBar.cpp:148-151` `row.y()-6, h=18` |

播放栏在所有 mode（含 boot 之外）都绘制（`NativeHud.cpp:309-311`），弹层打开时也不移动；
竖屏候选必须把“贴底”定义为“贴 stage 底”，不得贴物理屏底绕过安全区规则（见 §6）。

## 2. 层序与合成（已冻结）

自下而上（后绘制者在上）：

| 序 | 层 | 坐标 | 说明 |
|---|---|---|---|
| 1 | 3D 场景 | stage/3D 相机 | 独立层，HUD 不烤进 3D 插值纹理（计划 §4.1） |
| 2 | HUD 画布 | stage | 17 op 命令流，见 T03；含 brand/navigation/footer/archive/detail/playerBar |
| 3 | modal 遮罩 | stage | 属于 HUD 命令流，绘制在 HUD 内容之上、弹层内容之下 |
| 4 | hits 透明层 | stage | 只接受命中，不绘制；不含 modalOffset 写回 |
| 5 | 真实输入组件 | logical | 检索框、账号/验证码、设置编辑；绘制光标/选区/组合文本 |
| 6 | chrome | logical | 窗口按钮/拖动/缩放；Qt `z: 999` |
| 7 | 性能面板 | logical | Qt `z: 1000` |

Qt 证据：`Overlay.qml:81-84`（Hud 填满）、`Overlay.qml:86-121`（透明 pointer 层）、
`Overlay.qml:179-220`（hits 容器 scale/TopLeft + Repeater）、`Overlay.qml:355-484`（表单真实输入）、
`Overlay.qml:519-602`（检索/设置输入）、`Overlay.qml:604-617`（chrome z999）、
`Overlay.qml:618-620`（PerformancePanel z1000）。计划 §4.1 的六层（3D→HUD→遮罩→hits→chrome→性能）与本表一致，
遮罩本来就在第 3 层；本表只是把计划单独描述的真实输入显式插为第 5 层。遮罩属于 HUD 命令流，
Flutter 实现可在同一 Canvas 内先画内容再画遮罩。

合成规则：

- 遮罩**不平移**：Qt 先 `fill(0,0,width,1080, mask)` 再 `translate(0, modalOffset)` 画面板
  （`NativeHudModal.cpp:163-166`）。
- Hits 层必须单独构造（外层 `IgnorePointer`），透明背景，禁止用 hit 矩形绘制任何可见像素。
- 真实输入组件在 hits 层之上：它拦截自己的矩形，避免 hit 层抢焦点；但它不得覆盖或裁切 HUD。

### 2.1 3D 相机已有 aspect 分支（Qt 源码，非新设计）

`NativeScene::updateCamera` 直接按渲染面 `aspect = m_width / m_height` 分支（`Qt/src/NativeSceneCamera.cpp:55-71`）。
这是 Qt 已有代码，Flutter 3D 层必须 1:1 移植，不得按 `OrientationBuilder`/设备类型另选：

| 项 | Qt 公式 | 行 |
|---|---|---|
| portrait 判定 | `aspect < 1.05` | :56 |
| compact 判定 | `!portrait && m_width < 1100` | :57 |
| portrait 取景跨度 | `portraitDetail = max(6.3/aspect, 3.7*h/max(100, 0.54*h-156))`；`viewSpan = max(baseSpan, lerp(8.4/aspect, portraitDetail, detail))` | :59-65 |
| portrait 锚点 | `anchorX = 0.5`；`anchorY = 0.27 + 34/h` | :66-67 |
| 非 cinema portrait 基线 | `Vector{0, -4.6 + cinematicField(12,2,26.56) + 0.4 + 1.85, -2.17} + up*((0.36-0.5)*h/pixelScale)` | :74-78 |
| 主投影 | `perspective(m_fov, aspect, 5, 300)` | :98 |
| 可见性投影 | `perspective(m_fov, m_width/m_height, 5, min(300, max(6, fogFar+8)))`，x/y 再除 1.18 | :113-120 |

接线硬约束（Qt 证据）：`Engine::resize` 先把窗口尺寸归一化成 `scene.resize(width / (height / 1080), 1080)`
（`Qt/src/Engine.cpp:841-847`）。即 **Qt 相机面高度恒为 1080、宽度是 stageWidth**，`aspect` 实际等于 `stageWidth / 1080`：

- 横屏：相机面 `(stageWidth, 1080)`，与 §1.1 同源；`aspect < 1.05` 只在 `stageWidth < 1134` 的窄窗口出现。
- 竖屏：候选 `stageHeight ≠ 1080`，Qt 没有等价调用（两个 Activity 都 `sensorLandscape`）。竖屏相机面高度取 `1080`
  还是 `stageHeight`、`34/h` 与 `(0.36-0.5)*h/pixelScale` 用哪套单位，**均为 T43/T16 的 WAIT**；
  本契约只冻结“必须复用同一 aspect 分支与阈值”，不冒充已冻结竖屏取景。禁止把逻辑宽高与 stage 宽高混喂相机。

## 3. hits 布局契约（T03 拥有完整协议，这里只冻结布局部分）

### 3.1 字段与顺序

- 必需六字段：`x, y, width, height, action, label`（`NativeHud.cpp:102-109`）。label 回退只看 **null**：`label.isNull() ? action : label`（`NativeHud.cpp:108`）；空串 `""` 是非 null，**不得**回退成 action，也不得 trim 后判空改变语义。
- 仅 PlayerBar 的 hit 允许 `fixed: true`（`PlayerBar.cpp:46-53` 对每个 bar hit 都追加）。
- 顺序 = 源生成顺序（append 顺序）；禁止按 z/面积/action 排序；禁止去重。
- 命中矩形是 stage 坐标，不随绘制缩放取整。

### 3.2 modalOffset 只作用于非 fixed

消费侧（`Overlay.qml:191`）：

```
hitY = hit.y + ((modal != "" && hit.fixed != true) ? modalOffset : 0)
```

- `fixed` 仅播放栏；播放栏在弹层打开时保持原位（`Overlay.qml:191`，注释见 §6.5）。
- 该偏移只在**消费**时加，不允许写回 commands/hits/state；下帧重算。
- 弹层自己的命中表在 `NativeHudModal.cpp:93/125/147/173` 处 `hits = {}` 清空，
  因此弹层打开时**只**发布该弹层 hits + 之后追加的播放栏 fixed hits。布局实现必须保持这个“替换”
  语义，不能把底页 hits 留在表里再靠 z 覆盖。

### 3.3 触摸外扩

- Android：每个 hit 四边各外扩 16 stage px（`Overlay.qml:38-43`，`touchHitPadding = android ? 16 : 0`）。
- 桌面/iOS：0，矩形逐值不变。
- 外扩**只**在触摸命中层生效；不得写回源矩形，不得影响绘制、IME、无障碍语义矩形之外的可视几何。
- 播放进度/音量另有纵向 16 的额外余量（`Overlay.qml:485-508`，y 减 16、height 加 32，x/width 不变，
  避免 seek 比例偏移）；它们是独立手势层，不改变 `PlayerBar` 命中的 x 语义。

### 3.4 播放栏布局

| 元素 | stage 矩形 | 证据 |
|---|---|---|
| 整栏 | `(0, 984, stageWidth, 96)` | `NativeHud.cpp:310` |
| 输入屏蔽 | `(0, 978, stageWidth, 102)`，bottom 1080；= `row(0,984,stageWidth,96).adjusted(0,-6,0,0)` | `NativeHudPlayer.cpp:39`（`playerBounds = drawing.inputBounds`）+ `PlayerBar.cpp:241-242` |
| seek | `(0, 978, stageWidth, 18)` | `PlayerBar.cpp:148-151` |
| volume | `(stageWidth-300+58, 1031, 100, 28)` | `PlayerBar.cpp:208-218`（`outputX = right-300`，`y+47`） |

输入底带**不是** 96 高：`adjusted(0,-6,0,0)` 只把上边从 984 提到 978、高度 96→102，底边仍是 1080。
任何 `978 + 96 = 1074` 的写法都是回归；fixture/test 必须断言 `978 + 102 = 1080`。

`playerBounds` 区域吞掉滚轮（`NativeHudInput.cpp:14-16`），并有独立 `playerBarInputShield`
（`Overlay.qml:123-142`）。Flutter 必须保留“栏内滚动不进入列表”的行为。

注：seek/volume 是条件输出——seek 仅 `state.seekable && state.durationMs > 0`（`PlayerBar.cpp:148`），
volume 仅 `state.applicationVolume`（`PlayerBar.cpp:212`）；iOS 手势层只有 seek，没有 volume（`Overlay.qml:486`）。

### 3.5 舞台原点与窗口映射（竖屏 originY）

A36 把竖屏缩放舞台整体下移到安全区之下：绘制侧是 `Padding(top: containerTop * stageScale)`，
`containerTop = safe.top / stageScale`（§6）。因此「窗口 → 舞台」不是单纯除以 scale，而是
**先除 scale、再减原点**的一次仿射映射；横屏 `originY = 0`，退化为 `Overlay.qml:96-103` 的
`mouse.x / stageScale`。

```
// lib/hud/input/hit_layer.dart 是唯一实现，调用方不得复制这套算术
originY         = bands.containerTop                      // stage unit；横屏 0
toStage(p)      = (p.dx / scale,  p.dy / scale - originY)
toLogical(s)    = (s.dx * scale, (s.dy + originY) * scale)
rectToLogical(r)= Rect.fromLTWH(r.left * scale, (r.top + originY) * scale,
                                r.width * scale, r.height * scale)
```

- `StageGeometry.originY` 是竖屏舞台原点在窗口中的**唯一平移来源**：绘制（`Padding`）、
  命中（`HitLayer`/`PointerRouter`/`WheelRouter`）、无障碍语义矩形（`SemanticsLayer` 的
  `rectToLogical`）共用同一份 `StageGeometry`；**禁止**任何一层再各自加一次 `safe.top`。
- 命中表本身仍是**舞台坐标**（§3.1/§3.2）：`originY` 只出现在坐标换算这一层，
  不得写回 hits、`playerBounds` 或 `state`；`modalOffset`/触摸外扩仍在舞台坐标里相加。
- 竖屏 1080×2400、safe.top=72、scale=1：舞台顶 = 窗口 y=72；窗口 y=122 ↔ 舞台 y=50；
  窗口 y=71 落在安全区里、不属于舞台，命中必须落空。
- 以上数值是由公式推导的**拟议算术**，不是真机 golden；真机必须代入同一条公式与实测 inset。

## 4. 弹层几何与遮罩（已冻结）

### 4.1 modalBounds

```
detail-sort:    { containerLayout(width).x + 195, 391, 240, 184 }
lyrics-source:  { width*0.56 + 156, 674, 232, 232 }
lyrics-offset:  { width*0.56, 690, 320, 216 }
search:         modalWidth = min(width-100, max(760, min(1000, width*0.5 - 59)))
                left = width - modalWidth - 59
其它:           modalWidth = min(1260, width-100); left = (width - modalWidth) / 2
                rect = { left, 122, modalWidth, 836 }
```

逐行来自 `NativeHud.cpp:140-159`。竖屏候选的舞台宽为 1080 时，同一函数给出
默认弹层 `{50,122,980,836}`、检索弹层 `{261,122,760,836}`；不得为竖屏另造一套弹层宽公式，
只允许改变纵向锚点（见 §6）。

### 4.2 遮罩

| 弹层 | 暗色遮罩 | 亮色遮罩 | 说明 |
|---|---|---|---|
| search | `rgba(17,24,27,0.15)` | `rgba(227,224,215,0.12)` | 仅 `modal == "search"`；检索页轻遮罩 |
| saved / 其余面板 | `rgba(17,24,27,0.60)` | `rgba(227,224,215,0.45)` | 全舞台 `(0,0,width,1080)`；saved 经 `libraryPanel` 仍走这一档 |

数值来自 `NativeHudModal.cpp:163-165`（`17/255, 24/255, 27/255`；`227/255, 224/255, 215/255`）；`search` 判定在 :162，saved 走 :252-253 的 `libraryPanel` → `NativeHudLibrary.cpp:45-51`，遮罩仍是 0.60/0.45。
三个小菜单 `detail-sort / lyrics-source / lyrics-offset` **不画遮罩**且清空 hits
（`NativeHudModal.cpp:85-160`）；`detail-sort` 额外有一个整舞台 `close-modal` 命中
（`NativeHudModal.cpp:128`），点的不是菜单就关闭。

独立于弹层遮罩，资料库还有 `archiveMask`：裁到 `(0,0,width,984)`，用 `right-mask` 从
`fadeEnd = width-789` 向左 300 渐隐（`NativeHud.cpp:313-327`，`navigationLeft = width - 789`
见 `NativeHud.cpp:342-344`）。两个遮罩语义不同，不得合并。

### 4.3 弹层输入/列表几何（相对 bounds）

| 名称 | 公式 | default modal @1728（bounds 234/1260） | search modal @1728（bounds 864/805） | 证据 |
|---|---|---|---|---|
| inputX | `bounds.x + 53` | 287 | 917 | `NativeHud.cpp:184` |
| inputY | `bounds.y + 180` | 302 | 302 | 同上 |
| inputWidth | `bounds.width - 106 - libraryToolbarActionWidth()` | 1154 | 699 | `NativeHud.cpp:186`；toolbar 仅 saved 非 0，`NativeHudLibrary.cpp:60-72` |
| searchList | `(bounds.x+53, bounds.y+328, bounds.width-106, 430)` | (287,450,1154,430) | (917,450,699,430) | `NativeHud.cpp:188-191`；`NativeHud.h:96-98` |
| 设置滚动视口 | `bounds.top + 176 .. bounds.top + 836` | 298..958 | 298..958 | `NativeHud.h:115-116` |

表中 toolbar 宽度按 0 计（非 saved）；saved 时 `libraryToolbarActionWidth()` 追加，inputWidth/searchList 同步收窄。
default = `min(1260, width-100)` 居中（`NativeHud.cpp:153/157`）；search = `min(width-100, max(760, min(1000, width*0.5-59)))` 右贴 59（`NativeHud.cpp:155/157`）。

检索/个人库结果行高 72（`NativeHud.h:98`），视口 328..758 共 430；滚动量用相对偏移，
不用绝对像素缓存（计划 §6.5）。

## 5. 真实输入框与 IME（已冻结的布局部分）

### 5.1 检索输入

```
rect = ( inputX, inputY + modalOffset, inputWidth, 54 )     // stage
logical = rect * stageScale
font = 22 * stageScale; leftPadding = 18 * stageScale; rightPadding = 14 * stageScale
```

证据：`Overlay.qml:519-536`；背景仅在非 search/saved 时以 `modalOpacity*0.045` 轻遮罩
（`Overlay.qml:509-518`）。检索文字由真实 `TextInput` 渲染（QML 原生字体，
`rhineFontFamily` 来自 `RhineMiSans-regular.otf`，`main.cpp:1072-1075`），HUD 不画 query 文本；
HUD 只画面板与占位符背景。计划 §4.1 的“视觉文字仍由字形渲染器绘制”指 HUD 的静态标签，
不适用于真实输入框自身的文本；Flutter 侧必须用真实 `TextField` 显示文本/光标/选区/组合串，
不得用普通 `Text` 冒充可编辑输入。

### 5.2 账号/验证码/表单（login 与 playlist-form）

表单根 Item：`x = inputX*scale, y = modalOffset*scale, width = inputWidth*scale`
（`Overlay.qml:355-362`）。相对根：

| 元素 | stage 矩形（相对 formFields） | 证据 |
|---|---|---|
| 账号底框 | `(0, 430, inputWidth - (login?180:0), 55)` | `Overlay.qml:377-383` |
| 账号输入 | `(14, 430, inputWidth - (login?208:28), 55)` | `Overlay.qml:384-407` |
| 发送验证码 | `(inputWidth-170, 430, 170, 55)`，仅 login | `Overlay.qml:408-434` |
| 验证码底框 | `(0, 541, inputWidth, 55)`，仅 login | `Overlay.qml:435-447` |
| 验证码输入 | `(14, 541, inputWidth - 28, 55)`，仅 login；QML 源为 `parent.width - 28 * stageScale` | `Overlay.qml:443-461`（width :449） |
| 提交按钮 | `(inputWidth-170, login?611:530, 170, 36)` | `Overlay.qml:462-483` |

单位陷阱：`Overlay.qml:449` 的 28 乘了 `stageScale`，而 `parent.width = inputWidth * stageScale`，
所以 stage 宽 = `inputWidth - 28`、逻辑宽 = `(inputWidth - 28) * stageScale`。实现若写成
`inputWidth * stageScale - 28`，就把 28 当成逻辑像素（少乘 scale）；在 2880×1800 上会多出约 28×(1-0.8465608)≈4.3 逻辑 px。
账号行同理（`Overlay.qml:389` 的 208/28 都是 stage 常量，先减后乘）。

字号 19*scale（账号/验证码），14*scale（按钮），可编辑性受 `loginBusy` 约束；
手机号 `maximumLength=11`、验证码 8（`Overlay.qml:395,455`）。这些是 T05/T24 的账号语义，
布局只需保证矩形与遮罩偏移同源。

### 5.3 设置编辑

`x = editingSettingX*scale; y = (editingSettingY + modalOffset)*scale;
w/h = editingSettingW/H*scale`（`Overlay.qml:564-574`）；内文 `x+12*scale`、宽 `w-24*scale`、
字号 16*scale（`Overlay.qml:575-602`）。state 字段见 `NativeHud.cpp:208-213`。

### 5.4 IME 规则

1. 横屏：stageScale 只由当前逻辑视口高度决定（`Qt/qml/Main.qml:32`）。Qt 基线没有
   `windowSoftInputMode` 声明（`Qt/android/AndroidManifest.xml` 全文无该属性），也没有任何
   `viewInsets`/`safeArea` 处理（grep 0 命中）。Flutter 清单
   `android/app/src/main/AndroidManifest.xml:28` 保持 `adjustResize`（既定事实，本卡不改清单）：
   键盘弹出时平台缩小逻辑窗口，stageScale 按 §1.1 随新高度重算；代码禁止再用
   `MediaQuery.viewInsets` 手工缩放舞台，输入框矩形随同一 metrics 重算。
2. 竖屏（新增设计）：清单保持 `adjustResize`，键盘弹出时平台已经缩小逻辑窗口；
   band/stage 计算**不得再扣 `viewInsets`**，`stageScale`/`stageWidth`/`stageHeight` 与底栏
   均不因键盘改变，`imeStage = 0`。输入框仍以 stage 坐标描述，hit 与 IME 矩形同源。
   若未来改 `adjustNothing`，才允许用 `viewInsets` 压新增纵向容器；任何情况下 IME 不缩放 stage。
3. 任何情况下，真实输入组件的逻辑矩形 = stage 矩形 × stageScale；不得加第二个偏移/内边距，
   避免命中与 IME 三套坐标。

## 6. 竖屏候选（拟议，不裁决赢家）

前提：Qt 两个 Activity 都是 `sensorLandscape`（`AndroidManifest.xml:89,103`），没有 Qt 竖屏 HUD 基线；
竖屏是新增设计（计划 §6.4），不得伪造 Qt 竖屏截图证据。所有候选共用：

```
layoutW, layoutH                     // logical px：LayoutBuilder 可用窗口宽高，未预扣任何 inset
safe = MediaQuery.padding              // logical px；只在 stageHeight（扣一次）与 containerTop（舞台原点）出现，content 不再扣
portraitStageScale  = layoutW / 1080   // logical px per stage unit
portraitStageWidth  = 1080             // stage unit
containerTop        = safe.top / portraitStageScale   // stage unit；舞台在窗口中的原点 = StageGeometry.originY（唯一平移来源）
portraitStageHeight = (layoutH - safe.top - safe.bottom) / portraitStageScale   // stage unit，不是 logical px
```

单位与基线：`stageHeight/stageWidth/bandHeight/topBar/bottomBar/contentHeight` 全是 **stage 单位**，
logical px 只出现在 `layoutW/layoutH/safe`。本轮 fixture 没有设备 inset 数据：`insets` 全 0，
1080×2400 组得到的 `stageHeight = 914.2857142857143 / 0.38095238095238093 = 2400`、`contentHeight = 2208`
是 **inset=0 的拟议算术值**，不是设备实测、不是验收基线，更不得反推“竖屏舞台高 2400”。
真机必须把系统栏/安全区代入同一条公式（`stageHeight = (layoutH - safe.top - safe.bottom) / scale`），
安全区只在这里扣一次；测试只能断言“由同一公式与同一 inset 输入推导”，不能把 2400/2208 当 golden。

### 6.1 WAIT（未审定，禁止当成已冻结）

| 项 | 状态 | 说明 |
|---|---|---|
| W/Band/Hybrid 赢家 | **WAIT** | T43 比较可达性/层级/触摸/字尺度后裁决；本卡不投票 |
| 竖屏真机 inset 数值 | **WAIT** | Qt 无 safe-area 代码；fixture inset 全 0 只是算术假设 |
| 竖屏 3D 相机面高度（1080 vs stageHeight） | **WAIT** | Qt 只有 `scene.resize(w/(h/1080),1080)`，竖屏无等价调用 |
| IME 弹出时窗口是否 resize | **规则已冻结（adjustResize）** | Flutter 清单 :28 声明 `adjustResize`；Qt 基线无该声明（见 §5.4） |
| Band 滚动/吸附与底部安全区策略 | **WAIT** | T43 冻结；不得由 fixture 数字冒充 |

WAIT 条目只能由 T43/T51 关闭；IME resize 已按 Flutter 清单 `adjustResize` 冻结（§5.4），不属待裁决项。本契约不得以任何 fixture 数字声称已裁决。

三候选的差异只在纵向编排，不在横向量纲：

| 候选 | 结构 | 冻结公式 | 备注 |
|---|---|---|---|
| Portrait-W | 顶部 1080 带复用横屏命令，详情/列表纵向延伸，播放栏贴 stage 底 | `scale=layoutW/1080; stageW=1080; stageH=(layoutH-safe.top-safe.bottom)/scale; containerTop=safe.top/scale; bar=(0, stageH-96, 1080, 96); content=(safe.left/scale, 0, 1080-(safe.left+safe.right)/scale, stageH-96)` | 最接近横屏 1:1；W 即“宽即 1080”；content 不扣 safe.top/safe.bottom |
| Portrait-Band | 固定 1080 宽分带滚动，每带 1080 高 | `stageH=(layoutH-safe.top-safe.bottom)/scale; bandHeight=1080; bandCount=ceil(stageH/1080); bandY=k*1080; content=(safe.left/scale, 0, 1080-(safe.left+safe.right)/scale, stageH)` | 带内命令与横屏同宽，纵向拼接；底栏覆盖最后一带 |
| Portrait-Hybrid | 顶栏+内容+底栏三段，详情单列 | `stageH=(layoutH-safe.top-safe.bottom)/scale; topBar=(0,0,1080,96); bottomBar=(0,stageH-96,1080,96); content=(safe.left/scale, 96, 1080-(safe.left+safe.right)/scale, stageH-192)` | 三段独立滚动/固定；content 只扣上下 bar |

约束（全部候选项都适用）：

- 唯一安全区公式：`stageHeight = (layoutH - safe.top - safe.bottom) / scale`，
  上下安全区在舞台高度里**只扣一次**；`containerTop = safe.top / scale`（stage 单位）是舞台在窗口中的原点，
  widget 层据此把缩放后的舞台下移 `containerTop * scale = safe.top`。
  左右安全区只缩内容宽，不缩 stage；不得把安全区加进横屏公式。`safe.top/safe.bottom` 只允许出现在两处：
  `stageHeight` 公式与 `containerTop`（窗口原点）；content 是 stage 本地坐标（W `y=0, h=stageH-96`、
  Band `y=0, h=stageH`、Hybrid `y=96, h=stageH-192`），**不得**再出现 `safe.top/scale`、`safe.bottom/scale`，第三处不得再扣。
- 窗口映射：stage 原点 y = `containerTop * scale = safe.top`；缩放后舞台高 = `layoutH - safe.top - safe.bottom`；
  `playerBar` 底边 = `stageHeight`，对应窗口底边 = `layoutH - safe.bottom`，底栏落在手势区之上，不覆盖底部手势区。
- 原点也进入命中/语义换算：`StageGeometry.originY = containerTop`（stage 单位）是竖屏
  「窗口 → 舞台」的唯一平移来源，`toStage` 先除 `stageScale` 再减 `originY`，`toLogical`/`rectToLogical`
  反向加回（§3.5）。绘制 `Padding(top: containerTop * scale)`、命中、语义矩形共用同一份 geometry，
  调用方不得各自再补一次 `safe.top`；横屏 `originY = 0`，公式与 Qt 一致。
- 清单保持 `adjustResize`：平台已按键盘缩小窗口，band/stage 计算**不得再读 `viewInsets`**；
  `imeStage = imeConsumedStage = inputShiftStage = 0`。只有未来改 `adjustNothing` 时才允许用
  `viewInsets` 压容器；任何情况下 IME 不缩放 stage。
- 全部入口/文字/动作/状态必须保留；列数、弹层形态、触摸尺寸、字体下限、3D 占比都要在 T43
  用同一控件的可达性/层级/触摸/字尺度比较后冻结，本契约不预设 bottom sheet、48dp、52%。
- 任何候选都必须复用 §4.1 的 `modalBounds(1080)` 横向公式，只改纵向锚点；
  不得为竖屏重写弹层宽度。
- 竖屏尺寸 1080×2400、1440×3200、1200×2000 是**拟议测试矩阵**，不是已证实真机基线（计划 §6.4/T43）。

## 7. 旋转与尺寸重算

### 7.1 触发与顺序

输入：`MediaQuery.size`、`devicePixelRatio`、`padding`、`LayoutBuilder` 约束。`viewInsets` 不在当前输入列表：清单为 `adjustResize`，平台已缩窗口；只有未来改 `adjustNothing` 时才把它加入输入并压容器（§5.4/§6）。
顺序固定为：

```
metrics 变化 → 重算 StageMetrics（§1.1 或 §6 候选之一）
            → 用新 metrics 生成 commands/hits/frame（同代次）
            → 绘制一帧
            → 之后所有命中测试/IME 定位都用同一 metrics
```

Qt 对照：`Main.qml:37-38` 在 `onWidthChanged/onHeightChanged` 调 `rhine.resize(width,height)`；
`stageScale/stageWidth` 是绑定，窗口一变即重算；`NativeHud::draw` 每帧接收 `stageWidth`
并清空 `commands/hits` 重发（`NativeHud.cpp:252-256`），因此不存在跨尺寸的缓存命中矩形。
Flutter 必须显式保证同一语义：**尺寸变化后不得复用上一帧 hits**。

### 7.2 连续性（布局相关子集）

旋转/窗口变化只允许重建 MediaQuery 与重算 stage；引擎、播放器、列表、登录状态活在 Widget 树之外
（计划 §6.5）。布局必须保住：

- 目录栈每层游标 + item key + 相对滚动偏移（不是绝对 offset）。
- 输入文本、selection、composing、focus；编辑中的设置项与光标。
- 弹层名、关闭进度、`modalOffset`；滚动数字曲线不重启。
- 3D 相机/时钟/viewer 状态；拖拽中的旋转要取消并恢复可交互（`viewerPinch` 语义见
  `Overlay.qml:293-341`）。

### 7.3 不得发生

- 不得因旋转重建 `runApp`、dispose 播放器、清空列表、重复登录/启动 Node（计划 §6.5）。
- 不得用 `OrientationBuilder` 按设备类型切换公式（计划 §4.1）；只按可用尺寸选横/竖分支。
- 不得把 `textScaler` 乘进 stage：Qt HUD 字号是 stage 绝对单位，系统字体缩放会破坏 1:1；
  真实输入组件如需可读性，只能在 T32/T51 另立可访问性策略，不能改本契约的 stage 数值。

## 8. 未冻结 / 未取证（不得宣称通过）

| 项 | 状态 | 原因 |
|---|---|---|
| 竖屏最终形态（W/Band/Hybrid 选型） | **未裁决** | 计划 §6.4/T43：需同一控件可达性/层级/触摸/字尺度比较；本卡只冻结候选公式 |
| 竖屏真机基线 | **DEVICE_BLOCKED** | Qt 只有 sensorLandscape；1080×2400/1440×3200 是拟议矩阵 |
| 竖屏 `stageHeight=2400`（fixture） | **拟议算术，非基线** | inset=0 代入 §6 的结果；未扣系统栏/安全区，不得当设备值 |
| Qt 相机 `aspect<1.05` 竖屏取景 | 源码已存在，Flutter 未测 | `NativeSceneCamera.cpp:55-71`；竖屏相机面高度/单位仍 WAIT（§2.1） |
| 键盘弹出时 Android 窗口是否 resize | **已冻结：adjustResize** | Flutter 清单 `AndroidManifest.xml:28`；Qt 基线无该声明与 inset 处理，不得用 viewInsets 手工缩放 |
| 安全区实际数值 | **未取证** | Qt 源码无 safe-area 代码；竖屏新容器规则是设计约束，非真机测量 |
| 1080 高度外的横屏舞台 | **不适用** | 横屏高度恒 1080；窗口比例变化只改 stageWidth |
| 像素级 1:1（截图 ROI） | **未验证** | 本轮不执行截图/设备/性能验证 |

## 9. Fixture 与测试映射

`test/fixtures/stage_metrics.json`（schema `stage-metrics/v1`）至少四组：
2880×1800、1280×720、1080×2400、1440×3200。字段与断言：

- `groups[].physical/density/dpr/logical`：验证 `dpr = density/160`、`logical = physical/dpr`。
- 横屏组：`expected.stageScale`、`expected.stageWidth`、`expected.physicalPerStage` 与 §1.1 公式一致。
- 竖屏组：每组 `portrait` 对象的 `stageScale/stageWidth/stageHeight`（及 Band 的 `bandHeight/bandCount`、
  Hybrid 的 `topBar/bottomBar/contentHeight`）与 §6 公式一致；每组必须带 `baselineStatus=PROPOSED_ARITHMETIC_NOT_DEVICE`
  与 `insets` 全 0，`stageHeight` 只能按 `(logicalH - insets.top - insets.bottom) / scale` 推导，不得把 2400 当 golden。
  顶层 `portraitCandidates` 只记录三候选公式字符串；测试断言其条目/公式存在，数值断言落在每组 `portrait`。
- 相机常量：`layout.camera` 冻结 `portraitAspectThreshold=1.05`、`compactWidthThreshold=1100`、
  `perspectiveNear=5`、`perspectiveFar=300`（`NativeSceneCamera.cpp:55-57,98`）。
- `layout` 常量：播放栏 984/96、输入底带 978/102（断言 978+102=1080，不是 1074）、seek 978/18、volume 100×28@+58/+47（1031+28=1059）、验证码宽内缩 28（先减 stage 常量再乘 scale）、
  弹层 122/836、检索列表 328/430、输入 180/54、账号 430/55、验证码 541/55、提交 611/530、
  设置视口 176..836、触摸外扩 16、结果行高 72；断言内部和（984+96=1080、978+102=1080、328+430=758、
  430+55=485、541+55=596、122+836=958<984）。

`test/stage_metrics_test.dart` 是上述公式的可执行参考实现（P0 不写产品代码，测试自带纯函数），
断言容差 1e-6；T20/T30 落地 `StageMetrics` 后必须把测试改为引用共享实现而保留同一组断言。

## 10. 证据索引

| 事实 | 文件:行 |
|---|---|
| Window 1280×720、stageScale/stageWidth、resize 回调 | `Qt/qml/Main.qml:13-14,32-33,37-38` |
| 离屏回退公式、触摸 16px、hits 容器 scale/TopLeft、modalOffset、fixed 排除 | `Qt/qml/Overlay.qml:22-23,38-43,179-191` |
| 检索输入、设置编辑、表单、seek/volume、chrome/perf z | `Qt/qml/Overlay.qml:485-602,604-620` |
| Layout 默认值、结果列表/设置/专辑常量、commands/hits/frame | `Qt/src/NativeHud.h:37-47,74-76,96-98,108-110,115-116` |
| hit 六字段、modalBounds、containerLayout、detailBounds、state、draw 重置、archiveMask | `Qt/src/NativeHud.cpp:102-109,140-174,175-221,224-327` |
| 弹层清空 hits、遮罩颜色/alpha、小菜单 | `Qt/src/NativeHudModal.cpp:81-173` |
| 滚轮/播放栏吞事件/设置与检索视口 | `Qt/src/NativeHudInput.cpp:9-35,81-119` |
| PlayerBar 行高/头尾、fixed hit、seek、volume、render bounds | `Qt/src/PlayerBar.h:42-44`；`Qt/src/PlayerBar.cpp:46-53,141-151,208-252` |
| playerBounds 来源 | `Qt/src/NativeHudPlayer.cpp:32-41` |
| HUD 画布 scale(height/1080) | `Qt/src/Hud.cpp:152` |
| 输入字体 family | `Qt/src/main.cpp:1072-1075` |
| 播放栏输入底带 row→adjusted、label null 回退 | `Qt/src/PlayerBar.cpp:241-242`；`Qt/src/NativeHud.cpp:102-109`（:108 isNull） |
| 相机 aspect 分支/阈值/投影、Engine 归一化 | `Qt/src/NativeSceneCamera.cpp:55-71,98,113-120`；`Qt/src/Engine.cpp:841-847` |
| 验证码/账号宽度 28/208 乘 stageScale | `Qt/qml/Overlay.qml:380,389,449` |
| sensorLandscape；Qt 基线无 windowSoftInputMode（Flutter 清单 adjustResize 见 :28） | `Qt/android/AndroidManifest.xml:89,103` |
