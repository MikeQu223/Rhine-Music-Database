/// T36 · 个人库（saved）横屏 1:1 移植 + 竖屏响应式全语义。
///
/// 证据（只读引用，逐条对应，禁止凭猜）：
/// - 几何常量：Qt/src/NativeHudLibrary.cpp:7-18
/// - libraryPanel / savedPanel 分派：Qt/src/NativeHudLibrary.cpp:45-58
/// - libraryToolbarActionWidth（Create/Refresh/ActionGap 拼装）：Qt/src/NativeHudLibrary.cpp:60-72
/// - libraryOutlineButton（描边 + 可选加号 + 居中文字 + hit）：Qt/src/NativeHudLibrary.cpp:74-93
/// - libraryToolbar（QUERY 提示/创建/刷新/标签行/排序/表头/分组返回）：Qt/src/NativeHudLibrary.cpp:95-180
/// - libraryResultList（viewport/空态/登录入口/裁剪/滚动条 rail）：Qt/src/NativeHudLibrary.cpp:182-226
/// - libraryFooter（accent 方块/status/已载入提示）：Qt/src/NativeHudLibrary.cpp:228-250
/// - savedScrollMaximum / ensureSavedFilled（自动补页去重）：Qt/src/NativeHudLibrary.cpp:252-268
/// - ResultListTop=328 / ResultListBottom=758 / ResultRowHeight=72：Qt/src/NativeHud.h:96-98
/// - Row{index,value,indices}：Qt/src/NativeHud.h:32-36
/// - 命令格式 save/restore/clip/fill/text/image：Qt/src/NativeHud.cpp:16-43,130-134
/// - hit 六字段 x,y,width,height,action,label：Qt/src/NativeHud.cpp:102-109
/// - fit() 截断语义：Qt/src/NativeHud.cpp:48-75
/// - 滚动 maximum / rail / clipHits：Qt/src/HudScroll.h:13-86
/// - 弹层可见性与 modalOffset：Qt/qml/Overlay.qml:224-229
/// - 模型字段 editable()/sourceLoading()/providerName()/sourceMessage()/loadMoreSource()/
///   hasMore/totals/lists/columns/restoringAccount：Qt/src/MusicLibrary.h:45-105,140-151
///
/// 自包含约束：本文件不 import 任何 lib/hud/protocol/**、lib/hud/** 或其它树模块。
/// 需要外部能力时一律走本文件内声明的最小抽象端口（文本度量 / 行绘制 / 写操作），由集成方注入；
/// 依赖缺失时显式记入 LibraryModalFrame.notes，绝不以假数据兜底、绝不当作已实现。
///
/// 竖屏：Qt Android 只有横屏证据，本文件新增的竖屏布局是新规格，不是 Qt 竖屏像素。
///
/// 弹层框架分两段 owner，均不属于本层（docs/.../2026-11-09-qt-to-flutter-parity-plan.md:180）：
/// - 遮挡层（modal 遮罩槽，必须在内容之前）：全屏遮罩 + 弹层不透明底
///   （Qt/src/NativeHudModal.cpp:163-165、:171-172）；
/// - chrome 层（hits 之后）：RHINE LAB 行 / 标题 / 副标题 / "← 返回"
///   （Qt/src/NativeHudModal.cpp:198-202）与唯一 close-modal hit；owner 是计划中的
///   lib/hud/pages/chrome.dart（PAGE-ARCHIVE）。
/// 本层只产出 saved 面板内容，绝不画底、画前景框架或造第二个 close-modal。
library;

import 'dart:math' as math;

// ---------------------------------------------------------------------------
// 1. 颜色（Qt/src/NativeHudLibrary.cpp:20-42, Qt/src/NativeHud.cpp:10-15）
// ---------------------------------------------------------------------------

/// HUD 颜色。Qt 的 ink() 带色彩空间标记（calibratedWhite / calibratedRGB），
/// 其余颜色为 4 元素 RGBA。
class HudColor {
  const HudColor(this.r, this.g, this.b, this.a, [this.space]);

  final double r;
  final double g;
  final double b;
  final double a;

  /// null 表示无标记；否则为 "calibratedWhite" / "calibratedRGB"。
  final String? space;

  /// Qt 原样序列化：@see Qt/src/NativeHud.cpp:10-15
  List<Object?> toFlatArray() =>
      space == null ? <Object?>[r, g, b, a] : <Object?>[r, g, b, a, space];

  HudColor withAlpha(double value) => HudColor(r, g, b, value, space);

  @override
  String toString() => 'HudColor(${r}, ${g}, ${b}, ${a}${space == null ? '' : ', $space'})';
}

/// 个人库面板用到的取色函数，逐条对应 Qt 源码。
abstract final class HudPalette {
  /// Qt/src/NativeHudLibrary.cpp:20-22 accent()
  static const HudColor accent = HudColor(0.835, 0.639, 0.282, 1);

  /// Qt/src/NativeHud.cpp:10-15 ink()
  static HudColor ink({required bool dark}) => dark
      ? const HudColor(0.92, 0.92, 0.92, 1, 'calibratedWhite')
      : const HudColor(0.08, 0.085, 0.075, 1, 'calibratedRGB');

  /// Qt/src/NativeHudLibrary.cpp:24-28 mutedInk()：只改 alpha 为 0.55。
  static HudColor mutedInk(HudColor ink) => ink.withAlpha(0.55);

  /// Qt/src/NativeHudLibrary.cpp:30-34 faintInk()。
  static HudColor faintInk(HudColor ink, double alpha) => ink.withAlpha(alpha);

  /// Qt/src/NativeHudLibrary.cpp:36-38 libraryBarFill()
  static HudColor libraryBarFill({required bool dark}) => dark
      ? const HudColor(0.169, 0.200, 0.173, 1)
      : const HudColor(0.898, 0.906, 0.855, 1);

  /// Qt/src/NativeHudLibrary.cpp:40-42 libraryPanelFill()
  static HudColor libraryPanelFill({required bool dark}) => dark
      ? const HudColor(0.15, 0.15, 0.15, 1)
      : const HudColor(0.929, 0.922, 0.894, 1);
}

// ---------------------------------------------------------------------------
// 2. 几何矩形（QRectF 语义）
// ---------------------------------------------------------------------------

/// 与 QRectF 对齐的矩形语义：right()/bottom() 为 x+width / y+height，
/// 相交为空时宽高为负，isEmpty 判真。@see Qt/src/HudScroll.h:67-86
class HudRectF {
  const HudRectF(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;
  double get centerX => left + width / 2;
  double get centerY => top + height / 2;

  bool get isEmpty => width <= 0 || height <= 0;

  HudRectF intersected(HudRectF other) {
    final double l = math.max(left, other.left);
    final double t = math.max(top, other.top);
    final double r = math.min(right, other.right);
    final double b = math.min(bottom, other.bottom);
    return HudRectF(l, t, r - l, b - t);
  }

  @override
  String toString() => 'HudRectF($left, $top, $width, $height)';
}

/// 数值夹取，避免 num 返回类型与 double 变量不匹配。
double _clamp(double value, double low, double high) =>
    value < low ? low : (value > high ? high : value);

// ---------------------------------------------------------------------------
// 3. 绘制命令（Qt op() 的逐字段等价物）
// ---------------------------------------------------------------------------

/// HUD 绘制命令基类。toFlatArray 与 Qt op() 的位置参数逐项一致。
sealed class HudCommand {
  const HudCommand();

  List<Object?> toFlatArray();
}

/// save：Qt/src/NativeHud.cpp:19-21
final class HudSaveCommand extends HudCommand {
  const HudSaveCommand();

  @override
  List<Object?> toFlatArray() => const <Object?>['save'];
}

/// restore：Qt/src/NativeHud.cpp:22-24
final class HudRestoreCommand extends HudCommand {
  const HudRestoreCommand();

  @override
  List<Object?> toFlatArray() => const <Object?>['restore'];
}

/// clip：Qt/src/NativeHud.cpp:34-36
final class HudClipCommand extends HudCommand {
  const HudClipCommand(this.rect);

  final HudRectF rect;

  @override
  List<Object?> toFlatArray() =>
      <Object?>['clip', rect.left, rect.top, rect.width, rect.height];
}

/// fill：Qt/src/NativeHud.cpp:37-39 → {"fill", color, x, y, width, height}
final class HudFillCommand extends HudCommand {
  const HudFillCommand(this.rect, this.color);

  final HudRectF rect;
  final HudColor color;

  @override
  List<Object?> toFlatArray() => <Object?>[
        'fill',
        color.toFlatArray(),
        rect.left,
        rect.top,
        rect.width,
        rect.height,
      ];
}

/// text：Qt/src/NativeHud.cpp:40-43 → {"text", value, x, y, size, weight, tracking, color}
final class HudTextCommand extends HudCommand {
  const HudTextCommand(
    this.value,
    this.x,
    this.y,
    this.size, {
    this.weight = 'regular',
    this.tracking = 0,
    required this.color,
  });

  final String value;
  final double x;
  final double y;
  final double size;
  final String weight;
  final double tracking;
  final HudColor color;

  @override
  List<Object?> toFlatArray() => <Object?>[
        'text',
        value,
        x,
        y,
        size,
        weight,
        tracking,
        color.toFlatArray(),
      ];
}

/// image：Qt/src/NativeHud.cpp:130-134 → {"image", key, x, y, width, height}
final class HudImageCommand extends HudCommand {
  const HudImageCommand(this.key, this.rect);

  final String key;
  final HudRectF rect;

  @override
  List<Object?> toFlatArray() =>
      <Object?>['image', key, rect.left, rect.top, rect.width, rect.height];
}

// ---------------------------------------------------------------------------
// 4. 命中（hits 原序六字段：x, y, width, height, action, label）
// ---------------------------------------------------------------------------

/// 命中矩形。字段名与顺序即契约：x, y, width, height, action, label。
/// @see Qt/src/NativeHud.cpp:102-109
class HudHit {
  const HudHit({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.action,
    required this.label,
  });

  final double x;
  final double y;
  final double width;
  final double height;
  final String action;
  final String label;

  HudRectF get rect => HudRectF(x, y, width, height);

  /// 六字段 flatarray，顺序不可变。
  List<Object?> toFlatArray() => <Object?>[x, y, width, height, action, label];

  /// 与 Qt QJsonObject 相同的键名与插入顺序。
  Map<String, Object?> toJson() => <String, Object?>{
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'action': action,
        'label': label,
      };

  HudHit withRect(HudRectF r) => HudHit(
        x: r.left,
        y: r.top,
        width: r.width,
        height: r.height,
        action: action,
        label: label,
      );

  @override
  String toString() =>
      'HudHit($x, $y, $width, $height, $action, $label)';
}

// ---------------------------------------------------------------------------
// 5. 文本度量端口（对应 Qt Glyphs：width / bounds / NativeHud::fit）
// ---------------------------------------------------------------------------

/// 文本包围盒，对应 Glyphs::bounds() 的 x/y/width/height。
/// @see Qt/src/Glyphs.h:26
class LibraryTextBounds {
  const LibraryTextBounds({
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

/// 文本度量端口。集成方注入真实实现（Qt 侧为 Glyphs）。
/// 本文件只声明端口，不提供任何"看起来像"的默认度量 —— 缺失即错误。
/// @see Qt/src/Glyphs.h:25-27
abstract class LibraryTextMetrics {
  /// @see Qt/src/Glyphs.h:25 Glyphs::width(text, size, weight, tracking)
  double width(String text, double size,
      {String weight = 'regular', double tracking = 0});

  /// @see Qt/src/Glyphs.h:26 Glyphs::bounds(text, size, weight)
  LibraryTextBounds bounds(String text, double size, {String weight = 'regular'});

  /// 截断语义逐行照搬 NativeHud::fit：宽度超出时二分找最长可容前缀，再退一位加省略号。
  /// @see Qt/src/NativeHud.cpp:48-75
  String fit(String text, double size, double maxWidth,
      {String weight = 'regular'}) {
    if (width(text, size, weight: weight) <= maxWidth) {
      return text;
    }
    final int length = text.length;
    int low = 1;
    int high = length;
    while (low < high) {
      final int middle = (low + high + 1) ~/ 2;
      if (width(text.substring(0, middle), size, weight: weight) <= maxWidth) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    final int kept = low;
    if (kept == text.length) {
      return text;
    }
    final int cut = math.max(0, kept - 1);
    return '${text.substring(0, cut)}…';
  }
}

// ---------------------------------------------------------------------------
// 6. 行绘制端口（Qt 的共享 resultListRow 在 NativeHudSearch.cpp:175，非本文件职责）
// ---------------------------------------------------------------------------

/// 结果行引用，对应 Qt NativeHud::Row{index, value, indices}。
/// @see Qt/src/NativeHud.h:32-36
class LibraryRowRef {
  const LibraryRowRef({
    required this.index,
    required this.value,
    this.indices = const <int>[],
  });

  final int index;
  final Map<String, Object?> value;
  final List<int> indices;

  String? get kind => value['kind'] as String?;
}

/// 行绘制的输出回调：把命令与命中追加到帧里。
typedef LibraryRowOut = void Function(HudCommand command, HudHit? hit);

/// 结果行绘制端口。横屏 Qt 调用共享的 resultListRow(row, x, rowY, width, query, lane)，
/// 该函数不属于本文件（搜索/结果列表共用），因此这里注入。
/// @see Qt/src/NativeHudLibrary.cpp:209-212（调用点）
/// @see Qt/src/NativeHud.h:301（声明）
abstract class LibraryRowPainter {
  void paintRow({
    required LibraryRowRef row,
    required double x,
    required double y,
    required double width,
    required String query,
    required int lane,
    required LibraryRowOut out,
  });
}

// ---------------------------------------------------------------------------
// 7. 写操作端口（动作字符串 → 端口方法，一一对应）
// ---------------------------------------------------------------------------

/// 写操作 / 交互端口。库面板只通过这些方法触发副作用，不直连网络、不直连模型。
///
/// 动作字符串映射（Qt 原文，逐字）：
/// - "music:create-playlist"  → createPlaylist        Qt/src/NativeHudLibrary.cpp:110
/// - "music:refresh-personal" → refreshPersonal       Qt/src/NativeHudLibrary.cpp:116
/// - "music:collection:N"     → selectCollection(N)   Qt/src/NativeHudLibrary.cpp:127
/// - "music:group:N"          → setGroupKey(keys[N])  Qt/src/NativeHudLibrary.cpp:157
/// - "music:group-back"       → backToAllGroups       Qt/src/NativeHudLibrary.cpp:177
/// - "music:login"            → openLogin             Qt/src/NativeHudLibrary.cpp:198
/// - "close-modal"            → closeModal            Qt/src/NativeHudLibrary.cpp:321（登录面板）
/// - 滚动 / 自动补页          → scrollSaved / loadMoreSaved Qt/src/NativeHudLibrary.cpp:266
abstract class LibraryModalPorts {
  void createPlaylist();
  void refreshPersonal();
  void selectCollection(int collection);
  void setGroupKey(String key);
  void backToAllGroups();
  void openLogin();
  void closeModal();
  void scrollSaved(double offset);
  void loadMoreSaved();
}

// ---------------------------------------------------------------------------
// 8. 几何规格（横屏，逐常量对齐 Qt）
// ---------------------------------------------------------------------------

/// 横屏个人库几何。全部来自 Qt 源码常量，不可改数。
/// @see Qt/src/NativeHudLibrary.cpp:7-18
/// @see Qt/src/NativeHud.h:96-98
abstract final class LibraryGeometry {
  static const double inset = 53; // LibraryInset
  static const double barTop = 172; // LibraryBarTop
  static const double barHeight = 66; // LibraryBarHeight
  static const double tabTop = 252; // LibraryTabTop
  static const double tabHeight = 36; // LibraryTabHeight
  static const double tableY = 302; // LibraryTableY
  static const double footerY = 786; // LibraryFooterY
  static const double createWidth = 150; // LibraryCreateWidth
  static const double refreshWidth = 110; // LibraryRefreshWidth
  static const double actionGap = 10; // LibraryActionGap
  static const double titleX = 107; // LibraryTitleX
  static const double actionWidth = 136; // LibraryActionWidth

  static const double resultListTop = 328; // NativeHud.h:96
  static const double resultListBottom = 758; // NativeHud.h:97
  static const double rowHeight = 72; // NativeHud.h:98

  /// 430：viewport 高度。@see Qt/src/NativeHudLibrary.cpp:186
  static const double viewportHeight = resultListBottom - resultListTop;

  /// 标签行下划线厚度 3px（gold）。@see Qt/src/NativeHudLibrary.cpp:131
  static const double tabUnderline = 3;

  /// 排序下划线厚度 2px（gold）。@see Qt/src/NativeHudLibrary.cpp:161
  static const double sortUnderline = 2;

  /// 表头下 rule 透明度 0.18 / 0.24。@see Qt/src/NativeHudLibrary.cpp:167,171
  static const double ruleTabOpacity = 0.18;
  static const double ruleHeaderOpacity = 0.24;

  /// rail 轨道宽度 3px、两端内缩 8px、最小 thumb 30px。
  /// @see Qt/src/NativeHudLibrary.cpp:216-221
  static const double railWidth = 3;
  static const double railInset = 8;
  static const double railMinThumb = 30;

  /// 标签行游标步进 = labelWidth + 26。@see Qt/src/NativeHudLibrary.cpp:133
  static const double tabStep = 26;

  /// 排序段步进 = labelWidth + 20，分隔线在 sortX-16。@see Qt/src/NativeHudLibrary.cpp:150,152,163
  static const double sortStep = 20;
  static const double sortDividerOffset = 16;

  /// 空态文案 y 偏移 +92；登录入口 (left, +132, 300, 44)；message 字号 18。
  /// @see Qt/src/NativeHudLibrary.cpp:194-198
  static const double emptyMessageOffsetY = 92;
  static const double loginEntryOffsetY = 132;
  static const double loginEntryWidth = 300;
  static const double loginEntryHeight = 44;

  /// 分组返回：labelWidth = width(label) + 16，x = right - 150 - labelWidth，高 28、y-7。
  /// @see Qt/src/NativeHudLibrary.cpp:175-178
  static const double groupBackPad = 16;
  static const double groupBackReserve = 150;
  static const double groupBackHeight = 28;
  static const double groupBackOffsetY = -7;
  static const String groupBackText = '← 全部分组';
  static const String groupBackLabel = '全部分组';

  /// footer：accent 5x5 方块在 y+3，status 起点 x+13，status 上限 width-320，字号 10；
  /// 已载入行字号 9、tracking 0.04，右对齐到 right。
  /// @see Qt/src/NativeHudLibrary.cpp:230-249
  static const double footerSquare = 5;
  static const double footerSquareOffsetY = 3;
  static const double footerTextOffsetX = 13;
  static const double footerStatusMaxReduction = 320;
  static const double footerStatusSize = 10;
  static const double footerHintSize = 9;
  static const double footerHintTracking = 0.04;

  /// 左侧内容区。@see Qt/src/NativeHudLibrary.cpp:96
  static double contentLeft(double x) => x + inset;

  /// usable = width - inset*2。@see Qt/src/NativeHudLibrary.cpp:97
  static double usableWidth(double width) => width - inset * 2;

  /// 右边界 x + width - inset。@see Qt/src/NativeHudLibrary.cpp:106
  static double contentRight(double x, double width) => x + width - inset;

  /// libraryToolbarActionWidth()：Create/Refresh 以 ActionGap 拼装，有内容时再补一个 gap。
  /// @see Qt/src/NativeHudLibrary.cpp:60-72
  static double toolbarActionWidth({
    required bool savedModal,
    required bool editable,
    required String provider,
  }) {
    if (!savedModal) {
      return 0;
    }
    double total = 0;
    if (editable) {
      total += createWidth;
    }
    if (provider == 'qq') {
      total += (total > 0 ? actionGap : 0) + refreshWidth;
    }
    return total > 0 ? total + actionGap : 0;
  }

  /// savedScrollMaximum()。@see Qt/src/NativeHudLibrary.cpp:252-254
  static double savedScrollMaximum(double savedRowCount) =>
      math.max(0.0, savedRowCount * rowHeight - viewportHeight);

  /// 内容高度 = savedRowCount * ResultRowHeight。@see Qt/src/NativeHudLibrary.cpp:221
  static double savedContentHeight(double savedRowCount) =>
      savedRowCount * rowHeight;
}

// ---------------------------------------------------------------------------
// 9. 快照 / 状态
// ---------------------------------------------------------------------------

/// 一次渲染所需的只读快照。字段名与 Qt 模型字段一一对应。
/// 不引入 Qt 没有的阶段枚举：面板状态直接由 sourceLoading / rows / hasMore /
/// status / emptyMessage 字段表达（Qt/src/NativeHudLibrary.cpp:182-250）。
class LibraryModalSnapshot {
  const LibraryModalSnapshot({
    this.modal = 'saved',
    required this.dark,
    required this.provider,
    required this.providerName,
    required this.uid,
    required this.restoringAccount,
    required this.isLocal,
    required this.isSiren,
    required this.columns,
    required this.musicCollection,
    required this.groupBy,
    required this.activeGroup,
    required this.query,
    required this.rows,
    required this.laneHasSong,
    required this.loadedCount,
    required this.total,
    required this.hasMore,
    required this.sourceLoading,
    required this.status,
    required this.emptyMessage,
    required this.savedScroll,
  });

  /// "saved" | "search" | 其它。@see Qt/src/NativeHudLibrary.cpp:46-50
  final String modal;
  final bool dark;

  /// "" | "netease" | "qq" | "kugou" | "siren" | "local" …
  final String provider;
  final String providerName;

  /// 登录用户 id；空 = 未登录。@see Qt/src/NativeHudLibrary.cpp:195
  final String uid;
  final bool restoringAccount;
  final bool isLocal;
  final bool isSiren;

  /// 五列标题。@see Qt/src/MusicLibrary.h:151
  final List<String> columns;

  /// 当前集合（lane），1 基。@see Qt/src/NativeHud.h:94
  final int musicCollection;

  /// "none" | "artist" | "album"。@see Qt/src/NativeHud.h:84
  final String groupBy;

  /// 非空 = 处于某分组视图。@see Qt/src/NativeHud.h:85
  final String activeGroup;

  /// 过滤词；saved 模式下参与 rows() 过滤。@see Qt/src/NativeHudController.cpp:187-199
  final String query;

  /// 过滤后的行（Qt rows(lane) 的结果）。@see Qt/src/NativeHudController.cpp:183-202
  final List<LibraryRowRef> rows;

  /// `lists[lane]`（未经过滤的全量）是否含 `kind == "song"` 的行。
  /// 排序段的存在性判定用全量集合，不能用过滤后的 [rows]。
  /// @see Qt/src/NativeHudLibrary.cpp:136-140
  final bool laneHasSong;

  /// lists[lane].size()。@see Qt/src/NativeHudLibrary.cpp:235
  final int loadedCount;

  /// totals[lane]。@see Qt/src/NativeHudLibrary.cpp:239
  final int total;

  /// hasMore[lane]。@see Qt/src/MusicLibrary.h:148
  final bool hasMore;

  /// sourceLoading()。@see Qt/src/MusicLibrary.h:98-100
  final bool sourceLoading;

  /// footer 左侧状态文案。@see Qt/src/NativeHudLibrary.cpp:231
  final String status;

  /// sourceMessage(lane)：空集合文案。@see Qt/src/NativeHudLibrary.cpp:193
  final String emptyMessage;

  final double savedScroll;

  /// Qt/src/MusicLibrary.h:95-97
  bool get editable =>
      provider == 'netease' || provider == 'qq' || provider == 'siren';

  /// 未登录入口条件：!isLocal && !isSiren && lane>0 && uid 空 && 非恢复中。
  /// @see Qt/src/NativeHudLibrary.cpp:195-196
  bool get loginEntryAllowed =>
      !isLocal &&
      !isSiren &&
      musicCollection > 0 &&
      uid.isEmpty &&
      !restoringAccount;

  /// 标签行可见标签（columns.mid(1, kugou ? 3 : 4)）。@see Qt/src/NativeHudLibrary.cpp:119
  List<String> get tabLabels {
    final int count = provider == 'kugou' ? 3 : 4;
    if (columns.length <= 1) {
      return const <String>[];
    }
    final int end = math.min(columns.length, 1 + count);
    return columns.sublist(1, end);
  }

  /// 排序段是否存在（`lists[lane]` 全量含 kind=="song" 的行）。
  /// @see Qt/src/NativeHudLibrary.cpp:136-140
  bool get hasSongs => laneHasSong;

  /// 是否显示「创建歌单」。@see Qt/src/NativeHudLibrary.cpp:107 editable()
  bool get canCreatePlaylist => editable;

  /// 是否显示「刷新个人库」（仅 qq）。@see Qt/src/NativeHudLibrary.cpp:113
  bool get canRefreshPersonal => provider == 'qq';

  /// footer 提示文案。@see Qt/src/NativeHudLibrary.cpp:240-245
  String get footerHint {
    if (sourceLoading) {
      return '正在加载…';
    }
    if (hasMore) {
      return 'SCROLL / 滚动加载';
    }
    return '全部已载入';
  }

  /// footer 右侧整条文案。@see Qt/src/NativeHudLibrary.cpp:246-247
  String get footerLabel {
    final int shownTotal = math.max(total, loadedCount);
    return '已载入 $loadedCount / $shownTotal · $footerHint';
  }

  /// 排序键顺序，与 Qt keys 一致。@see Qt/src/NativeHudLibrary.cpp:142
  static const List<String> groupKeys = <String>['none', 'artist', 'album'];

  /// 排序标签，与 Qt labels 一致。@see Qt/src/NativeHudLibrary.cpp:141
  static const List<String> groupLabels = <String>['原序', '歌手分组', '专辑分组'];
}

// ---------------------------------------------------------------------------
// 10. 帧输出
// ---------------------------------------------------------------------------

/// 一次构建的产物：命令 + 命中同代（同一 build 调用内生成）。
class LibraryModalFrame {
  const LibraryModalFrame({
    required this.commands,
    required this.hits,
    required this.viewport,
    required this.savedScroll,
    required this.savedScrollMaximum,
    required this.savedRowCount,
    required this.firstRowHit,
    this.notes = const <String>[],
  });

  final List<HudCommand> commands;
  final List<HudHit> hits;

  /// 结果列表 viewport（也是滚动 / 命中裁剪区）。@see Qt/src/NativeHudLibrary.cpp:186
  final HudRectF viewport;
  final double savedScroll;
  final double savedScrollMaximum;
  final int savedRowCount;

  /// hits 中第一个属于行的下标；之前的是工具条/表头命中，不参与裁剪。
  /// @see Qt/src/NativeHudLibrary.cpp:203,214
  final int firstRowHit;

  /// 诊断备注（例如缺少行绘制端口）。缺失依赖必须显式暴露。
  final List<String> notes;

  /// 命令 flatarray 列表。
  List<Object?> commandsFlatArray() =>
      <Object?>[for (final HudCommand c in commands) c.toFlatArray()];

  /// hits 原序六字段 flatarray（长度 = 6 * hits.length）。
  List<Object?> hitsFlatArray() => <Object?>[
        for (final HudHit h in hits) ...h.toFlatArray(),
      ];

  /// 查找指定 action 的全部命中。
  List<HudHit> hitsFor(String action) =>
      hits.where((HudHit h) => h.action == action).toList();
}

/// 搜索面板委托（T35 归属）。本文件不实现搜索面板，缺失即抛错。
/// @see Qt/src/NativeHudLibrary.cpp:46-49
abstract class LibrarySearchPanelDelegate {
  LibraryModalFrame buildSearchPanel({
    required LibraryModalSnapshot snapshot,
    required double x,
    required double y,
    required double width,
  });
}

// ---------------------------------------------------------------------------
// 11. 横屏个人库布局（1:1）
// ---------------------------------------------------------------------------

/// 横屏 saved 面板。savedPanel = toolbar → resultList → footer（顺序固定）。
/// @see Qt/src/NativeHudLibrary.cpp:54-58
class LibrarySavedPanel {
  const LibrarySavedPanel({required this.metrics, this.rowPainter});

  final LibraryTextMetrics metrics;

  /// 行绘制端口；为 null 且存在行时记 note，不绘制、不伪造行内容。
  final LibraryRowPainter? rowPainter;

  /// libraryPanel 分派。@see Qt/src/NativeHudLibrary.cpp:45-51
  LibraryModalFrame buildLibraryPanel({
    required LibraryModalSnapshot snapshot,
    required double x,
    required double y,
    required double width,
    LibrarySearchPanelDelegate? searchDelegate,
  }) {
    if (snapshot.modal == 'search') {
      final LibrarySearchPanelDelegate? delegate = searchDelegate;
      if (delegate == null) {
        throw StateError(
          'libraryPanel(modal=search) 需要注入搜索面板委托（T35 归属）；'
          '本文件禁止虚构搜索面板内容。',
        );
      }
      return delegate.buildSearchPanel(
        snapshot: snapshot,
        x: x,
        y: y,
        width: width,
      );
    }
    return buildSaved(snapshot: snapshot, x: x, y: y, width: width);
  }

  /// savedPanel(x, y, width)。@see Qt/src/NativeHudLibrary.cpp:54-58
  LibraryModalFrame buildSaved({
    required LibraryModalSnapshot s,
    required double x,
    required double y,
    required double width,
  }) {
    final List<HudCommand> commands = <HudCommand>[];
    final List<HudHit> hits = <HudHit>[];
    final List<String> notes = <String>[];

    _toolbar(commands: commands, hits: hits, s: s, x: x, y: y, width: width);
    final _ResultListOut list = _resultList(
      commands: commands,
      hits: hits,
      notes: notes,
      s: s,
      x: x,
      y: y,
      width: width,
    );
    _footer(commands: commands, s: s, x: x, y: y, width: width);

    return LibraryModalFrame(
      commands: commands,
      hits: hits,
      viewport: list.viewport,
      savedScroll: list.scroll,
      savedScrollMaximum: list.maximum,
      savedRowCount: list.rowCount,
      firstRowHit: list.firstRowHit,
      notes: notes,
    );
  }

  // -- libraryToolbar ------------------------------------------------------
  // @see Qt/src/NativeHudLibrary.cpp:95-180
  void _toolbar({
    required List<HudCommand> commands,
    required List<HudHit> hits,
    required LibraryModalSnapshot s,
    required double x,
    required double y,
    required double width,
  }) {
    final HudColor ink = HudPalette.ink(dark: s.dark);
    final HudColor muted = HudPalette.mutedInk(ink);
    const HudColor gold = HudPalette.accent;

    final double left = LibraryGeometry.contentLeft(x);
    final double usable = LibraryGeometry.usableWidth(width);
    final double actionSpan = LibraryGeometry.toolbarActionWidth(
      savedModal: s.modal == 'saved',
      editable: s.editable,
      provider: s.provider,
    );
    final double barWidth = usable - actionSpan;

    commands.add(HudFillCommand(
      HudRectF(
          left, y + LibraryGeometry.barTop, barWidth, LibraryGeometry.barHeight),
      HudPalette.libraryBarFill(dark: s.dark),
    ));
    commands.add(HudFillCommand(
      HudRectF(left, y + LibraryGeometry.barTop, 3, LibraryGeometry.barHeight),
      gold,
    ));

    commands.add(HudTextCommand(
      'QUERY / 检索词',
      left + 18,
      y + LibraryGeometry.barTop + 10,
      9,
      tracking: 0.08,
      color: muted,
    ));

    double right =
        x + width - LibraryGeometry.inset; // contentRight(x, width)
    if (s.editable) {
      final HudRectF create = HudRectF(
        right - LibraryGeometry.createWidth,
        y + LibraryGeometry.barTop,
        LibraryGeometry.createWidth,
        LibraryGeometry.barHeight,
      );
      _outlineButton(
        commands: commands,
        hits: hits,
        rect: create,
        label: '创建歌单',
        action: 'music:create-playlist',
        size: 12,
        plus: true,
        dark: s.dark,
      );
      right = create.left - LibraryGeometry.actionGap;
    }
    if (s.provider == 'qq') {
      final HudRectF refresh = HudRectF(
        right - LibraryGeometry.refreshWidth,
        y + LibraryGeometry.barTop,
        LibraryGeometry.refreshWidth,
        LibraryGeometry.barHeight,
      );
      _outlineButton(
        commands: commands,
        hits: hits,
        rect: refresh,
        label: '刷新个人库',
        action: 'music:refresh-personal',
        size: 12,
        plus: false,
        dark: s.dark,
      );
    }

    final List<String> filters = s.tabLabels;
    final int selected = s.musicCollection - 1;
    double cursor = left;
    for (int index = 0; index < filters.length; index++) {
      final String label = filters[index];
      final double labelWidth = metrics.width(label, 13);
      final bool active = index == selected;
      hits.add(HudHit(
        x: cursor - 4,
        y: y + LibraryGeometry.tabTop,
        width: labelWidth + 8,
        height: LibraryGeometry.tabHeight,
        action: 'music:collection:${index + 1}',
        label: label,
      ));
      commands.add(HudTextCommand(
        label,
        cursor,
        y + LibraryGeometry.tabTop + 10,
        13,
        weight: active ? 'demibold' : 'regular',
        color: active ? ink : muted,
      ));
      if (active) {
        commands.add(HudFillCommand(
          HudRectF(
            cursor,
            y +
                LibraryGeometry.tabTop +
                LibraryGeometry.tabHeight -
                LibraryGeometry.tabUnderline,
            labelWidth,
            LibraryGeometry.tabUnderline,
          ),
          gold,
        ));
      }
      cursor += labelWidth + LibraryGeometry.tabStep;
    }

    if (s.hasSongs) {
      final List<String> labels = LibraryModalSnapshot.groupLabels;
      final List<String> keys = LibraryModalSnapshot.groupKeys;
      final List<double> widths = <double>[
        for (final String label in labels) metrics.width(label, 11),
      ];
      double total = 0;
      for (final double w in widths) {
        total += w;
      }
      total += LibraryGeometry.sortStep * (labels.length - 1);
      double sortX = x + width - LibraryGeometry.inset - total;
      commands.add(HudFillCommand(
        HudRectF(
          sortX - LibraryGeometry.sortDividerOffset,
          y + LibraryGeometry.tabTop + 6,
          1,
          LibraryGeometry.tabHeight - 12,
        ),
        HudPalette.faintInk(ink, 0.18),
      ));
      for (int index = 0; index < labels.length; index++) {
        final String label = labels[index];
        final bool active = s.groupBy == keys[index];
        hits.add(HudHit(
          x: sortX - 4,
          y: y + LibraryGeometry.tabTop,
          width: widths[index] + 8,
          height: LibraryGeometry.tabHeight,
          action: 'music:group:$index',
          label: label,
        ));
        commands.add(HudTextCommand(
          label,
          sortX,
          y + LibraryGeometry.tabTop + 11,
          11,
          weight: active ? 'demibold' : 'regular',
          color: active ? ink : muted,
        ));
        if (active) {
          commands.add(HudFillCommand(
            HudRectF(
              sortX,
              y +
                  LibraryGeometry.tabTop +
                  LibraryGeometry.tabHeight -
                  LibraryGeometry.sortUnderline,
              widths[index],
              LibraryGeometry.sortUnderline,
            ),
            gold,
          ));
        }
        sortX += widths[index] + LibraryGeometry.sortStep;
      }
    }

    commands.add(HudFillCommand(
      HudRectF(
        left,
        y + LibraryGeometry.tabTop + LibraryGeometry.tabHeight,
        usable,
        1,
      ),
      HudPalette.faintInk(ink, LibraryGeometry.ruleTabOpacity),
    ));

    commands.add(HudTextCommand(
      'ID / 编号',
      left,
      y + LibraryGeometry.tableY,
      9,
      tracking: 0.07,
      color: muted,
    ));
    commands.add(HudTextCommand(
      'TITLE / 音乐',
      left + LibraryGeometry.titleX,
      y + LibraryGeometry.tableY,
      9,
      tracking: 0.07,
      color: muted,
    ));
    commands.add(HudTextCommand(
      'OPEN',
      x + width - LibraryGeometry.actionWidth,
      y + LibraryGeometry.tableY,
      9,
      tracking: 0.07,
      color: muted,
    ));
    commands.add(HudFillCommand(
      HudRectF(left, y + LibraryGeometry.tableY + 16, usable, 1),
      HudPalette.faintInk(ink, LibraryGeometry.ruleHeaderOpacity),
    ));

    if (s.activeGroup.isNotEmpty) {
      final double labelWidth = metrics.width(LibraryGeometry.groupBackText, 11) +
          LibraryGeometry.groupBackPad;
      final double actionX = x +
          width -
          LibraryGeometry.inset -
          LibraryGeometry.groupBackReserve -
          labelWidth;
      hits.add(HudHit(
        x: actionX,
        y: y + LibraryGeometry.tableY + LibraryGeometry.groupBackOffsetY,
        width: labelWidth,
        height: LibraryGeometry.groupBackHeight,
        action: 'music:group-back',
        label: LibraryGeometry.groupBackLabel,
      ));
      commands.add(HudTextCommand(
        LibraryGeometry.groupBackText,
        actionX + 8,
        y + LibraryGeometry.tableY,
        11,
        color: ink,
      ));
    }
  }

  // -- libraryOutlineButton ------------------------------------------------
  // @see Qt/src/NativeHudLibrary.cpp:74-93
  void _outlineButton({
    required List<HudCommand> commands,
    required List<HudHit> hits,
    required HudRectF rect,
    required String label,
    required String action,
    required double size,
    required bool plus,
    required bool dark,
  }) {
    final HudColor ink = HudPalette.ink(dark: dark);
    final HudColor line = HudPalette.faintInk(ink, 0.25);
    commands.add(HudFillCommand(rect, HudPalette.libraryPanelFill(dark: dark)));
    commands.add(HudFillCommand(HudRectF(rect.left, rect.top, rect.width, 1), line));
    commands.add(
        HudFillCommand(HudRectF(rect.left, rect.bottom - 1, rect.width, 1), line));
    commands
        .add(HudFillCommand(HudRectF(rect.left, rect.top, 1, rect.height), line));
    commands.add(
        HudFillCommand(HudRectF(rect.right - 1, rect.top, 1, rect.height), line));

    if (plus) {
      final double textWidth = metrics.width(label, size);
      final double start = rect.centerX - (12 + 8 + textWidth) / 2;
      commands.add(HudFillCommand(
        HudRectF(start + 5.25, rect.centerY - 6, 1.5, 12),
        HudPalette.faintInk(ink, 0.55),
      ));
      commands.add(HudFillCommand(
        HudRectF(start, rect.centerY - 0.75, 12, 1.5),
        HudPalette.faintInk(ink, 0.55),
      ));
      _centeredText(
        commands: commands,
        value: label,
        x: start + 20,
        cy: rect.centerY,
        size: size,
        horizontal: false,
        color: ink,
      );
    } else {
      _centeredText(
        commands: commands,
        value: label,
        x: rect.centerX,
        cy: rect.centerY,
        size: size,
        horizontal: true,
        color: ink,
      );
    }
    hits.add(HudHit(
      x: rect.left,
      y: rect.top,
      width: rect.width,
      height: rect.height,
      action: action,
      label: label,
    ));
  }

  /// centeredText()：Qt/src/NativeHud.cpp:80-85
  void _centeredText({
    required List<HudCommand> commands,
    required String value,
    required double x,
    required double cy,
    required double size,
    required bool horizontal,
    required HudColor color,
  }) {
    final LibraryTextBounds b = metrics.bounds(value, size);
    commands.add(HudTextCommand(
      value,
      x - b.x - (horizontal ? b.width / 2 : 0),
      cy - b.y - b.height / 2,
      size,
      color: color,
    ));
  }

  // -- libraryResultList ---------------------------------------------------
  // @see Qt/src/NativeHudLibrary.cpp:182-226
  _ResultListOut _resultList({
    required List<HudCommand> commands,
    required List<HudHit> hits,
    required List<String> notes,
    required LibraryModalSnapshot s,
    required double x,
    required double y,
    required double width,
  }) {
    final double left = LibraryGeometry.contentLeft(x);
    final double usable = LibraryGeometry.usableWidth(width);
    final HudColor ink = HudPalette.ink(dark: s.dark);
    final HudRectF viewport = HudRectF(
      left,
      y + LibraryGeometry.resultListTop,
      usable,
      LibraryGeometry.viewportHeight,
    );
    final int rowCount = s.rows.length;
    final double maximum = LibraryGeometry.savedScrollMaximum(rowCount.toDouble());
    final double scroll = _clamp(s.savedScroll, 0, maximum);

    if (s.rows.isEmpty) {
      commands.add(HudTextCommand(
        metrics.fit(s.emptyMessage, 18, usable, weight: 'demibold'),
        left,
        y + LibraryGeometry.resultListTop + LibraryGeometry.emptyMessageOffsetY,
        18,
        weight: 'demibold',
        color: ink,
      ));
      if (s.loginEntryAllowed) {
        _outlineButton(
          commands: commands,
          hits: hits,
          rect: HudRectF(
            left,
            y +
                LibraryGeometry.resultListTop +
                LibraryGeometry.loginEntryOffsetY,
            LibraryGeometry.loginEntryWidth,
            LibraryGeometry.loginEntryHeight,
          ),
          label: '登录${s.providerName} →',
          action: 'music:login',
          size: 14,
          plus: false,
          dark: s.dark,
        );
      }
      return _ResultListOut(
        viewport: viewport,
        scroll: scroll,
        maximum: maximum,
        rowCount: rowCount,
        firstRowHit: hits.length,
      );
    }

    final int firstRowHit = hits.length;
    commands.add(const HudSaveCommand());
    commands.add(HudClipCommand(viewport));

    final LibraryRowPainter? painter = rowPainter;
    if (painter == null) {
      // 缺失依赖显式暴露：不绘制行、不生成行命中、不伪造内容。
      notes.add('row-painter-missing');
    } else {
      final int first = math.max(
        0,
        (scroll / LibraryGeometry.rowHeight).floor() - 1,
      );
      final int last = math.min(
        rowCount - 1,
        ((scroll + viewport.height) / LibraryGeometry.rowHeight).ceil() + 1,
      );
      for (int index = first; index <= last; index++) {
        final double rowY = y +
            LibraryGeometry.resultListTop +
            index * LibraryGeometry.rowHeight -
            scroll;
        painter.paintRow(
          row: s.rows[index],
          x: x,
          y: rowY,
          width: width,
          query: s.query,
          lane: s.musicCollection,
          out: (HudCommand command, HudHit? hit) {
            commands.add(command);
            if (hit != null) {
              hits.add(hit);
            }
          },
        );
      }
    }

    commands.add(const HudRestoreCommand());
    final List<HudHit> clipped = _clipHits(hits, firstRowHit, viewport);
    hits
      ..clear()
      ..addAll(clipped);

    final HudRectF track = HudRectF(
      x + width - 24,
      viewport.top + LibraryGeometry.railInset,
      LibraryGeometry.railWidth,
      viewport.height - LibraryGeometry.railInset * 2,
    );
    final _Rail rail = _computeRail(
      track: track,
      contentHeight: LibraryGeometry.savedContentHeight(rowCount.toDouble()),
      viewportHeight: viewport.height,
      offset: scroll,
      minThumbHeight: LibraryGeometry.railMinThumb,
    );
    commands.add(HudFillCommand(track, HudPalette.faintInk(ink, 0.10)));
    if (rail.visible) {
      commands.add(HudFillCommand(rail.thumb, HudPalette.faintInk(ink, 0.45)));
    }

    return _ResultListOut(
      viewport: viewport,
      scroll: scroll,
      maximum: maximum,
      rowCount: rowCount,
      firstRowHit: firstRowHit,
    );
  }

  /// HudScroll::clipHits。@see Qt/src/HudScroll.h:67-86
  static List<HudHit> _clipHits(List<HudHit> hits, int first, HudRectF area) {
    final List<HudHit> out = <HudHit>[];
    for (int index = 0; index < hits.length; index++) {
      final HudHit hit = hits[index];
      if (index < first) {
        out.add(hit);
        continue;
      }
      final HudRectF visible = hit.rect.intersected(area);
      if (visible.isEmpty) {
        continue;
      }
      out.add(hit.withRect(visible));
    }
    return out;
  }

  /// HudScroll::rail。@see Qt/src/HudScroll.h:50-64
  static _Rail _computeRail({
    required HudRectF track,
    required double contentHeight,
    required double viewportHeight,
    required double offset,
    double minThumbHeight = 30,
  }) {
    final double range = math.max(0.0, contentHeight - viewportHeight);
    if (range <= 0 || track.height <= 0) {
      return _Rail(
          visible: false, track: track, thumb: const HudRectF(0, 0, 0, 0));
    }
    final double low = math.min(minThumbHeight, track.height);
    final double thumbHeight =
        _clamp(track.height * viewportHeight / contentHeight, low, track.height);
    final double thumbY =
        track.top + _clamp(offset / range, 0, 1) * (track.height - thumbHeight);
    return _Rail(
      visible: true,
      track: track,
      thumb: HudRectF(track.left, thumbY, track.width, thumbHeight),
    );
  }

  // -- libraryFooter -------------------------------------------------------
  // @see Qt/src/NativeHudLibrary.cpp:228-250
  void _footer({
    required List<HudCommand> commands,
    required LibraryModalSnapshot s,
    required double x,
    required double y,
    required double width,
  }) {
    final HudColor muted = HudPalette.mutedInk(HudPalette.ink(dark: s.dark));
    commands.add(HudFillCommand(
      HudRectF(
        x + LibraryGeometry.inset,
        y + LibraryGeometry.footerY + LibraryGeometry.footerSquareOffsetY,
        LibraryGeometry.footerSquare,
        LibraryGeometry.footerSquare,
      ),
      HudPalette.accent,
    ));
    commands.add(HudTextCommand(
      metrics.fit(
        s.status,
        LibraryGeometry.footerStatusSize,
        width - LibraryGeometry.footerStatusMaxReduction,
      ),
      x + LibraryGeometry.inset + LibraryGeometry.footerTextOffsetX,
      y + LibraryGeometry.footerY,
      LibraryGeometry.footerStatusSize,
      color: muted,
    ));

    if (s.loadedCount == 0 && !s.sourceLoading) {
      return;
    }
    // Qt 的测量不带 tracking（NativeHudLibrary.cpp:248），tracking 只用于绘制。
    final double labelWidth =
        metrics.width(s.footerLabel, LibraryGeometry.footerHintSize);
    commands.add(HudTextCommand(
      s.footerLabel,
      x + width - LibraryGeometry.inset - labelWidth,
      y + LibraryGeometry.footerY,
      LibraryGeometry.footerHintSize,
      tracking: LibraryGeometry.footerHintTracking,
      color: muted,
    ));
  }
}

/// 结果列表内部产出。
class _ResultListOut {
  const _ResultListOut({
    required this.viewport,
    required this.scroll,
    required this.maximum,
    required this.rowCount,
    required this.firstRowHit,
  });

  final HudRectF viewport;
  final double scroll;
  final double maximum;
  final int rowCount;
  final int firstRowHit;
}

/// rail 结果，对应 HudScroll::Rail。
class _Rail {
  const _Rail({
    required this.visible,
    required this.track,
    required this.thumb,
  });

  final bool visible;
  final HudRectF track;
  final HudRectF thumb;
}

// ---------------------------------------------------------------------------
// 12. 控制器：自动补页去重 + 动作分派
// ---------------------------------------------------------------------------

/// 面板控制器。ensureSavedFilled 逐行照搬 Qt 的去重语义。
/// @see Qt/src/NativeHudLibrary.cpp:256-268
class LibraryModalController {
  LibraryModalController({required this.ports});

  final LibraryModalPorts ports;

  /// Qt: int m_savedAutoFillSize = -1; @see Qt/src/NativeHud.h:198
  int _savedAutoFillSize = -1;

  int get savedAutoFillSize => _savedAutoFillSize;

  /// 面板重开时复位（对应 Qt 构造初值 -1）。
  void resetAutoFill() {
    _savedAutoFillSize = -1;
  }

  /// 首屏不足一屏时自动补页；同一条数只补一次，避免空页循环。
  /// @see Qt/src/NativeHudLibrary.cpp:256-268
  bool ensureSavedFilled({
    required LibraryModalSnapshot s,
    required bool closing,
  }) {
    if (s.modal != 'saved' || closing || s.sourceLoading || !s.hasMore) {
      return false;
    }
    final int count = s.rows.length;
    if (count <= _savedAutoFillSize) {
      return false;
    }
    _savedAutoFillSize = count;
    if (count * LibraryGeometry.rowHeight < LibraryGeometry.viewportHeight) {
      ports.loadMoreSaved();
      return true;
    }
    return false;
  }

  /// 动作字符串 → 端口方法。未识别的 action 返回 false（不静默吞掉语义）。
  bool dispatch(String action) {
    switch (action) {
      case 'music:create-playlist':
        ports.createPlaylist();
        return true;
      case 'music:refresh-personal':
        ports.refreshPersonal();
        return true;
      case 'music:group-back':
        ports.backToAllGroups();
        return true;
      case 'music:login':
        ports.openLogin();
        return true;
      case 'close-modal':
        ports.closeModal();
        return true;
    }
    if (action.startsWith('music:collection:')) {
      final int? index =
          int.tryParse(action.substring('music:collection:'.length));
      if (index == null) {
        return false;
      }
      ports.selectCollection(index);
      return true;
    }
    if (action.startsWith('music:group:')) {
      final int? index = int.tryParse(action.substring('music:group:'.length));
      if (index == null ||
          index < 0 ||
          index >= LibraryModalSnapshot.groupKeys.length) {
        return false;
      }
      ports.setGroupKey(LibraryModalSnapshot.groupKeys[index]);
      return true;
    }
    return false;
  }

  /// 命中分发。
  bool dispatchHit(HudHit hit) => dispatch(hit.action);

  /// 滚动：夹到合法范围后交给端口。@see Qt/src/HudScroll.h:17-19
  void scrollTo(double offset, {required double savedRowCount}) {
    final double maximum = LibraryGeometry.savedScrollMaximum(savedRowCount);
    ports.scrollSaved(_clamp(offset, 0, maximum));
  }
}

// ---------------------------------------------------------------------------
// 13. 竖屏响应式（新规格；Qt Android 无竖屏证据）
// ---------------------------------------------------------------------------

/// 竖屏形态断点。
enum LibraryPortraitForm {
  /// 宽度 < 600
  compact,

  /// 600 ≤ 宽度 < 900
  medium,

  /// 宽度 ≥ 900
  expanded,
}

/// 竖屏规格。
///
/// 竖屏无 Qt 像素证据，按源码规格：Qt Android 只提供横屏像素，因此本节的
/// 断点、栏高、行高、间距都是新增规格；语义（动作 id / 命中 / 状态 / 文案）
/// 与横屏完全一致，但几何不得被当作 Qt 竖屏像素引用。
abstract final class LibraryPortraitSpec {
  static const double compactMaxWidth = 600;
  static const double mediumMaxWidth = 900;

  static const double gutterCompact = 16;
  static const double gutterMedium = 20;
  static const double gutterExpanded = 24;

  static const double barHeight = 52;
  static const double barGap = 12;
  static const double actionRowHeight = 44;
  static const double tabHeight = 40;
  static const double tabStep = 20;
  static const double tabUnderline = 3;
  static const double sortUnderline = 2;
  static const double listHeaderHeight = 28;
  static const double rowHeight = 64;
  static const double footerHeight = 32;
  static const double railWidth = 3;
  static const double railMinThumb = 30;

  /// 与横屏相同的透明度语义。
  /// @see Qt/src/NativeHudLibrary.cpp:167,171
  static const double ruleTabOpacity = 0.18;
  static const double ruleHeaderOpacity = 0.24;

  static const String queryLabel = 'QUERY / 检索词';
  static const String createLabel = '创建歌单';
  static const String refreshLabel = '刷新个人库';
  static const String idHeader = 'ID / 编号';
  static const String titleHeader = 'TITLE / 音乐';
  static const String openHeader = 'OPEN';
  static const String groupBackText = '← 全部分组';
  static const String groupBackLabel = '全部分组';

  static LibraryPortraitForm resolveForm(double width) {
    if (width < compactMaxWidth) {
      return LibraryPortraitForm.compact;
    }
    if (width < mediumMaxWidth) {
      return LibraryPortraitForm.medium;
    }
    return LibraryPortraitForm.expanded;
  }

  static double gutterFor(LibraryPortraitForm form) {
    switch (form) {
      case LibraryPortraitForm.compact:
        return gutterCompact;
      case LibraryPortraitForm.medium:
        return gutterMedium;
      case LibraryPortraitForm.expanded:
        return gutterExpanded;
    }
  }
}

/// 竖屏布局计划：按宽度与可用高度把各段堆叠起来。
class LibraryPortraitPlan {
  const LibraryPortraitPlan({
    required this.form,
    required this.gutter,
    required this.barRect,
    required this.actionRowRect,
    required this.tabRect,
    required this.sortRect,
    required this.headerRect,
    required this.viewport,
    required this.footerRect,
    required this.tabRuleY,
    required this.headerRuleY,
    required this.rowHeight,
  });

  final LibraryPortraitForm form;
  final double gutter;
  final HudRectF barRect;
  final HudRectF actionRowRect;
  final HudRectF tabRect;
  final HudRectF sortRect;
  final HudRectF headerRect;
  final HudRectF viewport;
  final HudRectF footerRect;
  final double tabRuleY;
  final double headerRuleY;
  final double rowHeight;

  /// 竖屏堆叠（新规格）：工具条 → 动作行 → 标签行 → 排序行 → 表头 → 列表 → footer。
  static LibraryPortraitPlan resolve({
    required double x,
    required double y,
    required double width,
    required double height,
  }) {
    final LibraryPortraitForm form = LibraryPortraitSpec.resolveForm(width);
    final double gutter = LibraryPortraitSpec.gutterFor(form);
    final double contentLeft = x + gutter;
    final double contentWidth = width - gutter * 2;

    final HudRectF bar = HudRectF(
      contentLeft,
      y,
      contentWidth,
      LibraryPortraitSpec.barHeight,
    );
    final HudRectF actionRow = HudRectF(
      contentLeft,
      bar.bottom + LibraryPortraitSpec.barGap,
      contentWidth,
      LibraryPortraitSpec.actionRowHeight,
    );
    final HudRectF tab = HudRectF(
      contentLeft,
      actionRow.bottom + LibraryPortraitSpec.barGap,
      contentWidth,
      LibraryPortraitSpec.tabHeight,
    );
    final double tabRuleY = tab.bottom;
    final HudRectF sort = HudRectF(
      contentLeft,
      tabRuleY + LibraryPortraitSpec.barGap,
      contentWidth,
      LibraryPortraitSpec.tabHeight,
    );
    final HudRectF header = HudRectF(
      contentLeft,
      sort.bottom + 6,
      contentWidth,
      LibraryPortraitSpec.listHeaderHeight,
    );
    final double headerRuleY = header.bottom;
    final HudRectF footer = HudRectF(
      contentLeft,
      y + height - LibraryPortraitSpec.footerHeight,
      contentWidth,
      LibraryPortraitSpec.footerHeight,
    );
    final double viewportTop = headerRuleY + 1;
    final double viewportHeight = math.max(0.0, footer.top - 6 - viewportTop);
    final HudRectF viewport = HudRectF(
      contentLeft,
      viewportTop,
      contentWidth,
      viewportHeight,
    );

    return LibraryPortraitPlan(
      form: form,
      gutter: gutter,
      barRect: bar,
      actionRowRect: actionRow,
      tabRect: tab,
      sortRect: sort,
      headerRect: header,
      viewport: viewport,
      footerRect: footer,
      tabRuleY: tabRuleY,
      headerRuleY: headerRuleY,
      rowHeight: LibraryPortraitSpec.rowHeight,
    );
  }
}

/// 竖屏 saved 面板：语义（动作 / 命中 / 状态 / 文案）与横屏一致，几何为新规格。
class LibraryPortraitPanel {
  const LibraryPortraitPanel({required this.metrics, this.rowPainter});

  final LibraryTextMetrics metrics;
  final LibraryRowPainter? rowPainter;

  /// 竖屏无 Qt 像素证据，按源码规格。
  LibraryModalFrame build({
    required LibraryModalSnapshot s,
    required double x,
    required double y,
    required double width,
    required double height,
  }) {
    final List<HudCommand> commands = <HudCommand>[];
    final List<HudHit> hits = <HudHit>[];
    final List<String> notes = <String>['portrait-layout-is-new-spec-no-qt-pixels'];
    final LibraryPortraitPlan plan =
        LibraryPortraitPlan.resolve(x: x, y: y, width: width, height: height);
    final HudColor ink = HudPalette.ink(dark: s.dark);
    final HudColor muted = HudPalette.mutedInk(ink);
    const HudColor gold = HudPalette.accent;

    commands.add(HudFillCommand(
      plan.barRect,
      HudPalette.libraryBarFill(dark: s.dark),
    ));
    commands.add(HudFillCommand(
      HudRectF(plan.barRect.left, plan.barRect.top, 3, plan.barRect.height),
      gold,
    ));
    commands.add(HudTextCommand(
      LibraryPortraitSpec.queryLabel,
      plan.barRect.left + 18,
      plan.barRect.top + 10,
      9,
      tracking: 0.08,
      color: muted,
    ));

    double actionRight = plan.actionRowRect.right;
    if (s.canCreatePlaylist) {
      final HudRectF create = HudRectF(
        actionRight - LibraryGeometry.createWidth,
        plan.actionRowRect.top,
        LibraryGeometry.createWidth,
        plan.actionRowRect.height,
      );
      _outlineButton(
        commands: commands,
        hits: hits,
        rect: create,
        label: LibraryPortraitSpec.createLabel,
        action: 'music:create-playlist',
        size: 13,
        plus: true,
        dark: s.dark,
      );
      actionRight = create.left - LibraryGeometry.actionGap;
    }
    if (s.canRefreshPersonal) {
      final HudRectF refresh = HudRectF(
        actionRight - LibraryGeometry.refreshWidth,
        plan.actionRowRect.top,
        LibraryGeometry.refreshWidth,
        plan.actionRowRect.height,
      );
      _outlineButton(
        commands: commands,
        hits: hits,
        rect: refresh,
        label: LibraryPortraitSpec.refreshLabel,
        action: 'music:refresh-personal',
        size: 13,
        plus: false,
        dark: s.dark,
      );
    }

    final List<String> filters = s.tabLabels;
    final int selected = s.musicCollection - 1;
    double cursor = plan.tabRect.left;
    for (int index = 0; index < filters.length; index++) {
      final String label = filters[index];
      final double labelWidth = metrics.width(label, 13);
      final bool active = index == selected;
      if (cursor + labelWidth > plan.tabRect.right) {
        break; // 窄幅超出可视区即止；剩余标签由横向滚动承载（新规格）。
      }
      hits.add(HudHit(
        x: cursor - 4,
        y: plan.tabRect.top,
        width: labelWidth + 8,
        height: plan.tabRect.height,
        action: 'music:collection:${index + 1}',
        label: label,
      ));
      commands.add(HudTextCommand(
        label,
        cursor,
        plan.tabRect.top + 10,
        13,
        weight: active ? 'demibold' : 'regular',
        color: active ? ink : muted,
      ));
      if (active) {
        commands.add(HudFillCommand(
          HudRectF(
            cursor,
            plan.tabRect.bottom - LibraryPortraitSpec.tabUnderline,
            labelWidth,
            LibraryPortraitSpec.tabUnderline,
          ),
          gold,
        ));
      }
      cursor += labelWidth + LibraryPortraitSpec.tabStep;
    }
    commands.add(HudFillCommand(
      HudRectF(plan.tabRect.left, plan.tabRuleY, plan.tabRect.width, 1),
      HudPalette.faintInk(ink, LibraryPortraitSpec.ruleTabOpacity),
    ));

    if (s.hasSongs) {
      final List<String> labels = LibraryModalSnapshot.groupLabels;
      final List<String> keys = LibraryModalSnapshot.groupKeys;
      final List<double> widths = <double>[
        for (final String label in labels) metrics.width(label, 11),
      ];
      double total = 0;
      for (final double w in widths) {
        total += w;
      }
      total += LibraryPortraitSpec.tabStep * (labels.length - 1);
      double sortX = plan.sortRect.right - total;
      for (int index = 0; index < labels.length; index++) {
        final bool active = s.groupBy == keys[index];
        hits.add(HudHit(
          x: sortX - 4,
          y: plan.sortRect.top,
          width: widths[index] + 8,
          height: plan.sortRect.height,
          action: 'music:group:$index',
          label: labels[index],
        ));
        commands.add(HudTextCommand(
          labels[index],
          sortX,
          plan.sortRect.top + 11,
          11,
          weight: active ? 'demibold' : 'regular',
          color: active ? ink : muted,
        ));
        if (active) {
          commands.add(HudFillCommand(
            HudRectF(
              sortX,
              plan.sortRect.bottom - LibraryPortraitSpec.sortUnderline,
              widths[index],
              LibraryPortraitSpec.sortUnderline,
            ),
            gold,
          ));
        }
        sortX += widths[index] + LibraryPortraitSpec.tabStep;
      }
    }

    if (s.activeGroup.isNotEmpty) {
      final double labelWidth = metrics.width(LibraryPortraitSpec.groupBackText, 11) +
          LibraryGeometry.groupBackPad;
      final double actionX = plan.headerRect.right - labelWidth;
      hits.add(HudHit(
        x: actionX,
        y: plan.headerRect.top,
        width: labelWidth,
        height: plan.headerRect.height,
        action: 'music:group-back',
        label: LibraryPortraitSpec.groupBackLabel,
      ));
      commands.add(HudTextCommand(
        LibraryPortraitSpec.groupBackText,
        actionX + 8,
        plan.headerRect.top + 8,
        11,
        color: ink,
      ));
    }

    commands.add(HudTextCommand(
      LibraryPortraitSpec.idHeader,
      plan.headerRect.left,
      plan.headerRect.top + 8,
      9,
      tracking: 0.07,
      color: muted,
    ));
    commands.add(HudTextCommand(
      LibraryPortraitSpec.titleHeader,
      plan.headerRect.left + LibraryGeometry.titleX,
      plan.headerRect.top + 8,
      9,
      tracking: 0.07,
      color: muted,
    ));
    commands.add(HudTextCommand(
      LibraryPortraitSpec.openHeader,
      plan.headerRect.right - LibraryGeometry.actionWidth,
      plan.headerRect.top + 8,
      9,
      tracking: 0.07,
      color: muted,
    ));
    commands.add(HudFillCommand(
      HudRectF(plan.headerRect.left, plan.headerRuleY, plan.headerRect.width, 1),
      HudPalette.faintInk(ink, LibraryPortraitSpec.ruleHeaderOpacity),
    ));

    final int rowCount = s.rows.length;
    final double maximum =
        math.max(0.0, rowCount * plan.rowHeight - plan.viewport.height);
    final double scroll = _clamp(s.savedScroll, 0, maximum);
    final int firstRowHit = hits.length;

    if (s.rows.isEmpty) {
      commands.add(HudTextCommand(
        metrics.fit(s.emptyMessage, 18, plan.viewport.width, weight: 'demibold'),
        plan.viewport.left,
        plan.viewport.top + LibraryGeometry.emptyMessageOffsetY,
        18,
        weight: 'demibold',
        color: ink,
      ));
      if (s.loginEntryAllowed) {
        _outlineButton(
          commands: commands,
          hits: hits,
          rect: HudRectF(
            plan.viewport.left,
            plan.viewport.top + LibraryGeometry.loginEntryOffsetY,
            math.min(LibraryGeometry.loginEntryWidth, plan.viewport.width),
            LibraryGeometry.loginEntryHeight,
          ),
          label: '登录${s.providerName} →',
          action: 'music:login',
          size: 14,
          plus: false,
          dark: s.dark,
        );
      }
    } else {
      commands.add(const HudSaveCommand());
      commands.add(HudClipCommand(plan.viewport));
      final LibraryRowPainter? painter = rowPainter;
      if (painter == null) {
        notes.add('row-painter-missing');
      } else {
        final int first = math.max(0, (scroll / plan.rowHeight).floor() - 1);
        final int last = math.min(
          rowCount - 1,
          ((scroll + plan.viewport.height) / plan.rowHeight).ceil() + 1,
        );
        for (int index = first; index <= last; index++) {
          final double rowY = plan.viewport.top + index * plan.rowHeight - scroll;
          painter.paintRow(
            row: s.rows[index],
            x: plan.viewport.left,
            y: rowY,
            width: plan.viewport.width,
            query: s.query,
            lane: s.musicCollection,
            out: (HudCommand command, HudHit? hit) {
              commands.add(command);
              if (hit != null) {
                hits.add(hit);
              }
            },
          );
        }
      }
      commands.add(const HudRestoreCommand());
      hits
        ..clear()
        ..addAll(LibrarySavedPanel._clipHits(hits, firstRowHit, plan.viewport));

      final HudRectF track = HudRectF(
        plan.viewport.right - 8,
        plan.viewport.top + 8,
        LibraryPortraitSpec.railWidth,
        math.max(0.0, plan.viewport.height - 16),
      );
      commands.add(HudFillCommand(track, HudPalette.faintInk(ink, 0.10)));
      if (rowCount * plan.rowHeight > plan.viewport.height) {
        final double thumbHeight = math.max(
          math.min(LibraryPortraitSpec.railMinThumb, track.height),
          track.height * plan.viewport.height / (rowCount * plan.rowHeight),
        );
        final double thumbY = track.top +
            (maximum <= 0 ? 0.0 : scroll / maximum) * (track.height - thumbHeight);
        commands.add(HudFillCommand(
          HudRectF(track.left, thumbY, track.width, thumbHeight),
          HudPalette.faintInk(ink, 0.45),
        ));
      }
    }

    final HudRectF footer = plan.footerRect;
    commands.add(HudFillCommand(
      HudRectF(
        footer.left,
        footer.top + LibraryGeometry.footerSquareOffsetY,
        LibraryGeometry.footerSquare,
        LibraryGeometry.footerSquare,
      ),
      gold,
    ));
    commands.add(HudTextCommand(
      metrics.fit(
        s.status,
        LibraryGeometry.footerStatusSize,
        footer.width - LibraryGeometry.footerStatusMaxReduction,
      ),
      footer.left + LibraryGeometry.footerTextOffsetX,
      footer.top,
      LibraryGeometry.footerStatusSize,
      color: muted,
    ));
    if (!(s.loadedCount == 0 && !s.sourceLoading)) {
      // Qt 的测量不带 tracking（NativeHudLibrary.cpp:248），tracking 只用于绘制。
      final double labelWidth =
          metrics.width(s.footerLabel, LibraryGeometry.footerHintSize);
      commands.add(HudTextCommand(
        s.footerLabel,
        footer.right - labelWidth,
        footer.top,
        LibraryGeometry.footerHintSize,
        tracking: LibraryGeometry.footerHintTracking,
        color: muted,
      ));
    }

    return LibraryModalFrame(
      commands: commands,
      hits: hits,
      viewport: plan.viewport,
      savedScroll: scroll,
      savedScrollMaximum: maximum,
      savedRowCount: rowCount,
      firstRowHit: firstRowHit,
      notes: notes,
    );
  }

  void _outlineButton({
    required List<HudCommand> commands,
    required List<HudHit> hits,
    required HudRectF rect,
    required String label,
    required String action,
    required double size,
    required bool plus,
    required bool dark,
  }) {
    final HudColor ink = HudPalette.ink(dark: dark);
    final HudColor line = HudPalette.faintInk(ink, 0.25);
    commands.add(HudFillCommand(rect, HudPalette.libraryPanelFill(dark: dark)));
    commands.add(HudFillCommand(HudRectF(rect.left, rect.top, rect.width, 1), line));
    commands.add(
        HudFillCommand(HudRectF(rect.left, rect.bottom - 1, rect.width, 1), line));
    commands
        .add(HudFillCommand(HudRectF(rect.left, rect.top, 1, rect.height), line));
    commands.add(
        HudFillCommand(HudRectF(rect.right - 1, rect.top, 1, rect.height), line));
    if (plus) {
      final double textWidth = metrics.width(label, size);
      final double start = rect.centerX - (12 + 8 + textWidth) / 2;
      commands.add(HudFillCommand(
        HudRectF(start + 5.25, rect.centerY - 6, 1.5, 12),
        HudPalette.faintInk(ink, 0.55),
      ));
      commands.add(HudFillCommand(
        HudRectF(start, rect.centerY - 0.75, 12, 1.5),
        HudPalette.faintInk(ink, 0.55),
      ));
      final LibraryTextBounds b = metrics.bounds(label, size);
      commands.add(HudTextCommand(
        label,
        start + 20 - b.x,
        rect.centerY - b.y - b.height / 2,
        size,
        color: ink,
      ));
    } else {
      final LibraryTextBounds b = metrics.bounds(label, size);
      commands.add(HudTextCommand(
        label,
        rect.centerX - b.x - b.width / 2,
        rect.centerY - b.y - b.height / 2,
        size,
        color: ink,
      ));
    }
    hits.add(HudHit(
      x: rect.left,
      y: rect.top,
      width: rect.width,
      height: rect.height,
      action: action,
      label: label,
    ));
  }
}
