// GUI session snapshot (session.json) reading and writing.
//
// 1:1 port of the Qt behaviour at the frozen baseline 8ed3067 (T07 sections 2,
// 2.5 and 3; the section headings are quoted in the comments below):
//   Qt/src/MusicSession.cpp:33-86     MusicLibrary::sessionState()          (library shape)
//   Qt/src/MusicSession.cpp:88-213    MusicLibrary::restoreSessionState()   (identity gate + clamps)
//   Qt/src/MusicSession.cpp:215-235   NativeApplication::sessionState()     (top level + 16 view fields)
//   Qt/src/MusicSession.cpp:237-267   NativeApplication::restoreSessionState()
//   Qt/src/MusicSession.cpp:269-284   NativeApplication::saveSession()
//   Qt/src/NativeApplication.cpp:64-69   read gate (openable && size <= 64 MiB)
//   Qt/src/NativeHud.h:115-135        settingsScrollMaximum() layout function
//
// PURE Dart: dart:convert only, no Flutter import and no package:path. Every path
// is resolved by the injected AppStorage (T26-S01, lib/data/storage/app_storage.dart)
// and every byte goes through the injected FileSystemPort.
//
// Ownership: the returned library map is restored state in exactly the
// sessionState() key set and the caller applies it. The saved flags
// searchLoading / directoryLoading / detailLoading are carried through because Qt
// consumes them as re-issue triggers (MusicSession.cpp:177-186) while forcing the
// in-memory flags back to false (MusicSession.cpp:164); the caller must consume
// them the same way and clear them.
//
// The 64 MiB write cap plus the atomic same-directory-temp replace are
// AppStorage.writeJsonAtomic's frozen responsibility (T26-S01); this atom proves
// that it hands over the 64 MiB limit and that nothing is deleted on any failure.

import 'dart:convert';

import 'app_storage.dart';
import 'playback_store.dart';

/// Every failureReason this atom can produce, in the evaluation order of the read
/// gate followed by the library identity gate.
const List<String> kSessionFailureReasons = <String>[
  'missing',
  'unreadable',
  'oversize',
  'invalid-json',
  'version',
  'provider-mismatch',
  'edition-mismatch',
  'uid-mismatch',
  'sources-length',
  'selected-physical',
  'directories-too-many',
];

/// The injected current identity.
///
/// Qt builds it from panel/provider, panel/kugou-edition and panel/account-id-*
/// before the session is read (NativeApplication.cpp:44-75,
/// MusicLibrary.cpp:169-171).
class SessionIdentity {
  const SessionIdentity({
    required this.provider,
    required this.edition,
    required this.uid,
  });

  /// netease | qq | kugou | local | siren
  final String provider;

  /// standard | lite
  final String edition;

  /// Current account uid; an empty string while logged out.
  final String uid;
}

/// One view snapshot: exactly the 16 fields of T07 section 2.3.
///
/// Field order here, in [toJson] and in [restore] is the frozen order of
/// MusicSession.cpp:215-235 (write) and :237-267 (read).
class ViewState {
  const ViewState({
    required this.mode,
    required this.selected,
    required this.tab,
    required this.modal,
    required this.queueOffset,
    required this.settingsScroll,
    required this.query,
    required this.groupBy,
    required this.activeGroup,
    required this.artistTab,
    required this.listOffset,
    required this.trackOffset,
    required this.bodyOffset,
    required this.musicCollection,
    required this.trackListMode,
    required this.lyricsMode,
  });

  /// The frozen key order of [toJson]; nothing else may ever be emitted.
  static const List<String> viewKeys = <String>[
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

  /// Accepted modal names (MusicSession.cpp:243). Anything else, including an
  /// empty string or a missing field, restores to no modal and is written back
  /// as an empty string.
  static const List<String> modals = <String>[
    'saved',
    'search',
    'discover',
    'queue',
    'settings',
    'player',
    'local',
  ];

  /// Accepted tab names (MusicSession.cpp:249).
  static const List<String> tabs = <String>['overview', 'notes', 'history'];

  /// archive | detail; 'detail' only when library.current is non-empty
  /// (MusicSession.cpp:262).
  final String mode;

  /// Global physical slot 0..39; NOT library.selectedPhysical
  /// (MusicSession.cpp:260 and the T07 section 2.3 note).
  final int selected;

  final String tab;

  /// Empty string means no modal is open.
  final String modal;

  final int queueOffset;

  /// Clamped to 0..settingsScrollMaximum(); a saved value may exceed the current
  /// maximum (MusicSession.cpp:247, NativeHud.h:115-135).
  final double settingsScroll;

  final String query;

  /// May legitimately be an empty string (MusicSession.cpp:253).
  final String groupBy;

  final String activeGroup;
  final String artistTab;
  final int listOffset;
  final int trackOffset;
  final int bodyOffset;

  /// 1..4 (MusicSession.cpp:257).
  final int musicCollection;
  final bool trackListMode;
  final bool lyricsMode;

  /// Restore path (MusicSession.cpp:241-260, T07 section 2.3).
  ///
  /// [currentNonEmpty] is library.current.isNotEmpty: it is the only input that
  /// can turn mode into 'detail'. [settingsScrollMaximum] is the injected runtime
  /// layout function value, not a constant.
  ///
  /// Unknown view fields are read past and never retained, so they can never be
  /// written back by [toJson].
  static ViewState restore(
    Object? raw, {
    required bool currentNonEmpty,
    required int settingsScrollMaximum,
  }) {
    final view = _asMap(raw) ?? const <String, Object?>{};
    final savedModal = _asString(view['modal']);
    final savedTab = _asString(view['tab']);
    final savedMode = _asString(view['mode']);
    return ViewState(
      // MusicSession.cpp:262.
      mode: (savedMode == 'detail' && currentNonEmpty) ? 'detail' : 'archive',
      // MusicSession.cpp:260.
      selected: _clampInt(_toIntOr(view['selected'], 0), 0, 39),
      // MusicSession.cpp:248-249.
      tab: (savedTab != null && tabs.contains(savedTab)) ? savedTab : 'overview',
      // MusicSession.cpp:242-245.
      modal: (savedModal != null && modals.contains(savedModal)) ? savedModal : '',
      // MusicSession.cpp:246.
      queueOffset: _nonNegative(view['queueOffset']),
      // MusicSession.cpp:247.
      settingsScroll: _clampDouble(view['settingsScroll'], settingsScrollMaximum),
      // MusicSession.cpp:250-256.
      query: _asString(view['query']) ?? '',
      groupBy: _asString(view['groupBy']) ?? 'none',
      activeGroup: _asString(view['activeGroup']) ?? '',
      artistTab: _asString(view['artistTab']) ?? 'songs',
      listOffset: _nonNegative(view['listOffset']),
      trackOffset: _nonNegative(view['trackOffset']),
      bodyOffset: _nonNegative(view['bodyOffset']),
      // MusicSession.cpp:257-259.
      musicCollection: _clampInt(_toIntOr(view['musicCollection'], 1), 1, 4),
      trackListMode: _asBool(view['trackListMode']),
      lyricsMode: _asBool(view['lyricsMode']),
    );
  }

  /// Exactly the 16 keys, in the frozen order (MusicSession.cpp:219-234).
  ///
  /// The caller applies hud.closing to the modal BEFORE building the view it
  /// saves: Qt writes 'hud.closing ? QString() : hud.modal'
  /// (MusicSession.cpp:218), so a closing HUD must be passed in with modal = ''.
  Map<String, Object?> toJson() => <String, Object?>{
        'mode': mode,
        'selected': selected,
        'tab': tab,
        'modal': modal,
        'queueOffset': queueOffset,
        'settingsScroll': settingsScroll,
        'query': query,
        'groupBy': groupBy,
        'activeGroup': activeGroup,
        'artistTab': artistTab,
        'listOffset': listOffset,
        'trackOffset': trackOffset,
        'bodyOffset': bodyOffset,
        'musicCollection': musicCollection,
        'trackListMode': trackListMode,
        'lyricsMode': lyricsMode,
      };
}

/// Re-issue triggers carried by a saved session (Qt/src/MusicSession.cpp:177-186).
///
/// Qt never restores these booleans as library state: restoreSessionState()
/// forces `detailLoading = directoryLoading = trackLoad = false`
/// (Qt/src/MusicSession.cpp:164) and then reads the SAVED values only to decide
/// whether to re-issue the search, re-enter the directory or re-choose the
/// detail. Keeping them out of [SessionRestoreResult.library] keeps the restored
/// map equal to Qt's post-restore in-memory state, so a later save cannot
/// round-trip a stale `true`.
class SessionRestoreTriggers {
  const SessionRestoreTriggers({
    this.search = false,
    this.directory = false,
    this.detail = false,
  });

  /// No saved request was in flight.
  static const SessionRestoreTriggers none = SessionRestoreTriggers();

  /// saved.searchLoading && keyword non-empty -> re-issue the search
  /// (Qt/src/MusicSession.cpp:177-179).
  final bool search;

  /// saved.directoryLoading && a restored directory exists whose songs are empty
  /// -> pop and re-enter it (Qt/src/MusicSession.cpp:180-183).
  final bool directory;

  /// saved.detailLoading && current non-empty, only when [directory] did not
  /// fire: Qt's :180-186 is one else-if chain, so the directory branch wins.
  final bool detail;
}

/// Outcome of [SessionStore.loadForRestore].
///
/// On any failure [loaded] is false, [view] and [player] are null and the file is
/// left untouched on disk (T07 sections 2.1 and 2.5).
class SessionRestoreResult {
  const SessionRestoreResult({
    required this.loaded,
    this.failureReason,
    this.library,
    this.view,
    this.player,
    this.triggers = SessionRestoreTriggers.none,
  });

  /// Nothing was restored and the file is kept.
  factory SessionRestoreResult.failure(String reason) =>
      SessionRestoreResult(loaded: false, failureReason: reason);

  /// A complete restore: version gate, library gate and view all passed.
  factory SessionRestoreResult.restored({
    required Map<String, Object?> library,
    required ViewState view,
    PlayerState? player,
    SessionRestoreTriggers triggers = SessionRestoreTriggers.none,
  }) =>
      SessionRestoreResult(
        loaded: true,
        library: library,
        view: view,
        player: player,
        triggers: triggers,
      );

  final bool loaded;

  /// One of [kSessionFailureReasons]; null when [loaded] is true.
  final String? failureReason;

  /// Restored library state in the sessionState() key set; null when [loaded] is
  /// false.
  final Map<String, Object?>? library;

  /// null when [loaded] is false.
  final ViewState? view;

  /// null when [loaded] is false, and also null when the background playback
  /// connection owns playback state (MusicSession.cpp:263-265).
  final PlayerState? player;

  /// Requests that were in flight when the session was saved; the caller re-issues
  /// them after applying [library]. [SessionRestoreTriggers.none] when nothing was
  /// in flight or when [loaded] is false.
  final SessionRestoreTriggers triggers;
}

/// Reads and writes <data>/session.json (T07 sections 2, 2.5 and 3).
///
/// The store is isolated common code: every path comes from the injected
/// [AppStorage] and the runtime layout is injected, so nothing here is wired to a
/// real device yet.
class SessionStore {
  SessionStore({
    required this.storage,
    int Function()? settingsScrollMaximum,
    this.physicalSlots,
  }) : settingsScrollMaximum =
            settingsScrollMaximum ?? defaultSettingsScrollMaximum;

  /// <data>/session.json lives under the same 64 MiB cap on read and on write;
  /// exactly 64 MiB is still accepted (NativeApplication.cpp:64-68,
  /// MusicSession.cpp:276).
  static const int sessionLimitBytes = kSessionLimitBytes;

  /// NativeHud.h:115-117, the default settings layout constants.
  static const double settingsViewportTop = 176;
  static const double settingsViewportBottom = 836;
  static const double defaultSettingsContentBottom = 1600;

  /// HudScroll::maximum(settingsContentBottom - SettingsViewportTop,
  /// SettingsViewportBottom - SettingsViewportTop) at the default layout
  /// (NativeHud.h:132-135, HudScroll.h:13-15), which is 764.
  ///
  /// The real maximum is a runtime layout function, so it is injected through the
  /// constructor; this is only the default when the host does not supply one.
  static int defaultSettingsScrollMaximum() {
    final content = defaultSettingsContentBottom - settingsViewportTop;
    final viewport = settingsViewportBottom - settingsViewportTop;
    final maximum = content - viewport;
    return maximum > 0 ? maximum.round() : 0;
  }

  /// Injected storage facade (paths + file-system seam).
  final AppStorage storage;

  /// Injected runtime layout function (NativeHud.h:132-135).
  final int Function() settingsScrollMaximum;

  /// Injected runtime slot layout, as built by MusicLibrary.cpp:50-58.
  ///
  /// Qt always has one: MusicLibrary owns a five-lane `std::array<QVector<int>, 5>`
  /// (MusicLibrary.h:150), so there is no "layout absent" state to fall back to. When
  /// the host does not provide it, the membership half of the selectedPhysical check
  /// cannot be proven and the gate FAILS CLOSED with the frozen reason
  /// 'selected-physical' (MusicSession.cpp:92-98); the -1..39 range check alone is
  /// never accepted as sufficient. A selectedPhysical of -1 ("none selected") still
  /// passes, exactly like Qt's "physical >= 0 &&" guard. Pass the value of
  /// [derivePhysicalSlots] over the engine content to accept a concrete slot.
  final List<List<int>>? physicalSlots;

  /// Qt/src/MusicLibrary.cpp:50-58: physicalSlots[lane] holds the global record
  /// indices whose 'category' equals 'columns'[lane].
  ///
  /// Lanes beyond the number of categories stay empty, exactly like Qt's
  /// "lane < 5 && lane < categories.size()".
  static List<List<int>> derivePhysicalSlots(Object? content) {
    final source = _asMap(content) ?? const <String, Object?>{};
    final categories = _asList(source['columns']);
    final records = _asList(source['records']);
    return <List<int>>[
      for (var lane = 0; lane < 5; lane++)
        <int>[
          if (lane < categories.length)
            for (var i = 0; i < records.length; i++)
              if ((_asMap(records[i]) ?? const <String, Object?>{})['category'] ==
                  categories[lane])
                i,
        ],
    ];
  }

  /// Read gate, library identity gate, then view (and player) restore.
  ///
  /// Read gate (NativeApplication.cpp:64-68): the file must exist, be readable and
  /// be at most 64 MiB. Library gate (MusicSession.cpp:88-213): provider, edition
  /// and uid must equal the injected [identity], sources must be exactly 5 lanes,
  /// the selected lane and physical slot must be valid, and directories must not
  /// exceed 64. Any failure keeps the file and restores neither the view nor the
  /// player (NativeApplication.cpp:237-240, T07 section 2.1).
  Future<SessionRestoreResult> loadForRestore(
    SessionIdentity identity, {
    required bool playbackConnection,
  }) async {
    final path = storage.sessionPath;
    final files = storage.files;

    // T07 0.7 puts the offline gate in the application layer, so the read is not
    // gated on storage.offline here; this method is only called when not offline.
    if (!await files.exists(path)) {
      return SessionRestoreResult.failure('missing');
    }
    final size = await files.sizeOrNegative(path);
    if (size < 0) {
      return SessionRestoreResult.failure('unreadable');
    }
    if (size > sessionLimitBytes) {
      return SessionRestoreResult.failure('oversize');
    }
    final bytes = await files.readAll(path);
    if (bytes == null) {
      return SessionRestoreResult.failure('unreadable');
    }

    final saved = _decodeSession(bytes);
    if (saved == null) {
      return SessionRestoreResult.failure('invalid-json');
    }

    // MusicSession.cpp:238: saved["version"] != 1 fails. A missing or non-numeric
    // version is a failure, not a default; 1 and 1.0 both pass.
    final version = saved['version'];
    if (version is! num ||
        version != 1 ||
        version != version.truncateToDouble()) {
      return SessionRestoreResult.failure('version');
    }

    // Qt reads saved["library"].toObject(), so a non-object library becomes an
    // empty object and then fails the provider check: same observable reason.
    final libraryRaw = _asMap(saved['library']) ?? const <String, Object?>{};

    final Map<String, Object?> library;
    try {
      library = _restoreLibrary(libraryRaw, identity);
    } on _GateFailure catch (failure) {
      return SessionRestoreResult.failure(failure.reason);
    }

    final current = _asMap(libraryRaw['current']) ?? const <String, Object?>{};
    final view = ViewState.restore(
      saved['view'],
      currentNonEmpty: current.isNotEmpty,
      settingsScrollMaximum: settingsScrollMaximum(),
    );

    // MusicSession.cpp:263-265: the player is restored only when the background
    // playback connection does not own playback state. The library gate has
    // already passed at this point, so a failed gate never reaches it.
    PlayerState? player;
    if (!playbackConnection) {
      player = normalizePlayer(saved['player'], currentProvider: identity.provider);
    }

    return SessionRestoreResult.restored(
      library: library,
      view: view,
      player: player,
      triggers: _restoreTriggers(library, libraryRaw),
    );
  }

  /// Qt/src/MusicSession.cpp:177-186, evaluated against the RESTORED library
  /// (keyword, directories, current) and the SAVED in-flight booleans.
  static SessionRestoreTriggers _restoreTriggers(
    Map<String, Object?> library,
    Map<String, Object?> saved,
  ) {
    final String keyword = library['keyword']! as String;
    final Map<String, Object?> current =
        library['current']! as Map<String, Object?>;
    final List<Object?> directories = library['directories']! as List<Object?>;

    final bool directory = _asBool(saved['directoryLoading']) &&
        directories.isNotEmpty &&
        ((directories.last! as Map<String, Object?>)['songs']! as List<Object?>)
            .isEmpty;
    return SessionRestoreTriggers(
      search: _asBool(saved['searchLoading']) && keyword.isNotEmpty,
      directory: directory,
      // Qt's :184 is an else-if on the directory branch.
      detail: !directory && _asBool(saved['detailLoading']) && current.isNotEmpty,
    );
  }

  /// MusicSession.cpp:269-284.
  ///
  /// Offline writes nothing and returns false. Otherwise it writes
  /// {version: 1, library, player, view} as compact UTF-8 through the capped,
  /// same-directory-temp and atomic-rename writer. Over 64 MiB the writer returns
  /// false and the old file is untouched (T07 section 2.5).
  Future<bool> save(
    Map<String, Object?> library,
    PlayerState player,
    ViewState view,
  ) async {
    if (storage.offline) {
      return false;
    }
    return storage.writeJsonAtomic(
      storage.sessionPath,
      <String, Object?>{
        'version': 1,
        'library': library,
        'player': player.toJson(),
        'view': view.toJson(),
      },
      limitBytes: sessionLimitBytes,
    );
  }

  /// MusicSession.cpp:88-213 in Qt's exact evaluation order: identity (:89-91),
  /// sources length and lane and physical (:92-98), directories (:99-102), and then
  /// the field restoration (:106-171).
  ///
  /// Throws [_GateFailure] for the first failing condition; the caller turns it
  /// into a failureReason. Nothing is deleted anywhere on this path.
  Map<String, Object?> _restoreLibrary(
    Map<String, Object?> saved,
    SessionIdentity identity,
  ) {
    // MusicSession.cpp:89-91. provider and edition compare as strings; uid uses
    // QString::toString(), so a missing or non-string uid reads as an empty string
    // and matches a logged-out identity.
    if (_asString(saved['provider']) != identity.provider) {
      throw const _GateFailure('provider-mismatch');
    }
    if (_asString(saved['edition']) != identity.edition) {
      throw const _GateFailure('edition-mismatch');
    }
    if ((_asString(saved['uid']) ?? '') != identity.uid) {
      throw const _GateFailure('uid-mismatch');
    }

    // MusicSession.cpp:92-98. Qt evaluates the sources length and the lane and
    // physical validity in one condition (so sources wins only because it is
    // written first); selectedLane out of range is a failure, not a clamp, and it
    // maps to the selected-physical reason because the frozen reason enum has no
    // lane entry of its own.
    final sourcesRaw = _asList(saved['sources']);
    final lane = _toIntOr(saved['selectedLane'], -1);
    final physical = _toIntOr(saved['selectedPhysical'], -1);
    if (sourcesRaw.length != 5) {
      throw const _GateFailure('sources-length');
    }
    // Qt evaluates membership against a layout that always exists (MusicLibrary.h:150).
    // A null layout is therefore NOT "no constraint": membership cannot be proven, so
    // the gate fails closed instead of skipping the check (MusicSession.cpp:92-98).
    final slots = physicalSlots;
    final member = slots != null &&
        lane >= 0 &&
        lane < slots.length &&
        slots[lane].contains(physical);
    if (lane < 0 ||
        lane >= 5 ||
        physical < -1 ||
        physical >= 40 ||
        (physical >= 0 && !member)) {
      throw const _GateFailure('selected-physical');
    }

    // MusicSession.cpp:99-102.
    final foldersRaw = _asList(saved['directories']);
    if (foldersRaw.length > 64) {
      throw const _GateFailure('directories-too-many');
    }

    // MusicSession.cpp:106-113: exactly five lanes.
    final sources = <Object?>[];
    for (var i = 0; i < 5; i++) {
      final source = _asMap(sourcesRaw[i]) ?? const <String, Object?>{};
      final items = _asList(source['items']);
      final total = _toIntOr(source['total'], 0);
      sources.add(<String, Object?>{
        'items': items,
        'total': _maxInt(items.length, total < 0 ? 0 : total),
        'offset': _clampInt(_toIntOr(source['offset'], 0), 0,
            items.isEmpty ? 0 : items.length - 1),
        'more': _asBool(source['more']),
        'row': _clampInt(_toIntOr(source['row'], 0), 0, 7),
      });
    }

    // MusicSession.cpp:114-137: root to leaf order, and 'page' is recomputed from
    // the restored index instead of being read.
    final directories = <Object?>[];
    for (final entry in foldersRaw) {
      final value = _asMap(entry) ?? const <String, Object?>{};
      final songs = _asList(value['songs']);
      final ids = _asList(value['ids']);
      final index = _clampInt(_toIntOr(value['index'], 0), 0,
          songs.isEmpty ? 0 : songs.length - 1);
      final sortField = _asString(value['sortField']);
      directories.add(<String, Object?>{
        'item': _asMap(value['item']) ?? const <String, Object?>{},
        'songs': songs,
        'sortField': (sortField == 'none' ||
                sortField == 'title' ||
                sortField == 'album' ||
                sortField == 'artist')
            ? sortField
            : 'none',
        'ids': ids,
        'albums': _asList(value['albums']),
        'cursor': _clampInt(_toIntOr(value['cursor'], 0), 0, ids.length),
        'index': index,
        'anchor': _clampInt(_toIntOr(value['anchor'], 0), 0, 39),
        // MusicSession.cpp:130: folder->index / 40 * 40 with integer division.
        'page': index ~/ 40 * 40,
        'parentPhysical': _clampInt(_toIntOr(value['parentPhysical'], 0), 0, 39),
        'parentLane': _clampInt(_toIntOr(value['parentLane'], 0), 0, 4),
        'parentItem': _asMap(value['parentItem']) ?? const <String, Object?>{},
        'albumCursor': _nonNegative(value['albumCursor']),
        'albumsMore': _asBool(value['albumsMore']),
      });
    }

    // MusicSession.cpp:165-171: discover defaults.
    final discovery = _asMap(saved['discover']) ?? const <String, Object?>{};

    // MusicSession.cpp:138-171, keys in the sessionState() order of :50-85.
    return <String, Object?>{
      'provider': identity.provider,
      'edition': identity.edition,
      'uid': identity.uid,
      'sources': sources,
      'directories': directories,
      'current': _asMap(saved['current']) ?? const <String, Object?>{},
      'selectedPhysical': physical,
      'selectedLane': lane,
      'keyword': _asString(saved['keyword']) ?? '',
      'searchKind': _asString(saved['searchKind']) ?? 'song',
      'status': _asString(saved['status']) ?? '',
      // Qt/src/MusicSession.cpp:164 forces detailLoading = directoryLoading = false
      // on restore and only uses the SAVED values as re-issue triggers (:177-186),
      // which SessionStore surfaces as SessionRestoreResult.triggers. The restored
      // state therefore always reports false, so a later save cannot write back a
      // stale in-flight flag.
      'searchLoading': false,
      'directoryLoading': false,
      'detailLoading': false,
      'privateSelection': _asBool(saved['privateSelection']),
      'searchCursor': _nonNegative(saved['searchCursor']),
      'playlistCursor': _nonNegative(saved['playlistCursor']),
      'albumCursor': _nonNegative(saved['albumCursor']),
      'likedCursor': _nonNegative(saved['likedCursor']),
      'likedIDs': saved['likedIDs'] is List ? saved['likedIDs'] : null,
      'groupName': _asString(saved['groupName']) ?? '',
      'groupIndices': <Object?>[
        for (final value in _asList(saved['groupIndices'])) _nonNegative(value),
      ],
      'groupLane': _clampInt(_toIntOr(saved['groupLane'], -1), -1, 4),
      'tracks': _asList(saved['tracks']),
      'trackIDs': _asList(saved['trackIDs']),
      'trackCursor': _nonNegative(saved['trackCursor']),
      'albumLoaded': _asBool(saved['albumLoaded']),
      'playContext': _asList(saved['playContext']),
      'directoryInfo': _asBool(saved['directoryInfo']),
      'wantsSongDetails': _asBool(saved['wantsSongDetails']),
      'discover': <String, Object?>{
        'tab': _asString(discovery['tab']) ?? 'playlists',
        'items': _asList(discovery['items']),
        'offset': _nonNegative(discovery['offset']),
        'more': _asBool(discovery['more']),
        'category': _asString(discovery['category']) ?? '全部',
        'newSongArea': _asString(discovery['newSongArea']) ?? '5',
      },
    };
  }
}

/// First failing gate condition; carries the frozen failureReason.
class _GateFailure implements Exception {
  const _GateFailure(this.reason);

  final String reason;
}

/// UTF-8 + JSON decode; null means "invalid-json" to the caller.
Map<String, Object?>? _decodeSession(List<int> bytes) {
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } catch (_) {
    return null;
  }
  if (decoded is! Map) {
    return null;
  }
  final result = <String, Object?>{};
  decoded.forEach((key, value) {
    if (key is String) {
      result[key] = value;
    }
  });
  return result;
}

/// QJsonValue::toObject(): a non-object reads as null, the caller substitutes {}.
Map<String, Object?>? _asMap(Object? value) {
  if (value is! Map) {
    return null;
  }
  final result = <String, Object?>{};
  value.forEach((key, entry) {
    if (key is String) {
      result[key] = entry;
    }
  });
  return result;
}

/// QJsonValue::toArray(): a non-array reads as an empty array.
List<Object?> _asList(Object? value) {
  if (value is List) {
    return value;
  }
  return const <Object?>[];
}

/// QJsonValue::toString() with no default: a non-string reads as null.
String? _asString(Object? value) => value is String ? value : null;

/// QJsonValue::toBool(): a non-bool reads as false.
bool _asBool(Object? value) => value is bool ? value : false;

/// QJsonValue::toInt(defaultValue): only whole, 32-bit in-range numbers convert.
///
/// Qt/src/serialization qjsonvalue.cpp:686-705 splits on the CBOR type:
///   * Double  -> convertDoubleTo<int>() (qnumeric_p.h:264-289): the value must
///     lie inside [-2147483648.0, 2147483648.0) — the supremum 2^31 (= -1 *
///     Tmin) is already rejected by `v >= supremum` — and convert back exactly,
///     so a fractional or non-finite double falls back.
///   * Integer -> `qint64(int(n)) == n`, i.e. the stored 64-bit integer must fit
///     int32 (3000000000 does not, -2147483648 does).
/// Everything else (bool, object, string, missing) returns [fallback]. Nothing
/// is truncated here: the 0..39-style clamping lives at the call sites, exactly
/// like Qt's std::clamp(..., 0, 39).
int _toIntOr(Object? value, int fallback) {
  if (value is int) {
    // Dart's int is 64-bit, so the Qt Integer branch needs the int32 round trip.
    if (value < -2147483648 || value > 2147483647) {
      return fallback;
    }
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      return fallback;
    }
    // -2147483648.0 is accepted, 2147483648.0 (the supremum) is rejected.
    if (value < -2147483648.0 || value >= 2147483648.0) {
      return fallback;
    }
    if (value != value.roundToDouble()) {
      return fallback;
    }
    return value.toInt();
  }
  return fallback;
}

int _clampInt(int value, int low, int high) {
  if (value < low) {
    return low;
  }
  if (value > high) {
    return high;
  }
  return value;
}

int _maxInt(int a, int b) => a > b ? a : b;

/// MusicSession.cpp:28-30: std::max(0, value.toInt()).
int _nonNegative(Object? value) {
  final number = _toIntOr(value, 0);
  return number < 0 ? 0 : number;
}

/// QJsonValue::toDouble(): a non-number reads as 0. The upper bound is the
/// injected runtime layout maximum, so the clamp is 0..maximum
/// (MusicSession.cpp:247).
double _clampDouble(Object? value, int maximum) {
  var number = 0.0;
  if (value is num) {
    number = value.toDouble();
  }
  if (!number.isFinite) {
    number = 0;
  }
  final upper = maximum < 0 ? 0.0 : maximum.toDouble();
  if (number < 0) {
    return 0;
  }
  if (number > upper) {
    return upper;
  }
  return number;
}
