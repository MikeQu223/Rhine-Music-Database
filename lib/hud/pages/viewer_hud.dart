/// Qt 查看器 HUD（stage 单位）的纯数据构建器。
///
/// 真值来源（逐字移植，行号对应 Qt/src）：
/// - NativeHudDetail.cpp:513-529  viewer() 整页命令序列（11 条 text、6 条 hit，无 save/alpha/restore）
/// - NativeHudDetail.cpp:514-516  空 current 早退：item.isEmpty() 时零命令零命中
/// - NativeHud.cpp:267-268        分派：frame["viewer"].toBool() 为真时只画 viewer()，
///                                不画 brand / navigation / footer / archive / detail
/// - NativeHud.cpp:306-311        宿主在 viewer() 之后追加 modalDraw(width) 与 playerBar(0, 984, width)
/// - NativeHud.cpp:10-15          ink()：dark ? [0.92,0.92,0.92,1,"calibratedWhite"]
///                                         : [0.08,0.085,0.075,1,"calibratedRGB"]
/// - NativeHud.cpp:40-43          text()：['text', value, x, y, size, weight, tracking, color]
/// - NativeHud.cpp:48-79          fit() / limited()：超宽二分最长前缀，截断取 left(length-1)+"…"
/// - NativeHud.cpp:102-109        hit()：六字段，label 为 null 时回落 action
/// - NativeHud.cpp:110-120        button()：m_modalControls=false 时 = hit + text(x, y+(h-size)/2-4)
/// - NativeHud.h:222              m_modalControls 默认 false，且只在 modalDraw 内部被置真（NativeHudModal.cpp:94-255）
/// - NativeViewer.cpp:278-282     frame() 在 !m_open 时直接返回 base（不写 viewer / viewerReady 键）
/// - NativeViewer.cpp:349-353     viewerState {transition, surface, exploded, stats}；stats（:336-348）
///                               内含 clarity / targetClarity / resetting
/// - NativeViewer.cpp:108-130     action() 的 scene 侧仲裁（本页只在 viewerHudActionAccepted 里镜像）
/// - NativeViewer.h:36-63         成员默认值：transition="closed"、surface="clear"、targetClarity=1
///
/// 契约：
/// 1. 纯 Dart：只依赖 dart:math，不 import Flutter / dart:ui，也不 import 本仓其它 HUD 文件。
///    命令与命中以普通 JSON 形态返回，宿主按同代规则原样 append 进整帧：不排序、不去重、
///    不合并，顺序即语义（NativeHud::draw 先 commands = {}; hits = {}; 再按调用顺序重发）。
/// 2. 命中一律六字段 x/width/height/action/label（NativeHud.cpp:102-109），绝不输出 fixed：
///    fixed 只属于 PlayerBar（PlayerBar.cpp:46-53）。
/// 3. viewer 页没有 save / alpha / restore 包裹（与 detail() 不同），也没有 fill / rule / image；
///    11 条 text 与 6 条 hit 是全部输出。
/// 4. 文字颜色全部走 NativeHud::ink()（带 calibrated 标记）；消费端负责 Gamma 1.8 -> sRGB。
/// 5. 不得把 HUD 画进 3D 纹理：本页只输出 2D 舞台命令。查看器的封面与展厅由场景 draw 通道
///    渲染（NativeCards.cpp），HUD 命令流永远不是 3D 贴图来源。
/// 6. opening / closing / reset / clarity / frosted 是 viewerState 的状态字段，对绘制没有任何
///    影响 —— NativeHud::viewer() 根本不读它们；任何 transition / surface / clarity 组合下，
///    本页都产出同样的 11 条命令与 6 条命中。宿主用这些字段 + [viewerHudActionAccepted]
///    复现 NativeViewer::action() 的仲裁，但那是 scene 的行为，不是 HUD 的绘制条件。
/// 7. "music:cover-front" 不经过 NativeViewer::action：NativeHudController.cpp 把它转给
///    NativeHudMusic.cpp:374-375，再到 NativeViewer::coverFront（NativeViewer.cpp:99-107），
///    该函数没有 m_open / m_ready 门禁，因此它不在 [viewerHudActionAccepted] 的判定范围内。
library;

import 'dart:math' as math;

/// 舞台矩形（Qt stage 单位，1920 基准宽）。
class ViewerHudRect {
  const ViewerHudRect(this.x, this.y, this.width, this.height);

  final double x;
  final double y;
  final double width;
  final double height;

  double get left => x;
  double get top => y;
  double get right => x + width;
  double get bottom => y + height;

  @override
  String toString() => 'ViewerHudRect($x, $y, $width, $height)';
}

/// Qt m_music->current 中被 viewer() 读取的两个字段（NativeHudDetail.cpp:514, 520, 521）。
///
/// Qt 用 item.isEmpty() 判断"没有当前条目"（空 QJsonObject 也算空），适配层必须把这种
/// 状态映射成 null；反过来，只要对象里有 title / id 键（哪怕值是空串），Qt 就会照常绘制，
/// 对应非 null 的 ViewerHudItem。title / id 缺失时 Qt 的 toString() 得到空串，因此两者默认空串。
class ViewerHudItem {
  const ViewerHudItem({this.id = '', this.title = ''});

  final String id;
  final String title;

  @override
  String toString() => 'ViewerHudItem($id, $title)';
}

/// 查看器状态切片（Qt NativeViewer 的只读快照 + 当前条目）。
///
/// 字段 ↔ Qt 调用点：
///   item              NativeHudDetail.cpp:514/520/521（m_music->current 的 title / id）
///   dark              NativeHud.cpp:11-14（ink() 唯一输入）
///   transition        NativeViewer.cpp:350（viewerState.transition）
///   surface           NativeViewer.cpp:351（viewerState.surface）
///   clarity           NativeViewer.cpp:337（stats.clarity，SceneMotion::Spring::value）
///   targetClarity     NativeViewer.cpp:338（stats.targetClarity；1=清晰，0=磨砂）
///   resetting         NativeViewer.cpp:346（stats.resetting）
///   ready             NativeViewer.cpp:282（viewerReady / m_ready）
///
/// 这些字段全部不参与 viewer() 的绘制（见文件契约 6），只供宿主复现 scene 仲裁。
class ViewerHudState {
  const ViewerHudState({
    this.item,
    this.dark = false,
    this.transition = viewerHudTransitionClosed,
    this.surface = viewerHudSurfaceClear,
    this.clarity = 1.0,
    this.targetClarity = 1.0,
    this.resetting = false,
    this.ready = false,
  });

  /// Qt m_music->current；null 等价于 item.isEmpty()（NativeHudDetail.cpp:514-516）。
  final ViewerHudItem? item;

  /// Qt NativeHud::dark（NativeHud.cpp:11-14）。
  final bool dark;

  /// viewerState.transition：closed / opening / open / closing（NativeViewer.cpp:350）。
  final String transition;

  /// viewerState.surface：clear / frosted（NativeViewer.cpp:351）。
  final String surface;

  /// stats.clarity：SceneMotion::Spring 的当前值，0..1（NativeViewer.cpp:337）。
  final double clarity;

  /// stats.targetClarity：1 = 清晰，0 = 磨砂（NativeViewer.cpp:338 / NativeViewer.h:53）。
  final double targetClarity;

  /// stats.resetting：复位动画是否进行中（NativeViewer.cpp:346）。
  final bool resetting;

  /// viewerReady：素材就绪后 viewer:* 动作才被 scene 接受（NativeViewer.cpp:282, 119-129）。
  final bool ready;

  /// transition == "opening"。
  bool get opening => transition == viewerHudTransitionOpening;

  /// transition == "closing"；此时 m_open 仍为 true（NativeViewer.cpp:115, 215），
  /// 所以 frame["viewer"] 仍为真、本页照常绘制，但 scene 忽略所有 viewer:* 动作。
  bool get closing => transition == viewerHudTransitionClosing;

  /// 对应 NativeViewer::isOpen()（NativeViewer.cpp:20-22）：closing 期间仍为 true。
  bool get isOpen => transition != viewerHudTransitionClosed;

  /// viewerState.surface == "frosted"。
  bool get frosted => surface == viewerHudSurfaceFrosted;

  /// viewerState.surface == "clear"。
  bool get clear => surface == viewerHudSurfaceClear;

  /// 计划字段名 reset ≡ Qt m_resetting / stats.resetting。
  bool get reset => resetting;

  /// 关闭按钮的动作名（NativeHudDetail.cpp:518）。宿主把它交给
  /// NativeHudController.cpp:670-672，去掉 "viewer:" 前缀后由 NativeViewer::action 处理。
  String get closeAction => viewerHudCloseAction;

  @override
  String toString() => 'ViewerHudState(item: $item, transition: $transition, '
      'surface: $surface, clarity: $clarity, targetClarity: $targetClarity, '
      'resetting: $resetting, ready: $ready, dark: $dark)';
}

/// 由舞台宽度派生的 11 个锚点 / 矩形，逐项对应 NativeHudDetail.cpp:518-528。
///
/// 宽度是 viewer(width) 的唯一输入（NativeHud.cpp:224 draw(next, stageWidth, time)）；舞台高恒为 1080，
/// 因此所有纵向坐标都是常量。列在右侧的控制簇以宽度为基准相对定位。
class ViewerHudGeometry {
  const ViewerHudGeometry(this.width);

  final double width;

  double get center => width / 2;

  /// "← 返回音乐   ESC"（NativeHudDetail.cpp:518）。
  ViewerHudRect get close => const ViewerHudRect(59, 69, 300, 54);

  /// "RHINE LAB / MUSIC DATABASE / COVER" 的文本锚点（:519）。
  double get headingX => center - 145;
  double get headingY => 70;

  /// 曲名 + " / 封面" 的文本锚点与限宽（:520）。
  double get titleX => center - 145;
  double get titleY => 95;
  double get titleLimit => center - 250;

  /// item id 的文本锚点（:521）。
  double get idX => center - 145;
  double get idY => 139;

  /// "360°" 的文本锚点（:522）。
  double get degreeX => width - 185;
  double get degreeY => 72;

  /// "清晰"（:523）与 "磨砂"（:524）。
  ViewerHudRect get clear => ViewerHudRect(width - 247, 189, 84, 38);
  ViewerHudRect get frosted => ViewerHudRect(width - 147, 189, 84, 38);

  /// 底部提示的文本锚点（:525）。
  double get hintX => 59;
  double get hintY => 965;

  /// "原始视角"（:526）、"封面正面"（:527）、"复位视角 ↗"（:528）。
  ViewerHudRect get reset => ViewerHudRect(center - 165, 914, 154, 46);
  ViewerHudRect get coverFront => ViewerHudRect(center + 18, 914, 154, 46);
  ViewerHudRect get resetCorner => ViewerHudRect(width - 194, 914, 135, 46);
}

/// 字形度量端口（Qt Glyphs，Glyphs.h:25-28）；本页只用 width()。
abstract class ViewerHudGlyphsPort {
  /// Qt Glyphs::width(text, size, weight, tracking = 0)。
  double width(String value, double size, String weight, [double tracking = 0]);
}

/// 本页产出的命令与命中。
class ViewerHudDrawing {
  ViewerHudDrawing({required this.commands, required this.hits});

  /// 没有当前条目：NativeHudDetail.cpp:514-516 的早退，零命令零命中。
  ViewerHudDrawing.empty()
      : commands = <Object?>[],
        hits = <Map<String, Object?>>[];

  final List<Object?> commands;
  final List<Map<String, Object?>> hits;

  bool get isEmpty => commands.isEmpty && hits.isEmpty;
}

// 常量（文案 / 动作 / 状态字面量，逐字对应 Qt）

const String viewerHudCloseLabel = '← 返回音乐   ESC'; // NativeHudDetail.cpp:518
const String viewerHudHeading = 'RHINE LAB / MUSIC DATABASE / COVER'; // :519
const String viewerHudTitleSuffix = ' / 封面'; // :520
const String viewerHudDegree = '360°'; // :522
const String viewerHudClearLabel = '清晰'; // :523
const String viewerHudFrostedLabel = '磨砂'; // :524
const String viewerHudHint = '拖动旋转     ↑ ↓ ← → 平移     滚轮缩放'; // :525
const String viewerHudResetLabel = '原始视角'; // :526
const String viewerHudCoverFrontLabel = '封面正面'; // :527
const String viewerHudResetCornerLabel = '复位视角 ↗'; // :528

const String viewerHudCloseAction = 'viewer:close'; // :518
const String viewerHudClearAction = 'viewer:clear'; // :523
const String viewerHudFrostedAction = 'viewer:frosted'; // :524
const String viewerHudResetAction = 'viewer:reset'; // :526 / :528
const String viewerHudCoverFrontAction = 'music:cover-front'; // :527

const String viewerHudTransitionClosed = 'closed'; // NativeViewer.h:62
const String viewerHudTransitionOpening = 'opening'; // NativeViewer.cpp:45
const String viewerHudTransitionOpen = 'open'; // NativeViewer.cpp:223
const String viewerHudTransitionClosing = 'closing'; // NativeViewer.cpp:115
const String viewerHudSurfaceClear = 'clear'; // NativeViewer.h:63
const String viewerHudSurfaceFrosted = 'frosted'; // NativeViewer.cpp:124

/// 查看器 HUD 只走 2D 舞台通道；3D 封面由场景 draw 通道生成。
const String viewerHudChannel = 'hud-stage';

// 调色板（逐字对应 Qt）

/// Qt NativeHud::ink()（NativeHud.cpp:10-15）：带 calibrated 标记。
List<Object?> _hudInk(bool dark) => dark
    ? <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite']
    : <Object?>[0.08, 0.085, 0.075, 1, 'calibratedRGB'];

/// NativeViewer::action()（NativeViewer.cpp:108-130）的 HUD 侧镜像。
///
/// - [ViewerHudState.isOpen] 为假或 [ViewerHudState.closing] 为真时，scene 丢弃所有 viewer:*
///   动作（:123-125），close 也不例外；
/// - close 在 ready 之前也有效（:124-128）；
/// - clear / frosted / reset 必须 ready（:129-140）。
///
/// 注意：这是 scene 的仲裁，不是 HUD 的绘制条件 —— 本页在任何组合下都照常发射 6 条命中；
/// 宿主若把命中直接派发，"关不掉 / 切不了"的时序必须由本函数（或等价实现）保证。
/// "music:cover-front" 不在此列（见文件契约 7）。
bool viewerHudActionAccepted(ViewerHudState state, String action) {
  if (!state.isOpen || state.closing) {
    return false;
  }
  if (action == viewerHudCloseAction) {
    return true;
  }
  if (!state.ready) {
    return false;
  }
  return action == viewerHudClearAction ||
      action == viewerHudFrostedAction ||
      action == viewerHudResetAction;
}

// 绘制（NativeHud 助手的 viewer 子集）

class _ViewerHudPainter {
  _ViewerHudPainter({required this.glyphs, required this.dark});

  final ViewerHudGlyphsPort glyphs;
  final bool dark;
  final List<Object?> commands = <Object?>[];
  final List<Map<String, Object?>> hits = <Map<String, Object?>>[];

  /// Qt NativeHud::text（NativeHud.cpp:40-43）；颜色缺省走 ink()。
  void text(String value, double x, double y, double size, String weight, [double tracking = 0]) {
    commands.add(<Object?>['text', value, x, y, size, weight, tracking, _hudInk(dark)]);
  }

  /// Qt NativeHud::fit（NativeHud.cpp:48-76）：二分最长可容纳前缀，截断时 left(length-1)+"…"。
  /// Dart 的 String.length / substring 与 QString::size() / left() 一样按 UTF-16 码元计数，
  /// 因此代理对上的截断行为也与 Qt 一致（可能截出半个代理对，Qt 同样如此）。
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
      return value.substring(0, math.max(0, length - 1)) + '…';
    }
    return value;
  }

  /// Qt NativeHud::limited（NativeHud.cpp:77-79）：颜色固定走 ink()，且不带 tracking。
  void limited(String value, double x, double y, double size, double width, [String weight = 'regular']) {
    text(fit(value, size, width, weight), x, y, size, weight);
  }

  /// Qt NativeHud::hit（NativeHud.cpp:102-109）：六字段，绝不写 fixed。
  void hit(ViewerHudRect rect, String action, String label) {
    hits.add(<String, Object?>{
      'x': rect.x,
      'y': rect.y,
      'width': rect.width,
      'height': rect.height,
      'action': action,
      'label': label,
    });
  }

  /// Qt NativeHud::button（NativeHud.cpp:110-120）：viewer 页 m_modalControls 恒为 false，
  /// 因此等价于 hit + text(label, x, y + (height - size) / 2 - 4, size, weight)。
  void button(String label, ViewerHudRect rect, String action, double size, [String weight = 'regular']) {
    hit(rect, action, label);
    text(label, rect.x, rect.y + (rect.height - size) / 2 - 4, size, weight);
  }
}

/// Qt NativeHud::viewer(double width)（NativeHudDetail.cpp:513-529）。
///
/// 调用前提：宿主只在 frame["viewer"].toBool() 为真时调用（NativeHud.cpp:267-268）；
/// 本函数只负责 item 为空时的早退，不判断 viewer 开关。
/// 返回的 commands / hits 需要与 modalDraw、playerBar(0, 984, width) 的产出按 Qt 顺序拼装
/// （NativeHud.cpp:306-311）——那两段属于别的原子，本页不产出。
ViewerHudDrawing renderViewerHud(
  ViewerHudState state,
  double width, {
  required ViewerHudGlyphsPort glyphs,
}) {
  final ViewerHudItem? item = state.item;
  if (item == null) {
    // NativeHudDetail.cpp:514-516：没有当前条目就什么都不画，也不注册命中。
    return ViewerHudDrawing.empty();
  }

  final ViewerHudGeometry g = ViewerHudGeometry(width);
  final _ViewerHudPainter p = _ViewerHudPainter(glyphs: glyphs, dark: state.dark);

  // 顺序即语义：逐行对应 NativeHudDetail.cpp:518-528。
  p.button(viewerHudCloseLabel, g.close, viewerHudCloseAction, 20, 'demibold');
  p.text(viewerHudHeading, g.headingX, g.headingY, 11, 'regular', 1.5);
  p.limited(item.title + viewerHudTitleSuffix, g.titleX, g.titleY, 28, g.titleLimit, 'demibold');
  p.text(item.id, g.idX, g.idY, 12, 'regular');
  p.text(viewerHudDegree, g.degreeX, g.degreeY, 55, 'light');
  p.button(viewerHudClearLabel, g.clear, viewerHudClearAction, 14);
  p.button(viewerHudFrostedLabel, g.frosted, viewerHudFrostedAction, 14);
  p.text(viewerHudHint, g.hintX, g.hintY, 13, 'regular');
  p.button(viewerHudResetLabel, g.reset, viewerHudResetAction, 15);
  p.button(viewerHudCoverFrontLabel, g.coverFront, viewerHudCoverFrontAction, 15);
  p.button(viewerHudResetCornerLabel, g.resetCorner, viewerHudResetAction, 14);

  return ViewerHudDrawing(commands: p.commands, hits: p.hits);
}
