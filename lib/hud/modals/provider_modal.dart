/// Flutter port of the Qt landscape 'provider' modal body (modal == 'provider').
///
/// Content only. The shared frame — save(), alpha(motion.opacity), the full-stage
/// scrim, translate(0, motion.offset), the panel base, the title band and the
/// close-modal hit — comes from lib/hud/modals/modal_shell.dart (card ).
/// This file adds the platform cards and the one contextual button; it never
/// draws a scrim, a panel base, a title band or a close hit of its own.
///
/// Qt evidence, line by line:
///
/// * dispatch: Qt/src/NativeHudModal.cpp:210-213 — modal == 'provider' calls
///   platformPanel(x, y, usable).
/// * provider table: Qt/src/NativeHudModal.cpp:12-24 (the local row is dropped
///   when PlatformFeatures::LocalMusic is off, :20-22).
/// * platformPanel: Qt/src/NativeHudModal.cpp:292-306.
/// * platformChoices: Qt/src/NativeHudModal.cpp:259-291.
/// * provider display name: Qt/src/MusicApi.cpp:10-24 plus the kugou lite
///   override in Qt/src/MusicLibrary.cpp:106-111.
/// * wrap(): Qt/src/Glyphs.cpp:350-402 (grapheme branch :361-379).
/// * primitives: Qt/src/NativeHud.cpp:10-15 (ink), :37-39 (fill), :40-43
///   (text), :48-76 (fit), :77-79 (limited), :102-109 (hit), :110-120
///   (button), :125-129 (rule).
/// * credential probe: hasCredential(id) at Qt/src/NativeHudModal.cpp:281; the
///   account state itself stays with the host (MusicAccount).
/// * actions: 'provider:<id>' is consumed by Qt/src/NativeHudController.cpp:512-524;
///   'discover' opens the discover modal (:674-681); 'music:login' goes through the
///   music: prefix router (:666-668) and NativeHudMusic.cpp:283-286 opens login.
/// * title / subtitle literals: Qt/src/NativeHudModal.cpp:27 and :53; the
///   caller may override them because the title band belongs to the shell.
///
/// Deliberately **not** owned here: switching the provider, stopping playback,
/// credential lookup or storage, the discover/login flows, and the open/close
/// state machine. No I/O, no network, no host selection.
library;

import 'package:rhine_music_database/hud/modals/modal_shell.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';

// Literal table copied from Qt (NativeHudModal.cpp:12-24)

/// One row of the anonymous 'providers' table
/// (Qt/src/NativeHudModal.cpp:13-18).
final class ProviderModalEntry {
  const ProviderModalEntry({
    required this.id,
    required this.name,
    required this.label,
    required this.detail,
  });

  /// Provider key: siren / netease / qq / kugou / local.
  final String id;

  /// Chinese display name, also the hit label (:270).
  final String name;

  /// Latin label painted under the name (:274).
  final String label;

  /// Two/three-word scope line, wrapped to at most three rows (:277-279).
  final String detail;
}

/// The modal id this body renders under (Qt modal == 'provider', :210).
const String kProviderModalId = 'provider';

/// Qt 'providers' (Qt/src/NativeHudModal.cpp:13-18), in table order.
const List<ProviderModalEntry> providerModalEntries = <ProviderModalEntry>[
  ProviderModalEntry(
    id: 'siren',
    name: '塞壬唱片',
    label: 'MONSTER SIREN',
    detail: '官网曲库',
  ),
  ProviderModalEntry(
    id: 'netease',
    name: '网易云音乐',
    label: 'NETEASE',
    detail: '搜索 · 个人音乐 · 推荐 · 播放 · 歌单编辑',
  ),
  ProviderModalEntry(
    id: 'qq',
    name: 'QQ 音乐',
    label: 'QQ MUSIC',
    detail: '全类搜索 · 每日推荐 · 个人音乐 · 歌单编辑',
  ),
  ProviderModalEntry(
    id: 'kugou',
    name: '酷狗音乐',
    label: 'KUGOU',
    detail: '标准版 / 概念版 · 个人歌单 · 推荐与榜单 · 播放',
  ),
  ProviderModalEntry(
    id: 'local',
    name: '本地音乐',
    label: 'LOCAL',
    detail: '文件夹管理 · 导入与索引 · 本地检索 · 播放',
  ),
];

/// The visible table after Qt's PlatformFeatures::LocalMusic gate
/// (Qt/src/NativeHudModal.cpp:20-22). Qt removes the *last* element; local is the
/// last element of [providerModalEntries], so filtering by id is equivalent.
List<ProviderModalEntry> providerModalVisibleEntries(bool localMusicEnabled) {
  if (localMusicEnabled) {
    return providerModalEntries;
  }
  return providerModalEntries
      .where((ProviderModalEntry entry) => entry.id != 'local')
      .toList(growable: false);
}

/// MusicApi::providerName (Qt/src/MusicApi.cpp:10-24) with the kugou concept
/// edition override (Qt/src/MusicLibrary.cpp:106-111).
String providerModalDisplayName(String provider, {bool kugouLite = false}) {
  if (provider == 'local') {
    return '本地音乐';
  }
  if (provider == 'qq') {
    return 'QQ 音乐';
  }
  if (provider == 'kugou') {
    return kugouLite ? '酷狗概念版' : '酷狗音乐';
  }
  if (provider == 'siren') {
    return '塞壬唱片';
  }
  return '网易云音乐';
}

// Frame result

/// One build() worth of Qt commands plus the shell's hit table.
final class ProviderModalFrame {
  const ProviderModalFrame({
    required this.commands,
    required this.hits,
    required this.bounds,
    required this.policy,
  });

  /// Qt commands, in emission order: shell envelope first, then the body.
  final List<List<Object?>> commands;

  /// Qt hits: the shell's close-modal first, then every provider:<id> and the
  /// contextual discover / music:login button.
  final List<HudHit> hits;

  /// Panel rect in stage coordinates, from the shell.
  final ModalShellBounds bounds;

  /// The shell policy this modal rendered under.
  final ModalShellPolicy policy;
}

// Modal

/// The provider modal body, drawn inside the shared [ModalShell].
final class ProviderModal {
  const ProviderModal({
    required this.textPort,
    required this.stageWidth,
    required this.dark,
    required this.opacity,
    required this.offset,
    required this.currentProvider,
    this.credentials = const <String>{},
    this.localMusicEnabled = true,
    this.kugouLite = false,
    this.title = 'MUSIC PLATFORM',
    this.subtitle = '直接选择音乐平台 / 各平台账号独立保存',
    this.entries,
  });

  /// Injected glyph metrics (HudTextPort), used by fit(), limited() and wrap().
  final HudTextPort textPort;

  /// Stage width in 1080-normalized units (HudStage.width).
  final double stageWidth;

  /// Qt member dark (NativeHud::dark).
  final bool dark;

  /// Current motion.opacity (Qt/src/NativeHudModal.cpp:84).
  final double opacity;

  /// Current motion.offset (Qt/src/NativeHudModal.cpp:166).
  final double offset;

  /// music.provider — decides the selected card and the contextual button
  /// (Qt/src/NativeHudModal.cpp:265, :299-305).
  final String currentProvider;

  /// Providers with a saved credential on this machine; Qt asks
  /// hasCredential(id) per card (:281-288).
  final Set<String> credentials;

  /// PlatformFeatures::LocalMusic (:20-22).
  final bool localMusicEnabled;

  /// music.kugouEdition == 'lite' — only affects the login button label
  /// (Qt/src/MusicLibrary.cpp:106-111).
  final bool kugouLite;

  /// modalTitle('provider') (Qt/src/NativeHudModal.cpp:27).
  final String title;

  /// modalSubtitle('provider') (Qt/src/NativeHudModal.cpp:53).
  final String subtitle;

  /// 平台表：null = Qt 静态 `providers` 表（`NativeHudModal.cpp:13-18`）；
  /// 非 null 时由宿主按插件注册表（`ProviderRegistry.ids()`）注入，多出来的
  /// 平台（插件声明的）才能出现在卡片行里。过滤 `local` 仍由调用方负责。
  final List<ProviderModalEntry>? entries;

  /// Paints one frame. Pure: no I/O, no mutation, no global state.
  ProviderModalFrame build() {
    final _CommandSink sink = _CommandSink();
    final ModalShellResult result = ModalShell(
      sink: sink,
      text: textPort,
      spec: ModalShellSpec(
        modalId: kProviderModalId,
        stageWidth: stageWidth,
        dark: dark,
        opacity: opacity,
        offset: offset,
        title: title,
        subtitle: subtitle,
        content: _paint,
      ),
    ).build();
    return ProviderModalFrame(
      commands: sink.commands,
      hits: result.hits,
      bounds: result.bounds,
      policy: result.policy,
    );
  }

  /// platformPanel(x, y, usable) (Qt/src/NativeHudModal.cpp:292-306).
  void _paint(ModalShellBody body) {
    final double x = body.bounds.left;
    final double y = body.bounds.top;
    final double usable = body.bounds.width;
    final double left = x + 53; // :294
    final double width = usable - 106; // :294

    hudText(
      body.sink,
      'PROVIDER ACCESS / 音乐平台',
      left,
      y + 222,
      13,
      weight: 'demibold',
      dark: dark,
    ); // :293
    _platformChoices(
      body,
      left,
      y + 258,
      width,
      entries ?? providerModalVisibleEntries(localMusicEnabled),
    ); // :294

    hudRule(body.sink, dark, left, y + 490, width, 0.2); // :295
    hudText(
      body.sink,
      '切换平台会停止当前播放，各平台账号与个人音乐独立保存。',
      left,
      y + 520,
      15,
      dark: dark,
    ); // :296
    hudText(
      body.sink,
      '网易云与 QQ 支持歌单编辑；酷狗支持读取与播放。',
      left,
      y + 558,
      15,
      dark: dark,
    ); // :297
    hudText(body.sink, '塞壬唱片', left, y + 590, 15, dark: dark); // :298

    // :299-305 — exactly one contextual control, in this precedence.
    if (currentProvider == 'local') {
      _button(body, '文件夹管理 ＋', left, y + 660, 330, 48, 'discover', 16);
    } else if (currentProvider == 'siren') {
      hudText(body.sink, '塞壬唱片官网曲库', left, y + 675, 15, dark: dark);
    } else {
      _button(
        body,
        '账号登录 / ${providerModalDisplayName(currentProvider, kugouLite: kugouLite)}',
        left,
        y + 660,
        330,
        48,
        'music:login',
        16,
      );
    }
  }

  /// platformChoices(x, y, width, expanded) (Qt/src/NativeHudModal.cpp:259-291).
  ///
  /// The only caller passes expanded = true (:297), so the compact 66 px branch
  /// (:266) is unreachable in Qt too and is not reproduced here. The provider
  /// table is never empty (:20-22 removes at most the local row), so the guard
  /// below is a defensive no-op that emits no command.
  void _platformChoices(
    ModalShellBody body,
    double x,
    double y,
    double width,
    List<ProviderModalEntry> entries,
  ) {
    if (entries.isEmpty) {
      return;
    }
    const double gap = 12; // :260
    final double cardWidth = (width - gap * (entries.length - 1)) / entries.length; // :261
    for (int index = 0; index < entries.length; index += 1) {
      final ProviderModalEntry entry = entries[index];
      final double left = x + index * (cardWidth + gap); // :263
      final bool selected = currentProvider == entry.id; // :265
      const double height = 190; // :266 (expanded)

      // :267-270 — the selected card keeps the same tint role at higher alpha.
      hudFill(
        body.sink,
        dark
            ? <Object?>[0.55, 0.59, 0.46, selected ? 0.3 : 0.12]
            : <Object?>[0.44, 0.49, 0.36, selected ? 0.23 : 0.09],
        left,
        y,
        cardWidth,
        height,
      );
      body.hit(left, y, cardWidth, height, 'provider:${entry.id}', entry.name); // :271
      if (selected) {
        // :272-274
        hudFill(
          body.sink,
          dark
              ? <Object?>[0.7, 0.75, 0.53, 1]
              : <Object?>[0.44, 0.49, 0.36, 1],
          left,
          y,
          3,
          height,
        );
      }
      hudText(
        body.sink,
        entry.label + (selected ? ' / ACTIVE' : ''),
        left + 16,
        y + 10,
        10,
        dark: dark,
      ); // :275
      hudText(
        body.sink,
        entry.name,
        left + 16,
        y + 29,
        22,
        weight: 'demibold',
        dark: dark,
      ); // :276

      // :277-280 — at most three wrapped detail rows, 21 px apart.
      final List<String> lines = _wrap(entry.detail, cardWidth - 32, 14);
      final int visible = lines.length < 3 ? lines.length : 3;
      for (int row = 0; row < visible; row += 1) {
        hudText(
          body.sink,
          lines[row],
          left + 16,
          y + 75 + row * 21,
          14,
          dark: dark,
        );
      }

      // :281-288 — local and siren never need a login.
      final String note = entry.id == 'local'
          ? '独立本地库 / 无需登录'
          : (entry.id == 'siren'
              ? '官网曲库 / 无需登录'
              : (credentials.contains(entry.id)
                  ? '本机已保存登录'
                  : '未登录 / 可选择后扫码'));
      _limited(body, note, left + 16, y + 150, 12, cardWidth - 32);
    }
  }

  /// Qt NativeHud::button (Qt/src/NativeHud.cpp:110-120) under m_modalControls.
  ///
  /// Duplicated here because chrome.dart exposes no button primitive and the
  /// shell keeps its own copy private; the emission order (hit, tint, fitted
  /// label) and the fit('regular') quirk at :118 are preserved exactly.
  void _button(
    ModalShellBody body,
    String label,
    double x,
    double y,
    double width,
    double height,
    String action,
    double size,
  ) {
    body.hit(x, y, width, height, action, label); // :112
    final double inset = _min(10, width / 8); // :113
    hudFill(body.sink, modalShellControlTint(dark: dark), x, y, width, height); // :115-116
    hudText(
      body.sink,
      textPort.fit(label, size, width - inset * 2), // :118
      x + inset,
      y + (height - size) / 2 - 4,
      size,
      dark: dark,
    ); // :119
  }

  /// Qt Glyphs::wrap grapheme branch (Qt/src/Glyphs.cpp:361-379).
  ///
  /// Qt splits on grapheme clusters, starts a new line when the accumulated
  /// width would pass [limit], and honours '\n'. The card details in the Qt
  /// table are CJK, i.e. the needsLayout() branch, so that is the branch
  /// reproduced here; the per-character advance branch (:381-398) applies only
  /// to simple Latin runs and is not exercised by this table.
  List<String> _wrap(String value, double limit, double size) {
    final List<String> lines = <String>[];
    String line = '';
    for (final int rune in value.runes) {
      final String cluster = String.fromCharCode(rune);
      if (cluster == '\n') {
        lines.add(line);
        line = '';
      } else if (line.isNotEmpty &&
          textPort.glyphWidth(line + cluster, size) > limit) {
        lines.add(line);
        line = cluster;
      } else {
        line += cluster;
      }
    }
    lines.add(line);
    return lines;
  }

  /// Qt limited(value, x, y, size, width, weight) (Qt/src/NativeHud.cpp:77-79).
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
      textPort.fit(value, size, width, weight),
      x,
      y,
      size,
      weight: weight,
      dark: dark,
    );
  }
}

double _min(double a, double b) => a < b ? a : b;

/// Command-only sink: hits go through the shell's ModalShellHitTable (body.hit).
final class _CommandSink implements HudSurfaceSink {
  final List<List<Object?>> commands = <List<Object?>>[];

  @override
  void op(List<Object?> command) => commands.add(command);

  @override
  void hit(HudHit hit) =>
      throw UnsupportedError('ProviderModal 只通过 ModalShellBody.hit 发命中。');
}
