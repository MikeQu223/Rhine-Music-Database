/// 插件根目录解析（PLUGIN-1）。
///
/// 权威源：`android/app/src/main/kotlin/rhine/music/database/porting/MediaSessionChannel.kt`
/// 的 `pluginDir()` —— `/sdcard/Android/data/<pkg>/file/plugin`，拿不到外部卷时退回
/// `<filesDir>/plugins`。Dart 侧只负责把那个路径拿到手并按需建子目录，绝不自造路径。
///
/// 为什么不用 Qt 的 `<AppLocalDataLocation>/plugins`：那是 `/data/user/0/<pkg>/files`，
/// 用户在文件管理器里既看不到也拷不进去；插件需要「放进目录即安装」这种可操作路径。
///
/// 三层回退（顺序固定，便于排障）：
///  1. 平台通道 `pluginDir()`（真机唯一正确来源）；
///  2. 环境变量 `RHINE_PLUGIN_DIR`（测试与桌面调试）；
///  3. 常见候选路径逐个试写（`flutter test` 与没有通道的宿主）；
/// 全失败时 [resolve] 返回 null，调用方必须如实显示「插件目录不可用」而不是抛异常。
library;

import 'dart:io';

import 'package:flutter/services.dart';

import '../platform/media_session.dart';

/// 用户插件根目录（可写），拿不到则 null。
///
/// [probe] 为 true 时才做候选路径试写；测试可以传 false 只走通道/环境变量。
Future<Directory?> resolvePluginRoot({
  MethodChannel? channel,
  bool probe = true,
}) async {
  final String? fromEnvironment = Platform.environment['RHINE_PLUGIN_DIR'];
  if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
    final Directory dir = Directory(fromEnvironment);
    if (await _ensureWritable(dir)) {
      return dir;
    }
  }
  final String? fromPlatform = await _platformPluginDir(channel);
  if (fromPlatform != null && fromPlatform.isNotEmpty) {
    final Directory dir = Directory(fromPlatform);
    if (await _ensureWritable(dir)) {
      return dir;
    }
  }
  if (!probe) {
    return null;
  }
  for (final String candidate in _candidatePaths()) {
    final Directory dir = Directory(candidate);
    if (await _ensureWritable(dir)) {
      return dir;
    }
  }
  return null;
}

/// 平台通道查询；异常（桌面/测试没有实现）与 null 一律当作「没有」。
Future<String?> _platformPluginDir(MethodChannel? channel) async {
  try {
    final MethodChannel target = channel ?? const MethodChannel(mediaSessionMethodChannelName);
    final String? path = await target.invokeMethod<String>('pluginDir');
    return path;
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// 兜底候选：先从 app-specific 外部目录猜，再退到私有目录（只用于无通道环境）。
Iterable<String> _candidatePaths() sync* {
  const String packageName = 'rhine.music.database';
  for (final String external in <String>[
    '/storage/emulated/0',
    '/sdcard',
    '/storage/self/primary',
  ]) {
    yield '$external/Android/data/$packageName/file/plugin';
  }
  yield '/data/user/0/$packageName/files/plugins';
  yield '/data/data/$packageName/files/plugins';
}

/// 建目录 + 写探针，确认真的可写（只 isDirectory 不够：外部卷会给出只读假目录）。
Future<bool> _ensureWritable(Directory dir) async {
  try {
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    final File probe = File('${dir.path}/.write-probe');
    await probe.writeAsString('1', flush: true);
    await probe.delete();
    return true;
  } on FileSystemException {
    return false;
  }
}
