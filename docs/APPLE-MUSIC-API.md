# Apple Music 模式开发文档

更新：2026-10-21

## 接入结构

Qt 界面 → MusicApi → Host `/native/apple/{operation}` → AppleMusic 适配层。

- `Qt/src/AppleMusic.cpp`：稳定门面、异步串行调度、请求过期隔离、播放核验与缓存状态。
- `Qt/src/AppleMusicClient.mm`：官方 Scripting Bridge、自动化权限、资料库读写与播放器命令；只返回普通 Qt 数据，不依赖 Host、账号或歌词控制器。
- `Qt/src/AppleMusicCatalog.mm`：官方公开 iTunes Search / Lookup 查询、限流与候选补查。
- `Qt/src/AppleMusicPlayback.h`：完整快照到界面状态的转换、自然曲尾识别和外部切歌隔离。
- `Qt/src/AppleMusicStart.h`：启动录音与进度核验，支持纯数据回归。
- `Qt/src/RecordingMatch.cpp`：纯元数据录音匹配，供原生播放核验与歌词补充共同使用。
- `Qt/src/LyricsController.cpp`：歌词和封面补充；保留旧匹配入口兼容调用方，不读取 Apple 歌词接口。
- `Qt/apple/CMakeLists.txt`：使用 `sdp` 从系统 Music.sdef 生成 Music.h，仅保存到构建目录。

## 身份、授权和线程

应用 Bundle ID 沿用 `rhine.music.database`。Info.plist 使用 `NSAppleEventsUsageDescription`，
不使用 MusicKit entitlement。连接时通过 `AEDeterminePermissionToAutomateTarget` 请求控制
`com.apple.Music`，之后读取权限时不再主动弹窗。用户可在系统设置 → 隐私与安全性 → 自动化中管理。

面板只保存 `apple-connected` 连接偏好和固定的本机会话标记 `apple-local-session`，不读取
Apple ID、邮箱、密码或令牌。这个标记不能证明订阅有效。切换 Apple 账号在 Music 中操作后重新连接。

模块依赖保持单向：业务只调用 `AppleMusic.h` 门面，门面协调系统客户端与目录检索；
两种适配器只共享 MusicData 数据契约与 RecordingMatch，不相互调用。系统对象不得传到业务层，
底层适配不得反向依赖 LyricsController、MusicAccount 或 Host。新增接口先判断所属职责，
避免把系统调用、搜索补查和界面状态继续叠到一个函数，也不为单次转发制造额外层次。

Apple Events 通过单线程 QThreadPool 串行运行，主线程只使用 JSON。每个请求捕获连接代数，
每次播放另外捕获播放代数。切来源、断开、停止和再次切歌会隔离旧回调；旧播放交付不能重新恢复发声。
写操作只执行一次并回读确认，不自动重试。回读确认不代表第二台设备已经完成云同步。

## 面板 API 契约

入口：`AppleMusic::request(owner, operation, arguments, callback)`。
成功响应：`{"body":{"code":200,"value":...}}`；业务失败 code=400，message 为可显示错误。
传输或播放核验失败也可经 callback 的 error 参数传递。接收对象销毁后不交付回调。

| operation | arguments | value / 说明 |
| --- | --- | --- |
| authorize | `[]` | `["apple-local-session","Apple Music 用户"]`；允许系统弹出自动化授权 |
| account | `[]` | 同上；只验证权限和 Music 资料库可读，不请求新权限 |
| capabilities | `[]` | 创建歌单、增加已有资料库歌曲的能力 |
| search | `[关键词, song/album/artist/playlist, 偏移]` | `{items,rawCount,total,more,notice}`；歌单检索返回明确限制 |
| suggest | `[关键词]` | 空数组；不虚构联想服务 |
| songs | `[[目录歌曲 ID]]` | 已经国区 Lookup 确认的歌曲数组，不接受本地持久 ID |
| detail | `[条目对象]` | `[完整条目,歌曲数组,歌曲ID数组]`；资料库目录优先读取原生对象 |
| artistAlbums | `[目录艺人ID,偏移]` | 有限公开专辑集合的本地分页 |
| librarySongs | `[偏移]` | 全部可读取资料库歌曲，供扩展调用；当前主栏目显示喜爱歌曲 |
| likedSongs | `[偏移]` | 只包含 `favorited=true` 的歌曲，不把整个曲库当作喜爱 |
| likedAlbums | `[偏移]` | 保留旧业务操作名；实际是资料库专辑，界面明确标为“资料库专辑” |
| userPlaylists | `[本机会话标记,偏移]` | 自有普通歌单和已有喜爱歌单；owned / creatorID 区分可编辑性 |
| favoritePlaylists | `[本机会话标记,偏移]` | 仅已有喜爱歌单；当前主业务通过 userPlaylists 分栏 |
| mutate | `[路由,参数对象]` | 下表中的原生写操作，完成后回读核实 |
| open | `[条目对象]` | 目录链接交给 Music；曲库歌曲使用 reveal，不自动开始播放 |
| wiki | `[条目对象]` | 明确说明百科内容需在官方页面查看 |
| lyrics / discover / categories | 依既有业务传入 | 无等价已接入接口，返回明确提示；推荐界面提供打开 Music 入口 |

页面大小 40。rawCount 为本次实际消费条数；more 只表示已取得的有限集合中还有条目，
不伪装 iTunes API 具有无限远程分页。失败与合法空结果分开处理。

## ID 与元数据

公共目录 ID 保存为十进制字符串，不能经过 32 位整数。原生曲目 ID 为 `lib_` 加持久 ID，
歌单 ID 为 `pl_` 加持久 ID；资料库专辑按 albumArtist 与 album 的组合生成 `album_` 稳定哈希。
目录 ID、原生持久 ID 与专辑分组 ID 不混用。原生当前歌曲可能尚未加入资料库，持久 ID 可读
并不意味着它一定能在 library playlist 中找到。

条目遵循 MusicData：`id,kind,key,provider,title,artist,artists,album,albumID,duration,cover,sourceURL`。
Apple 补充 `catalogID,persistentID,appleType,favorited,owned,creatorID,trackNumber` 等适用字段。
Music 字典 duration / playerPosition 的单位为秒；进入 Qt 必须乘 1000，跳转反向除 1000。
官方播放器的 0–100 音量映射成面板 0–1，不代表系统输出设备音量。

## 公开查询

所有查询使用 `https://itunes.apple.com`，不携带 Music 账号令牌。
本次首版针对已确认的中国大陆账号，公开查询地区固定 `cn`，不是自动推断账号地区。

| 用途 | 官方调用 |
| --- | --- |
| 国区艺人检索 | `/search?term=关键词&country=cn&entity=musicArtist&limit=50` |
| 歌曲／专辑候选 | `/search?term=关键词&country=tw&entity=song或album&limit=50` |
| 国区批量确认 | `/lookup?id=逗号分隔ID&country=cn` |
| 国区艺人曲目 | `/lookup?id=艺人ID&country=cn&entity=song&limit=200` |
| 国区近期艺人曲目 | 上一调用加 `sort=recent` |
| 国区艺人专辑 | `/lookup?id=艺人ID&country=cn&entity=album&limit=200` |
| 国区专辑内容 | `/lookup?id=专辑ID&country=cn&entity=song&limit=200`；可能只有专辑，无曲目 |

搜索先取台湾候选，再批量核对国区；已有匹配关键词的国区结果即返回，仅没有关键词命中时按前两个候选艺人的国区近期／默认集合补查。
相同在途 URL 合并等待者；关键词变化后旧搜索不再继续串联补查，不为填满页面固定发送所有请求。
候选归一采用系统 Foundation 的 Traditional-Simplified、NFKC 和大小写归一。
补查要求标题、专辑一致且时长差不超过 2 秒，保留版本标记；不能简单改写外区链接的地区。
有明确国区 country=CHN 且 music.apple.com/cn 链接才作为已确认国区结果。

每次公开 HTTP 请求至少间隔 3100 毫秒，串行发送，超时 20 秒；成功响应缓存 5 分钟，最多 100 项。
这一索引不等于完整 Apple Music 目录。没有命中不能推出没有版权；HTTP 200 的条目存在也不能
单独证明当前订阅可播放。香港、美国候选曾作为原型补查，覆盖不足，产品首版未叠加这些请求。

## 官方 Music 调用清单

系统字典：`/System/Applications/Music.app/Contents/Resources/com.apple.Music.sdef`。
声明由 `sdp -fh --basename Music -o 构建目录 Music.sdef` 生成，依赖系统 ScriptingBridge.framework。

| 功能 | 官方字典 / 原生调用 |
| --- | --- |
| 定位曲库 | sources 中 kind=library 的 source，再取 libraryPlaylists.firstObject |
| 全曲库批读 | tracks 的 persistentID / name / artist / album / albumArtist / duration / favorited / albumFavorited |
| 曲库内查找 | tracks 按 persistentID 过滤；原型也验证了 playlist searchFor，只有曲库内搜索能力 |
| 普通歌单 | source.userPlaylists；读取 smart、genius、shared、specialKind 确认可编辑范围 |
| 创建歌单 | classForScriptingClass("user playlist")，initWithProperties(name)，加入 userPlaylists |
| 改名／删除 | playlist.name / playlist.delete |
| 加已有歌曲 | track.duplicateTo(playlist)，避免重复插入，再回读持久 ID |
| 移除歌单歌曲 | 只删除该 playlist 中匹配曲目的对象，不删除曲库歌曲 |
| 喜爱歌曲 | track.favorited，设置后回读 |
| 喜爱专辑 | track.albumFavorited，设置后回读；原型未进行真实反向切换验收，可能影响曲库 |
| 喜爱已有歌单 | playlist.favorited，设置后回读 |
| 已入库歌曲播放 | track.playOnce(YES)；不能假定该参数在自动连播开启时必定阻止后续歌曲 |
| 暂停／继续／停止 | app.pause / app.playOnce(NO) / app.stop |
| 当前真实歌曲 | app.currentTrack 的 name / artist / album / persistentID / duration |
| 播放状态与进度 | app.playerState / app.playerPosition；playing 可能仍在缓冲 |
| 跳转／音量 | app.playerPosition / app.soundVolume |
| 上／下一首 | 原型验证过 app.previousTrack / app.nextTrack；产品面板优先使用自己的队列 |
| 官方随机与重复 | 原型验证过 shuffleEnabled / songRepeat；产品不自动改动这些全局偏好 |
| 封面 | 原型验证过 artwork.rawData / NSAppleEventDescriptor.data 解码；产品优先用公开封面及共享匹配 |
| 官方歌词字段 | 原型曲库所有已测歌词为空，不将该字段视为可用同步歌词接口 |

Music 的合作署名只在跨 Apple 匹配时按分隔符展开，并同时归一双方署名；其他来源的既有匹配契约保持不变。

### 写操作参数

| mutate 路由 | 参数与范围 |
| --- | --- |
| /like | `{id,track,like}`；track 元数据用于目录歌曲匹配已有曲库歌曲；未入库则提示先在 Music 加入 |
| /album/sub | `{id,t}`；仅已有资料库专辑；t=1 收藏，t=2 取消；需进一步真实账号写入验收 |
| /playlist/subscribe | `{id,t}`；仅已可读取的歌单，不凭公共 ID 假造已加入资料库 |
| /playlist/create | `{name}`，返回 `{playlist}` |
| /playlist/name/update | `{id,name}`，返回回读名称 |
| /playlist/delete | `{id}`；删除后重新定位，确认已不存在 |
| /playlist/tracks | `{pid,tracks,op}`；tracks 为单个已有资料库歌曲 ID，op=add / del |

收藏歌手无对应原生脚本实体，因此不开放 /artist/sub。
smart、genius、shared 或特殊歌单不作为面板可编辑的自有普通歌单。

## 播放交付、队列和同步

`AppleMusic::play(owner, track, callback)` 先按原生 ID 或精确录音匹配已有曲库歌曲，直接交付。
当前云端曲目未入库时可复用官方当前曲目对象，相同歌曲不必重新打开链接。
入口使用 180ms 防抖，连续点击仅交付最后一次；播放命令与状态采样均隔离旧播放代数。
未入库歌曲通过 `/usr/bin/open -a Music 国区HTTPS链接` 打开，延迟后调用官方继续播放。
禁止把 HTTPS 音乐页面直接交给 openLocation：它可能被作为 URL 流加入曲库。

`AppleMusic::state()` 返回最近的异步状态，不在 UI 线程等待 Apple Events；最长每 500 毫秒发起一次采样。
成功播放回调必须同时满足真实标题、歌手、录音版本、时长匹配，且连续两次有效采样间进度已推进。
缓冲期间元数据可暂时为空，不当作播放失败或曲尾。启动期限为 15 秒，独立计时器覆盖采样阻塞。
交付过渡期 1500ms 后若错误录音实际推进，暂停官方播放器再返回错误；失败后撤下播放图标和旧进度。
点击播放会重新交付并核验，不能直接恢复未知歌曲；没有在途或失败请求时才同步外部手动切歌。

已实测《至冬》国区 ID=6810715097、Tale Version 国区 ID=1890100604 可以播放；两者都是
专辑首曲。这不能证明任意专辑中间曲目均可定位。Dream Version 的链接曾实际播放 Tale Version。

面板继续使用 MusicPlayer 的 queue、index、mode、history，不读取完整官方 Up Next，不创建隐藏
云端队列歌单，也不在产品中通过界面自动化改动自动连播或歌曲过渡。
只有面板已经确认并接管的歌曲，在接近完整曲尾后读到明确 stopped 才增加 ended 序号。
缺失当前歌曲、暂停、主动停止和外部歌曲变化不能触发面板续播。
官方自动连播或过渡切到其他歌时，放弃本次曲尾接管并同步真实歌曲，避免覆盖用户在 Music 的操作。

## 验收与边界

离线回归覆盖公开数据映射、有限分页、缺失元数据、自然结束去重、主动停止、外部切歌、来源切换隔离。
所有离线测试不得弹出 Apple 授权或访问真实账号。真实账户新测试只使用塞壬唱片-MSR、HOYO-MiX、铁痕电台-MSR。
测试写入需要临时对象与明确清理；不得将源码编译或离线检查说成全功能账号验收。

原型证据保存在本机临时目录 rhine-applemusic-prototype-20261021，含 Search / Lookup 原始响应、
Tale／Dream／至冬播放采样和自动连播对照。开发过程中仍需复核最终应用的自动化授权、回读错误处理、
真实界面歌曲同步和系统权限变化，以及专辑收藏、跨设备同步等尚未充分验证的场景。

参考：[官方 Scripting Bridge 指南](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ScriptingBridgeConcepts/Introduction/Introduction.html)、
[官方公开 Lookup 示例](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/LookupExamples.html)。
