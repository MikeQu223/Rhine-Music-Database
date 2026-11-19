// 竖屏「关联 MV」面板（lib/hud/portrait/portrait_pages_mv.dart）与横屏 MV 弹层
// （lib/hud/modals/mv_modal.dart）的文案/命中测试。
//
// 真值口径：
// - 竖向页**版式是自拟的**（仓库无竖屏 MV QML，Qt/src/PlatformFeatures.h:23-27 的
//   MusicVideo 在 Android 恒 false），所以只断言"画了什么文案、发什么动作"，
//   不断言像素；
// - 语义来自 Qt/src/MvController.cpp：:590-592 / :646-649 / :657-660 的状态串、
//   :664 的 `静音跟随音乐 · Np`、:442-460 的 versionLabels()、:691 的 seek 阈值；
// - 横屏弹层的底行按钮组来自 Qt/qml/MvWindow.qml:560-583。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/modal_shell.dart';
import 'package:rhine_music_database/hud/modals/mv_modal.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';
import 'package:rhine_music_database/hud/portrait/portrait_canvas.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_mv.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';

/// 宽度按字符数估算、折行按「整段一行」，只为断言文案与命中。
PortraitCanvas _canvas({double gridWidth = 393, double height = 800}) => PortraitCanvas(
  metrics: PortraitMetrics(
    width: (String value, double size, String weight) => value.length * size * .6,
    wrap: (String value, double limit, double size, String weight) => <String>[value],
    bounds: (String value, double size, String weight) =>
        PortraitGlyphBounds(width: value.length * size * .6, height: size),
  ),
  unit: 1,
  gridWidth: gridWidth,
  height: height,
  dark: true,
);

List<String> _texts(PortraitCanvas c) => <String>[
  for (final List<Object?> command in c.commands)
    if (command[0] == 'text') command[1]! as String,
];

List<String> _actions(PortraitCanvas c) =>
    c.hits.map((HudHit hit) => hit.action).toList();

const MvPanelVersionRow _associated =
    MvPanelVersionRow(id: 'mv1', label: '[歌曲关联] 官方 MV · #mv1', associated: true);
const MvPanelVersionRow _search = MvPanelVersionRow(
    id: 'other1', label: '[搜索结果] 翻唱 · 某人 · #other1', associated: false);

/// 字形度量桩：宽度 = 字符数 × size × 0.5，fit 与 Qt NativeHud::fit 同语义。
final class _Metrics implements HudTextPort {
  const _Metrics();

  @override
  double glyphWidth(String value, double size, [String weight = 'regular']) =>
      value.length * size * 0.5;

  @override
  double glyphInset(String value, double size, [String weight = 'regular']) => 0;

  @override
  String fit(String value, double size, double width, [String weight = 'regular']) {
    if (glyphWidth(value, size) <= width) {
      return value;
    }
    int low = 1;
    int high = value.length;
    while (low < high) {
      final int middle = (low + high + 1) ~/ 2;
      if (glyphWidth(value.substring(0, middle), size) <= width) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return '${value.substring(0, low - 1)}\u2026';
  }

  @override
  void rolling(String key, String value, double x, double y, double size, String weight,
      double tracking, bool numeric) {}
}

final class _Sink implements HudSurfaceSink {
  final List<List<Object?>> commands = <List<Object?>>[];
  final List<HudHit> hits = <HudHit>[];

  @override
  void op(List<Object?> command) => commands.add(command);

  @override
  void hit(HudHit hit) => hits.add(hit);
}

void main() {
  group('竖屏 MV 面板', () {
    test('待机态：画状态串、页头返回命中与两个按钮', () {
      final PortraitCanvas c = _canvas();
      paintPortraitMvPage(
        c,
        model: const MvPanelModel(status: '播放歌曲后，将自动查找关联 MV'),
      );

      expect(_texts(c), contains('播放歌曲后，将自动查找关联 MV'));
      expect(_texts(c), contains('关联 MV'), reason: '页头标题');
      expect(_texts(c), contains('视频版本'));
      expect(_texts(c), contains('当前来源没有可选的视频版本'));
      final List<String> actions = _actions(c);
      expect(actions, contains('close-modal'), reason: '页头返回 → close-modal');
      expect(actions, contains('mv:retry'));
      expect(actions, contains('mv:versions'));
      expect(actions, contains('mv:auto:off'), reason: 'auto=true 时开关动作是关闭');
    });

    test('不支持来源：原样显示 Qt 的拒绝串（MvController.cpp:592）', () {
      final PortraitCanvas c = _canvas();
      paintPortraitMvPage(c, model: const MvPanelModel(status: '当前来源不支持关联 MV'));
      expect(_texts(c), contains('当前来源不支持关联 MV'));
    });

    test('已解析：标题 / MV id / 静音跟随串 / 诚实降级行（:664）', () {
      final PortraitCanvas c = _canvas();
      paintPortraitMvPage(
        c,
        model: const MvPanelModel(
          status: '静音跟随音乐 · 720p',
          title: '官方 MV',
          trackId: 'mv1',
          resolution: 720,
          versions: <MvPanelVersionRow>[_associated],
          selectedVersionId: 'mv1',
        ),
      );

      final List<String> texts = _texts(c);
      expect(texts, contains('官方 MV'));
      expect(texts, contains('MV mv1'));
      expect(texts, contains('静音跟随音乐 · 720p'));
      expect(texts, contains('本机未接入视频解码'), reason: 'decodable 缺省 false ⇒ 不伪造播放');
      expect(_actions(c), contains('mv:version:mv1'));
      expect(texts, contains('当前'), reason: '选中行标记');
    });

    test('版本行标签是 Qt versionLabels() 的原样拼法，命中 mv:version:<id>', () {
      final PortraitCanvas c = _canvas();
      paintPortraitMvPage(
        c,
        model: const MvPanelModel(
          status: '此歌曲没有关联 MV，可手动选择视频版本',
          versions: <MvPanelVersionRow>[_associated, _search],
        ),
      );

      expect(_texts(c), contains('[歌曲关联] 官方 MV · #mv1'));
      expect(_texts(c), contains('[搜索结果] 翻唱 · 某人 · #other1'));
      final List<String> actions = _actions(c);
      expect(actions.where((String a) => a.startsWith('mv:version:')).toList(),
          <String>['mv:version:mv1', 'mv:version:other1']);
    });

    test('版本附注与自动查找开：开关动作变成 mv:auto:on', () {
      final PortraitCanvas c = _canvas();
      paintPortraitMvPage(
        c,
        model: const MvPanelModel(
          status: '静音跟随音乐 · 1080p',
          versionStatus: '视频版本加载失败，可重试',
          auto: true,
        ),
      );
      expect(_texts(c), contains('视频版本加载失败，可重试'));
      expect(_texts(c), contains('自动查找：开'));
    });

    test('滚动夹取：position 越界不画到裁剪区外，列表仍从首项开始', () {
      final PortraitCanvas c = _canvas();
      paintPortraitMvPage(
        c,
        position: 999,
        model: const MvPanelModel(
          status: '此歌曲没有关联 MV，可手动选择视频版本',
          versions: <MvPanelVersionRow>[_associated, _search],
        ),
      );
      // 两行放得下 ⇒ 上界 0 ⇒ 夹到 0，首项仍可见。
      expect(_actions(c), contains('mv:version:mv1'));
    });
  });

  group('横屏 MV 弹层', () {
    test('通用弹层策略：有遮罩、有标题区、关闭走 close-modal', () {
      final _Sink sink = _Sink();
      final ModalShellResult result = const MvModal(width: 1920, dark: true).build(sink, const _Metrics());

      expect(result.policy.modalId, 'mv');
      expect(result.policy.paintsStageScrim, isTrue);
      expect(result.policy.usesTitleBand, isTrue);
      expect(result.policy.backAction, 'close-modal');
      expect(result.bounds.top, kModalShellModalTop);
      expect(result.bounds.height, kModalShellModalHeight);
      expect(
        result.hits.map((HudHit hit) => hit.action).toList(),
        contains('close-modal'),
      );
    });

    test('底行四枚按钮与自动查找开关（MvWindow.qml:566-583 / :182-199）', () {
      final _Sink sink = _Sink();
      // 命中走外壳的 ModalShellHitTable（sink 只收命令），见 modal_shell.dart 的
      // ModalShellResult.hits；因此断言 result.hits 而不是 sink.hits。
      final ModalShellResult result = const MvModal(
        width: 1920,
        dark: true,
        pictureOffsetMs: -1500,
        model: MvPanelModel(auto: true),
      ).build(sink, const _Metrics());

      final List<Object?> textCommands = <Object?>[
        for (final List<Object?> command in sink.commands)
          if (command[0] == 'text') command[1]!,
      ];
      expect(textCommands, contains('画面偏移 -1.5s'), reason: 'Qt (offset/1000).toFixed(1)');
      final List<String> actions = result.hits.map((HudHit hit) => hit.action).toList();
      expect(actions, containsAll(<String>[
        'mv:retry',
        'mv:offset:-500',
        'mv:offset:+500',
        'mv:offset:reset',
        'mv:auto:off',
      ]));
    });

    test('版本行命中 + 当前行标记 + 无版本时的说明串', () {
      final _Sink sink = _Sink();
      final ModalShellResult result = const MvModal(
        width: 1920,
        dark: true,
        model: MvPanelModel(
          status: '此歌曲没有关联 MV，可手动选择视频版本',
          versions: <MvPanelVersionRow>[_associated, _search],
          selectedVersionId: 'other1',
        ),
      ).build(sink, const _Metrics());

      final List<String> actions = result.hits.map((HudHit hit) => hit.action).toList();
      expect(actions, contains('mv:version:mv1'));
      expect(actions, contains('mv:version:other1'));

      final _Sink empty = _Sink();
      const MvModal(width: 1920, dark: true, model: MvPanelModel(status: '播放歌曲后，将自动查找关联 MV'))
          .build(empty, const _Metrics());
      final List<Object?> texts = <Object?>[
        for (final List<Object?> command in empty.commands)
          if (command[0] == 'text') command[1]!,
      ];
      expect(texts, contains('当前来源没有可选的视频版本'));
    });

    test('Escape 走通用弹层规则', () {
      expect(MvModal.actionForKey('Escape'), 'close-modal');
      expect(MvModal.actionForKey('Enter'), isNull, reason: '不发明按键行为');
    });
  });
}
