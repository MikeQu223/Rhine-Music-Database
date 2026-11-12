/// Start-up consent gate (plan T27, slice S01).
///
/// This file imports nothing but `dart:async`: the machine knows only the events
/// a host delivers and the ports a host injects, so the same transitions drive an
/// Android shell, an embedded engine or an offline test. Choosing the host, the
/// preference backend and the SDK packages stays with the integrator, which is
/// why no Flutter import may appear here.
///
/// Two Qt classes are carried over — ConsentActivity (the LAUNCHER gate) and
/// ConsentStore (the record plus the SDK start gate) — with the source line of
/// every rule:
///
/// * The consent Activity is the only LAUNCHER entry point and QtActivity is
///   exported=false (Qt/android/AndroidManifest.xml:84-105), so before consent
///   neither the Qt interface nor Clarity nor Bugly has started
///   (Qt/android/src/rhine/music/database/ConsentActivity.java:22-23).
/// * A granted record proceeds straight away with the stored region and never
///   probes the region (ConsentActivity.java:69-72); that stored region is kept
///   for diagnosis only (ConsentStore.java:57-63).
/// * Without a record every launch resolves the region live — never cached —
///   behind a hard 3000 ms gate (ConsentActivity.java:73-107,
///   GeoIp.java:50-51); a timeout, an error, or an undetermined result all
///   mean "other region" (ConsentActivity.java:86-89, GeoIp.java:129-131).
/// * Only CN and EU prompt (ConsentActivity.java:98-99), and the dialog cannot be
///   dismissed: no blank-area tap, no back key, two buttons only
///   (ConsentActivity.java:112-113, :121, :128-134).
/// * Agree writes the record once (ConsentStore.java:66-71), then starts the SDKs
///   and the business screen in that order (ConsentActivity.java:122-125,
///   :148-156). Exit calls finishAffinity() and nothing else
///   (ConsentActivity.java:126).
/// * Other regions proceed without a prompt and without writing a record, so the
///   next launch decides again (ConsentActivity.java:100-105,
///   ConsentStore.java:16-17).
/// * Clarity starts on every allowed path, Bugly only for mainland China
///   (ConsentStore.java:20-21, :81-96); each keeps its own start flag
///   (ConsentStore.java:41-44) and both swallow their own failures
///   (ConsentStore.java:89-92, :105-108).
/// * A background wake has no Activity and takes the region from the record
///   (ConsentStore.java:111-114).
library;

import 'dart:async';

/// Region answer of the start-up probe (Qt GeoIp.java:40-45).
///
/// [wire] is the integer the record stores, so both ends agree on the payload
/// (Qt ConsentStore.java:69).
enum ConsentRegion {
  /// Mainland China: the Chinese consent dialog (ConsentActivity.java:98-99,
  /// :119-122) and the only region that starts Bugly (ConsentStore.java:94-96).
  cn(1),

  /// European Union, EU 27 only — the EEA three, the UK and Switzerland are not
  /// in the table (GeoIp.java:42-43). English dialog, Clarity only
  /// (ConsentActivity.java:119-126, ConsentStore.java:20-21).
  eu(2),

  /// Everywhere else, or undetermined: timeout, offline, pure IPv6
  /// (GeoIp.java:44-45, :129-131). No prompt, no record, this run proceeds
  /// (ConsentActivity.java:100-105).
  other(3);

  const ConsentRegion(this.wire);

  /// Integer stored under the "region" key (Qt GeoIp.java:41-45).
  final int wire;

  /// Decodes a stored or probed wire value.
  ///
  /// A table miss is [kRegionNoneWire] inside the resolver and never leaves it
  /// (GeoIp.java:39-40, :133-143); unknown payloads decode to
  /// [ConsentRegion.other] for the same reason — "outside CN/EU or
  /// undetermined" is the answer that cannot prompt anyone by accident.
  static ConsentRegion fromWire(int wire) {
    for (final ConsentRegion region in ConsentRegion.values) {
      if (region.wire == wire) {
        return region;
      }
    }
    return ConsentRegion.other;
  }
}

/// Sentinel a table lookup returns on a miss; it is internal to the resolver and
/// never reaches a caller (Qt GeoIp.java:39-40, :133-143).
const int kRegionNoneWire = 0;

/// Total budget of the start-up region probe, shared by every endpoint rather
/// than granted per endpoint (Qt GeoIp.java:50-51). On expiry the launch
/// continues as [ConsentRegion.other] (ConsentActivity.java:73-75, :86-89,
/// :101-104).
const int kRegionProbeTimeoutMs = 3000;

/// Values the gate fixes and never reads from the environment
/// (Qt ConsentStore.java:28-39).
abstract final class ConsentSdkConfig {
  /// Clarity project id (Qt ConsentStore.java:28).
  static const String clarityProjectId = 'z8vbz4b078';

  /// Bugly console AppID; the AppKey is only used by the backend symbol upload
  /// and is not part of the client initialization (Qt ConsentStore.java:30-31).
  static const String buglyAppId = '22c01c69b9';

  /// Qt ConsentStore.java:32.
  static const bool buglyDebug = false;

  /// Native crashes are handed to Bugly, which is why the RHINE-SIGNAL
  /// diagnostic chain is not compiled in by default (Qt ConsentStore.java:33-39).
  static const bool buglyNativeMonitor = true;
}

/// Names of the consent record, verbatim (Qt ConsentStore.java:25-27).
abstract final class ConsentRecordKeys {
  /// SharedPreferences file the record lives in (Qt ConsentStore.java:25).
  static const String file = 'rhine-consent';

  /// Boolean, default false (Qt ConsentStore.java:26, :53-55).
  static const String granted = 'granted';

  /// Region integer, default [ConsentRegion.other]
  /// (Qt ConsentStore.java:27, :61-63).
  static const String region = 'region';
}

/// What the host persisted, read once per gate run
/// (Qt ConsentStore.java:53-55, :61-63).
class ConsentRecord {
  const ConsentRecord({required this.granted, required this.region});

  /// No record at all: granted=false and region=other
  /// (Qt ConsentStore.java:26-27, :54, :62).
  const ConsentRecord.empty() : granted = false, region = ConsentRegion.other;

  /// ConsentStore.isGranted (Qt ConsentStore.java:53-55).
  final bool granted;

  /// ConsentStore.grantedRegion (Qt ConsentStore.java:61-63).
  final ConsentRegion region;
}

/// Title of the mainland-China permission dialog (ConsentActivity.java:119).
const String kCnConsentTitle = '隐私与数据传输许可';

/// Body of the mainland-China permission dialog, verbatim from the Java text
/// block in ConsentActivity.java:36-51. The block strips the incidental
/// indentation, so this literal is the runtime string, trailing newline
/// included; the nested bullets keep their two leading spaces.
const String kCnConsentMessage =
    '以下第三方 SDK 会处理必要的信息：\n'
    '\n'
    '1.Microsoft Clarity\n'
    '  服务提供：Microsoft\n'
    '  可能收集：界面点击与浏览路径、设备型号、系统版本、屏幕尺寸、应用版本。\n'
    '  上述数据可能会传输至中国境外的服务器，使用这些服务即代表授予数据跨境传输许可。\n'
    '\n'
    '2.Bugly SDK\n'
    '  服务提供：腾讯\n'
    '  可能收集：手机型号、品牌、Android 系统版本与 API 等级、厂商系统版本、CPU 架构、是否 Root、磁盘/内存/存储占用、网络类型、应用进程名与 PID。\n'
    '  收集的数据用于排查质量问题、提升应用运行质量。\n'
    '  隐私政策：https://privacy.qq.com/document/preview/fc748b3d96224fdb825ea79e132c1a56\n'
    '\n'
    '仅适用于中国大陆联网使用。无互联网连接时将不会使用这些服务。\n';

/// Positive button label of the Chinese dialog (ConsentActivity.java:122).
const String kCnConsentApprove = '同意';

/// Negative button label of the Chinese dialog (ConsentActivity.java:126).
const String kCnConsentExit = '退出';

/// Title of the EU permission dialog (ConsentActivity.java:119).
const String kEuConsentTitle = 'Data Transfer Consent';

/// Body of the EU permission dialog, verbatim from ConsentActivity.java:53-62,
/// trailing newline included.
const String kEuConsentMessage =
    'Before you agree, this app does not start its interface and does not transmit any data.\n'
    '\n'
    'With your consent, Microsoft Clarity (session analytics) collects de-identified\n'
    'interaction data — taps and navigation, device model, OS version, screen size and\n'
    'app version — and transfers it to servers outside the European Union.\n'
    '\n'
    'You may decline; the app will then close and no data will be uploaded.\n'
    'You can use the app without connect to the internet.\n';

/// Positive button label of the English dialog (ConsentActivity.java:122).
const String kEuConsentApprove = 'Agree';

/// Negative button label of the English dialog (ConsentActivity.java:126).
const String kEuConsentExit = 'Exit';

/// The two-button dialog a CN/EU run must answer (ConsentActivity.java:116-141).
class ConsentDialogCopy {
  const ConsentDialogCopy({
    required this.title,
    required this.message,
    required this.approveLabel,
    required this.exitLabel,
  });

  /// Dialog title (ConsentActivity.java:119).
  final String title;

  /// Dialog body (ConsentActivity.java:120).
  final String message;

  /// The only way to continue (ConsentActivity.java:122-125).
  final String approveLabel;

  /// The only way to leave (ConsentActivity.java:126).
  final String exitLabel;

  /// Copy for [region].
  ///
  /// Only CN and EU ever prompt, so any other region is a caller bug and throws
  /// (ConsentActivity.java:98-105).
  static ConsentDialogCopy forRegion(ConsentRegion region) => switch (region) {
    ConsentRegion.cn => cnConsentDialog,
    ConsentRegion.eu => euConsentDialog,
    ConsentRegion.other => throw ArgumentError.value(
      region,
      'region',
      'only CN and EU prompt (ConsentActivity.java:98-105)',
    ),
  };
}

/// Mainland-China dialog copy.
const ConsentDialogCopy cnConsentDialog = ConsentDialogCopy(
  title: kCnConsentTitle,
  message: kCnConsentMessage,
  approveLabel: kCnConsentApprove,
  exitLabel: kCnConsentExit,
);

/// European-Union dialog copy.
const ConsentDialogCopy euConsentDialog = ConsentDialogCopy(
  title: kEuConsentTitle,
  message: kEuConsentMessage,
  approveLabel: kEuConsentApprove,
  exitLabel: kEuConsentExit,
);

/// Host services the gate drives; the machine never builds a host object itself.
abstract interface class ConsentPorts {
  /// Reads the record: file "rhine-consent", keys "granted" and "region"
  /// (Qt ConsentStore.java:25-27, :49-63).
  ConsentRecord readRecord();

  /// ConsentStore.grant: writes granted=true and the region
  /// (Qt ConsentStore.java:66-71).
  void writeGrant(ConsentRegion region);

  /// The live region probe, which is never cached (Qt GeoIp.java:84-131). The
  /// gate gives it at most [kRegionProbeTimeoutMs] and turns both an error and a
  /// timeout into [ConsentRegion.other] (Qt ConsentActivity.java:76-92).
  Future<ConsentRegion> probeRegion();

  /// ConsentStore.startSdks(context, region) (Qt ConsentStore.java:79-109):
  /// Clarity on every allowed path, Bugly for CN only, idempotent per process.
  /// [ConsentSdkStarter] is the Qt-faithful implementation of that contract.
  void startSdks(ConsentRegion region);

  /// startActivity(QtActivity) + finish() (Qt ConsentActivity.java:152-155).
  ///
  /// The launch carries FLAG_ACTIVITY_CLEAR_TOP|SINGLE_TOP (:152-153), so a host
  /// that is asked again — [ConsentGate.approve] may retry it after a persisted
  /// grant — must still end on the one business screen instead of stacking a
  /// second one.
  void enterBusiness();

  /// finishAffinity() (Qt ConsentActivity.java:126).
  void exitApp();
}

/// Phases of the gate. Only [proceeded] means the business screen was entered;
/// nothing business-related and no SDK may run before it
/// (Qt ConsentActivity.java:22-23, :148-156).
enum ConsentPhase {
  /// Nothing has run yet; [ConsentGate.start] is the only way out.
  idle,

  /// The live region probe is in flight (ConsentActivity.java:76-107).
  probing,

  /// The consent dialog is up and must be answered by one of its two buttons
  /// (ConsentActivity.java:98-99, :116-141).
  awaitingConsent,

  /// proceed(region): the SDKs were started and the business screen entered
  /// (ConsentActivity.java:148-156).
  proceeded,

  /// finishAffinity(): the app exits and nothing else runs
  /// (ConsentActivity.java:126).
  declined,

  /// Process teardown.
  terminated,
}

/// Immutable reading of the gate, safe to hand to the UI layer.
class ConsentSnapshot {
  const ConsentSnapshot({
    required this.phase,
    required this.region,
    required this.recordPersisted,
    required this.regionProbeCount,
    required this.regionProbeTimeoutCount,
    required this.persistGrantCount,
    required this.sdkStartCount,
    required this.businessLaunchCount,
    required this.exitCount,
  });

  /// Current phase.
  final ConsentPhase phase;

  /// Region of this run: the stored one on a granted launch, the probe answer
  /// otherwise; null until something proceeded.
  final ConsentRegion? region;

  /// Whether a record with granted=true exists for this run, either read from
  /// disk or written by [ConsentGate.approve] (ConsentStore.java:53-55, :66-71).
  final bool recordPersisted;

  /// Region probes started; at most one per launch
  /// (ConsentActivity.java:69-107).
  final int regionProbeCount;

  /// Probes that hit the [kRegionProbeTimeoutMs] gate and resolved to
  /// [ConsentRegion.other] (ConsentActivity.java:86-87).
  final int regionProbeTimeoutCount;

  /// Records written (ConsentActivity.java:123).
  final int persistGrantCount;

  /// Times [ConsentPorts.startSdks] was invoked (ConsentActivity.java:149).
  final int sdkStartCount;

  /// Times [ConsentPorts.enterBusiness] was invoked
  /// (ConsentActivity.java:150-155).
  final int businessLaunchCount;

  /// Times [ConsentPorts.exitApp] was invoked (ConsentActivity.java:126).
  final int exitCount;

  /// True once the business screen was entered.
  bool get isProceeded => phase == ConsentPhase.proceeded;
}

/// Drives the consent gate over injected [ConsentPorts].
///
/// The whole point of the gate is ordering: a launch that is not allowed never
/// reaches [ConsentPorts.startSdks] or [ConsentPorts.enterBusiness]
/// (ConsentActivity.java:22-23).
class ConsentGate {
  /// Creates the gate in [ConsentPhase.idle].
  ConsentGate(this._ports);

  final ConsentPorts _ports;

  ConsentPhase _phase = ConsentPhase.idle;
  ConsentRegion? _region;
  ConsentRegion? _pendingRegion;

  /// True from the moment a button is answered until its port returned.
  ///
  /// A host port that calls back into [approve] or [decline] would otherwise
  /// answer the very decision the outer call is still recording — the nested
  /// grant would count twice, or a nested exit would be overwritten by the outer
  /// proceed. The Qt buttons cannot be pressed twice while their handler runs
  /// (ConsentActivity.java:122-126), so the machine refuses instead of guessing.
  bool _answering = false;
  bool _recordPersisted = false;
  int _regionProbeCount = 0;
  int _regionProbeTimeoutCount = 0;
  int _persistGrantCount = 0;
  int _sdkStartCount = 0;
  int _businessLaunchCount = 0;
  int _exitCount = 0;

  /// Current phase.
  ConsentPhase get phase => _phase;

  /// Region of the most recent proceed attempt, null before anything proceeded
  /// (ConsentActivity.java:69-70, :149-150). A proceed that throws keeps the
  /// region it was attempting, because that is the one the record was written
  /// for and the only one a retry may run.
  ConsentRegion? get region => _region;

  /// Whether the record on disk carries granted=true
  /// (ConsentStore.java:53-55).
  bool get recordPersisted => _recordPersisted;

  /// Region of the answer this gate is still holding for the dialog, null when
  /// it holds none (ConsentActivity.java:122-126).
  ///
  /// The decision only exists while the dialog is up, so the value is read from
  /// [ConsentPhase.awaitingConsent] and is null on every other phase: a gate that
  /// proceeded, declined or terminated is not waiting for a button. A page that
  /// restores the prompt after a port rejected an answer reads this instead of
  /// probing the region again, and pairs it with [recordPersisted] to know which
  /// question is still open — false means the write never happened and the dialog
  /// has to be asked again (:123), true means the grant is already on disk and
  /// re-answering only repeats the proceed (:124-:155).
  ConsentRegion? get pendingRegion =>
      _phase == ConsentPhase.awaitingConsent ? _pendingRegion : null;

  /// Region probes started (ConsentActivity.java:84-85).
  int get regionProbeCount => _regionProbeCount;

  /// Probes that fell back to [ConsentRegion.other] on the hard gate
  /// (ConsentActivity.java:86-89).
  int get regionProbeTimeoutCount => _regionProbeTimeoutCount;

  /// Records written by [approve] (ConsentActivity.java:123).
  int get persistGrantCount => _persistGrantCount;

  /// SDK start invocations (ConsentActivity.java:149).
  int get sdkStartCount => _sdkStartCount;

  /// Business-screen entries (ConsentActivity.java:150-155).
  int get businessLaunchCount => _businessLaunchCount;

  /// App exits (ConsentActivity.java:126).
  int get exitCount => _exitCount;

  /// Current immutable reading.
  ConsentSnapshot get snapshot => ConsentSnapshot(
    phase: _phase,
    region: _region,
    recordPersisted: _recordPersisted,
    regionProbeCount: _regionProbeCount,
    regionProbeTimeoutCount: _regionProbeTimeoutCount,
    persistGrantCount: _persistGrantCount,
    sdkStartCount: _sdkStartCount,
    businessLaunchCount: _businessLaunchCount,
    exitCount: _exitCount,
  );

  /// Qt ConsentActivity.onCreate (ConsentActivity.java:66-108).
  ///
  /// A granted record proceeds straight away and never probes the region
  /// (:69-72). Otherwise the region is resolved live behind the
  /// [kRegionProbeTimeoutMs] gate: CN and EU raise the dialog, anything else —
  /// including a timeout or a failed probe — proceeds without a prompt and
  /// without writing a record (:73-107).
  ///
  /// The gate runs once. A second call after the first decision is ignored, the
  /// way a second Activity instance would read the now-granted record; the
  /// process-scoped half of the idempotency (the SDK start flags) lives in
  /// [ConsentSdkStarter], mirroring the static fields of the Qt store.
  Future<void> start() async {
    if (_phase != ConsentPhase.idle) {
      return;
    }
    final ConsentRecord record = _ports.readRecord();
    if (record.granted) {
      _recordPersisted = true;
      _proceed(record.region);
      return;
    }
    _phase = ConsentPhase.probing;
    final ConsentRegion region = await _probeRegion();
    if (_phase != ConsentPhase.probing) {
      // The gate was finished or torn down while the probe ran, so the dialog is
      // never shown (ConsentActivity.java:95-97).
      return;
    }
    if (region == ConsentRegion.cn || region == ConsentRegion.eu) {
      _pendingRegion = region;
      _phase = ConsentPhase.awaitingConsent;
      return;
    }
    // Outside CN/EU, or nothing resolved within the budget: this run is allowed
    // without a prompt and without a stored marker, so the next launch decides
    // again (ConsentActivity.java:100-105).
    _proceed(region);
  }

  /// ConsentActivity.java:122-125 — the positive button.
  ///
  /// The record is written once, then the run proceeds; the order matters, the
  /// grant is on disk before any SDK starts (:123 before :124).
  ///
  /// The first answer consumes the pending decision before
  /// [ConsentPorts.writeGrant] runs, so a port that calls back into the gate
  /// finds no second answer to give — the nested call is refused by
  /// [_beginAnswer] instead of answering over this one, and the same latch
  /// refuses it on a retry over an already persisted grant. A write that throws
  /// persisted nothing, so the decision is put back before the error is
  /// rethrown: the phase, the region and every counter are then exactly what the
  /// dialog left behind, and both buttons keep their meaning — Agree retries and
  /// writes once, Exit still leaves without a record (:123, :126). Losing the
  /// decision on the way out instead would strand the gate in
  /// [ConsentPhase.awaitingConsent] with nothing left to write, which is a user
  /// who did agree and can never get in.
  ///
  /// Nothing is rolled back once [ConsentPorts.writeGrant] returned, and that
  /// record is not written a second time either. A port that throws afterwards —
  /// from [ConsentPorts.startSdks] or [ConsentPorts.enterBusiness] inside
  /// [_proceed] — leaves the grant on disk, which is the truth: the user did
  /// agree and the record is written (ConsentStore.java:66-71 publishes
  /// granted=true in the store before anything else can fail). Qt has no
  /// recovery inside that process either; the throw escapes the click handler
  /// (:122-125, :149-155) and the next launch reads isGranted and proceeds
  /// without a dialog (:69-72). This gate cannot relaunch, so it keeps the same
  /// record here: the decision is put back and [pendingRegion] still names the
  /// region that was agreed, the phase stays [ConsentPhase.awaitingConsent], and
  /// the retried Agree skips [ConsentPorts.writeGrant] and repeats only the
  /// proceed — the one part a relaunched process would have run again. Every
  /// other counter keeps counting invocations, as it does on the first attempt.
  void approve() {
    _require(ConsentPhase.awaitingConsent, 'approve');
    _beginAnswer('approve');
    try {
      final ConsentRegion region = _pendingRegion!;
      if (!_recordPersisted) {
        _pendingRegion = null;
        try {
          _ports.writeGrant(region);
        } catch (_) {
          // Nothing was persisted and no SDK, no business screen and no counter
          // ran ahead of the record, so the only state to repair is the answer
          // itself — and only while the gate is still waiting for it, so a port
          // that already moved the machine on is not given a stale decision back.
          if (_phase == ConsentPhase.awaitingConsent) {
            _pendingRegion = region;
          }
          rethrow;
        }
        _persistGrantCount += 1;
        _recordPersisted = true;
      }
      try {
        _proceed(region);
      } catch (_) {
        // The record is on disk and the run did not finish, so the decision this
        // gate owes the user is not spent: it comes back for the retry above,
        // where the persisted grant is not written again. Only a gate still
        // waiting for an answer is given it back, so a port that already moved
        // the machine on keeps its own phase.
        if (_phase == ConsentPhase.awaitingConsent) {
          _pendingRegion = region;
        }
        rethrow;
      }
      _pendingRegion = null;
    } finally {
      _answering = false;
    }
  }

  /// ConsentActivity.java:126 — the negative button calls finishAffinity().
  ///
  /// Nothing else happens on this path: no record is written and no business or
  /// SDK port runs.
  ///
  /// Like [approve] it refuses to answer a second time from inside itself, and it
  /// drops its latch before handing over to [ConsentPorts.exitApp]: a first
  /// press that has already decided is not re-answerable, but the finishing host
  /// is not left holding a gate that still claims to be mid-answer either.
  void decline() {
    _require(ConsentPhase.awaitingConsent, 'decline');
    _beginAnswer('decline');
    _pendingRegion = null;
    _phase = ConsentPhase.declined;
    _exitCount += 1;
    _answering = false;
    _ports.exitApp();
  }

  /// ConsentActivity.java:158-164.
  ///
  /// While the dialog is up — and while the region is still being resolved — the
  /// back key is swallowed; the only ways out are the two buttons (:163). Once a
  /// grant is on disk the key goes back to the host's own handling (:159-162); a
  /// launch that proceeded without a record keeps it swallowed, exactly as
  /// ConsentStore.isGranted reads false there (:160).
  ///
  /// Returns true when the host should run its default back handling.
  bool backPressed() {
    if (!_recordPersisted) {
      return false;
    }
    return true;
  }

  /// Process teardown; the Qt gate holds no state past finish()/finishAffinity()
  /// (ConsentActivity.java:155, :126).
  void terminate() {
    if (_phase == ConsentPhase.terminated) {
      return;
    }
    _phase = ConsentPhase.terminated;
  }

  /// The one path into the business screen (ConsentActivity.java:148-156): SDKs
  /// first (:149), then the Qt Activity (:152-155).
  void _proceed(ConsentRegion region) {
    _region = region;
    _sdkStartCount += 1;
    _ports.startSdks(region);
    _businessLaunchCount += 1;
    _ports.enterBusiness();
    _phase = ConsentPhase.proceeded;
  }

  /// The hard gate of ConsentActivity.java:73-107: the probe runs behind a
  /// single-shot timeout, and a failure becomes [ConsentRegion.other] as well
  /// (:77, :86-89), so the start-up page can never stall on the network.
  Future<ConsentRegion> _probeRegion() {
    _regionProbeCount += 1;
    final Completer<ConsentRegion> decision = Completer<ConsentRegion>();
    final Timer timeout = Timer(Duration(milliseconds: kRegionProbeTimeoutMs), () {
      if (decision.isCompleted) {
        return;
      }
      _regionProbeTimeoutCount += 1;
      decision.complete(ConsentRegion.other);
    });
    unawaited(
      _guardedProbe()
          .then((ConsentRegion region) {
            if (!decision.isCompleted) {
              decision.complete(region);
            }
          })
          .whenComplete(timeout.cancel),
    );
    return decision.future;
  }

  /// A probe that fails is "undetermined", which the Qt code treats as the other
  /// region (ConsentActivity.java:88-89, GeoIp.java:129-131).
  Future<ConsentRegion> _guardedProbe() async {
    try {
      return await _ports.probeRegion();
    } catch (_) {
      return ConsentRegion.other;
    }
  }

  /// Takes the answer latch, refusing a call that arrives from inside another
  /// answer's port ([approve]/[decline] release it in a finally).
  void _beginAnswer(String event) {
    if (_answering) {
      throw StateError(
        event +
            ' is already being answered by the port it called; '
            'the gate answers one decision at a time',
      );
    }
    _answering = true;
  }

  void _require(ConsentPhase expected, String event) {
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
}

/// ConsentStore.startSdks (Qt ConsentStore.java:79-109) with the two
/// process-scoped start flags of :43-44.
///
/// Clarity is started on every allowed path (:81-93); Bugly only when the run
/// resolved to mainland China (:94-96). Both initializations swallow their own
/// failure — an analytics SDK that cannot start must not take the app down
/// (:89-92, :105-108) — and both flags are set *before* the call, exactly like
/// the Qt fields, so a failing SDK is not retried on every wake-up (:82, :97).
///
/// The flags are deliberately separate (:41-42): a process that first ran as
/// "other region" (Clarity only) can still start Bugly when a CN consent arrives
/// later, which one shared flag would block.
class ConsentSdkStarter {
  ConsentSdkStarter({
    required this.initializeClarity,
    required this.initializeBugly,
    this.onFailure,
  });

  /// Clarity.initialize(application, config) (Qt ConsentStore.java:84-87); the
  /// argument is [ConsentSdkConfig.clarityProjectId].
  final void Function(String projectId) initializeClarity;

  /// CrashReport.initCrashReport(context, appId, debug, strategy)
  /// (Qt ConsentStore.java:99-103); the strategy carries the native crash
  /// monitor flag set at :39 and used at :100.
  final void Function(String appId, bool debug, bool nativeMonitor)
  initializeBugly;

  /// Where a swallowed initialization failure is reported — the Qt code logs it
  /// (ConsentStore.java:89-92, :105-108); null drops it.
  final void Function(Object error)? onFailure;

  bool _clarityStarted = false;
  bool _buglyStarted = false;

  /// Successful Clarity initializations; stays <= 1
  /// (Qt ConsentStore.java:81-93).
  int clarityStartCount = 0;

  /// Successful Bugly initializations; stays <= 1 and is 0 outside CN
  /// (Qt ConsentStore.java:94-108).
  int buglyStartCount = 0;

  /// Initializations that threw and were swallowed
  /// (Qt ConsentStore.java:89-92, :105-108).
  int failureCount = 0;

  /// Whether Clarity was already started (Qt ConsentStore.java:43).
  bool get clarityStarted => _clarityStarted;

  /// Whether Bugly was already started (Qt ConsentStore.java:44).
  bool get buglyStarted => _buglyStarted;

  /// ConsentStore.startSdks(context, region) (Qt ConsentStore.java:79-109).
  void startSdks(ConsentRegion region) {
    if (!_clarityStarted) {
      _clarityStarted = true;
      try {
        initializeClarity(ConsentSdkConfig.clarityProjectId);
        clarityStartCount += 1;
      } catch (error) {
        _fail(error);
      }
    }
    if (region != ConsentRegion.cn || _buglyStarted) {
      return;
    }
    _buglyStarted = true;
    try {
      initializeBugly(
        ConsentSdkConfig.buglyAppId,
        ConsentSdkConfig.buglyDebug,
        ConsentSdkConfig.buglyNativeMonitor,
      );
      buglyStartCount += 1;
    } catch (error) {
      _fail(error);
    }
  }

  /// ConsentStore.startSdks(context) (Qt ConsentStore.java:111-114): a
  /// background wake has no Activity, so the region comes from the record and an
  /// ungranted process wakes as [ConsentRegion.other].
  ///
  /// NOTE — Qt inconsistency kept as-is, because the code is the contract: with
  /// no grant this still starts Clarity, while the class comment of
  /// ConsentStore.java:15-18 reads the other way ("没有同意记录就不启动 SDK").
  /// Flagged for the parent rather than silently changed.
  void startSdksForBackgroundWake(ConsentRecord record) {
    startSdks(record.granted ? record.region : ConsentRegion.other);
  }

  void _fail(Object error) {
    failureCount += 1;
    onFailure?.call(error);
  }
}
