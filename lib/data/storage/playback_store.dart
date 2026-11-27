// Background-playback persistence and the shared player-object contract.
//
// READ-ONLY spec sources at the same baseline (8ed3067b0812eb2612f7841ec127a6e8ca93231b):
//   * Qt/src/PlaybackService.cpp:419-436 - read precedence: while offline nothing is
//     restored; <data>/playback-session.json is inspected FIRST; ONLY when that file
//     does not exist does the code fall back to <data>/session.json and take its
//     top-level "player" object (legacy). The fallback is deliberately absent when the
//     primary file exists but cannot be opened or exceeds 64 MiB: changing that would
//     silently change the state source, so it is reproduced verbatim here.
//   * Qt/src/PlaybackService.cpp:438-448 - save target is playback-session.json, the
//     payload is the compact player object, and a payload above 64 MiB is not written.
//   * Qt/src/MusicPlayer.cpp:749-757 - sessionState() writes exactly
//     current, queue, index, mode, position, requested, preview.
//   * Qt/src/MusicPlayer.cpp:760-779 - restoreSessionState(): the position gate runs
//     FIRST and aborts the WHOLE restore (mode AND queue are then left untouched);
//     "mode" is restricted to all|one|off|shuffle; an empty "current" restores only the
//     queue; a non-empty "current" must be kind == "song" and its provider (defaulting
//     to the current API provider) must equal the current provider, otherwise the mode
//     assignment at :765-766 still stands while the queue and current are not applied.
//     The queue is always restored BEFORE the track is selected,
//     so a corrupt saved index can never make "next" jump to an unrelated position.
//   * Qt/src/PlaybackQueue.cpp:14-30 - queue sanitising: kind must be "song", the id
//     must be non-empty, and the FIRST occurrence of an identity wins.
//   * Qt/src/PlaybackQueue.cpp:36-38 - identity is provider + ":" + id with the
//     provider defaulting to "netease".
//   * Qt/src/PlaybackQueue.cpp:398-418 - restore(): the saved index addresses the
//     PRE-FILTER array (saved.at(savedIndex)); entries flagged "deferred" are kept out
//     of the complete queue but their ids are retained for background hydration; the
//     selection is dropped when the addressed entry is deferred or out of range;
//     replace() then re-seats the selection by identity. "deferred" is READ-ONLY in
//     this layer: it decides membership, and the queue this file returns never carries
//     the key, so toJson()/save cannot write it back.
//   * Qt/src/PlaybackQueue.cpp:140-146 - selectTrack() appends an unseen but valid
//     track and selects the appended row.
//
// DEFERRED IDS (PlaybackQueue.cpp:402-411,415-417): restore() appends a usable track id
// to a separate id array BEFORE it tests "deferred", keeps the deferred entry out of the
// complete queue, and hands that id array to load(ids, complete) for hydration. Storage
// therefore returns BOTH products of restore(): the complete queue (which is exactly what
// toJson() persists) and the ordered id list, exposed as [PlayerState.deferredIds]. The
// list is restore output, never archive state, so [PlayerState.toJson] still emits only
// the seven MusicPlayer::sessionState() keys. Hydrating the ids stays with the playback
// runtime; storage must not drop them on the way there. The "deferred" marker itself is
// read-only: it gates membership of the complete queue and is never written back.
//
// PURE Dart on purpose: no flutter import and no file IO of its own - every byte goes
// through the injected AppStorage/FileSystemPort so the Android directory stays an
// injected runtime path and is never guessed.

import 'dart:convert';

import 'app_storage.dart';

/// Track kind accepted by the queue contract (Qt/src/PlaybackQueue.cpp:19,404).
const String kSongKind = 'song';

/// Identity provider fallback, mirroring QJsonValue::toString("netease")
/// (Qt/src/PlaybackQueue.cpp:37, MusicPlayer.cpp:774).
const String kDefaultTrackProvider = 'netease';

/// Player modes accepted on restore (Qt/src/MusicPlayer.cpp:766).
const List<String> kPlayerModes = <String>['all', 'one', 'off', 'shuffle'];

/// Session position ceiling; larger values abort the whole restore
/// (Qt/src/MusicPlayer.cpp:762).
const double kMaxSessionPosition = 1e12;

/// Reads a JSON value the way QJsonValue::toObject() does: anything that is not an
/// object becomes the empty object.
Map<String, Object?> asJsonObject(Object? value) {
  if (value is Map) {
    return value.map<String, Object?>((key, item) => MapEntry<String, Object?>(key.toString(), item));
  }
  return <String, Object?>{};
}

/// Mirrors QJsonValue::toString(): a non-string value yields the default.
String jsonString(Object? value, [String fallback = '']) => value is String ? value : fallback;

/// Mirrors QJsonValue::toDouble(default): only a JSON number converts.
double jsonDouble(Object? value, [double fallback = 0]) => value is num ? value.toDouble() : fallback;

/// Mirrors QJsonValue::toInt(default) exactly (Qt 6 qjsonvalue.cpp:686-705).
///
///  * QCborValue::Integer (Dart int) converts only when it fits the 32-bit range
///    (qjsonvalue.cpp:695-700): qint64(int(n)) == n, i.e. -2^31 <= n <= 2^31-1.
///  * QCborValue::Double (Dart double) goes through convertDoubleTo<int>
///    (qnumeric_p.h:180-289): Tmin = -2147483648, supremum = -1 * Tmin = 2147483648.0.
///    The value converts only when it is not NaN (NaN must be excluded by the caller,
///    qnumeric_p.h:161-162), is not < -2147483648.0 (qnumeric_p.h:268-269), is not
///    >= 2147483648.0 (qnumeric_p.h:277-278) and survives the round-trip check
///    *value == v (qnumeric_p.h:281-286) - that is, the value must be WHOLE. A
///    non-integral double (1.7) therefore yields the default instead of truncating.
///  * Every other JSON type (string/bool/null/object/array) yields the default.
///
/// Note the asymmetry: 2147483648.0 is rejected while -2147483648.0 is accepted,
/// because the accepted interval [Tmin, supremum) is half-open.
int jsonInt(Object? value, [int fallback = 0]) {
  const int intMin = -2147483648; // -2^31 == Tmin
  const int supremum = 2147483648; // 2^31 == -Tmin; one past the int32 maximum
  const double intMinDouble = -2147483648.0;
  const double supremumDouble = 2147483648.0;
  if (value is int) {
    return value >= intMin && value < supremum ? value : fallback;
  }
  if (value is double) {
    if (!value.isFinite || value < intMinDouble || value >= supremumDouble) {
      return fallback;
    }
    // (int)v truncates toward zero in Qt too; *value == v then rejects anything
    // inexact, so only whole doubles survive.
    final truncated = value.toInt();
    return truncated.toDouble() == value ? truncated : fallback;
  }
  return fallback;
}

/// Mirrors QJsonValue::toBool(): only a JSON boolean is true.
bool jsonBool(Object? value) => value is bool ? value : false;

/// Queue identity: provider + ":" + id (Qt/src/PlaybackQueue.cpp:36-38).
String trackIdentity(Object? track) {
  final map = asJsonObject(track);
  return '${jsonString(map['provider'], kDefaultTrackProvider)}:${jsonString(map['id'])}';
}

/// The player object persisted inside session.json and, verbatim, as
/// playback-session.json (Qt/src/MusicPlayer.cpp:749-757).
class PlayerState {
  const PlayerState({
    required this.current,
    required this.queue,
    required this.index,
    required this.mode,
    required this.position,
    required this.requested,
    required this.preview,
    this.deferredIds = const <String>[],
  });

  /// Selected track, or an empty object in the other two shapes:
  ///  * empty current in the payload: the queue alone is restored (:769-773);
  ///  * rejected current (bad kind/provider): only [mode], [position], [requested] and
  ///    [preview] survive, and the queue stays empty with [index] -1 (:774-776).
  ///
  /// The legacy "deferred" marker is stripped: it is read-only here, and toJson() echoes
  /// this map back into the archive (MusicPlayer.cpp:751), so a hand-crafted marker must
  /// not survive a restore -> save round trip.
  final Map<String, Object?> current;

  /// Complete queue after sanitising; "deferred" entries stay out of it, and their ids
  /// (plus the rest of Qt's id array) are carried in [deferredIds].
  final List<Map<String, Object?>> queue;

  /// Selected row inside [queue], or -1 when nothing is selected.
  final int index;

  /// One of [kPlayerModes].
  final String mode;

  /// Playback position in seconds; finite and within 0..[kMaxSessionPosition].
  final double position;

  /// Whether playback should be running (resume information).
  final bool requested;

  /// Audition flag passed through on restore.
  final bool preview;

  /// The ordered id list produced by PlaybackQueue::restore(), i.e. Qt's `ids`
  /// (Qt/src/PlaybackQueue.cpp:404-405,415-417).
  ///
  /// Qt appends the id of EVERY usable entry (kind == "song" and a non-empty id) in
  /// archive order BEFORE it inspects "deferred". The list therefore holds deferred
  /// entries, duplicates, and ids whose entry sanitized() later dropped, and hydrate
  /// consumes exactly these ids. The name follows the deferred-id vocabulary, but the
  /// value is deliberately the full Qt id array rather than a deferred-only subset.
  ///
  /// NEVER serialised: [toJson] writes only the seven persisted keys, so this list
  /// cannot reach session.json or playback-session.json. It is empty when queue.restore
  /// never ran, which is the rejected-current path (:774-776).
  final List<String> deferredIds;

  /// Exactly the seven keys and the field order of Qt's sessionState()
  /// (Qt/src/MusicPlayer.cpp:756-757). [deferredIds] is deliberately absent: it is
  /// restore output, not part of the archive (PlaybackQueue.cpp:420-422).
  Map<String, Object?> toJson() => <String, Object?>{
        'current': current,
        'queue': queue,
        'index': index,
        'mode': mode,
        'position': position,
        'requested': requested,
        'preview': preview,
      };
}

class _QueueRestore {
  const _QueueRestore(this.queue, this.index, this.deferredIds);

  final List<Map<String, Object?>> queue;
  final int index;

  /// Qt's `ids` array: every usable id in archive order (PlaybackQueue.cpp:404-405).
  final List<String> deferredIds;
}

/// Reproduces PlaybackQueue::restore() + replace() + sanitized()
/// (Qt/src/PlaybackQueue.cpp:14-30, 99-117, 398-418).
_QueueRestore _restoreQueue(List<Object?> saved, Object? rawIndex) {
  final savedIndex = jsonInt(rawIndex, -1);

  final ids = <String>[];
  final complete = <Map<String, Object?>>[];
  for (final value in saved) {
    final track = asJsonObject(value);
    if (jsonString(track['kind']) != kSongKind || jsonString(track['id']).isEmpty) {
      continue;
    }
    // PlaybackQueue.cpp:404-405 appends the id BEFORE the deferred test, so this list
    // keeps every usable id in archive order: deferred entries, entries sanitized()
    // later drops as duplicates, and duplicates themselves.
    ids.add(jsonString(track['id']));
    if (jsonBool(track['deferred'])) {
      // Kept out of the complete queue, but its id must survive so the runtime can
      // hydrate it later (PlaybackQueue.cpp:406-411,415-417).
      continue;
    }
    // "deferred" is a READ-ONLY legacy marker: it decided membership above and is
    // stripped from the emitted queue, so persist()/toJson() never writes it back -
    // not even a literal deferred:false carried by the archive (storage.md §3.1).
    complete.add(Map<String, Object?>.of(track)..remove('deferred'));
  }

  // sanitized(): first occurrence of an identity wins (PlaybackQueue.cpp:14-30).
  final seen = <String>{};
  final queue = <Map<String, Object?>>[];
  for (final track in complete) {
    if (seen.add(trackIdentity(track))) {
      queue.add(track);
    }
  }

  // The selection addresses the PRE-FILTER array; a missing or out-of-range index and a
  // deferred selection both mean "no selection" (PlaybackQueue.cpp:412-414).
  Map<String, Object?> selected = <String, Object?>{};
  if (savedIndex >= 0 && savedIndex < saved.length) {
    selected = asJsonObject(saved[savedIndex]);
  }
  if (jsonBool(selected['deferred'])) {
    selected = <String, Object?>{};
  }

  var index = -1;
  if (selected.isNotEmpty) {
    final selectedKey = trackIdentity(selected);
    for (var row = 0; row < queue.length; row += 1) {
      if (trackIdentity(queue[row]) == selectedKey) {
        index = row;
        break;
      }
    }
  }
  // Unmodifiable so the ids cannot drift after the state was normalised; the empty
  // default is already a const (unmodifiable) list, so both shapes behave alike.
  return _QueueRestore(queue, index, List<String>.unmodifiable(ids));
}

/// Normalises a persisted player object. Returns null only when Qt aborts the whole
/// restore at the position gate (Qt/src/MusicPlayer.cpp:760-764). A current that fails
/// the kind/provider guard (:774-776) is not a total abort: Qt has already assigned the
/// whitelisted mode (:765-766) and returns before queue.restore() and play(), so a
/// partial state with the restored mode, an empty queue and index -1 is returned
/// instead of null. The gate order below follows Qt exactly.
///
/// [currentProvider] is the provider the running app currently serves; Qt compares the
/// saved track provider against it and defaults a missing provider to that same value.
PlayerState? normalizePlayer(Object? raw, {required String currentProvider}) {
  if (raw is! Map) {
    return null;
  }
  final saved = asJsonObject(raw);

  // 1. Position gate first: an unusable position discards mode AND queue.
  final position = jsonDouble(saved['position'], -1);
  if (position.isNaN || position.isInfinite || position < 0 || position > kMaxSessionPosition) {
    return null;
  }

  // 2. Mode whitelist. Qt assigns it BEFORE the current guard (:765-766), so it
  // survives even when the current is rejected at :774-776.
  final savedMode = jsonString(saved['mode']);
  final mode = kPlayerModes.contains(savedMode) ? savedMode : 'all';

  final track = asJsonObject(saved['current']);
  final savedQueue = saved['queue'] is List ? (saved['queue'] as List<Object?>) : const <Object?>[];
  final requested = jsonBool(saved['requested']);
  final preview = jsonBool(saved['preview']);

  // 3. Empty current: restore the queue only, then return (:769-773).
  if (track.isEmpty) {
    final restored = _restoreQueue(savedQueue, saved['index']);
    return PlayerState(
      current: const <String, Object?>{},
      queue: restored.queue,
      index: restored.index,
      mode: mode,
      position: position,
      requested: requested,
      preview: preview,
      // queue.restore() DID run on this branch (MusicPlayer.cpp:770), so the hydration
      // ids exist and are carried out (:770,778).
      deferredIds: restored.deferredIds,
    );
  }

  // 4. Current gate: Qt returns here WITHOUT ever calling queue.restore() (:774-776).
  final provider = jsonString(track['provider'], currentProvider);
  if (jsonString(track['kind']) != kSongKind || provider != currentProvider) {
    // MusicPlayer.cpp:765-766 has already assigned the whitelisted mode, then :774-776
    // returns before :778 queue.restore() and :779 play(), so the mode survives while
    // neither the saved queue nor the rejected current is applied. Both PRODUCT call
    // sites run on a freshly constructed MusicPlayer - the PlaybackService member
    // restored from its own constructor (PlaybackService.cpp:32-33,119) and
    // NativeApplication::initialize (NativeApplication.cpp:67 -> MusicSession.cpp:264,
    // skipped while a playback connection owns the player) - whose queue is empty and
    // whose index is -1 (PlaybackQueue.h:78). "Leave the queue untouched" is therefore,
    // at every product call site, exactly this empty queue with index -1. The only host
    // that re-restores a live player is the Qt self-test (Qt/tests/SessionChecks.cpp:217,
    // :236); its fixtures always pass the guard, so the reject branch is never observed
    // there. This value object cannot express "keep a live queue": a product re-restore
    // over a live player would need a structured partial-restore plan plus a caller
    // change, which is outside this file's contract today.
    //
    // position/requested/preview are carried exactly as the empty-current branch
    // carries them: they describe the normalised snapshot and stay inert without a
    // current (Qt feeds them back only through play() at :779).
    return PlayerState(
      current: const <String, Object?>{},
      queue: const <Map<String, Object?>>[],
      index: -1,
      mode: mode,
      position: position,
      requested: requested,
      preview: preview,
      // Qt returns at :774-776 BEFORE queue.restore(), so no id list was ever built on
      // this branch; an empty list is the faithful value, not a dropped one.
      deferredIds: const <String>[],
    );
  }

  // 5. Valid current: restore the queue, then reseat or append (:777-779).
  final restored = _restoreQueue(savedQueue, saved['index']);
  // selectTrack(): reseat on the existing identity, otherwise append
  // (Qt/src/PlaybackQueue.cpp:130-147). Qt appends only when the track has a
  // usable identity - kind == song and a NON-EMPTY id (:140). For a corrupt
  // current with an empty id the call is a no-op and the row that restore()
  // selected stays current, so the append test cannot key off index < 0.
  final queue = List<Map<String, Object?>>.of(restored.queue);
  // The current is echoed back by toJson() (MusicPlayer.cpp:751), so the read-only
  // marker is stripped here too: a hand-crafted "deferred" on the saved current must
  // never be written back into playback-session.json or session.json.
  final current = Map<String, Object?>.of(track)..remove('deferred');
  final key = trackIdentity(current);
  var index = restored.index;
  var matched = false;
  for (var row = 0; row < queue.length; row += 1) {
    if (trackIdentity(queue[row]) == key) {
      index = row;
      matched = true;
      break;
    }
  }
  if (!matched && jsonString(current['id']).isNotEmpty) {
    // The appended row obeys the same read-only rule: the emitted queue never carries
    // the legacy marker, so a hand-crafted deferred inside "current" cannot leak into
    // the persisted queue either. The second copy keeps the queue row independent of
    // [PlayerState.current], so a caller mutating one cannot silently rewrite the other.
    queue.add(Map<String, Object?>.of(current));
    index = queue.length - 1;
  }

  return PlayerState(
    current: current,
    queue: queue,
    index: index,
    mode: mode,
    position: position,
    requested: requested,
    preview: preview,
    // queue.restore() ran at :778 before play() at :779, so the ids are produced here
    // too; play() appending an unseen current does not change them.
    deferredIds: restored.deferredIds,
  );
}

/// Persistence of the background playback session.
///
/// The file body IS the player object: no version wrapper and no "player" key
/// (Qt/src/PlaybackService.cpp:419-448).
class PlaybackStore {
  PlaybackStore({required this.storage});

  /// Injected storage; the Android runtime directory is never guessed here.
  final AppStorage storage;

  /// Same 64 MiB read/write boundary as Qt (Qt/src/PlaybackService.cpp:419-448).
  static const int sessionLimitBytes = kSessionLimitBytes;

  /// Loads the player object.
  ///
  /// Returns null while offline, when nothing is persisted, when the primary file
  /// exists but is unusable, or when the payload fails the position gate. A rejected
  /// current yields the mode-only partial state described by [normalizePlayer]. No
  /// path in this method deletes or rewrites anything.
  Future<PlayerState?> load({required String currentProvider}) async {
    if (storage.offline) {
      return null;
    }
    final bool primaryExists;
    try {
      primaryExists = await storage.files.exists(storage.playbackSessionPath);
    } catch (_) {
      return null;
    }
    if (primaryExists) {
      final bytes = await _readCapped(storage.playbackSessionPath);
      if (bytes == null) {
        // Existing but unopenable/oversize: Qt does NOT fall back here.
        return null;
      }
      return _decodePlayer(bytes, currentProvider);
    }

    // Legacy fallback: only when playback-session.json is absent.
    final legacy = await _readCapped(storage.sessionPath);
    if (legacy == null) {
      return null;
    }
    final document = _decodeJson(legacy);
    if (document is! Map) {
      return null;
    }
    return normalizePlayer(asJsonObject(document)['player'], currentProvider: currentProvider);
  }

  /// Persists [player] as playback-session.json.
  ///
  /// Returns false while offline, above the 64 MiB boundary, or on an IO failure; in
  /// every failure case the previous file is left untouched. The player is never written
  /// into session.json - that file belongs to the GUI session store.
  Future<bool> save(PlayerState player) async {
    if (storage.offline) {
      return false;
    }
    try {
      return await storage.writeJsonAtomic(
        storage.playbackSessionPath,
        player.toJson(),
        limitBytes: sessionLimitBytes,
      );
    } catch (_) {
      return false;
    }
  }

  Future<List<int>?> _readCapped(String path) async {
    try {
      return await storage.readCapped(path, sessionLimitBytes);
    } catch (_) {
      return null;
    }
  }

  PlayerState? _decodePlayer(List<int> bytes, String currentProvider) {
    final document = _decodeJson(bytes);
    if (document is! Map) {
      return null;
    }
    return normalizePlayer(document, currentProvider: currentProvider);
  }
}

/// Decodes UTF-8 JSON, mapping every failure onto null (Qt keeps the file and behaves as
/// if nothing had been persisted).
Object? decodeJsonOrNull(List<int> bytes) => _decodeJson(bytes);

Object? _decodeJson(List<int> bytes) {
  try {
    return jsonDecode(utf8.decode(bytes));
  } catch (_) {
    return null;
  }
}
