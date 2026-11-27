/// 设置分区与平台能力契约的 fixture 测试（T06-F01）。
///
/// 证据等级 E1：fixture 逐值镜像冻结基线 `8ed3067b0812eb2612f7841ec127a6e8ca93231b`
/// 下的 Qt 源码；该基线上 Flutter 设置页尚未实现，因此这些断言用于防止
/// “契约文档 ↔ fixture”发生漂移（七分区顺序、每区保留项、平台能力矩阵、
/// 存储键与布局常量），而不是运行时或设备一致性证明。
/// 生产接线：ARCH_BLOCKED。设备画面/手感证据：DEVICE_BLOCKED。
///
/// 本文件与产出它的同一轮内**不执行**（未运行 flutter test）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _fixturePath = 'test/fixtures/settings_sections.json';
const String _contractPath =
    'docs/flutter-migration/contracts/settings-platform.md';
const String _baseline = '8ed3067b0812eb2612f7841ec127a6e8ca93231b';

const List<String> _sectionOrder = <String>[
  'Provider',
  'Preferences',
  'Performance',
  'Storage',
  'Update',
  'Project',
  'Footer',
];

const List<String> _projectLinkIds = <String>[
  'project-home',
  'project-author',
  'project-player',
  'project-kugou',
  'project-rhine',
  'project-lyricsx',
  'project-lyricskit',
  'project-lyrimuse',
];

const List<String> _editableKinds = <String>['Choice', 'Stepper', 'Slider'];

List<Map<String, dynamic>> _maps(Object? value) =>
    (value as List<dynamic>).cast<Map<String, dynamic>>();

Map<String, dynamic> _readJson(String path) {
  final File file = File(path);
  expect(file.existsSync(), isTrue,
      reason: '缺少 $path（请在包根目录运行 flutter test）');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

String _text(Map<String, dynamic> map, String key) => (map[key] as String?) ?? '';

void main() {
  late Map<String, dynamic> fixture;

  setUpAll(() {
    fixture = _readJson(_fixturePath);
  });

  group('T06 七分区集合', () {
    test('恰好为冻结的七个分区且顺序固定', () {
      final List<Map<String, dynamic>> sections = _maps(fixture['sections']);
      expect(sections, hasLength(7));
      expect(sections.map((s) => s['id']).toList(), _sectionOrder);
      expect(fixture['sectionOrder'], _sectionOrder);
      expect(sections.map((s) => s['number']).toList(),
          <int>[1, 2, 3, 4, 5, 6, 7]);
      expect(sections.map((s) => s['order']).toList(),
          <int>[10, 20, 30, 40, 50, 60, 70]);
    });

    test('每个分区都有中英标题且可见性恒为 always', () {
      for (final Map<String, dynamic> section in _maps(fixture['sections'])) {
        expect(_text(section, 'titleEn'), isNotEmpty);
        expect(_text(section, 'titleZh'), isNotEmpty);
        expect(_text(section, 'visible'), 'always');
      }
    });

    test('更新与诊断分区不得被排除', () {
      final List<Map<String, dynamic>> sections = _maps(fixture['sections']);
      final Map<String, dynamic> update =
          sections.firstWhere((s) => s['id'] == 'Update');
      final Map<String, dynamic> performance =
          sections.firstWhere((s) => s['id'] == 'Performance');
      final Map<String, dynamic> storage =
          sections.firstWhere((s) => s['id'] == 'Storage');
      expect(_text(update, 'customRenderer'), 'update');
      expect(update['customHeight'], 220);
      expect(_text(performance, 'customRenderer'), 'performance');
      expect(performance['customHeight'], 220);
      expect(_text(storage, 'customRenderer'), 'storage');
      expect(storage['customHeight'], 105);
    });
  });

  group('T06 Preferences 行', () {
    test('共 23 行且 order 严格递增、id 唯一', () {
      final List<Map<String, dynamic>> rows = _maps(fixture['preferencesRows']);
      expect(rows, hasLength(23));
      expect(rows.map((r) => r['id']).toList(), fixture['preferencesRowIds']);

      final Set<String> ids = <String>{};
      int previous = -1;
      for (final Map<String, dynamic> row in rows) {
        final String id = _text(row, 'id');
        expect(id, isNotEmpty);
        expect(ids.add(id), isTrue, reason: '重复行 id: $id');
        final int order = row['order'] as int;
        expect(order, greaterThan(previous), reason: 'order 未递增: $id');
        previous = order;
      }
    });

    test('每行都有中英标题', () {
      for (final Map<String, dynamic> row in _maps(fixture['preferencesRows'])) {
        expect(_text(row, 'titleEn'), isNotEmpty, reason: _text(row, 'id'));
        expect(_text(row, 'titleZh'), isNotEmpty, reason: _text(row, 'id'));
      }
    });

    test('可编辑控件必须有 action 或 actionPrefix', () {
      for (final Map<String, dynamic> row in _maps(fixture['preferencesRows'])) {
        if (!_editableKinds.contains(_text(row, 'kind'))) {
          continue;
        }
        final String action = _text(row, 'action');
        final String prefix = _text(row, 'actionPrefix');
        expect(action.isNotEmpty || prefix.isNotEmpty, isTrue,
            reason: '${_text(row, 'id')} 缺少 action/actionPrefix');
      }
    });

    test('Action 绑定行必须有 action', () {
      for (final Map<String, dynamic> row in _maps(fixture['preferencesRows'])) {
        if (_text(row, 'bindingKind') != 'Action') {
          continue;
        }
        expect(_text(row, 'action'), isNotEmpty, reason: _text(row, 'id'));
      }
    });

    test('Preference 绑定行的键必须在 Host 白名单内', () {
      final List<dynamic> keys =
          (fixture['storage'] as Map<String, dynamic>)['preferenceKeys']
              as List<dynamic>;
      for (final Map<String, dynamic> row in _maps(fixture['preferencesRows'])) {
        if (_text(row, 'bindingKind') != 'Preference') {
          continue;
        }
        final String key = _text(row, 'preferenceKey');
        expect(key, isNotEmpty, reason: _text(row, 'id'));
        expect(keys.contains(key), isTrue,
            reason: '${_text(row, 'id')} 的偏好键不在白名单: $key');
      }
    });

    test('静态选项必须包含默认值', () {
      for (final Map<String, dynamic> row in _maps(fixture['preferencesRows'])) {
        final Object? options = row['options'];
        final String defaultValue = _text(row, 'defaultValue');
        if (options == null || defaultValue.isEmpty) {
          continue;
        }
        final List<String> values =
            _maps(options).map((o) => _text(o, 'value')).toList();
        expect(values.contains(defaultValue), isTrue,
            reason: '${_text(row, 'id')} 默认值不在选项中: $defaultValue');
      }
    });

    test('代表性行的冻结数值', () {
      final Map<String, Map<String, dynamic>> byId =
          <String, Map<String, dynamic>>{
        for (final Map<String, dynamic> row
            in _maps(fixture['preferencesRows']))
          _text(row, 'id'): row,
      };

      expect(byId['theme']!['defaultValue'], 'light');
      expect(_text(byId['theme']!, 'actionPrefix'), 'setting:theme:');
      expect(byId['close-behavior']!['defaultValue'], 'quit');
      expect(byId['archive-mask']!['minimum'], 0);
      expect(byId['archive-mask']!['maximum'], 100);
      expect(byId['archive-mask']!['step'], 10);
      expect(byId['render-scale']!['steps'], <int>[50, 60, 75, 90, 100]);
      // Android 默认 75（Qt/src/render/AndroidRenderPolicy.h:106-116），非 Android 100；
      // SettingsSchema.cpp:565 的旧注释写作 90，以函数为准（见契约 §2 注）。
      expect(byId['render-scale']!['defaultValueAndroid'], 75);
      expect(byId['render-scale']!['defaultValueAndroidTuningOff'], 100);
      expect(byId['render-scale']!['defaultValueOther'], 100);
      expect(byId['render-scale']!['defaultValueAndroidEnvOverride'],
          'RHINE_ANDROID_RENDER_SCALE=50..100');
      expect(byId['msaa']!['steps'], <int>[2, 4, 8]);
      expect(byId['msaa']!['wrap'], isTrue);
      expect(byId['aa-scale']!['defaultValue'], '125');
      expect(byId['fsr-quality']!['defaultValue'], 'native');
      expect(byId['fg']!['visible'], 'defined(Q_OS_DARWIN)');
      expect(_text(byId['desktop-lyrics']!, 'action'), 'desktop-lyrics:open');
      expect(_text(byId['window']!, 'visible'),
          'PlatformFeatures::DesktopWindowControls');
      expect(_text(byId['official-player']!, 'visible'),
          'PlatformFeatures::OfficialPlayback && context.music && '
          '!context.music->isLocal()');
      expect(_text(byId['quality']!, 'visible'),
          'context.music && !context.music->isLocal()');
      expect(_text(byId['close-behavior']!, 'visible'),
          'defined(Q_OS_MACOS) || defined(Q_OS_WIN)');
      expect(_text(byId['vsync']!, 'visible'), '!defined(Q_OS_DARWIN)');
    });
  });

  group('T06 Project 链接', () {
    test('八条链接且顺序与 id 固定', () {
      final List<Map<String, dynamic>> links = _maps(fixture['projectLinks']);
      expect(links, hasLength(8));
      expect(links.map((l) => l['id']).toList(), _projectLinkIds);
      expect(links.map((l) => l['order']).toList(),
          <int>[10, 11, 12, 13, 14, 15, 16, 17]);
    });

    test('每条链接的 label 与 action 非空', () {
      for (final Map<String, dynamic> link in _maps(fixture['projectLinks'])) {
        expect(_text(link, 'label'), isNotEmpty, reason: _text(link, 'id'));
        expect(_text(link, 'action'), startsWith('music:project-'));
      }
    });
  });

  group('T06 平台能力矩阵', () {
    test('Android 与 iOS 的四项桌面能力为 false', () {
      final Map<String, dynamic> capabilities =
          fixture['capabilities'] as Map<String, dynamic>;
      const List<String> desktopOnly = <String>[
        'OfficialPlayback',
        'LocalMusic',
        'ApplicationVolume',
        'DesktopWindowControls',
      ];
      for (final String name in desktopOnly) {
        final Map<String, dynamic> flags =
            capabilities[name] as Map<String, dynamic>;
        expect(flags['android'], isFalse, reason: name);
        expect(flags['ios'], isFalse, reason: name);
        expect(flags['windows'], isTrue, reason: name);
        expect(flags['macos'], isTrue, reason: name);
        expect(flags['linux'], isTrue, reason: name);
      }
    });

    test('桌面歌词仅 Windows 与 macOS 可用', () {
      final Map<String, dynamic> lyrics =
          (fixture['capabilities'] as Map<String, dynamic>)['DesktopLyrics']
              as Map<String, dynamic>;
      expect(lyrics['windows'], isTrue);
      expect(lyrics['macos'], isTrue);
      expect(lyrics['android'], isFalse);
      expect(lyrics['ios'], isFalse);
      expect(lyrics['linux'], isFalse);
      expect(fixture['guarantees']['desktopLyricsPlatforms'],
          <String>['windows', 'macos']);
    });
  });

  group('T06 保留项与细粒度后果', () {
    test('七个分区在所有平台始终可见', () {
      expect(fixture['guarantees']['alwaysVisibleSections'], _sectionOrder);
    });

    test('Android 上更新、诊断、存储与同意门都保留', () {
      final List<dynamic> retained =
          fixture['guarantees']['retainedOnAndroid'] as List<dynamic>;
      expect(retained, contains('update'));
      expect(retained, contains('performance'));
      expect(retained, contains('storage'));
      expect(retained, contains('consent'));
      expect(fixture['guarantees']['consentNotASettingsSection'], isTrue);
    });

    test('Android 基线仍发起更新检查；跳过产物匹配是偏离项', () {
      final Map<String, dynamic> g =
          fixture['guarantees'] as Map<String, dynamic>;
      // Qt 基线：check() 无平台分支（Qt/src/AppUpdater.cpp:188-202）；
      // Android 空串只让 selectRelease 跳过产物循环（:73-76、:117），
      // 请求照发并停在 :135 的「尚无适合当前架构的更新包」文案。
      expect(g['updateCheckOnAndroidBaseline'], isTrue);
      expect(g['updateArtifactMatchingSkippedOnAndroid'], isTrue);
      expect(g['androidSkipCheckIsDeliberateDeviation'], isTrue);
      expect(g['inAppDownloadOrInstall'], isFalse);
      final Map<String, dynamic> update =
          fixture['update'] as Map<String, dynamic>;
      expect(update['platformAssets']['android'], '');
      // 退避常量与 m_release 保留/清空分界（Qt/src/AppUpdater.cpp:169-171、:248-252）。
      expect(update['defaultRetrySeconds'], 60);
      expect(update['inAppDownloadOrInstall'], isFalse);
      expect(update['androidPlatformAssetMeans'], contains('selectRelease'));
      expect(update['releaseInfoRetention'], contains('226-243'));
    });

    test('平台选择器在无本地音乐能力时移除 local 项', () {
      expect(fixture['guarantees']['androidPlatformChooserEntries'],
          <String>['siren', 'netease', 'qq', 'kugou']);
      expect(fixture['guarantees']['desktopPlatformChooserEntries'],
          <String>['siren', 'netease', 'qq', 'kugou', 'local']);
    });
  });

  group('T06 存储与布局', () {
    test('偏好前缀为 panel/ 且设置页键都在白名单内', () {
      final Map<String, dynamic> storage =
          fixture['storage'] as Map<String, dynamic>;
      expect(storage['prefix'], 'panel/');
      // 三条件只约束本地分支；remote 分支绕过（Host.cpp:1078-1092）。
      expect(storage['writeBranch'], contains('remote'));
      expect(storage['preferenceChangedGate'], contains('DARWIN'));
      final List<dynamic> whitelist = storage['preferenceKeys'] as List<dynamic>;
      for (final dynamic key in storage['settingsPageKeys'] as List<dynamic>) {
        expect(whitelist.contains(key), isTrue, reason: '键不在白名单: ' + key);
      }
    });

    test('布局常量与 Qt 冻结值一致', () {
      final Map<String, dynamic> layout =
          fixture['layout'] as Map<String, dynamic>;
      expect(layout['headerHeight'], 46);
      expect(layout['sectionGap'], 24);
      expect(layout['rowHeight'], 66);
      expect(layout['rowStep'], 76);
      expect(layout['optionHeight'], 50);
      expect(layout['bottomPad'], 28);
      expect(layout['contentInset'], 14);
      expect(layout['controlWidth'], 300);
      expect(layout['linkGap'], 16);
      expect(layout['linkRowHeight'], 50);
      expect(layout['linkRowStep'], 60);
      expect(layout['settingsViewportTop'], 176);
      expect(layout['settingsViewportBottom'], 836);
      expect(layout['wheelScrollStep'], 66);
      // 滚轮步长不是 SettingsCard 常量，来源是 NativeHudInput.cpp:30-33。
      expect(layout['wheelScrollStepSource'], contains('NativeHudInput.cpp'));
    });

    test('恢复默认不改动平台、账号与更新状态', () {
      final Map<String, dynamic> restore =
          fixture['restoreDefaults'] as Map<String, dynamic>;
      // 源码跳过 3 个 SettingKind + 1 个 BindingKind（NativeHudSettings.cpp:496-499）。
      expect(restore['skipsSettingKinds'], <String>['Action', 'Link', 'Custom']);
      expect(restore['skipsBindingKinds'], <String>['CustomSection']);
      expect(restore['expandedPreferenceCleared'], isTrue);
      expect(restore['invalidate'], contains('invalidate'));
      expect(restore['discRotationRestore'], contains('disc-rotation'));
      expect(restore['desktopLyricsResetGuardedBy'],
          'PlatformFeatures::DesktopLyrics');
      expect(restore['skipsInvisibleRows'], isTrue);
      expect(restore['autoUpdateCleared'], isTrue);
      expect(restore['scrollReset'], 0);
      expect(restore['doesNotChange'],
          containsAll(<String>['platform', 'account', 'update state']));
    });
  });

  group('T06 桌面歌词键', () {
    test('12 个键与默认值冻结', () {
      final Map<String, dynamic> lyrics =
          fixture['desktopLyrics'] as Map<String, dynamic>;
      final Map<String, dynamic> defaults =
          lyrics['defaults'] as Map<String, dynamic>;
      expect(lyrics['enabledKey'], 'desktop-lyrics');
      expect(defaults, hasLength(12));
      expect(defaults['desktop-lyrics'], 'off');
      expect(defaults['desktop-lyrics-size'], '32');
      expect(defaults['desktop-lyrics-translation-size'], '24');
      expect(defaults['desktop-lyrics-opacity'], '100');
      expect(defaults['desktop-lyrics-line-color'], '#f5f6f2');
      expect(defaults['desktop-lyrics-translation-color'], '#f5f6f2');
      expect(defaults['desktop-lyrics-line-weight'], 'bold');
      expect(defaults['desktop-lyrics-translation-weight'], 'regular');
      expect(defaults['desktop-lyrics-line-outline'], '1.5');
      expect(defaults['desktop-lyrics-translation-outline'], '1');
      expect(defaults['desktop-lyrics-line-outline-color'], '#000000');
      expect(defaults['desktop-lyrics-translation-outline-color'], '#000000');
      expect(lyrics['outlineStep'], 0.5);
      // 描边以一位小数写出（DesktopLyricsAppearance.cpp:74-89）：数值 1，落盘 "1.0"。
      expect(lyrics['outlineStoredStringNote'], contains('"1.0"'));
      expect(lyrics['weights'],
          <String>['light', 'regular', 'demibold', 'bold']);
    });

    test('桌面歌词键都在 Host 偏好白名单内', () {
      final List<dynamic> whitelist =
          (fixture['storage'] as Map<String, dynamic>)['preferenceKeys']
              as List<dynamic>;
      final Map<String, dynamic> defaults =
          (fixture['desktopLyrics'] as Map<String, dynamic>)['defaults']
              as Map<String, dynamic>;
      for (final String key in defaults.keys) {
        expect(whitelist.contains(key), isTrue, reason: '未知键: $key');
      }
    });
  });

  group('T06 更新契约', () {
    test('平台产物与阈值冻结', () {
      final Map<String, dynamic> update =
          fixture['update'] as Map<String, dynamic>;
      expect(update['repository'], 'MikeQu223/Rhine-Music-Database');
      expect(update['maxResponseBytes'], 1048576);
      expect(update['transferTimeoutMs'], 30000);
      expect(update['maxPackageBytes'], 2147483648);
      final Map<String, dynamic> assets =
          update['platformAssets'] as Map<String, dynamic>;
      expect(assets['windows-x64'], 'Windows-x64-Setup.exe');
      expect(assets['linux-x86_64'], 'Linux-x86_64.AppImage');
      expect(assets['macos-arm64'], 'macOS-arm64.zip');
      expect(assets['ios'], 'ios-unsigned.ipa');
      expect(assets['android'], '');
      expect(update['assetNamePattern'], 'RhineMusicDatabase-<tag>-<platform>');
    });

    test('无应用内下载安装，只打开发布页面', () {
      final Map<String, dynamic> update =
          fixture['update'] as Map<String, dynamic>;
      expect(update['releasePageUrl'],
          'https://github.com/MikeQu223/Rhine-Music-Database/releases');
      expect(fixture['guarantees']['inAppDownloadOrInstall'], isFalse);
    });
  });

  group('T06 契约文档一致性', () {
    test('契约文档存在并声明冻结基线与阻塞标记', () {
      final File contract = File(_contractPath);
      expect(contract.existsSync(), isTrue);
      final String text = contract.readAsStringSync();
      expect(text, contains('FROZEN_FOR_IMPLEMENTATION'));
      expect(text, contains(_baseline));
      expect(text, contains('DEVICE_BLOCKED'));
      expect(text, contains('ARCH_BLOCKED'));
    });

    test('契约文档按固定顺序列出七分区 id', () {
      final String text = File(_contractPath).readAsStringSync();
      const String tick = '\u{60}';
      int cursor = -1;
      for (final String id in _sectionOrder) {
        final int index = text.indexOf(tick + id + tick);
        expect(index, greaterThan(cursor), reason: '契约缺少或乱序: $id');
        cursor = index;
      }
    });
  });
}
