// Android 宿主契约（原子 A24 / DEDUP-37）——返回键路由的源文件形状。
//
// 被测文件：
//   android/app/src/main/AndroidManifest.xml
//   android/app/src/main/kotlin/rhine/music/database/MainActivity.kt
//   android/app/src/main/kotlin/rhine/music/database/porting/QtPlatformViewHost.kt
//
// 对照来源：
//   Qt/android/AndroidManifest.xml:64                        application 上的
//                                                            enableOnBackInvokedCallback
//   QtActivityBase.java:271、:291-297 → QtInputDelegate.java:503、:524、:544
//                                                            Qt 的返回键入口（包内可见）
//   FlutterActivity.java:658-676、:701-726、:940-943          Flutter 自己的槽位与终点
//
// 这些断言只读源码文本，不启动 Android、不跑 flutter test 之外的任何东西；
// 本 worktree 禁止执行验证，**RED/GREEN 均未执行**，文件头如实声明。
// 计划执行入口：flutter test test/app/android_host_contract_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 取第一个匹配到的元素文本（属性里不含 '>'，所以截到 '>' 为止是安全的）。
String _element(String text, String open) {
  final int start = text.indexOf(open);
  expect(start, isNot(-1), reason: 'missing ' + open);
  final int end = text.indexOf('>', start);
  return text.substring(start, end + 1);
}

/// [needle] 在 [text] 中、[from] 之后的下标；找不到时失败并给出可读理由。
int _indexAfter(String text, String needle, {int from = 0, String? reason}) {
  final int index = text.indexOf(needle, from);
  expect(index, isNot(-1), reason: reason ?? ('missing ' + needle));
  return index;
}

void main() {
  final String manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final String activityKt = File(
    'android/app/src/main/kotlin/rhine/music/database/MainActivity.kt',
  ).readAsStringSync();
  final String hostKt = File(
    'android/app/src/main/kotlin/rhine/music/database/porting/QtPlatformViewHost.kt',
  ).readAsStringSync();
  final String manifestCode = manifest.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

  group('AndroidManifest.xml (DEDUP-37)', () {
    test('activity 打开 enableOnBackInvokedCallback，且只打开一次', () {
      final String activity = _element(manifestCode, '<activity');
      expect(activity.contains('android:name=".MainActivity"'), isTrue);
      expect(activity.contains('android:enableOnBackInvokedCallback="true"'), isTrue);
      expect(
        'android:enableOnBackInvokedCallback'.allMatches(manifestCode).length,
        1,
        reason: '开关只声明在本 activity 上（Qt 声明在 application 上）',
      );
    });

    test('原有 configChanges / allowBackup 未被改写', () {
      final String activity = _element(manifestCode, '<activity');
      for (final String flag in <String>[
        'orientation',
        'keyboardHidden',
        'screenSize',
        'smallestScreenSize',
        'uiMode',
      ]) {
        expect(activity.contains(flag), isTrue, reason: flag);
      }
      final String application = _element(manifestCode, '<application');
      expect(application.contains('android:allowBackup="false"'), isTrue);
    });

    test('DEDUP-39：不写 screenOrientation，不锁方向', () {
      expect(manifestCode.contains('android:screenOrientation'), isFalse);
    });
  });

  group('MainActivity.kt (DEDUP-37)', () {
    test('仍是 FlutterActivity，不引 androidx、不锁方向、不直接 finish 业务页', () {
      expect(activityKt.contains('class MainActivity : FlutterActivity()'), isTrue);
      expect(activityKt.contains('import androidx.'), isFalse);
      expect(activityKt.contains('setRequestedOrientation'), isFalse);
      expect(activityKt.contains('requestedOrientation'), isFalse);
      expect(activityKt.contains('finish('), isFalse);
    });

    test('两个返回入口都在：onBackPressed 与 setFrameworkHandlesBack', () {
      expect(activityKt.contains('override fun onBackPressed()'), isTrue);
      expect(
        activityKt.contains('override fun setFrameworkHandlesBack(frameworkHandlesBack: Boolean)'),
        isTrue,
      );
      expect(activityKt.contains('super.onBackPressed()'), isTrue);
    });

    test('API 33+ 用 OnBackInvokedCallback 注册 PRIORITY_DEFAULT，且失败不崩', () {
      expect(activityKt.contains('OnBackInvokedDispatcher.PRIORITY_DEFAULT'), isTrue);
      expect(activityKt.contains('registerOnBackInvokedCallback('), isTrue);
      expect(activityKt.contains('unregisterOnBackInvokedCallback('), isTrue);
      expect(activityKt.contains('IllegalArgumentException'), isTrue);
    });

    test('顺序是 IME → 询问 Qt 宿主视图 → 未认领才回落 Flutter', () {
      final int routing = _indexAfter(activityKt, 'private fun dispatchHostBack()');
      final int ime = _indexAfter(activityKt, 'if (hideImeIfVisible()) return', from: routing);
      final int hostBack = _indexAfter(activityKt, 'QtPlatformViewHost.dispatchBackVerb {',
          from: routing);
      expect(ime < hostBack, isTrue, reason: 'IME 必须先于 Qt 视图');

      // 认领才停：claimed 为 true 直接从回调返回；否则走 fallBackToFlutter()。
      final int claimCheck = _indexAfter(activityKt, 'if (claimed) return@dispatchBackVerb',
          from: hostBack);
      final int fallbackCall = _indexAfter(activityKt, 'fallBackToFlutter()', from: claimCheck);
      expect(hostBack < claimCheck, isTrue);
      expect(claimCheck < fallbackCall, isTrue);

      // 回落的唯一终点是 super.onBackPressed()，且不在 Activity 收尾后补发。
      final int fallbackBody = _indexAfter(activityKt, 'private fun fallBackToFlutter()');
      final int finishingGuard = _indexAfter(activityKt, 'if (isFinishing || isDestroyed) return',
          from: fallbackBody);
      final int superCall = _indexAfter(activityKt, 'super.onBackPressed()', from: finishingGuard);
      expect(finishingGuard < superCall, isTrue);
    });

    test('两个返回入口都不做同步判定，统一交给 dispatchHostBack', () {
      final int pressed = _indexAfter(activityKt, 'override fun onBackPressed()');
      final int routed = _indexAfter(activityKt, 'dispatchHostBack()', from: pressed);
      expect(pressed < routed, isTrue);

      // 入口里不得出现旧的同步 consume 写法（handleHostBack 返回 Boolean 的老形状）。
      expect(activityKt.contains('handleHostBack'), isFalse);
      expect(activityKt.contains('dispatchBackVerb()'), isFalse);
    });

    test('IME 可见性按 SDK 分支，隐藏用 InputMethodManager', () {
      expect(activityKt.contains('hideSoftInputFromWindow('), isTrue);
      expect(activityKt.contains('WindowInsets.Type.ime()'), isTrue);
      expect(activityKt.contains('getWindowVisibleDisplayFrame('), isTrue);
    });
  });

  group('QtPlatformViewHost.kt (DEDUP-37)', () {
    test('back verb 是控制通道上的出站方法名常量，询问协议带 Result 回调', () {
      expect(hostKt.contains('const val METHOD_BACK = "back"'), isTrue);
      expect(hostKt.contains('internal fun dispatchBackVerb(onResult: (Boolean) -> Unit)'), isTrue);
      expect(hostKt.contains('internal fun forwardBackVerb(onResult: (Boolean) -> Unit)'), isTrue);
      expect(
        hostKt.contains('control.invokeMethod(QtPlatformViewHost.METHOD_BACK, payload, reply)'),
        isTrue,
      );
    });

    test('只有显式 Boolean true 才算认领：null / false / error / notImplemented 都回落', () {
      final int forwardAt = _indexAfter(hostKt, 'internal fun forwardBackVerb(onResult: (Boolean) -> Unit)');
      final int trueOnly = _indexAfter(hostKt, 'val claimed = result == true', from: forwardAt);
      final int successFn = _indexAfter(hostKt, 'override fun success(', from: forwardAt);
      final int errorFn = _indexAfter(hostKt, 'override fun error(', from: successFn);
      final int notImpl = _indexAfter(hostKt, 'override fun notImplemented()', from: errorFn);
      final int invoke = _indexAfter(
        hostKt,
        'control.invokeMethod(QtPlatformViewHost.METHOD_BACK, payload, reply)',
        from: notImpl,
      );
      expect(successFn < trueOnly, isTrue);
      expect(errorFn < notImpl, isTrue);
      expect(notImpl < invoke, isTrue);

      // error / notImplemented 两条分支都必须显式回 false，不能只 log 就算处理了。
      final int errorBody = _indexAfter(hostKt, 'onResult(false)', from: errorFn);
      expect(errorFn < errorBody, isTrue);
      expect(errorBody < notImpl, isTrue);
      // 旧的"调用没抛异常就算成功"的写法必须已经消失。
      expect(hostKt.contains('.isSuccess'), isFalse);
    });

    test('没有 Qt 视图 / 未 ready 时不发问，直接回 false 让 Activity 回落', () {
      final int forwardAt = _indexAfter(hostKt, 'internal fun forwardBackVerb(onResult: (Boolean) -> Unit)');
      final int guard = _indexAfter(hostKt, 'if (qtView == null)', from: forwardAt);
      final int verdictGuard = _indexAfter(hostKt, 'if (status["verdict"] != "ready")', from: forwardAt);
      final int invoke = _indexAfter(
        hostKt,
        'control.invokeMethod(QtPlatformViewHost.METHOD_BACK, payload, reply)',
        from: forwardAt,
      );
      expect(guard < invoke, isTrue);
      expect(verdictGuard < invoke, isTrue);
      final int guardBody = _indexAfter(hostKt, 'onResult(false)', from: guard);
      expect(guard < guardBody, isTrue);
      expect(guardBody < verdictGuard, isTrue);
    });

    test('dispatchBackVerb 没有归属者立即回落，且回复只认一次 + 250ms 超时兜底', () {
      final int dispatchAt = _indexAfter(hostKt, 'internal fun dispatchBackVerb(onResult: (Boolean) -> Unit)');
      final int ownerGuard = _indexAfter(hostKt, 'if (owner == null)', from: dispatchAt);
      final int immediateFalse = _indexAfter(hostKt, 'onResult(false)', from: ownerGuard);
      final int forward = _indexAfter(hostKt, 'owner.forwardBackVerb { claimed ->', from: dispatchAt);
      expect(ownerGuard < forward, isTrue);
      expect(immediateFalse < forward, isTrue);

      final int settled = _indexAfter(hostKt, 'val settled = AtomicBoolean(false)', from: dispatchAt);
      // 全文只有这一处一次性闸门：超时分支 + 回复分支共用同一个 settled。
      expect(RegExp(r'settled\.compareAndSet\(false, true\)').allMatches(hostKt).length, 2);
      final int timeoutConst = _indexAfter(hostKt, 'const val BACK_VERB_TIMEOUT_MS = 250L');
      final int timeoutRunnable = _indexAfter(hostKt, 'val timeout = Runnable {', from: settled);
      final int timeoutCas =
          _indexAfter(hostKt, 'settled.compareAndSet(false, true)', from: timeoutRunnable);
      final int postDelayed = _indexAfter(hostKt, 'mainHandler.postDelayed(timeout, BACK_VERB_TIMEOUT_MS)',
          from: timeoutRunnable);
      // 一次性闸门出现两次：超时 Runnable 里一次（源码在 postDelayed 之前定义），
      // 回复回调里一次（postDelayed 之后）；两处都拿同一个 settled 做先到先得。
      final int replyCas = _indexAfter(hostKt, 'settled.compareAndSet(false, true)', from: postDelayed);
      final int removeCallbacks =
          _indexAfter(hostKt, 'mainHandler.removeCallbacks(timeout)', from: postDelayed);
      expect(timeoutConst < postDelayed, isTrue);
      expect(settled < postDelayed, isTrue);
      expect(timeoutRunnable < timeoutCas, isTrue);
      expect(timeoutCas < postDelayed, isTrue);
      expect(postDelayed < replyCas, isTrue);
      expect(replyCas < removeCallbacks, isTrue);
    });
  });
}
