// ===========================================================================
// T40-S02 / A51   atomic = A51   file = lib/hud/modals/disc_warning_modal.dart
// scope = 唱片旋转风险弹层（视觉与静态动作串）
// 横屏 1:1 源：Qt/src/NativeHudModal.cpp
//   :83-84 save / alpha | :163-165 scrim | :166 translate
//   :167-172 通用面板 {left, 122, min(1260, width - 100), 836}
//   :173 hits 清空 | :188-202 分类行 / ← 返回 / 标题 / 副标题
//   :203-209 四段正文与两个按钮
// 状态机不在此文件：打开、关闭、偏好写入与 action 分发属于宿主
// （Qt/src/NativeHudController.cpp:711-723）；本类只把一次采样后的
// opacity / offset 画成一帧，不持有计时器、不读全局、不写存储。
//
// 2026-11-12 A51 说明：T40 的未跟踪同名文件是纯 Dart 的独立绘制器，内含
// motion / state / painter 副本；本文件按 modal_shell 契约重写为薄端口，
// 不复制其状态机，也不改变任何字符串、坐标或命中。
// ===========================================================================

import 'package:rhine_music_database/hud/modals/modal_shell.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';

/// "DISC ROTATION" 风险确认弹层。
///
/// Qt 的 modal id 是 'disc-rotation-warning'（NativeHudController.cpp:716），
/// 走通用弹层分支（NativeHudModal.cpp:188-209）：有遮罩、有标题区、无
/// 舞台级关闭命中。三个命中串的顺序就是 Qt 的绘制顺序：
///   close-modal（← 返回）→ disc-rotation:enable → disc-rotation:cancel。
final class DiscWarningModal {
  const DiscWarningModal({
    required this.width,
    this.dark = false,
    this.opacity = 1,
    this.offset = 0,
  });

  /// 舞台宽（HudStage.width；高度恒为 1080）。
  final double width;

  /// Qt NativeHud::dark：决定 ink、遮罩、面板与控件底色。
  final bool dark;

  /// Qt motion.opacity；由宿主每帧采样后传入。
  final double opacity;

  /// Qt motion.offset；由宿主每帧采样后传入。
  final double offset;

  /// Qt modal 字符串（NativeHudController.cpp:716）。
  static const String kind = 'disc-rotation-warning';

  /// NativeHudModal.cpp:31 的标题表。
  static const String title = 'DISC ROTATION';

  /// NativeHudModal.cpp:57 的副标题表。
  static const String subtitle = '开启前请确认资源与功耗风险';

  /// 本弹层可发出的全部动作，按绘制顺序（NativeHudModal.cpp:199-200 / :208-209）。
  static const List<String> actions = <String>[
    'close-modal',
    'disc-rotation:enable',
    'disc-rotation:cancel',
  ];

  /// Escape：通用弹层一律 close-modal（NativeHudController.cpp:913-922）。
  static const String escapeAction = 'close-modal';

  /// 本弹层唯一的按键映射；其它键由外壳吞掉（NativeHudController.cpp:923-925）。
  static const Map<String, String> keyActions = <String, String>{
    'Escape': 'close-modal',
  };

  /// 返回按键对应的动作；不在表内返回 null（不发明 Tab / Enter 行为）。
  static String? actionForKey(String key) => keyActions[key];

  /// 画一帧。外壳负责 save / alpha / scrim / translate / 面板 / 标题区 /
  /// restore；内容只发正文命令与两个内容按钮（NativeHudModal.cpp:203-209）。
  ModalShellResult build(HudSurfaceSink sink, HudTextPort text) {
    final ModalShellSpec spec = ModalShellSpec(
      modalId: kind,
      stageWidth: width,
      dark: dark,
      opacity: opacity,
      offset: offset,
      title: title,
      subtitle: subtitle,
      content: (ModalShellBody body) {
        final double x = body.bounds.left;
        final double y = body.bounds.top;

        hudText(body.sink, '唱片旋转需要持续刷新画面。', x + 53, y + 250, 22,
            weight: 'demibold', dark: body.dark); // :204
        hudText(
          body.sink,
          '开启后会增加 CPU / GPU 占用、耗电和发热，可能缩短电池续航。',
          x + 53,
          y + 310,
          16,
          dark: body.dark,
        ); // :205
        hudText(
          body.sink,
          '仅当前歌曲的详情页和歌词页旋转；资源库、暂停和后台均不旋转。',
          x + 53,
          y + 352,
          16,
          dark: body.dark,
        ); // :206
        hudText(
          body.sink,
          '该功能默认关闭，减少动态效果开启时也不会旋转。',
          x + 53,
          y + 394,
          16,
          dark: body.dark,
        ); // :207

        _contentButton(
          body,
          '了解风险，仍然开启',
          x + 53,
          y + 480,
          260,
          48,
          'disc-rotation:enable',
          16,
        ); // :208
        _contentButton(
          body,
          '保持关闭',
          x + 340,
          y + 480,
          180,
          48,
          'disc-rotation:cancel',
          16,
        ); // :209
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
