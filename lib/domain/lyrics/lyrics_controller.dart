/// Qt -> Flutter 迁移 · DEDUP-04 歌词侧的运行时（DEDUP-27 的依赖）。
///
/// Qt 移植源：Qt/src/LyricsController.cpp（全局偏移 → 当前偏移 → 活动行这三条主线）
///   :60-65    构造：读 'lyrics-global-offset-ms' → clamp ±10000 → offsetMs = m_globalOffsetMs
///   :78-84    trackKey
///   :133-146  clear
///   :243-254  load 的状态迁移（sameTrack 决定用每曲偏移还是全局偏移）
///   :470-479  accept（starts 重建、status/message、活动行）
///   :501-509  sync（offset 之后的时间轴 + upper_bound，只在行变化时发信号）
///   :511-531  adjustOffset / resetOffset
///   :534-544  applyGlobalOffset（写偏好 + 发信号，不 sync）
///   :639-661  playbackSnapshot / applyPlaybackSnapshot
/// 以及 MusicPlayer::tick 的闸门（Qt/src/MusicPlayer.cpp:471-492）：
///   tick 由宿主的单调时钟驱动，歌词只跟着 tick 走，不自己起定时器。
///
/// 反例约束（KEEP OUT）：
/// - 不 import flutter、不 import lib/data：偏好只能是注入的端口（LyricsPreferencePort）；
/// - 不接 UI、不接播放器：没有 seek/播放状态、没有 Widget 依赖、没有定时器；
/// - 不实现偏好存储、不加键前缀：'panel/' 前缀属于数据层（Qt/src/Host.cpp:1075、:1095），
///   这里传的是 Qt 原文里的裸键；
/// - 不实现取词：本地 lrc/内嵌歌词、siren/网易云请求、同名录音补缺、歌词缓存
///   （Qt/src/LyricsController.cpp:255-262、:264-277、:278-295、:296-318、:321+、:480-499）
///   全部属于数据层；本类只对「已拿到的文档」负责；
/// - 不实现远程 fork（:134、:244、:512、:522、:535 的 remoteCommand 与 :651-661 的
///   replica 语义）：单进程单实例，没有第二份状态需要同步；
/// - 不发明阈值与插值：闸门只有 MusicPlayer.cpp:475 的 0.1 秒，行选择只有 upper_bound。
library;

import 'lyrics_timeline.dart';

/// 全局偏移的偏好键（Qt/src/LyricsController.cpp:61、:542 的裸键）。
///
/// 数据层会补 'panel/' 前缀（Qt/src/Host.cpp:1075 读、:1095 写；
/// lib/data/storage/preference_store.dart:69 的 prefix），所以域层与 Qt 一样只认裸键。
const String lyricsGlobalOffsetPreferenceKey = 'lyrics-global-offset-ms';

/// 注入的偏好端口：数据层 PreferencePort（lib/data/storage/preference_store.dart:41-50）
/// **收窄后的同形**——同名同参的 read/write，另有三处差异，转接时不必再猜：
/// - 没有 remove（本类只读一次、只写一次，不需要删键）；
/// - write 不返回 bool（Qt 的 setPreference 是 void，见 :542；数据层把 false 静默掉即可）；
/// - read 用 null 表示缺键（数据层的 PreferenceStore.read 缺键给 ''，两者经
///   [parseLyricsOffsetPreference] 都归到「保持 0」：'' 与 null 一样解析失败，见 :61）。
///
/// 契约（照抄 Host 的对外行为，Qt/src/Host.cpp:1075、:1095）：
/// - [read] 缺键返回 null（Qt 的 preference() 给空串，空串在 :61 的 toDouble 处解析失败，
///   与本类的 null 走同一条「保持 0」的分支）；
/// - [write] 失败要静默（Host::setPreference 返回 void，:542 后面没有错误通道），
///   数据层现有的实现也是静默返回 false（lib/data/storage/preference_store.dart:173-183）。
abstract class LyricsPreferencePort {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

/// 歌词运行时：一份文档 + 一条时间轴 + 一个偏移。
///
/// 状态字段与 Qt/src/LyricsController.h 的公有成员一一对应：
/// [status]（.h:29，默认 "idle"）、[message]（.h:30）、[currentKey]（.h:31）、
/// [index]（.h:32，默认 -1）、[offsetMs]（.h:33）、[positionMs]（.h:34）、
/// [localSource]（.h:16，默认 "auto"）、[globalOffsetMs]（.h:64 的 m_globalOffsetMs）。
///
/// [status] 与 [message] 是可写字段：Qt 里它们就是公有成员，宿主的空态/加载态文案直接赋值。
/// 其余字段在 Dart 侧收窄成只读——Qt 里 index/offsetMs/positionMs/currentKey/m_document
/// 的赋值点全部在本类内（.cpp:143-145、:252-254、:471-479、:502、:515、:528、:655-659），
/// 收窄只是把「外部没有写入点」这件事写进类型。
class LyricsController {
  LyricsController._(this._preferences, this._globalOffsetMs) {
    // Qt/src/LyricsController.cpp:65：构造末尾把当前偏移对齐到全局偏移。
    _offsetMs = _globalOffsetMs;
  }

  /// 构造的异步版本：Qt 的构造函数同步读偏好（Qt/src/LyricsController.cpp:60-65），
  /// Dart 的端口是异步的，所以读取放在这里，构造函数本身保持私有。
  ///
  /// 读到的文本按 [parseLyricsOffsetPreference] 的规则处理：解析失败或非有限值 → 保持 0
  /// （:61-64 的 `validOffset && std::isfinite` 两个条件），可解析则夹到 ±10000（:63）。
  static Future<LyricsController> create(LyricsPreferencePort preferences) async {
    final saved = parseLyricsOffsetPreference(
      await preferences.read(lyricsGlobalOffsetPreferenceKey),
    );
    return LyricsController._(preferences, saved ?? 0);
  }

  /// MusicPlayer::tick 的轮询间隔（秒）：Qt/src/MusicPlayer.cpp:475
  /// （`if (!force && time - m_lastPoll < 0.1) return;`）。
  static const double tickIntervalSeconds = 0.1;

  final LyricsPreferencePort _preferences;
  final List<void Function()> _listeners = <void Function()>[];
  double _globalOffsetMs;
  double _lastPoll = -1; // Qt/src/MusicPlayer.h:64 `double m_lastPoll = -1;`
  double _offsetMs = 0;
  double _positionMs = 0;
  int _index = -1;
  String _currentKey = '';
  // localSource 只在 applyPlaybackSnapshot（:660）里改变；来源选择（Qt/src/LyricsController.cpp:227-240
  // 的 selectLocalSource、:256 的 load 内 setLocalSource）属数据层，本类没有进程内写入点。
  String _localSource = 'auto';
  Map<String, Object?> _document = const <String, Object?>{};
  List<double> _starts = const <double>[];

  /// 当前歌词文档（Qt .h:68 的 m_document）。只读：写入只能经 [accept] 或快照恢复。
  ///
  /// 面板消费的字段见 lib/hud/modals/lyrics_panel.dart:1-13：lines[].startMs/text/translation
  /// 与 plainText；本类不解释这些字段，只按 Qt/src/LyricsController.cpp:474-475 抽 startMs。
  Map<String, Object?> get document => _document;

  /// Qt/src/LyricsController.h:29 的公有成员，默认 "idle"（空闲/无文档）。
  String status = 'idle';

  /// Qt/src/LyricsController.h:30 的公有成员：空态与加载态文案由宿主直接写。
  String message = '';

  /// Qt/src/LyricsController.h:31 的 currentKey：最近一次 [load] 的曲目键。
  String get currentKey => _currentKey;

  /// Qt/src/LyricsController.h:32：活动行下标，-1 表示还没到第一行（或没有时间轴）。
  int get index => _index;

  /// Qt/src/LyricsController.h:33：当前曲目的偏移（毫秒）。正常路径（构造 :65、load :250、
  /// adjustOffset :515）保证它落在 ±10000 内；快照恢复 :657 是原样接管，未夹取。
  double get offsetMs => _offsetMs;

  /// Qt/src/LyricsController.h:34：最近一次 sync 的播放位置（毫秒，未加偏移）。
  double get positionMs => _positionMs;

  /// Qt/src/LyricsController.h:16 的 localSource。
  String get localSource => _localSource;

  /// Qt .h:64 的 m_globalOffsetMs：全局偏移只经 [applyGlobalOffset] 改写（:541）。
  double get globalOffsetMs => _globalOffsetMs;

  /// 对应 Qt 的 changed() 信号（Qt/src/LyricsController.h:41）。
  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _emit() {
    // 与 lib/domain/player/playback_queue.dart 的 _emit 一致：遍历副本，允许监听器在回调里退订。
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  /// Qt/src/LyricsController.cpp:78-84 `LyricsController::trackKey`。
  ///
  /// - 空对象 → 空串（:79-81）；
  /// - `provider.toString("netease") + ":" + id.toString()`（:82）：provider 缺失或非字符串按
  ///   "netease"，id 缺失或非字符串按空串；
  /// - provider 恰为字符串 "local" 时再追加 `":" + fingerprint`（:83）。
  ///
  /// 注意 Qt 不校验 id 是否为空：缺 id 的曲目得到 `"netease:"`，与「空对象 → 空串」是两回事，
  /// 这里照抄，不做补强。
  static String trackKey(Map<String, Object?>? track) {
    if (track == null || track.isEmpty) {
      return '';
    }
    final provider = lyricsTextValue(track['provider'], fallback: 'netease');
    final id = lyricsTextValue(track['id']);
    final key = provider + ':' + id;
    return track['provider'] == 'local'
        ? key + ':' + lyricsTextValue(track['fingerprint'])
        : key;
  }

  /// Qt/src/LyricsController.cpp:133-146 `clear`（去掉 :134-136 的 remoteCommand 分支）。
  ///
  /// :137 的 ++m_generation 是远程 fork 的世代号（域外，见文件头），这里没有对应物。
  /// 逐行对齐：currentKey 清空（:138）、document 置空（:139）、starts 清空（:140）、
  /// status "idle"（:141）、message 清空（:142）、index -1（:143）、
  /// offsetMs 回到全局偏移（:144）、positionMs 置 0（:145）。
  /// Qt 在这里**不发信号**（:133-146 没有 emit），本方法同样不发。
  void clear() {
    _currentKey = '';
    _document = const <String, Object?>{};
    _starts = const <double>[];
    status = 'idle';
    message = '';
    _index = -1;
    _offsetMs = _globalOffsetMs;
    _positionMs = 0;
  }

  /// Qt/src/LyricsController.cpp:243-254 `load` 的状态迁移（取词部分见文件头 KEEP OUT）。
  ///
  /// :247 算键、:248 判定是否同一首、:249 同曲保留播放位置（否则归 0）、
  /// :250 同曲沿用每曲偏移（否则退回全局偏移）、:251 先 clear、:252-254 再落 offset/key/position。
  /// sameTrack 的判定就是 `trackKey(track) == currentKey`：切歌（键不同）→ 偏移回到全局，
  /// 所以「同一首再读一次」不会把用户调过的偏移丢掉，「换歌」不会把上一首的偏移带过去。
  ///
  /// 之后 Qt 进入发信号的分支（:255 起的本地分支、:274 的缓存命中 accept、:296-318 的网络与
  /// loading），但**发射次数不恒定**：本地分支可能先在 :583 发一次 loading，再因缓存命中在
  /// :588-589 走 accept 再发一次，同一次 load 因此可能是两次。
  /// 取词属于数据层，本类在 :254 之后没有分支可走，所以这里只发这一次 changed()——比 Qt 少，不少多。
  /// 另一处差异是状态字段：Qt 先改成 loading/empty 再发，这里是 clear() 之后的 idle。
  /// 加载态文案由数据层接管，两处差异都写进了报告的残余风险。
  void load(Map<String, Object?> track) {
    final key = trackKey(track);
    final sameTrack = key == _currentKey;
    final position = sameTrack ? _positionMs : 0.0;
    final offset = sameTrack ? _offsetMs : _globalOffsetMs;
    clear();
    _offsetMs = offset;
    _currentKey = key;
    _positionMs = position;
    _emit();
  }

  /// Qt/src/LyricsController.cpp:470-479 `accept`（缓存与重试相关部分见文件头 KEEP OUT）。
  ///
  /// :471 先把曲目键塞进文档、:472 值语义地接管文档（QJsonObject 是隐式共享值类型，
  /// 所以这里是深拷贝，见 copyLyricsDocument）、:473-476 重建 starts、
  /// :477 starts 为空 → status "plain"，否则 "ready"、
  /// :478 同一条件决定文案是 "此歌词没有时间信息" 还是空串、
  /// :479 用当前 positionMs 与 offsetMs 算活动行、:489 发信号。
  ///
  /// 调用方负责先确认文档合法（[validLyricsDocument]，Qt 在 :309 与 :69 两处先校验）；
  /// 本类不重复校验，也不改写文档内容——除了 :471 那个 trackKey 键。
  void accept(Map<String, Object?> document, Map<String, Object?> track) {
    final next = copyLyricsDocument(document);
    next['trackKey'] = trackKey(track);
    _document = next;
    _starts = lyricsDocumentStarts(next);
    status = _starts.isEmpty ? 'plain' : 'ready';
    message = _starts.isEmpty ? '此歌词没有时间信息' : '';
    _index = lyricsActiveLineIndex(_document, _positionMs, offsetMs: _offsetMs);
    _emit();
  }

  /// Qt/src/LyricsController.cpp:501-509 `sync`。
  ///
  /// :502 记住原始位置、:503 时间轴 = position + 文档级 offsetMs + 当前偏移、
  /// :504 upper_bound、:505-508 只在活动行变了的时候发信号（每 tick 都发会把 HUD 打成重绘风暴）。
  /// 没有文档时 starts 为空，next 恒为 -1，与 Qt 对空数组的 upper_bound 一致。
  void sync(double position) {
    _positionMs = position;
    final time = position + lyricsDocumentOffsetMs(_document) + _offsetMs;
    final next = lyricsLineIndexAt(_starts, time);
    if (next != _index) {
      _index = next;
      _emit();
    }
  }

  /// 歌词侧跟着宿主 tick 走的那一步：Qt/src/MusicPlayer.cpp:471-492 的歌词子集。
  ///
  /// Qt 原文 `void MusicPlayer::tick(double time, bool force)`（:471）：
  /// - :472-474 有 playbackConnection 就整段 return（远程 fork，域外，见文件头）；
  /// - :475-477 `if (!force && time - m_lastPoll < 0.1) return;` —— 这就是「单调」的来源：
  ///   倒退的 time 差为负，永远落在 0.1 以内，被闸门挡住；同一 time 重复调用也一样；
  /// - :478 只有越过闸门才记 m_lastPoll；
  /// - :479-491 合并宿主 mediaState（播放器状态机，域外）；
  /// - :492 `lyrics.sync(state["position"].toDouble())` —— 时间轴只吃 mediaState 里的 position。
  ///
  /// 所以这里把 position 作为参数注入（Qt 从 host->mediaState() 里取，见 :480、:492），
  /// [time] 是宿主的单调时钟秒数（Qt/src/PlaybackService.cpp:106-109 的
  /// `m_clock.elapsed() / 1000.0`、Qt/src/NativeApplication.cpp:194-196 的 poll(time, force)）。
  ///
  /// 返回值只作诊断：true = 本次越过闸门并跑了一次 [sync]，false = 被闸门挡住。
  /// Qt 的 tick 返回 void；force 的语义照 :475 —— 跳过闸门但仍然记 m_lastPoll、仍然 sync。
  bool tick(double time, {required double positionMs, bool force = false}) {
    // 与 MusicPlayer::tick 同样的表示误差余量：Qt 的 time 来自真实时钟，抖动让
    // `time - m_lastPoll` 不会正好落在 0.1 上；这里的时间可以由调用方按十进制累加，
    // 10.3 - 10.2 = 0.09999999999999964 会被"< 0.1"整拍吞掉，歌词行停在上一条。
    if (!force && time - _lastPoll < tickIntervalSeconds - 1e-9) {
      return false;
    }
    _lastPoll = time;
    sync(positionMs);
    return true;
  }

  /// Qt/src/LyricsController.cpp:511-518 `adjustOffset`（去掉 :512-514 的 remoteCommand）。
  ///
  /// :515 `offsetMs = std::clamp(offsetMs + deltaMs, -10000., 10000.)` —— 累加后夹取，
  /// 所以连续 +200 停在 10000 不会越界；:516 立刻用 positionMs 重算活动行；
  /// :517 无条件发信号。因此当 :516 里活动行真的变了，监听器会收到**两次** changed
  /// （:507 与 :517）；这是 Qt 的现状，不是这里多写了一次。
  void adjustOffset(double deltaMs) {
    _offsetMs = clampLyricsOffsetMs(_offsetMs + deltaMs);
    sync(_positionMs);
    _emit();
  }

  /// Qt/src/LyricsController.cpp:521-531 `resetOffset`（去掉 :522-524 的 remoteCommand）。
  ///
  /// :525-527 偏移已经是 0 时直接 return，**不发信号**：界面不会因为一次无效重置而重建。
  /// 否则 :528 归零、:529 sync、:530 发信号。
  void resetOffset() {
    if (_offsetMs == 0) {
      return;
    }
    _offsetMs = 0;
    sync(_positionMs);
    _emit();
  }

  /// Qt/src/LyricsController.cpp:534-544 `applyGlobalOffset`（去掉 :535-537 的 remoteCommand）。
  ///
  /// :538-540 当前偏移与全局偏移相同时直接 return，不写偏好、不发信号（按钮据此置灰，
  /// 见 Qt/src/NativeHudModal.cpp:85-121）；:541 全局偏移 = 当前偏移；
  /// :542 以 QString::number 的文本写回 'lyrics-global-offset-ms'；
  /// :543 发信号。注意 :534 之后**没有 sync**：活动行只由 offsetMs 决定，这里改的是全局值。
  ///
  /// 写偏好在 Dart 侧是异步的，所以先改内存里的 m_globalOffsetMs（写完前 [globalOffsetMs]
  /// 就已经是新值，与 Qt :541 的可见顺序一致），await 端口写完之后再发信号（:542 → :543 的顺序）。
  Future<void> applyGlobalOffset() async {
    if (_offsetMs == _globalOffsetMs) {
      return;
    }
    _globalOffsetMs = _offsetMs;
    try {
      await _preferences.write(
        lyricsGlobalOffsetPreferenceKey,
        formatLyricsOffsetPreference(_globalOffsetMs),
      );
    } finally {
      // Qt 的 setPreference 没有错误通道（:542 之后直接 :543 emit），端口写失败也必须发信号。
      _emit();
    }
  }

  /// Qt/src/LyricsController.cpp:639-649 `playbackSnapshot`。
  ///
  /// 9 个键与原文一一对应：document（:640）、status（:641）、message（:642）、key（:643）、
  /// index（:644）、offsetMs（:645）、positionMs（:646）、globalOffsetMs（:647）、
  /// localSource（:648）。document 走深拷贝，对应 QJsonObject 的值语义。
  Map<String, Object?> playbackSnapshot() {
    return <String, Object?>{
      'document': copyLyricsDocument(_document),
      'status': status,
      'message': message,
      'key': _currentKey,
      'index': _index,
      'offsetMs': _offsetMs,
      'positionMs': _positionMs,
      'globalOffsetMs': _globalOffsetMs,
      'localSource': _localSource,
    };
  }

  /// Qt/src/LyricsController.cpp:651-661 `applyPlaybackSnapshot`。
  ///
  /// 逐键恢复，默认值与 QJsonValue 的 defaultValue 一致：status "idle"（:653）、
  /// message 空串（:654）、key 空串（:655）、index -1（:656）、三个 double 默认 0（:657-659）、
  /// localSource "auto"（:660）。**不发信号**：Qt 这里也没有 emit。
  ///
  /// 已知差异（照抄 Qt，不做补强）：这里和 :652 一样只换 document，**不重建 starts**。
  /// Qt 之所以安全，是因为 applyPlaybackSnapshot 只在 remoteCommand 之后被调用（:635），
  /// 而远程模式下 MusicPlayer::tick 在 :472-474 整段 return，sync 永远碰不到陈旧 starts。
  /// 单进程下若先 applyPlaybackSnapshot 再 tick，活动行会按旧 starts 计算——
  /// 这是 Qt 的既有形态，修它需要新的时序约定，属于域外决定，故留作残余风险。
  void applyPlaybackSnapshot(Map<String, Object?> snapshot) {
    _document = copyLyricsDocument(lyricsObjectValue(snapshot['document']));
    status = lyricsTextValue(snapshot['status'], fallback: 'idle');
    message = lyricsTextValue(snapshot['message']);
    _currentKey = lyricsTextValue(snapshot['key']);
    _index = lyricsIntegerValue(snapshot['index'], fallback: -1);
    _offsetMs = lyricsNumberValue(snapshot['offsetMs']);
    _positionMs = lyricsNumberValue(snapshot['positionMs']);
    _globalOffsetMs = lyricsNumberValue(snapshot['globalOffsetMs']);
    _localSource = lyricsTextValue(snapshot['localSource'], fallback: 'auto');
  }
}
