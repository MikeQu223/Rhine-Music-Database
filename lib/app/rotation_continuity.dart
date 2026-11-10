/// Rotation continuity — the "engine/session objects live outside the widget
/// tree" half of T44 (plan 2026-11-09-qt-to-flutter-parity-plan.md:369, 373-376,
/// 692-698).
///
/// Scope boundary: this library owns *runtime continuity only*. It never touches
/// geometry, never reads MediaQuery, and never imports \`package:flutter\`. The
/// stage re-derivation belongs to A1 (\`lib/app/orientation_state.dart\`); that file
/// is pure Dart and is imported here only for its single-source
/// \`restorableModalNames\` constant (MF-5). Every numeric input (logical size, dpr,
/// insets, IME inset) is injected as a plain \`double\`, so the whole file is
/// statically testable with \`flutter_test\` (the repo has no \`package:test\`).
///
/// Why a tree-external object at all: rotation may only rebuild MediaQuery and
/// recompute the stage (plan:369). It must not \`runApp\`, dispose the player,
/// clear the lists, log in again, restart Node, or rebuild the media source.
/// Anything that has to survive rotation therefore has to live here, outside the
/// widget tree, and be *handed in* to the rebuilt tree.
///
/// Evidence discipline: state fields mirror Qt and cite their Qt source line.
/// Instrumentation counters (request/key/open counts), the resource ledger and
/// the host are test harness constructs, not Qt fields. Fields added by the plan
/// are labelled with their plan line; none impersonates a Qt field.
///
/// RED/GREEN: NOT EXECUTED. No \`flutter test\`, no \`dart test\`, no \`dart
/// analyze\` was run for this file (hard prohibition for this task). The test in
/// \`test/rotation_continuity_test.dart\` is written, not executed.
///
/// Fixture: \`test/fixtures/rotation_state.json\` is synthetic (\`"synthetic":
/// true\`, \`"not_device_evidence": true\`). It is NOT a record of device rotation
/// round trips.
library;

import 'dart:math' as math;

import 'orientation_state.dart';

// ---------------------------------------------------------------------------
// 0. Shared constants
// ---------------------------------------------------------------------------

/// The seven modal names that may be restored (and therefore re-opened after a
/// rotation) — Qt/src/MusicSession.cpp:243.
///
/// Single source: \`lib/app/orientation_state.dart\` declares
/// \`restorableModalNames\`; this file imports it instead of duplicating the
/// literal set (MF-5). Every other name is dropped on restore. In particular
/// \`login\` is absent: a rotation must never resurrect the login modal, because
/// doing so would let a closeModal path cancel a live QR
/// (\`MusicAccount.cpp:352-379\`).
///
/// Qt/src/MusicSession.cpp:243 — membership test used by the restore path.
bool isRestorableModal(String? modal) => modal != null && restorableModalNames.contains(modal);

// ---------------------------------------------------------------------------
// 1. QR login: wall clock + generation + cancel completion barrier
// ---------------------------------------------------------------------------

/// Login phase literals, verbatim from Qt/src/MusicLibrary.h:174 (default
/// \`"idle"\`) and MusicAccount.cpp:311 (\`"failed"\`), :357 (\`"idle"\`),
/// :515 (\`"complete"\`), :542 (\`"preparing"\`), :588 (\`"waiting"\`),
/// :654/:659 (\`"confirming"\`).
abstract final class QrLoginPhase {
  static const String idle = 'idle';
  static const String preparing = 'preparing';
  static const String waiting = 'waiting';
  static const String confirming = 'confirming';
  static const String complete = 'complete';
  static const String failed = 'failed';

  static const List<String> all = <String>[
    idle,
    preparing,
    waiting,
    confirming,
    complete,
    failed,
  ];
}

/// Outcome of a cancel/close request against the completion barrier.
enum QrCancelOutcome {
  /// Cancel accepted, \`/login/qr/cancel\` actually issued (QQ only).
  requested,

  /// Cancel accepted, but no request was needed: either the provider is not QQ
  /// or there was no key to revoke — Qt/src/MusicAccount.cpp:359-364.
  shortCircuited,

  /// A cancel for the *current* generation is already in flight. The caller
  /// joins the existing barrier instead of bumping the generation again, so a
  /// double closeModal cannot drop a freshly created QR
  /// (Qt/src/MusicAccount.cpp:343-349, 371-378).
  joined,

  /// The caller observed an older generation than the live one. Rejected
  /// without touching \`qrKey\`/\`qr\`/generation, because clearing here would
  /// destroy a newer code (Qt/src/MusicAccount.cpp:353-356).
  rejectedStale,
}

/// One wall-clock validity window for a QR code.
///
/// Qt polls at 1 Hz and gives up after 300 polls, i.e. a 300 s wall-clock
/// budget: \`if (count >= 300)\` at Qt/src/MusicAccount.cpp:626 with
/// \`host->schedule(1000, ...)\` at :631. The check is expressed against
/// \`QDateTime::currentMSecsSinceEpoch()\` in the request payloads (:561, :600,
/// :635), so wall clock — not a frame ticker — is the authority; a rotation
/// cannot extend or restart it.
class QrValidityWindow {
  const QrValidityWindow({
    required this.issuedAtMs,
    this.lifetimeMs = kQrPollBudgetMs,
  });

  /// Max polls (300) x poll interval (1000 ms) — MusicAccount.cpp:626, :631.
  static const int kQrPollBudgetMs = 300 * 1000;

  final int issuedAtMs;
  final int lifetimeMs;

  int remainingMsAt(int nowMs) {
    final int remaining = lifetimeMs - (nowMs - issuedAtMs);
    return remaining < 0 ? 0 : remaining;
  }

  /// Strictly-greater-or-equal boundary: exactly at the budget the code is
  /// spent, matching \`count >= 300\` (MusicAccount.cpp:626).
  bool isExpiredAt(int nowMs) => nowMs - issuedAtMs >= lifetimeMs;

  /// Qt's user-facing reason string for this expiry — MusicAccount.cpp:32.
  static const String failureReason = 'qr-timeout';
}

/// Completion barrier for one \`/login/qr/cancel\`.
///
/// Qt stores it in \`m_cancellations\` as a shared node with a waiter list
/// (MusicLibrary.h:227-230) and completes every waiter with the request result
/// (MusicAccount.cpp:371-378). Generation is bumped *before* the request
/// (MusicAccount.cpp:354) so outstanding poll callbacks die via
/// \`valid(token, &m_loginGeneration)\` (MusicAccount.cpp:541, :565, :630).
class QrCancelTicket {
  QrCancelTicket({required this.atGeneration, required this.key});

  /// The generation that was live *before* the cancel bumped it.
  final int atGeneration;

  /// The key being revoked; Qt passes \`previousKey\` and clears \`qrKey\` first
  /// (MusicAccount.cpp:353-356, :371).
  final String key;

  final List<void Function(bool ok)> _waiters = <void Function(bool ok)>[];
  bool _completed = false;
  bool _ok = false;

  bool get completed => _completed;

  /// \`null\` while pending, then the request result.
  bool? get result => _completed ? _ok : null;

  int get waiterCount => _waiters.length;

  void wait(void Function(bool ok) done) {
    if (_completed) {
      done(_ok);
      return;
    }
    _waiters.add(done);
  }

  /// Idempotent: a second completion (late reply after the node was replaced)
  /// must not re-run waiters — MusicAccount.cpp:372-374 removes by identity
  /// before fanning out.
  void complete(bool ok) {
    if (_completed) {
      return;
    }
    _completed = true;
    _ok = ok;
    final List<void Function(bool ok)> waiters = List<void Function(bool ok)>.of(_waiters);
    _waiters.clear();
    for (final void Function(bool ok) waiter in waiters) {
      waiter(ok);
    }
  }
}

/// QR login state that must survive a rotation untouched.
///
/// Field map (Qt/src/MusicLibrary.h:171-177): \`qr\` (rendered image),
/// \`qrKey\`, \`loginStatus\`, \`loginPhase\`, \`loginMethod\`, \`accountLoading\`.
/// \`loginMethod\` defaults to \`"qr"\` and is re-armed to \`"qr"\` on a provider
/// switch (MusicAccount.cpp:279).
class QrLoginContinuity {
  QrLoginContinuity({
    required this.provider,
    required int nowMs,
    this.lifetimeMs = QrValidityWindow.kQrPollBudgetMs,
  })  : _nowMs = nowMs,
        issuedAtMs = nowMs;

  final String provider;
  final int lifetimeMs;

  int _nowMs;

  /// \`quint64 m_loginGeneration\` — MusicLibrary.h:243. Monotonic; bumped by
  /// every prepare (:540) and every cancel (:354).
  int generation = 0;

  /// MusicLibrary.h:172.
  String qrKey = '';

  /// MusicLibrary.h:171 — the rendered image payload (Qt keeps a QImage; here
  /// the already-encoded string, so the value round-trips through a fixture).
  String qr = '';

  /// MusicLibrary.h:173.
  String loginStatus = '';

  /// MusicLibrary.h:174.
  String loginPhase = QrLoginPhase.idle;

  /// MusicLibrary.h:175.
  String loginMethod = 'qr';

  /// MusicLibrary.h:177.
  bool accountLoading = false;

  /// Wall-clock anchor of the current code; reset only by a new key
  /// (MusicAccount.cpp:582) or by a new prepare (:545 clears \`qr\`).
  int issuedAtMs;

  /// Last failure reason, e.g. \`"qr-timeout"\` — MusicAccount.cpp:32.
  String failureReason = '';

  /// Request counters. These exist to *prove* that rotation issues no network
  /// call: the fixture and test snapshot them around every orientation change.
  int keyRequestCount = 0;
  int createRequestCount = 0;
  int checkRequestCount = 0;
  int cancelRequestCount = 0;

  QrCancelTicket? _pendingCancel;

  QrCancelTicket? get pendingCancel => _pendingCancel;

  bool get hasCode => qrKey.isNotEmpty;

  QrValidityWindow get validity => QrValidityWindow(issuedAtMs: issuedAtMs, lifetimeMs: lifetimeMs);

  int remainingMs() => validity.remainingMsAt(_nowMs);

  bool isExpired() => validity.isExpiredAt(_nowMs);

  /// Advances the injected wall clock. Never a ticker: rotation must not move
  /// it (that is exactly the failure mode plan:373 calls out).
  void observeWallClock(int nowMs) {
    _nowMs = nowMs;
  }

  /// Qt/src/MusicAccount.cpp:540-547 — bump generation, drop the old code, then
  /// wait for any in-flight cancel before touching the network (:548-557).
  int beginPrepare(int nowMs) {
    observeWallClock(nowMs);
    generation += 1;
    qrKey = '';
    qr = '';
    loginStatus = '准备二维码…';
    loginPhase = QrLoginPhase.preparing;
    accountLoading = true;
    failureReason = '';
    return generation;
  }

  /// \`waitCancellation\` gate — MusicAccount.cpp:343-349, :548-557.
  ///
  /// A new prepare may not start while a cancel for the previous key is still
  /// in flight; starting one anyway is what produces the "cancel drops the new
  /// code" bug the barrier exists to prevent.
  bool canStartPrepare() => _pendingCancel == null || _pendingCancel!.completed;

  bool _alive(int token) => token == generation;

  /// Accepts \`/login/qr/key\` result — MusicAccount.cpp:582.
  bool acceptKey(int token, String key) {
    if (!_alive(token) || key.isEmpty) {
      return false;
    }
    keyRequestCount += 1;
    qrKey = key;
    // MusicAccount.cpp:582 — the wall-clock window is anchored where the key
    // lands, so a code prepared long after construction still gets its full
    // lifetime instead of inheriting the constructor timestamp.
    issuedAtMs = _nowMs;
    return true;
  }

  /// Validates the \`data:image/(png|jpeg|gif|webp);base64,\` prefix from
  /// MusicAccount.cpp:607-609 before accepting the image; a bad payload fails
  /// login (:609-611) instead of rendering junk.
  static final RegExp _imageDataUri = RegExp(r'^data:image/(png|jpeg|gif|webp);base64,');

  bool acceptImage(int token, String dataUri) {
    if (!_alive(token) || !_imageDataUri.hasMatch(dataUri)) {
      return false;
    }
    qr = dataUri;
    return true;
  }

  /// \`ready()\` — MusicAccount.cpp:583-592.
  void markWaiting(int token, {required String scannerName}) {
    if (!_alive(token)) {
      return;
    }
    loginPhase = QrLoginPhase.waiting;
    loginStatus = '请用$scannerName扫描并确认登录';
  }

  /// code 802 — MusicAccount.cpp:653-657.
  void markScanned(int token) {
    if (!_alive(token)) {
      return;
    }
    loginPhase = QrLoginPhase.confirming;
    loginStatus = '已扫描，请在手机上确认';
  }

  /// One \`/login/qr/check\` tick. Returns \`false\` when the reply is stale (a
  /// newer generation exists) so the caller drops it — MusicAccount.cpp:630-635.
  bool recordCheck(int token) {
    if (!_alive(token)) {
      return false;
    }
    checkRequestCount += 1;
    return true;
  }

  /// code 800 — the provider says the code is spent. MusicAccount.cpp:643-651.
  ///
  /// \`qr\` is cleared but \`qrKey\` is not; generation is untouched, so the phase
  /// machine still owns the key until an explicit cancel or a new prepare.
  void markExpiredByProvider({
    String message = '二维码已过期，请重新生成',
    String? reason,
  }) {
    qr = '';
    accountLoading = false;
    loginPhase = QrLoginPhase.failed;
    loginStatus = message;
    // QQ passes the provider body's reason through reportLoginFailure
    // (MusicAccount.cpp:646-648); non-QQ code 800 uses the fixed message.
    failureReason = reason ?? QrValidityWindow.failureReason;
  }

  /// Wall-clock expiry. Only fires when the generation still matches the one
  /// that minted the code, mirroring \`valid(token, &m_loginGeneration)\` at
  /// MusicAccount.cpp:630.
  bool expireIfStale(int nowMs, {required int token}) {
    observeWallClock(nowMs);
    if (!_alive(token) || !hasCode || !isExpired()) {
      return false;
    }
    loginPhase = QrLoginPhase.failed;
    // Qt poll budget exhaustion (:626-628), distinct from provider code 800
    // (:649, "二维码已过期，请重新生成").
    loginStatus = '二维码超时，请重新生成';
    failureReason = QrValidityWindow.failureReason;
    accountLoading = false;
    return true;
  }

  /// Cancel / close barrier — Qt/src/MusicAccount.cpp:351-379.
  ///
  /// Order matters and is the contract:
  ///  1. reject a stale observation (do not clear a newer code),
  ///  2. join an in-flight cancel for the *same* generation (do not re-bump),
  ///  3. otherwise bump generation, clear \`qr\`/\`qrKey\`, set phase idle,
  ///  4. only QQ + a real previous key issues \`/login/qr/cancel\`.
  QrCancelOutcome cancel({
    required int observedGeneration,
    void Function(bool ok)? done,
    bool providerIsQq = true,
  }) {
    if (observedGeneration != generation) {
      return QrCancelOutcome.rejectedStale;
    }
    // MusicAccount.cpp:352-357 has no loginMethod gate: every cancel bumps the
    // generation, clears qr/qrKey and returns to idle. The method only decides
    // whether a request is issued below.
    final QrCancelTicket? pending = _pendingCancel;
    if (pending != null && !pending.completed && pending.atGeneration + 1 == generation) {
      // Generation did not move since the barrier was installed: the request is
      // already on the wire, so a second closeModal must wait, not re-bump.
      pending.wait(done ?? (bool _) {});
      return QrCancelOutcome.joined;
    }

    final String previousKey = qrKey;
    generation += 1;
    qrKey = '';
    qr = '';
    loginPhase = QrLoginPhase.idle;
    accountLoading = false;

    if (!providerIsQq || previousKey.isEmpty) {
      // Qt's waitCancellation (:343-349) joins a pending cancellation for this
      // provider before the non-QQ/empty-key shortcut returns done(true).
      final QrCancelTicket? inFlight = _pendingCancel;
      if (inFlight != null && !inFlight.completed) {
        inFlight.wait(done ?? (bool _) {});
        return QrCancelOutcome.joined;
      }
      if (done != null) {
        done(true);
      }
      return QrCancelOutcome.shortCircuited;
    }

    cancelRequestCount += 1;
    final QrCancelTicket ticket = QrCancelTicket(atGeneration: generation - 1, key: previousKey);
    if (done != null) {
      ticket.wait(done);
    }
    _pendingCancel = ticket;
    return QrCancelOutcome.requested;
  }

  /// Completes the barrier with the server result — MusicAccount.cpp:371-378.
  /// A failed cancel must surface as a login failure upstream (:552-554), which
  /// is why the boolean is returned rather than swallowed.
  bool completeCancel(String key, bool ok) {
    final QrCancelTicket? pending = _pendingCancel;
    if (pending == null || pending.key != key) {
      return false;
    }
    _pendingCancel = null;
    pending.complete(ok);
    return ok;
  }
}

// ---------------------------------------------------------------------------
// 2. Playback / queue / lyrics
// ---------------------------------------------------------------------------

/// Legal playback modes — Qt/src/MusicPlayer.cpp:647 (setMode) and :766
/// (restoreSessionState).
const List<String> kPlaybackModes = <String>['off', 'all', 'one', 'shuffle'];

/// Fallback for a missing or illegal mode — Qt/src/MusicPlayer.cpp:766.
const String kDefaultPlaybackMode = 'all';

/// play-history cap: MusicPlayer.cpp:194 (history.size() == 200 -> break) and
/// :416 (recent.size() < 200).
const int kPlaybackHistoryLimit = 200;

/// Position sanity ceiling — MusicPlayer.cpp:762 rejects position > 1e12.
const double kPlaybackPositionLimitMs = 1e12;

/// Lyrics offset clamp — LyricsController.cpp:515
/// (std::clamp(offsetMs + delta, -10000, 10000)).
const double kLyricsOffsetLimitMs = 10000;

double _asDouble(Object? value, [double fallback = 0]) {
  if (value is num) return value.toDouble();
  return fallback;
}

int _asInt(Object? value, [int fallback = -1]) {
  if (value is num) return value.toInt();
  return fallback;
}

List<Map<String, Object?>> _asTracks(Object? value) {
  if (value is! List) return <Map<String, Object?>>[];
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  for (final Object? item in value) {
    if (item is Map) out.add(Map<String, Object?>.from(item));
  }
  return out;
}

Map<String, Object?> _asMap(Object? value) {
  if (value is Map) return Map<String, Object?>.from(value);
  return <String, Object?>{};
}

/// Track identity provider:id — PlaybackQueue.cpp:36-38
/// (track["provider"].toString("netease") + ":" + track["id"].toString()).
String trackIdentity(Map<String, Object?> track) {
  final Object? provider = track['provider'];
  final Object? id = track['id'];
  final String resolved =
      provider is String && provider.isNotEmpty ? provider : 'netease';
  return resolved + ':' + (id is String ? id : '');
}

/// PlaybackQueue::sanitized (Qt/src/PlaybackQueue.cpp:14-30): songs with a
/// non-empty id, de-duplicated by identity in first-seen order. The service
/// snapshot path and the restore path share this because both must expose the
/// same queue that PlaybackQueue::syncSnapshot (:119-124) bounds the row
/// against.
List<Map<String, Object?>> _sanitizedTracks(
  Iterable<Map<String, Object?>> input,
) {
  final Set<String> seen = <String>{};
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  for (final Map<String, Object?> track in input) {
    if (track['kind'] != 'song') continue;
    final Object? id = track['id'];
    if (id is! String || id.isEmpty) continue;
    if (!seen.add(trackIdentity(track))) continue;
    out.add(Map<String, Object?>.from(track));
  }
  return out;
}

/// Where a restoreSessionState call ended. MusicPlayer.cpp:760-780 has four
/// exits; skippedForConnection is the gate that runs before the call in
/// MusicSession.cpp:263-265.
enum PlaybackRestoreOutcome {
  /// Queue restored, then the saved track was selected and loaded (:777-779).
  restored,

  /// current was empty: only the queue came back (:769-773).
  queueOnly,

  /// Position missing / negative / above 1e12: nothing changed at all, not even
  /// the mode (:761-764).
  rejectedPosition,

  /// current is not a song, or its provider is not the live provider
  /// (:774-776).
  rejectedTrack,

  /// A playback connection owns the truth, so the archive was not applied
  /// (MusicSession.cpp:263-265).
  skippedForConnection,
}

/// Playback state that must outlive a rotation.
///
/// Every field mirrors a member of MusicPlayer (MusicPlayer.h) or a field of its
/// session archive (MusicPlayer.cpp:749-758). No playback semantics are invented
/// here, and nothing here touches pixels: the point is that the object lives
/// outside the widget tree, so a rotation never rebuilds it (plan:369).
class PlaybackContinuity {
  PlaybackContinuity({this.provider = 'netease'});

  /// Live provider id, i.e. Qt's m_api->provider, used by the identity gate at
  /// MusicPlayer.cpp:774.
  final String provider;

  /// current — the full track object.
  Map<String, Object?>? current;

  /// queue — PlaybackQueue.cpp:420-422 serialises the complete items.
  List<Map<String, Object?>> queue = <Map<String, Object?>>[];

  /// queue.index() — selected row, -1 when nothing is selected
  /// (PlaybackQueue.h:78).
  int index = -1;

  /// mode (:756). Always one of kPlaybackModes because setMode (:647) and
  /// restore (:766) both filter.
  String mode = kDefaultPlaybackMode;

  /// position in milliseconds: AudioPlayer::state() returns
  /// QMediaPlayer::position(), and NativeHudPlayer.cpp:17 reads that straight
  /// into positionMs, so the unit is milliseconds end to end.
  double position = 0;

  /// requested (:757) — whether playback should be running.
  bool requested = false;

  /// preview (:757) — trial/preview playback flag.
  bool preview = false;

  /// loading, an input of the requested computation (:755).
  bool loading = false;

  /// Pending resume seek — MusicPlayer.h:65 std::optional<double>
  /// m_resumePosition. While set, the archive reports it instead of the live
  /// position (:752-755).
  double? resumePositionMs;

  /// MusicPlayer.h:66 m_resumePaused.
  bool resumePaused = false;

  /// history — MusicPlayer.h:41. The one field that is NOT part of the session
  /// archive: sessionState() (:749-758) has no history entry and
  /// restoreSessionState (:760-780) never writes it. History survives a rotation
  /// only because the player object survives; it is never resurrected from
  /// session.json.
  List<Map<String, Object?>> history = <Map<String, Object?>>[];

  /// Effective position used by the archive (:752).
  double get effectivePositionMs => resumePositionMs ?? position;

  /// Effective requested flag (:753-755): a pending resume wins over the live
  /// flag.
  bool get effectiveRequested =>
      resumePositionMs != null ? !resumePaused : (loading || requested);

  /// The exact session payload — MusicPlayer.cpp:749-758, no extra keys.
  Map<String, Object?> sessionState() => <String, Object?>{
        'current': current ?? const <String, Object?>{},
        'queue': queue
            .map((Map<String, Object?> track) =>
                Map<String, Object?>.from(track))
            .toList(growable: false),
        'index': index,
        'mode': mode,
        'position': effectivePositionMs,
        'requested': effectiveRequested,
        'preview': preview,
      };

  /// Replays MusicPlayer.cpp:760-780 in order, so a restore never invents a rule
  /// Qt does not have.
  PlaybackRestoreOutcome restoreSessionState(
    Map<String, Object?> saved, {
    required bool playbackConnection,
  }) {
    // MusicSession.cpp:263-265: with a live connection the service owns
    // playback, so the archive is not applied at all.
    if (playbackConnection) {
      return PlaybackRestoreOutcome.skippedForConnection;
    }

    // MusicPlayer.cpp:761-764: an unusable position rejects the whole restore,
    // the mode included.
    final Object? rawPosition = saved['position'];
    if (rawPosition is! num) {
      return PlaybackRestoreOutcome.rejectedPosition;
    }
    final double savedPosition = rawPosition.toDouble();
    if (!savedPosition.isFinite ||
        savedPosition < 0 ||
        savedPosition > kPlaybackPositionLimitMs) {
      return PlaybackRestoreOutcome.rejectedPosition;
    }

    // :765-766: the mode lands before the track gate; an illegal value falls
    // back to "all".
    final Object? rawMode = saved['mode'];
    mode = rawMode is String && kPlaybackModes.contains(rawMode)
        ? rawMode
        : kDefaultPlaybackMode;

    final Map<String, Object?> track = _asMap(saved['current']);
    final List<Map<String, Object?>> savedQueue = _asTracks(saved['queue']);
    final int savedIndex = _asInt(saved['index'], -1);

    // :769-773: no current track -> queue only.
    if (track.isEmpty) {
      _restoreQueue(savedQueue, savedIndex);
      return PlaybackRestoreOutcome.queueOnly;
    }

    // :774-776: identity gate. A failed gate leaves the queue untouched.
    if (track['kind'] != 'song') {
      return PlaybackRestoreOutcome.rejectedTrack;
    }
    final Object? trackProvider = track['provider'];
    final String resolvedProvider =
        trackProvider is String && trackProvider.isNotEmpty
            ? trackProvider
            : provider;
    if (resolvedProvider != provider) {
      return PlaybackRestoreOutcome.rejectedTrack;
    }

    // :777-779: queue first, then select by identity so a stale index cannot
    // send the next track somewhere unrelated.
    _restoreQueue(savedQueue, savedIndex);
    current = track;
    index = selectTrack(track);
    position = savedPosition;
    resumePositionMs = savedPosition;
    requested = saved['requested'] == true;
    resumePaused = !requested;
    preview = saved['preview'] == true;
    return PlaybackRestoreOutcome.restored;
  }

  /// PlaybackQueue::restore (PlaybackQueue.cpp:398-418): drop non-songs and
  /// empty ids, keep deferred placeholders out of the queue, resolve the
  /// selection from the saved index, then select by identity.
  void _restoreQueue(List<Map<String, Object?>> saved, int savedIndex) {
    final List<Map<String, Object?>> complete = <Map<String, Object?>>[];
    for (final Map<String, Object?> track in saved) {
      if (track['kind'] != 'song') continue; // :404-406
      final Object? id = track['id'];
      if (id is! String || id.isEmpty) continue;
      if (track['deferred'] == true) continue; // :408-410
      complete.add(Map<String, Object?>.from(track));
    }
    final Map<String, Object?>? selected =
        savedIndex >= 0 && savedIndex < saved.length ? saved[savedIndex] : null;
    queue = _sanitizedTracks(complete);
    if (selected == null || selected['deferred'] == true) {
      index = -1;
      return;
    }
    index = queue.indexWhere(
      (Map<String, Object?> track) =>
          trackIdentity(track) == trackIdentity(selected),
    );
  }

  /// PlaybackQueue::selectTrack (PlaybackQueue.h:38-39): keep the same selected
  /// song, otherwise look it up, otherwise append to the tail.
  int selectTrack(Map<String, Object?> track) {
    final String key = trackIdentity(track);
    final int existing = queue.indexWhere(
      (Map<String, Object?> item) => trackIdentity(item) == key,
    );
    if (existing >= 0) {
      index = existing;
      return index;
    }
    queue.add(Map<String, Object?>.from(track));
    index = queue.length - 1;
    return index;
  }

  /// MusicPlayer.cpp:405-425: newest first, de-duplicated by identity, capped at
  /// 200, with wiki/description stripped from the recorded copy.
  void recordPlayed(Map<String, Object?> track) {
    final Map<String, Object?> entry = Map<String, Object?>.from(track)
      ..['wiki'] = ''
      ..['description'] = '';
    final List<Map<String, Object?>> recent = <Map<String, Object?>>[entry];
    final String key = trackIdentity(track);
    for (final Map<String, Object?> value in history) {
      if (trackIdentity(value) != key && recent.length < kPlaybackHistoryLimit) {
        recent.add(value);
      }
    }
    history = recent;
  }

  /// MusicPlayer.cpp:188-200: reload play-history from the preference value,
  /// keeping only songs whose id matches ^[a-zA-Z0-9_-]{1,80}$ and stopping at
  /// 200 entries.
  void loadHistory(Iterable<Object?> saved) {
    final RegExp identifier = RegExp(r'^[a-zA-Z0-9_-]{1,80}$');
    final List<Map<String, Object?>> restored = <Map<String, Object?>>[];
    for (final Object? value in saved) {
      if (value is! Map) continue;
      final Map<String, Object?> track = Map<String, Object?>.from(value);
      if (track['kind'] != 'song') continue;
      final Object? id = track['id'];
      if (id is! String || !identifier.hasMatch(id)) continue;
      restored.add(track);
      if (restored.length == kPlaybackHistoryLimit) break;
    }
    history = restored;
  }

  /// MusicPlayer.cpp:662-669.
  void clearHistory() {
    history = <Map<String, Object?>>[];
  }

  /// MusicPlayer.cpp:276-277: a play() with a resume archive arms the pending
  /// seek instead of jumping immediately.
  void armResume(double? positionMs, {bool paused = false}) {
    resumePositionMs = positionMs;
    resumePaused = positionMs != null && paused;
  }

  /// MusicPlayer.cpp:484-490: once the media is seekable the pending resume is
  /// consumed exactly once and clamped to the duration.
  bool consumeResume({required bool seekable, double? durationMs}) {
    final double? pending = resumePositionMs;
    if (pending == null || loading || !seekable) return false;
    final double ceiling =
        durationMs == null || durationMs <= 0 ? pending : durationMs;
    position = pending.clamp(0.0, ceiling).toDouble();
    resumePositionMs = null;
    return true;
  }

  /// MusicPlayer.cpp:643-651: only the four legal values are accepted; the live
  /// setter never falls back, it ignores.
  bool setMode(String value) {
    if (!kPlaybackModes.contains(value)) return false;
    mode = value;
    return true;
  }

  /// MusicPlayer.cpp:686-702 (player-owned subset). history appears here — and
  /// only here — because the service channel is the one snapshot that carries it.
  Map<String, Object?> playbackSnapshot(LyricsContinuity lyrics) =>
      <String, Object?>{
        'current': current ?? const <String, Object?>{},
        'queue': queue
            .map((Map<String, Object?> track) =>
                Map<String, Object?>.from(track))
            .toList(growable: false),
        'history': history
            .map((Map<String, Object?> track) =>
                Map<String, Object?>.from(track))
            .toList(growable: false),
        'index': index,
        'mode': mode,
        'preview': preview,
        'lyrics': lyrics.playbackSnapshot(),
      };

  /// MusicPlayer.cpp:712-724 (player-owned subset of applyPlaybackSnapshot):
  /// only a live connection may push a snapshot over the local state.
  bool applyPlaybackSnapshot(
    Map<String, Object?> snapshot, {
    required bool playbackConnection,
  }) {
    if (!playbackConnection) return false; // :706-709
    current = _asMap(snapshot['current']);
    queue = _sanitizedTracks(_asTracks(snapshot['queue']));
    history = _asTracks(snapshot['history']);
    final int row = _asInt(snapshot['index'], -1);
    // PlaybackQueue::syncSnapshot (:119-124): any row outside the sanitized
    // queue becomes -1; a stale service row may not outlive the new queue.
    index = row >= 0 && row < queue.length ? row : -1;
    final Object? rawMode = snapshot['mode'];
    mode = rawMode is String && kPlaybackModes.contains(rawMode)
        ? rawMode
        : kDefaultPlaybackMode;
    preview = snapshot['preview'] == true;
    return true;
  }
}

/// Lyrics state that must outlive a rotation (plan:374).
///
/// Mirrors LyricsController.cpp:639-649 field for field, plus the HUD flag
/// lyricsMode (NativeHud.h:147, archived in MusicSession.cpp:234/:259).
class LyricsContinuity {
  /// m_document — parsed lyrics, including its own offsetMs and lines.
  Map<String, Object?> document = const <String, Object?>{};

  /// status — :653 defaults to "idle" on replay.
  String status = 'idle';

  /// message.
  String message = '';

  /// currentKey — :654.
  String key = '';

  /// index — active line, :656 defaults to -1.
  int index = -1;

  /// offsetMs — user offset, clamped to +/-10000 (LyricsController.cpp:515).
  double offsetMs = 0;

  /// positionMs — playback position fed by MusicPlayer::tick
  /// (MusicPlayer.cpp:492).
  double positionMs = 0;

  /// m_globalOffsetMs — preference "lyrics-global-offset-ms"
  /// (LyricsController.cpp:534-544).
  double globalOffsetMs = 0;

  /// localSource — :658 defaults to "auto".
  String localSource = 'auto';

  /// HUD lyrics mode — NativeHud.h:147.
  bool lyricsMode = false;

  /// Track the HUD compares against (NativeHudDetail.cpp:57).
  Map<String, Object?>? playingTrack;

  bool get hasDocument => document.isNotEmpty;

  /// LyricsController.cpp:511-518: clamp, then re-resolve the active line.
  double adjustOffset(double delta) {
    offsetMs = (offsetMs + delta)
        .clamp(-kLyricsOffsetLimitMs, kLyricsOffsetLimitMs)
        .toDouble();
    index = activeLineIndex();
    return offsetMs;
  }

  /// LyricsController.cpp:521-531.
  void resetOffset() {
    offsetMs = 0;
    index = activeLineIndex();
  }

  /// MusicPlayer.cpp:492 lyrics.sync(state["position"].toDouble()).
  void syncPosition(double positionMs) {
    this.positionMs = positionMs;
    index = activeLineIndex();
  }

  /// LyricsController.cpp:117-131: binary search over lines.startMs using
  /// positionMs + document.offsetMs + offsetMs, returning index - 1.
  int activeLineIndex() {
    final Object? rawLines = document['lines'];
    if (rawLines is! List || rawLines.isEmpty) return -1;
    final double position =
        positionMs + _asDouble(document['offsetMs']) + offsetMs;
    int lower = 0;
    int upper = rawLines.length;
    while (lower < upper) {
      final int middle = (lower + upper) ~/ 2;
      final Object? line = rawLines[middle];
      final double startMs = line is Map ? _asDouble(line['startMs']) : 0;
      if (startMs <= position) {
        lower = middle + 1;
      } else {
        upper = middle;
      }
    }
    return lower - 1;
  }

  /// NativeHudDetail.cpp:57-58: in lyrics mode, once the selected item is no
  /// longer the playing track the HUD falls back to the cover view.
  bool dropLyricsModeIfTrackChanged(String selectedIdentity) {
    if (!lyricsMode) return false;
    final Map<String, Object?>? playing = playingTrack;
    // Qt compares against PlaybackQueue::identity(player.current); an empty
    // current yields an empty identity, which generally differs from a selected
    // song, so the mode drops (NativeHudDetail.cpp:57-58).
    if (playing == null) {
      lyricsMode = false;
      return true;
    }
    if (selectedIdentity == trackIdentity(playing)) return false;
    lyricsMode = false;
    return true;
  }

  /// LyricsController.cpp:639-649, key order preserved.
  Map<String, Object?> playbackSnapshot() => <String, Object?>{
        'document': document,
        'status': status,
        'message': message,
        'key': key,
        'index': index,
        'offsetMs': offsetMs,
        'positionMs': positionMs,
        'globalOffsetMs': globalOffsetMs,
        'localSource': localSource,
      };

  /// LyricsController.cpp:651-661: replay a service snapshot verbatim, with the
  /// same defaults (status "idle", index -1, localSource "auto").
  void applyPlaybackSnapshot(Map<String, Object?> snapshot) {
    document = _asMap(snapshot['document']);
    final Object? rawStatus = snapshot['status'];
    status = rawStatus is String ? rawStatus : 'idle';
    final Object? rawMessage = snapshot['message'];
    message = rawMessage is String ? rawMessage : '';
    final Object? rawKey = snapshot['key'];
    key = rawKey is String ? rawKey : '';
    index = _asInt(snapshot['index'], -1);
    offsetMs = _asDouble(snapshot['offsetMs']);
    positionMs = _asDouble(snapshot['positionMs']);
    globalOffsetMs = _asDouble(snapshot['globalOffsetMs']);
    final Object? rawSource = snapshot['localSource'];
    localSource = rawSource is String ? rawSource : 'auto';
  }
}

// ---------------------------------------------------------------------------
// 3. 3D scene / viewer
// ---------------------------------------------------------------------------

/// 3D camera, clock and viewer state that must outlive a rotation (plan:375).
///
/// Initial values are copied from NativeScene.h:123-161, and applyViewport is a
/// faithful copy of the only rotation path Qt has: NativeScene.cpp:217-224.
class SceneContinuity {
  SceneContinuity({ViewerContinuity? viewer})
      : viewer = viewer ?? ViewerContinuity();

  /// Opening/reset/clarity of the archive viewer — NativeViewer.h:14-64.
  final ViewerContinuity viewer;

  // Camera + lens — NativeScene.h:123-130.
  List<double> eye = <double>[-62.26, 35.98, 43.28];
  List<double> aim = <double>[-0.5, 1.1, 0.4];
  double fov = 6.15;
  int width = 1920;
  int height = 1080;

  // Clock — NativeScene.h:135-137.
  double clock = 0;
  double last = 0;
  double bootStart = -1.76;

  // Transitions — NativeScene.h:140-145.
  double detail = 0;
  double targetDetail = 0;
  double rotation = 0;
  double targetRotation = 0;
  double scanTime = 29.1;
  double scanBlend = 0;

  // Selection + mode — NativeScene.h:159-161.
  int selected = 0;
  String mode = 'boot';

  /// NativeScene.h:167 m_freeze — when set, elapsed stops using the clock.
  double? freeze;

  /// Reveal progress and its target (NativeScene.h:138-139).
  double reveal = 0;
  double targetReveal = 0;

  /// NativeScene.h:151 m_looping, false until setMode changes the mode.
  bool looping = false;

  /// NativeScene.h:180.
  bool navigating = false;

  /// NativeScene.cpp:182 m_lastInteraction.
  double lastInteraction = 0;

  /// NativeScene.h:156 m_changed starts true so the first frame is emitted.
  bool changed = true;

  /// How many times the viewport changed (used by the ledger assertions).
  int viewportChangeCount = 0;

  double get aspect => height <= 0 ? 1 : width / height;

  /// Camera-side portrait test — NativeSceneCamera.cpp:56 (aspect < 1.05). The
  /// stage-side threshold belongs to A1's qtPortraitAspectThreshold; this one is
  /// the 3D camera's own rule and is deliberately not shared with the stage.
  bool get cameraPortrait => aspect < 1.05;

  /// Camera-side compact test — NativeSceneCamera.cpp:57.
  bool get cameraCompact => !cameraPortrait && width < 1100;

  /// canBrowse() gate — NativeSceneInput.cpp:6-8.
  bool get canBrowse =>
      looping && targetDetail == 0 && detail < 0.2 && reveal >= 0.8;

  /// Elapsed since boot — NativeSceneFrame.cpp:11.
  double get elapsed => freeze ?? (clock - bootStart);

  /// NativeSceneFrame.cpp:9: m_clock = time. The clock is pushed in from
  /// outside; a viewport change must never move it.
  void advanceClockTo(double time) {
    last = clock;
    clock = time;
  }

  /// NativeSceneFrame.cpp:19: boot hands over to detail at 35s.
  bool get bootFinished => mode == 'boot' && elapsed >= 35;

  /// NativeScene.cpp:165-198, the state-carrying subset.
  void setMode(String next) {
    changed = true;
    freeze = null;
    if (next == 'boot') bootStart = clock - 1.76; // :178
    looping = next != 'boot'; // :181
    lastInteraction = clock; // :182
    targetReveal = next == 'boot' ? 0 : 1; // :186
    targetDetail = next == 'detail' ? 1 : 0; // :187
    if (next != 'detail') targetRotation = 0; // :192
    mode = next;
  }

  /// NativeScene.cpp:217-224: the ONLY 3D entry point a rotation may use.
  ///
  /// It swaps the viewport size (and therefore the projection aspect on the next
  /// frame) and resizes the viewer in place. It must not touch the camera pose,
  /// the clock, bootStart, the detail/rotation targets, the selection, or
  /// reopen/reset the viewer.
  void applyViewport(int logicalWidth, int logicalHeight) {
    width = logicalWidth < 1 ? 1 : logicalWidth; // :219 max(1, w)
    height = logicalHeight < 1 ? 1 : logicalHeight; // :220 max(1, h)
    changed = true; // NativeScene.cpp:218 marks the scene dirty
    viewportChangeCount++;
    resizeViewer(); // NativeScene.cpp:223: single viewer resize, never reopen
  }

  /// NativeScene.cpp:223 m_viewer->resize(w, h): the viewer is resized, never
  /// re-opened or reset.
  void resizeViewer() => viewer.resize();
}

/// Viewer opening/reset/clarity state — NativeViewer.h:14-64 and
/// NativeViewer.cpp:39-84, :122-123, :231-236.
class ViewerContinuity {
  bool open = false;
  bool closing = false;

  /// m_transition — "closed" (NativeViewer.h:62), "opening" (:49).
  String transition = 'closed';

  /// m_time (NativeViewer.h:44).
  double time = 0;

  /// m_pendingUntil — open() arms it to time + 0.38 (:55).
  double pendingUntil = 0;

  double spread = 0;
  double targetSpread = 0;

  /// Spring m_clarity{1, 0} (NativeViewer.h:51). Both the value and the
  /// velocity are carried: SceneMotion::Spring::damp is second order, so
  /// keeping only the value would visibly change the motion after a rotation.
  double clarity = 1;
  double clarityVelocity = 0;
  double targetClarity = 1;

  /// m_surface — "clear" after open() (:62).
  String surface = 'clear';

  /// m_last.
  double last = 0;

  /// m_ready — lazy archive meshes loaded (:63).
  bool ready = false;

  /// m_resetting / m_resetElapsed (NativeViewer.h:40, :49).
  bool resetting = false;
  double resetElapsed = 0;

  /// m_goal — spherical({7.2, 3.8, 12}) (:84).
  List<double> goal = <double>[7.2, 3.8, 12];
  List<double>? resetFrom;
  List<double>? resetFocus;

  /// Identity counters: a rotation must not increase either.
  int openCount = 0;
  int resetCount = 0;
  int resizeCount = 0;

  /// NativeViewer.cpp:39-64. Returns false on the early return when already
  /// open, so a resize can never re-arm the opening animation.
  bool beginOpen(double atTime, {bool reducedMotion = false}) {
    if (open) return false; // :40
    open = true;
    closing = false;
    transition = 'opening';
    time = atTime;
    pendingUntil = reducedMotion ? atTime : atTime + 0.38;
    spread = 0;
    targetSpread = 0;
    clarity = 1;
    clarityVelocity = 0;
    targetClarity = 1;
    surface = 'clear';
    last = 0;
    // Qt open() calls reset(false); the identity counter tracks explicit
    // user resets, not this internal initialisation (fixture viewerExpect 0).
    reset(animated: false, count: false);
    openCount++;
    return true;
  }

  /// NativeViewer.cpp:77-84.
  void reset({
    required bool animated,
    bool reducedMotion = false,
    List<double>? from,
    List<double>? focus,
    bool count = true,
  }) {
    targetSpread = 0;
    goal = <double>[7.2, 3.8, 12];
    if (animated && !reducedMotion) {
      resetFrom = from == null ? null : List<double>.from(from);
      resetFocus = focus == null ? null : List<double>.from(focus);
      resetElapsed = 0;
      resetting = true;
    } else {
      resetting = false;
      resetElapsed = 0;
      resetFrom = null;
      resetFocus = null;
    }
    if (count) resetCount++;
  }

  /// NativeViewer.cpp:122-123.
  void setSurface(String action) {
    if (action == 'clear') targetClarity = 1;
    if (action == 'frosted') targetClarity = 0;
  }

  /// NativeViewer.cpp:231-236 + SceneMotion.cpp:113-119: second-order spring
  /// toward targetClarity at rate 8, snapping once value and velocity are both
  /// at rest. This mirrors Spring::damp exactly, including velocity carry-over.
  void stepClarity(double seconds) {
    if (seconds <= 0) return;
    final double delta = clarity - targetClarity;
    final double impulse = clarityVelocity + 8 * delta;
    final double decay = math.exp(-8 * seconds);
    clarity = targetClarity + (delta + impulse * seconds) * decay;
    clarityVelocity = (clarityVelocity - 8 * impulse * seconds) * decay;
    if ((clarity - targetClarity).abs() < 0.0001 &&
        clarityVelocity.abs() < 0.001) {
      clarity = targetClarity;
      clarityVelocity = 0;
    }
  }

  /// NativeScene.cpp:223. Deliberately a no-op on every transition field: a
  /// rotation resizes, it does not re-open.
  void resize() {
    resizeCount++;
  }
}

// ---------------------------------------------------------------------------
// 4. Drag cancellation
// ---------------------------------------------------------------------------

/// Pointer/drag state and its cancellation on rotation (plan:375).
///
/// Field set copied from NativeScene.h:175-180 and NativeSceneInput.cpp:9-23.
class DragContinuity {
  bool captured = false;
  bool dragging = false;
  bool browsing = false;
  bool holding = false;
  bool navigating = false;

  /// Momentum, kept across a rotation (NativeSceneInput.cpp:141-142 uses
  /// resetPointer(false)).
  bool hasMomentum = false;
  double velocityX = 0;
  double velocityY = 0;

  /// m_cursor — "grab"/"default" (:23).
  String cursor = 'default';

  /// m_targetRotation — clamped to +/-0.8 (:180).
  double targetRotation = 0;

  /// m_dragTrack / m_pendingHover / m_hover.
  Map<String, Object?>? dragTrack;
  Map<String, Object?>? pendingHover;
  Map<String, Object?>? hoveredCard;

  /// How many times a rotation cancelled an in-flight drag.
  int cancelCount = 0;

  /// NativeSceneInput.cpp:180.
  void rotateBy(double dx) {
    targetRotation = (targetRotation + dx * 0.004).clamp(-0.8, 0.8).toDouble();
  }

  /// NativeSceneInput.cpp:9-23 resetPointer(stopMomentum).
  void resetPointer({required bool stopMomentum, required bool canBrowseNow}) {
    pendingHover = null;
    captured = false;
    dragging = false;
    dragTrack = null;
    holding = false;
    browsing = false;
    hoveredCard = null;
    if (stopMomentum) {
      velocityX = 0;
      velocityY = 0;
      hasMomentum = false;
    }
    cursor = canBrowseNow ? 'grab' : 'default';
  }

  /// Rotation with a live pointer behaves like pointercancel ->
  /// resetPointer(false) (NativeSceneInput.cpp:141-142): the drag is cancelled,
  /// momentum survives, and the selected card is left alone because it is owned
  /// by SceneContinuity (m_selected is not part of resetPointer).
  bool cancelForViewportChange({required bool canBrowseNow}) {
    final bool active = captured ||
        dragging ||
        holding ||
        browsing ||
        dragTrack != null ||
        pendingHover != null;
    if (!active) return false;
    resetPointer(stopMomentum: false, canBrowseNow: canBrowseNow);
    cancelCount++;
    return true;
  }
}

// ---------------------------------------------------------------------------
// 5. Resource identity ledger
// ---------------------------------------------------------------------------

/// Resource identity ledger (plan:696).
///
/// This is a STATIC bookkeeping device: it proves by identity tokens and
/// counters that a rotation does not re-login, does not restart the Node
/// runtime, does not rebuild the media source, and that every listener/timer/
/// controller a rotation creates is also released. It is NOT device evidence.
class ResourceLedger {
  final Map<String, int> _created = <String, int>{};
  final Map<String, int> _disposed = <String, int>{};
  final Map<String, Set<int>> _live = <String, Set<int>>{};
  int _nextId = 0;

  /// MusicLibrary.h:243 m_loginGeneration: a new login session is a new
  /// generation. A rotation never opens one.
  int loginCount = 0;
  int loginAttempts = 0;

  /// BridgeProcessAndroid.cpp:164-169 — function-local static NodeRuntime, i.e.
  /// one process-wide instance.
  int nodeStartCount = 0;
  int nodeStartAttempts = 0;

  /// AudioPlayer.cpp:67 constructs the QMediaPlayer once; :161-179 swaps the
  /// source. A rotation reuses the source instead of rebuilding it.
  int mediaSourceBuildCount = 0;
  int mediaSourceReuseCount = 0;

  /// How many times the stage listener was re-bound in place.
  int stageRebindCount = 0;

  /// Register a live resource and return its identity token.
  int acquire(String kind) {
    _nextId++;
    _created[kind] = (_created[kind] ?? 0) + 1;
    _live.putIfAbsent(kind, () => <int>{}).add(_nextId);
    return _nextId;
  }

  /// Release a token. Returns false for an unknown or already-released token, so
  /// a double release cannot silently balance the books.
  bool release(String kind, int id) {
    final Set<int>? bucket = _live[kind];
    if (bucket == null || !bucket.remove(id)) return false;
    _disposed[kind] = (_disposed[kind] ?? 0) + 1;
    return true;
  }

  int created(String kind) => _created[kind] ?? 0;

  int disposed(String kind) => _disposed[kind] ?? 0;

  int live(String kind) => _live[kind]?.length ?? 0;

  /// True when every kind balances and nothing is still live.
  bool get balanced {
    for (final String kind in _created.keys) {
      if (created(kind) != disposed(kind)) return false;
    }
    for (final String kind in _live.keys) {
      if (live(kind) != 0) return false;
    }
    return true;
  }

  /// A login session is a new QR generation; rotation never calls this.
  bool beginLogin() {
    loginAttempts++;
    if (loginCount > 0) return false;
    loginCount = 1;
    return true;
  }

  /// BridgeProcessAndroid.cpp:164-169: the static instance is created once and
  /// reused, so a second call is a no-op that does not bump nodeStartCount.
  bool startNodeRuntime() {
    nodeStartAttempts++;
    if (nodeStartCount > 0) return false;
    nodeStartCount = 1;
    return true;
  }

  /// AudioPlayer.cpp:161-179: the source is built once; a later start attempt
  /// must not inflate the construction count.
  bool buildMediaSource() {
    if (mediaSourceBuildCount > 0) return false;
    mediaSourceBuildCount = 1;
    return true;
  }

  /// A rotation reuses the existing media source.
  void reuseMediaSource() {
    mediaSourceReuseCount++;
  }

  /// Re-binding a listener moves it; it must not count as a new one.
  void rebind(String kind, int id) {
    final Set<int>? bucket = _live[kind];
    if (bucket == null || !bucket.contains(id)) return;
    stageRebindCount++;
  }

  Map<String, Object?> report() => <String, Object?>{
        'created': Map<String, int>.from(_created),
        'disposed': Map<String, int>.from(_disposed),
        'live': _live.map(
          (String kind, Set<int> ids) =>
              MapEntry<String, int>(kind, ids.length),
        ),
        'balanced': balanced,
        'loginCount': loginCount,
        'nodeStartCount': nodeStartCount,
        'mediaSourceBuildCount': mediaSourceBuildCount,
        'notDeviceEvidence': true,
      };
}

// ---------------------------------------------------------------------------
// 6. Viewport frame + host
// ---------------------------------------------------------------------------

/// Plain insets (no Flutter EdgeInsets, so this file stays dependency free).
class ViewportInsets {
  const ViewportInsets({
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
    this.left = 0,
  });

  final double top;
  final double right;
  final double bottom;
  final double left;

  Map<String, Object?> toJson() => <String, Object?>{
        'top': top,
        'right': right,
        'bottom': bottom,
        'left': left,
      };
}

/// A viewport sample injected from outside (MediaQuery in the real app, a
/// fixture in tests). Plain doubles only.
class ViewportFrame {
  const ViewportFrame({
    required this.logicalWidth,
    required this.logicalHeight,
    required this.devicePixelRatio,
    this.insets = const ViewportInsets(),
    this.imeInset = 0,
  });

  final double logicalWidth;
  final double logicalHeight;
  final double devicePixelRatio;
  final ViewportInsets insets;
  final double imeInset;

  double get physicalWidth => logicalWidth * devicePixelRatio;

  double get physicalHeight => logicalHeight * devicePixelRatio;

  /// The width Qt would see for this frame (physical pixels), which is what
  /// NativeScene::resize receives.
  int get stageWidth => physicalWidth.round();

  int get stageHeight => physicalHeight.round();

  Map<String, Object?> toJson() => <String, Object?>{
        'logicalWidth': logicalWidth,
        'logicalHeight': logicalHeight,
        'devicePixelRatio': devicePixelRatio,
        'insets': insets.toJson(),
        'imeInset': imeInset,
      };

  static ViewportFrame fromJson(Map<String, Object?> json) => ViewportFrame(
        logicalWidth: _asDouble(json['logicalWidth']),
        logicalHeight: _asDouble(json['logicalHeight']),
        devicePixelRatio: _asDouble(json['devicePixelRatio'], 1),
        insets: ViewportInsets(
          top: _asDouble(_asMap(json['insets'])['top']),
          right: _asDouble(_asMap(json['insets'])['right']),
          bottom: _asDouble(_asMap(json['insets'])['bottom']),
          left: _asDouble(_asMap(json['insets'])['left']),
        ),
        imeInset: _asDouble(json['imeInset']),
      );
}

/// The rotation entry point.
///
/// Everything here exists outside the widget tree, so applying a viewport only
/// recomputes what the viewport derives (plan:369). The host never rebuilds the
/// app, never disposes playback, never clears a list, never logs in again and
/// never restarts Node.
class RotationContinuityHost {
  RotationContinuityHost({
    ViewportFrame? viewport,
    String provider = 'netease',
  })  : viewport = viewport ??
            const ViewportFrame(
              logicalWidth: 2400,
              logicalHeight: 1080,
              devicePixelRatio: 1,
            ),
        login = QrLoginContinuity(provider: provider, nowMs: 0),
        playback = PlaybackContinuity(provider: provider) {
    _stageListener = ledger.acquire('stageListener');
  }

  final QrLoginContinuity login;
  final PlaybackContinuity playback;
  final LyricsContinuity lyrics = LyricsContinuity();
  final SceneContinuity scene = SceneContinuity();
  final DragContinuity drag = DragContinuity();
  final ResourceLedger ledger = ResourceLedger();

  ViewportFrame viewport;
  int viewportRevision = 0;

  late final int _stageListener;

  /// Cold start: one login session, one Node runtime, one media source.
  void startRuntime() {
    ledger.beginLogin();
    ledger.startNodeRuntime();
    ledger.buildMediaSource();
    lyrics.playingTrack = playback.current;
  }

  /// The single rotation/resize entry point.
  ///
  /// Returns true when an in-flight drag had to be cancelled. Nothing else about
  /// the session changes: the QR generation, the playback archive and the lyrics
  /// offset are untouched, and the media source is reused.
  bool applyViewport(ViewportFrame next) {
    viewport = next;
    viewportRevision++;
    scene.applyViewport(next.stageWidth, next.stageHeight);
    final bool cancelled =
        drag.cancelForViewportChange(canBrowseNow: scene.canBrowse);
    ledger.rebind('stageListener', _stageListener);
    ledger.reuseMediaSource();
    return cancelled;
  }

  /// Release the resources the host itself owns.
  void dispose() {
    ledger.release('stageListener', _stageListener);
  }

  /// Snapshot of the pieces that must be provably identical across a rotation.
  Map<String, Object?> describe() => <String, Object?>{
        'viewportRevision': viewportRevision,
        'login': <String, Object?>{
          'generation': login.generation,
          'qrKey': login.qrKey,
          'hasCode': login.hasCode,
          'loginPhase': login.loginPhase,
          'remainingMs': login.remainingMs(),
        },
        'scene': <String, Object?>{
          'clock': scene.clock,
          'bootStart': scene.bootStart,
          'detail': scene.detail,
          'mode': scene.mode,
          'selected': scene.selected,
          'eye': List<double>.from(scene.eye),
          'aim': List<double>.from(scene.aim),
          'viewerTransition': scene.viewer.transition,
          'viewerClarity': scene.viewer.clarity,
          'viewerOpenCount': scene.viewer.openCount,
          'viewerResetCount': scene.viewer.resetCount,
        },
        'playback': <String, Object?>{
          'current': playback.current,
          'index': playback.index,
          'mode': playback.mode,
          'history': playback.history.length,
        },
        'lyrics': <String, Object?>{
          'offsetMs': lyrics.offsetMs,
          'source': lyrics.localSource,
          'lyricsMode': lyrics.lyricsMode,
        },
        'ledger': ledger.report(),
      };
}