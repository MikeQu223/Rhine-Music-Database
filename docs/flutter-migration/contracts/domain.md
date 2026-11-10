# 领域、账号与动作契约（T05）

> 状态：**冻结草案 v1.1**（T05 / DOMAIN-CONTRACT；2026-11-10 按基线源码逐条复核修订）。
> 规范来源：本仓库 Qt 实现，基线 `8ed3067b0812eb2612f7841ec127a6e8ca93231b`（分支 `feat/flutter`）。
> 本文所有条目均标注 `文件:行号` 证据；标注 **源码聚合，T05 重新核对** 的清单由 T05 逐条回读源码确认，未确认项显式写 `待复核`。
> 迁移目标：横屏 1:1（功能 / 画面 / 动作 / 状态 / 时序）；竖屏为新增重排，保留全部语义，不假造 Qt 竖屏基线。

## 0. 契约地位与读取方式

- 本文件是 Flutter 侧领域层（账号、音乐库、队列、歌词、动作路由）的**唯一冻结基准**。与旧 Flutter UI、旧草稿、任何二手笔记冲突时，以本文件 + Qt 源码为准。
- 行号引用指向基线提交下的 Qt 源码；若后续 Qt 侧文件漂移，以 `git show 8ed3067b:Qt/src/<file>` 为准。
- 每个契约条目形如 `D-<域>-<序号>`，便于测试与审查逐条引用。
- 本文**不**规定 widget 结构、颜色、动画曲线；只规定状态机、数据形状、字符串、时序与动作语法。
- 设备/真机项（APK 行为、IM E、系统返回键、后台恢复）在本文只标 `DEVICE_BLOCKED`，不宣称已验证。

## 1. 术语

| 术语 | 定义 | 证据 |
| --- | --- | --- |
| provider | 音乐来源枚举：`netease` / `qq` / `kugou` / `local` / `siren` | `Qt/src/MusicLibrary.cpp:20-22`（构造期白名单 `QStringList{"netease","qq","kugou","local","siren"}`），`MusicAccount.cpp:193-297`（switchProvider 白名单） |
| edition | 酷狗音源版本：`standard` / `lite` | `Qt/src/MusicLibrary.h`（kugouEdition）、`Qt/src/MusicLibrary.cpp:169-171`（accountKey） |
| lane | 音乐库五列之一，索引 0..4 | `Qt/src/MusicLibrary.h:151`（columns 默认值） |
| MSR | Monster Siren Records，即**塞壬唱片**，provider=`siren`，本地收藏实现 | `Qt/src/MusicSiren.cpp`、`Qt/src/MusicMutation.cpp:18-45` |
| 目录栈 | `MusicDirectory` 父子链，最多 64 层 | `Qt/src/MusicDirectory.cpp:46-142`、`Qt/src/MusicSession.cpp`（folders<=64） |
| 唯一队列 | `PlaybackQueue` 是播放队列的唯一状态源 | `Qt/src/PlaybackQueue.h:11-15` |
| cancel 屏障 | 取消二维码时必须等上游 `/login/qr/cancel` 回包才允许下一步 | `Qt/src/MusicAccount.cpp:343-379` |
| 墙钟冷却 | 重试倒计时以绝对时间戳计，不按 tick 计数 | `Qt/src/MusicAccount.cpp:308-341` |

## 2. 账号域（登录）

### 2.1 六条登录路径（D-AUTH-1）

登录路径是**六条具体路径**，不是 `provider × method` 的笛卡尔积。任何实现若把六条压缩成对称模板（3 provider × qr/sms）即为违约。

| ID | provider | method | edition | 入口动作 | QR 通道 | accountKey | 关键差异 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `netease-qr` | netease | qr | — | `music:login`、`music:qr` | 无（本地渲染 `host->qr(key)`） | `netease` | 二维码由宿主本地绘制，不走上游 qrimg |
| `netease-phone` | netease | phone | — | `music:login-method:phone` | — | `netease` | 唯一 SMS 路径；`/captcha/sent` + `/login/cellphone` |
| `qq-qr` | qq | qr | — | `music:login` | `channel=qq` | `qq` | 走 `/login/qr/create` 取 `qrimg` data URL |
| `qq-wechat` | qq | wechat | — | `music:login-method:wechat` | `channel=wechat` | `qq` | 同协议，仅 `channel` 与扫码器文案不同 |
| `kugou-standard` | kugou | qr | standard | `music:login` | 无 | `kugou-standard` | edition 进 worker env `RHINE_KUGOU_EDITION` |
| `kugou-lite` | kugou | qr | lite | `music:kugou-edition:lite`（登录模态打开时自动续 `startLogin`） | 无 | `kugou-lite` | providerName 显示 `酷狗概念版` |

**登录方法可用性（D-AUTH-2）**：`music:login-method:<qr|phone|wechat>` 仅接受 `qr`，或 `phone` 且 `provider==netease`，或 `wechat` 且 `provider==qq`；其余组合直接 `return`。处理顺序固定为 `cancelLogin()` -> `loginMethod=method` -> `loginStatus.clear()` -> 仅 `qr|wechat` 继续 `startLogin()`；`phone` **只切方式、不自动发码**，必须由后续显式动作发码。证据 `Qt/src/NativeHudMusic.cpp:295-307`。

**本地与塞壬不可登录（D-AUTH-3）**：`provider ∈ {local, siren}` 时登录相关动作（`music:login`、`music:logout`、`music:qr`、`music:login-method:*`、`music:kugou-edition:*`、`music:refresh-personal`、`music:activate`）与 `subscribe` 全部被拒；`local` 另有更长的拒绝表（含 `like*`、歌单写操作、`source`、`official`）。**完整拒绝表以 §4.4（D-ACT-2）为唯一定义**，本节不重复列举。证据 `Qt/src/NativeHudMusic.cpp:25-39`。

**酷狗 edition 切换（D-AUTH-4）**：`music:kugou-edition:<standard|lite>` **无条件**调用 `switchProvider("kugou", parts.value(2), cb)`（`Qt/src/NativeHudMusic.cpp:287-294`）；是否真的切换由 `switchProvider` 内部判定——同源且 edition 未变时在 `Qt/src/MusicAccount.cpp:202-208` 直接 `done(true)` 返回（幂等、不发请求）。跨 provider（如 `netease → kugou`）同样走这条动作，这正是 `kugou-lite` 路径的入口。edition 真变化时写 `kugouEdition`、`host->setKugouEdition`、偏好 `kugou-edition`、`identityNames[kugou]=pref(welcome-name-<新 accountKey>)`（`:221-226`，`provider` 赋值次序见 §2.11）；回调只在 `ok && modal=="login" && searchGeneration` 未变（token 于动作触发时捕获）时才续 `startLogin()`。

### 2.2 六阶段状态机（D-AUTH-5）

阶段枚举**恰好六个**：`idle` / `preparing` / `waiting` / `confirming` / `failed` / `complete`。

| 迁移 | 触发 | 副作用 | 证据 |
| --- | --- | --- | --- |
| `idle → preparing` | `startLogin()` | 先 `cancelLogin()`（其内部已 `++m_loginGeneration`），再 `++m_loginGeneration` 取 token；`loginDiagnostics={}`；`loginStatus=准备二维码…`；`qr.clear()`；`accountLoading=true`；随后 `waitCancellation` 等屏障 | `MusicAccount.cpp:525-558` |
| 任意（冷却中）→ failed | `startLogin()` 且 `!canRegenerateLogin()` | 仅当 `loginRetrySeconds()>0` 时置 `failed` 并写 `<message>（请等待 N 秒）`；为 0 时静默返回 | `MusicAccount.cpp:529-538` |
| `preparing → waiting` | `prepareQR` 的 `ready()` | `loginStatus=请用<scanner>扫描并确认登录`；`pollQR(token,0)` 启动 | `MusicAccount.cpp:560-623` |
| `waiting → confirming` | 轮询 `code==802` | `loginStatus=已扫描，请在手机上确认`；**不 return，继续轮询** | `MusicAccount.cpp:625-667` |
| `waiting → confirming` | 轮询 `code==803` | 先置 `loginPhase=confirming`，再 `confirmLogin(token)`（`captcha=false`） | 同上 |
| `confirming → complete` | `confirmLogin` 成功 | 见 §2.10（D-AUTH-19） | `MusicAccount.cpp:475-523` |
| 任意 `→ failed` | `failLogin` / `reportLoginFailure` | 见 §2.4 | `MusicAccount.cpp:308-320`、`:464-473` |
| `failed → preparing` | 用户再次 `startLogin` 且冷却为 0 | 受 `canRegenerateLogin` 门控 | `MusicAccount.cpp:304-306` |
| 任意 `→ idle` | `cancelLogin()` / `switchProvider()` | 清 `qrKey`、清 `qr`、`loginPhase=idle`、`accountLoading=false`；随后按 §2.6 等取消屏障 | `MusicAccount.cpp:343-379`、`:193-297` |

**801/802 的轮询语义（D-AUTH-6）**：`code==801`（等待扫码）不匹配任何阶段分支，只做 `pollQR(token, count+1)`，阶段保持 `waiting`、文案不变；把 801 当作 `confirming` 或写回进度百分比都是违约。`code==802`（已扫描）置 `confirming` 与文案后**没有 `return`**，同样继续 `pollQR(token, count+1)`——即 802 会反复到达，直到 803/800 或超时。响应 `code` 白名单由 `api.request` 的 `allowed` 参数给出，恰为 `{800,801,802,803}`；白名单外的 body code（如 805）被 `MusicApi` 转成 `<providerName>返回 N：<message>` 并直接 `failLogin`，**不得**当作「继续轮询」。证据 `MusicAccount.cpp:625-667`、`MusicApi.cpp:90-124`。

**可重生成门控（D-AUTH-7）**：`canRegenerateLogin() == loginRetrySeconds()==0 && loginPhase ∉ {preparing, confirming}`，`loginRetrySeconds()=ceil(max(0,(deadline-now))/1000)`。证据 `MusicAccount.cpp:299-306`。

### 2.3 二维码协议与时序（D-AUTH-8）

| 步骤 | 请求 | 载荷 | 处理 | 证据 |
| --- | --- | --- | --- | --- |
| 取 key | `POST /login/qr/key` | `{timestamp: nowMs}`，且 `provider==qq` 时附 `{channel: loginMethod==wechat ? wechat : qq}` | 取 `body.unikey`，回退 `body.data.unikey`；非字符串 -> `failLogin(二维码生成失败)` | `MusicAccount.cpp:560-623` |
| 网易出图 | 本地 `host->qr(qrKey)` | — | 直接 `qr = host->qr(qrKey)` 后 `ready()`；**不做空图校验**（源码 `MusicAccount.cpp:593-597` 无该分支，禁止凭空加失败路径） | 同上 |
| QQ / 酷狗出图（非网易） | `POST /login/qr/create` | `{key, qrimg:true, timestamp}`（`channel` 仅 QQ 在取 key 时携带） | 必须匹配 `^data:image/(png|jpeg|gif|webp);base64,`，否则 `failLogin(<providerName>二维码格式无效)`；`host->qrImage(data)` 空 -> `failLogin(<providerName>二维码读取失败)`（前缀逐字来自 `providerName() + QStringLiteral("二维码读取失败")`，`:613-617`） | 同上 |
| 轮询 | `POST /login/qr/check` | `{key, timestamp}` | 先 `host->schedule(1000)` 再发；`count>=300` 时改判超时；`body.code` 缺失按 `800`（`toInt(800)`）；响应 `code` 白名单恰为 `{800,801,802,803}`（`:665`），白名单外整包交 `failLogin` | `MusicAccount.cpp:625-667` |
| 取消 | `POST /login/qr/cancel` | `{key: previousKey}` | 仅 QQ 且 previousKey 非空时发 | `MusicAccount.cpp:343-379` |
| 短信 | `POST /captcha/sent` | `{phone, ctcode:86}` | 成功文案 `验证码已发送，请查看手机短信` | `MusicAccount.cpp:381-429` |
| 短信登录 | `POST /login/cellphone` | `{phone, captcha, countrycode:86}` | 成功 -> `confirmLogin(token, true)` | `MusicAccount.cpp:432-462` |
| 账号信息 | `api.call(account)` | — | 见 §2.10（D-AUTH-19） | `MusicAccount.cpp:475-523` |

**路由前缀（D-AUTH-9）**：上表与 §2.1 的路径都是 **netease 形态**。`MusicApi::request` 在 `provider != "netease"` 时把 route 改写为 `"/" + provider + route`（`Qt/src/MusicApi.cpp:80-82`），故 QQ 实际请求 `/qq/login/qr/key`、`/qq/login/qr/check`，酷狗为 `/kugou/login/qr/create` 等；`MusicApi::call` 固定走 `/native/<provider>/<operation>` 且 `allowed=={200}`（`Qt/src/MusicApi.cpp:61-70`）。Flutter 侧只拼一次前缀，禁止在调用点预拼 `/<provider>`。

**轮询参数（D-AUTH-10）**：间隔 `1000 ms`，上限 `300` 次；`count` 从 0 递增；超时文案 `二维码超时，请重新生成`。常量必须与曲线一致：`count>=300` 即判超时，故最多 300 次 check。

**800 的两条分支（D-AUTH-11）**：

- `provider==qq`：`qr.clear()`、`accountLoading=false`，随后 `reportLoginFailure(body)` —— 走完整失败分类与 `retryAfterMs` 冷却。
- 其他 provider：`failLogin(二维码已过期，请重新生成)`。

两者都为 `failed`，但文案与冷却来源不同；网易不得出现 QQ 的上游分类文案，QQ 不得丢掉 `retryAfterMs`。证据 `MusicAccount.cpp:625-667`、`:308-320`。

### 2.4 失败分类与文案（D-AUTH-12）

`loginFailureMessage(details)` 的判定顺序与文案（逐字）。取数层次先固定：

- `failure = details.lastFailure`（若为对象），否则 `failure = details`。
- `primary = failure.primaryFailure`。
- `upstreamError = primary.upstreamErrorKey`（非空）否则 `failure.upstreamErrorKey`。

| # | 条件（按顺序短路） | 文案（逐字） |
| --- | --- | --- |
| 1 | `failure.upstreamCode==20279` 或 `primary.upstreamCode==20279` 或 `upstreamError=="auth.device-limit"` | `登录设备数量已达上限，请在 QQ 音乐设备管理中删除无用设备` |
| 2 | `primary.upstreamCode==50006`（**仅 primary**） | `请使用手机 QQ 扫描手机 QQ 通道二维码，再尝试登录` |
| 3 | `upstreamError=="auth.rate-limited"` 或 `primary.upstreamCode==104604` 或 `failure.upstreamCode==104604` | `QQ 登录操作过于频繁，请等待冷却后重试` |
| 4 | `upstreamError=="auth.account-restricted"` | `账号当前受限，请在 QQ 音乐客户端检查` |
| 5 | `upstreamError=="auth.account-banned"` | `QQ 返回账号被封禁，请在官方客户端核实` |
| 6 | `upstreamError=="auth.account-binding"` | `账号绑定状态异常，请在 QQ 音乐客户端检查` |
| 7 | `failure.failureReason=="qr-timeout"` | `二维码已过期，请重新生成` |
| 8 | `failure.failureReason=="user-canceled"` | `已取消扫码登录` |
| 9 | `failure.failureStage=="credential-validation"` | `登录凭证验证失败，请重试或检查设备管理` |
| 10 | `failure.failureStage=="credential-exchange"` | `扫码授权交换失败，请重试或检查设备管理` |
| 11 | `failure.failureStage=="mqtt-listener"` | `扫码连接中断，请检查网络后重试` |
| 12 | `failure.failureReason=="session-busy"` | `扫码授权仍在处理中，请等待` |
| 13 | `details.code==429` 或 `details.failureReason=="local-backoff"`（**读外层 details**） | `扫码登录暂时冷却` |
| 14 | `details.code==401`（**读外层 details**） | `QQ 登录已失效，请重新扫码` |
| 15 | 默认且 `details.code==800`（**读外层 details**） | `二维码会话已失效或登录失败，请重新生成` |
| 16 | 默认其他 | `扫码登录失败，请稍后重试` |

证据 `MusicAccount.cpp:9-58`。注意第 7–12 条读 `failure`（可能已被 `lastFailure` 下钻），第 13–15 条读**外层** `details`；漏掉这一层差异会把 QQ 的 `lastFailure.code==401` 误判为失效。

`failLogin(result)`：`loginPhase=failed`、`accountLoading=false`；当 `provider==qq` 且 `result.failure` 含 `code` 时走 `reportLoginFailure(result.failure)`（无 fallback），否则 `loginStatus=result.error`。证据 `MusicAccount.cpp:464-473`。

### 2.5 冷却：retryAfterMs 是墙钟（D-AUTH-13）

- 来源：`MusicApi::safeFailure(details)` 归一后的 `details[retryAfterMs]`（毫秒），非秒、非 tick。
- 存储：`m_cooldowns[provider] = Cooldown{deadline = now + retry, message, ++m_cooldownGeneration}`。
- 展示：`updateLoginCooldown` 每秒（`host->schedule(1000)`）重算 `ceil((deadline-now)/1000)`；当 `source==provider && loginPhase==failed` 时改写 `loginStatus = message + （请等待 N 秒）`，为 0 时改为 `message + ，可重新生成`。
- 登记条件：仅 `retry = max(0, details.retryAfterMs) > 0` 才登记冷却；`retry==0` 时只置 `failed`，不产生倒计时。
- fallback：`reportLoginFailure(details, fallback)` 的 `fallback` 非空时优先于分类文案（`startLogin` 的「旧二维码取消失败，请稍后重试」即走此路）。
- 失效：`m_cooldowns[provider].token != cooldown.token` 即作废旧计时器回包。
- 清除：`confirmLogin` 的**非 captcha** 成功路径 `m_cooldowns.remove(provider)`；captcha 路径不清（见 §2.10）。
- 调度：`seconds>0` 的续期 `host->schedule(1000)` 在 `source==provider && failed` 判断之外，仍会继续；改写文案才受该判断约束。
- 证据：`MusicAccount.cpp:308-341`、`:475-523`。

禁止把冷却实现为「每 1 秒减 1 的整数计数器」：进程挂起、后台切回会让 tick 与真实时间脱节，必须持久化为绝对 deadline（毫秒时间戳）。

### 2.6 cancel 完成屏障（D-AUTH-14）

`cancelLogin()` 不是「发完请求就返回」，而是**带完成屏障**：

1. 先取 `previousKey=qrKey`；`++m_loginGeneration`（使在途轮询/回调失效）；`qrKey.clear()`；`qr.clear()`；`loginPhase=idle`；`accountLoading=false`。
2. 若 `provider!=qq` 或 `previousKey` 为空：**不发上游请求**；有 `done` 时调用 `waitCancellation(provider, done)`——该 provider 已有在途取消则排队等待，否则立刻 `done(true)`。
3. 否则（QQ 且 previousKey 非空）：新建 `Cancellation` 并把 `done` 挂为 waiter，写入 `m_cancellations[provider]`，再 `POST /login/qr/cancel {key:previousKey}`；回包后若表项仍是本次则移除，并以 `result.ok()` 唤醒**全部** waiter。
   - 注意：QQ 路径**不经过** `waitCancellation` 的就绪快返分支，屏障由本次请求自身建立；`waitCancellation` 只在非 QQ/空 key 或无请求场景下复用已在途的取消。
4. `startLogin` 在 `prepareQR` 之前 `waitCancellation(provider, cb)`；若 `cancelled` 为真才继续，否则 `failLogin(旧二维码取消失败，请稍后重试)`。

证据：`MusicAccount.cpp:343-379`（cancelLogin/waitCancellation）、`:525-558`（startLogin 使用屏障）。

这条屏障是 QQ 与网易的核心差异之一：**QQ 切通道/重生成前必须等取消回包**。屏障的设计意图是保证重生成前旧 key 已在上游作废——此句是设计意图，不是源码断言；源码只保证「等回包」这一时序，本仓库内没有证据证明上游会残留旧 key 或返回 `session-busy`。

### 2.7 SMS（仅网易）（D-AUTH-15）

- 门控：`provider==netease`、`!accountLoading`、`smsRetrySeconds()==0`。
- 手机号正则：`^1[0-9]{10}$`，不匹配 -> `loginStatus=请输入有效的中国大陆手机号码`。
- 发码前 `cancelLogin()`、`++m_loginGeneration`、`loginMethod=phone`、`loginStatus=正在发送短信验证码…`。
- 重发间隔：`constexpr qint64 SMS_RESEND_INTERVAL_MS = 60000`，以 `m_smsRetryAtMs = now + 60000` 记录；`updateSmsCooldown` 每 `1000 ms` 刷新剩余秒数（`ceil((remaining+999)/1000)`）。
- **60 秒墙钟在请求发出前就登记**，请求失败也不回滚；`m_smsRetryAtMs` 只在此处赋值，`logout`/`switchProvider` 都不清零，跨账号仍按时间戳自然过期。
- 门控命中时 **静默 return**：不写 `loginStatus`、不 `changed()`、不报错；因此 UI 不得把"点了没反应"渲染成失败文案。
- 短信登录：手机号 `^1[0-9]{10}$` 且验证码 `^[0-9]{4,8}$`，否则 `请输入中国大陆手机号码和短信验证码`；`loginStatus=正在登录…`；失败 `loginStatus=result.error`、`accountLoading=false`；成功后 `confirmLogin(token,true)`。
- captcha 成功**不置** `loginPhase=complete`、**不清** `qr/qrKey`、**不清**冷却（`MusicAccount.cpp:512-517` 的 `if(!captcha)` 块）；实现若在 SMS 成功后把阶段写成 `complete` 即为违约。
- 证据：`MusicAccount.cpp:381-429`、`:432-462`。

**QQ 与酷狗没有 SMS 路径（D-AUTH-16）**：`/captcha/sent`、`/login/cellphone`、`loginMethod=phone` 在任何 QQ / 酷狗路径上都不可达；fixture 与测试必须显式断言这一点（见 §7）。

### 2.8 凭据与身份名兼容（D-AUTH-17）

| 键 | 值 | 写入点 | 证据 |
| --- | --- | --- | --- |
| `account-id-<accountKey>` | uid | `rememberIdentityName`（登录成功后）、`restoreAccount` 失效时清空 | `MusicAccount.cpp:61-72`、`:139-190` |
| `welcome-name-<key>` | 昵称 | `rememberIdentityName` | 同上 |
| `kugou-edition` | `standard` / `lite` | `switchProvider` | `MusicAccount.cpp:193-297` |
| `provider` | 当前 provider | `switchProvider` | 同上 |
| `session.json` | 完整会话（见 §5.1） | `NativeApplication::saveSession` | `MusicSession.cpp:213-284` |

`accountKey()` = `provider==kugou ? "kugou-"+kugouEdition : provider`。因此酷狗 standard 与 lite 是**两个独立凭据槽**（`account-id-kugou-standard`、`account-id-kugou-lite`），`welcome-name-kugou-standard/lite` 同理。证据 `MusicLibrary.cpp:169-171`、`Host.cpp:1041-1058`（偏好白名单）。

Flutter 侧必须读写同一批键名与同一 `session.json` 位置（`AppStorage::dataDirectory()`），否则与 Qt 共存/回退时会丢登录态。

### 2.9 缓存恢复与失效（D-AUTH-18）

`restoreCachedAccount()`：

- `local` -> `nickname=本地音乐`；`siren` -> `nickname=本地收藏`；两者 `uid` 为空。
- 其他：`authenticated` 时 `uid = preference(account-id-<accountKey>)`，`nickname = identityNames[provider]`；**仅当 `nickname` 为空**时置 `正在恢复登录…`（uid 为空不算条件）；未认证时 `uid` 空、`nickname=未登录`。
- 触发条件是「昵称空」，**不是**「uid 与昵称都空」：已有 uid 但本机没存昵称时仍必须显示 `正在恢复登录…`。

`restoreIdentityName()`（同一节，源码 `MusicAccount.cpp:74-92`，此前遗漏）：

- `isLocal()` 或 `isSiren()` 直接返回。
- `source = provider=="netease" ? "qq" : "netease"`；若 `identityNames[source]` 非空，或 `host->hasCredential(source)` 为假，直接返回。
- 否则先把**独立实例** `m_identityApi` 的 `provider` 设为 `source`（`MusicAccount.cpp:82`），再调 `m_identityApi.call("account")`；成功时 `rememberIdentityName(source, value[1])` + `changed()`（`source==provider` 时才写 `account-id-<key>`，见 §2.8）。
- 回调带代数校验 `valid(m_accountGeneration, &m_accountGeneration)`：切源/登出后旧回包必须作废。
- 语义：启动时若本 provider 昵称缺失、而另一 provider 存有凭据，Qt 会用另一 provider 拉取账号名并刷新 `welcome-name-<key>`，使登录态显示与 Qt 一致；Flutter 不得省略这条路径。

`restoreAccount()`：

- `code==401` 或 `authExpired`，或（`provider==netease` 且 `code==301`）-> `uid.clear()`、`nickname=登录已失效`、清 `account-id-<key>`、`status=登录已失效，请重新登录`。
- 其他失败 -> 保留本机记录，`status=账号验证暂不可用，已保留本机登录记录`。

证据 `MusicAccount.cpp:74-92`（restoreIdentityName）、`:94-111`（restoreCachedAccount）、`:139-190`（restoreAccount）。

### 2.10 登录成功/登出副作用（D-AUTH-19）

`confirmLogin(token, captcha)` 的固定次序：

1. `api.call(account)`。失败时：`captcha` 为真 -> `loginStatus=result.error`、`accountLoading=false`、`changed()`；否则 `failLogin(result)`。
2. `host->saveCredential()`。非空错误同上二分（captcha 只置状态，QR 走 `failLogin({{}, error, {}})`）。
3. `++m_accountGeneration`；`restoringAccount=false`；`m_accountError.clear()`。
4. uid 变化才 `resetLikeState()`；写 `uid`、`nickname`；`rememberIdentityName(provider, nickname)`。
5. `loginStatus=已登录：<nickname>`；`refreshQQFeatures()`。
6. `status = captcha ? loginStatus : 已登录，可读取我的音乐`。
7. **仅 `!captcha`**：`qr.clear()`、`qrKey.clear()`、`loginPhase=complete`、`m_cooldowns.remove(provider)`。
8. `accountLoading=false`；`loadMoreSource(2)`；`changed()`。

证据 `MusicAccount.cpp:475-523`（第 7 步的 `if (!captcha)` 块在 `:512-517`）。因此 **SMS 成功不会把阶段推进到 `complete`，也不会清二维码/冷却**；竖屏若显示「登录完成」文案，只能来自 `loginStatus`，不能改阶段。

`logout`（`local`/`siren` 直接无操作），固定次序与副作用：

1. `clearSelection = selectedLane > 0 || privateSelection`（先算，后面用）。
2. `writeLoading=false`；清 `subscriptions`、`subscriptionStates`；`vipLevel=unknown`。
3. `discover->cancel()`；`player.stop()`；`player.clearHistory()`；偏好 `play-history=[]`。
4. `while(directory) leaveDirectory()`；清 `groupLane=-1`、`groupName`、`groupIndices`。
5. `cancelLogin()`；`++m_accountGeneration`；`restoringAccount=false`；`m_pendingLane=-1`；`m_playLiked=false`；`m_accountError.clear()`；`m_sourceErrors.fill({})`。
6. `host->logout()`；偏好 `account-id-<accountKey>` 置空；`uid.clear()`；`nickname=未登录`。
7. `likedIDs.reset()`；`likedCursor=playlistCursor=albumCursor=0`；`personalLoading=false`；`details.clear()`。
8. lane 1..4：`lists={}`、`totals=0`、`offsets=0`、`hasMore=true`。
9. `musicClearRequested`；`choose(clearSelection ? {} : current)`；`privateSelection=false`；`status=已退出登录`；`changed()`。

证据 `MusicAccount.cpp:670-717`。第 9 步的 `choose` 决定登出后光标落点：清空选择时传空对象，否则保留当前曲。

### 2.11 切源（switchProvider）语义（D-AUTH-20）

`switchProvider(source, edition)`：

0. `source==local && !PlatformFeatures::LocalMusic` -> `done(false)` 后返回（调用方必须中止：`music:kugou-edition` 之类回调据此决定是否继续 `startLogin`）。
1. `source ∉ {netease,qq,kugou,local,siren}` -> `done(true)` 后返回（与第 3 步同一分支，返回 `true` 表示调用方可继续，**不是静默忽略**）。
2. `editionChanged` 仅当 `source==kugou && edition ∈ {standard,lite} && edition != kugouEdition`。
3. `source==provider && !editionChanged` -> 直接返回 `true`（幂等，不发任何请求）。
4. `cancelLogin()`；`++m_generation`、`++m_accountGeneration`、`++m_selectionGeneration`、`++m_directoryGeneration`、`++m_wikiGeneration`、`++m_suggestGeneration`。
5. `discover->cancel()`、`player.stop()`、`local->cancel()`、`emit musicClearRequested`。
6. 先 `provider=source`（`MusicAccount.cpp:220`，**先于** edition 块，故块内 `accountKey()` 已按新 provider 计算）；`editionChanged` 时再写 `kugouEdition`、`host->setKugouEdition`、偏好 `kugou-edition`、重载 `identityNames[kugou]=pref(welcome-name-<新 accountKey>)`（`:221-226`）；最后 `host->setProvider`、偏好 `provider`、`api.provider`（`:227-229`）。
7. `restoreCachedAccount()`；`restoringAccount=false`；`m_pendingLane=-1`；`m_playLiked=false`；`m_accountError.clear()`；`m_sourceErrors.fill({})`；`loginStatus.clear()`；`loginDiagnostics={}`；`details.clear()`（详情缓存）；`coverImage.clear()`、`coverKey.clear()`（旧封面不得残留到新音源）。
8. `current={}`；`directory.reset()`；`groupLane=-1`；清 lane 0..4 的 lists/totals/offsets/hasMore/rowMemory；`sirenOffsets.fill(0)`（MSR 分页游标，不清会让塞壬分页错位）；`likedIDs.reset()`；游标归零（`likedCursor`/`albumCursor`/`playlistCursor`/`searchCursor`）；各 loading 标志复位（含 `sirenCatalogLoading`、`personalLoading`、`searchLoading`、`detailLoading`、`directoryLoading`、`trackLoad`、`writeLoading`）；`m_pendingSirenSearch=false`；清 subscriptions/subscriptionStates/capabilities；`vipLevel=unknown`；`searchKind=song`；`keyword`/`suggestions` 清空；`selectedPhysical=-1`、`selectedLane=0`、`privateSelection=false`、`loginMethod=qr`。
9. 列名：`local -> refreshLocal()`（不套用五列文案）；`siren -> {搜索结果,喜欢的歌曲,我的歌单,全部歌曲,全部专辑}`；其他 -> `{搜索结果,喜欢的歌曲,我的歌单,收藏歌单,收藏专辑}`。
10. `status=已切换至<providerName>`；`changed()`；`restoreAccount(done)`。

证据 `MusicAccount.cpp:193-297`。

## 3. 音乐库域

### 3.1 五 lane 与来源顺序（D-LIB-1）

固定五列（lane 0..4），列名逐字：

| lane | 默认列名 | 语义 | 证据 |
| --- | --- | --- | --- |
| 0 | `搜索结果` | 关键词检索结果 | `MusicLibrary.h:151` |
| 1 | `喜欢的歌曲` | 我喜欢的音乐 | 同上 |
| 2 | `我的歌单` | 自建歌单 | 同上 |
| 3 | `收藏歌单` | 收藏的他人歌单 | 同上 |
| 4 | `收藏专辑` | 收藏专辑 | 同上 |

**各 provider 的列差异（D-LIB-2）**：

| provider | lane 变化 | 证据 |
| --- | --- | --- |
| `netease` | 五列默认语义 | `MusicLibrary.h:151`、`MusicAccount.cpp:280-286` |
| `qq` | 五列默认语义；lane 4 由 `/album/sub` 驱动 | `MusicMutation.cpp:365-408` |
| `kugou` | lane 4 **禁用**：`酷狗 API 未提供收藏专辑，此栏目已禁用`（showSource）/ `此渠道暂不支持收藏专辑`（sourceMessage） | `MusicLibrary.cpp:556-588`、`:114-167`、`:738-854` |
| `local` | lane 0=本地检索；lane 1..4 无个人音乐语义 | `MusicLibrary.cpp:411-526` |
| `siren` | lane 0=`搜索结果`、lane 1=`喜欢的歌曲`（本地喜欢）、lane 2=`我的歌单`（本地歌单）、lane 3=`全部歌曲`（曲库，一次性全量）、lane 4=`全部专辑`（曲库） | `MusicSiren.cpp:7-88`、`MusicAccount.cpp:193-297`（切源时写入列名） |

**来源顺序（D-LIB-3）**：`sourceOrder()` = `kugou ? {1,2,3,0} : {1,2,3,4,0}`；无目录时 `column-prev|column-next` 按此顺序循环切列。证据 `MusicLibrary.cpp:185-187`、`NativeHudController.cpp:660`。

### 3.2 目录栈（D-LIB-4）

`MusicDirectory` 字段（`MusicLibrary.h:12-34`）：`parent`(shared_ptr)、`item`、`songs`、`sortField`、`ids`、`albums`、`cursor`、`index`、`anchor`、`page`、`parentPhysical`、`parentLane`、`parentItem`、`albumCursor`、`albumsMore`、`albumsLoading`，以及缓存 `cachedSongs`/`sortedSongs`/`cachedSortField`。

**进目录（D-LIB-5）**：`enterDirectory(item)` 的**顺序即语义**——先判 `kind=="song"`：真则 `choose(value)` 直接返回（**不推进任何代数、不入栈**）；否则才 `++m_directoryGeneration`、`++m_selectionGeneration`、`++m_wikiGeneration`，把**当前目录**（可能为空）挂为 `parent`，再加载。进入时 `emit modeRequested(archive)`、`emit navigationRequested(lane,1)`、`destination=(selectedLane+1)%5`、`anchor=destination*8+rowMemory[destination]`、`selectedPhysical=-1`、`status=正在打开：<title>`。三条加载路径必须都实现：①`local` 直接取 `local->tracks(value)` 填 `songs`/`ids`/`cursor` 并 `choose` 首曲（不改写 `status`，保留上一步的 `正在打开：<title>`）；②`isSiren() && kind==playlist && localCollection` 取 `collections->tracks(id)`，为空则 `status=歌单暂无可读取曲目`，否则 `loadDirectoryPage(0)`；③在线走 `api.call("detail")`，失败 `status=读取失败：<error>`，成功 `status=已打开：<title>`，`kind==artist` 进信息页，否则选首曲。证据 `MusicDirectory.cpp:46-142`。

**出目录（D-LIB-6）**：`leaveDirectory(restore)` 清空 `tracks`/`trackIDs`/`cover`；`restore` 为真时恢复 `selectedLane=parentLane`、`selectedPhysical=parentPhysical`、`current=details.value(item.key, parentItem)`，`emit selectionRequested(parentPhysical, {axis:lane, direction:-1})`，`mode=archive`，并 `selectDirectory(directory->index)`，`status=已返回：<title>`；无父目录时 `status=已返回：<columns[selectedLane]>`。证据 `MusicDirectory.cpp:417-452`。

**信息页往返（D-LIB-7）**：`showDirectoryInfo()` 置 `directoryInfo=true`、`current=item`、`tracks=orderedSongs()`、`trackIDs=ids`、`emit musicIdentityRequested(key)`、`mode=detail`；`returnToDirectory()` 在 `directoryInfo` 为真时回到 `selectDirectory(directory->index)`，否则 `mode=archive`。证据 `MusicDirectory.cpp:379-415`。

**40 格物理槽位与分页（D-LIB-8）**：屏幕可见 `5 lane × 8 行 = 40` 格；`cell=(index+anchor)%40`、`page=index/40*40`、`selectedLane=cell/8`、`physical=physicalSlots[lane][cell%8]`；`updateSongs` 用 `anchor=(cell-index%40+40)%40` 保持选中项不跳。证据 `MusicDirectory.cpp:21-31`、`:302-319`。

**翻页（D-LIB-9）**：`navigateDirectory(step)` 先算 `target=index+step`；`target>=songs.size() && cursor<ids.size()` 时 `loadDirectoryPage(target)` 后 **return**；否则 `direction = step>0 ? 1 : -1`，`axis=="row"` 时 `direction = step`（保留 ±N 步长），`axis` 为空时再取 `abs(step)>1 ? "lane" : "row"`；选中下标按 `((target%count)+count)%count` 回绕（负数安全，禁止直接取模）。`loadDirectoryPage` 每次取 100 个 id（`MusicData::unique(songs, ordered(ids))`），`cursor += ids.size()`，目标仍越界则递归再取，补页后仍越界由取模兜底。证据 `MusicDirectory.cpp:321-377`。

**播放队列虚拟目录（D-LIB-10）**：`followPlayback(track)` 若曲目不在当前目录，则临时建 `{kind:playlist, key:"playback:queue", id:"", title:"播放队列", trackCount:queue.size()}`，`songs=queue.items()`、`cursor=size`，并记住原父目录以便返回；`frame[mode]=detail`。证据 `MusicDirectory.cpp:455-503`。

**栈深上限（D-LIB-11）**：持久化时 `directories<=64`，超出丢弃；恢复时逐层重建并**静默夹取**（越界不判存档无效）：`parentPhysical` clamp 到 `0..39`、`parentLane` clamp 到 `0..4`，同层 `cursor` clamp 到 `0..ids.size()`、`index` clamp 到 `0..songs.size()-1`、`anchor` clamp 到 `0..39`。证据 `MusicSession.cpp:127-132`（`std::clamp`）。

### 3.3 搜索四种（D-LIB-12）

搜索类型**恰好四种**：`song` / `album` / `playlist` / `artist`（`NativeHudSearch.cpp:63-69`、`NativeHudMusic.cpp:148-159`）。

| 场景 | 标签 | 命中动作 | 证据 |
| --- | --- | --- | --- |
| 在线 | `歌曲` / `专辑` / `歌单` / `歌手` | `music:kind:<0..3>` | `NativeHudSearch.cpp:63-69` |
| 本地 | `歌曲` / `专辑` / `文件夹` / `歌手`（文件夹=`playlist` 位） | 同上，索引 2 语义为文件夹 | 同上 |

- 关键词长度：`provider==qq ? 60 : 100`（源码变量名为 `provider`），按 **UCS4 字符**计（`query.toUcs4().size()`）；空或超长 -> `status=请输入 1–<maximum> 字关键词` 且清空 lane 0、`++m_generation`。证据 `MusicLibrary.cpp:440-455`。
- 搜索历史：新关键词 `removeAll` + `prepend` + 上限 `12`，持久化偏好 `search-history`。证据 `MusicLibrary.cpp:477-485`。
- 分页：`start = more ? searchCursor : 0`，`searchCursor = start + page[rawCount]`，`hasMore[0]=page[more]`，`totals[0]=max(page[total], lists[0].size())`。
- 结果文案：`page[notice]` 优先，否则 `没有匹配的音乐` / `找到 N 条结果`（siren 另见 §3.4）。
- 网易云链接快捷路径：`host->fromLink(text)` 命中时直接构造单条 `MusicData::item(type,value)`，`hasMore[0]=false`，`emit modeRequested(song?detail:archive)`。
- 建议词：`kugou/local/siren` 跳过；`qq` -> `/getSmartbox {key}`，`netease` -> `/search/suggest {keywords, type:"mobile"}`；最多 `4` 条（`suggestions.size() < 4`）。证据 `MusicLibrary.cpp:528-554`，上限见 `:548`。

**分组视图（D-LIB-13）**：`setGroupView(kind)` 支持 `none` / `artist` / `album`（动作 `music:group:<0..2>`，返回 `music:group-back`）；分组后 `groupLane` 决定 `selectResult` 是否把索引经 `groupIndices` 映射回原序。证据 `MusicLibrary.cpp:232-243`、`:616-644`、`NativeHudSearch.cpp`。

### 3.4 收藏与 MSR（塞壬唱片）（D-LIB-14）

- `siren` 数据全部本地：`LocalCollections` 提供 `likedIDs` / `playlists` / `tracks` / `setLiked` / `createPlaylist` / `renamePlaylist` / `deletePlaylist` / `creatorID`。证据 `MusicSiren.cpp:7-23`、`MusicMutation.cpp:248-341`。
- 曲库：`/catalog` 一次性拉全量，`lists[3]=songs`、`lists[4]=albums`、`hasMore[3]=hasMore[4]=false`；状态 `已加载塞壬唱片曲库：N 首 / M 张专辑`；失败 `塞壬唱片曲库读取失败：<error>` 且把 `hasMore[3/4]` 复位为 true。证据 `MusicSiren.cpp:28-88`。
- 本地搜索：`pageSize=30`；歌曲匹配 `title/album/artist`，专辑匹配 `title/artist`，歌手按 `trackCount` 降序 + `title` 升序聚合，歌单取自 `lists[2]`；状态 `没有匹配的本地歌单` / `没有匹配的音乐` / `找到 N 条结果`。证据 `MusicSiren.cpp:91-190`。
- 全部歌曲：虚拟歌单 `{id:"siren-all", key:"siren:playlist:all", title:"全部歌曲"}`（动作 `music:open-all-siren`）。证据 `MusicSiren.cpp:193-246`。
- 喜欢列表分页：每次 100 首走 `api songs`，`totals[1]=collections->likedIDs().size()`，状态 `已读取喜欢的歌曲`；`playDirectory` 触发时沿 `m_playLiked` 链继续翻页直到 `hasMore[1]` 为假。证据 `MusicSiren.cpp:251-335`、`MusicLibrary.cpp:1013-1029`。
- `siren` 的 `columns[1..4]` 仍然存在，但 lane 3/4 的内容是曲库而非账号收藏；不得用「未登录」空态覆盖。

### 3.5 歌单写操作矩阵（D-LIB-15）

**可写判定 `canMutate(route)`（D-LIB-16）**：

| provider | 规则 | 证据 |
| --- | --- | --- |
| `siren` | 仅允许 `{/like, /playlist/create, /playlist/name/update, /playlist/delete, /playlist/tracks}` | `MusicMutation.cpp:18-45` |
| `netease` | 全部允许 | 同上 |
| `qq` | 查 capabilities：`/like→[mutations,likeSong]`、`/album/sub→[mutations,subscribeAlbum]`、`/playlist/subscribe→[mutations,subscribePlaylist]`、`/playlist/tracks→[mutations,updatePlaylistTracks]`、`/playlist/create→[playlistManagement,createPlaylist]`、`/playlist/name/update→[playlistManagement,renamePlaylist]`、`/playlist/delete→[playlistManagement,deletePlaylist]`；`capabilities` 为空时**按锁定契约放行**，显式 `false` 才拒绝 | 同上 |
| `kugou` / `local` | 一律拒绝 | 同上 |

**可编辑歌单 `canEditPlaylist(dir)`（D-LIB-17）**：**判定顺序即语义，`siren` 分支必须最前置并立即 return**——

1. `isSiren()` -> `return collections && kind==playlist && creatorID==collections->creatorID()`（**先于** special 与 uid 门；siren 的 uid 恒为空，若把 siren 放到通用门之后就必然恒 false，MSR 歌单改名/删除/加删曲目会整体失效）。
2. `special`（我喜欢的音乐）-> false。
3. `!editable() || uid 空 || kind!=playlist || creatorID!=uid` -> false。
4. `provider != "qq"` -> true（netease/kugou/local 等走到这里即放行；siren 已在第 1 步返回）。
5. `qq` -> `owned && dirId 解析为 1..199`。

证据 `MusicMutation.cpp:47-65`。

| 操作 | 路由 | 载荷 | 成功 | 失败文案 | 证据 |
| --- | --- | --- | --- | --- | --- |
| 喜欢/取消 | `/like` | `{id, like:!liked}`（netease）/ `{id}`（qq） | 本地镜像 + `已加入喜欢的歌曲` / `已从喜欢的歌曲移除` | `无法写入本地收藏`（siren） | `MusicMutation.cpp:248-341` |
| 收藏专辑/歌单 | `/album/sub`、`/playlist/subscribe` | `{id, t: subscribed?2:1}` | 更新 `subscriptions` + lane 3/4 | — | `:365-408` |
| 收藏歌手 | — | qq 直接拒绝 | — | `QQ 上游尚未提供收藏歌手写入` | 同上 |
| 建歌单 | `/playlist/create` | `{name}` | 解析 `body.playlist`，`creatorID=uid`，`lists[2]` 去重前置 | `请输入 1–N 字歌单名称` | `:410-494` |
| 改名 | `/playlist/name/update` | `{id, name}` | 改写 `lists[2]` 标题 + 当前目录 `item.title` | `只能编辑自己创建的歌单` | 同上 |
| 删歌单 | `/playlist/delete` | `{id}`（siren 走本地） | 刷新 `lists[2]` | `无法删除歌单`（siren） | `:167-246` |
| 加/删曲目 | `/playlist/tracks` | `{pid, tracks, op: add|del}` | 补丁当前目录 `cursor`/`trackCount`/`index` | `请选择自己创建的歌单` | `:496-602` |

**写请求协议（D-LIB-18）**：`qq` 走 `api.call("mutate", {route, values})`，其他 provider 走 `api.request(route, values)`；成功判定需 `body.body.code` 默认 `200`，非 200 -> `status=<providerName>返回 N` 且视为失败；成功后 `host->invalidateMetadata()` + `status=已同步至<providerName>`；失败时 `status=result.error`，`qq` 额外清空 `subscriptionStates` 并再次 `invalidateMetadata()`（**写入可能已落地，绝不自动重试**）。所有写操作由 `writeLoading` 串行化。证据 `MusicMutation.cpp:167-246`。

**名称长度（D-LIB-19）**：歌单名按 UCS4 计，`qq` 上限 `20`，其他 `100`；空或超长 -> `请输入 1–N 字歌单名称`。证据 `MusicMutation.cpp:410-494`。

### 3.6 唯一队列 + 历史（D-LIB-20）

**唯一状态源（D-LIB-21）**：播放队列只有 `PlaybackQueue` 一份状态，文档原文见 `PlaybackQueue.h:11-15`：`播放队列的唯一状态源 … 队列只保存完整曲目；缺少元数据的 ID 先补全再发布，界面不会出现占位歌曲.`

| 规则 | 内容 | 证据 |
| --- | --- | --- |
| 曲目身份 | `identity = track[provider] + ":" + track[id]`；`track[provider]` 缺省按 `"netease"` 处理 | `PlaybackQueue.cpp:36-38` |
| 批取大小 | `FetchBatchSize = 100` | `:9` |
| 随机历史上限 | `ShuffleHistoryLimit = 200`（只保留最近实际播放顺序） | `:11` |
| 入队 | 拒绝非 `song` / 空 id；拒绝 `(api->provider==local) != (track[provider]==local)`（本地曲只进本地队列）；已有同曲先移除（当前行除外，移除点在当前行之前时索引减一）；插入位置 `next ? max(0, m_index+1) : size` | `:149-171` |
| 删除 | 当前行与越界一律拒绝 | `:173-183` |
| 清空待播 | 仅保留当前曲为第 0 项；当前不是歌则清空 | `:193-204` |
| 历史记录 | 追加 identity，跳过连续重复，裁剪到 200 | `:214-226` |
| 随机回退 | 后退优先取 `m_history` 的前一首（取走后从历史移除） | `:256-283` |
| 随机前进 | 在 `count-1` 个候选中随机并**排除当前行**，同时把当前行压入 `m_history`（上限 200）；`count<=1` 时返回当前行 | `:256-283` |
| 单曲循环 | `mode==one` 时前后方向都返回当前行 | 同上 |
| 越界 | `mode==off` 且 `selected>=count` 返回 `-1`；其他模式取模回绕 | 同上 |
| 加载 | `m_ids` 按 `provider:id` 去重；已有完整曲目直接进 `m_resolved`；剩余批取；**失败不生成占位曲目** | `:285-331`、`:357-396` |
| 恢复 | `restore` 跳过非歌/空 id；`deferred:true` 仅当占位，不进入 `m_items`；`hydrate -> load(ids, complete)` | `:398-418` |

**播放历史（D-LIB-22）**：最近在前、按 identity 去重、上限 `200`、持久化偏好 `play-history`（登出清空）；入库前把 `wiki` 与 `description` **置为空串（键保留，不删键）**，历史只留可回放入口所需的最小体积；下游仍可安全读取这两个键并拿到空串。证据 `MusicPlayer.cpp:413-422`、`MusicAccount.cpp:670-717`。

**播放模式（D-LIB-23）**：枚举恰好 `{off, all, one, shuffle}`；`setMode` 拒绝其他值。证据 `MusicPlayer.cpp:643-651`。

**音质归一（D-LIB-24）**：`qq` 的 `best`/`ape` 在 `provider!=qq` 时归一为 `lossless`；非 `netease` 时 `jymaster|jyeffect|sky -> lossless`、`higher -> standard`；`kugou` 的 `ape -> lossless`；`siren -> original`。请求 `api.call(preview|playback, {track, effectiveQuality, alternative})`。证据 `MusicPlayer.cpp:367-386`。

**播放故障恢复（D-LIB-25）**：`maxRecoveryAttempts = 2`；恢复中状态 `正在恢复播放（%1/2）…`；本地曲目不重试；`tick` 轮询下限 `0.1 s`；`ended` 串行触发 `onEnd` 或 `next(1,true)`。证据 `MusicPlayer.cpp:471-518`。

**远程播放委托（D-LIB-26）**：存在 `playbackConnection` 时，`player.*` 与 `lyrics.*` 全部转发为远端调用，失败只置 `failed`+状态，**绝不启用第二个本地播放器**。证据 `MusicPlayer.cpp:628-641`、`LyricsController.cpp`（remoteCommand）。

**播放快照键（D-LIB-27）**：`{current, queue, history, index, mode, state, loading, failed, trial, preview, status, quality, actualQuality, alternative, lyrics}`。证据 `MusicPlayer.cpp:686-702`。

### 3.7 歌词（D-LIB-28）

- 来源枚举恰好 `{auto, local, netease, qq, kugou}`；`local` 选择仅在 `provider==local` 时开放，候选上限 `200`，sidecar 后缀 `.lrc`/`.LRC`，单文件 <= `1000000` 字节。证据 `LyricsController.h/.cpp`（selectLocalSource）。
- 文档校验（`validDocument`，`LyricsController.cpp:86-102`）：①`version==1`；②`timing ∈ {line, word, none}`；③`lines` 必须是数组且 `size()<=5000`；④`plainText` 必须是字符串；⑤`offsetMs` 必须是**数值**（`isDouble`，不是 `toInt`）且有限。**逐行也要校验**：遍历 `lines`，每行 `startMs` 必须 `isDouble` 且有限、`text` 必须是字符串，**任一行不合格则整份文档作废**（不是跳过该行）。
- 当前行：`index = upper_bound(starts, position + document.offsetMs + offsetMs) - 1`，无命中为未激活。
- 偏移：`adjustOffset` 夹取 `±10000` ms；`applyGlobalOffset` 持久化偏好 `lyrics-global-offset-ms`；`resetOffset` 归零。
- 行跳转 seek：`line.startMs - document.offsetMs - lyrics.offsetMs`，夹取到 `0..duration`（动作 `player:lyric-line:<i>`，要求 `state[seekable]`）。
- 状态枚举 `{idle, loading, ready, plain, empty, error}`；文案见 §2.4 之外的歌词表：`正在读取歌词…`、`暂无歌词`、`暂无歌词（网易云暂时限流）`、`歌词暂不可用，点击重试`、`暂无歌词 / 纯音乐`（**单条文案，含斜杠与两侧空格；不存在独立的「纯音乐」串**）、`此歌词没有时间信息`、`没有本地歌词文件或内嵌歌词，可选择其他来源`、`本地缺少歌词，正在匹配…`、`本地歌词无法读取，可选择其他来源`、`正在从网易云读取歌词…`、`正在从所选来源匹配歌词…`。
- 限流：网易云歌词请求最小间隔 `1500 ms`，失败后封禁 `60 s`；`siren` 借用网易云源，失败后 `60 s`、空结果后 `600 s` 才允许重试。
- 缓存：最多 `12` 条，持久化偏好 `lyrics-cache`；序列化后 `>= 240000` 字节时**从最旧条目开始逐条淘汰，直到 `< 240000`，然后始终写入**（禁止「超阈值就整份不写」）。
- 快照键：`{document, status, message, key, index, offsetMs, positionMs, globalOffsetMs, localSource}`。

## 4. 动作命名空间（D-ACT-*）

> **源码聚合，T05 重新核对**：本节最初由计划（plan:357）给出的源码聚合清单起草，T05 逐条回读 `Qt/src/NativeHud*.cpp` 与 `Qt/src/Engine.cpp` 后重写。凡与 plan:357 不一致处，以本节为准；本节未列出的新动作视为不存在。

### 4.1 通用规则（D-ACT-1）

1. **入口链路**：`Engine::action(value)` 先拦截 `performance:toggle`、`window:fullscreen`，其余转 `hud.action(value)` 并 `pollMedia` + `wake`；表单走 `Engine::submitForm` -> `hud.form(...)`。证据 `Qt/src/Engine.cpp:850`、`:867`。
2. **切分**：`parts = value.split(':')`，`parts[0]` 是命名空间。证据 `NativeHudController.cpp:485`。
3. **大小写**：分发全程**没有任何 `toLower`/`toUpper` 归一**——动作字符串**大小写敏感**，字面量全小写。`Music:Play`、`PLAYER:TOGGLE` 均视为未知动作。
4. **未知动作**：静默忽略，不报错、不改状态。
5. **载荷解码**：**仅** `music:hint`（`NativeHudMusic.cpp:143-144`）、`music:expand`（`:167-170`）、`discover:category`（`NativeHudController.cpp:613`）的载荷做 URL 解码（`QUrl::fromPercentEncoding`）；**顶层 `expand:` 用原始串、不解码**（`NativeHudController.cpp:777` 直接 `value.mid(7)`，解码会让含 `%`/非 ASCII 的键与源码比较失败、展开状态错乱）；`quality:set`、`archive-mask`、`gpu-index`、`msaa`、`render-scale` 等数值载荷解析失败时使用安全默认，不崩溃。
6. **模态门控先于命名空间**：若存在待提交的 `setting-edit:` 草稿，除 `setting-edit:*` 外的动作先取消草稿（`NativeHudController.cpp:396-398`）。
7. **平台开关门控**：`LocalMusic` 关闭时拒 `local:*` 与 `provider:local`；`OfficialPlayback` 关闭时拒 `music:official`、`player:official`、`music:activate`；`ApplicationVolume` 关闭时拒 `player:volume*`（`:433-437`）。

### 4.2 顶层动作表（无命名空间或独立前缀）

| 动作 | 语法 | 门控 | 语义 | 证据 |
| --- | --- | --- | --- | --- |
| `setting-edit:<id>` | 精确 | — | 开始编辑设置项 | `:399-401` |
| `menu` | 精确 | — | 打开/关闭设置模态 | `:403` |
| `home` | 精确 | — | 关歌词、关模态、关查看器、逐层出目录、回 `archive` | `:414` |
| `settings:scroll-up` / `settings:scroll-down` | 精确 | 设置模态 | 滚动 ±120，夹取到内容高度 | `:439-445` |
| `settings:restore-defaults` | 精确 | —（源码**无模态门**） | 恢复默认设置 | `:447-450` |
| `desktop-lyrics:*` | 前缀 | — | 桌面歌词动作族 | `:451` |
| `setting:<id>:<value>` | 前缀 | — | 写设置值 | `:455-462` |
| `update:check` / `update:cancel` / `update:release` / `update:auto` | 精确 | — | 更新动作；`auto` 切换偏好 `auto-update` | `:465-477` |
| `cache:clear` | 精确 | — | 清缓存 + `已清除` | `:479` |
| `detail:copy` | 精确 | `song && tab ∈ {overview,notes}` | 复制简介 | `:486` |
| `archive:tab-mode` | 精确 | `modal` 为空且支持曲目列表 | 切换 `trackListMode` | `:493` |
| `tab:<name>` | 前缀 | — | 切详情页签；`song && tab!=overview` 时 `sameAlbum` | `:499` |
| `provider` | 精确 | — | 打开音源选择模态 | `:508` |
| `provider:<name>` | 前缀 | — | 名字不同才切源，并重置搜索/结果/偏移 | `:512` |
| `confirm:yes` | 精确 | 存在待确认 | 执行 `m_confirm` 并关模态 | `:525` |
| `local:<cmd>` | 前缀 | `music.isLocal()` | `folder`/`files`/`rescan`/`cancel`/`remove:<i>`/`browse`/`prev`/`next` | `:533-570` |
| `discover:<cmd>` | 前缀 | — | `tab:<t>`/`item:<i>`/`open`/`area:<a>`/`categories`/`category-page:prev|next`/`category:<urlencoded>`/`more` | `:576-618` |
| `player:<cmd>` | 前缀 | 见 §4.3 | 播放器动作族 | `:620` |
| `open` | 精确 | — | 三分支：①`current` 空且无 `directory` 且 `selectedLane==0` -> 开搜索模态；②`current` 非空但 `kind!=song` -> `enterDirectory(current)`；③`current` 为歌曲 -> `mode=detail` + `loadSongWiki()` +（`detail-autoplay==on` 时 `play(false)`，不替换播放列表） | `:624-640` |
| `back` | 精确 | — | 关歌词；目录内按 `frame[mode]` 决定 `returnToDirectory` / `leaveDirectory` | `:641` |
| `column-prev` / `column-next` | 精确 | 有目录 | 目录内 `navigateDirectory(±8)`；否则按 `sourceOrder` 切列 | `:652` / `:660` |
| `prev` / `next` | 精确 | — | `music.next(±1)` | `:656` |
| `music:<cmd>` | 前缀 | 见 §4.4 | 音乐库动作族 | `:666` |
| `viewer:<cmd>` | 前缀 | — | 场景查看器 | `:670` |
| `discover` | 精确 | 非 `siren` | `siren` 直接 `return`（`:674-677`）；否则 `openModal("discover")`，且非 `local` 才 `discover->load()`（`:678-681`） | `:674-681` |
| `skip` / `back`（引导） | 精确 | — | `mode=archive` | `:682` |
| `search` / `saved` / `settings` | 精确 | — | 打开对应模态 | `:684` |
| `close-modal` | 精确 | — | 关闭当前模态 | `:686` |
| `viewer` | 精确 | — | 打开查看器 | `:688` |
| `replay` | 精确 | — | 关模态、`motion.set(false,lastTime,true)`、`mode=boot` | `:690` |
| `alternative` | 精确 | — | 切换备选音源 | `:699` |
| `quality` | 精确 | — | 循环音质 | `:701` |
| `quality:open` | 精确 | — | 打开音质面板 | `:707` |
| `quality:set:<id>` | 前缀 | — | 设定音质 | `:709` |
| `disc-rotation` | 精确 | — | 已开启 -> 关（`discRotation=false` + 偏好 `disc-rotation=off`）；未开启 -> 开确认模态 `disc-rotation-warning` | `:711` |
| `disc-rotation:enable` | 精确 | — | `discRotation=true` + 偏好 `on`，并开设置模态 | `:718` |
| `disc-rotation:cancel` | 精确 | — | 仅开设置模态（不开启旋转） | `:722` |
| `theme` | 精确 | — | 循环 `{light, dark, system}` 并写偏好 `theme`；`dark = themeMode=="system" ? host->systemDark() : themeMode=="dark"`，再 `m_scene.theme(dark)` | `:724` |
| `archive-mask:<v>` | 前缀 | — | 设置档案遮罩强度 | `:729` |
| `detail-autoplay` | 精确 | — | 读偏好 `detail-autoplay`，`on` -> 写 `off`，否则写 `on` | `:736-738` |
| `close-behavior` | 精确 | — | 读偏好，`tray` -> 写 `quit`，否则写 `tray`；该偏好只在点关闭按钮时被消费 | `:739-742` |
| `graphics-backend` | 精确 | — | 循环 `空 -> vulkan -> opengl -> 空`，Windows 且开启 D3D12 构建时 `opengl -> d3d12`；**仅写配置，下次启动生效** | `:743-757` |
| `gpu-index:<i>` | 前缀 | — | 选择 GPU | `:758` |
| `expand:<key>` | 前缀 | — | 展开/折叠设置分组（**原始串**，不解码，`value.mid(7)`） | `:774-780` |
| `fsr-quality:<v>` / `fsr-sharpness:<v>` | 前缀 | — | FSR 档位/锐度 | `:781` / `:790` |
| `aa-mode:<v>` / `msaa:<v>` / `aa-scale:<v>` / `render-scale:<v>` | 前缀 | — | 抗锯齿与渲染比例 | `:799` / `:814` / `:822` / `:830` |
| `fg` | 精确 | — | **仅 Darwin 生效**：非 Darwin 实现整段被注释，静默忽略（不写偏好、不改 `RHINE_FG`）；Darwin 读 `RHINE_FG`（空则读偏好 `fg`）取反写偏好，`Host::setPreference` 随即 `RhineFg::applyInterpolationPreference`，下一帧生效 | `:841-866`、`Host.cpp:1099-1101` |
| `single-play-mode` | 精确 | — | 偏好 `single-play-mode` 在 `append`/`replace` 间互转 | `:867` |
| `startup-animation` | 精确 | — | 反转 + 偏好 `on`/`off` | `:870` |
| `vsync` | 精确 | 非 Darwin | 反转 + 偏好；**Darwin 整段空操作** | `:873` |
| `motion` | 精确 | — | `reduced` 反转 + `m_scene.reduced(...)` + 偏好 `reduced`/`full` | `:880` |

**分发变量**：顶层分发的比较对象是 `value`（完整动作串），不是 `name`——`theme`、`fg`、`vsync`、`motion` 这类**不带冒号的裸词也是顶层动作**，按命名空间检索会整族漏掉。

**数值族精确语义（已逐项核对 `NativeHudController.cpp:729-884`，非「待复核」）**：

- `archive-mask:<v>`：`toInt` 后 clamp `0..100`（`:733`）。
- `gpu-index:<i>`：**仅 Linux**；字面 `default` 清空偏好，否则必须 `toInt` 成功且 `0 <= i < RhineGraphics::gpuDeviceCount()`，否则忽略（`:758-773`）。
- `expand:<key>`：切换 `expandedPreference` 后 `refreshSettingsLayout()`（`:774-780`）。
- `fsr-quality:<v>`：白名单 `{super, performance, balanced, quality, native}`（`:784-785`）。
- `fsr-sharpness:<v>`：clamp `0..100`（`:795`）。
- `aa-mode:<v>`：白名单 `{off, fxaa, ssaa, msaa, taa, fsr, fsr1, fsr3}`，Darwin 追加 `metalfx`（`:803-808`）。
- `msaa:<v>`：仅接受 `{2, 4, 8}`（`:818`）。
- `aa-scale:<v>`：clamp `100..200`（`:826`）。
- `render-scale:<v>`：clamp `50..100`（`:836`）。

迁移时按上表实现，不得臆造新档位；UI 控件区间必须与 clamp 一致。

### 4.3 `player:` 动作表

| 动作 | 语义 | 前置 | 证据 |
| --- | --- | --- | --- |
| `player:lyrics` | 进歌词模式（关模态、`followPlayback`、`mode=detail`） | 有当前曲 | `NativeHudController.cpp:304-392` |
| `player:lyrics-close` | 退出歌词模式 | — | 同上 |
| `player:lyrics-follow` | 切跟随播放 | — | 同上 |
| `player:lyrics-offset` | 开关偏移弹层 | — | 同上 |
| `player:lyrics-earlier` / `player:lyrics-later` | 偏移 ±200 ms | — | 同上 |
| `player:lyrics-reset` | 偏移归零 | — | 同上 |
| `player:lyrics-apply-global` | 写全局偏移偏好 | — | 同上 |
| `player:lyrics-sources` | 打开来源选择 | `local` 且当前曲为本地 | 同上 |
| `player:lyrics-source:<key>` | 选本地歌词源 | **仅 `music.isLocal()`**（不要求当前曲为本地；当前曲可来自任意 provider） | 同上 |
| `player:lyrics-retry` | `load(current, true)` | `current` 非空 | 同上 |
| `player:lyric-line:<i>` | seek 到行起点 | `state[seekable]` | 同上 |
| `player:open` | 打开播放器模态 | — | 同上 |
| `player:toggle` | 播放/暂停 | — | 同上 |
| `player:prev` / `player:next` | 上/下一首 | — | 同上 |
| `player:seek:<n>` | `n/20` 秒 | — | 同上 |
| `player:seek-fraction:<f>` | `f ∈ [0,1]` 比例 seek | — | 同上 |
| `player:volume:<n>` | `n/10` | `ApplicationVolume` | 同上 |
| `player:volume-fraction:<f>` | 比例音量 | `ApplicationVolume` | 同上 |
| `player:mode` | 循环 `off→all→one→shuffle` | — | 同上 |
| `player:mode:<off|all|one|shuffle>` | 指定模式 | — | 同上 |
| `player:queue:<i>` | 播放队列第 i 项 | — | 同上 |
| `player:remove:<i>` | 移除队列第 i 项 | — | 同上 |
| `player:clear` | `clearUpcoming()` | — | 同上 |
| `player:official` | `playOfficial(current)` | `OfficialPlayback` | 同上 |

### 4.4 `music:` 动作表

**门控（D-ACT-2）**：`siren` 拒绝 `{login, logout, qr, login-method, kugou-edition, subscribe, refresh-personal, activate}`；`local` 拒绝 `{login, logout, qr, login-method, kugou-edition, like, like-current, subscribe, create-playlist, delete-playlist, rename-playlist, add-to-playlist, playlist-pick, refresh-personal, activate, remove-track, source, official}`。证据 `Qt/src/NativeHudMusic.cpp:20-379`。

| 动作 | 语义 | 证据 |
| --- | --- | --- |
| `music:sort-menu` | 仅歌单详情打开排序菜单 | 同上 |
| `music:sort:<scope>:<field>` | 排序，`field ∈ {none,title,album,artist}`，仅详情 + 歌单 | 同上 |
| `music:slot:<n>` | 选中第 n 个物理槽 | 同上 |
| `music:index:<i>` | 按视图索引选中 | 四重前置：`trackListMode`、`frame[mode]==archive`、`0<=i<libraryItems().size()`、`libraryItems()[i].kind==song`，任一不满足静默 return；满足后分两路：有目录 -> `selectDirectory(i)`，无目录 -> `raw = groupLane==selectedLane ? groupIndices[i] : i` 再 `selectResult(raw, selectedLane, false)` |
| `music:result:<lane>:<index>` | 结果列表命中 | 同上 |
| `music:album-track:<i>` | 专辑内曲目 | 同上 |
| `music:track:<i>` | 目录内曲目 | 同上 |
| `music:parent` | 返回父目录 | 同上 |
| `music:directory-more` | 目录翻页 | 同上 |
| `music:directory-info` | 打开目录信息页 | 同上 |
| `music:directory` | 有目录则回目录，否则进当前项目录 | 同上 |
| `music:first-track` | 跳到首曲 | 同上 |
| `music:hint:<urlencoded>` | 用建议词检索 | 同上 |
| `music:kind:<0..3>` | 设定搜索类型；带 query 时立即搜索 | 同上 |
| `music:group:<0..2>` | 原序/歌手/专辑分组 | 同上 |
| `music:expand:<urlencoded>` | 展开分组键 | 同上 |
| `music:group-back` | 退出分组 | 同上 |
| `music:artist:<i>` | 打开歌手 | 同上 |
| `music:artist-tab:<songs|albums>` | 歌手页签 | 同上 |
| `music:artist-album:<i>` | 歌手专辑 | 同上 |
| `music:artist-more` | 歌手专辑翻页 | 同上 |
| `music:collection:<0..4>` | 切列 | 同上 |
| `music:more:<0..4>` | 该列加载更多 | 同上 |
| `music:page-prev` / `music:page-next` | 结果翻页 ±5 行 | 同上 |
| `music:play` | 播放当前曲（按 `single-play-mode` 决定是否换队） | 同上 |
| `music:preview` | 试听（仅 qq） | 同上 |
| `music:play-next` / `music:enqueue` | 下一首播放/入队，2 秒反馈 | 同上 |
| `music:play-loaded` | `playDirectory()` | 同上 |
| `music:remove-track` | 从当前歌单移除当前曲 | 同上 |
| `music:picker-prev` / `music:picker-next` | 歌单选择器翻页 ±7 | 同上 |
| `music:official` | 官方播放 | 同上 |
| `music:copy` | 复制 `<providerName> ID` | 同上 |
| `music:source` | 打开原始来源 URL | 同上 |
| `music:project-home` / `-author` / `-player` / `-kugou` / `-rhine` / `-lyricsx` / `-lyricskit` / `-lyrimuse` | 打开项目链接表 | 同上 |
| `music:login` | 打开登录模态、`loginMethod=qr`、`startLogin` | 同上 |
| `music:kugou-edition:<standard|lite>` | 切 edition，登录模态打开时继续 `startLogin` | 同上 |
| `music:login-method:<qr|phone|wechat>` | 切登录方式（受 D-AUTH-2 限制），`cancelLogin` 后按需 `startLogin` | 同上 |
| `music:refresh-personal` | 刷新个人音乐（仅 qq 有效） | 同上 |
| `music:like` / `music:like-current` | 喜欢/取消 | 同上 |
| `music:subscribe` | 收藏/取消收藏（专辑/歌单/歌手） | 同上 |
| `music:create-playlist` / `music:rename-playlist` / `music:delete-playlist` | 歌单表单；删除需 `canEditPlaylist` + 二次确认 | 同上 |
| `music:add-to-playlist` | 加入歌单 | 同上 |
| `music:playlist-pick:<id>` | 选定歌单 | 同上 |
| `music:open-all-siren` | 塞壬全部歌曲 | 同上 |
| `music:qr` | 重新生成二维码 | 同上 |
| `music:logout` | 登出 | 同上 |
| `music:cover-front` / `music:cover-back` | 封面翻面 | 同上 |
| `music:activate` | 切换 `activates` 开/关（`setActivates(!activates())`） | 同上 |

**反馈文案（D-ACT-3）**：加队/下一首的 2 秒反馈文案为 `未能加入，请重试`、`✓ 已设为下一首`、`✓ 已加入队列`；`SongActionFeedbackDurationMs = 2000`。

**动作优先级（D-ACT-4）**：分发按**固定书写顺序** `if/else if` 命中，先写的分支遮蔽后写的；已知遮蔽点：`back` 同时出现在目录返回分支（`:641`，先写）与引导分支（`:682`，后写）——有目录时先写的 `:641` 命中，引导分支被遮蔽；`discover` 精确匹配与 `discover:*` 前缀并存。新增动作必须插在同类前缀之前并更新本文。

## 5. 会话与持久化（D-STATE-*）

### 5.1 session.json 结构（D-STATE-1）

`NativeApplication::sessionState = {version:1, library, player, view}`；`library` 键见 `MusicLibrary::sessionState()`：`provider, edition, uid, sources[5]{items,total,offset,more,row}, directories<=64{item,songs,sortField,ids,albums,cursor,index,anchor,page,parentPhysical,parentLane,parentItem,albumCursor,albumsMore}, current, selectedPhysical, selectedLane, keyword, searchKind, status, searchLoading, directoryLoading, detailLoading, privateSelection, searchCursor, playlistCursor, albumCursor, likedCursor, likedIDs, groupName, groupIndices, groupLane, tracks, trackIDs, trackCursor, albumLoaded, playContext, directoryInfo, wantsSongDetails, discover{tab,items,offset,more,category,newSongArea}`；`view` 键：`mode, selected, tab, modal, queueOffset, settingsScroll, query, groupBy, activeGroup, artistTab, listOffset, trackOffset, bodyOffset, musicCollection, trackListMode, lyricsMode`。证据 `MusicSession.cpp`。

**边界（D-STATE-1b）**：`session.json` 与 QSettings 是两套持久化，不得互相替代——`session.json` 只承载上列 `library`/`player`/`view` 运行态；账号凭据、界面偏好与全部白名单键都在 QSettings（§5.4 为唯一定义）。§2.8 只标注账号键的**写入点**，不重复定义键表。

### 5.2 恢复校验（D-STATE-2）

- `version != 1`，或 `library` 恢复失败（`MusicSession.cpp:238-240`）-> 整份丢弃（`view` 与 `player` 也不再恢复）。
- `provider`/`edition`/`uid` 任一不等 -> `restoreSessionState` 返回 false，按上条整份丢弃（不做跨账号迁移）。
- `sources.size()==5`；`selectedLane ∈ 0..4`；`selectedPhysical ∈ -1..39` 且必须存在于 `physicalSlots[lane]`。
- 夹取（越界静默修正，不判存档无效）：`offset ∈ 0..max(0,size-1)`（`MusicSession.cpp:110`）、`row ∈ 0..7`（`:111`）、`index ∈ 0..max(0,songs-1)`、`anchor ∈ 0..39`、`parentPhysical ∈ 0..39`、`parentLane ∈ 0..4`、`page=index/40*40`（`:127-132`）；`groupLane ∈ -1..4`（`:150`）；`selected ∈ 0..39`（`:260`）、`settingsScroll ∈ 0..settingsScrollMaximum()`（`:247`）、`queueOffset`/`listOffset`/`trackOffset`/`bodyOffset` 非负（`:246`、`:254-256`）、`albumCursor` 非负（`:134`）；`sortField` 白名单 `{none,title,album,artist}`。
- 有 `searchLoading && keyword` 时重放搜索；`directoryLoading && songs 空` 时重进目录；`detailLoading` 时 `choose`；`siren` 重建 collections 与 lane 3/4。
- `modal` 白名单 `{saved,search,discover,queue,settings,player,local}`；`tab ∈ {overview,notes,history}`；`musicCollection` 夹取 `1..4`；`mode==detail` 仅当 `current` 非空；有 `playbackConnection` 时不恢复本地播放器状态。

### 5.3 落盘（D-STATE-3）

路径 `AppStorage::dataDirectory()+"/session.json"`，`QSaveFile` 原子写；序列化后 `> 64 MiB` -> 放弃写入并保留旧档（提示 `会话过大，已保留原有存档`）。证据 `MusicSession.cpp:213-284`。

### 5.4 偏好键白名单（D-STATE-4）

`search-history, play-history, local-cover-cache, theme, motion, startup-animation, detail-autoplay, single-play-mode, disc-rotation, scene-enhancement, archive-mask-strength, graphics-backend, gpu-index, vsync, supersample, render-scale, aa-mode, aa-scale, msaa, fsr-quality, fsr-sharpness, fg, close-behavior, auto-update, volume, quality, alternate-source, provider, lyrics-cache, lyrics-global-offset-ms, welcome-name-{netease,qq,kugou,kugou-standard,kugou-lite}, account-id-{netease,qq,kugou,kugou-standard,kugou-lite}, kugou-edition, desktop-lyrics{,-size,-translation-size,-opacity,-line-color,-translation-color,-line-weight,-translation-weight,-line-outline,-translation-outline,-line-outline-color,-translation-outline-color}`。**共 53 键**：基础 30 + `welcome-name-*` 5 + `account-id-*` 5 + `kugou-edition` 1 + `desktop-lyrics*` 12；`preferenceKeys()` 是唯一权威，新增键必须同时改该表与本节。证据 `Host.cpp:1041-1058`。

## 6. 迁移不变量（D-INV-*）

1. **禁止 LoggedOut 六态模板**：登录态不是 `LoggedOut/LoggingIn/...` 的六态枚举，而是「provider + method + edition」的六条路径 × 六阶段。六态枚举会把 SMS 错误地摊到 QQ/酷狗，直接违约。
2. **禁止 3×qr/sms 对称模板**：只有 `netease` 有 SMS；`qq` 的两个通道是 `qq`/`wechat`，不是 `qr`/`sms`；`kugou` 的差异是 edition，不是 method。
3. **801 不推进阶段**；800 按 provider 走两条不同分支。
4. **冷却必须墙钟**，不得用 tick 计数。
5. **cancel 屏障**：QQ 重生成/切通道前必须等 `/login/qr/cancel` 回包。
6. **队列单一状态源**：不得在 UI 层另存队列副本；不得发布占位曲目。
7. **本地/在线不混队**：`enqueue` 的 provider 一致性检查必须保留。
8. **歌词偏移单一来源**：`document.offsetMs + lyrics.offsetMs` 只在一处合成，行 seek 公式必须反解同一和。
9. **动作大小写敏感**，未知动作静默。
10. **q 与酷狗无 SMS**：任何 UI 若在这两个 provider 上渲染验证码输入框即为违约。

## 7. 登录矩阵夹具契约（D-FIX-*）

### 7.1 文件（D-FIX-1）

`test/fixtures/login_matrix.json`，UTF-8，`version: 1`。它是**登录路径的机读规格**，测试与实现共用；不得包含 UI 布局信息。

### 7.2 结构（D-FIX-2）

    {
      "version": 1,
      "source": "Qt/src/MusicAccount.cpp@8ed3067b0812eb2612f7841ec127a6e8ca93231b",
      "shared": {
        "phases": ["idle","preparing","waiting","confirming","failed","complete"],
        "pollIntervalMs": 1000,
        "pollLimit": 300,
        "smsResendMs": 60000,
        "phonePattern": "^1[0-9]{10}$",
        "captchaPattern": "^[0-9]{4,8}$",
        "qrCodes": {"expired": 800, "waiting": 801, "scanned": 802, "confirmed": 803},
        "retryAfterUnit": "ms",
        "cooldownClock": "wall",
        "scanPromptTemplate": "请用{scanner}扫描并确认登录",
        "loginStatusSuccessTemplate": "已登录：{nickname}",
        "smsSendGuard": "provider==netease && !accountLoading && smsRetrySeconds()==0",
        "statuses": { "preparing": "…", "scanned": "…", "success": "…" }
      },
      "paths": [ { ... } ]
    }

**夹具为字段名与取值的唯一权威**（`test/fixtures/login_matrix.json`：6 条路径、10 个 `continuesPolling` 标记、`statuses` 共 11 个键）。上文只是骨架；测试直接反序列化夹具，不复制常量。

每个 `paths[]` 元素：

    {
      "id": "netease-qr",
      "provider": "netease",
      "method": "qr",
      "edition": null,
      "accountKey": "netease",
      "entryActions": ["music:login", "music:qr"],
      "qrChannel": null,
      "scannerKey": "providerName",
      "supportsSms": false,
      "cancelBarrier": "none",
      "steps": [
        {"on": "qr-code:801", "phase": "waiting", "phaseChanged": false, "continuesPolling": true, "status": "请用{scanner}扫描并确认登录"},
        {"on": "qr-code:802", "phase": "confirming", "phaseChanged": true, "continuesPolling": true, "status": "已扫描，请在手机上确认"},
        {"on": "qr-code:803", "phase": "complete", "phaseChanged": true, "status": "已登录，可读取我的音乐"},
        {"on": "qr-code:800", "phase": "failed", "phaseChanged": true, "status": "二维码已过期，请重新生成"},
        {"on": "poll-timeout", "phase": "failed", "phaseChanged": true, "status": "二维码超时，请重新生成"}
      ]
    }

`qq-*` 额外有 `scanner: "手机 QQ"/"微信"` 与 `cancelBarrier: "upstream"`；`kugou-lite` 额外有 `providerNameOverride: "酷狗概念版"` 和两步 `entryActions`；`netease-phone` 有 `action:send-login-code-blocked`（`silent: true`）。

**门控串极性（唯一定义，不得二次改写）**：`shared.smsSendGuard` 是**放行**谓词（`provider==netease && !accountLoading && smsRetrySeconds()==0`）；`action:send-login-code-blocked` 的 `steps[].reason` 是**拦截**谓词（`provider!=netease || accountLoading || smsRetrySeconds()>0`），语义等价于 `Qt/src/MusicAccount.cpp:403` 的 `if (provider != "netease" || accountLoading || smsRetrySeconds() > 0) { return; }`（去掉引号与空格后的规范化串，非逐字复制）。两者互为补集，极性相反：断言各自按本义取值，禁止把 `==0` 与 `>0` 混用（历史缺陷 A15 即由此产生）。

**D-FIX-3 字段语义**：

| 字段 | 类型 | 约束 |
| --- | --- | --- |
| `id` | string | 六条之一，见 §2.1 |
| `provider` | enum | `netease`/`qq`/`kugou` |
| `method` | enum | `qr`/`phone`/`wechat` |
| `edition` | `standard`/`lite`/null | 仅 `kugou` 非空 |
| `accountKey` | string | `kugou ? "kugou-"+edition : provider` |
| `entryActions` | string[] | 必须出现在 §4.4 动作表 |
| `qrChannel` | `qq`/`wechat`/null | 仅 `provider==qq` 非空 |
| `scannerKey` | `providerName`/null | 空值表示用 `scanner` 字面量（QQ 两条路径）；无二维码步骤的路径（`netease-phone`）亦为 `null`，且不得出现 `scanner` 键 |
| `scanner` | string | 仅 QQ：`手机 QQ`/`微信`；其余用 `providerName()` |
| `providerNameOverride` | string | 仅 `kugou-lite`：`酷狗概念版` |
| `supportsSms` | bool | 仅 `netease-phone` 为 true |
| `cancelBarrier` | `upstream`/`none` | 仅 `provider==qq` 为 `upstream` |
| `steps[].on` | string | 事件键：`qr-code:800/801/802/803`、`poll-timeout`、`action:*`、`invalid-*` |
| `steps[].phase` | 六阶段之一 | 见 §2.2；captcha 成功保持 `idle` |
| `steps[].phaseChanged` | bool | `801` 与 captcha 成功为 `false`；`802`/`803`/`800`/`poll-timeout` 为 `true` |
| `steps[].continuesPolling` | bool | `801`/`802` 为 `true`；`800`/`803`/`poll-timeout` 不设 |

### 7.3 测试契约（D-FIX-4）

`test/login_matrix_test.dart`（只编写，不执行；无 `flutter test` 运行记录）：

| # | 断言 | 反例（Fail 条件） |
| --- | --- | --- |
| A1 | `paths.length == 6` 且 id 集合恰为 `{netease-qr, netease-phone, qq-qr, qq-wechat, kugou-standard, kugou-lite}` | 出现 `netease-sms`/`qq-sms`/`kugou-sms` |
| A2 | `netease.methods == {qr, phone}`、`qq.methods == {qr, wechat}`、`kugou.methods == {qr}` 且 editions `== {standard, lite}` | 任一 provider 出现 `sms`，或出现 3×`qr` 模板 |
| A3 | `supportsSms == true` 的路径**恰好一条**，且其 `provider == netease` | QQ/酷狗出现验证码输入 |
| A4 | `kugou-*` 的 `accountKey ∈ {kugou-standard, kugou-lite}` 且两者互异 | 酷狗共用 `kugou` 槽 |
| A5 | `shared.phases` 恰为六值且顺序固定 | 出现 `loggedOut`/`codeSent` 等 UI 态 |
| A6 | `shared.pollIntervalMs == 1000`、`pollLimit == 300`、`smsResendMs == 60000` | 30 s / 60 次 / 120 s 等魔改 |
| A7 | `qrCodes == {800,801,802,803}` 且 `801.phaseChanged == false` | 801 推进阶段 |
| A8 | `cancelBarrier == "upstream"` 当且仅当 `provider == qq` | 网易走 QQ 屏障，或 QQ 跳过屏障 |
| A9 | `retryAfterUnit == "ms"` 且 `cooldownClock == "wall"` | `s`/`tick` |
| A10 | 每条**含 `qr-code:*` 步**的路径 `steps` 覆盖 `waiting/confirming/complete/failed` 四阶段（`netease-phone` 不含 QR 步故不适用；`qq-wechat` 的 `method` 是 `wechat` 但**必须**纳入） | QR 路径缺 `failed` |
| A11 | `phonePattern`/`captchaPattern` 与 §2.7 逐字一致 | 宽松正则 |
| A12 | fixture 中不存在键名匹配 `(?i)logged.?out|six.?state` 的节点 | 六态模板 |
| A13 | `netease-phone` 的 `action:captcha-login` 步 `phase == "idle"` 且 `phaseChanged == false`（`confirmLogin(captcha=true)` 不写 `complete`） | 把 captcha 成功写成 `complete` |
| A14 | 所有 `qr-code:801`/`qr-code:802` 步 `continuesPolling == true`，`qr-code:803`/`qr-code:800` 无该键 | 802 后停止轮询 |
| A15 | `netease-phone` 存在 `action:send-login-code-blocked` 且 `silent == true`、`status == null`，其 `reason` **整串等于** `provider!=netease || accountLoading || smsRetrySeconds()>0`（`MusicAccount.cpp:403` 的**拦截**谓词） | 把静默守卫当失败文案，或用放行谓词（`==0`）冒充拦截谓词，或加取反（`!accountLoading`） |
| A16 | `shared.statuses` 非空且每个取值都是非空串；`scanPromptTemplate` 保留 `{scanner}`、`loginStatusSuccessTemplate` 保留 `{nickname}`；`smsSendGuard` **整串等于** `provider==netease && !accountLoading && smsRetrySeconds()==0` | 文案漂移为空串、模板丢失占位符、guard 前缀被换成别的 provider、两处门控极性混用 |

测试实现要求：纯 Dart、只读夹具、无网络、无 `WidgetsFlutterBinding` 依赖；失败信息需打印路径 id 与实际值，便于定位。

**QR 路径判定规则**：凡断言「QR 路径」处一律按 `steps` 中是否存在 `qr-code:*` 步判定，**不得**按 `method=='qr'` 过滤——`qq-wechat` 的 `method` 是 `wechat`，却完整包含 801/802/803/800，按 method 过滤会静默漏掉它（A7/A10 历史缺陷即此）。

### 7.4 与实现的关系（D-FIX-5）

夹具是**规格**不是配置：Flutter 实现不得在运行时读取 `test/fixtures/login_matrix.json`。生产代码中的六条路径/六阶段/常量必须与夹具一致，由测试守护。

## 8. 已复核关闭与未决（D-OPEN-*）

**已复核关闭（2026-11-10，基线源码只读核对）**：

- `providerName` 逐字串：`local=本地音乐`、`qq=QQ 音乐`（中间有半角空格）、`kugou=酷狗音乐`、`kugou+lite=酷狗概念版`、`siren=塞壬唱片`、其余=`网易云音乐`。证据 `Qt/src/MusicApi.cpp:10-24`、`Qt/src/MusicLibrary.cpp:106-111`。二维码就绪文案里的 `{scanner}` 对 `qq` 取 `微信`/`手机 QQ`，其余取 `providerName()`。
- `MusicBridge` 的 `/login/qr/check` **不做 code 归一**：`qq.cjs` 非 2xx 仅重写为 `{code:HTTP 状态, message, retryAfterMs, ...safeQrDiagnostics}`，2xx 原样透传（唯一例外是 `/getLyric` 归一）；`worker.cjs` 把 `loginQrCodeCheck` 结果直接返回。因此 800/801/802/803 的判定完全在 Qt 侧（`MusicAccount.cpp:665`），Flutter 侧必须自己判，不能指望桥接层给统一 code。

**仍未决**：

1. `LocalCollections` 的磁盘格式（是否 JSON、字段名）未读；只冻结了对外 API 语义。
2. 竖屏重排的布局语义不在本文范围（由布局卡负责），但**状态与动作必须复用本文**。

> 原「设置面板数值族 clamp 未读」一条已于 v1.2 关闭，精确区间见 §4.2「数值族精确语义」。

## 9. 变更记录

| 版本 | 日期 | 变更 | 作者 |
| --- | --- | --- | --- |
| v1.3 | 2026-11-10 | T05 静态复核（只读，未执行任何命令）：§4.2 补回 v1.2 声称已加但表中缺失的三个顶层裸词动作 `detail-autoplay`/`close-behavior`/`graphics-backend`；`discover` 的 `siren` 门控；`music:kugou-edition` 为**无条件**调用、幂等早返回在 `switchProvider` 内部；`restoreIdentityName` 用独立 `m_identityApi`；§2.11 的 `provider` 赋值先于 edition 块；§2.3 补路由前缀（非 netease 自动加 `/<provider>`）与「QQ/酷狗同走上游出图」；D-LIB-2 的 netease 证据文件纠正；`enterDirectory` 的 local 分支保留 `正在打开：` 文案；§5.2 补齐 `selected`/`settingsScroll`/`queueOffset`/`groupLane` 夹取与 `library` 恢复失败即整份丢弃；§5.4 标明 53 键构成与 QSettings/`session.json` 边界 | T05 |
| v1.2 | 2026-11-10 | 独立审查（R1）闭合修订：`canEditPlaylist` 的 `siren` 分支必须最前置；补 `restoreIdentityName`；§4.2 补 10 个顶层裸词动作（`disc-rotation` 三态/`theme`/`detail-autoplay`/`close-behavior`/`graphics-backend`/`single-play-mode`/`startup-animation`/`vsync`/`motion`，`fg` 仅 Darwin 生效（非 Darwin 整段注释））并写明分发变量是 `value` 而非 `name`；五个数值族 clamp 精确化；歌词 `validDocument` 补逐行 `startMs`/`text` 校验；`enterDirectory` 的 `kind==song` 短路前置与三条加载路径；翻页 `direction`/回绕；栈深静默夹取；`open` 三分支；`lyrics-source` 前置；顶层 `expand:` 不解码；`restore-defaults` 无模态门；歌词缓存逐条淘汰；`music:index` 四重门；历史条目置空串而非删键；「暂无歌词 / 纯音乐」单串；§2.3 网易无空图校验、QQ 文案带 `providerName()` 前缀；§2.11 `done(false)`/`done(true)` 语义与重置字段；§2.6 屏障因果断言降级为设计意图；§1 `provider` 白名单证据指针 | T05 |
| v1.1 | 2026-11-10 | 源码复核修订：cancel 屏障非 QQ 分支与 QQ 自建屏障、803 先置 `confirming`、缺 code 默认 800 与响应白名单、失败分类 16 条取数层次（`lastFailure`/`primaryFailure`/外层 `details`）、冷却仅 `retry>0` 且 captcha 不清阶段、`restoreCachedAccount` 昵称空条件、`confirmLogin`/`logout`/`switchProvider` 完整副作用、siren 列名、搜索长度与历史上限、队列随机前进与历史剥字段；关闭 providerName 与 Bridge 归一两项未决 | T05 |
| v1 | 2026-11-09 | 初版冻结：六路径/六阶段/QR 时序/冷却/屏障/SMS/五 lane/目录栈/搜索四型/MSR/写操作/队列/歌词/动作命名空间/会话 | T05 |

## 10. 验证状态

- 本文为**源码契约**，不含可执行验证。
- v1.1 复核读域（只读）：`Qt/src/MusicAccount.cpp` 全文、`Qt/src/MusicLibrary.h` 全文、`Qt/src/PlaybackQueue.cpp`/`.h` 全文、`Qt/src/MusicPlayer.cpp` 关键段、`MusicBridge/qq.cjs` 全文；补充 `Qt/src/MusicLibrary.cpp`、`Qt/src/MusicSession.cpp`、`Qt/src/MusicApi.cpp`、`Qt/src/NativeHudMusic.cpp`、`Qt/src/NativeHudSearch.cpp`、`MusicBridge/worker.cjs` 相关段。
- 读域列出的 `Qt/src/MusicSearch.cpp` 在基线中**不存在**（glob 核对 `Qt/src/*.cpp`）；搜索契约改由 `MusicLibrary.cpp:440-495` 与 `NativeHudSearch.cpp:63-69` 取证，未以文件缺失为由跳过该节。
- v1.2 追加只读核对：`Qt/src/MusicMutation.cpp`（canEditPlaylist/canMutate/写协议）、`MusicDirectory.cpp`（enterDirectory/navigateDirectory/loadDirectoryPage）、`MusicSession.cpp`（恢复夹取）、`LyricsController.cpp`（validDocument/缓存淘汰/文案）、`NativeHudController.cpp:711-884`（顶层裸词动作与数值族 clamp）、`NativeHudMusic.cpp:79-170`（music:index/hint/expand）。
- v1.3 追加只读核对：`Host.cpp:1041-1109`（偏好白名单与读写门）、`MusicLibrary.cpp:18-45`/`:106-171`、`MusicMutation.cpp` 全文、`MusicDirectory.cpp` 全文、`PlaybackQueue.cpp`/`.h` 全文、`MusicPlayer.cpp` 关键段、`LyricsController.cpp` 全文、`MusicSiren.cpp`、`MusicLocal.cpp`、`MusicSession.cpp` 全文、`NativeHudController.cpp` 顶层与 `player` 表、`NativeHudMusic.cpp` 全文、`MusicApi.cpp`、`Engine.cpp:850-875`。
- 按当前任务约束，**未执行** `flutter test`、`flutter analyze`、`dart format` 或任何构建命令；`test/login_matrix_test.dart` 仅为待运行代码。
- 未做设备验证：APK、真机登录、扫码、IME、后台恢复一律 `DEVICE_BLOCKED`，本文不宣称其通过。




