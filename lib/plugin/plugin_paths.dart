/// 插件根目录解析（PLUGIN-1）。权威源是宿主 `pluginDir()`，Dart 侧不自造路径。
///
/// 三层回退：平台通道 → 环境变量 `RHINE_PLUGIN_DIR` → 常见候选路径试写。
/// 全失败返回 null，调用方如实显示「插件目录不可用」。
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
