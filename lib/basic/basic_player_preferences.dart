/// 播放器的同步偏好桥（`MusicPlayer` 的 [PreferencePort] → 设置端口的异步落盘）。
///
/// 为什么需要这一层：`MusicPlayer` 在**构造时**同步读回偏好
/// （`lib/domain/player/music_player.dart` 的 `_seedHistory` / `_seedMode`），而设置端口
/// [BasicSettingsPort] 只有异步 API（`readAll` / `write`）。两者之间要有个内存镜像：
///
///  - [seed]：设置加载完成后把 `panel/<key>` 灌进镜像（镜像里是**裸键**）；
///  - [write]：同步更新镜像，落盘交给异步端口，写失败不反噬播放状态。
///
/// 为什么不经 `PreferenceStore`：播放器写的两个键里只有 `play-history` 在白名单
/// （`lib/data/storage/preference_store.dart` 的 `panelKeys`，被测试逐项锁死），
/// `play-mode` 会被白名单直接丢弃；而端口侧的 `readAll` 只按 `panel/` 前缀收值。
/// 直写端口既存得进也读得回，且与 `panel/play-history` 落在同一键空间。
library;

import 'dart:async';

import '../domain/player/music_player.dart' show PreferencePort;
import 'basic_settings_store.dart' show BasicSettingsPort, basicSettingsPreferencePrefix;

/// 播放器窄偏好的同步实现（内存镜像 + 端口异步落盘）。
class BasicPlayerPreferences implements PreferencePort {
  BasicPlayerPreferences(this._port);

  final BasicSettingsPort _port;

  /// 裸键 → 值。初始为空，[seed] 之后才有内容。
  final Map<String, String> _values = <String, String>{};

  /// 待落盘的写（测试可等它，生产不关心）。
  final List<Future<void>> _pending = <Future<void>>[];

  /// 把端口读到的 `panel/<key>` 表灌进镜像（设置加载后调用一次）。
  ///
  /// 只收字符串值并以裸键存：与 Qt `Host::preference("panel/" + key)` 的读口径一致。
  void seed(Map<String, String> raw) {
    for (final MapEntry<String, String> entry in raw.entries) {
      final String key = entry.key;
      if (!key.startsWith(basicSettingsPreferencePrefix)) {
        continue;
      }
      _values[key.substring(basicSettingsPreferencePrefix.length)] = entry.value;
    }
  }

  @override
  String read(String key) => _values[key] ?? '';

  @override
  void write(String key, String value) {
    _values[key] = value;
    // 落盘是尽力而为：写失败时内存值仍然生效（本会话内一致），下一次启动读回的
    // 是旧值——不假装成功，也不让一次失败的写打断播放。
    final Future<void> pending = _port
        .write('$basicSettingsPreferencePrefix$key', value)
        .then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _pending.add(pending);
  }

  /// 等所有已发起的写落盘（测试用；生产不调用）。
  Future<void> flush() async {
    final List<Future<void>> pending = List<Future<void>>.of(_pending);
    _pending.clear();
    await Future.wait<void>(pending);
  }

  /// 镜像里某个裸键的值（测试与诊断用）。
  String mirror(String key) => _values[key] ?? '';

  /// 当前镜像里存过的偏好键（不含值，测试用）。
  Iterable<String> get knownKeys => _values.keys;
}
