// 详情页排序弹层（视觉与静态动作串）
// 横屏 1:1 源：Qt/src/NativeHudModal.cpp
//   :122-141 detail-sort 分支 | :124 translate | :125 hits 清空
//   :128 舞台级关闭命中 | :129-130 面板（dark 色不带 calibratedWhite 标签）
//   :131-137 四行按钮 | :139 restore
// 几何源：Qt/src/NativeHud.cpp:141-144 / :160-166
// 状态机不在此文件：打开守卫、排序动作解析与清理属于宿主
// （Qt/src/NativeHudMusic.cpp:40-60）；本类只画一次采样后的帧。
//
// 同名文件（纯 Dart 独立绘制器）内含
// motion / cleanup / action-effect / painter 副本；本文件按 modal_shell
// 契约重写为薄端口，不复制其状态机，也不改变字符串、坐标、命中或面板色。

import 'package:rhine_music_database/hud/modals/modal_shell.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';

/// 详情页排序弹层，Qt modal id 为 'detail-sort'。
///
/// 外壳提供：无遮罩、无标题区、面板底（dark 不带 calibratedWhite 标签）、
/// translate、舞台级关闭命中与 restore。本类只提供四行按钮（NativeHudModal.cpp:131-137）。
/// 命中顺序：关闭排序菜单 → music:sort:detail:none → title → album → artist。
final class DetailSortModal {
  const DetailSortModal({
    required this.width,
    this.dark = false,
    this.opacity = 1,
    this.offset = 0,
    this.detailSort = 'none',
  });

  /// 舞台宽（HudStage.width；高度恒为 1080）。
  final double width;

  /// Qt NativeHud::dark：决定 ink、面板底与控件底色。
  final bool dark;

  /// Qt motion.opacity；由宿主每帧采样后传入。
  final double opacity;

  /// Qt motion.offset；由宿主每帧采样后传入，同时用于舞台级关闭命中的 y 反号。
  final double offset;

  /// Qt NativeHud::detailSort：'none' / 'title' / 'album' / 'artist'。
  final String detailSort;

  /// Qt modal 字符串（NativeHudMusic.cpp:42 / :51）。
  static const String kind = 'detail-sort';

  /// 四个排序字段，顺序即菜单行顺序（NativeHudModal.cpp:131）。
  static const List<String> fields = <String>[
    'none',
    'title',
    'album',
    'artist',
  ];

  /// 四行标签，顺序与 [fields] 对应（NativeHudModal.cpp:132）。
  static const List<String> labels = <String>[
    '默认排序',
    '按歌曲名排序',
    '按专辑名排序',
    '按歌手名排序',
  ];

  /// 舞台级关闭动作（NativeHudModal.cpp:128）。
  static const String closeAction = 'close-modal';

  /// 舞台级关闭命中的无障碍标签（NativeHudModal.cpp:128）。
  static const String catcherLabel = '关闭排序菜单';

  /// 行几何与字号（NativeHudModal.cpp:135-136）。
  static const double rowHeight = 42;
  static const double rowInset = 8;
  static const double rowTextSize = 14;

  /// 某字段对应的动作串（NativeHudModal.cpp:136）。
  static String actionFor(String field) => 'music:sort:detail:$field';

  /// Escape：通用弹层一律 close-modal（NativeHudController.cpp:913-922）。
  static const Map<String, String> keyActions = <String, String>{
    'Escape': 'close-modal',
  };

  /// 返回按键对应的动作；不在表内返回 null（不发明 Tab / Enter 行为）。
  static String? actionForKey(String key) => keyActions[key];

  /// 画一帧。外壳负责 save / alpha / translate / 面板 / 关闭命中 / restore；
  /// 内容只画四行按钮，不再发面板底或第二个 close-modal。
  ModalShellResult build(HudSurfaceSink sink, HudTextPort text) {
    final ModalShellSpec spec = ModalShellSpec(
      modalId: kind,
      stageWidth: width,
      dark: dark,
      opacity: opacity,
      offset: offset,
      content: (ModalShellBody body) {
        final double x = body.bounds.left;
        final double y = body.bounds.top;
        for (int index = 0; index < fields.length; index++) {
          final String field = fields[index];
          final String label =
              (detailSort == field ? '✓ ' : '') + labels[index];
          _contentButton(
            body,
            label,
            x + rowInset,
            y + rowInset + index * rowHeight,
            body.bounds.width - rowInset * 2,
            rowHeight,
            actionFor(field),
            rowTextSize,
          ); // :133-137
        }
      },
    );
    return ModalShell(sink: sink, text: text, spec: spec).build();
  }

  /// 内容按钮：Qt NativeHud::button 在 m_modalControls 下的分支
  /// （NativeHud.cpp:110-120）。先命中，再 tint，再以 regular 量宽拟合文字；
  /// 标签按 size / 默认 regular 绘制，不额外加粗。
  static void _contentButton(
    ModalShellBody body,
    String label,
    double x,
    double y,
    double width,
    double height,
    String action,
    double size,
  ) {
    body.hit(x, y, width, height, action, label); // :112
    final double inset = width < 80 ? width / 8 : 10.0; // :113 min(10, width / 8)
    hudFill(
      body.sink,
      modalShellControlTint(dark: body.dark),
      x,
      y,
      width,
      height,
    ); // :115-116
    hudText(
      body.sink,
      body.text.fit(label, size, width - inset * 2),
      x + inset,
      y + (height - size) / 2 - 4,
      size,
      dark: body.dark,
    ); // :118-119
  }
}
