
/// Qt 发现页移植的契约测试（未执行：RED 状态）。
///
/// 断言逐条对应 Qt 证据：
/// * Qt/tests/NativeHudChecks.cpp:1159-1331（外框、五列、滚轮 75、aspect、分类 40 分页）
/// * Qt/src/MusicDiscover.cpp:16-211（load/accept/loadCategories/cancel/open）
/// * Qt/src/NativeHudDiscover.cpp:9-148（tabs/tools/categories/scrollScope/artwork 装配）
/// * Qt/src/NativeHudController.cpp:576-619（discover: 分发与 scroll 归零）
///
/// 本文件与 lib/hud/modals/discover_modal.dart 同批交付；依赖文件 A
/// lib/hud/widgets/discover_card.dart（owner: W1）的冻结接口。
library;

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/discover_modal.dart';
import 'package:rhine_music_database/hud/widgets/discover_card.dart';

// ---------------------------------------------------------------------------
// 测试替身：只实现注入端口，不引入任何真实平台代码
// ---------------------------------------------------------------------------

class RecordedCall {
  RecordedCall.call(this.operation, this.arguments)
      : parameters = null;

  RecordedCall.request(this.operation, this.parameters)
      : arguments = null;

  final String operation;
  final List<Object?>? arguments;
  final DiscoverJson? parameters;
}

class FakeApi implements DiscoverApiPort {
  final List<RecordedCall> calls = <RecordedCall>[];
  void Function(DiscoverReply)? replyCall;
  void Function(DiscoverReply)? replyRequest;
  bool Function()? validCall;
  bool Function()? validRequest;
  Set<int>? allowedRequest;

  @override
  void call(
    String operation,
    List<Object?> arguments,
    void Function(DiscoverReply) reply, {
    bool Function()? valid,
  }) {
    calls.add(RecordedCall.call(operation, arguments));
    replyCall = reply;
    validCall = valid;
  }

  @override
  void request(
    String route,
    DiscoverJson parameters,
    void Function(DiscoverReply) reply, {
    bool Function()? valid,
    Set<int>? allowed,
  }) {
    calls.add(RecordedCall.request(route, parameters));
    replyRequest = reply;
    validRequest = valid;
    allowedRequest = allowed;
  }

  /// 等价于 Qt/src/MusicApi.cpp:98：valid 不成立时回调直接丢弃。
  bool deliverCall(DiscoverReply reply) {
    final handler = replyCall;
    final gate = validCall;
    if (handler == null || (gate != null && !gate())) {
      return false;
    }
    handler(reply);
    return true;
  }

  bool deliverRequest(DiscoverReply reply) {
    final handler = replyRequest;
    final gate = validRequest;
    if (handler == null || (gate != null && !gate())) {
      return false;
    }
    handler(reply);
    return true;
  }

  RecordedCall get last {
    return calls.last;
  }
}

class FakeHost implements DiscoverHostPort {
  FakeHost({
    this.provider = 'netease',
    this.uid = '',
    this.accountGeneration = 0,
    this.providerName = '网易云音乐',
  });

  @override
  String provider;

  @override
  String uid;

  @override
  int accountGeneration;

  @override
  String providerName;

  @override
  List<DiscoverJson> history = <DiscoverJson>[];

  @override
  final Set<String> subscriptions = <String>{};

  final List<String> events = <String>[];
  int changedCount = 0;
  bool? privateSelection;
  List<DiscoverJson>? playContext;
  DiscoverJson? played;
  List<DiscoverJson>? playedContext;
  DiscoverJson? chosen;
  DiscoverJson? enteredDirectory;
  final List<String> modes = <String>[];
  int openDailyCalls = 0;
  bool openDailyResult = false;

  @override
  void changed() {
    changedCount++;
    events.add('changed');
  }

  @override
  void setPrivateSelection(bool value) {
    privateSelection = value;
  }

  @override
  void setPlayContext(List<DiscoverJson> values) {
    playContext = values;
  }

  @override
  void play(DiscoverJson value, List<DiscoverJson> context) {
    played = value;
    playedContext = context;
  }

  @override
  void choose(DiscoverJson value) {
    chosen = value;
  }

  @override
  void enterDirectory(DiscoverJson value) {
    enteredDirectory = value;
  }

  @override
  void modeRequested(String mode) {
    modes.add(mode);
  }

  @override
  bool openDaily() {
    openDailyCalls++;
    return openDailyResult;
  }
}

class FakeData implements DiscoverDataPort {
  /// 复刻 Qt/src/MusicData.cpp:41-80：id 必须是 1-20 位数字且 name 是字符串。
  @override
  DiscoverJson? parseItem(DiscoverJson raw, String kind) {
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || !RegExp(r'^[0-9]{1,20}$').hasMatch(id) || name is! String) {
      return null;
    }
    final provider = raw['provider'] is String ? raw['provider'] as String : 'netease';
    return <String, Object?>{
      'kind': kind,
      'id': id,
      'title': name,
      'artist': raw['artist'] is String ? raw['artist'] : '',
      'cover': raw['cover'] is String ? raw['cover'] : '',
      'provider': provider,
      'key': provider + ':' + kind + ':' + id,
    };
  }
}

class FakeCovers implements DiscoverCoverProbe {
  final Map<String, DiscoverCover> sizes = <String, DiscoverCover>{};

  @override
  DiscoverCover? cover(String key) {
    return sizes[key];
  }
}

/// 可驱动的封面加载器：记录 show 期间的 url 与 512 尺寸，回调手动触发。
class FakeCoverLoader {
  final List<String> urls = <String>[];
  final List<int> sizes = <int>[];
  final List<void Function(String)> callbacks = <void Function(String)>[];
  int invalidateCount = 0;

  void load(String url, void Function(String) done, int size) {
    urls.add(url);
    sizes.add(size);
    callbacks.add(done);
  }

  void invalidate() {
    invalidateCount++;
  }

  void complete(int index, String key) {
    callbacks[index](key);
  }
}

DiscoverJson item(
  int id, {
  String kind = 'playlist',
  String cover = '',
  String provider = 'netease',
  String title = '',
}) {
  return <String, Object?>{
    'id': id.toString(),
    'name': title.isEmpty ? 'item-' + id.toString() : title,
    'artist': 'artist-' + id.toString(),
    'cover': cover,
    'provider': provider,
  };
}

List<DiscoverJson> items(int count, {String cover = '', String kind = 'playlist'}) {
  return <DiscoverJson>[
    for (var index = 0; index < count; index++)
      item(index + 1, kind: kind, cover: cover),
  ];
}

/// 组装被测对象；返回 (state, host, api, data)。
class Harness {
  Harness({String provider = 'netease', String uid = '', int account = 0}) {
    host = FakeHost(provider: provider, uid: uid, accountGeneration: account);
    api = FakeApi();
    data = FakeData();
    state = MusicDiscoverState(host: host, api: api, data: data);
  }

  late final FakeHost host;
  late final FakeApi api;
  late final FakeData data;
  late final MusicDiscoverState state;
  final DiscoverPanelState panel = DiscoverPanelState();
  final FakeCovers covers = FakeCovers();
  final FakeCoverLoader loader = FakeCoverLoader();

  DiscoverArtwork artwork() {
    return DiscoverArtwork(load: loader.load, invalidate: loader.invalidate);
  }

  DiscoverModel panelModel({double width = 1260}) {
    return buildDiscoverPanel(
      x: 40,
      y: 0,
      width: width,
      discover: state,
      host: host,
      panel: panel,
      dark: false,
      artwork: artwork(),
      covers: covers,
    );
  }
}

void main() {
  group('MusicDiscover.load 路由与参数（Qt/src/MusicDiscover.cpp:16-122）', () {
    test('默认 playlists 走 /personalized limit=30 field=result', () {
      final harness = Harness();
      harness.state.load();
      expect(harness.api.calls.length, 1);
      expect(harness.api.last.operation, '/personalized');
      expect(harness.api.last.parameters, <String, Object?>{'limit': 30});
      // Qt 不显式传 allowed，宿主按 MusicApi.h:24 的默认 {200} 判定。
      expect(harness.api.allowedRequest, isNull);
      expect(harness.state.loading, isTrue);
      expect(harness.state.status, '正在读取…');
      expect(harness.state.items, isEmpty);
      expect(harness.host.changedCount, 1);

      expect(
        harness.api.deliverRequest(
          DiscoverReply(value: <String, Object?>{
            'result': items(2),
          }),
        ),
        isTrue,
      );
      expect(harness.state.items.length, 2);
      expect(harness.state.loading, isFalse);
      expect(harness.state.offset, 2);
      expect(harness.state.more, isFalse);
      expect(harness.state.status, '已载入 2 条');
      expect(harness.host.changedCount, 2);
      expect(harness.state.items.first['key'], 'netease:playlist:1');
    });

    test('daily 走 /recommend/songs，kind=song，优先 data.dailySongs', () {
      final harness = Harness(uid: '42');
      harness.state.load('daily');
      expect(harness.api.last.operation, '/recommend/songs');
      expect(harness.api.last.parameters, isEmpty);
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'data': <String, Object?>{
            'dailySongs': <Object?>[item(7), item(8)],
          },
          'recommend': <Object?>[item(9)],
        }),
      );
      expect(harness.state.items.length, 2);
      expect(harness.state.items.first['kind'], 'song');
      expect(harness.state.items.first['key'], 'netease:song:7');
    });

    test('daily 回退 recommend 字段', () {
      final harness = Harness(uid: '42');
      harness.state.load('daily');
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'recommend': <Object?>[item(3)],
        }),
      );
      expect(harness.state.items.length, 1);
      expect(harness.state.items.first['id'], '3');
    });

    test('charts 走 /toplist field=list', () {
      final harness = Harness();
      harness.state.load('charts');
      expect(harness.api.last.operation, '/toplist');
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'list': <Object?>[item(11)],
        }),
      );
      expect(harness.state.items.length, 1);
      expect(harness.state.items.first['kind'], 'playlist');
    });

    test('albums 走 /album/newest field=albums kind=album', () {
      final harness = Harness();
      harness.state.load('albums');
      expect(harness.api.last.operation, '/album/newest');
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'albums': <Object?>[item(12)],
        }),
      );
      expect(harness.state.items.length, 1);
      expect(harness.state.items.first['kind'], 'album');
    });

    test('categories 走 /top/playlist 并带 cat/limit/offset', () {
      final harness = Harness();
      harness.state.category = '华语';
      harness.state.load('categories');
      expect(harness.api.last.operation, '/top/playlist');
      expect(harness.api.last.parameters, <String, Object?>{
        'cat': '华语',
        'limit': 30,
        'offset': 0,
      });
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'playlists': <Object?>[item(13)],
          'more': true,
        }),
      );
      expect(harness.state.more, isTrue);
      expect(harness.state.offset, 1);

      harness.state.load('categories', true);
      expect(harness.api.last.parameters, <String, Object?>{
        'cat': '华语',
        'limit': 30,
        'offset': 1,
      });
    });

    test('artists 走 /artist/sublist 并读 hasMore', () {
      final harness = Harness(uid: '42');
      harness.state.load('artists');
      expect(harness.api.last.operation, '/artist/sublist');
      expect(harness.api.last.parameters, <String, Object?>{
        'limit': 30,
        'offset': 0,
      });
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'data': <Object?>[item(21)],
          'hasMore': true,
        }),
      );
      expect(harness.state.more, isTrue);
      expect(harness.state.items.first['kind'], 'artist');
      expect(harness.host.subscriptions, contains('netease:artist:21'));
    });

    test('未知类别直接拒绝，不发请求', () {
      final harness = Harness();
      harness.state.load('mystery');
      expect(harness.api.calls, isEmpty);
      expect(harness.state.loading, isFalse);
      expect(harness.state.status, '不支持的发现类别');
    });

    test('非 netease 来源走 api.call(discover, [tab, start, arg])', () {
      final harness = Harness(provider: 'qq');
      harness.state.load();
      expect(harness.api.last.operation, 'discover');
      expect(harness.api.last.arguments, <Object?>['playlists', 0, '全部']);

      harness.state.load('new-songs');
      expect(harness.api.last.arguments, <Object?>['new-songs', 0, '5']);
      harness.state.newSongArea = '3';
      harness.state.load('new-songs');
      expect(harness.api.last.arguments, <Object?>['new-songs', 0, '3']);
    });
  });

  group('登录门与历史过滤（Qt/src/MusicDiscover.cpp:32-50）', () {
    test('daily 未登录不发请求并给出文案', () {
      final harness = Harness();
      harness.state.load('daily');
      expect(harness.api.calls, isEmpty);
      expect(harness.state.status, '登录后查看每日推荐');
      expect(harness.state.loading, isFalse);
    });

    test('guess 未登录同文案', () {
      final harness = Harness(provider: 'qq');
      harness.state.load('guess');
      expect(harness.api.calls, isEmpty);
      expect(harness.state.status, '登录后查看每日推荐');
    });

    test('artists 非 netease 给出网易云文案', () {
      final harness = Harness(provider: 'qq', uid: '42');
      harness.state.load('artists');
      expect(harness.api.calls, isEmpty);
      expect(harness.state.status, '登录网易云后查看收藏歌手');
    });

    test('artists netease 未登录给出文案', () {
      final harness = Harness(provider: 'netease');
      harness.state.load('artists');
      expect(harness.api.calls, isEmpty);
      expect(harness.state.status, '登录网易云后查看收藏歌手');
    });

    test('history 按 provider 过滤且 more=false、offset 归零', () {
      final harness = Harness(provider: 'netease');
      harness.host.history = <DiscoverJson>[
        <String, Object?>{'key': 'netease:song:1', 'provider': 'netease', 'title': 'a'},
        <String, Object?>{'key': 'qq:song:2', 'provider': 'qq', 'title': 'b'},
        <String, Object?>{'key': 'netease:song:3', 'title': 'c'},
      ];
      harness.state.more = true;
      harness.state.offset = 9;
      harness.state.load('history');
      expect(harness.api.calls, isEmpty);
      expect(harness.state.items.length, 2);
      expect(harness.state.more, isFalse);
      // Qt/src/MusicDiscover.cpp:25 start = append ? offset : 0；:137 offset = start + rawCount，
      // history 分支 rawCount 恒为 0，所以这里必须归零而不是保留 9。
      expect(harness.state.offset, 0);
      expect(harness.state.status, '已载入 2 条');
    });

    test('history 缺少 provider 字段按 netease 处理', () {
      final harness = Harness(provider: 'qq');
      harness.host.history = <DiscoverJson>[
        <String, Object?>{'key': 'netease:song:1', 'title': 'a'},
        <String, Object?>{'key': 'qq:song:2', 'provider': 'qq', 'title': 'b'},
      ];
      harness.state.load('history');
      expect(harness.state.items.length, 1);
      expect(harness.state.items.first['key'], 'qq:song:2');
    });
  });

  group('more 守卫与代数失效（Qt/src/MusicDiscover.cpp:17-24、9-13）', () {
    test('more=false 时 append 早退', () {
      final harness = Harness();
      harness.state.load();
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'result': <Object?>[item(1)],
        }),
      );
      final calls = harness.api.calls.length;
      harness.state.load('playlists', true);
      expect(harness.api.calls.length, calls);
      expect(harness.state.offset, 1);
    });

    test('loading 时 append 早退', () {
      final harness = Harness();
      harness.state.more = true;
      harness.state.load();
      final calls = harness.api.calls.length;
      harness.state.load('playlists', true);
      expect(harness.api.calls.length, calls);
    });

    test('cancel 递增 generation 后旧回调不得改写列表', () {
      final harness = Harness();
      harness.state.load();
      harness.state.cancel();
      expect(harness.state.loading, isFalse);
      expect(
        harness.api.deliverRequest(
          DiscoverReply(value: <String, Object?>{
            'result': <Object?>[item(1), item(2)],
          }),
        ),
        isFalse,
      );
      expect(harness.state.items, isEmpty);
      // Qt cancel 不复位 status（MusicDiscover.cpp:183-194）。
      expect(harness.state.status, '正在读取…');
    });

    test('accountGeneration 变化后旧回调不得改写列表', () {
      final harness = Harness(account: 3);
      harness.state.load();
      harness.host.accountGeneration = 4;
      expect(
        harness.api.deliverRequest(
          DiscoverReply(value: <String, Object?>{
            'result': <Object?>[item(1)],
          }),
        ),
        isFalse,
      );
      expect(harness.state.items, isEmpty);
      expect(harness.state.loading, isTrue);
    });

    test('切 tab 后旧回调不得写入新 tab', () {
      final harness = Harness();
      harness.state.load('charts');
      harness.state.load('albums');
      expect(
        harness.api.deliverRequest(
          DiscoverReply(value: <String, Object?>{
            'list': <Object?>[item(1)],
          }),
        ),
        isFalse,
      );
      expect(harness.state.items, isEmpty);
      expect(harness.state.tab, 'albums');
    });

    test('loadCategories 也受 generation 守卫', () {
      final harness = Harness(provider: 'qq');
      harness.state.loadCategories();
      expect(harness.api.last.operation, 'categories');
      harness.state.cancel();
      expect(
        harness.api.deliverCall(
          DiscoverReply(value: <Object?>[<String, Object?>{'id': 'a', 'name': 'a'}]),
        ),
        isFalse,
      );
      expect(harness.state.categories, isEmpty);
    });
  });

  group('accept 语义（Qt/src/MusicDiscover.cpp:124-150）', () {
    test('错误只写 status，不动 items 与 offset', () {
      final harness = Harness();
      harness.state.load();
      harness.api.deliverRequest(const DiscoverReply(error: '网络错误'));
      expect(harness.state.status, '网络错误');
      expect(harness.state.loading, isFalse);
      expect(harness.state.items, isEmpty);
      expect(harness.state.offset, 0);
      expect(harness.host.changedCount, 2);
    });

    test('append 按 key 去重且保留原序', () {
      final harness = Harness();
      harness.state.tab = 'categories';
      harness.state.more = true;
      harness.state.load('categories');
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'playlists': <Object?>[item(1), item(2)],
          'more': true,
        }),
      );
      harness.state.load('categories', true);
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'playlists': <Object?>[item(2), item(3)],
          'more': false,
        }),
      );
      expect(
        harness.state.items.map((value) => value['key']).toList(),
        <String>['netease:playlist:1', 'netease:playlist:2', 'netease:playlist:3'],
      );
      // offset 用原始条数（含重复），不是去重后条数。
      expect(harness.state.offset, 4);
      expect(harness.state.status, '已载入 3 条');
      expect(harness.state.more, isFalse);
    });

    test('非 append 直接替换列表', () {
      final harness = Harness();
      harness.state.load();
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'result': <Object?>[item(1)],
        }),
      );
      harness.state.load();
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'result': <Object?>[item(2)],
        }),
      );
      expect(harness.state.items.length, 1);
      expect(harness.state.items.first['key'], 'netease:playlist:2');
      expect(harness.state.offset, 1);
    });

    test('空页给暂无内容', () {
      final harness = Harness();
      harness.state.load();
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{'result': <Object?>[]}),
      );
      expect(harness.state.status, '暂无内容');
      expect(harness.state.items, isEmpty);
    });

    test('qq categories 页回写 category', () {
      final harness = Harness(provider: 'qq');
      harness.state.load('categories');
      harness.api.deliverCall(
        DiscoverReply(value: <String, Object?>{
          'items': <Object?>[item(1)],
          'category': '民谣',
          'rawCount': 1,
          'more': false,
        }),
      );
      expect(harness.state.category, '民谣');
    });

    test('非 qq 的 categories 页不回写 category', () {
      final harness = Harness();
      harness.state.load('categories');
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'playlists': <Object?>[item(1)],
          'category': '民谣',
        }),
      );
      expect(harness.state.category, '全部');
    });

    test('playlists 不读 body.more（Qt 只在 categories/artists 读）', () {
      final harness = Harness();
      harness.state.load();
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'result': <Object?>[item(1)],
          'more': true,
        }),
      );
      expect(harness.state.items.length, 1);
      expect(harness.state.more, isFalse);
    });

    test('new-songs 回写 areas 与 area', () {
      final harness = Harness(provider: 'qq');
      harness.state.load('new-songs');
      harness.api.deliverCall(
        DiscoverReply(value: <String, Object?>{
          'items': <Object?>[item(1)],
          'areas': <Object?>[
            <String, Object?>{'id': 1, 'name': '华语'},
            <String, Object?>{'id': 5, 'name': '欧美'},
          ],
          'area': 5,
          'rawCount': 1,
          'more': false,
        }),
      );
      expect(harness.state.newSongAreas.length, 2);
      expect(harness.state.newSongAreas.first['name'], '华语');
      expect(harness.state.newSongArea, '5');
    });

    test('parse 过滤非法项但 rawCount 保留原始条数', () {
      final harness = Harness();
      harness.state.load();
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'result': <Object?>[
            item(1),
            <String, Object?>{'id': 'abc', 'name': 'bad'},
            <String, Object?>{'id': '2'},
          ],
        }),
      );
      expect(harness.state.items.length, 1);
      expect(harness.state.offset, 3);
    });
  });

  group('cancel 复位（Qt/src/MusicDiscover.cpp:183-194）', () {
    test('cancel 清空全部字段且不动 status', () {
      final harness = Harness(uid: '42');
      harness.state
        ..tab = 'artists'
        ..items = <DiscoverJson>[item(1)]
        ..loading = true
        ..more = true
        ..offset = 30
        ..category = '华语'
        ..categories = <DiscoverJson>[<String, Object?>{'id': 'a', 'name': 'a'}]
        ..newSongAreas = <DiscoverJson>[<String, Object?>{'id': 1, 'name': 'x'}]
        ..newSongArea = '7'
        ..status = '已载入 1 条';
      final generation = harness.state.generation;
      harness.state.cancel();
      expect(harness.state.generation, generation + 1);
      expect(harness.state.tab, 'playlists');
      expect(harness.state.items, isEmpty);
      expect(harness.state.loading, isFalse);
      expect(harness.state.more, isFalse);
      expect(harness.state.offset, 0);
      expect(harness.state.categories, isEmpty);
      expect(harness.state.newSongAreas, isEmpty);
      expect(harness.state.newSongArea, '5');
      expect(harness.state.category, '全部');
      expect(harness.state.status, '已载入 1 条');
    });
  });

  group('open 分支（Qt/src/MusicDiscover.cpp:196-211）', () {
    test('越界不产生任何副作用', () {
      final harness = Harness();
      harness.state.items = <DiscoverJson>[item(1, kind: 'song')];
      harness.state.open(1);
      harness.state.open(-1);
      expect(harness.host.played, isNull);
      expect(harness.host.privateSelection, isNull);
      expect(harness.host.playContext, isNull);
    });

    test('song 走 play + choose + modeRequested(detail)', () {
      final harness = Harness(uid: '42');
      final song = item(5, kind: 'song');
      harness.state
        ..tab = 'daily'
        ..items = <DiscoverJson>[song, item(6, kind: 'song')];
      harness.state.open(0);
      expect(harness.host.privateSelection, isTrue);
      expect(harness.host.playContext!.length, 2);
      expect(harness.host.played!['key'], 'netease:song:5');
      expect(harness.host.playedContext!.length, 2);
      expect(harness.host.chosen!['key'], 'netease:song:5');
      expect(harness.host.modes, <String>['detail']);
      expect(harness.host.enteredDirectory, isNull);
    });

    test('非 song 走 enterDirectory 且不播放', () {
      final harness = Harness();
      harness.state
        ..tab = 'playlists'
        ..items = <DiscoverJson>[item(9, kind: 'playlist')];
      harness.state.open(0);
      expect(harness.host.privateSelection, isFalse);
      expect(harness.host.enteredDirectory!['key'], 'netease:playlist:9');
      expect(harness.host.played, isNull);
      expect(harness.host.chosen, isNull);
      expect(harness.host.modes, isEmpty);
    });
  });

  group('discoverPanel 装配（Qt/src/NativeHudDiscover.cpp:9-148）', () {
    test('netease tabs 顺序与 action', () {
      final harness = Harness();
      final model = harness.panelModel();
      expect(
        model.tabs.map((choice) => choice.label).toList(),
        <String>['推荐歌单', '每日推荐', '排行榜', '新专辑', '分类歌单', '收藏歌手', '历史'],
      );
      expect(
        model.tabs.map((choice) => choice.action).toList(),
        <String>[
          'discover:tab:playlists',
          'discover:tab:daily',
          'discover:tab:charts',
          'discover:tab:albums',
          'discover:tab:categories',
          'discover:tab:artists',
          'discover:tab:history',
        ],
      );
      expect(model.tabs.first.selected, isTrue);
      expect(model.tabs.where((choice) => choice.selected).length, 1);
      expect(model.bounds, const Rect.fromLTWH(40, 0, 1260, 836));
      expect(model.dark, isFalse);
    });

    test('qq tabs 插入 guess/new-songs 且 daily 文案不同', () {
      final harness = Harness(provider: 'qq');
      final model = harness.panelModel();
      expect(
        model.tabs.map((choice) => choice.label).toList(),
        <String>['推荐歌单', '每日 30 首', '猜你喜欢', '新歌速递', '排行榜', '新专辑', '分类歌单', '历史'],
      );
      expect(model.tabs[2].action, 'discover:tab:guess');
      expect(model.tabs[3].action, 'discover:tab:new-songs');
    });

    test('其它来源 tabs 只有基线与历史', () {
      final harness = Harness(provider: 'kugou');
      final model = harness.panelModel();
      expect(
        model.tabs.map((choice) => choice.action).toList(),
        <String>[
          'discover:tab:playlists',
          'discover:tab:daily',
          'discover:tab:charts',
          'discover:tab:albums',
          'discover:tab:categories',
          'discover:tab:history',
        ],
      );
      expect(model.tabs[1].label, '每日推荐');
    });

    test('playlists 页 tools 给每日推荐入口', () {
      final harness = Harness();
      final model = harness.panelModel();
      expect(model.tools.length, 1);
      expect(model.tools.first.label, '每日推荐 ↗');
      expect(model.tools.first.action, 'discover:tab:daily');
      expect(model.tools.first.selected, isFalse);
    });

    test('daily 页 tool 给资料库打开', () {
      final harness = Harness(uid: '42');
      harness.state.tab = 'daily';
      final model = harness.panelModel();
      expect(model.tools.single.label, '在资料库打开 ↗');
      expect(model.tools.single.action, 'discover:open');
    });

    test('guess 页 tool 给换一批', () {
      final harness = Harness(provider: 'qq', uid: '42');
      harness.state.tab = 'guess';
      final model = harness.panelModel();
      expect(model.tools.single.label, '换一批推荐 ↻');
      expect(model.tools.single.action, 'discover:tab:guess');
    });

    test('new-songs 页按 areas 生成 tool 并标 selected', () {
      final harness = Harness(provider: 'qq');
      harness.state
        ..tab = 'new-songs'
        ..newSongAreas = <DiscoverJson>[
          <String, Object?>{'id': 1, 'name': '华语'},
          <String, Object?>{'id': 5, 'name': '欧美'},
        ]
        ..newSongArea = '5';
      final model = harness.panelModel();
      expect(model.tools.map((choice) => choice.action).toList(),
          <String>['discover:area:1', 'discover:area:5']);
      expect(model.tools.map((choice) => choice.label).toList(), <String>['华语', '欧美']);
      expect(model.tools.map((choice) => choice.selected).toList(), <bool>[false, true]);
    });

    test('categories 非 picker 只给分类按钮', () {
      final harness = Harness();
      harness.state.tab = 'categories';
      final model = harness.panelModel();
      expect(model.categoryPicker, isFalse);
      expect(model.categories, isEmpty);
      expect(model.tools.single.label, '分类：全部 ↓');
      expect(model.tools.single.action, 'discover:categories');
    });

    test('categories picker 40 一页且前置全部', () {
      final harness = Harness();
      harness.state.tab = 'categories';
      harness.state.categories = <DiscoverJson>[
        for (var index = 0; index < 40; index++)
          <String, Object?>{'id': 'edge-' + index.toString(), 'name': 'edge-' + index.toString()},
      ];
      harness.panel.categoryPicker = true;
      final model = harness.panelModel();
      expect(model.categoryPicker, isTrue);
      expect(model.categoryPages, 2);
      expect(model.categoryPage, 0);
      expect(model.categories.length, 40);
      expect(model.categories.first.label, '全部');
      expect(model.categories.first.selected, isTrue);
      expect(model.categories[1].label, 'edge-0');
      expect(model.categories[1].action, 'discover:category:edge-0');
      expect(model.tools.single.label, '← 返回列表');
      expect(model.tools.single.action, 'discover:categories');
    });

    test('category-page:next 后第二页含 edge-39（NativeHudChecks.cpp:1318-1330）', () {
      final harness = Harness();
      harness.state.tab = 'categories';
      harness.state.categories = <DiscoverJson>[
        for (var index = 0; index < 40; index++)
          <String, Object?>{'id': 'edge-' + index.toString(), 'name': 'edge-' + index.toString()},
      ];
      harness.panel.categoryPicker = true;
      harness.panelModel();
      final result = handleDiscoverAction(
        'discover:category-page:next',
        discover: harness.state,
        host: harness.host,
        panel: harness.panel,
      );
      expect(result.handled, isTrue);
      expect(harness.panel.categoryPage, 1);
      final model = harness.panelModel();
      expect(model.categories.length, 1);
      expect(model.categories.single.label, 'edge-39');
      expect(model.categories.single.action, 'discover:category:edge-39');
    });

    test('qq 有分类时不前置全部', () {
      final harness = Harness(provider: 'qq');
      harness.state.tab = 'categories';
      harness.state.categories = <DiscoverJson>[
        <String, Object?>{'id': 'x', 'name': 'X'},
        <String, Object?>{'id': 'y', 'name': 'Y'},
      ];
      harness.panel.categoryPicker = true;
      final model = harness.panelModel();
      expect(model.categoryPages, 1);
      expect(model.categories.map((choice) => choice.label).toList(), <String>['X', 'Y']);
    });

    test('qq 分类为空时补全部', () {
      final harness = Harness(provider: 'qq');
      harness.state.tab = 'categories';
      harness.panel.categoryPicker = true;
      final model = harness.panelModel();
      expect(model.categories.single.label, '全部');
      expect(model.categories.single.selected, isTrue);
    });

    test('分类 id 做百分号编码', () {
      final harness = Harness();
      harness.state.tab = 'categories';
      harness.state.category = '全部';
      harness.state.categories = <DiscoverJson>[
        <String, Object?>{'id': '全部', 'name': '全部'},
        <String, Object?>{'id': 'a b', 'name': '含空格'},
      ];
      harness.panel.categoryPicker = true;
      final model = harness.panelModel();
      expect(model.categories.length, 3);
      expect(model.categories.first.action, 'discover:category:%E5%85%A8%E9%83%A8');
      expect(model.categories.first.selected, isTrue);
      expect(model.categories[1].selected, isTrue);
      expect(model.categories[2].action, 'discover:category:a%20b');
    });

    test('picker 时 visibleIndices 为空、entries 为空', () {
      final harness = Harness();
      harness.state.tab = 'categories';
      harness.state.items = items(10, cover: 'c1');
      harness.panel.categoryPicker = true;
      final model = harness.panelModel();
      expect(model.entries, isEmpty);
    });

    test('scrollScope 变化把 scroll 归零，同 tab 保留', () {
      final harness = Harness();
      harness.state.items = items(10);
      harness.panelModel();
      final maximum = harness.panel.scrollMaximum;
      expect(maximum, greaterThan(0));
      harness.panel.scroll = 120;
      harness.panelModel();
      expect(harness.panel.scroll, 120);

      harness.state.tab = 'charts';
      harness.panelModel();
      expect(harness.panel.scroll, 0);
      expect(harness.panel.scrollScope, 'netease:0:charts');
    });

    test('accountGeneration 变化也触发归零', () {
      final harness = Harness();
      harness.state.items = items(10);
      harness.panelModel();
      harness.panel.scroll = 100;
      harness.host.accountGeneration = 2;
      harness.panelModel();
      expect(harness.panel.scroll, 0);
      expect(harness.panel.scrollScope, 'netease:2:playlists');
    });

    test('scroll 超上限被 clamp 到 maximumScroll', () {
      final harness = Harness();
      harness.state.items = items(10);
      harness.panelModel();
      harness.panel.scroll = 99999;
      final model = harness.panelModel();
      expect(model.scroll, harness.panel.scrollMaximum);
    });

    test('封面：只有取到图才写 image/imageAspect，否则留空占位', () {
      final harness = Harness();
      harness.state.items = <DiscoverJson>[
        item(1, cover: 'a.jpg'),
        item(2, cover: 'b.jpg'),
      ];
      harness.covers.sizes['b.jpg'] = const DiscoverCover(200, 100);
      final artwork = harness.artwork();
      final model = buildDiscoverPanel(
        x: 0,
        y: 0,
        width: 1260,
        discover: harness.state,
        host: harness.host,
        panel: harness.panel,
        dark: true,
        artwork: artwork,
        covers: harness.covers,
      );
      expect(harness.loader.urls, <String>['a.jpg', 'b.jpg']);
      expect(harness.loader.sizes, <int>[512, 512]);
      expect(model.entries.length, 2);
      expect(model.entries.first.image, '');
      expect(model.entries.first.imageAspect, 1.0);
      harness.loader.complete(1, 'b.jpg');
      final refreshed = buildDiscoverPanel(
        x: 0,
        y: 0,
        width: 1260,
        discover: harness.state,
        host: harness.host,
        panel: harness.panel,
        dark: true,
        artwork: artwork,
        covers: harness.covers,
      );
      expect(harness.loader.invalidateCount, 1);
      expect(refreshed.entries[1].image, 'b.jpg');
      expect(refreshed.entries[1].imageAspect, 2.0);
      expect(refreshed.dark, isTrue);
    });

    test('scope+urls 不变时不重复加载封面', () {
      final harness = Harness();
      harness.state.items = <DiscoverJson>[item(1, cover: 'a.jpg')];
      final artwork = harness.artwork();
      DiscoverModel build() {
        return buildDiscoverPanel(
          x: 0,
          y: 0,
          width: 1260,
          discover: harness.state,
          host: harness.host,
          panel: harness.panel,
          dark: false,
          artwork: artwork,
          covers: harness.covers,
        );
      }

      build();
      build();
      expect(harness.loader.urls.length, 1);
    });

    test('generation 变化使旧封面回调作废', () {
      final harness = Harness();
      harness.state.items = <DiscoverJson>[item(1, cover: 'a.jpg')];
      final artwork = harness.artwork();
      artwork.show('netease:0:0', <String>['a.jpg']);
      harness.loader.complete(0, 'a.jpg');
      expect(artwork.image('a.jpg'), 'a.jpg');
      harness.state.generation = 9;
      artwork.show('netease:0:9', <String>['a.jpg']);
      expect(harness.loader.callbacks.length, 2);
      // scope 变化后先落空占位，旧回调一律作废。
      expect(artwork.image('a.jpg'), '');
      harness.loader.complete(0, 'stale');
      expect(artwork.image('a.jpg'), '');
      harness.loader.complete(1, 'a.jpg');
      expect(artwork.image('a.jpg'), 'a.jpg');
    });

    test('加载中的状态与计数透传', () {
      final harness = Harness();
      harness.state
        ..loading = true
        ..status = '正在读取…'
        ..more = true;
      harness.state.items = items(3);
      final model = harness.panelModel();
      expect(model.loading, isTrue);
      expect(model.more, isTrue);
      expect(model.status, '正在读取…');
      expect(model.loadedCount, 3);
      expect(model.tab, 'playlists');
    });
  });

  group('滚轮（Qt/src/NativeHudInput.cpp:60-74）', () {
    test('distance=75 精确累加（NativeHudChecks.cpp:1213-1230）', () {
      final harness = Harness();
      harness.state.items = items(10);
      harness.panelModel();
      final bounds = discoverModalBounds(1920);
      final viewport = DiscoverCard.layout(bounds, 10).viewport;
      final value = discoverWheel(
        discover: harness.state,
        panel: harness.panel,
        bounds: bounds,
        x: viewport.center.dx,
        y: viewport.center.dy,
        step: 1,
        distance: 75,
      );
      expect(value, 75);
      expect(harness.panel.scroll, 75);
    });

    test('无 distance 时按 step*60 步进', () {
      final harness = Harness();
      harness.state.items = items(10);
      harness.panelModel();
      final bounds = discoverModalBounds(1920);
      final viewport = DiscoverCard.layout(bounds, 10).viewport;
      final value = discoverWheel(
        discover: harness.state,
        panel: harness.panel,
        bounds: bounds,
        x: viewport.center.dx,
        y: viewport.center.dy,
        step: 2,
      );
      expect(value, 120);
    });

    test('distance=0 退回步进量（HudScroll.h:24）', () {
      final harness = Harness();
      harness.state.items = items(10);
      harness.panelModel();
      final bounds = discoverModalBounds(1920);
      final viewport = DiscoverCard.layout(bounds, 10).viewport;
      final value = discoverWheel(
        discover: harness.state,
        panel: harness.panel,
        bounds: bounds,
        x: viewport.center.dx,
        y: viewport.center.dy,
        step: 1,
        distance: 0,
      );
      expect(value, 60);
    });

    test('distance=0 时 movement 为 0，近尾不续载（NativeHudInput.cpp:64）', () {
      final harness = Harness();
      harness.state.items = items(12);
      harness.panelModel();
      final bounds = discoverModalBounds(1920);
      final viewport = DiscoverCard.layout(bounds, 12).viewport;
      // 416.8 - 30 + 60 落点被 clamp 到 416.8，movement 仍是 0（value_or 语义）。
      harness.panel.scroll = harness.panel.scrollMaximum - 30;
      harness.state.more = true;
      final value = discoverWheel(
        discover: harness.state,
        panel: harness.panel,
        bounds: bounds,
        x: viewport.center.dx,
        y: viewport.center.dy,
        step: 1,
        distance: 0,
      );
      expect(harness.panel.scrollMaximum, closeTo(416.8, 1e-9));
      expect(value, closeTo(416.8, 1e-9));
      expect(harness.api.calls, isEmpty);
    });

    test('viewport 外不滚动（标题区滚轮）', () {
      final harness = Harness();
      harness.state.items = items(10);
      harness.panelModel();
      final bounds = discoverModalBounds(1920);
      final value = discoverWheel(
        discover: harness.state,
        panel: harness.panel,
        bounds: bounds,
        x: bounds.center.dx,
        y: bounds.top + 150,
        step: 1,
        distance: 75,
      );
      expect(value, 0);
    });

    test('categoryPicker 时不滚动', () {
      final harness = Harness();
      harness.state.items = items(10);
      harness.panelModel();
      harness.panel.categoryPicker = true;
      final bounds = discoverModalBounds(1920);
      final viewport = DiscoverCard.layout(bounds, 10).viewport;
      final value = discoverWheel(
        discover: harness.state,
        panel: harness.panel,
        bounds: bounds,
        x: viewport.center.dx,
        y: viewport.center.dy,
        step: 1,
        distance: 75,
      );
      expect(value, 0);
    });

    test('near-end 且 more 时续载，loading 时不续载', () {
      final harness = Harness();
      harness.state.items = items(2);
      harness.panelModel();
      final bounds = discoverModalBounds(1920);
      final viewport = DiscoverCard.layout(bounds, 2).viewport;
      expect(harness.panel.scrollMaximum, 0);
      harness.state.more = true;
      discoverWheel(
        discover: harness.state,
        panel: harness.panel,
        bounds: bounds,
        x: viewport.center.dx,
        y: viewport.center.dy,
        step: 1,
        distance: 1000,
      );
      expect(harness.api.calls.length, 1);
      expect(harness.state.loading, isTrue);
      final calls = harness.api.calls.length;
      discoverWheel(
        discover: harness.state,
        panel: harness.panel,
        bounds: bounds,
        x: viewport.center.dx,
        y: viewport.center.dy,
        step: 1,
        distance: 1000,
      );
      expect(harness.api.calls.length, calls);
    });

    test('向上滚动不触发续载', () {
      final harness = Harness();
      harness.state.items = items(2);
      harness.panelModel();
      harness.state.more = true;
      final bounds = discoverModalBounds(1920);
      final viewport = DiscoverCard.layout(bounds, 2).viewport;
      discoverWheel(
        discover: harness.state,
        panel: harness.panel,
        bounds: bounds,
        x: viewport.center.dx,
        y: viewport.center.dy,
        step: -1,
        distance: -300,
      );
      expect(harness.api.calls, isEmpty);
    });
  });

  group('discover: 动作分发（Qt/src/NativeHudController.cpp:576-619）', () {
    test('tab 动作用 scroll 归零并清 picker', () {
      final harness = Harness();
      harness.panel
        ..scroll = 200
        ..categoryPicker = true
        ..categoryPage = 2;
      final result = handleDiscoverAction(
        'discover:tab:charts',
        discover: harness.state,
        host: harness.host,
        panel: harness.panel,
      );
      expect(result.handled, isTrue);
      expect(result.closeModal, isFalse);
      expect(harness.panel.scroll, 0);
      expect(harness.panel.categoryPicker, isFalse);
      expect(harness.panel.categoryPage, 0);
      expect(harness.state.tab, 'charts');
      expect(harness.api.last.operation, '/toplist');
    });

    test('tab:categories 且分类为空时补拉分类', () {
      final harness = Harness();
      handleDiscoverAction(
        'discover:tab:categories',
        discover: harness.state,
        host: harness.host,
        panel: harness.panel,
      );
      expect(
        harness.api.calls.map((call) => call.operation).toList(),
        <String>['/top/playlist', '/playlist/catlist'],
      );
    });

    test('item 动作总是关闭弹层', () {
      final harness = Harness();
      harness.state
        ..tab = 'playlists'
        ..items = <DiscoverJson>[item(1, kind: 'album')];
      final result = handleDiscoverAction(
        'discover:item:0',
        discover: harness.state,
        host: harness.host,
        panel: harness.panel,
      );
      expect(result.closeModal, isTrue);
      expect(harness.host.enteredDirectory!['key'], 'netease:album:1');

      final outOfRange = handleDiscoverAction(
        'discover:item:9',
        discover: harness.state,
        host: harness.host,
        panel: harness.panel,
      );
      expect(outOfRange.closeModal, isTrue);
    });

    test('open 动作用 openDaily 结果决定是否关闭', () {
      final harness = Harness();
      harness.host.openDailyResult = false;
      expect(
        handleDiscoverAction(
          'discover:open',
          discover: harness.state,
          host: harness.host,
          panel: harness.panel,
        ).closeModal,
        isFalse,
      );
      harness.host.openDailyResult = true;
      expect(
        handleDiscoverAction(
          'discover:open',
          discover: harness.state,
          host: harness.host,
          panel: harness.panel,
        ).closeModal,
        isTrue,
      );
      expect(harness.host.openDailyCalls, 2);
    });

    test('area 动作只在 qq 生效', () {
      final netease = Harness();
      final calls = netease.api.calls.length;
      handleDiscoverAction(
        'discover:area:3',
        discover: netease.state,
        host: netease.host,
        panel: netease.panel,
      );
      expect(netease.api.calls.length, calls);
      expect(netease.state.newSongArea, '5');

      final qq = Harness(provider: 'qq');
      qq.panel.scroll = 90;
      handleDiscoverAction(
        'discover:area:3',
        discover: qq.state,
        host: qq.host,
        panel: qq.panel,
      );
      expect(qq.state.newSongArea, '3');
      expect(qq.panel.scroll, 0);
      expect(qq.state.tab, 'new-songs');
    });

    test('categories 动作切换 picker 并在空列表时补拉', () {
      final harness = Harness();
      handleDiscoverAction(
        'discover:categories',
        discover: harness.state,
        host: harness.host,
        panel: harness.panel,
      );
      expect(harness.panel.categoryPicker, isTrue);
      expect(harness.api.last.operation, '/playlist/catlist');
      handleDiscoverAction(
        'discover:categories',
        discover: harness.state,
        host: harness.host,
        panel: harness.panel,
      );
      expect(harness.panel.categoryPicker, isFalse);
      expect(harness.panel.categoryPage, 0);
    });

    test('category 动作解码并回到列表页', () {
      final harness = Harness();
      harness.panel
        ..categoryPicker = true
        ..scroll = 300;
      handleDiscoverAction(
        'discover:category:%E5%8D%8E%E8%AF%AD',
        discover: harness.state,
        host: harness.host,
        panel: harness.panel,
      );
      expect(harness.state.category, '华语');
      expect(harness.panel.categoryPicker, isFalse);
      expect(harness.panel.scroll, 0);
      expect(harness.api.last.parameters, <String, Object?>{
        'cat': '华语',
        'limit': 30,
        'offset': 0,
      });
    });

    test('category-page 在边界处 clamp', () {
      final harness = Harness();
      harness.state.categories = <DiscoverJson>[
        for (var index = 0; index < 3; index++)
          <String, Object?>{'id': 'k' + index.toString(), 'name': 'k' + index.toString()},
      ];
      for (var index = 0; index < 5; index++) {
        handleDiscoverAction(
          'discover:category-page:prev',
          discover: harness.state,
          host: harness.host,
          panel: harness.panel,
        );
      }
      expect(harness.panel.categoryPage, 0);
      for (var index = 0; index < 5; index++) {
        handleDiscoverAction(
          'discover:category-page:next',
          discover: harness.state,
          host: harness.host,
          panel: harness.panel,
        );
      }
      expect(harness.panel.categoryPage, 0);
    });

    test('category-page 对 40 条 raw 分类得到 2 页', () {
      final harness = Harness();
      harness.state.categories = <DiscoverJson>[
        for (var index = 0; index < 40; index++)
          <String, Object?>{'id': 'edge-' + index.toString(), 'name': 'edge-' + index.toString()},
      ];
      harness.panel.categoryPage = 0;
      handleDiscoverAction(
        'discover:category-page:next',
        discover: harness.state,
        host: harness.host,
        panel: harness.panel,
      );
      expect(harness.panel.categoryPage, 1);
    });

    test('more 动作只对 categories/artists 读到的 more 续载', () {
      final harness = Harness();
      harness.state.category = '华语';
      harness.state.load('categories');
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'playlists': <Object?>[item(1)],
          'more': true,
        }),
      );
      expect(harness.state.more, isTrue);
      expect(harness.state.offset, 1);
      final calls = harness.api.calls.length;
      handleDiscoverAction(
        'discover:more',
        discover: harness.state,
        host: harness.host,
        panel: harness.panel,
      );
      expect(harness.api.calls.length, calls + 1);
      expect(harness.api.last.operation, '/top/playlist');
      expect(harness.api.last.parameters, <String, Object?>{
        'cat': '华语',
        'limit': 30,
        'offset': 1,
      });
    });

    test('more=false 时 more 动作早退', () {
      final harness = Harness();
      harness.state.category = '华语';
      harness.state.load('categories');
      harness.api.deliverRequest(
        DiscoverReply(value: <String, Object?>{
          'playlists': <Object?>[item(1)],
        }),
      );
      expect(harness.state.more, isFalse);
      final calls = harness.api.calls.length;
      handleDiscoverAction(
        'discover:more',
        discover: harness.state,
        host: harness.host,
        panel: harness.panel,
      );
      expect(harness.api.calls.length, calls);
    });

    test('local 来源不接受任何 discover 动作', () {
      final harness = Harness(provider: 'local');
      handleDiscoverAction(
        'discover:tab:daily',
        discover: harness.state,
        host: harness.host,
        panel: harness.panel,
      );
      expect(harness.api.calls, isEmpty);
      expect(harness.state.tab, 'playlists');
    });

    test('非 discover 前缀不处理', () {
      final harness = Harness();
      final result = handleDiscoverAction(
        'player:next',
        discover: harness.state,
        host: harness.host,
        panel: harness.panel,
      );
      expect(result.handled, isFalse);
      expect(harness.api.calls, isEmpty);
    });
  });

  group('modalBounds 与百分号编解码', () {
    test('三档舞台宽度的 discover 外框（NativeHudChecks.cpp:1159-1180）', () {
      final small = discoverModalBounds(1280);
      expect(small.left, 50);
      expect(small.top, 122);
      expect(small.width, 1180);
      expect(small.height, 836);

      final medium = discoverModalBounds(1920);
      expect(medium.left, 330);
      expect(medium.width, 1260);

      final large = discoverModalBounds(2560);
      expect(large.left, 650);
      expect(large.width, 1260);
    });

    test('percentEncode 只保留 unreserved 字符', () {
      expect(percentEncode('abcXYZ019-._~'), 'abcXYZ019-._~');
      expect(percentEncode('a b'), 'a%20b');
      expect(percentEncode('全部'), '%E5%85%A8%E9%83%A8');
      expect(percentEncode('a/b:c'), 'a%2Fb%3Ac');
    });

    test('percentDecode 与 percentEncode 互逆', () {
      expect(percentDecode(percentEncode('全部')), '全部');
      expect(percentDecode('a%20b'), 'a b');
      expect(percentDecode('plain'), 'plain');
      expect(percentDecode('%ZZ'), '%ZZ');
      expect(percentDecode('100%'), '100%');
    });

    test('分类每页 40 的页数计算与前置全部数学等价', () {
      expect(categoryAllCount('netease', 0), 1);
      expect(categoryAllCount('qq', 0), 1);
      expect(categoryAllCount('qq', 5), 0);
      expect(categoryAllCount('netease', 5), 1);

      expect(categoryPageCount('netease', 0), 1);
      expect(categoryPageCount('netease', 39), 1);
      expect(categoryPageCount('netease', 40), 2);
      expect(categoryPageCount('qq', 40), 1);
      expect(categoryPageCount('qq', 41), 2);
      expect(categoryPageCount('qq', 0), 1);
    });
  });
}
