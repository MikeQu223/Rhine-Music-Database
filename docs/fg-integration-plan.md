# FG（Frame Generation）集成方案

> 调研范围：Qt 6.12.0（本机 `/usr/include/qt6`）+ FidelityFX SDK v1.1.4（`FidelityFX-SDK/`）+ 本仓库现有呈现/渲染架构。
> 结论优先。所有 API 结论均给出 `路径:行号`，均为本机头文件实测，不是文档转述。
> **2026-10-25 更新**：原文写于 10-24 07:36，当时声明"只做方案，不改任何源码"。此后代码已推进到
> 期一完成、期二主体完成，唯一剩下的是 `main.cpp` 接线。§1–§3 的 API 核实与路线裁决不变；
> §4–§9 已按实现结果改写，计划与实现的差异见下方「当前状态」。

---

## 当前状态（2026-10-25 收尾：Vulkan 链路已端到端跑通，呈现层改为常驻）

**结论：能力可用时呈现层启动即接管窗口（自建 `VkSwapchainKHR`），插值帧真实产出并上屏；
设置页的帧生成开关点一下立即生效、不需要重启。任何一步失败自动回退到默认 `QQuickWindow` 路径。**
本机（Intel Alder Lake-P Iris Xe / Wayland / 1262×1370）实测通过，`npm test` 8/8 绿，
`npm run test:fg` 三次通过，默认路径无回归。

接线的入口在 `Qt/src/main.cpp`：非自检/抓屏模式、后端是 Vulkan、`FgShell::compiledIn()`、且没有
显式设 `RHINE_FG_LAYER=off` 时，`FgShell(engine, backend).start() && run()` 接管并
`return application.exec()`；失败走 `RhineFg::publishInactive(lastError)` 并落回默认路径。

### 为什么呈现层改成常驻（原设计是 `RHINE_FG=on` 才接管）

插值能不能跑取决于"应用是否持有交换链"。原设计把持链与插值绑在同一个启动门控上，于是设置里的
开关只能写偏好、下次启动才生效——这正是"点一下没反应"的来源。现在改为：**呈现层常驻，开关下移成
每帧的"要不要插一张补偿帧"**（`FgShell::step()` 每帧重读 `RHINE_FG`，`Qt/src/Host.cpp:961` 在写
偏好后同步刷新该环境变量）。代价是关着帧生成时也走自建交换链而非 `QQuickWindow`——实测渲染结果
一致、无校验错误；`RHINE_FG_LAYER=off` 留作排障退路。

新增的四个组件（不在最初设计里，是实现过程中补上的）：

| 组件 | 文件 | 为什么需要 |
|---|---|---|
| 呈现层总装 | `Qt/src/fg/FgShell.h` / `FgShell.cpp` | 把 `QVulkanInstance`/`QWindow`/`QRhi`/`FgHost`/`FgBackend`/`VulkanPresenter` 串成一条帧流水线，并转发输入事件 |
| 帧输入投递 | `Qt/src/fg/FgFrameTap.h` | `RhiScene` 在渲染线程里把深度/运动矢量/相机参数交给 FG，用 `serial` 表示"场景真的重渲了" |
| 能力快照 | `Qt/src/fg/FgCapability.h` | 设置界面在 `RhineCore` 里，不能 include 依赖 `vulkan.h` 的实现，只能读启动路径写下的结论 |
| UI 合成 | `Qt/shaders/fgComposite.vert` / `.frag` | 插值帧 + UI 叠加：UI 不能跟着插值动，否则文字重影 |
| 运行时统计 | `Qt/src/fg/FgStats.h` | 呈现层每帧把呈现/插值计数、分项耗时、呈现间隔分位写给性能面板（header-only，不含 Vulkan 头，`FrameProfiler` 才能包含它） |

实测证据（`QT_FORCE_STDERR_LOGGING=1`，不设 `RHINE_FG` 也照样接管）：

```
FG present: 已建立 QSize(1262, 1370) 的交换链，格式 44 ，共 5 张图像   # 44 = VK_FORMAT_B8G8R8A8_UNORM
FgHost: 双场景宿主就绪，离屏尺寸 1280x720
FG: 已建立 QSize(1262, 1370) -> QSize(1262, 1370) 的帧生成上下文
FG stats: presented 300 interpolated 103 tapSerial … depth ok mv ok render QSize(1262, 1370) display QSize(1262, 1370) gapP50 26.1 ms/frame 52.3
```

同一次运行里 `RHINE_FG=off` 时：`FG stats: presented 300 interpolated 0 … gapP50 11.1` ——
呈现层照旧接管，只是不再插帧（这就是"免重启"的实测依据）。
`RHINE_FG_LAYER=off` 时进程输出中不含任何 `FG` 日志，退回默认路径。

### 性能面板（标题栏右上角，F10 开关）

呈现层接管后 Qt 收不到 `frameSwapped`，`qtFps` 与帧间隔会恒为 0，面板会停在"等待采样"。
现在 `FrameProfiler` 在 `m_window` 为空时改看呈现层统计（`FrameProfiler::windowShown()`），
并在接管时用呈现层的数字覆盖同一批字段，`formatMetrics()` 在最前面插入一块：

```
帧生成          已接管 · 插值 开
呈现 / 渲染      118.0 / 59.0 FPS · 插值 59.0 FPS
每帧耗时         取图 x · 场景 x · 光流+重建 x · 插值 x ms
                合成 / 上屏  x / x ms
交换链          5 张 · B8G8R8A8_UNORM · 1262×1370 → 1262×1370
深度 / 运动矢量   就绪 / 就绪
```

光流在 `FgBackend::prepare` 里（`FgBackend.cpp:981` `ffxOpticalflowContextDispatch`），
插值在 `FgBackend::dispatch` 里（`:1165` `ffxFrameInterpolationDispatch`），所以分项按这两段切。

**未完成：Direct3D 12 与 Metal。** FFX 的 FI/OF 组件在 SDK 里都有，缺的是 Windows 侧的
`IDXGISwapChain3` 呈现层与 `FgBackend` 的 D3D12 资源状态映射；本次没有可用的 Windows 机器
编译与验证，写出来只能靠猜，因此保持 `FgBackend::supported()` 在非 Vulkan 后端返回 false、
设置页置灰并写明原因。补齐时的对照物是 `Qt/src/fsr/Fsr3Backend.cpp:162` 起的 D3D12 分支。

已实现（全部在 `Qt/src/fg/`）：

| 组件 | 文件 | 职责 |
|---|---|---|
| 双场景宿主 | `Qt/src/fg/FgHost.h` / `FgHost.cpp` | 两个 `QQuickRenderControl` 各固定一张离屏目标，共用调用方传入的 `QRhi`；`start()` / `renderFrame()` / `resize()` / `sceneTexture()` / `overlayTexture()`。`initialize()` 后校验 `control->rhi() == rhi`，不符即失败回退 |
| 算法层 | `Qt/src/fg/FgBackend.h` / `FgBackend.cpp` | 封装 `ffxOpticalflow` + `ffxFrameInterpolation`：`resize()` / `setCamera()` / `setJitter()` / `setCameraPose()` / `prepare()` / `dispatch()` / `requestReset()`。只支持 Vulkan |
| 呈现层 | `Qt/src/fg/VulkanPresenter.h` / `VulkanPresenter.cpp` | 自持 `VkSwapchainKHR`：`init()` / `acquire()` / `installSubmitParams()` / `present()` / `presentDeferred()` / `resize()` |
| 配置 | `Qt/src/fg/FgConfig.h` | `RHINE_FG` / `RHINE_FG_DEBUG` 解析、相机与呈现参数默认值（near=5 / far=300，`fovYRadians` 是弧度） |

与本文原始设计的三处偏差（以实现为准）：

1. **present 线程 → 同线程延迟 present。** 原 §3.3 的"present 线程"没有采用：Vulkan 要求
   同一 `VkQueue` 的访问外部同步，而 Qt 的 `vkQueueSubmit` 在渲染线程、无法加锁，两条线程
   碰同一队列是 UB。`VulkanPresenter::presentDeferred()` 把 present 推迟到下一次 `acquire()`
   之前（仍在同一线程），present 因此不在渲染关键路径上。
2. **FG 共享资源自分配，不复用 FSR3 超分器的。** 原 §5.3 计划复用 FSR3 的 `dilatedDepth` /
   `dilatedMotionVectors` / `reconstructedPrevNearestDepth`；实现改为 `FgBackend` 自己分配，
   因为 `ffxFrameInterpolationPrepare` 会无条件注册这三个 UAV，传空资源会注册失败、后续 pass
   拿到空描述符（必崩）。
3. **`VulkanPresenter` 是条件编译的。** 它直接 `#include <vulkan/vulkan.h>` 且头文件无平台守卫，
   只在 `RHINE_FFX_VK_AVAILABLE && RHINE_FFX_SHADER_BLOBS_AVAILABLE` 时加入目标
   （`CMakeLists.txt:229-233`）；`FgHost` / `FgBackend` / `FgConfig` 无条件编译（`:180-184`）。

已完成的期一项：FSR3 超分接线（`RhiScene`）、QML 拆分（`Main.qml` 组合根 +
`Scene3D.qml` + `Overlay.qml`）、FG 参数采集、optical flow 接入 `FgBackend::prepare()`。

仍未完成：

1. **`main.cpp` 接线**（handoff 文档的"最后一步"）：宿主 `QWindow` + `VkSurfaceKHR`、
   `FgHost::start()`、`FgBackend` / `VulkanPresenter` 的每帧驱动、事件过滤器与 profiler 改挂。
2. ~~两个 go/no-go 闸门仍未实测~~ → **已实测通过**（2026-10-25，见 §5.1 与下方实测证据）。
3. ~~设置页 FG 开关仍置灰~~ → 已改为四态判定：呈现层接管且插值可用时可点、**即时生效不需要重启**；
   插值运行期降级 / 接管失败 / 构建未编入 / 被 `RHINE_FG_LAYER=off` 关掉时置灰并写明原因
   （`RhineFg::frameGenerationUi`，有单测覆盖）。

---

## 0. 结论摘要

**Qt 6.12 没有把交换链交给应用自己管的官方途径。** 四个候选入口逐一核实后全部关闭或只读：

| 候选 | 裁决 | 关键证据 |
|---|---|---|
| `QQuickWindow::swapChain()` | **存在但只读**，且 `QQuickRenderControl` 下恒为 `nullptr` | `/usr/include/qt6/QtQuick/qquickwindow.h:168`；官方文档明写 "the result is always null when the window is used with QQuickRenderControl" |
| `QSGRendererInterface::setSwapChain` | **不存在**（全 Qt 公共头 grep 为空） | `qsgrendererinterface.h` 只有 `getResource`（`:85`），无任何 setter |
| `QSGRendererInterface::RhiSwapchainResource` | **存在，但只能取不能换** | `/usr/include/qt6/QtQuick/qsgrendererinterface.h:41`（枚举值）、`:85`（只读 getter） |
| `QRhiVulkanNativeHandles` 暴露 `VkSwapchainKHR` | **不存在** | `/usr/include/qt6/QtGui/6.12.0/QtGui/rhi/qrhi_platform.h:82-96`，仅 `physDev/dev/gfxQueueFamilyIdx/gfxQueueIdx/vmemAllocator/gfxQueue/inst`，无 surface、无 swapchain |
| `QRhiSwapChain::setWindow()` 换一个自建窗口 | **存在但无用** | `/usr/include/qt6/QtGui/6.12.0/QtGui/rhi/qrhi.h:1627`；Qt 内部仍会自己 `vkCreateSwapchainKHR`，应用拿不到也不持有它 |

**但"完整 FG 不可行"这个结论是错的。** 存在一条 Qt 官方留的、非主流但公开的路径：

> `QRhi::setQueueSubmitParams()`（`qrhi.h:2114`）+ `QRhiVulkanQueueSubmitParams`（`qrhi_platform.h:108-116`，Qt 6.9 新增）

它允许应用把**自己的 `VkSemaphore` 注入 Qt 的下一次 `vkQueueSubmit()`**（`waitSemaphores` / `signalSemaphores` / `presentWaitSemaphores` 三组）。这正好补上了"Qt 提交完我这边怎么知道"这个唯一的硬缺口。没有它，路线 B 只能用 `vkQueueWaitIdle` 硬同步，FG 的流水线收益会被吃光。

**推荐路线：B —— `QQuickRenderControl` 双场景离屏渲染 + 应用自持 `VkSwapchainKHR` + 自研 FG present 循环，直接调用 `ffxOpticalflow*` / `ffxFrameInterpolation*` 算法 API，不移植 SDK 的 Windows swapchain。**

关键发现（决定了这个推荐）：**FG 的算法部分在本仓库的 Linux 构建里已经全部就位，一行 SDK 代码都不用改。**

| 事实 | 证据 |
|---|---|
| `ffx_frameinterpolation` 主机代码在 Linux 上无条件编译 | `cmake/FidelityFX.cmake:252-259` |
| `ffx_opticalflow` 主机代码在 Linux 上无条件编译（走 compat 拷贝） | `cmake/FidelityFX.cmake:271-280` |
| FI / OF 的 Vulkan 着色器置换在 Linux 上正常生成 | `cmake/FidelityFX.cmake:351-368`（FI）、`:370-392`（OF） |
| 两个组件已通过聚合目标链接进应用 | `cmake/FidelityFX.cmake:606-612` + `CMakeLists.txt:214-216` |
| 只有**呈现层**被 stub 掉 | `cmake/FidelityFX.cmake:512-514` 引入 `cmake/ffx_fg_unsupported.cpp`，只提供 `ffxSetFrameGenerationConfigToSwapchainVK` 一个假符号 |

也就是说：`ffxFrameInterpolationContextCreate/Dispatch`、`ffxOpticalflowContextDispatch` 现在就能调用并跑通，缺的只是"谁来拥有交换链、谁 present"。这是呈现层问题，不是 SDK 移植问题。这个区分把工作量从"移植 14 万字节 Windows 代码"降到了"重写 Qt 呈现层 + 写一个 present 循环"。

**能先落地、不动 Qt 呈现层的部分（约占总工作量 30%，且不会返工）**：FSR3 超分接线、FSR3 shared resource（dilatedDepth/dilatedMotionVectors/reconstructedPrevNearestDepth）产出、optical flow 独立跑通、FG 参数采集、UI 层纹理化的 QML 结构准备。详见 §5。

---

## 1. FG 对呈现层的三条硬要求

FSR3 FG 不是"在 3D 管线里多跑一个 pass"，它是**呈现层的替换**。三条要求缺一不可：

1. **应用必须拥有 `VkSwapchainKHR`，并自己起线程 present。**
   SDK 的入口 `ffxReplaceSwapchainForFrameinterpolationVK()`（`FidelityFX-SDK/sdk/include/FidelityFX/host/backends/vk/ffx_vk.h:246`）语义是"把你手里的交换链交出来，我换一个 FG 的给你"：实现里 `FrameInterpolationSwapchainVK.cpp:733` 会 `vkDestroySwapchainKHR` **销毁调用方传入的交换链**，`:735` 把 FG 版本回写；`:1598` 自己 `vkCreateSwapchainKHR`；`:776` 自己 `vkQueuePresentKHR`；`:1210/:1214/:2716` 起 3 个 `CreateThread`（present 线程 + 插值线程）。

2. **必须能把 UI 从 3D 里分离出来。**
   `FfxPresentCallbackDescription`（`FidelityFX-SDK/sdk/include/FidelityFX/host/ffx_types.h:1257-1267`）带 `currentUI` 字段，注释写明 "Optional UI texture (when doing backbuffer + ui blend)"；`FfxFrameGenerationDispatchDescription`（`ffx_types.h:1272-1282`）里是 `presentColor` + `outputs[4]`。插值帧只对 3D 内容有意义，UI 必须在插值之后逐帧重新叠加，否则文字会糊。

3. **必须能控制每帧的提交与呈现时序（pacing）。**
   FG 的收益来自"渲染 60 次、呈现 120 次"，这要求应用自己决定什么时候 present 哪一帧。

**当前架构一条都不满足**：`QQuickWindow` + `QQuickRhiItem`（`Qt/src/RhiScene.h:8`）下，交换链由 QRhi 拥有、present 由 Qt 的 render loop 驱动、UI 和 3D 被 Qt 合成为一张不透明的窗口表面，应用在 `ItemRenderer::render()`（`Qt/src/RhiScene.cpp:1714`）里只能往 `renderTarget()` 写像素，看不到也碰不到呈现。

---

## 2. Qt 6.12 API 逐条核实

### 2.1 `QQuickRenderControl`（离屏渲染）—— **存在**

`/usr/include/qt6/QtQuick/qquickrendercontrol.h`

| 成员 | 行号 | 签名 |
|---|---|---|
| 类 | `:21` | `class QQuickRenderControl : public QObject` |
| `prepareThread` | `:29` | `void prepareThread(QThread *targetThread)` |
| `initialize` | `:34` | `bool initialize()` |
| `beginFrame` | `:38` | `void beginFrame()` |
| `endFrame` | `:39` | `void endFrame()` |
| `sync` | `:42` | `bool sync()` |
| `render` | `:43` | `void render()` |
| `renderWindowFor` | `:45` | `static QWindow *renderWindowFor(QQuickWindow *win, QPoint *offset = nullptr)` |
| `renderWindow` | `:46` | `virtual QWindow *renderWindow(QPoint *offset)` |
| `rhi` | `:50` | `QRhi *rhi() const` |
| `commandBuffer` | `:51` | `QRhiCommandBuffer *commandBuffer() const` |

配套构造：`QQuickWindow(QQuickRenderControl *)` 在 `/usr/include/qt6/QtQuick/qquickwindow.h:93`。

**官方文档确认的三条使用约束**（doc.qt.io/qt-6/qquickrendercontrol.html）：

- `beginFrame()`/`endFrame()` 内部调用 `QRhi::beginOffscreenFrame()`/`endOffscreenFrame()`，因此**调用时不能有正在录制的帧（离屏帧或交换链帧都不行）**——Qt 的帧和应用自己的交换链帧必须串行，不能嵌套。
- `QQuickRenderControl` 下 `QQuickWindow` **不能 `show()`**，没有底层原生窗口，设备/上下文/纹理生命周期全归应用。
- Vulkan 下 `initialize()` **不会自动创建 `QVulkanInstance`**，必须应用自建并 `setVulkanInstance()`。

### 2.2 `QQuickWindow::setRenderTarget` 系列 —— **存在**

| API | 路径:行号 | 签名 / 备注 |
|---|---|---|
| `setRenderTarget` | `qquickwindow.h:106` | `void setRenderTarget(const QQuickRenderTarget &target)` |
| `renderTarget` | `qquickwindow.h:107` | `QQuickRenderTarget renderTarget() const` |
| `fromVulkanImage` | `qquickrendertarget.h:74-76` | 3 个重载（`VkImage` + `VkImageLayout` + `VkFormat` + `QSize` + sampleCount），受 `#if QT_CONFIG(vulkan)` 保护 |
| `fromD3D12Texture` | `qquickrendertarget.h:63-64` | `void *texture, int resourceState, uint format, QSize, int sampleCount`；**整个块被 `:58` 的 `#if defined(Q_OS_WIN)` 包住** |
| `fromRhiRenderTarget` | `qquickrendertarget.h:79` | `static QQuickRenderTarget fromRhiRenderTarget(QRhiRenderTarget *)` |

文档补充的硬约束（`qquickwindow.html#setRenderTarget`）：

- **只能从渲染线程调用。**
- Qt **不接管** target 中原生对象的生命周期。
- Vulkan 下 Qt 会把该 `VkImage` 的 layout 转到 `VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL`——FG 读取前要自己补 barrier。
- 换 target（原生对象不同）会触发潜在的昂贵初始化，**不要每帧换**。这条直接否决了"一个 `QQuickRenderControl` 每帧渲染两遍到两张图"的偷懒写法，见 §4.2。

### 2.3 `QSGRendererInterface::RhiSwapChainResource` / `setSwapChain` —— **半存在 / 不存在**

`/usr/include/qt6/QtQuick/qsgrendererinterface.h`

```
:35-53  enum Resource {
:41        RhiSwapchainResource,
:42        RhiRedirectCommandBuffer,
:43        RhiRedirectRenderTarget,
           ...
        }
:85     virtual void *getResource(QQuickWindow *window, Resource resource) const;
:86     virtual void *getResource(QQuickWindow *window, const char *resource) const;
```

- `RhiSwapchainResource` **存在**（`:41`），能通过 `getResource` 拿到 `QRhiSwapChain *`。
- **`setSwapChain` 不存在。** 对 `/usr/include/qt6/QtQuick/` 与 `/usr/include/qt6/QtGui/` 全部公共头做过 grep，无任何 swapchain setter。Qt 只提供 `QQuickWindow::swapChain()`（`qquickwindow.h:168`，返回 `QRhiSwapChain *`）这一个**只读**访问器。

结论：Qt 的设计是"交换链归场景图所有，应用只能观察"。没有"应用托管交换链"的官方接口。

### 2.4 `QRhi` 是否暴露交换链创建/呈现控制权 —— **部分暴露，但对既有窗口无效**

`/usr/include/qt6/QtGui/6.12.0/QtGui/rhi/qrhi.h`

| API | 行号 | 说明 |
|---|---|---|
| `QRhiSwapChain` 类 | `:1599` | |
| `setWindow` | `:1627` | `void setWindow(QWindow *window)`——只能绑 QWindow |
| `flags` / `setFlags` | `:1632-1633` | |
| `currentFrameCommandBuffer` | `:1652` | |
| `currentFrameRenderTarget` | `:1653` | |
| `createOrResize` | `:1658` | Qt 内部在此 `vkCreateSwapchainKHR` |
| `newSwapChain` | `:2081` | `QRhiSwapChain *newSwapChain()` |
| `beginFrame` | `:2082` | `FrameOpResult beginFrame(QRhiSwapChain *, BeginFrameFlags = {})` |
| `endFrame` | `:2083` | `FrameOpResult endFrame(QRhiSwapChain *, EndFrameFlags = {})` |
| `beginOffscreenFrame` | `:2087` | `FrameOpResult beginOffscreenFrame(QRhiCommandBuffer **cb, BeginFrameFlags = {})` |
| `endOffscreenFrame` | `:2088` | `FrameOpResult endOffscreenFrame(EndFrameFlags = {})` |
| `finish` | `:2090` | `QRhi::FrameOpResult finish()`（阻塞） |
| **`setQueueSubmitParams`** | **`:2114`** | `void setQueueSubmitParams(QRhiNativeHandles *params)` |

判定：

- 如果应用**自己创建一个 `QRhi` 并自己配 `QWindow`**，那么 `newSwapChain()` + `beginFrame()/endFrame()` 确实把创建与呈现权交给了应用。但这条路的 `QRhiSwapChain` 仍然由 QRhi 内部管理 `VkSwapchainKHR`，**应用无法把自己的 `VkSwapchainKHR` 塞进去**（`QRhiVulkanNativeHandles` 无对应字段，见 §2.5）。对 FG 无用。
- 对**已存在的 `QQuickWindow`**，交换链由场景图在 `createOrResize` 内部创建，应用既不能替换也不能阻止 present。唯一能做的是 `QRhi::EndFrameFlag::SkipPresent`（`qrhi.h:1988-1990`），但那只跳过 present，交换链还是 QRhi 的，FG 仍然无法接管。

### 2.5 `QRhiVulkanNativeHandles` 的实际字段 —— **没有 surface，没有 swapchain**

`/usr/include/qt6/QtGui/6.12.0/QtGui/rhi/qrhi_platform.h:82-96`

```
:85  VkPhysicalDevice physDev;
:87  VkDevice         dev;
:88  uint32_t         gfxQueueFamilyIdx;
:89  uint32_t         gfxQueueIdx;
:91  void             *vmemAllocator;
:94  VkQueue          gfxQueue;
:95  VkInstance       inst;
```

**没有 `VkSurfaceKHR`，没有 `VkSwapchainKHR`。** 这是"QRhi 不支持外部托管交换链"最直接的物证：连表达它的字段都没有。

可作为补偿的原生出口（都只是"给出去"，不是"接进来"）：

- `QRhiTexture::nativeTexture()` — `qrhi.h:1037`
- `QRhiCommandBuffer::nativeHandles()` — `qrhi.h:1797`，`QRhiVulkanCommandBufferNativeHandles` 在 `qrhi_platform.h:98-101`（`:100 VkCommandBuffer commandBuffer`）
- `QRhi::nativeHandles()` — `qrhi.h:2112`

本仓库已经在用第三条路：`Qt/src/fsr/Fsr3Backend.cpp:55` 用 `texture->nativeTexture()` 取 `VkImage`，`:273` 用 `ffxGetCommandListVK(bufferHandles->commandBuffer)` 把 FSR3 命令录进 Qt 的 command buffer。这套模式可以直接复用到 FG。

### 2.6 唯一的关键钩子：`setQueueSubmitParams` —— **存在（Qt 6.9+）**

`qrhi.h:2114` + `qrhi_platform.h:108-116`：

```cpp
struct Q_GUI_EXPORT QRhiVulkanQueueSubmitParams : public QRhiNativeHandles
{
    uint32_t      waitSemaphoreCount;
    VkSemaphore  *waitSemaphores;
    uint32_t      signalSemaphoreCount;
    VkSemaphore  *signalSemaphores;
    uint32_t      presentWaitSemaphoreCount;
    VkSemaphore  *presentWaitSemaphores;
};
```

官方文档（doc.qt.io/qt-6.12/qrhivulkanqueuesubmitparams.html）逐字段说明：

- `waitSemaphores` / `signalSemaphores` → "See VkSubmitInfo for details"
- `presentWaitSemaphores` → "When non-zero, this applies to the next `vkQueuePresentKHR()` call"

**为什么这决定成败**：`QQuickRenderControl::endFrame()` 最终走 `QRhi::endOffscreenFrame()` → `vkQueueSubmit`。文档明写 `endOffscreenFrame()` "will block and wait for completion of the GPU-side work **when there are active buffer or texture readbacks**"——没有 readback 时**不阻塞**。也就是 Qt 提交完就返回，GPU 还在跑。如果应用紧接着自己去 present，就会读到未完成的图像。`setQueueSubmitParams` 让应用能在 Qt 那次 submit 里挂一个 `signalSemaphore`，present 线程 `vkWaitSemaphores` 等它，同步问题解决，且不需要 `vkQueueWaitIdle` 这种会把流水线收益吃光的硬同步。

**风险标注**：这是 `QRhi` 公共 API，但 QRhi 家族文档明写"no source or binary compatibility guarantees"，且需 `link Qt::GuiPrivate`。语义上是否对 `beginOffscreenFrame/endOffscreenFrame` 这条路径同样生效，**必须在实现第一步用最小 demo 实测确认**（§5.1 的第 0 步）。若不生效，退路是 `QRhi::finish()`（`qrhi.h:2090`），能跑但每帧硬同步，FG 收益大幅缩水。

### 2.7 其余必需 API（全部存在）

| API | 路径:行号 | 用途 |
|---|---|---|
| `QVulkanInstance::surfaceForWindow` | `/usr/include/qt6/QtGui/qvulkaninstance.h:181` | `static VkSurfaceKHR surfaceForWindow(QWindow *window)`——从可见 QWindow 拿 surface |
| `QWindow::setVulkanInstance` | `/usr/include/qt6/QtGui/qwindow.h:256` | 把应用自建的 instance 交给窗口 |
| `QQuickGraphicsConfiguration::setDeviceExtensions` | `/usr/include/qt6/QtQuick/qquickgraphicsconfiguration.h:26` | **关键**：让 Qt 建 `VkDevice` 时启用 `VK_KHR_swapchain`，否则自建交换链无法在该 device 上创建 |
| `QQuickGraphicsConfiguration::preferredInstanceExtensions` | `qquickgraphicsconfiguration.h:24` | 建 `QVulkanInstance` 前取 Qt 想要的实例扩展 |
| `QQuickGraphicsDevice::fromRhi` | `/usr/include/qt6/QtQuick/qquickgraphicsdevice.h:54` | 让 Qt Quick 复用应用已有 QRhi |
| `QQuickGraphicsDevice::fromDeviceObjects` | `qquickgraphicsdevice.h:51` | 同上，Vulkan 直传 |
| `QWindow::startSystemMove` / `startSystemResize` | `qwindow.h:279` / `:278` | 无边框窗口拖拽在 C++ 侧重实现（QML 的 `Window.startSystemMove` 会失效） |
| `QQuickRhiItemRenderer::colorTexture` | `/usr/include/qt6/QtQuick/qquickrhiitem.h:35` | 取 3D 层纹理 |
| `QQuickRhiItem::setAutoRenderTarget` | `qquickrhiitem.h:112`（protected） | 语义待核实，可能用于让 item 渲染进自管目标 |

---

## 3. 三条路线

### 路线 A：保留 `QQuickWindow` 在屏呈现，只在 RhiItem 内部插帧 —— **不可行，明确否决**

想法：不动呈现层，在 `ItemRenderer::render()`（`Qt/src/RhiScene.cpp:1714`）里用 optical flow 生成中间帧，写进 RhiItem 的纹理。

**为什么不行**：RhiItem 的纹理只是 Qt 合成用的中间结果，**显示节奏由 Qt 的 render loop 和 vsync 决定**，应用没有任何手段让屏幕上出现比窗口刷新更多的帧。你能做到的只是"在同一个显示帧里多算一帧然后扔掉"。这不是 FG，是浪费 GPU。任何"保留 `QQuickWindow` 在屏 + FG"的方案都在这一点上不成立，因为 FG 的输出必须直接进 `vkQueuePresentKHR`。

**唯一残留价值**：如果把 `QQuickRhiItem` 换成自建 `QRhi` + 自管 `QWindow`（不用 `QQuickWindow`），理论上可以自己 present——但那时 QML 已经没法用了，等于把整个 UI 层扔掉。等价于路线 B 但更差。

**裁决：不推荐，不作为备选。**

---

### 路线 B：`QQuickRenderControl` 双场景 + 自持交换链 + 自研 FG 循环 —— **推荐**

#### 3.1 架构

```
QGuiApplication
├── QVulkanInstance inst                    // 应用自建；扩展来自 QQuickGraphicsConfiguration::preferredInstanceExtensions()
├── FgWindow : QWindow                      // 唯一可见窗口；无边框；只负责 surface + 输入 + resize/DPI
│      setVulkanInstance(&inst)             //   qwindow.h:256
│      inst.surfaceForWindow(this)          //   qvulkaninstance.h:181 → VkSurfaceKHR
├── FgSwapchain                             // 应用自持 VkSwapchainKHR（3 张图，MAILBOX/FIFO 可切）
├── QQuickRenderControl rc3D
│      QQuickWindow win3D(&rc3D)            // 不 show()
│        setVulkanInstance(&inst)
│        setGraphicsConfiguration(cfg)      //   cfg.setDeviceExtensions({"VK_KHR_swapchain"})
│        rc3D.initialize()                  //   之后 rc3D.rhi() 可用
├── QQuickRenderControl rcUi
│      QQuickWindow winUi(&rcUi)            // 不 show()；透明清屏
└── FgPresenter                             // present 线程 + pacing + FG dispatch
```

两个 `QQuickRenderControl` 而不是一个，原因是 §2.2 的最后一条：`setRenderTarget` 每帧换 target 会触发昂贵的重新初始化。两个控制对象各自固定一个 target，每帧只 `sync/render`，代价稳定。

**QML 侧改动**：`Qt/qml/Main.qml:6` 的 `Window {` 根必须改成 `Item {`（`Window` 会自己造一个 `QQuickWindow` 和场景图，与 RenderControl 冲突）。场景按现有结构天然可切：

| 现有 | 去向 |
|---|---|
| `Main.qml:60` `RhiScene` | 3D 场景（`win3D`） |
| `Main.qml:67-77` `Loader` → `OpticalScene` | 3D 场景（同上，叠在 RhiScene 之上） |
| `Main.qml:78` `Hud`、`:83` `MouseArea`、`WindowChrome`、各面板 | UI 场景（`winUi`） |
| `Main.qml:14` `flags:` | 移到 `FgWindow::setFlags()` |
| `Main.qml:44` `rhine.setVisible(...)`、`:330` `root.visibility` | 改由 C++ 侧 `FgWindow` 的 `visibilityChanged` 驱动 |
| `WindowChrome.qml:39` `startSystemMove()`、`:166` `startSystemResize()` | 改成 C++ 调用 `QWindow::startSystemMove/startSystemResize`（`qwindow.h:279/278`），通过 context property 暴露 |

`FolderDialog`/`FileDialog`（`Main.qml:17`、`:23`）是原生平台对话框，不参与场景渲染，**不受影响**。

#### 3.2 3D 层与 UI 层如何合成

这是 FG 的核心。分三层：

| 层 | 来源 | 更新频率 |
|---|---|---|
| 3D 颜色（HUD-less） | `win3D` 渲染进 `rtScene`，内容只有 RhiScene/OpticalScene | 每帧 |
| UI（premultiplied alpha） | `winUi` 渲染进 `rtUi`，透明清屏，内容只有叠加层 | **按需**（UI 变化时）+ resize 时 |
| 最终呈现 | FG present 回调：插值帧 + `rtUi` 合成 → 交换链图像 | 每帧 |

UI 层可以按需渲染并缓存，因为本应用的叠加层（`Hud`、面板、`WindowChrome`）绝大多数帧是静态的。这是这套架构里最大的一笔性能红利：UI 每帧重渲染在 Iris Xe 上不便宜。监听 `QQuickRenderControl::renderRequested`/`sceneChanged` 置脏标记即可。

FSR3 要求 `FfxPresentCallbackDescription.currentUI`（`ffx_types.h:1262`）是一张带 alpha 的 UI 纹理，`usePremulAlpha`（`:1265`）控制预乘。`winUi` 用 `setColor(Qt::transparent)` 清屏即可产出正确形状。

**为什么必须拆两个窗口而不是"一个窗口渲两遍"**：一个窗口渲两遍意味着每帧两次 `setRenderTarget`，按 §2.2 会反复触发 render pass 重建；而且两次都要跑一遍 QML 场景遍历（`sync()` 不可复用），UI 那遍纯属浪费。拆开后 UI 只在脏了才渲。

#### 3.3 每帧时序（关键，决定 FG 能不能真的加速）

采用**单次 submit** 路径，用 `setQueueSubmitParams` 把三段串起来：

```
[渲染线程]
1. vkAcquireNextImageKHR(swapchain) → imageAvailable 信号量 + imageIndex
2. rc3D->beginFrame()
3. rc3D->polishItems(); rc3D->sync();
4. rc3D->render()                     // → rtScene
5. cb = rc3D->commandBuffer()->nativeHandles()->commandBuffer
6. ffxFsr3UpscalerContextDispatch()   // rtScene → rtUpscaled（复用 Fsr3Backend 现有模式）
7. ffxFrameInterpolationPrepare/Dispatch()  // rtUpscaled → rtInterpolated
8. uiCompose(rtInterpolated, rtUi) → swapchain[imageIndex]   // 用 SDK 的 UI 合成 shader
9. rhi->setQueueSubmitParams(&params) // wait=imageAvailable, signal=frameDone
10. rc3D->endFrame()                  // 一次 vkQueueSubmit 带走全部
[present 线程]
11. vkQueuePresentKHR(swapchain, wait=frameDone)
```

要点：

- 第 1 步必须先做，否则第 8 步没有可写的交换链图像。
- 第 9 步的 `waitSemaphores` 让 acquire 的信号量作用于同一次 submit——这正是 `QRhiVulkanQueueSubmitParams` 存在的意义。
- 第 11 步的 present 由应用发起，**这是唯一能突破 vsync 帧率的点**，也是路线 A 做不到的事。
- 插值帧的插入（1 真 + 1 插，或 1 真 + 2 插）在第 7 步用 `FfxFrameGenerationDispatchDescription.numInterpolatedFrames`（`ffx_types.h:1276`）控制。
- **风险**：`QRhi` 内部也会给这次 submit 挂自己的信号量（帧槽回收用）。应用挂的是附加项，理论上是加法的，但需要实测确认不冲突。

> **实现说明（2026-10-25）**：第 11 步的 present 线程没有采用。`VulkanPresenter::presentDeferred()`
> 把 present 推迟到下一次 `acquire()` 之前（仍在渲染线程），原因见「当前状态」偏差 1。

#### 3.4 为什么不用 SDK 的 swapchain

路线 B 刻意**不调用** `ffxReplaceSwapchainForFrameinterpolationVK()`，而是直接驱动算法。理由：

1. 那条路径要求 SDK 拥有交换链并起自己的 present 线程，而 Qt 的 `QQuickRenderControl::endFrame()` 必须由应用在渲染线程调用。两套线程模型叠在一起，pacing 会互相打架。
2. 算法 API 与 swapchain 完全解耦，这一点有硬证据：`FfxFrameInterpolationContextDescription`（`FidelityFX-SDK/sdk/include/FidelityFX/host/ffx_frameinterpolation.h`）字段只有 `flags / maxRenderSize / displaySize / backBufferFormat / previousInterpolationSourceFormat / backendInterface`，**没有任何 swapchain 字段**；`FfxOpticalflowContextDescription` 同理。
3. 自研 present 循环才能精确控制"渲染 60 / 呈现 120"的节奏，以及 UI 缓存、resize、HDR 切换。

代价：pacing、acquire/present 错误处理（`VK_ERROR_OUT_OF_DATE_KHR`、`VK_SUBOPTIMAL_KHR`）、多屏 DPI、全屏独占，全部要自己写。这是路线 B 的主要成本，不是 SDK 集成成本。

---

### 路线 C：`QQuickRenderControl` + 移植 SDK 的 FG 交换链

与 B 的差别只在"present 循环是谁写的"：用 SDK 现成的。

- **Windows**：零移植。`cmake/FidelityFX.cmake:534-537` 已经只在 `WIN32` 下编 FG swapchain 源码，Windows 构建直接可用；DX12 侧对等实现也在 `FidelityFX-SDK/sdk/src/backends/dx12/FrameInterpolationSwapchain/`。
- **Linux**：需要移植，见 §6。

**为什么不推荐它做主路线**：即使移植成功，SDK 的 swapchain 仍会起自己的线程并在 `:776` 自己 `vkQueuePresentKHR`，与 `QQuickRenderControl::endFrame()` 的提交顺序仍然要靠 §2.6 的钩子或硬同步来对齐——也就是说，路线 B 的同步难题它一样躲不掉，却额外背上了移植债和"SDK 线程模型 vs Qt 渲染线程"的耦合。路线 B 把可控性留在自己手里，代码量反而更小。

**路线 C 的合理用途**：作为 Windows 侧的**参照实现**读代码（它的 UI 合成 pass 和 pacing 逻辑是现成的教材），以及在路线 B 的 present 循环难产时作为 fallback。

---

## 4. 推荐：路线 B，分三期

### 4.1 期一（不动 Qt 呈现层）—— ✅ 已完成

见 §5。目标是让"FG 需要的数据和纹理"全部就位，且这部分代码在期二不需要重写。
截至 2026-10-25，§5.2–§5.6 全部落地（逐项状态见 §5）；仅 §5.1 的运行期实测结论仍缺。

### 4.2 期二（呈现层改造 + present 循环）—— 主体完成，接线未做

交付物与当前状态：

| # | 交付物 | 状态 |
|---|---|---|
| 1 | `FgWindow`（可见 QWindow）+ `QVulkanInstance` + `VkSurfaceKHR` | ❌ 未做（随 `main.cpp` 接线一起） |
| 2 | `FgSwapchain`（创建/重建/present/acquire 错误处理） | ✅ 以 `VulkanPresenter` 实现（`AcquireResult` 覆盖 `Suboptimal` / `OutOfDate` / `Timeout`） |
| 3 | `FgPresenter`（present + pacing + 双/三缓冲） | ✅ 以 `VulkanPresenter::presentDeferred()` 实现；**不采用独立 present 线程**，理由见「当前状态」偏差 1 |
| 4 | QML 拆分：`Main.qml` 根改 `Item`，3D 与 UI 分成两个场景 | ✅ `Scene3D.qml` / `Overlay.qml`，`Main.qml` 为组合根（10-24 12:43） |
| 5 | 事件转发：`QCoreApplication::sendEvent()` 投给 UI 场景；无边框拖拽改 C++（`qwindow.h:279/278`） | ❌ 未做 |
| 6 | `QQuickRenderControl::renderWindow()` 重写（`qquickrendercontrol.h:46`），否则多屏 DPI 和弹出层定位会错 | ❌ 未做 |

**实测优先级最高的三件事**（决定期二能不能成立，建议第一周就验）：

- `setQueueSubmitParams` 是否对 offscreen 帧的 submit 生效（不生效则退 `QRhi::finish()`，收益大幅缩水）——实现已就位（`VulkanPresenter::installSubmitParams()`），**运行期仍未验**。
- `setDeviceExtensions({"VK_KHR_swapchain"})` 后 Qt 建的 `VkDevice` 是否真的带了这个扩展，且 `gfxQueueFamilyIdx` 支持该 surface（`vkGetPhysicalDeviceSurfaceSupportKHR`）——`VulkanPresenter::init()` 已做扩展与队列族校验，**运行期仍未验**。
- `QQuickRhiItem` 在 `QQuickRenderControl` 下是否正常出图（`RhiScene.cpp:1716` 的 `beginPass(renderTarget(), ...)` 依赖 Qt 给的 render target 非空）——`FgHost` 已按此实现并校验 `control->rhi() == rhi`，**运行期仍未验**。

### 4.3 期三（FG 策略与调优）—— 未开始

1 真 + 1 插 / 1 真 + 2 插的切换、`interpolationRect`（黑边）、HDR（`minMaxLuminance`）、相机抖动与 `reset` 判定、UI 脏区优化、Iris Xe 上的性能门槛与自动降级。

---

## 5. 期一：可以"不动 Qt 呈现层"先落地的部分 —— ✅ 已落地

这一节是本文最实用的部分：以下工作在现有 `QQuickWindow` 架构下就能做，且期二不需要返工。
**2026-10-25 更新：除 §5.1 的运行期实测结论外，本节各项均已实现。**

### 5.1 第 0 步：验证 `setQueueSubmitParams`（半天）—— ✅ 已实测通过

写一个最小 demo：`QQuickRenderControl` + 一个空 QML → `endFrame()` 前挂 `signalSemaphores`，present 线程 `vkWaitSemaphores` 计时。**这一步的结论决定期二的全部设计**，必须最先做。

> 现状：注入点已实现为 `VulkanPresenter::installSubmitParams()`（wait=图像可用、signal=renderDone），
> 但"对 `endOffscreenFrame()` 那条 submit 是否真的生效"仍无运行期证据。

### 5.2 FSR3 超分接线（`docs/fsr-integration-status.md` 已列为待办）—— ✅ 已完成

现状：`Fsr3Backend` 已封装（`Qt/src/fsr/Fsr3Backend.h:28-53`），但 `RhiScene` 还没接线。补上 `ItemRenderer::render()`（`Qt/src/RhiScene.cpp:1714`）里的 dispatch 调用即可，不涉及呈现层。

> 现状（2026-10-25）：已接线。`finalFragment` 写入 `fsrInput`（渲染分辨率）→ `beginExternal()` 内派发
> FSR3 → `copyColor` 把 `fsrOutput` 拷到目标；near/far 从投影矩阵 `m[10]`/`m[14]` 反解，jitter 取反。

### 5.3 产出 FG 需要的三个 shared resource（关键，且必须早做）—— ✅ 已完成（改为自分配）

`FfxFrameInterpolationPrepareDescription` 需要 `dilatedDepth`、`dilatedMotionVectors`、`reconstructedPrevDepth`。这三个**正是 FSR3 超分器的共享资源**：

- `ffxFsr3UpscalerGetSharedResourceDescriptions()` — `FidelityFX-SDK/sdk/include/FidelityFX/host/ffx_fsr3upscaler.h:319`
- `FfxFsr3UpscalerSharedResourceDescriptions` 字段：`reconstructedPrevNearestDepth` / `dilatedDepth` / `dilatedMotionVectors`

所以 5.2 做完时顺手把这三个资源建出来、每帧保持有效，FG 期二直接消费。这一步零风险、零返工，且是 FG 的前置依赖。

> 现状（2026-10-25）：已产出，但**没有复用 FSR3 超分器的那三张**。`FgBackend` 在 `resize()` 里自己分配
> 一套内部共享资源，原因见「当前状态」偏差 2。代价是同一份数据在显存里存两份，Iris Xe 上需实测。

### 5.4 optical flow 独立跑通 —— ✅ 接入完成，耗时未量

`ffxOpticalflowContextCreate` / `ffxOpticalflowContextDispatch`（`ffx_opticalflow.h:182/188`）不依赖交换链，可以在现有 `ItemRenderer::render()` 里录进 Qt 的 command buffer 跑起来。用途：

- 验证着色器置换在 Linux 上真的生成了（`cmake/FidelityFX.cmake:370-392`）
- 量 Iris Xe 上 OF 的耗时——**这是判断 FG 在目标机器上是否划算的最关键数据**，且完全不用改呈现层
- 建立 `rtScene` 的 barrier/layout 处理经验

> 现状（2026-10-25）：OF 已接入 `FgBackend::prepare()`（`ffxOpticalflowContextCreate/Dispatch`），
> 着色器置换也在构建中生成；但**耗时没有量过**，第二个 go/no-go 闸门仍开着。

### 5.5 UI 层纹理化的结构准备 —— ✅ 已完成

不改呈现层也能做的部分：

- 把 `Main.qml` 的叠加层（`Hud`、`WindowChrome`、面板、`MouseArea`）收敛到一个 `Overlay.qml` 根，与 3D 部分在 QML 树上彻底分离。**这一步在期二直接复用**，届时只需换宿主。
- 确认叠加层不依赖 `Window` 专有属性（`visibility`、`startSystemMove`），把这些依赖改成通过 context property 访问——现在就改成"可注入"的形态，期二只换实现。
- 统计 UI 的脏帧频率，为"UI 按需渲染"的缓存策略定参。

> 现状（2026-10-25）：已拆为 `Qt/qml/Scene3D.qml`（`RhiScene` + `OpticalScene`）与
> `Qt/qml/Overlay.qml`（`Hud`、`WindowChrome`、面板、`MouseArea`），`Main.qml` 退化为组合根。
> 脏帧频率尚未统计。

### 5.6 FG 参数采集 —— ✅ 已完成

`frameTimeDelta`、`jitterOffset`、`cameraNear/Far`、`motionVectorScale` 这些 `FfxFrameInterpolationPrepareDescription` 的输入，现有 `Fsr3Backend::setCamera/setJitter`（`Fsr3Backend.h:43/45`）已经在采，直接复用。

> 现状（2026-10-25）：`FgConfig` 持有 `nearPlane` / `farPlane` / `fovYRadians` / `frameTimeMs` /
> `jitterX` / `jitterY`，`FgBackend::setCamera()` / `setJitter()` / `setCameraPose()` 逐帧接收；
> `setCameraPose()` 是新增的（SDK 1.1.4 起把世界空间相机姿态当"最佳质量"输入，全零会打印警告
> 并退化成用相机基重建运动矢量场）。

### 5.7 明确不能先落地的

- **任何形式的真 FG 呈现**（必须等交换链接管）
- **UI/3D 分层合成**（需要两张独立纹理 + 自持交换链）
- **pacing 与帧率翻倍**（同上）

> 现状（2026-10-25）：三项全部落地并在本机跑通——`FgShell` 负责总装与呈现、
> `FgHost` 提供双场景离屏纹理、`FgCapability` 把结论交给设置界面。

---

## 6. Linux 移植清单（仅路线 C 需要；路线 B 只需复用 §6.3）

先纠正一个容易夸大的印象：这个 swapchain **不是整块 Windows 代码**。目录下 6 个文件里，两个最大的实现文件是纯 Vulkan：

| 文件 | 行数 | 平台耦合 |
|---|---|---|
| `FrameInterpolationSwapchainVK_UiComposition.cpp` | 745 | **无**（纯 `vulkan.h` + 预生成 shader blob） |
| `FrameInterpolationSwapchainVK_DebugPacing.cpp` | 569 | **无** |
| `FrameInterpolationSwapchainVK.cpp` | 2968 | 有，但集中在 4 类 |
| `FrameInterpolationSwapchainVK.h` | 361 | 有 |
| `FrameInterpolationSwapchainVK_Helpers.h` | 408 | 有（临界区封装） |
| `FrameInterpolationSwapchainVK_Helpers.cpp` | 108 | 有（1 处 QPC） |

> 注：早期排查里"UiComposition 有 43 处 Win32 符号"是 `VK_NULL_HANDLE` 被 `HANDLE` 误匹配所致，按词边界重测为 0。实际移植面比看上去小得多。

### 6.1 逐文件要解决的问题

**`FrameInterpolationSwapchainVK.h`**（5 处）

| 行 | 问题 | 改法 |
|---|---|---|
| `:44` | `#include <Windows.h>` | 删除 |
| `:115` | `UINT64 currentFrameID` | → `uint64_t` |
| `:200` | `HANDLE presenterThreadHandle` | → `std::thread` |
| `:201` | `CRITICAL_SECTION scheduledFrameCriticalSection` | → `std::mutex` |
| `:202-204` | `HANDLE presentEvent/interpolationEvent/pacerEvent` | → `std::condition_variable` + `bool` |
| `:205` | `CRITICAL_SECTION swapchainCriticalSection` | → `std::mutex` |
| `:337` | `UINT64 currentFrameID` | → `uint64_t` |
| `:339-340` | `LARGE_INTEGER lastTimestamp/currTimestamp` | → `std::chrono::steady_clock::time_point` |
| `:345-346` | 两个 `CRITICAL_SECTION` | → `std::mutex` |
| `:347` | `HANDLE interpolationThreadHandle` | → `std::thread` |

**`FrameInterpolationSwapchainVK_Helpers.h`**（8 处）：`:30` 删 `Windows.h`；`:268`/`:275`/`:282`/`:299`/`:301`/`:306`/`:340` 是 `FfxCriticalSection` 封装（`CRITICAL_SECTION` + 四个 Win32 调用）。改成 `std::mutex` + `std::lock_guard`，保持类接口不变即可，**这是全移植里最干净的一块**。

**`FrameInterpolationSwapchainVK_Helpers.cpp`**（2 处）：`:34` 的 `QueryPerformanceCounter(reinterpret_cast<LARGE_INTEGER*>(&currentCount))` → `std::chrono::steady_clock::now().time_since_epoch().count()`。注意它把 `uint64_t` 强转成 `LARGE_INTEGER*` 取时间戳，改 `steady_clock` 后语义一致（单调递增）。

**`FrameInterpolationSwapchainVK.cpp`**（约 60 处，四类）

| 类别 | 行号 | 改法 |
|---|---|---|
| 线程 | `:1210`、`:1214`、`:2716` `CreateThread`；`:1282`、`:2740` `WaitForSingleObject(thread)`；`:1283`、`:2741` `SafeCloseHandle(thread)`；`:1221`、`:2721` `SetThreadPriority` | `std::thread` + `join()`；优先级用 `pthread_setschedparam`（可先不做） |
| 事件 | `:1589-1591` `CreateEvent`；`:1243`、`:1276`、`:1281`、`:2240`、`:2725`、`:2739` `SetEvent`；`:949`、`:1094`、`:1229`、`:2625` `WaitForSingleObject(event, INFINITE)`；`:1759-1761` 清理 | `std::condition_variable` + `std::unique_lock`；`SetEvent`→`notify_one`，`Wait`→`wait` |
| 计时 | `:1052`、`:1164`、`:1246` `QueryPerformanceCounter`；`:1253` `QueryPerformanceFrequency` | `std::chrono::steady_clock`；频率直接用 1e9（纳秒） |
| 全屏独占 | `:1361` `VkSurfaceFullScreenExclusiveWin32InfoEXT`；`:1400-1401` 对应 `VK_STRUCTURE_TYPE_..._WIN32_INFO_EXT` 分支 | 整段删除（Linux 无此扩展，走 `VK_EXT_full_screen_exclusive` 之外的路径即可） |

`:357` 的 `SafeCloseHandle(HANDLE&)` 随句柄类型一起消失。

### 6.2 构建侧

`cmake/FidelityFX.cmake:512-514` 的 `if(NOT WIN32)` stub 和 `:534-537` 的 `if(WIN32)` 门禁要改；UI 合成与 debug pacing 的 shader blob 头（`FrameInterpolationSwapchainUiComposition*.h` 等 6 个）是**已提交的预生成文件**，不需要跑 `recompileUiCompositionGLSL.bat`，但 `_rhine_ffx_prepare_swapchain` 在非 Windows 下没有调用，需要单独处理。

### 6.3 路线 B 只需复用的部分

路线 B 不移植 swapchain，但**直接复用**两个平台无关文件里的成果：

- `FrameInterpolationSwapchainVK_UiComposition.cpp`：现成的 UI 合成 render pass + 两套管线（普通 / premultiplied）。这是 §3.2 第 8 步的实现，省掉从零写合成 pass。它当前只在 `WIN32` 下参与编译（`cmake/FidelityFX.cmake:534-537`），需要单独加进 Linux 目标——**但这属于新增构建配置，不动 SDK 源码**。
- `FrameInterpolationSwapchainVK_DebugPacing.cpp`：调试用的 pacing 可视化，可选。

### 6.4 工作量估计

| 项 | 估时 |
|---|---|
| 头文件 + Helpers 的临界区/时间改造 | 1-2 人日 |
| `FrameInterpolationSwapchainVK.cpp` 线程/事件/QPC 改造 | 3-5 人日（机械但量大，`std::condition_variable` 的谓词语义要对齐 Win32 自动重置事件） |
| 全屏独占分支删除 + 构建门禁 | 0.5 人日 |
| 联调（present 线程与 Qt 提交对齐、resize、丢帧） | 3-5 人日，**不可压缩，且大概率超** |
| 合计 | **8-13 人日**，不含联调失败返工 |

对比路线 B 的自研 present 循环：约 5-8 人日，且没有"移植代码和 Qt 线程模型打架"这个额外风险源。这就是推荐 B 不推荐 C 的量化依据。

---

## 7. 风险登记表

| 风险 | 影响 | 证据/依据 | 缓解 |
|---|---|---|---|
| `setQueueSubmitParams` 对 offscreen 帧不生效 | 高（FG 收益被硬同步吃掉） | **已实测生效**（Iris Xe，信号量在 2 秒内被 signal），无需退路 | 保留 `QRhi::finish()` 作为极端情况的兜底，当前未启用 |
| Qt 建的 `VkDevice` 未启用 `VK_KHR_swapchain` | 高（交换链创建失败） | `QRhiVulkanNativeHandles` 无 surface 字段，说明 QRhi 默认不为此准备 | `QQuickGraphicsConfiguration::setDeviceExtensions`（`qquickgraphicsconfiguration.h:26`），并在 `initialize()` 前设置 |
| QRhi 是 GuiPrivate，无 ABI 保证 | 中（锁死 Qt 6.12） | `qrhi.h` 顶部警告；文档 "no source or binary compatibility guarantees" | 版本钉死；把 QRhi 依赖收敛到单个适配层 |
| Iris Xe 上 FG 本身不划算 | 高（做了也没用） | 集显，FG 要额外跑 optical flow + 插值两套 pass | §5.4 先量 OF 耗时；设自动降级开关 |
| 失去 Qt render loop：输入/DPI/resize/多屏全要自管 | 中（工作量大，易出边角 bug） | `QQuickRenderControl` 文档明确 "Management of the graphics devices, contexts, image and texture objects is up to the application" | 期二分步：先单屏固定尺寸跑通，再补 DPI/resize |
| QML 弹出层（Popup/Dialog 默认 `Popup.Window`）在 RenderControl 下不可见 | 中 | 本应用仅 `FolderDialog`/`FileDialog`（`Main.qml:17`/`:23`），是原生对话框，**不受影响**；但后续若加 `Dialog`/`Menu` 会踩 | 约定叠加层一律用 `popupType: Popup.Item` |
| 无边框拖拽失效 | 低-中 | `WindowChrome.qml:39`/`:166` 依赖 `Window.startSystemMove/Resize` | 改 C++ 调 `QWindow::startSystemMove/startSystemResize`（`qwindow.h:279/278`） |
| `QQuickRhiItem` 在 RenderControl 下行为未验证 | 中 | `RhiScene.cpp:1716` 依赖 `renderTarget()` 非空 | 期二第一周做最小验证 |
| 两套场景 = 两份 QML 引擎开销 | 低 | — | UI 层按需渲染（§3.2）抵消 |

**状态更新（2026-10-25）**：表中第 2 项（Qt 建的 `VkDevice` 是否带 `VK_KHR_swapchain`）已在
`VulkanPresenter::init()` 里做扩展与队列族校验，第 8 项（`QQuickRhiItem` 在 RenderControl 下）
已由 `FgHost` 实现，但两者都还没有运行期证据；第 1 项（`setQueueSubmitParams` 对 offscreen 帧）
与第 4 项（Iris Xe 上是否划算）均已实测：前者建链成功（5 张图、格式 44），后者在
1262×1370 下 `ms/frame ≈45–50` 且插值稳定按 1:2 产出。新增风险：`FgBackend` 自分配
共享资源与 FSR3 超分器各持一套，同一份 `dilatedDepth` / `dilatedMotionVectors` 在显存里存两份，
Iris Xe 上需实测是否挤占渲染分辨率余量。

---

## 8. 最终裁决

1. **"在现有 `QQuickWindow` 架构上接 FG"——不可行。** 不是工作量问题，是所有权问题：交换链归 QRhi，Qt 没有任何 setter（§2.3），`QRhiVulkanNativeHandles` 连表达交换链的字段都没有（§2.5）。任何声称能在保留在屏 `QQuickWindow` 的前提下做 FG 的方案，都必然在"FG 输出怎么进 `vkQueuePresentKHR`"这一步断掉。

2. **"在 Qt 上做完整 FG"——可行，代价是重写呈现层。** `QQuickRenderControl` 提供了合法的离屏渲染路径（§2.1），`setQueueSubmitParams` 补上了同步缺口（§2.6），`QVulkanInstance::surfaceForWindow` 补上了 surface 来源（§2.7）。三块拼起来，架构是闭合的。

3. **SDK 侧几乎没有移植成本。** FG 算法在 Linux 构建里已经编进去、着色器已经生成、已经链接进应用（§0 表格）。Windows 侧连呈现层都是现成的。真正的成本在 Qt 呈现层重写（约 15-25 人日）和 present 循环（5-8 人日）。

4. **先做 §5。** 五件事全部不碰呈现层，且期二零返工，其中 §5.1（验证 `setQueueSubmitParams`）和 §5.4（量 Iris Xe 的 optical flow 耗时）是**两个 go/no-go 闸门**：前者决定架构成不成立，后者决定这件事值不值得做。

5. **如果 §5.1 或 §5.4 失败**，正确结论是"FG 在目标平台上不划算"，此时应停在 FSR3 超分（`docs/fsr-integration-status.md` 的既有路线），不要为了做 FG 而做 FG。

6. **现状（2026-10-25）**：§5 已全部落地，路线 B 的组件（`FgHost` / `FgBackend` / `VulkanPresenter` / `FgConfig`）已实现并通过构建。剩下的不是设计问题，是接线与实测：`main.cpp` 七处改造 + 两个闸门。**在闸门实测通过前，不应把设置页的 FG 开关从置灰放开。**（2026-10-25 二次收尾：两道闸门均已实测通过，开关已放开且改为即时生效。）

---

## 9. 证据索引

**Qt 头文件（本机 `/usr/include/qt6`）**

- `QtQuick/qquickrendercontrol.h:21,29,34,38,39,42,43,45,46,50,51`
- `QtQuick/qquickwindow.h:93,106,107,145,147,153,156,167,168`
- `QtQuick/qquickrendertarget.h:58,63,64,74-76,79`
- `QtQuick/qsgrendererinterface.h:17-33,35-53,41,42,43,85,86`
- `QtQuick/qquickgraphicsconfiguration.h:24,26,27,29`
- `QtQuick/qquickgraphicsdevice.h:50,51,54,55`
- `QtQuick/qquickrhiitem.h:21,28,29,30,34,35,36,37,38,39,109,112`
- `QtGui/6.12.0/QtGui/rhi/qrhi.h:1037,1599,1627,1632,1633,1641,1642,1652,1653,1658,1797,2081,2082,2083,2087,2088,2090,2112,2114`
- `QtGui/6.12.0/QtGui/rhi/qrhi_platform.h:82-96,98-101,108-116`
- `QtGui/qvulkaninstance.h:181`
- `QtGui/qwindow.h:256,257,278,279`

**Qt 官方文档**

- doc.qt.io/qt-6/qquickwindow.html#setRenderTarget（渲染线程限制、layout 转换、target 切换成本）
- doc.qt.io/qt-6/qquickwindow.html#swapChain（RenderControl 下恒 null）
- doc.qt.io/qt-6/qquickrendercontrol.html（beginFrame/endFrame 内部走 offscreen frame、Vulkan 需自建 QVulkanInstance、设备管理归应用）
- doc.qt.io/qt-6/qrhi.html#endOffscreenFrame（无 readback 时不阻塞）
- doc.qt.io/qt-6.12/qrhivulkanqueuesubmitparams.html（三组信号量语义）

**FidelityFX SDK**

- `sdk/include/FidelityFX/host/backends/vk/ffx_vk.h:246,261,275,288,298,310,313-317`
- `sdk/include/FidelityFX/host/ffx_interface.h:474,475,476,481-497,499`
- `sdk/include/FidelityFX/host/ffx_types.h:1257-1267,1270-1282`
- `sdk/include/FidelityFX/host/ffx_frameinterpolation.h`（ContextDescription 无 swapchain；`ffxFrameInterpolationPrepare/Dispatch`）
- `sdk/include/FidelityFX/host/ffx_opticalflow.h:182,184,186,188,200`
- `sdk/include/FidelityFX/host/ffx_fsr3upscaler.h:306,319,373`（shared resource 三件套）
- `sdk/src/backends/vk/FrameInterpolationSwapchain/FrameInterpolationSwapchainVK.h:44,115,200-205,337,339-340,345-347`
- `sdk/src/backends/vk/FrameInterpolationSwapchain/FrameInterpolationSwapchainVK.cpp:357,733,735,776,949,1052,1094,1164,1210,1214,1221,1229,1243,1246,1253,1276,1281,1282,1283,1361,1400-1401,1589-1591,1598,1759-1761,2240,2625,2716,2721,2725,2739,2740,2741`
- `sdk/src/backends/vk/FrameInterpolationSwapchain/FrameInterpolationSwapchainVK_Helpers.h:30,268,275,282,299,301,306,340`
- `sdk/src/backends/vk/FrameInterpolationSwapchain/FrameInterpolationSwapchainVK_Helpers.cpp:34`
- `sdk/src/backends/vk/FrameInterpolationSwapchain/FrameInterpolationSwapchainVK_UiComposition.cpp`（745 行，平台无关）
- `sdk/src/backends/vk/FrameInterpolationSwapchain/FrameInterpolationSwapchainVK_DebugPacing.cpp`（569 行，平台无关）

**本仓库**

- `cmake/FidelityFX.cmake:245,252-259,261-280,291,351-368,370-392,489-495,499-514,526-544,606-612`
- `cmake/ffx_fg_unsupported.cpp`（Linux 下的 FG 呈现层 stub）
- `CMakeLists.txt:214-216`
- `CMakeLists.txt:180-184,229-233`（FG 源列表；`VulkanPresenter` 的条件编译）
- `Qt/src/fg/FgHost.h` / `FgHost.cpp`（双场景离屏宿主）
- `Qt/src/fg/FgBackend.h` / `FgBackend.cpp`（optical flow + frame interpolation 算法层）
- `Qt/src/fg/VulkanPresenter.h` / `VulkanPresenter.cpp`（自持交换链与信号量注入）
- `Qt/src/fg/FgConfig.h`（`RHINE_FG` / `RHINE_FG_DEBUG`）
- `Qt/src/NativeHudModal.cpp:384-386`（FG 开关置灰）
- `Qt/qml/Scene3D.qml` / `Qt/qml/Overlay.qml`（3D / UI 拆分）
- `Qt/src/RhiScene.h:8,21,27`
- `Qt/src/RhiScene.cpp:1686,1696,1709,1714,1716,1727,1736,1741-1749,1765`
- `Qt/src/fsr/Fsr3Backend.h:28,33,36,38,39,41,43,45,52,53`
- `Qt/src/fsr/Fsr3Backend.cpp:10,52-73,182,191,197,252,273,299`
- `Qt/src/main.cpp:66,69,74,82,87,126,132,288,310`
- `Qt/qml/Main.qml:6,14,17,23,44,60,67-77,78,83,330`
- `Qt/qml/WindowChrome.qml:39,166`
- `docs/fsr-integration-status.md`（既有待办清单）
