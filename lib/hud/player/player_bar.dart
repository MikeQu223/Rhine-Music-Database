// PlayerBar：横屏底部播放条的纯数据命令 / 命中构建器。
//
// 语义与顺序逐条移植自 Qt/src/PlayerBar.h 与 Qt/src/PlayerBar.cpp（1:1 真值）；
// 装配方式对齐 Qt/src/NativeHudPlayer.cpp:8-42（commands/hits/inputBounds/seek/volume）。
//
// 本文件不依赖 Flutter Widget / Material，也不 import lib/hud/protocol/* 或
// lib/domain/*：宿主负责把 commands 追加进整帧、把 hits 追加进命中表，并把
// inputBounds / seek / volume 交给输入分发。命令是 Qt 的 flat JSON 形态，
// 同代发布、不排序、不去重、不合并。

/// 行高（Qt PlayerBar::RowHeight）。
const double playerBarRowHeight = 96.0;

/// 浮窗品牌头高（Qt PlayerBar::HeaderHeight）。
const double playerBarHeaderHeight = 44.0;

/// 浮窗状态尾高（Qt PlayerBar::FooterHeight；本绘制器只做常量声明，未参与绘制）。
const double playerBarFooterHeight = 28.0;

/// 展示快照（Qt PlayerBar::State，PlayerBar.h:10-29）。
///
/// 不持有播放器、账号或页面控制器，便于主窗口与浮窗共享同一份输入。
class PlayerBarState {
  const PlayerBarState({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.cover = '',
    this.status = '',
    this.mode = '',
    this.positionMs = 0.0,
    this.durationMs = 0.0,
    this.volume = 1.0,
    this.playing = false,
    this.loading = false,
    this.failed = false,
    this.hasTrack = false,
    this.seekable = false,
    this.applicationVolume = true,
    this.liked = false,
    this.likeKnown = false,
    this.canLike = false,
    this.musicVideo = false,
  });

  final String title;
  final String artist;
  final String album;

  /// 封面键；非空时画 image，否则画唱片 ellipse 组。
  final String cover;

  /// 播放器状态文案；非空时覆盖默认状态尾与 failed 文案。
  final String status;

  /// shuffle / all / one；其它取值一律按顺序播放。
  final String mode;
  final double positionMs;
  final double durationMs;
  final double volume;
  final bool playing;
  final bool loading;
  final bool failed;
  final bool hasTrack;
  final bool seekable;

  /// 系统音量（false）时输出区不画音量条也不发音量命中。
  final bool applicationVolume;
  final bool liked;
  final bool likeKnown;
  final bool canLike;

  /// 是否画播放条上的 MV 按钮（Qt `PlayerBar::State::musicVideo`，
  /// 由 `PlatformFeatures::MusicVideo` 决定；本仓库 Android 侧 MV 已原生可播，
  /// 所以改由宿主按平台的 `capabilities.mv` 传入）。
  final bool musicVideo;
}

/// 组合形态（Qt PlayerBar::Surface，PlayerBar.h:31）。
enum PlayerBarSurface {
  /// 只画播放行。
  embedded,

  /// 播放行之上再组合品牌头与状态尾，行整体下移 [playerBarHeaderHeight]。
  floating,
}

/// Qt QRectF 的值等价物：x/y/width/height 加 right/bottom/center 派生量。
///
/// 用自有类型而非 dart:ui 的 Rect，保持本文件是纯 Dart 数据构建器。
class PlayerBarRect {
  const PlayerBarRect(this.x, this.y, this.width, this.height);

  final double x;
  final double y;
  final double width;
  final double height;

  double get left => x;
  double get top => y;
  double get right => x + width;
  double get bottom => y + height;
  double get centerX => x + width / 2;
  double get centerY => y + height / 2;

  @override
  bool operator ==(Object other) =>
      other is PlayerBarRect &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() =>
      'PlayerBarRect($x, $y, $width, $height)';
}

/// 文本包围盒（Qt Glyphs::bounds 的 x/y/width/height 四键）。
class GlyphBounds {
  const GlyphBounds({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  @override
  bool operator ==(Object other) =>
      other is GlyphBounds &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() =>
      'GlyphBounds($x, $y, $width, $height)';
}

/// 字形度量端口（Qt Glyphs::width 与 Glyphs::bounds 的只读两面）。
///
/// 绘制器只读这两个方法：width 用于省略号 fit，bounds 用于居中标签反推左上角。
abstract class GlyphsPort {
  /// 文本排版宽度（已含 tracking，与 Glyphs::width(value, size, weight) 一致）。
  double width(String value, double size, String weight);

  /// 文本包围盒（相对绘制原点；y 可为负）。
  GlyphBounds bounds(String value, double size, String weight);
}

/// 一帧的绘制产物（Qt PlayerBar::Drawing，PlayerBar.h:33-39）。
class PlayerBarDrawing {
  PlayerBarDrawing({
    required this.commands,
    required this.hits,
    required this.inputBounds,
    required this.seek,
    required this.volume,
  });

  /// flat 命令数组，顺序即 Qt append 顺序。
  final List<List<Object?>> commands;

  /// 命中表；每条含 x/y/width/height/action/label/fixed 七键。
  final List<Map<String, Object?>> hits;

  /// 播放行整块输入区（行矩形上扩 6）。
  final PlayerBarRect inputBounds;

  /// 进度条命中区；仅 seekable 且 durationMs > 0 时存在。
  final PlayerBarRect? seek;

  /// 音量条命中区；仅 applicationVolume 时存在。
  final PlayerBarRect? volume;
}

// ── 静态字形与调色板 ───────────────────────────────────────────────────────

const String _heartPath =
    'M 0 11 L -12 -1 L -12 -8 L -7 -13 L -2 -13 L 0 -10 L 2 -13 L 7 -13 L 12 -8 L 12 -1 Z';
const String _prevPath = 'M -57 -9 L -69 0 L -57 9 Z M -73 -10 L -73 10';
const String _nextPath = 'M 57 -9 L 69 0 L 57 9 Z M 73 -10 L 73 10';
const String _playPath = 'M -5 -10 L 9 0 L -5 10 Z';
const String _orderPath =
    'M -12 -8 L -3 -8 M -12 0 L -3 0 M -12 8 L -3 8 M 2 0 L 12 0 M 7 -5 L 12 0 L 7 5';
const String _shufflePath =
    'M -12 -8 L -6 -8 L 6 8 L 12 8 M 8 4 L 12 8 L 8 12 M -12 8 L -6 8 L 6 -8 L 12 -8 M 8 -12 L 12 -8 L 8 -4';
const String _loopPath =
    'M -11 3 L -11 -6 L -7 -9 L 11 -9 M 7 -13 L 11 -9 L 7 -5 M 11 -3 L 11 6 L 7 9 L -11 9 M -7 5 L -11 9 L -7 13';

/// Qt 的省略号（U+2026），逐字对齐 PlayerBar.cpp:39-42。
const String _ellipsis = '…';

/// 描边笔宽（path 命令的 1.5 实参）。
const double _strokeWidth = 1.5;

/// std::clamp 语义（要求 low <= high，与 Qt 调用点一致）。
double _clamp(double value, double low, double high) {
  if (value < low) {
    return low;
  }
  if (value > high) {
    return high;
  }
  return value;
}

/// QString::number(n).rightJustified(2, '0') 的等价实现。
String _twoDigits(int value) => value.toString().padLeft(2, '0');

/// 毫秒转 mm:ss（PlayerBar.cpp:8-12）。
///
/// seconds = floor(max(0, ms) / 1000)；分钟位数不封顶（100 分钟输出 100:00）。
String playerBarClock(double milliseconds) {
  final double nonNegative = milliseconds < 0 ? 0.0 : milliseconds;
  final int seconds = (nonNegative / 1000).floor();
  return '${_twoDigits(seconds ~/ 60)}:${_twoDigits(seconds % 60)}';
}

/// 单帧绘制累加器（Qt PlayerBar::Painter，PlayerBar.cpp:15-104）。
class _Painter {
  _Painter(this.glyphs, bool dark)
      : paper = dark ? _paperDark : _paperLight,
        ink = dark ? _inkDark : _inkLight,
        muted = dark ? _mutedDark : _mutedLight,
        line = dark ? _lineDark : _lineLight;

  final GlyphsPort glyphs;

  final List<List<Object?>> commands = <List<Object?>>[];
  final List<Map<String, Object?>> hits = <Map<String, Object?>>[];

  final List<double> paper;
  final List<double> ink;
  final List<double> muted;
  final List<double> line;

  /// 强调色在明暗两套调色板下相同（PlayerBar.cpp:31）。
  static const List<double> amber = <double>[0.863, 0.651, 0.227, 1.0];

  static const List<double> _paperLight = <double>[0.933, 0.937, 0.894, 1.0];
  static const List<double> _inkLight = <double>[0.141, 0.161, 0.145, 1.0];
  static const List<double> _mutedLight = <double>[0.4, 0.439, 0.392, 1.0];
  static const List<double> _lineLight = <double>[0.8, 0.816, 0.761, 1.0];

  static const List<double> _paperDark = <double>[0.133, 0.161, 0.137, 1.0];
  static const List<double> _inkDark = <double>[0.929, 0.941, 0.875, 1.0];
  static const List<double> _mutedDark = <double>[0.647, 0.678, 0.616, 1.0];
  static const List<double> _lineDark = <double>[0.298, 0.329, 0.282, 1.0];

  PlayerBarRect? seek;
  PlayerBarRect? volume;

  /// 由 renderPlayerBar 在绘制前赋值（对应 Qt drawing.inputBounds）。
  PlayerBarRect? inputBounds;

  void fill(PlayerBarRect rect, List<double> color) {
    commands.add(<Object?>['fill', color, rect.x, rect.y, rect.width, rect.height]);
  }

  /// 文本命令；超宽时按 Qt 规则 chop 尾部并补省略号（PlayerBar.cpp:36-45）。
  ///
  /// tracking 与 dash offset 两处 Qt 用整数字面量，这里保持同样的 JSON 形态。
  void label(
    String value,
    double x,
    double y,
    double size,
    double width, {
    String weight = 'regular',
    bool secondary = false,
  }) {
    String text = value;
    if (glyphs.width(text, size, weight) > width) {
      // QString::chop(1) 按 UTF-16 code unit 截断；Dart String 同为 UTF-16。
      while (text.isNotEmpty && glyphs.width(text + _ellipsis, size, weight) > width) {
        text = text.substring(0, text.length - 1);
      }
      text = text + _ellipsis;
    }
    commands.add(<Object?>['text', text, x, y, size, weight, 0, secondary ? muted : ink]);
  }

  /// 命中表条目；PlayerBar 所有命中都带 fixed:true（PlayerBar.cpp:46-54）。
  void hit(PlayerBarRect rect, String action, String label) {
    hits.add(<String, Object?>{
      'x': rect.x,
      'y': rect.y,
      'width': rect.width,
      'height': rect.height,
      'action': action,
      'label': label,
      'fixed': true,
    });
  }

  /// 图标路径：filled 走 fill-path，否则走带笔宽的 path（PlayerBar.cpp:55-61）。
  void path(String value, List<double> color, {bool filled = false}) {
    if (filled) {
      commands.add(<Object?>['fill-path', value, color]);
    } else {
      commands.add(<Object?>['path', value, _strokeWidth, color, const <Object?>[], 0]);
    }
  }

  /// 以 (centerX, centerY) 为中心的标签（PlayerBar.cpp:62-66）。
  void centeredLabel(
    String value,
    double centerX,
    double centerY,
    double size,
    String weight,
  ) {
    final GlyphBounds box = glyphs.bounds(value, size, weight);
    label(
      value,
      centerX - box.x - box.width / 2,
      centerY - box.y - box.height / 2,
      size,
      100,
      weight: weight,
    );
  }

  /// 播放键组（PlayerBar.cpp:67-88）。
  void controls(PlayerBarState state, double x, double y) {
    commands.add(<Object?>['save']);
    commands.add(<Object?>['translate', x, y]);
    path(_prevPath, ink);
    path(_nextPath, ink);
    fill(const PlayerBarRect(-23.0, -23.0, 46.0, 46.0), ink);
    if (state.loading) {
      // 加载提示使用底色，避免与深色播放键融在一起。
      fill(const PlayerBarRect(-11.0, -2.0, 4.0, 4.0), paper);
      fill(const PlayerBarRect(-2.0, -2.0, 4.0, 4.0), paper);
      fill(const PlayerBarRect(7.0, -2.0, 4.0, 4.0), paper);
    } else if (state.playing) {
      fill(const PlayerBarRect(-6.0, -9.0, 3.0, 18.0), paper);
      fill(const PlayerBarRect(3.0, -9.0, 3.0, 18.0), paper);
    } else {
      path(_playPath, paper, filled: true);
    }
    commands.add(<Object?>['restore']);
    hit(PlayerBarRect(x - 89, y - 24, 44, 48), 'player:prev', '上一首');
    hit(PlayerBarRect(x - 23, y - 23, 46, 46), 'player:toggle', state.playing ? '暂停' : '播放');
    hit(PlayerBarRect(x + 45, y - 24, 44, 48), 'player:next', '下一首');
  }

  /// 浮窗品牌头与状态尾（PlayerBar.cpp:89-103）。
  void chrome(PlayerBarState state, PlayerBarRect bounds) {
    final double x = bounds.x + 28;
    final double width = bounds.width - 56;
    label('RHINE LAB', x, bounds.y + 6, 17, width, weight: 'bold');
    label('莱茵生命 / 音频终端', x + 145, bounds.y + 10, 11, width - 145);
    fill(PlayerBarRect(bounds.x, bounds.y + playerBarHeaderHeight - 1, bounds.width, 1), line);
    final double bottom = bounds.y + playerBarHeaderHeight + playerBarRowHeight;
    fill(PlayerBarRect(bounds.x, bottom, bounds.width, 1), line);
    label('AUDIO ARCHIVE / RL–004', x, bottom + 6, 11, width, secondary: true);
    String status = state.status;
    if (status.isEmpty) {
      status = state.playing ? '正在播放' : '播放已暂停';
    }
    label(status, bounds.right - 228, bottom + 6, 11, 200, secondary: true);
  }
}

/// 歌曲信息行（PlayerBar.cpp:106-138）。
void _song(_Painter paint, PlayerBarState state, double x, double y, double width) {
  if (state.cover.isNotEmpty) {
    paint.commands.add(<Object?>['image', state.cover, x, y + 21, 54, 54]);
  } else {
    paint.commands.add(<Object?>['ellipse', paint.line, x, y + 21, 54, 54]);
    paint.commands.add(<Object?>['ellipse', paint.paper, x + 2, y + 23, 50, 50]);
    paint.commands.add(<Object?>['ellipse', paint.line, x + 10, y + 31, 34, 34]);
    paint.commands.add(<Object?>['ellipse', paint.paper, x + 11, y + 32, 32, 32]);
    paint.commands.add(<Object?>['ellipse', paint.ink, x + 23, y + 44, 8, 8]);
    paint.commands.add(<Object?>['ellipse', _Painter.amber, x + 37, y + 27, 5, 5]);
  }
  final double infoX = x + 74;
  final double infoWidth = width - 74;
  String caption = 'NOW PLAYING / 当前音轨';
  if (state.failed) {
    caption = state.status.isEmpty ? '音频连接中断' : state.status;
  } else if (state.loading) {
    caption = 'BUFFERING / 正在缓冲';
  }
  paint.label(caption, infoX, y + 13, 11, infoWidth, secondary: true);
  paint.label(
    state.title.isEmpty ? '尚未播放' : state.title,
    infoX,
    y + 32,
    23,
    infoWidth,
    weight: 'demibold',
  );
  String detail = state.artist;
  if (state.album.isNotEmpty) {
    detail = '$detail / ${state.album}';
  }
  if (detail.isEmpty) {
    detail = 'RHINE LAB / MUSIC DATABASE';
  }
  paint.label(detail, infoX, y + 65, 13, infoWidth, secondary: true);
  if (state.hasTrack) {
    paint.hit(PlayerBarRect(x, y + 14, width, 74), 'player:lyrics', '当前歌曲歌词');
  }
}

/// 进度行（PlayerBar.cpp:140-155）。
///
/// 命中区位于主界面与播放行的交界处，始终沿用整行宽度。
void _timeline(_Painter paint, PlayerBarState state, PlayerBarRect row) {
  final double position =
      state.durationMs > 0 ? _clamp(state.positionMs / state.durationMs, 0.0, 1.0) : 0.0;
  paint.fill(PlayerBarRect(row.x, row.y, row.width, 3), paint.line);
  paint.fill(PlayerBarRect(row.x, row.y, row.width * position, 3), _Painter.amber);
  final double markerX = _clamp(row.x + row.width * position - 1.5, row.left, row.right - 3);
  paint.fill(PlayerBarRect(markerX, row.y - 4, 3, 11), paint.ink);
  if (state.seekable && state.durationMs > 0) {
    final PlayerBarRect seek = PlayerBarRect(row.x, row.y - 6, row.width, 18);
    paint.seek = seek;
    paint.hit(seek, 'player:seek-fraction:0', '播放进度');
  }
  paint.label(
    playerBarClock(state.positionMs),
    row.centerX - 157,
    row.y + 42,
    11,
    50,
    secondary: true,
  );
  paint.label(
    playerBarClock(state.durationMs),
    row.centerX + 110,
    row.y + 42,
    11,
    50,
    secondary: true,
  );
}

/// 喜欢按钮：与播放键共用行中心（PlayerBar.cpp:157-172）。
void _favorite(_Painter paint, PlayerBarState state, double x, double y) {
  paint.commands.add(<Object?>['save']);
  paint.commands.add(<Object?>['translate', x, y + 1]);
  paint.path(
    _heartPath,
    state.likeKnown ? paint.ink : paint.muted,
    filled: state.liked,
  );
  paint.commands.add(<Object?>['restore']);
  if (state.canLike) {
    String label = state.liked ? '取消喜欢当前歌曲' : '喜欢当前歌曲';
    if (!state.likeKnown) {
      label = '核实并切换当前歌曲喜欢状态';
    }
    paint.hit(PlayerBarRect(x - 24, y - 24, 48, 48), 'music:like-current', label);
  }
}

/// 播放模式（PlayerBar.cpp:174-199）。
///
/// 模式文案不绘制在行内，只作为命中标签随动作下发。
void _playbackMode(_Painter paint, PlayerBarState state, double x, double y) {
  paint.commands.add(<Object?>['save']);
  paint.commands.add(<Object?>['translate', x, y]);
  String label;
  if (state.mode == 'shuffle') {
    label = '随机播放';
    paint.path(_shufflePath, paint.ink);
  } else if (state.mode == 'all' || state.mode == 'one') {
    label = state.mode == 'one' ? '单曲循环' : '列表循环';
    paint.path(_loopPath, paint.ink);
    if (state.mode == 'one') {
      paint.centeredLabel('1', 0, 0, 12, 'demibold');
    }
  } else {
    label = '顺序播放';
    paint.path(_orderPath, paint.ink);
  }
  paint.commands.add(<Object?>['restore']);
  paint.hit(PlayerBarRect(x - 24, y - 24, 48, 48), 'player:mode', '$label，点击切换播放模式');
}

/// 歌词入口（PlayerBar.cpp:201-206）。
void _lyrics(_Painter paint, PlayerBarState state, double x, double y) {
  paint.centeredLabel('词', x, y, 19, 'regular');
  if (state.hasTrack) {
    paint.hit(PlayerBarRect(x - 24, y - 24, 48, 48), 'player:lyrics', '当前歌曲歌词');
  }
}

/// MV 入口（PlayerBar.cpp:277-282）：只有平台支持 MV 时才画，词按钮相应左移 20。
void _mv(_Painter paint, PlayerBarState state, double x, double y) {
  paint.centeredLabel('MV', x, y, 15, 'regular');
  // Qt `PlayerBar.cpp:277-282` 的 label 与 hit 都不看 hasTrack：平台支持 MV 就画，
  // 没有当前曲目时点下去由 `MvController` 自己忽略（本仓库 `MvAction.open` 同理）。
  paint.hit(PlayerBarRect(x - 24, y - 24, 48, 48), 'player:mv', '打开 MV 播放窗口');
}

/// 输出区：音量与队列（PlayerBar.cpp）。
///
/// 移动端 `applicationVolume` 恒假，整块输出区都不画（不是禁用滑轨、也不是换成
/// 「系统音量」），只留右侧队列入口，也不发音量命中。
void _output(
  _Painter paint,
  PlayerBarState state,
  double x,
  double y,
  double right,
) {
  if (state.applicationVolume) {
    paint.fill(PlayerBarRect(x - 22, y + 23, 1, 50), paint.line);
    paint.label('OUTPUT / 输出', x, y + 29, 11, 180, secondary: true);
    paint.label('音量', x, y + 53, 14, 78);
    final double volumeX = x + 58;
    final PlayerBarRect volume = PlayerBarRect(volumeX, y + 47, 100, 28);
    paint.volume = volume;
    paint.fill(PlayerBarRect(volumeX, y + 60, 100, 3), paint.line);
    paint.fill(
      PlayerBarRect(volumeX, y + 60, 100 * _clamp(state.volume, 0.0, 1.0), 3),
      paint.ink,
    );
    paint.hit(volume, 'player:volume-fraction:0', '音量');
  }
  final double queueX = right - 65;
  paint.fill(PlayerBarRect(queueX, y + 28, 19, 1.5), paint.ink);
  paint.fill(PlayerBarRect(queueX, y + 34, 19, 1.5), paint.ink);
  paint.fill(PlayerBarRect(queueX, y + 40, 13, 1.5), paint.ink);
  paint.label('队列', queueX - 3, y + 57, 11, 50);
  paint.hit(PlayerBarRect(queueX - 14, y + 16, 54, 65), 'player:open', '播放队列');
}

/// 将播放快照转换为独立绘制命令（Qt PlayerBar::render，PlayerBar.cpp:228-252）。
///
/// 装饰只在 [PlayerBarSurface.floating] 组合，不访问也不修改播放状态。
/// [surface] 默认 embedded，对应 Qt 的默认实参 Surface::Embedded。
PlayerBarDrawing renderPlayerBar(
  PlayerBarState state,
  PlayerBarRect bounds,
  bool dark,
  GlyphsPort glyphs, [
  PlayerBarSurface surface = PlayerBarSurface.embedded,
]) {
  final _Painter paint = _Painter(glyphs, dark);
  paint.fill(bounds, paint.paper);
  double y = bounds.y;
  if (surface == PlayerBarSurface.floating) {
    paint.chrome(state, bounds);
    y += playerBarHeaderHeight;
  }
  final double center = bounds.centerX;
  final double outputX = bounds.right - 300;
  final double favoriteX = bounds.x + bounds.width * 0.23;
  final double songWidth = favoriteX - bounds.x - 62;
  final PlayerBarRect row = PlayerBarRect(bounds.x, y, bounds.width, playerBarRowHeight);
  paint.inputBounds = PlayerBarRect(row.x, row.y - 6, row.width, row.height + 6);
  _song(paint, state, bounds.x + 28, y, songWidth);
  final double centerY = y + playerBarRowHeight / 2;
  _favorite(paint, state, favoriteX, centerY);
  paint.controls(state, center, centerY);
  _lyrics(paint, state, bounds.right - (state.musicVideo ? 490 : 470), centerY);
  if (state.musicVideo) {
    _mv(paint, state, bounds.right - 435, centerY);
  }
  _playbackMode(paint, state, bounds.right - 380, centerY);
  _timeline(paint, state, row);
  _output(paint, state, outputX, y, bounds.right);
  return PlayerBarDrawing(
    commands: paint.commands,
    hits: paint.hits,
    inputBounds: paint.inputBounds!,
    seek: paint.seek,
    volume: paint.volume,
  );
}
