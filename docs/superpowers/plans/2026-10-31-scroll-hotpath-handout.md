# 快速滚动热路径优化 Implementation Plan（F 系列）

2026-10-31｜交接给 A–E 实施者｜基线 perf/lts，f2583f0（61dd993 后新增观测脚手架／内存文档，热点实现未变）。**E 已完成，本轮不重复生命周期／直写／80 字节实例修复。**

> 给实施者：沿用逐项执行、先失败回归再实现的方式；本文件只交接计划，不自动实施或提交。

**Goal：** 减少快速滚动每个已消费帧的场景展开、实例构造、批次打包和 HUD 栅格／上传成本，改善 P95/P99 与输入响应。
**Architecture：** 保留现有 QRhi、消费反馈与 100ms 准入；把每帧相同部件解析移到模板更新，把实例数据从多阶段字节复制改成最终列表单次打包；HUD 局部重绘单独按收益门槛推进。
**Tech Stack：** C++20、Qt 6.12／Qt Quick／QRhi，Vulkan 为主，保持其他现有后端回退。

## 依据与优先级

本助手未采集新的 E 后吞吐数据，下列是代码确认的重复工作，不是已证实的当前主瓶颈。仓库已有 [内存增长记录](../../../docs/vulkan-igpu/08-memory-growth.md)：记载池化后增长收敛，但这不是本轮帧率收益实测；RHI 根因的精确归属仍须分配栈／最小复现证实。旧 A/B 数据不作为新基准。实例池已在 Vulkan 默认开启；材质 arena 等须记录实际生效状态，不自动开更多实验。

| 候选 | 现有证据 | 本轮改变 |
|---|---|---|
| 活动唱片逐部件展开 | [NativeCards.cpp:60–145](../../../Qt/src/NativeCards.cpp#L60-L145) 每部件解析 base/high/low、局部矩阵、插值后写 QJsonObject | 预解码模板＋仅对活动唱片发布类型化动态参数 |
| 多阶段实例复制 | [batchDraws](../../../Qt/src/RhiScene.cpp#L2499)、[poolInstances](../../../Qt/src/RhiScene.cpp#L2565) 先各 draw 打包，再拼批次，再写 pool | 类型化分组＋最终范围一次打包／合并更新 |
| 可见性／排序重复工作 | [NativeSceneUpdate.cpp:251–319](../../../Qt/src/NativeSceneUpdate.cpp#L251-L319) 每候选扫描 returning、矩阵先打包再排序重打包 | 返回格位集合、距离预计算、排序后一次输出 |
| 全窗口 HUD 更新 | [Overlay.qml:70–73](../../../Qt/qml/Overlay.qml#L70-L73) 全屏 Hud；[Hud.cpp:23](../../../Qt/src/Hud.cpp#L23) 无区域 update | 按完整绘制组的旧新包围盒局部重绘，证实收益后再保留 |

顺序：**F01 → F02 → F03 → F04；F05 是独立条件项，F06 收尾。** 不把所有候选捆成一次改造；每项收益超过波动才继续推广；F01 若显示当前瓶颈已不在候选阶段，就交回证据并停止该项，不先重写再找收益。

## F01：只补热路径分段与可重复基线

Files：[NativeApplication.cpp](../../../Qt/src/NativeApplication.cpp#L74)、[NativeCards.cpp](../../../Qt/src/NativeCards.cpp)、[RhiScene.cpp](../../../Qt/src/RhiScene.cpp)、[Hud.cpp](../../../Qt/src/Hud.cpp)。复用现有探针与 [scroll 脚手架](../../../tools/perf/scroll/README.md)，不另建大监控系统。

- [x] 把 app->step 的 observe 与 HUD 命令生成拆开：当前 sample 后到 hud.draw 结束的区间也包含 music.observe／sameAlbum，不能叫纯 HUD；不要把 Qt 隐式共享的赋值直接记成深拷贝。[S1]（已拆成 场景采样／观察+专辑／HUD 绘制／返回拷贝 四段）
- [x] 同一窗口记录 NativeCards 展开、实例 pack、batch 组装、pool 对比／更新、Hud paint／更新区域；同时报调用数、活动 actor／part／draw／实例数、最终上传字节、临时字节构造量。未直接测得的 Qt 纹理上传字节标成未知，不拿 dirty 面积当实际传输。（`Qt/src/render/HotPathProbe.h` 收全部计数；HUD 更新区域本轮仍记整窗，局部区域留给 F05）
- [ ] **（待用户安排实测）** 用户固定轨迹与数据分首次／返回／停止首秒／收敛后四段；相同视角先确认 E 后存量不再随轮次增长。如增长仍复现，单独回 E 的退化验收，不用 F 的吞吐收益盖过去。已有 ab.sh 会杀进程、覆盖会话并启动程序，只能由用户明确安排；使用前另审查备份／失败恢复与离线数据，不由实施代理自动运行。复用 EXTRA_ENV 逐项设置 F 开关，分析时以实际时间线和样本数对齐，不重造同类脚本。

### F01 实施记录

- `Qt/src/render/HotPathProbe.h`：`HotPathWindow`（原子计数）+ `HotPathTimer`（作用域计时）+ `takeHotPathSample()`/`formatHotPathLine()`。GUI 线程写卡片与 HUD，渲染线程写打包/批次/池化，打印方一次性交换归零。
- `NativeApplication::step` 拆成四段并各自报均值/峰值：场景采样、观察+专辑（`music.observe`/`sameAlbum`）、HUD 绘制（`hud.draw`）、返回拷贝（`QJsonObject` 组装）。S1 口径：隐式共享赋值不计成深拷贝，只量整段组装成本。
- 新增 `热路径(每帧)` 行（`RHINE_STEP_PROBE=1`，与 `app->step 内部` 同窗口打印）：卡片展开次数/耗时/卡数/部件数→draw 数、实例打包 KB 与耗时、批次组数/KB/耗时、池化对比与上传 KB 及上传次数、HUD 绘制次数/耗时/命令条数。
- 埋点位置：`NativeCards::expand`（计数与计时）、`RhiScene::instance()`（打包字节与耗时）、`batchDraws`（组数、批内字节、耗时）、`poolInstances`（对比字节、上传字节、上传次数）、`Hud::paint`（次数、耗时、命令条数）。
- 边界：HUD 更新区域暂记整窗（`update()` 无 rect），不把 dirty 面积当实际纹理传输；Qt 纹理上传字节仍是未知量，需 F05 时再实测。
- 本轮**未**执行任何 GUI/GPU 实测，四段数据待用户按固定轨迹采集。

## F02：活动唱片模板预解码＋类型化动态 draw（优先）

Files：[NativeCards.h](../../../Qt/src/NativeCards.h)、[NativeCards.cpp](../../../Qt/src/NativeCards.cpp#L33)、[SceneTypes.h](../../../Qt/src/SceneTypes.h)、[NativeSceneFrame.cpp](../../../Qt/src/NativeSceneFrame.cpp)、[Engine.h](../../../Qt/src/Engine.h)、[RhiScene.cpp](../../../Qt/src/RhiScene.cpp#L2362)。新增共享类型可放在这些既有文件或单一小头文件，不全面拆重构引擎。

- [x] actorTemplate 到达／变更时一次解析部件 ID、mesh／asset、状态标志、high／low 数值和 double 精度 localMatrix；按模板 revision 缓存，模板不变时不在 card×part 循环重新 toObject／toArray／解析矩阵。（`SceneAppearance::revision` 进程内单调 → `frame["appearanceRevision"]` → `NativeCards::decodeParts()`；解码结果缓存到 `decoded`，`localMatrix` 预判 identity）局部非单位矩阵保持原有 double 运算及累加顺序，最终转换 float；不能因提前转 float 改变结果。 先把这一项作为可独立验收的小步，仍输出旧 draw；确认收益和等价后才继续类型化传输，不一次性绑定为大型重写。
- [ ] 仅为这条热点增加“不可变部件模板＋当前 actor 动态参数／矩阵”的类型化快照，由 NativeCards→Engine→Renderer 共享；材质插值和 optical shell 规则与现有实现一致。Renderer 的新入口直接读这些值，不再生成 JSON 后再 surface() 解析。其他非唱片 draw、诊断和参考图保留兼容通路，避免一次替换全部 frame JSON。
- [ ] 列表资源保留、draw 数统计、归位对象 ID、musicKey／selected、shadowOnly／透明 order 需同步从类型化包读取；不得为维持这些消费者又每帧把全包转回 JSON。诊断导出按需生成；参考渲染能显式选旧路径。
- [ ] 跨线程发布不可变快照，不共享可写 vector／临时指针；模板更新、设备恢复、boot／detail／viewer／theme／quality／clarity 全覆盖失效。复杂状态不支持时整条 draw 回旧路径，不混读半份新旧参数。新增开关 RHINE_SCROLL_TYPED_DRAWS=1，初期 opt-in。
- [ ] 写**新旧实现的差分测试**：相同模板和 actor 输入比较部件集合、材质数值、最终矩阵／ID／顺序，覆盖 identity／非 identity localMatrix、high/low 缺失、0/1 和中间插值、空场景／模板更新。不是只测试新结构能构造；未建立等价性之前不推广。

#### F02a 实施记录（模板预解码）

- `Qt/src/SceneAppearance.h` 加 `quint64 revision`，构造函数里用进程内单调 `std::atomic` 取新代号；`NativeSceneFrame` 把代号写进 `frame["appearanceRevision"]`。
- `Qt/src/NativeCards.h/.cpp` 新增 `struct Part` 与 `decodeParts(revision, source)`：把 `base/high/low`、九个静态字段、`localMatrix`（含 identity 预判）、`hasMap`、`interpolateAttenuation`、`Frosted_Polymer` 判定各解析一次，按代号缓存。代号为 0（viewer 临时模板）时不缓存，退回每帧解码。
- `expand()` 的 card×part 循环只做插值与矩阵乘法，不再有 `toObject/toArray` 与逐键 JSON 查找；输出 draw 的字段与顺序保持原样（仍是旧 JSON 通路）。
- 等价性与收益：本轮**未做**差分测试与实测（`Qt/tests/ScrollHotPathChecks.cpp` 属 F06 的交付物）；按计划，类型化传输（F02 余下四条）必须等这条小步先证明收益与等价。

## F03：批次键类型化＋最终实例单次打包（优先）

Files：[RhiScene.cpp](../../../Qt/src/RhiScene.cpp#L2499)、[SceneTypes.h](../../../Qt/src/SceneTypes.h)、[VulkanResourcePolicy.h](../../../Qt/src/render/VulkanResourcePolicy.h) 及测试。此项可先独立用于旧 draw 路径，F02 不必全部完成。

- [x] 用类型化 BatchKey 代替每 draw 多次 QByteArray::number 拼串；完整包含网格／索引资源及代号、范围、side／order、label／cover、材质精确值及实例 layout。分组条件维持原有不透明兼容约束，hash 必须与 equality 一致；不可只按 mesh 或纹理合并，不做浮点近似分组，不改变透明顺序。（`RhineRender::BatchKey`／`BatchSlotKey`／`PoolKey` 进 `VulkanResourcePolicy.h`；`Draw::poolKey` 与 `instancePool.mirror`、`batchInstances` 全改类型化键；`VulkanResourceChecks` 新增 13 项相等／哈希一致性用例）
- [ ] 分组先记录源范围和数量，再一次规划最终 opaque＋transparent 所需容量；直接把源实例写到最终 CPU staging／pool 范围，不再逐 draw vector→QByteArray→批次 QByteArray→pool 多轮拼接。源快照存活到打包完成；复用有界工作区，不用 raw pointer 指向可扩容容器。相同模型不等于相同 state／历史，未完整证明相同不得跨部件共享。
- [ ] 保留 E 的每帧统一容量规划、全部 offset／stride 校验、80/144 格式与历史 ID 配对。可以以可信版本或最终字节比较跳过未变切片；版本必须覆盖矩阵、材质状态、排序和落点。相同内容落点变化仍需写入，arena 换代后全部初始化。
- [ ] 对连续变化切片合并少量 updateDynamicBuffer 区间，合并间隙也须有本帧合法字节；比较额外复制量与命令数，不无条件整池上传。零变化零更新，整帧失败一致回退，不能制造半池新旧或读写重叠。
- [ ] 差分测试最终实例字节和 draw buffer／offset／count：共享几何但材质不同、纹理切换、opaque／transparent、重排／新增删除、池扩容／回退、motion 切换。新增 RHINE_SCROLL_PACK_ONCE=1；验收看总 CPU／总复制量和帧间隔，不只看 GPU 更新次数。

#### F03a 实施记录（批次键类型化）

- `Qt/src/render/VulkanResourcePolicy.h` 新增 `BatchKey`（vertices／indices／start／count／side／order／label／cover／材质 128 字节／instanceStride，`==` 与 `qHashMulti` 出自同一组字段）、`BatchSlotKey`（同上 + slot）、`PoolKey`（逐 draw 用 drawId，批次用 BatchSlotKey）。
- `Qt/src/RhiScene.cpp`：`batchDraws()` 的分组从「拼 `baked/...+8 个 number+材质` 字符串」改为 `QHash<BatchKey,int>`，槽位计数改 `QHash<BatchKey,int>`（几何键清空材质）；`Draw::poolKey` 从 `QByteArray` 换成 `PoolKey`，`instancePool.mirror` 与 `batchInstances` 同步类型化；`prepare()` 写 `poolKey.valid/drawId`；`poolInstances()` 按 `valid/batch` 分支查 `batchInstances` 或 `instances`。
- 语义保持不变：仍只合并"不透明 + 非透射 + depthWrite"的 draw，仍按材质精确字节分组、不改变透明顺序；池化关闭时仍走 `dynamicBuffer` 回退。
- 用例：`RhineVulkanResourceChecks` 110 项（新增 13 项：相等、哈希一致、材质字节／instanceStride／槽位／身份类型区分）。
- 本步只做键类型化；F03 余下三条（单次打包、跳过未变切片、合并更新区间）与 `RHINE_SCROLL_PACK_ONCE` 开关留待下一步。

## F04：可见集合与排序一次计算、一次输出

Files：[NativeSceneUpdate.cpp](../../../Qt/src/NativeSceneUpdate.cpp#L239)、[SceneMath.h](../../../Qt/src/SceneMath.h)、[SceneTypes.h](../../../Qt/src/SceneTypes.h)；不改变 E 的归位衰减或显示范围。

- [ ] 一次建立 returning cell 集合，替代每候选 std::any_of；cell key 支持有符号／循环坐标，保持重叠格位语义。视锥快速拒绝后再计算不必要的 slope／矩阵／theme，不能把覆盖或候选视锥缩小。
- [ ] 为本帧可见实例预计算相机距离一次、稳定排序索引，再一次输出 matrix／theme／stable ID 的对应数组；不先构建整块 visibleMatrices 后再重打包。相同距离保持旧 tie 顺序、维持已有前到后策略；保留 C/E 历史配对，不取消排序换 CPU 时间。
- [ ] 候选集合仅在依赖确实未变时复用；涉及相机、投影、窗口／DPR、滚动原点、归位集合的依赖缺一不可。初轮只做当帧线性化与预计算，不引入复杂跨帧可见性缓存。
- [ ] 差分比较旧／新可见 cell 集、排序顺序、ID／矩阵／theme 对应，覆盖快速往返、并列距离、负坐标、循环、归位重选和候选边界。开关 RHINE_SCROLL_LINEAR_VISIBILITY=1；固定候选数／可见数验证 CPU 降低，不将少画物体算无损收益。

## F05：HUD 改为有界 dirty region（分项测到成本才做）

Files：[NativeHud.cpp](../../../Qt/src/NativeHud.cpp#L207)、[Engine.cpp](../../../Qt/src/Engine.cpp#L1072)、[Hud.h](../../../Qt/src/Hud.h)、[Hud.cpp](../../../Qt/src/Hud.cpp)、[Glyphs.cpp](../../../Qt/src/Glyphs.cpp#L435)、[Overlay.qml](../../../Qt/qml/Overlay.qml#L70)。

- [ ] 先记录滚动期间 HUD 命令变化组／paint 成本／更新面积，旧 hudUpdated 已按命令变化发出，不能把“增加 dirty 信号”当新优化。全屏 HUD 是候选成本，不是已证实主因；若显示组普遍全变、dirty 接近全窗或成本很小，本项交回暂缓。
- [ ] 对受控、完整 save/restore 的绘制组发布稳定 ID、内容 revision、旧新保守包围盒；失效区域取旧∪新并扩大笔画／AA／变换后的实际范围。字体 shaping、图像 revision、clip／opacity、主题／尺寸／DPR／全局 mask 都算依赖；无法确定影响范围的命令直接整窗回退。
- [ ] 在 GUI 侧用 update(rect) 请求本 item 的逻辑坐标区域；paint 保留并利用 painter 的 clip，重放**覆盖该区域的背景和所有相关组**，不只画刚变的命令，避免透明残影／叠加丢失。起步可以整份命令重放但裁剪像素，之后按分项决定是否编译状态完整的命令组以省遍历。
- [ ] QQuickPaintedItem 在 Vulkan 下仍需 QImage→纹理上传，update(rect) 不保证本机 Qt 后端必做等比例部分上传；测 CPU 和实际上传，FrameBufferObject 不是 Vulkan 加速选项。[S2] 若 dirty 合并成全窗而各组是独立布局，可另评估少量小 painted item，但保持 z/clip/alpha 和全局命令语义，不能强拆有交叉状态的命令流。
- [ ] 回归移除／移动文字、透明背景、字体／主题／封面晚到、resize／DPR、滚动字幕和点击区；hits／输入立即更新，与绘制快照同一版本，不为绘制节流延迟交互。RHINE_HUD_DIRTY_REGIONS=1 独立 opt-in；不改字体线程、不替换整套 UI、不降低 HUD 分辨率。

## F06：回归、手工验收与交回

新增无窗口回归测试 `Qt/tests/ScrollHotPathChecks.cpp`（目标 RhineScrollHotPathRegression，测试 qt_scroll_hotpath_regression），在 `CMakeLists.txt` 注册；纯策略依赖 Qt Core，直接调用 NativeCards 新旧 parser／packer 做矩阵差分时允许链接 Qt Gui，但不创建 QGuiApplication、不加载用户会话。共享的帧内规划／BatchKey／dirty 计算抽成单一职责小头文件，必须是实际调用的策略，不复制只供用例的公式。按 F02–F05 先写失败差分用例，再最小实现并通过。

~~~sh
cmake --build output/qt-build -j$(nproc) --target RhineScrollHotPathRegression RhineRenderPolicyRegression RhineVulkanResourceRegression RhineSceneLifetimeRegression RhineFramePacingRegression RhineMusicTextureAdmissionRegression
ctest --test-dir output/qt-build --output-on-failure -R '^qt_(scroll_hotpath|render_policy|vulkan_resource|scene_lifetime|frame_pacing|music_texture_admission)_regression$'
~~~

- [ ] 上述为实施后的命令，本轮未执行。Core-only 测策略；差分 fixture 直接运行新旧 parser／packer。若需 Qt Gui 测实际文字，定向 offscreen 且隔离数据／网络，不启动主应用自动播放。主程序只编译验证，GUI／GPU 图像检查由用户安排。
- [ ] 以 E 后当前默认配置作基线，新开关**逐项**比较、分别回退：同机／驱动／Qt／窗口／DPR／画质／数据和轨迹，冷热缓存分组，配对 ABBA 至少三组；记录首次／返回／停止首秒／收敛后及 10/50/100 轮，报告 P50/P95/P99、GUI／渲染 CPU、有效 GPU 样本和输入延迟代理。换绑／提交不是实际上屏。
- [ ] 必须同时看到“目标阶段工作／耗时下降＋端到端帧间隔改善或明确的噪声内结论”，且 draw／可见实例／图像／交互一致。仅搬线程、减少绘制、降低分辨率、缩短动画或增延迟不算本轮优化；纯微基准不能代表整帧收益。
- [ ] 若最新 GPU／驱动等待而非 CPU 居主导，交回证据并暂停相应重构；不得用过去 C 前数字推断当前上限。暂无手工数据只标“功能完成、性能待验”。逐项交回变更摘要、回归结果、配对原始数据、实际开关／回退和剩余风险。

**执行边界：** 不恢复插帧、不限 FPS、不降画质、不加长 100ms、不扩大 LRU、不重做 E、不改字体线程；不自动 GUI／播放／网络测试、commit／push。保护现有 generated 头／临时目录与 third_party/filament-src；构建只处理本轮生成噪声，不能覆盖既有修改。

## 依据

- <a id="s1"></a>**S1** [Qt 隐式共享](https://doc.qt.io/qt-6/implicit-sharing.html)：赋值常为共享引用，写入才可能 detach；本计划定位真实解析、修改与拼接，不按赋值数量编造复制量。
- <a id="s2"></a>**S2** [QQuickPaintedItem](https://doc.qt.io/qt-6/qquickpainteditem.html#update)：update(rect) 是请求下一次可见绘制的区域；Vulkan 不因选择 FBO 变成 GPU QPainter。部分上传范围以实际 Qt backend 核对。
- **S3** [Qt Quick 性能指南](https://doc.qt.io/qt-6/qtquick-performance.html)：按 profile 定位再减少重复工作；不照搬示例刷新率作为本项目限帧预算。官方说明核对日期 2026-10-31。
