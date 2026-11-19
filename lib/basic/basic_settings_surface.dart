// 设置面板的渲染与命中面（纯 Dart，命令 + 命中注入，不依赖 Flutter widget）。
// 源：Qt/src/NativeHudSettings.cpp（:163-225 面板 / :310-330 performance / :344-370 update）
//     + Qt/src/SettingsCard.cpp（:36-45 表头 / :294-327 卡片循环）
//     + Qt/src/NativeHud.cpp:80-85（centeredText）
//
// 复用（不复制）：lib/hud/modals/settings_modal.dart 的表头绘制 / 卡片布局 /
//   行绘制与命中（paintSettingsSectionHeader / layoutSettingsCard /
//   paintSettingsRowLayer / paintSettingsOptions / paintSettingsActionBlock）；
//   lib/hud/pages/chrome.dart 的 op/hit 协议 helper。
//
// 本文件【不】复用 paintSettingsCard / paintSettingsCustomSection：那两个函数按
//   Qt 区块整块分派，会把帧生成（diagnostics）、检查更新、前往更新、清除缓存、
//   恢复默认等**未授权项**一起画出来。ONLY14 只需要 performance 的第二行与
//   update 的版本行，因此在这里用自有 renderer 名单独绘制。
//
// 不做：持久化、真实生效、native 调用、路由、模态壳、
//   键盘/hit 归属、滚动状态存储、版本/平台链接注入。
library;

import 'dart:ui' show Rect;

import '../hud/modals/settings_modal.dart';
import '../hud/pages/chrome.dart';
import '../hud/widgets/settings_row.dart';
import 'basic_settings.dart';

/// 面板配色：与 Qt ink() 同一组基色（NativeHud.cpp:11-14 / chrome.dart:28）。
SettingsPalette basicSettingsPalette({required bool dark}) => SettingsPalette.fromInk(
      dark
          ? const SettingsRgba(0.92, 0.92, 0.92, 1)
          : const SettingsRgba(0.08, 0.085, 0.075, 1),
      dark: dark,
    );

/// 唱片旋转行（Qt NativeHudSettings.cpp:324-328 的 row(102, ...)）。
///
/// 只画这一行：英文小标题 DISC ROTATION / 中文标题 唱片旋转 / 右侧 300×48 控件 /
/// 行下 1px 分隔线 / 13pt 帮助文本。**不画**第一行（性能面板 / 帧生成诊断，
/// 用户未授权）。
///
/// 几何：Qt 把这一行放在 performance 区块的**第二行**（secondRowTop=102，帮助
/// 文案在 secondHelpInsetTop=176，位于两行之下）。本面板不显示第一行，若仍按
/// 102/176 落位会留下 102px 空洞且帮助文案溢出区块。因此这里把同一行放到区块
/// 首行，并沿用 Qt 的同一套子偏移与同一组文案：titleInsetTop 10 / subtitleInsetTop
/// 25 / controlInsetTop 8 / controlHeight 48 / ruleInsetTop 62 / firstHelpInsetTop 78，
/// 区块高度 100（basicSettingsDiscRotationRenderer）。除“去掉未授权第一行”外，
/// 行内偏移、文字、命中动作与 label 全部逐字保留 Qt 真值。
void paintBasicSettingsDiscRotation({
  required Rect body,
  required bool discRotation,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  SettingsTextFit fit = identitySettingsTextFit,
}) {
  const double top = SettingsPerformanceSectionMetrics.firstRowTop;
  final double rowTop = body.top + top;
  final Rect control = Rect.fromLTWH(
    body.right - SettingsRowMetrics.controlWidth,
    rowTop + SettingsPerformanceSectionMetrics.controlInsetTop,
    SettingsRowMetrics.controlWidth,
    SettingsPerformanceSectionMetrics.controlHeight,
  );
  canvas.text(
    SettingsPerformanceContent.secondTitleEn,
    body.left,
    rowTop + SettingsPerformanceSectionMetrics.titleInsetTop,
    SettingsPerformanceSectionMetrics.titleSize,
    SettingsFontWeight.regular,
    SettingsPerformanceSectionMetrics.titleTracking,
    palette.muted,
  );
  canvas.text(
    SettingsPerformanceContent.secondTitleZh,
    body.left,
    rowTop + SettingsPerformanceSectionMetrics.subtitleInsetTop,
    SettingsPerformanceSectionMetrics.subtitleSize,
    SettingsFontWeight.demibold,
    SettingsPerformanceSectionMetrics.subtitleTracking,
    palette.ink,
  );
  paintSettingsActionBlock(
    rect: control,
    label: discRotation
        ? SettingsPerformanceContent.secondLabelOn
        : SettingsPerformanceContent.secondLabelOff,
    action: SettingsPerformanceContent.secondAction,
    hitLabel: SettingsPerformanceContent.secondHitLabel,
    canvas: canvas,
    palette: palette,
    fit: fit,
  );
  canvas.fill(
    body.left,
    rowTop + SettingsPerformanceSectionMetrics.ruleInsetTop,
    body.width,
    1,
    palette.line,
  );
  canvas.text(
    SettingsPerformanceContent.secondHelp,
    body.left,
    rowTop + SettingsPerformanceSectionMetrics.firstHelpInsetTop,
    SettingsPerformanceSectionMetrics.helpSize,
    SettingsFontWeight.regular,
    0,
    palette.muted,
  );
}

/// 当前版本行（Qt NativeHudSettings.cpp:344-349 的前两行文本）。
///
/// 只画版本文本 + 非发布构建的 commit 标题；**不画**启动检查 / 检查更新 /
/// 前往更新 / 发布说明（未授权项，且本面板不触发任何更新流程）。
/// 无命中：ONLY14 里版本是只读展示。
void paintBasicSettingsVersion({
  required Rect body,
  required BasicSettingsVersion version,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
}) {
  canvas.text(
    version.label,
    body.left,
    body.top + SettingsUpdateContent.versionInsetTop,
    SettingsUpdateContent.versionSize,
    SettingsFontWeight.demibold,
    0,
    palette.ink,
  );
  final String secondary = version.secondaryLabel;
  if (secondary.isNotEmpty) {
    canvas.text(
      secondary,
      body.left,
      body.top + SettingsUpdateContent.commitInsetTop,
      SettingsUpdateContent.commitSize,
      SettingsFontWeight.regular,
      0,
      palette.muted,
    );
  }
}

/// ONLY14 设置面板的绘制适配器。
///
/// 用法（141 侧接线示意）：
/// ```dart
/// final surface = BasicSettingsSurface(
///   viewport: Rect.fromLTWH(40, 176, usableWidth, 660), // 原 HUD 设置面板视口
///   model: basicSettingsPanelModel(
///     context: context, snapshot: snapshot, version: injectedVersion,
///   ),
///   scroll: currentScroll,
///   dark: viewState.dark,
/// );
/// // 先录进 recorder，再裁剪命中，最后才落 HUD sink。
/// final recorder = SettingsRowRecorder();
/// surface.paint(recorder);
/// final hits = surface.clipHits(recorder.hits);   // 视口外的命中必须丢掉
/// for (final op in recorder.ops) { /* op -> sink.op(...) */ }
/// for (final hit in hits) { sink.hit(HudHit(...)); }
///
/// // 命中 -> 命令：
/// final BasicSettingsCommand cmd = basicSettingsCommandFor(hit.action, context: context, snapshot: snapshot);
/// switch (cmd) { /* 141 侧处理 persisted / tap / warn / openUrl / message */ }
/// ```
///
/// 注意（重要）：
/// * [clipHits] **只裁剪命中区，不裁剪绘制 op**：绘制已按 `viewport` 判断行/
///   选项是否可见，但面板外的整块画布裁剪属宿主（`clip` op）。直写
///   `HudSurfaceSink` 的实现无法回退已发出的 op，命中裁剪必须走
///   recorder -> [clipHits] -> sink 这个顺序。
/// * [BasicSettingsHudCanvas] 是给“直接落 sink 且不做命中裁剪”的宿主用的便利桥；
///   需要精确命中裁剪时走 recorder + [clipHits]。
/// * 竖向居中字形（步进器 `−` / `＋`）默认用 `insetY=0, boxHeight=size` 近似
///   Qt `NativeHud.cpp:80-85` 的 bounds 中心；宿主可给
///   [BasicSettingsHudCanvas.new] 注入 `glyphBounds` 消除亚像素差。
class BasicSettingsSurface {
  BasicSettingsSurface({
    required this.viewport,
    required this.model,
    this.scroll = 0,
    this.dark = true,
    this.titleLoopHit = false,
    this.fit = identitySettingsTextFit,
    SettingsPalette? palette,
  }) : palette = palette ?? basicSettingsPalette(dark: dark);

  /// 卡片视口（原 HUD 设置面板 body 区域，含内边距）。
  final Rect viewport;

  final BasicSettingsPanelModel model;

  /// 期望滚动偏移；绘制时统一 clamp 到 [0, maximumScroll]。
  final double scroll;

  final bool dark;

  /// 桌面端标题循环命中（Qt SettingsCard 的 desktopTitleLoopHit）：默认关闭，
  /// 由宿主按平台决定。
  final bool titleLoopHit;

  final SettingsTextFit fit;
  final SettingsPalette palette;

  SettingsCardLayout? _layout;

  /// 卡片布局（惰性计算一次；viewport/model 不变时复用）。
  SettingsCardLayout get layout =>
      _layout ??= layoutSettingsCard(viewport: viewport, model: model.sections);

  double get contentHeight => layout.contentHeight;

  double get maximumScroll => layout.maximumScroll;

  /// 实际绘制用滚动值。
  double get clampedScroll {
    final double value = scroll.isFinite ? scroll : 0;
    if (value <= 0) {
      return 0;
    }
    return value >= maximumScroll ? maximumScroll : value;
  }

  /// 绘制整张卡片：表头 / 自定义区（唱片旋转、当前版本）/ 行 / 展开的选项区 / 项目链接。
  ///
  /// 循环与可见性判定逐字复刻 SettingsCard.cpp:294-327（同 paintSettingsCard），
  /// 仅把自定义区分派换成本文件的两个 ONLY14 绘制函数。
  void paint(SettingsCanvas canvas) {
    final SettingsCardLayout card = layout;
    final double offset = clampedScroll;
    for (final SettingsSectionLayout rawSection in card.sections) {
      final SettingsSectionLayout section = rawSection.translated(-offset);
      if (section.header.overlaps(viewport)) {
        paintSettingsSectionHeader(
            section: section, canvas: canvas, palette: palette);
      }
      if (section.section.hasCustomRenderer) {
        if (section.body.overlaps(viewport)) {
          _paintCustomSection(section, canvas);
        }
        continue;
      }
      for (int index = 0; index < section.rows.length; index++) {
        final SettingsRowLayout row = section.rows[index];
        // 防御纵深：模型是公开 const 构造，宿主若塞进 Qt 的未授权行
        // （storage/update/provider/诊断…），这里一律不画也不注册命中。
        if (!basicSettingAllowsDescriptor(row.row.id)) {
          continue;
        }
        final bool rowVisible = row.bounds.overlaps(viewport);
        final bool optionsVisible = row.row.expanded && row.options.overlaps(viewport);
        if (rowVisible) {
          paintSettingsRowLayer(
            layout: row,
            index: index,
            canvas: canvas,
            palette: palette,
            viewport: viewport,
            fit: fit,
            desktopTitleLoopHit: titleLoopHit,
          );
        } else if (optionsVisible) {
          paintSettingsOptions(
              layout: row, canvas: canvas, palette: palette, fit: fit);
        }
      }
    }
  }

  void _paintCustomSection(SettingsSectionLayout section, SettingsCanvas canvas) {
    final String renderer = section.section.customRenderer;
    if (renderer == basicSettingsDiscRotationRenderer) {
      paintBasicSettingsDiscRotation(
        body: section.body,
        discRotation: model.discRotation,
        canvas: canvas,
        palette: palette,
        fit: fit,
      );
      return;
    }
    if (renderer == basicSettingsVersionRenderer) {
      paintBasicSettingsVersion(
        body: section.body,
        version: model.version,
        canvas: canvas,
        palette: palette,
      );
      return;
    }
    // 其余自定义区（provider-card / storage / update / defaults / performance）
    // 一律不画：ONLY14 里没有它们的入口。
  }

  /// 命中裁剪：与 Qt NativeHudSettings.cpp:205-210 同序（先取 first，再绘制，再裁剪）。
  List<SettingsHitRegion> clipHits(List<SettingsHitRegion> hits, {int first = 0}) =>
      clipSettingsHits(hits, viewport, first: first);
}

/// 把面板绘制命令与命中区桥接到 HUD 的 op / hit 协议（chrome.dart）。
///
/// 只做翻译，不含任何布局逻辑：
/// - fill -> `['fill', color, x, y, w, h]`（hudFill）
/// - stroke -> 四条 1px fill（协议层没有 stroke op）
/// - text -> `['text', value, x, y, size, weight, tracking, color]`（hudText）
/// - hit -> HudHit（hudHitRegion）
/// - custom -> 忽略（ONLY14 面板没有 custom renderer 命中）
class BasicSettingsHudCanvas implements SettingsCanvas {
  BasicSettingsHudCanvas({
    required this.sink,
    required HudTextPort text,
    this.dark = false,
    this.glyphBounds,
  }) : _textPort = text;

  final HudSurfaceSink sink;

  /// 宿主注入的字形度量端口（构造参数名保持 `text`，稳定给宿主用）。
  /// 存储刻意私有 `_textPort`：本类同时要覆写 `SettingsCanvas.text()`，
  /// 不把内部存储端口并入公开 API（同名成员会与方法冲突，近名成员只会让
  /// 宿主分不清该用哪个，两者都不该出现）。
  final HudTextPort _textPort;

  /// 面板明暗：只用于 Qt「未显式传色 -> ink()」的回落（centeredText，NativeHud.cpp:85）。
  final bool dark;

  /// 可选：注入字形边界以求 `centered()` 与 Qt 逐像素一致
  /// （Qt/src/NativeHud.cpp:80-85 用 bounds 的 x/y/width/height）。
  /// HudTextPort 只暴露 glyphWidth / glyphInset（x 方向），因此默认用 size 近似
  /// 垂直居中；宿主若有 bounds 能力，注入本回调即可精确对齐。
  final ({double x, double y, double width, double height})? Function(
      String value, double size, String weight)? glyphBounds;

  static List<Object?> _color(SettingsRgba color) =>
      <Object?>[color.r, color.g, color.b, color.a];

  static String _weight(SettingsFontWeight weight) =>
      settingsFontWeightNames[weight] ?? 'regular';

  @override
  void fill(double left, double top, double width, double height, SettingsRgba color) {
    hudFill(sink, _color(color), left, top, width, height);
  }

  @override
  void stroke(Rect rect, SettingsRgba color) {
    for (final Rect edge in SettingsRowMetrics.strokeFillRects(rect)) {
      hudFill(sink, _color(color), edge.left, edge.top, edge.width, edge.height);
    }
  }

  @override
  void text(String value, double left, double top, double size, SettingsFontWeight weight,
      double tracking, SettingsRgba color) {
    hudText(sink, value, left, top, size,
        weight: _weight(weight), tracking: tracking, color: _color(color));
  }

  @override
  void centered(String value, double x, double cy, double size, SettingsFontWeight weight,
      bool horizontal) {
    final String weightName = _weight(weight);
    final ({double x, double y, double width, double height})? bounds =
        glyphBounds?.call(value, size, weightName);
    final double advance = bounds?.width ?? _textPort.glyphWidth(value, size, weightName);
    final double insetX = bounds?.x ?? _textPort.glyphInset(value, size, weightName);
    final double insetY = bounds?.y ?? 0;
    final double boxHeight = bounds?.height ?? size;
    hudText(
      sink,
      value,
      x - insetX - (horizontal ? advance / 2 : 0),
      cy - insetY - boxHeight / 2,
      size,
      weight: weightName,
      color: hudInk(dark),
    );
  }

  @override
  void hit(double left, double top, double width, double height, String action, String label) {
    hudHitRegion(sink, left, top, width, height, action, label);
  }

  @override
  void custom(String renderer, Rect body, double scroll) {
    // ONLY14 面板不使用 SettingsCanvas.custom（那是 Apple Music 标记等）。
  }
}
