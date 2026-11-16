// ===========================================================================
// SETTINGS-145 / W1   atomic = W1   file = test/basic/basic_settings_145_test.dart
// scope = ONLY14 设置模型与面板适配器的源码级断言（纯 Dart + flutter_test）
//
// 钉住四件事：
//   1. ONLY14 allow-list 与“被拒绝项”边界（provider 登录 / 缓存 / 更新 /
//      恢复默认 / 诊断 / 桌面窗口 / 桌面歌词 / 替代音源 / GPU / 帧生成 一概没有入口）；
//   2. 面板模型的行集合、顺序、可见性（沿 Qt visible 语义）与区块标题逐字；
//   3. 命中动作串 -> typed 命令的真值（含“不受支持音质”“不可切换”“需重启”“需风险确认”
//      与明确拒绝，绝不出现伪造的成功）；
//   4. 绘制适配器只画 ONLY14：没有检查更新 / 清除缓存 / 恢复默认 / 诊断行 /
//      帧生成行，但保留原 HUD 区块表头与唱片旋转、当前版本两行。
//
// 本文件【未执行】：按 control 的 execution 约定，tests / analyze / build 全部由 141 执行。
// ===========================================================================
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_settings.dart';
import 'package:rhine_music_database/basic/basic_settings_surface.dart';
import 'package:rhine_music_database/hud/modals/settings_modal.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/settings/settings_actions.dart';
import 'package:rhine_music_database/hud/widgets/settings_row.dart';

const BasicSettingsVersion _version = BasicSettingsVersion(
  version: '1.0.0',
  commitTitle: 'deadbee 源码编写阶段的假想提交标题',
);

SettingsPreferenceContext _context({
  String providerId = 'siren',
  SettingsOperatingSystem os = SettingsOperatingSystem.windows,
  String aaMode = 'off',
  bool musicEnabled = true,
  bool providerIsLocal = false,
}) =>
    SettingsPreferenceContext(
      operatingSystem: os,
      providerId: providerId,
      aaMode: aaMode,
      musicEnabled: musicEnabled,
      providerIsLocal: providerIsLocal,
    );

BasicSettingsPanelModel _model({
  SettingsPreferenceContext? context,
  SettingsPreferenceSnapshot snapshot = const SettingsPreferenceSnapshot(),
  BasicSettingsVersion version = _version,
  String expandedId = '',
}) =>
    basicSettingsPanelModel(
      context: context ?? _context(),
      snapshot: snapshot,
      version: version,
      expandedId: expandedId,
    );

class _Sink implements HudSurfaceSink {
  final List<HudWireCommand> ops = <HudWireCommand>[];
  final List<HudHit> hits = <HudHit>[];

  @override
  void op(HudWireCommand command) => ops.add(command);

  @override
  void hit(HudHit hit) => hits.add(hit);
}

class _TextPort implements HudTextPort {
  @override
  double glyphWidth(String value, double size, [String weight = 'regular']) =>
      value.length * size * 0.5;

  @override
  double glyphInset(String value, double size, [String weight = 'regular']) => size * 0.1;

  @override
  String fit(String value, double size, double width, [String weight = 'regular']) => value;

  @override
  void rolling(String key, String value, double x, double y, double size, String weight,
      double tracking, bool numeric) {}
}

void main() {
  group('ONLY14 allow-list', () {
    test('14 个合同项，展开后 23 个允许的 descriptor id', () {
      expect(basicSettingDescriptorIds.length, 14);
      expect(basicSettingsAllowedDescriptorIds.length, 23);
      // 15 个取值/动作行 + 8 条项目链接。
      expect(
        basicSettingDescriptorIds[BasicSettingId.projectLinks]!.length,
        8,
      );
      expect(
        basicSettingDescriptorIds[BasicSettingId.antiAliasing]!.length,
        5,
      );
      // 唱片旋转与当前版本是 Qt 自定义区里的行，没有 descriptor。
      expect(basicSettingDescriptorIds[BasicSettingId.discRotation]!.length, 0);
      expect(basicSettingDescriptorIds[BasicSettingId.version]!.length, 0);
    });

    test('被拒绝的 Qt 设置项一律不在允许集合内', () {
      for (final String id in basicSettingsRejectedDescriptorIds) {
        expect(basicSettingAllowsDescriptor(id), isFalse, reason: id);
        expect(basicSettingForDescriptor(id), isNull, reason: id);
        // 但它们确实存在于 Qt/Qt 移植的 descriptor 表里，否则这条测试会失去意义。
        expect(settingsDescriptorById(id), isNotNull, reason: id);
      }
      expect(basicSettingsRejectedDescriptorIds.length, 8);
    });

    test('项目链接真值的键与 settings_actions 的 id 表逐条对齐', () {
      final List<String> expected =
          settingsProjectLinkIds.map((String id) => 'project-' + id).toList();
      expect(basicSettingsProjectUrls.keys.toList(), expected);
      expect(basicSettingsProjectUrl('project-home'),
          'https://github.com/MikeQu223/Rhine-Music-Database');
      expect(basicSettingsProjectUrl('project-lyrimuse'),
          'https://github.com/Yudaotor/lyrimuse');
      expect(basicSettingsProjectUrl('project-unknown'), isNull);
    });
  });

  group('面板模型', () {
    test('默认（Windows/siren）只暴露 ONLY14 的行，顺序与 Qt order 一致', () {
      final BasicSettingsPanelModel model = _model();
      expect(model.rowIds, <String>[
        'theme',
        'startup-animation',
        'replay',
        'quality',
        'detail-autoplay',
        'single-play-mode',
        'archive-mask',
        'graphics-backend',
        'vsync',
        'render-scale',
        'aa-mode',
        'project-home',
        'project-author',
        'project-player',
        'project-kugou',
        'project-rhine',
        'project-lyricsx',
        'project-lyricskit',
        'project-lyrimuse',
      ]);
      // 被拒绝项没有任何入口。
      for (final String rejected in basicSettingsRejectedDescriptorIds) {
        expect(model.rowIds.contains(rejected), isFalse, reason: rejected);
      }
      // aa-scale / msaa / fsr 仅在对应模式出现（Qt visible 语义）。
      expect(model.rowIds.contains('aa-scale'), isFalse);
      expect(model.rowIds.contains('msaa'), isFalse);
      expect(model.rowIds.contains('fsr-quality'), isFalse);
      expect(model.rowIds.contains('fsr-sharpness'), isFalse);
    });

    test('四个区块沿用原 Qt 表头文案并重新编号 1..4', () {
      final BasicSettingsPanelModel model = _model();
      expect(model.sections.map((SettingsSectionModel s) => s.spec.id).toList(), <SettingsSectionId>[
        SettingsSectionId.preferences,
        SettingsSectionId.performance,
        SettingsSectionId.update,
        SettingsSectionId.project,
      ]);
      expect(model.sections.map((SettingsSectionModel s) => s.spec.number).toList(),
          <int>[1, 2, 3, 4]);
      expect(model.sections[0].spec.titleText, 'TERMINAL PREFERENCES / 终端偏好');
      expect(model.sections[1].spec.titleText, 'PERFORMANCE / 性能与诊断');
      expect(model.sections[2].spec.titleText, 'SOFTWARE UPDATE / 软件更新');
      expect(model.sections[3].spec.titleText, 'PROJECT / 项目与开源参考');
      // 自定义区用自有 renderer 名，绝不能落到 Qt 整块 renderer（会画出未授权项）。
      expect(model.sections[1].spec.customRenderer, basicSettingsDiscRotationRenderer);
      expect(model.sections[2].spec.customRenderer, basicSettingsVersionRenderer);
      expect(model.sections[1].spec.customRenderer,
          isNot(SettingsCustomRenderers.performance));
      expect(model.sections[2].spec.customRenderer, isNot(SettingsCustomRenderers.update));
      // 被拒绝的区块（provider / storage / footer）整体不存在。
      expect(
        model.sections.any((SettingsSectionModel s) =>
            s.spec.id == SettingsSectionId.provider ||
            s.spec.id == SettingsSectionId.storage ||
            s.spec.id == SettingsSectionId.footer),
        isFalse,
      );
    });

    test('抗锯齿与超分辨率的细项随 aa-mode 展开', () {
      expect(_model(context: _context(aaMode: 'ssaa')).rowIds.contains('aa-scale'), isTrue);
      expect(_model(context: _context(aaMode: 'msaa')).rowIds.contains('msaa'), isTrue);
      final List<String> fsrRows = _model(context: _context(aaMode: 'fsr')).rowIds;
      expect(fsrRows.contains('fsr-quality'), isTrue);
      expect(fsrRows.contains('fsr-sharpness'), isTrue);
      expect(_model(context: _context(aaMode: 'msaa')).rowIds.contains('fsr-quality'), isFalse);
    });

    test('Darwin 上 vsync / aa 细项按 Qt 语义整行省略', () {
      final List<String> darwinRows = _model(context: _context(os: SettingsOperatingSystem.macOS)).rowIds;
      expect(darwinRows.contains('vsync'), isFalse);
      expect(
        _model(
          context: _context(os: SettingsOperatingSystem.macOS, aaMode: 'ssaa'),
        ).rowIds.contains('aa-scale'),
        isFalse,
      );
      // aa-mode 本身仍在（enabled 取决于 temporalAntialiasingAvailable）。
      expect(darwinRows.contains('aa-mode'), isTrue);
    });

    test('音质行在本地音乐 provider 下整行省略', () {
      final List<String> localRows =
          _model(context: _context(providerId: 'local', providerIsLocal: true)).rowIds;
      expect(localRows.contains('quality'), isFalse);
      // 其余行不受影响。
      expect(localRows.contains('theme'), isTrue);
      expect(localRows.contains('archive-mask'), isTrue);
    });

    test('展开状态传给行模型（expandedId）', () {
      final BasicSettingsPanelModel model = _model(expandedId: 'aa-mode');
      final SettingsRowSpec row =
          model.sections[0].rows.firstWhere((SettingsRowSpec r) => r.id == 'aa-mode');
      expect(row.expanded, isTrue);
    });
  });

  group('音质真值', () {
    test('Siren 只有 lossless；残留 exhigh 必须显示为不受支持', () {
      final BasicSettingsQualityTruth truth = basicSettingsQualityTruth(
        context: _context(),
        snapshot: const SettingsPreferenceSnapshot(quality: 'exhigh'),
      );
      expect(truth.available.length, 1);
      expect(truth.available.first.value, 'lossless');
      expect(truth.available.first.label, '官网原始音源');
      expect(truth.singleChoice, isTrue);
      expect(truth.stored, 'exhigh');
      expect(truth.supported, isFalse);
      expect(truth.value, 'lossless');
      expect(truth.label, 'exhigh' + basicSettingsUnsupportedValueSuffix);
    });

    test('Siren 存了 lossless 时如实显示', () {
      final BasicSettingsQualityTruth truth = basicSettingsQualityTruth(
        context: _context(),
        snapshot: const SettingsPreferenceSnapshot(quality: 'lossless'),
      );
      expect(truth.supported, isTrue);
      expect(truth.label, '官网原始音源');
    });

    test('本地 provider 没有可选音质', () {
      final BasicSettingsQualityTruth truth = basicSettingsQualityTruth(
        context: _context(providerId: 'local', providerIsLocal: true),
        snapshot: const SettingsPreferenceSnapshot(quality: 'exhigh'),
      );
      expect(truth.available, isEmpty);
      expect(truth.empty, isTrue);
    });

    test('qq provider 的真实音质列表（MusicPlayer.cpp:104-124）', () {
      final BasicSettingsQualityTruth truth = basicSettingsQualityTruth(
        context: _context(providerId: 'qq'),
        snapshot: const SettingsPreferenceSnapshot(quality: 'lossless'),
      );
      expect(truth.available.map((SettingsChoice c) => c.value).toList(),
          <String>['best', 'standard', 'exhigh', 'lossless', 'ape']);
      expect(truth.supported, isTrue);
    });

    test('面板里的音质行 label 与真值一致', () {
      final BasicSettingsPanelModel model = _model(
        snapshot: const SettingsPreferenceSnapshot(quality: 'exhigh'),
      );
      final SettingsRowSpec row =
          model.sections[0].rows.firstWhere((SettingsRowSpec r) => r.id == 'quality');
      expect(row.label, 'exhigh' + basicSettingsUnsupportedValueSuffix);
    });
  });

  group('命令翻译', () {
    BasicSettingsCommand command(String action,
            {SettingsPreferenceContext? context, SettingsPreferenceSnapshot? snapshot}) =>
        basicSettingsCommandFor(
          action,
          context: context ?? _context(),
          snapshot: snapshot ?? const SettingsPreferenceSnapshot(),
        );

    test('展开选项区 / 被拒绝项 / 宿主动作 / 未知动作', () {
      final BasicSettingsCommand expand = command('expand:quality');
      expect(expand, isA<BasicSettingsExpandCommand>());
      expect((expand as BasicSettingsExpandCommand).rowId, 'quality');

      for (final String rejected in <String>['expand:motion', 'expand:alternative']) {
        final BasicSettingsCommand cmd = command(rejected);
        expect(cmd, isA<BasicSettingsUnavailableCommand>(), reason: rejected);
        expect((cmd as BasicSettingsUnavailableCommand).rejection,
            BasicSettingsRejection.rejectedSetting);
      }

      expect((command('expand:not-a-setting') as BasicSettingsUnavailableCommand).rejection,
          BasicSettingsRejection.unknownAction);
      expect((command('') as BasicSettingsUnavailableCommand).rejection,
          BasicSettingsRejection.unknownAction);
      expect((command('totally:bogus') as BasicSettingsUnavailableCommand).rejection,
          BasicSettingsRejection.unknownAction);

      // 已知但未授权（无 descriptor 承载的动作串）。
      for (final String rejected in <String>[
        'update:check',
        'update:auto',
        'update:release',
        'cache:clear',
        'performance:toggle',
        'music:login',
      ]) {
        final BasicSettingsCommand cmd = command(rejected);
        expect(cmd, isA<BasicSettingsUnavailableCommand>(), reason: rejected);
        expect((cmd as BasicSettingsUnavailableCommand).rejection,
            BasicSettingsRejection.rejectedSetting,
            reason: rejected);
      }

      final BasicSettingsCommand cancel = command('disc-rotation:cancel');
      expect((cancel as BasicSettingsUnavailableCommand).rejection,
          BasicSettingsRejection.hostOwned);
    });

    test('界面配色：直写 theme 并更新场景主题，无重启提示', () {
      final BasicSettingsCommand cmd = command('setting:theme:dark');
      expect(cmd, isA<BasicSettingsWriteCommand>());
      final BasicSettingsWriteCommand write = cmd as BasicSettingsWriteCommand;
      expect(write.setting, BasicSettingId.appearance);
      expect(write.descriptorId, 'theme');
      expect(write.value, 'dark');
      expect(write.currentValue, 'light');
      expect(write.preferenceKey, 'theme');
      expect(write.updatesSceneTheme, isTrue);
      expect(write.restart, BasicSettingsRestart.none);
      expect(write.dispatchAction, isEmpty);
    });

    test('同值写入报告 unchanged，不伪造 applied', () {
      final BasicSettingsCommand cmd =
          command('setting:theme:dark', snapshot: const SettingsPreferenceSnapshot(themeMode: 'dark'));
      expect((cmd as BasicSettingsUnavailableCommand).rejection, BasicSettingsRejection.unchanged);
      expect(cmd.message, isNotEmpty);
    });

    test('图形后端：写入 requested 且明确提示重启生效', () {
      final BasicSettingsCommand cmd = command('setting:graphics-backend:vulkan');
      final BasicSettingsWriteCommand write = cmd as BasicSettingsWriteCommand;
      expect(write.preferenceKey, 'graphics-backend');
      expect(write.value, 'vulkan');
      expect(write.restart, BasicSettingsRestart.nextLaunch);
    });

    test('垂直同步：走同名动作派发，Windows 上提示重启', () {
      final BasicSettingsWriteCommand write =
          command('setting:vsync:off') as BasicSettingsWriteCommand;
      expect(write.value, 'off');
      expect(write.dispatchAction, 'vsync');
      expect(write.restart, BasicSettingsRestart.nextLaunch);
    });

    test('Darwin 上 vsync 写入被报告为当前环境不可用', () {
      final BasicSettingsCommand cmd =
          command('setting:vsync:off', context: _context(os: SettingsOperatingSystem.macOS));
      expect((cmd as BasicSettingsUnavailableCommand).rejection, BasicSettingsRejection.disabled);
    });

    test('右侧画面遮罩：数值写入并派发 archive-mask:<value>', () {
      final BasicSettingsWriteCommand write =
          command('archive-mask:40') as BasicSettingsWriteCommand;
      expect(write.value, '40');
      expect(write.dispatchAction, 'archive-mask:40');
      expect(write.setting, BasicSettingId.archiveMask);
    });

    test('渲染分辨率：数值写入', () {
      // Windows 默认 100（RhineRender 平台默认），切到 75 才是真实变化。
      final BasicSettingsWriteCommand write =
          command('render-scale:75') as BasicSettingsWriteCommand;
      expect(write.value, '75');
      expect(write.dispatchAction, 'render-scale:75');
      expect(write.setting, BasicSettingId.renderScale);
    });

    test('渲染分辨率：与当前默认值相同时报告 unchanged', () {
      final BasicSettingsCommand cmd = command('render-scale:100');
      expect((cmd as BasicSettingsUnavailableCommand).rejection,
          BasicSettingsRejection.unchanged);
    });

    test('抗锯齿模式做 Qt 兼容归一化（fsr1 -> fsr）', () {
      final BasicSettingsWriteCommand write =
          command('aa-mode:fsr1') as BasicSettingsWriteCommand;
      expect(write.value, 'fsr');
      expect(write.setting, BasicSettingId.antiAliasing);
      expect(write.dispatchAction, 'aa-mode:fsr');
    });

    test('音质：qq 可切换，派发 quality:set:', () {
      final BasicSettingsWriteCommand write = command(
        'quality:set:lossless',
        context: _context(providerId: 'qq'),
      ) as BasicSettingsWriteCommand;
      expect(write.setting, BasicSettingId.audioQuality);
      expect(write.value, 'lossless');
      expect(write.dispatchAction, 'quality:set:lossless');
    });

    test('音质：Siren 只有一档，任何切换都是 unchanged（不可切换，不伪造成功）', () {
      for (final String action in <String>['quality:set:lossless', 'quality:set:exhigh']) {
        final BasicSettingsCommand cmd = command(action);
        expect(cmd, isA<BasicSettingsUnavailableCommand>(), reason: action);
        expect((cmd as BasicSettingsUnavailableCommand).rejection,
            BasicSettingsRejection.unchanged,
            reason: action);
      }
    });

    test('音质：本地 provider 下音质行不可用', () {
      final BasicSettingsCommand cmd = command(
        'quality:set:lossless',
        context: _context(providerId: 'local', providerIsLocal: true),
      );
      expect((cmd as BasicSettingsUnavailableCommand).rejection, BasicSettingsRejection.disabled);
    });

    test('手动显示初始化动画是动作行命令', () {
      final BasicSettingsActionRowCommand cmd =
          command('replay') as BasicSettingsActionRowCommand;
      expect(cmd.setting, BasicSettingId.replayInitialization);
      expect(cmd.descriptorId, 'replay');
      expect(cmd.dispatchAction, 'replay');
    });

    test('项目与开源参考只发 open-url 命令，URL 来自真值表', () {
      final BasicSettingsOpenProjectCommand cmd =
          command('music:project-author') as BasicSettingsOpenProjectCommand;
      expect(cmd.descriptorId, 'project-author');
      expect(cmd.url, 'https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced');
      expect(cmd.action, 'music:project-author');
      expect(command('music:project-unknown'), isA<BasicSettingsUnavailableCommand>());
    });

    test('唱片旋转：关闭->开启需要风险确认，开启->关闭直接放行', () {
      final BasicSettingsDiscRotationCommand open =
          command('disc-rotation') as BasicSettingsDiscRotationCommand;
      expect(open.setOn, isTrue);
      expect(open.requiresConfirmation, isTrue);

      final BasicSettingsDiscRotationCommand close = command(
        'disc-rotation',
        snapshot: const SettingsPreferenceSnapshot(discRotation: true),
      ) as BasicSettingsDiscRotationCommand;
      expect(close.setOn, isFalse);
      expect(close.requiresConfirmation, isFalse);

      final BasicSettingsDiscRotationCommand confirmed =
          command('disc-rotation:enable') as BasicSettingsDiscRotationCommand;
      expect(confirmed.setOn, isTrue);
      expect(confirmed.requiresConfirmation, isFalse);
    });
  });

  group('绘制适配器', () {
    // 真实面板视口（原 HUD 设置卡片 body）：内容高于视口，需要滚动。
    const Rect viewport = Rect.fromLTWH(40, 176, 1000, 660);

    // 内容断言用的高视口：四区块一次性全部可见（滚动与裁剪另有专门用例）。
    const Rect tallViewport = Rect.fromLTWH(40, 176, 1000, 2000);

    SettingsRowRecorder paintModel(BasicSettingsPanelModel model,
        {double scroll = 0, bool titleLoopHit = false, Rect area = tallViewport}) {
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      BasicSettingsSurface(
        viewport: area,
        model: model,
        scroll: scroll,
        titleLoopHit: titleLoopHit,
      ).paint(recorder);
      return recorder;
    }

    test('只画 ONLY14：有唱片旋转 / 版本 / 链接，没有更新与缓存与诊断', () {
      final SettingsRowRecorder recorder = paintModel(_model());

      // 表头逐字（原 HUD 区块标题）。
      expect(recorder.textAt('TERMINAL PREFERENCES / 终端偏好'), isNotNull);
      expect(recorder.textAt('PERFORMANCE / 性能与诊断'), isNotNull);
      expect(recorder.textAt('SOFTWARE UPDATE / 软件更新'), isNotNull);
      expect(recorder.textAt('PROJECT / 项目与开源参考'), isNotNull);

      // 唱片旋转行（performance 自定义区第二行）。
      expect(recorder.textAt('DISC ROTATION'), isNotNull);
      expect(recorder.textAt('唱片旋转'), isNotNull);
      expect(recorder.hasHit('disc-rotation'), isTrue);
      expect(recorder.hitAt('disc-rotation')!.label, '唱片旋转');

      // 当前版本行（update 自定义区前两行）。
      expect(recorder.textAt(_version.label), isNotNull);
      expect(recorder.textAt('当前版本 / 1.0.0 · 开发版'), isNotNull);

      // 项目链接 8 条。
      expect(recorder.hasHit('music:project-home'), isTrue);
      expect(recorder.hasHit('music:project-lyrimuse'), isTrue);

      // 未授权项没有任何绘制与命中。
      for (final String forbidden in <String>[
        'update:check',
        'update:auto',
        'update:release',
        'cache:clear',
        'performance:toggle',
        'setting:motion:on',
        'setting:alternative:on',
        'setting:official-player:on',
      ]) {
        expect(recorder.hasHit(forbidden), isFalse, reason: forbidden);
      }
      for (final String forbiddenText in <String>[
        '显示 / 隐藏 · F10', // 帧生成/诊断行
        '检查更新',
        '前往更新 ↗',
        '清除缓存',
        '恢复默认',
        '发布说明 ↗',
      ]) {
        expect(recorder.textAt(forbiddenText), isNull, reason: forbiddenText);
      }
      // 没有 provider 卡片 / 存储 / 页脚自定义区。
      expect(recorder.customs, isEmpty);
    });

    test('发布构建不追加“开发版”后缀，也不画 commit 行', () {
      final SettingsRowRecorder recorder = paintModel(_model(
        version: const BasicSettingsVersion(version: '1.0.0', releaseBuild: true),
      ));
      expect(recorder.textAt('当前版本 / 1.0.0'), isNotNull);
      expect(recorder.textAt('当前版本 / 1.0.0 · 开发版'), isNull);
      expect(recorder.textAt(_version.commitTitle), isNull);
    });

    test('展开选项区后产出真实选项命中（theme 三项）', () {
      final SettingsRowRecorder recorder = paintModel(_model(expandedId: 'theme'));
      expect(recorder.hasHit('expand:theme'), isTrue);
      expect(recorder.hasHit('setting:theme:light'), isTrue);
      expect(recorder.hasHit('setting:theme:dark'), isTrue);
      expect(recorder.hasHit('setting:theme:system'), isTrue);
    });

    test('滚动：内容高于视口，clamp 到 [0, maximumScroll]', () {
      final BasicSettingsSurface surface = BasicSettingsSurface(
        viewport: viewport,
        model: _model(),
      );
      expect(surface.maximumScroll, greaterThan(0));
      expect(surface.clampedScroll, 0);
      final BasicSettingsSurface scrolled = BasicSettingsSurface(
        viewport: viewport,
        model: _model(),
        scroll: -12,
      );
      expect(scrolled.clampedScroll, 0);
      final BasicSettingsSurface bottom = BasicSettingsSurface(
        viewport: viewport,
        model: _model(),
        scroll: 1e6,
      );
      expect(bottom.clampedScroll, surface.maximumScroll);
    });

    test('滚动后行位置上移', () {
      final SettingsRowRecorder top = paintModel(_model(), area: viewport);
      final SettingsRowRecorder moved =
          paintModel(_model(), scroll: 20, area: viewport);
      final double? topY = top.textAt('TERMINAL PREFERENCES / 终端偏好')?.top;
      final double? movedY = moved.textAt('TERMINAL PREFERENCES / 终端偏好')?.top;
      expect(topY, isNotNull);
      expect(movedY, isNotNull);
      expect(movedY!, lessThan(topY!));
    });

    test('表头滚过视口上沿后不再绘制（严格相交，= Qt SettingsCard 语义）', () {
      final SettingsRowRecorder gone = paintModel(_model(),
          scroll: SettingsRowMetrics.headerHeight, area: viewport);
      expect(gone.textAt('TERMINAL PREFERENCES / 终端偏好'), isNull);
      // 但同一批内容里的行仍然照常绘制。
      expect(gone.textAt('COLOR THEME'), isNotNull);
    });

    test('命中裁剪只保留视口内命中的交集', () {
      final BasicSettingsSurface surface =
          BasicSettingsSurface(viewport: viewport, model: _model());
      final List<SettingsHitRegion> clipped = surface.clipHits(<SettingsHitRegion>[
        const SettingsHitRegion(Rect.fromLTWH(0, 0, 10, 10), 'outside', '外面'),
        SettingsHitRegion(Rect.fromLTWH(viewport.left, viewport.top, 100, 20), 'inside', '里面'),
      ]);
      expect(clipped.map((SettingsHitRegion h) => h.action).toList(), <String>['inside']);
    });

    test('HUD 协议桥：fill / text / hit / centered 都能落到 op 与 hit 流', () {
      final _Sink sink = _Sink();
      final BasicSettingsHudCanvas canvas =
          BasicSettingsHudCanvas(sink: sink, text: _TextPort(), dark: true);
      BasicSettingsSurface(viewport: tallViewport, model: _model()).paint(canvas);

      expect(sink.ops, isNotEmpty);
      expect(sink.hits.any((HudHit hit) => hit.action == 'disc-rotation'), isTrue);
      expect(sink.hits.any((HudHit hit) => hit.action == 'music:project-home'), isTrue);

      final List<HudWireCommand> fills =
          sink.ops.where((HudWireCommand op) => op.first == 'fill').toList();
      expect(fills, isNotEmpty);
      for (final HudWireCommand op in fills) {
        expect(op.length, 6);
        expect((op[1] as List<Object?>).length, 4);
      }
      final List<HudWireCommand> texts =
          sink.ops.where((HudWireCommand op) => op.first == 'text').toList();
      expect(texts.any((HudWireCommand op) => op[1] == '当前版本 / 1.0.0 · 开发版'), isTrue);
      // 步进器用 centered('−' / '＋')，桥接后仍以 text op 发出（Qt NativeHud.cpp:80-85）。
      expect(texts.any((HudWireCommand op) => op[1] == '−'), isTrue);
      expect(texts.any((HudWireCommand op) => op[1] == '＋'), isTrue);
    });

    test('HUD 协议桥：注入 glyphBounds 时 centered 用真实边界（Qt centeredText 逐字）', () {
      final _Sink sink = _Sink();
      final BasicSettingsHudCanvas canvas = BasicSettingsHudCanvas(
        sink: sink,
        text: _TextPort(),
        glyphBounds: (String value, double size, String weight) =>
            (x: 2.0, y: 3.0, width: 10.0, height: 14.0),
      );
      canvas.centered('−', 100, 50, 19, SettingsFontWeight.regular, true);
      final HudWireCommand op = sink.ops.single;
      expect(op.first, 'text');
      expect(op[2], 100 - 2.0 - 5.0); // x - bounds.x - bounds.width/2
      expect(op[3], 50 - 3.0 - 7.0); // cy - bounds.y - bounds.height/2
    });
  });

  group('版本与真值来源', () {
    test('版本号不允许为空（必须来自真实 source）', () {
      expect(() => BasicSettingsVersion(version: ''), throwsA(isA<AssertionError>()));
      expect(_version.label, '当前版本 / 1.0.0 · 开发版');
      expect(_version.secondaryLabel, _version.commitTitle);
      expect(const BasicSettingsVersion(version: '1.0.0', releaseBuild: true).secondaryLabel,
          isEmpty);
    });
  });

  group('第二轮复审回归', () {
    test('expand: 不可见行返回 disabled（不发出永远展不开的展开命令）', () {
      final BasicSettingsCommand cmd = basicSettingsCommandFor(
        'expand:aa-scale',
        context: _context(),
        snapshot: const SettingsPreferenceSnapshot(),
      );
      expect(cmd, isA<BasicSettingsUnavailableCommand>());
      expect((cmd as BasicSettingsUnavailableCommand).rejection, BasicSettingsRejection.disabled);

      final BasicSettingsCommand visible = basicSettingsCommandFor(
        'expand:aa-mode',
        context: _context(),
        snapshot: const SettingsPreferenceSnapshot(),
      );
      expect(visible, isA<BasicSettingsExpandCommand>());
    });

    test('裸前缀（空 target）返回 unknownAction，不回落成任何写入', () {
      for (final String raw in <String>['quality:set:', 'setting:theme:', 'archive-mask:']) {
        final BasicSettingsCommand cmd = basicSettingsCommandFor(
          raw,
          context: _context(providerId: 'qq'),
          snapshot: const SettingsPreferenceSnapshot(),
        );
        expect(cmd, isA<BasicSettingsUnavailableCommand>(), reason: raw);
        expect(
          (cmd as BasicSettingsUnavailableCommand).rejection,
          BasicSettingsRejection.unknownAction,
          reason: raw,
        );
      }
    });

    test('绘制守卫：宿主塞入未授权行时不画标题也不注册命中', () {
      const Rect area = Rect.fromLTWH(40, 176, 1000, 2000);
      final SettingsPreferenceContext context = _context();
      const SettingsPreferenceSnapshot snapshot = SettingsPreferenceSnapshot();
      final SettingsDescriptor window = settingsDescriptorById('window')!;
      final SettingsRowSpec leaked =
          settingsRowSpecFor(window, context: context, snapshot: snapshot);
      final BasicSettingsPanelModel model = BasicSettingsPanelModel(
        sections: <SettingsSectionModel>[
          SettingsSectionModel(spec: basicPreferencesSection, rows: <SettingsRowSpec>[leaked]),
        ],
        version: _version,
        discRotation: false,
        quality: basicSettingsQualityTruth(context: context, snapshot: snapshot),
      );
      final SettingsRowRecorder recorder = SettingsRowRecorder();
      BasicSettingsSurface(viewport: area, model: model).paint(recorder);
      expect(recorder.hits, isEmpty);
      expect(recorder.customs, isEmpty);
      // 未授权行既不画标题也不注册命中，但区块表头照常绘制（不整块吞掉）。
      expect(recorder.textAt(leaked.titleEn), isNull);
      expect(recorder.textAt(leaked.titleZh), isNull);
      expect(recorder.textAt('TERMINAL PREFERENCES / 终端偏好'), isNotNull);
    });
  });
}
