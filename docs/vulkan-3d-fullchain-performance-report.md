# Vulkan 与 3D 全链路性能优化分析报告

- 项目：Rhine Music Database
- 分析日期：2026-10-30（Asia/Shanghai）
- 代码基线：分支 perf/lts，提交 233e067；分析时已有未跟踪目录 [filament-src](<../third_party/filament-src/>)，本报告不修改该目录。
- 方法：静态源码审计、既有项目记录复核、Qt/Khronos/AMD 官方资料交叉核对。CMake 要求 Qt 6.12，本机 qmake6 报告 6.12.0，现有构建缓存为 Release；这不是运行时性能测试。
- 交付边界：本次仅提交报告，不更改运行时代码；没有在目标 GPU 上执行新基准测试。下文“候选收益”均为待验证假设，不是已测提速。

## 一、结论先行

当前工程已经具备实例化、部分视锥剔除、动态缓冲复用与差分上传、材质绑定缓存、不透明批处理、Linux 管线排序与状态去重、烘焙光照、BC7 条件压缩、独立 UI 图层和管线缓存。继续把“加入实例化/增加缓存/去掉所有 staging”作为首要方案，会忽略当前实现。

建议按以下顺序推进：

1. **P0：先修正观测口径。** 自建 Vulkan QRhi 创建参数未显式包含 EnableTimestamps；现有 GPU 时间查询只判断硬件特性，不能证明采到了有效时间。presentMs 与 endMs 基本重叠，不能作为显示耗时。
2. **P1：核查可控呈现路径的提交与帧槽复用。** Qt 6.12 的 Vulkan 离屏结束仅在活动读回时同步等待；正常无读回路径不能据此判为每帧串行。beginOffscreenFrame 复用槽仍可能等待，3D/UI/最终合成的多次提交应以队列轨迹分析，不预先要求架构重写。[S1](#ref-s1)[S9](#ref-s9)
3. **P1：完成事件驱动的图层更新。** Linux 已有 dirty 与周期兜底，不是“所有平台每帧双层重绘”；非 Linux、非 Metal 分支仍强制置脏。应先补齐异步资源就绪通知，再比较不同平台的图层重渲率。
4. **P1：按需生成运动矢量与历史。** Linux 已采用主几何 MRT，不能再把“合并独立 velocity pass”算成新增收益；应检查无需时域处理时能否省去附件、前帧矩阵构造和带宽。
5. **P1/P2：压缩实际像素工作量与 CPU 重建。** 优先评估最终合成的固定九次采样、透明壳体覆盖、额外颜色复制、实例前帧匹配和 draw 元数据重建；不是先重写成 bindless/GPU-driven 引擎。
6. **P2：资源生命周期和窗口变化。** 减少尺寸变化时重复 finish/WaitIdle 与上下文重建，保留正确的 present 信号量生命周期；优化启动缓存与贴图驻留，但不把冷启动收益计入稳态 FPS。

这里的优先级综合“阻断后续判断程度、影响范围、实现风险”，**不代表已经确认哪个模块耗时最大**。不预设显示器刷新率，不增加 FPS 上限，也不以省电为目标。

**实验前提：** 当前 Vulkan 路径默认不启用 FFX compute（需 RHINE_FSR3_FFX=1 才尝试），FSR 模式可能实际走空间 EASU/RCAS。基线必须记录实际后端和回退原因，不能仅凭设置名称判定时域链路已启用：[Fsr3Backend.cpp:315–320](<../Qt/src/fsr/Fsr3Backend.cpp#L315-L320>)。

## 二、实际渲染链路与责任边界

### 2.1 两条路径必须分别测试

**原生 Qt Quick 路径：** FG 关闭且未强制图层宿主 → QQuickWindow/Qt 场景图 → QQuickRhiItem 的 RhiScene → Qt 管理提交与呈现。

**可控呈现路径：** FG 开启，或 RHINE_FG_LAYER=on → PresentationShell → SceneLayerHost 的 3D/UI 两个离屏 QQuickRenderControl → 3D 后处理 → 可选 FG → 叠加 UI → VulkanPresentationBackend → VulkanPresenter 自建交换链。

入口依据：[main.cpp:557–590](../Qt/src/main.cpp#L557-L590)、[Scene3D.qml:4–21](../Qt/qml/Scene3D.qml#L4-L21)。FG off 与 FG on 的性能差不只来自插帧算法；宿主、线程、离屏提交、图层与合成都可能改变。必须加入“FG off + 强制可控宿主”控制组。

### 2.2 3D 帧内部


```text
default/controlled host
  → Engine / NativeScene：推进模拟、构建可见场景和原生矩阵
  → synchronize：转交场景快照与资源引用
  → RhiScene：尺寸与后处理准备 → 纹理状态 → draw 准备
  → 资源更新 → 不透明 / 透明主几何
  → Linux：颜色 + 运动矢量 MRT；其他路径按需独立 MotionPass
  → 最终颜色合成 → 互斥 AA / FSR（按实际模式）
  → UI 合成 / 可选 FG → 提交 → present 请求
  → 窗口系统合成 / 显示扫描（不在上述 CPU 计时的直接覆盖范围）
```

依据：[NativeSceneFrame.cpp:8–155](../Qt/src/NativeSceneFrame.cpp#L8-L155)、[RhiScene.cpp:1550–1744](../Qt/src/RhiScene.cpp#L1550-L1744)、[ScenePostProcess.cpp:207–251](../Qt/src/render/ScenePostProcess.cpp#L207-L251)。该图是责任链，不是各阶段串行耗时可以直接相加的证明。

### 2.3 已有优化及适用范围

| 已有能力 | 源码证据 | 审计结论 |
| --- | --- | --- |
| 原生矩阵与实例缓冲复用 | [NativeSceneFrame.cpp:47–68](<../Qt/src/NativeSceneFrame.cpp#L47-L68>)；[RhiScene.cpp:1028–1094](<../Qt/src/RhiScene.cpp#L1028-L1094>) | 仍有小型 JSON 元数据，但不是每帧全量 JSON 矩阵传输 |
| 主列表范围/视锥裁剪、实例前到后排序 | [NativeSceneUpdate.cpp:218–303](<../Qt/src/NativeSceneUpdate.cpp#L218-L303>) | 主实例已有范围与视锥处理；排序也已落地，不作为新增收益 |
| 选中/归位对象视锥处理 | [NativeSceneFrame.cpp:118–142](<../Qt/src/NativeSceneFrame.cpp#L118-L142>) | 已有剔除；选中主体豁免、shadow-only 保留，不能称“完全无剔除” |
| 动态缓冲扩容与差分上传 | [RhiScene.cpp:998–1024](<../Qt/src/RhiScene.cpp#L998-L1024>) | 容量按需增长，变化区间按 4 字节扩展；仍需量 CPU 比较成本 |
| 不透明合批 | [RhiScene.cpp:1208](<../Qt/src/RhiScene.cpp#L1208>) 起、1691–1693 | 有材质/透明/深度条件；不能对所有 draw 无条件合批 |
| 管线排序、重复绑定消除 | [RhiScene.cpp:1255–1340](<../Qt/src/RhiScene.cpp#L1255-L1340>) | 核心优化受 Q_OS_LINUX 保护；透明顺序保留 |
| 主通道 MRT 运动矢量 | [RhiScene.cpp:1731–1743](<../Qt/src/RhiScene.cpp#L1731-L1743>) | Linux 已省掉单独几何速度遍历；其他平台不可直接照搬 |
| 烘焙表面、光场、BC7 条件路径 | [RhiScene.cpp:357–379](<../Qt/src/RhiScene.cpp#L357-L379>)；[opticalSurface.frag:30–50](<../Qt/shaders/enhancement/opticalSurface.frag#L30-L50>) | 不是重型实时阴影/PBR 光源遍历，不应优先建议级联阴影裁减 |
| Linux 图层脏标记与安全刷新 | [SceneLayerHost.cpp:447–515](<../Qt/src/render/SceneLayerHost.cpp#L447-L515>) | 已优化但有资源就绪正确性约束；其他分支不同 |
| QRhi 与 FFX 管线缓存 | [VulkanPresentationBackend.cpp:300–321](<../Qt/src/render/VulkanPresentationBackend.cpp#L300-L321>)；[FidelityFX.cmake](<../cmake/FidelityFX.cmake>) | QRhi 与原生 FFX 管线不是同一个缓存责任域 |

## 三、先建立可信的性能观测（P0）

### 3.1 CPU、GPU、排队和显示延迟分开

| 当前字段/采样 | 实际覆盖 | 不能据此断言 |
| --- | --- | --- |
| scene native / metadata / buffers | NativeScene 的 CPU 构帧阶段 | 不是 GPU 几何/光栅时间 |
| before/afterSynchronizing | Qt 同步阶段的 CPU 区间 | 不是所有业务逻辑，也不是 GPU 时间 |
| before/afterRendering | Qt 相关 CPU 回调区间 | 不自动等于完整驱动提交成本 |
| lastCompletedGpuTime | 启用时间戳后，最后可用的完成帧 GPU 区间 | 不保证对应当前录制帧，不代表逐通道耗时 [S2](#ref-s2) |
| frameSwapped 间隔 | Qt 信号间隔 | 不是像素真正被用户看到的间隔 |
| presentOne 的 presentMs | 从 endFrame 前的 restart 到返回后记账；与 endMs 重叠 | 不是独立 present-only，也不是扫描输出延迟 |
| Vulkan acquire 等待 | 交换链图像或帧槽可用性相关等待 | 不能单独归因于 GPU 算力不足 |
| RHINE_GPU_PROBE | 用 finish 排空后的受扰动样本 | 不能作为正常流水下的端到端 GPU 基准 |

定位：[FrameProfiler.cpp:80–178](../Qt/src/FrameProfiler.cpp#L80-L178)、[RhiScene.cpp:1843–1847](../Qt/src/RhiScene.cpp#L1843-L1847)、[PresentationShell.cpp:657–696](../Qt/src/render/PresentationShell.cpp#L657-L696)、[SceneLayerHost.cpp:447–459](../Qt/src/render/SceneLayerHost.cpp#L447-L459)。

**已确认的配置缺口：** [VulkanPresentationBackend.cpp:307](<../Qt/src/render/VulkanPresentationBackend.cpp#L307>) 仅传 EnablePipelineCacheDataSave；QRhi 时间戳须主动启用，硬件报告 Timestamps 支持并不充分。[S1](#ref-s1)[S2](#ref-s2) 建议仅在诊断模式附加 EnableTimestamps，并将“未启用/不支持/尚无样本”与真实 0 ms 区分。原生 Qt 路径要独立检查实际 RHI 配置，不能从此处反推。

**建议新增的观测：** CPU 构帧、元数据、实例打包、图层 polish/sync/render、提交、acquire、present-call 各自独立且有父子关系的区间；GPU 主几何、最终合成、AA/FSR、FG、UI 合成的区间；以 sceneFrameId / submitId / presentId 串联。记录每帧 draws、可见/剔除实例、上传字节、绑定/管线创建次数、纹理驻留、重建次数和 idle-fallback 次数。跨帧异步回收查询，不为读取性能结果添加每帧硬同步。

### 3.2 不把派生帧率当作交互性能

至少分列：真实场景帧率、生成帧数、提交成功率、呈现请求间隔分布、输入到场景采样时间。真正 input-to-photon 需要平台显示时序或外部光学测量；present 返回与交换链图像复用只能约束部分生命周期，不能证明像素显示完成。[S3](#ref-s3)

### 3.3 可复现实验约定

- Release/RelWithDebInfo；固定代码、GPU、驱动、Qt、分辨率和 DPR；记录平台为 Wayland/X11/Windows 及实际 present mode、交换链图像数。
- 每组预热至少 15 秒，稳定采样至少 60 秒，至少 3 次；这些是建议实验设计参数，不是项目已经执行的数据。
- 冷启动单列：应用缓存冷/热与驱动缓存状态分别记录；稳态不把首次编译和纹理装载混入均值。
- 以帧时间 p50/p95/p99、长帧数、CPU/GPU 忙闲与排队长度比较；不能用平均 FPS 掩盖卡顿。
- 常规基线关闭 RHINE_GPU_PROBE 和高频逐 draw 日志；验证层与 GPU capture 用于正确性/诊断，不与无调试开销的基线混比。
- 每次只改变一个因素；对确有强耦合的设置额外设计组合实验。质量、透明排序、运动矢量、色彩和输入延迟属于验收条件。

## 四、Vulkan 提交、同步与呈现优化

### 4.1 区分读回同步与离屏帧槽复用（P1，先测后改）

**现状：** [VulkanPresentationBackend.cpp:121–123](<../Qt/src/render/VulkanPresentationBackend.cpp#L121-L123>) 调用 beginOffscreenFrame；[164–179](<../Qt/src/render/VulkanPresentationBackend.cpp#L164-L179>) 安装信号量后 endOffscreenFrame，再 present。需要重绘的图层也各有 RenderControl begin/sync/render/end：[SceneLayerHost.cpp:358–407](<../Qt/src/render/SceneLayerHost.cpp#L358-L407>)。

**版本核查后的结论：** Qt 6.12 文档把离屏结束的同步等待限定在活动纹理/缓冲读回；官方 6.12 Vulkan 实现只在 readbacksPending 时立即等待提交 fence，无读回时轮换帧槽。beginOffscreenFrame 则先等待即将复用槽的命令完成。[S1](#ref-s1)[S9](#ref-s9) 所以“每次离屏结束都会排空 GPU”不成立，“离屏路径完全没有主机等待”也不成立。旧源码注释不能替代版本对应的实现。

应用显式读回定位于 [参考图渲染](<../Qt/src/RhiScene.cpp#L1976-L1985>) 与 [grabFrame 截图](<../Qt/src/render/PresentationShell.cpp#L1426-L1456>)，并非常规 presentOne 的每帧操作；截图/读回实验须单列。尚未验证本机 Qt 二进制的发行版补丁，官方分支源码不是本机二进制的逐字证明。

**验证/行动：** 标记各图层与最终合成的 begin/end、QRhi 槽 fence wait、桥接空提交及 GPU 队列。一个逻辑显示帧可能包含多个离屏提交，它们消耗同一 QRhi 的帧槽，等待可能落在下一层或下一次 begin。对比原生宿主与“强制可控宿主但关闭 FG”，确认提交开销、真实 CPU/GPU 重叠与 GUI 响应。

只有捕获证明提交粒度/槽等待是主瓶颈，才评估 Qt 支持范围内的帧集成、减少不必要提交或专用呈现线程。必须先设计 QML 同步、输入、资源所有权与恢复；不直接替换内部 API，不为读取 query 每帧 finish。

**验收：** p95/p99 与响应改善，无跨帧竞争、提前释放或队列无界积压；必要的资源复用等待并非可以一律删除。

### 4.2 保留正确生命周期，再评估空提交（P2）

[VulkanPresenter.cpp:888–908](<../Qt/src/fg/VulkanPresenter.cpp#L888-L908>) 用空提交把 acquire 信号量转成 Qt 可等待的 submitWaitSemaphore；947–956 注入 QRhi 等待/完成信号量。renderDone 按交换链图像索引分配/使用，方向符合 Vulkan 的 present wait semaphore 复用指导。[S3](#ref-s3)

潜在简化是让最终渲染直接等待 acquire，但**前提是能够证明 Qt 对 wait semaphore 的消费与 acquire 槽复用之间存在可靠完成信号**。目前槽 fence 只属于桥接空提交，并不等于最终渲染完成 fence。删掉空提交、只保留原槽 fence 会破坏这项证明；应把帧槽、渲染提交、present 图像生命周期分别画清。

不要按 frames-in-flight 索引无条件复用 renderDone，也不要把 present 返回视为等待信号量已在主机上完成。成功路径、漏 installSubmitParams、提交失败、OUT_OF_DATE、最小化和销毁都要验证。[S3](#ref-s3)[S4](#ref-s4)

### 4.3 硬同步回退与重建（P1/P2）

- present 的 forceIdle 或未安装提交参数路径会 vkDeviceWaitIdle（[VulkanPresenter.cpp:977–991](<../Qt/src/fg/VulkanPresenter.cpp#L977-L991>)）。这是兜底，不是正常路径优化。增加累计次数和原因，不要删掉同步来掩盖错误。
- backend resize 先 rhi->finish（[VulkanPresentationBackend.cpp:96–103](<../Qt/src/render/VulkanPresentationBackend.cpp#L96-L103>)）；FG resize 也会等待设备空闲（[FgBackend.cpp:611–614](<../Qt/src/fg/FgBackend.cpp#L611-L614>)）。检查同一尺寸事件是否触发多次排空/重复分配。
- 建议去重尺寸事件，零尺寸挂起，对短时间连续 resize 合并处理；以后若做旧资源延迟销毁，必须有覆盖渲染和呈现的完成依据。[S4](#ref-s4)
- present 对 SUBOPTIMAL 当次继续，但 acquire 的 SUBOPTIMAL 会设置 needsRecreate，下一次 acquire 在入口返回 OutOfDate：[VulkanPresenter.cpp:805–808](<../Qt/src/fg/VulkanPresenter.cpp#L805-L808>)、[884–886](<../Qt/src/fg/VulkanPresenter.cpp#L884-L886>)。所以“SUBOPTIMAL 完全不触发重建”的注释不能作为依据。记录原因与频率，区分兼容但非最优与必须恢复的 OUT_OF_DATE/SURFACE_LOST，不盲删重建。

### 4.4 交换链深度与屏障（P2）

交换链图像数、应用帧槽数和显示队列长度是不同参数。按 surface 能力与实际 present mode 做对比；更多图像可能缓解等待，也可能增加内存与排队延迟，不是越多越好。没有刷新率证据，不写死 16.67/8.33 ms 预算，不新增限帧策略。

finishTarget 明确负责 COLOR_ATTACHMENT_OPTIMAL → PRESENT_SRC_KHR 的外部屏障（[VulkanPresentationBackend.cpp:131–160](<../Qt/src/render/VulkanPresentationBackend.cpp#L131-L160>)）。优化之前先核对 QRhi/native layout 约定、生产者 access/stage 和首次 acquire 等待范围；UNDEFINED 仅适合确实丢弃旧内容的场景。不要仅凭“BOTTOM_OF_PIPE 看起来旧”就判错，也不要绕开 QRhi 的资源状态追踪。

## 五、CPU 构帧、可见性与 draw 提交

### 5.1 避免在“没有上传”时仍支付完整 CPU 构造成本（P1/P2）

**现状：** [Engine.cpp:650–718](../Qt/src/Engine.cpp#L650-L718) 已用场景签名和矩阵/主题缓冲比较识别稳定帧、复用休眠场景；[NativeSceneFrame.cpp:47–69](../Qt/src/NativeSceneFrame.cpp#L47-L69) 直接交付原生矩阵。渲染侧仍在 [RhiScene.cpp:1040–1094](../Qt/src/RhiScene.cpp#L1040-L1094) 每代构造实例 vector、打包 QByteArray，再进入差分比较。

**候选：** 从上游传递 geometry/material/transform/theme/resource 独立 revision；未变的 draw 保留实例数据与绑定，减少重复 QJson 字段读取、字节扫描和临时分配。先统计各阶段 CPU 时间、分配次数和实际变更率，再考虑 SoA、持久暂存数组或更细上传区间。并非删除所有 JSON 就能提高 FPS；小型元数据可能并非主耗时。

[dynamicBuffer 的现有实现](../Qt/src/RhiScene.cpp#L998-L1024) 已寻找共同前后缀、只上传一个变化区间。进一步把这个区间拆成多段，可能减少字节但增加更新命令；应比较“CPU 扫描 + 命令构建 + GPU 传输”的总成本，不单看上传量。

### 5.2 实例历史匹配同时影响画质和性能（P1）

[RhiScene.cpp:1047–1059](../Qt/src/RhiScene.cpp#L1047-L1059) 用上一帧矩阵的平移列字节作为 hash key；当前实例以相同字节找历史，未匹配则 previousModel 回退为当前模型。静态位置可匹配，但真实平移改变、浮点微差、同位置不同对象、排序变化都可能造成漏配或歧义。结果可能是对象运动矢量缺失或错配，并使 TAA/FSR/FG 质量评估失真。这是代码风险，不是本次已经复现的画面缺陷。

**方案：** 使用稳定的逻辑实例 ID（实体/格位/部件身份），将 current/previous transform 随实体生命周期维护；新生、传送、场景切换明确重置。不要退回按数组下标配对。以移动、滚动重排、对象新增删除、重叠位置为测试集，检查速度图，并比较 CPU hash/分配成本。

### 5.3 分层剔除与合批，先看规模（P2）

[NativeSceneUpdate.cpp:218–303](<../Qt/src/NativeSceneUpdate.cpp#L218-L303>) 的主列表已选择候选格位、视锥裁剪，并按相机距离稳定地前到后重排实例；[NativeSceneFrame.cpp:118–142](<../Qt/src/NativeSceneFrame.cpp#L118-L142>) 还对选中/归位 actor 做视锥球测试。主体豁免和 shadow-only 保留是语义，不应直接删除。应先量“候选 / 可见 / 被保留 / 提交实例数”、排序及缓冲重排成本，再判断更精细包围体、增量排序或屏幕尺寸 LOD 的价值。

主列表已有前到后实例排序；进一步只在兼容材质与状态内调整深度桶和管线/绑定排序的关系，作为 overdraw 与 CPU 状态切换的权衡实验，不重复计功。透明对象必须保持当前层次/混合语义；不能把透明壳体按管线全局重排来追求 draw 数。预深度通道也会增加几何与带宽，只有像素成本确实占优时才值得试。

[geometry()](../Qt/src/RhiScene.cpp#L1255-L1340) 的状态去重已在 Linux 生效；其他后端可先做等价移植实验，而非宣称此项尚未实现。当前实例顶点绑定仍使用 offset 0；存在 arena 字段/注释不等于一个已启用的全局实例 arena。若 draw 规模和驱动开销不高，不优先引入 indirect、bindless、mesh shader 或 GPU-driven 大改。

## 六、GPU 像素链路、后处理与渲染目标

### 6.1 无时域需求时，运动附件与历史应可被剔除（P1）

[RhiScene.cpp:529–575](../Qt/src/RhiScene.cpp#L529-L575) 的 Linux 单采样分支会配置 RGBA16F motion texture；[ScenePostProcess::needsMotion()](../Qt/src/render/ScenePostProcess.cpp#L65-L71) 则表达“时域 AA 或 FG 才需要 motion”。应把附件、MRT 管线变体、previousModel 属性、历史缓存和输出发布作为一组条件化，而非只停止读取附件。开关变化必须触发资源/管线一致重建并重置历史。

可以继续验证仅需两个分量时使用 RG16F；先核查 QRhi 渲染附件、FFX 导入格式、采样 swizzle 和各后端支持。MSAA 路径、深度可采样性、resolve 及 FG 输入也必须覆盖，不能把单采样条件直接推广为所有模式。

**容量示例，非实测带宽：** 单张 1920×1080 RGBA16F 约 15.82 MiB，RG16F 约 7.91 MiB，D32F 约 7.91 MiB。主颜色 + 深度 + RGBA16F 运动附件的基础容量约 39.55 MiB；不含对齐、MSAA、历史、UI、交换链和 FFX 内部资源。减少附件容量不等于每帧等量外存流量，缓存/压缩/可见覆盖会改变结果。

### 6.2 盘面模糊存在明确的零半径快路径候选（P1，局部低风险）

[opticalSurface.frag:172–194](../Qt/shaders/enhancement/opticalSurface.frag#L172-L194) 的盘面分支，源码上是中心 1 次加两圈各 8 次封面采样。当 blur=0，所有 UV 相同，权重总和为 20，数学结果退化为一次采样；可用材质级统一快路径或着色器变体免去这段重复工作，保留 blur>0 的效果。

这不是“必定获得 17 倍性能”：驱动可能合并部分采样，纹理缓存也会改变实际代价；还存在其余着色、覆盖率与整个帧的成本。验证编译后着色器、GPU pass 时间、分支一致性、纹理导数和浮点容差。盘面占屏小的场景收益可能很小。

### 6.3 最终九点柔化、透明覆盖与颜色复制（P1/P2）

- [opticalFinalFragment.frag:8–24](../Qt/shaders/enhancement/opticalFinalFragment.frag#L8-L24) 固定九点取样再做颜色输出。soften=0 仍使用 1 texel 偏移，因此不是恒等操作；改成单采样是质量/风格选择，不能当无损消冗余。可比较原实现、受控质量档位和预滤波方案。
- [opticalSurface.frag:99–168](../Qt/shaders/enhancement/opticalSurface.frag#L99-L168) 包含 alpha hash 与透明壳体逻辑。先看像素覆盖、shader 时间和混合层数，评估远处简化、不可见背面、薄层表示；不凭“看起来像玻璃”假设它实现了昂贵屏幕空间折射或光追。
- [ScenePostProcess.cpp:207–251](../Qt/src/render/ScenePostProcess.cpp#L207-L251) 中 TAA/compute FSR 后有显式输出复制，空间回退还有 EASU/RCAS。可通过直接把最终纹理交给消费者、减少不必要中间目标，验证能否省一次全屏读写；需保持输出尺寸、采样、alpha、色域和所有权。FSR 输入与输出不能简单别名为同一资源。[S5](#ref-s5)
- 不盲目交换 tone mapping、AA、FSR 与锐化顺序。先画明线性/HDR、显示参考编码、预乘 alpha 的边界，按锁定 SDK 的输入契约做画质 A/B；能少一个 pass 不等于结果等价。

### 6.4 内部尺寸是高杠杆驱动，但不等于免费提速（P1）

[ScenePostProcess.cpp:28–49](../Qt/src/render/ScenePostProcess.cpp#L28-L49) 的内部尺寸系数由 supersample × renderScale × aaScale ÷ FSR divisor 共同决定。必须记录最终实际 renderSize/displaySize/DPR，而非仅看“FSR Quality”名字；叠加 SSAA 或 supersample 可能抵消降分辨率。

纯尺寸数学上，单轴降到 1/1.5 后像素面积约为 44.4%；这是像素数量变化，不是预测整帧时间下降 55.6%。若 CPU 提交或同步受限，FSR 固定开销甚至可能令净收益为负。以原生、空间 AA、TAA、FSR 实际后端/质量分别比较；动态分辨率仅作后续可选方案，应使用稳定 GPU 时间与迟滞，避免 resize/context 抖动及画质波动。

## 七、资源、内存与冷启动

### 7.1 把图片加工移出渲染关键路径（P1/P2）

[updateMusic()](../Qt/src/RhiScene.cpp#L794-L844) 会生成标签、缩放封面并上传；[uploadMipped()](../Qt/src/RhiScene.cpp#L277-L290) 在 CPU 逐层缩放 mip。频繁换曲、快速浏览或缓存淘汰后重访时，这些工作可能形成长帧，需以“缓存 miss / 图片加工 / 上传入队 / 首次可见”分段测量。

建议在可安全使用的工作线程提前完成 QImage 解码、裁切与 mip 数据，向渲染线程发布不可变结果和 revision；GPU 对象创建/更新留在所属线程。字形生成须单独审计字体与绘制对象的线程限制，不能把整个 glyph 对象未经检查搬线程。可用占位图并限制每帧上传预算，但必须明确首屏质量/就绪延迟的取舍。

### 7.2 先补全驻留账本，而不是再加一个缓存（P2）

音乐贴图已有约 64 MiB 预算与 32 key 条件，按 revision 共享封面，并保护活动对象不被驱逐：[RhiScene.cpp:84](../Qt/src/RhiScene.cpp#L84)、[783–878](../Qt/src/RhiScene.cpp#L783-L878)。这是局部预算，活动集合过大时允许越过阈值；也不是整进程 GPU 占用上限。

账本应分列：活动/非活动标签封面、共享去重后字节、待上传、待退休、场景附件、时域历史、FG 内部资源与交换链。压力下先清非活动对象，设置回收迟滞，记录重新上传率，避免“预算更小但抖动更大”。现有 retire() 使用 QRhi deleteLater，不要以优化名义改成即时 delete 造成 GPU 悬空引用：[RhiScene.cpp:772–792](../Qt/src/RhiScene.cpp#L772-L792)。

### 7.3 UMA、staging、压缩与 load/store 的边界（P2）

- 当前烘焙表面已有 BC7 支持检查与 RGBA8 回退；三维光场与法线也已有专用表示：[RhiScene.cpp:356–380](../Qt/src/RhiScene.cpp#L356-L380)。不要把再次“启用 BC7”记为新优化。动态封面的压缩要算 CPU 编码、缓存与质量代价，不宜在 render 线程即时重压。
- UMA 可能允许适合的 host-visible/device-local 缓冲直写，但不代表所有 optimal-tiled 图像都能零拷贝、所有 staging 都应移除。离散显存、可映射性、缓存策略与 QRhi 的分配实现不同。先减少应用层重复字节构造/搬运，再用捕获证实底层上传瓶颈。[S6](#ref-s6)
- 对只清不读的附件避免无谓保留，对后续消费者需要的颜色/深度/motion/history 必须 store。tile-based GPU 的 transient/subpass 机会要单列；桌面 iGPU 不能一概按移动 TBDR 推理。先检查 QRhi 支持的 pass/附件表达，再考虑后端专用实现。[S7](#ref-s7)

### 7.4 管线缓存已做，后续盯住建管线长尾（P2）

QRhi 缓存与 FFX 原生 compute cache 分开。[cmake/FidelityFX.cmake:139–157](../cmake/FidelityFX.cmake#L139-L157) 注入缓存补丁；[448–460](../cmake/FidelityFX.cmake#L448-L460) 指向生成的兼容源码。修改 vendored 原文件却不核对实际编译路径，可能没有效果。

测量首次出现材质、首次开启 FSR/FG、切质量和 resize 时 pipeline 创建次数与耗时；优先提前创建实际会用的变体，避免无界预热。检查按设备/驱动兼容识别、缓存读写失败恢复和退出持久化。旧报告的简单 compute 合成微基准只说明该样例冷热差异，不能换算成 FSR 全场景 FPS；既有 QRhi 三次启动记录也没有证明稳定收益，详见 [既有实施记录](vulkan-igpu/06-implementation.md)。

## 八、FSR、运动数据与 FG 的性能—质量联动

### 8.1 先确认实际后端，再修契约（P1）

**关键默认值：** [Fsr3Backend.cpp:315–320](<../Qt/src/fsr/Fsr3Backend.cpp#L315-L320>) 在 Vulkan 上默认禁用 FFX compute，只有 RHINE_FSR3_FFX=1 才尝试；未启用/不可用时走空间 EASU/RCAS 回退。因此选择 FSR 模式不等于实际运行时域 FSR3。日志须分列请求模式、实际后端和回退原因。下列时域契约针对实际启用且可用的 compute 路径；FG 有独立开关，不与超分后端可用性混为一谈。

1. **单位：** [opticalGeometry.vert:40–46](../Qt/shaders/enhancement/opticalGeometry.vert#L40-L46) 从未抖动 VP 求 previous-current 并乘 0.5、翻转 Y，输出 UV 范围的位移；[Fsr3Backend.cpp:567–571](../Qt/src/fsr/Fsr3Backend.cpp#L567-L571) 和 [FgBackend.cpp:990–1003](../Qt/src/fg/FgBackend.cpp#L990-L1003) 再乘 renderSize 转成像素。源码注释将其简称 NDC，但不能据此再添加一个 0.5。仍需按 framebuffer 方向、clip correction、jitter 与消费者约定做带已知像素位移的测试。[S5](#ref-s5)
2. **身份与历史：** 前述稳定实例 ID 应先于时域质量评估。相机切换、resize、AA/FSR 模式变化、隐藏恢复和新实例必须有明确 reset；当前 FSR resize 已有尺寸/模式等值保护，不能误报成每帧重建。[Fsr3Backend.cpp:320–333](../Qt/src/fsr/Fsr3Backend.cpp#L320-L333)
3. **透明：** [Fsr3Backend.cpp:560–593](../Qt/src/fsr/Fsr3Backend.cpp#L560-L593) 的 dispatch 未赋 reactive / transparencyAndComposition。官方允许缺失 reactive 时使用零值默认，但对透明与动画材质建议提供合适掩码。玻璃壳、盘面、标签须做重影/闪烁实验；掩码也有通道和计算成本，不是无条件性能优化。[S5](#ref-s5)
4. **版本：** 以仓库锁定的 SDK 头文件/实现为准，官方网页可能覆盖较新补丁版；本报告不建议为追逐版本号直接升级，也不把新版修复当作当前应用已具有的能力。

### 8.2 FG 的优化目标不是单个大 FPS 数（P1/P2）

[PresentationShell.cpp:813–905](../Qt/src/render/PresentationShell.cpp#L813-L905) 已将插值与真实帧分成相邻调度步，一步一次 present；插帧前检查场景确实重渲，UI 单独更新不会重复插同一场景。保持这个约束，分别记录真实帧新鲜度、生成成功/失败、API 呈现请求数与输入采样延迟。新场景帧率下降而生成请求翻倍，不应被称为交互性能翻倍。

[FgBackend.cpp:972–1027](../Qt/src/fg/FgBackend.cpp#L972-L1027) 先做 optical flow 与 prepare，后续 dispatch 又有独立工作。分别打 GPU 区间，确认输入纹理与布局、reset、失败后的 frameID 和输出消费；不要把这些计算都算进 present-call。UI 应保持独立真实渲染/叠加，不随场景历史扭曲。

先确认同队列集成正确性，再考虑 async compute。当前 FG 与合成位于一个 QRhi 离屏帧，机械地增加 compute queue 会引入所有权、跨队列同步和资源存活问题，且未必有空闲算力可重叠。AMD 的 FSR 3.1 集成概览第 53 页也建议先禁用异步来验证质量；其当前手册要求 profile 后再判断异步收益。[S5](#ref-s5)[S8](#ref-s8)

### 8.3 静态缓存与真实呈现的口径（P1）

[PresentationShell.cpp:754–803](../Qt/src/render/PresentationShell.cpp#L754-L803) 已提供 content-only/always-present 实验开关，但默认仍可重复呈现缓存。缓存纹理重复 present 能提高请求计数，不增加场景信息；是否保留由平滑性、事件及时性与实际显示行为决定，不能单凭 presented/s 更大判胜。

事件驱动优化必须覆盖异步模型/图片就绪、字体、动画、输入、resize、设备恢复和时域收敛。Engine 已有稳定判定与有限时域收敛帧：[Engine.cpp:700–759](../Qt/src/Engine.cpp#L700-L759)。保留诊断看门狗并记录原因，逐步证明可以去掉高频兜底；不要把旧代码“必须每 tick 渲染”的注释当永恒约束，也不要在事件链未完整前直接删除。

## 九、实施优先级与验收表

以下是建议实施清单，**本次均未修改运行代码**。S/M/L 为相对复杂度，不是工期承诺；收益范围描述作用机制，不是已测百分比。

| ID | 优先级 / 复杂度 | 行动 | 可能改善 | 主要风险 / 验收证据 |
| --- | --- | --- | --- | --- |
| A01 | P0 / S–M | 时间戳启用、计时去重、贯穿 frame ID | 避免误判、形成基线 | GPU 有效样本状态明确；end/present 不重复相加 |
| A02 | P1 / M；改架构另评估 | 捕获多离屏提交与槽复用等待，有证据再改架构 | CPU/GPU 重叠、提交开销、GUI 响应 | 区分 readback/end 与 slot/begin 等待；队列轨迹与 p95/p99 |
| A03 | P1 / M | 统一图层 dirty / resource revision / 时域收敛 | 无变化时减少重绘与构帧 | 资源异步到达、恢复、动画均不丢更新 |
| A04 | P1 / M | 稳定实例 ID 维护 previous transform | 降 hash 分配、修时域输入 | 重排/移动/重叠/新生速度图正确 |
| A05 | P1 / M | 无需求时剔除 motion MRT 和历史 | 附件/上传/顶点与像素带宽 | AA/FG/MSAA 切换、深度和格式都正确 |
| A06 | P1 / S | blur=0 盘面单采样变体 | 局部纹理采样成本 | 编译结果、特写/远景 pass 时间与图像误差 |
| A07 | P1/P2 / M | 复用最终颜色纹理，评估九点柔化质量档 | 全屏 pass 与像素成本 | alpha、色域、FSR 输入输出不别名 |
| A08 | P1/P2 / M | 图片/mip 预处理与上传预算 | 换曲/浏览长帧 | 首次可见延迟、p99、缓存 miss 轨迹 |
| A09 | P2 / S–M | 其他后端移植状态去重，缓存 draw 元数据 | CPU 驱动/构帧开销 | 同画质 draw 状态计数、CPU profile |
| A10 | P2 / M | resize 去重、分离渲染/呈现退休证明 | 窗口交互停顿 | 重建次数、stall、验证层与恢复测试 |
| A11 | P2 / M | 局部预算升级为整帧资源账本 | 驻留压力、抖动定位 | 峰值字节、活动豁免、重传率 |
| A12 | P2/P3 / M–L | LOD/深度预通过/indirect/async 专项实验 | 仅对已确认瓶颈有效 | 先确认规模/overdraw/空闲引擎，再决定投入 |

推荐最小顺序：A01 → 原生/强制宿主对照 → A02 结论 → A04/A05/A06 的独立 A/B → A03/A08 长帧治理 → 其余按 profile 排序。不要将 A02 架构改造作为所有局部优化的前置阻塞。

## 十、可复现实验矩阵与交付标准

### 10.1 分组与场景

| 轴 | 必需控制组 | 记录与注意 |
| --- | --- | --- |
| 宿主 | 原生 FG off；强制可控宿主 FG off；同宿主 FG on | 分离宿主代价与 FG 算法代价 |
| 后处理 | off/空间 AA/TAA/实际 FSR 后端与质量 | 固定 displaySize、记录 renderSize、MSAA/DPR |
| 内容 | 静止档案墙、连续滚动、抽取归位、盘面特写/旋转、封面切换 | 同轨迹、同音乐数据、同缓存冷热 |
| 生命周期 | 连续 resize、最小化恢复、跨 DPR、模式切换、资源异步完成 | 检查卡顿/闪烁/黑屏/重建风暴 |
| 设备 | 实际目标 iGPU；若支持，再加 dGPU/其他平台 | 不拿不同设备绝对 GPU query 值直接排优劣 |
| 质量 | 同镜头截图 + 运动序列/速度图 | 色彩、模糊、透明顺序、重影、锯齿与 UI 稳定 |

### 10.2 最小数据记录

每个样本保存：代码与配置哈希、Qt/SDK/驱动/GPU、窗口系统、显示/内部尺寸、缓存状态、采样时长；CPU 帧时间/阶段、GPU 完成帧与通道时间、scene/submit/present ID、真实/生成/重复请求、长帧、重建/回退、上传/驻留、draw 与可见数。现有 --frame-profile 适合起点，但 GUI 收集和渲染计数是异步快照，不能默认一行所有字段来自同一帧：[FrameProfiler.cpp:157–178](../Qt/src/FrameProfiler.cpp#L157-L178)。

### 10.3 验收与回滚

- **正确性：** 验证层无新增同步/生命周期错误；无黑图、丢更新、错误速度和无界资源增长。capture/验证层单列，不污染正式性能组。
- **性能：** 每项报告基线/改动 p50/p95/p99、样本数与多次波动；收益超过实验噪声才保留，CPU/GPU/队列三者解释一致。未测试处标为“未测”，不填估算 FPS。
- **质量与体验：** 同镜头及动态序列比较；降低质量的选项明确分档，不能作为同等质量提速；输入延迟不能仅由 present 返回推导。
- **可回滚：** 每项单独开关/提交，保留原路径，失败回退有计数；先低风险局部改动，再碰线程、提交与队列重构。

### 10.4 证据置信度与待补信息

**已确认：** 路径分叉、离屏 API 使用、时间戳配置缺口、endMs/presentMs 重叠、已有优化、实例平移 hash、motion 附件、固定采样、输出复制、缓存和尺寸保护，都能由本文链接定位。

**尚未确认：** 目标设备上的首要瓶颈、多离屏提交/帧槽等待占比、shader 编译后采样是否合并、各 GPU 格式收益、端到端显示延迟、各项实际 FPS/长帧改善。下一轮需要固定硬件与轨迹的 CPU/GPU capture、基线 CSV 和画质序列；本报告没有用静态推断冒充这些测量。

## 参考资料

本地源码是“当前工程做了什么”的证据；下列官方资料用于核对 API/集成契约，访问日期为 2026-10-30。网页版本不自动代表仓库锁定的 SDK 版本。

- <a id="ref-s1"></a>**S1 Qt 6.12 QRhi**：[类文档](https://doc.qt.io/qt-6/qrhi.html)，重点 begin/endOffscreenFrame、flags、资源和调试标记。
- <a id="ref-s2"></a>**S2 Qt 6.12 QRhiCommandBuffer**：[lastCompletedGpuTime](https://doc.qt.io/qt-6/qrhicommandbuffer.html#lastCompletedGpuTime)，重点 EnableTimestamps 与完成帧关联；[QQuickRenderControl](https://doc.qt.io/qt-6/qquickrendercontrol.html) 用于受控宿主生命周期核对。
- <a id="ref-s3"></a>**S3 Khronos Vulkan Guide**：[Swapchain Semaphore Reuse](https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html)，重点按图像索引管理 present wait semaphore，以及 submit fence 与 present 完成的区别。
- <a id="ref-s4"></a>**S4 Khronos Vulkan Samples**：[Swapchain Recreation](https://docs.vulkan.org/samples/latest/samples/api/swapchain_recreation/README.html)，重点旧交换链与呈现资源的安全退休。
- <a id="ref-s5"></a>**S5 AMD GPUOpen**：[FSR 3 Upscaler 手册](https://gpuopen.com/manuals/fidelityfx_sdk/techniques/super-resolution-upscaler/) 及 [FSR 3.1 集成概览](https://gpuopen.com/presentations/2024/FidelityFX_Super_Resolution_3-1_Release-Overview_and_Integration.pdf)，重点 motion 空间、掩码；集成概览第 17 页明确输入/输出资源独立，第 53 页说明先禁用异步验证质量。
- <a id="ref-s6"></a>**S6 Khronos Vulkan Guide**：[Memory Allocation](https://docs.vulkan.org/guide/latest/memory_allocation.html)，重点内存管理基础；另见 [VMA 内存类型选择](https://gpuopen-librariesandsdks.github.io/VulkanMemoryAllocator/html/choosing_memory_type.html)，核对集成/离散 GPU 与 staging 选择。
- <a id="ref-s7"></a>**S7 Khronos Vulkan Samples**：[Using pipeline barriers efficiently](https://docs.vulkan.org/samples/latest/samples/performance/pipeline_barriers/README.html)，重点真实依赖与 stage 范围；附件另参见 [Appropriate use of render pass attachments](https://docs.vulkan.org/samples/latest/samples/performance/render_passes/README.html)。不把移动端样例收益推广至本项目。
- <a id="ref-s8"></a>**S8 AMD GPUOpen**：[FSR 3 插帧集成手册](https://gpuopen.com/manuals/fidelityfx_sdk/techniques/super-resolution-interpolation/)，重点 UI、frame ID、异步队列性能与资源存活；不把官方代理交换链的机制当作当前自建 presenter 已经具备的能力。

- <a id="ref-s9"></a>**S9 Qt 官方 6.12 分支源码**：[QRhi Vulkan 后端](https://raw.githubusercontent.com/qt/qtbase/6.12/src/gui/rhi/qrhivulkan.cpp)，定位 waitCommandCompletion / beginOffscreenFrame / endOffscreenFrame；核查读回等待与无读回帧槽轮换。分支可变，本机二进制补丁须独立确认。
