///  - one slice state, four HUD command streams (spike, no network/storage).
///
/// This probe **does not draw**. It feeds one [SliceState] snapshot through the
/// production page builders and captures the wire commands they emit, so the
/// Dart HUD spike can prove the four slice pages are producible from the same
/// shared contract:
///
/// * archive  -> [HudArchivePage.archive] (`lib/hud/pages/archive_page.dart:223`)
/// * detail   -> [renderSongDetail]  (`lib/hud/pages/song_detail.dart:663`)
/// * search   -> [buildSearchToolbarLayout] + [buildSearchFooterLayout]
///               (`lib/hud/modals/search_modal.dart`) and
///               [SearchResultsLayer.draw] (`lib/hud/modals/search_results.dart`)
/// * queue    -> [renderQueueModal]  (`lib/hud/modals/queue_modal.dart:161`)
///
/// Every command list below is copied from those builders in source order; this
/// file contributes no geometry of its own. The only local work is the injected
/// text/measurement port: it measures with the real atlas advances from
/// [GlyphLoadResult] and treats a missing glyph as zero advance (fail-closed,
/// never a fabricated outline).
///
/// Boundaries: no network, no user library, no storage, no platform channel, no
/// Flutter widgets. The only Flutter import is `dart:ui`'s [Rect], required by
/// [SearchResultsPort]'s method signatures.
///
/// Slice fixture: the sample song/queue rows are fixed spike data, not a read of
/// the user's library. They exist so the four pages have a current selection
/// (S1/S2/S4/S7 in `docs/flutter-migration/01-slice.md`).
library;

import 'dart:ui' show Rect;

import '../../hud/modals/queue_modal.dart';
import '../../hud/modals/search_modal.dart' as search_chrome;
import '../../hud/modals/search_results.dart' as search_results;
import '../../hud/pages/archive_page.dart';
import '../../hud/pages/chrome.dart';
import '../../hud/pages/song_detail.dart';
import '../../hud/protocol/hud_command.dart';
import 'glyph_loader.dart';
import 'hud_painter.dart';

/// The four slice pages covered by .
enum SlicePage { archive, detail, search, queue }

/// Immutable input snapshot for all four producers.
///
/// Values are slice facts, not Qt facts: [width] is the slice stage width from
/// `01-slice.md` (1728), [libraryIndex] is the selected 17th row (index 16),
/// and [query]/[keyword] are the S4 search terms.
class SliceState {
  const SliceState({
    this.width = 1728,
    this.dark = true,
    this.libraryIndex = 16,
    this.libraryTotal = 40,
    this.selectedPhysicalRow = 2,
    this.query = '青花瓷',
    this.keyword = '青花瓷',
    this.trackListMode = false,
    this.queueOffset = 0,
    this.queueBounds = const QueueModalRect(0, 0, 1006, 836),
  });

  /// Slice stage width (1728; `01-slice.md`).
  final double width;

  /// Slice baseline theme (dark; `01-slice.md`).
  final bool dark;

  /// Selected library index (S1 selects the 17th song => 16).
  final int libraryIndex;

  final int libraryTotal;

  /// Physical slot row passed to the archive chrome.
  final int selectedPhysicalRow;

  /// Live query text (S4).
  final String query;

  /// Committed keyword (S4); the search results layer highlights this one.
  final String keyword;

  final bool trackListMode;

  /// First visible queue row (S7).
  final int queueOffset;

  /// Queue panel rect; the Qt caller supplies x/y and fixes height at 836
  /// (`Qt/src/NativeHudPlayer.cpp:49`), so the probe takes the rect as input.
  final QueueModalRect queueBounds;

  Map<String, Object?> toJson() => <String, Object?>{
        'width': width,
        'dark': dark,
        'libraryIndex': libraryIndex,
        'libraryTotal': libraryTotal,
        'selectedPhysicalRow': selectedPhysicalRow,
        'query': query,
        'keyword': keyword,
        'trackListMode': trackListMode,
        'queueOffset': queueOffset,
        'queueBounds': <double>[
          queueBounds.x,
          queueBounds.y,
          queueBounds.width,
          queueBounds.height,
        ],
      };
}

/// One page's wire commands, decoded commands, hits and decode issues.
final class PageCommandStream {
  PageCommandStream._({
    required this.page,
    required this.wire,
    required this.decoded,
    required this.hits,
    required this.issues,
  });

  /// Captures [wire] and decodes it with the production protocol decoder.
  factory PageCommandStream.capture({
    required SlicePage page,
    required List<List<Object?>> wire,
    required List<Map<String, Object?>> hits,
  }) {
    final HudCommandDecode decoded = decodeHudCommands(<Object?>[...wire]);
    return PageCommandStream._(
      page: page,
      wire: List<List<Object?>>.unmodifiable(wire),
      decoded: List<HudCommand>.unmodifiable(decoded.commands),
      hits: List<Map<String, Object?>>.unmodifiable(hits),
      issues: List<String>.unmodifiable(<String>[
        for (final HudCommandIssue issue in decoded.issues) issue.toString(),
      ]),
    );
  }

  final SlicePage page;

  /// Raw wire arrays, exactly as the production builders emitted them.
  final List<List<Object?>> wire;

  /// Wire commands decoded by `decodeHudCommands` (same order).
  final List<HudCommand> decoded;

  final List<Map<String, Object?>> hits;

  /// Decode problems; empty for every well-formed producer.
  final List<String> issues;

  /// Op names in stream order (`wire[i][0]`).
  List<String> get operations => <String>[
        for (final List<Object?> command in wire)
          command.isNotEmpty && command.first is String ? command.first! as String : '',
      ];

  /// Runs the  executor over [decoded]; useful for state assertions.
  SpikeHudExecution get execution => executeSpikeHudCommands(decoded);

  @override
  String toString() =>
      'PageCommandStream($page, ${wire.length} commands, ${hits.length} hits, ${issues.length} issues)';
}

/// Archive page command stream.
///
/// The archive chrome delegates the track list and empty state to injected
/// producers by design (`archive_page.dart:152-158`). The probe injects empty
/// producers, so the stream covers the production chrome only; it is the
/// minimal assertable sequence for this page, not a claim about row rendering.
PageCommandStream archivePageCommands(SliceState state, {GlyphLoadResult? glyphs}) {
  final GlyphLoadResult atlas = glyphs ?? loadSpikeGlyphs();
  final _SpikeMetrics metrics = _SpikeMetrics(atlas);
  final _WireSink sink = _WireSink();
  final HudArchivePage page = HudArchivePage(sink, _ArchiveTextPort(sink, metrics, dark: state.dark), dark: state.dark);
  page.archive(
    width: state.width,
    s: _archiveState(state),
    drawTrackList: (double width, HudArchiveState s) {},
    drawEmpty: (double width, HudArchiveState s) {},
    supportsTrackList: (HudArchiveState s) => true,
  );
  return PageCommandStream.capture(page: SlicePage.archive, wire: sink.commands, hits: sink.hits);
}

/// Detail page command stream.
PageCommandStream detailPageCommands(SliceState state, {GlyphLoadResult? glyphs}) {
  final GlyphLoadResult atlas = glyphs ?? loadSpikeGlyphs();
  final _SpikeMetrics metrics = _SpikeMetrics(atlas);
  final SongDetailDrawing drawing = renderSongDetail(
    _songDetailState(state),
    state.width,
    glyphs: _DetailGlyphs(metrics),
    images: const _NoImages(),
  );
  return PageCommandStream.capture(
    page: SlicePage.detail,
    wire: <List<Object?>>[
      for (final Object? command in drawing.commands)
        if (command is List<Object?>) command else <Object?>[command],
    ],
    hits: drawing.hits,
  );
}

/// Search page command stream: toolbar, result layer, footer.
PageCommandStream searchPageCommands(SliceState state, {GlyphLoadResult? glyphs}) {
  final GlyphLoadResult atlas = glyphs ?? loadSpikeGlyphs();
  final _SpikeMetrics metrics = _SpikeMetrics(atlas);
  final search_chrome.SearchPalette palette = search_chrome.SearchPalette(
    ink: const search_results.SearchColor(0.92, 0.92, 0.92, 1),
    dark: state.dark,
  );
  final Rect bounds = search_chrome.searchModalBounds(state.width);
  final List<List<Object?>> wire = <List<Object?>>[];
  final List<Map<String, Object?>> hits = <Map<String, Object?>>[];

  void append(search_chrome.SearchModalLayout layout) {
    for (final search_chrome.SearchDrawOp op in layout.ops) {
      switch (op) {
        case search_chrome.SearchFillOp(:final Rect rect, :final search_results.SearchColor color):
          wire.add(<Object?>['fill', _searchColorWire(color), rect.left, rect.top, rect.width, rect.height]);
        case search_chrome.SearchRuleOp(:final Rect rect, :final double alpha):
          // SearchModalPainter.paint draws rules with ink.withAlpha(alpha).
          wire.add(<Object?>[
            'fill',
            _searchColorWire(palette.ink.withAlpha(alpha)),
            rect.left,
            rect.top,
            rect.width,
            rect.height,
          ]);
        case search_chrome.SearchTextOp(
            :final String text,
            :final double x,
            :final double y,
            :final double size,
            :final String weight,
            :final double letterSpacing,
            :final search_results.SearchColor color,
          ):
          wire.add(<Object?>['text', text, x, y, size, weight, letterSpacing, _searchColorWire(color)]);
        case search_chrome.SearchHitOp(
            :final double x,
            :final double y,
            :final double width,
            :final double height,
            :final String action,
            :final String label,
          ):
          hits.add(<String, Object?>{
            'x': x,
            'y': y,
            'width': width,
            'height': height,
            'action': action,
            'label': label,
          });
      }
    }
  }

  append(search_chrome.buildSearchToolbarLayout(
    stageWidth: state.width,
    localMusic: false,
    searchKind: 'song',
    groupBy: '',
    activeGroup: '',
    hasSongRows: true,
    palette: palette,
    glyphWidth: metrics.width,
  ));

  final _SearchWirePort port = _SearchWirePort(metrics);
  final search_results.SearchResultsLayer layer = search_results.SearchResultsLayer(
    port: port,
    originX: bounds.left,
    originY: bounds.top,
    modalWidth: bounds.width,
    rows: _searchRows(state),
    scroll: 0,
    lane: 0,
    ink: const search_results.SearchColor(0.92, 0.92, 0.92, 1),
    dark: state.dark,
    localMusic: false,
    emptyMessage: '未找到相关结果',
    query: state.keyword,
  );
  layer.draw(port);
  wire.addAll(port.commands);
  hits.addAll(port.hits);

  append(search_chrome.buildSearchFooterLayout(
    stageWidth: state.width,
    status: '检索完成',
    loaded: 2,
    totalItems: 2,
    sourceLoading: false,
    hasMore: false,
    palette: palette,
    glyphWidth: metrics.width,
  ));

  return PageCommandStream.capture(page: SlicePage.search, wire: wire, hits: hits);
}

/// Queue modal command stream.
PageCommandStream queuePageCommands(SliceState state, {GlyphLoadResult? glyphs}) {
  final GlyphLoadResult atlas = glyphs ?? loadSpikeGlyphs();
  final QueueModalDrawing drawing = renderQueueModal(
    _queueState(state),
    _QueueGlyphs(_SpikeMetrics(atlas)),
  );
  return PageCommandStream.capture(page: SlicePage.queue, wire: drawing.commands, hits: drawing.hits);
}

/// All four page streams from one state snapshot.
Map<SlicePage, PageCommandStream> buildSlicePageStreams(SliceState state, {GlyphLoadResult? glyphs}) {
  final GlyphLoadResult atlas = glyphs ?? loadSpikeGlyphs();
  return <SlicePage, PageCommandStream>{
    SlicePage.archive: archivePageCommands(state, glyphs: atlas),
    SlicePage.detail: detailPageCommands(state, glyphs: atlas),
    SlicePage.search: searchPageCommands(state, glyphs: atlas),
    SlicePage.queue: queuePageCommands(state, glyphs: atlas),
  };
}

// Slice fixture -> production state objects

HudArchiveState _archiveState(SliceState state) => HudArchiveState(
      libraryName: 'SLICE',
      libraryIndex: state.libraryIndex,
      libraryTotal: state.libraryTotal,
      selectedLane: 0,
      laneCount: 5,
      sourceOrderIndex: 0,
      provider: 'netease',
      isLocal: true,
      isSiren: false,
      directory: false,
      directoryKind: null,
      uid: 'spike',
      restoringAccount: false,
      sourceLoading: false,
      trackListMode: state.trackListMode,
      current: ArchiveItem(
        id: 'slice-song-${state.libraryIndex}',
        title: '青花瓷',
        artist: '周杰伦',
        kind: 'song',
      ),
      libraryItemsEmpty: false,
      libraryItemsLength: state.libraryTotal,
      selectedPhysicalRow: state.selectedPhysicalRow,
      sourceMessage: null,
    );

SongDetailState _songDetailState(SliceState state) => SongDetailState(
      provider: 'netease',
      officialPlayback: true,
      item: SongDetailItem(
        id: 'slice-song-${state.libraryIndex}',
        kind: 'song',
        title: '青花瓷',
        artist: '周杰伦',
        artists: const <String>['周杰伦'],
        album: '我很忙',
        description: '',
        wiki: '',
        date: '2007-11-02',
        durationMs: 239000,
        provider: 'netease',
      ),
      dark: state.dark,
      uid: 'spike',
      providerName: '网易云',
      canMutateLike: true,
      player: const SongDetailPlayerState(actualQuality: '320k'),
    );

QueueModalState _queueState(SliceState state) => QueueModalState(
      bounds: state.queueBounds,
      tracks: const <QueueModalTrack>[
        QueueModalTrack(title: '青花瓷', artist: '周杰伦', duration: 239000),
        QueueModalTrack(title: '彩虹', artist: '周杰伦', duration: 263000),
      ],
      current: const QueueModalTrack(title: '青花瓷', artist: '周杰伦', duration: 239000),
      cover: '',
      mode: 'all',
      status: 'SLICE QUEUE',
      currentIndex: 0,
      offset: state.queueOffset,
      playing: true,
      dark: state.dark,
    );

List<search_results.SearchRow> _searchRows(SliceState state) => <search_results.SearchRow>[
      search_results.SearchRow(
        index: 0,
        value: <String, Object?>{
          'id': 'slice-song-${state.libraryIndex}',
          'title': '青花瓷',
          'artist': '周杰伦',
          'album': '我很忙',
          'kind': 'song',
        },
      ),
      search_results.SearchRow(
        index: 1,
        value: <String, Object?>{
          'id': 'slice-song-17',
          'title': '彩虹',
          'artist': '周杰伦',
          'album': '我很忙',
          'kind': 'song',
        },
      ),
    ];

// Injected ports (atlas-backed, no invented outlines)

/// Advance-only measurement over the atlas. A missing glyph contributes zero
/// advance and an empty fit; no width is invented for it.
final class _SpikeMetrics {
  const _SpikeMetrics(this.atlas);

  final GlyphLoadResult atlas;

  GlyphWeight? _table(String weight) => atlas.weights[weight] ?? atlas.weights['regular'];

  double width(String text, double size, String weight, [double tracking = 0]) {
    final GlyphWeight? table = _table(weight);
    double em = 0;
    int count = 0;
    for (final int rune in text.runes) {
      final GlyphEntry? glyph = table?.glyphs[String.fromCharCode(rune)];
      em += glyph?.advance ?? 0;
      count += 1;
    }
    return em * size + (count > 1 ? tracking * (count - 1) : 0);
  }

  String fit(String text, double size, double maxWidth, String weight) {
    if (maxWidth <= 0 || text.isEmpty) {
      return '';
    }
    if (width(text, size, weight) <= maxWidth) {
      return text;
    }
    const String ellipsis = '…';
    final double ellipsisWidth = width(ellipsis, size, weight);
    final StringBuffer buffer = StringBuffer();
    double used = 0;
    for (final int rune in text.runes) {
      final String character = String.fromCharCode(rune);
      final double advance = width(character, size, weight);
      if (used + advance + ellipsisWidth > maxWidth) {
        break;
      }
      buffer.write(character);
      used += advance;
    }
    return buffer.toString() + ellipsis;
  }
}

List<double> _searchColorWire(search_results.SearchColor color) =>
    List<double>.unmodifiable(<double>[color.r, color.g, color.b, color.a]);

List<double> _resultColorWire(search_results.SearchColor color) =>
    List<double>.unmodifiable(<double>[color.r, color.g, color.b, color.a]);

final class _WireSink implements HudSurfaceSink {
  _WireSink();

  final List<List<Object?>> commands = <List<Object?>>[];
  final List<Map<String, Object?>> hits = <Map<String, Object?>>[];

  @override
  void op(HudWireCommand command) => commands.add(List<Object?>.unmodifiable(command));

  @override
  void hit(HudHit hit) => hits.add(hit.toJson());
}

final class _ArchiveTextPort implements HudTextPort {
  const _ArchiveTextPort(this.sink, this.metrics, {required this.dark});

  final _WireSink sink;
  final _SpikeMetrics metrics;
  final bool dark;

  @override
  double glyphWidth(String value, double size, [String weight = 'regular']) =>
      metrics.width(value, size, weight);

  /// Glyphs::inset needs a side-bearing metric the atlas does not carry; the
  /// probe returns 0 instead of inventing one (residual risk, reported).
  @override
  double glyphInset(String value, double size, [String weight = 'regular']) => 0;

  @override
  String fit(String value, double size, double width, [String weight = 'regular']) =>
      metrics.fit(value, size, width, weight);

  @override
  void rolling(String key, String value, double x, double y, double size, String weight,
      double tracking, bool numeric) {
    // The rolling animation belongs to the host text port; the spike emits the
    // static text command at the port-provided anchor instead of animating.
    hudText(sink, value, x, y, size, weight: weight, tracking: tracking, dark: dark);
  }
}

final class _DetailGlyphs implements SongDetailGlyphsPort {
  const _DetailGlyphs(this.metrics);

  final _SpikeMetrics metrics;

  @override
  double width(String value, double size, String weight, [double tracking = 0]) =>
      metrics.width(value, size, weight, tracking);

  @override
  List<String> wrap(String value, double width, double size, String weight) {
    final List<String> lines = <String>[];
    final StringBuffer line = StringBuffer();
    double used = 0;
    for (final int rune in value.runes) {
      final String character = String.fromCharCode(rune);
      final double advance = metrics.width(character, size, weight);
      if (line.isNotEmpty && used + advance > width) {
        lines.add(line.toString());
        line.clear();
        used = 0;
      }
      line.write(character);
      used += advance;
    }
    if (line.isNotEmpty) {
      lines.add(line.toString());
    }
    return lines;
  }

  /// Same atlas limitation as [_ArchiveTextPort.glyphInset].
  @override
  double inset(String value, double size, String weight) => 0;
}

/// No cover/bitmap resolver: the spike never reads user artwork.
final class _NoImages implements SongDetailImagePort {
  const _NoImages();

  @override
  SongDetailImage? image(String key) => null;
}

final class _QueueGlyphs implements QueueModalGlyphs {
  const _QueueGlyphs(this.metrics);

  final _SpikeMetrics metrics;

  @override
  double width(String value, double size, String weight) => metrics.width(value, size, weight);
}

final class _SearchWirePort implements search_results.SearchResultsPort {
  _SearchWirePort(this.metrics);

  final _SpikeMetrics metrics;
  final List<List<Object?>> commands = <List<Object?>>[];
  final List<Map<String, Object?>> hits = <Map<String, Object?>>[];

  @override
  double glyphWidth(String text, double size, String weight) => metrics.width(text, size, weight);

  @override
  String fit(String text, double size, double maxWidth, String weight) =>
      metrics.fit(text, size, maxWidth, weight);

  @override
  void save() => commands.add(<Object?>['save']);

  @override
  void clip(Rect rect) => commands.add(<Object?>['clip', rect.left, rect.top, rect.width, rect.height]);

  @override
  void restore() => commands.add(<Object?>['restore']);

  @override
  void fill(Rect rect, search_results.SearchColor color) => commands.add(<Object?>[
        'fill',
        _resultColorWire(color),
        rect.left,
        rect.top,
        rect.width,
        rect.height,
      ]);

  @override
  void text(String text, double x, double y, double size, String weight, double letterSpacing,
      search_results.SearchColor color) {
    commands.add(<Object?>[
      'text',
      text,
      x,
      y,
      size,
      weight,
      letterSpacing,
      _resultColorWire(color),
    ]);
  }

  @override
  void hit(double x, double y, double width, double height, String action, String label) {
    hits.add(<String, Object?>{
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'action': action,
      'label': label,
    });
  }
}
