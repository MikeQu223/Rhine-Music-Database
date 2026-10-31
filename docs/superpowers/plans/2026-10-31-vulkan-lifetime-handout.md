# Vulkan 生命周期与重复滚动退化 Handout（E 系列）

2026-10-31｜交接给 A–D 实施者｜基线 perf/lts，fac0854。

**优先目标：** 先定位／消除“滚动次数越多、帧率越低”的历史状态依赖，再做新的 Vulkan 减负。以下为静态代码证据及实施计划，**不是已复现的根因或实测提速**；本轮不改实现、不启动 GUI／播放。

## 当前结论与边界

- D 的四个参数仍为 opt-in，默认都关闭：[开关](../../../Qt/src/RhiScene.cpp#L375)。因此“D 已完成”不代表日常运行在 arena／直写路径。D05 正式结论为暂缓、缺 capture；D04 硬件验收也仍待做，不能说后端补丁和性能验证已经完成。
- 已确认三个 D 路径风险：历史材质槽只增不减；直写被全局内容缓存提前跳过；实例池两次调用没有统一总容量与镜像。前两项分别可能触发优化永久回退、跨帧旧值；这些不自动解释所有开关关闭时的慢。
- 默认路径仍要查归位对象／draw／资源数是否随轮次恢复。场景脉冲最多 6 个且过期移除、fieldCache 每 update 清理；batchInstances、materials、instances、materialBindings 已有逐帧回收，不能仅见 QHash 就报泄漏。

## E01：先固定退化复现与有效配置（必做）

> 实施：`RHINE_VK_RESOURCE_PROBE=1` 现在每个窗口多打两行——`资源账本配置:` 记请求值／生效值／回退原因、AA／motion／samples／宿主；`资源账本:` 追加 `arena 槽 活/历史/容量`、`实例池 容量/镜像条数`、`pipeline 活/布局活`。请求值与生效值分开静态保存在 `VulkanResourceProbe.h`（`VulkanResourceConfig`），回退时写原因字符串。第 1 条的“记录”已实现；第 2–4 条的分组采样仍需用户手工执行（本轮不启动 GUI）。

位置：[资源探针](../../../Qt/src/RhiScene.cpp#L1783)、[归位统计](../../../Qt/src/NativeSceneFrame.cpp#L193)、[资源拥有者](../../../Qt/src/RhiScene.cpp#L290)。

- [x] 不先改开关默认值。记录四个 D 参数的请求值、**本进程实际生效值／回退原因**、AA／motion、Qt／驱动／GPU、宿主；分别测默认全关与 D 单项开启，direct-write 组必须明确 uniform arena 已开。
- [ ] 用户手工按同一有限列表、同路线／速度往返 10／50／100 轮，在同一视角记录一段滚动及一段完全收敛后的静止窗口。收敛以 returningCards=0、pending 动画／上传完成为准，而不是只等固定几秒；另保留停止首秒的缓动窗口。
- [ ] 同一窗口记录 P50/P95/P99、CPU 构建／录制、有效 GPU 样本、draw／实例／returningCards、materials／instances／batchInstances、arena 的活跃／历史槽数和实际模式、pool 容量／镜像条数、pipeline／layout 的 map 数与 **sized 中实际拥有数量**、资源创建／退休／Qt 待释放量的可观测部分。RSS 或累计创建次数不能单独证明泄漏。
- [ ] 分流：收敛后恢复且 returning 数相关 → 活跃动画叠加；同一收敛画面资源仍增长 → 生命周期／缓存；达到某轮突然变慢且开关从 on 回退 off → 容量或路径退化；计数不变但原生队列等待增大 → 用户 capture 再查驱动／Vulkan。默认全关仍慢时，不把仅 opt-in 执行的代码当唯一根因。

## E02：修正历史材质槽与 pipeline 所有权（高优先级）

> 实施：`planMaterialArena()` 先回收本帧不再出现的键（槽位进 `freeSlots`、`committed` 失效），再按 `planMaterialSlots()` 只为真正新增的键扩容量；`materialSlot()` 优先复用空闲槽，`used` 只在空闲槽耗尽时前进。pipeline 与布局 SRB 改成 `clearPipelines()`：从 `sized` 摘出后 `release()->deleteLater()`，不再只清哈希（`pipelinesLive`/`layoutsLive` 因此能真实回落）。离线上限验收在 `VulkanResourceChecks.cpp` 的 `materialSlotPlanning()`：1000 轮固定活动集合 churn 水位恒 40、半新半旧复用空闲槽、无空闲槽才扩容到 80、300 个活动键判为不适合 arena。真实 `>256` 活动集合需要运行时场景，本轮没有可离线构造的样本。

**证据链：** [NativeScene.cpp](../../../Qt/src/NativeScene.cpp#L115) 在切换时 old.id=m_nextActor++；[NativeCards.cpp](../../../Qt/src/NativeCards.cpp#L102) 令 draw ID=−(actorId×256+partIndex+1)；[材质槽](../../../Qt/src/RhiScene.cpp#L904) 把 draw ID 加入 offsets、used 只增不减。[prepare](../../../Qt/src/RhiScene.cpp#L2136) 再按 used＋draws.size() 申请容量，超过 256 槽会永久关闭 uniform arena。**“材质键不会随滚动增长”的注释不成立**；这是有上限的历史增长／回退风险，不是已证实的无限显存泄漏。

- [x] 改成按本帧实际唯一活动材质规划：先收集／去重，再分配或复用槽；只有真正新增的 key 计入需求，不用 used＋全部 draws 过度预留。活动 key 有界且小于容量时，反复新 actor 不得耗尽历史 256 槽。
- [x] 可选最简单的每帧确定性重排／打包，或按代回收空闲槽；同一逻辑帧任何已发出的 draw 都不得被后续写覆盖。batch 更新由 QRhi 管理各原生帧槽的一致性；回收槽必须使旧 committed 失效，写入新 owner，避免字节恰好相同却读旧槽。无需把 actor ID 改回循环复用来掩盖问题，历史运动身份仍保留。
- [x] arena 扩容／模式回退只清 pipelines／pipelineLayouts 的 hash，原对象在 sized 中仍被持有：[clear 点](../../../Qt/src/RhiScene.cpp#L847)、[资源入库](../../../Qt/src/RhiScene.cpp#L1851)。拆出可安全退休的 pipeline／layout 所有权；清 map 时回收对应对象，不能调用只搜索 resources 的 retire 期待清掉 sized，也不能直接 sized.clear() 把有效 RT／深度一起删掉。保留 Qt 延迟释放，不加 deviceWaitIdle。[S1]
- [x] 验收历史 key 单调变化、同时活动集合固定的 1000 次离线 churn：槽占用／对象实际存量有界，不因历史次数永久回退。另测大于容量的真实活动集合，正确回退并给出原因；不能只提高 256 上限。

## E03：修正 D03 全量直写与实例池边界（先保正确）

> 实施：`writeMaterial()` 改成 `materialWriteRequired(映射中, 内容相同)`——直写时内容相同也写；映射生命周期从 `render()` 挪进 `prepare()`（容量规划 → 开始映射 → 写满 → 收尾），映射失败发生在任何写入之前，整帧统一走 `updateDynamicBuffer`，不会半帧两种路径。`poolInstances(opaque, transparent)` 现在一次收集两段、用 `poolSliceEnd()` 累计算出总容量、一次 `ensureInstancePool()`、一次 `next` 镜像提交；分配前对每个切片做 `poolSliceFits()` 检查，放不下就整帧回落逐 draw buffer。

位置：[writeMaterial](../../../Qt/src/RhiScene.cpp#L920)、[poolInstances](../../../Qt/src/RhiScene.cpp#L2320)、[两次池化调用](../../../Qt/src/RhiScene.cpp#L2882)。

- [x] writeMaterial 目前在 materialArenaMap 分支**之前**按 committed 内容相同直接 return，与直写每个原生帧槽必须写全相冲突。直写先写本帧所有有效槽；仅 batch 路径允许内容相同跳过。以真正的写调用／槽位初始化断言测试连续相同帧、后续变化、恢复／扩容，不只测一个脱离实现的 bool 函数。[S2]
- [x] beginMaterialArenaWrite 当前早于 prepare 的 ensureMaterialArena。先统一规划容量，再开始映射；扩容时不得沿用旧映射。本帧后半段不能因临时映射失败直接在同一对象改走 batch。按原计划用新 buffer／重绑回退，或整帧择定路径；记录哪个路径实际写入。
- [x] 目前 poolInstances 先用本次 total 而非 cursor＋total 保证容量，opaque／transparent 分别调用。第二次可能使写入越界；若它触发扩容，前一列表可能还指向已退休的旧 pool。改成**两个最终列表先统一规划、一次扩容，再一起分配／上传**，逐切片检查 offset＋bytes≤capacity（含对齐与溢出）。
- [x] mirror 当前每次调用被 next 替换，两个列表交替会丢掉另一半的上一帧镜像；改成整帧一次提交镜像，两个列表共同保留。测试两列表同内容且同落点时均不重传、第二列表跨容量边界、只有透明列表、空列表和失败回退，验证 draw 实际 buffer＋offset。

## E04：核对归位积压与“活跃资源”放大（默认路径也适用）

位置：[归位推进／删除](../../../Qt/src/NativeSceneUpdate.cpp#L193)、[draw 展开](../../../Qt/src/NativeSceneFrame.cpp#L114)、[资源退场](../../../Qt/src/RhiScene.cpp#L2806)。

> 实施：归位不收敛的根因是落位用了 `Spring::damp(0, 4.5, seconds)`——每步乘子 `(1+rate·h)·e^{-rate·h}` 在 60 fps 下约 0.99727，等效时间常数≈6 秒，且随帧率变化；改成 `SceneLifetime::returningLiftStep()` 的帧率无关指数衰减（标称速率仍是 4.5／减弱 35），单份归位寿命从近一分钟降到约 3.3 秒。`select()` 另修了重复归位：同一格先移除旧那份（位置完全重合，只是重复展开部件、重复引用同一 music key）。按计划首轮**没有**硬截 returning 数、没有跳动画、没有提弹簧速度；积压仍是暂时的（每帧换格时稳态≈200 份，停止输入后数秒清空）。探针：frame 增 `returningAgeMax`，`3D内部` 行打印 `归位 N(最老 X.XXs)`；新增 Core-only 用例 `Qt/tests/SceneLifetimeChecks.cpp`（17 项，含 400 次往返 churn 与满积压收敛）。未做运行期实测（计划禁止自动跑 GUI），age／数量需人工带 `RHINE_FG_DIAG=1` 观察。

- [x] 每次选择新增 actor 会展开多个 draw；只有 lift 与 rotation 收敛才移除 actor。测 returning 数、年龄、实际 dt 和删除数，确认 C04 合并 step 后时钟仍真实推进，停止后确实全部归位、所引用的 music key／材质／实例随之退出活动集合。
- [x] 若有同一 cell 的重复归位实体或永不收敛状态，修状态机及增删对称性；若只是输入持续快于归位速度，区分暂时动画积压和永久退化，保持视觉语义。初轮不硬截 returning 数、不跳动画、不提弹簧速度来制造提升。
- [x] 加有限往返的状态机测试：无输入并推进到满足现有收敛条件后，returning=0；主实例、draw／活动资源回到相同基线。GPU 原生释放可滞后提交完成，不能要求同一 CPU 帧立即下降；也不能用手工 resize／重启清理来当修复。

## E05：进一步 Vulkan 减负，修复稳定后独立 A/B

### 5a. 无 motion 时采用 80 字节实例格式（优先新增机会）

> 实施：新增独立烘焙目录 `Qt/shaders/compact/CMakeLists.txt`（同一二进制目录对同一源文件烘两次会撞 `.qsb/*.rule`，所以放子目录），产出 `/opticalCompact` 变体：`opticalGeometry.vert` 不带 `RHINE_SINGLE_PASS_MOTION`（不声明 location 8–11），`opticalSurfaceNoMrt.frag` 的 `v_velocity` 输入也包进该宏。`RhiScene` 里 `compactInstances` 仅在 `RHINE_VK_COMPACT_INSTANCES=1` 且 `motionVectors == nullptr`、无 `RHINE_WARP_PROBE` 时生效；pipeline key 增加紧凑位，顶点布局切 80 字节且不声明 previousModel 属性；`instance()` 按 80 字节步长序列化并整段跳过上一帧矩阵配对（省掉哈希查找与拷贝），batch／pool 走同一份字节。配置行新增「紧凑实例 请求/生效」。运行期 A/B（同 draw／画质／尺寸）未做——计划禁止自动跑 GUI，需人工带 `RHINE_VK_COMPACT_INSTANCES=1` 对照。

**当前：** Linux [Instance](../../../Qt/src/RhiScene.cpp#L75) 始终 144 字节，包含 previousModel；[实例打包](../../../Qt/src/RhiScene.cpp#L2063) 即使无 motion 也准备它，[顶点输入](../../../Qt/src/RhiScene.cpp#L1869) 仍声明该属性。A05 只裁附件／历史保存，不等于实例载荷和 vertex shader 都已裁掉。

- [x] 当本次管线确实没有运动矢量／其他历史消费者时，使用 model64＋state16 的 80 字节 CPU／顶点布局和不含 RHINE_SINGLE_PASS_MOTION 的 geometry shader；有 motion 保持 144 字节。同步修改 qsb 变体、pipeline key／layout、batch／pool stride、上一帧读取和探针；不能仅截断上传但让 shader 仍读 previousModel。
- [x] 这将少传 64/144≈44.4% 的**实例载荷字节**，不是整帧带宽或 FPS 预测。若默认无 motion，可减少 CPU 打包／QRhi 更新复制与 vertex fetch。固定相同 draw／画质／尺寸比较；模式切换重建／清历史，TAA／FSR／warp 与 reference 路径不回归。

### 5b. 将 pipeline 布局身份与 buffer 身份分离

- [x] 当前 arena 换 buffer 就清所有管线；资源地址改变本身不必改变原生 binding 布局。用独立布局描述 SRB、只在实际布局／shader／RT兼容性变化时换 pipeline；buffer 换代仅重建实际资源 SRB。布局 SRB 仍须 create()，可用空资源描述类型；真正 draw 必须绑定布局兼容且资源有效的实际 SRB。[S3]
- [x] 顶点 buffer、offset、index type 相同的连续 draw 可独立试 setVertexInput 去重；状态 key 必须完整并在新 pass／外部命令后失效。只有计数确有重复才做，不能改变透明顺序。无 capture 不新增多队列、bindless 或原生命令重录架构。

## E06：最小回归与手工验收

- [x] 扩展 [VulkanResourceChecks.cpp](../../../Qt/tests/VulkanResourceChecks.cpp)，将槽规划／写模式／两列表 pool 规划提成实际实现共用策略；补历史 churn、真实超容量、共享所有权、静态内容连续多原生帧槽初始化、map失败换对象、双列表扩容与80/144布局选择。归位测试用现有可隔离的 NativeScene harness；若需新测试目标，只建 Core／离线逻辑，不启动应用播放。
- [x] 建议 E05 两项仅 opt-in（RHINE_VK_COMPACT_INSTANCES／RHINE_VK_LAYOUT_ONLY_PIPELINES）；E02/E03 是对应 D 实验路径的正确性修复，不借新的开关保留已知越界／未初始化行为。开关全关／单开／组合开都能安全回退。
- [x] 实施后定向编译及测试，下列命令本计划未执行：

~~~sh
cmake --build output/qt-build -j$(nproc) --target RhineVulkanResourceRegression RhineRenderPolicyRegression RhineMusicTextureAdmissionRegression RhineFramePacingRegression
ctest --test-dir output/qt-build --output-on-failure -R '^qt_(vulkan_resource|render_policy|music_texture_admission|frame_pacing)_regression$'
~~~

- [ ] 由用户按 E01 手工采样，修复前后分离比较：相同收敛画面不再随历史轮次单调涨槽／资源、D 模式不随历史无故关闭、无 GPU 验证层错误、动作／纹理不串、P95/P99不持续恶化。分别说明默认与 D opt-in 是否复现；没有样本就交“静态风险已修，用户症状因果待验”，不能宣称找到唯一根因。

**顺序：** E01 → E02/E03 正确性 → E04 默认路径分流 → E05 独立优化 → E06。修复与新优化分组验收；D05 的“无证据暂缓”仍有效。

**执行边界：** 不自动运行 GUI／播放／网络验收，不 commit／push；保护已有生成 FFX 头和 third_party/filament-src。不限帧、不降画质、不增 LRU、不恢复插帧、不改字体线程；不清空所有资源或加 GPU 等待掩盖增长。后续函数行号变化按名称定位。

## 官方依据

- <a id="s1"></a>**[S1]** [Qt QRhiResource](https://doc.qt.io/qt-6/qrhiresource.html)：资源拥有权与 deleteLater；应用缓存清除与原生 GPU 回收不是同一时点。
- <a id="s2"></a>**[S2]** [Qt QRhiBuffer](https://doc.qt.io/qt-6/qrhibuffer.html#beginFullDynamicBufferUpdateForCurrentFrame)：全量直写、原生帧槽、每帧初始化与 batch 互斥。
- <a id="s3"></a>**[S3]** [Qt QRhiGraphicsPipeline](https://doc.qt.io/qt-6/qrhigraphicspipeline.html)：布局兼容性与管线创建成本。资料核对日期 2026-10-31；本机二进制以实际 Qt 构建为准。

### E06 交付说明

**用例覆盖**（`Qt/tests/VulkanResourceChecks.cpp` 97 项、`Qt/tests/SceneLifetimeChecks.cpp` 17 项，全部 Core-only、不建 QGuiApplication）：

| 要求 | 覆盖方式 |
|---|---|
| 槽规划／写模式／两列表 pool 规划提成共用策略 | 策略集中在 `Qt/src/render/VulkanResourcePolicy.h`，运行期与用例调同一函数 |
| 历史 churn | `materialSlotPlanning()`：1000 轮固定活动集合，槽位水位恒 40 |
| 真实超容量 | 300 个活动键时 `materialSlotPlanFits(300, 256)` 为 false → 运行期 `disableUniformArena` |
| 共享所有权 | `resourceGenerationMatches`/`pruneRetireNeeded`：仅"本帧未引用或代号过期"才退休 |
| 静态内容连续多帧初始化 | `materialWriteRequired(true, true)`：直写时内容相同也必须写 |
| map 失败换对象 | `poolSliceFits` 全量预检失败 → 整帧回落逐 draw buffer（不半池半单独） |
| 双列表扩容 | `poolSliceEnd` 累计两段（含空切片与 4 字节对齐） |
| 80／144 布局选择 | `compactInstances()`：`compactInstanceAllowed`、`instanceStride`、载荷比例 64/144 |
| 布局身份 | `pipelineLayoutIdentity()`：身份两位，buffer 换代不触发重建 |
| 归位状态机 | `SceneLifetimeChecks.cpp`：角度／落位衰减、400 次换格积压、满积压与停止后清空 |

**开关**（均 opt-in，仅 Vulkan 路径；全关时与改动前一致）：

| 开关 | 作用 |
|---|---|
| `RHINE_VK_UNIFORM_ARENA` | 材质 UBO 动态偏移 arena（E02／E03 的槽回收与写满语义始终生效） |
| `RHINE_VK_INSTANCE_ARENA` | 实例 buffer 池化（E03 双列表统一规划始终生效）；**默认开启**，`=0` 可关回逐 draw——非池化路径每帧上传的实例字节会被 Vulkan staging 逐帧累积（实测上传 165 KB/帧 ≈ 在堆 +165 KB/帧），只有 Vulkan 后端启用 |
| `RHINE_VK_DIRECT_WRITE` | arena 整块直写；映射失败整帧回落 |
| `RHINE_VK_DISCARD_UNUSED_DEPTH` | 无深度消费者时不保留内容 |
| `RHINE_VK_COMPACT_INSTANCES` | 80 字节实例 + 无 `RHINE_SINGLE_PASS_MOTION` 着色器 |
| `RHINE_VK_LAYOUT_ONLY_PIPELINES` | 布局身份与 buffer 身份分离 |

**实际执行的验证**：

~~~sh
cmake --build output/qt-build -j$(nproc) --target RhineVulkanResourceRegression RhineRenderPolicyRegression RhineMusicTextureAdmissionRegression RhineFramePacingRegression RhineSceneLifetimeRegression
ctest --test-dir output/qt-build --output-on-failure -R '^qt_(vulkan_resource|render_policy|music_texture_admission|frame_pacing|scene_lifetime)_regression$'
ctest --test-dir output/qt-build --output-on-failure
~~~

结果：定向 5/5、全量 16/16（37 秒）；主程序只做编译验证，未运行。

**状态：功能完成，性能待验。** 本轮没有真实 GPU 时间数据（计划禁止自动启动 GUI／播放）。资源计数（`RHINE_VK_RESOURCE_PROBE=1`）能给出 buffer／SRB／pipeline 存量与逐帧更新量，但 buffer 变少不等于帧时间变短。

**人工验收**：同一会话同一路径（首次快速滚动／原路返回／停止等待），逐个开关单开，对照 `资源账本` 行与 `QSG_RENDER_TIMING`／节拍诊断的 P50／P95／P99；光栅路径变化（紧凑实例、深度不保留）要同时看画面一致性与 `RHINE_FG_DIAG=1` 的 3D 分段。

**已知风险**：① E05a 的紧凑几何管线未在真实 Vulkan 上跑过，接口不匹配会建管线失败（默认关）；② E05b 依赖 QRhi 对"同布局描述、不同 buffer"的 SRB 兼容性判定，被拒时表现为绘制丢失（默认关）；③ E05b 的 setVertexInput 去重未做（无 capture 证明重复）；④ 归位积压仍有数秒尾巴（E04 把时间常数从约 6 秒降到 0.22 秒）。
