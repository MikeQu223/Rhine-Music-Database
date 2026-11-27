# 迁移前后存储 diff 报告模板（T26-D01）

- 状态：**模板，未执行，未通过**。本文件只定义报告结构、逐 key 对照表与判定规则；任何实例必须由实测数据填写，不可判定项一律写 UNMEASURED，不得留空，不得猜。
- 用途：比较 Qt 侧（源）与 Flutter 侧（目标）在同一份用户数据上的读写行为差异，覆盖 session.json、playback-session.json、collections/siren.json 与 panel QSettings。
- 契约来源：docs/flutter-migration/contracts/storage.md（下称 storage）、docs/flutter-migration/contracts/domain.md §5（下称 domain）、docs/flutter-migration/contracts/settings-platform.md（下称 settings-platform）。
- 本模板不产生任何验收结论；把模板结构填满不等于 diff 通过。

## 1. 使用规则

1. 每个迁移原子一份报告实例，文件名与原子编号一致，不得多原子共用一份。
2. 只允许三种结论词：PASS、FAIL、UNMEASURED。没有实测的 key 一律 UNMEASURED，并同时列入第 8 节。
3. 任一 key 为 FAIL，报告整体 FAIL；无 FAIL 但有 UNMEASURED，报告整体 UNMEASURED，不得写 PASS。
4. 报告整体 PASS 的条件：全部 key 为 PASS、第 8 节为空、元数据完整、两个 SHA 均为完整 40 位且实测。
5. 禁止写「视觉已对齐」「1:1 完成」「无差异」这类超出本报告测量面的结论。
6. 禁止把契约文档里的默认值当成实测默认值；默认值列必须注明来源是契约行号还是实测。

## 2. 报告元数据

| 字段 | 必填 | 取值要求 | 说明 |
|------|------|----------|------|
| reportId | 是 | 例如 T26-R01 | 与原子编号区分 |
| sourceSha | 是 | 40 位完整 SHA | Qt 侧基线 commit；不得写短 SHA |
| targetSha | 是 | 40 位完整 SHA | Flutter 侧 commit；不得写短 SHA |
| capturedAtUtc | 是 | ISO 8601，带 Z | 采集开始时刻 |
| capturedAtLocal | 是 | ISO 8601，带偏移 | 设备本地时区 |
| deviceSerial | 是 | 526f6b6d 或模拟器标识 | 真机与模拟器不得混用同一份报告 |
| deviceModel | 是 | 例如 OPD2511 | 与 serial 对应 |
| androidVersion | 是 | 例如 16 / API 36 | 记录 API level |
| densityDpi | 是 | 例如 315 | 影响布局默认值 |
| physicalResolution | 是 | 例如 2880x1800 | 与方向一并记录 |
| apkSha256 | 是 | 完整 64 位 | 被测 Qt APK；见 device-2026-11-09.md:9 |
| dataDirAbsolutePath | 是 | 绝对路径 | Qt AppLocalDataLocation 与 Flutter 目录 API 必须一致（storage:501-510） |
| qsettingsIdentity | 是 | RhineMusicDatabase / rhine.music.database | storage:282 |
| collector | 是 | 人名或 agent id | 实际执行者 |
| reviewer | 是 | 人名或 agent id | 独立复核者，不得与 collector 相同 |
| toolVersions | 是 | adb / flutter / dart 版本 | 未执行则写 NOT_RUN |

元数据缺任一项：报告整体 UNMEASURED，不允许用「待补」占位后给出 PASS。

## 3. 被测文件与产物清单

| 文件 | 产生方 | 读上限 | 写上限 | 本次字节数 | 完整 SHA256 | 备注 |
|------|--------|--------|--------|------------|-------------|------|
| session.json | Qt GUI / Flutter | 64 MiB | 64 MiB | | | storage:42-57、:61 |
| playback-session.json | 后台播放服务 | 64 MiB | 64 MiB | | | storage:248-275 |
| collections/siren.json | LocalCollections | 16 MiB | 未声明 | | | storage:440-463 |
| panel QSettings | QSettings | 单值 < 262144 UCS | 同左 | 不适用 | 不适用 | Android 落点为 DEVICE_BLOCKED，storage:284 |
| account.credential | 平台层 | 未声明 | 未声明 | 不采集内容 | 不采集 | 只记录权限位；storage:361-370 |

字节数必须是实测值；未采集则整行 UNMEASURED，不得留空。

## 4. 逐 key 表（session.json）

列说明：Qt 类型是 JSON 值类型（Qt 侧用 QJsonValue 读取）；Dart 类型是 lib/data/storage/ 中的实际承载类型；「缺失行为」「类型不符行为」抄自契约与 Dart 读侧实现，二者不一致时以实测为准并记 FAIL 或 UNMEASURED。

### 4.1 顶层（4 键，storage:65-74）

| 键 | Qt 类型 | Dart 类型 | 默认/缺失语义 | 必填 | 缺失行为 | 类型不符行为 | 版本迁移 |
|----|---------|-----------|----------------|------|----------|--------------|----------|
| version | int | int | 无 | 是 | 整份不恢复 | 非数或 ≠1 → 整份不恢复；1 与 1.0 均接受（storage:73；session_store:437-442） | 否，版本恒 1 |
| library | object | Map<String,Object?> | {} | 是 | 按 {} 处理后身份门失败 | 非对象按 {}（session_store:446） | 无 |
| player | object | PlayerState | 空对象 | 是 | 不恢复播放器（session_store:462-468；domain:590） | 非对象 → 不恢复 | 无 |
| view | object | ViewState | 空对象 | 否 | 按空对象应用默认值，不使整份会话失败（MusicSession.cpp:241-262）；view 单独存在不能恢复 UI（storage:195-204） | 非对象按 {} 应用默认值（toObject） | 无 |

### 4.2 library（31 键，storage:82-114）

| 键 | Qt 类型 | Dart 类型 | 默认/缺失语义 | 必填 | 缺失行为 | 类型不符行为 | 版本迁移 |
|----|---------|-----------|----------------|------|----------|--------------|----------|
| provider | string | String | 无 | 是 | 身份门失败（provider-mismatch，session_store:540-542） | 非串 → 同左 | 无 |
| edition | string | String | 无 | 是 | 身份门失败（edition-mismatch，session_store:543-545） | 非串 → 同左 | 无 |
| uid | string | String | 空串（未登录） | 是 | 缺失或非串按空串；当前账号非空则 uid-mismatch（session_store:546-548） | 按空串 | 无 |
| sources | array，恰 5 项 | List<Object?> | 无 | 是 | 缺失、非数组或长度 ≠5 → sources-length（session_store:555-560） | 同左 | 无 |
| directories | array，≤64，root→leaf | List<Object?> | [] | 否 | 缺失或非数组 → 空 | 按空 | 无 |
| current | object | Map<String,Object?> | {} | 否 | 缺失 → {} | 非对象 → {} | 无 |
| selectedPhysical | int | int | -1 | 否 | 缺失 → -1；越界或不在 physicalSlots[lane] → selected-physical 失败（session_store:564-575） | 非数 → -1（_toIntOr） | 无 |
| selectedLane | int | int | -1 | 是 | 缺失 → -1 → selected-physical 失败；越界同样失败（session_store:569-574） | 非数 → -1 → 失败 | 无 |
| keyword | string | String | "" | 否 | 缺失或非串 → "" | 按 "" | 无 |
| searchKind | string | String | song | 否 | 缺失或非串 → song | 按 song | 无 |
| status | string | String | "" | 否 | 缺失或非串 → "" | 按 "" | 无 |
| searchLoading | bool | bool | false | 否 | 非 bool → false；真且 keyword 非空则重放搜索（session_store:494） | 按 false | 无 |
| directoryLoading | bool | bool | false | 否 | 非 bool → false；真且目录存在且 songs 空则重进，优先级高于 detailLoading（session_store:489-497） | 按 false | 无 |
| detailLoading | bool | bool | false | 否 | 非 bool → false；仅在上一支未命中且 current 非空时 choose（session_store:496-497） | 按 false | 无 |
| privateSelection | bool | bool | false | 否 | 非 bool → false | 按 false | 无 |
| searchCursor | int | int | 0 | 否 | 负数 → 0 | 非数 → 0 | 无 |
| playlistCursor | int | int | 0 | 否 | 负数 → 0 | 非数 → 0 | 无 |
| albumCursor | int | int | 0 | 否 | 负数 → 0 | 非数 → 0 | 无 |
| likedCursor | int | int | 0 | 否 | 负数 → 0 | 非数 → 0 | 无 |
| likedIDs | array 或 null | List<Object?>? | null | 否 | 缺失或非数组 → 不恢复（null） | 不恢复 | 无 |
| groupName | string | String | "" | 否 | 缺失或非串 → "" | 按 "" | 无 |
| groupIndices | array<int> | List<Object?>（元素为 int） | [] | 否 | 非数组 → []；每项负数 → 0（session_store:664-666） | 按 [] | 无 |
| groupLane | int | int | -1 | 否 | 缺失 → -1；clamp -1..4 | 非数 → -1 | 无 |
| tracks | array | List<Object?> | [] | 否 | 非数组 → [] | 按 [] | 无 |
| trackIDs | array | List<Object?> | [] | 否 | 非数组 → [] | 按 [] | 无 |
| trackCursor | int | int | 0 | 否 | 负数 → 0 | 非数 → 0 | 无 |
| albumLoaded | bool | bool | false | 否 | 非 bool → false | 按 false | 无 |
| playContext | array | List<Object?> | [] | 否 | 非数组 → [] | 按 [] | 无 |
| directoryInfo | bool | bool | false | 否 | 非 bool → false | 按 false | 无 |
| wantsSongDetails | bool | bool | false | 否 | 非 bool → false | 按 false | 无 |
| discover | object | Map<String,Object?> | 见 4.5 | 否 | 缺失或非对象 → 默认 | 按默认 | 无 |

### 4.3 sources[i]（5 键，数组恰 5 项，storage:116-124）

| 键 | Qt 类型 | Dart 类型 | 默认/缺失语义 | 必填 | 缺失行为 | 类型不符行为 | 版本迁移 |
|----|---------|-----------|----------------|------|----------|--------------|----------|
| items | array | List<Object?> | [] | 否 | 非数组 → [] | 按 [] | 无 |
| total | int | int | 取 items 长度 | 否 | 负数按 0，再取 max(len, total) | 非数按 0 | 无 |
| offset | int | int | 0 | 否 | clamp 0..max(0, len-1) | 非数 → 0 | 无 |
| more | bool | bool | false | 否 | 非 bool → false | 按 false | 无 |
| row | int | int | 0 | 否 | clamp 0..7 | 非数 → 0 | 无 |

### 4.4 directories[i]（14 键，≤64 项，root→leaf，storage:126-143）

| 键 | Qt 类型 | Dart 类型 | 默认/缺失语义 | 必填 | 缺失行为 | 类型不符行为 | 版本迁移 |
|----|---------|-----------|----------------|------|----------|--------------|----------|
| item | object | Map<String,Object?> | {} | 否 | 缺失 → {} | 非对象 → {} | 无 |
| songs | array | List<Object?> | [] | 否 | 非数组 → [] | 按 [] | 无 |
| sortField | string | String | none | 否 | 缺失或不在 none/title/album/artist → none | 按 none | 无 |
| ids | array | List<Object?> | [] | 否 | 非数组 → [] | 按 [] | 无 |
| albums | array | List<Object?> | [] | 否 | 非数组 → [] | 按 [] | 无 |
| cursor | int | int | 0 | 否 | clamp 0..ids.length | 非数 → 0 | 无 |
| index | int | int | 0 | 否 | clamp 0..max(0, songs-1) | 非数 → 0 | 无 |
| anchor | int | int | 0 | 否 | clamp 0..39 | 非数 → 0 | 无 |
| page | int | int | 由 index 重算 | 否 | 读取时忽略写入值，按 index/40*40 重算（session_store:624） | 重算 | 无 |
| parentPhysical | int | int | 0 | 否 | clamp 0..39 | 非数 → 0 | 无 |
| parentLane | int | int | 0 | 否 | clamp 0..4 | 非数 → 0 | 无 |
| parentItem | object | Map<String,Object?> | {} | 否 | 缺失 → {} | 非对象 → {} | 无 |
| albumCursor | int | int | 0 | 否 | 负数 → 0 | 非数 → 0 | 无 |
| albumsMore | bool | bool | false | 否 | 非 bool → false | 按 false | 无 |

### 4.5 discover（6 键，storage:145-154）

| 键 | Qt 类型 | Dart 类型 | 默认/缺失语义 | 必填 | 缺失行为 | 类型不符行为 | 版本迁移 |
|----|---------|-----------|----------------|------|----------|--------------|----------|
| tab | string | String | playlists | 否 | 缺失或非串 → playlists | 按 playlists | 无 |
| items | array | List<Object?> | [] | 否 | 缺失 → [] | 非数组 → [] | 无 |
| offset | int | int | 0 | 否 | 负数 → 0 | 非数 → 0 | 无 |
| more | bool | bool | false | 否 | 非 bool → false | 按 false | 无 |
| category | string | String | 全部 | 否 | 缺失或非串 → 全部 | 按 全部 | 无 |
| newSongArea | string | String | 5 | 否 | 缺失或非串 → 5 | 按 5 | 无 |

### 4.6 view（16 键，storage:158-186）

| 键 | Qt 类型 | Dart 类型 | 默认/缺失语义 | 必填 | 缺失行为 | 类型不符行为 | 版本迁移 |
|----|---------|-----------|----------------|------|----------|--------------|----------|
| mode | string | String | archive | 否 | detail 仅当 current 非空，否则 archive | 非串 → archive | 无 |
| selected | int | int | 0 | 否 | clamp 0..39 | 非数 → 0 | 无 |
| tab | string | String | overview | 否 | 白名单 overview/notes/history，其他 → overview | 按 overview | 无 |
| modal | string | String | ""（关闭） | 否 | 白名单 saved/search/discover/queue/settings/player/local，其他 → 不打开 | 按不打开 | 无 |
| queueOffset | int | int | 0 | 否 | 负数 → 0 | 非数 → 0 | 无 |
| settingsScroll | double | double | 0.0 | 否 | clamp 0..settingsScrollMaximum()，上限为运行时布局函数（storage:181-186） | 非数 → 0.0 | 无 |
| query | string | String | "" | 否 | 缺失或非串 → "" | 按 "" | 无 |
| groupBy | string | String | none | 否 | 非串 → none；空串保留 | 按 none | 无 |
| activeGroup | string | String | "" | 否 | 非串 → "" | 按 "" | 无 |
| artistTab | string | String | songs | 否 | 非串 → songs | 按 songs | 无 |
| listOffset | int | int | 0 | 否 | 负数 → 0 | 非数 → 0 | 无 |
| trackOffset | int | int | 0 | 否 | 负数 → 0 | 非数 → 0 | 无 |
| bodyOffset | int | int | 0 | 否 | 负数 → 0 | 非数 → 0 | 无 |
| musicCollection | int | int | 1 | 否 | 缺失或非数 → 1；clamp 1..4 | 按 1 | 无 |
| trackListMode | bool | bool | false | 否 | 非 bool → false | 按 false | 无 |
| lyricsMode | bool | bool | false | 否 | 非 bool → false | 按 false | 无 |

### 4.7 player（7 键，storage:223-246）

| 键 | Qt 类型 | Dart 类型 | 默认/缺失语义 | 必填 | 缺失行为 | 类型不符行为 | 版本迁移 |
|----|---------|-----------|----------------|------|----------|--------------|----------|
| current | object | Map<String,Object?> | {} | 否 | 空对象 → 只恢复队列、不选曲 | 非对象 → {} | 无 |
| queue | array | List<Map<String,Object?>> | [] | 否 | 非数组 → [] | 按 [] | 无 |
| index | int | int | -1 | 否 | 仅用于队列恢复；越界 → 无选中 | 非数 → -1 | 无 |
| mode | string | String | all | 否 | 不在 all/one/off/shuffle → all | 按 all | 无 |
| position | double | double | -1（门） | 是（门） | 缺失得 -1 → 整份 player 丢弃，mode、队列、选曲都不应用（MusicPlayer.cpp:761；playback_store:285） | 非数、NaN/Infinite、<0 或 >1e12 → 整份丢弃 | 无 |
| requested | bool | bool | false | 否 | 非 bool → false | 按 false | 无 |
| preview | bool | bool | false | 否 | 非 bool → false | 按 false | 无 |

### 4.8 collections/siren.json（storage:440-463）

| 路径 | Qt 类型 | Dart 类型 | 默认/缺失语义 | 必填 | 缺失行为 | 类型不符行为 | 版本迁移 |
|------|---------|-----------|----------------|------|----------|--------------|----------|
| version | int | 待实现确认 | 无 | 是 | ≠1 → 整份视为空、不删文件 | 同左 | 无，恒 1 |
| provider | string | 待实现确认 | 无 | 是 | ≠siren → 视为空、不删文件 | 同左 | 无 |
| liked | array | 待实现确认 | [] | 否 | 非数组 → 空 | 按空 | 无 |
| playlists | array | 待实现确认 | [] | 否 | 非数组 → 空 | 按空 | 无 |
| playlists[].id | string | 待实现确认 | 无 | 是 | 空 id → 整条丢弃 | 同左 | 无 |
| playlists[].name | string | 待实现确认 | 无 | 是 | 空 name（trim 后）→ 整条丢弃 | 同左 | 无 |
| playlists[].createdAt | int 或 string | 待实现确认 | 0 | 否 | 缺失按 0，降序排序 | 未声明 | 无 |
| playlists[].trackIDs | array | 待实现确认 | [] | 否 | 非数组 → 空；存储旧→新、读取反转 | 按空 | 无 |

Dart 侧对 siren.json 的读侧尚未在本原子核对到实现类，故类型列写「待实现确认」，不得臆造。

## 5. 失败处理矩阵

### 5.1 读取失败

| 触发条件 | session.json | playback-session.json | collections/siren.json | panel QSettings |
|----------|--------------|------------------------|-------------------------|-----------------|
| 文件缺失 | 按无会话启动，不创建文件（storage:188-204） | 仅当不存在才回落 session.json 的 player 并标 legacy（storage:260） | 视为空（storage:456-457） | 每个键读空串；无默认值文件（storage:350） |
| 存在但打不开 | 按无会话启动，保留文件（storage:218-221） | 不回退 session.json，按无播放器处理（storage:264） | 视为空、不删文件 | 单键读空串；后端异常亦为空串（preference_store:149-162） |
| JSON 非法 | 按无会话启动，保留文件（Dart invalid-json） | 解码失败 → 无播放器，不回退 | 视为空、不删文件 | 不适用（非 JSON） |
| 超过上限 | >64 MiB 按无会话启动 | >64 MiB 不解析、不回退 | >16 MiB 视为空 | 单值 ≥262144 UCS 不写出；读取未声明 |
| 未知字段 | 读忽略，下次写丢弃（storage:186） | 读忽略 | 读忽略 | 读空串 |
| 部分字段缺失 | 逐字段取默认或夹取；version 与 library 门除外 | position 门可致整份丢弃；其余逐字段默认 | 逐字段默认，空 id/name 整条丢弃 | 逐键独立 |
| 身份不符 | provider/edition/uid 任一不等 → 整份不恢复（domain:586） | current 的 kind/provider 不符 → 队列也不恢复（storage:240-246） | provider≠siren → 视为空 | 不适用 |
| 版本不符 | ≠1 → 整份不恢复（storage:73） | 无 version 字段 | ≠1 → 视为空、不删文件 | 不适用 |

### 5.2 写入失败

| 触发条件 | session.json | playback-session.json | collections/siren.json | panel QSettings |
|----------|--------------|------------------------|-------------------------|-----------------|
| 序列化失败 | 不得当作空会话写盘（storage:218-221） | 不得写空对象 | 不得写空 | 不适用 |
| 超限 | 在 open/覆盖之前判定，保留旧档并告警（storage:206-214） | 跳过 commit，保留旧档 | 未声明 | 静默丢弃（storage:351） |
| open 失败 | 告警，旧档保留 | 跳过 commit | QSaveFile 失败保留旧档 | 静默丢弃 |
| 短写 | QSaveFile commit 前校验，失败保留旧档 | 长度不等不 commit（storage:270） | 原子替换，失败保留旧档 | 不适用 |
| commit 失败 | 告警「无法保存上次会话」，旧档保留（storage:206-214） | 返回值被忽略，无告警（storage:270）——风险项，必须实测 | 原子替换失败保留旧档 | 不适用 |
| 进程被杀 | 最多丢最近 15 秒（storage:214） | 每 5 秒定时保存 + 显式退出保存；SIGKILL 最多丢约 5 秒（PlaybackService.cpp:113-115、:438-448、:451-459） | 原子替换，旧档或新档 | 落盘时序 UNMEASURED |

## 6. diff 分类

| 分类 | 定义 | 判定要求 | 本次计数 |
|------|------|----------|----------|
| added | 仅 Flutter 写出，Qt 不写 | 必须证明 Qt 读侧忽略该字段且不破坏其他字段；否则 FAIL | |
| removed | Qt 写出，Flutter 不写 | 必须证明 Flutter 读侧仍接受且不丢用户数据；否则 FAIL | |
| retyped | 同名不同类型 | 无读侧兼容证据即 FAIL；有证据记 PASS 并附证据行号 | |
| default-changed | 默认值或夹取边界不同 | 影响可见状态或数据保留即 FAIL；纯展示层可记 PASS 并说明 | |
| reordered | 仅键顺序变化 | 不算 diff：键顺序不参与语义（storage:74） | 0 |
| unkeyed | 新增/删除嵌套层级 | 按 retyped 处理 | |

每类必须给出明细表：

| key 路径 | Qt 侧 | Flutter 侧 | 分类 | 证据（文件:行号或实测产物） | 结论 |
|----------|-------|------------|------|------------------------------|------|
| （待填） | | | | | |

## 7. panel 偏好键（53 键，storage:286-346）

Qt 侧一律以字符串存取（storage:355）；「有效默认」列只在 settings-platform 有 descriptor 行时给出，否则写 UNMEASURED。键名与 descriptor id 不一致的，见第 8 节。

| # | 键（panel/ 之后） | QSettings 值类型 | 有效默认/来源 | Dart 类型 | 本次结论 |
|---|-------------------|------------------|----------------|-----------|----------|
| 1 | search-history | string | UNMEASURED | String | |
| 2 | play-history | string | UNMEASURED | String | |
| 3 | local-cover-cache | string | UNMEASURED | String | |
| 4 | theme | string | light（settings-platform:120） | String | |
| 5 | motion | string | full（:130） | String | |
| 6 | startup-animation | string | off（:140） | String | |
| 7 | detail-autoplay | string | off（:190） | String | |
| 8 | single-play-mode | string | replace（:200） | String | |
| 9 | disc-rotation | string | UNMEASURED（无 descriptor 行） | String | |
| 10 | scene-enhancement | string | UNMEASURED（无 descriptor 行） | String | |
| 11 | archive-mask-strength | string | 疑似 archive-mask 50（:210），键名不一致 → UNMEASURED | String | |
| 12 | graphics-backend | string | 空串＝默认/自动探测，Darwin metal（:220） | String | |
| 13 | gpu-index | string | ""（:230） | String | |
| 14 | vsync | string | on（:240） | String | |
| 15 | supersample | string | UNMEASURED（无 descriptor 行） | String | |
| 16 | render-scale | string | Android 75 / 桌面 100（:250；:81 注释过期） | String | |
| 17 | aa-mode | string | off（:260） | String | |
| 18 | aa-scale | string | 125（:270） | String | |
| 19 | msaa | string | 4（:280） | String | |
| 20 | fsr-quality | string | native（:290） | String | |
| 21 | fsr-sharpness | string | 50（:300） | String | |
| 22 | fg | string | off（:310） | String | |
| 23 | close-behavior | string | quit（:110） | String | |
| 24 | auto-update | string | UNMEASURED（无 descriptor 行） | String | |
| 25 | volume | string | UNMEASURED（无 descriptor 行） | String | |
| 26 | quality | string | exhigh（:160） | String | |
| 27 | alternate-source | string | 疑似 alternative off（:170），键名不一致 → UNMEASURED | String | |
| 28 | provider | string | 非法值回退 netease（storage:188-204） | String | |
| 29 | lyrics-cache | string | UNMEASURED | String | |
| 30 | lyrics-global-offset-ms | string | UNMEASURED | String | |
| 31 | welcome-name-netease | string | UNMEASURED | String | |
| 32 | welcome-name-qq | string | UNMEASURED | String | |
| 33 | welcome-name-kugou | string | UNMEASURED | String | |
| 34 | account-id-netease | string | UNMEASURED | String | |
| 35 | account-id-qq | string | UNMEASURED | String | |
| 36 | account-id-kugou | string | UNMEASURED | String | |
| 37 | kugou-edition | string | 构造期读取（storage:188-204） | String | |
| 38 | desktop-lyrics | string | 桌面歌词开关（mac/win，settings-platform:212） | String | |
| 39 | desktop-lyrics-size | string | UNMEASURED | String | |
| 40 | desktop-lyrics-translation-size | string | UNMEASURED | String | |
| 41 | desktop-lyrics-opacity | string | UNMEASURED | String | |
| 42 | desktop-lyrics-line-color | string | UNMEASURED | String | |
| 43 | desktop-lyrics-translation-color | string | UNMEASURED | String | |
| 44 | desktop-lyrics-line-weight | string | UNMEASURED | String | |
| 45 | desktop-lyrics-translation-weight | string | UNMEASURED | String | |
| 46 | desktop-lyrics-line-outline | string | UNMEASURED | String | |
| 47 | desktop-lyrics-translation-outline | string | UNMEASURED | String | |
| 48 | desktop-lyrics-line-outline-color | string | UNMEASURED | String | |
| 49 | desktop-lyrics-translation-outline-color | string | UNMEASURED | String | |
| 50 | welcome-name-kugou-standard | string | UNMEASURED | String | |
| 51 | welcome-name-kugou-lite | string | UNMEASURED | String | |
| 52 | account-id-kugou-standard | string | UNMEASURED | String | |
| 53 | account-id-kugou-lite | string | UNMEASURED | String | |

写入规则（两套实现必须一致）：非离线、键在白名单、值长度严格小于 262144 个 UTF-16 code unit；任一不满足写入失败且不报错（storage:350-355；preference_store:173-183）。读取：离线、非白名单、缺失、后端异常一律空串。

## 8. 跨源不一致与不可判定项

以下条目在契约之间或契约与 Dart 实现之间存在命名/边界差异，本模板要求逐条保留为 UNMEASURED，直至有实测或源码级对照证据。

1. archive-mask 与 archive-mask-strength：settings-platform:210 的 descriptor id 是 archive-mask，storage:286-346 的白名单键是 archive-mask-strength。命名映射未在已读材料中给出 → UNMEASURED。
2. alternative 与 alternate-source：settings-platform:170 为 alternative，storage 白名单为 alternate-source → UNMEASURED。
3. window（:100）、replay（:150）、official-player（:180）有 descriptor 行但不在 53 键白名单内 → 是否持久化 UNMEASURED。
4. disc-rotation、scene-enhancement、supersample、auto-update、volume 在白名单内但没有 Preferences descriptor 行 → 语义类型与默认值 UNMEASURED。
5. graphics-backend 的非 Darwin 默认值是空串，语义为「默认/自动探测」，不得改写成 auto（settings-platform:79）。
6. render-scale 在 settings-platform:81 的注释已过期，Android 默认以 AndroidRenderPolicy.h:106-116 的 75 为准；实测若读到 100 → FAIL。
7. settingsScroll 的上限来自运行时布局（SettingsViewportTop/Bottom、内容底 1600），不是常量（storage:181-186）；报告必须记录实测设备与实测上限，不能用默认 764 代替。
8. directories[].page 是写入字段，读取时按 index/40*40 重算（session_store:624）；diff 不把 page 差异计为语义差异。
9. QSettings 在 Android 的真实文件名、编码与 53 键往返属 DEVICE_BLOCKED（storage:284、:501-510），未实测前该节整表 UNMEASURED。
10. 进程被杀时 session.json 最多丢 15 秒（storage:214），playback-session.json 每 5 秒定时保存 + 退出再保存，丢失窗口约 5 秒（PlaybackService.cpp:113-115、:438-448、:451-459）；两者的丢失窗口不得互相套用。
11. collections/siren.json 的 Dart 读侧实现未在本次核对范围内，逐 key 类型列写「待实现确认」，不得据契约反推为已实现。

## 9. 判定与签署

| 项 | 要求 |
|----|------|
| key 计数自洽 | PASS + FAIL + UNMEASURED 必须等于本次纳入比较的 key 总数 |
| 整体结论 | 有 FAIL → FAIL；无 FAIL 有 UNMEASURED → UNMEASURED；全 PASS 且第 8 节为空 → PASS |
| 证据 | 每个 PASS/FAIL 必须附实测产物路径或文件:行号；UNMEASURED 必须写明缺什么 |
| 签署 | collector 与 reviewer 均需签名与时间；两者不得相同 |
| 禁止结论 | 视觉已对齐、1:1 完成、无差异、与 Qt 完全一致 |

## 10. 未执行清单（模板默认）

- 未执行任何 build/test/analyze/Gradle/gradlew/adb/pub get/formatter/generator/golden。
- 未生成 Qt 或 Flutter 的真实存储文件，未做任何读写往返。
- 未读取设备上的 QSettings 实体，未采集任何 SHA256。
- 本文件 0 次实测；所有结论词在实例中才有意义。

## 11. 变更记录

- 2026-11-11：T26-D01 建立模板。只定义结构、逐 key 表、失败矩阵与判定规则，未产生任何通过结论。
