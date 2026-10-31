# 核显（iGPU）上的 Vulkan 链路优化：全网调研报告

> **范围**：只谈 Vulkan **链路本身**——提交与同步、呈现（present）与帧节奏、管线与描述符、命令缓冲、内存与带宽、render pass/attachment 语义、可观测性与工具。
> **不谈**：3D 场景侧优化（LOD、剔除、合批、光照、阴影、后处理配方、美术资源）。
> **面向对象**：本项目 RhineRender（Qt 6.12 + QRhi + 自持 `VkSwapchainKHR` + FSR3 帧生成），但结论对任何「自建呈现层的桌面/移动 iGPU 应用」通用。
> **证据等级**：〔规范〕Vulkan 规范与 Khronos 官方指南 ·〔厂商文档〕Intel/AMD/Arm/Imagination/Microsoft/Apple 官方 ·〔实测/案例〕有出处可复现的测量 ·〔社区经验〕工程共识，无一手测量 ·〔算术推导〕由公开规格换算，非实测。**全文不含编造的基准数字**：没有出处的数字一律标〔未验证〕或只给量级。
>
> **本项目前提（2026-02 用户指示，优先于本文其它一切建议）**：① **不关心功耗/发热/降频**——功耗只作为背景资料，不作为限帧、降负载或选型的理由；② **屏幕刷新率在运行期无法获取**，一律按「刷新率未知／无穷」处理——因此**不设帧率上限**，也不允许用「fps 是否贴住刷新率」来判断瓶颈或是否被 vsync 节流。所有关于 present 节奏的建议，目标都是**减少排队与阻塞**，而不是「对齐某个刷新周期」。

---

## 0. 一页结论（12 条）

1. **核显的第一约束是带宽，不是算力。** 一颗 28W 级核显配双通道 LPDDR5X-7467，理论峰值约 119.5 GB/s（算术换算），而这笔带宽**与 CPU 共享**。4K@120 下十个全屏 RGBA8 pass（按每 pass 读+写各一次计）就能吃掉约 79.6 GB/s（≈峰值的 67%；若峰值按 DDR5-5600 的 89.6 GB/s 算则≈89%）。所以「这一帧为像素搬运了几次」是核显优化的第一性问题。〔算术推导〕→ [03](03-igpu-bandwidth.md)
2. **核显没有独立显存，独显那套 staging → device local 的上传路径是净损失。** 判据不是 `deviceType`，而是 memoryTypes 里是否存在同时带 `DEVICE_LOCAL|HOST_VISIBLE` 的类型。判成 UMA 后应改持久映射 + 环形缓冲，用 `VK_EXT_memory_budget` 的 heapBudget 当预算。〔规范〕[Khronos · Memory Allocation](https://docs.vulkan.org/guide/latest/memory_allocation.html)
3. **`loadOp`/`storeOp` 是核显上性价比最高的开关，而且 TBDR 与 Intel/AMD 立即模式的规则一致。** `LOAD_OP_CLEAR` 代替 `LOAD`（省一次全屏读、触发 fast clear），`STORE_OP_DONT_CARE/NONE` 代替 `STORE`；`vkCmdClearAttachments` 与 `vkCmdResolveImage` 都是反模式（要走 attachment resolve）。不需要为 TBDR/IMR 写两套代码。〔规范〕[03 §C/§D](03-igpu-bandwidth.md)
4. **present 是核显上最容易被误判为「GPU 慢」的一段。** 合成器多一次全屏拷贝就是 1080p 每帧 16.6 MB（读+写）、60 fps 约 1 GB/s。判定要先把帧时间分到 **CPU 提交 / GPU 执行 / 呈现** 三段，而不是先上 profiler。〔方法论〕[04 §B](04-tools-cases.md)
5. **present mode 不是「有 vsync 开关」这么简单。** `FIFO`、`MAILBOX`、`IMMEDIATE` 的可用性因平台与驱动而异，而且历史上反复过：Mesa 的 Wayland WSI 长期是 mailbox 风格实现（2018 年实测 `minImageCount` 报 4），协议级 FIFO 到 2024-11 的 Mesa 24.3 才通过 `wp_fifo` 补上；NVIDIA 的 Wayland 驱动则直接报 `fifo`。**方向不能靠平台假设**，必须 `vkGetPhysicalDeviceSurfacePresentModesKHR` 探测 + 记录实际模式 + 记录退化原因。〔厂商文档/实测〕
6. **CPU 侧开销的大头不是 draw call，而是「每帧重建对象 + 每帧重复 API + 没有预热编译」。** 全进程单一 `VkPipelineCache` + 落盘 + 后台预热；描述符目标是一帧零更新；命令缓冲每线程池 + 整池 reset（官方 sample 的 CPU 采样：整池 reset 0.45% vs 逐缓冲 reset 1.16% vs alloc/free 28.8%）。〔实测/案例〕[02 §A–§C](02-pipeline-descriptor-commandbuffer.md)
7. **每帧 reset 描述符池再重建 set 是最典型反模式。** Khronos 实测 44 ms/23 FPS → 27 ms/37 FPS（-38%，CPU 收益，GPU 帧时间几乎不变）。正解是持久 set + push constant / dynamic offset。〔实测/案例〕同上
8. **管线缓存必须落盘，且 blob 不透明。** 只能整块保留/整块丢弃，失效键要含 `pipelineCacheUUID` 与驱动版本；`VK_KHR_pipeline_binary` 是官方给的「显式缓存控制」出口。〔规范/厂商文档〕
9. **交换链图像数是吞吐与延迟的兑换，不是「越少越好」。** 每多一张图通常换 1 帧呈现延迟，但也可能换来吞吐（本项目实测 3 张 318fps vs 6 张 335fps）。在「不关心功耗、刷新率未知」的前提下**默认按吞吐优先取 6**，把它做成可配置；只有确认存在音画不同步时才用 `present_wait2` 的绝对延迟去降。注意 `VK_KHR_present_wait` 已被 **`VK_KHR_present_wait2`** 取代。〔规范/实测〕[05 §E](05-rhine-audit.md)
10. **本项目不设帧率上限，功耗不是优化目标。** 核显确实存在「封装功耗共享 → 持续满载落频」的现象（Intel 155H 明示 28 W base / 115 W max turbo），但按当前前提这只作为**硬件风险提示**记录，不作为限帧理由。判断链路好坏看的是排队深度、present 阻塞时长与帧时间分布，而不是「有没有跑满」。〔厂商文档〕[03 §E](03-igpu-bandwidth.md)
11. **核显上 profiler 可能根本不可用，流程必须内建降级路径。** AMD 官方明确 RGP 不支持 <3 CU 设备且仅支持 RDNA；Intel GPA 2025.1 是最终版、2026 停止分发。所以先建「链路地板」（保留完整 present 链、内容换成 clear/单三角形）与计数埋点，再谈抓帧。〔厂商文档〕[04 §A/§D.5](04-tools-cases.md)
12. **静态检查不是性能工具，但 Best Practices 是。** validation + Synchronization Validation + Best Practices 三层里，只有第三层专门标「语法正确但性能可疑」。它能低成本抓出每帧 `vkCreate*`、每帧 map+flush、缺 barrier 导致的隐式同步。〔厂商文档〕[04 §C](04-tools-cases.md)

---

## 1. 成本模型：把「Vulkan 链路」拆成五项可度量的成本

任何「Vulkan 优化」都必须能落到下面五项之一，否则大概率是在优化场景而不是链路。

| # | 成本项 | 核显 vs 独显的关键差异 | 每帧量级（1080p / 1440p / 4K，BGRA8） | 主要抓手 |
|---|---|---|---|---|
| 1 | **像素带宽** | 核显无独立显存，带宽与 CPU 共享，且峰值只有 90–120 GB/s 量级 | 单张全屏 = 8.3 / 14.7 / 33.2 MB；60 fps 写一遍 = 0.5 / 0.9 / 2.0 GB/s | load/store op、避免多余 pass、避免 `vkCmdResolveImage`、压缩（AFBC/UBWC/DCC） |
| 2 | **CPU 提交与驱动开销** | 核显机型常配低压 CPU，单核性能弱，驱动开销占比更高 | 每帧 submit 从几次到几十次；每次几 µs 到几十 µs | 单次 submit 合并、命令缓冲复用、管线缓存、描述符零更新 |
| 3 | **呈现与合成** | 核显的显示引擎与合成器读同一块系统内存；多一次合成拷贝就是一次全屏带宽 | 合成一次 = 16.6 / 29.5 / 66.4 MB（读+写） | present mode、独立翻转 vs 合成、present_wait 观测、图像数 |
| 4 | **内存所有权与分配** | UMA 下 `DEVICE_LOCAL` 可映射；但过度映射/碎片化会伤 DRAM 效率 | 交换链 3 张 1080p ≈ 24.9 MB；6 张 ≈ 49.8 MB | 大分配 + 子分配（VMA）、持久映射、按需 staging |
| 5 | **功耗与频率**（本项目**不适用**） | 封装功耗共享；满载 → 降频 → 帧时间抖动 | — | 仅作背景；不据此限帧、不据此选 present mode |

> 换算口径：1920×1080×4 B = 8.29 MB；2560×1440×4 B = 14.75 MB；3840×2160×4 B = 33.18 MB。带宽峰值：DDR5-5600 双通道 = 89.6 GB/s，LPDDR5X-7467 双通道 = 119.5 GB/s（均为算术换算，实际可持续带宽更低）。

**推论（这三条决定了优化顺序）**

- 如果一帧的「全屏 pass 数 × 分辨率」已经接近带宽峰值，那么先减 pass / 减 store，而不是先调 shader。
- 如果 `MsInPresentAPI` 高、`MsGPUBusy` 持续低位，而帧率并没有随负载下降而上升，那么你在**等呈现/合成环节**（不一定是在等 vblank——刷新率未知，不能这样反推），此时减场景复杂度毫无意义。
- 如果 CPU 侧每帧创建/销毁任何 `Vk` 对象，那么在低压 CPU 上这会直接变成卡顿尖峰，优先于任何 GPU 侧微调。

---

## 2. 分层优化清单（按「层」而不是按「技巧」组织）

| 层 | 动作 | 预期收益 | 风险/代价 | 证据 | 详见 |
|---|---|---|---|---|---|
| 呈现 | 探测并记录实际 present mode + 退化原因；`vsync=false` 时 `MAILBOX` → `IMMEDIATE` → `FIFO_RELAXED` 顺序回退 | 知道「实际拿到什么、有没有在阻塞」，而不是假设关掉 vsync 就一定更快 | 低 | 〔规范/厂商文档〕 | [01](01-sync-submit-present.md) |
| 呈现 | 上 `present_id` + `present_wait2` 采 `presentLatency` | 让「present 是否阻塞、阻塞多久」可判定 | 低（需平台支持，缺失则降级） | 〔规范〕 | [05 §C](05-rhine-audit.md) |
| 呈现 | 交换链图像数做成可配置，**默认保留 6（吞吐优先）** | 保住 ~5% 吞吐；需要低延迟时再降 | 中（降少了丢吞吐、降多了丢延迟） | 〔实测/案例〕 | [05 §E](05-rhine-audit.md) |
| 同步 | 用 present_wait 替代「每帧空提交」做 acquire 信号量回收 | 省一次 submit/帧 | 中（语义要改对） | 〔规范〕 | [01](01-sync-submit-present.md) |
| 同步 | 屏障精确到 stage/access，不用 `BOTTOM_OF_PIPE` 兜底 | 减少过度同步 | 低 | 〔规范〕 | [01](01-sync-submit-present.md) |
| 管线 | 全进程单一 `VkPipelineCache` + 落盘 + 后台预热 | 消掉建管线卡顿 | 低 | 〔规范/实测〕 | [02 §A](02-pipeline-descriptor-commandbuffer.md) |
| 描述符 | 持久 set + push constant/dynamic offset，做到一帧零更新 | -38% CPU 帧时间（Khronos 实测） | 中（要重构绑定） | 〔实测/案例〕 | [02 §B](02-pipeline-descriptor-commandbuffer.md) |
| 命令缓冲 | 每线程池 + 整池 reset；不 alloc/free、不开 `RESET_COMMAND_BUFFER_BIT` | CPU 采样 28.8% → 0.45% | 低 | 〔实测/案例〕 | [02 §C](02-pipeline-descriptor-commandbuffer.md) |
| 内存 | UMA 判定 + 持久映射环形缓冲 + VMA + `VK_EXT_memory_budget` | 省一次全量 DRAM 往返 | 中 | 〔规范/厂商文档〕 | [03 §A](03-igpu-bandwidth.md) |
| 渲染结构 | 全量审计 load/store op；中间 RT 去 `SAMPLED/STORAGE`；用 attachment resolve | 省全屏读/写，触发 fast clear | 低 | 〔规范〕 | [03 §C/§D](03-igpu-bandwidth.md) |
| 布局 | 中间图像禁用 `TILING_LINEAR`；必要时 `TRANSIENT_ATTACHMENT|LAZILY_ALLOCATED` | 恢复带宽压缩 | 低 | 〔规范/厂商文档〕 | [03 §D](03-igpu-bandwidth.md) |
| 帧节奏 | 观测队列深度与 present 阻塞；不设帧率上限 | 稳帧时间、减少排队 | 低 | 〔厂商文档/实测〕 | [03 §E](03-igpu-bandwidth.md) |
| 可观测性 | 埋 5 个计数（PSO/descriptor/cmd alloc/submit/map）+ GPU 帧时间 + present 延迟 | 让所有优化可判定 | 低 | 〔方法论〕 | [04 §B](04-tools-cases.md) |
| 工具 | 「链路地板」基线（clear-only）+ 三段分流 + 静态检查 | 避免优化错对象 | 低 | 〔方法论〕 | [04 §B/§E](04-tools-cases.md) |

**明确不建议做（在核显上收益为负或风险过高）**

- 无条件加 frames in flight / 加交换链图像数（换延迟、换内存，吞吐未必涨）。
- 用 `VK_IMAGE_TILING_LINEAR` 图省事（放弃压缩与 fast clear）。
- 把「mailbox 不限速」本身当成问题——它在本项目是目标；真正的问题是**没有任何 present 阻塞测量**，所以看不出它是否在排队。
- 为了「参数化」把静态状态塞进 PSO 键（缓存命中率下降）。
- 每帧 `vkCmdResolveImage` 做 MSAA resolve（应走 attachment resolve）。
- 在发布版保留 validation / GPU-AV / per-draw debug label。

---

## 3. 与本项目（RhineRender）的合并优先级

详细审计见 [05-rhine-audit.md](05-rhine-audit.md)，这里只给合并后的动作顺序：

| 优先级 | 动作 | 为什么排这里 | 详见 |
|---|---|---|---|
| **P0** | 补 present 可观测性（`present_id` + `present_wait2`、GPU 帧时间、submit 耗时、实际 present mode + 退化原因） | 没有它，后面所有取舍都是猜 | 05 §C/G |
| **P0** | 建「链路地板」基线（clear-only）+ 记录 present mode/vsync/是否被外部限帧/电源模式（仅记录） | 先分清是链路还是场景 | 04 §B.5 |
| **P1** | 交换链图像数做成可配置，**默认保留 6**（现为硬编码抬到 6） | 你们实测 6 比 3 快 ~5%；需要低延迟时再由用户降 | 05 §E |
| **P1** | 全进程单一 `VkPipelineCache`（含 FFX FG 的 compute 管线）+ 落盘 | resize 会全量重建 FG 上下文，无缓存时每次重建都要重编译 | 05 §D、02 §A |
| **P3** | 手写 barrier 换成 sync2 语义（`dstStageMask = NONE`），并给「每帧全屏覆盖」前提加断言注释 | 现在 `BOTTOM_OF_PIPE`/0 功能正确、帧率收益≈0，只是整洁度；但 `UNDEFINED` 重置依赖全屏覆盖，将来做脏矩形会花屏 | 05 §F、01 |
| **P2** | 去掉每帧空提交（改用 present_wait 语义回收 acquire 信号量） | 一次 submit 的量级，先量后动 | 05 §A |
| **P2** | 声明并探测 `surface_maintenance1`/`swapchain_maintenance1`/`present_mode_fifo_latest_ready` | 平台能力差异大，需能力表 | 05 §H |
| **不建议** | 自建第二套呈现/同步体系、改用 `VK_EXT_shader_object`、引入 `VK_KHR_pipeline_binary` | 与 Qt/QRhi 的所有权冲突，收益不确定 | 05 §"不建议" |

---

## 4. 反模式速查（核显尤其致命）

1. 每帧 `vkCreateGraphicsPipelines` / `vkCreateComputePipelines`（或首次使用时才建）。
2. 每帧 reset descriptor pool + 重建 set。
3. 每帧 `vkAllocateCommandBuffers`/`vkFreeCommandBuffers`。
4. 每帧 `vkMapMemory` + `vkFlushMappedMemoryRanges`（尤其小范围、几百次）。
5. 无 `VkPipelineCache`（传 `VK_NULL_HANDLE`），或缓存不落盘。
6. 全屏 pass 用 `LOAD_OP_LOAD`/`STORE_OP_STORE` 而不需要旧内容/后续不读。
7. `vkCmdClearAttachments` 代替 `loadOp=CLEAR`；`vkCmdResolveImage` 代替 attachment resolve。
8. 中间 RT 带 `SAMPLED|STORAGE` 却从不采样/写入（压缩率下降）。
9. `TILING_LINEAR` 的中间图像。
10. 屏障一律 `ALL_COMMANDS` ↔ `ALL_COMMANDS` / `BOTTOM_OF_PIPE`。
11. 每帧 `vkDeviceWaitIdle` 或 `vkQueueWaitIdle`。
12. 用「无帧率上限 + mailbox」代替一切判断（它不是问题，问题是没有测量：没有 present 延迟与队列深度，你无法知道有没有在空转）。
13. 交换链图像数拉满、frames in flight 拉满，但没有任何延迟测量。
14. 假设 `FIFO` 一定可用（Wayland/旧驱动上未必）。
15. present 不等 `renderDone`，或 `presentWaitSemaphoreCount=0` 却没意识到语义。
16. 发布版开 validation / GPU-AV / 每 draw debug label。
17. 用 RenderDoc 的时间轴当性能结论（重放会改变时序）。
18. 把 `deviceType == INTEGRATED_GPU` 当 UMA 的唯一判据（某些 SoC 报 `CPU`/`OTHER`）。
19. 在 UMA 上照抄「staging → device local」两段式上传。
20. 只测 fps 不测 `p50/p99` 与 input-to-photon。

---

## 5. 测量协议（最小可用版）

1. **固定变量**：present mode、vsync、分辨率、内容（clear-only vs 满内容）；**不设帧率上限**，但要记录是否被外部（驱动/合成器/工具）限帧，电源模式只作环境记录、不作结论依据。
2. **链路地板**：保留完整 present 链，内容换成 clear 或单三角形；若 p50 已 ≥ 1/refresh，问题在链路。
3. **三段分流**（PresentMon）：`MsCPUBusy` → CPU 提交受限；`MsGPUBusy` → GPU 执行受限；`MsInPresentAPI` → 呈现受限；`PresentMode` 从 `Hardware: Independent Flip` 掉到 `Composed:*` 就是多一次合成拷贝的硬证据。
4. **计数埋点**（release + 无 layer）：PSO 创建数、descriptor 更新数、cmd buffer 分配数、submit 数、map/flush 次数；每帧或每 N 帧打印。
5. **能力探测表**：启动打印 deviceType、driverID、UMA 标志、heapBudget、image_compression_control、present_wait2、swapchain_maintenance1、surface_maintenance1、present_mode_fifo_latest_ready。
6. **只看 p50/p99 与延迟**，不看单次 fps 峰值；改动前后同一机器、同一电源策略。

---

## 6. 分册索引

| 分册 | 内容 | 适合谁读 |
|---|---|---|
| [01 · 同步、提交与呈现](01-sync-submit-present.md) | 信号量/栅栏/屏障语义、submit 结构、present mode、present_id/wait2、帧节奏与队列 | 改呈现层的人 |
| [02 · 管线 / 描述符 / 命令缓冲 / 内存](02-pipeline-descriptor-commandbuffer.md) | PSO 缓存、GPL/shader object、描述符零更新、命令缓冲回收、VMA、动态渲染、校验层成本 | 改 CPU 侧对象生命周期的人 |
| [03 · 核显内存模型与带宽](03-igpu-bandwidth.md) | UMA、带宽预算、TBDR vs IMR、压缩与布局、平台差异、25 条检查表（功耗一节仅作背景） | 做架构决策的人 |
| [04 · 工具、测量与真实案例](04-tools-cases.md) | 工具矩阵、三段分流方法论、静态检查、7 个真实案例（Godot/mpv/FSR3）、调查流程模板、10 条误判 | 要落地验证的人 |
| [05 · 本项目现状审计](05-rhine-audit.md) | 逐项审计 A–H、已做对的 8 条、优先级表、验证计划、不建议做的 6 条 | 本项目维护者 |
| [06 · 实施记录与实测](06-implementation.md) | WP1–WP6 落地状态、真机数字（Iris Xe/Mesa）、明确不做的三项及判据、复现命令、后续性价比排序 | 本项目维护者 / 想照做的人 |
| [07 · 全链路优化实施](07-render-optimization.md) | 全链路报告 A01–A11 的落地方式与验收口径、A07 的证否结论、A12 的实验门槛与判定矩阵、构建噪声 | 改呈现层、渲染线程与资源上传的人 |
| [08 · 常驻内存随翻动上涨](08-memory-growth.md) | 内存探针口径、逐帧增长与按曲目阶梯的区分、上传字节与堆增长 1:1 的证据、实例池化默认开启的修复、回归判定 | 查泄漏 / 改资源上传的人 |

---

## 7. 参考来源精选（一手优先）

**Khronos / 规范**
- [Vulkan Guide · Memory Allocation](https://docs.vulkan.org/guide/latest/memory_allocation.html)
- [Vulkan Guide · Pipeline Cache](https://docs.vulkan.org/guide/latest/pipeline_cache.html)
- [Vulkan Spec · WSI（present_wait / present_id）](https://docs.vulkan.org/spec/latest/chapters/VK_KHR_surface/wsi.html)
- [Vulkan Best Practices（VVL）](https://github.com/KhronosGroup/Vulkan-ValidationLayers/blob/main/docs/best_practices.md)
- [Khronos Blog · pipeline binary](https://www.khronos.org/blog/bringing-explicit-pipeline-caching-control-to-vulkan)

**厂商**
- [AMD GPUOpen · FSR Frame Interpolation Swapchain](https://gpuopen.com/manuals/fsr_sdk/techniques/frame-interpolation-swap-chain/)
- [Arm · Best Practice Warnings in Vulkan SDK](https://developer.arm.com/community/arm-community-blogs/b/mobile-graphics-and-gaming-blog/posts/arm-best-practice-warnings-in-vulkan-sdk)
- [Intel · Graphics Performance Analyzers](https://www.intel.com/content/www/us/en/developer/tools/graphics-performance-analyzers/overview.html)
- [Microsoft · PresentMon 指标定义](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md)

**实测案例**
- [Godot #100025 · swapchain 多余等待](https://github.com/godotengine/godot/issues/100025)
- [Godot #89856 · MAILBOX 让 GPU 常驻 100%](https://github.com/godotengine/godot/issues/89856)
- [Godot #106221 · waitable swapchain vs AUTO pacing](https://github.com/godotengine/godot/pull/106221)
- [mpv #7251 · queue-count 1→3](https://github.com/mpv-player/mpv/issues/7251)
- [AMD · RGP 对 <3 CU 设备的限制](https://github.com/GPUOpen-Tools/radeon_developer_panel/issues/62)

> 各分册文末还有完整来源列表（合计 100+ 条，一手来源占多数）。
