# Qt → Flutter 1:1 迁移实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 在不删减 Qt Android 现有功能、不伪造竖屏基线的条件下，把 Qt 参考实现完整迁移为 Flutter 产品壳：横屏业务功能、画面、动作、时序达到 1:1；竖屏作为新增重排保留全部语义、动作与风格。

**Architecture:** Qt Android 是参考实现与契约来源，Flutter 是新宿主。先用同一 archive→detail→search→queue 切片实测 PlatformView、Qt 离屏 Texture、Dart 自绘 HUD、混合、WebView 五种候选，再由统一裁决选型；领域状态（MusicLibrary、MusicPlayer、PlaybackQueue、LyricsController、NativeScene、NativeHud、Host）各自迁移，Node 只保留上游协议适配。横屏冻结 1080 高舞台换算，竖屏另立可用窗口布局，不复用横屏公式。

**Tech Stack:** Flutter stable（当前 pubspec SDK ^3.13.7，实施时记录实际版本）、Android embedding v2、Kotlin、MethodChannel/FFI、Qt 6/QML 参考源码、Node worker 协议、Dart unit/widget/golden/integration_test、逐 ROI 像素与命中对照工具。

**本轮状态：** 只写计划。未实现产品、未构建、未测试、未 analyze、未 adb、未安装、未改 Qt 源码、未执行任何 Future 命令。计划中的命令、文件、阈值均为未来步骤。

---

## 0. 阅读方法与证据纪律

### 0.1 证据等级

| 等级 | 含义 | 可用性 |
|---|---|---|
| E0 | 真机安装、启动、截图、无障碍树实证 | 可作页面/状态基线，但只限已覆盖范围 |
| E1 | 本计划实际直读的源码行 | 可作契约；实施前仍须由对应任务落 fixture |
| E2 | APK、证书、哈希、版本号等可复核产物 | 可作发布门证据 |
| E3 | 推断、设计候选、用户口径但未逐行核对 | 只能作线索，不能作验收依据 |

本计划实际直读的 Qt 源文件：Qt/qml/Main.qml:9-60；Qt/src/NativeHud.h:37-157；Qt/src/Glyphs.cpp:592-859；Qt/src/SettingsSchema.cpp:693-703；Qt/src/MusicAccount.cpp:304-717；Qt/src/BridgeProcessAndroid.cpp:19-281。其余 Qt 行为采用 Lead 已逐条核对的事实与既有报告，实施时由 T01/T03/T05/T07 复核并落 fixture；任何未落 fixture 的 E3 不得进入页面验收。

### 0.2 三条术语纪律

1. **1:1 只指横屏。** 竖屏没有 Qt 截图或布局基准，只能称“新增重排”，不得称“1:1 复刻”。
2. **视觉证据只认同状态真机帧。** 源码常量、QML 预览图、桌面离屏图只能证明规格，不能证明 Android 像素已对齐。
3. **不能用全局指标代替逐项对照。** 任何 SSIM/ΔE/像素容差/性能比例都是辅助，不得遮住字形、布局、动作、时序的逐 ROI 人工对照，不得用大 mask 隐藏差异。

---

## 1. 目标、范围与非目标

### 1.1 目标

- 横屏：在 2880×1800、density 315、API 36 的 OPD2511 上，复刻 Qt 的 1080 高舞台、3D 场景、2D HUD、命中、输入、弹层、账号、播放、队列、歌词、设置、更新、诊断、存储与返回键行为。
- 竖屏：新增一套可用窗口布局，保留全部入口、文字、动作、状态与视觉语言；不以“缩小”“裁切”“隐藏入口”交差。
- 工程：每个页面、每个领域都有契约、owner、独占写域、可观察通过/失败、未来测试与单标题 commit；架构选型由同一切片实测裁决，不预设赢家。

### 1.2 In scope

- 契约冻结、候选 spike、架构裁决、Flutter 壳、桥、领域、HUD 渲染器、字形、3D、全部页面/弹层、横竖屏、旋转连续性、无障碍、媒体会话、包签名与数据升级门。
- Android 首发。桌面/iOS 只进能力矩阵与风险，不扩大为全平台实施。

### 1.3 Non-goals 与明确禁止

- 本文件不写产品代码、不建 Flutter 页面、不改 lib/、不改 pubspec、不碰 Qt 业务源码、不跑构建/测试/analyze/adb/设备。
- 旧 912 行计划 docs/superpowers/plans/2026-11-08-flutter-android-rewrite.md 与旧 Flutter 产物**不是新规范**；不沿用其删功能、排除 3D/性能/更新/本地能力等旧约束。旧文件保持未跟踪，不改不删。
- 不以 Material 视觉组件重画界面来冒充 1:1；Material 只可用于不可见基础设施。
- 不伪造竖屏原图、不把重复 am start 当 process-death 恢复已证、不从一次输入丢字推断搜索正确。
- 最终软件验收门未过，不得宣称“1:1 完成”。

### 1.4 当前仓库事实

| 项 | 事实 |
|---|---|
| 分支/基线 | feat/flutter，base 89493eb3c3d2c1e6c050891718134ac7670e4d6c |
| Flutter 工程 | 根目录 pubspec.yaml（89 行，SDK ^3.13.7，仅 cupertino_icons）；lib/main.dart 122 行骨架 |
| Android 入口 | android/app/src/main/kotlin/rhine/music/database/MainActivity.kt（5 行 FlutterActivity） |
| 新增 Kotlin 包 | android/app/src/main/kotlin/rhine/music/database/porting/（设计新增，非现有目录） |
| Qt 参考 | Qt/qml/Main.qml、Qt/src/、Qt/android/AndroidManifest.xml、MusicBridge/、Assets/fonts/ |
| 旧计划 | docs/superpowers/plans/2026-11-08-flutter-android-rewrite.md 未跟踪；不并入本计划 |

---

## 2. 冻结基线、证据与缺口

### 2.1 设备与 APK（E0/E2）

| 项 | 值 |
|---|---|
| 设备 | serial 526f6b6d，OPD2511，Android 16/API 36，arm64-v8a，density 315，2880×1800 |
| APK | output/RhineMusicDatabase-01ee85b96fee-android-arm64-v8a-signed.apk |
| SHA256 | bd58d95a5edee4c66a9704a108fb335163dc4274239b5f32b2a0c4cb221b5a1e |
| 版本 | versionName 0.0.0，versionCode 1，minSdk 28，targetSdk 36 |
| 安装 | 增量安装成功 11.169 s；安装前包不存在；本轮无卸载、无清数据；用户 16:53 手动同意，非采集者代点 |
| 签名 | Qt 证书 39396cd06f2b7980302bad220ed071e09286540be4d224a2f9b047ca65205bdf；旧 Flutter 证书 7c514fe8cf95411117b6a4d1cba78768c1cda1d665c42f4828398d8587239dd4，两者不同 |
| 备份 | Manifest allowBackup=false；不得承诺 adb 私有备份可用 |

### 2.2 十二张真机截图覆盖

| # | 文件 | 覆盖 | 不能证明 |
|---|---|---|---|
| 01/02 | 01-consent.png、02-consent-relaunch.png | 隐私门槛、退出后重启复现 | 拒绝后继续（没有该入口） |
| 03 | 03-home-all-songs.png | 首页/全部歌曲、3D 墙、底栏 | 播放、登录、其他 lane |
| 04 | 04-search.png | 搜索空查询、四标签、IME | 搜索命中/排序/中文输入正确 |
| 05 | 05-search-restored.png | 同安装重复启动恢复搜索页 | process-death 冷启动恢复 |
| 06 | 06-settings.png | 设置首屏 5 项 | 第 6 项以后、展开项、保存失败 |
| 07 | 07-platform.png | 四平台卡、未登录态 | 登录后个人音乐/发现 |
| 08 | 08-queue.png | 空队列、四种播放模式 | 有队列、拖动、删除 |
| 09/10 | 09-library.png、10-library-track17.png | 资料库层级、曲目列、17/933 | “查看歌单详情”独立页（未出现） |
| 11 | 11-song-detail.png | 歌曲档案、3D 封面 DRAG TO INSPECT、动作 | 播放、喜欢、加入歌单/队列 |
| 12 | 12-search-results.png | 搜索空态、喜欢歌曲文案 | 结果命中（输入实际显示 cesseary） |

未覆盖：我的音乐/发现、登录后状态、播放中、Tab Mode、设置后续项、弹层展开/关闭、错误/加载态、竖屏。以上不阻塞写计划，但阻塞“全页面视觉已验收”的结论。

### 2.3 证据缺口与闭合任务

| # | 缺口 | 影响 | 闭合 |
|---|---|---|---|
| G1 | APK 哈希未证明与当前 Qt 源码同 commit | 全部像素基准可能错源 | T01 构建出处比对；未闭合则 P1 不裁决 |
| G2 | 业务页仅 12 张局部横屏；无播放/登录/竖屏/设置后续/Tab Mode | 未覆盖页不能做像素验收 | T50/T51 另立补采与逐页降级；不得用源码或桌面图宣布通过 |
| G3 | Qt 无竖屏规范 | 竖屏不能称 1:1 | T02 定义新增几何；T43/T51 样板与新 golden |
| G4 | 设置七区已确认，但逐项可见性/平台开关未全量 | 设置页可能漏项 | T06 全量 inventory；T37 实现 |
| G5 | 存储逐键 schema、损坏回退未全量 | 迁移可能丢键 | T07 逐文件/逐键冻结；T26 实现 |
| G6 | 登录后个人音乐/发现无真机画面 | 登录态页面无像素证据 | T36/T38 以源码规格 + 账号 mock 契约实现；T50 标“视觉未取证” |
| G7 | Android 内嵌 Node 的 Flutter 生命周期未验证 | 桥可能重复启动/失联 | T21 spike；失败改用上游既有策略，不删功能 |
| G8 | 签名材料可用性未核对 | 不能覆盖安装或数据不可达 | T53 只读核对 keystore/别名/保管；不可用则停并提供迁移方案 |

G1-G8 是证据缺口/补采任务，不是用户审批门；未闭合只阻塞对应验收或发布结论，不阻塞本计划完成。

### 2.4 逻辑像素、物理像素与舞台换算

真机截图是 2880×1800 **物理像素**，不是 dp。Android density 315，DPR = 315/160 = 1.96875；Flutter 与 Qt QML 的逻辑尺寸约为 1462.857×914.286。Qt 的 QML Window 也使用逻辑像素，因此：

- 横屏舞台：stageScale = heightLogical / 1080 = 914.286/1080 = 0.846561；stageWidth = widthLogical/stageScale = 1728。
- 物理映射：physical = stage × (heightPhysical/1080) = stage × 1.666667。两种写法在物理像素上等价；**不得把 1800 直接当 QML 高度，也不得把截图坐标直接当 dp**。
- 截图 ROI 比较：physical → logical 除以 1.96875；logical → stage 除以 0.846561。像素工具必须在同一坐标系比较，禁止一边用物理、一边用逻辑。
- 渲染：CustomPainter 用逻辑坐标，先 canvas.scale(stageScale)；1 stage px 在 720p 上可能小于 1 device px，必须抗锯齿，不得四舍五入。

示例断言（T02 fixture）：physical 2880×1800、dpr 1.96875 → logical 1462.857×914.286、stageScale 0.846561、stageWidth 1728；1280×720 桌面窗口 → stageScale 0.666667、stageWidth 1920。

---

## 3. 架构候选与统一裁决

### 3.1 候选

| ID | 结构 | 忠实保留点 | 必须实测 | Spike |
|---|---|---|---|---|
| A | Flutter 宿主 + Android PlatformView 承载 Qt 视图（QtQuickView 或自建 SurfaceView + Qt 渲染控制） | Qt 渲染/输入/业务原样 | QtActivity 不能当普通 View 直接塞；嵌入视图生命周期、触摸坐标、IME、无障碍、旋转、与 Flutter 叠层 | T11 |
| B | Flutter 宿主 + Qt 离屏渲染到 SurfaceTexture，经 FlutterTextureRegistry 合成 | Qt 渲染与业务原样，合成在 Flutter | QQuickRenderControl/RHI 离屏、GL/Vulkan 纹理共享、首帧、尺寸/时间戳、旋转、输入转发 | T12 |
| C | Flutter 宿主 + Dart CustomPainter 直译 HUD，3D 另选真实移植（原生 GLES/FlutterTexture；flutter_gpu 仅独立试验） | 无 Qt 运行时依赖，长期可维护 | 17 命令、字形 JSON、命中、3D GLB/相机/拾取/雾/动画、输入时延 | T13 |
| D | 混合：HUD 由 Dart 自绘，3D 暂由 Qt Texture 提供，逐页替换 | 渐进、可回退 | 双渲染栈同步、坐标同源、退出条件、长期成本 | T14 |
| E | Flutter 宿主 + 本地 WebView（canvas/WebGL/Three.js）完整复刻 | 命令语义可只写一次；Web 生态 | 全切片功能、IME、无障碍、纹理合成、首帧/resize、WebView 版本差异 | T15 |

说明：RhineLabUI 在 README:330 是上游界面模型/场景参考，不等于本 APP 全部功能；E 是完整候选，不是“只复用素材”。A/B/D 允许保留 Qt 移植层，无强制拆除 Qt 的期限；C/E 也必须通过同一功能门，不能以“纯 Flutter”换取删功能。

### 3.2 共同约束

- PlatformView/Texture 只是嵌入通道，不保证 QtActivity 可直接嵌入、GPU 后端可共享、SurfaceView 与 Flutter 可叠层；失败必须记录并退出该候选。
- 任何候选都不得以静态背景冒充 3D、不得删减账号/搜索/队列/设置/更新/诊断/本地 Siren 收藏、不得改上游协议。
- 跨桥若新增 envelope（例如带 generation 的 frame 包装），属于**新设计**：必须与 Qt 原数组契约并存并标注；envelope 的大小/超时/entityKey 等数值均为**拟议**，由 T10/T16 冻结，不冒充 Qt 原协议；不得用 seq/z 去重合法相同的命令，不得改变 hits 的生成/消费顺序。
- 候选新增第三方依赖只在独立 worktree 记录版本/许可证/平台支持；主 pubspec.yaml 不并写；裁决后仅赢家引入。
- 候选 spike 只能改宿主适配与 Qt/porting/；不得改 Qt 业务语义、存储 schema、登录状态机。

### 3.3 单切片与硬门

切片（同一设备、同一状态脚本）：启动 → archive 全部歌曲 → 打开第 17 首详情（3D 封面）→ 返回 → 搜索输入中文并打开结果 → 加入队列/移除 → 旋转竖屏再回横屏。切片必须同时覆盖：3D 画面、HUD 文字、命中、IME、无障碍、媒体会话、旋转、返回键。

硬门（全部满足才可进入裁决）：

1. 功能：切片内每个动作都有结果，无缺页、无禁用入口、无“稍后实现”。
2. 画面：逐 ROI 人工对照通过；文字、字形、颜色、层级、3D 材质/雾/相机可辨；无静态图假 3D。
3. 协议：同状态下 commands 逐条 token 等价；hits 逐项矩形与顺序等价；frame 投影矩阵容差 1e-9；不得去重相同命令。
4. 输入：hit 与绘制同源；IME 提交文本、selection、focus 正确；Android 按下即触发/iOS 抬起触发按源保留或记录统一偏差。
5. 状态：旋转不重复登录、不重复 Node worker、不重建媒体源；播放/队列/滚动/输入/3D 时钟连续。
6. 稳定：切片连续 30 分钟无崩溃、无 ANR、无泄漏到 OOM；性能只记录实测分布，不设自造固定 60fps。
7. 可维护：写清失败出口与回退；不以大 mask、全局 SSIM 或降低功能换取通过。

### 3.4 裁决规则

- T16 汇总所有已跑候选的同一切片数据；**没跑过的候选不得填指标**，只能标“未评估”。
- 优先选择最能忠实保留现有 Qt 逻辑、返工面最小、失败出口最清晰的方案；推荐评估顺序 B → A → D → C → E（仅为排期，不是预设赢家）。B/A 最接近原逻辑，D 可渐进，C/E 重写面大但合法。
- 若某候选全门通过且其余候选在剩余预算内不可能更优，可提前停止其余 spike，但必须在 ADR 记录停止理由与未评估项。
- 若全部候选失败：停止，向 Lead 报“架构未裁决”，不得以静态背景、删功能或 Material 重画强行交付。

---

## 4. 不可协商的绘制与几何契约

### 4.1 舞台与层

- 横屏：stageScale = heightLogical/1080；stageWidth = widthLogical/stageScale；3D 与 Overlay 同窗独立层，HUD 不烤进 3D 插值纹理。旋转/尺寸变化只重算 stage，不重建引擎状态。
- 竖屏：不复用横屏公式；由 LayoutBuilder 的可用窗口 + MediaQuery 安全区 + IME 计算统一 layout geometry，同一 geometry 同时输出 draw 与 hit；不按设备类型写顶层 OrientationBuilder。
- 层序：3D → HUD → modal 遮罩 → hits 透明层 → chrome → 性能面板。modalOffset 只推非 fixed hits。
- 真实输入框：检索、账号/验证码、设置编辑使用真实 Flutter 文本输入，位置来自 state 的 input 矩形；视觉文字仍由字形渲染器绘制，不能用普通 Text 代替后宣称一致。

### 4.2 commands：Qt 原始数组契约

Qt 公开值：NativeHud.h:74-76 的 commands、hits、frame。命令是数组，a[0] 为 op，**不是** {id,opcode,args,seq} 对象，也没有 z/frameId。下表 17 个 op 来自 Glyphs.cpp:637-825，参数下标按数组逐项核对：

| op | 参数（含 a[0]） | 语义 |
|---|---|---|
| save | "save" | QPainter 状态入栈 |
| restore | "restore" | 状态出栈 |
| alpha | "alpha", v | opacity 乘算：c.opacity()*v，不覆盖 |
| translate | "translate", x, y | 当前变换平移 |
| scale | "scale", sx, sy | 当前变换缩放 |
| rotate | "rotate", radians | 弧度，不是度 |
| clip | "clip", x, y, w, h | IntersectClip |
| fill | "fill", COLOR, x, y, w, h | fillRect；颜色在 a[1] |
| ellipse | "ellipse", COLOR, x, y, w, h | 左上矩形 + 宽高，不是圆心/半径 |
| text | "text", VALUE, x, y, size, weight, tracking, COLOR | 基线 y+size*1.044；逐字 advance*size+tracking |
| art | "art", KEY, x, y, size, count, tracking, COLOR | count<0 表示整串；无 text 的 1.044 基线偏移 |
| fill-path | "fill-path", SVG, COLOR | 填充路径 |
| path | "path", SVG, PENWIDTH, COLOR, DASHARRAY, DASHOFFSET | FlatCap/MiterJoin；dash 与 offset 均除以 penWidth |
| arc | "arc", CX, CY, R, START, SWEEP, PENWIDTH, COLOR | 弧度；Qt 内部取 -start/-sweep；RoundCap |
| right-mask | "right-mask", COLOR, START, SPAN, RIGHT, HEIGHT | 16 段 smoothstep alpha 渐隐 |
| gradient | "gradient", DARK | 固定中心 (979.2,518.4)、半径 1100，覆盖 8192×8192 |
| image | "image", KEY, x, y, w, h | 宿主按 key 解析图片 |

颜色是 RGBA 数组；第 5 项以 calibrated 前缀标记（calibratedWhite/calibratedRGB 等，Glyphs.cpp:35-49），按 Gamma 1.8 → sRGB 转换。

### 4.3 hits、frame 与发布

- hits 元素：必需 {x,y,width,height,action,label}（NativeHud.cpp:102-109）；仅 PlayerBar 的 hit 额外带 fixed:true（PlayerBar.cpp:46-53）。由绘制同源调用产生，按源生成/消费顺序消费；矩形是舞台坐标。禁止猜 z、禁止排序改写、禁止外扩写回源矩形（外扩只属于触摸层策略）。
- frame：3D 与 HUD 共用的一份渲染帧；字段清单由 T03 从 RhiScene/Engine 冻结，本节不枚举，避免把 eye/fog 等非顶层键写成契约。Flutter 只读。
- 发布：commands/hits/frame 必须同一状态代次发布；新增 generation 只能用于一致性校验，**不得去重合法相同的命令**。measure、hit、IME 使用同一 layout geometry，禁止三套坐标。
- 重绘：命令流变化必须立即触发一帧；仅 setState 不保证呈现帧的语义要显式测试。

### 4.4 文字、字体、颜色

- 素材：Assets/fonts/RhineMiSans-light.otf、RhineMiSans-regular.otf、RhineMiSans-demibold.otf、RhineMiSans-bold.otf、NotoSansSymbols2-Regular.ttf、misans-glyphs.json（weight→glyph→{advance,path}）。
- 正常路径：读同一 JSON 的 advance/path，按 advance*size+tracking 逐字绘制；基线 y+size*1.044；fit() 二分截断并补省略号；滚动数字使用源曲线（默认 0.46 s）。
- 回退：只有缺字、组合字符、复杂文字、RTL 才走 QTextLayout + 系统字体；NotoSansSymbols2 负责符号。禁止用普通 Text 全量重排后宣称字宽/截断/居中一致。
- 颜色：亮/暗两套 paper/panel/ink/muted/line/soft/amber；calibrated 颜色做 Gamma 1.8 → sRGB；遮罩、页脚方块、boot 橙按源常量。不能用 Material ColorScheme 近似。

### 4.5 2D HUD 与 3D 边界

- *Card.cpp 是 2D HUD 绘制器，由 NativeHud 调用并追加 commands/hits，不是 3D 贴图；SongDetailCard、CollectionDetailCard、PlaybackQueueCard、DiscoverMusicCard、SettingsCard、PlayerBar 均按 2D 迁移。
- 3D 必须保留真实 GLB、材质、相机、BVH 拾取、灯光、雾、动画时间、纹理准入；禁止静态背景、预渲染视频或把文字烤进 3D。
- 3D 与 2D 的隐性契约：投影偏移 0.16/0.20、18% 视野外扩、near 5/far 300、竖屏 aspect<1.05 分支、viewer 34° FOV/0.3..120 裁剪。

### 4.6 性能政策

- Qt 按需绘制，静止画面低 fps 正常；不得把“稳定 60fps/16.6ms/jank 1%/冷启动 +10%/内存 +15%”写成已承诺目标。这些数字若出现，只能作为“拟议待 P0/P4 基线冻结”的辅助指标。
- 辅助 SSIM≥0.97、ΔE≤3、像素容差、性能比例均为拟议，需用 Qt 同设备同场景基线冻结；它们不能代替逐 ROI、字形、布局、动作、时序的人工对照，不得用大 mask 遮差异。
- 核心硬门是功能/画面/动作/状态齐全；性能不达标可以优化或记录差异，但不能删功能换分数。

---

## 5. 领域、账号、设置、桥与存储

### 5.1 领域状态归属

| 领域 | 自有状态 | 禁止 | 任务 |
|---|---|---|---|
| MusicLibrary | provider、五 lane、目录栈、游标、搜索四种、收藏、Siren 目录（933 首/303 专辑）、MSR | 把目录逻辑塞进 UI | T22 |
| MusicPlayer | 播放态、音质、URL/解码、恢复、audio focus | 绕过唯一队列；UI 直接解码 | T23/T25 |
| PlaybackQueue | 唯一队列 + 历史、当前项、模式 | 第二队列；历史混入队列 | T23 |
| LyricsController | 缓存、偏移、来源、同步 | UI 内解析歌词 | T23 |
| NativeScene | 卡片阵、相机、材质、雾、拾取、动画、纹理准入 | 静态图假 3D | T41 |
| NativeHud | commands、hits、frame、modal、滚动、编辑态 | 只迁 Node 后 Material 重画 | T30-T32 |
| Host | 凭据、偏好、子进程、更新、诊断 | 凭据进日志/worker | T21/T24/T26/T27 |
| Node worker | 仅上游协议适配 | 承载业务状态；重设计上游协议 | T21 |
| Search | 防抖、请求 generation、取消、最近搜索白名单 | UI 内拼请求；旧响应覆盖新状态 | T22/T35 |
| MediaSession/AudioFocus | 锁屏、通知、耳机键、焦点 | 与播放器双写 | T25 |
| Update | 检查/下载/安装意图/失败回退 | 绕签名安装；旧计划排除 | T27/T37 |
| Storage | session、playback、device、collections、panel 偏好 | 默认登出、清收藏、把 panel 当文件 | T26 |

### 5.2 账号：六条真实路径，不是六态模板

| Provider | 路径 | 说明 |
|---|---|---|
| 塞壬 Siren | 免登录 | 本地 Siren 收藏/MSR；不是远程登录入口 |
| 网易云 NetEase | 二维码 + 手机号短信 | 仅 NetEase 允许短信；QQ/酷狗不得实现 SMS |
| QQ 音乐 | 二维码（channel=qq）+ 微信二维码（channel=wechat） | 取消有完成屏障；retryAfterMs 按 provider 墙钟倒计时 |
| 酷狗 | 标准版二维码 + 概念版二维码 | 两个 edition 各一条；单一 kugou-device.json，edition 由 RHINE_KUGOU_EDITION 区分 |

源码已核对的阶段与规则（MusicAccount.cpp）：

- 阶段：idle、preparing、waiting、confirming、complete、failed；**没有 LoggedOut 六态模板**，UI 只订阅这些阶段与账号状态。
- canRegenerateLogin：冷却为 0 且阶段不是 preparing/confirming（:304-306）。
- cancelLogin：generation++、清 qrKey/qr、phase=idle；QQ 有旧 key 时发 /login/qr/cancel 并建立完成屏障，下一次生成等待取消结果（:352-379）。
- prepareQR：QQ channel=wechat 或 qq；NetEase 用 host->qr，QQ/酷狗用 /login/qr/create 的 qrimg data URI；成功后 phase=waiting 并开始轮询（:560-623）。
- 轮询：schedule 每 1000 ms；count>=300 失败；800 过期（QQ 走 reportLoginFailure）、801 继续等待扫码（不改 phase）、802 已扫描待确认、803 确认后 confirmLogin；phase=confirming；缺省码 800（:625-667）。
- 短信：仅 provider==netease；手机号 ^1[0-9]{10}$；验证码 ^[0-9]{4,8}$；发送前 60000 ms 重发限制；generation 过滤旧响应（:402-462）。
- 确认：confirmLogin 成功后非短信路径清 qr/qrKey、phase=complete、清冷却；失败 phase=failed；**验证码失败是例外：只设 loginStatus，不进入 failLogin→failed**；验证码成功也不走非短信 complete 分支；凭据保存失败不得假装登录（:464-523）。
- 登录成功/失败/登出不得默认清空收藏或注销其他 provider；logout 只清当前来源凭据与私有资料。

### 5.3 设置：七区与全量 inventory

SettingsSchema.cpp:693-703 固定七区（顺序、标题、卡片高度）：

1. Provider / PROVIDER ACCESS / 音乐平台 / provider-card / 160
2. Preferences / TERMINAL PREFERENCES / 终端偏好
3. Performance / PERFORMANCE / 性能与诊断 / performance / 220
4. Storage / STORAGE / 存储与缓存 / storage / 105
5. Update / SOFTWARE UPDATE / 软件更新 / update / 220
6. Project / PROJECT / 项目与开源参考
7. Footer / CONFIG / 配置管理 / defaults / 84

全量页态与操作必须在 T06 冻结，至少覆盖：当前平台/切换平台；亮暗/跟随系统、动态效果、启动动画、Reinitialize、音质；帧生成、vsync、MSAA、AA 模式、渲染倍率、FSR、GPU 选择（按平台可见性）；缓存大小/清除/结果提示；检查更新/下载/安装/失败；八个项目链接；恢复默认/配置管理。当前 Qt 真实存在的更新、诊断、consent 不得因旧计划排除而消失；Android 上不适用的桌面项按源 visible/enabled 规则隐藏，而不是删除。

### 5.4 Node 桥：已内嵌，迁移的是生命周期

BridgeProcessAndroid.cpp 已证：node::Start(argc,argv)（:19-24）；Node 只初始化一次 + 随机 token 回环（:35-39、:81-91）；输入上限 48*1024*1024（:73）；MusicBridge/ios-runtime.cjs（:102、:107）；线程栈 8 MiB（:118）；worker.cjs（:207-211）；启动 30000 ms 超时（:213）；TMPDIR 用外部 cache，QQ/酷狗 device 状态走 dataDirectory（:194-206）。

Flutter 迁移要求：

- 复用同一 ios-runtime.cjs/worker.cjs 协议；字段名改动一处即静默断链，必须协议回放测试。
- Node 运行时进程级单例；Flutter Activity 重建/旋转/前后台不得重复 node::Start；会话按 engine 生命周期串行 stop/start。
- token 认证、握手前排队、48 MiB 上限、30 s 超时、stderr 落 logcat、worker 崩溃回传全部保留。
- 若 Flutter 进程内嵌 Node 不可行，改用上游既有策略（保留 Qt 移植层的 Node 宿主或等价原生宿主），不得造一个缺协议的假 worker；失败记录在 ADR 与 T21。

### 5.5 存储与状态

- 路径：AppStorage.cpp:80 Android dataDirectory=QStandardPaths::AppLocalDataLocation；:91 cache=CacheLocation。Host.cpp:1075/1095 的 panel/<key> 是 **QSettings 键**，不是 data/panel 文件。迁移清单记录运行时解析的绝对路径与键名，不写死 /data/data/<包名>，不猜 INI 文件名。
- session.json：顶层 {version:1, library, player, view}；QSaveFile 原子写；大于 64 MiB 拒绝并保留旧档（MusicSession.cpp:215、269-284）。
- view 字段：mode、selected、tab、modal、queueOffset、settingsScroll、query、groupBy、activeGroup、artistTab、listOffset、trackOffset、bodyOffset、musicCollection、trackListMode、lyricsMode；恢复按白名单与夹取，不新造字段。modal 恢复白名单仅 saved/search/discover/queue/settings/player/local 七项（MusicSession.cpp:243），其余 modal 不恢复。
- playback-session.json：队列/索引/位置/模式；兼容旧 session.json（PlaybackService.cpp:423、426）。
- device 状态：qq-device.json、单一 kugou-device.json 在 dataDirectory；酷狗 standard/lite 的令牌在 cookies.__kugou[edition] 按 edition 分键，RHINE_KUGOU_EDITION 区分，不是两个 device 文件（BridgeProcessAndroid.cpp:204-206、Host.cpp:268-269、513-516）。
- 凭据：走 Host 平台安全存储分支；迁移不得默认注销、不得清空账号/收藏；签名不可达时停在发布门并提供明确迁移方案，不删除私有数据。
- 缓存（封面/歌词/纹理）可重建，但不得把“可重建”当删除用户数据的理由。

### 5.6 平台能力矩阵

| 能力 | Android | iOS | Windows | macOS | Linux |
|---|---|---|---|---|---|
| OfficialPlayback | false | false | 源桌面分支（本轮不实施） | 源桌面分支（本轮不实施） | 源桌面分支（本轮不实施） |
| LocalMusic | false | false | 同上 | 同上 | 同上 |
| ApplicationVolume | false | false | 同上 | 同上 | 同上 |
| DesktopWindowControls | false | false | 同上 | 同上 | 同上 |
| DesktopLyrics | false | false | true（不实施） | true（不实施） | false（不实施） |

Qt PlatformFeatures 的 RHINE_MOBILE 同时覆盖 iOS 与 Android，前四项 false 是平台事实，不是“待定”；Android 不展示入口不等于删除能力。桌面/iOS 只列矩阵，不扩大实施。

---

## 6. 页面、状态、动作全量矩阵

### 6.1 页面级

| 页面 | 关键状态 | 动作 | 证据 |
|---|---|---|---|
| Consent 隐私门槛 | 首次/已同意/退出/重入 | 同意、退出 | E0 01/02；持久化仅同安装已证 |
| Boot | 启动动画/跳过/35 s 切 detail | ENTER SYSTEM、skip | E1 NativeHudBoot |
| Archive/首页 | 五 lane、目录栈、选中、滚动、Tab Mode、mask | open、column-prev/next、tab-mode、返回上一级、播放全部 | E0 03/09/10；E1 NativeHud.cpp |
| 目录空态 | 空目录/返回 | 返回上一级 | E1 NativeHud::empty |
| 歌曲详情 | 加载/正常/无同专辑/有同专辑/播放态 | 播放、喜欢、加入歌单/队列、下一首、歌手作品、tabs、排序 | E0 11 |
| 歌单/专辑/歌手详情 | artist tabs、当前行、收藏态、排序 | 播放全部、排序、收藏、打开曲目 | E1 NativeHudDetail/CollectionDetailCard |
| 3D 查看器 | opening/closing/reset/清晰/磨砂 | 拖拽、重置、关闭、查看封面 | E0 11 封面；E1 NativeViewer |
| 搜索 | 空/输入/结果/无结果/错误/分组/四标签 | 输入、清除、切标签、点结果、翻页 | E0 04/05/12 仅空态 |
| 个人库/收藏 | 未登录/已登录/空/加载 | 登录、创建歌单、刷新、打开 | E1 NativeHudLibrary；E0 07 未登录 |
| 登录面板 | qr/phone/wechat、preparing/waiting/confirming/complete/failed | 生成/重生成、扫码、发短信、提交、取消 | E1 MusicAccount |
| 设置 | 七区、展开项、滚动、保存失败、缓存提示 | 开关、选择、编辑、恢复默认、清除缓存、检查更新 | E0 06 首屏；E1 SettingsSchema |
| 发现 | 首屏/分页/错误/分类 | 滚动、打开卡片 | E1 NativeHudDiscover |
| 播放栏 | 无播放/加载/播放/暂停/seek/音量/歌词 | prev/toggle/next/seek/volume/词/队列 | E0 03/08；E1 PlayerBar |
| 播放队列 | 空/单曲/多曲/当前项/拖动 | 播放、删除、清空、拖序、模式 | E0 08 空态 |
| 歌词 | 无歌词/加载/偏移/来源/跟随 | 调偏移、切来源、重试、重置 | E1 NativeHud lyrics |
| 更新 | 检查/无更新/有更新/下载/安装/失败 | 检查、下载、安装 | E1 SettingsSchema；E0 未覆盖 |
| 诊断/性能面板 | 开/关/指标 | 开关、采样 | E1 PerformancePanel |
| Tab Mode | 开/关/列布局 | 进入/退出、选列 | E1 NativeHud archive |
| 桌面歌词 | 仅桌面 | 样式、位置 | 矩阵保留，Android 不实施 |

### 6.2 弹层级

search、saved/个人库、login、settings、discover、player/queue、quality、provider、playlist-form、playlist-picker、confirm、disc-rotation-warning、lyrics-offset、lyrics-source、detail-sort、desktop-lyrics（桌面）。每个弹层的几何、滚动、fixed hits、关闭动画、IME 叠层在 T02/T03 冻结；页面任务必须逐个实现，不得合并成“通用弹层”丢语义。

### 6.3 动作命名空间

源码字面量聚合（迁移前由 T05 重新冻结，保留大小写与冒号载荷）：discover、search、saved、settings、open、back、close-modal、archive:tab-mode、archive-mask:<v>、column-prev/next、prev/next、music:play-loaded、player:clear、player:remove:<i>、player:lyrics-*、single-play-mode、detail-autoplay、music:qr/preview/cover-front/activate/parent/picker-prev/picker-next/open-all-siren/directory/directory-info、local:*、viewer:reset/clear/frosted/close、settings:scroll-up/down、quality:set:<id>、disc-rotation*、close-behavior、motion、vsync、msaa:<v>、aa-mode:<v>、aa-scale:<v>、render-scale:<v>、fsr-*、gpu-index:<i>、startup-animation、skip、confirm:yes、alternative、title。

### 6.4 竖屏：新增设计，不是 1:1

- Qt 两个 Activity 都是 sensorLandscape；HUD 只有 1080 高一套绘制，3D 相机/查看器已有 aspect<1.05 分支。竖屏缺的是 HUD 排版，不是 3D 能力。
- 候选样板（只作比较，不是硬规则）：Portrait-W（stageScaleP=widthLogical/1080，stageWidthP=1080，stageHeight=heightLogical/stageScaleP，顶部 1080 带复用横屏命令，详情/列表纵向延伸，底部播放栏贴底）；Portrait-Band（固定 1080 宽分带滚动）；Portrait-Hybrid（顶栏+内容+底栏三段，详情单列）。
- 弹层形态、列数、触摸尺寸、字体下限、3D 占比（如 52%）都必须经过同一控件的可达性、信息层级、触摸命中、字尺度比较后冻结；不得预先规定所有弹层都 bottom sheet、所有页面单列、固定 48dp 或固定 52%。
- 必须保留：全部入口/文字/动作/状态；安全区避让只作用于新增纵向容器；IME 不缩放 stage，输入框保持舞台坐标，按冻结策略上移或压缩；返回键与手势不改变应用内层级语义。
- 竖屏 golden 是新基准，不是 Qt 原图；未审定前不得实现铺开。样板审定一次即可冻结模式，不为每个小项新造用户审批 gate。

### 6.5 旋转连续性清单

旋转/窗口变化时只允许 MediaQuery 重建与 stage 重算；引擎/状态对象活在 Widget 树之外，禁止 runApp 重建、dispose 播放器、清空列表、重新登录。必须保持：

- 五 lane 与当前 lane；目录堆栈与每层游标；item key + 相对滚动偏移（不是绝对 offset）。
- 输入文本、selection、composing、focus；编辑中的设置项与光标。
- 二维码墙钟有效期、generation、cancel 完成屏障；不得 closeModal/cancelLogin 导致二维码丢失。
- 队列、当前曲、播放位置、播放模式、历史；歌词偏移与来源。
- 3D 相机/动画时钟/boot 起点/detail 淡入/viewer opening/reset/clarity；拖拽中旋转要取消拖拽并恢复可交互，不丢选中卡。
- modal 名、关闭中进度、modalOffset；滚动数字曲线不重启。

---

## 7. 分阶段任务

通用约定：每个任务一个 owner；Files 段列出的路径即独占写域，同一文件不得并写；依赖未满足不启动；每个任务完成后 owner 自己派**恰 1 名**独立 ginka/deepseek-v4.1-flash（max 或 high）只读 reviewer，reviewer 不递归、不写文件、不构建/测试/adb，可读全部相关契约/fixture/diff，不被“4 文件”人为限制；owner 实收修正后立即以单标题 commit 提交。所有命令均为未来步骤，本轮不执行。本阶段共 42 张任务卡（P0 7 + P1 7 + P2 8 + P3 15 + P4 5）。

### P0 契约与基线（只写文档/夹具，不写产品）

#### T01 Qt 基线出处与证据台账
- Owner: BASE · Deps: 无 · Files: Create docs/flutter-migration/00-baseline.md、docs/flutter-migration/evidence/device-2026-11-09.md、test/fixtures/baseline_manifest.json、test/baseline_manifest_test.dart；Modify 无；Test test/baseline_manifest_test.dart
- [ ] 记录 APK SHA256、证书全值、versionName/Code（实测 versionCode=1，不是行为报告的 0）、min/targetSdk、安装前包不存在、install 无卸载/清数据。
- [ ] 记录候选 Qt commit 01ee85b96feeac875660e963ff78fbd383da0ae5；只用构建记录/产物元数据/可复现参数判定 APK 是否对应该 commit，不得用 -signed 文件名哈希、versionName 或“应该一致”反推 release key/构建对应。
- [ ] 复核 Manifest sensorLandscape、allowBackup=false、resizeableActivity=false、GLES3；记录 12 图索引与未覆盖项。
- [ ] fixture 固化 serial/APK SHA256/证书/版本/SDK；测试断言字段非空且 SHA256 为 64 位十六进制。
- [ ] 输出“基线可用/不可用”；不可用则 P1 不裁决、T50 不宣称像素通过。
- Pass: flutter test test/baseline_manifest_test.dart 通过，且 G1 有明确结论、证据可复核。Fail: 任何“哈希像是对的上”的推断或测试失败仍放行。
- Future: flutter test test/baseline_manifest_test.dart；git log -1 --format=%H -- Qt/ 与构建机产物记录比对。
- Commit: docs: freeze qt baseline provenance

#### T02 布局与舞台契约
- Owner: LAYOUT-CONTRACT · Deps: T01 · Files: Create docs/flutter-migration/contracts/layout.md、test/fixtures/stage_metrics.json、test/stage_metrics_test.dart；Modify 无
- [ ] 冻结横屏 stageScale/stageWidth、逻辑/物理/DPR 换算、层序、modal 遮罩、fixed hits。
- [ ] 冻结竖屏候选几何（Portrait-W/Band/Hybrid）与可用窗口/安全区/IME 公式，不预设最终形态。
- [ ] 冻结 draw/hit/IME 同 geometry 的输出结构与旋转重算规则。
- [ ] fixture 至少含 2880×1800、1280×720、1080×2400、1440×3200 四组；竖屏尺寸是拟议测试矩阵，不是已证实真机基线。
- Pass: flutter test test/stage_metrics_test.dart 对 stageScale 0.846561/stageWidth 1728、桌面 0.666667/1920 全部通过。Fail: 任一公式与 Main.qml 不一致。
- Commit: docs: freeze stage and portrait geometry contract

#### T03 HUD 协议契约
- Owner: HUD-CONTRACT · Deps: T01 · Files: Create docs/flutter-migration/contracts/hud-protocol.md、test/fixtures/hud_commands_17.json、test/fixtures/hud_hits.json、test/hud_protocol_test.dart；Modify 无
- [ ] 逐项冻结 17 op 的数组下标、类型、默认值、裁剪/alpha/变换语义、颜色第 5 项。
- [ ] 冻结 hits 必需六字段 x/y/width/height/action/label + 仅 PlayerBar 可选 fixed:true、生成/消费顺序、禁止 z 排序；冻结 frame 公开字段与同代次发布。
- [ ] hits fixture 覆盖基础六字段与 PlayerBar fixed:true；断言其余 hit 不带 fixed。
- [ ] 明确新增 envelope 属新设计：不去重相同命令、不改 hits 顺序、measure/hit/IME 同 geometry。
- [ ] fixture 覆盖 save/restore、alpha 乘算、fill/ellipse 颜色在 a[1]、path dash 归一、arc 弧度、right-mask 16 段、gradient 固定中心。
- Pass: flutter test test/hud_protocol_test.dart 断言 17 op 名称与参数位置全等、hits 六字段/fixed 契约通过。Fail: 出现 {id,opcode,args,seq}、z 字段或把 fixed 扩展到非 PlayerBar hit。
- Commit: docs: freeze native hud command and hit protocol

#### T04 文字、字形与颜色契约
- Owner: TEXT-CONTRACT · Deps: T01 · Files: Create docs/flutter-migration/contracts/text-color.md、test/fixtures/glyph_metrics.json、test/text_metrics_test.dart；Modify 无
- [ ] 冻结四个 OTF + NotoSansSymbols2 + misans-glyphs.json 的加载、advance/path、基线 1.044、tracking、fit 省略号。
- [ ] 冻结 QTextLayout 回退触发条件（缺字/组合/复杂/RTL）与回退字体顺序。
- [ ] 冻结亮/暗色板、calibrated Gamma 1.8 转换、遮罩/页脚/boot 常量。
- [ ] fixture 用 3 组颜色与 3 组字宽断言；记录普通 Text 不可用的原因。
- Pass: flutter test test/text_metrics_test.dart 字宽/基线/颜色全等。Fail: 用系统字体近似通过。
- Commit: docs: freeze glyph metrics and calibrated colors

#### T05 领域、账号与动作契约
- Owner: DOMAIN-CONTRACT · Deps: T01 · Files: Create docs/flutter-migration/contracts/domain.md、test/fixtures/login_matrix.json、test/login_matrix_test.dart；Modify 无
- [ ] 冻结六条登录路径、六阶段、正则、60 s 重发、1000 ms 轮询、300 次超时、800/802/803、cancel 屏障、retryAfterMs。
- [ ] 冻结五 lane、目录栈、搜索四种、收藏/MSR、歌单写操作、唯一队列+历史、歌词来源/偏移。
- [ ] 冻结动作命名空间与大小写/载荷；标注“源码聚合，T05 重新核对”。
- [ ] fixture 覆盖 NetEase qr/phone、QQ qq/wechat、Kugou standard/lite；断言 QQ/酷狗无 SMS。
- Pass: flutter test test/login_matrix_test.dart 六路径与阶段转移全过。Fail: 出现 LoggedOut 六态模板或 3×qr/sms。
- Commit: docs: freeze domain and six login paths

#### T06 设置、平台与更新契约
- Owner: PLATFORM-CONTRACT · Deps: T01 · Files: Create docs/flutter-migration/contracts/settings-platform.md、test/fixtures/settings_sections.json、test/settings_sections_test.dart；Modify 无
- [ ] 冻结七区 ID/顺序/中英标题/卡片高度/visible/enabled；逐项列设置行、选项、默认值、存储键。
- [ ] 冻结 Android/iOS/桌面能力矩阵；更新、诊断、consent 不得消失；桌面歌词仅 mac/win。
- [ ] 冻结更新检查/下载/安装/失败、缓存清理、恢复默认、项目链接的页面动作。
- [ ] fixture 断言七区顺序与 Provider/Preferences/Performance/Storage/Update/Project/Footer。
- Pass: flutter test test/settings_sections_test.dart 七区全等。Fail: 少于七区或把更新/诊断排除。
- Commit: docs: freeze settings sections and platform capabilities

#### T07 存储、会话与凭据契约
- Owner: STORE-CONTRACT · Deps: T01 · Files: Create docs/flutter-migration/contracts/storage.md、test/fixtures/session_view.json、test/session_schema_test.dart；Modify 无
- [ ] 逐文件逐键冻结 session.json 顶层 {version:1,library,player,view}、view 全字段、白名单/夹取、64 MiB 拒绝保留旧档。
- [ ] 冻结 playback-session.json 与 session.json 兼容、qq-device.json/单一 kugou-device.json、panel/<key> 是 QSettings 键。
- [ ] 冻结凭据安全存储分支、签名不可达时的停止/迁移方案、缓存可重建但用户数据不删。
- [ ] fixture 断言 view 字段集合与非法字段被拒；断言 >64 MiB 不覆盖旧档。
- Pass: flutter test test/session_schema_test.dart 字段/夹取/拒绝全过。Fail: 默认登出或把 panel 写成 data/panel 文件。
- Commit: docs: freeze session storage and credential contract

### P1 单切片与架构裁决

#### T10 切片规格与量具
- Owner: SLICE-LEAD · Deps: T02-T07 · Files: Create docs/flutter-migration/01-slice.md、test/fixtures/slice_cases.json、tool/parity/slice_runner.dart、test/slice_spec_test.dart；Modify 无
- [ ] 固定 archive→detail→search→queue 脚本、状态输入、采样点、ROI、命中/IME/a11y/媒体会话检查项。
- [ ] 固定同设备、同 DPR、同亮度、同字体缩放；固定命令/hits/frame 导出格式。
- [ ] 预注册通过/失败判定与证据保存路径；禁止事后调阈值。
- Pass: flutter test test/slice_spec_test.dart 脚本步骤与 ROI 完整。Fail: 任何候选可用不同切片。
- Commit: docs: freeze single parity slice and measurement plan

#### T11 候选 A：PlatformView 切片
- Owner: HOST-A · Deps: T10 · Files: Create lib/platform/qt_platform_view.dart、android/app/src/main/kotlin/rhine/music/database/porting/QtPlatformViewHost.kt、integration_test/slice_platformview_test.dart；Modify android/app/src/main/kotlin/rhine/music/database/MainActivity.kt
- [ ] 证明 QtActivity 不能直接塞后，改用 QtQuickView 或自建 SurfaceView + Qt 渲染控制；记录实际可行路径。
- [ ] 触摸坐标映射、IME、无障碍、旋转、前后台、媒体会话逐项跑切片。
- [ ] 记录失败点与最小 Qt 适配面；不改业务语义。
- Pass: 切片全门通过或明确失败原因。Fail: 静态截图冒充嵌入、触摸错位仍宣称可用。
- Future: flutter test integration_test/slice_platformview_test.dart -d 526f6b6d
- Commit: spike(host): evaluate qt platformview slice

#### T12 候选 B：Qt 离屏 Texture 切片
- Owner: HOST-B · Deps: T10 · Files: Create lib/platform/qt_texture.dart、Qt/porting/TextureHost.h、Qt/porting/TextureHost.cpp、Qt/porting/CMakeLists.txt、android/app/src/main/kotlin/rhine/music/database/porting/TextureBridge.kt、integration_test/slice_texture_test.dart；Modify Qt/CMakeLists.txt
- [ ] QQuickRenderControl 离屏渲染到 SurfaceTexture，注册 FlutterTexture；验证首帧、尺寸、时间戳、旋转。
- [ ] 验证 GL/Vulkan/RHI 后端与 Flutter 合成兼容；记录不可共享时的退出条件。
- [ ] 输入转发、IME、a11y、媒体会话跑同一脚本。
- Pass: 切片全门通过或明确失败。Fail: 只有静态首帧、旋转黑屏仍继续。
- Future: flutter test integration_test/slice_texture_test.dart -d 526f6b6d
- Commit: spike(host): evaluate qt offscreen texture slice

#### T13 候选 C：Dart HUD + 3D 移植切片
- Owner: HOST-C · Deps: T10 · Files: Create lib/spike/dart_hud/hud_painter.dart、lib/spike/dart_hud/glyph_loader.dart、lib/spike/scene3d/scene_surface.dart、integration_test/slice_dart_hud_test.dart；Modify 无
- [ ] 直译 17 命令、hits、字形 JSON、一个 archive 页 + 详情 + 搜索 + 队列。
- [ ] 3D 用原生 GLES/FlutterTexture 填真实 GLB、相机、拾取；flutter_gpu 只在独立 worktree 试验，不并写主 pubspec.yaml；禁止静态背景。
- [ ] 跑同一切片，记录字形/命中/时延差异。
- Pass: 切片全门通过或明确失败。Fail: 用 Material 列表替代 HUD。
- Future: flutter test integration_test/slice_dart_hud_test.dart -d 526f6b6d
- Commit: spike(hud): evaluate dart hud and 3d port slice

#### T14 候选 D：混合切片
- Owner: HOST-D · Deps: T10、T12 · Files: Create lib/spike/hybrid/hybrid_host.dart、Qt/porting/HybridTextureHost.h、Qt/porting/HybridTextureHost.cpp、integration_test/slice_hybrid_test.dart；Modify Qt/porting/CMakeLists.txt
- [ ] HUD 由 Dart 绘，3D 由 Qt Texture 供；验证坐标同源、同步、旋转、退出条件。
- [ ] 跑同一脚本，记录双栈成本与可回退点。
- Pass: 切片全门通过或明确失败。Fail: 两套状态双写导致错帧。
- Future: flutter test integration_test/slice_hybrid_test.dart -d 526f6b6d
- Commit: spike(host): evaluate hybrid hud and qt scene slice

#### T15 候选 E：本地 WebView 完整复刻切片
- Owner: HOST-E · Deps: T10 · Files: Create web/rhine_replica/index.html、web/rhine_replica/renderer.js、web/rhine_replica/three_scene.js、lib/platform/webview_replica.dart、integration_test/slice_webview_test.dart；Modify 无
- [ ] 在本地 WebView 跑命令流 + hits + Three.js 场景，完成同一切片。
- [ ] 验证 IME、a11y、首帧、resize、纹理合成、WebView 版本差异。
- [ ] 记录与 Flutter 输入/媒体会话的边界。
- Pass: 切片全门通过或明确失败。Fail: 只做素材展示、不跑交互。
- Future: flutter test integration_test/slice_webview_test.dart -d 526f6b6d
- Commit: spike(host): evaluate local webview full replica slice

#### T16 架构裁决
- Owner: ARCH · Deps: T11-T15 · Files: Create docs/flutter-migration/adr/0001-host-architecture.md、docs/flutter-migration/02-adjudication.md；Modify 无
- [ ] 只汇总已跑候选的同切片数据；未跑候选标“未评估”，不得填指标。
- [ ] 按功能/画面/协议/输入/状态/稳定/可维护裁决；记录赢家、失败出口、未评估项、停止理由。
- [ ] 若全失败，结论写“未裁决”并停止 P2 页面实现。
- Pass: ADR 能让下一位工程师独立复核。Fail: 预设赢家、用全局 SSIM 代替 ROI。
- Commit: docs: adjudicate qt to flutter host architecture

### P2 壳、桥、领域与数据

#### T20 Flutter 壳与生命周期
- Owner: APP-SHELL · Deps: T16 · Files: Modify lib/main.dart；Create lib/app/bootstrap.dart、lib/app/router.dart、lib/app/lifecycle.dart、test/app/bootstrap_test.dart、integration_test/app_shell_test.dart
- [ ] 建立可运行壳、启动阶段、错误边界、路由；返回键按 Qt 样本与源码补齐，不用 Flutter 路由默认 pop；不含业务假数据。
- [ ] 生命周期只重建 UI，不重建引擎/播放器/Node；旋转/前后台/低内存路径。
- [ ] 注入架构裁决结果与能力矩阵；保留回退入口。
- Pass: flutter test test/app/bootstrap_test.dart 与 integration_test 壳启动通过。Fail: runApp/旋转重建引擎。
- Commit: feat(app): add flutter shell and lifecycle

#### T21 引擎传输与 Node 生命周期
- Owner: BRIDGE · Deps: T20、T16 · Files: Create lib/bridge/engine_transport.dart、lib/bridge/node_runtime.dart、android/app/src/main/kotlin/rhine/music/database/porting/NodeRuntimeHost.kt、test/bridge/engine_transport_test.dart、integration_test/bridge_lifecycle_test.dart；条件 Create android/app/src/main/cpp/CMakeLists.txt（仅 ADR 选择 Flutter 进程内嵌 Node 时）；Modify android/app/build.gradle.kts、android/app/src/main/kotlin/rhine/music/database/MainActivity.kt
- [ ] 实现 resize/pointer/wheel/key/action/query/form 与 commands/hits/frame 传输；按 ADR 选择 Qt 宿主或 Flutter 内嵌。
- [ ] 若选 Flutter 进程内嵌 Node：externalNativeBuild 指向 cpp/CMakeLists.txt，JNI 只封装 node::Start/消息循环；若选 Qt 宿主则本项不适用，仍须保留同一协议。
- [ ] Node 单例、token、48 MiB 上限、30 s 超时、握手前排队、worker 崩溃回传、旋转不重复启动。
- [ ] 协议回放 ios-runtime.cjs/worker.cjs；字段名与 Qt 一致。
- Pass: flutter test test/bridge/engine_transport_test.dart、integration_test/bridge_lifecycle_test.dart 通过。Fail: 造缺协议假 worker 或重复 node::Start。
- Commit: feat(bridge): add engine transport and node lifecycle

#### T22 曲库、目录与搜索领域
- Owner: DOMAIN-LIBRARY · Deps: T21、T05 · Files: Create lib/domain/library/music_library.dart、lib/domain/library/directory_stack.dart、lib/domain/library/search_controller.dart、lib/domain/library/siren_catalog.dart、test/domain/library_test.dart、test/domain/search_generation_test.dart
- [ ] 五 lane、目录栈+游标、Siren 933 首/303 专辑、收藏/MSR、歌单写操作、搜索四种。
- [ ] 搜索防抖、generation、取消、旧响应丢弃、最近搜索白名单。
- [ ] 错误码与 Qt 对齐；不把目录逻辑塞 UI。
- Pass: 两个 test 全过；旧响应不能覆盖新查询。Fail: 搜索无 generation。
- Commit: feat(domain): port music library and search

#### T23 播放、队列与歌词领域
- Owner: DOMAIN-PLAYER · Deps: T21、T05 · Files: Create lib/domain/player/music_player.dart、lib/domain/player/playback_queue.dart、lib/domain/lyrics/lyrics_controller.dart、test/domain/player_queue_test.dart、test/domain/lyrics_test.dart
- [ ] 唯一队列+历史、当前项、模式、恢复、音质/URL/解码、audio focus 接口。
- [ ] 歌词缓存/偏移/来源/同步；面板内播放与详情播放一致。
- [ ] 断点恢复、队列删除/清空语义对齐。
- Pass: 队列不变量/歌词偏移测试全过。Fail: 第二队列或 UI 内解析歌词。
- Commit: feat(domain): port player queue and lyrics

#### T24 账号与凭据领域
- Owner: DOMAIN-ACCOUNT · Deps: T21、T05 · Files: Create lib/domain/account/account_manager.dart、lib/domain/account/login_session.dart、lib/domain/account/credential_store.dart、test/domain/login_state_test.dart、test/domain/credential_test.dart
- [ ] 六路径、六阶段、QR 轮询/超时/800/801/802/803、801 不改 phase 继续轮询、短信 60 s、cancel 屏障、retryAfterMs 墙钟。
- [ ] 凭据安全存储；验证码失败只设 loginStatus、不置 failed；失败不假装登录；登出只清当前来源。
- [ ] 旋转/重入不重复生成、不丢二维码。
- Pass: 登录矩阵测试全过；无 QQ/酷狗 SMS。Fail: LoggedOut 六态模板。
- Commit: feat(domain): port accounts and six login paths

#### T25 系统媒体会话与音频焦点
- Owner: MEDIA · Deps: T23 · Files: Create lib/platform/media_session.dart、android/app/src/main/kotlin/rhine/music/database/porting/MediaSessionHost.kt、android/app/src/main/kotlin/rhine/music/database/porting/MediaPlaybackService.kt、test/media_session_test.dart、integration_test/media_session_test.dart；Modify android/app/src/main/AndroidManifest.xml
- [ ] 锁屏/通知/耳机键/audio focus/暂停恢复；与播放器单向同步，不双写。
- [ ] 前台 Service + 常驻通知 + MediaSession 声明；Android 14/15 前台服务类型与权限按 targetSdk 36 配置。
- [ ] 来电/音频焦点丢失/恢复路径。
- Pass: integration_test 在设备上通过。Fail: 媒体会话状态与播放器不一致。
- Commit: feat(media): add android media session and audio focus

#### T26 存储迁移与会话恢复
- Owner: STORE-IMPL · Deps: T21、T07 · Files: Create lib/data/storage/app_storage.dart、lib/data/storage/session_store.dart、lib/data/storage/playback_store.dart、lib/data/storage/preference_store.dart、test/storage/session_restore_test.dart、test/storage/corruption_test.dart
- [ ] 逐键读/写/迁移/白名单/夹取；modal 仅 saved/search/discover/queue/settings/player/local 七项；原子写；>64 MiB 拒绝保留旧档；playback 兼容。
- [ ] panel QSettings 键、qq/单一 kugou device、运行时路径清单、凭据分支；损坏注入（截断/非法 JSON/权限拒绝）不删数据。
- [ ] 迁移前后差异报告模板。
- Pass: 两个 test 全过；损坏后旧档仍在。Fail: 默认登出或丢收藏。
- Commit: feat(storage): port session playback and preferences

#### T27 更新、诊断与 Consent 服务
- Owner: PLATFORM-SVC · Deps: T20、T06 · Files: Create lib/platform/update_service.dart、lib/diagnostics/diagnostics_service.dart、lib/app/consent_gate.dart、test/platform/update_test.dart、test/app/consent_gate_test.dart
- [ ] 检查/下载/安装意图/失败回退；诊断指标采集；consent 门槛文本与同意持久化。
- [ ] consent 先于业务/数据 SDK 初始化；退出不进入业务。
- [ ] 平台能力开关按矩阵隐藏入口，不删能力。
- Pass: 测试全过；未同意不初始化数据 SDK。Fail: 旧计划式排除更新/诊断。
- Commit: feat(platform): add update diagnostics and consent

### P3 HUD、页面、3D 与横竖屏

#### T30 HUD 渲染器核心
- Owner: HUD-IMPL · Deps: T16、T21、T03 · Files: Create lib/hud/render/hud_painter.dart、lib/hud/render/paint_stack.dart、lib/hud/render/clip_alpha.dart、lib/hud/render/gradient_mask.dart、test/hud/paint_stack_test.dart、test/golden/hud/paint_stack_1920.png
- [ ] 执行 17 op、状态栈、alpha 乘算、clip 相交、rotate 弧度、dash 归一、arc RoundCap、right-mask 16 段、gradient 固定中心。
- [ ] 同帧发布 commands/hits/frame；未知 op 安全丢弃但不静默吞已知 op。
- [ ] golden 固定命令流在 1920×1080 零差异。
- Pass: flutter test test/hud/paint_stack_test.dart 与 golden 通过。Fail: 改参数顺序或去重命令。
- Commit: feat(hud): execute native hud command stack

#### T31 字形与文本引擎
- Owner: HUD-TEXT · Deps: T30、T04 · Files: Create lib/hud/text/glyph_font.dart、lib/hud/text/glyph_run.dart、lib/hud/text/text_fitter.dart、lib/hud/text/fallback_shaper.dart、test/hud/text_fitter_test.dart、test/golden/hud/glyph_run_1920.png
- [ ] 读 misans-glyphs.json 的 advance/path；4 OTF + 符号字体；基线 1.044；tracking；fit 省略号。
- [ ] 缺字/组合/复杂/RTL 才回退；NotoSansSymbols2 符号。
- [ ] calibrated 颜色转换；滚动数字曲线。
- Pass: 字宽/基线/截断/golden 全过。Fail: 普通 Text 全量替代。
- Commit: feat(hud): add glyph text and fallback engine

#### T32 命中、输入、IME 与无障碍
- Owner: HUD-INPUT · Deps: T30、T03 · Files: Create lib/hud/input/hit_layer.dart、lib/hud/input/pointer_router.dart、lib/hud/input/wheel_router.dart、lib/hud/input/key_router.dart、lib/hud/input/text_input_overlay.dart、lib/hud/a11y/semantics_layer.dart、test/hud/hit_layer_test.dart、test/hud/ime_test.dart
- [ ] hits 必需六字段 x/y/width/height/action/label + 仅 PlayerBar 可选 fixed:true、顺序、外扩策略、modalOffset、playerBarInputShield。
- [ ] 指针/滚轮/键盘/查看器捏合；Android 按下即触发/iOS 抬起按源。
- [ ] 真实输入框位置来自 state；selection/composing/focus；语义 label/role 补齐顶部导航。
- Pass: hit/IME/semantics 测试全过。Fail: Widget 自带 hit 与画面脱钩。
- Commit: feat(hud): add hits input ime and semantics

#### T33 Chrome、Archive 与资料库页面
- Owner: PAGE-ARCHIVE · Deps: T30-T32、T22 · Files: Create lib/hud/pages/chrome.dart、lib/hud/pages/archive_page.dart、lib/hud/pages/directory_empty.dart、lib/hud/widgets/track_ruler.dart、test/golden/archive_default_1920.png、test/golden/archive_tabmode_1920.png
- [ ] 品牌/导航/页脚/遮罩；五 lane、目录栈、列游标、Tab Mode、mask、曲目表。
- [ ] 播放全部、返回上一级、open、column-prev/next；空态。
- [ ] 横屏几何按 stage；竖屏复用分段但纵向延伸（T43）。
- Pass: 默认/Tab Mode golden 与命中通过。Fail: 把资料库做成新页面或丢层级。
- Commit: feat(pages): port archive and library surfaces

#### T34 歌曲详情、容器详情与查看器 HUD
- Owner: PAGE-DETAIL · Deps: T30-T32、T22、T41 · Files: Create lib/hud/pages/song_detail.dart、lib/hud/pages/collection_detail.dart、lib/hud/pages/viewer_hud.dart、lib/hud/widgets/action_row.dart、test/golden/song_detail_1920.png、test/golden/collection_detail_1920.png
- [ ] 歌曲档案：3D 封面、DRAG TO INSPECT、动作行、四字段、三 tabs、同专辑 6 行。
- [ ] 歌单/专辑/歌手详情：artist tabs、当前行、收藏态、排序；查看器 opening/closing/reset/清晰/磨砂。
- [ ] 未登录/无同专辑/加载/错误态。
- Pass: golden 与动作/命中全过。Fail: 把 SongDetailCard 当 3D 贴图。
- Commit: feat(pages): port song detail collection detail and viewer

#### T35 搜索弹层与结果
- Owner: PAGE-SEARCH · Deps: T30-T32、T22 · Files: Create lib/hud/modals/search_modal.dart、lib/hud/modals/search_results.dart、test/golden/search_empty_1920.png、test/golden/search_results_1920.png、test/hud/search_modal_test.dart
- [ ] 四标签歌曲/专辑/歌单/歌手；空查询、1-100 字提示、结果/无结果/错误、分组、翻页、滚动条。
- [ ] IME 输入、清除、点结果、请求取消；不把丢字输入当命中。
- Pass: golden 与搜索状态机测试全过。Fail: 只做空态。
- Commit: feat(search): port search modal and result states

#### T36 个人库、收藏与登录面板
- Owner: PAGE-LIBRARY · Deps: T30-T32、T22、T24 · Files: Create lib/hud/modals/library_modal.dart、lib/hud/modals/login_panel.dart、lib/hud/modals/playlist_form.dart、test/golden/login_qr_1920.png、test/golden/library_logged_out_1920.png、test/hud/login_panel_test.dart
- [ ] 未登录登录入口、saved 集合、创建歌单/刷新、表格、写操作。
- [ ] 登录面板 qr/phone/wechat、倒计时、重生成、提交、取消；六阶段 UI。
- [ ] 我的音乐/发现登录后状态按源码规格；无真机帧时标“视觉未取证”。
- Pass: golden/阶段/倒计时测试全过。Fail: 给 QQ/酷狗加 SMS。
- Commit: feat(library): port saved library and login panel

#### T37 设置七区
- Owner: PAGE-SETTINGS · Deps: T30-T32、T06、T27 · Files: Create lib/hud/modals/settings_modal.dart、lib/hud/widgets/settings_row.dart、lib/hud/pages/desktop_lyrics_settings.dart、test/golden/settings_top_1920.png、test/golden/settings_bottom_1920.png、test/hud/settings_sections_test.dart
- [ ] 七区顺序/标题/卡片高度；滚动视口 176..836；展开项、编辑浮层、保存失败。
- [ ] 平台开关、主题/动效/启动动画/Reinitialize/音质、诊断、缓存、更新、项目链接、恢复默认。
- [ ] 桌面歌词仅 mac/win 可见；Android 不显示。
- Pass: 顶/底 golden 与七区测试全过。Fail: 少于七区或删更新/诊断。
- Commit: feat(settings): port seven settings sections

#### T38 发现页面
- Owner: PAGE-DISCOVER · Deps: T30-T32、T22 · Files: Create lib/hud/modals/discover_modal.dart、lib/hud/widgets/discover_card.dart、test/golden/discover_1920.png、test/hud/discover_test.dart
- [ ] 5 列网格、分类、分页、加载/错误/空。
- [ ] 打开卡片、滚动位置、返回恢复。
- Pass: golden 与分页测试全过。Fail: 未登录不可达却伪造数据。
- Commit: feat(discover): port discover grid and states

#### T39 播放栏、队列与歌词面板
- Owner: PAGE-PLAYER · Deps: T30-T32、T23 · Files: Create lib/hud/player/player_bar.dart、lib/hud/modals/queue_modal.dart、lib/hud/modals/lyrics_panel.dart、test/golden/player_idle_1920.png、test/golden/queue_empty_1920.png、test/hud/player_bar_test.dart
- [ ] 无播放/加载/播放/暂停/seek/音量/词/队列；底栏几何与命中。
- [ ] 队列空/多曲/删除/清空/拖动/四种模式；歌词偏移/来源/跟随。
- [ ] 与媒体会话/播放器状态单向同步。
- Pass: golden 与队列/歌词测试全过。Fail: 第二队列或双写。
- Commit: feat(player): port player bar queue and lyrics ui

#### T40 其余弹层
- Owner: PAGE-MODALS · Deps: T30-T32、T06 · Files: Create lib/hud/modals/quality_modal.dart、lib/hud/modals/provider_modal.dart、lib/hud/modals/playlist_picker.dart、lib/hud/modals/confirm_modal.dart、lib/hud/modals/disc_warning_modal.dart、lib/hud/modals/lyrics_offset_modal.dart、lib/hud/modals/detail_sort_modal.dart、test/golden/modals_misc_1920.png、test/hud/modals_misc_test.dart
- [ ] quality/provider/playlist-picker/confirm/disc-warning/lyrics-offset/lyrics-source/detail-sort 的几何、层级、fixed hits、关闭动画。
- [ ] 键盘/返回键/焦点顺序；不合并成通用弹层丢语义。
- Pass: 每个弹层 golden/命中/关闭路径通过。Fail: 缺一个弹层。
- Commit: feat(modals): port remaining native hud modals

#### T41 3D 场景与查看器
- Owner: SCENE-3D · Deps: T30、T16 · Files: Create lib/scene/scene_frame.dart、lib/scene/scene_math.dart、lib/scene/picking.dart、lib/scene/viewer_state.dart、lib/scene/scene_surface.dart、android/app/src/main/kotlin/rhine/music/database/porting/SceneTextureHost.kt、Qt/porting/SceneTextureHost.h、Qt/porting/SceneTextureHost.cpp、test/scene/projection_test.dart、integration_test/scene_slice_test.dart；Modify Qt/porting/CMakeLists.txt
- [ ] 5 lane×40 列、GLB、材质、相机、BVH 拾取、灯光/雾、动画时钟、纹理准入 100 ms。
- [ ] 投影偏移 0.16/0.20、18% 外扩、near5/far300、viewer 34°/0.3..120、竖屏 aspect<1.05。
- [ ] 拖拽/逐格导航/选中卡/相机弹簧；禁止静态背景。
- Pass: 投影矩阵 1e-9、拾取误差≤1 卡、切片 3D 全过。Fail: 静态图或丢纹理准入。
- Commit: feat(scene): port native 3d scene and picking

#### T42 Boot 与 Consent 页面
- Owner: PAGE-BOOT · Deps: T20、T27、T30 · Files: Create lib/ui/pages/boot_page.dart、lib/ui/pages/consent_page.dart、test/golden/boot_1920.png、test/golden/consent_1920.png、test/ui/consent_test.dart
- [ ] 35 s boot、ENTER SYSTEM/skip、35 s 后切 detail；时钟与跳过。
- [ ] Consent 文案/按钮/退出/同意/持久化；同意前不初始化数据 SDK。
- [ ] 与 Qt 门槛行为一致；不伪造“拒绝后继续”。
- Pass: golden 与 consent 状态测试全过。Fail: 同意前进入业务。
- Commit: feat(app): port boot and consent gates

#### T43 竖屏样板与几何
- Owner: LAYOUT-PORTRAIT · Deps: T33-T40、T02 · Files: Create lib/ui/layout/portrait_stage.dart、lib/ui/layout/portrait_bands.dart、test/fixtures/portrait_bands.json、test/ui/portrait_stage_test.dart、test/golden/portrait/home_1080x2400.png、test/golden/portrait/detail_1080x2400.png、test/golden/portrait/settings_1080x2400.png
- [ ] 三档 1080×2400、1440×3200、1200×2000（拟议测试矩阵，不是已证实真机基线）；可用窗口/安全区/IME。
- [ ] 比较 Portrait-W/Band/Hybrid 的可达性、层级、触摸、字尺度；冻结样板，不预设 bottom sheet/48dp/52%。
- [ ] 首页+底栏+详情+搜索+设置+队列+登录各一 golden；全部入口/动作保留。
- Pass: 三档 golden 与动作清单全过。Fail: 隐藏入口、裁切、硬缩。
- Commit: feat(layout): add portrait sample and geometry

#### T44 旋转与状态连续性
- Owner: LAYOUT-STATE · Deps: T43、T39、T41 · Files: Create lib/app/rotation_continuity.dart、test/fixtures/rotation_state.json、test/rotation_continuity_test.dart、integration_test/rotation_test.dart
- [ ] 五 lane/目录栈/游标/item key+相对滚动；输入/selection/focus；modal 仅七项白名单。
- [ ] QR 墙钟+generation+cancel 屏障；队列/播放/歌词偏移；3D 相机/时钟/viewer；拖拽取消恢复。
- [ ] 旋转不重复登录/Node/媒体源；10 次往返无泄漏。
- Pass: fixture 与 integration_test 全过。Fail: 任一项归零/重建。
- Commit: feat(layout): preserve state across rotation

### P4 对照、性能与发布

#### T50 横屏逐页验收
- Owner: QA-LANDSCAPE · Deps: T33-T44 · Files: Create docs/flutter-migration/acceptance/landscape.md、test/fixtures/parity_cases/archive_default.json、test/fixtures/parity_cases/song_detail.json、test/fixtures/parity_cases/search_empty.json、test/fixtures/parity_cases/queue_empty.json、tool/parity/compare.py
- [ ] 页面×状态×动作×方向覆盖表；逐 ROI 人工对照；字形/布局/动作/时序。
- [ ] 未覆盖页（我的音乐/发现/登录后/播放中/Tab Mode/错误态）标“视觉未取证”，另列补采。
- [ ] 任何 SSIM/ΔE 只作辅助；禁止大 mask。
- Pass: 已取证页逐 ROI 通过；未取证页不冒充。Fail: 用全局分数放行。
- Commit: docs: record landscape parity evidence

#### T51 竖屏验收
- Owner: QA-PORTRAIT · Deps: T43、T50 · Files: Create docs/flutter-migration/acceptance/portrait.md、test/golden/portrait/full_suite_1080x2400.png、test/fixtures/parity_cases/portrait_login.json
- [ ] 对照新 golden 与可达性/层级/触摸/字尺度清单。
- [ ] 登录/搜索/设置/队列/查看器/BOOT 全态；IME/安全区。
- [ ] 明确“新增设计，不是 1:1”；未审定项列 WAIT。
- Pass: 样板与全页清单通过。Fail: 宣称竖屏 1:1。
- Commit: docs: record portrait acceptance evidence

#### T52 性能与稳定性基线
- Owner: PERF · Deps: T50、T51 · Files: Create tool/perf/collect_frame_times.dart、tool/perf/README.md、docs/flutter-migration/03-performance.md
- [ ] 采集帧时间分布、首帧、内存、启动、30 min 稳定性；同设备同场景对比 Qt。
- [ ] 指标标“拟议待冻结”；不写固定 60fps/16.6ms/jank 1%/+10%。
- [ ] 静止低 fps 正常；不以删功能换分数。
- Pass: 数据可复核、差异有解释。Fail: 自造阈值当承诺。
- Commit: docs: record performance baseline and stability

#### T53 签名、数据升级与回滚
- Owner: RELEASE · Deps: T52 · Files: Create docs/flutter-migration/release.md、tool/release/verify_signing.sh；Modify android/app/build.gradle.kts
- [ ] 只读核对 keystore/别名/口令保管；沿用 Qt 证书 39396cd06f2b7980302bad220ed071e09286540be4d224a2f9b047ca65205bdf 或走正式迁移，不临时造证书。
- [ ] 旧 Flutter 证书不同，不能覆盖；applicationId 保持 rhine.music.database；versionCode 单调递增（不低于 1）；回滚包用同签名更高 versionCode，不依赖 adb install -d；allowBackup=false 不承诺 adb 私有备份。
- [ ] 回滚/升级演练保留账号/收藏/device/session，不卸载/清数据；签名不可达则停并提供迁移方案。
- Pass: 签名/升级/回滚证据齐全。Fail: 覆盖安装丢账号/收藏。
- Commit: docs: freeze release signing and data upgrade gate

#### T54 最终验收与声明
- Owner: QA-FINAL · Deps: T50-T53 · Files: Create docs/flutter-migration/acceptance/final.md
- [ ] 汇总功能/画面/动作/状态/性能/签名门；逐项标通过/未取证/失败。
- [ ] 未过门不得写“1:1 完成”；未取证页列补采任务。
- [ ] 发布检查：consent、更新、诊断、媒体会话、返回键、存储、账号迁移。
- Pass: 所有硬门有证据。Fail: 用文档替代软件验收。
- Commit: docs: record final parity acceptance

---

## 8. 集成、并行与审查规则

- **单 writer**：每个任务只写 Files 段列出的文件；契约文件、lib/app/router.dart、lib/bridge/engine_transport.dart、lib/hud/render/hud_painter.dart、lib/hud/pages/archive_page.dart 为热点，任何改动必须单 writer 或独立 worktree 完成后由 owner 审后 cherry-pick；同一文件不并写。
- **批次**：用户上限 100 并行/10 递归，实际每批 4-6 个 owner；P0 串行收口，P1 候选可并行（共享 T10 夹具只读），P2 领域可并行，P3 页面按文件隔离并行，P4 串行。
- **依赖**：契约未冻结不实现；切片未裁决不写页面；T43 未审定不铺竖屏；T53 未过不发布。
- **ACK/STOP**：owner 启动向 Lead 发 ACK；派 reviewer 后若 10 分钟无 ACK，STOP 并记录；连续两次寻址失败，改共享控制文件并标“单向”，不得假装双向健康。任何 owner 失联，其写域冻结，由 Lead 重派，不得并写。
- **reviewer**：每个任务恰 1 名独立 ginka/deepseek-v4.1-flash（max 或 high）leaf；只读任务 diff + 全部相关契约/fixture/证据，不递归、不构建/测试/adb、不写文件；输出问题/证据/未决。owner 实收修正后才 commit；reviewer 未返回不得用“看起来没问题”代替。
- **commit**：只标题、不写正文；示例见各任务。禁止 git add .、reset、历史改写、动旧计划或他人文件。
- **冲突**：契约变更由 contract owner 单点改并通知所有依赖任务；页面/领域不得私改契约。跨桥 envelope 变更属架构级，必须 ADR 追加。

---

## 9. 验收门与未来命令

### 9.1 硬门

1. 功能门：全部页面/弹层/动作/状态存在；账号六路径、搜索四种、队列、歌词、设置七区、更新、诊断、consent、返回键、媒体会话、存储迁移均有测试。
2. 画面门：横屏已取证页逐 ROI 人工通过；字形/颜色/层级/3D 材质/雾/相机可辨；未取证页明确标注，不得冒充。
3. 协议门：17 op 参数、hits 必需六字段 + 仅 PlayerBar 可选 fixed:true/顺序、frame 同代次发布、measure/hit/IME 同 geometry；不去重相同命令。
4. 状态门：旋转不重复登录/Node/媒体源；五 lane/游标/滚动/item key/输入/QR/队列/歌词/3D 时钟全连续。
5. 稳定门：切片 30 min 无崩溃/ANR/OOM；性能数据可复核。
6. 发布门：签名不覆盖旧 Flutter 证书；数据升级/回滚不丢账号/收藏；allowBackup=false 不承诺私有备份。

### 9.2 拟议辅助指标（待基线冻结）

SSIM≥0.97、ΔE≤3、像素容差、性能比例均为拟议，必须用 Qt 同设备同场景基线冻结后才可写入验收；它们不能代替逐 ROI/字形/布局/动作/时序人工对照，禁止大 mask。原 Qt 按需绘制，静止低 fps 正常，不得自造 60fps/16.6ms/jank 1%/+10% 承诺。

### 9.3 未来命令（本轮一律不执行）

~~~
flutter --version
flutter pub get
dart analyze
flutter test test/stage_metrics_test.dart
flutter test test/hud_protocol_test.dart
flutter test test/login_matrix_test.dart
flutter test test/settings_sections_test.dart
flutter test test/session_schema_test.dart
flutter test integration_test/slice_platformview_test.dart -d 526f6b6d
flutter test integration_test/slice_texture_test.dart -d 526f6b6d
flutter test integration_test/slice_dart_hud_test.dart -d 526f6b6d
flutter test integration_test/slice_webview_test.dart -d 526f6b6d
flutter build apk --release --target-platform android-arm64
adb -s 526f6b6d install -r output/RhineMusicDatabase-flutter-arm64-v8a-signed.apk
~~~

命令只作未来模板；设备操作、账号登录、截图补采需另行授权。

### 9.4 不能宣称的结论

- 未跑完 T54：不能称“1:1 完成”。
- 未取真机帧：不能称“视觉已对齐”。
- 未做 process-death 对照：不能称“恢复已证”。
- 未做搜索命中：不能称“搜索正确”。
- 未审定竖屏：不能称“竖屏 1:1”。
- 未过签名/数据门：不能称“可升级发布”。

---

### 9.5 计划自审

- [x] 页面/弹层/动作/领域均有任务映射；42 张卡编号连续。
- [x] 每卡有精确 Files、依赖、checkbox、Pass/Fail、Commit；无占位符路径、省略号路径、通配路径或未知包名。
- [x] G1-G8 是证据缺口，不是用户审批门；未取证页不得宣称通过。
- [x] 不预设架构赢家、竖屏形态或性能阈值；候选未跑标“未评估”。
- [x] 本轮只写计划，未执行构建/测试/analyze/adb/设备操作。

---

## 附录 A：代理提示与回收约定

每个任务 owner 派 reviewer 时，提示首行固定引用用户原始激励句（仅作为提示约定，不是产品规范），随后写：只读本任务 diff 与相关契约/fixture/证据；不构建、不测试、不 analyze、不 adb、不递归、不写文件；输出问题/证据/未决；不因“4 文件”限制拒绝读关键契约。owner 收到后逐条实收，P0 未关闭不得 commit。所有后代必须回收并在任务报告写 id/结论/修订；失联按 §8 STOP。

## 附录 B：关键 fixture 与断言示例

### B.1 舞台

~~~
{"physical":[2880,1800],"dpr":1.96875,"logical":[1462.857,914.286],"stageScale":0.846561,"stageWidth":1728}
~~~

断言：stageScale 与 914.286/1080 误差 <1e-6；stageWidth 与 1462.857/0.846561 误差 <1e-6。

### B.2 命令

~~~
[["fill",[0.945,0.941,0.906,1,"calibratedRGB"],0,0,1728,1080],
 ["ellipse",[0.835,0.639,0.282,1],100,200,40,24],
 ["text","全部歌曲",59,115.425,44,"bold",0,[0.08,0.085,0.075,1,"calibratedRGB"]],
 ["path","icon-arrow",2,[0.13,0.16,0.14,1],[4,2],0],
 ["arc",120,240,36,0,1.5708,2,[0.13,0.16,0.14,1]]]
~~~

断言：fill 颜色取 a[1]、矩形取 a[2..5]；ellipse 是左上矩形；text 基线 y+size*1.044；path dash/offset 除以 penWidth；arc 使用弧度与 RoundCap。

### B.3 登录

~~~
{"provider":"qq","method":"wechat","phase":"waiting","generation":7,"pollCount":12,"pollIntervalMs":1000,"retryAfterMs":0}
~~~

断言：取消后 generation 变为 8、phase=idle；pollCount 到 300 进入 failed；code 801→继续 waiting、802→confirming、803→confirmLogin、800→failed/QQ reportLoginFailure；QQ/酷狗发送短信必须失败。

### B.4 会话

~~~
{"version":1,"view":{"mode":"archive","selected":17,"tab":"overview","modal":"search","queueOffset":0,"settingsScroll":0,"query":"","groupBy":"none","activeGroup":"","artistTab":"songs","listOffset":0,"trackOffset":0,"bodyOffset":0,"musicCollection":1,"trackListMode":false,"lyricsMode":false}}
~~~

断言：只恢复白名单字段；非法/越界值夹取；>64 MiB 文件不覆盖旧档。

### B.5 命中

~~~
{"x":939,"y":118,"width":54,"height":54,"action":"settings","label":"设置"}
~~~

~~~
{"x":0,"y":0,"width":44,"height":48,"action":"player:prev","label":"上一首","fixed":true}
~~~

断言：基础字段为 x/y/width/height/action/label；仅 PlayerBar hit 允许额外 fixed:true（PlayerBar.cpp:46-53），其余 hit 不得带 fixed；第二条只验证字段形状，不代表页面坐标；消费顺序按源生成顺序；不按 z 排序；外扩只发生在触摸层。

---

**计划结束。** 本文件只定义迁移计划与未来验收；不包含产品实现，不代表任何页面已迁移或已验收。
