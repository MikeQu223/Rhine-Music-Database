/// 发现页的宿主侧投影：把 provider descriptor 的 `discover` 段和本地数据
/// 折成竖屏页需要的 chip / 条目。
///
/// Qt 的真源是 `Qt/src/DiscoverController.cpp`（provider 声明 `discover.enabled`
/// 与 `discover.tabs` 时才装页），竖屏版式见 `Qt/src/ResponsiveHudPages.cpp:376-470`。
/// 本仓库的网关层目前恒为 `UnavailableProviderGateway`（数据面在 Qt 侧），所以：
///   - tab 一律从 descriptor 的 `discover.tabs` 来（siren 没有 ⇒ 空）；
///   - `history` tab 用本地播放历史（`MusicPlayer.history`，Qt 同样落 `play-history`）；
///   - 其它 tab 在没有网关数据时诚实地显示 `status`，不伪造条目。
library;

import '../hud/portrait/portrait_discover_page.dart';
import '../provider/provider_descriptor.dart';
import 'basic_models.dart';

/// 发现页的一帧快照：宿主算好，HUD 只照着画（与其它页同一种「快照进、命令流出」）。
///
/// 单独封一个对象而不是往 `BasicHudFrame.build` 塞十个参数：帧签名已经很长，
/// 再加一条链路（`build` → `_buildPortraitFrame` → `BasicHudSurface`）会让三处
/// 都要同步维护同一组字段，容易漏。
class BasicDiscoverSnapshot {
  const BasicDiscoverSnapshot({
    required this.tabs,
    required this.tab,
    this.tools = const <PortraitDiscoverChip>[],
    this.categories = const <PortraitDiscoverChip>[],
    this.categoryPicker = false,
    this.entries = const <PortraitDiscoverEntry>[],
    this.status = '',
    this.more = false,
    this.loadingMore = false,
    this.scroll = 0,
  });

  final List<PortraitDiscoverChip> tabs;
  final String tab;
  final List<PortraitDiscoverChip> tools;
  final List<PortraitDiscoverChip> categories;
  final bool categoryPicker;
  final List<PortraitDiscoverEntry> entries;
  final String status;
  final bool more;
  final bool loadingMore;
  final double scroll;

  /// 空快照（没有发现页能力时用它，页面会画 `音乐平台尚未装载`）。
  static const BasicDiscoverSnapshot empty = BasicDiscoverSnapshot(
    tabs: <PortraitDiscoverChip>[],
    tab: '',
    status: '音乐平台尚未装载',
  );
}

/// 发现页的 tab 串（Qt `discover:tab:<id>`）。
const String basicDiscoverTabPrefix = 'discover:tab:';

/// 发现页的条目动作（Qt `discover:item:<index>`）。
const String basicDiscoverItemPrefix = 'discover:item:';

/// 播放发现页里的歌单（Qt `mobile:play-discover:<index>`）。
const String basicPlayDiscoverPrefix = 'mobile:play-discover:';

/// 发现页的「加载更多」（Qt `discover:more`）。
const String basicDiscoverMoreAction = 'discover:more';

/// 分类页的分类 chip（Qt `MusicDiscover` 的 `category` 过滤轴）。
const String basicDiscoverCategoryPrefix = 'discover:category:';

/// 新歌页的地区 chip（Qt 的 `newSongArea`）。
const String basicDiscoverAreaPrefix = 'discover:area:';

/// 播放历史 tab 的 id（Qt `m_discover->tab == "history"`）。
const String basicDiscoverHistoryTab = 'history';

/// 从 descriptor 取 tab 列表；没有 `discover` 声明时返回空表（siren 即此）。
List<PortraitDiscoverChip> basicDiscoverTabs(
  ProviderDescriptor? descriptor, {
  required String selectedTab,
}) {
  final List<Map<String, Object?>> raw =
      descriptor?.discoverTabs ?? const <Map<String, Object?>>[];
  return <PortraitDiscoverChip>[
    for (final Map<String, Object?> tab in raw)
      if (_text(tab['id']).isNotEmpty)
        PortraitDiscoverChip(
          label: _text(tab['label'], _text(tab['id'])),
          action: '$basicDiscoverTabPrefix${_text(tab['id'])}',
          selected: _text(tab['id']) == selectedTab,
        ),
  ];
}

/// 首个 tab 的 id（`discoverDefaultTab` 命中 tab 表时用它，否则用表首项）。
String basicDiscoverInitialTab(ProviderDescriptor? descriptor) {
  final List<Map<String, Object?>> tabs =
      descriptor?.discoverTabs ?? const <Map<String, Object?>>[];
  final String preferred = descriptor?.discoverDefaultTab ?? '';
  final List<String> ids = <String>[
    for (final Map<String, Object?> tab in tabs) _text(tab['id']),
  ];
  if (preferred.isNotEmpty && ids.contains(preferred)) return preferred;
  return ids.isEmpty ? '' : ids.first;
}

/// `history` tab 的条目：本地播放历史（最近在前，序号从 0 递增）。
List<PortraitDiscoverEntry> basicDiscoverHistoryEntries(List<SirenSong> songs) {
  return <PortraitDiscoverEntry>[
    for (int index = 0; index < songs.length; index += 1)
      PortraitDiscoverEntry(
        index: index,
        title: songs[index].title,
        artist: songs[index].artist,
        // 行列表不带封面（Qt `ResponsiveHudPages.cpp:462-469` 的 discover 行只给
        // 序号 + 标题 + 艺人；带图会让 row() 把序号列让出去）。
        image: '',
      ),
  ];
}

/// 发现页的空态/状态行。
String basicDiscoverStatus({
  required ProviderDescriptor? descriptor,
  required String tab,
  required int entryCount,
}) {
  if (descriptor == null) return '音乐平台尚未装载';
  if (!descriptor.discoverEnabled) return '${descriptor.name}不提供发现页';
  if (tab == basicDiscoverHistoryTab && entryCount == 0) return '还没有播放记录';
  if (entryCount == 0) return '这个分类暂时没有内容';
  return '';
}

String _text(Object? value, [String fallback = '']) {
  if (value is String) return value.trim().isEmpty ? fallback : value.trim();
  if (value == null) return fallback;
  final String text = '$value'.trim();
  return text.isEmpty ? fallback : text;
}
