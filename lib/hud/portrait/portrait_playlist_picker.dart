/// 竖屏「加入歌单」选择器（Qt compact `playlist-picker`）。
///
/// Qt 真值：`Qt/src/NativeHudMusic.cpp:483-486` 的 `music:add-to-playlist`
/// 只做两件事 —— `openModal("playlist-picker")`，歌单列表为空时再
/// `music.loadMoreSource(2)`。选择器本体在 `Qt/src/NativeHudModal.cpp`
/// 的通用列表分支（`playlists` + `music:playlist-pick:<id>`），393 网格下
/// 没有独立版式；这里按同一份网格拟一页：页头 + 歌单行 + 空态/新建入口。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'portrait_canvas.dart';

/// 「加入歌单」选择器的固定动作串（Qt `NativeHudMusic.cpp:487`）。
const String portraitPlaylistPickPrefix = 'music:playlist-pick:';

/// 选择器页头标题。
const String portraitPlaylistPickerTitle = '加入歌单';

/// 行高与 Qt 的列表行一致（`ResultRowHeight = 68`）。
const double portraitPlaylistPickerRowStride = 68;

/// 选择器的内容起点：终端页头之下（与其它 modal 页相同的 158）。
const double portraitPlaylistPickerContentTop = 158;

/// 画一页「加入歌单」选择器。
///
/// [playlists] 是 `(歌单 id, 歌单名, 曲目数)` 三元组；[notice] 非空时画在
/// 页头下的一行（承接「这首歌已在当前歌单」这类回话）；[canCreate] 为真时
/// 底部给「＋ 创建歌单」入口（Qt 在 `canCreatePlaylist` 时才给）。
void paintPortraitPlaylistPicker(
  PortraitCanvas c, {
required List<(String, String, int)> playlists,
  required String notice,
  required bool canCreate,
}) {
  final double w = c.gridWidth;
  c.fill(Rect.fromLTWH(0, 0, w, c.height), c.paper);
  c.text('ADD TO PLAYLIST', 20, 40, size: 8, width: w - 40, color: c.muted);
  c.text(portraitPlaylistPickerTitle, 20, 62, size: 23, width: w - 60, weight: 'demibold');
  c.icon('close', w - 41, 58, size: 18, color: c.ink);
  c.hit(Rect.fromLTWH(w - 52, 46, 44, 44), 'close-modal', '关闭');
  c.fill(Rect.fromLTWH(20, 92, w - 40, .6), c.line);
  if (notice.isNotEmpty) {
    c.text(notice, 20, 104, size: 10, width: w - 40, color: c.muted);
  }
  double y = portraitPlaylistPickerContentTop;
  if (playlists.isEmpty) {
    c.text('还没有本地歌单', 20, y + 8, size: 16, width: w - 40, weight: 'demibold');
    c.paragraph('先创建一个歌单，之后可以把曲目加进去。', 20, y + 40, size: 11, width: w - 40,
        color: c.muted);
  } else {
    c.section(y, '本机歌单  ${playlists.length}', 'LOCAL PLAYLISTS');
    y += 29;
    final int visible = math.max(0, ((c.contentBottom - y) / portraitPlaylistPickerRowStride).floor());
    for (int i = 0; i < visible && i < playlists.length; i += 1) {
      final (String id, String title, int trackCount) row = playlists[i];
      c.row(
        y + i * portraitPlaylistPickerRowStride,
        title: row.$2,
        artist: '本地歌单 · ${row.$3} 首',
        stamp: '${row.$3} 首',
        action: '$portraitPlaylistPickPrefix${row.$1}',
        number: (i + 1).toString().padLeft(2, '0'),
      );
    }
  }
  if (canCreate) {
    final double buttonY = math.min(c.contentBottom - 52, y + 60);
    c.button(Rect.fromLTWH(20, buttonY, w - 40, 44), '＋ 创建歌单', 'music:create-playlist');
  }
  c.finish();
}
