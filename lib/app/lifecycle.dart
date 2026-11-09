/// Architecture-neutral application lifecycle for the Qt to Flutter port
/// (plan T20, slice S01).
///
/// This file imports nothing. The machine knows only the events a host can
/// deliver and the ports a host must inject, so the same transitions drive a Qt
/// shell, an embedded Flutter engine or an offline test. Choosing the host,
/// wiring main, the router and the bootstrap is deliberately out of scope.
///
/// Rules carried over from Qt, each with the source line it came from:
///
/// * Nothing business-related runs before consent: the consent Activity is the
///   only LAUNCHER entry point and QtActivity is not exported
///   (Qt/android/AndroidManifest.xml:84-105,
///   Qt/android/src/rhine/music/database/ConsentActivity.java:148-156).
/// * The engine (Node runtime, login session, player) is attached exactly once,
///   after consent (Qt/src/Engine.cpp:53, Qt/src/Engine.cpp:66) and is never
///   rebuilt by a screen rotation or an Activity reattachment
///   (Qt/src/BridgeProcessAndroid.cpp:164-168 keeps the Node runtime
///   process-scoped; Qt/android/AndroidManifest.xml:100 absorbs rotation through
///   android:configChanges).
/// * The stored session is restored at most once per process, only when the host
///   is online, and a rejected document is left on disk
///   (Qt/src/NativeApplication.cpp:64-69, Qt/src/MusicSession.cpp:237-238).
/// * Leaving the foreground saves the session, hides the engine and trims GPU
///   memory; entering the foreground re-requests the landscape immersive window
///   (Qt/src/NativeApplication.cpp:84-88, Qt/src/AndroidWindow.cpp:85-118).
library;

/// Period of the mobile session saver (Qt/src/NativeApplication.cpp:81).
///
/// Android has no clean exit: swiping the app away is SIGKILL and aboutToQuit
/// never fires (Qt/src/NativeApplication.cpp:77-79), so the state is written on
/// a timer and immediately when the app leaves the foreground.
const Duration kSessionSaverInterval = Duration(seconds: 15);

/// Volume used when the stored preference is missing or not a finite number
/// (Qt/src/NativeApplication.cpp:58-63).
const double kFallbackVolume = 0.7;

/// Version tag of the session document; anything else is rejected before
/// restore (Qt/src/MusicSession.cpp:216, Qt/src/MusicSession.cpp:238).
const int kSessionDocumentVersion = 1;

/// Preference keys one-time initialization reads
/// (Qt/src/NativeApplication.cpp:47-58).
abstract final class LifecyclePreferenceKeys {
  /// Written to off on the first launch (Qt/src/NativeApplication.cpp:53).
  static const String startupAnimation = 'startup-animation';

  /// Part of the first-launch probe (Qt/src/NativeApplication.cpp:49).
  static const String theme = 'theme';

  /// Part of the first-launch probe (Qt/src/NativeApplication.cpp:50).
  static const String provider = 'provider';

  /// Restored into the player (Qt/src/NativeApplication.cpp:58-63).
  static const String volume = 'volume';
}

/// Literal preference values the Qt settings page writes
/// (Qt/src/NativeHudController.cpp:37, Qt/src/NativeHudController.cpp:872).
abstract final class LifecyclePreferenceValues {
  static const String on = 'on';
  static const String off = 'off';
}

/// Which scene-mode branch initialization requested, in the order Qt issues it.
///
/// This is the branch the machine asked for, not a guarantee about the first
/// frame: a restored document overwrites the scene mode right after
/// (Qt/src/MusicSession.cpp:262). The replay branch is issued last, so it is the
/// one branch a restore cannot override (Qt/src/NativeApplication.cpp:70-73).
enum StartupView {
  /// hud.action("replay") - first launch, or the user re-enabled the animation
  /// (Qt/src/NativeApplication.cpp:71-73).
  replay,

  /// m_scene->setMode("archive") (Qt/src/NativeApplication.cpp:55-57).
  archive,
}

/// The subset of Qt::ApplicationState the shell reacts to.
///
/// Qt hides the engine for every non-Active state but saves the session only for
/// inactive and suspended
/// (Qt/src/AndroidWindow.cpp:94, Qt/src/NativeApplication.cpp:85).
enum HostActivity { active, inactive, hidden, suspended }

/// Lifecycle phases. running is the only phase in which host events are
/// applied; consent is a hard gate in front of everything else.
enum LifecyclePhase {
  /// Consent has not been answered yet; no business port may run.
  awaitingConsent,

  /// Consent granted; the one-time initialization is in flight.
  initializing,

  /// Initialization finished; foreground and background events are applied.
  running,

  /// Consent declined: the app exits and nothing else runs.
  consentDeclined,

  /// Process teardown; no further event is accepted.
  terminated,
}

/// Opaque restore document.
///
/// The machine only reads [version]. Every field-level rule - provider/edition/
/// uid match, cursor clamps, the 64 MiB ceiling - stays with the library and view
/// owners that Qt keeps in MusicLibrary::restoreSessionState and
/// NativeApplication::restoreSessionState
/// (Qt/src/MusicSession.cpp:88-213, Qt/src/MusicSession.cpp:237-266).
class StoredSession {
  const StoredSession({required this.version});

  /// Document version, compared against [kSessionDocumentVersion].
  final int version;
}

/// Handles owned by the injected engine port.
///
/// The three identifiers exist so a reviewer (and a test) can prove that a
/// rotation or an Activity reattachment kept the same runtime, login session and
/// player instead of silently building new ones.
class EngineAttachment {
  const EngineAttachment({
    required this.nodeRuntimeId,
    required this.loginSessionId,
    required this.playerId,
  });

  /// Identity of the process-scoped Node runtime.
  final String nodeRuntimeId;

  /// Identity of the signed-in login session.
  final String loginSessionId;

  /// Identity of the player instance.
  final String playerId;
}

/// Host services the lifecycle machine drives.
///
/// Implementations adapt these calls to whatever host was adjudicated; the
/// machine never constructs a host object itself.
abstract interface class LifecyclePorts {
  /// Host::offline - offline runs never read or write session.json
  /// (Qt/src/NativeApplication.cpp:64, Qt/src/MusicSession.cpp:269-272).
  bool get offline;

  /// Host::playbackConnection() - when another process owns playback the UI must
  /// not overwrite volume or player state
  /// (Qt/src/NativeApplication.cpp:61, Qt/src/MusicSession.cpp:263-265).
  bool get playbackConnection;

  /// Raw preference value, empty when unset (QSettings semantics).
  String preference(String key);

  /// Stores a raw preference value.
  void setPreference(String key, String value);

  /// Builds the process-scoped engine. Called exactly once per process.
  EngineAttachment attachEngine();

  /// Pushes the theme / motion values the HUD captured when it was constructed
  /// (Qt/src/NativeHudController.cpp:31-36) onto the scene, before any other
  /// preference is read (Qt/src/NativeApplication.cpp:45-46).
  ///
  /// Must not read or write the startup-animation preference: Qt captures that
  /// value when the HUD is constructed (Qt/src/NativeHudController.cpp:37) and
  /// the machine consumes it in step 2 of [AppLifecycle], so an implementation
  /// that touched it here would change which launches replay. This call must
  /// also complete before any of the ports below runs.
  void applyPresentationPreferences();

  /// Reads the session document; null when absent, unreadable or above the
  /// 64 MiB ceiling (Qt/src/NativeApplication.cpp:65-69).
  StoredSession? loadSession();

  /// Restores the document and returns false when it is rejected.
  ///
  /// [restorePlayer] mirrors the Qt guard that skips the player half while a
  /// playback connection is active (Qt/src/MusicSession.cpp:263-265).
  bool restoreSession(StoredSession session, {required bool restorePlayer});

  /// music.restoreAccount() (Qt/src/NativeApplication.cpp:74).
  void restoreAccount();

  /// music.restoreIdentityName() (Qt/src/NativeApplication.cpp:75).
  void restoreIdentityName();

  /// music.player.volume(...) (Qt/src/NativeApplication.cpp:62).
  void setVolume(double volume);

  /// m_scene->setMode("archive") (Qt/src/NativeApplication.cpp:56).
  void setSceneModeArchive();

  /// hud.action("replay") (Qt/src/NativeApplication.cpp:72).
  void replayStartupAnimation();

  /// NativeApplication::saveSession (Qt/src/MusicSession.cpp:269-284).
  void saveSession();

  /// sensorLandscape plus the fullscreen/immersive flags
  /// (Qt/src/AndroidWindow.cpp:25-51, Qt/src/AndroidWindow.cpp:81).
  void applyWindowShape();

  /// window->showFullScreen() (Qt/src/AndroidWindow.cpp:82).
  void showFullScreen();

  /// backend->setVisible(active) (Qt/src/AndroidWindow.cpp:100).
  void setEngineVisible(bool visible);

  /// backend->trimMemory() (Qt/src/AndroidWindow.cpp:115).
  void trimMemory();
}

/// Immutable reading of the machine, safe to hand to the UI layer.
class LifecycleSnapshot {
  const LifecycleSnapshot({
    required this.phase,
    required this.hostActivity,
    required this.firstLaunch,
    required this.startupAnimation,
    required this.startupView,
    required this.volume,
    required this.attachment,
    required this.engineAttachCount,
    required this.sessionRestored,
    required this.sessionRestoreAttempts,
    required this.foregroundCount,
    required this.backgroundCount,
    required this.rotationCount,
    required this.reattachCount,
    required this.layoutGeneration,
    required this.saveCount,
  });

  /// Current phase.
  final LifecyclePhase phase;

  /// Last host activity reported by the platform.
  final HostActivity hostActivity;

  /// True when all four first-launch preferences were untouched.
  final bool firstLaunch;

  /// True when startup-animation was on at construction time.
  final bool startupAnimation;

  /// Last scene-mode branch the machine requested, null until initialization.
  ///
  /// A restored document can replace that mode afterwards
  /// (Qt/src/MusicSession.cpp:262), so this is not always the frame on screen.
  final StartupView? startupView;

  /// Applied volume, or null when a playback connection owns the player.
  final double? volume;

  /// Engine handles, null before consent.
  final EngineAttachment? attachment;

  /// How often the engine was attached; must stay 1 for the whole process.
  final int engineAttachCount;

  /// Whether the stored document was accepted.
  final bool sessionRestored;

  /// How many stored documents were loaded from disk for restore, including a
  /// document the version gate rejects before it ever reaches
  /// [LifecyclePorts.restoreSession] (Qt/src/MusicSession.cpp:237-238).
  final int sessionRestoreAttempts;

  /// Foreground entries.
  final int foregroundCount;

  /// Background entries.
  final int backgroundCount;

  /// Rotations observed.
  final int rotationCount;

  /// Activity reattachments observed.
  final int reattachCount;

  /// Increments on every rotation and reattachment; the UI rebuilds on it while
  /// the engine, login session and player stay untouched.
  final int layoutGeneration;

  /// Session writes performed by the machine.
  final int saveCount;

  /// True once initialization finished.
  bool get isRunning => phase == LifecyclePhase.running;

  /// True when the app is running and the host reports it as active.
  bool get isForeground =>
      phase == LifecyclePhase.running && hostActivity == HostActivity.active;
}

/// Drives the lifecycle rules above over an injected [LifecyclePorts].
class AppLifecycle {
  /// Creates the machine in [LifecyclePhase.awaitingConsent].
  AppLifecycle(this._ports);

  final LifecyclePorts _ports;

  LifecyclePhase _phase = LifecyclePhase.awaitingConsent;

  /// Qt has no application state before the first signal; starting from
  /// [HostActivity.inactive] keeps the first Active delivery on the window-shape
  /// path (Qt/src/AndroidWindow.cpp:85-91).
  HostActivity _hostActivity = HostActivity.inactive;

  EngineAttachment? _attachment;
  int _engineAttachCount = 0;
  bool _firstLaunch = false;
  bool _startupAnimation = false;
  StartupView? _startupView;
  double? _volume;
  bool _sessionRestored = false;
  int _sessionRestoreAttempts = 0;
  int _foregroundCount = 0;
  int _backgroundCount = 0;
  int _rotationCount = 0;
  int _reattachCount = 0;
  int _layoutGeneration = 0;
  int _saveCount = 0;

  /// Current immutable reading.
  LifecycleSnapshot get snapshot => LifecycleSnapshot(
    phase: _phase,
    hostActivity: _hostActivity,
    firstLaunch: _firstLaunch,
    startupAnimation: _startupAnimation,
    startupView: _startupView,
    volume: _volume,
    attachment: _attachment,
    engineAttachCount: _engineAttachCount,
    sessionRestored: _sessionRestored,
    sessionRestoreAttempts: _sessionRestoreAttempts,
    foregroundCount: _foregroundCount,
    backgroundCount: _backgroundCount,
    rotationCount: _rotationCount,
    reattachCount: _reattachCount,
    layoutGeneration: _layoutGeneration,
    saveCount: _saveCount,
  );

  /// Interval a host must use for its session-save timer.
  Duration get sessionSaverInterval => kSessionSaverInterval;

  /// Consent granted. The only entry point that builds the engine and the only
  /// one that runs the initialization sequence
  /// (Qt/src/Engine.cpp:53, Qt/src/Engine.cpp:66).
  void grantConsent() {
    _require(LifecyclePhase.awaitingConsent, 'grantConsent');
    _phase = LifecyclePhase.initializing;
    _attachment = _ports.attachEngine();
    _engineAttachCount += 1;
    _initialize();
    _phase = LifecyclePhase.running;
  }

  /// Consent declined: the app exits before any business port runs
  /// (Qt/android/src/rhine/music/database/ConsentActivity.java:126).
  void declineConsent() {
    _require(LifecyclePhase.awaitingConsent, 'declineConsent');
    _phase = LifecyclePhase.consentDeclined;
  }

  /// Host foreground/background delivery.
  ///
  /// Qt connects two listeners to the same signal: the session save inside
  /// initialize() (Qt/src/NativeApplication.cpp:84-88, connected from
  /// Qt/src/Engine.cpp:66) and the window/engine visibility one from
  /// configureAndroidWindow (Qt/src/AndroidWindow.cpp:85-118, connected at
  /// Qt/src/main.cpp:1262). Connection order is therefore save first, then
  /// visibility and trim, which is the order kept here.
  ///
  /// The host must mirror QGuiApplication::applicationStateChanged. Qt connects it
  /// in two places - the session save at Qt/src/NativeApplication.cpp:84-88 and the
  /// window/visibility listeners at Qt/src/AndroidWindow.cpp:85-118 (wired from
  /// Qt/src/main.cpp:1262) - and both receive one emission per real state change, an
  /// emission-on-change behaviour that belongs to QGuiApplication itself and not to
  /// a guard in those files; the periodic saver is a separate Qt timer
  /// (Qt/src/NativeApplication.cpp:80-83). A repeated delivery of the current
  /// state is therefore not a Qt signal: the machine treats it as an idempotent
  /// re-entry of the same path - the window shape is requested again for an
  /// active state, and save / hide / trim run again for an inactive one - without
  /// counting a second foreground or background entry.
  void hostActivityChanged(HostActivity activity) {
    if (_phase == LifecyclePhase.terminated) {
      throw StateError('hostActivityChanged cannot run after terminate');
    }
    final LifecyclePhase previousPhase = _phase;
    final HostActivity previousActivity = _hostActivity;
    _hostActivity = activity;
    if (previousPhase != LifecyclePhase.running) {
      // Qt connects the listeners only once the window exists, so a state
      // delivered during startup changes nothing; remembering it keeps the
      // snapshot honest.
      return;
    }
    if (activity == HostActivity.active) {
      _ports.applyWindowShape();
      _ports.showFullScreen();
      _ports.setEngineVisible(true);
      if (previousActivity != HostActivity.active) {
        _foregroundCount += 1;
      }
      return;
    }
    if (activity == HostActivity.inactive ||
        activity == HostActivity.suspended) {
      _saveSession();
    }
    _ports.setEngineVisible(false);
    _ports.trimMemory();
    if (previousActivity == HostActivity.active) {
      _backgroundCount += 1;
    }
  }

  /// Screen rotation.
  ///
  /// The manifest absorbs rotation through android:configChanges
  /// (Qt/android/AndroidManifest.xml:100), so Qt keeps the same window and the
  /// same NativeApplication; the scene simply samples the new width on the next
  /// frame (Qt/src/NativeApplication.cpp:98-131). No port is called: the engine,
  /// login session and player are untouched and only
  /// [LifecycleSnapshot.layoutGeneration] moves.
  void rotation() {
    _requireRunning('rotation');
    _rotationCount += 1;
    _layoutGeneration += 1;
  }

  /// The Activity was recreated while the process survived: returning from the
  /// background after the window was dropped, or switching split-screen mode.
  /// Qt re-requests the same shape and fullscreen instead of rebuilding anything
  /// (Qt/src/AndroidWindow.cpp:83-91, Qt/android/AndroidManifest.xml:108-110).
  void activityReattached() {
    _requireRunning('activityReattached');
    _reattachCount += 1;
    _layoutGeneration += 1;
    _ports.applyWindowShape();
    _ports.showFullScreen();
  }

  /// Periodic saver tick; the host owns the timer ([kSessionSaverInterval],
  /// Qt/src/NativeApplication.cpp:80-83).
  void sessionSaverTick() {
    _requireRunning('sessionSaverTick');
    _saveSession();
  }

  /// Desktop-style shutdown save (Qt/src/Engine.cpp:67-68). Harmless on Android,
  /// where aboutToQuit never fires (Qt/src/NativeApplication.cpp:77-79).
  void saveBeforeShutdown() {
    if (_phase != LifecyclePhase.running) {
      return;
    }
    _saveSession();
  }

  /// Process teardown.
  ///
  /// No port is called: the Node runtime is process-scoped and intentionally
  /// never stopped (Qt/src/BridgeProcessAndroid.cpp:164-168), and the last
  /// foreground step already saved through [hostActivityChanged].
  void terminate() {
    if (_phase == LifecyclePhase.terminated) {
      return;
    }
    _phase = LifecyclePhase.terminated;
  }

  void _initialize() {
    // 1. Theme and reduced motion before any other preference
    //    (Qt/src/NativeApplication.cpp:45-46).
    _ports.applyPresentationPreferences();

    // 2. hud.startupAnimation was captured when the HUD was constructed
    //    (Qt/src/NativeHudController.cpp:37), i.e. before the one-shot write in
    //    step 4, so it still reflects the stored value here.
    final String startupPreference = _ports.preference(
      LifecyclePreferenceKeys.startupAnimation,
    );
    _startupAnimation = startupPreference == LifecyclePreferenceValues.on;

    // 3. First launch means four untouched preferences, short-circuited left to
    //    right exactly like the Qt expression
    //    (Qt/src/NativeApplication.cpp:49-51).
    bool firstLaunch = false;
    if (startupPreference.isEmpty) {
      final String theme = _ports.preference(LifecyclePreferenceKeys.theme);
      if (theme.isEmpty) {
        final String provider = _ports.preference(
          LifecyclePreferenceKeys.provider,
        );
        if (provider.isEmpty) {
          final String volume = _ports.preference(
            LifecyclePreferenceKeys.volume,
          );
          firstLaunch = volume.isEmpty;
        }
      }
    }
    _firstLaunch = firstLaunch;

    // 4. The marker is written once so the animation cannot come back by
    //    accident (Qt/src/NativeApplication.cpp:52-54).
    if (startupPreference.isEmpty) {
      _ports.setPreference(
        LifecyclePreferenceKeys.startupAnimation,
        LifecyclePreferenceValues.off,
      );
    }

    // 5. Archive mode, decided before the session is read, exactly where Qt puts
    //    it (Qt/src/NativeApplication.cpp:55-57).
    if (!firstLaunch && !_startupAnimation) {
      _ports.setSceneModeArchive();
      _startupView = StartupView.archive;
    }

    // 6. Volume: the stored value when it parses to a finite number, otherwise
    //    0.7, and only when no playback connection owns the player
    //    (Qt/src/NativeApplication.cpp:58-63).
    final String storedVolume = _ports.preference(
      LifecyclePreferenceKeys.volume,
    );
    final double? parsedVolume = double.tryParse(storedVolume);
    final double volume = parsedVolume != null && parsedVolume.isFinite
        ? parsedVolume
        : kFallbackVolume;
    if (!_ports.playbackConnection) {
      _ports.setVolume(volume);
      _volume = volume;
    }

    // 7. Session restore: one attempt, skipped while offline, and a rejected
    //    document leaves the previous file in place
    //    (Qt/src/NativeApplication.cpp:64-69).
    if (!_ports.offline) {
      final StoredSession? session = _ports.loadSession();
      if (session != null) {
        _sessionRestoreAttempts += 1;
        if (session.version == kSessionDocumentVersion) {
          _sessionRestored = _ports.restoreSession(
            session,
            restorePlayer: !_ports.playbackConnection,
          );
        }
      }
    }

    // 8. The startup page is chosen only now, after the restore, so a restored
    //    scene mode cannot override the switch
    //    (Qt/src/NativeApplication.cpp:70-73).
    if (_firstLaunch || _startupAnimation) {
      _ports.replayStartupAnimation();
      _startupView = StartupView.replay;
    }

    // 9. Account and display name (Qt/src/NativeApplication.cpp:74-75).
    _ports.restoreAccount();
    _ports.restoreIdentityName();
  }

  /// Mirrors NativeApplication::saveSession, which returns immediately while
  /// offline (Qt/src/MusicSession.cpp:269-272).
  void _saveSession() {
    if (_ports.offline) {
      return;
    }
    _ports.saveSession();
    _saveCount += 1;
  }

  void _require(LifecyclePhase expected, String event) {
    if (_phase != expected) {
      throw StateError(
        event +
            ' is only valid in ' +
            expected.name +
            ', machine is in ' +
            _phase.name,
      );
    }
  }

  void _requireRunning(String event) => _require(LifecyclePhase.running, event);
}
