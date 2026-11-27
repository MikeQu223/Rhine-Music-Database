import '../hud/portrait/portrait_pages_album_info.dart';
import '../hud/portrait/portrait_pages_artist.dart';

/// 「辅助页面」的数据包：歌手页 / 歌曲百科 / 专辑信息。
///
/// 这三页的数据真值都在 [BasicController]（插件平台要等网络回执），
/// 而 [BasicViewState] 是一帧一投影的不可变快照、不承载这三页的临时态。
/// 宿主在 `_surface` 里从 controller 取一次、装箱传给 HUD，HUD 只负责画。
///
/// 三个字段都可为 null：null = 该页当前不该出现（不是「空页面」）。
class BasicAuxPages {
  const BasicAuxPages({this.artist, this.wiki, this.albumInfo});

  /// 歌手页（目录 `kind == 'artist'` 时存在）。
  final BasicArtistPageModel? artist;

  /// 歌曲百科页（`modal == 'wiki'` 时存在）。
  final BasicWikiPageModel? wiki;

  /// 专辑信息页（`modal == 'album-info'` 时存在）。
  final BasicAlbumInfoPageModel? albumInfo;
}

/// 歌手页的真值：曲目/专辑两个 tab 共用一份标题与状态串。
class BasicArtistPageModel {
  const BasicArtistPageModel({
    required this.name,
    required this.cover,
    required this.tab,
    required this.tracks,
    required this.albums,
    required this.status,
    required this.loading,
    this.selectedIndex = -1,
  });

  final String name;
  final String cover;

  /// `songs` / `albums`（见 [portraitArtistTabSongs]）。
  final String tab;
  final List<PortraitArtistRow> tracks;
  final List<PortraitArtistRow> albums;
  final String status;
  final bool loading;
  final int selectedIndex;
}

/// 歌曲百科页的真值（正文已按行切好）。
class BasicWikiPageModel {
  const BasicWikiPageModel({
    required this.title,
    required this.artist,
    required this.cover,
    required this.lines,
    required this.status,
    required this.loading,
  });

  final String title;
  final String artist;
  final String cover;
  final List<String> lines;
  final String status;
  final bool loading;
}

/// 专辑信息页的真值（同专辑曲目行的动作串由本模型一起给）。
class BasicAlbumInfoPageModel {
  const BasicAlbumInfoPageModel({
    required this.title,
    required this.artist,
    required this.cover,
    required this.date,
    required this.description,
    required this.trackCount,
    required this.songs,
    required this.status,
    required this.loading,
    this.selectedIndex = -1,
  });

  final String title;
  final String artist;
  final String cover;
  final String date;
  final String description;
  final int trackCount;
  final List<PortraitAlbumInfoRow> songs;
  final String status;
  final bool loading;
  final int selectedIndex;
}
