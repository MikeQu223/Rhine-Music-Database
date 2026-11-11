// 设置动作接线路由（T37-S04）—— 隔离源码，不是生产接线。
//
// 本文件只把设置页的十个动作翻译成「端口调用 + 不可变状态转移」。组合根与 T16 host
// 尚未裁决，docs/flutter-migration/contracts/settings-platform.md:334-339（尤其 :338 的
// ARCH_BLOCKED）仍然有效：Flutter 侧设置页与平台能力尚未接线，本文件不得被引用为
// 端到端完成的证据。
//
// 硬约束：
// 1. 纯 Dart：不 import package:flutter、不 import dart:io，也不做 Platform.isAndroid
//    之类的运行时探测。五项平台能力由调用方注入；推荐搬运
//    lib/platform/capability_matrix.dart（A29）CapabilityMatrix 的同名字段。本文件
//    不 import 它：它尚未合入本原子基线，import 会立刻制造断链。
// 2. SettingsActionPorts 是真实副作用（偏好写入、播放器、缓存清理、更新检查、打开
//    浏览器）的唯一出口。本文件不读写存储、不发网络请求、不碰播放器、不打开 URL。
// 3. 诊断入口不得删除：契约 :131-137 与 :322 明令 Performance/诊断在 Android/iOS 也
//    必须保留（Qt/src/NativeHudSettings.cpp:320-329 无条件绘制该行）。diagnostics 在
//    本层恒可见。
// 4. 几何（46/24/66/76/50/28/14/300，settings viewport 176..836）不属本文件（契约
//    §5 :165-182）；quality 行的内容谓词（当前曲目非本地）也不属本文件。
// 5. 动作串只取 Qt 基线里真实存在的串，见 actionKey；基线没有的串不发明。

// ---------------------------------------------------------------------------
// 1. 值域（白名单）—— 全部来自 Qt 的 normalize 分派（SettingsSchema.cpp:718-787）。
// ---------------------------------------------------------------------------

/// 主题值域：StorageType::Theme 只认 light/dark/system，其它值回落 light
/// （Qt/src/SettingsSchema.cpp:732-733；选项表 :25-29）。
const List<String> settingsThemeValues = <String>['light', 'dark', 'system'];

/// 音质值域：Qt 按 provider 动态给选项（SettingsSchema.cpp:181-190、:738-743；
/// MusicPlayer.cpp:104-124），本层取四个分支的并集作为平台门：
/// qq: best/standard/exhigh/lossless/ape；kugou: standard/exhigh/lossless/hires；
/// siren: lossless；其它（含网易云）: standard/higher/exhigh/lossless/hires/jymaster。
/// 逐 provider 收窄属于调用方的内容谓词；越界值一律 Ignored 且不写端口。
const List<String> settingsQualityValues = <String>[
  'best',
  'standard',
  'higher',
  'exhigh',
  'lossless',
  'hires',
  'ape',
  'jymaster',
];

/// Project 分区八个链接的动作后缀（Qt/src/SettingsSchema.cpp:664-687）：Qt 的
/// descriptor id 是 project-<id>，命中串是 music:project-<id>。
const List<String> settingsProjectLinkIds = <String>[
  'home',
  'author',
  'player',
  'kugou',
  'rhine',
  'lyricsx',
  'lyricskit',
  'lyrimuse',
];

// ---------------------------------------------------------------------------
// 2. 动作种类（十项，与任务范围一一对应）
// ---------------------------------------------------------------------------

/// 设置页可路由的十个动作。每一项都有 Qt 证据，没有「预留」项：update:auto、
/// disc-rotation、settings:scroll-up/down、desktop-lyrics:* 与其余偏好行不在本层。
enum SettingsActionKind {
  /// COLOR THEME / 界面配色（settings_modal.dart:2681-2695；Qt 侧见契约 §2 的冻结
  /// 表，源码 SettingsSchema.cpp:352-662，主题选项与规范化在 :25-29、:732-733）。裸串
  /// theme 是行级循环切换（NativeHudController.cpp:724-729），带值串前缀
  /// setting:theme:（settings_modal.dart:2692）。
  theme,

  /// REDUCED MOTION / 动态效果（settings_modal.dart:2696-2709；写入走
  /// NativeHudSettings.cpp:411-414 的 action("motion")）。
  motion,

  /// STARTUP ANIMATION / 初始化动画（settings_modal.dart:2710-2723；写入
  /// NativeHudSettings.cpp:415-418）。
  startupAnimation,

  /// INITIALIZATION / 手动显示初始化页面（settings_modal.dart:2724-2734 的 replay；
  /// 命中 NativeHudController.cpp:690-698）。
  reinitialize,

  /// AUDIO QUALITY / 音质（settings_modal.dart:2735-2749；写入
  /// NativeHudSettings.cpp:481-484 的 quality:set:<v>，落到 MusicPlayer.cpp:127-139）。
  quality,

  /// PERFORMANCE / 性能面板（NativeHudSettings.cpp:320-323 的 performance:toggle；
  /// Engine.cpp:850-853 转 performanceRequested）。诊断入口在移动端也不得移除。
  diagnostics,

  /// STORAGE / 存储与缓存（NativeHudSettings.cpp:332-341 的 cache:clear；
  /// NativeHudController.cpp:479-483）。
  cache,

  /// UPDATE 分区（NativeHudSettings.cpp:344-369）：update:check / update:cancel /
  /// update:release（NativeHudController.cpp:465-477）。
  update,

  /// PROJECT / 项目与开源参考的八个链接（SettingsSchema.cpp:664-687）。
  projectLinks,

  /// CONFIG / 恢复默认（NativeHudSettings.cpp:372-379 的 settings:restore-defaults；
  /// 语义 :492-525）。
  restoreDefaults,
}

// ---------------------------------------------------------------------------
// 3. 平台能力与可见性（契约 §8 :218-236；Qt/src/PlatformFeatures.h:1-25）
// ---------------------------------------------------------------------------

/// 五项平台能力。字段名与 PlatformFeatures.h / CapabilityMatrix 一致，语义是平台
/// 事实而不是「尚未实现」：false 就是该入口在该目标上不存在（契约 :220）。
///
/// 本类不复制 5x5 平台表，也不提供 forTarget 之类的工厂：能力值由调用方注入，
/// 否则就是把 A29 的矩阵重写一遍，并让两份真相随平台增删而漂移。
class SettingsActionAvailability {
  const SettingsActionAvailability({
    required this.officialPlayback,
    required this.localMusic,
    required this.applicationVolume,
    required this.desktopWindowControls,
    required this.desktopLyrics,
  });

  /// PlatformFeatures::OfficialPlayback：Android/iOS false，桌面 true。
  final bool officialPlayback;

  /// PlatformFeatures::LocalMusic：Android/iOS false，桌面 true。本层不消费它；
  /// 保留它是为了让调用方一次性搬运整份矩阵，字段名与 CapabilityMatrix 对齐。
  final bool localMusic;

  /// PlatformFeatures::ApplicationVolume：Android/iOS false，桌面 true。同上。
  final bool applicationVolume;

  /// PlatformFeatures::DesktopWindowControls：Android/iOS false，桌面 true。同上。
  final bool desktopWindowControls;

  /// PlatformFeatures::DesktopLyrics：仅 macOS/Windows true（Linux 也是 false）。
  /// 本层只用它决定 restoreDefaults 是否包含桌面歌词复位（契约 :228-232、:271），
  /// 不在此写任何键。
  final bool desktopLyrics;

  /// 动作入口是否可见。规则与证据逐条如下：
  ///
  /// - quality 只在 officialPlayback 为真时可见。Qt 的 officialVisible 还要叠加
  ///   「当前曲目非本地」（SettingsSchema.cpp:84-86）；本层只做平台门，内容谓词由
  ///   调用方与本方法的结果相与。
  /// - diagnostics 恒可见：契约 :131-137 明令不得因移动端移除诊断入口，:322 把
  ///   Update、Performance（诊断）、Storage 列为全平台必须保留的可见分区。
  /// - theme / motion / startupAnimation / reinitialize / cache / update /
  ///   projectLinks / restoreDefaults 恒可见：前三个偏好行没有 visible 谓词
  ///   （settings_modal.dart:2681-2723），replay 同 settings_modal.dart:2724-2734；
  ///   cache、update、project、restore 属自定义渲染区，
  ///   NativeHudSettings.cpp:332-379 无条件绘制。
  bool isVisible(SettingsActionKind kind) {
    if (kind == SettingsActionKind.quality) {
      return officialPlayback;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is SettingsActionAvailability &&
      other.officialPlayback == officialPlayback &&
      other.localMusic == localMusic &&
      other.applicationVolume == applicationVolume &&
      other.desktopWindowControls == desktopWindowControls &&
      other.desktopLyrics == desktopLyrics;

  @override
  int get hashCode => Object.hash(officialPlayback, localMusic, applicationVolume,
      desktopWindowControls, desktopLyrics);

  @override
  String toString() => 'SettingsActionAvailability(officialPlayback: '
      + officialPlayback.toString() +
      ', localMusic: ' +
      localMusic.toString() +
      ', applicationVolume: ' +
      applicationVolume.toString() +
      ', desktopWindowControls: ' +
      desktopWindowControls.toString() +
      ', desktopLyrics: ' +
      desktopLyrics.toString() +
      ')';
}

// ---------------------------------------------------------------------------
// 4. 不可变状态镜像
// ---------------------------------------------------------------------------

/// 设置动作的状态镜像。默认值取 Qt descriptor 的 defaultValue；它不是真相来源，
/// 调用方接线时必须用 host 读回值覆盖，否则 UI 显示会与本文件无关地错误。
class SettingsActionState {
  const SettingsActionState({
    this.themeMode = 'light',
    this.motionEnabled = true,
    this.startupAnimationEnabled = false,
    this.quality = 'exhigh',
    this.diagnosticsVisible = false,
    this.cacheBusy = false,
    this.updateBusy = false,
    this.updateAvailable = false,
    this.statusMessage = '',
  });

  /// 当前配色，取值域见 settingsThemeValues；默认 light
  /// （settings_modal.dart:2690 的 defaultValue；SettingsSchema.cpp:732-733 的兜底）。
  final String themeMode;

  /// true 表示 full（完整动效），false 表示 reduced（减少动效）
  /// （SettingsSchema.cpp:730-731、settings_modal.dart:2705）。
  final bool motionEnabled;

  /// 初始化动画开关，默认 off（settings_modal.dart:2719）。
  final bool startupAnimationEnabled;

  /// 当前音质，默认 exhigh（settings_modal.dart:2744）。
  final String quality;

  /// 性能面板是否显示。面板默认隐藏，performance:toggle 才是显示入口
  /// （Engine.cpp:850-853）。
  final bool diagnosticsVisible;

  /// 一次 cache:clear 是否在飞行中。Qt 的 clearCaches 同步完成后直接写
  /// cacheMessage「已清除」（NativeHudController.cpp:479-483）；Flutter 侧若异步，
  /// 用它挡住重复点击——这是本层的并发门，不是 Qt 基线语义。
  final bool cacheBusy;

  /// 一次 update:check 是否在飞行中（AppUpdater::check 在 busy() 时空操作，
  /// 契约 :241）。
  final bool updateBusy;

  /// 是否有可用更新（决定 update:release 是否放行；契约 :154；
  /// Qt/src/NativeHudSettings.cpp:361-364 的 !busy && available 门）。
  final bool updateAvailable;

  /// 最近一次状态文案。只有 Qt 真有状态通道的分支才写它（restore
  /// NativeHudSettings.cpp:523、cache :481、update 契约 :241/:255），其余分支保持
  /// 原值，避免发明 UI 文案。
  final String statusMessage;

  SettingsActionState copyWith({
    String? themeMode,
    bool? motionEnabled,
    bool? startupAnimationEnabled,
    String? quality,
    bool? diagnosticsVisible,
    bool? cacheBusy,
    bool? updateBusy,
    bool? updateAvailable,
    String? statusMessage,
  }) =>
      SettingsActionState(
        themeMode: themeMode ?? this.themeMode,
        motionEnabled: motionEnabled ?? this.motionEnabled,
        startupAnimationEnabled: startupAnimationEnabled ?? this.startupAnimationEnabled,
        quality: quality ?? this.quality,
        diagnosticsVisible: diagnosticsVisible ?? this.diagnosticsVisible,
        cacheBusy: cacheBusy ?? this.cacheBusy,
        updateBusy: updateBusy ?? this.updateBusy,
        updateAvailable: updateAvailable ?? this.updateAvailable,
        statusMessage: statusMessage ?? this.statusMessage,
      );

  @override
  bool operator ==(Object other) =>
      other is SettingsActionState &&
      other.themeMode == themeMode &&
      other.motionEnabled == motionEnabled &&
      other.startupAnimationEnabled == startupAnimationEnabled &&
      other.quality == quality &&
      other.diagnosticsVisible == diagnosticsVisible &&
      other.cacheBusy == cacheBusy &&
      other.updateBusy == updateBusy &&
      other.updateAvailable == updateAvailable &&
      other.statusMessage == statusMessage;

  @override
  int get hashCode => Object.hash(themeMode, motionEnabled, startupAnimationEnabled, quality,
      diagnosticsVisible, cacheBusy, updateBusy, updateAvailable, statusMessage);

  @override
  String toString() => 'SettingsActionState(themeMode: ' +
      themeMode +
      ', motionEnabled: ' +
      motionEnabled.toString() +
      ', startupAnimationEnabled: ' +
      startupAnimationEnabled.toString() +
      ', quality: ' +
      quality +
      ', diagnosticsVisible: ' +
      diagnosticsVisible.toString() +
      ', cacheBusy: ' +
      cacheBusy.toString() +
      ', updateBusy: ' +
      updateBusy.toString() +
      ', updateAvailable: ' +
      updateAvailable.toString() +
      ', statusMessage: ' +
      statusMessage +
      ')';
}

// ---------------------------------------------------------------------------
// 5. 端口：真实副作用的唯一出口
// ---------------------------------------------------------------------------

/// 每个方法对应一条 Qt 写入语义；实现方（组合根 / T16 host）负责偏好键、播放器
/// 动作、更新服务与外部链接。本文件只声明，不实现，也不推断实现细节。
abstract interface class SettingsActionPorts {
  /// 写入主题。Qt 侧同时更新缓存、磁盘偏好与场景波形
  /// （NativeHudSettings.cpp:394-404），不能只写偏好。
  void setTheme(String value);

  /// 写入动效。Qt 复用旧动作 action("motion")（NativeHudSettings.cpp:410-414）。
  void setMotion(bool enabled);

  /// 写入初始化动画（NativeHudSettings.cpp:415-418）。
  void setStartupAnimation(bool enabled);

  /// 重新显示初始化页面（NativeHudController.cpp:690-698：先关模态与输入，再
  /// m_scene.mode("boot")）。
  void reinitialize();

  /// 切换音质。Qt 先按 provider 选项校验，非法值直接返回且不写偏好
  /// （MusicPlayer.cpp:127-139）。
  void setQuality(String value);

  /// 显示/隐藏性能面板（Engine.cpp:850-853 的 performanceRequested）。
  void toggleDiagnostics();

  /// 清缓存。Qt 删除缓存目录以及 cacheDirectory()/qml 与 /shaders，不清偏好与
  /// 账号（契约 :145；Host.cpp:1033-1036）。
  void clearCache();

  /// 发起更新检查（AppUpdater::check，契约 :241-253）。
  void checkUpdate();

  /// 取消更新检查（契约 :255）。
  void cancelUpdate();

  /// 打开发布页面。Qt 只调用 QDesktopServices::openUrl（releases 页），没有应用内
  /// 下载或静默安装（契约 :257、:328）。
  void openReleasePage();

  /// 打开 Project 分区某个链接，id 见 settingsProjectLinkIds。
  void openProjectLink(String id);

  /// 恢复默认。Qt 的 restoreSettingsDefaults（NativeHudSettings.cpp:492-525）只重置
  /// 终端偏好：平台、账号、更新检查结果与限流状态都必须保持不变（契约 :261-275）。
  /// [includeDesktopLyrics] 取 PlatformFeatures::DesktopLyrics（:516）：false 时
  /// 整组桌面歌词键一条都不碰。
  void restoreDefaults({required bool includeDesktopLyrics});
}

// ---------------------------------------------------------------------------
// 6. 结果类型：sealed，调用方必须显式处理三类
// ---------------------------------------------------------------------------

/// dispatch 的返回值。
sealed class SettingsActionResult {
  const SettingsActionResult();
}

/// 已派发，携带转移后的新状态（旧状态对象不变）。
final class SettingsActionApplied extends SettingsActionResult {
  const SettingsActionApplied({required this.state, required this.message});

  /// 转移后的状态；调用方应把它交回 SettingsActionRouter.withState。
  final SettingsActionState state;

  /// 路由结果说明，诊断/日志用，不保证是 UI 文案（见 statusMessage 的边界）。
  final String message;

  @override
  String toString() => 'SettingsActionApplied(' + message + ')';
}

/// 被入参/状态门拒绝：端口没有被调用。
final class SettingsActionIgnored extends SettingsActionResult {
  const SettingsActionIgnored(this.reason);

  final String reason;

  @override
  String toString() => 'SettingsActionIgnored(' + reason + ')';
}

/// 被平台门拒绝：该动作在当前能力下不可见，端口没有被调用。
final class SettingsActionUnavailable extends SettingsActionResult {
  const SettingsActionUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'SettingsActionUnavailable(' + reason + ')';
}

// ---------------------------------------------------------------------------
// 7. 路由
// ---------------------------------------------------------------------------

/// 十项动作的唯一派发点。
///
/// 路由只做三件事：平台门（isVisible）、入参门（白名单）、端口调用。所有状态转移
/// 都产生新实例；router 自身不持有可变字段，异步回写用 withState。
class SettingsActionRouter {
  const SettingsActionRouter({
    required this.availability,
    required this.ports,
    this.state = const SettingsActionState(),
  });

  final SettingsActionAvailability availability;
  final SettingsActionPorts ports;
  final SettingsActionState state;

  /// 返回携带 [next] 的新 router；旧实例不变。异步端口（清缓存、更新检查）回写
  /// 状态时用这个方法。
  SettingsActionRouter withState(SettingsActionState next) =>
      SettingsActionRouter(availability: availability, ports: ports, state: next);

  /// 派发一个动作。[value] 是该动作携带的值；各分支的白名单见对应私有方法。
  SettingsActionResult dispatch(SettingsActionKind kind, {String? value}) {
    if (!availability.isVisible(kind)) {
      return SettingsActionUnavailable(
        kind.name + ' 在当前平台能力下不可见（PlatformFeatures 对应项为 false）',
      );
    }
    return switch (kind) {
      SettingsActionKind.theme => _theme(value),
      SettingsActionKind.motion => _motion(value),
      SettingsActionKind.startupAnimation => _startupAnimation(value),
      SettingsActionKind.reinitialize => _reinitialize(value),
      SettingsActionKind.quality => _quality(value),
      SettingsActionKind.diagnostics => _diagnostics(value),
      SettingsActionKind.cache => _cache(value),
      SettingsActionKind.update => _update(value),
      SettingsActionKind.projectLinks => _projectLinks(value),
      SettingsActionKind.restoreDefaults => _restoreDefaults(value),
    };
  }

  SettingsActionResult _theme(String? value) {
    if (value == null) {
      // 裸串 theme 在 Qt 里是「循环到下一个主题」（NativeHudController.cpp:724-729），
      // 属于调用方的选择逻辑；缺值即拒绝，不替调用方猜。
      return const SettingsActionIgnored('theme 需要显式值：light / dark / system');
    }
    if (!settingsThemeValues.contains(value)) {
      return SettingsActionIgnored('theme 值 ' + value + ' 不在白名单 light/dark/system 内');
    }
    ports.setTheme(value);
    return SettingsActionApplied(state: state.copyWith(themeMode: value), message: 'theme=' + value);
  }

  SettingsActionResult _motion(String? value) {
    final bool? enabled = _parseOnOff(value, acceptReducedFull: true);
    if (enabled == null) {
      return SettingsActionIgnored(
        'motion 只接受 on/off（Qt ReducedFull 的 full/reduced 亦接受），收到 ' +
            (value ?? 'null'),
      );
    }
    ports.setMotion(enabled);
    return SettingsActionApplied(
      state: state.copyWith(motionEnabled: enabled),
      message: 'motion=' + (enabled ? 'on' : 'off'),
    );
  }

  SettingsActionResult _startupAnimation(String? value) {
    final bool? enabled = _parseOnOff(value);
    if (enabled == null) {
      return SettingsActionIgnored(
        'startup-animation 只接受 on/off，收到 ' + (value ?? 'null'),
      );
    }
    ports.setStartupAnimation(enabled);
    return SettingsActionApplied(
      state: state.copyWith(startupAnimationEnabled: enabled),
      message: 'startup-animation=' + (enabled ? 'on' : 'off'),
    );
  }

  SettingsActionResult _reinitialize(String? value) {
    if (value != null) {
      return SettingsActionIgnored('replay 不接受值，收到 ' + value);
    }
    ports.reinitialize();
    // 没有字段变化的分支也返回新的 state 实例，免得调用方以为能原地改旧对象。
    return SettingsActionApplied(state: state.copyWith(), message: 'replay');
  }

  SettingsActionResult _quality(String? value) {
    if (value == null || !settingsQualityValues.contains(value)) {
      return SettingsActionIgnored(
        'quality 值 ' +
            (value ?? 'null') +
            ' 不在平台允许的音质值域内（MusicPlayer.cpp:104-124）',
      );
    }
    ports.setQuality(value);
    return SettingsActionApplied(state: state.copyWith(quality: value), message: 'quality=' + value);
  }

  SettingsActionResult _diagnostics(String? value) {
    if (value != null) {
      return SettingsActionIgnored('performance:toggle 不接受值，收到 ' + value);
    }
    ports.toggleDiagnostics();
    final bool next = !state.diagnosticsVisible;
    return SettingsActionApplied(
      state: state.copyWith(diagnosticsVisible: next),
      message: next ? '性能面板显示' : '性能面板隐藏',
    );
  }

  SettingsActionResult _cache(String? value) {
    if (value != null) {
      return SettingsActionIgnored('cache:clear 不接受值，收到 ' + value);
    }
    if (state.cacheBusy) {
      return const SettingsActionIgnored('缓存清理进行中，忽略重复触发');
    }
    ports.clearCache();
    // 端口是 fire-and-forget：完成回写由调用方 withState 把 cacheBusy 置回 false。
    // 这里不写 statusMessage = 已清除——此刻还没清完，写了就是假话
    // （Qt 的同步路径见 NativeHudController.cpp:479-483）。
    return SettingsActionApplied(state: state.copyWith(cacheBusy: true), message: 'cache:clear');
  }

  SettingsActionResult _update(String? value) {
    switch (value) {
      case 'check':
        if (state.updateBusy) {
          return const SettingsActionIgnored(
            '更新检查进行中，忽略重复触发（AppUpdater::check 在 busy 时为空操作）',
          );
        }
        ports.checkUpdate();
        return SettingsActionApplied(
          state: state.copyWith(updateBusy: true, statusMessage: '正在检查更新…'),
          message: 'update:check',
        );
      case 'cancel':
        ports.cancelUpdate();
        return SettingsActionApplied(
          state: state.copyWith(updateBusy: false, statusMessage: '已取消，可重新检查'),
          message: 'update:cancel',
        );
      case 'release':
        if (!state.updateAvailable) {
          // Qt 的「前往更新 ↗」只在 !busy && available() 时出现
          // （NativeHudSettings.cpp:361-364）；同一串也被无条件绘制的「发布说明 ↗」
          // 复用（:365-366）。本层按任务要求把 update:release 收敛为 updateAvailable
          // 才放行；无条件发布说明入口由 UI 直接调 ports.openReleasePage()，或等
          // T16 裁决后再改。
          return const SettingsActionIgnored('当前没有可用更新，update:release 不放行');
        }
        ports.openReleasePage();
        return SettingsActionApplied(state: state.copyWith(), message: 'update:release');
      default:
        return SettingsActionIgnored(
          'update 需要显式值 check/cancel/release，收到 ' + (value ?? 'null'),
        );
    }
  }

  SettingsActionResult _projectLinks(String? value) {
    if (value == null) {
      return const SettingsActionIgnored('projectLinks 需要链接 id（music:project-<id> 的后缀）');
    }
    if (!settingsProjectLinkIds.contains(value)) {
      return SettingsActionIgnored('未知 project 链接 id ' + value);
    }
    ports.openProjectLink(value);
    return SettingsActionApplied(
      state: state.copyWith(),
      message: 'music:project-' + value,
    );
  }

  SettingsActionResult _restoreDefaults(String? value) {
    if (value != null) {
      return SettingsActionIgnored('settings:restore-defaults 不接受值，收到 ' + value);
    }
    // 唯一出口，参数就是平台事实；本层不写任何键，也不清账号/平台/更新状态。
    ports.restoreDefaults(includeDesktopLyrics: availability.desktopLyrics);
    return SettingsActionApplied(
      state: state.copyWith(
        // Qt 的循环跳过不可见行（NativeHudSettings.cpp:495-502），因此 quality 只在
        // 该行可见时回到默认 exhigh；theme/motion/startup-animation 恒可见，直接复位
        // （默认值见 settings_modal.dart:2690、:2705、:2719、:2744）。
        themeMode: 'light',
        motionEnabled: true,
        startupAnimationEnabled: false,
        quality: availability.isVisible(SettingsActionKind.quality) ? 'exhigh' : state.quality,
        // 面板可见性、cacheBusy、updateBusy、updateAvailable 一律不动：恢复默认不改
        // 更新检查结果与限流状态（契约 :274）。
        statusMessage: '已恢复默认设置',
      ),
      message: 'settings:restore-defaults(includeDesktopLyrics: ' +
          (availability.desktopLyrics ? 'true' : 'false') +
          ')',
    );
  }
}

/// on/off（以及 Qt ReducedFull 的 full/reduced）到 bool 的映射；其余一律 null。
bool? _parseOnOff(String? value, {bool acceptReducedFull = false}) {
  switch (value) {
    case 'on':
      return true;
    case 'off':
      return false;
    case 'full':
      return acceptReducedFull ? true : null;
    case 'reduced':
      return acceptReducedFull ? false : null;
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// 8. 动作串映射（Qt 实际串；基线没有的串不发明）
// ---------------------------------------------------------------------------

/// 该动作的规范串。证据逐条：
///
/// - theme：裸串 theme（NativeHudController.cpp:724-729）；带值形式的前缀是
///   setting:theme:（settings_modal.dart:2692）。
/// - motion：裸串 motion（NativeHudSettings.cpp:411-414）；前缀 setting:motion:
///   （settings_modal.dart:2707）。
/// - startupAnimation：裸串 startup-animation（NativeHudSettings.cpp:415-418）；前缀
///   setting:startup-animation:（settings_modal.dart:2721）。
/// - reinitialize：replay（SettingsSchema.cpp:411-415、NativeHudController.cpp:690-698、
///   NativeApplication.cpp:72）。Qt 基线里没有 settings:reinitialize，本文件不发明。
/// - quality：裸串 quality 是循环下一档（NativeHudController.cpp:701-706）；带值串
///   quality:set:<v>（NativeHudController.cpp:709-710、settings_modal.dart:2746、
///   NativeHudSettings.cpp:481-484）。
/// - diagnostics：performance:toggle（NativeHudSettings.cpp:320-321、Engine.cpp:850-853）。
/// - cache：cache:clear（NativeHudSettings.cpp:336-337、NativeHudController.cpp:479-483）。
/// - update：update:check（NativeHudSettings.cpp:358-360、NativeHudController.cpp:467-468）。
/// - projectLinks：没有单一串，八个链接各自是 music:project-<id>
///   （SettingsSchema.cpp:664-687），这里返回公共前缀；具体 id 用 projectLinkAction。
/// - restoreDefaults：settings:restore-defaults（NativeHudSettings.cpp:372-375；契约 :160）。
String actionKey(SettingsActionKind kind) => switch (kind) {
      SettingsActionKind.theme => 'theme',
      SettingsActionKind.motion => 'motion',
      SettingsActionKind.startupAnimation => 'startup-animation',
      SettingsActionKind.reinitialize => 'replay',
      SettingsActionKind.quality => 'quality',
      SettingsActionKind.diagnostics => 'performance:toggle',
      SettingsActionKind.cache => 'cache:clear',
      SettingsActionKind.update => 'update:check',
      SettingsActionKind.projectLinks => 'music:project-',
      SettingsActionKind.restoreDefaults => 'settings:restore-defaults',
    };

/// 单个 Project 链接的命中串（Qt/src/SettingsSchema.cpp:664-687 的
/// music:project-<id>）。
String projectLinkAction(String id) => 'music:project-' + id;

/// actionKey / parseActionKey 的结果：动作种类 + 该串携带的值（没有值时 null）。
class SettingsActionRoute {
  const SettingsActionRoute(this.kind, [this.value]);

  final SettingsActionKind kind;
  final String? value;

  @override
  bool operator ==(Object other) =>
      other is SettingsActionRoute && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => 'SettingsActionRoute(' + kind.name + ', ' + (value ?? 'null') + ')';
}

/// 把 Qt 命中串解析成动作。只做词法映射，不做值域校验（值域在 dispatch 里）；
/// 未登记的串返回 null，不猜测、不模糊匹配、不做大小写折叠。
///
/// 支持的形式（全部有 Qt 证据）：
/// - 裸串：theme、motion、startup-animation、replay、quality、
///   performance:toggle、cache:clear、update:check、update:cancel、update:release、
///   settings:restore-defaults。
/// - 带值：setting:theme:<v>、setting:motion:<v>、setting:startup-animation:<v>
///   （settings_modal.dart:2692、:2707、:2721 的 actionPrefix）、quality:set:<v>
///   （settings_modal.dart:2746；NativeHudController.cpp:709-710）。
/// - Project 链接：music:project-<id>，只认 settingsProjectLinkIds 的八个 id
///   （SettingsSchema.cpp:664-687）。
SettingsActionRoute? parseActionKey(String key) {
  switch (key) {
    case 'theme':
      return const SettingsActionRoute(SettingsActionKind.theme);
    case 'motion':
      return const SettingsActionRoute(SettingsActionKind.motion);
    case 'startup-animation':
      return const SettingsActionRoute(SettingsActionKind.startupAnimation);
    case 'replay':
      return const SettingsActionRoute(SettingsActionKind.reinitialize);
    case 'quality':
      return const SettingsActionRoute(SettingsActionKind.quality);
    case 'performance:toggle':
      return const SettingsActionRoute(SettingsActionKind.diagnostics);
    case 'cache:clear':
      return const SettingsActionRoute(SettingsActionKind.cache);
    case 'update:check':
      return const SettingsActionRoute(SettingsActionKind.update, 'check');
    case 'update:cancel':
      return const SettingsActionRoute(SettingsActionKind.update, 'cancel');
    case 'update:release':
      return const SettingsActionRoute(SettingsActionKind.update, 'release');
    case 'settings:restore-defaults':
      return const SettingsActionRoute(SettingsActionKind.restoreDefaults);
  }

  const List<String> valuePrefixes = <String>[
    'setting:theme:',
    'setting:motion:',
    'setting:startup-animation:',
    'quality:set:',
  ];
  for (final String prefix in valuePrefixes) {
    if (key.startsWith(prefix)) {
      final String value = key.substring(prefix.length);
      if (value.isEmpty) {
        return null;
      }
      final SettingsActionKind kind = switch (prefix) {
        'setting:theme:' => SettingsActionKind.theme,
        'setting:motion:' => SettingsActionKind.motion,
        'setting:startup-animation:' => SettingsActionKind.startupAnimation,
        _ => SettingsActionKind.quality,
      };
      return SettingsActionRoute(kind, value);
    }
  }

  const String projectPrefix = 'music:project-';
  if (key.startsWith(projectPrefix)) {
    final String id = key.substring(projectPrefix.length);
    if (settingsProjectLinkIds.contains(id)) {
      return SettingsActionRoute(SettingsActionKind.projectLinks, id);
    }
  }
  return null;
}
