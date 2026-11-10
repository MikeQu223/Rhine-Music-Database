// Tests for the start-up consent gate (plan T27, slice S01).
//
// Every Qt line quoted here points at
// Qt/android/src/rhine/music/database/ConsentActivity.java,
// Qt/android/src/rhine/music/database/ConsentStore.java or
// Qt/android/src/rhine/music/database/GeoIp.java.
//
// These tests are written but NOT run in this worktree: the atom forbids
// flutter test, dart test and every verification script, so RED/GREEN are
// unknown and are reported as not executed.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/app/consent_gate.dart';

/// SDK call event of Clarity, id included (ConsentStore.java:28).
const String _clarityEvent = 'clarity:z8vbz4b078';

/// SDK call event of Bugly, id and flags included (ConsentStore.java:31-32, :39).
const String _buglyEvent = 'bugly:22c01c69b9:false:true';

/// Ordered traffic of a run: the injected ports append their own events and the
/// real [ConsentSdkStarter] appends its SDK calls to the same list, so the tests
/// exercise the shipped idempotency instead of a stub and still read the whole
/// order in a single assertion.
class _Recorder {
  final List<String> events = <String>[];
  final List<Object> failures = <Object>[];

  late final ConsentSdkStarter starter = ConsentSdkStarter(
    initializeClarity: (String projectId) => events.add('clarity:$projectId'),
    initializeBugly: (String appId, bool debug, bool nativeMonitor) =>
        events.add('bugly:$appId:$debug:$nativeMonitor'),
    onFailure: failures.add,
  );

  int get clarityStarts =>
      events.where((String event) => event.startsWith('clarity:')).length;

  int get buglyStarts =>
      events.where((String event) => event.startsWith('bugly:')).length;
}

/// Host stand-in that records every call the gate makes.
class _FakeConsentPorts implements ConsentPorts {
  _FakeConsentPorts({
    ConsentRecord record = const ConsentRecord.empty(),
    Future<ConsentRegion>? probe,
    this.grantFailures = 0,
  }) : _record = record,
       _probe = probe;

  final _Recorder recorder = _Recorder();
  ConsentRecord _record;
  final Future<ConsentRegion>? _probe;

  /// How many of the next [writeGrant] calls fail instead of persisting; the
  /// host stand-in for an unwritable preference file. Zero leaves the fake
  /// exactly as the happy-path tests expect it.
  int grantFailures;

  /// Runs at the end of a successful [writeGrant] that this fake persisted, so a
  /// test can re-enter the gate from inside its own port call.
  void Function(ConsentRegion region)? onGrant;

  /// Everything the gate asked the host to do, in order.
  List<String> get events => recorder.events;

  final List<ConsentRegion> grantWrites = <ConsentRegion>[];
  int probeCalls = 0;
  int businessLaunches = 0;
  int exits = 0;

  /// Completer of a probe that never resolves by itself; a test can finish it
  /// late to prove a stale answer changes nothing.
  Completer<ConsentRegion>? pendingProbe;

  @override
  ConsentRecord readRecord() => _record;

  @override
  void writeGrant(ConsentRegion region) {
    if (grantFailures > 0) {
      grantFailures -= 1;
      // Nothing is persisted here: no record, no [grantWrites] entry and no
      // [onGrant]. The gate's own counters staying put is asserted by the
      // unwritable-record group, which this fake cannot check itself.
      events.add('grantFailed:${region.name}');
      throw StateError('rhine-consent is not writable');
    }
    events.add('grant:${region.name}');
    grantWrites.add(region);
    _record = ConsentRecord(granted: true, region: region);
    onGrant?.call(region);
  }

  @override
  Future<ConsentRegion> probeRegion() {
    probeCalls += 1;
    final Future<ConsentRegion>? probe = _probe;
    if (probe != null) {
      return probe;
    }
    final Completer<ConsentRegion> pending = Completer<ConsentRegion>();
    pendingProbe = pending;
    return pending.future;
  }

  @override
  void startSdks(ConsentRegion region) {
    events.add('sdkStart:${region.name}');
    recorder.starter.startSdks(region);
  }

  @override
  void enterBusiness() {
    events.add('business');
    businessLaunches += 1;
  }

  @override
  void exitApp() {
    events.add('exit');
    exits += 1;
  }
}

/// Runs [body] and returns what it threw, so a re-entrant call made from inside
/// a port can be inspected instead of unwinding the port itself.
Object _captured(void Function() body) {
  try {
    body();
  } catch (error) {
    return error;
  }
  return 'no throw';
}

/// Flushes the microtask tail of a probe that resolves on its own (two pumps,
/// so the `.then(...).whenComplete(...)` chain is drained too).
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  group('evidence (GeoIp.java:39-51, ConsentStore.java:25-39)', () {
    test('region wire values, the sentinel and the probe budget', () {
      expect(ConsentRegion.cn.wire, 1);
      expect(ConsentRegion.eu.wire, 2);
      expect(ConsentRegion.other.wire, 3);
      expect(kRegionNoneWire, 0);
      expect(kRegionProbeTimeoutMs, 3000);

      // A table miss (GeoIp.java:39-40, :133-143) and any unknown payload decode
      // to the region that cannot prompt anyone by accident.
      expect(ConsentRegion.fromWire(kRegionNoneWire), ConsentRegion.other);
      expect(ConsentRegion.fromWire(1), ConsentRegion.cn);
      expect(ConsentRegion.fromWire(2), ConsentRegion.eu);
      expect(ConsentRegion.fromWire(3), ConsentRegion.other);
      expect(ConsentRegion.fromWire(99), ConsentRegion.other);
    });

    test('record file and keys are the Qt strings', () {
      expect(ConsentRecordKeys.file, 'rhine-consent');
      expect(ConsentRecordKeys.granted, 'granted');
      expect(ConsentRecordKeys.region, 'region');

      const ConsentRecord empty = ConsentRecord.empty();
      expect(empty.granted, isFalse);
      expect(empty.region, ConsentRegion.other);
    });

    test('the SDK ids and switches are the Qt constants', () {
      expect(ConsentSdkConfig.clarityProjectId, 'z8vbz4b078');
      expect(ConsentSdkConfig.buglyAppId, '22c01c69b9');
      expect(ConsentSdkConfig.buglyDebug, isFalse);
      expect(ConsentSdkConfig.buglyNativeMonitor, isTrue);
    });

    test('the dialog text is the Java text block, verbatim', () {
      expect(kCnConsentTitle, '隐私与数据传输许可');
      expect(kCnConsentApprove, '同意');
      expect(kCnConsentExit, '退出');
      expect(kEuConsentTitle, 'Data Transfer Consent');
      expect(kEuConsentApprove, 'Agree');
      expect(kEuConsentExit, 'Exit');

      expect(
        kCnConsentMessage,
        startsWith('以下第三方 SDK 会处理必要的信息：\n\n1.Microsoft Clarity\n'),
      );
      expect(kCnConsentMessage, contains('\n  服务提供：腾讯\n'));
      expect(
        kCnConsentMessage,
        contains(
          '\n  隐私政策：https://privacy.qq.com/document/preview/'
          'fc748b3d96224fdb825ea79e132c1a56\n',
        ),
      );
      expect(
        kCnConsentMessage,
        endsWith('仅适用于中国大陆联网使用。无互联网连接时将不会使用这些服务。\n'),
      );
      // ConsentActivity.java:37-50 is 14 lines and a Java text block keeps every
      // line terminator, the last one before the closing delimiter included.
      expect('\n'.allMatches(kCnConsentMessage).length, 14);

      expect(
        kEuConsentMessage,
        startsWith(
          'Before you agree, this app does not start its interface and does '
          'not transmit any data.\n\n',
        ),
      );
      expect(
        kEuConsentMessage,
        endsWith('You can use the app without connect to the internet.\n'),
      );
      // ConsentActivity.java:54-61 is 8 lines.
      expect('\n'.allMatches(kEuConsentMessage).length, 8);

      expect(
        ConsentDialogCopy.forRegion(ConsentRegion.cn).title,
        kCnConsentTitle,
      );
      expect(
        ConsentDialogCopy.forRegion(ConsentRegion.cn).message,
        kCnConsentMessage,
      );
      expect(
        ConsentDialogCopy.forRegion(ConsentRegion.cn).approveLabel,
        kCnConsentApprove,
      );
      expect(ConsentDialogCopy.forRegion(ConsentRegion.eu).title, kEuConsentTitle);
      expect(
        ConsentDialogCopy.forRegion(ConsentRegion.eu).message,
        kEuConsentMessage,
      );
      expect(
        ConsentDialogCopy.forRegion(ConsentRegion.eu).exitLabel,
        kEuConsentExit,
      );
      expect(
        () => ConsentDialogCopy.forRegion(ConsentRegion.other),
        throwsArgumentError,
        reason: 'ConsentActivity.java:98-105 prompts for CN and EU only',
      );
    });
  });

  group('launch decisions (ConsentActivity.java:66-108)', () {
    testWidgets('a granted record proceeds with its stored region and never probes', (
      WidgetTester tester,
    ) async {
      final _FakeConsentPorts ports = _FakeConsentPorts(
        record: const ConsentRecord(granted: true, region: ConsentRegion.cn),
      );
      final ConsentGate gate = ConsentGate(ports);

      await gate.start();

      expect(gate.phase, ConsentPhase.proceeded);
      expect(gate.region, ConsentRegion.cn);
      expect(gate.recordPersisted, isTrue);
      expect(
        ports.probeCalls,
        0,
        reason: 'ConsentActivity.java:69-72 does not resolve the region again',
      );
      expect(gate.regionProbeCount, 0);
      expect(ports.grantWrites, isEmpty);
      expect(gate.persistGrantCount, 0);
      expect(
        ports.events,
        <String>['sdkStart:cn', _clarityEvent, _buglyEvent, 'business'],
        reason:
            'startSdks (ConsentActivity.java:149) precedes the business '
            'screen (:152-155)',
      );
      expect(ports.recorder.clarityStarts, 1);
      expect(
        ports.recorder.buglyStarts,
        1,
        reason: 'the stored region is CN (ConsentStore.java:94-96)',
      );
      expect(ports.businessLaunches, 1);
      expect(
        gate.backPressed(),
        isTrue,
        reason: 'a granted run hands the key back (ConsentActivity.java:159-162)',
      );
    });

    testWidgets('CN keeps the dialog in front of every port until approval', (
      WidgetTester tester,
    ) async {
      final _FakeConsentPorts ports = _FakeConsentPorts(
        probe: Future<ConsentRegion>.value(ConsentRegion.cn),
      );
      final ConsentGate gate = ConsentGate(ports);

      final Future<void> run = gate.start();
      await _settle(tester);

      expect(gate.phase, ConsentPhase.awaitingConsent);
      expect(gate.regionProbeCount, 1);
      expect(ports.probeCalls, 1);
      expect(gate.sdkStartCount, 0, reason: 'no SDK while the dialog is up');
      expect(gate.businessLaunchCount, 0);
      expect(ports.events, isEmpty);

      expect(
        gate.backPressed(),
        isFalse,
        reason: 'ConsentActivity.java:163 swallows the key before consent',
      );
      expect(ports.events, isEmpty);

      gate.approve();

      expect(gate.phase, ConsentPhase.proceeded);
      expect(ports.grantWrites, <ConsentRegion>[ConsentRegion.cn]);
      expect(gate.persistGrantCount, 1);
      expect(gate.region, ConsentRegion.cn);
      expect(
        ports.events,
        <String>['grant:cn', 'sdkStart:cn', _clarityEvent, _buglyEvent, 'business'],
        reason:
            'the record is written (ConsentActivity.java:123) before proceed '
            '(:124) and before the SDKs start (:149)',
      );
      expect(ports.recorder.clarityStarts, 1);
      expect(ports.recorder.buglyStarts, 1);
      expect(ports.businessLaunches, 1);
      expect(gate.backPressed(), isTrue);

      await run;
    });

    testWidgets('EU approval starts Clarity only', (WidgetTester tester) async {
      final _FakeConsentPorts ports = _FakeConsentPorts(
        probe: Future<ConsentRegion>.value(ConsentRegion.eu),
      );
      final ConsentGate gate = ConsentGate(ports);

      final Future<void> run = gate.start();
      await _settle(tester);

      expect(gate.phase, ConsentPhase.awaitingConsent);
      expect(ports.events, isEmpty);

      gate.approve();

      expect(gate.region, ConsentRegion.eu);
      expect(
        ports.events,
        <String>['grant:eu', 'sdkStart:eu', _clarityEvent, 'business'],
      );
      expect(
        ports.recorder.buglyStarts,
        0,
        reason: 'ConsentStore.java:94 starts Bugly for CN only',
      );
      expect(ports.recorder.clarityStarts, 1);

      await run;
    });

    testWidgets('another region proceeds with no prompt, no record, Clarity only', (
      WidgetTester tester,
    ) async {
      final _FakeConsentPorts ports = _FakeConsentPorts(
        probe: Future<ConsentRegion>.value(ConsentRegion.other),
      );
      final ConsentGate gate = ConsentGate(ports);

      final Future<void> run = gate.start();
      await _settle(tester);

      expect(
        gate.phase,
        ConsentPhase.proceeded,
        reason: 'ConsentActivity.java:100-105 proceeds without a dialog',
      );
      expect(gate.recordPersisted, isFalse);
      expect(gate.persistGrantCount, 0);
      expect(ports.grantWrites, isEmpty);
      expect(gate.region, ConsentRegion.other);
      expect(gate.regionProbeTimeoutCount, 0);
      expect(ports.events, <String>['sdkStart:other', _clarityEvent, 'business']);
      expect(ports.recorder.buglyStarts, 0);
      expect(
        gate.backPressed(),
        isFalse,
        reason:
            'ConsentStore.isGranted is false on this path '
            '(ConsentActivity.java:160)',
      );

      await run;
    });

    testWidgets('an unresolved probe times out into other, and a late CN answer '
        'changes nothing', (WidgetTester tester) async {
      final _FakeConsentPorts ports = _FakeConsentPorts();
      final ConsentGate gate = ConsentGate(ports);

      final Future<void> run = gate.start();
      await tester.pump();

      expect(gate.phase, ConsentPhase.probing);
      expect(gate.regionProbeCount, 1);
      expect(gate.sdkStartCount, 0);
      expect(gate.businessLaunchCount, 0);
      expect(
        ports.events,
        isEmpty,
        reason: 'nothing runs while the region is still unknown',
      );

      await tester.pump(const Duration(milliseconds: kRegionProbeTimeoutMs));
      await run;

      expect(gate.phase, ConsentPhase.proceeded);
      expect(
        gate.regionProbeTimeoutCount,
        1,
        reason: 'ConsentActivity.java:86-87 treats the timeout as other',
      );
      expect(gate.region, ConsentRegion.other);
      expect(
        gate.persistGrantCount,
        0,
        reason: 'a timeout never writes a record (ConsentActivity.java:101-104)',
      );
      expect(ports.events, <String>['sdkStart:other', _clarityEvent, 'business']);

      ports.pendingProbe!.complete(ConsentRegion.cn);
      await _settle(tester);

      expect(gate.phase, ConsentPhase.proceeded);
      expect(
        gate.businessLaunchCount,
        1,
        reason: 'a stale answer must not re-enter the business screen',
      );
      expect(gate.sdkStartCount, 1);
      expect(ports.events, <String>['sdkStart:other', _clarityEvent, 'business']);
      expect(
        gate.approve,
        throwsStateError,
        reason: 'approval is only valid from the dialog (ConsentActivity.java:122)',
      );
    });

    testWidgets('a gate torn down while probing never prompts and never proceeds', (
      WidgetTester tester,
    ) async {
      final _FakeConsentPorts ports = _FakeConsentPorts();
      final ConsentGate gate = ConsentGate(ports);

      final Future<void> run = gate.start();
      await tester.pump();
      expect(gate.phase, ConsentPhase.probing);

      gate.terminate();
      expect(gate.phase, ConsentPhase.terminated);

      await tester.pump(const Duration(milliseconds: kRegionProbeTimeoutMs));
      await run;

      expect(
        gate.phase,
        ConsentPhase.terminated,
        reason:
            'ConsentActivity.java:95-97 shows nothing once the Activity is '
            'finishing or destroyed',
      );
      expect(ports.events, isEmpty);
      expect(ports.businessLaunches, 0);
      expect(gate.businessLaunchCount, 0);
      expect(gate.exitCount, 0);
    });
  });

  group('decline (ConsentActivity.java:126)', () {
    testWidgets('exit leaves nothing running and blocks every later approval', (
      WidgetTester tester,
    ) async {
      final _FakeConsentPorts ports = _FakeConsentPorts(
        probe: Future<ConsentRegion>.value(ConsentRegion.cn),
      );
      final ConsentGate gate = ConsentGate(ports);

      final Future<void> run = gate.start();
      await _settle(tester);
      expect(gate.phase, ConsentPhase.awaitingConsent);

      gate.decline();

      expect(gate.phase, ConsentPhase.declined);
      expect(gate.exitCount, 1);
      expect(ports.exits, 1);
      expect(gate.persistGrantCount, 0);
      expect(ports.grantWrites, isEmpty);
      expect(gate.sdkStartCount, 0);
      expect(gate.businessLaunchCount, 0);
      expect(
        ports.events,
        <String>['exit'],
        reason: 'finishAffinity() is the whole path (ConsentActivity.java:126)',
      );

      expect(gate.approve, throwsStateError);
      expect(gate.decline, throwsStateError);

      // A later start() is a no-op, exactly because the Qt Activity is gone.
      final Future<void> again = gate.start();
      await again;

      expect(gate.phase, ConsentPhase.declined);
      expect(ports.businessLaunches, 0);
      expect(ports.events, <String>['exit']);

      await run;
    });
  });

  group('an answer is taken once (ConsentActivity.java:122-126)', () {
    testWidgets('a port that answers the gate again is refused, and the first '
        'answer is the only one', (WidgetTester tester) async {
      final _FakeConsentPorts ports = _FakeConsentPorts(
        probe: Future<ConsentRegion>.value(ConsentRegion.cn),
      );
      final ConsentGate gate = ConsentGate(ports);
      final List<Object> refusals = <Object>[];
      ports.onGrant = (ConsentRegion region) {
        // The host re-enters the gate from inside the first answer: neither
        // button may answer the same decision a second time.
        refusals.add(_captured(() => gate.approve()));
        refusals.add(_captured(() => gate.decline()));
      };

      final Future<void> run = gate.start();
      await _settle(tester);
      expect(gate.phase, ConsentPhase.awaitingConsent);

      gate.approve();

      expect(refusals.length, 2);
      expect(refusals[0], isA<StateError>());
      expect(refusals[1], isA<StateError>());
      expect(
        ports.grantWrites,
        <ConsentRegion>[ConsentRegion.cn],
        reason: 'the nested Agree must not write a second record',
      );
      expect(gate.persistGrantCount, 1);
      expect(gate.exitCount, 0, reason: 'the nested Exit must not run');
      expect(ports.exits, 0);
      expect(gate.phase, ConsentPhase.proceeded);
      expect(gate.region, ConsentRegion.cn);
      expect(ports.businessLaunches, 1);
      expect(
        ports.events,
        <String>['grant:cn', 'sdkStart:cn', _clarityEvent, _buglyEvent, 'business'],
        reason: 'one press, one record, one SDK start, one business screen',
      );

      await run;
    });

    testWidgets('a port that refuses the record releases the latch, so the '
        'retried Agree writes once and proceeds once', (WidgetTester tester) async {
      final _FakeConsentPorts ports = _FakeConsentPorts(
        probe: Future<ConsentRegion>.value(ConsentRegion.eu),
        grantFailures: 1,
      );
      final ConsentGate gate = ConsentGate(ports);
      final List<Object> refusals = <Object>[];
      ports.onGrant = (ConsentRegion region) {
        // Only the retry reaches this: the refused press never persisted, so a
        // nested answer here proves that press released the latch.
        refusals.add(_captured(() => gate.approve()));
        refusals.add(_captured(() => gate.decline()));
      };

      final Future<void> run = gate.start();
      await _settle(tester);

      expect(
        gate.approve,
        throwsStateError,
        reason: 'the port refused the record',
      );
      expect(gate.phase, ConsentPhase.awaitingConsent);
      expect(gate.persistGrantCount, 0);
      expect(ports.grantWrites, isEmpty);

      gate.approve();

      expect(refusals.length, 2);
      expect(refusals[0], isA<StateError>());
      expect(refusals[1], isA<StateError>());
      expect(ports.grantWrites, <ConsentRegion>[ConsentRegion.eu]);
      expect(gate.persistGrantCount, 1);
      expect(gate.exitCount, 0);
      expect(gate.phase, ConsentPhase.proceeded);
      expect(gate.region, ConsentRegion.eu);
      expect(ports.businessLaunches, 1);
      expect(
        ports.events,
        <String>['grantFailed:eu', 'grant:eu', 'sdkStart:eu', _clarityEvent, 'business'],
        reason: 'a refused write is retried once, never counted as a grant',
      );

      await run;
    });
  });

  group('unwritable grant record (ConsentActivity.java:122-125)', () {
    testWidgets(
      'a failed write leaves the dialog answerable, and the retried Agree '
      'writes once and proceeds once',
      (WidgetTester tester) async {
        final _FakeConsentPorts ports = _FakeConsentPorts(
          probe: Future<ConsentRegion>.value(ConsentRegion.cn),
          grantFailures: 1,
        );
        final ConsentGate gate = ConsentGate(ports);

        final Future<void> run = gate.start();
        await _settle(tester);
        expect(gate.phase, ConsentPhase.awaitingConsent);

        expect(
          gate.approve,
          throwsStateError,
          reason: 'the port could not write the record',
        );

        expect(
          gate.phase,
          ConsentPhase.awaitingConsent,
          reason: 'a failed write is not an answer, so the dialog is still up',
        );
        expect(gate.recordPersisted, isFalse);
        expect(gate.persistGrantCount, 0);
        expect(gate.region, isNull);
        expect(gate.sdkStartCount, 0);
        expect(gate.businessLaunchCount, 0);
        expect(gate.exitCount, 0);
        expect(ports.grantWrites, isEmpty);
        expect(
          ports.events,
          <String>['grantFailed:cn'],
          reason:
              'nothing but the refused write ran (ConsentActivity.java:123 '
              'precedes :124 and :149)',
        );
        expect(
          gate.backPressed(),
          isFalse,
          reason: 'no record on disk, so the key stays swallowed (:160-163)',
        );

        gate.approve();

        expect(gate.phase, ConsentPhase.proceeded);
        expect(ports.grantWrites, <ConsentRegion>[ConsentRegion.cn]);
        expect(gate.persistGrantCount, 1);
        expect(gate.recordPersisted, isTrue);
        expect(gate.region, ConsentRegion.cn);
        expect(
          ports.events,
          <String>[
            'grantFailed:cn',
            'grant:cn',
            'sdkStart:cn',
            _clarityEvent,
            _buglyEvent,
            'business',
          ],
          reason: 'the retry persists exactly once and then follows :123-:124',
        );
        expect(ports.recorder.clarityStarts, 1);
        expect(ports.recorder.buglyStarts, 1);
        expect(ports.businessLaunches, 1);
        expect(gate.backPressed(), isTrue);
        expect(gate.approve, throwsStateError);

        await run;
      },
    );

    testWidgets('Exit still works after a failed write', (
      WidgetTester tester,
    ) async {
      final _FakeConsentPorts ports = _FakeConsentPorts(
        probe: Future<ConsentRegion>.value(ConsentRegion.cn),
        grantFailures: 1,
      );
      final ConsentGate gate = ConsentGate(ports);

      final Future<void> run = gate.start();
      await _settle(tester);
      expect(gate.phase, ConsentPhase.awaitingConsent);
      expect(gate.approve, throwsStateError);
      expect(gate.phase, ConsentPhase.awaitingConsent);

      gate.decline();

      expect(gate.phase, ConsentPhase.declined);
      expect(gate.exitCount, 1);
      expect(ports.exits, 1);
      expect(gate.persistGrantCount, 0);
      expect(ports.grantWrites, isEmpty);
      expect(
        ports.events,
        <String>['grantFailed:cn', 'exit'],
        reason: 'finishAffinity() is the whole path (ConsentActivity.java:126)',
      );
      expect(gate.approve, throwsStateError);
      expect(gate.sdkStartCount, 0);
      expect(gate.businessLaunchCount, 0);

      await run;
    });
  });

  group('gate idempotency', () {
    testWidgets('a second start() and a later approval add nothing', (
      WidgetTester tester,
    ) async {
      final _FakeConsentPorts ports = _FakeConsentPorts(
        record: const ConsentRecord(granted: true, region: ConsentRegion.cn),
      );
      final ConsentGate gate = ConsentGate(ports);

      await gate.start();
      expect(
        ports.events,
        <String>['sdkStart:cn', _clarityEvent, _buglyEvent, 'business'],
      );

      await gate.start();

      expect(gate.phase, ConsentPhase.proceeded);
      expect(ports.probeCalls, 0);
      expect(gate.sdkStartCount, 1);
      expect(ports.businessLaunches, 1);
      expect(
        ports.events,
        <String>['sdkStart:cn', _clarityEvent, _buglyEvent, 'business'],
      );
      expect(gate.approve, throwsStateError);
      expect(gate.persistGrantCount, 0);
    });
  });

  group('SDK start gate (ConsentStore.java:41-44, :79-114)', () {
    test('Clarity starts once on every allowed path, Bugly only for CN', () {
      final _Recorder recorder = _Recorder();

      recorder.starter.startSdks(ConsentRegion.other);
      recorder.starter.startSdks(ConsentRegion.eu);

      expect(
        recorder.events,
        <String>[_clarityEvent],
        reason: 'Clarity is the only SDK outside CN (ConsentStore.java:81-96)',
      );
      expect(recorder.starter.clarityStartCount, 1);
      expect(recorder.starter.buglyStartCount, 0);

      recorder.starter.startSdks(ConsentRegion.cn);

      expect(
        recorder.events,
        <String>[_clarityEvent, _buglyEvent],
        reason:
            'the two flags are separate, so a later CN consent still starts '
            'Bugly (ConsentStore.java:41-42)',
      );
      expect(recorder.starter.clarityStarted, isTrue);
      expect(recorder.starter.buglyStarted, isTrue);

      recorder.starter.startSdks(ConsentRegion.cn);

      expect(
        recorder.events,
        <String>[_clarityEvent, _buglyEvent],
        reason: 'each SDK starts at most once per process (ConsentStore.java:43-44)',
      );
      expect(recorder.starter.clarityStartCount, 1);
      expect(recorder.starter.buglyStartCount, 1);
    });

    test('a background wake takes the region from the record', () {
      final _Recorder ungranted = _Recorder();
      ungranted.starter.startSdksForBackgroundWake(const ConsentRecord.empty());
      expect(
        ungranted.events,
        <String>[_clarityEvent],
        reason: 'ConsentStore.java:111-114 falls back to other, so no Bugly',
      );

      final _Recorder granted = _Recorder();
      granted.starter.startSdksForBackgroundWake(
        const ConsentRecord(granted: true, region: ConsentRegion.cn),
      );
      expect(granted.events, <String>[_clarityEvent, _buglyEvent]);
    });

    test('a failing initialization is swallowed and never retried', () {
      final List<Object> failures = <Object>[];
      int clarityAttempts = 0;
      final ConsentSdkStarter starter = ConsentSdkStarter(
        initializeClarity: (String projectId) {
          clarityAttempts += 1;
          throw StateError('clarity is down');
        },
        initializeBugly: (String appId, bool debug, bool nativeMonitor) =>
            throw StateError('bugly is down'),
        onFailure: failures.add,
      );

      starter.startSdks(ConsentRegion.cn);
      starter.startSdks(ConsentRegion.cn);

      expect(
        clarityAttempts,
        1,
        reason: 'the flag is set before the call (ConsentStore.java:82, :97)',
      );
      expect(failures.length, 2);
      expect(starter.failureCount, 2);
      expect(starter.clarityStartCount, 0);
      expect(starter.buglyStartCount, 0);
      expect(starter.clarityStarted, isTrue);
      expect(starter.buglyStarted, isTrue);
    });
  });
}
