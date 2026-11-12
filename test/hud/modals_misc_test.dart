// ===========================================================================
// T40-T01 / A57   writer = A57   file = test/hud/modals_misc_test.dart
// scope = 五个弹层的组件级测试：quality / provider / disc-warning / detail-sort / confirm
//        + 共享弹层外壳 modal_shell 的边界、策略、动效与命中契约
// 参考真值：
//   Qt/src/NativeHudModal.cpp:81-257（modalDraw）/:122-141（detail-sort）
//     /:142-161（lyrics-source）/:203-209（disc-rotation-warning）
//     /:214-221（confirm）/:259-306（provider）/:326-446（quality）
//   Qt/src/NativeHud.cpp:140-166（modalBounds / containerLayout）
//     /:102-120（hit / button）/:125-129（rule）
//   Qt/src/UiMotion.h:24-42 + Qt/src/UiMotion.cpp:86-120（SurfaceMotion）
// 说明：本文件只读被测 API 的公开表面，不复制产品实现；期望值一律是
//   按 Qt 源码逐条折算、直接写死的字面量（颜色数组 / 标签 / 动作串）。
//   仅当某条断言显式标注 identity check 时，才与产品常量或表比较；
//   本文件没有未标注的产品 helper 回算。
// Written but NOT executed: 仓库禁令禁止 flutter/dart test/analyze/build，
//   因此本文件只做静态审查，未在设备或桌面上运行。
// ===========================================================================

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/hud/modals/confirm_modal.dart';
import 'package:rhine_music_database/hud/modals/detail_sort_modal.dart';
import 'package:rhine_music_database/hud/modals/disc_warning_modal.dart';
import 'package:rhine_music_database/hud/modals/modal_shell.dart';
import 'package:rhine_music_database/hud/modals/provider_modal.dart';
import 'package:rhine_music_database/hud/modals/quality_modal.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';

// ---------------------------------------------------------------------------
// Fakes / helpers
// ---------------------------------------------------------------------------

/// Deterministic glyph metrics: every code unit advances size * 0.5.
/// fit() reproduces Qt NativeHud::fit() (Qt/src/NativeHud.cpp:48-76): binary
/// search the longest prefix that fits, then drop one unit and append U+2026.
final class _Metrics implements HudTextPort {
  const _Metrics();

  static const double _advance = 0.5;

  @override
  double glyphWidth(String value, double size, [String weight = 'regular']) =>
      value.length * size * _advance;

  @override
  double glyphInset(String value, double size, [String weight = 'regular']) => 0;

  @override
  String fit(String value, double size, double width,
      [String weight = 'regular']) {
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
    return value.substring(0, low - 1) + '\u2026';
  }

  @override
  void rolling(String key, String value, double x, double y, double size,
      String weight, double tracking, bool numeric) {}
}

final class _Sink implements HudSurfaceSink {
  final List<List<Object?>> commands = <List<Object?>>[];
  final List<HudHit> hits = <HudHit>[];

  @override
  void op(List<Object?> command) => commands.add(command);

  @override
  void hit(HudHit hit) => hits.add(hit);
}

List<List<Object?>> _ofType(List<List<Object?>> commands, String type) =>
    commands.where((List<Object?> command) => command[0] == type).toList();

List<String> _texts(List<List<Object?>> commands) => _ofType(commands, 'text')
    .map((List<Object?> command) => command[1]! as String)
    .toList();

List<Object?> _textCommand(List<List<Object?>> commands, String value) =>
    commands.firstWhere(
      (List<Object?> command) => command[0] == 'text' && command[1] == value,
      orElse: () => throw StateError('missing text command: ' + value),
    );

List<Object?> _fillOf(
    List<List<Object?>> commands, double x, double y, double w, double h) {
  return commands.firstWhere(
    (List<Object?> command) =>
        command[0] == 'fill' &&
        command[2] == x &&
        command[3] == y &&
        command[4] == w &&
        command[5] == h,
    orElse: () => throw StateError('missing fill at ' +
        x.toString() +
        ',' +
        y.toString()),
  );
}

List<String> _hitActions(List<HudHit> hits) =>
    hits.map((HudHit hit) => hit.action).toList();

int _countActions(List<HudHit> hits, String action) =>
    hits.where((HudHit hit) => hit.action == action).length;

HudHit _hitWithAction(List<HudHit> hits, String action) => hits.firstWhere(
      (HudHit hit) => hit.action == action,
      orElse: () => throw StateError('missing hit action: ' + action),
    );

double _measure(String text, double size, String? weight, double tracking) =>
    text.length * size * 0.5;

void _probeContent(ModalShellBody body) {
  hudText(body.sink, 'PROBE', 1, 2, 3);
  body.hit(10, 20, 30, 40, 'probe:action', 'Probe');
}

/// A content builder that abuses the hit table as a command sink; the shell's
/// table must reject it instead of silently dropping the command.
void _opThroughHitTable(ModalShellBody body) {
  body.hits.op(<Object?>['save']);
}

void main() {
  // =========================================================================
  // Shared shell: geometry, policy, motion, envelope order
  // =========================================================================
  group('ModalShell bounds (Qt/src/NativeHud.cpp:140-166)', () {
    test('generic modal is centred at 1260 x 836 on the 1920 stage', () {
      final ModalShellBounds bounds =
          modalShellBounds(modalId: 'library', stageWidth: 1920);
      expect(bounds.left, 330);
      expect(bounds.top, 122);
      expect(bounds.width, 1260);
      expect(bounds.height, 836);
      expect(bounds.right, 1590);
      expect(bounds.bottom, 958);
    });

    test('generic modal clamps to width - 100 on a narrow stage', () {
      final ModalShellBounds bounds =
          modalShellBounds(modalId: 'confirm', stageWidth: 1080);
      expect(bounds.left, 50);
      expect(bounds.width, 980);
      expect(bounds.top, 122);
      expect(bounds.height, 836);
    });

    test('search keeps the 760 floor and the right inset of 59', () {
      final ModalShellBounds wide =
          modalShellBounds(modalId: 'search', stageWidth: 1920);
      expect(wide.width, 901);
      expect(wide.left, 960);

      final ModalShellBounds narrow =
          modalShellBounds(modalId: 'search', stageWidth: 1080);
      expect(narrow.width, 760);
      expect(narrow.left, 261);
    });

    test('detail-sort anchors to containerLayout + 195', () {
      // layout.left 40 + sidebar clamp(1920*0.23-40=401.6 -> 340) + 36 = 416.
      final ModalShellBounds wide =
          modalShellBounds(modalId: 'detail-sort', stageWidth: 1920);
      expect(wide.left, 611);
      expect(wide.top, 391);
      expect(wide.width, 240);
      expect(wide.height, 184);

      // 40 + clamp(1080*0.23-40=208.4 -> 250) + 36 = 326; +195 = 521.
      final ModalShellBounds narrow =
          modalShellBounds(modalId: 'detail-sort', stageWidth: 1080);
      expect(narrow.left, 521);
    });

    test('lyrics menus use the percentage anchors', () {
      final ModalShellBounds source =
          modalShellBounds(modalId: 'lyrics-source', stageWidth: 1920);
      expect(source.left, closeTo(1231.2, 1e-9));
      expect(source.top, 674);
      expect(source.width, 232);
      expect(source.height, 232);

      final ModalShellBounds offset =
          modalShellBounds(modalId: 'lyrics-offset', stageWidth: 1920);
      expect(offset.left, closeTo(1075.2, 1e-9));
      expect(offset.top, 690);
      expect(offset.width, 320);
      expect(offset.height, 216);
    });
  });

  group('ModalShellPolicy (Qt/src/NativeHudModal.cpp:85-202)', () {
    test('quality and provider keep the generic frame and title band', () {
      final ModalShellPolicy quality =
          ModalShellPolicy.forModal(kModalShellQualityModal);
      expect(quality.paintsStageScrim, isTrue);
      expect(quality.usesTitleBand, isTrue);
      expect(quality.dismissesOnStageTap, isFalse);
      expect(quality.backAction, 'close-modal');
      expect(quality.category, 'AUDIO SPECIFICATION');
      expect(quality.search, isFalse);
      expect(quality.darkPanelTagged, isTrue);

      final ModalShellPolicy provider =
          ModalShellPolicy.forModal(kProviderModalId);
      expect(provider.paintsStageScrim, isTrue);
      expect(provider.usesTitleBand, isTrue);
      expect(provider.category, 'MUSIC DIRECTORY');
    });

    test('special menus bypass scrim and title band but keep the shell', () {
      for (final String id in <String>[
        'lyrics-offset',
        'lyrics-source',
        'detail-sort',
      ]) {
        final ModalShellPolicy policy = ModalShellPolicy.forModal(id);
        expect(policy.paintsStageScrim, isFalse, reason: id);
        expect(policy.usesTitleBand, isFalse, reason: id);
        expect(policy.backAction, 'close-modal', reason: id);
      }
      expect(
        ModalShellPolicy.forModal('detail-sort').dismissesOnStageTap,
        isTrue,
      );
      expect(
        ModalShellPolicy.forModal('detail-sort').dismissLabel,
        '关闭排序菜单',
      );
      expect(
        ModalShellPolicy.forModal('lyrics-offset').bareCloseAffordance,
        isTrue,
      );
      expect(
        ModalShellPolicy.forModal('lyrics-source').bareCloseAffordance,
        isFalse,
      );
    });

    test('player and discover stay scrim-only; desktop-lyrics keeps its back',
        () {
      final ModalShellPolicy player = ModalShellPolicy.forModal('player');
      expect(player.paintsStageScrim, isTrue);
      expect(player.usesTitleBand, isFalse);
      expect(player.category, 'AUDIO TERMINAL');

      final ModalShellPolicy discover = ModalShellPolicy.forModal('discover');
      expect(discover.paintsStageScrim, isTrue);
      expect(discover.usesTitleBand, isFalse);

      final ModalShellPolicy desktop =
          ModalShellPolicy.forModal('desktop-lyrics');
      expect(desktop.backAction, 'desktop-lyrics:back');
      expect(desktop.category, 'DESKTOP LYRICS');
    });

    test('settings switches the header sizes and category', () {
      final ModalShellPolicy settings = ModalShellPolicy.forModal('settings');
      expect(settings.category, 'SYSTEM PREFERENCES');
      expect(settings.search, isFalse);
    });

    test('scrim / panel colours reproduce ink-relative literals', () {
      expect(
        modalShellScrimColor(dark: true, search: false),
        <Object?>[17 / 255, 24 / 255, 27 / 255, 0.6],
      );
      expect(
        modalShellScrimColor(dark: false, search: false),
        <Object?>[227 / 255, 224 / 255, 215 / 255, 0.45],
      );
      expect(
        modalShellScrimColor(dark: true, search: true),
        <Object?>[17 / 255, 24 / 255, 27 / 255, 0.15],
      );
      expect(
        modalShellPanelColor(dark: true, tagged: true),
        <Object?>[0.15, 0.15, 0.15, 1, 'calibratedWhite'],
      );
      expect(
        modalShellPanelColor(dark: true, tagged: false),
        <Object?>[0.15, 0.15, 0.15, 1],
      );
      expect(modalShellControlTint(dark: true),
          <Object?>[0.55, 0.59, 0.46, 0.13]);
      expect(modalShellControlTint(dark: false),
          <Object?>[0.44, 0.49, 0.36, 0.1]);
    });
  });

  group('ModalShell envelope (Qt/src/NativeHudModal.cpp:83-172)', () {
    test('emits save / alpha / scrim / translate / panel then content then restore',
        () {
      final _Sink sink = _Sink();
      final ModalShellResult result = ModalShell(
        sink: sink,
        text: const _Metrics(),
        spec: ModalShellSpec(
          modalId: 'library',
          stageWidth: 1920,
          dark: true,
          opacity: 0.5,
          offset: 8,
          title: 'MY MUSIC',
          subtitle: '我的音乐 / N',
          content: _probeContent,
        ),
      ).build();

      final List<List<Object?>> commands = sink.commands;
      expect(commands.first, <Object?>['save']);
      expect(commands[1], <Object?>['alpha', 0.5]);
      expect(commands[2][0], 'fill');
      // Qt NativeHudModal.cpp:163-165, dark non-search scrim.
      expect(commands[2][1], <Object?>[17 / 255, 24 / 255, 27 / 255, 0.6]);
      expect(commands[2][2], 0);
      expect(commands[2][3], 0);
      expect(commands[2][4], 1920);
      expect(commands[2][5], 1080);
      expect(commands[3], <Object?>['translate', 0.0, 8.0]);
      expect(commands[4][0], 'fill');
      // Qt NativeHudModal.cpp:171-172, dark panel with calibratedWhite.
      expect(commands[4][1], <Object?>[0.15, 0.15, 0.15, 1, 'calibratedWhite']);
      expect(commands[4][2], result.bounds.left);
      expect(commands[4][3], 122);
      expect(commands[4][4], 1260);
      expect(commands[4][5], 836);
      // Title band: category text, back tint, back label, title, subtitle.
      expect(commands[5][0], 'text');
      expect(commands[5][1], 'RHINE LAB / MUSIC DATABASE / MUSIC DIRECTORY');
      expect(commands[6][0], 'fill'); // back button tint
      expect(commands[6][2], 1370); // 330 + 1260 - 220
      expect(commands[6][3], 140); // 122 + 18
      expect(commands[10][0], 'text');
      expect(commands[10][1], 'PROBE');
      expect(commands.last, <Object?>['restore']);
    });

    test('title band carries the Qt category, back button, title and subtitle',
        () {
      final _Sink sink = _Sink();
      final ModalShellResult result = ModalShell(
        sink: sink,
        text: const _Metrics(),
        spec: const ModalShellSpec(
          modalId: 'library',
          stageWidth: 1920,
          title: 'MY MUSIC',
          subtitle: '我的音乐 / N',
        ),
      ).build();

      final List<List<Object?>> commands = sink.commands;
      final List<Object?> category = _textCommand(
          commands, 'RHINE LAB / MUSIC DATABASE / MUSIC DIRECTORY');
      expect(category[2], 383); // 330 + 53
      expect(category[3], 159); // 122 + 37
      expect(category[4], 11);
      final List<Object?> back = _textCommand(commands, '\u2190 \u8FD4\u56DE');
      expect(back[4], 20);
      expect(back[5], 'demibold');
      final List<Object?> title = _textCommand(commands, 'MY MUSIC');
      expect(title[2], 383);
      expect(title[3], 213);
      expect(title[4], 38);
      expect(title[5], 'demibold');
      final List<Object?> subtitle = _textCommand(commands, '我的音乐 / N');
      expect(subtitle[2], 383);
      expect(subtitle[3], 269);
      expect(subtitle[4], 15);
    });

    test('the shell owns exactly one close-modal hit, before content hits', () {
      final _Sink sink = _Sink();
      final ModalShellResult result = ModalShell(
        sink: sink,
        text: const _Metrics(),
        spec: const ModalShellSpec(
          modalId: 'library',
          stageWidth: 1920,
          content: _probeContent,
        ),
      ).build();

      expect(result.hits.length, 2);
      final HudHit close = result.hits.first;
      expect(close.action, 'close-modal');
      expect(close.label, '\u2190 \u8FD4\u56DE');
      expect(close.x, 1370);
      expect(close.y, 140);
      expect(close.width, 167);
      expect(close.height, 54);
      expect(result.hits[1].action, 'probe:action');
      expect(result.hits[1].label, 'Probe');
    });

    test('content cannot smuggle commands through the hit table', () {
      final _Sink sink = _Sink();
      expect(
        () => ModalShell(
          sink: sink,
          text: const _Metrics(),
          spec: const ModalShellSpec(
            modalId: 'library',
            stageWidth: 1920,
            content: _opThroughHitTable,
          ),
        ).build(),
        throwsUnsupportedError,
      );
    });

    test('bare modals skip scrim and title band entirely', () {
      final _Sink sink = _Sink();
      final ModalShellResult result = ModalShell(
        sink: sink,
        text: const _Metrics(),
        spec: const ModalShellSpec(
          modalId: 'lyrics-offset',
          stageWidth: 1920,
          dark: true,
          offset: 4,
        ),
      ).build();

      // Panel + the bare close button tint; no stage scrim.
      expect(_ofType(sink.commands, 'fill').length, 2);
      expect(_texts(sink.commands), <String>['关闭']);
      expect(result.policy.bareCloseAffordance, isTrue);
      expect(result.hits.length, 1);
      final HudHit close = result.hits.single;
      expect(close.action, 'close-modal');
      expect(close.label, '关闭');
      expect(close.x, closeTo(1323.2, 1e-9)); // 1075.2 + 248
      expect(close.y, 698); // 690 + 8
      expect(close.width, 56);
      expect(close.height, 36);
      final List<Object?> label = _textCommand(sink.commands, '关闭');
      expect(label[2], closeTo(1330.2, 1e-9)); // 1323.2 + min(10, 7)
      expect(label[3], 705.5); // 698 + (36 - 13) / 2 - 4
      expect(label[4], 13);
    });
  });

  group('ModalShellMotion (Qt/src/UiMotion.h:24-42 / UiMotion.cpp:86-120)', () {
    test('entering runs 0.3 s and settles exactly on the target', () {
      final ModalShellMotion motion = ModalShellMotion();
      expect(motion.opacity, 0);
      expect(motion.offset, 12);
      expect(motion.duration, 0);
      expect(motion.finished, isTrue);

      motion.set(true, 0);
      expect(motion.duration, 0.3);
      expect(motion.finished, isFalse);

      motion.sample(0.15);
      expect(motion.opacity, greaterThan(0));
      expect(motion.opacity, lessThan(1));
      expect(motion.offset, greaterThan(0));
      expect(motion.offset, lessThan(12));

      motion.sample(0.3);
      expect(motion.opacity, 1);
      expect(motion.offset, 0);
      expect(motion.duration, 0);
      expect(motion.finished, isTrue);
    });

    test('closing re-samples before retargeting so fast toggles stay continuous',
        () {
      final ModalShellMotion motion = ModalShellMotion();
      motion.set(true, 0);
      motion.sample(0.15);
      final double opacity = motion.opacity;
      final double offset = motion.offset;

      motion.set(false, 0.15);
      expect(motion.opacity, opacity);
      expect(motion.offset, offset);
      expect(motion.duration, 0.2);
      expect(motion.finished, isFalse);

      motion.sample(0.35);
      expect(motion.opacity, 0);
      expect(motion.offset, 8);
      expect(motion.finished, isTrue);
    });

    test('reduced motion snaps to the target without a curve', () {
      final ModalShellMotion motion = ModalShellMotion();
      motion.set(true, 0, reduced: true);
      expect(motion.opacity, 1);
      expect(motion.offset, 0);
      expect(motion.duration, 0);
      expect(motion.finished, isTrue);

      motion.set(false, 1, reduced: true);
      expect(motion.opacity, 0);
      expect(motion.offset, 8);
      expect(motion.duration, 0);
    });
  });

  // =========================================================================
  // detail-sort (Qt/src/NativeHudModal.cpp:122-141)
  // =========================================================================
  group('DetailSortModal', () {
    test('has no scrim and no title band, but keeps the panel and dismissal',
        () {
      final _Sink sink = _Sink();
      final ModalShellResult result = const DetailSortModal(
        width: 1920,
        dark: true,
        offset: 8,
      ).build(sink, const _Metrics());

      expect(sink.commands.first, <Object?>['save']);
      expect(sink.commands[1], <Object?>['alpha', 1.0]);
      expect(sink.commands[2], <Object?>['translate', 0.0, 8.0]);
      expect(sink.commands[3][0], 'fill');
      expect(sink.commands[3][1], <Object?>[0.15, 0.15, 0.15, 1]);
      expect(sink.commands[3][2], 611);
      expect(sink.commands[3][3], 391);
      expect(sink.commands[3][4], 240);
      expect(sink.commands[3][5], 184);
      expect(result.policy.paintsStageScrim, isFalse);
      expect(result.policy.usesTitleBand, isFalse);
      expect(_texts(sink.commands), isNot(contains(
          'RHINE LAB / MUSIC DATABASE / MUSIC DIRECTORY')));
    });

    test('stage-wide dismissal cancels the overlay offset (Qt/qml/Overlay.qml:185-235)',
        () {
      final _Sink sink = _Sink();
      final ModalShellResult result = const DetailSortModal(
        width: 1920,
        offset: 8,
      ).build(sink, const _Metrics());

      expect(result.hits.length, 5);
      final HudHit catcher = result.hits.first;
      expect(catcher.action, 'close-modal');
      expect(catcher.label, '关闭排序菜单');
      expect(catcher.x, 0);
      expect(catcher.y, -8);
      expect(catcher.width, 1920);
      expect(catcher.height, 1080);
      expect(catcher.fixed, isFalse);
    });

    test('four content rows keep Qt geometry and action strings', () {
      final _Sink sink = _Sink();
      final ModalShellResult result = const DetailSortModal(
        width: 1920,
      ).build(sink, const _Metrics());

      expect(
        _hitActions(result.hits),
        <String>[
          'close-modal',
          'music:sort:detail:none',
          'music:sort:detail:title',
          'music:sort:detail:album',
          'music:sort:detail:artist',
        ],
      );
      for (int index = 0; index < 4; index += 1) {
        final HudHit row = result.hits[index + 1];
        expect(row.x, 619); // 611 + 8
        expect(row.y, 399 + index * 42); // 391 + 8 + i*42
        expect(row.width, 224); // 240 - 16
        expect(row.height, 42);
        // detailSort defaults to 'none', so row 0 carries Qt's check prefix
        // (detail_sort_modal.dart:104-105 / NativeHudModal.cpp:132-136).
        const List<String> labels = <String>[
          '默认排序',
          '按歌曲名排序',
          '按专辑名排序',
          '按歌手名排序',
        ];
        expect(
          row.label,
          index == 0 ? '✓ ' + labels[index] : labels[index],
        );
      }
    });

    test('the active field gets the check prefix', () {
      final _Sink sink = _Sink();
      const DetailSortModal modal = DetailSortModal(
        width: 1920,
        detailSort: 'album',
      );
      final ModalShellResult result = modal.build(sink, const _Metrics());

      expect(result.hits[3].label, '✓ 按专辑名排序');
      expect(result.hits[1].label, '默认排序');
      expect(_texts(sink.commands), contains('✓ 按专辑名排序'));
    });

    test('content buttons replicate Qt button() under m_modalControls', () {
      final _Sink sink = _Sink();
      const DetailSortModal modal = DetailSortModal(width: 1920);
      modal.build(sink, const _Metrics());

      // Default detailSort 'none' is the active row, so its label is prefixed.
      final List<Object?> label = _textCommand(sink.commands, '✓ 默认排序');
      expect(label[2], 629); // 619 + min(10, 224/8)
      expect(label[3], 409); // 399 + (42-14)/2 - 4
      expect(label[4], 14);
      expect(label[5], 'regular');
      final List<Object?> tint =
          _fillOf(sink.commands, 619, 399, 224, 42);
      // Qt NativeHud.cpp:114-116, light modal-control tint.
      expect(tint[1], <Object?>[0.44, 0.49, 0.36, 0.1]);
      expect(sink.commands.last, <Object?>['restore']);
    });

    test('Escape closes; no invented key behaviour', () {
      expect(DetailSortModal.closeAction, 'close-modal');
      expect(DetailSortModal.actionForKey('Escape'), 'close-modal');
      expect(DetailSortModal.actionForKey('Tab'), isNull);
      expect(DetailSortModal.actionForKey('Enter'), isNull);
      expect(DetailSortModal.actionFor('title'), 'music:sort:detail:title');
      expect(DetailSortModal.fields, <String>['none', 'title', 'album', 'artist']);
      expect(DetailSortModal.labels, <String>[
        '默认排序',
        '按歌曲名排序',
        '按专辑名排序',
        '按歌手名排序',
      ]);
    });

    test('build is pure and repeatable', () {
      const DetailSortModal modal = DetailSortModal(width: 1200);
      final _Sink first = _Sink();
      final _Sink second = _Sink();
      final ModalShellResult a = modal.build(first, const _Metrics());
      final ModalShellResult b = modal.build(second, const _Metrics());
      expect(second.commands, first.commands);
      expect(b.hits.length, a.hits.length);
      expect(a.bounds.left, 50);
      expect(a.bounds.width, 1100);
    });
  });

  // =========================================================================
  // disc-rotation-warning (Qt/src/NativeHudModal.cpp:203-209)
  // =========================================================================
  group('DiscWarningModal', () {
    test('generic frame renders the full title band at 1920', () {
      final _Sink sink = _Sink();
      final ModalShellResult result =
          const DiscWarningModal(width: 1920).build(sink, const _Metrics());

      expect(sink.commands[0], <Object?>['save']);
      expect(sink.commands[1], <Object?>['alpha', 1.0]);
      expect(sink.commands[2][0], 'fill');
      expect(sink.commands[2][1],
          <Object?>[227 / 255, 224 / 255, 215 / 255, 0.45]);
      expect(sink.commands[2][4], 1920);
      expect(sink.commands[2][5], 1080);
      expect(sink.commands[3], <Object?>['translate', 0.0, 0.0]);
      expect(sink.commands[4][1], <Object?>[0.929, 0.922, 0.894, 1]);
      expect(sink.commands[4][2], 330);
      expect(sink.commands[4][3], 122);

      expect(
        _textCommand(sink.commands,
            'RHINE LAB / MUSIC DATABASE / MUSIC DIRECTORY')[3],
        159,
      );
      expect(_textCommand(sink.commands, 'DISC ROTATION')[3], 213);
      expect(
        _textCommand(sink.commands, '开启前请确认资源与功耗风险')[3],
        269,
      );
      expect(result.hits.length, 3);
      expect(sink.commands.last, <Object?>['restore']);
    });

    test('four body paragraphs keep their Qt copy and offsets', () {
      final _Sink sink = _Sink();
      const DiscWarningModal(width: 1920).build(sink, const _Metrics());

      final Map<String, double> expected = <String, double>{
        '唱片旋转需要持续刷新画面。': 372, // 122 + 250
        '开启后会增加 CPU / GPU 占用、耗电和发热，可能缩短电池续航。': 432,
        '仅当前歌曲的详情页和歌词页旋转；资源库、暂停和后台均不旋转。': 474,
        '该功能默认关闭，减少动态效果开启时也不会旋转。': 516,
      };
      expected.forEach((String text, double y) {
        final List<Object?> command = _textCommand(sink.commands, text);
        expect(command[2], 383); // 330 + 53
        expect(command[3], y);
      });
      expect(_textCommand(sink.commands, '唱片旋转需要持续刷新画面。')[4], 22);
      expect(_textCommand(sink.commands, '唱片旋转需要持续刷新画面。')[5],
          'demibold');
    });

    test('the two risk buttons emit enable / cancel exactly once', () {
      final _Sink sink = _Sink();
      final ModalShellResult result =
          const DiscWarningModal(width: 1920).build(sink, const _Metrics());

      expect(_hitActions(result.hits),
          <String>['close-modal', 'disc-rotation:enable', 'disc-rotation:cancel']);
      final HudHit enable = result.hits[1];
      expect(enable.x, 383);
      expect(enable.y, 602); // 122 + 480
      expect(enable.width, 260);
      expect(enable.height, 48);
      expect(enable.label, '了解风险，仍然开启');
      final HudHit cancel = result.hits[2];
      expect(cancel.x, 670); // 330 + 340
      expect(cancel.width, 180);
      expect(cancel.label, '保持关闭');
      expect(_countActions(result.hits, 'disc-rotation:enable'), 1);
      expect(_countActions(result.hits, 'disc-rotation:cancel'), 1);
    });

    test('dark scrim is 0.6 alpha and the panel keeps the calibrated tag', () {
      final _Sink sink = _Sink();
      const DiscWarningModal(width: 1920, dark: true).build(sink, const _Metrics());
      expect(sink.commands[2][1],
          <Object?>[17 / 255, 24 / 255, 27 / 255, 0.6]);
      expect(sink.commands[4][1],
          <Object?>[0.15, 0.15, 0.15, 1, 'calibratedWhite']);
      final List<Object?> body = _textCommand(sink.commands, 'DISC ROTATION');
      expect(body[7], <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite']);
    });

    test('Escape maps to close-modal and the action table is Qt-exact', () {
      expect(DiscWarningModal.actions,
          <String>['close-modal', 'disc-rotation:enable', 'disc-rotation:cancel']);
      expect(DiscWarningModal.escapeAction, 'close-modal');
      expect(DiscWarningModal.actionForKey('Escape'), 'close-modal');
      expect(DiscWarningModal.actionForKey('Space'), isNull);
    });

    test('opacity and offset are injected, hits stay un-translated', () {
      final _Sink sink = _Sink();
      final ModalShellResult result = const DiscWarningModal(
        width: 1920,
        opacity: 0.4,
        offset: 6,
      ).build(sink, const _Metrics());

      expect(sink.commands[1], <Object?>['alpha', 0.4]);
      expect(sink.commands[3], <Object?>['translate', 0.0, 6.0]);
      expect(result.hits[1].y, 602);
    });
  });

  // =========================================================================
  // confirm (Qt/src/NativeHudModal.cpp:214-221) — misc angles only
  // =========================================================================
  group('ConfirmModal misc', () {
    ConfirmModal modal({
      bool dark = false,
      bool reduced = false,
      bool closing = false,
      bool search = false,
      bool isLocal = false,
      bool isSiren = false,
      String providerName = '',
    }) =>
        ConfirmModal(
          width: 1920,
          confirmTitle: '示例专辑',
          measureText: _measure,
          dark: dark,
          reduced: reduced,
          closing: closing,
          search: search,
          isLocal: isLocal,
          isSiren: isSiren,
          providerName: providerName,
        );

    test('search=true lowers the scrim alpha to the Qt values', () {
      final ConfirmModalFrame dark = modal(dark: true, search: true).build();
      expect(dark.commands[2][1],
          <Object?>[17 / 255, 24 / 255, 27 / 255, 0.15]);
      final ConfirmModalFrame light = modal(search: true).build();
      expect(light.commands[2][1],
          <Object?>[227 / 255, 224 / 255, 215 / 255, 0.12]);
    });

    test('reduced and closing change no command (modalDraw never branches)', () {
      final List<List<Object?>> plain = modal().build().commands;
      expect(modal(reduced: true).build().commands, plain);
      expect(modal(closing: true).build().commands, plain);
      expect(modal(reduced: true, closing: true).build().commands, plain);
    });

    test('empty provider name still renders the remote sentence', () {
      final ConfirmModalFrame frame = modal(providerName: '').build();
      expect(_texts(frame.commands), contains('此操作将同步至。'));
    });

    test('confirm:yes is emitted exactly once, between the two close targets',
        () {
      final ConfirmModalFrame frame = modal(providerName: '网易云音乐').build();
      final List<String> actions = frame.hits
          .map((List<Object?> hit) => hit[4]! as String)
          .toList();
      expect(actions, <String>['close-modal', 'confirm:yes', 'close-modal']);
      expect(
        actions.where((String action) => action == 'confirm:yes').length,
        1,
      );
    });

    test('confirm geometry matches the Qt confirm branch', () {
      final ConfirmModalFrame frame = modal().build();
      final List<Object?> back = frame.hits[0];
      expect(back[0], 1370);
      expect(back[1], 140);
      expect(back[2], 167);
      expect(back[3], 54);
      expect(back[5], '\u2190 \u8FD4\u56DE');
      final List<Object?> confirm = frame.hits[1];
      expect(confirm[0], 383);
      expect(confirm[1], 572); // 122 + 450
      expect(confirm[2], 180);
      expect(confirm[3], 45);
      final List<Object?> cancel = frame.hits[2];
      expect(cancel[0], 600); // 330 + 270
      expect(cancel[2], 150);
    });

    test('escapeAction and the action table stay Qt-exact', () {
      expect(ConfirmModal.actions, <String>['confirm:yes', 'close-modal']);
      expect(ConfirmModal.escapeAction, 'close-modal');
      expect(ConfirmModal.title, 'CONFIRM DELETE');
      expect(ConfirmModal.subtitle, '删除确认');
      expect(ConfirmModal.category, 'MUSIC DIRECTORY');
    });

    test('the legacy frame still owns a single full-stage scrim', () {
      final ConfirmModalFrame frame = modal().build();
      expect(_ofType(frame.commands, 'fill').first[1],
          <Object?>[227 / 255, 224 / 255, 215 / 255, 0.45]);
      expect(_ofType(frame.commands, 'fill').first.sublist(2),
          <Object?>[0.0, 0.0, 1920.0, 1080.0]);
    });

    test('build is pure and repeatable', () {
      final ConfirmModal subject = modal(providerName: 'QQ 音乐');
      final ConfirmModalFrame first = subject.build();
      final ConfirmModalFrame second = subject.build();
      expect(second.commands, first.commands);
      expect(second.hits, first.hits);
    });
  });

  // =========================================================================
  // provider (Qt/src/NativeHudModal.cpp:259-306)
  // =========================================================================
  group('ProviderModal', () {
    ProviderModal modal({
      String currentProvider = 'netease',
      Set<String> credentials = const <String>{'qq'},
      bool localMusicEnabled = true,
      bool dark = false,
      bool kugouLite = false,
    }) =>
        ProviderModal(
          textPort: const _Metrics(),
          stageWidth: 1920,
          dark: dark,
          opacity: 1,
          offset: 0,
          currentProvider: currentProvider,
          credentials: credentials,
          localMusicEnabled: localMusicEnabled,
          kugouLite: kugouLite,
        );

    test('initial render keeps the Qt frame, title band and card order', () {
      final ProviderModalFrame frame = modal().build();

      expect(frame.bounds.left, 330);
      expect(frame.bounds.top, 122);
      expect(frame.bounds.width, 1260);
      expect(frame.bounds.height, 836);
      expect(frame.policy.category, 'MUSIC DIRECTORY');
      expect(_texts(frame.commands), contains('MUSIC PLATFORM'));
      expect(_texts(frame.commands), contains('直接选择音乐平台 / 各平台账号独立保存'));
      final List<Object?> section =
          _textCommand(frame.commands, 'PROVIDER ACCESS / 音乐平台');
      expect(section[2], 383);
      expect(section[3], 344); // 122 + 222
      expect(section[4], 13);
      expect(section[5], 'demibold');
      expect(
        _hitActions(frame.hits),
        <String>[
          'close-modal',
          'provider:siren',
          'provider:netease',
          'provider:qq',
          'provider:kugou',
          'provider:local',
          'music:login',
        ],
      );
    });

    test('five expanded cards use the Qt gap and width', () {
      final ProviderModalFrame frame = modal().build();
      // usable 1154, gap 12 => (1154 - 48) / 5 = 221.2.
      final HudHit siren = frame.hits[1];
      expect(siren.x, 383);
      expect(siren.y, 380); // 122 + 258
      expect(siren.width, closeTo(221.2, 1e-9));
      expect(siren.height, 190);
      expect(siren.label, '塞壬唱片');
      final HudHit netease = frame.hits[2];
      expect(netease.x, closeTo(616.2, 1e-9)); // 383 + 221.2 + 12
      final HudHit local = frame.hits[5];
      expect(local.x, closeTo(1315.8, 1e-9)); // 383 + 4 * 233.2
    });

    test('localMusicEnabled=false drops the local card and reflows', () {
      final ProviderModalFrame frame =
          modal(localMusicEnabled: false).build();
      expect(_hitActions(frame.hits), isNot(contains('provider:local')));
      expect(
        frame.hits.where((HudHit hit) => hit.action.startsWith('provider:')).length,
        4,
      );
      // (1154 - 36) / 4 = 279.5.
      expect(frame.hits[1].width, closeTo(279.5, 1e-9));
    });

    test('the active card carries /ACTIVE, the tint and the 3 px bar', () {
      final ProviderModalFrame frame =
          modal(currentProvider: 'qq', credentials: const <String>{}).build();
      expect(_texts(frame.commands), contains('QQ MUSIC / ACTIVE'));
      expect(_texts(frame.commands), isNot(contains('NETEASE / ACTIVE')));
      final List<List<Object?>> fills = _ofType(frame.commands, 'fill');
      // fills: scrim, panel, card1..card5, selected bar, login tint.
      expect(fills[2][1], <Object?>[0.44, 0.49, 0.36, 0.09]);
      // Qt NativeHudModal.cpp:267-268: light selected alpha is 0.23.
      expect(fills[4][1], <Object?>[0.44, 0.49, 0.36, 0.23]);
      final List<Object?> bar = fills.firstWhere(
        (List<Object?> command) =>
            command[4] == 3 && command[5] == 190,
      );
      expect(bar[1], <Object?>[0.44, 0.49, 0.36, 1]);
      expect(bar[2], closeTo(849.4, 1e-9)); // qq card left
    });

    test('credential state picks the Qt note per card', () {
      final ProviderModalFrame frame =
          modal(credentials: const <String>{'qq'}).build();
      expect(_texts(frame.commands), contains('本机已保存登录'));
      expect(_texts(frame.commands), contains('官网曲库 / 无需登录'));
      expect(_texts(frame.commands), contains('独立本地库 / 无需登录'));
      expect(_texts(frame.commands), contains('未登录 / 可选择后扫码'));
    });

    test('local provider shows 文件夹管理, siren shows no login control', () {
      final ProviderModalFrame local = modal(currentProvider: 'local').build();
      final HudHit manage = _hitWithAction(local.hits, 'discover');
      expect(manage.x, 383);
      expect(manage.y, 782); // 122 + 660
      expect(manage.width, 330);
      expect(manage.height, 48);
      expect(manage.label, '文件夹管理 ＋');
      expect(_hitActions(local.hits), isNot(contains('music:login')));

      final ProviderModalFrame siren = modal(currentProvider: 'siren').build();
      expect(_hitActions(siren.hits), isNot(contains('music:login')));
      final List<Object?> text =
          _textCommand(siren.commands, '塞壬唱片官网曲库');
      expect(text[2], 383);
      expect(text[3], 797); // 122 + 675
    });

    test('remote providers show 账号登录 and the kugou lite name', () {
      expect(_texts(modal(currentProvider: 'kugou').build().commands),
          isNot(contains('账号登录 / 酷狗概念版')));
      expect(
        _hitWithAction(
                modal(currentProvider: 'kugou').build().hits, 'music:login')
            .label,
        '账号登录 / 酷狗音乐',
      );
      final ProviderModalFrame kugou = modal(
        currentProvider: 'kugou',
        kugouLite: true,
      ).build();
      final HudHit login = _hitWithAction(kugou.hits, 'music:login');
      expect(login.label, '账号登录 / 酷狗概念版');
      expect(login.x, 383);
      expect(login.y, 782);
      expect(login.width, 330);
      expect(login.height, 48);

      final ProviderModalFrame netease = modal().build();
      expect(_hitWithAction(netease.hits, 'music:login').label,
          '账号登录 / 网易云音乐');
    });

    test('each provider action is emitted once and build is repeatable', () {
      final ProviderModal subject = modal(currentProvider: 'kugou');
      final ProviderModalFrame first = subject.build();
      final ProviderModalFrame second = subject.build();
      expect(second.commands, first.commands);
      expect(_hitActions(second.hits), _hitActions(first.hits));
      for (final HudHit hit in first.hits) {
        expect(_countActions(first.hits, hit.action), 1, reason: hit.action);
      }
    });

    test('dark variant uses the dark tint and scrim', () {
      final ProviderModalFrame frame =
          modal(dark: true, currentProvider: 'qq').build();
      expect(frame.commands[2][1],
          <Object?>[17 / 255, 24 / 255, 27 / 255, 0.6]);
      final List<List<Object?>> fills = _ofType(frame.commands, 'fill');
      expect(fills[2][1], <Object?>[0.55, 0.59, 0.46, 0.12]);
      expect(fills[4][1], <Object?>[0.55, 0.59, 0.46, 0.3]);
      expect(_texts(frame.commands), contains('QQ MUSIC / ACTIVE'));
    });
  });

  // =========================================================================
  // quality (Qt/src/NativeHudModal.cpp:326-446)
  // =========================================================================
  group('QualityModal', () {
    QualityModal modal({
      String provider = 'netease',
      String selectedQuality = 'lossless',
      String actualQuality = 'sq',
      bool loading = false,
      bool failed = false,
      bool trial = false,
      bool dark = false,
      QualityModalBadgeResolver? badges,
    }) =>
        QualityModal(
          textPort: const _Metrics(),
          stageWidth: 1920,
          dark: dark,
          opacity: 1,
          offset: 0,
          provider: provider,
          selectedQuality: selectedQuality,
          actualQuality: actualQuality,
          loading: loading,
          failed: failed,
          trial: trial,
          badges: badges,
        );

    test('initial render keeps the Qt frame and the actual-source block', () {
      final QualityModalFrame frame = modal().build();

      expect(frame.bounds.left, 330);
      expect(frame.bounds.top, 122);
      expect(frame.bounds.width, 1260);
      expect(frame.bounds.height, 836);
      expect(frame.policy.category, 'AUDIO SPECIFICATION');
      expect(_texts(frame.commands), contains('AUDIO QUALITY'));
      expect(_texts(frame.commands), contains('声音档案 / 播放音质'));
      expect(
        _textCommand(frame.commands,
            'RHINE LAB / MUSIC DATABASE / AUDIO SPECIFICATION')[3],
        159,
      );
      final List<Object?> section =
          _textCommand(frame.commands, '实际音源 / SOURCE');
      expect(section[2], 400); // 383 + 17
      expect(section[3], 321); // 122 + 199
      expect(section[4], 10);
      expect(section[5], 'demibold');
      expect(section[6], 0.6);
      final List<Object?> actual = _textCommand(frame.commands, '无损 / SQ');
      expect(actual[2], 400);
      expect(actual[3], 341); // 122 + 219
      expect(actual[4], 18);
      expect(actual[5], 'demibold');
    });

    test('unknown actual quality falls back to 尚未确认', () {
      final QualityModalFrame frame =
          modal(actualQuality: 'unknown-codec').build();
      expect(_texts(frame.commands), contains('尚未确认'));
    });

    test('failed wins over loading and trial, loading wins over trial', () {
      expect(_texts(modal(failed: true, loading: true, trial: true)
          .build()
          .commands), contains('音源不可用'));
      expect(_texts(modal(loading: true, trial: true).build().commands),
          contains('正在获取音源…'));
      expect(_texts(modal(trial: true).build().commands), contains('试听片段'));
    });

    test('preference line uses the description title, siren uses its override',
        () {
      expect(_texts(modal(selectedQuality: 'hires').build().commands),
          contains('已选偏好：高解析无损'));
      expect(_texts(modal(provider: 'siren', selectedQuality: 'lossless')
          .build()
          .commands), contains('已选偏好：官网原始音源'));
    });

    test('netease hit order: close, featured pair, then reversed options', () {
      final QualityModalFrame frame = modal().build();
      expect(
        _hitActions(frame.hits),
        <String>[
          'close-modal',
          'quality:set:jymaster',
          'quality:set:hires',
          'quality:set:lossless',
          'quality:set:exhigh',
          'quality:set:higher',
          'quality:set:standard',
        ],
      );
      for (final HudHit hit in frame.hits) {
        expect(_countActions(frame.hits, hit.action), 1, reason: hit.action);
      }
    });

    test('featured cards use two columns at y+278 and 174 px height', () {
      final QualityModalFrame frame = modal().build();
      final HudHit jymaster = frame.hits[1];
      expect(jymaster.x, 383);
      expect(jymaster.y, 400); // 122 + 278
      expect(jymaster.width, 568); // (1154 - 18) / 2
      expect(jymaster.height, 174);
      expect(jymaster.label, '超清母带');
      final HudHit hires = frame.hits[2];
      expect(hires.x, 969); // 383 + 568 + 18
      expect(hires.y, 400);
      expect(_texts(frame.commands), contains('01 / MASTER AUDIO'));
      expect(_texts(frame.commands), contains('超清母带'));
      expect(_texts(frame.commands), contains('选择此档 →'));
    });

    test('compact rows run bottom-up with padded indices', () {
      final QualityModalFrame frame = modal().build();
      final HudHit lossless = frame.hits[3];
      expect(lossless.x, 383);
      expect(lossless.y, 596); // 122 + 474
      expect(lossless.width, 1154);
      expect(lossless.height, 57);
      expect(lossless.label, '无损');
      expect(frame.hits[4].y, 654); // + 58
      expect(frame.hits[6].y, 770); // 596 + 3 * 58
      expect(_texts(frame.commands), contains('03'));
      expect(_texts(frame.commands), contains('06'));
    });

    test('selected row shows the check, others show the caption', () {
      // Select a row that is not "lossless" so the lossless row renders its
      // caption instead of the check (Qt/src/NativeHudModal.cpp:375).
      final QualityModalFrame frame =
          modal(selectedQuality: 'standard').build();
      expect(_texts(frame.commands), contains('✓ 已选择'));
      expect(_texts(frame.commands), contains('LOSSLESS / SQ'));
    });

    test('netease footer adds 其他音源标识 without inventing badges', () {
      final QualityModalFrame frame = modal().build();
      final List<Object?> extra =
          _textCommand(frame.commands, '其他音源标识');
      expect(extra[2], 383);
      expect(extra[3], 860); // 122 + 738
      expect(extra[4], 11);
      expect(_textCommand(frame.commands, '选择与设置同步 · 切换保留播放位置')[3],
          913);
      expect(_ofType(frame.commands, 'image'), isEmpty);
    });

    test('extra netease badges render at 18 px height when resolvable', () {
      final QualityModalFrame frame = modal(badges: (String key) {
        if (key == 'quality:netease-jyeffect') {
          return const QualityModalBadge(width: 2, height: 1);
        }
        return null;
      }).build();
      final List<List<Object?>> images = _ofType(frame.commands, 'image');
      expect(images.length, 1);
      final List<Object?> image = images.single;
      expect(image[1], 'quality:netease-jyeffect');
      expect(image[2], 513); // 383 + 130
      expect(image[3], 857); // 122 + 735
      expect(image[4], 36); // 18 * 2 / 1
      expect(image[5], 18);
      expect(_textCommand(frame.commands, '高清臻音')[2], 561); // 513 + 36 + 12);
    });

    test('featured badge is capped at 68 px and preserves aspect', () {
      final QualityModalFrame frame = modal(badges: (String key) {
        if (key == 'quality:netease-jymaster') {
          return const QualityModalBadge(width: 3, height: 1);
        }
        return null;
      }).build();
      final List<Object?> image =
          _ofType(frame.commands, 'image').first;
      expect(image[1], 'quality:netease-jymaster');
      expect(image[2], 847); // 383 + 568 - 104
      expect(image[3], 419); // 122 + 278 + 19
      expect(image[4], 63); // min(68, 21 * 3)
      expect(image[5], 21); // 63 * 1 / 3
    });

    test('kugou badges get the dark backing plate before the image', () {
      final QualityModalFrame frame = modal(
        provider: 'kugou',
        selectedQuality: 'hires',
        badges: (String key) {
          if (key == 'quality:kugou-hires') {
            return const QualityModalBadge(width: 2, height: 1);
          }
          return null;
        },
      ).build();
      final List<List<Object?>> images = _ofType(frame.commands, 'image');
      expect(images.length, 1);
      final List<List<Object?>> fills = _ofType(frame.commands, 'fill');
      final List<Object?> plate = fills.firstWhere(
        (List<Object?> command) => command[1] is List<Object?> &&
            (command[1]! as List<Object?>).length == 4 &&
            (command[1]! as List<Object?>)[0] == 0.30,
      );
      expect(plate[1], <Object?>[0.30, 0.33, 0.26, 1]);
      expect(plate[4], 50); // 42 + 8
      expect(plate[5], 29); // 21 + 8
    });

    test('siren pins lossless and paints its substitute description', () {
      final QualityModalFrame frame =
          modal(provider: 'siren', selectedQuality: 'standard').build();
      expect(_hitActions(frame.hits),
          <String>['close-modal', 'quality:set:lossless']);
      expect(_texts(frame.commands), contains('官网原始音源'));
      // The pinned row is selected, so Qt draws the check instead of the caption
      // (Qt/src/NativeHudModal.cpp:375): the ORIGINAL SOURCE caption never shows.
      expect(_texts(frame.commands), isNot(contains('ORIGINAL SOURCE')));
      expect(_texts(frame.commands), contains('✓ 已选择'));
    });

    test('compact text badges: HQ / STD / AUTO follow the Qt table', () {
      final QualityModalFrame frame = modal(
        provider: 'qq',
        selectedQuality: 'standard',
      ).build();
      // qq rows are ape / exhigh / standard: sq -> STD, hq -> HQ, empty -> STD.
      expect(_texts(frame.commands), contains('HQ'));
      expect(_texts(frame.commands), isNot(contains('AUTO')));
      expect(
        _texts(frame.commands).where((String text) => text == 'STD').length,
        2,
      );
    });

    test('emits only known Qt ops and no raw text-field action', () {
      final QualityModalFrame frame = modal().build();
      const Set<String> ops = <String>{
        'save',
        'alpha',
        'translate',
        'fill',
        'text',
        'image',
        'restore',
      };
      for (final List<Object?> command in frame.commands) {
        expect(ops, contains(command[0]));
      }
      for (final HudHit hit in frame.hits) {
        expect(hit.action.startsWith('input'), isFalse);
        expect(hit.fixed, isFalse);
      }
    });

    test('build is pure and repeatable', () {
      final QualityModal subject = modal(selectedQuality: 'exhigh');
      final QualityModalFrame first = subject.build();
      final QualityModalFrame second = subject.build();
      expect(second.commands, first.commands);
      expect(_hitActions(second.hits), _hitActions(first.hits));
      expect(second.bounds.left, first.bounds.left);
    });
  });
}
