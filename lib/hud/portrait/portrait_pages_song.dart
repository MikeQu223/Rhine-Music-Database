/// 竖屏（compact）「唱片档案」详情页与「歌词」页：命令流排版，不建 widget。
///
/// 真值来源（几何/层级逐条对齐，C++ 语法改写为 Dart 命令流）：
/// - `Qt/src/ResponsiveHudPages.cpp:173-288` song()：档案类型标签与序号、两行大标题、
///   艺人/专辑、状态点、进度条 + 刻度、传输环，以及歌词/模式/队列/更多四入口。
/// - `Qt/src/ResponsiveLyrics.cpp:49-108` progressRow/transportRow 与
///   `:115-125` lyricsPlayer()、`:127-234` lyrics()：进度行几何、正文 30 / 译文 17 /
///   行间 20 的行距体系、当前行强调与阅读区上下边缘渐隐、行命中 `player:lyric-line:<i>`。
/// - `Qt/src/ResponsiveHudLayout.cpp:303-322`：沉浸播放条的 5 键排布（x = 26 + i*73，
///   播放键圆心同一行）与 `seek` / `playerBounds` 字段。
///
/// 只做「把一份输入排版成命令流 + 命中/字段」：滚动、跟随、seek 由宿主解释 actions
/// 与 fields，本文件不持有播放状态。纵向全部由 `c.height` 推出（629 与 854 都成立），
/// 所有区间先夹再画，不出现负高度/NaN。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'portrait_canvas.dart';

/// 393 设计网格宽。
// 网格宽由 canvas.gridWidth 提供（DPI 适配后页宽可变），这里不再写死。

/// 正文左右留白（Qt 的 20 / 353 对）。
const double _gutter = 20;
// 正文宽 = canvas.gridWidth - 40（左右各 20 网格）。

/// 歌词入口不可用时发的动作：宿主按真实原因给一句提示，而不是留死键。
///
/// 为什么不让页面自己弹提示：命令流里没有 toast，页面也不知道「为什么不可用」
/// （可能不是当前曲目，也可能当前曲目就是没歌词）。提示文案归宿主
/// （`lib/basic/basic_app.dart` 的 `_route`），页面只负责「这一格被点了」。
const String portraitSongHintLyrics = 'mobile:song-hint:lyrics';

/// 评论入口不可用时发的动作（同上）。
const String portraitSongHintComments = 'mobile:song-hint:comments';

/// 毫秒 → mm:ss（Qt `MusicData::pad`）。
/// 两处时间标签的右缘内缩量：Qt 的沉浸条右缘落在 393-16，这里统一成同一常量。
const double _songRightInset = 24;

String _clock(double ms) {
  final double value = ms.isFinite && ms > 0 ? ms : 0;
  final int seconds = (value / 1000).floor();
  return '${_pad(seconds ~/ 60)}:${_pad(seconds % 60)}';
}

String _pad(int value) => value.toString().padLeft(2, '0');

/// 0..1 夹取（`double.clamp` 返回 num，这里保持 double 口径）。
double _unit(double value) =>
    value.isNaN ? 0 : (value < 0 ? 0 : (value > 1 ? 1 : value));

/// 档案类型标签（Qt 的 “TRACK RECORD / 唱片档案”，按 kind 换抬头）。
String _sectionLabel(String kind) => switch (kind) {
  'album' => 'ALBUM ARCHIVE / 专辑档案',
  'playlist' => 'PLAYLIST ARCHIVE / 播放列表',
  _ => 'TRACK RECORD / 唱片档案',
};

/// 艺人 / 专辑 次要信息，缺一项就不留多余分隔符。
String _metaLine(String artist, String album) {
  if (artist.isEmpty) {
    return album;
  }
  if (album.isEmpty) {
    return artist;
  }
  return '$artist   /   $album';
}

/// 唱片档案（详情）页。返回前必须调用 c.finish()。
///
/// 纵向排布自上而下累加（见 [_songLayout]）：卡片吃剩下的高度，三段间距按富余等比放大。
///
/// [current] 表示详情页曲目是否就是正在播放的那首：false 时整条控制带只服务本页曲目
/// （进度归零、seek 无热区、播放键发 `music:play`、上下首发 `music:detail-*`、无歌词入口）。
void paintPortraitSongPage(
  PortraitCanvas c, {
  required String title,
  required String artist,
  required String album,
  required String kind,
  required String stamp,
  required String cover,
  required bool current,
  required bool playing,
  required bool buffering,
  required bool favourite,
  required double positionMs,
  required double durationMs,
  required String lyricPreview,
  required bool lyricsAvailable,
  bool commentsAvailable = false,
  String mode = 'all',
}) {
  final double h = c.height;

  // 整页铺纸色：竖屏详情是沉浸页，不透出身后的 3D 唱片。
  c.fill(Rect.fromLTWH(0, 0, c.gridWidth, math.max(0, h)), c.paper);

  // 关闭：参考图是顶部居中的一枚 X，没有「RHINE LAB / 标题」页头。
  c.icon('close', c.gridWidth / 2 - 9, 34, size: 18, color: c.ink);
  c.hit(Rect.fromLTWH(c.gridWidth / 2 - 40, 16, 80, 52), 'back', '关闭');

  // 标题总共占几行：Qt `paragraph(maximumLines = 2)`、25pt × 1.2 行距 = 每行 30。
  // 先算行数再排纵向预算，标题多一行就把唱片卡少收一行的高，不靠「钉底部」兜底。
  int titleLines = math.min(
    2,
    math.max(1, c.wrap(title, c.gridWidth - 40, 25, 'demibold').length),
  );
  if (h < _songFloorHeight(titleLines) + _songCardMin && titleLines > 1) {
    // 矮屏先牺牲标题第二行（Qt 也是 2 行封顶，1 行是合法版式），再谈压卡片。
    titleLines = 1;
  }
  // 歌词预览取自**当前播放曲目**的时间轴：详情页是另一首时预览会指错歌，
  // 所以非当前曲目直接不显示（Qt 的 song() 本来就没有这一行）。
  final String preview = current ? lyricPreview : '';
  final _SongLayout layout = _songLayout(
    c,
    titleLines: titleLines,
    lyricPreview: preview.isNotEmpty,
  );

  // 唱片卡：正方形居中，最长边 312（参考值），矮屏由 [_songLayout] 收到 96 甚至更小。
  final double side = layout.cardSide;
  final Rect card = Rect.fromLTWH(
    (c.gridWidth - side) / 2,
    _cardTop,
    side,
    side,
  );
  c.fill(card, c.surface);
  if (cover.isNotEmpty) {
    c.image(cover, card);
  }
  c.border(card, c.line);

  // 档案行：类型标签 + 右上序号，行下一道细线（y 由 [_songLayout] 给，卡片封顶后
  // 的余量会落在卡片与这一行之间）。
  final double labelTop = layout.labelTop;
  c.text(
    _sectionLabel(kind),
    _gutter,
    labelTop,
    size: 8,
    width: 240,
    color: c.muted,
  );
  if (stamp.isNotEmpty) {
    c.rightText(stamp, c.gridWidth - 20, labelTop, 8, 'regular', c.ink);
  }
  c.fill(Rect.fromLTWH(_gutter, labelTop + 14, (c.gridWidth - 40), .6), c.line);

  // 两行大标题（超出省略号）+ 艺人/专辑 + 收藏状态。
  final double titleTop = labelTop + _labelRow;
  c.paragraph(
    title,
    _gutter,
    titleTop,
    size: 25,
    width: (c.gridWidth - 40),
    weight: 'demibold',
    maximumLines: 2,
    lineSpacing: 1.2,
  );
  final double metaTop = titleTop + _titleLine * titleLines + _gapTitleMeta;
  final String meta = _metaLine(artist, album);
  if (meta.isNotEmpty) {
    c.text(
      meta,
      _gutter,
      metaTop,
      size: 11,
      width: (c.gridWidth - 40) - 56,
      color: c.muted,
    );
  }
  // 设计稿里心在 350（393 - 43）：必须跟着页宽贴右缘，写死会漂到页面中间。
  c.icon(
    favourite ? 'heart-filled' : 'heart',
    c.gridWidth - 43,
    metaTop - 4,
    size: 18,
    color: favourite ? c.ink : c.muted,
  );
  // 收藏热区 44×44（Qt `{337, top + 30, 44, 44}` 的相对版）：旧实现只画图标不给命中，
  // 详情页点心等于没反应。
  // 详情页喜欢的是「选中那首」（Qt `ResponsiveHudPages.cpp:188-194` 的路由就是
  // `music:like`）；`music:like-current` 属于沉浸条那类「正在播放」的入口。
  c.hit(
    Rect.fromLTWH(c.gridWidth - 57, metaTop - 22, 44, 44),
    'music:like',
    '喜欢这首歌',
  );

  // 状态行：琥珀圆点 + 播放状态。非当前曲目说「尚未播放」（Qt 的同一句），
  // 不能拿另一首歌的「正在播放」来冒充本页曲目。
  final double stateTop = metaTop + _metaRow;
  c.commands.add(<Object?>[
    'ellipse',
    c.amber,
    _gutter + 2,
    stateTop + 5,
    5,
    5,
  ]);
  // 只有本曲目在播才配「正在播放 / 暂停」：另一首在播时本页曲目仍是「尚未播放」，
  // 播放键也必须画成 ▶（点它 = 切到本曲目），不能沿用那首的暂停图标。
  final bool trackPlaying = current && playing;
  final String playbackState = !current
      ? '尚未播放'
      : (buffering ? '正在载入' : (playing ? '正在播放' : '已暂停'));
  c.text(
    playbackState,
    _gutter + 12,
    stateTop,
    size: 8,
    width: 160,
    color: c.muted,
  );

  // 控制带三块全部取 [_songLayout] 自上而下算好的 y，块与块之间至少留
  // [_minProgressGap]/[_minTransportGap]/[_minFooterGap]，任何高度都不叠。
  final double barY = layout.barY;
  final double transportCenter = layout.transportCenter;
  final double footerTop = layout.footerTop;
  _songFooterRow(
    c,
    top: footerTop,
    // 歌词/评论无需播放就能看，可用性由控制器按平台能力决定。
    lyricsAvailable: lyricsAvailable,
    commentsAvailable: commentsAvailable,
    mode: mode,
  );
  _songTransportRow(
    c,
    center: transportCenter,
    current: current,
    playing: trackPlaying,
  );
  _songProgressRow(
    c,
    barY: barY,
    current: current,
    lyricPreview: preview,
    positionMs: positionMs,
    durationMs: durationMs,
  );

  c.finish();
}

// ── 详情页纵向预算（网格单位，全部与 `c.height` 同量纲）────────────────────
// 每一块的高度都是常量：由 [_songLayout] 自上而下累加，任何页高都不重叠。

/// 关闭键（命中 16..68）下方的卡片顶。
const double _cardTop = 84;

/// 卡片 → 档案行。
const double _gapAfterCard = 16;

/// 档案行（类型标签 + 细线）。
const double _labelRow = 26;

/// 标题一行的高（25pt × 1.2 行距）。
const double _titleLine = 30;

/// 标题末行 → 艺人/专辑行。
const double _gapTitleMeta = 6;

/// 艺人/专辑 + 收藏心（心与命中叠在这 24 里）。
const double _metaRow = 24;

/// 状态点 + 状态字。
const double _stateRow = 18;

/// 轨道/刻度/刻度时间(30) + 两端时间与 PLAYBACK POSITION 标签(22)。
/// [_songProgressRow] 从 `barY - 22` 起笔；歌词预览另外占 [_lyricPreviewBlock]。
const double _progressBlock = 52;

/// 歌词预览单独占一条（预览行在时间标签之上），否则两者会压在一起。
const double _lyricPreviewBlock = 22;

/// 传输环直径（[_songTransportRow] 的 center ± 26）。
const double _transportBlock = 52;

/// 底部五入口的命中行。
const double _footerBlock = 48;

/// 三块之间的**最小**间距：矮屏时退到这里为止，再矮就只收卡片。
const double _minProgressGap = 12;
const double _minTransportGap = 14;
const double _minFooterGap = 12;

/// 底边呼吸空间（不含富余高度的分配）。
const double _bottomInset = 12;

/// 唱片卡的下限（网格单位）。
///
/// 上限不能写死 312：参考图的 312 是**393 宽设计稿**里的值（312/393 ≈ 79% 页宽），
/// 而本仓库的竖屏网格随 DPI 变宽（本机 586），写死 312 会让唱片只占页宽 53%，
/// 卡片封顶后的余量全堆到卡片下方变成一条空带。上限按页宽比例算。
const double _songCardMin = 96;

/// 唱片卡最大边长占页宽的比例（参考图 `312 / 393`）。
const double _songCardRatio = .79;

/// 除唱片卡之外的全部固定高度（含最小间距与底边距）。
double _songFloorHeight(int titleLines) =>
    _cardTop +
    _gapAfterCard +
    _labelRow +
    _titleLine * titleLines +
    _gapTitleMeta +
    _metaRow +
    _stateRow +
    _progressBlock +
    _transportBlock +
    _footerBlock +
    _minProgressGap +
    _minTransportGap +
    _minFooterGap +
    _bottomInset;

/// [paintPortraitSongPage] 的纵向排布结果。
typedef _SongLayout = ({
  double cardSide,
  double labelTop,
  double barY,
  double transportCenter,
  double footerTop,
});

/// 算详情页的纵向排布：控制带底锚、卡片吃余量。
///
/// 五入口钉在 `c.height - _bottomInset - _footerBlock`，传输环与进度条按最小间距上叠；
/// 四块固定内容扣掉后剩下的给唱片卡，夹在 [_songCardMin]..[页宽 × _songCardRatio]。
/// 卡片封顶后的余量七成放到卡片与档案行之间，三成留在状态行与进度条之间。
_SongLayout _songLayout(
  PortraitCanvas c, {
  required int titleLines,
  required bool lyricPreview,
}) {
  final double footerTop = math.max(
    0.0,
    c.height - _bottomInset - _footerBlock,
  );
  final double transportCenter =
      footerTop - _minFooterGap - _transportBlock / 2;
  // 进度块整体高：`_progressBlock`（轨道到刻度时间）+ 可选的歌词预览条。
  // [_songProgressRow] 从 `barY - 22` 起笔，到刻度时间 `barY + 30` 收，
  // 所以块顶 = 传输环顶 - 最小间距 - 块高，`barY` 再把预览条的高度让出来。
  final double previewBlock = lyricPreview ? _lyricPreviewBlock : 0;
  final double progressTop =
      transportCenter -
      _transportBlock / 2 -
      _minTransportGap -
      (_progressBlock + previewBlock);
  final double barY = progressTop + previewBlock + 22;

  final double textHeight =
      _labelRow +
      _titleLine * titleLines +
      _gapTitleMeta +
      _metaRow +
      _stateRow;
  final double availForCard =
      progressTop - _minProgressGap - _cardTop - _gapAfterCard - textHeight;
  final double cardCap = math.max(_songCardMin, c.gridWidth * _songCardRatio);
  final double cardSide = availForCard.clamp(_songCardMin, cardCap);
  final double extra = math.max(0.0, availForCard - cardSide);
  final double labelTop = _cardTop + cardSide + _gapAfterCard + extra * .7;
  return (
    cardSide: cardSide,
    labelTop: labelTop,
    barY: barY,
    transportCenter: transportCenter,
    footerTop: footerTop,
  );
}

/// 进度行：歌词预览 + 轨道/已播/游标 + 刻度 + 两端时间（左已播、右剩余）。
///
/// [current] = false 时轨道为空、游标停在最左、右侧显示本曲目的**总时长**
/// （Qt: `current ? "−" + time(rest) : model.duration`），且不产出 `seek` 字段。
void _songProgressRow(
  PortraitCanvas c, {
  required double barY,
  required bool current,
  required String lyricPreview,
  required double positionMs,
  required double durationMs,
}) {
  // 预览行在时间标签之上，独立一条（不能和 `_clock` 抢 `barY - 21`）。
  if (lyricPreview.isNotEmpty) {
    c.icon('lyrics-lines', _gutter, barY - 44, size: 11, color: c.muted);
    c.text(
      lyricPreview,
      _gutter + 18,
      barY - 43,
      size: 10,
      width: (c.gridWidth - 40) - 18,
      color: c.muted,
    );
  }
  final double fraction = current && durationMs.isFinite && durationMs > 0
      ? _unit(positionMs / durationMs)
      : 0;
  c.fill(Rect.fromLTWH(_gutter, barY, (c.gridWidth - 40), 2), c.line);
  if (fraction > 0) {
    c.fill(
      Rect.fromLTWH(_gutter, barY, (c.gridWidth - 40) * fraction, 2),
      c.amber,
    );
  }
  c.fill(
    Rect.fromLTWH(
      _gutter - 1.5 + (c.gridWidth - 40) * fraction,
      barY - 4,
      3,
      10,
    ),
    c.ink,
  );
  for (int tick = 0; tick <= 20; tick++) {
    c.fill(
      Rect.fromLTWH(_gutter + tick * 17.6, barY + 6, .6, tick % 5 == 0 ? 6 : 3),
      c.line,
    );
  }
  // 只有本曲目真的在播时才给拖动热区：否则拖一下就把别的曲目的播放位置改了。
  if (current) {
    c.field('seek', Rect.fromLTWH(15, barY - 12, c.gridWidth - 30, 26));
  }
  // 参考图版式：时间在轨道**上方**两侧（左已播 / 右总时长），中间是
  // `PLAYBACK POSITION` 小标；轨道下方另给 1/4、1/2、3/4 三处时间刻度。
  final double elapsed = current ? positionMs : 0;
  c.text(
    _clock(elapsed),
    _gutter,
    barY - 20,
    size: 11,
    width: 100,
    color: c.muted,
  );
  c.rightText(
    _clock(durationMs),
    c.gridWidth - _songRightInset,
    barY - 20,
    11,
    'regular',
    c.muted,
  );
  final String positionLabel = 'PLAYBACK POSITION';
  final double positionWidth = c.measure(positionLabel, 8, 'regular');
  c.text(
    positionLabel,
    (c.gridWidth - positionWidth) / 2,
    barY - 19,
    size: 8,
    color: c.muted,
  );
  if (durationMs.isFinite && durationMs > 0) {
    final double trackWidth = c.gridWidth - 40;
    for (final double fraction in <double>[0.25, 0.5, 0.75]) {
      final String caption = _clock(durationMs * fraction);
      final double captionWidth = c.measure(caption, 9, 'regular');
      c.text(
        caption,
        _gutter + trackWidth * fraction - captionWidth / 2,
        barY + 18,
        size: 9,
        color: c.muted,
      );
    }
  }
}

/// 传输三键：上一首 / 居中的圆环播放键 / 下一首。
///
/// 非当前曲目：播放键 = `music:play`（切到本曲目并播放），上一首/下一首按
/// **详情页所在列表**换曲（`music:detail-prev/next`），不发播放队列的
/// `player:*`——那会控制到另一首歌身上，正是本次要修的缺陷。
void _songTransportRow(
  PortraitCanvas c, {
  required double center,
  required bool current,
  required bool playing,
}) {
  final double cx = c.gridWidth / 2;
  c.commands.add(<Object?>[
    'arc',
    cx,
    center,
    26,
    0,
    math.pi * 2 - .02,
    1.2,
    c.ink,
  ]);
  c.icon(
    playing ? 'pause' : 'play',
    cx - 11,
    center - 11,
    size: 22,
    color: c.ink,
  );
  c.icon('prev', cx - 104, center - 12, size: 24, color: c.ink);
  c.icon('next', cx + 80, center - 12, size: 24, color: c.ink);
  c.hit(
    Rect.fromLTWH(cx - 128, center - 26, 48, 52),
    current ? 'player:prev' : 'music:detail-prev',
    '上一首',
  );
  c.hit(
    Rect.fromLTWH(cx - 34, center - 34, 68, 68),
    current ? 'player:toggle' : 'music:play',
    playing ? '暂停' : '播放',
  );
  c.hit(
    Rect.fromLTWH(cx + 56, center - 26, 48, 52),
    current ? 'player:next' : 'music:detail-next',
    '下一首',
  );
}

/// 底部五入口：歌词 / 评论 / 模式 / 队列 / 更多（Qt 竖屏歌曲页同一行）。
///
/// 参考图（`docs/flutter-migration/archive` 外的设备截图）里这一行是**纯文字**、
/// 等分页宽，当前模式那格用琥珀色；图标会把它挤成四格，所以不放图标。
///
/// **五格全部可点**：歌词/评论在「本曲目没在播」或「平台没有歌词/评论」时不留死键
/// （旧实现塞空串 `''`，`PortraitCanvas.hit` 对空动作直接 return，点了毫无反馈），
/// 而是发 [portraitSongHintLyrics] / [portraitSongHintComments]，由宿主
/// （`lib/basic/basic_app.dart` 的 `_route`）按真实原因给一句可见提示。
void _songFooterRow(
  PortraitCanvas c, {
  required double top,
  bool lyricsAvailable = true,
  bool commentsAvailable = false,
  String mode = 'all',
}) {
  c.fill(Rect.fromLTWH(_gutter, top, (c.gridWidth - 40), .6), c.line);
  final String modeLabel = switch (mode) {
    'shuffle' => '随机',
    'one' => '单曲',
    'off' => '单曲',
    _ => '顺序',
  };
  final List<String> labels = <String>['歌词', '评论', modeLabel, '队列', '更多'];
  final List<String> actions = <String>[
    lyricsAvailable ? 'player:lyrics' : portraitSongHintLyrics,
    commentsAvailable ? 'music:comments' : portraitSongHintComments,
    'player:mode',
    'player:open',
    'mobile:song-options',
  ];
  const List<String> hitLabels = <String>[
    '打开全屏歌词',
    '查看评论',
    '切换播放模式',
    '播放队列',
    '歌曲更多操作',
  ];
  // 不可用那两格的热区文案要说清是「提示」而不是「已执行」，无障碍读屏才不撒谎。
  final List<String> spoken = <String>[
    lyricsAvailable ? hitLabels[0] : '歌词不可用',
    commentsAvailable ? hitLabels[1] : '评论不可用',
    hitLabels[2],
    hitLabels[3],
    hitLabels[4],
  ];
  final double cell = (c.gridWidth - 40) / 5;
  for (int index = 0; index < labels.length; index++) {
    final double x = _gutter + cell * index;
    // 模式那格是唯一带状态的：非顺序播放时用琥珀色标出来。
    final bool active = index == 2 && mode != 'all';
    final bool mutedEntry =
        (index == 0 && !lyricsAvailable) || (index == 1 && !commentsAvailable);
    c.text(
      labels[index],
      x,
      top + 14,
      size: 12,
      width: cell,
      color: active ? c.amber : (mutedEntry ? c.line : c.muted),
    );
    // 命中铺满整格（旧实现左右各缩 4，小屏上五等分后每格只剩 ~66 宽，边缘很难点中）。
    c.hit(
      Rect.fromLTWH(x, top, cell, _footerBlock),
      actions[index],
      spoken[index],
    );
  }
}

/// 歌词页（沉浸播放条 + 滚动歌词）。返回前必须调用 c.finish()。
void paintPortraitLyricsPage(
  PortraitCanvas c, {
  required String title,
  required String artist,
  required String cover,
  required bool playing,
  required double positionMs,
  required double durationMs,
  required List<(int startMs, String text, String translation)> lines,
  required int activeLine,
  bool liked = false,
}) {
  final double h = c.height;

  // 歌词页整页铺纸色（Qt 的 lyric 分支：`paperPage || lyric` 全屏 paper），
  // 正文因此始终落在纸面而不是 3D 场景上。
  c.fill(Rect.fromLTWH(0, 0, c.gridWidth, math.max(0, h)), c.paper);
  // 顶部：只有一枚居中把手（下拉/点击收起），没有「RHINE LAB / 歌词」页头——
  // 参考图的歌词页是沉浸式全屏歌词，标题区只有封面 + 曲名 + 艺人 + 收藏/更多。
  // 把手本来就该在页面正中（设计稿 160..233 的中心是 196.5 ≈ 393/2），
  // 页宽变宽后必须按 gridWidth 居中，否则会明显偏左。
  final double handleLeft = (c.gridWidth - 73) / 2;
  c.fill(Rect.fromLTWH(handleLeft, 16, 73, 3), c.line);
  c.hit(
    Rect.fromLTWH(handleLeft - 40, 4, 153, 40),
    'player:lyrics-close',
    '收起歌词',
  );

  const Rect strip = Rect.fromLTWH(_gutter, 40, 44, 44);
  c.fill(strip, c.surface);
  if (cover.isNotEmpty) {
    c.image(cover, strip);
  }
  c.border(strip, c.line);
  // 曲名/艺人右界让给两枚图标（设计稿 250 = 393 - 76 - 67）。
  final double lyricTitleWidth = c.gridWidth - 76 - 96;
  c.text(title, 76, 44, size: 13, width: lyricTitleWidth, weight: 'demibold');
  c.text(artist, 76, 63, size: 10, width: lyricTitleWidth, color: c.muted);
  // Qt compact 歌词页右上两枚：收藏心（真态取 `selectedLiked`，命中
  // `music:like-current`）与「更多」（打开歌曲操作面板）。
  c.icon(
    liked ? 'heart-filled' : 'heart',
    c.gridWidth - 49,
    50,
    size: 18,
    color: liked ? c.ink : c.muted,
  );
  c.hit(
    Rect.fromLTWH(c.gridWidth - 63, 36, 44, 44),
    'music:like-current',
    '喜欢这首歌',
  );
  c.icon('more', c.gridWidth - 23, 52, size: 14, color: c.muted);
  c.hit(
    Rect.fromLTWH(c.gridWidth - 37, 36, 44, 44),
    'mobile:song-options',
    '歌曲更多操作',
  );

  // 阅读区从 118 起，下沿让给沉浸条。Qt 固定留 250（按 393×854 算），
  // 矮屏会把歌词压成一条缝；这里按可用高度取比例，最高 250、最少 150。
  const double viewTop = 118;
  // 沉浸条内容只画到 `top + 117`，再留 8 网格呼吸；按固定带高铺会空出一百多网格。
  const double barContentHeight = 125;
  final double bandTop = math.max(
    viewTop + 96,
    h - c.gestureInset - barContentHeight,
  );

  c.contentBottom = bandTop;
  c.beginContent(viewTop);
  _lyricsRows(
    c,
    top: viewTop,
    bottom: bandTop,
    lines: lines,
    activeLine: activeLine,
  );
  c.endContent();

  _lyricsBar(
    c,
    top: bandTop,
    playing: playing,
    positionMs: positionMs,
    durationMs: durationMs,
    liked: liked,
  );
  c.finish();
}

/// 逐行歌词：当前行大一号 + ink，其余 muted；译文小字挂在本行正文下方。
void _lyricsRows(
  PortraitCanvas c, {
  required double top,
  required double bottom,
  required List<(int startMs, String text, String translation)> lines,
  required int activeLine,
}) {
  final double height = math.max(0, bottom - top);
  if (lines.isEmpty) {
    // 空状态摆阅读区正中，别贴着顶沿（否则歌词区看起来像没铺开）。
    c.text(
      '暂无歌词 / NO LYRICS',
      _gutter,
      top + height / 2 - 8,
      size: 12,
      width: (c.gridWidth - 40),
      color: c.muted,
    );
    return;
  }

  final int active = activeLine >= 0 && activeLine < lines.length
      ? activeLine
      : -1;
  final List<double> tops = <double>[];
  final List<double> heights = <double>[];
  final List<List<String>> bodies = <List<String>>[];
  final List<List<String>> translations = <List<String>>[];
  double cursor = 0;
  for (int index = 0; index < lines.length; index++) {
    final bool isActive = index == active;
    final double size = isActive ? 22 : 18;
    final double lineHeight = isActive ? 30 : 26;
    final String body = lines[index].$2.isEmpty ? '•••' : lines[index].$2;
    final List<String> wrapped = c.wrap(
      body,
      (c.gridWidth - 40),
      size,
      isActive ? 'demibold' : 'regular',
    );
    final String source = lines[index].$3;
    final List<String> translated = source.isEmpty
        ? const <String>[]
        : c.wrap(source, (c.gridWidth - 40), 11);
    final double rowHeight =
        wrapped.length * lineHeight + translated.length * 17;
    tops.add(cursor);
    heights.add(rowHeight);
    bodies.add(wrapped);
    translations.add(translated);
    cursor += rowHeight + 20;
  }

  final double contentHeight = math.max(0, cursor - 20);
  // 没有滚动入参：把当前行摆到阅读区中线，越界时贴住两端（等价 Qt 的 follow 目标）。
  double scroll = active >= 0
      ? tops[active] + heights[active] / 2 - height / 2
      : 0;
  scroll = scroll.clamp(0, math.max(0, contentHeight - height + 24)).toDouble();

  for (int index = 0; index < lines.length; index++) {
    final double y = top + tops[index] - scroll;
    final double rowHeight = heights[index];
    if (y + rowHeight < top - 12 || y > bottom + 12) {
      continue;
    }
    final bool isActive = index == active;
    final double size = isActive ? 22 : 18;
    final double lineHeight = isActive ? 30 : 26;
    // 上下边缘 36 的渐隐（Qt lyrics() 的 edge 公式），保证滚动进出不生硬。
    final double edge = _unit(
      math.min((y + rowHeight - top) / 36, (bottom - y) / 36),
    );
    final List<Object?> color = List<Object?>.of(isActive ? c.ink : c.muted);
    color[3] = (isActive ? 1.0 : .32) * edge;
    final List<String> body = bodies[index];
    for (int line = 0; line < body.length; line++) {
      c.text(
        body[line],
        _gutter,
        y + line * lineHeight,
        size: size,
        width: (c.gridWidth - 40),
        weight: isActive ? 'demibold' : 'regular',
        color: color,
      );
    }
    final List<Object?> translated = List<Object?>.of(color);
    translated[3] = (isActive ? 1.0 : .32) * edge * .7;
    final List<String> translation = translations[index];
    for (int line = 0; line < translation.length; line++) {
      c.text(
        translation[line],
        _gutter,
        y + body.length * lineHeight + line * 17,
        size: 11,
        width: (c.gridWidth - 40),
        color: translated,
      );
    }
    // 下标必须是 lines 的真实下标：宿主用它换算真实 seek 目标。
    final double hitTop = math.max(top, y - 8);
    final double hitBottom = math.min(bottom, y + rowHeight + 10);
    if (hitBottom - hitTop > 8) {
      c.hit(
        Rect.fromLTWH(12, hitTop, c.gridWidth - 24, hitBottom - hitTop),
        'player:lyric-line:$index',
        body.join(' '),
      );
    }
  }
}

/// 沉浸播放条：进度 + 两端时间 + 五键（heart / prev / play / next / queue）。
void _lyricsBar(
  PortraitCanvas c, {
  required double top,
  required bool playing,
  required double positionMs,
  required double durationMs,
  required bool liked,
}) {
  final double h = c.height;
  c.fill(Rect.fromLTWH(0, top, c.gridWidth, .6), c.line);

  // 沉浸条几何照抄 Qt compact `player(c, immersive=true)`
  // （ResponsiveHudLayout.cpp:303-323）：进度 top+19、时间 top+32、
  // 五个按键 top+65..117。整条高度由调用方给的 bandHeight 决定，
  // 多出来的空间留在最下方，歌词因此拿到其余全部高度。
  final double barY = top + 19;
  final double fraction = durationMs.isFinite && durationMs > 0
      ? _unit(positionMs / durationMs)
      : 0;
  // 轨道宽度 = 页宽 - 左右各 26（设计稿 393 → 341）；DPI 适配后页宽比 393 宽。
  final double trackLeft = 26;
  final double trackWidth = math.max(60, c.gridWidth - 52);
  c.fill(Rect.fromLTWH(trackLeft, barY, trackWidth, 2), c.line);
  if (fraction > 0) {
    c.fill(Rect.fromLTWH(trackLeft, barY, trackWidth * fraction, 2), c.amber);
  }
  c.fill(
    Rect.fromLTWH(trackLeft - 1.5 + trackWidth * fraction, barY - 5, 3, 12),
    c.ink,
  );
  final double tickStep = trackWidth / 20;
  for (int tick = 0; tick <= 20; tick++) {
    c.fill(
      Rect.fromLTWH(
        trackLeft + tick * tickStep,
        barY + 4,
        .6,
        tick % 5 == 0 ? 6 : 3,
      ),
      c.line,
    );
  }
  c.field('seek', Rect.fromLTWH(trackLeft, top + 9, trackWidth, 24));
  c.text(
    _clock(positionMs),
    trackLeft,
    top + 32,
    size: 10,
    width: 100,
    color: c.muted,
  );
  c.rightText(
    _clock(durationMs),
    c.gridWidth - _songRightInset,
    top + 32,
    10,
    'regular',
    c.muted,
  );

  const List<String> icons = <String>['heart', 'prev', '', 'next', 'queue'];
  // Qt 沉浸条第 0 键是「喜欢」（`ResponsiveHudLayout.cpp:311-323` 的
  // `liked ? heart-filled : heart` + 路由 `music:like-current`）；只有
  // `m_player.canLike` 时才给命中，siren 的 descriptor `mutations.likeSong=true`。
  const List<String> routes = <String>[
    'music:like-current',
    'player:prev',
    'player:toggle',
    'player:next',
    'player:open',
  ];
  final List<String> labels = <String>[
    '喜欢',
    '上一首',
    playing ? '暂停' : '播放',
    '下一首',
    '播放队列',
  ];
  final double rowCenter = top + 90;
  // 五键等分页宽（设计稿 cell = 73 是 393 页宽算出来的，不能写死）。
  final double cell = (c.gridWidth - 52) / 5;
  final double iconOffset = (cell - 23) / 2;
  for (int index = 0; index < 5; index++) {
    final double x = 26 + index * cell;
    final double centerX = x + cell / 2;
    if (index == 2) {
      // 整圆必须少画一点：sweep 恰好 2π 时 Path.arcTo 会退化，环画不出来。
      c.commands.add(<Object?>[
        'arc',
        centerX,
        rowCenter,
        26,
        0,
        math.pi * 2 - .02,
        1.2,
        c.line,
      ]);
      c.icon(
        playing ? 'pause' : 'play',
        centerX - 11,
        rowCenter - 11,
        size: 22,
        color: c.ink,
      );
    } else if (index == 0) {
      c.icon(
        liked ? 'heart-filled' : icons[index],
        x + iconOffset,
        top + 79,
        size: 23,
        color: liked ? c.ink : c.muted,
      );
    } else {
      c.icon(icons[index], x + iconOffset, top + 79, size: 23, color: c.ink);
    }
    if (routes[index].isNotEmpty) {
      c.hit(Rect.fromLTWH(x, top + 65, cell, 52), routes[index], labels[index]);
    }
  }
  c.field(
    'playerBounds',
    Rect.fromLTWH(0, top, c.gridWidth, math.max(0, h - top)),
  );
}
