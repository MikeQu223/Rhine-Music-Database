// LyricsPanel：横屏歌词面板的纯数据命令 / 命中构建器与视图状态机。
//
// 语义逐条移植自 Qt/src/NativeHudDetail.cpp:217-338（NativeHud::lyricsPanel 全部
// 布局、绘制与命中），曲线取自 Qt/src/UiMotion.cpp:63-84（UiMotion::ReelCurve 的
// 49 点样条），滚轮语义见 Qt/src/NativeHudInput.cpp:122-127。
//
// 本文件不依赖 Flutter Widget / Material，也不 import lib/hud/protocol/* 或
// lib/domain/*：歌词加载、解析、网络与缓存属领域，本文件只消费注入的
// document（lines[].startMs/text/translation + plainText）与已算好的 index。
//
// 边界：lyrics_offset / lyrics_source 两个弹层属 （Qt/src/NativeHudModal.cpp:85-161），
// 本文件不创建、不绘制它们；面板只暴露 player:lyrics-offset / player:lyrics-sources
// 两条动作，由宿主转给弹层。
//
// 命令是 Qt 的 flat JSON 形态：同代发布、不排序、不去重、不合并。

import 'dart:math' as math;

/// 面板动作接收器：宿主注入后，面板把「歌词来源 / 歌词偏移」按钮的 action 串
/// 原样转出（Qt NativeHudController.cpp:324-345 把这两串分派到  弹层）。
/// 面板不解释动作、不打开弹层、不写状态。
typedef LyricsActionSink = void Function(String action);

// ── 校准常量（Qt/src/NativeHudDetail.cpp:229-230、253、304） ────────────────

/// 歌词正文视口上沿（Qt constexpr top = 360）。
const double lyricsPanelTop = 360.0;

/// 歌词正文视口下沿（Qt constexpr bottom = 889）。
const double lyricsPanelBottom = 889.0;

/// 当前句基准线（Qt constexpr focusY = top + 155 = 515）。
const double lyricsPanelFocusY = 515.0;

/// 正文行号（Qt constexpr size = 34）。
const double lyricsPanelBodySize = 34.0;

/// 正文行距（NativeHudDetail.cpp:272、312、321）。
const double lyricsPanelLineHeight = 47.0;

/// 译文行距（NativeHudDetail.cpp:272、312、325）。
const double lyricsPanelTranslationHeight = 26.0;

/// 行间留白（NativeHudDetail.cpp:272 的 +32）。
const double lyricsPanelRowGap = 32.0;

/// 纯文本窗口行数（NativeHudDetail.cpp:243-244 的 9）。
const int lyricsPanelPlainWindow = 9;

/// 顶部限宽内缩（NativeHudDetail.cpp:223-224 的 width - 85）。
const double lyricsPanelHeaderInset = 85.0;

/// 换行左右内缩（NativeHudDetail.cpp:242、265、269 的 width - 24）。
const double lyricsPanelWrapInset = 24.0;

/// 正文裁剪行高（NativeHudDetail.cpp:313-319 的 55）。
const double lyricsPanelEdgeSpan = 55.0;

/// 非当前句的透明度（NativeHudDetail.cpp:319 的 0.28）。
const double lyricsPanelIdleAlpha = 0.28;

/// 译文相对正文的透明度（NativeHudDetail.cpp:323 的 0.65）。
const double lyricsPanelTranslationAlpha = 0.65;

/// muted 透明度（NativeHudDetail.cpp:221-222；注意是赋值 0.45 而非乘）。
const double lyricsPanelMutedAlpha = 0.45;

/// 跟随时长（NativeHudDetail.cpp:301：browse ? 0.18 : 0.42）。
const double lyricsPanelFollowDuration = 0.42;

/// 浏览时长（NativeHudDetail.cpp:301：browse ? 0.18 : 0.42）。
const double lyricsPanelBrowseDuration = 0.18;

/// 空文本占位（NativeHudDetail.cpp:262-264）。
const String lyricsPanelEmptyLine = '•••';

/// 无歌词时的默认文案（NativeHudDetail.cpp:238-240）。
const String lyricsPanelPlaceholder = '播放歌曲后显示歌词';

/// 歌词视口上下沿（Qt NativeHudDetail.cpp:229-230 的 constexpr）。
///
/// 默认值即校准值；宿主如需整体缩放舞台，必须传入同一对常量，不得自创数值。
class LyricsPanelBounds {
  const LyricsPanelBounds(this.top, this.bottom);

  /// 校准真值 top=360 / bottom=889。
  static const LyricsPanelBounds calibrated = LyricsPanelBounds(lyricsPanelTop, lyricsPanelBottom);

  final double top;
  final double bottom;

  @override
  bool operator ==(Object other) =>
      other is LyricsPanelBounds && other.top == top && other.bottom == bottom;

  @override
  int get hashCode => Object.hash(top, bottom);

  @override
  String toString() => 'LyricsPanelBounds(' + top.toString() + ', ' + bottom.toString() + ')';
}

/// 字形度量端口（Qt Glyphs::width 与 Glyphs::wrap 的只读两面）。
///
/// wrap 的 weight 一律显式传：Qt 的默认实参是 "regular"，显式化避免两侧默认值漂移。
abstract class GlyphsPort {
  /// 文本排版宽度（Qt Glyphs::width(value, size, weight)）。
  double width(String value, double size, String weight);

  /// 按 limit 贪心换行（Qt Glyphs::wrap(value, limit, size, weight)）。
  List<String> wrap(String value, double limit, double size, String weight);
}

// ── 排版 ───────────────────────────────────────────────────────────────────

/// 一行歌词的排版结果（Qt NativeHud::LyricRow，NativeHud.h:163-167）。
class LyricsPanelRow {
  const LyricsPanelRow({
    required this.top,
    required this.text,
    required this.translation,
  });

  /// 该行相对布局原点的纵向偏移（Qt LyricRow::top）。
  final double top;

  /// 正文按 width-24、34、"bold" 换行后的行（空文本用 [lyricsPanelEmptyLine]）。
  final List<String> text;

  /// 译文按 width-24、17、"regular" 换行后的行；无译文时为空。
  final List<String> translation;

  /// 绘制高度（不含 +32 行距）：text*47 + translation*26（NativeHudDetail.cpp:312）。
  double get height => text.length * lyricsPanelLineHeight + translation.length * lyricsPanelTranslationHeight;
}

/// 整份文档的排班（Qt m_lyricsLayout + 触发重排的缓存键）。
class LyricsPanelLayout {
  const LyricsPanelLayout({
    required this.rows,
    required this.width,
    required this.signature,
    required this.totalHeight,
  });

  final List<LyricsPanelRow> rows;

  /// 生成该布局时的 width（Qt m_lyricsWidth）。
  final double width;

  /// 生成该布局时的文档签名（Qt m_lyricsDocument 的深比较等价物）。
  final String signature;

  /// 累计高度（最后一行 top + 该行步进）。
  final double totalHeight;

  /// 缓存命中判定：document 深等价且 width 相同（NativeHudDetail.cpp:254）。
  bool matches(Map<String, Object?> document, double width) =>
      this.width == width && signature == lyricsDocumentSignature(document);
}

/// 按 Qt 规则为整份文档排版（NativeHudDetail.cpp:257-273）。
///
/// 纯函数：同 document / width / glyphs 输入必得值等价的布局；缓存由调用方通过
/// [LyricsPanelModel.layout] 回填，本函数不做任何隐藏状态。
LyricsPanelLayout buildLyricsLayout(
  Map<String, Object?> document,
  double width,
  GlyphsPort glyphs,
) {
  final List<Map<String, Object?>> lines = lyricLines(document);
  final List<LyricsPanelRow> rows = <LyricsPanelRow>[];
  final double limit = width - lyricsPanelWrapInset;
  double height = 0;
  for (final Map<String, Object?> line in lines) {
    String original = stringOf(line['text']);
    if (original.isEmpty) {
      original = lyricsPanelEmptyLine;
    }
    final List<String> wrapped = glyphs.wrap(original, limit, lyricsPanelBodySize, 'bold');
    final String translation = stringOf(line['translation']);
    final List<String> translated =
        translation.isEmpty ? const <String>[] : glyphs.wrap(translation, limit, 17.0, 'regular');
    rows.add(LyricsPanelRow(top: height, text: wrapped, translation: translated));
    height += (wrapped.isEmpty ? 1 : wrapped.length) * lyricsPanelLineHeight +
        translated.length * lyricsPanelTranslationHeight +
        lyricsPanelRowGap;
  }
  return LyricsPanelLayout(
    rows: rows,
    width: width,
    signature: lyricsDocumentSignature(document),
    totalHeight: height,
  );
}

/// 取出 document["lines"] 的对象列表；形状非法时按空处理（[LyricsController::validDocument] 已挡过一遍）。
List<Map<String, Object?>> lyricLines(Map<String, Object?> document) {
  final Object? raw = document['lines'];
  if (raw is! List) {
    return const <Map<String, Object?>>[];
  }
  final List<Map<String, Object?>> lines = <Map<String, Object?>>[];
  for (final Object? value in raw) {
    final Map<String, Object?> line = <String, Object?>{};
    if (value is Map) {
      value.forEach((Object? key, Object? item) {
        if (key is String) {
          line[key] = item;
        }
      });
    }
    lines.add(line);
  }
  return lines;
}

/// 文档的规范化签名：键序无关、数值按 QJsonValue 语义（1000 == 1000.0）归一。
///
/// QJsonObject::operator== 是深比较且对象内部按键排序，这里用等价的可比较字符串
/// 复刻同一语义，避免把「同一个 Map 实例被就地修改」误判成命中缓存。
String lyricsDocumentSignature(Object? value) {
  final StringBuffer buffer = StringBuffer();
  _writeSignature(buffer, value);
  return buffer.toString();
}

void _writeSignature(StringBuffer out, Object? value) {
  if (value == null) {
    out.write('n');
    return;
  }
  if (value is bool) {
    out.write(value ? 't' : 'f');
    return;
  }
  if (value is num) {
    // QJsonValue 只存 double：1000 与 1000.0 相等，这里同样归一。
    if (value.isFinite && value == value.truncateToDouble() && value.abs() < 1e15) {
      out.write('i');
      out.write(value.toInt().toString());
    } else {
      out.write('d');
      out.write(value.toString());
    }
    return;
  }
  if (value is String) {
    out.write('s');
    out.write(value.length.toString());
    out.write(':');
    out.write(value);
    return;
  }
  if (value is List) {
    out.write('[');
    out.write(value.length.toString());
    out.write(':');
    for (final Object? item in value) {
      _writeSignature(out, item);
    }
    out.write(']');
    return;
  }
  if (value is Map) {
    final List<String> keys = <String>[];
    final Map<String, Object?> byKey = <String, Object?>{};
    value.forEach((Object? key, Object? item) {
      final String name = key.toString();
      keys.add(name);
      byKey[name] = item;
    });
    keys.sort();
    out.write('{');
    out.write(keys.length.toString());
    out.write(':');
    for (final String key in keys) {
      out.write(key.length.toString());
      out.write(':');
      out.write(key);
      _writeSignature(out, byKey[key]);
    }
    out.write('}');
    return;
  }
  out.write('u');
  out.write(value.runtimeType.toString());
  out.write(value.toString());
}

// ── 时间轴端口与样条（Qt/src/UiMotion.cpp:63-84） ──────────────────────────

/// 49 点缓动样条（Qt UiMotion::ReelCurve）。
///
/// 位置公式：points[i] = target + (displacement + (impulse + 10*displacement) * t) * exp(-10t)，
/// i == 48 硬落 target；sample 在最后一段做线性插值并给出每秒速度。
/// 与 Qt 一致，duration 必须 > 0（面板只用 0.18/0.42）；<= 0 时退化为定点，避免除零。
class ReelCurve {
  ReelCurve({
    required this.from,
    required this.target,
    required this.velocity,
    required this.start,
    required this.duration,
  }) : points = _reelPoints(from, target, velocity, duration);

  /// 起始位置。
  final double from;

  /// 目标位置。
  final double target;

  /// 打断时接续的初速（Qt 传入上一段 sample 的速度）。
  final double velocity;

  /// 起始时间（秒）。
  final double start;

  /// 时长（秒）。
  final double duration;

  /// 49 个采样点（Qt m_points）。
  final List<double> points;
}

List<double> _reelPoints(double from, double target, double velocity, double duration) {
  final List<double> points = List<double>.filled(49, target);
  if (duration <= 0) {
    return points;
  }
  final double displacement = from - target;
  final double cap = (math.max(displacement.abs(), 1.0) * 12) / duration;
  final double impulse = _clamp(velocity, -cap, cap) * duration;
  for (int index = 0; index <= 48; index++) {
    final double t = index / 48.0;
    points[index] = index == 48
        ? target
        : target + (displacement + (impulse + 10 * displacement) * t) * math.exp(-10 * t);
  }
  return points;
}

/// 时间轴端口：曲线的构造与采样（供测试注入确定性的假实现）。
abstract class LyricsMotionPort {
  /// 构造一段曲线。
  ReelCurve curve({
    required double from,
    required double target,
    required double velocity,
    required double start,
    required double duration,
  });

  /// 采样，返回 [位置, 速度]（Qt ReelCurve::sample）。
  List<double> sample(ReelCurve curve, double time);
}

/// 默认实现：逐行复刻 Qt UiMotion::ReelCurve，不依赖任何动画框架或计时器。
class ReelMotion implements LyricsMotionPort {
  const ReelMotion();

  @override
  ReelCurve curve({
    required double from,
    required double target,
    required double velocity,
    required double start,
    required double duration,
  }) =>
      ReelCurve(
        from: from,
        target: target,
        velocity: velocity,
        start: start,
        duration: duration,
      );

  @override
  List<double> sample(ReelCurve curve, double time) {
    if (curve.duration <= 0) {
      return <double>[curve.target, 0.0];
    }
    final double position = _clamp((time - curve.start) / curve.duration, 0.0, 1.0) * 48;
    if (position >= 48) {
      return <double>[curve.points[48], 0.0];
    }
    final int index = position.floor();
    return <double>[
      curve.points[index] + (curve.points[index + 1] - curve.points[index]) * (position - index),
      ((curve.points[index + 1] - curve.points[index]) * 48) / curve.duration,
    ];
  }
}

/// 跟随状态（Qt m_lyricsScroll / m_lyricsTarget / m_lyricsCurve 三者的一份快照）。
class LyricsFollowState {
  const LyricsFollowState({
    this.scroll = 0,
    this.velocity = 0,
    this.target,
    this.curve,
  });

  /// 本帧绘制使用的滚动位置（Qt m_lyricsScroll）。
  final double scroll;

  /// 本帧采样到的速度（Qt sample[1]；只读诊断，不参与绘制）。
  final double velocity;

  /// 当前目标（Qt m_lyricsTarget；null 表示尚未确定）。
  final double? target;

  /// 进行中的曲线（Qt m_lyricsCurve；null 表示已收敛）。
  final ReelCurve? curve;
}

/// 推进一帧滚动状态（NativeHudDetail.cpp:291-303 的逐行等价）。
///
/// 纯函数：不读时钟、不持有状态，输入相同必得相同输出。顺序与 Qt 一致——
/// 先按当前曲线采样，再在 target 变化时重设曲线（reduced 则直接落位）。
LyricsFollowState followStep({
  required double prevScroll,
  required double target,
  required bool browse,
  required bool reduced,
  required double frameTime,
  double? prevTarget,
  ReelCurve? curve,
  LyricsMotionPort motion = const ReelMotion(),
}) {
  final List<double> sample =
      curve != null ? motion.sample(curve, frameTime) : <double>[prevScroll, 0.0];
  double scroll = sample[0];
  ReelCurve? nextCurve = curve;
  double? nextTarget = prevTarget;
  if (prevTarget == null || target != prevTarget) {
    nextTarget = target;
    if (reduced) {
      scroll = target;
      nextCurve = null;
    } else {
      nextCurve = motion.curve(
        from: sample[0],
        target: target,
        velocity: sample[1],
        start: frameTime,
        duration: browse ? lyricsPanelBrowseDuration : lyricsPanelFollowDuration,
      );
    }
  }
  return LyricsFollowState(
    scroll: scroll,
    velocity: sample[1],
    target: nextTarget,
    curve: nextCurve,
  );
}

// ── 输入模型 ───────────────────────────────────────────────────────────────

/// 一帧的面板输入：领域快照（document/index/status/…）+ 视图状态（browse/scroll/curve/…）。
///
/// 领域字段由宿主从播放快照原样填入；视图字段由宿主用上一帧
/// [LyricsPanelDrawing.view] 回填。面板不自己算 activeLineIndex（领域语义不在本层）。
class LyricsPanelModel {
  const LyricsPanelModel({
    this.x = 0,
    this.width = 0,
    this.title = '',
    this.artist = '',
    this.document = const <String, Object?>{},
    this.index = -1,
    this.status = 'idle',
    this.message = '',
    this.offsetMs = 0,
    this.globalOffsetMs = 0,
    this.seekable = false,
    this.localSource = 'auto',
    this.provider = '',
    this.isLocal = false,
    this.dark = false,
    this.bounds = LyricsPanelBounds.calibrated,
    this.browse,
    this.lastIndex = -1,
    this.lineUpdates = 0,
    this.plainOffset = 0,
    this.prevScroll = 0,
    this.prevTarget,
    this.curve,
    this.layout,
    this.reducedMotion = false,
    this.frameTime = 0,
  });

  /// 面板左沿（Qt lyricsPanel(x, width) 的 x；详情页取舞台宽 * 0.56）。
  final double x;

  /// 面板可用宽（Qt 的 width；详情页取 舞台宽 - x - 59）。
  final double width;

  /// 当前曲目标题（limited 20 demibold）。
  final String title;

  /// 当前曲目艺人（limited 13 regular）。
  final String artist;

  /// 注入的歌词文档：lines[{startMs,text,translation}] + plainText。
  final Map<String, Object?> document;

  /// 领域已算好的当前行下标（-1 表示尚未开始）。
  final int index;

  /// LyricsController::status：idle/loading/ready/plain/empty/error。
  final String status;

  /// LyricsController::message（无歌词时的回退文案）。
  final String message;

  /// 偏移毫秒。面板绘制不消费它（Qt lyricsPanel 不读 offsetMs）；随模型带入，
  /// 供宿主把同一份快照交给  的 lyrics-offset 弹层，避免二次读取。
  final double offsetMs;

  /// 全局偏移毫秒（LyricsController::globalOffsetMs，LyricsController.cpp:60-64）。
  /// 面板绘制不消费它；随模型带入，供 lyrics-offset 弹层判定「全局应用」是否
  /// 已经是当前全局值（NativeHudModal.cpp:110-116）。
  final double globalOffsetMs;

  /// player.state.seekable：只有可跳转时才发歌词行命中。
  final bool seekable;

  /// LyricsController::localSource（自动/本地/各提供商）。
  final String localSource;

  /// 曲目 provider；与 [isLocal] 同时成立才画「歌词来源 ⌃」。
  final String provider;

  /// music.isLocal()。
  final bool isLocal;

  /// 深色主题（决定 ink 校准色）。
  final bool dark;

  /// 视口上下沿，默认校准值。
  final LyricsPanelBounds bounds;

  /// 浏览位置（Qt m_lyricsBrowse；null 表示跟随当前句）。
  final double? browse;

  /// 上一次参与比对的 index（Qt m_lyricsLastIndex）。
  final int lastIndex;

  /// 连续换行计数（Qt m_lyricsLineUpdates）。
  final int lineUpdates;

  /// 纯文本滚动偏移（Qt m_lyricsPlainOffset）。
  final int plainOffset;

  /// 上一帧滚动位置（Qt m_lyricsScroll）。
  final double prevScroll;

  /// 上一帧目标（Qt m_lyricsTarget）。
  final double? prevTarget;

  /// 上一帧曲线（Qt m_lyricsCurve）。
  final ReelCurve? curve;

  /// 上一帧缓存布局（Qt m_lyricsLayout + m_lyricsDocument/m_lyricsWidth）。
  final LyricsPanelLayout? layout;

  /// 系统「减少动态效果」。
  final bool reducedMotion;

  /// 本帧时间（秒；Qt lastTime）。
  final double frameTime;

  /// 便捷拷贝：未传的字段保持原值（清空可空字段请直接构造新模型）。
  LyricsPanelModel copyWith({
    double? x,
    double? width,
    String? title,
    String? artist,
    Map<String, Object?>? document,
    int? index,
    String? status,
    String? message,
    double? offsetMs,
    double? globalOffsetMs,
    bool? seekable,
    String? localSource,
    String? provider,
    bool? isLocal,
    bool? dark,
    LyricsPanelBounds? bounds,
    double? browse,
    int? lastIndex,
    int? lineUpdates,
    int? plainOffset,
    double? prevScroll,
    double? prevTarget,
    ReelCurve? curve,
    LyricsPanelLayout? layout,
    bool? reducedMotion,
    double? frameTime,
  }) =>
      LyricsPanelModel(
        x: x ?? this.x,
        width: width ?? this.width,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        document: document ?? this.document,
        index: index ?? this.index,
        status: status ?? this.status,
        message: message ?? this.message,
        offsetMs: offsetMs ?? this.offsetMs,
        globalOffsetMs: globalOffsetMs ?? this.globalOffsetMs,
        seekable: seekable ?? this.seekable,
        localSource: localSource ?? this.localSource,
        provider: provider ?? this.provider,
        isLocal: isLocal ?? this.isLocal,
        dark: dark ?? this.dark,
        bounds: bounds ?? this.bounds,
        browse: browse ?? this.browse,
        lastIndex: lastIndex ?? this.lastIndex,
        lineUpdates: lineUpdates ?? this.lineUpdates,
        plainOffset: plainOffset ?? this.plainOffset,
        prevScroll: prevScroll ?? this.prevScroll,
        prevTarget: prevTarget ?? this.prevTarget,
        curve: curve ?? this.curve,
        layout: layout ?? this.layout,
        reducedMotion: reducedMotion ?? this.reducedMotion,
        frameTime: frameTime ?? this.frameTime,
      );
}

/// 一帧的视图状态（排版缓存、浏览位、跟随曲线、纯文本窗口）。
class LyricsPanelView {
  const LyricsPanelView({
    required this.hasLines,
    required this.lines,
    required this.layout,
    required this.layoutRebuilt,
    required this.browse,
    required this.lastIndex,
    required this.lineUpdates,
    required this.plainOffset,
    required this.plainRows,
    required this.plainSize,
    required this.plainMessage,
    required this.follow,
    required this.active,
    required this.activeStartMs,
  });

  /// 是否有时间轴歌词行（false = 纯文本/占位分支）。
  final bool hasLines;

  /// 注入的 lines（绘制 hit 文案与 startMs 比对时复用，避免二次解析）。
  final List<Map<String, Object?>> lines;

  /// 有效布局（缓存命中时与入参同一实例）。
  final LyricsPanelLayout? layout;

  /// 本帧是否重排（Qt 的 document/width 变化分支）。
  final bool layoutRebuilt;

  /// 浏览位置（重排或每两行重置后为 null）。
  final double? browse;

  /// 推进后的 lastIndex。
  final int lastIndex;

  /// 推进后的 lineUpdates。
  final int lineUpdates;

  /// 推进后的 plainOffset。
  final int plainOffset;

  /// 纯文本换行结果（仅无歌词行分支使用）。
  final List<String> plainRows;

  /// 纯文本字号（plain 空 24，否则 27）。
  final double plainSize;

  /// 纯文本最终文案（plain → message → 默认）。
  final String plainMessage;

  /// 推进后的跟随状态。
  final LyricsFollowState follow;

  /// active = clamp(index, 0, rows-1)；无歌词行时为 -1。
  final int active;

  /// 当前行 startMs 的原始注入值（index < 0 时为 null）。
  ///
  /// Qt NativeHudDetail.cpp:305 取 lines.at(active)["startMs"]，再到 317 用 QJsonValue
  /// 深比较（数值归一：1000 == 1000.0；缺失键彼此相等）。这里保留原始值直接比较，
  /// 语义与 Qt 相同。注入契约 LyricsController.cpp:96 保证 startMs 是有限 double，
  /// 因此正常输入下只有 startMs 等于当前行的行才判 active。
  final Object? activeStartMs;
}

/// 一帧的绘制产物。
class LyricsPanelDrawing {
  LyricsPanelDrawing({
    required this.commands,
    required this.hits,
    required this.view,
  });

  /// flat 命令数组，顺序即 Qt append 顺序。
  final List<List<Object?>> commands;

  /// 命中表；每条六字段 x/y/width/height/action/label，本面板不输出 fixed。
  final List<Map<String, Object?>> hits;

  /// 本帧推进后的视图状态；宿主必须回填进下一帧模型，否则滚动/浏览会丢帧。
  final LyricsPanelView view;
}

// ── 滚轮输入（Qt/src/NativeHudInput.cpp:122-127） ─────────────────────────

/// 布局最后一行 top（Qt NativeHudInput.cpp:123 的
/// “m_lyricsLayout.isEmpty() ? 0 : m_lyricsLayout.constLast().top”）。
double lyricsLastTop(LyricsPanelLayout? layout) {
  if (layout == null || layout.rows.isEmpty) {
    return 0.0;
  }
  return layout.rows[layout.rows.length - 1].top;
}

/// 一次滚轮的落点与增量（Qt NativeHudInput.cpp:122-127 的入参汇总）。
///
/// 面板不持有输入设备：宿主把帧里的指针位置、wheel 的 distance/delta/step 与上一帧
/// 视图状态原样填入，产物再由宿主回填进下一帧模型的
/// [LyricsPanelModel.browse] / [LyricsPanelModel.plainOffset]。这里只读不算领域。
class LyricsWheelInput {
  const LyricsWheelInput({
    required this.pointerX,
    required this.pointerY,
    required this.width,
    required this.scroll,
    required this.browse,
    required this.plainOffset,
    required this.lastTop,
    this.distance,
    this.delta = 0,
    this.step = 0,
    this.kind = 'song',
    this.lyricsMode = true,
    this.bounds = LyricsPanelBounds.calibrated,
  });

  /// 指针 x（Qt 的 x）。
  final double pointerX;

  /// 指针 y（Qt 的 y）。
  final double pointerY;

  /// 整帧宽（Qt 的 width；详情页歌词区左沿 = width * 0.56，NativeHudDetail.cpp:56）。
  final double width;

  /// 本帧滚动位置（Qt m_lyricsScroll）。
  final double scroll;

  /// 当前浏览位置（Qt m_lyricsBrowse 的 optional）。
  final double? browse;

  /// 纯文本窗口偏移（Qt m_lyricsPlainOffset）。
  final int plainOffset;

  /// 最后一行 top（Qt m_lyricsLayout.constLast().top；空布局为 0）。
  final double lastTop;

  /// 平滑帧给出的显式距离（Qt distance；null 表示只给 delta）。
  final double? distance;

  /// 像素增量（Qt delta）。
  final double delta;

  /// 语义步进（Qt step；只作用于纯文本窗口）。
  final int step;

  /// 当前曲目 kind；只有 song 参与歌词滚轮（NativeHudInput.cpp:122）。
  final String kind;

  /// 是否处于歌词模式（Qt lyricsMode）。
  final bool lyricsMode;

  /// 歌词区上下沿，默认校准值（NativeHudDetail.cpp:229-230 的 constexpr）。
  final LyricsPanelBounds bounds;

  /// Qt NativeHudInput.cpp:122 的落点判定：
  /// lyricsMode && kind == "song" && x >= width * 0.56 && y ∈ [top, bottom)。
  bool get insideLyrics =>
      lyricsMode &&
      kind == 'song' &&
      pointerX >= width * 0.56 &&
      pointerY >= bounds.top &&
      pointerY < bounds.bottom;
}

/// 滚轮结果（宿主回填下一帧）。
class LyricsWheelResult {
  const LyricsWheelResult({
    required this.handled,
    required this.browse,
    required this.plainOffset,
  });

  /// 落点是否落在歌词区；false 时两个字段原样返回。
  final bool handled;

  /// 新的浏览位置（Qt m_lyricsBrowse）。
  final double? browse;

  /// 新的纯文本偏移（Qt m_lyricsPlainOffset）。
  final int plainOffset;
}

/// 应用一次滚轮（Qt/src/NativeHudInput.cpp:122-127 的逐行等价）。
///
/// movement = distance ?? (-delta / 120) * 65；
/// browse   = clamp(browse ?? scroll + movement, 0.0, lastTop)；
/// plainOffset = max(0, plainOffset + step)。
/// 落点不在歌词区时两者都不动（Qt 直接 return）。
LyricsWheelResult applyLyricsWheel(LyricsWheelInput event) {
  if (!event.insideLyrics) {
    return LyricsWheelResult(
      handled: false,
      browse: event.browse,
      plainOffset: event.plainOffset,
    );
  }
  final double movement = event.distance ?? (-event.delta / 120) * 65;
  final double base = event.browse ?? event.scroll;
  return LyricsWheelResult(
    handled: true,
    browse: _clamp(base + movement, 0.0, event.lastTop),
    plainOffset: _maxInt(0, event.plainOffset + event.step),
  );
}

// ── 绘制 ───────────────────────────────────────────────────────────────────

/// 单帧累加器（Qt NativeHud 的 op/hit/text/button/limited 子集）。
class _Painter {
  _Painter(this.glyphs, this.dark, {this.onAction});

  final GlyphsPort glyphs;
  final bool dark;

  /// 宿主 sink：只由 [actionButton] 调用，默认 null 时行为与旧版完全一致。
  final LyricsActionSink? onAction;

  final List<List<Object?>> commands = <List<Object?>>[];
  final List<Map<String, Object?>> hits = <Map<String, Object?>>[];

  /// Qt ink()：深色 calibratedWhite / 浅色 calibratedRGB（NativeHud.cpp:10-15）。
  List<Object?> get ink => dark
      ? <Object?>[0.92, 0.92, 0.92, 1.0, 'calibratedWhite']
      : <Object?>[0.08, 0.085, 0.075, 1.0, 'calibratedRGB'];

  /// muted 是直接赋 alpha 0.45，不是乘（NativeHudDetail.cpp:221-222）。
  List<Object?> get muted => _withAlpha(ink, lyricsPanelMutedAlpha);

  void save() {
    commands.add(<Object?>['save']);
  }

  void restore() {
    commands.add(<Object?>['restore']);
  }

  void clip(double x, double y, double width, double height) {
    commands.add(<Object?>['clip', x, y, width, height]);
  }

  /// Qt NativeHud.cpp:40-43 的 tracking 是整数字面量 0；与同代 player_bar.dart:303
  /// 保持同一 JSON 形态（0 而非 0.0），故这里用 num 承接调用点的字面量。
  void text(String value, double x, double y, double size, String weight, num tracking, List<Object?> color) {
    commands.add(<Object?>['text', value, x, y, size, weight, tracking, color]);
  }

  /// 命中表条目：六字段，不带 fixed（NativeHud.cpp:102-109）。
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

  /// 省略号截断（NativeHud.cpp:48-76 的 fit）：二分到放得下的最长前缀，再 chop(1)+「…」。
  ///
  /// 注意 Qt 不在二分里预留省略号宽度，这里保持一致（逐字移植，不改观感）。
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
      final int keep = length - 1 < 0 ? 0 : length - 1;
      return value.substring(0, keep) + '…';
    }
    return value;
  }

  /// limited（NativeHud.cpp:77-79）：fit 后按原字号单行绘制。
  void limited(String value, double x, double y, double size, double width, String weight) {
    text(fit(value, size, width, weight), x, y, size, weight, 0, ink);
  }

  /// button（NativeHud.cpp:110-120）：lyricsPanel 在 modalDraw 之外，m_modalControls
  /// 恒为 false，因此没有底色、没有内缩、文字不被 fit。
  void button(String label, double x, double y, double width, double height, String action, double size) {
    hit(x, y, width, height, action, label);
    text(label, x, y + (height - size) / 2 - 4, size, 'regular', 0, ink);
  }

  /// 绘制与 [button] 完全一致，随后把同一条 action 串交给宿主 sink。
  /// 只用于会打开  弹层的「歌词来源 / 歌词偏移」两键，其余命中不转出。
  void actionButton(String label, double x, double y, double width, double height, String action, double size) {
    button(label, x, y, width, height, action, size);
    onAction?.call(action);
  }
}

List<Object?> _withAlpha(List<Object?> color, double alpha) =>
    <Object?>[color[0], color[1], color[2], alpha, color[4]];

/// 计算一帧视图状态（不含命令），便于宿主或测试单独观察状态推进。
LyricsPanelView resolveLyricsView(
  LyricsPanelModel model,
  GlyphsPort glyphs, {
  LyricsMotionPort motion = const ReelMotion(),
}) {
  final List<Map<String, Object?>> lines = lyricLines(model.document);
  if (lines.isEmpty) {
    // NativeHudDetail.cpp:233-252：纯文本/占位分支不改动滚动与布局状态。
    final String plain = stringOf(model.document['plainText']);
    String message = plain.isNotEmpty ? plain : model.message;
    if (message.isEmpty) {
      message = lyricsPanelPlaceholder;
    }
    final double size = plain.isEmpty ? 24.0 : 27.0;
    final List<String> rows = glyphs.wrap(message, model.width - lyricsPanelWrapInset, size, 'regular');
    final int offset =
        _minInt(model.plainOffset, _maxInt(0, rows.length - lyricsPanelPlainWindow));
    return LyricsPanelView(
      hasLines: false,
      lines: const <Map<String, Object?>>[],
      layout: model.layout,
      layoutRebuilt: false,
      browse: model.browse,
      lastIndex: model.lastIndex,
      lineUpdates: model.lineUpdates,
      plainOffset: offset,
      plainRows: rows,
      plainSize: size,
      plainMessage: message,
      follow: LyricsFollowState(
        scroll: model.prevScroll,
        velocity: 0,
        target: model.prevTarget,
        curve: model.curve,
      ),
      active: -1,
      activeStartMs: null,
    );
  }
  final LyricsPanelLayout? cached = model.layout;
  double? browse = model.browse;
  int lastIndex = model.lastIndex;
  int lineUpdates = model.lineUpdates;
  int plainOffset = model.plainOffset;
  double? prevTarget = model.prevTarget;
  ReelCurve? curve = model.curve;
  double scroll = model.prevScroll;
  bool rebuilt = false;
  final LyricsPanelLayout layout;
  if (cached == null || !cached.matches(model.document, model.width)) {
    // NativeHudDetail.cpp:254-281：重排并整体复位跟随状态。
    layout = buildLyricsLayout(model.document, model.width, glyphs);
    rebuilt = true;
    browse = null;
    lastIndex = model.index;
    lineUpdates = 0;
    plainOffset = 0;
    prevTarget = null;
    curve = null;
    scroll = layout.rows[_clampInt(model.index, 0, layout.rows.length - 1)].top;
  } else {
    layout = cached;
  }
  // NativeHudDetail.cpp:282-289：每更新两行歌词重置歌词位置。
  if (model.index != lastIndex) {
    lastIndex = model.index;
    if (model.index >= 0) {
      lineUpdates += 1;
      if (lineUpdates >= 2) {
        lineUpdates = 0;
        browse = null;
      }
    }
  }
  final int active = _clampInt(model.index, 0, layout.rows.length - 1);
  final double target = browse ?? layout.rows[active].top;
  final LyricsFollowState follow = followStep(
    prevScroll: scroll,
    target: target,
    browse: browse != null,
    reduced: model.reducedMotion,
    frameTime: model.frameTime,
    prevTarget: prevTarget,
    curve: curve,
    motion: motion,
  );
  return LyricsPanelView(
    hasLines: true,
    lines: lines,
    layout: layout,
    layoutRebuilt: rebuilt,
    browse: browse,
    lastIndex: lastIndex,
    lineUpdates: lineUpdates,
    plainOffset: plainOffset,
    plainRows: const <String>[],
    plainSize: 0,
    plainMessage: '',
    follow: follow,
    active: active,
    activeStartMs: model.index >= 0 ? lines[active]['startMs'] : null,
  );
}

/// 绘制整块歌词面板（NativeHudDetail.cpp:217-338）。
///
/// 顺序即 Qt 的 append 顺序：顶部标题/艺人/关闭 →［来源］→ 正文（含行命中）→
/// 底部［歌词偏移］［回到当前句］。无歌词行时正文换成纯文本窗口 +［重新查找歌词］。
LyricsPanelDrawing paintLyricsPanel(
  LyricsPanelModel model,
  GlyphsPort glyphs, {
  LyricsMotionPort motion = const ReelMotion(),
  LyricsActionSink? onAction,
}) {
  final LyricsPanelView view = resolveLyricsView(model, glyphs, motion: motion);
  final _Painter painter = _Painter(glyphs, model.dark, onAction: onAction);
  final double x = model.x;
  final double width = model.width;
  final double top = model.bounds.top;
  final double bottom = model.bounds.bottom;

  painter.limited(model.title, x, 278, 20, width - lyricsPanelHeaderInset, 'demibold');
  painter.limited(model.artist, x, 310, 13, width - lyricsPanelHeaderInset, 'regular');
  painter.button('关闭', x + width - 60, 278, 60, 40, 'player:lyrics-close', 14);
  if (model.isLocal && model.provider == 'local') {
    painter.actionButton('歌词来源 ⌃', x + 156, 914, 120, 32, 'player:lyrics-sources', 13);
  }

  if (!view.hasLines) {
    painter.save();
    painter.clip(x, top, width, bottom - top);
    final List<String> rows = view.plainRows;
    final int offset = view.plainOffset;
    final int count = _minInt(lyricsPanelPlainWindow, rows.length - offset);
    for (int index = 0; index < count; index++) {
      painter.text(rows[offset + index], x, top + 55 + index * 48, view.plainSize, 'bold', 0, painter.muted);
    }
    painter.restore();
    if (model.status == 'error' || model.status == 'empty') {
      painter.button('重新查找歌词 ↗', x, 909, 170, 36, 'player:lyrics-retry', 14);
    }
    return LyricsPanelDrawing(commands: painter.commands, hits: painter.hits, view: view);
  }

  final LyricsPanelLayout layout = view.layout!;
  final List<Map<String, Object?>> lines = view.lines;
  final double scroll = view.follow.scroll;
  final Object? activeStartMs = view.activeStartMs;
  final List<Object?> ink = painter.ink;
  painter.save();
  // 正文裁剪左右各外扩（NativeHudDetail.cpp:307）。
  painter.clip(x - 4, top, width + 8, bottom - top);
  for (int index = 0; index < lines.length; index++) {
    final LyricsPanelRow row = layout.rows[index];
    final double y = lyricsPanelFocusY + row.top - scroll;
    final double height = row.height;
    if (y + height < top || y > bottom) {
      continue;
    }
    final bool isActive = model.index >= 0 && _sameStart(lines[index]['startMs'], activeStartMs);
    final double edge = _clamp(
      math.min((y + height - top) / lyricsPanelEdgeSpan, (bottom - y) / lyricsPanelEdgeSpan),
      0,
      1,
    );
    final double alpha = (isActive ? 1.0 : lyricsPanelIdleAlpha) * edge;
    for (int rowIndex = 0; rowIndex < row.text.length; rowIndex++) {
      painter.text(
        row.text[rowIndex],
        x,
        y + rowIndex * lyricsPanelLineHeight,
        lyricsPanelBodySize,
        'bold',
        0,
        _withAlpha(ink, alpha),
      );
    }
    final double translationAlpha = alpha * lyricsPanelTranslationAlpha;
    for (int rowIndex = 0; rowIndex < row.translation.length; rowIndex++) {
      painter.text(
        row.translation[rowIndex],
        x,
        y + row.text.length * lyricsPanelLineHeight + rowIndex * lyricsPanelTranslationHeight,
        17,
        'regular',
        0,
        _withAlpha(ink, translationAlpha),
      );
    }
    if (model.seekable) {
      final double hitY = math.max(top, y);
      final String label = stringOf(lines[index]['text']);
      painter.hit(
        x,
        hitY,
        width,
        math.max(0.0, math.min(bottom, y + height + 20) - hitY),
        'player:lyric-line:' + index.toString(),
        label.isEmpty ? '间奏' : label,
      );
    }
  }
  painter.restore();
  painter.actionButton('歌词偏移 ⌃', x, 914, 144, 32, 'player:lyrics-offset', 13);
  painter.button('回到当前句', x + width - 125, 914, 125, 32, 'player:lyrics-follow', 13);
  return LyricsPanelDrawing(commands: painter.commands, hits: painter.hits, view: view);
}

// ── 小工具（std::clamp / QJsonValue::toString 等价物） ─────────────────────

String stringOf(Object? value) => value is String ? value : '';

/// Qt 的 QJsonValue 深比较（NativeHudDetail.cpp:317）：数值归一，缺失键彼此相等。
bool _sameStart(Object? lineStart, Object? activeStart) => lineStart == activeStart;

double _clamp(double value, double low, double high) {
  if (value < low) {
    return low;
  }
  if (value > high) {
    return high;
  }
  return value;
}

int _clampInt(int value, int low, int high) {
  if (value < low) {
    return low;
  }
  if (value > high) {
    return high;
  }
  return value;
}

int _minInt(int a, int b) => a < b ? a : b;

int _maxInt(int a, int b) => a > b ? a : b;
