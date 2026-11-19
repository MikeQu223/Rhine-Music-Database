/// 竖屏（compact）「关联 MV」面板。
///
/// 版式说明（必须如实标注）：**Qt 没有竖屏 MV 面板**。仓库内 MV 相关文件只有
/// `Qt/src/MvController.cpp`、`Qt/src/MvController.h`、`Qt/qml/MvWindow.qml`（960×790
/// 的横屏窗口）、`Qt/qml/MvDesktopControls.qml`、`Qt/qml/MvWallpaper.qml`、
/// `Qt/tests/MvChecks.cpp` 与 `docs/MV.md`；`Qt/src/PlatformFeatures.h:23-27` 的
/// `MusicVideo = !RHINE_MOBILE && (WIN|LINUX|MACOS)` 又让整条 MV 路径在 Android 上
/// 恒关闭（`Qt/src/NativeHudController.cpp:358-359`）。因此本页的几何**没有 Qt 像素真值**，
/// 是按现有竖屏语法自拟的：页头用 `PortraitCanvas.header`、分节用 `section`、行用
/// `indexRow` 的同款排版（见 `lib/hud/portrait/portrait_pages_song.dart` 与
/// `portrait_pages_library.dart`）。
///
/// 语义仍然逐条来自 Qt：
/// - 状态串直接显示 `MvController.status`（:590-592 / :646-649 / :657-660 / :664）；
/// - 版本列表显示 `ProviderMvVersion.label`（Qt `versionLabels()`，:442-460）；
/// - `静音跟随音乐 · Np` 行就是 Qt :664 的成功串（本页不重拼，读 state.status）；
/// - 手机侧没有解码器：phase == playing 时额外画 `本机未接入视频解码`（诚实降级）。
///
/// 本文件只排版：不持有状态、不请求、不 import flutter。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../../domain/mv/mv_controller.dart';
import '../../provider/provider_gateway.dart';
import 'portrait_canvas.dart';

/// 393 网格的左右页边距（Qt 全站 20 / 373）。
const double _gutter = 20;

/// 版本行行高（`PortraitCanvas.indexRow` 的 68）。
const double _versionRowHeight = 68;

/// 正文宽：随页宽走（DPI 适配后页宽比 393 宽），左右各留 20 网格。
double _contentWidth(PortraitCanvas c) => c.gridWidth - 40;

/// 竖屏「关联 MV」面板。返回前必须调用 `c.finish()`。
///
/// [state] 是 [MvController] 的快照；[position] 是版本列表的滚动窗口（条目单位，
/// 可为小数，语义同 `paintPortraitCollectionPage` 的 `position`）。
void paintPortraitMvPage(
  PortraitCanvas c, {
  required MvState state,
  double position = 0,
}) {
  final double h = c.height;

  // 沉浸页：整页铺纸色，不把身后的 3D 场景透出来（与详情页/歌词页同一约定）。
  c.fill(Rect.fromLTWH(0, 0, c.gridWidth, math.max(0, h)), c.paper);

  c.header('关联 MV', back: true, backAction: 'close-modal');

  double y = 130;

  // 状态行：直接显示 Qt 的状态串，不翻译、不美化。
  final String status = state.status;
  if (status.isNotEmpty) {
    y = c.paragraph(status, _gutter, y,
        size: 13,
        width: _contentWidth(c),
        maximumLines: 2,
        lineSpacing: 1.4);
    y += 10;
  }

  // 已解析的播放信息：标题 / 分辨率 / 静音跟随行。
  final ProviderMvTrack? track = state.track;
  if (track != null) {
    c.text(track.title, _gutter, y, size: 15, width: _contentWidth(c), weight: 'demibold');
    y += 22;
    c.text('MV ${track.id}', _gutter, y, size: 9, width: _contentWidth(c), color: c.muted);
    y += 18;
    // Qt :664 的成功串：`静音跟随音乐 · %1p`（state.status 与 resolution 同源）。
    c.text('静音跟随音乐 · ${track.resolution}p', _gutter, y, size: 12, width: _contentWidth(c));
    y += 22;
    // 手机侧的诚实降级：没有解码器就不假装在放画面。
    c.text('本机未接入视频解码', _gutter, y, size: 12, width: _contentWidth(c), color: c.amber);
    y += 26;
  }

  // 版本列表附注（Qt m_versionStatus：warning / 未找到其他视频版本 / 加载失败可重试）。
  if (state.versionStatus.isNotEmpty) {
    c.text(state.versionStatus, _gutter, y, size: 11, width: _contentWidth(c), color: c.muted);
    y += 20;
  }

  // 版本列表：有就列，没有就说明"为什么没有"。
  c.section(y, '视频版本', state.hasVersions ? '${state.versions.length} 个可用' : '未找到');
  y += 30;

  final double bottom = math.max(y + 80, h - 34);
  c.contentBottom = bottom;
  c.beginContent(y);
  final List<ProviderMvVersion> rows = state.versions;
  if (rows.isEmpty) {
    c.text('当前来源没有可选的视频版本', _gutter, y + 12,
        size: 12, width: _contentWidth(c), color: c.muted);
  } else {
    final double scroll = _clampScroll(position, rows.length, bottom - y);
    final int first = math.max(0, scroll.floor());
    for (int index = first; index < rows.length; index++) {
      final double rowY = y + index * _versionRowHeight - scroll;
      if (rowY >= bottom) {
        break;
      }
      if (rowY + _versionRowHeight <= y) {
        continue;
      }
      final ProviderMvVersion version = rows[index];
      final bool current = version.id == state.selectedVersionId;
      _versionRow(c, rowY, version, current: current);
    }
  }
  c.endContent();

  // 底部操作：重试 / 刷新版本 / 自动查找开关。竖屏 MV 是整页，不做迷你播放条。
  final double barTop = math.max(y + 40, h - 96);
  if (barTop < h - 8) {
    c.fill(Rect.fromLTWH(0, barTop, c.gridWidth, 1), c.line);
    final double buttonY = barTop + 22;
    final double buttonWidth = (_contentWidth(c) - 12) / 2;
    c.button(Rect.fromLTWH(_gutter, buttonY, buttonWidth, 44), '重新查找', MvAction.retry);
    c.button(
      Rect.fromLTWH(_gutter + buttonWidth + 12, buttonY, buttonWidth, 44),
      '刷新版本',
      MvAction.versions,
    );
    final double toggleY = buttonY + 52;
    if (toggleY + 30 < h) {
      c.text(state.auto ? '自动查找：开' : '自动查找：关', _gutter, toggleY,
          size: 12, width: _contentWidth(c) - 100, color: c.muted);
      c.chip(
        Rect.fromLTWH(c.gridWidth - 92, toggleY - 8, 72, 30),
        state.auto ? '关闭' : '打开',
        state.auto ? MvAction.autoOff : MvAction.autoOn,
      );
    }
  }

  c.finish();
}

/// 一行版本：`indexRow` 的同款排版 + 当前选中标记 + `mv:version:<id>` 命中。
void _versionRow(
  PortraitCanvas c,
  double y,
  ProviderMvVersion version, {
  required bool current,
}) {
  final double rowWidth = c.gridWidth - 40;
  if (current) {
    c.fill(Rect.fromLTWH(_gutter, y, rowWidth, 67), c.raised);
    c.fill(Rect.fromLTWH(_gutter, y, 2, 67), c.amber);
  }
  // label 是 Qt versionLabels() 的原样拼法，直接显示不拆字段。
  final double textWidth = c.gridWidth - 52 - 54;
  c.text(version.label, _gutter + 8, y + 16, size: 13, width: textWidth, weight: 'demibold');
  c.text(
    version.associated ? '歌曲关联' : '搜索结果',
    _gutter + 8,
    y + 38,
    size: 10,
    width: textWidth,
    color: c.muted,
  );
  if (current) {
    c.text('当前', c.gridWidth - 62, y + 26, size: 10, width: 34, color: c.amber);
  }
  c.fill(Rect.fromLTWH(_gutter, y + 67, rowWidth, .6), c.line);
  c.hit(Rect.fromLTWH(_gutter, y, rowWidth, 67), MvAction.version(version.id), version.label);
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
