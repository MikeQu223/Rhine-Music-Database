/// 竖屏（compact）HUD 的「歌曲操作」底部 sheet：命令流排版，不建 widget。
///
/// 真值来源（逐条对齐，C++ 语法改写为 Dart 命令流）：
/// - `Qt/src/ResponsiveLyrics.cpp:236-276` `ResponsiveHudLayout::optionsSheet`：
///   清掉 seek/volume 字段 → 顶边 `max(118., m_height - BottomGestureInset - 416)`
///   → surface 填充 + 1 高分隔线 → 「歌曲操作」18 号标题 → 两列按钮网格
///   （`{20+(i%2)*181, y+(i/2)*52, 172, 44}`，`y = sheetTop + 56`）→ 网格下 12 处
///   `album + " / " + duration` 元信息行 → 其下 25 处 4 行封顶的说明段落。
/// - `Qt/src/ResponsiveHudLayout.h:16`：`BottomGestureInset = 34`。
/// - 原语走 `Qt/src/ResponsiveHudCanvas.cpp` 的 `fill` / `text` / `button` / `paragraph`，
///   本文件不新造画布原语。
///
/// 与 Qt 原文的两处口径差异，都写在这里免得后来者对不上：
/// 1. Qt 的 416 是**内容**高度，34 的手势内缩只让填充铺到屏幕底；任务书要求
///    「sheet 高度就是 416」，所以这里取 `sheetTop = min(max(118, h - 416), h)`、
///    返回 `h - sheetTop`（h ≥ 534 时恒为 416）。118 的地板与 Qt 的 `max(118., …)` 同义，
///    短屏不会把 sheet 顶到页头以上。
/// 2. Qt 的两列 x 差 181 = 按钮 172 + 间隔 9。本仓库页宽随 DPI 变（`c.gridWidth`），
///    所以按「左右各 20 + 中间 9 间隔，两列等分」重算：393 页宽上仍是 20 / 201 / 172 宽，
///    586 页宽上变成 20 / 297.5 / 268.5 宽，不再写死 393 的 172/181。
///    垂直方向的 52 行距与 44 高是元素尺寸，不随页宽变，保持 Qt 原值。
///
/// 只画 sheet 自己：整页半透明遮罩、整屏「收起操作」热区（Qt 在 `:238` 发射的
/// `mobile:song-options`，区间 `{0,118,393,h-118}`）都由调用方负责；本函数不铺纸色、
/// 不调 `c.finish()`，并且必须在其它页面内容之后调用（它清 seek/volume 字段，
/// 正是 Qt 「sheet 打开时底层拖动/音量失效」的语义）。
///
/// 纯 Dart：不 import Flutter。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'portrait_canvas.dart';

/// sheet 设计高度（`Qt/src/ResponsiveLyrics.cpp:240` 的 416）。
const double portraitSongOptionsHeight = 416;

/// sheet 顶边的地板（Qt 同式 `std::max(118., …)`；短屏也不压到页头以上）。
const double portraitSongOptionsMinTop = 118;

/// 底部「歌曲操作」sheet。
///
/// 返回 sheet 的实际高度（网格单位）：`min(max(118, h - 416), h)` 到屏幕底；
/// 800 高画布上即 416、顶边 384。调用方可用它做遮罩高度或收起动画的终点。
///
/// - [actions]：按钮表，每项 `(label, action)`。i 从 0 起两列排布，第 i 个按钮
///   命中串就是 `action` 原样（空串 = 只画按钮不发射热区，与 Qt 跳过空 route 同义）。
///   Qt 侧这张表由调用方拼（primary/secondaryActions + 官方客户端 + 查看评论），
///   本函数不做业务过滤。
/// - [detail]：网格下 12 处的元信息行，形如 `专辑名 / 04:21`（Qt 的
///   `album + " / " + duration`）。空串不画。
/// - [detailBody]：元信息行下 25 处的段落说明，12 号、最多 4 行（Qt 的
///   `source["detailBody"]`，超行由 `paragraph` 补省略号）。
/// - [scrollOffset]：把按钮网格与底部说明整体上移的位移（网格单位，≥0）。sheet 内容
///   超出「屏幕底上方 20」时才允许滚动，传入值会被夹到可用溢出量；null = 不滚动
///   （Qt 的 sheet 不滚，放不下的部分直接出屏）。滚动只影响网格与说明，标题与分隔线
///   不动，内容裁剪在 sheet 内容区（`sheetTop + 56` 起）之内。
double paintPortraitSongOptions(
  PortraitCanvas c, {
  required List<(String label, String action)> actions,
  required String detail,
  String detailBody = '',
  double? scrollOffset,
}) {
  final double h = math.max(0, c.height);
  final double w = c.gridWidth;
  const double gutter = 20;
  final double innerWidth = math.max(0, w - gutter * 2);

  // Qt :237-238：sheet 打开时底层的拖动/音量热区失效（fields 在画布上，命中表之外）。
  c.fields.remove('seek');
  c.fields.remove('volume');

  // Qt :240：`const double sheetTop = std::max(118., m_height - BottomGestureInset - 416);`
  // 手势内缩 34 已含在任务书口径的 416 里（见文件头第 1 条差异）。
  final double sheetTop =
      math.min(math.max(portraitSongOptionsMinTop, h - portraitSongOptionsHeight), h);
  final double sheetHeight = math.max(0, h - sheetTop);

  // Qt :241-242：表面填充铺到屏幕底 + 顶沿 1 高分隔线（353 = 页宽 - 左右各 20）。
  c.fill(Rect.fromLTWH(0, sheetTop, w, sheetHeight), c.surface);
  c.fill(Rect.fromLTWH(gutter, sheetTop, innerWidth, 1), c.line);

  // Qt :243：标题 18 号 demibold，文本宽 300（设计稿值，窄页按右缘收回）。
  c.text('歌曲操作', gutter, sheetTop + 18,
      size: 18, width: math.min(300, innerWidth), weight: 'demibold');

  // Qt :272 起排位置与 :265 的网格：两列 + 9 间隔（393 上 20 / 201、172 宽）。
  const double gap = 9;
  const double rowStride = 52;
  const double buttonHeight = 44;
  final double buttonWidth = math.max(0, (innerWidth - gap) / 2);
  final double columnStride = buttonWidth + gap;
  final int rows = (actions.length + 1) ~/ 2;

  final double gridTop = sheetTop + 56;
  // Qt :273：网格之后 `y += ((actions.size() + 1) / 2) * 52 + 12`。
  final double metaY = gridTop + rows * rowStride + 12;

  // Qt :274：说明段落 12 号、4 行封顶、行距 1.5（12 × 1.5 = 18）。
  const double blockGap = 25;
  const double lineHeight = 12 * 1.5;
  final List<String> bodyLines =
      detailBody.isEmpty ? const <String>[] : c.wrap(detailBody, innerWidth, 12);
  final int bodyCount = math.min(4, bodyLines.length);
  final double contentBottom = metaY + (bodyCount == 0 ? 0 : blockGap + bodyCount * lineHeight);

  // 滚动量：只允许把「超出的那一截」推到屏幕底上方 20 的位置。
  final double overflow = math.max(0, contentBottom - math.max(0, h - 20));
  final double offset = math.min(math.max(0, scrollOffset ?? 0), overflow);

  // 裁剪区就是 sheet 的内容区：标题/分隔线在 beginContent 之前画，不受滚动影响。
  final double savedContentBottom = c.contentBottom;
  c.contentBottom = h;
  c.beginContent(gridTop);

  // Qt :272-276：第 i 个按钮 `{20+(i%2)*181, y+(i/2)*52, 172, 44}`，
  // 走 `PortraitCanvas.button`（Qt 同名原语：surface + 1px 边框 + 标签 + 原样动作串）。
  for (int index = 0; index < actions.length; index++) {
    final (String label, String action) = actions[index];
    c.button(
      Rect.fromLTWH(gutter + (index % 2) * columnStride,
          gridTop - offset + (index ~/ 2) * rowStride, buttonWidth, buttonHeight),
      label,
      action,
    );
  }

  // Qt :275：`c.text(album + " / " + duration, 20, y, 12, 353, "regular", c.muted)`。
  if (detail.isNotEmpty) {
    c.text(detail, gutter, metaY - offset, size: 12, width: innerWidth, color: c.muted);
  }
  // Qt :275：`c.paragraph(source["detailBody"], 20, y + 25, 12, 353, c.muted, "regular", 4)`。
  if (bodyCount > 0) {
    c.paragraph(detailBody, gutter, metaY + blockGap - offset,
        size: 12, width: innerWidth, color: c.muted, maximumLines: 4, lineSpacing: 1.5);
  }

  c.endContent();
  c.contentBottom = savedContentBottom;
  return sheetHeight;
}
