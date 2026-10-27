# 把 3D 场景重构为 Filament：可行性评估

> 评估日期 2026-10-27。Filament 基准版本 **v1.78.1**（2026-10-21 发布）。
> 代码事实取自本仓库当前工作树（`main` @ 2a0c877）；人日估算为量级参考，非承诺。
> **修订说明**：初版依据一次只扫描了 `filament/include`（公开 API）的调研，得出"Filament 自持设备、必须 fork"的结论。第二次调研在 `filament/backend/include` 中找到了共享上下文的入口，并经 Open3D v0.20.0 的 API 文档交叉验证。**§四 已推翻重写，结论从"要 fork"改为"不需要 fork"。**

---

## 一、结论先说

| 范围 | 结论 | 一句话理由 |
| --- | --- | --- |
| **A. 只把 3D 场景交给 Filament，Qt 管 UI，后处理自留** | **技术上成立，不需要 fork** | 设备可以共享（`VulkanSharedContext`）、呈现可以归宿主（重写 `VulkanPlatform`）。真正的代价是要保住 FSR3.1 + 插帧，你得在 Filament 之外**自己再渲一遍深度与运动矢量**——把想省的东西又请回来一半。 |
| **B. 把后处理也搬进 Filament** | **否决** | Filament 没有 FSR2/3、没有插帧、不暴露深度/运动矢量；而这正是 7,363 行里最值钱的部分。 |
| **C. 不迁** | **仍推荐** | 真正的维护成本在后处理与 HUD，Filament 对这两块一行都不减少。 |

一句话：**Filament 能替你画好那个场景，而且接得进来；问题是你要保的那两项能力，恰好都要求它把内部缓冲交出来。**

---

## 二、切口：数据流是一条纹理，不是一扇窗口

本项目不需要"窗口嵌入"，因为 FG 路径本来就是离屏的：

- `SceneLayerHost::sceneTexture()`（`Qt/src/render/SceneLayerHost.h:59`）直接返回一张 `QRhiTexture *`，
- `overlayTexture()`（同文件 `:61`）返回 UI 层纹理，
- 两层共用**同一个 `QRhi`**（该头文件 `:25` 的注释："场景与 UI 的离屏宿主，共享一个 QRhi"），Qt 侧天然零拷贝。

Qt 这边对"外来图像"是开放的：

- `QRhiTexture::createFrom(NativeTexture{quint64 object, int layout})`（`/usr/include/qt6/QtGui/6.12.0/QtGui/rhi/qrhi.h:1038`，结构体 `:994`）可认领现成图像；
- `QRhiVulkanNativeHandles`（`.../rhi/qrhi_platform.h:82`）可**导入** `VkPhysicalDevice physDev`、`VkDevice dev`、`gfxQueueFamilyIdx`、`gfxQueueIdx`（还有 `preferredExtensionsForImportedDevice()`），即 QRhi 可以改用别人建的设备。

所以缝合点只有一处：**Filament 与 QRhi 能不能待在同一台 `VkDevice` 上，以及那张图怎么交接。**

---

## 三、Filament 是什么（已核实）

### 定位、许可与维护

- **Apache-2.0**，含明示专利授权；闭源商用只需附许可文本。第三方的 37 个模块里已抽查的 LICENSE 全部为宽松许可（Apache-2.0 / MIT / BSD / zlib），**未发现 GPL/copyleft**。`[已核实]`
- **纯可嵌入渲染库**：无窗口管理、无 UI、无托盘。`libs/filamentapp` 只是样例的 SDL2 骨架。`[已核实]`
- **没有 UI、没有文字渲染**。唯一相邻物 `libs/filagui` = Dear ImGui 桥接。**HUD 不在它的管辖范围内。**`[已核实]`
- **没有动画系统、没有拾取**。`BootTimeline` 215 + `SceneMotion` 265 + `SceneDrag` 125 + `NativePicking` 249 = 854 行仍然是你自己的。`[已核实]`
- **维护状况很好**：20,656 star、2,284 fork、202 个未关 issue，2026-10-26 仍有提交（Romain Guy、Powei Feng 等在列），发版 **每周到每两周一次**（v1.78.1 10-21、v1.78.0 10-13、v1.77.3 10-08…）。桌面是三平台一等公民，六枚 CI 徽章（Android / iOS / Linux / macOS / Windows / Web）。`[已核实]`
- 官方自述仍是："**This is not an officially supported Google product.**"`[已核实]`

### 后端矩阵

| 后端 | 支持情况 | 对本项目 |
| --- | --- | --- |
| Vulkan 1.0 | Windows / Linux / macOS / Android | 与现有主路径一致 |
| OpenGL 4.1+ | Windows / Linux / macOS | 与现有 GL 回退一致，**但下限更高**（见下） |
| Metal | macOS / iOS / tvOS | 与现有 macOS 路径一致，但见 §九 的质量风险 |
| WebGPU / WebGL 2.0 | 桌面 + 浏览器 | 用不到 |
| **Direct3D** | **完全没有** | 无影响：D3D12 已于 commit `50d1d60` 停用 |

**收窄点**：Filament 桌面 OpenGL 要求 **4.1+**；本项目 GL 回退走 `QSGRendererInterface::OpenGL`（`Qt/src/main.cpp:100`、`:179`），未显式指定 GL 版本，下限由 Qt 决定且**低于 4.1**。那些今天能靠 GL 回退跑的旧机器，可能跑不了 Filament——而 GL 回退存在的理由恰恰就是它们。`[待验证：Qt 侧确切下限]`

### 版本节奏

- 版本号"只是**表面上**像语义化版本"：major 变更仅指 C++ API 不兼容；**middle 位变更意味着材质系统破坏性变更——"users need to rebuild their mat files"**，`MATERIAL_VERSION` 不匹配会 panic。`[已核实]`
- 材质编译器 `matc` **必须与运行时同一 release**："Make sure you always use tools from the same release as the runtime library."`[已核实]`

---

## 四、设备与图像的归属（本节为修订重点）

### 4.1 设备可以共享 —— 不需要 fork

`filament/backend/include/backend/platforms/VulkanPlatform.h` 里有嵌套结构 **`VulkanPlatform::VulkanSharedContext`**，注释原文：客户端可以实例化它并传给 `Engine::Builder::sharedContext` 以共享自己的 Vulkan 上下文，"**This is specifically necessary if the client wishes to override the swapchain API**"。

字段（经 Open3D v0.20.0 的 API 文档逐项交叉验证）：

```
VkInstance       instance
VkPhysicalDevice physicalDevice
VkDevice         logicalDevice
uint32_t         graphicsQueueFamilyIndex
uint32_t         graphicsQueueIndex
bool             debugUtilsEnabled / debugMarkersSupported / multiviewSupported
```

它以 **不透明 `void*`** 传入 `Engine::create()` / `Builder::sharedContext`（正因如此，Open3D 用一个"布局兼容的替身结构"来构造它，并注明"when filament is updated, keep in sync with filament/backend/include/backend/platforms/VulkanPlatform.h"）。

**含义**：可以让 **QRhi 建设备、Filament 共享它**，或者反过来。Qt 侧的 `QRhiVulkanNativeHandles` 两个方向都支持。**这条路上不需要 fork Filament。**

一个必须守住的约束（头文件注释）：客户端需要给 Filament **至少再分配一个 graphics 队列**；如果 GPU 只有一个 graphics 队列，"then the client needs to ensure that no concurrent access can occur"。

> 注：初版调研只扫了 `filament/include`（40 个公开头文件），因此漏掉了这一处——它位于 `backend/` 头文件树（会拖入 BlueVK）。这是"公开 API 不提供"与"平台层不提供"的区别。

### 4.2 呈现可以归宿主

`VulkanPlatform` 暴露了一组可覆写的虚函数，让宿主完全接管交换链与呈现：`createSwapChain(void* nativeWindow, uint64_t flags, VkExtent2D)`、`getSwapChainBundle()`（返回 `SwapChainBundle{VkImage colors[], depth, colorFormat, depthFormat, extent, layerCount, isProtected}`）、`acquire(SwapChainPtr, ImageSyncData*)`、`present(SwapChainPtr, uint32_t index, VkSemaphore finishedDrawing)`、`recreate`、`hasResized`、`getRequiredInstanceExtensions()`、`terminate()`，以及 `getInstance()`/`getDevice()`；还有 `getCustomization()` → `Customization{GPUPreference, isSRGBSwapChainSupported, flushAndWaitOnWindowResize, transitionSwapChainImageLayoutForPresent, timeBeforeEvictionFbo}`。

`[来源：子代理读取头文件；我独立验证了 VulkanSharedContext 的存在与字段，**未独立复现**这些虚函数签名，按单源对待]`

**含义**：**自持交换链与自持呈现这条能力是保得住的**——初版报告里把"自持交换链呈现"判定为"无路"是错的。你的 `VulkanPresenter`（`Qt/src/fg/VulkanPresenter.cpp`，976 行）不必推倒。

### 4.3 但仍然不交单张纹理的句柄

即便共享了设备，Filament 依旧**不暴露某张 `Texture` 底层的 `VkImage`**：40 个公开头文件里没有 `getVkImage`/`getTextureId`，`Engine::getBackend()` 只返回枚举；出向到 CPU 只有 `Renderer::readPixels`（原文："**intended for debugging and testing. It will impact performance significantly.**"，`Renderer.h:577`、`:663`）；入向的 `Texture::Builder::import` 只收 `GLuint` / `id<MTLTexture>`，**没有 Vulkan 分支**。

所以"把 Filament 渲好的一张图直接塞给 QRhi"这条路是**不通的**。真正通的是上面 4.2 那条：**让 Filament 渲染进宿主提供的图像**（覆写 `createSwapChain` 返回你自己的 `SwapChainBundle`，或让它渲进你指定的 RenderTarget）。方向要对——**不是从 Filament 取图，而是把图给它。**

### 4.4 于是真正剩下的缺口只有一个：深度 / 运动矢量 / jitter

后处理要接上，你的 FSR3.1 与插帧需要的是：低分辨率颜色、**深度**、**运动矢量**、jitter 偏移、曝光。其中：

- **颜色**：可得（就是你提供给它的那张图）。
- **jitter**：可得——FSR3 的 jitter 本质是投影矩阵的亚像素偏移，**相机矩阵由你构造**，你在交给 Filament 之前自己加偏移即可。
- **深度**：Filament 不暴露。
- **运动矢量**：Filament 内部有（TAA 的 motion-adaptive 历史剔除、history reprojection 依赖它），但**没有任何公开访问器**；TAA 的 jitter 是固定枚举（`RGSS_X4`/`UNIFORM_HELIX_X4`/`HALTON_23_X8`/`X16`/`X32`，默认 X16），不能注入自定义序列。

**结论**：深度与运动矢量这两项，你要么让 Filament 交出来（需要动它的源码），要么**在 Filament 之外用你自己的几何与矩阵再渲一遍**。后者不需要 fork，代价是把场景的光栅化做两遍、并让"场景几何"出现两份事实来源（Filament 的 `TransformManager` 与你速度 pass 的矩阵必须永远一致）。

---

## 五、能力对照

| 能力 | Filament v1.78.1 | 本项目现状 | 判定 |
| --- | --- | --- | --- |
| MSAA | `sampleCount` 默认 4，支持 `customResolve` | 有 | 持平 |
| FXAA | `View::setAntiAliasing`，**默认开启** | 有 | 持平 |
| TAA | 有，参数很多（feedback 0.12、historyReprojection、motionAdaptiveHistory、disocclusion…） | 自研 + 自定义 jitter | **收窄** |
| 自定义 jitter | 枚举内可选，**不能注入自定义偏移**（但你可以在相机矩阵上自己加） | 自主 | 可绕过 |
| 深度 / 运动矢量对外 | **不暴露** | 自持 `velocityPass` + `motion.vert` | **需自建** |
| FSR1（EASU+RCAS） | 内建，但只用于它自己的动态分辨率 | GL 路径上有 | 部分重复 |
| 动态分辨率 | `minScale{0.5,0.5}` / `maxScale{1.0,1.0}` / `sharpness 0.9`；LOW=双线性、MEDIUM=SGSR 1.0、HIGH·ULTRA=FSR1 | 自研 SSAA | 持平 |
| FSR 3.1 超分 | **没有** | 有 | **需自建输入** |
| 帧生成 / 光流插帧 | **没有** | 有 | **需自建输入** |
| **自持交换链呈现** | **有路**（覆写 `VulkanPlatform::acquire/present`，初版误判为"无路"） | 有（`VulkanPresenter` 976 行） | **可保留** |
| 自定义全屏 pass | 可在内部做（`View` → `RenderTarget` → 第二个 `View` + procedural quad，用 `uvToRenderTargetUV`）；`customSurfaceShading: true` 可接管 `surfaceShading()` | 完全自主 | 受限 |
| 注入内部管线 | 不行：`FrameGraph` 是内部框架，不是扩展点 | — | 受限 |
| 光照烘焙 | **无烘焙工具**（官方仍为 TODO："[TODO] Spherical-harmonics or spherical-gaussian lightmaps, irradiance volumes, PRT?"）；`cmgen` 只做 IBL/球谐；支持烘焙 AO 贴图 | 自研 `bake-archive-lighting.py` → 三张图集 | **无替代** |
| 材质系统 | 离线 `matc` 编 `.mat` → `.filamat`，一份 blob 覆盖所有后端；**版本须与运行时一致** | 手写 GLSL → Qt shadertools → `.qsb` | 收益项 |
| 文字 / UI | 无 | `Hud` + `Glyphs` | 不在范围 |
| 无窗口 / 按需渲染 | 支持：`createSwapChain(w, h, flags)` = headless；`beginFrame()` 返回 false 时可跳过也可照画 | 按需绘制 | 持平 |
| C++ API 文档 | **无公开 API reference**（`google.github.io/filament/api/` 404），只能读头文件 | — | 成本项 |

---

## 六、Filament 会替换掉什么（本地实测）

### 会被替掉

- **场景着色 378 行**：`opticalSurface.frag` 196 + `opticalGeometry.vert` 61 + `opticalCommon.glsl` 65 + `opticalFinalFragment.frag` 46 + `opticalQuad.vert` 10 → 改写成 `.mat`。
- **`RhiScene.cpp` 里约 550–700 行纯 QRhi 管路**：资源创建/上传（`:182-236`）、构造期管线与 SRB（`:236-354`）、render target 与绑定失效（`:366-402`）、纹理退役与封面上传（`:631-739`）、`bindings()`/`pipeline()`/`dynamicBuffer`（`:739-853`）、`geometry()`/`composite()`/`velocityPass()`（`:1051-1177`）。**但注意：其中 `velocityPass()` 若为保 FSR3 而必须自建，这部分不能算省下。**

### 不会被替掉

| 模块 | 行数 | 为什么 |
| --- | --- | --- |
| 后处理 `render/` + `fg/` + `fsr/` | **7,363** | Filament 无 FSR3/FG，也不给深度与运动矢量 |
| HUD 叠加层 | **5,001** | Filament 无文字、无 UI |
| 业务逻辑 | **8,518** | 与渲染无关 |
| 动画 / 拾取 | **854** | Filament 无动画系统、无拾取 |
| 后处理着色器 | 510 中的绝大部分 | 留在 QRhi 侧 |

### 关键：画面质感不来自光照模型，来自烘焙

- `opticalSurface.frag:25`："只插值烘焙光场的相邻高度切片；**没有实时光源求值、光线追踪或折射背景采样**"
- `bakedIllumination()`（`:26-32`）从 `lightAtlas` 取 `floor(v_lightUv.z)` 与 `+1` 两个高度切片做 `mix`；
- `keyLight()`（`:39-49`）只有一束正上方偏前的主光，"**场景没有实时阴影**"；
- 质感来自 `scripts/bake-archive-lighting.py` 写出的 `archive-baked-surface.bin`（`:92`）、`-light.bin`（`:125`）、`-normal.bin`（`:158`）。

**Filament 的 PBR / IBL / SSAO / CSM 解决的是本项目已经用离线烘焙绕过去的问题**，而它自己没有烘焙工具。迁移后要么保留烘焙观感（在 `.mat` 里采样你自己的三张图集），要么改实时（美术重调 + 失去可控性）。

---

## 七、成本量级（人日）

**锚点**：本项目自估 FG 自持交换链为 **20–33 人日**（`docs/fsr-integration-status.md` 第四节）；`third_party/` 已背 glslang + dxc，全量首次构建约 40 分钟。

| 项 | 范围 A |
| --- | --- |
| `VulkanPlatform` 子类：共享设备 + 自持交换链与呈现 + 队列同步 | 10–18 |
| 场景移植：`.mat` 改写 + JSON 绘制列表 → `RenderableManager` 实体桥接 + 相机 | 15–25 |
| **为保住 FSR3/插帧而自建深度 + 运动矢量 pass** | 8–15 |
| 烘焙管线重接（三张图集 → 材质参数） | 4–8 |
| 依赖冲突治理（见 §九：Filament 会装 glslang/spirv-tools） | 3–6 |
| 构建 / CI / 三平台（clang 17、`matc` 版本对齐） | 6–10 |
| 视觉基线与 9 个检查程序适配 | 4–8 |
| **合计** | **约 50–90 人日** |

**与初版的差异**：不再有 fork 的长期维护税（每年 40 个 release 的 rebase 风险消失），但多了"自建深度/速度 pass"这一项——**你想省掉的 550–700 行管路，有一半要以另一种形式请回来**。

---

## 八、如果真要推进：go/no-go 原型（5–8 人日）

只验证一件事：**Filament 能不能在 QRhi 的设备上、渲进 QRhi 的图里、并且这一帧完整走通你的后处理。**

1. QRhi 照现状建设备；读出它的 `VkInstance`/`VkPhysicalDevice`/`VkDevice`/队列索引（`rhi->nativeHandles()`）。
2. 用 `VulkanSharedContext` 让 Filament 共享这台设备（`Engine::Builder::sharedContext`），按注释给 Filament **单独的 graphics 队列**；GPU 只有一个队列时验证串行化方案。
3. 覆写 `VulkanPlatform::createSwapChain` / `getSwapChainBundle`，把 **你** 的 `VkImage` 交给它；或用 RenderTarget 方案。
4. **判定闸门 A**：一帧出现在 Qt Quick 里，GPU 上零回读，且 `RHINE_FG=on` 路径仍能呈现。只要退化成 `readPixels`，**立即否决**（1080p RGBA8 一帧 8.3 MB，官方明说 readPixels 显著影响性能）。
5. **判定闸门 B**：把 `OpticalSurface` 的烘焙观感在 `.mat` 里 1:1 复刻出来（三张图集作为材质参数 + `customSurfaceShading`）。复刻不出来，后面全无意义。
6. **判定闸门 C**：自建深度/速度 pass 与 Filament 的变换能否长期保持一致——这是最容易在半年后腐化的地方。

---

## 九、先例、风险与已核实的坑

### 先例：薄，但不是零

- **Open3D** 是最接近的真实参照：一个带 Qt GUI 的 C++ 3D 库，内部嵌入 Filament，并在 0.20.0 的 API 里公开了 `FilamentVulkanSharedContext`（即本文 §4.1 的交叉验证来源）。`[已核实]`
- 玩具级 Qt 集成：`nitronoid/qt_filament`（25★，"hello world example of using filament within a Qt window"）、`qt_filament_pbr`（10★）、`Tiantian-kaixin/filamentQt`（5★）、`akashkgarg/qtgraphics-filament`（1★）。`[已核实]`
- 官方 issue **#8605**"Support integrating Filament rendering into external OpenGL context / FBO (for JUCE or other UI frameworks)"：2025-04-08 开、**当天关**。报告者指出"Filament's rendering model assumes ownership over the swap chain and window surface"；维护者 poweifeng 回复"Platform 类就是干这个的，覆写 `OpenGLPlatform` 再传给引擎"，报告者追问"它到底是不是内部自建 HWND/HDC"，**再无回应**。`[已核实]`
- 另一条 **#5668**（2022）：某公司招人做 Qt/Windows 集成，开发者两周没能在一个 Qt 视口里渲出一个球，issue 被当作招聘帖当天关闭。`[已核实]`

**读法**：这条路有 API 支持、有 Open3D 这样的真实使用，但**没有一个可照抄的"Qt + Filament + 自持交换链 + 自研后处理"的完整样例**。

### 具体风险（都可核实）

1. **依赖冲突——这条对本项目是直接命中**：Filament 会安装 glslang / spirv-tools / spirv-cross，而本仓库 `third_party/` 已经背了 glslang + dxc。Filament 侧有两条**至今未关**的 issue：#5957"filament conflicts with other packages. please allow to use external dependencies"（2022-08-19 起）、#8965"filament installs spirv-tools which conflicts with the external package spirv-tools"（2025-07-17 起）。`[已核实]`
2. **Metal 是它最不稳定的后端**：标题含 metal 的 issue 有 **310** 条，未关的含 #10280（`lit` 着色模型在 Metal 上出现黑面，half 精度 NoV NaN 传播，2026-08-09）、#8229（`ClearOptions::clear=false` 时画面损坏）、#7588（Intel GPU 上 UBO 加载失败）、#6674（iOS 白屏）。**本项目 macOS 只有 Metal 一条路。**`[已核实]`
3. **渲染到外部 GL 纹理有已知问题**：#6248"GLError when using RenderTarget to render at an external GL texture"，2022-10-31 开至今未关。若考虑 GL 后端作为退路，这条要先验。`[已核实]`
4. **线程模型**：Engine 自带渲染线程与若干工作线程，且"not thread-safe"；`Platform` 的回调在 **Filament 的渲染线程**上调用，与 Qt 的渲染线程是两个。`[已核实]`
5. **构建税**：`matc` 必须与运行时同版本；`FILAMENT_ENABLE_RTTI` 默认 OFF（本项目若依赖 RTTI 需改）；无公开 C++ API 文档。`[已核实]`

---

## 十、仍未验证

- **`libfilament` 实际体积与构建耗时**：release 资产 `linux.tgz` 76,777,225 字节（含库 + 头 + 主机工具），单库体积与构建时间官方无数据，需实测。（Filament 有 CI 体积守卫，默认阈值 20 KB，说明体积被认真对待。）
- **Qt 6.12 的 OpenGL RHI 后端确切下限**（决定 GL 回退是否会因 Filament 的 4.1 要求而失效）。
- **`VulkanPlatform` 那组可覆写虚函数的逐字签名**：我独立验证了 `VulkanSharedContext` 的存在与字段，虚函数清单目前是单源。
- **同一 `VkDevice` 上两个提交栈的实际可行性**：队列交错、内存分配器、图像布局/屏障交接，均未验证。官方注释只给了"至少多一个 graphics 队列，否则要保证无并发访问"这一句。
- **GPU 只有单个 graphics 队列时的行为**（集显/部分 Intel）——这可能直接淘汰一部分目标机器。
- **是否有 FSR2/FSR3 的社区修改**：未找到可信来源，不要把它当依据。

---

## 十一、一句话回答

**"Filament 好不好"：好，而且比我第一版判断的更好——它是三个候选里唯一真为"嵌进别人应用"设计的，且确实能把设备共享给宿主、把呈现留给宿主，不需要 fork。**

**"该不该换"：仍然不该，但理由要说得准。** 不是接不进来，而是**接进来之后，为了保住 FSR3.1 超分与插帧，你得在 Filament 之外再渲一遍深度和运动矢量**——等于把 `RhiScene.cpp` 里那 550–700 行管路省下一半，又在另一处重建一半，同时还多背一个 37 个第三方模块、会与你的 glslang 打架、Metal 后端有 310 条 issue 的依赖。而它**完全省不掉**的仍是那 7,363 行后处理、5,001 行 HUD 与 854 行动画拾取。

**最该做的仍然是那三件老事**：AA 矩阵从七种收窄、`fg/`+`fsr/` 的可裁剪性做实、HUD 换成 Qt Quick 原生文字。三件加起来，成本是这次迁移的一个零头。


---

## 十二、功能清单：失效 / 需重实现 / Filament 自带替代

> 分类依据：代码实际行为，非接口猜测。**C 可删**（Filament 有等价物）、**B 必须重写**（Filament 没有，但你必须保住）、**A 会退化**（Filament 给不了，且不值得重造）。

### C. Filament 自带替代（这些代码可以删）

| 功能 | 现在的实现 | Filament 对应物 | 保留度 |
| --- | --- | --- | --- |
| 场景材质与着色 | `opticalSurface.frag` 196 + `opticalGeometry.vert` 61 + `opticalCommon.glsl` 65 | `.mat` + 着色模型（lit / unlit / subsurface / cloth / specularGlossiness） | 结构可替，**观感要自己复刻** |
| 场景最终合成 | `opticalFinalFragment.frag` 46 + `opticalQuad.vert` 10 | View 后处理链 / 第二个 View 的全屏 pass | 可替 |
| QRhi 管路 | `RhiScene.cpp` 约 550–700 行（管线、SRB、render target、纹理退役、`dynamicBuffer`、`instance`） | Engine / Scene / View / Renderer / RenderableManager | **主要收益项** |
| 批处理与剔除 | `prepare()` / `batchDraws()` 约 146 行 | RenderableManager + TransformManager 的自动视锥剔除与实例化 | 可替 |
| MSAA | `samples()`：`RHINE_AA_MODE=msaa` + `RHINE_MSAA`(2–8) + `rhi->supportedSampleCounts()` | `MultiSampleAntiAliasingOptions`（sampleCount 默认 4，`customResolve`） | 部分：上限由它决定，**不保证 8×** |
| FXAA | `aaFragment.frag` + fxaa 分支 | `View::setAntiAliasing`（**默认开启**） | 可替 |
| TAA | `taa.frag` + `m_history[2]` 双历史缓冲 | `setTemporalAntiAliasingOptions`（feedback / historyReprojection / motionAdaptiveHistory / disocclusion…） | 可替，**但 jitter 不可注入**（见 A） |
| 分辨率缩放 | `RHINE_RENDER_SCALE`(50–100) × `RHINE_SUPERSAMPLE`(1–2) | `setDynamicResolutionOptions`（`minScale` / `maxScale` / `sharpness`） | 部分（见 A） |
| FSR1 EASU+RCAS | `fsr1_easu.frag` + `fsr1_rcas.frag` + `Fsr1Constants` | `QualityLevel` HIGH（移动优化）/ ULTRA（标准 FSR1） | 部分：**只能作它自己的动态分辨率上采样器** |
| 材质编译与跨后端变体 | Qt shadertools → 每后端一份 `.qsb` | `matc` 一份 `.filamat` 覆盖 GL / Vulkan / Metal | **净收益**（少一套 per-backend 变体管理） |
| GPU 帧计时 | `FrameProfiler` | `Renderer::getFrameInfoHistory()` | 部分 |

### B. 必须重新实现（Filament 完全没有）

| 功能 | 现在的实现 | 为什么必须自己做 |
| --- | --- | --- |
| **深度 + 运动矢量 pass** | `MotionPass.cpp` + `motion.vert` + `velocity.frag`（"共用深度和速度输出；历史按实例稳定位置匹配，并包含上一帧相机变换"） | Filament 内部有速度缓冲，但**无任何公开访问器**。不重建，TAA / FSR3 / 插帧全部失去输入 |
| **FSR 3.1 超分** | `Fsr3Backend.cpp` + `fsr/` 785 行 | 无 FSR2/FSR3。后端可保留，输入要改成自建的 depth/velocity |
| **FSR 帧生成 + 光流** | `fg/` 2,876 行 + `FrameGenerator` 契约（`prepare(color, depth, motion)`） | 无插帧、无光流、无 FG 概念 |
| **自持交换链与呈现** | `VulkanPresenter.cpp` 976 行 + `PresentationShell` | 有替代路径，**但要改形态**：写成 `VulkanPlatform` 子类（`createSwapChain` / `getSwapChainBundle` / `acquire` / `present`） |
| **即时模式 → 保留模式桥接** | `Engine::frame()` 返回 `QJsonObject`，每帧描述绘制 | Filament 是实体/组件模型，需要实体池 + 每帧同步 transform，不能每帧重建实体 |
| **烘焙观感** | `bakedIllumination()` 高度切片插值 + `keyLight()` 单主光 + 三张图集 | Filament **没有烘焙工具**（官方仍是 TODO）；要么在 `.mat` 里采样你的图集，要么改实时 |
| **CPU 拾取** | `NativePicking.cpp` 249 行（AABB 射线求交） | Filament 无拾取 API |
| **动画 / 时间线** | `BootTimeline` 215 + `SceneMotion` 265 + `SceneDrag` 125 | Filament 无动画系统 |
| **封面 / 音乐纹理生命周期** | `musicDraws()` / `updateMusic()` / `retire()` / `releaseCover()` | 要映射到 Filament 的 `Engine::destroy` 语义与 GPU 资源回收 |
| **HUD 全套** | `Hud` + `Glyphs` + `NativeHud*` 共 5,001 行 | Filament 无文字、无 UI。**一行不动，也一行不省** |
| **离屏参考帧** | `renderReference()`（golden frame 比对） | 无对应物；视觉回归体系要重写 |
| **调试与遥测** | `RHINE_DEBUG_DRAWS`、`recordRender`、`RenderTelemetry`、9 个检查程序 | 部分可映射（`getFrameInfoHistory`），其余自建 |
| **线程模型** | 单一 Qt 渲染线程 | Engine 自带渲染线程 + 工作线程且 "not thread-safe"；`Platform` 回调在 **Filament 的**渲染线程上 |

### A. 会退化 / 失效（Filament 给不了，也不建议重造）

| 功能 | 现状 | 迁移后 |
| --- | --- | --- |
| **自定义 TAA jitter 序列** | 自主生成，反向传给 FSR3 的 jitter 偏移 | jitter 是**固定枚举**（`RGSS_X4` / `UNIFORM_HELIX_X4` / `HALTON_23_X8`/`X16`/`X32`，默认 X16），不能注入序列。可绕过（自己扰相机投影矩阵），但那已不是"保留" |
| **FSR1 单独锐化（RCAS-only）** | `FsrSharpness` 允许只跑 RCAS | FSR1 必须 EASU+RCAS 一起用，不能只要锐化 |
| **锐化随放大倍数自适应衰减** | `effectiveSharpnessPercent()` 按 `1/√放大倍数` 衰减（1×=100%、2×≈71%、3×≈58%、4×=50%、8×≈35%），注释写明是为压暗色封面上的亮环 | Filament 的 sharpness 是**平的 0.0–2.0 滑块**，没有这层自适应。要保住得在调用侧自己算 |
| **FSR 质量预设的自定义除数** | `super=3.0` / `performance=2.0` / `balanced=1.7` / `quality=1.5` | 只有它内建的几档，自定义除数不复存在 |
| **真超采样（>1.0 渲染倍率）** | `RHINE_AA_SCALE` 可到 200%、`RHINE_SUPERSAMPLE` 可到 2× | 动态分辨率 `maxScale` 默认 1.0；FSR/SGSR 只在缩小方向有意义。**超出是否可用待验证** |
| **老 GL 硬件覆盖** | GL 回退下限由 Qt 决定（低于 4.1） | Filament 桌面要求 **GL 4.1+**，靠 GL 回退活着的旧机器可能直接跑不了 |
| **7 种 AA 互斥矩阵的语义** | `off`/`fxaa`/`msaa`/`ssaa`/`taa`/`fsr1`/`fsr3`（+`metalfx`）自由切换 | 会变成**两套 AA 并存**（Filament 的 MSAA/FXAA/TAA + 你的 FSR/后处理），必须明确"谁负责"，否则重复处理。Filament 亦明说 FSR1 要求 "well anti-aliased (MSAA or TAA), noise free — **Avoid FXAA and dithering**" |
| **Metal 后端稳定性** | 自研 Metal 路径 + MetalFX | 310 条 metal 相关 issue：黑面（#10280）、画面损坏（#8229）、Intel GPU UBO 失败（#7588）、白屏（#6674）。**风险而非失效** |

### 三类的一句话总结

- **能删的**主要是"画场景"这层：378 行着色 + 550–700 行管路 + 146 行批处理，**约 1,000 行级**。
- **必须重写的**是"把场景接进你的后处理"这层：深度/速度 pass、即时转保留模式的桥接、交换链形态改造，**约 600–900 行级**，外加 7,363 行后处理的**输入改造**。
- **真正失效的**都是"因为完全掌控管线才存在"的细节：自定义 jitter、RCAS-only、锐化自适应、自定义质量除数、超采样上限。单看都很小，合起来正是这套渲染器的手感来源。
