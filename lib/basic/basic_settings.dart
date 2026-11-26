// 设置模型（typed，纯 Dart，无 UI / 无持久化 / 无副作用），源为 Qt 的 SettingsSchema
// 与 NativeHudSettings。
//
// 只做四件事：ONLY14 allow-list、面板模型复用 descriptor 表、动作串转 typed 命令、
// 真值（版本 / 项目链接 / 音质选项）逐字取 Qt。
// 不做：持久化、真实生效、native 调用、模态壳、键盘与命中归属。
library;

import '../hud/modals/settings_modal.dart';
import '../hud/widgets/settings_row.dart';

/// ONLY14 的 14 个合同项，顺序 = Qt descriptor order 顺序
/// （配色 / 初始化动画 / 手动显示 / 音质 / 详情页自动播放 / 点击播放单曲 / 右侧遮罩 /
///  图形后端 / 垂直同步 / 渲染分辨率 / 抗锯齿与超分 / 唱片旋转 / 当前版本 / 项目与开源参考）。
enum BasicSettingId {
  appearance,
  startupAnimation,
  replayInitialization,
  audioQuality,
  detailAutoplay,
  singlePlayMode,
  archiveMask,
  graphicsBackend,
  vsync,
  renderScale,
  antiAliasing,
  discRotation,
  version,
  projectLinks,
}

/// 每一项展开成哪些 Qt descriptor id。
///
/// discRotation / version 是 Qt 自定义区里的“行”，没有 descriptor（
/// NativeHudSettings.cpp:324 与 :344-347），因此为空列表：它们由面板单独绘制，
/// 命令串分别是 `disc-rotation` / `disc-rotation:enable` 与（无，纯展示）。
/// 抗锯齿与超分辨率是同一个合同项：aa-mode / aa-scale / msaa / fsr-quality /
/// fsr-sharpness 五个细项全部归入 antiAliasing。
const Map<BasicSettingId, List<String>> basicSettingDescriptorIds = <BasicSettingId, List<String>>{
  BasicSettingId.appearance: <String>['theme'],
  BasicSettingId.startupAnimation: <String>['startup-animation'],
  BasicSettingId.replayInitialization: <String>['replay'],
  BasicSettingId.audioQuality: <String>['quality'],
  BasicSettingId.detailAutoplay: <String>['detail-autoplay'],
  BasicSettingId.singlePlayMode: <String>['single-play-mode'],
  BasicSettingId.archiveMask: <String>['archive-mask'],
  BasicSettingId.graphicsBackend: <String>['graphics-backend'],
  BasicSettingId.vsync: <String>['vsync'],
  BasicSettingId.renderScale: <String>['render-scale'],
  BasicSettingId.antiAliasing: <String>[
    'aa-mode',
    'aa-scale',
    'msaa',
    'fsr-quality',
    'fsr-sharpness',
  ],
  BasicSettingId.discRotation: <String>[],
  BasicSettingId.version: <String>[],
  BasicSettingId.projectLinks: <String>[
    'project-home',
    'project-author',
    'project-player',
    'project-kugou',
    'project-rhine',
    'project-lyricsx',
    'project-lyricskit',
    'project-lyrimuse',
  ],
};

/// Qt descriptor 表里真实存在、但本面板【明确拒绝】的设置项：
/// 用户本次只授权 ONLY14，provider 登录 / 缓存 / 更新 / 恢复默认 / 诊断等一概不加。
/// 这些 id 只用于把“已知但被拒绝”的动作分类出来（而不是伪装成未知动作）。
const List<String> basicSettingsRejectedDescriptorIds = <String>[
  'window', // 桌面窗口
  'close-behavior', // 关闭行为
  'motion', // 减弱动效
  'alternative', // 替代音源
  'official-player', // 官方播放器
  'desktop-lyrics', // 桌面歌词
  'gpu-index', // GPU 选择
  'fg', // 帧生成
];

/// hudState 绑定行在偏好里的真实键（descriptor 不带键，见 [basicSettingsCommandFor]）。
const Map<String, String> basicSettingsHudStatePreferenceKeys = <String, String>{
  'startup-animation': 'startup-animation',
  'archive-mask': 'archive-mask-strength',
  'vsync': 'vsync',
  // 音质：descriptor 的 bindingKind 是 player，既没有 preferenceKey 也只派发
  // `quality:set:<value>`，但播放器自己把值写进同一份偏好
  // （Qt/src/MusicPlayer.cpp:139 `m_host->setPreference("quality", value)`，读回
  // 同键 :181；"quality" 在宿主白名单里 Host.cpp:1063）。没有这条映射时，
  // 可以切换的 provider（qq/kugou/…）会得到「这一项没有可持久化的偏好键」，音质
  // 只选不存。
  //
  // 注意出厂 provider siren 只有一档 'lossless'（settings_modal.dart:2495-2499），
  // 而 descriptor 默认值是 'exhigh'：归一化后 target 恒等于当前档，命令在
  // settings_row.dart:1088 的 unchanged 检查就返回了，压根走不到这里。那是
  // 「只有一档就没什么可切换」，属实的 unchanged 而非这篇映射的漏洞。
  'quality': 'quality',
};

/// ONLY14 允许暴露的 descriptor id 集合（由 [basicSettingDescriptorIds] 展开）。
final Set<String> basicSettingsAllowedDescriptorIds = Set<String>.unmodifiable(<String>{
  for (final List<String> ids in basicSettingDescriptorIds.values) ...ids,
});

/// Qt 里真实存在、但没有 descriptor 承载的“被拒绝”动作串前缀：
/// 缓存（NativeHudSettings.cpp:332-342 cache:clear）、更新（:351-370 update:auto/
/// check/cancel/release）、诊断面板（:320 performance:toggle）、账号（basic_app
/// 当前对 music:login/qr/logout 明确回“尚未接入”）。它们必须被分类为
/// “已知但未授权”，而不是伪装成未知动作。
const List<String> basicSettingsRejectedActionPrefixes = <String>[
  'cache:',
  'update:',
  'performance:',
  'music:activate',
  'music:login',
  'music:logout',
  'music:qr',
];

/// descriptor id 是否在 ONLY14 之内。
bool basicSettingAllowsDescriptor(String descriptorId) =>
    basicSettingsAllowedDescriptorIds.contains(descriptorId);

/// descriptor id 属于哪个合同项；不在 ONLY14 内返回 null。
BasicSettingId? basicSettingForDescriptor(String descriptorId) {
  for (final MapEntry<BasicSettingId, List<String>> entry in basicSettingDescriptorIds.entries) {
    if (entry.value.contains(descriptorId)) {
      return entry.key;
    }
  }
  return null;
}

// 当前版本（ONLY14 第 13 项）

/// 版本真值。**必须由宿主用真实 source 构造**（pubspec / 构建期注入 / 平台包信息）；
/// 面板不提供默认值、不猜测版本号、不读网络。
class BasicSettingsVersion {
  const BasicSettingsVersion({
    required this.version,
    this.releaseBuild = false,
    this.commitTitle = '',
  }) : assert(version != '', 'BasicSettingsVersion.version 必须来自真实 source，不允许留空');

  /// 例如 pubspec.yaml 的 version 名（不含 build 号）或构建注入串。
  final String version;

  /// 发布构建：真则第二行（commit 标题）不画（NativeHudSettings.cpp:347-349）。
  final bool releaseBuild;

  /// 非发布构建的 commit 标题（可空）。
  final String commitTitle;

  /// NativeHudSettings.cpp:346-347 逐字：versionPrefix + version + buildLabel。
  String get label =>
      SettingsUpdateContent.versionPrefix +
      version +
      (releaseBuild ? '' : SettingsUpdateContent.devBuildSuffix);

  /// :349 非发布构建的第二行；发布构建为空串（面板跳过绘制）。
  String get secondaryLabel => releaseBuild ? '' : commitTitle;
}

// 音质真值（ONLY14 第 4 项）

/// 已持久化值不在 provider 真实支持列表里时追加的后缀。
/// 例：Siren 只支持 lossless，而快照里残留旧值 exhigh —— 面板必须说真话，
/// 显示 "exhigh · 不受支持"，而不是把 lossless 的标签贴到 exhigh 上。
const String basicSettingsUnsupportedValueSuffix = ' · 不受支持';

/// 一次音质读取的真值。
class BasicSettingsQualityTruth {
  const BasicSettingsQualityTruth({
    required this.available,
    required this.stored,
    required this.value,
    required this.supported,
    required this.label,
  });

  /// provider 真实支持的选项（Siren 只有一条 lossless「官网原始音源」）。
  final List<SettingsChoice> available;

  /// 快照里的原始持久化值（可能为空 = 从未写过）。
  final String stored;

  /// 归一化后的可用值（settingsNormalizeValue 的结果，必在 [available] 内）。
  final String value;

  /// [stored] 是否在 [available] 内（为空视为支持：还没有写过任何值）。
  final bool supported;

  /// 控件显示文本；!supported 时带 [basicSettingsUnsupportedValueSuffix]。
  final String label;

  /// provider 只有一个选项（Siren）：音质不可切换，也不该呈现成可切换。
  bool get singleChoice => available.length == 1;

  /// 是否根本没有可选音质（本地音乐 provider）。
  bool get empty => available.isEmpty;
}

/// 从真实 descriptor + provider 能力读出音质真值（不伪造质量、不伪造支持）。
BasicSettingsQualityTruth basicSettingsQualityTruth({
  required SettingsPreferenceContext context,
  required SettingsPreferenceSnapshot snapshot,
}) {
  final SettingsDescriptor? descriptor = settingsDescriptorById('quality');
  if (descriptor == null) {
    return const BasicSettingsQualityTruth(
      available: <SettingsChoice>[],
      stored: '',
      value: '',
      supported: true,
      label: '',
    );
  }
  final SettingsPreferenceValue value =
      settingsReadPreference(descriptor, context: context, snapshot: snapshot);
  final List<SettingsChoice> available = settingsChoicesFor(descriptor, context);
  final bool supported =
      value.raw.isEmpty || available.any((SettingsChoice choice) => choice.value == value.raw);
  final String label = supported
      ? settingsDisplayLabel(descriptor, context, value)
      : value.raw + basicSettingsUnsupportedValueSuffix;
  return BasicSettingsQualityTruth(
    available: available,
    stored: value.raw,
    value: value.canonical,
    supported: supported,
    label: label,
  );
}

// 项目与开源参考（ONLY14 第 14 项）

/// Qt/src/NativeHudMusic.cpp:271-280 的真实链接表，键 = descriptor id。
/// 面板不显示 URL，只把它交给宿主的 open-url 端口。
const Map<String, String> basicSettingsProjectUrls = <String, String>{
  'project-home': 'https://github.com/MikeQu223/Rhine-Music-Database',
  'project-author': 'https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced',
  'project-player': 'https://github.com/yakult-green-tea/qq-music-api',
  'project-kugou': 'https://github.com/MakcRe/KuGouMusicApi',
  'project-rhine': 'https://github.com/LBEILC/RhineLabUI',
  'project-lyricsx': 'https://github.com/MxIris-LyricsX-Project/LyricsX',
  'project-lyricskit': 'https://github.com/MxIris-LyricsX-Project/LyricsKit',
  'project-lyrimuse': 'https://github.com/Yudaotor/lyrimuse',
};

/// 项目链接真值；未知 id 返回 null（命令层据此报 missingProjectUrl，不编 URL）。
String? basicSettingsProjectUrl(String descriptorId) => basicSettingsProjectUrls[descriptorId];

// 面板分区（原 Qt 区块 / 表头文案逐字，只保留 ONLY14 需要的四个区块）

/// 唱片旋转只画 performance 区块的第二行，因此用自己的 renderer 名：
/// 绝不能落到 SettingsCustomRenderers.performance（那会连帧生成/诊断一起画出来）。
const String basicSettingsDiscRotationRenderer = 'basic-disc-rotation';

/// 当前版本只画 update 区块的版本行，因此用自己的 renderer 名：
/// 绝不能落到 SettingsCustomRenderers.update（那会连检查更新/前往更新一起画出来）。
const String basicSettingsVersionRenderer = 'basic-version';

/// 序号 0（原 01）PROVIDER ACCESS / 音乐平台：横屏设置第一屏的平台卡
/// （Qt `SettingsCard.cpp:256-295` 的 providerCard）。竖屏设置页有自己那张
/// widget 卡（`BasicPortraitSettingsPage` 的 ACCESS 卡），所以这个分区只在
/// 横屏（`BasicSettingsWindow`）里出现——不然竖屏会画两遍。
const SettingsSectionSpec basicProviderSection = SettingsSectionSpec(
  id: SettingsSectionId.provider,
  number: 1,
  order: 10,
  titleEn: 'PROVIDER ACCESS',
  titleZh: '音乐平台',
  customRenderer: SettingsCustomRenderers.providerCard,
  customHeight: 160,
);

/// 序号 1（原 02）TERMINAL PREFERENCES / 终端偏好：ONLY14 的 15 行全在这里。
const SettingsSectionSpec basicPreferencesSection = SettingsSectionSpec(
  id: SettingsSectionId.preferences,
  number: 2,
  order: 20,
  titleEn: 'TERMINAL PREFERENCES',
  titleZh: '终端偏好',
  customRenderer: '',
  customHeight: 0,
);

/// 序号 2（原 03）PERFORMANCE / 性能与诊断：只保留唱片旋转那一行，体高 100。
const SettingsSectionSpec basicPerformanceSection = SettingsSectionSpec(
  id: SettingsSectionId.performance,
  number: 3,
  order: 30,
  titleEn: 'PERFORMANCE',
  titleZh: '性能与诊断',
  customRenderer: basicSettingsDiscRotationRenderer,
  customHeight: 100,
);

/// 序号 3（原 05）SOFTWARE UPDATE / 软件更新：只保留当前版本两行文本，体高 52。
const SettingsSectionSpec basicUpdateSection = SettingsSectionSpec(
  id: SettingsSectionId.update,
  number: 5,
  order: 50,
  titleEn: 'SOFTWARE UPDATE',
  titleZh: '软件更新',
  customRenderer: basicSettingsVersionRenderer,
  customHeight: 52,
);

/// 序号 4（原 06）PROJECT / 项目与开源参考：8 条链接（两列网格）。
const SettingsSectionSpec basicProjectSection = SettingsSectionSpec(
  id: SettingsSectionId.project,
  number: 6,
  order: 60,
  titleEn: 'PROJECT',
  titleZh: '项目与开源参考',
  customRenderer: '',
  customHeight: 0,
);

/// 面板四个区块（顺序即绘制顺序）。
List<SettingsSectionSpec> basicSettingsSections() => const <SettingsSectionSpec>[
      basicPreferencesSection,
      basicPerformanceSection,
      basicUpdateSection,
      basicProjectSection,
    ];

// 面板模型

/// 交给绘制层的最小面板模型：四个区块 + 两个自定义区真值 + 音质真值。
class BasicSettingsPanelModel {
  const BasicSettingsPanelModel({
    required this.sections,
    required this.version,
    required this.discRotation,
    required this.quality,
    this.expandedId = '',
  });

  final List<SettingsSectionModel> sections;

  /// 当前版本真值（宿主注入）。
  final BasicSettingsVersion version;

  /// 唱片旋转当前值（Qt MusicPlayer::discRotation）。
  final bool discRotation;

  /// 音质真值（含“不受支持”判定）。
  final BasicSettingsQualityTruth quality;

  /// 当前展开的选项区归属行 id（空 = 没有展开）。
  final String expandedId;

  /// 面板实际暴露的行 id（顺序 = 绘制顺序；不含唱片旋转/版本这两个自定义行）。
  List<String> get rowIds => <String>[
        for (final SettingsSectionModel section in sections)
          for (final SettingsRowSpec row in section.rows) row.id,
      ];

  bool get isEmpty => rowIds.isEmpty;
}

/// 构造 ONLY14 面板模型。
///
/// - descriptor、标题、选项、默认值、可见性、enabled、label 全部取自既有
///   settings_modal.dart，不在本文件复制一份（避免两处真值漂移）；
/// - 不可见的行（如 Darwin 上的 vsync、非 ssaa 下的 aa-scale）按 Qt 语义整行省略；
/// - 音质行的 label 用 [BasicSettingsQualityTruth]，不受支持时明说；
/// - 被拒绝的设置项根本没有入口（allow-list 过滤），项目链接只取 8 条真值。
BasicSettingsPanelModel basicSettingsPanelModel({
  required SettingsPreferenceContext context,
  required SettingsPreferenceSnapshot snapshot,
  required BasicSettingsVersion version,
  String expandedId = '',
}) {
  final BasicSettingsQualityTruth quality =
      basicSettingsQualityTruth(context: context, snapshot: snapshot);

  final List<SettingsRowSpec> preferenceRows = <SettingsRowSpec>[];
  for (final SettingsDescriptor descriptor
      in settingsSectionDescriptors(SettingsSectionId.preferences)) {
    if (!basicSettingAllowsDescriptor(descriptor.id)) {
      continue; // ONLY14 之外：没有入口
    }
    if (!settingsVisible(descriptor, context)) {
      continue; // Qt 语义：环境不满足就整行不出现
    }
    SettingsRowSpec row = settingsRowSpecFor(
      descriptor,
      context: context,
      snapshot: snapshot,
      expandedId: expandedId,
    );
    if (descriptor.id == 'quality') {
      row = row.copyWith(
        label: quality.label,
        enabled: quality.available.isNotEmpty,
      );
    }
    preferenceRows.add(row);
  }

  final List<SettingsRowSpec> projectRows = <SettingsRowSpec>[
    for (final SettingsDescriptor descriptor
        in settingsSectionDescriptors(SettingsSectionId.project))
      if (basicSettingAllowsDescriptor(descriptor.id))
        settingsRowSpecFor(
          descriptor,
          context: context,
          snapshot: snapshot,
          expandedId: expandedId,
        ),
  ];

  return BasicSettingsPanelModel(
    sections: <SettingsSectionModel>[
      const SettingsSectionModel(spec: basicProviderSection),
      SettingsSectionModel(spec: basicPreferencesSection, rows: preferenceRows),
      const SettingsSectionModel(spec: basicPerformanceSection),
      const SettingsSectionModel(spec: basicUpdateSection),
      SettingsSectionModel(spec: basicProjectSection, rows: projectRows),
    ],
    version: version,
    discRotation: snapshot.discRotation,
    quality: quality,
    expandedId: expandedId,
  );
}

// 命中动作串 -> typed 命令

/// 写入后是否需要重启才生效（Qt 各行 restartHint 为“重启生效”）。
enum BasicSettingsRestart { none, nextLaunch }

/// 一次设置交互的 typed 命令。面板只发命令；持久化与真实生效归宿主。
sealed class BasicSettingsCommand {
  const BasicSettingsCommand({required this.action});

  /// 触发的原始动作串（Qt 命中动作，逐字保留，便于宿主日志/回放）。
  final String action;
}

/// 展开/收起某行的选项区（UI 状态，不写任何值）。
final class BasicSettingsExpandCommand extends BasicSettingsCommand {
  const BasicSettingsExpandCommand({required super.action, required this.rowId});

  final String rowId;

  @override
  String toString() => 'BasicSettingsExpandCommand($rowId)';
}

/// 写入一个值：宿主负责持久化 + 真实生效 + native 副作用。
final class BasicSettingsWriteCommand extends BasicSettingsCommand {
  const BasicSettingsWriteCommand({
    required super.action,
    required this.setting,
    required this.descriptorId,
    required this.value,
    required this.currentValue,
    required this.preferenceKey,
    required this.declaredPreferenceKey,
    required this.dispatchAction,
    required this.updatesSceneTheme,
    required this.restart,
  });

  /// 归属的合同项（界面配色 / 音质 / 抗锯齿与超分辨率 …）。
  final BasicSettingId setting;

  /// Qt descriptor id（theme / quality / aa-mode …）。
  final String descriptorId;

  /// 已归一化的目标值（settingsNormalizeValue 的结果）。
  final String value;

  /// 归一化前的当前值（用于宿主去重/日志）。
  final String currentValue;

  /// Qt applySettingValue 的直写偏好键（planSettingsApply 给出；可能为空，
  /// 例：同名动作类 vsync / detail-autoplay 走动作派发而非直写）。
  final String preferenceKey;

  /// descriptor 自己声明的 preferenceKey（hudState / player 绑定可能为空）。
  final String declaredPreferenceKey;

  /// Qt 额外派发的动作串（例：`quality:set:lossless`、`archive-mask:40`、`vsync`）。
  final String dispatchAction;

  /// 界面配色写完后还需更新场景主题（Qt NativeHudSettings.cpp:394-404）。
  final bool updatesSceneTheme;

  /// 是否需要重启生效（Qt restartHint 非空即 nextLaunch）。
  final BasicSettingsRestart restart;

  @override
  String toString() => 'BasicSettingsWriteCommand($descriptorId: $currentValue -> $value)';
}

/// 唱片旋转切换。开启前必须先过风险确认（Qt NativeHudController.cpp:711-722
/// 弹 disc-rotation-warning，NativeHudModal.cpp:203-209 两个按钮）。
final class BasicSettingsDiscRotationCommand extends BasicSettingsCommand {
  const BasicSettingsDiscRotationCommand({
    required super.action,
    required this.setOn,
    required this.requiresConfirmation,
  });

  final bool setOn;

  /// true = 宿主必须先弹风险确认；用户确认后走 `disc-rotation:enable`。
  final bool requiresConfirmation;

  @override
  String toString() =>
      'BasicSettingsDiscRotationCommand(setOn: $setOn)';
}

/// 只有动作、没有值的行（ONLY14 里只有 replay “手动显示初始化页面”）。
final class BasicSettingsActionRowCommand extends BasicSettingsCommand {
  const BasicSettingsActionRowCommand({
    required super.action,
    required this.setting,
    required this.descriptorId,
    required this.dispatchAction,
  });

  final BasicSettingId setting;
  final String descriptorId;
  final String dispatchAction;

  @override
  String toString() => 'BasicSettingsActionRowCommand($descriptorId)';
}

/// 打开一个项目/开源参考链接（URL 来自 Qt 真值表，不是硬编码猜测）。
final class BasicSettingsOpenProjectCommand extends BasicSettingsCommand {
  const BasicSettingsOpenProjectCommand({
    required super.action,
    required this.descriptorId,
    required this.url,
  });

  final String descriptorId;
  final String url;

  @override
  String toString() => 'BasicSettingsOpenProjectCommand($descriptorId)';
}

/// 命令被明确拒绝的原因（**不是**静默 no-op：宿主需要能把真话说出来）。
enum BasicSettingsRejection {
  /// 动作串不属于 Qt 设置面板。
  unknownAction,

  /// 属于 Qt 设置面板，但不在用户授权的 ONLY14 之内。
  rejectedSetting,

  /// 属于宿主界面（模态壳关闭等），不由设置模型处理。
  hostOwned,

  /// 当前环境下该行不可见/不可用（Qt visible/enabled 谓词）。
  disabled,

  /// 目标值与当前值相同（Qt :388-392 不写也不派发）。
  unchanged,

  /// 没有可写入目标（Qt :486-489 落空）。
  unbound,

  /// 平台把整段写入编译掉了（Qt :443-448 非 Darwin 的 fg）。
  platformNoop,

  /// 项目链接缺真值。
  missingProjectUrl,
}

/// 拒绝文案（宿主可直接显示；绝不声称“已生效”）。
String basicSettingsRejectionMessage(BasicSettingsRejection rejection) {
  switch (rejection) {
    case BasicSettingsRejection.unknownAction:
      return '该操作不属于设置面板。';
    case BasicSettingsRejection.rejectedSetting:
      return '该设置项不在本次设置面板范围内。';
    case BasicSettingsRejection.hostOwned:
      return '该操作由界面层处理。';
    case BasicSettingsRejection.disabled:
      return '该设置在当前环境下不可用。';
    case BasicSettingsRejection.unchanged:
      return '值未变化。';
    case BasicSettingsRejection.unbound:
      return '该设置没有可写入的目标。';
    case BasicSettingsRejection.platformNoop:
      return '该设置在当前平台不生效。';
    case BasicSettingsRejection.missingProjectUrl:
      return '缺少该项目链接的真值。';
  }
}

/// 无法执行的命令（带明确原因）。宿主据此显示真话，不伪造成功。
final class BasicSettingsUnavailableCommand extends BasicSettingsCommand {
  const BasicSettingsUnavailableCommand({
    required super.action,
    required this.rejection,
    this.descriptorId = '',
  });

  final BasicSettingsRejection rejection;
  final String descriptorId;

  /// 可直接显示的拒绝文案。
  String get message => basicSettingsRejectionMessage(rejection);

  @override
  String toString() =>
      'BasicSettingsUnavailableCommand(${rejection.name}: $action)';
}

/// 全部 descriptor（ONLY14 + 被拒绝项），仅用于动作分类，不用于暴露。
List<SettingsDescriptor> _allSettingsDescriptors() {
  final List<SettingsDescriptor> out = <SettingsDescriptor>[];
  for (final SettingsSectionId section in SettingsSectionId.values) {
    out.addAll(settingsSectionDescriptors(section));
  }
  return out;
}

/// 把一个动作串解析成 (descriptor, 目标值)。
/// 先精确匹配 descriptor.action（裸动作 / replay / 链接），再匹配 actionPrefix。
({SettingsDescriptor descriptor, String? target})? _resolveSettingsAction(String action) {
  final List<SettingsDescriptor> all = _allSettingsDescriptors();
  for (final SettingsDescriptor descriptor in all) {
    if (descriptor.action.isNotEmpty && descriptor.action == action) {
      return (descriptor: descriptor, target: null);
    }
  }
  for (final SettingsDescriptor descriptor in all) {
    final String prefix = descriptor.actionPrefix;
    if (prefix.isNotEmpty && action.startsWith(prefix)) {
      return (descriptor: descriptor, target: action.substring(prefix.length));
    }
  }
  return null;
}

/// 把一次面板命中翻译成 typed 命令。**纯函数**：不写任何状态、不触发副作用。
///
/// 覆盖 ONLY14 面板会发出的全部动作：
///   `expand:<id>`、`<prefix><value>`（如 `setting:theme:dark`、`quality:set:lossless`、
///   `archive-mask:40`）、裸 `<action>`（如 `theme`、`replay`）、`disc-rotation`、
///   `disc-rotation:enable`、`music:project-<id>`。
/// 其余动作：已知但未授权 -> rejectedSetting；宿主/模态壳 -> hostOwned；其它 -> unknownAction。
BasicSettingsCommand basicSettingsCommandFor(
  String action, {
  required SettingsPreferenceContext context,
  required SettingsPreferenceSnapshot snapshot,
}) {
  final String raw = action;
  if (raw.isEmpty) {
    return BasicSettingsUnavailableCommand(
        action: raw, rejection: BasicSettingsRejection.unknownAction);
  }

  // 1. 展开/收起选项区（纯 UI 状态）。
  if (raw.startsWith('expand:')) {
    final String rowId = raw.substring('expand:'.length);
    final SettingsDescriptor? expandDescriptor = settingsDescriptorById(rowId);
    if (expandDescriptor == null) {
      return BasicSettingsUnavailableCommand(
          action: raw, rejection: BasicSettingsRejection.unknownAction, descriptorId: rowId);
    }
    if (!basicSettingAllowsDescriptor(rowId)) {
      return BasicSettingsUnavailableCommand(
          action: raw, rejection: BasicSettingsRejection.rejectedSetting, descriptorId: rowId);
    }
    // 不可见或禁用的行没有可展开的选项区：`settingsRowSpecFor` 只在
    // `expandedId == id && enabled` 时置 `expanded`，两者都要对齐，
    // 否则（如 Darwin 上的 graphics-backend）会发出一个永远展不开的展开命令。
    if (!settingsVisible(expandDescriptor, context) ||
        !settingsEnabled(expandDescriptor, context)) {
      return BasicSettingsUnavailableCommand(
          action: raw, rejection: BasicSettingsRejection.disabled, descriptorId: rowId);
    }
    return BasicSettingsExpandCommand(action: raw, rowId: rowId);
  }

  // 2. 唱片旋转（自定义行，无 descriptor；开启前必须过风险确认）。
  if (raw == 'disc-rotation') {
    final bool setOn = !snapshot.discRotation;
    return BasicSettingsDiscRotationCommand(
        action: raw, setOn: setOn, requiresConfirmation: setOn);
  }
  if (raw == 'disc-rotation:enable') {
    return const BasicSettingsDiscRotationCommand(
        action: 'disc-rotation:enable', setOn: true, requiresConfirmation: false);
  }
  if (raw == 'disc-rotation:cancel') {
    // 风险确认弹窗的“取消”属于模态壳（宿主），不是设置写入。
    return const BasicSettingsUnavailableCommand(
        action: 'disc-rotation:cancel', rejection: BasicSettingsRejection.hostOwned);
  }

  // 3. descriptor 行。
  final ({SettingsDescriptor descriptor, String? target})? resolved = _resolveSettingsAction(raw);
  if (resolved == null) {
    for (final String prefix in basicSettingsRejectedActionPrefixes) {
      if (raw.startsWith(prefix)) {
        return BasicSettingsUnavailableCommand(
            action: raw, rejection: BasicSettingsRejection.rejectedSetting);
      }
    }
    return BasicSettingsUnavailableCommand(
        action: raw, rejection: BasicSettingsRejection.unknownAction);
  }
  final SettingsDescriptor descriptor = resolved.descriptor;
  if (!basicSettingAllowsDescriptor(descriptor.id)) {
    return BasicSettingsUnavailableCommand(
        action: raw,
        rejection: BasicSettingsRejection.rejectedSetting,
        descriptorId: descriptor.id);
  }
  if (!settingsVisible(descriptor, context) || !settingsEnabled(descriptor, context)) {
    return BasicSettingsUnavailableCommand(
        action: raw,
        rejection: BasicSettingsRejection.disabled,
        descriptorId: descriptor.id);
  }
  final BasicSettingId? setting = basicSettingForDescriptor(descriptor.id);
  if (setting == null) {
    // allow-list 与 descriptor 表不一致（防御：真值漂移时明确报错而不是误写）。
    return BasicSettingsUnavailableCommand(
        action: raw,
        rejection: BasicSettingsRejection.rejectedSetting,
        descriptorId: descriptor.id);
  }

  // 3a. 链接行：只发 open-url 命令。
  if (descriptor.kind == SettingsRowKind.link) {
    final String? url = basicSettingsProjectUrl(descriptor.id);
    if (url == null) {
      return BasicSettingsUnavailableCommand(
          action: raw,
          rejection: BasicSettingsRejection.missingProjectUrl,
          descriptorId: descriptor.id);
    }
    return BasicSettingsOpenProjectCommand(
        action: raw, descriptorId: descriptor.id, url: url);
  }

  // 3b. 纯动作行（ONLY14 内只有 replay）。
  if (descriptor.kind == SettingsRowKind.action) {
    return BasicSettingsActionRowCommand(
      action: raw,
      setting: setting,
      descriptorId: descriptor.id,
      dispatchAction: descriptor.action,
    );
  }

  // 3c. 取值行：当前值 -> 目标值 -> 归一化 -> Qt applySettingValue 计划。
  // 空前缀目标（如裸 'quality:set:'）不得靠归一化回落去写一个用户没选的值。
  if (resolved.target != null && resolved.target!.isEmpty) {
    return BasicSettingsUnavailableCommand(
        action: raw,
        rejection: BasicSettingsRejection.unknownAction,
        descriptorId: descriptor.id);
  }
  final SettingsPreferenceValue current =
      settingsReadPreference(descriptor, context: context, snapshot: snapshot);
  final String target =
      resolved.target ?? settingsSwitchTarget(descriptor, context, current);
  final String canonical = settingsNormalizeValue(descriptor, context, target);
  final SettingsRowSpec rowSpec = settingsRowSpecFor(
    descriptor,
    context: context,
    snapshot: snapshot,
  );
  final SettingsApplyPlan plan = planSettingsApply(
    descriptor: rowSpec,
    target: canonical,
    currentCanonical: current.canonical,
    isDarwin: context.isDarwin,
  );
  switch (plan.outcome) {
    case SettingsCommitOutcome.applied:
      break;
    case SettingsCommitOutcome.unchanged:
      return BasicSettingsUnavailableCommand(
          action: raw,
          rejection: BasicSettingsRejection.unchanged,
          descriptorId: descriptor.id);
    case SettingsCommitOutcome.unknownDescriptor:
      return BasicSettingsUnavailableCommand(
          action: raw,
          rejection: BasicSettingsRejection.unknownAction,
          descriptorId: descriptor.id);
    case SettingsCommitOutcome.unbound:
      return BasicSettingsUnavailableCommand(
          action: raw,
          rejection: BasicSettingsRejection.unbound,
          descriptorId: descriptor.id);
    case SettingsCommitOutcome.platformNoop:
      return BasicSettingsUnavailableCommand(
          action: raw,
          rejection: BasicSettingsRejection.platformNoop,
          descriptorId: descriptor.id);
  }
  // hudState 绑定的行由 Qt 控制器自己 setPreference，descriptor 里既没有
  // preferenceKey 也没有 actionPrefix，面板因此算不出键；但宿主确实持久化它们，
  // 键名逐条来自源码（不是这里发明的）：
  //   startup-animation -> NativeHudController.cpp:870-872 setPreference("startup-animation")
  //                        （读回 :37）
  //   archive-mask      -> NativeHudController.cpp:733-734 setPreference("archive-mask-strength")
  //                        （读回 :50-52）
  //   vsync             -> NativeHudController.cpp:46 读 "vsync"，写入同键
  //   quality           -> MusicPlayer.cpp:139 写 "quality"、:181 读回（见上方映射表的注释；
  //                        仅多档 provider 可达，单档 siren 先被 unchanged 拦下）
  // 这几个键都在 Host.cpp:1056-1063 的白名单里。
  final String persistedKey = plan.preferenceKey ??
      (basicSettingsHudStatePreferenceKeys[descriptor.id] ?? '');
  final String restartHint = settingsRestartHint(descriptor, context);
  return BasicSettingsWriteCommand(
    action: raw,
    setting: setting,
    descriptorId: descriptor.id,
    value: canonical,
    currentValue: current.canonical,
    preferenceKey: persistedKey,
    declaredPreferenceKey: descriptor.preferenceKey,
    dispatchAction: plan.action ?? '',
    updatesSceneTheme: plan.updatesSceneTheme,
    restart: restartHint.isEmpty ? BasicSettingsRestart.none : BasicSettingsRestart.nextLaunch,
  );
}
