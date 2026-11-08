# 响应式 HUD 维护指南

本文描述当前 Qt/C++ 实现，供后续维护者定位代码。以源码和回归为准，不包含早期原型、会话记录或已废弃的设计方案。

## 1. 布局边界

- **逻辑宽度 < 逻辑高度：移动布局。宽度 ≥ 高度：原横屏布局。** 不按设备名、DPI 或像素分辨率判断，不使用比例缓冲区。
- 引擎舞台高度固定为 1080；`ResponsiveHudLayout::resize(stageWidth)` 因而直接比较 `stageWidth < 1080`。
- 移动设计宽度为 393 pt；`unit = stageWidth / 393`，可用高度为 `1080 / unit`。393 × 852 是参考画布，不是强制屏幕尺寸。
- 横屏绘制继续走原 `NativeHud`、原卡片、原输入路径；移动排版必须在 `compact()` 分支内。新增共享接口的默认参数必须保留原行为。
- iPhone 当前固定竖屏，iPad 保持横屏：方向同时由 `InfoIOS.plist.in`、`IOSWindow.mm` 声明。窗口最小宽度放开到 320，便于桌面窗口验证响应式布局；默认窗口尺寸不变。
- 设置 `CADisableMinimumFrameDurationOnPhone`，让 iPhone ProMotion 设备可以使用屏幕支持的完整帧率（最高 120Hz）；iPad Pro 不依赖该键。`IOSDisplayLink.mm` 在 `QGuiApplication` 之前给 Qt 的 `CADisplayLink` 设置 80–120Hz 请求范围。包审计检查该键存在；高刷只改变系统允许的呈现上限，不改变布局或渲染节拍。

## 2. 调用链与代码地图

```text
QML 点击 / 拖动 / 原生输入
    → Engine::action / wheelInput / pointer
    → NativeHud 控制器 → 原 MusicLibrary / MusicPlayer / MusicDiscover / SettingsSchema
    → NativeHud::draw：整理共享卡片模型
        ├─ 横屏：保留原绘制命令与命中区域
        └─ 移动：ResponsiveHudLayout::arrange → Canvas → 过渡合成
    → NativeHud::state：文本输入、滑杆和手势几何
    → Engine::step → RhiScene：场景合成参数
```

| 文件 | 职责及维护入口 |
| --- | --- |
| `Qt/src/NativeHud.cpp` | 布局选择、共享状态组装、移动排版接入、列表选中项交回音乐层 |
| `Qt/src/ResponsiveHudLayout.h/.cpp` | 页面分派、滚动状态、393 pt 坐标换算、底部导航、指示条插值、QML 字段导出 |
| `Qt/src/ResponsiveHudPages.cpp` | 主界面、歌曲、集合详情、发现、队列、设置、检索的明确版式 |
| `Qt/src/ResponsiveLyrics.cpp` | 歌词换行缓存、跟随曲线、歌词页控制区、更多操作面板 |
| `Qt/src/ResponsiveHudCanvas.h/.cpp` | 颜色、字形、图标、裁剪、按钮、列表行与命中矩形；不请求数据、不改变播放状态 |
| `Qt/src/ResponsiveHudContent.h/.cpp` | 登录、确认等辅助弹层及设置自定义区的语义端口，直接接收文字、动作、图片、字段，禁止反向解析桌面绘图命令 |
| `Qt/src/ResponsiveHudTransition.h` | 歌词整页滑入滑出、拖动回弹、资料库与歌曲页的场景同步过渡 |
| `Qt/src/NativeHudDetail.cpp` | 生成歌曲与集合卡片模型；移动集合以只读 rowAt 闭包按可见窗口生成行，横屏仍提供原分页窗口 |
| `Qt/src/NativeHudDiscover.cpp` | 共用发现数据和封面缓存；移动端独立计算可见封面索引 |
| `Qt/src/NativeHudSettings.cpp` | 共用设置 Schema、可用性与自定义区动作 |
| `Qt/src/NativeHudPlayer.cpp` | 共用 `PlayerBar::State` 与 `PlaybackQueueCard::Model` |
| `Qt/src/NativeHudController.cpp` | `mobile:` 动作及原业务路由分发；普通移动 tab 不走弹窗关闭动画 |
| `Qt/src/NativeHudInput.cpp` | 区分场景滚动与移动内容滚动；移动坐标不落入桌面命中逻辑 |
| `Qt/qml/IOSInput.qml` | 列表稳定输入面、场景触摸、歌词正文滚动和页头下拉 |
| `Qt/qml/Overlay.qml` | 实际文本输入与滑杆；移动几何取自 C++，横屏使用原值 |
| `Qt/src/NativeApplication.cpp` | 按压序列的 HUD/场景所有权，避免拖动穿透成换列 |
| `Qt/src/NativeSceneCamera.cpp` | 移动歌曲正视角与构图；横屏视角沿用原公式 |

不要复制音乐请求、收藏权限、队列、排序、设置 Schema 或账号状态。布局接收只读模型，按钮输出已有动作；移动专用动作只补足展示和导航差异。

## 3. 坐标与输入：最容易出错的地方

存在三种坐标，必须分清：

1. **393 pt 设计坐标**：`ResponsiveHudCanvas` 内的版式。
2. **高度为 1080 的舞台坐标**：设计坐标乘 `unit`；`hits`、`fields` 和 C++ 输入使用此坐标。
3. **QML 窗口逻辑坐标**：舞台坐标乘 `stageScale = windowHeight / 1080`。物理 GPU 目标尺寸不参与 HUD 命中。

`Canvas` 在绘制命令中统一添加缩放，同时将命中矩形和字段乘 `unit`。QML 的位置要除 `stageScale` 再传给后端；`wheelInput` 的连续位移参数保持窗口逻辑距离，`Engine::wheel` 会再转换成舞台距离。移动触摸不要预先把位移除一次 `stageScale`，否则会重复缩放。

`Canvas::beginContent/endContent` 控制绘图裁剪，`hit/field` 控制可交互边界。部分可见的卡片需要先求可见矩形再建立命中；不能让正文命中覆盖迷你栏。重叠按钮按后绘制者优先，手动查找命中时要反向遍历 `hits`。

`state()` 输出的 `playerBounds`、`archiveListY`、`seek`、输入字段等必须来自同一次排版；不要在 QML 重算一份近似几何。辅助表单由 `compactaccount/compactcaptcha/compactsubmit` 指示字段是否可见。

## 4. 主界面的两个独立滚动区

主界面由真实资料库场景、四行曲目区、迷你播放栏和底部导航组成。

- 场景区和列表区各自占有从本区域开始的拖动。手指跨越边界不能改变所有者。
- `IOSInput.qml` 的列表 `MouseArea` 稳定覆盖整个列表，不能让随行重建的按钮接管拖动。
- 按下发 `mobile:archive-begin`，连续移动交给 `wheelInput`，松开或取消发 `mobile:archive-release`。
- `m_archiveOffset` 保存连续设计距离；行高 48 pt。内容随手指移动，黄色选中槽固定在第二行。
- 最近行发生变化才产生 `m_archiveSelection`。`NativeHud::draw` 通过 `takeArchiveSelection` 消费一次，再调用 `MusicLibrary::selectLibraryIndex`。
- 松开后使用 0.24 s `UiMotion::ReelCurve` 吸附；减少动态效果时立即对齐。滚轮无显式 release 时按空闲时间收束。
- 不得在重绘中无条件重设 offset；仅来源变化或明确外部选曲才重新对齐。
- 来源 tab 是不同功能。目录内物理唱片跨列时，选中 tab 仍依据最外层目录的 `parentLane`，不能依据当前物理列。
- `NativeApplication` 保留整个按压序列的 HUD 所有权，防止列表输入透到场景造成换列。

## 5. 动画规则

| 操作 | 允许的动画 |
| --- | --- |
| 顶部来源、发现分类、搜索分类、底部导航 | 页面内容立即更新；仅黄色指示条移动 |
| 资料库打开歌曲 / 返回 | HUD 交接跟随场景 `detail` 进度，不能另起独立计时造成不同步 |
| 打开歌词 / 关闭歌词 | 整页从底部滑入 / 向下滑出 |
| 歌词页头下拉 | 跟随拖动，舞台距离达到 90 时关闭，否则回弹 |
| 主界面曲目列表 | 连续位移，松开吸附；不能用刷新当前几行代替滚动 |

`tabIndicator(group, target)` 为不同栏保存独立位置，0.24 s cubic-out 插值；连续点击从当前位置接续。不要把 tab 或歌曲 ID 的变化一律解释为整个 HUD 的出入场。

`ResponsiveHudTransition` 只在移动布局调用。歌词手势命中区位于 60 pt 以下：横条和页头可拖动关闭，正文拖动只滚动歌词。页头文本、喜爱和更多也在灵动岛下方。过渡期间禁止使用最终位置的命中区。

新增曲线必须接入 `NativeHud::animating` / `ResponsiveHudLayout::animating`，并通过引擎唤醒，确保暂停播放时动画也能完成；同时不能在曲线结束后永久保持出帧。

## 6. 页面和安全区域约束

- 普通页底部：67 pt 迷你栏 + 43 pt tab 区 + **34 pt 系统手势留白**。不绘制系统小白条。
- 主界面显示四行，渲染可见区至少约半屏。`archiveListTop()` 统一计算列表起点。
- 歌曲页：专辑仍由 3D 场景取出，上方仅关闭入口，下方控制区允许覆盖资料库；无音量行。长标题最多两行并使控制区整体上移。
- 歌曲页区分浏览歌曲和正在播放歌曲：只有身份一致且可定位时才导出 seek 字段；不能拖动另一首歌曲的播放进度。
- 发现、搜索、设置使用不透明纸色背景；顶部中央为灵动岛留白，不添加横贯顶部的黑色装饰条。
- 导航第四项为设置，`saved` 路由仍保留用于既有收藏入口，不另建一套收藏业务。
- 集合详情保留全部已加载曲目的可浏览范围，但只调用 `rowAt` 构建可见行，末尾通过原 `music:directory-more` / `music:artist-more` 加载后续数据；不能把桌面的一屏模型当完整数据。资料库、搜索、发现和收藏页接近末尾时，由 `NativeHudInput` 调用原分页接口，不能在布局层另存加载标志。
- 歌词换行缓存比较整个文档，防止同曲重查得到相同行数但文字变化时继续显示旧内容。跟随滚动使用原 `UiMotion::ReelCurve`。

## 7. 业务动作边界

- `selectLibraryIndex` 只负责把序号映射到原物理槽位，再走统一选择流程；不要更改来源排序。
- `followPlaybackDetails` 由当前布局更新。移动端切歌不强制从主界面打开详情，横屏默认行为保持。显式点击迷你栏仍走 `player:detail`。
- `playDirectory(includeAllSongSources = false)`：默认参数保留原横屏来源限制；只有移动标题播放入口传 `true`，允许当前纯歌曲来源播放全部。无完整 ID 清单且仍有分页时，先补齐全部搜索结果，再建立队列；查询、账号或选择变化立即作废旧意图，空页或失败不得退化为播放当前页。
- `playCollection` 复用现有 `detail/songs` API 与队列补齐。独立的播放请求代数隔离重复点击，并检查原选择代数；不能通过增加选择代数来取消仍在运行的详情加载，否则其 loading 状态可能悬挂。
- 本地、塞壬、网络来源继续用原适配层；账号切换、过期响应、收藏权限和官方客户端交付不得在布局层重新实现。

## 8. 场景合成与帧生成

`Engine::step` 只在移动布局向场景附加：

| 字段 | 含义 |
| --- | --- |
| `mobileHud` | 手机布局标记 |
| `songPanelTop` | 歌曲控制区顶部，按高度归一化 |
| `songPanelTransition` | 控制区上缘渐变高度，按高度归一化 |

`RhiScene::Globals` 的 `backend` 四分量分别为：Y 翻转、面板顶部、渐变高度、手机标记。最终合成的 `opticalFinalFragment.frag` 使用手机标记隔离桌面侧边遮罩与移动亚克力；标记为 0 时沿用原横屏效果。不要改动其他分量的既有语义。

Apple MRT 运动附件清零通道只在移动布局运行，保护主颜色写入；解决背景清屏色被解释为运动矢量的问题。`FrameGenerationHistory` 只在进入/离开移动布局以及移动上下文变化时增加历史失效；横屏保留原有原点检测和重置逻辑。不能把手机残影修复扩散为桌面渲染行为变化。

## 9. 修改与验收

先检查当前工作区差异，避免覆盖其他任务的改动。串行运行：

```sh
npm run build
CI=true npm test
npm run build:ios
```

格式和静态检查入口为 `npm run format:check`、`npm run lint`、`git diff --check`。工具版本见 `requirements-format.txt`；缺失工具必须说明，不能扩大忽略范围。不要对第三方或生成目录做自主格式化。

核心验证位置：

- `Qt/tests/NativeHudChecks.cpp`：严格宽高切换、横竖往返快照、命中及输入坐标、四行连续滚动、来源隔离、集合尾曲可达、歌曲/歌词/队列、场景同步过渡。
- `Qt/tests/RenderChecks.cpp`：移动帧生成上下文隔离与桌面不额外重置。
- `scripts/audit-ios.py`：方向、系统依赖和高刷许可存在。
- `RHINE_HUD_CAPTURE_DIR` 可让原生 HUD 回归输出 393 × 852 检查图；这是离线绘制，不是 iPhone 截图。
- 应用 `--capture <目录> archive|detail` 可检查真实场景和 HUD 合成；设备、窗口尺寸和 GPU 应明确记录。

涉及横屏共享入口时，应将同一套原横屏固定输入在 Git 基线和当前版本分别运行，对比绘制命令及命中矩形。静态检查、离线截图和 macOS 构建均不能证明 iPhone 手感、GPU 残影或所有设备像素一致；这些仍需对应设备人工确认。

## 10. 必须守住的回归边界

- 分组列表序号先通过 `groupIndices` 转为原始序号，再复用 `selectResult`；目录任意跳转使用空 axis，不能发送固定的 `row +1`。
- 移动主路径先 `prepare` 页面作用域，再构建可见模型，不能调用整套桌面 brand/navigation/footer/archive 后丢弃输出。
- 集合 `rowAt` 闭包持有隐式共享的只读数组，不持有悬空业务对象；队列和网格用可见范围保留原始索引。2000 条数据的命令量仍须受视口限制。
- `hit` 和 `field` 与裁剪区求交，不得整块丢弃部分可见的控件。
- `ResponsiveHudContent::Model` 是文字、动作、图片、字段的语义接口。`modalBody` 和设置扩展区向该端口交付；添加输入字段必须显式声明，不能按桌面行坐标猜测。
- 启动 HUD 保持原 1920 × 1080 动画，但必须完整缩放居中到实际窄舞台；稳态过渡不复制命令数组。
- `Engine::action` 两种布局均使用 Input 唤醒，不能用布局布尔值把横屏降级为 Other。

`NativeHudChecks.cpp` 包含分组/目录映射、完整分页播放与取消、部分裁剪、2000 条长列表、手机登录与歌单表单、确认动作和启动画布回归。
