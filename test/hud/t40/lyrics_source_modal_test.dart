// Written but NOT executed: the writer task forbids running flutter/dart test,
// analyze or build. Intended command:
//   flutter test test/hud/t40/lyrics_source_modal_test.dart
//
// Every expected number below is copied from, or computed exactly as, the Qt
// source cited next to it; none is read back from the Dart implementation.

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/lyrics_source_modal.dart';

/// Deterministic stand-in for Qt `Glyphs::width` (Qt/src/Glyphs.cpp:286):
/// one UTF-16 code unit measures `size`, tracking adds `tracking` per unit.
double _measure(String text, double size, String? weight, double tracking) =>
    text.length * size + tracking * text.length;

/// A measurement that never fits, to prove every row label goes through the
/// injected `fit` binary search instead of a hardcoded advance.
double _huge(String text, double size, String? weight, double tracking) => 1e9;

// Qt/src/NativeHud.cpp:11-14.
const List<Object?> _darkInk = <Object?>[0.92, 0.92, 0.92, 1.0, 'calibratedWhite'];
const List<Object?> _lightInk = <Object?>[0.08, 0.085, 0.075, 1.0, 'calibratedRGB'];

// Qt/src/NativeHudModal.cpp:146.
const List<Object?> _darkPanel = <Object?>[0.15, 0.15, 0.15, 1.0, 'calibratedWhite'];
const List<Object?> _lightPanel = <Object?>[0.929, 0.922, 0.894, 1.0];

// Qt/src/NativeHud.cpp:116.
const List<Object?> _lightTint = <Object?>[0.44, 0.49, 0.36, 0.1];

LyricsSourceModal _modal({
  double width = 1920.0,
  bool dark = true,
  double opacity = 1.0,
  double offset = 0.0,
  String localSource = 'auto',
  LyricsSourceMeasureText? measureText,
}) =>
    LyricsSourceModal(
      width: width,
      dark: dark,
      opacity: opacity,
      offset: offset,
      localSource: localSource,
      measureText: measureText ?? _measure,
    );

List<String> _textValues(LyricsSourceModalFrame frame) => frame.commands
    .where((List<Object?> command) => command[0] == 'text')
    .map((List<Object?> command) => command[1]! as String)
    .toList();

List<Object?> _textCommand(
  LyricsSourceModalFrame frame,
  String value,
) =>
    frame.commands.firstWhere((List<Object?> command) =>
        command[0] == 'text' && command[1] == value);

void main() {
  group('lyrics source popover: frame skeleton', () {
    test('draw order is save, alpha, translate, panel, five rows … restore '
        '(NativeHudModal.cpp:83-84, :144-146, :158-159)', () {
      final LyricsSourceModalFrame frame = _modal().build();
      // save, alpha, translate, panel fill, five (fill, text) row pairs,
      // restore; the hit rows live in frame.hits, not in the command stream.
      expect(frame.commands.length, 15);
      expect(frame.commands.first, <Object?>['save']);
      expect(frame.commands[1], <Object?>['alpha', 1.0]);
      expect(frame.commands[2], <Object?>['translate', 0.0, 0.0]);
      expect(frame.commands[3], <Object?>[
        'fill',
        _darkPanel,
        1920.0 * 0.56 + 156,
        674.0,
        232.0,
        232.0,
      ]);
      expect(frame.commands.last, <Object?>['restore']);
    });

    test('no scrim and no outside catcher: only five row hits '
        '(NativeHudModal.cpp:147-148)', () {
      final LyricsSourceModalFrame frame = _modal().build();
      expect(frame.hits.length, 5);
      final double panelX = 1920.0 * 0.56 + 156;
      for (final List<Object?> hit in frame.hits) {
        expect(hit.length, 6);
        final double x = hit[0]! as double;
        final double y = hit[1]! as double;
        final double w = hit[2]! as double;
        final double h = hit[3]! as double;
        expect(x, greaterThanOrEqualTo(panelX + 10));
        expect(y, greaterThanOrEqualTo(674.0 + 11));
        expect(x + w, lessThanOrEqualTo(panelX + 10 + 212));
        expect(y + h, lessThanOrEqualTo(674.0 + 11 + 5 * 42));
      }
    });
  });

  group('lyrics source popover: hit table', () {
    test('five rows in sources order with exact Qt rects, actions and labels '
        '(NativeHudModal.cpp:149-157)', () {
      final LyricsSourceModalFrame frame = _modal(localSource: 'auto').build();
      final double rowX = 1920.0 * 0.56 + 156 + 10;
      expect(frame.hits, <List<Object?>>[
        <Object?>[rowX, 685.0, 212.0, 42.0, 'player:lyrics-source:auto', '✓ 自动（本地优先）'],
        <Object?>[rowX, 727.0, 212.0, 42.0, 'player:lyrics-source:local', '本地歌词'],
        <Object?>[rowX, 769.0, 212.0, 42.0, 'player:lyrics-source:netease', '网易云音乐'],
        <Object?>[rowX, 811.0, 212.0, 42.0, 'player:lyrics-source:qq', 'QQ 音乐'],
        <Object?>[rowX, 853.0, 212.0, 42.0, 'player:lyrics-source:kugou', '酷狗音乐'],
      ]);
    });

    test('only the exactly equal localSource gets the check prefix '
        '(NativeHudModal.cpp:152-154)', () {
      final LyricsSourceModalFrame frame = _modal(localSource: 'qq').build();
      expect(_textValues(frame), <String>[
        '自动（本地优先）',
        '本地歌词',
        '网易云音乐',
        '✓ QQ 音乐',
        '酷狗音乐',
      ]);
      expect(frame.hits[3][5], '✓ QQ 音乐');
      expect(frame.hits[0][5], '自动（本地优先）');
    });

    test('a source id outside the five rows never changes the rendered set', () {
      final LyricsSourceModalFrame frame = _modal(localSource: 'bogus').build();
      expect(frame.hits.map((List<Object?> hit) => hit[4]), <String>[
        'player:lyrics-source:auto',
        'player:lyrics-source:local',
        'player:lyrics-source:netease',
        'player:lyrics-source:qq',
        'player:lyrics-source:kugou',
      ]);
      expect(_textValues(frame).any((String value) => value.startsWith('✓ ')), isFalse);
    });
  });

  group('lyrics source popover: injected measurement and theme', () {
    test('every row label is truncated through the injected measure '
        '(NativeHud.cpp:48-76, :118)', () {
      final LyricsSourceModalFrame frame = _modal(measureText: _huge).build();
      expect(_textValues(frame), <String>['…', '…', '…', '…', '…']);
    });

    test('light theme uses the plain panel fill and calibrated RGB ink '
        '(NativeHudModal.cpp:146, NativeHud.cpp:11-14)', () {
      final LyricsSourceModalFrame frame = _modal(dark: false).build();
      expect(frame.commands[3], <Object?>[
        'fill',
        _lightPanel,
        1920.0 * 0.56 + 156,
        674.0,
        232.0,
        232.0,
      ]);
      // First row fill + text, NativeHud.cpp:116 and :118.
      expect(frame.commands[4], <Object?>[
        'fill',
        _lightTint,
        1920.0 * 0.56 + 156 + 10,
        685.0,
        212.0,
        42.0,
      ]);
      expect(_textCommand(frame, '✓ 自动（本地优先）')[7], _lightInk);
    });
  });

  group('lyrics source popover: geometry scales with width', () {
    test('panel x follows width * 0.56 + 156 (NativeHud.cpp:145-148)', () {
      final LyricsSourceModalFrame frame = _modal(width: 2400).build();
      final List<Object?> fill = frame.commands[3];
      expect(fill[2], 2400.0 * 0.56 + 156);
      expect(fill[3], 674.0);
      expect(fill[4], 232.0);
      expect(fill[5], 232.0);
      expect(frame.hits.first[0], 2400.0 * 0.56 + 156 + 10);
    });
  });
}
