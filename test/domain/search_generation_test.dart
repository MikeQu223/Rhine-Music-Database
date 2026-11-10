// Qt -> Flutter 迁移 T22：搜索领域片（去抖 / 代数 / 取消 / 旧响应丢弃 / 白名单）。
//
// 规范来源（引用用「文件 + 符号名」，不写行号：根文件仍在追加片段，行号必漂）：
// - Qt/src/MusicLibrary.cpp  search / suggest / loadMoreSource / showSource
// - Qt/src/MusicLocal.cpp    searchLocal
// - Qt/src/NativeHudController.cpp  setQuery 的 700ms 合并、closeModal 的 ++m_searchGeneration
// - Qt/src/NativeHudMusic.cpp       hint / kind 点击不排队
// - Qt/src/MusicApi.cpp      send 的 valid() 丢弃与错误文案
//
// 断言里的中文文案、阈值与键名逐字取自 Qt 源码。
//
// 仓库本阶段禁止运行验证：本文件仅编写、未执行（RED/GREEN 均未执行）。
// 计划执行入口（待授权）：flutter test test/domain/search_generation_test.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/domain/library/music_library.dart';

// ---------------------------------------------------------------------------
// 测试替身（必须实现端口的所有成员：Dart 的 implements 不允许缺成员）
// ---------------------------------------------------------------------------

class _Prefs implements LibraryPreferencesPort {
  _Prefs([Map<String, String>? values]) : values = values ?? <String, String>{};

  final Map<String, String> values;

  @override
  String? read(String key) => values[key];

  @override
  void write(String key, String value) => values[key] = value;
}

class _Host implements LibraryHostPort {
  @override
  bool authenticated = false;

  @override
  bool offline = false;

  @override
  bool localEnabled = true;

  /// Qt Host::fromLink 的返回值：空串表示「不是链接」。
  String link = '';

  @override
  Future<void> acceptCookies(String cookies, int epoch, String credentialKey) async {}

  @override
  Future<void> clearCache() async {}

  @override
  String fromLink(String text) => link;

  @override
  bool hasCredential(String provider) => authenticated;

  @override
  Future<void> invalidateMetadata() async {}

  @override
  Future<String?> loadCover(String url) async => null;

  @override
  Future<void> logout() async {
    authenticated = false;
  }

  @override
  Future<void> openExternal(String url) async {}

  @override
  Future<void> playOfficial(String id, void Function(String message) done) async {}

  @override
  String qr(String key) => '';

  @override
  String qrImage(String data) => '';

  @override
  Future<String> saveCredential() async => '';

  @override
  Cancelable schedule(Duration delay, void Function() action) => _Task(delay, action);

  @override
  Future<void> setKugouEdition(String edition) async {}

  @override
  Future<void> setProvider(String provider) async {}
}

/// 宿主请求端口：默认把请求挂起，由用例决定何时、以何顺序回填应答。
class _Wire implements HostRequestPort {
  final List<({String route, JsonMap params})> calls = <({String route, JsonMap params})>[];
  final List<Completer<HostReply>> pending = <Completer<HostReply>>[];

  /// 非空时立即应答（用于不需要控制时序的用例）。
  HostReply Function(String route, JsonMap params)? auto;

  @override
  Future<HostReply> requestJson(String route, JsonMap params) {
    calls.add((route: route, params: params));
    final HostReply Function(String route, JsonMap params)? handler = auto;
    if (handler != null) {
      return Future<HostReply>.value(handler(route, params));
    }
    final Completer<HostReply> completer = Completer<HostReply>();
    pending.add(completer);
    return completer.future;
  }

  /// Qt MusicApi::call 的 args 数组（/native/<provider>/<op> 的 params['args']）。
  List<Object?> argsOf(int index) => (calls[index].params['args'] as List<Object?>?) ?? <Object?>[];
}

class _Playback implements PlaybackPort {
  @override
  JsonMap current = <String, Object?>{};

  @override
  String coverImage = '';

  @override
  List<JsonMap> queueItems = <JsonMap>[];

  @override
  List<String> queueIds = <String>[];

  @override
  int queueIndex = -1;

  @override
  int queueSize = 0;

  @override
  List<JsonMap> history = <JsonMap>[];

  @override
  void Function()? onChanged;

  @override
  void Function(JsonMap value)? onTrackSelected;

  @override
  void clearCaches() {}

  @override
  void clearHistory() => history.clear();

  @override
  void loadQueue(List<String> ids, List<JsonMap> items) {
    queueIds = List<String>.of(ids);
    queueItems = List<JsonMap>.of(items);
    queueSize = ids.length;
  }

  @override
  void play(JsonMap track, {List<JsonMap>? source}) {
    current = track;
  }

  @override
  int queueIndexOfId(String id) => queueIds.indexOf(id);

  @override
  void remove(int index) {
    if (index < 0 || index >= queueItems.length) {
      return;
    }
    queueItems.removeAt(index);
    if (index < queueIds.length) {
      queueIds.removeAt(index);
    }
    queueSize = queueItems.length;
  }

  @override
  void stop() {
    current = <String, Object?>{};
  }
}

class _Local implements LocalMusicPort {
  _Local(this._songs);

  final List<JsonMap> _songs;
  int searchCount = 0;

  @override
  bool busy = false;

  @override
  String status = '';

  @override
  void cancel() {}

  @override
  List<JsonMap> collections(String kind) => <JsonMap>[];

  @override
  bool contains(String path) => false;

  @override
  void importPaths(List<String> paths) {}

  @override
  List<JsonMap> search(String query, String kind) {
    searchCount++;
    return List<JsonMap>.of(_songs);
  }

  @override
  List<JsonMap> songs() => List<JsonMap>.of(_songs);

  @override
  List<JsonMap> tracks(JsonMap collection) => <JsonMap>[];
}

/// 可手动推进的调度器：记录 delay 归属，flush 时执行尚未取消的动作。
class _Scheduler implements SchedulerPort {
  final List<_Task> tasks = <_Task>[];

  @override
  Cancelable schedule(Duration delay, void Function() action) {
    final _Task task = _Task(delay, action);
    tasks.add(task);
    return task;
  }

  Iterable<_Task> get ready => tasks.where((_Task task) => !task.cancelled && !task.ran);

  Future<void> flush() async {
    for (final _Task task in ready.toList()) {
      task.ran = true;
      task.action();
    }
    await _settle();
  }
}

class _Task implements Cancelable {
  _Task(this.delay, this.action);

  final Duration delay;
  final void Function() action;
  bool cancelled = false;
  bool ran = false;

  @override
  void cancel() => cancelled = true;
}

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

JsonMap _song(String id, {String title = '曲'}) {
  return <String, Object?>{
    'kind': 'song',
    'id': id,
    'title': title,
    'artist': '歌手',
    'artists': <Object?>[],
    'provider': 'netease',
    'key': 'netease:song:' + id,
  };
}

/// 搜索结果页（Qt MusicLibrary::search 回调读取 items/rawCount/more/total/notice）。
HostReply _page(List<String> ids, {int? total, bool more = false, int? rawCount, String notice = ''}) {
  return HostReply(<String, Object?>{
    'code': 200,
    'value': <String, Object?>{
      'items': <Object?>[for (final String id in ids) _song(id)],
      'total': total ?? ids.length,
      'more': more,
      'rawCount': rawCount ?? ids.length,
      'notice': notice,
    },
  });
}

HostReply _suggestions(List<String> words) {
  return HostReply(<String, Object?>{
    'code': 200,
    'result': <String, Object?>{
      'allMatch': <Object?>[
        for (final String word in words) <String, Object?>{'keyword': word},
      ],
    },
  });
}

/// 搜索结果栏不放记录：physicalSlots[0] 为空时 observe 直接返回，
/// 检索用例因此不依赖 choose/详情链路的其余片段。
JsonMap _content() {
  return <String, Object?>{
    'records': <Object?>[
      <String, Object?>{'kind': 'song', 'id': '1', 'title': '甲', 'category': '喜欢的歌曲'},
    ],
  };
}

({MusicLibrary library, _Prefs prefs, _Host host, _Wire wire, _Scheduler scheduler}) _build({
  String provider = 'netease',
  LocalMusicPort? local,
}) {
  final _Prefs prefs = _Prefs(<String, String>{'provider': provider, 'kugou-edition': 'standard'});
  final _Host host = _Host();
  final _Wire wire = _Wire();
  final _Scheduler scheduler = _Scheduler();
  final MusicLibrary library = MusicLibrary(
    host: host,
    preferences: prefs,
    requests: wire,
    content: _content(),
    player: _Playback(),
    scheduler: scheduler,
    local: local,
  );
  // 夹具保持已登录态：详情/收藏链路以 uid 判定，空值会改写 status。
  // 注意：根文件 showSource 现已在 lane 0 早退（对应 Qt MusicLibrary::showSource 的 lane > 0 守卫），
  // 因此检索用例不会经过 uid 分支；此处保留 uid 只为其它链路的登录态前置。
  library.uid = 'u1';
  return (library: library, prefs: prefs, host: host, wire: wire, scheduler: scheduler);
}

Future<void> _settle() async {
  for (var index = 0; index < 8; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('代数：旧响应不能覆盖新查询', () {
    test('先发 A 再发 B，B 先回生效，A 迟到被整体丢弃', () async {
      final built = _build();
      await built.library.search('A');
      await built.scheduler.flush();
      expect(built.wire.calls, hasLength(1));

      await built.library.search('B');
      await built.scheduler.flush();
      expect(built.wire.calls, hasLength(2));
      expect(built.wire.argsOf(1), <Object?>['B', 'song', 0]);

      built.wire.pending[1].complete(_page(<String>['b1'], total: 1));
      await _settle();
      expect(built.library.lists[0].single['id'], 'b1');
      expect(built.library.totals[0], 1);
      expect(built.library.status, '找到 1 条结果');

      built.wire.pending[0].complete(_page(<String>['a1', 'a2'], total: 9));
      await _settle();
      expect(built.library.lists[0].map((JsonMap item) => item['id']), <String>['b1']);
      expect(built.library.totals[0], 1);
      expect(built.library.status, '找到 1 条结果');
      expect(built.library.searchCursor, 1);
      expect(built.library.searchLoading, isFalse);
    });

    test('cancelSearch 只作废排队动作；在途应答与 Qt 一样仍落地', () async {
      final built = _build();
      await built.library.search('夜航星');
      await built.scheduler.flush();
      expect(built.library.searchLoading, isTrue);
      final int generation = built.library.generation;

      built.library.cancelSearch();
      // Qt NativeHud::closeModal 只 ++m_searchGeneration（HUD 层），不动 m_generation。
      expect(built.library.generation, generation);
      expect(built.library.searchLoading, isTrue);

      built.wire.pending.single.complete(_page(<String>['late'], total: 7));
      await _settle();
      expect(built.library.lists[0].single['id'], 'late');
      expect(built.library.totals[0], 7);
      expect(built.library.status, '找到 7 条结果');
      expect(built.library.searchLoading, isFalse);
    });

    test('cancelSearch 作废已排队的 700ms 合并动作', () async {
      final built = _build();
      await built.library.search('甲');
      expect(built.scheduler.tasks, hasLength(1));
      expect(built.scheduler.ready, hasLength(1));

      built.library.cancelSearch();
      expect(built.scheduler.ready, isEmpty);
      await built.scheduler.flush();
      expect(built.wire.calls, isEmpty);
    });
  });

  group('防抖合并', () {
    test('700ms 窗口内连续输入只发最后一次，前一次被取消', () async {
      final built = _build();
      await built.library.search('a');
      await built.library.search('ab');
      expect(built.scheduler.tasks, hasLength(2));
      expect(built.scheduler.tasks.first.cancelled, isTrue);
      expect(built.scheduler.tasks.last.delay, librarySearchDebounce);
      expect(librarySearchDebounce, const Duration(milliseconds: 700));

      await built.scheduler.flush();
      expect(built.wire.calls, hasLength(1));
      expect(built.wire.argsOf(0), <Object?>['ab', 'song', 0]);
      expect(built.wire.calls.single.route, '/native/netease/search');

      built.wire.pending.single.complete(_page(<String>['ab1']));
      await _settle();
      expect(built.library.keyword, 'ab');
      expect(built.library.lists[0].single['id'], 'ab1');
    });

    test('续页（more）不排队，直接按 searchCursor 发出', () async {
      final built = _build();
      built.library.keyword = '夜航星';
      built.library.searchCursor = 8;
      built.library.hasMore[0] = true;
      built.wire.auto = (String route, JsonMap params) => _page(<String>['x'], more: true);

      await built.library.search('夜航星', more: true);
      expect(built.scheduler.tasks, isEmpty);
      expect(built.wire.argsOf(0), <Object?>['夜航星', 'song', 8]);
    });

    test('切分类不排队，并作废排队中的合并动作（只发一次请求）', () async {
      final built = _build();
      built.wire.auto = (String route, JsonMap params) => _page(<String>['k']);

      await built.library.search('甲');
      expect(built.scheduler.ready, hasLength(1));

      await built.library.search('甲', kind: 'album');
      // 排队任务被 cancel（仍留在 tasks 里），可执行集合必须为空。
      expect(built.scheduler.ready, isEmpty);
      expect(built.wire.calls, hasLength(1));
      expect(built.wire.argsOf(0), <Object?>['甲', 'album', 0]);
      expect(built.library.searchKind, 'album');

      await built.scheduler.flush();
      // 排队任务已被作废：不会再补发一次 'search'。
      expect(built.wire.calls, hasLength(1));
    });
  });

  group('最近搜索白名单', () {
    test('上限 12、去重置顶并写回 search-history', () async {
      final built = _build();
      built.wire.auto = (String route, JsonMap params) => _page(<String>['x']);
      for (var index = 1; index <= 13; index++) {
        await built.library.search('q' + index.toString());
        await built.scheduler.flush();
      }

      expect(built.library.searchHistory, hasLength(librarySearchHistoryLimit));
      expect(built.library.searchHistory.first, 'q13');
      expect(built.library.searchHistory.last, 'q2');
      expect(built.library.searchHistory.contains('q1'), isFalse);

      final Object? stored = jsonDecode(built.prefs.read('search-history') ?? '[]');
      expect(stored, built.library.searchHistory);

      await built.library.search('q5');
      await built.scheduler.flush();
      expect(built.library.searchHistory, hasLength(librarySearchHistoryLimit));
      expect(built.library.searchHistory.first, 'q5');
      expect(built.library.searchHistory.where((String value) => value == 'q5'), hasLength(1));
    });

    test('空词与超长词清空旧结果并给出 Qt 文案', () async {
      final built = _build();
      built.library.keyword = 'old';
      built.library.lists[0] = <JsonMap>[_song('old')];
      built.library.totals[0] = 1;
      built.library.hasMore[0] = true;
      built.library.searchCursor = 20;
      built.wire.auto = (String route, JsonMap params) => _page(<String>['ok']);

      await built.library.search('   ', kind: 'song');
      expect(built.library.status, '请输入 1–100 字关键词');
      expect(built.library.lists[0], isEmpty);
      expect(built.library.totals[0], 0);
      expect(built.library.hasMore[0], isFalse);
      expect(built.library.searchCursor, 0);

      final builtQq = _build(provider: 'qq');
      await builtQq.library.search('x' * 61, kind: 'song');
      expect(builtQq.library.status, '请输入 1–60 字关键词');
      expect(builtQq.wire.calls, isEmpty);

      await built.library.search('x' * 100, kind: 'song');
      expect(built.wire.calls, hasLength(1));
      expect(built.wire.argsOf(0), <Object?>['x' * 100, 'song', 0]);
    });

    test('同词同分类且已有结果时不重复发车', () async {
      final built = _build();
      built.wire.auto = (String route, JsonMap params) => _page(<String>['a']);
      await built.library.search('夜航星', kind: 'song');
      expect(built.wire.calls, hasLength(1));
      await built.library.search('夜航星', kind: 'song');
      expect(built.wire.calls, hasLength(1));
    });
  });

  group('分页与结果页', () {
    test('more 续页按 key 去重合并，游标按 rawCount 推进', () async {
      final built = _build();
      built.library.keyword = '夜航星';
      built.library.lists[0] = <JsonMap>[_song('a')];
      built.library.totals[0] = 1;
      built.library.hasMore[0] = true;
      built.library.searchCursor = 20;
      built.wire.auto = (String route, JsonMap params) =>
          _page(<String>['a', 'b'], total: 42, more: true, rawCount: 2);

      await built.library.search('夜航星', more: true);
      expect(built.wire.argsOf(0), <Object?>['夜航星', 'song', 20]);
      expect(built.library.lists[0].map((JsonMap item) => item['id']), <String>['a', 'b']);
      expect(built.library.searchCursor, 22);
      expect(built.library.hasMore[0], isTrue);
      expect(built.library.totals[0], 42);
      expect(built.library.status, '找到 42 条结果');
    });

    test('more 在检索中或已无更多时不发请求（Qt 续页守卫）', () async {
      final built = _build();
      built.library.hasMore[0] = true;
      built.library.searchLoading = true;
      await built.library.search('夜航星', more: true);
      expect(built.wire.calls, isEmpty);

      built.library.searchLoading = false;
      built.library.hasMore[0] = false;
      await built.library.search('夜航星', more: true);
      expect(built.wire.calls, isEmpty);
    });

    test('首屏空结果给 Qt 空态文案，并回到归档态', () async {
      final built = _build();
      built.library.frame['mode'] = 'detail';
      built.wire.auto = (String route, JsonMap params) => _page(<String>[]);
      await built.library.search('没有的结果', kind: 'song');
      expect(built.library.lists[0], isEmpty);
      expect(built.library.totals[0], 0);
      expect(built.library.status, '没有匹配的音乐');
      expect(built.library.offsets[0], 0);
      expect(built.library.modeRequests, contains('archive'));
      expect(built.library.frame['mode'], 'archive');
    });

    test('notice 优先作为状态文案', () async {
      final built = _build();
      built.wire.auto = (String route, JsonMap params) =>
          _page(<String>['n1'], notice: '已按相关度排序');
      await built.library.search('夜航星', kind: 'song');
      expect(built.library.status, '已按相关度排序');
    });

    test('检索失败沿用 Qt 文案，不落地旧结果', () async {
      final built = _build();
      built.wire.auto = (String route, JsonMap params) =>
          const HostReply(<String, Object?>{'code': 500, 'message': '上游超时'});
      await built.library.search('夜航星', kind: 'song');
      expect(built.library.status, '检索失败：上游超时');
      expect(built.library.searchLoading, isFalse);
      expect(built.library.lists[0], isEmpty);
    });
  });

  group('链接与本地渠道', () {
    test('网易云链接直接成为唯一结果并进入对应模式', () async {
      final built = _build();
      built.host.link = 'song:123';
      await built.library.search('https://music.163.com/song?id=123', kind: 'song');
      expect(built.wire.calls, isEmpty);
      expect(built.library.lists[0].single['id'], '123');
      expect(built.library.lists[0].single['kind'], 'song');
      expect(built.library.totals[0], 1);
      expect(built.library.hasMore[0], isFalse);
      expect(built.library.keyword, 'https://music.163.com/song?id=123');
      expect(built.library.wantsSongDetails, isTrue);
      expect(built.library.modeRequests, contains('detail'));
    });

    test('本地渠道整表替换 lists[0]，不发远端请求', () async {
      final _Local local = _Local(<JsonMap>[_song('l1'), _song('l2')]);
      final built = _build(provider: 'local', local: local);
      // 构造期 bootstrap 会 unawaited(refreshLocal())，先等它落地再断言，避免竞态。
      await _settle();
      final int before = local.searchCount;

      await built.library.search('夜');
      await built.scheduler.flush();
      expect(built.wire.calls, isEmpty);
      expect(built.library.lists[0], hasLength(2));
      expect(built.library.totals[0], 2);
      expect(built.library.hasMore[0], isFalse);
      expect(built.library.status, '本地检索：2 条结果');
      expect(built.library.modeRequests, contains('archive'));
      expect(local.searchCount, before + 1);
    });

    test('本地渠道没有在线续页（Qt loadMoreSource 首行 return）', () async {
      final _Local local = _Local(<JsonMap>[_song('l1')]);
      final built = _build(provider: 'local', local: local);
      await _settle();
      final int before = local.searchCount;

      await built.library.search('夜', more: true);
      expect(local.searchCount, before);
      expect(built.wire.calls, isEmpty);
    });
  });

  group('联想', () {
    test('最多 4 条，网易走 /search/suggest 的 keywords/type', () async {
      final built = _build();
      built.wire.auto = (String route, JsonMap params) =>
          _suggestions(<String>['a1', 'a2', 'a3', 'a4', 'a5']);
      built.library.suggest('a');
      await _settle();
      expect(built.wire.calls.single.route, '/search/suggest');
      expect(built.wire.calls.single.params, <String, Object?>{'keywords': 'a', 'type': 'mobile'});
      expect(built.library.suggestions, <String>['a1', 'a2', 'a3', 'a4']);
    });

    test('后发联想覆盖先发，先发迟到不写入', () async {
      final built = _build();
      built.library.suggest('a');
      built.library.suggest('ab');
      expect(built.wire.calls, hasLength(2));

      built.wire.pending[1].complete(_suggestions(<String>['ab1']));
      await _settle();
      expect(built.library.suggestions, <String>['ab1']);

      built.wire.pending[0].complete(_suggestions(<String>['a1']));
      await _settle();
      expect(built.library.suggestions, <String>['ab1']);
    });

    test('QQ 走 /qq/getSmartbox 并取 name 字段', () async {
      final built = _build(provider: 'qq');
      built.wire.auto = (String route, JsonMap params) => const HostReply(<String, Object?>{
        'code': 200,
        'response': <String, Object?>{
          'data': <String, Object?>{
            'song': <String, Object?>{
              'itemlist': <Object?>[
                <String, Object?>{'name': 'q1'},
              ],
            },
          },
        },
      });
      built.library.suggest('q');
      await _settle();
      expect(built.wire.calls.single.route, '/qq/getSmartbox');
      expect(built.wire.calls.single.params, <String, Object?>{'key': 'q'});
      expect(built.library.suggestions, <String>['q1']);
    });

    test('空词与酷狗不请求联想，但先清空旧联想', () async {
      final built = _build();
      built.library.suggestions = <String>['旧'];
      built.library.suggest('   ');
      await _settle();
      expect(built.wire.calls, isEmpty);
      expect(built.library.suggestions, isEmpty);

      final kugou = _build(provider: 'kugou');
      kugou.library.suggest('a');
      await _settle();
      expect(kugou.wire.calls, isEmpty);
    });
  });
}
