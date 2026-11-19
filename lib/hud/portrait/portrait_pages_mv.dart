/// 竖屏（compact）「关联 MV」面板。
///
/// **版式没有 Qt 真值，是自拟的**。仓库内 MV 文件只有 `Qt/src/MvController.cpp`、
/// `Qt/src/MvController.h`、`Qt/qml/MvWindow.qml`（960×790 的横屏窗口）、
/// `Qt/qml/MvDesktopControls.qml`、`Qt/qml/MvWallpaper.qml`、`Qt/tests/MvChecks.cpp`
/// 与 `docs/MV.md`——没有竖屏 MV 面板；而且 `Qt/src/PlatformFeatures.h:23-27` 的
/// `MusicVideo = !RHINE_MOBILE && (WIN|LINUX|MACOS)` 让整条 MV 路径在 Android 上恒关闭
/// （`Qt/src/NativeHudController.cpp:358-359`）。所以本页的几何按现有竖屏语法自拟：
/// 页头用 `PortraitCanvas.header`、分节用 `section`、行沿用 `indexRow` 的排版
/// （`lib/hud/portrait/portrait_pages_song.dart`、`portrait_pages_library.dart`）。
///
/// 语义逐条来自 Qt，不是自拟：
/// - 状态串原样显示（Qt :590-592 / :646-649 / :657-660 的文案，由领域层拼好）；
/// - 版本行的标签是 `[歌曲关联] `/`[搜索结果] ` + `title · artist · #id`
///   （Qt `versionLabels()`，:442-460）；
/// - `静音跟随音乐 · Np`（Qt :664）。
///
/// 边界：hud 层不 import lib/domain（与 `lib/hud/portrait/portrait_pages_comments.dart`、
/// `lib/hud/player/player_bar.dart:7` 同一条规矩），所以数据面是本文件自己的只读视图模型。
/// 宿主把 `lib/domain/mv/mv_controller.dart` 的 `MvState` 映射进来即可。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'portrait_canvas.dart';

/// 版本行（映射自 `ProviderMvVersion`）。
class PortraitMvVersionRow {
  const PortraitMvVersionRow({
    required this.id,
    required this.label,
    required this.associated,
  });

  /// 版本 id（命中 `mv:version:<id>`）。
  final String id;

  /// 已拼好的列表标签（Qt `versionLabels()` 的原样拼法）。
  final String label;

  /// 是否是歌曲关联版本（决定副标 `歌曲关联` / `搜索结果`）。
  final bool associated;
}

/// MV 面板的只读视图模型（映射自 `MvState`）。
class PortraitMvModel {
  const PortraitMvModel({
    this.status = '',
    this.title = '',
    this.trackId = '',
    this.resolution = 0,
    this.versionStatus = '',
    this.versions = const <PortraitMvVersionRow>[],
    this.selectedVersionId = '',
    this.auto = true,
    this.decodable = false,
  });

  /// 主状态串（Qt `status`）。
  final String status;

  /// 已解析的 MV 标题（空串 = 还没解析到）。
  final String title;

  /// MV id（空串 = 还没解析到）。
  final String trackId;

  /// 分辨率（0 = 未知）。
  final int resolution;

  /// 版本列表附注（Qt `versionStatus`）。
  final String versionStatus;

  /// 版本列表。
  final List<PortraitMvVersionRow> versions;

  /// 当前选中的版本 id。
  final String selectedVersionId;

  /// 是否自动查找。
  final bool auto;

  /// 是否有解码器：Android 侧恒 false，面板据此画 `本机未接入视频解码`。
  final bool decodable;
}

/// 393 网格的左右页边距（Qt 全站 20 / 373）。
const double _gutter = 20;

/// 版本行行高（`PortraitCanvas.indexRow` 的 68）。
const double _versionRowHeight = 68;

/// 内容起始 y（页头之下：header 标题在 87、分类在 69，正文自 130 起）。
const double portraitMvContentTop = 130.0;

/// 底部操作条的高度（状态行 + 两枚按钮 + 自动查找开关）。
const double portraitMvBarHeight = 152.0;

/// 正文宽：随页宽走（DPI 适配后页宽比 393 宽），左右各留 20 网格。
double _contentWidth(PortraitCanvas c) => c.gridWidth - 40;

/// 竖屏「关联 MV」面板。返回前必须调用 `c.finish()`。
void paintPortraitMvPage(
  PortraitCanvas c, {
  required PortraitMvModel model,
  // 版本列表的滚动窗口（条目单位，可为小数），语义同
  // `paintPortraitCollectionPage` 的 `position`。
  double position = 0,
}) {
  final double h = c.height;

  // 沉浸页：整页铺纸色，不把身后的 3D 场景透出来（与详情页/歌词页同一约定）。
  c.fill(Rect.fromLTWH(0, 0, c.gridWidth, math.max(0, h)), c.paper);

  c.header('关联 MV', back: true, backAction: 'close-modal');

  double y = portraitMvContentTop;

  // 状态行：原样显示领域层给出的 Qt 串。
  if (model.status.isNotEmpty) {
    y = c.paragraph(model.status, _gutter, y,
        size: 13, width: _contentWidth(c), maximumLines: 2, lineSpacing: 1.4);
    y += 12;
  }

  // 已解析的播放信息。
  if (model.title.isNotEmpty || model.trackId.isNotEmpty) {
    c.text(model.title.isEmpty ? model.trackId : model.title, _gutter, y,
        size: 15, width: _contentWidth(c), weight: 'demibold');
    y += 22;
    if (model.trackId.isNotEmpty) {
      c.text('MV ${model.trackId}', _gutter, y, size: 9, width: _contentWidth(c), color: c.muted);
      y += 18;
    }
    if (model.resolution > 0) {
      // Qt :664 的成功串。
      c.text('静音跟随音乐 · ${model.resolution}p', _gutter, y, size: 12, width: _contentWidth(c));
      y += 22;
    }
    // 诚实降级：没有解码器就不假装在放画面。
    if (!model.decodable) {
      c.text('本机未接入视频解码', _gutter, y, size: 12, width: _contentWidth(c), color: c.amber);
      y += 26;
    }
  }

  // 版本附注（Qt m_versionStatus）。
  if (model.versionStatus.isNotEmpty) {
    c.text(model.versionStatus, _gutter, y, size: 11, width: _contentWidth(c), color: c.muted);
    y += 20;
  }

  c.section(y, '视频版本', model.versions.isEmpty ? '未找到' : '${model.versions.length} 个可用');
  y += 30;

  final double barTop = math.max(y + 40, h - 34 - portraitMvBarHeight);
  final double bottom = math.max(y, barTop - 8);
  c.contentBottom = bottom;
  c.beginContent(y);
  if (model.versions.isEmpty) {
    c.text('当前来源没有可选的视频版本', _gutter, y + 12,
        size: 12, width: _contentWidth(c), color: c.muted);
  } else {
    final double scroll = _clampScroll(position, model.versions.length, bottom - y);
    final int first = math.max(0, scroll.floor());
    for (int index = first; index < model.versions.length; index++) {
      final double rowY = y + index * _versionRowHeight - scroll;
      if (rowY >= bottom) {
        break;
      }
      if (rowY + _versionRowHeight <= y) {
        continue;
      }
      _versionRow(c, rowY, model.versions[index],
          current: model.versions[index].id == model.selectedVersionId);
    }
  }
  c.endContent();

  // 底部操作条：重新查找 / 刷新版本 / 自动查找开关。
  if (barTop + portraitMvBarHeight <= h + 1) {
    c.fill(Rect.fromLTWH(0, barTop, c.gridWidth, 1), c.line);
    final double buttonY = barTop + 22;
    final double buttonWidth = (_contentWidth(c) - 12) / 2;
    c.button(Rect.fromLTWH(_gutter, buttonY, buttonWidth, 44), '重新查找', 'mv:retry');
    c.button(Rect.fromLTWH(_gutter + buttonWidth + 12, buttonY, buttonWidth, 44), '刷新版本',
        'mv:versions');
    final double toggleY = buttonY + 56;
    if (toggleY + 30 <= h) {
      c.text(model.auto ? '自动查找：开' : '自动查找：关', _gutter, toggleY, size: 12,
          width: math.max(0, _contentWidth(c) - 108), color: c.muted);
      c.chip(Rect.fromLTWH(c.gridWidth - 92, toggleY - 8, 72, 30), model.auto ? '关闭' : '打开',
          model.auto ? 'mv:auto:off' : 'mv:auto:on',
          selected: model.auto);
    }
  }

  c.finish();
}

/// 一行版本：`indexRow` 的同款排版 + 当前选中标记 + `mv:version:<id>` 命中。
void _versionRow(PortraitCanvas c, double y, PortraitMvVersionRow row, {required bool current}) {
  final double rowWidth = _contentWidth(c);
  if (current) {
    c.fill(Rect.fromLTWH(_gutter, y, rowWidth, 67), c.raised);
    c.fill(Rect.fromLTWH(_gutter, y, 2, 67), c.amber);
  }
  // label 就是 Qt versionLabels() 的原样拼法，直接显示、不拆字段。
  final double textWidth = math.max(0, c.gridWidth - 52 - 54);
  c.text(row.label, _gutter + 8, y + 16, size: 13, width: textWidth, weight: 'demibold');
  c.text(row.associated ? '歌曲关联' : '搜索结果', _gutter + 8, y + 38,
      size: 10, width: textWidth, color: c.muted);
  if (current) {
    c.text('当前', c.gridWidth - 62, y + 26, size: 10, width: 34, color: c.amber);
  }
  c.fill(Rect.fromLTWH(_gutter, y + 67, rowWidth, .6), c.line);
  c.hit(Rect.fromLTWH(_gutter, y, rowWidth, 67), 'mv:version:${row.id}', row.label);
}

/// 版本列表的滚动上界（宿主夹取用；语义同 `ResponsiveHudLayout.cpp:238-244`）。
///
/// 返回条目单位的上界；可视高度由调用方按同一套几何算出（见 [portraitMvPlainViewport]）。
double portraitMvMaxScroll(double contentTop, double contentBottom, int total) {
  final double viewport = math.max(0, contentBottom - contentTop);
  final double rows = math.max(1, viewport / _versionRowHeight);
  return math.max(0, total - rows);
}

/// 版本列表的可视高度（供宿主算夹取上界），与 [paintPortraitMvPage] 同一公式。
double portraitMvListViewport(PortraitCanvas c, double contentTopSoFar) {
  final double barTop = math.max(contentTopSoFar + 40, c.height - 34 - portraitMvBarHeight);
  return math.max(0, barTop - 8 - contentTopSoFar);
}

/// 滚动夹取：条目位置夹在 `[0, max(0, total - 可视行数)]`，不越界、不产生负高度。
double _clampScroll(double position, int total, double viewport) {
  final double rows = math.max(1, viewport / _versionRowHeight);
  final double maxScroll = math.max(0, total - rows);
  if (!position.isFinite || position < 0) {
    return 0;
  }
  return position > maxScroll ? maxScroll : position;
}
