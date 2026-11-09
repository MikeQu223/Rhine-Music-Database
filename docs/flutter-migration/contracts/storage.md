# 存储、会话与凭据契约（T07）

状态：**FROZEN**（T07-C01 / 原子 T07-C01-M12）。本文件是 Flutter P0 对 Qt Android 数据面的唯一规范。
基线：`8ed3067b0812eb2612f7841ec127a6e8ca93231b`。规范源是同一基线的 Qt 源码；旧 Flutter 实现不是规范。
证据方式：全部结论由本基线 Qt 源码逐行核对得出，行号见文末 §13 证据索引；不可在离线环境证明的项在 §12 单独标注。
独立只读审查：见 `reports/T07-C01-M12-R.json`（审查对象是本 commit 的精确 revision）。

本契约只冻结**磁盘上的文件、键、格式、边界与恢复语义**，不冻结 UI 布局和网络协议。所有相对路径均以 Qt `AppStorage` 在 Android 上解析出的运行时目录为根；文档中不写死 `/data/data/<package>`，也不猜测 QSettings 的文件名与转义。

## 0. 不可协商规则

1. **路径不改名、不搬家。** Flutter 必须读写 Qt 已经使用的同一批文件；不得另建 `*.v2.json`、`data/panel/`、`session_flutter.json`、`collections_flutter/` 之类的新存储结构。
2. **用户数据只增不删。** 迁移、首启、缓存清理、解析失败都不得删除 session、playback-session、account.credential、collections、设备身份文件、panel/* 键。只有用户显式退出**当前来源**账号时，才按 §6.5 删除该来源的凭据字段；凭据对象为空时才删除凭据文件。
3. **写会话是原子的，且 64 MiB 是硬上限。** 超限时保留旧文件，不截断、不写半截。
4. **view 只有 16 个字段。** 读时忽略未知字段，写时不得产生未知字段；非法枚举值回退到本契约规定的默认值。
5. **凭据安全分支不得静默降级为“退出登录”。** 安全存储不可用、签名不可用、迁移未验证时，保留原文件并停下发布门，不允许把用户变成未登录；失败文案必须与 Qt 一致。
6. **panel 是 QSettings 键，不是文件。** 53 个白名单键位于 `panel/<key>`；不得创建 `data/panel` 目录或 JSON 面板文件。
7. **离线模式不落盘。** `Host::offline` 为真时，Qt 不读凭据、不写 session、不读写偏好；Flutter 必须保持同一行为，且不得借机清空已有文件。
8. **回滚兼容。** Flutter 写出的 session/playback/credential/collections 必须仍能被 Qt 读取；已有字段的类型不得改变，新字段只能按 Qt 的忽略规则追加。
9. **Qt 现状与 Flutter 增强必须分开表述。** Qt 的凭据写入是**原地非原子**的（§6.1）；Flutter 若改为原子写入或系统安全存储，属于**增强分支**，必须 §6.3 全部满足后才可启用，且不得因此改变 Qt 可读性。
10. **本契约不声称设备已验证。** 目录绝对路径、QSettings 落点、权限位、崩溃窗口均为 §12 DEVICE_BLOCKED 项。

## 1. 目录契约（AppStorage 对齐）

Qt `AppStorage`（`Qt/src/AppStorage.cpp`）：

| 逻辑目录 | Android 解析 | 依赖函数 | 用途 | 可删除性 |
|---|---|---|---|---|
| `dataDirectory()` | `QStandardPaths::AppLocalDataLocation` | `AppStorage.cpp:73-82` | 会话、凭据、收藏、设备身份、解包资源 | **用户数据，禁止清空** |
| `cacheDirectory()` | `QStandardPaths::CacheLocation` | `AppStorage.cpp:84-93` | 封面/元数据/着色器/QML 缓存 | 可重建，可清（§9） |
| `temporaryDirectory()` | `QDir::tempPath()` | `AppStorage.cpp:95-104` | 临时文件 | 可清 |

- Android 走 `#else` 分支：`dataDirectory()` 没有 portable 根，直接是 `AppLocalDataLocation`；`cacheDirectory()` 是 `CacheLocation`；`temporaryDirectory()` 是 `QDir::tempPath()`。
- portable（绿色版）分支由 `initializePortable()` 建立（`AppStorage.cpp:33-57`），只在桌面入口调用，**Android 不设置 portable 根**，因此 Android 上 `portableRoot` 恒为空。桌面分支仅供解释 Qt 行为，不是迁移目标：Windows 为 `<exe>/data`（`AppStorage.cpp:77-78`）、`data/cache`（`:85-86`）、`data/temp`（`:99-100`）与 `data/settings.ini`（`:107-108`）；portable 为 `<root>/data` 与 `<root>/settings.ini`。

**必须实测记录的运行时值（DEVICE_BLOCKED）：** Flutter 首次接线前必须在目标设备上记录 Qt 实际解析出的 `dataDirectory()` 绝对路径，并证明 Flutter 解析到同一目录。若 Flutter 的 `getApplicationSupportDirectory()` 等 API 落在不同目录，必须在接线层显式改到 Qt 目录；否则整个契约不成立，发布门标记 BLOCKED，而不是让 Flutter 静默使用新目录。

### 1.1 文件清单

除注明外全部位于 `dataDirectory()`。

| 文件 | 生产者/消费者 | 格式 | 大小上限 | 证据 |
|---|---|---|---|---|
| `session.json` | GUI 进程 | UTF-8 compact JSON | 读/写 64 MiB | `MusicSession.cpp:269-284`、`NativeApplication.cpp:64-69` |
| `playback-session.json` | 后台播放服务 | UTF-8 compact JSON | 读/写 64 MiB | `PlaybackService.cpp:419-448` |
| `playback-service.lock` | 后台播放服务 | QLockFile | — | `playback_main.cpp:61` |
| `account.credential` | Host（Android/Linux） | UTF-8 compact JSON，权限 0600 | 未见上限 | `PlatformAndroid.cpp:13-15,26-42`、`PlatformLinux.cpp:17` |
| `account.dpapi` | Host（Windows） | DPAPI 密文 | 未见上限 | `PlatformWindows.cpp:24` |
| `collections/siren.json` | LocalCollections（仅 siren） | UTF-8 compact JSON | 读取 16 MiB | `LocalCollections.cpp:13-21,36-85` |
| `qq-device.json` | Node 协议进程 | JSON | 未见上限 | `Host.cpp:380`、`BridgeProcessAndroid.cpp:204` |
| `kugou-device.json` | Node 协议进程 | JSON | 未见上限 | `Host.cpp:381`、`BridgeProcessAndroid.cpp:205` |
| `resources/` | AndroidAssets 解包 | 资源树 | — | 可重建（不得删除整个 data 目录） |
| `cacheDirectory()/metadata/<hash>.json` | Host | JSON | — | `Host.cpp:1020-1023` |
| `cacheDirectory()/media-cover.png` | Host（系统媒体封面） | PNG | — | `Host.cpp:978` |
| `cacheDirectory()/shaders/pipeline.cache` | 渲染管线（**仅 Windows**） | 二进制 | — | `main.cpp:1234`（在 `#ifdef Q_OS_WIN` 内 `:1232-1239`；Android 不产生该文件） |
| `cacheDirectory()/shaders/qrhi-pipeline.cache` | Vulkan 呈现后端 | 二进制 | — | `VulkanPresentationBackend.cpp:34` |
| `cacheDirectory()/qml/` | Qt QML 磁盘缓存 | 二进制 | — | `AppStorage.cpp:51`、`Host.cpp:1034` |

`collections` 目录名不是字面量：`LocalCollections` 的存储根默认是 `dataDirectory() + "/collections"`，文件名是 `<provider>.json`（`LocalCollections.cpp:15,19-21`）；siren 来源因此得到 `collections/siren.json`。

**64 MiB 边界语义（读与写一致）：** 读取端条件是 `file.open(...) && file.size() <= 64 * 1024 * 1024`（`NativeApplication.cpp:66`、`PlaybackService.cpp:429`），写入端拒绝条件是 `bytes.size() > 64 * 1024 * 1024`（`MusicSession.cpp:276`）。即 67,108,864 字节仍被接受，67,108,865 被拒绝。

## 2. `session.json` 契约

### 2.1 顶层

```json
{"version":1,"library":{},"player":{},"view":{}}
```

- 顶层**恰好**这四个键（`MusicSession.cpp:215-235`）；`version` 是整数 `1`。
- `library`/`player`/`view` 都是对象，写入时必须存在。
- 读取门禁（`MusicSession.cpp:237-240`）：`saved["version"] != 1` **或** `music.restoreSessionState(library)` 返回假 → 整个 `restoreSessionState` 立即返回假，**view 与 player 都不恢复**，但**文件保留**。
- 编码 UTF-8、compact JSON（`QJsonDocument::Compact`，无缩进）。键顺序不参与语义；字段集合参与契约。

### 2.2 `library` 字段

写入源：`MusicLibrary::sessionState()`（`MusicSession.cpp:33-86`）；读取源：`MusicLibrary::restoreSessionState()`（`MusicSession.cpp:88-213`）。

身份门（先于一切字段，`MusicSession.cpp:89-98`）：`provider`、`edition`、`uid` 三者必须与当前值全等，否则返回假。随后三条结构门禁：`sources.size() == 5`、`0 <= selectedLane <= 4`、`-1 <= selectedPhysical <= 39` 且 `selectedPhysical >= 0` 时必须属于 `physicalSlots[selectedLane]`（`:92-98`）、`directories.size() <= 64`（`:99-102`）。

| 键 | 类型 | 写入含义 | 读取规则 |
|---|---|---|---|
| `provider` | string | `netease`/`qq`/`kugou`/`local`/`siren` | 必须全等，否则整个 library 失败 |
| `edition` | string | `standard`/`lite` | 必须全等，否则失败 |
| `uid` | string | 当前账号 uid；未登录/本地为空串 | 必须全等，否则失败 |
| `sources` | array | 恰好 5 个 lane 对象 | 长度必须为 5 |
| `directories` | array | 目录栈，root→leaf | 超过 64 失败 |
| `current` | object | 当前选中条目 | 原样；空对象合法 |
| `selectedPhysical` | int | 物理槽 | 见身份门 |
| `selectedLane` | int | 0..4 | 见身份门 |
| `keyword` | string | 搜索关键词 | `toString()`（非串→空串） |
| `searchKind` | string | 默认 `song` | 非串/缺失 → `song` |
| `status` | string | 状态文案 | 原样 |
| `searchLoading` | bool | 保存时是否在搜索 | 真且 keyword 非空 → 恢复后重新 `search()` |
| `directoryLoading` | bool | 保存时是否在进目录 | 真且目录存在且 songs 为空 → 重新 `enterDirectory()`（else-if 首支，优先于 detailLoading，`:180-186`） |
| `detailLoading` | bool | 保存时是否在取详情 | 真且 current 非空 → 重新 `choose()`（else-if 次支，仅当上一支不成立时检查，`:180-186`） |
| `privateSelection` | bool | 私有选择态 | 原样 |
| `searchCursor` | int | ≥0 | 负数 → 0 |
| `playlistCursor` | int | ≥0 | 负数 → 0 |
| `albumCursor` | int | ≥0 | 负数 → 0 |
| `likedCursor` | int | ≥0 | 负数 → 0 |
| `likedIDs` | array \| null | 喜欢列表 | 非数组/缺失 → 不恢复（`nullopt`） |
| `groupName` | string | 分组名 | 原样 |
| `groupIndices` | array\<int\> | 分组索引 | 每项负数 → 0 |
| `groupLane` | int | 默认 -1 | clamp 到 `-1..4` |
| `tracks` | array | 歌曲对象 | 原样 |
| `trackIDs` | array | 歌曲 ID | 原样 |
| `trackCursor` | int | ≥0 | 负数 → 0 |
| `albumLoaded` | bool | 专辑是否加载 | 原样 |
| `playContext` | array | 播放上下文 | 原样 |
| `directoryInfo` | bool | 目录信息态 | 原样 |
| `wantsSongDetails` | bool | 是否要歌曲详情 | 原样 |
| `discover` | object | 发现页状态 | 缺失/非对象按默认值（下表） |

`sources[lane]` 每项恰好 5 键（写入 `MusicSession.cpp:36-40`，读取 `:106-113`）：

| 键 | 类型 | 读取规则 |
|---|---|---|
| `items` | array | 原样 |
| `total` | int | `max(items.length, total >= 0 ? total : 0)` |
| `offset` | int | clamp `0..max(0, items.length-1)` |
| `more` | bool | 非 bool → false |
| `row` | int | clamp `0..7` |

`directories[]` 每项恰好 14 键（写入 `MusicSession.cpp:12-27`，读取 `:115-136`）。读取时按数组顺序从第一项开始逐级挂 `parent`，因此 **root→leaf** 顺序由写入方保证，最后一项是最深目录：

| 键 | 类型 | 读取规则 |
|---|---|---|
| `item` | object | 原样 |
| `songs` | array | 原样 |
| `sortField` | string | 只接受 `none`/`title`/`album`/`artist`；其他/缺失 → `none` |
| `ids` | array | 原样 |
| `albums` | array | 原样 |
| `cursor` | int | clamp `0..ids.length` |
| `index` | int | clamp `0..max(0, songs.length-1)` |
| `anchor` | int | clamp `0..39` |
| `page` | int | **写入字段，读取时忽略并重算**：`page = index / 40 * 40` |
| `parentPhysical` | int | clamp `0..39` |
| `parentLane` | int | clamp `0..4` |
| `parentItem` | object | 原样 |
| `albumCursor` | int | 负数 → 0 |
| `albumsMore` | bool | 非 bool → false |

`discover` 默认值（`MusicSession.cpp:165-171`）：

| 键 | 类型 | 默认/规则 |
|---|---|---|
| `tab` | string | 缺失/非串 → `playlists` |
| `items` | array | 缺失 → `[]` |
| `offset` | int | 负数 → 0 |
| `more` | bool | 非 bool → false |
| `category` | string | 缺失/非串 → `全部` |
| `newSongArea` | string | 缺失/非串 → `5` |

补充读取行为（`MusicSession.cpp:164,172-211`）：恢复时把内存标志 `detailLoading`/`directoryLoading`/`trackLoad` 一律置假。但三者中 `detailLoading`、`directoryLoading` **仍然是持久字段**——它们与 `searchLoading` 一起被 `sessionState()` 写入（`:61-63`），恢复时只是用其存档值触发一次 `choose()`/`enterDirectory()`（`:180`、`:184`，互斥 else-if）；只有 `trackLoad` 不落盘。**不得**把这三个都说成“不是持久字段”；只有成员变量本身在恢复后置假；清空 `coverImage`/`coverKey` 并重新请求封面；siren 来源在恢复 `likedCursor` **之后**重建本地列表（`:187-204`），因为本地列表来自磁盘而非会话；`selectedLane > 0` 且该 lane 为空时补拉一页（`:205-211`）。

### 2.3 `view` 字段（恰好 16 个）

写入源和读取源都在 `MusicSession.cpp`：`:215-235`（`NativeApplication::sessionState`）与 `:237-267`（`NativeApplication::restoreSessionState`）。

| # | 键 | 类型 | 写入含义 | 恢复规则 |
|---|---|---|---|---|
| 1 | `mode` | string | `archive`/`detail` | 仅当为 `detail` **且** `library.current` 非空时 `detail`，否则 `archive` |
| 2 | `selected` | int | 物理选中槽 | clamp `0..39` |
| 3 | `tab` | string | `overview`/`notes`/`history` | 白名单外 → `overview` |
| 4 | `modal` | string | 当前模态；关闭中写空串 | 只接受 `saved`/`search`/`discover`/`queue`/`settings`/`player`/`local`；其他/空/缺失 → 不打开任何模态 |
| 5 | `queueOffset` | int | 队列滚动偏移 | 负数 → 0 |
| 6 | `settingsScroll` | double | 设置页滚动值 | clamp `0..settingsScrollMaximum()`（运行时布局函数，非常量） |
| 7 | `query` | string | 搜索框文本 | 非串 → 空串 |
| 8 | `groupBy` | string | 分组方式 | 非串 → `none`；空串保留 |
| 9 | `activeGroup` | string | 激活分组 | 非串 → 空串 |
| 10 | `artistTab` | string | 歌手页 tab | 非串 → `songs` |
| 11 | `listOffset` | int | 列表偏移 | 负数 → 0 |
| 12 | `trackOffset` | int | 曲目列表偏移 | 负数 → 0 |
| 13 | `bodyOffset` | int | 正文偏移 | 负数 → 0 |
| 14 | `musicCollection` | int | 音乐收藏页 | clamp `1..4`；缺失/非数 → 1 |
| 15 | `trackListMode` | bool | 曲目列表模式 | 非 bool → false |
| 16 | `lyricsMode` | bool | 歌词模式 | 非 bool → false |

补充：

- `modal` 的写入值是 `hud.closing ? "" : hud.modal`（`MusicSession.cpp:222`）。白名单外的字符串（例如 `account`、`login`）不恢复，且**不报错、不清理**。
- `settingsScrollMaximum()` 由 HUD 布局计算（`NativeHud.h:132-135`，视口常量 `SettingsViewportTop = 176`、`SettingsViewportBottom = 836`、内容底默认 `1600`，见 `:115-117`）；保存值可能大于当前最大值，恢复时必须夹取。
- `selected` 是全局物理槽，与 `library.selectedPhysical` 是两个独立字段，两者都保存；library 的成员校验先发生（`:238`）。
- **未知字段：读取忽略；写入禁止。** 归一化输出键集合必须恰好等于本表 16 键。

### 2.4 恢复顺序与身份门（时序契约）

启动顺序（`NativeApplication.cpp:44-90`）：

1. `Host` 构造：读 `panel/kugou-edition`，仅当值为 `lite` 才设 `lit` 版本（`Host.cpp:59-61`）；读凭据对象（`Host.cpp:62-63`，仅 `!offline && !remote`）。
2. `MusicLibrary` 构造：`kugouEdition = panel/kugou-edition == "lite" ? "lite" : "standard"`；`provider = panel/provider`，非法（含 Android 上禁用的 `local`）回退 `netease`（`MusicLibrary.cpp:18-25`）。`accountKey()` 对 kugou 是 `"kugou-" + edition`，其他是 provider 本身（`MusicLibrary.cpp:169-171`）。`restoreCachedAccount()` 决定 `uid = authenticated ? panel/account-id-<accountKey> : ""`（`MusicAccount.cpp:105-106`）。
3. 读 `session.json`，仅当 `!offline`、可打开且大小 ≤64 MiB（`NativeApplication.cpp:64-69`）。
4. `restoreSessionState`：先 `version == 1`，再 `library` 全量门禁；任一失败 → view/player 都不恢复（`MusicSession.cpp:237-240`）。
5. 成功后才应用 view；player 仅在“不存在后台播放连接”时恢复（`MusicSession.cpp:263-265`）。
6. 之后才发起 `restoreAccount()` 网络校验（`NativeApplication.cpp:74`），它可能更新或清空 uid，但**不回滚已恢复的 library**。

由此得到的硬约束：

- `panel/provider`、`panel/kugou-edition`、`panel/account-id-*` 与会话是同一个身份系统。迁移若丢失/重置这些键，session 的身份门会失败，表现为“上次状态消失”，但文件仍在。**禁止把“恢复失败”实现成删除 session。**
- 酷狗 standard/lite 的 uid 分属 `account-id-kugou-standard` 与 `account-id-kugou-lite`；切换版本后旧 edition 的会话不应恢复（edition 不匹配即失败）。
- 凭据文件存在但 `account-id-*` 键为空时 uid 为空；保存过非空 uid 的会话不会恢复。不得在启动时自动补写 uid。
- 只有 library 门禁通过后才应用 view；因此“view 单独存在”不能恢复任何 UI 状态。测试夹具中的 view 必须放在完整顶层结构下使用。

### 2.5 保存、原子性与超限

`NativeApplication::saveSession()`（`MusicSession.cpp:269-284`）：

1. `offline` 为真 → 直接返回，不写。
2. 目标 `dataDirectory()/session.json`；序列化为 compact UTF-8（`:274-275`）。
3. 若字节数 **> 64 MiB（67,108,864）**：警告“会话过大，已保留原有存档”并返回（`:276-279`）。此时 `QSaveFile` 只被构造、**尚未 open**，目标文件一个字节都不动。
4. 否则 `mkpath` + `QSaveFile::open` + 完整写入 + `commit()`；任一步失败 → 警告“无法保存上次会话”，旧文件保留（`:280-283`）。
5. 移动端没有可靠退出点（SIGKILL），保存节拍是每 **15 秒**一次 + `ApplicationInactive`/`ApplicationSuspended` 立即一次（`NativeApplication.cpp:76-89`）。因此崩溃最多丢失最近 15 秒的状态；契约不承诺更强。

Flutter 等价要求：

- 超限判断必须在创建/打开/覆盖目标**之前**；不得先截断目标。
- 临时文件必须与目标同目录，提交用原子 rename；失败时清理临时文件并保留旧文件。
- 不得把“序列化失败”当成空会话写盘。
- 读取端遇到超限、打不开、JSON 非法：保留文件，按无会话启动；下一次正常保存才允许覆盖。

## 3. `session.json` 内的 `player` 对象

写入源 `MusicPlayer::sessionState()`（`MusicPlayer.cpp:749-758`）；读取源 `MusicPlayer::restoreSessionState()`（`MusicPlayer.cpp:760-780`）。

| 键 | 类型 | 含义 | 恢复规则 |
|---|---|---|---|
| `current` | object | 当前曲目 | 空对象 → 只恢复队列，不选曲 |
| `queue` | array | `PlaybackQueue::toJson()`，即原始 `m_items`（`PlaybackQueue.cpp:420-422`） | 见 §3.1 |
| `index` | int | 当前队列索引 | 仅用于队列恢复（默认 -1） |
| `mode` | string | `all`/`one`/`off`/`shuffle` | 白名单外 → `all` |
| `position` | double | 播放位置（秒） | 必须有限且 `0..1e12`；否则**整个 player 恢复直接返回**（mode、队列、选曲都不应用） |
| `requested` | bool | 保存时是否应处于播放态 | 传给 `play(..., saved)` 作为 resume 信息 |
| `preview` | bool | 是否试听 | 传给 `play(..., preview, saved)` |

`position` 是**第一道门**（`MusicPlayer.cpp:761-764`）：非法时连 `mode` 都不写回。

### 3.1 队列恢复

- `queue` 是曲目对象数组，不是 ID 数组。元素必须 `kind == "song"` 且 `id` 非空，否则丢弃；身份是 `provider(default "netease") + ":" + id`，同身份重复项只保留第一次出现（`PlaybackQueue.cpp:14-30` 的 `sanitized()`，`:36-38` 的 `identity()`）。
- 原 `index` 指向**过滤前**的数组：`savedIndex` 在 `[0, saved.size())` 才取该元素作为选中项，因此过滤后可能无选中（`PlaybackQueue.cpp:412-414`）。
- 兼容旧存档字段 `deferred: true`：该项不进入完整队列，但其 id 仍加入待补全列表；当前实现**只读不写**该字段（`PlaybackQueue.cpp:402-411,420-422`）。
- `current` 非空时：`kind` 必须是 `song`，且 `provider`（缺省为当前 API provider）必须等于当前 provider；否则**队列也不恢复**（`MusicPlayer.cpp:773-776`，校验在 `queue.restore` 之前）。
- 恢复顺序固定：先 `queue.restore`，再按身份选曲/播放（`MusicPlayer.cpp:777-779`）；损坏索引不能让“下一首”跳到无关位置。
- `queue.restore` 的第三个参数是 `!m_host->playbackConnection()`：只有 GUI 独占时才在本地补全曲目详情（`MusicPlayer.cpp:770,778`）。

## 4. `playback-session.json`

后台播放服务独立持久化，避免 GUI 进程被杀导致队列丢失。

### 4.1 内容

文件本身就是 §3 的 player 对象：`current`、`queue`、`index`、`mode`、`position`、`requested`、`preview`。**没有** `version` 包装，也**没有** `player` 外层（`PlaybackService.cpp:442-443`）。

### 4.2 读取与 legacy 兼容（`PlaybackService.cpp:419-436`）

1. `offline` → 不恢复。
2. 先看 `dataDirectory()/playback-session.json`。
3. **仅当该文件不存在**（`!file.exists()`）时回退到 `dataDirectory()/session.json`，标记 `legacy = true`，取顶层 `player` 对象（`:425-433`）。
4. 文件可打开且 `size <= 64 MiB` 才解析；`legacy` 时取 `saved["player"]`，否则整个对象就是 player（`:429-434`）。
5. 结果交给 `MusicPlayer::restoreSessionState`（§3 规则，含 position 门禁）。

**既有行为，不得“顺手修正”：** 若 `playback-session.json` 存在但打不开或超 64 MiB，**不会**回退到 `session.json`——回退只由“文件不存在”触发。改为条件回退会改变状态来源。

### 4.3 保存（`PlaybackService.cpp:438-448`）

- `offline` → 不写。
- 目标 `dataDirectory()/playback-session.json`；compact player JSON。
- 仅当 `bytes.size() <= 64 MiB` 且 `open` 成功且 `write` 长度相等时才 `commit()`；**`commit()` 的返回值被忽略**（Qt 无警告）。Flutter 可保留同样语义，但不得把 player 写进 `session.json` 代替。

### 4.4 进程边界

- `playback-service.lock` 是 `QLockFile` 单实例锁（`playback_main.cpp:61`）；不是用户数据，不得当作会话备份或在迁移时删除。
- 前台 GUI 存在 `playbackConnection()` 时，GUI 不重复恢复 player（`MusicSession.cpp:263-265`），且不覆盖播放器音量（`NativeApplication.cpp:61-63`）。播放状态权威在后台服务；Flutter 必须按同一所有权划分，避免两进程同时写/恢复 player。

## 5. `panel/*` QSettings 契约

### 5.1 存储位置与形态

- `AppStorage::settings()`（`AppStorage.cpp:106-115`）：Android 走 `QSettings()` **默认构造**（无 portable 根）。
- QSettings 身份由 `main.cpp:878-882` 在创建应用实例前静态设定：`setOrganizationName(AppIdentity::Organization)`、`setOrganizationDomain(AppIdentity::Id)`、`setApplicationName(AppIdentity::Id)`。取值：`Organization = "RhineMusicDatabase"`（`AppIdentity.h:6`），`Id = RHINE_APPLICATION_ID = "rhine.music.database"`（`AppIdentity.h:5`、`CMakeLists.txt:22`）。因此组织名与应用名/域都是同一命名空间。
- 键名形如 `panel/<key>`：读取 `AppStorage::settings().value("panel/" + key).toString()`（`Host.cpp:1075`），写入 `setValue("panel/" + key, value)`（`Host.cpp:1095`）。
- **不得猜测** QSettings 的绝对路径、文件名或 INI 转义细节；Android 上实际落点必须在设备上记录（DEVICE_BLOCKED），并用 Qt 生成的真实文件做往返验证。Flutter 若改用 `shared_preferences`/自建 JSON，会读不到 Qt 的键，等价于设置全丢，禁止直接替换。

### 5.2 53 个白名单键（精确冻结）

来源是 `Host.cpp:1038` 起匿名命名空间内的**文件级自由函数** `const QStringList &preferenceKeys()`（`:1041-1059`，**不是 `Host` 成员函数**），读写**共用同一份名单**：

```text
search-history
play-history
local-cover-cache
theme
motion
startup-animation
detail-autoplay
single-play-mode
disc-rotation
scene-enhancement
archive-mask-strength
graphics-backend
gpu-index
vsync
supersample
render-scale
aa-mode
aa-scale
msaa
fsr-quality
fsr-sharpness
fg
close-behavior
auto-update
volume
quality
alternate-source
provider
lyrics-cache
lyrics-global-offset-ms
welcome-name-netease
welcome-name-qq
welcome-name-kugou
account-id-netease
account-id-qq
account-id-kugou
kugou-edition
desktop-lyrics
desktop-lyrics-size
desktop-lyrics-translation-size
desktop-lyrics-opacity
desktop-lyrics-line-color
desktop-lyrics-translation-color
desktop-lyrics-line-weight
desktop-lyrics-translation-weight
desktop-lyrics-line-outline
desktop-lyrics-translation-outline
desktop-lyrics-line-outline-color
desktop-lyrics-translation-outline-color
welcome-name-kugou-standard
welcome-name-kugou-lite
account-id-kugou-standard
account-id-kugou-lite
```

计数恰为 **53**（本仓库核对：`Host.cpp:1042-1057`）。

### 5.3 读写规则

- 读取（`Host.cpp:1061-1076`）：`offline` 或键不在白名单 → 空串；键缺失 → 空串。**没有默认值文件，也不在首启写入默认值。**
- 写入（`Host.cpp:1077-1106`）：仅当非 `offline`、键在白名单、且 `value.size() < 262144` 时写 `panel/<key>`；否则静默丢弃。
  - `262144` 是 `QString::size()`，即 UTF-16 code unit 计数，**严格小于**；不是 UTF-8 字节数。
  - `fg` 写入后额外调用 `RhineFg::applyInterpolationPreference(value)`（`:1099-1101`）；`kugou-edition` 在 Host 构造时决定酷狗版本；`graphics-backend` 由启动图形设置读取；`close-behavior` 由桌面托盘读取。
  - 读写名单必须同一份：读取白名单与写入白名单分叉会造成“设置写完立刻回弹”（源码注释 `Host.cpp:1039-1040`）。Flutter 必须以本节 53 键为唯一名单。
- 值统一按字符串存取（`toString()`/`setValue(QString)`）；调用方自行解释布尔/数字（例如 `"off"`、`"0.7"`）。不得把私有类型编码写进 QSettings。

### 5.4 与会话的身份耦合

`panel/provider`、`panel/kugou-edition`、`panel/account-id-*` 决定 §2.4 的 library 身份门。迁移必须原样保留；不得在首启把缺失的 provider 落盘成 `netease`（Qt 只在内存中回退）。若这些键不可读，按 BLOCKED 处理，而不是静默重登。

## 6. 凭据契约

### 6.1 位置、格式与写入方式

- Android/Linux：`dataDirectory()/account.credential`（`PlatformAndroid.cpp:13-15`、`PlatformLinux.cpp:17`），UTF-8 compact JSON 对象。
- Windows：`dataDirectory()/account.dpapi`（DPAPI，`PlatformWindows.cpp:24`）。
- **Android 写入是原地非原子的**（`PlatformAndroid.cpp:26-42`）：
  1. `mkpath` 目录，失败 → 返回文案 `登录成功，但 Android 凭据当前不可写`；
  2. `QFile::open(WriteOnly | Truncate)` —— **先截断再写**，中途失败会留下半截文件；
  3. `write(bytes)`，随后 `close()`；
  4. 无论写入是否完整，都显式 `QFile::setPermissions(ReadOwner | WriteOwner)`，即 **0600**（`:40`）；
  5. 只有 `written == bytes.size()` 才返回空（成功），否则返回同一失败文案。
  源码注释明确：不依赖 `0666 & ~umask` 的默认值，写完后显式收紧权限（`:33-34`）。**Flutter 的原子写入是增强，不是 Qt 现状**；两种写法都必须保持 0600 与 Qt 可读。
- 内容是一个 cookie 对象，至少包含：
  - `qqmusic_session`：QQ 会话 token 字符串（`Host.cpp:552,620,632`）；
  - `MUSIC_U`：网易云 token 字符串（`Host.cpp:552`）；
  - `__qqSessions`：QQ 附加会话对象（`Host.cpp:621,633`）；
  - `__kugou`：对象，键为 `standard`/`lite`，值为该版本凭据对象，至少含 `token`（字符串）与 `userid`（`toString().toULongLong()`，`Host.cpp:548-550`）。
- **其他未知 cookie / 嵌套字段必须原样保留**：`acceptCookies` 直接按名字写回顶层键（`Host.cpp:518-524`），保存的是整个对象，不做字段白名单裁剪。

### 6.2 安全等级（必须如实记录）

Qt Android **不是** Android Keystore / 系统钥匙串：它是应用私有目录里的普通文件 + 0600 权限。源码注释明确说明“Android 的 per-app 沙箱已经隔离了其它应用，0600 只是把同一 uid 下的其它进程也挡在外面”（`PlatformAndroid.cpp:11-12,33-34`）。契约不得声称“已使用系统安全存储”。Flutter 若引入 Keystore/EncryptedSharedPreferences，属于增强分支，必须满足 §6.3。

### 6.3 Flutter 安全存储分支（发布门）

只允许两种实现：

- **A. 兼容文件分支（P0 默认）**：继续读写同一 `account.credential`，JSON 结构与 0600 权限不变。写入**可以**改为同目录临时文件 + 原子 rename（这是对 §6.1 非原子现状的增强），失败保留旧文件，成功后权限 0600。此分支不新增存储结构，Qt 可回读。
- **B. 系统安全存储分支**：仅当签名/Keystore 在目标构建可用且经过设备验证时启用。必须：
  1. 首启读取 legacy 文件并导入安全存储；
  2. 写入后读回比对，确认完整；
  3. 确认成功前**保留** legacy 文件，绝不删除；
  4. 安全存储不可用、读回不一致、签名不可达 → 保留 legacy，返回与 Qt **完全相同**的失败文案 `登录成功，但 Android 凭据当前不可写`，不得把用户置为未登录；
  5. 回滚时 Qt 仍能读到 legacy 文件（因此 B 不能提前删除它）。
- 若 B 无法满足上述任一条：**停止发布门**，输出迁移计划（导出/导入、回滚、验证步骤），不得带病上线。缓存可重建不是删除凭据或用户数据的理由。

### 6.4 读取与失败语义

- 启动时仅在 `!offline && !remote` 时读取凭据（`Host.cpp:62-66`）。
- 文件缺失、打不开、JSON 非法 → `QJsonDocument::fromJson(...).object()` 得到空对象；**不得删除文件、不得清空 account-id 键、不得自动登出**。
- 凭据存在性 `hasCredential()`（`Host.cpp:541-553`）：
  - `qq`：`qqmusic_session` 非空；
  - `netease`：`MUSIC_U` 非空；
  - `kugou`：`__kugou[当前 edition].token` 非空**且** `userid > 0`（`toULongLong()`）；
  - 其他任何值 → false（含 `local`/`siren`）。
- `authenticated()` 即 `hasCredential(provider)`（`Host.cpp:538-540`）。

### 6.5 退出登录（逐来源精确语义）

`Host::logout()`（`Host.cpp:609-662`）先 `mediaControl("stop")`（`:618`），再按当前 provider 分派：

| 当前 provider | 删除 | 保留 | 文件处理 |
|---|---|---|---|
| `qq` | `qqmusic_session`、`__qqSessions` | `MUSIC_U`、`__kugou` 及其他 | `cookie.isEmpty()` → 删文件；否则保存 |
| `kugou` | 仅 `__kugou[当前 edition]` | 另一 edition 的 `__kugou` 项、QQ/网易 token | `__kugou` 变空则删该键；对象空 → 删文件；否则保存 |
| 其余（含 `netease`） | 除下列三项外的所有 cookie | `__kugou`、`qqmusic_session`、`__qqSessions` | 对象空 → 删文件；否则保存 |

- 只删除**当前来源**的凭据：酷狗删的是当前 edition 的 token，不删两个 edition（`:622-629`）；QQ 不碰网易与酷狗（`:619-621`）。
- 最后一步仅在 `!offline` 时执行：空对象 → `platformDeleteCredential()`，否则 `saveCredential()`（`:655-661`）。
- 上层 `MusicLibrary::logout()`（`MusicAccount.cpp:669-717`）在此之外还会：`player.stop()`、`player.clearHistory()`、`setPreference("play-history", "[]")`（`:680-682`）、逐层 `leaveDirectory()`（`:683-685`）、`cancelLogin()`、清 liked 游标与个人列表（`:700-711`）、`setPreference("account-id-" + accountKey(), "")`（`:697`）、`musicClearRequested`（`:712`）。本地/收藏来源直接返回（`:671-673`）。
- **不删除**：`collections/`、session.json、playback-session.json、`*device.json`、其他来源的 `account-id-*`。
- 迁移实现不得提供“清空所有账号数据”作为默认登出路径。

### 6.6 Cookie 更新

`Host::acceptCookies()`（`Host.cpp:501-530`）：先按 `epoch` 门禁丢弃过期响应（`:507-509`）；把 `privateCredentials` 中当前 edition 的凭据写回 `__kugou[edition]`（`:511-517`）；按 `QNetworkCookie::parseCookies` 合并 Set-Cookie 到顶层，`changed` 只在值真的变化时为真（`:518-525`）；**仅当 `changed` 且 `hasCredential(qq|netease|kugou)` 为真**才 `saveCredential()`（`:526-529`）。Flutter 必须保留“只在有效凭据存在时落盘”，避免把退化 cookie 写成已登录。

## 7. 设备身份

- QQ：`dataDirectory()/qq-device.json`；酷狗：`dataDirectory()/kugou-device.json`。
- 由 Node 协议进程通过环境变量读取（Android：`BridgeProcessAndroid.cpp:202-206`；桌面：`Host.cpp:380-382`）：
  - `RHINE_QQ_DEVICE_STATE_PATH`
  - `RHINE_KUGOU_DEVICE_STATE_PATH`
  - `RHINE_KUGOU_EDITION`（`standard`/`lite`）
- 酷狗**只有一份** `kugou-device.json`，不是 `kugou-device-standard.json` + `kugou-device-lite.json`；edition 只切换 token 与协议模块，不切换设备身份（源码注释 `Host.cpp:379`、`:575-577`）。
- 设备身份是上游风控/登录稳定性的一部分，迁移时必须原样保留，不得重新生成、不得改名、不得删除。更换设备身份可能导致重新验证/风控，属于用户可见回归。
- Android 上 `TMPDIR` 用外部缓存目录（`CacheLocation`），仅当其为空时回退 `temporaryDirectory()`（`BridgeProcessAndroid.cpp:194-200`）；设备文件本身必须在 `dataDirectory()`，不得放进 cache/temp。

## 8. 本地收藏（siren）

只有 siren 来源创建 `LocalCollections`（`MusicLibrary.cpp:26-30`、`MusicAccount.cpp:287-293`），其存储根默认 `dataDirectory()/collections`，文件名为 `<provider>.json`（`LocalCollections.cpp:13-21`）：

```text
dataDirectory()/collections/siren.json
```

Schema（`LocalCollections.cpp:36-85`）：

```json
{"version":1,"provider":"siren","liked":["track-id"],"playlists":[{"id":"uuid","name":"name","createdAt":0,"trackIDs":["track-id"]}]}
```

规则：

- 读取上限 **16 MiB**：`!file.open() || file.size() > 16*1024*1024` → 视为空（`:40-42`）。
- `version != 1` 或 `provider` 不匹配 → 视为空，**不删文件**（`:44-46`）。
- `liked` / `playlists[].trackIDs` 的字符串去重且忽略空串（`strings()`，`:23-34`）；`name` 读取时 `trimmed()`，空 `id`/空 name 的歌单整条丢弃（`:50-54`）。
- 歌单按 `createdAt` **降序**稳定排序（`:60-70`）。
- 写入 `QSaveFile` 原子替换；`mkpath` 或 `open` 失败返回假（`:73-85`）。
- 新建歌单（`:178-190`）：`title = name.trimmed()`，要求非空、`title.toUcs4().size() <= 100`、现有歌单数 `< 200`；否则返回空对象。新歌单用 `QUuid`（无花括号）作为 id，`createdAt` 为毫秒时间戳，并 **prepend** 到列表（内存中即最新在前）。重命名同样是 `trimmed()` + ≤100 ucs4（`:192-203`）。
- `liked` 与歌单 `trackIDs` 的**存储顺序是“旧→新”追加**；读取 `likedIDs()`（`:87-94`）与 `tracks()`（`:164-176`）时反转为“新→旧”。
- 这是用户数据：任何缓存清理、迁移、重登都不得删除。

## 9. 缓存、临时文件与清理边界

- 可重建：`cacheDirectory()/qml`、`cacheDirectory()/shaders`、`cacheDirectory()/metadata`、`cacheDirectory()/media-cover.png`、`dataDirectory()/resources` 解包产物、`temporaryDirectory()`。
- `Host::clearCache()`（`Host.cpp:1026-1037`）执行两件事：
  1. `invalidateMetadata()`（`:1010-1023`）：自增 `metadataRevision`、清内存 `cache`，非 offline 时删除 `cacheDirectory()/metadata` 下所有 `*.json`（`:1020-1023`）；
  2. 递归删除 `cacheDirectory()/qml` 与 `cacheDirectory()/shaders`（`:1033-1036`）。删除失败（如文件占用）不影响本次清理。
- 因此清单是 **qml 目录 + shaders 目录 + metadata/*.json**；`media-cover.png` 不在清理范围。
- 清缓存**绝不能**触碰：session.json、playback-session.json、playback-service.lock、account.credential、collections/*、qq-device.json、kugou-device.json、panel/* 键。
- 不得为了“清干净”删除 `dataDirectory`。

## 10. 迁移、首启与回滚

1. **只读首启**：Flutter 首次运行读取 Qt 文件；解析/身份门失败时按无状态启动，但保留文件。只有用户产生新状态并触发正常保存时，才允许原子覆盖 `session.json`。
2. **不改名/不搬家**：不创建 session 备份文件、不移动 collections、不把 credential 转成新路径。安全存储分支（§6.3 B）保留 legacy 文件，不构成“搬家”。
3. **不预写默认值**：panel 缺失键保持缺失；provider 的内存回退 `netease` 不落盘。首启判定依赖多个键同时为空（`NativeApplication.cpp:47-54`：`startup-animation`、`theme`、`provider`、`volume` 全空才算首启），预写默认值会改变首启行为。
4. **版本保持 1**：Flutter 不得提升 session/collections/credential 的版本号；需要新字段时先扩展本契约并保证 Qt 忽略。
5. **回滚**：任何时刻 Qt 应能读取 Flutter 写出的文件；因此 compact JSON、字段类型、0600 权限、原子替换必须保持。
6. **失败即停**：若无法复现目录/QSettings 文件/凭据权限中的任一项，发布门 BLOCKED；不允许“先上线再补”。

## 11. 验收与测试映射

| 计划项 | 产物 | 断言 |
|---|---|---|
| T07 逐文件逐键冻结（plan:445） | 本文 §1-§5 | 53 个 panel 键、session 顶层 4 键、library 全字段、view 16 字段、夹取/白名单/64 MiB |
| T07 playback/device/panel（plan:446） | 本文 §4、§5、§7 | playback 优先 + 仅“文件不存在”时 legacy player 回退；两个设备文件；panel 是 QSettings 键不是文件 |
| T07 凭据安全分支（plan:447） | 本文 §6 | 0600 非原子现状、A/B 分支门禁、逐来源登出、无默认登出、用户数据不删 |
| T07 fixture + test（plan:444,448） | `test/fixtures/session_view.json`、`test/session_schema_test.dart` | view 16 字段、非法字段丢弃、数值夹取、>64 MiB 不覆盖旧档 |

补充静态验收（**不执行**，按用户禁令；本原子只交付 doc）：

- 测试代码中 `sessionLimitBytes == 64 * 1024 * 1024`；超限路径先返回、后写盘。
- view 归一化输出键集合恰好等于 §2.3 的 16 键，顺序固定。
- `panelKeys.length == 53` 且与 §5.2 逐项相等；值长度 262143 可写、262144 不可写。
- 登出测试覆盖 qq / kugou（两 edition）/ netease 三组保留关系。
- 所有文件操作测试只在 `Directory.systemTemp` 下进行，不触碰真实 `dataDirectory`。

## 12. 设备不可证项（DEVICE_BLOCKED）

以下不能在当前环境（禁止 adb/安装/运行/构建）证明，必须在设备或发布门补证；未补证前不得声称通过：

1. Qt `AppLocalDataLocation` 与 Flutter 目录 API 的绝对路径一致（§1）。
2. QSettings 在 Android 上的真实文件名、编码/转义、53 键往返（§5.1）。
3. `account.credential` 写入后的实际权限位与崩溃/半写恢复行为（§6.1）。
4. Qt 生成的 session/playback/collections 真实文件与 Flutter 读写往返（含 64 MiB 边界）（§2.5、§4.3、§8）。
5. Keystore/签名可用性与安全存储迁移读回（若选 §6.3 B 分支）。
6. SIGKILL 下 15 秒保存节拍的实际丢失窗口（§2.5）。

## 13. 证据索引（基线 8ed3067b0812eb2612f7841ec127a6e8ca93231b）

| 主题 | 位置 |
|---|---|
| 目录解析 | `Qt/src/AppStorage.cpp:33-57,59-71,73-82,84-93,95-104,106-115` |
| QSettings 身份 | `Qt/src/main.cpp:878-882`、`Qt/src/AppIdentity.h:5-8`、`CMakeLists.txt:22` |
| 偏好白名单/读写 | `Qt/src/Host.cpp:1038-1059,1061-1076,1077-1106` |
| 缓存清理 | `Qt/src/Host.cpp:1010-1023,1025-1037`、`Qt/src/main.cpp:1234`（仅 Windows）、`Qt/src/render/VulkanPresentationBackend.cpp:34` |
| 凭据读写/存在性/登出/cookie | `Qt/src/PlatformAndroid.cpp:11-46`、`Qt/src/PlatformLinux.cpp:17`、`Qt/src/PlatformWindows.cpp:24`、`Qt/src/Host.cpp:59-66,501-530,538-553,599-605,609-662` |
| 设备身份 | `Qt/src/Host.cpp:379-382,575-577`、`Qt/src/BridgeProcessAndroid.cpp:194-206` |
| session 顶层/view/保存 | `Qt/src/MusicSession.cpp:215-235,237-267,269-284` |
| library 字段与恢复 | `Qt/src/MusicSession.cpp:12-31,33-86,88-213` |
| 启动顺序与保存节拍 | `Qt/src/NativeApplication.cpp:44-90` |
| player 对象与队列 | `Qt/src/MusicPlayer.cpp:749-758,760-780`、`Qt/src/PlaybackQueue.cpp:14-38,398-422` |
| playback 服务 | `Qt/src/PlaybackService.cpp:419-448`、`Qt/src/playback_main.cpp:61` |
| 本地收藏 | `Qt/src/LocalCollections.cpp:13-21,23-34,36-71,73-85,87-94,164-176,178-203,215-251` |
| 身份键/accountKey | `Qt/src/MusicLibrary.cpp:18-30,169-171`、`Qt/src/MusicAccount.cpp:61-72,94-111,669-717` |
| 设置滚动上限 | `Qt/src/NativeHud.h:114-118,132-135` |
| 计划映射 | `docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:443-450` |

## 14. 本原子边界（T07-C01-M12）

- 本文件是**唯一**写域产物；`test/fixtures/session_view.json` 与 `test/session_schema_test.dart`（plan:444）属于后续原子，本文件只给出断言要求（§11）。
- 本原子**未执行**任何 `flutter build/test/analyze/run`、`dart test/analyze`、Gradle、`pub get`、格式化/代码生成/验证脚本、Qt 编译运行、adb 或设备操作；§11 的静态断言为待执行清单，RED/GREEN 均未运行。
- 读域中列出的 `Qt/src/PanelPreferences.cpp` 在本基线**不存在**；偏好实现实际在 `Qt/src/Host.cpp`（`preferenceKeys()`/`preference()`/`setPreference()`），本文件按实际源码取证。其余读域文件均已存在并核对。
