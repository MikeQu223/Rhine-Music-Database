import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/app/lifecycle.dart';

/// Recording host: every port call lands in [calls] in the order the machine
/// issued it, which is what the ordering rules are asserted against.
class _FakePorts implements LifecyclePorts {
  _FakePorts({
    this.offline = false,
    this.playbackConnection = false,
    Map<String, String>? preferences,
    this.session,
    this.restoreResult = true,
  }) : preferences = preferences ?? <String, String>{};

  @override
  final bool offline;

  @override
  final bool playbackConnection;

  final Map<String, String> preferences;
  final StoredSession? session;
  final bool restoreResult;

  final List<String> calls = <String>[];
  int engineAttachments = 0;

  @override
  String preference(String key) {
    calls.add('pref:' + key);
    return preferences[key] ?? '';
  }

  @override
  void setPreference(String key, String value) {
    calls.add('setPref:' + key + '=' + value);
    preferences[key] = value;
  }

  @override
  EngineAttachment attachEngine() {
    engineAttachments += 1;
    final String suffix = engineAttachments.toString();
    calls.add('attachEngine:' + suffix);
    return EngineAttachment(
      nodeRuntimeId: 'node-' + suffix,
      loginSessionId: 'login-' + suffix,
      playerId: 'player-' + suffix,
    );
  }

  @override
  void applyPresentationPreferences() => calls.add('applyPresentation');

  @override
  StoredSession? loadSession() {
    calls.add('loadSession');
    return session;
  }

  @override
  bool restoreSession(StoredSession session, {required bool restorePlayer}) {
    calls.add(
      'restoreSession:v' +
          session.version.toString() +
          ',player:' +
          restorePlayer.toString(),
    );
    return restoreResult;
  }

  @override
  void restoreAccount() => calls.add('restoreAccount');

  @override
  void restoreIdentityName() => calls.add('restoreIdentityName');

  @override
  void setVolume(double volume) => calls.add('setVolume:' + volume.toString());

  @override
  void setSceneModeArchive() => calls.add('archive');

  @override
  void replayStartupAnimation() => calls.add('replay');

  @override
  void saveSession() => calls.add('saveSession');

  @override
  void applyWindowShape() => calls.add('applyWindowShape');

  @override
  void showFullScreen() => calls.add('showFullScreen');

  @override
  void setEngineVisible(bool visible) =>
      calls.add('engineVisible:' + visible.toString());

  @override
  void trimMemory() => calls.add('trimMemory');
}

void main() {
  group('consent gate', () {
    test('builds nothing before consent', () {
      final _FakePorts ports = _FakePorts();
      final AppLifecycle lifecycle = AppLifecycle(ports);

      expect(ports.calls, isEmpty);
      expect(lifecycle.snapshot.phase, LifecyclePhase.awaitingConsent);
      expect(lifecycle.snapshot.attachment, isNull);
      expect(lifecycle.snapshot.engineAttachCount, 0);
    });

    test('declining consent runs no business port and blocks the start', () {
      final _FakePorts ports = _FakePorts();
      final AppLifecycle lifecycle = AppLifecycle(ports);

      lifecycle.declineConsent();

      expect(ports.calls, isEmpty);
      expect(lifecycle.snapshot.phase, LifecyclePhase.consentDeclined);
      expect(lifecycle.grantConsent, throwsStateError);
    });

    test('granting consent attaches the engine before any init port', () {
      final _FakePorts ports = _FakePorts();
      final AppLifecycle lifecycle = AppLifecycle(ports);

      lifecycle.grantConsent();

      expect(ports.calls.first, 'attachEngine:1');
      expect(lifecycle.snapshot.phase, LifecyclePhase.running);
      expect(lifecycle.snapshot.engineAttachCount, 1);
      expect(lifecycle.snapshot.attachment!.nodeRuntimeId, 'node-1');
    });

    test('granting consent twice throws', () {
      final _FakePorts ports = _FakePorts();
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();

      expect(lifecycle.grantConsent, throwsStateError);
    });
  });

  group('first launch initialization', () {
    test('replays the animation and secures the one-shot marker', () {
      final _FakePorts ports = _FakePorts();
      final AppLifecycle lifecycle = AppLifecycle(ports);

      lifecycle.grantConsent();

      // Qt/src/NativeApplication.cpp:44-90, in order.
      expect(ports.calls, <String>[
        'attachEngine:1',
        'applyPresentation',
        'pref:startup-animation',
        'pref:theme',
        'pref:provider',
        'pref:volume',
        'setPref:startup-animation=off',
        'pref:volume',
        'setVolume:0.7',
        'loadSession',
        'replay',
        'restoreAccount',
        'restoreIdentityName',
      ]);
      expect(lifecycle.snapshot.firstLaunch, isTrue);
      expect(lifecycle.snapshot.startupAnimation, isFalse);
      expect(lifecycle.snapshot.startupView, StartupView.replay);
      expect(lifecycle.snapshot.volume, 0.7);
      expect(ports.preferences['startup-animation'], 'off');
    });

    test('returning user restores archive without replaying', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{
          'startup-animation': 'off',
          'theme': 'dark',
          'provider': 'kugou',
          'volume': '0.35',
        },
      );
      final AppLifecycle lifecycle = AppLifecycle(ports);

      lifecycle.grantConsent();

      // The first-launch probe short-circuits at the non-empty startup key, so
      // theme/provider are not read again (Qt/src/NativeApplication.cpp:49-51).
      // Archive is decided before the volume read and before the restore
      // (Qt/src/NativeApplication.cpp:55-63).
      expect(ports.calls, <String>[
        'attachEngine:1',
        'applyPresentation',
        'pref:startup-animation',
        'archive',
        'pref:volume',
        'setVolume:0.35',
        'loadSession',
        'restoreAccount',
        'restoreIdentityName',
      ]);
      expect(lifecycle.snapshot.firstLaunch, isFalse);
      expect(lifecycle.snapshot.startupView, StartupView.archive);
      expect(lifecycle.snapshot.volume, 0.35);
    });

    test('enabled animation replays on every launch', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{
          'startup-animation': 'on',
          'theme': 'dark',
          'provider': 'kugou',
          'volume': '0.5',
        },
      );
      final AppLifecycle lifecycle = AppLifecycle(ports);

      lifecycle.grantConsent();

      expect(lifecycle.snapshot.startupAnimation, isTrue);
      expect(lifecycle.snapshot.startupView, StartupView.replay);
      expect(ports.calls, isNot(contains('archive')));
    });

    test('unparsable volume falls back to 0.7', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{
          'startup-animation': 'off',
          'volume': 'loud',
        },
      );

      AppLifecycle(ports).grantConsent();

      expect(ports.calls, contains('setVolume:0.7'));
    });

    test('infinite volume falls back to 0.7', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{
          'startup-animation': 'off',
          'volume': 'Infinity',
        },
      );

      AppLifecycle(ports).grantConsent();

      expect(ports.calls, contains('setVolume:0.7'));
    });

    test('a playback connection keeps the player untouched', () {
      final _FakePorts ports = _FakePorts(
        playbackConnection: true,
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports);

      lifecycle.grantConsent();

      expect(ports.calls, isNot(contains('setVolume:0.7')));
      expect(lifecycle.snapshot.volume, isNull);
    });
  });

  group('session restore', () {
    test('accepts a version 1 document', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
        session: const StoredSession(version: 1),
      );
      final AppLifecycle lifecycle = AppLifecycle(ports);

      lifecycle.grantConsent();

      expect(ports.calls, contains('restoreSession:v1,player:true'));
      expect(lifecycle.snapshot.sessionRestored, isTrue);
      expect(lifecycle.snapshot.sessionRestoreAttempts, 1);
    });

    test('rejects a foreign document version without deleting it', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
        session: const StoredSession(version: 2),
      );
      final AppLifecycle lifecycle = AppLifecycle(ports);

      lifecycle.grantConsent();

      expect(ports.calls, contains('loadSession'));
      expect(
        ports.calls.where((String call) => call.startsWith('restoreSession')),
        isEmpty,
      );
      expect(lifecycle.snapshot.sessionRestored, isFalse);
      expect(lifecycle.snapshot.sessionRestoreAttempts, 1);
    });

    test('tolerates a rejected document and keeps running', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
        session: const StoredSession(version: 1),
        restoreResult: false,
      );
      final AppLifecycle lifecycle = AppLifecycle(ports);

      lifecycle.grantConsent();

      expect(lifecycle.snapshot.phase, LifecyclePhase.running);
      expect(lifecycle.snapshot.sessionRestored, isFalse);
    });

    test('skips the player half while a playback connection is active', () {
      final _FakePorts ports = _FakePorts(
        playbackConnection: true,
        preferences: <String, String>{'startup-animation': 'off'},
        session: const StoredSession(version: 1),
      );

      AppLifecycle(ports).grantConsent();

      expect(ports.calls, contains('restoreSession:v1,player:false'));
    });

    test('offline never reads the session', () {
      final _FakePorts ports = _FakePorts(
        offline: true,
        preferences: <String, String>{'startup-animation': 'off'},
        session: const StoredSession(version: 1),
      );
      final AppLifecycle lifecycle = AppLifecycle(ports);

      lifecycle.grantConsent();

      expect(ports.calls, isNot(contains('loadSession')));
      expect(lifecycle.snapshot.sessionRestoreAttempts, 0);
    });

    test('archive mode is decided before the document is read', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
        session: const StoredSession(version: 1),
      );

      AppLifecycle(ports).grantConsent();

      // Qt sets the archive mode at line 55-57, then reads the volume at 58 and
      // only then opens session.json at 64-69.
      final int archiveAt = ports.calls.indexOf('archive');
      final int loadAt = ports.calls.indexOf('loadSession');
      final int volumeAt = ports.calls.indexOf('pref:volume');
      expect(archiveAt, greaterThan(0));
      expect(volumeAt, greaterThan(archiveAt));
      expect(loadAt, greaterThan(volumeAt));
    });

    test('restores at most once across rotation and reattachment', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
        session: const StoredSession(version: 1),
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();

      lifecycle
        ..rotation()
        ..activityReattached()
        ..hostActivityChanged(HostActivity.inactive)
        ..hostActivityChanged(HostActivity.active);

      expect(lifecycle.snapshot.sessionRestoreAttempts, 1);
      expect(
        ports.calls.where((String call) => call == 'loadSession').length,
        1,
      );
    });
  });

  group('foreground and background', () {
    test('leaving the foreground saves, hides and trims in that order', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();
      // The machine has no host state before the first Qt signal
      // (lib/app/lifecycle.dart:312-315), so leaving the foreground needs a real
      // foreground entry first for the counter guard at lib/app/lifecycle.dart:418.
      lifecycle.hostActivityChanged(HostActivity.active);
      ports.calls.clear();

      lifecycle.hostActivityChanged(HostActivity.inactive);

      // Session save listener connected first (Engine.cpp:66), visibility
      // listener second (main.cpp:1262).
      expect(ports.calls, <String>[
        'saveSession',
        'engineVisible:false',
        'trimMemory',
      ]);
      expect(lifecycle.snapshot.backgroundCount, 1);
      expect(lifecycle.snapshot.isForeground, isFalse);
    });

    test('suspended behaves like inactive', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();
      ports.calls.clear();

      lifecycle.hostActivityChanged(HostActivity.suspended);

      expect(ports.calls, <String>[
        'saveSession',
        'engineVisible:false',
        'trimMemory',
      ]);
    });

    test('hidden hides and trims without saving', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();
      ports.calls.clear();

      lifecycle.hostActivityChanged(HostActivity.hidden);

      expect(ports.calls, <String>['engineVisible:false', 'trimMemory']);
      expect(lifecycle.snapshot.saveCount, 0);
    });

    test('returning to the foreground re-applies the window shape', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();
      lifecycle.hostActivityChanged(HostActivity.inactive);
      ports.calls.clear();

      lifecycle.hostActivityChanged(HostActivity.active);

      expect(ports.calls, <String>[
        'applyWindowShape',
        'showFullScreen',
        'engineVisible:true',
      ]);
      expect(lifecycle.snapshot.foregroundCount, 1);
      expect(lifecycle.snapshot.isForeground, isTrue);
    });

    test('repeated active deliveries keep one foreground entry', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();

      lifecycle
        ..hostActivityChanged(HostActivity.active)
        ..hostActivityChanged(HostActivity.active);

      expect(lifecycle.snapshot.foregroundCount, 1);
      expect(lifecycle.snapshot.isForeground, isTrue);
      // A duplicate delivery is not a Qt signal: QGuiApplication emits
      // applicationStateChanged only on a real change (Qt connections at
      // Qt/src/AndroidWindow.cpp:85-118 and Qt/src/NativeApplication.cpp:84-88), so
      // the window-shape path re-enters idempotently and no second foreground entry
      // is counted.
      expect(
        ports.calls.where((String call) => call == 'applyWindowShape').length,
        2,
      );
      expect(
        ports.calls.where((String call) => call == 'showFullScreen').length,
        2,
      );
      expect(
        ports.calls.where((String call) => call == 'engineVisible:true').length,
        2,
      );
    });

    test('repeated inactive deliveries re-enter without a second background entry', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();
      lifecycle.hostActivityChanged(HostActivity.active);
      ports.calls.clear();

      lifecycle
        ..hostActivityChanged(HostActivity.inactive)
        ..hostActivityChanged(HostActivity.inactive);

      // Mirror of the duplicate Active path: the save / hide / trim path re-enters
      // idempotently while the background counter moves once
      // (lib/app/lifecycle.dart:412-420).
      expect(ports.calls, <String>[
        'saveSession',
        'engineVisible:false',
        'trimMemory',
        'saveSession',
        'engineVisible:false',
        'trimMemory',
      ]);
      expect(lifecycle.snapshot.backgroundCount, 1);
      expect(lifecycle.snapshot.isForeground, isFalse);
    });

    test('the periodic tick saves while running', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();
      ports.calls.clear();

      lifecycle.sessionSaverTick();

      expect(ports.calls, <String>['saveSession']);
      expect(lifecycle.snapshot.saveCount, 1);
      expect(lifecycle.sessionSaverInterval, const Duration(seconds: 15));
    });

    test('offline never writes a session', () {
      final _FakePorts ports = _FakePorts(
        offline: true,
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();
      ports.calls.clear();

      lifecycle
        ..sessionSaverTick()
        ..hostActivityChanged(HostActivity.inactive)
        ..saveBeforeShutdown();

      expect(ports.calls, isNot(contains('saveSession')));
      expect(lifecycle.snapshot.saveCount, 0);
    });

    test('shutdown save writes once while running', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();
      ports.calls.clear();

      // Qt/src/Engine.cpp:67-68 - the desktop aboutToQuit save; on Android the
      // signal never fires (Qt/src/NativeApplication.cpp:77-79).
      lifecycle.saveBeforeShutdown();

      expect(ports.calls, <String>['saveSession']);
      expect(lifecycle.snapshot.saveCount, 1);
    });

    test('shutdown save is ignored before the machine runs', () {
      final _FakePorts ports = _FakePorts();

      AppLifecycle(ports).saveBeforeShutdown();

      expect(ports.calls, isEmpty);
    });

    test('state delivered before consent is remembered without side effects', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports);

      lifecycle.hostActivityChanged(HostActivity.suspended);
      expect(ports.calls, isEmpty);
      expect(lifecycle.snapshot.hostActivity, HostActivity.suspended);

      lifecycle.grantConsent();
      ports.calls.clear();
      lifecycle.hostActivityChanged(HostActivity.active);

      expect(ports.calls, <String>[
        'applyWindowShape',
        'showFullScreen',
        'engineVisible:true',
      ]);
    });
  });

  group('rotation and activity reattachment', () {
    test('rotation touches no port and keeps the engine handle', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();
      final EngineAttachment attachment = lifecycle.snapshot.attachment!;
      ports.calls.clear();

      lifecycle.rotation();

      expect(ports.calls, isEmpty);
      expect(lifecycle.snapshot.rotationCount, 1);
      expect(lifecycle.snapshot.layoutGeneration, 1);
      expect(lifecycle.snapshot.engineAttachCount, 1);
      expect(identical(lifecycle.snapshot.attachment, attachment), isTrue);
      expect(ports.engineAttachments, 1);
    });

    test('activity reattachment re-applies the shape only', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();
      ports.calls.clear();

      lifecycle.activityReattached();

      expect(ports.calls, <String>['applyWindowShape', 'showFullScreen']);
      expect(lifecycle.snapshot.reattachCount, 1);
      expect(lifecycle.snapshot.layoutGeneration, 1);
      expect(lifecycle.snapshot.engineAttachCount, 1);
      expect(ports.engineAttachments, 1);
    });

    test('rotation before consent throws', () {
      final AppLifecycle lifecycle = AppLifecycle(_FakePorts());

      expect(lifecycle.rotation, throwsStateError);
      expect(lifecycle.activityReattached, throwsStateError);
    });

    test('rotation after terminate throws', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();

      lifecycle.terminate();

      expect(lifecycle.rotation, throwsStateError);
    });
  });

  group('termination', () {
    test('teardown calls no port and keeps the process-scoped engine', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();
      ports.calls.clear();

      lifecycle.terminate();

      expect(ports.calls, isEmpty);
      expect(lifecycle.snapshot.phase, LifecyclePhase.terminated);
      expect(lifecycle.snapshot.engineAttachCount, 1);
      expect(lifecycle.snapshot.attachment, isNotNull);
    });

    test('host activity after terminate throws', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();

      lifecycle.terminate();

      expect(
        () => lifecycle.hostActivityChanged(HostActivity.active),
        throwsStateError,
      );
    });

    test('terminate is idempotent', () {
      final _FakePorts ports = _FakePorts(
        preferences: <String, String>{'startup-animation': 'off'},
      );
      final AppLifecycle lifecycle = AppLifecycle(ports)..grantConsent();

      lifecycle
        ..terminate()
        ..terminate();

      expect(lifecycle.snapshot.phase, LifecyclePhase.terminated);
    });
  });
}
