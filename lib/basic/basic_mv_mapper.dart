/// 领域层 [`MvState`] → 竖屏/横屏 MV 面板视图模型 [`MvPanelModel`] 的映射。
///
/// 与 `basic_comment_mapper.dart` 同一分工：hud 层（`lib/hud/**`）刻意不 import
/// `lib/domain/**`（见 `lib/hud/player/player_bar.dart:7`），所以映射放在 basic 层，
/// 两侧（竖屏页 `portrait_pages_mv.dart` 与横屏弹层 `modals/mv_modal.dart`）
/// 共用同一份只读模型。
///
/// 真值：`Qt/src/MvController.cpp` 的 `state()`/`versionLabels()` 与
/// `Qt/src/ResponsiveHudPages.cpp` 的 MV 页。
library;

import '../domain/mv/mv_controller.dart';
import '../hud/portrait/portrait_pages_mv.dart';
import '../provider/provider_gateway.dart' show ProviderMvVersion;

/// 把 MV 领域态映射成面板模型。
///
/// [decodable] 看**当前是否已经解析出可播放地址**：本仓库已接入 `video_player`
/// （`lib/basic/basic_mv_player.dart`，真机可播 1080p），所以拿到 `url` 就是可解码；
/// 拿不到（插件没给 MV、或仍在解析）才画「本机未接入视频解码」这条诚实降级。
/// 注意 Qt 桌面端由 `PlatformFeatures.h:23-27` 恒关 MV，口径与本仓库不同。
MvPanelModel basicMvPanelModelOf(MvState state) {
  return MvPanelModel(
    status: state.status,
    title: state.track?.title ?? '',
    trackId: state.trackId,
    resolution: state.resolution,
    versionStatus: state.versionStatus,
    versions: <MvPanelVersionRow>[
      for (final ProviderMvVersion version in state.versions)
        MvPanelVersionRow(
          id: version.id,
          label: version.label,
          associated: version.associated,
        ),
    ],
    selectedVersionId: state.selectedVersionId,
    auto: state.auto,
    // 见上方文档：有播放地址才算可解码（真机已用 video_player 播过 Ave Mujica）。
    decodable: (state.track?.url ?? '').isNotEmpty,
  );
}
