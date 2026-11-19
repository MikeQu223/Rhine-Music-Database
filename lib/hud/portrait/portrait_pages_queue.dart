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

import 'portrait_canvas.dart';

/// 页边距（Qt 全站 20 / 373）。
const double _left = 20;

/// 行高（`Qt/src/ResponsiveHudCanvas.cpp` `row()` 的 68）。
const double _rowHeight = 68;

/// 内容起点（`ResponsiveHudLayout::arrange` 的 `c.beginContent(158)`）。
const double _contentTop = 158;

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
  final double resolvedScroll = scroll ??
      (currentIndex > 0 ? 251 + currentIndex * _rowHeight : 0);

  // 队列页把整页（含当前歌曲卡与模式按钮）一起上移：Qt 是 `y = 158 - m_scroll`。
  double y = _contentTop - resolvedScroll;

  // ── 当前歌曲卡 ────────────────────────────────────────────────────────
  final Rect card = Rect.fromLTWH(_left, y, content, 102);
  c.fill(card, c.surface);
  c.border(card, c.line);
  c.text('ON AIR / 当前歌曲', _left + 17, y + 16,
      size: 9, width: content - 34, color: c.muted);
  c.text(
    title.isEmpty ? '等待音轨' : title,
    _left + 17,
    y + 38,
    size: 18,
    width: content - 34,
    weight: 'demibold',
  );
  c.text(artist, _left + 17, y + 72, size: 11, width: content - 34, color: c.muted);
  y += 121;

  // ── 播放模式 ──────────────────────────────────────────────────────────
  c.text('PLAYBACK MODE / 播放模式', _left, y, size: 9, width: content, color: c.muted);
  y += 24;
  c.button(
    Rect.fromLTWH(_left, y, content, 44),
    '${portraitQueueModeLabel(mode)}  ▾',
    'mobile:queue-modes',
  );
  y += 61;
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
    y += 96;
  }

  // ── 队列分节 + 清空 ───────────────────────────────────────────────────
  c.section(y, '播放队列  ${tracks.length}', '');
  // 「清空队列」贴右缘：Qt x=310（= 393-83）、宽 63；命中 {291, y-5, 82, 44}。
  c.text('清空队列', w - 83, y + 4, size: 12, width: 63, color: c.muted);
  c.hit(Rect.fromLTWH(w - 102, y - 5, 82, 44), 'player:clear', '清空队列');
  y += 45;

  // ── 队列行（只画可视区间，裁剪由 beginContent 承担）──────────────────
  final double restoreBottom = c.contentBottom;
  c.beginContent(_contentTop);
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
  final double bottom = math.max(
    y + resolvedScroll + 20,
    409 + math.max(0, tracks.length - 1) * _rowHeight + c.contentBottom - _contentTop,
  );
  return bottom;
}

/// 两位序号（Qt `MusicData::pad`，缺省 width=2）。
String _pad(int value) => value.toString().padLeft(2, '0');
