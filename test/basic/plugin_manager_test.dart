import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/plugin/plugin_manager.dart';
import 'package:rhine_music_database/plugin/plugin_models.dart';

/// 一份合法的插件 manifest（`Qt/src/ProviderRegistry.cpp:29-55` 的必填项）。
Map<String, Object?> _manifest(String id, String version, {String entry = 'plugin.cjs'}) {
  return <String, Object?>{
    'schemaVersion': 2,
    'apiVersion': '2.0',
    'id': id,
    'version': version,
    'entry': <String, Object?>{'file': entry},
    'display': <String, Object?>{'name': '测试插件 $id'},
    'capabilities': <String, Object?>{'search': true},
  };
}

/// 在 [root] 下铺一个插件目录（目录名可指定，用来模拟 `.backup-<id>`）。
Future<Directory> _pluginDir(
  Directory root,
  String id,
  Map<String, Object?> manifest, {
  String? dirName,
}) async {
  final Directory dir = Directory('${root.path}/${dirName ?? id}');
  await dir.create(recursive: true);
  await File('${dir.path}/manifest.json').writeAsString(jsonEncode(manifest));
  final Object? entry = (manifest['entry'] as Map<Object?, Object?>?)?['file'];
  if (entry is String && entry.isNotEmpty) {
    await File('${dir.path}/$entry').writeAsString('module.exports = {};\n');
  }
  return dir;
}

PluginManager _manager(Directory root) {
  return PluginManager(
    rootResolver: () async => root,
    // 测试不联网：地址只用于状态行文案，不会真的去请求。
    marketUrl: 'https://example.invalid/index.json',
  );
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rhine-plugin-test');
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  group('manifest 校验沿用 Host 文案', () {
    test('合法 manifest 解析出 id/版本/入口/能力数', () {
      final PluginManifest manifest = parsePluginManifest(_manifest('netease', '2.1.1'));
      expect(manifest.id, 'netease');
      expect(manifest.version, '2.1.1');
      expect(manifest.entryFile, 'plugin.cjs');
      expect(manifest.capabilities.length, 1);
      expect(manifest.label, '测试插件 netease');
    });

    test('schemaVersion / apiVersion / 入口非法时给出对应拒绝串', () {
      expect(
        () => parsePluginManifest(<String, Object?>{..._manifest('netease', '2.1.1'), 'schemaVersion': 1}),
        throwsA(isA<PluginManifestError>().having((PluginManifestError e) => e.message, 'message',
            '插件 manifest 版本不受支持')),
      );
      expect(
        () => parsePluginManifest(<String, Object?>{..._manifest('netease', '2.1.1'), 'apiVersion': '3.0'}),
        throwsA(isA<PluginManifestError>().having(
            (PluginManifestError e) => e.message, 'message', '插件 API 版本不兼容')),
      );
      expect(
        () => parsePluginManifest(_manifest('netease', '2.1.1', entry: '../evil.cjs')),
        throwsA(isA<PluginManifestError>()
            .having((PluginManifestError e) => e.message, 'message', '插件入口无效')),
      );
    });

    test('保留 id 与非法 id 被拒绝', () {
      expect(
        () => parsePluginManifest(_manifest('siren', '1.0.0')),
        throwsA(isA<PluginManifestError>()
            .having((PluginManifestError e) => e.message, 'message', '插件 id 为保留 id')),
      );
      expect(
        () => parsePluginManifest(_manifest('Netease', '1.0.0')),
        throwsA(isA<PluginManifestError>()
            .having((PluginManifestError e) => e.message, 'message', '插件 id 无效')),
      );
    });

    test('版本比较按段比数字，更新标记依赖它', () {
      expect(comparePluginVersion('2.1.1', '2.1.0'), greaterThan(0));
      expect(comparePluginVersion('2.0.10', '2.0.9'), greaterThan(0));
      expect(comparePluginVersion('2.1.1', '2.1.1'), 0);
      expect(comparePluginVersion('1.0.0', '2.0.0'), lessThan(0));
    });

    test('市场条目的 files[] 支持字符串与 {path} 两种写法', () {
      final MarketPluginEntry? entry = parseMarketEntry(<String, Object?>{
        'id': 'netease',
        'name': '网易云音乐',
        'version': '2.1.1',
        'path': 'plugins/netease',
        'entry': <String, Object?>{'file': 'plugin.cjs'},
        'files': <Object?>['plugin.cjs', <String, Object?>{'path': 'xhr-sync-worker.js'}],
      });
      expect(entry, isNotNull);
      expect(entry!.files, <String>['plugin.cjs', 'xhr-sync-worker.js']);
      expect(entry.entryFile, 'plugin.cjs');
    });
  });

  group('镜像回退链（用户指定顺序）', () {
    test('六级顺序固定：直连 → gh-proxy → v4 → v6 → cdn → axisnow', () {
      expect(pluginMarketMirrorPrefixes, <String>[
        '',
        'https://gh-proxy.org/',
        'https://v4.gh-proxy.org/',
        'https://v6.gh-proxy.org/',
        'https://cdn.gh-proxy.org/',
        'https://axisnow.gh-proxy.org/',
      ]);
    });

    test('域名标签：直连写成 github.com（直连），代理去掉协议与尾斜杠', () {
      expect(pluginMirrorLabel(''), 'github.com（直连）');
      expect(pluginMirrorLabel('https://gh-proxy.org/'), 'gh-proxy.org');
      expect(pluginMirrorLabel('https://axisnow.gh-proxy.org/'), 'axisnow.gh-proxy.org');
    });

    test('回退窗口是 200ms（用户要求「每 200ms 无响应回退到下一级」）', () {
      expect(pluginMirrorResponseWindow, const Duration(milliseconds: 200));
    });

    test('初始快照没有当前域名也没有未响应域名', () async {
      final PluginManager manager = _manager(root);
      await manager.initialize();
      final PluginSnapshot snapshot = manager.snapshot();
      expect(snapshot.activeHost, isEmpty);
      expect(snapshot.deadHosts, isEmpty);
      expect(snapshot.mirrors, hasLength(pluginMarketMirrorPrefixes.length));
    });
  });

  group('磁盘状态', () {
    test('扫目录认出已装插件，禁用写进 plugins-state.json 且重启后仍禁用', () async {
      await _pluginDir(root, 'netease', _manifest('netease', '2.1.1'));
      final PluginManager manager = _manager(root);
      await manager.initialize();

      expect(manager.installed.map((InstalledPlugin p) => p.manifest.id), <String>['netease']);
      expect(manager.installed.single.enabled, isTrue);
      expect(manager.userPluginsRoot, root.path);

      await manager.setEnabled('netease', false);
      expect(manager.message, '已禁用插件');
      final Object? state = jsonDecode(await File('${root.path}/plugins-state.json').readAsString());
      expect(state, <String, Object?>{
        'disabled': <String>['netease'],
      });

      final PluginManager restarted = _manager(root);
      await restarted.initialize();
      expect(restarted.installed.single.enabled, isFalse);
      expect(restarted.enabled('netease'), isFalse);
    });

    test('回滚把 .backup-<id> 提为当前版本，之后没有可回滚版本', () async {
      await _pluginDir(root, 'netease', _manifest('netease', '2.1.1'));
      await _pluginDir(root, 'netease', _manifest('netease', '2.0.9'), dirName: '.backup-netease');
      final PluginManager manager = _manager(root);
      await manager.initialize();

      expect(manager.hasRollback('netease'), isTrue);
      final String refusal = await manager.rollback('netease');
      expect(refusal, isEmpty);
      expect(manager.message, '插件已回滚');
      expect(manager.installed.single.manifest.version, '2.0.9');
      expect(manager.hasRollback('netease'), isFalse);
      expect(Directory('${root.path}/.backup-netease').existsSync(), isFalse);
      // 回滚失败一次也要给出 Qt 的拒绝串。
      expect(await manager.rollback('netease'), '没有可回滚的版本');
    });

    test('卸载删除插件目录、备份与禁用记录', () async {
      await _pluginDir(root, 'netease', _manifest('netease', '2.1.1'));
      await _pluginDir(root, 'netease', _manifest('netease', '2.0.9'), dirName: '.backup-netease');
      final PluginManager manager = _manager(root);
      await manager.initialize();
      await manager.setEnabled('netease', false);

      expect(await manager.uninstall('netease'), isEmpty);
      expect(manager.installed, isEmpty);
      expect(Directory('${root.path}/netease').existsSync(), isFalse);
      expect(Directory('${root.path}/.backup-netease').existsSync(), isFalse);
      expect(manager.enabled('netease'), isTrue);
      expect(await manager.uninstall('netease'), '插件未安装');
    });

    test('目录不可用时给出 Host 文案且不炸', () async {
      final PluginManager manager = PluginManager(
        rootResolver: () async => null,
        marketUrl: 'https://example.invalid/index.json',
      );
      await manager.initialize();
      expect(manager.status, '插件目录不可用');
      expect(manager.installed, isEmpty);
      expect(await manager.rollback('netease'), '插件目录不可用');
      expect(manager.hasRollback('netease'), isFalse);
    });
  });
}
