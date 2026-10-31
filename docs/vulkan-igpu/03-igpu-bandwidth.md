# 核显（iGPU）上的 Vulkan：内存模型、带宽、瓦片语义与平台差异

> 面向本仓库的 Qt + 自研 Vulkan 呈现层（原生 `VkDevice`/`VkQueue`、自建 `VkSwapchainKHR`、FSR3 帧生成 + FSR 上采样）。本文只讨论 **Vulkan 链路本身**：内存类型选择、带宽预算、render pass / attachment 语义、图像布局与压缩、呈现与帧节奏、平台差异。3D 场景侧手段（LOD、剔除、批处理、光照、后处理配方）不在范围内，仅在解释机制时顺带提及。
>
> 证据等级标记：〔规范〕= Vulkan 规范 / Khronos 官方指南；〔厂商文档〕= Intel / AMD / Arm / Imagination / Microsoft / Apple 官方；〔实测/案例〕= 可复现的工程报告或驱动源码注释；〔社区经验〕= 广泛流传但无一手文档，需自行验证；〔算术推导〕= 由公开规格做单位换算得到，不是实测。**本文不含任何编造的基准数字**：所有 GB/s 数字要么是从内存规格换算的峰值（标注换算过程），要么明确标为经验区间。

## 0. 结论先行

1. **核显没有独立显存**：`DEVICE_LOCAL` 与 `HOST_VISIBLE` 常落在同一个 memory type 上，独显那套「staging → device local」的上传路径在核显上是**净损失**（多一次全量 DRAM 往返）。
2. **带宽是硬上限，且是与 CPU 共享的**：一颗 28W 级核显配 LPDDR5X-7467 双通道只有约 119.5 GB/s 峰值（算术），4K@120 下十个全屏 pass 就能吃掉 80 GB/s。优化的第一性问题永远是「这一帧我为像素搬运了几次」。
3. **`loadOp`/`storeOp` 是核显上最便宜也最有效的开关**：在瓦片式（TBDR）GPU 上它直接决定数据是否离开片上 tile memory；在立即模式（Intel/AMD 核显）上它决定 fast-clear 与带宽压缩能否生效。两边规则一致，不需要两套代码路径。
4. **`VK_IMAGE_TILING_LINEAR` 在核显上基本等于放弃压缩**：几乎所有带宽压缩（AFBC/UBWC/DCC）都要求 tiling 布局，linear 图像往往连快速清屏都用不上。
5. **刷新率未知，就不能用 fps 判断瓶颈**：本项目一律按「刷新率未知/无穷」处理——`FIFO` 可能被驱动或合成器按真实刷新节流，也可能等价于 `immediate`；判据改用 GPU busy、present 阻塞时长、submit 耗时、队列堆积深度。
6. **不设帧率上限，跑满即目标**：功耗与降频只作为硬件风险提示记录，不作为限帧或降负载的理由；pacing 的目标是**最小化排队与阻塞**，而不是对齐某个刷新周期。

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。
---

## A. 内存模型：UMA、`DEVICE_LOCAL` 与 `HOST_VISIBLE`

**该做**：启动时做一次 UMA 判定，然后选一条上传路径；把 UMA 当成「一个内存池 + 一个可用预算」来管理。
**别做**：无条件照搬独显的两段式上传；也不要假设 `DEVICE_LOCAL` 一定不可映射。

### A1 · 运行时判定是不是 UMA

- **机制**：规范允许同一个 memory type 同时带 `DEVICE_LOCAL` 与 `HOST_VISIBLE`，这就是 UMA 的典型标志；Khronos 指南把它直接写成「UMA 通过 `VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT | VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT` 的组合表示」〔规范〕。
- **Vulkan**：遍历 `VkPhysicalDeviceMemoryProperties::memoryTypes`，找 `(flags & (DEVICE_LOCAL|HOST_VISIBLE)) == (DEVICE_LOCAL|HOST_VISIBLE)` 的类型；再用 `VkPhysicalDeviceProperties::deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU` 交叉确认。注意 `deviceType` 只是提示，**heap 结构才是事实**（某些 ARM SoC 会报 `CPU`/`OTHER`）。
- **代价/风险**：判定结果要参与资源创建决策（见 A2），判错只影响性能，不影响正确性。
- **适用条件**：所有平台都该做；判成 UMA 后**不要**再为「显存放不下」写回退路径。
- 依据：[Khronos Vulkan Guide · Memory Allocation](https://docs.vulkan.org/guide/latest/memory_allocation.html)、[VkMemoryPropertyFlagBits](https://docs.vulkan.org/refpages/latest/refpages/source/VkMemoryPropertyFlagBits.html)。

### A2 · UMA 上不需要 staging buffer

- **机制**：独显上 CPU 写入要先落 staging（HOST_VISIBLE），再 `vkCmdCopyBuffer` 到 device local；UMA 上「device local」本身就是系统内存，CPU 可直接映射写入，省掉一次拷贝与一次同步〔规范〕。
- **Vulkan**：为顶点/UBO/纹理上传建一个 `DEVICE_LOCAL|HOST_VISIBLE`（优先再带 `HOST_COHERENT`）的持久映射环形缓冲；`vkMapMemory` 一次，之后每帧只写指针偏移，非 coherent 时用 `vkFlushMappedMemoryRanges` + 对齐 `VkPhysicalDeviceLimits::nonCoherentAtomSize`。
- **代价/风险**：CPU 写入的缓存行会被 GPU 读取，产生**读写交替**的 DRAM 效率损失；写得太碎（每帧几百次小 map/flush）比拷贝还慢。
- **适用条件**：静态/低频数据（纹理、mesh、常量）直接映射写；每帧被 GPU 高频采样的数据如果 CPU 侧写得很碎，仍然值得保留一次 staging 拷贝把它变成一次顺序大块写。
- 依据：[Khronos · Memory Allocation](https://docs.vulkan.org/guide/latest/memory_allocation.html)（原文：UMA 下「there is no need to create a staging buffer and the transfer overhead is greatly reduced」，代价是「system memory has to be shared with the GPU」）。

### A3 · 一致性（coherency）、缓存与写合并

- **机制**：`HOST_COHERENT` 表示不需要 `vkFlushMappedMemoryRanges`/`vkInvalidateMappedMemoryRanges`；`HOST_CACHED` 表示这块内存对 CPU **有缓存**——规范明确写「对未缓存内存的主机访问比对缓存内存慢，但未缓存内存总是 host coherent」〔规范〕。x86 上「可映射但无 `HOST_CACHED`」的类型通常实现为 write-combining（WC）内存。
- **Vulkan**：① 写多读少的流式缓冲选「`HOST_VISIBLE|HOST_COHERENT` 但不带 `HOST_CACHED`」；② 任何需要 CPU **读**的东西（回读、统计、GPU 时间戳拷贝）必须挑带 `HOST_CACHED` 的类型，否则 CPU 会逐字节走 uncached 读，慢一个数量级〔厂商文档〕；③ 非 coherent 时的 flush 范围按 `nonCoherentAtomSize` 向上取整。
- **代价/风险**：WC 内存不适合 CPU 做读-改-写或随机小写；一旦 CPU 侧对同一 cache line 写两次不连续位置，写合并就会失效。
- **适用条件**：Adreno 在 Mesa 文档里被描述为「mostly write combined memory but with the ability to map some buffers as cache coherent with the CPU」，正是这个模型〔实测/案例〕。
- 依据：[VkMemoryPropertyFlagBits](https://docs.vulkan.org/refpages/latest/refpages/source/VkMemoryPropertyFlagBits.html)、[AMD GPUOpen · Using Vulkan Device Memory](https://gpuopen.com/learn/vulkan-device-memory)（回读必须 `HOST_VISIBLE|HOST_COHERENT|HOST_CACHED`）、[Mesa freedreno](https://docs.mesa3d.org/drivers/freedreno.html)。

### A4 · 预算感知：`VK_EXT_memory_budget` 在 UMA 上是必需品而非可选

- **机制**：UMA 上「显存」就是系统内存，浏览器、Qt、波形缓存、其它进程都在抢；`VK_EXT_memory_budget` 的 `heapBudget`/`heapUsage` 给出「当前进程还能用多少」的估计，规范说明其值依赖 OS 与系统负载〔规范〕。
- **Vulkan**：链 `VkPhysicalDeviceMemoryBudgetPropertiesEXT` 到 `VkPhysicalDeviceMemoryProperties2`，**每帧或每几秒**查一次；超预算时先降 swapchain 分辨率/关闭帧生成，而不是等 `VK_ERROR_OUT_OF_DEVICE_MEMORY`。可选叠加 `VK_EXT_memory_priority` 给 render target / swapchain 图像更高优先级。
- **代价/风险**：`heapBudget` 是启发式值，不是硬保证；轮询过于频繁会引入 CPU 开销（实测通常可忽略，但别放进每帧热路径的最内层）。
- **适用条件**：所有 UMA 设备；独显上同样有用（VRAM 满时驱动会挪到系统内存，性能断崖）。
- 依据：[VK_EXT_memory_budget](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_memory_budget.html)、[VK_EXT_memory_priority](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_memory_priority.html)。

### A5 · Resizable BAR / SAM：对独显有意义，对核显无意义

- **机制**：独显上 CPU 能映射的 VRAM 窗口长期受限于 BAR 大小；GPUOpen 给出的经验阈值是「小于 256 MB 的上传场景，`DEVICE_LOCAL|HOST_VISIBLE` 是最理想的类型」（暗示窗口有限）〔厂商文档〕。ReBAR/SAM 把该窗口放大到接近整个 VRAM，从而让「直接写显存」在独显上也成立。核显本来就只有一块可映射内存，**没有窗口问题**，所以 ReBAR 对核显性能无可观测影响。
- **Vulkan**：不要为 ReBAR 写专门代码——它表现为 `VkPhysicalDeviceMemoryProperties` 里 `DEVICE_LOCAL|HOST_VISIBLE` 类型的 `heapIndex`/可用大小变化，A2 的路径自动受益。
- **代价/风险**：如果把「直接映射写显存」当成默认路径，在**未开 ReBAR 的独显**上会退化成跨 PCIe 的慢速映射，帧率断崖。
- **适用条件**：本项目的核显目标机 —— 忽略 ReBAR；若要兼容独显笔记本，用 A1 的判定分流。
- 依据：[AMD GPUOpen · Using Vulkan Device Memory](https://gpuopen.com/learn/vulkan-device-memory)。ReBAR 的具体窗口语义本轮未抓到一手规格页，标〔未验证〕。

### A6 · 映射粒度与「一次大分配 + 自行 sub-allocation」

- **机制**：`vkAllocateMemory` 在多数驱动上是重量级操作（可能触发内核态分配/迁移）；Khronos 指南建议应用创建大分配并自行管理〔规范〕。UMA 上频繁分配还会加剧内存碎片与预算抖动。
- **Vulkan**：按「用途 + memory type」分几个大 `VkDeviceMemory` 池（例如：图像池、顶点池、上传环形池），用 `vkBindImageMemory2`/`vkBindBufferMemory2` 绑到偏移；`VkMemoryAllocateInfo::pNext` 挂 `VkMemoryDedicatedAllocateInfo`（仅驱动要求时）。跨进程共享或与显示栈共享时再考虑 `VK_EXT_external_memory_host` 导入宿主指针（要求地址与大小按 `minImportedHostPointerAlignment` 对齐）〔规范〕。
- **代价/风险**：自己管池要处理对齐（`VkMemoryRequirements::alignment`）、图像/缓冲区不能重叠绑定、以及 resize 时的整池重建。
- **适用条件**：所有平台；对**每帧新建 swapchain 图像 / FSR 中间纹理**的项目尤其重要（分辨率切换会反复分配）。
- 依据：[Khronos · Memory Allocation](https://docs.vulkan.org/guide/latest/memory_allocation.html)、[VK_EXT_external_memory_host](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_external_memory_host.html)。

### A7 · 不要为了「设备本地」再拷一次

- **机制**：有些移植代码会把「上传缓冲」再 `vkCmdCopyBuffer` 到「device local」缓冲。UMA 上两者是同一块物理内存，这次拷贝是纯浪费（读+写各一遍全量数据），并且插入一次 barrier。
- **Vulkan**：创建时直接请求 `DEVICE_LOCAL|HOST_VISIBLE` 并把 `usage` 设全（`VERTEX_BUFFER|UNIFORM_BUFFER|TRANSFER_DST`），只保留一份。
- **代价/风险**：某些驱动对「同时 host visible 的 device local」有额外限制（如不允许作为 `STORAGE_BUFFER` 高频写目标），需要用 `vkGetPhysicalDeviceImageFormatProperties`/`vkGetBufferMemoryRequirements` 逐用例确认。
- **适用条件**：仅在 A1 判定为 UMA 时启用；独显上保留原路径。
- 依据：[Khronos · Memory Allocation](https://docs.vulkan.org/guide/latest/memory_allocation.html)。

---

## B. 带宽是第一约束

**该做**：先算清楚「这一帧每个像素被读/写了几次」，再谈别的优化。
**别做**：在核显上追求「多 pass 的电影级效果链」——每一层全屏 pass 都是一次 DRAM 往返。

### B1 · 带宽预算怎么算

峰值带宽 = 传输速率 × 位宽 / 8。双通道 = 128 bit = 16 B/时钟：

| 内存配置 | 位宽 | 峰值带宽（算术） | 依据 |
|---|---|---|---|
| DDR5-5600 双通道 | 128 bit | 5600 × 16 B ≈ **89.6 GB/s** | Intel ARK（Core Ultra 7 155H：2 通道，Up to DDR5 5600）〔厂商文档〕 |
| LPDDR5X-7467 双通道 | 128 bit | 7467 × 16 B ≈ **119.5 GB/s** | 同上（Up to LPDDR5/X 7467）〔厂商文档〕 |
| LPDDR5X-7500 双通道 | 128 bit | 7500 × 16 B ≈ **120.0 GB/s** | AMD Ryzen 7 7840U 规格页〔厂商文档〕 |
| Apple M2 统一内存 | — | **100 GB/s**（厂商标称） | Apple Newsroom〔厂商文档〕 |

- **机制**：这是**理论峰值**。真实可持续带宽要扣除刷新、读写转向（read/write turnaround）、行冲突、以及 CPU 侧并发访问。工程上按峰值的 **60%–80%** 做预算比较稳妥〔经验〕，并在目标机上用实测校正。
- **Vulkan**：把上表当成常数写进代码注释与预算脚本；用 `VK_EXT_memory_budget` 的 `heapUsage` 差分做粗粒度观测（见 B8）。
- **代价/风险**：只看峰值会低估问题——UMA 上 CPU 每帧解音频、跑 UI 合成也在吃同一份带宽。
- **适用条件**：所有核显。
- 依据：[Intel ARK · Core Ultra 7 155H](https://www.intel.com/content/www/us/en/products/sku/236847/intel-core-ultra-7-155h-processor-24m-cache-up-to-4-80-ghz/specifications.html)、[AMD Ryzen 7 7840U](https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-7-7840u.html)、[Apple Newsroom · M2](https://www.apple.com/newsroom/2022/06/apple-unveils-m2-with-breakthrough-performance-and-capabilities/)。

### B2 · 每帧像素预算表（RGBA8）

| 分辨率 | 一帧 RGBA8 | 一次全屏「读 + 写」 | @60 fps | @120 fps |
|---|---|---|---|---|
| 1920×1080 | 8.29 MB | 16.6 MB | 0.99 GB/s | 1.99 GB/s |
| 2560×1440 | 14.75 MB | 29.5 MB | 1.77 GB/s | 3.54 GB/s |
| 3840×2160 | 33.18 MB | 66.4 MB | 3.98 GB/s | 7.96 GB/s |

- **机制**：一次「采样上一 pass 的结果 + 写入本 pass」= 一读一写。**pass 数 × 分辨率 × 实际帧率** 直接决定带宽（帧率按实测计，不假设刷新率）。
- **换算示例（算术推导）**：4K@120 下 10 个全屏 pass ≈ 79.6 GB/s，已经吃掉 DDR5-5600 双通道（89.6 GB/s）的 **89%**；同样的 10 个 pass 在 1440p@120 只有 35.4 GB/s（约 40%）。RGBA16F 全部翻倍。
- **Vulkan**：把「全屏 pass 数」当成一等指标；每加一个 pass 都要问「能不能合并进同一个 render pass / 能不能在半分辨率做」。
- **代价/风险**：表里没有算 depth/stencil、没有算 MSAA、没有算 resolve、没有算 swapchain 之外的额外拷贝。真实值只会更高。
- **适用条件**：一切核显。

### B3 · 偷带宽的操作清单（按危害排序）

| 操作 | 典型代价 | 对策 |
|---|---|---|
| 不必要的 `LOAD_OP_LOAD` | 每个 attachment 每帧一次全屏读 | 改 `CLEAR` 或 `DONT_CARE`（C2） |
| 不必要的 `STORE_OP_STORE` | 一次全屏写 | `DONT_CARE` / `NONE`（C3） |
| MSAA resolve / `vkCmdResolveImage` | 4×color 读 + 1× 写 | 片上 resolve + `MULTISAMPLED_RENDER_TO_SINGLE_SAMPLED`（D7） |
| `vkCmdCopyImage` / `vkCmdBlitImage` | 一次全屏读 + 一次全屏写 | 直接在目标布局渲染，或用 render pass 的 resolve |
| 回读（`vkCmdCopyImageToBuffer` + map） | 一次全屏写 + 一次 CPU 映射 + 阻塞 | 真需要才做；降低回读频率、分帧、异步（B6） |
| `VK_IMAGE_TILING_LINEAR` | 失去压缩 + 失去 fast clear | 一律 `OPTIMAL`（D6） |
| `RGBA16F` / `RGBA32F` 中间缓冲 | 2× / 4× 带宽 | `A2B10G10R10`、`R11G11B10`、`R8`（B5） |
| 过度 MSAA（8×/16×） | 8×/16× 存储 | 上限 4×，或直接放弃 MSAA 用后处理 |

### B4 · `loadOp`/`storeOp`：最便宜的带宽开关

- **机制**：在瓦片式 GPU 上，`LOAD_OP_CLEAR` 直接把 tile memory 初始化，**不产生任何外部流量**；`LOAD_OP_LOAD` 则强制把上一帧内容从 DRAM 拉回片上。Arm 的原文是「`LOAD_OP_CLEAR` 是免费的，而 `vkCmdClearColorImage` 非常昂贵」〔厂商文档〕。
- **Vulkan**：`VkAttachmentDescription::loadOp/storeOp`（render pass）或 `VkRenderingAttachmentInfo::loadOp/storeOp`（dynamic rendering）。确定性全屏覆盖 → `LOAD_OP_DONT_CARE`；需要清成已知值 → `LOAD_OP_CLEAR`。
- **代价/风险**：`DONT_CARE` 让内容未定义，若某条路径（如 UI 层、局部重绘）依赖旧内容会出画面错误；`CLEAR` 会真的执行清屏，若随后整屏被覆盖，不如 `DONT_CARE`。
- **适用条件**：所有平台。tiler 上收益最大（省掉读回），立即模式上省一次全屏读 + 让 fast clear 生效。
- 依据：[Khronos · TBR Best Practices](https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html)、[Arm · Picking the most efficient load/store operations](https://developer.arm.com/community/arm-community-blogs/b/mobile-graphics-and-gaming-blog/posts/picking-the-most-efficient-load-store-operations)。

### B5 · `storeOp = DONT_CARE` / `STORE_OP_NONE`：不要写回不需要的东西

- **机制**：depth/stencil、MSAA color、只在同一 render pass 内被采样的中间缓冲，一旦不需要跨 pass 使用，就没有理由写回 DRAM。
- **Vulkan**：`VK_ATTACHMENT_STORE_OP_DONT_CARE`（内容未定义、不保证写回）或 `VK_ATTACHMENT_STORE_OP_NONE`（Vulkan 1.3 / `VK_KHR_load_store_op_none`，显式声明「不写」）。Khronos 指南把 `NONE` 描述为「不想回写、又不想逻辑丢弃」时的选择〔规范〕。
- **代价/风险**：`DONT_CARE` 在某些实现上仍可能触发一次写（保守实现）；`NONE` 需要 1.3 或扩展。
- **适用条件**：depth buffer（除非要做 depth 预通道复用）、MSAA attachment（配合 resolve attachment）、纯中间 G-buffer。
- 依据：[Khronos · TBR Best Practices](https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html)、[VkAttachmentStoreOp](https://docs.vulkan.org/refpages/latest/refpages/source/VkAttachmentStoreOp.html)。

### B6 · 回读：核显上最贵的同步点

- **机制**：回读要把 GPU 结果写回可被 CPU 看见的内存，再让 CPU 读——一次全屏写 + 一次映射 + 一次等待。在 UMA 上内存是共享的，但这不消除**同步**代价：CPU 读之前必须等 GPU 完成。
- **Vulkan**：① 用 `HOST_CACHED` 的可映射缓冲做目标（A3）；② 用 fence 而非 `vkQueueWaitIdle`，并把回读延后 1–2 帧（读上一帧的结果）；③ 分块回读（只读需要的 tile 区域）；④ 用 `vkCmdCopyImageToBuffer` 的 `VkBufferImageCopy::imageExtent` 限定区域。
- **代价/风险**：延迟一帧会引入一帧的输入延迟，交互式可视化里可能被感知。
- **适用条件**：频谱/波形回读、截图、自动曝光统计。若只是「显示」，尽量让 GPU 侧完成，不要回 CPU。
- 依据：[AMD GPUOpen · Using Vulkan Device Memory](https://gpuopen.com/learn/vulkan-device-memory)、[Khronos · Memory Allocation](https://docs.vulkan.org/guide/latest/memory_allocation.html)。

### B7 · 格式位宽：省一半带宽的最直接手段

- **机制**：带宽与每像素字节数线性相关。RGBA8 = 4 B/px，RGBA16F = 8 B/px，RGBA32F = 16 B/px。Khronos 指南还指出：**每像素占用的位数越小，硬件越可能用更大的 tile**（片上容量固定，格式窄则一 tile 覆盖更多像素）〔规范〕。
- **Vulkan**：中间缓冲优先 `VK_FORMAT_R8G8B8A8_UNORM`/`VK_FORMAT_A2B10G10R10_UNORM_PACK32`（HDR 且只要 10 bit 时）/`VK_FORMAT_R11G11B10_UFLOAT_PACK32`（HDR 且要浮点范围）；只在确实需要 alpha 混合精度时用 16F。
- **代价/风险**：`A2B10G10R10` 没有负值、动态范围有限；`R11G11B10` 没有 alpha；色调映射/混合链上精度不足会产生 banding。
- **适用条件**：本项目 HDR 场景色 + 上采样输出的中间链路最值得改；最终 swapchain 格式由 surface 决定，改不了。
- 依据：[Khronos · TBR Best Practices](https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html)。

### B8 · 帧生成与上采样的带宽账（本项目特有）

- **机制**：FSR3 帧生成在每两个真实帧之间插入一帧，需要读上一帧、当前帧（含运动矢量/深度），写出一帧插值结果。按 1440p RGBA8 估算：读 2×14.75 MB + 写 14.75 MB ≈ 44 MB/生成帧；60 真实帧/秒 → 约 **2.7 GB/s** 额外带宽（算术推导，未计光流本身的读写）。上采样则相反：它把着色分辨率降下来，是核显上**最划算**的带宽手段。
- **Vulkan**：把帧生成当作「额外的全屏 pass + 额外的 present」纳入预算；`vkQueuePresentKHR` 频率翻倍意味着 present 侧开销（含可能的跨适配器拷贝，见 F6）也翻倍。
- **代价/风险**：帧生成在低帧率下会放大延迟；iGPU 带宽吃紧时，插值帧可能把真实帧的带宽挤掉，净收益为负。
- **适用条件**：先保住真实帧的帧率与带宽余量，再开帧生成；带宽余量 < 20% 时优先关帧生成而不是降分辨率。
- 依据：机制来自 Vulkan 呈现/带宽模型（本文 B1–B3）；具体 FSR3 实现细节属项目代码，未在本文核实。

### B9 · transient + lazily allocated：把中间图像从「必须落盘」变成「可以不存在」

- **机制**：`VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT` 声明「这张图只在 render pass 内被读写，不会被采样/拷贝」，配合带 `VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT` 的 memory type，tiler 上可以**根本不分配物理内存**，整段生命周期留在 tile memory〔规范〕。在 IMR 上规范允许它退化成普通分配（约束只是「不得被采样/传输」），因此这个声明对 Intel/AMD 是「无害但收益不保证」。
- **Vulkan**：MSAA color、depth/stencil、G-buffer 这类只在 pass 内使用的 attachment，创建时把 usage 写成 `TRANSIENT_ATTACHMENT | (COLOR|DEPTH_STENCIL)_ATTACHMENT`；`vkGetImageMemoryRequirements` 返回的 `memoryTypeBits` 若指向 lazily allocated 类型就分配它。配套要求：`storeOp` 用 `DONT_CARE`/`NONE`，`loadOp` 用 `LOAD` 时读到的内容按规范是**未定义**的，所以实际只能是 `CLEAR`/`DONT_CARE`。
- **代价/风险**：只要某一帧需要「上一帧的 depth」或「pass 外采样」，这个 usage 立刻不合法，必须提前规划资源划分；部分驱动会静默退化为普通内存，收益归零且不报错——可对照 `VK_EXT_memory_budget` 的 `heapUsage` 变化侧面确认。
- **适用条件**：TBR（Mali / Adreno / PowerVR / Apple）优先；IMR 上仅在 `memoryTypeBits` 确实给出 lazily allocated 类型时才值得。
- 依据：[Khronos · Memory Allocation](https://docs.vulkan.org/guide/latest/memory_allocation.html)、[Khronos · TBR Best Practices](https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html)。

---

## C. 瓦片式（TBDR）与立即模式（IMR）

**该做**：写「对两种架构都正确」的一套 attachment 语义（clear 代替 load、能丢就丢 store、中间数据留在 pass 内）。
**别做**：为 tiler 和 IMR 各写一条渲染路径——Khronos 指南明确不建议〔规范〕。

### C1 · TBDR 的 on-chip tile memory 语义

- **机制**：Mali / Adreno / PowerVR / Apple 都是先 binning（把几何按屏幕 tile 分桶）再逐 tile 光栅；一个 tile 的所有 color/depth/MSAA 数据在**片上**累积，只有在该 tile 结束时才可能写回 DRAM。片上容量有限（且**不可查询**），由 attachment 数量、格式位宽、MSAA 倍数共同决定〔规范〕。
- **Vulkan**：不要试图「查询 tile 大小」；把它当黑盒，只控制「进片上 / 出片上」的时机（loadOp/storeOp）。
- **代价/风险**：attachment 太多或格式太宽会超片上容量 → 驱动被迫把 tile 拆小或中途 spill 到 DRAM，性能断崖且难以观测。
- **适用条件**：移动/嵌入式与 Apple；本项目若只面向桌面核显，此节主要用于「同一套代码别写坏」。
- 依据：[Khronos · TBR Best Practices](https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html)、[Imagination · PowerVR Architecture](https://docs.imgtec.com/starter-guides/powervr-architecture/html/topics/rules/do-use-on-chip-memory-efficiently-for-deferred-rendering.html)、[Mesa freedreno](https://docs.mesa3d.org/drivers/freedreno.html)。

### C2 · 为什么 `loadOp`/`storeOp` 在移动核显上是头等大事

- **机制**：tile 结束时若 `storeOp = STORE`，整个 tile 的 color/depth 被写回 DRAM；下一帧若 `loadOp = LOAD`，又要读回来。**一次全屏「读+写」= 2 × 分辨率 × 4 B**，在 1440p@120 就是 3.54 GB/s，只为「保留上一帧」。
- **Vulkan**：默认 `CLEAR`/`DONT_CARE`，只在确实要跨帧累积（TAA 历史、粒子拖尾）时才 `LOAD`。
- **代价/风险**：跨帧累积效果（TAA、曝光适应）确实需要 `LOAD`，这时应把该 attachment 单独拆出来，其余全部 `DONT_CARE`。
- **适用条件**：tiler 收益最大；IMR 上同样省一次全屏读（见 C5）。
- 依据：[Arm · Picking the most efficient load/store operations](https://developer.arm.com/community/arm-community-blogs/b/mobile-graphics-and-gaming-blog/posts/picking-the-most-efficient-load-store-operations)。

### C3 · subpass / input attachment 的现代替代

- **机制**：传统做法是把「G-buffer → 光照」拆成两个 pass（各一次全屏读写）；subpass + input attachment 让第二个 subpass 直接读片上数据，不落 DRAM。但**子 pass 合并并不保证**，驱动可能仍然拆开。
- **Vulkan**：① `VK_EXT_subpass_merge_feedback` 查询「这两个 subpass 到底有没有被合并」；② 现代等价物是 dynamic rendering + `VK_KHR_dynamic_rendering_local_read`：在 `vkCmdBeginRendering` 内用带 `VK_DEPENDENCY_BY_REGION_BIT` 的 barrier 做 local read，layout 用 `VK_IMAGE_LAYOUT_RENDERING_LOCAL_READ_KHR`；③ `VkRenderingAttachmentLocationInfoKHR` + `vkCmdSetRenderingAttachmentLocationsKHR` 做 attachment location 重映射（pipeline 与渲染时两处必须一致）。
- **代价/风险**：local read 只能用于 framebuffer-space stage，**不能**做 layout transition 或 queue family transfer；attachment location 不一致会直接渲染错误。
- **适用条件**：需要在同一 pass 内「写完再读同一像素」的效果（合成、简单光照）；邻域效果不行（见 C4）。
- 依据：[VK_KHR_dynamic_rendering_local_read](https://docs.vulkan.org/features/latest/features/proposals/VK_KHR_dynamic_rendering_local_read.html)、[Khronos · TBR Best Practices](https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html)。

### C4 · framebuffer fetch 与 `VK_EXT_shader_tile_image` 的边界

- **机制**：Arm 的 framebuffer fetch 允许片元着色器直接读写当前像素的 tile 数据；Vulkan 里没有单一对应扩展，而是三条路：input attachment（C3）、`VK_EXT_rasterization_order_attachment_access`（同 draw 内无 barrier 读同位置先前片元）、以及 `VK_EXT_shader_tile_image`（直接访问当前 tile）。三者共同的局限是**只能访问当前像素坐标**。
- **Vulkan**：用 `VK_EXT_rasterization_order_attachment_access`（配合 local read）在同一 draw 内无 barrier 读同位置先前片元值；或用 input attachment。
- **代价/风险**：任何需要邻域的算法（bloom、blur、FXAA、色调映射的空间项）**必然**要跨 tile，必须 flush 到主存再读回——这是移动 GPU 上后处理天然贵的根本原因〔厂商文档〕。
- **适用条件**：像素局部效果（混合、简单合成）；邻域效果改为「低分辨率 + 单次 pass」。
- 依据：[Arm · Framebuffer fetch in Vulkan](https://developer.arm.com/community/arm-community-blogs/b/mobile-graphics-and-gaming-blog/posts/framebuffer-fetch-in-vulkan)、[Khronos · TBR Best Practices](https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html)。

### C5 · Intel / AMD 核显是立即模式：优化点完全不同

- **机制**：Intel Xe 与 AMD RDNA APU 的核显是**立即模式**（IMR）：没有 tile memory，render target 直接落在 LLC/DRAM。因此「片上次世代」的收益不存在，优化点转移到：① 减少全屏 pass 数；② 让 fast clear / 带宽压缩生效；③ 避免 resolve 与拷贝；④ 提高 occupancy 以掩盖 DRAM 延迟。
- **Vulkan**：同一套 `loadOp=CLEAR` + `storeOp=DONT_CARE` 在 IMR 上依然有效（省一次全屏读、并给驱动触发 fast-clear 的机会）；`TRANSIENT_ATTACHMENT`/`LAZILY_ALLOCATED` 在 IMR 上通常拿不到 lazily allocated 的 `memoryTypeBits`，此时按普通内存分配即可，写了不亏但别指望省（见 B9）。
- **代价/风险**：把移动端的「多 subpass 保片上」策略照搬到 IMR 上，可能只是增加了 barrier 与状态切换。
- **适用条件**：本项目的主目标（Intel Xe / AMD APU 核显）。
- 依据：[Khronos · Memory Allocation](https://docs.vulkan.org/guide/latest/memory_allocation.html)、[AMD GPUOpen · DCC overview](https://gpuopen.com/learn/dcc-overview/)。

### C6 · 不要用宽 barrier 破坏 binning 与片元的重叠

- **机制**：tiler 上 binning pass 与逐 tile 的 fragment 工作可以重叠；一条 `ALL_GRAPHICS → ALL_GRAPHICS` 或 `ALL_COMMANDS` barrier 会把两者强行切成两段。
- **Vulkan**：barrier 的 `srcStageMask/dstStageMask` 精确到实际使用阶段（`COLOR_ATTACHMENT_OUTPUT`、`FRAGMENT_SHADER`），`accessMask` 精确到 `COLOR_ATTACHMENT_WRITE`/`SHADER_READ`；能用 `VK_DEPENDENCY_BY_REGION_BIT` 就用（尤其 tiler）。
- **代价/风险**：过度精确的 barrier 容易写出同步 bug（读到未写完的数据），必须配合验证层与 RenderDoc 检查。
- **适用条件**：所有平台；tiler 上收益最明显。
- 依据：[Khronos · TBR Best Practices](https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html)。

---

## D. 压缩与布局

**该做**：默认 `VK_IMAGE_TILING_OPTIMAL`，让驱动有机会启用无损带宽压缩。
**别做**：为了「方便 CPU 直接读像素」而用 `LINEAR`；那是把核显最值钱的优化关掉。

### D1 · 无损带宽压缩的共同前提

- **机制**：AMD 的 DCC、Arm 的 AFBC、Qualcomm 的 UBWC、Intel 的压缩元数据（CCS，〔社区经验〕）都建立在「**tiling 布局 + 块对齐 + 特定 usage**」之上。它们按块压缩：块内颜色接近时只存一个基准值 + 少量 delta，命中时省掉大部分 DRAM 流量。
- **Vulkan**：`VkImageCreateInfo::tiling = VK_IMAGE_TILING_OPTIMAL`；`usage` 只声明真正需要的位；避免把 render target 同时标成 `SAMPLED`（见 D4）。
- **代价/风险**：压缩对**随机/稀疏写**不友好；一旦某块被部分写，压缩收益下降甚至需要解压。
- **适用条件**：所有核显；受益最大的是「大面积纯色/渐变」的内容——音乐可视化的背景与 UI 层恰好属于此类。
- 依据：[AMD GPUOpen · DCC overview](https://gpuopen.com/learn/dcc-overview/)、[Linux kernel · AFBC](https://dri.freedesktop.org/docs/drm/gpu/afbc.html)。

### D2 · AMD DCC 的具体行为（对 APU 同样适用）

- **机制**：DCC 无损，按块存「一个全精度值 + delta」；GCN 1.2 及更新（**含 APU**）启用。关键收益是 render-target → texture 的 barrier 在 DCC 下可以变成 no-op、不触发解压。clear 成 0.0/1.0 比清成任意值更快更省带宽（ARGB 用 `{1,0,0,0}`/`{0,1,1,1}`/全 0/全 1；depth 0 或 1；stencil 0x00）〔厂商文档〕。
- **Vulkan**：`loadOp = CLEAR` + `clearValue` 用 0/1；确认整屏都会被写时干脆 `DONT_CARE` 不 clear。
- **代价/风险**：把 RT 标记为 shader-readable 会降低压缩效果——有些压缩选项只在禁止 shader 读时可用〔厂商文档〕。
- **适用条件**：AMD APU（RADV/Windows 驱动都会启用 DCC）；本项目若跑在 7840U 这类 APU 上直接受益。
- 依据：[AMD GPUOpen · DCC overview](https://gpuopen.com/learn/dcc-overview/)。

### D3 · AFBC（Arm）与 UBWC（Qualcomm）

- **机制**：AFBC 是 Arm 的帧缓冲压缩，要求 encoder/decoder 对 modifier 达成一致；`AFBC_FORMAT_MOD_YTR` 是无损色彩空间变换，对 RGB buffer **应当启用**以获得最大压缩率，且组件顺序必须按 fourcc 解读〔规范/内核文档〕。Qualcomm 的对应机制通常称 UBWC（Universal Bandwidth Compression），Mesa 的 freedreno 驱动提供 `noubwc` 调试开关可关闭它——反证它默认开启〔实测/案例〕。
- **Vulkan**：跨进程/跨 API 共享时用 `VK_EXT_image_drm_format_modifier` 传 modifier（见 D5）；纯 GPU 内部使用时什么都不用做，驱动自动选择。
- **代价/风险**：AFBC 对图像的 stride/对齐有额外要求（`VkImageDrmFormatModifierPropertiesEXT` 的 `drmFormatModifierTilingFeatures` 会说明支持哪些 usage）；用错 modifier 会直接创建失败。
- **适用条件**：移动/嵌入式；桌面核显不涉及。UBWC 的具体压缩比与块尺寸本轮未抓到 Qualcomm 一手页面（官方站点为 JS 渲染），标〔未验证〕。
- 依据：[Linux kernel · AFBC](https://dri.freedesktop.org/docs/drm/gpu/afbc.html)、[Mesa freedreno](https://docs.mesa3d.org/drivers/freedreno.html)。

### D4 · `VK_EXT_image_compression_control`：fixed-rate 压缩

- **机制**：无损压缩由实现透明完成；**fixed-rate 是有损的、必须应用 opt-in**。它以 bits per component 表达：R8G8 压一半 = 4 bpc = 8 bpp；RGBA8 压一半 = 4 bpc = 16 bpp，两者都用 `VK_IMAGE_COMPRESSION_FIXED_RATE_4BPC_BIT_EXT` 请求〔规范〕。
- **Vulkan**：`VkImageCompressionControlEXT` 挂到 `VkImageCreateInfo::pNext`，`flags = VK_IMAGE_COMPRESSION_FIXED_RATE_EXPLICIT_EXT`，`pFixedRateFlags` 指定速率；创建后用 `vkGetImageSubresourceLayout2EXT` 查**实际生效**的速率；swapchain 图像要走 `VK_EXT_image_compression_control_swapchain` 单独控制。
- **代价/风险**：有损，压缩伪影在渐变/文字上最明显；请求的速率可能因 usage flags 不被采用（规范明确写了这一条）。
- **适用条件**：带宽吃紧且能接受轻微有损的中间缓冲；UI/文字层建议不要用。
- 依据：[VK_EXT_image_compression_control](https://docs.vulkan.org/features/latest/features/proposals/VK_EXT_image_compression_control.html)、[VkImageCompressionFixedRateFlagBitsEXT](https://docs.vulkan.org/refpages/latest/refpages/source/VkImageCompressionFixedRateFlagBitsEXT.html)。

### D5 · tiling modifier 与跨进程共享

- **机制**：DRM format modifier 是 64-bit、厂商前缀的**半透明整数**，多数代表一种具体的 tiling 格式；`DRM_FORMAT_MOD_LINEAR` 是少数非厂商例外。它的目标是让不同进程/API/设备共享同一块图像内存（dma_buf）〔规范〕。
- **Vulkan**：`VkImageCreateInfo::tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT` + `VkImageDrmFormatModifierListCreateInfoEXT`（让驱动挑）或 `VkImageDrmFormatModifierExplicitCreateInfoEXT`（导入已知布局）；用 `vkGetImageDrmFormatModifierPropertiesEXT` 反查。
- **代价/风险**：`VkImageTiling` 的枚举里只有 `OPTIMAL`（实现相关、更高效）、`LINEAR`（行主序，可能有行填充）、`DRM_FORMAT_MODIFIER_EXT` 三种，选错就是性能断崖；modifier 与 `VkFormat` 的映射是**有损**的（DRM format 不区分 sRGB）〔规范〕。
- **适用条件**：与 Wayland 合成器/视频解码器共享帧；本项目自建 swapchain，正常路径用 `OPTIMAL` 即可。
- 依据：[VK_EXT_image_drm_format_modifier](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_image_drm_format_modifier.html)、[VkImageTiling](https://docs.vulkan.org/refpages/latest/refpages/source/VkImageTiling.html)。

### D6 · 为什么 linear tiling 在核显上是灾难

- **机制**：`VK_IMAGE_TILING_LINEAR` 是行主序（可能带行填充）布局，而所有带宽压缩与 fast clear 都要求「块状」布局；linear 图像通常被迫走未压缩路径，且驱动可能插入额外的 blit 才能渲染。
- **Vulkan**：一律 `OPTIMAL`；只有「CPU 必须直接按行读像素」且没有替代方案时才用 `LINEAR`（例如把一帧写进共享内存给非 Vulkan 的消费者）。
- **代价/风险**：linear 图像的 `vkGetImageSubresourceLayout` 是唯一能拿到行 pitch 的方式；一旦用了，就很难再享受压缩。
- **适用条件**：视频输出/屏幕捕获/与外部 API 共享。
- 依据：[VkImageTiling](https://docs.vulkan.org/refpages/latest/refpages/source/VkImageTiling.html)、[AMD GPUOpen · DCC overview](https://gpuopen.com/learn/dcc-overview/)。

### D7 · `VkImageCreateInfo` 的 usage/flags 如何影响压缩可用性

- **机制**：压缩是否可用取决于 usage 组合。同时声明 `COLOR_ATTACHMENT | SAMPLED | STORAGE` 会让驱动倾向于「随时可能被任意访问」的保守布局，压缩收益下降。
- **Vulkan**：① 只声明真正需要的 usage；② `VK_IMAGE_CREATE_..._BIT` 慎用（`MUTABLE_FORMAT`、`EXTENDED_USAGE` 都会限制布局优化）；③ 确实需要「渲染完立刻采样」时，优先用同一 render pass 的 input attachment 或 local read（C3），而不是给图像加 `SAMPLED`；④ 需要反馈回路的用 `VK_EXT_attachment_feedback_loop_layout` 显式声明，而不是默认加位。
- **代价/风险**：usage 少写会直接 `VK_ERROR_FORMAT_NOT_SUPPORTED` 或验证层报错，需要在创建前用 `vkGetPhysicalDeviceImageFormatProperties2` 校验。
- **适用条件**：所有核显；对每帧创建/销毁的中间图像尤其重要。
- 依据：[VkImageCreateInfo](https://docs.vulkan.org/refpages/latest/refpages/source/VkImageCreateInfo.html)、[AMD GPUOpen · DCC overview](https://gpuopen.com/learn/dcc-overview/)。

### D8 · MSAA 与 resolve 的带宽账

- **机制**：4× MSAA 把 color 与 depth 的存储量各乘 4，resolve 还要再读 4 份写 1 份。在 tiler 上 resolve **可以完全发生在片上**，前提是 MSAA attachment 的 `storeOp=DONT_CARE` 且同一个 subpass 内提供 resolve attachment，此时额外 DRAM 流量≈0〔规范〕；在 IMR 上 MSAA 基本就是实打实的 4 倍带宽。
- **Vulkan**：① 有 `VK_EXT_multisampled_render_to_single_sampled` 就用它——单采样图像 + 隐式 MSAA，规范的适用前提是「resolve attachment + `LAZILY_ALLOCATED` + `loadOp`≠LOAD + `storeOp`≠STORE」；② 没这个扩展时用 subpass 的 `pResolveAttachments` 在 pass 内 resolve，**绝不要** `vkCmdResolveImage`（强制往返主存）；③ 只在确实存在高对比几何边缘时开 MSAA。
- **代价/风险**：`VK_EXT_multisampled_render_to_single_sampled` 对「跨帧部分光栅化」「与上一帧混合」的场景不适用，需要先确认这个 pass 在架构上是自洽的。
- **适用条件**：音乐可视化里大量的全屏渐变、频谱条、粒子通常是**平滑**内容，MSAA 收益极低；先把 MSAA 关掉，用帧率与带宽预算再决定是否值得开 2×。
- 依据：[Khronos · TBR Best Practices](https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html)、[VK_EXT_multisampled_render_to_single_sampled](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_multisampled_render_to_single_sampled.html)。

---

## E. 功耗、时钟与呈现节奏（功耗仅作背景，不作决策依据）

**该做**：把功耗/降频当作**硬件风险提示**记录；pacing 的目标是**最小化排队与阻塞**。
**别做**：不要为省电或避免降频去限帧/降负载；不要在刷新率未知时用 fps 与刷新率的关系判断瓶颈。

### E1 · 背景：封装功耗预算被 CPU 与 GPU 共享

- **机制**：核显与 CPU 同一封装、共享功耗预算。Intel ARK 对 Core Ultra 7 155H 明示：Processor Base Power **28 W**、Maximum Turbo Power **115 W**、Minimum Assured Power 20 W〔厂商文档〕。长时间满载时频率可能从 turbo 段落到 base 段，帧时间变长而「利用率」仍显示 100%。
- **Vulkan**：应用无法控制频率，也没有对应的 API；这里唯一可做的是把它记为**观测项**——同负载长时间运行后帧时间上升时，先分清是频率下降还是自己的队列堆积（E5）。
- **代价/风险**：把降频误判成「代码退化」（或反之）会浪费大量优化时间。
- **适用条件**：仅作背景与排障参考，**不参与**任何限帧/降负载决策。
- 依据：[Intel ARK · Core Ultra 7 155H](https://www.intel.com/content/www/us/en/products/sku/236847/intel-core-ultra-7-155h-processor-24m-cache-up-to-4-80-ghz/specifications.html)。

### E2 · DVFS 与帧时间抖动：先当测量噪声处理

- **机制**：GPU 频率随负载与温度动态调整（DVFS），同一段工作在冷机与热机下耗时不同，表现为长时间运行后的节奏漂移。它是**测量噪声源**，不是优化目标。
- **Vulkan**：① `VK_KHR_present_id` + `VK_KHR_present_wait`（`vkWaitForPresentKHR`）测「真正上屏」的时刻，而不是提交时刻〔规范〕；② `VK_EXT_present_timing` 回收各 present stage 时序；③ `vkCmdWriteTimestamp2` / `VK_QUERY_TYPE_TIMESTAMP` 测 GPU busy；④ 帧时间按 1%/0.1% 分位统计。**瓶颈判据只用**：GPU busy 占比、present 阻塞时长、submit 耗时、队列堆积深度。
- **代价/风险**：`present_wait` 会阻塞调用线程，不能放在渲染线程关键路径上无限等；`present_timing` 队列满时返回 `VK_ERROR_PRESENT_TIMING_QUEUE_FULL_EXT`。
- **适用条件**：所有平台；刷新率未知时**不要**用「fps 是否贴住某个数值」反推瓶颈。
- 依据：[VK_KHR_present_wait](https://docs.vulkan.org/refpages/latest/refpages/source/VK_KHR_present_wait.html)、[VK_EXT_present_timing](https://docs.vulkan.org/features/latest/features/proposals/VK_EXT_present_timing.html)。

### E3 · 「跑满 100%」是目标，不是要避免的事

- **机制**：本项目**不设帧率上限，跑满即目标**。持续满载可能触发热/功耗限制并压低频率——这是硬件风险提示，**不构成限帧理由**。
- **Vulkan**：用 timestamp query 计算每帧 GPU busy（busy / 帧间隔），作为「还有多少可优化空间」的度量；若 busy 不变而帧间隔变长，记为频率风险，并在报告里注明测试时长与冷热机差异。
- **代价/风险**：满载时帧时间可能随温度漂移，跨时段对比的数据必须标注条件。
- **适用条件**：全部；只有用户显式要求「静音/低温」时才考虑限帧（本项目无此需求）。
- 依据：[Intel ARK · Core Ultra 7 155H](https://www.intel.com/content/www/us/en/products/sku/236847/intel-core-ultra-7-155h-processor-24m-cache-up-to-4-80-ghz/specifications.html)（功耗规格）；降频行为属〔厂商文档 + 推理〕，具体曲线需实测。

### E4 · present mode 的真实含义（刷新率未知，必须实测）

- **机制**：规范只定义排队语义，不定义刷新率。`FIFO` 是「等下一个 vblank 再更新」，但在刷新率未知的合成器/驱动栈上，**FIFO 可能被按真实刷新节流，也可能等价于 immediate**；`MAILBOX` 单槽替换、旧图像立即可复用；`IMMEDIATE` 立即提交、可能撕裂；`FIFO_RELAXED` 错过 vblank 就立即更新；`FIFO_LATEST_READY` 跳过过期帧〔规范〕。
- **Vulkan**：把 presentMode 当**探测项**而不是结论——用 `vkGetPhysicalDeviceSurfacePresentModesKHR` 取真实支持集，逐个跑并记录「present 阻塞时长 + 队列深度 + 帧间隔分布」；运行时用 `VK_EXT_swapchain_maintenance1` 的 `VkSwapchainPresentModeInfoEXT` 做 per-present 切换，不必重建 swapchain。
- **代价/风险**：不能假设「关掉 vsync 就一定更快」，也不能假设「开 vsync 就是 60」——两者都依赖未知的刷新率与合成器行为；`MAILBOX` 会让队列永远非空，掩盖「渲染比呈现慢」的事实。
- **适用条件**：默认 `FIFO`（唯一必须支持的模式）；需要低延迟时试 `MAILBOX`；最终结论必须来自本机实测。
- 依据：[VkPresentModeKHR](https://docs.vulkan.org/refpages/latest/refpages/source/VkPresentModeKHR.html)、[VK_EXT_swapchain_maintenance1](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_swapchain_maintenance1.html)、[VK_EXT_present_mode_fifo_latest_ready](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_present_mode_fifo_latest_ready.html)。

### E5 · pacing：最小化排队与阻塞，而不是对齐刷新周期

- **机制**：刷新率未知时不存在「正确的帧周期」可对齐；能控制的只有队列深度与每帧阻塞点，而帧时间方差的主要来源常常是队列里堆了 N 帧。
- **Vulkan**：① 用 timeline semaphore 计数值或 `present_id` 判断「还有几帧没上屏」，超过阈值（建议 1–2）就等，形成背压；② `vkWaitForPresentKHR` 等指定 `presentId`；③ `VK_EXT_present_timing` 设定绝对上屏时间（只在已知目标周期时才有意义）；④ 采集 `vkQueuePresentKHR` 的墙钟耗时与 submit 耗时。
- **代价/风险**：背压等待会抬高输入延迟；把等待放进渲染线程临界区会拖慢下一帧的录制。
- **适用条件**：所有平台。**判据是队列深度与阻塞时长，不是 fps**。
- 依据：[VK_KHR_present_wait](https://docs.vulkan.org/refpages/latest/refpages/source/VK_KHR_present_wait.html)、[VK_EXT_present_timing](https://docs.vulkan.org/features/latest/features/proposals/VK_EXT_present_timing.html)、[VK_EXT_swapchain_maintenance1](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_swapchain_maintenance1.html)。

### E6 · 帧生成放大的是呈现与带宽

- **机制**：帧生成把 present 次数翻倍，present 侧开销、合成器开销、可能的跨适配器拷贝全部翻倍，且不降低真实帧的渲染成本（带宽账见 B8）。
- **Vulkan**：做成可热切换开关，依据「队列深度 + present 阻塞时长 + `heapUsage`」决定；切模式用 `VK_EXT_swapchain_maintenance1`，避免重建 swapchain。
- **代价/风险**：频繁切换有可见跳变，需加滞后；present 次数翻倍后若队列堆积，延迟会明显上升。
- **适用条件**：真实帧稳定且带宽有余量时开；判定依据是队列与带宽，**不是温度**。
- 依据：机制由 B8 + E4/E5 推导；具体阈值必须实测。

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

---

## F. 平台差异

**该做**：用能力查询（extensions / properties / driverID）分流，而不是用 `#ifdef` 猜平台。
**别做**：假设「核显 = 移动 GPU 语义」，Intel/AMD 核显是立即模式。

### F1 · Intel Xe 核显（ANV on Linux / Windows 驱动）

- **机制**：立即模式、统一内存、共享 LLC。没有 tile memory，render target 直接落 LLC/DRAM；fast clear 与压缩元数据是主要带宽手段〔社区经验〕。Linux 上走 Mesa 的 ANV，Windows 上是 Intel 自家驱动，两者对扩展的支持面不同。
- **Vulkan**：用 `VkPhysicalDeviceDriverProperties::driverID`（`VK_DRIVER_ID_INTEL_OPEN_SOURCE_MESA` / `..._INTEL_PROPRIETARY_WINDOWS`）区分，再决定是否启用 `VK_EXT_image_compression_control` 等可选路径。
- **代价/风险**：ANV 对某些扩展支持滞后（例如 fixed-rate compression 的支持情况需按驱动版本查）。
- **适用条件**：本项目在 Linux 桌面的主要目标之一。
- 依据：[Mesa ANV 文档](https://docs.mesa3d.org/drivers/anv.html)、[Khronos · Memory Allocation](https://docs.vulkan.org/guide/latest/memory_allocation.html)。

### F2 · AMD APU（RADV / Windows）

- **机制**：立即模式 + DCC + UMA。DCC 在 GCN 1.2 及更新的 APU 上启用〔厂商文档〕；RADV 在 APU 上同样只有系统内存堆。
- **Vulkan**：`loadOp=CLEAR` 清成 0/1、避免把 RT 标成 shader-readable（D2）；`VK_EXT_memory_budget` 在 APU 上尤其重要（系统内存被其它进程抢占）。
- **代价/风险**：Windows 驱动与 RADV 对同一扩展的行为可能不同（尤其 compression control）。
- **适用条件**：7840U / 8840U 这类 APU 掌机与轻薄本。
- 依据：[AMD GPUOpen · DCC overview](https://gpuopen.com/learn/dcc-overview/)、[AMD Ryzen 7 7840U](https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-7-7840u.html)。

### F3 · Apple Silicon（MoltenVK）

- **机制**：TBDR + 统一内存（M2 标称 100 GB/s）〔厂商文档〕。Vulkan 跑在 MoltenVK 上，需要把 Vulkan 语义翻译成 Metal：额外的命令缓冲编码、状态翻译、以及 render pass 描述到 Metal render pass 的映射，都会带来 CPU 侧开销。
- **Vulkan**：尽量用 dynamic rendering（与 Metal 的 render pass 模型更接近）、减少 render pass 数量与切换；`loadOp/storeOp` 语义在 TBDR 上收益最大（C2）；避免依赖 MoltenVK 未实现的扩展。
- **代价/风险**：MoltenVK 的支持面与性能特性随版本变化；具体开销比例本文未取到一手数据，标〔未验证〕。
- **适用条件**：macOS 构建；本项目若要跨平台需单独验证。
- 依据：[Apple Newsroom · M2](https://www.apple.com/newsroom/2022/06/apple-unveils-m2-with-breakthrough-performance-and-capabilities/)、[MoltenVK](https://github.com/KhronosGroup/MoltenVK)。

### F4 · Qualcomm Adreno

- **机制**：Mesa 文档描述为「mostly tile-mode renderer，可绕过 tiling（gmem）直接渲染到系统内存（sysmem）」；UMA，主要使用 write-combined 内存，但部分缓冲可映射为 CPU cache coherent〔实测/案例〕。
- **Vulkan**：tiler 语义（C1–C3）；`noubwc`/`notile`/`sysmem` 等调试开关可用于验证「压缩/分块到底有没有生效」。
- **代价/风险**：小 render pass 走 sysmem 反而更快（Mesa 文档提到默认对 draw call 很少的 pass 用 sysmem），说明「分块不是免费的」。
- **适用条件**：Android/ARM 平台；桌面项目通常不涉及。
- 依据：[Mesa freedreno](https://docs.mesa3d.org/drivers/freedreno.html)。

### F5 · ARM Mali

- **机制**：TBDR，tile memory 容量紧张，AFBC 是主要带宽手段；binning pass 会把几何跑两遍。
- **Vulkan**：把顶点位置与其他属性分离存放以减少 binning 带宽（Khronos 指南提到 `unorm16` 位置足够）〔规范〕；attachment 数量与格式位宽直接影响能否留在片上（C1）。
- **代价/风险**：为 Mali 做的顶点布局改动在 IMR 上可能无收益甚至略差。
- **适用条件**：仅移动端目标。
- 依据：[Khronos · TBR Best Practices](https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html)、[Arm · Picking the most efficient load/store operations](https://developer.arm.com/community/arm-community-blogs/b/mobile-graphics-and-gaming-blog/posts/picking-the-most-efficient-load-store-operations)。

### F6 · 混合显卡：「渲染在 dGPU、显示在 iGPU」的拷贝代价

- **机制**：Windows 的混合系统里，iGPU 接显示输出、dGPU 只做渲染；OS 与驱动共同决定应用跑在哪块 GPU 上，跨适配器资源在两块 GPU 之间共享〔厂商文档〕。若应用在 dGPU 上渲染而窗口在 iGPU 上显示，每次 present 都要把整帧搬一次（PCIe 或共享内存）——**这是一次全屏读 + 一次全屏写**，按 1440p 约 29.5 MB/帧，120 fps 下约 3.5 GB/s，且要额外占 PCIe 带宽。
- **Vulkan**：① Linux 上用 `VK_EXT_physical_device_drm` 的 `hasPrimary` 判断哪块 GPU 真正驱动显示（有 primary node 才是能扫描输出的设备）〔规范〕；② Windows 上用 `VkPhysicalDeviceIDProperties::deviceLUID` 与窗口所在适配器的 LUID 匹配；③ 对带宽敏感的可视化程序，**优先在显示适配器（iGPU）上渲染**，而不是在 dGPU 上渲染再拷贝。
- **代价/风险**：Vulkan 没有跨适配器 present 的标准路径；强行在 dGPU 上渲染会把「省下来的算力」赔进拷贝。
- **适用条件**：双显卡笔记本；单显卡机器不涉及。
- 依据：[Microsoft · Using cross-adapter resources in a hybrid system](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/using-cross-adapter-resources-in-a-hybrid-system)、[VK_EXT_physical_device_drm](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_physical_device_drm.html)。

### F7 · 驱动差异的最小验证集

- **机制**：同一份代码在 ANV / RADV / Windows 驱动 / MoltenVK 上表现不同，靠猜没用。
- **Vulkan**：启动时打印一组事实——`deviceType`、`driverID`+`driverName`、`apiVersion`、是否有 `DEVICE_LOCAL|HOST_VISIBLE` 类型、`heapBudget`、是否支持 `dynamic_rendering_local_read` / `image_compression_control` / `present_wait` / `swapchain_maintenance1`。这十行日志能省掉大量「为什么这台机器慢」。
- **代价/风险**：日志本身无成本，但要防止在每帧打印。
- **适用条件**：所有平台，尤其是需要远程排查的用户机器。
- 依据：[VkPhysicalDeviceDriverProperties](https://docs.vulkan.org/refpages/latest/refpages/source/VkPhysicalDeviceDriverProperties.html)、[VK_EXT_memory_budget](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_memory_budget.html)。

---

## G. 核显 Vulkan 检查表（按收益/成本排序）

**该做**：从上往下做，前 5 条通常就能拿回大部分可回收带宽；每完成一条单独测一次帧时间与 1% low。
**别做**：一次性全上——每条都要能独立回滚，否则无法定位回归。

| # | 动作 | 章节 | 收益 | 成本/风险 |
|---|---|---|---|---|
| 1 | 所有不需要旧内容的 attachment 改 `LOAD_OP_CLEAR` / `DONT_CARE` | B4 | 高（省一次全屏读） | 极低 |
| 2 | 不需要跨 pass 使用的 attachment 改 `STORE_OP_DONT_CARE`/`NONE` | B5 | 高（省一次全屏写） | 极低 |
| 3 | 删除所有非必要 `vkCmdCopyImage`/`vkCmdBlitImage`/`vkCmdResolveImage` | B3 | 高 | 低（要改渲染路径） |
| 4 | 中间缓冲从 RGBA16F 降到 `A2B10G10R10`/`R11G11B10` | B7 | 高（2×） | 中（精度风险） |
| 5 | 图像一律 `TILING_OPTIMAL`，禁用 `LINEAR` | D6 | 高 | 低 |
| 6 | 每帧 pass 数减半（合并到同一 render pass / 半分辨率后处理） | B2 | 高 | 中 |
| 7 | 启动时做 UMA 判定，去掉 staging 中转 | A1/A2 | 中高 | 低 |
| 8 | 限未上屏帧数 ≤1–2 形成背压（**不设 fps 上限**） | E5 | 中高（降低排队抖动） | 低 |
| 9 | `vkCmdClearAttachments` 全部替换为 `loadOp=CLEAR` | B4 | 中 | 低 |
| 10 | 4× MSAA 降级或改用 `MULTISAMPLED_RENDER_TO_SINGLE_SAMPLED` | D8/B3 | 中高 | 中 |
| 11 | 清理 usage/flags：只声明真正需要的位 | D7 | 中 | 低 |
| 12 | `CLEAR` 的 `clearValue` 统一用 0/1（触发快速清屏） | D2 | 中 | 极低 |
| 13 | 移除 render target 上不必要的 `SAMPLED` | D2/D7 | 中 | 中（要改依赖） |
| 14 | 回读延后 1–2 帧 + 用 `HOST_CACHED` 目标 | B6/A3 | 中 | 中 |
| 15 | 每帧/每几秒查 `heapBudget`，超预算先降分辨率/关帧生成 | A4 | 中 | 低 |
| 16 | 精度：barrier 收窄 + `BY_REGION` | C6 | 中（tiler 更高） | 中（同步 bug 风险） |
| 17 | 混合显卡机器上强制在显示适配器渲染 | F6 | 中高（笔记本） | 低 |
| 18 | 开启 `VK_EXT_subpass_merge_feedback` 确认合并是否发生 | C3 | 低中 | 低 |
| 19 | 需要「写完立刻读」的地方用 dynamic rendering local read | C3 | 中（tiler） | 高（实现复杂度） |
| 20 | 试 `VK_EXT_image_compression_control` fixed-rate（仅中间缓冲） | D4 | 中（带宽） | 中（有损） |
| 21 | 建立 present/队列度量（`present_wait` + timestamp query），不用 fps 判瓶颈 | E2 | 中（可观测性） | 中 |
| 22 | 帧生成做成可热切换，按队列深度/带宽余量切换 | E6 | 中 | 中 |
| 23 | 内存池化：大分配 + 自行 sub-allocation | A6 | 低中 | 中 |
| 24 | `VK_EXT_memory_priority` 给 RT/swapchain 更高优先级 | A4 | 低中 | 低 |
| 25 | 启动日志打印 10 项能力事实 | F7 | 低（排障价值高） | 极低 |

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

---

## 参考来源

一手来源（Khronos / 厂商 / 驱动）：

1. [Khronos Vulkan Guide · Memory Allocation](https://docs.vulkan.org/guide/latest/memory_allocation.html) —— UMA 的 `DEVICE_LOCAL|HOST_VISIBLE` 判据、免 staging、`LAZILY_ALLOCATED` 语义、大分配+sub-allocation 建议。
2. [Khronos Vulkan Guide · Tile Based Rendering Best Practices](https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html) —— TBR 的 load/store 规则、tile 尺寸不可查询、subpass 合并、MSAA 片上 resolve、barrier 粒度、early-Z 注意事项。
3. [VkMemoryPropertyFlagBits](https://docs.vulkan.org/refpages/latest/refpages/source/VkMemoryPropertyFlagBits.html) —— `DEVICE_LOCAL`/`HOST_VISIBLE`/`HOST_COHERENT`/`HOST_CACHED`/`LAZILY_ALLOCATED` 的规范定义（含「uncached memory is always host coherent」）。
4. [VkPresentModeKHR](https://docs.vulkan.org/refpages/latest/refpages/source/VkPresentModeKHR.html) —— IMMEDIATE/MAILBOX/FIFO/FIFO_RELAXED/FIFO_LATEST_READY 的精确语义。
5. [VK_EXT_memory_budget](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_memory_budget.html) —— `heapBudget`/`heapUsage` 语义与轮询建议。
6. [VK_EXT_memory_priority](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_memory_priority.html) —— 分配优先级提示。
7. [VK_EXT_image_compression_control](https://docs.vulkan.org/features/latest/features/proposals/VK_EXT_image_compression_control.html) —— 无损透明压缩 vs fixed-rate 有损 opt-in、bpc 表示法、swapchain 变体。
8. [VkImageCompressionFixedRateFlagBitsEXT](https://docs.vulkan.org/refpages/latest/refpages/source/VkImageCompressionFixedRateFlagBitsEXT.html) —— 固定压缩率的枚举定义。
9. [VK_KHR_dynamic_rendering_local_read](https://docs.vulkan.org/features/latest/features/proposals/VK_KHR_dynamic_rendering_local_read.html) —— dynamic rendering 内的 local read、`RENDERING_LOCAL_READ` layout、attachment location 重映射。
10. [VK_EXT_multisampled_render_to_single_sampled](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_multisampled_render_to_single_sampled.html) —— 用 resolve attachment + `LAZILY_ALLOCATED` 做「零额外内存」MSAA 的前提条件。
11. [VK_EXT_image_drm_format_modifier](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_image_drm_format_modifier.html) —— modifier 是 64-bit 厂商前缀半透明整数、`DRM_FORMAT_MOD_LINEAR` 例外、VkFormat↔DRM format 映射有损。
12. [VkImageTiling](https://docs.vulkan.org/refpages/latest/refpages/source/VkImageTiling.html) —— `OPTIMAL`/`LINEAR`/`DRM_FORMAT_MODIFIER_EXT` 的定义。
13. [VK_EXT_external_memory_host](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_external_memory_host.html) —— 导入宿主指针的对齐要求与限制。
14. [VK_EXT_physical_device_drm](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_physical_device_drm.html) —— primary/render node 与 `hasPrimary`，判断「哪块 GPU 在驱动显示」。
15. [VK_KHR_present_wait](https://docs.vulkan.org/refpages/latest/refpages/source/VK_KHR_present_wait.html) —— `vkWaitForPresentKHR` 与 `presentId` 的配对语义。
16. [VK_EXT_present_timing](https://docs.vulkan.org/features/latest/features/proposals/VK_EXT_present_timing.html) —— 绝对目标上屏时间、present stage 时序反馈、队列满错误。
17. [VK_EXT_swapchain_maintenance1](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_swapchain_maintenance1.html) —— per-present 粒度切换 present mode、present fence、延迟分配。
18. [VK_EXT_present_mode_fifo_latest_ready](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_present_mode_fifo_latest_ready.html) —— 跳过过期帧的垂直同步模式（注册号 362）。
19. [AMD GPUOpen · Using Vulkan Device Memory](https://gpuopen.com/learn/vulkan-device-memory) —— 各 memory type 的用途、回读需 `HOST_CACHED`、<256 MB 上传用 `DEVICE_LOCAL|HOST_VISIBLE`、分配池化。
20. [AMD GPUOpen · DCC overview](https://gpuopen.com/learn/dcc-overview/) —— DCC 无损压缩原理、APU 支持、清屏值 0/1 的收益、shader-readable RT 降低压缩率。
21. [Arm · Picking the most efficient load/store operations](https://developer.arm.com/community/arm-community-blogs/b/mobile-graphics-and-gaming-blog/posts/picking-the-most-efficient-load-store-operations) —— `LOAD_OP_CLEAR` 免费、`vkCmdClearColorImage` 昂贵、后处理必须跨 tile。
22. [Arm · Framebuffer fetch in Vulkan](https://developer.arm.com/community/arm-community-blogs/b/mobile-graphics-and-gaming-blog/posts/framebuffer-fetch-in-vulkan) —— 片元着色器直接读写片上像素数据的机制与限制。
23. [Imagination · PowerVR Architecture · Use on-chip memory efficiently](https://docs.imgtec.com/starter-guides/powervr-architecture/html/topics/rules/do-use-on-chip-memory-efficiently-for-deferred-rendering.html) —— deferred 多 RT 的带宽代价、transient attachment 的片上语义。
24. [Mesa · freedreno / Adreno](https://docs.mesa3d.org/drivers/freedreno.html) —— Adreno 是 UMA、主要 write-combined、可绕过 tiling 走 sysmem、`noubwc`/`sysmem` 调试开关。
25. [Mesa · ANV (Intel Vulkan)](https://docs.mesa3d.org/drivers/anv.html) —— Intel Linux Vulkan 驱动的实现结构（描述符/绑定表内存布局）。
26. [Linux kernel · AFBC](https://dri.freedesktop.org/docs/drm/gpu/afbc.html) —— AFBC 需 encoder/decoder 对 modifier 一致、`AFBC_FORMAT_MOD_YTR` 对 RGB 提升压缩率。
27. [Microsoft · Using cross-adapter resources in a hybrid system](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/using-cross-adapter-resources-in-a-hybrid-system) —— 混合系统定义：iGPU 输出、dGPU 渲染、OS/驱动决定应用跑在哪块 GPU。
28. [Intel ARK · Core Ultra 7 155H](https://www.intel.com/content/www/us/en/products/sku/236847/intel-core-ultra-7-155h-processor-24m-cache-up-to-4-80-ghz/specifications.html) —— 2 通道、DDR5-5600 / LPDDR5X-7467、Base 28 W / Max Turbo 115 W。
29. [AMD Ryzen 7 7840U](https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-7-7840u.html) —— 2 通道、DDR5-5600 / LPDDR5X-7500、Radeon 780M。
30. [Apple Newsroom · M2](https://www.apple.com/newsroom/2022/06/apple-unveils-m2-with-breakthrough-performance-and-capabilities/) —— 100 GB/s 统一内存带宽、最高 24 GB。
31. [KhronosGroup/MoltenVK](https://github.com/KhronosGroup/MoltenVK) —— Vulkan-on-Metal 转换层（具体开销数字本文未取到一手数据，标〔未验证〕）。

> 未验证项：Resizable BAR 的窗口语义（A5）、Intel CCS 的具体行为（D1）、Qualcomm UBWC 的块尺寸与压缩比（D3）、MoltenVK 的额外开销比例（F3）。这些位置已在正文显式标注，未作为结论使用。
