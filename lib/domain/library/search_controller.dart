part of 'music_library.dart';

// 搜索控制器（Qt MusicLibrary::search / suggest / loadMoreSource(0) / 取消）
//
// 逐函数对齐（引用用「文件 + 符号名」，不写行号：根文件仍在追加片段，行号必漂）：
// - Qt/src/MusicLibrary.cpp  MusicLibrary::search / suggest / loadMoreSource
// - Qt/src/MusicLocal.cpp    MusicLibrary::searchLocal
// - Qt/src/MusicSiren.cpp    MusicLibrary::searchSirenLocal（本片只转调）
// - Qt/src/NativeHudController.cpp  NativeHud::setQuery 的 700ms 合并与 token 比对、
//                             NativeHud::closeModal 的 ++m_searchGeneration
// - Qt/src/NativeHudMusic.cpp       hint / kind 点击（不排队）
// - Qt/src/MusicApi.cpp      MusicApi::call / request / send（valid() 为假时不回调）
//
// 本片不新增传输字段/路由：搜索只走 MusicApi::call => /native/<provider>/search，
// 参数顺序沿用 Qt 的 QJsonArray{query, kind, start}；联想只走 MusicApi::request 的
// "/search/suggest"（网易）与 "/getSmartbox"（QQ）。
//
// 本片不碰目录栈：lane 切换一律交给根文件的 showSource(lane)（Qt MusicLibrary::showSource）。
//
// 取消语义映射（唯一）：cancelSearch ≡ Qt NativeHud::closeModal 的搜索部分——
// 只作废 HUD 层排队动作，**不动** MusicLibrary::m_generation，因此在途应答仍会回调。
//

/// Qt NativeHud::setQuery 的检索合并窗口（Qt/src/NativeHudController.cpp 的 setQuery）。
///
/// 说明：Qt 的 200ms/300ms 合并分别属于封面（MusicLibrary::loadCover）与详情
/// （MusicLibrary::choose 的节流），与检索无关；检索词合并只有 NativeHud 的 700ms 一处。
const Duration librarySearchDebounce = Duration(milliseconds: 700);

/// Qt MusicLibrary 的最近搜索白名单上限（构造函数读入与 search 写回两处同值）。
const int librarySearchHistoryLimit = 12;

/// Qt MusicLibrary::suggest 的联想条数上限。
const int librarySuggestLimit = 4;

/// 单个 MusicLibrary 上尚未兑现的检索合并任务。
///
/// part 不能给 MusicLibrary 增加字段，因此用 Expando 承载「每个实例一份」的合并
/// 句柄：token 对应 Qt NativeHud::m_searchGeneration（HUD 层，不是 MusicLibrary 的
/// m_generation），用于作废已排队但还没执行的 700ms 合并动作。
class _LibrarySearchPending {
  int token = 0;

  Cancelable? handle;
}

final Expando<_LibrarySearchPending> _librarySearchPending =
    Expando<_LibrarySearchPending>('library.search.pending');

/// 取（必要时创建）某个资料库实例的合并句柄。
_LibrarySearchPending _searchPendingOf(MusicLibrary lib) =>
    _librarySearchPending[lib] ??= _LibrarySearchPending();

/// 作废已排队的 700ms 合并动作（Qt NativeHud::m_searchGeneration 的用法）。
///
/// 只作用于 HUD 层排队任务：**不**递增 MusicLibrary::m_generation，因此不会丢弃
/// 在途应答（那由 search / 空词 / searchLocal 各自 ++m_generation 决定）。
void _librarySearchInvalidatePending(MusicLibrary lib) {
  final _LibrarySearchPending pending = _searchPendingOf(lib);
  pending.handle?.cancel();
  pending.handle = null;
  pending.token++;
}

// 冻结入口 1/3：Qt MusicLibrary::search(QString text, QString kind, bool more)

/// 检索入口（根文件 MusicLibrary.search 的委托目标）。
///
/// 排队策略（对齐 Qt 时序；状态与结果和 Qt 完全一致）：
/// - more == true：Qt MusicLibrary::loadMoreSource 对 lane 0 直接调
///   search(keyword, {}, true)，**不**递增 m_searchGeneration，因此续页不排队、立即发出；
///   本地渠道在 Qt loadMoreSource 首行就 return，这里同样直接返回。
/// - kind 非空：Qt NativeHudMusic 的 kind 点击先 ++m_searchGeneration 再直接
///   search(text, kind)，因此这里先作废排队任务，再立即发出。
/// - 其余（用户敲字／点历史词）：与 Qt NativeHud::setQuery 一样合并 700ms，只有最后一次生效。
///
/// 返回的 Future 在「已排队」时立即完成（尚未发请求）；只有 more / kind 两条立即路径
/// 会等到应答写回状态后才完成。
Future<void> librarySearch(MusicLibrary lib, String text, {String kind = '', bool more = false}) async {
  if (more && lib.isLocal) {
    // Qt MusicLibrary::loadMoreSource 首行：本地渠道没有在线续页。
    return;
  }
  if (more) {
    await _librarySearchRun(lib, text, kind: kind, more: true);
    return;
  }
  if (kind.isNotEmpty) {
    // Qt NativeHudMusic 的 kind 点击：先作废 setQuery 排进 700ms 队列的回调。
    _librarySearchInvalidatePending(lib);
    await _librarySearchRun(lib, text, kind: kind, more: false);
    return;
  }
  final _LibrarySearchPending pending = _searchPendingOf(lib);
  pending.handle?.cancel();
  final int token = ++pending.token;
  pending.handle = lib.scheduler.schedule(librarySearchDebounce, () {
    if (token != pending.token) {
      // 已被后来的输入、分类切换或取消作废。
      return;
    }
    pending.handle = null;
    unawaited(_librarySearchRun(lib, text, kind: kind, more: more));
  });
}

/// Qt MusicLibrary::search 本体。调用前不合并，语义与 Qt 一一对应。
Future<void> _librarySearchRun(
  MusicLibrary lib,
  String text, {
  required String kind,
  required bool more,
}) async {
  if (lib.isLocal) {
    await _librarySearchLocal(lib, text, kind);
    return;
  }
  // Qt MusicLibrary::search 开头：仅网易云、仅首屏时把「歌曲/专辑/歌单/歌手:ID」
  // 或分享链接解析成直接结果，keyword 保留未 trim 的原文。
  if (lib.provider == 'netease' && !more) {
    final String link = lib.host.fromLink(text);
    if (link.isNotEmpty) {
      final List<String> parts = link.split(':');
      final String type = parts.isNotEmpty ? parts[0] : '';
      final String id = parts.length > 1 ? parts[1] : '';
      lib.generation++;
      lib.searchLoading = false;
      lib.keyword = text;
      lib.searchKind = type;
      lib.lists[0] = <JsonMap>[musicItem(kind: type, id: id)];
      lib.totals[0] = 1;
      lib.offsets[0] = 0;
      lib.hasMore[0] = false;
      lib.rowMemory[0] = 0;
      lib.status = '正在读取链接…';
      // Qt 此处是同步 showSource(0)（根文件 showSource 返回 void）。
      lib.showSource(0);
      lib.wantsSongDetails = type == 'song';
      lib.modeRequests.add(type == 'song' ? 'detail' : 'archive');
      return;
    }
  }
  final String query = text.trim();
  // Qt：同一关键词、同一分类且已有结果（或正在检索）时不再发车。
  if (!more &&
      query == lib.keyword &&
      (kind.isEmpty || kind == lib.searchKind) &&
      (lib.lists[0].isNotEmpty || lib.searchLoading)) {
    return;
  }
  // Qt：QQ 上限 60 个码点，其余渠道 100 个码点。
  final int maximum = lib.provider == 'qq' ? 60 : 100;
  if (query.isEmpty || query.runes.length > maximum) {
    // Qt：输入被清空或越界后，旧结果已与关键词无关，必须整体清除。
    lib.generation++;
    lib.searchLoading = false;
    lib.keyword = query;
    lib.groupLane = -1;
    lib.groupName = '';
    lib.groupIndices.clear();
    lib.lists[0] = <JsonMap>[];
    lib.totals[0] = 0;
    lib.offsets[0] = 0;
    lib.hasMore[0] = false;
    lib.rowMemory[0] = 0;
    lib.searchCursor = 0;
    lib.status = '请输入 1–$maximum 字关键词';
    lib.changed();
    return;
  }
  // Qt：续页时正在检索或已无更多则直接返回。
  if (more && (lib.searchLoading || !lib.hasMore[0])) {
    return;
  }
  if (kind.isNotEmpty) {
    lib.searchKind = kind;
  }
  lib.keyword = query;
  final int token = ++lib.generation;
  final int start = more ? lib.searchCursor : 0;
  if (!more) {
    // Qt：首屏先清空栏目、游标与分组，再写最近搜索白名单。
    lib.groupLane = -1;
    lib.groupName = '';
    lib.groupIndices.clear();
    lib.lists[0] = <JsonMap>[];
    lib.totals[0] = 0;
    lib.offsets[0] = 0;
    lib.searchCursor = 0;
    lib.hasMore[0] = false;
    _librarySearchRemember(lib, query);
  }
  if (lib.isSiren) {
    // Qt：塞壬走本地曲库过滤，代数已在上方递增（searchSirenLocal 自己不递增）。
    await lib.sirenSearchLocal(query, lib.searchKind, start, more);
    return;
  }
  lib.searchLoading = true;
  lib.status = '正在检索…';
  lib.changed();
  // Qt MusicApi::call：/native/<provider>/search，args 为数组 {query, kind, start}。
  final MusicReply reply = await lib.api.call(
    'search',
    <Object?>[query, lib.searchKind, start],
    valid: () => token == lib.generation,
  );
  // 迟到响应：Qt MusicApi::send 在 valid() 为假时根本不回调；根文件端口以
  // fail(_staleReply) 交回（并暴露 isStale 供调用方判断），这里用代数再判一次
  // 并静默丢弃，绝不改写状态。
  if (token != lib.generation || isStale(reply)) {
    return;
  }
  lib.searchLoading = false;
  if (!reply.ok) {
    lib.status = '检索失败：${reply.error ?? ''}';
    lib.changed();
    return;
  }
  final JsonMap page = mapOf(reply.value);
  final List<JsonMap> items = mapsOf(page['items']);
  // Qt：续页按 key 去重追加，首屏整表替换。
  lib.lists[0] = more ? uniqueItems(lib.lists[0], items) : items;
  if (!more) {
    lib.offsets[0] = 0;
  }
  lib.searchCursor = start + intOf(page['rawCount']);
  lib.hasMore[0] = boolOf(page['more']);
  final int total = intOf(page['total']);
  lib.totals[0] = total > lib.lists[0].length ? total : lib.lists[0].length;
  lib.status = textOf(page['notice']);
  if (lib.status.isEmpty) {
    lib.status = items.isEmpty ? '没有匹配的音乐' : '找到 ${lib.totals[0]} 条结果';
  }
  if (!more) {
    // Qt：首屏结果替换后再回到搜索栏并进入归档态。
    lib.showSource(0);
    lib.modeRequests.add('archive');
    lib.frame['mode'] = 'archive';
  }
  lib.changed();
}

/// Qt MusicLibrary::searchLocal（MusicLocal.cpp）。
///
/// 与远端检索的差异全部照抄 Qt：不改写最近搜索白名单、不置 searchLoading，
/// 并且整表替换 lists[0]；keyword 只存 trim 后的文本。
Future<void> _librarySearchLocal(MusicLibrary lib, String text, String kind) async {
  lib.generation++;
  if (kind.isNotEmpty) {
    lib.searchKind = kind;
  }
  lib.keyword = text.trim();
  lib.searchLoading = false;
  lib.groupLane = -1;
  lib.groupIndices.clear();
  lib.groupName = '';
  final LocalMusicPort? port = lib.local;
  lib.lists[0] = port == null ? <JsonMap>[] : port.search(lib.keyword, lib.searchKind);
  lib.totals[0] = lib.lists[0].length;
  lib.hasMore[0] = false;
  lib.offsets[0] = 0;
  lib.rowMemory[0] = 0;
  lib.showSource(0);
  lib.status = '本地检索：${lib.totals[0]} 条结果';
  lib.modeRequests.add('archive');
  lib.changed();
}

/// Qt MusicLibrary::search 的历史写回：去重、置顶、截断到 12 条并写回偏好。
void _librarySearchRemember(MusicLibrary lib, String query) {
  while (lib.searchHistory.remove(query)) {
    // Qt QStringList::removeAll：同名条目全部移除后再置顶。
  }
  lib.searchHistory.insert(0, query);
  while (lib.searchHistory.length > librarySearchHistoryLimit) {
    lib.searchHistory.removeLast();
  }
  lib.preferences.write('search-history', jsonEncode(lib.searchHistory));
}

// 冻结入口 2/3：Qt MusicLibrary::suggest(QString text)

/// 检索联想（根文件 MusicLibrary.suggest 的委托目标）。
///
/// 顺序照抄 Qt：先 ++m_suggestGeneration 并清空旧联想，再判「空词 / 酷狗 / 本地 /
/// 塞壬」早退——因此清空发生在早退之前，旧联想不会留在界面上。
void librarySuggest(MusicLibrary lib, String text) {
  final int token = ++lib.suggestGeneration;
  lib.suggestions.clear();
  // Qt：空词、酷狗、本地与塞壬都不请求联想。
  if (text.trim().isEmpty || lib.provider == 'kugou' || lib.isLocal || lib.isSiren) {
    return;
  }
  unawaited(_librarySuggestRequest(lib, text, token, lib.provider == 'qq'));
}

Future<void> _librarySuggestRequest(MusicLibrary lib, String text, int token, bool qq) async {
  // Qt：QQ 走 /getSmartbox{key}，其余走 /search/suggest{keywords, type}；
  // MusicApi::request 在 provider != netease 时自动前置 "/<provider>"。
  final MusicReply reply = await lib.api.request(
    qq ? '/getSmartbox' : '/search/suggest',
    qq
        ? <String, Object?>{'key': text}
        : <String, Object?>{'keywords': text, 'type': 'mobile'},
    valid: () => token == lib.suggestGeneration,
  );
  if (token != lib.suggestGeneration || isStale(reply)) {
    return;
  }
  if (!reply.ok) {
    return;
  }
  final JsonMap body = mapOf(reply.value);
  final List<JsonMap> values = qq
      ? mapsOf(mapOf(mapOf(mapOf(body['response'])['data'])['song'])['itemlist'])
      : mapsOf(mapOf(body['result'])['allMatch']);
  for (final JsonMap value in values) {
    final Object? keyword = value[qq ? 'name' : 'keyword'];
    if (keyword is String && lib.suggestions.length < librarySuggestLimit) {
      lib.suggestions.add(keyword);
    }
  }
  // Qt 侧 suggestions 由 HUD 的连续重绘读取（NativeHudSearch 没有 changed()）；
  // Flutter 没有该重绘循环，故补一次失效通知，不改变任何字段语义。
  lib.changed();
}

// 冻结入口 3/3：取消检索（Qt 以 HUD 层代数作废排队动作）

/// 取消当前检索（根文件 MusicLibrary.cancelSearch 的委托目标）。
///
/// Qt 没有同名的 MusicLibrary::cancelSearch；唯一等价的显式取消动作是
/// NativeHud::closeModal 里的 ++m_searchGeneration——它**只**作废排队中的
/// 700ms 合并回调（setQuery 里捕获的 token 比对），既不动 MusicLibrary::m_generation，
/// 也不改 searchLoading：关闭搜索弹层后，在途应答仍按 MusicApi::valid()
/// （绑 m_generation）落地。本函数严格照此实现，不额外递增 m_generation。
void libraryCancelSearch(MusicLibrary lib) {
  _librarySearchInvalidatePending(lib);
}
