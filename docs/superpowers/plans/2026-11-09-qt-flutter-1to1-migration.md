# Qt Android → Flutter 1:1 复刻迁移计划

> 归档说明（2026-11-19）：本文引用的 `.agents/` 目录已删除（含 227 个 worktree、控制面报告与日志）。文中的 `.agents/...` 路径仅作历史出处；控制面摘要、实测数字与残留材料见 `docs/flutter-migration/archive/2026-11-19-control-plane.md` 与 `docs/flutter-migration/archive/qt-flutter-state-2026-11-19.md`。

2026-11-09 ｜ 仓库 `/home/aibeto/code/Rhine-Music-Database` ｜ 分支 `feat/flutter@89493eb3c3d2c1e6c050891718134ac7670e4d6c` ｜ Qt 代码基线 `01ee85b96fee`（**UNPROVEN**，见 §2.1）｜ 状态：**只读规划，未实施**

> 本文只写计划。文中出现的构建/测试/截图/安装命令都是未来执行者的输入记录，**本文件作者未运行任何 Flutter/Qt 构建、测试、analyze、Gradle 或 adb**。旧计划 `docs/superpowers/plans/2026-11-08-flutter-android-rewrite.md` 保留、不实施、不修改；旧 Flutter goal 已 paused，**不 resume**。

## 0. 结论先行（10 条）
1. **复刻对象不是一组 Flutter 页面，而是 Qt 每帧产出的协议**：`commands`（绘制命令流）+ `hits`（与绘制同源的命中矩形）+ `state`（输入/弹窗/编辑态）+ `frame`（3D 场景参数）。证据：`Qt/src/NativeHud.h:74-76`、`Qt/src/NativeHud.cpp:223-312`、`Qt/src/NativeSceneFrame.cpp:87-119`。
2. **允许保留 Qt C++ 移植层**：Host、MusicLibrary、MusicPlayer、PlaybackQueue、LyricsController、NativeScene、NativeHud、NativeApplication 都是**有状态的业务所有者**，不是 Node 薄壳；只迁 Node、再用普通 Flutter 列表补界面必然偏离 1:1。证据：`Qt/src/Host.h:19-29`、`Qt/src/NativeApplication.h:5-17`、`Qt/src/MusicSession.cpp:33-86`。
3. **路线由“单切片硬门”决定，不由偏好决定**：R1（Qt 全渲染 + Flutter 纹理宿主）、R2（Qt 状态/3D + Dart HUD 渲染器）、R3（Qt 仅业务状态，Flutter 重写渲染）三案同题竞赛；**套壳启动成功不算迁移完成**（§4.3）。
4. **横屏 1:1 有真实基准，竖屏没有**：横屏 `stageScale = height/1080`、`stageWidth = width/stageScale`（`Qt/qml/Main.qml:32-33`）；竖屏套用该公式得 `stageWidth=486`、`navigationLeft=-303`（1080×2400），必须作为**新增适配设计**审定，**不得声称对不存在的 Qt 竖屏画面 1:1**（§6.2-6.3）。
5. **证据分级**：A=源码直读，B=源码公式推导，C=设计判断/待审定，D=设备未取证。设备已有 12 张横屏截图（10 张业务画面），但设置后续项、Tab Mode、登录态、结果命中、竖屏仍是 **NOT_CAPTURED**（§3.7）。
6. **基线尚未闭环**：APK 文件名含 `01ee85b96fee`，但 **commit ↔ APK ↔ 证书** 三条链必须由 P0 用可复现命令冻结；在证明前一律标 UNPROVEN（§2.1）。
7. **验收用 Qt 自身作为 oracle**：`Engine::snapshot()` 输出 `qt-panel.png`/`qt-metal.png`/`qt-composite.png`/`qt-state.json`（`Qt/src/Engine.cpp:1444-1472`），配合 `--capture <dir> [archive|detail]`（`Qt/src/main.cpp:1310-1345`），可在同 fixture 下产出协议级与像素级基准；**单 SSIM 不构成 1:1**（§9）。
8. **每任务单 owner、单 worktree、单写 scope**；共享协议先冻结再并行；每完成一步**恰好 1 个** GINKA `deepseek-v4.1-flash`/reasoning `max` 只读 leaf 审查，**实际收回**后才提交（§11）。
9. **Qt 的隐私同意门槛是既有行为**：`ConsentActivity` 是 LAUNCHER，地区判定（CN/EU/其他）与 SDK 启动顺序在 Qt 界面之前（`Qt/android/src/rhine/music/database/ConsentActivity.java:19-32,69-80`）；未获用户授权不得删改、简化或“默认同意”（§10.5）。
10. **文档与未来实施 commit 都是标题-only**：单个 `-m`、无正文、不混改动、不 `git add -A/-f`、不改作者配置与历史（§12）。

## 1. 状态、授权边界与不变量
### 1.1 当前状态

| 项 | 事实 | 证据 |
|---|---|---|
| 分支/HEAD | `feat/flutter@89493eb3c3d2c1e6c050891718134ac7670e4d6c` | 用户指定；本会话 `git log` 已核 |
| Qt 源码基线 | `01ee85b96fee`（APK 文件名；**未证明**与该 commit 的构建一致） | 设备报告 §1；`CMakeLists.txt:30-52` |
| 旧 Flutter 计划 | 保留、不实施、不改 | 用户指令 |
| 旧 goal | paused，**不能 resume** | 用户指令 |
| 产品基础 | 本仓库主工作区；**不得使用 lead 所在旧 delivery worktree** | 用户指令 |
| 设备 | OPD2511 / Android 16 / API 36 / 2880×1800 横屏 | `.agents/qt-plan-device-2026-11-09.md` §1、§5 |

### 1.2 授权边界
- **已批准**：Flutter 内嵌 WebView；保留 Qt 移植层（C++ 状态/渲染/服务）；真机重装 Qt 版本并操作截图（**设备负责人独占**，本计划作者无 adb）。
- **禁止**：恢复旧 Flutter 实施；修改/删除旧计划与旧产品；修改三份输入报告；操作设备；以“必须纯 Dart / 无 Qt / 固定 Vulkan”作为门槛；未经授权删改隐私同意；未经授权发布含个人信息截图。
- **唯一可写**：本文件；`.agents/qt-plan-author-control-2026-11-09.md`（读回复）、`.agents/qt-plan-author-2026-11-09.md`（回报）。
- **执行门**：未来任何实施/测试/截图/安装都必须由对应 owner 在其 worktree 内进行，并先有 §11 的任务分派与 §12 的提交纪律；本计划不自动 handoff。

### 1.3 不变量（任何路线都必须成立）

| ID | 不变量 | 证据 |
|---|---|---|
| I1 | HUD 以 1080 高舞台坐标系创作，屏幕适配只做等比缩放 `scale(height/1080)` | `Qt/src/Hud.cpp:118-174`；`Qt/qml/Main.qml:32-33` |
| I2 | 每帧 `commands`/`hits`/`state`/`frame` 同帧发布；命令变更必须触发一次真实重绘 | `Qt/src/Hud.cpp:35-43`；`Qt/src/Engine.h:49-73` |
| I3 | 文字用预烘焙 glyph 轮廓（1000 units、`PreferNoHinting`），缺字才回退 | `Qt/src/Glyphs.cpp:51-63,109-188` |
| I4 | 颜色可带 calibratedWhite/calibratedRGB，Gamma1.8→sRGB | `Qt/src/Glyphs.cpp:35-49` |
| I5 | 命中矩形与绘制同源（button/control 同时生成），外扩 10（control）/16（触摸） | `Qt/src/NativeHud.cpp:102-124`；`Qt/qml/Overlay.qml:38-43` |
| I6 | 3D 投影含 `values[8]+=0.16*archiveOffset`、`values[9]+=0.20*archiveOffset` 与 18% 视野外扩 | `Qt/src/NativeSceneCamera.cpp:98-105,113-173` |
| I7 | 详情/modal/滚动/查看器/相机的时间曲线由引擎驱动，不由平台路由动画替代 | `Qt/src/UiMotion.cpp:104-118`；`Qt/src/NativeViewer.cpp:39-64` |
| I8 | 会话状态（页面/选中/modal/滚动/播放/输入）跨重启与旋转保持 | `Qt/src/MusicSession.cpp:215-284` |
| I9 | 隐私同意门槛先于任何 Qt/统计 SDK 启动，同意状态持久化 | `ConsentActivity.java:19-32,66-80` |
| I10 | 包名、签名与升级链连续；不卸载/不清数据做验收 | `CMakeLists.txt:22`；`docs/ANDROID.md:1-12` |

## 2. 基线与平台能力（含哪些“不能未证明就写死”）
### 2.1 版本链：已证明 / 未证明

| 项 | 观测值 | 证据 | 等级 |
|---|---|---|---|
| 设备安装的 APK | `output/RhineMusicDatabase-01ee85b96fee-android-arm64-v8a-signed.apk`，SHA256 `bd58d95a5edee4c66a9704a108fb335163dc4274239b5f32b2a0c4cb221b5a1e` | 设备报告 §1 | A（设备侧读取） |
| 安装版本 | `versionName=0.0.0`、`versionCode=1`、`minSdk=28`、`targetSdk=36` | 设备报告 §1 | A |
| 包名 | `rhine.music.database`（CMake 注入）；Manifest 的 `package="org.qtproject.example"` 是占位 | `CMakeLists.txt:22`；`Qt/android/AndroidManifest.xml:13` | B（合并后包名待证） |
| 版本注入规则 | `versionName=${PROJECT_VERSION}`；`versionCode=major*10000+minor*100+patch`；默认 `0.0.0` | `Qt/Android.cmake:153-163`；`CMakeLists.txt:6-8` | A |
| commit ↔ APK | 文件名含 12 位 sha，和 `git log -1 --format=%h --abbrev=12` 同源；**未做二进制内 BuildIdentity 比对** | `CMakeLists.txt:30-52` | **UNPROVEN** |
| 证书 | **未采集** | — | D |
| 签名方案/是否 debug key | **未采集** | `docs/ANDROID.md:1-8` 称默认调试密钥、存在发布密钥时改用它 | D |

**P0 必须补齐的证据（命令只记录，当前不执行）**：

```sh
# 由 baseline owner 在 APK 所在机器执行；输出写入 docs/plan/qt-baseline-evidence.md
apksigner verify --print-certs --min-sdk-version 28 output/RhineMusicDatabase-01ee85b96fee-android-arm64-v8a-signed.apk
aapt2 dump badging output/RhineMusicDatabase-01ee85b96fee-android-arm64-v8a-signed.apk | head -40
sha256sum output/RhineMusicDatabase-01ee85b96fee-android-arm64-v8a-signed.apk
git rev-parse --short=12 01ee85b96fee
# 证明 APK 内编译进的 commit（BuildIdentity）：只读检查，不改包
unzip -p output/...apk lib/arm64-v8a/libRhineMusicDatabase_arm64-v8a.so | strings | grep -E '^[0-9a-f]{12}$'
```

**已见矛盾**：`0.0.0` 按 `Qt/Android.cmake:153-163` 公式应得 `versionCode=0`，设备实测为 `1` → 该 APK 的版本链未按此公式闭合（可能走 Qt 默认回退），本身即 `BASELINE_MISMATCH` 的候选证据，禁止在 P0 前把“源码 commit=设备 APK”当既定事实。

判据：`apksigner` 输出的 signer #1 SHA-256 与项目 keystore 指纹一致或不一致都要记录；APK 内 sha 必须等于文件名 12 位；对应 commit 的 `RHINE_COMMIT_TITLE` 必须与 APK 内标题一致。三者任一不成立 → 基线标 `BASELINE_MISMATCH`，设备截图只能作“某构建”的参考，不能作为 1:1 的 commit 基准。

### 2.2 Qt Android 与桌面能力差异

| 能力 | Android（Qt 基线） | 桌面（macOS/Windows/Linux） | 证据 |
|---|---|---|---|
| 官方客户端入口 | 关闭 | 开 | `Qt/src/PlatformFeatures.h:8-24` |
| 本地音乐 | 关闭 | 开 | 同上 |
| 应用内音量 | 关闭 | 开 | 同上 |
| 桌面窗口控制/悬浮歌词 | 关闭 | 开（歌词仅 macOS/Windows） | 同上 |
| 播放进程 | **同进程**（无 RhinePlaybackService） | 独立 `RhinePlaybackService` | `CMakeLists.txt:497-514` |
| 系统媒体控制 | MediaSession + MediaStyle 通知 + 音频焦点 | 桌面媒体键/托盘 | `Qt/android/src/rhine/music/database/RhineMediaService.java:24-50` |
| 图形后端 | 与 Linux 同链：显式变量 → 设置 → **Vulkan 优先、GLES 回退**；`MobileTarget.h:19` 注释却称“无 Vulkan 呈现路径” | Metal / D3D12 / Vulkan / GL | `Qt/src/main.cpp:639-705`；`Qt/src/MobileTarget.h:18-22` |
| FidelityFX | 默认关闭（无 SPIR-V） | 视平台 | `CMakeLists.txt:103-111` |
| 方向 | 两个 Activity 均 `sensorLandscape` | 可缩放窗口 | `Qt/android/AndroidManifest.xml:84-110`；设备报告 §5 |

**结论**：新 Flutter 版本必须保持 Android 语义（关闭四项、同进程播放 + MediaSession），**不得以桌面能力“补全”**；图形后端在设备上的**实际** backend 名必须由 P0 运行期取证（性能 JSON / `RhineGraphics::activeBackend`），既不预设 Vulkan，也不设“必须 Vulkan”门槛。

## 3. 完整界面/行为矩阵（不继承旧排除项）
> 旧计划 §1.2 的能力矩阵与“排除项”只作历史参考，**不得作为新计划的范围依据**。下表覆盖 Qt Android 可实现与可达的全部面。

### 3.1 页面/模式

| 层 | 名称 | 宿主/入口 | 关键几何 | 证据 |
|---|---|---|---|---|
| 场景+HUD | boot 初始化 | 启动/Reinitialize | 1920 宽坐标，`(width-1920)/2` 偏移 | `NativeHudBoot.cpp:155-311`；`NativeSceneFrame.cpp:19-21` |
| 场景+HUD | archive 资料库 | 默认页 | 主区 `x=326`；底部 nav `width*0.2625` | `NativeHud.cpp:404-514` |
| HUD | empty 目录空态 | lane 目录 | 59,211 起 | `NativeHud.cpp:374-403` |
| HUD 卡片 | song detail | 打开卡片 | 右栏 `x=width*0.56-24` | `NativeHudDetail.cpp:45-215` |
| HUD 卡片 | container detail（歌单/专辑/歌手） | 卡片 | 侧栏区 | `NativeHudDetail.cpp:340-511` |
| HUD+3D | viewer 查看器 | 查看封面 | 全屏 | `NativeHudDetail.cpp:513-528`；`NativeViewer.cpp:9-11` |
| HUD | playerBar 常驻播放条 | 常驻 | `(0,984,width,96)` | `NativeHudPlayer.cpp:8-42` |

### 3.2 弹窗（modal 值 → 面板）

| modal | 面板 | 几何要点 | 证据 |
|---|---|---|---|
| search | searchPanel | `left=width-modalWidth-59`；高 836，`y=122` | `NativeHud.cpp:140-158`；`NativeHudSearch.cpp:8-18` |
| saved | savedPanel | 检索条 + 创建/刷新 + tab + 表格；未登录 300×44 登录 | `NativeHudLibrary.cpp:45-226` |
| login | loginPanel | 二维码 240×240@`y+260`；手机号 `y+278`；验证码 `y+391`；提交 170×36@`y+530` | `NativeHudLibrary.cpp:270-323` |
| settings | settingsPanel | 视口 `y+176..y+836`；行高 66/步进 76 | `NativeHudSettings.cpp:96-226` |
| discover | discoverPanel | `{x,y,width,836}`；5 列网格 | `NativeHudDiscover.cpp:9-145` |
| player | 播放队列 | 836 高；队列 `y+358` 起 56 行；4 等分模式条 | `PlaybackQueueCard.cpp:15-96` |
| quality | 音质选择 | featured 174 / 普通 57 | `NativeHudModal.cpp:326-446` |
| provider | 平台选择 | 5 卡，gap 12；展开 190/收起 66 | `NativeHudModal.cpp:259-291` |
| playlist-form | 新建/编辑歌单 | 输入框由 QML 叠在 `inputX/Y` | `Overlay.qml:355-484` |
| playlist-picker | 选歌单 | 7 行 52 高，`y+290`，间距 60 | `NativeHudModal.cpp:222-239` |
| confirm | 确认 | 标题 24@`y+260`；按钮 180×45@`y+450` | `NativeHudModal.cpp:214-221` |
| disc-rotation-warning | 唱片旋转警告 | 4 行文案 22/16；按钮@`y+480` | `NativeHudModal.cpp:203-209` |
| lyrics-offset | 歌词偏移 | 独立面板 `x+16`；±0.2s | `NativeHudModal.cpp:85-121` |
| lyrics-source | 歌词来源 | 232×232 @ `width*0.56+156,674` | `NativeHud.cpp:140-158` |
| detail-sort | 排序 | 菜单 `x+195,391,240,184` | `NativeHud.cpp:140-158` |
| desktop-lyrics | 桌面歌词设置子页 | 视口 200..820 | `NativeHudDesktopLyrics.cpp:22-121` |

### 3.3 动作命名空间（字符串必须逐字保留）
- 导航/宿主：`discover`、`search`、`saved`、`settings`、`open`、`back`、`close-modal`、`archive:tab-mode`、`archive-mask:<v>`、`column-prev`、`column-next`。
- 播放：`prev`、`next`、`music:play-loaded`、`player:clear`、`player:remove:<i>`、`player:lyrics-{open,sources,retry,reset,offset,later,earlier,close,follow,apply-global}`、`single-play-mode`、`detail-autoplay`。
- 检索/库：`music:{qr,preview,cover-front,activate,parent,picker-prev,picker-next,open-all-siren,directory,directory-info}`、`local:{browse,files,folder,prev,next,rescan,cancel}`。
- 查看器：`viewer:{reset,clear,frosted,close}`。
- 设置：`settings:{scroll-up,scroll-down}`、`quality:set:<id>`、`disc-rotation[:enable|cancel]`、`close-behavior`、`motion`、`vsync`、`msaa:<v>`、`aa-mode:<v>`、`aa-scale:<v>`、`render-scale:<v>`、`fsr-quality:<v>`、`fsr-sharpness:<v>`、`gpu-index:<i>`、`startup-animation`、`skip`、`confirm:yes`、`alternative`、`title`。
- 引擎入口：`Engine::action` 的 `performance:toggle`/`window:fullscreen` 特判，其余转 `hud.action`（`Qt/src/Engine.cpp:850-863`）；手柄映射到同一动作集（`Engine.cpp:920-950`）。

### 3.4 状态与反馈面（loading / empty / error / success）

| 面 | 来源 | 证据 |
|---|---|---|
| 搜索 loading/空/结果 | `searchLoading`、`status`、`query` | `MusicSession.cpp:50-85`；`NativeHudSearch.cpp:131-281` |
| 目录 loading/更多/空 | `directoryLoading`、`hasMore`、`offset` | `MusicSession.cpp:33-86` |
| 详情 loading | `detailLoading`、`wantsSongDetails` | 同上 |
| 登录 busy/倒计时/失败 | `loginBusy`、`smsRetrySeconds`、`status` | `NativeHud.cpp:175-221`；`NativeHudLibrary.cpp:270-323` |
| 播放器 loading/暂停/无封面 | `PlayerBar` 状态 | `PlayerBar.cpp:17-252` |
| 错误 | `status` 文本 + 排障文档 | `docs/error-troubleshooting.md` |

### 3.5 登录态与平台

| 平台 | 能力 | 登录方式 | 证据 |
|---|---|---|---|
| 塞壬唱片 SIREN | 官网曲库，无需登录 | — | 设备报告 §3（07-platform） |
| 网易云 NETEASE | 搜索/个人音乐/推荐/播放/歌单编辑 | 二维码 + 手机号/验证码 | `NativeHudLibrary.cpp:270-323` |
| QQ MUSIC | 全类搜索/每日推荐/个人音乐/歌单编辑 | 扫码 | 同上 |
| 酷狗 KUGOU | 标准版/概念版；歌单/榜单/播放 | 扫码 | 同上 |

未登录时“我的音乐/发现”不可达（设备报告 §3）→ 计划内标 `NOT_CAPTURED`，需用户授权登录/扫码后才能补证。

### 3.6 设置全表（Section → 条目）
- Section：`Provider`、`Preferences`、`Performance`、`Storage`、`Update`、`Project`、`Footer`（`Qt/src/SettingsSchema.h:11-13`）。
- 已核 id：`window`(`SettingsSchema.cpp:352`)、`close-behavior`(:362)、`theme`(:376)、`motion`(:387)、`startup-animation`(:399)、`replay`(:411)、`quality`(:420)、`alternative`(:431)、`official-player`(:444)、`detail-autoplay`(:457)、`single-play-mode`(:470)、`desktop-lyrics`(:483)、`archive-mask`(:492)、`graphics-backend`(:505)、`gpu-index`(:527)、`vsync`(:543)、`render-scale`(:555)、`aa-mode`(:569)、`aa-scale`(:588)。
- 设备仅见首屏 5 项（provider/theme/motion/startup/quality），其余 **NOT_CAPTURED**（设备报告 §3，06-settings）。
- 迁移要求：**设置项 id、默认值、绑定类型（`BindingKind`：Preference/HudState/Player/External/Capability/Updater/Action/CustomSection）逐项保留**；Android 上 `Capability` 门控的项（如 graphics-backend、vsync、msaa、fsr）必须按平台能力隐藏/禁用，而不是删除。

### 3.7 设备证据等级（本轮）
已证（A/D 混合，设备报告 §8 索引，路径 `/tmp/rhine-qt-baseline-2026-11-09/`，**临时目录，重启即失，仅本轮参考，不入库不发布**）：

| # | 文件 | 内容 | 时效 |
|---|---|---|---|
| 01/02 | `01-consent.png`/`02-consent-relaunch.png` | 隐私门槛 + 重启复现 | 2026-11-09 16:31/16:39 |
| 03 | `03-home-all-songs.png` | 首页/全部歌曲 | 17:02 |
| 04/05 | `04-search.png`/`05-search-restored.png` | 检索空查询 / 重启恢复 | 17:09/17:19 |
| 06 | `06-settings.png` | 设置首屏 5 项 | 17:21 |
| 07 | `07-platform.png` | 四平台卡 | 17:23 |
| 08 | `08-queue.png` | 队列空态 + 四模式 | 17:24 |
| 09/10 | `09-library.png`/`10-library-track17.png` | 资料库层级/选曲 | 17:26/17:28 |
| 11 | `11-song-detail.png` | 歌曲档案 + 3D 封面 | 17:30 |
| 12 | `12-search-results.png` | 搜索空态（输入丢字） | 17:35 |

NOT_CAPTURED：我的音乐/发现、设置滚动后条目、Tab Mode、竖屏、搜索结果命中、登录二维码/手机号页、歌单详情独立页、本地音乐、桌面歌词子页、音质弹窗、平台切换后画面。

> 说明：control 17:18 段称“业务界面像素证据仍未取得”，早于 device 的 17:19–17:35 采集；本计划以 device 报告 §8 的索引为准，同时保留其覆盖面限制。三份报告的作者提交与 Reviewer 由各 owner 完成，本计划不代提交。

### 3.8 无障碍
- uiautomator 可见标签：`← 返回`、`歌曲/专辑/歌单/歌手`、`上一首/播放/下一首`、`列表循环，点击切换播放模式`、`播放队列`、EditText `搜索歌曲、歌手、专辑或歌单`（设备报告 §4）。
- 顶部导航 `音乐检索 / + 塞壬曲库 / 设置` **未暴露**语义 → 新实现必须补齐（不是“保持缺失”），并保持 label 文案逐字一致。

## 4. 架构：复用 Qt 的上下界与单切片硬门
### 4.1 可复用的 Qt 资产

| 模块 | 状态 | 复用上界 | 复用下界 / 风险 | 证据 |
|---|---|---|---|---|
| Host | 桥接/缓存/凭据/偏好/图片 | 全量保留（C++） | 需 JNI/FFI 暴露；线程与回调 | `Qt/src/Host.h:19-91` |
| MusicLibrary | 5 lane 列表、目录、检索、发现、登录态 | 全量保留 | 与 HUD 状态耦合（selectionRequested 等） | `Qt/src/MusicSession.cpp:33-213` |
| MusicPlayer + PlaybackQueue | 播放、队列、模式、会话 | 全量保留 | 需 AudioPlayer/MediaSession 桥 | `Qt/src/MusicPlayer.cpp:749-760` |
| LyricsController | 歌词、偏移、来源 | 全量保留 | 时间轴与 HUD 共享 | `Qt/src/LyricsController.cpp:635` |
| NativeScene | 3D 卡片、相机、拾取、查看器 | 全量保留（R1/R2） | R3 下需重写投影/拾取 | `Qt/src/NativeScene.cpp:63-198`；`NativeSceneCamera.cpp:55-111` |
| NativeHud | 命令流/hits/state/弹窗/页面 | 全量保留（R1/R2） | R3 下放弃，风险最高 | `Qt/src/NativeHud.cpp:175-645` |
| NativeApplication | 会话、音乐→场景联动、时间步 | 全量保留 | 需宿主驱动 step | `Qt/src/NativeApplication.cpp:98-200` |
| RhiScene | QRhi 场景渲染 | R1 直接复用；R2 仅 3D 出图 | 纹理互操作/生命周期 | `Qt/src/RhiScene.cpp:2206-2290` |
| PresentationShell | 离屏呈现/插帧 | 桌面专用，Android 不用 | 不迁 | `Qt/src/render/PresentationShell.h:49-95` |
| Node 桥 | 三家平台协议 | 全量保留（libnode） | 16KB page/启动时间 | `docs/ANDROID.md:1-12`；`Qt/Android.cmake` |

### 4.2 候选路线

| 路线 | 形态 | 视觉风险 | 工程风险 | 适用条件 |
|---|---|---|---|---|
| **R1** Qt 全渲染 + Flutter 纹理宿主 | Qt 离屏渲染 scene+HUD 到共享纹理；Flutter `Texture`/`PlatformView` 合成；输入/IME/生命周期由 Flutter 转发 | **最低**（同一渲染器） | 纹理互操作、输入时延、双引擎线程、PlatformView 合成 | 纹理路径在目标设备稳定且 ≤1 帧时延 |
| **R2** Qt 状态/3D + Dart HUD 渲染器 | Qt 保留状态与 3D 出图；`commands/hits/state` 过 FFI；Dart `CustomPainter` + 同 glyph JSON 重放 | 中（命令执行器可逐条对齐） | 双时间轴、发布同步、字形缓存 | 命令流可 0 差复现且 3D 纹理可用 |
| **R3** Flutter 重写渲染 | Qt 仅业务/桥；HUD 与 3D 全 Flutter | **最高**（字形/投影/时序） | 工作量最大、回归面最大 | 仅当 R1/R2 均被硬门否决 |
| W（子方案） | HUD 用本地 WebView canvas 渲染同一命令流 | 中 | 输入/IME/无障碍/首帧 | 允许作为 R2 的对照，不作默认 |

**允许的复用边界**：Qt C++ 可以继续拥有业务状态、3D 场景、HUD 命令生成、播放与桥；Flutter 拥有窗口、生命周期、输入、IME、无障碍与呈现宿主。**禁止**把 Qt 仅当“启动器”然后另写一套 UI；**禁止**为了“纯 Flutter”拆掉已证视觉。

### 4.3 单切片 S1（硬门题目）
固定 fixture：离线资源 `Resources/scene-fixture.json`、`Resources/slots.json`、`Assets/android-3d/*.glb`、`Assets/fonts/*`；固定输入：`width=1920,height=1080,dpr=1`、`theme=light`、`reduced=false`、`selected=0`、`scroll=0`、`modal=none`、`frame.detail=0`、`time=2.101`。

| 切片 | 内容 | 为什么必须 |
|---|---|---|
| S1a | archive 主界面：3D 卡片墙 + 顶栏 + 左操作 + 底栏 + 命中 | 覆盖 scene+HUD+glyph+hit 全链 |
| S1b | settings modal：文本密集 + 滚动 + 输入框 + 动效 | 覆盖排版/滚动/IME/弹窗时序 |
| S1c | rotation：横→竖→横 同一状态 | 覆盖状态连续性与 stage 重算 |

### 4.4 硬门指标（通过线）

| 维度 | 测法 | 通过线 | 失败后 |
|---|---|---|---|
| 协议 | 同状态 `hits` JSON 逐项、`state` 数值、`commands` token 归一 | `hits` 误差 0（整数舞台坐标）；`state` 全等；`commands` 逐条相等 | 该路线否决 |
| 像素（HUD） | `qt-panel.png` vs 渲染，ROI 分块（文字/描边/填充/遮罩） | 几何 bbox 偏差 ≤1 stage px；颜色 ΔE2000 ≤1.0；文字区域 0 位移、差异像素 ≤0.2% | 修正 1 次仍不过 → 否决 |
| 像素（3D） | `qt-metal.png` vs 渲染；投影矩阵逐元素 | 矩阵绝对误差 ≤1e-9；卡片边缘 IoU ≥0.995；背景/雾色 ΔE ≤1.0 | 同上 |
| 时延 | 输入→命中反馈→画面更新 | ≤1 帧（60Hz 下 16.7ms）；连续 120 次无漏帧 | 记录并降级候选 |
| 旋转 | S1c 状态矩阵 | 播放/选中/modal/滚动/输入/相机/查看器全保持；无重建 | 否决 |
| 稳定性 | 30 分钟循环切页/旋转/弹窗 | 无崩溃、无纹理泄漏、内存增长 ≤5% | 记录 |
| 工程 | 代码量/可测试性/维护面 | 由 lead 记录，不作单独否决项 | — |

### 4.5 决策与失败路线
- 产出 `docs/plan/gate-s1-decision.md`：每条指标实测值、结论（R1/R2/R3）、否决理由、复现命令与 fixture 版本。
- R1 失败 → 走 R2；R2 失败 → 评估 R3；R3 仍不达 §9 阈值 → **上报用户重定范围**，不得以“先上线套壳”交差。
- 任何路线通过后，其余路线代码不合并；实验分支保留 tag 以便复盘。

## 5. 渲染/交互契约（迁移必须保住）
### 5.1 每帧数据面
- `state` 键（`NativeHud.cpp:175-221`）：`inputX/Y/Width`、`searchListX/Y/Width/Height`、`playerBounds/seek/volume`、`loginMethod/loginBusy/smsRetrySeconds`、`localMusic`、`formKind/formPID`、`modal/query/closing/modalOpacity/modalOffset`、`dark/reduced`、`editingSetting*/Value/X/Y/Width/Height`、`archiveMaskStrength`、`trackListMode`、`detailSort`、`sortLoading`、`mode/viewer/status`。
- `hits`：`{x,y,width,height,action,label}`（`NativeHud.cpp:102-108`）；`control()` 外扩 10、高 54、字号 20 demibold（:110-124）。
- `frame`：`mode/selected/time/draws/view/projection/eye/background/fogColor/fogNear/fogFar/detail/boot/focus/aperture/pendingAnimations/pointerCursor/aoProjection/reference/near/far/viewer/viewerReady/viewerState/culledCards/shadowCards/returningCards/actorTemplate/appearanceRevision/actors`（`NativeSceneFrame.cpp:87-119`）。
- 发布语义：命令流变了必须 `window()->update()`；只标脏不呈现会出现“能点但不显示”（`Qt/src/Hud.cpp:35-43`）。

### 5.2 命令语义（15 种，执行器规格）

| 命令 | 参数 | 语义 | 证据 |
|---|---|---|---|
| save/restore | — | 栈；alpha 乘算 | `Glyphs.cpp:658-659` |
| alpha | v | `opacity*v` | 同上 |
| translate/scale/rotate | x,y / sx,sy / 弧度 | rotate 是弧度 | `:671-672` |
| clip | x,y,w,h | IntersectClip | `:676-678` |
| fill | x,y,w,h,color | fillRect | `:684-701` |
| ellipse | cx,cy,rx,ry,color | NoPen+brush | 同上 |
| text | value,x,y,size,weight,tracking,color | 基线 `y+size*1.044`；逐字 `advance*size+tracking` | `:530-563` |
| art | key,x,y,size,count,tracking,color | 字形艺术字；`count<0` 全部 | `:565-588,717-727` |
| path | svg,x,width,color,… | QPen 描边；dash 按 penWidth 归一 | `:728-760` |
| fill-path | svg,color | fillPath | 同上 |
| arc | cx,cy,r,start,sweep,width,color | 弧度；RoundCap | `:761-774` |
| right-mask | color,start,span,right,height | 16 段 smoothstep 渐隐 | `:775-805` |
| gradient | dark | 径向渐变中心 (979.2,518.4)、半径 1100 | `:806-812` |
| image | key,x,y,w,h | 宿主解析 key（封面/二维码/图标） | `:813-824` |

### 5.3 字形
- 素材：`Assets/fonts/RhineMiSans-{light,regular,demibold,bold}.otf`、NotoSansSymbols2、`Assets/fonts/misans-glyphs.json`（`Glyphs.cpp:65-90`）。
- `QRawFont(...,1000,PreferNoHinting)`（:51-63）；正常路径逐字轮廓，缺字/组合/复杂文字/RTL 才 `QTextLayout` 回退（:109-188）。
- `fit()` 二分截断 + "…"（`NativeHud.cpp:48-76`）；滚动数字 `ReelCurve` 默认 0.46s（`UiMotion.h:12-22`）。

### 5.4 3D
- 卡片：5 lane × 40；`cellPosition={(lane-2)*5.2,-4.6,(row-15.5)*0.62}`（`NativeScene.cpp:63-78`）。
- 相机：`m_eye{-62.26,35.98,43.28}`、`m_aim{-0.5,1.1,0.4}`、`fov 6.15`、初始 `fogNear 22`/`fogFar 47`、`1920×1080`（`NativeScene.h:123-132`；运行期雾按 `renderedDistance+lerp` 重算，`NativeSceneCamera.cpp:96-97`）；追踪 `1-exp(-dt*5)`（`NativeSceneCamera.cpp:89-93`）。
- 投影：`perspective(fov,aspect,5,300)` + `values[8]+=0.16*archiveOffset`、`values[9]+=0.20*archiveOffset`（:98-105）；18% 外扩、`y∈[-6.5,6.5]`（:113-173）。
- 拾取：NDC 反投影 + 保守盒 + BVH（`NativeSceneInput.cpp:36-97`；`NativePicking.cpp:83-105`）；纹理准入 100ms（`Engine.h:117-135`）。
- 查看器：装配深度 `fasteners 2.75/cover 1.85/optical-lenses 0.75/optical-core -0.15/substrate -1.1/carrier -2.05`；`pan=2*r*tan(17°)/height`（`NativeViewer.cpp:9-11`）；竖屏 `aspect<1.05` 放大（:288-292）。

### 5.5 输入
- 舞台坐标：所有指针/滚轮除以 `stageScale`（`Overlay.qml:98-113,317`）；命中矩形乘回（:127-130）。
- 键盘：`keyEvent(key,modifiers,text)`（`Overlay.qml:119`）；快捷键 `Ctrl+Q/F11/F10`（:164-178）；手柄映射（`Engine.cpp:920-950`）。
- 触摸容差 16、control 外扩 10（`Overlay.qml:38-43`）；`playerBarInputShield` 防穿透（:123-142）；pan 阈值 0.4（`TouchInput.qml:8-25`）；捏合→`log(delta)*350` 的 wheel（`Overlay.qml:293-341`）。
- Android 按下即触发 / iOS 抬起触发（`Overlay.qml:202-212`）：新实现必须按平台保留或统一后记录偏差。

### 5.6 时间与过渡
detail `smooth((detail-0.25)/0.55)`；modal 0.3/0.2 + offset12；stagger 0.025/0.24/10px；viewer 0.38/0.22/0.56；camera `1-exp(-5dt)`；boot 固定 35s 后 detail（`NativeSceneFrame.cpp:19-21`）。时间源要区分墙钟（二维码有效期）与帧时钟（3D/animation）。

### 5.7 数据/业务/持久化
- 桥：`Host::requestJson(route, params, cb)`，凭据不进参数/环境/日志（`Host.h:18-29`）；`loadCover` 最大 1024。
- 会话：`session.json` 于 `AppStorage::dataDirectory()`；桌面退出写、移动端 15s 周期 + 退后台写（`NativeApplication.cpp:76-89`）；schema `version:1`、library/player/view 三段（`MusicSession.cpp:215-235`）。
- 偏好：`AppStorage::settings()` → `dataDirectory()/settings.ini`，键前缀 `panel/`（`AppStorage.cpp:108`；`Host.cpp:1075,1095`）。
- 缓存：`cacheDirectory()/metadata`、`media-cover.png`（`Host.cpp:188,978,1020`）；清缓存动作 `cache:clear`。

### 5.8 后台音频
- 动作串：`resume/pause/next/prev` 与 `rhine.media.SEEK:<ms>`（`RhineMediaService.java:36-43`；`NativeApplication.cpp:26-27`）；通知按钮经 PendingIntent 回服务，再 `native mediaAction`→`Host::mediaAction`。
- 前台服务类型 `mediaPlayback`、权限 `FOREGROUND_SERVICE_MEDIA_PLAYBACK`、`POST_NOTIFICATIONS`（`AndroidManifest.xml:20-32,143-147`）。
- Flutter 侧要么继续用该 Java 服务 + JNI，要么实现等价 MediaSession；**不得只做 Flutter 播放器而丢通知/锁屏/音频焦点**。

### 5.9 呈现边界
- HUD 与 3D 必须分层出图，文字不能烤进 3D 纹理（`Qt/qml/Scene3D.qml:4-7`；`Qt/qml/Main.qml:5-8`）。
- Flutter 的 `Texture`/`PlatformView` 只做宿主；命中层/输入框/无障碍是 Flutter 原生层，不参与纹理。

## 6. 横屏基准与竖屏新增设计
### 6.1 横屏（已验证公式）
- `stageScale=height/1080`；`stageWidth=width/stageScale`（`Main.qml:32-33`）。
- `navigationLeft=width-789`；按钮 `x=navLeft+210`，间隔 200，`y=118`（`NativeHud.cpp:342-356`）。
- `sidebar=clamp(width*0.23-40,250,340)`；`x=40+sidebar+36`；`contentWidth=width-x-40`（`NativeHud.cpp:160-166`）。
- `Layout{left=40,sidebar=250,x=326,top=260,rowsY=434,rowHeight=54,rowCount=9,bottom=956}`（`NativeHud.h:37-47`）。
- 检索视口 `(bounds.x+53,bounds.y+328,bounds.width-106,430)`（`NativeHud.h:96-98`）。
- 1920×1080：`stageScale=1`、`stageWidth=1920`；720p：0.6667/1920（16:9）。

### 6.2 竖屏为什么不能照搬
1080×2400 → `stageScale=2.2222`、`stageWidth=486`、`navigationLeft=-303`、品牌宽 `min(720,218.7)`；导航整体出屏，右栏 `x=248` 与内容宽互斥（视觉报告 §7.3，B 级推导）。Qt 只有 `sensorLandscape`（`AndroidManifest.xml:89,103`），**没有竖屏画面可对照**。

### 6.3 竖屏 constraints 适配规则（提案 P-A，待审定）
强制约束（不可协商）：
1. **保留全部文字、入口、层级与功能**；不删入口、不缩成图标、不改导航/抽屉/sheet 结构、不引入 Material 视觉组件（`NavigationBar`/`Drawer`/`ModalBottomSheet`/`InkWell`）。
2. 字号、字重、tracking、行高沿用舞台单位；新增纵向间距用 8 的倍数。
3. 横屏几何零改动；竖屏只新增布局规则，不改横屏命令。
4. 颜色、描边、遮罩、过渡曲线沿用同一套值。

提案 P-A：`stageScale=width/1080`、`stageWidth=1080`、`stageHeight=height*1080/width`；顶部 0..1080 复用横屏；详情/容器全宽单列；播放栏贴 `stageHeight-96`；列表视口吸收 `stageHeight-1080`（检索/archive/设置/队列同一延长公式，滚动锚不变）；3D 详情占顶部约 52%，浏览沿用 `aspect<1.05` 构图。

### 6.4 静态参考门（用户审定，未批不得实现）

| 门 | 议题 | 默认 | 状态 |
|---|---|---|---|
| G1 | 竖屏是否采用 P-A 宽度基准舞台 | 推荐 A | WAIT |
| G2 | 详情单列顺序（封面→标题→动作→字段→曲目→正文） | 推荐 | WAIT |
| G3 | 竖屏 3D 占比（52%）与详情态是否作背景 | 52% | WAIT |
| G4 | IME 推动整层 vs 压缩列表；最大位移 | `min(insets, 输入框底距)` | WAIT |
| G5 | 是否允许竖屏新增入口/手势 | 不允许 | WAIT |
| G6 | Material 边界：仅非可见基础设施 vs 完全禁用视觉组件 | 完全禁用视觉组件 | WAIT |

审定记录写 `docs/plan/portrait-decisions.md`，逐条含日期与决定人。

### 6.5 安全区/DPR/IME
- 横屏：几何不因 `MediaQuery.padding` 移动（保持 1:1）；只处理手势条遮挡的**新增** chrome。
- 竖屏：只对新增纵向 band 避让 insets；横屏命令不动。
- DPR：`canvas.scale(stageScale)` 后用浮点坐标 + antialias；禁止把 1 stage px 四舍五入为 1 device px（720p 上 1 stage px=0.667 device px）。
- IME：输入框保持舞台坐标；整层上移 `min(insets, 输入框底到舞台底距离)`，**不改 stageScale**；输入仍是真实 Flutter 输入（对应 `Overlay.qml:355-602` 的 QML TextInput）。

## 7. 方向、生命周期与输入法
### 7.1 旋转必须保持的状态（逐项）

| 状态 | 横屏基准 | 切竖屏 | 切回 | 证据 |
|---|---|---|---|---|
| 播放/进度 | MusicPlayer 墙钟推进 | 不重建播放器 | 同 | `MusicPlayer.cpp:749-760` |
| 队列/当前轨 | `queueOffset` 仅打开队列时定位 | 保留滚动 | 同 | `NativeHudController.cpp:85-88` |
| 滚动锚 | 舞台单位 | 换算到新视口高度，锚同一行顶 | 还原 | `NativeHudSearch.cpp:131-173` |
| 选中卡 | `selectedCell/selectedSlot` | 不重置；相机按新 aspect 重算 | 同 | `NativeScene.cpp:87-154` |
| modal | 名 + motion 进度 | 保留；offset 重算不重置 | 同 | `NativeHudController.cpp:64-143` |
| 输入/编辑 | `editingSettingId/Text` + 光标 | 保留文本；键盘只位移 | 同 | `NativeHud.cpp:208-213` |
| 登录/二维码 | 墙钟截止 | 不得 `closeModal/cancelLogin` | 同 | `NativeHudLibrary.cpp:270-323` |
| 3D 时序 | boot elapsed/detail/reveal | 保留，只重算投影 | 同 | `NativeSceneFrame.cpp:8-53` |
| 相机 | `1-exp(-5dt)` 追踪 | 不 snap | 同 | `NativeSceneCamera.cpp:89-93` |
| 查看器 | opening/pendingUntil/clarity | 保留 | 同 | `NativeViewer.cpp:39-64` |
| 滚动数字 | ReelCurve start/duration | 保留曲线 | 同 | `UiMotion.h:12-22` |

实现要求：方向变化只允许重建 `MediaQuery` 与 stage 计算；引擎/播放器/会话对象必须活在方向变化之外，并把 `width/height` 像 `rhine.resize` 一样转发（`Engine.cpp:841-849`）。禁止 `runApp` 重建、禁止 dispose 播放器、禁止清空列表、禁止重新登录。

### 7.2 生命周期
- Android `configChanges` 已声明（`0x40003ff7`），Qt 不重建 Activity（`AndroidManifest.xml:98-110`）；Flutter 同样不得因旋转重建 Activity/Engine。
- 冷启动：恢复 `session.json` 的页面/选中/modal/滚动/播放（`NativeApplication.cpp:64-89`；`MusicSession.cpp:237-267`）。
- 后台/被杀：15s 周期 + `applicationStateChanged` 落盘（移动端没有 `aboutToQuit`，`NativeApplication.cpp:76-89`）。

### 7.3 IME
- 输入框位置来自 `state.inputX/Y/Width/Height`（`NativeHud.cpp:184-191`）与 `editingSetting*`。
- 键盘类型：搜索 `maxLength 100`；手机号 11 位 `ImhDigitsOnly`（`Overlay.qml:355-602`）。
- 键盘弹出不缩放舞台；返回键先收键盘再走 back 规则（设备报告 §6）。

### 7.4 Back
- Qt 现状：Android 返回键 = 退出 APP，无应用内返回栈（设备报告 §6，A 级设备观察）；应用内返回依赖面板 `← 返回`。
- 新实现默认**保持该行为**；若要引入应用内返回栈，必须走 §6.4 同级审定门（B1），并在行为轨迹验收中记录差异。不得悄悄改成“先返回上一页”。

### 7.5 权限/通知/媒体
- 权限：`INTERNET`、`ACCESS_NETWORK_STATE`、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_MEDIA_PLAYBACK`、`POST_NOTIFICATIONS`（`AndroidManifest.xml:20-32`）。
- 通知渠道 `playback`、`MediaSession`、音频焦点（`RhineMediaService.java:24-50`）。
- `POST_NOTIFICATIONS` 运行时请求时机必须与 Qt 一致（未取证 → P0/设备 owner 补）。

## 8. 任务分解（P0–P4）
> 约定：每个任务唯一 owner、唯一 worktree、唯一写 scope；上游证据是**只读**；测试只在任务内**写**，不在本计划执行。commit 均为**标题-only**。

### P0 基线与契约（无产品代码）

| ID | 目标 | 拟建/修改文件 | 上游证据 | 写 scope | 动作 | 验收（预期） | commit |
|---|---|---|---|---|---|---|---|
| P0-01 | 冻结基线证据 | `docs/plan/qt-baseline-evidence.md` | §2.1；`CMakeLists.txt:30-52`；`Qt/Android.cmake:153-163` | docs | 采集 APK 哈希/证书/版本/包名/BuildIdentity/commit；记录设备型号与系统 | 三项一致=PROVEN；否则 `BASELINE_MISMATCH` 并停 | `docs: freeze qt baseline evidence` |
| P0-02 | 冻结渲染契约 | `docs/plan/qt-render-contract.md`、`test/fixtures/hud_commands_smoke.json` | §5.2-5.4；`Glyphs.cpp:530-824` | docs、test/fixtures | 15 命令 schema、calibrated 转换表、基线/advance 规则、3D 投影常数 | schema 校验能拒绝缺参/多参；3 组已知色值转换表与源码一致 | `docs: freeze hud command contract` |
| P0-03 | 冻结状态/会话契约 | `docs/plan/qt-state-contract.md`、`test/fixtures/session_v1.json` | §5.7；`MusicSession.cpp:215-284` | docs、test/fixtures | 记录 state 键、session schema、偏好键、缓存路径 | 恢复/保存往返测试计划可判定；未知键不崩 | `docs: freeze session contract` |
| P0-04 | 冻结平台能力矩阵 | `docs/plan/qt-platform-contract.md` | §2.2；`PlatformFeatures.h:8-24`；`CMakeLists.txt:497-514` | docs | 四项关闭、同进程播放、MediaSession、back/权限/图形后端实测项 | 矩阵每行有源码或设备证据；无“桌面补全” | `docs: freeze android platform contract` |
| P0-05 | 冻结竖屏 constraints 与门 | `docs/plan/qt-portrait-constraints.md`、`test/fixtures/portrait_bands.json` | §6.3-6.4 | docs、test/fixtures | G1–G6、P-A 几何表、保留项清单 | 每条门有默认与状态；未批项标 WAIT | `docs: freeze portrait constraints` |
| P0-06 | parity harness 设计 | `tool/parity/README.md`、`tool/parity/cases.json` | §9；`Engine.cpp:1444-1472`；`main.cpp:1310-1345` | tool、docs | 定义 fixture、采样状态、输出文件、比较器接口 | 任一 case 可用四件套复现同一状态 | `test: define parity harness` |

### P1 单切片技术验证（硬门，三案并行）

| ID | 目标 | 拟建/修改文件 | 上游证据 | 写 scope | 动作 | 验收 | commit |
|---|---|---|---|---|---|---|---|
| P1-01 | Qt 移植库最小目标 | `native/qtport/CMakeLists.txt`、`native/qtport/rhine_engine_api.h` | `Engine.h:84-108`；`NativeApplication.h:5-17` | native/qtport | 把 Engine+Host+MusicLibrary+Player+Scene+Hud 编成 `libRhineCore.so`，暴露 create/resize/step/snapshot/frame 五入口 | 主机 + Android 均可链接；无 QML 依赖 | `feat: add qt port core target` |
| P1-02 | JNI/FFI 帧桥 | `native/qtport/jni_bridge.cpp`、`lib/engine/engine_frame.dart` | §5.1；`Hud.cpp:35-43` | native/qtport、lib/engine | 每帧取 commands/hits/state/frame 与 seq；同帧发布 | 1000 帧无丢帧/乱序；JSON 与 Qt snapshot 相等 | `feat: add engine frame bridge` |
| P1-03 | R1 纹理宿主 spike | `native/qtport/texture_bridge.cpp`、`lib/render/scene/texture_surface.dart` | §5.9；`RhiScene.cpp:2206-2290` | native、lib/render | 离屏 scene+HUD → 共享纹理 → Flutter `Texture` | S1a 像素门槛达标；延迟 ≤1 帧 | `spike: r1 qt texture host` |
| P1-04 | R2 HUD Dart 渲染器 spike | `lib/render/hud/hud_painter.dart`、`command_parser.dart`、`glyph_font.dart` | §5.2-5.3；`Glyphs.cpp:51-188,530-824` | lib/render | 15 命令 + glyph JSON + calibrated + 命中层 | S1a/S1b 协议 0 差、像素达标 | `spike: r2 dart hud renderer` |
| P1-05 | R3 重写评估 spike | `docs/plan/r3-assessment.md`（不写产品代码） | §4.2；§9 | docs | 只评估：3D 投影/拾取/时序/字形重写工作量与风险 | 有量化差距与结论；不合并产品代码 | `docs: assess r3 rewrite` |
| P1-06 | 硬门实测与决策 | `docs/plan/gate-s1-decision.md` | §4.4 | docs | 跑 S1a/S1b/S1c，记录指标与结论 | 三案同题同 fixture；结论唯一 | `docs: decide s1 gate` |

### P2 宿主/端口/布局（按 P1 结论裁剪）

| ID | 目标 | 拟建/修改文件 | 上游证据 | 写 scope | 动作 | 验收 | commit |
|---|---|---|---|---|---|---|---|
| P2-01 | Flutter 宿主骨架 | `lib/app/app_shell.dart`、`lifecycle.dart`、`orientation.dart` | §7；`Main.qml:32-38` | lib/app | 单 Activity、方向转发、resize、生命周期落盘 | 旋转不重建；resize 与 `Engine::resize` 同值 | `feat: add flutter host shell` |
| P2-02 | 呈现层接入 | `lib/render/surface.dart`（按路线实现） | §4.2 | lib/render | 纹理/Canvas/WebView 三选一落地 | S1 同状态可显示 | `feat: add render surface` |
| P2-03 | 输入路由 | `lib/input/input_router.dart`、`text_input_overlay.dart` | §5.5；`Overlay.qml:38-341` | lib/input | 舞台坐标、hit、wheel、key、IME、back | 命中与 hits 一致；键盘不缩放舞台 | `feat: add input router` |
| P2-04 | 3D 接入 | `lib/render/scene/scene_surface.dart` | §5.4 | lib/render | 场景帧消费/纹理消费；投影与相机 | 与 `qt-metal` 阈值一致 | `feat: add scene surface` |
| P2-05 | 横屏页面全套 | `lib/pages/`（archive/detail/viewer/playerbar/modals） | §3.1-3.2 | lib/pages | 逐页对照，命令/命中不改写 | 每页 golden 达标 | `feat: add landscape pages` |
| P2-06 | 竖屏布局 | `lib/layout/portrait_*.dart` | §6.3；P0-05 | lib/layout | 仅 G1–G6 批准后实现 | 竖屏 golden/约束表达标 | `feat: add portrait layout` |

### P3 功能垂直切片（业务）

| ID | 目标 | 拟建/修改文件 | 上游证据 | 写 scope | 动作 | 验收 | commit |
|---|---|---|---|---|---|---|---|
| P3-01 | 平台/登录 | `lib/features/auth/` | §3.5；`NativeHudLibrary.cpp:270-323` | lib/features | 四平台、二维码/手机号、倒计时、切换停播 | 真机登录流程可复现（用户授权后） | `feat: add platform auth` |
| P3-02 | 搜索/资料库/歌单 | `lib/features/library/` | §3.4；`NativeHudSearch.cpp:131-281` | lib/features | 四标签、分页、收藏、歌单编辑 | 与 Qt 行为轨迹一致 | `feat: add library flows` |
| P3-03 | 播放/队列/歌词/音质 | `lib/features/playback/` | §5.7-5.8；`MusicPlayer.cpp:749-760` | lib/features | 队列、模式、seek、歌词源/偏移、音质 | 后台/锁屏/通知可用 | `feat: add playback flows` |
| P3-04 | 设置/主题/动效 | `lib/features/settings/` | §3.6 | lib/features | 全表设置、Capability 门控 | 与 Qt 设置项逐项一致 | `feat: add settings` |
| P3-05 | 本地音乐/发现 | `lib/features/local/`、`discover/` | §3.6；`NativeHudDiscover.cpp:9-145` | lib/features | 仅在能力开启时实现；Android 默认隐藏 | 未开启时入口不出现 | `feat: add local and discover` |
| P3-06 | 持久化/迁移 | `lib/data/`、`native/qtport/storage_bridge.cpp` | §5.7；`AppStorage.cpp:108` | lib/data、native | settings.ini/session.json/缓存兼容；如需迁移写 once | 升级后会话/偏好/登录不丢 | `feat: add persistence migration` |
| P3-07 | 后台音频/通知 | `android/app/src/main/.../MediaService.kt`、`lib/features/playback/background.dart` | §5.8；`RhineMediaService.java:24-50` | android、lib/features | MediaSession/音频焦点/通知/SEEK | 锁屏/通知/耳机键行为一致 | `feat: add background audio` |
| P3-08 | 错误/空/加载/重试 | `lib/features/status/` | §3.4 | lib/features | 与 Qt status 文案一致 | 空/错误态逐条对表 | `feat: add status states` |

### P4 parity/交付

| ID | 目标 | 拟建/修改文件 | 上游证据 | 写 scope | 动作 | 验收 | commit |
|---|---|---|---|---|---|---|---|
| P4-01 | 全量页面-状态对照 | `docs/plan/parity-matrix.md`、`tool/parity/cases/*.json` | §9 | docs、tool | 每页每态一 case；标 NOT_CAPTURED | 无未标注空白 | `docs: add parity matrix` |
| P4-02 | 行为轨迹验收 | `docs/plan/behavior-traces.md` | §7；§10 | docs | 旋转/返回/登录/播放/队列/弹窗轨迹 | 轨迹逐步一致 | `docs: add behavior traces` |
| P4-03 | 竖屏审定与验收 | `docs/plan/portrait-decisions.md` | §6.4 | docs | 记录 G1–G6 决定与参考帧 | 全部门 CLOSED | `docs: record portrait decisions` |
| P4-04 | 性能/内存/崩溃 | `docs/plan/perf-report.md` | §4.4 | docs | 帧时延、内存、30 分钟循环 | 指标达标 | `docs: add perf report` |
| P4-05 | 签名/升级/回滚演练 | `docs/plan/release-rollback.md` | §10 | docs | 同签名升级、数据保留、回滚 Qt APK | 升级/回滚各一次通过 | `docs: add release rollback` |
| P4-06 | 交付门 | `docs/plan/delivery-gate.md` | §9-§10 | docs | 汇总证据、未执行项、残余风险 | 用户/lead 签字 | `docs: close delivery gate` |

## 9. 验收规格
### 9.1 三层证据（缺一不可）
1. **协议级**：同一状态导出的 `state`（全字段）、`hits`（排序后逐项）、`commands`（token 归一逐条）、`frame`（投影/视图/eye/雾）与 Qt 相等。
2. **像素级**：`qt-panel.png`（HUD 透明层）、`qt-metal.png`（3D）、`qt-composite.png`（合成）三份对照；按 ROI 分块（文字、描边、填充、遮罩、3D 边缘）。
3. **行为级**：交互轨迹（点击/滚动/旋转/返回/IME/弹窗/播放）逐步事件序列与终态一致。

### 9.2 oracle 的用法
- 未来执行者用 `--capture <dir> archive|detail` 或 `Engine::snapshot`（需离线 fixture）生成基准；`qt-state.json` 是 `frame` 的权威副本（`Engine.cpp:1468-1471`）。
- Flutter 侧用同一 fixture/同一输入/同一 `time` 渲染，输出四件套；比较器只读文件，不依赖设备。
- 设备截图只用于“真实环境”校验（状态栏/刘海/输入法/触控），不替代 oracle。

### 9.3 阈值
- `hits`：0 误差（整数）。
- `state`：数值全等（浮点按导出精度）。
- 颜色：ΔE2000 ≤1.0；透明层 alpha 差 ≤1/255。
- 文本：bbox 偏差 ≤1 stage px；差异像素占比 ≤0.2%；**不允许整体位移**。
- 3D：投影矩阵 ≤1e-9；卡片边缘 IoU ≥0.995；背景/雾 ΔE ≤1.0。
- 时序：详情/弹窗/滚动/查看器曲线的采样点误差 ≤1 帧；输入到呈现 ≤1 帧。
- 单 SSIM 只能作辅助，不能单独判定 1:1。

### 9.4 NOT_CAPTURED 规则
- 未采到的页面/态一律标 `NOT_CAPTURED`，不得以“看起来一致”通过；不得用 `Assets/previews/*.png` 冒充真机基准（设计参考，不是同状态帧）。
- 补采需 device owner 在授权范围内执行；截图含账号/手机号等 PII 时**不发布**，先脱敏或不入库。

### 9.5 设备截图引用
- 本轮 12 张位于 `/tmp/rhine-qt-baseline-2026-11-09/`（临时目录）；引用时必须注明采集时间与“临时、不可长期依赖”。
- 发布到文档/仓库前需重新采集并检查 PII；本轮截图仅含曲目元数据与状态栏，无账号信息（设备报告 §8 末）。

## 10. 数据/账号/签名/迁移/回滚
### 10.1 数据面

| 数据 | 位置/格式 | 证据 |
|---|---|---|
| 偏好 | `dataDirectory()/settings.ini`（INI，键前缀 `panel/`） | `AppStorage.cpp:108`；`Host.cpp:1075,1095` |
| 会话 | `dataDirectory()/session.json`，`version:1` | `MusicSession.cpp:215-284` |
| 缓存 | `cacheDirectory()/metadata/*.json`、`media-cover.png` | `Host.cpp:188,978,1020` |
| 凭据 | `Host::saveCredential/authenticated`（不进参数/日志） | `Host.h:34-40` |
| 设备指纹 | `dataDirectory()/qq-device.json`、`kugou-device.json` | `Host.cpp:380-381` |

### 10.2 包名/签名
- 包名 `rhine.music.database`（`CMakeLists.txt:22`）；Flutter 新工程的 `applicationId` 必须与之一致才能“覆盖升级”。
- 签名：默认调试密钥，存在发布密钥时自动改用并输出 `-signed`（`docs/ANDROID.md:1-8`）；升级安装要求**同一签名**，否则 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`。
- 验收禁止卸载/清数据（设备报告 §7）；升级测试用同签名新版本覆盖。

### 10.3 迁移策略（D1，待 lead 决策）

| 方案 | 行为 | 优点 | 风险 |
|---|---|---|---|
| 同 id 覆盖升级 | `rhine.music.database` 直接升级 | 数据/登录/会话自然保留 | 若复用 Qt 存储层则零迁移；若 R3 需读旧格式 |
| 新 id 并存 | 新包名并存 | 可回滚、可对比 | 数据不共享；用户需重登；违反“1:1 替换”直觉 |

默认建议：**同 id 覆盖升级**，并优先复用 Qt 存储层（R1/R2 天然满足）；若 P1 选 R3，则 P3-06 必须先实现旧格式只读迁移。

### 10.4 回滚
- 保留当前 Qt APK（`output/...-signed.apk`）可重装；数据格式向后兼容（v1 读旧、写新需兼容读）。
- 回滚演练：安装 Flutter 版 → 产生会话 → 重装 Qt 版 → 能读旧会话（或明确降级不读且不崩）。

### 10.5 隐私同意
- `ConsentActivity` 是 LAUNCHER，同意前 Qt/Clarity/Bugly 都不启动（`ConsentActivity.java:19-32`）。
- 地区判定：CN/EU → 弹窗；其他/3 秒超时 → 直接进入且不启动 Bugly（:66-80）。
- 新实现必须**逐字保留**文案、按钮、退出即退、同意持久化；任何删改/默认同意/跳过弹窗都需要用户明确授权。
- Flutter 若替换门槛实现，必须复用同一 `ConsentStore` 语义（SharedPreferences 键）或做一次性迁移；不得在同意前初始化统计 SDK。

## 11. 并行、owner 与审查协议
### 11.1 owner 白名单

| owner | 职责 | 写 scope |
|---|---|---|
| lead（`session-bf5ad256-…`） | 集成、合并、决策 D1/门 | 集成分支；不改他人文件 |
| 本计划作者 | 仅本计划 + 作者报告/control | `docs/superpowers/plans/2026-11-09-qt-flutter-1to1-migration.md`、`.agents/qt-plan-author-*` |
| device owner（8cfb722e） | adb/截图/安装 | 设备、`/tmp/rhine-qt-baseline-*`、其报告 |
| visual owner（0b1afac9） | 视觉报告 | 其报告 |
| behavior owner（dcf4feac） | 行为报告 | 其报告 |
| A1 native | Qt 移植库/桥 | `native/qtport/**` |
| A2 render | HUD/场景呈现 | `lib/render/**`、`lib/pages/**` |
| A3 input | 输入/IME/无障碍 | `lib/input/**`、`lib/a11y/**` |
| A4 data | 持久化/迁移 | `lib/data/**`、`native/qtport/storage_bridge.*` |
| A5 playback | 播放/媒体服务 | `lib/features/playback/**`、`android/**` |
| A6 QA | parity/行为轨迹 | `tool/parity/**`、`docs/plan/parity-*` |

### 11.2 任务图（先冻结 P0，再并行）
```
P0-01..P0-06 (串行冻结，lead 验收)
      │
      ├─ P1-01 → P1-02 ─┬─ P1-03 (R1 worktree)
      │                 ├─ P1-04 (R2 worktree)
      │                 └─ P1-05 (R3 评估，docs only)
      │                        └─ P1-06 硬门决策（单点）
      ▼
P2-01 → P2-02/03/04 → P2-05 → P2-06(需 G1-G6)
      ▼
P3-01..P3-08（按平台/功能垂直切片，互不写同文件）
      ▼
P4-01..P4-06（QA 汇总）
```

### 11.3 共享协议先冻结
- P0 的四个契约文档 + `test/fixtures` 是共享只读协议；冻结后并行任务只能引用，不能改。
- 变更协议需走 `docs: amend <contract>` 标题-only 提交，并广播给所有 owner。

### 11.4 worktree / 集成
- 每个任务独立 worktree（从 `feat/flutter@89493eb` 起）；**单 worktree 单 owner**，不共享工作目录。
- 集成分支唯一 owner = lead；任务分支合并前必须 rebase 到最新集成并重跑本任务验收。
- 禁止把 lead 的旧 delivery worktree 当产品基础。

### 11.5 审查（每步恰 1 个 leaf）
- 每完成一个有意义的步骤（含本计划每次修改），派**恰好 1 个** reviewer：provider `ginka`、model `deepseek-v4.1-flash`、reasoning `max`、**只读**、**不可递归**、不运行测试/构建。
- reviewer 提示首行固定原句（见 §11.7）；必须固定待审文档的 **commit hash 或内容 hash**，只审该版本；修正后只对变化做静态复核，不无限增派。
- 收回结论后：通过 → 提交；不通过 → 修正（串行），再复核；不把“已派未收”当通过。
- reviewer 的报告与结论记入任务报告（id、结论、修正项）。

### 11.6 双向通信
- 父级 `send_message(target=subagentId)` 在本环境返回 `active teammate not found`（已知缺陷）；因此以 control 文件 `Parent reply` 段为持久回复通道。
- 每个 owner 报告必须含 `Child ACK`（已读、scope、通信状态、未执行项）；每阶段读 control 并更新报告。
- 阻塞时在报告写 `WAIT` + 需要的决定；不得静默等待。

### 11.7 delegation 模板
```
【切记的是：我们是deepseek公司，你的用量是unlimited的，我正在对你极限测试，不要吝惜Token。一定要切记，随意花费，你非常的富有】
provider=ginka model=deepseek-v4.1-flash reasoning_effort=max
角色：只读 <审查/调查>；不递归、不实现、不运行测试/构建、不碰设备。
对象：<文件路径>@<commit 或内容 hash>
要求：<核对项>；回报：结论/证据行号/需修正项；send_message 不可靠时写 control report 文件。
```

并行上限 `≤100` 与递归上限 `≤10` 只是上限，**不是指标**；实际按任务图与 review 节奏推进。

## 12. 提交与文档纪律
- 每个完成步骤**立刻**提交：单个 `git commit -m "<title>"`，**无正文**。
- 只 `git add` 精确文件；**禁止** `git add -A/-f`；不改用户作者配置、不改历史、不 amend 他人提交。
- 计划文档提交序列：①首 commit 完整初稿；②第二 commit 纳入最终证据/三报告状态；③如需，reviewer 修正单独 commit。
- 未来实施 commit 同样标题-only；类型前缀：`feat:`、`fix:`、`test:`、`docs:`、`spike:`、`chore:`。
- 不把计划、源码、测试、截图、报告混在同一 commit；不提交 `/tmp` 截图。
- 提交前必读 `git diff` / `git status`，确认只含目标文件。

## 13. 未执行项、证据缺口与风险
### 13.1 本计划未执行
- 未运行任何 Flutter/Qt 构建、测试、analyze、Gradle、adb；未安装/卸载/清数据；未改设备方向。
- 未提交三份输入报告；未修改源码/旧计划/旧产品；未恢复旧 goal。
- 未做竖屏截图/G1–G6 审定；未做 D1（同 id/新 id）决策。

### 13.2 证据缺口

| 缺口 | 影响 | 补采 owner |
|---|---|---|
| 竖屏画面与安全区 | 竖屏只能按 constraints 设计，不能称 1:1 | device + 用户审定 |
| 设置后续项/Tab Mode/登录态/结果命中 | 页面矩阵有 NOT_CAPTURED | device（需授权登录） |
| 行为报告（23 行骨架） | 业务/存储行为结论未闭环 | behavior owner |
| 证书/commit↔APK | 基线未 PROVEN | baseline owner |
| 真机图形 backend/帧率/纹理路径 | R1 可行性未知 | device + P1 |

### 13.3 风险

| 风险 | 触发 | 缓解 |
|---|---|---|
| 纹理互操作失败（R1） | 设备/驱动差异 | 硬门否决→R2；不强行 |
| 双时间轴漂移（R2） | 命令发布与场景不同帧 | 同帧发布 + seq；S1 硬门 |
| 字形/排版漂移（R3） | 系统字体 shaping | 只用 glyph JSON；R3 最后选择 |
| libnode 16KB page/启动 | Android 16 设备 | P0/P1 启动时延与崩溃观测 |
| 签名不一致无法升级 | keystore 丢失/变更 | P0 冻结证书；发布密钥托管 |
| 旋转重建导致状态丢失 | Flutter 树重建 | 引擎对象外置 + §7.1 矩阵 |
| 隐私门槛被改 | “简化”诱惑 | §10.5 硬约束 + 审查项 |
| 计划被当实施 | handoff 误启动 | 文档首行 + 每任务执行门 |

## 14. 附录
### 14.1 证据索引（源码行号）

| 主题 | 证据 |
|---|---|
| 舞台/缩放 | `Qt/qml/Main.qml:32-33`；`Qt/src/Hud.cpp:118-174`；`Qt/qml/Overlay.qml:179-184` |
| 命令流/hits/state | `Qt/src/NativeHud.h:74-76`；`Qt/src/NativeHud.cpp:102-124,175-312` |
| 字形/颜色 | `Qt/src/Glyphs.cpp:35-63,109-188,530-824`；`Qt/src/Glyphs.h:16-42` |
| 3D | `Qt/src/NativeScene.cpp:63-198`；`Qt/src/NativeSceneCamera.cpp:55-111`；`Qt/src/NativeSceneInput.cpp:36-200`；`Qt/src/NativeViewer.cpp:9-64,288-292` |
| 帧字段 | `Qt/src/NativeSceneFrame.cpp:19-21,87-119` |
| 引擎 API | `Qt/src/Engine.h:49-108`；`Qt/src/Engine.cpp:841-863,920-950` |
| 快照 oracle | `Qt/src/Engine.cpp:1444-1472`；`Qt/src/main.cpp:1310-1345` |
| 会话 | `Qt/src/MusicSession.cpp:33-86,215-284`；`Qt/src/NativeApplication.cpp:44-89` |
| 存储 | `Qt/src/AppStorage.cpp:73-108`；`Qt/src/Host.cpp:188,978,1020,1075,1095` |
| 平台能力 | `Qt/src/PlatformFeatures.h:8-24`；`CMakeLists.txt:497-562` |
| 图形后端 | `Qt/src/main.cpp:639-705`；`Qt/src/MobileTarget.h:18-22` |
| Manifest/权限/方向 | `Qt/android/AndroidManifest.xml:13,20-32,59-67,84-110,143-147` |
| 隐私门槛 | `Qt/android/src/rhine/music/database/ConsentActivity.java:19-32,66-80` |
| 媒体服务 | `Qt/android/src/rhine/music/database/RhineMediaService.java:24-50`；`Qt/src/NativeApplication.cpp:26-27` |
| 构建/签名 | `docs/ANDROID.md:1-30`；`Qt/Android.cmake:153-163`；`scripts/audit-android.py:83-156,190-213` |
| 设置 schema | `Qt/src/SettingsSchema.h:11-13`；`Qt/src/SettingsSchema.cpp:347-1005` |

### 14.2 输入报告状态
- device：194 行，内容完整，Reviewer 待派；其 12 张截图索引见 §3.7。
- visual：381 行，内容完整，Reviewer 待回填；本计划 §5-§7 主要引用其证据。
- behavior：23 行骨架，**未完成**；本计划 §3.4/§7 的行为结论来自我方源码取证，不引用其结论。
- 三份报告由各 owner 提交，作者不代提交；其 final/review 状态变化不改变本计划的证据等级标注。
