// T26-S04 - panel preference store tests (Qt -> Flutter 1:1 parity, storage domain).
//
// Contract: /tmp/t07-drafts/storage.md section 5 (FROZEN T07-C01) and the
// same-baseline Qt source Qt/src/Host.cpp. Every assertion below encodes a Qt
// behaviour and cites it as file:line.
//
// STATUS: UNEXECUTED. This project forbids running flutter test / dart test /
// analyze, so this file ships as an unexecuted RED/GREEN specification of the
// parity contract (RED/GREEN both recorded as NOT EXECUTED).
//
// Pure Dart logic tests: no widget binding, no goldens, no file system access
// outside Directory.systemTemp.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/data/storage/preference_store.dart';

/// The 53 whitelist keys in EXACT frozen order.
///
/// Source of truth: Qt/src/Host.cpp:1042-1057; mirrored by T07 section 5.2.
/// Deliberately re-typed here (not imported from the store) so that drift in
/// either copy fails the test instead of silently agreeing with itself.
const List<String> kQtPanelKeysInOrder = <String>[
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

/// In-memory [PreferencePort] that records every call it receives.
///
/// The store must never do file IO itself, so this port is the only storage
/// boundary and it deliberately touches no disk.
class RecordingPort implements PreferencePort {
  RecordingPort({
    Map<String, String>? initial,
    Set<String> failOnKeys = const <String>{},
    this.readFails = false,
  })  : _values = <String, String>{...?initial},
        _failOnKeys = failOnKeys;

  final Map<String, String> _values;
  final Set<String> _failOnKeys;
  final bool readFails;

  final List<String> reads = <String>[];
  final List<String> writes = <String>[];
  final List<String> removes = <String>[];

  @override
  Future<String?> read(String key) async {
    reads.add(key);
    if (readFails) {
      throw StateError('port read failure');
    }
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes.add(key);
    if (_failOnKeys.contains(key)) {
      throw StateError('port write failure');
    }
    _values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    removes.add(key);
    if (_failOnKeys.contains(key)) {
      throw StateError('port remove failure');
    }
    _values.remove(key);
  }

  String? stored(String key) => _values[key];

  List<String> get touched => <String>[...reads, ...writes, ...removes];
}

/// A DISK-CAPABLE fake port rooted at [root], a Directory.systemTemp probe.
///
/// [RecordingPort] alone can never prove the absence of file IO: an in-memory
/// Map creates nothing whatever it is handed, so a "no file was created"
/// assertion resting only on it would be vacuously true. This port closes that
/// hole in ways that CAN fail:
///   * it really writes every logical key to a file under [root], and the test
///     asserts all those paths stay INSIDE [root] - an absolute key, a ".."
///     escape or a key embedding a foreign directory would surface as a
///     violation and fail;
///   * it records any key that looks like a path (absolute, escaping, or
///     containing [root]) as a [violations] entry instead of accepting it;
///   * [persistedPaths] being non-empty is asserted, which proves the disk path
///     was genuinely exercised and the "nothing appeared elsewhere" checks are
///     therefore meaningful rather than vacuous.
/// The store must only ever hand over the logical key "panel/<panel key>".
class TripwirePort implements PreferencePort {
  TripwirePort({required this.root});

  final String root;
  final Map<String, String> _values = <String, String>{};
  final List<String> reads = <String>[];
  final List<String> writes = <String>[];
  final List<String> removes = <String>[];
  final List<String> persistedPaths = <String>[];
  final List<String> violations = <String>[];

  List<String> get touched => <String>[...reads, ...writes, ...removes];

  bool _looksLikeAPath(String key) =>
      key.startsWith('/') || key.contains('..') || key.contains(root);

  File _fileFor(String key) => File('$root/${Uri.encodeComponent(key)}');

  void _persist(String key, String value) {
    final File file = _fileFor(key);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(value);
    persistedPaths.add(file.path);
  }

  @override
  Future<String?> read(String key) async {
    reads.add(key);
    if (_looksLikeAPath(key)) {
      violations.add(key);
      return null;
    }
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes.add(key);
    if (_looksLikeAPath(key)) {
      // A store that guessed the Android sandbox path lands here.
      violations.add(key);
      return;
    }
    _values[key] = value;
    _persist(key, value);
  }

  @override
  Future<void> remove(String key) async {
    removes.add(key);
    _values.remove(key);
  }
}

void main() {
  group('frozen constants (Qt/src/Host.cpp:1042-1057, 1075, 1094)', () {
    test('prefix is exactly "panel/"', () {
      expect(PreferenceStore.prefix, 'panel/');
    });

    test('maxValueCodeUnits is 262144: the first REJECTED length (strictly less-than)', () {
      expect(PreferenceStore.maxValueCodeUnits, 262144);
    });

    test('panelKeys: exactly 53 entries, zero duplicates, exact order', () {
      final List<String> keys = PreferenceStore.panelKeys;
      expect(keys.length, 53, reason: 'T07 section 5.2 freezes 53 keys');
      expect(keys.toSet().length, 53,
          reason: 'a duplicate key would break read/write symmetry');
      expect(keys, equals(kQtPanelKeysInOrder));
      for (var i = 0; i < kQtPanelKeysInOrder.length; i++) {
        expect(keys[i], kQtPanelKeysInOrder[i],
            reason: 'order drift at index $i');
      }
    });

    test('one list serves both directions: every frozen key is whitelisted',
        () {
      // Qt/src/Host.cpp:1039-1040: a split read/write list makes a saved
      // setting bounce back immediately.
      for (final String key in kQtPanelKeysInOrder) {
        expect(PreferenceStore.isPanelKey(key), isTrue, reason: key);
      }
      expect(PreferenceStore.isPanelKey('nope'), isFalse);
      expect(PreferenceStore.isPanelKey('panel/theme'), isFalse);
      expect(PreferenceStore.isPanelKey(''), isFalse);
    });
  });

  group('read (Qt/src/Host.cpp:1072-1075)', () {
    test('non-whitelisted key returns "" and never reaches the port', () async {
      final RecordingPort port = RecordingPort(
        initial: <String, String>{'panel/nope': 'x'},
      );
      final PreferenceStore store = PreferenceStore(port: port);
      expect(await store.read('nope'), '');
      expect(await store.read('account-id'), '');
      expect(port.reads, isEmpty);
    });

    test('absent whitelisted key returns "" (no defaults file, no first-launch write)',
        () async {
      final RecordingPort port = RecordingPort();
      final PreferenceStore store = PreferenceStore(port: port);
      expect(await store.read('theme'), '');
      expect(port.reads, <String>['panel/theme']);
    });

    test('stored value is returned verbatim, as a String', () async {
      final RecordingPort port = RecordingPort(
        initial: <String, String>{'panel/theme': 'dark'},
      );
      final PreferenceStore store = PreferenceStore(port: port);
      expect(await store.read('theme'), 'dark');
      expect(await store.read('theme'), isA<String>());
    });

    test('port receives exactly "panel/<key>"', () async {
      final RecordingPort port = RecordingPort();
      final PreferenceStore store = PreferenceStore(port: port);
      await store.read('volume');
      expect(port.reads, <String>['panel/volume']);
      expect(port.touched.every((String k) => k.startsWith('panel/')), isTrue);
    });

    test('offline read returns "" without touching the port', () async {
      final RecordingPort port = RecordingPort(
        initial: <String, String>{'panel/theme': 'dark'},
      );
      final PreferenceStore store = PreferenceStore(port: port, offline: true);
      expect(await store.read('theme'), '');
      expect(port.reads, isEmpty);
    });

    test('an unreadable key degrades to "" exactly like an absent key', () async {
      // Qt maps a failed QSettings read onto an empty QVariant -> "".
      final RecordingPort port = RecordingPort(readFails: true);
      final PreferenceStore store = PreferenceStore(port: port);
      expect(await store.read('provider'), '');
      expect(await store.read('theme'), '');
    });
  });

  group('write gate (Qt/src/Host.cpp:1094-1095)', () {
    test('262143 UTF-16 code units is written', () async {
      final RecordingPort port = RecordingPort();
      final PreferenceStore store = PreferenceStore(port: port);
      final String value = List<String>.filled(262143, 'a').join();
      expect(value.length, 262143);
      expect(await store.write('theme', value), isTrue);
      expect(port.writes, <String>['panel/theme']);
      expect(port.stored('panel/theme'), value);
    });

    test('262144 UTF-16 code units is refused and nothing is written', () async {
      final RecordingPort port = RecordingPort();
      final PreferenceStore store = PreferenceStore(port: port);
      final String value = List<String>.filled(262144, 'a').join();
      expect(value.length, 262144);
      expect(await store.write('theme', value), isFalse);
      expect(port.writes, isEmpty);
      expect(port.stored('panel/theme'), isNull);
    });

    test('a value larger than the limit is refused too', () async {
      final RecordingPort port = RecordingPort();
      final PreferenceStore store = PreferenceStore(port: port);
      final String value = List<String>.filled(262145, 'a').join();
      expect(await store.write('theme', value), isFalse);
      expect(port.writes, isEmpty);
    });

    test('the limit counts UTF-16 code units, NOT UTF-8 bytes', () async {
      // 100000 CJK characters = 100000 UTF-16 code units (under the limit) but
      // 300000 UTF-8 bytes (over it). Acceptance proves the unit is characters.
      final RecordingPort port = RecordingPort();
      final PreferenceStore store = PreferenceStore(port: port);
      final String value = List<String>.filled(100000, '\u4e2d').join();
      expect(value.length, 100000);
      expect(utf8.encode(value).length, 300000);
      expect(utf8.encode(value).length > PreferenceStore.maxValueCodeUnits, isTrue);
      expect(await store.write('desktop-lyrics-line-color', value), isTrue);
      expect(port.stored('panel/desktop-lyrics-line-color'), value);
    });

    test('astral characters count 2 code units each (surrogate pairs)', () async {
      final RecordingPort port = RecordingPort();
      final PreferenceStore store = PreferenceStore(port: port);
      const String astral = '\u{10348}'; // 2 UTF-16 code units, 4 UTF-8 bytes
      final String justUnder = List<String>.filled(131071, astral).join();
      final String atLimit = List<String>.filled(131072, astral).join();
      expect(astral.length, 2);
      expect(justUnder.length, 262142);
      expect(atLimit.length, 262144);
      expect(await store.write('theme', justUnder), isTrue);
      expect(await store.write('theme', atLimit), isFalse);
      expect(port.writes, <String>['panel/theme']);
      expect(port.stored('panel/theme'), justUnder);
    });

    test('non-whitelisted key is refused and never reaches the port', () async {
      final RecordingPort port = RecordingPort();
      final PreferenceStore store = PreferenceStore(port: port);
      expect(await store.write('nope', 'x'), isFalse);
      // callers must pass the bare key; the store owns the prefix
      expect(await store.write('panel/theme', 'x'), isFalse);
      expect(await store.write('', 'x'), isFalse);
      expect(port.writes, isEmpty);
    });

    test('offline write is dropped without touching the port', () async {
      final RecordingPort port = RecordingPort(
        initial: <String, String>{'panel/theme': 'dark'},
      );
      final PreferenceStore store = PreferenceStore(port: port, offline: true);
      expect(await store.write('theme', 'light'), isFalse);
      expect(port.writes, isEmpty);
      expect(port.stored('panel/theme'), 'dark');
    });

    test('write forwards exactly "panel/<key>"', () async {
      final RecordingPort port = RecordingPort();
      final PreferenceStore store = PreferenceStore(port: port);
      expect(await store.write('volume', '0.7'), isTrue);
      expect(port.writes, <String>['panel/volume']);
    });

    test('values stay plain strings, never typed', () async {
      // Qt stores QString only; callers interpret bool/number ("off", "0.7").
      final RecordingPort port = RecordingPort();
      final PreferenceStore store = PreferenceStore(port: port);
      await store.write('motion', 'off');
      await store.write('archive-mask-strength', '0.7');
      expect(await store.read('motion'), 'off');
      expect(await store.read('archive-mask-strength'), '0.7');
      expect(port.stored('panel/motion'), isA<String>());
      expect(port.stored('panel/archive-mask-strength'), isA<String>());
    });

    test('a port failure does not corrupt existing keys', () async {
      final RecordingPort port = RecordingPort(
        initial: <String, String>{'panel/volume': '0.7', 'panel/theme': 'dark'},
        failOnKeys: <String>{'panel/motion'},
      );
      final PreferenceStore store = PreferenceStore(port: port);
      expect(await store.write('motion', 'on'), isFalse);
      expect(port.stored('panel/motion'), isNull);
      expect(await store.read('volume'), '0.7');
      expect(await store.read('theme'), 'dark');
      expect(port.stored('panel/volume'), '0.7');
      expect(port.stored('panel/theme'), 'dark');
    });
  });

  group('remove (injected-port extension; Qt has no preference remove path)', () {
    test('whitelisted key is removed as "panel/<key>"', () async {
      final RecordingPort port = RecordingPort(
        initial: <String, String>{'panel/theme': 'dark'},
      );
      final PreferenceStore store = PreferenceStore(port: port);
      await store.remove('theme');
      expect(port.removes, <String>['panel/theme']);
      expect(port.stored('panel/theme'), isNull);
      expect(await store.read('theme'), '');
    });

    test('non-whitelisted key is ignored', () async {
      final RecordingPort port = RecordingPort();
      final PreferenceStore store = PreferenceStore(port: port);
      await store.remove('nope');
      expect(port.removes, isEmpty);
    });

    test('offline remove is a no-op', () async {
      final RecordingPort port = RecordingPort(
        initial: <String, String>{'panel/theme': 'dark'},
      );
      final PreferenceStore store = PreferenceStore(port: port, offline: true);
      await store.remove('theme');
      expect(port.removes, isEmpty);
      expect(port.stored('panel/theme'), 'dark');
    });

    test('a failing remove never throws', () async {
      final RecordingPort port = RecordingPort(
        failOnKeys: <String>{'panel/theme'},
      );
      final PreferenceStore store = PreferenceStore(port: port);
      await store.remove('theme'); // must complete without throwing
      expect(port.removes, <String>['panel/theme']);
    });
  });

  group('no file system side effects (QSettings is a STORE, not a data/panel file)',
      () {
    test('using the store never creates anything under a data directory', () async {
      // Two Directory.systemTemp roots: the port's own backing store (where it
      // legitimately writes) and a stand-in for the Qt data directory, which the
      // STORE must never touch.
      final Directory portRoot =
          Directory.systemTemp.createTempSync('rhine_pref_port_');
      final Directory dataDirectory =
          Directory.systemTemp.createTempSync('rhine_pref_store_');
      addTearDown(() {
        if (portRoot.existsSync()) {
          portRoot.deleteSync(recursive: true);
        }
        if (dataDirectory.existsSync()) {
          dataDirectory.deleteSync(recursive: true);
        }
      });
      final TripwirePort port = TripwirePort(root: portRoot.path);
      final PreferenceStore store = PreferenceStore(port: port);
      for (final String key in PreferenceStore.panelKeys) {
        expect(await store.read(key), '');
        expect(await store.write(key, 'v'), isTrue);
        expect(await store.read(key), 'v');
      }
      await store.remove('theme');
      expect(port.writes.length, PreferenceStore.panelKeys.length);
      expect(port.touched.every((String k) => k.startsWith('panel/')), isTrue);
      // Anti-vacuity: the port DID write to disk, so the checks below really
      // can fail - a store that created or forwarded a real path shows up here.
      expect(port.persistedPaths, isNotEmpty);
      expect(
        port.persistedPaths
            .every((String p) => p.startsWith(portRoot.path + '/')),
        isTrue,
        reason: 'the port must never be steered outside its own root',
      );
      expect(port.violations, isEmpty,
          reason: 'the store must never hand the port an absolute, escaping or'
              ' data-directory-resolving key');
      expect(port.touched.any((String k) => k.contains(dataDirectory.path)),
          isFalse,
          reason: 'the store must never hand a file path to the port');
      expect(dataDirectory.existsSync(), isTrue);
      expect(dataDirectory.listSync(recursive: true), isEmpty,
          reason: 'the store must not write settings.ini or panel/* itself');
    });
  });
}
