# 07 · 实施记录：全链路优化 A01–A11 落地与 A12 门槛

> 本文落实 [全链路性能报告](../vulkan-3d-fullchain-performance-report.md)（下称“报告”）A 表：**A01**（GPU 计时可信度与帧 ID 贯穿）、**A02**（帧槽等待与提交捕获）、**A03**（图层内容版本）、**A04**（稳定实例 ID）、**A05**（运动矢量 MRT 按需）、**A06**（`blur==0` 盘面单采样）、**A07**（九点柔化与全屏复用的证否）、**A08**（封面预处理与上传预算）、**A09**（绘制状态去重全平台化）、**A10**（swapchain resize 去重与退休证明）、**A11**（整帧资源账本）；**A12** 按报告要求只给“实验前置门槛与判定矩阵”，不盲改。
> 证据等级沿用全套约定：〔规范〕Vulkan 规范/Khronos ·〔源码〕本仓库代码事实 ·〔算术推导〕由公开规格或代码路径换算 ·〔实测〕本机可复现测量（命令附在文末）·〔未验证〕尚未测量的推断。
> **本文不含 GPU 实测数字**：本轮只做到“代码级 + 构建/测试级”验证，运行时收益需要用 §1.3、§5.3、§6.3、§10.3 列出的四态与计数器在一次真人操作里采集。报告里“不把未测当已测”的要求同样适用于本文。

---

## 0. 一页结论

| ID | 改动 | 状态 | 验证 | 代价 / 风险 |
|---|---|---|---|---|
| A01 | 受控呈现路径开启 Vulkan 时间戳查询；GPU 计时按“能力→是否请求→有无样本”四态上报；`presentMs` 与 `endMs` 的重复计量换成整帧 `frameMs` + `frameId` | 已实施 | 构建通过；`qt_render_policy_regression` 覆盖四态分类与状态名；面板与 CSV 已接线〔源码〕 | 驱动不支持时间戳时状态显示 `unsupported`，不伪造数值；`presentMs` 字段保留但标弃用（`FgCapabilityChecks.cpp` 仍在赋值） |
| A02 | 量出“离屏提交次数”和“帧槽等待”：后端统计 `beginOffscreenFrame` 次数与耗时，呈现层算 `submitsPerFrame` 与 begin/end 的 p95/p99 | 已实施（只测不改架构） | 构建通过；CSV 新增 6 列、面板新增“FG 提交/等待”行〔源码〕 | 分位用 120 样本环，前 8 帧不出分位；`submitsPerFrame` 依赖后端计数差，后端归零时按差值为负夹到 0 |
| A03 | 引擎内容版本 `sceneRevision`/`hudRevision`：渲染线程发现新资源落地时回报一次，图层按版本置脏去重 | 已实施（默认关闭，`RHINE_LAYER_REVISION=1` 启用） | 构建通过；探针新增“版本”栏与两路版本号〔源码〕 | 默认仍走信号 + 20 帧兜底，行为与优化前一致；启用后未实机比对（见 §7.3） |
| A04 | `SceneDrawData` 增加逐实例稳定 ID，`previousModel` 按 `(drawId, instanceId)` 精确匹配，旧的平移列哈希降为回退 | 已实施 | 构建通过；`RHINE_MOTION_PROBE` 可量化“按 id / 回退 / 未配对”三路比例〔源码〕 | `rebase()` 那一帧全体 ID 变（速度 0 一帧）；条数变化时整块回退旧路径；需目检（见 §8.3） |
| A05 | 运动矢量 MRT 与逐实例历史只在 `taa`/`fsr` 需要时分配，并把“是否需要”纳入 resize 早退比较 | 已实施 | 构建通过；`RHINE_AA_MODE=off/fxaa/msaa/fsr1` 不再分配目标〔源码〕 | 切换 AA 模式会触发一次资源重建（已被早退吸收，不再每帧重建）；`fsr3` 运行期不可用时仍按配置分配（空写一次 16 B/实例） |
| A06 | 盘面片元着色器在 `blur==0` 时走单次采样快路径（两个变体同步改） | 已实施 | 数学恒等 + float32 模拟偏差 ≤5 ULP〔算术推导〕 | 仅影响“清晰档”（`clarity==1` 或非 viewer）；模糊档路径与画质不变 |
| A07 | 九点柔化与两处全屏拷贝：**证否**“可逐像素等价省略”，只留注释、探针与一处 `qputenv` 去重 | 已实施（结论为不改画面） | 构建通过；`RHINE_POST_PROBE=1` 可逐路径核对提交数〔源码〕〔算术推导〕 | 若后续要省这 9 次采样，只能做成显式质量档（`RHINE_SOFTEN=fast`），不是等价优化 |
| A08 | 封面合成与整条 mip 链移到工作线程预处理，渲染线程只做按预算的上传与换绑 | 已实施 | 构建通过；`RHINE_TEXTURE_PROBE=1` 输出完成/过期/溢出/顺延与首次可见帧数〔源码〕 | 换歌瞬间可能多显示一帧旧封面；线程池拒绝或预处理失败自动退回同步路径 |
| A09 | 绘制状态去重（排序 + 只在管线/绑定变化时下发）从 Linux 专用分支推广到全部后端，并修掉 `#ifdef` 包住函数闭合括号的结构隐患 | 已实施 | 构建通过；透明段提交顺序不变〔源码〕 | 唯一画面差异：`blend=true` 但非 transparent 的 hashed 材质改为按管线分组提交，需真人目检 |
| A10 | 后端 `resize()` 增加尺寸早退（不再每帧 `m_rhi->finish()`），并新增 `swapchainRecreates`/`deviceIdleWaits`/`resizeSkips` 三个计数器贯穿到面板与 CSV | 已实施 | 构建通过；计数器接线到 `RhineFg::Stats`/CSV/reportStats〔源码〕 | 早退依赖“已生效交换链尺寸”这一新口径；运行期收益待用 `fg_resize_skips` 与 `fg_device_idle_waits` 的比值证明〔未验证〕 |
| A11 | 局部预算升级为整帧资源账本：240 帧滚动窗口的峰值（带峰帧号）+ 每帧新增绑定/上传 + 封面重传率 + 可选预算告警 | 已实施 | 构建通过；CSV 新增 8 列、面板新增“整帧资源”块〔源码〕 | 峰值是滚动窗口而非 lifetime；“封面字节”没有数据源，只有次数与重传率 |
| A12 | LOD / 深度预通过 / indirect / async 专项实验 | **未实施**，只给门槛与判定矩阵（§12） | 报告本身就要求“先确认规模/overdraw/空闲引擎再决定投入”〔规范〕 | 没有前置证据就动手，等于用主路径风险换不确定收益 |

一句话：**这一轮把“看不见”变成“看得见”（A01/A02/A03/A11），把四条确定的白工从热路径上删掉（A05/A06/A08 的一部分/A10），并诚实记录了一个“看起来能省、实际不能省”的结论（A07）**；帧时间收益仍需一次真人操作把新计数器采出来。

---

## 1. A01：GPU 计时可信度与帧 ID 贯穿

### 1.1 问题（三个独立的缺口）

1. **受控呈现路径从来没请求过时间戳。** `VulkanPresentationBackend::createDevice()` 建 QRhi 时只带 `QRhi::EnablePipelineCacheDataSave`，而 `RhiScene` 的 GPU 帧时间读的是 `cb->lastCompletedGpuTime()`，前置条件是 `rhi()->isFeatureSupported(QRhi::Timestamps)`。〔源码〕默认 Qt Quick 路径在 `main.cpp` 里有 `graphics.setTimestamps(true)`，于是行为分裂：默认路径能报数，呈现层接管后恒为 0。
2. **0 的含义被复用。** 面板把 `gpuTimeMs` 为 0 一律当作“没有测量”，而三种截然不同的原因（不支持 / 没请求 / 这一帧还没完成）挤在同一个 0 里，无法判断是平台问题还是配置问题。〔源码〕
3. **计时重复且缺帧 ID。** `PresentationShell::presentOne()` 里 `endFrame()` 之后重新起表再记 `presentMs`，量到的只是几条记账语句（恒≈0），与 `endMs` 是同一段；同时 CSV 的每一行没有与呈现帧对齐的标识，“帧间隔 30 ms 但分项都是 1 ms”的缺口无法追到具体帧。〔源码〕

### 1.2 改法

- `Qt/src/render/VulkanPresentationBackend.cpp`：`QRhi::create(..., QRhi::EnablePipelineCacheDataSave | QRhi::EnableTimestamps)`；建好后若 `isFeatureSupported(QRhi::Timestamps)` 则 `RhineRender::requestTimestamps()` 登记。离屏的两个 `QQuickWindow` 通过 `QQuickGraphicsDevice::fromRhi()` 共用同一个 QRhi（`SceneLayerHost` 里有 `m_scene.control->rhi() == rhi` 的校验），所以这一处开关同时覆盖场景与图层两条绘制路径。
- `Qt/src/main.cpp`：默认 Qt Quick 路径同样 `RhineRender::requestTimestamps()`，与既有 `setTimestamps(true)` 对齐——否则呈现层没接管时面板会把“没请求”报成“没样本”。
- 新增 `Qt/src/render/RenderPolicy.h`（header-only，只依赖 `QString`，可离线测）：
  - `enum class GpuTimingStatus { Unsupported, Disabled, NoSample, Ok }`；
  - `classifyGpuTiming(featureSupported, timestampsRequested, hasSample)`——`!supported` 优先判 `Unsupported`，其次 `!requested → Disabled`，最后 `hasSample ? Ok : NoSample`；
  - `gpuTimingStatusName()` 给出 `"unsupported" / "disabled" / "noSample" / "ok"`。
- `Engine::recordRender()` 追加第 7 参 `RhineRender::GpuTimingStatus gpuTiming`，`performance()["gpuTimingStatus"]` **无条件**输出；`gpuTimeMs` 仍只在 `> 0` 时输出（0 继续表示“没有数值”，数值与状态分开）。
- `Qt/src/RhiScene.cpp` 每帧：`classifyGpuTiming(rhi()->isFeatureSupported(QRhi::Timestamps), RhineRender::timestampsRequested(), gpuTimeMs > 0)`。
- `PresentationShell`：新增 `m_frameProbe`，从 `beginFrame()` 之前起表到 `endFrame()` 返回后停表，得到**整帧** `frameMs`；`presented` 时 `++frameId`。原“上屏耗时”列改名为“整帧”，`reportStats()` 一行里可直接对照“取图/场景/光流/插值/合成/整帧”。
- `FrameProfiler`：CSV 在**末尾**追加 7 列（`gpu_timing_status, render_frames, fg_frame_id, fg_frame_ms, fg_swapchain_recreates, fg_device_idle_waits, fg_resize_skips`），旧 14 列顺序不动，历史分析脚本不受影响；面板详情新增一行“GPU 时间 …”。

### 1.3 验收口径（怎么读这四态）

| 状态 | 含义 | 现场该查什么 |
|---|---|---|
| `ok` | 有真实样本 | `gpuTimeMs` 可直接引用 |
| `disabled` | 驱动支持，但这条路径没请求 | 呈现层 `EnableTimestamps`、`main.cpp` 的 `setTimestamps(true)` 是否被别处覆盖 |
| `noSample` | 已请求，本帧没有已完成样本 | 首帧、刚重建资源、或提交队列长期未完成 |
| `unsupported` | 后端/设备不支持 | 软件光栅化（`RHINE_SOFTWARE_GPU`）、部分 GL 实现 |

### 1.4 未做

- 多帧平均与百分位：`frameMs`/`gpuTimeMs` 仍是 `blend()` 滑动平均（与既有分项一致），尖峰看 `gapP99/over33Ms` 直方图；**逐帧最慢样本**没有单独落盘。
- 每 pass 的 GPU 时间戳（`QRhi::newTextureReadback` + 多处 `setTimestamps`）没有做，属于 A11 的账本范畴。
- **没有 GPU 实测**：本机 GUI 运行会在启动时恢复网络播放（对用户有副作用），已放弃该验证方式；四态在构建期与离线用例里覆盖。

---

## 2. A05：运动矢量 MRT 按需分配

### 2.1 问题

`RhiScene::resize()` 里 motion 目标的分配条件只有 `sampleCount <= 1`：于是 `RHINE_AA_MODE=off/fxaa/msaa/fsr1` 也会分配一张 `RGBA16F` 颜色附件、维护两张历史纹理、并给每个实例多写 16 B 的 `previousModel`——这些数据只有 TAA/FSR 的时域路径会读。〔源码〕〔未验证〕多一次全屏附件写入在核显上是实打实的带宽。

### 2.2 改法

- `ScenePostProcess` 新增 `bool motionConfigured() const` = `RhineRender::modeNeedsMotion(qEnvironmentVariable("RHINE_AA_MODE")) || RhineFg::isEnabled()`。**分配看配置，消费看运行期能力**：`needsMotion()` 语义保持不变（`temporal()` 还要看 FSR 引擎是否 `available()`），避免“配置说要、运行期拿不到”时把 MRT 删掉。
- `RhiScene::resize()`：`const bool wantMotion = nextSamples <= 1 && (postProcess->motionConfigured() || qEnvironmentVariableIsSet("RHINE_WARP_PROBE"));`，并把 `motionTarget == wantMotion` 加进早退条件；切换时打一行 `运动矢量目标: 分配/不分配 | AA <mode> | samples <n>`。

| `RHINE_AA_MODE` | 运动矢量目标 | 说明 |
|---|---|---|
| `off` / `fxaa` | 不分配 | 没有时域重投影 |
| `msaa` | 不分配 | 采样数 > 1，MRT 与 resolve 冲突（既有约束） |
| `fsr1` | 不分配 | 只有空间升采样 |
| `taa` / `fsr3` | 分配 | 需要逐像素运动矢量 |
| 任意 + `RHINE_FG_LAYER=on` | 分配 | 呈现层插值要 depth/motion |
| 任意 + `RHINE_WARP_PROBE` | 分配 | 探针需要写 warp |

### 2.3 代价与风险

- 模式切换（例如 `off → taa`）会触发一次资源重建；这条路径本来就要重建，早退比较里加上 `motionTarget` 只是保证“配置变了能重建”，不会引入每帧重建。
- `fsr3` 在运行期 `available()` 为假时仍会分配：这是“按配置口径”而不是“按当帧能力口径”的取舍——当帧能力会在运行中翻转，跟着它分配/释放会得到抖动。
- 非 Linux 平台只多一个 `bool` 成员，不改变它们的实例布局。

---

## 3. A06：`blur == 0` 的盘面单采样

### 3.1 位置

`Qt/shaders/enhancement/opticalSurface.frag` 与 `opticalSurfaceNoMrt.frag` 各有一份盘面（`flags.x == 6.0`）采样块，必须同步改，否则 OpenGL 后端与 Vulkan 后端画质不一致。

### 3.2 等价性

原代码在 `blur == 0` 时：中心采样 1 次（权重 4）+ 两环各 8 次（每环 4 个方向各正负，共 16 次），全部落在同一个 `discUv`；权重和 `total = 4 + 16 = 20`。因此

```
(4·S + 16·S) / 20 = S
```

与快路径 `linearColor(texture(cover, discUv).rgb) * 0.8` 在数学上恒等，`keyLight()` 的作用顺序也一致（两路都是先乘 0.8 再 keyLight）。〔算术推导〕float32 逐项模拟两次求和的相对偏差 ≤ 2.98e-7（≤5 ULP），远低于 8 bit sRGB 的一个台阶（≈2.46e-3 线性）。

阈值用 `blur <= 1e-6` 而不是 `blur == 0.0`：`blur = viewer ? (1.0 - clamp(v_clarity,0,1)) : 0.0`，非 viewer 时精确 0，viewer 且 `clarity == 1.0` 时 `1.0 - 1.0` 也精确 0；用 epsilon 只为避开浮点相等比较，并且不会把“几乎清晰”的实例误放进快路径。

### 3.3 收益与代价

- 清晰档（默认 `clarity = 1.0`，且非 viewer）盘面像素的纹理采样从 17 次降到 1 次：报告里写的“20”是权重和，实际 texture 指令是 17 条。
- 模糊档路径完全没动，画质不受影响；分支是 uniform 风格的逐实例标量，不会造成 warp 内发散放大。
- 同一片元着色器里另外两处“看起来可以省”的采样（`opticalFinalFragment.frag` 的九点柔化、`taa.frag` 的 3×3）见 A07：前者不存在等价快路径，后者是时域积分的固有成本。

---

## 4. A09：绘制状态去重全平台化

### 4.1 问题

`RhiScene::geometry()` 里“按管线/绑定排序后只在变化时下发”的去重路径整段被 `#ifdef Q_OS_LINUX` 包住，其他后端每 draw 无条件 `setGraphicsPipeline()` + `setShaderResources()` + `setViewport()`。〔源码〕同一份数据，Linux 上 3 次状态切换，Windows/macOS 上可能是 3×N。

### 4.2 改法

- 去掉 `geometry()` 内的 `#ifdef Q_OS_LINUX / #else / #endif`，排序 + 去重路径全平台生效；`RHINE_DRAW_PROBE` 的探针统计保留（它统计的正是“实际下发次数”，是这条路径是否生效的直接证据）。
- 同时修掉一个结构隐患：HEAD 里 `geometry()` 末尾的 `#ifdef Q_OS_LINUX` 还包住了**函数自身的闭合花括号**和整个 `warpFrame()`，导致任何按预处理条件改这段代码的操作都容易把大括号弄丢。现在 `geometry()` 的 `}` 在 `#ifdef` 之外，`warpFrame()` 单独被 `#ifdef` 圈住。

### 4.3 一致性

- 透明段顺序不变：`render()` 本来就分别调用 `geometry(opaque)` 与 `geometry(transparent)`，而不透明/透明的划分来自 `data["transparent"]`；`geometry()` 内的 `stable_sort` 对透明项恒返回 `false`，保持原序。
- 唯一可见差异：`blend = true` 但 `data["transparent"] = false` 的 hashed 材质（磨砂/半透明封面一类），现在会按管线分组提交，而不是按 draw 顺序。这类材质如果依赖“按绘制顺序混合”，理论上可能出现差异——**需要一次真人目检**（放大封面、切到磨砂卡面）确认无可见变化。

---

## 5. A10：swapchain resize 去重

### 5.1 根因

`PresentationShell::syncSizes()` 每帧把窗口尺寸推给后端；`VulkanPresentationBackend::resize()` 无条件执行 `m_rhi->finish()`（`vkDeviceWaitIdle`）→ `releaseTargets()` → 重建交换链目标 → `ensureTargets()`。`VulkanPresenter::resize()` 内部本来有“尺寸没变就返回”的早退，但它在 `finish()` 之后才被调用，等于每帧一次设备空闲等待＋一次全量资源重建。〔源码〕这正是报告里“呈现层最贵的一行”和反模式清单第 11 条（每帧 `vkDeviceWaitIdle`）。

### 5.2 改法

- 后端 `resize()` 顶部：`if (!force && m_presenter && !m_swapTargets.empty() && size == m_size && m_swapSize == m_presenter->extent()) { ++m_resizeSkips; return true; }`——只做尺寸比较，不 `finish()`、不重建。
- `m_size` 口径从“上次请求的逻辑尺寸”改为“**已生效的交换链尺寸**”：`initialize()` 末尾与每次重建成功后都取 `m_presenter->extent()`。否则 HiDPI 下“请求的逻辑像素 ≠ 交换链物理像素”，同尺寸判断会永久失败，早退形同虚设。
- `PresentationShell::syncSizes()` 末尾新增受保护接线：`if (m_presenter && !m_needRecreate && m_presenter->extent() == pixelSize()) m_presenter->resize(pixelSize(), false);`——只确认、不重建；真正重建仍只走 `recreateSwapchain()`（`force = true`），那里要作废跨尺寸的插值历史并强制重画一帧。
- 三个计数器：`swapchainRecreates`（重建成功次数）、`deviceIdleWaits`（真正发生 `m_rhi->finish()` 的次数）、`resizeSkips`（早退次数）。它们经 `RhineFg::Stats` 每帧发布，`reportStats()` 一行打印“重建 N 等待 M 尺寸跳过 K”，并各占 CSV 一列。

### 5.3 验收口径

| 现象 | 结论 |
|---|---|
| `fg_resize_skips` 随帧数增长，`fg_device_idle_waits` 不增长 | 静止窗口下不再每帧等 GPU 空闲（A10 生效） |
| 拖动/改窗口时 `fg_swapchain_recreates` 与 `fg_device_idle_waits` 同步 +1，然后停住 | 重建只发生在尺寸真的变化时 |
| 两者都持续增长 | 早退条件没命中：查 `m_size` 与 `presenter->extent()` 的口径差（DPI 缩放、presenter 内部 clamp） |

### 5.4 风险

- 早退只在 `force == false` 生效：`OutOfDate` 与窗口 `Resize/Expose` 仍强制重建，不会把“能呈现但已失效”的交换链留下。
- 若 `presenter->extent()` 与请求尺寸长期不一致，会退化成“每帧一次重建”以外的路径：第一帧重建后 `m_size = extent`，之后即命中早退（自愈，不会回到旧行为）。
- 本项**没有 GPU 实测**：收益的上界是“每帧一次 `vkDeviceWaitIdle`”，实际节省取决于该 API 在本机的耗时〔未验证〕。

---

## 6. A02：帧槽等待与离屏提交计数

### 6.1 问题

报告指出的两个等待在日志里是同一行时间：`beginFrame()` 里可能等帧槽（上一帧的 image 还没被合成器释放），`endFrame()` 里可能等的是队列串行化。只有把两段分开，才能回答“30 ms 的帧间隔到底是等槽还是在等 GPU”。〔源码〕

### 6.2 改法（只测量，不改提交结构）

- `PresentationBackend` 新增两个默认虚函数：`offscreenSubmits()`（默认 0）、`slotWaitMs()`（默认 −1 表示“本后端不提供”）。`VulkanPresentationBackend` 在 `beginFrame()` 内用 `QElapsedTimer` 包住 `beginOffscreenFrame()`，并 `++m_offscreenSubmitCount`；**没有改队列、信号量与调用顺序**——报告要求“有证据再改架构”。
- `RhineFg::Stats` 新增 `slotWaitMs`、`beginP95Ms/beginP99Ms/endP95Ms/endP99Ms`、`submitsPerFrame`。
- `PresentationShell`：120 个样本的环形缓冲（每 8 个样本重算一次分位，避免每帧 O(n log n)）；`submitsPerFrame` = 后端计数差 + QML 场景层/UI 层渲染计数差，后端计数归零时把差值夹到 0（后端重建后计数会回到 0）。
- `reportStats()` 增加“FG 提交/等待”一行；CSV 追加 6 列：`fg_submits_per_frame, fg_slot_wait_ms, fg_begin_p95_ms, fg_begin_p99_ms, fg_end_p95_ms, fg_end_p99_ms`。

### 6.3 验收口径

| 读数 | 含义 |
|---|---|
| `fg_submits_per_frame` 稳定在 1–3 | 一帧里只有呈现层 + 0–2 个 QML 图层的离屏提交（与设计一致） |
| 该值随帧漂到 6 以上 | 有额外的 `QQuickRenderControl::beginFrame` 被触发（多半是图层置脏过多，看 A03 探针） |
| `fg_slot_wait_ms` 偶发大、`fg_begin_p95_ms` 跟着大 | 等在帧槽（合成器没释放 image） |
| `fg_end_p95_ms` 大而 begin 小 | 等在 GPU 串行化/呈现，与帧槽无关 |

### 6.4 未验证

- 本机没有采集过 `slotWaitMs` 的真实量级（GUI 运行有副作用，见 §1.4）；默认 −1 时面板显示为空而不是 0，避免“没测量”被当成“零等待”。

---

## 7. A03：图层内容版本

### 7.1 问题

`SceneLayerHost` 的置脏来自三路：Qt 的 `renderRequested`（噪音级频率）、引擎信号（`sceneUpdated`/`hudUpdated`）、以及 20 帧一次的兜底。三路都没有“这一帧到底有没有新内容”的可比较结论，于是探针只能看到“重渲了多少次”，看不到“哪一次是白渲”。更麻烦的是**异步资源到达**：模型/纹理/封面在工作线程里就绪时，引擎的帧签名比较看不到变化（帧字段没变），只能等兜底，表现就是“封面比歌名慢半拍”。〔源码〕

### 7.2 改法

- `Engine` 新增两个单调版本：`sceneRevision()`、`hudRevision()`（relaxed 原子，主线程写、渲染线程读）。只在内容真的变化时自增：`notifySceneRenderers(visualChanged == true)` 与两处 `hudUpdated` 发射点。
- `Engine::requestSceneContent()`（`Q_INVOKABLE`）：给“渲染线程发现的新资源落地”用。`RhiScene` 每帧算出的 `bindings`（本帧新建 SRB 数）> 0 时，用 `Qt::QueuedConnection` 回报一次——新 SRB 就意味着有新纹理/新缓冲被绑上，这正是异步加载完成的信号。回报后 3D 层立刻重画一帧，不必等兜底。
- `SceneLayerHost::setResourceRevision(scene, hud)`：版本前进才置脏，两路分开置脏（HUD 每帧都变时不能顺手把 3D 层一起拖去重渲）。`PresentationShell::step()` 在 `renderFrame()` **之前**每帧推一次。
- 探针（`RHINE_LAYER_PROBE=1`）增加“版本”一栏与两路版本号，60 帧打印一次。

### 7.3 为什么默认关闭

兜底间隔（20 帧 ≈ 0.3 s）本来就是为“异步资源到达没有信号”准备的。把置脏切到版本号之后，兜底就是唯一的可见性保障；在实机比对过“启用后不丢更新”之前，不能直接把默认路径换掉。所以做成 `RHINE_LAYER_REVISION=1` 才启用、默认只记录版本——出事只换环境变量就能回到旧路径，`RHINE_LAYER_SAFETY_FRAMES` 也仍然可调（0 = 恢复每帧强制置脏）。

**验收（启用后）**：`图层探针` 的“版本”栏应当只在内容变化时增长，且“3D 重渲次数”应当明显小于“置脏来源总和”；连续滚动 HUD 时 UI 重渲应当持续、3D 重渲应当接近 0。这两条没实测过〔未验证〕。

---

## 8. A04：稳定实例 ID 与 `previousModel`

### 8.1 问题

运动矢量的速度来自“当前实例矩阵 − 上一帧同实例矩阵”。原来的匹配方式是**按平移列哈希**：只有平移列逐字节相同的实例才能配上，移动中的实例、浮点微差的实例、以及同一位置的两个不同对象都会漏配或错配。〔源码〕错配的后果比漏配更糟：速度方向完全错误，时域累积会把错误抹开到整块画面。

### 8.2 改法

- `SceneTypes.h` 的 `SceneDrawData` 增加 `QVector<quint32> ids`。
- `NativeSceneUpdate.cpp`：`cellInstanceId(cell) = quint32(quint16(cell.lane)) << 16 | quint16(cell.row)`——格子位置本身就是稳定身份；`instanceIds` 与 `visibleMatrices` 同步 append；按距离重排（`stable_sort` 的 reordered 分支）时 `sortedIds` 一起重排，保证矩阵与 ID 永远同序。
- `NativeCards.cpp`：卡片直接用 `card["id"].toInt()` 当实例 ID。
- `RhiScene::instance()`：`previousInstanceMatrices` 的键改成 `quint64(drawId) << 32 | instanceId`；只有当“上一帧这一块写入的条数与本帧相等”时才走按 ID 匹配（`previousInstanceCounts` 闸门），否则整块回退旧的平移列路径。三种结果分别计数：按 ID 命中 / 平移列回退 / 未配对（速度 0）。
- `RhiScene::resize()` 早退之后清空三张表并 `motionHistoryValid = false`：顺带修掉“resize 后第一帧仍用陈旧 VP 算重投影”的既有缺陷。

### 8.3 已知取舍

- `rebase()`（场景整体重置）那一帧全体 ID 会变，速度退化为 0 一帧，随后恢复。
- 条数变化（进出视野）时整块回退旧路径：这一帧的匹配质量与优化前一致，不会更差。
- 同一实例块被多个 draw 引用时主表记录冗余（每条 80 B），换取“不需要跨 draw 建索引”。
- **只能靠画面验证**：`RHINE_MOTION_PROBE=1` 打印三路比例（期望“按 ID”占绝对多数、未配对接近 0），但最终要看移动/重叠/新生实例的速度图是否干净。

---

## 9. A07：九点柔化与全屏复用——证否

### 9.1 结论

**没有可证明逐像素等价的全屏 pass 或采样可以省。** 这一项的正确交付是“把不能省的理由写进代码”，而不是硬造一条快路径。

### 9.2 九点柔化为什么不能塌成一次采样

`opticalFinalFragment.frag` 的核是 `[1 2 1; 2 4 2; 1 2 1] / 16`，tap 半径

```
k = 1 + 6 · distanceFromFocus · soften   ∈ [1, 7]   （像素）
采样偏移 = k / textureSize
```

即使 `soften == 0` 或 `distanceFromFocus == 0`，`k == 1`，九个 tap 仍然落在 **±1 texel 的九个不同位置**，权重和 16——它不是“九个相同采样”，不存在数学恒等的单采样替代。〔算术推导〕注释已写进 `Qt/shaders/enhancement/opticalFinalFragment.frag`（19 行，零语义改动），同时记录“四次双线性折叠 9→4 采样”的等价推导与不启用它的三条理由（需要额外纹理/采样状态、收益仅 5 次采样、失去质量档的清晰语义）。

### 9.3 另外两处“看起来能省”的全屏拷贝，实测/推理都不能省

| 位置 | 为什么不能省 |
|---|---|
| `taa` 的 `copyColor → destination` | 历史纹理必须是未呈现的 `RGBA16F`（下一帧还要读），而 `destination` 是 8 位呈现目标；同一个 pass 不能既当历史又当呈现目标（别名） |
| FSR3 的 `m_output → destination` | compute 必须写 `UsedWithLoadStore` 的 16F，跨格式 `copyImage` 实测整屏粉红（格式/布局不兼容），只能走 pass 拷贝 |

### 9.4 本轮唯一的行为改动

`qputenv("RHINE_FSR_ENGINE", ...)` 原来每帧无条件写，改成值变化才写（`RHINE_POST_REUSE=0` 可回滚）。这是纯 CPU 侧的字符串/环境表操作，收益微小但零风险；同时新增 `RHINE_POST_PROBE=1`，按路径（fxaa / taa-init / taa-steady / fsr3 / fsr1）打印提交数与绑定数，为“以后要不要做质量档”留下证据。

---

## 10. A08：封面预处理与上传预算

### 10.1 问题

换歌时封面在**渲染线程**上完成：`QPainter` 合成（`coverSize = clamp(width, 512, 1024)`）→ 逐层 `scaled` 生成整条 mip 链 → 逐层 `setData` 上传。这是一次同步的、几十毫秒量级的 CPU + 上传工作，正好落在出帧路径上；封面越大、mip 越多，卡顿越明显。〔源码〕

### 10.2 改法

- `CoverPrepareTask : QRunnable` 在全局线程池里完成“合成 + 整条 mip 链”，产出 `CoverPrepareResult`（每层字节数 + 整块像素）；工作线程**只碰 QImage 与 QPainter，不碰 QRhi、不碰 Glyphs**，结果经 `shared_ptr<CoverMailbox>`（`QMutex` + `QQueue`）回到渲染线程。
- 渲染线程每帧一次 `drainCoverPrep()`：按“请求代号还在不在、是否还有 key 想要这个 revision、是不是已经有人做出来了”判过期，再按**每帧字节预算**上传（`RHINE_TEXTURE_UPLOAD_BUDGET_MB`，默认 8 MiB，0 = 不限）。队首那条即使单张超预算也放行，否则小预算配大封面会永久饿死。
- 换绑 `bindCoverTexture()`：同一 revision 被多首同专辑曲目共享，一次全部换绑；旧纹理只有在没有别的 key 引用时才退休（`cacheKey == 0` 的占位图被所有空封面共享，提前退休会让别人的 SRB 指向已释放对象）。
- 兜底：无图（要画占位图，需要 Glyphs）、参考图渲染、线程池拒绝、预处理失败 → 一律走原来的同步路径；等待期间保留上一张封面，绝不显示空纹理。
- 探针 `RHINE_TEXTURE_PROBE=1`：完成数 / 过期丢弃 / 队列溢出丢弃 / 顺延帧数 / 首次可见帧数（最近 8 次）。

### 10.3 验收口径

| 读数 | 含义 |
|---|---|
| 首次可见帧数 ≤ 2 | 预处理与上传都在一两帧内完成（正常路径） |
| 首次可见帧数长期 > 5 且 `顺延` 增长 | 预算太小或封面太大：调 `RHINE_TEXTURE_UPLOAD_BUDGET_MB` |
| `过期丢弃` 远大于 `完成` | 用户在快速切歌，属正常；若静止时也这样，查 `coverWanted` 的登记/撤销 |
| 换歌时不再出现单帧长卡 | A08 的主要目标（CPU 侧工作已移出渲染线程） |

`rhine_texture_probe` 的数值同样**未实测**〔未验证〕；本轮只保证“编译通过 + 逻辑自洽 + 有回退路径”。

---

## 11. A11：整帧资源账本

### 11.1 问题

原来只有“当前值”（`gpuResources`/`bindingCreations`/`gpuMusicTextureBytes`/`coverUploads`），回答不了三个问题：峰值出现在哪一帧、本帧新增了多少、封面到底重传了几次。〔源码〕

### 11.2 改法

- `Engine::noteFrameLedger()` 在 `recordRender()` 末尾聚合，240 帧**滚动窗口**记录 `(帧号, 资源数, 纹理字节)`，窗口内重算峰值并带上峰值帧号。
- `performance()` 新增键：`gpuResourcesPeak/Frame`、`gpuTextureBytesPeak/Frame`、`frameBindings`、`frameCoverUploads`、`coverUploadsPerFrame`（EMA，千分整数发布）、`coverRetransmitPerKFrame`、`resourceBudgetMb`。
- `RHINE_RESOURCE_BUDGET_MB`：默认 0（关闭），非 0 时超预算**只告警一次**，不降级——降级策略要先有数据才敢定。
- CSV 追加 8 列：`ledger_resources_peak, ledger_resources_peak_frame, ledger_texture_bytes_peak, ledger_texture_bytes_peak_frame, ledger_frame_bindings, ledger_frame_cover_uploads, ledger_cover_uploads_per_frame, ledger_cover_retransmit_per_kframe`（总 35 列，旧 21 列顺序不动）。

### 11.3 口径（不要混用）

| 字段 | 单位 | 来源 |
|---|---|---|
| `resources` | 资源**个数** | `RhiScene` 把 `resources/sized/transient` 相加（含 postProcess 与 motion） |
| `textureBytes` | **字节**（驻留快照） | `musicTextureBytes()`，按 `w*h*4*4/3` 估 mip 占用 |
| `bindings` | 本帧**新建 SRB** 个数 | `bindingCreations` 差分（含 postProcess） |
| `coverUploads` | 本帧封面**上传次数** | `RhiScene` 只提供次数，没有字节数——所以“封面字节”这一列不存在 |

`coverRetransmitPerKFrame` = 每千帧封面重传次数，是“同一封面被重复上传”的直接指标；滚动窗口与 EMA 都是为了避免启动期一次性上传把 lifetime 峰值/均值永久抬高。

---

## 12. A12：LOD / 深度预通过 / indirect / async 的前置门槛

报告明确要求“仅对已确认瓶颈有效，先确认规模/overdraw/空闲引擎再决定投入”。因此本轮**不实现**，只把判定条件写成可执行的表：没有证据就不动手。

### 12.1 共同前置（缺一不可）

1. **有可信的帧时间分解**：`gpu_timing_status == ok`（A01），且 `frameMs` 的分项之和能解释 ≥ 80% 的整帧时间。
2. **知道是谁贵**：`gpuResourcesPeak`/`frameBindings`（A11）+ `draws`（现有 CSV 列）能给出规模量级；`RHINE_DRAW_PROBE` 给出实际状态切换次数（A09）。
3. **有可回退的开关**：新路径必须能用环境变量关掉，默认路径逐像素不变。

### 12.2 判定矩阵

| 候选 | 前置证据 | 度量 | 通过阈值 | 不通过时的代价 |
|---|---|---|---|---|
| LOD（距离/尺寸分级） | `draws` 持续 > 800 且 `gpu_timing_status == ok`，`gpuTimeMs` 占帧时间 > 50% | `gpuTimeMs` p95、`draws` | p95 降低 ≥ 10% 且目检无跳变 | 多一套资产与切换逻辑，缓存命中率下降 |
| 深度预通过 | 有 overdraw 证据：同屏透明/不透明像素比、或 `gpuTimeMs` 随分辨率超线性 | `gpuTimeMs`、带宽（A11 字节） | p95 降低 ≥ 8% 且不增加带宽 | 多一遍全屏深度写，核显上很可能净负 |
| Indirect draw | CPU 侧提交贵：`sceneMs`/`recordMs` 占 `frameMs` > 20%，`draws` 大但 `gpuTimeMs` 小 | `recordMs`、`draws` | `recordMs` 降低 ≥ 30% | 需要 GPU 端缓冲布局，调试面大 |
| Async compute | 队列空闲证据：`fg_slot_wait_ms` 或 `endP95` 明显 > `gpuTimeMs`（说明 GPU 没吃满） | `idleGapMs`、`gpuTimeMs` | 整帧降低 ≥ 5% 且无额外同步点 | 队列/信号量复杂度上升，本机 ANV 上收益常为 0（见 06 号文档 WP5 的结论） |

### 12.3 顺序建议

先做 A02 的读数结论（提交/等待到底谁大），再决定 LOD 还是 indirect；**深度预通过与 async compute 在本机（Intel Iris Xe + ANV）应先证否**：核显带宽有限、深度预通过多一遍写往往净负，而 ANV 的 async queue 在单队列呈现路径上拿不到并行度（06 号文档已记录同类结论）。

---

## 13. 验证记录

| 项 | 命令 / 方法 | 结果 |
|---|---|---|
| 增量构建 | `cmake --build output/qt-build -j$(nproc)` | 通过：首轮全量 180 步；A01/A05/A06/A09/A10 重编 10 步、零警告；A04/A07/A11 落地后 66 步；A03/A08 落地后 28 步；每轮后都还原构建噪声 |
| 回归测试 | `ctest --test-dir output/qt-build --output-on-failure` | **12/12 通过**：A01–A10 后 40.02 s，A03/A08 后 37.99 s；含 `qt_render_policy_regression`（0.01 s）、`qt_offline`（7.01 s）、`qt_audio_stream_regression`（26.69 s） |
| 逐提交可编译 | `git worktree add --detach /tmp/wt-a01 <sha>` + `cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/usr -DRHINE_PACKAGE_APP=OFF -DRHINE_VERSION=0.0.1` | A01/A05/A06/A09/A10 五个提交各自检出后 `cmake --build` 全部 `RC=0`（A01 为 315 步全量，其余增量） |
| 纯策略用例 | `./output/qt-build/RhineRenderPolicyRegression` | 29 条断言：四态分类 8 格、状态名逐字、`modeNeedsMotion` 10 例、时间戳登记单调 |
| 工程门禁 | `python3 scripts/check-qt-project.py` | `Qt source tree and build commands: no legacy language dependencies` |
| 上游完整性 | `node scripts/check-music-upstream.cjs` | 通过（API 哈希、Enhanced/QQ 锁定与协议拷贝移除） |
| 打包审计 | `python3 scripts/audit-qt.py output/RhineMusicDatabase.AppDir` | `{"qt_deployed": true, "swift_runtime_required": false, "locked_music_bridge": true}` |
| 打包回归 | `node scripts/check-packaged-app.cjs output/RhineMusicDatabase.AppDir` | Session / Native music 44 项 / Qt 场景与离屏包检查全部 passed |

**关于 `npm test`**：它在第一步 `scripts/check-repository.cjs` 就中止，报 `Unexpected public documentation`——实际文件集多出 `docs/vulkan-igpu/0{1..7}-*.md`、本报告与 `.mnemon/runtime/*.md`，而白名单只有 `README.md`、`tools/perf/README.md`。`docs/vulkan-igpu/*` 是分支上已提交的文件（`512e064 docs(vulkan-igpu): 添加实施记录文档与目录项`），白名单没同步，**属分支既有问题，与本轮改动无关**；上表把该步骤之后的门禁逐条单独跑过。桥接测试（`local-lyrics` / `ios-bridge` / `netease-client` / `qq-client` / `kugou-client`）本轮未单跑。

---

## 14. 构建噪声（提交前需还原）

FFX 着色器排列生成器在构建时会重写 `generated/ffx_shaders/vk/*.h` 共 14 个文件：内容集合等价，但 include 顺序与 `IndirectionTable` 索引按哈希顺序重排。这不是本轮的改动，也不会影响功能，但会把 diff 弄脏：

```bash
git restore --source=HEAD -- generated/
```

建议后续把这个生成器的输出固定成确定性顺序，或者把它挪到 `output/` 下（本轮不动构建系统）。

---

## 15. 复现命令

```bash
# 构建（Release，已有 output/qt-build 缓存）
cd /home/aibeto/code/Rhine-Music-Database && cmake --build output/qt-build -j"$(nproc)"

# 回归（12 条，含渲染策略用例与 qt_offline 自检）
ctest --test-dir output/qt-build --output-on-failure

# 只跑新增用例
./output/qt-build/RhineRenderPolicyRegression

# 采集现场数字（GUI，会恢复上次播放的网络音频，注意副作用）
QT_FORCE_STDERR_LOGGING=1 RHINE_FG_LAYER=on RHINE_FG_DIAG=1 RHINE_LAYER_PROBE=1 \
  RHINE_TEXTURE_PROBE=1 RHINE_MOTION_PROBE=1 \
  ./output/qt-build/RhineMusicDatabase --frame-profile /tmp/fg.csv
# 关注列：gpu_timing_status / fg_frame_id / fg_frame_ms /
#         fg_swapchain_recreates / fg_device_idle_waits / fg_resize_skips /
#         fg_submits_per_frame / fg_slot_wait_ms / fg_begin_p95_ms / fg_end_p95_ms /
#         ledger_resources_peak / ledger_texture_bytes_peak / ledger_cover_uploads_per_frame

# 构建噪声还原
git restore --source=HEAD -- generated/
```

**下一轮优先级建议**：先用上面的 CSV 采一组稳定窗口 + 拖动窗口 + 连续切歌的对照数据，确认 `fg_resize_skips : fg_device_idle_waits` 的比值、`fg_submits_per_frame` 的稳定性、封面的首次可见帧数；这三组数字决定 A02（提交结构）与 A08（预算/线程模型）是否值得继续投入。A12 的四项都要等这些证据，报告里的判断标准已经写进 §12.2。
