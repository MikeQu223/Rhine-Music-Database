// 平台能力矩阵 —— 契约 docs/flutter-migration/contracts/settings-platform.md §8 (:218-230)
// 与 Qt/src/PlatformFeatures.h:1-25 的编译期常量逐项对齐。
//
// 设计约束：
// - 纯 Dart：不 import dart:io，不 import package:flutter/foundation.dart，也不读取
//   Platform.isAndroid 之类的运行时信息。目标平台由调用方显式传入，矩阵在任意宿主
//   （单测、桌面预览、移动壳）中都可复现。
// - 五项能力全部是非空 bool，矩阵实例为 const。false 是平台事实（RHINE_MOBILE 分支，
//   或缺少 Q_OS_MACOS/Q_OS_WIN），不是“尚未实现”的 TBD；不存在 unknown、null 或可变
//   capability，也不得在运行时按设备改写。
// - 入口可见性只是展示层派生规则。隐藏入口不删除能力定义：五项能力字段在所有目标上
//   都保留，[CapabilityMatrix.forTarget] 始终返回完整矩阵。

/// 平台构建目标。
///
/// 只描述构建目标，不探测当前进程；调用方（组合根或测试）显式传入。枚举值的拼写与
/// 设置页既有的 `SettingsOperatingSystem` 一致。
enum RhineTarget { android, iOS, windows, macOS, linux }

/// 受平台能力矩阵控制的 UI 入口。
enum CapabilityEntry {
  /// “本地音乐”provider 候选（Qt/src/NativeHudModal.cpp:20-23；
  /// Qt/src/MusicLibrary.cpp:23）。
  localProvider,

  /// `official-player` 设置行（Qt/src/SettingsSchema.cpp:444-456）。
  officialPlayback,

  /// 应用音量控制（Qt/src/NativeHudPlayer.cpp:31；
  /// Qt/src/NativeHudController.cpp:433-436）。
  applicationVolume,

  /// `window` 设置行（Qt/src/SettingsSchema.cpp:354-361）。
  desktopWindowControls,

  /// `desktop-lyrics` 设置行（Qt/src/SettingsSchema.cpp:483-491）。
  desktopLyrics,
}

/// 某个构建目标上的五项平台能力，来源是 PlatformFeatures.h 的编译期常量。
///
/// 构造器私有，能力集合由 [forTarget] 固定为五个 const 实例；不存在部分初始化或
/// 运行时可变的矩阵。构造器断言把表格本身写死：前四项严格等于 RHINE_MOBILE 的取反，
/// [desktopLyrics] 只在 macOS/Windows 为 true。
class CapabilityMatrix {
  const CapabilityMatrix._({
    required this.target,
    required this.officialPlayback,
    required this.localMusic,
    required this.applicationVolume,
    required this.desktopWindowControls,
    required this.desktopLyrics,
  })  : assert(
          (target == RhineTarget.android || target == RhineTarget.iOS)
              ? !officialPlayback &&
                  !localMusic &&
                  !applicationVolume &&
                  !desktopWindowControls
              : officialPlayback &&
                  localMusic &&
                  applicationVolume &&
                  desktopWindowControls,
          '前四项能力必须与 RHINE_MOBILE 分支一致（PlatformFeatures.h:7-18）。',
        ),
        assert(
          desktopLyrics ==
              (target == RhineTarget.windows ||
                  target == RhineTarget.macOS),
          'DesktopLyrics 仅在 macOS/Windows 为 true（PlatformFeatures.h:20-24）。',
        );

  /// 该矩阵对应的构建目标。
  final RhineTarget target;

  /// `PlatformFeatures::OfficialPlayback`。
  /// Android/iOS false；Windows/macOS/Linux true。
  final bool officialPlayback;

  /// `PlatformFeatures::LocalMusic`。
  /// Android/iOS false；Windows/macOS/Linux true。
  final bool localMusic;

  /// `PlatformFeatures::ApplicationVolume`。
  /// Android/iOS false；Windows/macOS/Linux true。
  final bool applicationVolume;

  /// `PlatformFeatures::DesktopWindowControls`。
  /// Android/iOS false；Windows/macOS/Linux true。
  final bool desktopWindowControls;

  /// `PlatformFeatures::DesktopLyrics`。
  /// 仅 macOS/Windows true；Android/iOS/Linux false。
  final bool desktopLyrics;

  /// RHINE_MOBILE 分支（Qt/src/MobileTarget.h:12）：四项 false，DesktopLyrics 亦 false。
  static const CapabilityMatrix _android = CapabilityMatrix._(
    target: RhineTarget.android,
    officialPlayback: false,
    localMusic: false,
    applicationVolume: false,
    desktopWindowControls: false,
    desktopLyrics: false,
  );

  /// 与 Android 同属 RHINE_MOBILE 分支，五项均为 false。
  static const CapabilityMatrix _ios = CapabilityMatrix._(
    target: RhineTarget.iOS,
    officialPlayback: false,
    localMusic: false,
    applicationVolume: false,
    desktopWindowControls: false,
    desktopLyrics: false,
  );

  /// 桌面分支：四项 true，DesktopLyrics 亦 true。
  static const CapabilityMatrix _windows = CapabilityMatrix._(
    target: RhineTarget.windows,
    officialPlayback: true,
    localMusic: true,
    applicationVolume: true,
    desktopWindowControls: true,
    desktopLyrics: true,
  );

  /// 桌面分支：四项 true，DesktopLyrics 亦 true。
  static const CapabilityMatrix _macOS = CapabilityMatrix._(
    target: RhineTarget.macOS,
    officialPlayback: true,
    localMusic: true,
    applicationVolume: true,
    desktopWindowControls: true,
    desktopLyrics: true,
  );

  /// 桌面分支四项 true；DesktopLyrics 在 Linux 恒 false
  /// （PlatformFeatures.h:20-24 只认 Q_OS_MACOS/Q_OS_WIN）。
  static const CapabilityMatrix _linux = CapabilityMatrix._(
    target: RhineTarget.linux,
    officialPlayback: true,
    localMusic: true,
    applicationVolume: true,
    desktopWindowControls: true,
    desktopLyrics: false,
  );

  /// 当前 Flutter 移动壳的 const 默认矩阵（Android）。
  ///
  /// 当前应用只交付 Android；调用方若没有更具体的目标来源，应显式使用该常量，而不是
  /// 由库内部猜测平台。iOS 通过 [forTarget] 选择，值相同但语义上仍是独立目标。
  static const CapabilityMatrix defaultAndroid = _android;

  /// 按显式目标返回对应的 const 矩阵。
  ///
  /// 没有运行时探测，也没有“未知平台”分支：目标类型是封闭枚举，未知值在类型层就
  /// 不可能传入。返回值是上表的 const 实例，可安全地作为不可变配置缓存。
  static CapabilityMatrix forTarget(RhineTarget target) => switch (target) {
        RhineTarget.android => _android,
        RhineTarget.iOS => _ios,
        RhineTarget.windows => _windows,
        RhineTarget.macOS => _macOS,
        RhineTarget.linux => _linux,
      };

  /// 该目标是否展示 [entry]。
  ///
  /// 规则与 Qt 的 visible 谓词逐项一致：
  /// - [CapabilityEntry.localProvider] ← [localMusic]
  ///   （Qt/src/NativeHudModal.cpp:20-23）
  /// - [CapabilityEntry.officialPlayback] ← [officialPlayback]
  ///   （Qt/src/SettingsSchema.cpp:84-86；调用方还需与“当前曲目非本地”相与）
  /// - [CapabilityEntry.applicationVolume] ← [applicationVolume]
  ///   （Qt/src/NativeHudController.cpp:433-436）
  /// - [CapabilityEntry.desktopWindowControls] ← [desktopWindowControls]
  ///   （Qt/src/SettingsSchema.cpp:60-62、:354-361）
  /// - [CapabilityEntry.desktopLyrics] ← [desktopLyrics]
  ///   （Qt/src/SettingsSchema.cpp:64-66、:483-491）
  ///
  /// 因此 Android/iOS 上五项入口全部隐藏；Linux 仅 desktopLyrics 隐藏；Windows/macOS
  /// 全部可见。desktopLyrics 入口只在 macOS/Windows 可见。返回 false 只表示隐藏入口，
  /// 不表示删除能力：对应 bool 字段仍然存在，非 UI 调用方仍可读取。
  bool isEntryVisible(CapabilityEntry entry) => switch (entry) {
        CapabilityEntry.localProvider => localMusic,
        CapabilityEntry.officialPlayback => officialPlayback,
        CapabilityEntry.applicationVolume => applicationVolume,
        CapabilityEntry.desktopWindowControls => desktopWindowControls,
        CapabilityEntry.desktopLyrics => desktopLyrics,
      };
}
