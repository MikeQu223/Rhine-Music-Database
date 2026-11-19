///  —— 「发现音乐」卡片（DiscoverMusicCard）的 1:1 Dart 移植。
///
/// 唯一真值源：Qt Android 横屏实现（行号即证据，勿凭记忆改数）：
/// - Qt/src/DiscoverMusicCard.h:10-15    Choice{label,action,selected}
/// - Qt/src/DiscoverMusicCard.h:16-23    Entry{title,artist,kind,image,imageAspect=1,index=0}
/// - Qt/src/DiscoverMusicCard.h:24-39    Model（bounds/dark/tab/status/loading/more/tabs/tools/
///                                       categories/entries/scroll/categoryPicker/categoryPage/
///                                       categoryPages/loadedCount）
/// - Qt/src/DiscoverMusicCard.h:40-50    Canvas 回调面（fill/text/fit/wrap/hit/image/circle/
///                                       measure/command）
/// - Qt/src/DiscoverMusicCard.h:51-53    ArchiveColumns=5、ViewportTop=230、ViewportBottom=748
/// - Qt/src/DiscoverMusicCard.h:54-59    Layout{viewport,tileSize,rowStride,maximumScroll}
/// - Qt/src/DiscoverMusicCard.h:60-63    layout / entryBounds / visibleIndices / paint
/// - Qt/src/DiscoverMusicCard.cpp:5-15   layout()：viewport 内缩 53/106、高 518、tile 间距 18、
///                                       rowStride=tile+112、rows=ceil(max(0,count-2)/5)（整数除法）、
///                                       bottom=rows>0?526+rows*rowStride-18:468、maximumScroll=max(0,bottom-748)
/// - Qt/src/DiscoverMusicCard.cpp:17-31  entryBounds()：两张特殊卡 238 高、featuredWidth=(w-18)*0.66、
///                                       方形档案 tileSize x (rowStride-18)
/// - Qt/src/DiscoverMusicCard.cpp:34-52  visibleIndices()：offset=clamp(scroll,0,max)、
///                                       先 0/1 两张特殊卡、再 firstRow/lastRow 行区间，判定用 intersects
/// - Qt/src/DiscoverMusicCard.cpp:56-65  Painter 构造：x=bounds.x+53、y=bounds.y、width=bounds.width-106；
///                                       深色四组字面量（paper/ink/muted/soft）
/// - Qt/src/DiscoverMusicCard.cpp:67-87  paint() 顺序：整幅 paper → 3px 顶线 ink → header → tabs →
///                                       tools → (categories|empty|clip+translate+recommendations+restore+
///                                       scrollIndicator) → footer
/// - Qt/src/DiscoverMusicCard.cpp:95-101 浅色字面量 paper/ink/muted/soft + amber/night/white
/// - Qt/src/DiscoverMusicCard.cpp:103-107 label()：先 canvas.fit 再 canvas.text，颜色默认 ink
/// - Qt/src/DiscoverMusicCard.cpp:109-113 rule()：ink 的 alpha 置 0.18，1px
/// - Qt/src/DiscoverMusicCard.cpp:115-124 button()：四条 1px 边框 alpha 0.18、文本 12 号
///                                       top+(height-12)/2-3、左边距 12、可用宽 available-24、hit 六字段
/// - Qt/src/DiscoverMusicCard.cpp:126-132 header()：五个文案与坐标
/// - Qt/src/DiscoverMusicCard.cpp:134-151 tabs()：两条 rule(126/170)、cell=width/max(1,n)、
///                                       文本居中、hit 高 40@128、amber 下划线 min(48,cell-8)@169 h3
/// - Qt/src/DiscoverMusicCard.cpp:153-166 tools()：空态文案；否则 cell=min(190,width/n)、
///                                       button(...,cell-8,32)、选中 amber 2px@213
/// - Qt/src/DiscoverMusicCard.cpp:168-179 kind()：album/artist/song/其余→PLAYLIST
/// - Qt/src/DiscoverMusicCard.cpp:181-191 title()：canvas.wrap(demibold)、行距 size+6、最多 2 行、
///                                       超出行数在末行补「…」
/// - Qt/src/DiscoverMusicCard.cpp:193-208 artwork()：底色 soft/night；有封面按 aspect 等比内接居中
///                                       （aspect=max(0.1,imageAspect)）；无封面画 kind 与两位序号占位
/// - Qt/src/DiscoverMusicCard.cpp:210-216 contentHit()：(rect 上移 scroll) ∩ viewport，非空才 hit
/// - Qt/src/DiscoverMusicCard.cpp:218-221 open()：动作 "discover:item:<index>"，label=title
/// - Qt/src/DiscoverMusicCard.cpp:223-233 framedArtwork()：save/translate/rotate(0.0872664626)/
///                                       translate/restore，阴影 +5/+8、纸 +0/+0、封面内缩 7
/// - Qt/src/DiscoverMusicCard.cpp:235-249 featured()：artSize=min(184,w*0.4)、copyWidth=w-artSize-80、
///                                       "01"@361/94、标题@288/27、副行@382/12、动作@432/12
/// - Qt/src/DiscoverMusicCard.cpp:251-278 secondary()：night 底、五层圆环、有 entry 走 02 版，
///                                       nullptr 走「＋/每日推荐/进入推荐 ↗」+ hit "discover:tab:daily"
/// - Qt/src/DiscoverMusicCard.cpp:280-297 recommendations()：loadedCount>2 画分组标题；
///                                       按 entries 顺序分发 featured/secondary/tile；loadedCount==1 补空位
/// - Qt/src/DiscoverMusicCard.cpp:299-310 tile()：封面 size×size、kind@+12/9、标题@+32/14、副行@+78/10
/// - Qt/src/DiscoverMusicCard.cpp:312-324 scrollIndicator()：maximumScroll<=0 直接返回；
///                                       thumb=max(28,h*h/(h+max))、轨道 alpha 0.16、宽 2、x+width+16
/// - Qt/src/DiscoverMusicCard.cpp:326-342 categories()：5 列、cell=(width-32)/5、行距 44、起始 285、
///                                       button 高 36、选中 amber 2px@+35、<=1 项时画 status@680
/// - Qt/src/DiscoverMusicCard.cpp:344-350 empty()：rule(230) + LOADING/MUSIC ARCHIVE + 主文案 + 提示
/// - Qt/src/DiscoverMusicCard.cpp:352-373 footer()：rule(756)、三态状态文案、分类翻页/加载更多/滚动提示
/// - Qt/src/DiscoverMusicCard.cpp:378-380 paint() 入口
/// - Qt/src/NativeHudDiscover.cpp:12-122 宿主装配：bounds=modalBounds、loadedCount=items.size、
///                                       scroll 已 clamp、entries 只含 visibleIndices 的项、
///                                       imageAspect=cover.width/cover.height
/// - Qt/tests/NativeHudChecks.cpp:1159-1331 这里必须满足的断言（五列同行/不重叠/hit 收进 viewport/
///                                       滚轮 75 精确累计/0.0872664626 旋转/居中 tab/aspect 保持/分类 40 分页）
///
/// 边界（与宿主/兄弟原子的契约）：
/// 1. 本文件只负责「卡片内部」：几何 + 绘制命令 + 命中。弹层坐标 modalBounds、遮罩、位移动画、
///    关闭流程、滚动条归零时机、DiscoverArtwork 封面键与 scope、MusicDiscover 状态机、
///    NativeHud::discoverPanel 的模型装配都不在这里（属 B = lib/hud/modals/discover_modal.dart
///    与宿主）。
/// 2. 不 import Flutter/Material，不 import lib/hud/protocol/**、lib/hud/text/**、lib/domain/**；
///    仅依赖 dart:ui 的 Rect（契约指定的几何类型）与 dart:math。文本测量/截断/换行全部由注入的
///    DiscoverCanvas 提供（Qt 的 Glyphs 由宿主注入），本文件没有任何全局可变状态。
/// 3. 颜色是 rgba 0..1 四元 List<double>；命中是六字段 x/y/width/height/action/label，
///    不含 fixed（fixed 只属于 PlayerBar）。命令是 Qt 扁平数组：["save"]/["clip",x,y,w,h]/
///    ["translate",dx,dy]/["rotate",rad]/["restore"]/["ellipse",color,x,y,w,h]。
/// 4. 顺序即语义：绘制与命中都按 Qt 的源码顺序产出，不排序、不去重、不合并；同代发布。
/// 5. 颜色按值传递（Qt 的 QJsonArray 是值语义）：本文件不原地修改任何颜色，派生 alpha 一律新建列表；
///    canvas 实现也不得原地修改传入的颜色列表。
/// 6. 竖屏：Qt 没有竖屏发现页，本文件不发明竖屏像素；全部几何都是 bounds 的函数，响应式编排
///    由调用方在 bounds/viewport 上完成。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

/// 档案网格列数（Qt/src/DiscoverMusicCard.h:51 ArchiveColumns）。
const int archiveColumns = 5;

/// 档案视口上沿，相对 bounds.y（Qt/src/DiscoverMusicCard.h:52 ViewportTop）。
const double discoverViewportTop = 230;

/// 档案视口下沿，相对 bounds.y（Qt/src/DiscoverMusicCard.h:53 ViewportBottom）。
const double discoverViewportBottom = 748;

/// 发现页面板高度（Qt/src/NativeHudDiscover.cpp:13 model.bounds 的 836）。
const double discoverPanelHeight = 836;

/// 两张特殊卡的高度（Qt/src/DiscoverMusicCard.cpp:23/26 字面量 238）。
const double discoverSpecialCardHeight = 238;

/// 特殊卡上沿，相对 bounds.y（Qt/src/DiscoverMusicCard.cpp:23/26 字面量 230）。
const double discoverSpecialCardTop = 230;

/// 第一行方形档案的上沿，相对 bounds.y（Qt/src/DiscoverMusicCard.cpp:29 字面量 526）。
const double discoverArchiveTop = 526;

/// 旋转角（Qt/src/DiscoverMusicCard.cpp:227 字面量 0.0872664626，即 5°）。
const double discoverFramedRotation = 0.0872664626;

/// 一个标签页/工具/分类选项（Qt/src/DiscoverMusicCard.h:10-15）。
///
/// 字段可变，与 C++ 聚合类型一致：装配方可以先建对象再补字段。
class DiscoverChoice {
  DiscoverChoice({this.label = '', this.action = '', this.selected = false});

  String label;
  String action;
  bool selected;

  @override
  String toString() => 'DiscoverChoice(' + label + ', ' + action + ', selected=' + selected.toString() + ')';
}

/// 一条发现条目（Qt/src/DiscoverMusicCard.h:16-23）。
///
/// [index] 是它在**已加载列表**中的原始下标（不是可见序列下标）：entryBounds、可见性和
/// "discover:item:<index>" 全部用它，所以滚动后不会误开相邻档案。
class DiscoverEntry {
  DiscoverEntry({
    this.title = '',
    this.artist = '',
    this.kind = '',
    this.image = '',
    this.imageAspect = 1,
    this.index = 0,
  });

  String title;
  String artist;

  /// 原始 kind 串（album/artist/song/其它），绘制时由 [DiscoverCard] 映射成中英标签。
  String kind;

  /// 封面键；空串表示没有封面，走统一档案占位（不伪造封面）。
  String image;

  /// 真实封面宽高比（Qt/src/NativeHudDiscover.cpp:119 width/height）；缺省 1。
  double imageAspect;

  /// 已加载列表中的下标（Qt/src/NativeHudDiscover.cpp:111）。
  int index;

  @override
  String toString() => 'DiscoverEntry(' +
      index.toString() +
      ', ' +
      title +
      ', ' +
      artist +
      ', ' +
      kind +
      ', ' +
      image +
      ', ' +
      imageAspect.toString() +
      ')';
}

/// 发现页只读显示模型（Qt/src/DiscoverMusicCard.h:24-39）。
///
/// 只承载绘制需要的快照，不含平台请求、账号状态或播放器引用；装配方（B）负责填。
class DiscoverModel {
  DiscoverModel({
    this.bounds = Rect.zero,
    this.dark = false,
    this.tab = '',
    this.status = '',
    this.loading = false,
    this.more = false,
    List<DiscoverChoice>? tabs,
    List<DiscoverChoice>? tools,
    List<DiscoverChoice>? categories,
    List<DiscoverEntry>? entries,
    this.scroll = 0,
    this.categoryPicker = false,
    this.categoryPage = 0,
    this.categoryPages = 1,
    this.loadedCount = 0,
  })  : tabs = tabs ?? <DiscoverChoice>[],
        tools = tools ?? <DiscoverChoice>[],
        categories = categories ?? <DiscoverChoice>[],
        entries = entries ?? <DiscoverEntry>[];

  /// 面板矩形（Qt 的 modalBounds，高 836）。
  Rect bounds;

  /// 深色主题：只切换 paper/ink/muted/soft 四组字面量（cpp:59-65）。
  bool dark;

  /// 当前标签键（装配期用；本文件不消费，保留以对齐 Qt Model 字段）。
  String tab;

  /// 空态/分类页脚文案（cpp:340/347/354）。
  String status;

  bool loading;
  bool more;

  List<DiscoverChoice> tabs;
  List<DiscoverChoice> tools;
  List<DiscoverChoice> categories;

  /// 只含可见项的条目（装配方按 visibleIndices 过滤），按可见顺序排列。
  List<DiscoverEntry> entries;

  /// 宿主已 clamp 过的滚动偏移（NativeHudDiscover.cpp:92-93）。
  double scroll;

  bool categoryPicker;
  int categoryPage;
  int categoryPages;

  /// 已加载条目总数（= 平台 items.size；不是 entries.length）。
  int loadedCount;

  @override
  String toString() => 'DiscoverModel(' +
      bounds.toString() +
      ', dark=' +
      dark.toString() +
      ', tab=' +
      tab +
      ', loadedCount=' +
      loadedCount.toString() +
      ', scroll=' +
      scroll.toString() +
      ', categoryPicker=' +
      categoryPicker.toString() +
      ')';
}

/// 档案网格几何（Qt/src/DiscoverMusicCard.h:54-59）。
class DiscoverLayout {
  const DiscoverLayout({
    this.viewport = Rect.zero,
    this.tileSize = 0,
    this.rowStride = 0,
    this.maximumScroll = 0,
  });

  /// 档案视口：裁剪、命中求交、滚轮作用域都用它。
  final Rect viewport;

  /// 方形档案边长：viewport.width 去掉四条 18 的列间距后五等分。
  final double tileSize;

  /// 行距：tileSize + 112（112 = 封面下方的文字区）。
  final double rowStride;

  /// 最大滚动距离：max(0, contentBottom - ViewportBottom)。
  final double maximumScroll;

  @override
  String toString() => 'DiscoverLayout(' +
      viewport.toString() +
      ', tileSize=' +
      tileSize.toString() +
      ', rowStride=' +
      rowStride.toString() +
      ', maximumScroll=' +
      maximumScroll.toString() +
      ')';
}

/// Qt/src/DiscoverMusicCard.h:40-50 的 Canvas 回调面。
///
/// 宿主把这九个回调转发到自己的绘制原语（Qt/src/NativeHudDiscover.cpp:123-146）：
/// fill→fill、text→text、fit/wrap/measure→Glyphs、hit→hit、image→封面绘制、
/// circle→op(["ellipse",color,cx-r,cy-r,2r,2r])、command→op。
/// 实现方不得原地修改传入的颜色列表（Qt 的 QJsonArray 是值语义）。
abstract class DiscoverCanvas {
  /// 实心矩形，rgba 0..1（Qt NativeHud::fill）。
  void fill(double x, double y, double width, double height, List<double> color);

  /// 单行文本，(x,y) 是 Qt 的字形锚点，weight 为 regular/light/demibold/bold。
  void text(String value, double x, double y, double size, String weight, List<double> color);

  /// 单行截断（Qt NativeHud::fit，二分找最长可容纳前缀 + 省略号）。
  String fit(String value, double size, double available, String weight);

  /// 按宽度换行（Qt Glyphs::wrap）。
  List<String> wrap(String value, double width, double size, String weight);

  /// 六字段命中 x/y/width/height/action/label（Qt NativeHud::hit）。
  void hit(double x, double y, double width, double height, String action, String label);

  /// 封面，key 由宿主解析成真实图片（DiscoverArtwork 的键）。
  void image(String key, double x, double y, double width, double height);

  /// 圆（宿主转成 op(["ellipse",...])）。
  void circle(double cx, double cy, double radius, List<double> color);

  /// 水平测量（Qt Glyphs::width），用于 tabs 居中。
  double measure(String value, double size, String weight);

  /// 扁平绘制命令（Qt NativeHud::op）。
  void command(List<Object?> command);
}

/// 发现卡片：纯静态几何 + 一次绘制（Qt/src/DiscoverMusicCard.h:60-63）。
class DiscoverCard {
  const DiscoverCard._();

  /// Qt/src/DiscoverMusicCard.h:51-53。
  static const int archiveColumnCount = archiveColumns;
  static const double viewportTop = discoverViewportTop;
  static const double viewportBottom = discoverViewportBottom;

  /// 深色纸/墨/次/软（Qt/src/DiscoverMusicCard.cpp:60-64）。
  static const List<double> _paperDark = <double>[0.09, 0.115, 0.095, 1];
  static const List<double> _inkDark = <double>[0.93, 0.94, 0.88, 1];
  static const List<double> _mutedDark = <double>[0.65, 0.69, 0.62, 1];
  static const List<double> _softDark = <double>[0.16, 0.20, 0.16, 1];

  /// 浅色纸/墨/次/软（Qt/src/DiscoverMusicCard.cpp:95-98）。
  static const List<double> _paperLight = <double>[0.973, 0.969, 0.933, 1];
  static const List<double> _inkLight = <double>[0.133, 0.165, 0.145, 1];
  static const List<double> _mutedLight = <double>[0.39, 0.43, 0.38, 1];
  static const List<double> _softLight = <double>[0.89, 0.90, 0.85, 1];

  /// 主题无关的三色（Qt/src/DiscoverMusicCard.cpp:99-101）。
  static const List<double> amber = <double>[0.835, 0.639, 0.282, 1];
  static const List<double> night = <double>[0.133, 0.165, 0.145, 1];
  static const List<double> white = <double>[0.95, 0.95, 0.9, 1];

  /// Qt/src/DiscoverMusicCard.cpp:5-15。
  ///
  /// rows 用 C++ 的整数除法 (max(0,count-2)+4)/5，这里用 ~/ 保持向零截断。
  static DiscoverLayout layout(Rect bounds, int count) {
    final Rect viewport = Rect.fromLTWH(
      bounds.left + 53,
      bounds.top + viewportTop,
      bounds.width - 106,
      viewportBottom - viewportTop,
    );
    final double tileSize = (viewport.width - (archiveColumns - 1) * 18) / archiveColumns;
    final double rowStride = tileSize + 112;
    final int rows = (math.max(0, count - 2) + archiveColumns - 1) ~/ archiveColumns;
    final double bottom = rows > 0 ? 526 + rows * rowStride - 18 : 468;
    return DiscoverLayout(
      viewport: viewport,
      tileSize: tileSize,
      rowStride: rowStride,
      maximumScroll: math.max(0.0, bottom - viewportBottom),
    );
  }

  /// Qt/src/DiscoverMusicCard.cpp:17-31。
  ///
  /// 两张特殊卡固定占 230..468；index>=2 的方形档案从 526 起按五列网格排。
  static Rect entryBounds(Rect bounds, int index) {
    final DiscoverLayout geometry = layout(bounds, 0);
    final double left = geometry.viewport.left;
    final double width = geometry.viewport.width;
    final double featuredWidth = (width - 18) * 0.66;
    if (index == 0) {
      return Rect.fromLTWH(left, bounds.top + 230, featuredWidth, 238);
    }
    if (index == 1) {
      return Rect.fromLTWH(
        left + featuredWidth + 18,
        bounds.top + 230,
        width - featuredWidth - 18,
        238,
      );
    }
    return Rect.fromLTWH(
      left + ((index - 2) % archiveColumns) * (geometry.tileSize + 18),
      bounds.top + 526 + ((index - 2) ~/ archiveColumns) * geometry.rowStride,
      geometry.tileSize,
      geometry.rowStride - 18,
    );
  }

  /// Qt/src/DiscoverMusicCard.cpp:34-52。
  ///
  /// 绘制、点击与封面请求共用这一份可见索引：先两张特殊卡，再按 firstRow/lastRow 行区间，
  /// 每个候选都要求「上移 offset 后」与视口真正相交。
  /// 注意 int((ViewportTop + offset - 526) / rowStride) 是 C++ 的向零截断，
  /// Dart 用 toInt() 得到同样的结果（不能用 floor）。
  static List<int> visibleIndices(Rect bounds, int count, double scroll) {
    final DiscoverLayout geometry = layout(bounds, count);
    final List<int> indices = <int>[];
    final double offset = scroll.clamp(0.0, geometry.maximumScroll).toDouble();
    final int special = math.min(2, count);
    for (int index = 0; index < special; index++) {
      if (_intersects(entryBounds(bounds, index).translate(0, -offset), geometry.viewport)) {
        indices.add(index);
      }
    }
    final int firstRow = math.max(0, ((viewportTop + offset - 526) / geometry.rowStride).toInt());
    final int lastRow = math.max(0, ((viewportBottom + offset - 526) / geometry.rowStride).toInt());
    for (int index = 2 + firstRow * archiveColumns;
        index < math.min(count, 2 + (lastRow + 1) * archiveColumns);
        index++) {
      if (_intersects(entryBounds(bounds, index).translate(0, -offset), geometry.viewport)) {
        indices.add(index);
      }
    }
    return indices;
  }

  /// Qt/src/DiscoverMusicCard.cpp:378-380。
  static void paint(DiscoverModel model, DiscoverCanvas canvas) {
    _Painter(model, canvas).paint();
  }

  /// Qt QRectF::intersects：严格不等号（贴边不算相交）。
  static bool _intersects(Rect a, Rect b) =>
      math.max(a.left, b.left) < math.min(a.right, b.right) &&
      math.max(a.top, b.top) < math.min(a.bottom, b.bottom);

  /// Qt QRectF::intersected：坐标先取交，宽高可能为负，由调用方判空。
  static Rect _intersected(Rect a, Rect b) => Rect.fromLTRB(
        math.max(a.left, b.left),
        math.max(a.top, b.top),
        math.min(a.right, b.right),
        math.min(a.bottom, b.bottom),
      );

  /// Qt QRectF::isEmpty：宽或高 <= 0。
  static bool _isEmpty(Rect rect) => rect.width <= 0 || rect.height <= 0;
}

/// Qt/src/DiscoverMusicCard.cpp:53-374 的 Painter，逐方法对应。
class _Painter {
  _Painter(this.model, this.canvas)
      : x = model.bounds.left + 53,
        y = model.bounds.top,
        width = model.bounds.width - 106;

  final DiscoverModel model;
  final DiscoverCanvas canvas;

  /// Qt cpp:57-58：卡片内容区左沿、bounds 上沿、内容宽。
  final double x;
  final double y;
  final double width;

  /// Qt cpp:59-65：深色只换这四个字面量；amber/night/white 不变。
  List<double> get paper => model.dark ? DiscoverCard._paperDark : DiscoverCard._paperLight;
  List<double> get ink => model.dark ? DiscoverCard._inkDark : DiscoverCard._inkLight;
  List<double> get muted => model.dark ? DiscoverCard._mutedDark : DiscoverCard._mutedLight;
  List<double> get soft => model.dark ? DiscoverCard._softDark : DiscoverCard._softLight;

  /// Qt cpp:67-87，绘制顺序即语义。
  void paint() {
    canvas.fill(model.bounds.left, y, model.bounds.width, model.bounds.height, paper);
    canvas.fill(model.bounds.left, y, model.bounds.width, 3, ink);
    header();
    tabs();
    tools();
    if (model.categoryPicker) {
      categories();
    } else if (model.loadedCount == 0) {
      empty();
    } else {
      final Rect viewport = DiscoverCard.layout(model.bounds, model.loadedCount).viewport;
      canvas.command(<Object?>['save']);
      canvas.command(<Object?>['clip', viewport.left, viewport.top, viewport.width, viewport.height]);
      canvas.command(<Object?>['translate', 0.0, -model.scroll]);
      recommendations();
      canvas.command(<Object?>['restore']);
      scrollIndicator();
    }
    footer();
  }

  /// Qt cpp:103-107：先 fit 再 text；颜色缺省用 ink。
  void label(
    String value,
    double left,
    double top,
    double size,
    double available, [
    String weight = 'regular',
    List<double> color = const <double>[],
  ]) {
    canvas.text(
      canvas.fit(value, size, available, weight),
      left,
      y + top,
      size,
      weight,
      color.isEmpty ? ink : color,
    );
  }

  /// Qt cpp:109-113：ink 的 alpha 直接置为 opacity，1px 横线。
  void rule(double top, [double opacity = 0.18]) {
    canvas.fill(x, y + top, width, 1, _alpha(ink, opacity));
  }

  /// Qt cpp:115-124：四条 1px 边框（alpha 0.18）+ 12 号文本 + 六字段命中。
  void button(DiscoverChoice choice, double left, double top, double available, [double height = 36]) {
    final List<double> border = _alpha(ink, 0.18);
    canvas.fill(left, y + top, available, 1, border);
    canvas.fill(left, y + top + height - 1, available, 1, border);
    canvas.fill(left, y + top, 1, height, border);
    canvas.fill(left + available - 1, y + top, 1, height, border);
    label(choice.label, left + 12, top + (height - 12) / 2 - 3, 12, available - 24);
    canvas.hit(left, y + top, available, height, choice.action, choice.label);
  }

  /// Qt cpp:126-132。
  void header() {
    label('02 / MUSIC DIRECTORY', x, 25, 11, width - 180, 'regular', muted);
    button(DiscoverChoice(label: '← 返回', action: 'close-modal'), x + width - 140, 20, 140, 38);
    label('发现音乐', x, 65, 36, 180, 'bold');
    label('Discover music', x + 190, 76, 22, width - 200, 'light', muted);
    label('RHINE LAB / MUSIC DATABASE', x + width - 270, 97, 10, 270, 'regular', muted);
  }

  /// Qt cpp:134-151：cell 均分，文本按 measure 居中，选中项画 amber 下划线。
  void tabs() {
    final double cell = width / math.max(1, model.tabs.length);
    rule(126);
    rule(170);
    for (int index = 0; index < model.tabs.length; index++) {
      final DiscoverChoice choice = model.tabs[index];
      final double left = x + index * cell;
      final String value = canvas.fit(choice.label, 12, cell - 8, 'regular');
      final double textWidth = canvas.measure(value, 12, 'regular');
      label(value, left + (cell - textWidth) / 2, 141, 12, cell - 8, 'regular',
          choice.selected ? ink : muted);
      canvas.hit(left, y + 128, cell, 40, choice.action, choice.label);
      if (choice.selected) {
        final double underline = math.min(48.0, cell - 8);
        canvas.fill(left + (cell - underline) / 2, y + 169, underline, 3, DiscoverCard.amber);
      }
    }
  }

  /// Qt cpp:153-166：空态一行提示字；否则最多 190 宽的工具按钮 + 选中 amber 短线。
  void tools() {
    if (model.tools.isEmpty) {
      label('CURATED ARCHIVES / 精选音乐档案', x, 191, 10, width, 'regular', muted);
      return;
    }
    final double cell = math.min(190.0, width / model.tools.length);
    for (int index = 0; index < model.tools.length; index++) {
      final DiscoverChoice choice = model.tools[index];
      button(choice, x + index * cell, 182, cell - 8, 32);
      if (choice.selected) {
        canvas.fill(x + index * cell, y + 213, cell - 8, 2, DiscoverCard.amber);
      }
    }
  }

  /// Qt cpp:168-179。
  String kindOf(DiscoverEntry entry) {
    if (entry.kind == 'album') {
      return 'ALBUM / 专辑';
    }
    if (entry.kind == 'artist') {
      return 'ARTIST / 歌手';
    }
    if (entry.kind == 'song') {
      return 'TRACK / 歌曲';
    }
    return 'PLAYLIST / 歌单';
  }

  /// Qt cpp:181-191：最多 maximum 行，超出时在最后一行补「…」。
  void title(
    DiscoverEntry entry,
    double left,
    double top,
    double size,
    double available, [
    List<double> color = const <double>[],
    int maximum = 2,
  ]) {
    final List<String> lines = canvas.wrap(entry.title, available, size, 'demibold');
    for (int index = 0; index < math.min(maximum, lines.length); index++) {
      String value = lines[index];
      if (index == maximum - 1 && lines.length > maximum) {
        value += '…';
      }
      label(value, left, top + index * (size + 6), size, available, 'demibold', color);
    }
  }

  /// Qt cpp:193-208：有封面按真实宽高比内接居中；无封面用档案占位（不伪造封面）。
  void artwork(
    DiscoverEntry entry,
    double left,
    double top,
    double available,
    double height, [
    bool darkTile = false,
  ]) {
    canvas.fill(left, y + top, available, height, darkTile ? DiscoverCard.night : soft);
    if (entry.image.isNotEmpty) {
      final double aspect = math.max(0.1, entry.imageAspect);
      final double imageWidth = math.min(available, height * aspect);
      final double imageHeight = imageWidth / aspect;
      canvas.image(
        entry.image,
        left + (available - imageWidth) / 2,
        y + top + (height - imageHeight) / 2,
        imageWidth,
        imageHeight,
      );
    } else {
      label(kindOf(entry), left + 14, top + 13, 10, available - 28, 'regular',
          darkTile ? DiscoverCard.white : muted);
      label((entry.index + 1).toString().padLeft(2, '0'), left + 14, top + height - 65, 42,
          available - 28, 'light', darkTile ? DiscoverCard.amber : muted);
    }
  }

  /// Qt cpp:210-216：矩形先上移 scroll，再与视口求交；交集为空就不发命中。
  void contentHit(Rect rectangle, String action, String name) {
    final Rect viewport = DiscoverCard.layout(model.bounds, model.loadedCount).viewport;
    final Rect target = DiscoverCard._intersected(rectangle.translate(0, -model.scroll), viewport);
    if (!DiscoverCard._isEmpty(target)) {
      canvas.hit(target.left, target.top, target.width, target.height, action, name);
    }
  }

  /// Qt cpp:218-221。
  void open(DiscoverEntry entry) {
    contentHit(DiscoverCard.entryBounds(model.bounds, entry.index),
        'discover:item:' + entry.index.toString(), entry.title);
  }

  /// Qt cpp:223-233：以装裱中心旋转 5°，阴影 +5/+8、纸面、封面内缩 7；不改变封面宽高比。
  void framedArtwork(DiscoverEntry entry, double left, double top, double size) {
    canvas.command(<Object?>['save']);
    canvas.command(<Object?>['translate', left + size / 2, y + top + size / 2]);
    canvas.command(<Object?>['rotate', discoverFramedRotation]);
    canvas.command(<Object?>['translate', -left - size / 2, -y - top - size / 2]);
    canvas.fill(left + 5, y + top + 8, size, size, const <double>[0.725, 0.749, 0.675, 1]);
    canvas.fill(left, y + top, size, size, const <double>[0.969, 0.957, 0.898, 1]);
    artwork(entry, left + 7, top + 7, size - 14, size - 14);
    canvas.command(<Object?>['restore']);
  }

  /// Qt cpp:235-249。
  void featured(DiscoverEntry entry) {
    final Rect rectangle = DiscoverCard.entryBounds(model.bounds, 0);
    final double artSize = math.min(184.0, rectangle.width * 0.4);
    final double copyWidth = rectangle.width - artSize - 80;
    canvas.fill(rectangle.left, rectangle.top, rectangle.width, rectangle.height, soft);
    label('01', rectangle.right - 120, 361, 94, 120, 'light',
        model.dark ? const <double>[0.24, 0.29, 0.23, 1] : const <double>[0.788, 0.812, 0.737, 1]);
    label('FEATURED ARCHIVE / 精选推荐', x + 24, 250, 10, copyWidth, 'regular', muted);
    title(entry, x + 24, 288, 27, copyWidth);
    label(entry.artist.isEmpty ? kindOf(entry) : entry.artist, x + 24, 382, 12, copyWidth, 'regular',
        muted);
    label(entry.kind == 'song' ? '▶ 播放歌曲' : '打开音乐档案 ↗', x + 24, 432, 12, copyWidth);
    framedArtwork(entry, rectangle.right - artSize - 28, 257, artSize);
    open(entry);
  }

  /// Qt cpp:251-278：第二张特殊卡；没有第 2 条时是「每日推荐」入口。
  void secondary(DiscoverEntry? entry) {
    final Rect rectangle = DiscoverCard.entryBounds(model.bounds, 1);
    final double sideX = rectangle.left;
    final double sideWidth = rectangle.width;
    canvas.fill(sideX, rectangle.top, sideWidth, rectangle.height, DiscoverCard.night);
    label('NEXT DISCOVERY / 继续探索', sideX + 20, 250, 10, sideWidth - 40, 'regular',
        DiscoverCard.white);
    final double center = sideX + sideWidth / 2;
    const List<double> ring = <double>[0.40, 0.46, 0.37, 1];
    canvas.circle(center, y + 310, 37, ring);
    canvas.circle(center, y + 310, 36, DiscoverCard.night);
    canvas.circle(center, y + 310, 28, ring);
    canvas.circle(center, y + 310, 27, DiscoverCard.night);
    canvas.circle(center + 25, y + 283, 3, DiscoverCard.amber);
    if (entry != null) {
      label('02', center - 18, 289, 30, sideWidth / 2, 'light', DiscoverCard.amber);
      title(entry, sideX + 20, 355, 20, sideWidth - 40, DiscoverCard.white);
      label(entry.artist.isEmpty ? kindOf(entry) : entry.artist, sideX + 20, 413, 11,
          sideWidth - 40, 'regular', DiscoverCard.white);
      label(entry.kind == 'song' ? '播放歌曲 ▶' : '打开档案 ↗', sideX + 20, 438, 11, sideWidth - 40,
          'regular', DiscoverCard.amber);
      open(entry);
    } else {
      label('＋', center - 10, 292, 24, sideWidth / 2, 'light', DiscoverCard.amber);
      label('每日推荐', sideX + 20, 365, 23, sideWidth - 40, 'demibold', DiscoverCard.white);
      label('进入推荐 ↗', sideX + 20, 426, 12, sideWidth - 40, 'regular', DiscoverCard.white);
      contentHit(rectangle, 'discover:tab:daily', '每日推荐');
    }
  }

  /// Qt cpp:280-297：entries 顺序即绘制顺序；loadedCount==1 时右卡退化成入口。
  void recommendations() {
    if (model.loadedCount > 2) {
      label('音乐档案', x, 490, 17, 150, 'demibold');
      label('SELECTED PROGRAMS', x + 95, 495, 10, width - 100, 'regular', muted);
    }
    for (final DiscoverEntry entry in model.entries) {
      if (entry.index == 0) {
        featured(entry);
      } else if (entry.index == 1) {
        secondary(entry);
      } else {
        tile(entry);
      }
    }
    if (model.loadedCount == 1) {
      secondary(null);
    }
  }

  /// Qt cpp:299-310：方形档案；top 用 entryBounds 的绝对 y 减 panel y。
  void tile(DiscoverEntry entry) {
    final Rect rectangle = DiscoverCard.entryBounds(model.bounds, entry.index);
    final double left = rectangle.left;
    final double top = rectangle.top - y;
    final double size = rectangle.width;
    artwork(entry, left, top, size, size);
    label(kindOf(entry), left, top + size + 12, 9, size, 'regular', muted);
    title(entry, left, top + size + 32, 14, size);
    label(entry.artist.isEmpty ? kindOf(entry) : entry.artist, left, top + size + 78, 10, size,
        'regular', muted);
    open(entry);
  }

  /// Qt cpp:312-324：轨道 2px、alpha 0.16；滑块 min 28；内容不超一屏就整条不画。
  void scrollIndicator() {
    final DiscoverLayout geometry = DiscoverCard.layout(model.bounds, model.loadedCount);
    if (geometry.maximumScroll <= 0) {
      return;
    }
    final double height = geometry.viewport.height;
    final double thumb = math.max(28.0, height * height / (height + geometry.maximumScroll));
    final double top =
        geometry.viewport.top + (height - thumb) * model.scroll / geometry.maximumScroll;
    canvas.fill(x + width + 16, geometry.viewport.top, 2, height, _alpha(muted, 0.16));
    canvas.fill(x + width + 16, top, 2, thumb, muted);
  }

  /// Qt cpp:326-342：五列分类按钮；<=1 项时把 status 画在 680。
  void categories() {
    label('选择歌单分类', x, 237, 20, width, 'demibold');
    const int columns = 5;
    final double cell = (width - 32) / columns;
    for (int index = 0; index < model.categories.length; index++) {
      final double left = x + (index % columns) * (cell + 8);
      // 285 是 double 上下文里的 int 表达式：整数字面量只能逐字转换，
      // 285 + int 的结果类型是 int，所以必须写成 285.0（ 同类编译错误）。
      final double top = 285.0 + (index ~/ columns) * 44;
      final DiscoverChoice choice = model.categories[index];
      button(choice, left, top, cell, 36);
      if (choice.selected) {
        canvas.fill(left, y + top + 35, cell, 2, DiscoverCard.amber);
      }
    }
    if (model.categories.length <= 1) {
      label(model.status, x, 680, 14, width, 'regular', muted);
    }
  }

  /// Qt cpp:344-350：空态三分支（加载中 / 有 status / 暂无内容）。
  void empty() {
    rule(230);
    label(model.loading ? 'LOADING ARCHIVES' : 'MUSIC ARCHIVE', x, 336, 12, width, 'regular', muted);
    label(model.loading ? '正在读取音乐…' : (model.status.isEmpty ? '暂无内容' : model.status), x, 377,
        25, width, 'demibold');
    label('切换上方分类，继续探索音乐资料库。', x, 428, 13, width, 'regular', muted);
  }

  /// Qt cpp:352-373：状态栏三态（分类翻页 / 加载更多 / 滚动提示）。
  void footer() {
    rule(756);
    String status = model.status;
    if (model.categoryPicker) {
      status = (model.categoryPage + 1).toString() + ' / ' + model.categoryPages.toString();
    } else if (!model.loading && model.loadedCount > 0) {
      status = '已载入 ' + model.loadedCount.toString() + ' 条 / 滚轮浏览';
    }
    label(status, x, 779, 11, width - 350, 'regular', muted);
    if (model.categoryPicker) {
      button(DiscoverChoice(label: '↑ 上一页', action: 'discover:category-page:prev'), x + width - 212,
          770, 100, 34);
      button(DiscoverChoice(label: '下一页 ↓', action: 'discover:category-page:next'), x + width - 100,
          770, 100, 34);
    } else if (model.more) {
      button(DiscoverChoice(label: model.loading ? '载入中…' : '加载更多 ↓', action: 'discover:more'),
          x + width - 120, 770, 120, 34);
    } else if (model.loadedCount > 0) {
      final double maximum = DiscoverCard.layout(model.bounds, model.loadedCount).maximumScroll;
      final String hint =
          model.scroll < maximum ? 'SCROLL TO EXPLORE / 向下滚动' : 'END OF ARCHIVE / 档案结束';
      label(hint, x + width - 205, 779, 10, 205, 'regular', muted);
    }
  }

  /// Qt 里是把 QJsonArray 的 alpha 直接赋值后按值传参；这里新建列表，绝不原地改。
  static List<double> _alpha(List<double> color, double alpha) =>
      <double>[color[0], color[1], color[2], alpha];
}
