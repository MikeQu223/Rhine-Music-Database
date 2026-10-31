# 各平台异常返回排障手册

## 1. 错误是怎么到界面上的

一次请求的完整链路：

```
Qt MusicApi::request / call
  -> Host 请求层（缓存、合并、限流、30 秒超时、Node 子进程）
  -> MusicBridge/worker.cjs（私有 IPC）
  -> 平台协议层：网易云内置接口 / qq.cjs 回环服务 / kugou.cjs 锁定上游
  -> 回包原路返回
```

界面上的文案只有四种来源：

1. **Host 层固定文案**：子进程退出、超时、限流、临时目录失败等，不带平台码。
2. **`MusicApi` 拼装**：`api.request` 路径遇到未允许的 `code` 时显示
   `<平台>返回 <code>：<message>`（`Qt/src/MusicApi.cpp:111`）。
3. **适配层原文**：`api.call`（`/native/<平台>/<操作>`）与 Node 适配层抛出的错误，
   界面直接显示 message，例如 `QQ 音乐返回 -1`、`酷狗搜索需要登录…`。
4. **登录专用文案**：`loginFailureMessage` 把 QQ 扫码失败的诊断字段翻译成中文
   （`Qt/src/MusicAccount.cpp:9`）。

判断顺序：先看文案属于哪一种，再决定查进程、查网络还是查账号。

## 2. 通用层错误（三平台适用）

| 界面文案 | 触发位置 | 含义 | 处理 |
| --- | --- | --- | --- |
| 音乐服务已退出，请重试 | `Qt/src/Host.cpp:102` | Node 子进程退出时还有请求在等待 | 点重试会重新拉起；反复出现见第 8 节 |
| 音乐服务组件缺失，请重新构建应用 | `Qt/src/Host.cpp:76` | `node`/`node.exe` 不存在或无法执行（FailedToStart） | 安装包不完整，重新解压或重新构建 |
| 无法创建音乐服务临时目录 | `Qt/src/Host.cpp:325` | `data/temp` 不可写（Windows 绿色版目录只读） | 换到可写目录 |
| 音乐请求超时，请重试 | `Qt/src/Host.cpp:383` | 请求 30 秒没有回包 | 网络或上游挂起；与“已退出”不同，进程还活着 |
| 音乐服务提示访问频繁，已暂停该平台的新请求；缓存仍可浏览 | `Qt/src/Host.cpp:294` | 上游回 `405/429/509` 或消息含“频繁”，该平台被暂停至少 120 秒 | 等待，或检查账号风控；只影响排队请求（缓存读取、取播放地址） |
| 本地模式已禁用在线平台操作 | `Qt/src/Host.cpp:188` | 当前来源是本地音乐 | 切回在线来源 |
| 元数据格式无效 | `Qt/src/MusicApi.cpp:103` | 回包不是对象或缺少 `body` | 桥接或上游协议异常，记录平台与操作 |
| Offline: no local fixture for … | `Qt/src/Host.cpp:317` | 离线测试模式没有对应 fixture | 仅测试环境 |

补充：

- `MusicApi` 在回包缺少 `code` 字段时按 `200` 处理，只有非 200 且不在允许集合里才会报错。
- `Host` 的限流暂停只作用于进入队列的请求（可缓存的元数据、`/song/url`），
  非缓存请求仍然直接发往桥接。

## 3. 网易云音乐

### 3.1 状态码

| code | 含义 | 界面表现 |
| --- | --- | --- |
| 200 | 成功 | 正常 |
| 301 | 未登录或登录状态无效 | 恢复账号时视为“登录已失效，请重新登录” |
| 400 | 参数或请求错误 | 网易云音乐返回 400：<上游消息> |
| 401 | 凭据失效 | 登录已失效，请重新登录 |
| 405 / 429 / 509 | 限流或风控 | 触发第 2 节的平台暂停；消息含“频繁”同样触发 |
| 500 | 上游异常 | 网易云音乐返回 500：<上游消息> |
| 800 | 二维码过期或登录失败 | 二维码已过期，请重新生成 |
| 801 | 等待扫码 | 请用网易云音乐扫描并确认登录 |
| 802 | 已扫码待确认 | 已扫描，请在手机上确认 |
| 803 | 授权成功 | 换取账号信息后完成登录 |

二维码轮询允许的集合是 `{800, 801, 802, 803}`（`Qt/src/MusicAccount.cpp:585`），
其他码会直接显示 `网易云音乐返回 <code>：<message>`。

### 3.2 常见业务文案

| 文案 | 来源 | 说明 |
| --- | --- | --- |
| 此歌曲暂无可用音源，请登录或在网易云打开 | `MusicBridge/client/netease.mjs:80` | `/song/url/v1` 回包没有 url |
| 歌曲已不可读取 | `MusicBridge/client/netease.mjs:165` | 歌曲详情为空 |
| 未找到喜欢的歌曲歌单，请刷新个人音乐 | `MusicBridge/client/netease.mjs:308` | 账号资料缺少“我喜欢的音乐” |
| 喜欢的歌曲顺序暂时无法读取，请重试 | `MusicBridge/client/netease.mjs:312` | likelist 顺序异常 |
| 旧二维码取消失败，请稍后重试 | `Qt/src/MusicAccount.cpp:473` | 上一个二维码取消没有确认成功 |
| 二维码生成失败 | `Qt/src/MusicAccount.cpp:499` | 回包缺少 `unikey` |

## 4. QQ 音乐

### 4.1 扫码登录状态

允许集合同样是 `{800, 801, 802, 803}`。800 会附带诊断字段：
`failureStage`、`failureReason`、`errorKey`、`upstreamErrorKey`、
`upstreamHttpStatus`、`upstreamCode`、`upstreamGlobalCode`、`upstreamSubCode`、`retryAfterMs`。

`loginFailureMessage`（`Qt/src/MusicAccount.cpp:9`）的翻译规则：

| 条件 | 文案 |
| --- | --- |
| upstreamCode 20279 或 errorKey `auth.device-limit` | 登录设备数量已达上限，请在 QQ 音乐设备管理中删除无用设备 |
| upstreamCode 50006 | 请使用手机 QQ 扫描手机 QQ 通道二维码，再尝试登录 |
| errorKey `auth.rate-limited` 或 upstreamCode 104604 | QQ 登录操作过于频繁，请等待冷却后重试 |
| errorKey `auth.account-restricted` | 账号当前受限，请在 QQ 音乐客户端检查 |
| errorKey `auth.account-banned` | QQ 返回账号被封禁，请在官方客户端核实 |
| errorKey `auth.account-binding` | 账号绑定状态异常，请在 QQ 音乐客户端检查 |
| failureReason `qr-timeout` | 二维码已过期，请重新生成 |
| failureReason `user-canceled` | 已取消扫码登录 |
| failureStage `credential-validation` | 登录凭证验证失败，请重试或检查设备管理 |
| failureStage `credential-exchange` | 扫码授权交换失败，请重试或检查设备管理 |
| failureStage `mqtt-listener` | 扫码连接中断，请检查网络后重试 |
| failureReason `session-busy` | 扫码授权仍在处理中，请等待 |
| code 429 或 failureReason `local-backoff` | 扫码登录暂时冷却 |
| code 401 | QQ 登录已失效，请重新扫码 |
| code 800（未命中以上） | 二维码会话已失效或登录失败，请重新生成 |
| 其他 | 扫码登录失败，请稍后重试 |

冷却来自 `retryAfterMs`，界面显示“（请等待 N 秒）”，冷却只保存在内存中，重启应用即清除。

### 4.2 已登记的上游码

来自 `MusicBridge/node_modules/@yakult-green-tea/qq-music-api/dist/src/protocol/businessCodes.js`：

| 码 | 场景 | 含义 |
| --- | --- | --- |
| 20279 | 扫码换凭证 | 登录设备数达上限 |
| 20277 / 20278 | 扫码换凭证 | 账号受限 |
| 20450 | 扫码换凭证 | 账号被封禁 |
| 20272 / 20274 | 扫码换凭证 | 账号绑定异常或缺失 |
| 20261 | 扫码换凭证 | 登录参数被拒 |
| 104604 | 扫码换凭证 | 操作频繁，冷却 30 秒 |
| 50006 | 手机 QQ 扫码换凭证 | 通道不匹配，改用手机 QQ 扫码 |
| 1000 / 104400 / 104401 | 带凭证读取 | 凭据不被认可，路由回 401 |
| 2001 | 搜索 | 搜索被拒（未分类，不当成“没结果”） |
| 10 | 匿名读歌单 | 算法歌单必须带凭证 |
| 10004 | 带凭证读歌单 | 歌单不存在 |
| 80120 | 未登录读歌单 | 是否凭证失效未确认，不按 401 处理 |
| 80000 / 40000 | 收藏专辑 | 该 musicu 接口不可用，已改走旧 CGI |
| 104003 | 取播放链接 | 该音质本次没有链接（免费账号常见） |
| 22006 | 猜你喜欢 | 请求被拒（未分类） |
| 500003 / 860100005 | 每日推荐候选 | 请求被拒（未分类） |

没登记的数字一律当“未知非零码”，不推断语义。

### 4.3 桥接层状态码

`MusicBridge/qq.cjs` 对回环服务非 2xx 响应做固定映射：

| 情况 | 返回 code | 文案 |
| --- | --- | --- |
| HTTP 401 | 401 | QQ 登录已失效，请重新登录 |
| `errorKey` 为 `search.rejected` | 原状态码 | QQ 拒绝了本次搜索，请登录后重试 |
| 写操作失败 | 原状态码 | QQ 写入未确认，请先刷新列表核实结果，不要重复提交 |
| 其他非 2xx | 原状态码 | QQ 音乐暂不可用，请稍后重试 |

二维码 key/create 失败由上游 `qrServiceErrorResult` 产生状态码与 `retryAfterMs`，
但桥接层会把非 2xx 的上游原文替换成固定文案，所以界面看到的是
`QQ 音乐返回 502：QQ 音乐暂不可用，请稍后重试` 这类组合，英文原文不会到界面。

写操作网络中断或回包无法解析时固定返回 502，
文案为“QQ 写入结果未确认，请刷新核实，不要重复提交”。

### 4.4 客户端校验文案

| 文案 | 位置 | 说明 |
| --- | --- | --- |
| QQ 音乐返回 <code> | `client/qq.mjs:149`、`:157` | 顶层响应或模块内 code 不是 0/200 |
| QQ 收藏状态尚未确认，请刷新后重试 | `client/qq.mjs:409` | 写前状态读取失败 |
| QQ 歌单名称需要 1–20 字 | `client/qq.mjs:432` | 名称校验 |
| QQ 暂不支持此编辑操作 / 此类别 | `client/qq.mjs:482`、`:741` | 路由未开放 |
| QQ 未确认这首歌是可编辑的普通曲库歌曲 | `client/qq.mjs:488` | 写入目标不是普通曲库歌曲 |
| QQ 歌曲资料暂不可读取 / 歌曲暂不可读取 | `client/qq.mjs:617`、`:227` | getSongInfo 为空 |
| QQ 暂未提供可用的歌单分类 | `client/qq.mjs:669` | 分类接口为空 |
| Stale operation | 适配层通用 | 请求已被新账号或新选择作废 |

### 4.5 “QQ 音乐返回 -1”是什么

- 这句文案不是本地生成的错误码，而是 QQ 上游回包自带的 `code: -1` 被
  `client/qq.mjs` 的 `response()`/`module()` 原样带出。
- 本地代码从不产生 `-1`；`businessCodes.js` 里也没有 `-1` 的登记，属于“未登记的非零码”，
  不能推断成登录失效、限流或版权问题。
- 可能出现的操作：读歌曲详情（getSongInfo）、歌手页（getSingerHotsong/getSingerAlbum）、
  专辑信息、榜单、新歌/新专辑（getRecommend）、歌词。
- 排查时先确认范围：
  - 只有某一首歌/某位歌手/某个榜单失败 → 该条目或参数不被 QQ 接受，换条目可复现范围。
  - 所有请求都失败 → 会话、设备或出口被 QQ 拒绝；重新登录（必要时在 QQ 音乐设备管理里
    清理设备）后再试，并记录失败时的操作与账号状态。
- 如果用户只是看到“QQ 音乐返回 -1”，请同时记录：平台、版本（开发版/发布版）、
  账号是否已登录、具体页面和操作、是否必现。

### 4.6 播放相关提示

无可用 URL 时按提示键显示（`MusicBridge/client/qq.mjs:645`）：

| hint.key | 文案 |
| --- | --- |
| playback.maybe-membership | QQ 提示可能缺少会员权益，可尝试试听或在官方客户端核实 |
| playback.maybe-region-restricted | QQ 提示歌曲可能受地区限制，请在官方客户端核实 |
| playback.preview-missing | QQ 确认这首歌没有试听文件 |
| playback.preview-unavailable | QQ 暂未提供可用试听片段 |
| playback.quality-file-unavailable | QQ 未提供所选音质的文件 |
| playback.quality-detail-unavailable | QQ 无法确认所选音质的文件资料 |

没有 hint 时：已登录 → “QQ 已登录，但平台未返回标准音质音源…”；未登录 →
“QQ 当前未登录，请用 QQ 或微信扫码登录后重试”。

## 5. 酷狗音乐

### 5.1 二维码状态映射

`MusicBridge/kugou.cjs` 把上游 `data.status` 映射为：

| 上游 status | 返回 code | 含义 |
| --- | --- | --- |
| 0 | 800 | 二维码过期 |
| 1 | 801 | 等待扫码 |
| 2 | 802 | 已扫码待确认 |
| 4 | 803 | 授权成功（必须同时拿到 token 和 userid，否则回 503） |
| 其他 | 503 | 状态未知 |

### 5.2 业务与传输错误

| 情况 | code | 文案 |
| --- | --- | --- |
| 上游 `status === 0` 或 `error_code !== 0` | 502 | 酷狗接口返回错误 <N>，请检查登录或稍后重试 |
| 上游调用抛异常 | 502 | 酷狗请求失败（<error_code>）或 酷狗请求失败，请稍后重试 |
| 设备注册失败（`/register/dev`） | 503 | 酷狗设备注册失败，请稍后重试 |
| 搜索未登录 | 适配层错误 | 酷狗搜索需要登录，请先用酷狗音乐扫码 |
| 无播放地址 | 适配层错误 | 酷狗未返回可播放地址，请确认账号登录及歌曲权限 |
| 歌曲资料为空 | 适配层错误 | 酷狗歌曲资料暂不可读取 |
| 缺少“我喜欢”歌单 | 适配层错误 | 酷狗未返回“我喜欢”歌单，请从“我的歌单”浏览 |
| 收藏专辑不可读 | 适配层错误 | 酷狗 API 未提供收藏专辑读取，请从搜索或歌单浏览专辑 |

酷狗标准版与概念版凭据分开保存，切换版本后需要重新确认登录状态。

## 6. 写操作与账号状态

- 写操作串行，未登录时状态栏显示“请先登录<平台>”；
  当前服务不支持编辑时显示“<平台>当前支持读取与播放”或“当前 QQ 服务未开放此编辑功能”
  （`Qt/src/MusicMutation.cpp:82`）。
- 网易云/酷狗写操作回包内层 code 不是 200 时，状态栏显示“<平台>返回 <code>”
  （`Qt/src/MusicMutation.cpp:109`）。
- QQ 写入结果无法确认时不要重复提交：桥接会回 502 并提示先刷新列表核实。
- 401/301 会让账号进入“登录已失效”状态；QQ 的 401 还会清空收藏状态缓存，
  下次读取绕开旧缓存。

## 7. 开发版与发布版的差异（Windows 重点）

- Windows 使用绿色版目录：设置、缓存、`account.dpapi`、`qq-device.json`、
  `kugou-device.json` 都在 `<应用目录>/data` 下。
  **每解压到一个新文件夹就是一台“新设备”**：没有账号、没有缓存、设备身份也是新的。
- 覆盖旧目录不会丢 `data`，所以旧账号仍在；这就是“覆盖旧版本能用、解压到新文件夹不行”
  最常见的差异来源，先确认新目录是否重新登录过。
- macOS 使用系统数据目录（`~/Library/Application Support/RhineMusicDatabase/…`），
  开发版与发布版共享账号、设备身份和缓存；排查时不能把 Windows 的行为直接套过来。
- Windows 开发版（Debug）与发布版使用不同的可执行文件，只要从不同目录启动，
  `data` 就是各自独立的一份。

## 8. 现场采集与命令（Windows）

### 8.1 先拿到完整信息

让反馈者提供：平台、版本（开发版/发布版）、操作路径、界面完整文案（含冒号后的内容）、
账号是否已登录、是否必现、其他平台是否正常。

### 8.2 验证音乐服务本身是否正常

在 `RHINE MUSIC DATABASE` 目录（有 `resources` 的那层）打开 PowerShell：

```powershell
.\resources\MusicBridge\node.exe .\resources\MusicBridge\worker.cjs
```

启动后粘贴一行请求并回车：

```text
{"id":"1","route":"/login/qr/key","params":{},"cookies":{}}
```

- 回一行含 `unikey` 的 JSON：node、依赖、网络都正常，问题在应用拉起子进程的方式或账号。
- 直接退出或打印报错：记录报错并检查安装包完整性。

### 8.3 区分崩溃与正常退出

先在应用里复现“音乐服务已退出”，随后执行：

```powershell
Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000,1001} -MaxEvents 100 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'node' } | Format-List TimeCreated,Id,Message
```

有 `node.exe` 记录 = 真崩溃（附故障模块）；没有记录 = 被正常结束或被外部终止，
再查安全软件：

```powershell
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Windows Defender/Operational'; Id=1116,1117} -MaxEvents 50 -ErrorAction SilentlyContinue | Format-List TimeCreated,Id,Message
```

### 8.4 已知的观测盲区

- `Host` 把子进程 stderr 丢到空设备（`Qt/src/Host.cpp:355`），`finished` 处理器也不记录
  `exitCode`/`exitStatus`，所以“音乐服务已退出”目前无法从界面或日志看出原因。
- 登录诊断字段（`loginDiagnostics`）只在内存里，界面不展示、日志不落盘。
- 若要长期定位，建议在 Host 记录退出码和最后若干 KB stderr，并在性能面板或错误文案中展示
  平台、操作与上游码。

## 9. 速查表

| 现象 | 所属层 | 下一步 |
| --- | --- | --- |
| 网易云扫码时“音乐服务已退出” | Host 子进程 | 第 8.2、8.3 节 |
| “音乐服务组件缺失” | 安装包 | 确认 `resources/MusicBridge/node(.exe)` 存在 |
| “音乐请求超时” | 网络/上游 | 检查网络、代理、该平台其他请求 |
| “网易云音乐返回 301 / 401” | 账号 | 重新登录 |
| “网易云音乐返回 429”或含“频繁” | 风控 | 等待 2 分钟以上，避免连续操作 |
| 二维码已过期（三平台） | 扫码会话 | 重新生成二维码 |
| “登录设备数量已达上限” | QQ | 在 QQ 音乐设备管理里删除旧设备 |
| “QQ 音乐返回 -1” | QQ 上游未登记码 | 确认范围（单条目/全部），重新登录后复测 |
| “QQ 音乐返回 401：QQ 登录已失效” | 账号 | 重新扫码 |
| “QQ 写入结果未确认” | 写操作 | 先刷新核实，不要重复提交 |
| “酷狗接口返回错误 N” | 酷狗业务码 | 检查登录与歌曲权限，记录 N |
| “酷狗设备注册失败” | 设备注册 | 稍后重试；检查网络与设备状态 |
| 某平台全部请求失败、其他平台正常 | 平台风控/会话 | 重新登录该平台，记录失败时间 |
