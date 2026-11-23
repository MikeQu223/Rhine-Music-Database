/// 竖屏（compact）HUD 的播放队列页。
///
/// 真源：`Qt/src/ResponsiveHudPages.cpp:468-533` 的 `ResponsiveHudLayout::queue()`，
/// 逐条 1:1 移植（当前歌曲卡 → 播放模式按钮 + 四 chip → 队列分行 → 尾部说明 →
/// 应用音量滑轨 → 返回内容总高）；行/分节/按钮/chip 走
/// `Qt/src/ResponsiveHudCanvas.cpp` 的 `row()` / `section()` / `button()` / `chip()`。
///
/// 与参考实现的**唯一**几何差异：Qt 把 393 设计稿当常量（353 = 393-40、310/291 等
/// 都是绝对值），这里与 `portrait_pages_library.dart` 同口径，所有 x / 宽度按
/// `c.gridWidth` 相对推算，DPI 适配后页宽变宽也不会缩成中间一条窄柱。
///
/// 只把「一次排版」发射成命令流 + 命中表：滚动位置、模式展开态、当前行、音量都由
/// 宿主给出（BasicHudSurface / basic_app），本文件不持有任何状态，也不 import Flutter。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../scale/portrait_rhythm.dart';
import 'portrait_canvas.dart';

/// 页边距（Qt 全站 20 / 373）。
const double _left = 20;

/// 行高（`Qt/src/ResponsiveHudCanvas.cpp` `row()` 的 68）。
///
/// 不随屏高缩放：`PortraitCanvas.row()` 是横竖共用的排版单元，行内偏移 12/36/67
/// 与 44 的封面都写死在这个高度里，单独压缩会压字。
const double _rowHeight = 68;

/// 设计基准高度：16:9 舞台（1080×1920 舞台像素）换算成 393 宽的网格就是 393×698.67。
///
/// 队列页的纵向间距按 `c.height / _designHeight` 等比缩放：设计基准上
/// 158 / 102 / 19 / 24 / 44 / 17 / 45 这一组数字逐像素等于参考图（也等于旧实现
/// 的硬编码），矮屏按比例收，达到或超过基准就封顶在 1.0、不再拉大（富余高度留给
/// 队列行）。选 698.67 而不是 854 是因为前者正是画布在 1080×1920 上给出的
/// `gridHeight`（`BasicHudFrame.build(width: 1080, height: 1920, portrait: true)`），
/// 长屏手机（网格高 ~900）与它共用同一套间距，短屏才按比例收。
const double _designHeight = 698.6666666666666;

/// 内容起点（`ResponsiveHudLayout::arrange` 的 `c.beginContent(158)`）。
const double _designContentTop = 158;

/// 内容起点的下限：`PortraitCanvas.header()` 的标题底在 ≈117，再往上就压页头。
const double _minContentTop = 118;

/// 当前歌曲卡的高（参考图 102）与其下限（两行字 + 边距再小就挤）。
const double _designCardHeight = 102;
const double _minCardHeight = 84;

/// 播放模式词表与中文标签（Qt `queue()` 的 modes / labels，顺序固定）。
const List<String> portraitQueueModes = <String>['off', 'all', 'one', 'shuffle'];
const List<String> portraitQueueModeLabels = <String>[
  '顺序播放',
  '列表循环',
  '单曲循环',
  '随机播放',
];

/// 模式的中文标签；白名单外回落「顺序播放」（Qt `labels.value(indexOf(mode), "顺序播放")`）。
String portraitQueueModeLabel(String mode) {
  final int index = portraitQueueModes.indexOf(mode);
  return index < 0 ? '顺序播放' : portraitQueueModeLabels[index];
}

/// 队列一行：(标题, 艺人, 时长文案, 封面 key)。
typedef PortraitQueueRow = ({String title, String artist, String stamp, String image});

/// 播放队列页。返回内容总高（与 Qt `queue()` 的返回值同义：`y + scroll + 20` 与
/// 「最后一首置顶」的封底高取大者），宿主可用它做滚动上限。
///
/// 必须由 `paintPortraitShell` 的 content 回调调用（它已设好 `contentBottom`）；
/// 本函数自己开 `beginContent(158)` 的裁剪区并 `endContent()`，不调用 `finish()`。
double paintPortraitQueuePage(
  PortraitCanvas c, {
    /// 当前在播曲目标题；空串按 Qt 的缺省显示「等待音轨」。
    required String title,
    required String artist,
    required List<PortraitQueueRow> tracks,
    /// 当前行（`player.queue.index`）；-1 = 无当前项。
    required int currentIndex,
    /// `off` / `all` / `one` / `shuffle`。
    required String mode,
    /// 模式 chip 是否展开（Qt `m_queueModesExpanded`，由 `mobile:queue-modes` 翻转）。
    required bool modesExpanded,
    /// 应用音量区（Qt `m_player.applicationVolume`）：Android/iOS 恒 false，不画。
    bool applicationVolume = false,
    /// 0..1，超界由本函数 clamp（Qt `std::clamp(volume, 0., 1.)`）。
    double volume = 0,
    /// 滚动量（Qt `m_scroll`）。null = 按 Qt 的 `newScope` 规则从当前行推算，
    /// 让当前行落在内容区顶部；宿主有真实滚动真值时显式传入。
    double? scroll,
  }) {
  final double w = c.gridWidth;
  final double content = w - 2 * _left;

  // 纵向比例：基准高（393×698.67，即 16:9 舞台）上恰好复现参考图的
  // 158/102/19/24/44/17/45；矮屏按比例收，达到或超过基准直接取 1.0——不做
  // 「高屏放大」，也避免 `698.6667/698.6667` 这类浮点差把卡片压成 101.99。
  // 下限 .72 是「44 的按钮 + 36 的 chip 还得点得中」的经验底。
  // 与其余竖屏页共用同一条节奏线（[PortraitRhythm]：只收间距、字号不动、收到
  // 0.78 为止）。原先这里自带一套 `h/698.67 clamp(.72,1)`，两套下限不同会让
  // 同一块屏上的队列页比别的页更挤。
  final double d = PortraitRhythm.of(c.height);
  final double contentTop = math.max(_minContentTop, _designContentTop * d);
  final double cardHeight = math.max(_minCardHeight, _designCardHeight * d);
  // 卡内三行文案按卡高同比缩，卡片收到下限时文字不会越过卡片下沿。
  final double cardScale = cardHeight / _designCardHeight;
  final double cardGap = 19 * d;
  final double modeLabelRow = 24 * d;
  final double modeButtonGap = 17 * d;
  // chip 两行 = 36 + 44 行距 + 8 尾距；缩放不放低于这个实际需要。
  final double chipBlock = modesExpanded ? math.max(88, 96 * d) : 0;
  final double sectionRow = math.max(34, 45 * d);

  // 队列行起点：卡片 → 模式标签 → 模式按钮 → chip → 分节标题，全部自上而下累加。
  // 旧实现把 `158 / 121 / 61 / 45` 全部写死，矮屏（可用高不足 409-158+行）时
  // 分节和行会顶到模式按钮上。
  final double rowsTop =
      contentTop + cardHeight + cardGap + modeLabelRow + 44 + modeButtonGap + chipBlock + sectionRow;

  final double resolvedScroll =
      scroll ?? (currentIndex > 0 ? (rowsTop - contentTop) + currentIndex * _rowHeight : 0);

  // 队列页把整页（含当前歌曲卡与模式按钮）一起上移：Qt 是 `y = 158 - m_scroll`。
  double y = contentTop - resolvedScroll;

  // ── 当前歌曲卡 ────────────────────────────────────────────────────────
  final Rect card = Rect.fromLTWH(_left, y, content, cardHeight);
  c.fill(card, c.surface);
  c.border(card, c.line);
  c.text('ON AIR / 当前歌曲', _left + 17, y + 16 * cardScale,
      size: 9, width: content - 34, color: c.muted);
  c.text(
    title.isEmpty ? '等待音轨' : title,
    _left + 17,
    y + 38 * cardScale,
    size: 18,
    width: content - 34,
    weight: 'demibold',
  );
  c.text(artist, _left + 17, y + 72 * cardScale,
      size: 11, width: content - 34, color: c.muted);
  y = contentTop - resolvedScroll + cardHeight + cardGap;

  // ── 播放模式 ──────────────────────────────────────────────────────────
  c.text('PLAYBACK MODE / 播放模式', _left, y, size: 9, width: content, color: c.muted);
  y += modeLabelRow;
  c.button(
    Rect.fromLTWH(_left, y, content, 44),
    '${portraitQueueModeLabel(mode)}  ▾',
    'mobile:queue-modes',
  );
  y += 44 + modeButtonGap;
  if (modesExpanded) {
    // 四 chip 两列：Qt {20 + (i%2)*181, y + (i~/2)*44, 172, 36}，其中 172 + 9 + 172 = 353。
    final double chipWidth = (content - 9) / 2;
    for (int i = 0; i < portraitQueueModes.length; i++) {
      final String value = portraitQueueModes[i];
      c.chip(
        Rect.fromLTWH(
          _left + (i % 2) * (chipWidth + 9),
          y + (i ~/ 2) * 44,
          chipWidth,
          36,
        ),
        portraitQueueModeLabels[i],
        'player:mode:$value',
        selected: mode == value,
      );
    }
    y += chipBlock;
  }

  // ── 队列分节 + 清空 ───────────────────────────────────────────────────
  c.section(y, '播放队列  ${tracks.length}', '');
  // 「清空队列」贴右缘：Qt x=310（= 393-83）、宽 63；命中 {291, y-5, 82, 44}。
  c.text('清空队列', w - 83, y + 4, size: 12, width: 63, color: c.muted);
  c.hit(Rect.fromLTWH(w - 102, y - 5, 82, 44), 'player:clear', '清空队列');
  y = rowsTop - resolvedScroll;

  // ── 队列行（只画可视区间，裁剪由 beginContent 承担）──────────────────
  final double restoreBottom = c.contentBottom;
  c.beginContent(contentTop);
  final (int first, int last) = c.visibleRows(y, _rowHeight, tracks.length);
  for (int index = first; index < last; index++) {
    if (index < 0 || index >= tracks.length) {
      continue;
    }
    final PortraitQueueRow row = tracks[index];
    final bool current = index == currentIndex;
    c.row(
      y + index * _rowHeight,
      title: row.title,
      artist: row.artist,
      stamp: row.stamp,
      action: 'player:queue:$index',
      // 当前行序号用「●」，其余补零（Qt `MusicData::pad(index + 1)`）。
      number: current ? '●' : _pad(index + 1),
      current: current,
      // 当前曲不提供移除（Qt 传空串；PlaybackQueue 也拒绝删当前项）。
      remove: current ? '' : 'player:remove:$index',
      image: row.image,
      hasImage: row.image.isNotEmpty,
    );
  }
  c.endContent();
  c.contentBottom = restoreBottom;
  y += tracks.length * _rowHeight;

  // ── 空态 + 尾部说明 ───────────────────────────────────────────────────
  if (tracks.isEmpty) {
    c.text('播放队列为空', _left, y + 20, size: 17, width: content);
    y += 70;
  }
  y = c.paragraph(
        '清空仅移除待播歌曲，当前歌曲继续播放。',
        _left,
        y + 14,
        size: 12,
        width: content,
        color: c.muted,
      ) +
      24;

  // ── 应用音量（仅 applicationVolume 平台；手机端不画）───────────────────
  if (applicationVolume) {
    final double level = volume.clamp(0.0, 1.0);
    final double railWidth = w - 93; // Qt 300 = 393-93
    c.text('OUTPUT / 音量', _left, y, size: 9, width: content, color: c.muted);
    c.fill(Rect.fromLTWH(_left, y + 31, railWidth, 2), c.line);
    c.fill(Rect.fromLTWH(_left, y + 31, railWidth * level, 2), c.ink);
    c.text(
      '${(level * 100).round()}%',
      w - 65,
      y + 25,
      size: 11,
      width: 45,
      color: c.muted,
    );
    c.field('volume', Rect.fromLTWH(_left, y + 16, railWidth, 32));
    y += 62;
  }

  // Qt: max(y + m_scroll + 20, 409 + max(0, size-1)*68 + contentBottom - 158)。
  // 409/158 在这里换成随屏高算出来的 rowsTop/contentTop，「最后一首置顶」的封底
  // 因此仍然等于「最后一行滚到内容区顶部时的总高」，矮屏不会少算。
  final double bottom = math.max(
    y + resolvedScroll + 20,
    rowsTop + math.max(0, tracks.length - 1) * _rowHeight + c.contentBottom - contentTop,
  );
  return bottom;
}

/// 两位序号（Qt `MusicData::pad`，缺省 width=2）。
String _pad(int value) => value.toString().padLeft(2, '0');
