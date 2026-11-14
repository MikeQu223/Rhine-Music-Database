# Rhine 插件 SDK 与适配器指南

本文件描述当前 core 与插件之间的真实契约。它同时是第三方插件的实现指南；平台特定的适配示例放在本地
`docs/PLUGIN/`（已 gitignore），不进入主仓库。

当前契约版本：

- manifest/descriptor schemaVersion：`2`
- plugin API apiVersion：`2.0`
- 运行时：桌面 bundled Node；移动端 libnode 18
- 插件入口：CommonJS 单文件 `plugin.cjs`（源码可以是 ESM，由构建器打包）

---

## 1. 当前架构

```text
Qt UI / MusicLibrary / MusicPlayer / MusicAccount / MusicMutation
        │
        │ MusicApi.call("/native/<provider>/<operation>", {args})
        │ MusicApi.request("/<provider>/<route>" 或 legacy route)
        ▼
C++ Host
  ├─ 请求队列、去重、内存/磁盘缓存、平台限流
  ├─ provider cookie/secret 切片、epoch 校验
  ├─ BridgeProcess（node worker）或移动端 worker
  └─ 响应回调、Cookie 持久化、诊断
        │
        ▼
Node worker.cjs
  ├─ /plugin/<id>/<operation>      统一 native operation
  ├─ /plugin/<id>/route/<path>     插件原始路由
  ├─ /native/<id>/<operation>      迁移期 native 路由
  ├─ <prefix>/...                  插件声明的 prefix 路由
  └─ routes.legacyRoutes           迁移期 legacy 路由
        │
        ▼
PluginRegistry
  ├─ 扫描 manifest.json
  ├─ 校验 id/apiVersion/入口/路由冲突
  ├─ 按请求 create(host)，module 本身缓存
  └─ 生成 descriptor 供 Qt 渲染（构建期/Qt 侧）
        │
        ▼
plugin.cjs: create(host) → dispatchNative / dispatchRoute
        │
        ▼
插件 transport → 上游 npm 包 / HTTP / 本地 IPC
```

Qt 侧播放服务、媒体策略和音频链路见
[docs/audio/service-chain.md](../../../docs/audio/service-chain.md)。

### 1.1 core / SDK / plugin 的边界

| 层     | 可以包含                                                        | 禁止包含                                                  |
| ------ | --------------------------------------------------------------- | --------------------------------------------------------- |
| core   | Qt 业务、Host、通用 Registry、SDK、统一模型、本地音乐、内置来源 | 第三方平台协议、上游包、平台专属文案/资产/音质 badge      |
| SDK    | Port 类型、manifest/descriptor schema、模型校验、通用工具       | 平台实现、运行时副作用                                    |
| plugin | 适配器、transport、上游依赖、平台字段归一化、平台文案/资产      | 其他 provider 的凭据、core 内部类型、直接写 stdout/stderr |

主仓库新增文件不得出现第三方平台名称。平台 descriptor、fixture、适配示例和平台特定构建资产放在
`docs/PLUGIN/` 或独立插件仓库。

### 1.2 core-only 与 full

- 默认构建是 core-only：只带本地音乐和内置来源，不包含任何第三方插件。
- `--plugins=full` 会把构建期的第三方插件打进便利产物。
- 用户安装的插件放在应用数据目录 `<data>/plugins/<id>`；用户目录中的同 id 插件优先于构建期插件。
- `<data>/plugins-state.json` 的 `{ "disabled": ["id"] }` 控制启用/禁用；禁用的插件不会出现在 Registry。
- 插件安装不验签、不建立信任链；只校验 id、manifest 结构、安全相对路径和入口存在性。
- Qt 渲染读 descriptor（构建期从 manifest 提取，或用户插件直接读 manifest）；worker 运行读同一份 `manifest.json`。
  两边必须保持一致，否则会出现“UI 显示支持、实际 dispatch 不支持”的状态。

---

## 2. 插件目录与产物

推荐源码目录：

```text
<plugins-root>/<id>/
  manifest.json              # 唯一运行/展示元数据
  index.mjs                  # runtime.sourceEntry，构建输入
  plugin.cjs                 # 构建产物，manifest.entry.file
  adapter.mjs / transport.mjs
  LICENSE
  THIRD-PARTY-NOTICES.md
  sbom.cdx.json
  ...                        # 上游运行时需要的额外文件
```

发布时只保证 `manifest.json`、`entry.file` 和 `files[]` 中列出的文件存在；源码文件可以保留在开发目录，
但不要写进市场 `files[]`，否则市场校验会把它当成运行时文件。

`manifest.runtime.sourceEntry` 是构建输入；`manifest.entry.file` 是运行时入口。构建器会把
`sourceEntry` 打成单文件 CJS，并回写 `entry.sha256` 与 `entry.size`。

---

## 3. manifest

最小示例：

```json
{
    "schemaVersion": 2,
    "apiVersion": "2.0",
    "id": "example",
    "version": "1.0.0",
    "publisher": "Example Lab",
    "entry": { "file": "plugin.cjs" },
    "display": {
        "name": "Example Music",
        "label": "EXAMPLE",
        "detail": "示例来源",
        "order": 50
    },
    "capabilities": {
        "search": true,
        "suggest": true,
        "detail": true,
        "playback": true,
        "lyrics": true,
        "account": true,
        "login": true,
        "preview": false,
        "mutations": { "likeSong": true }
    },
    "operations": {
        "search": true,
        "suggest": true,
        "songs": true,
        "detail": true,
        "playback": true,
        "lyrics": true,
        "account": true,
        "loginBegin": true,
        "loginPoll": true,
        "loginCancel": true,
        "mutate": true
    },
    "quality": {
        "default": "standard",
        "options": [
            { "id": "standard", "label": "标准", "tier": "standard" },
            { "id": "lossless", "label": "无损", "tier": "lossless" }
        ]
    },
    "login": {
        "required": false,
        "methods": [{ "id": "qr", "type": "qr", "label": "扫码登录" }]
    },
    "library": { "columns": ["搜索结果", "喜欢的歌曲"], "likedModel": "likedSongs" }
}
```

关键字段：

| 字段                  | 作用                                                                                    |
| --------------------- | --------------------------------------------------------------------------------------- |
| `id`                  | provider 唯一标识；同时用于凭据切片、路由和 `Entity.provider`                           |
| `apiVersion`          | 必须与 host 同 major 且 minor 不超过 host                                               |
| `entry`               | 运行时入口；`sha256/size` 由构建器生成，客户端不做信任校验                              |
| `files[]`             | 运行时文件清单；市场安装按 `index.json` 的 files 逐文件下载                             |
| `routes.prefixes`     | 前缀路由，例如 `/example`；Registry 负责去前缀后交给 `dispatchRoute`                    |
| `routes.legacyRoutes` | 精确 legacy 路由；用于迁移期兼容                                                        |
| `operations`          | 插件支持的 operation 白名单；插件入口应据此拒绝未声明 operation                         |
| `capabilities`        | UI/功能门控；Qt 用它决定搜索、登录、收藏、播放等入口是否显示                            |
| `display`             | provider 名称、标签、排序、默认项等展示字段；`display.default` 只能在所有插件中声明一次 |
| `variants`            | provider 变体（如 edition）及标签；对应 `variantPreference` 存储键                      |
| `library`             | 栏位、栏顺序、喜欢的模型、歌单编辑规则                                                  |
| `search`              | 查询长度、suggest、链接解析开关                                                         |
| `quality`             | 音质选项 `id/label/default/tier/badges`；实际展示档位来自插件播放结果的 canonical `tier` |
| `login`               | 登录方式、SMS flow、轮询间隔/超时、失败文案                                             |
| `discover`            | 发现页 tab                                                                              |
| `lyrics`              | 歌词来源、回退、匹配模式、限流                                                          |
| `media`               | 播放/封面 host、scheme、封面 transform                                                 |
| `externalPlayback`    | 官方客户端 URL scheme/payload/提示                                                      |
| `links`               | 官方网页模板、链接解析提示、项目链接                                                    |
| `strings`             | descriptor 驱动的 UI 文案                                                               |
| `credentials`         | 凭据命名空间、variant、inject/responseSecrets、auth 表达式、legacy 迁移、device 文件    |
| `runtime`             | hosting、diagnosticsOrdinal、env（`$variant`/`$dataDir`）                              |
| `cache`               | TTL、磁盘缓存 operation、版本、最大条目、失效事件                                       |

id 必须匹配 `^[a-z0-9-]{1,40}$`，内置来源 id 为保留 id，第三方插件不能占用。`apiVersion` 目前是 `2.0`，
新插件应声明 `"2.0"`，不要声明高于 host 的 minor。

当前运行时实际消费的字段并不等于 schema 全集：

- 已接通：`display`、`capabilities`、`operations`、`quality.id/label/default/descriptions/labels/badges`、
  `library.columns/sourceOrder/lanes/visibleLanes/identityProviders/likedModel/playlistNameMaxLength/
  playlistEditableRule/dirIdRange`、`search.maxQueryLength`、`login.methods/failureMessages/pollIntervalMs/
  pollTimeoutMs`、`lyrics.rateLimitMs/fallbackRateLimitMs`、`media`、`cache`、`credentials`、`externalPlayback`、
  `runtime.env/diagnosticsOrdinal`、`discover`、`links.webTemplates`、`strings`。
- 声明性/尚未完全接通：`quality.tier/aliases`（Qt 主要读插件播放结果的 `tier`）、
  `search.enabled/parseLinks/linkPatterns`、`network`、`limits`、`runtime.hosting/mobileBundled/bundled`
  （构建层读取 `runtime.sourceEntry/bundled`，运行时不解释）。这些字段可以写，但不要假设当前版本会自动生效。


`routes.rawRoutes` 目前只是声明性字段，worker 的原始路由入口是
`/plugin/<id>/route/<path>` 和 `routes.prefixes`；不要假设 core 会按 `rawRoutes` 自动放行。

---

## 4. 运行时入口

插件模块必须导出 `create(host, options)`：

```ts
export interface PluginModule {
    create(host: PluginHost, options?: Record<string, unknown>): PluginRuntime | Promise<PluginRuntime>;
}

export interface PluginRuntime {
    dispatchNative(operation: string, args: unknown[]): Promise<unknown>;
    dispatchRoute?(route: string, params?: Record<string, unknown>): Promise<unknown>;
    capabilities?(): Promise<ProviderCapabilities>;
    dispose?(): Promise<void>;
}
```

当前 Registry 的实际行为：

- worker 的 stdout 是 JSON-line 协议；core 在加载插件前禁用了 `console.*`。插件不得直接写 stdout/stderr，
  也不要用同步日志污染 IPC；需要诊断时只能用 `host.diagnostics.record`。
- 模块只 import 一次并缓存；**每次请求都会重新调用 `create(host)`**。
- `create` 应轻量，不要依赖跨请求单例；需要共享的缓存放在模块级变量或 transport 单例里。
- `dispatchNative` 的 `args` 是 Qt 传下来的位置参数，不是对象；插件入口应按 manifest.operations 拒绝未声明 operation。
- `dispatchRoute` 返回值是原始 body，不经过统一模型校验；只用于插件自己的原始路由/迁移 shim。
- `capabilities()` 是可选运行时方法；Qt 的能力门控以 manifest.descriptor 为准。
- `dispose()` 目前不是 core 的每请求清理钩子；不要依赖它释放每请求资源。

### 4.1 native operation 参数

| operation       | 参数                                                      | 返回                                            |
| --------------- | --------------------------------------------------------- | ----------------------------------------------- |
| `search`        | `(text, kind, offset)`，kind=`song/album/artist/playlist` | `Page<MusicEntity>`                             |
| `suggest`       | `(text)`                                                  | `string[]`                                      |
| `resolveLink`   | `(text)`                                                  | `EntityRef \| null`                             |
| `songs`         | `(ids: string[])`                                         | `Track[]`                                       |
| `detail`        | `(ref: EntityRef)`                                        | `[MusicEntity, Track[], string[]]`              |
| `artistAlbums`  | `(id, offset)`                                            | `Page<Album>`                                   |
| `trackPage`     | `(ref, offset)`，歌手页使用 `kind=artist`                  | `Page<Track>`                                   |
| `catalog`       | `()`                                                      | `Page<MusicEntity>`                             |
| `playback`      | `(track, qualityId, alternative)`                         | `PlaybackSource`                                |
| `preview`       | `(track, qualityId, alternative)`                         | `PlaybackSource`                                |
| `lyrics`        | `(track)`                                                 | `LyricsDocument \| null`                        |
| `account`       | `()`                                                      | `Account \| null`                               |
| `loginBegin`    | `(method)`                                                | `{ token, qrText?, qrImage?, pollIntervalMs? }` |
| `loginPoll`     | `(token)`                                                 | `{ code?, status?, account?, message? }`        |
| `loginCancel`   | `(token?)`                                                | 任意                                            |
| `loginSms`      | `(phone)`                                                 | 任意                                            |
| `loginSubmit`   | `(phone, code)`                                           | 任意                                            |
| `logout`        | `()`                                                      | 任意                                            |
| `userPlaylists` | `(uid?)`                                                  | `Page<Playlist>`                                |
| `likedIDs`      | `(uid?)`                                                  | `string[]`                                      |
| `likedSongs`    | `(offset?)`                                               | `Page<Track>`                                   |
| `likedAlbums`   | `(offset?)`                                               | `Page<Album>`                                   |
| `likedState`    | `(ids, uid?)`                                             | `Record<string, LikeState>`                     |
| `discover`      | `(tab, offset?, category?)`                               | `Page<MusicEntity>`                             |
| `categories`    | `()`                                                      | `{id,name}[]`                                   |
| `mutate`        | `(route, values)`                                         | `MutationResult`                                |
| `comments`      | `(track, id, sort, page, cursor?)`                        | `CommentsPage`                                  |
| `commentReplies`| `(track, id, parentCommentId, cursor?, limit?)`           | `CommentReplies`                                |
| `vip`           | `()`                                                      | `VipStatus`                                     |
| `request`       | `(route, params)`                                         | 原始上游 body（不做模型校验）                   |

平台扩展的 operation（例如 MV）可以保留，但必须写进 manifest.operations，并在 Qt 侧有对应消费方。
未知 operation 应抛 400 结构化错误，不能静默回退到其他 provider。

---

## 5. Host API

当前 Host 传入插件的是 callback 风格对象：

```ts
export interface PluginHost {
    manifest: ProviderManifest;
    cookies(): Record<string, unknown>;
    acceptCookies(values: string): void;
    receivedCookies(): string[];
    secretState(): Record<string, unknown>;
    delay(milliseconds: number, callback: () => void): void;
    authenticated(): boolean;
    env(): Record<string, string>;
    request(
        route: string,
        params: Record<string, unknown>,
        callback: (raw: string, error: string) => void,
    ): void;
    diagnostics: PluginDiagnostics;
}
```

- `cookies()` 返回当前 provider 的 cookie 切片。Host 按 manifest `credentials.inject` 注入声明的 secret 键；返回值只读，不要修改。
- `acceptCookies(JSON.stringify(lines))` 接收 Set-Cookie 行；core 会在 epoch 校验后写回当前 provider 切片。
- `receivedCookies()` 返回本次请求产生的 cookie 行，worker 会随响应交回 Host。
- `secretState()` 返回需要跨 cookie 保存的私有状态；Host 按 manifest `credentials.responseSecrets` 持久化，
  不会把私有键送回 Qt/UI。
- `env()` 返回 Host 按 `runtime.env` 展开的插件环境（`$variant`、`$dataDir`）；设备状态等私有路径用它。
- `delay(ms, cb)` 必须在 `cb` 中继续，否则请求会悬挂到超时。
- `authenticated()` 由 Host 依据 manifest `credentials.auth` 计算；它不是插件凭据的替代校验。
- `request(route, params, cb)` 回调第一个参数是原始 JSON 字符串，形如
  `{"body":..., "cookies":[...], "_epoch":...}`；`cb('', error)` 表示传输失败。
- `diagnostics.record(fields)` 只接受 number/boolean；不要上报 cookie、token、URL 或原始错误。

可选的 `MusicBridge/plugins/sdk/base-api.mjs` 提供 `request(route, values, allow=[200], valid)`：它把 callback
host 包成 Promise，非允许 code 会 reject 并附带 `safeLoginDetails`。注意它要求响应 body 是对象，无法表达
`null`/数组响应；这类上游响应应直接使用 `host.request` 或在 transport 层包装。

插件不得读取其他 provider 的 cookie；不得把原始认证记录、Set-Cookie、token 写进错误消息或日志。

---

## 6. 统一模型与校验

worker 在每个 native operation 返回后调用 `models.cjs` 的 `assertValid`，`request` 与原始路由除外。
校验失败会变成结构化错误，所以返回值必须严格符合模型。

### 6.1 Entity / Track / Album / Artist / Playlist

必填：

- `provider`：必须等于插件 id
- `kind`：`song`、`album`、`artist`、`playlist`（MV 走独立 operation）
- `id`、`key`：`key` 必须是 `<provider>:<kind>:<id>` 形式
- `title`
- `artist`：单一展示字符串
- `artists[]`：`{id, name}` 数组，可为空

常用可选字段：`creatorID`、`albumID`、`album`、`albumAudioID`、`mediaId`、`cover`、`description`、
`wiki`、`date`、`duration`（毫秒）、`trackCount`、`mvID`、`special`、`owned`、`dirId`、`listid`、
`listType`、`chart`、`period`、`rankCid`、`isDefault`、`isFavorite`、`playCount`、`virtual`、`extensions`。

平台特有字段只能放在 `extensions`，不能污染顶层模型。

### 6.2 Page

```ts
interface Page<T> {
    items: T[];
    rawCount: number; // 本页消费的上游原始条目数，用于推进 offset
    total?: number;
    more: boolean;
    notice?: string;
    incomplete?: boolean;
    category?: string;
    areas?: { id: string; name: string }[];
    area?: number;
}
```

分页约定：

- 请求使用 `offset`，插件自己换算成 page/cursor；
- `rawCount` 是本页消费的上游原始条目数，不是累计数，也不是过滤和去重后的 `items.length`；
  Qt 用 `offset += rawCount` 推进。即使原始条目无法映射，也不得让下一页重复或跳过条目；
- `more` 必须反映可靠的上游分页信息；使用页大小推断时，必须确认该上游的分页行为支持这一推断；
- 若无法可靠判断后续页或已消费数量，返回 `incomplete: true` 或抛出错误，不要把部分结果当作完整结果；
- `more=true` 时 `rawCount` 必须大于零，避免无法推进的循环；过滤后 `items` 为空但原始消费数大于零
  时，仍可继续分页。

歌手详情页在来源声明 `trackPage` 时，从 `offset=0` 请求 `kind=artist` 的歌曲页，按 `rawCount`
推进并按歌曲键去重；浏览至末尾可继续加载，播放全部会先补齐后续页。请求失败或返回
`incomplete: true` 时保留已显示的歌曲并允许重试。未声明 `trackPage` 的旧插件继续显示 `detail`
返回的歌曲，不能据此保证歌曲完整。声明此 operation 的插件应支持歌手歌曲分页；分页范围和排序由
插件按照上游实际能力定义，核心不假设热门列表等于完整曲库。会话恢复保留分页进度。

缓存策略应允许不完整或失败的分页重新请求；如果缓存层不能识别 `incomplete`，不要缓存该 operation。

### 6.3 PlaybackSource

必填 `url` 与归一化 `tier`。常用可选字段：

`type`、`extName`、`format`、`bitrate`、`br`、`size`、`sampleRate`、`bitDepth`、`providerTier`、
`qualityId`、`trial`、`restriction`、`qualityFallback`。

`tier` 取值：`auto`、`standard`、`hq`、`lossless`、`hires`、`master`、`original`。平台内部档位放在
`quality.options[].id`、`providerTier` 或插件的 `quality.badges` 中；core 不做平台音质翻译。

### 6.4 LyricsDocument

使用 `MusicBridge/lyrics-format.cjs` 的 `normalizeLyrics` 生成：

```ts
interface LyricsDocument {
    version: 1;
    source: string;
    timing: 'none' | 'line' | 'word';
    offsetMs: number;
    lines: Array<{ startMs: number; endMs?: number; text: string; translation?: string; words?: ... }>;
    plainText?: string;
}
```

没有歌词返回 `null`；不要返回空字符串或未归一化的上游对象。

歌词请求限流由 descriptor 的 `lyrics.rateLimitMs` 控制；当从当前来源回退到其他来源搜索歌词时，
来源自己的 `lyrics.fallbackRateLimitMs` 会作为额外下限。

### 6.5 Account / Mutation / Error

- `Account`：`{ uid: string, nickname: string }`，未登录返回 `null`。
- `MutationResult`：`{ applied: boolean, state?, item?, countDelta? }`；写操作必须明确 `applied`。
- `LikeState`：`subscribed`、`not-subscribed`、`unknown`。
- 错误对象至少 `{code, message}`；可选 `authExpired`、`retryable`、`writeAttempted`、`verification:'unconfirmed'`
  和上游诊断白名单字段。不要把上游原始响应或认证信息塞进 `message`。

### 6.6 Comments

评论是只读 operation，由插件 manifest 的 `operations.comments` / `operations.commentReplies` 声明：

```ts
comments(track, id, sort, page, cursor) -> {
  comments: CommentItem[];
  totalCount: number;
  hasMore: boolean;
  cursor?: string;
}
commentReplies(track, id, parentCommentId, cursor, limit) -> {
  comments: CommentItem[];
  hasMore: boolean;
  time?: string;
}
```

`CommentItem` 至少 `{id, content, nickname}`，可选 `userId`、`avatarUrl`、`time`、`likedCount`、
`replyCount`、`replyTo`、`location`、`inlineReplies`。`sort` 为 `hot`/`new`；分页和 cursor 语义由插件
自己解释，但必须返回 `hasMore` 和下一页 cursor。头像 URL 会经过 Host 的封面 allowlist 校验。

---

## 7. 凭据与登录

core 的存储格式是 v2：

```json
{
    "version": 2,
    "providers": {
        "example": {
            "cookies": { "session": "..." },
            "secrets": {}
        }
    }
}
```

- Host 按 provider 切片后注入 `message.cookies`，插件只能看到自己的切片。
- 登录成功后通过 `host.acceptCookies` 写回；响应会携带 `_epoch`，旧登录/旧账号的迟到响应不能覆盖新凭据。
- 二维码登录：`loginBegin` 返回 `token`、`qrText` 或 `qrImage`；`loginPoll` 返回
  `status`（`waiting/scanned/confirmed/expired`）和上游 `code`；确认后 Host 调用 `account()` 验证。
- 短信登录：method 的 `flow.send`（默认 `loginSms`）发送验证码，`flow.submit`（默认
  `loginSubmit`）提交；Qt 还读取 `phonePattern`、`flow.codePattern` 和 `resendCooldownMs`。
- 二维码轮询间隔和超时读取 `login.pollIntervalMs` / `login.pollTimeoutMs`；`channel`、`countryCode`
  目前只作为插件自身的附加参数来源，core 不解释其语义。
- 登录失败要抛结构化错误；认证过期加 `authExpired: true`，让 Qt 提示重新登录。
- 不要把 cookie/token 写入日志、诊断或错误消息。

---

## 8. 路由

| 路由族                      | 用途              | 现状                    |
| --------------------------- | ----------------- | ----------------------- |
| `/native/<id>/<operation>`  | Qt 统一 operation | 当前主路径              |
| `/plugin/<id>/<operation>`  | 显式插件入口      | worker 支持             |
| `/plugin/<id>/route/<path>` | 插件原始路由      | worker 支持             |
| `<prefix>/...`              | `routes.prefixes` | Registry 匹配并剥离前缀 |
| `routes.legacyRoutes`       | 精确 legacy shim  | 迁移期兼容              |

注意：当前 `MusicApi.request` 对“默认 legacy 来源”以外的 provider 会先拼 `"/<provider>"`；原始路由应按这个约定
声明 prefix 或 legacy route。插件入口应优先实现 native operation，原始路由只用于迁移和特殊查询。

---

## 9. 构建、发布与市场

### 9.0 适配流程

1. **盘点上游**：确认接口、参数、分页、cookie/CSRF、错误码，以及哪些 module 可以直接 require。
2. **写最小 manifest**：先只声明 `search/detail/playback/lyrics`，`capabilities` 与 `operations` 保持一致。
3. **写 transport**：维护“插件 route → 上游 module”白名单；注入 cookie；保留参数类型；只收集必要的 Set-Cookie。
4. **写 item 映射**：先把一条上游结果映射成合法 Entity/Page，再用 `models.cjs` 校验。
5. **逐 operation 实现**：每加一个就同步 manifest.operations、fixture 与 capability；空结果要返回空 Page，不是 undefined。
6. **最后做登录/写操作**：先只读 smoke，再真实账号；写操作不自动重试，未确认写入必须显式标记。
7. **打包**：`bundle-plugins.cjs` → `plugin.cjs`；确认 entry hash/size、`files[]`、市场 index 一致。
8. **验证**：契约检查、worker IPC smoke、市场检查；有真实账号时做只读网络 smoke。
9. **审计**：重点看空值、第二页、鉴权过期、HTTP 媒体、特殊歌单、布尔/字符串参数。

### 9.1 构建

```bash
node scripts/bundle-plugins.cjs MusicBridge/local-plugins <id>
```

构建器：

1. 读取 `manifest.runtime.sourceEntry`；
2. 用 esbuild 打成 `plugin.cjs`（CJS，target node18）；
3. 执行插件自己的 `build.cjs` 插件（如有）；
4. 生成额外 worker/占位文件（如有）；
5. 回写 `manifest.entry.sha256`、`entry.size` 和 `runtime.bundled`。

插件作者必须自己保证 `plugin.cjs` 的依赖全部打包；发布目录不应依赖 `node_modules`。

### 9.2 市场

市场布局：

```text
index.json
plugins/<id>/manifest.json
plugins/<id>/plugin.cjs
plugins/<id>/...
```

`index.json` 的每个条目声明 `path`、`entry.file` 和 `files[]`。客户端按文件下载，不解析 tar、不验签；
`scripts/check-marketplace.cjs <index>` 会反向遍历插件目录，拒绝未列入 `files` 的运行时文件。

安装流程：staging 目录 → 校验 manifest/entry → 原子替换 → 保留 `.backup-<id>` 供回滚。启用状态存
`<data>/plugins-state.json`。

---

## 10. 测试清单

最小验证：

```bash
node scripts/check-plugin-contracts.cjs
node scripts/check-contract-freeze.cjs
node scripts/bundle-plugins.cjs MusicBridge/local-plugins <id>
node scripts/check-marketplace.cjs <market>/index.json
```

插件自身至少覆盖：

- manifest 通过 schema/Registry 校验；
- 每个 operation 的参数位置、返回模型、空结果和错误；
- 分页第二页、空页、`more` 终止；
- 登录成功/失败/过期/取消；
- 播放 tier、试听/受限/无 URL；
- 歌词 null 与有歌词；
- mutation 的 `applied` 与未确认写入；
- 错误路径不泄漏 cookie/token。

用 worker 做一次真实 IPC smoke：

```bash
printf '%s\n' '{"id":"1","route":"/plugin/example/search","params":{"args":["hello","song",0]},"cookies":{}}' \
  | RHINE_USER_PLUGINS="$PWD/plugins" node MusicBridge/worker.cjs
```

---

## 11. 常见错误

1. 把 native operation 参数当对象接收；实际是位置参数。
2. operation 没写进 manifest.operations，入口却实现了；或反过来声明了却没有实现。
3. `Page.rawCount` 返回累计值而不是本页数量，导致 UI 跳页。
4. `more` 在空结果时仍为 true，导致无限请求。
5. 直接返回上游对象；worker 的模型校验会拒绝，且平台字段会泄漏到 UI。
6. 把上游布尔参数原样传透；部分上游只接受字符串 `"true"/"false"`。
7. 过度过滤 cookie（例如过滤所有 `__*`），把上游需要的 CSRF cookie 删掉。
8. 搜索/详情成功后被一次封面补全失败拖垮整个请求。
9. 播放 URL 返回 HTTP，但 manifest 声明 HTTPS-only，移动端 ATS 会拦截。
10. 写操作没有 `applied`，或失败后没有 `verification:'unconfirmed'`。
11. 依赖 `host.authenticated()` 做安全判断；它不是凭据校验。
12. 依赖 core 调用 `dispose()` 做每请求清理；当前 Registry 不会这样做。
13. 在插件里读取其他 provider cookie 或把 token 写进错误消息。
14. 把平台名称/文案/资产放进主仓库；应放在插件 descriptor 或 `docs/PLUGIN/`。

---

## 12. 当前已知边界

- 插件以 module 形式运行在 worker 内，尚无 P9 的 supervisor/quarantine 隔离；卡死或 OOM 仍可能影响整个 worker。
- worker 的 stdout 是 JSON-line 协议；core 会禁用插件 `console.*`，插件也不得直接写 stdout/stderr，否则会破坏 IPC。
- 签名、撤销、anti-downgrade 不在当前最简市场范围内；安装只做结构/路径校验。
- `manifest.routes.rawRoutes` 尚未成为 worker 的放行表。
- Host 的凭据、缓存、封面和播放 host/scheme 策略都由 manifest/descriptor 驱动：凭据需要声明
  `credentials.auth`（以及需要持久化时的 `inject`/`responseSecrets`），缓存读取 `cache.ttlByOperation/
  ttlByRoute/disk/maxEntries`，封面读取 `media.coverHosts`，播放地址读取 `media.hosts/alternativeHosts/
  allowHttp/schemePolicy`。`manifest.limits` 和 `manifest.network` 仍是声明性字段，尚未强制执行。
- Qt 仍只暴露固定的 canonical 写操作路由（喜欢、订阅、歌单创建/改名/删除/曲目编辑）；新增 mutation
  类型需要同时更新 Qt 和插件契约。
- 通用插件 secretState 通过 manifest 的 `inject`/`responseSecrets` 持久化到对应 provider 切片；新插件
  不再需要扩展 Host 的平台键。
- Host 的 `authenticated()`/`hasCredential()` 和凭据落盘按 `credentials.auth` 对所有插件 id 生效；
  cookie 或 secret 需要跨重启保存时，务必声明对应凭据策略。
- Qt 的试听判断读取播放结果里的 `trial` 或 `preview` 布尔值。
- 移动端插件下载/安装尚未做真机 smoke；商店构建应使用构建期打包 flavor。
