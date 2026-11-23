/// 竖屏（compact）「歌手」页：页头 + 艺人卡 + 曲目/发行专辑两栏。
///
/// 真源：
///  - `Qt/src/MusicDirectory.cpp:242-272` `openSongArtist(index)`：`↗ 歌手作品`
///    进入的是**歌手目录**（`kind == "artist"`），不是把检索切到 song 分类。
///  - `Qt/src/MusicDirectory.cpp:141-150` + `:452-469`：歌手目录由 `detail` 的
///    `[item, songs, ids]` 填充，随后 `showDirectoryInfo()` 把模式切到 detail，
///    状态串是「已打开：<歌手>」。
///  - `Qt/src/NativeHudDetail.cpp` 容器：`albums = kind == "artist" &&
///    artistTab == "albums"`，标签 `歌曲 / 发行专辑`（动作
///    `music:artist-tab:songs|albums`），专辑行动作 `music:artist-album:<rawIndex>`，
///    曲目行动作 `music:track:<rawIndex>`。
///  - 本仓库既有词表把「列表行」统一成 `music:index:<i>`（见
///    `lib/basic/basic_app.dart:139` 的 `basicMusicIndexActionPrefix`），所以曲目行
///    沿用 `music:index:<i>`，专辑行保留 Qt 的 `music:artist-album:<i>`。
///
/// 393 网格：页宽一律读 `c.gridWidth`，不写死 393；本文件只排版，不持有状态、
/// 不发请求，横向复用同一份命令流（`basic_hud.dart` 的
/// `_paintPortraitPageInLandscape` 会重采样这份网格）。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../scale/portrait_rhythm.dart';
import 'portrait_canvas.dart';

/// 歌手页一行（曲目行与专辑行同形：标题、副标题、行末戳、动作串）。
typedef PortraitArtistRow = ({
  String title,
  String artist,
  String stamp,
  String action,
});

/// 行距（`ResponsiveHudCanvas::row` 的 68 网格单位）。
const double portraitArtistRowStride = 68;

/// 「曲目」标签的动作串（Qt `music:artist-tab:songs`）。
const String portraitArtistTabSongsAction = 'music:artist-tab:songs';

/// 「发行专辑」标签的动作串（Qt `music:artist-tab:albums`）。
const String portraitArtistTabAlbumsAction = 'music:artist-tab:albums';

/// 标签 `songs` / `albums`（Qt `MusicDirectory::artistTab`）。
const String portraitArtistTabSongs = 'songs';
const String portraitArtistTabAlbums = 'albums';

/// 专辑行动作：`music:artist-album:<rawIndex>`（Qt `NativeHudDetail.cpp` 原文）。
String portraitArtistAlbumAction(int index) => 'music:artist-album:$index';

/// 曲目行动作：`music:index:<rawIndex>`（本仓库既有列表词表）。
String portraitArtistTrackAction(int index) => 'music:index:$index';

/// 左右页边距（Qt 全站 20 / 373）。
const double _gutter = 20;

/// 艺人卡正方形边长（设计稿 120，短屏按 .3 页高收）。
double _coverSide(PortraitCanvas c) =>
    math.max(88, math.min(120, c.height * .3));

/// 画歌手页。返回前必须调用 `c.finish()`。
///
/// [tab] 决定列表内容：`songs` 画曲目行，其它值画专辑行（Qt 只认 `albums`）。
/// [status] 是控制器状态串（空串不画）；[loading] 且列表为空时用「正在打开…」
/// 代替空态标题，避免首帧闪「暂无」。
void paintPortraitArtistPage(
  PortraitCanvas c, {
  /// 歌手名（页头标题）。
  required String artist,

  /// 歌手封面（插件/曲库的 cover key；空串画空槽，不编假图）。
  required String cover,

  /// 当前标签：`songs` / `albums`。
  required String tab,

  /// 曲目行（`music:index:<i>`）。
  required List<PortraitArtistRow> tracks,

  /// 发行专辑行（`music:artist-album:<i>`）。
  required List<PortraitArtistRow> albums,

  /// 控制器状态串（Qt `MusicLibrary::status`）。
  required String status,

  /// 正在打开歌手页。
  required bool loading,

  /// 当前曲目在 [tracks] 里的下标（越界 = 不画高亮）。
  int selectedIndex = -1,

  /// 返回动作串。
  String backAction = 'back',

  /// 列表滚动量（网格单位）。曲目列可能有几十首，矮屏上一屏放不下就必须能滚。
  double scroll = 0,
}) {
  final double width = c.gridWidth - 2 * _gutter;
  final double height = c.height;

  // 整页纸色：歌手页是资料库内页，不能把身后的 3D 唱片透出来。
  c.fill(Rect.fromLTWH(0, 0, c.gridWidth, math.max(0, height)), c.paper);
  c.header(artist, back: true, backAction: backAction);

  // 艺人卡：左侧正方形封面 + 右侧档案信息。
  final double side = _coverSide(c);
  final Rect card = Rect.fromLTWH(_gutter, 128, side, side);
  c.fill(card, c.surface);
  if (cover.isNotEmpty) {
    c.image(cover, card);
  }
  c.border(card, c.line);

  final double right = card.right + 14;
  final double rightWidth = c.gridWidth - _gutter - right;
  double y = card.top + 4;
  c.text(
    'ARTIST ARCHIVE / ${tracks.length} TRACKS',
    right,
    y,
    size: 8,
    width: rightWidth,
    color: c.muted,
  );
  y += 16;
  y = c.paragraph(
    artist,
    right,
    y,
    size: 20,
    width: rightWidth,
    weight: 'demibold',
    maximumLines: 2,
    lineSpacing: 1.15,
  );
  y += 6;
  final String meta = albums.isEmpty
      ? '${tracks.length} 首曲目'
      : '${tracks.length} 首曲目 · ${albums.length} 张专辑';
  c.text(meta, right, y, size: 10, width: rightWidth, color: c.muted);
  y += 18;
  if (status.isNotEmpty) {
    c.paragraph(
      status,
      right,
      y,
      size: 9,
      width: rightWidth,
      color: c.muted,
      maximumLines: 2,
      lineSpacing: 1.25,
    );
  }

  // 两个 44 高标签（Qt 的 artist tabs）：按页宽折半，不写死 393。
  // 标签行位置：设计稿 264 是「封面下沿 248 → 标签 264」的推进量，
  // 矮屏按节奏收（[PortraitRhythm.below]），但绝不压到封面里。
  double tabY = math.max(
    card.bottom + PortraitRhythm.gap(16, height),
    PortraitRhythm.below(card.bottom, 264, height),
  );
  final double tabWidth = (width - 9) / 2;
  c.chip(
    Rect.fromLTWH(_gutter, tabY, tabWidth, 44),
    '曲目',
    portraitArtistTabSongsAction,
    selected: tab != portraitArtistTabAlbums,
  );
  c.chip(
    Rect.fromLTWH(_gutter + tabWidth + 9, tabY, tabWidth, 44),
    '发行专辑',
    portraitArtistTabAlbumsAction,
    selected: tab == portraitArtistTabAlbums,
  );
  tabY += PortraitRhythm.gap(60, height);

  final List<PortraitArtistRow> rows =
      tab == portraitArtistTabAlbums ? albums : tracks;
  c.section(
    tabY,
    tab == portraitArtistTabAlbums ? '发行专辑' : '曲目',
    'INDEX / ${rows.length}',
  );
  final double listTop = tabY + PortraitRhythm.gap(30, height);
  final double bottom = math.max(listTop + 24, c.contentBottom);
  if (bottom - listTop < 24 || listTop >= height) {
    c.finish();
    return;
  }

  c.contentBottom = bottom;
  // 行窗口 + 滚动：曲目列常有三五十首，不能只画一屏就算完（用户报的「挤压」
  // 在矮屏上就是这条——内容被裁掉且拖不动）。
  final double maximumScroll = math.max(
    0,
    rows.length * portraitArtistRowStride - math.max(0, bottom - listTop),
  );
  final double offset = scroll.clamp(0.0, maximumScroll);
  final double cursor = listTop - offset;
  c.beginContent(listTop);
  if (rows.isEmpty) {
    c.text(
      loading ? '正在打开…' : (tab == portraitArtistTabAlbums ? '暂无发行专辑' : '暂无曲目'),
      _gutter,
      listTop + 8,
      size: 15,
      width: width,
      weight: 'demibold',
    );
    if (status.isNotEmpty) {
      c.paragraph(
        status,
        _gutter,
        listTop + 34,
        size: 10,
        width: width,
        color: c.muted,
        maximumLines: 2,
      );
    }
  } else {
    final (int first, int last) =
        c.visibleRows(cursor, portraitArtistRowStride, rows.length);
    for (int index = first; index < last; index++) {
      final PortraitArtistRow row = rows[index];
      c.row(
        cursor + index * portraitArtistRowStride,
        title: row.title,
        artist: row.artist,
        stamp: row.stamp,
        action: row.action,
        current: tab != portraitArtistTabAlbums && index == selectedIndex,
      );
    }
  }
  c.endContent();
  c.finish();
}
