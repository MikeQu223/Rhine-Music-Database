// Contract freeze for the Qt-compatible session / preference / credential store.
//
// Normative source: docs/flutter-migration/contracts/storage.md (FROZEN, reviewed
// by reports/T07-C01-M12-R.json) against the Qt sources of the same baseline.
// Every assertion below cites the contract section and the Qt line range it
// freezes. This atom (T07-C18 / plan:444,448) only adds the fixture and the test:
// no production storage layer exists yet under lib/, so the small "contract
// mirror" section carries the executable form of the contract. When the storage
// layer lands these helpers must be replaced by imports from lib/ and the mirror
// deleted; the assertions themselves stay unchanged.
//
// Hard rules honoured here:
//   * no platform absolute path is invented: only the contract's relative file
//     names are asserted (storage.md:8, :284, :1.1);
//   * no test opens session.json, QSettings, account.credential or any device
//     path; the only file IO is reading this repository's own fixture;
//   * nothing here is executed by this atom: flutter test / dart test / build /
//     analyze are forbidden for the task, so RED/GREEN are reported NOT RUN.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Frozen names, limits and key lists
// ---------------------------------------------------------------------------

/// storage.md §1.1, §2.5: 64 MiB is a hard limit and the write comparison is
/// strict greater-than: MusicSession.cpp:276 rejects anything above it.
const int sessionLimitBytes = 64 * 1024 * 1024; // 67108864
const int sessionLimitBytesPlusOne = sessionLimitBytes + 1;

/// storage.md §8: LocalCollections.cpp:40 rejects anything above 16 MiB.
const int collectionsLimitBytes = 16 * 1024 * 1024; // 16777216

/// storage.md §5.3, Host.cpp:1094: value.size() < 262144, where QString::size()
/// counts UTF-16 code units.
const int panelValueLimit = 262144;

/// Relative names only; the absolute root is AppStorage::dataDirectory()
/// resolved at runtime and is a DEVICE_BLOCKED item (storage.md §1, §12).
const String sessionFileName = 'session.json';
const String playbackSessionFileName = 'playback-session.json';
const String playbackLockFileName = 'playback-service.lock';
const String credentialFileName = 'account.credential';
const String collectionsDirectory = 'collections';

/// storage.md §7: one kugou device file regardless of edition.
const Map<String, String> deviceStateFiles = <String, String>{
  'qq': 'qq-device.json',
  'kugou': 'kugou-device.json',
};

/// storage.md §2.3: exactly 16 view keys, in the order the contract freezes.
const List<String> viewKeys = <String>[
  'mode',
  'selected',
  'tab',
  'modal',
  'queueOffset',
  'settingsScroll',
  'query',
  'groupBy',
  'activeGroup',
  'artistTab',
  'listOffset',
  'trackOffset',
  'bodyOffset',
  'musicCollection',
  'trackListMode',
  'lyricsMode',
];

/// storage.md §2.3: MusicSession.cpp:243 whitelist; everything else, including
/// the empty string written while a modal closes, restores no modal at all.
const List<String> modalWhitelist = <String>[
  'saved',
  'search',
  'discover',
  'queue',
  'settings',
  'player',
  'local',
];

/// storage.md §2.3 row 3: MusicSession.cpp:249.
const List<String> viewTabs = <String>['overview', 'notes', 'history'];

/// storage.md §2.2: MusicSession.cpp:122 directory sort whitelist.
const List<String> sortFields = <String>['none', 'title', 'album', 'artist'];

/// storage.md §3: MusicPlayer.cpp:766.
const List<String> playerModes = <String>['all', 'one', 'off', 'shuffle'];

/// storage.md §2.2: the 31 library keys written by
/// MusicLibrary::sessionState() (MusicSession.cpp:50-85).
const List<String> libraryKeys = <String>[
  'provider',
  'edition',
  'uid',
  'sources',
  'directories',
  'current',
  'selectedPhysical',
  'selectedLane',
  'keyword',
  'searchKind',
  'status',
  'searchLoading',
  'directoryLoading',
  'detailLoading',
  'privateSelection',
  'searchCursor',
  'playlistCursor',
  'albumCursor',
  'likedCursor',
  'likedIDs',
  'groupName',
  'groupIndices',
  'groupLane',
  'tracks',
  'trackIDs',
  'trackCursor',
  'albumLoaded',
  'playContext',
  'directoryInfo',
  'wantsSongDetails',
  'discover',
];

/// storage.md §2.2: MusicSession.cpp:36-40.
const List<String> sourceKeys = <String>['items', 'total', 'offset', 'more', 'row'];

/// storage.md §2.2: MusicSession.cpp:12-26.
const List<String> directoryKeys = <String>[
  'item',
  'songs',
  'sortField',
  'ids',
  'albums',
  'cursor',
  'index',
  'anchor',
  'page',
  'parentPhysical',
  'parentLane',
  'parentItem',
  'albumCursor',
  'albumsMore',
];

/// storage.md §2.2: MusicSession.cpp:80-85.
const List<String> discoverKeys = <String>[
  'tab',
  'items',
  'offset',
  'more',
  'category',
  'newSongArea',
];

/// storage.md §3: MusicPlayer.cpp:756-757.
const List<String> playerKeys = <String>[
  'current',
  'queue',
  'index',
  'mode',
  'position',
  'requested',
  'preview',
];

/// storage.md §5.2: the exact 53 preference keys of Host.cpp:1042-1057, in
/// source order. Read (Host.cpp:1072-1075) and write (Host.cpp:1094-1095) share
/// this single list; the contract forbids splitting them.
const List<String> panelKeys = <String>[
  'search-history',
  'play-history',
  'local-cover-cache',
  'theme',
  'motion',
  'startup-animation',
  'detail-autoplay',
  'single-play-mode',
  'disc-rotation',
  'scene-enhancement',
  'archive-mask-strength',
  'graphics-backend',
  'gpu-index',
  'vsync',
  'supersample',
  'render-scale',
  'aa-mode',
  'aa-scale',
  'msaa',
  'fsr-quality',
  'fsr-sharpness',
  'fg',
  'close-behavior',
  'auto-update',
  'volume',
  'quality',
  'alternate-source',
  'provider',
  'lyrics-cache',
  'lyrics-global-offset-ms',
  'welcome-name-netease',
  'welcome-name-qq',
  'welcome-name-kugou',
  'account-id-netease',
  'account-id-qq',
  'account-id-kugou',
  'kugou-edition',
  'desktop-lyrics',
  'desktop-lyrics-size',
  'desktop-lyrics-translation-size',
  'desktop-lyrics-opacity',
  'desktop-lyrics-line-color',
  'desktop-lyrics-translation-color',
  'desktop-lyrics-line-weight',
  'desktop-lyrics-translation-weight',
  'desktop-lyrics-line-outline',
  'desktop-lyrics-translation-outline',
  'desktop-lyrics-line-outline-color',
  'desktop-lyrics-translation-outline-color',
  'welcome-name-kugou-standard',
  'welcome-name-kugou-lite',
  'account-id-kugou-standard',
  'account-id-kugou-lite',
];

/// storage.md §6: PlatformAndroid.cpp:27,41 exact failure text.
const String credentialFailureNote = '登录成功，但 Android 凭据当前不可写';

/// storage.md §6.1: the Qt call is QFile::setPermissions(path, QFile::ReadOwner
/// | QFile::WriteOwner). Those enum values are Qt permission flags, not POSIX
/// bits; the resulting POSIX mode is 0600, i.e. 0x180 == 384.
const int credentialMode = 0x180;

/// storage.md §6.1: the Qt Android write is mkpath -> open(Truncate) -> write
/// -> close -> chmod 0600 (PlatformAndroid.cpp:29-40). It is explicitly NOT
/// atomic; the atomic form is Flutter branch A (storage.md §6.3 A).
const List<String> qtCredentialWriteSteps = <String>[
  'mkpath',
  'open-truncate',
  'write',
  'close',
  'chmod-0600',
];

// ---------------------------------------------------------------------------
// Contract mirror: value coercion identical to QJsonValue accessors
// ---------------------------------------------------------------------------

Map<String, Object?> _map(Object? value) {
  if (value is Map) {
    final Map<String, Object?> result = <String, Object?>{};
    value.forEach((Object? key, Object? item) {
      result['$key'] = item;
    });
    return result;
  }
  return <String, Object?>{};
}

List<Object?> _list(Object? value) => value is List ? List<Object?>.from(value) : <Object?>[];

/// QJsonValue::toInt returns its default unless the number is integral, so a
/// fractional double must not be truncated silently (MusicPlayer.cpp:770 and
/// MusicSession.cpp:260 both rely on it).
int _int(Object? value, [int fallback = 0]) {
  if (value is int) {
    return value;
  }
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return fallback;
}

double _double(Object? value, [double fallback = 0]) {
  if (value is num && value.isFinite) {
    return value.toDouble();
  }
  return fallback;
}

bool _bool(Object? value) => value is bool ? value : false;

String _str(Object? value) => value is String ? value : '';

String _strOr(Object? value, String fallback) => value is String ? value : fallback;

int _max(int left, int right) => left > right ? left : right;

int _nonnegative(int value) => _max(0, value);

int _clampInt(int value, int lower, int upper) {
  if (value < lower) {
    return lower;
  }
  if (value > upper) {
    return upper;
  }
  return value;
}

double _clampDouble(double value, double lower, double upper) {
  if (value < lower) {
    return lower;
  }
  if (value > upper) {
    return upper;
  }
  return value;
}

List<String> _strings(Object? value) {
  final List<String> result = <String>[];
  final Set<String> seen = <String>{};
  for (final Object? entry in _list(value)) {
    final String text = _str(entry);
    if (text.isEmpty || !seen.add(text)) {
      continue;
    }
    result.add(text);
  }
  return result;
}

// ---------------------------------------------------------------------------
// Contract mirror: view (storage.md §2.3, MusicSession.cpp:215-234 / :237-262)
// ---------------------------------------------------------------------------

Map<String, Object?> normalizeView(
  Map<String, Object?> saved, {
  required bool hasCurrent,
  required int settingsScrollMaximum,
}) {
  final String modal = _str(saved['modal']);
  final String tab = _str(saved['tab']);
  return <String, Object?>{
    'mode': _str(saved['mode']) == 'detail' && hasCurrent ? 'detail' : 'archive',
    'selected': _clampInt(_int(saved['selected']), 0, 39),
    'tab': viewTabs.contains(tab) ? tab : 'overview',
    'modal': modalWhitelist.contains(modal) ? modal : '',
    'queueOffset': _nonnegative(_int(saved['queueOffset'])),
    'settingsScroll': _clampDouble(
      _double(saved['settingsScroll']),
      0,
      settingsScrollMaximum.toDouble(),
    ),
    'query': _str(saved['query']),
    'groupBy': _strOr(saved['groupBy'], 'none'),
    'activeGroup': _str(saved['activeGroup']),
    'artistTab': _strOr(saved['artistTab'], 'songs'),
    'listOffset': _nonnegative(_int(saved['listOffset'])),
    'trackOffset': _nonnegative(_int(saved['trackOffset'])),
    'bodyOffset': _nonnegative(_int(saved['bodyOffset'])),
    'musicCollection': _clampInt(_int(saved['musicCollection'], 1), 1, 4),
    'trackListMode': _bool(saved['trackListMode']),
    'lyricsMode': _bool(saved['lyricsMode']),
  };
}

/// storage.md §2.2: MusicSession.cpp:177-186. search() is an independent if;
/// the two loading replays are a mutually exclusive else-if, directory first.
bool shouldReplaySearch(Map<String, Object?> savedLibrary) =>
    _bool(savedLibrary['searchLoading']) && _str(savedLibrary['keyword']).isNotEmpty;

String followUpBranch(
  Map<String, Object?> savedLibrary, {
  required bool hasDirectory,
  required bool directorySongsEmpty,
  required bool currentNonEmpty,
}) {
  if (_bool(savedLibrary['directoryLoading']) && hasDirectory && directorySongsEmpty) {
    return 'enterDirectory';
  }
  if (_bool(savedLibrary['detailLoading']) && currentNonEmpty) {
    return 'choose';
  }
  return 'none';
}

// ---------------------------------------------------------------------------
// Contract mirror: library normalization (storage.md §2.2, MusicSession.cpp:88-213)
// ---------------------------------------------------------------------------

Map<String, Object?> normalizeSource(Map<String, Object?> saved) {
  final List<Object?> items = _list(saved['items']);
  return <String, Object?>{
    'items': items,
    'total': _max(items.length, _nonnegative(_int(saved['total']))),
    'offset': _clampInt(_int(saved['offset']), 0, _max(0, items.length - 1)),
    'more': _bool(saved['more']),
    'row': _clampInt(_int(saved['row']), 0, 7),
  };
}

Map<String, Object?> normalizeDirectory(Map<String, Object?> saved) {
  final List<Object?> songs = _list(saved['songs']);
  final List<Object?> ids = _list(saved['ids']);
  final int index = _clampInt(_int(saved['index']), 0, _max(0, songs.length - 1));
  final String sortField = _strOr(saved['sortField'], 'none');
  return <String, Object?>{
    'item': _map(saved['item']),
    'songs': songs,
    'sortField': sortFields.contains(sortField) ? sortField : 'none',
    'ids': ids,
    'albums': _list(saved['albums']),
    'cursor': _clampInt(_int(saved['cursor']), 0, ids.length),
    'index': index,
    'anchor': _clampInt(_int(saved['anchor']), 0, 39),
    // storage.md §2.2: page is written but ignored on read; recomputed as
    // index / 40 * 40 with integer division (MusicSession.cpp:130).
    'page': index ~/ 40 * 40,
    'parentPhysical': _clampInt(_int(saved['parentPhysical']), 0, 39),
    'parentLane': _clampInt(_int(saved['parentLane']), 0, 4),
    'parentItem': _map(saved['parentItem']),
    'albumCursor': _nonnegative(_int(saved['albumCursor'])),
    'albumsMore': _bool(saved['albumsMore']),
  };
}

Map<String, Object?> normalizeDiscover(Map<String, Object?> saved) => <String, Object?>{
      'tab': _strOr(saved['tab'], 'playlists'),
      'items': _list(saved['items']),
      'offset': _nonnegative(_int(saved['offset'])),
      'more': _bool(saved['more']),
      'category': _strOr(saved['category'], '全部'),
      'newSongArea': _strOr(saved['newSongArea'], '5'),
    };

Map<String, Object?> normalizeLibraryScalars(Map<String, Object?> saved) => <String, Object?>{
      'keyword': _str(saved['keyword']),
      'searchKind': _strOr(saved['searchKind'], 'song'),
      'status': _str(saved['status']),
      'searchCursor': _nonnegative(_int(saved['searchCursor'])),
      'playlistCursor': _nonnegative(_int(saved['playlistCursor'])),
      'albumCursor': _nonnegative(_int(saved['albumCursor'])),
      'likedCursor': _nonnegative(_int(saved['likedCursor'])),
      // storage.md §2.2: non-array or missing becomes std::nullopt, not [].
      'likedIDs': saved['likedIDs'] is List ? _list(saved['likedIDs']) : null,
      'groupName': _str(saved['groupName']),
      'groupLane': _clampInt(_int(saved['groupLane'], -1), -1, 4),
      'groupIndices': _list(saved['groupIndices'])
          .map((Object? value) => _nonnegative(_int(value)))
          .toList(),
      'trackCursor': _nonnegative(_int(saved['trackCursor'])),
      'privateSelection': _bool(saved['privateSelection']),
      'albumLoaded': _bool(saved['albumLoaded']),
      'directoryInfo': _bool(saved['directoryInfo']),
      'wantsSongDetails': _bool(saved['wantsSongDetails']),
    };

/// storage.md §2.2 / §2.4: MusicSession.cpp:88-102. Returns null when the
/// identity and structure gates accept the file, otherwise the first failing
/// gate.
String? libraryGateFailure(
  Map<String, Object?> saved, {
  required String provider,
  required String edition,
  required String uid,
  required Map<int, Set<int>> physicalSlots,
}) {
  if (_str(saved['provider']) != provider) {
    return 'provider';
  }
  if (_str(saved['edition']) != edition) {
    return 'edition';
  }
  if (_str(saved['uid']) != uid) {
    return 'uid';
  }
  final List<Object?> sources = _list(saved['sources']);
  final int lane = _int(saved['selectedLane'], -1);
  final int physical = _int(saved['selectedPhysical'], -1);
  if (sources.length != 5) {
    return 'sources';
  }
  if (lane < 0 || lane >= 5) {
    return 'selectedLane';
  }
  if (physical < -1 || physical >= 40) {
    return 'selectedPhysical';
  }
  if (physical >= 0 && !(physicalSlots[lane] ?? <int>{}).contains(physical)) {
    return 'physicalSlot';
  }
  if (_list(saved['directories']).length > 64) {
    return 'directories';
  }
  return null;
}

// ---------------------------------------------------------------------------
// Contract mirror: session envelope (storage.md §2.1, MusicSession.cpp:215-284)
// ---------------------------------------------------------------------------

const int sessionVersion = 1;

/// storage.md §1.1 / §2.1: NativeApplication.cpp:66 accepts size <= limit and
/// MusicSession.cpp:276 keeps the previous file when size > limit, so the two
/// gates agree on the boundary: limit itself is allowed, limit + 1 is not.
bool withinSessionLimit(int byteLength) => byteLength <= sessionLimitBytes;

/// storage.md §2.1: MusicSession.cpp:238-240 returns false without touching the
/// view when the version differs or the library gate rejects the file, so a
/// rejected library also rejects the view; there is no partial restore.
String? restoreSessionFailure(
  Map<String, Object?> file, {
  required int byteLength,
  required String provider,
  required String edition,
  required String uid,
  required Map<int, Set<int>> physicalSlots,
}) {
  if (!withinSessionLimit(byteLength)) {
    return 'limit';
  }
  if (_int(file['version'], -1) != sessionVersion) {
    return 'version';
  }
  return libraryGateFailure(
    _map(file['library']),
    provider: provider,
    edition: edition,
    uid: uid,
    physicalSlots: physicalSlots,
  );
}

// ---------------------------------------------------------------------------
// Contract mirror: player and queue (storage.md §3, MusicPlayer.cpp:749-780,
// PlaybackQueue.cpp:14-38 / :398-422)
// ---------------------------------------------------------------------------

double _doubleOrNan(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.nan;
}

/// storage.md §3: MusicPlayer.cpp:766, whitelist or "all".
String playerMode(Object? saved) {
  final String mode = _str(saved);
  return playerModes.contains(mode) ? mode : 'all';
}

/// storage.md §3: MusicPlayer.cpp:760-780. The position gate returns before the
/// mode is assigned, so an unusable position rejects the whole player part while
/// a wrong-shaped queue does not.
String playerRestoreBranch(Map<String, Object?> saved, {required String provider}) {
  final double position = _doubleOrNan(saved['position']);
  if (position.isNaN || !position.isFinite || position < 0 || position > 1e12) {
    return 'reject-position';
  }
  playerMode(saved['mode']);
  if (_map(saved['current']).isEmpty) {
    return 'queue-only';
  }
  final Map<String, Object?> track = _map(saved['current']);
  if (_str(track['kind']) != 'song') {
    return 'abort-track';
  }
  if (_strOr(track['provider'], provider) != provider) {
    return 'abort-provider';
  }
  return 'queue-then-play';
}

/// storage.md §3: PlaybackQueue.cpp:36-38.
String queueIdentity(Map<String, Object?> track) =>
    _strOr(track['provider'], 'netease') + ':' + _str(track['id']);

/// storage.md §3: PlaybackQueue.cpp:14-30. Only complete songs survive, and the
/// provider:id identity removes repeats.
List<Map<String, Object?>> queueSanitize(List<Object?> values) {
  final List<Map<String, Object?>> result = <Map<String, Object?>>[];
  final Set<String> seen = <String>{};
  for (final Object? value in values) {
    final Map<String, Object?> track = _map(value);
    if (_str(track['kind']) != 'song' || _str(track['id']).isEmpty) {
      continue;
    }
    if (!seen.add(queueIdentity(track))) {
      continue;
    }
    result.add(track);
  }
  return result;
}

/// storage.md §3: PlaybackService.cpp:425-432. The legacy fallback exists only
/// while playback-session.json does not exist; an existing but unreadable or
/// oversized file never falls back to session.json.
String playbackRestoreFileName({required bool sessionFileExists}) =>
    sessionFileExists ? playbackSessionFileName : sessionFileName;

/// storage.md §3: PlaybackService.cpp:429 and :444, same boundary as the GUI.
bool playbackServiceWithinLimit(int byteLength) => byteLength <= sessionLimitBytes;

// ---------------------------------------------------------------------------
// Contract mirror: preferences (storage.md §5.2, Host.cpp:1041-1095)
// ---------------------------------------------------------------------------

const String panelPrefix = 'panel/';

String panelStorageKey(String key) => panelPrefix + key;

/// storage.md §5.2: Host.cpp:1072-1075, offline and unknown keys read as empty.
String panelRead(String key, {required bool offline, required Map<String, String> store}) {
  if (offline || !panelKeys.contains(key)) {
    return '';
  }
  return store[panelStorageKey(key)] ?? '';
}

/// storage.md §5.3: Host.cpp:1094, a strict less-than on UTF-16 code units:
/// 262143 characters are written, 262144 are dropped. An empty value is legal
/// and is how account ids are cleared (MusicAccount.cpp:697).
bool panelWriteAllowed(String key, String value, {required bool offline}) =>
    !offline && value.length < panelValueLimit && panelKeys.contains(key);

// ---------------------------------------------------------------------------
// Contract mirror: collections (storage.md §8, LocalCollections.cpp:13-85)
// ---------------------------------------------------------------------------

String collectionsPath(String provider) => '$collectionsDirectory/$provider.json';

List<String> collectionStrings(Object? value) => _strings(value);

List<Map<String, Object?>> _stableSortCreatedAtDesc(List<Map<String, Object?>> records) {
  final List<Map<String, Object?>> result = List<Map<String, Object?>>.from(records);
  for (int index = 1; index < result.length; index++) {
    final Map<String, Object?> current = result[index];
    final double key = _double(current['createdAt']);
    int cursor = index - 1;
    while (cursor >= 0 && _double(result[cursor]['createdAt']) < key) {
      result[cursor + 1] = result[cursor];
      cursor--;
    }
    result[cursor + 1] = current;
  }
  return result;
}

/// storage.md §8: LocalCollections.cpp:36-71. A version or provider mismatch
/// yields empty collections without deleting the file.
Map<String, Object?> loadCollections(Map<String, Object?> document, {required String provider}) {
  if (_int(document['version'], -1) != 1 || _str(document['provider']) != provider) {
    return <String, Object?>{'liked': <String>[], 'playlists': <Map<String, Object?>>[]};
  }
  final List<Map<String, Object?>> playlists = <Map<String, Object?>>[];
  for (final Object? entry in _list(document['playlists'])) {
    final Map<String, Object?> record = _map(entry);
    final String id = _str(record['id']);
    final String name = _str(record['name']).trim();
    if (id.isEmpty || name.isEmpty) {
      continue;
    }
    playlists.add(<String, Object?>{
      'id': id,
      'name': name,
      'createdAt': _double(record['createdAt']),
      'trackIDs': collectionStrings(record['trackIDs']),
    });
  }
  return <String, Object?>{
    'liked': collectionStrings(document['liked']),
    'playlists': _stableSortCreatedAtDesc(playlists),
  };
}

// ---------------------------------------------------------------------------
// Contract mirror: credential (storage.md §6, PlatformAndroid.cpp:13-46,
// Host.cpp:541-553 / :511-529)
// ---------------------------------------------------------------------------

/// storage.md §6.1: PlatformAndroid.cpp:29-40, in order, and not atomic.
List<String> credentialWriteSteps() => List<String>.from(qtCredentialWriteSteps);

/// storage.md §6.1: PlatformAndroid.cpp:29-41. Every early return reports the
/// same note; success is an empty string, which is what clears the banner.
String credentialWriteResult({
  required bool directoryCreated,
  required bool opened,
  required int written,
  required int expected,
}) {
  if (!directoryCreated || !opened) {
    return credentialFailureNote;
  }
  return written == expected ? '' : credentialFailureNote;
}

/// storage.md §6.1: QFile::ReadOwner | QFile::WriteOwner, i.e. 0600.
bool credentialOwnerOnly(int mode) => mode == credentialMode;

/// storage.md §6.2: Host.cpp:548-552.
bool hasCredential(
  String provider, {
  required Map<String, Object?> cookies,
  required String edition,
}) {
  if (provider == 'kugou') {
    final Map<String, Object?> editions = _map(cookies['__kugou']);
    final Map<String, Object?> credential = _map(editions[edition]);
    final String token = _str(credential['token']);
    final int userId = int.tryParse(_str(credential['userid'])) ?? 0;
    return token.isNotEmpty && userId > 0;
  }
  if (provider == 'qq') {
    return _str(cookies['qqmusic_session']).isNotEmpty;
  }
  if (provider == 'netease') {
    return _str(cookies['MUSIC_U']).isNotEmpty;
  }
  return false;
}

/// storage.md §6.2: Host.cpp:511-516, the edition cookie lives inside __kugou.
Map<String, Object?> acceptKugouCookies(
  Map<String, Object?> cookies, {
  required String edition,
  required Map<String, Object?> credential,
}) {
  final Map<String, Object?> next = Map<String, Object?>.from(cookies);
  final Map<String, Object?> editions = _map(cookies['__kugou']);
  editions[edition] = credential;
  next['__kugou'] = editions;
  return next;
}

/// storage.md §6.3: the device files of each music source.
String deviceStateFile(String provider) => deviceStateFiles[provider] ?? '';

// ---------------------------------------------------------------------------
// Contract mirror: save path (storage.md §2.1, MusicSession.cpp:269-284)
// ---------------------------------------------------------------------------

/// storage.md §2.1: the bytes are serialised first, the QSaveFile is constructed
/// next, and the 64 MiB gate then returns before open/write/commit. Exceeding
/// the limit therefore leaves the previous session.json untouched instead of
/// writing a truncated file.
List<String> sessionSaveSteps(int byteLength) {
  final List<String> steps = <String>['construct'];
  if (byteLength > sessionLimitBytes) {
    steps.addAll(<String>['warn', 'return']);
    return steps;
  }
  steps.addAll(<String>['mkdir', 'open', 'write', 'commit']);
  return steps;
}

/// storage.md §2.1: what session.json holds afterwards.
String sessionSaveResult({required String previous, required String next, required int byteLength}) =>
    sessionSaveSteps(byteLength).contains('commit') ? next : previous;

// ---------------------------------------------------------------------------
// Contract mirror: collections size gate (LocalCollections.cpp:36-42)
// ---------------------------------------------------------------------------

/// storage.md §8: load() returns early when the file is larger than 16 MiB, so
/// an oversized file reads as empty collections and is left in place.
bool collectionsWithinLimit(int byteLength) => byteLength <= collectionsLimitBytes;

// ---------------------------------------------------------------------------
// Contract mirror: logout (storage.md §6.5, Host.cpp:609-661,
// MusicAccount.cpp:670-717)
// ---------------------------------------------------------------------------

/// storage.md §6.5: Host.cpp:619-644. Only the current source's cookies are
/// dropped; the other source keeps its session so a later provider switch can
/// restore it without a new login.
Map<String, Object?> logoutCookies(
  String provider, {
  required Map<String, Object?> cookies,
  required String edition,
}) {
  final Map<String, Object?> next = Map<String, Object?>.from(cookies);
  if (provider == 'qq') {
    next.remove('qqmusic_session');
    next.remove('__qqSessions');
    return next;
  }
  if (provider == 'kugou') {
    final Map<String, Object?> editions = _map(cookies['__kugou']);
    editions.remove(edition);
    if (editions.isEmpty) {
      next.remove('__kugou');
    } else {
      next['__kugou'] = editions;
    }
    return next;
  }
  final Object? kugou = cookies['__kugou'];
  final Object? qqToken = cookies['qqmusic_session'];
  final Object? qqSessions = cookies['__qqSessions'];
  next.clear();
  if (kugou != null) {
    next['__kugou'] = kugou;
  }
  if (qqToken != null) {
    next['qqmusic_session'] = qqToken;
  }
  if (qqSessions != null) {
    next['__qqSessions'] = qqSessions;
  }
  return next;
}

/// storage.md §6.5: Host.cpp:655-661, an empty jar deletes the file, a partial
/// jar is saved back.
String credentialFileAction(Map<String, Object?> cookies) =>
    cookies.isEmpty ? 'delete' : 'save';

/// storage.md §6.5 / MusicAccount.cpp:682,697: logout resets the play history
/// and clears only the current source's account id, through the ordinary panel
/// write gate (the empty value is what clears it).
Map<String, String> logoutPreferences(
  String provider,
  String edition,
  Map<String, String> store,
) {
  final Map<String, String> next = Map<String, String>.from(store);
  next[panelStorageKey('play-history')] = '[]';
  next[panelStorageKey('account-id-' + accountKeyFor(provider, edition))] = '';
  return next;
}

// ---------------------------------------------------------------------------
// Fixture loading. Only this repository's own fixture is read; no platform path
// and no session.json of a device is ever touched.
// ---------------------------------------------------------------------------

String? _fixtureText;

String fixtureText() {
  return _fixtureText ??= File('test/fixtures/session_view.json').readAsStringSync();
}

Map<String, Object?> fixture() => _map(jsonDecode(fixtureText()));

/// QJsonObject keeps its keys sorted, so Qt writes session.json in sorted order
/// regardless of the initializer order in MusicSession.cpp:216-234.
bool _sortedAscending(List<String> keys) {
  final List<String> copy = List<String>.from(keys)..sort();
  for (int index = 0; index < keys.length; index++) {
    if (keys[index] != copy[index]) {
      return false;
    }
  }
  return true;
}

List<String> _keys(Map<String, Object?> value) => value.keys.toList();

/// storage.md §2.2: MusicLibrary::sessionState writes kugou <-> edition.
String accountKeyFor(String provider, String edition) =>
    provider == 'kugou' ? 'kugou-' + edition : provider;

/// storage.md §6.2: MusicAccount.cpp:105-110, uid mirrors the account preference
/// and is empty unless the host reports an authenticated credential.
String accountUid({
  required bool authenticated,
  required String provider,
  required String edition,
  required Map<String, String> preferences,
}) {
  if (!authenticated) {
    return '';
  }
  return preferences[panelStorageKey('account-id-' + accountKeyFor(provider, edition))] ?? '';
}

void main() {
  // storage.md §2.1: the envelope is {version:1, library, player, view} and the
  // four keys are the whole file, not a subset the reader may extend.
  group('session envelope fixture', () {
    test('is a version 1 envelope with library, player and view', () {
      final Map<String, Object?> file = fixture();
      expect(_keys(file).toSet(), <String>{'version', 'library', 'player', 'view'});
      expect(file['version'], sessionVersion);
      expect(_map(file['library']), isNotEmpty);
      expect(_map(file['player']), isNotEmpty);
      expect(_map(file['view']), isNotEmpty);
      // The fixture is emitted the way QJsonObject serialises: sorted keys.
      expect(_sortedAscending(_keys(file)), isTrue);
    });

    test('library carries the 31 keys of MusicLibrary::sessionState', () {
      final Map<String, Object?> library = _map(fixture()['library']);
      expect(_keys(library).toSet(), libraryKeys.toSet());
      expect(libraryKeys, hasLength(31));
      expect(_keys(library), hasLength(31));
      expect(_sortedAscending(_keys(library)), isTrue);
      expect(library['provider'], 'netease');
      expect(library['edition'], 'standard');
      expect(library['uid'], '10001');
    });

    test('sources hold five lanes of five keys', () {
      final List<Object?> sources = _list(_map(fixture()['library'])['sources']);
      expect(sources, hasLength(5));
      for (final Object? entry in sources) {
        expect(_keys(_map(entry)).toSet(), sourceKeys.toSet());
      }
      final Map<String, Object?> first = _map(sources.first);
      expect(first['row'], 0);
      expect(_bool(first['more']), isTrue);
    });

    test('directories keep the 14-key folder state and the parent chain', () {
      final List<Object?> folders = _list(_map(fixture()['library'])['directories']);
      expect(folders, isNotEmpty);
      expect(folders.length, lessThanOrEqualTo(64));
      for (final Object? entry in folders) {
        expect(_keys(_map(entry)).toSet(), directoryKeys.toSet());
      }
      final Map<String, Object?> leaf = _map(folders.last);
      if (folders.length > 1) {
        expect(_map(leaf['parentItem']), _map(_map(folders.first)['item']));
      }
      expect(_int(leaf['page']), _int(leaf['index']) ~/ 40 * 40);
    });

    test('discover keeps its six keys', () {
      final Map<String, Object?> discover = _map(_map(fixture()['library'])['discover']);
      expect(_keys(discover).toSet(), discoverKeys.toSet());
      expect(discover['tab'], 'playlists');
      expect(discover['newSongArea'], '5');
    });

    test('player carries the seven keys of MusicPlayer::sessionState', () {
      final Map<String, Object?> player = _map(fixture()['player']);
      expect(_keys(player).toSet(), playerKeys.toSet());
      expect(_keys(player), hasLength(7));
      expect(_sortedAscending(_keys(player)), isTrue);
      expect(playerModes.contains(player['mode']), isTrue);
      expect(_list(player['queue']), isNotEmpty);
      // The queue is a list of complete tracks, not a list of ids.
      expect(_str(_map(_list(player['queue']).first)['kind']), 'song');
    });

    test('view carries exactly the sixteen frozen keys', () {
      final Map<String, Object?> view = _map(fixture()['view']);
      expect(_keys(view).toSet(), viewKeys.toSet());
      expect(_keys(view), hasLength(16));
      expect(_sortedAscending(_keys(view)), isTrue);
      expect(modalWhitelist.contains(view['modal']), isTrue);
    });
  });

  // storage.md §2.3: MusicSession.cpp:237-267 restores the view only after the
  // library gate passed, and every field is coerced, never trusted.
  group('view restore', () {
    test('normalises to the frozen sixteen keys in contract order', () {
      final Map<String, Object?> restored = normalizeView(
        _map(fixture()['view']),
        hasCurrent: true,
        settingsScrollMaximum: 1000,
      );
      expect(_keys(restored), viewKeys);
      expect(restored['mode'], 'detail');
      expect(restored['selected'], 3);
      expect(restored['tab'], 'notes');
      expect(restored['modal'], 'queue');
      expect(restored['queueOffset'], 12);
      expect(restored['settingsScroll'], 240.5);
      expect(restored['query'], '夜');
      expect(restored['groupBy'], 'album');
      expect(restored['activeGroup'], '夜航');
      expect(restored['artistTab'], 'albums');
      expect(restored['listOffset'], 40);
      expect(restored['trackOffset'], 8);
      expect(restored['bodyOffset'], 16);
      expect(restored['musicCollection'], 2);
      expect(restored['trackListMode'], isTrue);
      expect(restored['lyricsMode'], isTrue);
    });

    test('detail mode needs a current track', () {
      final Map<String, Object?> view = _map(fixture()['view']);
      expect(normalizeView(view, hasCurrent: false, settingsScrollMaximum: 1000)['mode'], 'archive');
      expect(normalizeView(view, hasCurrent: true, settingsScrollMaximum: 1000)['mode'], 'detail');
    });

    test('modal restore only accepts the whitelist and never the closing marker', () {
      for (final String modal in modalWhitelist) {
        final Map<String, Object?> view = <String, Object?>{'modal': modal};
        expect(normalizeView(view, hasCurrent: false, settingsScrollMaximum: 0)['modal'], modal);
      }
      const List<String> rejected = <String>['', 'unknown', 'Saved', 'queue '];
      for (final String modal in rejected) {
        final Map<String, Object?> view = <String, Object?>{'modal': modal};
        expect(normalizeView(view, hasCurrent: false, settingsScrollMaximum: 0)['modal'], '');
      }
    });

    test('tab and offsets are coerced', () {
      expect(
        normalizeView(<String, Object?>{'tab': 'history'}, hasCurrent: false, settingsScrollMaximum: 0)['tab'],
        'history',
      );
      expect(
        normalizeView(<String, Object?>{'tab': 'bogus'}, hasCurrent: false, settingsScrollMaximum: 0)['tab'],
        'overview',
      );
      expect(
        normalizeView(<String, Object?>{'tab': 3}, hasCurrent: false, settingsScrollMaximum: 0)['tab'],
        'overview',
      );
      for (final String key in <String>['queueOffset', 'listOffset', 'trackOffset', 'bodyOffset']) {
        expect(normalizeView(<String, Object?>{key: -7}, hasCurrent: false, settingsScrollMaximum: 0)[key], 0);
        expect(normalizeView(<String, Object?>{key: 7}, hasCurrent: false, settingsScrollMaximum: 0)[key], 7);
      }
    });

    test('selected, scroll and collection are clamped', () {
      expect(normalizeView(<String, Object?>{'selected': -5}, hasCurrent: false, settingsScrollMaximum: 0)['selected'], 0);
      expect(normalizeView(<String, Object?>{'selected': 99}, hasCurrent: false, settingsScrollMaximum: 0)['selected'], 39);
      expect(
        normalizeView(<String, Object?>{'settingsScroll': 5000.0}, hasCurrent: false, settingsScrollMaximum: 1000)['settingsScroll'],
        1000.0,
      );
      expect(
        normalizeView(<String, Object?>{'settingsScroll': -3.0}, hasCurrent: false, settingsScrollMaximum: 1000)['settingsScroll'],
        0.0,
      );
      expect(normalizeView(<String, Object?>{}, hasCurrent: false, settingsScrollMaximum: 0)['musicCollection'], 1);
      expect(normalizeView(<String, Object?>{'musicCollection': 0}, hasCurrent: false, settingsScrollMaximum: 0)['musicCollection'], 1);
      expect(normalizeView(<String, Object?>{'musicCollection': 9}, hasCurrent: false, settingsScrollMaximum: 0)['musicCollection'], 4);
    });

    test('strings and booleans fall back instead of being coerced by truthiness', () {
      final Map<String, Object?> restored = normalizeView(
        <String, Object?>{'groupBy': 5, 'artistTab': null, 'trackListMode': 'true', 'lyricsMode': 1, 'query': 42},
        hasCurrent: false,
        settingsScrollMaximum: 0,
      );
      expect(restored['groupBy'], 'none');
      expect(restored['artistTab'], 'songs');
      expect(restored['trackListMode'], isFalse);
      expect(restored['lyricsMode'], isFalse);
      expect(restored['query'], '');
    });
  });

  // storage.md §2.1 / §2.4: the 64 MiB gate and the identity gate.
  group('session gate', () {
    test('the limit is 64 MiB and both sides agree on the boundary', () {
      expect(sessionLimitBytes, 67108864);
      expect(sessionLimitBytesPlusOne, 67108865);
      expect(withinSessionLimit(sessionLimitBytes), isTrue);
      expect(withinSessionLimit(sessionLimitBytesPlusOne), isFalse);
      expect(withinSessionLimit(0), isTrue);
      expect(playbackServiceWithinLimit(sessionLimitBytes), isTrue);
      expect(playbackServiceWithinLimit(sessionLimitBytesPlusOne), isFalse);
    });

    test('the read path rejects an oversized file before the version gate', () {
      expect(
        restoreSessionFailure(
          fixture(),
          byteLength: sessionLimitBytesPlusOne,
          provider: 'netease',
          edition: 'standard',
          uid: '10001',
          physicalSlots: const <int, Set<int>>{0: <int>{3}},
        ),
        'limit',
      );
      // The size gate runs before the version gate.
      final Map<String, Object?> wrongVersion = Map<String, Object?>.of(fixture())..['version'] = 2;
      expect(
        restoreSessionFailure(
          wrongVersion,
          byteLength: sessionLimitBytesPlusOne,
          provider: 'netease',
          edition: 'standard',
          uid: '10001',
          physicalSlots: const <int, Set<int>>{0: <int>{3}},
        ),
        'limit',
      );
      expect(
        restoreSessionFailure(
          wrongVersion,
          byteLength: sessionLimitBytes,
          provider: 'netease',
          edition: 'standard',
          uid: '10001',
          physicalSlots: const <int, Set<int>>{0: <int>{3}},
        ),
        'version',
      );
    });

    test('the identity and structure gates report the first failure in order', () {
      Map<String, Object?> library() => Map<String, Object?>.of(_map(fixture()['library']));

      String? check(Map<String, Object?> value) => restoreSessionFailure(
            <String, Object?>{'version': 1, 'library': value},
            byteLength: 128,
            provider: 'netease',
            edition: 'standard',
            uid: '10001',
            physicalSlots: const <int, Set<int>>{0: <int>{3}},
          );

      expect(check(library()), isNull);
      expect(check(library()..['provider'] = 'qq'), 'provider');
      expect(check(library()..['edition'] = 'lite'), 'edition');
      expect(check(library()..['uid'] = ''), 'uid');
      expect(check(library()..['sources'] = <Object?>[]), 'sources');
      expect(check(library()..['selectedLane'] = 9), 'selectedLane');
      expect(check(library()..['selectedLane'] = -1), 'selectedLane');
      expect(check(library()..['selectedPhysical'] = 40), 'selectedPhysical');
      expect(check(library()..['selectedPhysical'] = 7), 'physicalSlot');
      expect(
        check(library()..['directories'] = List<Object?>.filled(65, <String, Object?>{})),
        'directories',
      );
      expect(check(library()..['selectedPhysical'] = -1), isNull);
    });
  });

  // storage.md §3: MusicPlayer.cpp:760-780 and PlaybackQueue.cpp:14-38.
  group('player and queue', () {
    test('the fixture restores the queue before selecting the saved track', () {
      expect(
        playerRestoreBranch(_map(fixture()['player']), provider: 'netease'),
        'queue-then-play',
      );
    });

    test('an unusable position rejects the player part before the mode is set', () {
      const List<Object?> rejected = <Object?>[null, 'not-a-number', -1.0, 1e12 + 1];
      for (final Object? position in rejected) {
        expect(
          playerRestoreBranch(<String, Object?>{'position': position, 'mode': 'shuffle'}, provider: 'netease'),
          'reject-position',
        );
      }
      for (final Object? position in <Object?>[0, 42.5, 1e12]) {
        expect(
          playerRestoreBranch(<String, Object?>{'position': position}, provider: 'netease'),
          'queue-only',
        );
      }
    });

    test('the mode is validated independently of the track', () {
      expect(playerMode('shuffle'), 'shuffle');
      expect(playerMode('off'), 'off');
      expect(playerMode('one'), 'one');
      expect(playerMode('all'), 'all');
      expect(playerMode(''), 'all');
      expect(playerMode(null), 'all');
      expect(playerMode(7), 'all');
    });

    test('a track that is not the current provider song aborts before the queue', () {
      final Map<String, Object?> player = _map(fixture()['player']);
      final Map<String, Object?> current = _map(player['current']);
      expect(
        playerRestoreBranch(
          <String, Object?>{'position': 1.0, 'current': <String, Object?>{...current, 'kind': 'album'}},
          provider: 'netease',
        ),
        'abort-track',
      );
      expect(
        playerRestoreBranch(
          <String, Object?>{'position': 1.0, 'current': <String, Object?>{...current, 'provider': 'qq'}},
          provider: 'netease',
        ),
        'abort-provider',
      );
      // A missing provider is read as the active source (MusicPlayer.cpp:774).
      final Map<String, Object?> anonymous = Map<String, Object?>.of(current)..remove('provider');
      expect(
        playerRestoreBranch(<String, Object?>{'position': 1.0, 'current': anonymous}, provider: 'netease'),
        'queue-then-play',
      );
    });

    test('queue identity is provider:id with netease as the default provider', () {
      expect(queueIdentity(<String, Object?>{'provider': 'netease', 'id': '1901'}), 'netease:1901');
      expect(queueIdentity(<String, Object?>{'provider': 'qq', 'id': '1901'}), 'qq:1901');
      expect(queueIdentity(<String, Object?>{'id': '1901'}), 'netease:1901');
    });

    test('the queue drops incomplete tracks and repeats', () {
      final List<Map<String, Object?>> sanitized = queueSanitize(<Object?>[
        <String, Object?>{'kind': 'song', 'id': '1901', 'provider': 'netease'},
        <String, Object?>{'kind': 'song', 'id': '1901', 'provider': 'netease'},
        <String, Object?>{'kind': 'song', 'id': '1901', 'provider': 'qq'},
        <String, Object?>{'kind': 'album', 'id': '1901', 'provider': 'netease'},
        <String, Object?>{'kind': 'song', 'id': '', 'provider': 'netease'},
        <String, Object?>{'kind': 'song', 'id': '1902'},
      ]);
      expect(sanitized, hasLength(3));
      expect(sanitized.map(queueIdentity).toList(), <String>['netease:1901', 'qq:1901', 'netease:1902']);
    });
  });

  // storage.md §3: PlaybackService.cpp:419-448.
  group('playback service session', () {
    test('the legacy fallback exists only while the new file is absent', () {
      expect(playbackRestoreFileName(sessionFileExists: true), 'playback-session.json');
      expect(playbackRestoreFileName(sessionFileExists: false), 'session.json');
      expect(playbackSessionFileName, 'playback-session.json');
      expect(sessionFileName, 'session.json');
    });

    test('an existing but unusable file never falls back to the GUI session', () {
      // PlaybackService.cpp:425 only checks existence, so a corrupt or oversized
      // playback-session.json is read (and rejected) instead of replaying
      // session.json: the file name does not depend on its content.
      final String chosen = playbackRestoreFileName(sessionFileExists: true);
      expect(chosen, isNot(sessionFileName));
      expect(playbackServiceWithinLimit(sessionLimitBytesPlusOne), isFalse);
    });
  });

  // storage.md §5.2 / §5.3: Host.cpp:1041-1095.
  group('panel preferences', () {
    test('the key list has exactly 53 unique entries', () {
      expect(panelKeys, hasLength(53));
      expect(panelKeys.toSet(), hasLength(53));
      expect(panelKeys.first, 'search-history');
      expect(panelKeys.last, 'account-id-kugou-lite');
      expect(panelKeys.contains('kugou-edition'), isTrue);
      expect(panelKeys.contains('account-id-kugou-standard'), isTrue);
      // Read and write share this one list; a split list is the documented bug.
      expect(panelKeys.where((String key) => key == 'volume'), hasLength(1));
    });

    test('values live under the panel/ prefix', () {
      expect(panelStorageKey('volume'), 'panel/volume');
      expect(panelStorageKey('theme'), 'panel/theme');
    });

    test('offline and unknown keys read as empty', () {
      const Map<String, String> store = <String, String>{'panel/volume': '0.7'};
      expect(panelRead('volume', offline: false, store: store), '0.7');
      expect(panelRead('volume', offline: true, store: store), '');
      expect(panelRead('not-a-key', offline: false, store: store), '');
      expect(panelRead('volume', offline: false, store: const <String, String>{}), '');
    });

    test('writes are gated by a strict 262144 UTF-16 limit', () {
      expect(panelValueLimit, 262144);
      final String atLimit = List<String>.filled(panelValueLimit - 1, 'a').join();
      final String overLimit = List<String>.filled(panelValueLimit, 'a').join();
      expect(atLimit.length, 262143);
      expect(overLimit.length, 262144);
      expect(panelWriteAllowed('volume', atLimit, offline: false), isTrue);
      expect(panelWriteAllowed('volume', overLimit, offline: false), isFalse);
      expect(panelWriteAllowed('volume', '', offline: false), isTrue);
      expect(panelWriteAllowed('not-a-key', '1', offline: false), isFalse);
      expect(panelWriteAllowed('volume', '1', offline: true), isFalse);
    });

    test('the read path has no size gate', () {
      final String overLimit = List<String>.filled(panelValueLimit, 'a').join();
      final Map<String, String> store = <String, String>{'panel/volume': overLimit};
      expect(panelRead('volume', offline: false, store: store).length, panelValueLimit);
    });
  });

  // storage.md §8: LocalCollections.cpp:13-85.
  group('local collections', () {
    test('the file lives under collections/<provider>.json and caps at 16 MiB', () {
      expect(collectionsLimitBytes, 16777216);
      expect(collectionsDirectory, 'collections');
      expect(collectionsPath('netease'), 'collections/netease.json');
      expect(collectionsPath('siren'), 'collections/siren.json');
    });

    test('a version or provider mismatch yields empty collections', () {
      final Map<String, Object?> document = <String, Object?>{
        'version': 1,
        'provider': 'netease',
        'liked': <Object?>['1901'],
        'playlists': <Object?>[
          <String, Object?>{'id': 'p1', 'name': '夜'},
        ],
      };
      expect(_list(loadCollections(document, provider: 'netease')['liked']), <Object?>['1901']);
      expect(_list(loadCollections(<String, Object?>{...document, 'version': 2}, provider: 'netease')['liked']), isEmpty);
      expect(_list(loadCollections(<String, Object?>{...document, 'provider': 'qq'}, provider: 'netease')['liked']), isEmpty);
      expect(_list(loadCollections(<String, Object?>{}, provider: 'netease')['playlists']), isEmpty);
    });

    test('liked ids and track ids are de-duplicated and never empty', () {
      expect(collectionStrings(<Object?>['1901', '1901', '', 42, '1902']), <String>['1901', '1902']);
      expect(collectionStrings(null), isEmpty);
      expect(collectionStrings('1901'), isEmpty);
    });

    test('playlists drop empty records, trim names and keep newest first', () {
      final Map<String, Object?> document = <String, Object?>{
        'version': 1,
        'provider': 'netease',
        'liked': <Object?>[],
        'playlists': <Object?>[
          <String, Object?>{'id': 'old', 'name': '  旧  ', 'createdAt': 1, 'trackIDs': <Object?>['1901', '1901']},
          <String, Object?>{'id': '', 'name': '无 id', 'createdAt': 9},
          <String, Object?>{'id': 'blank', 'name': '   ', 'createdAt': 9},
          <String, Object?>{'id': 'tie-a', 'name': '并列 A', 'createdAt': 3},
          <String, Object?>{'id': 'tie-b', 'name': '并列 B', 'createdAt': 3},
          <String, Object?>{'id': 'new', 'name': '新', 'createdAt': 5},
          <String, Object?>{'id': 'missing-time', 'name': '无时间'},
        ],
      };
      final List<Map<String, Object?>> playlists =
          _list(loadCollections(document, provider: 'netease')['playlists']).map(_map).toList();
      expect(playlists.map((Map<String, Object?> record) => record['id']).toList(),
          <String>['new', 'tie-a', 'tie-b', 'old', 'missing-time']);
      expect(playlists.firstWhere((Map<String, Object?> record) => record['id'] == 'old')['name'], '旧');
      expect(playlists.firstWhere((Map<String, Object?> record) => record['id'] == 'old')['trackIDs'],
          <String>['1901']);
      expect(playlists.firstWhere((Map<String, Object?> record) => record['id'] == 'missing-time')['createdAt'], 0.0);
    });
  });

  // storage.md §6: PlatformAndroid.cpp:13-46 and Host.cpp:511-553.
  group('credential', () {
    test('the Android write is a truncate-then-write sequence, not an atomic rename', () {
      expect(credentialWriteSteps(), qtCredentialWriteSteps);
      expect(credentialWriteSteps(), <String>['mkpath', 'open-truncate', 'write', 'close', 'chmod-0600']);
      expect(credentialWriteSteps().contains('rename'), isFalse);
      expect(credentialFileName, 'account.credential');
    });

    test('every failure path reports the same user visible note', () {
      expect(credentialFailureNote, '登录成功，但 Android 凭据当前不可写');
      expect(
        credentialWriteResult(directoryCreated: true, opened: true, written: 12, expected: 12),
        '',
      );
      expect(
        credentialWriteResult(directoryCreated: true, opened: true, written: 11, expected: 12),
        credentialFailureNote,
      );
      expect(
        credentialWriteResult(directoryCreated: false, opened: true, written: 12, expected: 12),
        credentialFailureNote,
      );
      expect(
        credentialWriteResult(directoryCreated: true, opened: false, written: 0, expected: 12),
        credentialFailureNote,
      );
    });

    test('the file mode is owner read and write only', () {
      expect(credentialMode, 0x180);
      expect(credentialMode, 384);
      expect(credentialOwnerOnly(0x180), isTrue);
      // 0644 would leak the token to the rest of the uid.
      expect(credentialOwnerOnly(0x1a4), isFalse);
      expect(credentialOwnerOnly(0x1c0), isFalse);
    });

    test('kugou needs a token and a numeric user id per edition', () {
      expect(
        hasCredential(
          'kugou',
          edition: 'standard',
          cookies: <String, Object?>{
            '__kugou': <String, Object?>{
              'standard': <String, Object?>{'token': 't', 'userid': '42'},
            },
          },
        ),
        isTrue,
      );
      for (final String userId in <String>['0', '', 'abc', '-1']) {
        expect(
          hasCredential(
            'kugou',
            edition: 'standard',
            cookies: <String, Object?>{
              '__kugou': <String, Object?>{
                'standard': <String, Object?>{'token': 't', 'userid': userId},
              },
            },
          ),
          isFalse,
        );
      }
      expect(
        hasCredential(
          'kugou',
          edition: 'lite',
          cookies: <String, Object?>{
            '__kugou': <String, Object?>{
              'standard': <String, Object?>{'token': 't', 'userid': '42'},
            },
          },
        ),
        isFalse,
      );
    });

    test('netease and qq read their own cookie names', () {
      expect(hasCredential('netease', edition: 'standard', cookies: <String, Object?>{'MUSIC_U': 'u'}), isTrue);
      expect(hasCredential('netease', edition: 'standard', cookies: <String, Object?>{'MUSIC_U': ''}), isFalse);
      expect(
        hasCredential('qq', edition: 'standard', cookies: <String, Object?>{'qqmusic_session': 's'}),
        isTrue,
      );
      expect(hasCredential('qq', edition: 'standard', cookies: <String, Object?>{}), isFalse);
      expect(hasCredential('local', edition: 'standard', cookies: <String, Object?>{'MUSIC_U': 'u'}), isFalse);
      expect(hasCredential('siren', edition: 'standard', cookies: <String, Object?>{'MUSIC_U': 'u'}), isFalse);
    });

    test('the kugou edition cookie nests under __kugou and keeps other cookies', () {
      final Map<String, Object?> cookies = acceptKugouCookies(
        <String, Object?>{
          'MUSIC_U': 'netease-token',
          '__kugou': <String, Object?>{'lite': <String, Object?>{'token': 'old'}},
        },
        edition: 'standard',
        credential: <String, Object?>{'token': 'new', 'userid': '42'},
      );
      expect(cookies['MUSIC_U'], 'netease-token');
      final Map<String, Object?> editions = _map(cookies['__kugou']);
      expect(_keys(editions).toSet(), <String>{'lite', 'standard'});
      expect(_map(editions['standard'])['token'], 'new');
      expect(_map(editions['lite'])['token'], 'old');
    });

    test('device state files are per source and kugou has one for both editions', () {
      expect(deviceStateFiles.keys.toSet(), <String>{'qq', 'kugou'});
      expect(deviceStateFile('qq'), 'qq-device.json');
      expect(deviceStateFile('kugou'), 'kugou-device.json');
      expect(deviceStateFile('netease'), '');
    });
  });

  // storage.md §2.2: MusicSession.cpp:177-186, the loading branches.
  group('loading replay', () {
    test('a search is replayed only when it was in flight and still has a query', () {
      expect(shouldReplaySearch(<String, Object?>{'searchLoading': true, 'keyword': '夜'}), isTrue);
      expect(shouldReplaySearch(<String, Object?>{'searchLoading': true, 'keyword': ''}), isFalse);
      expect(shouldReplaySearch(<String, Object?>{'searchLoading': false, 'keyword': '夜'}), isFalse);
      expect(shouldReplaySearch(<String, Object?>{'searchLoading': true}), isFalse);
    });

    test('the directory and detail replays are exclusive, directory first', () {
      expect(
        followUpBranch(
          <String, Object?>{'directoryLoading': true, 'detailLoading': true},
          hasDirectory: true,
          directorySongsEmpty: true,
          currentNonEmpty: true,
        ),
        'enterDirectory',
      );
      expect(
        followUpBranch(
          <String, Object?>{'directoryLoading': true, 'detailLoading': true},
          hasDirectory: false,
          directorySongsEmpty: true,
          currentNonEmpty: true,
        ),
        'choose',
      );
      expect(
        followUpBranch(
          <String, Object?>{'directoryLoading': true},
          hasDirectory: true,
          directorySongsEmpty: false,
          currentNonEmpty: true,
        ),
        'none',
      );
      expect(
        followUpBranch(
          <String, Object?>{'detailLoading': true},
          hasDirectory: true,
          directorySongsEmpty: true,
          currentNonEmpty: false,
        ),
        'none',
      );
      expect(
        followUpBranch(<String, Object?>{}, hasDirectory: true, directorySongsEmpty: true, currentNonEmpty: true),
        'none',
      );
    });

    test('the fixture keeps detail loading so the replay branch is exercised', () {
      final Map<String, Object?> library = _map(fixture()['library']);
      expect(library['detailLoading'], isTrue);
      expect(library['searchLoading'], isFalse);
      expect(library['directoryLoading'], isFalse);
      expect(
        followUpBranch(
          library,
          hasDirectory: _list(library['directories']).isNotEmpty,
          directorySongsEmpty: false,
          currentNonEmpty: _map(library['current']).isNotEmpty,
        ),
        'choose',
      );
    });
  });

  // storage.md §8: MusicLibrary.cpp:18-30 only builds LocalCollections for siren;
  // the online sources keep liked ids in the session instead.
  group('collections ownership', () {
    test('only siren owns a collections file', () {
      bool ownsCollections(String provider) => provider == 'siren';
      for (final String provider in <String>['netease', 'qq', 'kugou', 'local']) {
        expect(ownsCollections(provider), isFalse, reason: provider);
      }
      expect(ownsCollections('siren'), isTrue);
      expect(collectionsPath('siren'), 'collections/siren.json');
    });
  });

  // storage.md §2.1: the writer, not just the reader, has a 64 MiB gate.
  group('session save path', () {
    test('a session at the limit is written, one byte more keeps the previous file', () {
      expect(
        sessionSaveSteps(sessionLimitBytes),
        <String>['construct', 'mkdir', 'open', 'write', 'commit'],
      );
      expect(
        sessionSaveSteps(sessionLimitBytesPlusOne),
        <String>['construct', 'warn', 'return'],
      );
      // MusicSession.cpp:276-279 returns before open/write/commit, so the old
      // session.json is never truncated.
      expect(sessionSaveSteps(sessionLimitBytesPlusOne).contains('open'), isFalse);
      expect(sessionSaveSteps(sessionLimitBytesPlusOne).contains('write'), isFalse);
      expect(sessionSaveSteps(sessionLimitBytesPlusOne).contains('commit'), isFalse);
      expect(
        sessionSaveResult(previous: 'old', next: 'new', byteLength: sessionLimitBytes),
        'new',
      );
      expect(
        sessionSaveResult(previous: 'old', next: 'new', byteLength: sessionLimitBytesPlusOne),
        'old',
      );
    });

    test('an empty or small payload always takes the write path', () {
      expect(sessionSaveSteps(0).last, 'commit');
      expect(sessionSaveResult(previous: 'old', next: 'fresh', byteLength: 0), 'fresh');
    });
  });

  // storage.md §8: LocalCollections.cpp:36-42 size gate.
  group('collections size gate', () {
    test('16 MiB is accepted and one more byte reads as empty', () {
      expect(collectionsLimitBytes, 16 * 1024 * 1024);
      expect(collectionsWithinLimit(collectionsLimitBytes), isTrue);
      expect(collectionsWithinLimit(collectionsLimitBytes + 1), isFalse);
      expect(collectionsWithinLimit(0), isTrue);
      // The oversized file is kept on disk; load() only returns early.
      expect(collectionsWithinLimit(collectionsLimitBytes + 1), isFalse);
    });
  });

  // storage.md §6.5: Host.cpp:609-661 and MusicAccount.cpp:670-717.
  group('logout isolation', () {
    test('qq logout drops only the qq cookies', () {
      final Map<String, Object?> after = logoutCookies(
        'qq',
        edition: 'standard',
        cookies: <String, Object?>{
          'MUSIC_U': 'netease-token',
          'qqmusic_session': 'qq-token',
          '__qqSessions': <String, Object?>{'a': 1},
          '__kugou': <String, Object?>{'standard': <String, Object?>{'token': 'k'}},
        },
      );
      expect(_keys(after).toSet(), <String>{'MUSIC_U', '__kugou'});
      expect(credentialFileAction(after), 'save');
    });

    test('kugou logout drops only the active edition', () {
      final Map<String, Object?> after = logoutCookies(
        'kugou',
        edition: 'standard',
        cookies: <String, Object?>{
          'MUSIC_U': 'netease-token',
          '__kugou': <String, Object?>{
            'standard': <String, Object?>{'token': 's'},
            'lite': <String, Object?>{'token': 'l'},
          },
        },
      );
      expect(after['MUSIC_U'], 'netease-token');
      expect(_keys(_map(after['__kugou'])).toSet(), <String>{'lite'});
      expect(credentialFileAction(after), 'save');

      final Map<String, Object?> emptied = logoutCookies(
        'kugou',
        edition: 'lite',
        cookies: <String, Object?>{
          '__kugou': <String, Object?>{
            'lite': <String, Object?>{'token': 'l'},
          },
        },
      );
      expect(emptied.containsKey('__kugou'), isFalse);
      // Nothing left at all: the credential file is deleted, not saved empty.
      expect(credentialFileAction(emptied), 'delete');
    });

    test('netease logout clears everything except the other sources', () {
      final Map<String, Object?> after = logoutCookies(
        'netease',
        edition: 'standard',
        cookies: <String, Object?>{
          'MUSIC_U': 'netease-token',
          'unrelated': 'x',
          'qqmusic_session': 'qq-token',
          '__qqSessions': <String, Object?>{'a': 1},
          '__kugou': <String, Object?>{'standard': <String, Object?>{'token': 'k'}},
        },
      );
      expect(_keys(after).toSet(), <String>{'__kugou', 'qqmusic_session', '__qqSessions'});
      expect(after.containsKey('MUSIC_U'), isFalse);
      expect(after.containsKey('unrelated'), isFalse);
      expect(hasCredential('netease', edition: 'standard', cookies: after), isFalse);
    });

    test('logout clears only the current account id and resets the history', () {
      const Map<String, String> store = <String, String>{
        'panel/account-id-netease': '10001',
        'panel/account-id-qq': '77',
        'panel/account-id-kugou-lite': '55',
        'panel/play-history': '["1901"]',
      };
      final Map<String, String> after = logoutPreferences('netease', 'standard', store);
      expect(after['panel/account-id-netease'], '');
      expect(after['panel/account-id-qq'], '77');
      expect(after['panel/account-id-kugou-lite'], '55');
      expect(after['panel/play-history'], '[]');
      // Clearing goes through the ordinary write gate: only the empty value is
      // a legal way to erase a key, there is no remove() in setPreference.
      expect(panelWriteAllowed('account-id-netease', '', offline: false), isTrue);

      final Map<String, String> kugouAfter = logoutPreferences('kugou', 'lite', store);
      expect(kugouAfter['panel/account-id-kugou-lite'], '');
      expect(kugouAfter['panel/account-id-netease'], '10001');
    });

    test('an empty jar deletes the credential file', () {
      expect(credentialFileAction(<String, Object?>{}), 'delete');
      expect(credentialFileAction(<String, Object?>{'__kugou': <String, Object?>{}}), 'save');
    });
  });

  // storage.md §2.2: QJsonValue coercion is narrower than Dart's.
  group('json coercion', () {
    test('integers are never truncated', () {
      expect(_int(3), 3);
      expect(_int(3.0), 3);
      expect(_int(3.5), 0);
      expect(_int(3.5, 7), 7);
      expect(_int('3'), 0);
      expect(_int(null, -1), -1);
      expect(_int(true), 0);
      expect(_int(double.nan), 0);
      expect(_int(double.infinity), 0);
    });

    test('doubles, booleans and strings follow the Qt readers', () {
      expect(_double(5), 5.0);
      expect(_double('5'), 0.0);
      expect(_double(null, -1), -1.0);
      expect(_bool(true), isTrue);
      expect(_bool(1), isFalse);
      expect(_bool('true'), isFalse);
      expect(_bool(null), isFalse);
      expect(_str(null), '');
      // QJsonValue::toString answers an empty string for non-strings, so a
      // numeric field is never silently stringified.
      expect(_str(42), '');
      expect(_strOr(null, 'songs'), 'songs');
      expect(_strOr(42, 'songs'), 'songs');
      expect(_strings(<Object?>['a', 'a', '', 1, 'b']), <String>['a', 'b']);
      expect(_strings(null), isEmpty);
      expect(_clampInt(99, 0, 39), 39);
      expect(_clampInt(-5, 0, 39), 0);
      expect(_clampDouble(5000, 0, 1000), 1000.0);
      expect(_nonnegative(-3), 0);
      expect(_max(2, 5), 5);
    });
  });

  // storage.md §2.2 / §6.2: MusicLibrary.cpp:169-171 and MusicAccount.cpp:105-110.
  group('account identity', () {
    test('the account preference key follows the kugou edition', () {
      expect(accountKeyFor('kugou', 'standard'), 'kugou-standard');
      expect(accountKeyFor('kugou', 'lite'), 'kugou-lite');
      expect(accountKeyFor('netease', 'standard'), 'netease');
      expect(accountKeyFor('qq', 'standard'), 'qq');
      expect(panelKeys.contains('account-id-kugou-standard'), isTrue);
      expect(panelKeys.contains('account-id-kugou-lite'), isTrue);
    });

    test('uid is empty until the credential is authenticated', () {
      const Map<String, String> preferences = <String, String>{'panel/account-id-netease': '10001'};
      expect(
        accountUid(authenticated: false, provider: 'netease', edition: 'standard', preferences: preferences),
        '',
      );
      expect(
        accountUid(authenticated: true, provider: 'netease', edition: 'standard', preferences: preferences),
        '10001',
      );
      expect(
        accountUid(authenticated: true, provider: 'netease', edition: 'standard', preferences: const <String, String>{}),
        '',
      );
    });
  });
}
