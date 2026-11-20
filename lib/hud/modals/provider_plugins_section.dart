/// 横屏 `provider` 弹层的**插件平台补充段**：注册表驱动的平台卡、插件平台分组、
/// 当前平台标记，以及 Qt 真值里那张「第三方平台插件」卡。
///
/// 为什么单独一个文件：`lib/hud/modals/provider_modal.dart` 的卡片表是
/// `Qt/src/NativeHudModal.cpp:12-24` 的**硬编码五条**，只覆盖内置平台。一旦
/// 第三方插件平台（用户安装的 descriptor）被启用，卡片就必须来自注册表
/// （`providerCardsState()` 遍历 `registry.ids()`），并且 Qt 的卡片总数是
/// `items.size() + 1`（`Qt/src/NativeHudModal.cpp:343-344`：多一张插件卡）。
/// 把这段放在独立文件，`provider_modal.dart` 只多一个可选入参，
/// 既有五卡路径与既有测试一字不动。
///
/// Qt 真值逐条对应：
/// - `Qt/src/NativeHudModal.cpp:305-320` `providerCardsState()`：遍历
///   `registry.ids()`，`local` 在关掉本地音乐时跳过，每项
///   `{id, name, label, detail, selected: provider==id, authenticated: hasCredential(id)}`。
/// - `Qt/src/NativeHudModal.cpp:341-399` `platformChoices`：`gap = 12`、
///   `cardCount = items.size() + 1`、`cardWidth = (width - gap*(cardCount-1))/cardCount`，
///   expanded 时卡高 190，每张卡 `hit(..., "provider:"+id, name)`、选中卡
///   `/ ACTIVE` 标签 + 左侧 3 px 竖条，末尾第 6 张 `hit(..., "plugins", "第三方平台插件")`。
/// - `Qt/src/NativeHudModal.cpp:400-420` `platformPanel`：`editable` 由
///   `providerPlaylistEditors()` 拼成，空则 `平台能力由插件声明。`，否则
///   `支持歌单编辑：<名字、名字>`；`registry.name("siren")` 那行也是查注册表。
/// - `Qt/src/NativeHudModal.cpp:322-338` `providerPlaylistEditors()`：
///   平台 descriptor 的 `capabilities.playlistManagement` 里任一子键为 true 才算。
/// - 插件平台分组：`registry.userInstalled(id)` 为 true 的那些排在内置之后
///   （Qt 侧同一张表由 `registry.ids()` 按 `display.order` 排序，插件 descriptor 的
///   order 缺省排在后面；这里显式分两段，让"内置 / 插件"在横屏上也读得出来）。
///
/// 纯 Dart：不 import Flutter，不读盘、不触网。
library;

import 'package:rhine_music_database/hud/modals/modal_shell.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';
import 'package:rhine_music_database/provider/provider_descriptor.dart';
import 'package:rhine_music_database/provider/provider_registry.dart';

/// 卡片间距（`Qt/src/NativeHudModal.cpp:342` `constexpr double gap = 12`）。
const double providerCardGap = 12;

/// expanded 卡高（`:266` `const auto height = expanded ? 190 : 66;`）。
const double providerCardHeight = 190;

/// compact 卡高（同上 66）。`platformPanel` 恒传 expanded=true，
/// 只有其他调用点会用到这个档。
const double providerCardCompactHeight = 66;

/// 第 6 张卡的动作与命中 label（`:390` `hit(..., "plugins", "第三方平台插件")`）。
const String providerPluginsCardAction = 'plugins';
const String providerPluginsCardLabel = '第三方平台插件';

/// 第 6 张卡的拉丁行（`:393` `text("THIRD-PARTY / PLUGINS", left + 16, y + 10, 10);`）。
const String providerPluginsCardCaption = 'THIRD-PARTY / PLUGINS';

/// 第 6 张卡的标题（`:394` / `:397` 的 `fit("第三方平台插件", …)` 原文）。
const String providerPluginsCardTitle = '第三方平台插件';

/// 第 6 张卡的说明（`:395` `limited("插件市场 / 安装与启用", …)`）。
const String providerPluginsCardNote = '插件市场 / 安装与启用';

/// 第 6 张卡的正号（`:394` `centeredText("+", left + cardWidth / 2, y + 84, 54, "light", true);`）。
const String providerPluginsCardGlyph = '+';

/// 一张平台卡（`Qt/src/NativeHudModal.cpp:305-320` 的 `providerCardsState()` 行）。
final class ProviderPlatformCard {
  const ProviderPlatformCard({
    required this.id,
    required this.name,
    required this.label,
    required this.detail,
    required this.selected,
    required this.authenticated,
    required this.plugin,
  });

  /// 平台 id，也是命中动作的后缀（`provider:<id>`）。
  final String id;

  /// 中文名（`registry.name(id)`；kugou lite 时是「酷狗概念版」）。
  final String name;

  /// 拉丁标签（`registry.label(id)`）。
  final String label;

  /// 定位语（`registry.detail(id)`）。
  final String detail;

  /// 是否当前平台（`m_music->provider == id`）。
  final bool selected;

  /// 是否本机已保存登录（`m_host->hasCredential(id)`）。
  final bool authenticated;

  /// 是否用户安装的插件平台（`registry.userInstalled(id)`）。
  /// Qt 的卡片表没有这一位；横屏这里用它把"插件平台"视觉上分出来。
  final bool plugin;
}

/// 平台卡表：内置在前、插件在后，同组内保持 `registry.ids()` 的 `display.order` 顺序。
///
/// 对应 `Qt/src/NativeHudModal.cpp:305-320`，并按 [ProviderPlatformCard.plugin]
/// 做了一次稳定分组（分组的理由见文件头）。
List<ProviderPlatformCard> providerPlatformCards({
  required ProviderRegistry registry,
  required String currentProvider,
  Set<String> credentials = const <String>{},
  bool localMusicEnabled = true,
  bool kugouLite = false,
}) {
  final List<ProviderPlatformCard> builtin = <ProviderPlatformCard>[];
  final List<ProviderPlatformCard> plugins = <ProviderPlatformCard>[];
  for (final String id in registry.ids) {
    // :308-310 —— local 在关掉本地音乐时整条跳过。
    if (id == 'local' && !localMusicEnabled) {
      continue;
    }
    final bool plugin = registry.userInstalled(id);
    final ProviderDescriptor? descriptor = registry.descriptor(id);
    final ProviderPlatformCard card = ProviderPlatformCard(
      id: id,
      // kugou lite 的显示名覆盖（Qt/src/MusicLibrary.cpp:106-111）。
      name: id == 'kugou' && kugouLite ? '酷狗概念版' : registry.name(id),
      label: registry.label(id),
      detail: registry.detail(id),
      selected: id == currentProvider,
      authenticated: credentials.contains(id),
      plugin: plugin,
    );
    // descriptor 为 null 时不丢卡（Qt 的 registry.ids() 只含已装载项，这里等价）。
    assert(descriptor == null || descriptor.id == id);
    (plugin ? plugins : builtin).add(card);
  }
  return <ProviderPlatformCard>[...builtin, ...plugins];
}

/// 支持歌单编辑的平台中文名（`Qt/src/NativeHudModal.cpp:322-338`
/// `providerPlaylistEditors()`）。
///
/// 判据：descriptor 的 `capabilities.playlistManagement` 是对象，且里面
/// **任一**子键为 true。Qt 原文：
/// ```cpp
/// const auto management = registry.descriptor(id)["capabilities"].toObject()["playlistManagement"].toObject();
/// for (auto value = management.begin(); value != management.end(); ++value) {
///     if (value.value().toBool()) { editors.append(registry.name(id)); break; }
/// }
/// ```
List<String> providerPlaylistEditors(ProviderRegistry registry) {
  final List<String> editors = <String>[];
  for (final String id in registry.ids) {
    final Object? management =
        registry.descriptor(id)?.capabilities['playlistManagement'];
    if (management is! Map) {
      continue;
    }
    for (final Object? value in management.values) {
      if (_flag(value)) {
        editors.add(registry.name(id));
        break;
      }
    }
  }
  return editors;
}

/// 页尾那句能力说明（`Qt/src/NativeHudModal.cpp:405-412`）：
/// `editable.isEmpty() ? "平台能力由插件声明。" : "支持歌单编辑：" + editable.join("、")`。
String providerPlaylistCapabilityLine(List<String> editors) {
  final List<String> values = editors
      .map((String value) => value.trim())
      .where((String value) => value.isNotEmpty)
      .toList(growable: false);
  if (values.isEmpty) {
    return '平台能力由插件声明。';
  }
  return '支持歌单编辑：${values.join('、')}';
}

/// 卡片几何（`Qt/src/NativeHudModal.cpp:342-344`）：
/// `cardCount = items.size() + 1`、`cardWidth = (width - gap*(cardCount-1))/cardCount`。
///
/// 返回每张平台卡的左边 x，长度与 [platformCount] 一致；第 6 张插件卡的左边是
/// `x + platformCount * (cardWidth + gap)`（`:382`）。
final class ProviderCardsLayout {
  const ProviderCardsLayout({
    required this.cardWidth,
    required this.count,
    required this.lefts,
    required this.pluginsLeft,
  });

  /// 统一卡宽（平台卡与插件卡同宽）。
  final double cardWidth;

  /// `cardCount = platformCount + 1`。
  final int count;

  /// 平台卡左边 x。
  final List<double> lefts;

  /// 第 6 张插件卡左边 x。
  final double pluginsLeft;
}

ProviderCardsLayout providerCardsLayout({
  required double x,
  required double width,
  required int platformCount,
}) {
  final int count = platformCount + 1;
  final double cardWidth = (width - providerCardGap * (count - 1)) / count;
  final List<double> lefts = <double>[
    for (int index = 0; index < platformCount; index += 1)
      x + index * (cardWidth + providerCardGap),
  ];
  return ProviderCardsLayout(
    cardWidth: cardWidth,
    count: count,
    lefts: lefts,
    pluginsLeft: x + platformCount * (cardWidth + providerCardGap),
  );
}

/// 画平台卡组（`Qt/src/NativeHudModal.cpp:345-399`），不含第 6 张插件卡。
///
/// 每张卡：填充 tint（选中 alpha 更高）→ `hit(…, "provider:<id>", name)` →
/// 选中卡左侧 3 px 竖条 → `label + (selected ? " / ACTIVE" : "")`（10 号）→
/// 名称（expanded 22 / compact 17，demibold）→ expanded 时至多 3 行 detail
/// （14 号，21 行距）→ 底部 note（12 号，`fit` 到 `cardWidth - 32`）。
///
/// [cards] 的顺序即绘制顺序；`/ ACTIVE` 只看 [ProviderPlatformCard.selected]，
/// 与 Qt 的 `provider["selected"]` 同源。
void paintProviderPlatformCards(
  ModalShellBody body, {
  required List<ProviderPlatformCard> cards,
  required double x,
  required double y,
  required double width,
  bool expanded = true,
}) {
  if (cards.isEmpty) {
    return;
  }
  final ProviderCardsLayout layout = providerCardsLayout(
    x: x,
    width: width,
    platformCount: cards.length,
  );
  for (int index = 0; index < cards.length; index += 1) {
    final ProviderPlatformCard card = cards[index];
    _paintCard(
      body,
      card: card,
      left: layout.lefts[index],
      y: y,
      cardWidth: layout.cardWidth,
      expanded: expanded,
    );
  }
}

/// 画第 6 张「第三方平台插件」卡（`Qt/src/NativeHudModal.cpp:382-398`）。
///
/// 这张卡在任何平台卡组后面都占一格，所以 [width]/[platformCount] 必须与
/// [paintProviderPlatformCards] 传同一组值，卡宽才与平台卡一致。
void paintProviderPluginsCard(
  ModalShellBody body, {
  required double x,
  required double y,
  required double width,
  required int platformCount,
  bool expanded = true,
}) {
  final ProviderCardsLayout layout = providerCardsLayout(
    x: x,
    width: width,
    platformCount: platformCount,
  );
  final double left = layout.pluginsLeft;
  final double cardWidth = layout.cardWidth;
  final double height = expanded ? providerCardHeight : providerCardCompactHeight;

  // :384-385 —— 第 6 张卡恒为未选中态 tint。
  hudFill(
    body.sink,
    _cardTint(body.dark, selected: false),
    left,
    y,
    cardWidth,
    height,
  );
  // :390 —— 命中动作 "plugins"，label "第三方平台插件"。
  body.hit(left, y, cardWidth, height, providerPluginsCardAction,
      providerPluginsCardLabel);
  // :393 —— "THIRD-PARTY / PLUGINS"。
  hudText(body.sink, providerPluginsCardCaption, left + 16, y + 10, 10,
      dark: body.dark);
  if (expanded) {
    // :394 —— 54 号正号，居中于卡宽中点、y+84。
    _centeredText(
      body,
      value: providerPluginsCardGlyph,
      centerX: left + cardWidth / 2,
      cy: y + 84,
      size: 54,
      weight: 'light',
    );
    // :395 —— fit(标题, 22, cardWidth-32, demibold)。
    _limited(
      body,
      providerPluginsCardTitle,
      left + 16,
      y + 118,
      22,
      cardWidth - 32,
      'demibold',
    );
    // :396 —— 插件市场 / 安装与启用。
    _limited(
      body,
      providerPluginsCardNote,
      left + 16,
      y + 154,
      12,
      cardWidth - 32,
    );
  } else {
    // :397 —— compact 只有一行 17 号标题。
    _limited(
      body,
      providerPluginsCardTitle,
      left + 16,
      y + 29,
      17,
      cardWidth - 32,
      'demibold',
    );
  }
}

/// 卡内 note（`Qt/src/NativeHudModal.cpp:347-356`）：
/// local/siren 恒「无需登录」，其余按 `authenticated` 二选一。
String providerCardNote(ProviderPlatformCard card) {
  if (card.id == 'local') {
    return '独立本地库 / 无需登录';
  }
  if (card.id == 'siren') {
    return '官网曲库 / 无需登录';
  }
  return card.authenticated ? '本机已保存登录' : '未登录 / 可选择后扫码';
}

// -- 私有 ---------------------------------------------------------------

List<Object?> _cardTint(bool dark, {required bool selected}) => dark
    ? <Object?>[0.55, 0.59, 0.46, selected ? 0.3 : 0.12]
    : <Object?>[0.44, 0.49, 0.36, selected ? 0.23 : 0.09]; // :352-353 / :386

void _paintCard(
  ModalShellBody body, {
  required ProviderPlatformCard card,
  required double left,
  required double y,
  required double cardWidth,
  required bool expanded,
}) {
  final double height = expanded ? providerCardHeight : providerCardCompactHeight;
  hudFill(body.sink, _cardTint(body.dark, selected: card.selected), left, y, cardWidth, height); // :351
  body.hit(left, y, cardWidth, height, 'provider:${card.id}', card.name); // :352-353
  if (card.selected) {
    // :354-356 —— 选中卡左侧 3 px 竖条。
    hudFill(
      body.sink,
      body.dark
          ? <Object?>[0.7, 0.75, 0.53, 1]
          : <Object?>[0.44, 0.49, 0.36, 1],
      left,
      y,
      3,
      height,
    );
  }
  // :357 —— 拉丁行带 / ACTIVE 后缀。
  hudText(
    body.sink,
    card.label + (card.selected ? ' / ACTIVE' : ''),
    left + 16,
    y + 10,
    10,
    dark: body.dark,
  );
  // :358 —— 名称，expanded 22 / compact 17。
  hudText(
    body.sink,
    card.name,
    left + 16,
    y + 29,
    expanded ? 22 : 17,
    weight: 'demibold',
    dark: body.dark,
  );
  if (!expanded) {
    return;
  }
  // :359-363 —— 至多 3 行 detail，行距 21，14 号。
  final List<String> lines = _wrap(body, card.detail, cardWidth - 32, 14);
  final int visible = lines.length < 3 ? lines.length : 3;
  for (int row = 0; row < visible; row += 1) {
    hudText(body.sink, lines[row], left + 16, y + 75 + row * 21, 14,
        dark: body.dark);
  }
  // :364-370 —— 底部 note，12 号，fit 到 cardWidth - 32。
  _limited(body, providerCardNote(card), left + 16, y + 150, 12, cardWidth - 32);
}

/// Qt `Glyphs::wrap` 的 grapheme 分支（`Qt/src/Glyphs.cpp:361-379`）：
/// 逐字累加，超出 [limit] 就换行，`\n` 强制换行。
List<String> _wrap(ModalShellBody body, String value, double limit, double size) {
  final List<String> lines = <String>[];
  String line = '';
  for (final int rune in value.runes) {
    final String cluster = String.fromCharCode(rune);
    if (cluster == '\n') {
      lines.add(line);
      line = '';
    } else if (line.isNotEmpty && body.text.glyphWidth(line + cluster, size) > limit) {
      lines.add(line);
      line = cluster;
    } else {
      line += cluster;
    }
  }
  lines.add(line);
  return lines;
}

/// Qt `limited(value, x, y, size, width, weight)`（`Qt/src/NativeHud.cpp:77-79`）。
void _limited(
  ModalShellBody body,
  String value,
  double x,
  double y,
  double size,
  double width, [
  String weight = 'regular',
]) {
  hudText(
    body.sink,
    body.text.fit(value, size, width, weight),
    x,
    y,
    size,
    weight: weight,
    dark: body.dark,
  );
}

/// Qt `centeredText(value, x, cy, size, weight, horizontal)`（`Qt/src/NativeHud.cpp:80-85`）。
///
/// `HudTextPort` 只暴露 x 方向的 `glyphWidth` / `glyphInset`，纵向边界取 [size]
/// 近似（与 `lib/basic/basic_settings_surface.dart:330-340` 的既有口径一致）。
void _centeredText(
  ModalShellBody body, {
  required String value,
  required double centerX,
  required double cy,
  required double size,
  String weight = 'regular',
}) {
  final double advance = body.text.glyphWidth(value, size, weight);
  final double insetX = body.text.glyphInset(value, size, weight);
  hudText(
    body.sink,
    value,
    centerX - insetX - advance / 2,
    cy - size / 2,
    size,
    weight: weight,
    dark: body.dark,
  );
}

/// 与 `ProviderDescriptor.capability` 同口径的宽松布尔（数字/字符串也算）。
bool _flag(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  if (value is String) {
    return value == 'true' || value == '1';
  }
  return false;
}
