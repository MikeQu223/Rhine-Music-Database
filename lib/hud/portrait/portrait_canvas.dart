/// 竖屏（compact）画布：`Qt/src/ResponsiveHudCanvas.cpp` 的 Dart 移植。
///
/// 设计坐标是 393 pt 宽的手机网格：整份命令流先 `save` + `scale(unit, unit)`，
/// 之后所有绘制都在 393 网格里发生，命中矩形在发射时乘回舞台单位
/// （Qt/src/ResponsiveHudCanvas.cpp:129-149 的 `hit`/`field`）。
///
/// 本文件只做「把一次排版发射成命令流 + 命中表」，不持有任何业务状态：
/// 页面组合在 `portrait_layout.dart` / `portrait_pages_*.dart`，动作字符串由
/// 宿主（BasicHudSurface → basic_app）解释。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../protocol/hud_hit.dart';

/// 字形度量端口（Qt 侧是 `Glyphs`）。
///
/// 注入而不是自己量：HUD 的文字宽度必须与绘制用同一套字形，
/// 否则折行/截断/居中会和实际像素错开（Qt/src/ResponsiveHudCanvas.cpp:83-101）。
class PortraitMetrics {
  const PortraitMetrics({required this.width, required this.wrap, required this.bounds});

  final double Function(String value, double size, String weight) width;
  final List<String> Function(String value, double width, double size, String weight) wrap;
  final PortraitGlyphBounds Function(String value, double size, String weight) bounds;
}

/// `Glyphs::bounds` 的返回值（Qt 的 x/y 是相对基线的墨迹原点）。
class PortraitGlyphBounds {
  const PortraitGlyphBounds({
    this.x = 0,
    this.y = 0,
    this.width = 0,
    this.height = 0,
  });

  final double x;
  final double y;
  final double width;
  final double height;
}

/// 393 网格画布。
class PortraitCanvas {
  PortraitCanvas({
    required PortraitMetrics metrics,
    required this.unit,
    required this.height,
    required this.dark,
  }) : _metrics = metrics {
    ink = dark ? <Object?>[.925, .933, .886, 1] : <Object?>[.082, .110, .090, 1];
    muted = dark ? <Object?>[.63, .68, .60, 1] : <Object?>[.404, .431, .388, 1];
    line = dark ? <Object?>[.23, .28, .24, 1] : <Object?>[.741, .753, .702, 1];
    paper = dark ? <Object?>[.075, .110, .094, 1] : <Object?>[.933, .925, .894, 1];
    surface = dark ? <Object?>[.125, .165, .137, 1] : <Object?>[.910, .902, .863, 1];
    raised = dark ? <Object?>[.165, .208, .173, 1] : <Object?>[.871, .875, .820, 1];
    amber = <Object?>[.780, .608, .224, 1];
    commands.add(<Object?>['save']);
    commands.add(<Object?>['scale', unit, unit]);
  }

  final PortraitMetrics _metrics;

  /// 舞台单位 / 393（Qt 的 `m_unit`）。
  final double unit;

  /// 393 网格里的可视高度（= 舞台高 / unit）。
  final double height;

  final bool dark;

  final List<List<Object?>> commands = <List<Object?>>[];

  /// 命中矩形已在舞台单位（乘过 [unit]），与横屏命令流同一坐标口径。
  final List<HudHit> hits = <HudHit>[];

  /// 命名字段（播放条/进度条/输入框），舞台单位。
  final Map<String, Rect> fields = <String, Rect>{};

  /// 内容裁剪底（迷你播放条上沿）。
  double contentBottom = 693;

  late final List<Object?> ink;
  late final List<Object?> muted;
  late final List<Object?> line;
  late final List<Object?> paper;
  late final List<Object?> surface;
  late final List<Object?> raised;
  late final List<Object?> amber;

  double _clipTop = 0;
  bool _content = false;

  /// 内容裁剪区内可见的行区间（Qt/src/ResponsiveHudCanvas.cpp:27-31）。
  (int, int) visibleRows(double top, double stride, int count) {
    final int first = math.max(0, math.min(count, (((_clipTop - top) / stride).floor())));
    final int last = math.max(first, math.min(count, ((contentBottom - top) / stride).ceil()));
    return (first, last);
  }

  void fill(Rect r, List<Object?> c) {
    if (_content && (r.bottom <= _clipTop || r.top >= contentBottom)) {
      return;
    }
    commands.add(<Object?>['fill', c, r.left, r.top, r.width, r.height]);
  }

  /// 1px 级细边框：四条 0.7 网格单位的填充（Qt 侧同样不用 stroke）。
  void border(Rect r, List<Object?> c) {
    fill(Rect.fromLTWH(r.left, r.top, r.width, .7), c);
    fill(Rect.fromLTWH(r.left, r.bottom, r.width, .7), c);
    fill(Rect.fromLTWH(r.left, r.top, .7, r.height), c);
    fill(Rect.fromLTWH(r.right, r.top, .7, r.height), c);
  }

  void text(
    String v,
    double x,
    double y, {
    double size = 14,
    double width = 353,
    String weight = 'regular',
    List<Object?>? color,
  }) {
    if ((_content && (y + size < _clipTop || y > contentBottom)) || v.isEmpty || width <= 0) {
      return;
    }
    String value = v;
    if (_metrics.width(value, size, weight) > width) {
      while (value.isNotEmpty && _metrics.width('$value…', size, weight) > width) {
        value = value.substring(0, value.length - 1);
      }
      value = '$value…';
    }
    commands.add(<Object?>['text', value, x, y, size, weight, 0, color ?? ink]);
  }

  void rightText(String v, double right, double y, double size, String weight,
      [List<Object?>? color]) {
    text(v, right - _metrics.width(v, size, weight), y,
        size: size, width: right, weight: weight, color: color);
  }

  List<String> wrap(String v, double width, double size, [String weight = 'regular']) =>
      _metrics.wrap(v, width, size, weight);

  double measure(String v, double size, [String weight = 'regular']) =>
      _metrics.width(v, size, weight);

  double paragraph(
    String v,
    double x,
    double y, {
    double size = 13,
    double width = 353,
    List<Object?>? color,
    String weight = 'regular',
    int maximumLines = 0,
    double lineSpacing = 1.5,
  }) {
    final List<String> lines = _metrics.wrap(v, width, size, weight);
    final int count = maximumLines > 0 ? math.min(maximumLines, lines.length) : lines.length;
    double cursor = y;
    for (int index = 0; index < count; index++) {
      final bool truncated = index == count - 1 && count < lines.length;
      text(lines[index] + (truncated ? '…' : ''), x, cursor,
          size: size, width: width, weight: weight, color: color);
      cursor += size * lineSpacing;
    }
    return cursor;
  }

  /// 以墨迹包围盒居中（Qt/src/ResponsiveHudCanvas.cpp:103-108）。
  void centered(String value, double cx, double cy, double size,
      [String weight = 'regular', List<Object?>? color]) {
    final PortraitGlyphBounds bounds = _metrics.bounds(value, size, weight);
    text(value, cx - bounds.x - bounds.width / 2, cy - bounds.y - bounds.height / 2,
        size: size, width: 393, weight: weight, color: color);
  }

  /// 24×24 图标路径表（逐条抄自 Qt/src/ResponsiveHudCanvas.cpp:110-127）。
  static const Map<String, String> iconPaths = <String, String>{
    'search': 'M 21 21 L 16 16 M 18 10 C 18 14.4 14.4 18 10 18 C 5.6 18 2 14.4 2 10 C 2 5.6 5.6 2 10 2 C 14.4 2 18 5.6 18 10 Z',
    'settings': 'M 4 6 L 20 6 M 4 12 L 20 12 M 4 18 L 20 18 M 8 3 L 8 9 M 16 9 L 16 15 M 10 15 L 10 21',
    'back': 'M 15 5 L 8 12 L 15 19',
    'left': 'M 20 12 L 4 12 L 10 6 M 4 12 L 10 18',
    'right': 'M 4 12 L 20 12 L 14 6 M 20 12 L 14 18',
    'up': 'M 12 21 L 12 3 L 6 9 M 12 3 L 18 9',
    'down': 'M 12 3 L 12 21 L 6 15 M 12 21 L 18 15',
    'play': 'M 8 4 L 21 12 L 8 20 Z',
    'pause': 'M 8 4 L 8 20 M 16 4 L 16 20',
    'prev': 'M 5 4 L 5 20 M 20 4 L 8 12 L 20 20 Z',
    'next': 'M 19 4 L 19 20 M 4 4 L 16 12 L 4 20 Z',
    'repeat': 'M 3 7 L 19 7 L 15 3 M 19 7 L 19 11 M 21 17 L 5 17 L 9 21 M 5 17 L 5 13',
    'shuffle':
        'M 3 5 L 6 5 C 10 5 14 19 18 19 L 22 19 L 18 15 M 22 19 L 18 23 M 3 19 L 6 19 C 10 19 14 5 18 5 L 22 5 L 18 1 M 22 5 L 18 9',
    'transport-prev': 'M 4 4 L 4 20 M 19 4 Q 21 3 21 6 L 21 18 Q 21 21 19 20 L 8 14 Q 5 12 8 10 Z',
    'transport-next': 'M 20 4 L 20 20 M 5 4 Q 3 3 3 6 L 3 18 Q 3 21 5 20 L 16 14 Q 19 12 16 10 Z',
    'transport-pause': 'M 6 4 L 10 4 L 10 20 L 6 20 Z M 15 4 L 19 4 L 19 20 L 15 20 Z',
    'song-heart': 'M 12 21 C 8 18 2 14 2 8 C 2 2 9 1 12 5 C 15 1 22 2 22 8 C 22 14 16 18 12 21 Z',
    'queue-note':
        'M 2 5 L 18 5 M 2 12 L 13 12 M 2 19 L 10 19 M 21 5 L 21 17 C 21 23 13 23 13 19 C 13 15 19 15 21 17',
    'lyrics-lines': 'M 3 5 L 21 5 M 3 11 L 15 11 M 3 17 L 18 17',
    'queue': 'M 3 5 L 21 5 M 3 10 L 21 10 M 3 15 L 12 15 M 17 14 L 22 18 L 17 22 Z',
    'volume':
        'M 3 9 L 7 9 L 12 4 L 12 20 L 7 15 L 3 15 Z M 15 8 C 17 10 17 14 15 16 M 18 5 C 22 9 22 15 18 19',
    'database':
        'M 3 5 C 3 1 21 1 21 5 C 21 9 3 9 3 5 L 3 19 C 3 23 21 23 21 19 L 21 5 M 3 12 C 3 16 21 16 21 12',
    'compass': 'M 21 12 C 21 24 3 24 3 12 C 3 0 21 0 21 12 Z M 16 7 L 14 14 L 7 17 L 10 10 Z',
    'folder': 'M 2 6 L 9 6 L 11 8 L 22 8 L 22 21 L 2 21 Z M 2 6 L 2 3 L 9 3 L 11 6 L 21 6',
    'heart': 'M 12 24 L 0 12 L 0 5 L 5 0 L 10 0 L 12 3 L 14 0 L 19 0 L 24 5 L 24 12 Z',
    'close': 'M 6 6 L 18 18 M 6 18 L 18 6',
    'user': 'M 16 6 C 16 12 8 12 8 6 C 8 0 16 0 16 6 Z M 4 22 C 4 12 20 12 20 22',
    'more': 'M 5 12 L 6 12 M 11 12 L 12 12 M 17 12 L 18 12',
  };

  void icon(String name, double x, double y, {double size = 20, List<Object?>? color}) {
    commands.add(<Object?>['save']);
    commands.add(<Object?>['translate', x, y]);
    commands.add(<Object?>['scale', size / 24, size / 24]);
    if (name == 'heart-filled' || name == 'song-heart-filled') {
      final String pathName = name == 'song-heart-filled' ? 'song-heart' : 'heart';
      commands.add(<Object?>['fill-path', iconPaths[pathName]!, color ?? ink]);
    } else {
      commands.add(<Object?>['path', iconPaths[name] ?? iconPaths['more']!, 1.5, color ?? ink]);
    }
    commands.add(<Object?>['restore']);
  }

  void image(String key, Rect r) {
    if (key.isNotEmpty && (!_content || (r.bottom > _clipTop && r.top < contentBottom))) {
      commands.add(<Object?>['image', key, r.left, r.top, r.width, r.height]);
    }
  }

  void hit(Rect rect, String action, String label) {
    Rect r = rect;
    if (_content) {
      r = _intersect(r, Rect.fromLTWH(0, _clipTop, 393, math.max(0, contentBottom - _clipTop)));
    }
    if (action.isEmpty || r.isEmpty) {
      return;
    }
    hits.add(HudHit(
      x: r.left * unit,
      y: r.top * unit,
      width: r.width * unit,
      height: r.height * unit,
      action: action,
      label: label,
      fixed: true,
    ));
  }

  void field(String name, Rect rect) {
    Rect r = rect;
    if (_content) {
      r = _intersect(r, Rect.fromLTWH(0, _clipTop, 393, math.max(0, contentBottom - _clipTop)));
    }
    if (r.isEmpty) {
      return;
    }
    fields[name] = Rect.fromLTWH(r.left * unit, r.top * unit, r.width * unit, r.height * unit);
  }

  void button(Rect r, String title, String action, {bool primary = false, bool selected = false}) {
    fill(r, primary ? amber : (selected ? raised : surface));
    if (!primary) {
      border(r, line);
    }
    text(title, r.left + 12, r.top + (r.height - 13) / 2 - 1,
        size: 13,
        width: r.width - 24,
        weight: primary ? 'demibold' : 'regular',
        color: primary ? <Object?>[.09, .125, .08, 1] : ink);
    hit(r, action, title);
  }

  void chip(Rect r, String title, String action, {bool selected = false}) {
    if (selected) {
      fill(r, raised);
    }
    border(r, selected ? muted : line);
    text(title, r.left + 9, r.top + 12,
        size: 11, width: r.width - 18, color: selected ? ink : muted);
    hit(r, action, title);
  }

  void section(double y, String title, String subtitle) {
    text(title, 20, y, size: 17, width: 220, weight: 'demibold');
    text(subtitle, 245, y + 5, size: 9, width: 128, color: muted);
  }

  /// 收藏/列表行（Qt/src/ResponsiveHudCanvas.cpp:171-204）。
  void row(
    double y, {
    required String title,
    required String artist,
    required String stamp,
    required String action,
    String number = '',
    bool current = false,
    String remove = '',
    String playAction = '',
    String image = '',
    bool hasImage = false,
  }) {
    if (current) {
      fill(Rect.fromLTWH(20, y, 353, 68), raised);
      fill(Rect.fromLTWH(20, y, 2, 68), amber);
    }
    double left = number.isEmpty ? 20 : 54;
    if (hasImage) {
      left = 74;
    }
    if (hasImage) {
      final Rect artwork = Rect.fromLTWH(20, y + 12, 44, 44);
      fill(artwork, surface);
      if (image.isNotEmpty) {
        this.image(image, artwork);
      }
      border(artwork, line);
    } else {
      text(number, 25, y + 24, size: 11, width: 26, color: muted);
    }
    final double titleRight = playAction.isEmpty && remove.isEmpty ? 333 : 300;
    final double titleWidth = titleRight - left - 8;
    text(title, left, y + 12,
        size: 14,
        width: titleWidth,
        weight: 'demibold',
        color: current ? <Object?>[.455, .333, .098, 1] : ink);
    text(artist, left, y + 36, size: 11, width: titleRight - left, color: muted);
    if (remove.isEmpty) {
      if (playAction.isEmpty) {
        text(stamp, 333, y + 26, size: 10, width: 40, color: muted);
      }
    } else {
      icon('close', 342, y + 25, size: 16);
      hit(Rect.fromLTWH(329, y + 12, 44, 44), remove, '移除 $title');
    }
    fill(Rect.fromLTWH(20, y + 67, 353, .6), line);
    hit(Rect.fromLTWH(20, y, remove.isEmpty ? 353 : 305, 67), action, title);
    if (playAction.isNotEmpty) {
      text('▶ 全部', 309, y + 24, size: 10, width: 64);
      hit(Rect.fromLTWH(302, y + 12, 71, 44), playAction, '播放全部 $title');
    }
  }

  void indexRow(double y, String title, String subtitle, String action, String iconName) {
    icon(iconName, 20, y + 24);
    text(title, 52, y + 12, size: 14, width: 287, weight: 'demibold');
    text(subtitle, 52, y + 36, size: 11, width: 287, color: muted);
    icon('right', 352, y + 25, size: 16);
    fill(Rect.fromLTWH(20, y + 67, 353, .6), line);
    hit(Rect.fromLTWH(20, y, 353, 67), action, title);
  }

  void beginContent(double top) {
    _clipTop = top;
    _content = true;
    commands.add(<Object?>['save']);
    commands.add(<Object?>['clip', 0, top, 393, math.max(0, contentBottom - top)]);
  }

  void endContent() {
    commands.add(<Object?>['restore']);
    _content = false;
  }

  /// 内页页头（Qt/src/ResponsiveHudCanvas.cpp:226-252）。
  void header(
    String title, {
    bool back = false,
    bool libraryBack = false,
    bool showSettings = true,
    String backAction = 'back',
  }) {
    if (back) {
      icon('back', 28, 88);
      hit(Rect.fromLTWH(16, 76, 44, 44), backAction, '返回');
    }
    final double x = back ? 74 : 20;
    text('RHINE LAB / AUDIO ARCHIVE', x, 69,
        size: 8, width: libraryBack ? 175 : 240, color: muted);
    text(title, x, 87, size: 25, width: libraryBack ? 185 : (back ? 246 : 300), weight: 'demibold');
    if (libraryBack) {
      fill(Rect.fromLTWH(269, 60, 104, 42), raised);
      border(Rect.fromLTWH(269, 60, 104, 42), line);
      icon('left', 281, 71, size: 18);
      text('返回', 305, 71, size: 14, width: 60, weight: 'demibold');
      hit(Rect.fromLTWH(263, 54, 116, 54), 'back', '返回资料库');
      return;
    }
    if (!showSettings) {
      return;
    }
    icon(title == '设置' ? 'user' : 'settings', 341, 79);
    hit(Rect.fromLTWH(329, 66, 44, 44), title == '设置' ? 'saved' : 'settings',
        title == '设置' ? '我的音乐' : '设置');
  }

  void finish() {
    commands.add(<Object?>['restore']);
  }
}

Rect _intersect(Rect a, Rect b) {
  final double left = math.max(a.left, b.left);
  final double top = math.max(a.top, b.top);
  final double right = math.min(a.right, b.right);
  final double bottom = math.min(a.bottom, b.bottom);
  if (right <= left || bottom <= top) {
    return Rect.zero;
  }
  return Rect.fromLTRB(left, top, right, bottom);
}
