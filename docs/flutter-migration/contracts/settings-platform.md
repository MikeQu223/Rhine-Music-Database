# 设置分区与平台能力契约（冻结 v1）

状态：`FROZEN_FOR_IMPLEMENTATION`
冻结基线：`8ed3067b0812eb2612f7841ec127a6e8ca93231b`
规范来源：冻结基线下的 Qt 源码（`Qt/src/SettingsSchema.h`、`Qt/src/SettingsSchema.cpp`、`Qt/src/SettingsCard.h/.cpp`、`Qt/src/NativeHudSettings.cpp`、`Qt/src/NativeHudModal.cpp`、`Qt/src/NativeHud.cpp`、`Qt/src/PlatformFeatures.h`、`Qt/src/AppUpdater.h/.cpp`、`Qt/src/Host.cpp`、`Qt/src/DesktopLyrics*.h/.cpp`、`Qt/android/src/rhine/music/database/Consent*.java`、`Qt/qml/PerformancePanel.qml`）。旧 Flutter UI 不是规范。
证据等级：E1（直接读源码）。本文件产出期间未执行任何构建、测试、analyze、`flutter run`、Qt 编译/运行、Gradle/gradlew、`pub get`、代码生成、formatter、adb、APK 安装/卸载/清数据、截图、性能采集或运行协议验证。
适用：横屏 Qt 行为按本契约 1:1 迁移；竖屏只做重排新设计，保留全部语义，不伪造 Qt 竖屏基线。
生产接线：`ARCH_BLOCKED`。设备画面/手感证据：`DEVICE_BLOCKED`。
本文件只冻结协议与契约表，不代表任何 Flutter 侧已实现或已验收。
Owner: PLATFORM-CONTRACT (T06)

---

## 0. 本契约的地位

本契约是 Flutter 设置页（SYSTEM SETTINGS 模态）与平台能力的**唯一冻结来源**。任何 Flutter 实现出现下列情况即为偏离：

- 分区数量不为 7，或顺序/ID 与第 1 节不符。
- 缺少 Update / Performance（诊断）/ Storage 分区，或在 Android 上隐藏它们。（`Consent` 不在分区内，见第 11 节，同样不得移除。）
- 删除“当前平台不适用”的**行**；必须按第 2 节 `visible`/`enabled` 隐藏或禁用。
- 修改第 7 节的存储键名、第 6 节的规范化语义、第 9 节的更新状态文案语义。

证据等级说明：E0 = 设备实测；E1 = 直接读冻结基线源码；E2 = 推断。本契约全部条款为 E1，第 14 节列出未取得 E0 的条目。

---

## 1. 分区集合（硬冻结，`sections()`）

源码：`Qt/src/SettingsSchema.cpp:693-703`。渲染顺序由 `order` 升序决定（`Qt/src/NativeHudSettings.cpp:39-77` 跳过不可见分区并排序行）。

| # | order | id | titleEn | titleZh | customRenderer | customHeight | visible |
|---|---|---|---|---|---|---|---|
| 1 | 10 | `Provider` | `PROVIDER ACCESS` | `音乐平台` | `provider-card` | 160 | 恒 true |
| 2 | 20 | `Preferences` | `TERMINAL PREFERENCES` | `终端偏好` | 空 | 0 | 恒 true |
| 3 | 30 | `Performance` | `PERFORMANCE` | `性能与诊断` | `performance` | 220 | 恒 true |
| 4 | 40 | `Storage` | `STORAGE` | `存储与缓存` | `storage` | 105 | 恒 true |
| 5 | 50 | `Update` | `SOFTWARE UPDATE` | `软件更新` | `update` | 220 | 恒 true |
| 6 | 60 | `Project` | `PROJECT` | `项目与开源参考` | 空 | 0 | 恒 true |
| 7 | 70 | `Footer` | `CONFIG` | `配置管理` | `defaults` | 84 | 恒 true |

不变式：

- **I-1**：分区 ID 顺序恒为 `Provider, Preferences, Performance, Storage, Update, Project, Footer`；`number` 恒为 1..7；`order` 恒为 10,20,30,40,50,60,70。
- **I-2**：七个分区 `visible` 均为 `alwaysVisible`（恒 true），任何平台都不得隐藏 Update/Performance/Storage。
- **I-3**：`customHeight` 仅为自定义渲染区的**固定体高**；`Preferences` 与 `Project` 的 0 表示按行计算（见第 5 节）。

---

## 2. Preferences 分区行冻结表（23 行，源码 `SettingsSchema.cpp:352-662`）

列含义：`kind` 控件种类；`binding` 值来源（`Preference`=Host 偏好键 / `HudState`=HUD 运行态 / `Player`=播放器状态 / `External`=宿主激活态 / `Action`=纯动作）；`storage` 规范化类型；`default` 规范默认值；`options` 选项或数值范围；`visible`/`enabled` 运行条件；`label` 动态标签。

| order | id | kind | binding（键 / actionPrefix） | storage | default | titleEn | titleZh | options | visible / enabled | label / actionLabel |
|---|---|---|---|---|---|---|---|---|---|---|
| 100 | `window` | Action | Action `window:fullscreen` | None | — | `WINDOW` | `窗口显示` | — | visible = `PlatformFeatures::DesktopWindowControls` | actionLabel `切换全屏 / F11` |
| 110 | `close-behavior` | Choice | Preference `close-behavior` / `setting:close-behavior:` | TrayQuit | `quit` | `CLOSE WINDOW` | `点击关闭窗口` | `quit` 退出播放器 / `tray` 最小化到托盘 | visible = mac 或 win | — |
| 120 | `theme` | Choice | HudState / `setting:theme:` | Theme | `light` | `COLOR THEME` | `界面配色` | `light` 亮色 / `dark` 暗色 / `system` 跟随系统 | 恒显示 | themeLabel |
| 130 | `motion` | Choice | HudState / `setting:motion:` | ReducedFull | `full` | `REDUCED MOTION` | `动态效果` | `full` 完整动效 / `reduced` 减少动效 | 恒显示 | — |
| 140 | `startup-animation` | Choice | HudState / `setting:startup-animation:` | OnOff | `off` | `STARTUP ANIMATION` | `初始化动画` | `off` 关闭 / `on` 开启 | 恒显示 | — |
| 150 | `replay` | Action | Action `replay` | None | — | `INITIALIZATION` | `手动显示初始化页面` | — | 恒显示 | actionLabel `Reinitialize` |
| 160 | `quality` | Choice | Player / `quality:set:` | PlayerQuality | `exhigh` | `AUDIO QUALITY` | `音质` | `MusicPlayer::qualityOptions(provider)` 动态 | visible = 有播放器且非本地 | — |
| 170 | `alternative` | Choice | Player / `setting:alternative:` | PlayerAlternative | `off` | `ALTERNATE SOURCE` | `替代音源` | `off` 关闭（使用平台默认音质） / `on` 开启（音质由来源决定） | visible = 非本地且 provider == `netease` | — |
| 180 | `official-player` | Choice | External `music:activate` / `setting:official-player:` | ExternalBool | `off` | `OFFICIAL PLAYER` | `官方窗口` | `off` 尽量保持后台 / `on` 播放时显示 | visible = `PlatformFeatures::OfficialPlayback` 且非本地 | — |
| 190 | `detail-autoplay` | Choice | Preference `detail-autoplay` / `setting:detail-autoplay:` | OnOff | `off` | `ENTER AUTOPLAY` | `进入详情自动播放` | `off` 关闭 / `on` 开启 | 恒显示 | — |
| 200 | `single-play-mode` | Choice | Preference `single-play-mode` / `setting:single-play-mode:` | AppendReplace | `replace` | `PLAYLIST ON PLAY` | `点击播放单曲` | `replace` 替换为所在列表 / `append` 仅添加当前单曲 | 恒显示 | — |
| 205 | `desktop-lyrics` | Action | Action `desktop-lyrics:open` | None | — | `DESKTOP LYRICS` | `桌面歌词` | — | visible = `PlatformFeatures::DesktopLyrics` | actionLabel `样式与同步` |
| 210 | `archive-mask` | Stepper | HudState / `archive-mask:` | HudCachedInt | `50` | `RIGHT MASK` | `右侧画面遮罩` | min 0 / max 100 / step 10 | 恒显示 | archiveMaskLabel：0 → `0 · 关闭`，否则 `N%` |
| 220 | `graphics-backend` | Choice | Preference `graphics-backend` / `setting:graphics-backend:` | Enum | 非 Darwin 无 `defaultValue`（未知则回落到首选项 `""` = 默认/自动探测）；Darwin 选项仅 `metal`，回落解析为 `metal` | `GRAPHICS BACKEND`（Darwin：`METAL RENDERER`） | `图形后端`（Darwin：`渲染模式`） | 非 Darwin：`` 默认 / 自动探测``、`vulkan` Vulkan、`opengl` OpenGL（+`d3d12` Direct3D 12，仅当 `RHINE_ENABLE_D3D12_BACKEND`）；Darwin：`metal` Metal | enabled = 非 Darwin；非 Darwin 有 restartHint `重启生效` | graphicsBackendLabel |
| 230 | `gpu-index` | Choice | Preference `gpu-index` / `gpu-index:` | Enum | `""` | `GPU` | `显卡` | `` 默认 / `i` 显卡 i（i 为 0-based 设备序号） | visible = Linux 且 `gpuDeviceCount() > 1` | restartHint `重启生效`；gpuIndexLabel |
| 240 | `vsync` | Choice | HudState / `setting:vsync:` | HudCachedBool | `on` | `V-SYNC` | `垂直同步` | `off` 关闭 / `on` 开启 | visible = 非 Darwin | restartHint `重启生效` |
| 250 | `render-scale` | Stepper | Preference `render-scale` / `render-scale:` | Integer | `RhineRender::androidDefaultRenderScale()`：Android **75**（`RHINE_ANDROID_RENDER_SCALE=50..100` 覆盖；`RHINE_ANDROID_RENDER_TUNING=0` 退回 100），iOS/桌面 **100** | `RENDER SCALE` | `渲染分辨率` | steps {50,60,75,90,100} | 恒显示 | renderScaleLabel：100 → `100% · 原生`，否则 `N%` |
| 260 | `aa-mode` | Choice | Preference `aa-mode` / `aa-mode:` | Enum | `off` | `AA & UPSCALING`（Darwin：`METALFX`） | `抗锯齿与超分辨率`（Darwin：`时域抗锯齿与超分辨率`） | 非 Darwin：`off` 关闭 / `fxaa` FXAA / `ssaa` SSAA / `msaa` MSAA / `taa` TAA / `fsr` FSR；Darwin：`off` 关闭 / `metalfx` MetalFX Temporal | enabled = 非 Darwin true，Darwin 取决于 `RhineFg::capability().temporalAvailable` | aaModeLabel（Darwin 不支持时 `系统或设备不支持`） |
| 270 | `aa-scale` | Stepper | Preference `aa-scale` / `aa-scale:` | Integer | `125` | `AA SCALE` | `抗锯齿倍率` | min 100 / max 200 / step 25 | visible = 非 Darwin 且 `aa-mode == ssaa` | percentLabel `N%` |
| 280 | `msaa` | Stepper | Preference `msaa` / `msaa:` | Integer | `4` | `MSAA SAMPLES` | `多重采样倍率` | steps {2,4,8} / wrap true | visible = 非 Darwin 且 `aa-mode == msaa` | msaaLabel `Nx` |
| 290 | `fsr-quality` | Choice | Preference `fsr-quality` / `fsr-quality:` | Enum | `native` | `FSR QUALITY` | `FSR 档位` | `native` 原生 AA / `quality` 高质量 / `balanced` 平衡 / `performance` 性能 / `super` 超级性能 | visible = 非 Darwin 且 `aa-mode ∈ {fsr, fsr1, fsr3}` | — |
| 300 | `fsr-sharpness` | Stepper | Preference `fsr-sharpness` / `fsr-sharpness:` | Integer | `50` | `FSR SHARPNESS` | `FSR 锐化` | min 0 / max 100 / step 10 | visible 同 `fsr-quality` | percentLabel `N%` |
| 310 | `fg` | Choice | Preference `fg` / `setting:fg:` | OnOff | `off` | `FRAME GENERATION` | `帧生成` | `off` 关闭 / `on` 开启 | visible = Darwin only；enabled = `frameGenerationState().clickable` | fgLabel（`frameGenerationState().value`，受 `RHINE_FG` 环境变量覆盖） |

注（`graphics-backend` 默认值）：该行未设置 `defaultValue`，`normalize` 在未知值时回落到“首个选项”。非 Darwin 的首选项为空字符串，表示**默认 / 自动探测**，不得改写为 `auto` 之类的其它取值；Darwin 的首选项为 `metal`，因此同一份空偏好在该平台解析为 `metal`。

注（`render-scale` 默认值）：`SettingsSchema.cpp:565` 的注释仍写着“Android 90，其它平台 100”，但 `Qt/src/render/AndroidRenderPolicy.h:106-116` 的 `androidDefaultRenderScale()` 在 Android 上返回 **75**（`RHINE_ANDROID_RENDER_SCALE=50..100` 覆盖；总开关 `RHINE_ANDROID_RENDER_TUNING=0` 退回 100），非 Android 返回 100。**以函数为准，注释是过期文本**；实现必须与 `main.cpp::applyRenderScaleSetting()` 的同一函数消费点保持一致。

---

## 3. Project 分区：8 条链接（源码 `SettingsSchema.cpp:664-687`）

全部为 `kind = Link`、`section = Project`、`storage = None`、`binding = Action`，`order = 10 + index`，且 `titleEn == titleZh == actionLabel == label`。

| order | id | action | label（= titleEn = titleZh = actionLabel） |
|---|---|---|---|
| 10 | `project-home` | `music:project-home` | `本项目 / Rhine Music Database` |
| 11 | `project-author` | `music:project-author` | `网易云音乐 API / api-enhanced` |
| 12 | `project-player` | `music:project-player` | `QQ 音乐 API / qq-music-api` |
| 13 | `project-kugou` | `music:project-kugou` | `酷狗音乐 API / KuGouMusicApi` |
| 14 | `project-rhine` | `music:project-rhine` | `界面原项目 / RhineLabUI` |
| 15 | `project-lyricsx` | `music:project-lyricsx` | `歌词参考 / LyricsX` |
| 16 | `project-lyricskit` | `music:project-lyricskit` | `格式移植 / LyricsKit` |
| 17 | `project-lyrimuse` | `music:project-lyrimuse` | `同步与匹配参考 / Lyrimuse` |

链接行以两列网格排布（见第 5 节），点击命中 `binding.action`。

---

## 4. 自定义渲染分区的内容冻结（源码 `NativeHudSettings.cpp:227-380`）

这些分区没有 descriptor 行，内容由自定义渲染器绘制，因此必须逐条冻结，否则最易被“顺手删掉”。

### 4.1 Provider（`provider-card`，height 160）

卡片（`body.left, body.top+4, body.width, 80`，填充 `soft`）：

- 左侧 3px 金色条：`fill(card.left, card.top, 3, card.height, gold)`。
- 46×46 Apple Music 标记（`card.left+14, card.top+17`）：`save/translate/scale(46/24)` 后依次 `fill-path` `AppleMusicIcon`（ink）与 `AppleMusicNote`（panel）；**所有平台统一使用单色图标**。

- 文本 `CURRENT PROVIDER / 当前平台`（10pt muted，`card.left+74, card.top+10`）。
- `providerName`（20pt demibold，`+74/+24`）。
- `provider.toUpper()`（10pt muted，`+74/+52`）。
- 切换按钮（`card.right-126, card.top+23, 110, 34`）：action `provider`；**绘制文案为 `切换平台 ▾`，命中标签为 `切换平台`**（`actionBlock(rect, "切换平台 ▾", "provider", "切换平台", true)`）——两者不同，不得合并。

账号行（`body.left, body.top+98, 320, 46`）：

- `isLocal` → `文件夹管理 / 导入与索引`，action `discover`。
- `isSiren` → `塞壬唱片` 纯文本，**无 action**。
- uid 为空 → `登录 / <providerName>`，action `music:login`。
- 否则 → `退出登录 / <nickname>`，action `music:logout`。

右侧注释：siren → `官网曲库 / 无需登录`；QQ 已有 uid → 会员态映射 `{free 免费账号, green 绿钻会员, super 超级会员, unknown 会员状态未知}`；其它 → `各平台账号独立保存`。

平台选择器（`NativeHudModal.cpp:12-24, platformChoices`）：候选 5 项 = siren/netease/qq/kugou/local；**当 `!PlatformFeatures::LocalMusic` 时移除 local 项**（Android/iOS 恒为 4 项）。卡片间隙 12，宽度 `(width-12*(n-1))/n`，高度 展开 190 / 收起 66，命中 `provider:<id>`，选中项左侧 3px 金色条。

### 4.2 Performance（`performance`，height 220）— 诊断保留项

- 行 ① `PERFORMANCE / 性能面板`，label `显示 / 隐藏 · F10`，action `performance:toggle`；帮助文案 `在性能面板内手动收集、导出诊断文件。`（`top+78`）。
- 行 ② `DISC ROTATION / 唱片旋转`，label `discRotation ? 开启 / 点击关闭 : 关闭 / 点击了解风险`，action `disc-rotation`；帮助文案 `默认关闭；开启会增加持续渲染、耗电和发热。`（`top+176`）。
- 每行控件区 `(body.right-300, top+8, 300, 48)`，下划线 `top+62`。

性能面板本体（`Qt/qml/PerformancePanel.qml`，F10 切换）必须保留：标题文本 `profiler.headline`；`profiler.details` 可滚动诊断文本（`rhineFontFamily`、12pt、行高 1.35、自动换行）；四个按钮（140×30 `recordingAction` 收集或导出性能诊断 → `profiler.toggleRecording()`；82×30 `诊断目录` → `profiler.openReportFolder()`；50×30 `精简/展开` → 展开态切换；50×30 `关闭` → `profiler.toggleVisible()`），Accessible.name 分别为 `收集或导出性能诊断` / `打开诊断目录` / `展开或精简性能面板` / `关闭性能面板`。**不得因“移动端不适用”而移除诊断入口。**

### 4.3 Storage（`storage`，height 105）

- 标题 `STORAGE / 存储与缓存`。
- 控件块 label = `cacheMessage.isEmpty() ? 清除缓存 : cacheMessage`，action `cache:clear`。
- 帮助文案 `清理元数据、歌词、封面与列表缓存，保留主题和账号。`（`top+72`）。

后端语义（`Qt/src/Host.cpp:1033-1036`）：清缓存除缓存目录外还删除 `cacheDirectory()/qml` 与 `/shaders`；**不清除**偏好（主题等）与账号凭据。

### 4.4 Update（`update`，height 220）

- 版本行：`当前版本 / <AppUpdater::currentVersion()>`（18pt demibold，`top+4`）；非发布构建追加 ` · 开发版`。
- 非发布构建再加 `AppUpdater::commitTitle()`（12pt，`top+32`）。
- 自动检查块（`body.right-300, top+50, 300, 48`）：`preference(auto-update) == off ? 启动检查 / 关闭 : 启动检查 / 开启`，action `update:auto`。
- `updater.status()`（13pt，`top+68`）。
- 检查块（`body.left, top+112, 170, 46`）：label `busy() ? 取消 : 检查更新`，action `busy() ? update:cancel : update:check`。
- 仅当 `!busy && available()`：附加块（`body.left+186, top+112, 210, 46`）`前往更新 ↗`，action `update:release`。
- **无条件恒绘制**：`发布说明 ↗`（`body.right-210, top+112, 210, 46`），action `update:release`——它不在 `!busy && available()` 条件内（源码 `NativeHudSettings.cpp:365-366`），不得并入上一行。
- 帮助文案 `更新将打开 GitHub 发布页面，请在浏览器中下载并安装。`（12pt，`top+176`）。

### 4.5 Footer（`defaults`，height 84）

- 恢复块（`body.left, body.top+6, 300, 46`）：label `恢复默认设置`，action `settings:restore-defaults`。
- 帮助文案 `仅重置终端偏好，平台、账号与更新状态保持不变。`（12pt，`body.left+316, top+20`）。

---

## 5. 布局几何（硬冻结常量，1:1）

源码：`Qt/src/SettingsCard.cpp:9-19, 239-292`。

常量：`HeaderHeight = 46`、`SectionGap = 24`、`RowHeight = 66`、`RowStep = 76`、`OptionHeight = 50`、`BottomPad = 28`、`ContentInset = 14`、`ControlWidth = 300`、`LinkGap = 16`、`LinkRowHeight = 50`、`LinkRowStep = 60`。

算法（`viewport` 为设置内容可视区）：

1. `left = viewport.left + 14`；`width = viewport.width - 28`。
2. 每个分区：header = `(viewport.left, cursor, viewport.width, 46)`，`cursor += 46`。
3. 自定义渲染区：body = `(left, cursor, width, customHeight)`，分区高 = `46 + customHeight`，`cursor += customHeight + 24`。
4. Project：两列网格，`linkWidth = (width - 16) / 2`，第 i 行 bounds = `(left + (i%2)*(linkWidth+16), cursor + (i/2)*60, linkWidth, 50)`，bodyHeight = `((n+1)/2)*60`。
5. 普通行区：每行 bounds = `(left, cursor, width, 66)`；control = `(left + width - 300, cursor + 9, 300, 48)`；若该行展开且 enabled，options = `(control.left, cursor + 68, 300, choices*50 + 4)`，`optionsHeight = choices*50 + 4`；`cursor += 76 + optionsHeight`。
6. `contentHeight = cursor - viewport.top + 28`；`maximumScroll = HudScroll::maximum(contentHeight, viewport.height)`。

文本与命中（`SettingsCard.cpp:36-236`）：分区标题**左侧**两位序号 `rightJustified(2,"0")`（11pt muted，绘制于 `header.left()+ContentInset`，与内容左缘对齐，`SettingsCard.cpp:38-41`）；标题行 `titleEn + " / " + titleZh`（14pt demibold，`left+26, top+9`）；行内**左侧**两位行号（11pt muted，`rect.left()` / `top+25`，`SettingsCard.cpp:198`）、`titleEn`（11pt muted，`+30/top+10`）、`titleZh`（17pt demibold，tracking -0.01，`+30/top+25`）、`restartHint`（10pt muted，`+30/top+50`）；禁用行 ink 透明度 0.35 / muted 0.28。交互：Choice 控件框命中 `expand:<id>`（Android 变体移除左侧标题热区，桌面/iOS 保留整行命中 `binding.action`）；Stepper 减号命中 `prefix+decrementValue`、加号命中 `prefix+incrementValue`、滑轨分段命中 `prefix+value`；Action 命中 `binding.action`；Link 整块命中 `binding.action`；展开的选项行命中 `actionFor(row)+choice.value`（`actionFor = actionPrefix 非空 ? actionPrefix : action`）。

设置模态框架（`NativeHudModal.cpp`）：类别标签 `RHINE LAB / MUSIC DATABASE / SYSTEM PREFERENCES`（settings 时 14pt，否则 11pt，`x+53, y+37`）；标题 `SYSTEM SETTINGS`（38pt demibold，`x+53, y+91`）；副标题 `终端偏好设置`（18pt，`x+53, y+147`）；返回按钮 `← 返回`（`x+usable-220, y+18, 167, 54`，命中 `close-modal`）。设置可视区在 `NativeHud.h:115-116`：`SettingsViewportTop = 176`、`SettingsViewportBottom = 836`；滚轮步长 66（`NativeHudInput.cpp:30-33`）；滚动按钮 `settings:scroll-up` / `settings:scroll-down`（`NativeHudSettings.cpp:163-225`）。

---

## 6. 值规范化 / 读取 / 切换（源码 `SettingsSchema.cpp:718-926`）

**normalize（718-787）**：按 `storage` 分派；`OnOff`/`ReducedFull`/`Theme`/`TrayQuit`/`AppendReplace` 逐项白名单，非法值回落 `defaultValue`（缺失时用该类型的固定兜底：`off`/`full`/`light`/`quit`/`replace`）；`PlayerQuality` 非法值回落 `defaultValue`，仍非法则取首个选项；`PlayerAlternative`/`ExternalBool`/`HudCachedBool`/`Capability`/`Updater` 归一为 `on|off`；`Integer`/`HudCachedInt` 解析整数，失败回落 `defaultValue`，再失败取 `minimum`；**有 `steps` 时先取最近档位（nearestStep）**，否则 `clamp(minimum, maximum)`；`Enum` 特例：`aa-mode` 的 `fsr1`/`fsr3` 归一为 `fsr`，`graphics-backend` 的 `d3d11` 归一为空串，随后按“选项命中 → defaultValue → 首选项”回落；`None` 返回 `raw.isEmpty() ? defaultValue : raw`。

**read（789-849）**：按 `binding.kind` 取值 —— `Preference` 取 `host->preference(preferenceKey)`；`HudState` 按 storage/id 映射到 `themeMode`、`reduced`、`startupAnimation`、`vsync`、`archiveMaskStrength`；`Player` 取 `player.quality` / `player.alternative`；`External` 取 `host->activates()`；`Capability`/`Updater` 取偏好；`Action`/`CustomSection` 直接返回空值。随后 `isDefault = raw.isEmpty()`、`canonical = normalize(...)`、`boolean = canonical ∈ {on, reduced, tray, append}`、`integer = canonical.toInt()`、`valid = ok || !canonical.isEmpty()`。Darwin 上 `fg` 受环境变量 `RHINE_FG` 覆盖。

**visible/enabled（858-864）**：无谓词即恒 true。

**switchTarget（866-889）**：选项 ≥2 时取当前项的下一个（环形）；否则按 storage 取反（`ReducedFull`、`TrayQuit`、`AppendReplace` 各自二元，其余 `on/off` 互转）。

**nextValue（891-926）**：Choice 按选项索引 `clamp(index + direction, 0, n-1)`；Stepper/Slider 有 `steps` 时按档位索引，`wrap` 用环形，否则 clamp；无 `steps` 时 `clamp(integer + direction * max(1, step), minimum, maximum)`。

**注册表校验（928-1004，实现必须保留等价断言）**：分区 id 唯一、标题/编号非空；descriptor id 唯一、分区存在、双语标题非空；Preference 键必须在 `Host::isPreferenceKey` 白名单内；Action 必须有 action；Choice/Stepper/Slider 必须有 `action` 或 `actionPrefix`；action 全局唯一；选项值非空且不重复；静态选项必须包含 `defaultValue`；`minimum <= maximum`；`step >= 0`；`steps` 有序且包含 `defaultValue`。

---

## 7. 存储键与持久化

后端：`AppStorage::settings()`（`QSettings`），区段前缀 **`panel/`**，即实际键为 `panel/<key>`（`Qt/src/Host.cpp:1061-1106`）。写入前置条件：非离线、值长度 `< 262144`、键在 `Host::preferenceKeys()` 白名单内。`Host::isPreferenceKey` 为白名单判定。写入后发 `preferenceChanged` 的条件是**平台**为 Darwin/Windows，**不是** remote 与否：remote 分支（`Host.cpp:1089-1091`）与本地分支（`1102-1104`）都在 `#if defined(Q_OS_DARWIN) || defined(Q_OS_WIN)` 内 emit。**remote 分支**（后台服务模式）走 `remote->call("host.setPreference", …)` 后 `remotePreferences.remove(key)`，**绕过**白名单/长度/离线三重校验（`Host.cpp:1078-1092`）；读侧同理由 `cacheHost` 回填（`1061-1071`）；`fg` 热应用（`RhineFg::applyInterpolationPreference`）在两个分支都会执行。

设置页直接持久化的键（`Host.cpp:1041-1059`）：

`theme`, `motion`, `startup-animation`, `detail-autoplay`, `single-play-mode`, `disc-rotation`, `scene-enhancement`, `archive-mask-strength`, `graphics-backend`, `gpu-index`, `vsync`, `supersample`, `render-scale`, `aa-mode`, `aa-scale`, `msaa`, `fsr-quality`, `fsr-sharpness`, `fg`, `close-behavior`, `auto-update`, `quality`, `alternate-source`, `provider`, `volume`。

设置页外但对齐须一致的键：`search-history`, `play-history`, `local-cover-cache`, `lyrics-cache`, `lyrics-global-offset-ms`, `welcome-name-*`, `account-id-*`, `kugou-edition`。

桌面歌词键（mac/win）：`desktop-lyrics` + 11 个外观键，见第 12 节。

注意：descriptor 中的 `preferenceKey`（如 `close-behavior`、`detail-autoplay`、`single-play-mode`、`graphics-backend`、`gpu-index`、`render-scale`、`aa-mode`、`aa-scale`、`msaa`, `fsr-quality`, `fsr-sharpness`, `fg`）直接作为 QSettings 键的 `<key>` 部分；`StorageType` 只描述取值域，不改变键名。

---

## 8. 平台能力矩阵（源码 `Qt/src/PlatformFeatures.h:1-25`）

`RHINE_MOBILE` 定义时（Android/iOS）四项能力为 **false**，桌面构建为 **true**。这是平台事实，**不是 TBD**，不得在 Flutter 侧按“尚未实现”而改成 unknown/可变。

| 能力 | Android | iOS | Windows | macOS | Linux |
|---|---|---|---|---|---|
| `OfficialPlayback` | false | false | true | true | true |
| `LocalMusic` | false | false | true | true | true |
| `ApplicationVolume` | false | false | true | true | true |
| `DesktopWindowControls` | false | false | true | true | true |
| `DesktopLyrics` | false | false | true | true | **false** |

派生后果（必须一致）：

- `DesktopLyrics` 为 false 时：Preferences 的 `desktop-lyrics` 行不可见；`restoreSettingsDefaults` 不触碰桌面歌词键。
- `OfficialPlayback` 为 false 时：`official-player` 行不可见（且还需非本地）。
- `LocalMusic` 为 false 时：平台选择器为 4 项（无 `local`），且不得出现“文件夹管理/导入索引”入口。
- `ApplicationVolume` 为 false 时：不得暴露应用音量控制（本轮 Flutter 侧尚未接线，见第 14 节）。

---

## 9. 更新检查 / 下载 / 安装 / 失败（`Qt/src/AppUpdater.h/.cpp`）

**调用与状态**：`check()` 在 `busy()` 时为空操作；离线时失败文案 `离线模式不检查更新`；处于限流窗口时直接返回限流文案；否则状态先置 `正在检查更新…`。

**数据源**：先取静态清单 `https://github.com/MikeQu223/Rhine-Music-Database/releases/latest/download/update.json`；404 时回退 API `https://api.github.com/repos/MikeQu223/Rhine-Music-Database/releases/latest`（`Accept: application/vnd.github+json`、`X-GitHub-Api-Version: 2022-11-28`）。读取上限 1 MiB（超出即中止）、传输超时 30s、重定向策略 `NoLessSafeRedirectPolicy`、UA `RhineMusicDatabase/<currentVersion>`。

**版本判定**：`isNewer` 要求严格 `x.y.z`（每段 ≤ 65535，允许前导 `v`）；`current` 为空视为更新。

**产物选择**（`selectRelease`）：拒绝 draft/prerelease/非法 tag、非更新版本、非官方 `html_url`（不等于 `https://github.com/MikeQu223/Rhine-Music-Database/releases/tag/<tag>`）、缺少名为 `RhineMusicDatabase-<tag>-<platform>` 的产物或非官方下载地址、大小 ≤ 0、> 2 GiB、非整数大小、产物状态非 `uploaded`。错误文案：`发布版本格式无效，或不是正式版本`、`发布页面地址无效`、`发布产物信息不完整，请查看发布页面`、`新版本尚无适合当前架构的更新包，请查看发布页面`。

**平台产物**（`platformAsset()`）：Android → 空串（**只让 `selectRelease` 跳过“按平台匹配产物”循环**，`AppUpdater.cpp:73-76`、`:117`；**`check()` 本身没有 Android 分支**，仍会无条件发起网络请求，最终停在 `:135` 文案）；iOS → `ios-unsigned.ipa`；macOS arm64 → `macOS-arm64.zip`；Windows x86_64 → `Windows-x64-Setup.exe`；Linux x86_64 → `Linux-x86_64.AppImage`；其它 → 空串。

**结果文案**：API 404 → `尚无正式发布版本`；解析失败 → `更新服务返回了无效数据`；成功且有更新 → `发现新版本 <tag>` 并发 `updateAvailable`；成功无更新 → `当前已是最新版本`。**`m_release` 的保留/清空分界**：网络/HTTP/解析失败于 `AppUpdater.cpp:226-243` 提前 `return`，**保留**上一次发布信息；但 `:248` 的 `m_release = release;` 早于 `:249-252` 的 `selectRelease` 错误检查，故 draft/prerelease/非官方地址/产物校验失败时 `selectRelease` 返回 `{}`，会**清空** `m_release`（`available()` 变 false、`前往更新 ↗` 入口消失）。

**限流**：429，或 403 且（`X-RateLimit-Remaining == 0` 或带 `Retry-After` 或消息含 `rate limit`）→ 置 `retryAtUnix = now + min(Retry-After, 86400)` 或 `X-RateLimit-Reset`，文案 `当前网络出口的 GitHub 更新检查额度已用尽，请在 HH:mm:ss 后重试或查看发布页面`；普通 403 → `GitHub 拒绝访问更新服务（HTTP 403），请检查代理或查看发布页面`；其它 → `检查失败，请检查网络后重试`。既无 `Retry-After` 也无 `X-RateLimit-Reset` 时，回落常量 `DEFAULT_RETRY_SECONDS = 60`（`AppUpdater.cpp:169-171`）。

**取消**：`cancel()` → `已取消，可重新检查`。

**下载/安装**：Qt 侧**没有**应用内下载或安装。`openRelease()` 只调用 `QDesktopServices::openUrl(https://github.com/MikeQu223/Rhine-Music-Database/releases)`，即“在浏览器中下载并安装”。Flutter 侧不得凭此实现静默下载/自安装；必须沿用“打开发布页面”语义。**Android 检查语义**：Qt 基线在 Android **仍会**发起检查（无平台分支，只是无可匹配产物）；若 Flutter 侧选择“Android 不发起检查”，必须显式标注为**相对 Qt 基线的有意偏离**（见第 13 节），不得伪装成基线语义。

---

## 10. 恢复默认（`NativeHudSettings.cpp:492-525`）

`restoreSettingsDefaults()` 语义，必须逐条保留：

1. 清空展开态 `expandedPreference`。
2. 遍历 descriptor：**跳过** `Action`/`Link`/`Custom`/`CustomSection`，以及 `visible == false` 的行。
3. `gpu-index` 特例 → `setPreference(gpu-index, "")`（复位为默认/自动），不走通用默认值路径。
4. 其余行 → `applySettingValue(id, defaultValue)`（注意：走的是**同一套写入语义**，即偏好写入、播放器动作、图形动作等各自的分派）。
5. 若 `discRotation` → 触发 `disc-rotation` 动作。
6. `setPreference(auto-update, "")`。
7. 若 `PlatformFeatures::DesktopLyrics` → `setPreference(desktop-lyrics, "off")` + `DesktopLyrics::resetAppearance(host)` + 置 `desktopLyricsAppearanceLoaded = false`。
8. `settingsScroll = 0`；`refreshSettingsLayout()`；状态栏文案 `已恢复默认设置`；末行 `m_host->invalidate()` 请求重绘（`NativeHudSettings.cpp:524`）。

边界：**平台、账号、更新检查结果与更新限流状态不因恢复默认而改变**（这也是 Footer 帮助文案的承诺）。

---

## 11. 同意门与诊断链（Android，`Consent*`）— 不可消失项

- `ConsentActivity` 是 Android 上**唯一 LAUNCHER**；`QtActivity` 不对外暴露（`Qt/android/src/main/AndroidManifest.xml`、`build.gradle`）。因此 **Qt 界面在同意（或本次判定放行）之前不会启动**。**诊断 SDK 有例外**：只有 CN/EU 弹窗路径与后台唤醒路径（`RhineApplication.java:20-22`）以同意为前置；非 CN/EU 或区域探测超时时 `ConsentActivity.java:100-105` 直接 `proceed(region)` → `:148-149` `startSdks` → `ConsentStore.java:81-93` 仅凭 `!clarityStarted` 即初始化 Clarity，即**未同意、未弹窗也会启动 Clarity**。
- `ConsentStore`：偏好文件 `rhine-consent`，键 `granted` / `region`。`Clarity`（ID `z8vbz4b078`）**总是**启动（每次进程一次，独立幂等标志；注意这不等于“仅同意后启动”）；`Bugly`（ID `22c01c69b9`，debug false，native monitor true）**仅当 region == 中国大陆**时启动。区域判定结果**不缓存**。
- 同意弹窗：中国大陆标题 `隐私与数据传输许可`，其它区域 `Data Transfer Consent`；按钮 同意/退出 或 Agree/Exit；`setCancelable(false)`、`setCanceledOnTouchOutside(false)`、拦截返回键；拒绝 → `finishAffinity()` 退出；同意 → 写入 `granted` + `region` 并进入 QtActivity。
- 区域为 CN/EU 之外的地区或探测超时 → 直接进入，且**不落盘** region。
- 隐私文案必须如实描述 Clarity 与 Bugly 的采集项与跨境传输；不得删减或改写成更弱承诺。

Flutter 迁移不得移除或弱化该同意门；本轮不实施（见第 14 节）。

---

## 12. 桌面歌词（`DesktopLyrics`，mac/win only）

入口：Preferences 行 `desktop-lyrics`（action `desktop-lyrics:open`，label `样式与同步`）→ 模态 `desktop-lyrics`（标题 `DESKTOP LYRICS` / `桌面歌词 / 样式与同步`，返回按钮命中 `desktop-lyrics:back`，滚动按钮 `desktop-lyrics:scroll-up|scroll-down`，动作前缀 `desktop-lyrics:`）。

存储键与默认值（`Qt/src/DesktopLyricsLayout.h:15-46`、`DesktopLyricsAppearance.cpp:52-97`）：

| 键 | 默认值 | 域 |
|---|---|---|
| `desktop-lyrics` | `off`（关闭） | 开关 |
| `desktop-lyrics-size` | 32 | 20..60 |
| `desktop-lyrics-translation-size` | 24 | 16..48 |
| `desktop-lyrics-opacity` | 100 | 20..100 |
| `desktop-lyrics-line-color` | `#f5f6f2` | 颜色 |
| `desktop-lyrics-translation-color` | `#f5f6f2` | 颜色 |
| `desktop-lyrics-line-weight` | `bold` | light/regular/demibold/bold |
| `desktop-lyrics-translation-weight` | `regular` | 同上 |
| `desktop-lyrics-line-outline` | 1.5 | 0..4，步长 0.5 |
| `desktop-lyrics-translation-outline` | 1 | 0..4，步长 0.5 |
| `desktop-lyrics-line-outline-color` | `#000000` | 颜色 |
| `desktop-lyrics-translation-outline-color` | `#000000` | 颜色 |

规范化：整数按上下限 clamp；描边四舍五入到 0.5 步长并 clamp 到 0..4（写出时以一位小数 `QString::number(v,"f",1)`）；颜色经 `QColor` 校验，非法回落默认色并**小写化**；字重白名单 `light/regular/demibold/bold`，非法回落默认。`isAppearanceKey` 对 `desktop-lyrics-size` 与其余 10 项均为 true（正文尺寸键名沿用旧键）。

页面行顺序（`DesktopLyricsSettingsPage.cpp`）：`ENABLED 显示桌面歌词`、`OPACITY 整体透明度`、然后第 1 节（主歌词）`SIZE 字号`/`WEIGHT 字重`/`COLOR 颜色`/`OUTLINE 描边`/`OUTLINE COLOR 描边颜色`，接着第 2 节（翻译）同五项，随后 `OFFSET 歌词偏移`（偏移动作按钮），最后 `恢复默认样式` 重置按钮。

约束：`DesktopLyrics` 为 false 的平台（Android/iOS/Linux）不出现入口、页面与键写入；**不得删除键定义与文档**。

---

## 13. 硬性不变式汇总（MUST / MUST NOT）

- **MUST** 保持 7 分区、ID 顺序与 order 如第 1 节。
- **MUST** 保留 Update、Performance（诊断）、Storage 分区在所有平台可见；保留 Android 同意门。
- **MUST** 按第 2/8 节的 `visible`/`enabled` 隐藏或禁用不适用的**行**；**MUST NOT** 删除行定义。
- **MUST** 使用第 7 节的 QSettings 键名（`panel/<key>` 前缀）与第 12 节的桌面歌词键名。
- **MUST** 复刻第 5 节的几何常量与布局算法（至少：46/24/66/76/50/28/14/300/16/50/60 与 settings viewport 176..836）。
- **MUST** 复刻第 6 节的 normalize/read/switch/next 语义与注册表校验断言。
- **MUST** 让“恢复默认”满足第 10 节的边界承诺（平台/账号/更新状态不变）。
- **MUST NOT** 实现应用内静默下载/自安装；`openRelease()` 只打开发布页面。
- **偏离项（非 Qt 基线）**：Qt 基线在 Android **仍会**发起更新检查（仅无可匹配产物）。若 Flutter 在 Android 跳过检查，属于**有意偏离**，必须在此显式标注，不得写作基线不变式。
- **MUST NOT** 让桌面不适用项的缺失表现为“设置项消失导致分区缺项”。

---

## 14. 未验证项与阻塞（本契约不声称为设备证据）

- `DEVICE_BLOCKED`：横屏设置模态的实际像素布局、滚动手感、字体度量、视觉配色（`NativeHudSettings.cpp:163-225` 的色值）、性能面板在实际设备上的耗时与诊断输出格式 —— 本契约只冻结源码语义，未做设备测量。
- `DEVICE_BLOCKED`：Android 同意门在真机上的区域判定时延、缓存与商店更新行为。
- `ARCH_BLOCKED`：Flutter 侧设置页/平台能力**尚未实现**，本契约不代表任何接线或验收；接线需由后续实现卡完成并另行验证。
- 未执行任何构建/测试/analyze/运行/安装命令（见文件头证据等级）。

---

## 15. 证据表（源文件 → 行号，均针对冻结基线）

| 主题 | 源 |
|---|---|
| 七分区定义 | `Qt/src/SettingsSchema.cpp:693-703` |
| Android 渲染默认倍率 | `Qt/src/render/AndroidRenderPolicy.h:106-116`（75 / 100 / 环境覆盖）|
| Preferences 23 行 | `Qt/src/SettingsSchema.cpp:352-662` |
| Project 8 链接 | `Qt/src/SettingsSchema.cpp:664-687` |
| 选项与可见性谓词 | `Qt/src/SettingsSchema.cpp:18-345` |
| normalize / read | `Qt/src/SettingsSchema.cpp:718-849` |
| switchTarget / nextValue | `Qt/src/SettingsSchema.cpp:866-926` |
| 注册表校验 | `Qt/src/SettingsSchema.cpp:928-1004` |
| 布局常量与算法 | `Qt/src/SettingsCard.cpp:9-19, 239-292` |
| 行/选项绘制与命中 | `Qt/src/SettingsCard.cpp:36-236` |
| 自定义渲染内容 | `Qt/src/NativeHudSettings.cpp:227-380` |
| 应用值 / 恢复默认 | `Qt/src/NativeHudSettings.cpp:382-525` |
| 设置模态框架与滚动 | `Qt/src/NativeHudModal.cpp`, `Qt/src/NativeHud.cpp:140-166`, `Qt/src/NativeHud.h:115-116`, `Qt/src/NativeHudInput.cpp:30-33` |
| 平台能力 | `Qt/src/PlatformFeatures.h:1-25` |
| 更新 | `Qt/src/AppUpdater.h`, `Qt/src/AppUpdater.cpp:1-277` |
| 偏好白名单与持久化 | `Qt/src/Host.cpp:1033-1109` |
| 桌面歌词键与默认值 | `Qt/src/DesktopLyricsLayout.h:15-46`, `Qt/src/DesktopLyricsAppearance.cpp:52-97` |
| 桌面歌词页面 | `Qt/src/DesktopLyricsSettingsPage.cpp:163-303`, `Qt/src/NativeHudDesktopLyrics.cpp:117-122` |
| 性能面板 | `Qt/qml/PerformancePanel.qml` |
| Android 同意 | `Qt/android/src/rhine/music/database/ConsentActivity.java`, `ConsentStore.java` |
