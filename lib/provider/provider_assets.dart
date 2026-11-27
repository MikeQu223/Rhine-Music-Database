import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:rhine_music_database/provider/provider_descriptor.dart';
import 'package:rhine_music_database/provider/provider_registry.dart';

/// 平台注册表的 Flutter 侧装载器：把内置 descriptor 读进 [ProviderRegistry]。
///
/// 数据来源分两路（与 Qt `ProviderRegistry::load` 的优先级一致）：
/// 1. 构建期内置 descriptor：`pubspec.yaml` 声明的 `MusicBridge/plugins/descriptors/`；
/// 2. 用户插件 manifest：`PluginManager` 扫到的已安装插件（由调用方传入，本类不碰文件系统）。
///
/// 本文件是**唯一**允许 import `flutter/services.dart` 的地方（读 assets）；
/// 纯数据逻辑全在 [ProviderDescriptor] / [ProviderRegistry]，可以脱离 Flutter 测试。
class ProviderAssetLoader {
  ProviderAssetLoader({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;

  /// 内置 descriptor 的 asset 路径（`pubspec.yaml` 里整目录声明，按文件名读）。
  static const String builtinDescriptorDirectory = 'MusicBridge/plugins/descriptors';

  /// 内置 descriptor 的 id 列表（与 `MusicBridge/plugins/descriptors/` 下的文件名一致）。
  static const List<String> builtinIds = <String>['siren', 'local'];

  /// 读一份 JSON asset；缺失返回 null（Qt 里缺 descriptor 也只是少一个平台，不崩）。
  Future<Map<String, Object?>?> readJson(String assetPath) async {
    try {
      final String text = await _bundle.loadString(assetPath);
      final Object? decoded = jsonDecode(text);
      return decoded is Map<String, Object?> ? decoded : null;
    } on Object {
      return null;
    }
  }

  /// 读全部内置 descriptor（顺序固定，解析失败项跳过并回报）。
  Future<List<Map<String, Object?>>> readBuiltins({void Function(String id, String reason)? onRejected}) async {
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    for (final String id in builtinIds) {
      final Map<String, Object?>? json = await readJson('$builtinDescriptorDirectory/$id.json');
      if (json == null) {
        onRejected?.call(id, '内置平台描述符缺失');
        continue;
      }
      out.add(json);
    }
    return out;
  }

  /// 装载注册表：内置 descriptor + 用户插件 manifest（后者来自 `PluginManager` 的已安装列表）。
  Future<ProviderRegistry> load({
    Iterable<Map<String, Object?>> userManifests = const <Map<String, Object?>>[],
    Set<String> disabled = const <String>{},
    void Function(String id, String reason)? onRejected,
  }) async {
    final List<Map<String, Object?>> builtins = await readBuiltins(onRejected: onRejected);
    return ProviderRegistry.load(
      builtins: builtins,
      userManifests: userManifests,
      disabled: disabled,
      onRejected: onRejected,
    );
  }

  /// 平台列表里给 UI 用的角色判断（内置 / 用户插件）。
  static bool isBuiltin(ProviderDescriptor descriptor) => builtinIds.contains(descriptor.id);
}
