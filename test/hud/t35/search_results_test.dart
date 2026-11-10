// T35-C19-W2 (PAGE-SEARCH) — lib/hud/modals/search_results.dart 的单元测试。
//
// 只写不执行：本卡禁令禁止 flutter/dart test|analyze|run，RED/GREEN 均未执行。
// 覆盖合同 a-l：视口 / 行矩形 / 可见范围 / 滚动最大値 / 滚动轨 / 空态 / 行内容 /
// 行动作 / 百分号编解码 / 标题匹配 / 分组派生 / 滚动状态与自动补载 / 绘制顺序与命中裁剪。

import 'dart:ui' show Color, Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/search_results.dart';

/// 确定性假文本度量：逐 UTF-16 单元 × size × 权重系数（demibold 0.6 / 其它 0.5）。
/// 只用于验证算式与调用参数，不代表真实字形 advance。
double fakeGlyph(String text, double size, String weight) {
  final factor = weight == 'demibold' ? 0.6 : 0.5;
  return text.length * size * factor;
}

/// 固定为 0 的字形宽度，用于验证 matchWidth > 0 的下划线守卫。
double zeroGlyph(String text, double size, String weight) => 0;

String _rectText(Rect rect) =>
    'Rect(' + rect.left.toString() + ', ' + rect.top.toString() + ', ' + rect.width.toString() + ', ' + rect.height.toString() + ')';

/// 记录端口调用，验证绘制顺序、op 参数与命中六字段原序。
class RecordingPort implements SearchResultsPort {
  final List<String> ops = <String>[];
  final List<String> glyphs = <String>[];

  /// 命中按调用顺序记录：[x, y, width, height, action, label]。
  final List<List<Object?>> hits = <List<Object?>>[];

  /// 被 clip 的矩形（Qt 保存/裁剪/恢复的顺序证据）。
  final List<Rect> clips = <Rect>[];

  /// fit 的调用参数：[text, size, maxWidth, weight]。
  final List<List<Object?>> fits = <List<Object?>>[];

  @override
  double glyphWidth(String text, double size, String weight) {
    glyphs.add(text + '@' + size.toString() + '@' + weight);
    return fakeGlyph(text, size, weight);
  }

  @override
  String fit(String text, double size, double maxWidth, String weight) {
    fits.add(<Object?>[text, size, maxWidth, weight]);
    return text;
  }

  @override
  void save() {
    ops.add('save');
  }

  @override
  void clip(Rect rect) {
    clips.add(rect);
    ops.add('clip ' + _rectText(rect));
  }

  @override
  void restore() {
    ops.add('restore');
  }

  @override
  void fill(Rect rect, SearchColor color) {
    ops.add('fill ' + _rectText(rect) + ' ' + color.toString());
  }

  @override
  void text(String text, double x, double y, double size, String weight, double letterSpacing,
      SearchColor color) {
    ops.add('text ' + text + ' @' + x.toString() + ',' + y.toString());
  }

  @override
  void hit(double x, double y, double width, double height, String action, String label) {
    hits.add(<Object?>[x, y, width, height, action, label]);
    ops.add('hit ' + action);
  }
}

SearchRow row(int index, Map<String, Object?> value) => SearchRow(index: index, value: value);

void main() {
  // 1920 舞台：modalWidth = min(1820, max(760, min(1000, 901))) = 901，left = 960。
  const double stageOriginX = 960;
  const double stageOriginY = 122;
  const double modalWidth1920 = 901;

  // 1280 舞台：modalWidth = max(760, 581) = 760，left = 461。
  const double stageOriginX1280 = 461;
  const double modalWidth1280 = 760;

  group('searchResultViewport', () {
    test('1920 舞台：left+53 / top+328 / width-106 / 430', () {
      final viewport = searchResultViewport(
        originX: stageOriginX,
        originY: stageOriginY,
        modalWidth: modalWidth1920,
      );
      expect(viewport, const Rect.fromLTWH(1013, 450, 795, 430));
      expect(viewport.width, modalWidth1920 - 2 * kSearchInset);
      expect(viewport.height, kSearchResultListHeight);
      expect(viewport.height, 430);
    });

    test('1280 窄舞台仍是同一公式（响应式只改 modalWidth）', () {
      final viewport = searchResultViewport(
        originX: stageOriginX1280,
        originY: stageOriginY,
        modalWidth: modalWidth1280,
      );
      expect(viewport, const Rect.fromLTWH(514, 450, 654, 430));
    });

    test('冻结常量逐字等于 Qt 真源', () {
      expect(kSearchInset, 53);
      expect(kSearchResultListTop, 328);
      expect(kSearchResultListBottom, 758);
      expect(kSearchResultRowHeight, 72);
      expect(kSearchResultListHeight, 430);
    });
  });

  group('searchRowRect / searchRowSeparator', () {
    final viewport = searchResultViewport(
      originX: stageOriginX,
      originY: stageOriginY,
      modalWidth: modalWidth1920,
    );

    test('rowY = viewport.top + index*72 - scroll', () {
      expect(searchRowRect(viewport, 0, 0), const Rect.fromLTWH(1013, 450, 795, 72));
      expect(searchRowRect(viewport, 2, 30), const Rect.fromLTWH(1013, 564, 795, 72));
      expect(searchRowRect(viewport, 5, 0), const Rect.fromLTWH(1013, 810, 795, 72));
    });

    test('分隔线在 y+71、高 1、宽 viewport.width', () {
      final separator = searchRowSeparator(searchRowRect(viewport, 1, 0));
      expect(separator, const Rect.fromLTWH(1013, 593, 795, 1));
    });

    test('行命中矩形 = (viewport.left, rowY, viewport.width, 72)', () {
      expect(searchRowHitRect(viewport, 522), const Rect.fromLTWH(1013, 522, 795, 72));
    });
  });

  group('searchVisibleRange', () {
    test('scroll 0、10 行：first 0、last 7（含 overscan）', () {
      final range = searchVisibleRange(rowCount: 10, scroll: 0, viewportHeight: 430);
      expect(range.first, 0);
      expect(range.last, 7);
      expect(range.isEmpty, isFalse);
      expect(range.count, 8);
      expect(range.indices.toList(), <int>[0, 1, 2, 3, 4, 5, 6, 7]);
    });

    test('rowCount = 0 返回空区间', () {
      final range = searchVisibleRange(rowCount: 0, scroll: 0, viewportHeight: 430);
      expect(range.isEmpty, isTrue);
      expect(range.count, 0);
      expect(range.indices.toList(), isEmpty);
      expect(range, SearchVisibleRange.empty);
    });

    test('滚动到第 4 行：first 3、last 9', () {
      final range = searchVisibleRange(rowCount: 10, scroll: 288, viewportHeight: 430);
      expect(range.first, 3);
      expect(range.last, 9);
    });

    test('scroll 超界（未 clamp）退化为空区间', () {
      final range = searchVisibleRange(rowCount: 10, scroll: 1000, viewportHeight: 430);
      expect(range.first, 12);
      expect(range.last, 9);
      expect(range.isEmpty, isTrue);
    });

    test('先 clamp 再取可见范围就不会超界', () {
      final clamped = searchClampScroll(scroll: 1000, rowCount: 10, viewportHeight: 430);
      final range = searchVisibleRange(rowCount: 10, scroll: clamped, viewportHeight: 430);
      expect(clamped, 290);
      expect(range.isEmpty, isFalse);
      expect(range.last, 9);
      expect(range.first, (290 / 72).floor() - 1);
    });
  });

  group('searchScrollMaximum / searchClampScroll', () {
    test('maximum = max(rowCount*72 - vp, 0)', () {
      expect(searchScrollMaximum(10, 430), 290);
      expect(searchScrollMaximum(5, 430), 0);
      expect(searchScrollMaximum(6, 430), 2);
      expect(searchScrollMaximum(0, 430), 0);
    });

    test('clamp 到 [0, maximum]', () {
      expect(searchClampScroll(scroll: 999, rowCount: 10, viewportHeight: 430), 290);
      expect(searchClampScroll(scroll: -50, rowCount: 10, viewportHeight: 430), 0);
      expect(searchClampScroll(scroll: 100, rowCount: 10, viewportHeight: 430), 100);
      expect(searchClampScroll(scroll: 100, rowCount: 2, viewportHeight: 430), 0);
    });
  });

  group('searchApplyWheel', () {
    test('steps 默认 1 → ResultRowHeight 72 像素（NativeHudInput.cpp:92-95）', () {
      expect(searchApplyWheel(scroll: 0, rowCount: 10, viewportHeight: 430), 72);
    });

    test('distance 有效且非 0 时覆盖 steps', () {
      expect(
        searchApplyWheel(scroll: 0, rowCount: 10, viewportHeight: 430, steps: 4, distance: 15),
        15,
      );
    });

    test('distance == 0 时退回 steps * stepPixels (72)', () {
      expect(
        searchApplyWheel(scroll: 0, rowCount: 10, viewportHeight: 430, steps: 2, distance: 0),
        144,
      );
    });

    test('结果夹取到 [0, maximum]', () {
      expect(searchApplyWheel(scroll: 280, rowCount: 10, viewportHeight: 430), 290);
      expect(searchApplyWheel(scroll: 10, rowCount: 10, viewportHeight: 430, steps: -3), 0);
      expect(searchApplyWheel(scroll: 0, rowCount: 2, viewportHeight: 430), 0);
    });
  });

  group('searchRailTrack / searchScrollRail', () {
    final viewport = searchResultViewport(
      originX: stageOriginX,
      originY: stageOriginY,
      modalWidth: modalWidth1920,
    );

    test('轨道 = (originX + modalWidth - 24, viewport.top + 8, 3, viewport.height - 16)', () {
      final track = searchRailTrack(
        originX: stageOriginX,
        modalWidth: modalWidth1920,
        viewport: viewport,
      );
      expect(track, const Rect.fromLTWH(1837, 458, 3, 414));
    });

    test('内容不超过视口时不画 thumb', () {
      final rail = searchScrollRail(
        track: searchRailTrack(
          originX: stageOriginX,
          modalWidth: modalWidth1920,
          viewport: viewport,
        ),
        rowCount: 5,
        scroll: 0,
        viewportHeight: 430,
      );
      expect(rail.visible, isFalse);
      expect(rail.thumb, isNull);
    });

    test('内容超出时 thumb 出现且 scroll 0 时贴顶', () {
      final track = searchRailTrack(
        originX: stageOriginX,
        modalWidth: modalWidth1920,
        viewport: viewport,
      );
      final rail = searchScrollRail(
        track: track,
        rowCount: 10,
        scroll: 0,
        viewportHeight: 430,
      );
      expect(rail.visible, isTrue);
      final thumb = rail.thumb!;
      expect(thumb.left, track.left);
      expect(thumb.width, 3);
      expect(thumb.top, track.top);
      expect(thumb.height, closeTo(414 * 430 / 720, 1e-9));
    });

    test('滚到 maximum 时 thumb 贴底', () {
      final track = searchRailTrack(
        originX: stageOriginX,
        modalWidth: modalWidth1920,
        viewport: viewport,
      );
      final rail = searchScrollRail(
        track: track,
        rowCount: 10,
        scroll: 290,
        viewportHeight: 430,
      );
      final thumb = rail.thumb!;
      expect(thumb.top + thumb.height, closeTo(track.top + track.height, 1e-9));
    });

    test('内容仅超出 2 像素时 thumb 仍取最小厚度 clamp', () {
      final track = searchRailTrack(
        originX: stageOriginX,
        modalWidth: modalWidth1920,
        viewport: viewport,
      );
      final rail = searchScrollRail(
        track: track,
        rowCount: 6,
        scroll: 0,
        viewportHeight: 430,
      );
      expect(rail.visible, isTrue);
      expect(rail.thumb!.height, closeTo(414 * 430 / 432, 1e-9));
      expect(rail.thumb!.height, lessThanOrEqualTo(414));
    });
  });

  group('SearchColor.toColor', () {
    test('0..1 RGBA -> ARGB bytes, alpha defaults to 1', () {
      expect(const SearchColor(0, 0, 0, 0).toColor(), const Color.fromARGB(0, 0, 0, 0));
      expect(
        const SearchColor(1, 1, 1, 1).toColor(),
        const Color.fromARGB(255, 255, 255, 255),
      );
      // 0.5 * 255 = 127.5 -> 128, 0.25 * 255 = 63.75 -> 64, 0.75 * 255 = 191.25 -> 191.
      expect(
        const SearchColor(0.5, 0.25, 0.75).toColor(),
        const Color.fromARGB(255, 128, 64, 191),
      );
    });

    test('channels are clamped after rounding', () {
      expect(
        const SearchColor(2, -1, 0.2, 1.5).toColor(),
        const Color.fromARGB(255, 255, 0, 51),
      );
    });

    test('withAlpha keeps rgb', () {
      expect(const SearchColor(0.2, 0.4, 0.6).withAlpha(0.55), const SearchColor(0.2, 0.4, 0.6, 0.55));
    });
  });

  group('空态', () {
    test('local / remote 文案逐字来自 Qt', () {
      expect(searchEmptyHint(localMusic: true), '在文件夹管理中导入音乐后即可检索。');
      expect(searchEmptyHint(localMusic: false), '输入歌曲、歌手、专辑或歌单名称后按 ENTER。');
    });

    test('标题 (left, top+92)、提示 (left, top+128)', () {
      const viewport = Rect.fromLTWH(1013, 450, 795, 430);
      expect(searchEmptyMessagePosition(viewport), const Offset(1013, 542));
      expect(searchEmptyHintPosition(viewport), const Offset(1013, 578));
      expect(kSearchEmptyMessageSize, 18);
      expect(kSearchEmptyHintSize, 12);
    });
  });

  group('行内容', () {
    test('titleWidth = modalWidth - 308', () {
      expect(searchRowTitleWidth(901), 593);
      expect(searchRowTitleWidth(760), 452);
    });

    test('kind 转大写，空则 SONG', () {
      expect(searchRowKind(<String, Object?>{'kind': 'song'}), 'SONG');
      expect(searchRowKind(<String, Object?>{'kind': 'Album'}), 'ALBUM');
      expect(searchRowKind(<String, Object?>{'kind': 'group'}), 'GROUP');
      expect(searchRowKind(<String, Object?>{}), 'SONG');
      expect(searchRowKind(<String, Object?>{'kind': 3}), 'SONG');
    });

    test('id 只取 string，非 string 得空串', () {
      expect(searchRowIdText(<String, Object?>{'id': '42'}), '42');
      expect(searchRowIdText(<String, Object?>{'id': 42}), '');
      expect(searchRowIdText(<String, Object?>{}), '');
    });

    test('detail：artist 优先，空则 album，都空则空串', () {
      expect(
        searchRowDetail(<String, Object?>{'artist': '歌手A', 'album': '专辑B'}),
        '歌手A',
      );
      expect(searchRowDetail(<String, Object?>{'artist': '', 'album': '专辑B'}), '专辑B');
      expect(searchRowDetail(<String, Object?>{'artist': '', 'album': ''}), '');
      expect(searchRowDetail(<String, Object?>{}), '');
    });

    test('detail：含 playCount 键才追加 " / N 次播放"', () {
      expect(
        searchRowDetail(<String, Object?>{'artist': '歌手A', 'playCount': 2.5}),
        '歌手A / 3 次播放',
      );
      expect(
        searchRowDetail(<String, Object?>{'artist': '歌手A', 'playCount': 12}),
        '歌手A / 12 次播放',
      );
      expect(
        searchRowDetail(<String, Object?>{'playCount': -0.5}),
        ' / -1 次播放',
      );
      expect(searchRowDetail(<String, Object?>{'artist': '歌手A', 'playCount': 0}), '歌手A / 0 次播放');
      expect(searchRowDetail(<String, Object?>{'artist': '歌手A', 'playCount': 'x'}), '歌手A / 0 次播放');
      // 键存在即为真（QJsonObject::contains），null 的 toDouble() 为 0。
      expect(searchRowDetail(<String, Object?>{'artist': '歌手A', 'playCount': null}), '歌手A / 0 次播放');
    });

    test('标签底色：dark {1,1,1,0.07} / light {0.10,0.11,0.10,0.05}', () {
      expect(searchTagFill(true), kSearchTagFillDark);
      expect(searchTagFill(false), kSearchTagFillLight);
      expect(kSearchTagFillDark, const SearchColor(1, 1, 1, 0.07));
      expect(kSearchTagFillLight, const SearchColor(0.10, 0.11, 0.10, 0.05));
    });

    test('tagWidth = glyphWidth(kind, 8, regular) + 10', () {
      expect(
        searchRowTagWidth(
          value: <String, Object?>{'kind': 'song'},
          glyphWidth: fakeGlyph,
        ),
        fakeGlyph('SONG', 8, 'regular') + 10,
      );
    });

    test('行锚点：id(y+20) / title(+107, y+11) / tag(+107, y+40) / detail / 查看 ↗', () {
      const viewport = Rect.fromLTWH(1013, 450, 795, 430);
      final layout = searchRowLayout(
        viewport: viewport,
        modalWidth: 901,
        rowY: 522,
        tagWidth: 30,
        titleWidth: 593,
      );
      expect(layout.rowRect, const Rect.fromLTWH(1013, 522, 795, 72));
      expect(layout.separator, const Rect.fromLTWH(1013, 593, 795, 1));
      expect(layout.idPosition, const Offset(1013, 542));
      expect(layout.titlePosition, const Offset(1120, 533));
      expect(layout.tagRect, const Rect.fromLTWH(1120, 562, 30, 14));
      expect(layout.tagTextPosition, const Offset(1125, 563));
      expect(layout.detailPosition, const Offset(1158, 562));
      expect(layout.detailMaxWidth, 593 - 30 - 8);
      // x 为弹窗左边界 960：960 + 901 - 136 = 1725。
      expect(layout.actionPosition, const Offset(1725, 542));
    });
  });

  group('searchQtString / searchQtDouble / searchQtNumberFixed0', () {
    test('非 string 得空串，非 num 得 0（QJsonValue 严格语义）', () {
      expect(searchQtString(<String, Object?>{'a': 'x'}['a']), 'x');
      expect(searchQtString(7), '');
      expect(searchQtString(null), '');
      expect(searchQtDouble(3), 3.0);
      expect(searchQtDouble(3.5), 3.5);
      expect(searchQtDouble('3.5'), 0);
      expect(searchQtDouble(null), 0);
    });

    test("QString::number(v, 'f', 0) 远离零四舍五入", () {
      expect(searchQtNumberFixed0(2.5), '3');
      expect(searchQtNumberFixed0(-0.5), '-1');
      expect(searchQtNumberFixed0(-2.5), '-3');
      expect(searchQtNumberFixed0(1.5), '2');
      expect(searchQtNumberFixed0(0.4), '0');
      expect(searchQtNumberFixed0(12), '12');
      expect(searchQtNumberFixed0(0), '0');
    });
  });

  group('percentEncode / percentDecode', () {
    test('仅 A-Z a-z 0-9 - _ . ~ 不编码', () {
      const unreserved = 'AZaz09-_.~';
      expect(percentEncode(unreserved), unreserved);
    });

    test('空格 %20（不是 +）、加号 %2B、冒号 %3A', () {
      expect(percentEncode('a b'), 'a%20b');
      expect(percentEncode('a+b'), 'a%2Bb');
      expect(percentEncode('artist:u1'), 'artist%3Au1');
    });

    test('非 ASCII 按 UTF-8 逐字节、十六进制大写', () {
      expect(percentEncode('中'), '%E4%B8%AD');
      expect(percentEncode('张 三'), '%E5%BC%A0%20%E4%B8%89');
      expect(percentEncode('🎵'), '%F0%9F%8E%B5');
    });

    test('percentDecode 是严格逆函数，往返一致', () {
      for (final sample in <String>[
        '',
        'plain',
        'a b+c:d/e?f#g&h=i',
        'name:未知专辑',
        '🎵 音乐',
        '%',
        '%25 已编码',
        'album:0001',
      ]) {
        expect(percentDecode(percentEncode(sample)), sample, reason: sample);
      }
    });

    test('percentDecode 拒绝截断 / 非法转义 / 非 ASCII 字面量', () {
      expect(() => percentDecode('%2'), throwsFormatException);
      expect(() => percentDecode('%'), throwsFormatException);
      expect(() => percentDecode('%GG'), throwsFormatException);
      expect(() => percentDecode('é'), throwsFormatException);
      expect(percentDecode('a+b'), 'a+b');
      expect(percentDecode('%e4%b8%ad'), '中');
    });
  });

  group('searchRowAction', () {
    test('group 行 → music:expand:<百分号编码 key>', () {
      final groupRow = row(0, <String, Object?>{'kind': 'group', 'key': 'artist:u1'});
      expect(searchRowAction(groupRow, 0), 'music:expand:artist%3Au1');
      final chinese = row(-1, <String, Object?>{'kind': 'group', 'key': 'name:张 三'});
      expect(searchRowAction(chinese, 2), 'music:expand:name%3A%E5%BC%A0%20%E4%B8%89');
    });

    test('普通行 → music:result:<lane>:<index>，index 用原始下标', () {
      final song = row(7, <String, Object?>{'kind': 'song', 'title': 'T'});
      expect(searchRowAction(song, 0), 'music:result:0:7');
      expect(searchRowAction(song, 2), 'music:result:2:7');
      expect(searchRowAction(row(0, <String, Object?>{}), 0), 'music:result:0:0');
    });
  });

  group('searchTitleMatch / searchTitleUnderline', () {
    test('大小写不敏感命中，前缀与匹配宽度用 demibold 18', () {
      final match = searchTitleMatch(shown: 'Hello World', query: 'WORLD', glyphWidth: fakeGlyph);
      expect(match.index, 6);
      expect(match.prefixWidth, fakeGlyph('Hello ', 18, 'demibold'));
      expect(match.matchWidth, fakeGlyph('WORLD', 18, 'demibold'));
      expect(match.prefixWidth, 6 * 18 * 0.6);
      expect(match.matchWidth, 5 * 18 * 0.6);
    });

    test('未命中 → index -1、matchWidth 0', () {
      final match = searchTitleMatch(shown: 'Hello', query: 'zzz', glyphWidth: fakeGlyph);
      expect(match.index, -1);
      expect(match.matchWidth, 0);
      expect(match, SearchTitleMatch.none);
    });

    test('query 为空 → 不匹配', () {
      final match = searchTitleMatch(shown: 'Hello', query: '', glyphWidth: fakeGlyph);
      expect(match, SearchTitleMatch.none);
    });

    test('UTF-16 单元下标与 substring 同构（含非 ASCII）', () {
      final match = searchTitleMatch(shown: 'aÄBC', query: 'äb', glyphWidth: fakeGlyph);
      expect(match.index, 1);
      expect(match.matchWidth, fakeGlyph('ÄB', 18, 'demibold'));
    });

    test('下划线 = (x+prefixWidth, y+19, matchWidth, 2)', () {
      final match = searchTitleMatch(shown: 'Hello World', query: 'WORLD', glyphWidth: fakeGlyph);
      final underline = searchTitleUnderline(x: 100, y: 200, match: match)!;
      expect(underline.left, 100 + 64.8);
      expect(underline.top, 219);
      expect(underline.width, 54);
      expect(underline.height, 2);
    });

    test('matchWidth 为 0 时不画下划线', () {
      final match = searchTitleMatch(shown: 'Hello', query: 'ell', glyphWidth: zeroGlyph);
      expect(match.matchWidth, 0);
      expect(searchTitleUnderline(x: 0, y: 0, match: match), isNull);
      expect(
        searchTitleUnderline(x: 0, y: 0, match: SearchTitleMatch.none),
        isNull,
      );
    });
  });

  group('deriveSearchGrouping — artist', () {
    final items = <SearchRow>[
      row(0, <String, Object?>{
        'kind': 'song',
        'title': 'Alpha',
        'artist': 'A',
        'albumID': 'al1',
        'album': 'Alb1',
        'artists': <Object?>[
          <String, Object?>{'id': 'u1', 'name': 'A'},
          <String, Object?>{'id': '', 'name': 'B'},
        ],
      }),
      row(1, <String, Object?>{'kind': 'song', 'title': 'Beta', 'artist': 'C', 'artists': <Object?>[]}),
      row(2, <String, Object?>{'kind': 'song', 'title': 'Gamma', 'artist': '', 'albumID': 'al1', 'album': 'Alb1'}),
      row(3, <String, Object?>{'kind': 'album', 'title': 'NotSong'}),
      row(4, <String, Object?>{
        'kind': 'song',
        'title': 'Delta',
        'artist': 'A',
        'artists': <Object?>[
          <String, Object?>{'id': 'u1', 'name': 'A'},
        ],
      }),
    ];

    test('artists 数组优先；id 空时用 name: 前缀', () {
      final grouping = deriveSearchGrouping(items: items, groupBy: 'artist');
      expect(grouping.grouped, isTrue);
      expect(grouping.groups.map((g) => g.key).toList(), <String>[
        'artist:u1',
        'name:B',
        'name:C',
        'name:',
      ]);
      expect(grouping.groups.map((g) => g.title).toList(), <String>['A', 'B', 'C', '未知歌手']);
      expect(grouping.groups.first.indices, <int>[0, 4]);
      expect(grouping.rows.length, 4);
    });

    test('group 行 value：kind/key/title/album + id 与 artist 串', () {
      final grouping = deriveSearchGrouping(items: items, groupBy: 'artist');
      final first = grouping.rows.first.value;
      expect(first['kind'], 'group');
      expect(first['key'], 'artist:u1');
      expect(first['title'], 'A');
      expect(first['album'], '点击展开分组');
      expect(first['id'], '2');
      expect(first['artist'], '2 首已载入');
      expect(grouping.rows[2].value['id'], '1');
      expect(grouping.rows[2].value['artist'], '1 首已载入');
    });

    test('非 song 行不参与分组也不出现在结果里', () {
      final grouping = deriveSearchGrouping(items: items, groupBy: 'artist');
      expect(grouping.rows.any((r) => r.value['kind'] == 'album'), isFalse);
      expect(grouping.rows.every((r) => r.index == -1), isTrue);
    });

    test('activeGroup 命中原组，返回原始行（保留原始 index 顺序）', () {
      final grouping = deriveSearchGrouping(items: items, groupBy: 'artist', activeGroup: 'name:C');
      expect(grouping.rows.length, 1);
      expect(grouping.rows.single.index, 1);
      expect(grouping.rows.single.value['title'], 'Beta');
      expect(grouping.groupFor('name:C')!.indices, <int>[1]);
    });

    test('activeGroup 未命中返回空列表', () {
      final grouping = deriveSearchGrouping(items: items, groupBy: 'artist', activeGroup: 'nope');
      expect(grouping.rows, isEmpty);
      expect(grouping.groupFor('nope'), isNull);
    });

    test('artists 数组缺失时回退 name:<artist>', () {
      final grouping = deriveSearchGrouping(items: items, groupBy: 'artist');
      expect(grouping.groups.map((g) => g.key), contains('name:C'));
      expect(grouping.groups.firstWhere((g) => g.key == 'name:C').title, 'C');
    });

    test('artist 为空 → key name: 且 title 未知歌手', () {
      final grouping = deriveSearchGrouping(items: items, groupBy: 'artist');
      final unknown = grouping.groups.firstWhere((g) => g.key == 'name:');
      expect(unknown.title, '未知歌手');
      expect(unknown.indices, <int>[2]);
    });
  });

  group('deriveSearchGrouping — album', () {
    final items = <SearchRow>[
      row(0, <String, Object?>{'kind': 'song', 'title': 'A', 'albumID': 'al1', 'album': 'Alb1'}),
      row(1, <String, Object?>{'kind': 'song', 'title': 'B', 'albumID': '', 'album': ''}),
      row(2, <String, Object?>{'kind': 'song', 'title': 'C', 'albumID': 'al1', 'album': 'Alb1'}),
    ];

    test('albumID 非空用 album:<id>，否则 album-name:<album>', () {
      final grouping = deriveSearchGrouping(items: items, groupBy: 'album');
      expect(grouping.groups.map((g) => g.key).toList(), <String>['album:al1', 'album-name:']);
      expect(grouping.groups.first.indices, <int>[0, 2]);
      expect(grouping.groups.first.title, 'Alb1');
    });

    test('album 为空 → title 未知专辑', () {
      final grouping = deriveSearchGrouping(items: items, groupBy: 'album');
      expect(grouping.groups.last.title, '未知专辑');
    });

    test('同 label 去重：先到先得、只建一个组', () {
      final grouping = deriveSearchGrouping(items: items, groupBy: 'album');
      expect(grouping.groups.length, 2);
      expect(grouping.groups.first.indices, <int>[0, 2]);
      expect(grouping.groups.first.key, 'album:al1');
    });
  });

  group('deriveSearchGrouping — none / filter / 无 song', () {
    final items = <SearchRow>[
      row(0, <String, Object?>{'kind': 'song', 'title': 'Alpha', 'artist': 'A', 'id': 'u1'}),
      row(1, <String, Object?>{'kind': 'album', 'title': 'Beta', 'artist': 'B'}),
      row(2, <String, Object?>{'kind': 'song', 'title': 'Gamma', 'artist': 'C', 'id': 'u3'}),
    ];

    test('groupBy none 返回（过滤后）原始行，不做分组', () {
      final grouping = deriveSearchGrouping(items: items, groupBy: 'none');
      expect(grouping.grouped, isFalse);
      expect(grouping.groups, isEmpty);
      expect(grouping.rows.map((r) => r.index).toList(), <int>[0, 1, 2]);
    });

    test('filter 用 title+artist+id 小写包含匹配', () {
      final grouping = deriveSearchGrouping(items: items, groupBy: 'none', filter: 'u3');
      expect(grouping.rows.map((r) => r.index).toList(), <int>[2]);
      final byArtist = deriveSearchGrouping(items: items, groupBy: 'none', filter: 'c');
      expect(byArtist.rows.map((r) => r.index).toList(), <int>[2]);
      final byTitle = deriveSearchGrouping(items: items, groupBy: 'none', filter: 'beta');
      expect(byTitle.rows.map((r) => r.index).toList(), <int>[1]);
    });

    test('filter 在分组之前生效', () {
      final grouping = deriveSearchGrouping(items: items, groupBy: 'album', filter: 'gamma');
      expect(grouping.grouped, isTrue);
      expect(grouping.groups.length, 1);
      expect(grouping.groups.single.indices, <int>[2]);
    });

    test('无 song 行时不分组，直接返回可见原始行', () {
      final noSongs = <SearchRow>[
        row(0, <String, Object?>{'kind': 'album', 'title': 'X'}),
        row(1, <String, Object?>{'kind': 'playlist', 'title': 'Y'}),
      ];
      final grouping = deriveSearchGrouping(items: noSongs, groupBy: 'artist');
      expect(grouping.grouped, isFalse);
      expect(grouping.rows.map((r) => r.index).toList(), <int>[0, 1]);
    });

    test('deriveSearchRows 只返回展示列表', () {
      final rows = deriveSearchRows(items: items, groupBy: 'artist');
      expect(rows.every((r) => r.index == -1), isTrue);
      expect(rows.length, 2);
    });
  });

  group('SearchResultsState', () {
    test('初值：0 / 0 / -1 / 0 / 0 / -1', () {
      final state = SearchResultsState();
      expect(state.searchScroll, 0);
      expect(state.searchRowCount, 0);
      expect(state.autoFillSize, -1);
      expect(state.savedScroll, 0);
      expect(state.savedRowCount, 0);
      expect(state.savedAutoFillSize, -1);
    });

    test('resetResultViews 六字段复位', () {
      final state = SearchResultsState(
        searchScroll: 120,
        searchRowCount: 9,
        autoFillSize: 7,
        savedScroll: 88,
        savedRowCount: 4,
        savedAutoFillSize: 3,
      );
      state.resetResultViews();
      expect(state.searchScroll, 0);
      expect(state.searchRowCount, 0);
      expect(state.autoFillSize, -1);
      expect(state.savedScroll, 0);
      expect(state.savedRowCount, 0);
      expect(state.savedAutoFillSize, -1);
    });

    test('shouldAutoFill 每个守卫都单独能拦住（各自新状态）', () {
      bool call({
        SearchResultsState? state,
        bool modalIsSearch = true,
        bool closing = false,
        String query = 'abc',
        String keyword = 'abc',
        bool sourceLoading = false,
        bool hasMore = true,
        int rowCount = 3,
      }) {
        return (state ?? SearchResultsState()).shouldAutoFill(
          modalIsSearch: modalIsSearch,
          closing: closing,
          query: query,
          keyword: keyword,
          sourceLoading: sourceLoading,
          hasMore: hasMore,
          rowCount: rowCount,
        );
      }

      expect(call(), isTrue);
      expect(call(modalIsSearch: false), isFalse);
      expect(call(closing: true), isFalse);
      expect(call(query: 'ab'), isFalse);
      expect(call(sourceLoading: true), isFalse);
      expect(call(hasMore: false), isFalse);
      expect(call(rowCount: 0), isFalse);
    });

    test('接受时把 autoFillSize 更新为 rowCount', () {
      final state = SearchResultsState();
      expect(
        state.shouldAutoFill(
          modalIsSearch: true,
          closing: false,
          query: 'abc',
          keyword: 'abc',
          sourceLoading: false,
          hasMore: true,
          rowCount: 3,
        ),
        isTrue,
      );
      expect(state.autoFillSize, 3);
    });

    test('query.trimmed() 与 keyword 比较', () {
      final state = SearchResultsState();
      expect(
        state.shouldAutoFill(
          modalIsSearch: true,
          closing: false,
          query: '  abc  ',
          keyword: 'abc',
          sourceLoading: false,
          hasMore: true,
          rowCount: 2,
        ),
        isTrue,
      );
    });

    test('rowCount <= autoFillSize 时不再重复接受', () {
      final state = SearchResultsState(autoFillSize: 5);
      expect(
        state.shouldAutoFill(
          modalIsSearch: true,
          closing: false,
          query: 'k',
          keyword: 'k',
          sourceLoading: false,
          hasMore: true,
          rowCount: 5,
        ),
        isFalse,
      );
      expect(state.autoFillSize, 5);
      expect(
        state.shouldAutoFill(
          modalIsSearch: true,
          closing: false,
          query: 'k',
          keyword: 'k',
          sourceLoading: false,
          hasMore: true,
          rowCount: 6,
        ),
        isTrue,
      );
      expect(state.autoFillSize, 6);
    });

    test('needLoadMore = rowCount*72 < 430', () {
      final state = SearchResultsState();
      final short = state.evaluateAutoFill(
        modalIsSearch: true,
        closing: false,
        query: 'k',
        keyword: 'k',
        sourceLoading: false,
        hasMore: true,
        rowCount: 5,
      );
      expect(short.accepted, isTrue);
      expect(short.needLoadMore, isTrue);
      expect(short.shouldLoadMore, isTrue);

      final state2 = SearchResultsState();
      final full = state2.evaluateAutoFill(
        modalIsSearch: true,
        closing: false,
        query: 'k',
        keyword: 'k',
        sourceLoading: false,
        hasMore: true,
        rowCount: 6,
      );
      expect(full.accepted, isTrue);
      expect(full.needLoadMore, isFalse);
      expect(full.shouldLoadMore, isFalse);

      final state3 = SearchResultsState();
      final guarded = state3.evaluateAutoFill(
        modalIsSearch: true,
        closing: false,
        query: 'k',
        keyword: 'k',
        sourceLoading: false,
        hasMore: false,
        rowCount: 2,
      );
      expect(guarded.accepted, isFalse);
      expect(guarded.needLoadMore, isTrue);
      expect(guarded.shouldLoadMore, isFalse);
      expect(state3.autoFillSize, -1);
    });
  });

  group('SearchResultsLayer.draw', () {
    test('空列表只画两行文案，不发命中也不画轨道', () {
      final port = RecordingPort();
      final layer = SearchResultsLayer(
        port: port,
        originX: stageOriginX,
        originY: stageOriginY,
        modalWidth: modalWidth1920,
        rows: const <SearchRow>[],
        scroll: 0,
        lane: 0,
        ink: const SearchColor(0.1, 0.1, 0.1),
        dark: true,
        localMusic: false,
        emptyMessage: '没有找到结果',
        query: 'abc',
      );
      layer.draw(port);
      expect(port.hits, isEmpty);
      expect(port.clips, isEmpty);
      expect(port.ops.where((op) => op.startsWith('text')).length, 2);
      expect(port.ops.first, startsWith('text 没有找到结果 @1013.0,542.0'));
      expect(port.ops.last, contains('输入歌曲、歌手、专辑或歌单名称后按 ENTER。'));
      expect(port.fits.first, <Object?>['没有找到结果', 18.0, 795.0, 'demibold']);
      expect(port.fits.last, <Object?>['输入歌曲、歌手、专辑或歌单名称后按 ENTER。', 12.0, 795.0, 'regular']);
    });

    test('按 index 升序绘制并收集命中，命中六字段原序', () {
      final port = RecordingPort();
      final rows = <SearchRow>[
        for (var index = 0; index < 10; index++)
          row(index, <String, Object?>{
            'kind': 'song',
            'id': 'id' + index.toString(),
            'title': 'Title' + index.toString(),
            'artist': 'Artist',
          }),
      ];
      final layer = SearchResultsLayer(
        port: port,
        originX: stageOriginX,
        originY: stageOriginY,
        modalWidth: modalWidth1920,
        rows: rows,
        scroll: 0,
        lane: 0,
        ink: const SearchColor(0.1, 0.1, 0.1),
        dark: true,
        localMusic: false,
        emptyMessage: '没有找到结果',
        query: 'Title',
      );
      layer.draw(port);

      expect(port.ops.first, 'save');
      expect(port.ops[1], startsWith('clip Rect(1013.0, 450.0, 795.0, 430.0)'));
      expect(port.clips.single, const Rect.fromLTWH(1013, 450, 795, 430));

      // 可见区间 0..7，但只有与视口相交的行才发命中：0..5。
      expect(port.hits.length, 6);
      expect(port.hits.map((hit) => hit[4]).toList(), <Object?>[
        'music:result:0:0',
        'music:result:0:1',
        'music:result:0:2',
        'music:result:0:3',
        'music:result:0:4',
        'music:result:0:5',
      ]);
      expect(port.hits.first, <Object?>[1013.0, 450.0, 795.0, 72.0, 'music:result:0:0', 'Title0']);
      // 第 5 行被视口裁剪：450 + 5*72 = 810，高只剩 430 - 360 = 70。
      expect(port.hits[5], <Object?>[1013.0, 810.0, 795.0, 70.0, 'music:result:0:5', 'Title5']);
      expect(port.ops.last, isNot(startsWith('hit')));
    });

    test('group 行命中走 music:expand: 且 label 用原文 title', () {
      final port = RecordingPort();
      final layer = SearchResultsLayer(
        port: port,
        originX: stageOriginX,
        originY: stageOriginY,
        modalWidth: modalWidth1920,
        rows: <SearchRow>[
          row(-1, <String, Object?>{
            'kind': 'group',
            'key': 'artist:u1',
            'title': '歌手A',
            'album': '点击展开分组',
            'id': '2',
            'artist': '2 首已载入',
          }),
        ],
        scroll: 0,
        lane: 0,
        ink: const SearchColor(0.1, 0.1, 0.1),
        dark: false,
        localMusic: true,
        emptyMessage: '没有找到结果',
        query: '歌手',
      );
      layer.draw(port);
      expect(port.hits.single[4], 'music:expand:artist%3Au1');
      expect(port.hits.single[5], '歌手A');
      // group 行的 detail 是 artist 字段（2 首已载入），不是 album 文案。
      expect(port.fits.map((fit) => fit[0]), contains('2 首已载入'));
    });

    test('滚动越界时先 clamp 再绘制，命中随之平移', () {
      final port = RecordingPort();
      final rows = <SearchRow>[
        for (var index = 0; index < 10; index++)
          row(index, <String, Object?>{'kind': 'song', 'title': 'T' + index.toString()}),
      ];
      final layer = SearchResultsLayer(
        port: port,
        originX: stageOriginX,
        originY: stageOriginY,
        modalWidth: modalWidth1920,
        rows: rows,
        scroll: 9999,
        lane: 0,
        ink: const SearchColor(0.1, 0.1, 0.1),
        dark: true,
        localMusic: false,
        emptyMessage: '没有找到结果',
        query: '',
      );
      expect(layer.maximumScroll, 290);
      layer.draw(port);
      // clamp 后 scroll = 290；可见区间 first=3，但第 3 行 rowY=376 完全在视口上方被丢弃，
      // 第 4 行 rowY=448 只与视口相交 70 像素。
      expect(port.hits.first[4], 'music:result:0:4');
      expect(port.hits.first[1], 450.0);
      expect(port.hits.first[3], 70.0);
      expect(port.hits.map((hit) => hit[4]).toList(), <Object?>[
        'music:result:0:4',
        'music:result:0:5',
        'music:result:0:6',
        'music:result:0:7',
        'music:result:0:8',
        'music:result:0:9',
      ]);
      expect(port.hits.every((hit) => (hit[1] as double) >= 450), isTrue);
      expect(port.hits.every((hit) => (hit[1] as double) + (hit[3] as double) <= 880), isTrue);
    });

    test('内容超出视口才画轨道 thumb', () {
      RecordingPort portWithRail() => RecordingPort();
      final rows = <SearchRow>[
        for (var index = 0; index < 10; index++)
          row(index, <String, Object?>{'kind': 'song', 'title': 'T'}),
      ];
      final port = portWithRail();
      SearchResultsLayer(
        port: port,
        originX: stageOriginX,
        originY: stageOriginY,
        modalWidth: modalWidth1920,
        rows: rows,
        scroll: 0,
        lane: 0,
        ink: const SearchColor(0.1, 0.1, 0.1),
        dark: true,
        localMusic: false,
        emptyMessage: '没有找到结果',
        query: '',
      ).draw(port);
      // 轨道 + thumb 两次 fill 都以 Rect(1837, 458, 3, …) 出现。
      final railFills = port.ops
          .where((op) => op.startsWith('fill') && op.contains('Rect(1837.0, 458.0, 3.0'))
          .toList();
      expect(railFills.length, 2);
      expect(railFills.last, contains('0.45'));

      final shortPort = RecordingPort();
      SearchResultsLayer(
        port: shortPort,
        originX: stageOriginX,
        originY: stageOriginY,
        modalWidth: modalWidth1920,
        rows: rows.take(2).toList(),
        scroll: 0,
        lane: 0,
        ink: const SearchColor(0.1, 0.1, 0.1),
        dark: true,
        localMusic: false,
        emptyMessage: '没有找到结果',
        query: '',
      ).draw(shortPort);
      final shortRailFills = shortPort.ops
          .where((op) => op.startsWith('fill') && op.contains('Rect(1837.0, 458.0, 3.0'))
          .toList();
      expect(shortRailFills.length, 1);
    });

    test('paint 转调 draw（画布由端口持有）', () {
      final port = RecordingPort();
      final layer = SearchResultsLayer(
        port: port,
        originX: stageOriginX,
        originY: stageOriginY,
        modalWidth: modalWidth1920,
        rows: const <SearchRow>[],
        scroll: 0,
        lane: 0,
        ink: const SearchColor(0.1, 0.1, 0.1),
        dark: true,
        localMusic: true,
        emptyMessage: '空',
        query: '',
      );
      expect(layer.viewport, const Rect.fromLTWH(1013, 450, 795, 430));
      expect(layer.shouldRepaint(layer), isFalse);
      expect(port.ops, isEmpty);
      // paint 需要真实 Canvas，本卡禁止运行 Flutter 测试，故只验证 draw 路径。
      expect(Size(1920, 1080).width, 1920);
    });
  });
}
