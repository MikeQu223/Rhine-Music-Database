# 04 · 工具、测量与真实案例：核显 Vulkan 呈现链路

> 范围：只谈 **Vulkan 链路本身**（API 用法、驱动交互、同步与提交、内存与带宽、呈现与帧节奏、工具与测量）。
> 不涉及 3D 场景优化（LOD / 剔除 / 批处理 / 光照 / 后处理配方），只在解释机制时顺带提及。
> 证据等级：〔规范〕= Vulkan 规范/扩展文本；〔厂商文档〕= Khronos/AMD/Intel/Arm/NVIDIA/Microsoft 官方文档；〔实测案例〕= 有可追溯 issue/PR/演讲的具体数字；〔社区经验〕= 通行做法，无一手数字。
> 所有数字都带来源链接；没有把握的一律写量级或标注「未验证」。

---

## 0. 结论速览

1. **先建立"链路地板"，再谈优化**。保留完整 present 链、把内容换成最小帧，测出的帧时间就是链路地板。判据不是"地板和刷新率比"，而是：地板是否已吃掉目标帧预算的绝大部分（经验阈值：<10% 才算合格），以及地板自身的 p99/p50 是否接近 1。地板不合格时，任何内容侧优化都无效。〔方法论，见 §B.4〕
2. **核显上 90% 的"慢"要先分到三段**：CPU 提交、GPU 执行、呈现/合成。PresentMon 的 `MsCPUBusy / MsGPUBusy / MsInPresentAPI` 三段就能做初判，不需要 profiler。〔厂商文档〕[PresentMon 指标定义](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md)
3. **profiler 在核显上不可靠这件事本身是事实**：AMD 官方明确 RGP 不支持 <3 CU 的设备，且只支持 RDNA（GCN 的 APU 直接不支持）。〔厂商文档〕[rdpanel#62](https://github.com/GPUOpen-Tools/radeon_developer_panel/issues/62)
4. **别用 RenderDoc 的时间轴当性能数据**。它是抓帧调试器，重放会改变时序；时间结论要用 PresentMon / GPUView / RGP / Tracy。〔社区经验〕[renderdoc.org](https://renderdoc.org/)
5. **present 阻塞是最常见的"核显假瓶颈"**。`MsInPresentAPI` 高而 `MsGPUBusy` 低 = 你在等呈现（驱动/合成器的节流或队列满），不是 GPU 慢。**不要**用"fps 是否贴住刷新率"来判断——刷新率未知。〔厂商文档〕[PresentMon](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md)
6. **FSR3 帧生成会把"帧率"和"延迟"解耦**。开了 FG 之后 FPS 翻倍但 input-to-photon 可能变差，必须分开测。〔厂商文档〕[FSR FG Swapchain](https://gpuopen.com/manuals/fsr_sdk/techniques/frame-interpolation-swap-chain/)
7. **验证层不是性能工具，但 Best Practices 是**：它专门标"语法正确但性能可疑"的用法。〔厂商文档〕[VVL best_practices.md](https://github.com/KhronosGroup/Vulkan-ValidationLayers/blob/main/docs/best_practices.md)
8. **Intel GPA 已 EOL**（2025.1 为最终版，2026 停止分发），可以当下用，不要写进长期流程。〔厂商文档〕[Intel GPA](https://www.intel.com/content/www/us/en/developer/tools/graphics-performance-analyzers/overview.html)
9. **目标是"最小化排队与阻塞"，不是"对齐某个刷新周期"**。未知刷新率下，唯一可控的是提交次数、队列深度、present 阻塞时长。

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。因此本文不把"限帧省电/避免降频"作为建议，也不使用"fps 与刷新率的关系"作为判据。

---

## A. 工具矩阵

### A.0 该做什么 / 别做什么

**该做**
- 固定「一个计时工具 + 一个抓帧工具 + 一个系统级工具」三件套：计时用 PresentMon（Win）/ MangoHud（Linux），抓帧用 RenderDoc，系统级用 GPUView 或 Tracy。
- 每次实验只改一个变量，并记录：`present mode`、vsync **状态**、**是否设了帧率上限（默认不设上限）**、分辨率、是否插电（仅作环境记录）。

**别做**
- 别用抓帧工具的 duration 列排名优化项（重放会放大/缩小不同 pass 的相对成本）。
- 别在没有 `PresentMode` 列的情况下比较两次运行的 FPS——窗口合成路径变了，结论就作废。
- 别把"电源模式/是否插电"写成结论依据：它只影响数据可比性，不构成"该限帧"的理由。

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

### A.1 总表

| 工具 | 能回答 | 不能回答 | 核显上的坑 |
|---|---|---|---|
| RenderDoc | 这一帧的每个 draw/dispatch 参数、状态、barrier、layout transition、资源内容 | GPU 真实耗时、present/显示延迟、带宽 | 抓帧本身吃共享内存带宽；4K 大帧 capture 可能耗尽系统内存 |
| RGP（AMD） | per-event 时间、barrier、pipeline stall、occupancy、async compute | 非 AMD、非 RDNA；<3 CU 设备 | 官方：<3 CU 不支持、GCN APU 不支持〔厂商文档〕 |
| Intel GPA | 多帧流抓取 + 逐 draw 分析（Frame Analyzer） | 非 Intel GPU；未来版本 | 2025.1 后 EOL，2026 停分发 |
| Arm Streamline / Mali Offline Compiler | Mali 上的系统级 trace / 离线 shader cycle 估算 | x86 核显（架构不同） | 对 Intel/AMD 核显无意义；但 tile 思维可迁移 |
| Nsight Graphics | NVIDIA 上的 GPU Trace、逐事件、ray tracing | 非 NVIDIA GPU | 核显上完全不可用 |
| Tracy | CPU+GPU zone 时间线、帧直方图、锁竞争 | 系统级 present/display 时间 | 需插桩，插桩本身有开销 |
| PresentMon | CPU/GPU/显示三段耗时、present mode、input-to-photon | 单 draw 级归因、GPU 计数器 | 需 "Performance Log Users" 组权限 |
| GPUView / ETW | DMA packet 排队、vsync 间隔、页错误、上下文切换 | 单 draw 归因；非 Windows | ETL 几百 MB；需 ADK；符号配置烦 |
| PIX | D3D12 呈现路径、Present 事件、GPU 队列 | Vulkan | 只对 D3D 有意义，Vulkan 项目仅作「Windows 呈现机制」参考 |
| Mesa `INTEL_DEBUG` / `AMD_DEBUG` | 驱动内部行为（perf 提示、PC flush、DCC 开关） | 端到端帧时间 | 这些开关会**改变**行为，不能用来算收益 |
| vulkaninfo | 队列族、present mode 列表、format、limits、heap | 性能 | iGPU 的 DEVICE_LOCAL 是系统内存，别当显存看 |
| MangoHud | 实时 FPS/frametime/GPU 负载、日志绘图 | 精确归因 | overlay 自身有开销，且可能影响 pacing |
| apitrace | API 调用序列记录/重放、数 submit 次数 | 计时 | 大 trace 回放慢；Vulkan 支持成熟度需自行确认〔未验证〕 |

### A.2 逐工具要点

**RenderDoc** 〔社区经验〕[renderdoc.org](https://renderdoc.org/)
- 定位：独立抓帧调试器，支持 Vulkan/D3D11/D3D12/GL/GLES，Windows/Linux/Android，capture 可跨平台携带，有 Python API。
- 在链路调查里的正确用法：**数事件、看同步、看 layout**。例如「这一帧有几个 `vkQueueSubmit`」「present 前有没有多余的 `vkCmdPipelineBarrier`」「swapchain image 的 layout 转换发生在哪」。
- 不能：给 GPU 时间。它的 duration 是重放环境的产物。
- 核显坑：抓帧时应用会停在世界里重放，iGPU 上重放成本被放大；抓 4K + FSR FG 的帧，capture 文件可能上 GB。

**AMD Radeon GPU Profiler (RGP)** 〔厂商文档〕[gpuopen.com/rgp](https://gpuopen.com/rgp/)
- 能：detailed timing、per-event 时间、barrier、pipeline stall、async compute；支持 DX12/Vulkan/OpenCL/HIP。
- APU 支持是真的：官方 release note 明确写了 "Support for additional AMD RDNA 3.5 architecture-based APUs (AMD Ryzen AI Max … with Radeon 8000S graphics)"。
- **坑（必须记住）**：官方在 issue 里写明 "Radeon Developer Panel does not support RGP capture on devices with less than 3 CUs"，且 "only supports devices using AMD RDNA architecture"（举例 5700u 是 GCN，不支持）；CU 限制的原因是 "firmware issues on these smaller devices that could impact the data collection and accuracy"。〔厂商文档〕[rdpanel#62](https://github.com/GPUOpen-Tools/radeon_developer_panel/issues/62)
- 推论：入门核显（2 CU 级别）上你**拿不到** RGP，只能退回 PresentMon/GPUView/ETW。

**Intel GPA / Frame Analyzer** 〔厂商文档〕[Intel GPA](https://www.intel.com/content/www/us/en/developer/tools/graphics-performance-analyzers/overview.html)
- 能：Graphics Frame Analyzer "Visualize multiframe stream captures and select a frame to analyze down to the draw call level"；目标 API 含 DirectX / OpenGL / Vulkan；支持到 Vulkan SDK v1.4.304.0。
- 坑：官方公告 "Intel GPA 2025.1 is the final version… downloadable until the end of 2025 and will be discontinued in 2026"。**不要把它当长期依赖**。

**Arm Performance Studio（Streamline / Mali Offline Compiler）** 〔厂商文档〕[Arm best practice 博客](https://developer.arm.com/community/arm-community-blogs/b/mobile-graphics-and-gaming-blog/posts/arm-best-practice-warnings-in-vulkan-sdk)
- Streamline：系统级 CPU/GPU trace（细节本次未抓取原文，〔未验证〕）。
- Mali Offline Compiler：离线编译 shader 出 cycle 估算，不跑应用（同上〔未验证〕）。
- 对 x86 核显的直接价值 ≈ 0（架构不同）；**间接价值**是 tile-based/带宽受限的思维，以及下面这条：Arm 把已废弃的 PerfDoc 层并入了 Khronos 验证层，可以在桌面 PC 上预检 Mali 友好性。

**NVIDIA Nsight Graphics** 〔厂商文档〕[developer.nvidia.com/nsight-graphics](https://developer.nvidia.com/nsight-graphics)
- 能：D3D/Vulkan/OpenGL/OpenXR 的调试与 profile，GPU Trace，官方称 "minimal overhead for non-biased activity data"。
- 坑：NVIDIA GPU 专属；在 Intel/AMD 核显上零覆盖。

**Tracy** 〔社区经验〕[wolfpld/tracy](https://github.com/wolfpld/tracy)
- 定位："real time, nanosecond resolution, remote telemetry, hybrid frame and sampling profiler"，支持 Vulkan/D3D/GL/Metal 的 GPU zone。
- 链路调查用法：把 `acquire → submit → present` 三段打 zone，直接看哪段在墙钟上占时间；配合帧直方图看抖动。
- 坑：需要源码插桩；插桩粒度太细会自己制造 CPU 开销。

**PresentMon** 〔厂商文档〕[GameTechDev/PresentMon](https://github.com/GameTechDev/PresentMon)
- 系统级 ETW 采集，不改应用；CPU、GPU、Display 三段耗时与延迟；跨 DirectX/OpenGL/Vulkan。
- 权限坑：需要 "Performance Log Users" 组成员身份，否则报 "failed to start trace session (access denied)"。

**GPUView / ETW** 〔厂商文档〕[Microsoft Learn](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/using-gpuview)
- 能：CPU 上下文切换 + 内核进出 + DXGK 的全部 GPU 事件（command buffer 提交、资源创建/销毁/lock/bind）+ 驱动上报的 command buffer 起止时间 + 每个 adapter 的 vsync 间隔 + 页错误。
- 用它回答一个问题：**"GPU 队列里到底有没有活"**。队列空 → CPU 提交受限或呈现受限；队列持续非空 → GPU 受限。
- 附带能力：每条 adapter 的 vsync 间隔是**分析侧**唯一可靠的刷新率来源。应用运行时拿不到刷新率，但调查时可以用它把"是否被节流"量化。
- 坑：`Log.cmd` 录 30–60 秒就够，ETL 可能几百 MB；XPerf 读不了 GPU 事件；`Log m` 会跳过高频事件（trace 更小但细节少）。

**PIX** 〔厂商文档〕[devblogs.microsoft.com/pix](https://devblogs.microsoft.com/pix/)
- 官方定位即 "Performance tuning and debugging for DirectX 12 games on Windows"。
- 对 Vulkan 项目只有一个用途：**理解 Windows 呈现/合成机制**（Present → DWM → 显示），以及看别人 D3D12 案例里的呈现路径问题。别指望它挂到你的 Vulkan 帧上。

**Mesa：`INTEL_DEBUG` / `AMD_DEBUG`** 〔厂商文档〕[docs.mesa3d.org/envvars](https://docs.mesa3d.org/envvars.html)
- `INTEL_DEBUG=perf`："emit messages about performance issues"；`pc` 输出 PIPE_CONTROL 使用；`bat` 输出 batch 信息；`nofc`/`noccs` 关 fast clear / 无损压缩（用于**隔离**压缩相关行为）。
- `AMD_DEBUG=info` 打印驱动信息；`nodcc` 关 DCC；`nohyperz` 关 Hyper-Z；`notiling` 关 tiling。
- **纪律**：`nodcc`/`nohyperz`/`nofc` 都是"把快路径关掉"，只能用来定位某类带宽优化是否生效，**绝不能**用它们的帧率当基线。

**vulkaninfo** 〔厂商文档〕[KhronosGroup/Vulkan-Tools](https://github.com/KhronosGroup/Vulkan-Tools)
- 查：队列族与 `queueFlags`、`vkGetPhysicalDeviceSurfacePresentModesKHR` 实际返回的 present mode 列表、format、limits、memory heap。
- 核显坑：iGPU 的 `DEVICE_LOCAL` heap 其实是系统内存的一段，heap 大小不等于可用显存；`VK_EXT_memory_budget` 的值更接近真实预算。

**MangoHud** 〔社区经验〕[flightlessmango/MangoHud](https://github.com/flightlessmango/MangoHud)
- Vulkan/OpenGL overlay：FPS、温度、CPU/GPU 负载；有 Vsync 段（含 "Vulkan Vsync"）；支持 FPS logging + 绘图。
- 坑：overlay 自己会画一帧，且在某些合成器下影响 present；对比实验时要么全关，要么全程开。

**apitrace** — 记录/重放 API 调用流，用来数 `vkQueueSubmit` 次数、确认调用顺序。计时不可信。〔未验证：本次未抓取原文，使用前请自行确认 Vulkan 支持范围〕

### A.3 三套组合

- **Windows + AMD 核显（≥3 CU）**：PresentMon → RGP（判 GPU 侧）→ GPUView（判队列是否空）。
- **Windows + Intel 核显**：PresentMon → GPUView → GPA Frame Analyzer（一次性深挖，注意 EOL）→ RenderDoc（看同步/状态）。
- **Linux（Mesa/ANV/RADV）**：MangoHud（粗测）→ Tracy 或 `INTEL_DEBUG=perf`（归因）→ RenderDoc（抓帧）→ `vulkaninfo`（能力核对）。

---

## B. 判定瓶颈归属的方法论

### B.0 该做什么 / 别做什么

**该做**：先按"三段耗时"分流，再用对照实验证伪；每个结论都要能用一个独立的实验推翻。
**别做**：不要用「GPU 利用率 100%」当 GPU 受限的证据——核显的利用率口径（尤其 Windows 任务管理器）不可靠；也不要用「CPU 占用低」排除 CPU 提交受限（单线程主循环的瓶颈常体现为等待，不是占用）；更不要用"fps 接近某个数"推断刷新率。

> 功耗只是背景（不作决策依据）：核显与 CPU 共享封装功耗预算，长时间满载可能触发频率回退，让同一实验的前后半段数据漂移。记录插电状态与运行时长是为了**数据可比性**；本项目不因功耗限帧或降负载。

### B.1 指标定义（全部来自 PresentMon，单位 ms）

| 指标 | 定义（原文） | 用途 |
|---|---|---|
| `MsBetweenPresents` | 相邻两次 Present 的间隔 | 应用侧帧率口径 |
| `MsCPUBusy` | "how long the CPU spent working on this frame before presenting" | CPU 提交受限的分子 |
| `MsCPUWait` | 提交前 CPU 等待的时间 | 等 fence/等 acquire 的直接证据 |
| `MsGPUBusy` | "time during which at least one GPU engine is executing work from the target process" | GPU 受限的分子 |
| `MsGPUTime` | GPU 处理该帧的总时长（含空转） | 与 Busy 的差 = GPU 空转 |
| `MsGPULatency` | 帧开始到 GPU 开始处理 | 排队深度 |
| `MsInPresentAPI` | "time spent inside the Present() call" | **present 阻塞的直接证据** |
| `MsRenderPresentLatency` | Present 调用 → GPU 工作完成 | 渲染尾部 |
| `MsUntilDisplayed` | Present 调用 → 上屏 | 呈现链路总延迟 |
| `DisplayedTime` | 该帧在屏上停留时长（未显示为 NA） | 帧节奏是否均匀 |
| `MsBetweenDisplayChange` | 上一次显示变化到这一次 | 观察呈现节流的**离散性**（不是与刷新率相除） |
| `MsClickToPhotonLatency` | 最早的相关鼠标点击 → 上屏 | input-to-photon |
| `MsAllInputToPhotonLatency` | 最早的键鼠输入 → 上屏 | 同上（更全） |

〔厂商文档〕[PresentMon README-ConsoleApplication.md](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md)

**统计口径必须写清楚**：
- `avg FPS` = 总帧数 / 总时长，会被长尾和"突发高帧"同时污染。
- `p99 帧时间` = 帧时间分布的第 99 百分位；`1% low` 有两种通行定义（最慢 1% 帧的**平均**，或第 99 百分位）。同一次实验里必须固定一种，否则两次结论不可比。〔社区经验〕
- `frametime jitter`：帧时间标准差，或相邻帧差分的分布宽度。对 FG/自建 pacing 来说，jitter 比 avg 更能反映体感。
- `input-to-photon`：唯一能反映"手感"的指标；FG 场景下它与 FPS 会反向变化。

### B.2 四类受限的判据（刷新率未知版）

| 判据 | CPU 提交受限 | GPU 受限 | 呈现受限 | 帧生成受限 |
|---|---|---|---|---|
| `MsCPUBusy` | 高（接近帧间隔） | 低 | 低 | 低~中 |
| `MsGPUBusy` | 低 | ≈ 帧间隔 | 低 | ≈ 帧间隔 |
| `MsInPresentAPI` | 低 | 低 | **高** | 中（pacing 线程在等） |
| submit 区段耗时（Tracy zone） | >20% 帧时间 | 低 | 低 | 低 |
| GPUView 里未完成的 DMA packet | 浅、经常空 | 持续非空且随内容增长 | 周期性清空 | 周期性清空 |
| `DisplayedTime` 分布 | — | 连续、宽 | **单峰、离散**（被外部节流） | 长短交替（2×真实帧率） |

判读规则：
- **不要**比较"fps 与刷新率"。刷新率运行时不可得，且 FIFO 在不同驱动/合成器上可能按真实刷新节流，也可能等价于 immediate（见 B.3）。
- "被外部节流"只能从**分布形状**判断：`DisplayedTime` / `MsBetweenDisplayChange` 若在多次运行中反复落在同一组离散值上（方差极小），说明有外部时钟在决定上屏时机；此时瓶颈在呈现，不在渲染。
- 队列深度是比"利用率"更可靠的 GPU 受限证据：持续有未完成的 packet 且 `MsGPUBusy` 贴着帧间隔 → GPU 受限。

〔厂商文档〕前三行指标定义来自 PresentMon；PresentMode 取值：`Hardware: Legacy Flip`、`Hardware: Independent Flip`、`Composed: Flip`、`Hardware Composed: Independent Flip`、`Composed: Copy with GPU GDI`、`Composed: Copy with CPU GDI`。
**规则**：一旦从 `Hardware: Independent Flip` 掉到 `Composed:*`，你就多了一次合成拷贝，这是"呈现受限"的硬证据，不是渲染慢。

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

### B.3 对照实验：present mode × 帧率上限（cap）

刷新率未知，所以矩阵的一方不是"刷新率"，而是**你自己设的、可复现的 cap**（例如取地板帧率的 1× 与 2×，或固定 60/120）：

| | 不设上限 | cap = N | cap = 2N |
|---|---|---|---|
| FIFO | ① | ② | ③ |
| MAILBOX | ④ | ⑤ | ⑥ |
| IMMEDIATE（若能拿到） | ⑦ | ⑧ | ⑨ |

读法（全部基于"排队与阻塞"，不基于刷新率）：
- **⑦ vs ①**：若 ⑦ 明显快于 ①，说明 FIFO 在被节流（值多少未知，也不重要）；若两者接近，可能是内容本身已到上限，也可能是 FIFO 在此平台等价于 immediate——用 B.2 的"分布形状"再确认。
- **① 的 `MsInPresentAPI` 高而 `MsGPUBusy` 低** → 呈现受限；此时**不要**下结论说"关掉 vsync 就会更快"，因为节流可能来自合成器/驱动而非应用选项。
- **④ 下 GPU 常驻高但内容很轻** → mailbox 空转重绘（§D.2）。它的危害是**测量失效与队列膨胀**（你测到的不是有效工作量），处理方式是换 IMMEDIATE/FIFO 或引入显式 pacing，不是"为了省电而限帧"。
- **⑤/⑥ 的意义**：cap 是**可控变量**，用来把"排队深度"和"GPU 真实能力"分离。cap 后 p99 显著改善 → 瓶颈是排队而非算力；cap 后 p99 不变 → 瓶颈在 GPU 或提交侧。

〔规范〕present mode 语义：[Vulkan WSI 章节](https://docs.vulkan.org/spec/latest/chapters/VK_KHR_surface/wsi.html)：FIFO 的原文是 "the presentation engine waits for the next vertical blanking period to update the current image… one request is removed from the beginning of the queue and processed during each vertical blanking period"，且是**唯一必须支持**的 present mode。注意这段描述的是**行为**，不是"一定是 60Hz"——vblank 多久由系统决定，应用看不到。

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

### B.4 测「链路开销」而不是「场景开销」

**空场景法（floor test，§B.5 的通过标准以此为准）**
1. 保留：swapchain 创建/重建、acquire、submit、present、FG 上下文、上采样 pass、Qt 的合成/呈现回调。
2. 替换：内容换成 `loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR` + 无 draw，或一个全屏三角形。
3. 记录：`MsCPUBusy`、`MsGPUBusy`、`MsInPresentAPI`、`MsBetweenPresents` 的 p50/p99，以及 `MsInPresentAPI / MsBetweenPresents` 的占比、GPUView 的队列深度。
4. 通过标准（三条同时满足）：
   - (a) 地板帧时间 ≤ 目标帧预算的 10%（经验阈值；例：目标 120fps 即预算 8.3ms，地板应 ≤0.8ms）；
   - (b) 地板 p99/p50 ≤ 1.2（无周期性阻塞）；
   - (c) `MsInPresentAPI` 占地板帧时间的比例 ≤ 10%。
   任一条不满足 → 链路本身有问题，先修链路再谈内容。

**逐项开关法（ablation）**
- 顺序：全开 → 关 FG → 关上采样 → 关 overlay → 关 Qt 额外 pass → 只留 clear。
- 每一步只改一项，记录 ΔCPU / ΔGPU / Δpresent 阻塞时长。
- 判据：某开关让 `MsCPUBusy` 降而 `MsGPUBusy` 不变 → 该项在 CPU 侧（提交/同步/pacing）；反之在 GPU/带宽侧。

**为什么必须这么做**：核显的 CPU 与 GPU 共享内存控制器与带宽，场景复杂度和链路开销会互相污染；不做 ablation，你无法把"渲染变快了"和"提交变少了"分开。〔方法论，社区经验〕

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

### B.5 FSR3 帧生成的测量特殊性

- FSR FG (Swapchain) 在 Vulkan 上会**替换应用的 `VkSwapchainKHR`**，并返回替换过的 `vkGetSwapchainImagesKHR / vkAcquireNextImageKHR / vkQueuePresentKHR / vkSetHdrMetadataEXT` 函数指针。〔厂商文档〕[FSR FG Swapchain](https://gpuopen.com/manuals/fsr_sdk/techniques/frame-interpolation-swap-chain/)
- 它内部起 **2 个额外 CPU 线程**：一个"不阻塞应用地等插值完成并计算 pacing"，一个负责 UI 合成与 pacing present。→ 你的 `MsCPUBusy` 会**低估**真实 CPU 成本（有一部分跑在别的线程）。
- 关闭 FG 时，"present 会略贵一点（多一次 surface copy）"（厂商原话：one extra surface copy）。→ 关 FG 的对照实验不是免费的，别把它当零成本基线。
- 4.0.0 起支持 **Driver-Assisted Frame Pacing**：把最终呈现时机交给显示驱动，"instead of a user-mode busy-wait loop"，条件是 RDNA4 + 特定驱动 + 独占/无边框全屏 + 关 vsync + 在 VRR 窗口内。**不满足就静默回退**到用户态 pacing。〔厂商文档〕[AMD FSR Frame Generation](https://gpuopen.com/amd-fsr-framegeneration/)
- 结论：FG 场景下**唯一可信的指标是 `MsAllInputToPhotonLatency` + `DisplayedTime` 抖动**；FPS 只用于回归对比。判据是"排队是否变浅、阻塞是否变短"，不是"是否对上某个刷新周期"。

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

---

## C. 静态检查手段

### C.0 该做什么 / 别做什么

**该做**：每次改同步/提交代码后跑一遍 validation + best practices；把 sync validation 当 CI 门禁。
**别做**：别指望 validation 告诉你"哪里慢"——它只说"哪里错"或"哪里可疑"。

### C.1 各子层能查什么

`VK_LAYER_KHRONOS_validation` 的子功能〔厂商文档〕[Vulkan 开发工具指南](https://docs.vulkan.org/guide/latest/development_tools.html)：

| 子层/功能 | 能查出 | 与性能的关系 |
|---|---|---|
| 核心校验（VU/VUID） | 违反 Valid Usage 的调用、未定义行为 | 间接：UB 在 iGPU 上可能"能跑但慢"（如未初始化的 layout） |
| **Synchronization Validation** | Draw/Copy/Dispatch/Blit 之间缺失或错误的同步导致的资源访问冲突 | 直接：缺失 barrier → 数据竞争 → 驱动插入隐式同步 → 变慢 |
| **Best Practices Warnings** | "potential performance issues, questionable usage patterns, common mistakes" | 直接：这是唯一面向性能的静态检查 |
| GPU-Assisted Validation | shader 越界访问等（靠插桩） | 只用于调试，开销极大 |
| Shader printf | shader 内打印 | 同上 |
| `VK_LAYER_LUNARG_api_dump` | 完整 API 调用流 | 数 submit/barrier 次数 |
| `VK_LAYER_LUNARG_gfxreconstruct` | 抓帧/重放 | 复现问题 |

Vulkan 是显式 API，驱动不做错误检查（没有 `glGetError` 等价物），所以错误的同步/用法**不会报错，只会变慢或偶发花屏**。〔规范〕[validation overview](https://docs.vulkan.org/guide/latest/validation_overview.html)

### C.2 哪些 warning 值得当性能问题处理

按"是否可能真影响帧时间"排序（〔社区经验〕，需在你自己的机器上验证）：

1. **同步类**：缺失的 `vkCmdPipelineBarrier` / 错误的 `srcStageMask` → 驱动可能插入全管线 flush。**必查**。
2. **每帧重复创建对象**：每帧 `vkCreate*`（pipeline/layout/descriptor/buffer）→ 驱动分配与编译，核显上尤其贵。**必查**。
3. **`vkQueueSubmit` 次数过多 / 每帧多个 submit**：每次 submit 在 Linux 上是一次 DRM ioctl，Mesa 前端还有校验开销。**量了再改**。
4. **映射/刷新**：每帧 `vkMapMemory` + 非 coherent 内存的手动 flush/invalidate → 共享内存上会触发 cache 维护。**必查**。
5. **format/usage 不匹配导致的隐式转换**（如 swapchain image 拿到非 `COLOR_ATTACHMENT` 用途后又要 blit）→ 额外拷贝。
6. **仅风格类**（如未用 `VK_KHR_synchronization2`、旧式 `BOTTOM_OF_PIPE`）→ 一般是校验层干净度问题，帧率收益接近 0，别当作优化项。

### C.3 配置与工具链

- 四种配置方式（推荐顺序）：Vulkan Configurator → `VK_EXT_layer_settings` 在 `vkCreateInstance` 里程序化设置 → `vk_layer_settings.txt` + `VK_LAYER_SETTINGS_PATH` → 环境变量（如 `VK_LAYER_MESSAGE_ID_FILTER`）。〔厂商文档〕[khronos_validation_layer.md](https://github.com/KhronosGroup/Vulkan-ValidationLayers/blob/main/docs/khronos_validation_layer.md)
- **Arm best practice checks** 是 Best Practices 的可选子集，自 Vulkan SDK 1.2.148.0 起提供；它检查 "technically correct but potentially unadvisable in terms of resulting performance" 的用法，依据是 Mali GPU Best Practices。〔厂商文档〕[Arm 博客](https://developer.arm.com/community/arm-community-blogs/b/mobile-graphics-and-gaming-blog/posts/arm-best-practice-warnings-in-vulkan-sdk)
- **Vulkan Profiles**：把"你需要的能力集"写成 profile，用 Profiles Checker 在目标设备上验证是否满足（Android 上会报出具体未满足项）。核显/低端设备上这是避免"在开发机上能跑、在用户机上退化"的手段。〔厂商文档〕[Vulkan-Profiles](https://github.com/KhronosGroup/Vulkan-Profiles)
- **`VK_EXT_tooling_info`**：运行时枚举当前 driver/loader 上真正可用的工具与层，用来确认"我以为挂上了 RGP/validation，其实没挂"。〔未验证：本次未抓取扩展原文〕
- **debug label 规范**：给每个 command buffer / pass / 关键资源打 `VK_EXT_debug_utils` 标签（`vkCmdBeginDebugUtilsLabelEXT`），命名形如 `fg/interp`、`present/acquire`、`qt/compose`。这样 RenderDoc 的事件树、RGP 的 marker、Tracy 的 zone 三边能对上号。〔社区经验〕

---

## D. 真实案例（只保留"优化 Vulkan 链路"的结论）

### D.1 Godot：swapchain 上多余的等待，白送 1–2 帧延迟

- 现象：Vulkan/D3D12 比 OpenGL 兼容渲染器多 1 帧延迟；用 PIX 看到蓝色 marker——即使不额外缓冲，也要等下一个 V-Sync 才执行 command list，执行完再等一个 V-Sync 才上屏，等于**等了两次 V-Sync**。
- 加一条线索：用 `FORCE_SEPARATE_PRESENT_QUEUE` 走独立 present 队列时，延迟反而更差（多 2 帧）。
- **优化对象：Vulkan/D3D12 呈现链路**（不是场景）。
- 结论：present 队列与渲染队列的耦合方式决定了延迟下界；「多一个队列」不必然是优化。
- 〔实测案例〕[godot#100025](https://github.com/godotengine/godot/issues/100025)

### D.2 Godot：MAILBOX 让 GPU 常驻 100%

- 现象：把 vsync 切到 Mailbox 后，一个"简单 2D 线条网格"也让 GPU 占用冲到 100% 并保持，其他 vsync 模式只有不到 15%。
- **优化对象：呈现策略**（链路），但方向是**负向**：mailbox = 不限速地渲染并丢弃旧帧。
- 结论：mailbox 空转会让 **`MsGPUBusy` 失去诊断意义**（一直满）并放大提交队列；发现该现象应改用 IMMEDIATE/FIFO 或引入显式 pacing 以恢复可测量性，理由不是省电。
- 〔实测案例〕[godot#89856](https://github.com/godotengine/godot/issues/89856)

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

### D.3 Godot：waitable swapchain 打赢自家 AUTO pacing

- 结论原文："waitable swapchains where many times superior at doing the same job as AUTO"；但 "not all GPUs support the necessary Vulkan extension on all platforms (notably AMD doesn't support it on Windows)"，所以保留 AUTO 作回退。
- 该 PR 引入 `latency_mode`（low_extreme/low/medium/high_throughput）与可屏蔽 pacing 方式的调试参数。
- **优化对象：present pacing（链路）**。它的价值是**减少排队帧数**，而不是"对齐刷新率"。
- 〔实测案例〕[godot#106221](https://github.com/godotengine/godot/pull/106221)
- **补充（规范层面）**：`VK_KHR_present_wait` 已被 **`VK_KHR_present_wait2`** 取代；规范原文强调 "block, waiting for a specific step of the presentation process… allows them to control the amount of outstanding work (and hence the potential lag in responding to user input)"。〔规范〕[WSI](https://docs.vulkan.org/spec/latest/chapters/VK_KHR_surface/wsi.html) → 本项目若计划用 present_wait，应按 present_wait2 设计。

### D.4 mpv：队列数 1→3，重负载 scaler 下约 +9%

- 数据（RX 570 / Mesa 20 git，2160p→1440p，`ewa_lanczos` + deband，`vulkan-swap-mode=immediate`）：queue-count=1 约 152fps，=2 约 153fps，=3 约 166fps（作者注明"若不因功耗降频还会更快"）。
- **优化对象：提交/队列深度（链路）**，不是画面质量。
- 结论：只有当 GPU 有独立 compute 队列可并行时，加深队列才有收益；收益来自"提交与执行重叠"，与刷新率无关。
- 〔实测案例〕[mpv#7251](https://github.com/mpv-player/mpv/issues/7251)

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

### D.5 工具本身在核显上的边界（AMD 官方）

- RGP 不支持少于 3 CU 的设备；只支持 RDNA；CU 限制源于 "firmware issues on these smaller devices that could impact the data collection and accuracy"。
- 用户实测：Ryzen 7 9800X3D 的 "Radeon Graphics" 直接报 "The current hardware is not supported"，而文档把 Ryzen APU 列为支持——**文档与实现有落差**。
- 结论：核显调查必须预设"profiler 可能不可用"，流程要有 PresentMon/GPUView 的降级路径。
- 〔厂商文档〕[rdpanel#62](https://github.com/GPUOpen-Tools/radeon_developer_panel/issues/62)

### D.6 FSR3 帧生成：链路成本与 pacing

- FSR FG (Swapchain) 在 Vulkan 上替换 swapchain 与四个函数指针；内部 2 个线程做插值等待与 pacing；关闭 FG 时 present 会多一次 surface copy。
- 4.0.0 起可把最终呈现时机交给驱动（Driver-Assisted Frame Pacing），把用户态 busy-wait 换成驱动调度；不满足条件（RDNA4 + 驱动版本 + 全屏 + 关 vsync + VRR 窗口）则静默回退。
- 官方还提醒："requires unencumbered access to the swap chain"——第三方注入/覆盖层会破坏 pacing。
- **优化对象：呈现链路（pacing）**，与场景无关。
- 〔厂商文档〕[FSR FG](https://gpuopen.com/amd-fsr-framegeneration/)、[Swapchain 手册](https://gpuopen.com/manuals/fsr_sdk/techniques/frame-interpolation-swap-chain/)
- 对本项目：如果自建 `VkSwapchainKHR` 又接 FSR FG 的 swapchain 替换路径，等于**两层都在管 present**——先确认谁拥有 present 权，再谈 pacing。

### D.7 Khronos 生态：把"性能建议"做成可执行检查

- Arm 把 PerfDoc 并入 Khronos 验证层（2020），Vulkan SDK 1.2.148.0 起可用；它检查 API 用法"语法正确但性能可疑"，并可在桌面 PC 上预检移动端友好性。
- **优化对象：API 用法（链路）**，不是场景。
- 〔厂商文档〕[Arm 博客](https://developer.arm.com/community/arm-community-blogs/b/mobile-graphics-and-gaming-blog/posts/arm-best-practice-warnings-in-vulkan-sdk)、[Vulkanised 2023](https://www.khronos.org/events/vulkanised-2023)（Khronos 官方演讲库，含 Valve/Arm/Samsung 的移动与驱动议题；具体 slide 本次未逐页抓取，〔未验证〕）
- 说明：Vulkanised 的历年 slide 托管在 khronos.org / vulkan.org，本次抓取时 PDF 直链不可达，因此本文不引用其具体数字。

---

## E. 「一次完整的核显 Vulkan 性能调查」流程模板

| # | 步骤 | 工具 | 看什么 | 通过标准 |
|---|---|---|---|---|
| 0 | 冻结环境 | — | GPU/驱动版本、present mode、vsync 状态、**是否设帧率上限（默认不设）**、分辨率、是否插电（仅记录） | 记录齐全，后续每步不得变更 |
| 1 | 能力核对 | `vulkaninfo` | present mode 列表、queue family、`VK_EXT_memory_budget`、扩展可用性 | 你假设的 present mode 真的在列表里 |
| 2 | 链路地板 | 最小帧 + PresentMon | `MsCPUBusy/GPU/InPresent` 的 p50/p99、`MsInPresentAPI` 占比、队列深度 | 地板 ≤ 目标预算 10%，p99/p50 ≤ 1.2，present 占比 ≤ 10%；否则转 3a |
| 3a | 若地板不合格：查呈现 | PresentMon `PresentMode` 列、GPUView 队列 | 是否 `Composed:*`、`MsInPresentAPI` 是否高、`DisplayedTime` 是否离散单峰 | 定位到合成路径或 present 阻塞 |
| 3b | 若地板正常：加内容 | PresentMon + RenderDoc | `MsGPUBusy` 是否随内容线性上升 | 线性 → GPU/带宽侧；不线性 → CPU 侧 |
| 4 | GPU 侧细分 | RGP（若支持）/ GPUView | per-event 时间、barrier、队列占用 | 找到 top-3 事件或"队列一直空" |
| 5 | CPU 侧细分 | Tracy zone / `INTEL_DEBUG=perf` | acquire/submit/present 三段墙钟 | 找到占比 >20% 的一段 |
| 6 | 静态检查 | validation + best practices + sync validation | warning 列表 | 无同步类 warning；性能类 warning 逐条判定 |
| 7 | 对照实验 | present mode × cap 矩阵（§B.3） | 12 格的 p99、`MsInPresentAPI`、input-to-photon | 找到"排队最浅、阻塞最短"的组合并解释原因 |
| 8 | 单项改动 | 只改一处 + A/B | Δp99、Δjitter、Δpresent 阻塞 | 改动可复现，且不以牺牲延迟换 FPS |
| 9 | 回归 | 同环境重跑步骤 2/3b | 地板与曲线 | 地板不变差，曲线下移 |
| 10 | 记录 | 写进 perf 日志 | 结论 + 反例 | 别人能按记录复现 |

**降级路径**（profiler 不可用时）：PresentMon 三段 → GPUView 队列 → RenderDoc 数事件 → 二分法拔功能。

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

---

## F. 常见误判

1. **用错计时口径**。拿 RenderDoc 的 duration 排名、或拿"GPU 利用率"当耗时。核显上时间必须来自 PresentMon/Tracy/GPUView 这类不改语义的观测点。
2. **把 vsync 当性能**。刷新率未知时，FIFO 可能被驱动/合成器按真实刷新节流，也可能等价于 immediate——所以**不能**说"关 vsync 就一定更快"，也**不能**说"开 vsync 就是 60"。判断只能用 GPU busy、present 阻塞时长、submit 耗时、队列深度（§B.2/B.3）。
3. **把驱动缓存当优化**。第二次运行变快，常是 shader/pipeline 缓存命中或页缓存预热。判据：首次运行（清缓存）与二次运行的差值；只有二次运行也改善才是真优化。
4. **只看平均帧不看抖动**。avg 提升 5% 但 p99 恶化 30%，体感是变差。FG 场景尤其如此。
5. **在插电/电池、不同 TDP 下对比**。电源状态会改变可用功耗预算从而改变频率与耗时，所以它是**必须记录的环境变量**，用来保证两次数据可比；但它不是结论依据——本项目不据此限帧。
6. **把 mailbox 的 100% 占用当"跑满了"**。见 §D.2：那是空转重绘，会让 `MsGPUBusy` 失去诊断意义，也不代表有更多有效工作。
7. **以为"多一个队列/多一个线程"就会更快**。Godot 的独立 present 队列曾让延迟更差（§D.1）；FSR FG 的内部线程也会让 `MsCPUBusy` 失真。
8. **把 `VK_SUBOPTIMAL_KHR` 当错误立刻重建**。重建要 `vkDeviceWaitIdle` + 重建全部图像/视图/信号量，代价远大于收益；除非尺寸真的变了。
9. **在没有 present 可观测性时下结论**。看不到 `present_id` / `MsInPresentAPI` / `DisplayedTime`，就无法区分"渲染慢"和"等上屏"。
10. **把工具限制当成设备限制**。RGP 抓不到 ≠ 你的核显没问题（§D.5）；GPA EOL ≠ Intel 核显不能调。
11. **用"省电/降温"当限帧理由**。本项目不关心功耗；限帧只有在能减少排队或降低 present 阻塞时才成立，且必须用 p99 与 input-to-photon 证明。
12. **用 fps 与刷新率的关系判断瓶颈**。刷新率运行时不可得；正确做法是看分布形状（`DisplayedTime` 是否离散单峰）与队列深度。

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

---

## 参考来源

**Khronos / 规范**
1. https://docs.vulkan.org/spec/latest/chapters/VK_KHR_surface/wsi.html — WSI 规范：present mode 语义、`VK_KHR_present_wait2`、合成与阻塞行为。
2. https://docs.vulkan.org/guide/latest/development_tools.html — Khronos 官方工具指南：validation 子层（sync/GPU-AV/best practices）、api_dump、gfxreconstruct。
3. https://docs.vulkan.org/guide/latest/validation_overview.html — 为什么显式 API 不做错误检查、VU/VUID 与未定义行为。
4. https://github.com/KhronosGroup/Vulkan-ValidationLayers/blob/main/docs/best_practices.md — Best Practices 层的目的与启用方式。
5. https://github.com/KhronosGroup/Vulkan-ValidationLayers/blob/main/docs/khronos_validation_layer.md — 四种配置方式与环境变量。
6. https://github.com/KhronosGroup/Vulkan-Profiles — Vulkan Profiles 工具与 Profiles Checker。
7. https://github.com/KhronosGroup/Vulkan-Tools — vulkaninfo / vkcube 所在仓库。
8. https://www.khronos.org/events/vulkanised-2023 — Vulkanised 2023 议程与演讲者（Arm/Valve/Samsung/LunarG/NVIDIA）。

**AMD**
9. https://gpuopen.com/rgp/ — RGP 功能与版本说明（含 RDNA 3.5 APU 支持）。
10. https://github.com/GPUOpen-Tools/radeon_developer_panel/issues/62 — 官方：少于 3 CU 的设备不支持 RGP、仅支持 RDNA。
11. https://gpuopen.com/amd-fsr-framegeneration/ — FSR Frame Generation 概述、Driver-Assisted Frame Pacing、swapchain 独占要求。
12. https://gpuopen.com/manuals/fsr_sdk/techniques/frame-interpolation-swap-chain/ — FSR FG (Swapchain) 的 Vulkan 集成方式、2 个内部线程、额外 surface copy。

**Intel / Microsoft**
13. https://www.intel.com/content/www/us/en/developer/tools/graphics-performance-analyzers/overview.html — GPA 能力、目标 API 与 EOL 公告。
14. https://github.com/GameTechDev/PresentMon — PresentMon 总览与权限要求。
15. https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md — 全部指标定义与 PresentMode 取值表。
16. https://learn.microsoft.com/en-us/windows-hardware/drivers/display/using-gpuview — GPUView/ETW 采集内容与工作流。
17. https://devblogs.microsoft.com/pix/ — PIX 定位（D3D12 专用）。

**Arm / NVIDIA**
18. https://developer.arm.com/community/arm-community-blogs/b/mobile-graphics-and-gaming-blog/posts/arm-best-practice-warnings-in-vulkan-sdk — PerfDoc 并入 Khronos 验证层、Arm best practice checks。
19. https://developer.nvidia.com/nsight-graphics — Nsight Graphics 支持的 API 与 GPU Trace。

**Mesa**
20. https://docs.mesa3d.org/envvars.html — `INTEL_DEBUG` / `AMD_DEBUG` 全部开关语义。

**开源项目案例**
21. https://github.com/godotengine/godot/issues/100025 — swapchain 多余等待导致 1–2 帧延迟。
22. https://github.com/godotengine/godot/issues/89856 — MAILBOX 导致 GPU 100%。
23. https://github.com/godotengine/godot/pull/106221 — waitable swapchain 优于 AUTO pacing，及平台支持差异。
24. https://github.com/mpv-player/mpv/issues/7251 — queue-count 1/2/3 的帧率对比。
25. https://github.com/wolfpld/tracy — Tracy 的能力与支持 API。
26. https://github.com/flightlessmango/MangoHud — Linux overlay、Vsync 段与日志绘图。
27. https://renderdoc.org/ — RenderDoc 支持的 API/平台与跨平台 capture。

（apitrace、Streamline、Mali Offline Compiler、`VK_EXT_tooling_info` 在正文中已标注「未验证」，本次未取得原文。）
