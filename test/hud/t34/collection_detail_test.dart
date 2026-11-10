// T34 集合详情 HUD 页（lib/hud/pages/collection_detail.dart）的独立单元测试。
//
// 期望值全部对着 Qt 真值写，不引用本页实现的内部符号：
// - Qt/src/NativeHudDetail.cpp:340-511    container() 的模型构建与命令信封（含 :440 的 "music:subscribe"）
// - Qt/src/CollectionDetailCard.cpp:1-262 卡片排版 / 调色板 / 五个绘制段的顺序
// - Qt/src/CollectionDetailCard.h:11-64   Choice / Fact / Row / Model 字段与默认值
// - Qt/src/NativeHud.cpp:10-174           hudInk / fill / text / fit / hit / button / image、containerLayout、detailBounds
// - Qt/src/NativeHud.h:37-47              Layout 默认值（left 40 / top 260 / rowsY 434 / rowHeight 54 / rowCount 9 / bottom 956）
// - Qt/src/MusicData.cpp:148-158          pad() 与 time()（含 duration<=0 → "暂无"）
// - Qt/src/MusicMutation.cpp:47-66        canEditPlaylist 已内含 kind/special/creatorID，卡片不得再判 kind
// - Qt/src/PlaybackQueue.cpp:36-38        identity = provider(缺省 netease) + ":" + id
//
// 三套横向几何必须分开断言，混用是这套页面最容易蒙混过去的错误：
// - 底板 bounds = detailBounds = (40, 260, 1840, 696)，宽 1840（= 1920 - 2*40）；
// - 卡片内容列 model.x / model.width = containerLayout = (416, 1464)，right 1880、contentRight 1858；
// - 侧栏列 sx = Model.left + 22 = 62（不是 model.x = 416），sideWidth = sidebar - 44 = 296。
// 同理：sheet 宽 = model.width + 18 = 1482（不是 bounds 宽 + 18 = 1858）；
// artistX = model.x + model.width * 0.55（不是 contentRight 的 1442 * 0.55）；
// rightLabel 的右对齐只用 measure(value, size, weight)，tracking 不参与度量。
//
// 本任务禁止执行任何构建 / 测试命令，因此本文件的 RED/GREEN 均为"未执行"，
// 只作为待执行的源码证据提交（报告记录 validationExecuted=false）。

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/pages/collection_detail.dart';

// ---------------------------------------------------------------------------
// 假字形端口：宽度 = 字符数 * size * charWidth + 字符数 * tracking
// ---------------------------------------------------------------------------

/// 故意让 tracking 参与宽度：一旦 rightLabel 误用带 tracking 的度量，
/// 右对齐 x 就会差 len*tracking，断言立刻暴露（Qt 见 CollectionDetailCard.cpp:62-66）。
class _FakeGlyphs implements CollectionDetailGlyphsPort {
  const _FakeGlyphs({this.charWidth = 0.5});

  final double charWidth;

  @override
  double width(String value, double size, String weight, [double tracking = 0]) {
    return value.length * size * charWidth + value.length * tracking;
  }

  @override
  List<String> wrap(String value, double width, double size, String weight) {
    final int perLine = math.max(1, (width / (size * charWidth)).floor());
    final List<String> lines = <String>[];
    for (final String paragraph in value.split('\n')) {
      for (int start = 0; start < paragraph.length; start += perLine) {
        lines.add(paragraph.substring(start, math.min(paragraph.length, start + perLine)));
      }
    }
    if (lines.isEmpty) {
      lines.add('');
    }
    return lines;
  }
}

const _FakeGlyphs _glyphs = _FakeGlyphs();

// ---------------------------------------------------------------------------
// 几何常量（1920 x 1080 舞台；Qt 只看宽度，高度由 Layout 固定）
// ---------------------------------------------------------------------------

const double _width = 1920;
const double _left = 40;
const double _sidebar = 340;
const double _sideWidth = 296;
const double _x = 416;
const double _modelWidth = 1464;
const double _right = 1880;
const double _contentRight = 1858;
const double _boundsX = 40;
const double _boundsWidth = 1840;
const double _sx = 62;
const double _titleX = 464;
const double _artistX = _x + _modelWidth * 0.55;
const double _timeEdge = _contentRight - 60;
const double _rowsY = 434;
const double _rowHeight = 54;

// ---------------------------------------------------------------------------
// 调色板（CollectionDetailCard.cpp:16-50；四元素、无 calibrated 标记）
// ---------------------------------------------------------------------------

const List<Object?> _paperLight = <Object?>[0.945, 0.941, 0.906, 1];
const List<Object?> _panelLight = <Object?>[0.973, 0.969, 0.933, 1];
const List<Object?> _inkLight = <Object?>[0.133, 0.165, 0.145, 1];
const List<Object?> _mutedLight = <Object?>[0.384, 0.42, 0.376, 1];
const List<Object?> _lineLight = <Object?>[0.80, 0.808, 0.753, 1];
const List<Object?> _softLight = <Object?>[0.898, 0.906, 0.855, 1];
const List<Object?> _amber = <Object?>[0.835, 0.639, 0.282, 1];

const List<Object?> _paperDark = <Object?>[0.08, 0.095, 0.09, 1];
const List<Object?> _panelDark = <Object?>[0.095, 0.11, 0.1, 1];
const List<Object?> _inkDark = <Object?>[0.93, 0.94, 0.88, 1];

/// NativeHud.cpp:10-15：亮色是 calibratedRGB，暗色才是 calibratedWhite。
const List<Object?> _hudInkLight = <Object?>[0.08, 0.085, 0.075, 1, 'calibratedRGB'];
const List<Object?> _hudInkDark = <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite'];

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

String _repeat(String unit, int count) => List<String>.filled(count, unit).join();

/// 曲目 01..NN：时长 03:45 起每条 +1s，日期 2024-01-01 起。
List<CollectionDetailTrack> _songs(int count) {
  return <CollectionDetailTrack>[
    for (int i = 0; i < count; i++)
      CollectionDetailTrack(
        id: (i + 1).toString(),
        title: '曲目 ' + (i + 1).toString().padLeft(2, '0'),
        artist: '歌手 ' + (i + 1).toString().padLeft(2, '0'),
        durationMs: 225000.0 + i * 1000,
        date: '2024-01-' + (i + 1).toString().padLeft(2, '0'),
      ),
  ];
}

CollectionDetailState _state({
  String kind = 'playlist',
  String provider = 'netease',
  String providerName = '网易云音乐',
  String title = '夜航',
  String artist = '群星',
  String id = '42',
  String coverKey = 'cover:42',
  bool virtual = false,
  bool special = false,
  bool local = false,
  bool localCollection = false,
  int itemTrackCount = 0,
  int directoryIdCount = 0,
  List<CollectionDetailTrack>? songs,
  List<int>? trackOrder,
  String sortField = 'none',
  bool directory = false,
  int? directoryIndex,
  String? currentIdentity,
  String date = '2024-01-01',
  String description = '专辑简介',
  bool dark = false,
  int trackOffset = 0,
  bool artistAlbums = false,
  bool albumsMore = false,
  bool albumsLoading = false,
  bool directoryLoading = false,
  bool detailLoading = false,
  bool sortRequest = false,
  String sortNotice = '',
  bool canEditPlaylist = false,
  bool canMutateSubscribe = false,
  bool subscribed = false,
  String? subscriptionState,
}) {
  return CollectionDetailState(
    kind: kind,
    provider: provider,
    providerName: providerName,
    title: title,
    artist: artist,
    id: id,
    coverKey: coverKey,
    virtual: virtual,
    special: special,
    local: local,
    localCollection: localCollection,
    itemTrackCount: itemTrackCount,
    directoryIdCount: directoryIdCount,
    songs: songs ?? _songs(12),
    trackOrder: trackOrder,
    sortField: sortField,
    directory: directory,
    directoryIndex: directoryIndex,
    currentIdentity: currentIdentity,
    date: date,
    description: description,
    dark: dark,
    trackOffset: trackOffset,
    artistAlbums: artistAlbums,
    albumsMore: albumsMore,
    albumsLoading: albumsLoading,
    directoryLoading: directoryLoading,
    detailLoading: detailLoading,
    sortRequest: sortRequest,
    sortNotice: sortNotice,
    canEditPlaylist: canEditPlaylist,
    canMutateSubscribe: canMutateSubscribe,
    subscribed: subscribed,
    subscriptionState: subscriptionState,
  );
}

CollectionDetailDrawing _render([
  CollectionDetailState? state,
  double width = _width,
  double opacity = 1,
]) {
  return renderCollectionDetail(
    width: width,
    state: state ?? _state(),
    glyphs: _glyphs,
    opacity: opacity,
  );
}

// ---------------------------------------------------------------------------
// 断言助手
// ---------------------------------------------------------------------------

List<List<Object?>> _ops(CollectionDetailDrawing drawing, String op) {
  return drawing.commands
      .whereType<List<Object?>>()
      .where((List<Object?> command) => command.isNotEmpty && command[0] == op)
      .toList();
}

List<List<Object?>> _fills(CollectionDetailDrawing drawing) => _ops(drawing, 'fill');
List<List<Object?>> _texts(CollectionDetailDrawing drawing) => _ops(drawing, 'text');

List<Object?> _text(CollectionDetailDrawing drawing, String value) {
  final List<List<Object?>> matches =
      _texts(drawing).where((List<Object?> text) => text[1] == value).toList();
  expect(matches, hasLength(1), reason: '文本 "$value" 应恰好出现一次');
  return matches.single;
}

/// 同一文案可能在多处出现（标题同时出现在 header 与侧栏），用 x 定位。
List<Object?> _textAt(CollectionDetailDrawing drawing, String value, double x) {
  final List<List<Object?>> matches = _texts(drawing)
      .where((List<Object?> text) => text[1] == value && text[2] == x)
      .toList();
  expect(matches, hasLength(1), reason: '文本 "$value" @x=$x 应恰好出现一次');
  return matches.single;
}

bool _hasText(CollectionDetailDrawing drawing, String value) =>
    _texts(drawing).any((List<Object?> text) => text[1] == value);

Map<String, Object?> _hit(CollectionDetailDrawing drawing, String action) {
  final List<Map<String, Object?>> matches =
      drawing.hits.where((Map<String, Object?> hit) => hit['action'] == action).toList();
  expect(matches, hasLength(1), reason: '命中 "$action" 应恰好出现一次');
  return matches.single;
}

bool _hasHit(CollectionDetailDrawing drawing, String action) =>
    drawing.hits.any((Map<String, Object?> hit) => hit['action'] == action);

List<Map<String, Object?>> _hitsStarting(CollectionDetailDrawing drawing, String prefix) => drawing.hits
    .where((Map<String, Object?> hit) => (hit['action']! as String).startsWith(prefix))
    .toList();

List<double> _rect(Map<String, Object?> hit) => <double>[
      hit['x']! as double,
      hit['y']! as double,
      hit['width']! as double,
      hit['height']! as double,
    ];

bool _sameColor(List<Object?> actual, List<Object?> expected) {
  if (actual.length != expected.length) {
    return false;
  }
  for (int i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i]) {
      return false;
    }
  }
  return true;
}

bool _sameRgb(List<Object?> actual, List<Object?> expected) {
  if (actual.length < 3 || expected.length < 3) {
    return false;
  }
  return actual[0] == expected[0] && actual[1] == expected[1] && actual[2] == expected[2];
}

/// 精确匹配一条 fill（几何 + 颜色）。rgb=true 时只比前三通道。
List<Object?> _fill(
  CollectionDetailDrawing drawing,
  double x,
  double y,
  double width,
  double height,
  List<Object?> color, {
  bool rgb = false,
}) {
  final List<List<Object?>> matches = _fills(drawing).where((List<Object?> fill) {
    final List<Object?> actual = fill[1]! as List<Object?>;
    return fill[2] == x &&
        fill[3] == y &&
        fill[4] == width &&
        fill[5] == height &&
        (rgb ? _sameRgb(actual, color) : _sameColor(actual, color));
  }).toList();
  expect(matches, hasLength(1), reason: 'fill ($x, $y, $width, $height) 应恰好出现一次');
  return matches.single;
}

bool _hasFill(
  CollectionDetailDrawing drawing,
  double x,
  double y,
  double width,
  double height,
  List<Object?> color, {
  bool rgb = false,
}) {
  return _fills(drawing).any((List<Object?> fill) {
    final List<Object?> actual = fill[1]! as List<Object?>;
    return fill[2] == x &&
        fill[3] == y &&
        fill[4] == width &&
        fill[5] == height &&
        (rgb ? _sameRgb(actual, color) : _sameColor(actual, color));
  });
}

/// line 色 + 指定 alpha 的任意尺寸 fill：rule 是 1px 特例，
/// 但边框的竖线（outlinedButton / 封面 frame）高度分别是 44 / 280，不能只按 1px 找。
bool _hasLineFill(
  CollectionDetailDrawing drawing,
  double x,
  double y,
  double width,
  double height,
  double alpha, {
  List<Object?> color = _lineLight,
}) {
  return _fills(drawing).any((List<Object?> fill) {
    final List<Object?> actual = fill[1]! as List<Object?>;
    return fill[2] == x &&
        fill[3] == y &&
        fill[4] == width &&
        fill[5] == height &&
        actual.length == 4 &&
        actual[3] == alpha &&
        _sameRgb(actual, color);
  });
}

/// CollectionDetailCard.cpp:68-70：rule = 1px fill。
bool _hasRule(CollectionDetailDrawing drawing, double x, double y, double width, double alpha) =>
    _hasLineFill(drawing, x, y, width, 1, alpha);

bool _hasAmberRow(CollectionDetailDrawing drawing, double y) =>
    _hasFill(drawing, _x - 8, y, _contentRight - _x + 16, _rowHeight - 2, _amber);

void _collectStrings(Object? value, List<String> out) {
  if (value is String) {
    out.add(value);
    return;
  }
  if (value is List<Object?>) {
    for (final Object? element in value) {
      _collectStrings(element, out);
    }
    return;
  }
  if (value is Map<String, Object?>) {
    for (final Object? element in value.values) {
      _collectStrings(element, out);
    }
  }
}

List<String> _strings(CollectionDetailDrawing drawing) {
  final List<String> out = <String>[];
  _collectStrings(drawing.commands, out);
  _collectStrings(drawing.hits, out);
  return out;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

void main() {
  group('Qt 纯函数助手（MusicData.cpp:148-158 / NativeHud.cpp:160-174 / NativeHudDetail.cpp:387-421）', () {
    test('pad 右对齐补零，负号照 Qt 原样（MusicData.cpp:148-150）', () {
      expect(collectionDetailPad(1), '01');
      expect(collectionDetailPad(12), '12');
      expect(collectionDetailPad(5, 3), '005');
      // QString::number(-1) == "-1"，rightJustified(2, '0') 不截断也不补零。
      expect(collectionDetailPad(-1), '-1');
    });

    test('time 分钟/秒各补两位，非正时长是"暂无"（MusicData.cpp:152-158）', () {
      expect(collectionDetailTime(0), '暂无');
      expect(collectionDetailTime(-1), '暂无');
      expect(collectionDetailTime(225000), '03:45');
      expect(collectionDetailTime(59999), '00:59');
      expect(collectionDetailTime(3600000), '60:00');
    });

    test('containerLayout：sidebar 夹在 250..340，x = left+sidebar+36（NativeHud.cpp:160-166）', () {
      final CollectionDetailLayout wide = collectionDetailLayout(_width);
      expect(wide.left, 40);
      expect(wide.sidebar, 340);
      expect(wide.x, 416);
      expect(wide.width, 1464);
      expect(wide.top, 260);
      expect(wide.rowsY, 434);
      expect(wide.rowHeight, 54);
      expect(wide.rowCount, 9);
      expect(wide.bottom, 956);

      // 1200*0.23-40 = 236 → 夹到下界 250。
      final CollectionDetailLayout narrow = collectionDetailLayout(1200);
      expect(narrow.sidebar, 250);
      expect(narrow.x, 326);
      expect(narrow.width, 834);

      // 1280*0.23-40 = 254.4，尚未触底。
      final CollectionDetailLayout mid = collectionDetailLayout(1280);
      expect(mid.sidebar, closeTo(254.4, 1e-9));
      expect(mid.x, closeTo(330.4, 1e-9));
      expect(mid.width, closeTo(909.6, 1e-9));
    });

    test('detailBounds 非 song 分支 = (left, top, width-2*left, bottom-top)（NativeHud.cpp:172-173）', () {
      final CollectionDetailRect bounds = collectionDetailBounds(_width);
      expect(bounds.x, _boundsX);
      expect(bounds.y, 260);
      expect(bounds.width, _boundsWidth);
      expect(bounds.height, 696);
      expect(bounds.right, _right);
      expect(bounds.bottom, 956);

      final CollectionDetailRect narrow = collectionDetailBounds(1200);
      expect(narrow.width, 1120);
      expect(narrow.height, 696);
    });

    test('archiveId 前缀表与 virtual 覆盖（NativeHudDetail.cpp:387-393）', () {
      expect(collectionDetailArchiveId(_state()), 'NETEASE ID / 42');
      expect(collectionDetailArchiveId(_state(provider: 'qq')), 'QQ MID / 42');
      expect(collectionDetailArchiveId(_state(provider: 'kugou')), 'KUGOU ID / 42');
      // 表外 provider 不加前缀（prefixes[provider] 为空）。
      expect(collectionDetailArchiveId(_state(provider: 'other')), '42');
      // virtual 优先：providerName + " / " + title。
      expect(collectionDetailArchiveId(_state(virtual: true)), '网易云音乐 / 夜航');
    });

    test('subject / record / totalCount（NativeHudDetail.cpp:395-421）', () {
      expect(collectionDetailSubject('artist'), '歌手');
      expect(collectionDetailSubject('playlist'), '歌单');
      expect(collectionDetailSubject('album'), '专辑');

      expect(_state().record, 'PLAYLIST RECORD');
      expect(_state(kind: 'album').record, 'ALBUM RECORD');
      expect(_state(kind: 'artist').record, 'ARTIST RECORD');

      expect(_state().totalCount, 12);
      expect(_state(itemTrackCount: 30).totalCount, 30);
      expect(_state(directoryIdCount: 40).totalCount, 40);
    });
  });

  group('命令信封（NativeHudDetail.cpp:503-510 / NativeHud.cpp:110-120）', () {
    test('顺序是 save → alpha → 返回按钮 → 卡片 → restore', () {
      final CollectionDetailDrawing drawing = _render();
      expect(drawing.commands.first, <Object?>['save']);
      expect(drawing.commands[1], <Object?>['alpha', 1.0]);
      expect(drawing.commands.last, <Object?>['restore']);
      expect(_ops(drawing, 'save'), hasLength(1));
      expect(_ops(drawing, 'restore'), hasLength(1));
    });

    test('返回按钮几何与文案 = layout.left+19 / 211 / sideWidth / 54', () {
      final CollectionDetailDrawing drawing = _render();
      final Map<String, Object?> hit = _hit(drawing, 'music:directory');
      expect(hit['label'], '← 返回曲目资料库   ESC');
      expect(_rect(hit), <double>[59, 211, 296, 54]);

      final List<Object?> text = _text(drawing, '← 返回曲目资料库   ESC');
      // button(): text(label, x, y+(height-size)/2-4) = 211+(54-20)/2-4 = 224。
      expect(text.sublist(2, 7), <Object?>[59.0, 224.0, 20.0, 'demibold', 0.0]);
    });

    test('详情页 m_modalControls=false：按钮文字用 hudInk 且亮色是 calibratedRGB', () {
      final CollectionDetailDrawing light = _render();
      final List<Object?> lightText = _text(light, '← 返回曲目资料库   ESC');
      expect(lightText[7], _hudInkLight);
      expect((lightText[7]! as List<Object?>)[4], 'calibratedRGB');

      final CollectionDetailDrawing dark = _render(_state(dark: true));
      expect(_text(dark, '← 返回曲目资料库   ESC')[7], _hudInkDark);
    });

    test('命中是六字段，绝不写成 fixed', () {
      final CollectionDetailDrawing drawing = _render();
      expect(drawing.hits, isNotEmpty);
      for (final Map<String, Object?> hit in drawing.hits) {
        expect(hit.keys.toSet(), <String>{'x', 'y', 'width', 'height', 'action', 'label'});
      }
    });

    test('opacity 原样透传到 alpha', () {
      final CollectionDetailDrawing drawing = _render(_state(), _width, 0.25);
      expect(drawing.commands[1], <Object?>['alpha', 0.25]);
    });

    test('只产出 save/alpha/fill/text/image/restore 六种命令', () {
      final CollectionDetailDrawing drawing = _render();
      final Set<Object?> ops =
          drawing.commands.whereType<List<Object?>>().map((List<Object?> c) => c[0]).toSet();
      expect(ops, <Object?>{'save', 'alpha', 'fill', 'text', 'image', 'restore'});
    });
  });

  group('底板、sheet 与调色板（CollectionDetailCard.cpp:27-50 / 115-120）', () {
    test('paper 铺满 detailBounds', () {
      _fill(_render(), _boundsX, 260, _boundsWidth, 696, _paperLight);
    });

    test('sheet 宽 = model.width + 18 = 1482，绝不是 bounds 宽 + 18', () {
      final CollectionDetailDrawing drawing = _render();
      // x-18 = 398，宽 1464+18 = 1482。
      _fill(drawing, _x - 18, 260, _modelWidth + 18, 696, _panelLight);
      expect(
        _fills(drawing).any((List<Object?> fill) => fill[4] == _boundsWidth + 18),
        isFalse,
        reason: 'sheet 不能拿 bounds 宽（1840）当 model.width（1464）用',
      );
    });

    test('sheet 顶部 3px ink 线与左侧 1px 竖线（y+3 起，高 bounds.height-29）', () {
      final CollectionDetailDrawing drawing = _render();
      _fill(drawing, _x - 18, 260, _modelWidth + 18, 3, _inkLight);
      expect(_hasLineFill(drawing, _x - 18, 263, 1, 696.0 - 29, 0.85), isTrue);
    });

    test('暗色主题换 paper/panel/ink，hudInk 才是 calibratedWhite', () {
      final CollectionDetailDrawing drawing = _render(_state(dark: true));
      _fill(drawing, _boundsX, 260, _boundsWidth, 696, _paperDark, rgb: true);
      _fill(drawing, _x - 18, 260, _modelWidth + 18, 696, _panelDark, rgb: true);
      expect(_textAt(drawing, '夜航', _x)[7], _inkDark);
    });
  });

  group('header（CollectionDetailCard.cpp:132-141）', () {
    test('kicker = providerName + " / " + record，位置 (x, 268, 11, 0.8)', () {
      final List<Object?> kicker = _text(_render(), '网易云音乐 / PLAYLIST RECORD');
      expect(kicker.sublist(2, 8), <Object?>[_x, 268.0, 11.0, 'regular', 0.8, _mutedLight]);
    });

    test('providerName 为空时回落 RHINE LAB', () {
      expect(_hasText(_render(_state(providerName: '')), 'RHINE LAB / PLAYLIST RECORD'), isTrue);
    });

    test('标题 32 bold tracking -0.6 起于 (x, 284)', () {
      final List<Object?> title = _textAt(_render(), '夜航', _x);
      expect(title.sublist(2, 7), <Object?>[_x, 284.0, 32.0, 'bold', -0.6]);
      expect(title[7], _inkLight);
    });

    test('标题按 contentRight-x-190 截断：78 字符含省略号', () {
      final String long = _repeat('长', 200);
      final CollectionDetailDrawing drawing = _render(_state(title: long));
      final List<Object?> title = _texts(drawing)
          .firstWhere((List<Object?> text) => text[2] == _x && text[3] == 284.0);
      final String value = title[1]! as String;
      // 1252 / (32*0.5) = 78.25 → 78，Qt 返回 left(77)+"…"。
      expect(value.length, 78);
      expect(value.endsWith('…'), isTrue);
      expect(value.substring(0, 77), _repeat('长', 77));
    });

    test('totalCount 右对齐只用 measure（38 light），tracking -1 不参与度量', () {
      final CollectionDetailDrawing drawing = _render();
      final List<Object?> total = _text(drawing, '12');
      expect(total[2], _contentRight - 38.0);
      expect(total[3], 270.0);
      expect(total.sublist(4, 7), <Object?>[38.0, 'light', -1.0]);
      // 若误用带 tracking 的度量会得到 1858-36 = 1822。
      expect(total[2], isNot(_contentRight - _glyphs.width('12', 38, 'light', -1)));
    });

    test('"TRACKS / 曲目" 同样只用 measure（11 字符 * 11 * 0.5 = 60.5）', () {
      final List<Object?> label = _text(_render(), 'TRACKS / 曲目');
      expect(label[2], _contentRight - 60.5);
      expect(label[3], 312.0);
      expect(label[6], 0.6);
      expect(label[2], isNot(_contentRight - 67.1));
    });
  });

  group('toolbar（CollectionDetailCard.cpp:143-158）', () {
    test('播放全部：ink 底 180x44、inverse 文字 (x+22, 349)', () {
      final CollectionDetailDrawing drawing = _render();
      _fill(drawing, _x, 339, 180, 44, _inkLight);
      final Map<String, Object?> hit = _hit(drawing, 'music:play-loaded');
      expect(hit['label'], '▶  播放全部');
      expect(_rect(hit), <double>[_x, 339, 180, 44]);
      final List<Object?> text = _text(drawing, '▶  播放全部');
      // primaryButton 文字用 y+12（CollectionDetailCard.cpp:111-112），不是垂直居中：
      // 339 + 12 = 351，不是 339 + (44-16)/2 - 4 = 349。
      expect(text.sublist(2, 7), <Object?>[438.0, 351.0, 16.0, 'demibold', 0.0]);
      expect(text[7], _panelLight);
    });

    test('排序按钮只在 playlist 出现，文字在 x+12', () {
      final CollectionDetailDrawing playlist = _render();
      final Map<String, Object?> hit = _hit(playlist, 'music:sort-menu');
      expect(hit['label'], '排序方式 ▾');
      expect(_rect(hit), <double>[611, 339, 180, 44]);
      // outlinedButton：四条 1px line 边框（alpha 0.9）+ 文字内缩 12。
      expect(_hasRule(playlist, 611, 339, 180, 0.9), isTrue);
      expect(_hasRule(playlist, 611, 382, 180, 0.9), isTrue);
      expect(_hasLineFill(playlist, 611, 339, 1, 44, 0.9), isTrue);
      expect(_hasLineFill(playlist, 790, 339, 1, 44, 0.9), isTrue);
      final List<Object?> text = _text(playlist, '排序方式 ▾');
      expect(text.sublist(2, 7), <Object?>[623.0, 349.0, 16.0, 'regular', 0.0]);

      for (final String kind in <String>['album', 'artist']) {
        final CollectionDetailDrawing other = _render(_state(kind: kind));
        expect(_hasHit(other, 'music:sort-menu'), isFalse, reason: 'kind=$kind 无排序入口');
        expect(_hasText(other, '排序方式 ▾'), isFalse);
      }
    });

    test('歌手 tabs：110x32 命中、13px 文字、选中项 42x3 琥珀下划线', () {
      final CollectionDetailDrawing drawing = _render(_state(kind: 'artist'));
      final Map<String, Object?> songs = _hit(drawing, 'music:artist-tab:songs');
      expect(_rect(songs), <double>[626, 345, 110, 32]);
      final Map<String, Object?> albums = _hit(drawing, 'music:artist-tab:albums');
      expect(_rect(albums), <double>[751, 345, 110, 32]);

      final List<Object?> songsText = _text(drawing, '热门歌曲');
      expect(songsText.sublist(2, 7), <Object?>[626.0, 355.0, 13.0, 'regular', 0.0]);
      expect(songsText[7], _inkLight);
      expect(_text(drawing, '发行专辑')[7], _mutedLight);

      _fill(drawing, 626, 377, 42, 3, _amber);
      expect(_fills(drawing).any((List<Object?> fill) => fill[2] == 751.0 && fill[3] == 377.0),
          isFalse);
    });

    test('非歌手页没有 tabs', () {
      final CollectionDetailDrawing drawing = _render();
      expect(_hasHit(drawing, 'music:artist-tab:songs'), isFalse);
      expect(_hasText(drawing, '热门歌曲'), isFalse);
    });

    test('TRACK INDEX 右对齐只用 measure（18 字符 * 11 * 0.5 = 99）', () {
      final List<Object?> label = _text(_render(), 'TRACK INDEX / 曲目目录');
      expect(label[2], _contentRight - 99.0);
      expect(label[3], 354.0);
      expect(label[6], 0.5);
      expect(label[2], isNot(_contentRight - 108.0));
    });
  });

  group('表体（CollectionDetailCard.cpp:160-198）', () {
    test('表头：2px ink 分隔线、四列标签、433 处 0.25 rule', () {
      final CollectionDetailDrawing drawing = _render();
      // fill(x, 398, contentRight-x, 2, ink*0.55)。
      expect(
        _fills(drawing).any((List<Object?> fill) {
          final List<Object?> color = fill[1]! as List<Object?>;
          return fill[2] == _x &&
              fill[3] == 398.0 &&
              fill[4] == _contentRight - _x &&
              fill[5] == 2 &&
              color[3] == 0.55 &&
              _sameRgb(color, _inkLight);
        }),
        isTrue,
      );

      expect(_text(drawing, '#').sublist(2, 8),
          <Object?>[_x, 414.0, 11.0, 'regular', 0.5, _mutedLight]);
      expect(_text(drawing, '曲目 / TITLE').sublist(2, 4), <Object?>[_titleX, 414.0]);
      expect(_text(drawing, '歌手 / ARTIST').sublist(2, 8),
          <Object?>[_artistX, 414.0, 11.0, 'regular', 0.5, _mutedLight]);

      final List<Object?> stamp = _text(drawing, '时长');
      expect(stamp[2], _timeEdge - 11.0);
      expect(stamp[3], 414.0);
      expect(stamp[6], 0.5);
      expect(stamp[2], isNot(_timeEdge - 12.0));

      expect(_hasRule(drawing, _x, 433, _contentRight - _x, 0.25), isTrue);
    });

    test('artistX = x + model.width*0.55，不是 contentRight 的 1442*0.55', () {
      expect(_artistX, isNot(_x + (_contentRight - _x) * 0.55));
      expect(_text(_render(), '歌手 / ARTIST')[2], _artistX);
      // 用错会偏 12.1px。
      expect(_text(_render(), '歌手 / ARTIST')[2], isNot(_x + 1442 * 0.55));
    });

    test('首行五个文本 + 行尾 rule + 整行命中', () {
      final CollectionDetailDrawing drawing = _render();
      // 行号 11px 在 (x, yy+18) = (416, 452)，非当前行用 muted。
      expect(_text(drawing, '01').sublist(2, 8),
          <Object?>[_x, 452.0, 11.0, 'regular', 0.0, _mutedLight]);

      // 曲名 18 demibold，fitted 到 (titleX, yy+13)。
      final List<Object?> title = _text(drawing, '曲目 01');
      expect(title.sublist(2, 7), <Object?>[_titleX, 447.0, 18.0, 'demibold', 0.0]);
      expect(title[7], _inkLight);

      // 歌手 13 regular (artistX, yy+17)。
      final List<Object?> artist = _text(drawing, '歌手 01');
      expect(artist.sublist(2, 7), <Object?>[_artistX, 451.0, 13.0, 'regular', 0.0]);
      expect(artist[7], _mutedLight);

      // 时长右对齐到 timeEdge，measure 30（5 字符 * 12 * 0.5）。
      final List<Object?> stamp = _text(drawing, '03:45');
      expect(stamp[2], _timeEdge - 30.0);
      expect(stamp[3], 452.0);
      expect(stamp.sublist(4, 7), <Object?>[12.0, 'regular', 0.0]);
      expect(stamp[7], _mutedLight);

      // 播放入口 "▷" 18px 右对齐到 contentRight：宽 9。
      final List<List<Object?>> arrows =
          _texts(drawing).where((List<Object?> text) => text[1] == '▷').toList();
      expect(arrows, hasLength(9));
      expect(arrows.first[2], _contentRight - 9.0);
      expect(arrows.first[3], 447.0);
      expect(arrows.first[7], _mutedLight);

      expect(_hasRule(drawing, _x, 487, _contentRight - _x, 0.15), isTrue);

      final Map<String, Object?> hit = _hit(drawing, 'music:track:0');
      expect(hit['label'], '曲目 01');
      expect(_rect(hit), <double>[_x - 8, _rowsY, _contentRight - _x + 16, _rowHeight - 2]);
    });

    test('只画 9 行（rowCount），第 10 条不出现', () {
      final CollectionDetailDrawing drawing = _render();
      expect(_hitsStarting(drawing, 'music:track:'), hasLength(9));
      expect(_hasText(drawing, '10'), isFalse);
      expect(_hit(drawing, 'music:track:8')['y'], _rowsY + 8 * _rowHeight);
    });

    test('trackOffset 只夹上界：12 条送 999 → 3', () {
      final CollectionDetailDrawing drawing = _render(_state(trackOffset: 999));
      expect(drawing.trackOffset, 3);
      expect(_hitsStarting(drawing, 'music:track:').first['action'], 'music:track:3');
      expect(_hitsStarting(drawing, 'music:track:').last['action'], 'music:track:11');
      // 序号按显示位置 +1：第一行是 04。
      expect(_text(drawing, '04')[3], 452.0);
    });

    test('trackOrder 只改内容/动作，不改显示序号（NativeHudDetail.cpp:460-482）', () {
      final List<int> order = List<int>.generate(12, (int i) => 11 - i);
      final CollectionDetailDrawing drawing = _render(_state(trackOrder: order));
      final Map<String, Object?> first = _hit(drawing, 'music:track:11');
      expect(first['label'], '曲目 12');
      expect(first['y'], _rowsY);
      expect(_text(drawing, '01')[3], 452.0);
      expect(_hit(drawing, 'music:track:10')['y'], _rowsY + _rowHeight);
    });

    test('曲名按 artistX-titleX-30 = 727.2 截断成 80 字符', () {
      final List<CollectionDetailTrack> songs = <CollectionDetailTrack>[
        CollectionDetailTrack(
          id: '1',
          title: _repeat('长', 200),
          artist: '歌手',
          durationMs: 225000,
        ),
      ];
      final CollectionDetailDrawing drawing = _render(_state(songs: songs));
      final List<Object?> title = _texts(drawing)
          .firstWhere((List<Object?> text) => text[3] == 447.0 && text[2] == _titleX);
      final String value = title[1]! as String;
      // 727.2 / (18*0.5) = 80.8 → 80，Qt 返回 left(79)+"…"。
      expect(value.length, 80);
      expect(value.endsWith('…'), isTrue);
      expect(value.substring(0, 79), _repeat('长', 79));
    });

    test('当前行：soft 底 + 3px 琥珀条 + ink 文字 + 琥珀 ▷', () {
      final CollectionDetailDrawing drawing = _render(_state(currentIdentity: 'netease:1'));
      _fill(drawing, _x - 8, _rowsY, _contentRight - _x + 16, _rowHeight - 2, _softLight);
      expect(_hasAmberRow(drawing, _rowsY), isTrue);
      expect(_text(drawing, '01')[7], _inkLight);
      final List<List<Object?>> arrows =
          _texts(drawing).where((List<Object?> text) => text[1] == '▷').toList();
      expect(arrows.first[7], _amber);
      // 只有第一行是当前行。
      expect(_hasAmberRow(drawing, _rowsY + _rowHeight), isFalse);
    });

    test('目录模式用 directoryIndex 判当前行（NativeHudDetail.cpp:476）', () {
      final CollectionDetailDrawing drawing =
          _render(_state(directory: true, directoryIndex: 1));
      expect(_hasAmberRow(drawing, _rowsY + _rowHeight), isTrue);
      expect(_hasAmberRow(drawing, _rowsY), isFalse);
    });

    test('无当前行时没有任何行被高亮', () {
      final CollectionDetailDrawing drawing = _render();
      expect(_hasFill(drawing, _x - 8, _rowsY, _contentRight - _x + 16, _rowHeight - 2, _softLight),
          isFalse);
      expect(_text(drawing, '01')[7], _mutedLight);
    });

    test('滚动条：轨道 right-8=1872 高 484，thumb 363（9/12）', () {
      final CollectionDetailDrawing drawing = _render();
      expect(
        _fills(drawing).any((List<Object?> fill) {
          final List<Object?> color = fill[1]! as List<Object?>;
          return fill[2] == _right - 8 &&
              fill[3] == _rowsY &&
              fill[4] == 2 &&
              fill[5] == 484 &&
              color[3] == 0.55 &&
              _sameRgb(color, _lineLight);
        }),
        isTrue,
      );
      expect(_fill(drawing, _right - 8, _rowsY, 2, 363, _mutedLight), isNotEmpty);
    });

    test('trackOffset=3 时 fraction=1，thumb 行进 121px', () {
      expect(_fill(_render(_state(trackOffset: 3)), _right - 8, _rowsY + 121, 2, 363, _mutedLight),
          isNotEmpty);
    });

    test('曲目数不超过 9 时不画滚动条', () {
      final CollectionDetailDrawing drawing = _render(_state(songs: _songs(5)));
      expect(
        _fills(drawing).any((List<Object?> fill) => fill[2] == _right - 8 && fill[4] == 2),
        isFalse,
      );
    });

    test('thumb 最少 28px（CollectionDetailCard.cpp:191-197 clamp）', () {
      final CollectionDetailDrawing drawing = _render(
        _state(songs: _songs(200), itemTrackCount: 200),
      );
      // 484 * 9/200 = 21.78 → clamp 到 28。
      expect(_fill(drawing, _right - 8, _rowsY, 2, 28, _mutedLight), isNotEmpty);
    });

    test('空曲目：22 demibold 空态文案在 (titleX, 500)，没有行命中', () {
      final CollectionDetailDrawing drawing =
          _render(_state(songs: const <CollectionDetailTrack>[]));
      final List<Object?> text = _text(drawing, '暂无可读取曲目');
      expect(text.sublist(2, 7), <Object?>[_titleX, 500.0, 22.0, 'demibold', 0.0]);
      expect(text[7], _inkLight);
      expect(_hitsStarting(drawing, 'music:track:'), isEmpty);
      expect(
        _fills(drawing)
            .any((List<Object?> fill) => fill[2] == _x && fill[3] == _rowsY && fill[5] == 1),
        isFalse,
      );
    });

    test('空曲目 + 载入中 → 正在载入曲目…', () {
      final CollectionDetailDrawing drawing =
          _render(_state(songs: const <CollectionDetailTrack>[], directoryLoading: true));
      expect(_hasText(drawing, '正在载入曲目…'), isTrue);
    });
  });

  group('侧栏（CollectionDetailCard.cpp:200-244）', () {
    test('封面 250x250 落在 artX=85（sx + (296-250)/2），不是基于 model.x', () {
      final CollectionDetailDrawing drawing = _render();
      // matte = (artX-8, matTop, artSize+16, matHeight) = (77, 344, 266, 280)。
      _fill(drawing, 77, 344, 266, 280, _softLight);
      final List<Object?> image = _ops(drawing, 'image').single;
      expect(image, <Object?>['image', 'cover:42', 85.0, 352.0, 250.0, 250.0]);
      // artX = 62 + 23 = 85；用 model.x 会得到 416+23 = 439。
      expect(image[2], isNot(_x + 23.0));
    });

    test('封面四边 frame 与 matte 的边界（alpha 0.9）', () {
      final CollectionDetailDrawing drawing = _render();
      expect(_hasRule(drawing, 77, 344, 266, 0.9), isTrue);
      expect(_hasRule(drawing, 77, 623, 266, 0.9), isTrue);
      expect(_hasLineFill(drawing, 77, 344, 1, 280, 0.9), isTrue);
      expect(_hasLineFill(drawing, 342, 344, 1, 280, 0.9), isTrue);
    });

    test('coverKey 为空时不产出 image 命令（NativeHud.cpp:130-134）', () {
      expect(_ops(_render(_state(coverKey: '')), 'image'), isEmpty);
    });

    test('archiveId 10px 落在封面下缘 +5', () {
      final List<Object?> archive = _text(_render(), 'NETEASE ID / 42');
      expect(archive.sublist(2, 7), <Object?>[85.0, 607.0, 10.0, 'regular', 0.0]);
      expect(archive[7], _mutedLight);
    });

    test('侧栏标题在 (sx, 642)，歌手在 (sx, 678)', () {
      final CollectionDetailDrawing drawing = _render();
      final List<Object?> title = _textAt(drawing, '夜航', _sx);
      expect(title.sublist(2, 7), <Object?>[_sx, 642.0, 22.0, 'bold', 0.0]);
      expect(title[7], _inkLight);
      // 侧栏列是 sx=62，不是 model.x=416。
      expect(title[2], isNot(_x));

      final List<Object?> artist = _textAt(drawing, '群星', _sx);
      expect(artist.sublist(2, 7), <Object?>[_sx, 678.0, 13.0, 'regular', 0.0]);
      expect(artist[7], _mutedLight);
    });

    test('两条事实：标签 11/0.5、值 13，行距 40', () {
      final CollectionDetailDrawing drawing = _render();
      expect(_textAt(drawing, 'RELEASE / 发行日期', _sx).sublist(2, 8),
          <Object?>[_sx, 710.0, 11.0, 'regular', 0.5, _mutedLight]);
      expect(_textAt(drawing, '2024-01-01', _sx).sublist(2, 7),
          <Object?>[_sx, 729.0, 13.0, 'regular', 0.0]);
      expect(_textAt(drawing, 'FORMAT / 收录', _sx)[3], 750.0);
      expect(_textAt(drawing, '12 TRACKS / 曲目', _sx)[3], 769.0);
    });

    test('日期为空时值是"暂无"', () {
      expect(_textAt(_render(_state(date: '')), '暂无', _sx)[3], 729.0);
    });

    test('简介：0.35 rule + 12px 起于 (sx, 818)', () {
      final CollectionDetailDrawing drawing = _render();
      expect(_hasRule(drawing, _sx, 804, _sideWidth, 0.35), isTrue);
      final List<Object?> quote = _textAt(drawing, '专辑简介', _sx);
      expect(quote.sublist(2, 7), <Object?>[_sx, 818.0, 12.0, 'regular', 0.0]);
      expect(quote[7], _mutedLight);
    });

    test('简介最多两行（818 / 840）', () {
      final CollectionDetailDrawing drawing = _render(_state(description: _repeat('述', 120)));
      final List<List<Object?>> lines = _texts(drawing)
          .where((List<Object?> text) => text[2] == _sx && (text[3] == 818.0 || text[3] == 840.0))
          .toList();
      expect(lines, hasLength(2));
      expect(_texts(drawing).any((List<Object?> text) => text[2] == _sx && text[3] == 862.0), isFalse);
    });

    test('空简介回落"暂无简介"', () {
      expect(_textAt(_render(_state(description: '')), '暂无简介', _sx)[3], 818.0);
    });

    test('canEditPlaylist 才画修改/删除：rule 858、按钮 866', () {
      final CollectionDetailDrawing drawing = _render(_state(canEditPlaylist: true));
      expect(_hasRule(drawing, _sx, 858, _sideWidth, 0.3), isTrue);

      final Map<String, Object?> rename = _hit(drawing, 'music:rename-playlist');
      expect(rename['label'], '修改名称');
      expect(_rect(rename), <double>[_sx, 866, 142, 30]);
      final List<Object?> renameText = _text(drawing, '修改名称');
      expect(renameText.sublist(2, 7), <Object?>[_sx, 871.0, 12.0, 'regular', 0.0]);
      expect(renameText[7], _inkLight);

      final Map<String, Object?> remove = _hit(drawing, 'music:delete-playlist');
      expect(remove['label'], '删除歌单');
      expect(_rect(remove), <double>[_sx + 148, 866, 148, 30]);
      expect(_text(drawing, '删除歌单')[2], _sx + 148);
    });

    test('默认不可编辑：既无命中也没有 858 的分隔线', () {
      final CollectionDetailDrawing drawing = _render();
      expect(_hasHit(drawing, 'music:rename-playlist'), isFalse);
      expect(_hasHit(drawing, 'music:delete-playlist'), isFalse);
      expect(
        _fills(drawing).any((List<Object?> fill) =>
            fill[2] == _sx &&
            fill[3] == 858.0 &&
            fill[5] == 1 &&
            (fill[1]! as List<Object?>)[3] == 0.3),
        isFalse,
      );
    });

    test('卡片不按 kind 过滤修改/删除：宿主 canEditPlaylist 是唯一判据', () {
      // MusicMutation.cpp:47-66 已内含 kind=="playlist" 等条件；
      // 卡片再判一次 kind 会把宿主判定覆盖成恒假。
      final CollectionDetailDrawing drawing = _render(_state(kind: 'album', canEditPlaylist: true));
      expect(_hasHit(drawing, 'music:rename-playlist'), isTrue);
      expect(_hasHit(drawing, 'music:delete-playlist'), isTrue);
    });
  });

  group('footer（CollectionDetailCard.cpp:246-254）', () {
    test('默认提示 12px (x, 934) + 来源右对齐 (contentRight, 931)', () {
      final CollectionDetailDrawing drawing = _render();
      final List<Object?> hint = _text(drawing, '滚轮浏览曲目 · 点击查看歌曲');
      expect(hint.sublist(2, 7), <Object?>[_x, 934.0, 12.0, 'regular', 0.0]);
      expect(hint[7], _mutedLight);

      final List<Object?> source = _text(drawing, '网易云音乐 ↗');
      expect(<Object?>[source[2], source[3], source[4]],
          <Object?>[_contentRight - 38.5, 931.0, 11.0]);
      expect(source[7], _inkLight);

      final Map<String, Object?> hit = _hit(drawing, 'music:source');
      expect(_rect(hit), <double>[_contentRight - 38.5 - 4, 925, 42.5, 23]);
    });

    test('本地/虚拟/localCollection 不画来源', () {
      for (final CollectionDetailState state in <CollectionDetailState>[
        _state(local: true),
        _state(virtual: true),
        _state(localCollection: true),
      ]) {
        final CollectionDetailDrawing drawing = _render(state);
        expect(_hasHit(drawing, 'music:source'), isFalse);
        expect(_hasText(drawing, '网易云音乐 ↗'), isFalse);
      }
    });

    test('更多按钮 150x32 在 contentRight-150，文字 12px 内缩 12', () {
      final CollectionDetailDrawing drawing = _render(_state(itemTrackCount: 20));
      final Map<String, Object?> hit = _hit(drawing, 'music:directory-more');
      expect(hit['label'], '加载更多 ↓');
      expect(_rect(hit), <double>[_contentRight - 150, 922, 150, 32]);
      final List<Object?> text = _text(drawing, '加载更多 ↓');
      expect(text.sublist(2, 7), <Object?>[_contentRight - 150 + 12, 928.0, 12.0, 'regular', 0.0]);
    });

    test('加载中时按钮文案换成"载入中…"', () {
      final CollectionDetailDrawing drawing =
          _render(_state(itemTrackCount: 20, directoryLoading: true));
      expect(_hit(drawing, 'music:directory-more')['label'], '载入中…');
    });

    test('更多可见时来源左移 170', () {
      final CollectionDetailDrawing drawing = _render(_state(itemTrackCount: 20));
      final Map<String, Object?> hit = _hit(drawing, 'music:source');
      expect(hit['x'], _contentRight - 170 - 38.5 - 4);
    });

    test('歌手"更多专辑"需要 directory 非空（NativeHudDetail.cpp:445）', () {
      final CollectionDetailDrawing withDirectory = _render(
        _state(kind: 'artist', artistAlbums: true, albumsMore: true, directory: true),
      );
      final Map<String, Object?> hit = _hit(withDirectory, 'music:artist-more');
      expect(hit['label'], '更多专辑 ↓');
      expect(_rect(hit), <double>[_contentRight - 150, 922, 150, 32]);

      final CollectionDetailDrawing withoutDirectory = _render(
        _state(kind: 'artist', artistAlbums: true, albumsMore: true),
      );
      expect(_hasHit(withoutDirectory, 'music:artist-more'), isFalse);
    });

    test('sortRequest 优先于 sortNotice 覆盖提示（NativeHudDetail.cpp:454-459）', () {
      expect(
        _hasText(_render(_state(sortRequest: true, sortNotice: '排序已完成')), '正在补齐曲目以排序…'),
        isTrue,
      );
      expect(_hasText(_render(_state(sortNotice: '排序已完成')), '排序已完成'), isTrue);
    });
  });

  group('收藏行（NativeHudDetail.cpp:416-441）', () {
    test('动作串是字面量 music:subscribe（:440），且永不出现 acct:', () {
      for (final String kind in <String>['playlist', 'album', 'artist']) {
        final CollectionDetailDrawing drawing =
            _render(_state(kind: kind, canMutateSubscribe: true));
        expect(_hit(drawing, 'music:subscribe')['action'], 'music:subscribe');
        expect(
          drawing.hits.any((Map<String, Object?> hit) =>
              (hit['action']! as String).startsWith('acct:')),
          isFalse,
        );
      }
    });

    test('歌单默认文案 ＋ 收藏歌单：rule 900、命中 904/296x40、文字 914', () {
      final CollectionDetailDrawing drawing = _render(_state(canMutateSubscribe: true));
      expect(_hasRule(drawing, _sx, 900, _sideWidth, 0.3), isTrue);
      final Map<String, Object?> hit = _hit(drawing, 'music:subscribe');
      expect(_rect(hit), <double>[_sx, 904, _sideWidth, 40]);

      final List<Object?> text = _text(drawing, '＋ 收藏歌单');
      expect(text.sublist(2, 7), <Object?>[_sx, 914.0, 14.0, 'regular', 0.0]);
      expect(text[7], _inkLight);
    });

    test('主体词随 kind 变化：专辑 / 歌手', () {
      expect(_hasText(_render(_state(kind: 'album', canMutateSubscribe: true)), '＋ 收藏专辑'), isTrue);
      expect(_hasText(_render(_state(kind: 'artist', canMutateSubscribe: true)), '＋ 收藏歌手'), isTrue);
      expect(_hasText(_render(_state(kind: 'artist', canMutateSubscribe: true)), '＋ 收藏歌单'),
          isFalse);
    });

    test('已收藏用琥珀色，文字不变', () {
      final CollectionDetailDrawing drawing =
          _render(_state(canMutateSubscribe: true, subscribed: true));
      expect(_text(drawing, '✓ 已收藏歌单')[7], _amber);
    });

    test('QQ 未知状态显示 ＋ 收藏 / 核实', () {
      final List<Object?> text =
          _text(_render(_state(provider: 'qq', canMutateSubscribe: true)), '＋ 收藏 / 核实');
      expect(text[7], _inkLight);
    });

    test('QQ 已知状态：subscribed → 琥珀勾选，not-subscribed → 普通加号', () {
      expect(
        _text(
          _render(_state(
              provider: 'qq', canMutateSubscribe: true, subscriptionState: 'subscribed')),
          '✓ 已收藏歌单',
        )[7],
        _amber,
      );
      expect(
        _text(
          _render(_state(
              provider: 'qq', canMutateSubscribe: true, subscriptionState: 'not-subscribed')),
          '＋ 收藏歌单',
        )[7],
        _inkLight,
      );
    });

    test('virtual / special / 无权限时不出现收藏行', () {
      for (final CollectionDetailState state in <CollectionDetailState>[
        _state(virtual: true, canMutateSubscribe: true),
        _state(special: true, canMutateSubscribe: true),
        _state(canMutateSubscribe: false),
      ]) {
        final CollectionDetailDrawing drawing = _render(state);
        expect(_hasHit(drawing, 'music:subscribe'), isFalse);
        expect(
          _fills(drawing).any((List<Object?> fill) => fill[2] == _sx && fill[3] == 900.0),
          isFalse,
        );
      }
    });
  });

  group('歌手"发行专辑"视图（NativeHudDetail.cpp:346-352 / 465-474）', () {
    CollectionDetailState albums({List<CollectionDetailTrack>? songs}) =>
        _state(kind: 'artist', artistAlbums: true, songs: songs ?? _songs(3));

    test('行动作换成 music:artist-album:N，stamp 用日期', () {
      final CollectionDetailDrawing drawing = _render(albums());
      final Map<String, Object?> hit = _hit(drawing, 'music:artist-album:0');
      expect(hit['label'], '曲目 01');
      // '2024-01-01' 10 字符 * 12 * 0.5 = 60 → x = 1798-60。
      expect(_textAt(drawing, '2024-01-01', _timeEdge - 60.0)[3], 452.0);
      expect(_hitsStarting(drawing, 'music:track:'), isEmpty);
    });

    test('日期为空回落"专辑"', () {
      final List<CollectionDetailTrack> songs = <CollectionDetailTrack>[
        const CollectionDetailTrack(id: 'x', title: '曲目', date: ''),
      ];
      final CollectionDetailDrawing drawing = _render(albums(songs: songs));
      // '专辑' 2 字符 * 12 * 0.5 = 12 → x = 1798-12。
      expect(_textAt(drawing, '专辑', _timeEdge - 12.0)[3], 452.0);
    });

    test('专辑视图没有播放全部，tabs 选中"发行专辑"', () {
      final CollectionDetailDrawing drawing = _render(albums());
      expect(_hasHit(drawing, 'music:play-loaded'), isFalse);
      expect(_hasText(drawing, '▶  播放全部'), isFalse);

      expect(_text(drawing, '发行专辑')[7], _inkLight);
      expect(_text(drawing, '热门歌曲')[7], _mutedLight);
      _fill(drawing, 751, 377, 42, 3, _amber);
    });

    test('专辑视图仍保留收藏行（与 albums 无关）', () {
      final CollectionDetailDrawing drawing = _render(
        _state(kind: 'artist', artistAlbums: true, canMutateSubscribe: true, songs: _songs(3)),
      );
      expect(_hasHit(drawing, 'music:subscribe'), isTrue);
    });
  });

  group('窄舞台与确定性（NativeHud.cpp:160-174，portrait 只做语义重排）', () {
    test('1200 宽：sidebar 250、back 命中宽 206、sheet 852', () {
      final CollectionDetailDrawing drawing = _render(_state(), 1200);
      final Map<String, Object?> back = _hit(drawing, 'music:directory');
      expect(_rect(back), <double>[59, 211, 206, 54]);

      // bounds = (40, 260, 1120, 696)；x = 326、width = 834 → sheet 308 / 852。
      _fill(drawing, _boundsX, 260, 1120, 696, _paperLight);
      _fill(drawing, 308, 260, 852, 696, _panelLight);

      // coverSize = min(250, 206-16) = 190；artX = 62 + (206-190)/2 = 70。
      expect(_ops(drawing, 'image').single,
          <Object?>['image', 'cover:42', 70.0, 352.0, 190.0, 190.0]);
    });

    test('同一状态两次渲染命令完全一致（页面无隐藏可变状态）', () {
      final CollectionDetailDrawing first = _render();
      final CollectionDetailDrawing second = _render();
      expect(first.commands, second.commands);
      expect(first.hits, second.hits);
      expect(first.trackOffset, second.trackOffset);
    });

    test('任何渲染都不泄漏 acct: / 远端路径类动作串', () {
      final CollectionDetailDrawing drawing = _render(_state(canMutateSubscribe: true));
      expect(_strings(drawing).where((String value) => value.contains('acct:')), isEmpty);
      expect(_strings(drawing).where((String value) => value.startsWith('/')), isEmpty);
    });
  });
}
