# FSR3 帧生成（FG）最后一步交接

> 状态：除本文档描述的最后一步外，所有 FSR/FG 组件均已实现并通过完整构建。
> 当前工作区 `cmake --build output/qt-build -j8` 为绿，默认渲染路径完全正常。
> **2026-10-25 完结**：本文档描述的最后一步已经做完，两个 go/no-go 闸门也已实测通过
> （`setQueueSubmitParams` 对 offscreen 提交生效；共享 device 上建链成功，5 张图、格式 44）。
> `Qt/src/main.cpp` 的接线、呈现层、UI 合成、设置页三态、单测与 GPU 冒烟测试均已落地，
> 实测 presented 300 / interpolated 149。本文档保留作为过程记录；
> 当前状态以 `docs/fg-integration-plan.md` 的「当前状态」为准。

---

## 一、先验证这两件事（go/no-go 闸门）

在动 `main.cpp` 之前必须先验掉。任何一条不成立，FG 的收益模型就不成立。

### 闸门 1：两个 `QQuickRenderControl` 能否共享一个 `QRhi`

Qt 6.12 **没有** `QQuickRenderControl::initialize(QRhi*)`（头文件、动态库符号、官方文档三方核实）。
正确入口是：

```cpp
QQuickWindow::setGraphicsDevice(QQuickGraphicsDevice::fromRhi(rhi));
control->initialize();   // 无参版本
```

`Qt/src/fg/FgHost.cpp` 已按此实现，并在 initialize 后校验 `control->rhi() == rhi`，不符即失败回退（不崩）。

**最小验证**：写一个只载入 `Scene3D.qml`（即只含 `RhiScene`）的 FgHost，确认：
- `start()` 返回 true；
- `renderFrame()` 之后 `sceneTexture()` 里有非背景色像素。

重点确认 `QQuickRhiItem`（`RhiScene`）在 RenderControl 下能否出图——它依赖 Qt 传入的 renderTarget 非空（`Qt/src/RhiScene.cpp` 的 `ItemRenderer::render`）。

### 闸门 2：`setQueueSubmitParams` 对离屏帧是否生效

`QRhi::setQueueSubmitParams(QRhiNativeHandles*)`（`qrhi.h:2114`）+
`QRhiVulkanQueueSubmitParams`（`rhi/qrhi_platform.h:108-116`，6 个字段）。

`VulkanPresenter` 用它把"渲染完成信号量"注入 Qt 的 `vkQueueSubmit`，从而避免 `vkQueueWaitIdle` 硬同步。
若不生效，`renderDone` 永远无信号，`vkQueuePresentKHR` 会挂死。

**安全通道**：`RHINE_FG_PRESENT_SYNC=idle` 会跳过注入，present 前 `vkDeviceWaitIdle`。
如果真机挂死，先用这个跑通画面，再回头查注入。

**同时确认**：Qt 的 Vulkan 设备是否启用了 `VK_KHR_swapchain`。
没启用时 `vkGetDeviceProcAddr(dev, "vkCreateSwapchainKHR")` 返回空，`VulkanPresenter::init()` 会明确报错。
需要时用 `QQuickGraphicsConfiguration::setDeviceExtensions({"VK_KHR_swapchain"})`。

---

## 二、最后一步：用 FgHost 替换 `QQuickWindow` 启动结构

### 为什么不能做成旁路开关

`FgHost` 报告原话：只适用于"路线 B 的 FgWindow + 应用自驱动循环，不能当现有 `main.cpp` 的旁路开关"。
两个硬原因：

1. **同一 `VkQueue` 的线程安全**：Qt 的 threaded render loop 在自己的渲染线程里 `vkQueueSubmit`，
   我们无法给它加锁；两条线程碰同一个队列是未定义行为。
2. **同一 surface 上的两个交换链**：`QQuickRhiItem` 路径下 Qt Quick 自己 present，
   我们再建一个 `VkSwapchainKHR` 并 present，结果未定义/闪烁。

所以 FG 必须**替换**呈现层，不是叠加。

### 需要改的位置（`Qt/src/main.cpp`）

| 行号 | 现状 | 需要变成 |
|---|---|---|
| 289 | `QQmlApplicationEngine engine;` | 保留引擎（`rhine`/`profiler`/`rhineFontFamily` 是 engine-scoped 上下文属性，两条路径共用） |
| 307 | `engine.loadFromModule("RhineMusic", "Main");` | FG 路径改为**不加载** `Main.qml`，改为 `FgHost::start(engine, Scene3D.qml, Overlay.qml, rhi)` |
| 311 | `qobject_cast<QQuickWindow*>(engine.rootObjects().first())` | FG 路径没有 root window；需另建一个 `QWindow` 作为 `VkSurfaceKHR` 的宿主 |
| 323 | `backend.setWindow(window);` | 需要一个能接受 `QWindow*` 的宿主窗口；`Engine` 对窗口的依赖要逐个确认 |
| 331 | `window->installEventFilter(&backend);` | 事件过滤器改挂到新的宿主 `QWindow` |
| 332 | `profiler.attach(window);` | 同上 |
| 360 | `runUiChecks(..., qobject_cast<QQuickWindow*>(...))` | FG 路径下没有 root window，需要单独处理 |
| 392 | 后台释放定时器里的 `auto window = ...` | 同上 |

另外 `#ifdef Q_OS_WIN` 的管线缓存配置（`setGraphicsConfiguration`）与 `window->show()` 也要挪到新宿主。

### 自驱动渲染循环的骨架

```cpp
// 伪代码：替换 application.exec() 之前的窗口设置
QRhi *rhi = /* 自建：QRhi::create(QRhi::Vulkan, &params) */;
FgHost host;
if (!host.start(engine, QUrl("qrc:/qt/qml/RhineMusic/Scene3D.qml"),
                QUrl("qrc:/qt/qml/RhineMusic/Overlay.qml"), rhi)) {
    // 回退到现有 QQuickWindow 路径，不要 abort
}
VulkanPresenter presenter;
presenter.init(rhi, surface, size);
FgBackend fg;
fg.resize(rhi, renderSize, displaySize);

// 每帧：
//   1. host.renderFrame()                  → scene3d + overlay 两张纹理
//   2. FSR3 超分 scene3d（RhiScene 的既有路径或 FgBackend 上游）
//   3. fg.prepare(rhi, cb, colorHudLess, depth, motionVectors)
//   4. presenter.acquire(&frame) → fg.dispatch(...) → presenter.present(frame)
```

注意 `FgBackend::prepare()/dispatch()` 必须在 `beginExternal()/endExternal()` 之间调用。

### 资源路径

QML 已注册为 `qrc:/qt/qml/RhineMusic/Scene3D.qml` 与 `qrc:/qt/qml/RhineMusic/Overlay.qml`
（`Qt/CMakeLists.txt` 的 `QT_RESOURCE_ALIAS` + `qt_add_qml_module` 的 `OUTPUT_DIRECTORY`）。

### 相机参数

`FgBackend::setCamera(near, far, fovYRadians, frameTimeMs)`：
- near/far 从投影矩阵反解（`m[10]`/`m[14]`，`near = d/(c-1)`、`far = d/(c+1)`），与 `RhiScene` 里 FSR3 的做法一致；
- `fovY` 取 `NativeScene` 的 `m_fov`（**单位是度，需转弧度**）；
- `frameID` 必须严格 +1，跳帧会让 SDK 静默重置 FG 历史。

---

## 三、已完成的验证清单（供你先验前面的部分）

### 构建
```bash
cmake -S . -B output/qt-build
cmake --build output/qt-build -j8      # 期望 exit 0
```
配置阶段应看到：
```
-- FidelityFX: FSR3 components=ON vk=TRUE dx12=FALSE shader_blobs=TRUE
```

### 符号链接
```bash
nm -C output/qt-build/RhineMusicDatabase | grep -E "ffx(Fsr3Upscaler|FrameInterpolation|Opticalflow)ContextCreate"
```
应各出现 1 次。

### 运行时验证（需要你跑程序，我不被允许）

| 项 | 怎么看 |
|---|---|
| FSR3 超分 | `RHINE_AA_MODE=fsr3`，日志里不应出现 `FSR3: ffxFsr3UpscalerContextCreate failed`；画质应有边缘重建 |
| FSR1 | `RHINE_AA_MODE=fsr1`，画面应比 `off` 略锐，无白边 |
| MSAA | `RHINE_AA_MODE=msaa`，CD 边缘锯齿应明显减少。**Iris Xe 上先试 `RHINE_MSAA=2`**，4x 在 2536×1370 下额外约 +260MB 显存 |
| TAA | `RHINE_AA_MODE=taa`，静止时应收敛得更干净，转动时不应有拖影 |
| 免重启切换 | 设置页逐个切 AA 模式，不需重启即生效 |
| D3D11 移除 | `RHINE_GRAPHICS=d3d11` 应被忽略并回退到默认 |
| FG 开关 | 四态：呈现层接管且插值可用时可点、**即时生效（不重启）**；插值运行期降级 / 接管失败 / 未编入 / 被 `RHINE_FG_LAYER=off` 关掉时置灰写明原因 |

### 已知的未验证风险（按风险排序）

1. **Iris Xe 显存**：MSAA 4x 在 2536×1370 下额外约 +260MB。`create()` 失败会 `qFatal`，表现为切模式直接 abort。先用 `RHINE_MSAA=2`。
2. **速度矢量不含相机运动**：`velocity.vert` 里 current/previous 用同一个 `g.view`，所以相机平移时 TAA 重投影退化为同位置采样，靠 3×3 邻域夹紧兜底，会略软。FSR3 同样受限。根治需要把上一帧 view 也存进 Globals（会改 544B 布局）。
3. **`loaded` 目标在两个 pass 间共用 MS/resolve 纹理**：Vulkan 允许，但若某后端要求 resolve 目标独占，第二次 resolve 会出问题。
4. **viewer + MSAA 时 `normalDepth` 从未被渲染**却作为 `finalFragment` 的 binding 5 绑定。着色器 viewer 分支不采样它，但若后端对"从未作为附件用过的纹理直接采样"报 layout 错误，这里会先暴露。
5. **Windows 侧全部未编译验证**：DX12 后端、DXC 构建、`WindowsGraphics.cpp`。DX12 分支已用真实 `ffx_dx12.h` + 桩头做过四种宏组合的语法检查。

---

## 四、环境变量速查

| 变量 | 取值 | 作用 |
|---|---|---|
| `RHINE_GRAPHICS` | `vulkan` / `opengl` / `d3d12`(仅 Win) | 后端，重启生效 |
| `RHINE_AA_MODE` | `off`/`fxaa`/`ssaa`/`msaa`/`taa`/`fsr1`/`fsr3` | 互斥单选，免重启 |
| `RHINE_AA_SCALE` | 100–200 | 仅 SSAA |
| `RHINE_RENDER_SCALE` | 50–100 | 渲染分辨率百分比 |
| `RHINE_SUPERSAMPLE` | 1–2 | 超采样倍率 |
| `RHINE_MSAA` | 2/4/8 | MSAA 采样数覆盖 |
| `RHINE_JITTER` | 1 | 强制抖动（fsr3/taa 下自动开启） |
| `RHINE_FG` | `on`/`off` | 插帧开关：只决定每次呈现要不要插补偿帧，**免重启**（设置页写偏好时同步刷新） |
| `RHINE_FG_LAYER` | `off` | 排障用：强制不接管呈现层，退回 `QQuickWindow` 默认路径 |
| `RHINE_FG_PRESENT_SYNC` | `idle` | FG 排障：跳过信号量注入，present 前硬同步 |
