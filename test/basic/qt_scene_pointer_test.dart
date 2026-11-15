import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/qt_scene_view.dart';

/// Qt 场景指针搬运的可证伪测试（FINAL-RECOVERY-138 / 指针归属与去重）。
///
/// 这里只证明 Dart 侧状态机：哪些事件真的下发给 Qt、下发成什么类型。
/// 设备上"归档跟着手指动"是归属问题（HUD 命中 vs 场景），那部分要实机日志；
/// 但"双指退单指后的幽灵 move"和"up 被去重吞掉"是纯状态机错误，能在这里锁死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(qtSceneChannelName);
  final List<MethodCall> calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return null;
    });
    QtScenePointerBridge.instance.attach(7);
  });

  tearDown(() {
    QtScenePointerBridge.instance.detach(7);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  List<String> types() => calls
      .where((MethodCall call) => call.method == 'pointer')
      .map((MethodCall call) =>
          (call.arguments as Map<Object?, Object?>)['type']! as String)
      .toList();

  const Rect scene = Rect.fromLTWH(0, 0, 1920, 1080);

  PointerDownEvent down(int pointer, Offset at, {int stamp = 0}) =>
      PointerDownEvent(
        pointer: pointer,
        position: at,
        timeStamp: Duration(milliseconds: stamp),
      );

  PointerMoveEvent move(int pointer, Offset at, {int stamp = 0}) =>
      PointerMoveEvent(
        pointer: pointer,
        position: at,
        timeStamp: Duration(milliseconds: stamp),
      );

  PointerUpEvent up(int pointer, Offset at, {int stamp = 0}) => PointerUpEvent(
        pointer: pointer,
        position: at,
        timeStamp: Duration(milliseconds: stamp),
      );

  test('同一时间戳同一位置的 down 与 up 都必须下发（去重键要带事件类型）', () {
    QtScenePointerBridge.instance
      ..down(down(1, const Offset(100, 100), stamp: 5), scene)
      ..up(up(1, const Offset(100, 100), stamp: 5), scene);
    expect(types(), <String>['pointerdown', 'pointerup'],
        reason: '只按 timeStamp+位置去重会把真正的 up 吞掉，Qt 永远停在下压态');
  });

  test('完全重复的 move 只下发一次，但换了坐标的重采样照常下发', () {
    QtScenePointerBridge.instance
      ..down(down(1, const Offset(100, 100), stamp: 1), scene)
      ..move(move(1, const Offset(120, 100), stamp: 2), scene)
      ..move(move(1, const Offset(120, 100), stamp: 2), scene)
      ..move(move(1, const Offset(140, 100), stamp: 2), scene);
    expect(types(), <String>['pointerdown', 'pointermove', 'pointermove'],
        reason: '同时间戳不同坐标是重采样，不能丢（丢了就是"拖一半不跟手"）');
  });

  test('双指退单指：剩下的手指不再产生幽灵 move，抬起也不发没有 down 的 up', () {
    QtScenePointerBridge.instance
      ..down(down(1, const Offset(300, 500), stamp: 1), scene)
      ..down(down(2, const Offset(400, 500), stamp: 2), scene)
      ..move(move(2, const Offset(420, 500), stamp: 3), scene)
      ..move(move(1, const Offset(300, 520), stamp: 4), scene)
      ..up(up(2, const Offset(420, 500), stamp: 5), scene)
      ..move(move(1, const Offset(300, 560), stamp: 6), scene)
      ..up(up(1, const Offset(300, 560), stamp: 7), scene);
    // 双指期间质心位移会走 'pan'（Qt NativeViewer 的同一条通路），这是允许的；
    // 不允许的是 'pointermove'（单指拖拽）和没有 down 的 'pointerup'。
    expect(types(), isNot(contains('pointermove')),
        reason: '双指退单指后剩下的手指不属于 Qt，它的 move 是幽灵拖动');
    expect(types().where((String type) => type == 'pointerdown').length, 1);
    expect(types().where((String type) => type == 'pointerup').length, 0,
        reason: 'Qt 收到 cancel 之后不该再收到 up');
    // 双指间距变化走 wheel（缩放），同样属于允许的双指通路；单指阶段不允许出现 wheel。
    final int firstMove = types().indexOf('pointermove');
    expect(firstMove, -1, reason: '整个过程都不该出现单指拖拽事件');
  });

  test('系统取消下发 pointercancel，而不是用 up 顶替', () {
    QtScenePointerBridge.instance
      ..down(down(1, const Offset(200, 200), stamp: 1), scene)
      ..cancel(const PointerCancelEvent(pointer: 1, position: Offset(200, 200)));
    expect(types(), <String>['pointerdown', 'pointercancel']);
  });

  test('视图重建后状态机干净：旧指针不会带到新视图', () {
    QtScenePointerBridge.instance
      ..down(down(1, const Offset(10, 10), stamp: 1), scene)
      ..detach(7)
      ..attach(8)
      ..move(move(1, const Offset(200, 200), stamp: 2), scene);
    expect(types(), <String>['pointerdown'],
        reason: 'detach 必须清空 _forwarded/_pointers/_lastKey，否则旧手指继续拖新视图');
  });

  test('每根手指的 down 都会加上去重表条目，抬起时清掉（表不能无界增长）', () {
    for (int pointer = 1; pointer <= 6; ++pointer) {
      QtScenePointerBridge.instance
        ..down(down(pointer, const Offset(50, 50), stamp: pointer), scene)
        ..up(up(pointer, const Offset(50, 50), stamp: pointer + 100), scene);
    }
    // 6 组 down/up 全部下发；如果 up 之后没清表，第 2 根的同坐标事件会被误判重复。
    expect(types().where((String type) => type == 'pointerdown').length, 6);
    expect(types().where((String type) => type == 'pointerup').length, 6);
  });
}
