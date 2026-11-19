/// Qt 专辑 / 歌单 / 歌手详情页（stage 单位）的纯数据构建器。
///
/// 真值来源（逐字移植，行号对应 Qt/src）：
/// - NativeHudDetail.cpp:340-511  container() 整页命令序列与卡片模型构建
/// - CollectionDetailCard.cpp:11-262 卡片内部排版（sheet/header/toolbar/table/sidebar/footer）
/// - CollectionDetailCard.h:11-64    Model/Choice/Fact/Row 字段与默认值
/// - NativeHud.cpp:160-174        containerLayout / detailBounds / Layout 默认值
/// - NativeHud.h:37-47            Layout 默认值 left=40/top=260/rowsY=434/rowHeight=54/rowCount=9/bottom=956
/// - MusicData.cpp:148-158        pad()/time()
/// - MusicMutation.cpp:47-66      canEditPlaylist（"修改/删除"按钮的唯一判定）
/// - PlaybackQueue.cpp:36-38      identity = provider(缺省 netease) + ":" + id
///
/// 契约：
/// 1. 纯 Dart：只 import 'dart:math'，不依赖 Flutter，也不 import 本仓其它 HUD 文件。
/// 2. 命令是扁平 JSON 数组、元素 0 为 op；顺序即语义（不排序/去重/合并）。
/// 3. 命中一律六字段 x/y/width/height/action/label，绝不输出 fixed（fixed 只属于 PlayerBar）。
/// 4. 三套横向几何各有来源，不可互相替代（CollectionDetailCard.cpp:11-24 + NativeHud.cpp:160-174）：
///    - 底板 bounds = detailBounds（1920 下 {40,260,1840,696}）；
///    - 卡片内容列 model.x / model.width（= containerLayout.x / .width，1920 下 416 / 1464）；
///    - 侧栏 sx = model.left + 22（1920 下 62），不是 model.x。
/// 5. 两套色板不可混用：卡片内所有线/底/字用 _Palette（四元素、无 calibrated 标记，
///    CollectionDetailCard.cpp:16-50）；只有宿主级 button() 的返回按钮文字用
///    NativeHud::ink()（五元素带 calibrated 标记，NativeHud.cpp:10-15）。
/// 6. 本页只做 2D：侧栏封面是 Qt 明确产出的 image 命令（CollectionDetailCard.cpp:214），
///    与"3D 封面只走场景 draw 通道"不冲突；本页不产出任何 art/3D 命令。
/// 7. 排序与"容器切换即复位 detailSort"属于宿主状态（NativeHudDetail.cpp:353-368）：
///    宿主负责按 sortField 计算 MusicData::sortOrder 的索引后以 trackOrder 注入；
///    trackOrder 为 null 等价于 Qt 的恒等序（sortField 非 title/album/artist 时）。
/// 8. Qt 的 m_trackOrder 由 MusicData::sortOrder 生成，永远与 songs 等长（MusicData.cpp:162-183）；
///    因此 trackOrder 应当等长，越界只做防御性回落到显示位置，不作为契约。
/// 9. 收藏动作串是 Qt 的唯一字面量 "music:subscribe"（NativeHudDetail.cpp:440），
///    路由（/playlist/subscribe、/<kind>/sub）只由宿主 canMutate 判定，不进入动作串。
/// 10. Model.loadedCount 在 CollectionDetailCard 的绘制里从未被读取（全 262 行无引用），
///     因此这里不建模它，避免给出无消费者的字段。

// 本文件只依赖 dart:math（min/max），不引入任何 Flutter 依赖。
import 'dart:math' as math;

/// 舞台矩形（Qt stage 单位，1920 基准宽）。
class CollectionDetailRect {
  const CollectionDetailRect(this.x, this.y, this.width, this.height);
  final double x;
  final double y;
  final double width;
  final double height;

  double get left => x;
  double get top => y;
  double get right => x + width;
  double get bottom => y + height;

  @override
  String toString() => 'CollectionDetailRect($x, $y, $width, $height)';
}

/// Qt NativeHud::Layout（NativeHud.h:37-47）+ containerLayout（NativeHud.cpp:160-166）。
class CollectionDetailLayout {
  const CollectionDetailLayout({
    required this.left,
    required this.sidebar,
    required this.x,
    required this.width,
    required this.top,
    required this.rowsY,
    required this.rowHeight,
    required this.rowCount,
    required this.bottom,
  });

  final double left;
  final double sidebar;
  final double x;
  final double width;
  final double top;
  final double rowsY;
  final double rowHeight;
  final int rowCount;
  final double bottom;
}

/// Qt CollectionDetailCard::Choice（CollectionDetailCard.h:11-15）。
/// [action] 为空表示该控件不绘制也不命中（CollectionDetailCard.cpp:74-76/83-85/92-94/106-108）。
class CollectionDetailAction {
  const CollectionDetailAction(this.label, this.action, {this.selected = false});
  final String label;
  final String action;
  final bool selected;

  bool get isEmpty => action.isEmpty;

  @override
  String toString() => 'CollectionDetailAction($label, $action, $selected)';
}

/// Qt CollectionDetailCard::Fact（CollectionDetailCard.h:16-19）。
class CollectionDetailFact {
  const CollectionDetailFact(this.label, this.value);
  final String label;
  final String value;
}

/// 曲目 / 专辑行所需的原始字段（Qt 直接读 QJsonObject，这里显式建模）。
class CollectionDetailTrack {
  const CollectionDetailTrack({
    required this.id,
    this.provider = 'netease',
    this.title = '',
    this.artist = '',
    this.durationMs = 0,
    this.date = '',
  });

  final String id;

  /// Qt track["provider"]；PlaybackQueue::identity 的缺省值是 "netease"（PlaybackQueue.cpp:36-38）。
  final String provider;

  final String title;
  final String artist;

  /// Qt MusicData::time 读取的 duration，毫秒（MusicData.cpp:152-158）。
  final double durationMs;

  /// 歌手详情的"发行专辑"行用 date 作为 stamp（NativeHudDetail.cpp:468-474）。
  final String date;

  /// Qt PlaybackQueue::identity(track) = provider + ":" + id（PlaybackQueue.cpp:36-38）。
  String get identity => '$provider:$id';
}

/// 本页产出的命令与命中。
class CollectionDetailDrawing {
  CollectionDetailDrawing({
    required this.commands,
    required this.hits,
    required this.trackOffset,
  });

  final List<Object?> commands;
  final List<Map<String, Object?>> hits;

  /// clamp 后的 trackOffset（NativeHudDetail.cpp:369），宿主需回写 NativeHud::trackOffset。
  final int trackOffset;
}

/// 字形度量端口（Qt Glyphs，Glyphs.h:25-28；卡片 Canvas 用 fit/wrap/measure 三个入口）。
abstract class CollectionDetailGlyphsPort {
  /// Qt Glyphs::width(text, size, weight, tracking = 0)，即 Canvas.measure。
  double width(String value, double size, String weight, [double tracking = 0]);

  /// Qt Glyphs::wrap(text, width, size, weight = "regular")。
  List<String> wrap(String value, double width, double size, String weight);
}

/// 注入的页面状态视图：Qt NativeHud/music/host 中被 container() 读取的字段集合。
/// 页面本身不保存可变状态；trackOffset 由宿主回写（见 CollectionDetailDrawing.trackOffset）。
class CollectionDetailState {
  const CollectionDetailState({
    required this.kind,
    required this.provider,
    required this.providerName,
    required this.title,
    this.artist = '',
    this.id = '',
    this.coverKey = '',
    this.virtual = false,
    this.special = false,
    this.local = false,
    this.localCollection = false,
    this.itemTrackCount = 0,
    this.directoryIdCount = 0,
    this.songs = const <CollectionDetailTrack>[],
    this.trackOrder,
    this.sortField = 'none',
    this.directory = false,
    this.directoryIndex,
    this.currentIdentity,
    this.date = '',
    this.description = '',
    this.dark = false,
    this.trackOffset = 0,
    this.artistAlbums = false,
    this.albumsMore = false,
    this.albumsLoading = false,
    this.directoryLoading = false,
    this.detailLoading = false,
    this.sortRequest = false,
    this.sortNotice = '',
    this.canEditPlaylist = false,
    this.canMutateSubscribe = false,
    this.subscribed = false,
    this.subscriptionState,
  });

  /// Qt item["kind"]：playlist / album / artist（决定 record 标题、tabs、排序入口）。
  final String kind;

  /// Qt music.provider（原始服务方，用于 archiveId 前缀表 NativeHudDetail.cpp:387-393）。
  final String provider;

  /// Qt music.providerName()（显示名，卡片 header 的 kicker 与"来源"按钮用它）。
  final String providerName;

  final String title;
  final String artist;
  final String id;
  final String coverKey;

  /// Qt item["virtual"]（NativeHudDetail.cpp:389/418/442）。
  final bool virtual;

  /// Qt item["special"]（NativeHudDetail.cpp:418）。
  final bool special;

  /// Qt music.isLocal()。
  final bool local;

  /// Qt item["localCollection"]（NativeHudDetail.cpp:442）。
  final bool localCollection;

  /// Qt item["trackCount"]。
  final int itemTrackCount;

  /// Qt music.directory->ids.size()（NativeHudDetail.cpp:394）。
  final int directoryIdCount;

  /// Qt container() 里已按 albums / directory.orderedSongs() 选好的 songs（NativeHudDetail.cpp:346-352）。
  final List<CollectionDetailTrack> songs;

  /// Qt MusicData::sortOrder(songs, sortField) 的索引；null 等价于恒等序（MusicData.cpp:162-168）。
  final List<int>? trackOrder;

  /// Qt sortField：仅 playlist（非 directory、非 albums）时取 detailSort，否则 "none"
  /// （NativeHudDetail.cpp:362-363）。它是 m_trackOrder 的生成输入，绘制层不读取；
  /// 宿主必须按它算出 trackOrder 再注入，本页只消费 trackOrder。
  final String sortField;

  /// Qt music.directory 是否非空（行 current 判断第一阶段，NativeHudDetail.cpp:476）。
  final bool directory;

  /// Qt music.directory->index。
  final int? directoryIndex;

  /// Qt PlaybackQueue::identity(music.player.current)；player.current 为空时传 null。
  final String? currentIdentity;

  /// Qt item["date"]。
  final String date;

  /// Qt item["description"]。
  final String description;

  final bool dark;

  /// Qt NativeHud::trackOffset（页面内只夹上界，见 NativeHudDetail.cpp:369）。
  final int trackOffset;

  /// Qt artistTab == "albums"。
  final bool artistAlbums;

  /// Qt music.directory->albumsMore。
  final bool albumsMore;

  /// Qt music.directory->albumsLoading。
  final bool albumsLoading;

  /// Qt music.directoryLoading。
  final bool directoryLoading;

  /// Qt music.detailLoading。
  final bool detailLoading;

  /// Qt m_sortRequest。
  final bool sortRequest;

  /// Qt m_sortNotice。
  final String sortNotice;

  /// Qt music.canEditPlaylist(item)（NativeHudDetail.cpp:412；实现见 MusicMutation.cpp:47-66）。
  /// 该函数内部已包含 kind=="playlist"、非 special、creatorID==uid 等全部条件，宿主只需传结果。
  final bool canEditPlaylist;

  /// Qt music.canMutate(subscribeRoute)（NativeHudDetail.cpp:416-418）。
  /// subscribeRoute = kind=="playlist" ? "/playlist/subscribe" : "/"+kind+"/sub"，
  /// 只用于宿主判定是否出现收藏行；输出动作串固定是 "music:subscribe"。
  final bool canMutateSubscribe;

  /// Qt music.isSubscribed(item)（非 QQ 分支，NativeHudDetail.cpp:435）。
  final bool subscribed;

  /// QQ 分支 music.subscriptionStates.value(item.key, "unknown")；null 等价 "unknown"。
  final String? subscriptionState;

  /// Qt albums = (kind == "artist" && artistTab == "albums")（NativeHudDetail.cpp:346）。
  bool get albums => kind == 'artist' && artistAlbums;

  /// Qt CollectionDetailCard::record()（CollectionDetailCard.cpp:122-130）。
  String get record {
    if (kind == 'album') {
      return 'ALBUM RECORD';
    }
    if (kind == 'artist') {
      return 'ARTIST RECORD';
    }
    return 'PLAYLIST RECORD';
  }

  /// Qt std::max({item["trackCount"], ids.size(), songs.size()})（NativeHudDetail.cpp:395）。
  int get totalCount => math.max(itemTrackCount, math.max(directoryIdCount, songs.length));
}

/// Qt CollectionDetailCard::Amber（CollectionDetailCard.cpp:50）。
const List<Object?> collectionDetailAmber = <Object?>[0.835, 0.639, 0.282, 1];

// 版式与纯函数助手

/// Qt NativeHud::containerLayout（NativeHud.cpp:160-166）+ Layout 默认值（NativeHud.h:37-47）。
CollectionDetailLayout collectionDetailLayout(double width) {
  const double left = 40;
  const double sidebarMin = 250;
  const double sidebarMax = 340;
  final double sidebar = (width * 0.23 - 40).clamp(sidebarMin, sidebarMax).toDouble();
  final double x = left + sidebar + 36;
  return CollectionDetailLayout(
    left: left,
    sidebar: sidebar,
    x: x,
    width: width - x - 40,
    top: 260,
    rowsY: 434,
    rowHeight: 54,
    rowCount: 9,
    bottom: 956,
  );
}

/// Qt NativeHud::detailBounds 的非 song 分支（NativeHud.cpp:172-173）。
CollectionDetailRect collectionDetailBounds(double width) {
  final CollectionDetailLayout layout = collectionDetailLayout(width);
  return CollectionDetailRect(
    layout.left,
    layout.top,
    width - layout.left * 2,
    layout.bottom - layout.top,
  );
}

/// Qt MusicData::pad(value, width = 2)（MusicData.cpp:148-150）。
String collectionDetailPad(int value, [int width = 2]) => value.toString().padLeft(width, '0');

/// Qt MusicData::time(track)（MusicData.cpp:152-158）。
String collectionDetailTime(double durationMs) {
  if (durationMs <= 0) {
    return '暂无';
  }
  final int seconds = durationMs ~/ 1000;
  return '${collectionDetailPad(durationMs ~/ 60000)}:${collectionDetailPad(seconds % 60)}';
}

// 调色板（CollectionDetailCard.cpp:16-50，四元素、无 calibrated 标记）

class _Palette {
  _Palette(bool dark)
      : paper =
            dark ? <Object?>[0.08, 0.095, 0.09, 1] : <Object?>[0.945, 0.941, 0.906, 1],
        panel =
            dark ? <Object?>[0.095, 0.11, 0.10, 1] : <Object?>[0.973, 0.969, 0.933, 1],
        ink = dark ? <Object?>[0.93, 0.94, 0.88, 1] : <Object?>[0.133, 0.165, 0.145, 1],
        muted = dark ? <Object?>[0.65, 0.69, 0.62, 1] : <Object?>[0.384, 0.42, 0.376, 1],
        line = dark ? <Object?>[0.30, 0.34, 0.29, 1] : <Object?>[0.80, 0.808, 0.753, 1],
        soft = dark ? <Object?>[0.16, 0.20, 0.16, 1] : <Object?>[0.898, 0.906, 0.855, 1],
        inverse =
            dark ? <Object?>[0.12, 0.15, 0.13, 1] : <Object?>[0.973, 0.969, 0.933, 1];

  final List<Object?> paper;
  final List<Object?> panel;
  final List<Object?> ink;
  final List<Object?> muted;
  final List<Object?> line;
  final List<Object?> soft;
  final List<Object?> inverse;
}

/// Qt CollectionDetailCard::withAlpha（CollectionDetailCard.cpp:6-9）：返回副本，绝不改原数组。
List<Object?> _withAlpha(List<Object?> color, double alpha) {
  final List<Object?> result = List<Object?>.of(color);
  if (result.length > 3) {
    result[3] = alpha;
  }
  return result;
}

// 绘制累加器（Qt NativeHud 的 op/fill/text/fit/hit/button/rule/image）

class _Painter {
  _Painter({required this.glyphs, required this.dark});

  final CollectionDetailGlyphsPort glyphs;
  final bool dark;
  final List<Object?> commands = <Object?>[];
  final List<Map<String, Object?>> hits = <Map<String, Object?>>[];

  /// Qt NativeHud::op（NativeHud.cpp:16-18）。
  void op(List<Object?> command) => commands.add(command);

  /// Qt NativeHud::save / restore / alpha（NativeHud.cpp:19-27）。
  void save() => op(<Object?>['save']);
  void restore() => op(<Object?>['restore']);
  void alpha(double value) => op(<Object?>['alpha', value]);

  /// Qt NativeHud::ink()（NativeHud.cpp:10-15）：宿主级助手用它，带 calibrated 标记。
  List<Object?> get hudInk => dark
      ? <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite']
      : <Object?>[0.08, 0.085, 0.075, 1, 'calibratedRGB'];

  /// Qt NativeHud::fill（NativeHud.cpp:37-39）。
  void fill(double x, double y, double width, double height, List<Object?> color) {
    op(<Object?>['fill', List<Object?>.of(color), x, y, width, height]);
  }

  /// Qt NativeHud::text（NativeHud.cpp:40-43）：tracking 在 size 之后、颜色之前。
  void text(String value, double x, double y, double size, String weight, double tracking,
      List<Object?> color) {
    op(<Object?>['text', value, x, y, size, weight, tracking, List<Object?>.of(color)]);
  }

  /// Qt NativeHud::fit（NativeHud.cpp:48-76）：二分最长可容纳前缀，截断时 left(length-1)+"…"。
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
      return value.substring(0, math.max(0, length - 1)) + '…';
    }
    return value;
  }

  /// Qt NativeHud::hit（NativeHud.cpp:102-109）：六字段，绝不写 fixed。
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

  /// Qt NativeHud::button（NativeHud.cpp:110-120）：详情页 m_modalControls 为 false，
  /// 因此等价于 hit + text(label, x, y + (height - size) / 2 - 4, size, weight)。
  void button(String label, double x, double y, double width, double height, String action, double size,
      [String weight = 'regular']) {
    hit(x, y, width, height, action, label);
    text(label, x, y + (height - size) / 2 - 4, size, weight, 0, hudInk);
  }

  /// Qt NativeHud::image（NativeHud.cpp:130-134）：key 为空不产出命令。
  void image(String key, double x, double y, double width, double height) {
    if (key.isEmpty) {
      return;
    }
    op(<Object?>['image', key, x, y, width, height]);
  }
}

// 卡片模型（Qt CollectionDetailCard::Model 的可绘制子集）

/// 单行渲染数据。Qt 在 container() 里一次性算好 number/stamp/current/action/label
/// （NativeHudDetail.cpp:460-482），卡片只负责排版。
class CollectionDetailRow {
  const CollectionDetailRow({
    required this.number,
    required this.title,
    required this.artist,
    required this.stamp,
    required this.action,
    required this.label,
    required this.current,
  });

  final String number;
  final String title;
  final String artist;
  final String stamp;
  final String action;
  final String label;
  final bool current;
}

/// Qt CollectionDetailCard::Model（CollectionDetailCard.h:29-64）中真正被绘制读取的字段。
class CollectionDetailCardModel {
  const CollectionDetailCardModel({
    required this.bounds,
    required this.left,
    required this.x,
    required this.width,
    required this.rowsY,
    required this.kind,
    required this.record,
    required this.provider,
    required this.title,
    required this.artist,
    required this.coverKey,
    required this.archiveId,
    required this.totalCount,
    required this.facts,
    required this.quote,
    required this.tabs,
    required this.playAll,
    required this.sort,
    required this.rename,
    required this.remove,
    required this.subscribe,
    required this.source,
    required this.more,
    required this.emptyMessage,
    required this.hint,
    required this.rows,
    required this.scrollFraction,
    required this.scrollThumb,
    required this.dark,
    required this.trackOffset,
    required this.rowCount,
    required this.rowHeight,
    required this.sideWidth,
    required this.coverSize,
  });

  /// Qt Model.bounds = detailBounds(width)（NativeHud.cpp:167-174）。
  final CollectionDetailRect bounds;

  /// Qt Model.left = Layout.left（默认 40）；侧栏列 sx = left + 22。
  final double left;

  /// Qt Model.x = containerLayout.x = left + sidebar + 36（1920 下 416）；卡片内容列左缘。
  final double x;

  /// Qt Model.width = containerLayout.width = width - x - 40（1920 下 1464）。
  final double width;

  /// Qt Model.rowsY（默认 434）；滚动条轨道的起点。
  final double rowsY;

  final String kind;
  final String record;
  final String provider;
  final String title;
  final String artist;
  final String coverKey;
  final String archiveId;
  final int totalCount;
  final List<CollectionDetailFact> facts;
  final String quote;
  final List<CollectionDetailAction> tabs;
  final CollectionDetailAction playAll;
  final CollectionDetailAction sort;
  final CollectionDetailAction rename;
  final CollectionDetailAction remove;
  final CollectionDetailAction subscribe;
  final CollectionDetailAction source;
  final CollectionDetailAction more;
  final String emptyMessage;
  final String hint;
  final List<CollectionDetailRow> rows;
  final double scrollFraction;
  final double scrollThumb;
  final bool dark;
  final int trackOffset;
  final int rowCount;
  final double rowHeight;
  final double sideWidth;
  final double coverSize;
}

/// Qt CollectionDetailCard::archiveId 的前缀表（NativeHudDetail.cpp:387-393）。
String collectionDetailArchiveId(CollectionDetailState state) {
  if (state.virtual) {
    return state.providerName + ' / ' + state.title;
  }
  const Map<String, String> prefixes = <String, String>{
    'qq': 'QQ MID / ',
    'kugou': 'KUGOU ID / ',
    'netease': 'NETEASE ID / ',
  };
  final String prefix = prefixes[state.provider] ?? '';
  return prefix + state.id;
}

/// Qt 收藏文案的主体词（NativeHudDetail.cpp:419-421）。
String collectionDetailSubject(String kind) {
  if (kind == 'artist') {
    return '歌手';
  }
  if (kind == 'playlist') {
    return '歌单';
  }
  return '专辑';
}

/// 构建卡片模型：对应 NativeHudDetail.cpp:340-511 中 card.* 的全部赋值。
CollectionDetailCardModel collectionDetailCardModel(CollectionDetailState state, double width) {
  final CollectionDetailLayout layout = collectionDetailLayout(width);
  final CollectionDetailRect bounds = collectionDetailBounds(width);
  final double sideWidth = layout.sidebar - 44;
  final double coverSize = math.min(250, sideWidth - 16);
  final List<CollectionDetailTrack> songs = state.songs;

  // NativeHudDetail.cpp:369：trackOffset 只夹上界（Qt 用 min，不夹下界）。
  final int limit = math.max(0, songs.length - layout.rowCount);
  final int trackOffset = math.min(state.trackOffset, limit);

  // 行（NativeHudDetail.cpp:460-482）。
  final List<int>? order = state.trackOrder;
  final List<CollectionDetailRow> rows = <CollectionDetailRow>[];
  final int visible = math.min(layout.rowCount, math.max(0, songs.length - trackOffset));
  for (int row = 0; row < visible; row++) {
    final int index = trackOffset + row;
    // Qt 侧只有上界夹取（NativeHudDetail.cpp:369），下界由输入层保证 0..（NativeHudInput.cpp:145/163）；
    // 这里对越界行做防御性跳过，等价于"宿主不会送负值"这一前提下的 Qt 行为。
    if (index < 0 || index >= songs.length) {
      continue;
    }
    // Qt: rawIndex = m_trackOrder.at(index)（排序后的原索引），
    // 然后 songs.at(rawIndex) 取该索引对应的曲目（NativeHudDetail.cpp:462-463）。
    // 序号用显示位置 index+1，曲目内容/动作串用 rawIndex。
    final int rawIndex = order == null
        ? index
        : (index >= 0 && index < order.length ? order[index] : index);
    final CollectionDetailTrack song =
        rawIndex >= 0 && rawIndex < songs.length ? songs[rawIndex] : songs[index];
    final String stamp = state.albums
        ? (song.date.isEmpty ? '专辑' : song.date)
        : collectionDetailTime(song.durationMs);
    final String current = state.currentIdentity ?? '';
    final bool isCurrent = (state.directory && state.directoryIndex == rawIndex) ||
        (current.isNotEmpty && song.identity == current);
    rows.add(CollectionDetailRow(
      number: collectionDetailPad(index + 1),
      title: song.title,
      artist: song.artist,
      stamp: stamp,
      action: (state.albums ? 'music:artist-album:' : 'music:track:') + '$rawIndex',
      label: song.title,
      current: isCurrent,
    ));
  }

  // 滚动条（NativeHudDetail.cpp:483-486 决定是否给值；CollectionDetailCard.cpp:191-197 负责绘制）。
  double scrollFraction = -1;
  double scrollThumb = 0;
  if (songs.length > layout.rowCount) {
    scrollFraction = trackOffset / math.max(1, songs.length - layout.rowCount);
    scrollThumb = layout.rowCount / songs.length;
  }

  // 动作行（NativeHudDetail.cpp:402-459）。
  final CollectionDetailAction playAll = state.albums
      ? const CollectionDetailAction('', '')
      : const CollectionDetailAction('▶  播放全部', 'music:play-loaded');
  final CollectionDetailAction sort = state.kind == 'playlist'
      ? const CollectionDetailAction('排序方式 ▾', 'music:sort-menu')
      : const CollectionDetailAction('', '');
  final List<CollectionDetailAction> tabs = state.kind == 'artist'
      ? <CollectionDetailAction>[
          CollectionDetailAction('热门歌曲', 'music:artist-tab:songs', selected: !state.artistAlbums),
          CollectionDetailAction('发行专辑', 'music:artist-tab:albums', selected: state.artistAlbums),
        ]
      : const <CollectionDetailAction>[];
  // Qt 只调用 music.canEditPlaylist(item)（NativeHudDetail.cpp:412-415）；
  // kind == "playlist" / 非 special / creatorID == uid 等条件都已经在 canEditPlaylist 内部（MusicMutation.cpp:47-66）。
  // 这里再判一次 kind 会把宿主已算好的判定覆盖成"恒假/恒真"，属于重复判定，删掉。
  final bool editable = state.canEditPlaylist;
  final CollectionDetailAction rename =
      editable ? const CollectionDetailAction('修改名称', 'music:rename-playlist') : const CollectionDetailAction('', '');
  final CollectionDetailAction remove =
      editable ? const CollectionDetailAction('删除歌单', 'music:delete-playlist') : const CollectionDetailAction('', '');

  // 订阅 / 收藏（NativeHudDetail.cpp:416-441）。
  // 动作串是 Qt 的单一字面量 "music:subscribe"；canMutate(route) 只决定是否出现，
  // 路由本身不进入动作串（收藏写入的 route 由宿主按 item.kind 重新推导）。
  final String subject = collectionDetailSubject(state.kind);
  CollectionDetailAction subscribe = const CollectionDetailAction('', '');
  if (!state.virtual && !state.special && state.canMutateSubscribe) {
    if (state.provider == 'qq') {
      final String status = state.subscriptionState ?? 'unknown';
      final String label;
      bool selected = false;
      if (status == 'subscribed') {
        label = '✓ 已收藏' + subject;
        selected = true;
      } else if (status == 'not-subscribed') {
        label = '＋ 收藏' + subject;
      } else {
        label = '＋ 收藏 / 核实';
      }
      subscribe = CollectionDetailAction(label, 'music:subscribe', selected: selected);
    } else if (state.subscribed) {
      subscribe = CollectionDetailAction('✓ 已收藏' + subject, 'music:subscribe', selected: true);
    } else {
      subscribe = CollectionDetailAction('＋ 收藏' + subject, 'music:subscribe');
    }
  }

  // 来源 / 更多（NativeHudDetail.cpp:442-449）。
  final CollectionDetailAction source = (!state.local && !state.virtual && !state.localCollection)
      ? CollectionDetailAction(state.providerName + ' ↗', 'music:source')
      : const CollectionDetailAction('', '');
  // 可见性不在模型里重复存：卡片 footer 用 !more.isEmpty 判定（CollectionDetailCard.cpp:248）。
  CollectionDetailAction more = const CollectionDetailAction('', '');
  if (state.albums) {
    // Qt: albums && music.directory && directory->albumsMore（NativeHudDetail.cpp:445-446）。
    if (state.directory && state.albumsMore) {
      more = CollectionDetailAction(state.albumsLoading ? '载入中…' : '更多专辑 ↓', 'music:artist-more');
    }
  } else if (songs.length < state.totalCount) {
    more = CollectionDetailAction(state.directoryLoading ? '载入中…' : '加载更多 ↓', 'music:directory-more');
  }

  // 空态与提示（NativeHudDetail.cpp:450-459）。
  final String emptyMessage = songs.isEmpty
      ? (state.directoryLoading || state.detailLoading ? '正在载入曲目…' : '暂无可读取曲目')
      : '';
  final String hint = state.sortRequest
      ? '正在补齐曲目以排序…'
      : (state.sortNotice.isNotEmpty ? state.sortNotice : '滚轮浏览曲目 · 点击查看歌曲');

  return CollectionDetailCardModel(
    bounds: bounds,
    left: layout.left,
    x: layout.x,
    width: layout.width,
    rowsY: layout.rowsY,
    kind: state.kind,
    record: state.record,
    provider: state.providerName,
    title: state.title,
    artist: state.artist,
    coverKey: state.coverKey,
    archiveId: collectionDetailArchiveId(state),
    totalCount: state.totalCount,
    facts: <CollectionDetailFact>[
      CollectionDetailFact('RELEASE / 发行日期', state.date.isEmpty ? '暂无' : state.date),
      CollectionDetailFact('FORMAT / 收录', '${state.totalCount} TRACKS / 曲目'),
    ],
    quote: state.description.isEmpty ? '暂无简介' : state.description,
    tabs: tabs,
    playAll: playAll,
    sort: sort,
    rename: rename,
    remove: remove,
    subscribe: subscribe,
    source: source,
    more: more,
    emptyMessage: emptyMessage,
    hint: hint,
    rows: rows,
    scrollFraction: scrollFraction,
    scrollThumb: scrollThumb,
    dark: state.dark,
    trackOffset: trackOffset,
    rowCount: layout.rowCount,
    rowHeight: layout.rowHeight,
    sideWidth: sideWidth,
    coverSize: coverSize,
  );
}

// 卡片绘制（CollectionDetailCard.cpp:27-262）

class _CardPainter {
  /// Qt Painter 的构造初始化（CollectionDetailCard.cpp:13-15）：
  /// sx = model.left + 22（侧栏列）、right = model.x + model.width（内容列右缘）。
  /// 注意 model.left 是 Layout.left（40），model.x 是 containerLayout.x（1920 下 416）：
  /// 两者相差一个 sidebar+36，绝不可互相替代。
  _CardPainter(this.painter, this.model)
      : palette = _Palette(model.dark),
        x = model.x,
        sx = model.left + 22,
        right = model.x + model.width,
        contentRight = model.x + model.width - 22;

  final _Painter painter;
  final CollectionDetailCardModel model;
  final _Palette palette;

  /// Qt Painter::right → model.x + model.width；卡片内容列的左缘即 model.x。
  final double x;
  final double right;
  final double contentRight;

  /// Qt Painter::sx → model.left + 22。
  final double sx;

  CollectionDetailGlyphsPort get glyphs => painter.glyphs;

  /// Qt 卡片内的左对齐 text 助手：tracking 缺省 0。
  void label(String value, double atX, double atY, double size, List<Object?> color,
      [String weight = 'regular', double tracking = 0]) {
    painter.text(value, atX, atY, size, weight, tracking, color);
  }

  /// Qt 卡片内的右对齐助手（CollectionDetailCard.cpp:62-66）：
  /// 宽度只按 measure(value, size, weight) 量（不带 tracking），再把 tracking 原样传进文本命令。
  /// Qt 就是这样写的，因此 totalCount/TRACKS/曲目目录/时长/▷ 的 x 会与"含 tracking"差几个像素；必须等价保留。
  void rightLabel(String value, double edge, double atY, double size, List<Object?> color,
      [String weight = 'regular', double tracking = 0]) {
    final double width = glyphs.width(value, size, weight);
    painter.text(value, edge - width, atY, size, weight, tracking, color);
  }

  /// Qt 卡片内的 rule（CollectionDetailCard.cpp:68-70）：1px、卡片自身 line 色 + 透明度。
  /// 注意：这里绝不能用宿主 NativeHud::ink()（那是五元素 calibrated 数组，且色值不同）。
  void rule(double atX, double atY, double width, double opacity) {
    painter.fill(atX, atY, width, 1, _withAlpha(palette.line, opacity));
  }

  /// Qt 卡片内的 fitted（CollectionDetailCard.cpp:57-60）：先 fit 再 label，不带 tracking。
  void fitted(String value, double atX, double atY, double size, double width, List<Object?> color,
      [String weight = 'regular']) {
    painter.text(painter.fit(value, size, width, weight), atX, atY, size, weight, 0, color);
  }

  /// Qt 卡片内的 textButton（CollectionDetailCard.cpp:72-80）。
  void textButton(CollectionDetailAction action, double atX, double atY, double width, double height,
      double size, List<Object?> color) {
    if (action.isEmpty) {
      return;
    }
    painter.hit(atX, atY, width, height, action.action, action.label);
    painter.text(painter.fit(action.label, size, width, 'regular'), atX,
        atY + (height - size) / 2 - 4, size, 'regular', 0, color);
  }

  /// Qt 卡片内的 rightTextButton（CollectionDetailCard.cpp:82-89）。
  void rightTextButton(CollectionDetailAction action, double edge, double atY, double size,
      List<Object?> color) {
    if (action.isEmpty) {
      return;
    }
    final double width = glyphs.width(action.label, size, 'regular');
    painter.hit(edge - width - 4, atY - 6, width + 4, size + 12, action.action, action.label);
    painter.text(action.label, edge - width, atY, size, 'regular', 0, color);
  }

  /// Qt 卡片内的 outlinedButton（CollectionDetailCard.cpp:91-103）。
  /// 四条边是直接 fill（左右两条高 = height），不是卡片 rule()（rule 固定 1px 高）。
  void outlinedButton(CollectionDetailAction action, double atX, double atY, double width, double height,
      double size) {
    if (action.isEmpty) {
      return;
    }
    final List<Object?> border = _withAlpha(palette.line, 0.9);
    painter.fill(atX, atY, width, 1, border);
    painter.fill(atX, atY + height - 1, width, 1, border);
    painter.fill(atX, atY, 1, height, border);
    painter.fill(atX + width - 1, atY, 1, height, border);
    painter.hit(atX, atY, width, height, action.action, action.label);
    painter.text(painter.fit(action.label, size, width - 24, 'regular'), atX + 12,
        atY + (height - size) / 2 - 4, size, 'regular', 0, palette.ink);
  }

  /// Qt 卡片内的 primaryButton（CollectionDetailCard.cpp:105-113）。
  void primaryButton(CollectionDetailAction action, double atX, double atY, double width, double height) {
    if (action.isEmpty) {
      return;
    }
    painter.fill(atX, atY, width, height, palette.ink);
    painter.hit(atX, atY, width, height, action.action, action.label);
    painter.text(painter.fit(action.label, 16, width - 44, 'demibold'), atX + 22, atY + 12, 16,
        'demibold', 0, palette.inverse);
  }

  /// Qt CollectionDetailCard::paint（CollectionDetailCard.cpp:27-262）。
  void paint() {
    painter.fill(model.bounds.x, model.bounds.y, model.bounds.width, model.bounds.height, palette.paper);
    sheet();
    header();
    toolbar();
    table();
    sidebar();
    footer();
  }

  /// CollectionDetailCard.cpp:115-120。
  /// Qt 用 model.width（内容列宽，1920 下 1464），不是 bounds.width（1840）。
  void sheet() {
    painter.fill(x - 18, model.bounds.y, model.width + 18, model.bounds.height, palette.panel);
    painter.fill(x - 18, model.bounds.y, model.width + 18, 3, palette.ink);
    painter.fill(x - 18, model.bounds.y + 3, 1, model.bounds.height - 29,
        _withAlpha(palette.line, 0.85));
  }

  /// CollectionDetailCard.cpp:132-141。
  void header() {
    final String kicker = (model.provider.isEmpty ? 'RHINE LAB' : model.provider) + ' / ' + model.record;
    label(kicker, x, 268, 11, palette.muted, 'regular', 0.8);
    // Qt 这一行直接调 canvas.text（不是 fitted），所以只有标题保留 tracking -0.6（CollectionDetailCard.cpp:137-138）。
    painter.text(painter.fit(model.title, 32, contentRight - x - 190, 'bold'), x, 284, 32, 'bold', -0.6,
        palette.ink);
    rightLabel('${model.totalCount}', contentRight, 270, 38, palette.ink, 'light', -1);
    rightLabel('TRACKS / 曲目', contentRight, 312, 11, palette.muted, 'regular', 0.6);
  }

  /// CollectionDetailCard.cpp:143-158。
  void toolbar() {
    primaryButton(model.playAll, x, 339, 180, 44);
    if (!model.sort.isEmpty) {
      outlinedButton(model.sort, x + 195, 339, 180, 44, 16);
    }
    for (int index = 0; index < model.tabs.length; index++) {
      final CollectionDetailAction tab = model.tabs[index];
      final double left = x + 210 + index * 125;
      painter.hit(left, 345, 110, 32, tab.action, tab.label);
      label(painter.fit(tab.label, 13, 110, 'regular'), left, 355, 13,
          tab.selected ? palette.ink : palette.muted);
      if (tab.selected) {
        painter.fill(left, 377, 42, 3, collectionDetailAmber);
      }
    }
    rightLabel('TRACK INDEX / 曲目目录', right - 22, 354, 11, palette.muted, 'regular', 0.5);
  }

  /// CollectionDetailCard.cpp:160-198（表体）。
  void table() {
    // Qt: artistX = model.x + model.width * 0.55（CollectionDetailCard.cpp:164），
    // 用的是内容列宽 model.width（1464），不是 contentRight - x（1420 或 1442）。
    final double width = contentRight - x;
    final double titleLeft = x + 48;
    final double artistX = x + model.width * 0.55;
    final double timeEdge = contentRight - 60;
    painter.fill(x, 398, width, 2, _withAlpha(palette.ink, 0.55));
    label('#', x, 414, 11, palette.muted, 'regular', 0.5);
    label('曲目 / TITLE', titleLeft, 414, 11, palette.muted, 'regular', 0.5);
    label('歌手 / ARTIST', artistX, 414, 11, palette.muted, 'regular', 0.5);
    rightLabel('时长', timeEdge, 414, 11, palette.muted, 'regular', 0.5);
    rule(x, 433, width, 0.25);
    for (int index = 0; index < model.rows.length; index++) {
      final CollectionDetailRow row = model.rows[index];
      final double yy = model.rowsY + index * model.rowHeight;
      if (row.current) {
        painter.fill(x - 8, yy, contentRight - x + 16, model.rowHeight - 2, palette.soft);
        painter.fill(x - 8, yy, 3, model.rowHeight - 2, collectionDetailAmber);
      }
      label(row.number, x, yy + 18, 11, row.current ? palette.ink : palette.muted);
      fitted(row.title, titleLeft, yy + 13, 18, artistX - titleLeft - 30, palette.ink, 'demibold');
      fitted(row.artist, artistX, yy + 17, 13, timeEdge - artistX - 30, palette.muted);
      rightLabel(row.stamp, timeEdge, yy + 18, 12, palette.muted);
      rightLabel('▷', contentRight, yy + 13, 18, row.current ? collectionDetailAmber : palette.muted);
      rule(x, yy + model.rowHeight - 1, contentRight - x, 0.15);
      painter.hit(x - 8, yy, contentRight - x + 16, model.rowHeight - 2, row.action, row.label);
    }
    if (model.rows.isEmpty && model.emptyMessage.isNotEmpty) {
      painter.text(painter.fit(model.emptyMessage, 22, contentRight - x - 100, 'demibold'), titleLeft,
          500, 22, 'demibold', 0, palette.ink);
    }
    if (model.scrollFraction >= 0) {
      final double height = model.rowCount * model.rowHeight - 2;
      final double thumb = math.max(28.0, model.scrollThumb * height).clamp(0.0, height).toDouble();
      final double travel = model.scrollFraction.clamp(0.0, 1.0).toDouble() * (height - thumb);
      painter.fill(right - 8, model.rowsY, 2, height, _withAlpha(palette.line, 0.55));
      painter.fill(right - 8, model.rowsY + travel, 2, thumb, palette.muted);
    }
  }

  /// CollectionDetailCard.cpp:200-244 的侧栏（封面 / 档案 / 事实 / 简介 / 编辑 / 收藏）。
  void sidebar() {
    final double sideWidth = model.sideWidth;
    label('03 / ' + model.record, sx, 322, 11, palette.muted, 'regular', 0.8);
    final double artSize = math.min(model.coverSize, sideWidth - 16);
    final double artX = sx + (sideWidth - artSize) / 2;
    const double artTop = 352;
    const double matTop = 344;
    final double matHeight = artSize + 30;
    painter.fill(artX - 8, matTop, artSize + 16, matHeight, palette.soft);
    painter.fill(artX - 8, matTop, artSize + 16, 1, _withAlpha(palette.line, 0.9));
    painter.fill(artX - 8, matTop + matHeight - 1, artSize + 16, 1, _withAlpha(palette.line, 0.9));
    painter.fill(artX - 8, matTop, 1, matHeight, _withAlpha(palette.line, 0.9));
    painter.fill(artX + artSize + 7, matTop, 1, matHeight, _withAlpha(palette.line, 0.9));
    painter.image(model.coverKey, artX, artTop, artSize, artSize);
    fitted(model.archiveId, artX, artTop + artSize + 5, 10, artSize, palette.muted);
    final double titleY = matTop + matHeight + 18;
    label(painter.fit(model.title, 22, sideWidth, 'bold'), sx, titleY, 22, palette.ink, 'bold');
    fitted(model.artist, sx, titleY + 36, 13, sideWidth, palette.muted);
    double y = titleY + 68;
    for (final CollectionDetailFact fact in model.facts) {
      label(fact.label, sx, y, 11, palette.muted, 'regular', 0.5);
      painter.text(painter.fit(fact.value, 13, sideWidth, 'regular'), sx, y + 19, 13, 'regular', 0,
          palette.ink);
      y += 40;
    }
    if (model.quote.isNotEmpty) {
      rule(sx, y + 14, sideWidth, 0.35);
      final List<String> lines = glyphs.wrap(model.quote, sideWidth, 12, 'regular');
      final int count = math.min(2, lines.length);
      for (int index = 0; index < count; index++) {
        label(lines[index], sx, y + 28 + index * 22, 12, palette.muted);
      }
    }
    if (!model.rename.isEmpty || !model.remove.isEmpty) {
      rule(sx, 858, sideWidth, 0.3);
      textButton(model.rename, sx, 866, sideWidth / 2 - 6, 30, 12, palette.ink);
      textButton(model.remove, sx + sideWidth / 2, 866, sideWidth / 2, 30, 12, palette.ink);
    }
    if (!model.subscribe.isEmpty) {
      rule(sx, 900, sideWidth, 0.3);
      painter.hit(sx, 904, sideWidth, 40, model.subscribe.action, model.subscribe.label);
      painter.text(painter.fit(model.subscribe.label, 14, sideWidth, 'regular'), sx, 914, 14,
          'regular', 0, model.subscribe.selected ? collectionDetailAmber : palette.ink);
    }
  }

  /// CollectionDetailCard.cpp:246-254 的页脚（提示 / 更多 / 来源）。
  void footer() {
    final bool moreVisible = !model.more.isEmpty;
    fitted(model.hint, x, 934, 12, contentRight - x - (moreVisible ? 360 : 220), palette.muted);
    if (moreVisible) {
      outlinedButton(model.more, contentRight - 150, 922, 150, 32, 12);
    }
    rightTextButton(model.source, moreVisible ? contentRight - 170 : contentRight, 931, 11, palette.ink);
  }
}

// 入口

/// 产出整页命令：先 save/alpha，再返回按钮，再卡片本体，最后 restore
/// （NativeHudDetail.cpp:503-510 的顺序）。
CollectionDetailDrawing renderCollectionDetail({
  required double width,
  required CollectionDetailState state,
  required CollectionDetailGlyphsPort glyphs,
  double opacity = 1,
}) {
  final CollectionDetailLayout layout = collectionDetailLayout(width);
  final CollectionDetailCardModel model = collectionDetailCardModel(state, width);
  final _Painter painter = _Painter(glyphs: glyphs, dark: state.dark);
  painter.save();
  painter.alpha(opacity);
  painter.button('← 返回曲目资料库   ESC', layout.left + 19, 211, layout.sidebar - 44, 54,
      'music:directory', 20, 'demibold');
  _CardPainter(painter, model).paint();
  painter.restore();
  return CollectionDetailDrawing(
    commands: painter.commands,
    hits: painter.hits,
    trackOffset: model.trackOffset,
  );
}
