# 06 · 实施记录：Vulkan 链路优化落地与实测（Intel Iris Xe / Mesa ANV）

> 本文记录 `perf/lts` 分支上「Vulkan 链路本身」的优化实施结果：改了什么、为什么这么改、在本机（Intel Iris Xe ADL GT2 + Mesa 26.2.5 + Wayland/niri）上量到什么、以及明确**不做**的项和理由。
> 证据等级沿用全套约定：〔规范〕Vulkan 规范/Khronos ·〔厂商文档〕驱动/厂商文档 ·〔实测〕本机可复现测量（命令附在文末）·〔微基准〕隔离掉业务的独立测量程序。
> 前提同 [README](README.md)：**不关心功耗**、**刷新率按未知处理**，判据是 GPU busy / present 阻塞 / submit 耗时 / 队列深度，不是「fps 贴不贴刷新率」。

---

## 0. 一页结论

| # | 改动 | 状态 | 本机实测 | 代价 |
|---|---|---|---|---|
| WP1 | QRhi 管线缓存落盘（`pipelineCacheData()` / `setPipelineCacheData()` + `EnablePipelineCacheDataSave`） | 已实施 | 缓存文件 138 200 B；二次启动恢复 138 164 B。**启动耗时 3 次对照无显著差异**（无缓存 1.627/1.599/1.729 s，有缓存 1.633/1.667/1.661 s） | 磁盘 138 KB + 恢复 ~0.12 s |
| WP2 | 启动一次性呈现报告 + 每帧「图像复用间隔」指标 | 已实施 | 启动即打印设备/API/驱动/交换链/格式/模式/扩展；复用间隔 2.4~9.4 ms（与刷新周期无关） | 无 |
| WP3 | present 转场 barrier `dstStage` `BOTTOM_OF_PIPE`→`NONE` | **不做** | — | — |
| WP4 | `FIFO_LATEST_READY` 作为 FIFO 的替代 | **不做**（本机驱动不暴露） | `fifo_latest_ready=0` | — |
| WP5 | 去掉每帧「只等不信号」的空提交 | **不做** | 取图仅 0.03~0.1 ms/帧 | — |
| WP6 | FFX（FSR3）计算管线补进程级 `VkPipelineCache` | 已实施 | 微基准：冷建 1.88 ms/条 → 命中 ≈0.001 ms/条（40 条：75 ms → 0.05 ms） | 缓存对象常驻（约 78 KB 量级） |

一句话：**本机能测到的收益集中在「可观测性」和「FSR3 上下文重建」两处**；QRhi 侧管线缓存因为 Qt Quick 自己已经有 QSG 管线缓存、且本机 ANV 的着色器编译本就不贵，落盘收益落在噪声里——但代价≈0，保留。

---

## 1. WP1：QRhi 管线缓存落盘

**问题**：`VulkanPresentationBackend` 里 `QRhi::create(QRhi::Vulkan, &params, {})` 的第三个参数（flags）是空的，即 `QRhi::EnablePipelineCacheDataSave` 没开，自建呈现层的管线缓存每次启动都要重新编译。〔实测〕

**改法**：
- 建 QRhi 时带上 `QRhi::EnablePipelineCacheDataSave`；
- 设备建好后 `setPipelineCacheData(读到的 blob)`，路径是 `AppStorage::cacheDirectory()/shaders/qrhi-pipeline.cache`；
- 前 240 帧上屏成功后写回一次（不是退出时写）：管线在启动阶段就编译完，被 SIGINT/kill 强杀也不至于丢掉这 138 KB 编译成果；
- 恢复成功打一行 `QRhi 管线缓存: 已恢复 <n> 字节 ← <path>`。

**实测**：
- 首次运行（8 s 后 `timeout -s INT` 杀）生成 `~/.cache/RhineMusicDatabase/rhine.music.database/shaders/qrhi-pipeline.cache`，138 200 B；
- 二次运行日志：`QRhi 管线缓存: 已恢复 138164 字节 ← …/qrhi-pipeline.cache`；
- 启动到「呈现层已启动」的 3 组对照（各交替跑，消除单次噪声）：

| 轮次 | 无缓存 | 有缓存 |
|---|---|---|
| 1 | 1.627 s | 1.633 s |
| 2 | 1.599 s | 1.667 s |
| 3 | 1.729 s | 1.661 s |

**结论**：本机**没有可测收益**，差异在噪声内。原因有两条：① Qt Quick 的场景图着色器本来就走 `QSG_RHI` 自己的管线缓存（`main.cpp` 里的 `setPipelineCacheLoadFile/SaveFile`），大头早被它吃掉了；② Mesa ANV 在这个规模上编译不贵。保留的理由：代价只有 138 KB 磁盘与一次读盘，而 Windows 驱动与部分闭源驱动上着色器编译是数百毫秒级，这类平台收益会显现；同时它把「管线缓存」这条路径打通，后续接 `VK_KHR_pipeline_binary` 时不用再改结构。**不建议**把它当成「启动优化」写进发布说明。

---

## 2. WP2：呈现层可观测性

**已加**（启动一次性打印，直接可复制进 issue）：

```
FG present 配置: 设备 Intel(R) Iris(R) Xe Graphics (ADL GT2) · API 1.4.354 · driver 0x6802005
  · 交换链 1262x1370 6 张 · 格式 44 · 颜色空间 0 · 呈现 MAILBOX（可选 MAILBOX/FIFO）
  · 扩展 present_id=1 present_wait=1 fifo_latest_ready=0 maintenance1=1 present_timing=1
```

**每帧指标**新增 `imageReuseMs`（同一张交换链图像两次上屏的平均间隔）。它的用途是把三种情况分开：

| 观察 | 含义 |
|---|---|
| 复用间隔 ≈ 刷新周期 | 合成器/vsync 在限速 |
| 复用间隔远大于刷新周期且稳定 | 渲染或提交跟不上（GPU busy） |
| 复用间隔忽大忽小 | 队列深度不足或存在阻塞点 |

本机静止内容、MAILBOX、6 张图：10 s 上屏 2 700 帧（≈270 fps），复用间隔 2.4~9.4 ms，**与「刷新周期」无关**，说明是 GPU/提交在推进而不是被合成器节流——这正是本项目「刷新率未知」前提下需要的判据。〔实测〕

帧内分解（同一次运行）：取图 0.03~0.1 ms、场景 0.05~0.3 ms、合成 0.03~0.05 ms、上屏 0.00 ms、起始/收尾各 0.05~0.08 ms。

---

## 3. WP6：给 FSR3 补进程级 `VkPipelineCache`

**问题**：FidelityFX SDK 1.1.4 的 Vulkan 后端全仓没有任何 `VkPipelineCache`——`CreatePipelineVK` 里是
`vkCreateComputePipelines(backendContext->device, nullptr, 1, …)`（子模块 `ffx_vk.cpp:3641`）。而 `FgBackend::resize()` 在窗口尺寸或格式变化时会 `vkDeviceWaitIdle` + 整体销毁并重建 FSR3 上下文（`Qt/src/fg/FgBackend.cpp:565-625`），**重建后每个 pass 的计算管线都要重新编译**，这笔开销正好落在用户拖窗口的那一刻。〔实测〕

**关键工程约束**：FidelityFX-SDK 是 gitlink 子模块（pin `c6efa6bf…`），直接改子模块工作树不进父仓库 diff，`git submodule update` 就会丢。而构建**根本不编译子模块里的 `ffx_vk.cpp`**，编译的是配置期生成的改写副本 `output/qt-build/fidelityfx-compat/ffx_vk.cpp`（`build.ninja:230`），生成器是 `cmake/FidelityFX.cmake` 的 `_rhine_ffx_compat_copy()`。〔实测〕——第一次改子模块后 `cmake --build` 返回 `ninja: no work to do`，就是「改的地方没被编译」的实证。

**改法**（沿用仓库既有的 compat 改写模式）：
1. 新增 `cmake/ffx_vk_pipeline_cache.inc`：在 `CreatePipelineVK` 入口注入一段 C++，按 `VkDevice` 复用一个 `static VkPipelineCache`，用函数表里已有的 `vkGetDeviceProcAddr` 现取 `vkCreatePipelineCache`；失败即退回 `VK_NULL_HANDLE`（= 上游原行为）。
2. 新增 `cmake/ffx_vk_pipeline_cache_create.inc`：把建管线那行换成带缓存、并可选计时的版本。
3. `cmake/FidelityFX.cmake`：`file(READ)` 两个 inc，`string(REPLACE)` 注入到锚点，并在注入后 `if(NOT contents MATCHES …) message(FATAL_ERROR …)` 兜底；顺带补 `<cstdio>/<cstdlib>/<ctime>`。
4. 两个开关：`RHINE_FFX_PIPELINE_CACHE=0` 整段关闭（A/B 用，行为与上游一致）；`RHINE_FFX_CACHE_PROBE=1` 为每条管线打一行编译耗时。

**为什么缓存要活到进程结束**：FSR3 上下文重建后拿到的 `backendContext` 是新的，缓存若跟着上下文走就正好在需要它的时候被销毁。按 `VkDevice` 复用、进程级持有，才能在第二次 `resize()` 命中。

**微基准**（`/tmp/vk_pipe_probe.cpp`，独立程序：同一 `VkShaderModule` + 40 组 specialization constant，模拟 FFX 一轮上下文重建要建的 N 条管线）：

```
device: Intel(R) Iris(R) Xe Graphics (ADL GT2) (api 1.4.354)
variant count: 40
A cold (cache=null): 75.15 ms total, 1.88 ms/pipeline
B warm (cache hit):   0.05 ms total, 0.00 ms/pipeline
cache bytes: 78423
speedup: 1651.29x
```〔微基准〕

要点：
- 「冷建 1.88 ms/条」是**极简 compute shader** 的数字；FSR3 的 pass 着色器更重，单条只会更贵，所以 40+ 条管线一轮重建的量级是**几十毫秒到上百毫秒**，与「拖窗口卡一下」的观感吻合。
- 命中后近似免费（驱动做 hash 查找），因此这笔开销在第二次及以后的重建里基本消失。

**诚实标注的验证边界**：本机 `--offline` 运行没有 motion vector/depth 输入（`FG stats: tapSerial 0 depth null mv null`），插值上下文**没有真正创建**，所以端到端没有触发「建管线」那一步——上面给出的是机制级微基准，不是 FFX 端到端 A/B。端到端复现需要能提供 MV/depth 的 3D 场景（播放音乐时）。

---

## 4. 明确不做的三项（含判据）

### WP3 · present 转场 barrier 把 `dstStage` 改成 `NONE`
现状 `srcStage=COLOR_ATTACHMENT_OUTPUT, dstStage=BOTTOM_OF_PIPE, dstAccess=0` 就是 Vulkan 1.1 里「转场到 `PRESENT_SRC_KHR`」的规范写法：present 不是管线阶段，用 `BOTTOM_OF_PIPE` 作为「到呈现为止」的汇合点是标准做法。〔规范〕
`dstStage=NONE` 属于 synchronization2 语义（Vulkan 1.3），而本文件里 `QVulkanInstance::setApiVersion(1.1)` 是写死的；改动要连实例/设备版本、QRhi 内部提交一起动，**语义收益为零**。不做。

### WP4 · `FIFO_LATEST_READY`
`VK_KHR_present_mode_fifo_latest_ready` 在「必须 vsync」时比 FIFO 更好（vblank 节流但总取最新帧，队列不堆旧帧）。本机 Mesa 26.2.5 的 ANV **不暴露**该模式：启动报告里 `fifo_latest_ready=0`，`vulkaninfo` 的 present mode 列表也只有 `MAILBOX/FIFO`。〔实测〕
没有可验证设备就启用一个需要额外设备扩展的枚举，属于「改一处、坏一片」的典型风险；因此本轮只把能力探测做进启动报告（以后在支持的平台上能直接看出来），不切模式。

### WP5 · 去掉每帧「只等不信号」的空提交
现状每帧一次空提交把 acquire 的 `VkSemaphore` 转成 QRhi 提交能等的信号量。想省掉它必须让 QRhi 的提交直接等 `acquireSemaphore`，但：
- QRhi 的 `setQueueSubmitParams` 只替换信号量指针，**不提供提交围栏**（`qrhivulkan.cpp:5761` 附近），我们无法知道上一次 QRhi 提交何时真正执行完；
- 2 个帧槽的 `acquireSemaphore` 若在上一帧提交执行 wait 之前被再次 signal，就是二进制信号量的非法重用；唯一兜底是每帧 `present_wait` 同步，反而更慢。
- 实测取图只要 0.03~0.1 ms/帧，空提交本身也在同量级；而当前已跑到 ≈270 fps，收益上限 <0.1 ms/帧。

正解需要把 `rhi->beginOffscreenFrame` 提到 `vkAcquireNextImageKHR` 之前（改 `PresentationShell` 时序）或改成「每张交换链图像一个 acquire 信号量」，属于结构性改动，收益与风险不成比例。**记录为已知债务**，不做。

---

## 5. 验证记录

| 项 | 命令 / 方法 | 结果 |
|---|---|---|
| 增量构建 | `cmake --build output/qt-build -j 20` | 通过，无警告新增 |
| 回归测试 | `ctest --test-dir output/qt-build` | **11/11 通过**（含 qt_offline、qt_fg_capability_regression、qt_local_music_regression） |
| 真机上屏 | `RHINE_FG=1 RHINE_GRAPHICS=vulkan` + `RHINE_FG_DIAG=1`，10 s | 上屏 2 700 帧，无 validation 依赖、无错误日志；交换链 1262×1370×6，MAILBOX |
| 管线缓存落盘 | 见 §1 | 首跑写入 138 200 B，二跑恢复 138 164 B |
| FFX 补丁生效 | `grep rhineCacheForThisDevice output/qt-build/fidelityfx-compat/ffx_vk.cpp` | 生成副本 line 3277/3674 命中，最终二进制含探针字符串 |
| FFX 开销 | `/tmp/vk_pipe_probe` | 冷 1.88 ms/条 vs 命中 ≈0.001 ms/条 |

**复现命令**（每行可直接粘）：

```bash
# 构建
cd /home/aibeto/code/Rhine-Music-Database && cmake --build output/qt-build -j 20

# 真机上屏（必须 RHINE_FG=1，否则 Linux 上呈现层不接管；必须 QT_FORCE_STDERR_LOGGING=1，否则看不到 Qt 日志）
QT_FORCE_STDERR_LOGGING=1 RHINE_FG=1 RHINE_GRAPHICS=vulkan RHINE_FG_DIAG=1 \
  timeout -s INT 10 ./output/qt-build/RhineMusicDatabase --offline 2>/tmp/run.log

# FFX 管线缓存 A/B 与探针
RHINE_FFX_PIPELINE_CACHE=0 RHINE_FFX_CACHE_PROBE=1 …   # 关缓存 + 打印每管线耗时
```

---

## 6. 若继续做：按性价比排序

1. **让插值真正跑起来时再测一次 WP6**（需要 MV/depth）：把 `RHINE_FFX_CACHE_PROBE=1` 打开，音乐播放中拖窗口，对比开关缓存的「一次 resize 内建管线总耗时」。
2. **每交换链图像一个 acquire 信号量**：这是去掉空提交、且不违反二进制信号量语义的正解，同时让 acquire 与 QRhi 提交解耦。
3. **`VK_KHR_pipeline_binary`**（Vulkan 1.4 新扩展）：比 `VkPipelineCache` blob 更可控的落盘粒度，可在支持的驱动上替代 WP1 的 blob 方案。
4. **把 `imageReuseMs` / 队列深度接进性能面板**，让「合成器限速 vs 提交跟不上」在 UI 上直接可读。
