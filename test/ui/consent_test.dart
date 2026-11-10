// T42 —— Consent 门槛页测试（**只编写，不执行**：本卡禁止 flutter/dart test/analyze）。
//
// 被测验的对象是 presentation 层：
//   - 文案/标题/按钮全部来自 T27 lib/app/consent_gate.dart 的 ConsentDialogCopy 常量，
//     本文件的期望值独立抄写（产品被改动时必须在这里失败）；
//   - 流程由 T27 的 ConsentGate 驱动，测试用 fake ConsentPorts 注入（不联网、不真等 3 秒）。
// 本文件**不**再断言 T27 内部的幂等标志（ConsentSdkStarter 属 T27 自己的测试），
// 也不复制第二套流程机（T42-CHANNEL-34-R1 M1）。
//
// Qt 证据（Qt/android/src/rhine/music/database/）：
// - ConsentActivity.java:69-72   已同意直接放行，不再判定地区
// - ConsentActivity.java:76-107  3 秒硬闸门；超时/异常都按 other
// - ConsentActivity.java:95-97   宿主已销毁就什么都不做
// - ConsentActivity.java:98-104  CN/EU 弹窗；其他地区直接放行且不写持久标记
// - ConsentActivity.java:119-134 标题/按钮按地区取值、不可取消、返回键无效
// - ConsentActivity.java:136-140 正文隐私链接可点
// - ConsentActivity.java:158-164 返回键只在已同意时有效
// - res/values/styles.xml:8-14   RhineConsent 纯黑承载页

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/app/consent_gate.dart';
import 'package:rhine_music_database/ui/pages/consent_page.dart';

// ============================================================================
// 期望文案：独立抄一遍（产品常量被改动时必须在这里失败）
// ============================================================================

/// = ConsentActivity.java:36-51 的 text block 去掉公共缩进后的字节序列。
const String _expectedCnMessage =
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

/// = ConsentActivity.java:53-62 的 text block（8 行 + 结尾换行）。
const String _expectedEuMessage =
    'Before you agree, this app does not start its interface and does not transmit any data.\n'
    '\n'
    'With your consent, Microsoft Clarity (session analytics) collects de-identified\n'
    'interaction data — taps and navigation, device model, OS version, screen size and\n'
    'app version — and transfers it to servers outside the European Union.\n'
    '\n'
    'You may decline; the app will then close and no data will be uploaded.\n'
    'You can use the app without connect to the internet.\n';

// ============================================================================
// fake ConsentPorts（T27 的注入面）
// ============================================================================

/// 地域判定假件接口（T27 把它藏在 ConsentPorts.probeRegion 后面）。
abstract class _Probe {
  Future<ConsentRegion> resolve();
}

/// 立即给答案的判定。
class _FixedProbe extends _Probe {
  _FixedProbe(this.region) : error = null;

  _FixedProbe.error(Object this.error) : region = ConsentRegion.other;

  final ConsentRegion region;
  final Object? error;
  int resolveCalls = 0;

  @override
  Future<ConsentRegion> resolve() {
    resolveCalls += 1;
    final Object? failure = error;
    if (failure != null) {
      return Future<ConsentRegion>.error(failure);
    }
    return Future<ConsentRegion>.value(region);
  }
}

/// 内存版 T27 端口：只记调用顺序，不 import 任何 SDK。
class _FakePorts implements ConsentPorts {
  _FakePorts({
    this.granted = false,
    this.storedRegion = ConsentRegion.other,
    _Probe? probe,
  }) : probe = probe ?? _FixedProbe(ConsentRegion.other);

  bool granted;
  ConsentRegion storedRegion;
  final _Probe probe;

  final List<String> log = <String>[];

  @override
  ConsentRecord readRecord() {
    return ConsentRecord(granted: granted, region: storedRegion);
  }

  @override
  void writeGrant(ConsentRegion region) {
    log.add('grant:${region.name}');
    granted = true;
    storedRegion = region;
  }

  @override
  Future<ConsentRegion> probeRegion() => probe.resolve();

  @override
  void startSdks(ConsentRegion region) {
    log.add('startSdks:${region.name}');
  }

  @override
  void enterBusiness() {
    log.add('enterBusiness');
  }

  @override
  void exitApp() {
    log.add('exitApp');
  }
}

/// 一次门槛跑完的装配：T27 ConsentGate + 可观测的端口。
class _Gate {
  _Gate({
    bool granted = false,
    ConsentRegion storedRegion = ConsentRegion.other,
    _Probe? probe,
  }) : ports = _FakePorts(granted: granted, storedRegion: storedRegion, probe: probe) {
    gate = ConsentGate(ports);
  }

  final _FakePorts ports;
  late final ConsentGate gate;

  List<String> get log => ports.log;
}

// ============================================================================
// 辅助
// ============================================================================

/// 页面只吃 T27 的 gate 与待决地区读数。
Widget _app(
  ConsentGate gate,
  ConsentRegion? Function() pendingRegion,
  VoidCallback? onProceed, {
  BusinessEntryOwner businessEntry = BusinessEntryOwner.host,
  void Function(String url)? onPrivacyLinkTap,
  void Function(String reason)? onPresentationBroken,
}) {
  return MaterialApp(
    home: ConsentPage(
      gate: gate,
      businessEntry: businessEntry,
      onProceed: onProceed,
      regionOfPendingDecision: pendingRegion,
      onPrivacyLinkTap: onPrivacyLinkTap,
      onPresentationBroken: onPresentationBroken,
    ),
  );
}

/// 复刻 Android 系统返回键：向 flutter/navigation 发 popRoute 平台消息。
///
/// 选它而不是 tester.binding.handlePopRoute()：后者在 WidgetsBinding 上是
/// @protected @visibleForTesting，测试文件里直接调用会触发 invalid_use_of_protected_member。
Future<void> _sendSystemBack(WidgetTester tester) async {
  // 与 Flutter 自身测试一致（flutter/test/material/app_test.dart:1073）：
  // handlePlatformMessage 的形参是 ByteData?，声明成 Object 会类型不匹配。
  final ByteData message =
      const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute'));
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    message,
    (ByteData? _) {},
  );
  await tester.pumpAndSettle();
}

/// 按正文纯文本找 Text（find.text 对 Text.rich 不安全，这里显式比 toPlainText）。
Finder _bodyFinder(String plainText) {
  return find.byWidgetPredicate(
    (Widget widget) => widget is Text && widget.textSpan?.toPlainText() == plainText,
  );
}

void main() {
  // ==========================================================================
  group('文案逐字节（ConsentActivity.java:36-51 / :53-62）', () {
    test('CN_MESSAGE 与 Qt text block 全等', () {
      expect(kCnConsentMessage, _expectedCnMessage);
    });

    test('CN_MESSAGE 结构：3 处段间空行、7 行两空格缩进、URL 恰 1 次、结尾换行', () {
      expect(kCnConsentMessage.endsWith('\n'), isTrue);
      expect('\n\n'.allMatches(kCnConsentMessage).length, 3);
      expect(
        kCnConsentMessage
            .split('\n')
            .where((String line) => line.startsWith('  ') && line.trim().isNotEmpty)
            .length,
        7,
      );
      expect(
        'https://privacy.qq.com/document/preview/fc748b3d96224fdb825ea79e132c1a56'
            .allMatches(kCnConsentMessage)
            .length,
        1,
      );
      expect(kCnConsentMessage.contains('仅适用于中国大陆联网使用。'), isTrue);
    });

    test('EU_MESSAGE 与 Qt text block 全等（保留语法瑕疵与 em dash）', () {
      expect(kEuConsentMessage, _expectedEuMessage);
      expect(kEuConsentMessage.endsWith('\n'), isTrue);
      expect('\n\n'.allMatches(kEuConsentMessage).length, 2);
      expect(kEuConsentMessage.contains('—'), isTrue);
      expect(kEuConsentMessage.contains('You can use the app without connect to the internet.'), isTrue);
    });

    test('标题/按钮与 ConsentActivity.java:119、:122、:126 一致', () {
      // cnConsentDialog / euConsentDialog 是库级顶层 const（T27:228、:236），
      // 不是 ConsentDialogCopy 的静态成员；forRegion 才是类里的静态方法。
      expect(cnConsentDialog.title, '隐私与数据传输许可');
      expect(euConsentDialog.title, 'Data Transfer Consent');
      expect(cnConsentDialog.approveLabel, '同意');
      expect(cnConsentDialog.exitLabel, '退出');
      expect(euConsentDialog.approveLabel, 'Agree');
      expect(euConsentDialog.exitLabel, 'Exit');
      expect(cnConsentDialog.message, _expectedCnMessage);
      expect(euConsentDialog.message, _expectedEuMessage);
    });

    test('other 不是可弹窗地区：ConsentDialogCopy.forRegion 必须抛（ConsentActivity.java:98-105）', () {
      expect(() => ConsentDialogCopy.forRegion(ConsentRegion.other), throwsArgumentError);
    });
  });

  // ==========================================================================
  group('T27 ConsentGate 与 Qt 门槛语义（页面依赖的唯一流程机）', () {
    test('已同意：直接 proceeded，不判定地区，按持久 region 起 SDK 并进业务页', () async {
      final _Gate g = _Gate(granted: true, storedRegion: ConsentRegion.eu);

      await g.gate.start();

      expect(g.gate.phase, ConsentPhase.proceeded);
      expect(g.gate.region, ConsentRegion.eu);
      expect(g.log, <String>['startSdks:eu', 'enterBusiness']);
    });

    test('CN：awaitingConsent，且同意前一个副作用都没有（ConsentActivity.java:98-99）', () async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.cn));

      await g.gate.start();

      expect(g.gate.phase, ConsentPhase.awaitingConsent);
      expect(g.log, isEmpty);
      expect(g.gate.sdkStartCount, 0);
      expect(g.gate.businessLaunchCount, 0);
      expect(g.gate.persistGrantCount, 0);
    });

    test('CN 同意：writeGrant 在 startSdks 之前（ConsentActivity.java:123 先于 :124）', () async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.cn));
      await g.gate.start();

      g.gate.approve();

      expect(g.gate.phase, ConsentPhase.proceeded);
      expect(g.log, <String>['grant:cn', 'startSdks:cn', 'enterBusiness']);
      expect(g.gate.persistGrantCount, 1);
      expect(g.gate.sdkStartCount, 1);
      expect(g.gate.businessLaunchCount, 1);
    });

    test('EU 退出：只 exitApp，不写标记、不起 SDK（ConsentActivity.java:126）', () async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.eu));
      await g.gate.start();

      g.gate.decline();

      expect(g.gate.phase, ConsentPhase.declined);
      expect(g.log, <String>['exitApp']);
      expect(g.gate.exitCount, 1);
      expect(g.gate.recordPersisted, isFalse);
    });

    test('other 放行：不弹窗、不写标记，下次启动重新判定（ConsentActivity.java:100-104）', () async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.other));

      await g.gate.start();

      expect(g.gate.phase, ConsentPhase.proceeded);
      expect(g.gate.recordPersisted, isFalse);
      expect(g.log, <String>['startSdks:other', 'enterBusiness']);
    });

    // 3 秒硬闸门本身由 T27 自己的 consent_gate_test 覆盖（它持有 kRegionProbeTimeoutMs）：
    // 这里不再挂一个真实 3 秒 Timer，只验「判定抛异常 → other」（ConsentActivity.java:88-89）。
    test('判定抛异常 → 按 other 放行（ConsentActivity.java:91-93）', () async {
      final _Gate failed = _Gate(probe: _FixedProbe.error(StateError('probe boom')));
      await failed.gate.start();
      expect(failed.gate.phase, ConsentPhase.proceeded);
      expect(failed.gate.region, ConsentRegion.other);
    });

    test('待决期间再 start 不重新探测（ConsentActivity.java:76-107 每次启动只判一次）', () async {
      final _FixedProbe probe = _FixedProbe(ConsentRegion.cn);
      final _Gate g = _Gate(probe: probe);
      await g.gate.start();

      await g.gate.start();

      expect(probe.resolveCalls, 1);
      expect(g.gate.phase, ConsentPhase.awaitingConsent);
    });

    test('返回键：未同意一路吃掉，同意后才交给宿主（ConsentActivity.java:158-164）', () async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.cn));
      await g.gate.start();
      expect(g.gate.backPressed(), isFalse);

      g.gate.approve();

      expect(g.gate.backPressed(), isTrue);
    });
  });
  // ==========================================================================
  group('ConsentPage：CN 弹窗（ConsentActivity.java:116-141）', () {
    testWidgets('needsDecision(cn)：中文标题/按钮/正文，不可取消，返回键不关', (WidgetTester tester) async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.cn));
      int proceeded = 0;

      await tester.pumpWidget(_app(g.gate, () => ConsentRegion.cn, () => proceeded += 1));
      await tester.pumpAndSettle();

      expect(proceeded, 0);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('隐私与数据传输许可'), findsOneWidget);
      expect(find.text('同意'), findsOneWidget);
      expect(find.text('退出'), findsOneWidget);
      expect(_bodyFinder(kCnConsentMessage), findsOneWidget);
      // 弹窗出现前依然没有启动任何 SDK、也没有写持久标记。
      expect(g.log, isEmpty);

      // 文案 span 结构：前缀 + 可点 URL + 尾巴，拼回来逐字节等于 CN 文案。
      final Text body = tester.widget<Text>(_bodyFinder(kCnConsentMessage));
      final TextSpan span = body.textSpan! as TextSpan;
      expect(span.children, isNotNull);
      expect(span.children!.length, 2);
      final TextSpan link = span.children!.first as TextSpan;
      final TextSpan tail = span.children!.last as TextSpan;
      expect(link.text, contains('https://privacy.qq.com/'));
      expect(link.recognizer, isA<TapGestureRecognizer>());
      expect(span.text! + link.text! + tail.text!, kCnConsentMessage);

      // barrierDismissible=false（ConsentActivity.java:121、:130）：点空白不关。
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      // 返回键不关（ConsentActivity.java:134）。
      await _sendSystemBack(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(proceeded, 0);
      expect(g.log, isEmpty);
    });

    testWidgets('点「同意」：grant→startSdks→enterBusiness，对话关闭，onProceed 一次', (WidgetTester tester) async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.cn));
      int proceeded = 0;

      await tester.pumpWidget(_app(g.gate, () => ConsentRegion.cn, () => proceeded += 1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同意'));
      await tester.pumpAndSettle();

      expect(proceeded, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(g.log, <String>['grant:cn', 'startSdks:cn', 'enterBusiness']);
    });

    testWidgets('点「退出」：exitApp 一次、onProceed 零次，之后 approve 抛 StateError', (WidgetTester tester) async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.cn));
      int proceeded = 0;

      await tester.pumpWidget(_app(g.gate, () => ConsentRegion.cn, () => proceeded += 1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出'));
      await tester.pumpAndSettle();

      expect(proceeded, 0);
      expect(find.byType(AlertDialog), findsNothing);
      expect(g.log, <String>['exitApp']);
      // T27 的合法性检查：已 declined 就不能再 approve（「拒绝后继续」不可达）。
      expect(() => g.gate.approve(), throwsStateError);
      expect(g.log, <String>['exitApp']);
    });

    testWidgets('隐私链接可点：回调收到正文里的 URL，且弹窗不关闭（ConsentActivity.java:136-140）', (WidgetTester tester) async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.cn));
      final List<String> opened = <String>[];

      await tester.pumpWidget(
        _app(g.gate, () => ConsentRegion.cn, () {}, onPrivacyLinkTap: opened.add),
      );
      await tester.pumpAndSettle();

      final Text body = tester.widget<Text>(_bodyFinder(kCnConsentMessage));
      final TextSpan link = (body.textSpan! as TextSpan).children!.first as TextSpan;
      final TapGestureRecognizer recognizer = link.recognizer! as TapGestureRecognizer;
      expect(recognizer.onTap, isNotNull);
      // 不做坐标点击：URL 位于长文中间，按坐标点不可靠；这里直接触发挂上去的回调。
      recognizer.onTap!();
      await tester.pumpAndSettle();

      expect(opened, <String>[link.text]);
      expect(opened.single, startsWith('https://privacy.qq.com/document/preview/'));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(g.log, isEmpty);
    });

    testWidgets('双击同意只生效一次：log 里只有一组副作用（未执行）', (WidgetTester tester) async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.cn));
      int proceeded = 0;

      await tester.pumpWidget(_app(g.gate, () => ConsentRegion.cn, () => proceeded += 1));
      await tester.pumpAndSettle();

      // 同一帧内连点两次，模拟双击。
      await tester.tap(find.text('同意'), warnIfMissed: false);
      await tester.tap(find.text('同意'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(proceeded, 1);
      expect(g.log.where((String e) => e == 'grant:cn').length, 1);
      expect(g.log.where((String e) => e == 'startSdks:cn').length, 1);
      expect(g.log.where((String e) => e == 'enterBusiness').length, 1);
    });

    testWidgets('同意后页面 PopScope 重建：canPop 由 false 变 true（M2 回归）', (WidgetTester tester) async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.cn));

      await tester.pumpWidget(_app(g.gate, () => ConsentRegion.cn, () {}));
      await tester.pumpAndSettle();

      final Finder pagePop = find.byKey(const ValueKey<String>('consent-page-pop'));
      expect(tester.widget<PopScope>(pagePop).canPop, isFalse);

      await tester.tap(find.text('同意'));
      await tester.pumpAndSettle();

      // 若实现只在 build 期读一次快照，这里会一直是 false。
      expect(tester.widget<PopScope>(pagePop).canPop, isTrue);
      expect(g.gate.phase, ConsentPhase.proceeded);
    });

    testWidgets('黑底承载页：Scaffold 背景是纯黑（styles.xml:12-13）', (WidgetTester tester) async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.cn));

      await tester.pumpWidget(_app(g.gate, () => ConsentRegion.cn, () {}));
      await tester.pumpAndSettle();

      final Scaffold scaffold =
          tester.widget<Scaffold>(find.byKey(const ValueKey<String>('consent-gate-surface')));
      expect(scaffold.backgroundColor, const Color(0xFF000000));
    });
  });

  // ==========================================================================
  group('ConsentPage：EU 弹窗（ConsentActivity.java:119-126）', () {
    testWidgets('needsDecision(eu)：英文标题/按钮，正文无链接 span', (WidgetTester tester) async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.eu));

      await tester.pumpWidget(_app(g.gate, () => ConsentRegion.eu, () {}));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Data Transfer Consent'), findsOneWidget);
      expect(find.text('Agree'), findsOneWidget);
      expect(find.text('Exit'), findsOneWidget);
      expect(find.text('隐私与数据传输许可'), findsNothing);

      final Text body = tester.widget<Text>(_bodyFinder(kEuConsentMessage));
      final TextSpan span = body.textSpan! as TextSpan;
      expect(span.text, kEuConsentMessage);
      expect(span.children, isNull);
    });

    testWidgets('EU 点 Agree：按 eu 写标记并进业务页', (WidgetTester tester) async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.eu));
      int proceeded = 0;

      await tester.pumpWidget(_app(g.gate, () => ConsentRegion.eu, () => proceeded += 1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agree'));
      await tester.pumpAndSettle();

      expect(proceeded, 1);
      expect(g.log, <String>['grant:eu', 'startSdks:eu', 'enterBusiness']);
    });
  });

  // ==========================================================================
  group('ConsentPage：放行路径与防重复通知', () {
    testWidgets('已同意：onProceed 一次、无对话框、不判定地区', (WidgetTester tester) async {
      final _Gate g = _Gate(granted: true, storedRegion: ConsentRegion.eu);
      int proceeded = 0;

      await tester.pumpWidget(_app(g.gate, () => null, () => proceeded += 1));
      await tester.pumpAndSettle();

      expect(proceeded, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(g.log, <String>['startSdks:eu', 'enterBusiness']);
    });

    testWidgets('other 放行：onProceed 一次、无对话框、不写持久标记', (WidgetTester tester) async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.other));
      int proceeded = 0;

      await tester.pumpWidget(_app(g.gate, () => null, () => proceeded += 1));
      await tester.pumpAndSettle();

      expect(proceeded, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(g.gate.recordPersisted, isFalse);
      expect(g.gate.backPressed(), isFalse);
    });

    testWidgets('待决地区读数异常：不弹空窗、不伪造放行，并上报宿主（R2-5）', (WidgetTester tester) async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.cn));
      final List<String> broken = <String>[];

      await tester.pumpWidget(
        _app(g.gate, () => null, () {}, onPresentationBroken: broken.add),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(g.log, isEmpty);
      // T27 停在 awaitingConsent：本页既不猜地区也不放行，只把不变量破坏上报。
      expect(g.gate.phase, ConsentPhase.awaitingConsent);
      expect(broken, hasLength(1));
      expect(broken.single, contains('awaitingConsent without a pending region'));
    });

    testWidgets('businessEntry=ports：T27 enterBusiness 已导航，页面绝不再调 onProceed（R2-4）',
        (WidgetTester tester) async {
      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.cn));
      int hostNavigations = 0;

      await tester.pumpWidget(
        _app(
          g.gate,
          () => ConsentRegion.cn,
          () => hostNavigations += 1,
          businessEntry: BusinessEntryOwner.host,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('同意'));
      await tester.pumpAndSettle();
      expect(hostNavigations, 1);
      expect(g.log, <String>['grant:cn', 'startSdks:cn', 'enterBusiness']);

      // ports 模式：onProceed 必须为 null（构造期断言），页面绝不第二次导航。
      final _Gate g2 = _Gate(probe: _FixedProbe(ConsentRegion.cn));
      await tester.pumpWidget(
        _app(g2.gate, () => ConsentRegion.cn, null, businessEntry: BusinessEntryOwner.ports),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('同意'));
      await tester.pumpAndSettle();

      // 导航只发生一次，且发生在 T27 的 enterBusiness 里（log 里恰好一条）。
      expect(g2.log, <String>['grant:cn', 'startSdks:cn', 'enterBusiness']);

      // 构造期断言：ports 模式下传 onProceed 会 assert 失败（debug 下抛 AssertionError）。
      expect(
        () => ConsentPage(
          gate: _Gate(probe: _FixedProbe(ConsentRegion.cn)).gate,
          regionOfPendingDecision: () => ConsentRegion.cn,
          businessEntry: BusinessEntryOwner.ports,
          onProceed: () {},
        ),
        throwsAssertionError,
      );
    });

    testWidgets('竖屏：对话框仍渲染，无布局异常（双倍安全边距分支）', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final _Gate g = _Gate(probe: _FixedProbe(ConsentRegion.cn));

      await tester.pumpWidget(_app(g.gate, () => ConsentRegion.cn, () {}));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('同意'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
