# 01 · 同步、提交与呈现链路（核显 + Qt/QRhi 自持 swapchain）
> **范围**：只谈 Vulkan 链路本身——信号量/围栏、屏障与布局、提交拓扑、呈现与帧节奏、平台 WSI、测量方法。
> **不含**：LOD/剔除/批处理/光照/阴影/后处理配方/资源压缩等 3D 场景优化（仅在解释机制时顺带提一句）。
> **证据等级**：〔规范〕Vulkan 规范/Khronos 官方文档 ·〔厂商文档〕Intel/AMD/ARM/NVIDIA/Microsoft 官方文档 ·〔实测/案例〕有具体数据或代码位置 ·〔社区经验〕工程共识、"量级"级判断。
> **本机限制（实测）**：容器内无 `/dev/dri`，`vulkaninfo` 报 `vkEnumeratePhysicalDevices ERROR_INITIALIZATION_FAILED`，因此**本机支持哪些 present mode / 扩展一律标〔未验证〕**，需在真机用 `vulkaninfo --summary` 与 `vulkaninfo | grep -i present` 逐 surface 确认。

---

## 0. 结论摘要

> 全局前提（m00232–m00233）：本项目不关心功耗；运行时无法获取刷新率，一律按**无穷刷新**假设——凡涉及「帧率 vs 刷新率」的判据在本文中一律不成立。

| # | 结论 | 等级 |
|---|---|---|
| 1 | 本项目「只带信号量的空提交」是规范内用法，但它的**收益是 CPU 可观测性**（每槽一个 fence），不是性能；它并不修复「Qt 侧 wait 阶段固定为 COLOR_ATTACHMENT_OUTPUT」这个真正的正确性边界。 | 〔规范〕〔实测/案例〕 |
| 2 | acquire 信号量的等待阶段必须覆盖**该图像第一次被访问的管线阶段**；若帧内第一次写是 TRANSFER（FSR3 合成输出 blit），拿 COLOR_ATTACHMENT_OUTPUT 去等就是数据竞争。 | 〔规范〕 |
| 3 | 禁止 `vkQueueWaitIdle`/`vkDeviceWaitIdle` 出现在帧循环；本项目 present 的 `vkDeviceWaitIdle` 退化路径必须计数告警。 | 〔厂商文档〕 |
| 4 | 布局转换贵的不是"转换"本身，而是它隐含的 render-cache flush/AUX 解析与作为全局依赖切断 GPU 并行；核显上每帧固定的 UNDEFINED→COLOR_ATTACHMENT_OPTIMAL→PRESENT_SRC 两条是**必要**的，但 pass 中间的冗余转换不是。 | 〔厂商文档〕 |
| 5 | `ALL_COMMANDS`/`ALL_GRAPHICS` 是 bubble 的头号来源；应换成 sync2 的精确 stage/access mask。 | 〔厂商文档〕 |
| 6 | 时间线信号量能省 CPU（一次等一批/免对象管理），但**不能**直接用于 `vkQueuePresentKHR`（必须 BINARY），故只能替换 GPU-GPU 侧，present 侧仍需二进制桥。 | 〔规范〕 |
| 7 | 把 present 推到下一次 acquire 之前 = 最多多 **1 个帧间隔**的延迟（按实测帧时折算；60 Hz 时约 16.7 ms，但本项目不假设刷新率）；换来的是对 `VkQueue` 的外部同步时序，而不是「锁」。 | 〔规范〕〔实测/案例〕 |
| 8 | 核显 + Wayland 下 MAILBOX 通常不可用、direct scanout 需满足全屏/不透明/格式匹配等条件，否则 compositor 多一次全屏拷贝。 | 〔社区经验〕〔未验证〕 |

---

## A. 信号量与围栏
### A.0 该做 / 别做
- **该做**：同步对象按「in-flight 槽」分配（acquire/fence），呈现代理信号量按「swapchain image index」分配；帧循环里只等 fence、不等 idle。
- **别做**：每帧新建信号量/围栏；在帧循环调用 `vkQueueWaitIdle`/`vkDeviceWaitIdle`；让同一个二进制信号量被两个队列同时等待；`pWaitDstStageMask` 与 `pWaitSemaphores` 数组错位。

### A.1 二进制信号量的复用规则与死锁形态
**机制**：二进制信号量是一个"未消费的 signal"令牌，生命周期严格是「一次 signal → 一次 wait」。规范用 VUID 把这个约束钉死：

- `VUID-vkQueueSubmit-pSignalSemaphores-00067`：每个二进制信号量**在被 signal 时**必须处于 unsignaled 状态〔规范〕[vkQueueSubmit](https://docs.vulkan.org/refpages/latest/refpages/source/vkQueueSubmit.html)
- `VUID-vkQueueSubmit-pWaitSemaphores-03238`：被等待的二进制信号量必须有**已经提交的** signal 操作〔规范〕（同上）
- `VUID-vkQueueSubmit-pWaitSemaphores-00068`：同一个二进制信号量不得同时被多个队列等待〔规范〕（同上）

**四种典型死锁/失效**：

1. **令牌泄漏**：某帧 acquire 了图像但 Qt 没提交（丢帧/异常路径），acquire 信号量的 signal 永远没人消费 → 下一帧同一槽再 signal 就违反 00067。本项目用 `submitWaitPending[]` + "只等不信号"的 recover 空提交处理了这条（`src/fg/VulkanPresenter.cpp:650-782`），代价是**该帧 CPU 硬阻塞**在 `vkWaitForFences`。
2. **fence 未 reset 就复用**：`VUID-vkQueueSubmit-fence-00063`「fence must be unsignaled」，且 `00064` 要求该 fence 没挂在别的未完成提交上〔规范〕。本项目的 `fenceInfo.flags = 0` 注释（`VulkanPresenter.cpp:544`）正是这条。
3. **一个信号量等两次**：违反 00068，表现为 device lost 或随机挂起。
4. **swapchain 信号量按"帧"而不是按"image"分配**：上一次 present 还没消费完这张图就再次 signal。

**swapchain 信号量的正确复用方式**〔规范〕[Khronos: Swapchain semaphore reuse](https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html)：渲染完成信号量必须**按 image index** 分配。理由：只有"再次 acquire 到同一张图"才证明 presentation engine 已经把它释放，因此该 index 的信号量此时必然已被消费。本项目 `renderDone[imageIndex]` 正是这个形态——**这是做对了的地方，不要改成 per-frame 信号量**。

- **代价/风险**：按 image 分配会占 `imageCount` 个信号量（3~4 个），可忽略。
- **不适用**：若同一 image 在一帧内被 present 两次（不可能），或使用了 `VK_KHR_shared_presentable_image`。

### A.2 acquire 的 imageAvailable 为什么不能与渲染队列的等待阶段乱配
**这是本文最重要的一条正确性结论。**

**机制**：`vkAcquireNextImageKHR` 的 `semaphore` 在"图像可被应用使用"时 signal。随后某个提交用 `pWaitDstStageMask`（sync1）或 `VkSemaphoreSubmitInfo::stageMask`（sync2）声明"哪些管线阶段必须等这个 signal"。**等待阶段之后的阶段不受保护**：dst stage 是"第二同步范围的起点"，只有该阶段及其后的阶段才被阻塞。

**本项目的具体风险**：QRhi 把所有注入的 wait 写死为 `VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT`（`qrhivulkan.cpp:3100` 一带，见 [Qt 源码](https://code.qt.io/cgit/qt/qtbase.git/plain/src/gui/rhi/qrhivulkan.cpp)），而 `QRhiVulkanQueueSubmitParams` 只有 `waitSemaphoreCount/waitSemaphores/signalSemaphoreCount/signalSemaphores/presentWaitSemaphoreCount/presentWaitSemaphores`，**没有 stage mask 字段**（`/usr/include/qt6/QtGui/6.12.0/QtGui/rhi/qrhi_platform.h`，本机实测）。因此：

- 若该帧**第一次触碰 swapchain image 的工作是 color attachment 写**（典型 render pass 输出）→ COLOR_ATTACHMENT_OUTPUT 是**正确且最优**的：VERTEX/TRANSFER 等前序阶段不必等 acquire，CPU/GPU 可提前跑。
- 若第一次触碰是 **TRANSFER**（FSR3 帧生成的合成输出 blit、或把上采样结果 blit 到 swapchain）或 **VERTEX/COMPUTE**（从该图采样）→ 这些阶段不在等待范围内，**可能在图像仍归 presentation engine 所有时写入** = 数据竞争。表现：花屏、闪烁、偶发黑帧，且默认校验层不报。
- 同理，若在 Qt 的 command buffer 里对该图做 `UNDEFINED → COLOR_ATTACHMENT_OPTIMAL` 且 `srcStageMask = NONE`，这次转换不等待任何东西，其正确性**完全**依赖 acquire 信号量的 dst 阶段覆盖到"转换之后的第一次访问"。

**该做**：

- 用 `VK_LAYER_KHRONOS_validation` 的 **synchronization validation** 跑一帧全流程（见 F 节）；它会按 stage mask 建模 semaphore wait，能直接报 `SYNC-HAZARD-*`。
- 结构上保证"每帧对 swapchain image 的第一次访问是 color attachment"。若必须 blit，则把"渲染到中间图 → blit 到 swapchain"改成"渲染直接到 swapchain"或"在 Qt 提交前用一次独立的、自己控制的提交做 TRANSFER 并显式等 acquire"。
- 若想彻底摆脱 QRhi 的固定 stage，唯一干净的办法是**不用 QRhi 注入 wait 列表**，改为自己提交最终呈现前的那一步（自建 command buffer + `vkQueueSubmit2`）。

〔规范〕[VkSemaphoreSubmitInfo / sync2](https://docs.vulkan.org/guide/latest/extensions/VK_KHR_synchronization2.html)

### A.3 时间线信号量何时更省 CPU
**机制**〔规范〕[VK_KHR_timeline_semaphore](https://docs.vulkan.org/refpages/latest/refpages/source/VK_KHR_timeline_semaphore.html)：时间线信号量是单调计数器，支持 Host query / Host wait / Host signal / Device wait / Device signal 五种操作，已进 Vulkan 1.2 核心。

**省 CPU 的三种场景**：

1. **CPU 侧查进度**：`vkGetSemaphoreCounterValue` 一次拿到"GPU 跑到哪"，替代"每帧 fence + `vkWaitForFences`"。对多帧 in-flight，一个 counter 就能表达"第 N 帧完成了吗"。
2. **一次等一批**：`vkWaitSemaphores` 传数组，一个系统调用等多个同步点；N 个二进制信号量要 N 次调用。
3. **多队列共享进度**：compute/transfer 与 graphics 各自推进同一个 counter，省掉每个对之间的一对二进制度量。

**代价/风险**：

- 时间线信号量**不能**直接给 `vkQueuePresentKHR` 用：`VUID-vkQueuePresentKHR-pWaitSemaphores-03267` 要求 `pWaitSemaphores` 全部是 `VK_SEMAPHORE_TYPE_BINARY`〔规范〕[vkQueuePresentKHR](https://docs.vulkan.org/refpages/latest/refpages/source/vkQueuePresentKHR.html)。present 侧必须保留一个二进制"桥"。
- 时间线信号量的 signal 值必须严格递增；跨帧复用时若把 counter 与"帧号"混用，容易在丢帧/recover 路径上算出重复值。
- **不适用**：acquire 的 imageAvailable 本质是"一次性、每 acquire 一个"事件，用时间线信号量没有收益（且 WSI 只给二进制）。

### A.4 fence 与 CPU 等待的正确姿势
- **一次等一批**：`vkWaitForFences(dev, count, pFences, VK_TRUE, timeout)`，把这一帧所有 fence 一起等，省 syscall。
- **超时**：生产代码用有限超时（如 1 s）+ 失败即走 device lost 恢复，不要 `UINT64_MAX` 无限等（会 hang 死 UI）。本项目 `kAcquireTimeoutNs` 就是这个思路。
- **reset 的时机**：`vkResetFences` 必须在"确认 GPU 已完成 + 即将重新提交"之间，且与提交同线程；提前 reset 会造成 00063 违例。
- **帧槽数量决定 CPU 能领先多少**：QRhi 的 `QVK_FRAMES_IN_FLIGHT = 2`，意味着 `beginOffscreenFrame` 最多等"两帧前的 fence"，CPU 天然领先 ≤2 帧。想再降延迟就减到 1（牺牲吞吐），不要指望 present 侧。
- **别用 fence 做帧节奏**：fence 只告诉你"GPU 做完"，不告诉你"上屏了"。后者要用 `VK_KHR_present_wait`（D 节）。

### A.5 为什么禁止 `vkQueueWaitIdle`/`vkDeviceWaitIdle` 进帧循环
**机制**：`vkQueueWaitIdle` 等该队列**所有已提交工作**完成，等价于把 GPU 流水线抽干；`vkDeviceWaitIdle` 更狠，等所有队列。二者都把"CPU 提交"与"GPU 执行"的 overlap 彻底删除，CPU 与 GPU 变成串行。

**案例数据**〔厂商文档/案例〕[Khronos sample: wait_idle](https://docs.vulkan.org/samples/latest/samples/performance/wait_idle/README.html)：官方 sample 在 Mali-G76 上把 `vkQueueWaitIdle` 换成 fence，viking room 场景从 **72 ms/帧降到 56 ms/帧**（约 22%）。这是"每帧一次 idle"的代价量级参照。

**允许出现的位置**（都不是每帧路径）：swapchain 重建、device 销毁、surface 丢失恢复、离线导出/截图。

**本项目的具体点**：`present()`（`VulkanPresenter.cpp:819-899`）在 `paramsInstalled == false` 时退回 `vkDeviceWaitIdle`，注释自称"单次 50 ms 级"。这是**退化路径**，但只要 Qt 有一次没消费 `setQueueSubmitParams`，就会静默掉到同步节奏。**该做**：给这条路径加一个计数器 + 每秒日志/遥测，并在 debug 构建里 `assert`，否则它永远发现不了。

---

## B. 屏障与布局转换
### B.0 该做 / 别做
- **该做**：每帧只保留"必要"的转换；用精确 stage/access mask；把转换放在 render pass 的 `initialLayout/finalLayout` 或 `VkRenderingAttachmentInfo` 边界上；能 discard 就用 `UNDEFINED`。
- **别做**：`ALL_COMMANDS`/`ALL_GRAPHICS` 对 `ALL_*`；在 render pass 中间插全局 barrier；对同一图像一帧内反复 `COLOR_ATTACHMENT_OPTIMAL ↔ SHADER_READ_ONLY`；用 `vkCmdResolveImage` 做 MSAA 解析。

### B.1 布局转换的真实代价（核显尤其）
**机制**：布局转换不是"拷贝整张图"。它的成本来自三处：

1. **cache/render-target flush**：从 color attachment 切到 shader read，驱动必须把未落盘的 render cache 写出、并可能做 AUX/CCS（压缩元数据）解析。
2. **作为全局依赖切断并行**：barrier 让后续阶段等前面所有工作（见 B.4），在 TBR 上还可能迫使驱动 **split pass**，把本该留在 tile memory 的内容写回主存——这是核显上最贵的一项〔厂商文档〕[Khronos TBR best practices](https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html)。
3. **load/store 流量**：TBR 页原文强调 loadOp/storeOp 是"direct instructions to the hardware"，`LOAD_OP_CLEAR` 比 `vkCmdClearAttachments` 快（在 tile memory 内初始化、不产生外部内存流量），`STORE_OP_DONT_CARE` 则完全避免写回。

**量级判断**〔经验〕：一次全屏（1440p 级）layout transition 的开销在**几十微秒量级**，随分辨率与是否触发压缩元数据解析而变化；它单独看不致命，但每帧 4~6 次、且每次都切断并行时，累积成可见的帧时间抖动。**不要把它当"零成本"**，也不要编造具体数字——本机无 GPU 可测。

### B.2 必须的转换 vs 冗余的转换
**必须（swapchain 每帧）**：

1. acquire 后：`UNDEFINED → COLOR_ATTACHMENT_OPTIMAL`（或 `PRESENT_SRC → COLOR_ATTACHMENT_OPTIMAL`）
2. 渲染完：`COLOR_ATTACHMENT_OPTIMAL → PRESENT_SRC`

**选 `UNDEFINED` 还是 `PRESENT_SRC` 作 oldLayout**：如果该帧会**全屏重写**这张图（音乐可视化几乎总是），`UNDEFINED` 更好——它向驱动声明"内容可丢弃"，避免一次无用的 load；这也是 Khronos 对 swapchain image 的常见建议〔厂商文档/经验〕。若该帧只重绘局部（脏矩形），才需要 `PRESENT_SRC` 保内容。

**冗余（常见于 FSR/后处理链）**：`UPSCALED → SHADER_READ_ONLY` 只是为了给下一 pass 采样。若两 pass 在同一个 render pass 内，可用 input attachment 或 `VK_KHR_dynamic_rendering_local_read`（`vkCmdSetRenderingAttachmentLocationsKHR`）保住 on-chip 数据〔厂商文档〕（TBR 页）。**注意**：这条只在"能合并成一个 pass"时成立，合并本身属于后处理配方范畴，本文只谈同步/带宽层面的收益。

**动态渲染下的写法**（无 implicit transition，必须显式）：

```c
VkImageMemoryBarrier2 b = {
  .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
  .srcStageMask  = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
  .srcAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
  .dstStageMask  = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
  .dstAccessMask = VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
  .oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
  .newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
  .image = img, .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
};
VkDependencyInfo dep = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
                         .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &b };
vkCmdPipelineBarrier2(cmd, &dep);
```

**render pass 自动转换 vs 手写**：render pass 的 `initialLayout/finalLayout` 让驱动把转换**合并进 pass 的开始/结束**（TBR 上可完全留在 tile memory 内），通常比手写 barrier 更可能被优化；动态渲染没有 implicit，但在 `VkRenderingInfo` 里给同样的 loadOp/storeOp 时，TBR 页原文说"hardware logic remains identical"。**结论**：用哪个 API 不决定快慢，**是否有全局依赖切在 pass 中间**才决定快慢。

### B.3 同步范围过宽的代价
**规范/文档原文**〔厂商文档〕[Vulkan Guide: Profiling](https://docs.vulkan.org/guide/latest/profiling.html) 把 GPU 气泡的第一大根因写成：

> "Restrictive Barriers: Using `VK_PIPELINE_STAGE_ALL_COMMANDS_BIT` forces the GPU to wait for all previous work to finish before starting the next task, even if they aren't dependent."

TBR 页则直接点名：

> "Avoid using broad barriers like `VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT` to `VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT`, as these often create unnecessary stalls."

**该做**：把 mask 收窄到"真正的生产者/消费者"。典型对照：

| 场景 | 过宽写法 | 精确写法（sync2） |
|---|---|---|
| 渲染完 → 采样 | `ALL_GRAPHICS → ALL_COMMANDS` | `COLOR_ATTACHMENT_OUTPUT/COLOR_ATTACHMENT_WRITE → FRAGMENT_SHADER/SHADER_SAMPLED_READ` |
| 渲染完 → blit | `ALL_COMMANDS → ALL_COMMANDS` | `COLOR_ATTACHMENT_OUTPUT/COLOR_ATTACHMENT_WRITE → TRANSFER/TRANSFER_READ` |
| 上传后 → 顶点读 | `ALL_COMMANDS → ALL_COMMANDS` | `COPY/TRANSFER_WRITE → VERTEX_SHADER/VERTEX_ATTRIBUTE_READ`（或 `VERTEX_INPUT`） |
| 呈现前 | `ALL_COMMANDS → BOTTOM_OF_PIPE` | 交给 WSI：`COLOR_ATTACHMENT_OPTIMAL → PRESENT_SRC`，dst `NONE` |

**sync2 的语义变化**〔规范〕[VK_KHR_synchronization2](https://docs.vulkan.org/guide/latest/extensions/VK_KHR_synchronization2.html)：`VK_PIPELINE_STAGE_2_NONE` 取代了 "BOTTOM_OF_PIPE 作 dst" 的旧把戏；`TOP_OF_PIPE` 作 src 应迁移成 `ALL_COMMANDS` + `ACCESS_NONE`；mask 变成 64 位（`VkAccessFlags2`/`VkPipelineStageFlags2`），因为 32 位已经不够用。

### B.4 何时用 event 代替 barrier
**机制**：`VkEvent` 把一次完整 barrier 拆成两半——`vkCmdSetEvent2` 标记"生产完成"，`vkCmdWaitEvents2` 声明"消费开始"，两者之间可以插入**与该资源无关**的工作，让 GPU 先跑。这就是 split barrier。

**该做**：同一 command buffer 内，生产者与消费者之间有明显可并行的独立工作时；或在"一个 pass 的输出要到很后面才被读"时提前 set、延后 wait。

**别做/风险**：

- event **只在同一 queue 内有效**，跨队列/跨提交必须用 semaphore。
- event 不是免费的：驱动要维护 event 状态，且某些实现会退化成隐式全 barrier；用之前最好对比一下 RGP/Nsight 上的气泡。
- 不要拿 event 做"跨帧"同步（那需要 semaphore 或 fence）。

**不适用**：简单的"渲染完立刻采样"，一个窄 barrier 就够，加 event 只是噪音。

### B.5 新路径：host image copy 等
`VK_EXT_host_image_copy`〔规范〕[VK_EXT_host_image_copy](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_host_image_copy.html)：允许在 host 上直接 copy 到/从 image，**不经过 GPU 可访问的 staging buffer**，省掉 buffer 及其内存管理，某些架构还能省一次拷贝。提供 `vkCopyImageToImageEXT`/`vkCopyImageToMemoryEXT`/`vkCopyMemoryToImageEXT` 与 `vkTransitionImageLayoutEXT`。

- **适用**：纹理/查找表上传、截图回读、资源加载期。
- **不适用**：每帧 swapchain 呈现路径（swapchain image 不支持 host copy usage），以及需要 GPU 侧格式转换的场景。
- **代价**：host copy 是 CPU 同步操作，大图会阻塞主线程；且需要 `VK_IMAGE_USAGE_HOST_TRANSFER_BIT`。

---

## C. 提交拓扑
### C.0 该做 / 别做
- **该做**：一帧一次 submit（或极少几次）；用 `vkQueueSubmit2` + `VkSubmitInfo2`；把"只带信号量"的提交限定在必要处并计入成本。
- **别做**：每个 draw 一次 submit；用 `vkQueueSubmit` 的 `pWaitDstStageMask` 数组硬编码 `ALL_COMMANDS`；在帧循环里做队列族所有权转移。

### C.1 一次 `vkQueueSubmit` 里塞多少工作
**机制**：submit 的 CPU 成本 ≈ 一次内核态提交 + 驱动打包命令流 + 内部同步对象管理。**次数**比"总字节数"更影响 CPU；但一次 submit 内的工作是**有序**的，过大的 submit 会让尾部命令拖住整批的完成信号。

**经验法则**〔经验〕：

- 同一帧、彼此有依赖的工作 → 一个 submit。
- 无关工作（如下一帧的 compute）→ 另一个 submit，让 GPU 能交错。
- 需要"早完成早 signal"的工作（如呈现前最后一 blit）→ 不要和后面的大批工作绑在一个 submit 里。

**数据**：本机无 GPU，无法测 submit 间隔；量级上现代驱动单次 submit 是**微秒级**〔经验〕，但 Nsight Systems 专门把 "command submission overhead" 列为一类问题〔厂商文档〕[Profiling](https://docs.vulkan.org/guide/latest/profiling.html)，说明它在高帧率/小批量场景确实可见。

### C.2 VkSubmitInfo2 相对 VkSubmitInfo 的收益
**该做**：新代码一律 `vkQueueSubmit2` + `VkSubmitInfo2` + `VkSemaphoreSubmitInfo`。

**机制**〔规范〕[vkQueueSubmit](https://docs.vulkan.org/refpages/latest/refpages/source/vkQueueSubmit.html)（页面顶部写明 "This functionality is superseded by vkQueueSubmit2"）：

- stage mask 绑在**每个信号量**上（`VkSemaphoreSubmitInfo::stageMask`），不再是"与 `pWaitSemaphores` 一一对应的平行数组"——后者是最容易错位、且错位后静默出错的地方。
- 原生支持时间线信号量（带 value）。
- 少一批 VUID 需要记。

**代价**：需要 `VK_KHR_synchronization2`（Vulkan 1.3 核心）；老驱动需 fallback。

### C.3 空提交（只带信号量）：代价与陷阱
**合法性**：`vkQueueSubmit` 的描述首句是 "Submits a sequence of semaphores **or** command buffers"〔规范〕，因此 `commandBufferCount = 0` + 只给 wait/signal 是设计内用法。

**它解决什么**：把 acquire 得到的 imageAvailable 二进制信号量**转成另一个二进制信号量**，让 Qt 的提交去等；同时给该帧槽一个可 join 的 fence（`VulkanPresenter.cpp:746-748` 注释明说）。

**它不解决什么**（关键）：

- **不解决 stage 问题**：Qt 侧仍然在 COLOR_ATTACHMENT_OUTPUT 等，见 A.2。空提交只是把"一个二进制"换成"另一个二进制"。
- **不减少延迟**：多一次队列操作 = 多一次信号量跳变，GPU 侧多一个依赖节点。

**代价与陷阱**：

1. **每次空提交 = 一次完整 submit 的 CPU 成本**（驱动要为它建 batch），即使里面没有命令。
2. **fence 约束**：`VUID-vkQueueSubmit-fence-00063` fence 必须 unsignaled；`00064` 不能挂在别的未完成提交上〔规范〕。所以每槽一个独立 fence 是**必须**的，不能复用 QRhi 的 `ofr.cmdFence`。
3. **acquire 超时时不能提交**：`vkAcquireNextImageKHR` 返回 `VK_TIMEOUT`/`VK_NOT_READY` 时信号量**未 signal**，此时若提交等待它的空提交，就违反 03238（等待一个没有已提交 signal 的信号量）→ device lost。本项目在 TIMEOUT 分支提前 return 是对的（`VulkanPresenter.cpp:650-782`）。
4. **recover 路径会阻塞 CPU**：`submitWaitPending` 时的"只等不信号"空提交 + `vkWaitForFences`，是罕见路径但确实会把 CPU 顶住一个 submit 往返。
5. **ALL_COMMANDS 作 wait stage**：空提交里没有命令时影响可忽略，但一旦有人往里塞命令，就立刻变成全局栅栏。**建议**改成 `VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT` 或直接保留并加注释说明"此提交永不携带命令"。

### C.4 多队列与队列族所有权转移
**该做**：graphics/present 尽量同族；compute/transfer 独立队列只在**真有并行工作**时才值。

**机制**〔规范〕[VkSharingMode](https://docs.vulkan.org/refpages/latest/refpages/source/VkSharingMode.html)：

- `EXCLUSIVE`：同一时刻只属于一个队列族；创建时不属任何族，首次使用隐式获得所有权；跨族访问必须做 ownership transfer（`VkImageMemoryBarrier` 的 `srcQueueFamilyIndex/dstQueueFamilyIndex`，配 release/acquire 两次 barrier）。
- `CONCURRENT`：多族可并发访问，但原文明确 "may result in lower performance access to the buffer or image than `VK_SHARING_MODE_EXCLUSIVE`"〔规范〕。

**取舍**：

| 情况 | 选择 | 理由 |
|---|---|---|
| 只有一个 graphics 族且支持 present | EXCLUSIVE，零转移 | iGPU 常见；最省 |
| graphics 与 present 不同族 | EXCLUSIVE + 每帧一次 release/acquire | 转移成本 = 一次 barrier，可控 |
| 资源被多族高频随机访问 | CONCURRENT | 省转移，但每次访问可能降速 |
| 只读纹理跨族 | CONCURRENT 可接受 | 无写冲突，转移收益低 |

**别做**：在帧循环里对 swapchain image 做所有权转移——WSI 创建的 image 的族归属由驱动决定，应用不该假设能转移；present 的队列族必须拥有该 image〔规范〕[vkQueuePresentKHR](https://docs.vulkan.org/refpages/latest/refpages/source/vkQueuePresentKHR.html)。

---

## D. 呈现与帧节奏
### D.0 该做 / 别做
- **该做**：把 `vkGetPhysicalDeviceSurfacePresentModesKHR` 的真实集合**探测并记录**（每个 surface 一套），按实测的 present 阻塞时长/帧间隔选模式；`preTransform = currentTransform`；`compositeAlpha` 取 supported 集合里最「不透明」的那个。
- **别做**：假设「关掉 vsync 就一定更快」或「开 vsync 就是 60」；假设 `imageCount == minImageCount`；在 Wayland 上硬要 MAILBOX 而不 fallback；用 `IMMEDIATE` 当「低延迟」的万能药。

### D.1 四种 present mode 的真实差别
〔规范〕[VkPresentModeKHR](https://docs.vulkan.org/refpages/latest/refpages/source/VkPresentModeKHR.html) 逐字语义：

| 模式 | 等 vblank | 撕裂 | 内部队列 | 实际行为 |
|---|---|---|---|---|
| `FIFO` | 是 | 否 | FIFO 队列 | 唯一**必须**支持；稳定、延迟 = 队列深度 × 帧时 |
| `FIFO_RELAXED` | 一般等 | **迟到时可能** | FIFO | 错过 vblank 就立即更新；抖动时省一帧延迟，代价是偶发撕裂 |
| `MAILBOX` | 是 | 否 | **单条**队列 | 队列满时**新请求替换旧条目**，旧图像立刻可被应用复用；延迟低但丢帧 |
| `IMMEDIATE` | 否 | **是** | 无需排队 | 最低延迟、必撕裂 |
| `FIFO_LATEST_READY`（新） | 是 | 否 | 按"就绪"筛选 | 每个 vblank 把已就绪的连续请求全部出队、**只呈现最后一个**，其余丢弃；配合 display timing 用 |

**注意**：`FIFO_LATEST_READY_KHR/EXT` 的枚举值是 `1000361000`，是较新的扩展，老驱动没有〔规范〕。

**刷新率未知时这些语义还剩多少**：上表的「等 vblank」是规范措辞，**不等于**「每 16.7 ms 一次」。运行时拿不到刷新率，因此 FIFO 可能被驱动/合成器按真实刷新节流、**也可能等价于 immediate**（合成器或注入层接管 present、surface 实际不上屏等）；MAILBOX / FIFO_RELAXED 的「替换旧条目 / 抢跑」是否真的发生，也无法从 API 侧推断。结论：**present mode 必须探测并记录，但不得用它反推刷新率，也不得假设「关 vsync 更快」。**

**选法**：

1. 启动时枚举 `vkGetPhysicalDeviceSurfacePresentModesKHR`，把「请求的模式 / 实际创建成功的模式 / 实测帧间隔分布」三者一起写进日志。
2. 默认选**能创建成功且实测 present 阻塞最短**的模式：按 `vkQueuePresentKHR` 的 CPU 耗时与 acquire 阻塞时长排序，而不是按「vsync 开/关」的直觉。
3. `IMMEDIATE` 要单独验证「是否真的不排队」——未知刷新率下它可能照样被节流。
4. 帧生成（FSR3）要求**帧间隔可预测**；MAILBOX 的丢帧会打乱这个间隔，因此开插帧时优先「不丢帧」的模式。

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

### D.2 minImageCount / compositeAlpha / preTransform 的坑
〔规范〕[VkSwapchainCreateInfoKHR](https://docs.vulkan.org/refpages/latest/refpages/source/VkSwapchainCreateInfoKHR.html)：

- `minImageCount`："the minimum number of presentable images that the application needs. The implementation will either create the swapchain with **at least** that many images, or it will fail" → **实际数量 ≥ minImageCount**，代码必须读回 `vkGetSwapchainImagesKHR` 的真实数量，不能假设相等。
- `MAILBOX` 想稳定"总有图可画"，经验上要 ≥3 张〔经验〕；FIFO 下 `minImageCount + 1` 可吸收抖动。
- `preTransform`：必须 ∈ `supportedTransforms`（`VUID-...-preTransform-01279`）。若 ≠ `currentTransform`，原文说 presentation engine 会 "transform the image content as part of the presentation operation" → 可能走合成/额外拷贝路径。桌面平台 `currentTransform` 通常是 `IDENTITY`，**直接传 currentTransform**。
- `compositeAlpha`：必须 ∈ `supportedCompositeAlpha`（`VUID-...-compositeAlpha-01280`）。Wayland 上常见 `OPAQUE`/`PRE_MULTIPLIED`；`INHERIT` 在部分平台不支持。选 `OPAQUE` 最省（compositor 可以做不透明优化/direct scanout）。
- `presentMode`：必须 ∈ `vkGetPhysicalDeviceSurfacePresentModesKHR` 的返回集合（`VUID-...-presentMode-01281`）。
- `clipped`：`VK_TRUE` 允许驱动丢弃不可见区域，全屏/无遮挡时通常更快。

### D.3 `VK_KHR_present_id` + `present_wait`
〔规范〕[VK_KHR_present_wait](https://docs.vulkan.org/refpages/latest/refpages/source/VK_KHR_present_wait.html)：

- 设计目的是 "by managing the number of outstanding images yet to be presented"——即**限制在途帧数**，而不是"等 GPU 做完"。
- Issue 1 原文：wait "will finish when the present is visible to the user"，实现应 "signal the wait as close as possible to the presentation of the first pixel"。
- Issue 2：因为 display 与 rendering 常在两个驱动里，所以提供独立同步 API 而非复用 fence。

**该做**：用它替代「靠下一次 acquire 隐式证明 present 完成」，得到**在途帧数上限**与「上屏时间」反馈；pacing 目标是**减少排队与阻塞**，不是把帧对齐到某个刷新周期（刷新率未知）。配合 `VK_EXT_present_timing` 取上屏时间戳。

**代价/风险**：

- `vkWaitForPresentKHR` 是**阻塞调用**，不能放在渲染线程关键路径上；放独立线程或用非阻塞轮询。
- Linux 上长期是 **opt-in**：Mesa 先实现（[Phoronix](https://www.phoronix.com/news/Mesa-VK_KHR_present_wait)），后来才扩到 Wayland（[Phoronix](https://www.phoronix.com/news/Mesa-KHR_present_wait-Wayland)）〔社区/新闻〕。**必须在运行时查 `VK_KHR_present_wait` 是否可用**，不可用就不能把它写进主路径。
- 更新的 `VK_KHR_present_wait2` 改为 **per-surface**（一个 device 多 surface 更正确），语义与上述同源〔规范〕[present_wait2 proposal](https://docs.vulkan.org/features/latest/features/proposals/VK_KHR_present_wait2.html)。

### D.4 低延迟扩展：存在的与不存在的
- **`VK_NV_low_latency2`**〔规范〕[VK_NV_low_latency2](https://docs.vulkan.org/refpages/latest/refpages/source/VK_NV_low_latency2.html)：**Not ratified**，依赖 Vulkan 1.2。提供 latency marker（`vkSetLatencyMarkerNV`）、让 CPU 睡到"刚好赶上"（`vkLatencySleepNV`）、以及 `vkQueueNotifyOutOfBandNV`。对帧生成场景有价值（避免 CPU 盲目跑在前面导致队列堆积）。**风险**：仅 NVIDIA、Linux 驱动支持面窄〔未验证〕，且与 LSFG/Mako 这类注入层可能冲突（本机装了 `VK_LAYER_LSFGVK_frame_generation`，见第 0 节环境说明）。
- **`VK_EXT_low_latency` 不存在**。网络上常见这个拼写，属于误传；不要再引用〔规范〕（Khronos 扩展列表里没有该名字，NV_low_latency2 之外只有 `VK_NV_low_latency`（旧版，已被 2 取代））。
- **`VK_GOOGLE_display_timing`**：给出"上一次 present 的实际显示时间 + 未来 vblank 预测"，可做精确 pacing。**风险**：扩展老、Wayland 支持差〔未验证〕，且依赖驱动上报的时序质量。
- **`VK_EXT_present_timing`**（较新）：厂商中立的"present 时间反馈"路径，配合 `VK_KHR_present_id`/`present_wait` 使用；返回码里有 `VK_ERROR_PRESENT_TIMING_QUEUE_FULL_EXT`（见 vkQueuePresentKHR 返回码）〔规范〕[present_timing proposal](https://docs.vulkan.org/features/latest/features/proposals/VK_EXT_present_timing.html)。

### D.5 VRR、延迟 vs 吞吐
- **VRR**：显示器刷新率随内容变，本项目**拿不到也不需要知道**它。FIFO 在未知刷新率下可能被按真实刷新节流、也可能等价 immediate；因此不要把 `VK_GOOGLE_display_timing`/`VK_EXT_present_timing` 给出的目标时间当作「刷新周期」去对齐，只把它当作「上屏时间的观测值」〔厂商文档/经验〕。
- **延迟 vs 吞吐**：多帧 in-flight（2~3）提高吞吐，但每多一帧就多一个帧间隔的延迟。本项目**不设帧率上限、跑满即目标**；要压的是**排队与阻塞**，不是「贴住刷新率」。判据用：GPU busy 占比、`vkQueuePresentKHR` 阻塞时长、`vkQueueSubmit` 耗时、在途帧/队列堆积深度。
- **功耗只作背景科普，不作决策依据**：满负载会增加功耗与发热，极端情况下触发硬件降频——这是**硬件风险提示**，不构成限帧理由。本项目不因功耗做任何限帧/降载；若真观察到降频，按「性能回归」排查（温度墙/驱动限流），而不是改帧率策略。
- **帧生成（FSR3）的特殊性**：插帧要求**帧间隔可预测**。MAILBOX 的丢帧、`FIFO_RELAXED` 的抢跑都会让插帧错拍——这与本项目 `present()` 对 `SUBOPTIMAL` 选择「不重建」是同类权衡（`VulkanPresenter.cpp:819-899` 注释记录了 gapP50 26 ms / 均值 52 ms 的双峰）。

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

### D.6 把 present 放到关键路径之外：可行做法与风险
| 做法 | 机制 | 代价 | 风险 | 适用 |
|---|---|---|---|---|
| **延迟 present**（本项目） | 记录 pending，下次 acquire 前 flush | 最多 +1 个帧间隔（按实测帧时折算；60 Hz 时约 16.7 ms，本项目不假设刷新率） | 依赖「这段窗口内没有其他线程提交到同一队列」 | 单线程帧循环、想省一次同步 |
| **独立 present 队列** | 同族第二个 queue + semaphore 交接 | 一次额外信号量跳变 | 同族才免费；跨族要 ownership transfer | 有真正的多队列硬件（独显） |
| **present_wait 独立线程** | 线程 A 提交，线程 B `vkWaitForPresentKHR` | 一线程 | 阻塞调用 + 扩展可用性 | 需要在途帧上限 / 上屏反馈时 |
| **present 放渲染线程末尾** | `endFrame` 后立刻 present | 零额外延迟 | 与 QRhi 的提交必须同线程 | **最优解**（若能保证线程模型） |

**结论**：延迟 present 是「线程安全换一个帧间隔」的交易。如果本项目的 `present()` 与 QRhi 的 `endOffscreenFrame()` 本来就在同一线程，那么**没有理由延迟**——直接 present 可省掉最多一个帧间隔。pacing 的目标是**最小化排队与阻塞**，不是把帧对齐到某个刷新周期（刷新率未知）。

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

---

## E. 平台 WSI
### E.0 该做 / 别做
- **该做**：按 `VK_KHR_surface` 的实现（xcb/xlib/wayland）分别验证 present mode 集合；在 Wayland 上默认 FIFO；混合显卡机器上**显式确认应用跑在哪块 GPU**。
- **别做**：把 X11 的 MAILBOX 经验照搬到 Wayland；假设 compositor 一定 direct scanout。

### E.1 X11 vs Wayland
| 维度 | X11（xcb/xlib） | Wayland |
|---|---|---|
| 呈现路径 | DRI3/Present；有 compositor 时可能 flip 或复制；无 compositor/全屏时可 direct scanout | client 提交 dmabuf（带 modifier），compositor 决定是否 direct scanout |
| direct scanout 条件 | 全屏、无遮挡、格式匹配 | 全屏、不透明、format/modifier 匹配、无 transform/缩放、无 overlay |
| compositor 复制 | 有 compositor 时可能发生 | **默认发生**（除非满足 scanout 条件） |
| MAILBOX 可用性 | 一般可用（Present 扩展支持 IMMEDIATE/MAILBOX） | **通常不可用**（协议层只有 frame callback 驱动的 FIFO 语义）〔社区经验〕〔未验证〕 |
| VRR | 依赖驱动/X11 Present 扩展 | 依赖 compositor 支持 |

**本机情况（实测）**：`XDG_SESSION_TYPE=wayland`、`WAYLAND_DISPLAY=wayland-1`、同时 `DISPLAY=:0`（XWayland）。若 Qt 走 `xcb` 平台插件，则应用实际是 **XWayland 客户端**——多一层 compositor 拷贝、present mode 能力受限，且 `VK_LAYER_FROG_gamescope_wsi_x86_64` 这类层可能介入。**该做**：`QT_QPA_PLATFORM` 明确选 `wayland` 或 `xcb` 各测一遍，用 `vulkaninfo` 看两个 surface 的 present mode 差异。

### E.2 Windows DWM / MPO
〔厂商文档〕[Microsoft: DXGI flip model](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/for-best-performance--use-dxgi-flip-model)：

- DWM 是 Windows 桌面合成器；flip model 与 DWM **共享内容**，把拷贝降到最低。
- 三条路径：Composed / DirectFlip / DirectFlip with MPO。**MPO** 由 DWM 预留专用硬件 scanout plane，直接扫描输出并可在屏幕子区域做拉伸/alpha 混合。
- Independent Flip 下配合 `DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT`："you can get down to 1 frame of latency on recent versions of Windows, with graceful fallback to the minimum possible when composed"。
- 验证工具：**PresentMon** 可以看到实际走了哪条路径。
- 对 Vulkan 的映射：`VK_KHR_present_wait`/`VK_EXT_present_timing` 是跨平台对应物；Windows 上 `VK_KHR_win32_surface` 的 present mode 集合通常包含 MAILBOX。

### E.3 混合显卡：surface 在 iGPU、渲染在 dGPU（或反之）
**机制**：`VkSurfaceKHR` 绑定在某块 GPU 的 `VkInstance`/`VkPhysicalDevice` 上；若渲染设备与 surface 所在设备不是同一块，每帧都要**跨设备拷贝**（PCIe，全屏 1440p RGBA8 ≈ 14.7 MB/帧，60 fps ≈ 0.9 GB/s）并额外同步〔经验/量级〕。

**本机（实测）**：Intel Iris Xe（`00:02.0`）+ NVIDIA RTX 3050 Mobile（`01:00.0`）→ **混合显卡**。Wayland compositor 通常跑在 iGPU 上。若应用被 `DRI_PRIME=1`/`__NV_PRIME_RENDER_OFFLOAD` 拉到 dGPU 渲染，而 surface 在 iGPU，则每帧多一次跨设备拷贝 + 额外延迟。

**该做**：

- 明确选择：**iGPU 渲染 + iGPU 呈现**（省一次跨设备拷贝与 PCIe 带宽；核显性能对音乐可视化通常够，本项目不按功耗取舍）或 **dGPU 渲染 + dGPU 呈现**（compositor 也在 dGPU 时才成立）。
- 用 `vkGetPhysicalDeviceSurfaceSupportKHR` + `vkGetPhysicalDeviceSurfaceCapabilitiesKHR` 在**每块** GPU 上查 surface 支持，别假设。
- 在日志里打印选中的 `deviceName` + `deviceType` + 是否 `VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU`。

**风险**：驱动可能"自动"做跨设备 present（NVIDIA Optimus / `VK_LAYER_NV_optimus`），此时你看到的是"低 fps + 高延迟"但找不到原因。

---

## F. 反模式清单 + 如何验证你确实改对了
### F.1 反模式（按危害排序）
| # | 反模式 | 为什么错 | 正确做法 |
|---|---|---|---|
| 1 | 帧循环里 `vkDeviceWaitIdle`/`vkQueueWaitIdle` | 抽干流水线，CPU/GPU 串行 | 等 fence；只在重建/销毁时 idle |
| 2 | acquire 信号量用 `ALL_COMMANDS`/`COLOR_ATTACHMENT_OUTPUT` 但不核对首访阶段 | 可能越过 presentation engine 的所有权边界 | 保证首访是 color attachment，或自己控制提交 |
| 3 | `ALL_COMMANDS → ALL_COMMANDS` 满屏 barrier | GPU 气泡头号来源 | 精确 stage/access mask（sync2） |
| 4 | 每帧多次 `COLOR_ATTACHMENT_OPTIMAL ↔ SHADER_READ_ONLY` | render cache flush + AUX 解析 | 合并 pass / input attachment / local read |
| 5 | render pass 中间插全局 barrier | TBR 上迫使 split pass，丢 tile memory | 转换放 pass 边界 |
| 6 | 用 `vkCmdResolveImage` 做 MSAA 解析 | 强制 round-trip 到主存 | render pass 的 resolve attachment |
| 7 | 每帧新建信号量/fence | 驱动对象管理成本 + 泄漏 | 按槽/按 image 预分配 |
| 8 | swapchain 信号量按"帧"分配 | 违反信号量复用规则 | 按 image index 分配 |
| 9 | 假设 `imageCount == minImageCount` | 实现可能给更多 | 读回真实数量 |
| 10 | `preTransform`/`compositeAlpha` 硬编码 | VUID 违例或走慢路径 | 从 capabilities 里取 |
| 11 | present 的 `pResults` 不检查 | 丢 `OUT_OF_DATE`/`SUBOPTIMAL` 信号 | 至少检查，按策略处理 |
| 12 | 把 `VK_EXT_low_latency` 当存在 | 扩展不存在 | 用 `VK_NV_low_latency2` 或 present_timing |
| 13 | 为省功耗 / 避免降频而限帧、降负载 | 本项目不关心功耗，限帧直接砍吞吐 | 不设上限、跑满即目标；降频按性能回归排查 |
| 14 | 用「fps 是否贴住刷新率」判断瓶颈 | 刷新率未知，该判据不成立 | 用 GPU busy、present 阻塞时长、submit 耗时、队列堆积深度 |
| 15 | 假设「关掉 vsync 就一定更快」/「开 vsync 就是 60」 | 未知刷新率下 FIFO 可能等价 immediate，也可能被节流 | 探测并记录实际模式 + 实测帧间隔 |

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

### F.2 如何验证你确实改对了
**必做的四步**：

1. **Synchronization Validation**：`VK_LAYER_KHRONOS_validation` 打开 `validate_sync`，跑完整帧流程（含 resize、丢帧、最小化）。它能按 stage mask 建模 semaphore wait，直接报 `SYNC-HAZARD-*`〔厂商文档〕[Khronos blog: sync validation](https://www.khronos.org/blog/a-guide-to-vulkan-synchronization-validation)。**这是唯一能自动发现 A.2 那类问题的工具。**
2. **Best Practices 层**：`VK_LAYER_KHRONOS_validation` 的 best practices 会提示 "use of ALL_COMMANDS"、"image layout transition"、"wait idle" 等。
3. **抓帧**：RenderDoc 看每个 barrier 的 src/dst stage 与 layout；确认没有"每帧 N 次全屏转换"。
4. **时间线**：Nsight Systems（CPU-GPU 同步 + **command submission overhead**）或 AMD RGP（GPU 时间线 + hardware-level stalls）；用 `VkDebugUtilsLabelEXT` 给每个阶段打标签，否则时间线上全是匿名提交〔厂商文档〕[Profiling](https://docs.vulkan.org/guide/latest/profiling.html)。

**必须记录的可观测指标**（改前/改后各跑 60 s）：

| 指标 | 采集方式 | 期望变化 |
|---|---|---|
| CPU 帧时间（含 submit） | 项目自带 `FrameProfiler`（`gapCPU` 等字段） | 下降或不变 |
| GPU 空闲气泡 | RGP/Nsight 时间线 | 减少 |
| present 间隔抖动（p50/p99） | 自建 timestamp + `VK_KHR_present_id` | p99 收敛 |
| acquire 阻塞时间 | `vkAcquireNextImageKHR` 前后计时 | < 1 ms |
| swapchain image 复用间隔 | 记录 acquire 到的 index 序列 | 无"同一 index 连续两帧" |
| 退化路径触发次数 | present 里 `deviceWaitIdle` 计数 | **必须为 0** |
| GPU busy 占比 | GPU timestamp query / RGP / Nsight | 上升（不设上限，跑满即目标） |
| `vkQueueSubmit` CPU 耗时 p50/p99 | 自计时包住调用 | 下降 |
| `vkQueuePresentKHR` 阻塞时长 p50/p99 | 自计时包住调用 | 下降 |
| 在途帧 / 队列堆积深度 | 计数器：in-flight 槽数、已提交未 present 数 | 不堆积、无单调增长 |

**判据纪律**：**不要**用「fps 与刷新率的关系」判断瓶颈——刷新率未知，该判据不成立。上表后四项 + GPU busy 占比才是判据。

**工具纪律**〔实测/环境〕：本机装了 `VK_LAYER_LSFGVK_frame_generation`、`VK_LAYER_MAKO_*`、`VK_LAYER_MESA_anti_lag`、`VK_LAYER_FROG_gamescope_wsi`、`VK_LAYER_NV_present`、`MANGOHUD` 等隐式层，它们会拦截/改写 present 与帧生成。**测 present 时序时必须用 `VK_LOADER_LAYERS_DISABLE=~all~...` 或 `VK_INSTANCE_LAYERS` 精确控制**，否则数据不可信。

---

## G. 专项评估：本项目的「空提交 + 延迟 present + 每图信号量」
### G.1 设计还原
```
帧 N:
  acquire():
    [若 slotInUse] 等 slotFence[slot] + reset
    [若 submitWaitPending] 发 recover 空提交(只等不信号) + 等 slotFence
    vkAcquireNextImageKHR(semaphore = acquireSemaphore[slot], fence = NULL)
    空提交: wait acquireSemaphore[slot] @ALL_COMMANDS -> signal submitWaitSemaphore[slot], fence = slotFence[slot]
  installSubmitParams(): wait submitWaitSemaphore[slot] / signal renderDone[imageIndex]
  [Qt/QRhi 提交: semaphoresWaitMasks = COLOR_ATTACHMENT_OUTPUT]
  present(): 直接 vkQueuePresentKHR(wait renderDone[imageIndex])，与 Qt 提交同线程
           （VulkanPresentationBackend.cpp:143-155：endOffscreenFrame() 之后立刻 present()）
 注：presentDeferred()/flushDeferredPresent() 是防御性 API，当前**无外部调用点**
     （定义在 VulkanPresenter.cpp:902，:631/:664 仅在 acquire 里防御性 flush）
```

### G.2 正确性边界
| 边界 | 状态 | 说明 |
|---|---|---|
| 空提交合法 | ✅ | `vkQueueSubmit` 描述 "semaphores **or** command buffers"〔规范〕 |
| fence 无信号 | ✅ | `flags = 0`，符合 00063〔规范〕 |
| 信号量 1:1 配对 | ✅（有 recover 兜底） | `submitWaitPending` 处理 Qt 不提交的帧 |
| swapchain 信号量按 image | ✅ | `renderDone[imageIndex]`，符合 Khronos 建议 |
| **首访阶段 vs wait stage** | ⚠️ **风险** | QRhi 固定 COLOR_ATTACHMENT_OUTPUT；若首访是 TRANSFER/采样 → 数据竞争 |
| **VkQueue 外部同步** | ⚠️ **风险** | present 与 QRhi 提交来自不同线程时，仅靠"时间错开"不构成同步〔规范〕 |
| `pResults` 未检查 | ⚠️ 次要 | 丢 `OUT_OF_DATE`/`SUBOPTIMAL`；单 swapchain 下影响小，但 `SUBOPTIMAL` 被静默吞掉 |
| acquire TIMEOUT 分支 | ✅ | 提前 return，不提交等待未 signal 的信号量 |

**最关键的两条风险**：

1. **阶段错配**（见 A.2）：如果 FSR3 的合成输出是通过 TRANSFER 写进 swapchain image，那 Qt 提交在 COLOR_ATTACHMENT_OUTPUT 的等待**保护不到**这个 TRANSFER 写。修复方式二选一：(a) 改成渲染直写 swapchain；(b) 把"blit 到 swapchain"这一步从 Qt 的 command buffer 里拿出来，自己提交并显式 `waitSemaphore = acquireSemaphore` + `stage = TRANSFER`。
2. **队列外部同步（潜在）**：当前 `present()` 与 Qt 提交同线程，所以暂不触发；一旦改成 `presentDeferred()`/跨线程，`vkQueuePresentKHR` 与 `vkQueueSubmit` 对同一 `VkQueue` 的 host 访问必须**外部同步**（原文："Host access to queue must be externally synchronized if it was not created with `VK_DEVICE_QUEUE_CREATE_INTERNALLY_SYNCHRONIZED_BIT_KHR`"〔规范〕[vkQueuePresentKHR](https://docs.vulkan.org/refpages/latest/refpages/source/vkQueuePresentKHR.html)）。"present 推迟到下次 acquire 之前"只是**时间上的错开**，不是互斥原语。若 Qt 的渲染线程在这段窗口内提交，就是 UB（表现：偶发 device lost / 画面撕裂 / 花屏）。

### G.3 CPU/GPU 代价
| 项 | 代价 | 说明 |
|---|---|---|
| 空提交 | 每帧 +1 次 submit（µs 级 CPU）〔经验〕 | 与"把 acquire 信号量直接注入 QRhi wait 列表"相比是纯开销 |
| 信号量跳变 | +1 个 GPU 侧依赖节点 | 对 16.7 ms 帧可忽略，对 1 ms 帧开始可见 |
| 延迟 present | 0（**当前未启用**） | `presentDeferred()` 无外部调用点；`endFrame` 里 present 紧跟 `endOffscreenFrame()`。若将来改成 deferred，才会引入最多 1 帧延迟 |
| recover 路径 | 偶发 CPU 硬阻塞 | 只在丢帧时触发 |
| `deviceWaitIdle` 退化 | 单次 50 ms 级（代码注释） | 必须计 0 容忍 |

**关键判断**：这个设计**在 CPU 成本上是负收益**（多一次 submit），**在延迟上也是负收益**（多一帧），它换到的唯一东西是"每槽一个可观测 fence"+"Qt 不提交时的信号量兜底"。如果这两点能通过别的方式获得（例如直接读 QRhi 的 fence，或保证 Qt 一定提交），这个设计可以简化掉。

### G.4 替代方案对比
| 方案 | 机制 | 收益 | 风险/代价 | 建议 |
|---|---|---|---|---|
| **A. 现状**（空提交 + 延迟 present） | 见 G.1 | fence 可观测、丢帧兜底 | +1 submit、+1 帧延迟、队列同步靠时序 | 保留但**先修 A.2 与 G.2 的两条风险** |
| **B. 直接注入 acquire 信号量** | 把 `acquireSemaphore[slot]` 直接放进 `QRhiVulkanQueueSubmitParams::waitSemaphores` | 省掉空提交与一次信号量跳变 | 仍是 COLOR_ATTACHMENT_OUTPUT；Qt 不提交时该信号量无人消费（需要 recover） | 若阶段问题能解决，**这是最简形态** |
| **C. present 不延迟** | `present()` 直接在渲染线程末尾调 `vkQueuePresentKHR` | 省掉最多 1 帧延迟 | 要求与 QRhi 提交同线程 | **现状已经是这个形态**（`endFrame` 内），无需改动；只需防止有人改成 deferred |
| **D. 独立 present 队列** | 同族第二个 queue + semaphore 交接 | present 不阻塞渲染提交 | 多一次信号量跳变；跨族要 ownership transfer；不省延迟 | 收益小，除非 present 真的阻塞 |
| **E. 时间线信号量替换每图二进制** | 用 counter 表达"第 N 帧完成" | 省 CPU 侧查询/等待 | **不能用于 present 的 pWaitSemaphores**（VUID-03267）〔规范〕 | 只用于 GPU-GPU 侧，present 仍需二进制桥 |
| **F. `VK_KHR_present_wait`** | 等"某一帧真正上屏" | 精确帧节奏、可替代 acquire 隐式证明 | 阻塞调用、Linux 上 opt-in、Wayland 支持晚 | 可用则**配合 C 使用**，不要单独依赖 |

### G.5 核显 + Wayland/X11 下的额外风险
1. **MAILBOX 与 FIFO 的可用性都不能假设**：Wayland 下 Mesa 的 WSI 长期用 mailbox 风格实现（2018 年实测 `minImageCount` 报 4），协议级 FIFO 直到 2024-11 的 Mesa 24.3 才通过 `wp_fifo` 补上；而 NVIDIA 的 Wayland 驱动直接报 `present_mode=fifo`。若代码默认 `MAILBOX` 却没查 `vkGetPhysicalDeviceSurfacePresentModesKHR`，可能创建失败、也可能静默落到别的模式。
2. **compositor 拷贝**：非全屏/不透明时，compositor 每帧多一次全屏拷贝（1440p RGBA8 ≈ 14.7 MB/帧）→ 核显带宽吃紧。
3. **XWayland 双层**：若 Qt 走 xcb，present 实际经 XWayland → compositor，多一层拷贝且 present mode 能力受限。
4. **帧生成层冲突**：`VK_LAYER_LSFGVK_frame_generation`（本机已装）会自己插入 present 逻辑，与本项目的 `renderDone`/`presentDeferred` 可能双重管理 → 必须用 `VK_LOADER_LAYERS_DISABLE` 做对照实验。
5. **混合显卡**：Iris Xe + RTX 3050 Mobile，见 E.3。
6. **刷新率未知**：compositor 可能按真实刷新节流、也可能完全不节流；核显上真正可测的是 present 阻塞时长与 GPU busy 占比。**不要用「帧率异常」反推 compositor 行为**，也不要据此调 vsync/帧率策略。

> 前提修订：本项目不关心功耗；刷新率未知，按无穷刷新假设（m00232–m00233）。

### G.6 建议的最小改动序列（按性价比排序）
1. **修阶段错配**（A.2 / G.2-1）：确认 swapchain image 的首访阶段；若是 TRANSFER，改成渲染直写或自管那一步提交。→ 正确性，零性能风险。
2. **守住 present 不延迟**（C）：现状是 `endFrame` 内 `endOffscreenFrame()` 后立刻 `present()`，保持这样即可；若有人改用 `presentDeferred()`（跨线程），必须同时加队列互斥或串行化，否则违反对 `VkQueue` 的外部同步要求。
3. **给退化路径加计数/告警**（A.5）：`paramsInstalled == false` 时 `deviceWaitIdle` 的路径必须可观测。
4. **收窄 mask**（B.3）：把 `ALL_COMMANDS`/`ALL_GRAPHICS` 换成 sync2 精确 mask，包括空提交里那个 `ALL_COMMANDS`。
5. **评估 `VK_KHR_present_wait`**（D.3）：可用则接进来做 pacing，不可用则保持现状。

---

## 参考来源
**Khronos / Vulkan 官方**

1. https://docs.vulkan.org/refpages/latest/refpages/source/vkQueueSubmit.html — `vkQueueSubmit` 参考页：空提交合法性、fence/信号量 VUID（00063/00064/00067/00068/03238）。
2. https://docs.vulkan.org/refpages/latest/refpages/source/vkQueuePresentKHR.html — present 参考页：pWaitSemaphores 必须 BINARY（03267）、队列外部同步要求、image 所有权与返回码。
3. https://docs.vulkan.org/refpages/latest/refpages/source/VkSwapchainCreateInfoKHR.html — minImageCount/preTransform/compositeAlpha/presentMode 的语义与 VUID。
4. https://docs.vulkan.org/refpages/latest/refpages/source/VkPresentModeKHR.html — 五种 present mode 的逐字语义（含 FIFO_LATEST_READY）。
5. https://docs.vulkan.org/refpages/latest/refpages/source/VkSharingMode.html — EXCLUSIVE/CONCURRENT 语义与 CONCURRENT 的性能警告。
6. https://docs.vulkan.org/refpages/latest/refpages/source/VK_KHR_timeline_semaphore.html — 时间线信号量的五种操作。
7. https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_host_image_copy.html — host 直拷 image 的语义与命令。
8. https://docs.vulkan.org/refpages/latest/refpages/source/VK_KHR_present_wait.html — present_wait 的设计目的与 Issue 讨论。
9. https://docs.vulkan.org/refpages/latest/refpages/source/VK_NV_low_latency2.html — NV 低延迟 2 的命令/结构（Not ratified）。
10. https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html — Khronos 指南：swapchain 信号量必须按 image 复用。
11. https://docs.vulkan.org/guide/latest/tile_based_rendering_best_practices.html — TBR 最佳实践：load/store、避免全局依赖、避免 ALL_GRAPHICS barrier。
12. https://docs.vulkan.org/guide/latest/extensions/VK_KHR_synchronization2.html — sync2 的 stage/access mask 迁移写法与 64 位 mask。
13. https://docs.vulkan.org/guide/latest/profiling.html — GPU 气泡的两大根因（受限 barrier、CPU-GPU 同步）与工具矩阵。
14. https://docs.vulkan.org/samples/latest/samples/performance/wait_idle/README.html — 官方 sample：wait_idle → fence 在 Mali-G76 上 72 ms → 56 ms/帧。
15. https://www.khronos.org/blog/a-guide-to-vulkan-synchronization-validation — synchronization validation 的使用与原理。