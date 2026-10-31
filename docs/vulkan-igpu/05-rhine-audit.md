# 本项目（RhineRender）Vulkan 呈现链路现状审计

> 本文只谈**Vulkan 链路本身**：提交、同步、呈现、管线、内存与可观测性。不涉及场景/着色器/美术。
> 依据：`Qt/src/fg/VulkanPresenter.cpp`、`Qt/src/render/VulkanPresentationBackend.cpp`、`Qt/src/render/PresentationShell.cpp`、`Qt/src/fg/FgBackend.cpp`（分支 `perf/lts`）。
> 所有「收益量级」都是待实测假设，不是结论；每条都给了验证方法。
>
> **前提（m00232–m00233）**：本项目**不关心功耗/发热/降频**；**运行期无法获取屏幕刷新率**，一律按「刷新率未知/无穷」处理。因此本文不出现「帧率上限对齐刷新率」「为省电限帧」类建议；凡涉及 present 节奏的结论，都以「减少排队与阻塞」为目标，而不是「对齐某个刷新周期」。

## 0. 结论摘要

现有呈现链路已经比大多数自研壳子干净：自持交换链、每图像一个 `renderDone` 信号量、热路径没有 `vkDeviceWaitIdle`、present 不延迟、全屏单 pass 直接写交换链、重建走事务式路径。**不要为了"更 Vulkan"把这些拆掉重写。**

真正还剩的空间按性价比排序：

| # | 事项 | 预期 | 成本 | 优先级 |
|---|---|---|---|---|
| 1 | 补 present 可观测性（`present_id` + `present_wait2`、GPU 帧时间、submit 耗时） | 让后面所有优化可判定 | 小 | P0 |
| 2 | FG 上下文重建 + FFX 无管线缓存 | 消除 resize/切换时的编译卡顿（毫秒级 × N 条管线） | 中 | P1 |
| 3 | present mode 实际拿到什么、有没有被节流（刷新率未知，无法靠 fps 判断） | 让「present 是否在阻塞」可观测，而不是假设关掉 vsync 就更快 | 小 | P1 |
| 4 | 每帧一次「空提交」 | 每帧省一次 submit + fence | 中 | P2 |
| 5 | 交换链图像数做成可配置，**默认保留 6**（吞吐优先） | 保住那 ~5% 吞吐（335 vs 318 fps）；代价是多 ~20MB 与数帧延迟 | 小 | P2 |
| 6 | 屏障语义现代化（BOTTOM_OF_PIPE → NONE） | 主要是校验层干净，帧率收益接近 0 | 小 | P3 |

---

## 1. 已经做对的（别改坏）

1. **自己持有 `VkSwapchainKHR`，绕开 SDK 的 present 回调**（`VulkanPresenter.h:12-32`）——FG 与 Qt 抢同一个交换链是必踩的坑，现在的做法是对的。
2. **每张交换链图像一个 `renderDone` 信号量**（`VulkanPresenter.cpp:80-82`）。"这张图能被重新 acquire"本身就证明上次 present 消费了它的信号量，不需要额外的回收围栏。这是 present 侧最省的正确拓扑。
3. **acquire 与渲染提交之间用信号量串起来，不用 `vkQueueWaitIdle`**（`VulkanPresenter.cpp:746-764`、`784-817`）。
4. **present 就在 `endFrame()` 里同步发出，没有推迟**（`VulkanPresentationBackend.cpp:143-155`）。`presentDeferred()` 目前没有调用点，别启用它——那会平白多一帧延迟。
5. **重建是事务式的**：新交换链/视图/信号量先在局部变量里建好，最后一步替换（`VulkanPresenter.cpp:302-397`）。失败时旧状态仍可用。
6. **`VK_SUBOPTIMAL_KHR` 不重建**（`VulkanPresenter.cpp:881-893`）。为 suboptimal 重建要 `deviceWaitIdle` + 重建全部 image/view/semaphore + 全部纹理与管线，代价远大于收益。
7. **全屏单 pass 直接写交换链图像**（`PresentationShell.cpp` 里 `cb->beginPass(target,...)` + `cb->draw(3)`），没有额外的全屏 blit/拷贝。
8. **present mode 会写进性能面板**（`VulkanPresenter.cpp:940-957`），这比多数项目强——帧率上限主要由它决定，必须可见。

---

## 2. 逐项审计

### A. 每帧多一次「空提交」

**位置**：`VulkanPresenter.cpp:746-766`。`vkAcquireNextImageKHR` 拿到图后，立刻发一个 `commandBufferCount=0` 的 `vkQueueSubmit`：等 `acquireSemaphore[slot]`、发 `submitWaitSemaphore[slot]`、挂 `slotFence[slot]`。

**它在解决什么**：`acquireSemaphore` 是每帧槽复用的一张二进制信号量，但"渲染提交到底有没有消费它"在 Vulkan 里**不可查询**；空提交把这件事变成一个可等待的 fence。所以这不是多余代码，是当前拓扑下最简单正确的解法。

**成本**：每帧多一次 `vkQueueSubmit` + 一次 fence 等待。Linux 上每次 submit 对应一次 DRM 提交 ioctl，Mesa 前端还有命令缓冲校验/序列化开销，量级是「几十微秒/次」〔经验，需实测〕。300fps 时约 300 次/秒 ⇒ CPU 侧 1%~2% 量级。GPU 侧因为空提交没有命令，理论上只多一次调度事件。

**能不能去掉**：
- 用 `VK_KHR_present_id` + `VK_KHR_present_wait2`（`vkWaitForPresent2KHR`；旧的 `VK_KHR_present_wait` 已被它取代，新代码别再按旧扩展设计，见 `04-tools-cases.md` D.3）：present 完成即可证明 `acquireSemaphore` 已被消费。链变成 acquire → 渲染提交直接等 `acquireSemaphore[slot]` → present 等 `renderDone[image]` 带 presentId → 复用槽前查 presentId 是否完成。**一次 submit 都不用加**。
- 用时间线信号量：QRhi 的 `QRhiVulkanQueueSubmitParams` 只暴露二进制信号量数组（没有 `VkTimelineSemaphoreSubmitInfo` 的 value 字段），**从 Qt 这条提交路径无法 signal 时间线信号量**，所以这条路当前不可行。
- 直接把 `acquireSemaphore[slot]` 交给 QRhi 等：可行，但你 afterward 没有任何手段知道它何时被消费 ⇒ 复用会违反二进制信号量语义。除非同时上 present_wait。

**结论**：P2。先量 CPU 侧提交耗时占比（见 G），低于 5% 就别动。若要动，先上 present_wait，再一次性删掉空提交与 fence。

**验证**：`apitrace`/`RenderDoc` 数每帧 submit 次数；在 `vkQueueSubmit` 前后加 `QElapsedTimer` 累计。

---

### B. present mode 在 Wayland / 无 vsync 下的退化

**位置**：`VulkanPresenter.cpp:512-534`。`vsync=false` 时优先 `MAILBOX`，没有则 `IMMEDIATE`，否则留在 `FIFO`。

**问题**：Wayland 下 present mode 的支持矩阵依驱动/合成器而变，而且历史上有反复：Mesa 的 Wayland WSI 长期用 mailbox 风格实现（2018 年实测 `minImageCount` 报 4，FIFO 下只用 3 张），协议级 FIFO 直到 2024-11 的 Mesa 24.3 才通过 `wp_fifo` 补上；NVIDIA 的 Wayland 驱动则一直直接报 `present_mode=fifo`。**方向不确定，唯一可靠做法是探测**：用 `vkGetPhysicalDeviceSurfacePresentModesKHR` 决定请求谁，并记录"请求了谁 / 实际拿到谁 / 谁不可用"。现在只能看到最终模式名，看不到这条链路。

**建议**：
1. 退化时打一条 `qInfo`，把 `vkGetPhysicalDeviceSurfacePresentModesKHR` 的完整列表打出来（只在首次或 `RHINE_FG_DIAG` 下）。
2. 考虑 `VK_KHR_present_mode_fifo_latest_ready`（Vulkan 1.4 核心 / 早期 `VK_EXT_present_mode_fifo_latest_ready`）：语义是"垂直同步但不排队"，延迟接近 mailbox、无撕裂，是 Wayland 这类只有 FIFO 的平台上最实用的第三选项。
3. `vsync=false` 且只有 FIFO 时，把 `FIFO_RELAXED` 作为第二选择（允许撕裂，且不保证按固定节奏排队）。**但注意：刷新率未知时，「FIFO 会不会真的节流」也无法从 fps 反推**——必须测 present 的阻塞时长与帧间隔分布。
4. 若要用上述任何扩展：实例级扩展走 `QVulkanInstance::setExtensions`，设备级走 `QRhiVulkanInitParams::deviceExtensions`（`VulkanPresentationBackend.cpp:211` 现在只请求了 `VK_KHR_swapchain`）。**注意：presenter 不创建设备，任何设备扩展都必须在 QRhi 创建时申请**，否则 `vkGetDeviceProcAddr` 返回空——这一点代码里已有同类注释（`VulkanPresenter.cpp:193-196`），扩展开关要加在同一处。

**验证**：在 X11 / Wayland / Windows 三平台打印实际 present mode；用 `vkcube --present_mode` 对照。

---

### C. 缺 present 可观测性 ⇒ 延迟与节奏无法判定

现在没有 `present_id`/`present_wait2`，因此拿不到"这一帧什么时候真正上屏"。后果：
- 无法测端到端延迟（input→photon），FG 的收益/代价说不清；
- 无法判断是 GPU 慢、合成器慢、还是 present 排队；
- 无法做自适应 pacing（例如 FG 打开后按 display 节奏限帧）。

**建议**：启用 `VK_KHR_present_id` + `VK_KHR_present_wait2`（若平台不支持则降级为无操作；`present_wait2` 额外提供超时与更宽松的 swapchain 创建约束），每次 present 带自增 id，用一个专用线程或每 N 帧 `vkWaitForPresent2KHR` 采样完成时刻，得到 `presentLatency = t_done - t_submit`。这条数据是后面所有"要不要减图像数/要不要限帧"决策的依据。

**风险**：`vkWaitForPresentKHR` 会阻塞，绝不能在渲染线程调用；用 1 个采样线程 + 环形缓冲。

---

### D. FG 上下文重建 + FFX 完全没有管线缓存

**位置**：`FgBackend::resize()`（`FgBackend.cpp:565-625`）——只要 `renderSize/displaySize/colorFormat` 有一个变了，就 `vkDeviceWaitIdle` + `release()` + 全量重建 FG 上下文。窗口拖拽、DPI 变化、进出全屏都会触发。

**同时**：随仓库 vendor 的 FFX Vulkan 后端**没有任何 `VkPipelineCache`**：
- `FidelityFX-SDK/sdk/src/backends/vk/ffx_vk.cpp` 里 `pipelineCache` 只出现在 breadcrumb 打印中；
- 计算管线创建是 `vkCreateComputePipelines(device, nullptr, ...)`（`ffx_vk.cpp:3642`）；
- 其余管线同样是 `VK_NULL_HANDLE`（`FrameInterpolationSwapchainVK_UiComposition.cpp:358,366`、`FrameInterpolationSwapchainVK_DebugPacing.cpp:325`）。

⇒ 每次 resize 重建，FG 的十几~几十条管线都会重新走一遍创建。**驱动内部缓存（Mesa 的 shader cache、Windows 驱动的磁盘缓存）能吃掉一部分**，但进程内 `VkPipelineCache` 仍是零语义风险的省法，尤其是同一进程内反复 resize。

**建议顺序**：
1. 先量：在 `FgBackend::resize()` 前后打点，记录重建总耗时；用 RenderDoc 抓一次 resize，看 `vkCreate*Pipelines` 累计耗时。
2. 若无痛（<20ms），不动。
3. 若有痛：在 FgBackend 里建一个**跨重建存活**的 `VkPipelineCache`，给 vendored FFX 打一个最小补丁，把 `ffx_vk.cpp` 里所有 `vkCreate*Pipelines` 的 cache 参数从 `nullptr`/`VK_NULL_HANDLE` 改成后端上下文里的 cache 句柄；进程退出时把 cache 数据落盘，key 用 `VkPhysicalDeviceProperties::pipelineCacheUUID` + 驱动版本，加载前校验 UUID。
4. 实现位置：FFX 的公开 `VkDeviceContext`（`FidelityFX-SDK/sdk/include/FidelityFX/host/backends/vk/ffx_vk.h:89-93`）只有 `vkDevice/vkPhysicalDevice/vkDeviceProcAddr` 三个字段，**没有** cache 槽位；内部 `BackendContext_VK`（`ffx_vk.cpp:77-273`）才是要加字段的地方。最小补丁 = 给 `BackendContext_VK` 加 `VkPipelineCache pipelineCache`，并在 `ffx_vk.cpp:3642` 的 `vkCreateComputePipelines` 处传入（FG 的 pass 全是 compute 管线，`ffx_vk.cpp` 里没有 graphics 管线创建）。

**风险**：vendored 代码改动需要在升级 SDK 时重放；cache 失效必须能回退（UUID 不匹配就丢弃）。

---

### E. 交换链图像数

**位置**：`VulkanPresenter.cpp:255-268`。`minImageCount + 1`；非 FIFO 时抬到 6（`RHINE_FG_SWAP_IMAGES` 可覆盖）。代码注释里已有实测：3 张 318fps vs 6 张 335fps，差约 5%。

**成本**：1262×1370 BGRA8 ≈ 6.9MB/张，6 张 ≈ 41MB 系统内存（核显上是与 CPU 共享的 DRAM），外加合成器的读取带宽。**收益是 318 → 335 fps（约 +5%）**，代价是数帧延迟与 41MB 常驻内存。

**建议**：在「不关心功耗、刷新率未知」的前提下，**吞吐优先，默认保留 6 张**；把「图像数」变成可配置并写进性能面板（现在只有覆盖用的环境变量），让用户能在「更高吞吐」与「更低音画延迟」之间自己选。只有在确实测到音画同步问题时才降到 4——那时用 `present_wait2` 的绝对延迟数据来定，而不是用 fps。

---

### F. 屏障语义

**位置**：`VulkanPresentationBackend.cpp:118-139`，`srcStage=COLOR_ATTACHMENT_OUTPUT`、`dstStage=BOTTOM_OF_PIPE`、`dstAccess=0`、`oldLayout=COLOR_ATTACHMENT_OPTIMAL → PRESENT_SRC_KHR`。

- 功能正确。但 `BOTTOM_OF_PIPE` 在 `VK_KHR_synchronization2` 语义下等价于 `VK_PIPELINE_STAGE_2_NONE`，校验层（best practices）会提示 deprecated。若设备支持 1.3/sync2，改成 `vkCmdPipelineBarrier2` + `dstStageMask = VK_PIPELINE_STAGE_2_NONE` 更规范，**帧率收益约等于 0**，属于整洁度改动，P3。
- 反过来，**不要在 present 之前加 `VK_ACCESS_MEMORY_READ` 之类的"保险"**：那会让驱动等写回，核显上直接吃带宽。

**另一个点**：`target()` 每帧把交换链纹理的 native layout 重置成 `VK_IMAGE_LAYOUT_UNDEFINED`（`VulkanPresentationBackend.cpp:107`）。全屏覆盖时这是**正确且通常更快**的选择（不 load 旧内容、允许驱动重置压缩元数据）。但它依赖"每帧确实全屏覆盖"这个前提——如果将来做局部重绘/脏矩形，这里必须改成保留上一帧布局，否则会花屏。**建议在代码里把这个前提写成断言式注释**（现在没有）。

---

### G. 可观测性埋点（最该先做）

现在只有 `presentMs` 和帧间隔（`PresentationShell.cpp` 附近）。缺的是能区分「Vulkan 链路开销」与「场景开销」的数据：

| 指标 | 怎么埋 | 用途 |
|---|---|---|
| `vkQueueSubmit` CPU 耗时 | 每次 submit 前后 `QElapsedTimer`，滑动平均 | 判断是否 CPU 提交受限（A 的前提） |
| acquire 等待耗时 | `vkAcquireNextImageKHR` 前后 | 判断是否被 present/合成器卡住（B 的依据） |
| present 返回耗时 | 同上 | 驱动/合成器是否有异常阻塞 |
| present 完成延迟 | present_wait（C） | 端到端延迟、图像数取舍 |
| GPU 帧时间 | timestamp query（`vkCmdWriteTimestamp2`）或 `VK_EXT_calibrated_timestamps` 对齐 CPU 时钟 | 判断 GPU 是否真的忙 |
| `deviceWaitIdle` 次数 | 计数器 | 现在只在 fallback/resize，一旦热路径出现就是事故 |

这些加起来不到 100 行，但决定了后面每一项优化是"有效"还是"自我感觉良好"。

---

### H. 设备/实例扩展清单

`VulkanPresentationBackend.cpp:211` 只请求 `VK_KHR_swapchain`。上面 B/C/D 提到的扩展（`present_wait2`、`present_id`、`surface_maintenance1`、`present_mode_fifo_latest_ready`、`swapchain_maintenance1`）都要在这里显式申请，并且要先查 `vkEnumerateDeviceExtensionProperties`。建议做一张"能力探测表"，启动时打印一次（`RHINE_FG_DIAG` 下），而不是散落在各处 if。

---

## 3. 验证计划（建议顺序）

1. **先埋点**（G），跑三种负载：静态画面、动画、FG 开/关。拿到 submit 耗时占比、acquire 等待、present 延迟。
2. **只改一个变量**：present mode 对照（FIFO vs MAILBOX vs IMMEDIATE），确认帧率上限来源。
3. **FG resize 卡顿**：录一次窗口拖拽的帧时间序列，看是否是 D 里的重建尖峰；是则上管线缓存。
4. **图像数 A/B**：3 / 4 / 6 三档 × FG 开/关，同时记录 fps、帧时间 p99、present 延迟。别只看 fps。
5. **空提交**：只有第 1 步证明 submit 占比高才动。

---

## 4. 明确不建议做的

- **多线程命令缓冲录制 / 多队列提交**：本项目每帧只有 1 个全屏 pass + 少量 FG pass，录制时间可忽略，复杂度换不来收益。
- **descriptor buffer / bindless**：pass 数量极少，描述符更新不是瓶颈。
- **为省一次 submit 去 hack 信号量语义**：正确性风险远大于几十微秒。
- **用 `vkDeviceWaitIdle` 换"稳定"**：现在只在 resize/fallback 路径，保持这样。
- **为 suboptimal 重建交换链**：已经做对了，不要"优化"回去。
- **把 present 推迟到下一帧**（`presentDeferred`）：会稳定多一帧延迟，除非做专门的 pacing 实验。

---

## 5. 与分册的对应关系

- 提交/同步/呈现机制 → `01-sync-submit-present.md`
- 管线/描述符/命令缓冲/内存 → `02-pipeline-descriptor-commandbuffer.md`
- 核显带宽/tile/功耗 → `03-igpu-bandwidth.md`
- 工具与测量方法 → `04-tools-cases.md`
