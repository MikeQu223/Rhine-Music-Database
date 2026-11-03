# Rhine Music Panel 渲染层架构

> 基线：当前工作区（`c4a3e77` 之后，含 Apple 默认窗口 MetalFX 补帧、设置页帧生成开关与性能面板统计）。
> 本文按“共同场景渲染器 + 各平台宿主”梳理当前实际运行的每条管线；Metal 只是其中一条平台路径，
> 但会写清它从窗口到屏幕的完整链路。

## 0. 先看结论

### 0.1 当前实际存在的管线

| 管线 | 宿主 | 图形后端 | 场景后处理 | 帧生成 | 最终上屏 | 高 DPI |
| --- | --- | --- | --- | --- | --- | --- |
| Apple（macOS / iOS）默认窗口 | `Main.qml` / `QQuickWindow` | Metal | MetalFX 时域（可选） | `MetalFramePresentation`（`panel/fg` 或 `RHINE_FG=on`） | Qt Quick 场景图 → `CAMetalLayer` | Qt Quick 内部按物理像素 |
| Windows | `PresentationShell` | Vulkan | `ScenePostProcess`（FXAA/TAA/FSR） | `FgBackend`（仅 `RHINE_FG=on`） | `VulkanPresenter` 自持交换链 | 逻辑尺寸 + target DPR |
| Linux（显式开 FG） | `PresentationShell` | Vulkan | `ScenePostProcess`（FXAA/TAA/FSR） | `FgBackend`（仅 `RHINE_FG=on`） | `VulkanPresenter` 自持交换链 | 物理像素离屏层 + 根条目缩放 |
| Windows/Linux 默认窗口 | `Main.qml` / `QQuickWindow` | Vulkan 或 OpenGL | `ScenePostProcess`（FXAA/TAA/FSR） | 无（FG 只存在于呈现层） | Qt Quick 交换链 | Qt Quick 内部按物理像素 |

D3D12 代码仍在，但 `RHINE_ENABLE_D3D12_BACKEND` 当前构建为 OFF；OpenGL 后端没有呈现层支持，
因此也不进入帧生成。

### 0.2 共同点与差异

- **只有一个引擎和一个场景渲染器**：`Engine` 生成场景/HUD 快照，`RhiScene` 内的
  `RhineRendering::Renderer` 负责烘焙材质、唱片、深度/运动矢量和最终合成。所有管线共用它。
- **差异只在“谁拥有窗口、谁做最终合成与上屏”**：
  - 默认窗口：`QQuickWindow` 的 Qt Quick 场景图合成 `Scene3D.qml` 与 `Overlay.qml`，Qt 拥有交换链。
  - 受控呈现层：应用自己创建 `QWindow` + `QRhi`，用两个 `QQuickRenderControl` 分别渲染 3D/UI，
    `PresentationShell` 合成后由呈现后端上屏。
- **运动矢量的产出方式按后端分**：
  - Linux 与 Apple：颜色 pass 的第二颜色附件（单趟 MRT），实例带 `previousModel`；
  - Windows：独立的 `MotionPass`（D32F + RG16F/RGBA16F），实例不带 `previousModel`。
- **UI 永远不参与插值**：两种宿主都只对 3D 层做 FG；UI 在合成阶段按显示帧率叠加。
- **后处理二选一**：Apple 用 MetalFX（时域超分/MetalFX Temporal）；其他平台用 `ScenePostProcess`
  （FXAA/TAA/FSR），不会同时运行。

### 0.3 启动分流

```text
main.cpp
  │
  ├─ selectGraphicsBackend()
  │    macOS/iOS → Metal
  │    Windows/Linux → Vulkan（可用时）或 OpenGL
  │
  ├─ 读取偏好/环境变量（vsync、render-scale、aa-mode、fg…）
  │
  ├─ fgCandidate?
  │    Apple（macOS/iOS）→ 否（默认 QQuickWindow，MetalFX 在窗口内完成）
  │    Windows→ 是（原生窗口 + Vulkan 呈现层；RHINE_FG_LAYER=off 可强制默认）
  │    Linux  → 仅 RHINE_FG=on 或 RHINE_FG_LAYER=on 时是
  │
  ├─ 是 → PresentationShell::start()
  │        ├─ 自建 QWindow + QRhi + 交换链
  │        ├─ SceneLayerHost：Scene3D.qml / Overlay.qml 两个离屏层
  │        ├─ FrameGenerator（Vulkan FgBackend，Windows/Linux）
  │        ├─ fgComposite 合成 3D（真实/插值）与 UI
  │        └─ PresentationBackend 上屏
  │
  └─ 否/启动失败 → QQmlApplicationEngine::load(Main.qml)
           └─ QQuickWindow
                ├─ Scene3D.qml → RhiScene
                └─ Overlay.qml → Hud/输入层/性能面板
```

## 1. 启动与选择

### 1.1 图形后端

`Qt/src/main.cpp` 在任何 `QQuickWindow` 创建前完成选择：

| 平台 | 选择规则 | 回退 |
| --- | --- | --- |
| macOS / iOS | Metal；`RHINE_GRAPHICS` 只接受 `metal`/`auto`，其他值会告警并忽略 | 无（Qt 平台只提供 Metal） |
| Windows | `QSG_RHI_BACKEND` / `RHINE_GRAPHICS` / 保存的 `panel/graphics-backend`；默认探测 Vulkan，失败则 OpenGL | OpenGL |
| Linux | 同上；默认探测 Vulkan，失败则 OpenGL；选卡结果在启动前落成厂商环境变量 | OpenGL |

D3D12 只在 `RHINE_ENABLE_D3D12_BACKEND` 打开时参与 Windows 选择；当前构建关闭。

### 1.2 偏好与环境变量

`applyVSyncSetting()`、`applySupersampleSetting()`、`applyRenderScaleSetting()`、
`applyAntialiasingSetting()`、`applyFrameGenerationSetting()` 在窗口创建前把持久化偏好转成环境变量：

| 设置 | 偏好键 | 环境变量 | 生效方式 |
| --- | --- | --- | --- |
| 图形后端 | `graphics-backend` | `RHINE_GRAPHICS` / `QSG_RHI_BACKEND` | 仅启动 |
| 垂直同步 | `vsync` | `RHINE_VSYNC`；呈现层 `RHINE_FG_VSYNC` | 仅启动 |
| 超采样 | `supersample` | `RHINE_SUPERSAMPLE` | 下一帧重建目标 |
| 渲染倍率 | `render-scale` | `RHINE_RENDER_SCALE` | 下一帧重建目标 |
| 抗锯齿 | `aa-mode` | `RHINE_AA_MODE` | 每帧读取 |
| MSAA | `msaa` | `RHINE_MSAA` | 下一帧重建目标 |
| FSR 档位/锐化 | `fsr-quality` / `fsr-sharpness` | `RHINE_FSR_QUALITY` / `RHINE_FSR_SHARPNESS` | 下一帧 |
| 帧生成 | `fg` | `RHINE_FG` | Apple 由设置页/偏好驱动，显式环境变量优先；Windows/Linux 仍以环境变量为排障入口 |

`RHINE_FG_LAYER` 不是帧生成开关，而是“是否允许呈现层接管”的排障开关：`on` 在 Linux 强制接管，
`off` 在 Windows/Linux 强制默认路径；Apple 上已无效果。

### 1.3 呈现层门控

`fgCandidate` 的当前条件（`main.cpp`）：

| 平台 | 条件 |
| --- | --- |
| Apple（macOS/iOS） | 固定 false：默认窗口内完成 MetalFX 补帧，不接管窗口 |
| Windows | `!test && !--capture && !RHINE_FG_LAYER=off && 原生窗口系统 && supportsBackend(Vulkan)` |
| Linux | 在 Windows 条件上再加 `(RHINE_FG=on || RHINE_FG_LAYER=on)` |

`supportsBackend()` 只认 Metal 和 Vulkan；OpenGL/D3D12 不走呈现层，也就没有 FG。

### 1.4 默认窗口与回退

- 默认路径：`engine.loadFromModule("RhineMusic", "Main")`，随后 `window->setGraphicsConfiguration()`
  开启时间戳查询、设置管线缓存（Windows），并注册 `sceneGraphInvalidated` 资源账本。
- 受控路径：`PresentationShell::start()` 失败（交换链、离屏 QML、FG 上下文或自检失败）时回退默认窗口，
  并把原因写入 `RhineFg::publishInactive()`；合成仍可继续，只是没有插值。
- 旧 iOS 呈现层的 `PresentationStartupProbe` 仍保留，但 Apple 默认窗口路径不再启动它。

## 2. 共同层：Engine → RhiScene

### 2.1 输入帧协议与同步缓存

`ItemRenderer::synchronize()` 从 `Engine` 取：

- `Engine::frame()`：QJsonObject，含 `projection`/`view`/`aoProjection`、`draws`、`background`、
  `mode`、`viewer`、`jitter`、`temporalReset`、`discAngle`、`batchDraws`、`fogNear`/`fogFar` 等；
- `Engine::drawBuffers()`：实例矩阵、主题值、实例 id；
- `Engine::current()` / `cover()` / `musicTextures()`：当前曲目、封面和仍在归位的旧唱片；
- `RhiScene::lightingEnabled()`、`Engine::geometryRevision()`、`Engine::sceneRevision()`。

`SceneSyncCache.h` 的 `SceneSyncSignature{revision, geometryRevision, lighting}` 不变时复用上一份
`frame`/`buffers`/`item`/`cover`，避免 HUD 变化时重复复制整份场景 JSON。`noteSceneConsumed()` 只写
原子序号，再经队列回主线程给 `FramePacingPolicy` 对账。

### 2.2 尺寸与目标

`Renderer::resize()` 按当前平台计算：

```text
非 Apple：renderSize = ScenePostProcess::renderSize(displaySize)   // 含 FSR 档位
Apple   ：renderSize = displaySize × supersample × renderPercent / 100

displaySize = 当前渲染目标的物理像素
```

`Settings::renderSize()` 的倍率是 `supersample(1–2) × renderPercent(50–100)`；Apple 的
MetalFX 时域和补帧都要求 `supersample × renderPercent ≤ 100`（即不能超采样）。

| 目标 | 尺寸 | 格式 | 用途 |
| --- | --- | --- | --- |
| `color` | render | RGBA16F；MSAA 时多重采样 + resolve | 唯一场景颜色 |
| `depth` | render | D32F，与 color 同采样数 | 深度测试、时域/插帧输入 |
| `motionVectors`（Linux/Apple） | render | RGBA16F，单采样 | 颜色 pass 第二附件，MRT 写速度 |
| `target` | display | RGBA8 | 仅离线 `renderReference()` 的读回目标 |
| `ScenePostProcess::m_input` | render | FSR 时 RGBA16F，否则 RGBA8 | 非 Apple 后处理输入 |
| `ScenePostProcess::m_output` | display | RGBA16F | FSR 升采样输出 |
| `ScenePostProcess::m_history[2]` | render | RGBA16F | TAA 历史双缓冲 |
| `MotionPass`（Windows） | render | D32F + RGBA16F | 独立深度/运动矢量 pass |
| MetalFX 时域输出 | display | RGBA16F | 时域超分结果 |
| `MetalFramePresentation::realColor` | display | RGBA8 | Apple 补帧的真实帧快照 |
| 呈现层 3D/UI 纹理 | display | RGBA8 | `SceneLayerHost` 的两层输出 |
| 交换链图像 | display | 平台格式 | 最终上屏 |

重建条件：`viewSize`、`renderSize`、采样数、AA 模式、是否分配运动矢量、深度 store 策略任一变化。
Linux 重建目标时还会清空上一帧 VP/实例历史；Apple 重建时清空 `metalHistory`。

### 2.3 场景资源与材质

构造时加载：

- 几何：`archive-cassette.bin` / `archive-assembly.bin` 及索引/部件表；
- 表面图集：`archive-baked-surface.bin`（1024²，完整 mip；可用时优先 `archive-baked-surface-bc7.bin`）；
- 光场：`archive-baked-light.bin`（576×96×24 RGBA8 三维纹理，硬件三线性）；
- 法线响应：`archive-baked-normal.bin`（128×256 RGBA16F）；
- 程序化贴图：盒体装饰高/低两档、封套前后文字、占位封面；
- 唱片网格：`DiscGeometry` 生成盘面、盘体、中心环。

表面/光场均以 sRGB8 存储线性辐亮度/4，着色器手工解码后乘回 4；法线响应保留 RGBA16F。
烘焙脚本为 `scripts/bake-archive-lighting.py`，构建期生成到 `output/resources/`。

材质统一走 `opticalSurface.frag`。`Surface` 结构固定 128 字节：

```text
color, physical（roughness/metalness/transmission/thickness）,
optics（ior/attenuationDistance/Index_Inlay/sharpCover）,
attenuation, extra（clearcoat/clearcoatRoughness/disc cos/sin）,
flags（材质类型/side/subdued/floor）, darkColor, emission
```

| type | 含义 |
| --- | --- |
| 0 | 默认/实例化材质 |
| 1 | 曲目标签/文字平面 |
| 2 | 非实例化几何（主角/调试着色） |
| 3 | `Frosted_Polymer` / `Optical_Film` |
| 4 | `Ivory_Edges` |
| 5 | `Optical_Diffuser` |
| 6 | 唱片盘面 |
| 7 | 盒体装饰文字/铭牌 |
| 8 | 唱片盘体/中心环 |
| 9 | 光学薄膜/玻璃 |

全局 UBO `Globals`：**Linux/Apple 832 字节，Windows 704 字节**；`Instance`：**Linux/Apple 144 字节，
Windows 80 字节**。差值来自 `previousModel`（Linux/Apple 单趟 MRT 需要）。顶点 32 字节
（位置、法线、UV）。关闭运动矢量后，Apple 还会使用 80 字节紧凑实例。

### 2.4 绘制列表与批次

`musicDraws()`：

- 剔除 `Internal_Ceramic`、`Amber_Optical_Inlay`、`Champagne_Index`、`Printed_Label` 等穿帮部件；
- `Optical_Film*` / `Optical_Glass*` 走透明队列、关闭深度写入；
- 壳体改为烘焙外观：`transmission=0`，未选中的实例化壳体单面剔除，选中 `Frosted_Polymer`
  透明（资料库 0.62、详情 0.20、查看器 0.14），并按 selected 状态补出盘面、银色盘体、中心环、
  封套标记。

`prepare()` 复用 `MaterialSlotKey{id, mesh, name}`；不透明批次按几何/材质键合并，透明物体保持
`order` 排序；`geometry()` 先按管线状态分组再提交。

常用优化（按后端生效）：

| 策略 | 默认 | 作用 |
| --- | --- | --- |
| 实例池 `RHINE_VK_INSTANCE_ARENA` | 开 | Vulkan/Metal 共用一张 Dynamic VertexBuffer，按偏移切片 |
| 材质 UBO arena `RHINE_VK_UNIFORM_ARENA` | 关 | 材质槽 + 动态偏移，复用 SRB（Vulkan 实验） |
| 直接写 arena `RHINE_VK_DIRECT_WRITE` | 关 | `beginFullDynamicBufferUpdateForCurrentFrame()` 整块直写 |
| 布局复用 `RHINE_VK_LAYOUT_ONLY_PIPELINES` | 关 | arena 换 buffer 不重建 pipeline |
| 紧凑实例 `RHINE_VK_COMPACT_INSTANCES` | Apple 自动、其他关 | 无运动矢量消费者时用 80 字节实例 |
| 深度不保留 `RHINE_VK_DISCARD_UNUSED_DEPTH` | 关 | 无消费者时 `DoNotStore` 深度 |

### 2.5 Pass 顺序

```text
resize / ScenePostProcess::prepare（非 Apple）
  → 材质与实例准备（绑定缓存 + 合批 + 池化）
  → 颜色 pass：清背景 → 不透明 → 透明
       Linux/Apple：同一 pass 的第二颜色附件写运动矢量（MRT）
       Windows：颜色 pass 不写运动，之后再跑 MotionPass
  → finalFragment：ACES、九点柔化、纸张/暗角背景
  → AA / 超分 / MetalFX
  → 目标纹理（默认窗口 / 离屏层 / 读回目标）
  → FG（如果有）→ 最终上屏
```

- 没有独立的阴影、法线、AO、景深或玻璃抓屏 pass；这些由烘焙图集和材质着色器承担。
- Linux/Apple 的 MRT 变体由 `RHINE_SINGLE_PASS_MOTION` 烘焙；Apple 另加 `RHINE_METAL_MOTION`，
  `opticalGeometry.vert` 读 `previousModel0..3`，`opticalSurface.frag` 在 location 1 写速度。
- Windows 的 `MotionPass` 使用独立 D32F/RGBA16F 目标，按实例 id/平移列配对上一帧矩阵；
  相机/实例都静止时跳过静态 draw 的栅格化。
- Linux 另有 `RHINE_WARP_PROBE=1` 的重投影探针，只用于肉眼判断拉丝/残影，不是生产插值路径。

### 2.6 最终合成与平台分支

| 平台 / 模式 | 最终合成目标 | 后续 |
| --- | --- | --- |
| 非 Apple，`fxaa` / `taa` / `fsr` | `ScenePostProcess::inputTarget()` | `ScenePostProcess::resolve()` → 目标 |
| 非 Apple，`off` / `ssaa` / `msaa` | 目标 | 无 |
| Apple，`metalfx` | MetalFX 结果 → 目标 | 无 |
| Apple，`off` | 目标 | 无 |

`finalFragment` 始终执行 ACES、九点二项核柔化（中心 4、轴向 2、对角 1，总权重 16）和纸张/暗角背景；
它不采样旧版场景、AO 或景深。

### 2.7 发布给帧生成的输入

- macOS/iOS：`publishMotionInputs()` 写入 `Engine::metalFxInputs`（渲染线程与 GUI 线程共享的快照），
  由默认窗口的 `MetalFramePresentation` 读取；
- Linux/Windows：写入进程级 `RhineFg::FrameInputs`，由呈现层读取；
- `serial` 每发布一次 +1，呈现层据此判断输入是否新鲜，避免对同一场景重复插值。

### 2.8 封面与标签生命周期

- 标签纹理按曲目 key + 标题/歌手/类型/id revision 缓存；封面纹理按 `QImage::cacheKey()` 去重。
- 封面/标签上限 32 个 key、64 MiB；封面最大 1024²，带完整 mip 链。
- 封面合成与 mip 生成在工作线程 `CoverPrepareTask` 中完成：默认同时 4 个在途、最多 16 条成品排队、
  每帧上传预算 8 MiB（`RHINE_TEXTURE_UPLOAD_BUDGET_MB`）。预处理失败改走同步路径。
- 冷纹理准入 `MusicTextureAdmission`：焦点 key 稳定 100ms（`RHINE_TEXTURE_ADMISSION_MS`）后才创建
  标签/封面纹理；快速滚动时不给每个路过条目建 GPU 资源。
- `renderReference()` 强制同步封面，保证离线截图与实时路径一致。

## 3. 管线 A：Apple 默认 QQuickWindow（macOS / iOS，Metal）

macOS 与 iOS 共用这一条管线：同一个 Engine/RhiScene/MetalFramePresentation、同样的 MetalFX 时域与
补帧、同样的 Qt Quick 合成；差异只在平台窗口、资源目录、输入/无障碍等 UI 层。`PresentationShell`
在 Apple 平台上不会被选择，但代码保留。

### 3.1 链路

```text
Engine::frame()/drawBuffers()
  → ItemRenderer::synchronize()（SceneSyncCache）
  → Renderer::render()
      → 材质/实例准备
      → color pass（RGBA16F + D32F，MRT 写运动矢量）
      → composite:
          metalfx? → MetalFxTemporal::resolve()（或 RHINE_METAL_TEMPORAL=light）
          → finalFragment（ACES/柔化/纸张）
          → MetalFramePresentation::realTarget()（display RGBA8）
      → publishMotionInputs() → Engine::metalFxInputs
      → MetalFramePresentation::generate()（MetalFX FrameInterpolator）
      → present()/presentAsync()：中间帧先上屏，真实帧下一步上屏
  → QQuickRhiItem 目标纹理
  → Qt Quick 场景图合成 Scene3D + Overlay（HUD 不插值）
  → CAMetalLayer 交换链，按显示刷新率 present
```

### 3.2 尺寸与 AA

- `displaySize` = `QQuickRhiItem` 目标的物理像素；`renderSize` = display × superSample × renderPercent。
- AA 选项只有 `off` / `metalfx`（`Settings::temporal()` 还要求设备支持且倍率 ≤100%）。
  MetalFX 用渲染分辨率颜色/深度/像素单位运动矢量 + Halton 抖动输出显示分辨率。
- 设备不支持时 `implementation="metalfx-unavailable"`，画面退回 `off`，不中断渲染。
- 没有 FXAA/SSAA/MSAA/TAA/FSR 选项；这些由非 Apple 的 `ScenePostProcess` 承担。
- 普通窗口的 vsync 由启动时写入的 `QSurfaceFormat` swapInterval 控制：`metalVSyncEnabled()` 默认 true（1），
  `RHINE_VSYNC`/`RHINE_FG_VSYNC` 可关到 0；Qt Quick 的 `CAMetalLayer` 跟随该设置，默认按显示刷新率 present。

### 3.3 帧生成（默认窗口）

`MetalFramePresentation`（`Qt/src/render/MetalFramePresentation.h`）在 `RhiScene` 的窗口帧内运行：

1. `synchronize()` 无条件探测 MetalFX 插帧能力（`createMetalFxFrameGenerator`），并把
   `RhineFg::capability` 转交 GUI 线程，供设置页判断开关是否可点。
2. 每个窗口 vsync 只渲染一次；真实帧按“每两帧一次”写入私有 `realColor`（RGBA8，display 尺寸），
   其余帧只做上屏拷贝。`update()` 在动画期间每个 vsync 主动续帧，保证 Qt Quick 不因引擎
   85–95Hz 的内容更新而退回低频。
3. 真实帧调用 `MetalFxFrameGenerator::generate()`：`prepare()`/`dispatch()` 在
   `beginExternal()/endExternal()` 之间执行；`resize()` 在 pass 结束后创建/延迟销毁资源，不等待设备空闲。
4. 时序固定为“中间帧 I(n−1,n) → 真实帧 R(n) → 中间帧 I(n,n+1) → …”；本帧先拷贝中间帧，
   下一帧拷贝同一对的真实帧，避免时间顺序倒退。
5. 上屏通过 `present.vert/frag` 的全屏三角把源纹理拷到 `QQuickRhiItem` 目标；Qt Quick 再叠加 HUD。
6. 默认同步模式；`RHINE_METAL_FG_ASYNC=on` 可把插值放到后台命令队列（5 个快照槽、独立
   `MTLCommandQueue`，只在窗口 GPU 完成后消费）。

实测与目标：

- 120Hz 显示上稳定 60 张真实帧 + 60 张插值帧，呈现约 120 FPS；
- 帧间隔目标 8.33ms；同步模式在 2560×1440、70% 内部渲染 + MetalFX 时域下实测 p50 8.30ms、p95 9.2ms；
- 分帧按窗口 vsync 奇偶，因此 144Hz 屏上是 72+72，60Hz 屏上是 30+30；当前没有单独的 60Hz 门控。
- 同步模式给 3D 内容增加约一个 vsync 的延迟；HUD 不参与插值。

### 3.4 设置与性能面板

- 设置页的“帧生成”行只在 Apple 平台可见（`SettingsSchema::fgVisible`）；偏好键 `panel/fg`，
  默认关闭。开启/关闭写入偏好并立即更新 `RenderConfiguration`，不需要重启。
- `RhineFg::capability` 由渲染线程经 `Engine::publishFrameGenerationCapability()` 转交 GUI 线程；
  MetalFX 不可用时行置灰并显示原因。`RHINE_FG` 排障环境变量优先，并会让开关标签跟随实际状态。
- 性能面板沿用原有 FG 区块：默认窗口下显示
  “帧生成 默认窗口 · 插值 开 / 呈现 / 渲染 120 / 60 FPS · 插值 60 FPS / 输入 / 显示 …”；
  关闭时显示“帧生成 未接管 · 未开启”。统计由 `Engine::publishFrameGenerationStats()` 每 250ms
  从渲染线程转交 GUI 线程。

### 3.5 关闭与回退

`RHINE_FG`/偏好关闭、MetalFX 不可用、输入纹理不满足要求或尺寸/配置变化时，`MetalFramePresentation`
挂起并释放插值上下文；`RhiScene` 直接渲染到 `QQuickRhiItem` 目标，画面与未开补帧时一致。
`RHINE_METAL_FG_SCALE` 控制插值工作分辨率（默认 100%），`RHINE_METAL_FG_LINK_SCALER=on` 才启用
与 MetalFX 时域 scaler 的链接（默认关，避免不同系统版本的输入尺寸约束）。

## 4. Apple 平台差异与遗留的 PresentationShell

- iOS 与 macOS 共用第 3 节的默认窗口管线：同一个 `RhiScene`、MetalFX 时域、`MetalFramePresentation`
  和 Qt Quick 合成；`main.cpp` 的 `fgCandidate` 对 `Q_OS_DARWIN` 固定 false，iOS 不再启动呈现层。
- iOS 的差异只在窗口/资源/输入层：`configureIOSWindow`、资源目录 `RhineAssets`、`IOSInput.qml`、
  安全区与方向；这些不改变渲染 pass、尺寸或 FG 时序。
- 高 DPI 由 Qt Quick 处理，与 macOS 相同；第 3 节的尺寸、AA、FG、设置页和性能面板逻辑对 iOS 同样生效。
- `PresentationShell`、`SceneLayerHost`、`RhiPresentationBackend` 和 iOS 启动探针代码仍然保留，
  供 Windows/Linux 使用或排障；不要为 Apple Metal 补帧再修改或启动它们。

## 5. 管线 C：Windows（Vulkan 受控 / Qt 默认）

### 5.1 受控路径（默认情况下）

- `fgCandidate`：原生窗口 + Vulkan 可用 + 未设置 `RHINE_FG_LAYER=off`；测试/截图模式不接管。
- `VulkanPresentationBackend` + `VulkanPresenter`：应用自持 `VkSwapchainKHR`；vsync 开时 FIFO，
  关时优先 MAILBOX、否则 IMMEDIATE；非 FIFO 增加交换链图像；可选 deferred present。
- `SceneLayerHost`：逻辑尺寸 + target DPR；两层 RGBA8；根条目缩放 1.0。
- 场景渲染器与 Apple 的 `RhiScene` 相同，但 Windows 走独立 `MotionPass`，实例不带 `previousModel`。
- 帧生成：`FgBackend`（FFX Optical Flow + Frame Interpolation）。`RHINE_FG` 在 Windows 默认被
  `main.cpp` 固定为 off；只有显式 `RHINE_FG=on` 才插值。设置页不显示该行。
- `RHINE_FG_LAYER=off` 可强制默认 Qt 窗口；`on` 不是 Windows 的额外条件（默认已允许接管），
  也不会改变 `RHINE_FG` 的插值请求。
- 启动自检：3 秒内至少上屏 20 帧、`OutOfDate ≤ 200`；连续 5 次重建仍无新帧则回退默认窗口。

### 5.2 默认 Qt Quick 路径

- 触发条件：OpenGL 后端、`RHINE_FG_LAYER=off`，或呈现层启动失败。
- `QQuickWindow` 的 Qt Quick 场景图直接合成 `Scene3D.qml` 与 `Overlay.qml`；
  `RhiScene` 走 `ScenePostProcess`（FXAA/TAA/FSR）与 `MotionPass`；没有 FG。
- 高 DPI、焦点、输入法、窗口装饰均由 Qt Quick 负责。

## 6. 管线 D：Linux（Vulkan 受控 / Qt 默认）

### 6.1 受控路径（显式开 FG）

- `fgCandidate`：原生窗口 + Vulkan 可用 + `(RHINE_FG=on || RHINE_FG_LAYER=on)`；否则默认 Qt 路径。
- `VulkanPresentationBackend` + `VulkanPresenter`：自持交换链；vsync 关闭时优先 MAILBOX，
  其次 IMMEDIATE；非 FIFO 申请更多图像；`presentDeferred` 可把 present 推迟到下一次 acquire；
  `RHINE_FG_PRESENT_SYNC=idle` 是退回设备空闲等待的排障通道。
- `SceneLayerHost`：物理像素离屏层（`pixelSize()`），根条目按 `m_ratio` 缩放；两层 RGBA8。
- 场景渲染器：Linux 走单趟 MRT（`RHINE_SINGLE_PASS_MOTION`），实例带 `previousModel`；
  `publishMotionInputs()` 直接发布深度/运动矢量。
- 帧生成：`FgBackend`；`RHINE_FG=on` 时插值，`RHINE_FG_LAYER=on` 单独使用时只接管窗口做 A/B，
  不插值。`RHINE_FG_LAYER=off` 强制默认路径。
- 实测：呈现层接管且不插值时内容帧率低于 Qt 默认路径约 35%，所以默认不接管；
  只有显式 FG 才付出这份成本。
- 启动自检与回退同 Windows。

### 6.2 默认 Qt Quick 路径

- 触发条件：未开 FG、OpenGL 后端，或呈现层失败。
- `QQuickWindow` + `RhiScene`：Vulkan 走 MRT 运动矢量与 `ScenePostProcess`；OpenGL 回退到
  `surfaceNoMrt` 兼容管线，时域/运动相关模式受后端能力限制。
- 没有 FG；内容帧率通常高于呈现层接管模式。

## 7. 抗锯齿、超分与 MetalFX

### 7.1 模式对照

| 模式 | 平台 | 实现 | 渲染尺寸 | 时域 | 输入 |
| --- | --- | --- | --- | --- | --- |
| `off` | 全部 | 直接最终合成 | 全局倍率 | 否 | 颜色 |
| `fxaa` | 非 Apple | `aaFragment.frag` | 全局倍率 | 否 | 颜色 |
| `ssaa` | 非 Apple | 放大渲染尺寸，最终合成缩回 | × `AA_SCALE` | 否 | 颜色 |
| `msaa` | 非 Apple | 多重采样颜色/深度 + resolve | 全局倍率 | 否 | 颜色、深度 |
| `taa` | 非 Apple | `taa.frag` + 历史双缓冲 | 全局倍率 | 是 | 颜色、深度、速度、历史 |
| `fsr` | 非 Apple | FSR3 计算（可选）；否则 FSR1 EASU+RCAS | ÷ FSR 档位 | 仅 FSR3 计算 | 颜色；FSR3 另需深度、速度 |
| `metalfx` | Apple | `MTLFXTemporalScaler` | 全局倍率（≤100%） | 是 | 颜色、深度、速度 |

### 7.2 关键流程

- **off**：`finalFragment` 直接采样 `color` 写目标；`renderPercent < 100` 时同时做双线性放大。
- **fxaa**：`finalFragment` 写 `m_input`（RGBA8），`aaFragment` 边缘检测/方向混合后输出。
- **ssaa**：只提高几何渲染尺寸；`sampleCount` 仍为 1，最终按目标视口缩回。
- **msaa**：`color`/`depth` 用设备支持且不超过 `RHINE_MSAA` 的最大采样数；`color` 额外带
  单采样 resolve，后续只读 resolve 结果。
- **taa**：`Engine` 以 Halton(2,3) 8 相位推进 `jitter`；`RhiScene` 把抖动应用进投影，
  运动矢量用未抖动 VP 计算。`taa.frag` 按速度重投影历史、3×3 邻域夹紧、0.9 历史权重混合。
- **fsr**：内部尺寸除以档位；`finalFragment` 写 RGBA16F `m_input`；FSR3 计算路径只在
  `Fsr3Backend` 可用且 `RHINE_FSR3_FFX=1` 时创建，输出显示分辨率；否则 FSR1 EASU+RCAS。
- **metalfx**：`MetalFxTemporal::resolve()` 用渲染分辨率颜色/深度、像素单位运动和 Halton 抖动
  输出显示分辨率；失败时 `implementation="metalfx-unavailable"`，退回 `off`。

### 7.3 抖动、历史与重置

- 抖动只服务时域方案：`taa`、可用的 FSR3 计算路径、Apple `metalfx`；FSR1 和空间方案不推进。
- `Engine::step()` 在时域模式下把 `m_temporalFramesRemaining` 置 8；画面变化后的 8 帧强制标记
  “有变化”，让历史继续累积。
- `resetTemporalState()`（场景切换、相机跳变、尺寸变化等）清空抖动相位、请求 FSR/MetalFX reset，
  并在下一帧 `frame["temporalReset"]` 中传递。
- 后处理目标、历史和 FSR/MetalFX 上下文都与 `renderSize`/`displaySize`/模式绑定；任一变化都会重建。

## 8. 帧生成（FG）

### 8.1 算法层

- **Vulkan**：`FgBackend` 封装 `ffxOpticalflow` + `ffxFrameInterpolation`；两个 effect 的上下文
  描述都不含 swapchain，算法只记录计算命令，交换链和 present 交给 `VulkanPresenter`。
- **Apple**：`createMetalFxFrameGenerator()` 在系统提供 `MTLFXFrameInterpolator` 时返回实现；
  与 Vulkan 共用 `RhineRender::FrameGenerator` 契约。
- 资源契约：`color`/`colorHudLess`/`output` 是显示分辨率且格式相同；`depth`/`motionVectors` 是
  渲染分辨率；`prepare()`/`dispatch()` 在 `beginExternal()`/`endExternal()` 之间调用。
  `resize()`/`release()` 在呈现层只能在帧外；Apple 默认窗口在 pass 结束后调用并延迟销毁，
  不等待设备空闲。

### 8.2 平台门控与宿主

| 平台 | 宿主 | 插值条件 |
| --- | --- | --- |
| Apple（macOS/iOS） | 默认 QQuickWindow | `panel/fg` 或 `RHINE_FG=on`，MetalFX 插帧可用，`renderscale × supersample ≤ 100%` |
| Windows | `PresentationShell` | `RHINE_FG=on`（默认 off）；呈现层接管且 FG 上下文可用 |
| Linux | `PresentationShell` | `RHINE_FG=on`；`RHINE_FG_LAYER=on` 只接管不插值 |

`RHINE_FG_LAYER=off` 在 Windows/Linux 强制默认窗口；Apple 无效果。

### 8.3 每帧流程

**呈现层（Windows/Linux）**：

1. `armFrameGeneration()` 在帧外读 `FrameInputs`，按显示物理像素 resize FG 上下文，写相机/抖动/reset。
2. `recordFrameGeneration()` 在同一离屏帧内先 `prepare()`（光流 + 深度重建），再 `dispatch()`（插值）。
3. `composite()` 以插值帧为 base，叠加 UI 层（`fgComposite.frag` 的预乘 source-over）。
4. 插值帧上屏后，真实帧留到下一次 `step()` 的 `pendingRealFrame` 分支，一步只 present 一次。
5. `lastFrameReset()` 为真时本帧直接呈现真实颜色。

**Apple 默认窗口**：

1. 每两帧真实渲染一次；真实颜色写入私有 RGBA8 目标，`MetalFX FrameInterpolator` 生成上一对
   真实帧的中间帧。
2. 本帧先呈现中间帧，下一帧呈现同一对的真实帧，保证时间顺序。
3. `update()` 在每个 vsync 续帧，引擎 85–95Hz 内容按 60Hz 采样。
4. `RHINE_METAL_FG_ASYNC=on` 可把插值放到后台命令队列；`RHINE_METAL_FG_SCALE` 控制插值分辨率；
   `RHINE_METAL_FG_LINK_SCALER=on` 才链接 MetalFX 时域 scaler。

### 8.4 统计与设置

- 设置页“帧生成”行仅 Apple 可见；`panel/fg` 默认关闭，开关运行期生效。
- `RhineFg::Stats` 统一承载：呈现/真实/插值计数、耗时、交换链信息；默认窗口用
  `defaultWindow=true` 标记，性能面板据此显示“默认窗口”区块并且不覆盖 Qt 的帧间隔。
- `--frame-profile` CSV 末尾包含 `gpu_time_ms,fg_presented,fg_interpolated,fg_rendered`，
  便于 A/B 与核对 60/60。

## 9. 调度、缓存与诊断

### 9.1 帧调度

- `Engine::FramePacingPolicy` 用“发布/消费序号”判断渲染线程是否取走上一份快照；输入优先；
  上一份未消费时跳过完整 step；250ms 看门狗防止窗口遮挡时动画永久挂住。
- 引擎定时器不是固定 60Hz：动态间隔由消费状态决定；静止 750ms、场景 4 帧稳定且无 HUD 动画后休眠。
  盘面单独旋转时降到约 30Hz；`RHINE_TICK_MS` 可人为压帧。
- Apple 默认窗口在动画期间由 `RhiScene` 每个 vsync `update()`；静止/休眠后停止续帧。
- `sceneRevision`/`hudRevision` 只在内容真的变化时自增；呈现层用它代替“按信号重复置脏”。
- Linux `SceneLayerHost` 默认每 20 帧补一次脏（`RHINE_LAYER_SAFETY_FRAMES`）；`RHINE_LAYER_REVISION=1`
  额外按版本号推进置脏，但信号和周期兜底仍然生效。

### 9.2 性能与资源计数

- `Engine::recordRender()` 汇总资源数、SRB 创建、纹理字节、封面上传、draw call、GPU 时间
  （四态 `unsupported/disabled/noSample/ok`）。
- `FrameProfiler`/性能面板读取 `RhineFg::Stats` 与 `Engine` 资源账本；默认窗口的 FG 数据由
  `Engine::publishFrameGenerationStats()` 转交，呈现层由自身 `publishStats()` 写入。
- 常用诊断：

| 变量 | 用途 |
| --- | --- |
| `RHINE_PACE_DIAG` | 引擎 tick/step/render、唤醒来源、发布/消费差 |
| `RHINE_STEP_PROBE` / `RHINE_LAYER_PROBE` / `RHINE_HUD_PROBE` | 拆 step/HUD/图层成本 |
| `RHINE_FG_DIAG` | 呈现层 FG 计数、层耗时、脏标记、交换链重建/等待 |
| `RHINE_METAL_FG_DIAG` | Apple 默认窗口每秒呈现/真实/插值计数、能力发布 |
| `RHINE_POST_PROBE` | 后处理路径与全屏 pass 数 |
| `RHINE_VK_RESOURCE_PROBE` / `RHINE_MEMORY_PROBE` / `RHINE_TEXTURE_PROBE` / `RHINE_MOTION_PROBE` | Vulkan 资源、内存、纹理准入、运动矢量配对 |
| `RHINE_DEBUG_FSR` / `RHINE_DEBUG_GPU` / `RHINE_DEBUG_DRAWS` / `RHINE_DEBUG_TINT` / `RHINE_DEBUG_ATLAS` | 各专项调试 |
| `RHINE_DRAW_PROBE` / `RHINE_GPU_PROBE` / `RHINE_KEY_PROBE` / `RHINE_HUD_SKIP_PAINT` / `RHINE_POST_REUSE` | 绘制/HUD/后处理探针 |
| `RHINE_WARP_PROBE` / `RHINE_WARP_SHOW` | Linux 重投影探针 |
| `RHINE_FG_DEBUG` / `RHINE_FG_SWAP_IMAGES` / `RHINE_RESOURCE_BUDGET_MB` | FG 呈现与资源预算 |

## 10. 着色器与资源清单

| 类别 | 文件 | 用途 |
| --- | --- | --- |
| 场景几何 | `enhancement/opticalGeometry.vert` | 实例化顶点、图集 UV、三维光场坐标、Linux/Apple previousModel/速度 |
| 场景材质 | `enhancement/opticalSurface.frag` | 烘焙表面、主光高光、玻璃/薄膜、盘面、MRT 运动矢量 |
| 场景材质 | `enhancement/opticalSurfaceNoMrt.frag` | 无第二颜色附件时的变体 |
| 最终合成 | `enhancement/opticalQuad.vert` / `opticalFinalFragment.frag` | 全屏三角、九点柔化、ACES、纸张背景 |
| 运动 | `motion.vert` / `velocity.frag` | Windows 深度/运动矢量 pass |
| 后处理 | `quad.vert` / `copyColor.frag` / `aaFragment.frag` / `taa.frag` | 拷贝、FXAA、TAA |
| 超分 | `fsr1_easu.frag` / `fsr1_rcas.frag` | FSR1 EASU/RCAS |
| MetalFX 时域 | `metal-temporal/resolve.vert` / `resolve.frag` | `MetalTemporalResolve` 轻量时域路径 |
| MetalFX 呈现 | `metal-temporal/present.vert` / `present.frag` | 默认窗口补帧/真实帧拷贝到 QQuickRhiItem 目标 |
| 呈现合成 | `fgComposite.vert` / `fgComposite.frag` | 呈现层插值帧/真实帧与 UI 的预乘 source-over |
| 公共 | `common.glsl` / `enhancement/opticalCommon.glsl` | 全局块、ACES、sRGB、面朝向 |
| 紧凑变体 | `Qt/shaders/compact/` | 无运动矢量消费者的 80 字节实例管线 |
| FFX 预编译 | `generated/ffx_shaders/vk/*.h` | FSR3 超分/帧生成计算着色器 |

烘焙资源由 `scripts/bake-archive-lighting.py` 生成；表面图集可输出 BC7，光场是 576×96×24 RGBA8
三维纹理，法线响应是 128×256 RGBA16F。旧的 `room-pmrem.bin`、AO/IBL 资源和实时阴影/法线/AO/景深
目标不再参与自维护场景路径。

## 11. 关键约束

1. **唯一场景渲染器**：`RhiScene` 同时负责资料库、详情页、查看器和唱片；不要引入第二条场景管线。
2. **平台后处理二选一**：Apple 用 MetalFX，非 Apple 用 `ScenePostProcess`；不会同时运行。
3. **FSR3 不是默认计算路径**：Vulkan 默认只走 FSR1；`RHINE_FSR3_FFX=1` 才创建 FFX 计算上下文。
4. **运动矢量按后端**：Linux/Apple 单趟 MRT（实例 144 字节，带 `previousModel`）；Windows
   `MotionPass`（实例 80 字节）。有 motion/TAA/FG/warp 消费者时不能裁掉第二附件或历史矩阵。
5. **共享 QRhi**：呈现层的两个离屏层、FG 宿主和呈现器必须同一设备；`SceneLayerHost::start()` 会校验。
6. **UI 不参与插值**：插值只作用于 3D 层，UI 在合成阶段按显示帧率叠加。
7. **高 DPI 不统一**：Linux 呈现层物理像素 + 根条目缩放；Windows 呈现层逻辑尺寸 + target DPR；
   默认 Qt Quick 路径（含 Apple）由 Qt 自己处理 DPR。
8. **FG 的宿主不同**：Apple 在默认 QQuickWindow 内；Windows/Linux 在呈现层内。
   Apple 的 `RHINE_FG_LAYER` 无效果；Linux 的呈现层接管需要显式 FG/FG_LAYER。
9. **FG 资源生命周期**：呈现层 `resize()/release()` 只能在帧外；Apple 默认窗口在 pass 结束后调用，
   使用 `deleteLater`、不主动等待设备空闲。`prepare()/dispatch()` 必须在 external 段内。
10. **退出顺序**：先拆呈现层/交换链，再销毁原生窗口；否则 WSI 会对已销毁 surface 做 roundtrip。
11. **离线参考渲染强制同步封面**：参考渲染只跑一帧，没有后续帧等异步成品。
12. **Vulkan 尺寸去重必须在 `finish()` 之前**：`VulkanPresentationBackend::resize()` 同尺寸早退。

## 12. 验证入口与文件职责

### 12.1 测试

- `qt_render_policy_regression`：GPU 计时四态、时间戳登记、AA 运动需求、场景同步签名、材质槽键、
  Apple 补帧设置与启动偏好。
- `qt_fg_capability_regression`：FG 开关解析、能力快照、设置页三态、帧输入投递。
- `qt_music_texture_admission_regression`、`qt_frame_pacing_regression`、`qt_vulkan_resource_regression`、
  `qt_scene_lifetime_regression`。
- `qt_offline`（`RHINE_GPU_TEST=1` 时含 GPU 离线参考）、`qt_glyphs_regression`、`qt_native_hud_regression`
  （含 Apple 帧生成行的可命中性）、`qt_gpu_choice_regression`、`qt_platform_regression`。
- `RHINE_VISUAL_TESTS=1` 的冻结动画/场景快照；`npm run test:visual` 手动运行。
- 离线测试不能替代真实 GPU、Windows/Linux 实机、显示缩放和系统集成验证。

### 12.2 文件索引

| 路径 | 职责 |
| --- | --- |
| `Qt/src/main.cpp` | 后端选择、偏好下发、默认/受控路径分流、退出顺序 |
| `Qt/src/Engine.{h,cpp}` | 场景/HUD 帧协议、抖动、内容版本、帧节拍、资源遥测、FG 能力/统计转发 |
| `Qt/src/RhiScene.{h,cpp}` | 唯一场景渲染器（烘焙材质、唱片、AA/FSR/MetalFX、默认窗口 FG、离线参考） |
| `Qt/src/render/ScenePostProcess.{h,cpp}` | 非 Apple 的 FXAA/TAA/FSR3/FSR1 后处理 |
| `Qt/src/render/MotionPass.{h,cpp}` | Windows 的深度 + 运动矢量 pass |
| `Qt/src/render/MetalFxBackend.{h,mm}` | Apple MetalFX 时域超分、FrameInterpolator 与后台插值队列 |
| `Qt/src/render/MetalFramePresentation.h` | Apple 默认窗口的真实/插值帧编排与上屏 |
| `Qt/src/render/MetalFrameQueue.h` | Apple 默认窗口可选的后台插值队列 |
| `Qt/src/render/PresentationShell.{h,cpp}` | 受控呈现调度（Windows/Linux）、FG 装配、合成、统计与降级 |
| `Qt/src/render/SceneLayerHost.{h,cpp}` | 两个离屏 QML 层、目标与高 DPI 几何 |
| `Qt/src/render/PresentationBackend.h` | 呈现后端抽象 |
| `Qt/src/render/RhiPresentationBackend.cpp` | Metal 的 QRhi 交换链呈现（Apple 默认窗口不经过；代码保留） |
| `Qt/src/render/VulkanPresentationBackend.cpp` | Vulkan 呈现适配器与管线缓存 |
| `Qt/src/fg/VulkanPresenter.{h,cpp}` | 自持 `VkSwapchainKHR`、信号量注入、present |
| `Qt/src/fg/FgBackend.{h,cpp}` | FSR3 光流 + 帧插值算法层 |
| `Qt/src/fg/FgConfig.h` / `FgCapability.h` / `FgFrameTap.h` / `FgStats.h` | FG 开关、能力、帧输入、统计 |
| `Qt/src/fsr/Fsr3Backend.{h,cpp}` | FSR3 超分封装（默认 Vulkan FFX 关闭） |
| `Qt/src/fsr/Fsr1Constants.h` / `FsrSharpness.h` | FSR1 常量与锐化换算 |
| `Qt/src/render/RenderConfiguration.h` | Apple 每 Engine 的渲染设置、能力与遥测 |
| `Qt/src/render/RenderPolicy.h` / `FramePacingPolicy.h` | GPU 计时、时间戳、节拍纯逻辑 |
| `Qt/src/render/MusicTextureAdmission.h` / `CoverPrepBudget.h` | 冷纹理准入与封面预处理预算 |
| `Qt/src/render/SceneSyncCache.h` / `MaterialSlotKey.h` | 同步签名与材质槽键 |
| `Qt/src/render/SceneResources.h` / `VulkanResourcePolicy.h` / `VulkanResourceProbe.h` | 资源所有权、arena/池化策略与探针 |
| `Qt/src/render/FrameGenerator.h` | 原生插帧算法契约 |
| `Qt/src/SettingsSchema.cpp` / `NativeHudSettings.cpp` / `NativeHudController.cpp` | 设置页帧生成行、偏好写入与运行期切换 |
| `Qt/src/FrameProfiler.cpp` | 性能面板与 CSV（含 `defaultWindow` FG 统计） |
| `Qt/src/Glyphs.{h,cpp}` / `DiscGeometry.{h,cpp}` | 文字图集与唱片环带网格 |
| `Qt/qml/Main.qml` / `Scene3D.qml` / `Overlay.qml` | 默认窗口与两层边界 |
| `Qt/shaders/**` | 场景材质、最终合成、后处理、超分、运动、MetalFX 与呈现合成 |
| `scripts/bake-archive-lighting.py` | 生成表面/光场/法线烘焙资源 |
