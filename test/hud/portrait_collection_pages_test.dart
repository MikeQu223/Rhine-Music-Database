// 竖屏「喜欢的歌曲」/「我的歌单」两个绘制器的命中与文案测试。
//
// 这两个 painter 只往 PortraitCanvas 写命令与热区，不建 widget，所以测试就是
// 「构造一张画布 → 画 → 断言命令/热区」。真值口径：
// - Qt/src/ResponsiveHudPages.cpp:896-915（lane 1 整页几何与两个按钮）
// - Qt/src/ResponsiveHudLayout.cpp:181-189（saved 页返回命中改写成 mobile:mine）
// - Qt/src/NativeHud.cpp:533-538（saved 页行动作 music:result:<lane>:<index>）
// - Qt/src/MusicSiren.cpp:251-335（lane 2 空态文案）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/portrait/portrait_canvas.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_collection_likes.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_collection_playlists.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';

/// 宽度按字符数估算：本组只关心「画了什么 / 发了什么动作」，不校验像素。
PortraitCanvas _canvas() => PortraitCanvas(
  metrics: PortraitMetrics(
    width: (String value, double size, String weight) => value.length * size * .6,
    wrap: (String value, double limit, double size, String weight) => <String>[value],
    bounds: (String value, double size, String weight) =>
        PortraitGlyphBounds(width: value.length * size * .6, height: size),
  ),
  unit: 1,
  height: 700,
  dark: true,
);

List<String> _actions(PortraitCanvas c) =>
    c.hits.map((HudHit hit) => hit.action).toList();

List<String> _texts(PortraitCanvas c) => <String>[
  for (final List<Object?> command in c.commands)
    if (command.length >= 2 && command[0] == 'text') command[1]! as String,
];

void main() {
  group('喜欢的歌曲页', () {
    test('列表态：页头/计数/两个按钮/逐行命中都按 Qt 动作串发出', () {
      final PortraitCanvas c = _canvas();
      paintPortraitLikesPage(
        c,
        rows: const <PortraitLikesRow>[
          ('第一首', '塞壬唱片', '03:12'),
          ('第二首', '塞壬唱片', '04:01'),
          ('第三首', '其他艺人', ''),
        ],
        selectedIndex: 1,
        loading: false,
        notice: '已读取喜欢的歌曲',
      );

      final List<String> actions = _actions(c);
      expect(actions, contains('mobile:mine'), reason: '返回命中改写成 mobile:mine');
      expect(actions, contains('mobile:play-liked'));
      expect(actions, contains('player:open'));
      for (int index = 0; index < 3; index++) {
        expect(actions, contains('music:result:1:$index'));
      }
      expect(actions.where((String a) => a.startsWith('music:result:1:')).length, 3);

      final List<String> texts = _texts(c);
      expect(texts, contains('喜欢的歌曲'));
      expect(texts, contains('PERSONAL ARCHIVE / 3 TRACKS'));
      expect(texts, contains('COLLECTION / 收藏资料库'));
      expect(texts, contains('▶ 播放全部'));
      expect(texts, contains('查看队列'));
      expect(texts, contains('第一首'));
      expect(texts, contains('03:12'));
      // 序号两位补零（Qt MusicData::pad）。
      expect(texts, contains('01'));
      expect(texts, contains('03'));
    });

    test('空态与载入态：不画假行，只给 Qt 的空态文案 + notice', () {
      final PortraitCanvas c = _canvas();
      paintPortraitLikesPage(
        c,
        rows: const <PortraitLikesRow>[],
        selectedIndex: -1,
        loading: false,
        notice: '暂无喜欢的歌曲',
      );
      expect(_actions(c).any((String a) => a.startsWith('music:result:1:')), isFalse);
      final List<String> texts = _texts(c);
      expect(texts, contains('暂无喜欢的歌曲'));
      expect(texts, contains('PERSONAL ARCHIVE / 0 TRACKS'));

      final PortraitCanvas loading = _canvas();
      paintPortraitLikesPage(
        loading,
        rows: const <PortraitLikesRow>[],
        selectedIndex: -1,
        loading: true,
        notice: '',
      );
      expect(_texts(loading), contains('正在读取…'));
    });
  });

  group('我的歌单页', () {
    test('列表态：行标题/计数/副标题与 music:result:2:<i> 命中齐全', () {
      final PortraitCanvas c = _canvas();
      paintPortraitPlaylistsPage(
        c,
        rows: const <PortraitPlaylistRow>[
          PortraitPlaylistRow(id: 'p1', title: '清晨', trackCount: 3),
          PortraitPlaylistRow(id: 'p2', title: '深夜', trackCount: 12),
        ],
        selectedIndex: 0,
        loading: false,
        notice: '已读取本地歌单',
        canCreate: true,
      );

      final List<String> actions = _actions(c);
      expect(actions, contains('mobile:mine'));
      expect(actions, contains('music:result:2:0'));
      expect(actions, contains('music:result:2:1'));
      expect(actions, contains('music:create-playlist'));

      final List<String> texts = _texts(c);
      expect(texts, contains('我的歌单'));
      expect(texts, contains('INDEX / 02'));
      expect(texts, contains('清晨'));
      expect(texts, contains('深夜'));
      expect(texts, contains('3 首'));
      expect(texts, contains('12 首'));
      // Qt LocalCollections::playlistItem 的 description 原文。
      expect(texts, contains('本地歌单 · 仅保存在本机'));
      expect(texts, contains('+ 创建歌单'));
    });

    test('空态：默认不给创建入口，空歌单文案来自 MusicSiren 的空集提示', () {
      final PortraitCanvas c = _canvas();
      paintPortraitPlaylistsPage(
        c,
        rows: const <PortraitPlaylistRow>[],
        selectedIndex: -1,
        loading: false,
        notice: '暂无本地歌单，可点击创建歌单',
      );

      expect(_actions(c).any((String a) => a.startsWith('music:result:2:')), isFalse);
      expect(_actions(c), isNot(contains('music:create-playlist')));
      final List<String> texts = _texts(c);
      expect(texts, contains('暂无本地歌单'));
      expect(texts, contains('暂无本地歌单，可点击创建歌单'));
      expect(texts, contains('INDEX / 00'));
    });
  });
}
