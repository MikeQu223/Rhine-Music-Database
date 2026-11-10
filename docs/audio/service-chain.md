# Rhine Music Panel 音频服务链路

本文描述音频从插件取源、经传输与解码、格式协商与重采样，到系统音频设备完成输出的完整链路。覆盖控制面、数据面、观测面以及平台差异。插件 manifest/descriptor 与适配细节见 [MusicBridge/plugins/sdk/README.md](../../MusicBridge/plugins/sdk/README.md)。

默认路径：

```
插件 playback（worker/Node）→ 可播放 URL
    → HttpAudioStream / 本地文件
    → QMediaPlayer(FFmpeg)
    → QAudioBufferOutput
    → AudioResampler(libswresample)
    → 有界 PCM 队列
    → QAudioSink
    → 系统音频服务
    → 扬声器 / 耳机 / DAC
```

QMediaPlayer 在本路径中不绑定 `QAudioOutput`，只负责解码；`QAudioOutput` 仅保留设备选择和音量控制面。

## 1. 总览

### 1.1 三条链路

| 链路 | 方向 | 主要组件 |
| --- | --- | --- |
| 控制面 | GUI → 服务 | `PlaybackConnection`（QLocalSocket）→ `PlaybackService` → `Host`/`MusicPlayer`/`PlaybackQueue` → `AudioPlayer` |
| 数据面 | 云端 → 设备 | MusicBridge → `HttpAudioStream` → `QMediaPlayer`(FFmpeg) → `AudioPcmOutput` → `QAudioSink` |
| 观测面 | 播放器 → 面板 | `AudioPlayer`/`HttpAudioStream`/`AudioPcmOutput` → `PlaybackDiagnostics` → `PlaybackConnection` → `FrameProfiler` |

### 1.2 进程拓扑

```
RhineMusicDatabase (GUI)          RhinePlaybackService (helper)             MusicBridge (Node)
  HUD / QML / 渲染                  Host / MusicApi / MusicPlayer             worker.cjs + plugins
  PlaybackConnection  ──IPC──▶     PlaybackQueue / AudioPlayer               plugin adapters
  只显示状态、频谱、诊断             │                                         │
                                    ├─ HttpAudioStream ──网络线程──▶ 云 CDN
                                    ├─ QMediaPlayer (FFmpeg 解码线程)
                                    └─ QAudioSink ──▶ 系统音频服务 ──▶ 设备
```

| 进程 | 职责 | 入口 | 生命周期 |
| --- | --- | --- | --- |
| `RhineMusicDatabase` | 界面、渲染、HUD、设置、歌词；不持有解码器和音频设备 | `Qt/src/main.cpp` | 用户可见窗口；第二实例 attach 后退出 |
| `RhinePlaybackService` | 音源请求、队列、解码、PCM 输出、设备所有权、系统媒体键 | `Qt/src/playback_main.cpp` | 随 GUI 启动；GUI 断开即退出 |
| `MusicBridge` | 插件加载、登录、搜索、详情、播放地址解析 | `MusicBridge/worker.cjs` + `MusicBridge/plugins` | 懒启动；所有来源共用一个 Node 进程 |
| iOS | 单进程；GUI 直接持有播放链路 | `Qt/src/main.cpp` | 无独立 helper |

桌面端由 `PlaybackService` 拥有音频设备；iOS 由应用进程直接播放（`Qt/src/PlaybackConnection.cpp:18-19`）。

## 2. 进程、线程与 IPC

### 2.1 服务启动与单实例

- GUI 通过 `connectPlaybackService()` 连接同一用户的唯一服务；没有运行时按需拉起 helper，参数为 `--resources <root> --gui <GUI executable>`（`Qt/src/PlaybackConnection.cpp:24-27`）。
- 端点名为 `rhine-playback-` 加上数据目录 UTF-8 的 SHA-256 前 24 个 hex 字符；Windows 直接使用该名，其他平台走 `/tmp/`（`Qt/src/PlaybackConnection.cpp:64-75`）。
- helper 路径：macOS `Contents/Helpers/RhinePlaybackService.app/...`，Windows `RhinePlaybackService.exe`，Linux `RhinePlaybackService`（`Qt/src/PlaybackConnection.cpp:77-87`）。
- 服务用 `data/playback-service.lock`（`QLockFile::tryLock(0)`）保证单实例；冲突且带 `--show-interface` 时向现有服务发送 `show`（`Qt/src/playback_main.cpp:61-70`）。
- 服务监听使用 `QLocalServer::UserAccessOption`；只有取得进程锁的进程才 `removeServer(endpoint)` 清理陈旧套接字（`Qt/src/PlaybackService.cpp:141-146`）。

### 2.2 IPC 协议

- 协议版本 `PlaybackConnection::ProtocolVersion = 3`（`Qt/src/PlaybackConnection.h:14`）。
- 帧格式为 compact JSON + `\n`；服务端和 GUI 端的读写缓冲上限均为 64 MiB，超限直接断开（`Qt/src/PlaybackService.cpp:148-177`、`Qt/src/PlaybackConnection.cpp:151-156`）。
- 同步 `call` 默认 5 s 超时；异步 `request` 30 s，`host.request` 例外（`Qt/src/PlaybackConnection.h:18-20`、`Qt/src/PlaybackConnection.cpp:101-119`）。
- 服务方法分四类：
  - 会话：`hello`、`attach`、`interface.ready`、`quit`、`show`、`host.request`
  - 宿主：`host.preference`、`setPreference`、`hasCredential`、`saveCredential`、`acceptCookies`、`logout`、`setProvider`、`setProviderVariant`、`mediaControl`、`mediaLoad`、`invalidateMetadata`、`clearCache`、`diagnostics`
  - 播放：`player.play`、`enqueue`、`loadQueue`、`toggle`、`pause`、`seek`、`volume`、`next`、`remove`、`clear`、`stop`、`quality`、`mode`、`alternative`、`clearHistory`、`clearCaches`
  - 歌词：`lyrics.*`
- 服务每次处理完命令后执行 `m_player.tick(...)`、`publish()`，再回 `{id, result, error}`（`Qt/src/PlaybackService.cpp:304-306`）。
- `publish()` 只发送与上次快照不同的顶层字段（patch）；没有客户端时直接返回，不组装快照（`Qt/src/PlaybackService.cpp:180-222`）。
- GUI 进程的 `Host::mediaLoad`/`mediaControl` 只转发 IPC，不创建 `AudioPlayer`（`Qt/src/Host.cpp:913-939`）。

### 2.3 线程模型

| 线程 | 归属 | 工作 |
| --- | --- | --- |
| GUI 主线程 | GUI 进程 | 渲染、QML、设置、歌词、诊断面板 |
| 服务主线程 | PlaybackService | Host、队列、AudioPlayer、AudioPcmOutput、QTimer 泵送 |
| HTTP 网络线程 | 每个 `HttpAudioStream` 一个 `QThread` | Range 请求、缓存写入、重连 |
| FFmpeg 解码线程 | QMediaPlayer（Qt FFmpeg 后端） | 解码并通过 `QAudioBufferOutput` 交付 PCM |
| QAudioSink 平台渲染线程 | Qt 音频后端 | 从环形缓冲取 PCM，交给系统音频服务 |
| OutputFormatProbe 线程 | AudioPlayer | Windows/CoreAudio 输出格式后台探测 |
| SessionWriter 线程 | PlaybackService | 会话快照序列化与 `QSaveFile` 落盘 |

`AudioPcmOutput` 由服务主线程持有；`QAudioSink` 的平台线程只消费写入的字节。解码缓冲通过排队连接回到服务主线程，再进行重采样、入队和写 sink。因此主线程的长卡顿会直接表现为输出欠载；这一点在“已知限制”中说明。

## 3. 音源获取与来源策略

### 3.1 来源与账号

当前来源由 ProviderRegistry 的 descriptor 决定；`local` 与 `siren` 是 core 内置来源，第三方来源以插件形式安装。未安装的第三方来源不会出现在资料库，未知 provider id 不会回退到其他平台。

登录与凭据：

- 每个 provider 独立保存 `providers.<id>.cookies` 与 `providers.<id>.secrets`，Host 只把当前 provider 的切片交给插件。
- 登录判定由 manifest `credentials.auth` 声明；`expiredCodes` 命中时 Host 在响应上标记 `authExpired`，Qt 收到后清理账号状态并提示重新登录。
- `credentials.inject` 把声明的 secret 注入插件可见的 cookie；`credentials.responseSecrets` 把插件响应中的私有键写回 secret 槽。
- 有 `variants` 的来源按 variant 分槽保存凭据；退出只清理当前 variant，切换来源会恢复已保存的 variant 偏好。
- 二维码/短信等登录流程由 descriptor `login.methods`、`flow.send/submit`、`pollIntervalMs/pollTimeoutMs` 描述，Qt 只负责渲染和调用对应 operation。旧扁平凭据通过 manifest `credentials.legacy` 迁移一次。

### 3.2 音质与替代音源

- 偏好键 `quality` 保存插件自己的 quality id；可用档位、默认档位、标签、描述和徽章来自 descriptor `quality`。
- 插件播放结果必须返回统一 `tier`（`auto/standard/hq/lossless/hires/master/original`），平台实际档位放在 `providerTier`，界面用它查描述和徽章。
- `aliases` 用于兼容旧档位名；未知档位按来源默认值处理。
- 试听由 `trial`/`preview` 表示；详情页和播放栏据此显示试听状态。
- 是否支持替代音源、预检接口和官方客户端入口由 descriptor `capabilities`、`externalPlayback` 声明；core 不再按平台名改写音质或 `unblock` 参数。

### 3.3 请求路径

```text
MusicLibrary::play
  → MusicPlayer::play / prepare
    → MusicApi::call('playback' | 'preview', {track, quality, alternative})
      → Host::requestJson
        → MusicBridge worker.cjs（JSON-line IPC）
          → PluginRegistry
            → plugin adapter / transport
```

- 路由为 `/native/<provider>/<operation>`，参数封装为 `params.args`。
- worker 只放行 manifest `operations` 中声明的 operation；插件原始路由使用 `/plugin/<provider>/route/<path>`，legacy/prefix 路由由 manifest 声明。
- 播放地址请求不缓存；相同 cache key 的并发请求仍会合并为一个 flight。
- 请求超时 30 s；worker 未启动、退出、超时分别有固定错误文案。
- 响应 code 为 405/429/509 或消息含“频繁”时，按来源封禁 `blockedUntil = now + max(120s, retryAfterMs)`。

### 3.4 插件播放结果

插件返回的 `PlaybackSource` 至少包含 `url` 和统一 `tier`，可选 `providerTier`、`format`、`bitrate`、`sampleRate`、`bitDepth`、`trial`、`qualityFallback`、`restriction`。播放地址的解析、音质档位映射和上游错误全部在插件内完成；core 不读取上游平台字段。

`local` 由本地索引直接提供文件 URL；`siren` 使用内置 client 获取官网音源。两者的音质档位同样通过 descriptor 描述。

### 3.5 交给播放器前的 URL 准入

`AudioPlayer::load` 按当前 provider 的 descriptor `media` 校验：

- `media.hosts`：允许的播放 host（支持 `*.example.com`）。
- `media.alternativeHosts`：仅在插件声明替代音源时允许的额外 host。
- `media.allowHttp` / `media.schemePolicy`：是否允许 HTTP；默认只允许 HTTPS。
- 本地/离线模式只接受本地文件；未知来源默认拒绝远程 URL。
- 校验失败记录 `load-rejected` 诊断并返回 false，界面显示“音频地址不可用”。

注意：白名单只校验初始 URL；`HttpAudioStream` 跟随重定向，跳转后的主机不再复核（只会阻止协议降级）。

## 4. 传输层

### 4.1 HttpAudioStream

远端 URL 由 `HttpAudioStream`（`QIODevice` 子类）提供给 QMediaPlayer；本地文件直接 `setSource(url)`，完全旁路 HTTP（`Qt/src/AudioPlayer.cpp:202-245`）。

- 临时缓存：`QTemporaryFile`，模板 `QDir::tempPath()+"/rhine-stream-XXXXXX"`；reader 与 writer 都以无缓冲方式打开同一文件（`Qt/src/HttpAudioStream.cpp:367-395`）。
- 每个流一个独立网络线程和 `QNetworkAccessManager`（`Qt/src/HttpAudioStream.cpp:78,389-393`）。
- 请求头：`Range: bytes=<offset>-`、`Accept-Encoding: identity`；offset > 0 且已有 validator 时加 `If-Range: <ETag>`（`Qt/src/HttpAudioStream.cpp:178-182`）。
- 3000 ms 传输超时、256 KiB 读取缓冲、64 KiB 单次写缓存（`Qt/src/HttpAudioStream.cpp:16-21,185-187`）。

### 4.2 续传、重试与校验

- 接受 200/206；3xx 交给 Qt 重定向；>=400 立即失败。
- 206 必须匹配 `^bytes ([0-9]+)-([0-9]+)/([0-9]+)$`，起点等于请求 offset、终点大于起点、总长不小于终点，且 `Content-Length` 等于本次区间长度。
- 200 表示服务端忽略 Range：`writeOffset` 归零、按 `Content-Length` 重设 total，从头覆盖缓存。
- 总长上限 1 GiB；前后两次 total 声明必须一致。
- `Content-Type` 以 `text/` 开头或包含 `json` 时失败，避免把错误页当音频。
- ETag 变化时失败；ETag 只在其非空且非 weak 时保存。
- 不完整响应且 total 仍大于已写字节时，从 `writeOffset` 继续；否则只在 status 为 0/200/206/>=500 且重试次数 < 2 时重试。重试没有退避定时器（`Qt/src/HttpAudioStream.cpp:311-364`）。

### 4.3 读取与 seek

- 解码线程 `readData()` 在缓存区间命中时直接读；已知 total 且到达末尾返回 EOF；否则唤醒网络线程发起新的 Range 请求。
- `isSequential()` 在 total < 0（长度未知的 chunked 流）时为 true，此时无法 seek。
- seek 到未缓存区间会发起新的 Range 请求；命中已有区间不发网络请求。

### 4.4 失败语义

- 首个数据块到达前失败：立即置“音频连接失败，请重试或打开来源页面”，清空 `pendingSource`，停止看门狗。
- 已建立解码会话后失败：只置 `pendingFailure`，由 4 s 无进度看门狗最终落错；暂停或输出背压期间健康检查直接返回，错误不会在暂停时落定。
- 临时缓存创建失败：“无法创建音频缓冲，请检查临时目录空间”；该错误只写入播放器状态，`AudioPlayer::load()` 仍返回 true。

## 5. 解码

### 5.1 后端锁定

- `Qt/src/main.cpp` 与 `Qt/src/playback_main.cpp` 在 `QT_MEDIA_BACKEND` 为空时设置为 `ffmpeg`。
- `AudioPlayer` 构造时读取该变量：为空或等于 `ffmpeg` 时 `pcmEnabled=true`；其他值回退原生 `QAudioOutput` 路径（兼容性对照）。
- 工程要求 Qt 6.12 的 Multimedia 模块。

### 5.2 媒体会话

`createPlayer()`（`Qt/src/AudioPlayer.cpp:107-135`）：

1. `releasePlayer()` 释放旧会话和未完成回调。
2. 创建新的 `QMediaPlayer` 与 `QAudioBufferOutput`。
3. 连接播放状态、媒体状态、错误、时长信号到界面唤醒回调。
4. 调用 `observeDecodedBuffers()`，再 `setAudioBufferOutput(decodedOutput.get())`。
5. `setAudioOutput(pcmEnabled ? nullptr : &output)`：FFmpeg 模式下播放器不挂任何音频输出，只解码。

### 5.3 解码缓冲观察

`QAudioBufferOutput::audioBufferReceived` 是唯一的 PCM 入口（`Qt/src/AudioPlayer.cpp:675-705`）：

- 用捕获的 `decoderObservation` 与 `sourceSerial` 丢弃旧会话/旧音源已排队的回调。
- 记录 `decodedFormat`。
- `pcmEnabled && !outputUnavailable` 时调用 `pcm.push(buffer)`；返回 false 时整个回调提前返回。
- 频谱：`spectrumEnabled && playbackRequested && spectrum.consume(buffer)`，最多每 50 ms 发一次。
- 诊断：累计 `decodedBuffers/decodedBytes/decodedFrames`、`lastDecodedElapsedMs`、`lastDecodedEndMs`。

该 tap 在每个会话都无条件挂载；即使诊断和频谱都关闭，PCM 输出仍依赖它。

### 5.4 频谱

`AudioSpectrum` 固定 2048 帧窗口、40 个频带，支持 UInt8/Int16/Int32/Float，最多取 2 个声道；Hann 窗 + 迭代基 2 FFT；频带 35 Hz 到 `min(16000, sampleRate/2)` 对数分布；只读 `buffer.constData()`，不修改 PCM（`Qt/src/AudioSpectrum.cpp:7-109`）。

### 5.5 媒体状态与 EOF

- `state()["buffering"]`：`LoadingMedia`、`StalledMedia` 或存在 `pendingSource`。
- `EndOfMedia` 且 `!sourceEnded && !decoderEnded`：置 `decoderEnded=true`；PCM 路径调用 `pcm.finish()`，非 PCM 路径直接 `completePlayback()`。
- `pcm.completed` 只在 `decoderEnded` 时调用 `completePlayback()`；后者置 `sourceEnded`、清错误、`playbackRequested=false`、停看门狗、`++ended`。
- 已自然播完后按播放（`resume`）会重新武装：`restart = sourceEnded || (decoderEnded && pcm.complete())`，重置 `decoderEnded`、`pcm.reset(...,0)`、重新绑定观察、seek 到 0。

## 6. 输出格式协商

### 6.1 两种策略

设置项 `audio-output-policy`：

| 值 | 界面标签 | 语义 |
| --- | --- | --- |
| `system`（默认） | 跟随系统（推荐） | 按当前系统混音/HAL 格式提交；通常转换最少、兼容性最好 |
| `source` | 保留源格式 | 设备完整支持源格式时原样提交；否则协商回退 |

持久化值仍是 `system`/`source`（`Qt/src/SettingsSchema.cpp:452-466`、`Qt/src/Host.cpp:927-929,1080-1088`）。

### 6.2 选择算法

`AudioOutputFormat::select(source, system, preferred, policy, supported)`（`Qt/src/AudioOutputFormat.cpp:15-53`）：

1. `policy == Source && supported(source)`：原样返回 source（后续逐字节旁路）。
2. 否则按 `observed(system) → device.preferredFormat()` 依次尝试每个候选；无效候选跳过。
3. 每个候选依次尝试：
   - `Float` 采样格式 + 源声道布局
   - 候选采样格式 + 源声道布局
   - 候选原样
4. 全部失败时，若 `supported(source)` 则退回 source，否则返回无效格式（`AudioPcmOutput` 报 error 1）。

系统观测只有采样率/声道、没有采样格式时，用系统采样率 + 源声道布局 + Float 重建观测。

### 6.3 各平台系统格式

`systemFormat()` 只观测默认设备（`Qt/src/AudioOutputFormat.cpp`、`Qt/src/AudioOutputFormatIOS.mm`）。`QAudioDevice` 重载是主线程入口，只读取默认标记与设备 id；真正的平台探测在 `systemFormat(const QByteArray &deviceId, bool isDefault)`，工作线程只能调用后者（Qt 6.12 访问 `QAudioDevice` 的格式最长可阻塞数秒）：

| 平台 | 来源 | 能力 |
| --- | --- | --- |
| Windows | 默认端点 `IAudioClient::GetMixFormat` | 采样率、声道、采样格式；status 1 |
| macOS | CoreAudio HAL `kAudioDevicePropertyStreamFormat` | 采样率、声道、采样格式；status 1 |
| iOS | `AVAudioSession` 的 rate/channels | 无采样格式，status 2 |
| Linux | 无平台分支 | 空格式，status 0；只能回退 `preferredFormat` |

status：0 不可用、1 完整系统流/混音观测、2 仅采样率/声道。

### 6.4 刷新

- 设备列表变化（`audioOutputsChanged`）触发 `followDefaultOutput(true)`，该路径仍在主线程现场探测并立即重建。
- 播放中每 5000 ms 把系统格式重读交给独立探测线程；主线程在 250 ms 心跳里消费最新结果，status/采样率/声道/采样格式任一变化才重建输出。工作线程只接收设备 id 与默认标记，不持有 `QAudioDevice`，设备切换后到达的旧结果按 id 丢弃。
- status 0（这次平台读取失败）与超过 15 s 的观测都不触发重建：前者不能证明格式变了，后者可能早于暂停期间的 seek 或输出重建。
- 检测到变化后重建输出时直接复用这份观测，不再在主线程重读系统格式；但重建本身仍要在主线程创建 `QAudioSink` 并读取 `preferredFormat()`，所以真正的格式变化仍可能带来一次可听停顿。
- 暂停时看门狗停止，不再提交探测；恢复播放后继续每 5000 ms 一次。

## 7. 重采样与抖动

### 7.1 库加载

`AudioResampler` 不链接 libswresample，而是用 `QLibrary` 动态加载 Qt 随附的成对库（`Qt/src/AudioResampler.cpp:21-95`）：

- 搜索目录：应用目录、`Frameworks`（三种层级）、`../lib`、`QLibraryInfo::LibrariesPath`、`QLibraryInfo::LibraryExecutablesPath`。
- 文件名：Windows `swresample-N.dll` / `avutil-(N+54).dll`；macOS `libswresample.N*.dylib` / `libavutil.(N+54)*.dylib`；Linux `.so.N*`；iOS framework。
- 两个库必须位于同一目录；运行时校验 `(swresample_major + 54) == avutil_major`。
- 符号：`swr_alloc/free/init/convert/get_out_samples`、`av_opt_set/av_opt_set_int`。

### 7.2 配置与转换

- 输入输出格式完全相等：`direct=true`，逐字节复制，不加载 SWR，不产生尾部。
- 否则设置 `in/out_chlayout`、采样率、采样格式、`filter_size=64`，再 `swr_init`。
- 降为 `Int16`/`UInt8` 且输入为 Float 或更宽时启用 TPDF（`dither_method=2`）；Float/Int32 输出、同位深转换、同格式旁路均不加抖动。
- 单次转换输出上限 16 MiB。
- EOF 时最多 16 次空输入冲刷 FIR 延迟；仍非空按 error 2 处理。

### 7.3 声道布局

Qt 6.12 的 `QAudioFormat::channelConfig` 位与 FFmpeg `AV_CH_*` 顺序对应：位置 1–18 映射到 AV 0–17，`LFE2`/`TopSide*`/`BottomFront*` 映射到 AV 35–40（`Qt/src/AudioResampler.cpp:111-124`）。

## 8. PCM 队列与设备输出

### 8.1 生命周期

`AudioPcmOutput` 由服务主线程持有（`Qt/src/AudioPcmOutput.h:11-12`）：

```
reset() → push() 首个缓冲 → open() → QAudioSink::start()
   → push()/pump() 持续写入 → finish() → drained → completed()
```

- `reset()` 递增会话代数、停止定时器、销毁 sink/resampler、清空队列与统计。
- `open()` 协商格式、创建重采样器、创建 `QAudioSink`，请求 250 ms 缓冲（`SINK_BUFFER_MS`），`start()`。
- 首个缓冲才真正打开 sink；`reset()` 不创建 sink。

### 8.2 队列与泵送

| 参数 | 值 | 行为 |
| --- | --- | --- |
| 泵送定时器 | 5 ms `Qt::PreciseTimer` | `pump()` 写入 sink |
| QAudioSink 请求缓冲 | 250 ms | 实际大小以 `sink->bufferSize()` 为准 |
| 背压高水位 | 200 ms | 未写入队列超过它时 `backpressure(true)` 暂停 QMediaPlayer |
| 背压低水位 | 50 ms | `backpressure(false)` 恢复播放 |
| 队列硬上限 | 2 s | 超出 `fail(5)`，不丢样本、不无限增长 |
| 设备停滞 | 5000 ms | 无 `processedUSecs()` 进展且仍有待写数据/Active 时 `fail(6)` |

`pump()` 只写 `sink->bytesFree()`，按帧对齐；写满后清理 `pending`。暂停时停止定时器；恢复时重启并立即泵送。

背压只统计尚未写进设备的应用队列（`pending.size() - offset`），不含 sink 环形缓冲；`outputBufferMs` 是两者之和。主线程停顿时 `push()` 与 `pump()` 一起停，只有 sink 环形缓冲还被平台线程消费，所以停顿容忍度由 250 ms 环形缓冲决定，而不是应用队列。

### 8.3 时钟与 seek

- `minimumMs`：seek 过滤锚点；`baseMs`：播放位置锚点。
- `push()` 用 `buffer.startTime()` 与 `minimumMs` 计算需要跳过的帧；完全在目标之前的缓冲直接丢弃，部分重叠的缓冲按字节偏移裁剪。
- `position()` = `baseMs + clamp(sink->processedUSecs(), 0, 已写 PCM 时长)`，以设备已消费时钟为准。
- seek 时 `reset()` 清空旧 PCM、重采样器和 sink，`minimumMs=baseMs=目标位置`。

### 8.4 EOF

- `finish()` 置 `ending`，冲刷重采样器尾部，追加到队列。
- 队列为空且 sink 进入 `IdleState` 时置 `drained`，只回调一次 `completed`。
- 环形缓冲变大后，`completed()` 相对解码 EOF 最多晚约 250 ms；那是仍在播放的真实音频，不是静音。
- 排空期间发生输出重建时，`followDefaultOutput()` 对 `decoderEnded` 补发 `completePlayback()`，避免 `ended` 不递增。

### 8.5 错误码

| 码 | 含义 | 触发 |
| --- | --- | --- |
| 1 | 无受支持格式 | `select()` 返回无效格式 |
| 2 | 重采样器 | `configure()`、`convert()` 或尾部冲刷失败 |
| 3 | 设备/写入 | sink 报错、`start()` 失败、`write()` 返回负值或非帧对齐 |
| 4 | 流内格式变化 | 后续缓冲格式与打开时不一致 |
| 5 | 队列超限 | 应用队列中未写入的数据超过 2 s |
| 6 | 设备停止消费 | 5 s 无 `processedUSecs()` 进展 |

失败后 `errorOccurred` 回调把播放器置为“音频输出失败，请检查输出设备或切换输出策略”。

### 8.6 诊断字段

`snapshot()` 输出策略、客户端提交格式、系统观测、硬件状态、三类转换标志、重采样/抖动状态、转换耗时、缓冲、欠载、错误、重建、背压、排空和回退标志（`Qt/src/AudioPcmOutput.cpp:287-326`）。硬件格式与实际有效位深固定为未知。

## 9. 播放状态机与控制

### 9.1 关键标志

| 标志 | 含义 | 置位/清除 |
| --- | --- | --- |
| `playbackRequested` | 用户播放意图 | `load`/`resume` 置 true；`pause`/`stop`/完成置 false |
| `sourceEnded` | 音源自然结束 | `completePlayback()` 置 true；`load`/`seek`/`resume` 清 false |
| `decoderEnded` | 解码器到达 EOF | `EndOfMedia` 置 true；`load`/`seek`/`resume`/`releasePlayer`/策略切换清 false |
| `decoderThrottled` | 输出背压暂停解码 | 背压回调设置 |
| `outputUnavailable` | 无可用输出设备 | 设备丢失置 true，恢复置 false |
| `recoveryPosition` | 待恢复位置 | 设备丢失/加载时设置，恢复后清 -1 |
| `error` | 锁存错误 | 具体失败路径设置；`load`/`stop`/设备恢复/完成/策略切换清空 |

### 9.2 对外状态

`AudioPlayer::state()` 固定 10 键（`Qt/src/AudioPlayer.cpp:534-549`）：`playing`、`position`、`duration`、`seekable`、`volume`、`ended`、`error`、`recoverable`、`requested`、`buffering`。

`playing = playbackRequested && !outputUnavailable && error.isEmpty() && (player->isPlaying() || decoderThrottled || (decoderEnded && !sourceEnded))`。

### 9.3 控制动作

`control(action, value)`：

- `pause`：清频谱、停看门狗、`player->pause()`、`pcm.pause(true)`。
- `resume`：置播放意图；若已自然结束则重新武装并从头播放；恢复 sink、看门狗和播放器。
- `seek`：仅在可 seek 时执行；清频谱、更新位置、重置 PCM 过滤点、重新绑定解码观察、seek 播放器。
- `stop`：停下并重建媒体会话，清空位置、错误、待处理源。
- `volume`：夹在 0..1 后 `output.setVolume`，经 `volumeChanged` 同步到 `pcm.setVolume`。

### 9.4 设备热插拔

- 默认设备消失：保存 `recoveryPosition`（不覆盖尚未消费的恢复位置）、`outputUnavailable=true`、暂停并重置 PCM、暂停播放器、detach `QAudioOutput`。
- 设备恢复：`releasePlayer()` + `createPlayer()`，按 `recoveryPosition` 恢复位置并重新开始传输；用户暂停意图保留。
- 同设备但格式变化：重建 PCM、按当前位置 seek；不可 seek 的流从当前起点继续。

### 9.5 策略热切换

`setOutputPolicy()`（`Qt/src/AudioPlayer.cpp:751-777`）：记录当前位置、若上次输出失败则清除错误、重置 PCM、保留暂停意图；可 seek 时重置 `decoderEnded`、重新绑定解码观察并 seek 回原位置；最后发 `output` 诊断事件。

### 9.6 看门狗

| 看门狗 | 周期/阈值 | 行为 |
| --- | --- | --- |
| 播放健康 | 250 ms 检查；`pendingFailure` 4 s，否则 15 s | 无进度则锁存“音频读取失败…” |
| 网络传输 | 3000 ms 传输超时；最多 2 次重试 | 由 `HttpAudioStream` 处理 |
| 输出停滞 | 5 s 无 `processedUSecs()` 进展 | `fail(6)` |
| 系统格式 | 每 5 s 由后台线程重读；主线程每 250 ms 消费结果 | 变化则重建输出 |

### 9.7 播放错误恢复

`MusicPlayer::tick` 在 `state.recoverable`、非本地来源且恢复次数 < 2 时调用 `recoverPlayback()`：重新解析音源 URL 并 seek 回原位置；否则锁存播放错误（`Qt/src/MusicPlayer.cpp:445-516`）。

## 10. 队列、自动切歌与会话恢复

### 10.1 队列

- 队列项 identity = `provider + ':' + id`（`Qt/src/PlaybackQueue.cpp:36-38`）。
- 只保留 `kind == 'song'` 且 id 非空；未补全的 ID 以每批 100 个调用 `songs` 补全。
- `enqueue` 拒绝本地/在线混队，按 identity 去重。
- 顺序、随机、单曲、关闭四种模式；`navigate()` 处理随机后退栈、单曲循环和顺序环绕。

### 10.2 自动切歌

`PlaybackService` 每 250 ms 调用 `MusicPlayer::tick()`；`ended` 递增后按队列模式选择下一首。队列播放完且模式为 `off` 时状态显示“队列已播放完”，不重新加载。

### 10.3 会话

- 服务每 5000 ms 提交一次会话快照；`SessionWriter` 在后台线程序列化并用 `QSaveFile` 写 `playback-session.json`（≤64 MiB，离线跳过），只保留最新快照，不阻塞音频泵。
- 只保存元数据、队列、索引、模式、位置、音量等；不保存在线 URL。
- 恢复时重新走 `play`/`prepare` 解析音源，并用保存的位置与暂停意图恢复。

## 11. 偏好与设置

| 键 | 值 | 作用 |
| --- | --- | --- |
| `provider` | 已安装或内置的 provider id | 当前来源 |
| `quality` | 当前来源的 quality id | 请求/偏好音质 |
| `alternate-source` | `on`/`off` | 插件声明替代音源时启用 |
| `audio-output-policy` | `system`/`source` | 输出格式策略 |
| `volume` | 0..1，默认 0.7 | 应用音量 |
| `provider-variant-<id>` | 当前来源的 variant id | 插件版本/分支偏好 |
| `play-history` | JSON | 播放历史，最多 200 条 |

偏好由服务端 `QSettings` 持久化（`panel/<key>`），GUI 通过 IPC 读写并使用 `remotePreferences` 缓存（`Qt/src/Host.cpp:1028-1099`）。

## 12. 诊断与可观测性

### 12.1 事件与字段

`PlaybackDiagnostics::record` 只接受 15 个固定事件名（`snapshot`、`load`、`load-rejected`、`control`、`media-status`、`playback-state`、`error`、`buffer`、`metadata`、`output`、`request-start`、`request-finish`、`upstream`、`stalled`、`media-transfer`）和白名单数值字段；最多 8192 条，超出计入 `omittedEvents`（`Qt/src/PlaybackDiagnostics.cpp:132-151`）。

报告声明：

- `mediaHttpStatusAvailable=true`、`mediaTransferBytesAvailable=true`、`outputClientFormatAvailable=true`
- `networkPacketLossAvailable=false`、`networkDnsTlsTimingAvailable=false`、`deviceOutputSamplesAvailable=false`、`outputHardwareFormatAvailable=false`

notes 明确：解码帧不等于可听设备输出；不采集原始错误、URL、主机、IP、头、载荷、账号、曲目、路径或设备身份。

### 12.2 面板与导出

`FrameProfiler` 的音频区显示解码 PCM、应用提交、系统当前、设备首选四种格式，转换类型、重采样/抖动、转换耗时、缓冲、欠载、错误和重建次数；硬件格式显示“未获取”（`Qt/src/FrameProfiler.cpp:663-715`）。导出为 schema 2 JSON，默认写入文档目录下的 `RHINE Diagnostics`。

### 12.3 崩溃诊断

Crashpad 只接入 GUI 进程（`RhineMusicDatabase`），由调试模式开关控制；播放服务进程不初始化 Crashpad。播放链路的可观测性以 `PlaybackDiagnostics` 为准。

## 13. 平台差异与打包

| 平台 | 输出路径 | 系统格式观测 | 打包 |
| --- | --- | --- | --- |
| Windows | Qt WASAPI 共享模式 → 系统混音器 | `GetMixFormat` | FFmpeg DLL 随 Qt kit；windeployqt 部署 |
| macOS | Qt CoreAudio → HAL | `kAudioDevicePropertyStreamFormat` | FFmpeg dylib 复制到 `Contents/Frameworks` |
| iOS | AVAudioSession | 仅 rate/channels | 嵌入 FFmpeg frameworks |
| Linux | Qt 音频后端（PulseAudio/PipeWire 由发行版） | 无（status 0） | AppImage 自编 FFmpeg 9.0.1 |

共享模式仍然经过系统混音器，不是 bit-perfect；当前没有独占 WASAPI、ASIO、CoreAudio Hog、SoXR 或 EQ 链。

## 14. 验证边界与已知限制

已验证：

- `qt_audio_output_regression`：44.1/48/96/192 kHz → 48 kHz 的整块/分块一致性、尾部帧、1 kHz 通带误差、30 kHz 混叠抑制、Int32 逐字节旁路、格式选择与诊断过滤、真实设备静音消费/暂停/seek/策略切换/设备丢失恢复/背压/超限/EOF 排空。
- `qt_audio_stream_regression`：本机 HTTP + 真实 FFmpeg 的完整流、截断恢复、托管重连、chunked 无长度流、seek 到未缓存区间、停止取消、暂停且无设备不误报。
- `qt_platform_regression`、`PlaybackServiceChecks`：设备跟随、服务进程拓扑与退出顺序。

未验证：

- Windows/Linux/iOS 的真实工具链、驱动、蓝牙/DAC、长期漂移与用户听感。
- 真实插件与内置来源 CDN 的 Range、206、ETag、重定向与主机分布。
- 系统混音器内部的转换、抖动和有效位深。
- 独占输出、硬件采样率切换、SoXR、EQ/耳机校正均未实现。
- `SessionWriter` 与 `OutputFormatProbe` 已移出服务主线程；主线程长卡顿仍会直接影响 PCM 生产，250 ms 环形缓冲只是把常见停顿挡在可听范围之外，没有把泵送搬离主线程。其他主线程工作仍需避免长阻塞。

## 15. 关键文件索引

| 文件 | 职责 |
| --- | --- |
| `Qt/src/MusicLibrary.cpp` / `Qt/src/MusicAccount.cpp` | 来源选择、登录、搜索、账号恢复 |
| `Qt/src/MusicPlayer.cpp` | 播放准备、音质归一化、队列驱动、会话 |
| `Qt/src/MusicApi.cpp` / `Qt/src/Host.cpp` | 桥接路由、缓存/限流、偏好、诊断 |
| `MusicBridge/worker.cjs` / `MusicBridge/plugins` | 插件加载、Host 适配与播放地址解析 |
| `Qt/src/HttpAudioStream.cpp` | 可续传 HTTP 字节流与临时缓存 |
| `Qt/src/AudioPlayer.cpp` | 媒体会话、状态机、看门狗、设备恢复 |
| `Qt/src/AudioOutputFormat.cpp` / `Qt/src/AudioOutputFormatIOS.mm` | 输出格式观测与协商 |
| `Qt/src/AudioResampler.cpp` | libswresample 加载、重采样、抖动 |
| `Qt/src/AudioPcmOutput.cpp` | 有界 PCM 队列与 QAudioSink |
| `Qt/src/AudioSpectrum.cpp` | 只读 FFT 频谱 |
| `Qt/src/PlaybackService.cpp` / `Qt/src/PlaybackConnection.cpp` | 进程模型、IPC、快照发布；`SessionWriter` 异步会话落盘 |
| `Qt/src/PlaybackDiagnostics.cpp` / `Qt/src/FrameProfiler.cpp` | 诊断白名单、报告与面板 |
