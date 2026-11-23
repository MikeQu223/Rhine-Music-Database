/// 竖屏「我的音乐」总览页（Qt compact `library()` 的 `m_savedOverview` 分支）。
///
/// 真源：`Qt/src/ResponsiveHudPages.cpp:858-892`，逐条 1:1：
///   - 卡 `{20, y, 353, 102}`（surface + 1px line 边框）
///   - `PERSONAL MUSIC DATABASE`(37, y+16, 9, muted)
///   - `我的音乐`(37, y+38, 18, demibold)
///   - `<平台名> / <用户名>`(37, y+73, 11, muted)
///   - `y += 126`
///   - `c.section(y, "收藏与档案", "PERSONAL INDEX")` → `y += 36`
///   - 每个收藏列一行 `indexRow`（`music:collection:<lane>`，第 1 列 heart、其余 folder）
///   - 可选 `收藏歌手`（`mobile:artists`）/ `播放历史`（`mobile:history`）/
///     `设置`（`settings`）
///   - 可选 `+ 创建歌单` 按钮（`music:create-playlist`）
///
/// 与参考实现的差异：Qt 用 393 设计稿常量（353 = 393-40、y 均为绝对值），这里
/// 与其它竖屏页同口径，宽度按 `c.gridWidth` 相对推算，DPI 适配后页宽变宽也不会
/// 缩成中间一条窄柱。返回内容总高（供宿主算滚动上限）。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../scale/portrait_rhythm.dart';
import 'portrait_canvas.dart';
import 'portrait_layout.dart';

/// 总览页的内容起点（Qt `library()` 的非检索分支：`y = 158 - m_scroll`）。
const double portraitSavedOverviewContentTop = 158;

/// 总览页返回动作（Qt 把 saved 页的 `close-modal` 全部改写成 `mobile:mine`）。
const String portraitSavedBackAction = 'mobile:mine';

/// 总览页的动作串（与 Qt 常量一致）。
const String portraitSavedArtistsAction = 'mobile:artists';
const String portraitSavedHistoryAction = 'mobile:history';
const String portraitSavedCreatePlaylistAction = 'music:create-playlist';

/// 一行索引项（`c.indexRow`）的数据。
class PortraitSavedOverviewRow {
  const PortraitSavedOverviewRow({
    required this.title,
    required this.subtitle,
    required this.action,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final String action;

  /// 图标名：`heart` / `folder` / `user` / `compass` / `settings`。
  final String icon;
}

/// 画「我的音乐」总览页。返回内容总高（含滚动偏移）。
double paintPortraitSavedOverview(
  PortraitCanvas c, {
  required String providerName,
  required String userName,
  required List<PortraitSavedOverviewRow> collectionRows,
  bool showArtists = false,
  bool canCreatePlaylist = false,
  double scroll = 0,
}) {
  final double w = c.gridWidth;
  final double pageBottom = c.contentBottom;
  c.fill(Rect.fromLTWH(0, 0, w, math.max(0, c.height)), c.paper);
  paintPortraitTerminalHeader(
    c,
    title: '我的音乐',
    code: '04',
    identifier: 'SAVED / 收藏与档案',
  );
  // 终端页头之下的返回按钮（Qt 在 saved 非总览态才给 back，总览态由 `saved`
  // 动作自己进出；这里给一个回资料库的入口，避免总览独占一屏后无法返回）。
  c.icon('back', 28, 88, size: 18, color: c.ink);
  c.hit(Rect.fromLTWH(16, 76, 44, 44), portraitSavedBackAction, '返回资料库');

  // 起点与各段推进量按页高节奏收（矮屏上 158 + 126 + 36 + 5×68 会直接把
  // 「设置」那行推到裁剪线以下；高屏不收，保持参考图间距）。
  final double h = c.height;
  final double stride = PortraitRhythm.gap(68, h);
  double y = PortraitRhythm.below(110, portraitSavedOverviewContentTop, h) - scroll;
  c.beginContent(y);

  // 卡：surface + line 边框，102 高。
  c.fill(Rect.fromLTWH(20, y, w - 40, 102), c.surface);
  c.border(Rect.fromLTWH(20, y, w - 40, 102), c.line);
  c.text('PERSONAL MUSIC DATABASE', 37, y + 16, size: 9, width: w - 74, color: c.muted);
  c.text('我的音乐', 37, y + 38, size: 18, width: w - 74, weight: 'demibold');
  final String owner = userName.isEmpty ? providerName : '$providerName / $userName';
  c.text(owner, 37, y + 73, size: 11, width: w - 74, color: c.muted);
  y += PortraitRhythm.gap(126, h);

  c.section(y, '收藏与档案', 'PERSONAL INDEX');
  y += PortraitRhythm.gap(36, h);

  for (final PortraitSavedOverviewRow row in collectionRows) {
    c.indexRow(y, row.title, row.subtitle, row.action, row.icon);
    y += stride;
  }
  if (showArtists) {
    c.indexRow(y, '收藏歌手', 'ARTIST RECORDS', portraitSavedArtistsAction, 'user');
    y += stride;
  }
  c.indexRow(y, '播放历史', 'RECENT TRACKS', portraitSavedHistoryAction, 'compass');
  y += stride;
  c.indexRow(y, '设置', 'TERMINAL PREFERENCES', 'settings', 'settings');
  y += stride;
  if (canCreatePlaylist) {
    c.button(Rect.fromLTWH(20, y, w - 40, 44), '+ 创建歌单', portraitSavedCreatePlaylistAction);
    y += 60;
  }

  c.endContent();
  c.finish();
  // 内容总高：末行下沿 + 20（Qt 同 `return y + m_scroll + 20`），并保证不小于视口。
  final double contentHeight = y + scroll + 20;
  return math.max(contentHeight, pageBottom + 20);
}
