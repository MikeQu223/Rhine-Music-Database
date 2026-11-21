import 'dart:convert';
import 'dart:io';

import '../plugin/plugin_models.dart' show InstalledPlugin;

/// Qt 侧 `ProviderRegistry` 的插件扫描目录（相对 Qt 的 `root`）。
///
/// `Qt/src/ProviderRegistry.cpp:78-79` 只扫两处：
/// `<root>/MusicBridge/plugins/descriptors` 与 `<root>/MusicBridge/local-plugins`。
/// 这里的 `root` 是 `Qt/src/main.cpp:964` 的 `RHINE_RESOURCES`，也就是 Android 上的
/// `<files>/resources`（Qt 的 `AndroidAssets` 解包目录），**不是** `AppStorage::dataDirectory()`。
const String qtPluginDescriptorDirectory = 'MusicBridge/local-plugins';

/// 把已启用插件的 manifest 同步进 Qt 的扫描目录，返回写成功的平台数。
///
/// 为什么需要这一步：Qt 的 `Host::loadCover`（`Qt/src/Host.cpp:2205-2221`）用
/// `ProviderRegistry::coverHosts()` 做封面域名白名单，而这份白名单来自 Qt 自己
/// 扫到的 descriptor。Flutter 的插件装在 `<external>/file/plugin`，Qt 完全不知道
/// 它们存在，于是插件曲目的封面被静默拒绝（真机日志 `RHINE_QT_COVER_RESULT
/// len=0 key=`，3D 唱片只剩灰盘）。把 manifest 软链过去，Qt 就能拿到
/// `media.coverHosts`、平台名与列定义。
///
/// 只写 descriptor 需要的东西：`manifest.json` 与一个真实存在的入口文件
/// （Qt `validManifest` 会校验 `entry.file` 能打开）。入口用软链，软链不被支持时
/// 退回同名占位文件——Qt 只校验存在性，真正跑插件的是 Flutter 侧那份。
///
/// 注意：Qt 的 registry 只在引擎启动时装载一次，所以新增/禁用插件后需要重启
/// 应用才会反映到封面白名单上。
Future<int> syncQtPluginDescriptors({
  required String resourcesRoot,
  required String pluginRoot,
  required List<InstalledPlugin> installed,
}) async {
  if (resourcesRoot.isEmpty || pluginRoot.isEmpty) {
    return 0;
  }
  final Directory target = Directory('$resourcesRoot/$qtPluginDescriptorDirectory');
  final Set<String> keep = <String>{};
  int written = 0;
  try {
    if (!target.existsSync()) {
      target.createSync(recursive: true);
    }
    for (final InstalledPlugin plugin in installed) {
      if (!plugin.enabled) {
        continue;
      }
      final String id = plugin.manifest.id;
      if (id.isEmpty || id == 'siren' || id == 'local') {
        continue;
      }
      final Directory dir = Directory('${target.path}/$id');
      dir.createSync(recursive: true);
      final File source = File('$pluginRoot/$id/manifest.json');
      final String manifest = source.existsSync()
          ? source.readAsStringSync()
          : jsonEncode(plugin.manifest.raw);
      File('${dir.path}/manifest.json').writeAsStringSync(manifest);
      final String entry = plugin.manifest.entryFile;
      if (entry.isNotEmpty) {
        final String entryPath = '${dir.path}/$entry';
        final bool exists = File(entryPath).existsSync() || Link(entryPath).existsSync();
        if (!exists) {
          try {
            Link(entryPath).createSync('$pluginRoot/$id/$entry');
          } on FileSystemException {
            // 外部存储不支持软链时退回占位文件：Qt 只校验入口存在。
            File(entryPath).writeAsStringSync('');
          }
        }
      }
      keep.add(id);
      written++;
    }
    // 卸载或禁用的插件必须撤掉，否则 Qt 仍认它的封面域名。
    for (final FileSystemEntity entity in target.listSync()) {
      if (entity is! Directory) {
        continue;
      }
      final String name = entity.path.split(Platform.pathSeparator).last;
      if (keep.contains(name)) {
        continue;
      }
      try {
        entity.deleteSync(recursive: true);
      } on FileSystemException {
        // 删不掉就留着，下一次同步再试。
      }
    }
  } on FileSystemException {
    return written;
  }
  return written;
}
