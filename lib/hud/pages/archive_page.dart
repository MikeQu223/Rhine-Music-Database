// 覆盖「品牌 / 导航 / 页脚 / 遮罩；五 lane、目录栈、列游标、Tab Mode、mask、曲目表」
//      + 「播放全部、返回上一级、open、column-prev/next；空态」
// 横屏 1:1 真值源：Qt/src/NativeHud.cpp
//   archive             404-497  目录栈返回 / 详情入口 / 播放全部 / 标题或曲目表 /
//                                编号 / 上下槽位 / 左右列游标 / 底部提示行
//   archiveTabButton    500-514  Tab Mode 命中 + 文案 + keycap/symbol 两条路径
//   empty               374-403  本文件不重实现：注入 drawEmpty 委托（directory_empty.dart）
//   archiveTrackList    535-593  本文件不重实现：注入 drawTrackList 委托（track_ruler.dart）
//   control             121-124  命中 x-10 / width+20 / 54；文字 x / y+14 / 20 / demibold
//   button              110-119  m_modalControls=false（NativeHud.h:222 默认 false）
//                                -> 命中 x/y/width/height 不加 padding、不发 fill
//   roll                97-101   fit(value,size,width,weight) 后 rollingText(port)
//   rollingText         86-96    -> HudTextPort.rolling(key,shown,x-inset,y,size,weight,0,numeric)
//   limited             77-79    fit 后 text，weight 透传
//   hit / fill / rule / text / aligned   102-129 / 37-39 / 125-129 / 40-43 / 44-46
//   MusicData::pad      Qt/src/MusicData.cpp:148-150  QString::number(v).rightJustified(w,'0')
//   五 lane 模型         Qt/src/NativeHudController.cpp:183-185  rows(lane): lane<0 || lane>=5
//   supportsTrackList   Qt/src/NativeHudController.cpp:945-948（注入谓词表达，本页不判断）
// 纯 Dart：仅相对导入 './chrome.dart'（契约块见 chrome.dart），不 import 任何 UI / 渲染框架。
// 命令与命中按 Qt 发射顺序 append（不排序、不去重、不合并），顺序即语义。
// 外部依赖：lib/hud/protocol/{hud_command,hud_hit,hud_frame}.dart（唯一 shared types）
//   与本页注入的 HudSurfaceSink / HudTextPort 的适配由宿主接线。
import 'dart:math' as math;

import 'chrome.dart';

/// Qt MusicData::pad(int value, int width = 2) (Qt/src/MusicData.cpp:148-150)：
/// QString::number(value).rightJustified(width, '0')。
String _pad(int value, [int width = 2]) => value.toString().padLeft(width, '0');

/// Qt 数字进 SVG path 文案时的格式（QString::arg(double) 的 'g' 形态）：
/// 整数不带小数点；非整数用最短往返十进制。
String _num(double value) {
  if (!value.isFinite) {
    return value.toString();
  }
  if (value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return value.toString();
}

/// Qt MusicLibrary::current 中被 archive() 读取的字段切片（NativeHud.cpp:406-407, 435-441）。
/// id 为空串等价于 Qt item["id"].toString().isEmpty()（NativeHud.cpp:407）。
class ArchiveItem {
  const ArchiveItem({required this.id, required this.title, required this.artist, required this.kind});

  final String id;
  final String title;
  final String artist;

  /// Qt current["kind"]：playlist / album / artist / folder / song 等（NativeHud.cpp:411, 439）
  final String kind;
}

/// Qt NativeHud::archive(double width) 读取的 MusicLibrary / MusicSession 状态切片（只读快照）。
///
/// 字段 ↔ Qt 调用点：
///   libraryName          NativeHud.cpp:430, 485
///   libraryIndex         NativeHud.cpp:456（+1 后 pad）
///   libraryTotal         NativeHud.cpp:460
///   selectedLane         NativeHud.cpp:420-426, 469, 487
///   laneCount            Qt/src/NativeHudController.cpp:183-185（资料库 lane 模型宽度 5）
///   sourceOrderIndex     NativeHud.cpp:482  sourceOrder().indexOf(selectedLane)
///   provider             NativeHud.cpp:483（kugou 时为 4 列，否则 5 列）
///   isLocal / isSiren    NativeHud.cpp:424-426（isSiren 的 play-all / open-all-siren 分支）
///   directory            NativeHud.cpp:409, 420-423, 481, 486, 494
///   directoryKind        NativeHud.cpp:411-417（详情入口文案）, 420-422（playlist/album/folder）
///   uid / restoringAccount / sourceLoading  空态委托（directory_empty.dart）所需切片
///   trackListMode        NativeHud.cpp:428, 503
///   current              NativeHud.cpp:406-407, 428, 435, 439, 575
///   libraryItemsEmpty    NativeHud.cpp:473  libraryItems().isEmpty()
///   libraryItemsLength   NativeHud.cpp:537  libraryItems().size()（适配器/曲目表消费）
///   selectedPhysicalRow  NativeHud.cpp:468-469  max(0, physicalSlots[lane].indexOf(selected))
///   sourceMessage        空态委托（directory_empty.dart）所需切片
class HudArchiveState {
  const HudArchiveState({
    required this.libraryName,
    required this.libraryIndex,
    required this.libraryTotal,
    required this.selectedLane,
    required this.laneCount,
    required this.sourceOrderIndex,
    required this.provider,
    required this.isLocal,
    required this.isSiren,
    required this.directory,
    required this.directoryKind,
    required this.uid,
    required this.restoringAccount,
    required this.sourceLoading,
    required this.trackListMode,
    required this.current,
    required this.libraryItemsEmpty,
    required this.libraryItemsLength,
    required this.selectedPhysicalRow,
    required this.sourceMessage,
  });

  final String libraryName;
  final int libraryIndex;
  final int libraryTotal;
  final int selectedLane;

  /// Qt 资料库 lane 模型宽度（NativeHudController.cpp:183-185 的 lane >= 5）；默认 5。
  final int laneCount;

  /// Qt music.sourceOrder().indexOf(music.selectedLane)（NativeHud.cpp:482）。
  final int sourceOrderIndex;

  /// Qt music.provider（NativeHud.cpp:483）。
  final String provider;

  final bool isLocal;
  final bool isSiren;

  /// Qt music.directory（非空即处于目录栈内）。
  final bool directory;

  /// Qt music.directory->item["kind"]；无目录时为 null。
  final String? directoryKind;

  final String uid;
  final bool restoringAccount;
  final bool sourceLoading;

  /// Qt trackListMode（NativeHud.h:146 默认 false）。
  final bool trackListMode;

  /// Qt music.current；null 或 id 为空串时走空态分支（NativeHud.cpp:407/461）。
  final ArchiveItem? current;

  final bool libraryItemsEmpty;
  final int libraryItemsLength;

  /// 当前 lane 的物理槽行号（Qt max(0, physicalSlots[selectedLane].indexOf(selected))）。
  final int selectedPhysicalRow;

  final String? sourceMessage;
}

/// Qt NativeHud::archive() / archiveTabButton() / 曲目编号滚动（NativeHud.cpp:404-514）。
///
/// 本页只拥有「资料库页面外壳」：目录栈返回与详情入口、播放全部、标题区、曲目编号、
/// 上下槽位、左右列游标、Tab Mode 按钮、底部提示行。曲目表与空态分别由注入的
/// drawTrackList / drawEmpty 委托（track_ruler.dart / directory_empty.dart）绘制，
/// 与 Qt 的 NativeHud::archiveTrackList / NativeHud::empty 分工一致。
class HudArchivePage {
  HudArchivePage(this.sink, this.text, {this.dark = false});

  /// 注入出口：命令与命中按 Qt 发射顺序 append（chrome.dart 契约）。
  final HudSurfaceSink sink;

  /// 注入的 glyph / 文本端口。本页自身不做任何字形度量。
  final HudTextPort text;

  /// Qt dark 主题标志（NativeHud.cpp:470）。
  final bool dark;

  // Qt 私有 helper 的等价薄封装（只使用 chrome.dart 已冻结的契约）

  /// Qt NativeHud::text() (NativeHud.cpp:40-43)。
  void _text(String value, double x, double y, double size, [String weight = 'regular', double tracking = 0]) {
    hudText(sink, value, x, y, size, weight: weight, tracking: tracking, dark: dark);
  }

  /// Qt NativeHud::fill() (NativeHud.cpp:37-39)：color 为空时回落 ink()。
  void _fill(List<Object?> color, double x, double y, double width, double height) {
    hudFill(sink, color, x, y, width, height, dark: dark);
  }

  /// Qt NativeHud::rule() (NativeHud.cpp:125-129)：默认 opacity 0.4（NativeHud.h:261）。
  void _rule(double x, double y, double width, [double opacity = 0.4]) {
    hudRule(sink, dark, x, y, width, opacity);
  }

  /// Qt NativeHud::hit() (NativeHud.cpp:102-109)：六字段按 x/y/width/height/action/label 原序。
  void _hit(double x, double y, double width, double height, String action, String label) {
    hudHitRegion(sink, x, y, width, height, action, label);
  }

  /// Qt NativeHud::control() (NativeHud.cpp:121-124)。
  void _control(String label, double x, double y, double width, String action) {
    hudControl(sink, text, label, x, y, width, action, dark: dark);
  }

  /// Qt NativeHud::aligned() (NativeHud.cpp:44-46)。
  void _aligned(String value, double x, double y, double size, [String weight = 'regular', double tracking = 0]) {
    hudAligned(sink, text, value, x, y, size, weight: weight, tracking: tracking, dark: dark);
  }

  /// Qt NativeHud::button() 且 m_modalControls == false (NativeHud.cpp:110-119)：
  /// hit(x, y, width, height) + text(label, x + 0, y + (height - size) / 2 - 4, size, weight)；
  /// 不加 padding、不发 fill（archive 页从不把 m_modalControls 置 true，NativeHud.h:222）。
  void _button(String label, double x, double y, double width, double height, String action, double size,
      [String weight = 'regular']) {
    _hit(x, y, width, height, action, label);                      // :112
    _text(label, x, y + (height - size) / 2 - 4, size, weight);    // :118-119（inset == 0）
  }

  /// Qt NativeHud::roll() (NativeHud.cpp:97-101)：fit 后交给 rolling 端口，
  /// 端口负责滚动动画与命令发射（HudTextPort.rolling）。
  void _roll(String key, String value, double x, double y, double size, double width,
      [String weight = 'regular', bool numeric = false]) {
    final String shown = text.fit(value, size, width, weight);                                        // :99
    text.rolling(key, shown, x - text.glyphInset(shown, size, weight), y, size, weight, 0, numeric);  // :100
  }

  // Qt NativeHud::archive() (NativeHud.cpp:404-497)

  /// 画资料库页。drawTrackList / drawEmpty 为注入委托：
  ///   drawTrackList(width, s)  == Qt archiveTrackList(x, width)（track_ruler.dart）
  ///   drawEmpty(width, s)      == Qt empty(width)（directory_empty.dart）
  /// supportsTrackList(s) == Qt NativeHud::supportsTrackList()（NativeHudController.cpp:945-948）。
  void archive({
    required double width,
    required HudArchiveState s,
    required void Function(double width, HudArchiveState state) drawTrackList,
    required void Function(double width, HudArchiveState state) drawEmpty,
    required bool Function(HudArchiveState state) supportsTrackList,
  }) {
    // :405-407 const auto item = music.current; if (!item.isEmpty() && !id.isEmpty())
    final ArchiveItem? item = s.current;
    if (item != null && item.id.isNotEmpty) {
      // :408 const auto x = navigationLeft(width);
      final double x = width - HudChrome.navigationRightInset;

      // :409-419 目录栈：返回上一级 + 按目录 kind 的详情入口
      if (s.directory) {
        _control('← 返回上一级', 59, 211, 280, 'music:parent');                        // :410
        final String kind = s.directoryKind ?? '';                                    // :411
        String label = '查看歌单详情 ↗';                                                // :412
        if (kind == 'album') {
          label = '查看专辑详情 ↗';                                                    // :414
        } else if (kind == 'artist') {
          label = '查看歌手详情 ↗';                                                    // :416
        }
        _control(label, 59, 265, 310, 'music:directory-info');                        // :418
      }

      // :420-427 播放全部 / 在资料库中打开
      if ((s.directory && const <String>{'playlist', 'album', 'folder'}.contains(s.directoryKind ?? '')) ||
          (!s.directory && s.selectedLane == 1)) {
        _control('播放全部 →', 59, s.directory ? 319 : 211, 310, 'music:play-loaded'); // :423
      } else if (!s.directory && s.isSiren && s.selectedLane == 3) {
        _control('播放全部 →', 59, 211, 310, 'music:play-loaded');                     // :425
        _control('在资料库中打开 →', 59, 265, 310, 'music:open-all-siren');             // :426
      }

      // :428 const bool showTrackList = trackListMode && item["kind"] == "song";
      final bool showTrackList = s.trackListMode && item.kind == 'song';

      // :429-431 非曲目表态：来源滚动标题
      if (!showTrackList) {
        _roll('music-source', 'MUSIC DATABASE / ${s.libraryName}', x, 471, 12, width - x - 59);
      }

      if (showTrackList) {
        // :432-433 archiveTrackList(x, width)
        drawTrackList(width, s);
      } else {
        // :435-453 标题 / 命中 / 分隔线 / 头部点 / ID 行 / kind / 打开按钮 / 提示
        _roll('music-title', item.title, x, 509, 28, width - x - 59, 'bold');          // :435
        _hit(x, 509, 414, 37, 'open', item.title);                                    // :436
        _rule(x, 601, width - x - 59);                                                // :437
        _fill(const <Object?>[], x - 12, 598, 6, 6);                                  // :438 ink()
        final String kind = item.kind;                                                // :439
        _roll('music-id', '${kind.toUpperCase()} ID: ${item.id} / ${item.artist}', x, 624, 16,
            width - x - 210);                                                         // :440-442
        _text(kind.toUpperCase(), width - 170, 627, 11);                              // :443
        String label = '打开歌单资料库 →';                                              // :444
        if (kind == 'song') {
          label = '查看歌曲详情 →';                                                    // :446
        } else if (kind == 'album') {
          label = '打开专辑资料库 →';                                                  // :448
        } else if (kind == 'artist') {
          label = '浏览歌手作品 →';                                                    // :450
        }
        _control(label, x, 703, 300, 'open');                                         // :452
        _aligned('点击打开 · ENTER 键也可打开', x, 771, 14);                            // :453
      }

      // :455-460 曲目编号区
      _text('TRACK / SELECT', 60, 865, 11);                                           // :455
      trackNumber(libraryIndex: s.libraryIndex, libraryTotal: s.libraryTotal);        // :456-458
      _text('/', 141, 925, 32, 'light');                                              // :459
      _text(s.libraryTotal.toString(), 172, 932, 22);                                 // :460
    } else {
      // :461-463 empty(width)
      drawEmpty(width, s);
    }

    // :464-496 底部导航行（无论当前项是否存在都发射）
    final double nav = width * 0.2625;                                                // :464
    _button('↑', nav, 903, 46, 46, 'prev', 28);                                       // :465
    for (int index = 0; index < 8; ++index) {                                         // :466-477
      final double x = nav + 85 + index * 26;                                         // :467
      final int row = math.max(0, s.selectedPhysicalRow);                             // :468-469
      final List<Object?> color = hudInk(dark);                                       // :470
      color[3] = index == row ? 1 : 0.45;                                             // :471
      _fill(color, x, index == row ? 909 : 920, 2, index == row ? 33 : 12);           // :472
      if (!s.libraryItemsEmpty) {                                                     // :473
        _hit(x - 6, 900, 26, 50, 'music:slot:$index',
            '选曲 ${index + 1}');                                        // :474-475
      }
    }
    _button('↓', nav + 320, 903, 46, 46, 'next', 28);                                 // :478

    final double col = width * 0.5234375;                                             // :479
    _button('←', col, 903, 46, 46, 'column-prev', 28);                                // :480
    if (!s.directory) {                                                               // :481
      _text('COLLECTION ${_pad(s.sourceOrderIndex + 1)} / ${_pad(s.provider == 'kugou' ? 4 : 5)}',
          col + 70, 904, 10);                                                         // :482-484
      _roll('music-column', s.libraryName, col + 70, 925, 15, width - col - 360);     // :485
    } else {
      final String label = 'TRACK COLUMN ${_pad(s.selectedLane + 1)} / 05';      // :487
      _text(label, col + 62 + (171 - text.glyphWidth(label, 15)) / 2, 916, 15);       // :488
    }
    _button('→', col + 310, 903, 46, 46, 'column-next', 28);                          // :490

    if (supportsTrackList(s)) {                                                       // :491
      archiveTabButton(width: width, trackListMode: s.trackListMode);                 // :492
    }
    _text(
        s.directory
            ? '← → 浏览曲目列 / ↑ ↓ 选曲 / ENTER 查看 / ESC 上一级'
            : '← → 切换来源 / ↑ ↓ 选曲 / ENTER 查看 / 检索',
        nav,
        850,
        12);                                                                          // :494-496
  }

  /// Qt NativeHud::archiveTabButton(double width) (NativeHud.cpp:500-514)。
  void archiveTabButton({required double width, required bool trackListMode}) {
    final double x = width - 340;                                                     // :501
    _hit(x - 8, 854, 186, 48, 'archive:tab-mode', 'Tab Mode，按 Tab 切换');            // :502
    _text('Tab Mode', x, 866, 18, trackListMode ? 'bold' : 'regular');                 // :503
    final List<Object?> color = hudInk(dark);                                          // :504
    final double keyX = x + 108;                                                       // :505
    final String keycap = <String>[
      'M', _num(keyX), '864',
      'L', _num(keyX + 34), '864',
      'L', _num(keyX + 34), '888',
      'L', _num(keyX), '888',
      'Z',
    ].join(' ');                                                                       // :506
    sink.op(<Object?>['path', keycap, 1, color]);                                      // :507
    final String symbol = <String>[
      'M', _num(keyX + 7), '876',
      'L', _num(keyX + 23), '876',
      'M', _num(keyX + 18), '871',
      'L', _num(keyX + 23), '876',
      'L', _num(keyX + 18), '881',
      'M', _num(keyX + 27), '870',
      'L', _num(keyX + 27), '882',
    ].join(' ');                                                                       // :508-512
    sink.op(<Object?>['path', symbol, 1.2, color]);                                    // :513
  }

  /// Qt archive() 内的曲目编号滚动 (NativeHud.cpp:456-458)：
  ///   number = pad(libraryIndex + 1)
  ///   numberSize = min(58, 58 * 77 / max(1, glyphs->width(number, 58)))
  ///   rollingText("music-number", number, 60, 901.2, numberSize, "regular", 0, true)
  /// 与编号同行的 "/" 和总数由 archive() 直接以 text() 发射（NativeHud.cpp:459-460），
  /// 因此 libraryTotal 在本方法内不参与；保留该参数以对齐 Qt 调用点的断言。
  void trackNumber({required int libraryIndex, required int libraryTotal}) {
    final String number = _pad(libraryIndex + 1);                                      // :456
    final double numberSize =
        math.min(58.0, 58.0 * 77 / math.max(1.0, text.glyphWidth(number, 58)));         // :457
    text.rolling('music-number', number, 60, 901.2, numberSize, 'regular', 0, true);    // :458
  }
}
