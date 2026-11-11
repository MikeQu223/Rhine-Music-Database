// Written but NOT executed: the writer task forbids running flutter/dart test,
// analyze or build. Intended command:
//   flutter test test/hud/t40/lyrics_offset_modal_test.dart
//
// Every expected number below is copied from, or computed exactly as, the Qt
// source cited next to it; none is read back from the Dart implementation.

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/lyrics_offset_modal.dart';

/// Deterministic stand-in for Qt `Glyphs::width` (Qt/src/Glyphs.cpp:286):
/// one UTF-16 code unit measures `size`, tracking adds `tracking` per unit.
double _measure(String text, double size, String? weight, double tracking) =>
    text.length * size + tracking * text.length;

/// A measurement that never fits, to prove every button label goes through the
/// injected `fit` binary search instead of a hardcoded advance.
double _huge(String text, double size, String? weight, double tracking) => 1e9;

// Qt/src/NativeHud.cpp:11-14.
const List<Object?> _darkInk = <Object?>[0.92, 0.92, 0.92, 1.0, 'calibratedWhite'];
const List<Object?> _lightInk = <Object?>[0.08, 0.085, 0.075, 1.0, 'calibratedRGB'];

// Qt/src/NativeHudModal.cpp:91-92.
const List<Object?> _darkPanel = <Object?>[0.15, 0.15, 0.15, 1.0, 'calibratedWhite'];
const List<Object?> _lightPanel = <Object?>[0.929, 0.922, 0.894, 1.0];

// Qt/src/NativeHud.cpp:116.
const List<Object?> _lightTint = <Object?>[0.44, 0.49, 0.36, 0.1];

LyricsOffsetModal _modal({
  double width = 1920.0,
  bool dark = true,
  double opacity = 1.0,
  double offset = 0.0,
  double offsetMs = 800.0,
  double globalOffsetMs = 0.0,
  LyricsOffsetMeasureText? measureText,
}) =>
    LyricsOffsetModal(
      LyricsOffsetModalState(
        width: width,
        opacity: opacity,
        offset: offset,
        offsetMs: offsetMs,
        globalOffsetMs: globalOffsetMs,
        measureText: measureText ?? _measure,
        dark: dark,
      ),
    );

List<String> _textValues(LyricsOffsetModalFrame frame) => frame.commands
    .where((List<Object?> command) => command[0] == 'text')
    .map((List<Object?> command) => command[1]! as String)
    .toList();

List<Object?> _textCommand(
  LyricsOffsetModalFrame frame,
  String value,
) =>
    frame.commands.firstWhere((List<Object?> command) =>
        command[0] == 'text' && command[1] == value);

void main() {
  group('lyrics offset popover: frame skeleton', () {
    test('draw order is save, alpha, translate, panel, header … restore '
        '(NativeHudModal.cpp:83-94, :119)', () {
      final LyricsOffsetModalFrame frame = _modal().build();
      // save, alpha, translate, fill, header text, five button fills +
      // labels, the offset label, restore. Hit rows live in frame.hits, not in
      // the command stream.
      expect(frame.commands.length, 17);
      expect(frame.commands.first, <Object?>['save']);
      expect(frame.commands[1], <Object?>['alpha', 1.0]);
      expect(frame.commands[2], <Object?>['translate', 0.0, 0.0]);
      expect(frame.commands[3], <Object?>[
        'fill',
        _darkPanel,
        1920.0 * 0.56,
        690.0,
        320.0,
        216.0,
      ]);
      expect(frame.commands.last, <Object?>['restore']);
    });

    test('header and offset label sit at bounds.x+16, y+18 / y+58 '
        '(NativeHudModal.cpp:87-88, :95, :97-103)', () {
      final LyricsOffsetModalFrame frame = _modal(offsetMs: 800).build();
      final double contentX = 1920.0 * 0.56 + 16;
      expect(
        _textCommand(frame, '歌词偏移'),
        <Object?>['text', '歌词偏移', contentX, 708.0, 17.0, 'demibold', 0.0, _darkInk],
      );
      expect(
        _textCommand(frame, '已提前 0.8s'),
        <Object?>['text', '已提前 0.8s', contentX, 748.0, 15.0, 'regular', 0.0, _darkInk],
      );
    });
  });

  group('lyrics offset popover: hit table', () {
    test('five controls with exact Qt rects and action strings '
        '(NativeHudModal.cpp:96, :104-117)', () {
      final LyricsOffsetModalFrame frame = _modal(offsetMs: 800).build();
      final double contentX = 1920.0 * 0.56 + 16;
      expect(frame.hits, <List<Object?>>[
        <Object?>[contentX + 232, 698.0, 56.0, 36.0, 'close-modal', '关闭'],
        <Object?>[contentX, 782.0, 138.0, 40.0, 'player:lyrics-earlier', '歌词提前 0.2s'],
        <Object?>[contentX + 150, 782.0, 138.0, 40.0, 'player:lyrics-later', '歌词延后 0.2s'],
        <Object?>[contentX, 842.0, 138.0, 40.0, 'player:lyrics-reset', '重置'],
        <Object?>[contentX + 150, 842.0, 138.0, 40.0, 'player:lyrics-apply-global', '全局应用'],
      ]);
    });

    test('reset/apply-global collapse to muted text when they would be no-ops '
        '(NativeHudModal.cpp:106-117)', () {
      final LyricsOffsetModalFrame frame =
          _modal(offsetMs: 0, globalOffsetMs: 0, dark: false).build();
      expect(frame.hits, <List<Object?>>[
        <Object?>[1920.0 * 0.56 + 16 + 232, 698.0, 56.0, 36.0, 'close-modal', '关闭'],
        <Object?>[1920.0 * 0.56 + 16, 782.0, 138.0, 40.0, 'player:lyrics-earlier', '歌词提前 0.2s'],
        <Object?>[1920.0 * 0.56 + 16 + 150, 782.0, 138.0, 40.0, 'player:lyrics-later', '歌词延后 0.2s'],
      ]);
      expect(frame.commands.length, 15);
      final List<Object?> muted = <Object?>[
        0.08,
        0.085,
        0.075,
        0.45,
        'calibratedRGB',
      ];
      expect(
        _textCommand(frame, '重置'),
        <Object?>['text', '重置', 1920.0 * 0.56 + 16, 851.0, 13.0, 'regular', 0.0, muted],
      );
      expect(
        _textCommand(frame, '全局应用'),
        <Object?>[
          'text',
          '全局应用',
          1920.0 * 0.56 + 16 + 150,
          851.0,
          13.0,
          'regular',
          0.0,
          muted,
        ],
      );
    });

    test('no scrim catcher: every hit is a control inside the panel (:93)', () {
      final LyricsOffsetModalFrame frame = _modal().build();
      final double panelX = 1920.0 * 0.56;
      expect(frame.hits.length, 5);
      for (final List<Object?> hit in frame.hits) {
        expect(hit.length, 6);
        final double x = hit[0]! as double;
        final double y = hit[1]! as double;
        final double w = hit[2]! as double;
        final double h = hit[3]! as double;
        expect(x, greaterThanOrEqualTo(panelX));
        expect(y, greaterThanOrEqualTo(690.0));
        expect(x + w, lessThanOrEqualTo(panelX + 320.0));
        expect(y + h, lessThanOrEqualTo(690.0 + 216.0));
      }
    });
  });

  group('lyrics offset popover: offset label', () {
    test('positive, negative and zero labels use one decimal '
        '(NativeHudModal.cpp:97-103)', () {
      expect(_textValues(_modal(offsetMs: 1200).build()), contains('已提前 1.2s'));
      expect(_textValues(_modal(offsetMs: -1200).build()), contains('已延后 1.2s'));
      expect(_textValues(_modal(offsetMs: 0).build()), contains('未校准'));
    });
  });

  group('lyrics offset popover: injected measurement and theme', () {
    test('every button label is truncated through the injected measure '
        '(NativeHud.cpp:48-76, :118)', () {
      final LyricsOffsetModalFrame frame = _modal(measureText: _huge).build();
      final int ellipses =
          _textValues(frame).where((String value) => value == '…').length;
      // close, earlier, later, reset, apply-global.
      expect(ellipses, 5);
      expect(_textValues(frame), contains('歌词偏移'));
    });

    test('light theme uses the plain panel fill and calibrated RGB ink '
        '(NativeHudModal.cpp:91-92, NativeHud.cpp:11-14)', () {
      final LyricsOffsetModalFrame frame = _modal(dark: false).build();
      expect(frame.commands[3], <Object?>[
        'fill',
        _lightPanel,
        1920.0 * 0.56,
        690.0,
        320.0,
        216.0,
      ]);
      expect(_textCommand(frame, '歌词偏移')[7], _lightInk);
      // NativeHud.cpp:116 tint is the modal-control fill.
      expect(frame.commands[5], <Object?>[
        'fill',
        _lightTint,
        1920.0 * 0.56 + 16 + 232,
        698.0,
        56.0,
        36.0,
      ]);
    });
  });

  group('lyrics offset popover: geometry scales with width', () {
    test('panel x follows width * 0.56 (NativeHud.cpp:149-152)', () {
      final LyricsOffsetModalFrame frame = _modal(width: 2400).build();
      final List<Object?> fill = frame.commands[3];
      expect(fill[2], 2400.0 * 0.56);
      expect(fill[3], 690.0);
      expect(frame.hits.first[0], 2400.0 * 0.56 + 16 + 232);
    });
  });
}
