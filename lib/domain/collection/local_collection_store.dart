// Local ("on this device") collection: liked track ids and user playlists.
//
// PURE Dart - this file must not import Flutter. Persistence is injected as a
// [PreferencePort] (lib/data/storage/preference_store.dart) so the store can be
// unit tested against any in-memory backend.
//
// Storage layout (two string keys, both JSON):
//   * `local-liked-ids`  - JSON string array, e.g. ["track-1","track-2"].
//   * `local-playlists`  - JSON object array, e.g.
//     [{"id":"local-playlist-1","title":"Red","trackIds":["track-3"]}].
//
// Corrupt JSON or a wrong shape is treated as "no data" instead of failing the
// load: a damaged preference value must never make the collection screen
// unusable, and it must never be rewritten behind the user's back on load.

import 'dart:convert';

import '../../data/storage/preference_store.dart';

/// One user playlist stored on this device.
class LocalPlaylist {
  /// Creates a playlist. [trackIds] order is preserved as given.
  const LocalPlaylist({
    required this.id,
    required this.title,
    required this.trackIds,
  });

  /// Stable id, generated as `local-playlist-<n>` by
  /// [LocalCollectionStore.createPlaylist].
  final String id;

  /// Display title; always already trimmed by the store.
  final String title;

  /// Track ids in insertion order.
  final List<String> trackIds;

  /// Number of tracks in this playlist.
  int get trackCount => trackIds.length;

  /// Returns a copy with the given fields replaced.
  LocalPlaylist copyWith({
    String? id,
    String? title,
    List<String>? trackIds,
  }) {
    return LocalPlaylist(
      id: id ?? this.id,
      title: title ?? this.title,
      trackIds: trackIds ?? this.trackIds,
    );
  }

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      'trackIds': trackIds,
    };
  }

  /// Parses a persisted playlist. Unknown/invalid fields fall back to safe
  /// empty values instead of throwing.
  factory LocalPlaylist.fromJson(Map<Object?, Object?> json) {
    final rawId = json['id'];
    final rawTitle = json['title'];
    final rawTracks = json['trackIds'];
    return LocalPlaylist(
      id: rawId is String ? rawId : '',
      title: rawTitle is String ? rawTitle : '',
      trackIds: rawTracks is List
          ? rawTracks.whereType<String>().toList(growable: true)
          : <String>[],
    );
  }
}

/// Liked tracks and playlists persisted on this device.
class LocalCollectionStore {
  /// Creates a store over [preferences]. Call [load] before reading state.
  LocalCollectionStore({required this.preferences});

  /// The injected persistence backend; never bypassed.
  final PreferencePort preferences;

  /// Preference key for the liked track id array.
  static const String likedIdsKey = 'local-liked-ids';

  /// Preference key for the playlist array.
  static const String playlistsKey = 'local-playlists';

  /// Id prefix used by [createPlaylist]; the full id is
  /// `<prefix><n>` with n starting at 1 and strictly increasing.
  static const String playlistIdPrefix = 'local-playlist-';

  static final RegExp _playlistIdPattern = RegExp(r'^local-playlist-(\d+)$');

  List<String> _likedIds = <String>[];
  List<LocalPlaylist> _playlists = <LocalPlaylist>[];

  /// Reads both preference keys into memory. Never throws: corrupt JSON or a
  /// wrong shape yields an empty collection.
  Future<void> load() async {
    _likedIds = await _readLikedIds();
    _playlists = await _readPlaylists();
  }

  Future<List<String>> _readLikedIds() async {
    final raw = await _readString(likedIdsKey);
    if (raw == null) {
      return <String>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return <String>[];
      }
      // De-duplicate so a hand-edited value cannot produce a repeated id.
      final seen = <String>{};
      return <String>[
        for (final id in decoded.whereType<String>())
          if (seen.add(id)) id,
      ];
    } on FormatException {
      return <String>[];
    }
  }

  Future<List<LocalPlaylist>> _readPlaylists() async {
    final raw = await _readString(playlistsKey);
    if (raw == null) {
      return <LocalPlaylist>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return <LocalPlaylist>[];
      }
      final result = <LocalPlaylist>[];
      for (final entry in decoded) {
        if (entry is Map) {
          result.add(LocalPlaylist.fromJson(entry));
        }
      }
      return result;
    } on FormatException {
      return <LocalPlaylist>[];
    }
  }

  Future<String?> _readString(String key) async {
    try {
      return await preferences.read(key);
    } catch (_) {
      // Same policy as PreferenceStore: an unreadable key is an absent key.
      return null;
    }
  }

  Future<void> _writeString(String key, String value) async {
    try {
      await preferences.write(key, value);
    } catch (_) {
      // Persistence failures must not corrupt the in-memory state; the caller
      // sees the operation succeed locally and a later write retries.
    }
  }

  /// The liked track ids, in insertion order.
  List<String> get likedIds => List<String>.unmodifiable(_likedIds);

  /// All playlists, in insertion order.
  List<LocalPlaylist> get playlists =>
      List<LocalPlaylist>.unmodifiable(_playlists);

  /// Whether [id] is liked.
  bool isLiked(String id) => _likedIds.contains(id);

  /// Likes or unlikes [id], persists, and reloads the in-memory state.
  Future<void> setLiked(String id, bool liked) async {
    if (liked) {
      if (!_likedIds.contains(id)) {
        _likedIds.add(id);
        await _writeString(likedIdsKey, jsonEncode(_likedIds));
        await load();
      }
    } else {
      if (_likedIds.contains(id)) {
        _likedIds.removeWhere((existing) => existing == id);
        await _writeString(likedIdsKey, jsonEncode(_likedIds));
        await load();
      }
    }
  }

  /// Creates a playlist named [title] (trimmed) and returns it.
  ///
  /// The id is `local-playlist-<n>` where n is one greater than the largest
  /// existing number in that format, so ids stay stable and reproducible.
  ///
  /// Throws [ArgumentError] when [title] is empty or whitespace-only.
  Future<LocalPlaylist> createPlaylist(String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(title, 'title', 'Playlist title must not be empty');
    }
    final playlist = LocalPlaylist(
      id: '$playlistIdPrefix${_nextPlaylistNumber()}',
      title: trimmed,
      trackIds: <String>[],
    );
    _playlists.add(playlist);
    await _writePlaylists();
    await load();
    return playlist;
  }

  int _nextPlaylistNumber() {
    var max = 0;
    for (final playlist in _playlists) {
      final match = _playlistIdPattern.firstMatch(playlist.id);
      if (match == null) {
        continue;
      }
      final number = int.tryParse(match.group(1)!);
      if (number != null && number > max) {
        max = number;
      }
    }
    return max + 1;
  }

  /// Renames [id] to [title] (trimmed). No-op when [id] is unknown.
  ///
  /// Throws [ArgumentError] when [title] is empty or whitespace-only.
  Future<void> renamePlaylist(String id, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(title, 'title', 'Playlist title must not be empty');
    }
    final index = _indexOfPlaylist(id);
    if (index == -1) {
      return;
    }
    _playlists[index] = _playlists[index].copyWith(title: trimmed);
    await _writePlaylists();
    await load();
  }

  /// Removes [id]; returns false when the playlist does not exist.
  Future<bool> removePlaylist(String id) async {
    final index = _indexOfPlaylist(id);
    if (index == -1) {
      return false;
    }
    _playlists.removeAt(index);
    await _writePlaylists();
    await load();
    return true;
  }

  /// Appends [trackIds] to [playlistId], skipping ids already in the playlist
  /// (including duplicates within [trackIds]). No-op for an unknown playlist.
  Future<void> addToPlaylist({
    required String playlistId,
    required List<String> trackIds,
  }) async {
    final index = _indexOfPlaylist(playlistId);
    if (index == -1) {
      return;
    }
    final playlist = _playlists[index];
    final next = playlist.trackIds.toList(growable: true);
    for (final trackId in trackIds) {
      if (next.contains(trackId)) {
        continue;
      }
      next.add(trackId);
    }
    _playlists[index] = playlist.copyWith(trackIds: next);
    await _writePlaylists();
    await load();
  }

  /// Removes [trackIds] from [playlistId] and returns how many ids were
  /// actually removed. Unknown playlist or absent ids yield 0.
  Future<int> removeFromPlaylist({
    required String playlistId,
    required List<String> trackIds,
  }) async {
    final index = _indexOfPlaylist(playlistId);
    if (index == -1) {
      return 0;
    }
    final playlist = _playlists[index];
    final wanted = trackIds.toSet();
    final removed = playlist.trackIds.where(wanted.contains).toSet().length;
    if (removed == 0) {
      return 0;
    }
    final next = playlist.trackIds
        .where((trackId) => !wanted.contains(trackId))
        .toList(growable: true);
    _playlists[index] = playlist.copyWith(trackIds: next);
    await _writePlaylists();
    await load();
    return removed;
  }

  int _indexOfPlaylist(String id) =>
      _playlists.indexWhere((playlist) => playlist.id == id);

  Future<void> _writePlaylists() async {
    await _writeString(
      playlistsKey,
      jsonEncode(<Object?>[
        for (final playlist in _playlists) playlist.toJson(),
      ]),
    );
  }
}
