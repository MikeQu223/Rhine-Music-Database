// Panel preference store - 1:1 parity with the Qt panel preference contract.
//
// Qt side (READ ONLY spec): Qt/src/Host.cpp
//   * Host.cpp:1039-1058 - ONE function-local static QStringList is used for
//     BOTH read and write. The comment there is explicit: if the read list and
//     the write list diverge, a write succeeds but the read-back is empty, and
//     the UI shows "the setting jumps back right after saving".
//   * Host.cpp:1061-1076 - Host::preference(key) returns '' while offline, ''
//     for a key that is not whitelisted, and '' when the key is simply absent.
//     There is NO defaults file and NO first-launch default writing.
//   * Host.cpp:1077-1106 - Host::setPreference(key, value) persists
//     "panel/" + key only when
//         !offline && value.size() < 262144 && preferenceKeys().contains(key)
//     i.e. the limit is QString CHARACTERS (UTF-16 code units) and it is
//     STRICTLY LESS-THAN, not UTF-8 bytes. Anything else is silently dropped.
//   * Values are stored and read ENTIRELY AS STRINGS ("off", "0.7"); callers
//     interpret bool/number. No type is ever written into the store.
//
// The real landing point of QSettings on Android (absolute path, file name,
// INI escaping) is not decided here: contract section 5.1 forbids guessing
// it, and a self-built JSON or shared_preferences replacement would not see
// Qt's keys at all - which is equivalent to losing every setting. The store is
// therefore platform-agnostic and PURE Dart: the persistence backend is
// injected as a [PreferencePort]. This file performs no file IO of its own,
// never guesses the Android sandbox path, and must be round-tripped against a
// real Qt-generated store before any production wiring is claimed.
//
// Identity coupling ( section 5.4): panel/provider, panel/kugou-edition and
// panel/account-id-* feed the session library identity gate. Qt only falls back
// to 'netease' IN MEMORY and never persists that fallback, so a missing
// provider MUST stay missing here as well. 'kugou' uids live in
// account-id-kugou-standard / account-id-kugou-lite. An unreadable identity
// key is a BLOCKED condition for the caller - never a silent re-login, and
// never a reason to invent a default. This store reports '' exactly like Qt
// does; it must not turn that '' into a default value or a logout.

/// Persistence backend for panel preferences.
///
/// [key] is always the fully qualified `<prefix><panel key>` string - exactly
/// what Qt hands to QSettings (`"panel/" + key`, Qt/src/Host.cpp:1075,1095).
abstract class PreferencePort {
  /// Returns the stored string, or `null` when the key is absent.
  Future<String?> read(String key);

  /// Persists [value] for [key].
  Future<void> write(String key, String value);

  /// Removes [key]; removing an absent key is not an error.
  Future<void> remove(String key);
}

/// Panel preferences behind an injected [PreferencePort].
///
/// Mirrors `Host::preference` / `Host::setPreference` (Qt/src/Host.cpp:1061-1106).
class PreferenceStore {
  /// Creates a store over [port]. [offline] mirrors Qt's offline flag: while
  /// offline every read answers '' and every write is dropped without touching
  /// the port (Qt/src/Host.cpp:1072,1094).
  PreferenceStore({required this.port, this.offline = false});

  /// The persistence backend. Never bypassed: the store does no file IO.
  final PreferencePort port;

  /// When true all reads return '' and all writes/removes are dropped.
  final bool offline;

  /// Serialized key prefix; Qt writes `"panel/" + key`
  /// (Qt/src/Host.cpp:1075,1095).
  static const String prefix = 'panel/';

  /// The Qt value-length gate in QString characters, i.e. UTF-16 code units:
  /// `value.size() < 262144` (Qt/src/Host.cpp:1094). Because the Qt test is
  /// STRICTLY less-than, this constant is the first REJECTED length - the
  /// largest accepted value is 262143 characters - and it is a character
  /// (code unit) budget, NOT a UTF-8 byte budget.
  static const int maxValueCodeUnits = 262144;

  /// The 53 whitelisted panel keys in the EXACT frozen order of
  /// Qt/src/Host.cpp:1042-1057 ( contract section 5.2).
  ///
  /// ONE list serves both read and write, because a split list makes a saved
  /// setting bounce back immediately (Qt/src/Host.cpp:1039-1040).
  static const List<String> panelKeys = <String>[
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

  /// Whether [key] is in the single shared read/write whitelist
  /// (Qt/src/Host.cpp:1107-1109).
  static bool isPanelKey(String key) => panelKeys.contains(key);

  /// Reads [key], returning '' when the store is offline, when the key is not
  /// whitelisted, when it is absent, or when the backend cannot answer.
  ///
  /// There is NO default value and no first-launch default writing
  /// (Qt/src/Host.cpp:1072-1075): a missing key must stay missing so the
  /// caller can tell "unset" from "set to the default".
  Future<String> read(String key) async {
    if (offline || !isPanelKey(key)) {
      return '';
    }
    try {
      return (await port.read(prefix + key)) ?? '';
    } catch (_) {
      // Qt maps a failed QSettings read onto an empty QVariant -> ''. An
      // unreadable key is therefore reported exactly like an absent one; the
      // caller - not this store - decides that unreadable identity keys are
      // BLOCKED ( section 5.4).
      return '';
    }
  }

  /// Writes [value] for [key].
  ///
  /// Returns true when the value reached the port, false when it was dropped.
  /// The value is dropped without touching the port when the store is offline,
  /// when [key] is not whitelisted, or when the value reaches
  /// [maxValueCodeUnits] UTF-16 code units (strictly less-than,
  /// Qt/src/Host.cpp:1094). A backend failure is reported as false as well:
  /// Qt's QSettings has no error channel and silently discards, and a failed
  /// write must never leave other keys or a partial value behind.
  Future<bool> write(String key, String value) async {
    if (offline || value.length >= maxValueCodeUnits || !isPanelKey(key)) {
      return false;
    }
    try {
      await port.write(prefix + key, value);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Removes [key].
  ///
  /// NOTE: Qt has no panel-preference remove path - `preferenceKeys()` is only
  /// ever read or written (Qt/src/Host.cpp:1075,1095). This method exists for
  /// the injected port contract and future use; Qt parity code must not call
  /// it, and it must never be used to reset settings to defaults, which would
  /// violate "no first-launch default writing" ( section 10.3).
  Future<void> remove(String key) async {
    if (offline || !isPanelKey(key)) {
      return;
    }
    try {
      await port.remove(prefix + key);
    } catch (_) {
      // Qt has no error channel for this operation; stay silent like the rest.
    }
  }
}
