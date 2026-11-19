import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../hud/modals/lyrics_panel.dart' as lyrics;
import '../hud/pages/chrome.dart' show HudSurfaceSink, HudTextPort;
import '../hud/pages/song_detail.dart' as detail;
import '../hud/player/player_bar.dart' as player;
import '../hud/text/glyph_font.dart';
import '../hud/text/glyph_run.dart';
import '../hud/text/rolling_text.dart';
import '../hud/widgets/track_ruler.dart' as ruler;
import 'basic_cover_images.dart';

/// 字形资源：misans-glyphs.json 是 Qt 真值的字形表，boot-lettering-art.json 是
/// 启动字标资源（Resources/ 目录）。
///
/// 说明：pubspec.yaml 没有 `fonts:` 段，因此 OTF 不注册为 Flutter 字体族；
/// 这里用 [FontLoader] 从 asset 字节注册，只服务 B 计划里的复杂文字回退
/// （见 [BasicGlyphPorts.draw] 的 TextPainter 分支），主绘制仍然走 JSON 轮廓。
const String basicGlyphTableAsset = 'Assets/fonts/misans-glyphs.json';
const String basicLetteringAsset = 'Resources/boot-lettering-art.json';

const List<String> basicRhineMiSansAssets = <String>[
  'Assets/fonts/RhineMiSans-light.otf',
  'Assets/fonts/RhineMiSans-regular.otf',
  'Assets/fonts/RhineMiSans-demibold.otf',
  'Assets/fonts/RhineMiSans-bold.otf',
];

const String basicSymbolFontAsset = 'Assets/fonts/NotoSansSymbols2-Regular.ttf';
const String basicRhineMiSansFamily = 'RhineMiSans';
const String basicSymbolFamily = 'NotoSansSymbols2';

/// 资源装载结果。失败项逐条保留，禁止静默 fallback：
/// [failures] 非空时宿主必须把缺项写进可见状态（BasicApp 的装载失败页）。
class BasicHudResources {
  const BasicHudResources({
    required this.glyphs,
    required this.text,
    required this.ports,
    required this.families,
    required this.failures,
  });

  final GlyphFontSet glyphs;
  final GlyphText text;
  final BasicGlyphPorts ports;
  final List<String> families;
  final List<String> failures;

  static Future<BasicHudResources> load({
    AssetBundle? bundle,
    BasicCoverImages? covers,
  }) async {
    final AssetBundle source = bundle ?? rootBundle;
    final List<String> failures = <String>[];
    GlyphFontSet glyphs = GlyphFontSet.empty;
    try {
      final String glyphJson = await source.loadString(basicGlyphTableAsset);
      String letteringJson = '{}';
      try {
        letteringJson = await source.loadString(basicLetteringAsset);
      } on Object catch (error) {
        failures.add('lettering $basicLetteringAsset: $error');
      }
      glyphs = parseGlyphResources(
        glyphJson: glyphJson,
        letteringJson: letteringJson,
      );
    } on Object catch (error) {
      failures.add('glyphs $basicGlyphTableAsset: $error');
    }
    final List<String> families = await _registerFontFamilies(source, failures);
    final GlyphText text = GlyphText.resourceOnly(glyphs);
    return BasicHudResources(
      glyphs: glyphs,
      text: text,
      ports: BasicGlyphPorts(glyphs: glyphs, text: text, covers: covers),
      families: families,
      failures: List<String>.unmodifiable(failures),
    );
  }

  static Future<List<String>> _registerFontFamilies(
    AssetBundle bundle,
    List<String> failures,
  ) async {
    final List<String> families = <String>[];
    if (await _loadFamily(bundle, basicRhineMiSansFamily, basicRhineMiSansAssets, failures)) {
      families.add(basicRhineMiSansFamily);
    }
    if (await _loadFamily(bundle, basicSymbolFamily, <String>[basicSymbolFontAsset], failures)) {
      families.add(basicSymbolFamily);
    }
    return families;
  }

  static Future<bool> _loadFamily(
    AssetBundle bundle,
    String family,
    List<String> assets,
    List<String> failures,
  ) async {
    final FontLoader loader = FontLoader(family);
    var loaded = 0;
    for (final String asset in assets) {
      try {
        final ByteData data = await bundle.load(asset);
        loader.addFont(Future<ByteData>.value(data));
        loaded += 1;
      } on Object catch (error) {
        failures.add('font $family $asset: $error');
      }
    }
    if (loaded == 0) {
      return false;
    }
    try {
      await loader.load();
      return true;
    } on Object catch (error) {
      failures.add('font $family load: $error');
      return false;
    }
  }
}

/// [GlyphText] 的端口实现：HudTextPort（chrome/archive）、HudGlyphBoundsPort
/// （track_ruler）、player_bar 的 GlyphsPort、lyrics_panel 的 GlyphsPort、
/// song_detail 的 SongDetailGlyphsPort。
///
/// 度量真值来自 JSON 字形表（GlyphText）；JSON 覆盖不到的文字
/// （例如 U+2014 em dash 只在 OTF 里）走 TextPainter 回退：
/// 这是可见的降级，不改变坐标/字号，也不伪造 advance。
class BasicGlyphPorts
    implements
        HudTextPort,
        ruler.HudGlyphBoundsPort,
        player.GlyphsPort,
        lyrics.GlyphsPort,
        detail.SongDetailGlyphsPort {
  BasicGlyphPorts({required this.glyphs, required this.text, this.covers});

  final GlyphFontSet glyphs;
  final GlyphText text;

  /// 真实封面像素来源（null = 未接线，页面画空槽而不是假图）。
  final BasicCoverImages? covers;

  /// 记录 rolling 请求次数，便于测试断言“页面确实请求过滚动标签”。
  /// 实际绘制见 [beginFrame]/[rolling]：每次请求都按当前帧时钟落到命令流，
  /// 不再是空实现（旧实现在这里直接 return，导致标题/当前序号整段不画）。
  int rollingRequests = 0;

  /// 共享滚动文字运行时（见 lib/hud/text/rolling_text.dart）：每个 key 一份
  /// [RollingLabel]，字符槽跨帧保留。时钟/repaint 由宿主注入，本端口不自带计时器。
  late final HudRollingText rollingText = HudRollingText(
    measure: (String value, double size, String weight, double tracking) =>
        _width(value, size, weight, tracking),
  );

  List<Object?> _frameInk = const <Object?>[];
  bool _frameAnimate = true;

  /// 宿主（[BasicHudFrame.build]）在绘制本帧前绑定时钟、ink 与动画开关。
  void beginFrame({
    required HudSurfaceSink sink,
    required double time,
    required List<Object?> ink,
    bool animate = true,
  }) {
    _frameInk = ink;
    _frameAnimate = animate;
    rollingText.begin(time: time, emit: sink.op);
  }

  /// 结束本帧；true = 仍有滚动字符槽在动，宿主应继续 ticker 续帧。
  bool endFrame() => rollingText.end();

  /// 本帧绘制结束后共享滚动文字是否还在动。
  bool get rollingAnimating => rollingText.animating;

  static const double _fallbackTextScale = kBaselineFactor;

  double _width(String value, double size, String weight, double tracking) {
    if (value.isEmpty || !(size > 0)) {
      return 0;
    }
    try {
      return text.width(value, size, weight: weight, tracking: tracking);
    } on StateError {
      return _fallbackParagraph(value, size, weight, tracking).width;
    }
  }

  TextPainter _fallbackParagraph(
    String value,
    double size,
    String weight,
    double tracking,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontSize: size,
          letterSpacing: tracking,
          fontFamily: basicRhineMiSansFamily,
          fontFamilyFallback: const <String>[basicSymbolFamily],
          fontWeight: _fontWeight(weight),
        ),
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    return painter;
  }

  static FontWeight _fontWeight(String weight) {
    switch (weight) {
      case 'light':
        return FontWeight.w300;
      case 'demibold':
        return FontWeight.w600;
      case 'bold':
        return FontWeight.w700;
      default:
        return FontWeight.w400;
    }
  }

  /// HudTextPort
  @override
  double glyphWidth(String value, double size, [String weight = 'regular']) =>
      _width(value, size, weight, 0);

  /// HudTextPort
  @override
  double glyphInset(String value, double size, [String weight = 'regular']) {
    if (value.isEmpty || !(size > 0)) {
      return 0;
    }
    try {
      return text.inset(value, size, weight: weight);
    } on StateError {
      // 与 Qt Glyphs::inset 对齐（Qt/src/Glyphs.cpp:339-349）：字形表里没有轮廓时
      // Qt 回 0，而不是整段 advance。回 advance 会让调用方把整行左移一个文字宽度；
      // 真机表现就是右侧歌名只剩列表裁剪窗口里那几个像素（ 缺陷②）。
      // draw() 的 OTF 回退分支正是在 x 处起笔，所以 0 才是自洽值。
      return 0;
    }
  }

  /// HudTextPort：按真实宽度截断，尾部补省略号（与 text_fitter 同判据：
  /// 先量原文，超宽才截断）。
  @override
  String fit(String value, double size, double width, [String weight = 'regular']) {
    if (value.isEmpty || !(width > 0) || _width(value, size, weight, 0) <= width) {
      return value;
    }
    final List<int> runes = value.runes.toList(growable: false);
    for (var length = runes.length - 1; length > 0; length--) {
      final String candidate = '${String.fromCharCodes(runes.take(length))}…';
      if (_width(candidate, size, weight, 0) <= width) {
        return candidate;
      }
    }
    return '…';
  }

  /// HudTextPort：把滚动标签落到当前帧命令流（Qt NativeHud::roll）。
  ///
  /// 真机缺陷（左侧标题空白、底部只显示 "/936"）的源根因就在这里：旧实现只
  /// `rollingRequests += 1` 就返回，页面按 Qt 顺序发出的 music-brand /
  /// music-source / music-title / music-id / music-column / music-number 六类
  /// 滚动文字全部没有命令落到 HUD；静态 hudText("/") 与 total 仍照常画，于是
  /// 只剩 "/936"。现在走 [HudRollingText]：初始帧即发静态 text（可见），值变化
  /// 时按 kReelDuration 发 save/alpha/clip/text/restore，由宿主 ticker 推进。
  @override
  void rolling(
    String key,
    String value,
    double x,
    double y,
    double size,
    String weight,
    double tracking,
    bool numeric,
  ) {
    rollingRequests += 1;
    rollingText.request(
      key: key,
      value: value,
      x: x,
      y: y,
      size: size,
      weight: weight,
      tracking: tracking,
      numeric: numeric,
      ink: _frameInk,
      animate: _frameAnimate,
    );
  }

  /// HudGlyphBoundsPort（track_ruler）
  @override
  ruler.GlyphBounds glyphBounds(
    String value,
    double size, [
    String weight = 'regular',
  ]) {
    final Rect bounds = _bounds(value, size, weight);
    return ruler.GlyphBounds(
      x: bounds.left,
      y: bounds.top,
      width: bounds.width,
      height: bounds.height,
    );
  }

  Rect _bounds(String value, double size, String weight) {
    if (value.isEmpty || !(size > 0)) {
      return Rect.zero;
    }
    try {
      return text.bounds(value, size, weight: weight);
    } on StateError {
      final TextPainter painter = _fallbackParagraph(value, size, weight, 0);
      return Rect.fromLTWH(0, size * (1 - _fallbackTextScale), painter.width,
          painter.height);
    }
  }

  /// player_bar.GlyphsPort 的 width(value, size, weight)；
  /// song_detail.SongDetailGlyphsPort 另带可选 tracking（Qt Glyphs::width(..., tracking = 0)）。
  /// 一个实现同时满足两侧：调用方不传 tracking 时等价于旧的三参数版本。
  @override
  double width(String value, double size, String weight, [double tracking = 0]) =>
      _width(value, size, weight, tracking);

  /// player_bar.GlyphsPort
  @override
  player.GlyphBounds bounds(String value, double size, String weight) {
    final Rect bounds = _bounds(value, size, weight);
    return player.GlyphBounds(
      x: bounds.left,
      y: bounds.top,
      width: bounds.width,
      height: bounds.height,
    );
  }

  /// lyrics_panel / song_detail 的 wrap：按真实 advance 贪心折行。
  @override
  List<String> wrap(String value, double limit, double size, String weight) {
    if (value.isEmpty) {
      return const <String>[];
    }
    if (!(limit > 0)) {
      return <String>[value];
    }
    final List<String> lines = <String>[];
    final StringBuffer line = StringBuffer();
    for (final int rune in value.runes) {
      final String character = String.fromCharCode(rune);
      if (character == '\n') {
        lines.add(line.toString());
        line.clear();
        continue;
      }
      final String candidate = line.toString() + character;
      if (line.isNotEmpty && _width(candidate, size, weight, 0) > limit) {
        lines.add(line.toString());
        line.clear();
      }
      line.write(character);
    }
    if (line.isNotEmpty) {
      lines.add(line.toString());
    }
    return lines;
  }

  /// song_detail.SongDetailGlyphsPort（tracking 可选）
  @override
  double inset(String value, double size, String weight) => glyphInset(value, size, weight);

  /// HudPainterPorts.text 的实现。y 是 em-box 顶（HudTextDrawFn 契约），
  /// 基线在 y + size * kBaselineFactor。
  void draw(
    ui.Canvas canvas,
    String value,
    double x,
    double y,
    double size,
    String weight,
    double tracking,
    Color color,
  ) {
    if (value.isEmpty || !(size > 0)) {
      return;
    }
    final ui.Paint ink = ui.Paint()
      ..color = color
      ..isAntiAlias = true;
    try {
      text.paintText(
        canvas,
        value,
        x,
        y,
        size,
        weight: weight,
        tracking: tracking,
        ink: ink,
      );
    } on StateError {
      final TextPainter painter = _fallbackParagraph(value, size, weight, tracking)
        ..text = TextSpan(
          text: value,
          style: TextStyle(
            fontSize: size,
            letterSpacing: tracking,
            color: color,
            fontFamily: basicRhineMiSansFamily,
            fontFamilyFallback: const <String>[basicSymbolFamily],
            fontWeight: _fontWeight(weight),
          ),
        );
      painter.layout();
      painter.paint(canvas, Offset(x, y + size * (_fallbackTextScale - 1)));
      painter.dispose();
    }
  }

  /// HudPainterPorts.path：线上传输的就是 SVG 路径数据（不是路径名），
  /// 与 Qt Glyphs.cpp:728-760 一致——Qt 对 'path' / 'fill-path' 都现解析这份
  /// 字符串。解析器在 lib/hud/text/glyph_font.dart 里已是 Glyphs::path 的移植。
  /// 返回 null 会让 paint_stack 记 missingPath 并跳过绘制：真机上底栏播放键
  /// 因此只剩实心底板、没有三角与箭头（ 缺陷③）。
  ui.Path? pathFor(String key) => key.isEmpty ? null : parseSvgPath(key);

  /// HUD image 命令的像素来源：真实专辑封面（[BasicCoverImages] 按 URL 缓存）。
  /// 端口没接上时仍返回 null——页面画空槽，不画假图。
  ui.Image? imageFor(String key) => covers?.imageFor(key);
}
