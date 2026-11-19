// Static spec tests for the slice runner (T10-R01 / T10-T01).
//
// These tests are pure Dart + flutter_test: no external process, no device and
// no real capture. They are not executed by T02 (this atom may not run
// build/test/analyze); they exist so the executor contract is pinned by code.
//
// Not executed here: the runner CLI itself is only invoked through runCli with
// in-memory sinks, and fixture/capture inputs are built from literals or the
// read-only fixture file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/parity/slice_runner.dart';

const String fixturePath = 'test/fixtures/slice_cases.json';

String fixtureText() {
  final file = File(fixturePath);
  if (!file.existsSync()) {
    fail('missing fixture: $fixturePath');
  }
  return file.readAsString();
}

Map<String, Object?> fixtureJson() =>
    Map<String, Object?>.from(jsonDecode(fixtureText()) as Map);

Map<String, Object?> deepCopy(Map<String, Object?> value) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);

SliceFixture loadFixtureForTest() =>
    parseFixture(fixtureJson(), sourcePath: fixturePath);

SliceError sliceErrorOf(void Function() body, String what) {
  try {
    body();
  } catch (error) {
    if (error is SliceError) {
      return error;
    }
    fail('$what: expected SliceError, got ${error.runtimeType}');
  }
  fail('$what: expected SliceError, but the call returned normally');
}

Map<String, Object?> unitJson({
  String candidate = 'A',
  String step = 'S1',
  int unit = 0,
  Object? commands,
  Object? hits,
  Object? frame,
  Object? state,
  Object? generation = 1,
  Object? commandsGeneration,
  Object? hitsGeneration,
  Object? frameGeneration,
  Object? stateGeneration,
}) {
  final map = <String, Object?>{
    'schema': 'slice-unit/v1',
    'candidate': candidate,
    'step': step,
    'unit': unit,
    'tMonotonicMs': 1000 + unit,
    'wallClock': '2026-11-11T10:00:00Z',
    'commands': commands ?? <Object?>[],
    'hits': hits ?? <Object?>[],
    'frame': frame ?? <String, Object?>{},
    'state': state ?? <String, Object?>{'route': 'library'},
    'generation': generation,
  };
  if (commandsGeneration != null) {
    map['commandsGeneration'] = commandsGeneration;
  }
  if (hitsGeneration != null) {
    map['hitsGeneration'] = hitsGeneration;
  }
  if (frameGeneration != null) {
    map['frameGeneration'] = frameGeneration;
  }
  if (stateGeneration != null) {
    map['stateGeneration'] = stateGeneration;
  }
  return map;
}

String jsonl(List<Map<String, Object?>> units) =>
    '${units.map(jsonEncode).join('\n')}\n';

CandidateCapture captureOf(
  SliceFixture fixture,
  String candidateId,
  List<Map<String, Object?>> units,
) =>
    buildCandidateCapture(
      fixture: fixture,
      candidateId: candidateId,
      sources: <CaptureSource>[CaptureSource('memory.jsonl', jsonl(units))],
    );

void main() {
  group('fixture/oneSliceRule', () {
    test('read-only fixture parses and keeps its sampling contract', () {
      final fixture = loadFixtureForTest();
      expect(fixture.schema, 'slice-cases/v1');
      expect(fixture.candidates.length, 5);
      expect(fixture.steps.length, 10);
      expect(fixture.rois.length, 38);
      expect(fixture.checks.length, 21);
      expect(fixture.thresholds.length, 7);
      expect(fixture.capture.minUnitsPerStep, 3);
      expect(fixture.requiredUnits('S1'), 3);
      expect(fixture.requiredUnits('S2'), 4);
      expect(fixture.frozenTolerance('th.stage.metric'), isNotNull);
      expect(fixture.frozenTolerance('th.hit.rect'), isNull);
      expect(fixture.frozenTolerance('th.perf.fps'), isNull);
    });

    test('candidate carrying steps is rejected', () {
      final json = deepCopy(fixtureJson());
      final candidates = json['candidates']! as List<Object?>;
      final candidate = candidates.first! as Map<String, Object?>;
      candidate['steps'] = <Object?>[];
      final error = sliceErrorOf(
        () => parseFixture(json, sourcePath: fixturePath),
        'candidate.steps',
      );
      expect(error.code, 'oneSliceRule.candidateForbiddenField');
      expect(error.message.contains('steps'), isTrue);
    });

    test('every forbidden candidate field is rejected', () {
      const forbidden = <String>[
        'rois',
        'checks',
        'thresholds',
        'unmeasured',
        'overrides',
        'tolerance',
      ];
      for (final field in forbidden) {
        final json = deepCopy(fixtureJson());
        final candidates = json['candidates']! as List<Object?>;
        final candidate = candidates.first! as Map<String, Object?>;
        candidate[field] = <Object?>[];
        final error = sliceErrorOf(
          () => parseFixture(json, sourcePath: fixturePath),
          'candidate.$field',
        );
        expect(error.code, 'oneSliceRule.candidateForbiddenField');
      }
    });

    test('candidate with an undeclared field is rejected', () {
      final json = deepCopy(fixtureJson());
      final candidates = json['candidates']! as List<Object?>;
      final candidate = candidates.first! as Map<String, Object?>;
      candidate['score'] = 0.5;
      final error = sliceErrorOf(
        () => parseFixture(json, sourcePath: fixturePath),
        'candidate.score',
      );
      expect(error.code, 'oneSliceRule.candidateUnknownField');
    });

    test('oneSliceRule.allowedCandidateFields must stay complete', () {
      final json = deepCopy(fixtureJson());
      final rule = json['oneSliceRule']! as Map<String, Object?>;
      rule['allowedCandidateFields'] = <Object?>['id', 'name'];
      final error = sliceErrorOf(
        () => parseFixture(json, sourcePath: fixturePath),
        'allowedCandidateFields',
      );
      expect(error.code, 'oneSliceRule.allowedMismatch');
    });
  });

  group('CLI criteria gate', () {
    test('threshold flags are rejected by the parser', () {
      for (final flag in <String>['--threshold', '--tolerance', '--ssim']) {
        final error = sliceErrorOf(
          () => parseInvocation(<String>[
            'compare',
            '--fixture',
            fixturePath,
            '--capture',
            'A=unit.jsonl',
            flag,
            '0.5',
          ]),
          flag,
        );
        expect(error.code, 'cli.thresholdOverride');
      }
      final inline = sliceErrorOf(
        () => parseInvocation(<String>[
          'compare',
          '--fixture',
          fixturePath,
          '--capture',
          'A=unit.jsonl',
          '--threshold=0.5',
        ]),
        '--threshold=0.5',
      );
      expect(inline.code, 'cli.thresholdOverride');
    });

    test('criteria flags are rejected by the parser', () {
      for (final flag in <String>['--steps', '--rois', '--checks', '--global-score']) {
        final error = sliceErrorOf(
          () => parseInvocation(<String>[
            'compare',
            '--fixture',
            fixturePath,
            '--capture',
            'A=unit.jsonl',
            flag,
            'S1',
          ]),
          flag,
        );
        expect(error.code, 'cli.criteriaOverride');
      }
    });

    test('runCli exits 3 on a threshold override and never reads the fixture', () {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = runCli(
        <String>[
          'compare',
          '--fixture',
          'missing-fixture.json',
          '--capture',
          'A=missing.jsonl',
          '--threshold',
          '0.99',
        ],
        out: out,
        err: err,
      );
      expect(code, 3);
      expect(err.toString().contains('cli.thresholdOverride'), isTrue);
      expect(out.toString(), isEmpty);
    });

    test('export refuses capture and manifest flags', () {
      final withCapture = sliceErrorOf(
        () => parseInvocation(<String>[
          'export',
          '--fixture',
          fixturePath,
          '--capture',
          'A=unit.jsonl',
        ]),
        'export --capture',
      );
      expect(withCapture.code, 'cli.flagNotAllowed');
      final withManifest = sliceErrorOf(
        () => parseInvocation(<String>[
          'export',
          '--fixture',
          fixturePath,
          '--roi-manifest',
          'roi.json',
        ]),
        'export --roi-manifest',
      );
      expect(withManifest.code, 'cli.flagNotAllowed');
    });

    test('capture flag needs candidate=path', () {
      final error = sliceErrorOf(
        () => parseInvocation(<String>[
          'compare',
          '--fixture',
          fixturePath,
          '--capture',
          'unit.jsonl',
        ]),
        '--capture',
      );
      expect(error.code, 'cli.captureFormat');
    });
  });

  group('ordered token equality', () {
    test('commands order is never normalized', () {
      final diff = firstTokenDifference(
        <Object?>['player:toggle', 'player:next'],
        <Object?>['player:next', 'player:toggle'],
      );
      expect(diff, isNotNull);
      expect(diff!.kind, 'value');
    });

    test('duplicate tokens are never removed', () {
      final diff = firstTokenDifference(
        <Object?>['player:toggle', 'player:toggle'],
        <Object?>['player:toggle'],
      );
      expect(diff, isNotNull);
      expect(diff!.kind, 'length');
    });

    test('identical payloads compare equal regardless of object key order', () {
      expect(
        tokenEquals(<Object?>{'a': 1, 'b': 2}, <Object?>{'b': 2, 'a': 1}),
        isTrue,
      );
      expect(
        tokenEquals(<Object?>['x', 'y'], <Object?>['x', 'y']),
        isTrue,
      );
    });

    test('numbers stay type-strict and missing keys are differences', () {
      final numberDiff = firstTokenDifference(<Object?>[1], <Object?>[1.0]);
      expect(numberDiff, isNotNull);
      expect(numberDiff!.kind, 'numberType');
      final missing = firstTokenDifference(
        <Object?>[<Object?>{'x': 1}],
        <Object?>[<Object?>{'x': 1, 'fixed': true}],
      );
      expect(missing, isNotNull);
      expect(missing!.kind, 'missingLeft');
    });

    test('frame comparison uses the frozen absolute tolerance only', () {
      final ok = firstFrameDifference(
        <String, Object?>{'a': 1.00000001},
        <String, Object?>{'a': 1.0},
        1e-9,
      );
      expect(ok, isNotNull);
      expect(ok!.kind, 'tolerance');
      final same = firstFrameDifference(
        <String, Object?>{'a': 1.0},
        <String, Object?>{'a': 1.0},
        1e-9,
      );
      expect(same, isNull);
      final structural = firstFrameDifference(
        <String, Object?>{'a': 1.0},
        <String, Object?>{'a': 1.0, 'b': 2.0},
        1e-9,
      );
      expect(structural, isNotNull);
      expect(structural!.kind, 'missingLeft');
    });
  });

  group('generation coherence', () {
    test('a mismatched hits generation discards the whole snapshot', () {
      final fixture = loadFixtureForTest();
      final units = parseUnitsJsonl(
        jsonl(<Map<String, Object?>>[
          unitJson(unit: 0),
          unitJson(unit: 1, hitsGeneration: 2),
        ]),
        source: 'memory.jsonl',
      );
      final discards = <UnitDiscard>[];
      final kept = dropIncoherentUnits(units, discards: discards);
      expect(units.length, 2);
      expect(kept.length, 1);
      expect(kept.single.unitIndex, 0);
      expect(discards.length, 1);
      expect(discards.single.code, 'unit.generationMismatch');
      expect(discards.single.unit.unitIndex, 1);

      final capture = captureOf(fixture, 'A', <Map<String, Object?>>[
        unitJson(unit: 0),
        unitJson(unit: 1, hitsGeneration: 2),
      ]);
      expect(capture.unitCountFor('S1'), 1);
      expect(capture.recordCountFor('S1'), 1);
      expect(capture.records, 1);
      expect(capture.discardsFor('S1').length, 1);
    });

    test('coherent component stamps survive', () {
      final units = parseUnitsJsonl(
        jsonl(<Map<String, Object?>>[
          unitJson(
            unit: 0,
            commandsGeneration: 7,
            hitsGeneration: 7,
            frameGeneration: 7,
            stateGeneration: 7,
            generation: 7,
          ),
        ]),
        source: 'memory.jsonl',
      );
      final discards = <UnitDiscard>[];
      final kept = dropIncoherentUnits(units, discards: discards);
      expect(kept.length, 1);
      expect(discards, isEmpty);
    });
  });

  group('sampling gates', () {
    test('S2 needs one extra unit on top of minUnitsPerStep', () {
      final fixture = loadFixtureForTest();
      final candidate = fixture.candidateById('A')!;
      final step = fixture.stepById('S2')!;
      final capture = captureOf(fixture, 'A', <Map<String, Object?>>[
        unitJson(step: 'S2', unit: 0),
        unitJson(step: 'S2', unit: 1),
        unitJson(step: 'S2', unit: 2),
      ]);
      final evaluation = evaluateStep(
        fixture: fixture,
        candidate: candidate,
        step: step,
        capture: capture,
        manifest: RoiManifest.empty(),
      );
      expect(evaluation.requiredUnits, 4);
      expect(evaluation.unitCount, 3);
      expect(evaluation.verdict, SliceVerdict.unmeasured);
      expect(
        evaluation.reasons.any((reason) => reason.contains('采样不足')),
        isTrue,
      );
    });

    test('three S1 units clear the sampling gate', () {
      final fixture = loadFixtureForTest();
      final candidate = fixture.candidateById('A')!;
      final step = fixture.stepById('S1')!;
      final capture = captureOf(fixture, 'A', <Map<String, Object?>>[
        unitJson(step: 'S1', unit: 0),
        unitJson(step: 'S1', unit: 1),
        unitJson(step: 'S1', unit: 2),
      ]);
      final evaluation = evaluateStep(
        fixture: fixture,
        candidate: candidate,
        step: step,
        capture: capture,
        manifest: RoiManifest.empty(),
      );
      expect(evaluation.unitCount, 3);
      expect(evaluation.recordCount, 3);
      expect(
        evaluation.reasons.any((reason) => reason.contains('采样不足')),
        isFalse,
      );
    });

    test('no capture at all is UNMEASURED, never PASS', () {
      final fixture = loadFixtureForTest();
      final candidate = fixture.candidateById('A')!;
      final step = fixture.stepById('S0')!;
      final evaluation = evaluateStep(
        fixture: fixture,
        candidate: candidate,
        step: step,
        capture: buildCandidateCapture(
          fixture: fixture,
          candidateId: 'A',
          sources: const <CaptureSource>[],
        ),
        manifest: RoiManifest.empty(),
      );
      expect(evaluation.verdict, SliceVerdict.unmeasured);
      expect(evaluation.reasons, isNotEmpty);
    });
  });

  group('per-ROI evaluation', () {
    StageRect rectOf(SliceRoi roi) => roi.rect;

    test('missing rect is UNMEASURED for layout ROIs', () {
      final fixture = loadFixtureForTest();
      final step = fixture.stepById('S1')!;
      final roi = fixture.roiById('roi.nav.bar')!;
      final evaluation = evaluateRoi(
        fixture: fixture,
        step: step,
        roi: roi,
        manifestStep: null,
        units: const <SliceUnit>[],
      );
      expect(evaluation.verdict, SliceVerdict.unmeasured);
      expect(evaluation.notes.join(' ').contains('UNMEASURED'), isTrue);
    });

    test('matching rect passes with the frozen stage metric', () {
      final fixture = loadFixtureForTest();
      final step = fixture.stepById('S1')!;
      final roi = fixture.roiById('roi.nav.bar')!;
      final manifestStep = StepRoiManifest(
        present: const <String>['roi.nav.bar'],
        rects: <String, StageRect>{'roi.nav.bar': rectOf(roi)},
        conditions: const <String, RoiCondition>{},
        stage: const <String, num>{},
      );
      final evaluation = evaluateRoi(
        fixture: fixture,
        step: step,
        roi: roi,
        manifestStep: manifestStep,
        units: const <SliceUnit>[],
      );
      expect(evaluation.verdict, SliceVerdict.pass);
      expect(evaluation.toleranceThresholdId, 'th.stage.metric');
      expect(evaluation.delta, 0);
    });

    test('conditional ROI without a recorded condition is UNMEASURED', () {
      final fixture = loadFixtureForTest();
      final step = fixture.stepById('S1')!;
      final roi = fixture.roiById('roi.player.seek')!;
      final manifestStep = StepRoiManifest(
        present: const <String>[],
        rects: <String, StageRect>{'roi.player.seek': rectOf(roi)},
        conditions: const <String, RoiCondition>{},
        stage: const <String, num>{},
      );
      final evaluation = evaluateRoi(
        fixture: fixture,
        step: step,
        roi: roi,
        manifestStep: manifestStep,
        units: const <SliceUnit>[],
      );
      expect(evaluation.verdict, SliceVerdict.unmeasured);
    });

    test('conditional ROI with holds=false is NOT_APPLICABLE', () {
      final fixture = loadFixtureForTest();
      final step = fixture.stepById('S1')!;
      final roi = fixture.roiById('roi.player.seek')!;
      final manifestStep = StepRoiManifest(
        present: const <String>[],
        rects: <String, StageRect>{'roi.player.seek': rectOf(roi)},
        conditions: <String, RoiCondition>{
          'roi.player.seek': const RoiCondition(
            holds: false,
            values: <String, Object?>{'durationMs': 0},
          ),
        },
        stage: const <String, num>{},
      );
      final evaluation = evaluateRoi(
        fixture: fixture,
        step: step,
        roi: roi,
        manifestStep: manifestStep,
        units: const <SliceUnit>[],
      );
      expect(evaluation.verdict, SliceVerdict.notApplicable);
    });

    test('every ROI of a step is reported individually', () {
      final fixture = loadFixtureForTest();
      final candidate = fixture.candidateById('A')!;
      final step = fixture.stepById('S2')!;
      final capture = captureOf(fixture, 'A', <Map<String, Object?>>[
        unitJson(step: 'S2', unit: 0),
        unitJson(step: 'S2', unit: 1),
        unitJson(step: 'S2', unit: 2),
        unitJson(step: 'S2', unit: 3),
      ]);
      final evaluation = evaluateStep(
        fixture: fixture,
        candidate: candidate,
        step: step,
        capture: capture,
        manifest: RoiManifest.empty(),
      );
      expect(evaluation.rois.length, step.roiIds.length);
      final json = evaluation.toJson();
      final verdicts = json['roiVerdicts']! as Map<String, Object?>;
      expect(verdicts.length, step.roiIds.length);
      expect(verdicts.keys.toSet(), step.roiIds.toSet());
      expect(json.containsKey('score'), isFalse);
      expect(json.containsKey('globalScore'), isFalse);
    });

    test('roi manifest refuses aggregate scores and unknown keys', () {
      final score = sliceErrorOf(
        () => parseRoiManifest(<String, Object?>{
          'schema': 'slice-roi-manifest/v1',
          'candidate': 'A',
          'steps': <String, Object?>{
            'S1': <String, Object?>{'score': 0.97},
          },
        }),
        'manifest score',
      );
      expect(score.code, 'roiManifest.aggregateScore');
      final unknown = sliceErrorOf(
        () => parseRoiManifest(<String, Object?>{
          'schema': 'slice-roi-manifest/v1',
          'bogus': true,
        }),
        'manifest unknown key',
      );
      expect(unknown.code, 'roiManifest.unknownKey');
    });
  });

  group('equivalence and report', () {
    test('command order difference between candidates is a FAIL', () {
      final fixture = loadFixtureForTest();
      final a = captureOf(fixture, 'A', <Map<String, Object?>>[
        unitJson(
          step: 'S1',
          unit: 0,
          commands: <Object?>['player:toggle', 'player:next'],
        ),
      ]);
      final b = captureOf(fixture, 'B', <Map<String, Object?>>[
        unitJson(
          step: 'S1',
          unit: 0,
          commands: <Object?>['player:next', 'player:toggle'],
        ),
      ]);
      final report = evaluateEquivalence(
        fixture,
        <String, CandidateCapture>{'A': a, 'B': b},
        const <String>['A', 'B'],
      );
      expect(report.reference, 'A');
      final s1 = report.steps.firstWhere((step) => step.stepId == 'S1');
      expect(s1.commandsDiffs, 1);
      expect(s1.verdict, SliceVerdict.fail);
      expect(report.verdict, SliceVerdict.fail);
    });

    test('state divergence skips the token comparison', () {
      final fixture = loadFixtureForTest();
      final a = captureOf(fixture, 'A', <Map<String, Object?>>[
        unitJson(step: 'S1', unit: 0, state: <String, Object?>{
          'route': 'library',
          'generation': 1,
        }),
      ]);
      final b = captureOf(fixture, 'B', <Map<String, Object?>>[
        unitJson(step: 'S1', unit: 0, state: <String, Object?>{
          'route': 'library',
          'generation': 2,
        }),
      ]);
      final report = evaluateEquivalence(
        fixture,
        <String, CandidateCapture>{'A': a, 'B': b},
        const <String>['A', 'B'],
      );
      final s1 = report.steps.firstWhere((step) => step.stepId == 'S1');
      expect(s1.stateDivergences, 1);
      expect(s1.pairs, 0);
      expect(s1.verdict, SliceVerdict.unmeasured);
    });

    test('report exposes per-ROI verdicts and no global score', () {
      final fixture = loadFixtureForTest();
      final report = compareCaptures(
        fixture,
        <String, List<CaptureSource>>{
          'A': <CaptureSource>[
            CaptureSource('memory.jsonl', jsonl(<Map<String, Object?>>[
              unitJson(step: 'S1', unit: 0),
              unitJson(step: 'S1', unit: 1),
              unitJson(step: 'S1', unit: 2),
            ])),
          ],
        },
        fixturePath: fixturePath,
      );
      final json = report.toJson();
      expect(json['schema'], 'slice-report/v1');
      expect(json['verdict'], 'UNMEASURED');
      expect(json['exitCode'], 2);
      final encoded = jsonEncode(json);
      expect(encoded.contains('"globalScore"'), isFalse);
      expect(encoded.contains('"score"'), isFalse);
      final steps = json['steps']! as List<Object?>;
      expect(steps.length, 10);
      final s1 = steps[1]! as Map<String, Object?>;
      expect(s1['step'], 'S1');
      expect((s1['rois']! as List<Object?>).length, 15);
    });
  });

  group('export', () {
    test('export carries fixture criteria and never accepts overrides', () {
      final fixture = loadFixtureForTest();
      final report = buildExportReport(fixture, fixturePath: fixturePath);
      expect(report['schema'], 'slice-export/v1');
      expect(report['mode'], 'export');
      final criteria = report['criteria']! as Map<String, Object?>;
      expect(criteria['thresholdOverridesAccepted'], isFalse);
      expect(criteria['builtInDefaultThresholds'], isFalse);
      expect(criteria['globalScore'], isFalse);
      expect(criteria['perRoiVerdicts'], isTrue);
      final steps = report['steps']! as List<Object?>;
      expect(steps.length, 10);
      final s2 = steps[2]! as Map<String, Object?>;
      expect(s2['id'], 'S2');
      expect(s2['requiredUnits'], 4);
      expect((s2['rois']! as List<Object?>).length, 21);
      final rule = report['oneSliceRule']! as Map<String, Object?>;
      expect(
        (rule['forbiddenCandidateFields']! as List<Object?>).contains('steps'),
        isTrue,
      );
    });

    test('runCli export writes normalized JSON to the sink', () {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = runCli(
        <String>['export', '--fixture', fixturePath],
        out: out,
        err: err,
      );
      expect(code, 0);
      expect(err.toString(), isEmpty);
      final decoded =
          Map<String, Object?>.from(jsonDecode(out.toString()) as Map);
      expect(decoded['schema'], 'slice-export/v1');
    });

    test('runCli compare returns the verdict exit code', () {
      final fixture = loadFixtureForTest();
      final directory = Directory.systemTemp.createTempSync('slice_spec');
      addTearDown(() => directory.deleteSync(recursive: true));
      final captureFile = File('${directory.path}/A-S1.jsonl');
      captureFile.writeAsStringSync(jsonl(<Map<String, Object?>>[
        unitJson(step: 'S1', unit: 0),
        unitJson(step: 'S1', unit: 1),
        unitJson(step: 'S1', unit: 2),
      ]));
      final out = StringBuffer();
      final err = StringBuffer();
      final code = runCli(
        <String>[
          'compare',
          '--fixture',
          fixturePath,
          '--capture',
          'A=${captureFile.path}',
        ],
        out: out,
        err: err,
      );
      expect(err.toString(), isEmpty);
      expect(code, 2);
      final decoded =
          Map<String, Object?>.from(jsonDecode(out.toString()) as Map);
      expect(decoded['verdict'], 'UNMEASURED');
      expect(decoded['candidates'], <Object?>['A']);
      expect(fixture.candidates.length, 5);
    });

    test('verdict exit codes are fixed', () {
      expect(SliceVerdict.pass.exitCode, 0);
      expect(SliceVerdict.fail.exitCode, 1);
      expect(SliceVerdict.unmeasured.exitCode, 2);
      expect(SliceVerdict.notApplicable.exitCode, 2);
    });
  });
}
