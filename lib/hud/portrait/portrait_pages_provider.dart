/// 竖屏（compact）HUD 的「音乐平台」整页：命令流排版，不建 widget。
///
/// 真源：
/// - `Qt/src/ResponsiveHudPages.cpp:612-701` `ResponsiveHudLayout::providerPage`：
///   `y = 158 - m_scroll`，三段 `terminalSection`（01 音乐平台 / 02 第三方平台插件 /
///   03 账号与歌单）、64 高的平台行、`indexRow` 的插件市场入口、账号分支与页尾两段
///   `paragraph`，最后 `return y + m_scroll + 20`。
/// - `Qt/src/ResponsiveHudPages.cpp:25-34` `terminalSection`：23×18 墨块 + 居中编号 +
///   中文标题 + 右缘英文说明。
/// - `Qt/src/ResponsiveHudPages.cpp:527-544` 设置页那张 `ACCESS / 音乐平台` 卡
///   （几何原样搬成可复用的 [paintPortraitProviderAccessCard]，供 Lead 在
///   `lib/basic/basic_settings_portrait.dart` 里调用）。
/// - `Qt/src/NativeHud.cpp:478-486,543-545`：页面数据来自
///   `m_music->providerName()` / `loggedIn` / `userName` / `provider`、
///   `providerCardsState()`（id/name/label/detail/selected/authenticated）与
///   `providerPlaylistEditors()`。
///
/// 与 `portrait_pages_library.dart` 一样，这里只把「一次排版」发射成命令流 + 命中表：
/// 滚动位置、切换动作、登录/退登全部归宿主（BasicHudSurface / basic_app）。
///
/// 页宽一律读 `c.gridWidth`（设计稿 393 的 353 = 左右各 20），**不写死 393**。
///
/// 纯 Dart：不 import Flutter。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../../provider/provider_descriptor.dart';
import '../../provider/provider_gateway.dart';
import '../scale/portrait_rhythm.dart';
import 'portrait_canvas.dart';

/// 页面内容起点（`Qt/src/ResponsiveHudPages.cpp:613` 的 `158 - m_scroll`）。
const double portraitProviderContentTop = 158;

/// 平台行行高（`Qt/src/ResponsiveHudPages.cpp` 的 `constexpr rowHeight = 64`）。
const double portraitProviderRowHeight = 64;

/// 设置页 ACCESS 卡整卡高度（Qt `y += 116`，即卡 96 高 + 20 间距）。
const double portraitProviderAccessCardStride = 116;

/// 正文左右留白（Qt 全站 20 / 373 对）。
const double _gutter = 20;

/// 墨块编号的横向中心（Qt `centered(number, 31.5, …)` 与 `fill({20, y, 23, 18})`）。
const double _numberCenter = 31.5;

/// 竖屏「音乐平台」页。
///
/// 返回下一页内容的 y（Qt 是 `return y + m_scroll + 20`，这里把 scroll 加回去，
/// 与 Qt 的返回值口径一致）。调用方负责纸色/页头/播放条（见
/// `paintPortraitShell`）；本函数只画 [portraitProviderContentTop] 以下的内容。
///
/// - [providers]：已经按 `display.order` 排好、并已按 `PlatformFeatures::LocalMusic`
///   过滤过的平台表（Qt 的 `providerCardsState()` 里 `id == "local"` 在关掉本地音乐
///   时被跳过；过滤是调用方的事，页面不重复判断）。
///   ACCOUNT 段的三分支判据是 Qt 原文 `s["localMusic"]` / `s["provider"] == "siren"`
///   （`Qt/src/ResponsiveHudPages.cpp:647-666`），其中 `localMusic` 是
///   `m_music->isLocal()`（`Qt/src/NativeHud.cpp:286`），即「当前平台是本地音乐」，
///   所以这里只看 [currentId]。
/// - [currentId]：`music.provider`，决定哪一行高亮 + ACCOUNT 段走哪一支。
/// - [accounts]：平台 id → 已恢复的账号；null 或未登录即「未登录」。`siren` / `local`
///   在 Qt 里恒为「无需账号」，这里同样不看账号表。
/// - [scrollOffset]：Qt 的 `m_scroll`。签名按任务书保留 `String`
///   （页面状态是命令流字符串通道），解析失败按 0 处理。
/// - [playlistEditors]：`providerPlaylistEditors()` 的中文平台名（支持歌单编辑的那些），
///   空表时画 `平台能力由插件声明。`
/// - [userName]：`music.nickname`（仅登录态使用；空串时 Qt 仍画它，所以空串就什么都不显示
///   会与真值不一致 —— 见下方 `logged` 分支的注释）。
void paintPortraitProviderPage(
  PortraitCanvas c, {
  required List<ProviderDescriptor> providers,
  required String currentId,
  required Map<String, ProviderAccount?> accounts,
  required String scrollOffset,
  List<String> playlistEditors = const <String>[],
  String userName = '',
}) {
  final double scroll = double.tryParse(scrollOffset.trim()) ?? 0;
  // 起点按页高节奏收（矮屏上固定 158 会把最后一段平台按钮推出裁剪线）。
  final double top = math.min(
    PortraitRhythm.below(110, portraitProviderContentTop, c.height),
    math.max(0, c.height),
  );
  double y = top - scroll;

  // 行/按钮全部落在内容裁剪区内：`beginContent` 之后 fill/text/hit 都会夹到
  // [top, contentBottom]，于是滚出视口的行既不上屏也不接收命中（Qt 由整页 scissor 做）。
  c.beginContent(top);

  _terminalSection(c, y, '01', '音乐平台', 'PROVIDER ACCESS'); // :616
  y += 26; // :617

  if (providers.isEmpty) {
    // :618-620 —— 空列表：一段 12 号 muted 段落 + 16。
    y = c.paragraph(
      '当前没有可用的音乐平台。',
      _gutter,
      y,
      size: 12,
      width: _contentWidth(c),
      color: c.muted,
    ) + 16;
  }
  for (final ProviderDescriptor provider in providers) {
    final bool selected = provider.id == currentId; // :625
    if (selected) {
      // :627-630
      c.fill(Rect.fromLTWH(_gutter, y, _contentWidth(c), portraitProviderRowHeight), c.raised);
      c.fill(Rect.fromLTWH(_gutter, y, 2, portraitProviderRowHeight), c.amber);
    }
    // :631 —— 名称 15 demibold，设计稿宽 208（393-185）。
    c.text(provider.name, 32, y + 10,
        size: 15, width: c.gridWidth - 185, weight: 'demibold');
    // :632 —— 拉丁标签 8 regular muted，右锚 361（393-32）。
    c.rightText(provider.label, c.gridWidth - 32, y + 13, 8, 'regular', c.muted);
    // :633 —— 定位语 10 regular muted，设计稿宽 240（393-153）。
    c.text(provider.detail, 32, y + 34,
        size: 10, width: c.gridWidth - 153, color: c.muted);
    // :634-635 —— 右侧状态：当前平台（amber demibold）/ 切换 →（muted regular）。
    c.rightText(
      selected ? '当前平台' : '切换 →',
      c.gridWidth - 32,
      y + 35,
      10,
      selected ? 'demibold' : 'regular',
      selected ? c.amber : c.muted,
    );
    // :636 —— 行分隔线贴着行底（rowHeight - .6）。
    c.fill(
      Rect.fromLTWH(_gutter, y + portraitProviderRowHeight - .6, _contentWidth(c), .6),
      c.line,
    );
    // :637 —— 整行命中，label 是「切换到 <名>」。
    c.hit(
      Rect.fromLTWH(_gutter, y, _contentWidth(c), portraitProviderRowHeight),
      'provider:${provider.id}',
      '切换到 ${provider.name}',
    );
    y += portraitProviderRowHeight; // :638
  }

  y += 18; // :640
  _terminalSection(c, y, '02', '第三方平台插件', 'PLUGINS'); // :641
  y += 26; // :642
  // :643 —— 插件市场入口（画布自带的 indexRow：行高 67 + 7 间距 = 74）。
  c.indexRow(y, '插件市场', '安装与管理第三方平台插件', 'plugins', 'database');
  y += 74; // :644
  _terminalSection(c, y, '03', '账号与歌单', 'ACCOUNT'); // :645
  y += 26; // :646

  final String providerName = _displayName(providers, currentId);
  final ProviderAccount? account = accounts[currentId];
  final bool logged = account != null && account.loggedIn;
  final String name = userName.isEmpty ? (account?.nickname ?? '') : userName;

  if (currentId == 'local') {
    // :647-652 —— 当前平台是本地音乐（Qt 判据是 `s["localMusic"]`，即
    // `m_music->isLocal()`，不是 PlatformFeatures::LocalMusic）：无账号，只有文件夹管理。
    c.text(providerName, _gutter, y + 8, size: 15, width: _contentWidth(c), weight: 'demibold');
    c.text(
      '本地索引 / 无需账号，文件保留在原目录',
      _gutter,
      y + 30,
      size: 10,
      width: _contentWidth(c),
      color: c.muted,
    );
    y += 50;
    c.button(
      Rect.fromLTWH(_gutter, y, _contentWidth(c), 44),
      '文件夹管理 ＋',
      'discover',
    );
    y += 58;
  } else if (currentId == 'siren') {
    // :653-656 —— 塞壬：官网曲库，无需登录。
    c.text(providerName, _gutter, y + 8, size: 15, width: _contentWidth(c), weight: 'demibold');
    y = c.paragraph(
      '官网曲库 / 无需登录',
      _gutter,
      y + 30,
      size: 10,
      width: _contentWidth(c),
      color: c.muted,
    ) + 14;
  } else {
    // :657-666 —— 其它平台：登录态 + 账号名 + 登录按钮。
    c.text(providerName, _gutter, y + 8,
        size: 15, width: c.gridWidth - 153, weight: 'demibold');
    c.rightText(
      logged ? '已登录' : '未登录',
      c.gridWidth - 20,
      y + 11,
      10,
      'regular',
      logged ? c.ink : c.muted,
    );
    c.text(
      logged ? name : '登录后可同步收藏与歌单',
      _gutter,
      y + 30,
      size: 10,
      width: _contentWidth(c),
      color: c.muted,
    );
    y += 50;
    c.button(
      Rect.fromLTWH(_gutter, y, _contentWidth(c), 44),
      '账号登录 / $providerName',
      'music:login',
    );
    y += 58;
  }

  // :668-677 —— 支持歌单编辑的平台列表 / 插件声明的兜底文案。
  final List<String> editors = playlistEditors
      .map((String value) => value.trim())
      .where((String value) => value.isNotEmpty)
      .toList(growable: false);
  y = c.paragraph(
    editors.isEmpty ? '平台能力由插件声明。' : '支持歌单编辑：${editors.join('、')}',
    _gutter,
    y,
    size: 10,
    width: _contentWidth(c),
    color: c.muted,
  ) + 10;
  // :678 —— 页尾提示语。
  y = c.paragraph(
    '切换平台会停止当前播放，各平台账号与个人音乐独立保存。',
    _gutter,
    y,
    size: 10,
    width: _contentWidth(c),
    color: c.muted,
  ) + 16;

  c.endContent();
}

/// 设置页那张 `ACCESS / 音乐平台` 卡的可复用版本
/// （`Qt/src/ResponsiveHudPages.cpp:527-544`）。
///
/// 几何与文案逐字照抄：卡 96 高、左缘 2px amber、标题 8 号 muted、平台名 18 号
/// demibold、右上「切换平台 ↗」+ 命中 `provider`、左下登录态 + 右下
/// 「退出登录 ↗」/「登录账号 ↗」（命中 `music:logout` / `music:login`）。
///
/// 返回下一张卡的 y（Qt 的 `y += 116`）。调用方在设置页内容区按自己的节奏调用，
/// 本函数不改 `contentBottom`、不画页头。
double paintPortraitProviderAccessCard(
  PortraitCanvas c,
  double y, {
  required String providerName,
  required bool loggedIn,
  String userName = '',
}) {
  final double width = _contentWidth(c);
  // :528-530 —— 卡片底 + 左缘 amber 竖条。
  c.fill(Rect.fromLTWH(_gutter, y, width, 96), c.surface);
  c.fill(Rect.fromLTWH(_gutter, y, 2, 96), c.amber);
  // :531 —— 标题行（33 / y+12 / 8 号 / 设计稿宽 220）。
  c.text('ACCESS / 音乐平台', 33, y + 12, size: 8, width: c.gridWidth - 173, color: c.muted);
  // :532 —— 平台名（33 / y+32 / 18 demibold / 设计稿宽 210）。
  c.text(providerName, 33, y + 32, size: 18, width: c.gridWidth - 183, weight: 'demibold');
  // :533 —— 右上角「切换平台 ↗」（281 = 393-112，宽 83）。
  c.text('切换平台 ↗', c.gridWidth - 112, y + 15, size: 10, width: 83);
  // :534 —— 切换命中：269 = 393-124，104×44。
  c.hit(
    Rect.fromLTWH(c.gridWidth - 124, y, 104, 44),
    'provider',
    '切换音乐平台',
  );
  // :535-536 —— 左下登录态（33 / y+71 / 10 / 设计稿宽 205）。
  c.text(
    loggedIn ? userName : '尚未登录',
    33,
    y + 71,
    size: 10,
    width: c.gridWidth - 188,
    color: c.muted,
  );
  // :537 —— 右下登录/退登入口（同为 281 / 83）。
  c.text(
    loggedIn ? '退出登录 ↗' : '登录账号 ↗',
    c.gridWidth - 112,
    y + 71,
    size: 10,
    width: 83,
    color: c.muted,
  );
  // :538 —— 命中：269 / y+52 / 104×44。
  c.hit(
    Rect.fromLTWH(c.gridWidth - 124, y + 52, 104, 44),
    loggedIn ? 'music:logout' : 'music:login',
    loggedIn ? '退出登录' : '登录',
  );
  // :544 —— y += 116。
  return y + portraitProviderAccessCardStride;
}

/// Qt `terminalSection`（`Qt/src/ResponsiveHudPages.cpp:25-34`）：
/// 23×18 的墨块 + 居中编号（纸色）+ 13 号 demibold 标题 + 右缘 7 号 muted 说明。
void _terminalSection(
  PortraitCanvas c,
  double y,
  String number,
  String title,
  String caption,
) {
  c.fill(Rect.fromLTWH(_gutter, y, 23, 18), c.ink);
  c.centered(number, _numberCenter, y + 9, 8, 'regular', c.paper);
  c.text(title, 51, y + 2, size: 13, width: 180, weight: 'demibold');
  c.rightText(caption, c.gridWidth - 20, y + 5, 7, 'regular', c.muted);
}

/// 平台中文名：当前 id 在 [providers] 里的名字，找不到就用 id 本身
/// （Qt `ProviderRegistry::name` 的口径）。
String _displayName(List<ProviderDescriptor> providers, String id) {
  for (final ProviderDescriptor provider in providers) {
    if (provider.id == id) {
      return provider.name;
    }
  }
  return id;
}

/// 正文宽度：随页宽走（DPI 适配后页宽比 393 宽），左右各留 20 网格。
double _contentWidth(PortraitCanvas c) => c.gridWidth - 40;
