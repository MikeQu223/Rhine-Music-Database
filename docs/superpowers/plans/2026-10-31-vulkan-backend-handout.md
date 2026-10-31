# Vulkan 后端优化 Handout（D 系列）

2026-10-31｜交接给 A／B／C 实施者｜基线 perf/lts，2ec3ce4（C01–C04 已提交）。

**目标：** 减少真实 Vulkan 资源／描述符／上传／附件开销，不再重复 C 系列 JSON 装配、Qt 同步和引擎节拍优化。
**方式：** 应用侧先经 QRhi 的受支持接口做优化；Qt Vulkan 后端补丁只作有证据的独立实验。不重写原生 Vulkan 渲染器，不预报提速百分比。
**状态：** 本文件仅为计划；未修改运行代码、启动 GUI 或执行 GPU 基准。旧 n=2 数据早于 C 落地，不能直接作 D 的新基线。

## 已核实的边界

- Linux 普通窗口、FG 关闭时走 QQuickWindow／QQuickRhiItem，受控宿主须 RHINE_FG_LAYER=on 才强制进入：[main.cpp](../../../Qt/src/main.cpp#L569)。默认路径不经过自建 VulkanPresenter；不能把改它的 submit／present 算作普通滚动收益。
- C02 已复用材质解析，几何提交已有管线／SRB 去重；A05 已按需求裁掉 motion MRT，时间戳与管线缓存也已有配置，不重复记功。
- 仍存在每材质独立 Dynamic UBO：[prepare](../../../Qt/src/RhiScene.cpp#L1780)；实例缓冲仍按 draw／batch 管理。geometry 实际仍绑定 {draw.instances, 0}，instanceOffset／arenaBuffer 的声明或注释不代表 arena 已落地：[geometry](../../../Qt/src/RhiScene.cpp#L1950)。
- Qt 6.12 Vulkan 的 Dynamic buffer 本已走 CPU_TO_GPU 分配、按帧槽管理且通常持久映射；“再加持久映射”不是新增机制。应用现用的 [dynamicBuffer](../../../Qt/src/RhiScene.cpp#L1578) 仍需字节比较和 updateDynamicBuffer 中间更新路径，优化对象是其调用／复制／资源数量，而非凭空消灭 Vulkan map。[S1](#ref-s1)[S2](#ref-s2)

## D01：先建立 Vulkan 资源账本，不扩成新探针工程

位置：[RhiScene.cpp](../../../Qt/src/RhiScene.cpp)、[main.cpp](../../../Qt/src/main.cpp#L677)；QRhi 不能直接暴露的原生计数由用户手工 capture 或独立后端统计取得。

- [x] 新增 RHINE_VK_RESOURCE_PROBE=1，按共同窗口记录活跃 Dynamic UBO／实例 buffer 数、容量／有效字节、更新次数与复制字节、SRB 创建／绑定次数、pass 数与深度 store 策略；创建次数与稳态存量分开，复用现有计时与资源账本。
- [x] 启动记录实际 backend／宿主、Qt 版本／库来源、GPU／驱动和有效时间戳状态。只在 Vulkan 默认路径评价本轮收益；固定 C 功能、AA、尺寸、DPR、轨迹和冷热缓存。
- [x] 用户 capture 时核对实际 VkBuffer／descriptor set 分配与更新、vkCmdBindDescriptorSets、pass 和 barrier；应用侧 setShaderResources 次数不等于 vkUpdateDescriptorSets 次数。CPU 墙钟、GPU 时间及等待分别解释，不推算“GPU 利用率”。

## D02：材质 UBO 合并＋动态偏移＋按纹理组合复用 SRB（优先）

位置：[prepare／SRB](../../../Qt/src/RhiScene.cpp#L1780)、[geometry](../../../Qt/src/RhiScene.cpp#L1926)、[pipeline](../../../Qt/src/RhiScene.cpp#L1467)。先保留 batch 更新模式，只改变资源组织，以便独立验收。

实施：`Qt/src/render/VulkanResourcePolicy.h`（纯算术）、`RhiScene.cpp` 的 `MaterialArena`／`materialBindingsFor()`／`arenaMaterial()`；默认关闭，`RHINE_VK_UNIFORM_ARENA=1` 才启用，任何一步不满足就永久退回逐材质 buffer。[S3](#ref-s3)

- [x] 将本帧 Surface 打包进少量 Dynamic uniform arena，绑定 1 改用 uniformBufferWithDynamicOffset；offset 按 rhi->ubufAlignment()／ubufAligned()，不硬编码 256。每次绑定的 range 为 Surface 大小，而不是整张 arena；检查绑定 range ≤ MaxUniformBufferRange、offset＋range ≤ buffer 容量及整数溢出；MaxUniformBufferRange 限制单次暴露范围，不是整个 arena 总大小。仅资源／offset 表示超限时分块／回退。
- [x] 共用同 arena、global UBO、图集、label／cover 和 sampler 的 draw 复用 SRB；缓存 key 包含完整资源身份／代号、布局及 arena 代号，不含本次材质 offset。不要跨不同纹理组合错误合并，也不要跨设备复用；限制缓存规模、失效后安全退休。
- [x] 改成共享后同步调整所有权：当前材质淘汰循环与纹理失效路径会直接 retire(state.bindings／state.uniform.buffer)，不能原样用于共享 SRB／arena。材质槽只持共享句柄，缓存／arena 统一回收；一个 draw 淘汰不得使其他 draw 悬空，used 保活、纹理释放和设备销毁均覆盖。
- [x] draw 保存 materialOffset；绑定去重改成“SRB＋动态偏移＋当前布局状态”一起判断。SRB 指针相同但 offset 不同仍必须 setShaderResources；管线／布局切换时按兼容性正确重绑，不沿用旧去重假设。
- [x] 核对 pipeline key／pipelineLayouts 对静态 UBO 与动态 UBO 的原生布局区分；改模式时重建对应布局／管线，不能只换 SRB。arena 扩容时重绑所有引用，新旧资源存活遵循 QRhi；先规划本帧容量，避免录制后再改已用字节。
- [x] 保留稳定材质少更新的优势；不要因为共用一个 buffer 每 draw 重写同一位置。验收看原生 buffer／descriptor 数、更新与绑定成本及帧间隔；动态 offset 本身也可能有 CPU 成本，无收益就回退。

## D03：实例 buffer 池化与全量直写，分两步 A/B

位置：[instance／dynamicBuffer](../../../Qt/src/RhiScene.cpp#L1578)、[batchInstances](../../../Qt/src/RhiScene.cpp#L1834)、[geometry](../../../Qt/src/RhiScene.cpp#L1950)。D02 不作为必需前置；先做可独立验证的资源池化，再试直写。

实施：`RHINE_VK_INSTANCE_ARENA=1` 把逐 draw／逐批次 Dynamic VertexBuffer 收进一张池（`poolInstances()`，偏移 4 字节对齐、内容或落点变化才上传、失败退回落单 buffer）；`RHINE_VK_DIRECT_WRITE=1` 对材质 arena 试整块直写（`beginMaterialArenaWrite()`，本帧写满每个槽位、录制前结束、映射失败即回退）。实例 VertexBuffer 的整块直写按计划留给 Qt 6.12 Vulkan 实现核实，本轮不做。运行时差分与连续多帧相同内容的用例在 D06 的策略测试里覆盖。[S1](#ref-s1)[S2](#ref-s2)

- [x] 第一步：对最终不透明／透明列表的实例字节分配少量 Dynamic VertexBuffer arena，记录 buffer＋byteOffset＋实例数；所有消费者实际使用 offset，不只填字段。保持实例 stride、当前／上一帧矩阵、顺序与 batch 去重，检查溢出与边界；motion／独立速度通道和诊断读取也须正确，不能只修主 geometry。
- [x] 保留现有 batch 更新，比较有效字节／容量、更新命令、CPU 与资源数。容量分档增长、有界回收，禁止同一帧多次覆盖已被前面 draw 读取的区域；不以 pooling 名义改变 draw 顺序或材质。
- [x] 第二步：先在中大型动态 UBO 上试 beginFullDynamicBufferUpdateForCurrentFrame／endFullDynamicBufferUpdateForCurrentFrame；每个被使用的录制帧均写全当帧读取范围，在任何依赖 pass 前结束。实例 VertexBuffer 直写另作 Qt 6.12 Vulkan 实现核实后的可选实验，不假定所有后端均支持相同行为。
- [x] 同一 buffer 对象不混用直写和 ResourceUpdateBatch／读回；静止时也不能因 CPU 字节没变跳过直写，否则下一个 QRhi 帧槽可能读旧值。Qt 管理 map／flush／帧槽，不能用应用帧号模拟槽或自行销毁 Qt 内部 VkBuffer。
- [ ] 映射失败／模式切换以新 buffer 和正确重绑回退到 batch 路径，绝不在原对象上临时混两种更新模型。新增测试覆盖连续多帧相同内容、第三帧后再变化、扩容／空列表／隐藏恢复；全量多写和 flush 成本可能抵消收益，需保留差分路径作对照。

## D04：无后续深度消费者时不 store 深度（低复杂度候选）

实施：`RHINE_VK_DISCARD_UNUSED_DEPTH=1` 才启用；`RhineRender::depthStoreRequired()` 给出保守消费者表（FSR/FG 配置、时域 AA、warp 探针任一存在就照旧 store），策略只随 resize 变，并写进早退比较。剩余那条要看用户 capture 里的 storeOp 与 GPU 时间，应用侧只如实记 `depthStorePasses` / `depthDiscardPasses`。

位置：[makeTarget／resize](../../../Qt/src/RhiScene.cpp#L672)、[publishMotionInputs](../../../Qt/src/RhiScene.cpp#L2118)、[ScenePostProcess](../../../Qt/src/render/ScenePostProcess.cpp#L248)。[S4](#ref-s4)

- [x] 先做保守消费者表：AA off／空间 FXAA／MSAA 且无其他读取可选“不存”；TAA／FSR／FG／warp／未知诊断需求先保留。FSR 能力运行期变化时不逐帧翻策略，按配置保守判定；不能从“FG 下线”推断所有深度都无人读。
- [x] 无消费者时保留 D32F 深度测试／清除，只给主纹理 RT 添加 QRhiTextureRenderTarget::DoNotStoreDepthStencilContents；需要 store 时恢复。标记必须在 compatible render-pass descriptor 创建前设置；策略变动进入 resize／布局失效条件。
- [x] 初轮不改成可能不同精度的 D24S8，不强制 renderbuffer，也不改 HDR 颜色格式。被后续采样的 color／motion／history 仍须 store，不能把 PRESERVE、DONT_CARE 与丢弃旧内容混为一谈。
- [ ] 对比实际 render-pass depth storeOp、GPU 时间与帧间隔；Intel 桌面 iGPU 不按移动 tile GPU 推定收益。模式切换、MSAA、resize、参考图／时域重置正确性全部保留。

## D05：Qt Vulkan 后端专项，只有 capture 命中才做

实施结论：**暂缓，证据不足**。本轮没有拿到用户侧的 Vulkan capture（帧分析器／验证层记录都没有），而应用侧账本显示纹理上传只发生在冷加载与准入换绑时（静止段 5.33 MiB 全程一次量级），持续滚动阶段的上传与 barrier 都不构成可观测长帧来源；按计划不为了完成清单给 Qt 打补丁。D01 的 `VulkanResourceWindow` 已能区分“上传/绑定/绘制”三类计数，后续拿到 capture 再按门槛重开。


独立 Qt 源码 worktree／补丁，不直接改系统安装；记录与当前 Qt 6.12 二进制对应的 revision 和构建参数。网页分支源码可变，不等于本机二进制。[S2](#ref-s2)

- [ ] **staging 池实验门槛：** 仅当纹理上传期间的 vmaCreateBuffer／destroy、map／flush 成为明确长帧来源时，试按已完成提交安全复用的 staging slab／ring。Qt 当前上传路径有“no reuse of staging, this is intentional”注释，先查清原因、回收／flush／offset 对齐和所有 subresource 拷贝；不能仅按应用 frameIndex 重用，也不能把逻辑取消当 GPU 已完成。
- [ ] **barrier 实验门槛：** 仅当队列捕获证明过宽 stage／access 或多余 layout 往返阻断依赖以外的重叠，才在完整资源追踪内收窄／合并。保留 RAW/WAR/WAW、host flush、attachment→sample、transfer→sample 依赖，验证多个纹理／帧槽／pass；不在应用层盲插 native barrier 绕开 QRhi。
- [x] 未命中门槛，交回“暂缓，证据不足”即完成本项，不为了完成清单给 Qt 打补丁。纹理准入后上传已经很小，staging 可能只改善冷加载长帧，并非持续滚动。

## D06：测试、独立开关与交付

实施：`Qt/tests/VulkanResourceChecks.cpp` 8 组共 57 项断言，已注册 `RhineVulkanResourceRegression`／`qt_vulkan_resource_regression`（Qt6::Core，不建 QGuiApplication、不碰 VkDevice）。四个开关都是 opt-in 且只在 Vulkan 路径读：`RHINE_VK_UNIFORM_ARENA`（D02）、`RHINE_VK_INSTANCE_ARENA`／`RHINE_VK_DIRECT_WRITE`（D03，两步各自独立）、`RHINE_VK_DISCARD_UNUSED_DEPTH`（D04）；关掉即回到原来的逐材质 uniform buffer／逐 draw 实例 buffer／照旧 store 深度。定向构建与测试已跑：四个目标增量编译通过，`ctest -R '^qt_(vulkan_resource|render_policy|music_texture_admission|frame_pacing)_regression$'` 4/4 通过；主程序只做编译验证、没有运行。**功能完成，性能待验**：应用侧只有计数（创建／更新／绑定／跳过／上传字节），没有硬件时间，任何“变快了”的说法都还没有证据支撑。


新增纯策略文件 `Qt/src/render/VulkanResourcePolicy.h` 和 `Qt/tests/VulkanResourceChecks.cpp`，注册 Core-only 目标 RhineVulkanResourceRegression／qt_vulkan_resource_regression；不要在离线测试创建 QGuiApplication 或 VkDevice。

- [x] 先写失败用例：任意有效 alignment 的 packing、offset／range 溢出与扩容、相同 SRB 不同 offset 不能跳绑、资源／设备代号换代、共享 SRB 单个引用退出／最后引用退出、实例 offset／stride、深度消费者真值表、直写与 batch 互斥及跨帧必须初始化。纯测试验证策略，不冒充驱动／GPU 生命周期验收。
- [x] 诊断开关建议 D02=RHINE_VK_UNIFORM_ARENA、D03=RHINE_VK_INSTANCE_ARENA／RHINE_VK_DIRECT_WRITE、D04=RHINE_VK_DISCARD_UNUSED_DEPTH；先 opt-in、仅 Vulkan 生效，其他后端保留原路径。一个开关只控制一个实验；四者可组合但逐项测后才测组合。
- [x] 实施后定向编译／测试，再编译主程序但不运行；这些命令本轮已执行：

~~~sh
cmake --build output/qt-build -j$(nproc) --target RhineVulkanResourceRegression RhineRenderPolicyRegression RhineMusicTextureAdmissionRegression RhineFramePacingRegression
ctest --test-dir output/qt-build --output-on-failure -R '^qt_(vulkan_resource|render_policy|music_texture_admission|frame_pacing)_regression$'
~~~

- [ ] 用户手工验收：固定 C 后基线，首次／返回滚动、静止、换封面、快速焦点切换、AA 模式切换、resize／DPR／隐藏恢复各检查；单开关配对 ABBA 至少三组，冷热缓存分开，记录 P50/P95/P99、CPU 录制与 GPU 有效样本、资源／绑定／更新量、输入响应和图像一致性。验证层／capture 单独跑，不混入正式性能数据。
- [x] buffer／descriptor 变少不是提速证明；同负载端到端无收益或有回归则关闭，不追加限帧／降画质。无硬件数据写“功能完成，性能待验”。独立交回改动、测试、原始计数／样本、回退方法；D05 需另附 Qt patch 和二进制来源。

**顺序：** D01 → D02 → D03／D04 分别 A/B → D06；D05 单独立项。每个实验若风险高于已测收益，可以停在门槛结论，不必全做。

**本轮不做：** 默认路径之外的 VulkanPresenter 空提交／交换链图像数／present mode 改造；再次开启 pipeline cache／持久映射／motion 裁剪；无证据 bindless／多队列／间接绘制／换 Vulkan 版本。它们不是已确认的当前瓶颈。也不关闭正确同步换吞吐。

**执行边界：** 不自动启动 GUI／播放／网络测试，不自动 commit／push；保护已有修改和 third_party/filament-src，不改字体／LRU／节拍、不恢复插帧、不限 FPS。构建生成头只处理本轮噪声。交接方使用当前 C 后基线，行号漂移以函数名为准。

## 官方依据（核对日期 2026-10-31）

- <a id="ref-s1"></a>**S1** [Qt 6.12 QRhiBuffer](https://doc.qt.io/qt-6.12/qrhibuffer.html)：全量直写的帧槽、更新互斥和使用范围要求；实现时以实际头文件的方法名为准。
- <a id="ref-s2"></a>**S2** [Qt 6.12 Vulkan 后端源码](https://code.qt.io/cgit/qt/qtbase.git/plain/src/gui/rhi/qrhivulkan.cpp?h=6.12)：QVkBuffer::create、setShaderResources、beginFullDynamicBufferUpdateForCurrentFrame、纹理 staging 及附件 store 策略。
- <a id="ref-s3"></a>**S3** [动态 UBO binding](https://doc.qt.io/qt-6.12/qrhishaderresourcebinding.html#uniformBufferWithDynamicOffset)、[QRhi 对齐与限制](https://doc.qt.io/qt-6.12/qrhi.html)：同一 SRB 通过动态 offset 读取不同区域。
- <a id="ref-s4"></a>**S4** [QRhiTextureRenderTarget flags](https://doc.qt.io/qt-6.12/qrhitexturerendertarget.html#Flag-enum)：DoNotStoreDepthStencilContents 只影响无需保留的深度纹理内容，不取消深度测试。
