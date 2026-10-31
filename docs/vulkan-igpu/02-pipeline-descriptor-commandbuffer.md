# 02 · 管线 / 描述符 / 命令缓冲 / 内存：Vulkan CPU 侧开销（含 iGPU 视角）

> 适用对象：本仓库的 Qt + 自研 Vulkan 呈现层——从 QRhi 取原生 `VkDevice`/`VkQueue`，自建 `VkSwapchainKHR`，带 FSR3 帧生成与 FSR 上采样。
> 范围：只谈 Vulkan 链路本身的 CPU 开销（API 使用方式、驱动交互、同步与提交、内存与带宽、呈现与帧节奏、工具与测量）。
> 不谈：3D 场景优化（LOD / 剔除 / 合批 / 光照 / 阴影 / 后处理配方 / 资源压缩）。
> 证据等级：〔规范〕Vulkan 规范与官方 refpage ·〔厂商文档〕IHV/ISV 官方指南 ·〔实测/案例〕有出处可查的测量 ·〔社区经验〕工程共识，无一手测量（会明说）。
> 全文数字均来自文末来源，不做无出处估算；只有量级把握时只写量级。

## 0. 先说结论（10 条，后面每节展开）

1. **CPU 开销的大头不在 draw call 本身，而在"每帧重建对象 + 每帧重复同样的 API 调用 + 没预热的编译"。** 先消掉这三件事，再谈细节。
2. **管线**：全进程一个 `VkPipelineCache`（可落盘），PSO 在后台线程预热；`VK_EXT_graphics_pipeline_library` / `VK_EXT_shader_object` 是"减少 link 次数"的工具，不是默认路径。
3. **描述符**：目标不是"更新更快"，而是**一帧零更新**。路径是持久 descriptor set + push constant / dynamic offset，不是更快的 `vkUpdateDescriptorSets`。
4. **命令缓冲**：每线程池 + `vkResetCommandPool`；不要每帧 alloc/free，不要为了"细粒度回收"打开 `RESET_COMMAND_BUFFER_BIT`。
5. **内存**：大分配 + 子分配（VMA）、持久映射；UMA 上直接省掉 staging；用 `VK_EXT_memory_budget` 看预算，而不是等 OOM。
6. **渲染结构**：动态渲染在 iGPU（tile-based）上不会自动变快，但也不会变慢——load/store op 的纪律才是带宽开关，`VK_EXT_subpass_merge_feedback` 能告诉你 subpass 到底合没合。
7. **校验层**：开发期全开，性能测量期全关；多线程录制时校验层的全局锁可能吃掉一倍以上性能（官方仓库实测报告：多数游戏提升约 150%）。
8. **发布版必须关掉的东西**：validation、GPU-AV、以及任何 per-draw 的 `vkCmdBeginDebugUtilsLabelEXT`。
9. **iGPU 特有的两条**：① 内存与显存是同一块物理 RAM，别照抄 discrete 的 staging 套路；② 带宽是命门，任何"多写一遍再读回来"的结构（多余 pass、`vkCmdResolveImage`、不必要的 store）都直接变成 CPU 侧等带宽。
10. **验证方式**：不要靠"感觉变快了"。计数（API 调用数 / PSO 创建数 / descriptor 更新数 / submit 数）+ 抓帧工具（RenderDoc / RGP / GPA / Nsight），见 §G。

---

## A. 管线（VkPipeline / VkPipelineCache）

**该做**：进程内单一缓存实例 + 落盘持久化 + 后台线程建 PSO + 够用就好的动态状态 + 用 feedback 量化"建一次有多贵"。
**别做**：创建 pipeline 传 `VK_NULL_HANDLE` 缓存；在渲染帧里第一次使用时才建 PSO；为了"参数化"把不需要的静态状态塞进 PSO 键里。

### A.1 VkPipelineCache 的正确用法

- **机制**：`VkPipelineCache` 是"已创建管线状态的复用容器"。驱动在 `vkCreateGraphicsPipelines` 时查询它，命中则可跳过绝大部分创建工作（编译、部分校验、内部数据结构构建）。官方指南明确：管线创建"somewhat costly"，缓存的**最大优势**是状态可存盘跨进程复用，从而"eliminating some of the costly parts of creation"〔规范〕([guide/pipeline_cache](https://docs.vulkan.org/guide/latest/pipeline_cache.html))。
- **API 形态**：
  - 进程内：`vkCreatePipelineCache` 建**一个**，全进程所有 `vkCreate*Pipelines` 都传它。规范保证"the same pipeline cache object can be used in multiple threads simultaneously"，内部已同步〔规范〕([spec/pipelines](https://docs.vulkan.org/spec/latest/chapters/pipelines.html))。
  - 落盘：`vkGetPipelineCacheData` 取 blob → 下次启动填进 `VkPipelineCacheCreateInfo::pInitialData`。规范要求该数据必须来自**之前一次** `vkGetPipelineCacheData` 调用（VUID-…-00769），即 blob 完全是不透明的，不要自己拼、不要跨实现移植〔规范〕。
  - 多池/多线程：可 `vkMergePipelineCaches` 合并；也可设 `VK_PIPELINE_CACHE_CREATE_EXTERNALLY_SYNCHRONIZED_BIT`，此时"implementation may skip any unnecessary processing needed to support simultaneous modification from multiple threads"——代价是你自己保证外部同步〔规范〕。
- **代价与风险**：规范只说实现"should not internally limit"条目数与宿主内存，**缓存会无限长大**；应用侧要用 `vkGetPipelineCacheData` 的 `dataSize` 做上限与裁剪〔规范〕。裁剪不能做 LRU（blob 内部结构不透明），只能"整块保留 / 整块丢弃"——这正是 `VK_KHR_pipeline_binary` 出现的动机〔厂商文档〕([Khronos blog: pipeline binary](https://www.khronos.org/blog/bringing-explicit-pipeline-caching-control-to-vulkan))。
- **适用条件**：任何有 PSO 的程序都适用。**不适用**：把缓存当"编译外包"——缓存只省重复工作，第一次仍然要编译。

### A.2 落盘持久化的失效键

- **机制**：blob 与"设备 + 驱动 + 全局特性开关"绑定，换驱动/换 GPU/开关 robustness 或 protected memory 后旧 blob 无效。
- **该做什么**：给缓存文件加 key：`vendorID` + `deviceID` + `driverVersion` + `pipelineCacheUUID`（均在 `VkPhysicalDeviceProperties`）+ 自启用扩展/特性集合的哈希 + 引擎 shader 版本号。任一变化 → 丢弃重建。
- **更细的判据**：`VK_KHR_pipeline_binary` 提供 `vkGetPipelineKeyKHR()`——不带 createInfo 时返回"全局 key"，全局 key 变了说明当前 device 上的 blob 全部失效（驱动更新、robustness/protected memory 等全局特性变化都会改 key）〔厂商文档〕([Khronos blog](https://www.khronos.org/blog/bringing-explicit-pipeline-caching-control-to-vulkan))。没有该扩展时用上面的手写 key 兜底。
- **风险**：key 太粗 → 每次启动都冷缓存，用户每次首帧卡顿；key 太细（把不影响代码生成的开关也算进去）→ 缓存永远命中不了。**判据**：只有"会改变驱动生成代码或内部布局"的项才进 key。

### A.3 vendor blob / VK_KHR_pipeline_binary

- **机制**：驱动内部本来就有"per-pipeline 派生的二进制内部缓存"，即使你不传 `VkPipelineCache` 也存在〔厂商文档〕。该扩展让你按**单个 pipeline** 取回 blob，摆脱"一个不透明大 blob"的两个硬限制：① 缓存大小不可裁剪；② 难与应用自有缓存系统（版本、GC、分发）集成。
- **关键事实**：一个 pipeline 会产出**多个** blob——有的只依赖某 stage 的 shader 代码 + 静态状态，有的依赖相邻 stage 接口，有的只依赖静态状态（原文举例：VS/FS + 静态 vertex input/blend 时得到 Blob1..Blob4）。这正是 GPL 与 shader object 有效的根本原因：blob 可跨 pipeline 共享〔厂商文档〕。
- **API 形态**：创建时带 `VK_PIPELINE_CREATE_2_CAPTURE_DATA_BIT_KHR` → `vkCreatePipelineBinariesKHR()` → `vkGetPipelineBinaryDataKHR()` 取 key+data。温启动时把 `VkPipelineBinaryInfoKHR` 链进 createInfo，即可**只从 blob 建 pipeline**，连 SPIR-V 都不必加载（可省掉 `VkShaderModule` 的创建与磁盘读）。
- **异步价值**：可提前异步创建 binary，把磁盘 I/O 挪出关键路径以避免 micro-stutter，并提前知道"哪些 binary 缺失"〔厂商文档〕。
- **风险**：实现覆盖有限（查 `pipelineBinaryInternalCache` 等属性）；`pipelineBinaryPrefersInternalCache` 为真时自己再存一份可能重复劳动，可用 `VkDevicePipelineBinaryInternalCacheControlKHR` 关掉驱动内部缓存，做单一事实来源。
- **适用条件**：PSO 数量多、启动时间敏感、要求"首帧即热"。**不适用**：PSO 只有几十个的小程序——一个落盘 `VkPipelineCache` 就够了。

### A.4 VK_EXT_graphics_pipeline_library（GPL）：收益与代价

- **机制**：把 PSO 拆成 4 个可独立创建、独立缓存的 library：Vertex Input Interface（只含 `VkPipelineVertexInputStateCreateInfo` + `VkPipelineInputAssemblyStateCreateInfo`，**无 shader**，创建极快、数量少）、Pre-Rasterization Shaders（VS/TES/GS + viewport/raster/tess 状态）、Fragment Shader（FS + depth-stencil）、Fragment Output Interface（color blend + multisample）。最终只做一次很便宜的 link〔厂商文档〕([Khronos blog: GPL](https://www.khronos.org/blog/reducing-draw-time-hitching-with-vk-ext-graphics-pipeline-library))。
- **实测形态**：Source 2 的 Vertex Input / Fragment Output interface 组合数"< forty"（不到 40 个），且无 shader 代码、创建快——所以拆分成本主要落在 4 类 library 的缓存命中率上，而不是数量上〔实测/案例〕。
- **前置条件（关键）**：GPL 要真便宜，必须把大量状态动态化：pre-raster 侧需要 `VIEWPORT_WITH_COUNT`、`SCISSOR_WITH_COUNT`、`DEPTH_BIAS`、`CULL_MODE`、`FRONT_FACE` 等动态状态，且 renderPass 传 `VK_NULL_HANDLE`（配 dynamic rendering）；fragment 侧需要 `DEPTH_TEST_ENABLE`/`DEPTH_WRITE_ENABLE`/`DEPTH_COMPARE_OP`/`STENCIL_*` 等动态状态〔厂商文档〕。否则每种静态组合都会切出一个新 library，收益归零。
- **pipeline layout 的坑**：GPL 要求建 library 时就给完整 pipeline layout，但 VS/FS 的配对到 draw time 才知道。解法是 `VK_PIPELINE_LAYOUT_CREATE_INDEPENDENT_SETS_BIT_KHR`：每个 stage 只给自身消费的 set（共享 set 的 layout 必须一致）。Source 2 的划分是 set0 = draw time 才绑的动态资源（uber set）、set1 = VS 静态、set2 = FS 静态、set3 = bindless 跨 stage 共享；不做"每 stage 一个 set"的原因是性能（一次 alloc/update/bind 而非两次）以及部分移动 GPU 只支持 4 个 descriptor set〔厂商文档〕。
- **代价**：代码复杂度显著上升（4 类缓存 + link 时机 + layout 分区）；`VK_PIPELINE_CREATE_LINK_TIME_OPTIMIZATION_BIT_EXT` 会增加 CPU 时间换 GPU 性能，Source 2 的做法是"先不带优化快速 link（`graphicsPipelineLibraryFastLinking` 为真时很快），后台再做带优化的版本替换"〔厂商文档〕。
- **适用条件**：PSO 组合爆炸（材质 × 顶点格式 × blend 状态），且已有 dynamic rendering + extended dynamic state 基础。**不适用**：PSO 只有几十~几百个，或还在 Vulkan 1.1 上、动态状态不全——此时 GPL 只会把"1 次编译"变成"4 次创建 + 1 次 link"。

### A.5 VK_EXT_shader_object：适用边界

- **机制**：`VkShaderEXT` 表示**单个编译后 stage**，用 `vkCreateShadersEXT()` 创建、`vkCmdBindShadersEXT()` 绑定，所有状态（含 vertex input、blend、depth）通过 `vkCmdSet*` 动态设置。与 pipeline 的关键差别：linking 只是创建时的"承诺"而非独立对象；pipeline 必须 link 后才能用，shader object 不需要；**不要求在创建时指定 attachment format**，因此可用于任意合法 format 组合〔厂商文档〕([Khronos blog: shader object](https://www.khronos.org/blog/you-can-use-vulkan-without-pipelines-today))。
- **性能边界（合规实现的硬门槛，CTS 会测）**：shader object draw ≤ **150%** 的"全静态 pipeline" CPU 时间；≤ **120%** 的"最大动态 pipeline" CPU 时间；从 binary 建 shader object ≤ **150%** 的"拷贝等量数据到 device local"CPU 时间〔厂商文档/规范〕。即：**它可能比 pipeline 慢一点，规范只保证不慢太多**。
- **什么时候值得**：① 组合数多到 PSO 缓存本身成为负担（每加一个静态状态就乘一倍）；② 需要在运行时"任意换 FS 而不重建 PSO"（调试、可视化、用户自定义 shader）；③ 状态大部分已经在用动态状态（此时 pipeline 的优势本来就被自己削掉了）。
- **什么时候不值得**：状态稳定、PSO 数量可控、驱动对 PSO 有更强的静态优化（多数桌面驱动如此）。注意博客原话的前提：性能好是"只要不是每次 draw 前把所有 setter 都调一遍"——**每帧重设全部 `vkCmdSet*` 是典型反模式**，它把成本从"建 PSO"搬到了"每 draw 调 setter"。
- **风险**：扩展可用性/驱动成熟度参差；一旦走这条路，PSO 缓存那套体系（含 `VK_KHR_pipeline_binary`、发行平台分发的缓存）都不能直接用。

### A.6 VkPipelineCreationFeedback 怎么用

- **机制**：`VkPipelineCreationFeedback` = `{ flags, duration }`，`duration` 单位**纳秒**；`flags` 未置 `VALID_BIT` 时其余位不得置、其余成员未定义〔规范〕([refpage](https://docs.vulkan.org/refpages/latest/refpages/source/VkPipelineCreationFeedback.html))。用法：在 `pNext` 挂 `VkPipelineCreationFeedbackCreateInfo`，可同时拿到 pipeline 级与每个 stage 级的 feedback。
- **该看哪个 flag**：`APPLICATION_PIPELINE_CACHE_HIT_BIT` 表示你传的 `pipelineCache` 让实现避免了绝大部分创建开销；规范特别说明：若实现走的是**内部缓存**而非你给的缓存，它"discouraged from setting"该位，因为对你不可行动〔规范〕([refpage](https://docs.vulkan.org/refpages/latest/refpages/source/VkPipelineCreationFeedbackFlagBits.html))。`BASE_PIPELINE_ACCELERATION_BIT` 衡量 base pipeline 的收益，规范给的判据是"1% 减少不值得置位，50% 值得"。
- **工程用法**：把 `duration` 累加进启动阶段的自有埋点，得到"本次运行 PSO 创建总耗时"；hit 比例低于预期时，先查 A.2 的 key 是否过细，再查是否在帧内首次使用才建 PSO。
- **风险**：feedback 本身有成本（实现要计时），只在启动/预热阶段开启；长期开在渲染循环里没有意义。

### A.7 管线布局与 push constant 复用

- **机制**：`VkPipelineLayout` 是 PSO 与 descriptor set 之间的契约。**layout 复用**带来两个直接收益：① 同一 layout 的 PSO 之间切换时，已绑定的 descriptor set 无需重绑（兼容性判定通过）；② 驱动的 PSO 内部表示以 layout 为键，layout 越少，内部缓存命中率越高。
- **该做**：把 layout 数量压到"个位数"（主渲染 layout、FSR/后处理 layout、计算 layout）。所有 per-draw 小数据（矩阵、时间、频谱/音量参数）走 **push constant**——它是传 per-draw 常量"最快的方式"（无间接、可直接索引；root/descriptor table 需要一到两次间接 + 边界检查）〔厂商文档〕([NVIDIA](https://developer.nvidia.com/blog/advanced-api-performance-descriptors/))；Intel 同样建议"favor root constants over root descriptors, and favor root descriptors over descriptor tables"，并强调 push/root constant 会被预载进寄存器〔厂商文档〕([Intel Gen11](https://www.intel.com/content/www/us/en/developer/articles/guide/developer-and-optimization-guide-for-intel-processor-graphics-gen11-api.html))。
- **容量约束**：`maxPushConstantsSize` 规范下限 128 字节〔规范〕([limits](https://docs.vulkan.org/spec/latest/chapters/limits.html))。超了就分块：高频小块走 push constant，超出的走 dynamic UBO offset——不要再开第二个 layout。
- **风险**：push constant **不参与** set layout 兼容性判定，但它的**范围（stageFlags + offset + size）必须完全一致**才算 layout 兼容；两个 layout 里 push constant 范围写得不一样，会导致你不得不在 draw 之间重绑 pipeline。
- **适用条件**：per-draw 常量 < 128B 时永远优先。**不适用**：需要 per-instance 数组或超过限值的常量块——用 dynamic offset 指向一个大 UBO。

### A.8 动态状态：把 PSO 数量压下来

- **机制**：PSO 的键 = 静态状态集合。把状态从"创建时固定"改成"录制时设置"，键的笛卡尔积立刻塌缩。典型清单（Vulkan 1.3 内即可用）：`extendedDynamicState`（cull mode、front face、primitive topology、depth test/write/compare、depth bounds、stencil op/mask/ref）、`extendedDynamicState2`（depth bias、rasterizer discard、primitive restart、logic op）、`extendedDynamicState3`（blend 常量/因子、color write mask、各 `*_ENABLE`、polygonMode、tessellation domain/origin、conservative rasterization 等）〔厂商文档〕（GPL 博客列出的前置动态状态清单即同一套 API）。
- **代价**：每条 `vkCmdSet*` 都是 CPU 时间与命令缓冲字节；动态状态的验证成本也更高（部分组合要到 draw 时才可知）。判据：**某个状态在一次提交里改不到几次，就让它静态**；改成动态的收益是"PSO 数量减少"，成本是"每次切换的 set 调用"。
- **风险**：全动态 + 每 draw 全量重设 = 把 PSO 的成本转移成 API 调用，通常更糟（shader object 博客原文亦强调这一点）。
- **适用条件**：状态组合爆炸、且帧内同一状态反复切换的场景。**不适用**：状态固定的小程序——静态 PSO 让驱动能做更强的优化。

### A.9 编译卡顿（首次使用编译）与后台预热

- **机制**：PSO 首次创建包含 shader 编译/转换，耗时在 ms~十 ms 量级（取决于 shader 与驱动），出现在渲染帧里就是一次明显掉帧。规范只保证"创建是同步的"，不保证便宜〔规范〕。
- **该做**：
  1. 启动后（或曲目/场景加载时）在**后台线程**用同一个 `VkPipelineCache` 批量建 PSO；线程优先级设 idle，需要时临时提高〔厂商文档〕([NVIDIA PSO](https://developer.nvidia.com/blog/advanced-api-performance-pipeline-state-objects/))。
  2. 先用泛化 shader 快速上线，再在后台特化替换（同源）。
  3. 有 `VK_KHR_pipeline_binary` 时，先异步创建 binary，把磁盘 I/O 移出关键路径〔厂商文档〕。
  4. 不要把几十万个 PSO 一次性序列化到磁盘——内存会膨胀；用"miss 时再更新 library"的策略〔厂商文档〕。
- **风险**：后台建 PSO 与前台渲染共享驱动内部锁与内存分配器，可能出现"后台把前台拖慢"。缓解：限制后台并发度、按帧配额（每帧最多建 N 个）、建完统一落盘一次而不是每建一个就落盘。
- **适用条件**：所有"第一次出现某种材质/效果会卡"的程序。**不适用**：PSO 全部在启动时同步建完且总耗时 < 100 ms 的小程序。

### A.10 A 节检查清单

- [ ] 全进程是否只有一个 `VkPipelineCache`？（含 QRhi 侧与自建层是否各建了一个——两个缓存互不命中，命中率与二进制复用都减半）
- [ ] 缓存 blob 是否落盘？key 是否包含 `pipelineCacheUUID` + 驱动版本 + shader 版本？
- [ ] 是否有 PSO 在渲染帧内首次创建？（抓帧看 `vkCreateGraphicsPipelines` 是否出现在帧中间）
- [ ] `VkPipelineCreationFeedback` 的累计耗时与 hit 比例是否被记录？
- [ ] pipeline layout 数量是否 ≤ 个位数？push constant 范围在各 layout 间是否一致？
- [ ] 动态状态是否"够用就好"，而不是"全都动态"？

---

## B. 描述符（descriptor）

**该做**：持久 set + push constant / dynamic offset + 少量 set layout；bindless 只在真正需要时上；以**一帧零更新**为目标。
**别做**：每帧 `vkResetDescriptorPool` + 重分配 + 重更新；每个 draw 调一次 `vkUpdateDescriptorSets`；用"更大的池"掩盖"每帧重建"。

### B.1 set layout 兼容性与切换成本

- **机制**：两个 `VkDescriptorSetLayout` 兼容（同类型/同数量/同 stageFlags/同 immutable sampler）时，已绑定的 set 在切换 pipeline 后仍然有效，无需重绑；反之每次切 pipeline 都要重绑 set——这是每帧几十~几百次额外 API 调用。
- **该做**：把 set layout 数量压到与 pipeline layout 同量级（个位数）；把"总是同时变"的描述符放进同一个 set；把"draw 之间会变"的放 set 1（高频），"整帧不变"的放 set 0（低频）。
- **代价/风险**：set 拆太细 → 每次 draw 多次 `vkCmdBindDescriptorSets`；set 合太粗 → 任何一个小变化都要重建整个 set。经验分割线是"变化频率"，不是"逻辑归属"〔社区经验〕。
- **iGPU 特有**：Intel 明确写"Minimize descriptor heap changes. Changing descriptor heaps severely stalls the graphics pipeline"〔厂商文档〕([Intel](https://www.intel.com/content/www/us/en/developer/articles/guide/developer-and-optimization-guide-for-intel-processor-graphics-gen11-api.html))。descriptor set 切换在 iGPU 上同样是"改硬件状态"，不是纯 CPU 记账。

### B.2 VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND

- **机制**：允许在 set 已绑定、甚至已在 GPU 上使用时更新描述符，驱动不再需要"绑定时消费/重打包"。启用需三件套同时设置：pool 的 `VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT`、setLayout 的 `VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT`、binding 的 `VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT`；并需查询对应的 `descriptorBinding*UpdateAfterBind` 特性〔规范〕([guide](https://docs.vulkan.org/guide/latest/extensions/VK_EXT_descriptor_indexing.html))。
- **真实收益**：不是"更新更快"，而是**解除了"更新必须在绑定前完成"的时序约束**，让流式资源（纹理上传、频谱图）可在帧内任意时刻更新而不打断录制顺序。
- **风险**：驱动必须为"随时可能变"的描述符付出额外同步/复制代价；滥用会把 bindless 的隐式成本摊到所有 draw 上。只在"确实需要帧内更新"的 binding 上开，不要整套 set 全开。

### B.3 descriptor indexing（运行时数组 + 非一致索引）

- **机制**：shader 用运行时下标索引 descriptor 数组。分两类：**动态 uniform 索引**（同一 invocation group 内 index 相同，uniform control flow）与**动态非 uniform 索引**（GLSL `nonuniformEXT` / SPIR-V `NonUniform` 装饰），后者需要 `shader*ArrayNonUniformIndexing` 特性〔规范〕。
- **关键配套**：`VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT` 允许数组只绑前 N 个槽（例：`array[64]` 只绑前 32），前提是 shader **保证不索引未绑定的槽**〔规范〕。这让你可以一次性分配大数组、逐步填充，而不必每加一个资源就重建 set。
- **代价**：非一致索引在部分硬件上是"最慢的路径"（per-lane 地址生成 + 边界检查）；NVIDIA 的建议是"全应用 GPU 可见 descriptor 不超过约 1M、sampler 不超过约 2K"（Vulkan 由驱动自动去重，限制只算"唯一变体"），超过会带来实际代价〔厂商文档〕([NVIDIA](https://developer.nvidia.com/blog/advanced-api-performance-descriptors/))。
- **适用条件**：资源数量随内容增长（音乐可视化里的频谱纹理、粒子贴图集）且无法编译期确定。**不适用**：资源集合固定且少——直接静态 binding 更快。

### B.4 push descriptors（VK_KHR_push_descriptor）

- **机制**：描述符直接写进命令缓冲，由实现管理其内存，不需要 descriptor pool/set。规范原话：push descriptor"may enable easier porting from older APIs and **in some cases can be more efficient** than writing descriptors into descriptor sets"〔规范〕([refpage](https://docs.vulkan.org/refpages/latest/refpages/source/VK_KHR_push_descriptor.html))。该扩展已**晋升为 Vulkan 1.4 core**。
- **容量**：`VkPhysicalDevicePushDescriptorProperties::maxPushDescriptors` 限制单个 push-descriptor set layout 里能放的描述符数量〔规范〕([limits](https://docs.vulkan.org/spec/latest/chapters/limits.html))——这个数通常不大（几十），别指望用它代替 bindless。
- **代价/风险**：每个 set 的内容都要进命令缓冲，draw 多时命令缓冲体积膨胀；且无法跨 draw 复用同一组描述符（每次都得重新 push）。
- **适用条件**：per-draw 少量描述符（1~4 个）且**每次 draw 都不同**——例如每帧变化的频谱 buffer + 每 draw 不同的采样参数。**不适用**：整帧不变量（那应该是普通持久 set）。

### B.5 VK_EXT_descriptor_buffer

- **机制**：Vulkan 1.0 模型允许实现"consume & repack"绑定时看到的描述符；descriptor buffer 把 descriptor set 变成**内存**（offset + element size + element count，tightly packed），`VkDescriptorPool` 退化成 arena allocator，`vkCmdBindDescriptorSets` 实质是"绑一个 buffer + offset"。因此实现不再重打包，`vkUpdateDescriptorSets` 的开销消失〔规范/提案〕([feature proposal](https://docs.vulkan.org/features/latest/features/proposals/VK_EXT_descriptor_buffer.html))。
- **提案里点名的问题**（很能说明"每帧重建"有多贵）：有应用**每帧拷贝数万个 descriptor**，`vkUpdateDescriptorSets` 的调用开销"不理想"；想让 descriptor 不进 device memory 很难，也没有 hint 告诉实现"这个 set 只用于 staging"；若 set 落在 device local(BAR) 或 uncached 内存，host 读它会产生"catastrophic effect on performance"〔规范/提案〕。
- **API 形态**：`vkGetDescriptorEXT()` 把 `VkDescriptorGetInfoEXT` 转成二进制 blob（官方指南示例里一个 storage buffer descriptor 是 16 字节：地址 8 字节 + range 4 字节等），可直接 `memcpy` 到 mapped descriptor buffer，或写 staging 再 `vkCmdCopyBuffer`；拷贝后需 barrier 到 `VK_ACCESS_2_DESCRIPTOR_BUFFER_READ_BIT_EXT`。绑定侧：`vkCmdBindDescriptorBuffersEXT` 后必须调 `vkCmdSetDescriptorBufferOffsetsEXT`，set offset 需按 `minDescriptorBufferOffsetAlignment`（示例 256）对齐〔规范/官方指南〕([guide/descriptor_buffer](https://docs.vulkan.org/guide/latest/descriptor_buffer.html))。
- **代价**：layout 不能同时是 update-after-bind 与 descriptor-buffer capable；不支持无法用内存表达的抽象类型（dynamic uniform/storage buffer），替代方案是 push constant、push constant 里放 BDA、或 push descriptors〔规范/提案〕。需要一个自己的"descriptor 分配器"（本质是给每种类型算 element size 的 arena）。
- **适用条件**：bindless 规模大、每帧要写很多描述符、或想把描述符纳入统一内存预算（UMA 上尤其香：descriptor buffer 可以就在同一块系统内存里）。

### B.6 池尺寸与碎片

- **机制**：`VkDescriptorPool` 是固定尺寸分配。池太小 → 帧内 `vkAllocateDescriptorSets` 返回 `VK_ERROR_OUT_OF_POOL_MEMORY`；很多项目靠"池开大一点"掩盖，结果是每次分配都更慢且占用更多内存。
- **该做**：按 setLayout 预估"每帧最大 set 数"，池尺寸 = 峰值 × 1.5；池按"帧槽"复制（N 帧 in flight → N 个池），整池 reset 而不是逐 set 释放。
- **为什么不要 `VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT`**：为了能释放单个 set 就要打开它，而实现可能因此放弃更简单的分配器——Khronos 样例明确提到 mobile 实现"may use a simpler allocator if that flag is not set, relying on the fact that pool memory will only be recycled in block"〔规范/官方指南 + 实测/案例〕([samples/descriptor_management](https://docs.vulkan.org/samples/latest/samples/performance/descriptor_management/README.html))。更好的做法是"回收 set 复用"而不是"释放"。
- **碎片来源**：不同 layout 混用同一池、大小差异大、长期不整池重置。判断信号：同 workload 下 `vkAllocateDescriptorSets` 的失败率随时间上升，或帧时间随运行时长缓慢上升。

### B.7 为什么"每帧重建描述符集"是反模式，以及"一帧零更新"怎么做

- **反模式定义**：每帧 `vkResetDescriptorPool()` → 一串 `vkAllocateDescriptorSets()` → 一串 `vkUpdateDescriptorSets()`。这是"最直白、最灵活"的做法，但在移动/iGPU 上很低效；极端情况（每个 draw 调一次 `vkUpdateDescriptorSets`）"更新描述符的时间可能超过 draw 本身"〔规范/官方指南 + 实测/案例〕([samples/descriptor_management](https://docs.vulkan.org/samples/latest/samples/performance/descriptor_management/README.html))。
- **量级（可查的实测）**：draw-call 密集场景、2019 年高端手机、release、无校验层：**44 ms / 23 FPS → 27 ms / 37 FPS，帧时间降 38%**；GPU 帧时间几乎不变、仍是 CPU bound——收益全在 CPU 侧〔实测/案例〕。Arm 的对应文章还给出配套结论：单个大 `VkBuffer` + dynamic offset 也能拿到类似量级，且在复杂场景里可与 set 缓存叠加〔厂商文档〕([Arm](https://community.arm.com/arm-community-blogs/b/graphics-gaming-and-vr-blog/posts/vulkan-descriptor-and-buffer-management))。
- **做到"一帧零更新"的四步**：
  1. **持久 set**：set 的生命周期 = 资源的生命周期，不是帧。纹理/缓冲创建时建 set，销毁时销毁。
  2. **变化的部分搬走**：per-draw 常量 → push constant；per-object 数据 → 一个大 UBO/SSBO + `vkCmdBindDescriptorSets` 的 dynamic offset（不是新 set）。
  3. **按内容缓存**：以 set 内容为 key 的 hashmap，或直接把 set handle 存在材质/网格对象里〔同上〕。
  4. **环形缓冲**：同一帧内要写两次同一资源（例如 FSR3 的中间 target 在帧间复用）时用 N 个槽轮转，避免每帧重建。
- **风险**：持久 set 意味着"资源热重载/分辨率变化"必须显式失效缓存；否则会绑到已销毁的 image（校验层会抓，发布版是黑屏/花屏）。给缓存加版本号与 `VK_EXT_debug_utils` 名字，便于定位。

### B.8 B 节检查清单

- [ ] 每帧是否有 `vkResetDescriptorPool`？如有，是否真必要（能否改成轮转池）？
- [ ] 每帧 `vkUpdateDescriptorSets` 次数是多少？目标：**接近 0**，只留流式资源。
- [ ] set layout 与 pipeline layout 各多少个？
- [ ] 是否为了 `vkFreeDescriptorSets` 打开了 `FREE_DESCRIPTOR_SET_BIT`？
- [ ] per-draw 常量走的是 push constant 还是 descriptor？（应优先 push constant）

---

## C. 命令缓冲（command buffer）

**该做**：每线程一个池 + 整池 reset；一次性命令缓冲标 `ONE_TIME_SUBMIT_BIT`；只在真正需要并行录制时用 secondary。
**别做**：每帧 `vkAllocateCommandBuffers`/`vkFreeCommandBuffers`；为了"能单独回收某一个"而开 `RESET_COMMAND_BUFFER_BIT`；在高频路径调 `vkResetCommandBuffer`。

### C.1 一次性 vs 可复用；RESET_COMMAND_BUFFER_BIT 的代价

- **机制**：三种回收策略——allocate&free、`vkResetCommandBuffer`（要求 pool 带 `VK_COMMAND_BUFFER_POOL_CREATE_RESET_COMMAND_BUFFER_BIT`）、`vkResetCommandPool`。官方样例原话：RESET_COMMAND_BUFFER_BIT"会强制 pool 为每个 command buffer 使用独立的内部 allocator"，比整池 reset 增加 CPU 与内存开销；allocate&free 是"worst-performing"〔规范/官方指南〕([samples/command_buffer_usage](https://docs.vulkan.org/samples/latest/samples/performance/command_buffer_usage/README.html))。
- **实测量级（同一样例，Android Profiler，CPU bound 场景）**：Reset pool **53.3 ms / 11877 ms = 0.45%**；Reset buffers **140.29 ms / 12087 ms = 1.16%**；Allocate and free **3319.25 ms / 11513 ms = 28.8%**〔实测/案例〕。读法：整池 reset 已接近免费；逐缓冲 reset 贵约 2.5 倍；逐缓冲 alloc/free 贵约 60 倍。
- **规范侧两条硬约束**：`VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT` 表示"每次录制只提交一次，且每次提交之间会被 reset 重录"；`SIMULTANEOUS_USE_BIT` 允许 pending 状态重提交，但"may reduce performance"〔规范〕([spec/cmdbuffers](https://docs.vulkan.org/spec/latest/chapters/cmdbuffers.html))。
- **该做什么**：每帧 `vkResetCommandPool` + 复用同一批 command buffer；`ONE_TIME_SUBMIT_BIT` 无脑加；不要 `SIMULTANEOUS_USE_BIT`（它让驱动无法做"重录即改写"的优化）。

### C.2 每线程池 + 多线程录制

- **机制**：命令录制是 CPU 密集型，且"no driver threads come to the rescue"——录制成本完全落在你的线程上〔厂商文档〕([NVIDIA command buffers](https://developer.nvidia.com/blog/advanced-api-performance-command-buffers/))。并行录制的唯一方式是"多个 command buffer 在不同线程录，然后一次 submit 里 `vkCmdExecuteCommands` 或分多次 submit"。
- **API 形态**：每线程一个 `VkCommandPool`（池不是线程安全的，command buffer 的录制也不是）；线程内录完把 handle 交回主线程提交。
- **代价/风险**：线程太多会与驱动内部锁竞争；NVIDIA 建议线程/command list 不要过多，目标是每帧 5~10 次提交（`ExecuteCommandList` ↔ `vkQueueSubmit`），因为 OS 调度一次 command list 需要 50~80 微秒，若 list 执行快于此会出现 bubble〔厂商文档〕。
- **适用条件**：单帧录制时间 > 2~3 ms 且渲染是 CPU bound 时。**不适用**：本来只有几十条命令的轻负载——多线程同步成本超过收益。

### C.3 secondary command buffer：收益与失效场景

- **收益**：可以把"每个物体/每个 pass 的录制"分散到多线程，然后被多个 primary 复用（同一段后处理在多个 view 里重复）。
- **失效场景（关键，多数人踩这里）**：
  1. **render pass 兼容性**：secondary 的 `VkCommandBufferInheritanceInfo::renderPass` 定义"它能被在哪些 render pass 里执行"——不兼容就不能 `vkCmdExecuteCommands`〔规范〕([spec/cmdbuffers](https://docs.vulkan.org/spec/latest/chapters/cmdbuffers.html))。用动态渲染时该字段被忽略（原文："renderPass, subpass, and framebuffer are ignored"）。
  2. **framebuffer 精度影响执行期性能**：规范写明"Specifying the exact framebuffer that the secondary command buffer will be executed with may result in better performance at command buffer execution time"——传精确 framebuffer 是性能选项，不是可选装饰〔规范〕。
  3. **动态状态不继承**：primary 上设的动态状态不会自动带到 secondary；secondary 里必须自己设（或用支持继承的扩展）。
  4. **调用本身贵**：官方样例明确"invocations are expensive"，数量要少，太多会让应用变 CPU bound〔规范/官方指南〕。
- **结论**：secondary 是"多线程录制的载体"，不是"减少 API 调用的手段"。要减少命令数，应让一个 secondary 里录更多 draw，而不是切更多 secondary。

### C.4 命令数量对驱动前端的影响

- **机制**：每条命令都要经过校验（开发期）、参数转换、写入命令缓冲；提交时驱动前端还要解析。命令数越多，CPU 时间与命令缓冲体积越大，cache 局部性越差。
- **可操作的削减**：① 用 `vkCmdBindDescriptorSets` 的 `dynamicOffsetCount` 一次绑多个 offset，而不是多次 bind；② 合并 pipeline barrier（用 `VkDependencyInfo` 的数组形式一次提交多个 barrier，Vulkan 1.3 / `VK_KHR_synchronization2`）；③ 避免"宽 barrier"——`ALL_GRAPHICS_BIT` 到自身的 barrier 会破坏 binning 与 fragment 的重叠〔规范/官方指南〕([TBR best practices](https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html))；④ 不要在队列上频繁混 draw/dispatch/copy（会引起 pipeline drain）〔厂商文档〕([NVIDIA](https://developer.nvidia.com/blog/advanced-api-performance-command-buffers/))。
- **风险**：为减少命令数而过度使用 indirect/多 draw 会把成本转到 GPU 或 shader 侧（本文不讨论批处理，这里只限 API 链路层面的合并）。

### C.5 录制时的状态冗余消除

- **机制**：录制端维护"当前已绑定状态"影子副本，只在变化时才发命令。典型冗余：每 draw 都 `vkCmdBindPipeline`（同 PSO）、每 draw 都 `vkCmdSetViewport`（同值）、每 draw 都重绑同一 descriptor set。
- **代价**：影子状态维护成本在录制线程上（一次比较 vs 一次 API 调用，通常前者便宜一个量级）；跨 secondary/primary 边界时影子状态必须失效（动态状态不继承）。
- **风险**：漏更新会导致"少发了一条该发的命令"，这类 bug 难查——务必在 debug 构建里用"全量重发"开关做 A/B，并用校验层/Best Practices 层兜底。
- **适用条件**：draw 数 > 数百且状态重复率高。**不适用**：draw 很少时，影子状态只增加代码复杂度。

### C.6 C 节检查清单

- [ ] 每帧是否 `vkAllocateCommandBuffers`/`vkFreeCommandBuffers`？（应为 0）
- [ ] 是否打开了 `RESET_COMMAND_BUFFER_BIT`？（除非真要逐缓冲 reset）
- [ ] 提交次数/帧是多少？（5~10 量级；过多会因调度间隔产生 bubble）
- [ ] secondary 的数量与"每次 `vkCmdExecuteCommands` 里塞多少条命令"？
- [ ] 是否有 `ALL_GRAPHICS` → 自身的宽 barrier？

---

## D. 内存（VkDeviceMemory / VMA）

**该做**：一个分配器（VMA）、大块子分配、持久映射、UMA 上省 staging、预算可见。
**别做**：per-resource `vkAllocateMemory`；每帧 map/unmap；在 iGPU 上照抄 discrete 的 staging 路径；不看预算硬分配。

### D.1 VMA 的使用要点

- **机制**：Vulkan 只给"整块 `VkDeviceMemory`"，`maxMemoryAllocationCount` 限制同时活跃的分配数，而 OS/驱动级的分配/释放"likely to be really slow"；官方指南把 sub-allocation 称为 first-class 做法，并建议用 VMA 这类库〔规范/官方指南〕([memory_allocation](https://docs.vulkan.org/guide/latest/memory_allocation.html))。
- **推荐参数形态**（VMA 官方 usage patterns）：GPU-only 资源用 `VMA_MEMORY_USAGE_AUTO`（自动选 DEVICE_LOCAL），大资源或会随分辨率重建的资源加 `VMA_ALLOCATION_CREATE_DEDICATED_MEMORY_BIT` + `priority = 1.0f`（配 `VK_EXT_memory_priority` 降低被 OS 换出的概率）；上传缓冲用 `VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT`（+ `MAPPED_BIT` 做持久映射）；回读缓冲用 `VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT`（保证 HOST_VISIBLE|HOST_CACHED）〔厂商文档〕([VMA usage_patterns](https://gpuopen-librariesandsdks.github.io/VulkanMemoryAllocator/html/usage_patterns.html))。
- **mapped 计数与 flush/invalidate**：
  - 映射是**按 allocation 计数**的：同一 allocation 调两次 `vkMapMemory` 就要 `vkUnmapMemory` 两次（VMA 帮你记账，但不要自己混着调裸 API）。
  - 非 HOST_COHERENT 内存需要 `vkFlushMappedMemoryRanges`（写后）/ `vkInvalidateMappedMemoryRanges`（读前），VMA 对应 `vmaFlushAllocation`/`vmaInvalidateAllocation`。**按区间 flush，不要整块 flush**；写入量小于 `nonCoherentAtomSize` 时按该值向上取整，否则可能丢失部分写入〔规范〕。
  - 判断是否需要 flush：查 memory type 的 `HOST_COHERENT` 位。iGPU 的 HOST_VISIBLE|DEVICE_LOCAL 内存**通常** coherent，但不要假设——查询后再决定走快路径还是 flush 路径。
- **代价/风险**：VMA 的块大小与碎片策略不是万能；`vmaCalculateStatistics()` 只用于调试（很慢），运行时判断用 `vmaGetHeapBudgets()`〔厂商文档〕([staying_within_budget](https://gpuopen-librariesandsdks.github.io/VulkanMemoryAllocator/html/staying_within_budget.html))。

### D.2 内存类型选择与 UMA 上 HOST_VISIBLE|DEVICE_LOCAL 的判定

- **机制**：选类型的正确顺序是按用途过滤：① 要 GPU 快速访问 → `DEVICE_LOCAL`；② 要 CPU 写 → `HOST_VISIBLE`；③ 不想每次 flush → 优先 `HOST_COHERENT`；④ 回读多 → 优先 `HOST_CACHED`。UMA 上常存在同时满足 ①②③ 的类型，那就是"零拷贝"路径。
- **怎么判定"是不是 UMA"**：不要靠 vendorID 猜。两个可查信号：`deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU`；以及"存在同时带 DEVICE_LOCAL|HOST_VISIBLE 的 memory type，且该 heap 大小 ≈ 系统内存"。官方指南的表述是：UMA 上直接用 `DEVICE_LOCAL|HOST_VISIBLE`，省掉 staging，传输开销大减，但要小心内存压力〔规范/官方指南〕。
- **风险**：类型存在不代表"写进去对 GPU 就快"——若非 HOST_COHERENT 仍要 flush；某些实现里 HOST_VISIBLE|DEVICE_LOCAL 是"小窗口"（BAR），大资源塞进去会失败或变慢。
- **适用条件**：iGPU / UMA 平台。**不适用**：discrete GPU（DEVICE_LOCAL 通常不可 host-visible，或只有有限的 BAR 窗口）。

### D.3 持久映射

- **机制**：`vkMapMemory` 在部分驱动上会做页表/TLB 操作，成本远高于一次 memcpy；持久映射把这次成本摊到初始化。VMA 的 `VMA_ALLOCATION_CREATE_MAPPED_BIT` 就是为此存在〔厂商文档〕。
- **该做**：环形上传缓冲（每帧写的 UBO/SSBO/instance 数据）**永久映射**，用 `VkMappedMemoryRange`/fence 控制"这块正被 GPU 读"的区间，而不是每帧 map/unmap。
- **风险**：持久映射 + 非 coherent 内存 = 必须自己管 flush 区间；写超范围会造成"GPU 读到半更新数据"的撕裂（在音乐可视化的频谱数据上表现为闪烁）。
- **适用条件**：所有每帧上传的宿主可见缓冲。

### D.4 暂存路径是否必要（staging vs 直接写）

- **机制**：discrete 上必须 staging（`vkCmdCopyBuffer`/`vkCmdCopyBufferToImage` 到 DEVICE_LOCAL）；UMA 上 DEVICE_LOCAL 本身可 host-visible，staging 只是"多一次拷贝 + 多一块内存 + 多一个 barrier"。
- **该做**：启动时探测"是否存在 DEVICE_LOCAL|HOST_VISIBLE 且 size 足够"的类型；有则直接写，没有则走 staging。两条路径用同一个上传接口封装，运行时只选一次。
- **风险**：iGPU 上直接写大纹理可能触发驱动内部"压缩/重排"（tiling/swizzle），比 staging 更慢；对**会被采样的 image**，优先仍用 staging + `vkCmdCopyBufferToImage`（让驱动在拷贝时做 layout/tiling 转换），对**线性 buffer**（UBO/SSBO/顶点）直接写。
- **适用条件**：逐资源判断，而不是全局一刀切。

### D.5 内存预算与 VK_EXT_memory_budget

- **机制**：超额分配不一定立刻失败——可能"没事 / 变慢（被换到系统内存，GPU 走 PCIe 访问）/ 新分配耗时数秒甚至冻结系统 / `VK_ERROR_OUT_OF_DEVICE_MEMORY` / 甚至 TDR（`VK_ERROR_DEVICE_LOST`）"〔厂商文档〕([VMA staying_within_budget](https://gpuopen-librariesandsdks.github.io/VulkanMemoryAllocator/html/staying_within_budget.html))。iGPU 上这条尤其危险：显存就是系统内存，超支会直接拖慢整机。
- **API 形态**：instance 开 `VK_KHR_get_physical_device_properties2`、device 开 `VK_EXT_memory_budget`，allocator 加 `VMA_ALLOCATOR_CREATE_EXT_MEMORY_BUDGET_BIT`，并且**每帧调一次 `vmaSetCurrentFrameIndex()`**，在该调用内查询 budget（避免每次分配都查）。`VkPhysicalDeviceMemoryBudgetPropertiesEXT` 提供按 heap 的 `heapBudget[]`/`heapUsage[]`〔规范〕。
- **控制手段**：默认策略会尽量不超预算（默认块建议尺寸如 256 MB，超预算则用更小的块甚至 dedicated）；`VMA_ALLOCATION_CREATE_WITHIN_BUDGET_BIT` 让超预算直接失败（适合非关键资源，不适合 render target）；`VMA_ALLOCATION_CREATE_NEVER_ALLOCATE_BIT` 只允许放进已有块（调用极快，永不触发新分配，适合每帧临时资源）〔厂商文档〕。
- **适用条件**：所有产品。**风险**：budget 是"建议值"，不是硬保证；不要用它替代自己的峰值估算。

### D.6 分配抖动与碎片

- **症状**：帧时间随运行时长缓慢上升；同 workload 下 `vkAllocateMemory` 越来越慢；分辨率切换后内存占用不回落。
- **成因**：① 每帧分配/释放（应改为环形/池化）；② 大小混合（大 render target 与小 UBO 落在同一块）；③ 缺 dedicated 阈值（大资源应显式 dedicated）。
- **该做**：资源按生命周期分层（永久 / 每曲目 / 每帧 / 每 pass），每层独立池/块；分辨率变化时整层重建而不是零散释放。
- **验证**：`vmaCalculateStatistics()` 打印 block 数、unused bytes、largest free block（只在调试构建）。

### D.7 D 节检查清单

- [ ] 所有分配是否走同一个 allocator？有没有裸 `vkAllocateMemory` 混进来（QRhi 侧可能有一份）？
- [ ] 每帧是否 map/unmap？是否整块 flush 而不是区间？
- [ ] 是否探测过 UMA 的 DEVICE_LOCAL|HOST_VISIBLE 类型？staging 路径是否多余？
- [ ] 是否用 `VK_EXT_memory_budget` + `vmaSetCurrentFrameIndex`？
- [ ] 分辨率切换后内存是否回落？

---

## E. 渲染结构（dynamic rendering / render pass / subpass / MSAA）

**该做**：动态渲染 + 严格的 load/store 纪律；需要 tile 内存复用时才考虑 subpass；MSAA resolve 走 attachment，不要 `vkCmdResolveImage`。
**别做**：为了"兼容老驱动"维护两套路径；用 `vkCmdClearAttachments` 代替 `loadOp = CLEAR`；把 depth/MSAA 的 storeOp 留成 `STORE`。

### E.1 动态渲染 vs VkRenderPass/VkFramebuffer 在驱动层的差别

- **机制**：官方指南原话：动态渲染用 `VkRenderingInfo` 里**同样的** load/store 操作，"hardware logic remains identical"，但代码更简单；仍须严守 load/store 纪律，否则一样回退〔规范/官方指南〕([TBR best practices](https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html))。
- **CPU 侧差别**：动态渲染省掉 `VkRenderPass`/`VkFramebuffer` 的创建与兼容性管理（也就省掉"render pass 兼容性"这一整类 bug），但**不省**驱动内部工作——tile-based 驱动仍要在 binning pass 里知道 attachment 配置。
- **iGPU/驱动侧的真实风险**：动态渲染允许把一次 render pass 拆成多个 `vkCmdBeginRendering`，而 tiling GPU 的 tile 内存只在"一个连续的 rendering 实例"里有效，拆开就会溢出到内存。社区（Turnip 驱动开发者）直接形容 dynamic rendering 在 tiling GPU 上"especially nasty"，正是这个原因〔社区经验〕([Igalia](https://blogs.igalia.com/dpiliaev/turnip-vulkan-1-3/))。
- **该做什么**：用动态渲染，但**一个 pass 一个 `vkCmdBeginRendering`**，中间不要插入需要 flush 的操作；用 `VkRenderingAttachmentInfo` 明确 load/store。
- **适用条件**：Vulkan 1.3 及以上（`VK_KHR_dynamic_rendering` 已 core）。**不适用**：真需要 subpass 的 tile 内数据复用（见 E.2）。

### E.2 subpass 是否仍值得

- **机制**：传统 render pass 让驱动能"merge"相邻 subpass，合并后中间数据（G-buffer 之类）**全留在 tile memory**，不写回主存；合并不保证、依赖实现〔规范/官方指南〕。
- **怎么知道合没合**：`VK_EXT_subpass_merge_feedback` 可直接告诉你某次 subpass 是否真被合并〔规范/官方指南〕。没有这个反馈就谈"subpass 省带宽"是猜。
- **鼓励合并的做法**：subpass dependency 保持简单，避免 Global 依赖（pipeline barrier、descriptor set update）——它们会逼驱动拆分〔规范/官方指南〕。
- **动态渲染的替代**：`VK_KHR_dynamic_rendering_local_read` 提供类似收益（`vkCmdSetRenderingAttachmentLocationsKHR` 把 attachment 映射到 input index，shader 用 `subpassInput`/`subpassLoad`）〔规范/官方指南〕。
- **结论**：本项目的渲染结构（可视化 + FSR 后处理链）pass 数不多、pass 间有全屏依赖，subpass 收益有限；**只有当"两个 pass 之间只差一次 tile 内读"时才值得引入**，且必须用 merge feedback 验证。
- **transient 内存**：`VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT` + `VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT` 可让部分 GPU **完全不分配物理内存**（只存在 tile memory），适合"只在 pass 内用、绝不采样"的 depth/MSAA attachment〔规范/官方指南〕。

### E.3 attachment 复用与 render pass 兼容性

- **机制**：render pass 兼容性由 attachment 的 format/samples/usage + subpass 结构决定；不兼容就要新建 render pass + framebuffer，且已绑定的 PSO 可能失效。动态渲染把这层约束变成"每次 begin 时给 attachment 描述"，但**驱动仍会因 attachment 配置变化而重建内部状态**。
- **该做**：把 swapchain image 的 format/usage 固定下来（不要在同一帧里混用 sRGB/UNORM 视图）；render target 池按 (format, usage, size) 做 key，同 key 复用同一批 image 与同一批 PSO。
- **风险**：`VK_KHR_imageless_framebuffer` 能减少 framebuffer 数量，但不会减少"配置变化导致的驱动内部重建"。

### E.4 resolve 与 MSAA 的 API 形态

- **机制（tile-based 关键点）**：MSAA 的 resolve 可以**全在片上完成**——把 multisampled attachment 的 `storeOp` 设成 `DONT_CARE`，并在同一个 subpass/render 里提供 resolve attachment 即可触发；**避免 `vkCmdResolveImage`**，它强制往返主存〔规范/官方指南〕。
- **API 形态**：`VkRenderingAttachmentInfo::resolveMode = VK_RESOLVE_MODE_AVERAGE_BIT`（或 `VK_KHR_multisampled_render_to_single_sampled` 走"隐式 MSAA"：不建 multisampled image，只建单采样 image + 内部 resolve）。
- **代价/风险**：MSAA 增加 tile 内存占用（"attachment 数量/格式/MSAA 决定每像素占用"），格式位深小可选择更大 tile 或避免溢出〔规范/官方指南〕。iGPU 上 4x MSAA 的带宽代价比 discrete 更明显。
- **适用条件**：需要抗锯齿且没有上采样方案时。本项目已有 FSR 上采样，MSAA 与超分叠加通常不划算（先吃超分收益，再考虑 MSAA）。

### E.5 E 节检查清单

- [ ] 是否有 `loadOp = LOAD` 但其实每帧全屏覆盖？（应 `CLEAR` 或 `DONT_CARE`）
- [ ] depth / MSAA / transient attachment 的 `storeOp` 是否都是 `DONT_CARE`/`NONE`？
- [ ] 是否用了 `vkCmdResolveImage`？（应改为 attachment resolve）
- [ ] 一帧里有几个 `vkCmdBeginRendering`？是否把本该连续的 pass 拆开了？
- [ ] 有没有用 `VK_EXT_subpass_merge_feedback` 验证过"subpass 真的合并了"？

---

## F. 校验与调试的成本

**该做**：开发构建默认 core + sync validation；GPU-AV 与 best practices 按需开、按范围开；发布版彻底关掉。
**别做**：性能测量时保留任何 layer；多线程录制时用老版本校验层；把逐命令 debug 标签留在发布版。

### F.1 各特性的影响量与使用策略

| 特性 | 影响量级 | 什么时候开 | 依据 |
|---|---|---|---|
| Core validation | 明显；多线程时可能是最大项（见 F.2） | 开发构建默认 | 〔厂商文档〕 |
| Synchronization validation | 需显式启用，覆盖 barrier / hazard 检查 | 改同步代码时开，平时关 | 〔厂商文档〕 |
| Best practices | 中（逐调用启发式检查） | 调优阶段开一轮 | 〔厂商文档〕 |
| GPU-AV | 很大；"完美校验可以慢到 multiple seconds a frame" | 只在怀疑越界/OOB 时开，且用 Scoped GPU-AV 限定区域 | 〔厂商文档〕 |
| GPU-AV + Core 同时开 | "performance will be slow"（官方明确不建议） | 不要 | 〔厂商文档〕 |

- **GPU-AV 的硬成本**：需要 **1 个 descriptor set**（会让 `maxBoundDescriptorSets` 减 1），需要 `fragmentStoresAndAtomics`/`vertexPipelineStoresAndAtomics`/`timelineSemaphore`；默认关 Safe Mode（Regression Mode，追求快），"Force robustness on"可再提速，Scoped GPU-AV 只校验指定区域以提速〔厂商文档〕([LunarG](https://vulkan.lunarg.com/doc/view/latest/windows/gpu_validation.html))。
- **同步校验**：Vulkan 的排序保证有限，缺同步是"看起来能跑"的典型 bug；LunarG 的白皮书专门讲怎么用、怎么优化它〔厂商文档〕([Khronos blog](https://www.khronos.org/blog/a-guide-to-vulkan-synchronization-validation))。
- **策略**：CI 里跑"无 layer 的基准 + 有 core/sync 的功能测试"两套；性能回归只看前者。

### F.2 多线程与校验层的锁

- **机制**：校验层要在每个 `vkFoo` 的 Pre/PostCallRecord 阶段持 read/write lock；多线程程序里这把锁会成为"启用校验后的最大性能成本"，并且它还会限制层内优化空间〔厂商文档/官方仓库〕([VVL fine_grained_locking.md](https://github.com/KhronosGroup/Vulkan-ValidationLayers/blob/master/docs/fine_grained_locking.md))。
- **量级**：该文档写明 fine-grained locking "has been tested with 15+ released games and improves performance in almost all of them, **and many improve by about 150%**"——即老版本校验层在多线程游戏上可能吃掉一倍以上性能〔实测/案例〕。
- **该做什么**：用较新的 SDK；多线程录制时确认 layer 版本带 fine-grained locking；性能测量一定关 layer。

### F.3 VK_EXT_tooling_info

- **机制**：查询"当前到底有哪些工具在跑"——`vkGetPhysicalDeviceToolPropertiesEXT()` 返回每个 tool 的 name/version/purposes。用途：判断"advertised limits 与预期不符是不是某个工具改的"、"应用提供了 debug marker 但实现没在处理"〔规范〕([refpage](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_tooling_info.html))。已晋升 Vulkan 1.3 core。
- **该做什么**：启动日志打印一次（含 `VK_TOOL_PURPOSE_PROFILING`/`TRACING`/`VALIDATION` 标志），出问题时第一眼能看到"是不是 RenderDoc 还挂着"。
- **风险**：几乎没有——一次查询，不进入渲染循环。

### F.4 debug utils 命名与标签的发布版开关

- **机制**：`vkSetDebugUtilsObjectNameEXT` 是**一次性成本**（对象创建时），可以留在发布版（便于崩溃转储/抓帧对照）；`vkCmdBeginDebugUtilsLabelEXT`/`vkCmdEndDebugUtilsLabelEXT` 是**逐命令成本**，每条都是一次 API 调用 + 命令缓冲字节。
- **该做**：对象命名保留（成本一次性）；**命令级标签用宏开关**，发布版编译掉；不要每 draw 一对 label。
- **风险**：layer 未启用时这些调用是空操作，但仍要经过 loader/驱动的 dispatch，不是零成本。

### F.5 F 节检查清单

- [ ] 发布版是否 100% 不加载任何 layer？（含 `VK_INSTANCE_LAYERS`、SDK 的 implicit layer）
- [ ] 命令级 debug label 是否被编译掉？
- [ ] 是否打印过 `VK_EXT_tooling_info`？
- [ ] 性能基准是否在"无 layer + release"下采集？

---

## G. 反模式清单 + 用什么计数验证

### G.1 反模式表

| # | 反模式 | 机制（为什么慢） | 替代 | 验证计数 |
|---|---|---|---|---|
| 1 | 创建 pipeline 传 `VK_NULL_HANDLE` | 每次全量编译/构建内部状态 | 全进程单一 `VkPipelineCache` + 落盘 | PSO 创建次数、feedback duration 累计 |
| 2 | 渲染帧内首次使用才建 PSO | 编译落在关键路径 → 掉帧 | 启动/加载期后台预热 | 抓帧中 `vkCreateGraphicsPipelines` 是否在帧中间 |
| 3 | 每帧 reset 池 + 重建 descriptor | 分配与更新成本全在 CPU；实测 44→27 ms（-38%） | 持久 set + 缓存 + dynamic offset | `vkUpdateDescriptorSets`/`vkAllocateDescriptorSets` 次数/帧 |
| 4 | 每 draw 调 `vkUpdateDescriptorSets` | 更新可能比 draw 还贵 | push constant / dynamic offset | 同上，按 draw 归一化 |
| 5 | 每帧 alloc/free command buffer | 实测占 CPU 采样 28.8% | 每线程池 + `vkResetCommandPool` | `vkAllocateCommandBuffers` 次数/帧 |
| 6 | 为逐缓冲 reset 打开 `RESET_COMMAND_BUFFER_BIT` | 每缓冲独立 allocator；实测 1.16% vs 0.45% | 整池 reset | pool flags、`vkResetCommandBuffer` 次数 |
| 7 | 每 draw 重绑同 PSO / 重设同值动态状态 | 冗余 API 调用与命令字节 | 录制端影子状态 | 命令数/draw 比 |
| 8 | `ALL_GRAPHICS` → 自身的宽 barrier | 破坏 binning 与 fragment 重叠 | 精确 stage/access 的 barrier | barrier 数、stage 掩码分布 |
| 9 | `vkCmdResolveImage` 做 MSAA resolve | 强制往返主存 | attachment resolve + `storeOp=DONT_CARE` | resolve 调用次数、带宽计数器 |
| 10 | `vkCmdClearAttachments` 代替 `loadOp=CLEAR` | 走渲染管线而非 tile 初始化 | `VK_ATTACHMENT_LOAD_OP_CLEAR` | clear 调用次数 |
| 11 | 每帧 map/unmap 上传缓冲 | 页表/TLB 操作 | 持久映射 + 环形缓冲 | `vkMapMemory` 次数/帧 |
| 12 | per-resource `vkAllocateMemory` | 驱动级分配很慢，逼近 `maxMemoryAllocationCount` | VMA 子分配 | 分配次数、block 数 |
| 13 | 每 draw 一对 debug label（发布版） | 逐命令 API 成本 | 编译期宏关掉 | 命令级 label 数/帧 |
| 14 | 性能测量时开着 validation | 多线程锁竞争（实测部分游戏 ~150%） | 测量时关 layer | 实例层列表、`VK_EXT_tooling_info` |
| 15 | 两套 PSO 缓存（QRhi 一份、自建层一份） | 互不命中，命中率减半 | 复用同一个 `VkPipelineCache` | 缓存 blob 大小、hit 比例 |

### G.2 计数与工具矩阵

- **必须自己埋的计数（每帧/每次运行）**：
  - `vkCreate*Pipelines` 次数与 `VkPipelineCreationFeedback.duration` 总和；
  - `vkUpdateDescriptorSets` 次数、`vkAllocateDescriptorSets` 次数；
  - `vkAllocateCommandBuffers`/`vkResetCommandBuffer`/`vkResetCommandPool` 次数；
  - `vkQueueSubmit` 次数、pipeline barrier 次数、`vkCmdBindPipeline` 次数（可按 draw 归一化）；
  - `vkMapMemory`/`vkFlushMappedMemoryRanges` 次数与字节数。
  - 实现方式：这些函数都经 driver dispatch，最省事的做法是在自己的封装层加计数器（不要 hook 驱动）。
- **抓帧/剖析工具**：
  - **RenderDoc**：看"一帧里有哪些 API 调用、PSO 绑定切换序列"，直接回答"有多少冗余"；
  - **Intel GPA / VTune**：Intel 官方推荐用于 CPU/GPU 瓶颈定位〔厂商文档〕([Intel](https://www.intel.com/content/www/us/en/developer/articles/guide/developer-and-optimization-guide-for-intel-processor-graphics-gen11-api.html))；
  - **AMD Radeon GPU Profiler / NVIDIA Nsight**：discrete 侧对照；
  - **Streamline Performance Analyzer**：Khronos 样例用它确认"CPU bound 而 GPU idle"〔实测/案例〕([samples/descriptor_management](https://docs.vulkan.org/samples/latest/samples/performance/descriptor_management/README.html))；
  - **validation 层 Best Practices**：会直接对"每帧重建 descriptor""不必要 storeOp"等给警告——最便宜的反模式检测器。
- **判据**：GPU 帧时间稳定但 CPU 帧时间长 → 走 §A~C；CPU 时间不长但帧率不够、GPU 在等带宽 → 走 §D~E（iGPU 尤其看 load/store 与 resolve）。两者都看 RenderDoc 的"每帧 API 调用数"，它是最直接的链路开销指标。

### G.3 本项目的落地顺序（Qt + QRhi + 自建呈现层 + FSR3）

1. **先统一资源所有权**：确认 QRhi 与自建层是否各有一份 pipeline cache / descriptor pool / allocator。两份意味着命中率减半、内存翻倍。最小改动是"自建层复用 QRhi 已创建的 `VkPipelineCache`（若可得），否则在自建层建一个并在所有自建 PSO 间共享"。
2. **给 FSR3/上采样链的 PSO 做启动预热**：这些 pass 的 shader 固定，第一次出现的编译掉帧完全可以挪到加载期；用 `VkPipelineCreationFeedback` 量化"预热省了多少 ms"。
3. **把每帧描述符更新打到 0**：音乐可视化的 per-frame 数据（频谱、时间、音量）走 push constant 或一个大 UBO 的 dynamic offset；纹理只在加载时建 set。
4. **命令缓冲改为每帧整池 reset**，把 `vkAllocateCommandBuffers` 从帧循环里彻底移除。
5. **测量纪律**：所有基准在"release + 无 layer"下采集；对照组的唯一变量是本次改动。

---

## 参考来源

**规范 / Khronos 官方（一手）**

1. [Vulkan Guide · Pipeline Cache](https://docs.vulkan.org/guide/latest/pipeline_cache.html) — 管线缓存复用与跨进程落盘的动机与官方推荐做法。
2. [Vulkan Spec · Pipelines（Pipeline Cache 章）](https://docs.vulkan.org/spec/latest/chapters/pipelines.html) — 缓存对象的多线程语义、`EXTERNALLY_SYNCHRONIZED`、`vkGetPipelineCacheData` 的 VUID 约束。
3. [VkPipelineCreationFeedback](https://docs.vulkan.org/refpages/latest/refpages/source/VkPipelineCreationFeedback.html) — feedback 结构、纳秒单位、VALID_BIT 语义。
4. [VkPipelineCreationFeedbackFlagBits](https://docs.vulkan.org/refpages/latest/refpages/source/VkPipelineCreationFeedbackFlagBits.html) — CACHE_HIT 与 BASE_PIPELINE_ACCELERATION 的置位条件与 1%/50% 判据。
5. [Khronos Blog · Bringing Explicit Pipeline Caching Control to Vulkan](https://www.khronos.org/blog/bringing-explicit-pipeline-caching-control-to-vulkan) — VK_KHR_pipeline_binary 的动机、多 blob 结构、全局 key 失效、异步建 binary 抗卡顿。
6. [Khronos Blog · Reducing Draw-time Hitching with VK_EXT_graphics_pipeline_library](https://www.khronos.org/blog/reducing-draw-time-hitching-with-vk-ext-graphics-pipeline-library) — GPL 四段拆分、所需动态状态清单、INDEPENDENT_SETS 分区、Source 2 的 fast-linking 策略。
7. [Khronos Blog · You Can Use Vulkan Without Pipelines Today](https://www.khronos.org/blog/you-can-use-vulkan-without-pipelines-today) — shader object 的语义差异、CTS 性能门槛（150%/120%/150%）、"别每 draw 重设全部 state"。
8. [Vulkan Guide · VK_EXT_descriptor_indexing](https://docs.vulkan.org/guide/latest/extensions/VK_EXT_descriptor_indexing.html) — update-after-bind 三件套、partially bound、动态/非一致索引。
9. [VK_EXT_descriptor_buffer · Feature Proposal](https://docs.vulkan.org/features/latest/features/proposals/VK_EXT_descriptor_buffer.html) — 每帧数万 descriptor 的更新开销、consume-and-repack 模型、layout 互斥与替代方案。
10. [Vulkan Guide · Descriptor Buffer](https://docs.vulkan.org/guide/latest/descriptor_buffer.html) — vkGetDescriptorEXT/vkCmdSetDescriptorBufferOffsetsEXT 用法、256 字节对齐、barrier 要求。
11. [VK_KHR_push_descriptor refpage](https://docs.vulkan.org/refpages/latest/refpages/source/VK_KHR_push_descriptor.html) — 扩展语义、"in some cases more efficient"、晋升 Vulkan 1.4。
12. [Vulkan Spec · Limits](https://docs.vulkan.org/spec/latest/chapters/limits.html) — maxPushDescriptors、maxPushConstantsSize 等上限定义。
13. [Vulkan Samples · Descriptor and Buffer Management](https://docs.vulkan.org/samples/latest/samples/performance/descriptor_management/README.html) — 44 ms/23 FPS → 27 ms/37 FPS（-38%）实测、set 缓存与 buffer 管理、FREE_DESCRIPTOR_SET_BIT 的分配器影响。
14. [Vulkan Samples · Command Buffer Usage](https://docs.vulkan.org/samples/latest/samples/performance/command_buffer_usage/README.html) — 三种回收策略实测占比（0.45%/1.16%/28.8%）与 best practices 摘要。
15. [Vulkan Spec · Command Buffers](https://docs.vulkan.org/spec/latest/chapters/cmdbuffers.html) — ONE_TIME_SUBMIT/SIMULTANEOUS_USE 语义、InheritanceInfo 与"传精确 framebuffer 可能更快"。
16. [Vulkan Guide · Memory Allocation](https://docs.vulkan.org/guide/latest/memory_allocation.html) — 子分配是一等做法、驱动级分配很慢、UMA 内存类型选择、LAZILY_ALLOCATED。
17. [Vulkan Guide · Embedded Programming](https://docs.vulkan.org/guide/latest/embedded_programming.html) — UMA 下"每一字节传输都耗电并争抢带宽"。
18. [Vulkan Guide · Tile Based Rendering Best Practices](https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html) — load/store 纪律、subpass merge 与 feedback、transient/lazily allocated、MSAA 片上 resolve、避免宽 barrier。
19. [VK_EXT_tooling_info refpage](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_tooling_info.html) — 查询活跃工具及其 purpose 标志。
20. [Khronos Blog · A Guide to Vulkan Synchronization Validation](https://www.khronos.org/blog/a-guide-to-vulkan-synchronization-validation) — 同步校验层的用途与 LunarG 白皮书入口。

**厂商文档（IHV / ISV 一手）**

21. [NVIDIA · Advanced API Performance: Pipeline State Objects](https://developer.nvidia.com/blog/advanced-api-performance-pipeline-state-objects/) — 后台线程建 PSO、idle 优先级、泛化先上线、不要一次性序列化海量 PSO。
22. [NVIDIA · Advanced API Performance: Descriptors](https://developer.nvidia.com/blog/advanced-api-performance-descriptors/) — push/root constant 最快、descriptor table 两次间接、1M/2K 经验上限、binding 不要过度稀疏。
23. [NVIDIA · Advanced API Performance: Command Buffers](https://developer.nvidia.com/blog/advanced-api-performance-command-buffers/) — 录制是 CPU 密集、每帧 5~10 次提交、50~80 µs 调度成本、不要频繁混 draw/dispatch/copy。
24. [Arm · Vulkan Mobile Best Practices: Descriptor and Buffer Management](https://community.arm.com/arm-community-blogs/b/graphics-gaming-and-vr-blog/posts/vulkan-descriptor-and-buffer-management) — 移动端每帧重建 descriptor 的低效、set 缓存与单一大 buffer + dynamic offset 的收益。
25. [Arm · GPU Best Practices: Optimizing descriptor sets and layouts](https://developer.arm.com/documentation/101897/0304/CPU-overheads/Optimizing-descriptor-sets-and-layouts-for-Vulkan) — descriptor set/layout 组织的官方最佳实践（补充读物）。
26. [VMA · Recommended usage patterns](https://gpuopen-librariesandsdks.github.io/VulkanMemoryAllocator/html/usage_patterns.html) — AUTO/dedicated/priority、顺序写与随机读的 host access flag、持久映射。
27. [VMA · Staying within budget](https://gpuopen-librariesandsdks.github.io/VulkanMemoryAllocator/html/staying_within_budget.html) — 超额分配的后果、vmaGetHeapBudgets 与 VK_EXT_memory_budget 的接法、WITHIN_BUDGET/NEVER_ALLOCATE 用途。
28. [Intel · Developer and Optimization Guide for Intel Processor Graphics Gen11](https://www.intel.com/content/www/us/en/developer/articles/guide/developer-and-optimization-guide-for-intel-processor-graphics-gen11-api.html) — PTBR/tile-based 架构、L3 保留 per-tile 数据、descriptor heap 切换"严重停顿"、push/root constant 优先。
29. [LunarG · GPU Assisted Validation](https://vulkan.lunarg.com/doc/view/latest/windows/gpu_validation.html) — GPU-AV 开关策略、descriptor set/feature 需求、"multiple seconds a frame"的极端成本、Scoped GPU-AV。

**官方仓库 / 社区**

30. [KhronosGroup/Vulkan-ValidationLayers · fine_grained_locking.md](https://github.com/KhronosGroup/Vulkan-ValidationLayers/blob/master/docs/fine_grained_locking.md) — 校验层全局锁是多线程下最大开销；15+ 游戏实测，多数提升约 150%。
31. [Igalia · Turnip Vulkan 1.3](https://blogs.igalia.com/dpiliaev/turnip-vulkan-1-3/) — 驱动开发者视角：dynamic rendering 在 tiling GPU 上容易把 render pass 拆开（社区经验，未逐段核对）。
