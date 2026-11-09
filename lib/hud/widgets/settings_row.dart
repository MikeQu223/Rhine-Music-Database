/// Qt 设置卡片「行」层的 Flutter 移植：几何、绘制指令、命中区、展开、编辑浮层与提交结果。
///
/// 唯一权威源是 Qt Android 横屏实现（仓库根 = Rhine-Music-Database）：
/// - Qt/src/SettingsCard.cpp:9-19        几何常量
/// - Qt/src/SettingsCard.cpp:21-25        fade()（把 alpha 直接【置为】给定值）
/// - Qt/src/SettingsCard.cpp:27-30        actionFor()
/// - Qt/src/SettingsCard.cpp:32-34        rowIndex()
/// - Qt/src/SettingsCard.cpp:47-64        drawOptions()
/// - Qt/src/SettingsCard.cpp:66-94        drawChoice()
/// - Qt/src/SettingsCard.cpp:96-146       drawStepper()
/// - Qt/src/SettingsCard.cpp:148-161      drawAction()
/// - Qt/src/SettingsCard.cpp:163-175      drawTextInput()
/// - Qt/src/SettingsCard.cpp:177-186      drawLink()
/// - Qt/src/SettingsCard.cpp:188-236      drawRow()
/// - Qt/src/SettingsCard.cpp:239-292      layout()（本文件只取行级片段）
/// - Qt/src/SettingsCard.cpp:294-326      paint()（行/选项可见性）
/// - Qt/src/SettingsCard.h:11-50          RowModel / RowLayout / Model / Layout
/// - Qt/src/SettingsCard.h:69-77          Canvas 钩子
/// - Qt/src/HudScroll.h:13-26,67-86       maximum / clampOffset / clipHits
/// - Qt/src/NativeHudSettings.cpp:109-161 编辑浮层状态机
/// - Qt/src/NativeHudSettings.cpp:172-179 行配色
/// - Qt/src/NativeHudSettings.cpp:195-200 stroke 的四条填充实现
/// - Qt/src/NativeHudSettings.cpp:332-341 Storage 自定义区唯一的瞬时文案
/// - Qt/src/NativeHudSettings.cpp:382-490 applySettingValue（失败路径全为静默 no-op）
/// - Qt/src/NativeHudInput.cpp:23-26      滚轮：编辑中先取消编辑
/// - Qt/src/NativeHudController.cpp:394-402 setting-edit: 派发与前置取消
/// - Qt/src/NativeHudController.cpp:774-780 expand: 单一展开项
/// - 契约 .agents/parity-20261109/worktrees/T06/docs/flutter-migration/contracts/settings-platform.md
///
/// 边界：本文件只负责「行」。卡片级组装（七区顺序、表头绘制、滚动轨道、
/// settings_modal 视口与 modalBounds）属于 settings_modal 原子，不在这里实现。
/// 纯几何/逻辑，不依赖 Flutter；测试见 test/hud/t37/settings_row_test.dart。
///
/// 竖屏：Qt 没有竖屏设置页，这里不发明竖屏像素；响应式编排由调用方在
/// viewport/bounds 上完成，本文件的几何全部是 viewport 的函数。

import 'dart:math' as math;
import 'dart:ui' show Rect;

/// SettingKind（Qt/src/SettingsSchema.h:39-48）逐值对应。
/// Switch 与 Choice 共用 drawChoice（SettingsCard.cpp:206-212）。
enum SettingsRowKind { switchRow, choice, stepper, slider, textInput, action, link, custom }

/// BindingKind（Qt/src/SettingsSchema.h:50-59）。
enum SettingsBindingKind { preference, hudState, player, external, capability, updater, action, customSection }

/// 字体权重词表：Qt 侧只出现 regular / demibold（SettingsCard.cpp:41,43,59,102 等）。
enum SettingsFontWeight { regular, demibold }

/// Qt 侧权重字符串，便于比对与落图。
const Map<SettingsFontWeight, String> settingsFontWeightNames = <SettingsFontWeight, String>{
  SettingsFontWeight.regular: 'regular',
  SettingsFontWeight.demibold: 'demibold',
};

/// Qt 用 4 元素 JSON 数组表示颜色（0..1 浮点）。这里保持同一表示，
/// 避免经过 8bit 量化后与 Qt 像素对不上。
class SettingsRgba {
  final double r;
  final double g;
  final double b;
  final double a;

  const SettingsRgba(this.r, this.g, this.b, this.a);

  /// Qt/src/SettingsCard.cpp:21-25：fade() 直接【赋值】alpha，不是相乘。
  SettingsRgba fade(double alpha) => SettingsRgba(r, g, b, alpha);

  @override
  bool operator ==(Object other) =>
      other is SettingsRgba && other.r == r && other.g == g && other.b == b && other.a == a;

  @override
  int get hashCode => Object.hash(r, g, b, a);

  @override
  String toString() => 'SettingsRgba(' + r.toString() + ', ' + g.toString() + ', ' + b.toString() + ', ' + a.toString() + ')';
}

/// 行配色（Qt/src/NativeHudSettings.cpp:172-179）。
class SettingsPalette {
  final SettingsRgba ink;
  final SettingsRgba muted;
  final SettingsRgba faint;
  final SettingsRgba line;
  final SettingsRgba soft;
  final SettingsRgba gold;
  final SettingsRgba panel;

  const SettingsPalette({
    required this.ink,
    required this.muted,
    required this.faint,
    required this.line,
    required this.soft,
    required this.gold,
    required this.panel,
  });

  /// muted/faint/line 全部是 ink 的 fade 结果；soft/gold/panel 是固定值。
  factory SettingsPalette.fromInk(SettingsRgba ink, {required bool dark}) => SettingsPalette(
        ink: ink,
        muted: ink.fade(0.55),
        faint: ink.fade(0.12),
        line: ink.fade(0.25),
        soft: dark ? const SettingsRgba(1, 1, 1, 0.05) : const SettingsRgba(0, 0, 0, 0.04),
        gold: const SettingsRgba(0.835, 0.639, 0.282, 1),
        panel: dark ? const SettingsRgba(0.15, 0.15, 0.15, 1) : const SettingsRgba(0.929, 0.922, 0.894, 1),
      );
}

/// 一个下拉选项（RowModel::choices 的单项）。
class SettingsChoice {
  /// choice.value：既用于和 row.value.canonical 比较，也拼进命中动作。
  final String value;

  /// choice.label：下拉项显示文本与命中 label。
  final String label;

  const SettingsChoice({required this.value, required this.label});
}

/// RowModel::value（SettingsValue 的 canonical / integer 两面）。
class SettingsRowValue {
  final String canonical;
  final int integer;

  const SettingsRowValue({this.canonical = '', this.integer = 0});
}

/// RowModel + descriptor 中行绘制/命中需要的那部分（Qt/src/SettingsCard.h:11-31）。
class SettingsRowSpec {
  final String id;

  /// descriptor->kind
  final SettingsRowKind kind;

  /// descriptor->binding.kind
  final SettingsBindingKind bindingKind;

  /// descriptor->binding.action
  final String action;

  /// descriptor->binding.actionPrefix
  final String actionPrefix;

  /// descriptor->binding.preferenceKey
  final String preferenceKey;

  /// descriptor->titleEn
  final String titleEn;

  /// descriptor->titleZh
  final String titleZh;

  /// descriptor->actionLabel
  final String actionLabel;

  /// descriptor->restartHint
  final String restartHint;

  /// RowModel::label（随值解析出的控件文本；Choice/Stepper/TextInput 用它）。
  final String label;

  /// RowModel::value
  final SettingsRowValue value;

  /// RowModel::choices
  final List<SettingsChoice> choices;

  /// RowModel::numericValues
  final List<int> numericValues;

  /// RowModel::decrementValue / incrementValue（非空才注册 ± 命中）
  final String decrementValue;
  final String incrementValue;

  /// RowModel::targetValue
  final String targetValue;

  /// RowModel::enabled
  final bool enabled;

  /// RowModel::expanded
  final bool expanded;

  const SettingsRowSpec({
    required this.id,
    required this.kind,
    this.bindingKind = SettingsBindingKind.preference,
    this.action = '',
    this.actionPrefix = '',
    this.preferenceKey = '',
    this.titleEn = '',
    this.titleZh = '',
    this.actionLabel = '',
    this.restartHint = '',
    this.label = '',
    this.value = const SettingsRowValue(),
    this.choices = const <SettingsChoice>[],
    this.numericValues = const <int>[],
    this.decrementValue = '',
    this.incrementValue = '',
    this.targetValue = '',
    this.enabled = true,
    this.expanded = false,
  });

  SettingsRowSpec copyWith({
    String? id,
    SettingsRowKind? kind,
    SettingsBindingKind? bindingKind,
    String? action,
    String? actionPrefix,
    String? preferenceKey,
    String? titleEn,
    String? titleZh,
    String? actionLabel,
    String? restartHint,
    String? label,
    SettingsRowValue? value,
    List<SettingsChoice>? choices,
    List<int>? numericValues,
    String? decrementValue,
    String? incrementValue,
    String? targetValue,
    bool? enabled,
    bool? expanded,
  }) {
    return SettingsRowSpec(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      bindingKind: bindingKind ?? this.bindingKind,
      action: action ?? this.action,
      actionPrefix: actionPrefix ?? this.actionPrefix,
      preferenceKey: preferenceKey ?? this.preferenceKey,
      titleEn: titleEn ?? this.titleEn,
      titleZh: titleZh ?? this.titleZh,
      actionLabel: actionLabel ?? this.actionLabel,
      restartHint: restartHint ?? this.restartHint,
      label: label ?? this.label,
      value: value ?? this.value,
      choices: choices ?? this.choices,
      numericValues: numericValues ?? this.numericValues,
      decrementValue: decrementValue ?? this.decrementValue,
      incrementValue: incrementValue ?? this.incrementValue,
      targetValue: targetValue ?? this.targetValue,
      enabled: enabled ?? this.enabled,
      expanded: expanded ?? this.expanded,
    );
  }
}

/// 几何常量与两个纯函数（Qt/src/SettingsCard.cpp:9-34）。
///
/// 卡片级组装（layout()、表头、滚动）属于 settings_modal 原子；常量表放在这里，
/// 因为它是 SettingsCard.cpp:9-19 的唯一权威，避免两个模块各存一份数值而漂移。
class SettingsRowMetrics {
  const SettingsRowMetrics._();

  static const double headerHeight = 46;
  static const double sectionGap = 24;
  static const double rowHeight = 66;
  static const double rowStep = 76;
  static const double optionHeight = 50;
  static const double bottomPad = 28;
  static const double contentInset = 14;
  static const double controlWidth = 300;
  static const double linkGap = 16;
  static const double linkRowHeight = 50;
  static const double linkRowStep = 60;

  /// SettingsCard.cpp:32-34：1 基序号的两位零填充。
  static String rowIndex(int index) => (index + 1).toString().padLeft(2, '0');

  /// SettingsCard.cpp:27-30：actionPrefix 优先，为空才回退 binding.action。
  static String actionFor(SettingsRowSpec row) => row.actionPrefix.isEmpty ? row.action : row.actionPrefix;

  /// SettingsCard.cpp:256：Project 两列宽度。
  static double linkWidth(double width) => (width - linkGap) / 2;

  /// SettingsCard.cpp:264：Project 体高 = ((n + 1) / 2) * LinkRowStep（整数除法）。
  static double linkBodyHeight(int count) => ((count + 1) ~/ 2) * linkRowStep;

  /// SettingsCard.cpp:277：展开高度 = choices * OptionHeight + 4。
  static double optionsHeightFor(int choiceCount) => choiceCount * optionHeight + 4;

  /// Qt/src/NativeHudSettings.cpp:195-200：stroke 由四条 1px 填充模拟。
  /// 顺序与 Qt 完全一致：上边、下边、左边、右边。
  static List<Rect> strokeFillRects(Rect rect) => <Rect>[
        Rect.fromLTWH(rect.left, rect.top, rect.width, 1),
        Rect.fromLTWH(rect.left, rect.bottom - 1, rect.width, 1),
        Rect.fromLTWH(rect.left, rect.top, 1, rect.height),
        Rect.fromLTWH(rect.right - 1, rect.top, 1, rect.height),
      ];

  /// Qt/src/HudScroll.h:13-15。
  static double maximumScroll(double contentHeight, double viewportHeight) =>
      math.max(0, contentHeight - viewportHeight);

  /// Qt/src/HudScroll.h:17-19。
  static double clampScroll(double offset, double contentHeight, double viewportHeight) =>
      offset.clamp(0, maximumScroll(contentHeight, viewportHeight)).toDouble();
}

/// RowLayout（Qt/src/SettingsCard.h:33-50）：行矩形、控件矩形、展开选项矩形。
class SettingsRowLayout {
  final SettingsRowSpec row;

  /// 行整体矩形（含行号/标题区）。
  final Rect bounds;

  /// 右侧控件矩形（Choice/Stepper/Action/TextInput 用）。
  final Rect control;

  /// 展开选项矩形；未展开或禁用时是空矩形（Qt 默认 QRectF()）。
  final Rect options;

  /// 展开占位高度；0 表示不占位（Qt/src/SettingsCard.cpp:275-281）。
  final double optionsHeight;

  const SettingsRowLayout({
    required this.row,
    required this.bounds,
    required this.control,
    required this.options,
    required this.optionsHeight,
  });

  /// Qt/src/SettingsCard.cpp:300-302：paint() 把三个矩形整体上移 scroll。
  SettingsRowLayout translated(double dy) => SettingsRowLayout(
        row: row,
        bounds: bounds.translate(0, dy),
        control: control.translate(0, dy),
        options: options.translate(0, dy),
        optionsHeight: optionsHeight,
      );
}

/// 一行布局 + 光标推进量（Qt/src/SettingsCard.cpp:281 的 cursor += RowStep + optionsHeight）。
class SettingsRowPlacement {
  final SettingsRowLayout layout;
  final double nextCursor;

  const SettingsRowPlacement(this.layout, this.nextCursor);
}

/// Qt/src/SettingsCard.cpp:270-282：普通区单行的几何与光标推进。
/// left = viewport.left + ContentInset，width = viewport.width - 2 * ContentInset，
/// cursor 为该区当前纵坐标（由 settings_modal 的卡片循环维护）。
SettingsRowPlacement placeSettingsRow({
  required SettingsRowSpec row,
  required double left,
  required double width,
  required double cursor,
}) {
  final control = Rect.fromLTWH(left + width - SettingsRowMetrics.controlWidth, cursor + 9,
      SettingsRowMetrics.controlWidth, 48);
  final bool showOptions = row.expanded && row.enabled;
  final double optionsHeight =
      showOptions ? SettingsRowMetrics.optionsHeightFor(row.choices.length) : 0;
  final Rect options = showOptions
      ? Rect.fromLTWH(control.left, cursor + SettingsRowMetrics.rowHeight + 2,
          SettingsRowMetrics.controlWidth, optionsHeight)
      : Rect.zero;
  return SettingsRowPlacement(
    SettingsRowLayout(
      row: row,
      bounds: Rect.fromLTWH(left, cursor, width, SettingsRowMetrics.rowHeight),
      control: control,
      options: options,
      optionsHeight: optionsHeight,
    ),
    cursor + SettingsRowMetrics.rowStep + optionsHeight,
  );
}

/// Qt/src/SettingsCard.cpp:255-263：Project 区两列链接行。
SettingsRowLayout placeProjectLink({
  required SettingsRowSpec row,
  required int index,
  required double left,
  required double width,
  required double cursor,
}) {
  final double linkWidth = SettingsRowMetrics.linkWidth(width);
  return SettingsRowLayout(
    row: row,
    bounds: Rect.fromLTWH(left + (index % 2) * (linkWidth + SettingsRowMetrics.linkGap),
        cursor + (index ~/ 2) * SettingsRowMetrics.linkRowStep, linkWidth, SettingsRowMetrics.linkRowHeight),
    control: Rect.zero,
    options: Rect.zero,
    optionsHeight: 0,
  );
}

/// 文本截断钩子，对应 Canvas::fit（Qt/src/SettingsCard.h:73）。
///
/// 真实测量由注入的实现给出（T31 lib/hud/text/text_fitter.dart）；本模块只负责
/// 把 Qt 逐字一致的 maxWidth 传下去，因此测试断言的是参数而不是字形宽度。
typedef SettingsTextFit = String Function(String value, double size, double maxWidth, SettingsFontWeight weight);

/// 无测量直通实现：不做截断。仅用于不关心文本的调用方。
String identitySettingsTextFit(String value, double size, double maxWidth, SettingsFontWeight weight) => value;

/// SettingsCard.h:69-77 的 Canvas 钩子。
abstract class SettingsCanvas {
  void fill(double left, double top, double width, double height, SettingsRgba color);

  void stroke(Rect rect, SettingsRgba color);

  void text(String value, double left, double top, double size, SettingsFontWeight weight,
      double tracking, SettingsRgba color);

  void centered(String value, double x, double cy, double size, SettingsFontWeight weight,
      bool horizontal);

  void hit(double left, double top, double width, double height, String action, String label);

  void custom(String renderer, Rect body, double scroll);
}

/// 一条命中区（Qt 的 hit 记录：矩形 + 动作串 + 无障碍 label）。
class SettingsHitRegion {
  final Rect rect;
  final String action;
  final String label;

  const SettingsHitRegion(this.rect, this.action, this.label);

  @override
  String toString() => 'SettingsHitRegion(' + rect.toString() + ', ' + action + ', ' + label + ')';
}

/// Qt/src/HudScroll.h:67-86：命中区与可见区域求交；无重叠即丢弃，
/// 有重叠则把矩形就地裁剪成交集（半行不能压到表头/页脚上）。
///
/// [first] 与 Qt clipHits 的同名参数语义一致：索引 < first 的命中属于本帧更早
/// 的图层（例如表头/页脚），【原样保留】——既不裁剪也不丢弃；只有 >= first 的
/// 才参与求交。默认 0 表示传入的全部都是本图层命中。
List<SettingsHitRegion> clipSettingsHits(List<SettingsHitRegion> regions, Rect area, {int first = 0}) {
  final List<SettingsHitRegion> clipped = <SettingsHitRegion>[];
  for (int index = 0; index < regions.length; index++) {
    final SettingsHitRegion region = regions[index];
    if (index < first) {
      clipped.add(region);
      continue;
    }
    final double left = math.max(region.rect.left, area.left);
    final double top = math.max(region.rect.top, area.top);
    final double right = math.min(region.rect.right, area.right);
    final double bottom = math.min(region.rect.bottom, area.bottom);
    if (right - left <= 0 || bottom - top <= 0) {
      continue;
    }
    clipped.add(SettingsHitRegion(Rect.fromLTRB(left, top, right, bottom), region.action, region.label));
  }
  return clipped;
}

/// 绘制指令记录。测试用它逐条比对 Qt 的绘制调用序列。
abstract class SettingsDrawOp {
  const SettingsDrawOp();
}

class SettingsFillOp extends SettingsDrawOp {
  final double left;
  final double top;
  final double width;
  final double height;
  final SettingsRgba color;

  const SettingsFillOp(this.left, this.top, this.width, this.height, this.color);

  @override
  bool operator ==(Object other) =>
      other is SettingsFillOp &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height &&
      other.color == color;

  @override
  int get hashCode => Object.hash(left, top, width, height, color);
}

class SettingsStrokeOp extends SettingsDrawOp {
  final Rect rect;
  final SettingsRgba color;

  const SettingsStrokeOp(this.rect, this.color);

  @override
  bool operator ==(Object other) =>
      other is SettingsStrokeOp && other.rect == rect && other.color == color;

  @override
  int get hashCode => Object.hash(rect, color);
}

class SettingsTextOp extends SettingsDrawOp {
  final String value;
  final double left;
  final double top;
  final double size;
  final SettingsFontWeight weight;
  final double tracking;
  final SettingsRgba color;

  const SettingsTextOp(this.value, this.left, this.top, this.size, this.weight, this.tracking, this.color);

  @override
  bool operator ==(Object other) =>
      other is SettingsTextOp &&
      other.value == value &&
      other.left == left &&
      other.top == top &&
      other.size == size &&
      other.weight == weight &&
      other.tracking == tracking &&
      other.color == color;

  @override
  int get hashCode => Object.hash(value, left, top, size, weight, tracking, color);
}

class SettingsCenteredOp extends SettingsDrawOp {
  final String value;
  final double x;
  final double cy;
  final double size;
  final SettingsFontWeight weight;
  final bool horizontal;

  const SettingsCenteredOp(this.value, this.x, this.cy, this.size, this.weight, this.horizontal);

  @override
  bool operator ==(Object other) =>
      other is SettingsCenteredOp &&
      other.value == value &&
      other.x == x &&
      other.cy == cy &&
      other.size == size &&
      other.weight == weight &&
      other.horizontal == horizontal;

  @override
  int get hashCode => Object.hash(value, x, cy, size, weight, horizontal);
}

class SettingsCustomOp extends SettingsDrawOp {
  final String renderer;
  final Rect body;
  final double scroll;

  const SettingsCustomOp(this.renderer, this.body, this.scroll);

  @override
  bool operator ==(Object other) =>
      other is SettingsCustomOp &&
      other.renderer == renderer &&
      other.body == body &&
      other.scroll == scroll;

  @override
  int get hashCode => Object.hash(renderer, body, scroll);
}

/// 记录型 Canvas：把绘制指令与命中区按调用顺序存下来。
class SettingsRowRecorder implements SettingsCanvas {
  final List<SettingsDrawOp> ops = <SettingsDrawOp>[];
  final List<SettingsHitRegion> hits = <SettingsHitRegion>[];

  /// fit 收到的参数（value, size, maxWidth, weight），用于校验截断宽度。
  final List<List<Object>> fitCalls = <List<Object>>[];

  SettingsTextFit get fitter => (String value, double size, double maxWidth, SettingsFontWeight weight) {
        fitCalls.add(<Object>[value, size, maxWidth, weight]);
        return value;
      };

  List<SettingsFillOp> get fills => ops.whereType<SettingsFillOp>().toList();
  List<SettingsStrokeOp> get strokes => ops.whereType<SettingsStrokeOp>().toList();
  List<SettingsTextOp> get texts => ops.whereType<SettingsTextOp>().toList();
  List<SettingsCenteredOp> get centered => ops.whereType<SettingsCenteredOp>().toList();
  List<SettingsCustomOp> get customs => ops.whereType<SettingsCustomOp>().toList();

  SettingsTextOp? textAt(String value) {
    for (final SettingsTextOp op in texts) {
      if (op.value == value) {
        return op;
      }
    }
    return null;
  }

  bool hasHit(String action) => hits.any((SettingsHitRegion hit) => hit.action == action);

  SettingsHitRegion? hitAt(String action) {
    for (final SettingsHitRegion hit in hits) {
      if (hit.action == action) {
        return hit;
      }
    }
    return null;
  }

  @override
  void fill(double left, double top, double width, double height, SettingsRgba color) {
    ops.add(SettingsFillOp(left, top, width, height, color));
  }

  @override
  void stroke(Rect rect, SettingsRgba color) {
    ops.add(SettingsStrokeOp(rect, color));
  }

  @override
  void text(String value, double left, double top, double size, SettingsFontWeight weight,
      double tracking, SettingsRgba color) {
    ops.add(SettingsTextOp(value, left, top, size, weight, tracking, color));
  }

  @override
  void centered(String value, double x, double cy, double size, SettingsFontWeight weight,
      bool horizontal) {
    ops.add(SettingsCenteredOp(value, x, cy, size, weight, horizontal));
  }

  @override
  void hit(double left, double top, double width, double height, String action, String label) {
    hits.add(SettingsHitRegion(Rect.fromLTWH(left, top, width, height), action, label));
  }

  @override
  void custom(String renderer, Rect body, double scroll) {
    ops.add(SettingsCustomOp(renderer, body, scroll));
  }
}

/// Qt/src/SettingsCard.cpp:47-64：展开的下拉选项列表。
void paintSettingsOptions({
  required SettingsRowLayout layout,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  SettingsTextFit fit = identitySettingsTextFit,
}) {
  final SettingsRowSpec row = layout.row;
  final Rect options = layout.options;
  canvas.fill(options.left, options.top, options.width, options.height, palette.soft);
  canvas.stroke(options, palette.line);
  for (int index = 0; index < row.choices.length; index++) {
    final SettingsChoice choice = row.choices[index];
    final Rect rect = Rect.fromLTWH(options.left + 2,
        options.top + 2 + index * SettingsRowMetrics.optionHeight,
        options.width - 4, SettingsRowMetrics.optionHeight - 4);
    final bool active = choice.value == row.value.canonical;
    if (active) {
      canvas.fill(rect.left, rect.top, 3, rect.height, palette.gold);
    }
    canvas.text(fit(choice.label, 15, rect.width - 32, SettingsFontWeight.regular), rect.left + 14,
        rect.top + 15, 15, active ? SettingsFontWeight.demibold : SettingsFontWeight.regular, 0,
        palette.ink);
    canvas.hit(rect.left, rect.top, rect.width, rect.height,
        SettingsRowMetrics.actionFor(row) + choice.value, choice.label);
  }
}

/// Qt/src/SettingsCard.cpp:66-94：Choice/Switch 的右侧控件与命中。
///
/// desktopTitleLoopHit 对应 Qt 的 #if !defined(Q_OS_ANDROID) 分支（:82-92）：
/// Android 上【不注册】左侧标题热区，旧版「一键循环到下一个值」在触屏上
/// 会因误触改名设置且无法撤销。Android 目标必须传 false（默认值）。
void paintSettingsChoice({
  required SettingsRowLayout layout,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  SettingsTextFit fit = identitySettingsTextFit,
  bool desktopTitleLoopHit = false,
}) {
  final SettingsRowSpec row = layout.row;
  final Rect control = layout.control;
  canvas.fill(control.left, control.top, control.width, control.height, palette.soft);
  canvas.stroke(control, palette.line);
  canvas.text(fit(row.label, 15, control.width - 48, SettingsFontWeight.regular), control.left + 14,
      control.top + 15, 15, SettingsFontWeight.regular, 0,
      row.enabled ? palette.ink : palette.ink.fade(0.35));
  // NativeHudSettings.cpp:66 已把 expanded 与 enabled 与过：disabled 行永远画 ▾。
  canvas.text(row.expanded && row.enabled ? '▴' : '▾', control.right - 24, control.top + 14, 14,
      SettingsFontWeight.regular, 0, row.enabled ? palette.muted : palette.muted.fade(0.3));
  if (!row.enabled) {
    return;
  }
  canvas.hit(control.left, control.top, control.width, control.height, 'expand:' + row.id, row.titleZh);
  if (desktopTitleLoopHit && row.action.isNotEmpty) {
    final double labelLeft = layout.bounds.left + 30;
    final double labelWidth = control.left - labelLeft - 8;
    if (labelWidth > 0) {
      canvas.hit(labelLeft, layout.bounds.top + 4, labelWidth, SettingsRowMetrics.rowHeight - 8,
          row.action, row.titleZh);
    }
  }
}

/// Qt/src/SettingsCard.cpp:96-146：Stepper/Slider 的加减号、数值轨道与命中。
void paintSettingsStepper({
  required SettingsRowLayout layout,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  SettingsTextFit fit = identitySettingsTextFit,
}) {
  final SettingsRowSpec row = layout.row;
  final Rect control = layout.control;
  canvas.fill(control.left, control.top, control.width, control.height, palette.soft);
  canvas.stroke(control, palette.line);

  // 数值在减号左侧；进度条垂直居中并位于加减按钮之间。
  canvas.text(fit(row.label, 15, 96, SettingsFontWeight.demibold), control.left + 2, control.top + 15,
      15, SettingsFontWeight.demibold, 0, row.enabled ? palette.ink : palette.ink.fade(0.35));
  final Rect minus = Rect.fromLTWH(control.left + 100, control.top + 8, 32, 32);
  final Rect plus = Rect.fromLTWH(control.right - 40, control.top + 8, 32, 32);
  canvas.stroke(minus, palette.line);
  canvas.stroke(plus, palette.line);
  canvas.centered('−', minus.center.dx, minus.center.dy, 19, SettingsFontWeight.regular, true);
  canvas.centered('＋', plus.center.dx, plus.center.dy, 16, SettingsFontWeight.regular, true);

  final int count = row.numericValues.length;
  if (count > 1) {
    final Rect track = Rect.fromLTWH(minus.right + 12, control.center.dy - 2,
        plus.left - minus.right - 24, 4);
    canvas.fill(track.left, track.top, track.width, track.height, palette.faint);
    // Qt 循环里 selected 会被最后一个匹配覆盖；没有匹配时保持 0。
    int selected = 0;
    for (int index = 0; index < count; index++) {
      if (row.numericValues[index] == row.value.integer) {
        selected = index;
      }
    }
    final double fraction = count <= 1 ? 0 : selected / (count - 1);
    canvas.fill(track.left, track.top, track.width * fraction, track.height, palette.gold);
    final double knobX = track.left + track.width * fraction - 4;
    canvas.fill(knobX, track.top - 5, 8, 14, palette.ink);
    if (row.enabled) {
      final double segment = track.width / math.max(1, count);
      for (int index = 0; index < count; index++) {
        canvas.hit(track.left + index * segment, track.top - 10, segment, 24,
            SettingsRowMetrics.actionFor(row) + row.numericValues[index].toString(), row.titleZh);
      }
    }
  }
  if (row.enabled) {
    if (row.decrementValue.isNotEmpty) {
      canvas.hit(minus.left, minus.top, minus.width, minus.height,
          SettingsRowMetrics.actionFor(row) + row.decrementValue, row.titleZh);
    }
    if (row.incrementValue.isNotEmpty) {
      canvas.hit(plus.left, plus.top, plus.width, plus.height,
          SettingsRowMetrics.actionFor(row) + row.incrementValue, row.titleZh);
    }
  }
}

/// Qt/src/SettingsCard.cpp:148-161：Action 行。
void paintSettingsAction({
  required SettingsRowLayout layout,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  SettingsTextFit fit = identitySettingsTextFit,
}) {
  final SettingsRowSpec row = layout.row;
  final Rect control = layout.control;
  canvas.fill(control.left, control.top, control.width, control.height, palette.soft);
  canvas.stroke(control, palette.line);
  canvas.text(fit(row.actionLabel, 15, control.width - 48, SettingsFontWeight.regular), control.left + 14,
      control.top + 15, 15, SettingsFontWeight.regular, 0,
      row.enabled ? palette.ink : palette.ink.fade(0.35));
  canvas.text('→', control.right - 24, control.top + 14, 14, SettingsFontWeight.regular, 0,
      row.enabled ? palette.muted : palette.muted.fade(0.3));
  if (row.enabled) {
    canvas.hit(control.left, control.top, control.width, control.height, row.action, row.titleZh);
  }
}

/// Qt/src/SettingsCard.cpp:163-175：TextInput 行；命中动作是 setting-edit:<id>。
void paintSettingsTextInput({
  required SettingsRowLayout layout,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  SettingsTextFit fit = identitySettingsTextFit,
}) {
  final SettingsRowSpec row = layout.row;
  final Rect control = layout.control;
  canvas.fill(control.left, control.top, control.width, control.height, palette.soft);
  canvas.stroke(control, palette.line);
  canvas.text(fit(row.label, 15, control.width - 48, SettingsFontWeight.regular), control.left + 14,
      control.top + 15, 15, SettingsFontWeight.regular, 0,
      row.enabled ? palette.ink : palette.ink.fade(0.35));
  canvas.text('✎', control.right - 24, control.top + 14, 14, SettingsFontWeight.regular, 0,
      row.enabled ? palette.muted : palette.muted.fade(0.3));
  if (row.enabled) {
    canvas.hit(control.left, control.top, control.width, control.height, 'setting-edit:' + row.id,
        row.titleZh);
  }
}

/// Qt/src/SettingsCard.cpp:177-186：Project 区链接行。
/// 注意：全宽 bounds 命中【无条件注册】，与 enabled 无关；绘制也用 raw ink/muted。
void paintSettingsLink({
  required SettingsRowLayout layout,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  SettingsTextFit fit = identitySettingsTextFit,
}) {
  final SettingsRowSpec row = layout.row;
  final Rect rect = layout.bounds;
  canvas.fill(rect.left, rect.top, rect.width, rect.height, palette.soft);
  canvas.stroke(rect, palette.line);
  canvas.text(fit(row.actionLabel, 14, rect.width - 40, SettingsFontWeight.regular), rect.left + 12,
      rect.top + 15, 14, SettingsFontWeight.regular, 0, palette.ink);
  canvas.text('↗', rect.right - 22, rect.top + 14, 13, SettingsFontWeight.regular, 0, palette.muted);
  canvas.hit(rect.left, rect.top, rect.width, rect.height, row.action, row.actionLabel);
}

/// Qt/src/SettingsCard.cpp:188-236：整行绘制。Link 走独立分支并提前返回，
/// 因此链接行【没有】行号、没有下划线；Custom 只画 chrome，不注册控件命中。
void paintSettingsRow({
  required SettingsRowLayout layout,
  required int index,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  required Rect viewport,
  SettingsTextFit fit = identitySettingsTextFit,
  bool desktopTitleLoopHit = false,
}) {
  final SettingsRowSpec row = layout.row;
  if (row.kind == SettingsRowKind.link) {
    paintSettingsLink(layout: layout, canvas: canvas, palette: palette, fit: fit);
    return;
  }
  final Rect rect = layout.bounds;
  final SettingsRgba ink = row.enabled ? palette.ink : palette.ink.fade(0.35);
  final SettingsRgba muted = row.enabled ? palette.muted : palette.muted.fade(0.28);
  canvas.fill(rect.left, rect.bottom - 1, rect.width, 1, palette.line);
  canvas.text(SettingsRowMetrics.rowIndex(index), rect.left, rect.top + 25, 11,
      SettingsFontWeight.regular, 0.04, muted);
  canvas.text(row.titleEn, rect.left + 30, rect.top + 10, 11, SettingsFontWeight.regular, 0.08, muted);
  canvas.text(row.titleZh, rect.left + 30, rect.top + 25, 17, SettingsFontWeight.demibold, -0.01, ink);
  if (row.restartHint.isNotEmpty) {
    canvas.text(row.restartHint, rect.left + 30, rect.top + 50, 10, SettingsFontWeight.regular, 0.03,
        muted);
  }

  switch (row.kind) {
    case SettingsRowKind.switchRow:
    case SettingsRowKind.choice:
      paintSettingsChoice(
          layout: layout,
          canvas: canvas,
          palette: palette,
          fit: fit,
          desktopTitleLoopHit: desktopTitleLoopHit);
      break;
    case SettingsRowKind.stepper:
    case SettingsRowKind.slider:
      paintSettingsStepper(layout: layout, canvas: canvas, palette: palette, fit: fit);
      break;
    case SettingsRowKind.action:
      paintSettingsAction(layout: layout, canvas: canvas, palette: palette, fit: fit);
      break;
    case SettingsRowKind.textInput:
      paintSettingsTextInput(layout: layout, canvas: canvas, palette: palette, fit: fit);
      break;
    case SettingsRowKind.link:
      paintSettingsLink(layout: layout, canvas: canvas, palette: palette, fit: fit);
      break;
    case SettingsRowKind.custom:
      break;
  }

  if (row.expanded && row.enabled && layout.options.intersects(viewport)) {
    paintSettingsOptions(layout: layout, canvas: canvas, palette: palette, fit: fit);
  }
}

/// Qt/src/SettingsCard.cpp:294-326 的行级片段（:314-325）。
/// 行可见就整行画（drawRow 内部会再画一次 options）；只有「行不可见但
/// options 可见」时才单独补画 options，保证展开列表跨视口边界时不闪断。
void paintSettingsRowLayer({
  required SettingsRowLayout layout,
  required int index,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  required Rect viewport,
  SettingsTextFit fit = identitySettingsTextFit,
  bool desktopTitleLoopHit = false,
}) {
  final bool rowVisible = layout.bounds.intersects(viewport);
  final bool optionsVisible =
      layout.row.expanded && layout.options.intersects(viewport);
  if (rowVisible) {
    paintSettingsRow(
        layout: layout,
        index: index,
        canvas: canvas,
        palette: palette,
        viewport: viewport,
        fit: fit,
        desktopTitleLoopHit: desktopTitleLoopHit);
  }
  if (optionsVisible && !rowVisible) {
    paintSettingsOptions(layout: layout, canvas: canvas, palette: palette, fit: fit);
  }
}

/// 展开偏好（NativeHudController.cpp:774-780）：
/// expandedPreference 保存当前展开行 id，再点同一行就折叠（置空），
/// 点别的行直接换成那一行，因此始终最多一行展开。
String toggleExpandedPreference(String current, String key) => current == key ? '' : key;

/// RowModel::expanded 的取值来源。
bool settingsRowExpanded(String expandedPreference, String rowId) => expandedPreference == rowId;

/// 编辑浮层状态（NativeHudSettings.cpp:109-161 的 editingSettingId/Text/Rect）。
class SettingsEditState {
  /// 空串表示没有编辑中的行（Qt 用空 QString）。
  final String settingId;

  /// 编辑框文本。
  final String text;

  /// 控件矩形已按 settingsScroll 上移；默认空矩形对应 Qt 默认 QRectF()。
  final Rect rect;

  const SettingsEditState({this.settingId = '', this.text = '', this.rect = Rect.zero});

  bool get isActive => settingId.isNotEmpty;

  SettingsEditState withText(String value) => SettingsEditState(settingId: settingId, text: value, rect: rect);
}

/// commitSettingEdit 的结果：Qt 先取出 id/text 并清空状态，再写值。
class SettingsEditCommit {
  final SettingsEditState next;
  final String? id;
  final String? text;

  const SettingsEditCommit(this.next, this.id, this.text);

  /// false 表示这次提交是空提交（Qt:139-142 直接 return，不写值）。
  bool get hasValue => id != null;
}

/// NativeHudSettings.cpp:109-131：开启编辑。
///
/// 两道门都会【保持原状态不动】：descriptor 为空或 kind 不是 TextInput（:110-113）；
/// 重建 layout 后找不到 id 匹配且 enabled 的行（:119-130）。
SettingsEditState beginSettingEdit({
  required SettingsEditState state,
  required String id,
  required SettingsRowSpec? descriptor,
  required SettingsRowLayout? laidOut,
  required double scroll,
}) {
  if (descriptor == null || descriptor.kind != SettingsRowKind.textInput) {
    return state;
  }
  if (laidOut == null || laidOut.row.id != id || !laidOut.row.enabled) {
    return state;
  }
  return SettingsEditState(
    settingId: id,
    text: laidOut.row.value.canonical,
    rect: laidOut.control.translate(0, -scroll),
  );
}

/// NativeHudSettings.cpp:133-137：没有编辑中的行时忽略输入。
SettingsEditState setSettingEditText(SettingsEditState state, String text) =>
    state.isActive ? state.withText(text) : state;

/// NativeHudSettings.cpp:139-151：空提交直接返回；否则先清空状态再交出 id/text，
/// 由调用方接 applySettingValue + refreshSettingsLayout + invalidate。
SettingsEditCommit commitSettingEdit(SettingsEditState state) {
  if (!state.isActive) {
    return SettingsEditCommit(state, null, null);
  }
  return SettingsEditCommit(const SettingsEditState(), state.settingId, state.text);
}

/// NativeHudSettings.cpp:153-161：取消不写值，只清状态。
SettingsEditState cancelSettingEdit(SettingsEditState state) =>
    state.isActive ? const SettingsEditState() : state;

/// NativeHudController.cpp:394-402：只有 setting-edit: 前缀会开启编辑，
/// 其余任何动作到达时若正在编辑，先取消编辑。
bool settingsActionCancelsEdit(String currentSettingId, String action) =>
    currentSettingId.isNotEmpty && !action.startsWith('setting-edit:');

/// Qt 用 value.mid(13)：长度不足时返回空串，不抛异常。
String settingsEditIdFromAction(String action) =>
    action.length <= 13 ? '' : action.substring(13);

/// NativeHudInput.cpp:23-26：设置面板收到滚轮时，编辑中先取消编辑。
bool settingsWheelCancelsEdit(String currentSettingId) => currentSettingId.isNotEmpty;

/// applySettingValue 的可见结果分类（NativeHudSettings.cpp:382-490）。
///
/// Qt 侧【没有任何保存失败提示】：没有错误文案、没有红框、没有回滚动画，
/// 失败路径全部是静默 no-op。所以 rows 层要复刻的是「静默」，不是造一个提示条。
enum SettingsCommitOutcome {
  /// 真实写入：setPreference 或转成一次 action(...)（:395-484, :486-489）。
  applied,

  /// SettingsSchema::find 返回空（:383-386）。
  unknownDescriptor,

  /// 归一化结果与当前 canonical 相同，Qt 不写也不派发（:388-392）。
  unchanged,

  /// 既不是已知特例、binding.kind 也不是 Preference，函数末尾落空（:486-489）。
  unbound,

  /// 平台条件把整段写入编译掉了：非 Darwin 平台上的 fg（:443-448 的 #ifdef Q_OS_DARWIN）。
  platformNoop,
}

/// 一次 applySettingValue 的执行计划。
class SettingsApplyPlan {
  final SettingsCommitOutcome outcome;

  /// 非空则写宿主偏好（Qt m_host->setPreference）。
  final String? preferenceKey;

  /// 非空则再派发一次动作串（Qt action(...)）。
  final String? action;

  /// theme 分支额外更新 dark 与场景主题（:394-404）。
  final bool updatesSceneTheme;

  const SettingsApplyPlan(this.outcome, {this.preferenceKey, this.action, this.updatesSceneTheme = false});

  @override
  String toString() => 'SettingsApplyPlan(' + outcome.toString() + ', preferenceKey: ' +
      preferenceKey.toString() + ', action: ' + action.toString() + ', updatesSceneTheme: ' +
      updatesSceneTheme.toString() + ')';
}

/// 直接写偏好、不派发动作的特例（:395-409）。
const Set<String> settingsDirectPreferenceIds = <String>{'theme', 'graphics-backend'};

/// 转成一次 action(...) 的特例及其动作串构造规则（:410-484）。
/// 用 map 保存「原样动作」的那批；带目标值的单独映射。
const Map<String, String> settingsSameNameActionIds = <String, String>{
  'motion': 'motion',
  'startup-animation': 'startup-animation',
  'vsync': 'vsync',
  'detail-autoplay': 'detail-autoplay',
  'single-play-mode': 'single-play-mode',
  'close-behavior': 'close-behavior',
  'alternative': 'alternative',
};

const Map<String, String> settingsActionWithTargetPrefix = <String, String>{
  'archive-mask': 'archive-mask:',
  'render-scale': 'render-scale:',
  'aa-mode': 'aa-mode:',
  'aa-scale': 'aa-scale:',
  'msaa': 'msaa:',
  'fsr-quality': 'fsr-quality:',
  'fsr-sharpness': 'fsr-sharpness:',
  'gpu-index': 'gpu-index:',
};

/// NativeHudSettings.cpp:382-490 的移植：给定 id、目标值与当前值，
/// 算出这次提交会做什么。isDarwin 只影响 fg 一行（:443-448 的 #ifdef Q_OS_DARWIN）：
/// Windows/Linux/Android 上 fg 整段被编译掉，因此只有 Darwin 才是 applied。
SettingsApplyPlan planSettingsApply({
  required SettingsRowSpec? descriptor,
  required String target,
  required String currentCanonical,
  required bool isDarwin,
}) {
  if (descriptor == null) {
    return const SettingsApplyPlan(SettingsCommitOutcome.unknownDescriptor);
  }
  if (target == currentCanonical) {
    return const SettingsApplyPlan(SettingsCommitOutcome.unchanged);
  }
  final String id = descriptor.id;
  if (settingsDirectPreferenceIds.contains(id)) {
    return SettingsApplyPlan(SettingsCommitOutcome.applied,
        preferenceKey: id, updatesSceneTheme: id == 'theme');
  }
  if (id == 'fg') {
    // Qt 这里整段包在 #ifdef Q_OS_DARWIN 里：非 Darwin 平台点它什么都不会发生。
    if (!isDarwin) {
      return const SettingsApplyPlan(SettingsCommitOutcome.platformNoop);
    }
    return const SettingsApplyPlan(SettingsCommitOutcome.applied, preferenceKey: 'fg');
  }
  if (id == 'official-player') {
    return const SettingsApplyPlan(SettingsCommitOutcome.applied, action: 'music:activate');
  }
  if (id == 'quality') {
    return SettingsApplyPlan(SettingsCommitOutcome.applied, action: 'quality:set:' + target);
  }
  final String? sameName = settingsSameNameActionIds[id];
  if (sameName != null) {
    return SettingsApplyPlan(SettingsCommitOutcome.applied, action: sameName);
  }
  final String? prefix = settingsActionWithTargetPrefix[id];
  if (prefix != null) {
    return SettingsApplyPlan(SettingsCommitOutcome.applied, action: prefix + target);
  }
  if (descriptor.bindingKind == SettingsBindingKind.preference) {
    return SettingsApplyPlan(SettingsCommitOutcome.applied, preferenceKey: descriptor.preferenceKey);
  }
  return const SettingsApplyPlan(SettingsCommitOutcome.unbound);
}

/// NativeHudSettings.cpp:336-337：Storage 区块的按钮文案是整份 Qt 代码里
/// 唯一的瞬时反馈文案（cache:clear 成功后变成「已清除」），失败时没有任何文案。
/// 注意 actionBlock 的命中 label 固定是「清除缓存」，不随文案变化（:337）。
String storageCacheActionLabel(String cacheMessage) =>
    cacheMessage.isEmpty ? '清除缓存' : cacheMessage;

/// Storage 按钮的命中 label（Qt/src/NativeHudSettings.cpp:337）。
const String storageCacheHitLabel = '清除缓存';
