import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/storage/preference_store.dart';
import '../hud/modals/settings_modal.dart';
import 'basic_settings.dart';

/// 跨语言契约：Android 侧 porting/BasicSettingsChannel.kt 的 CHANNEL 逐字相同。
const String basicSettingsChannelName = 'rhine.music.database/basic_settings';

/// 本 APK 的真实版本真值（PackageManager 读出来的，不是写死的）。
/// 平台没有报告 versionName 时的可见版本串（如实说“未知”，不编版本号）。
const String basicSettingsUnknownVersion = '未知版本';

class BasicSettingsPackageInfo {
  const BasicSettingsPackageInfo({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.debuggable,
  });

  static const BasicSettingsPackageInfo unknown = BasicSettingsPackageInfo(
    packageName: '',
    versionName: '',
    versionCode: 0,
    debuggable: true,
  );

  final String packageName;
  final String versionName;
  final int versionCode;

  /// true = debuggable 构建 → 面板显示"开发版"并画 commit 行。
  final bool debuggable;

  /// 面板版本行：version 只取 [versionName]；releaseBuild 由 debuggable 反推。
  /// 读不到版本时宁可不出行，也不编一个（[BasicSettingsVersion.version] 断言非空）。
  BasicSettingsVersion? get version {
    if (versionName.isEmpty) {
      return null;
    }
    return BasicSettingsVersion(
      version: versionName,
      releaseBuild: !debuggable,
      commitTitle: '',
    );
  }
}

/// 设置持久化的宿主端口（Android = MethodChannel；测试 = 内存）。
abstract class BasicSettingsPort {
  Future<Map<String, String>> readAll();
  Future<bool> write(String key, String value);
  Future<void> remove(String key);
  Future<BasicSettingsPackageInfo> packageInfo();
  Future<bool> openUrl(String url);
}

/// 真实落盘：通道失败一律收敛成"失败"，绝不假装写成功。
class MethodChannelBasicSettingsPort implements BasicSettingsPort {
  MethodChannelBasicSettingsPort({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(basicSettingsChannelName);

  final MethodChannel _channel;

  @override
  Future<Map<String, String>> readAll() async {
    try {
      final Object? raw = await _channel.invokeMethod<Object?>('all');
      if (raw is! Map) {
        return const <String, String>{};
      }
      final Map<String, String> out = <String, String>{};
      raw.forEach((Object? key, Object? value) {
        if (key is String && value is String) {
          out[key] = value;
        }
      });
      return out;
    } catch (_) {
      return const <String, String>{};
    }
  }

  @override
  Future<bool> write(String key, String value) async {
    try {
      final Object? ok = await _channel
          .invokeMethod<Object?>('write', <String, Object?>{'key': key, 'value': value});
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      await _channel.invokeMethod<Object?>('remove', <String, Object?>{'key': key});
    } catch (_) {
      // 删除失败等价于"值还在"：下一次读回会拿到旧值，面板不会撒谎。
    }
  }

  @override
  Future<BasicSettingsPackageInfo> packageInfo() async {
    try {
      final Object? raw = await _channel.invokeMethod<Object?>('packageInfo');
      if (raw is! Map) {
        return BasicSettingsPackageInfo.unknown;
      }
      return BasicSettingsPackageInfo(
        packageName: raw['packageName'] is String ? raw['packageName']! as String : '',
        versionName: raw['versionName'] is String ? raw['versionName']! as String : '',
        versionCode: raw['versionCode'] is int ? raw['versionCode']! as int : 0,
        debuggable: raw['debuggable'] == true,
      );
    } catch (_) {
      return BasicSettingsPackageInfo.unknown;
    }
  }

  @override
  Future<bool> openUrl(String url) async {
    try {
      final Object? ok =
          await _channel.invokeMethod<Object?>('openUrl', <String, Object?>{'url': url});
      return ok == true;
    } catch (_) {
      return false;
    }
  }
}

/// 测试/桌面预览用的内存端口：行为与真实端口一致（含失败注入）。
/// 用 Flutter 官方 **shared_preferences** 真实落盘（2026-11-16 用户直接指示）。
///
/// 键就是完整 `<prefix><panel key>`（与 Qt/src/Host.cpp:1075 的 `"panel/" + key`
/// 同一字符串），值一律字符串：shared_preferences 不做类型转换，bool/number
/// 的解释仍归调用方，和 Qt 的 QSettings 契约一致。
///
/// 为什么不复用 [MethodChannelBasicSettingsPort] 的 `write`：真机上那条通道
/// 返回失败（设备实测横幅「写入失败：archive-mask-strength 未能保存（仍是 55）」），
/// 而 shared_preferences 是官方插件、由 GeneratedPluginRegistrant 保证注册。
/// `packageInfo` / `openUrl` 仍然走原通道：它们不是持久化，不需要换实现。
class SharedPreferencesBasicSettingsPort implements BasicSettingsPort {
  SharedPreferencesBasicSettingsPort({
    Future<SharedPreferences> Function()? preferences,
    MethodChannelBasicSettingsPort? host,
  })  : _preferences = preferences ?? SharedPreferences.getInstance,
        _host = host ?? MethodChannelBasicSettingsPort();

  final Future<SharedPreferences> Function() _preferences;
  final MethodChannelBasicSettingsPort _host;

  @override
  Future<Map<String, String>> readAll() async {
    try {
      final SharedPreferences prefs = await _preferences();
      final Map<String, String> out = <String, String>{};
      for (final String key in prefs.getKeys()) {
        if (!key.startsWith(basicSettingsPreferencePrefix)) {
          continue;
        }
        final Object? value = prefs.get(key);
        if (value is String) {
          out[key] = value;
        }
      }
      return out;
    } catch (_) {
      // 读不到就当没有已存值：与 Qt 的"缺键给空串"同一语义，不编默认值。
      return const <String, String>{};
    }
  }

  @override
  Future<bool> write(String key, String value) async {
    // 只接受完整 `panel/<裸键>`：裸键写进去也永远读不出来（readAll 只收前缀键），
    // 那是"看起来存了、其实丢了"，宁可如实拒绝。
    if (!key.startsWith(basicSettingsPreferencePrefix)) {
      return false;
    }
    try {
      final SharedPreferences prefs = await _preferences();
      final bool ok = await prefs.setString(key, value);
      if (!ok) {
        // shared_preferences 会先把值写进内存缓存再落盘；落盘失败时缓存里已经"有值"，
        // 同进程的 readAll 会把没存住的值报成已存。这里按官方 API 重新读一次盘，
        // 让内存与本 APK 的真实落盘状态一致（失败就是失败，不假装成功）。
        await prefs.reload();
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      final SharedPreferences prefs = await _preferences();
      await prefs.remove(key);
    } catch (_) {
      // 删不存在的键不算错；删失败也不假装成功（读回自然还是旧值）。
    }
  }

  @override
  Future<BasicSettingsPackageInfo> packageInfo() => _host.packageInfo();

  @override
  Future<bool> openUrl(String url) => _host.openUrl(url);
}

class MemoryBasicSettingsPort implements BasicSettingsPort {
  MemoryBasicSettingsPort({
    Map<String, String>? values,
    this.package = BasicSettingsPackageInfo.unknown,
    this.failWrites = false,
    this.failReads = false,
  }) : values = <String, String>{...?values};

  final Map<String, String> values;
  BasicSettingsPackageInfo package;

  /// true 时 [write] 返回 false 且不改内容（模拟 commit 失败）。
  bool failWrites;

  /// true 时 [readAll] 返回空表（模拟通道不可用）。
  bool failReads;

  /// 记录 openUrl 调用，测试断言"确实请求了真实 URL"。
  final List<String> openedUrls = <String>[];

  @override
  Future<Map<String, String>> readAll() async =>
      failReads ? const <String, String>{} : Map<String, String>.from(values);

  @override
  Future<bool> write(String key, String value) async {
    if (failWrites) {
      return false;
    }
    values[key] = value;
    return true;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }

  @override
  Future<BasicSettingsPackageInfo> packageInfo() async => package;

  @override
  Future<bool> openUrl(String url) async {
    openedUrls.add(url);
    return true;
  }
}

/// 一次加载的结果：面板要的三样真值（快照 / 版本 / 包信息）一起给。
class BasicSettingsLoad {
  const BasicSettingsLoad({
    required this.snapshot,
    required this.package,
    required this.raw,
  });

  final SettingsPreferenceSnapshot snapshot;
  final BasicSettingsPackageInfo package;

  /// 原始 `panel/<key>` 表（键含前缀，值逐字），供真实生效路径复用。
  final Map<String, String> raw;

  BasicSettingsVersion? get version => package.version;

  /// 原始表里取一个 panel key 的已存值；缺键给空串（与 Host::preference 一致）。
  String value(String panelKey) => raw['$basicSettingsPreferencePrefix$panelKey'] ?? '';
}

/// 设置面板落在 `panel/<key>`（Qt/src/Host.cpp:1075），与既有 HUD 偏好同一键空间。
const String basicSettingsPreferencePrefix = 'panel/';

/// 把 `panel/<key>` 原始表收敛成 [SettingsPreferenceSnapshot]（默认值取 Qt 真值表）。
SettingsPreferenceSnapshot basicSettingsSnapshotFrom(
  Map<String, String> raw, {
  bool dark = true,
}) {
  String value(String key) => raw['$basicSettingsPreferencePrefix$key'] ?? '';
  bool flag(String key, {required bool fallback}) {
    final String text = value(key).trim().toLowerCase();
    if (text == 'on' || text == 'true' || text == '1') {
      return true;
    }
    if (text == 'off' || text == 'false' || text == '0') {
      return false;
    }
    return fallback;
  }

  int intValue(String key, int fallback) {
    final String text = value(key).trim();
    final int? parsed = int.tryParse(text);
    return parsed ?? fallback;
  }

  final String theme = value('theme');
  final String quality = value('quality');
  return SettingsPreferenceSnapshot(
    preferences: <String, String>{
      for (final MapEntry<String, String> entry in raw.entries)
        if (entry.key.startsWith(basicSettingsPreferencePrefix))
          entry.key.substring(basicSettingsPreferencePrefix.length): entry.value,
    },
    // 面板显示"当前生效"的配色：只有显式存过 'dark' 才是暗色，缺键（以及旧版本
    // 残留的 'system'）一律算亮色——这是本项目的默认配色，没有系统亮度检测。
    themeMode: theme == 'dark' ? 'dark' : 'light',
    reducedMotion: flag('motion', fallback: false),
    startupAnimation: flag('startup-animation', fallback: false),
    discRotation: flag('disc-rotation', fallback: false),
    // 垂直同步默认关闭、右侧画面遮罩默认 0（用户 2026-11-19 指定的出厂默认）。
    vsync: flag('vsync', fallback: false),
    archiveMaskStrength: intValue('archive-mask-strength', 0),
    quality: quality.isEmpty ? 'lossless' : quality,
    alternative: flag('alternative', fallback: false),
    officialPlayerActive: false,
  );
}

/// 设置读写器：只经由 [PreferenceStore]（白名单 + 长度上限 + 离线语义都在那里）。
class BasicSettingsStore {
  BasicSettingsStore({required BasicSettingsPort port, bool offline = false})
      : _port = port,
        _preferences = PreferenceStore(port: _PortAdapter(port), offline: offline);

  final BasicSettingsPort _port;
  final PreferenceStore _preferences;

  BasicSettingsPort get port => _port;

  Future<BasicSettingsLoad> load({bool dark = false}) async {
    final Map<String, String> raw = await _port.readAll();
    return BasicSettingsLoad(
      snapshot: basicSettingsSnapshotFrom(raw, dark: dark),
      package: await _port.packageInfo(),
      raw: raw,
    );
  }

  /// 写一个 panel key（前缀由 [PreferenceStore] 自己加：它的白名单是**裸键**，
  /// 传 `panel/xxx` 会被当成未知键直接丢弃——Qt/src/Host.cpp:1107 的白名单也是裸键）。
  /// 返回真实结果：false = 没落盘。
  Future<bool> write(String panelKey, String value) =>
      _preferences.write(panelKey, value);

  Future<void> remove(String panelKey) => _preferences.remove(panelKey);

  Future<String> read(String panelKey) => _preferences.read(panelKey);

  Future<bool> openUrl(String url) => _port.openUrl(url);
}

/// PreferenceStore 要的是 [PreferencePort]；本适配器把 KeyValue 端口桥过去，
/// 并且**保留异常语义**（PreferenceStore 自己会把异常收敛成 false/''）。
class _PortAdapter implements PreferencePort {
  const _PortAdapter(this._port);

  final BasicSettingsPort _port;

  @override
  Future<String?> read(String key) async {
    final Map<String, String> all = await _port.readAll();
    return all[key];
  }

  @override
  Future<void> write(String key, String value) async {
    final bool ok = await _port.write(key, value);
    if (!ok) {
      throw StateError('settings write rejected: $key');
    }
  }

  @override
  Future<void> remove(String key) => _port.remove(key);
}
