// T01 基线出处 manifest 断言（T01-F01 fixture + T01-T01 测试）。
//
// 状态：**已编写、未执行**。本 atom 的禁令不允许 flutter test / dart analyze /
// 任何构建，因此本文件只固化断言，不得被报告为"通过"。获准执行时的命令：
//   flutter test test/baseline_manifest_test.dart
//
// 字段契约来源：docs/flutter-migration/00-baseline.md §12.1（顶层键）与
// §12.2（断言清单）；事实值来源同文件的 §1-§9 与 evidence/ 下原始输出。
//
// 本测试只读 test/fixtures/baseline_manifest.json：不生成路径、快照、像素或
// 安装结论，也不访问设备、APK、网络。
//
// 依赖说明：任务书写的是 package:test，但仓库 pubspec.yaml 的 dev_dependencies
// 只有 flutter_test（无 test 条目），package:test 无法解析；经父 agent 裁决改用
// package:flutter_test/flutter_test.dart，未改动 pubspec。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _fixturePath = 'test/fixtures/baseline_manifest.json';

final RegExp _hex12 = RegExp(r'^[0-9a-f]{12}$');
final RegExp _hex16 = RegExp(r'^[0-9a-f]{16}$');
final RegExp _hex40 = RegExp(r'^[0-9a-f]{40}$');
final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');
final RegExp _sha256ColonUpper = RegExp(r'^([0-9A-F]{2}:){31}[0-9A-F]{2}$');
final RegExp _sha1ColonUpper = RegExp(r'^([0-9A-F]{2}:){19}[0-9A-F]{2}$');

Map<String, dynamic> _object(Map<String, dynamic> parent, String key) {
  final Object? value = parent[key];
  expect(value, isA<Map>(), reason: '$key 必须是 JSON 对象');
  return (value! as Map).cast<String, dynamic>();
}

List<dynamic> _array(Map<String, dynamic> parent, String key) {
  final Object? value = parent[key];
  expect(value, isA<List>(), reason: '$key 必须是 JSON 数组');
  return value! as List<dynamic>;
}

String _text(Map<String, dynamic> parent, String key, {String label = ''}) {
  final String where = label.isEmpty ? key : '$label.$key';
  final Object? value = parent[key];
  expect(value, isA<String>(), reason: '$where 必须是字符串');
  final String text = value! as String;
  expect(text.trim(), isNotEmpty, reason: '$where 不得为空');
  return text;
}

int _int(Map<String, dynamic> parent, String key, {String label = ''}) {
  final String where = label.isEmpty ? key : '$label.$key';
  final Object? value = parent[key];
  expect(value, isA<int>(), reason: '$where 必须是整数');
  return value! as int;
}

bool _bool(Map<String, dynamic> parent, String key, {String label = ''}) {
  final String where = label.isEmpty ? key : '$label.$key';
  final Object? value = parent[key];
  expect(value, isA<bool>(), reason: '$where 必须是布尔');
  return value! as bool;
}

void _matches(String value, RegExp pattern, String label) {
  expect(pattern.hasMatch(value), isTrue,
      reason: '$label 格式不符：$value');
}

Map<String, dynamic> _loadFixture() {
  final File file = File(_fixturePath);
  expect(file.existsSync(), isTrue, reason: 'fixture 缺失：$_fixturePath');
  final Object? decoded = jsonDecode(file.readAsStringSync());
  expect(decoded, isA<Map>(), reason: 'fixture 顶层必须是 JSON 对象');
  return (decoded! as Map).cast<String, dynamic>();
}

void main() {
  late Map<String, dynamic> manifest;

  setUpAll(() {
    manifest = _loadFixture();
  });

  group('§12.1 顶层契约', () {
    test('schemaVersion / task / generatedAt', () {
      expect(manifest['schemaVersion'], 1);
      expect(manifest['task'], 'T01');
      _matches(_text(manifest, 'generatedAt'), RegExp(r'^\d{4}-\d{2}-\d{2}$'),
          'generatedAt');
    });

    test('§12.1 必含顶层键齐全', () {
      const List<String> required = <String>[
        'schemaVersion',
        'task',
        'generatedAt',
        'repo',
        'worktree',
        'branch',
        'baselineCommit',
        'planHistoricalBaseline',
        'apk',
        'certificate',
        'qtSource',
        'buildIdentity',
        'nativeChain',
        'manifest',
        'device',
        'installation',
        'screenshots',
        'gaps',
        'pixelBaseline',
        'testExecution',
      ];
      for (final String key in required) {
        expect(manifest.containsKey(key), isTrue, reason: '缺少顶层键 $key');
      }
    });

    test('冻结坐标 repo / worktree / branch', () {
      expect(_text(manifest, 'repo'), '/home/aibeto/code/Rhine-Music-Database');
      expect(_text(manifest, 'worktree'),
          '.agents/parity-20261109/worktrees/OPS86-A27-T01BASE');
      expect(_text(manifest, 'branch'), 'flutter/ops86-t01-baseline');
    });

    test('baselineCommit 是 T01 冻结基线，worktreeBaseCommit 是本 atom 起点', () {
      final String baseline = _text(manifest, 'baselineCommit');
      _matches(baseline, _hex40, 'baselineCommit');
      expect(baseline, '8ed3067b0812eb2612f7841ec127a6e8ca93231b');

      final String historical = _text(manifest, 'planHistoricalBaseline');
      _matches(historical, _hex40, 'planHistoricalBaseline');
      expect(historical, '89493eb3c3d2c1e6c050891718134ac7670e4d6c');

      final String worktreeBase = _text(manifest, 'worktreeBaseCommit');
      _matches(worktreeBase, _hex40, 'worktreeBaseCommit');
      expect(worktreeBase, '708677579626f8eaeeef77e8588125ecadab4858');
      expect(worktreeBase, isNot(baseline),
          reason: 'T01 冻结基线与本 atom worktree 起点是两个字段，不得合并');
    });
  });

  group('§12.1 apk 与 §12.2 哈希/版本断言', () {
    test('必填非空、哈希 64 位小写十六进制、值与文档一致', () {
      final Map<String, dynamic> apk = _object(manifest, 'apk');
      final String path = _text(apk, 'path', label: 'apk');
      expect(path, endsWith('.apk'));
      expect(_text(apk, 'mtime', label: 'apk'), isNotEmpty);

      final String sha256 = _text(apk, 'sha256', label: 'apk');
      _matches(sha256, _hex64, 'apk.sha256');
      expect(sha256,
          'bd58d95a5edee4c66a9704a108fb335163dc4274239b5f32b2a0c4cb221b5a1e');

      expect(_int(apk, 'sizeBytes', label: 'apk'), 73776456);
      expect(_int(apk, 'topLevelApkCount', label: 'apk'), 1);
      expect(_text(apk, 'package', label: 'apk'), 'rhine.music.database');
      expect(_text(apk, 'versionName', label: 'apk'), '0.0.0');
      expect(_text(apk, 'abi', label: 'apk'), 'arm64-v8a');
    });

    test('versionCode >= 1，minSdk/targetSdk 为整数且 targetSdk >= minSdk', () {
      final Map<String, dynamic> apk = _object(manifest, 'apk');
      expect(_int(apk, 'versionCode', label: 'apk'), greaterThanOrEqualTo(1));
      final int minSdk = _int(apk, 'minSdk', label: 'apk');
      final int targetSdk = _int(apk, 'targetSdk', label: 'apk');
      expect(targetSdk, greaterThanOrEqualTo(minSdk));
      // 冻结实测值，防止"格式通过但产物被换掉"。
      expect(minSdk, 28);
      expect(targetSdk, 36);
    });
  });

  group('§12.1 certificate 与 §12.2 证书全值', () {
    test('两种 SHA256 写法一致且指向同一张证书', () {
      final Map<String, dynamic> cert = _object(manifest, 'certificate');
      final String sha256 = _text(cert, 'sha256', label: 'certificate');
      _matches(sha256, _sha256ColonUpper, 'certificate.sha256');

      final String compact = _text(cert, 'sha256Compact', label: 'certificate');
      _matches(compact, _hex64, 'certificate.sha256Compact');
      expect(sha256.replaceAll(':', '').toLowerCase(), compact);
      expect(compact,
          '39396cd06f2b7980302bad220ed071e09286540be4d224a2f9b047ca65205bdf');
    });

    test('SHA1/主体/签发者/序列号/有效期/算法/条目均非空且自洽', () {
      final Map<String, dynamic> cert = _object(manifest, 'certificate');
      _matches(_text(cert, 'sha1', label: 'certificate'), _sha1ColonUpper,
          'certificate.sha1');

      for (final String key in <String>['owner', 'issuer', 'serialNumber',
          'validFrom', 'validTo', 'signatureAlgorithm', 'publicKey', 'source']) {
        _text(cert, key, label: 'certificate');
      }
      expect(_text(cert, 'owner', label: 'certificate'),
          _text(cert, 'issuer', label: 'certificate'),
          reason: '文档记录为自签名证书，主体与签发者相同');
      expect(_text(cert, 'signatureAlgorithm', label: 'certificate'),
          'SHA384withRSA');
      expect(_text(cert, 'serialNumber', label: 'certificate'),
          'c72f9f0bf588afa3');
      // 证书身份可由 APK 直接证明；keystore/别名/口令仍属 G8，不在本 fixture 声称。
      expect(cert['signatureEntries'], isA<List<dynamic>>());
      final List<String> entries = (cert['signatureEntries']! as List<dynamic>)
          .map((dynamic e) => e! as String)
          .toList();
      expect(entries, <String>[
        'META-INF/MYKEY.RSA',
        'META-INF/MYKEY.SF',
        'META-INF/MANIFEST.MF',
      ]);
    });
  });

  group('§12.1 qtSource', () {
    test('候选 commit 与两棵 Qt 树完全相同', () {
      final Map<String, dynamic> qt = _object(manifest, 'qtSource');
      final String candidate = _text(qt, 'candidateCommit', label: 'qtSource');
      _matches(candidate, _hex40, 'qtSource.candidateCommit');
      expect(candidate, '01ee85b96feeac875660e963ff78fbd383da0ae5');

      expect(_text(qt, 'candidateCommitTitle', label: 'qtSource'),
          'feat: 新增双指平移手势处理逻辑');
      expect(_text(qt, 'candidateCommitTime', label: 'qtSource'),
          '2026-11-07T05:39:43+08:00');

      final String treeCandidate = _text(qt, 'qtTreeCandidate', label: 'qtSource');
      final String treeBaseline = _text(qt, 'qtTreeBaseline', label: 'qtSource');
      _matches(treeCandidate, _hex40, 'qtSource.qtTreeCandidate');
      _matches(treeBaseline, _hex40, 'qtSource.qtTreeBaseline');
      expect(treeCandidate, treeBaseline,
          reason: '候选 commit 与基线的 Qt tree ID 必须完全相同');
      expect(treeCandidate, '12da26f0b9163592a9f6b69a2a0df4c806c12e0b');

      expect(_int(qt, 'diffStatLines', label: 'qtSource'), 0);
      expect(_bool(qt, 'isAncestorOfBaseline', label: 'qtSource'), isTrue);
    });
  });

  group('§12.1 buildIdentity 与 §12.2 commitSha', () {
    test('commitSha 为 12 位十六进制且是候选 commit 前缀', () {
      final Map<String, dynamic> identity = _object(manifest, 'buildIdentity');
      final String commitSha = _text(identity, 'commitSha', label: 'buildIdentity');
      _matches(commitSha, _hex12, 'buildIdentity.commitSha');
      expect(commitSha, '01ee85b96fee');

      final Map<String, dynamic> qt = _object(manifest, 'qtSource');
      final String candidate = qt['candidateCommit']! as String;
      expect(candidate.startsWith(commitSha), isTrue,
          reason: '12 位短 SHA 必须能无歧义地指回 qtSource.candidateCommit');
      expect(_text(identity, 'commitTitle', label: 'buildIdentity'),
          _text(qt, 'candidateCommitTitle', label: 'qtSource'));
    });

    test('headerPath/headerBytes 与三处 payload 偏移', () {
      final Map<String, dynamic> identity = _object(manifest, 'buildIdentity');
      expect(_text(identity, 'headerPath', label: 'buildIdentity'),
          'output/android-build/BuildIdentity.h');
      expect(_int(identity, 'headerBytes', label: 'buildIdentity'), 204);

      final Map<String, dynamic> offsets =
          _object(identity, 'stringsInPayload');
      expect(_int(offsets, 'utf8ShaOffset', label: 'stringsInPayload'), 976021);
      expect(_int(offsets, 'utf16ShaOffset', label: 'stringsInPayload'), 1002496);
      expect(_int(offsets, 'utf16TitleOffset', label: 'stringsInPayload'),
          1001900);
    });
  });

  group('§12.1 nativeChain 与 §12.2 同值断言', () {
    test('三段 stage 齐全，哈希为 64 位小写十六进制', () {
      final List<Map<String, dynamic>> chain = _array(manifest, 'nativeChain')
          .map((dynamic e) => (e! as Map).cast<String, dynamic>())
          .toList();
      expect(chain, hasLength(3));
      expect(chain.map((Map<String, dynamic> e) => e['stage']).toList(),
          <String>['linked-unstripped', 'stripped-intermediate', 'apk-entry']);

      for (final Map<String, dynamic> stage in chain) {
        final String label =
            'nativeChain[${stage['stage']! as String}]';
        _text(stage, 'path', label: label);
        expect(_int(stage, 'sizeBytes', label: label), greaterThan(0));
        _matches(_text(stage, 'sha256', label: label), _hex64, '$label.sha256');
      }
    });

    test('stripped-intermediate 与 apk-entry 的 sha256/size 相同', () {
      final List<Map<String, dynamic>> chain = _array(manifest, 'nativeChain')
          .map((dynamic e) => (e! as Map).cast<String, dynamic>())
          .toList();
      final Map<String, dynamic> unstripped = chain.firstWhere(
          (Map<String, dynamic> e) => e['stage'] == 'linked-unstripped');
      final Map<String, dynamic> stripped = chain.firstWhere(
          (Map<String, dynamic> e) => e['stage'] == 'stripped-intermediate');
      final Map<String, dynamic> apkEntry = chain
          .firstWhere((Map<String, dynamic> e) => e['stage'] == 'apk-entry');

      expect(apkEntry['sha256'], stripped['sha256'],
          reason: 'APK 内 native 条目必须与 stripped 中间产物逐字节相同');
      expect(apkEntry['sizeBytes'], stripped['sizeBytes']);
      expect(stripped['sha256'],
          '3f50afc04508fac0d01647efb307efa73c6dc978fb71d79d85dd17f8967bf0cf');
      expect(unstripped['sha256'],
          '7790160fccdd004efc8efe230adce582ddbd67420d1125bcb2782322de0f9def');
      // strip 只摘尾部符号/调试节：未 strip 库必然更大。
      expect(_int(unstripped, 'sizeBytes', label: 'linked-unstripped'),
          149401128);
      expect(_int(stripped, 'sizeBytes', label: 'stripped-intermediate'),
          41535456);
      expect(apkEntry['path'], 'lib/arm64-v8a/libRhineMusicDatabase_arm64-v8a.so');
    });
  });

  group('§12.1 manifest 与 §12.2 四项精确匹配', () {
    test('sensorLandscape / allowBackup=false / resizeable=false / GLES3', () {
      final Map<String, dynamic> mf = _object(manifest, 'manifest');
      expect(_text(mf, 'sourcePath', label: 'manifest'),
          'Qt/android/AndroidManifest.xml');
      expect(_text(mf, 'mergedPath', label: 'manifest'),
          endsWith('processReleaseManifest/AndroidManifest.xml'));
      expect(_text(mf, 'screenOrientation', label: 'manifest'),
          'sensorLandscape');
      expect(_bool(mf, 'allowBackup', label: 'manifest'), isFalse);
      expect(_bool(mf, 'resizeableActivity', label: 'manifest'), isFalse);
      expect(_text(mf, 'glesVersion', label: 'manifest'), '0x00030000');
      expect(_bool(mf, 'glesRequired', label: 'manifest'), isTrue);
    });
  });

  group('§12.1 device', () {
    test('设备坐标非空且与设备报告一致', () {
      final Map<String, dynamic> device = _object(manifest, 'device');
      expect(_text(device, 'serial', label: 'device'), '526f6b6d');
      expect(_text(device, 'model', label: 'device'), 'OPD2511');
      expect(_text(device, 'androidVersion', label: 'device'), '16');
      expect(_int(device, 'apiLevel', label: 'device'), 36);
      expect(_text(device, 'abi', label: 'device'), 'arm64-v8a');
      expect(_int(device, 'density', label: 'device'), 315);
      expect(_text(device, 'physicalResolution', label: 'device'), '2880×1800');
      expect(_text(device, 'fingerprint', label: 'device'),
          'OPPO/OPD2511/OP6546L1:16/BP2A.250605.015/B.4a2d817-2503cdb-254d651:user/release-keys');
    });
  });

  group('§12.1 installation 与 §12.2 安装事实', () {
    test('安装前不存在、未卸载、未清数据、增量安装成功', () {
      final Map<String, dynamic> install = _object(manifest, 'installation');
      expect(_bool(install, 'preinstallPackageAbsent', label: 'installation'),
          isTrue);
      expect(_bool(install, 'incremental', label: 'installation'), isTrue);
      expect(_bool(install, 'success', label: 'installation'), isTrue);
      expect(_bool(install, 'uninstallPerformed', label: 'installation'),
          isFalse);
      expect(_bool(install, 'clearDataPerformed', label: 'installation'),
          isFalse);
      expect(_int(install, 'durationMs', label: 'installation'), greaterThan(0));
    });

    test('命令指向同一 APK 与同一设备，安装时间与包路径成立', () {
      final Map<String, dynamic> apk = _object(manifest, 'apk');
      final Map<String, dynamic> device = _object(manifest, 'device');
      final Map<String, dynamic> install = _object(manifest, 'installation');

      final String command = _text(install, 'command', label: 'installation');
      expect(command, contains(apk['path']! as String));
      expect(command, contains(device['serial']! as String));
      expect(command, contains('install'));

      final String first = _text(install, 'firstInstallTime', label: 'installation');
      final String last = _text(install, 'lastUpdateTime', label: 'installation');
      expect(first, last, reason: '首次安装且无覆盖时两者应相同');
      expect(first, '2026-11-09 16:28:32');

      final String packagePath =
          _text(install, 'packagePathAfterInstall', label: 'installation');
      expect(packagePath, startsWith('package:'));
      expect(packagePath, contains('rhine.music.database'));
      expect(packagePath, endsWith('/base.apk'));
    });
  });

  group('§12.1 screenshots 与 §12.2 12 图索引', () {
    test('索引恰为 12 项，bytes > 0 且 prefix16 为 16 位十六进制', () {
      final Map<String, dynamic> shots = _object(manifest, 'screenshots');
      expect(_bool(shots, 'indexAvailable', label: 'screenshots'), isTrue);
      expect(_text(shots, 'originalDirectory', label: 'screenshots'),
          '/tmp/rhine-qt-baseline-2026-11-09/');

      final List<Map<String, dynamic>> items = _array(shots, 'items')
          .map((dynamic e) => (e! as Map).cast<String, dynamic>())
          .toList();
      expect(items, hasLength(12));

      final List<int> ids = <int>[];
      final List<String> files = <String>[];
      for (final Map<String, dynamic> item in items) {
        final String file = _text(item, 'file', label: 'screenshots.items');
        final int id = _int(item, 'id', label: 'screenshots.items');
        expect(id, greaterThan(0));
        ids.add(id);
        files.add(file);
        expect(file, endsWith('.png'));
        expect(_text(item, 'capturedAt', label: 'screenshots.items'),
            isNotEmpty);
        expect(_int(item, 'bytes', label: 'screenshots.items'), greaterThan(0));
        _matches(_text(item, 'sha256Prefix16', label: 'screenshots.items'),
            _hex16, 'screenshots.items[$id].sha256Prefix16');
      }
      expect(ids, List<int>.generate(12, (int i) => i + 1),
          reason: '12 图 id 必须恰为 1..12 且不重复');
      expect(files.toSet(), hasLength(12), reason: '文件名必须唯一');
      // 文档 §8.1 索引首尾样本，防止整表被替换。
      expect(items.first['file'], '01-consent.png');
      expect(items.last['file'], '12-search-results.png');
      expect(items.first['sha256Prefix16'], '425d7c7c890ee7ab');
      expect(items.last['sha256Prefix16'], '553963e921ea19ed');
    });

    test('像素实体不可用：entitiesAvailable=false 且无完整哈希', () {
      final Map<String, dynamic> shots = _object(manifest, 'screenshots');
      expect(_bool(shots, 'entitiesAvailable', label: 'screenshots'), isFalse);
      expect(_bool(shots, 'fullHashAvailable', label: 'screenshots'), isFalse);
      expect(_text(shots, 'entityStatus', label: 'screenshots'),
          'directory_missing_no_pixel_files_found');
    });
  });

  group('§12.1 pixelBaseline', () {
    test('像素基线状态为不可用、须重采', () {
      final Map<String, dynamic> pixel = _object(manifest, 'pixelBaseline');
      expect(_text(pixel, 'status', label: 'pixelBaseline'),
          'unavailable_recapture_required');
    });
  });

  group('§12.1 gaps 与 §12.2 唯一 closed', () {
    test('G1 为 closed/artifact-level，G2-G8 存在，closed 数量恰为 1', () {
      final Map<String, dynamic> gaps = _object(manifest, 'gaps');
      const List<String> ids = <String>['G1', 'G2', 'G3', 'G4', 'G5', 'G6',
          'G7', 'G8'];
      for (final String id in ids) {
        expect(gaps.containsKey(id), isTrue, reason: '缺少 $id');
        _text(_object(gaps, id), 'status', label: 'gaps.$id');
      }

      final Map<String, dynamic> g1 = _object(gaps, 'G1');
      expect(_text(g1, 'status', label: 'gaps.G1'), 'closed');
      expect(_text(g1, 'scope', label: 'gaps.G1'), 'artifact-level');

      final List<String> closed = ids
          .where((String id) => _object(gaps, id)['status'] == 'closed')
          .toList();
      expect(closed, <String>['G1'],
          reason: '本 fixture 只允许 G1 closed；任何状态变化都必须同时改 fixture '
              '与 00-baseline.md，让这条断言变红');
    });
  });

  group('§12.1 testExecution', () {
    test('本 fixture 不声称任何执行或通过', () {
      final Map<String, dynamic> exec = _object(manifest, 'testExecution');
      expect(_bool(exec, 'performed', label: 'testExecution'), isFalse);
      expect(_text(exec, 'reason', label: 'testExecution'),
          contains('flutter test'));
    });
  });

  group('§12.2 身份链交叉校验', () {
    test('buildIdentity.commitSha 出现在 APK 路径，APK 哈希唯一且合法', () {
      final Map<String, dynamic> build = _object(manifest, 'buildIdentity');
      final Map<String, dynamic> apk = _object(manifest, 'apk');
      final String short = build['commitSha']! as String;
      expect(apk['path'], contains(short));
      expect(_int(apk, 'topLevelApkCount', label: 'apk'), 1);
      _matches(_text(apk, 'sha256', label: 'apk'), _hex64, 'apk.sha256');
    });
  });
}
