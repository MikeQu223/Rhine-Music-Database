// Written but NOT executed: the writer task forbids running flutter/dart test,
// analyze or build. Intended command:
//   flutter test test/hud/t40/lyrics_modal_host_test.dart
//
// The host is checked against the Qt dispatch table
// (Qt/src/NativeHudController.cpp:324-345) and the offset arithmetic in
// Qt/src/LyricsController.cpp:511-544; the panel wiring test re-paints the same
// model with and without the sink to prove the hit/command streams are
// unchanged.

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/lyrics_modal_host.dart';
import 'package:rhine_music_database/hud/modals/lyrics_offset_modal.dart';
import 'package:rhine_music_database/hud/modals/lyrics_panel.dart';

/// Deterministic stand-in for Qt `Glyphs::width` (Qt/src/Glyphs.cpp:286).
double _measure(String text, double size, String? weight, double tracking) =>
    text.length * size + tracking * text.length;

LyricsPanelModel _model({
  double offsetMs = 0.0,
  double globalOffsetMs = 0.0,
  bool isLocal = true,
  String provider = 'local',
  String localSource = 'auto',
  bool dark = true,
  double width = 800.0,
}) =>
    LyricsPanelModel(
      width: width,
      offsetMs: offsetMs,
      globalOffsetMs: globalOffsetMs,
      isLocal: isLocal,
      provider: provider,
      localSource: localSource,
      dark: dark,
    );

LyricsModalHost _host({
  LyricsPanelModel? model,
  void Function(LyricsSourceSelection selection)? onSourceSelected,
}) =>
    LyricsModalHost(
      model: model ?? _model(),
      stageWidth: 1920.0,
      measureText: _measure,
      onSourceSelected: onSourceSelected,
    );

LyricOffsetChange _change(LyricsModalResult? result) {
  expect(result, isA<LyricOffsetChange>());
  return result! as LyricOffsetChange;
}

void main() {
  group('modal host: opening and closing', () {
    test('lyrics-offset toggles the popover and returns no domain change '
        '(NativeHudController.cpp:324-328)', () {
      final LyricsModalHost host = _host();
      expect(host.handleAction(LyricsModalHost.actionOffset), isNull);
      expect(host.openAction, 'lyrics-offset');
      final LyricsModalFrame open = host.build();
      expect(open.openAction, 'lyrics-offset');
      expect(
        open.hits.map((List<Object?> hit) => hit[4]),
        contains('player:lyrics-earlier'),
      );

      expect(host.handleAction(LyricsModalHost.actionOffset), isNull);
      expect(host.openAction, isNull);
      final LyricsModalFrame closed = host.build();
      expect(closed.isOpen, isFalse);
      expect(closed.commands, isEmpty);
      expect(closed.hits, isEmpty);
    });

    test('lyrics-sources is gated by isLocal && provider == local '
        '(NativeHudController.cpp:336-341)', () {
      final LyricsModalHost notLocal =
          _host(model: _model(isLocal: false, provider: 'local'));
      expect(notLocal.handleAction(LyricsModalHost.actionSources), isNull);
      expect(notLocal.openAction, isNull);

      final LyricsModalHost localProvider =
          _host(model: _model(isLocal: true, provider: 'netease'));
      expect(localProvider.handleAction(LyricsModalHost.actionSources), isNull);
      expect(localProvider.openAction, isNull);

      final LyricsModalHost allowed = _host();
      expect(allowed.handleAction(LyricsModalHost.actionSources), isNull);
      expect(allowed.openAction, 'lyrics-source');
      expect(allowed.build().hits.length, 5);
    });

    test('close clears the open popover immediately', () {
      final LyricsModalHost host = _host();
      host.handleAction(LyricsModalHost.actionSources);
      expect(host.build().isOpen, isTrue);
      host.close();
      expect(host.openAction, isNull);
      expect(host.build().isOpen, isFalse);
      expect(host.build().commands, isEmpty);
    });

    test('close-modal also clears, and is a no-op while closed', () {
      final LyricsModalHost host = _host();
      expect(host.handleAction('close-modal'), isNull);
      host.handleAction(LyricsModalHost.actionOffset);
      expect(host.handleAction('close-modal'), isNull);
      expect(host.openAction, isNull);
    });
  });

  group('modal host: offset arithmetic', () {
    test('earlier is +200 ms, later is -200 ms, the model is never mutated '
        '(NativeHudController.cpp:330-331)', () {
      final LyricsModalHost host = _host(model: _model(offsetMs: 800.0));
      host.handleAction(LyricsModalHost.actionOffset);

      final LyricOffsetChange earlier = _change(
        host.handleAction('player:lyrics-earlier'),
      );
      expect(earlier.action, 'player:lyrics-earlier');
      expect(earlier.deltaMs, 200.0);
      expect(earlier.newOffset, 1000.0);
      expect(earlier.global, isFalse);
      expect(host.model.offsetMs, 800.0);

      final LyricOffsetChange later = _change(
        host.handleAction('player:lyrics-later'),
      );
      expect(later.action, 'player:lyrics-later');
      expect(later.deltaMs, -200.0);
      expect(later.newOffset, 600.0);
      expect(later.global, isFalse);
      expect(host.model.offsetMs, 800.0);
    });

    test('the suggestion equality is value based', () {
      final LyricsModalHost host = _host(model: _model(offsetMs: 800.0));
      host.handleAction(LyricsModalHost.actionOffset);
      expect(
        host.handleAction('player:lyrics-earlier'),
        const LyricOffsetChange(
          action: 'player:lyrics-earlier',
          deltaMs: 200.0,
          newOffset: 1000.0,
          global: false,
        ),
      );
    });

    test('clamps to +/-10000 at both ends '
        '(LyricsController.cpp:511-518)', () {
      for (final (double start, String action, double expected) in <(double, String, double)>[
        (9900.0, 'player:lyrics-earlier', 10000.0),
        (10000.0, 'player:lyrics-earlier', 10000.0),
        (-9900.0, 'player:lyrics-later', -10000.0),
        (-10000.0, 'player:lyrics-later', -10000.0),
      ]) {
        final LyricsModalHost host = _host(model: _model(offsetMs: start));
        host.handleAction(LyricsModalHost.actionOffset);
        final LyricOffsetChange change = _change(host.handleAction(action));
        expect(change.deltaMs, action == 'player:lyrics-earlier' ? 200.0 : -200.0);
        expect(change.newOffset, expected);
      }
    });

    test('reset suggests 0 and is a no-op at 0 '
        '(LyricsController.cpp:521-531)', () {
      final LyricsModalHost host = _host(model: _model(offsetMs: 800.0));
      host.handleAction(LyricsModalHost.actionOffset);
      final LyricOffsetChange reset = _change(host.handleAction('player:lyrics-reset'));
      expect(reset.deltaMs, -800.0);
      expect(reset.newOffset, 0.0);
      expect(reset.global, isFalse);
      expect(host.model.offsetMs, 800.0);

      host.model = _model(offsetMs: 0.0);
      expect(host.handleAction('player:lyrics-reset'), isNull);
    });

    test('apply-global suggests the current track offset and is a no-op when '
        'it already equals the global one (LyricsController.cpp:534-544)', () {
      final LyricsModalHost host = _host(model: _model(offsetMs: 800.0));
      host.handleAction(LyricsModalHost.actionOffset);
      final LyricOffsetChange applied = _change(
        host.handleAction('player:lyrics-apply-global'),
      );
      expect(applied.action, 'player:lyrics-apply-global');
      expect(applied.deltaMs, 0.0);
      expect(applied.newOffset, 800.0);
      expect(applied.global, isTrue);

      host.model = _model(offsetMs: 800.0, globalOffsetMs: 800.0);
      expect(host.handleAction('player:lyrics-apply-global'), isNull);
    });

    test('offset actions are only owned by the open offset popover', () {
      final LyricsModalHost host = _host(model: _model(offsetMs: 800.0));
      for (final String action in <String>[
        'player:lyrics-earlier',
        'player:lyrics-later',
        'player:lyrics-reset',
        'player:lyrics-apply-global',
      ]) {
        expect(host.handleAction(action), isNull);
      }
      host.handleAction(LyricsModalHost.actionSources);
      expect(host.handleAction('player:lyrics-earlier'), isNull);
      expect(host.openAction, 'lyrics-source');
    });
  });

  group('modal host: frames', () {
    test('offset frame delegates stage width, theme and offsets exactly', () {
      final LyricsModalHost host =
          _host(model: _model(offsetMs: 800.0, dark: true));
      host.handleAction(LyricsModalHost.actionOffset);
      final LyricsModalFrame frame = host.build();
      final LyricsOffsetModalFrame expected = LyricsOffsetModal(
        LyricsOffsetModalState(
          width: 1920.0,
          opacity: 1.0,
          offset: 0.0,
          offsetMs: 800.0,
          globalOffsetMs: 0.0,
          measureText: _measure,
          dark: true,
        ),
      ).build();
      expect(frame.commands, expected.commands);
      expect(frame.hits, expected.hits);
      // The host uses stageWidth (1920), not LyricsPanelModel.width (800).
      expect(frame.commands[3][2], 1920.0 * 0.56);
    });

    test('source frame forwards localSource, opacity and motion offset', () {
      final LyricsPanelModel model = _model(localSource: 'netease');
      final LyricsModalHost host = _host(model: model);
      host.opacity = 0.6;
      host.offset = 4.0;
      host.handleAction(LyricsModalHost.actionSources);
      final LyricsModalFrame frame = host.build();
      expect(frame.openAction, 'lyrics-source');
      expect(frame.commands[1], <Object?>['alpha', 0.6]);
      expect(frame.commands[2], <Object?>['translate', 0.0, 4.0]);
      // Row 3 (index 2) is the selected netease row (NativeHudModal.cpp:152).
      expect(frame.hits[2][5], '✓ 网易云音乐');
    });
  });

  group('modal host: source selection', () {
    test('a row closes the popover, calls back, and reports the raw id '
        '(NativeHudController.cpp:342-345)', () {
      final List<LyricsSourceSelection> picked = <LyricsSourceSelection>[];
      String? openDuringCallback;
      late LyricsModalHost host;
      host = _host(
        onSourceSelected: (LyricsSourceSelection selection) {
          openDuringCallback = host.openAction;
          picked.add(selection);
        },
      );
      host.handleAction(LyricsModalHost.actionSources);
      final LyricsModalResult? result = host.handleAction('player:lyrics-source:qq');
      expect(result, isA<LyricsSourceSelection>());
      expect((result! as LyricsSourceSelection).source, 'qq');
      expect(picked.single.source, 'qq');
      expect(openDuringCallback, isNull);
      expect(host.openAction, isNull);
      expect(host.build().isOpen, isFalse);
    });

    test('unknown ids and a missing id are passed through unvalidated '
        '(LyricsController.cpp:232-238)', () {
      final LyricsModalHost host = _host();
      host.handleAction(LyricsModalHost.actionSources);
      final LyricsSourceSelection unknown =
          host.handleAction('player:lyrics-source:bogus')! as LyricsSourceSelection;
      expect(unknown.source, 'bogus');

      host.handleAction(LyricsModalHost.actionSources);
      final LyricsSourceSelection missing =
          host.handleAction('player:lyrics-source')! as LyricsSourceSelection;
      expect(missing.source, '');
      expect(host.openAction, isNull);
    });

    test('selection is ignored while the offset popover is open', () {
      final List<LyricsSourceSelection> picked = <LyricsSourceSelection>[];
      final LyricsModalHost host = _host(onSourceSelected: picked.add);
      host.handleAction(LyricsModalHost.actionOffset);
      expect(host.handleAction('player:lyrics-source:qq'), isNull);
      expect(picked, isEmpty);
      expect(host.openAction, 'lyrics-offset');
    });
  });

  group('panel wiring', () {
    test('the sink receives exactly the two popover actions in draw order and '
        'does not change the frame', () {
      const GlyphsPort glyphs = _Glyphs();
      final LyricsPanelModel model = LyricsPanelModel(
        width: 800.0,
        document: <String, Object?>{
          'lines': <Map<String, Object?>>[
            <String, Object?>{'startMs': 0, 'text': '第一行', 'translation': ''},
          ],
          'plainText': '',
        },
        index: 0,
        status: 'ready',
        isLocal: true,
        provider: 'local',
        localSource: 'auto',
        dark: true,
        frameTime: 1.0,
      );
      final List<String> sink = <String>[];
      final LyricsPanelDrawing withSink =
          paintLyricsPanel(model, glyphs, onAction: sink.add);
      final LyricsPanelDrawing withoutSink = paintLyricsPanel(model, glyphs);
      expect(sink, <String>['player:lyrics-sources', 'player:lyrics-offset']);
      expect(withSink.commands, withoutSink.commands);
      expect(withSink.hits, withoutSink.hits);
    });

    test('the sources action stays silent when the button is not drawn', () {
      const GlyphsPort glyphs = _Glyphs();
      final LyricsPanelModel model = LyricsPanelModel(
        width: 800.0,
        document: <String, Object?>{
          'lines': <Map<String, Object?>>[
            <String, Object?>{'startMs': 0, 'text': '第一行', 'translation': ''},
          ],
          'plainText': '',
        },
        index: 0,
        status: 'ready',
        isLocal: true,
        provider: 'netease',
        frameTime: 1.0,
      );
      final List<String> sink = <String>[];
      paintLyricsPanel(model, glyphs, onAction: sink.add);
      expect(sink, <String>['player:lyrics-offset']);
    });

    test('LyricsPanelModel carries globalOffsetMs through copyWith', () {
      expect(_model().globalOffsetMs, 0.0);
      final LyricsPanelModel copied = _model(offsetMs: 300.0)
          .copyWith(globalOffsetMs: -450.0, offsetMs: 600.0);
      expect(copied.globalOffsetMs, -450.0);
      expect(copied.offsetMs, 600.0);
    });
  });
}

class _Glyphs implements GlyphsPort {
  const _Glyphs();

  @override
  double width(String value, double size, String weight) => value.length * size;

  @override
  List<String> wrap(String value, double limit, double size, String weight) =>
      <String>[value];
}
