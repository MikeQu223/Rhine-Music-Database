/// Flutter port of the Qt landscape 'quality' modal body (modal == 'quality').
///
/// This library owns **content only**. The shared frame pipeline — save(),
/// alpha(motion.opacity), the full-stage scrim, translate(0, motion.offset),
/// the panel base, the title band and the close-modal hit — comes from
/// lib/hud/modals/modal_shell.dart (card ). Nothing here re-emits any of
/// those commands, and nothing here reads storage, starts I/O, touches the
/// network, resolves an account or selects a production host: every value below
/// is injected by the caller, and every command is written to the caller's
/// HudSurfaceSink.
///
/// Qt evidence for the body, line by line:
///
/// * entry point: Qt/src/NativeHudModal.cpp:210-211 — modal == 'quality' calls
///   qualityPanel(x, y, usable); the frame before it is :162-202.
/// * qualityPanel body: Qt/src/NativeHudModal.cpp:380-446.
/// * qualityChoice row/card: Qt/src/NativeHudModal.cpp:326-377.
/// * description table: Qt/src/NativeHudModal.cpp:307-323 (the siren +
///   lossless override is :329-331).
/// * option order / per-provider lists: Qt/src/MusicPlayer.cpp:104-124
///   (MusicPlayer::qualityOptions).
/// * featured cards per provider: Qt/src/NativeHudModal.cpp:405-412.
/// * primitives: Qt/src/NativeHud.cpp:10-15 (ink), :37-39 (fill), :40-43
///   (text), :48-76 (fit), :77-79 (limited), :102-109 (hit), :125-129
///   (rule), :130-134 (image).
/// * selection action: Qt/src/NativeHudController.cpp:707-710
///   (quality:open opens the modal, quality:set:<id> sets the preference via
///   MusicPlayer::setQuality, Qt/src/MusicPlayer.cpp:127-157).
/// * title / subtitle literals: Qt/src/NativeHudModal.cpp:30 and :56; the
///   caller may override them because the title band belongs to the shell.
///
/// Deliberately **not** owned here: the audio preference itself
/// (MusicPlayer::setQuality), the playback engine, the credential store, the
/// badge image cache (Host::image), and the quality open/close state machine
/// (NativeHudController.cpp:132-143, :701-710). Those stay with the host.
library;

import 'package:rhine_music_database/hud/modals/modal_shell.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';

// Literal tables copied from Qt (NativeHudModal.cpp:307-323)

/// One row of Qt's qualityDescriptions table
/// (Qt/src/NativeHudModal.cpp:308-313).
///
/// [badge] is the image key suffix: Qt looks up 'quality:<provider>-<badge>' in
/// the host image cache (:346-347). An empty badge means 'never an image', which
/// is also why those rows fall back to the STD / HQ / AUTO text badge.
final class QualityModalDescription {
  const QualityModalDescription({
    required this.title,
    required this.caption,
    required this.detail,
    required this.badge,
  });

  /// QualityDescription::title — the row/card headline (:315-322).
  final String title;

  /// QualityDescription::caption — the uppercase English line.
  final String caption;

  /// QualityDescription::detail — one sentence, painted through limited().
  final String detail;

  /// QualityDescription::badge — hq, sq, hires, jymaster or empty.
  final String badge;
}

/// Qt qualityDescriptions (Qt/src/NativeHudModal.cpp:314-322), verbatim.
const Map<String, QualityModalDescription> qualityModalDescriptions =
    <String, QualityModalDescription>{
  'standard': QualityModalDescription(
    title: '标准',
    caption: 'STANDARD',
    detail: '日常聆听，兼顾音质与数据流量',
    badge: '',
  ),
  'higher': QualityModalDescription(
    title: '较高',
    caption: 'HIGH QUALITY',
    detail: '提升声音细节，保持轻量传输',
    badge: 'hq',
  ),
  'exhigh': QualityModalDescription(
    title: '极高',
    caption: 'HIGH QUALITY',
    detail: '更充分保留有损编码中的声音细节',
    badge: 'hq',
  ),
  'lossless': QualityModalDescription(
    title: '无损',
    caption: 'LOSSLESS / SQ',
    detail: '无损编码，保留更完整的录音细节',
    badge: 'sq',
  ),
  'ape': QualityModalDescription(
    title: '无损 / APE',
    caption: 'LOSSLESS / APE',
    detail: '以 APE 格式提供无损音源',
    badge: 'sq',
  ),
  'hires': QualityModalDescription(
    title: '高解析无损',
    caption: 'HI-RES AUDIO',
    detail: '还原高解析录音中的丰富层次',
    badge: 'hires',
  ),
  'jymaster': QualityModalDescription(
    title: '超清母带',
    caption: 'MASTER AUDIO',
    detail: '聆听母带版本中的细腻质感与动态',
    badge: 'jymaster',
  ),
  'best': QualityModalDescription(
    title: '自动最高可用',
    caption: 'BEST AVAILABLE',
    detail: '由平台选择当前可用的最高音质',
    badge: '',
  ),
};

/// The siren + lossless replacement row (Qt/src/NativeHudModal.cpp:329-331).
const QualityModalDescription qualityModalSirenLossless =
    QualityModalDescription(
  title: '官网原始音源',
  caption: 'ORIGINAL SOURCE',
  detail: '直接使用塞壬唱片官网提供的音源文件',
  badge: '',
);

/// MusicPlayer::qualityOptions (Qt/src/MusicPlayer.cpp:104-124), ids only.
///
/// Qt also carries a second label per option, but qualityPanel never paints it:
/// qualityChoice always reads the title out of [qualityModalDescriptions]
/// (Qt/src/NativeHudModal.cpp:328-331, :368, :373). Carrying unused labels
/// would invent UI Qt never draws, so they are dropped here.
List<String> qualityModalOptions(String provider) {
  if (provider == 'qq') {
    return <String>['best', 'standard', 'exhigh', 'lossless', 'ape'];
  }
  if (provider == 'kugou') {
    return <String>['standard', 'exhigh', 'lossless', 'hires'];
  }
  if (provider == 'siren') {
    return <String>['lossless'];
  }
  return <String>['standard', 'higher', 'exhigh', 'lossless', 'hires', 'jymaster'];
}

/// Featured cards per provider (Qt/src/NativeHudModal.cpp:405-412).
List<String> qualityModalFeatured(String provider) {
  if (provider == 'qq') {
    return <String>['best', 'lossless'];
  }
  if (provider == 'kugou') {
    return <String>['hires', 'lossless'];
  }
  if (provider == 'siren') {
    return <String>[];
  }
  return <String>['jymaster', 'hires'];
}

/// The names hash used for the 'actual source' line
/// (Qt/src/NativeHudModal.cpp:385-388).
const Map<String, String> qualityModalActualNames = <String, String>{
  'standard': '标准',
  'hq': '高品质 / HQ',
  'sq': '无损 / SQ',
  'hires': '高解析无损 / Hi-Res',
  'jymaster': '超清母带',
  'jyeffect': '高清臻音',
  'sky': '沉浸环绕声',
};

/// Pixel size of one host badge image, as Host::image(key).size() reports it.
///
/// The port never ships image assets: [QualityModal.badges] answers null when
/// the host has no bitmap for the key, which is exactly Qt's pixels.isNull()
/// branch (Qt/src/NativeHudModal.cpp:350, :357, :435).
final class QualityModalBadge {
  const QualityModalBadge({required this.width, required this.height});

  final double width;
  final double height;
}

/// Resolves 'quality:<provider>-<badge>' to a bitmap size, or null when the
/// host has none. Implementations must be pure lookups: no decoding, no I/O.
typedef QualityModalBadgeResolver = QualityModalBadge? Function(String key);

// Frame result

/// One build() worth of Qt commands plus the shell's hit table.
final class QualityModalFrame {
  const QualityModalFrame({
    required this.commands,
    required this.hits,
    required this.bounds,
    required this.policy,
  });

  /// Qt commands, in emission order: shell envelope first, then the body.
  final List<List<Object?>> commands;

  /// Qt hits: the shell's close-modal first, then every quality:set:<id>.
  final List<HudHit> hits;

  /// Panel rect in stage coordinates, from the shell.
  final ModalShellBounds bounds;

  /// The shell policy this modal rendered under.
  final ModalShellPolicy policy;
}

// Modal

/// The quality modal body, drawn inside the shared [ModalShell].
final class QualityModal {
  const QualityModal({
    required this.textPort,
    required this.stageWidth,
    required this.dark,
    required this.opacity,
    required this.offset,
    required this.provider,
    required this.selectedQuality,
    required this.actualQuality,
    this.loading = false,
    this.failed = false,
    this.trial = false,
    this.badges,
    this.title = 'AUDIO QUALITY',
    this.subtitle = '声音档案 / 播放音质',
  });

  /// Injected glyph metrics (HudTextPort), used by fit() and limited().
  final HudTextPort textPort;

  /// Stage width in 1080-normalized units (HudStage.width).
  final double stageWidth;

  /// Qt member dark (NativeHud::dark).
  final bool dark;

  /// Current motion.opacity (Qt/src/NativeHudModal.cpp:84).
  final double opacity;

  /// Current motion.offset (Qt/src/NativeHudModal.cpp:166).
  final double offset;

  /// music.provider — selects the featured cards, the option list and the
  /// siren / netease special branches (Qt/src/NativeHudModal.cpp:329,
  /// :405-412, :427-441).
  final String provider;

  /// music.player.quality — the selected preference (:332, :402).
  final String selectedQuality;

  /// music.player.actualQuality — the codec actually served (:389).
  final String actualQuality;

  /// music.player.loading (:392).
  final bool loading;

  /// music.player.failed (:390).
  final bool failed;

  /// music.player.trial (:394).
  final bool trial;

  /// Optional badge lookup; null (or a null answer) reproduces Qt's
  /// pixels.isNull() branch.
  final QualityModalBadgeResolver? badges;

  /// modalTitle('quality') (Qt/src/NativeHudModal.cpp:30).
  final String title;

  /// modalSubtitle('quality') (Qt/src/NativeHudModal.cpp:56).
  final String subtitle;

  bool get _siren => provider == 'siren';

  /// Paints one frame. Pure: no I/O, no mutation, no global state.
  QualityModalFrame build() {
    final _CommandSink sink = _CommandSink();
    final ModalShellResult result = ModalShell(
      sink: sink,
      text: textPort,
      spec: ModalShellSpec(
        modalId: kModalShellQualityModal,
        stageWidth: stageWidth,
        dark: dark,
        opacity: opacity,
        offset: offset,
        title: title,
        subtitle: subtitle,
        content: _paint,
      ),
    ).build();
    return QualityModalFrame(
      commands: sink.commands,
      hits: result.hits,
      bounds: result.bounds,
      policy: result.policy,
    );
  }

  /// qualityPanel(x, y, usable) (Qt/src/NativeHudModal.cpp:380-446).
  void _paint(ModalShellBody body) {
    final double x = body.bounds.left;
    final double y = body.bounds.top;
    final double usable = body.bounds.width;
    final double left = x + 53; // :383
    final double width = usable - 106; // :384

    // :389-396 — preference name, then the three playback overrides in Qt order.
    String actual = qualityModalActualNames[actualQuality] ?? '尚未确认';
    if (failed) {
      actual = '音源不可用';
    } else if (loading) {
      actual = '正在获取音源…';
    } else if (trial) {
      actual = '试听片段';
    }
    final List<Object?> accent = _accent();

    hudFill(body.sink, accent, left, y + 195, 3, 48); // :397-398
    hudText(
      body.sink,
      '实际音源 / SOURCE',
      left + 17,
      y + 199,
      10,
      weight: 'demibold',
      tracking: 0.6,
      dark: dark,
    ); // :399
    hudText(
      body.sink,
      actual,
      left + 17,
      y + 219,
      18,
      weight: 'demibold',
      dark: dark,
    ); // :400

    final String preference = _siren
        ? '官网原始音源'
        : (qualityModalDescriptions[selectedQuality]?.title ?? '');
    _limited(
      body,
      '已选偏好：' + preference,
      left + width * 0.52,
      y + 219,
      14,
      width * 0.48,
    ); // :401-403

    hudRule(body.sink, dark, left, y + 257, width, 0.25); // :404

    // :405-417 — featured cards first, two per row.
    final List<String> featured = qualityModalFeatured(provider);
    final double cardWidth = (width - 18) / 2; // :413
    for (int index = 0; index < featured.length; index += 1) {
      _qualityChoice(
        body,
        featured[index],
        index + 1,
        left + index * (cardWidth + 18),
        y + 278,
        cardWidth,
        featured: true,
      ); // :414-417
    }

    // :418-425 — the remaining options, iterated in Qt's reverse order
    // (options.crbegin() .. crend()), compact rows at a fixed 58 px stride.
    final List<String> options = qualityModalOptions(provider);
    int row = 0;
    for (int index = options.length - 1; index >= 0; index -= 1) {
      final String id = options[index];
      if (featured.contains(id)) {
        continue;
      }
      _qualityChoice(
        body,
        id,
        row + 3,
        left,
        y + 474 + row * 58,
        width,
        featured: false,
      );
      row += 1;
    }

    // :426-441 — netease keeps two extra source badges visible even though they
    // are not selectable rows.
    if (provider == 'netease') {
      hudText(
        body.sink,
        '其他音源标识',
        left,
        y + 738,
        11,
        weight: 'demibold',
        dark: dark,
      ); // :428
      const List<String> extraBadges = <String>['jyeffect', 'sky'];
      for (int index = 0; index < extraBadges.length; index += 1) {
        final String id = extraBadges[index];
        final String key = 'quality:' + provider + '-' + id;
        final QualityModalBadge? pixels = badges?.call(key);
        final double badgeX = left + 130 + index * 235; // :434
        if (pixels != null) {
          final double badgeWidth = 18 * pixels.width / pixels.height; // :436
          hudOp(body.sink, <Object?>[
            'image',
            key,
            badgeX,
            y + 735,
            badgeWidth,
            18,
          ]); // :437
          hudText(
            body.sink,
            qualityModalActualNames[id] ?? '',
            badgeX + badgeWidth + 12,
            y + 737,
            12,
            dark: dark,
          ); // :438
        }
      }
    }

    hudRule(body.sink, dark, left, y + 775, width, 0.22); // :442
    hudText(
      body.sink,
      '选择与设置同步 · 切换保留播放位置',
      left,
      y + 791,
      12,
      dark: dark,
    ); // :443
    _limited(
      body,
      '可用音质由歌曲与平台权益决定，以实际音源为准。',
      left + width * 0.47,
      y + 791,
      12,
      width * 0.53,
    ); // :444-445
  }

  /// qualityChoice(id, number, x, y, width, featured)
  /// (Qt/src/NativeHudModal.cpp:326-377).
  void _qualityChoice(
    ModalShellBody body,
    String id,
    int number,
    double x,
    double y,
    double width, {
    required bool featured,
  }) {
    // :328-331 — siren substitutes the lossless row; every other id comes from
    // the shared table (Qt's QHash::value default-constructs an empty row).
    final QualityModalDescription description = _siren && id == 'lossless'
        ? qualityModalSirenLossless
        : (qualityModalDescriptions[id] ??
            const QualityModalDescription(
                title: '', caption: '', detail: '', badge: ''));
    // :332 — siren pins the selection to lossless.
    final bool selected = _siren ? id == 'lossless' : selectedQuality == id;
    final double height = featured ? 174.0 : 57.0; // :333
    final List<Object?> accent = _accent(); // :334
    final List<Object?> tint = List<Object?>.of(accent)
      ..[3] = selected ? 0.18 : 0.055; // :335-336
    if (featured || selected) {
      hudFill(body.sink, tint, x, y, width, height); // :337-339
    }
    hudRule(body.sink, dark, x, y + height, width, selected ? 0.6 : 0.13); // :340
    if (selected) {
      hudFill(body.sink, accent, x, y, 3, height); // :341-343
    }
    body.hit(x, y, width, height, 'quality:set:' + id, description.title); // :344

    final String index = number.toString().padLeft(2, '0'); // :345
    final String key = 'quality:' + provider + '-' + description.badge; // :346
    final QualityModalBadge? pixels =
        description.badge.isEmpty ? null : badges?.call(key); // :347
    final double badgeX = featured ? x + width - 104 : x + 30; // :348
    final double badgeY = featured ? y + 19 : y + 16; // :349
    if (pixels != null) {
      // :350-356 — width capped at 68, aspect preserved; kugou gets a backing
      // plate so the badge reads on its light artwork.
      final double badgeWidth = _min(68, 21 * pixels.width / pixels.height);
      final double badgeHeight = badgeWidth * pixels.height / pixels.width;
      if (provider == 'kugou') {
        hudFill(
          body.sink,
          <Object?>[0.30, 0.33, 0.26, 1],
          badgeX - 4,
          badgeY - 4,
          badgeWidth + 8,
          badgeHeight + 8,
        ); // :353-355
      }
      hudOp(body.sink, <Object?>[
        'image',
        key,
        badgeX,
        badgeY,
        badgeWidth,
        badgeHeight,
      ]); // :356
    } else if (!featured) {
      // :357-365 — compact rows fall back to a text badge.
      String label = 'STD';
      if (id == 'best') {
        label = 'AUTO';
      } else if (description.badge == 'hq') {
        label = 'HQ';
      }
      hudText(
        body.sink,
        label,
        x + 30,
        y + 18,
        11,
        weight: 'demibold',
        dark: dark,
      );
    }
    if (featured) {
      // :366-370
      hudText(
        body.sink,
        index + ' / ' + description.caption,
        x + 22,
        y + 22,
        11,
        weight: 'demibold',
        tracking: 0.8,
        dark: dark,
      );
      hudText(
        body.sink,
        description.title,
        x + 22,
        y + 62,
        26,
        weight: 'demibold',
        dark: dark,
      );
      _limited(body, description.detail, x + 22, y + 106, 13, width - 44);
      hudText(
        body.sink,
        selected ? '✓ 已选择' : '选择此档 →',
        x + 22,
        y + 143,
        12,
        weight: 'demibold',
        dark: dark,
      );
    } else {
      // :371-376
      hudText(body.sink, index, x + 10, y + 20, 9, dark: dark);
      hudText(
        body.sink,
        description.title,
        x + 112,
        y + 6,
        17,
        weight: 'demibold',
        dark: dark,
      );
      _limited(body, description.detail, x + 112, y + 32, 12, width - 256);
      hudText(
        body.sink,
        selected ? '✓ 已选择' : description.caption,
        x + width - 134,
        y + 20,
        10,
        weight: 'demibold',
        dark: dark,
      );
    }
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

  /// Qt/src/NativeHudModal.cpp:334 / :397.
  List<Object?> _accent() => dark
      ? <Object?>[0.69, 0.74, 0.53, 1]
      : <Object?>[0.43, 0.48, 0.34, 1];
}

double _min(double a, double b) => a < b ? a : b;

/// Command-only sink: this modal never emits hits through the sink, because hits
/// go through the shell's own ModalShellHitTable (body.hit).
final class _CommandSink implements HudSurfaceSink {
  final List<List<Object?>> commands = <List<Object?>>[];

  @override
  void op(List<Object?> command) => commands.add(command);

  @override
  void hit(HudHit hit) =>
      throw UnsupportedError('QualityModal 只通过 ModalShellBody.hit 发命中。');
}
