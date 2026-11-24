import 'package:rhine_music_database/hud/protocol/hud_hit.dart';

// HudHit has a single definition in the protocol layer. Re-exporting it keeps every
// existing `import 'chrome.dart'` call site compiling while removing the duplicate class.
export 'package:rhine_music_database/hud/protocol/hud_hit.dart' show HudHit;

/// Wire command alias: a flat JSON array appended to the sink in Qt emission order.
/// The sealed decoded model is protocol/hud_command.dart's HudCommand; this alias is
/// only the unparsed wire shape accepted by [HudSurfaceSink.op].
typedef HudWireCommand = List<Object?>;

/// Injection outlet for commands and hits. Commands are flat arrays appended in Qt emission order; never reorder or dedupe.
abstract class HudSurfaceSink {
  void op(HudWireCommand command);
  void hit(HudHit hit);
}

///  glyph/text port. Injected; this library never measures glyphs itself.
abstract class HudTextPort {
  double glyphWidth(String value, double size, [String weight = 'regular']);
  double glyphInset(String value, double size, [String weight = 'regular']);
  String fit(String value, double size, double width, [String weight = 'regular']);
  void rolling(String key, String value, double x, double y, double size, String weight, double tracking, bool numeric);
}

/// Qt NativeHud::ink() (NativeHud.cpp:10-15).
List<Object?> hudInk(bool dark) => dark
    ? <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite']
    : <Object?>[0.08, 0.085, 0.075, 1, 'calibratedRGB'];

// 品牌 / 导航 / 页脚 / 遮罩（chrome）
// 横屏 1:1 源：Qt/src/NativeHud.cpp
//   archiveMask 313-327 | brand 328-331 | brandLine 332-341 | navigationLeft 342-344
//   navigation 345-356 | footer 357-373 | control 121-124 | hit 102-109 | rule 125-129
//   fill 37-39 | text 40-43 | aligned 44-46 | roll 97-101 | op 16-18 | draw(chrome 段) 272-277
//   默认值：Qt/src/NativeHud.h:140-150 / 145 / 254-261 / 265-270
// 纯 Dart（仅 import 协议层 hud_hit.dart 并 re-export HudHit；不 import 任何 UI / 渲染框架）。
// 契约块位于本文件顶部，由本文件持有并逐字保留；其他文件只 import 复用。
// 附加说明：契约列出的 helper 中 hudText / hudAligned / hudControl / hudFill 增加了
//   可选命名参数 dark（默认 false），用于复刻 Qt ink() 对成员 dark 的依赖
//   （NativeHud.cpp:11-14）。契约规定的全部参数、位置与默认值保持不变，
//   任何按契约书写的调用都与加 dark 之前完全等价。

/// Qt NativeHud::op() (NativeHud.cpp:16-18)：命令按发射顺序 append，不重排、不去重。
void hudOp(HudSurfaceSink sink, HudWireCommand command) {
  sink.op(command);
}

/// Qt NativeHud::fill() (NativeHud.cpp:37-39)：color 为空时回落 ink()。
void hudFill(HudSurfaceSink sink, List<Object?> color, double x, double y, double width, double height,
    {bool dark = false}) {
  sink.op(<Object?>['fill', color.isEmpty ? hudInk(dark) : color, x, y, width, height]); // :38
}

/// Qt NativeHud::text() (NativeHud.cpp:40-43)：['text', value, x, y, size, weight, tracking, color]。
void hudText(HudSurfaceSink sink, String value, double x, double y, double size,
    {String weight = 'regular', double tracking = 0, List<Object?>? color, bool dark = false}) {
  // :42 Qt writes `color.isEmpty() ? ink() : color`, so an explicitly passed empty array must
  // fall back too (hudFill:58 already did; this matches archive_page's empty-list idiom).
  sink.op(<Object?>['text', value, x, y, size, weight, tracking,
      (color == null || color.isEmpty) ? hudInk(dark) : color]); // :42
}

/// Qt NativeHud::aligned() (NativeHud.cpp:44-46)：x 左移 glyph inset 后再 text()。
/// Qt aligned() has no color parameter (NativeHud.h:247-248): it always takes text()'s ink default,
/// so this helper deliberately exposes no color override either.
void hudAligned(HudSurfaceSink sink, HudTextPort text, String value, double x, double y, double size,
    {String weight = 'regular', double tracking = 0, bool dark = false}) {
  hudText(sink, value, x - text.glyphInset(value, size, weight), y, size, // :45
      weight: weight, tracking: tracking, dark: dark);
}

/// Qt NativeHud::rule() (NativeHud.cpp:125-129)：ink() 复合色，alpha(槽位 3) 换成 opacity，再 fill 1px 高。
/// 默认值与 Qt 头文件声明逐字一致：NativeHud.h:261 "void rule(double x, double y, double width,
/// double opacity = 0.4);"。因此省略 opacity 的调用与 Qt 语义相同；brandLine 显式传 0.65 与
/// NativeHud.cpp:338 的调用点一致，directory_empty / archive_page 显式传 0.4 与 NativeHud.cpp:399 /
/// NativeHud.cpp:437 的调用点一致。
void hudRule(HudSurfaceSink sink, bool dark, double x, double y, double width, [double opacity = 0.4]) {
  final List<Object?> color = hudInk(dark); // :126
  color[3] = opacity;                      // :127
  hudFill(sink, color, x, y, width, 1);    // :128
}

/// Qt NativeHud::hit() (NativeHud.cpp:102-109)：六字段 {x,y,width,height,action,label}，
/// Qt 的 label 形参默认 {} 且为 null 时回落 action（NativeHud.h:257 / NativeHud.cpp:108）。
/// 这里保留同一回落：省略 label 时写入 action，因此省略与显式传入两种调用都与 Qt 一致。
/// 只有 PlayerBar 可置 fixed:true。
void hudHitRegion(HudSurfaceSink sink, double x, double y, double width, double height, String action,
    [String? label]) {
  sink.hit(HudHit(x: x, y: y, width: width, height: height, action: action, label: label ?? action)); // :103-108（label.isNull() ? action : label）
}

/// Qt NativeHud::control() (NativeHud.cpp:121-124)：命中区 x-10 / width+20 / 高 54；
/// 文字在 x 处左对齐、y+14、20 号 demibold。
void hudControl(HudSurfaceSink sink, HudTextPort text, String label, double x, double y, double width,
    String action, {bool dark = false}) {
  sink.hit(HudHit(x: x - 10, y: y, width: width + 20, height: 54, action: action, label: label));                   // :122
  hudAligned(sink, text, label, x, y + 14, 20, weight: 'demibold', dark: dark); // :123
}

/// 通用路径命令 helper：['path', d, strokeWidth, color]
/// （Qt 对应写法 op({"path", d, strokeWidth, color})，见 NativeHud.cpp:507 / 513 / 619）。
/// chrome 的任何调用点都不使用它；提供给其他文件复用，避免各自重定义。
void hudPath(HudSurfaceSink sink, String d, double strokeWidth, List<Object?> color) {
  sink.op(<Object?>['path', d, strokeWidth, color]);
}

/// 品牌 / 导航 / 页脚 / 遮罩。横屏坐标全部为 Qt 舞台坐标（stage 高 1080）。
class HudChrome {
  HudChrome(this.sink, this.text, {this.dark = false});

  final HudSurfaceSink sink;
  final HudTextPort text;
  final bool dark;

  /// Qt 舞台高度 1080（硬证据）：Engine.cpp:847 scene.resize(width / (height / 1080), 1080)、
  /// NativeScene.h:130 double m_height = 1080；NativeHud 侧按同一舞台坐标绘制
  /// （NativeHud.cpp:310 playerBar(0, 984, width)、:324-325 clip/right-mask 高度 984）。
  static const double stageHeight = 1080.0;
  /// Qt NativeHud.cpp:318 constexpr double FadeWidth = 300;
  static const double archiveMaskFadeWidth = 300.0;
  /// Qt NativeHud.cpp:324-325 clip / right-mask 的固定高度 984。
  static const double maskClipHeight = 984.0;
  /// Qt NativeHud.cpp:343 return width - 789;
  static const double navigationRightInset = 789.0;
  /// Qt NativeHud.h:145 `int archiveMaskStrength = 50`。
  ///
  /// 本项目出厂默认改成 0（关闭）：曲库页不压暗右侧 3D 画面（用户 2026-11-19 指定）。
  static const int defaultArchiveMaskStrength = 0;

  /// Qt NativeHud::navigationLeft() (NativeHud.cpp:342-344)。
  double navigationLeft(double width) => width - navigationRightInset;

  /// Qt NativeHud::brand() (NativeHud.cpp:328-331)。
  void brand({required String libraryName, required double width}) {
    // :329 roll("music-brand", libraryName, 59, 115.425, 44, std::min(720.0, width * 0.45), "bold")
    final double rollWidth = width * 0.45 < 720.0 ? width * 0.45 : 720.0; // std::min(720.0, width * 0.45)
    final String shown = text.fit(libraryName, 44, rollWidth, 'bold');                                        // NativeHud.cpp:99
    text.rolling('music-brand', shown, 59 - text.glyphInset(shown, 44, 'bold'), 115.425, 44, 'bold', 0, false); // :100
    hudAligned(sink, text, 'RHINE LAB / MUSIC DATABASE', 59, 173, 14, weight: 'demibold', tracking: 1, dark: dark);         // :330
  }

  /// Qt NativeHud::brandLine() (NativeHud.cpp:332-341)。
  void brandLine(int index) {
    if (index == 0) {
      hudText(sink, 'RHINE LAB', 59, 115.425, 50.75, weight: 'bold', tracking: 1, dark: dark);        // :334
    } else if (index == 1) {
      hudText(sink, 'MUSIC DATABASE', 59, 169, 22, weight: 'demibold', tracking: 1.7, dark: dark);         // :336
    } else {
      hudRule(sink, dark, 59, 212, 300, 0.65);                                                          // :338
      hudText(sink, 'INDEX / COLLECTION / TRACK', 59, 228, 11, weight: 'regular', tracking: 1.2, dark: dark);          // :339
    }
  }

  /// Qt NativeHud::navigation() (NativeHud.cpp:345-356)。
  /// 发射顺序固定：discover(按 isLocal/isSiren 条件) -> search -> saved -> settings。
  void navigation({required double width, required bool isLocal, required bool isSiren, required bool updaterAvailable}) {
    final double x = navigationLeft(width) + 210;                                                          // :346
    if (isLocal) {
      hudControl(sink, text, '文件夹管理 ＋', x - 210, 118, 184, 'discover', dark: dark);              // :347-348
    } else if (!isSiren) {
      hudControl(sink, text, '发现音乐 ↗', x - 210, 118, 184, 'discover', dark: dark);            // :349-350
    }
    hudControl(sink, text, '音乐检索  /', x, 118, 184, 'search', dark: dark);                        // :352
    final String savedLabel = isLocal
        ? '本地曲库'
        : (isSiren ? '＋ 塞壬曲库' : '＋ 我的音乐');                                    // :353-354
    hudControl(sink, text, savedLabel, x + 200, 118, 184, 'saved', dark: dark);                            // :353-354
    hudControl(sink, text, updaterAvailable ? '设置 · 更新' : '设置', x + 400, 118, 120, 'settings', dark: dark); // :355
  }

  /// Qt NativeHud::footer() (NativeHud.cpp:357-373)。
  void footer({required double width, required bool isLocal, required bool isSiren, required String uid, required String provider}) {
    hudFill(sink, <Object?>[119.0 / 255, 123.0 / 255, 96.0 / 255, 1], 59, 971, 5, 5);                      // :358
    String session = isLocal ? 'LOCAL LIBRARY' : 'GUEST SESSION';                                  // :359
    if (isSiren) {
      session = 'SIREN RECORDS';                                                                       // :361
    } else if (uid.isNotEmpty) {                                                                           // :362 !uid.isEmpty()
      session = 'NETEASE SESSION';                                                                     // :363
      if (provider == 'qq') {                                                                               // :364
        session = 'QQ SESSION';                                                                        // :365
      } else if (provider == 'kugou') {                                                                     // :366
        session = 'KUGOU SESSION';                                                                     // :367
      }
    }
    // Qt 原点就是 967（NativeHud.cpp:634/636）。10pt 字的墨迹落在 y+9.7 .. y+17.4
    // （`lib/hud/text/glyph_run.dart` 的 `y + size*1.044` 口径与 Qt
    // `Qt/src/Glyphs.cpp:530-564` 逐行一致），y=967 时墨迹底 ≈ 977.4，
    // 恰好落在 y=984 的播放条顶线之上，与 `music-number`（`01`，基线 901.2、58 号，
    // 墨迹底 ≈ 962.6）也留 14.1 的缝。
    //
    // 2026-11-25 曾把这一行抬到 952（提交 03d160fea），那是把「舞台被底部安全区
    // 截短成 1069.2」的错位算到了文字头上；舞台高度恢复成 Qt 的 1080 之后
    // （`lib/basic/basic_app.dart` 的横屏分支），纵坐标必须回到 Qt 真值。
    const double footerBaselineY = 967;
    hudText(sink, session, 75, footerBaselineY, 10, weight: 'regular', tracking: 0.9, dark: dark);          // :370
    const String credit = 'POWERED BY RHINE LAB';                                                                // :371
    final double creditWidth = text.glyphWidth(credit, 10, 'demibold');                                    // :372 m_glyphs->width(...)
    hudText(sink, credit, width - 59 - creditWidth, footerBaselineY, 10, weight: 'demibold', dark: dark);   // :372
  }

  /// Qt NativeHud::archiveMask() (NativeHud.cpp:313-327)。
  /// 命令序列固定：save -> clip(0,0,width,984) -> right-mask(color,fadeStart,fadeEnd-fadeStart,width,984) -> restore。
  /// 与 Qt 一致，dark 只来自实例成员（NativeHud.h:140 / NativeHud.cpp:320），不是形参。
  void archiveMask({required double width, required int strength}) {
    if (strength == 0) {                                                                                   // :314
      return;
    }
    const double fadeWidth = archiveMaskFadeWidth;                                                          // :318 FadeWidth = 300
    final double opacity = strength / 100.0;                                                                // :319 strength / 100.
    final List<Object?> color = dark
        ? <Object?>[0.055, 0.075, 0.08, opacity]
        : <Object?>[0.9, 0.89, 0.86, opacity];                                                              // :320
    final double fadeEnd = navigationLeft(width);                                                           // :321
    final double fadeStart = fadeEnd - fadeWidth;                                                           // :322
    sink.op(<Object?>['save']);                                                                             // :323
    sink.op(<Object?>['clip', 0, 0, width, maskClipHeight]);                                                // :324
    sink.op(<Object?>['right-mask', color, fadeStart, fadeEnd - fadeStart, width, maskClipHeight]);         // :325
    sink.op(<Object?>['restore']);                                                                          // :326
  }

  /// Qt NativeHud::draw() chrome 段 (NativeHud.cpp:272-277, 275-277)：
  /// archiveMask(仅 archive 且未抑制) -> brand -> navigation -> footer。
  /// suppressMask 承载 Qt:272 的抑制条件 !(lyricsMode && !player.current.isEmpty())；调用方必须按
  /// 「歌词态 且 当前播放项非空」两条件同时成立来置位，archiveMode 对应 frame["mode"]=="archive"。
  void chromeView({
    required double width,
    required bool archiveMode,
    required bool suppressMask,
    required String libraryName,
    required bool isLocal,
    required bool isSiren,
    required String uid,
    required String provider,
    required int archiveMaskStrength,
    required bool updaterAvailable,
  }) {
    if (archiveMode && !suppressMask) {                                                                     // :272-274
      archiveMask(width: width, strength: archiveMaskStrength);
    }
    brand(libraryName: libraryName, width: width);                                                          // :275
    navigation(width: width, isLocal: isLocal, isSiren: isSiren, updaterAvailable: updaterAvailable);        // :276
    footer(width: width, isLocal: isLocal, isSiren: isSiren, uid: uid, provider: provider);                  // :277
  }
}
