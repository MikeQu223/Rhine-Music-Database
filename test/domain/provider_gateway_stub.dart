/// 测试替身共用的网关桩：只提供 `ProviderGateway` 里那些**本测试用不到**的成员。
///
/// 为什么要有这个文件：`ProviderGateway` 是播放器与插件平台之间的唯一契约，随着功能
/// 逐项补齐（发现页、喜欢状态、歌单、MV、歌词…）它会持续加方法；每个测试替身都手写
/// 一份空实现的话，每加一个操作就要改几十个文件，而且改漏了就是编译错误、整份测试
/// 跑不起来。这里把「用不到就抛 UnimplementedError」收敛成一处。
///
/// 用法：`class _FakeGateway with ProviderGatewayStub implements ProviderGateway`。
/// 类自己声明的方法优先于 mixin，所以想验的方法照常覆写。
library;

import 'package:rhine_music_database/provider/provider_gateway.dart';

mixin ProviderGatewayStub implements ProviderGateway {
  @override
  Future<List<Map<String, Object?>>> detailSongs(Map<String, Object?> item) =>
      throw UnimplementedError('detailSongs');

  @override
  Future<Map<String, Object?>> discover({
    required String tab,
    int start = 0,
    String category = '',
    String area = '',
  }) =>
      throw UnimplementedError('discover');

  @override
  Future<List<String>> discoverCategories() => throw UnimplementedError('discoverCategories');

  @override
  Future<List<String>> likedState(List<String> trackIds) => throw UnimplementedError('likedState');

  @override
  Future<List<String>> likedTrackIds({String uid = ''}) => throw UnimplementedError('likedTrackIds');

  @override
  Future<Map<String, Object?>> lyricsByTrack(Map<String, Object?> track) =>
      throw UnimplementedError('lyricsByTrack');

  @override
  Future<Map<String, Object?>> mutate(String route, Map<String, Object?> values) =>
      throw UnimplementedError('mutate');

  @override
  Future<String> playback({
    required String trackId,
    String quality = '',
    bool alternative = false,
  }) =>
      throw UnimplementedError('playback');

  @override
  Future<bool> setTrackLiked({required String trackId, required bool liked}) =>
      throw UnimplementedError('setTrackLiked');

  @override
  Future<List<Map<String, Object?>>> songsByIds(List<String> ids) => throw UnimplementedError('songsByIds');

  @override
  Future<List<Map<String, Object?>>> userPlaylists({String uid = ''}) =>
      throw UnimplementedError('userPlaylists');
}
