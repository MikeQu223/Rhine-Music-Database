/// Qt 歌曲详情页（stage 单位）的纯数据构建器。
///
/// 真值来源（逐字移植，行号对应 Qt/src）：
/// - NativeHudDetail.cpp:8-43    body() 正文四分支
/// - NativeHudDetail.cpp:45-215  detail() 整页命令序列（x=width*0.56、usable、detailBounds）
/// - SongDetailCard.cpp:11-111   卡片、动作行、四字段、三 tabs
/// - NativeHud.cpp:10-138        fill/text/fit/limited/hit/button/rule/image 助手
/// - NativeHud.cpp:167-174       detailBounds(song) = {width*0.56-24, 260, width-left-35, 696}
/// - NativeHud.h                 AlbumTrackRowCount=6 / AlbumTrackTop=630 / AlbumTrackRowHeight=48
///
/// 契约：
/// 1. 纯 Dart：不依赖 Flutter（Widget/Material/dart:ui），也不 import 本仓其它 HUD 文件。
///    命令与命中以普通 JSON 形态返回，宿主按同代规则追加进整帧与命中表：不排序、不去重、
///    不合并，顺序即语义（与 worktrees//lib/hud/protocol 的 wire 说明一致）。
/// 2. 命中一律六字段 x/y/width/height/action/label（NativeHud.cpp:102-108），绝不输出 fixed：
///    fixed 只属于 PlayerBar（PlayerBar.cpp:46-53）。
/// 3. 3D 封面与 2D 卡片是两条通道：本页只产出平面命令与 "viewer" 动作；真实 3D 封面由场景
///    draw 通道生成（NativeCards.cpp expand -> frame["draws"]）。把 SongDetailCard/本页命令流
///    当作 3D 贴图是 plan  明列的 Fail 条件。
/// 4. 颜色：NativeHud::ink() 带 calibrated 标记（NativeHud.cpp:10-15），消费端做 Gamma 1.8->sRGB；
///    卡片自己的 ink() 不带标记（SongDetailCard.cpp:7-9）。两者不可混用。
/// 5. limited() 不接受颜色参数，因此它产出的 text 命令一律使用 calibrated ink（NativeHud.cpp:77-79），
///    即使调用点在卡片内部 —— 这是 Qt 的真实行为，必须保留。
/// 6. 同专辑六行、DRAG TO INSPECT、动作行、四字段、三 tabs、未登录/加载/错误/空态全部按 Qt 原样。
library;

// 本文件只依赖 dart:math（min/max），不引入任何 Flutter 依赖。
import 'dart:math' as math;

/// 舞台矩形（Qt stage 单位，1920 基准宽）。
class SongDetailRect {
  const SongDetailRect(this.x, this.y, this.width, this.height);
  final double x;
  final double y;
  final double width;
  final double height;

  double get left => x;
  double get top => y;
  double get right => x + width;
  double get bottom => y + height;

  @override
  String toString() => 'SongDetailRect($x, $y, $width, $height)';
}

/// 动作行的一格：Qt SongDetailCard::Action{label, route}（SongDetailCard.h）。
/// route 为空表示该格不绘制也不命中（SongDetailCard.cpp:26-28）。
class SongDetailAction {
  const SongDetailAction(this.label, this.route);
  final String label;
  final String route;

  bool get isEmpty => route.isEmpty;

  @override
  String toString() => 'SongDetailAction($label, $route)';
}

/// 同专辑曲目行所需的字段（Qt 用原始 JSON，这里显式建模）。
class SongDetailTrack {
  const SongDetailTrack({
    required this.id,
    this.title = '',
    this.artist = '',
    this.durationMs = 0,
  });

  final String id;
  final String title;
  final String artist;

  /// Qt MusicData::time 读取的 duration，毫秒。
  final double durationMs;
}

/// 当前歌曲条目（Qt music.current 中被本页读取的字段）。
class SongDetailItem {
  const SongDetailItem({
    required this.id,
    this.kind = 'song',
    this.title = '',
    this.artist = '',
    this.artists = const <String>[],
    this.album = '',
    this.description = '',
    this.wiki = '',
    this.date = '',
    this.durationMs = 0,
    this.provider = 'netease',
    this.path = '',
    this.format = '',
    this.sampleRate = 0,
    this.bitrate = 0,
  });

  final String id;
  final String kind;
  final String title;
  final String artist;

  /// Qt item["artists"]：非空时二级动作行第三格出现 "歌手作品"（NativeHudDetail.cpp:139-141）。
  final List<String> artists;
  final String album;
  final String description;
  final String wiki;
  final String date;

  /// Qt MusicData::time(item) 使用的毫秒时长。
  final double durationMs;

  /// Qt PlaybackQueue::identity 使用的 track provider，缺省 "netease"（PlaybackQueue.cpp:36-38）。
  final String provider;

  // 本地文件分支（body() 的 isLocal() 分支，NativeHudDetail.cpp:10-14）。
  final String path;
  final String format;
  final int sampleRate;
  final int bitrate;

  /// Qt PlaybackQueue::identity(track)（PlaybackQueue.cpp:36-38）。
  String get identity => '$provider:$id';
}

/// Qt music.player 中被本页读取的字段（NativeHudDetail.cpp:103-117）。
class SongDetailPlayerState {
  const SongDetailPlayerState({
    this.currentIdentity,
    this.loading = false,
    this.failed = false,
    this.actualQuality = '',
  });

  /// PlaybackQueue::identity(player.current)。
  final String? currentIdentity;
  final bool loading;
  final bool failed;

  /// player.actualQuality（仅在 isCurrent 为真时被采用）。
  final String actualQuality;
}

/// 注入的页面状态视图：Qt NativeHud/music/host 中被 detail() 读取的字段集合。
/// 页面本身不保存任何可变状态，偏移量由宿主回写（见 SongDetailDrawing.trackOffset/bodyOffset）。
class SongDetailState {
  const SongDetailState({
    required this.provider,
    required this.officialPlayback,
    this.item,
    this.local = false,
    this.dark = false,
    this.tab = 'overview',
    this.tracks = const <SongDetailTrack>[],
    this.trackOffset = 0,
    this.bodyOffset = 0,
    this.detailLoading = false,
    this.lyricsMode = false,
    this.uid = '',
    this.providerName = '',
    this.isSiren = false,
    this.canMutateLike = false,
    this.likedInIds = false,
    this.likedInList = false,
    this.likeSubscriptionState,
    this.queueFeedbackKey,
    this.queueFeedbackEnqueueLabel = '＋ 加入队列',
    this.queueFeedbackPlayNextLabel = '▷ 下一首播放',
    this.player = const SongDetailPlayerState(),
    this.directory = false,
    this.canEditPlaylist = false,
    this.localQuality = '',
  });

  /// Qt music.provider（服务方，决定 logo 键与 "试听片段" 分支），非 track provider。
  final String provider;

  /// Qt PlatformFeatures::OfficialPlayback（编译期特性开关，必须由宿主显式注入）。
  final bool officialPlayback;

  final SongDetailItem? item;

  /// Qt music.isLocal()。
  final bool local;
  final bool dark;

  /// 当前 tab：overview / notes / history（NativeHud.h: QString tab = "overview"）。
  final String tab;

  /// Qt music.tracks（同专辑曲目）。
  final List<SongDetailTrack> tracks;

  /// Qt NativeHud::trackOffset（仅 history tab 使用，页面内被 clamp）。
  final int trackOffset;

  /// Qt NativeHud::bodyOffset（仅非 history tab 使用，页面内被 clamp）。
  final int bodyOffset;

  /// Qt music.detailLoading。
  final bool detailLoading;

  /// Qt NativeHud::lyricsMode。
  final bool lyricsMode;

  /// Qt music.uid。
  final String uid;

  /// Qt music.providerName()。
  final String providerName;

  /// Qt music.isSiren()。
  final bool isSiren;

  /// Qt music.canMutate("/like")。
  final bool canMutateLike;

  /// likedIDs 是否包含当前 id（NativeHudDetail.cpp:120）。
  final bool likedInIds;

  /// MusicData::indexOfId(music.lists[1], id) >= 0（NativeHudDetail.cpp:121）。
  final bool likedInList;

  /// QQ 分支的订阅态：music.subscriptionStates.value(item.key, "unknown") 的宿主解析结果；
  /// null 等价于 Qt 的缺省 "unknown"（NativeHudDetail.cpp:123-129）。
  final String? likeSubscriptionState;

  /// Qt m_songQueueFeedbackKey（NativeHudDetail.cpp:134-137）。
  final String? queueFeedbackKey;

  /// Qt m_songQueueFeedback.value("enqueue", "＋ 加入队列") 的宿主解析结果。
  final String queueFeedbackEnqueueLabel;

  /// Qt m_songQueueFeedback.value("play-next", "▷ 下一首播放") 的宿主解析结果。
  final String queueFeedbackPlayNextLabel;

  final SongDetailPlayerState player;

  /// Qt music.directory 是否为真（NativeHudDetail.cpp:211）。
  final bool directory;

  /// Qt music.canEditPlaylist(music.directory->item)。
  final bool canEditPlaylist;

  /// Qt MusicPlayer::localQuality(item)（仅 local 时被采用）。
  final String localQuality;
}

/// 字形度量端口（Qt Glyphs，Glyphs.h:25-28）。
abstract class SongDetailGlyphsPort {
  /// Qt Glyphs::width(text, size, weight, tracking = 0)。
  double width(String value, double size, String weight, [double tracking = 0]);

  /// Qt Glyphs::wrap(text, width, size, weight = "regular")。
  List<String> wrap(String value, double width, double size, String weight);

  /// Qt Glyphs::inset(text, size, weight = "regular")。
  double inset(String value, double size, String weight);
}

/// 宿主已解码的位图（Qt m_host->image(key) 的返回体，只用到宽高与键）。
class SongDetailImage {
  const SongDetailImage({required this.key, required this.width, required this.height});
  final String key;
  final int width;
  final int height;
}

/// 位图查询端口（Qt m_host->image）。
abstract class SongDetailImagePort {
  SongDetailImage? image(String key);
}

/// 本页产出的命令与命中。
class SongDetailDrawing {
  SongDetailDrawing({
    required this.commands,
    required this.hits,
    this.delegatedTo,
    this.trackOffset,
    this.bodyOffset,
  });

  /// 该页不负责这一段（archive / container / lyrics-panel），宿主转交对应构建器。
  SongDetailDrawing.delegated(String to)
      : commands = <Object?>[],
        hits = <Map<String, Object?>>[],
        delegatedTo = to,
        trackOffset = null,
        bodyOffset = null;

  final List<Object?> commands;
  final List<Map<String, Object?>> hits;
  final String? delegatedTo;

  /// clamp 后的 trackOffset（仅在 history tab 计算），宿主需回写 NativeHud::trackOffset。
  final int? trackOffset;

  /// clamp 后的 bodyOffset（仅在非 history tab 计算），宿主需回写 NativeHud::bodyOffset。
  final int? bodyOffset;

  bool get isDelegated => delegatedTo != null;
}

/// 委派目标常量。
const String songDetailDelegateArchive = 'archive';
const String songDetailDelegateContainer = 'container';
const String songDetailDelegateLyricsPanel = 'lyrics-panel';

/// 六行同专辑常量（NativeHud.h）。
const int songDetailAlbumTrackRowCount = 6;
const double songDetailAlbumTrackTop = 630.0;
const double songDetailAlbumTrackRowHeight = 48.0;

/// 三 tabs 的键与命中前缀（SongDetailCard.cpp:94-105）。
const List<String> songDetailTabKeys = <String>['overview', 'notes', 'history'];

/// 3D 封面只走场景 draw 通道；本页永不输出封面贴图命令。
const String songDetailCoverChannel = 'scene-draw';

// 调色板（逐字对应 Qt）

/// Qt NativeHud::ink()（NativeHud.cpp:10-15）：带 calibrated 标记。
List<Object?> _hudInk(bool dark) => dark
    ? <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite']
    : <Object?>[0.08, 0.085, 0.075, 1, 'calibratedRGB'];

/// Qt SongDetailCard::ink()（SongDetailCard.cpp:7-9）：不带 calibrated 标记。
List<Object?> _cardInk(bool dark) =>
    dark ? <Object?>[0.92, 0.93, 0.88, 1] : <Object?>[0.133, 0.165, 0.145, 1];

/// Qt SongDetailCard 的 inverse（SongDetailCard.cpp:23/56）。
List<Object?> _cardInverse(bool dark) =>
    dark ? <Object?>[0.12, 0.15, 0.13, 1] : <Object?>[0.973, 0.969, 0.933, 1];

/// Qt SongDetailCard 的 Amber（SongDetailCard.cpp:5）。
const List<Object?> songDetailAmber = <Object?>[0.835, 0.639, 0.282, 1];

/// Qt MusicData::pad(value, width = 2)（MusicData.cpp:148-150）。
String songDetailPad(int value, [int width = 2]) => value.toString().padLeft(width, '0');

/// Qt MusicData::time(track)（MusicData.cpp:152-158）。
String songDetailTime(double durationMs) {
  if (durationMs <= 0) {
    return '暂无';
  }
  final int seconds = durationMs ~/ 1000;
  return '${songDetailPad(durationMs ~/ 60000)}:${songDetailPad(seconds % 60)}';
}

/// Qt MusicData::slice(values, start, count)（MusicData.cpp:116-123）：越界安全。
List<T> songDetailSlice<T>(List<T> values, int start, int count) {
  final int end = math.min(values.length, start + count);
  final List<T> result = <T>[];
  for (int i = math.max(0, start); i < end; i++) {
    result.add(values[i]);
  }
  return result;
}

/// Qt detailBounds(width) 的 kind == "song" 分支（NativeHud.cpp:167-170）。
SongDetailRect songDetailPanelBounds(double width) {
  final double left = width * 0.56 - 24;
  return SongDetailRect(left, 260, width - left - 35, 696);
}

// 绘制累加器（Qt NativeHud 的 op/fill/text/limited/hit/button/rule/image）

class _Painter {
  _Painter({required this.glyphs, required this.dark});

  final SongDetailGlyphsPort glyphs;
  final bool dark;
  final List<Object?> commands = <Object?>[];
  final List<Map<String, Object?>> hits = <Map<String, Object?>>[];

  /// Qt NativeHud::op（NativeHud.cpp:16-18）。
  void op(List<Object?> command) => commands.add(command);

  /// Qt NativeHud::save / restore / alpha（NativeHud.cpp:19-27）。
  void save() => op(<Object?>['save']);
  void restore() => op(<Object?>['restore']);
  void alpha(double value) => op(<Object?>['alpha', value]);

  /// Qt NativeHud::fill（NativeHud.cpp:37-39）。
  void fill(double x, double y, double width, double height, List<Object?>? color) {
    final List<Object?> effective =
        (color == null || color.isEmpty) ? _hudInk(dark) : List<Object?>.of(color);
    op(<Object?>['fill', effective, x, y, width, height]);
  }

  /// Qt NativeHud::text（NativeHud.cpp:40-43）。
  void text(
    String value,
    double x,
    double y,
    double size,
    String weight, [
    double tracking = 0,
    List<Object?>? color,
  ]) {
    final List<Object?> effective =
        (color == null || color.isEmpty) ? _hudInk(dark) : List<Object?>.of(color);
    op(<Object?>['text', value, x, y, size, weight, tracking, effective]);
  }

  /// Qt NativeHud::fit（NativeHud.cpp:48-76）：二分求最长可容纳前缀，截断时 left(length-1) + "…"。
  String fit(String value, double size, double width, String weight) {
    int length = value.length;
    if (glyphs.width(value, size, weight) > width) {
      int low = 1;
      int high = length;
      while (low < high) {
        final int middle = (low + high + 1) ~/ 2;
        if (glyphs.width(value.substring(0, middle), size, weight) <= width) {
          low = middle;
        } else {
          high = middle - 1;
        }
      }
      length = low;
    }
    if (length != value.length) {
      return '${value.substring(0, math.max(0, length - 1))}…';
    }
    return value;
  }

  /// Qt NativeHud::limited（NativeHud.cpp:77-79）：颜色固定为 calibrated ink，调用点无法覆盖。
  void limited(String value, double x, double y, double size, double width, [String weight = 'regular']) {
    text(fit(value, size, width, weight), x, y, size, weight);
  }

  /// Qt NativeHud::hit（NativeHud.cpp:102-109）：六字段，绝不写 fixed。
  /// Qt 里 label 缺省（isNull）时回落为 action；本页每个调用点都显式给出 label
  /// （如歌曲标题、tabs 文案），故这里把 label 固化为必填参数以保住该不变量。
  void hit(double x, double y, double width, double height, String action, String label) {
    hits.add(<String, Object?>{
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'action': action,
      'label': label,
    });
  }

  /// Qt NativeHud::button（NativeHud.cpp:110-120）：detail 页 m_modalControls 为 false，
  /// 因此等价于 hit + text(label, x, y + (height - size) / 2 - 4, size, weight)。
  void button(String label, double x, double y, double width, double height, String action, double size,
      [String weight = 'regular']) {
    hit(x, y, width, height, action, label);
    text(label, x, y + (height - size) / 2 - 4, size, weight);
  }

  /// Qt NativeHud::rule（NativeHud.cpp:125-129）：使用 calibrated ink。
  void rule(double x, double y, double width, double opacity) {
    final List<Object?> color = _hudInk(dark);
    color[3] = opacity;
    fill(x, y, width, 1, color);
  }

  /// Qt NativeHud::image（NativeHud.cpp:130-134）：key 为空不产出命令。
  void image(String key, double x, double y, double width, double height) {
    if (key.isEmpty) {
      return;
    }
    op(<Object?>['image', key, x, y, width, height]);
  }
}

/// Qt SongDetailCard::rule（SongDetailCard.cpp:11-15）：使用卡片自己的 ink，不带 calibrated 标记。
void _cardRule(_Painter p, double modelX, double modelWidth, bool dark, double y, double opacity) {
  final List<Object?> color = _cardInk(dark);
  color[3] = opacity;
  p.fill(modelX, y, modelWidth, 1, color);
}

/// Qt SongDetailCard::Card Model（SongDetailCard.h）。
class _CardModel {
  _CardModel({
    required this.x,
    required this.width,
    required this.dark,
    required this.local,
    required this.id,
    required this.titleLines,
    required this.tab,
    required this.trackCount,
    required this.primaryActions,
    required this.secondaryActions,
    this.artist = '',
    this.album = '',
    this.duration = '',
    this.playback = '',
    this.quality = '',
    this.badgeKey = '',
    this.badgeWidth = 0,
  });

  final double x;
  final double width;
  final bool dark;
  final bool local;
  final String id;
  final List<String> titleLines;
  final String artist;
  final String album;
  final String duration;
  final String playback;
  final String quality;
  final String badgeKey;
  final double badgeWidth;
  final String tab;
  final int trackCount;
  final List<SongDetailAction> primaryActions;
  final List<SongDetailAction> secondaryActions;
}

/// Qt SongDetailCard::actions（SongDetailCard.cpp:17-46）。
void _cardActions(_Painter p, _CardModel model, List<SongDetailAction> items, double y, bool primaryRow) {
  const double gap = 12;
  const double height = 44;
  final double width = (model.width - gap * 2) / 3;
  final List<Object?> foreground = _cardInk(model.dark);
  final List<Object?> inverse = _cardInverse(model.dark);
  for (int index = 0; index < items.length; index++) {
    final SongDetailAction item = items[index];
    if (item.route.isEmpty) {
      continue;
    }
    final double x = model.x + index * (width + gap);
    final bool primary = primaryRow && index == 0;
    if (primary) {
      p.fill(x, y, width, height, foreground);
    } else {
      final List<Object?> border = List<Object?>.of(foreground);
      border[3] = 0.2;
      p.fill(x, y, width, 1, border);
      p.fill(x, y + height - 1, width, 1, border);
      p.fill(x, y, 1, height, border);
      p.fill(x + width - 1, y, 1, height, border);
    }
    p.hit(x, y, width, height, item.route, item.label);
    final List<Object?> color = primary ? inverse : foreground;
    p.text(item.label, x + 12, y + 12, 14, primary ? 'demibold' : 'regular', 0, color);
  }
}

/// Qt SongDetailCard::paint（SongDetailCard.cpp:50-111）。
void _paintCard(_Painter p, _CardModel model) {
  final List<Object?> foreground = _cardInk(model.dark);
  final List<Object?> muted = List<Object?>.of(foreground);
  muted[3] = 0.62;
  final List<Object?> inverse = _cardInverse(model.dark);

  p.fill(model.x - 24, 260, model.width + 48, 3, foreground);
  p.fill(model.x, 280, 24, 18, foreground);
  p.text('01', model.x + 4, 282, 10, 'regular', 0, inverse);
  p.text('TRACK RECORD / 歌曲档案', model.x + 36, 282, 11, 'regular', 0, muted);
  p.limited('ID · ${model.id}', model.x + model.width * 0.65, 282, 10, model.width * 0.35);
  _cardRule(p, model.x, model.width, model.dark, 314, 0.18);
  p.limited(model.album.isEmpty ? 'AUDIO ARCHIVE / 音频档案' : model.album, model.x, 332, 15, model.width);
  for (int index = 0; index < model.titleLines.length; index++) {
    p.limited(model.titleLines[index], model.x, 366.0 + index * 40.0, 32, model.width, 'bold');
  }
  final double artistY = model.titleLines.length > 1 ? 450.0 : 416.0;
  p.limited(model.artist, model.x, artistY, 18, model.width);
  _cardActions(p, model, model.primaryActions, 476, true);
  _cardActions(p, model, model.secondaryActions, 532, false);

  final bool albumTracks = model.tab == 'history';
  if (!albumTracks) {
    _cardRule(p, model.x, model.width, model.dark, 586, 0.18);
    final double column = (model.width - 12) / 2;
    final List<List<String>> fields = <List<String>>[
      <String>['ALBUM / 所属专辑', model.album],
      <String>['QUALITY / 音质', model.quality],
      <String>['DURATION / 时长', model.duration],
      <String>['PLAYBACK / 播放方式', model.playback],
    ];
    for (int index = 0; index < fields.length; index++) {
      final double x = model.x + (index % 2) * (column + 12);
      final double y = 609.0 + (index ~/ 2) * 57.0;
      p.text(fields[index][0], x, y, 10, 'regular', 0, muted);
      if (index == 1 && model.badgeWidth > 0) {
        p.image(model.badgeKey, x, y + 24, model.badgeWidth, 22);
      } else {
        final String value = fields[index][1];
        p.limited(value.isEmpty ? '暂无' : value, x, y + 22, 15, column - 12);
      }
      if (index == 1 && !model.local && model.quality.isNotEmpty) {
        p.hit(x, y + 18, column, 34, 'quality:open', '音质说明与切换');
      }
    }
  }

  final List<String> labels = <String>[
    model.local ? '文件信息' : '歌曲百科',
    '专辑信息',
    '同专辑曲目',
  ];
  if (albumTracks && model.trackCount > 0) {
    labels[2] = '${labels[2]} · ${model.trackCount} 首';
  }
  final double tabsY = albumTracks ? 584.0 : 720.0;
  _cardRule(p, model.x, model.width, model.dark, tabsY + 42, 0.18);
  for (int index = 0; index < songDetailTabKeys.length; index++) {
    final double x = model.x + index * model.width / 3;
    final double width = model.width / 3 - 12;
    p.hit(x, tabsY, width, 38, 'tab:${songDetailTabKeys[index]}', labels[index]);
    p.limited(labels[index], x, tabsY + 10, 14, width);
    if (model.tab == songDetailTabKeys[index]) {
      p.fill(x, tabsY + 41, 48, 3, songDetailAmber);
    }
  }
}

/// Qt NativeHud::body()（NativeHudDetail.cpp:8-43）。
/// 注意：本页只在 !albumTracks 分支调用它，且此时 kind 必为 "song"；仍按 Qt 原样保留全部分支。
String songDetailBody(SongDetailState state) {
  final SongDetailItem? item = state.item;
  if (state.local) {
    final String path = item?.path ?? '';
    final String format = item?.format ?? '';
    final int sampleRate = item?.sampleRate ?? 0;
    final int bitrate = item?.bitrate ?? 0;
    return '$path\n$format / $sampleRate Hz / $bitrate kbps';
  }
  if (item == null) {
    return '';
  }
  if (item.kind == 'song') {
    if (state.tab == 'overview') {
      final String wiki = item.wiki;
      if (wiki.isNotEmpty) {
        return wiki;
      }
      return state.detailLoading ? '正在读取歌曲百科…' : '暂无歌曲百科';
    }
    String date = item.date;
    String description = item.description;
    if (date.isEmpty) {
      date = '暂无';
    }
    if (description.isEmpty) {
      description = '暂无专辑介绍';
    }
    return '专辑：${item.album}\n歌手：${item.artist}\n发行日期：$date\n$description';
  }
  if (state.tab == 'overview') {
    final String description = item.description;
    return description.isEmpty ? '暂无简介' : description;
  }
  return '编号：${item.id}\n名称：${item.title}\n${item.artist}\n已载入 ${state.tracks.length} 首';
}

/// 构建歌曲详情页的整页命令与命中。
///
/// 对齐 Qt NativeHud::detail(double width, double opacity)（NativeHudDetail.cpp:45-215）。
SongDetailDrawing renderSongDetail(
  SongDetailState state,
  double width, {
  required SongDetailGlyphsPort glyphs,
  required SongDetailImagePort images,
  double opacity = 1.0,
}) {
  final SongDetailItem? item = state.item;
  if (item == null) {
    // NativeHudDetail.cpp:48-51：空 item 走资料库页。
    return SongDetailDrawing.delegated(songDetailDelegateArchive);
  }
  if (item.kind != 'song') {
    // NativeHudDetail.cpp:52-55：非 song 走容器详情页。
    return SongDetailDrawing.delegated(songDetailDelegateContainer);
  }

  final _Painter p = _Painter(glyphs: glyphs, dark: state.dark);

  // NativeHudDetail.cpp:56-62。
  final double x = width * 0.56;
  // Qt：item 与 player.current 不同源时把 lyricsMode 复位为 false（NativeHudDetail.cpp:57-59），
  // 因此只有两者同源（identity 相等）时才继续走歌词面板（NativeHudDetail.cpp:75-79）。
  // 本函数是纯函数、不复位宿主状态：宿主收到非 lyrics-panel 的帧后应自行把 lyricsMode 置 false。
  final bool lyricsMode = state.lyricsMode && item.identity == state.player.currentIdentity;
  final double usable = width - x - 59;
  const double gap = 12;
  final double buttonWidth = (usable - gap * 2) / 3;

  p.save();
  p.alpha(opacity);
  if (!lyricsMode) {
    final SongDetailRect bounds = songDetailPanelBounds(width);
    p.fill(
      bounds.x,
      bounds.y,
      bounds.width,
      bounds.height,
      state.dark ? <Object?>[0.08, 0.095, 0.09, 0.96] : <Object?>[0.973, 0.969, 0.933, 0.96],
    );
  }

  // NativeHudDetail.cpp:70-74：左列恒定产出（含 DRAG TO INSPECT 与查看封面）。
  p.button('← 返回资料库   ESC', 59, 211, 360, 54, 'back', 20, 'demibold');
  p.limited(item.id, 60, 845, 37, 330);
  p.text('MUSIC DATABASE', 60, 893, 10, 'regular');
  p.text('DRAG TO INSPECT', 60, 917, 10, 'regular');
  p.button('查看封面 ↗', 60, 944, 260, 35, 'viewer', 14);

  if (lyricsMode) {
    // NativeHudDetail.cpp:75-79：右侧歌词面板属于歌词原子，本页只负责它之前的公共前缀。
    p.restore();
    final SongDetailDrawing drawing =
        SongDetailDrawing(commands: p.commands, hits: p.hits, delegatedTo: songDetailDelegateLyricsPanel);
    return drawing;
  }

  // NativeHudDetail.cpp:81-117：卡片模型（含徽标与音质文案）。
  final List<String> wrapped = glyphs.wrap(item.title, usable, 32, 'bold');
  final List<String> titleLines = wrapped.length > 2
      ? <String>[wrapped[0], '${wrapped[1]}…']
      : wrapped.sublist(0, math.min(2, wrapped.length));

  // Qt：isCurrent = identity(item) == identity(player.current)（NativeHudDetail.cpp:103-105）。
  // PlaybackQueue::identity 对空 current 得到 "netease:"（PlaybackQueue.cpp:36-38），
  // 因此宿主必须把"当前无播放项"映射为 currentIdentity == null（或字面量 "netease:"），
  // 否则会误判 isCurrent 并多取一次音质徽标位图。
  final bool isCurrent = item.identity == state.player.currentIdentity &&
      !state.player.loading &&
      !state.player.failed;
  String quality = isCurrent ? state.player.actualQuality : '';
  if (state.local) {
    quality = state.localQuality;
  }
  final String badgeProvider = state.local ? 'netease' : state.provider;
  final String badgeKey = 'quality:$badgeProvider-$quality';
  final SongDetailImage? badge = quality.isEmpty ? null : images.image(badgeKey);
  double badgeWidth = 0;
  // Qt 只判 !badge.isNull()（NativeHudDetail.cpp:112-114）；此处额外要求 height > 0，
  // 以免 22.0 * width / height 出现除零（防御性分歧，height 恒 >0 时行为一致）。
  if (badge != null && badge.height > 0) {
    badgeWidth = math.min(22.0 * badge.width / badge.height, (usable - gap) / 2 - 12);
  }
  final String qualityLabel = quality.isEmpty ? '' : (quality == 'standard' ? '标准' : '高品质');

  String playback = '面板内播放';
  if (state.officialPlayback) {
    playback = state.local ? '本地文件 / 面板内播放' : '面板内播放 / 官方入口';
  }

  // NativeHudDetail.cpp:118-148：动作行、QQ 订阅态与队列反馈。
  final List<SongDetailAction> primaryActions = <SongDetailAction>[
    const SongDetailAction('▶ 播放歌曲', 'music:play'),
    const SongDetailAction('', ''),
    const SongDetailAction('', ''),
  ];
  if (state.canMutateLike && (!state.isSiren || item.kind == 'song')) {
    bool liked = state.likedInIds || state.likedInList;
    String label = liked ? '♥ 已喜欢' : '♡ 喜欢';
    if (state.provider == 'qq') {
      final String subscription = state.likeSubscriptionState ?? 'unknown';
      liked = subscription == 'subscribed';
      label = liked ? '♥ 已喜欢' : '♡ 喜欢';
      if (subscription == 'unknown') {
        label = '红心 / 核实后切换';
      }
    }
    primaryActions[1] = SongDetailAction(label, 'music:like');
    primaryActions[2] = const SongDetailAction('＋ 加入歌单', 'music:add-to-playlist');
  }
  final List<SongDetailAction> secondaryActions = <SongDetailAction>[
    const SongDetailAction('＋ 加入队列', 'music:enqueue'),
    const SongDetailAction('▷ 下一首播放', 'music:play-next'),
    const SongDetailAction('', ''),
  ];
  if (state.queueFeedbackKey != null && state.queueFeedbackKey == '${state.uid}:${item.identity}') {
    secondaryActions[0] = SongDetailAction(state.queueFeedbackEnqueueLabel, 'music:enqueue');
    secondaryActions[1] = SongDetailAction(state.queueFeedbackPlayNextLabel, 'music:play-next');
  }
  if (item.artists.isNotEmpty) {
    secondaryActions[2] = const SongDetailAction('↗ 歌手作品', 'music:artist:0');
  }
  for (int index = 0; index < primaryActions.length; index++) {
    final String weight = primaryActions[index].route == 'music:play' ? 'demibold' : 'regular';
    primaryActions[index] = SongDetailAction(
        p.fit(primaryActions[index].label, 14, buttonWidth - 24, weight), primaryActions[index].route);
  }
  for (int index = 0; index < secondaryActions.length; index++) {
    secondaryActions[index] = SongDetailAction(
        p.fit(secondaryActions[index].label, 14, buttonWidth - 24, 'regular'), secondaryActions[index].route);
  }

  final _CardModel model = _CardModel(
    x: x,
    width: usable,
    dark: state.dark,
    local: state.local,
    id: item.id,
    titleLines: titleLines,
    artist: item.artist,
    album: item.album,
    duration: songDetailTime(item.durationMs),
    playback: playback,
    quality: qualityLabel,
    badgeKey: badgeKey,
    badgeWidth: badgeWidth,
    tab: state.tab,
    trackCount: state.tracks.length,
    primaryActions: primaryActions,
    secondaryActions: secondaryActions,
  );
  _paintCard(p, model);

  // NativeHudDetail.cpp:166-202：同专辑六行 / 正文三行。
  final bool albumTracks = state.tab == 'history';
  int? effectiveTrackOffset;
  int? effectiveBodyOffset;
  if (albumTracks) {
    final int maxOffset = math.max(0, state.tracks.length - songDetailAlbumTrackRowCount);
    final int trackOffset = state.trackOffset < 0
        ? 0
        : (state.trackOffset > maxOffset ? maxOffset : state.trackOffset);
    effectiveTrackOffset = trackOffset;
    final List<SongDetailTrack> songs =
        songDetailSlice<SongDetailTrack>(state.tracks, trackOffset, songDetailAlbumTrackRowCount);
    for (int index = 0; index < songs.length; index++) {
      final SongDetailTrack song = songs[index];
      final double yy = songDetailAlbumTrackTop + index * songDetailAlbumTrackRowHeight;
      p.text(songDetailPad(trackOffset + index + 1), x, yy, 11, 'regular');
      p.limited('${song.title} / ${song.artist}', x + 35, yy, 16, usable - 115);
      p.text(songDetailTime(song.durationMs), x + usable - 65, yy, 12, 'regular');
      p.rule(x, yy + 36, usable, 0.2);
      p.hit(x, yy - 4, usable, 42, 'music:album-track:${trackOffset + index}', song.title);
    }
    if (state.tracks.length > songDetailAlbumTrackRowCount) {
      final double height = songDetailAlbumTrackRowCount * songDetailAlbumTrackRowHeight - 12;
      final List<Object?> track = _hudInk(state.dark);
      track[3] = 0.12;
      p.fill(x + usable + 10, songDetailAlbumTrackTop - 4, 2, height, track);
      final double thumb =
          math.max(28.0, height * songDetailAlbumTrackRowCount / state.tracks.length);
      final double fraction =
          trackOffset / (state.tracks.length - songDetailAlbumTrackRowCount);
      final List<Object?> handle = _hudInk(state.dark);
      handle[3] = 0.6;
      p.fill(x + usable + 10, songDetailAlbumTrackTop - 4 + fraction * (height - thumb), 2, thumb, handle);
    }
    if (state.tracks.isEmpty) {
      p.text(state.detailLoading ? '正在载入曲目…' : '暂无曲目信息', x, songDetailAlbumTrackTop, 17, 'regular');
    }
  } else {
    final List<String> lines = glyphs.wrap(songDetailBody(state), usable, 16, 'regular');
    final int maxOffset = math.max(0, lines.length - 3);
    // Qt 只有上界：bodyOffset = std::min(bodyOffset, std::max(0, int(lines.size()) - 3))
    // （NativeHudDetail.cpp:196）；此处额外把负值夹到 0，避免用负偏移切片（防御性分歧，
    // bodyOffset >= 0 时与 Qt 完全一致）。
    final int bodyOffset = state.bodyOffset < 0
        ? 0
        : (state.bodyOffset > maxOffset ? maxOffset : state.bodyOffset);
    effectiveBodyOffset = bodyOffset;
    final int count = math.min(3, lines.length - bodyOffset);
    for (int index = 0; index < count; index++) {
      p.text(lines[bodyOffset + index], x, 790.0 + index * 31.0, 16, 'regular');
    }
    p.hit(x, 786, usable, count * 31.0, 'detail:copy', '点击复制完整内容');
  }

  // NativeHudDetail.cpp:203-214：底部分隔线与三格状态按钮。
  p.rule(x, 898, usable, 0.18);
  if (state.officialPlayback && !state.local) {
    p.button(state.provider != 'netease' ? '${state.providerName} ↗' : '官方客户端 ↗', x, 910, buttonWidth, 44,
        'music:official', 13);
  }
  if (state.provider == 'qq') {
    p.button('试听片段', x + buttonWidth + gap, 910, buttonWidth, 44, 'music:preview', 13);
  }
  if (state.directory && state.canEditPlaylist) {
    p.button('从歌单移除', x + (buttonWidth + gap) * 2, 910, buttonWidth, 44, 'music:remove-track', 13);
  }
  p.restore();

  return SongDetailDrawing(
    commands: p.commands,
    hits: p.hits,
    trackOffset: effectiveTrackOffset,
    bodyOffset: effectiveBodyOffset,
  );
}
