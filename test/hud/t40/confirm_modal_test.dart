// Written but NOT executed: the writer task forbids running flutter/dart test,
// analyze or build. Intended command:
//   flutter test test/hud/t40/confirm_modal_test.dart
//
// Every expected number below is copied from, or computed exactly as, the Qt
// source cited next to it; none is read back from the Dart implementation.

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/confirm_modal.dart';

/// Deterministic stand-in for Qt `Glyphs::width` (Qt/src/Glyphs.cpp:286):
/// one UTF-16 code unit measures `size`, tracking adds `tracking` per unit.
/// The library must never hardcode glyph widths, so tests inject this.
double _measure(String text, double size, String? weight, double tracking) =>
    text.length * size + tracking * text.length;

// Qt/src/NativeHud.cpp:10-15.
const List<Object?> _darkInk = <Object?>[0.92, 0.92, 0.92, 1.0, 'calibratedWhite'];
const List<Object?> _lightInk = <Object?>[0.08, 0.085, 0.075, 1.0, 'calibratedRGB'];

// Qt/src/NativeHudModal.cpp:171-172.
const List<Object?> _darkPanel = <Object?>[0.15, 0.15, 0.15, 1.0, 'calibratedWhite'];
const List<Object?> _lightPanel = <Object?>[0.929, 0.922, 0.894, 1.0];

// Qt/src/NativeHud.cpp:116.
const List<Object?> _darkTint = <Object?>[0.55, 0.59, 0.46, 0.13];
const List<Object?> _lightTint = <Object?>[0.44, 0.49, 0.36, 0.1];

ConfirmModal _modal({
  double width = 1920.0,
  bool dark = true,
  String confirmTitle = '移除索引：LenMusic',
  bool isLocal = true,
  bool isSiren = false,
  String providerName = '网易云音乐',
  double opacity = 1.0,
  double offset = 0.0,
  ConfirmModalRectHook? rectHook,
}) =>
    ConfirmModal(
      width: width,
      dark: dark,
      confirmTitle: confirmTitle,
      measureText: _measure,
      isLocal: isLocal,
      isSiren: isSiren,
      providerName: providerName,
      opacity: opacity,
      offset: offset,
      rectHook: rectHook,
    );

void main() {
  group('confirm modal: generic full-modal geometry', () {
    test('draw order is save, alpha, scrim, translate, panel … restore '
        '(NativeHudModal.cpp:83-84, :162-174, :255-256)', () {
      final ConfirmModalFrame frame = _modal().build();
      expect(frame.commands.length, 17);
      expect(frame.commands.first, <Object?>['save']);
      expect(frame.commands[1], <Object?>['alpha', 1.0]);
      expect(frame.commands[3], <Object?>['translate', 0.0, 0.0]);
      expect(frame.commands.last, <Object?>['restore']);
    });

    test('scrim covers the whole 1920x1080 stage: 17/255,24/255,27/255 alpha .6 '
        '(NativeHudModal.cpp:163-165)', () {
      final ConfirmModalFrame frame = _modal(width: 1920, dark: true).build();
      expect(frame.commands[2], <Object?>[
        'fill',
        <Object?>[17.0 / 255.0, 24.0 / 255.0, 27.0 / 255.0, 0.6],
        0.0,
        0.0,
        1920.0,
        1080.0,
      ]);
    });

    test('panel: min(1260, width-100) wide, centred, top 122, height 836 '
        '(NativeHud.cpp:153-158, NativeHudModal.cpp:171-172)', () {
      final ConfirmModalFrame frame = _modal(width: 1920).build();
      // (1920 - min(1260, 1820)) / 2 = 330.
      expect(frame.commands[4],
          <Object?>['fill', _darkPanel, 330.0, 122.0, 1260.0, 836.0]);
    });

    test('narrow stage: width 1200 gives modalWidth 1100 at left 50 '
        '(NativeHud.cpp:153-158)', () {
      final ConfirmModalFrame frame = _modal(width: 1200).build();
      expect(frame.commands[4],
          <Object?>['fill', _darkPanel, 50.0, 122.0, 1100.0, 836.0]);
      // Title starts at x + 53 = 103; its fit width is usable - 106 = 994.
      expect(frame.commands[10][2], 103.0);
    });

    test('wide stage: width 1600 clamps the modal to 1260 at left 170 '
        '(NativeHud.cpp:153)', () {
      final ConfirmModalFrame frame = _modal(width: 1600).build();
      expect(frame.commands[4],
          <Object?>['fill', _darkPanel, 170.0, 122.0, 1260.0, 836.0]);
    });

    test('opacity and offset are injected, never recomputed '
        '(NativeHudModal.cpp:84, :166)', () {
      final ConfirmModalFrame frame = _modal(opacity: 0.42, offset: 18.0).build();
      expect(frame.commands[1], <Object?>['alpha', 0.42]);
      expect(frame.commands[3], <Object?>['translate', 0.0, 18.0]);
    });

    test('light theme: ink, panel, tint and scrim alpha .45 '
        '(NativeHud.cpp:10-15, :116, NativeHudModal.cpp:163-172)', () {
      final ConfirmModalFrame frame = _modal(dark: false).build();
      expect(frame.commands[2], <Object?>[
        'fill',
        <Object?>[227.0 / 255.0, 224.0 / 255.0, 215.0 / 255.0, 0.45],
        0.0,
        0.0,
        1920.0,
        1080.0,
      ]);
      expect(frame.commands[4],
          <Object?>['fill', _lightPanel, 330.0, 122.0, 1260.0, 836.0]);
      expect(frame.commands[5][7], _lightInk);
      expect(frame.commands[6][1], _lightTint);
      expect(frame.commands[12][1], _lightTint);
    });
  });

  group('confirm modal: shared header', () {
    test('category line, title and subtitle at the Qt offsets '
        '(NativeHudModal.cpp:188, :198-202, :37, :62)', () {
      final ConfirmModalFrame frame = _modal().build();
      expect(frame.commands[5], <Object?>[
        'text',
        'RHINE LAB / MUSIC DATABASE / MUSIC DIRECTORY',
        383.0, // x + 53
        159.0, // y + 37
        11.0, // "confirm" is not "settings"
        'regular',
        0.0,
        _darkInk,
      ]);
      expect(frame.commands[8],
          <Object?>['text', 'CONFIRM DELETE', 383.0, 213.0, 38.0, 'demibold', 0.0, _darkInk]);
      expect(frame.commands[9],
          <Object?>['text', '删除确认', 383.0, 269.0, 15.0, 'regular', 0.0, _darkInk]);
    });

    test('back button: x+usable-220, y+18, 167x54, size 20 demibold '
        '(NativeHudModal.cpp:199-200)', () {
      final ConfirmModalFrame frame = _modal().build();
      expect(frame.hits[0],
          <Object?>[1370.0, 140.0, 167.0, 54.0, 'close-modal', '← 返回']);
      // inset = min(10, 167/8) = 10; label y = 140 + (54-20)/2 - 4 = 153.
      expect(frame.commands[6],
          <Object?>['fill', _darkTint, 1370.0, 140.0, 167.0, 54.0]);
      expect(frame.commands[7],
          <Object?>['text', '← 返回', 1380.0, 153.0, 20.0, 'demibold', 0.0, _darkInk]);
    });
  });

  group('confirm modal: confirm branch (NativeHudModal.cpp:214-221)', () {
    test('confirmTitle is limited() at x+53, y+260, size 24, usable-106 '
        '(NativeHudModal.cpp:215)', () {
      final ConfirmModalFrame frame = _modal().build();
      expect(frame.commands[10],
          <Object?>['text', '移除索引：LenMusic', 383.0, 382.0, 24.0, 'demibold', 0.0, _darkInk]);
    });

    test('confirmTitle truncation goes through the injected measurer '
        '(NativeHud.cpp:48-76)', () {
      // 60 units at size 24 measure 1440 > 1154, so the longest fitting prefix
      // is 48 units (48*24 = 1152 <= 1154); Qt drops one more and appends "…".
      final String longTitle = List<String>.filled(60, 'A').join();
      final String expected = '${List<String>.filled(47, 'A').join()}…';
      final ConfirmModalFrame frame = _modal(confirmTitle: longTitle).build();
      expect(frame.commands[10][1], expected);
    });

    test('confirmTitle that fits is emitted unchanged (no ellipsis)', () {
      final ConfirmModalFrame frame = _modal(confirmTitle: '删除歌单：夜航').build();
      expect(frame.commands[10][1], '删除歌单：夜航');
    });

    test('body text: local branch (NativeHudModal.cpp:216)', () {
      final ConfirmModalFrame frame =
          _modal(isLocal: true, isSiren: false, providerName: '网易云音乐').build();
      expect(frame.commands[11], <Object?>[
        'text',
        '只移除本地索引，磁盘音乐文件保持原样。',
        383.0,
        452.0,
        16.0,
        'regular',
        0.0,
        _darkInk,
      ]);
    });

    test('body text: siren branch wins over providerName (NativeHudModal.cpp:217)', () {
      final ConfirmModalFrame frame =
          _modal(isLocal: false, isSiren: true, providerName: '网易云音乐').build();
      expect(frame.commands[11][1], '只删除本机歌单，不会同步到塞壬唱片。');
    });

    test('body text: remote branch concatenates providerName (NativeHudModal.cpp:218)', () {
      final ConfirmModalFrame frame = _modal(
        isLocal: false,
        isSiren: false,
        providerName: '网易云音乐',
      ).build();
      expect(frame.commands[11], <Object?>[
        'text',
        '此操作将同步至网易云音乐。',
        383.0,
        452.0,
        16.0,
        'regular',
        0.0,
        _darkInk,
      ]);
    });

    test('confirm button: x+53, y+450, 180x45, action confirm:yes, size 16 '
        '(NativeHudModal.cpp:220)', () {
      final ConfirmModalFrame frame = _modal().build();
      expect(frame.hits[1],
          <Object?>[383.0, 572.0, 180.0, 45.0, 'confirm:yes', '确认删除']);
      expect(frame.commands[12],
          <Object?>['fill', _darkTint, 383.0, 572.0, 180.0, 45.0]);
      // inset = min(10, 180/8) = 10; label y = 572 + (45-16)/2 - 4 = 582.5.
      expect(frame.commands[13],
          <Object?>['text', '确认删除', 393.0, 582.5, 16.0, 'regular', 0.0, _darkInk]);
    });

    test('cancel button: x+270, y+450, 150x45, action close-modal, size 16 '
        '(NativeHudModal.cpp:221)', () {
      final ConfirmModalFrame frame = _modal().build();
      expect(frame.hits[2],
          <Object?>[600.0, 572.0, 150.0, 45.0, 'close-modal', '取消']);
      expect(frame.commands[14],
          <Object?>['fill', _darkTint, 600.0, 572.0, 150.0, 45.0]);
      expect(frame.commands[15],
          <Object?>['text', '取消', 610.0, 582.5, 16.0, 'regular', 0.0, _darkInk]);
    });
  });

  group('confirm modal: hit table', () {
    test('exactly three hits, in draw order, with the six Qt fields '
        '(NativeHud.cpp:102-120)', () {
      final List<List<Object?>> hits = _modal().build().hits;
      expect(hits.length, 3);
      expect(hits[0], <Object?>[1370.0, 140.0, 167.0, 54.0, 'close-modal', '← 返回']);
      expect(hits[1], <Object?>[383.0, 572.0, 180.0, 45.0, 'confirm:yes', '确认删除']);
      expect(hits[2], <Object?>[600.0, 572.0, 150.0, 45.0, 'close-modal', '取消']);
    });

    test('every hit carries x, y, width, height, action, label in that order', () {
      for (final List<Object?> hit in _modal().build().hits) {
        expect(hit.length, 6);
        expect(hit[0], isA<double>());
        expect(hit[1], isA<double>());
        expect(hit[2], isA<double>());
        expect(hit[3], isA<double>());
        expect(hit[4], isA<String>());
        expect(hit[5], isA<String>());
      }
    });

    test('hits follow the drawn rectangles: each hit matches its fill', () {
      final ConfirmModalFrame frame = _modal().build();
      expect(frame.hits[0].sublist(0, 4), frame.commands[6].sublist(2, 6));
      expect(frame.hits[1].sublist(0, 4), frame.commands[12].sublist(2, 6));
      expect(frame.hits[2].sublist(0, 4), frame.commands[14].sublist(2, 6));
    });

    test('no full-screen outside catcher: only detail-sort installs one '
        '(NativeHudModal.cpp:128)', () {
      final List<List<Object?>> hits = _modal().build().hits;
      expect(hits.where((List<Object?> h) => h[2] == 1920.0 && h[3] == 1080.0), isEmpty);
    });
  });

  group('confirm modal: action table and close path', () {
    test('only the two Qt actions are emitted, in source order '
        '(NativeHudModal.cpp:220-221)', () {
      final ConfirmModalFrame frame = _modal().build();
      expect(frame.hits.map((List<Object?> h) => h[4]).toList(),
          <String>['close-modal', 'confirm:yes', 'close-modal']);
      expect(ConfirmModal.actions, <String>['confirm:yes', 'close-modal']);
    });

    test('取消 and ← 返回 both dispatch close-modal (NativeHudModal.cpp:199, :221)', () {
      final ConfirmModalFrame frame = _modal().build();
      expect(frame.hits[2][5], '取消');
      expect(frame.hits[2][4], 'close-modal');
      expect(frame.hits[0][5], '← 返回');
      expect(frame.hits[0][4], 'close-modal');
    });

    test('Escape maps to close-modal while this modal is open '
        '(NativeHudController.cpp:913-921)', () {
      expect(ConfirmModal.escapeAction, 'close-modal');
      expect(ConfirmModal.actions, contains(ConfirmModal.escapeAction));
    });

    test('confirm:yes is the only mutation action the panel offers', () {
      expect(ConfirmModal.actions.where((String a) => a == 'confirm:yes').length, 1);
    });
  });

  group('confirm modal: injected portrait hook', () {
    test('default identity keeps every Qt stage pixel exact', () {
      final ConfirmModalFrame frame = _modal().build();
      expect(frame.commands[4][2], 330.0);
      expect(frame.commands[4][3], 122.0);
      expect(frame.hits[1][0], 383.0);
    });

    test('a hook maps panel, hit and text rects consistently '
        '(no portrait pixel is invented here)', () {
      List<double> shift(double x, double y, double w, double h) =>
          <double>[x + 10, y + 20, w, h];
      final ConfirmModalFrame frame = _modal(rectHook: shift).build();
      expect(frame.commands[4],
          <Object?>['fill', _darkPanel, 340.0, 142.0, 1260.0, 836.0]);
      expect(frame.hits[1],
          <Object?>[393.0, 592.0, 180.0, 45.0, 'confirm:yes', '确认删除']);
      expect(frame.commands[13][2], 403.0);
      expect(frame.commands[13][3], 602.5);
    });
  });

  group('confirm modal: purity', () {
    test('build() allocates fresh lists and mutates no injected state', () {
      final ConfirmModal modal = _modal();
      final ConfirmModalFrame first = modal.build();
      final ConfirmModalFrame second = modal.build();
      expect(first.commands, second.commands);
      expect(first.hits, second.hits);
      expect(identical(first.commands, second.commands), isFalse);
      expect(identical(first.hits, second.hits), isFalse);
    });
  });

  group('ConfirmModalMotion == Qt UiMotion::SurfaceMotion', () {
    test('initial state: opacity 0, offset 12, duration 0, finished '
        '(UiMotion.h:28-42)', () {
      final ConfirmModalMotion motion = ConfirmModalMotion();
      expect(motion.opacity, 0.0);
      expect(motion.offset, 12.0);
      expect(motion.duration, 0.0);
      expect(motion.finished, isTrue);
    });

    test('sample() is a no-op while settled (UiMotion.cpp:86-89)', () {
      final ConfirmModalMotion motion = ConfirmModalMotion()..sample(5.0);
      expect(motion.opacity, 0.0);
      expect(motion.offset, 12.0);
      expect(motion.finished, isTrue);
    });

    test('set(true): duration 0.3 and the enter Bezier 0.22/1, 0.36/1 '
        '(UiMotion.cpp:91-92, :111-112)', () {
      final ConfirmModalMotion motion = ConfirmModalMotion();
      motion.set(true, 0.0);
      expect(motion.duration, 0.3);
      expect(motion.finished, isFalse);
      expect(motion.offset, 12.0); // from
      expect(motion.opacity, 0.0); // from

      motion.sample(0.15); // progress 0.5
      expect(motion.opacity, closeTo(0.96138255575218934, 1e-6));
      expect(motion.offset, closeTo(0.4634093309737279, 1e-6));

      motion.sample(0.3); // progress 1
      expect(motion.opacity, closeTo(1.0, 1e-6));
      expect(motion.offset, closeTo(0.0, 1e-6));
      expect(motion.duration, 0.0);
      expect(motion.finished, isTrue);
    });

    test('set(false): duration 0.2, offset target 8, exit Bezier 0.4/0, 1/1 '
        '(UiMotion.cpp:92, :106, :113-114)', () {
      final ConfirmModalMotion motion = ConfirmModalMotion();
      motion.set(true, 0.0);
      motion.sample(0.3); // settled at 1 / 0
      expect(motion.opacity, closeTo(1.0, 1e-6));
      expect(motion.offset, closeTo(0.0, 1e-6));

      motion.set(false, 1.0);
      expect(motion.duration, 0.2);
      expect(motion.finished, isFalse);

      motion.sample(1.1); // progress 0.5
      expect(motion.opacity, closeTo(0.6751854141442443, 1e-6));
      expect(motion.offset, closeTo(2.5985166868460458, 1e-6));

      // (1.25 - 1.0) / 0.2 = 1.25 >= 1, so UiMotion.cpp:95-97 clears the duration
      // and finished becomes true. Sampling at exactly start + duration is a
      // float trap: (1.2 - 1.0) / 0.2 = 0.9999999999999998 < 1.
      motion.sample(1.25); // progress >= 1
      expect(motion.opacity, closeTo(0.0, 1e-6));
      expect(motion.offset, closeTo(8.0, 1e-6));
      expect(motion.finished, isTrue);
    });

    test('reduced: duration 0 and an instant snap on show (UiMotion.cpp:109-119)', () {
      final ConfirmModalMotion motion = ConfirmModalMotion();
      motion.set(true, 0.0, true);
      expect(motion.duration, 0.0);
      expect(motion.finished, isTrue);
      expect(motion.opacity, 1.0);
      expect(motion.offset, 0.0);
    });

    test('reduced: closing from the settled state snaps to 0 / 8', () {
      final ConfirmModalMotion motion = ConfirmModalMotion();
      motion.set(true, 0.0, true);
      motion.set(false, 0.5, true);
      expect(motion.duration, 0.0);
      expect(motion.opacity, 0.0);
      expect(motion.offset, 8.0);
    });

    test('set() samples the running transition first, so a retarget continues '
        '(UiMotion.cpp:100-104)', () {
      final ConfirmModalMotion motion = ConfirmModalMotion();
      motion.set(true, 0.0);
      motion.sample(0.15);
      final double opacity = motion.opacity;
      final double offset = motion.offset;

      motion.set(false, 0.15);
      expect(motion.opacity, closeTo(opacity, 1e-12));
      expect(motion.offset, closeTo(offset, 1e-12));
      expect(motion.duration, 0.2);

      motion.sample(0.25); // 0.1s into the 0.2s exit, progress 0.5
      expect(motion.opacity, closeTo(0.64911147905659394, 1e-6));
      expect(motion.offset, closeTo(2.9114039078978493, 1e-6));

      // (0.36 - 0.15) / 0.2 = 1.05 >= 1. (0.35 - 0.15) / 0.2 is
      // 0.9999999999999999, which would leave finished false.
      motion.sample(0.36);
      expect(motion.opacity, closeTo(0.0, 1e-6));
      expect(motion.offset, closeTo(8.0, 1e-6));
      expect(motion.finished, isTrue);
    });

    test('progress is clamped: sampling before start holds the from values '
        '(UiMotion.cpp:90)', () {
      final ConfirmModalMotion motion = ConfirmModalMotion();
      motion.set(true, 10.0);
      motion.sample(9.0);
      expect(motion.opacity, closeTo(0.0, 1e-6));
      // Qt's bezier bisection runs 24 steps, so at progress 0 the curve
      // returns 8.94069644985507e-8 rather than exactly 0 (UiMotion.cpp:13-21).
      // The held from-offset is therefore 12 + (0 - 12) * 8.94e-8 =
      // 11.999998927116426, a 1.07e-6 residual -- within 1e-5, not 1e-6.
      expect(motion.offset, closeTo(12.0, 1e-5));
      expect(motion.duration, 0.3);
    });
  });
}
