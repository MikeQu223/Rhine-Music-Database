/// 横屏（landscape）「关联 MV」弹层：`modalId = 'mv'`。
///
/// 外壳（save / alpha / 遮罩 / translate / 面板底 / 标题区 / close-modal / restore）
/// 由 `lib/hud/modals/modal_shell.dart` 统一负责，本文件只画内容：
///
/// - 版式语义取自 Qt 唯一一份横屏 MV 界面 `Qt/qml/MvWindow.qml`（960×790 窗口，
///   `Qt/src/PlatformFeatures.h:23-27` 在 Android 上恒关）：分类行
///   `RHINE LAB / MUSIC DATABASE / VIDEO TERMINAL`（:245）、标题 `MUSIC VIDEO`（:253）、
///   副标 `关联影像 / ` + title 或 `静音跟随音乐播放`（:333）、待机区居中状态串 +
///   `重新查找 MV`（:442）、底行 `status · versionStatus`（:560）、
///   `画面偏移 X.Xs`（:566）与 `刷新版本` / `−0.5s` / `+0.5s` / `归零`（:571-583）。
/// - 这些**不是像素对齐**：MvWindow 是桌面窗口（标题栏/页脚/置顶/壁纸/全屏那一整套
///   都不适用于移动端），本弹层只保留移动端有意义的四块：状态、版本列表、画面偏移、
///   自动查找开关。**版式是自拟的，语义是抄的**。
/// - 手机上没有解码器：内容区固定画 `本机未接入视频解码`（诚实降级，不伪造播放）。
///
/// 命中动作全部是 `mv:*`（唯一定义处见 `lib/domain/mv/mv_controller.dart` 的
/// [MvAction]），另外外壳自带 `close-modal`。
///
/// 本文件不 import flutter、不 import lib/domain：数据面是注入的 [MvPanelModel]。
library;

import 'dart:math' as math;

import 'package:rhine_music_database/hud/modals/modal_shell.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_mv.dart'
    show MvPanelModel, MvPanelVersionRow;

/// 版本行行高（舞台单位，1080 高归一化后；竖屏 68 网格 ≈ 同一量级）。
const double mvModalRowHeight = 68;

/// 内容左右内缩（对齐通用弹层的 kModalShellHeaderInset 53）。
const double mvModalInset = 53;

/// 版本列表的上界（条目单位），宿主据此夹取 [MvModal.position]。
double mvModalMaxScroll(double contentTop, double contentBottom, int total) {
  final double viewport = math.max(0, contentBottom - contentTop);
  final double rows = math.max(1, viewport / mvModalRowHeight);
  return math.max(0, total - rows);
}

/// 横屏 MV 弹层（内容层）。
final class MvModal {
  const MvModal({
    required this.width,
    required this.dark,
    this.opacity = 1,
    this.offset = 0,
    this.title = 'MUSIC VIDEO',
    this.subtitle = '',
    this.model = const MvPanelModel(),
    this.position = 0,
    this.pictureOffsetMs = 0,
  });

  /// 舞台宽（HudStage.width；高度恒为 kModalShellStageHeight）。
  final double width;

  /// Qt NativeHud::dark：决定 ink、面板底与控件底色。
  final bool dark;

  /// Qt motion.opacity；由宿主每帧采样后传入。
  final double opacity;

  /// Qt motion.offset；由宿主每帧采样后传入。
  final double offset;

  /// 标题区主标题（外壳负责画）。
  final String title;

  /// 标题区副标题（外壳负责画）：MvWindow.qml:333 的 `关联影像 / ...`。
  final String subtitle;

  /// 注入的视图模型（映射自 `MvState`）。
  final MvPanelModel model;

  /// 版本列表的滚动窗口（条目单位，可为小数）。
  final double position;

  /// 画面偏移（毫秒，Qt `MvController::offset()`；底行显示成 `X.Xs`）。
  final int pictureOffsetMs;

  /// 弹层 id（决定外壳策略；`mv` 落通用分支：有遮罩、有标题区、关闭走 close-modal）。
  static const String kind = 'mv';

  static const String category = 'VIDEO TERMINAL';

  /// Escape 走通用弹层规则（NativeHudController.cpp:913-922）。
  static const Map<String, String> keyActions = <String, String>{'Escape': 'close-modal'};

  /// 返回按键对应的动作；不在表内返回 null（不发明 Tab / Enter 行为）。
  static String? actionForKey(String key) => keyActions[key];

  /// 画一帧。外壳负责 save / alpha / 遮罩 / translate / 面板底 / 标题区 / restore。
  ModalShellResult build(HudSurfaceSink sink, HudTextPort text) {
    final ModalShellSpec spec = ModalShellSpec(
      modalId: kind,
      stageWidth: width,
      dark: dark,
      opacity: opacity,
      offset: offset,
      title: title,
      subtitle: subtitle,
      content: (ModalShellBody body) => _paint(body),
    );
    return ModalShell(sink: sink, text: text, spec: spec).build();
  }

  void _paint(ModalShellBody body) {
    final double x = body.bounds.left;
    final double y = body.bounds.top;
    final double left = x + mvModalInset;
    final double contentWidth = body.bounds.width - mvModalInset * 2;

    // 1) 状态行：Qt MvWindow.qml:560 的同一条串（status · versionStatus）。
    final String statusLine = model.versionStatus.isEmpty
        ? model.status
        : '${model.status} · ${model.versionStatus}';
    _limited(body, statusLine, left, y + 24, 15, contentWidth, 'demibold');

    // 2) 已解析的 MV：标题 / id / 静音跟随串（Qt :664）。
    double cursor = y + 56;
    if (model.title.isNotEmpty || model.trackId.isNotEmpty) {
      _limited(body, model.title.isEmpty ? model.trackId : model.title, left, cursor, 17,
          contentWidth * 0.6, 'demibold');
      if (model.resolution > 0) {
        _limited(body, '静音跟随音乐 · ${model.resolution}p', left + contentWidth * 0.62, cursor + 2,
            13, contentWidth * 0.38);
      }
      cursor += 26;
      if (model.trackId.isNotEmpty) {
        _limited(body, 'MV ${model.trackId} / ${model.resolution}p', left, cursor, 11, contentWidth * 0.5);
        cursor += 18;
      }
    }

    // 3) 诚实降级：没有解码器就不画播放面，只写清楚现状。
    if (!model.decodable) {
      hudFill(body.sink, modalShellControlTint(dark: body.dark), left, cursor, contentWidth, 46);
      hudText(
        body.sink,
        body.text.fit('本机未接入视频解码 · 仅同步时间轴', 13, contentWidth - 24),
        left + 12,
        cursor + 15,
        13,
        dark: body.dark,
      );
      cursor += 58;
    }

    // 4) 版本列表标题 + 行（Qt :474 的 `01 / VIDEO VERSION / 视频版本`）。
    _limited(body, '01 / VIDEO VERSION / 视频版本', left, cursor, 11, contentWidth * 0.6, 'demibold');
    _limited(
      body,
      model.versions.isEmpty ? (model.versionStatus.isEmpty ? '未找到其他视频版本' : model.versionStatus) : '${model.versions.length} 个可用',
      left + contentWidth * 0.64,
      cursor + 2,
      11,
      contentWidth * 0.36,
    );
    cursor += 20;

    // 版本列表的可视区：底边让给底行（画面偏移 + 四枚按钮）。
    final double bottom = y + body.bounds.height - 92;
    final double viewport = math.max(0, bottom - cursor);
    final List<MvPanelVersionRow> rows = model.versions;
    if (rows.isEmpty) {
      _limited(body, '当前来源没有可选的视频版本', left, cursor + 10, 12, contentWidth);
    } else {
      final double scroll = _clampScroll(position, rows.length, viewport);
      final int first = math.max(0, scroll.floor());
      for (int index = first; index < rows.length; index++) {
        final double rowY = cursor + index * mvModalRowHeight - scroll;
        if (rowY >= bottom) {
          break;
        }
        if (rowY + mvModalRowHeight <= cursor) {
          continue;
        }
        _versionRow(body, left, rowY, contentWidth, rows[index],
            current: rows[index].id == model.selectedVersionId);
      }
    }

    // 5) 底行：画面偏移 + 刷新版本 / −0.5s / +0.5s / 归零 + 自动查找开关
    //    （Qt MvWindow.qml:566-583 的按钮组）。
    final double rowY = y + body.bounds.height - 70;
    hudRule(body.sink, body.dark, left, rowY - 14, contentWidth);
    _limited(body, '画面偏移 ${offsetSeconds}s', left, rowY, 12, contentWidth * 0.42);
    final double buttonTop = rowY + 20;
    final double gap = 8;
    final double buttonWidth = (contentWidth - gap * 3) / 4;
    _contentButton(body, '刷新版本', left, buttonTop, buttonWidth, 40, 'mv:retry', 13);
    _contentButton(
        body, '−0.5s', left + (buttonWidth + gap), buttonTop, buttonWidth, 40, 'mv:offset:-500', 13);
    _contentButton(body, '+0.5s', left + (buttonWidth + gap) * 2, buttonTop, buttonWidth, 40,
        'mv:offset:+500', 13);
    _contentButton(body, '归零', left + (buttonWidth + gap) * 3, buttonTop, buttonWidth, 40,
        'mv:offset:reset', 13);

    // 自动查找开关（Qt :182-199 的 setEnabled 槽位；桌面侧偏好叫 mv-auto）。
    // 与「画面偏移」同一行右侧，底行只剩那一排按钮，不再往下挤。
    _limited(body, model.auto ? '自动查找：开' : '自动查找：关', left + contentWidth * 0.46, rowY + 2,
        11, contentWidth * 0.22);
    _contentButton(
      body,
      model.auto ? '关闭' : '打开',
      left + contentWidth * 0.72,
      rowY - 6,
      contentWidth * 0.28,
      30,
      model.auto ? 'mv:auto:off' : 'mv:auto:on',
      11,
    );
  }

  /// Qt MvWindow.qml:566 的 `(rhineMv.offset / 1000).toFixed(1)`。
  String get offsetSeconds => (pictureOffsetMs / 1000).toStringAsFixed(1);

  /// 一行版本：命中 `mv:version:<id>`，标签是 Qt `versionLabels()` 的原样拼法。
  void _versionRow(
    ModalShellBody body,
    double left,
    double y,
    double width,
    MvPanelVersionRow row, {
    required bool current,
  }) {
    if (current) {
      hudFill(body.sink, modalShellControlTint(dark: body.dark), left, y, width, mvModalRowHeight - 1);
    }
    body.hit(left, y, width, mvModalRowHeight - 1, 'mv:version:${row.id}', row.label);
    _limited(body, row.label, left + 12, y + 14, 13, width * 0.72, 'demibold');
    _limited(
      body,
      row.associated ? '歌曲关联' : '搜索结果',
      left + 12,
      y + 36,
      10,
      width * 0.5,
    );
    if (current) {
      _limited(body, '当前', left + width * 0.86, y + 26, 11, width * 0.14, 'demibold');
    }
    hudRule(body.sink, body.dark, left, y + mvModalRowHeight - 1, width, 0.3);
  }

  /// 内容按钮：Qt NativeHud::button 在 m_modalControls 下的分支（先命中，再 tint，再拟合文字）。
  void _contentButton(
    ModalShellBody body,
    String label,
    double x,
    double y,
    double width,
    double height,
    String action,
    double size,
  ) {
    body.hit(x, y, width, height, action, label);
    final double inset = width < 80 ? width / 8 : 10.0;
    hudFill(body.sink, modalShellControlTint(dark: body.dark), x, y, width, height);
    hudText(
      body.sink,
      body.text.fit(label, size, width - inset * 2),
      x + inset,
      y + (height - size) / 2 - 4,
      size,
      dark: body.dark,
    );
  }

  /// 限宽文字（Qt NativeHud::limited 的等价：先 fit 再画）。
  void _limited(
    ModalShellBody body,
    String value,
    double x,
    double y,
    double size,
    double width, [
    String weight = 'regular',
  ]) {
    hudText(
      body.sink,
      body.text.fit(value, size, width, weight),
      x,
      y,
      size,
      weight: weight,
      dark: body.dark,
    );
  }
}

/// 滚动夹取：条目位置夹在 `[0, max(0, total - 可视行数)]`。
double _clampScroll(double position, int total, double viewport) {
  final double rows = math.max(1, viewport / mvModalRowHeight);
  final double maxScroll = math.max(0, total - rows);
  if (!position.isFinite || position < 0) {
    return 0;
  }
  return position > maxScroll ? maxScroll : position;
}
