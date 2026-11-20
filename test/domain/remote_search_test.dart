/// 远端（插件平台）分类检索的映射与状态串。
///
/// 真机取证：`netease` 的 `search` 返回
/// `{kind,id,title,artist,artists[],album,albumID,cover,duration,provider,key,trackCount}`，
/// 没有 `durationMs`；页面右列读 `durationMs`，所以这一层必须补。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/domain/search/remote_search.dart';
import 'package:rhine_music_database/provider/plugin_gateway.dart' show ProviderRequestError;
import 'package:rhine_music_database/provider/provider_gateway.dart';

/// 只实现 `search`/`playback` 的假网关，其余继承默认（抛不支持）。
class _FakeGateway implements ProviderGateway {
  _FakeGateway({this.items = const <Map<String, Object?>>[], this.error});

  final List<Map<String, Object?>> items;
  final Object? error;
  final List<(String, String, int)> calls = <(String, String, int)>[];

  @override
  String get providerId => 'fake';

  @override
  Future<List<Map<String, Object?>>> search({
    required String query,
    required ProviderSearchKind kind,
    required int start,
  }) async {
    calls.add((query, kind.id, start));
    final Object? failure = error;
    if (failure != null) {
      throw failure;
    }
    return items;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('插件条目补出 durationMs 与整数 trackCount，其余字段原样保留', () {
    final Map<String, Object?> row = remoteSearchRow(<String, Object?>{
      'kind': 'song',
      'id': '2668397359',
      'title': '晴天',
      'artist': '周杰伦',
      'album': '叶惠美',
      'cover': 'https://p3.music.126.net/a.jpg',
      'duration': 270738,
      'provider': 'netease',
      'key': 'netease:song:2668397359',
    });
    expect(row['durationMs'], 270738);
    expect(row['trackCount'], 0);
    expect(row['artist'], '周杰伦');
    expect(row['album'], '叶惠美');
    expect(row['cover'], 'https://p3.music.126.net/a.jpg');
    expect(row['key'], 'netease:song:2668397359');
  });

  test('分类 key 映射到插件枚举，未知 key 退回歌曲', () {
    expect(remoteSearchKind('song'), ProviderSearchKind.song);
    expect(remoteSearchKind('artist'), ProviderSearchKind.artist);
    expect(remoteSearchKind('album'), ProviderSearchKind.album);
    expect(remoteSearchKind('playlist'), ProviderSearchKind.playlist);
    expect(remoteSearchKind('nonsense'), ProviderSearchKind.song);
  });

  test('有命中：状态串与 Qt 一致，hasMore 按页长判断', () async {
    final _FakeGateway gateway = _FakeGateway(items: <Map<String, Object?>>[
      <String, Object?>{'kind': 'song', 'id': '1', 'title': '晴天', 'duration': 1000},
      <String, Object?>{'kind': 'song', 'id': '2', 'title': '晴天 (Live)', 'duration': 2000},
    ]);
    final RemoteSearchResult result =
        await runRemoteSearch(gateway: gateway, kind: 'song', query: ' 晴天 ');
    expect(result.rows.length, 2);
    expect(result.total, 2);
    expect(result.status, '找到 2 条结果');
    expect(result.hasMore, isFalse);
    // 查询词去掉首尾空白后再下发（与 Qt `text = keyword.trim()` 一致）。
    expect(gateway.calls.single.$1, '晴天');
    expect(gateway.calls.single.$2, 'song');
  });

  test('无命中：曲目/歌单两套文案', () async {
    final _FakeGateway gateway = _FakeGateway();
    expect((await runRemoteSearch(gateway: gateway, kind: 'song', query: 'x')).status,
        '没有匹配的音乐');
    expect((await runRemoteSearch(gateway: gateway, kind: 'playlist', query: 'x')).status,
        '没有匹配的本地歌单');
  });

  test('空关键词不请求插件，直接回提示', () async {
    final _FakeGateway gateway = _FakeGateway();
    final RemoteSearchResult result =
        await runRemoteSearch(gateway: gateway, kind: 'song', query: '   ');
    expect(result.status, '请输入 1–100 字关键词');
    expect(gateway.calls, isEmpty);
  });

  test('插件报错：把原因做成状态串，不抛给 UI', () async {
    final _FakeGateway gateway =
        _FakeGateway(error: const ProviderRequestError('网易云音乐返回 400：参数错误'));
    final RemoteSearchResult result =
        await runRemoteSearch(gateway: gateway, kind: 'song', query: '晴天');
    expect(result.rows, isEmpty);
    expect(result.status, '网易云音乐返回 400：参数错误');
  });
}
