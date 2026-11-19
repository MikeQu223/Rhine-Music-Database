# Flutter Android 重构实施计划（基本功能 · 对齐 main 的 iOS / macOS）

2026-11-08 ｜ 基线 `main@2a5d5ca` ｜ Flutter 3.47.8 / Dart 3.13.7 ｜ 当前分支 `feat/flutter`

> 修订 2（2026-11-08）：按六项决策更新——3D 必须真实渲染、登录只做接口且每种最多测 2 次、包名/签名不动且不处理旧数据、本地音乐接口预留、官方入口不显示、塞壬按 P1 接入。实现取向改为发挥 Flutter 生态，不照搬 Qt 内部结构。
>
> 修订 3（2026-11-08）：3D 改为 **Flutter GPU / flutter_scene 优先（Android Vulkan）**，不移植 Qt 渲染器；OpenGL ES 仅作备选并明确限制。签名确认不会自动使用自定义 key；允许精选插件；QQ/酷狗播放不纳入测试；更新检查不做、只留接口。
>
> 修订 4（2026-11-08）：清理口径冲突——播放验证统一为只验网易云；3D 材质差异不再豁免，按 §3.6 阈值量化判定；更新检查明确为「不做 + 接口预留」而非后置待办；统一 Qt 呈现层的例外批准路径（默认不移植、例外需明确批准，任何情况都不降 2D），并把 M0.5 的三个待确认点汇总到 §6.2。
>
> 修订 5（2026-11-08）：§6.2 四个确认点全部定案，覆盖修订 3/4 里的两处余地——① QQ/酷狗**不做任何真机测试**（原为「仅跳过播放测试」）；② **首版仅 Vulkan**，无 Vulkan 明确显示「3D 不可用」，OpenGL ES 从「受限备选」降级为**接口预留**；③ 3D 效果以 Qt 版为标准，首版不削减，优化方向等人工测试后再给；④ A/B 全不达标**暂停 3D 部分**，取消「例外批准移植 Qt」这条路。详见 §1.6 #11、#13–#15 与 §6.2。

**目标：** 用 Flutter 重写 Android 客户端，功能与 `main` 分支的 iOS / macOS 版本对齐。只做基本功能；不做遥测，不做性能优化；竖屏与横屏都可用，启动时保持系统当前方向；3D 主视觉必须是真实 3D，与现有版本保持同一几何、相机、动效与材质呈现。

**非目标：** 重写音乐协议；本地音乐（接口预留、首版不做）；官方客户端入口；桌面歌词与窗口控制；应用内音量；遥测与崩溃上报；性能面板与图形调优；应用内下载或更新器。

---

## 0. 结论先行

1. **业务不能重写。** 三家平台的登录、搜索、详情、播放地址、歌词、歌单编辑都在 `MusicBridge/` 的 Node 实现里，原生侧只做状态机与适配。Dart 直接实现协议不可行：加密、签名、设备指纹、Cookie 与风控都在上游模块内。Flutter 必须复用同一个 Node Worker，否则「功能对齐」无从谈起。
2. **iOS 是移动端对齐基准。** iOS 与 macOS 共用同一套 `MusicLibrary / MusicPlayer / LyricsController / NativeHud`，差异只由 [`PlatformFeatures.h`](../../../Qt/src/PlatformFeatures.h) 与窗口适配决定。Android 首版按 iOS 的能力集实现：无本地音乐、无官方客户端入口、无应用内音量、无桌面歌词。
3. **Qt Android 版不是基准。** `feat/android-armv8a` 上的 Android 专属功能不进入本清单；该分支只作为 libnode 启动与资源打包的参考实现。
4. **3D 必须是真实 3D，且优先 Flutter 生态。** 不接受 2D 贴图/预烘图模拟，也不移植 Qt 渲染器。用同一套 GLB 与场景数据，在 **Flutter GPU 系**（`flutter_scene` 为首选，备选 `just_graphics_engine` / `glint_engine` / `flutter3d`）上复现同一相机与动效；**首版仅 Android Vulkan**，OpenGL ES 只预留接口（§3.11）。达不到 §3.6 阈值就**暂停 3D 部分**，不移植 Qt、不启用 GLES、**任何情况都不降级 2D**。
5. **首版最大的三个未知在写 UI 前验证：** libnode 能否在目标 Android 版本（含 16 KB 页）稳定加载；网易云音源能否被 Flutter 播放器直接播放；Flutter 3D 能否在 Vulkan 设备上既保真又流畅。3D 相关的未知若判负，按 §1.6 #15 暂停 3D 部分，其余功能继续。

---

## 1. 对齐口径

### 1.1 现有实现关系（代码事实）

- iOS 与 macOS 共用 `MusicLibrary / MusicPlayer / LyricsController / NativeHud / MusicBridge`；没有 iOS 专用的音乐业务副本（见 `docs/IOS-MAINTENANCE.md`「维护原则：业务只改一份」）。
- 平台差异集中在 `Qt/src/PlatformFeatures.h`：
  - iOS：`OfficialPlayback=false`、`LocalMusic=false`、`ApplicationVolume=false`、`DesktopWindowControls=false`、`DesktopLyrics=false`；
  - macOS：以上均为 `true`（`DesktopLyrics` 仅 macOS/Windows）。
- iOS 仅横屏（`Qt/InfoIOS.plist.in` 只声明 LandscapeLeft / LandscapeRight）；macOS 是可缩放窗口。
- iOS 有系统媒体中心、音频会话、中断与路由变化处理（`Qt/src/PlatformIOS.mm`）；macOS 使用系统媒体键。
- 两端共用同一套 HUD 与 1920×1080 舞台坐标，按高度缩放。

因此：**只要不碰上面五项能力，iOS 与 macOS 的用户可见行为就是同一套。** 下文用「两端一致」表示这一点。

### 1.2 能力矩阵

| 能力 | iOS（main） | macOS（main） | Android 首版 |
| --- | --- | --- | --- |
| 屏幕方向 | 仅横屏 | 可缩放窗口 | 竖 + 横，跟随系统 |
| 面板内播放 | 支持 | 支持 | 支持 |
| 官方客户端入口 | 关闭 | 支持 | 不显示（已定；无 Intent） |
| 本地音乐 | 关闭 | 支持 | 不做；接口预留，不显示入口 |
| 应用内音量 | 关闭（系统音量） | 支持 | 关闭（系统音量） |
| 桌面歌词 | 不支持 | 支持 | 不支持 |
| 窗口控制 / 置顶 / 关闭行为 | 不支持 | 支持 | 不支持 |
| 3D 资料库 | Metal 实时 3D | Metal 实时 3D | 实时 3D，Flutter GPU/flutter_scene，**仅 Android Vulkan**；同一 GLB/相机/动效；无 Vulkan 显示「3D 不可用」 |
| 触控滚动 | 拖动转滚轮 | 滚轮 | 原生滚动 |
| 后台 / 锁屏控制 | 媒体中心 | 系统媒体键 | MediaSession + 通知 |
| 凭据存储 | Keychain | Keychain | Keystore |
| 更新检查 | 有（打开 GitHub） | 有 | 不做；`UpdateService` 接口预留 |
| 性能面板 / 图形设置 | 有 | 有 | 不做（明确排除） |

### 1.3 「基本功能」的边界

**纳入：** 启动与会话恢复、平台与账号、检索、个人音乐库、发现与歌手、详情、播放、队列、歌词、设置（偏好）、外壳与导航、数据缓存与安全。

**不纳入：** 本地音乐（接口预留，首版不做）、官方客户端入口（不显示）、桌面歌词、窗口控制、性能面板、图形后端 / AA / 超分 / 插帧、更新器、遥测与崩溃上报、MV / 评论 / 电台 / 下载（iOS 与 macOS 也没有）。

**分级：**

- **P0**：首版必须，缺一即判定「未对齐」；
- **P1**：首版应做；若延期，只能发布 Beta，不能判定「对齐完成」；延期项不得是登录、播放、检索、个人库、歌词、队列；
- **P2**：明确后置，不阻塞首版验收。

「塞壬唱片」已确认按 **P1 正式纳入**（含本机喜欢与自建歌单）；本地音乐、官方入口不做；更新检查**不做**，仅保留 `UpdateService` 空接口（§3.10），不列为 P2 待办。

### 1.4 方向与窗口（本次的硬要求）

- `AndroidManifest.xml` 不写 `android:screenOrientation`；启动时**不调用** `SystemChrome.setPreferredOrientations`。让系统按当前方向与旋转锁定决定，冷启动方向 = 启动瞬间的系统方向。
- 现有脚手架已包含 `configChanges="orientation|screenSize|smallestScreenSize|screenLayout|density|uiMode"`，旋转不重建 Activity。
- 布局按 `MediaQuery.orientation` + 宽度断点切换；播放器、弹层、输入法分别验证竖横两种形态。
- 边到边显示 + `SafeArea`；竖屏刘海、横屏挖孔/圆角都留安全区。
- 平板与折叠屏：竖屏也保持两栏（比例按 §3.5），不出现「竖屏就是放大手机」的布局。

### 1.5 已声明差异（不算缺陷）

| 项 | iOS / macOS（main） | Android 首版 | 说明 |
| --- | --- | --- | --- |
| 屏幕方向 | iOS 仅横屏；macOS 窗口 | 竖 + 横，跟随系统 | 本次的明确要求 |
| 更新检查 | 有 | 不做，`UpdateService` 接口预留 | 已定；无 UI、无网络请求 |
| 本地音乐 | iOS 关；macOS 开 | 不做，接口预留 | 已定；不显示入口 |
| 官方客户端入口 | iOS 关；macOS 开 | 不显示 | 已定；无 Intent |
| 触控滚动 | Qt 把拖动换算成 wheel；桌面用滚轮 | 原生滚动 | 只影响手感，不改变可滚内容与边界 |
| 性能面板 / 图形设置 | 有 | 不做 | 用户明确排除性能相关内容 |

除此之外，功能行为以 iOS 为基准逐项对齐；上表之外的差异按缺陷处理。**3D 不在差异表里——必须真实渲染并达到 §3.6 的阈值。** 首版仅 Vulkan 设备提供 3D，无 Vulkan 设备显示「3D 不可用」属于设备范围限制（§3.11），不计为功能差异。

### 1.6 本轮已定决策（实施时不再讨论）

| # | 决策 | 落地方式 |
| --- | --- | --- |
| 1 | 本地音乐暂时不做 | 定义 `LibrarySource` 抽象与 `LocalLibrarySource` 空实现；provider 列表不出现本地；不申请文件权限；不迁移任何本地索引 |
| 2 | 不显示官方客户端 | 不实现 `official` 动作、不显示入口、不写 Intent；`PlatformFeatures.officialPlayback = false` |
| 3 | 包名与签名不动，旧数据不处理 | 继续 `rhine.music.database`；沿用脚手架现有签名配置（debug），不新增/修改 keystore；安装前卸载 Qt 版；首启不扫描/迁移/清理旧 data |
| 4 | 3D 必须完全一致 | 真实 3D、同一 GLB/相机/动效；M0.5 用 Flutter GPU/flutter_scene 做保真度验证；达不到就**暂停 3D 部分**（§1.6 #15）；不移植 Qt 呈现层；任何情况都不降 2D |
| 5 | 塞壬唱片按 P1 接入 | 目录/分类/检索/详情/播放/歌词 + 本机喜欢/自建歌单，全部纳入对齐验收 |
| 6 | 登录只做接口，网易云每种最多测 2 次 | 六种登录方式全部实现状态机与桥接；**真机只在网易云扫码/短信各 ≤2 次**；QQ/酷狗四种不做真机测试；其余状态用 fixture/日志覆盖 |
| 7 | 不照搬 Qt 内部实现 | 不复刻 `NativeHud` 命令流、`Glyphs` 排版缓存、HUD 脏区重绘；用 Flutter 组件/状态/主题/动画实现同样的产品行为（见 §3.8） |
| 8 | 3D 优先 Flutter 生态，不移植 Qt 呈现层 | `flutter_scene`（Flutter GPU）为首选；备选 `just_graphics_engine`/`glint_engine`/`flutter3d`；**首版仅 Vulkan**；OpenGL ES 只预留 `SceneBackend` 接口、不实现（§3.11）；不写 Qt RHI 移植；达不到阈值就暂停 3D 部分 |
| 9 | 签名不会自动用自定义 key | 当前 `android/app/build.gradle.kts` 的 release 也指向 debug keystore；不会自动读取任何自定义签名。本次不改；若以后要改，需显式加 `signingConfigs.release` + `key.properties` |
| 10 | 允许精选插件 | 只接维护活跃、许可证兼容、无遥测的包；版本锁定、逐项审计；不接会改包名/签名或引入第二套遥测的插件 |
| 11 | QQ/酷狗不做真机测试 | 登录、写操作、播放的代码与状态机仍实现，但真机测试全部取消；只用 fixture/静态检查；真机只验网易云（两种登录、播放、音质、替代源） |
| 12 | 更新检查不做，只留接口 | `UpdateService` 空实现：`check()` 返回 null、`openReleasePage()` no-op；无 UI、无网络、无 GitHub 调用 |
| 13 | 首版仅 Vulkan，OpenGL 只留接口 | 无可用 Vulkan 的设备明确显示「3D 不可用」；定义 `SceneBackend` 的 GLES 实现点但不实现、不引入 `three_js`/`flutter_gl`、不验证、不验收（§3.11）；不静默降级 2D |
| 14 | 3D 效果以 Qt 版为标准 | 阴影/IBL/材质/动效一律按 Qt 版，首版不削减；M0.5 只记录 p50/p95 帧间隔与长帧作为数据，卡顿不作为改画面的理由；优化方向由你人工测试后再给 |
| 15 | 全不达标则暂停 3D 部分 | A/B 两个 Flutter GPU 候选均不达 §3.6 阈值 → 暂停 M0.5、M5 主视觉接入与 V-23；其余模块继续但不宣告「对齐完成」；不移植 Qt、不启用 GLES 接口、不降 2D；等你给方向再恢复 |

---

## 2. 基本功能清单

> 「现有行为」列描述 `main` 的 iOS / macOS 实际行为；「首版目标」列是 Flutter Android 要对齐的结果。依据列给出可核对的源码位置。共 12 个模块、98 项。
>
> 说明：`MusicLibrary` 里的 `suggest()` 与 `searchHistory` 在参考实现中没有被界面消费（`suggest()` 全仓库无调用点，`searchHistory` 只存不读）。`suggest()` 不实现；`searchHistory` 只在 M12 保留持久化语义，不做 UI。`MusicPlayer::history` 有界面：发现页的「历史」tab 按当前平台过滤展示最近 200 首。

### 2.1 M01 启动与会话恢复

| ID | 功能项 | 现有行为（iOS / macOS） | 首版目标 | 依据 |
| --- | --- | --- | --- | --- |
| 01-01 | 初始化页 | 两端一致：品牌轮廓描边动画 + 扫描阶段 + 进度，完成后进资料库 | 用 CustomPainter 复刻同一轮廓路径与阶段文案 | `NativeHudBoot.cpp` |
| 01-02 | 桥接启动 | iOS 进程内 NodeMobile，随机令牌回环；macOS QProcess | 进程内 `libnode` + 回环，令牌语义一致 | `BridgeProcessIOS.cpp`、`BridgeProcessAndroid.cpp` |
| 01-03 | 平台与账号恢复 | 两端一致：恢复上次 provider、酷狗版本、账号与昵称 | 同 | `MusicAccount.cpp`、`MusicSession.cpp` |
| 01-04 | 播放会话恢复 | 两端一致：当前曲、队列、索引、模式、位置、暂停意图、试听标记 | 同 | `MusicPlayer::sessionState` |
| 01-05 | 浏览会话恢复 | 两端一致：目录栈、选中项、搜索词/类别/游标、发现 tab、滚动位置 | 恢复平台 + 根视图 + 播放；深层目录按 P1 | `MusicLibrary::sessionState` |
| 01-06 | 启动失败与重试 | 两端一致：桥接失败显示错误并可重试，不白屏 | 同；错误码分类展示 | `BridgeProcess`、`Host` |

### 2.2 M02 平台与账号

| ID | 功能项 | 现有行为（iOS / macOS） | 首版目标 | 依据 |
| --- | --- | --- | --- | --- |
| 02-01 | 平台选择 | iOS：塞壬 / 网易云 / QQ / 酷狗（隐藏本地）；macOS：多一个「本地音乐」 | 与 iOS 相同；本地音乐入口不出现 | `NativeHudModal.cpp`、`PlatformFeatures.h` |
| 02-02 | 网易云扫码登录 | 两端一致：二维码 + 1 s 轮询（801 待扫 / 802 待确认 / 803 成功 / 800 过期），300 次后超时 | 同；轮询与超时逐值一致 | `MusicAccount.cpp` |
| 02-03 | 网易云短信登录 | 两端一致：手机号校验、验证码、60 秒重发冷却 | 同 | `MusicAccount.cpp`、`smsRetrySeconds` |
| 02-04 | QQ 扫码 / 微信扫码 | 两端一致：两种渠道；提示「7 天内最多 5 台设备」 | 同；限制文案保留 | `NativeHudLibrary.cpp`、`qq.mjs` |
| 02-05 | 酷狗标准版 / 概念版 | 两端一致：两版本独立扫码与独立凭据 | 同；按版本分别保存 | `MusicAccount.cpp`、`NativeHudModal.cpp` |
| 02-06 | 账号卡片 | 两端一致：昵称、头像、UID、会员状态（QQ）；先用缓存身份、后台刷新；塞壬显示「官网曲库 / 无需登录」 | 同 | `NativeHudSettings.cpp`、`restoreCachedAccount` |
| 02-07 | 退出登录 / 切换账号 | 两端一致：切平台或退出都会停止播放；退出清空最近播放记录，保留主题与偏好；账号数据隔离 | 同 | `MusicAccount.cpp`、`Host` |
| 02-08 | 登录异常 / 取消 | 两端一致：二维码过期、风控、网络错误、冷却均有提示与重试；取消登录会调用 `qr/cancel` 并清掉二维码 | 同；错误分类可重试，取消不残留轮询 | `MusicAccount.cpp` |

### 2.3 M03 检索

| ID | 功能项 | 现有行为（iOS / macOS） | 首版目标 | 依据 |
| --- | --- | --- | --- | --- |
| 03-01 | 检索入口 | 两端一致：导航「音乐检索 /」，打开检索弹层并聚焦输入 | 同；键盘自动弹出（可关闭） | `NativeHud.cpp`、`Main.qml` |
| 03-02 | 四类结果 | 两端一致：歌曲 / 专辑 / 歌单 / 歌手；本地模式下第三类为「文件夹」 | 在线模式四类；不实现本地文件夹 | `NativeHudSearch.cpp` |
| 03-03 | 分页加载 | 两端一致：滚动到底继续请求，返回条数与游标驱动 | 同；去重与乱序保护 | `MusicLibrary::search`、`MusicData` |
| 03-04 | 结果行操作 | 两端一致：播放、详情、下一首播放、加入队列、加入歌单、复制 | 同 | `NativeHudMusic.cpp` |
| 03-05 | 空/错/加载态 | 两端一致：空结果、请求失败、加载中都有明确文案 | 同；断网可重试 | `NativeHudSearch.cpp` |

### 2.4 M04 个人音乐库

| ID | 功能项 | 现有行为（iOS / macOS） | 首版目标 | 依据 |
| --- | --- | --- | --- | --- |
| 04-01 | 我的音乐入口 | 两端一致：导航「＋ 我的音乐」，打开个人库弹层 | 同 | `NativeHud.cpp` |
| 04-02 | 喜欢歌曲 | 两端一致：列表、分页、播放、红心 | 同 | `NativeHudLibrary.cpp` |
| 04-03 | 收藏歌单 / 专辑 / 歌手 | 两端一致：按 provider 能力展示并分页 | 同 | `MusicLibrary::refreshPersonal` |
| 04-04 | 自建歌单列表 | 两端一致：本人歌单、收藏歌单、非公开歌单（QQ） | 同 | `MusicLibrary::libraryItems` |
| 04-05 | 歌单增删改 | 两端一致：创建 / 改名 / 删除；QQ 有 1–20 字限制与能力开关 | 同；写操作二次确认 | `NativeHudModal.cpp`、`capabilities` |
| 04-06 | 加歌 / 移歌 | 两端一致：从歌曲行与详情加入歌单；从歌单移除 | 同 | `music:add-to-playlist`、`mutate` |
| 04-07 | 红心同步 | 两端一致：列表、详情、播放栏三处状态一致 | 同；单一状态源 | `songLiked`、`canLike` |
| 04-08 | 分组与排序 | 两端一致：按歌手/专辑分组；详情曲目按歌名/专辑/歌手排序 | 分组 P1，排序 P0 | `groupBy`、`detail-sort` |
| 04-09 | 分页 | 两端一致：首屏不足自动补页，到底停止 | 同 | `ensureSavedFilled` |

### 2.5 M05 发现与歌手

| ID | 功能项 | 现有行为（iOS / macOS） | 首版目标 | 依据 |
| --- | --- | --- | --- | --- |
| 05-01 | 发现入口与 tab | 两端一致：推荐歌单 / 每日推荐 / 排行榜 / 新专辑 / 分类歌单 / 历史；QQ 多「猜你喜欢」「新歌速递」，网易多「收藏歌手」 | 同；tab 随 provider 变化 | `NativeHudDiscover.cpp` |
| 05-02 | 推荐歌单 | 两端一致：分页、打开歌单详情、播放全部 | 同 | `MusicDiscover.cpp` |
| 05-03 | 每日推荐 / 每日 30 首 / 猜你喜欢 | 两端一致：登录后可见；未登录提示登录 | 同 | `MusicDiscover.cpp` |
| 05-04 | 排行榜 | 两端一致：榜单列表 → 曲目 → 播放 | 同 | `MusicDiscover.cpp` |
| 05-05 | 新专辑 / 新歌速递 | 两端一致：分页、打开专辑、播放 | 同 | `MusicDiscover.cpp` |
| 05-06 | 分类歌单 | 两端一致：分类选择 + 分页列表 | 同 | `MusicDiscover.cpp` |
| 05-07 | 收藏歌手 | 网易云独有：列表、进入歌手页 | 同 | `MusicDiscover.cpp` |
| 05-08 | 历史 | 两端一致：本机最近播放 200 首，按当前平台过滤，无更多分页 | 同；数据源与过滤规则一致 | `MusicDiscover.cpp`、`player.history` |
| 05-09 | 歌手页 | 两端一致：热门歌曲 / 发行专辑两个 tab，分页，播放 | 同 | `NativeHudDetail.cpp`、`artistAlbums` |
| 05-10 | 塞壬唱片 | 两端一致：官网目录、分类、检索、播放；无需登录；本地喜欢与自建歌单（`LocalCollections`，存本机） | P1；含本地喜欢/歌单 CRUD | `siren.mjs`、`MusicLibrary::isSiren`、`LocalCollections` |

### 2.6 M06 详情

| ID | 功能项 | 现有行为（iOS / macOS） | 首版目标 | 依据 |
| --- | --- | --- | --- | --- |
| 06-01 | 歌曲详情 | 两端一致：封面、标题、歌手、专辑、时长、音质、播放方式（完整/试听） | 同 | `NativeHudDetail.cpp`、`SongDetailCard.cpp` |
| 06-02 | 歌曲百科 tab | 两端一致：`wiki` 文本，缺省显示「暂无歌曲百科」 | 同 | `wiki` operation |
| 06-03 | 专辑信息 tab | 两端一致：专辑名、歌手、发行日期、简介 | 同 | `body()` |
| 06-04 | 同专辑曲目 tab | 两端一致：最多 6 行视口、滚动、排序、跳播 | 同；排序 P0 | `AlbumTrackRowCount`、`detail-sort` |
| 06-05 | 详情操作 | iOS：播放、下一首、加入队列、加入歌单、喜欢、复制（无官方入口）；macOS 多「官方客户端」 | 与 iOS 相同；官方入口不出现 | `NativeHudDetail.cpp`、`PlatformFeatures.h` |
| 06-06 | 专辑 / 歌单详情 | 两端一致：简介、曲目、播放全部、收藏（provider 支持时） | 同 | `CollectionDetailCard.cpp` |
| 06-07 | 歌手详情 | 两端一致：热门歌曲 / 发行专辑，分页 | 同 | `NativeHudDetail.cpp` |
| 06-08 | 试听 / 音质提示 | 两端一致：返回试听时明确提示；完整播放取决于账号权限 | 同 | `MusicPlayer::trial`、`actualQuality` |

### 2.7 M07 播放

| ID | 功能项 | 现有行为（iOS / macOS） | 首版目标 | 依据 |
| --- | --- | --- | --- | --- |
| 07-01 | 音源解析与播放 | 两端一致：Node 解析 URL，原生播放；正式播放走 `playback`，预览/试听走 `preview`；失败可重试 | Flutter 播放器接直链 | `MusicPlayer::prepare`、`playback`/`preview` |
| 07-02 | 播放 / 暂停 / 上下一首 | 两端一致：App 内按钮与系统控制（iOS 媒体中心 / macOS 媒体键）状态同步 | 同；通知栏、锁屏、耳机线控三处同步 | `PlayerBar.cpp`、`PlatformIOS.mm` |
| 07-03 | 进度与 seek | 两端一致：进度条可拖，试听/不可 seek 时禁用 | 同 | `PlayerBar::State.seekable` |
| 07-04 | 播放模式 | 两端一致：列表循环 / 单曲循环 / 顺序播放 / 随机播放 | 同；四态循环 | `PlayerBar.cpp`、`mode` |
| 07-05 | 音量 | iOS 用系统音量，不显示应用内音量；macOS 有应用内音量 | 用系统音量，不显示滑杆 | `PlatformFeatures.h` |
| 07-06 | 音质选择 | 两端一致：按 provider 提供档位（网易 6 档、QQ 5 档、酷狗 4 档、塞壬 1 档）；切平台时不在新档位内的值按 `prepare` 的 effectiveQuality 规则回退 | 同；切档保留位置 | `MusicPlayer::qualityOptions`、`prepare` |
| 07-07 | 替代音源 | 两端一致：仅网易云可开；音质由来源决定 | 同；文案保留 | `SettingsSchema`、`alternative` |
| 07-08 | 试听与不可用 | 两端一致：无音源、试听、权限不足都有明确提示 | 同 | `MusicPlayer::fail` |
| 07-09 | 播放失败恢复 | 两端一致：失败重试、切歌、恢复播放位置 | 同；有限次退避 | `MusicPlayer::recoverPlayback` |
| 07-10 | 后台 / 通知 / 中断 | iOS 媒体中心 + AVAudioSession；macOS 媒体键 | MediaSession + 前台服务；耳机拔出暂停、来电中断恢复 | `PlatformIOS.mm` |

### 2.8 M08 队列

| ID | 功能项 | 现有行为（iOS / macOS） | 首版目标 | 依据 |
| --- | --- | --- | --- | --- |
| 08-01 | 队列面板 | 两端一致：当前曲目 + 待播列表 + 模式 | 同；竖屏全屏页、横屏弹层 | `PlaybackQueueCard.cpp` |
| 08-02 | 当前曲目标识 | 两端一致：高亮、播放态、封面 | 同 | `PlaybackQueueCard.cpp` |
| 08-03 | 跳播 | 两端一致：点击任意队列项立即播放 | 同 | `queue` action |
| 08-04 | 移除 / 清空待播 | 两端一致：移除单项、清空后续 | 同 | `remove`、`clear` |
| 08-05 | 队列来源替换 | 两端一致：播放单曲/歌单/专辑时按上下文替换队列 | 同；规则写成测试 | `MusicLibrary::play`、`directorySource` |

### 2.9 M09 歌词

| ID | 功能项 | 现有行为（iOS / macOS） | 首版目标 | 依据 |
| --- | --- | --- | --- | --- |
| 09-01 | 歌词页 | 两端一致：播放栏入口进入，封面 + 歌词 | 同 | `NativeHudDetail.cpp` `lyricsMode` |
| 09-02 | 同步滚动 | 两端一致：逐句高亮、自动居中、手动浏览后暂停跟随；有翻译时原文 + 翻译双行，缺失时只显示原文 | 同；翻译行样式与换行按参考实现 | `activeLineIndex`、`NativeHudDetail.cpp` |
| 09-03 | 点击行跳转 | 两端一致：点击歌词行 seek 到该句 | 同 | `lyricsTarget` |
| 09-04 | 偏移校准 | 两端一致：单曲偏移 ±，全局偏移持久化，可重置 | 同 | `LyricsController::offsetMs` |
| 09-05 | 歌词来源 | 两端一致：自动（本地优先）/ 本地 / 网易云 / QQ / 酷狗；选择按曲目记忆 | 保留五项；无本地曲目时「本地」不生效（与 iOS 相同） | `player:lyrics-source`、`m_localSources` |
| 09-06 | 缓存与空态 | 两端一致：歌词缓存，已缓存歌词离线可读；无歌词、纯文本、加载失败有明确状态 | 同 | `LyricsController`、`lyrics-cache` |

### 2.10 M10 设置与偏好

| ID | 功能项 | 现有行为（iOS / macOS） | 首版目标 | 依据 |
| --- | --- | --- | --- | --- |
| 10-01 | 平台卡片 | 两端一致：当前平台、账号、切换入口 | 同 | `NativeHudSettings.cpp` |
| 10-02 | 主题 | 两端一致：亮色 / 暗色 / 跟随系统，即时生效 | 同 | 偏好 `theme` |
| 10-03 | 动态效果 | 两端一致：减少动效（关闭过渡/滚动缓动） | 同 | 偏好 `motion` |
| 10-04 | 初始化动画 | 两端一致：开关 + 手动重播初始化页 | 同 | `startup-animation`、`replay` |
| 10-05 | 唱片旋转 | 两端一致：默认关闭；开启时弹确认（耗电与发热风险），可取消 | 同；确认弹层与文案保留 | `disc-rotation`、`disc-rotation-warning` |
| 10-06 | 右侧遮罩强度 | 两端一致：0–100 步进，主视觉右侧渐变遮罩 | 同 | `archive-mask-strength` |
| 10-07 | 音质 | 两端一致：按 provider 档位 | 同 | `quality` |
| 10-08 | 替代音源 | 两端一致：仅网易云可见 | 同 | `alternative` |
| 10-09 | 进入详情自动播放 | 两端一致：开关 | 同 | `detail-autoplay` |
| 10-10 | 点击播放单曲 | 两端一致：单曲 / 列表两种语义 | 同 | `single-play-mode` |
| 10-11 | 清除缓存 | 两端一致：清元数据/歌词/封面/列表缓存，保留账号与主题；按钮显示结果提示 | 同 | `cache:clear`、`cacheMessage` |
| 10-12 | 恢复默认 | 两端一致：只重置终端偏好 | 同 | `settings:restore-defaults` |
| 10-13 | 关于 / 版本 | 两端一致：版本号、开发版提交标题、「项目与开源参考」静态说明 | 版本与开发版信息 P0；项目链接 P2 | `NativeHudSettings.cpp` |
| 10-14 | 隐藏项 | iOS 不显示官方窗口、桌面歌词、窗口控制；性能/图形设置属性能范围 | 不出现；不保留死入口 | `SettingsSchema`、`PlatformFeatures.h` |

### 2.11 M11 外壳、导航与主视觉

| ID | 功能项 | 现有行为（iOS / macOS） | 首版目标 | 依据 |
| --- | --- | --- | --- | --- |
| 11-01 | 品牌头 / 页脚 | 两端一致：RHINE LAB 标识、资料库名、编号与总量 | 同；字体与字重一致 | `NativeHud::brand`、`footer` |
| 11-02 | 导航 | 两端一致：发现音乐 / 音乐检索 / 我的音乐 / 设置 | 同；竖屏收成图标+短标签 | `NativeHud::navigation` |
| 11-03 | 资料库列表 | 两端一致：编号、标题、歌手、专辑、时长、选中态、滚动 | 同 | `NativeHudLibrary.cpp` |
| 11-04 | 主视觉 | 两端一致：封面、唱片、光盘盒、右侧遮罩、旋转/换页动效 | **真实 3D**，同一 GLB/相机/动效；引擎由 M0.5 在 A/B 中定；**仅 Vulkan**，无 Vulkan 显示「3D 不可用」，OpenGL 只留接口；禁止 2D 贴图替代 | `Assets/android-3d/*.glb`、`scene-fixture.json` |
| 11-05 | 封面查看页 | 两端一致：从主视觉/播放栏封面进入；正面/背面、单指旋转、双指缩放、双指平移 | 同；P1 | `Overlay.qml`、`NativeViewer.cpp` |
| 11-06 | 播放栏 | 两端一致：封面、标题、歌手、进度、控制、模式、队列、歌词、喜欢 | 同；竖屏紧凑、横屏完整 | `PlayerBar.cpp` |
| 11-07 | 弹层体系 | 两端一致：居中卡片、遮罩、进入/退出动效、ESC/返回关闭 | 同；竖屏改全屏 sheet | `NativeHudModal.cpp` |
| 11-08 | 主题与字体 | 两端一致：亮/暗/系统；MiSans 四字重 + 符号字体 | 同；字体随包 | `Assets/fonts/` |
| 11-09 | 竖屏布局 | iOS 不支持竖屏；macOS 仅窗口缩放 | 新增：单列、顶部导航、底部播放栏、全屏子页 | 本计划 §3.5 |
| 11-10 | 横屏布局 | 两端一致：左索引 + 右舞台/详情 | 同；按高度缩放，夹在 0.75–1.25 | 本计划 §3.5 |
| 11-11 | 目录导航 | 两端一致：搜索结果 → 专辑/歌单/歌手 → 曲目，逐级可返回；返回保持上一级滚动位置与选中项 | 同；返回栈与状态保留写成测试 | `MusicDirectory`、`NativeHudMusic.cpp` |

### 2.12 M12 数据、缓存与安全

| ID | 功能项 | 现有行为（iOS / macOS） | 首版目标 | 依据 |
| --- | --- | --- | --- | --- |
| 12-01 | 偏好持久化 | 两端一致：主题、音质、模式、各开关；音量仅 macOS 有 | 同；iOS 侧无音量项，Android 同；类型化 SettingsStore | `Host` 偏好键 |
| 12-02 | 内部记录 | 两端一致：检索记录最多 12 条，只持久化、**没有 UI**；最近播放最多 200 首，在发现页「历史」tab 展示；清缓存清检索记录，退出登录清最近播放；歌词全局偏移持久化 | 同 | `search-history`、`play-history` |
| 12-03 | 凭据 | 两端一致：Keychain；按 provider/酷狗版本隔离 | Keystore 加密；不落明文、不进日志 | `PlatformIOS.mm`、`Host` |
| 12-04 | 缓存 | 两端一致：封面、歌词、元数据、列表缓存 | 文件 LRU；可统计、可清理 | `Host` 缓存、`lyrics-cache` |
| 12-05 | 清除缓存 | 两端一致：保留账号、主题与偏好 | 同 | `cache:clear` |
| 12-06 | 无遥测 | 两端一致：无分析 SDK、无自建收集服务器 | 保持：不接 Firebase/Crashlytics/Sentry，不埋点上报 | `README.md` 隐私说明 |

---

## 3. 技术方案

### 3.1 分层

```text
Flutter (Dart)
  UI          shell / pages / modals / components
  State       session · browse · player · lyrics · settings
  Gateway     MusicGateway（22 个适配 operation + 原始路由通道，JSON lines）
        │  127.0.0.1 随机端口 + 随机令牌
Kotlin / JNI
  NodeHost    资源解压 · System.loadLibrary("node") · pthread(8 MB) · node::Start
Node（不修改业务代码）
  ios-runtime.cjs · worker.cjs · client/*.mjs · upstream/*
Audio（Dart）
  just_audio + audio_service + audio_session
```

### 3.2 桥接：复用现有 Node Worker

- **复用 `MusicBridge/ios-runtime.cjs`**：它已经同时服务于 iOS 与 Qt Android，参数为端口与令牌，消息为 `start / input / stop`，Worker 串行重建。Flutter 不再写第二套运行时协议。
- **连接方向**：Dart 先 `ServerSocket.bind(127.0.0.1, 0)`，把端口与随机令牌经 MethodChannel 交给 `NodeHost`；Node 的 `ios-runtime.cjs` 主动连接并把令牌作为首条消息——与 Qt 的 `QTcpServer` 方向一致，**不要反过来让 Dart 去连 Node**。
- **新增 `android/app/src/main/cpp/nodehost.cpp`**：JNI 入口 → 创建 8 MB 栈的 pthread → `node::Start(4, argv)`；argv 为 `node`、`ios-runtime.cjs`、端口、令牌。实现可逐条对照 `BridgeProcessAndroid.cpp`，包括「argv 生命周期覆盖整个运行时」「退出码写 logcat」。
- **资源**：用 `scripts/bundle-bridge.cjs` 以 `RHINE_ANDROID_BUILD=1` 打出单文件 `worker.cjs`（约 14 MB）+ `xhr-sync-worker.js` + `upstream/`，并复制 `ios-runtime.cjs` 与 `data/china_ip_ranges.txt`，整包约 20 MB；发布包不再携带 `node_modules`（避免原始 85 MB 依赖）。产物目录保持 `MusicBridge/` 与 `data/` 同级（worker 里用 `__dirname/../data`），复制到 `filesDir/node/`，带版本戳；首启用初始化页显示解压进度。
- **Worker 环境**：`start` 消息必须带 `env`：`TMPDIR`（应用可写的缓存目录）、`RHINE_QQ_DEVICE_STATE_PATH`、`RHINE_KUGOU_DEVICE_STATE_PATH`、`RHINE_KUGOU_EDITION`——与 `BridgeProcessAndroid.cpp` 一致。缺了这些，临时文件会落到不可写目录，QQ/酷狗的设备身份也会每次重建。
- **协议**：每行一个 JSON。两条通道都必须实现：
  - **适配 operation**：`route: "/native/<provider>/<operation>"`，`params: { args: [...] }`；`body.value` 是适配后的业务值（对应 `MusicApi::send` 的 `adapted=true`）。
  - **原始路由**：`route: "/<path>"`（QQ/酷狗自动加 `/<provider>` 前缀，与 `MusicApi::request` 一致），`params` 直接透传；响应取整个 `body`。三块已知用途：登录（`/login/qr/key`、`/login/qr/create`、`/login/qr/check`、`/login/qr/cancel`、`/login/cellphone`、`/captcha/sent`）、**网易云发现页**（`/personalized`、`/recommend/songs`、`/toplist`、`/album/newest`、`/top/playlist`、`/playlist/catlist`、`/artist/sublist`）、**非 QQ 的写操作**（`/like`、`/playlist/create`、`/playlist/name/update`、`/playlist/delete`、`/playlist/tracks`、`/playlist/subscribe`、`/album/sub`、`/artist/sub`）——这些 22 个 operation 覆盖不到；QQ 的写操作才走 `mutate`。
  - 错误统一读 `body.code` / `body.message` / `body.authExpired`；`_epoch`、`_credentialKey` 只做隔离，不作为业务字段。原始路由要支持**每路由的允许状态码集合**：例如扫码 check 的 800/801/802/803 都是正常状态，不能当失败。
  - **合计约 43 条路由**（22 适配 + 21 原始）。只实现 22 个 operation 会导致登录、网易云发现页和非 QQ 写操作全部不可用。
- **Cookie 与凭据**：Dart 侧按 provider 维护 cookie jar；酷狗按 `standard/lite` 分开；响应里的 `kugouCredentials` + `_credentialKey` 要按版本保存（对应 Qt 的 `privateCredentials`），下次请求带上该版本的 `__kugou` cookie；QQ 的 `qqSessions` 存进 cookie jar 的 `__qqSessions` 键（对应 `Host.cpp` 的处理）。凭据整体用 Keystore 加密后落盘，请求时解出并随 `cookies` 带上。
- **不修改** `worker.cjs`、`client/*.mjs`、`upstream/*`；只在打包时注入已有的 `android-web-apis.cjs`。

### 3.3 播放

- `just_audio`（ExoPlayer）+ `audio_service`（前台服务 + MediaSession）+ `audio_session`（音频焦点/中断）。
- 不实现桌面版的独立播放服务（`PlaybackConnection`）：iOS 本来就是应用进程内播放，Android 与 iOS 对齐。
- Node 只负责解析 URL；Dart 播放器只吃 HTTP(S) 直链。**真机播放验证只验网易云公开曲目**：若网易云要求 `Referer`/`User-Agent`/Cookie，先用 `AudioSource.uri(headers:)`；仍失败则引入 `media_kit`（libmpv）作为回退，**M0 定案**。**QQ/酷狗不做任何真机测试**（登录、写操作、播放都一样），播放代码仍实现，但只用 fixture/静态检查覆盖，不验音质与替代源。
- 后台：`AudioService` 前台服务，Android 13+ 请求 `POST_NOTIFICATIONS`；拒绝时播放不崩，仅通知不可见。
- **后台续播的 URL 解析归属**：Android 上 UI isolate 可能被暂停，不能在「上一首结束」时依赖 UI 再向 Node 要地址。M0 先测「锁屏 + 队列自动续播」；若主 isolate 不能稳定跑，改用「队列前预取未来 1–2 首 URL」或把队列状态机放进 audio handler 所在 isolate（通过平台通道向主 isolate 要 URL）。此项必须在 M4 前定案。
- 中断：来电、耳机拔出、蓝牙断连、音频焦点丢失按 iOS 的 `AVAudioSession` 语义处理（暂停/恢复/降低音量）。
- 不实现应用内音量；音量键与系统音量面板直接作用。

### 3.4 状态与持久化

- 单一状态源：`SessionController`（平台/账号）、`BrowseController`（检索/目录/发现）、`PlayerController`（队列/当前/进度）、`LyricsController`、`SettingsController`。UI 只读状态、只发意图。
- 播放器状态由 `AudioHandler` 的流回灌，避免「UI 自己计时」与真实播放位置漂移。
- 持久化：偏好 `shared_preferences`；历史/会话 JSON 文件；凭据 `flutter_secure_storage`；缓存文件 LRU。
- 会话快照字段与 Qt 对齐：`provider / edition / uid / current / queue / index / mode / position / requested / preview / browse`。

### 3.5 响应式布局

- 设计基准是「1080 高、宽度弹性」的舞台：Qt 的 `stageWidth = width / (height / 1080)`，手机横屏会比 1920 更宽。横屏取 `s = clamp(h / 1080, 0.75, 1.25)` 作为字号/间距缩放，布局宽度按 `w / s` 的设计单位计算；**不要把 1920 当固定宽度**。竖屏不强行缩放，使用独立的竖屏令牌。
- 断点：`compact < 600`、`medium 600–839`、`expanded ≥ 840`（最短边）；结合 `orientation` 选布局。
- 竖屏：单列；顶部品牌 + 导航；内容滚动；底部播放栏；检索/我的/队列/设置/详情为全屏页；弹层改 bottom sheet 或全屏。
- 横屏：左侧索引 38–42%，右侧舞台/详情；播放栏底部；弹层居中卡片。
- 平板竖屏：保持两栏（1 : 1.4），不塌成单列。
- 键盘：`resizeToAvoidBottomInset` + 结果列表滚动到底；横屏输入时仍能看到至少 3 行结果。

### 3.6 表现层与 3D 对齐边界

**必须对齐：** 页面层级、信息顺序、相对位置与比例、字号字重、主色与强调色、动效时长与缓动、过场顺序、加载/空/错状态；3D 的几何、相机、构图、遮挡关系、旋转/换页时序与材质呈现。

**3D 的硬要求：**

- 直接使用现有 `Assets/android-3d/archive-assembly.glb`、`archive-cassette.glb` 与 `scene-fixture.json`、`slots.json`，不重新建模、不换相机。
- 复现同一相机 FOV/位置、光盘旋转曲线、封面/盒体变换、右侧遮罩、封面查看页正反面、列表/详情/歌词页的过场。
- **禁止**用预烘 PNG、2D `Transform`、视频或截面贴图替代 3D。发现即判定不通过。

**引擎选择（M0.5 在 A/B 之间定；首版仅 Vulkan，OpenGL 只留接口）**

| 路线 | 接口/包 | 说明 | 限制 |
| --- | --- | --- | --- |
| **首选：Flutter GPU / Vulkan** | `flutter_gpu`（SDK 内置）+ `flutter_scene` | 纯 Dart + GLSL，Impeller/Vulkan；glTF、PBR、IBL、阴影、后处理；`SceneView` 直接进 Flutter 合成树，无 PlatformView；支持 `.fmat` 自定义材质 | 预览阶段；Android 仅 Vulkan；中低端机帧率需实测 |
| 备选 A：Flutter GPU / Vulkan | `just_graphics_engine` / `glint_engine` / `flutter3d` | 同为 Flutter GPU 系，glTF/PBR/阴影/动画；可作为 `flutter_scene` 不达阈值时的替代 | 各自成熟度不同；API 可能变 |
| 接口预留（首版不实现） | `SceneBackend` 的 GLES 实现点（§3.11） | 只定义抽象与「不可用」返回；不引入 `three_js`/`flutter_gl`，不写渲染代码 | 不验证、不验收；后续要覆盖非 Vulkan 设备须重走 M0.5 保真度验证 |
| 不采用 | Qt `RhiScene`/shader 移植 | 违背「优先 Flutter 生态」 | 不做；A/B 全不达标时按 §1.6 #15 暂停 3D 部分，不以此兜底 |

**Android 启用方式：**

- `AndroidManifest.xml` 的 `<application>` 内加：
  `<meta-data android:name="io.flutter.embedding.android.EnableFlutterGPU" android:value="true" />`
- 强制 Vulkan：`ImpellerBackend=vulkan`（manifest meta-data 或启动参数），并在 release 构建验证。**Vulkan 是首版唯一的 3D 后端**；Flutter GPU 在 Android 的 GLES 路径很慢/有挂起问题（flutter/flutter#177873），这也是本次不启用 GLES 的原因。
- `flutter run` 调试可用 `--enable-impeller --enable-flutter-gpu`；release 必须靠 manifest 固化，不能依赖命令行。

**设备范围（已定，不再由 M0.5 决策）：** 仅带可用 Vulkan 的设备渲染 3D。无 Vulkan 时 `SceneBackend` 返回 unsupported，主视觉区域明确显示「3D 不可用」，其余功能照常可用；**不切换 GLES、不静默降级 2D、不弹「正在降级」提示**。OpenGL ES 只保留 §3.11 的接口，供后续接入。

**效果基准与性能记录（已定）：** 阴影、IBL、材质、动效一律以 Qt 版为准，首版不削减任何效果。`flutter_scene` 在 Android 中低端机上复杂场景可能只有 5–40 fps；M0.5 只把 p50/p95 帧间隔与长帧**记录为数据**，卡顿不作为改画面或削效果的理由。优化方向由你人工测试后另行给出；在此之前不擅自调参、不换画质档。

**3D 验收阈值：**

1. 在带 Vulkan 的目标设备上，六个状态（资料库静置、切歌、进详情、歌词页、封面正面、封面背面）与 iOS/macOS 并排截图；
2. 几何、构图、遮挡、动效时序一致；不允许“看起来差不多”；
3. 光盘/盒体关键区域 **ΔE2000 ≤ 3**，且 **SSIM ≥ 0.97**；
4. 连续旋转/切页 60 秒无崩溃、无明显卡顿（不设 FPS 指标，但不能肉眼可见地抖）；**效果以 Qt 版为准，不因流畅削减**，帧率只记录、不作为判定项；
5. 允许的差异仅限：抗锯齿方式、驱动导致的 ±1 像素边缘、色调映射实现差异（仍须在阈值内）。

**UI 判定方式：** 7 个关键页面（资料库、详情、歌词、发现、检索、队列、设置）截图并排走查，人工评审；UI 不做逐像素 diff。**3D 不走人工「差不多」判定**，单独按上面的 ΔE2000 / SSIM 阈值量化，材质与几何超出阈值即判缺陷。

**启动动画：** 复用 `NativeHudBoot.cpp` 里的轮廓路径数据，用 `CustomPainter` 按弧长截取，保持描边时序。

### 3.7 Android 集成清单（M0 必做）

| 项 | 结论/动作 |
| --- | --- |
| `minSdk` | 24（`flutter_secure_storage` 的 Keystore 路径与 `audio_service` 的现代 API 都需要；不要依赖 `flutter.minSdkVersion` 的默认值） |
| 权限 | `INTERNET`、`ACCESS_NETWORK_STATE`、`POST_NOTIFICATIONS`、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_MEDIA_PLAYBACK`、`WAKE_LOCK` |
| 备份 | `android:allowBackup="false"`；Keystore 密钥不随备份迁移，恢复后无法解密旧凭据 |
| 明文流量 | M0 **只记录网易云**返回 URL 的 scheme（真机）；QQ/酷狗仅按 fixture/静态检查记录，不做真机测试。若有 `http://`，优先改 `https://`，否则用域名级 network security config 或 `media_kit`（libmpv 不走 Android 的明文策略） |
| 原生库 | `libnode.so` 放 `jniLibs/<abi>/`，按 `android-source.json` 校验 SHA；`readelf -d` 确认 `NEEDED` 全部随包。若 `System.loadLibrary` 报找不到，检查 `extractNativeLibs` / `useLegacyPackaging`，再复测 16 KB 对齐 |
| NDK 构建 | `externalNativeBuild` 只编 `nodehost`（CMake），链接 `libnode`；不要在 Flutter 插件里再编一份 Node |
| 打包 | `bundle-bridge.cjs`（`RHINE_ANDROID_BUILD=1`）产物 + `ios-runtime.cjs` + `data/`，首启解压到 `filesDir/node/` |
| 签名 | **不会自动使用自定义签名**。当前 `android/app/build.gradle.kts` 的 release 也指向 `signingConfigs.debug`；除非显式加 `signingConfigs.release` + `key.properties`，Gradle 不会去读任何自定义 keystore。本次不改签名逻辑；继续 `rhine.music.database`，安装前卸载 Qt 版（同包名 + debug 签名无法覆盖 release 版），不做旧数据迁移；debug 签名只用于内部安装 |
| 3D 启用 | `<application>` 内加 `io.flutter.embedding.android.EnableFlutterGPU=true`；强制 Vulkan（`ImpellerBackend=vulkan`）；release 构建必须实测，不依赖 `flutter run` 命令行 |
| Vulkan 要求 | **首版唯一 3D 后端**。无可用 Vulkan 的设备由 `SceneBackend` 返回 unsupported，明确显示「3D 不可用」；不切 GLES、不用 2D 冒充；其余功能照常 |
| OpenGL ES 接口预留 | 只定义 `SceneBackend` 的 GLES 实现点（§3.11）；首版不引入 `three_js`/`flutter_gl`、不实现、不验证、不验收；后续启用须重走 M0.5 |
| 旧数据 | **不处理**：不扫描、不迁移、不清理 Qt 版 data；卸载 Qt 版即由系统删除；首启按全新区安装处理 |
| 方向 | 不写 `android:screenOrientation`，不调 `setPreferredOrientations`；`configChanges` 保持现有脚手架 |
| 系统栏 | edge-to-edge；亮/暗主题切换时同步状态栏与导航栏图标对比度，横屏不留黑边 |
| 通知 | Android 13+ 首次播放时请求权限；拒绝不阻塞播放 |

### 3.8 Flutter 实现取向（不复刻 Qt 内部结构）

产品行为对齐，不等于实现方式照搬。以下 Qt 机制**不要**搬进 Flutter：

- `NativeHud` 的命令流（`commands/hits`）与 `Hud::updatePaintNode` 脏区重绘——这是 Qt 的渲染约束，不是产品行为；
- `Glyphs` 的宽度缓存、run-path / mask 渐变缓存；
- `QQuickRenderControl` 两层离屏窗口、`PresentationShell` 的 step 泵；
- 用 `CustomPainter` 把整页画成一张画布。

用 Flutter 的方式重写：

| 领域 | 建议 |
| --- | --- |
| 状态 | Riverpod（或等价）+ `freezed`/`json_serializable` 生成不可变模型；`AsyncValue` 统一加载/错误 |
| 导航 | `Navigator` 2.0 的强类型路由 + `PopScope`；弹层用 `showModalBottomSheet`/全屏 `PageRoute`，不用手写 z-order |
| 列表 | `CustomScrollView` + `SliverList.builder`；分页用 `ScrollController`/`AsyncNotifier`；不整页重建 |
| 主题 | `ThemeExtension` 承载 Rhine 令牌；`ColorScheme` + `ThemeMode.system`；状态栏图标随亮暗切换 |
| 动画 | `AnimationController`/`TweenSequence`/隐式动画；统一读 `MediaQuery.disableAnimations`，不在每个页面各写一套 |
| 文本 | `TextPainter` 做 fit/省略；歌词用 `Text.rich` 双行；不实现 Qt 的字形命令缓存 |
| 图片 | `cached_network_image` + `memCacheWidth`；预取下一首封面；缓存目录接 `path_provider` |
| 音频 | `just_audio` + `audio_service` + `audio_session`（见 §3.3） |
| 存储 | `shared_preferences`（偏好）、`path_provider` + JSON（会话/本地集合）、`flutter_secure_storage`（凭据） |
| 测试 | `flutter_test` + `mocktail` + golden；关键闭环用 `integration_test` |
| 3D | `flutter_scene` 的 `SceneView` 直接进 Flutter 合成树（无 PlatformView）；UI 只依赖 `SceneBackend`（§3.11），只做 UI 叠加、手势转发与生命周期；GLES 仅接口预留，首版不实现 |
| 插件 | 允许使用精选插件改善体验（见下方策略） |

**必须保持一致的是**信息层级、交互结果、状态机、视觉比例、动效时序；实现细节可以不同。

**插件策略（允许用，但不乱用）：**

- 只接维护活跃、许可证兼容、无遥测/无自建上报的包；版本锁定在 `pubspec.lock`，升级前跑一遍回归。
- 首选：`flutter_scene`（3D）、`just_audio`/`audio_service`/`audio_session`（播放）、`cached_network_image`（封面）、`flutter_secure_storage`（凭据）、`shared_preferences`/`path_provider`（存储）、`freezed`/`json_serializable`（模型）、`mocktail`/`golden_toolkit`（测试）。
- 不接：会改包名/签名、引入第二套遥测、与 `libnode`/3D 原生库冲突、或长期不维护的包。
- 每个插件在 M1 的依赖审计里登记：用途、许可证、最近更新时间、是否含原生代码、是否能被替换。

### 3.9 本地音乐扩展点（首版不做，接口预留）

只定义抽象，不写实现、不显示入口、不申请权限：

```dart
abstract interface class LibrarySource {
  String get id;                 // netease / qq / kugou / siren / local
  bool get requiresLogin;
  Future<SearchPage> search(SearchQuery query);
  Future<Track> track(String id);
  Future<PlaybackSource> playback(Track track, String quality);
  Future<LyricsDocument?> lyrics(Track track, String? source);
}

/// 首版返回 Disabled；接入本地音乐时再实现导入/扫描/标签/封面/LRC。
final class LocalLibrarySource implements LibrarySource {
  @override
  String get id => 'local';
  @override
  bool get requiresLogin => false;
  // ... 全部抛 UnsupportedError 或返回空页
}
```

- `Provider` 枚举保留 `local`，但 `PlatformFeatures.localMusic = false`；provider 列表不渲染 local；
- `switchProvider('local')` 返回「当前版本不支持本地音乐」，不进入半初始化状态；
- 本地索引/标签解析/封面/LRC/文件权限都不在首版实现；后续接入时只补 `LocalLibrarySource` 与文件选择 UI，不改其它模块。

### 3.10 更新检查扩展点（首版不做，接口预留）

只定义抽象，不写 UI、不发网络请求：

```dart
abstract interface class UpdateService {
  Future<UpdateInfo?> check();
  Future<void> openReleasePage();
}

/// 首版：永远返回 null，打开链接为 no-op；设置页不显示「检查更新」。
final class DisabledUpdateService implements UpdateService {
  @override
  Future<UpdateInfo?> check() async => null;
  @override
  Future<void> openReleasePage() async {}
}
```

- `UpdateService` 作为依赖注入，后续接入 GitHub Releases 时只换实现；
- 首版不显示更新入口、不请求 GitHub、不写入 `auto-update` 偏好；
- `AppUpdater` 的版本检查逻辑不移植。

### 3.11 OpenGL ES 接口预留（首版不实现，仅 Vulkan）

首版只走 Vulkan，但把后端选择隔离在一个接口后面：后续若要覆盖非 Vulkan 设备，只需补一个实现并重走 M0.5，不改 UI 与状态层。

```dart
enum SceneBackendKind { vulkan, gles }

abstract interface class SceneBackend {
  SceneBackendKind get kind;
  /// 设备/驱动是否可用；不可用时 UI 显示「3D 不可用」，不尝试其它后端。
  Future<bool> isAvailable();
  Future<void> load(SceneFixture fixture);   // 同一 GLB / slots / 相机参数
  Widget build(SceneState state);            // 交给合成树，不做 2D 兜底
  void dispose();
}

/// 首版唯一实现：Flutter GPU / Impeller / Vulkan。
final class VulkanSceneBackend implements SceneBackend { /* flutter_scene */ }

/// 只留扩展点：不引入 three_js/flutter_gl、不写渲染代码、不注册进 provider。
final class GlesSceneBackend implements SceneBackend {
  @override
  SceneBackendKind get kind => SceneBackendKind.gles;
  @override
  Future<bool> isAvailable() async => false;   // 首版恒为不可用
  // 其余方法抛 UnimplementedError
}
```

- `SceneBackendProvider` 只注册 `VulkanSceneBackend`；`isAvailable() == false` 时返回 `SceneUnavailable`，主视觉区域显示「3D 不可用」占位，其余页面与播放功能照常可用。
- 不注册 GLES 后端、不自动探测 GLES、不在无 Vulkan 设备上尝试 `Texture`/PlatformView 回退；`SceneUnavailable` 不是 2D 贴图，也不弹「正在降级」提示。
- 后续启用 GLES 时：补 `GlesSceneBackend`（可用 `three_js`+`flutter_gl`）、注册进 provider，并重走 M0.5 六状态的 ΔE2000 / SSIM 验证。Flutter 3.47 的 GLES render-to-texture 改为 top-down，需先验证 Y 翻转与 FBO 方向。

---

## 4. 分阶段实施计划

### 依赖关系

```text
M0 ─┬─> M0.5 ────────────────┐
    ├─> M1 ──┬─> M3 ─────────┤
    └─> M2 ──┴─> M4 ─────────┴─> M5 ─> M6
```

- M0.5（3D 保真度）、M1、M2 可在 M0 之后并行；
- M3 与 M4 可在 M1+M2 之后并行（两名开发者时）；
- M5 依赖 M3、M4 的状态与页面骨架，以及 M0.5 选定的 3D 引擎；
- M6 是独立验收阶段，不写新功能。
- 若 M0.5 判定 A/B 全不达标，按 §1.6 #15 **暂停 3D 部分**：M5 主视觉接入与 V-23 挂起，其余模块继续，整体不宣告「对齐完成」。

### M0 技术验证与骨架（Gate 0）

**范围**

- 替换 Flutter 模板；装入 `RhineMiSans` 四字重与 `NotoSansSymbols2`；建立颜色/字号/间距令牌。
  - 脚手架现状：仓库根已完成 `flutter create --platforms=android`，包名 `rhine.music.database`、五套图标、应用名、阿里云 Gradle 镜像都在；直接在其上继续，不重新 create，并移除模板的 counter 测试。
- `nodehost.cpp` + Kotlin `NodeHost` + 资源解压 + 回环握手；Dart `MusicGateway` 最小实现（search / detail / playback；`capabilities` 仅在支持的 provider 上验）。
- 播放器最小闭环：解析 → `just_audio` 播放 → 暂停/seek；`audio_service` 最小前台服务 + MediaSession（用来验证后台续播，不做完整通知样式）。
- 音源验证：**只验网易云公开曲目**；QQ/酷狗**不做任何真机测试**（登录/写操作/播放均只用 fixture 与静态检查，实现保留）。
- 应用骨架：竖屏单列 / 横屏两栏各一页；播放栏占位；方向跟随系统。
- Android 集成：`minSdk 24`；`INTERNET`、`ACCESS_NETWORK_STATE`、`POST_NOTIFICATIONS`、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_MEDIA_PLAYBACK`、`WAKE_LOCK`；`android:allowBackup="false"`（Keystore 加密数据不能跨设备恢复）；不写 `screenOrientation`。
- `libnode.so` 按 `vendor/nodejs-mobile/android-source.json` 固定版本放进 `jniLibs/<abi>/`，`readelf -d` 核对 `NEEDED`（`libc++_shared.so` 等随包补齐）；`externalNativeBuild` 只编 `nodehost`。
- 3D 启用：manifest 加 `io.flutter.embedding.android.EnableFlutterGPU=true` 与 Vulkan 后端；**首版仅 Vulkan**，无 Vulkan 由 `SceneBackend` 返回 unsupported 并显示「3D 不可用」；OpenGL 只留接口（§3.11）。具体保真度在 M0.5 验。
- 签名与包名：**不改**。继续 `rhine.music.database`，沿用脚手架现有签名配置（debug），不新增/修改 keystore；**不会自动读取自定义签名**；安装前卸载 Qt 版，不迁移旧数据。

**依赖：** 无。

**退出标准（1–6 必须满足）**

1. 真机 arm64 能安装并冷启动到首页：首启（含 20 MB 解压）≤ 10 s，后续 ≤ 5 s（中端机）；无 native crash、无 JNI abort；安装前已卸载 Qt 版，首启按全新区处理（不做旧数据迁移）。
2. 解压完成后 Node 握手 ≤ 3 s；`/native/netease/search` 返回 ≥ 20 条；Worker stderr 能在 logcat 看到。
3. 网易云至少一首可播放 ≥ 30 s；暂停、继续、seek 可用；锁屏/通知出现媒体控制。QQ/酷狗不做真机测试。
4. 锁屏状态下让队列自动续播至少 2 首（验证后台仍能解析下一首 URL）；这是后台架构的判定点。
5. 冷启动竖屏保持竖屏、横屏保持横屏；旋转 10 次不崩、不中断播放。
6. Android 15 16 KB 页模拟器能加载 libnode；若不能，给出「仅 4 KB 设备」或「重编 libnode」的明确结论。

**失败处置：** 第 6 条失败 → 用 nodejs-mobile 源码重编 `libnode.so`（`-Wl,-z,max-page-size=16384`）或改用更新版本；网易云若不能直链播放 → 先试 `just_audio` headers，再试 `media_kit`，不带着未知进入 M4。

> 构建与安装由你执行；本阶段只交代码与验证清单，不自动跑构建。

### M0.5 3D 保真度验证（Gate 0.5）

**范围**

- 用同一套 `Assets/android-3d/*.glb` 与 `scene-fixture.json` / `slots.json`，在候选引擎上复现 6 个状态：资料库静置、切歌、进详情、歌词页、封面正面、封面背面。
- 候选 A（首选）：`flutter_scene`（Flutter GPU / Impeller / Android Vulkan）。
- 候选 B：`just_graphics_engine` / `glint_engine` / `flutter3d`（同为 Flutter GPU 系）。
- **OpenGL ES 不纳入本阶段验证**：首版只留 `SceneBackend` 接口（§3.11），不引入 `three_js`/`flutter_gl`、不参与保真度比对。
- **不做** Qt `RhiScene`/shader 移植；A/B 全不达阈值时按 §1.6 #15 暂停 3D 部分，不用它兜底。
- 相机、光盘旋转、封面/盒体变换、遮罩、过场都从现有场景数据取值，不调参“调得像”。
- 与 iOS/macOS 同状态并排截图；记录 ΔE2000 / SSIM、帧率/长帧、内存。**效果以 Qt 版为准，首版不削减**；帧率只作数据记录。
- 同时验证：debug 与 **release** 构建都能启用 Flutter GPU；强制 Vulkan 的 manifest 配置生效；无 Vulkan 设备明确显示「3D 不可用」。

**依赖：** M0（设备、资源、构建链）；可与 M1/M2 并行。

**退出标准**

1. 真实 3D，无任何 2D 贴图/预烘图/视频替代。
2. 6 个状态并排：几何、构图、遮挡、动效时序一致；关键区域 ΔE2000 ≤ 3 且 SSIM ≥ 0.97。
3. 连续旋转/切页 60 秒无崩溃；目标真机无明显卡顿（只记录 p50/p95 帧间隔）。**效果以 Qt 版为标准，首版不削减任何效果**；卡顿只记数据，优化方向等你人工测试后再给。
4. 在 A/B 中选定 Flutter GPU 引擎并写入计划；后端固定 **Vulkan**（唯一路径）；release 构建实测通过。
5. 输入转发（单指旋转、双指缩放/平移）在 3D 层验证一次，交互语义与 §11-05 一致。
6. 无 Vulkan 设备：明确显示「3D 不可用」，其余功能照常；不切 GLES、不静默 2D。

**失败处置：** A、B 两个 Flutter GPU 候选均不达 §3.6 阈值 → **暂停 3D 部分**：M0.5 结论挂起、M5 的主视觉接入与 V-23 暂停，其余模块（M1–M4、M6 的非 3D 部分）继续，但整体**不宣告「对齐完成」**；不移植 Qt、不启用 GLES 接口、不降 2D、不擅自改画面或重定范围。等你人工测试后给出方向，再恢复 M0.5。

### M1 领域层与会话持久化（Gate 1）

**范围**

- 数据模型：`Provider / Account / Track / Album / Playlist / Artist / LyricDocument / QueueItem / SessionSnapshot`。
- `LibrarySource` 抽象 + `LocalLibrarySource` 空实现（§3.9）：provider 枚举保留 local，但首版不可达、无 UI、无权限。
- `MusicGateway` 全量 22 个 operation + 原始路由通道（登录、网易云发现、非 QQ 写操作必需）；请求 id、超时、取消、代数隔离；cookie jar；酷狗凭据；错误分类（网络 / 鉴权过期 / 地区 / 试听 / 限流 / 风控 / 上游格式）。
- `BridgeWatchdog`：Worker 退出、握手断开或请求超时 → 失败在途请求；runtime 线程仍在时重启 Worker 会话；runtime 已退出时进入不可恢复错误页并提示重启应用（libnode 不支持同进程二次 `node::Start`，不要假装能热重启整个运行时）。
- 请求去重与路由 TTL：对齐 `Host::lifetime` 的短/长生命周期，只用于防抖、防重复请求与风控，不作为性能目标。
- 仓储：Account / Search / Library / Discover / Detail / Playback / Lyrics。
- 持久化：SettingsStore、HistoryStore、SessionStore、CredentialStore、CacheStore（LRU）。
- 单元测试：用录制的 fixture 回放，不依赖真实账号。

**依赖：** M0。

**退出标准**

1. 22 个 operation 与原始路由通道均有类型化封装；登录路由（网易云六条 + QQ/酷狗各自路由）、网易云发现页七条、非 QQ 写操作八条的 fixture 解析全部通过。
2. 取消/超时/乱序响应不改变当前账号与播放状态（代数隔离测试）。
3. 杀进程重启恢复 `provider / edition / uid / current / queue / index / mode / position / requested / preview / browse`。
4. 账号 A/B 切换不串数据；凭据文件中无明文 cookie/token。
5. 缓存命中、失效、清理有日志与测试；清除缓存不影响账号与主题。
6. 人为杀掉 Worker：runtime 仍活时 10 秒内重建会话；runtime 退出时给出不可恢复错误页与重启提示，在途请求得到明确错误，不出现永久转圈。
7. `switchProvider('local')` 返回「当前版本不支持本地音乐」；provider 列表不出现本地；`LocalLibrarySource` 有单测，确认不会触发文件扫描/权限申请。

### M2 设计系统与响应式外壳（Gate 2）

**范围**

- 令牌：颜色（亮/暗）、字号、字重、间距、圆角、边框、动效曲线与时长。
- 组件：TopBar、NavBar、ListRow、TabBar、PlayerBar、ModalSheet、Confirm、Toast、Empty/Error/Loading、IconButton、Progress。
- 外壳：竖屏单列、横屏两栏、平板两栏；弹层栈与返回键；页面转场。
- 方向：`MediaQuery` 监听、SafeArea、边到边、键盘避让。

**依赖：** M0（可与 M1 并行）。

**退出标准**

1. 7 个尺寸（320×480 / 360×800 / 411×891 / 800×360 / 891×411 / 1024×768 / 1280×800）× 2 主题的 golden 测试通过，无 overflow、无裁切；golden 在固定 CI 环境生成与比对，避免字体渲染差异。
2. 触摸目标 ≥ 48 dp；正文对比度 ≥ 4.5:1。
3. 旋转保持导航位置、滚动位置、已打开的弹层与输入内容。
4. 竖屏 320×480 不溢出；横屏 800×360 播放栏 + 内容不重叠。
5. 四字重字体离线可用，缺字回退到符号字体。

### M3 账号、检索与个人库（Gate 3）

**范围**

- 平台切换、账号卡片、登录接口与状态机（网易云扫码/短信、QQ 扫码/微信、酷狗双版本）、退出与隔离。
  - **UI 最小可用即可**：二维码/验证码/倒计时/错误文案；不做账号管理、设备管理、花式动效等扩展。
  - **登录验证范围**：六种方式的接口与状态机全做；**真机只在网易云扫码/短信各最多 2 次**（成功一次即够）；**QQ 扫码/微信、酷狗标准/概念四种不做真机测试**，失败/取消/过期/冷却全部用 fixture 覆盖。不做「退出→再登录」循环。
- 检索：输入、四类 tab、分页、结果行操作；不新增历史/建议 UI（参考实现没有）。
- 个人库：喜欢、收藏、自建歌单 CRUD、加歌/移歌、红心同步、排序/分组、分页；QQ 写操作走 `mutate`，网易云/酷狗走原始写路由（与 `MusicMutation.cpp` 一致），塞壬走本地集合。
- 错误与空态：未登录、登录过期、限流、风控、网络失败。

**依赖：** M1 + M2。

**退出标准**

1. 三个在线平台（网易云 / QQ / 酷狗）切换后，账号、列表、缓存互不串；塞壬在 M5 单独验收（含本机喜欢与歌单）。
2. 六种登录方式（网易云扫码/短信、QQ 扫码/微信、酷狗标准/概念）的接口与状态机全部完成；**网易云两种真机各 ≤2 次**，QQ/酷狗四种真机 0 次、只用 fixture/静态检查；失败/取消/过期/冷却状态由 fixture 覆盖。不要求退出后再登录；网易云两次都失败则记录原因并停止，不用更多次数强推。
3. 四类检索各翻 3 页，无重复、无漏项；到底停止；断网重试可恢复；中文输入法组合输入不丢字，候选未上屏时不触发搜索。
4. 歌单创建/改名/删除/加歌/移歌在重启后保持；QQ 的字数限制与能力开关生效。
5. 红心在列表、详情、播放栏三处一致；失败回滚并提示。

### M4 播放、队列与歌词（Gate 4）

**范围**

- 播放状态机：解析、播放、暂停、切歌、seek、失败恢复、试听、音质切换、替代音源。**QQ/酷狗不做真机测试**（登录/写操作/播放都一样），代码与状态机保留、只用 fixture/静态检查覆盖；播放/音质/替代源只验网易云。
- 队列：来源替换、按 ID 补全（`loadQueue`）、跳播、移除、清空、模式。
- 后台：前台服务、MediaSession、通知、音频焦点、耳机/蓝牙、来电中断。
- 歌词：拉取、解析、逐句滚动、原文 + 翻译双行、点击跳转、偏移（单曲 + 全局）、来源选择、缓存、空态。
- 最近播放记录随播放写入，并在发现页「历史」tab 展示（按当前平台过滤）。

**依赖：** M1 + M2。

**退出标准**

1. 网易云连续播放 30 分钟、切歌 100 次无崩溃、无内存持续增长（只做稳定性观察，不设性能指标）；QQ/酷狗不做真机测试。
2. seek 误差 ≤ 1 s；切音质保持位置与暂停意图；不可用档位回退并提示。
3. 队列跳播/移除/清空正确；播放专辑/歌单后队列来源符合规则。
4. 歌词与音频偏差 ≤ 300 ms（网易云曲目）；偏移 ±10 s 可调、可重置、重启保留全局值。
5. 来电中断后恢复播放；耳机拔出暂停；通知栏控制与 App 内状态一致。
6. 锁屏且界面不在前台时，队列连续自动续播 ≥ 3 首（验证下一首 URL 的解析归属）；系统回收进程后重启，队列与位置仍可恢复。
7. 断网/弱网播放失败有提示与重试；恢复网络后可继续。

### M5 详情、发现、设置与主视觉（Gate 5）

**范围**

- 歌曲详情三个 tab、专辑/歌单详情、歌手页、详情操作、排序。
- 发现全部 tab（按 provider 变化：网易云走七条原始路由，QQ/酷狗/塞壬走 `discover` operation）+ 塞壬（目录/分类/检索/本地喜欢与歌单，P1）。
- 设置页（保留项 10-01…10-13；隐藏项 10-14）。
- 初始化页动画、封面查看页手势（P1）、**主视觉 3D 接入（M0.5 选定引擎）**。
- 播放栏、导航、品牌头/页脚的最终视觉。

**依赖：** M3 + M4 + M0.5。

**退出标准**

1. 清单中每个入口都可到达、可返回；无 dead button、无空白页。
2. 详情三 tab 内容正确；同专辑曲目排序与跳播正确。
3. 发现 tab 随 provider 正确变化（QQ 多两项、网易多收藏歌手）。
4. 设置项全部即时生效并持久化；恢复默认只重置偏好。
5. 封面查看页：单指旋转、双指缩放、双指平移，任意斜向平移为直线。
6. 7 个关键页面截图走查通过（§3.6）。
7. 3D 六状态与 iOS/macOS 并排达到 §3.6 阈值；无 2D 替代。

### M6 全量对齐验收（Gate 6）

**范围**

- 只修缺陷，不加功能。
- 三张矩阵：功能矩阵（§5.2）、方向/设备矩阵（§5.4）、异常矩阵（§5.3）。
- 与 iOS/macOS 并排走查；记录差异并判定是否属于「已声明差异」。

**依赖：** M0–M5 全部。

**退出标准**

- §5.5「对齐完成的定义」全部勾选；P0/P1 无缺陷、无延期。

---

## 5. 验收标准

### 5.1 判定规则

- **P0 与 P1 全过** 才可判定「功能对齐完成」；任一项延期只能标记为 Beta，不能对外说「已对齐」。
- 每条判据必须是「可复现步骤 + 可观察结果」；不接受「看起来一样」。
- 视觉按 7 个关键页面截图人工评审，UI 不做像素 diff；**3D 按 §3.6 的 ΔE2000 ≤ 3 且 SSIM ≥ 0.97 单独量化判定，超出阈值即为缺陷**，不适用「看起来差不多」的人工豁免。
- **本计划不以 FPS / 内存 / 启动耗时作为优化目标或验收指标**；仅保留可用性下限：首启（含桥接解压）≤ 10 s、后续冷启动 ≤ 5 s、全程无崩溃 / 无 ANR / 无白屏 / 无静默失败。M4 的「无内存持续增长」只用于排除泄漏，不比较占用高低。
- 所有网络异常都必须有用户可见的文案与重试路径；不允许「转圈到死」。

### 5.2 功能对齐验收矩阵（P0）

| ID | 验收项 | 步骤 | 通过标准 | 模块 |
| --- | --- | --- | --- | --- |
| V-01 | 启动方向 | 竖屏锁定冷启动；横屏锁定冷启动 | 启动后方向与启动瞬间一致，无强制旋转 | 01、1.4 |
| V-02 | 会话恢复 | 播放中杀进程，重启；再在暂停状态杀进程，重启 | 平台/账号/当前曲/位置/队列/模式恢复；暂停意图保持（原本在播则续播，原本暂停则保持暂停） | 01-03/04 |
| V-03 | 桥接失败 | 删除/损坏 Node 资源后启动 | 错误页 + 重试；不白屏、不闪退 | 01-06 |
| V-04 | 网易云登录 | 扫码；短信；各最多 2 次 | 接口/状态机/fixture 通过；真机成功则记录；60 s 冷却生效；不因失败反复重试 | 02-02/03 |
| V-05 | QQ 登录（不做真机） | 跑接口/状态机 + fixture；不扫码、不占设备额度 | 接口/状态机/fixture 通过；5 台设备限制文案可见；**真机 0 次** | 02-04 |
| V-06 | 酷狗双版本（不做真机） | 跑接口/状态机 + fixture；两版本凭据隔离用 fixture 验证 | 两版本凭据独立；接口/状态机/fixture 通过；**真机 0 次** | 02-05 |
| V-07 | 平台隔离 | A 平台登录并产生缓存 → 切 B → 切回 A | 列表、账号、缓存不串；A 仍登录 | 02-07 |
| V-08 | 检索 | 四类各翻 3 页；断网后重试 | 无重复/漏项；到底停止；断网有提示且可恢复 | 03 |
| V-09 | 个人库写操作 | 建歌单 → 改名 → 加 2 首 → 移 1 首 → 删除 | 每步 UI 与重启后一致；失败回滚 | 04 |
| V-10 | 发现 tab | 三个 provider 各看一遍；打开「历史」 | tab 组合正确；分页与打开详情正常；历史只显示当前平台的最近播放 | 05 |
| V-11 | 播放闭环（网易云） | 播放 → 暂停 → 下一首 → seek → 切模式 | 状态、进度、按钮、通知一致；QQ/酷狗不做真机测试 | 07 |
| V-12 | 音质/替代/试听（网易云） | 切档；开替代；播放受限曲目 | 位置保留；回退提示；试听文案正确；QQ/酷狗不做真机测试 | 07-06/07/08 |
| V-13 | 队列 | 播放专辑 → 跳播 → 移除 → 清空 | 队列与当前曲一致；清空只清后续 | 08 |
| V-14 | 歌词 | 播放 → 歌词页 → 点行 → 调偏移 → 切来源 | 偏差 ≤ 300 ms；有翻译的曲目双行显示正确；偏移重启保留；来源生效 | 09 |
| V-15 | 后台/中断 | 锁屏播放；来电；拔耳机 | 通知可控；中断暂停并恢复；拔耳机暂停 | 07-10 |
| V-16 | 设置持久化 | 改主题/动效/音质/自动播放 → 重启 | 全部保持；恢复默认只重置偏好 | 10 |
| V-17 | 竖屏布局 | 320×480、360×800、411×891 | 无 overflow；播放栏不遮挡；子页可返回 | 11-09 |
| V-18 | 横屏布局 | 800×360、891×411、1024×768 | 两栏比例正确；弹层不超出；键盘不遮结果 | 11-10 |
| V-19 | 旋转稳定性 | 播放中、弹层中、输入中旋转各 5 次 | 不中断播放；不丢输入；不重复弹层 | 1.4 |
| V-20 | 异常矩阵 | 断网、弱网、登录过期、音源不可用、空结果 | 均有文案 + 重试；无静默失败 | 全 |
| V-21 | 安全/无遥测 | 静态扫描依赖；抓包 10 分钟 | 无分析/崩溃 SDK；无自建上报域名 | 12-03/06 |
| V-22 | 并排走查 | 与 iOS/macOS 同操作 60 分钟 | 除 §1.5 已声明差异外，无功能差异 | 全 |
| V-23 | 3D 保真度（仅 Vulkan） | 6 个状态与 iOS/macOS 并排截图；连续旋转/切页 60 s；debug + release 各一次 | 真实 3D、同一 GLB/相机/构图/时序；效果以 Qt 版为准未削减；ΔE2000 ≤ 3 且 SSIM ≥ 0.97；无 2D 替代；无 Vulkan 设备明确显示「3D 不可用」，不切 GLES | 11-04、M0.5 |

**P1 专项验收（不阻塞 Beta，但阻塞「对齐完成」）**

| ID | 验收项 | 通过标准 | 模块 |
| --- | --- | --- | --- |
| V-P1-1 | 封面查看页 | 正/反面切换；单指旋转；双指缩放；任意斜向双指平移为直线；退出后状态复位 | 11-05 |
| V-P1-2 | 塞壬唱片 | 目录/分类/检索/详情/播放/歌词全通；本地喜欢与自建歌单 CRUD（建/改名/删/加歌/移歌）；无需登录；与三家平台切换不串 | 05-10 |
| V-P1-3 | 分组与排序 | 按歌手/专辑分组正确；详情曲目三种排序正确；重启保持 | 04-08 |
| V-P1-4 | 初始化动画 | 开关生效；手动重播不重启应用；与首启动画一致 | 10-04 |

### 5.3 异常场景清单（必须逐条过）

1. 冷启动无网络 → 初始化页提示网络不可用，可重试。
2. 播放中切飞行模式 → 当前曲缓冲耗尽后暂停并提示；恢复网络可续播。
3. 登录态在服务端失效 → 需要登录的操作提示「登录已过期」，引导重新登录，不清空本地歌单缓存。
4. 音源返回 404/403 → 提示「暂无可用音源」，可重试或换源；不无限重试。
5. 试听曲目 → 明确标注试听，进度条到试听终点停止并提示。
6. 搜索无结果 → 空态文案，不显示「加载中」。
7. 歌单写操作失败 → 回滚 UI，提示原因；不出现「看似成功」。
8. 队列为空 / 当前曲被删除 → 停止播放并清空播放栏，不崩溃。
9. 旋转时正在输入 → 输入内容与焦点保留，键盘不闪退。
10. 通知权限被拒绝 → 播放正常，通知不显示，设置页可再次引导。
11. 3D 初始化失败 / 设备无可用 Vulkan → 明确显示「3D 不可用」，3D 区域保留错误占位，其余功能照常；**不静默降级成 2D 贴图**、不尝试 GLES 回退。

**登录验证范围（硬约束）**

| 登录方式 | 真机最多次数 | 成功判定 | 失败处理 |
| --- | --- | --- | --- |
| 网易云扫码 | 2 | 账号卡片出现昵称/UID | 记录原因，不自动重试；其余状态用 fixture |
| 网易云短信 | 2 | 同上；60 s 冷却生效 | 同上；不连续发码 |
| QQ 扫码 | **0（不做真机测试）** | 接口/状态机/fixture 通过；5 台设备限制文案可见 | 用 fixture 定位；不占用设备额度 |
| 微信扫码 | **0（不做真机测试）** | 接口/状态机/fixture 通过 | 同上 |
| 酷狗标准版 | **0（不做真机测试）** | 接口/状态机/fixture 通过 | 同上 |
| 酷狗概念版 | **0（不做真机测试）** | 接口/状态机/fixture 通过；与标准版凭据独立 | 同上 |

QQ/酷狗四种登录及写操作、播放**全部不做真机测试**，只用 fixture 与静态检查覆盖；真机只验网易云。网易云超过上限即停止，改用日志与 fixture 定位；不允许“再试一次”式反复登录。

### 5.4 方向 / 设备矩阵

| 维度 | 取值 | 通过标准 |
| --- | --- | --- |
| 设备 | 6.x 寸 arm64 手机（Android 12+） | 全功能 |
| 设备 | Android 15 16 KB 页模拟器/真机 | libnode 可加载；否则 M0 判死并改路线 |
| 设备 | 平板或折叠屏（最短边 ≥ 600 dp） | 两栏布局，竖屏不塌单列 |
| 设备 | 支持 Vulkan 的目标机（**首版唯一 3D 路径**） | Flutter GPU/flutter_scene 保真度达标；debug + release 都验；效果以 Qt 版为准未削减 |
| 设备 | 无 Vulkan 设备 | 明确显示「3D 不可用」，其余功能照常；不切 GLES（仅接口预留）、不静默 2D |
| 安装 | 卸载 Qt 版后全新安装；不做旧数据迁移 | 首启按全新区工作；签名不一致时先卸载，不尝试覆盖 |
| 方向 | 竖屏冷启动 / 横屏冷启动 | 保持启动方向 |
| 方向 | 播放中旋转 / 弹层中旋转 / 输入中旋转 | 状态不丢、播放不断 |
| 窗口 | 分屏 / 自由窗口（若设备支持） | 无 overflow，播放栏不重叠 |
| 字体 | 系统字号 1.0 / 1.3 | 不裁切、不重叠 |

### 5.5 「功能对齐完成」的定义

- [ ] §5.2 的 V-01…V-23 全部通过；
- [ ] 清单中 P0 项全部实现，P1 项全部完成（含 V-P1-1…V-P1-4；不允许延期，否则只能标记 Beta）；
- [ ] 六种登录的接口/状态机/fixture 完成；网易云两种真机各 ≤2 次，QQ/酷狗四种真机 0 次；塞壬的「检索 → 详情 → 播放 → 歌词 → 本地喜欢/歌单」闭环走通；
- [ ] 每个入口可达、可返回，无 dead button、无空白页；
- [ ] 杀进程重启恢复平台、账号、播放会话与偏好；
- [ ] 3D 六状态与 iOS/macOS 并排达到 §3.6 阈值，效果以 Qt 版为准未削减，且无 2D 替代；仅 Vulkan，无 Vulkan 设备明确显示「3D 不可用」，OpenGL 仅接口预留；
- [ ] 方向/设备矩阵全部通过；
- [ ] 异常场景 11 条全部有明确 UI；
- [ ] 无遥测（静态依赖扫描 + 抓包）；
- [ ] 与 iOS/macOS 并排走查 60 分钟，除 §1.5 已声明差异外无功能差异；
- [ ] 0 个 P0 缺陷、0 个 P1 缺陷。

---

## 6. 风险与剩余确认

### 6.1 技术风险

| 风险 | 影响 | 处置 | 阶段 |
| --- | --- | --- | --- |
| libnode 18.20.4 未按 16 KB 页对齐 | Android 15+ 设备无法加载，直接不可用 | M0 用 `readelf -lW` 检查 LOAD 对齐；不合格则从源码重编或换版本 | M0 |
| `libnode.so` 依赖 `libc++_shared.so` 等未随包 | `System.loadLibrary` 失败，应用起不来 | `readelf -d` 列 `NEEDED`，缺什么补什么；打包后用 `zipalign -c -P 16` 复检 | M0 |
| libc++/STL ABI 与 Flutter 引擎冲突 | 链接失败或运行时崩溃 | 用 nodejs-mobile 对应 NDK 版本；只保留一份 `libc++_shared.so`；`nodehost` 只调 `node::Start`，不跨边界传 STL 类型 | M0 |
| 音源返回 `http://` 直链 | Android 9+ 明文策略拦截，播放器报错 | 优先 https 重写；不行用域名级 network security config 或 `media_kit`；M0 只记录网易云 scheme（QQ/酷狗走 fixture/静态检查） | M0 |
| 桥接产物约 20 MB（单文件 worker） | APK 增加约 20 MB + libnode；首启解压 | 复用 `bundle-bridge.cjs`（`RHINE_ANDROID_BUILD=1`），不打包 `node_modules`；初始化页显示进度；只打 arm64（模拟器另加 x86_64） | M0 |
| APK 预计 60–80 MB（libnode + 桥接 + Flutter） | 安装包偏大 | 本计划不做体积优化；先记录实测值，是否有裁剪需求由你定 | M0 |
| 后台 isolate 不能向 Node 要下一首 URL | 锁屏后队列停在当前曲，自动续播失效 | M0 做「锁屏续播 2 首」判定；不行则预取 1–2 首 URL，或把队列状态机放音频 isolate 并通过通道要 URL | M0/M4 |
| 签名冲突 / 同包名覆盖 | debug 签名装不到 Qt release 版上 | **已定：不改签名**；安装前卸载 Qt 版；不做旧数据迁移；不尝试覆盖安装 | M0 |
| Keystore 加密数据被系统备份 | 换机恢复后无法解密，登录态异常 | `allowBackup=false`；启动时解密失败按「未登录」处理，不崩溃 | M0/M1 |
| Worker 崩溃或握手断开 | 请求永久转圈、会话失效 | `BridgeWatchdog`：失败在途请求；runtime 仍活则重建 Worker，runtime 退出则错误页；M1 用人为 kill 验证 | M1 |
| QQ 登录设备限制（7 天 5 台） | 真机登录被拒会占用额度 | **已定：QQ/酷狗不做真机登录**，不占用设备额度；只用 fixture/静态检查，5 台设备限制文案保留 | M3 |
| 国产 ROM 后台限制 | 通知/后台播放被杀 | 前台服务 + 电池优化引导；在目标机型验收 | M4 |
| 竖屏小高度 + 播放栏 + 键盘 | 内容被遮挡 | 横屏弹层全屏化；`resizeToAvoidBottomInset`；最小高度验证 360 dp | M2 |
| Flutter 3D 生态达不到保真度 | 无法满足“完全一致” | M0.5 用同一 GLB 做 A/B 比对；**两者都不达 ΔE≤3 且 SSIM≥0.97 就暂停 3D 部分**（M0.5/M5 主视觉/V-23 挂起，其余模块继续），等你给方向再恢复；不移植 Qt、不降 2D | M0.5 |
| flutter_scene 在 Android 中低端机帧率偏低 | 复杂场景实测 5–40 fps；阴影/IBL 可能拖慢 | **效果以 Qt 版为标准，首版不削减**；只记录 p50/p95 帧间隔与长帧作为数据，卡顿不作为改画面的理由；优化方向由你人工测试后给出 | M0.5 |
| Flutter GPU 在 Android 仅 Vulkan 可靠 | 无 Vulkan 设备无法渲染 3D | **已定：首版仅 Vulkan**；无 Vulkan 明确显示「3D 不可用」，其余功能照常；GLES 只留 `SceneBackend` 接口，不启用 | M0.5 |
| 3D 暂停导致「对齐完成」挂起 | M5 主视觉与 V-23 无法完成 | 其余模块继续开发；整体只标记 Beta、不宣告对齐完成；3D 恢复需你给方向后重走 M0.5 | M0.5/M6 |
| Flutter 3.47 GLES render-to-texture 改为 top-down | 自定义 shader/后处理上下颠倒 | **首版不实现 GLES**，此风险不适用；后续启用 `GlesSceneBackend` 时再验证 Y 翻转与 FBO 方向 | 后置 |
| Node 18 已停止维护 | 安全与兼容风险 | 锁定版本；M0 记录升级到 nodejs-mobile 新版本的可行性 | M0 |
| Flutter/Gradle 工具链 | 首次构建失败 | 已配阿里云镜像；M0 先验证 `flutter build apk --debug` | M0 |

### 6.2 已确认（无待确认项）

2026-11-08 四个确认点全部定案，已并入 §1.6 决策表，实施时不再讨论：

1. **QQ/酷狗不做测试**（#11）：登录、写操作、播放的代码与状态机仍实现，但**真机测试全部取消**，只用 fixture/静态检查；真机只验网易云（扫码/短信各 ≤2 次，播放、音质、替代源）。原先「若提供账号则每种登录 ≤2 次」的条件不再适用。
2. **首版仅 Vulkan**（#13）：无 Vulkan 设备明确显示「3D 不可用」，其余功能照常；OpenGL ES **只预留 `SceneBackend` 接口**（§3.11），不实现、不引入 `three_js`/`flutter_gl`、不验证、不验收；后续启用须补实现并重走 M0.5。
3. **效果以 Qt 版为标准**（#14）：阴影/IBL/材质/动效不削减；M0.5 只记录 p50/p95 帧间隔与长帧，卡顿不改画面；优化方向由你人工测试后另行给出。
4. **全不达标则暂停 3D 部分**（#15）：A/B 两个 Flutter GPU 候选均不达 §3.6 阈值 → 暂停 M0.5、M5 主视觉接入与 V-23，其余模块继续但不宣告「对齐完成」；不移植 Qt、不启用 GLES、不降 2D，等你给方向再恢复。

其余已定项：更新检查不做、只留 `UpdateService`（§3.10）；本地音乐只留 `LibrarySource`/`LocalLibrarySource`（§3.9）；包名与签名不动、旧数据不处理；塞壬按 P1；不做遥测与性能优化。按 §1.6 执行。

---

## 7. 交付物

- `lib/` Flutter 应用（UI、状态、Gateway、播放器、歌词、`LibrarySource`/`UpdateService` 扩展点）；
- `lib/scene/` 3D 场景模块（`flutter_scene` 为首选；**仅 Vulkan**；`SceneBackend` 接口 + `GlesSceneBackend` 空实现只作扩展点，不含 `three_js` 适配；不移植 Qt 渲染器）；
- `android/app/src/main/cpp/nodehost.cpp` + Kotlin `NodeHost`；
- `assets/` 字体、`Assets/android-3d/*.glb` 与场景数据、桥接资源打包清单；
- `test/` 单元与 fixture 回放；`integration_test/` 关键闭环；
- `docs/` 本计划 + 验收记录（V-01…V-23 与 V-P1-1…4 的实际结果）；
- 插件审计表（用途/许可证/维护状态/原生代码/可替换性）；
- 构建脚本（debug/release；签名沿用脚手架现状，不新增/修改 keystore）；
- 第三方许可证（nodejs-mobile、上游协议模块、3D 引擎）随包或关于页展示；
- 一份「与 iOS/macOS 的已声明差异」清单（§1.5）。

---

## 8. 代码依据索引

| 主题 | 文件 |
| --- | --- |
| 平台能力 | `Qt/src/PlatformFeatures.h` |
| iOS 适配 | `Qt/src/PlatformIOS.mm`、`Qt/src/IOSWindow.mm`、`Qt/InfoIOS.plist.in` |
| 启动/会话 | `Qt/src/main.cpp`、`Qt/src/MusicSession.cpp`、`Qt/src/MusicAccount.cpp` |
| 检索/库/发现 | `Qt/src/MusicLibrary.cpp`、`Qt/src/MusicDiscover.cpp`、`Qt/src/NativeHudSearch.cpp`、`Qt/src/NativeHudLibrary.cpp` |
| 详情 | `Qt/src/NativeHudDetail.cpp`、`Qt/src/SongDetailCard.cpp`、`Qt/src/CollectionDetailCard.cpp` |
| 播放/队列 | `Qt/src/MusicPlayer.cpp`、`Qt/src/PlayerBar.cpp`、`Qt/src/PlaybackQueueCard.cpp` |
| 歌词 | `Qt/src/LyricsController.cpp` |
| 设置 | `Qt/src/SettingsSchema.cpp`、`Qt/src/NativeHudSettings.cpp` |
| 启动动画 | `Qt/src/NativeHudBoot.cpp` |
| 主视觉/触控 | `Qt/qml/Overlay.qml`、`Qt/src/NativeViewer.cpp` |
| 3D 场景 | `Assets/android-3d/*.glb`、`scene-fixture.json`、`slots.json`；`Qt/src/RhiScene.cpp`、`Qt/src/OpticalScene.cpp`（只取相机/动画参数，不移植渲染器）；`Qt/shaders/enhancement/*`（仅作对照） |
| 写操作 | `Qt/src/MusicMutation.cpp` |
| 塞壬本地集合 | `Qt/src/LocalCollections.cpp`、`MusicBridge/client/siren.mjs` |
| 登录 | `Qt/src/MusicAccount.cpp` |
| 桥接 | `MusicBridge/ios-runtime.cjs`、`MusicBridge/worker.cjs`、`MusicBridge/client/dispatch.mjs`、`Qt/src/BridgeProcessAndroid.cpp` |
| iOS 维护原则 | `docs/IOS-MAINTENANCE.md` |
| 功能清单 | `README.md`「功能列表」 |

### 外部依据（2026-11-07 检索，实施前复核）

- Flutter GPU 入门（Dart + GLSL、Impeller、`flutter_gpu_shaders`）：<https://docs.flutter.cn/posts/flutter-gpu-101>
- Flutter Scene（Flutter GPU 上的 3D 引擎，glTF/PBR/IBL/`.fmat`）：<https://github.com/bdero/flutter_scene>
- just_graphics_engine（Flutter GPU 3D，Android 仅 Vulkan）：<https://pub.dev/packages/just_graphics_engine>
- three_js（Dart/three.js，ANGLE/GLES）：<https://pub.dev/packages/three_js> —— **仅 `GlesSceneBackend` 接口预留的参考，首版不引入**
- Flutter GPU 在 Android GLES 的挂起问题：<https://github.com/flutter/flutter/issues/177873> —— 首版不走 GLES，仅记录不启用的原因
- Android `EnableFlutterGPU` manifest 键：`io.flutter.embedding.android.EnableFlutterGPU`（布尔值必须显式 `true`）
