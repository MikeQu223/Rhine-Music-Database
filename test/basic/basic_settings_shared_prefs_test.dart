/// 设置持久化的真落地：shared_preferences（2026-11-16 用户直接指示）。
///
/// 这里量的是 [SharedPreferencesBasicSettingsPort] 的真实行为，不量 UI：
///   1) 键是完整 `panel/<裸键>`（与 Qt/src/Host.cpp:1075 的 `"panel/" + key` 同一字符串）；
///   2) 值是字符串，读回逐字相同；
///   3) 非 `panel/` 前缀的键不进 readAll（不把别人的偏好当成设置）；
///   4) 写失败必须如实返回 false（绝不假装落盘），读失败给空集合而不是编默认值；
///   5) packageInfo / openUrl 仍走原平台通道（不是持久化，不需要换实现）。
///
/// 背景（真机证据，不是推测）：2026-11-16 20:56 在 526f6b6d 上点「右侧画面遮罩」
/// 的 80 刻度后，设置窗横幅显示「写入失败：archive-mask-strength 未能保存（仍是 55）」，
/// 截图 .agents/parity-20261109/logs/159/install-and-run2/shot-09-after-stepper.png。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('写入后读回同一字符串，键带 panel/ 前缀', () async {
    final SharedPreferencesBasicSettingsPort port = SharedPreferencesBasicSettingsPort();
    expect(await port.write('${basicSettingsPreferencePrefix}archive-mask-strength', '80'), isTrue);

    final Map<String, String> all = await port.readAll();
    expect(all['panel/archive-mask-strength'], '80');
    // 只接受字符串：数字/布尔不会被读成"看起来像"的字符串。
    expect(all.length, 1);
  });

  test('remove 之后读回为空；删不存在的键不抛', () async {
    final SharedPreferencesBasicSettingsPort port = SharedPreferencesBasicSettingsPort();
    await port.write('${basicSettingsPreferencePrefix}theme', 'dark');
    expect((await port.readAll())['panel/theme'], 'dark');

    await port.remove('${basicSettingsPreferencePrefix}theme');
    expect((await port.readAll()).containsKey('panel/theme'), isFalse);
    await port.remove('${basicSettingsPreferencePrefix}never-written');
  });

  test('非 panel/ 前缀的键不进入 readAll', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'someone-else/key': 'x',
      'panel/theme': 'light',
      'panel/numeric': 42,
    });
    final Map<String, String> all = await SharedPreferencesBasicSettingsPort().readAll();
    // 非字符串值（这里 42）同样不进入结果：设置值是字符串契约。
    expect(all, <String, String>{'panel/theme': 'light'});
  });

  test('读失败给空集合、写失败给 false：不编默认值也不假装落盘', () async {
    Future<SharedPreferences> explode() async => throw StateError('plugin missing');
    final SharedPreferencesBasicSettingsPort port =
        SharedPreferencesBasicSettingsPort(preferences: explode);

    expect(await port.readAll(), isEmpty);
    expect(await port.write('${basicSettingsPreferencePrefix}render-scale', '75'), isFalse);
    await port.remove('${basicSettingsPreferencePrefix}render-scale');
  });

  test('packageInfo / openUrl 仍走平台通道（不是持久化）', () async {
    const MethodChannel channel = MethodChannel('test/basic_settings_host');
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      switch (call.method) {
        case 'packageInfo':
          return <String, Object?>{
            'packageName': 'rhine.music.database',
            'versionName': '1.0.0',
            'versionCode': 1,
            'debuggable': true,
          };
        case 'openUrl':
          return true;
        default:
          return null;
      }
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final SharedPreferencesBasicSettingsPort port = SharedPreferencesBasicSettingsPort(
      host: MethodChannelBasicSettingsPort(channel: channel),
    );

    final BasicSettingsPackageInfo info = await port.packageInfo();
    expect(info.packageName, 'rhine.music.database');
    expect(info.version?.version, '1.0.0');
    expect(await port.openUrl('https://example.invalid/x'), isTrue);
    expect(calls.map((MethodCall c) => c.method), <String>['packageInfo', 'openUrl']);
  });
}
