// T30-S07-M12 protocol tests: command stream, hit table and frame envelope.
//
// WRITTEN BUT NOT EXECUTED. This atom forbids flutter/dart test, analyze, build
// and codegen commands, so RED/GREEN are unverified. Every expectation below was
// derived by reading the Qt source cited beside it and the decoder code.
//
// Fixtures are inline on purpose: the frozen contract plans
// test/fixtures/*.json and test/hud_protocol_test.dart (contract §6.1/§6.3),
// neither of which is inside this atom's write scope.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/protocol/hud_command.dart';
import 'package:rhine_music_database/hud/protocol/hud_frame.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';

/// The 17 op arrays in the frozen wire shape (`Qt/src/Glyphs.cpp:637-829`).
List<Object?> commandFixture() => <Object?>[
      <Object?>['save'],
      <Object?>['restore'],
      <Object?>['alpha', 0.5],
      <Object?>['translate', 10, 20],
      <Object?>['scale', 2, 3],
      <Object?>['rotate', 0.25],
      <Object?>['clip', 1, 2, 3, 4],
      <Object?>[
        'fill',
        <Object?>[0.1, 0.2, 0.3, 1.0],
        5,
        6,
        7,
        8,
      ],
      <Object?>[
        'ellipse',
        <Object?>[0.1, 0.2, 0.3],
        9,
        10,
        11,
        12,
      ],
      <Object?>[
        'text',
        'hi',
        13,
        14,
        15,
        '600',
        0.5,
        <Object?>[1, 1, 1],
      ],
      <Object?>[
        'art',
        'icons/a',
        16,
        17,
        18,
        2,
        0.25,
        <Object?>[1, 1, 1],
      ],
      <Object?>['fill-path', 'glyph/a', <Object?>[1, 0, 0]],
      <Object?>[
        'path',
        'glyph/b',
        3.0,
        <Object?>[0, 1, 0, 0.5],
        <Object?>[4, 4],
        1.5,
      ],
      <Object?>['arc', 20, 21, 22, 0.1, 0.2, 23, <Object?>[0, 0, 1]],
      <Object?>['right-mask', <Object?>[1, 1, 1], 24, 25, 26, 27],
      <Object?>['gradient', true],
      <Object?>['image', 'img/x', 28, 29, 30, 31],
    ];

/// A structurally valid local-adapter envelope.
Map<String, Object?> envelope({
  int generation = 1,
  Object? frame,
  Object? commands,
  Object? hits,
  Object? state,
}) =>
    <String, Object?>{
      'generation': generation,
      'frame': frame ??
          <String, Object?>{
            'mode': 'archive',
            'viewer': false,
            'detail': 0.0,
            'selected': 3.0,
          },
      'commands': commands ?? <Object?>[],
      'hits': hits ?? <Object?>[],
      'state': state ?? <String, Object?>{'modal': false},
    };

void main() {
  group('commands: 17 ops', () {
    test('decodes every op in order without reordering or deduplicating', () {
      final decode = decodeHudCommands(commandFixture());
      expect(decode.commands.length, 17);
      expect(decode.issues, isEmpty);
      expect(decode.hasUnknownOperations, isFalse);
      expect(decode.hasMalformedCommands, isFalse);
      expect(
        decode.commands.map((command) => command.index).toList(),
        List<int>.generate(17, (index) => index),
      );
    });

    test('keeps Qt argument positions per op', () {
      final decode = decodeHudCommands(commandFixture());

      final fill = decode.commands[7] as HudFill;
      expect(fill.color.red, 0.1);
      expect(fill.x, 5);
      expect(fill.y, 6);
      expect(fill.width, 7);
      expect(fill.height, 8);

      final text = decode.commands[9] as HudText;
      expect(text.value, 'hi');
      expect(text.size, 15);
      expect(text.weight, '600');
      expect(text.tracking, 0.5);

      final art = decode.commands[10] as HudArt;
      expect(art.key, 'icons/a');
      expect(art.count, 2);
      expect(art.tracking, 0.25);

      final path = decode.commands[12] as HudStrokePath;
      expect(path.key, 'glyph/b');
      expect(path.penWidth, 3.0);
      expect(path.color.green, 1.0);
      expect(path.dashPattern, <double>[4, 4]);
      expect(path.dashOffset, 1.5);

      final arc = decode.commands[13] as HudArc;
      expect(arc.color.blue, 1.0);
      expect(arc.penWidth, 23);

      final mask = decode.commands[14] as HudRightMask;
      expect(mask.color.red, 1.0);
      expect(mask.height, 27);

      expect((decode.commands[15] as HudGradient).dark, isTrue);
      expect((decode.commands[16] as HudImage).width, 30);
    });

    test('a repeated command is executed twice, never merged', () {
      final decode = decodeHudCommands(<Object?>[
        <Object?>['save'],
        <Object?>['save'],
      ]);
      expect(decode.commands.length, 2);
      expect(decode.issues, isEmpty);
    });

    test('unknown ops are skipped and reported, never fatal', () {
      final decode = decodeHudCommands(<Object?>[
        <Object?>['blur', 1],
        7,
        <Object?>['save'],
      ]);
      expect(decode.commands.length, 1);
      expect(decode.commands.single, isA<HudSave>());
      expect(decode.issues.length, 2);
      expect(decode.issues[0].kind, HudIssueKind.unknownOperation);
      expect(decode.issues[1].kind, HudIssueKind.nonArrayCommand);
      expect(decode.hasUnknownOperations, isTrue);
      expect(decode.hasMalformedCommands, isTrue);

      final named = decodeHudCommands(<Object?>[<Object?>[]]);
      expect(named.issues.single.kind, HudIssueKind.unknownOperation);
    });

    test('missing arguments keep Qt coercion to 0.0 and are reported', () {
      final decode = decodeHudCommands(<Object?>[
        <Object?>['translate', 5],
      ]);
      final translate = decode.commands.single as HudTranslate;
      expect(translate.x, 5);
      expect(translate.y, 0);
      expect(decode.issues.single.kind, HudIssueKind.malformedArgument);
      expect(decode.issues.single.op, 'translate');
    });
  });

  group('colors: calibrated gamma 1.8 then sRGB', () {
    test('hudCalibratedChannel applies pow(1.8) before the sRGB curve', () {
      final expected = hudSrgbEncode(math.pow(0.5, hudCalibratedGamma).toDouble());
      expect(hudCalibratedChannel(0.5), closeTo(expected, 1e-12));
      // Qt/src/Glyphs.cpp:41-44: 0.5 -> 0.5723, never the "encode only" 0.7354.
      expect(hudCalibratedChannel(0.5), closeTo(0.5723, 1e-3));
      expect(hudCalibratedChannel(0.5), isNot(closeTo(0.7354, 1e-4)));
    });

    test('hudSrgbEncode keeps the 0.0031308 linear-segment threshold', () {
      expect(hudSrgbEncode(0.001), closeTo(12.92 * 0.001, 1e-12));
      expect(
        hudSrgbEncode(0.5),
        closeTo(1.055 * math.pow(0.5, 1 / 2.4) - 0.055, 1e-12),
      );
    });

    test('only a calibrated element 4 switches the conversion on', () {
      final plain = decodeHudColor(<Object?>[0.5, 0.5, 0.5, 1.0]);
      expect(plain.red, 0.5);

      final calibrated = decodeHudColor(
        <Object?>[0.5, 0.5, 0.5, 1.0, 'calibrated-rgb'],
      );
      expect(calibrated.red, closeTo(0.5723, 1e-3));

      // Anything after the prefix word still counts as calibrated.
      final prefixed = decodeHudColor(
        <Object?>[0.5, 0.5, 0.5, 1.0, 'calibrated'],
      );
      expect(prefixed.red, closeTo(0.5723, 1e-3));
    });

    test('alpha never takes part in the gamma or sRGB step', () {
      final color = decodeHudColor(<Object?>[0.5, 0.5, 0.5, 0.5, 'calibrated']);
      expect(color.alpha, 0.5);
      expect(color.red, closeTo(0.5723, 1e-3));
    });

    test('non-array color is opaque black and now reported', () {
      final decode = decodeHudCommands(<Object?>[
        <Object?>['fill', 'nope', 1, 2, 3, 4],
      ]);
      final fill = decode.commands.single as HudFill;
      expect(fill.color.red, 0);
      expect(fill.color.green, 0);
      expect(fill.color.blue, 0);
      expect(fill.color.alpha, 1);
      expect(decode.issues.single.kind, HudIssueKind.malformedArgument);
      expect(decode.issues.single.op, 'fill');

      // An absent color keeps the same value and is still reported.
      final absent = decodeHudCommands(<Object?>[
        <Object?>['ellipse', null, null, null, null, null],
      ]);
      final ellipse = absent.commands.single as HudEllipse;
      expect(ellipse.color.alpha, 1);
      expect(absent.issues, isNotEmpty);
    });

    test('a non-numeric alpha reads as fully transparent', () {
      final color = decodeHudColor(<Object?>[1, 1, 1, 'x']);
      expect(color.alpha, 0);
      expect(color.red, 1);
    });
  });

  group('hits: six fields plus optional fixed, order, label fallback', () {
    test('decodes in delivery order and never reorders', () {
      final decode = decodeHudHits(<Object?>[
        <String, Object?>{
          'x': 1.0,
          'y': 2.0,
          'width': 3.0,
          'height': 4.0,
          'action': 'music:play',
          'label': 'Play',
        },
        <String, Object?>{
          'x': 5.0,
          'y': 6.0,
          'width': 7.0,
          'height': 8.0,
          'action': 'player:next',
          'label': null,
          'fixed': true,
        },
        <String, Object?>{
          'x': 9.0,
          'y': 10.0,
          'width': 11.0,
          'height': 12.0,
          'action': 'music:like-current',
          'label': '',
        },
      ]);
      expect(decode.issues, isEmpty);
      expect(
        decode.hits.map((hit) => hit.action).toList(),
        <String>['music:play', 'player:next', 'music:like-current'],
      );
      expect(decode.hits[0].label, 'Play');
      // Qt/src/NativeHud.cpp:108: label.isNull() ? action : label
      expect(decode.hits[1].label, 'player:next');
      // An empty QString is not null, so it survives untouched.
      expect(decode.hits[2].label, '');
      // Qt/src/PlayerBar.cpp:47-53 appends `fixed` after the six fields, and
      // Overlay.qml:191 needs it at consumption time, so the decoder retains it
      // instead of discarding wire information.
      expect(decode.hits.map((hit) => hit.fixed).toList(),
          <bool>[false, true, false]);
      expect(decode.hits[1].toJson().keys.toList(),
          <String>['x', 'y', 'width', 'height', 'action', 'label', 'fixed']);
      expect(decode.hits[1].toJson()[hudPlayerBarFixedField], isTrue);
      // An ordinary target is still exactly the six Qt fields: no
      // `fixed: false` is added.
      expect(decode.hits[0].toJson().keys.toList(),
          <String>['x', 'y', 'width', 'height', 'action', 'label']);
      expect(
          decode.hits[0].toJson().containsKey(hudPlayerBarFixedField), isFalse);
    });

    test('toJson keeps the Qt key order and only marks fixed targets', () {
      const hit = HudHit(
        x: 1,
        y: 2,
        width: 3,
        height: 4,
        action: 'a',
        label: 'l',
      );
      expect(
        hit.toJson().keys.toList(),
        <String>['x', 'y', 'width', 'height', 'action', 'label'],
      );
      const fixed = HudHit(
        x: 1,
        y: 2,
        width: 3,
        height: 4,
        action: 'a',
        label: 'l',
        fixed: true,
      );
      expect(
        fixed.toJson().keys.toList(),
        <String>['x', 'y', 'width', 'height', 'action', 'label', 'fixed'],
      );
      expect(fixed.toJson()[hudPlayerBarFixedField], isTrue);
    });

    test('a hit without the marker defaults to not fixed', () {
      final decode = decodeHudHits(<Object?>[
        <String, Object?>{
          'x': 1.0,
          'y': 2.0,
          'width': 3.0,
          'height': 4.0,
          'action': 'music:play',
          'label': 'Play',
        },
      ]);
      expect(decode.issues, isEmpty);
      expect(decode.hits.single.fixed, isFalse);
    });

    test('only a JSON true marks a hit fixed', () {
      // Qt reads the marker with QJsonValue::toBool: numbers and strings are
      // not booleans, so they fall back to false without a repair issue.
      Map<String, Object?> target(Object? marker) => <String, Object?>{
            'x': 1.0,
            'y': 2.0,
            'width': 3.0,
            'height': 4.0,
            'action': 'player:next',
            'label': 'Next',
            'fixed': marker,
          };
      final decode = decodeHudHits(<Object?>[
        target(1),
        target('true'),
        target(false),
      ]);
      expect(decode.issues, isEmpty);
      expect(decode.hits.map((hit) => hit.fixed).toList(),
          <bool>[false, false, false]);
    });

    test('same geometry with a different fixed flag is not equal', () {
      const plain = HudHit(
        x: 1,
        y: 2,
        width: 3,
        height: 4,
        action: 'player:next',
        label: 'Next',
      );
      const fixed = HudHit(
        x: 1,
        y: 2,
        width: 3,
        height: 4,
        action: 'player:next',
        label: 'Next',
        fixed: true,
      );
      expect(plain, isNot(fixed));
      // hashCode follows equality: an identical hit with the same flag still
      // agrees, so the field is part of the value, not object identity.
      const samePlain = HudHit(
        x: 1,
        y: 2,
        width: 3,
        height: 4,
        action: 'player:next',
        label: 'Next',
      );
      expect(samePlain, plain);
      expect(samePlain.hashCode, plain.hashCode);
    });

    test('a full publish round trip keeps the player-bar flag', () {
      final first = decodeHudHits(<Object?>[
        <String, Object?>{
          'x': 1.0,
          'y': 2.0,
          'width': 3.0,
          'height': 4.0,
          'action': 'player:play',
          'label': 'Play',
          'fixed': true,
        },
      ]);
      // Re-serializing every decoded hit is what a full frame re-publish does;
      // the flag must survive, not just the six required fields.
      final republished = first.hits.map((hit) => hit.toJson()).toList();
      final second = decodeHudHits(republished);
      expect(second.issues, isEmpty);
      expect(second.hits.single.fixed, isTrue);
      expect(second.hits.single, first.hits.single);
    });

    test('modal offset skips fixed targets, matching T32 hit_layer.dart:112',
        () {
      // T32 lib/hud/input/hit_layer.dart:112:
      // hit.y + ((modal.isNotEmpty && !hit.fixed) ? modalOffset : 0.0)
      double offsetY(HudHit hit, bool modalOpen, double modalOffset) =>
          hit.y + ((modalOpen && !hit.fixed) ? modalOffset : 0.0);
      const plain = HudHit(
        x: 0,
        y: 10,
        width: 1,
        height: 1,
        action: 'music:play',
        label: 'Play',
      );
      const fixed = HudHit(
        x: 0,
        y: 10,
        width: 1,
        height: 1,
        action: 'player:next',
        label: 'Next',
        fixed: true,
      );
      expect(offsetY(plain, true, 64), 74);
      expect(offsetY(fixed, true, 64), 10);
      expect(offsetY(plain, false, 64), 10);
    });

    test('appendHudPlayerBarFixed appends the flag last without mutating', () {
      const hit = HudHit(
        x: 1,
        y: 2,
        width: 3,
        height: 4,
        action: 'music:like-current',
        label: 'l',
      );
      final Map<String, Object?> six = hit.toJson();
      final Map<String, Object?> fixed = appendHudPlayerBarFixed(six);
      expect(
        fixed.keys.toList(),
        <String>['x', 'y', 'width', 'height', 'action', 'label', 'fixed'],
      );
      expect(fixed['fixed'], isTrue);
      // the six-field map is copied, never mutated in place
      expect(six.length, 6);
      expect(six.containsKey(hudPlayerBarFixedField), isFalse);
      // Qt/src/PlayerBar.cpp:170: a player-bar target with a music: action -
      // the flag comes from the producer, never from the action prefix.
      expect(fixed['action'], 'music:like-current');
    });

    test('appendHudPlayerBarFixed is idempotent', () {
      final Map<String, Object?> fixed = appendHudPlayerBarFixed(
        <String, Object?>{
          'x': 1.0,
          'y': 2.0,
          'width': 3.0,
          'height': 4.0,
          'action': 'player:next',
          'label': 'Next',
        },
      );
      expect(appendHudPlayerBarFixed(fixed), same(fixed));
      expect(fixed['fixed'], isTrue);
    });

    test('breaks geometry, action and label exactly like Qt would', () {
      final decode = decodeHudHits(<Object?>[
        <String, Object?>{'x': 1, 'y': 2, 'width': 3, 'action': 'a'},
        <String, Object?>{
          'x': 1,
          'y': 2,
          'width': 3,
          'height': 4,
          'action': 5,
        },
        'nope',
        <String, Object?>{
          'x': 1,
          'y': 2,
          'width': 3,
          'height': 4,
          'action': 'ok',
          'label': 7,
        },
      ]);
      expect(decode.hits.length, 1);
      expect(decode.hits.single.label, 'ok');
      expect(decode.issues.length, 4);
      expect(decode.issues[0].dropped, isTrue);
      expect(decode.issues[1].dropped, isTrue);
      expect(decode.issues[2].dropped, isTrue);
      expect(decode.issues[3].dropped, isFalse);
      expect(decode.issues[3].index, 3);
      expect(decode.hasDroppedHits, isTrue);
    });
  });

  group('frame: 33 delivered keys', () {
    test('delivered keys are the 31 literals plus the two survivors', () {
      expect(hudQtLiteralFrameKeys.length, 31);
      expect(hudQtFrameKeysAddedAfterLiterals.length, 4);
      expect(hudQtFrameKeysRemovedByCardsExpand, <String>['actorTemplate', 'actors']);
      expect(hudDeliveredFrameKeys.length, 33);
      expect(
        hudDeliveredFrameKeys,
        <String>[...hudQtLiteralFrameKeys, 'appearanceRevision', 'stats'],
      );
      expect(hudDeliveredFrameKeys.contains('actorTemplate'), isFalse);
      expect(hudDeliveredFrameKeys.contains('actors'), isFalse);
      expect(hudDeliveredFrameKeys.toSet().length, 33);
    });

    test('generation stays a local-adapter field, never a Qt frame key', () {
      expect(hudLocalAdapterFrameEnvelopeFields, <String>[
        'generation',
        'frame',
        'commands',
        'hits',
        'state',
      ]);
      expect(hudDeliveredFrameKeys.contains('generation'), isFalse);
      expect(hudQtLiteralFrameKeys.contains('generation'), isFalse);
      expect(hudQtFrameKeysAddedAfterLiterals.contains('generation'), isFalse);
    });

    test('HudFrameView types only the keys the HUD actually reads', () {
      final view = HudFrameView(<String, Object?>{
        'mode': 'detail',
        'viewer': true,
        'detail': 0.75,
        'selected': 2,
        'boot': <String, Object?>{'logo': 1.0},
        'extra': 1,
      });
      expect(view.mode, 'detail');
      expect(view.viewer, isTrue);
      expect(view.detail, 0.75);
      expect(view.selected, 2.0);
      // Qt/src/NativeHudBoot.cpp:156 reads this with toObject().
      expect(view.boot, <String, Object?>{'logo': 1.0});
      expect(view.unexpectedKeys, <String>['extra']);

      // Contract §4.1 types boot as a number; Qt's toObject() would read an
      // empty object, so a scalar must not be exposed as a motion object.
      expect(HudFrameView(<String, Object?>{'boot': 1.0}).boot, isNull);

      const empty = HudFrameView(<String, Object?>{});
      expect(empty.mode, '');
      expect(empty.viewer, isFalse);
      expect(empty.detail, 0.0);
      expect(empty.selected, 0.0);
      expect(empty.boot, isNull);
      expect(empty.unexpectedKeys, isEmpty);
    });
  });

  group('envelope: decode and gate', () {
    test('decodes the local adapter envelope', () {
      final decoded = HudFrameEnvelope.decode(envelope(generation: 7));
      expect(decoded.generation, 7);
      expect(decoded.frame.mode, 'archive');
      expect(decoded.commands.commands, isEmpty);
      expect(decoded.hits.hits, isEmpty);
      expect(decoded.state['modal'], isFalse);
      expect(() => decoded.state['modal'] = true, throwsUnsupportedError);
    });

    test('rejects a snapshot that is missing or mistyping an envelope field',
        () {
      expect(
        () => HudFrameEnvelope.decode(<String, Object?>{
          'frame': <String, Object?>{},
          'commands': <Object?>[],
          'hits': <Object?>[],
          'state': <String, Object?>{},
        }),
        throwsA(isA<HudProtocolException>()),
      );
      expect(
        () => HudFrameEnvelope.decode(envelope(generation: -1)),
        throwsA(isA<HudProtocolException>()),
      );
      expect(
        () => HudFrameEnvelope.decode(<String, Object?>{
          'generation': '7',
          'frame': <String, Object?>{},
          'commands': <Object?>[],
          'hits': <Object?>[],
          'state': <String, Object?>{},
        }),
        throwsA(isA<HudProtocolException>()),
      );
      expect(
        () => HudFrameEnvelope.decode(envelope(frame: <Object?>[])),
        throwsA(isA<HudProtocolException>()),
      );
      expect(
        () => HudFrameEnvelope.decode(envelope(commands: <String, Object?>{})),
        throwsA(isA<HudProtocolException>()),
      );
      expect(
        () => HudFrameEnvelope.decode(envelope(hits: <String, Object?>{})),
        throwsA(isA<HudProtocolException>()),
      );
      expect(
        () => HudFrameEnvelope.decode(envelope(state: <Object?>[])),
        throwsA(isA<HudProtocolException>()),
      );
    });

    test('the gate drops a snapshot whole unless it is strictly newer', () {
      final gate = HudFrameGate();
      expect(gate.appliedGeneration, isNull);
      expect(gate.markApplied(HudFrameEnvelope.decode(envelope(generation: 3))), isTrue);
      expect(gate.appliedGeneration, 3);
      expect(
        gate.markApplied(HudFrameEnvelope.decode(envelope(generation: 3))),
        isFalse,
      );
      expect(
        gate.markApplied(HudFrameEnvelope.decode(envelope(generation: 2))),
        isFalse,
      );
      expect(gate.appliedGeneration, 3);
      expect(gate.markApplied(HudFrameEnvelope.decode(envelope(generation: 4))), isTrue);
      expect(gate.appliedGeneration, 4);
    });
  });

  group('stage geometry', () {
    test('matches the Qt stage formulas', () {
      final base = HudStage.fromLogicalSize(width: 1920, height: 1080);
      expect(base.scale, 1.0);
      expect(base.width, 1920.0);
      expect(base.height, 1080.0);

      final shortSide = HudStage.fromLogicalSize(width: 1280, height: 720);
      expect(shortSide.scale, closeTo(720 / 1080, 1e-12));
      expect(shortSide.width, closeTo(1920, 1e-9));
      expect(shortSide.height, closeTo(1080, 1e-9));

      // Qt/qml/Overlay.qml:22 falls back to scale 1 for a zero height, while the
      // engine path (Qt/src/Engine.cpp:1353) falls back to width 1920 instead.
      final flat = HudStage.fromLogicalSize(width: 800, height: 0);
      expect(flat.scale, 1.0);
      expect(flat.width, 800.0);
      expect(HudStage.engineHudWidth(width: 800, height: 0), 1920.0);
      expect(HudStage.engineHudWidth(width: 1280, height: 720), closeTo(1920, 1e-9));
    });
  });

  // ---------------------------------------------------------------------
  // Defensive decoding: the fix for review finding F1 (a color array shorter
  // than three channels used to escape `decodeHudCommands` as a `RangeError`,
  // which `HudFrameEnvelope.decode` does not catch because it absorbs only
  // `TypeError`, aborting a whole frame). Qt reads channels through
  // `QJsonArray::at` behind `size()` checks (Qt/src/Glyphs.cpp:35-49), so the
  // wire may legally carry 0, 1 or 2 channels; every degenerate argument must
  // keep Qt's coercion and be reported (F2), and no known op may abort.
  // ---------------------------------------------------------------------
  group('defensive decoding keeps Qt coercion and reports it', () {
    test('a color array shorter than three channels reads the rest as 0.0', () {
      final empty = decodeHudColor(const <Object?>[]);
      expect(empty.red, 0);
      expect(empty.green, 0);
      expect(empty.blue, 0);
      expect(empty.alpha, 1);

      final one = decodeHudColor(<Object?>[0.25]);
      expect(one.red, 0.25);
      expect(one.green, 0);
      expect(one.blue, 0);
      expect(one.alpha, 1);

      final two = decodeHudColor(<Object?>[0.25, 0.5]);
      expect(two.red, 0.25);
      expect(two.green, 0.5);
      expect(two.blue, 0);
      expect(two.alpha, 1);
    });

    test('a short color argument is reported and stays opaque black', () {
      final decode = decodeHudCommands(<Object?>[
        <Object?>['fill', <Object?>[], 1.0, 0.5, 0.5, 0.5],
      ]);
      expect(decode.issues, hasLength(1));
      expect(decode.issues.single.kind, HudIssueKind.malformedArgument);
      expect(decode.issues.single.op, 'fill');
      expect(decode.hasMalformedCommands, isTrue);

      final fill = decode.commands.single as HudFill;
      expect(fill.index, 0);
      expect(fill.color.red, 0);
      expect(fill.color.green, 0);
      expect(fill.color.blue, 0);
      expect(fill.color.alpha, 1);
    });

    test('a partial color keeps the channels it has and is reported once', () {
      final decode = decodeHudCommands(<Object?>[
        <Object?>['fill', <Object?>[0.25, 0.5], 1.0, 0.5, 0.5, 0.5],
      ]);
      expect(decode.issues, hasLength(1));
      final fill = decode.commands.single as HudFill;
      expect(fill.color.red, 0.25);
      expect(fill.color.green, 0.5);
      expect(fill.color.blue, 0);
      expect(fill.color.alpha, 1);
    });

    test('a short calibrated color still converts only the channels it has', () {
      final decode = decodeHudCommands(<Object?>[
        <Object?>['fill', <Object?>[0.5, 0.5], 1.0, 0.0, 0.0, 1.0],
      ]);
      final fill = decode.commands.single as HudFill;
      // Element 4 is the calibration marker; two channels means it is absent,
      // so the value stays linear (Qt/src/Glyphs.cpp:41-44).
      expect(fill.color.red, 0.5);
      expect(fill.color.blue, 0);
      expect(decode.issues, hasLength(1));
    });

    test('a mistyped gradient flag reads false and is reported', () {
      final decode = decodeHudCommands(<Object?>[
        <Object?>['gradient', 'yes'],
      ]);
      final gradient = decode.commands.single as HudGradient;
      expect(gradient.dark, isFalse);
      expect(decode.issues.single.kind, HudIssueKind.malformedArgument);
      expect(decode.issues.single.op, 'gradient');
      expect(decode.issues.single.detail, contains('Qt reads it as false'));
    });

    test('a mistyped art count reads as -1 (whole string) and is reported', () {
      final decode = decodeHudCommands(<Object?>[
        <Object?>['art', 'static.clock', 10.0, 20.0, 30.0, '2', 0.0, <Object?>[1, 1, 1, 1]],
      ]);
      final art = decode.commands.single as HudArt;
      expect(art.count, -1);
      expect(decode.issues.single.kind, HudIssueKind.malformedArgument);
      expect(decode.issues.single.op, 'art');
      expect(decode.issues.single.detail, contains('Qt reads it as -1'));
    });

    test('a non-list dash argument draws solid and is reported', () {
      final decode = decodeHudCommands(<Object?>[
        <Object?>['path', 'bar.fill', 3.0, <Object?>[1, 1, 1, 1], 'nope'],
      ]);
      final path = decode.commands.single as HudStrokePath;
      expect(path.dashPattern, isEmpty);
      expect(path.dashOffset, isNull);
      expect(decode.issues.single.kind, HudIssueKind.malformedArgument);
      expect(decode.issues.single.op, 'path');
    });

    test('a mistyped dash offset keeps null and is reported', () {
      final decode = decodeHudCommands(<Object?>[
        <Object?>[
          'path', 'bar.fill', 3.0, <Object?>[1, 1, 1, 1], <Object?>[4, 4], 'x',
        ],
      ]);
      final path = decode.commands.single as HudStrokePath;
      expect(path.dashPattern, <double>[4, 4]);
      expect(path.dashOffset, isNull);
      expect(decode.issues.single.kind, HudIssueKind.malformedArgument);
      expect(decode.issues.single.op, 'path');
    });

    test('the fully typed 17-op fixture still reports nothing', () {
      // Guards the F2 widening: a well typed optional argument must not be
      // reported, otherwise the default-path assertions at the top of this
      // file (commands group) would break.
      final decode = decodeHudCommands(commandFixture());
      expect(decode.commands, hasLength(17));
      expect(decode.issues, isEmpty);
      expect(decode.hasMalformedCommands, isFalse);
      expect(decode.hasUnknownOperations, isFalse);
    });
  });
}
