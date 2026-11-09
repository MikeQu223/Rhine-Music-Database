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
//     to the current API provider) must equal the current provider, otherwise even the
//     queue is not restored. The queue is always restored BEFORE the track is selected,
//     so a corrupt saved index can never make "next" jump to an unrelated position.
//   * Qt/src/PlaybackQueue.cpp:14-30 - queue sanitising: kind must be "song", the id
//     must be non-empty, and the FIRST occurrence of an identity wins.
//   * Qt/src/PlaybackQueue.cpp:36-38 - identity is provider + ":" + id with the
//     provider defaulting to "netease".
//   * Qt/src/PlaybackQueue.cpp:398-418 - restore(): the saved index addresses the
//     PRE-FILTER array (saved.at(savedIndex)); entries flagged "deferred" are kept out
//     of the complete queue but their ids are retained for background hydration; the
//     selection is dropped when the addressed entry is deferred or out of range;
//     replace() then re-seats the selection by identity.
//   * Qt/src/PlaybackQueue.cpp:140-146 - selectTrack() appends an unseen but valid
//     track and selects the appended row.
//
// BOUNDARY (reported, not invented): background hydration of "deferred" ids
// (PlaybackQueue::load) belongs to the playback runtime, not to storage. This file
// therefore returns the complete queue exactly as <toJson()> would persist it and does
// not invent an ids field.
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
  return jsonString(map['provider'], kDefaultTrackProvider) + ':' + jsonString(map['id']);
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
  });

  /// Selected track, or an empty object when only the queue is restored.
  final Map<String, Object?> current;

  /// Complete queue after sanitising; "deferred" entries stay out of it.
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

  /// Exactly the seven keys and the field order of Qt's sessionState()
  /// (Qt/src/MusicPlayer.cpp:756-757).
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
  const _QueueRestore(this.queue, this.index);

  final List<Map<String, Object?>> queue;
  final int index;
}

/// Reproduces PlaybackQueue::restore() + replace() + sanitized()
/// (Qt/src/PlaybackQueue.cpp:14-30, 99-117, 398-418).
_QueueRestore _restoreQueue(List<Object?> saved, Object? rawIndex) {
  final savedIndex = jsonInt(rawIndex, -1);

  final complete = <Map<String, Object?>>[];
  for (final value in saved) {
    final track = asJsonObject(value);
    if (jsonString(track['kind']) != kSongKind || jsonString(track['id']).isEmpty) {
      continue;
    }
    if (jsonBool(track['deferred'])) {
      // Kept out of the complete queue; only its id would be hydrated by the runtime.
      continue;
    }
    complete.add(track);
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
  return _QueueRestore(queue, index);
}

/// Normalises a persisted player object, returning null when Qt would abort the whole
/// restore (Qt/src/MusicPlayer.cpp:760-779).
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

  // 2. Mode whitelist.
  final savedMode = jsonString(saved['mode']);
  final mode = kPlayerModes.contains(savedMode) ? savedMode : 'all';

  final track = asJsonObject(saved['current']);
  final savedQueue = saved['queue'] is List ? (saved['queue'] as List<Object?>) : const <Object?>[];
  final requested = jsonBool(saved['requested']);
  final preview = jsonBool(saved['preview']);

  // 3. The queue is restored in both branches, always before any selection.
  final restored = _restoreQueue(savedQueue, saved['index']);

  if (track.isEmpty) {
    return PlayerState(
      current: const <String, Object?>{},
      queue: restored.queue,
      index: restored.index,
      mode: mode,
      position: position,
      requested: requested,
      preview: preview,
    );
  }

  final provider = jsonString(track['provider'], currentProvider);
  if (jsonString(track['kind']) != kSongKind || provider != currentProvider) {
    return null;
  }

  // selectTrack(): reseat on the existing identity, otherwise append
  // (Qt/src/PlaybackQueue.cpp:130-147). Qt appends only when the track has a
  // usable identity - kind == song and a NON-EMPTY id (:140). For a corrupt
  // current with an empty id the call is a no-op and the row that restore()
  // selected stays current, so the append test cannot key off index < 0.
  final queue = List<Map<String, Object?>>.of(restored.queue);
  final key = trackIdentity(track);
  var index = restored.index;
  var matched = false;
  for (var row = 0; row < queue.length; row += 1) {
    if (trackIdentity(queue[row]) == key) {
      index = row;
      matched = true;
      break;
    }
  }
  if (!matched && jsonString(track['id']).isNotEmpty) {
    queue.add(track);
    index = queue.length - 1;
  }

  return PlayerState(
    current: track,
    queue: queue,
    index: index,
    mode: mode,
    position: position,
    requested: requested,
    preview: preview,
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
  /// exists but is unusable, or when the payload fails the contract. No path in this
  /// method deletes or rewrites anything.
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
