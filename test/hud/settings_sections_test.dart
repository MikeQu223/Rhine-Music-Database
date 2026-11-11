// T37-C18-A2-W —— 设置模态七区表 / 布局算法 / 五类自定义区 / 模态框架 / 编辑浮层的独立校验。
//
// 证据纪律：每条断言注释给出 Qt 源文件:行号，不用记忆值、不用旧 Flutter UI。
//   Qt/src/SettingsSchema.cpp:693-703   七区表
//   Qt/src/SettingsCard.cpp:9-19        11 个几何常量
//   Qt/src/SettingsCard.cpp:36-45       表头（序号 / 标题 / 下划线）
//   Qt/src/SettingsCard.cpp:239-292     layout() 光标推进
//   Qt/src/SettingsCard.cpp:294-327     paint() 可见性
//   Qt/src/NativeHudSettings.cpp:163-225 面板 / 轨道 / 滚动按钮
//   Qt/src/NativeHudSettings.cpp:227-380 五类自定义区
//   Qt/src/NativeHudModal.cpp:5-24      平台候选表
//   Qt/src/NativeHudModal.cpp:188-202   模态框架
//   Qt/src/NativeHudModal.cpp:259-291   平台选择器几何
//   Qt/src/NativeHud.h:115-116          176 / 836
//   Qt/src/NativeHudInput.cpp:29-33     滚轮 66 与命中窗口
//   Qt/src/HudScroll.h:13-26,50-86      maximum / clampOffset / applyWheel / rail / clipHits
//   Qt/qml/Overlay.qml:563-602          编辑浮层
//   Qt/qml/PerformancePanel.qml:1-150   性能面板本体
//
// 状态：本轮禁止执行 flutter test / dart test / dart analyze / build / pub get。
// 本文件按「RED/GREEN 未执行」交付，逻辑由父派独立只读 reviewer 复核。

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/hud/modals/settings_modal.dart';
import 'package:rhine_music_database/hud/widgets/settings_row.dart';

SettingsPalette darkPalette() =>
    SettingsPalette.fromInk(const SettingsRgba(1, 1, 1, 1), dark: true);

/// 真注册表驱动的桌面基准：windows + netease + 可播放 + 默认快照。
/// Preferences 的行数与顺序直接来自 SettingsSchema.cpp:347-691 的 descriptors()。
const SettingsPreferenceContext desktopContext = SettingsPreferenceContext();
const SettingsPreferenceSnapshot desktopSnapshot = SettingsPreferenceSnapshot();

List<SettingsSectionModel> desktopSectionModel() =>
    settingsSectionModels(context: desktopContext, snapshot: desktopSnapshot);

SettingsRowSpec registryRow(String id) => settingsRowSpecFor(
      settingsDescriptorById(id)!,
      context: desktopContext,
      snapshot: desktopSnapshot,
    );

/// 逐 key 期望表的一行，对应 SettingsSchema.cpp:352-687 的一条 descriptor。
class _RowExpectation {
  const _RowExpectation(
    this.id,
    this.order,
    this.kind,
    this.storage,
    this.binding,
    this.titleEn,
    this.titleZh, {
    this.defaultValue = '',
    this.action = '',
    this.actionPrefix = '',
    this.preferenceKey = '',
    this.restartHint = '',
    this.darwinTitleEn = '',
    this.darwinTitleZh = '',
  });

  final String id;
  final int order;
  final SettingsRowKind kind;
  final SettingsStorageType storage;
  final SettingsBindingKind binding;
  final String titleEn;
  final String titleZh;
  final String defaultValue;
  final String action;
  final String actionPrefix;
  final String preferenceKey;
  final String restartHint;
  final String darwinTitleEn;
  final String darwinTitleZh;
}

void main() {
  // 手算基准：modalBounds = (0,0,1280,H)，即可用宽 usable = 1280 - 106 = 1174；
  // viewport = (0+40, 0+176, 1280-80, 836-176) = (40, 176, 1200, 660)
  // —— NativeHudSettings.cpp:164-165 与 NativeHud.h:115-116。
  const Rect viewport = Rect.fromLTWH(40, 176, 1200, 660);
  // left = viewport.left + ContentInset = 40 + 14 = 54；width = 1200 - 28 = 1172（SettingsCard.cpp:242-243）。
  const double left = 54;
  const double width = 1172;

  group('七区表（契约 §1；SettingsSchema.cpp:693-703）', () {
    test('七个分区、order 10..70、number 1..7、顺序固定', () {
      expect(settingsSections.length, 7);
      expect(settingsSections.map((SettingsSectionSpec s) => s.order).toList(),
          <int>[10, 20, 30, 40, 50, 60, 70]);
      expect(settingsSections.map((SettingsSectionSpec s) => s.number).toList(),
          <int>[1, 2, 3, 4, 5, 6, 7]);
      expect(settingsSections.map((SettingsSectionSpec s) => s.id).toList(), <SettingsSectionId>[
        SettingsSectionId.provider,
        SettingsSectionId.preferences,
        SettingsSectionId.performance,
        SettingsSectionId.storage,
        SettingsSectionId.update,
        SettingsSectionId.project,
        SettingsSectionId.footer,
      ]);
      // orderedSettingsSections() 是 NativeHudSettings.cpp:39-77 的 order 升序。
      expect(orderedSettingsSections().map((SettingsSectionSpec s) => s.order).toList(),
          <int>[10, 20, 30, 40, 50, 60, 70]);
    });

    test('中英标题逐字（SettingsSchema.cpp:695-701）', () {
      expect(settingsSections[0].titleEn, 'PROVIDER ACCESS');
      expect(settingsSections[0].titleZh, '音乐平台');
      expect(settingsSections[1].titleEn, 'TERMINAL PREFERENCES');
      expect(settingsSections[1].titleZh, '终端偏好');
      expect(settingsSections[2].titleEn, 'PERFORMANCE');
      expect(settingsSections[2].titleZh, '性能与诊断');
      expect(settingsSections[3].titleEn, 'STORAGE');
      expect(settingsSections[3].titleZh, '存储与缓存');
      expect(settingsSections[4].titleEn, 'SOFTWARE UPDATE');
      expect(settingsSections[4].titleZh, '软件更新');
      expect(settingsSections[5].titleEn, 'PROJECT');
      expect(settingsSections[5].titleZh, '项目与开源参考');
      expect(settingsSections[6].titleEn, 'CONFIG');
      expect(settingsSections[6].titleZh, '配置管理');
    });

    test('customRenderer / customHeight 逐区冻结（SettingsSchema.cpp:695-701）', () {
      expect(settingsSections[0].customRenderer, 'provider-card');
      expect(settingsSections[0].customHeight, 160);
      expect(settingsSections[1].customRenderer, '');
      expect(settingsSections[1].customHeight, 0);
      expect(settingsSections[2].customRenderer, 'performance');
      expect(settingsSections[2].customHeight, 220);
      expect(settingsSections[3].customRenderer, 'storage');
      expect(settingsSections[3].customHeight, 105);
      expect(settingsSections[4].customRenderer, 'update');
      expect(settingsSections[4].customHeight, 220);
      expect(settingsSections[5].customRenderer, '');
      expect(settingsSections[5].customHeight, 0);
      expect(settingsSections[6].customRenderer, 'defaults');
      expect(settingsSections[6].customHeight, 84);
      // hasCustomRenderer 决定走自定义体高分支还是行循环（SettingsCard.cpp:250/268）。
      expect(settingsSections[0].hasCustomRenderer, isTrue);
      expect(settingsSections[1].hasCustomRenderer, isFalse);
      expect(settingsSections[5].hasCustomRenderer, isFalse);
    });

    test('七区 visible 恒 true：Android 也不隐藏 Update / Performance / Storage（契约 §13 MUST）', () {
      expect(visibleSettingsSections(const PlatformCapabilities.android()).length, 7);
      expect(visibleSettingsSections(const PlatformCapabilities.iOS()).length, 7);
      expect(visibleSettingsSections(const PlatformCapabilities.linux()).length, 7);
      for (final SettingsSectionSpec section in settingsSections) {
        expect(settingsSectionVisible(section, const PlatformCapabilities.android()), isTrue);
        expect(section.alwaysVisible, isTrue);
      }
    });

    test('表头序号是两位零填充（SettingsCard.cpp:40 rightJustified(2)）', () {
      expect(settingsSections[0].numberText, '01');
      expect(settingsSections[6].numberText, '07');
      expect(settingsSections[0].titleText, 'PROVIDER ACCESS / 音乐平台');
    });

    test('平台能力矩阵：移动全 false，桌面四项 true，Linux 的 DesktopLyrics 为 false（契约 §8）', () {
      const PlatformCapabilities android = PlatformCapabilities.android();
      expect(android.officialPlayback, isFalse);
      expect(android.localMusic, isFalse);
      expect(android.applicationVolume, isFalse);
      expect(android.desktopWindowControls, isFalse);
      expect(android.desktopLyrics, isFalse);
      const PlatformCapabilities windows = PlatformCapabilities.windows();
      expect(windows.officialPlayback, isTrue);
      expect(windows.localMusic, isTrue);
      expect(windows.applicationVolume, isTrue);
      expect(windows.desktopWindowControls, isTrue);
      expect(windows.desktopLyrics, isTrue);
      const PlatformCapabilities linux = PlatformCapabilities.linux();
      expect(linux.desktopLyrics, isFalse);
      expect(linux.localMusic, isTrue);
    });
  });

  group('布局算法（SettingsCard.cpp:239-292）', () {
    final SettingsCardLayout layout =
        layoutSettingsCard(viewport: viewport, model: desktopSectionModel());

    test('十一项几何常量与 Qt 字面值一致（SettingsCard.cpp:9-19；A1 已冻结，此处复核调用面）', () {
      expect(SettingsRowMetrics.headerHeight, 46);
      expect(SettingsRowMetrics.sectionGap, 24);
      expect(SettingsRowMetrics.rowHeight, 66);
      expect(SettingsRowMetrics.rowStep, 76);
      expect(SettingsRowMetrics.optionHeight, 50);
      expect(SettingsRowMetrics.bottomPad, 28);
      expect(SettingsRowMetrics.contentInset, 14);
      expect(SettingsRowMetrics.controlWidth, 300);
      expect(SettingsRowMetrics.linkGap, 16);
      expect(SettingsRowMetrics.linkRowHeight, 50);
      expect(SettingsRowMetrics.linkRowStep, 60);
    });

    test('header 从 viewport.top 起，每区 cursor += 46 后进入体区', () {
      // 推导（SettingsCard.cpp:244-254；Preferences 17 行来自 SettingsSchema.cpp:347-691 的可见性门）：
      //  Provider: header 176；cursor 222；body 160；cursor = 222+160+24 = 406
      //  Preferences: header 406；cursor 452；17 行 x 76 = 1292；cursor = 452+1292+24 = 1768
      //  Performance: header 1768；cursor 1814；body 220；cursor = 1814+220+24 = 2058
      //  Storage: header 2058；cursor 2104；body 105；cursor = 2104+105+24 = 2233
      //  Update: header 2233；cursor 2279；body 220；cursor = 2279+220+24 = 2523
      //  Project: header 2523；cursor 2569；8 链接 -> ((8+1)/2)*60 = 240；cursor = 2569+240+24 = 2833
      //  Footer: header 2833；cursor 2879；body 84；cursor = 2879+84+24 = 2987
      expect(layout.sections[0].header, const Rect.fromLTWH(40, 176, 1200, 46));
      expect(layout.sections[0].body, const Rect.fromLTWH(54, 222, 1172, 160));
      expect(layout.sections[0].height, 206);
      expect(layout.sections[1].header.top, 406);
      expect(layout.sections[1].body, const Rect.fromLTWH(54, 452, 1172, 1292));
      expect(layout.sections[1].height, 1338);
      expect(layout.sections[2].header.top, 1768);
      expect(layout.sections[2].body, const Rect.fromLTWH(54, 1814, 1172, 220));
      expect(layout.sections[3].header.top, 2058);
      expect(layout.sections[3].body, const Rect.fromLTWH(54, 2104, 1172, 105));
      expect(layout.sections[4].header.top, 2233);
      expect(layout.sections[4].body, const Rect.fromLTWH(54, 2279, 1172, 220));
      expect(layout.sections[5].header.top, 2523);
      expect(layout.sections[5].body, const Rect.fromLTWH(54, 2569, 1172, 240));
      expect(layout.sections[6].header.top, 2833);
      expect(layout.sections[6].body, const Rect.fromLTWH(54, 2879, 1172, 84));
    });

    test('普通行：bounds 66 高、control 300x48 右对齐下移 9、每行推进 76（SettingsCard.cpp:273-281）', () {
      final List<SettingsRowLayout> rows = layout.sections[1].rows;
      // 23 条偏好描述符中 6 条被平台门挡掉（gpu-index/aa-scale/msaa/fsr-quality/fsr-sharpness/fg），
      // 余 17 行：SettingsSchema.cpp:352-687 与 NativeHudSettings.cpp:28-37。
      expect(rows.length, 17);
      expect(rows[0].bounds, const Rect.fromLTWH(54, 452, 1172, 66));
      expect(rows[0].control, const Rect.fromLTWH(926, 461, 300, 48));
      expect(rows[0].optionsHeight, 0);
      expect(rows[0].options, Rect.zero);
      expect(rows[1].bounds.top, 528);
      expect(rows[1].control.top, 537);
      expect(rows[2].bounds.top, 604);
      expect(rows[2].control.top, 613);
      // 第 17 行（index 16）top = 452 + 16*76 = 1668；control 再下移 9。
      expect(rows[16].bounds.top, 1668);
      expect(rows[16].control.top, 1677);
    });

    test('Project 两列 8 链接坐标（SettingsCard.cpp:256-264）', () {
      // linkWidth = (1172 - 16) / 2 = 578；列间 +594；行间 +60。
      final List<SettingsRowLayout> rows = layout.sections[5].rows;
      expect(rows.length, 8);
      expect(rows[0].bounds, const Rect.fromLTWH(54, 2569, 578, 50));
      expect(rows[1].bounds, const Rect.fromLTWH(648, 2569, 578, 50));
      expect(rows[2].bounds, const Rect.fromLTWH(54, 2629, 578, 50));
      expect(rows[3].bounds, const Rect.fromLTWH(648, 2629, 578, 50));
      expect(rows[4].bounds, const Rect.fromLTWH(54, 2689, 578, 50));
      expect(rows[5].bounds, const Rect.fromLTWH(648, 2689, 578, 50));
      expect(rows[6].bounds, const Rect.fromLTWH(54, 2749, 578, 50));
      expect(rows[7].bounds, const Rect.fromLTWH(648, 2749, 578, 50));
      // 链接行没有 control / options（SettingsCard.cpp:258-262 只填 bounds）。
      expect(rows[0].control, Rect.zero);
      expect(rows[0].optionsHeight, 0);
    });

    test('contentHeight / maximumScroll（SettingsCard.cpp:289-290；HudScroll.h:13-15）', () {
      // contentHeight = cursor - viewport.top + BottomPad = 2987 - 176 + 28 = 2839
      expect(layout.contentHeight, 2839);
      // maximumScroll = max(0, 2839 - 660) = 2179
      expect(layout.maximumScroll, 2179);
      expect(layout.viewportHeight, 660);
    });

    test('展开行把 optionsHeight 计入光标（SettingsCard.cpp:275-281）', () {
      // 4 个选项：optionsHeight = 4 * 50 + 4 = 204；该行推进 76 + 204 = 280。
      final SettingsRowSpec expanded = SettingsRowSpec(
        id: 'aa-mode',
        kind: SettingsRowKind.choice,
        titleEn: 'AA & UPSCALING',
        titleZh: '抗锯齿与超分辨率',
        label: '关闭',
        expanded: true,
        choices: const <SettingsChoice>[
          SettingsChoice(value: 'off', label: '关闭'),
          SettingsChoice(value: 'fxaa', label: 'FXAA'),
          SettingsChoice(value: 'taa', label: 'TAA'),
          SettingsChoice(value: 'fsr', label: 'FSR'),
        ],
      );
      final SettingsCardLayout one = layoutSettingsCard(
        viewport: viewport,
        model: <SettingsSectionModel>[
          SettingsSectionModel(
              spec: settingsSectionById(SettingsSectionId.preferences)!,
              rows: <SettingsRowSpec>[expanded]),
        ],
      );
      expect(one.sections[0].rows[0].optionsHeight, 204);
      // 该模型只有 Preferences 一个分区：cursor 176 -> header 后 222 -> bodyTop 222；
      // control.left = 54 + 1172 - 300 = 926；options.top = 222 + 66 + 2 = 290（SettingsCard.cpp:277）。
      expect(one.sections[0].rows[0].options, const Rect.fromLTWH(926, 290, 300, 204));
      // 行推进 76 + 204 = 280；body 高 280；cursor = 222 + 280 + 24 = 526；
      // contentHeight = 526 - 176 + 28 = 378（SettingsCard.cpp:281,289）。
      expect(one.sections[0].body.height, 280);
      expect(one.contentHeight, 378);
    });

    test('禁用行即使 expanded 也不占位（SettingsCard.cpp:275）', () {
      final SettingsRowSpec disabled = SettingsRowSpec(
        id: 'gpu-index',
        kind: SettingsRowKind.choice,
        enabled: false,
        expanded: true,
        choices: const <SettingsChoice>[
          SettingsChoice(value: '', label: '默认'),
          SettingsChoice(value: '0', label: '显卡 0'),
        ],
      );
      final SettingsCardLayout one = layoutSettingsCard(
        viewport: viewport,
        model: <SettingsSectionModel>[
          SettingsSectionModel(
              spec: settingsSectionById(SettingsSectionId.preferences)!,
              rows: <SettingsRowSpec>[disabled]),
        ],
      );
      expect(one.sections[0].rows[0].optionsHeight, 0);
      expect(one.sections[0].rows[0].options, Rect.zero);
    });

    test('settingsRowExpanded 复刻 row.expanded = expandedId == id && enabled（NativeHudSettings.cpp:66）', () {
      expect(settingsRowExpanded(row: registryRow('theme'), expandedId: 'theme'), isTrue);
      expect(settingsRowExpanded(row: registryRow('theme'), expandedId: ''), isFalse);
      expect(
          settingsRowExpanded(
              row: SettingsRowSpec(id: 'theme', kind: SettingsRowKind.choice, enabled: false),
              expandedId: 'theme'),
          isFalse);
    });
  });

  group('偏好注册表（SettingsSchema.cpp:347-691；Host.cpp:1041-1059）', () {
    const List<String> expectedPreferenceKeys = <String>[
      'search-history', 'play-history', 'local-cover-cache', 'theme', 'motion', 'startup-animation',
      'detail-autoplay', 'single-play-mode', 'disc-rotation', 'scene-enhancement', 'archive-mask-strength',
      'graphics-backend', 'gpu-index', 'vsync', 'supersample', 'render-scale', 'aa-mode', 'aa-scale',
      'msaa', 'fsr-quality', 'fsr-sharpness', 'fg', 'close-behavior', 'auto-update', 'volume', 'quality',
      'alternate-source', 'provider', 'lyrics-cache', 'lyrics-global-offset-ms', 'welcome-name-netease',
      'welcome-name-qq', 'welcome-name-kugou', 'account-id-netease', 'account-id-qq', 'account-id-kugou',
      'kugou-edition', 'desktop-lyrics', 'desktop-lyrics-size', 'desktop-lyrics-translation-size',
      'desktop-lyrics-opacity', 'desktop-lyrics-line-color', 'desktop-lyrics-translation-color',
      'desktop-lyrics-line-weight', 'desktop-lyrics-translation-weight', 'desktop-lyrics-line-outline',
      'desktop-lyrics-translation-outline', 'desktop-lyrics-line-outline-color',
      'desktop-lyrics-translation-outline-color', 'welcome-name-kugou-standard', 'welcome-name-kugou-lite',
      'account-id-kugou-standard', 'account-id-kugou-lite',
    ];

    test('53 个偏好 key 与 Qt Host 白名单逐字同序', () {
      expect(settingsPreferenceKeys, expectedPreferenceKeys);
      expect(settingsPreferenceKeys.length, 53);
      expect(settingsPreferenceKeySet.length, 53);
      expect(isSettingsPreferenceKey('theme'), isTrue);
      expect(isSettingsPreferenceKey('account-id-kugou-lite'), isTrue);
      expect(isSettingsPreferenceKey('not-a-preference'), isFalse);
    });

    test('31 条 descriptor：23 条偏好 + 8 条项目链接', () {
      final List<SettingsDescriptor> all = settingsDescriptors();
      expect(all.length, 31);
      expect(
          all.map((SettingsDescriptor d) => d.id).toList(),
          <String>[
            'window', 'close-behavior', 'theme', 'motion', 'startup-animation', 'replay', 'quality',
            'alternative', 'official-player', 'detail-autoplay', 'single-play-mode', 'desktop-lyrics',
            'archive-mask', 'graphics-backend', 'gpu-index', 'vsync', 'render-scale', 'aa-mode', 'aa-scale',
            'msaa', 'fsr-quality', 'fsr-sharpness', 'fg', //
            'project-home', 'project-author', 'project-player', 'project-kugou', 'project-rhine',
            'project-lyricsx', 'project-lyricskit', 'project-lyrimuse',
          ]);
      expect(settingsDescriptorById('window')!.order, 100);
      expect(settingsDescriptorById('project-lyrimuse')!.order, 17);
      expect(settingsDescriptorById('not-a-row'), isNull);
      // SettingsSchema.cpp:693-703 的分区归属：偏好 23 条全在 preferences，链接 8 条全在 project。
      expect(settingsSectionDescriptors(SettingsSectionId.preferences).length, 23);
      expect(settingsSectionDescriptors(SettingsSectionId.project).length, 8);
      expect(
          settingsSectionDescriptors(SettingsSectionId.project)
              .map((SettingsDescriptor d) => d.order)
              .toList(),
          <int>[10, 11, 12, 13, 14, 15, 16, 17]);
    });

    const List<_RowExpectation> expected = <_RowExpectation>[
      _RowExpectation('window', 100, SettingsRowKind.action, SettingsStorageType.none,
          SettingsBindingKind.action, 'WINDOW', '窗口显示',
          action: 'window:fullscreen'),
      _RowExpectation('close-behavior', 110, SettingsRowKind.choice, SettingsStorageType.trayQuit,
          SettingsBindingKind.preference, 'CLOSE WINDOW', '点击关闭窗口',
          defaultValue: 'quit',
          action: 'close-behavior',
          actionPrefix: 'setting:close-behavior:',
          preferenceKey: 'close-behavior'),
      _RowExpectation('theme', 120, SettingsRowKind.choice, SettingsStorageType.theme,
          SettingsBindingKind.hudState, 'COLOR THEME', '界面配色',
          defaultValue: 'light', action: 'theme', actionPrefix: 'setting:theme:'),
      _RowExpectation('motion', 130, SettingsRowKind.choice, SettingsStorageType.reducedFull,
          SettingsBindingKind.hudState, 'REDUCED MOTION', '动态效果',
          defaultValue: 'full', action: 'motion', actionPrefix: 'setting:motion:'),
      _RowExpectation('startup-animation', 140, SettingsRowKind.choice, SettingsStorageType.onOff,
          SettingsBindingKind.hudState, 'STARTUP ANIMATION', '初始化动画',
          defaultValue: 'off',
          action: 'startup-animation',
          actionPrefix: 'setting:startup-animation:'),
      _RowExpectation('replay', 150, SettingsRowKind.action, SettingsStorageType.none,
          SettingsBindingKind.action, 'INITIALIZATION', '手动显示初始化页面',
          action: 'replay'),
      _RowExpectation('quality', 160, SettingsRowKind.choice, SettingsStorageType.playerQuality,
          SettingsBindingKind.player, 'AUDIO QUALITY', '音质',
          defaultValue: 'exhigh', action: 'quality', actionPrefix: 'quality:set:'),
      _RowExpectation('alternative', 170, SettingsRowKind.choice,
          SettingsStorageType.playerAlternative, SettingsBindingKind.player, 'ALTERNATE SOURCE', '替代音源',
          defaultValue: 'off', action: 'alternative', actionPrefix: 'setting:alternative:'),
      _RowExpectation('official-player', 180, SettingsRowKind.choice,
          SettingsStorageType.externalBool, SettingsBindingKind.external, 'OFFICIAL PLAYER', '官方窗口',
          defaultValue: 'off', action: 'music:activate', actionPrefix: 'setting:official-player:'),
      _RowExpectation('detail-autoplay', 190, SettingsRowKind.choice, SettingsStorageType.onOff,
          SettingsBindingKind.preference, 'ENTER AUTOPLAY', '进入详情自动播放',
          defaultValue: 'off',
          action: 'detail-autoplay',
          actionPrefix: 'setting:detail-autoplay:',
          preferenceKey: 'detail-autoplay'),
      _RowExpectation('single-play-mode', 200, SettingsRowKind.choice,
          SettingsStorageType.appendReplace, SettingsBindingKind.preference, 'PLAYLIST ON PLAY', '点击播放单曲',
          defaultValue: 'replace',
          action: 'single-play-mode',
          actionPrefix: 'setting:single-play-mode:',
          preferenceKey: 'single-play-mode'),
      _RowExpectation('desktop-lyrics', 205, SettingsRowKind.action, SettingsStorageType.none,
          SettingsBindingKind.action, 'DESKTOP LYRICS', '桌面歌词',
          action: 'desktop-lyrics:open'),
      _RowExpectation('archive-mask', 210, SettingsRowKind.stepper, SettingsStorageType.hudCachedInt,
          SettingsBindingKind.hudState, 'RIGHT MASK', '右侧画面遮罩',
          defaultValue: '50', actionPrefix: 'archive-mask:'),
      _RowExpectation('graphics-backend', 220, SettingsRowKind.choice, SettingsStorageType.enumeration,
          SettingsBindingKind.preference, 'GRAPHICS BACKEND', '图形后端',
          preferenceKey: 'graphics-backend',
          action: 'graphics-backend',
          actionPrefix: 'setting:graphics-backend:',
          restartHint: '重启生效',
          darwinTitleEn: 'METAL RENDERER',
          darwinTitleZh: '渲染模式'),
      _RowExpectation('gpu-index', 230, SettingsRowKind.choice, SettingsStorageType.enumeration,
          SettingsBindingKind.preference, 'GPU', '显卡',
          actionPrefix: 'gpu-index:', preferenceKey: 'gpu-index', restartHint: '重启生效'),
      _RowExpectation('vsync', 240, SettingsRowKind.choice, SettingsStorageType.hudCachedBool,
          SettingsBindingKind.hudState, 'V-SYNC', '垂直同步',
          defaultValue: 'on', action: 'vsync', actionPrefix: 'setting:vsync:', restartHint: '重启生效'),
      _RowExpectation('render-scale', 250, SettingsRowKind.stepper, SettingsStorageType.integer,
          SettingsBindingKind.preference, 'RENDER SCALE', '渲染分辨率',
          defaultValue: '100', actionPrefix: 'render-scale:', preferenceKey: 'render-scale'),
      _RowExpectation('aa-mode', 260, SettingsRowKind.choice, SettingsStorageType.enumeration,
          SettingsBindingKind.preference, 'AA & UPSCALING', '抗锯齿与超分辨率',
          defaultValue: 'off',
          actionPrefix: 'aa-mode:',
          preferenceKey: 'aa-mode',
          darwinTitleEn: 'METALFX',
          darwinTitleZh: '时域抗锯齿与超分辨率'),
      _RowExpectation('aa-scale', 270, SettingsRowKind.stepper, SettingsStorageType.integer,
          SettingsBindingKind.preference, 'AA SCALE', '抗锯齿倍率',
          defaultValue: '125', actionPrefix: 'aa-scale:', preferenceKey: 'aa-scale'),
      _RowExpectation('msaa', 280, SettingsRowKind.stepper, SettingsStorageType.integer,
          SettingsBindingKind.preference, 'MSAA SAMPLES', '多重采样倍率',
          defaultValue: '4', actionPrefix: 'msaa:', preferenceKey: 'msaa'),
      _RowExpectation('fsr-quality', 290, SettingsRowKind.choice, SettingsStorageType.enumeration,
          SettingsBindingKind.preference, 'FSR QUALITY', 'FSR 档位',
          defaultValue: 'native', actionPrefix: 'fsr-quality:', preferenceKey: 'fsr-quality'),
      _RowExpectation('fsr-sharpness', 300, SettingsRowKind.stepper, SettingsStorageType.integer,
          SettingsBindingKind.preference, 'FSR SHARPNESS', 'FSR 锐化',
          defaultValue: '50', actionPrefix: 'fsr-sharpness:', preferenceKey: 'fsr-sharpness'),
      _RowExpectation('fg', 310, SettingsRowKind.choice, SettingsStorageType.onOff,
          SettingsBindingKind.preference, 'FRAME GENERATION', '帧生成',
          defaultValue: 'off',
          action: 'fg',
          actionPrefix: 'setting:fg:',
          preferenceKey: 'fg'),
    ];

    test('逐 key 校验 order / kind / storage / binding / 标题 / 默认值 / action', () {
      expect(expected.length, 23);
      expect(
          settingsSectionDescriptors(SettingsSectionId.preferences)
              .map((SettingsDescriptor d) => d.id)
              .toList(),
          expected.map((_RowExpectation e) => e.id).toList());
      const SettingsPreferenceContext darwinContext = SettingsPreferenceContext(
        capabilities: PlatformCapabilities.macOS(),
        operatingSystem: SettingsOperatingSystem.macOS,
      );
      for (final _RowExpectation row in expected) {
        final SettingsDescriptor d = settingsDescriptorById(row.id)!;
        expect(d.section, SettingsSectionId.preferences, reason: row.id);
        expect(d.order, row.order, reason: row.id);
        expect(d.kind, row.kind, reason: row.id);
        expect(d.storage, row.storage, reason: row.id);
        expect(d.bindingKind, row.binding, reason: row.id);
        expect(settingsTitleEn(d, desktopContext), row.titleEn, reason: row.id);
        expect(settingsTitleZh(d, desktopContext), row.titleZh, reason: row.id);
        expect(settingsDefaultValue(d, desktopContext), row.defaultValue, reason: row.id);
        expect(d.action, row.action, reason: row.id);
        expect(d.actionPrefix, row.actionPrefix, reason: row.id);
        expect(d.preferenceKey, row.preferenceKey, reason: row.id);
        expect(settingsRestartHint(d, desktopContext), row.restartHint, reason: row.id);
        // SettingsSchema.cpp:220/260 的 Darwin 标题覆盖。
        if (row.darwinTitleEn.isNotEmpty) {
          expect(settingsTitleEn(d, darwinContext), row.darwinTitleEn, reason: row.id);
          expect(settingsTitleZh(d, darwinContext), row.darwinTitleZh, reason: row.id);
        } else {
          expect(settingsTitleEn(d, darwinContext), row.titleEn, reason: row.id);
        }
      }
      // render-scale 的平台默认取 Qt 的函数，不是硬编码：SettingsSchema.cpp:555-568 的
      // .defaultValue = QString::number(RhineRender::androidDefaultRenderScale())；
      // AndroidRenderPolicy.h:95-116 在 Android 下返回 75，其余平台 100。
      // SettingsSchema.cpp:565 与 main.cpp:805-806 的「90%」都是过期注释，以函数为准。
      const SettingsPreferenceContext android = SettingsPreferenceContext(
        capabilities: PlatformCapabilities.android(),
        operatingSystem: SettingsOperatingSystem.android,
      );
      expect(settingsDefaultValue(settingsDescriptorById('render-scale')!, android), '75');
      expect(settingsDefaultValue(settingsDescriptorById('render-scale')!, desktopContext), '100');
    });

    test('项目链接 8 条：kind Link、action music:project-*、标题即 actionLabel', () {
      const List<String> ids = <String>[
        'project-home', 'project-author', 'project-player', 'project-kugou', 'project-rhine',
        'project-lyricsx', 'project-lyricskit', 'project-lyrimuse',
      ];
      for (int index = 0; index < ids.length; index++) {
        final SettingsDescriptor d = settingsDescriptorById(ids[index])!;
        expect(d.kind, SettingsRowKind.link, reason: d.id);
        expect(d.bindingKind, SettingsBindingKind.action, reason: d.id);
        expect(d.storage, SettingsStorageType.none, reason: d.id);
        expect(d.order, 10 + index, reason: d.id);
        expect(d.action, 'music:' + ids[index], reason: d.id);
        expect(d.actionLabel, d.titleEn, reason: d.id);
        expect(d.titleZh, d.titleEn, reason: d.id);
      }
    });

    test('平台门：windows 17 / macOS 17 / linux 15 / android 13 行', () {
      List<String> visibleIds(SettingsPreferenceContext context) =>
          settingsSectionModels(context: context, snapshot: desktopSnapshot)
              .firstWhere((SettingsSectionModel m) => m.spec.id == SettingsSectionId.preferences)
              .rows
              .map((SettingsRowSpec row) => row.id)
              .toList();
      const List<String> windowsIds = <String>[
        'window', 'close-behavior', 'theme', 'motion', 'startup-animation', 'replay', 'quality',
        'alternative', 'official-player', 'detail-autoplay', 'single-play-mode', 'desktop-lyrics',
        'archive-mask', 'graphics-backend', 'vsync', 'render-scale', 'aa-mode',
      ];
      expect(visibleIds(desktopContext), windowsIds);
      const SettingsPreferenceContext macOS = SettingsPreferenceContext(
        capabilities: PlatformCapabilities.macOS(),
        operatingSystem: SettingsOperatingSystem.macOS,
      );
      expect(visibleIds(macOS), <String>[
        'window', 'close-behavior', 'theme', 'motion', 'startup-animation', 'replay', 'quality',
        'alternative', 'official-player', 'detail-autoplay', 'single-play-mode', 'desktop-lyrics',
        'archive-mask', 'graphics-backend', 'render-scale', 'aa-mode', 'fg',
      ]);
      const SettingsPreferenceContext linux = SettingsPreferenceContext(
        capabilities: PlatformCapabilities.linux(),
        operatingSystem: SettingsOperatingSystem.linux,
      );
      expect(visibleIds(linux), <String>[
        'window', 'theme', 'motion', 'startup-animation', 'replay', 'quality', 'alternative',
        'official-player', 'detail-autoplay', 'single-play-mode', 'archive-mask', 'graphics-backend',
        'vsync', 'render-scale', 'aa-mode',
      ]);
      const SettingsPreferenceContext android = SettingsPreferenceContext(
        capabilities: PlatformCapabilities.android(),
        operatingSystem: SettingsOperatingSystem.android,
      );
      expect(visibleIds(android), <String>[
        'theme', 'motion', 'startup-animation', 'replay', 'quality', 'alternative', 'detail-autoplay',
        'single-play-mode', 'archive-mask', 'graphics-backend', 'vsync', 'render-scale', 'aa-mode',
      ]);
      // NativeHudSettings.cpp:28-37 的次级门：aaMode 决定三条渲染倍率行，gpuDeviceCount 决定显卡行。
      SettingsPreferenceContext withAa(String mode, {int gpuCount = 1}) =>
          SettingsPreferenceContext(aaMode: mode, gpuDeviceCount: gpuCount);
      expect(visibleIds(withAa('ssaa')), contains('aa-scale'));
      expect(visibleIds(withAa('msaa')), contains('msaa'));
      expect(visibleIds(withAa('fsr')), containsAll(<String>['fsr-quality', 'fsr-sharpness']));
      expect(visibleIds(withAa('off')), isNot(contains('aa-scale')));
      // gpu-index 只在 Linux 且多卡时出现（NativeHudSettings.cpp:246-257）。
      const SettingsPreferenceContext linuxDualGpu = SettingsPreferenceContext(
        capabilities: PlatformCapabilities.linux(),
        operatingSystem: SettingsOperatingSystem.linux,
        gpuDeviceCount: 2,
      );
      expect(visibleIds(linuxDualGpu), contains('gpu-index'));
      expect(visibleIds(withAa('off', gpuCount: 2)), isNot(contains('gpu-index')));
    });

    test('normalize / switchTarget / nextValue / numericValues', () {
      SettingsPreferenceValue value(String canonical, {int integer = 0}) =>
          SettingsPreferenceValue(canonical: canonical, integer: integer);
      final SettingsDescriptor aaMode = settingsDescriptorById('aa-mode')!;
      final SettingsDescriptor graphics = settingsDescriptorById('graphics-backend')!;
      final SettingsDescriptor msaa = settingsDescriptorById('msaa')!;
      final SettingsDescriptor renderScale = settingsDescriptorById('render-scale')!;
      final SettingsDescriptor archiveMask = settingsDescriptorById('archive-mask')!;
      final SettingsDescriptor theme = settingsDescriptorById('theme')!;
      final SettingsDescriptor close = settingsDescriptorById('close-behavior')!;

      // SettingsSchema.cpp:125-190 normalizeValue()：两处 Qt 专有别名在 Dart 侧保留同一收敛。
      expect(settingsNormalizeValue(aaMode, desktopContext, 'fsr3'), 'fsr');
      expect(settingsNormalizeValue(aaMode, desktopContext, 'fsr1'), 'fsr');
      expect(settingsNormalizeValue(graphics, desktopContext, 'd3d11'), '');
      expect(settingsNormalizeValue(graphics, desktopContext, 'vulkan'), 'vulkan');
      expect(settingsNormalizeValue(theme, desktopContext, 'bogus'), 'light');
      expect(settingsNormalizeValue(close, desktopContext, 'tray'), 'tray');
      expect(settingsNormalizeValue(msaa, desktopContext, '7'), '8');
      expect(settingsNormalizeValue(renderScale, desktopContext, '999'), '100');
      expect(settingsNormalizeValue(renderScale, desktopContext, '40'), '50');
      // 55 与 50/60 等距，nearestStep 用严格小于比较，平局取先出现者（SettingsSchema.cpp:441-452）。
      expect(settingsNormalizeValue(archiveMask, desktopContext, '55'), '50');
      expect(settingsNormalizeValue(archiveMask, desktopContext, '56'), '60');
      expect(settingsNormalizeValue(archiveMask, desktopContext, '999'), '100');

      // SettingsSchema.cpp:293-330 switchTarget()：静态选项循环，否则按 storage 翻转。
      expect(settingsSwitchTarget(theme, desktopContext, value('light')), 'dark');
      expect(settingsSwitchTarget(theme, desktopContext, value('system')), 'light');
      expect(settingsSwitchTarget(close, desktopContext, value('tray')), 'quit');
      expect(settingsSwitchTarget(close, desktopContext, value('quit')), 'tray');

      // SettingsSchema.cpp:332-360 nextValue()：choice 夹取不循环，stepper 按 wrap 取模。
      expect(settingsNextValue(msaa, desktopContext, value('8', integer: 8), 1), '2');
      expect(settingsNextValue(msaa, desktopContext, value('2', integer: 2), -1), '8');
      expect(settingsNextValue(renderScale, desktopContext, value('90', integer: 90), 1), '100');
      expect(settingsNextValue(renderScale, desktopContext, value('100', integer: 100), 1), '100');
      expect(settingsNextValue(theme, desktopContext, value('light'), 1), 'dark');
      expect(settingsNextValue(theme, desktopContext, value('system'), 1), 'system');

      // NativeHudSettings.cpp:26-37 numericValues()。
      expect(settingsNumericValues(msaa), <int>[2, 4, 8]);
      expect(settingsNumericValues(renderScale), <int>[50, 60, 75, 90, 100]);
      expect(settingsNumericValues(archiveMask),
          <int>[0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100]);
    });

    test('settingsValidateRegistry() 对当前注册表零错误', () {
      expect(settingsValidateRegistry(), isEmpty);
    });

    test('恢复默认设置计划：14 步，默认快照全部 unchanged', () {
      final SettingsDefaultsResetPlan plan = settingsDefaultsResetPlan();
      expect(plan.steps.map((SettingsDefaultResetStep s) => s.id).toList(), <String>[
        'close-behavior', 'theme', 'motion', 'startup-animation', 'quality', 'alternative',
        'official-player', 'detail-autoplay', 'single-play-mode', 'archive-mask', 'graphics-backend',
        'vsync', 'render-scale', 'aa-mode',
      ]);
      // 默认快照下 target 与 currentCanonical 全等：planSettingsApply 的第一条就是 unchanged。
      expect(
          plan.steps.every((SettingsDefaultResetStep s) => s.outcome == SettingsCommitOutcome.unchanged),
          isTrue);
      expect(plan.resetsDiscRotation, isFalse);
      expect(plan.clearsAutoUpdate, isTrue);
      expect(plan.resetsDesktopLyrics, isTrue);
      expect(plan.status, '已恢复默认设置');
      expect(plan.scroll, 0);
      expect(plan.clearsExpandedPreference, isTrue);
      expect(SettingsDefaultsResetPlan.autoUpdatePreferenceKey, 'auto-update');
      expect(SettingsDefaultsResetPlan.desktopLyricsEnabledKey, 'desktop-lyrics');
    });

    test('恢复默认设置计划：被改过的偏好落成 action 或 preferenceKey', () {
      const SettingsPreferenceSnapshot changed = SettingsPreferenceSnapshot(
        preferences: <String, String>{
          'close-behavior': 'tray',
          'graphics-backend': 'vulkan',
          'render-scale': '50',
        },
        themeMode: 'dark',
        reducedMotion: true,
        vsync: false,
        archiveMaskStrength: 80,
        quality: 'lossless',
      );
      final SettingsDefaultsResetPlan plan = settingsDefaultsResetPlan(snapshot: changed);
      SettingsDefaultResetStep step(String id) =>
          plan.steps.firstWhere((SettingsDefaultResetStep s) => s.id == id);
      expect(step('close-behavior').outcome, SettingsCommitOutcome.applied);
      expect(step('close-behavior').action, 'close-behavior');
      expect(step('close-behavior').preferenceKey, '');
      expect(step('theme').outcome, SettingsCommitOutcome.applied);
      expect(step('theme').preferenceKey, 'theme');
      expect(step('theme').action, '');
      expect(step('motion').action, 'motion');
      expect(step('quality').action, 'quality:set:exhigh');
      expect(step('archive-mask').action, 'archive-mask:50');
      expect(step('graphics-backend').outcome, SettingsCommitOutcome.applied);
      expect(step('graphics-backend').preferenceKey, 'graphics-backend');
      expect(step('vsync').action, 'vsync');
      expect(step('render-scale').action, 'render-scale:100');
      // official-player 的当前值仍是默认 off，故保持 unchanged（SettingsSchema.cpp:382-490 的顺序）。
      expect(step('official-player').outcome, SettingsCommitOutcome.unchanged);
    });

    test('恢复默认：Android 的 render-scale 回到 75、非 Android 回到 100', () {
      // NativeHudSettings.cpp:495-509：逐 descriptor 应用 descriptor.defaultValue，
      // 而 render-scale 的 default 就是 androidDefaultRenderScale()（Android 75）。
      const SettingsPreferenceContext android = SettingsPreferenceContext(
        capabilities: PlatformCapabilities.android(),
        operatingSystem: SettingsOperatingSystem.android,
      );
      SettingsDefaultResetStep stepFor(SettingsDefaultsResetPlan plan) =>
          plan.steps.firstWhere((SettingsDefaultResetStep s) => s.id == 'render-scale');
      const SettingsPreferenceSnapshot changed = SettingsPreferenceSnapshot(
        preferences: <String, String>{'render-scale': '50'},
      );

      final SettingsDefaultResetStep androidChanged =
          stepFor(settingsDefaultsResetPlan(context: android, snapshot: changed));
      expect(androidChanged.value, '75');
      expect(androidChanged.action, 'render-scale:75');
      expect(androidChanged.outcome, SettingsCommitOutcome.applied);

      // 未改过时 Android 的默认快照本来就等于 75，恢复默认是 no-op（仍是 75，不是 90）。
      final SettingsDefaultResetStep androidDefault =
          stepFor(settingsDefaultsResetPlan(context: android));
      expect(androidDefault.value, '75');
      expect(androidDefault.outcome, SettingsCommitOutcome.unchanged);

      final SettingsDefaultResetStep desktopChanged =
          stepFor(settingsDefaultsResetPlan(snapshot: changed));
      expect(desktopChanged.value, '100');
      expect(desktopChanged.action, 'render-scale:100');
      expect(desktopChanged.outcome, SettingsCommitOutcome.applied);
    });
  });

  group('偏好标签解析：终止性与 raw 读取（SettingsSchema.cpp:227-305）', () {
    SettingsPreferenceValue value(String canonical, {String raw = ''}) =>
        SettingsPreferenceValue(raw: raw.isEmpty ? canonical : raw, canonical: canonical);

    test('settingsThemeLabel 直接遍历 theme 选项，构建七区不递归', () {
      const SettingsPreferenceContext context = SettingsPreferenceContext();
      const SettingsPreferenceSnapshot dark = SettingsPreferenceSnapshot(themeMode: 'dark');
      final SettingsPreferenceValue theme =
          settingsReadPreference(settingsDescriptorById('theme')!, context: context, snapshot: dark);
      expect(theme.canonical, 'dark');
      expect(settingsThemeLabel(context, theme), '暗色');
      expect(settingsThemeLabel(context, value('neon')), 'neon');

      // SettingsSchema.cpp:227-234 直接遍历 themeChoices()；回归：曾经由
      // settingsChoiceLabel -> descriptor.label 回调自身而无限递归。
      // 真注册表构建整卡模型必须终止。
      final List<SettingsSectionModel> models = settingsSectionModels(context: context, snapshot: dark);
      expect(models.length, 7);
      final SettingsSectionModel preferences =
          models.firstWhere((SettingsSectionModel m) => m.spec.id == SettingsSectionId.preferences);
      expect(preferences.rows.firstWhere((SettingsRowSpec r) => r.id == 'theme').label, '暗色');
    });

    test('settingsAaModeLabel 直接遍历 aaChoices；Darwin 不支持时短路', () {
      const SettingsPreferenceContext windows = SettingsPreferenceContext();
      expect(settingsAaModeLabel(windows, value('taa')), 'TAA');
      expect(settingsAaModeLabel(windows, value('fsr')), 'FSR');
      expect(settingsAaModeLabel(windows, value('weird')), 'weird');

      // SettingsSchema.cpp:293-305：Darwin 且 aaEnabled=false 时返回「系统或设备不支持」。
      const SettingsPreferenceContext unsupported = SettingsPreferenceContext(
        operatingSystem: SettingsOperatingSystem.macOS,
        temporalAntialiasingAvailable: false,
      );
      expect(settingsAaModeLabel(unsupported, value('metalfx')), '系统或设备不支持');
      const SettingsPreferenceContext mac = SettingsPreferenceContext(
        operatingSystem: SettingsOperatingSystem.macOS,
      );
      expect(settingsAaModeLabel(mac, value('metalfx')), 'MetalFX Temporal');
      expect(settingsAaModeLabel(mac, value('off')), '关闭');

      // 回归：曾经由 settingsChoiceLabel 回调自身递归；两种 Darwin 配置的整卡模型都必须终止。
      expect(settingsSectionModels(context: unsupported).length, 7);
      expect(settingsSectionModels(context: mac).length, 7);
    });

    test('graphics-backend / gpu-index 标签读 raw preference 而非 normalize 后的 canonical', () {
      const SettingsPreferenceContext context = SettingsPreferenceContext();
      // SettingsSchema.cpp:252-274：saved 来自 host->preference("graphics-backend")，未知值原样回显。
      expect(settingsGraphicsBackendLabel(context, value('', raw: 'foo')), 'foo');
      expect(settingsGraphicsBackendLabel(context, value('vulkan', raw: 'vulkan')), 'Vulkan');
      expect(
          settingsGraphicsBackendLabel(
              const SettingsPreferenceContext(appliedGraphicsBackend: 'vulkan'),
              value('d3d12', raw: 'd3d12')),
          'Vulkan（下次启动：Direct3D 12）');

      // SettingsSchema.cpp:276-291：saved 来自 host->preference("gpu-index").trimmed()。
      const SettingsPreferenceContext twoCards = SettingsPreferenceContext(gpuDeviceCount: 2);
      expect(settingsGpuIndexLabel(twoCards, value('', raw: '5')), '默认（序号 5 不存在）');
      expect(settingsGpuIndexLabel(twoCards, value('', raw: ' 1 ')), '显卡 1');
      expect(settingsGpuIndexLabel(twoCards, value('', raw: '')), '默认');
    });
  });

  group('面板视口 / 滚动轨道 / 滚轮（NativeHudSettings.cpp:164-165,212-224；NativeHudInput.cpp:29-33）', () {
    test('面板视口 = (x+40, y+176, width-80, 660)', () {
      expect(SettingsPanelGeometry.viewport(x: 0, y: 0, width: 1280),
          const Rect.fromLTWH(40, 176, 1200, 660));
      expect(SettingsPanelGeometry.viewport(x: 100, y: 50, width: 1000),
          const Rect.fromLTWH(140, 226, 920, 660));
      expect(SettingsModalMetrics.viewportTop, 176);
      expect(SettingsModalMetrics.viewportBottom, 836);
      expect(SettingsModalMetrics.viewportHeight, 660);
    });

    test('返回按钮 = (x+usable-220, y+18, 167, 54)（NativeHudModal.cpp:199-200）', () {
      expect(SettingsPanelGeometry.backButton(x: 0, y: 0, usable: 1174),
          const Rect.fromLTWH(954, 18, 167, 54));
    });

    test('轨道 = (x+width-24, y+176+30, 3, 660-60)，上下按钮各 23x25（NativeHudSettings.cpp:212-224）', () {
      final Rect track = SettingsPanelGeometry.scrollTrack(x: 0, y: 0, width: 1280);
      expect(track, const Rect.fromLTWH(1256, 206, 3, 600));
      expect(SettingsPanelGeometry.scrollUpButton(track: track, y: 0),
          const Rect.fromLTWH(1246, 176, 23, 25));
      expect(SettingsPanelGeometry.scrollDownButton(track: track, y: 0),
          const Rect.fromLTWH(1246, 811, 23, 25));
      expect(SettingsPanelGeometry.scrollUpAction, 'settings:scroll-up');
      expect(SettingsPanelGeometry.scrollDownAction, 'settings:scroll-down');
      expect(SettingsPanelGeometry.scrollUpGlyph, '↑');
      expect(SettingsPanelGeometry.scrollDownGlyph, '↓');
    });

    test('rail() 只在有滚动余量时返回 thumb（HudScroll.h:50-64）', () {
      const Rect track = Rect.fromLTWH(1256, 206, 3, 600);
      final SettingsScrollRail none = settingsScrollRail(
          track: track, contentHeight: 600, viewportHeight: 660, offset: 0);
      expect(none.visible, isFalse);
      expect(none.thumb, Rect.zero);
      final SettingsScrollRail rail = settingsScrollRail(
          track: track, contentHeight: 2839, viewportHeight: 660, offset: 0);
      expect(rail.visible, isTrue);
      // thumbHeight = clamp(600 * 660 / 2839, min(30,600), 600) = 139.485...
      expect(rail.thumb.height, closeTo(600 * 660 / 2839, 1e-9));
      expect(rail.thumb.top, closeTo(206, 1e-9));
      final SettingsScrollRail bottom = settingsScrollRail(
          track: track, contentHeight: 2839, viewportHeight: 660, offset: 2179);
      expect(bottom.thumb.top, closeTo(206 + (600 - 600 * 660 / 2839), 1e-9));
    });

    test('滚轮步长 66，distance 优先，之后 clamp（HudScroll.h:22-26；NativeHudInput.cpp:33）', () {
      expect(SettingsModalMetrics.wheelStep, 66);
      expect(
          settingsWheelScroll(
              offset: 0, contentHeight: 2839, viewportHeight: 660, steps: 1),
          66);
      expect(
          settingsWheelScroll(
              offset: 66, contentHeight: 2839, viewportHeight: 660, steps: -1),
          0);
      expect(
          settingsWheelScroll(
              offset: 0, contentHeight: 2839, viewportHeight: 660, steps: 1, distance: 120.5),
          120.5);
      // 越过上限必须夹到 maximumScroll = 2179。
      expect(
          settingsWheelScroll(
              offset: 2113, contentHeight: 2839, viewportHeight: 660, steps: 1),
          2179);
      // 负向越过 0 也要夹住。
      expect(
          settingsWheelScroll(
              offset: 10, contentHeight: 2839, viewportHeight: 660, steps: -1, distance: -500),
          0);
    });

    test('滚轮命中窗口：左右各内缩 53，纵向 176..836（NativeHudInput.cpp:29-33）', () {
      const Rect bounds = Rect.fromLTWH(0, 0, 1280, 900);
      expect(
          settingsWheelHits(bounds: bounds, pointerX: 100, pointerY: 200),
          isTrue);
      expect(settingsWheelHits(bounds: bounds, pointerX: 10, pointerY: 200), isFalse);
      expect(settingsWheelHits(bounds: bounds, pointerX: 1270, pointerY: 200), isFalse);
      expect(settingsWheelHits(bounds: bounds, pointerX: 100, pointerY: 100), isFalse);
      expect(settingsWheelHits(bounds: bounds, pointerX: 100, pointerY: 850), isFalse);
      expect(settingsWheelHits(bounds: bounds, pointerX: 100, pointerY: 200, closing: true), isFalse);
      // motionOffset 会把指针位置换算回本地坐标。
      expect(
          settingsWheelHits(
              bounds: bounds, pointerX: 100, pointerY: 250, motionOffset: 100),
          isFalse);
    });

    test('clipSettingsHits 的 first 语义：first 之前的命中原样保留（HudScroll.h:67-86）', () {
      const Rect area = Rect.fromLTWH(0, 0, 100, 660);
      final List<SettingsHitRegion> hits = <SettingsHitRegion>[
        const SettingsHitRegion(Rect.fromLTWH(0, -10, 10, 10), 'header', 'h0'),
        const SettingsHitRegion(Rect.fromLTWH(0, 0, 10, 10), 'inside', 'h1'),
        const SettingsHitRegion(Rect.fromLTWH(0, 650, 10, 20), 'partial', 'h2'),
        const SettingsHitRegion(Rect.fromLTWH(0, 700, 10, 10), 'outside', 'h3'),
      ];
      final List<SettingsHitRegion> clipped = clipSettingsPanelHits(hits, area, first: 2);
      expect(clipped.length, 3);
      // index 0 < first：即使完全在区域外也原样保留。
      expect(clipped[0].rect, const Rect.fromLTWH(0, -10, 10, 10));
      expect(clipped[0].action, 'header');
      // index 1 < first：原样保留。
      expect(clipped[1].rect, const Rect.fromLTWH(0, 0, 10, 10));
      // index 2 >= first：被裁到交集。
      expect(clipped[2].rect, const Rect.fromLTWH(0, 650, 10, 10));
      expect(clipped[2].action, 'partial');
      // index 3 与区域无交集，被丢弃。
      expect(clipped.any((SettingsHitRegion h) => h.action == 'outside'), isFalse);
    });
  });

  group('provider 卡片（NativeHudSettings.cpp:256-308）', () {
    const Rect body = Rect.fromLTWH(54, 222, 1172, 160);

    test('卡片 / 标记 / 切换按钮 / 账号行几何', () {
      // card = (body.left, body.top+4, body.width, 80)（:257）
      expect(settingsProviderCardRect(body), const Rect.fromLTWH(54, 226, 1172, 80));
      // mark = (card.left+14, card.top+17, 46, 46)（:260）
      expect(settingsProviderMarkRect(body), const Rect.fromLTWH(68, 243, 46, 46));
      // switch = (card.right-126, card.top+23, 110, 34)（:271）
      expect(settingsProviderSwitchRect(body), const Rect.fromLTWH(1100, 249, 110, 34));
      // account = (body.left, body.top+98, 320, 46)（:289）
      expect(settingsProviderAccountRect(body), const Rect.fromLTWH(54, 320, 320, 46));
    });

    test('切换按钮的绘制文案与命中 label 是两个不同字符串（:272）', () {
      expect(ProviderCardMetrics.switchPaintLabel, '切换平台 ▾');
      expect(ProviderCardMetrics.switchHitLabel, '切换平台');
      expect(ProviderCardMetrics.switchAction, 'provider');
      expect(ProviderCardMetrics.switchPaintLabel == ProviderCardMetrics.switchHitLabel, isFalse);
    });

    test('账号行四分支（:276-288）', () {
      final ProviderAccountRow local = providerAccountRow(
          const SettingsProviderState(providerId: 'local', providerName: '本地音乐'));
      expect(local.label, '文件夹管理 / 导入与索引');
      expect(local.action, 'discover');
      final ProviderAccountRow siren = providerAccountRow(
          const SettingsProviderState(providerId: 'siren', providerName: '塞壬唱片'));
      expect(siren.label, '塞壬唱片');
      expect(siren.isText, isTrue);
      final ProviderAccountRow anonymous = providerAccountRow(
          const SettingsProviderState(providerId: 'netease', providerName: '网易云音乐'));
      expect(anonymous.label, '登录 / 网易云音乐');
      expect(anonymous.action, 'music:login');
      final ProviderAccountRow logged = providerAccountRow(const SettingsProviderState(
          providerId: 'netease', providerName: '网易云音乐', uid: '42', nickname: '小音'));
      expect(logged.label, '退出登录 / 小音');
      expect(logged.action, 'music:logout');
    });

    test('右侧注释：siren / QQ 会员态 / 其它（:296-304）', () {
      expect(
          providerAccountNote(
              const SettingsProviderState(providerId: 'siren', providerName: '塞壬唱片')),
          '官网曲库 / 无需登录');
      expect(
          providerAccountNote(const SettingsProviderState(
              providerId: 'qq', providerName: 'QQ 音乐', uid: '9', vipLevel: 'free')),
          '免费账号');
      expect(
          providerAccountNote(const SettingsProviderState(
              providerId: 'qq', providerName: 'QQ 音乐', uid: '9', vipLevel: 'green')),
          '绿钻会员');
      expect(
          providerAccountNote(const SettingsProviderState(
              providerId: 'qq', providerName: 'QQ 音乐', uid: '9', vipLevel: 'super')),
          '超级会员');
      expect(
          providerAccountNote(const SettingsProviderState(
              providerId: 'qq', providerName: 'QQ 音乐', uid: '9', vipLevel: 'unknown')),
          '会员状态未知');
      // 表里没有的等级回落到"会员状态未知"。
      expect(
          providerAccountNote(const SettingsProviderState(
              providerId: 'qq', providerName: 'QQ 音乐', uid: '9', vipLevel: 'platinum')),
          '会员状态未知');
      expect(
          providerAccountNote(
              const SettingsProviderState(providerId: 'netease', providerName: '网易云音乐')),
          '各平台账号独立保存');
      expect(providerMembershipNotes.length, 4);
    });

    test('逐条绘制：卡片底、金条、单色标记、三行文本、切换按钮、账号行、注释', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      const SettingsProviderState state = SettingsProviderState(
          providerId: 'qq', providerName: 'QQ 音乐', uid: '9', nickname: '小Q', vipLevel: 'green');
      paintProviderCardSection(
          body: body, state: state, canvas: recorder, palette: darkPalette());

      // :258 卡片填充 soft
      expect(recorder.fills.first.color, darkPalette().soft);
      expect(recorder.fills.first.left, 54);
      expect(recorder.fills.first.top, 226);
      expect(recorder.fills.first.width, 1172);
      expect(recorder.fills.first.height, 80);
      // :259 左侧 3px 金条
      final SettingsFillOp accent = recorder.fills[1];
      expect(accent.left, 54);
      expect(accent.top, 226);
      expect(accent.width, 3);
      expect(accent.height, 80);
      expect(accent.color, darkPalette().gold);
      // :261-267 单色 Apple Music 标记走 custom op
      expect(recorder.customs.length, 1);
      expect(recorder.customs.single.renderer, SettingsAppleMusicMark.renderer);
      expect(recorder.customs.single.body, const Rect.fromLTWH(68, 243, 46, 46));
      // :268-270 三行文本
      final SettingsTextOp current = recorder.textAt('CURRENT PROVIDER / 当前平台')!;
      expect(current.left, 128);
      expect(current.top, 236);
      expect(current.size, 10);
      expect(current.tracking, 0.08);
      expect(current.color, darkPalette().muted);
      final SettingsTextOp name = recorder.textAt('QQ 音乐')!;
      expect(name.left, 128);
      expect(name.top, 250);
      expect(name.size, 20);
      expect(name.weight, SettingsFontWeight.demibold);
      expect(name.tracking, -0.02);
      expect(name.color, darkPalette().ink);
      final SettingsTextOp code = recorder.textAt('QQ')!;
      expect(code.left, 128);
      expect(code.top, 278);
      expect(code.size, 10);
      expect(code.tracking, 0.07);
      // :271-272 切换按钮：命中 label 是"切换平台"而不是"切换平台 ▾"
      final SettingsHitRegion? switchHit = recorder.hitAt('provider');
      expect(switchHit, isNotNull);
      expect(switchHit!.rect, const Rect.fromLTWH(1100, 249, 110, 34));
      expect(switchHit.label, '切换平台');
      expect(recorder.centered.any((SettingsCenteredOp op) => op.value == '切换平台 ▾'), isTrue);
      // :289-295 账号行 action
      final SettingsHitRegion? accountHit = recorder.hitAt('music:logout');
      expect(accountHit, isNotNull);
      expect(accountHit!.rect, const Rect.fromLTWH(54, 320, 320, 46));
      expect(accountHit.label, '退出登录 / 小Q');
      // :305-306 右侧注释位置与文本
      final SettingsTextOp note = recorder.textAt('绿钻会员')!;
      expect(note.left, 390);
      expect(note.top, 336);
      expect(note.size, 12);
      expect(note.color, darkPalette().muted);
    });

    test('塞壬唱片账号行是纯文本，不注册命中（:279-281）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintProviderCardSection(
          body: body,
          state: const SettingsProviderState(providerId: 'siren', providerName: '塞壬唱片'),
          canvas: recorder,
          palette: darkPalette());
      expect(recorder.textAt('塞壬唱片'), isNotNull);
      expect(recorder.hits.any((SettingsHitRegion h) => h.action == 'music:login'), isFalse);
      expect(recorder.hits.any((SettingsHitRegion h) => h.action == 'discover'), isFalse);
      expect(recorder.textAt('官网曲库 / 无需登录'), isNotNull);
    });
  });

  group('平台选择器（NativeHudModal.cpp:5-24,259-291）', () {
    test('候选 5 项顺序固定；非 LocalMusic 平台移除 local', () {
      final List<SettingsProviderDefinition> desktop =
          providerChoices(const PlatformCapabilities.windows());
      expect(desktop.length, 5);
      expect(desktop.map((SettingsProviderDefinition d) => d.id).toList(),
          <String>['siren', 'netease', 'qq', 'kugou', 'local']);
      expect(desktop.map((SettingsProviderDefinition d) => d.name).toList(),
          <String>['塞壬唱片', '网易云音乐', 'QQ 音乐', '酷狗音乐', '本地音乐']);
      expect(desktop.map((SettingsProviderDefinition d) => d.label).toList(),
          <String>['MONSTER SIREN', 'NETEASE', 'QQ MUSIC', 'KUGOU', 'LOCAL']);
      final List<SettingsProviderDefinition> mobile =
          providerChoices(const PlatformCapabilities.android());
      expect(mobile.length, 4);
      expect(mobile.map((SettingsProviderDefinition d) => d.id).toList(),
          <String>['siren', 'netease', 'qq', 'kugou']);
      expect(mobile.any((SettingsProviderDefinition d) => d.id == 'local'), isFalse);
    });

    test('命中 action / label 逐字（:270）', () {
      expect(settingsProviderDefinitions.first.hitAction, 'provider:siren');
      expect(settingsProviderDefinitions.first.hitLabel, '塞壬唱片');
      expect(settingsProviderDefinitions[3].hitAction, 'provider:kugou');
    });

    test('卡片宽 = (width - 12*(n-1))/n，高 展开 190 / 收起 66（:261,266）', () {
      final List<ProviderChoicePlacement> five = placeProviderChoices(
        left: 0,
        top: 258,
        width: 1060,
        providers: providerChoices(const PlatformCapabilities.windows()),
        selectedId: 'qq',
        expanded: true,
      );
      // (1060 - 12 * 4) / 5 = 202.4
      expect(five.length, 5);
      expect(five[0].bounds, const Rect.fromLTWH(0, 258, 202.4, 190));
      expect(five[1].bounds.left, closeTo(214.4, 1e-9));
      expect(five[2].bounds.left, closeTo(428.8, 1e-9));
      expect(five[3].bounds.left, closeTo(643.2, 1e-9));
      expect(five[4].bounds.left, closeTo(857.6, 1e-9));
      expect(five[4].bounds.width, closeTo(202.4, 1e-9));
      // 选中项与文案
      expect(five[2].selected, isTrue);
      expect(five[2].labelText, 'QQ MUSIC / ACTIVE');
      expect(five[0].labelText, 'MONSTER SIREN');
      expect(five[2].nameSize, 22);
      final List<ProviderChoicePlacement> collapsed = placeProviderChoices(
        left: 0,
        top: 258,
        width: 1060,
        providers: providerChoices(const PlatformCapabilities.windows()),
        selectedId: 'qq',
        expanded: false,
      );
      expect(collapsed.first.bounds.height, 66);
      expect(collapsed.first.nameSize, 17);
    });

    test('4 项时宽度 = (width - 12*3)/4（Android 恒 4 项）', () {
      final List<ProviderChoicePlacement> four = placeProviderChoices(
        left: 53,
        top: 258,
        width: 1060,
        providers: providerChoices(const PlatformCapabilities.android()),
        selectedId: 'siren',
        expanded: true,
      );
      // (1060 - 36) / 4 = 256
      expect(four.length, 4);
      expect(four[0].bounds, const Rect.fromLTWH(53, 258, 256, 190));
      expect(four[1].bounds.left, closeTo(321, 1e-9));
      expect(four[3].bounds.left, closeTo(857, 1e-9));
      expect(four[3].bounds.width, closeTo(256, 1e-9));
    });

    test('选中底色与金条色（:267-272）', () {
      expect(providerChoiceTint(dark: true, selected: true), const SettingsRgba(0.55, 0.59, 0.46, 0.3));
      expect(providerChoiceTint(dark: true, selected: false), const SettingsRgba(0.55, 0.59, 0.46, 0.12));
      expect(providerChoiceTint(dark: false, selected: true), const SettingsRgba(0.44, 0.49, 0.36, 0.23));
      expect(providerChoiceTint(dark: false, selected: false), const SettingsRgba(0.44, 0.49, 0.36, 0.09));
      expect(providerChoiceAccent(dark: true), const SettingsRgba(0.7, 0.75, 0.53, 1));
      expect(providerChoiceAccent(dark: false), const SettingsRgba(0.44, 0.49, 0.36, 1));
    });
  });

  group('performance 自定义区（NativeHudSettings.cpp:310-330）', () {
    const Rect body = Rect.fromLTWH(54, 1814, 1172, 220);

    test('两行标签随 discRotation 切换（:324-326）', () {
      final SettingsRowRecorder off = SettingsRowRecorder();
      paintPerformanceSection(
          body: body, discRotation: false, canvas: off, palette: darkPalette());
      expect(off.centered.any((SettingsCenteredOp op) => op.value == '关闭 / 点击了解风险'), isTrue);
      expect(off.centered.any((SettingsCenteredOp op) => op.value == '开启 / 点击关闭'), isFalse);
      final SettingsRowRecorder on = SettingsRowRecorder();
      paintPerformanceSection(
          body: body, discRotation: true, canvas: on, palette: darkPalette());
      expect(on.centered.any((SettingsCenteredOp op) => op.value == '开启 / 点击关闭'), isTrue);
      expect(on.centered.any((SettingsCenteredOp op) => op.value == '关闭 / 点击了解风险'), isFalse);
    });

    test('第一行固定文案与命中（:320-321）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintPerformanceSection(
          body: body, discRotation: false, canvas: recorder, palette: darkPalette());
      expect(recorder.centered.any((SettingsCenteredOp op) => op.value == '显示 / 隐藏 · F10'), isTrue);
      final SettingsHitRegion? hit = recorder.hitAt('performance:toggle');
      expect(hit, isNotNull);
      expect(hit!.rect, const Rect.fromLTWH(926, 1826, 300, 48));
      expect(hit.label, '性能面板');
      final SettingsHitRegion? disc = recorder.hitAt('disc-rotation');
      expect(disc, isNotNull);
      expect(disc!.rect, const Rect.fromLTWH(926, 1924, 300, 48));
      expect(disc.label, '唱片旋转');
    });

    test('标题与下划线位置（:315-318）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintPerformanceSection(
          body: body, discRotation: false, canvas: recorder, palette: darkPalette());
      final SettingsTextOp firstEn = recorder.textAt('PERFORMANCE')!;
      expect(firstEn.left, 54);
      expect(firstEn.top, 1828);
      expect(firstEn.size, 11);
      expect(firstEn.tracking, 0.08);
      final SettingsTextOp firstZh = recorder.textAt('性能面板')!;
      expect(firstZh.top, 1843);
      expect(firstZh.size, 17);
      expect(firstZh.weight, SettingsFontWeight.demibold);
      final SettingsTextOp secondEn = recorder.textAt('DISC ROTATION')!;
      expect(secondEn.top, 1926);
      // 下划线：fill(body.left, body.top + top + 62, body.width, 1)
      expect(
          recorder.fills.any((SettingsFillOp op) =>
              op.left == 54 && op.top == 1880 && op.width == 1172 && op.height == 1),
          isTrue);
      expect(
          recorder.fills.any((SettingsFillOp op) =>
              op.left == 54 && op.top == 1978 && op.width == 1172 && op.height == 1),
          isTrue);
    });

    test('两条帮助文案逐字（:322-323,327-328）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintPerformanceSection(
          body: body, discRotation: false, canvas: recorder, palette: darkPalette());
      final SettingsTextOp help1 = recorder.textAt('在性能面板内手动收集、导出诊断文件。')!;
      expect(help1.left, 54);
      expect(help1.top, 1892);
      expect(help1.size, 13);
      final SettingsTextOp help2 = recorder.textAt('默认关闭；开启会增加持续渲染、耗电和发热。')!;
      expect(help2.left, 54);
      expect(help2.top, 1990);
      expect(help2.size, 13);
    });
  });

  group('storage 自定义区（NativeHudSettings.cpp:332-342）', () {
    const Rect body = Rect.fromLTWH(54, 2104, 1172, 105);

    test('label = cacheMessage.isEmpty ? 清除缓存 : cacheMessage（:336-337）', () {
      final SettingsRowRecorder empty = SettingsRowRecorder();
      paintStorageSection(
          body: body, cacheMessage: '', canvas: empty, palette: darkPalette());
      expect(empty.centered.any((SettingsCenteredOp op) => op.value == '清除缓存'), isTrue);
      final SettingsRowRecorder filled = SettingsRowRecorder();
      paintStorageSection(
          body: body, cacheMessage: '已清除', canvas: filled, palette: darkPalette());
      expect(filled.centered.any((SettingsCenteredOp op) => op.value == '已清除'), isTrue);
      expect(filled.centered.any((SettingsCenteredOp op) => op.value == '清除缓存'), isFalse);
      // 命中 label 恒为"清除缓存"，不随文案变化（:337）。
      final SettingsHitRegion? hit = filled.hitAt('cache:clear');
      expect(hit, isNotNull);
      expect(hit!.label, '清除缓存');
      expect(hit.rect, const Rect.fromLTWH(926, 2112, 300, 48));
      expect(storageCacheActionLabel(''), '清除缓存');
      expect(storageCacheActionLabel('已清除'), '已清除');
      expect(storageCacheHitLabel, '清除缓存');
    });

    test('标题与帮助文案（:334-340）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintStorageSection(
          body: body, cacheMessage: '', canvas: recorder, palette: darkPalette());
      final SettingsTextOp en = recorder.textAt('STORAGE')!;
      expect(en.top, 2114);
      expect(en.size, 11);
      final SettingsTextOp zh = recorder.textAt('存储与缓存')!;
      expect(zh.top, 2129);
      expect(zh.size, 17);
      expect(zh.weight, SettingsFontWeight.demibold);
      final SettingsTextOp help = recorder.textAt('清理元数据、歌词、封面与列表缓存，保留主题和账号。')!;
      expect(help.top, 2176);
      expect(help.size, 13);
      // 下划线在 top+62 处
      expect(
          recorder.fills.any((SettingsFillOp op) =>
              op.left == 54 && op.top == 2166 && op.width == 1172 && op.height == 1),
          isTrue);
    });
  });

  group('update 自定义区（NativeHudSettings.cpp:344-370）', () {
    const Rect body = Rect.fromLTWH(54, 2279, 1172, 220);

    test('版本行：发布构建不带后缀（:346-347）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintUpdateSection(
        body: body,
        version: '1.4.2',
        commitTitle: 'abc123 修复设置页',
        releaseBuild: true,
        updaterStatus: '',
        prefersAutoUpdate: true,
        busy: false,
        updateAvailable: false,
        canvas: recorder,
        palette: darkPalette(),
      );
      final SettingsTextOp version = recorder.textAt('当前版本 / 1.4.2')!;
      expect(version.left, 54);
      expect(version.top, 2283);
      expect(version.size, 18);
      expect(version.weight, SettingsFontWeight.demibold);
      // 非发布构建才画 commitTitle（:349）。
      expect(recorder.textAt('abc123 修复设置页'), isNull);
    });

    test('非发布构建：追加 · 开发版 并绘制 commitTitle（:345,349）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintUpdateSection(
        body: body,
        version: '1.4.2',
        commitTitle: 'abc123 修复设置页',
        releaseBuild: false,
        updaterStatus: '当前已是最新版本',
        prefersAutoUpdate: false,
        busy: false,
        updateAvailable: false,
        canvas: recorder,
        palette: darkPalette(),
      );
      expect(recorder.textAt('当前版本 / 1.4.2 · 开发版'), isNotNull);
      final SettingsTextOp commit = recorder.textAt('abc123 修复设置页')!;
      expect(commit.left, 54);
      expect(commit.top, 2311);
      expect(commit.size, 12);
      expect(commit.color, darkPalette().muted);
      final SettingsTextOp status = recorder.textAt('当前已是最新版本')!;
      expect(status.top, 2347);
      expect(status.size, 13);
    });

    test('自动检查块：off/on 两种文案（:351-355）', () {
      final SettingsRowRecorder off = SettingsRowRecorder();
      paintUpdateSection(
        body: body,
        version: '1.0.0',
        commitTitle: '',
        releaseBuild: true,
        updaterStatus: '',
        prefersAutoUpdate: false,
        busy: false,
        updateAvailable: false,
        canvas: off,
        palette: darkPalette(),
      );
      final SettingsHitRegion? autoHit = off.hitAt('update:auto');
      expect(autoHit, isNotNull);
      expect(autoHit!.rect, const Rect.fromLTWH(926, 2329, 300, 48));
      expect(autoHit.label, '启动检查');
      expect(off.centered.any((SettingsCenteredOp op) => op.value == '启动检查 / 关闭'), isTrue);
      final SettingsRowRecorder on = SettingsRowRecorder();
      paintUpdateSection(
        body: body,
        version: '1.0.0',
        commitTitle: '',
        releaseBuild: true,
        updaterStatus: '',
        prefersAutoUpdate: true,
        busy: false,
        updateAvailable: false,
        canvas: on,
        palette: darkPalette(),
      );
      expect(on.centered.any((SettingsCenteredOp op) => op.value == '启动检查 / 开启'), isTrue);
    });

    test('检查块：busy 时是取消，否则检查更新（:358-360）', () {
      final SettingsRowRecorder idle = SettingsRowRecorder();
      paintUpdateSection(
        body: body,
        version: '1.0.0',
        commitTitle: '',
        releaseBuild: true,
        updaterStatus: '',
        prefersAutoUpdate: true,
        busy: false,
        updateAvailable: false,
        canvas: idle,
        palette: darkPalette(),
      );
      final SettingsHitRegion? check = idle.hitAt('update:check');
      expect(check, isNotNull);
      expect(check!.rect, const Rect.fromLTWH(54, 2391, 170, 46));
      expect(check.label, '检查更新');
      expect(idle.centered.any((SettingsCenteredOp op) => op.value == '检查更新'), isTrue);
      final SettingsRowRecorder busy = SettingsRowRecorder();
      paintUpdateSection(
        body: body,
        version: '1.0.0',
        commitTitle: '',
        releaseBuild: true,
        updaterStatus: '正在检查更新…',
        prefersAutoUpdate: true,
        busy: true,
        updateAvailable: false,
        canvas: busy,
        palette: darkPalette(),
      );
      final SettingsHitRegion? cancel = busy.hitAt('update:cancel');
      expect(cancel, isNotNull);
      expect(cancel!.label, '检查更新');
      expect(busy.centered.any((SettingsCenteredOp op) => op.value == '取消'), isTrue);
      expect(busy.hits.any((SettingsHitRegion h) => h.action == 'update:check'), isFalse);
    });

    test('前往更新 只在 !busy && available 时出现（:361-364）', () {
      final SettingsRowRecorder available = SettingsRowRecorder();
      paintUpdateSection(
        body: body,
        version: '1.0.0',
        commitTitle: '',
        releaseBuild: true,
        updaterStatus: '发现新版本 1.5.0',
        prefersAutoUpdate: true,
        busy: false,
        updateAvailable: true,
        canvas: available,
        palette: darkPalette(),
      );
      expect(available.centered.any((SettingsCenteredOp op) => op.value == '前往更新 ↗'), isTrue);
      expect(
          available.hits.any((SettingsHitRegion h) =>
              h.action == 'update:release' &&
              h.label == '前往更新' &&
              h.rect == const Rect.fromLTWH(240, 2391, 210, 46)),
          isTrue);
      final SettingsRowRecorder none = SettingsRowRecorder();
      paintUpdateSection(
        body: body,
        version: '1.0.0',
        commitTitle: '',
        releaseBuild: true,
        updaterStatus: '',
        prefersAutoUpdate: true,
        busy: false,
        updateAvailable: false,
        canvas: none,
        palette: darkPalette(),
      );
      expect(none.centered.any((SettingsCenteredOp op) => op.value == '前往更新 ↗'), isFalse);
    });

    test('发布说明 无条件恒绘制，且不并入条件行（:365-366）', () {
      for (final bool busy in <bool>[false, true]) {
        final SettingsRowRecorder recorder = SettingsRowRecorder();
        paintUpdateSection(
          body: body,
          version: '1.0.0',
          commitTitle: '',
          releaseBuild: true,
          updaterStatus: '',
          prefersAutoUpdate: true,
          busy: busy,
          updateAvailable: false,
          canvas: recorder,
          palette: darkPalette(),
        );
        expect(recorder.centered.any((SettingsCenteredOp op) => op.value == '发布说明 ↗'), isTrue,
            reason: 'busy=' + busy.toString());
        final List<SettingsHitRegion> notesHits = recorder.hits
            .where((SettingsHitRegion h) =>
                h.action == 'update:release' && h.label == '发布说明')
            .toList();
        expect(notesHits.length, 1);
        expect(notesHits.first.rect, const Rect.fromLTWH(1016, 2391, 210, 46));
      }
    });

    test('帮助文案 12pt（:367-368）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintUpdateSection(
        body: body,
        version: '1.0.0',
        commitTitle: '',
        releaseBuild: true,
        updaterStatus: '',
        prefersAutoUpdate: true,
        busy: false,
        updateAvailable: false,
        canvas: recorder,
        palette: darkPalette(),
      );
      final SettingsTextOp help = recorder.textAt('更新将打开 GitHub 发布页面，请在浏览器中下载并安装。')!;
      expect(help.left, 54);
      expect(help.top, 2455);
      expect(help.size, 12);
      expect(help.color, darkPalette().muted);
    });
  });

  group('footer（defaults）自定义区（NativeHudSettings.cpp:372-379）', () {
    const Rect body = Rect.fromLTWH(54, 2879, 1172, 84);

    test('恢复块 300x46 与帮助文案（:373-377）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintDefaultsSection(body: body, canvas: recorder, palette: darkPalette());
      final SettingsHitRegion? hit = recorder.hitAt('settings:restore-defaults');
      expect(hit, isNotNull);
      expect(hit!.rect, const Rect.fromLTWH(54, 2885, 300, 46));
      expect(hit.label, '恢复默认设置');
      expect(recorder.centered.any((SettingsCenteredOp op) => op.value == '恢复默认设置'), isTrue);
      final SettingsTextOp help = recorder.textAt('仅重置终端偏好，平台、账号与更新状态保持不变。')!;
      expect(help.left, 370);
      expect(help.top, 2899);
      expect(help.size, 12);
    });
  });

  group('表头（SettingsCard.cpp:36-45）', () {
    test('序号 / 标题 / 下划线的位置与字号', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsSectionLayout section = SettingsSectionLayout(
        section: settingsSections[0],
        header: const Rect.fromLTWH(40, 176, 1200, 46),
        body: const Rect.fromLTWH(54, 222, 1172, 160),
        rows: const <SettingsRowLayout>[],
        height: 206,
      );
      paintSettingsSectionHeader(section: section, canvas: recorder, palette: darkPalette());
      // 序号绘于 header.left() + ContentInset = 54，top + 12 = 188，11pt（:40-41）
      final SettingsTextOp index = recorder.textAt('01')!;
      expect(index.left, 54);
      expect(index.top, 188);
      expect(index.size, 11);
      expect(index.tracking, 0.05);
      expect(index.color, darkPalette().muted);
      // 标题 left + 26 = 80，top + 9 = 185，14pt demibold（:42-43）
      final SettingsTextOp title = recorder.textAt('PROVIDER ACCESS / 音乐平台')!;
      expect(title.left, 80);
      expect(title.top, 185);
      expect(title.size, 14);
      expect(title.weight, SettingsFontWeight.demibold);
      expect(title.tracking, 0.06);
      expect(title.color, darkPalette().ink);
      // 下划线：fill(left, header.bottom()-1, width - 2*ContentInset, 1)（:44）
      final SettingsFillOp rule = recorder.fills.single;
      expect(rule.left, 54);
      expect(rule.top, 221);
      expect(rule.width, 1172);
      expect(rule.height, 1);
      expect(rule.color, darkPalette().line);
    });

    test('scroll 会把表头一起上移（SettingsCard.cpp:297）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsSectionLayout section = SettingsSectionLayout(
        section: settingsSections[0],
        header: const Rect.fromLTWH(40, 176, 1200, 46),
        body: const Rect.fromLTWH(54, 222, 1172, 160),
        rows: const <SettingsRowLayout>[],
        height: 206,
      );
      paintSettingsSectionHeader(
          section: section, canvas: recorder, palette: darkPalette(), scroll: 30);
      expect(recorder.textAt('01')!.top, 158);
      expect(recorder.fills.single.top, 191);
    });
  });

  group('整卡绘制与命中裁剪（SettingsCard.cpp:294-327；NativeHudSettings.cpp:205-210）', () {
    test('表头 / 自定义区 / 行 / 滚动按钮的数量与裁剪 first 语义', () {
      final SettingsCardLayout layout =
          layoutSettingsCard(viewport: viewport, model: desktopSectionModel());
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      // 模拟 Qt：先记录 firstHit = hits.size()，绘制后 clipHits(hits, firstHit, viewport)。
      const int firstHit = 0;
      paintSettingsCard(
        layout: layout,
        scroll: 0,
        canvas: recorder,
        palette: darkPalette(),
        custom: const SettingsCustomSectionState(
          provider: SettingsProviderState(providerId: 'netease', providerName: '网易云音乐'),
          version: '1.0.0',
          releaseBuild: true,
        ),
      );
      expect(recorder.hits, isNotEmpty);
      // SettingsCard.cpp:299 header.intersects(viewport) 才画表头：
      // preferences(406) / performance(1768) 的表头落在 176..836；footer(2833) 不在。
      expect(recorder.textAt('01'), isNotNull);
      expect(recorder.textAt('02'), isNotNull);
      expect(recorder.textAt('07'), isNull);
      // SettingsCard.cpp:300-305 自定义区要 body 与视口相交才分发：
      // provider body 222..382 相交；performance 1814..2034、storage 2104..2209、
      // update 2279..2499、footer 2879..2963 整块在视口下方。
      expect(recorder.textAt('CURRENT PROVIDER / 当前平台'), isNotNull);
      expect(recorder.textAt('在性能面板内手动收集、导出诊断文件。'), isNull);
      expect(recorder.textAt('清理元数据、歌词、封面与列表缓存，保留主题和账号。'), isNull);
      expect(recorder.textAt('更新将打开 GitHub 发布页面，请在浏览器中下载并安装。'), isNull);
      expect(recorder.textAt('恢复默认设置'), isNull);
      final List<SettingsHitRegion> clipped =
          clipSettingsPanelHits(recorder.hits, viewport, first: firstHit);
      // 所有命中都必须落在视口内（first=0 表示整批参与裁剪）。
      for (final SettingsHitRegion hit in clipped) {
        expect(hit.rect.top, greaterThanOrEqualTo(viewport.top - 1e-9));
        expect(hit.rect.bottom, lessThanOrEqualTo(viewport.bottom + 1e-9));
      }
      // 反向断言：行控件同样整行绘制，越界命中只能靠 clipHits 收回来。
      // replay 是 index 5 的 action 行：bounds 832..898、control 841..889 > 836
      // （SettingsCard.cpp:307-317 只判整行相交 + HudScroll.h:67-86）。
      expect(
          recorder.hits.any((SettingsHitRegion h) =>
              h.action == 'replay' && h.rect.bottom > viewport.bottom),
          isTrue);

      // 第二遍：滚到底（maximumScroll = 2179）后可见性整体上移。
      final SettingsRowRecorder bottomRecorder = SettingsRowRecorder();
      paintSettingsCard(
        layout: layout,
        scroll: layout.maximumScroll,
        canvas: bottomRecorder,
        palette: darkPalette(),
        custom: const SettingsCustomSectionState(
          provider: SettingsProviderState(providerId: 'netease', providerName: '网易云音乐'),
          version: '1.0.0',
          releaseBuild: true,
        ),
      );
      // update header 2233-2179 = 54（54..100 不与视口相交，故序号 05 不画）；
      // update body 2279-2179 = 100..320，帮助行 2455-2179 = 276 可见；
      // footer body 2879-2179 = 700..784。
      expect(layout.sections[4].header.top, 54);
      expect(bottomRecorder.textAt('05'), isNull);
      expect(
          bottomRecorder.textAt('更新将打开 GitHub 发布页面，请在浏览器中下载并安装。'), isNotNull);
      expect(bottomRecorder.textAt('恢复默认设置'), isNotNull);
      // project header 2523-2179 = 344 与 footer header 2833-2179 = 654 都在视口内。
      expect(bottomRecorder.textAt('06'), isNotNull);
      expect(bottomRecorder.textAt('07'), isNotNull);
      // provider body 222-2179 = -1957..-1797、performance 1814-2179 = -365..-145，均不相交。
      expect(bottomRecorder.textAt('CURRENT PROVIDER / 当前平台'), isNull);
      expect(bottomRecorder.textAt('在性能面板内手动收集、导出诊断文件。'), isNull);
    });

    test('滚动后仍从同一视口裁剪，先绘制的表头命中不受影响', () {
      final SettingsCardLayout layout =
          layoutSettingsCard(viewport: viewport, model: desktopSectionModel());
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      // 先放一条属于更早图层的命中（例如模态返回按钮），index 0 < first。
      recorder.hit(954, 18, 167, 54, 'close-modal', '← 返回');
      final int firstHit = recorder.hits.length;
      paintSettingsCard(
        layout: layout,
        scroll: 120,
        canvas: recorder,
        palette: darkPalette(),
        custom: const SettingsCustomSectionState(),
      );
      final List<SettingsHitRegion> clipped =
          clipSettingsPanelHits(recorder.hits, viewport, first: firstHit);
      expect(clipped.first.action, 'close-modal');
      expect(clipped.first.rect, const Rect.fromLTWH(954, 18, 167, 54));
      for (final SettingsHitRegion hit in clipped.skip(1)) {
        expect(hit.rect.top, greaterThanOrEqualTo(viewport.top - 1e-9));
        expect(hit.rect.bottom, lessThanOrEqualTo(viewport.bottom + 1e-9));
      }
    });

    test('滚动按钮的绘制与命中（NativeHudSettings.cpp:223-224）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      final SettingsCardLayout layout =
          layoutSettingsCard(viewport: viewport, model: desktopSectionModel());
      paintSettingsPanel(
        x: 0,
        y: 0,
        width: 1280,
        layout: layout,
        scroll: 0,
        canvas: recorder,
        palette: darkPalette(),
        custom: const SettingsCustomSectionState(),
        dark: true,
      );
      final SettingsHitRegion? up = recorder.hitAt('settings:scroll-up');
      expect(up, isNotNull);
      expect(up!.rect, const Rect.fromLTWH(1246, 176, 23, 25));
      expect(up.label, '↑');
      final SettingsHitRegion? down = recorder.hitAt('settings:scroll-down');
      expect(down, isNotNull);
      expect(down!.rect, const Rect.fromLTWH(1246, 811, 23, 25));
      expect(down.label, '↓');
      // NativeHud.cpp:110-120 的 button() 模态分支（m_modalControls=true，NativeHudModal.cpp:174）：
      // 先铺底色再左对齐 fit(glyph, 14, 23 - 2 * 2.875)；inset = min(10, 23/8) = 2.875。
      expect(
          recorder.fills.any((SettingsFillOp op) =>
              op.left == 1246 &&
              op.top == 176 &&
              op.width == 23 &&
              op.height == 25 &&
              op.color == const SettingsRgba(0.55, 0.59, 0.46, 0.13)),
          isTrue);
      final SettingsTextOp upText = recorder.textAt('↑')!;
      expect(upText.left, 1248.875);
      expect(upText.top, 177.5);
      expect(upText.size, 14);
      expect(upText.color, darkPalette().ink);
      // 轨道固定绘制，thumb 在 contentHeight > viewportHeight 时才出现。
      expect(
          recorder.fills.any((SettingsFillOp op) =>
              op.left == 1256 && op.top == 206 && op.width == 3 && op.height == 600),
          isTrue);
      expect(
          recorder.fills.any((SettingsFillOp op) =>
              op.left == 1256 && op.top == 206 && op.width == 3 && op.height != 600),
          isTrue);
    });
  });

  group('模态框架（NativeHudModal.cpp:188-202）', () {
    test('类别标签 / 标题 / 副标题的文案、字号与位置', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintSettingsModalFrame(
          x: 0, y: 0, usable: 1174, canvas: recorder, palette: darkPalette());
      expect(SettingsModalFrame.categoryText, 'RHINE LAB / MUSIC DATABASE / SYSTEM PREFERENCES');
      final SettingsTextOp category = recorder.textAt(SettingsModalFrame.categoryText)!;
      expect(category.left, 53);
      expect(category.top, 37);
      expect(category.size, 14);
      // NativeHudModal.cpp:198 不传 color → NativeHud.cpp:40-43 默认 ink()（不是 muted）。
      expect(category.color, darkPalette().ink);
      expect(category.color, isNot(darkPalette().muted));
      final SettingsTextOp title = recorder.textAt('SYSTEM SETTINGS')!;
      expect(title.left, 53);
      expect(title.top, 91);
      expect(title.size, 38);
      expect(title.weight, SettingsFontWeight.demibold);
      final SettingsTextOp subtitle = recorder.textAt('终端偏好设置')!;
      expect(subtitle.left, 53);
      expect(subtitle.top, 147);
      expect(subtitle.size, 18);
    });

    test('返回按钮 (x+usable-220, y+18, 167, 54) 命中 close-modal（:199-200）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintSettingsModalFrame(
          x: 0, y: 0, usable: 1174, canvas: recorder, palette: darkPalette());
      final SettingsHitRegion? back = recorder.hitAt('close-modal');
      expect(back, isNotNull);
      expect(back!.rect, const Rect.fromLTWH(954, 18, 167, 54));
      expect(back.label, '← 返回');
      // NativeHudModal.cpp:174 置 m_modalControls=true 且 settings 分支不复位（:175-187 只复位
      // player/discover）→ NativeHud.cpp:110-120：底色 + inset=min(10, 167/8)=10 + 左对齐 fit。
      expect(
          recorder.fills.any((SettingsFillOp op) =>
              op.left == 954 &&
              op.top == 18 &&
              op.width == 167 &&
              op.height == 54 &&
              op.color == const SettingsRgba(0.44, 0.49, 0.36, 0.1)),
          isTrue);
      final SettingsTextOp backText = recorder.textAt('← 返回')!;
      expect(backText.left, 964);
      expect(backText.top, 31);
      expect(backText.size, 20);
      expect(backText.weight, SettingsFontWeight.demibold);
      expect(recorder.centered.where((SettingsCenteredOp op) => op.value == '← 返回'), isEmpty);
    });

    test('x / y 偏移整体平移（模态不是从 (0,0) 起）', () {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      paintSettingsModalFrame(
          x: 100, y: 50, usable: 900, canvas: recorder, palette: darkPalette());
      expect(recorder.textAt(SettingsModalFrame.categoryText)!.left, 153);
      expect(recorder.textAt(SettingsModalFrame.categoryText)!.top, 87);
      expect(recorder.textAt('SYSTEM SETTINGS')!.top, 141);
      expect(recorder.textAt('终端偏好设置')!.top, 197);
      expect(recorder.hitAt('close-modal')!.rect, const Rect.fromLTWH(780, 68, 167, 54));
    });

    test('遮罩 + 面板底：先铺满 1080 高遮罩，再铺 modalBounds 的 836 面板（NativeHudModal.cpp:163-172）', () {
      // NativeHud.cpp:153-158：width 1280 → modalWidth = min(1260, 1180) = 1180，left = 50，y = 122。
      expect(settingsModalBounds(1280), const Rect.fromLTWH(50, 122, 1180, 836));
      final SettingsRowRecorder light = SettingsRowRecorder();
      paintSettingsModalBackdrop(
          width: 1280, bounds: settingsModalBounds(1280), canvas: light);
      expect(light.fills.length, 2);
      final SettingsFillOp mask = light.fills[0];
      expect(mask.left, 0);
      expect(mask.top, 0);
      expect(mask.width, 1280);
      expect(mask.height, 1080);
      // NativeHudModal.cpp:163-165：浅色 227/224/215，settings 的 search=false → alpha 0.45。
      expect(mask.color, const SettingsRgba(227 / 255, 224 / 255, 215 / 255, 0.45));
      final SettingsFillOp panel = light.fills[1];
      expect(panel.left, 50);
      expect(panel.top, 122);
      expect(panel.width, 1180);
      expect(panel.height, 836);
      // NativeHudModal.cpp:171-172：浅色 0.929/0.922/0.894 不透明。
      expect(panel.color, const SettingsRgba(0.929, 0.922, 0.894, 1));

      final SettingsRowRecorder dark = SettingsRowRecorder();
      paintSettingsModalBackdrop(
          width: 1280, bounds: settingsModalBounds(1280), canvas: dark, dark: true);
      expect(dark.fills[0].color, const SettingsRgba(17 / 255, 24 / 255, 27 / 255, 0.6));
      expect(dark.fills[1].color, const SettingsRgba(0.15, 0.15, 0.15, 1));
    });
  });

  group('编辑浮层（Overlay.qml:563-602；NativeHudSettings.cpp:109-161）', () {
    test('几何：背景 = rect*scale，文本左内缩 12，宽 -24，字号 16', () {
      const Rect settingRect = Rect.fromLTWH(926, 461, 300, 48);
      final SettingsEditOverlayGeometry overlay =
          settingsEditOverlay(settingRect: settingRect, modalOffset: 24);
      // y 会加上 modalOffset（Overlay.qml:568）。
      expect(overlay.background, const Rect.fromLTWH(926, 485, 300, 48));
      expect(overlay.text, const Rect.fromLTWH(938, 485, 276, 48));
      expect(overlay.fontSize, 16);
      expect(overlay.stageScale, 1);
    });

    test('stageScale 同时缩放位置 / 尺寸 / 字号（Overlay.qml:567-585）', () {
      const Rect settingRect = Rect.fromLTWH(926, 461, 300, 48);
      final SettingsEditOverlayGeometry overlay =
          settingsEditOverlay(settingRect: settingRect, modalOffset: 24, stageScale: 2);
      expect(overlay.background, const Rect.fromLTWH(1852, 970, 600, 96));
      expect(overlay.text, const Rect.fromLTWH(1876, 970, 552, 96));
      expect(overlay.fontSize, 32);
    });

    test('宽度不足时文本宽夹到 0，不为负（Overlay.qml:581 Math.max(0, ...)）', () {
      final SettingsEditOverlayGeometry overlay = settingsEditOverlay(
          settingRect: const Rect.fromLTWH(10, 20, 20, 40), modalOffset: 0);
      expect(overlay.text.width, 0);
      expect(overlay.text.height, 40);
    });

    test('配色：深色 #2b332c / #4a554b / #e9e7da，浅色 #e5e7da / #aab0a0 / #222a25（Overlay.qml:571-586）', () {
      expect(SettingsEditOverlayMetrics.background(true),
          const SettingsRgba(0x2b / 255, 0x33 / 255, 0x2c / 255, 1));
      expect(SettingsEditOverlayMetrics.border(true),
          const SettingsRgba(0x4a / 255, 0x55 / 255, 0x4b / 255, 1));
      expect(SettingsEditOverlayMetrics.textColor(true),
          const SettingsRgba(0xe9 / 255, 0xe7 / 255, 0xda / 255, 1));
      expect(SettingsEditOverlayMetrics.background(false),
          const SettingsRgba(0xe5 / 255, 0xe7 / 255, 0xda / 255, 1));
      expect(SettingsEditOverlayMetrics.border(false),
          const SettingsRgba(0xaa / 255, 0xb0 / 255, 0xa0 / 255, 1));
      expect(SettingsEditOverlayMetrics.textColor(false),
          const SettingsRgba(0x22 / 255, 0x2a / 255, 0x25 / 255, 1));
      expect(SettingsEditOverlayMetrics.borderWidth, 1);
      expect(SettingsEditOverlayMetrics.textInset, 12);
      expect(SettingsEditOverlayMetrics.accessibleName, '设置文本');
      expect(SettingsEditOverlayMetrics.objectName, 'musicSettingEditInput');
    });
  });

  group('性能面板本体（PerformancePanel.qml:1-150）', () {
    test('四按钮顺序、宽度与 Accessible.name 逐字', () {
      final List<PerformancePanelButton> buttons = performancePanelButtons(
        left: 12,
        top: 100,
        expanded: true,
        recording: false,
        recordingAction: '开始收集',
      );
      expect(buttons.length, 4);
      expect(buttons[0].rect, const Rect.fromLTWH(12, 100, 140, 30));
      expect(buttons[1].rect, const Rect.fromLTWH(158, 100, 82, 30));
      expect(buttons[2].rect, const Rect.fromLTWH(246, 100, 50, 30));
      expect(buttons[3].rect, const Rect.fromLTWH(302, 100, 50, 30));
      expect(buttons[0].label, '开始收集');
      expect(buttons[1].label, '诊断目录');
      expect(buttons[2].label, '精简');
      expect(buttons[3].label, '关闭');
      expect(buttons[0].accessibleName, '收集或导出性能诊断');
      expect(buttons[1].accessibleName, '打开诊断目录');
      expect(buttons[2].accessibleName, '展开或精简性能面板');
      expect(buttons[3].accessibleName, '关闭性能面板');
      expect(buttons[0].objectName, 'performanceRecordButton');
      expect(buttons[0].color, '#314f47');
    });

    test('recording / 收起会切换首个按钮的颜色与第三按钮的文案（:70,114）', () {
      final List<PerformancePanelButton> buttons = performancePanelButtons(
        left: 12,
        top: 100,
        expanded: false,
        recording: true,
        recordingAction: '停止收集',
      );
      expect(buttons[0].color, '#9f3830');
      expect(buttons[0].label, '停止收集');
      expect(buttons[2].label, '展开');
    });

    test('卡片尺寸与 details 可视高（:18-19,:48-49）', () {
      expect(PerformancePanelMetrics.cardWidth, 366);
      expect(PerformancePanelMetrics.cardMargin, 12);
      expect(PerformancePanelMetrics.cardRadius, 8);
      expect(PerformancePanelMetrics.cardColor, '#ed151b20');
      expect(PerformancePanelMetrics.cardBorderColor, '#54616b');
      expect(PerformancePanelMetrics.cardHeight(100), 124);
      // height = min(details.height, max(80, panel.height - 210))
      expect(
          PerformancePanelMetrics.detailsHeight(panelHeight: 600, detailsContentHeight: 500),
          390);
      expect(
          PerformancePanelMetrics.detailsHeight(panelHeight: 600, detailsContentHeight: 100),
          100);
      expect(
          PerformancePanelMetrics.detailsHeight(panelHeight: 200, detailsContentHeight: 500),
          80);
      expect(PerformancePanelMetrics.detailsSize, 12);
      expect(PerformancePanelMetrics.detailsLineHeight, 1.35);
      expect(PerformancePanelMetrics.headlineSize, 21);
      expect(PerformancePanelMetrics.headlineColor, '#8fe3bb');
      expect(PerformancePanelMetrics.headlineObjectName, 'performanceHeadline');
      expect(PerformancePanelMetrics.cardObjectName, 'performanceCard');
      expect(PerformancePanelMetrics.buttonHeight, 30);
      expect(PerformancePanelMetrics.buttonRadius, 4);
      expect(PerformancePanelMetrics.buttonSpacing, 6);
      expect(PerformancePanelMetrics.buttonColor, '#303b43');
    });
  });

  group('Apple Music 标记（NativeHudSettings.cpp:15-18,261-267）', () {
    test('两条 path 与渲染顺序固定：icon 用 ink，note 用 panel', () {
      expect(SettingsAppleMusicMark.iconPath.startsWith('M 23.994 6.124'), isTrue);
      expect(SettingsAppleMusicMark.notePath.startsWith('M 17.571 10.114'), isTrue);
      expect(SettingsAppleMusicMark.layerCount, 2);
      expect(SettingsAppleMusicMark.layerName(0), 'icon');
      expect(SettingsAppleMusicMark.layerName(1), 'note');
      expect(SettingsAppleMusicMark.layerPaintRole(0), 'ink');
      expect(SettingsAppleMusicMark.layerPaintRole(1), 'panel');
      expect(SettingsAppleMusicMark.layerPath(0), SettingsAppleMusicMark.iconPath);
      expect(SettingsAppleMusicMark.layerPath(1), SettingsAppleMusicMark.notePath);
      // 46/24 的缩放由 mark 矩形宽高除以 24 得出（:264）。
      expect(ProviderCardMetrics.markSize / ProviderCardMetrics.markGlyphExtent, closeTo(46 / 24, 1e-9));
    });
  });

  group('自定义区分发（NativeHudSettings.cpp:227-380）', () {
    test('五类渲染器各自命中一次，未知 renderer 回落到 provider-card', () {
      const Rect body = Rect.fromLTWH(54, 0, 1172, 160);
      for (final String renderer in <String>[
        SettingsCustomRenderers.performance,
        SettingsCustomRenderers.storage,
        SettingsCustomRenderers.update,
        SettingsCustomRenderers.defaults,
      ]) {
        final SettingsRowRecorder recorder = SettingsRowRecorder();
        paintSettingsCustomSection(
          renderer: renderer,
          body: body,
          scroll: 0,
          state: const SettingsCustomSectionState(),
          canvas: recorder,
          palette: darkPalette(),
        );
        expect(recorder.ops, isNotEmpty, reason: renderer);
      }
      final SettingsRowRecorder fallback = SettingsRowRecorder();
      paintSettingsCustomSection(
        renderer: 'unknown-renderer',
        body: body,
        scroll: 0,
        state: const SettingsCustomSectionState(),
        canvas: fallback,
        palette: darkPalette(),
      );
      expect(fallback.textAt('CURRENT PROVIDER / 当前平台'), isNotNull);
    });
  });
}
