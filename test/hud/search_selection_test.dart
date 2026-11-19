// 横屏检索面板的**分类 / 分组动作语义**测试。
//
// 被测文件：lib/hud/modals/search_modal.dart 的 (e2) 段
// 真值口径：Qt/src/NativeHudMusic.cpp:218-256 的 kind / group / expand / group-back 四个分支
//   kind:       ++m_searchGeneration; listOffset=0; resetResultViews(); activeGroup.clear();
//               kind = QStringList{"song","album","playlist","artist"}.value(last,"song");
//               text = query.isEmpty() ? music.keyword : query;
//               if (text.isEmpty()) music.searchKind = kind; else music.search(text, kind);
//   group:      setGroupView({},{},…); ++generation;
//               groupBy = QStringList{"none","artist","album"}.value(last,"none");
//               activeGroup.clear(); listOffset=0; resetResultViews();
//   expand:     ++generation; key = decode(value.mid(13)); activeGroup = key; …
//   group-back: setGroupView({},{},…); ++generation; activeGroup.clear(); …
// 以及 Qt/src/NativeHudSearch.cpp:85-88 的分组条出场条件（lists[0] 里存在 kind == "song" 的行）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/search_modal.dart';

void main() {
  group('动作串解析（Qt NativeHudMusic.cpp:218-256）', () {
    test('music:kind:<n> → 分类命令，越界回落 song', () {
      expect(searchSelectionCommand('music:kind:0'), isA<SearchKindCommand>());
      expect((searchSelectionCommand('music:kind:3')! as SearchKindCommand).kind, 'artist');
      expect((searchSelectionCommand('music:kind:1')! as SearchKindCommand).kind, 'album');
      expect((searchSelectionCommand('music:kind:2')! as SearchKindCommand).kind, 'playlist');
      // Qt `QStringList::value(last, "song")`
      expect((searchSelectionCommand('music:kind:9')! as SearchKindCommand).kind, 'song');
      expect(searchSelectionCommand('music:kind:abc'), isNull, reason: '下标不是整数时不猜');
    });

    test('music:group:<n> → 分组命令，越界回落 none', () {
      expect((searchSelectionCommand('music:group:0')! as SearchGroupCommand).groupBy, 'none');
      expect((searchSelectionCommand('music:group:1')! as SearchGroupCommand).groupBy, 'artist');
      expect((searchSelectionCommand('music:group:2')! as SearchGroupCommand).groupBy, 'album');
      expect((searchSelectionCommand('music:group:7')! as SearchGroupCommand).groupBy, 'none');
    });

    test('music:expand:<编码 key> → 展开命令，key 解百分号编码', () {
      final SearchExpandCommand command =
          searchSelectionCommand('music:expand:artist%3AKay%20%26%20Zeta')! as SearchExpandCommand;
      expect(command.key, 'artist:Kay & Zeta');
      // 非法转义时保留原文（Qt 的 fromPercentEncoding 宽容，从不丢点击）
      final SearchExpandCommand broken =
          searchSelectionCommand('music:expand:%ZZ')! as SearchExpandCommand;
      expect(broken.key, '%ZZ');
    });

    test('music:group-back → 返回命令；其它动作不归本层（null）', () {
      expect(searchSelectionCommand('music:group-back'), isA<SearchGroupBackCommand>());
      expect(searchSelectionCommand('music:result:0:3'), isNull);
      expect(searchSelectionCommand('mobile:search-submit'), isNull);
      expect(searchSelectionCommand(''), isNull);
    });
  });

  group('选中态 reducer', () {
    const SearchSelectionState base = SearchSelectionState(
      searchKind: 'song',
      groupBy: 'none',
      activeGroup: '',
      keyword: '已提交词',
      query: '在打的词',
    );

    test('分类点击：输入框非空时用输入框文本立刻重搜，并清空展开态', () {
      final SearchSelectionChange change = searchApplySelection(base, const SearchKindCommand(3));
      expect(change.state.searchKind, 'artist');
      expect(change.state.activeGroup, '');
      expect(change.state.listOffset, 0);
      expect(change.state.generation, 1, reason: 'Qt ++m_searchGeneration');
      expect(change.resetViews, isTrue);
      final SearchKindRun run = change.run!;
      expect(run.kind, 'artist');
      expect(run.text, '在打的词', reason: 'text = query.isEmpty() ? keyword : query');
    });

    test('分类点击：输入框为空时复用已提交词', () {
      final SearchSelectionState state = base.copyWith(query: '');
      final SearchKindRun run = searchApplySelection(state, const SearchKindCommand(1)).run!;
      expect(run.text, '已提交词');
      expect(run.kind, 'album');
    });

    test('分类点击：输入框与已提交词都空 → 只改选中态，不发检索', () {
      final SearchSelectionState state = base.copyWith(query: '', keyword: '');
      final SearchSelectionChange change = searchApplySelection(state, const SearchKindCommand(2));
      expect(change.run, isNull, reason: 'Qt music.searchKind = kind 分支');
      expect(change.state.searchKind, 'playlist');
    });

    test('分组点击：只换 groupBy 并清空展开态，不触发检索', () {
      final SearchSelectionState state = base.copyWith(groupBy: 'album', activeGroup: 'k');
      final SearchSelectionChange change = searchApplySelection(state, const SearchGroupCommand(1));
      expect(change.state.groupBy, 'artist');
      expect(change.state.activeGroup, '');
      expect(change.state.generation, state.generation + 1);
      expect(change.run, isNull);
    });

    test('展开分组：activeGroup = key，分类与分组键都不动', () {
      final SearchSelectionState state = base.copyWith(groupBy: 'artist');
      final SearchSelectionChange change =
          searchApplySelection(state, const SearchExpandCommand('artist:Kay'));
      expect(change.state.activeGroup, 'artist:Kay');
      expect(change.state.groupBy, 'artist');
      expect(change.state.searchKind, 'song');
      expect(change.state.generation, state.generation + 1);
      expect(change.run, isNull);
    });

    test('返回全部分组：清空 activeGroup，保留 groupBy', () {
      final SearchSelectionState state = base.copyWith(groupBy: 'album', activeGroup: 'album:CONTROL');
      final SearchSelectionChange change =
          searchApplySelection(state, const SearchGroupBackCommand());
      expect(change.state.activeGroup, '');
      expect(change.state.groupBy, 'album');
      expect(change.state.generation, state.generation + 1);
    });
  });

  group('分组条出场条件（Qt NativeHudSearch.cpp:85-88）', () {
    test('任一行的 kind == "song" 才显示分组条', () {
      expect(
        searchHasSongRows(<Map<String, Object?>>[
          <String, Object?>{'kind': 'album', 'title': 'A'},
          <String, Object?>{'kind': 'song', 'title': 'B'},
        ]),
        isTrue,
      );
      expect(
        searchHasSongRows(<Map<String, Object?>>[
          <String, Object?>{'kind': 'artist', 'title': 'C'},
        ]),
        isFalse,
      );
      expect(searchHasSongRows(const <Map<String, Object?>>[]), isFalse);
      expect(
        searchHasSongRows(<Map<String, Object?>>[
          <String, Object?>{'kind': 'group', 'title': 'G'},
        ]),
        isFalse,
        reason: '分组行（kind == group）不算 song 行',
      );
    });
  });
}
