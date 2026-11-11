// Static contract tests for lib/app/rotation_continuity.dart.
//
// These tests are written against test/fixtures/rotation_state.json but are
// never executed by T44-82 (flutter/dart test is forbidden in this tree). They
// are part of the source deliverable and must stay pure Dart + flutter_test.
//
// The fixture is synthetic and explicitly not device evidence; it only pins
// the value-state contract that a real rotation must carry.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/app/orientation_state.dart';
import 'package:rhine_music_database/app/rotation_continuity.dart';

late Map<String, Object?> fx;

Map<String, Object?> asMap(Object? value) {
  if (value is Map) return Map<String, Object?>.from(value);
  return <String, Object?>{};
}

List<Map<String, Object?>> asTracks(Object? value) {
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  if (value is! List) return out;
  for (final Object? item in value) {
    if (item is Map) out.add(Map<String, Object?>.from(item));
  }
  return out;
}

Map<String, Object?> copyJson(Object? value) =>
    asMap(jsonDecode(jsonEncode(value)));

double d(Object? value) => value is num ? value.toDouble() : 0;

int i(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;

Map<String, Object?> part(String key) => asMap(fx[key]);

QrLoginContinuity seededLogin() {
  final Map<String, Object?> seed = asMap(part('qr')['seed']);
  final int now = i(seed['nowMs']);
  final QrLoginContinuity login = QrLoginContinuity(
    provider: fx['provider'] as String? ?? 'netease',
    nowMs: now,
    lifetimeMs: i(seed['lifetimeMs'], QrValidityWindow.kQrPollBudgetMs),
  );
  final int token = login.beginPrepare(now);
  expect(login.acceptKey(token, seed['key'] as String), isTrue);
  expect(login.acceptImage(token, seed['image'] as String), isTrue);
  login.markWaiting(token, scannerName: seed['scannerName'] as String);
  return login;
}

void applyLyricsSeed(LyricsContinuity lyrics) {
  final Map<String, Object?> seed = asMap(part('lyrics')['seed']);
  lyrics.document = asMap(seed['document']);
  lyrics.status = seed['status'] as String? ?? 'idle';
  lyrics.message = seed['message'] as String? ?? '';
  lyrics.key = seed['key'] as String? ?? '';
  lyrics.index = i(seed['index'], -1);
  lyrics.offsetMs = d(seed['offsetMs']);
  lyrics.positionMs = d(seed['positionMs']);
  lyrics.globalOffsetMs = d(seed['globalOffsetMs']);
  lyrics.localSource = seed['localSource'] as String? ?? 'auto';
  lyrics.lyricsMode = seed['lyricsMode'] == true;
  lyrics.playingTrack = seed['playingTrack'] == null
      ? null
      : asMap(seed['playingTrack']);
}

void applySceneSeed(SceneContinuity scene) {
  final Map<String, Object?> seed = asMap(part('scene')['seed']);
  scene.clock = d(seed['clock']);
  scene.last = d(seed['clock']);
  scene.bootStart = d(seed['bootStart']);
  scene.detail = d(seed['detail']);
  scene.targetDetail = d(seed['targetDetail']);
  scene.rotation = d(seed['rotation']);
  scene.targetRotation = d(seed['targetRotation']);
  scene.scanTime = d(seed['scanTime']);
  scene.scanBlend = d(seed['scanBlend']);
  scene.selected = i(seed['selected']);
  scene.mode = seed['mode'] as String? ?? 'boot';
  scene.reveal = d(seed['reveal']);
  scene.targetReveal = d(seed['targetReveal']);
  scene.looping = seed['looping'] == true;
  scene.navigating = seed['navigating'] == true;
  scene.lastInteraction = d(seed['lastInteraction']);
  scene.eye = (seed['eye'] as List).map((Object? value) => d(value)).toList();
  scene.aim = (seed['aim'] as List).map((Object? value) => d(value)).toList();
  scene.fov = d(seed['fov']);

  final Map<String, Object?> viewer = asMap(part('scene')['viewerSeed']);
  scene.viewer.beginOpen(d(viewer['openAt']));
  scene.viewer.setSurface(viewer['surface'] as String? ?? 'clear');
  for (final Object? step in viewer['claritySteps'] as List) {
    scene.viewer.stepClarity(d(step));
  }
}

void applyDragSeed(DragContinuity drag) {
  final Map<String, Object?> seed = asMap(part('drag')['seed']);
  drag.captured = seed['captured'] == true;
  drag.dragging = seed['dragging'] == true;
  drag.browsing = seed['browsing'] == true;
  drag.holding = seed['holding'] == true;
  drag.navigating = seed['navigating'] == true;
  drag.hasMomentum = seed['hasMomentum'] == true;
  drag.velocityX = d(seed['velocityX']);
  drag.velocityY = d(seed['velocityY']);
  drag.cursor = seed['cursor'] as String? ?? 'default';
  drag.targetRotation = d(seed['targetRotation']);
  drag.dragTrack = seed['dragTrack'] == null ? null : asMap(seed['dragTrack']);
  drag.pendingHover =
      seed['pendingHover'] == null ? null : asMap(seed['pendingHover']);
  drag.hoveredCard =
      seed['hoveredCard'] == null ? null : asMap(seed['hoveredCard']);
}

RotationContinuityHost seededHost() {
  final RotationContinuityHost host = RotationContinuityHost();
  host.startRuntime();
  expect(
    host.playback.restoreSessionState(
      asMap(part('playback')['sessionState']),
      playbackConnection: false,
    ),
    PlaybackRestoreOutcome.restored,
  );
  applyLyricsSeed(host.lyrics);
  applySceneSeed(host.scene);
  applyDragSeed(host.drag);

  final Map<String, Object?> seed = asMap(part('qr')['seed']);
  final int now = i(seed['nowMs']);
  final int token = host.login.beginPrepare(now);
  expect(host.login.acceptKey(token, seed['key'] as String), isTrue);
  expect(host.login.acceptImage(token, seed['image'] as String), isTrue);
  host.login.markWaiting(token, scannerName: seed['scannerName'] as String);
  return host;
}

void main() {
  setUpAll(() {
    final String source =
        File('test/fixtures/rotation_state.json').readAsStringSync();
    fx = asMap(jsonDecode(source));
    expect(fx['synthetic'], isTrue);
    expect(fx['not_device_evidence'], isTrue);
  });

  group('modal whitelist has a single source', () {
    test('exactly the seven Qt-restorable names are accepted', () {
      expect(restorableModalNames, hasLength(7));
      for (final String name in <String>[
        'saved',
        'search',
        'discover',
        'queue',
        'settings',
        'player',
        'local',
      ]) {
        expect(isRestorableModal(name), isTrue, reason: name);
      }
      expect(isRestorableModal('login'), isFalse);
      expect(isRestorableModal(''), isFalse);
      expect(isRestorableModal(null), isFalse);
    });
  });

  group('QR login continuity', () {
    test('validity window uses wall clock and the 300 s boundary', () {
      const QrValidityWindow window = QrValidityWindow(issuedAtMs: 1000);
      expect(window.lifetimeMs, 300000);
      expect(window.remainingMsAt(1000), 300000);
      expect(window.remainingMsAt(300999), 1);
      expect(window.remainingMsAt(301000), 0);
      expect(window.remainingMsAt(999999), 0);
      expect(window.isExpiredAt(300999), isFalse);
      expect(window.isExpiredAt(301000), isTrue);
    });

    test('seed is waiting with a 300 s window and no rotation drift', () {
      final QrLoginContinuity login = seededLogin();
      final Map<String, Object?> expected =
          asMap(part('qr')['expectations']);
      expect(login.generation, expected['generation']);
      expect(login.loginPhase, QrLoginPhase.waiting);
      expect(login.loginStatus, expected['loginStatus']);
      expect(login.loginMethod, 'qr');
      expect(login.qrKey, isNotEmpty);
      expect(login.qr, isNotEmpty);
      expect(login.remainingMs(), expected['remainingAtSeed']);
      login.observeWallClock(i(expected['clockAdvancedTo']));
      expect(login.remainingMs(), expected['remainingAfterClockAdvance']);
      expect(login.expireIfStale(i(expected['liveAtNowMs']), token: 1), isFalse);
      expect(login.loginPhase, QrLoginPhase.waiting);
      expect(login.expireIfStale(i(expected['expiredAtNowMs']), token: 1), isTrue);
      expect(login.loginPhase, QrLoginPhase.failed);
      expect(login.loginStatus, expected['statusAfterWallClockExpiry']);
      expect(login.failureReason, expected['failureReason']);
      expect(login.accountLoading, isFalse);
    });

    test('stale wall-clock token cannot expire a newer code', () {
      final QrLoginContinuity login = seededLogin();
      final int oldToken = login.generation;
      login.observeWallClock(500000);
      final int token = login.beginPrepare(500000);
      expect(token, oldToken + 1);
      expect(login.acceptKey(token, 'new-key'), isTrue);
      expect(
        login.expireIfStale(999999, token: oldToken),
        isFalse,
        reason: 'a stale poll callback must not touch the new generation',
      );
      expect(login.qrKey, 'new-key');
      expect(login.loginPhase, QrLoginPhase.preparing);
    });

    test('provider code 800 clears qr but keeps qrKey and uses its own text', () {
      final QrLoginContinuity login = seededLogin();
      final String key = login.qrKey;
      login.markExpiredByProvider();
      expect(login.qr, isEmpty);
      expect(login.qrKey, key);
      expect(login.generation, 1);
      expect(login.loginPhase, QrLoginPhase.failed);
      expect(
        login.loginStatus,
        asMap(part('qr')['expectations'])['statusAfterProviderExpiry'],
      );
      expect(login.failureReason, QrValidityWindow.failureReason);
      expect(login.accountLoading, isFalse);

      final QrLoginContinuity qq = seededLogin();
      qq.markExpiredByProvider(
        message: 'QQ provider body',
        reason: 'qq-code-800',
      );
      expect(qq.loginStatus, 'QQ provider body');
      expect(qq.failureReason, 'qq-code-800');
    });

    test('scanned and poll-tick transitions preserve the generation', () {
      final QrLoginContinuity login = seededLogin();
      expect(login.recordCheck(1), isTrue);
      expect(login.checkRequestCount, 1);
      login.markScanned(1);
      expect(login.loginPhase, QrLoginPhase.confirming);
      expect(login.loginStatus, '已扫描，请在手机上确认');
      expect(login.generation, 1);
      expect(login.recordCheck(0), isFalse);
      expect(login.checkRequestCount, 1);
    });

    test('QQ cancel issues one request and a second call joins the barrier', () {
      final QrLoginContinuity login = seededLogin();
      final String key = login.qrKey;
      final List<bool> completions = <bool>[];
      expect(
        login.cancel(
          observedGeneration: 1,
          providerIsQq: true,
          done: completions.add,
        ),
        QrCancelOutcome.requested,
      );
      expect(login.generation, 2);
      expect(login.qrKey, isEmpty);
      expect(login.qr, isEmpty);
      expect(login.loginPhase, QrLoginPhase.idle);
      expect(login.cancelRequestCount, 1);
      expect(login.canStartPrepare(), isFalse);
      expect(completions, isEmpty);

      expect(
        login.cancel(observedGeneration: 2, providerIsQq: true),
        QrCancelOutcome.joined,
      );
      expect(login.generation, 2);
      expect(login.cancelRequestCount, 1);
      expect(login.completeCancel(key, true), isTrue);
      expect(completions, <bool>[true]);
      expect(login.canStartPrepare(), isTrue);
      expect(login.completeCancel(key, true), isFalse);
    });

    test('stale generation is rejected without destroying a newer code', () {
      final QrLoginContinuity login = seededLogin();
      final String oldKey = login.qrKey;
      expect(
        login.cancel(observedGeneration: 1, providerIsQq: true),
        QrCancelOutcome.requested,
      );
      expect(login.completeCancel(oldKey, true), isTrue);
      final int token = login.beginPrepare(240000);
      expect(login.acceptKey(token, 'newer-key'), isTrue);
      expect(
        login.cancel(observedGeneration: token - 1, providerIsQq: true),
        QrCancelOutcome.rejectedStale,
      );
      expect(login.qrKey, 'newer-key');
      expect(login.generation, token);
      expect(login.cancelRequestCount, 1);
    });

    test('non-QQ cancel short-circuits and still bumps generation', () {
      final QrLoginContinuity login = seededLogin();
      bool? result;
      expect(
        login.cancel(
          observedGeneration: 1,
          providerIsQq: false,
          done: (bool ok) => result = ok,
        ),
        QrCancelOutcome.shortCircuited,
      );
      expect(result, isTrue);
      expect(login.generation, 2);
      expect(login.cancelRequestCount, 0);
      expect(login.loginPhase, QrLoginPhase.idle);
      expect(login.qrKey, isEmpty);
    });

    test('loginMethod is not a cancel gate', () {
      final QrLoginContinuity login = seededLogin();
      login.loginMethod = 'phone';
      expect(
        login.cancel(observedGeneration: 1, providerIsQq: false),
        QrCancelOutcome.shortCircuited,
      );
      expect(login.generation, 2);
      expect(login.loginPhase, QrLoginPhase.idle);
    });

    test('cancel ticket fans out once and replays result to late waiters', () {
      final QrCancelTicket ticket =
          QrCancelTicket(atGeneration: 1, key: 'old-key');
      final List<bool> first = <bool>[];
      final List<bool> second = <bool>[];
      ticket.wait(first.add);
      ticket.wait(second.add);
      expect(ticket.waiterCount, 2);
      expect(ticket.result, isNull);
      ticket.complete(true);
      expect(ticket.completed, isTrue);
      expect(ticket.result, isTrue);
      expect(first, <bool>[true]);
      expect(second, <bool>[true]);
      expect(ticket.waiterCount, 0);
      ticket.complete(false);
      expect(first, <bool>[true]);
      final List<bool> late = <bool>[];
      ticket.wait(late.add);
      expect(late, <bool>[true]);
      expect(ticket.result, isTrue);
    });
  });

  group('playback archive restore', () {
    test('restores the filtered queue, mode, position and resume seek', () {
      final Map<String, Object?> expected =
          asMap(part('playback')['expect']);
      final PlaybackContinuity player = PlaybackContinuity(provider: 'netease');
      expect(
        player.restoreSessionState(
          asMap(part('playback')['sessionState']),
          playbackConnection: false,
        ),
        PlaybackRestoreOutcome.restored,
      );
      expect(player.queue.length, expected['queueLength']);
      expect(
        player.queue.map((Map<String, Object?> track) => track['id']).toList(),
        orderedEquals(expected['queueIds'] as List),
      );
      expect(player.index, expected['index']);
      expect(player.current!['id'], expected['currentId']);
      expect(player.mode, expected['mode']);
      expect(player.position, expected['position']);
      expect(player.resumePositionMs, expected['resumePositionMs']);
      expect(player.effectivePositionMs, expected['resumePositionMs']);
      expect(player.requested, expected['requested']);
      expect(player.preview, expected['preview']);
      expect(player.history, isEmpty);
    });

    test('all fixture restore cases keep their scalar outcome', () {
      for (final Map<String, Object?> testCase in
          asTracks(part('playback')['cases'])) {
        final Map<String, Object?> saved =
            copyJson(part('playback')['sessionState']);
        asMap(testCase['mutate']).forEach((String key, Object? value) {
          saved[key] = value;
        });
        final PlaybackContinuity player = PlaybackContinuity(provider: 'netease');
        final PlaybackRestoreOutcome outcome = player.restoreSessionState(
          saved,
          playbackConnection: testCase['playbackConnection'] == true,
        );
        expect(outcome.name, testCase['expect'], reason: testCase['name'] as String);
        if (testCase.containsKey('expectQueueLength')) {
          expect(
            player.queue.length,
            testCase['expectQueueLength'],
            reason: testCase['name'] as String,
          );
        }
        if (testCase.containsKey('expectIndex')) {
          expect(player.index, testCase['expectIndex']);
        }
        if (testCase.containsKey('expectMode')) {
          expect(player.mode, testCase['expectMode']);
        }
      }
    });

    test('position gate accepts exactly 1e12 and rejects above it', () {
      final PlaybackContinuity player = PlaybackContinuity(provider: 'netease');
      final Map<String, Object?> saved =
          copyJson(part('playback')['sessionState']);
      saved['position'] = kPlaybackPositionLimitMs;
      expect(
        player.restoreSessionState(saved, playbackConnection: false),
        PlaybackRestoreOutcome.restored,
      );
      final PlaybackContinuity above = PlaybackContinuity(provider: 'netease');
      saved['position'] = kPlaybackPositionLimitMs + 1;
      expect(
        above.restoreSessionState(saved, playbackConnection: false),
        PlaybackRestoreOutcome.rejectedPosition,
      );
      expect(above.queue, isEmpty);
      expect(above.current, isNull);
    });

    test('mode setter accepts four values and ignores everything else', () {
      final PlaybackContinuity player = PlaybackContinuity(provider: 'netease');
      for (final Map<String, Object?> testCase in
          asTracks(part('playback')['modeCases'])) {
        final String value = testCase['value'] as String;
        final bool accepted = testCase['accepted'] == true;
        final String before = player.mode;
        expect(player.setMode(value), accepted, reason: value);
        expect(player.mode, accepted ? value : before, reason: value);
      }
    });

    test('history load caps at 200 valid song ids', () {
      final PlaybackContinuity player = PlaybackContinuity(provider: 'netease');
      final int probe = i(part('playback')['historyProbeCount']);
      final List<Map<String, Object?>> saved = List<Map<String, Object?>>.generate(
        probe,
        (int row) => <String, Object?>{
          'kind': 'song',
          'id': 'song-$row',
          'provider': 'netease',
        },
      );
      player.loadHistory(saved);
      expect(player.history.length, kPlaybackHistoryLimit);
      expect(player.history.first['id'], 'song-0');
      expect(player.history.last['id'], 'song-199');
    });

    test('recordPlayed is newest-first, deduplicated and strips long text', () {
      final PlaybackContinuity player = PlaybackContinuity(provider: 'netease');
      player.recordPlayed(<String, Object?>{
        'kind': 'song',
        'id': 'alpha',
        'provider': 'netease',
        'wiki': 'long wiki',
        'description': 'long description',
      });
      player.recordPlayed(<String, Object?>{
        'kind': 'song',
        'id': 'beta',
        'provider': 'netease',
      });
      player.recordPlayed(<String, Object?>{
        'kind': 'song',
        'id': 'alpha',
        'provider': 'netease',
      });
      expect(player.history.length, 2);
      expect(player.history[0]['id'], 'alpha');
      expect(player.history[1]['id'], 'beta');
      expect(player.history[0]['wiki'], '');
      expect(player.history[0]['description'], '');
    });

    test('resume seek is consumed once and clamped to duration', () {
      final PlaybackContinuity player = PlaybackContinuity(provider: 'netease');
      player.armResume(5000);
      expect(player.effectivePositionMs, 5000);
      expect(player.effectiveRequested, isTrue);
      expect(
        player.consumeResume(seekable: false, durationMs: 4000),
        isFalse,
      );
      expect(
        player.consumeResume(seekable: true, durationMs: 4000),
        isTrue,
      );
      expect(player.position, 4000);
      expect(player.resumePositionMs, isNull);
      expect(player.consumeResume(seekable: true), isFalse);

      player.armResume(null, paused: true);
      expect(player.effectivePositionMs, player.position);
    });

    test('session payload has exactly the seven Qt keys', () {
      final PlaybackContinuity player = PlaybackContinuity(provider: 'netease');
      expect(
        player.sessionState().keys.toList(),
        orderedEquals(<String>[
          'current',
          'queue',
          'index',
          'mode',
          'position',
          'requested',
          'preview',
        ]),
      );
    });

    test('applyPlaybackSnapshot is gated and clips an out-of-range row', () {
      final PlaybackContinuity player = PlaybackContinuity(provider: 'netease');
      expect(
        player.applyPlaybackSnapshot(
          <String, Object?>{'index': 0},
          playbackConnection: false,
        ),
        isFalse,
      );
      expect(player.index, -1);
      final Map<String, Object?> snapshot = <String, Object?>{
        'current': <String, Object?>{
          'kind': 'song',
          'id': 'alpha',
          'provider': 'netease',
        },
        'queue': <Map<String, Object?>>[
          <String, Object?>{'kind': 'song', 'id': 'alpha', 'provider': 'netease'},
          <String, Object?>{'kind': 'song', 'id': 'beta', 'provider': 'netease'},
        ],
        'history': <Map<String, Object?>>[],
        'index': 99,
        'mode': 'repeat-all',
        'preview': true,
      };
      expect(
        player.applyPlaybackSnapshot(snapshot, playbackConnection: true),
        isTrue,
      );
      expect(player.queue.length, 2);
      expect(player.index, -1);
      expect(player.mode, kDefaultPlaybackMode);
      expect(player.preview, isTrue);
      snapshot['index'] = 1;
      player.applyPlaybackSnapshot(snapshot, playbackConnection: true);
      expect(player.index, 1);

      // PlaybackQueue::syncSnapshot sanitizes before bounding the row
      // (PlaybackQueue.cpp:119-124): the album row disappears, the duplicate
      // identity collapses, so original row 2 is out of range for a 2-row
      // queue and must become -1, not beta.
      final Map<String, Object?> serviceQueue = <String, Object?>{
        'current': <String, Object?>{'kind': 'song', 'id': 'beta', 'provider': 'netease'},
        'queue': <Map<String, Object?>>[
          <String, Object?>{'kind': 'song', 'id': 'alpha', 'provider': 'netease'},
          <String, Object?>{'kind': 'album', 'id': 'album-1', 'provider': 'netease'},
          <String, Object?>{'kind': 'song', 'id': 'beta', 'provider': 'netease'},
          <String, Object?>{'kind': 'song', 'id': 'beta', 'provider': 'netease', 'title': 'dup'},
        ],
        'history': <Map<String, Object?>>[],
        'index': 2,
        'mode': 'all',
        'preview': false,
      };
      player.applyPlaybackSnapshot(serviceQueue, playbackConnection: true);
      expect(player.queue.length, 2);
      expect(player.queue.map((Map<String, Object?> t) => t['id']).toList(), <Object?>['alpha', 'beta']);
      expect(player.index, -1);
      serviceQueue['index'] = 1;
      player.applyPlaybackSnapshot(serviceQueue, playbackConnection: true);
      expect(player.index, 1);
      expect(player.queue[1]['id'], 'beta');
    });

    test('playbackSnapshot carries history and the lyrics sub-object', () {
      final PlaybackContinuity player = PlaybackContinuity(provider: 'netease');
      final LyricsContinuity lyrics = LyricsContinuity();
      applyLyricsSeed(lyrics);
      final Map<String, Object?> snapshot = player.playbackSnapshot(lyrics);
      expect(
        snapshot.keys.toList(),
        orderedEquals(<String>[
          'current',
          'queue',
          'history',
          'index',
          'mode',
          'preview',
          'lyrics',
        ]),
      );
      expect(asMap(snapshot['lyrics'])['offsetMs'], 1500);
    });
  });

  group('lyrics continuity', () {
    test('seed resolves the fixture active line and keeps the offset', () {
      final LyricsContinuity lyrics = LyricsContinuity();
      applyLyricsSeed(lyrics);
      final Map<String, Object?> expected = asMap(part('lyrics')['expect']);
      expect(lyrics.activeLineIndex(), expected['activeLineIndex']);
      expect(lyrics.offsetMs, expected['offsetMs']);
      expect(lyrics.localSource, expected['source']);
      expect(lyrics.lyricsMode, expected['lyricsMode']);
      expect(lyrics.key, expected['key']);
      expect(lyrics.status, expected['status']);
      expect(lyrics.globalOffsetMs, expected['globalOffsetMs']);
    });

    test('adjustOffset clamps both directions and recomputes the line', () {
      final LyricsContinuity lyrics = LyricsContinuity();
      applyLyricsSeed(lyrics);
      final Map<String, Object?> clamp = asMap(part('lyrics')['clamp']);
      lyrics.offsetMs = d(clamp['from']);
      expect(lyrics.adjustOffset(d(clamp['delta'])), clamp['expectAfter']);
      expect(lyrics.index, lyrics.activeLineIndex());
      lyrics.offsetMs = d(clamp['downFrom']);
      expect(lyrics.adjustOffset(d(clamp['downDelta'])), clamp['expectDown']);
      lyrics.resetOffset();
      expect(lyrics.offsetMs, clamp['resetExpect']);
      expect(lyrics.index, lyrics.activeLineIndex());
    });

    test('syncPosition re-resolves without moving the user offset', () {
      final LyricsContinuity lyrics = LyricsContinuity();
      lyrics.document = <String, Object?>{
        'offsetMs': 0,
        'lines': <Map<String, Object?>>[
          <String, Object?>{'startMs': 0},
          <String, Object?>{'startMs': 1000},
        ],
      };
      lyrics.offsetMs = 100;
      lyrics.syncPosition(800);
      expect(lyrics.offsetMs, 100);
      expect(lyrics.index, 0);
      lyrics.syncPosition(1000);
      expect(lyrics.index, 1);
    });

    test('lyrics mode drops on same/other identity and on empty current', () {
      final LyricsContinuity lyrics = LyricsContinuity();
      applyLyricsSeed(lyrics);
      final Map<String, Object?> change = asMap(part('lyrics')['trackChange']);
      expect(
        lyrics.dropLyricsModeIfTrackChanged(change['sameIdentity'] as String),
        isFalse,
      );
      expect(lyrics.lyricsMode, isTrue);
      expect(
        lyrics.dropLyricsModeIfTrackChanged(change['otherIdentity'] as String),
        isTrue,
      );
      expect(lyrics.lyricsMode, change['expectLyricsModeAfterOther']);

      lyrics.lyricsMode = true;
      lyrics.playingTrack = null;
      expect(lyrics.dropLyricsModeIfTrackChanged('netease:anything'), isTrue);
      expect(lyrics.lyricsMode, isFalse);
    });

    test('snapshot has nine keys and replay applies Qt defaults', () {
      final LyricsContinuity lyrics = LyricsContinuity();
      expect(
        lyrics.playbackSnapshot().keys.toList(),
        orderedEquals(<String>[
          'document',
          'status',
          'message',
          'key',
          'index',
          'offsetMs',
          'positionMs',
          'globalOffsetMs',
          'localSource',
        ]),
      );
      lyrics.applyPlaybackSnapshot(<String, Object?>{});
      expect(lyrics.document, isEmpty);
      expect(lyrics.status, 'idle');
      expect(lyrics.message, '');
      expect(lyrics.key, '');
      expect(lyrics.index, -1);
      expect(lyrics.offsetMs, 0);
      expect(lyrics.positionMs, 0);
      expect(lyrics.globalOffsetMs, 0);
      expect(lyrics.localSource, 'auto');
    });

    test('applyPlaybackSnapshot accepts a service snapshot verbatim', () {
      final LyricsContinuity lyrics = LyricsContinuity();
      applyLyricsSeed(lyrics);
      final Map<String, Object?> snapshot = lyrics.playbackSnapshot();
      final LyricsContinuity replayed = LyricsContinuity();
      replayed.applyPlaybackSnapshot(snapshot);
      expect(replayed.document, lyrics.document);
      expect(replayed.status, lyrics.status);
      expect(replayed.key, lyrics.key);
      expect(replayed.index, lyrics.index);
      expect(replayed.offsetMs, lyrics.offsetMs);
      expect(replayed.positionMs, lyrics.positionMs);
      expect(replayed.globalOffsetMs, lyrics.globalOffsetMs);
      expect(replayed.localSource, lyrics.localSource);
    });
  });

  group('3D scene and viewer continuity', () {
    test('defaults match NativeScene initial values', () {
      final SceneContinuity scene = SceneContinuity();
      expect(scene.targetReveal, 0);
      expect(scene.looping, isFalse);
      expect(scene.changed, isTrue);
      expect(scene.mode, 'boot');
      expect(scene.reveal, 0);
      expect(scene.detail, 0);
      expect(scene.clock, 0);
      expect(scene.bootStart, -1.76);
      expect(scene.selected, 0);
      expect(scene.viewer.transition, 'closed');
      expect(scene.viewer.open, isFalse);
      expect(scene.viewer.clarity, 1);
      expect(scene.viewer.resetCount, 0);
    });

    test('setMode clears freeze and writes the boot/detail targets', () {
      final SceneContinuity scene = SceneContinuity();
      scene.clock = 40;
      scene.freeze = 7;
      scene.setMode('boot');
      expect(scene.mode, 'boot');
      expect(scene.freeze, isNull);
      expect(scene.bootStart, closeTo(38.24, 1e-12));
      expect(scene.looping, isFalse);
      expect(scene.targetReveal, 0);
      expect(scene.targetDetail, 0);
      expect(scene.targetRotation, 0);
      expect(scene.lastInteraction, 40);
      expect(scene.changed, isTrue);

      scene.clock = 50;
      scene.setMode('detail');
      expect(scene.mode, 'detail');
      expect(scene.looping, isTrue);
      expect(scene.targetReveal, 1);
      expect(scene.targetDetail, 1);
      expect(scene.lastInteraction, 50);
    });

    test('applyViewport changes only size/dirty/viewer resize', () {
      final SceneContinuity scene = SceneContinuity();
      applySceneSeed(scene);
      scene.eye = <double>[-1, 2, 3];
      scene.aim = <double>[4, 5, 6];
      scene.fov = 1.25;
      scene.freeze = 9;
      final double clock = scene.clock;
      final int revisionBefore = scene.viewportChangeCount;
      final int resizeBefore = scene.viewer.resizeCount;
      scene.applyViewport(2400, 1080);
      expect(scene.width, 2400);
      expect(scene.height, 1080);
      expect(scene.aspect, closeTo(2400 / 1080, 1e-12));
      expect(scene.changed, isTrue);
      expect(scene.viewportChangeCount, revisionBefore + 1);
      expect(scene.clock, clock);
      expect(scene.bootStart, -1.76);
      expect(scene.detail, 0.12);
      expect(scene.targetDetail, 1);
      expect(scene.rotation, 0.21);
      expect(scene.targetRotation, 0.34);
      expect(scene.selected, 12);
      expect(scene.eye, <double>[-1, 2, 3]);
      expect(scene.aim, <double>[4, 5, 6]);
      expect(scene.fov, 1.25);
      expect(scene.freeze, 9);
      expect(scene.viewer.resizeCount, resizeBefore + 1);
      expect(scene.viewer.open, isTrue);
      expect(scene.viewer.openCount, 1);
      expect(scene.viewer.resetCount, 0);
    });

    test('viewport dimensions clamp to at least one logical pixel', () {
      final SceneContinuity scene = SceneContinuity();
      scene.applyViewport(0, -4);
      expect(scene.width, 1);
      expect(scene.height, 1);
    });

    test('camera portrait/compact thresholds follow Qt', () {
      final SceneContinuity scene = SceneContinuity();
      for (final Map<String, Object?> testCase in
          asTracks(part('scene')['cameraCases'])) {
        scene.applyViewport(i(testCase['width']), i(testCase['height']));
        expect(
          scene.aspect,
          closeTo(d(testCase['aspect']), 1e-12),
          reason: testCase['width'].toString(),
        );
        expect(scene.cameraPortrait, testCase['portrait'],
            reason: testCase['width'].toString());
        expect(scene.cameraCompact, testCase['compact'],
            reason: testCase['width'].toString());
      }
    });

    test('boot handover happens at 35 elapsed seconds', () {
      final SceneContinuity scene = SceneContinuity();
      final Map<String, Object?> handover = asMap(part('scene')['bootHandover']);
      scene.advanceClockTo(d(handover['clock']));
      scene.setMode('boot');
      expect(
        scene.bootStart,
        closeTo(d(handover['bootStartAfterSetMode']), 1e-12),
      );
      expect(
        scene.elapsed,
        closeTo(d(handover['bootOffsetSeconds']), 1e-12),
      );
      scene.advanceClockTo(d(handover['justBeforeClock']));
      expect(scene.bootFinished, isFalse);
      scene.advanceClockTo(d(handover['handoverAtClock']));
      expect(scene.bootFinished, isTrue);
      expect(
        scene.elapsed,
        closeTo(d(handover['handoverElapsedSeconds']), 1e-12),
      );
    });

    test('canBrowse requires looping, settled detail and full reveal', () {
      final SceneContinuity scene = SceneContinuity();
      scene.looping = true;
      scene.targetDetail = 0;
      scene.detail = 0.19;
      scene.reveal = 0.8;
      expect(scene.canBrowse, isTrue);
      scene.detail = 0.2;
      expect(scene.canBrowse, isFalse);
      scene.detail = 0.1;
      scene.reveal = 0.79;
      expect(scene.canBrowse, isFalse);
      scene.reveal = 1;
      scene.targetDetail = 0.1;
      expect(scene.canBrowse, isFalse);
    });

    test('viewer opening does not count as an explicit reset', () {
      final ViewerContinuity viewer = ViewerContinuity();
      expect(viewer.beginOpen(41), isTrue);
      expect(viewer.open, isTrue);
      expect(viewer.transition, 'opening');
      expect(viewer.openCount, 1);
      expect(viewer.resetCount, 0);
      expect(viewer.pendingUntil, closeTo(41.38, 1e-12));
      expect(viewer.clarity, 1);
      expect(viewer.clarityVelocity, 0);
      expect(viewer.surface, 'clear');
      expect(viewer.spread, 0);
      expect(viewer.beginOpen(42), isFalse);
      expect(viewer.openCount, 1);
      expect(viewer.resetCount, 0);

      final ViewerContinuity reduced = ViewerContinuity();
      expect(reduced.beginOpen(50, reducedMotion: true), isTrue);
      expect(reduced.pendingUntil, 50);
    });

    test('viewer clarity uses the exact second-order spring', () {
      final ViewerContinuity viewer = ViewerContinuity();
      viewer.beginOpen(41);
      viewer.setSurface('frosted');
      double value = 1;
      double velocity = 0;
      for (int step = 0; step < 2; step++) {
        final double delta = value - 0;
        final double impulse = velocity + 8 * delta;
        final double decay = math.exp(-0.8);
        value = (delta + impulse * 0.1) * decay;
        velocity = (velocity - 8 * impulse * 0.1) * decay;
        viewer.stepClarity(0.1);
        expect(viewer.clarity, closeTo(value, 1e-12));
        expect(viewer.clarityVelocity, closeTo(velocity, 1e-12));
      }
      expect(viewer.clarity, lessThan(1));
      viewer.setSurface('clear');
      for (int step = 0; step < 200; step++) {
        viewer.stepClarity(0.05);
      }
      expect(viewer.clarity, 1);
      expect(viewer.clarityVelocity, 0);
    });

    test('viewer reset/resize counters and reduced-motion snap', () {
      final ViewerContinuity viewer = ViewerContinuity();
      viewer.beginOpen(10, reducedMotion: true);
      expect(viewer.pendingUntil, 10);
      viewer.reset(animated: true, from: <double>[1, 2, 3]);
      expect(viewer.resetCount, 1);
      expect(viewer.resetting, isTrue);
      expect(viewer.resetElapsed, 0);
      expect(viewer.resetFrom, <double>[1, 2, 3]);
      viewer.reset(animated: false);
      expect(viewer.resetCount, 2);
      expect(viewer.resetting, isFalse);
      viewer.resize();
      expect(viewer.resizeCount, 1);
      viewer.resize();
      expect(viewer.resizeCount, 2);
    });
  });

  group('drag cancellation', () {
    test('stage drag survives momentum but loses pointer identity', () {
      final DragContinuity drag = DragContinuity();
      applyDragSeed(drag);
      final Map<String, Object?> expected =
          asMap(part('drag')['expectCancel']);
      expect(drag.cancelForViewportChange(canBrowseNow: false), isTrue);
      expect(drag.captured, expected['captured']);
      expect(drag.dragging, expected['dragging']);
      expect(drag.browsing, expected['browsing']);
      expect(drag.holding, expected['holding']);
      expect(drag.hasMomentum, expected['hasMomentum']);
      expect(drag.velocityX, expected['velocityX']);
      expect(drag.velocityY, expected['velocityY']);
      expect(drag.cursor, expected['cursor']);
      expect(drag.dragTrack, expected['dragTrack']);
      expect(drag.hoveredCard, expected['hoveredCard']);
      expect(drag.cancelCount, expected['cancelCount']);
      expect(drag.targetRotation, expected['targetRotation']);
      expect(drag.cancelForViewportChange(canBrowseNow: false), isFalse);
      expect(drag.cancelCount, 1);
    });

    test('browsable scene leaves the pointer as grab', () {
      final DragContinuity drag = DragContinuity();
      applyDragSeed(drag);
      expect(drag.cancelForViewportChange(canBrowseNow: true), isTrue);
      expect(
        drag.cursor,
        asMap(part('drag')['expectCancelWhenBrowsable'])['cursor'],
      );
    });

    test('idle pointer is not counted as a cancellation', () {
      final DragContinuity drag = DragContinuity();
      expect(drag.cancelForViewportChange(canBrowseNow: false), isFalse);
      expect(
        drag.cancelCount,
        asMap(part('drag')['expectIdleNoCancel'])['cancelCount'],
      );
    });

    test('rotateBy clamps to +/-0.8 and resetPointer can stop momentum', () {
      final DragContinuity drag = DragContinuity();
      drag.rotateBy(1000);
      expect(drag.targetRotation, 0.8);
      drag.rotateBy(-1000);
      expect(drag.targetRotation, -0.8);
      drag.captured = true;
      drag.hasMomentum = true;
      drag.velocityX = 1;
      drag.resetPointer(stopMomentum: true, canBrowseNow: false);
      expect(drag.captured, isFalse);
      expect(drag.hasMomentum, isFalse);
      expect(drag.velocityX, 0);
      expect(drag.cursor, 'default');
    });

    test('pending hover counts as active and is cancelled', () {
      final DragContinuity drag = DragContinuity();
      drag.pendingHover = <String, Object?>{'id': 'beta'};
      expect(drag.cancelForViewportChange(canBrowseNow: false), isTrue);
      expect(drag.pendingHover, isNull);
      expect(drag.cancelCount, 1);
    });
  });

  group('viewport frame', () {
    test('fromJson/toJson round-trip and stage rounding', () {
      final Map<String, Object?> json = <String, Object?>{
        'logicalWidth': 1200,
        'logicalHeight': 540,
        'devicePixelRatio': 2,
        'insets': <String, Object?>{
          'top': 24,
          'right': 1,
          'bottom': 48,
          'left': 2,
        },
        'imeInset': 320,
      };
      final ViewportFrame frame = ViewportFrame.fromJson(json);
      expect(frame.logicalWidth, 1200);
      expect(frame.logicalHeight, 540);
      expect(frame.devicePixelRatio, 2);
      expect(frame.insets.top, 24);
      expect(frame.insets.right, 1);
      expect(frame.insets.bottom, 48);
      expect(frame.insets.left, 2);
      expect(frame.imeInset, 320);
      expect(frame.physicalWidth, 2400);
      expect(frame.physicalHeight, 1080);
      expect(frame.stageWidth, 2400);
      expect(frame.stageHeight, 1080);
      expect(frame.toJson(), json);
    });

    test('missing optional fields default to zero and dpr one', () {
      final ViewportFrame frame = ViewportFrame.fromJson(
        <String, Object?>{'logicalWidth': 10, 'logicalHeight': 20},
      );
      expect(frame.devicePixelRatio, 1);
      expect(frame.insets.top, 0);
      expect(frame.insets.right, 0);
      expect(frame.insets.bottom, 0);
      expect(frame.insets.left, 0);
      expect(frame.imeInset, 0);
    });

    test('landscape 1000x600 sends Qt stage units (1800x1080), not physical pixels', () {
      // Qt 反例（root review F3）：窗口 1000x600 交给 Engine::resize 后，
      // Qt/src/Engine.cpp:847 送 scene.resize(1000 / (600 / 1080), 1080) = 1800x1080。
      const ViewportFrame frame = ViewportFrame(
        logicalWidth: 1000,
        logicalHeight: 600,
        devicePixelRatio: 1,
      );
      expect(frame.physicalWidth, 1000);
      expect(frame.physicalHeight, 600);
      expect(frame.stageWidth, 1800);
      expect(frame.stageHeight, 1080);
      expect(frame.stageMetrics.stageScale, closeTo(600 / 1080, 1e-12));
      expect(frame.stageMetrics.stageWidth, closeTo(1800, 1e-9), reason: 'stageWidth 取自唯一 StageMetrics');
      expect(frame.stageMetrics.stageHeight, closeTo(1080, 1e-9));
      expect(frame.stageMetrics.isLandscape, isTrue);
    });

    test('dpr changes physical pixels only; the stage box is dpr-invariant', () {
      const ViewportFrame at1 = ViewportFrame(
        logicalWidth: 1000,
        logicalHeight: 600,
        devicePixelRatio: 1,
      );
      const ViewportFrame at2 = ViewportFrame(
        logicalWidth: 1000,
        logicalHeight: 600,
        devicePixelRatio: 2,
      );
      // Qt/qml/Main.qml:32 的 stageScale = height / 1080 没有 dpr 项，
      // 所以同一个逻辑窗口在 @1 与 @2 上必须是同一个舞台盒。
      expect(at2.physicalWidth, 2000);
      expect(at2.physicalHeight, 1200);
      expect(at1.stageWidth, at2.stageWidth);
      expect(at1.stageHeight, at2.stageHeight);
      expect(at2.stageWidth, 1800);
      expect(at2.stageHeight, 1080);
      // 唯一仍按物理宽判定的是 A1 的 StageMetrics.cameraCompact
      // （orientation_state.dart:324，任务书要求保留物理宽阈值、不改成舞台单位）。
      expect(at1.stageMetrics.cameraCompact, isTrue, reason: '1000 物理 < 1100');
      expect(at2.stageMetrics.cameraCompact, isFalse, reason: '2000 物理 >= 1100');
    });

    test('portrait 1080x2400 sends a 1080x2400 stage', () {
      const ViewportFrame frame = ViewportFrame(
        logicalWidth: 1080,
        logicalHeight: 2400,
        devicePixelRatio: 1,
      );
      // 竖屏契约（orientation_state.dart:283-285）：舞台宽恒 1080，
      // stageScale = logicalWidth / 1080，stageHeight = logicalHeight / stageScale。
      expect(frame.stageWidth, 1080);
      expect(frame.stageHeight, 2400);
      expect(frame.stageMetrics.orientation, OrientationKind.portrait);
      expect(frame.stageMetrics.stageScale, closeTo(1, 1e-12));
      // 竖屏不得被机械锁成 1080 高：更高的窗口必须给出更高的舞台。
      const ViewportFrame taller = ViewportFrame(
        logicalWidth: 1080,
        logicalHeight: 3000,
        devicePixelRatio: 1,
      );
      expect(taller.stageWidth, 1080);
      expect(taller.stageHeight, 3000);
    });

    test('degenerate frame falls back to Qt 1920x1080', () {
      // Qt/src/Engine.cpp:1353 的 m_height > 0 ? ... : 1920 兜底。
      const ViewportFrame zero = ViewportFrame(
        logicalWidth: 0,
        logicalHeight: 0,
        devicePixelRatio: 1,
      );
      expect(zero.stageWidth, 1920);
      expect(zero.stageHeight, 1080);
      expect(zero.stageMetrics.stageScale, 0);
      const ViewportFrame half = ViewportFrame(
        logicalWidth: 1000,
        logicalHeight: 0,
        devicePixelRatio: 1,
      );
      expect(half.stageWidth, 1920);
      expect(half.stageHeight, 1080);
    });

    test('stage box matches the single StageMetrics formula across sizes', () {
      // 回归护栏：ViewportFrame 不得重新长出第二套 1080/1920/1.05 常量。
      const List<List<double>> sizes = <List<double>>[
        <double>[2400, 1080],
        <double>[1000, 600],
        <double>[1920, 1200],
        <double>[1080, 2400],
        <double>[360, 800],
        <double>[800, 360],
      ];
      for (final List<double> size in sizes) {
        for (final double dpr in <double>[1, 2, 2.75, 3]) {
          final ViewportFrame frame = ViewportFrame(
            logicalWidth: size[0],
            logicalHeight: size[1],
            devicePixelRatio: dpr,
          );
          final StageMetrics metrics = StageMetrics.compute(
            StageInputs(
              logicalWidth: size[0],
              logicalHeight: size[1],
              devicePixelRatio: dpr,
            ),
          );
          expect(
            frame.stageWidth,
            metrics.stageWidth.round(),
            reason: 'stageWidth 必须是 StageMetrics 的舍入值：${size[0]}x${size[1]}@$dpr',
          );
          expect(
            frame.stageHeight,
            metrics.stageHeight.round(),
            reason: 'stageHeight 必须是 StageMetrics 的舍入值：${size[0]}x${size[1]}@$dpr',
          );
        }
      }
    });
  });

  group('rotation host', () {
    test('three fixture frames preserve login, playback, lyrics and scene', () {
      final RotationContinuityHost host = seededHost();
      final List<Map<String, Object?>> frames = asTracks(fx['frames']);
      for (final Map<String, Object?> frame in frames) {
        final Map<String, Object?> expected = asMap(frame['expect']);
        final Map<String, Object?> stage = asMap(expected['stage']);
        final Map<String, Object?> expectedLogin = asMap(expected['login']);
        final Map<String, Object?> expectedScene = asMap(expected['scene']);
        final Map<String, Object?> expectedPlayback = asMap(expected['playback']);
        final Map<String, Object?> expectedLyrics = asMap(expected['lyrics']);
        final bool cancelled = host.applyViewport(
          ViewportFrame.fromJson(asMap(frame['viewport'])),
        );
        expect(
          cancelled,
          frame['name'] == 'landscape',
          reason: 'only the first frame meets the seeded drag',
        );
        expect(host.viewportRevision, expected['viewportRevision']);
        expect(host.scene.width, stage['width']);
        expect(host.scene.height, stage['height']);
        expect(host.scene.cameraPortrait, stage['portrait']);
        expect(host.scene.cameraCompact, stage['compact']);
        expect(host.login.generation, expectedLogin['generation']);
        expect(host.login.qrKey, expectedLogin['qrKey']);
        expect(host.login.hasCode, expectedLogin['hasCode']);
        expect(host.login.loginPhase, expectedLogin['loginPhase']);
        expect(host.login.remainingMs(), expectedLogin['remainingMs']);
        expect(host.scene.clock, expectedScene['clock']);
        expect(host.scene.bootStart, expectedScene['bootStart']);
        expect(host.scene.detail, expectedScene['detail']);
        expect(host.scene.mode, expectedScene['mode']);
        expect(host.scene.selected, expectedScene['selected']);
        expect(host.scene.eye, orderedEquals(expectedScene['eye'] as List));
        expect(host.scene.aim, orderedEquals(expectedScene['aim'] as List));
        expect(host.scene.viewer.transition, expectedScene['viewerTransition']);
        expect(host.scene.viewer.openCount, expectedScene['viewerOpenCount']);
        expect(host.scene.viewer.resetCount, expectedScene['viewerResetCount']);
        expect(
          host.scene.viewer.resizeCount,
          expectedScene['viewerResizeCount'],
        );
        expect(host.scene.canBrowse, expectedScene['canBrowse']);
        expect(host.playback.index, expectedPlayback['index']);
        expect(host.playback.mode, expectedPlayback['mode']);
        expect(host.playback.history.length, expectedPlayback['history']);
        expect(host.lyrics.offsetMs, expectedLyrics['offsetMs']);
        expect(host.lyrics.localSource, expectedLyrics['source']);
        expect(host.lyrics.lyricsMode, expectedLyrics['lyricsMode']);

        final Map<String, Object?> described = host.describe();
        expect(described['viewportRevision'], expected['viewportRevision']);
        expect(
          asMap(described['login'])['generation'],
          expectedLogin['generation'],
        );
        expect(
          asMap(described['scene'])['viewerResetCount'],
          expectedScene['viewerResetCount'],
        );
        expect(
          asMap(described['playback'])['index'],
          expectedPlayback['index'],
        );
        expect(
          asMap(described['lyrics'])['offsetMs'],
          expectedLyrics['offsetMs'],
        );
      }
      expect(host.scene.viewer.resetCount, 0);
      expect(host.scene.viewer.openCount, 1);
      host.dispose();
      expect(host.ledger.live('stageListener'), 0);
    });

    test('ten round trips reuse resources and balance every lease', () {
      final Map<String, Object?> spec = asMap(part('ledger'));
      final Map<String, Object?> expected = asMap(spec['expect']);
      final RotationContinuityHost host = RotationContinuityHost();
      host.startRuntime();
      final ViewportFrame first = ViewportFrame.fromJson(
        asMap((asTracks(fx['frames'])[0])['viewport']),
      );
      final ViewportFrame second = ViewportFrame.fromJson(
        asMap((asTracks(fx['frames'])[1])['viewport']),
      );
      final String ephemeralKind = spec['ephemeralKind'] as String;
      final int rounds = i(spec['roundTrips']);
      for (int round = 0; round < rounds; round++) {
        final int lease = host.ledger.acquire(ephemeralKind);
        for (int apply = 0; apply < i(spec['appliesPerRoundTrip']); apply++) {
          host.applyViewport(apply == 0 ? first : second);
        }
        expect(host.ledger.release(ephemeralKind, lease), isTrue);
      }
      host.dispose();
      expect(host.ledger.loginCount, expected['loginCount']);
      expect(host.ledger.loginAttempts, expected['loginAttempts']);
      expect(host.ledger.nodeStartCount, expected['nodeStartCount']);
      expect(host.ledger.nodeStartAttempts, expected['nodeStartAttempts']);
      expect(host.ledger.mediaSourceBuildCount, expected['mediaSourceBuildCount']);
      expect(host.ledger.mediaSourceReuseCount, expected['mediaSourceReuseCount']);
      expect(host.ledger.stageRebindCount, expected['stageRebindCount']);
      expect(
        host.ledger.created('stageListener'),
        expected['stageListenerCreated'],
      );
      expect(
        host.ledger.live('stageListener'),
        expected['stageListenerLiveAfterDispose'],
      );
      expect(host.ledger.created(ephemeralKind), expected['ephemeralCreated']);
      expect(host.ledger.disposed(ephemeralKind), expected['ephemeralDisposed']);
      expect(host.ledger.balanced, expected['balancedAfterDispose']);
      expect(
        host.ledger.report()['notDeviceEvidence'],
        expected['reportNotDeviceEvidence'],
      );

      expect(host.ledger.beginLogin(), isFalse);
      expect(host.ledger.loginAttempts, 2);
      expect(host.ledger.startNodeRuntime(), isFalse);
      expect(host.ledger.nodeStartAttempts, 2);
      expect(host.ledger.buildMediaSource(), isFalse);
      expect(host.ledger.mediaSourceBuildCount, 1);
    });

    test('ledger rejects unknown and double release', () {
      final ResourceLedger ledger = ResourceLedger();
      final int id = ledger.acquire('stageListener');
      expect(ledger.release('stageListener', id), isTrue);
      expect(ledger.release('stageListener', id), isFalse);
      expect(ledger.release('missing', 1), isFalse);
      expect(ledger.live('stageListener'), 0);
      expect(ledger.balanced, isTrue);
    });

    test('host hands stage units to the 3D scene (1000x600 -> 1800x1080)', () {
      final RotationContinuityHost host = RotationContinuityHost();
      host.applyViewport(
        const ViewportFrame(
          logicalWidth: 1000,
          logicalHeight: 600,
          devicePixelRatio: 1,
        ),
      );
      // 旧缺陷：宿主把物理 1000x600 直接交给 SceneContinuity，横屏场景的
      // cameraCompact（width < 1100）被误判为 true。Qt 的 NativeScene 收的是
      // 舞台单位（Qt/src/Engine.cpp:847），所以这里必须是 1800x1080。
      expect(host.scene.width, 1800);
      expect(host.scene.height, 1080);
      expect(host.scene.aspect, closeTo(1800 / 1080, 1e-12));
      expect(host.scene.cameraPortrait, isFalse);
      expect(
        host.scene.cameraCompact,
        isFalse,
        reason: 'NativeSceneCamera.cpp:57 比较的是舞台宽 1800，不是物理宽 1000',
      );
      expect(host.scene.viewportChangeCount, 1);
      expect(host.scene.viewer.resizeCount, 1);
      host.dispose();
    });

    test('host pushes the Qt 1920x1080 fallback for a degenerate frame', () {
      // 退化帧使用 StageMetrics 的 1920x1080 兜底（Engine.cpp:1353 在 Android
      // HUD 路径上用同一个 1920）；注意 Engine::resize 根本不会把退化帧转给
      // NativeScene —— 它早退并保留上一尺寸（Engine.cpp:841-843）。要完全复刻
      // 该语义，调用方可在 applyViewport 前用 stageMetrics.stageScale > 0 判断；
      // 本测试只固定宿主当前行为。
      final RotationContinuityHost host = RotationContinuityHost();
      host.applyViewport(
        const ViewportFrame(
          logicalWidth: 2400,
          logicalHeight: 1080,
          devicePixelRatio: 1,
        ),
      );
      expect(host.scene.width, 2400);
      expect(host.scene.height, 1080);
      host.applyViewport(
        const ViewportFrame(
          logicalWidth: 0,
          logicalHeight: 0,
          devicePixelRatio: 1,
        ),
      );
      expect(host.scene.width, 1920);
      expect(host.scene.height, 1080);
      host.dispose();
    });
  });
}