# 快速滚动 CPU 与节拍优化 Implementation Plan

2026-10-31｜交接给 A01–A11、B01–B04 实施者｜C 系列接续当前实现，按项交回。

**目标：** 降低快速滚动的同步／draw 装配成本，并减少停止后的无效完整 step；不预先承诺 FPS 收益。
**架构：** 先对齐账本，再复用 draw 的稳定部分、缩短同步临界区，最后用消费反馈合并过量生产。各项独立比较；保留现有 QRhi、字体线程和纹理准入链路。
**技术：** Qt Quick／QRhi、C++20、Vulkan。执行可用 executing-plans；本文件是交接计划，不自动实施或提交。

## 依据与修正

用户手测 n=2，2560×1440、Vulkan、Intel i915；下表为 d0 → d100，单位 ms。属于用户提供的窗口统计，本轮未复测。

| 阶段 | 首次滚动 | 返回滚动 |
| --- | --- | --- |
| 纹理 | 0.65 → 0.12 | 0.84 → 0.18 |
| draw 列表＋构建＋录制 | 6.06 → 6.44 | 10.25 → 10.96 |
| Qt Quick sync | 6.41 → 6.69 | 9.54 → 9.87 |
| 渲染线程合计 | 16.5 → 15.8 | 25.5 → 24.5 |

优先处理 CPU／同步路径；纹理准入已显著减少生成工作，暂不追加延迟、缓存容量或线程池改造。CPU 墙钟耗时含等待，GPU／帧期比例不是硬件利用率，现有两轮还不足以排除驱动等待或宣布提速。

两点不能沿用原归因：

- 停止段 3D 5.67ms 大于 Qt render 4.94ms；41.9ms 帧期也不能直接和另一窗口 render/s=45–66 拼接。先对齐区间、调用次数和分母，不反推“QML 自身绘制成本”。
- 当前 [Engine.cpp](../../../Qt/src/Engine.cpp#L370) 的 requestSceneContent() 只递增场景版本／发信号，不直接 wake 或清零 stableFrames；[准入调度器](../../../Qt/src/render/MusicTextureAdmission.h#L206) 只有一个单次定时器。wake/s=21 不能据此归因准入。取消=0／在途峰值=1 仅说明本组未观测到取消积压。

## C01：统一账本，定位同步内部成本

位置：[Engine.cpp](../../../Qt/src/Engine.cpp#L80)、[NativeApplication.cpp](../../../Qt/src/NativeApplication.cpp#L73)、[RhiScene.cpp](../../../Qt/src/RhiScene.cpp#L2444)、[Hud.cpp](../../../Qt/src/Hud.cpp#L28)、[FrameProfiler.cpp](../../../Qt/src/FrameProfiler.cpp#L139)。

- [ ] 同一单调时钟窗口输出时长、tick／3D render／窗口呈现的总次数、各段总耗时与样本数；命名区分三种帧，均值由总量除以对应次数计算。统计停止后 0–1s 和随后静止窗口，避免把缓动期叫空闲。
- [ ] 在已有 sync 总计下补 RHI synchronize、Hud::paint 分项，draw 列表拆 musicDraws／prepare；记录 draws、returningCards、实例数，以及每 draw 耗时。先判定返回滚动变慢是数量增加还是单项成本增加；Qt sync 总时间不直接等于自定义 synchronize 耗时。
- [ ] wake 按输入、Host invalidated、媒体、其他调用来源计数；另记准入定时器“回调／核验成功”、requestSceneContent、stableFrames 重置次数及原因。既不把 wake 当实际休眠唤醒次数，也不把 resource request 当完整模拟重启。
- [ ] GPU 值标成“最近已完成 RHI 帧 GPU 时间”，保留状态／采样次数；当前每秒日志是最近值，不能当窗口均值。该 API 异步，完成帧号未知时不与当前 CPU 帧硬配对。默认不增加逐帧刷屏。

## C02：复用 draw 的稳定部分（主要性能改动）

位置：[RhiScene.cpp](../../../Qt/src/RhiScene.cpp#L887) 的 musicDraws、prepare、surface、geometry，以及 render 中的队列装配；按需扩展 [RenderChecks.cpp](../../../Qt/tests/RenderChecks.cpp)。

- [ ] 先复用过滤后的部件模板、mesh 范围、数值资源标识和已解析材质；避免每帧对每部件反复改 QJsonObject、拼 resourceKey、解析同一 surface。预留／复用列表容量；同帧多 pass 共享已算结果。
- [ ] 把稳定的网格／拓扑、可变材质、实例矩阵及实际纹理绑定分别判脏。仅变矩阵时更新实例数据和透明深度排序；不能仅按 sceneRevision 或 geometryRevision 缓存整个列表。焦点／归位增删、viewer／mode、主题／透明度、异步 mesh／纹理、设备／render-pass 改变各有失效入口。
- [ ] 缓存命中仍刷新本帧 used 标记，保持安全退休；纹理变化仍按实际指针／资源代号重绑。保持透明顺序、正反面、shadowOnly、当前／归位曲目的占位与纹理归属；不删玻璃、阴影或归位动画来制造收益。缓存有界，设备重建不复用旧 QRhi 对象。
- [ ] 验收看相同 draws／实例数下的列表＋构建＋录制总成本及峰值；分别报告首次与返回滚动。不把 draws 变少或工作转移到 GUI 线程单独当成成功。

## C03：缩短 Qt Quick 同步临界区

位置：[RhiScene.cpp](../../../Qt/src/RhiScene.cpp#L2444) synchronize、[Engine.h](../../../Qt/src/Engine.h#L92) musicTextures 快照、[Engine.cpp](../../../Qt/src/Engine.cpp)、[Hud.cpp](../../../Qt/src/Hud.cpp)。依据 C01 分项实施，不先假定 6–10ms 全来自 RHI 项。

- [ ] RHI 同步若占主要成本：在 GUI 内容发布时制作不可变快照，同步期只接收最新版本；分别按场景／几何／准入／封面版本复用数据。检查 frame 写字段引发的 detach、musicTextures 逐项写 admitted 和大容器复制，避免同内容重复准备。快照覆盖相机、变换、资源到达、设备恢复，不能因拓扑未变漏更新。
- [ ] Hud::paint 若占主要成本：沿用现有 HUD 版本和命令缓存，复用未变文字／图像内容，维持尺寸、DPR、主题、输入及动画失效；保留字体现有线程归属。若这两项均不大，继续定位剩余 Qt 节点同步，不做无收益快照重构。
- [ ] 对比 sync、GUI 总 CPU、渲染线程总成本和帧间隔；把复制从 sync 搬到更多 tick 上若总成本增加，应调整或撤回。

## C04：用消费反馈合并过量 step

位置：[Engine.cpp](../../../Qt/src/Engine.cpp#L503) tick／wake、[Engine.h](../../../Qt/src/Engine.h)、[RhiScene.cpp](../../../Qt/src/RhiScene.cpp#L2444) 同步／render 通知；新增纯策略 `Qt/src/render/FramePacingPolicy.h` 与 `Qt/tests/FramePacingChecks.cpp`，在 [CMakeLists.txt](../../../CMakeLists.txt#L625) 注册 Core-only 回归目标。

- [ ] 移除用 tick 内 frameNs−stepNs 推断呈现阻塞的决策：该范围测不到 Qt render/sync 等待。保留 RHINE_TICK_MS 排障覆盖；生产节拍以当前 Qt Quick 路径实际消费快照为反馈，不依赖已下线 FG 的回调。
- [ ] 单独维护单调的“发布／消费”序号，最多保留一份尚未消费的最新视觉快照；消费反馈只匹配其实际读取的序号。输入立即收集并合并最新状态、发出更新请求；待消费期间合并重复完整 step，播放／网络等业务事件继续处理。消费后若仍有输入或动画，异步调度下一次；无待办则休眠。
- [ ] 不积压追赶已被覆盖的中间帧，不以固定 FPS／16ms／刷新率常数限速。动画继续用单调时间，保留现有 delta 限制；一次消费至多排一个后续回调，避免反馈自己形成空转。
- [ ] 区分模拟推进与“纹理／准入就绪，仅需重绘”。后者只发布必要资源状态并请求帧，不无条件重置 stableFrames；若场景动画确实在动，照常推进。隐藏／销毁／设备重建时作废旧消费回调，恢复首帧能自举；Qt 跳过未变化内容时也不会永久等待确认。
- [ ] 消费反馈通过安全的 queued 通知回 GUI，不在渲染线程等待 GUI，也不加 finish／GPU 空闲等待。recordRender 统计仅是录制次数；不得把它或一次同步反馈叫“真实上屏”。

## C05：回归、人工对照与交回

- [ ] 先以假序号／假时钟测试 C04：多次输入合并、旧／重复确认失效、消费后只排一次、动画连续推进且停止后不自激、纯资源请求不重置模拟、隐藏恢复／设备代号更新／销毁、无帧时准入到期仍能请求更新。新增目标 RhineFramePacingRegression，测试 qt_frame_pacing_regression；不靠 sleep 或 GUI 播放验证策略。
- [ ] C02 对缓存失效策略做真实回归：仅矩阵变化可复用稳定项；材质／焦点／纹理／设备改变必须更新；draw 增删、used 保活和透明顺序正确。纯逻辑测试只覆盖策略，GPU 生命周期和画面正确性由人工验收。
- [ ] 定向验证下列目标，另编译主程序但不运行。这些是实施后的命令，本轮写计划未执行：

~~~sh
cmake --build output/qt-build -j$(nproc) --target RhineRenderPolicyRegression RhineMusicTextureAdmissionRegression RhineFramePacingRegression
ctest --test-dir output/qt-build --output-on-failure -R '^qt_(render_policy|music_texture_admission|frame_pacing)_regression$'
~~~

- [ ] 由用户手工跑相同数据／轨迹／窗口／DPR／画质的配对 ABBA 至少三组；每组分别控制冷／热缓存。主比较固定准入 100ms、C 改动关闭／开启；另用 0ms 验证兼容。首次滚动、返回、停止后 0–1s、随后静止分别记录总量、P50／P95／P99 帧间隔、draw 数、sync 分项、GUI CPU、tick／消费比、资源就绪到换绑延迟。
- [ ] C02/C03 以同负载 CPU 成本下降且帧间隔改善为性能证据；C04 以重复完整 step 减少、尾部 CPU／延迟改善且输入响应与动画不退化为证据，不强求 tick/render 恰好等于 1。n=2、均值方向不一致不宣布提速；若驱动／GPU 归因仍不清，再由用户固定逻辑视口仅减少目标像素做独立诊断，不作为交付画质变更。
- [ ] 分项交回改动摘要、定向测试结果、配对原始数据及计时定义；未人工测就标“功能完成，性能待验”。C02、C03、C04 各保留可独立关闭的诊断开关或可独立撤回的变更组，避免把所有改动捆成一次性能结论。

**执行顺序：** C01 → C02 → C03 → C04 → C05；C01 的测量修正不扩成新的长期探针工程。每项核对前两轮功能后再继续。

**边界：** 不自动启动 GUI／播放／网络验收，不自动 commit／push；使用既有构建目录，生成 FFX 头只处理本轮噪声且保留已有修改。不恢复插帧、不限帧、不降画质、不改字体线程、不扩大 LRU；前轮“空 key 占纹理 LRU 条目”作为独立正确性修补，不能混入 C 性能收益。

**计时依据：** [Qt：lastCompletedGpuTime](https://doc.qt.io/qt-6/qrhicommandbuffer.html#lastCompletedGpuTime) 明确说明返回较早完成帧的异步结果，可能滞后 2–3 帧。
