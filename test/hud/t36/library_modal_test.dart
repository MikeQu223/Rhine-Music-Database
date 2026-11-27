// T36 · library_modal 只读回归测试。
//
// 状态：RED 未执行（用户禁运行验证）。按硬禁令，本文件只写不执行：
//   禁执行 flutter/dart 任何命令（build/test/analyze/run/pub get/format/代码生成）。
// 因此本文件从未被运行过；用例中的断言值全部由 Qt 源码常量手工推导。
//
// 证据（逐条对应 qt 源码；本文件不 import 任何跨树模块）：
// - 常量：Qt/src/NativeHudLibrary.cpp:7-18
// - toolbarActionWidth：Qt/src/NativeHudLibrary.cpp:60-72
// - 标签行 hit/下划线：Qt/src/NativeHudLibrary.cpp:119-134
// - 排序段 hit/分隔线/下划线：Qt/src/NativeHudLibrary.cpp:136-165
// - 表头与 rule 0.18/0.24：Qt/src/NativeHudLibrary.cpp:167-171
// - 分组返回 hit：Qt/src/NativeHudLibrary.cpp:173-179
// - 空态/登录入口：Qt/src/NativeHudLibrary.cpp:192-201
// - viewport/裁剪/rail：Qt/src/NativeHudLibrary.cpp:186,203-225
// - footer：Qt/src/NativeHudLibrary.cpp:228-250
// - ensureSavedFilled 去重：Qt/src/NativeHudLibrary.cpp:256-268
// - ResultListTop/Bottom/RowHeight：Qt/src/NativeHud.h:96-98
// - hit 六字段：Qt/src/NativeHud.cpp:102-109
// - rail/clipHits：Qt/src/HudScroll.h:50-86

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/library_modal.dart';

/// 确定性测试替身（TEST DOUBLE）。只用于测试；生产代码必须注入真实 Glyphs。
///
/// 宽度规则：每个 rune 宽度 = size * 0.6；bounds：x=0, y=-size*0.8,
/// width=width(text,size), height=size。规则固定，便于精确断言几何。
class FakeMetrics implements LibraryTextMetrics {
  const FakeMetrics();

  @override
  double width(String text, double size,
      {String weight = 'regular', double tracking = 0}) {
    return text.runes.length * size * 0.6 + tracking * text.runes.length;
  }

  @override
  LibraryTextBounds bounds(String text, double size,
      {String weight = 'regular'}) {
    return LibraryTextBounds(
      x: 0,
      y: -size * 0.8,
      width: width(text, size, weight: weight),
      height: size,
    );
  }

  // LibraryTextMetrics 是 abstract class 且 fit 带方法体；implements 不继承
  // 方法体，因此这里必须提供实现，否则测试文件无法编译。
  @override
  String fit(String text, double size, double maxWidth,
      {String weight = 'regular'}) {
    if (width(text, size, weight: weight) <= maxWidth) {
      return text;
    }
    final double unit = size * 0.6;
    final int capacity = unit <= 0 ? 0 : (maxWidth / unit).floor();
    final int kept = capacity < 1 ? 1 : capacity;
    final int cut = kept > text.length ? text.length : kept;
    return '${text.substring(0, cut)}…';
  }
}

/// 行绘制测试替身：为每一行发一个 fill + 一个行命中。
class FakeRowPainter implements LibraryRowPainter {
  final List<int> painted = <int>[];

  @override
  void paintRow({
    required LibraryRowRef row,
    required double x,
    required double y,
    required double width,
    required String query,
    required int lane,
    required LibraryRowOut out,
  }) {
    painted.add(row.index);
    out(
      HudFillCommand(HudRectF(x, y, width, LibraryGeometry.rowHeight),
          HudPalette.accent),
      null,
    );
    out(
      const HudFillCommand(HudRectF(0, 0, 0, 0), HudPalette.accent),
      HudHit(
        x: x,
        y: y,
        width: width,
        height: LibraryGeometry.rowHeight,
        action: 'music:row:${row.index}',
        label: 'row-${row.index}',
      ),
    );
  }
}

/// 端口记录替身：只记录调用，不触发副作用。
class RecordingPorts implements LibraryModalPorts {
  int createCount = 0;
  int refreshCount = 0;
  int loadMoreCount = 0;
  int loginCount = 0;
  int backCount = 0;
  int closeCount = 0;
  final List<int> collections = <int>[];
  final List<String> groupKeys = <String>[];
  final List<double> scrolls = <double>[];

  @override
  void createPlaylist() => createCount++;

  @override
  void refreshPersonal() => refreshCount++;

  @override
  void selectCollection(int collection) => collections.add(collection);

  @override
  void setGroupKey(String key) => groupKeys.add(key);

  @override
  void backToAllGroups() => backCount++;

  @override
  void openLogin() => loginCount++;

  @override
  void closeModal() => closeCount++;

  @override
  void scrollSaved(double offset) => scrolls.add(offset);

  @override
  void loadMoreSaved() => loadMoreCount++;
}

LibraryRowRef songRow(int index) => LibraryRowRef(
      index: index,
      value: <String, Object?>{'kind': 'song', 'title': 't$index'},
    );

LibraryRowRef albumRow(int index) => LibraryRowRef(
      index: index,
      value: <String, Object?>{'kind': 'album', 'title': 'a$index'},
    );

LibraryModalSnapshot snapshot({
  String modal = 'saved',
  bool dark = false,
  String provider = 'netease',
  String providerName = '网易云音乐',
  String uid = '',
  bool restoringAccount = false,
  bool isLocal = false,
  bool isSiren = false,
  List<String>? columns,
  int musicCollection = 1,
  String groupBy = 'none',
  String activeGroup = '',
  String query = '',
  List<LibraryRowRef>? rows,
  bool laneHasSong = false,
  int loadedCount = 0,
  int total = 0,
  bool hasMore = true,
  bool sourceLoading = false,
  String status = '',
  String emptyMessage = '',
  double savedScroll = 0,
}) {
  return LibraryModalSnapshot(
    modal: modal,
    dark: dark,
    provider: provider,
    providerName: providerName,
    uid: uid,
    restoringAccount: restoringAccount,
    isLocal: isLocal,
    isSiren: isSiren,
    columns: columns ??
        const <String>['搜索结果', '喜欢的歌曲', '我的歌单', '收藏歌单', '收藏专辑'],
    musicCollection: musicCollection,
    groupBy: groupBy,
    activeGroup: activeGroup,
    query: query,
    rows: rows ?? const <LibraryRowRef>[],
    laneHasSong: laneHasSong,
    loadedCount: loadedCount,
    total: total,
    hasMore: hasMore,
    sourceLoading: sourceLoading,
    status: status,
    emptyMessage: emptyMessage,
    savedScroll: savedScroll,
  );
}

HudHit onlyHit(List<HudHit> hits, String action) {
  final List<HudHit> matched =
      hits.where((HudHit h) => h.action == action).toList();
  expect(matched, hasLength(1), reason: 'action $action 应恰好一个命中');
  return matched.single;
}

HudTextCommand textCommand(List<HudCommand> commands, String value) {
  final Iterable<HudTextCommand> all =
      commands.whereType<HudTextCommand>();
  final List<HudTextCommand> matched =
      all.where((HudTextCommand c) => c.value == value).toList();
  expect(matched, hasLength(1), reason: '文案 $value 应恰好一条 text 命令');
  return matched.single;
}

void main() {
  const FakeMetrics metrics = FakeMetrics();
  const double x = 0;
  const double y = 0;
  const double w = 1920;

  LibrarySavedPanel panel({LibraryRowPainter? painter}) =>
      LibrarySavedPanel(metrics: metrics, rowPainter: painter);

  group('几何常量 1:1（Qt/src/NativeHudLibrary.cpp:7-18, Qt/src/NativeHud.h:96-98）',
      () {
    test('全部常量与 Qt 源一致', () {
      expect(LibraryGeometry.inset, 53);
      expect(LibraryGeometry.barTop, 172);
      expect(LibraryGeometry.barHeight, 66);
      expect(LibraryGeometry.tabTop, 252);
      expect(LibraryGeometry.tabHeight, 36);
      expect(LibraryGeometry.tableY, 302);
      expect(LibraryGeometry.footerY, 786);
      expect(LibraryGeometry.createWidth, 150);
      expect(LibraryGeometry.refreshWidth, 110);
      expect(LibraryGeometry.actionGap, 10);
      expect(LibraryGeometry.titleX, 107);
      expect(LibraryGeometry.actionWidth, 136);
      expect(LibraryGeometry.resultListTop, 328);
      expect(LibraryGeometry.resultListBottom, 758);
      expect(LibraryGeometry.rowHeight, 72);
      expect(LibraryGeometry.viewportHeight, 430);
    });

    test('toolbarActionWidth 组合（NativeHudLibrary.cpp:60-72）', () {
      // netease/siren：editable=true，provider!=qq → 150+10
      expect(
        LibraryGeometry.toolbarActionWidth(
            savedModal: true, editable: true, provider: 'netease'),
        160,
      );
      expect(
        LibraryGeometry.toolbarActionWidth(
            savedModal: true, editable: true, provider: 'siren'),
        160,
      );
      // qq：150 + gap10 + 110 = 270，再补尾 gap 10 = 280
      expect(
        LibraryGeometry.toolbarActionWidth(
            savedModal: true, editable: true, provider: 'qq'),
        280,
      );
      // kugou：不可编辑、非 qq → 0
      expect(
        LibraryGeometry.toolbarActionWidth(
            savedModal: true, editable: false, provider: 'kugou'),
        0,
      );
      // 非 saved 模态恒 0
      expect(
        LibraryGeometry.toolbarActionWidth(
            savedModal: false, editable: true, provider: 'qq'),
        0,
      );
    });

    test('savedScrollMaximum（NativeHudLibrary.cpp:252-254）', () {
      expect(LibraryGeometry.savedScrollMaximum(0), 0);
      expect(LibraryGeometry.savedScrollMaximum(6.0), 0); // 432-430
      expect(LibraryGeometry.savedScrollMaximum(10.0), 720 - 430);
    });
  });

  group('横屏工具条（Qt/src/NativeHudLibrary.cpp:95-180）', () {
    test('创建歌单 hit 矩形/文案/action（qq 叠加刷新）', () {
      final LibraryModalFrame f = panel().buildSaved(
        s: snapshot(provider: 'qq', providerName: 'QQ音乐'),
        x: x,
        y: y,
        width: w,
      );
      final HudHit create = onlyHit(f.hits, 'music:create-playlist');
      expect(create.label, '创建歌单');
      expect(create.x, closeTo(1920 - 53 - 150, 1e-9)); // 1717
      expect(create.y, closeTo(172, 1e-9));
      expect(create.width, 150);
      expect(create.height, 66);

      final HudHit refresh = onlyHit(f.hits, 'music:refresh-personal');
      expect(refresh.label, '刷新个人库');
      expect(refresh.x, closeTo(1717 - 10 - 110, 1e-9)); // 1597
      expect(refresh.width, 110);
    });

    test('netease 不出现刷新命中；kugou 无创建（editable=false）', () {
      final LibraryModalFrame netease =
          panel().buildSaved(s: snapshot(), x: x, y: y, width: w);
      expect(netease.hitsFor('music:refresh-personal'), isEmpty);
      expect(netease.hitsFor('music:create-playlist'), hasLength(1));

      final LibraryModalFrame kugou = panel().buildSaved(
        s: snapshot(provider: 'kugou', providerName: '酷狗音乐'),
        x: x,
        y: y,
        width: w,
      );
      expect(kugou.hitsFor('music:create-playlist'), isEmpty);
      expect(kugou.hitsFor('music:refresh-personal'), isEmpty);
    });

    test('工具条底宽 = usable - actionSpan，QUERY 文案在 left+18', () {
      final LibraryModalFrame f =
          panel().buildSaved(s: snapshot(), x: x, y: y, width: w);
      // 工具条底色是 _toolbar 中第一个 66 高的 fill（其余 66 高 fill 为按钮底）
      final HudFillCommand bar = f.commands
          .whereType<HudFillCommand>()
          .firstWhere(
              (HudFillCommand c) => c.rect.height == LibraryGeometry.barHeight);
      expect(bar.rect.left, 53);
      expect(bar.rect.top, 172);
      expect(bar.rect.height, 66);
      expect(bar.rect.width, closeTo(1814 - 160, 1e-9)); // 1654

      final HudTextCommand query = textCommand(f.commands, 'QUERY / 检索词');
      expect(query.x, 53 + 18);
      expect(query.y, 172 + 10);
      expect(query.size, 9);
      expect(query.tracking, 0.08);
      expect(query.color.a, 0.55);
    });

    test('标签行 hit 与 active 下划线（NativeHudLibrary.cpp:119-134）', () {
      final LibraryModalFrame f =
          panel().buildSaved(s: snapshot(), x: x, y: y, width: w);
      // columns.mid(1,4) → 4 个标签；musicCollection=1 → 第 0 个 active
      final HudHit tab1 = onlyHit(f.hits, 'music:collection:1');
      expect(tab1.label, '喜欢的歌曲');
      expect(tab1.x, closeTo(53 - 4, 1e-9));
      expect(tab1.y, closeTo(252, 1e-9));
      // width = 5 runes * 13 * 0.6 = 39 → +8 = 47
      expect(tab1.width, closeTo(39 + 8, 1e-9));
      expect(tab1.height, 36);

      final HudTextCommand tab1Text = textCommand(f.commands, '喜欢的歌曲');
      expect(tab1Text.weight, 'demibold');
      expect(tab1Text.x, 53);
      expect(tab1Text.y, 252 + 10);
      expect(tab1Text.size, 13);

      // 第二个标签游标 = 53 + 39 + 26 = 118
      final HudHit tab2 = onlyHit(f.hits, 'music:collection:2');
      expect(tab2.label, '我的歌单');
      expect(tab2.x, closeTo(118 - 4, 1e-9));

      // active 下划线：3px gold，位于 tabTop+tabHeight-3，宽度 = labelWidth
      final List<HudFillCommand> goldUnderline = f.commands
          .whereType<HudFillCommand>()
          .where((HudFillCommand c) =>
              c.color.r == 0.835 && c.color.g == 0.639 && c.rect.height == 3)
          .toList();
      expect(goldUnderline, hasLength(1));
      expect(goldUnderline.single.rect.width, closeTo(39, 1e-9));
    });

    test('标签下划线高度 3、gold、y = tabTop+33', () {
      final LibraryModalFrame f =
          panel().buildSaved(s: snapshot(), x: x, y: y, width: w);
      final List<HudFillCommand> unders = f.commands
          .whereType<HudFillCommand>()
          .where((HudFillCommand c) => c.rect.height == 3)
          .toList();
      expect(unders, hasLength(1));
      expect(unders.single.rect.left, 53);
      expect(unders.single.rect.top, closeTo(252 + 36 - 3, 1e-9));
      expect(unders.single.rect.width, closeTo(39, 1e-9));
      expect(unders.single.color.toFlatArray(), HudPalette.accent.toFlatArray());
    });

    test('排序段 hit/分隔线/下划线（NativeHudLibrary.cpp:136-165）', () {
      final LibraryModalFrame f = panel().buildSaved(
        s: snapshot(
          rows: <LibraryRowRef>[songRow(0), songRow(1)],
          laneHasSong: true,
        ),
        x: x,
        y: y,
        width: w,
      );
      // widths: 原序 2*6.6=13.2, 歌手分组 26.4, 专辑分组 26.4 → total 106.0
      final double total = 13.2 + 26.4 + 26.4 + 20 * 2;
      expect(total, closeTo(106.0, 1e-9));
      final double sortX = 1920 - 53 - total;

      final HudHit g0 = onlyHit(f.hits, 'music:group:0');
      expect(g0.label, '原序');
      expect(g0.x, closeTo(sortX - 4, 1e-9));
      expect(g0.y, closeTo(252, 1e-9));
      expect(g0.width, closeTo(13.2 + 8, 1e-9));
      expect(g0.height, 36);

      final HudHit g1 = onlyHit(f.hits, 'music:group:1');
      expect(g1.x, closeTo(sortX + 13.2 + 20 - 4, 1e-9));
      expect(g1.width, closeTo(26.4 + 8, 1e-9));

      // 1px 分隔线在 sortX-16，y=tabTop+6，高 24，alpha 0.18
      final HudFillCommand divider = f.commands
          .whereType<HudFillCommand>()
          .firstWhere((HudFillCommand c) => c.rect.width == 1 && c.rect.height == 24);
      expect(divider.rect.left, closeTo(sortX - 16, 1e-9));
      expect(divider.rect.top, closeTo(252 + 6, 1e-9));
      expect(divider.color.a, closeTo(0.18, 1e-9));

      // active groupBy=none → 第 0 段 2px 下划线
      final HudFillCommand underline = f.commands
          .whereType<HudFillCommand>()
          .firstWhere((HudFillCommand c) => c.rect.height == 2);
      expect(underline.rect.left, closeTo(sortX, 1e-9));
      expect(underline.rect.top, closeTo(252 + 36 - 2, 1e-9));
      expect(underline.rect.width, closeTo(13.2, 1e-9));
      expect(underline.color.toFlatArray(), HudPalette.accent.toFlatArray());
    });

    test('无 song 行时不绘制排序段（NativeHudLibrary.cpp:137-140）', () {
      final LibraryModalFrame f = panel().buildSaved(
        s: snapshot(rows: <LibraryRowRef>[albumRow(0)]),
        x: x,
        y: y,
        width: w,
      );
      expect(f.hitsFor('music:group:0'), isEmpty);
      expect(f.hitsFor('music:group:1'), isEmpty);
      expect(f.hitsFor('music:group:2'), isEmpty);
    });

    test('过滤后无 song 但 lists[lane] 含 song：排序段仍出现（NativeHudLibrary.cpp:136-140）', () {
      final LibraryModalFrame f = panel().buildSaved(
        s: snapshot(rows: <LibraryRowRef>[albumRow(0)], laneHasSong: true),
        x: x,
        y: y,
        width: w,
      );
      expect(f.hitsFor('music:group:0'), hasLength(1));
      expect(f.hitsFor('music:group:1'), hasLength(1));
      expect(f.hitsFor('music:group:2'), hasLength(1));
    });

    test('表头文案与 rule 0.18/0.24（NativeHudLibrary.cpp:167-171）', () {
      final LibraryModalFrame f =
          panel().buildSaved(s: snapshot(), x: x, y: y, width: w);
      final HudTextCommand id = textCommand(f.commands, 'ID / 编号');
      expect(id.x, 53);
      expect(id.y, 302);
      expect(id.size, 9);
      expect(id.tracking, 0.07);
      final HudTextCommand title = textCommand(f.commands, 'TITLE / 音乐');
      expect(title.x, 53 + 107);
      expect(title.y, 302);
      final HudTextCommand open = textCommand(f.commands, 'OPEN');
      expect(open.x, 1920 - 136);
      expect(open.y, 302);

      final List<HudFillCommand> rules = f.commands
          .whereType<HudFillCommand>()
          .where((HudFillCommand c) => c.rect.height == 1 && c.rect.width == 1814)
          .toList();
      expect(rules, hasLength(2));
      expect(rules[0].rect.top, closeTo(252 + 36, 1e-9));
      expect(rules[0].color.a, closeTo(0.18, 1e-9));
      expect(rules[1].rect.top, closeTo(302 + 16, 1e-9));
      expect(rules[1].color.a, closeTo(0.24, 1e-9));
    });

    test('分组返回 hit「全部分组」action music:group-back（:173-179）', () {
      final LibraryModalFrame plain =
          panel().buildSaved(s: snapshot(), x: x, y: y, width: w);
      expect(plain.hitsFor('music:group-back'), isEmpty);

      final LibraryModalFrame grouped = panel().buildSaved(
        s: snapshot(activeGroup: '某歌手', groupBy: 'artist'),
        x: x,
        y: y,
        width: w,
      );
      final HudHit back = onlyHit(grouped.hits, 'music:group-back');
      expect(back.label, '全部分组');
      expect(back.height, 28);
      // labelWidth = 6 runes * 6.6 + 16 = 55.6
      const double labelWidth = 6 * 11 * 0.6 + 16;
      expect(back.width, closeTo(labelWidth, 1e-9));
      expect(back.x, closeTo(1920 - 53 - 150 - labelWidth, 1e-9));
      expect(back.y, closeTo(302 - 7, 1e-9));
      final HudTextCommand backText = textCommand(grouped.commands, '← 全部分组');
      expect(backText.x, closeTo(back.x + 8, 1e-9));
      expect(backText.y, 302);
      expect(backText.size, 11);
    });
  });

  group('结果列表 viewport / 空态 / 登录入口（NativeHudLibrary.cpp:182-226）', () {
    test('viewport = (left, 328, usable, 430)', () {
      final LibraryModalFrame f =
          panel().buildSaved(s: snapshot(), x: x, y: y, width: w);
      expect(f.viewport.left, 53);
      expect(f.viewport.top, 328);
      expect(f.viewport.width, 1814);
      expect(f.viewport.height, 430);
    });

    test('未登录且非 local/siren：登录入口 (left, 460, 300, 44) + 文案', () {
      final LibraryModalFrame f = panel().buildSaved(
        s: snapshot(uid: '', providerName: '网易云音乐'),
        x: x,
        y: y,
        width: w,
      );
      final HudHit login = onlyHit(f.hits, 'music:login');
      expect(login.label, '登录网易云音乐 →');
      expect(login.x, 53);
      expect(login.y, closeTo(328 + 132, 1e-9));
      expect(login.width, 300);
      expect(login.height, 44);

      final HudTextCommand empty = textCommand(f.commands, '');
      expect(empty.y, closeTo(328 + 92, 1e-9));
      expect(empty.size, 18);
      expect(empty.weight, 'demibold');
    });

    test('isLocal / isSiren / lane<=0 / restoringAccount 都不给登录入口', () {
      for (final LibraryModalSnapshot s in <LibraryModalSnapshot>[
        snapshot(isLocal: true),
        snapshot(isSiren: true),
        snapshot(isLocal: true, isSiren: true),
        snapshot(musicCollection: 0),
        snapshot(restoringAccount: true),
        snapshot(uid: 'u1'),
      ]) {
        final LibraryModalFrame f =
            panel().buildSaved(s: s, x: x, y: y, width: w);
        expect(f.hitsFor('music:login'), isEmpty);
      }
    });

    test('有行时 save/clip/restore 顺序与 rail（NativeHudLibrary.cpp:203-225）',
        () {
      final FakeRowPainter painter = FakeRowPainter();
      final LibraryModalFrame f = panel(painter: painter).buildSaved(
        s: snapshot(rows: <LibraryRowRef>[songRow(0), songRow(1)]),
        x: x,
        y: y,
        width: w,
      );
      final List<String> kinds = f.commands
          .map((HudCommand c) => c is HudSaveCommand
              ? 'save'
              : c is HudRestoreCommand
                  ? 'restore'
                  : c is HudClipCommand
                      ? 'clip'
                      : '')
          .where((String k) => k.isNotEmpty)
          .toList();
      expect(kinds, <String>['save', 'clip', 'restore']);

      final HudClipCommand clip =
          f.commands.whereType<HudClipCommand>().single;
      expect(clip.rect.top, 328);
      expect(clip.rect.height, 430);

      // 2 行 * 72 = 144 < 430 → rail 不可见
      final List<HudFillCommand> railFills = f.commands
          .whereType<HudFillCommand>()
          .where((HudFillCommand c) => c.rect.width == 3)
          .toList();
      expect(railFills, hasLength(1)); // 只有 track
      final HudHit row0 = onlyHit(f.hits, 'music:row:0');
      expect(row0.y, closeTo(328, 1e-9)); // index0, scroll 0
    });

    test('rail thumb 在内容超过一屏时可见（HudScroll.h:50-64）', () {
      final FakeRowPainter painter = FakeRowPainter();
      final List<LibraryRowRef> rows =
          List<LibraryRowRef>.generate(10, songRow);
      final LibraryModalFrame f = panel(painter: painter).buildSaved(
        s: snapshot(rows: rows, loadedCount: 10, total: 10),
        x: x,
        y: y,
        width: w,
      );
      expect(f.savedRowCount, 10);
      expect(f.savedScrollMaximum, closeTo(720 - 430, 1e-9));
      final List<HudFillCommand> railFills = f.commands
          .whereType<HudFillCommand>()
          .where((HudFillCommand c) =>
              c.rect.width == 3 ||
              (c.rect.width == 3 && c.rect.height > 0))
          .toList();
      expect(railFills, hasLength(2)); // track + thumb
      final HudFillCommand track = railFills.first;
      expect(track.rect.left, closeTo(1920 - 24, 1e-9));
      expect(track.rect.top, closeTo(328 + 8, 1e-9));
      expect(track.rect.height, closeTo(430 - 16, 1e-9));
      expect(track.color.a, closeTo(0.10, 1e-9));
      final HudFillCommand thumb = railFills.last;
      expect(thumb.color.a, closeTo(0.45, 1e-9));
    });
  });

  group('footer（Qt/src/NativeHudLibrary.cpp:228-250）', () {
    test('accent 方块 (left, 789, 5, 5) + status 起点 left+13', () {
      final LibraryModalFrame f = panel().buildSaved(
        s: snapshot(status: '就绪', loadedCount: 3, total: 5),
        x: x,
        y: y,
        width: w,
      );
      final HudFillCommand square = f.commands
          .whereType<HudFillCommand>()
          .firstWhere((HudFillCommand c) => c.rect.width == 5 && c.rect.height == 5);
      expect(square.rect.left, 53);
      expect(square.rect.top, closeTo(786 + 3, 1e-9));
      expect(square.color.toFlatArray(), HudPalette.accent.toFlatArray());

      final HudTextCommand status = textCommand(f.commands, '就绪');
      expect(status.x, 53 + 13);
      expect(status.y, 786);
      expect(status.size, 10);
      expect(status.color.a, closeTo(0.55, 1e-9));
    });

    test('已载入文案与三种 hint（src:240-247）', () {
      expect(
        snapshot(loadedCount: 3, total: 5, hasMore: false).footerLabel,
        '已载入 3 / 5 · 全部已载入',
      );
      expect(
        snapshot(loadedCount: 3, total: 5, hasMore: true).footerLabel,
        '已载入 3 / 5 · SCROLL / 滚动加载',
      );
      expect(
        snapshot(loadedCount: 3, total: 5, sourceLoading: true).footerLabel,
        '已载入 3 / 5 · 正在加载…',
      );
      expect(snapshot(loadedCount: 0, total: 0).footerLabel, '已载入 0 / 0 · SCROLL / 滚动加载');
      // total < loaded 时取 max
      expect(
        snapshot(loadedCount: 7, total: 2, hasMore: false).footerLabel,
        '已载入 7 / 7 · 全部已载入',
      );
    });

    test('loaded==0 且非加载中 → 不出提示行（src:236-238）', () {
      final LibraryModalFrame f =
          panel().buildSaved(s: snapshot(), x: x, y: y, width: w);
      expect(
        f.commands.whereType<HudTextCommand>().where(
            (HudTextCommand c) => c.value.startsWith('已载入 ')),
        isEmpty,
      );
    });
  });

  group('状态直接由 Qt 模型字段表达（不造派生枚举）', () {
    test('未登录 / loading / 空集合 / hasMore 均读源字段', () {
      final LibraryModalSnapshot loggedOut = snapshot();
      expect(loggedOut.rows, isEmpty);
      expect(loggedOut.sourceLoading, isFalse);
      expect(loggedOut.loginEntryAllowed, isTrue); // 未登录入口条件

      final LibraryModalSnapshot loading = snapshot(sourceLoading: true);
      expect(loading.sourceLoading, isTrue);
      expect(loading.rows, isEmpty);

      final LibraryModalSnapshot empty = snapshot(uid: 'u');
      expect(empty.loginEntryAllowed, isFalse);
      expect(empty.rows, isEmpty);

      final LibraryModalSnapshot noMore =
          snapshot(rows: <LibraryRowRef>[songRow(0)], hasMore: false);
      expect(noMore.hasMore, isFalse);
      expect(noMore.rows, hasLength(1));
      expect(noMore.footerHint, '全部已载入');
    });
  });

  group('ensureSavedFilled 去重（Qt/src/NativeHudLibrary.cpp:256-268）', () {
    test('首屏不足一屏补一次页；同条数不重复', () {
      final RecordingPorts ports = RecordingPorts();
      final LibraryModalController c = LibraryModalController(ports: ports);
      expect(c.savedAutoFillSize, -1);

      final LibraryModalSnapshot s2 =
          snapshot(rows: <LibraryRowRef>[songRow(0), songRow(1)]);
      expect(c.ensureSavedFilled(s: s2, closing: false), isTrue);
      expect(ports.loadMoreCount, 1);
      expect(c.savedAutoFillSize, 2);

      // 条数未变 → 不补
      expect(c.ensureSavedFilled(s: s2, closing: false), isFalse);
      expect(ports.loadMoreCount, 1);

      // 条数增加但仍不足一屏 → 再补一次
      final LibraryModalSnapshot s3 =
          snapshot(rows: List<LibraryRowRef>.generate(3, songRow));
      expect(c.ensureSavedFilled(s: s3, closing: false), isTrue);
      expect(ports.loadMoreCount, 2);
      expect(c.savedAutoFillSize, 3);
    });

    test('已满一屏（>=6 行）不补页，但记录 size', () {
      final RecordingPorts ports = RecordingPorts();
      final LibraryModalController c = LibraryModalController(ports: ports);
      final LibraryModalSnapshot s =
          snapshot(rows: List<LibraryRowRef>.generate(6, songRow));
      expect(c.ensureSavedFilled(s: s, closing: false), isFalse);
      expect(ports.loadMoreCount, 0);
      expect(c.savedAutoFillSize, 6);
    });

    test('closing / sourceLoading / !hasMore / 非 saved 一律不补', () {
      final RecordingPorts ports = RecordingPorts();
      final LibraryModalController c = LibraryModalController(ports: ports);
      final LibraryModalSnapshot base = snapshot(rows: <LibraryRowRef>[songRow(0)]);
      expect(c.ensureSavedFilled(s: base, closing: true), isFalse);
      expect(
        c.ensureSavedFilled(
            s: snapshot(rows: <LibraryRowRef>[songRow(0)], sourceLoading: true),
            closing: false),
        isFalse,
      );
      expect(
        c.ensureSavedFilled(
            s: snapshot(rows: <LibraryRowRef>[songRow(0)], hasMore: false),
            closing: false),
        isFalse,
      );
      expect(
        c.ensureSavedFilled(
            s: snapshot(modal: 'search', rows: <LibraryRowRef>[songRow(0)]),
            closing: false),
        isFalse,
      );
      expect(ports.loadMoreCount, 0);
      expect(c.savedAutoFillSize, -1);
    });

    test('resetAutoFill 回到 -1', () {
      final RecordingPorts ports = RecordingPorts();
      final LibraryModalController c = LibraryModalController(ports: ports);
      c.ensureSavedFilled(
          s: snapshot(rows: <LibraryRowRef>[songRow(0)]), closing: false);
      expect(c.savedAutoFillSize, 1);
      c.resetAutoFill();
      expect(c.savedAutoFillSize, -1);
    });
  });

  group('动作分派（action 字符串 → 端口）', () {
    test('所有 Qt 动作串都能映射到端口方法', () {
      final RecordingPorts ports = RecordingPorts();
      final LibraryModalController c = LibraryModalController(ports: ports);
      expect(c.dispatch('music:create-playlist'), isTrue);
      expect(c.dispatch('music:refresh-personal'), isTrue);
      expect(c.dispatch('music:collection:3'), isTrue);
      expect(c.dispatch('music:group:1'), isTrue);
      expect(c.dispatch('music:group-back'), isTrue);
      expect(c.dispatch('music:login'), isTrue);
      expect(c.dispatch('close-modal'), isTrue);

      expect(ports.createCount, 1);
      expect(ports.refreshCount, 1);
      expect(ports.collections, <int>[3]);
      expect(ports.groupKeys, <String>['artist']);
      expect(ports.backCount, 1);
      expect(ports.loginCount, 1);
      expect(ports.closeCount, 1);
    });

    test('未知 action / 越界 group / 非法序号返回 false 且不触端口', () {
      final RecordingPorts ports = RecordingPorts();
      final LibraryModalController c = LibraryModalController(ports: ports);
      expect(c.dispatch('music:group:9'), isFalse);
      expect(c.dispatch('music:group:-1'), isFalse);
      expect(c.dispatch('music:group:x'), isFalse);
      expect(c.dispatch('music:collection:x'), isFalse);
      expect(c.dispatch('music:unknown'), isFalse);
      expect(ports.groupKeys, isEmpty);
      expect(ports.collections, isEmpty);
    });

    test('scrollTo 夹到 [0, maximum]', () {
      final RecordingPorts ports = RecordingPorts();
      final LibraryModalController c = LibraryModalController(ports: ports);
      c.scrollTo(-50, savedRowCount: 10);
      c.scrollTo(9999, savedRowCount: 10);
      expect(ports.scrolls[0], 0);
      expect(ports.scrolls[1], closeTo(720 - 430, 1e-9));
    });

    test('dispatchHit 走命中 action', () {
      final RecordingPorts ports = RecordingPorts();
      final LibraryModalController c = LibraryModalController(ports: ports);
      const HudHit hit = HudHit(
        x: 0,
        y: 0,
        width: 1,
        height: 1,
        action: 'music:login',
        label: '登录网易云音乐 →',
      );
      expect(c.dispatchHit(hit), isTrue);
      expect(ports.loginCount, 1);
    });
  });

  group('hit 六字段与 flatarray 契约（Qt/src/NativeHud.cpp:102-109）', () {
    test('字段名与顺序固定', () {
      const HudHit hit = HudHit(
        x: 1,
        y: 2,
        width: 3,
        height: 4,
        action: 'a',
        label: 'l',
      );
      expect(hit.toFlatArray(), <Object?>[1, 2, 3, 4, 'a', 'l']);
      expect(hit.toJson().keys.toList(),
          <String>['x', 'y', 'width', 'height', 'action', 'label']);
    });

    test('hitsFlatArray 长度 = 6 * hits，顺序与 hits 一致', () {
      final LibraryModalFrame f = panel().buildSaved(
        s: snapshot(provider: 'qq', activeGroup: 'g', groupBy: 'album'),
        x: x,
        y: y,
        width: w,
      );
      final List<Object?> flat = f.hitsFlatArray();
      expect(flat.length, f.hits.length * 6);
      expect(flat[0], f.hits.first.x);
      expect(flat[4], f.hits.first.action);
      expect(flat[5], f.hits.first.label);
      expect(
        flat.sublist(0, 6),
        f.hits.first.toFlatArray(),
      );
    });

    test('空集合时无行命中，firstRowHit 位于末尾', () {
      final LibraryModalFrame f =
          panel().buildSaved(s: snapshot(), x: x, y: y, width: w);
      expect(f.firstRowHit, f.hits.length);
      expect(f.savedRowCount, 0);
    });
  });

  group('缺失依赖显式暴露（禁止假数据兜底）', () {
    test('有行但无 rowPainter → notes 记 row-painter-missing，不造行命中', () {
      final LibraryModalFrame f = panel().buildSaved(
        s: snapshot(rows: <LibraryRowRef>[songRow(0), songRow(1)]),
        x: x,
        y: y,
        width: w,
      );
      expect(f.notes, contains('row-painter-missing'));
      expect(f.hits.where((HudHit h) => h.action.startsWith('music:row:')), isEmpty);
    });

    test('modal=search 未注入委托即抛错，不虚构搜索面板', () {
      expect(
        () => panel().buildLibraryPanel(
          snapshot: snapshot(modal: 'search'),
          x: x,
          y: y,
          width: w,
        ),
        throwsStateError,
      );
    });
  });

  group('竖屏响应式（新规格，无 Qt 竖屏像素证据）', () {
    test('断点：600 / 900', () {
      expect(LibraryPortraitSpec.resolveForm(599), LibraryPortraitForm.compact);
      expect(LibraryPortraitSpec.resolveForm(600), LibraryPortraitForm.medium);
      expect(LibraryPortraitSpec.resolveForm(899), LibraryPortraitForm.medium);
      expect(LibraryPortraitSpec.resolveForm(900), LibraryPortraitForm.expanded);
      expect(LibraryPortraitSpec.gutterFor(LibraryPortraitForm.compact), 16);
      expect(LibraryPortraitSpec.gutterFor(LibraryPortraitForm.medium), 20);
      expect(LibraryPortraitSpec.gutterFor(LibraryPortraitForm.expanded), 24);
    });

    test('竖屏堆叠单调递减且 viewport 非负', () {
      final LibraryPortraitPlan plan =
          LibraryPortraitPlan.resolve(x: 0, y: 0, width: 400, height: 800);
      expect(plan.form, LibraryPortraitForm.compact);
      expect(plan.gutter, 16);
      expect(plan.barRect.left, 16);
      expect(plan.barRect.width, 400 - 32);
      expect(plan.barRect.height, LibraryPortraitSpec.barHeight);
      expect(plan.actionRowRect.top, plan.barRect.bottom + LibraryPortraitSpec.barGap);
      expect(plan.tabRect.top, plan.actionRowRect.bottom + LibraryPortraitSpec.barGap);
      expect(plan.tabRuleY, plan.tabRect.bottom);
      expect(plan.sortRect.top, plan.tabRuleY + LibraryPortraitSpec.barGap);
      expect(plan.headerRect.top, plan.sortRect.bottom + 6);
      expect(plan.headerRuleY, plan.headerRect.bottom);
      expect(plan.viewport.top, plan.headerRuleY + 1);
      expect(plan.footerRect.top, 800 - LibraryPortraitSpec.footerHeight);
      expect(plan.viewport.height, greaterThanOrEqualTo(0));
    });

    test('竖屏命中沿用横屏 action 串，并标注新规格 note', () {
      const LibraryPortraitPanel portrait =
          LibraryPortraitPanel(metrics: metrics);
      final LibraryModalFrame f = portrait.build(
        s: snapshot(
          provider: 'qq',
          providerName: 'QQ音乐',
          activeGroup: 'g',
          groupBy: 'artist',
          rows: <LibraryRowRef>[songRow(0)],
          laneHasSong: true,
        ),
        x: 0,
        y: 0,
        width: 400,
        height: 800,
      );
      expect(f.notes, contains('portrait-layout-is-new-spec-no-qt-pixels'));
      expect(f.hitsFor('music:create-playlist'), hasLength(1));
      expect(f.hitsFor('music:refresh-personal'), hasLength(1));
      expect(f.hitsFor('music:collection:1'), hasLength(1));
      expect(f.hitsFor('music:group:0'), hasLength(1));
      expect(f.hitsFor('music:group-back'), hasLength(1));
      expect(f.hitsFor('music:group-back').single.label, '全部分组');
      expect(f.hitsFor('music:create-playlist').single.label, '创建歌单');
      expect(f.hitsFor('music:refresh-personal').single.label, '刷新个人库');
      // 窄幅下标签行超出即止，不越界
      for (final HudHit h in f.hits) {
        if (h.action.startsWith('music:collection:')) {
          expect(h.x + h.width, lessThanOrEqualTo(400 - 16 + 1e-9));
        }
      }
    });

    test('竖屏空集合给同语义登录入口', () {
      const LibraryPortraitPanel portrait =
          LibraryPortraitPanel(metrics: metrics);
      final LibraryModalFrame f = portrait.build(
        s: snapshot(providerName: '网易云音乐'),
        x: 0,
        y: 0,
        width: 400,
        height: 800,
      );
      final HudHit login = onlyHit(f.hits, 'music:login');
      expect(login.label, '登录网易云音乐 →');
      expect(login.width, lessThanOrEqualTo(300));
      expect(login.height, 44);
    });
  });
}
