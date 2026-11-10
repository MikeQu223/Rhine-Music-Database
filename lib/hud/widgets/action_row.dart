/// T34-S01-M12-W3 —— 动作行（三列按钮行）的纯数据构建器。
///
/// 真值来源（逐行对照 /home/aibeto/code/Rhine-Music-Database/Qt/src，行号即证据）：
/// - SongDetailCard.cpp:17-46    actions()：gap=12、height=44、width=(model.width-gap*2)/3、
///                               route 为空整格跳过、primaryRow && index==0 用前景实心填充、
///                               否则四条 1px 边框（alpha 0.2）、hit(...)、text(label,x+12,y+12,14,...)
/// - SongDetailCard.cpp:69-70    两行的唯一调用点：primaryActions@476 primaryRow=true、
///                               secondaryActions@532 primaryRow=false
/// - SongDetailCard.cpp:7-9      卡片自己的 ink()：四元色，不带 calibrated 标记
/// - SongDetailCard.cpp:23/56    卡片反相色（实心格文字色、编号块底色）
/// - NativeHudDetail.cpp:56-62   x=width*0.56、usable=width-x-59、gap=12、buttonWidth=(usable-gap*2)/3
/// - NativeHudDetail.cpp:142-148 调用方先对标签做 fit(label, 14, buttonWidth-24, weight)
/// - NativeHudDetail.cpp:203-213 封面动作行：官方客户端/试听片段/从歌单移除 三列（y=910,h=44,size=13）
/// - NativeHud.cpp:10-15         HUD ink()：四元色 + calibrated 标记（深色是 calibratedWhite）
/// - NativeHud.cpp:16-18         op()：命令是扁平 QJsonArray，追加进 commands
/// - NativeHud.cpp:37-43         fill/text 命令的字段顺序
/// - NativeHud.cpp:48-76         fit()：二分求最长可容纳前缀，截断取 left(length-1) + 省略号
/// - NativeHud.cpp:102-108       hit()：六字段 x/y/width/height/action/label，label 为 null 时回退 action
/// - NativeHud.cpp:110-120       button()：hit +（模态时 fill + fit 文本），文本 y=(height-size)/2-4
/// - NativeHud.cpp:125-129       rule()：ink 的 alpha 换成 opacity 后画 1px 横线
///
/// 契诺（与宿主约定，勿单方面改动）：
/// 1. 纯 Dart：不 import Flutter、dart:ui，也不 import 本仓其它 HUD 文件；本文件零 import、自足。
/// 2. 状态只从显式传入的不可变模型进入；测量只走注入的 GlyphsPort，本文件无全局可变状态。
/// 3. 顶层函数一律返回 Drawing：commands 是 Qt 扁平命令数组，hits 是六字段命中。
///    顺序即语义：append-only、不排序、不去重、不合并。
/// 4. 命中永远不含 fixed —— fixed 只属于 PlayerBar（Qt/src/PlayerBar.cpp:46-53）。
/// 5. 几何全部是 Qt stage 单位（1920 基准宽），不做任何 DPR/逻辑像素换算。
/// 6. 两种 ink 不可混用：卡片行用 cardInk（四元色，SongDetailCard.cpp:7-9），
///    HUD 级助手用 hudInk（五元色 + calibrated 标记，NativeHud.cpp:10-15）。
library;

/// 一条 Qt 绘制命令：QJsonArray（NativeHud::op，Qt/src/NativeHud.cpp:16-18）。
typedef HudFlatCommand = List<Object?>;

/// 一条 Qt 命中：六字段 x/y/width/height/action/label（NativeHud::hit，Qt/src/NativeHud.cpp:102-108）。
typedef HudFlatHit = Map<String, Object?>;

/// 一帧的绘制结果：命令与命中分两条通道回到宿主，宿主按同代规则整帧追加。
class Drawing {
  const Drawing({
    this.commands = const <Object?>[],
    this.hits = const <HudFlatHit>[],
  });

  /// Qt flat JSON 命令数组（NativeHud.cpp:16-18）。
  final List<Object?> commands;

  /// Qt 命中数组（NativeHud.cpp:102-108），顺序即语义。
  final List<HudFlatHit> hits;

  bool get isEmpty => commands.isEmpty && hits.isEmpty;

  static const Drawing empty = Drawing();
}

/// 追加式构造器；只暴露 op/hit/add，避免任何排序或去重的可能。
class DrawingBuilder {
  final List<Object?> _commands = <Object?>[];
  final List<HudFlatHit> _hits = <HudFlatHit>[];

  /// Qt NativeHud::op（NativeHud.cpp:16-18）。
  void op(HudFlatCommand command) {
    _commands.add(command);
  }

  /// 按 Qt NativeHud::hit 的字段与顺序登记命中（NativeHud.cpp:102-108）。
  void hit({
    required double x,
    required double y,
    required double width,
    required double height,
    required String action,
    String? label,
  }) {
    _hits.add(hitRecord(
      x: x,
      y: y,
      width: width,
      height: height,
      action: action,
      label: label,
    ));
  }

  /// 顺序拼接另一份结果：命令在前、命中在后，但不做任何重排。
  void add(Drawing drawing) {
    _commands.addAll(drawing.commands);
    _hits.addAll(drawing.hits);
  }

  Drawing build() => Drawing(
        commands: List<Object?>.unmodifiable(_commands),
        hits: List<HudFlatHit>.unmodifiable(_hits),
      );
}

/// 字形端口：对应 Qt Glyphs::width(value, size, weight)（NativeHud.cpp:57-68）。
///
/// 只要求“同参同值”的纯测量：同一字符串在同样 size/weight 下多次测量结果必须一致，
/// 且宽度随前缀增长单调不减 —— fit() 的二分依赖后一条。
abstract interface class GlyphsPort {
  double width(String value, double size, String weight);
}

/// Qt NativeHud::fit 的逐行移植（NativeHud.cpp:48-76）。
///
/// 算法：value 整体放得下时原样返回；否则在 1..length 上二分出最长可容纳前缀长度
/// length（Qt 用 low=1、middle=(low+high+1)/2、value.left(middle)），
/// 截断时取 left(length-1) + 省略号 —— 丢一个字符给省略号，且
/// length 是 UTF-16 code unit 数（QString::left 与 Dart substring 语义一致，
/// 因此代理对可能被切开，这是 Qt 的真实行为）。长度小于 2 时不会出现省略号。
String fitGlyphText(
  String value,
  double size,
  double width,
  String weight,
  GlyphsPort glyphs,
) {
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
    return value.substring(0, keep) + '\u2026';
  }
  return value;
}

/// 卡片 ink：四元色，无 calibrated 标记（SongDetailCard.cpp:7-9）。
List<Object?> cardInk(bool dark) => dark
    ? const <Object?>[0.92, 0.93, 0.88, 1]
    : const <Object?>[0.133, 0.165, 0.145, 1];

/// 卡片反相色（SongDetailCard.cpp:23 primary 文字色、:56 编号块底色）。
List<Object?> cardInverse(bool dark) => dark
    ? const <Object?>[0.12, 0.15, 0.13, 1]
    : const <Object?>[0.973, 0.969, 0.933, 1];

/// HUD ink：四元色 + calibrated 标记（NativeHud.cpp:10-15）。
///
/// 深色是 calibratedWhite、浅色是 calibratedRGB —— Qt 逐字如此，消费端统一做
/// Gamma 1.8 -> sRGB 解码。与 cardInk 不可互换。
List<Object?> hudInk(bool dark) => dark
    ? const <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite']
    : const <Object?>[0.08, 0.085, 0.075, 1, 'calibratedRGB'];

/// 复制后替换 alpha：Qt 的 auto color = ink(); color[3] = opacity;
/// （SongDetailCard.cpp:12-13、:34-35，NativeHud.cpp:126-127）不会改到调色板本身。
List<Object?> withAlpha(List<Object?> color, double alpha) {
  final List<Object?> out = List<Object?>.of(color);
  out[3] = alpha;
  return out;
}

/// Qt NativeHud::fill 的命令形状：["fill", color, x, y, width, height]（NativeHud.cpp:37-39）。
HudFlatCommand fillCommand(double x, double y, double width, double height, List<Object?> color) =>
    <Object?>['fill', color, x, y, width, height];

/// Qt NativeHud::text 的命令形状：["text", value, x, y, size, weight, tracking, color]
/// （NativeHud.cpp:40-43）。卡片画布的 text 端口固定 tracking=0（NativeHudDetail.cpp:153-155）。
HudFlatCommand textCommand(
  String value,
  double x,
  double y,
  double size,
  String weight,
  double tracking,
  List<Object?> color,
) =>
    <Object?>['text', value, x, y, size, weight, tracking, color];

/// Qt NativeHud::hit 的一条记录（NativeHud.cpp:102-108）。
///
/// 键序固定 x/y/width/height/action/label；label 为 null 才回退到 action，
/// 空字符串保持空字符串（Qt 判的是 isNull()，不是 isEmpty()）。
HudFlatHit hitRecord({
  required double x,
  required double y,
  required double width,
  required double height,
  required String action,
  String? label,
}) =>
    <String, Object?>{
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'action': action,
      'label': label ?? action,
    };

/// Qt NativeHud::rule 的命令：ink 的 alpha 换成 opacity，然后画 1px 横线（NativeHud.cpp:125-129）。
HudFlatCommand hudRuleCommand(double x, double y, double width, double opacity, bool dark) =>
    fillCommand(x, y, width, 1, withAlpha(hudInk(dark), opacity));

/// 列间距（SongDetailCard.cpp:19 constexpr double gap = 12）。
const double kActionRowGap = 12;

/// 行高（SongDetailCard.cpp:20 constexpr double height = 44）。
const double kActionRowHeight = 44;

/// 文字左边距（SongDetailCard.cpp:44 x + 12）。
const double kActionRowTextInsetX = 12;

/// 文字上边距（SongDetailCard.cpp:44 y + 12）。
const double kActionRowTextInsetY = 12;

/// 文字字号（SongDetailCard.cpp:44 的 14）。
const double kActionRowFontSize = 14;

/// 非实心格四条边框的 alpha（SongDetailCard.cpp:35 border[3] = 0.2）。
const double kActionRowBorderAlpha = 0.2;

/// 实心格（primary）文字字重（SongDetailCard.cpp:44 primary ? demibold : ...）。
const String kActionRowPrimaryWeight = 'demibold';

/// 描边格文字字重（SongDetailCard.cpp:44）。
const String kActionRowSecondaryWeight = 'regular';

/// 第一行（实心）在卡片里的 y（SongDetailCard.cpp:69 actions(..., 476, true)）。
const double kSongDetailPrimaryRowY = 476;

/// 第二行（描边）在卡片里的 y（SongDetailCard.cpp:70 actions(..., 532, false)）。
const double kSongDetailSecondaryRowY = 532;

/// 调用方做标签裁剪时从列宽里扣掉的左右内边距和（NativeHudDetail.cpp:144/147 的 buttonWidth - 24）。
const double kActionRowFitInset = 24;

/// 一格的列宽：(model.width - gap * 2) / 3（SongDetailCard.cpp:21）。
///
/// 这里是浮点除法，不取整 —— Qt 的 const auto width 是 double，
/// 785.8 宽会得到 253.9333...，后续 x 也是小数。
double actionRowColumnWidth(double rowWidth) => (rowWidth - kActionRowGap * 2) / 3;

/// 一格的位置：model.x + index * (width + gap)（SongDetailCard.cpp:29）。
///
/// index 是输入向量里的下标，不是“已绘制计数”：route 为空的格子被跳过后，
/// 后面的格子不会左移（Qt 的 continue 发生在 x 计算前，但 x 用的就是 index，见 :24-29）。
double actionRowCellX({
  required double rowX,
  required double columnWidth,
  required int index,
}) =>
    rowX + index * (columnWidth + kActionRowGap);

/// Qt SongDetailCard::Action{label, route}（SongDetailCard.h:10-13）。
class ActionRowItem {
  const ActionRowItem(this.label, this.route);

  /// 命中 label 与绘制文案；Qt 里同一字段两用（SongDetailCard.cpp:41/44）。
  final String label;

  /// 动作路由；空字符串表示这一格整格跳过（SongDetailCard.cpp:26-28）。
  final String route;

  bool get isSkipped => route.isEmpty;

  ActionRowItem withLabel(String next) => ActionRowItem(next, route);
}

/// 一次动作行绘制所需的全部输入（不可变）。
class ActionRowModel {
  const ActionRowModel({
    required this.x,
    required this.width,
    required this.y,
    required this.dark,
    required this.primaryRow,
    required this.items,
  });

  /// 行左边界（stage 单位）。歌曲卡片里等于 width * 0.56（NativeHudDetail.cpp:56）。
  final double x;

  /// 行可用宽（stage 单位）。歌曲卡片里 usable = width - x - 59（NativeHudDetail.cpp:60）。
  final double width;

  /// 行上边界（stage 单位）：476 或 532（SongDetailCard.cpp:69-70）。
  final double y;

  final bool dark;

  /// true 时 index==0 的格子用前景实心填充（SongDetailCard.cpp:30-32）。
  final bool primaryRow;

  /// 固定三格：不足三格由空 route 占位；超过三格会画到行宽之外（与 Qt 一致，不做保护）。
  final List<ActionRowItem> items;
}

/// 移植 SongDetailCard::actions（SongDetailCard.cpp:17-46）。
///
/// 每格命令序列（与 Qt 完全同序）：
/// - primary：fill(x, y, width, height, foreground)
/// - 否则四条 1px 边框：上、下、左、右，颜色 foreground 且 alpha=0.2（:36-39 的顺序）
/// - 然后登记命中（:41）
/// - 最后一条文字：text(label, x+12, y+12, 14, primary ? demibold : regular,
///   primary ? inverse : foreground)（:42-44；命令里 tracking 固定 0）
///
/// 注意 Qt 的文案裁剪不在这里：detail() 在 paint 之前用 fit(label, 14, buttonWidth-24, weight)
/// 先裁好（NativeHudDetail.cpp:142-148），因此本函数原样发出 label。
Drawing buildActionRow(ActionRowModel model) {
  final DrawingBuilder builder = DrawingBuilder();
  final List<Object?> foreground = cardInk(model.dark); // SongDetailCard.cpp:22
  final List<Object?> inverse = cardInverse(model.dark); // SongDetailCard.cpp:23
  final double width = actionRowColumnWidth(model.width); // SongDetailCard.cpp:21
  for (int index = 0; index < model.items.length; index++) {
    final ActionRowItem item = model.items[index]; // SongDetailCard.cpp:25
    if (item.route.isEmpty) {
      continue; // SongDetailCard.cpp:26-28：整格跳过，既不绘制也不命中
    }
    final double x = actionRowCellX(rowX: model.x, columnWidth: width, index: index); // :29
    final bool primary = model.primaryRow && index == 0; // SongDetailCard.cpp:30
    if (primary) {
      builder.op(fillCommand(x, model.y, width, kActionRowHeight, foreground)); // :32
    } else {
      final List<Object?> border = withAlpha(foreground, kActionRowBorderAlpha); // :34-35
      builder.op(fillCommand(x, model.y, width, 1, border)); // :36
      builder.op(fillCommand(x, model.y + kActionRowHeight - 1, width, 1, border)); // :37
      builder.op(fillCommand(x, model.y, 1, kActionRowHeight, border)); // :38
      builder.op(fillCommand(x + width - 1, model.y, 1, kActionRowHeight, border)); // :39
    }
    builder.hit(
      x: x,
      y: model.y,
      width: width,
      height: kActionRowHeight,
      action: item.route,
      label: item.label,
    ); // SongDetailCard.cpp:41
    final List<Object?> color = primary ? inverse : foreground; // :42
    builder.op(textCommand(
      item.label,
      x + kActionRowTextInsetX,
      model.y + kActionRowTextInsetY,
      kActionRowFontSize,
      primary ? kActionRowPrimaryWeight : kActionRowSecondaryWeight,
      0,
      color,
    )); // SongDetailCard.cpp:44
  }
  return builder.build();
}

/// 复现调用方的标签裁剪（NativeHudDetail.cpp:142-148）。
///
/// Qt 先算 buttonWidth = (usable - gap*2)/3（:62），再对每格
/// fit(label, 14, buttonWidth - 24, weight)：主行按 route 选字重
/// （action.route == "music:play" ? "demibold" : "regular"，:143），
/// 副行一律默认 "regular"（:147）。裁剪覆盖所有格（含空 route 的格），
/// 因为 Qt 的循环不筛 route —— 空标签 fit 后仍是空串。
List<ActionRowItem> fitActionRowLabels(
  List<ActionRowItem> items, {
  required double fontSize,
  required double columnWidth,
  required GlyphsPort glyphs,
  String Function(ActionRowItem item)? weightOf,
}) {
  final double fitWidth = columnWidth - kActionRowFitInset;
  return <ActionRowItem>[
    for (final ActionRowItem item in items)
      item.withLabel(fitGlyphText(
        item.label,
        fontSize,
        fitWidth,
        weightOf == null ? kActionRowSecondaryWeight : weightOf(item),
        glyphs,
      )),
  ];
}

/// 歌曲卡片两行的唯一组合点：476 primary / 532 secondary（SongDetailCard.cpp:69-70）。
///
/// 两次 actions() 之间没有 save/restore、没有额外命令；命令与命中都按行序拼在一起。
Drawing songDetailActionRows({
  required double x,
  required double width,
  required bool dark,
  required List<ActionRowItem> primaryActions,
  required List<ActionRowItem> secondaryActions,
}) {
  final DrawingBuilder builder = DrawingBuilder();
  builder.add(buildActionRow(ActionRowModel(
    x: x,
    width: width,
    y: kSongDetailPrimaryRowY,
    dark: dark,
    primaryRow: true,
    items: primaryActions,
  ))); // SongDetailCard.cpp:69
  builder.add(buildActionRow(ActionRowModel(
    x: x,
    width: width,
    y: kSongDetailSecondaryRowY,
    dark: dark,
    primaryRow: false,
    items: secondaryActions,
  ))); // SongDetailCard.cpp:70
  return builder.build();
}

/// 封面动作行的一格（NativeHudDetail.cpp:203-213 的三个条件按钮）。
class FooterActionSlot {
  const FooterActionSlot(this.label, this.route);

  final String label;
  final String route;
}

/// 封面动作行（官方客户端 / 试听片段 / 从歌单移除）的输入。
///
/// 与 ActionRowModel 的区别：这里每一格来自独立的 if 条件，而不是带空 route 的三元向量；
/// 绘制语义也换成 NativeHud::button（NativeHud.cpp:110-120）：
/// hit 先登记，文字垂直居中到 y + (height - size)/2 - 4，没有边框也没有实心底
/// （m_modalControls 为 false 时不画底、也不做 fit —— :113-119）。
class FooterActionRowModel {
  const FooterActionRowModel({
    required this.x,
    required this.width,
    required this.y,
    required this.dark,
    required this.slots,
    this.height = 44,
    this.fontSize = 13,
    this.modalControls = false,
    this.glyphs,
  });

  /// 行左边界：歌曲详情里等于 width * 0.56（NativeHudDetail.cpp:56）。
  final double x;

  /// 行可用宽：usable = width - x - 59（NativeHudDetail.cpp:60）。
  final double width;

  /// 行上边界：910（NativeHudDetail.cpp:205/209/212）。
  final double y;

  final bool dark;

  /// 三个槽位，null 表示该条件不成立；下标决定列位，缺格不会让后面的格子左移。
  final List<FooterActionSlot?> slots;

  /// 44（NativeHudDetail.cpp:205/209/212）。
  final double height;

  /// 13（NativeHudDetail.cpp:206/209/212）。
  final double fontSize;

  /// Qt m_modalControls：为 true 时 button() 会加半透明底并按 width-2*inset 裁字
  /// （NativeHud.cpp:113-118）。详情页恒为 false。
  final bool modalControls;

  /// 仅在 modalControls 为 true 时需要 —— Qt 只在那条分支里调用 fit（:118）。
  final GlyphsPort? glyphs;
}

/// 移植 NativeHudDetail.cpp:203-213 的三列封面动作行 + NativeHud::button（NativeHud.cpp:110-120）。
///
/// 列宽与列位：buttonWidth = (usable - gap*2)/3（:61-62），
/// 第 i 列 x = x + i * (buttonWidth + gap)（:205/209/212 的三种写法等价）。
///
/// 每格命令序列（modalControls=false，即详情页真实形态）：
/// 1. hit(x, y, buttonWidth, 44, route, label)（NativeHud.cpp:112）
/// 2. text(label, x, y + (44-13)/2 - 4, 13, "regular", 0, ink())（:118-119，ink 带 calibrated 标记）
Drawing buildFooterActionRow(FooterActionRowModel model) {
  if (model.modalControls && model.glyphs == null) {
    throw ArgumentError(
      'modalControls 需要 glyphs：Qt 在这条分支里按 width-2*inset 做 fit（NativeHud.cpp:118）',
    );
  }
  final DrawingBuilder builder = DrawingBuilder();
  final double columnWidth = actionRowColumnWidth(model.width); // NativeHudDetail.cpp:62
  final List<Object?> color = hudInk(model.dark); // NativeHud.cpp:119 -> text() 的默认 ink()
  for (int index = 0; index < model.slots.length; index++) {
    final FooterActionSlot? slot = model.slots[index];
    if (slot == null) {
      continue; // 条件不成立：Qt 连 button() 都不调用，不 hit 不 text（NativeHudDetail.cpp:204-213）
    }
    final double x = actionRowCellX(rowX: model.x, columnWidth: columnWidth, index: index);
    builder.hit(
      x: x,
      y: model.y,
      width: columnWidth,
      height: model.height,
      action: slot.route,
      label: slot.label,
    ); // NativeHud.cpp:112
    final double inset = model.modalControls
        ? (columnWidth / 8 < 10 ? columnWidth / 8 : 10.0)
        : 0.0; // NativeHud.cpp:113 std::min(10.0, width/8)，非模态为 0
    if (model.modalControls) {
      builder.op(fillCommand(
        x,
        model.y,
        columnWidth,
        model.height,
        model.dark
            ? const <Object?>[0.55, 0.59, 0.46, 0.13]
            : const <Object?>[0.44, 0.49, 0.36, 0.1],
      )); // NativeHud.cpp:115-116
    }
    final String label = model.modalControls
        ? fitGlyphText(slot.label, model.fontSize, columnWidth - inset * 2,
            kActionRowSecondaryWeight, model.glyphs!)
        : slot.label; // NativeHud.cpp:118：非模态分支原样发 label，不裁字
    builder.op(textCommand(
      label,
      x + inset,
      model.y + (model.height - model.fontSize) / 2 - 4,
      model.fontSize,
      kActionRowSecondaryWeight,
      0,
      color,
    )); // NativeHud.cpp:119
  }
  return builder.build();
}
