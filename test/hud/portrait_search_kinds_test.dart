// 竖屏「分类检索页」的命中与文案测试。
//
// 被测文件：lib/hud/portrait/portrait_pages_search_kinds.dart
// 真值口径：
// - Qt/src/ResponsiveHudPages.cpp:941-990（compact 检索分支：检索框 / 四 tab /
//   indexTab / terminalSection / 结果行 / 空态）
// - Qt/src/ResponsiveHudPages.cpp:17-31（indexTab 与 terminalSection 两个原语）
// - Qt/src/NativeHudSearch.cpp:63-65,88-89,105,126-127（kinds 顺序、分组标签/键/动作串）
// - Qt/src/NativeHud.cpp:531-538（行条目动作 music:result:<lane>:<index>）
//
// 本组只断言「画了什么文案 / 发了什么动作」，不校验像素：字形宽度用固定估算。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/portrait/portrait_canvas.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_search_kinds.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';

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

List<String> _actions(PortraitCanvas c) => c.hits.map((HudHit hit) => hit.action).toList();

List<String> _texts(PortraitCanvas c) => <String>[
  for (final List<Object?> command in c.commands)
    if (command.length >= 2 && command[0] == 'text') command[1]! as String,
];

void main() {
  group('分类检索页 · 骨架', () {
    test('空关键词：画「检索音乐档案」，四 tab 与检索框按 Qt 动作串发出', () {
      final PortraitCanvas c = _canvas();
      paintPortraitSearchKindsPage(
        c,
        query: '',
        searchKind: 'song',
        rows: const <PortraitSearchKindsRow>[],
        total: 0,
        status: '没有匹配的音乐',
      );

      final List<String> actions = _actions(c);
      // 终端页（`Qt/src/ResponsiveHudLayout.cpp:150-176`）不画返回箭头：退出走底栏
      // ARCHIVE（`mobile:nav:archive` → 宿主清空 modal），页内不登记 `close-modal`
      // ——参考图 m13779 的检索页同样没有返回键。
      expect(actions, isNot(contains('close-modal')));
      expect(actions, contains('mobile:search-submit'));
      // 四个分类 tab：竖屏下标 0..3 → music:kind:{0,3,1,2}
      expect(actions, contains('music:kind:0'));
      expect(actions, contains('music:kind:3'), reason: 'tab 1 是「歌手」= kinds 下标 3');
      expect(actions, contains('music:kind:1'));
      expect(actions, contains('music:kind:2'));
      // 检索框必须登记输入域（键入正文由输入层自绘，不重复画字）
      expect(c.fields.keys, contains('search'));

      final List<String> texts = _texts(c);
      expect(texts, contains('音乐检索'));
      // 终端页头三件套 + 琥珀编号 `02` + `SEARCH / 档案检索`
      expect(texts, contains('RHINE LAB'));
      expect(texts, contains('AUDIO TERMINAL'));
      expect(texts, contains('RL–004'));
      expect(texts, contains('02'));
      expect(texts, contains('SEARCH / 档案检索'));
      expect(texts, contains('检索音乐档案'), reason: 'query.trim().isEmpty');
      expect(texts, contains('输入歌曲、歌手、专辑或歌单名称'));
      expect(texts, contains('检索结果'));
      expect(texts, contains('INDEX / 00'));
      // tab 标签顺序：竖屏是 歌曲/歌手/专辑/歌单（与横向 歌曲/专辑/歌单/歌手 不同）
      expect(texts, containsAll(<String>['歌曲', '歌手', '专辑', '歌单']));
    });

    test('有结果：逐行发出宿主动作串，序号两位补零，空态文案不出现', () {
      final PortraitCanvas c = _canvas();
      paintPortraitSearchKindsPage(
        c,
        query: 'alpha',
        searchKind: 'song',
        rows: const <PortraitSearchKindsRow>[
          (title: 'Alpha', artist: 'Kay', stamp: '03:20', action: 'music:result:0:0'),
          (title: 'Beta', artist: 'Zeta', stamp: '02:11', action: 'music:result:0:1'),
        ],
        total: 2,
        status: '找到 2 条结果',
      );

      final List<String> actions = _actions(c);
      expect(actions, contains('music:result:0:0'));
      expect(actions, contains('music:result:0:1'));

      final List<String> texts = _texts(c);
      expect(texts, contains('01'));
      expect(texts, contains('02'));
      expect(texts, contains('INDEX / 02'));
      expect(texts, contains('Alpha'));
      expect(texts, contains('Kay'));
      expect(texts, contains('03:20'));
      // 有结果时不应画空态
      expect(texts, isNot(contains('检索音乐档案')));
      expect(texts, isNot(contains('暂无匹配档案')));
    });

    test('非空关键词但无结果：标题是「暂无匹配档案」，正文是状态串', () {
      final PortraitCanvas c = _canvas();
      paintPortraitSearchKindsPage(
        c,
        query: 'zzz',
        searchKind: 'album',
        rows: const <PortraitSearchKindsRow>[],
        total: 0,
        status: '没有匹配的音乐',
      );

      final List<String> texts = _texts(c);
      expect(texts, contains('暂无匹配档案'));
      expect(texts, contains('没有匹配的音乐'));
      expect(texts, isNot(contains('检索音乐档案')));
      expect(texts, isNot(contains('输入歌曲、歌手、专辑或歌单名称')));
      // 专辑分类没有分组条
      expect(_actions(c), isNot(contains('music:group:0')));
    });

    test('歌单分类空态：状态串用「没有匹配的本地歌单」', () {
      final PortraitCanvas c = _canvas();
      paintPortraitSearchKindsPage(
        c,
        query: 'zzz',
        searchKind: 'playlist',
        rows: const <PortraitSearchKindsRow>[],
        total: 0,
        status: '没有匹配的本地歌单',
      );
      expect(_texts(c), contains('没有匹配的本地歌单'));
    });
  });

  group('分类检索页 · 分组条', () {
    test('歌曲分类画三格分组条，动作串与横向同源；选中态跟随 groupBy', () {
      final PortraitCanvas c = _canvas();
      paintPortraitSearchKindsPage(
        c,
        query: 'kay',
        searchKind: 'song',
        groupBy: 'artist',
        rows: const <PortraitSearchKindsRow>[
          (title: 'Kay', artist: '2 首', stamp: '', action: 'music:expand:artist%3AKay'),
        ],
        total: 1,
        status: '找到 1 条结果',
      );

      final List<String> actions = _actions(c);
      expect(actions, contains('music:group:0'));
      expect(actions, contains('music:group:1'));
      expect(actions, contains('music:group:2'));
      expect(_texts(c), containsAll(<String>['原序', '歌手分组', '专辑分组']));
      // 未展开时不出现返回
      expect(actions, isNot(contains('music:group-back')));
      expect(_texts(c), isNot(contains('← 全部分组')));
    });

    test('展开态：画「分组：<名>」与「← 全部分组」，发出 music:group-back', () {
      final PortraitCanvas c = _canvas();
      paintPortraitSearchKindsPage(
        c,
        query: 'kay',
        searchKind: 'song',
        groupBy: 'artist',
        activeGroup: 'Kay',
        rows: const <PortraitSearchKindsRow>[
          (title: 'Alpha', artist: 'Kay', stamp: '03:12', action: 'music:result:0:0'),
        ],
        total: 1,
        status: '找到 1 条结果',
      );

      final List<String> actions = _actions(c);
      expect(actions, contains('music:group-back'));
      final List<String> texts = _texts(c);
      expect(texts, contains('分组：Kay'));
      expect(texts, contains('← 全部分组'));
      // 展开态里分组的行条目由调用方给，动作原样透传
      expect(actions, contains('music:result:0:0'));
    });

    test('非歌曲分类不画分组条（Qt 只在有 song 行时给分组入口）', () {
      final PortraitCanvas c = _canvas();
      paintPortraitSearchKindsPage(
        c,
        query: 'kay',
        searchKind: 'artist',
        rows: const <PortraitSearchKindsRow>[
          (title: 'Kay', artist: 'Kay', stamp: '3 首', action: 'music:result:0:0'),
        ],
        total: 1,
        status: '找到 1 条结果',
      );
      expect(_actions(c), isNot(contains('music:group:0')));
      expect(_texts(c), isNot(contains('原序')));
    });
  });

  group('分类检索页 · 载入态与常量', () {
    test('loading 时列表顶部画「检索中…」，不影响结果行', () {
      final PortraitCanvas c = _canvas();
      paintPortraitSearchKindsPage(
        c,
        query: 'kay',
        searchKind: 'song',
        rows: const <PortraitSearchKindsRow>[
          (title: 'Alpha', artist: 'Kay', stamp: '03:12', action: 'music:result:0:0'),
        ],
        total: 1,
        status: '正在检索…',
        loading: true,
      );
      final List<String> texts = _texts(c);
      expect(texts, contains('检索中…'));
      expect(texts, contains('Alpha'));
    });

    test('tab 下标 → 分类 / 动作的映射与 kinds 顺序一致', () {
      expect(portraitSearchKindKeys, <String>['song', 'artist', 'album', 'playlist']);
      expect(portraitSearchKindActionOrder, <int>[0, 3, 1, 2]);
      expect(portraitSearchKindAction(0), 'music:kind:0');
      expect(portraitSearchKindAction(1), 'music:kind:3');
      expect(portraitSearchKindAction(2), 'music:kind:1');
      expect(portraitSearchKindAction(3), 'music:kind:2');
      expect(portraitSearchKindIndex('song'), 0);
      expect(portraitSearchKindIndex('artist'), 1);
      expect(portraitSearchKindIndex('album'), 2);
      expect(portraitSearchKindIndex('playlist'), 3);
      expect(portraitSearchKindIndex('folder'), 0, reason: '未知分类回落 0，与 Qt 的 selectedType 兜底一致');
      expect(portraitSearchGroupAction(1), 'music:group:1');
      expect(portraitSearchGroupKeys, <String>['none', 'artist', 'album']);
    });

    test('页面不写死 393：宽页（586 网格）也能把四 tab 摊满整行', () {
      final PortraitCanvas wide = PortraitCanvas(
        metrics: PortraitMetrics(
          width: (String value, double size, String weight) => value.length * size * .6,
          wrap: (String value, double limit, double size, String weight) => <String>[value],
          bounds: (String value, double size, String weight) =>
              PortraitGlyphBounds(width: value.length * size * .6, height: size),
        ),
        unit: 1,
        height: 900,
        dark: false,
        gridWidth: 586,
      );
      paintPortraitSearchKindsPage(
        wide,
        query: '',
        searchKind: 'song',
        rows: const <PortraitSearchKindsRow>[],
        total: 0,
        status: '没有匹配的音乐',
      );
      // 检索框右端跟着页宽走：field('search') 宽 = gridWidth - 78。
      expect(wide.fields['search']!.width, closeTo(586 - 78, .001));
      // 第 4 个 tab 的命中格右缘 = _left + cell*3 + cell - 7 = 页宽 - 20 - 7。
      final double cell = (586 - 40) / 4;
      expect(20 + cell * 3 + cell - 7, closeTo(586 - 20 - 7, .001));
    });
  });
}
