/// 远端（插件平台）分类检索：把插件 `search` 返回的条目映射成检索页的行。
///
/// 为什么要这一层：`CatalogSearchIndex` 只认塞壬曲库（本地 936 首），切到插件平台
/// 后资料库仍是塞壬数据；检索是唯一能真正体现「多平台」的入口，所以这里单独开一条
/// 远端路径——行形状与 `CatalogSearchIndex` 完全一致（`kind/id/title/artist/album/
/// cover/trackCount`），页面与分组条不用改。
///
/// Qt 真值：`Qt/src/MusicLibrary.cpp:628-700`（`search` → `api.call("search", …)` →
/// `items/rawCount/more`），`Qt/src/MusicSiren.cpp:91-190`（本地检索的同款状态串）。
library;

import '../../provider/plugin_gateway.dart' show ProviderRequestError;
import '../../provider/provider_gateway.dart';

/// 一次远端检索的结果。
class RemoteSearchResult {
  const RemoteSearchResult({
    this.rows = const <Map<String, Object?>>[],
    this.total = 0,
    this.hasMore = false,
    this.status = '',
  });

  /// 与 `CatalogSearchIndex` 同形的行。
  final List<Map<String, Object?>> rows;

  /// 结果总数（插件不一定给，缺省用本页条数）。
  final int total;

  /// 还有下一页。
  final bool hasMore;

  /// 状态串（空 = 用默认的「找到 N 条结果」）。
  final String status;
}

/// 检索分类 key → 插件枚举。
///
/// 插件只认 `song`/`album`/`playlist`/`artist`（`port.d.ts` 的 `SearchKind`），
/// 我们的分类 key 与它一一对应；未知 key 退回歌曲。
ProviderSearchKind remoteSearchKind(String kind) {
  for (final ProviderSearchKind value in ProviderSearchKind.values) {
    if (value.id == kind) {
      return value;
    }
  }
  return ProviderSearchKind.song;
}

/// 把插件条目规整成检索页的行。
///
/// 插件字段（真机 `netease` 返回）：`kind/id/title/artist/artists[]/album/albumID/
/// cover/duration/provider/key/trackCount/mvID`；本地检索用的是 `durationMs`，
/// 这里补一份，页面右列（`_trackTime`）就不用分支。
Map<String, Object?> remoteSearchRow(Map<String, Object?> item) {
  final Object? duration = item['durationMs'] ?? item['duration'];
  final int durationMs = duration is num ? duration.toInt() : 0;
  final Object? trackCount = item['trackCount'];
  return <String, Object?>{
    ...item,
    'durationMs': durationMs,
    'trackCount': trackCount is num ? trackCount.toInt() : 0,
    'artist': (item['artist'] ?? '').toString(),
    'album': (item['album'] ?? '').toString(),
    'cover': (item['cover'] ?? '').toString(),
  };
}

/// 跑一次远端检索。
///
/// 失败**不抛**：插件回非 200（未登录、限流、平台不支持）时把原因做成状态串，
/// 页面照常显示空列表——与 Qt 一致（`MusicLibrary` 把失败写进 `status`）。
/// 远端调用失败时的可显示原因（检索、收藏、歌单、播放地址共用一套口径）。
String remoteErrorMessage(Object error) {
  if (error is ProviderUnavailableError) {
    return error.message;
  }
  if (error is ProviderRequestError) {
    return error.message;
  }
  return '插件调用失败：$error';
}

Future<RemoteSearchResult> runRemoteSearch({
  required ProviderGateway gateway,
  required String kind,
  required String query,
  int start = 0,
  int pageSize = 30,
}) async {
  final String text = query.trim();
  if (text.isEmpty) {
    return const RemoteSearchResult(status: '请输入 1–100 字关键词');
  }
  try {
    final List<Map<String, Object?>> items = await gateway.search(
      query: text,
      kind: remoteSearchKind(kind),
      start: start,
    );
    final List<Map<String, Object?>> rows = <Map<String, Object?>>[
      for (final Map<String, Object?> item in items) remoteSearchRow(item),
    ];
    if (rows.isEmpty) {
      return RemoteSearchResult(
        status: kind == 'playlist' ? '没有匹配的本地歌单' : '没有匹配的音乐',
      );
    }
    return RemoteSearchResult(
      rows: rows,
      total: rows.length,
      hasMore: rows.length >= pageSize,
      status: '找到 ${rows.length} 条结果',
    );
  } on ProviderUnavailableError catch (error) {
    return RemoteSearchResult(status: error.message);
  } on ProviderRequestError catch (error) {
    return RemoteSearchResult(status: error.message);
  } on Object catch (error) {
    return RemoteSearchResult(status: '检索失败：$error');
  }
}
