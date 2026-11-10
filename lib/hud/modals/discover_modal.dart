/// Qt 发现页（Discover）状态机与面板模型装配的 1:1 Dart 移植。
///
/// 蓝本（只读证据，逐函数对应；行号以 baseline 8ed3067b 为准）：
/// * Qt/src/MusicDiscover.h:5-28, Qt/src/MusicDiscover.cpp:1-211      状态机
/// * Qt/src/NativeHudDiscover.cpp:9-148                              discoverPanel 的 Model 装配
/// * Qt/src/DiscoverArtwork.cpp:9-39                                 封面 scope + generation 作废、512 尺寸
/// * Qt/src/NativeHudInput.cpp:60-74, Qt/src/HudScroll.h:13-26        滚轮落点与近尾续载
/// * Qt/src/NativeHudController.cpp:576-619,674-681                   discover: 动作分发与 scroll 归零
/// * Qt/src/NativeHud.cpp:140-159                                    modalBounds（discover 走 else 分支）
/// * Qt/src/NativeHud.h:87-91                                        categoryPicker/categoryPage/CategoryPageSize=40
/// * Qt/src/MusicData.cpp:82-96                                      unique 合并
/// * Qt/src/MusicLibrary.h:103-105,234                               accountGeneration
///
/// 边界：本树没有 lib/domain/**、lib/hud/protocol/**、lib/hud/text/**，因此平台请求、
/// 资料库、播放器、封面解码全部以本文件内的 abstract 端口注入；宿主真实接线一律记
/// ARCH_BLOCKED（见 reports/T38-C18-W2.json），不得伪造实现。
library;

import 'dart:convert' show utf8;
import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../widgets/discover_card.dart'
    show DiscoverCard, DiscoverChoice, DiscoverEntry, DiscoverModel;

/// Qt 的 QJsonObject 等价物；发现页条目、分类、区域都用它承载。
typedef DiscoverJson = Map<String, Object?>;

/// Qt NativeHud::CategoryPageSize（Qt/src/NativeHud.h:89）。
const int categoryPageSize = 40;

/// Qt NativeHud::modalBounds 的固定外框（Qt/src/NativeHud.cpp:153-158）。
const double discoverModalMaxWidth = 1260;
const double discoverModalTop = 122;
const double discoverModalHeight = 836;

/// Qt HudScroll::DefaultWheelStep 与 discover 分支字面量（Qt/src/HudScroll.h:11、
/// Qt/src/NativeHudInput.cpp:64,67）。
const double discoverWheelStep = 60;

/// 近尾续载阈值（Qt/src/NativeHudInput.cpp:69）。
const double discoverNearEndThreshold = 120;

DiscoverJson _object(Object? value) {
  if (value is DiscoverJson) {
    return value;
  }
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }
  return <String, Object?>{};
}

List<Object?> _array(Object? value) {
  if (value is List) {
    return value;
  }
  return const <Object?>[];
}

String _string(Object? value) {
  return value is String ? value : '';
}

String _stringOr(Object? value, String fallback) {
  return value is String ? value : fallback;
}

bool _bool(Object? value) {
  return value is bool ? value : false;
}

/// QJsonValue::toInt(default)：只有数值才转换，其余返回 default。
int _int(Object? value, [int fallback = 0]) {
  return value is num ? value.toInt() : fallback;
}

// ---------------------------------------------------------------------------
// 百分号编解码：QUrl::toPercentEncoding / QUrl::fromPercentEncoding
// （Qt/src/NativeHudDiscover.cpp:57、Qt/src/NativeHudController.cpp:23-25）
// ---------------------------------------------------------------------------

bool _isHexUnit(int unit) {
  return (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x46) ||
      (unit >= 0x61 && unit <= 0x66);
}

/// 复刻 QUrl::toPercentEncoding：仅 ALPHA / DIGIT / - . _ ~ 原样保留，其余按
/// UTF-8 字节百分号编码，十六进制大写。
String percentEncode(String value) {
  const unreserved = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
      'abcdefghijklmnopqrstuvwxyz'
      '0123456789-._~';
  final units = utf8.encode(value);
  final buffer = StringBuffer();
  for (final unit in units) {
    if (unit < 0x80 && unreserved.contains(String.fromCharCode(unit))) {
      buffer.writeCharCode(unit);
      continue;
    }
    buffer.write('%');
    buffer.write(unit.toRadixString(16).toUpperCase().padLeft(2, '0'));
  }
  return buffer.toString();
}

/// 复刻 QUrl::fromPercentEncoding（输入先 toUtf8 再解码）：非法序列按替换字符处理。
String percentDecode(String value) {
  final bytes = <int>[];
  final pending = StringBuffer();

  void flush() {
    if (pending.isNotEmpty) {
      bytes.addAll(utf8.encode(pending.toString()));
      pending.clear();
    }
  }

  for (var index = 0; index < value.length; index++) {
    final unit = value.codeUnitAt(index);
    if (unit == 0x25 && index + 2 < value.length) {
      final high = value.codeUnitAt(index + 1);
      final low = value.codeUnitAt(index + 2);
      if (_isHexUnit(high) && _isHexUnit(low)) {
        flush();
        bytes.add(int.parse(value.substring(index + 1, index + 3), radix: 16));
        index += 2;
        continue;
      }
    }
    pending.writeCharCode(unit);
  }
  flush();
  return utf8.decode(bytes, allowMalformed: true);
}

// ---------------------------------------------------------------------------
// 注入端口
// ---------------------------------------------------------------------------

/// Qt MusicReply（Qt/src/MusicApi.h:7-14）：error 为空即 ok。
class DiscoverReply {
  const DiscoverReply({this.value, this.error = ''});

  final Object? value;
  final String error;

  bool get ok {
    return error.isEmpty;
  }
}

/// Qt MusicApi（Qt/src/MusicApi.h:22-25）。valid 在 API 层投递前拦截
/// （Qt/src/MusicApi.cpp:98），端口实现必须先判 valid 再回调。
abstract class DiscoverApiPort {
  void call(
    String operation,
    List<Object?> arguments,
    void Function(DiscoverReply) reply, {
    bool Function()? valid,
  });

  /// Qt/src/MusicApi.h:22-25 的 request(route, params, reply, valid, allowed={200})：
  /// allowed 缺省由宿主填 {200}，本层不预设状态码。
  void request(
    String route,
    DiscoverJson parameters,
    void Function(DiscoverReply) reply, {
    bool Function()? valid,
    Set<int>? allowed,
  });
}

/// Qt MusicLibrary + MusicPlayer 的最小注入面。
abstract class DiscoverHostPort {
  /// Qt MusicLibrary.h:161 provider。
  String get provider;

  /// Qt MusicLibrary.h:163 uid。
  String get uid;

  /// Qt MusicLibrary.h:103-105,234 accountGeneration()。
  int get accountGeneration;

  /// Qt MusicLibrary.h:92 providerName()（每日推荐虚拟目录的 artist 字段）。
  String get providerName;

  /// Qt MusicPlayer.h:41 history。
  List<DiscoverJson> get history;

  /// Qt MusicLibrary.h:194 subscriptions（artists 页把 key 写进这里）。
  Set<String> get subscriptions;

  /// Qt MusicLibrary.h:44 changed()。
  void changed();

  /// Qt MusicLibrary.h:187 privateSelection。
  void setPrivateSelection(bool value);

  /// Qt MusicLibrary.h:156 playContext。
  void setPlayContext(List<DiscoverJson> values);

  /// Qt MusicPlayer::play(value, items)（Qt/src/MusicDiscover.cpp:205）。
  void play(DiscoverJson value, List<DiscoverJson> context);

  /// Qt MusicLibrary.h:63 choose(value)。
  void choose(DiscoverJson value);

  /// Qt MusicLibrary.h:123 enterDirectory(value)（Qt/src/MusicDirectory.cpp:46-142）。
  void enterDirectory(DiscoverJson value);

  /// Qt MusicLibrary.h:216 modeRequested(mode)。
  void modeRequested(String mode);

  /// Qt MusicLibrary.h:124 openDaily()（Qt/src/MusicDirectory.cpp:147-209）。
  bool openDaily();
}

/// Qt MusicData::parse（Qt/src/MusicData.h:9、.cpp:41-80）；非法项返回 null。
abstract class DiscoverDataPort {
  DiscoverJson? parseItem(DiscoverJson raw, String kind);
}

/// Host::image(key) 的返回尺寸；null 等价于 QImage::isNull()。
class DiscoverCover {
  const DiscoverCover(this.width, this.height);

  final int width;
  final int height;
}

/// Qt Host::image(key)（Qt/src/NativeHudDiscover.cpp:116-120）。
abstract class DiscoverCoverProbe {
  DiscoverCover? cover(String key);
}

// ---------------------------------------------------------------------------
// 封面：Qt DiscoverArtwork（Qt/src/DiscoverArtwork.cpp:9-39）
// ---------------------------------------------------------------------------

/// 复刻 DiscoverArtwork：scope/urls 相同则早退；scope 或 urls 变化时递增 generation，
/// 旧回调作废；失败封面保持空字符串占位，不在同一 scope 内重试。
class DiscoverArtwork {
  DiscoverArtwork({required this.load, required this.invalidate});

  /// Host::loadCover(url, callback, size)（Qt/src/DiscoverArtwork.cpp:22-33）。
  final void Function(String url, void Function(String key) done, int size) load;

  /// Host::invalidate()（Qt/src/DiscoverArtwork.cpp:30）。
  final void Function() invalidate;

  /// 固定 512 像素（Qt/src/DiscoverArtwork.cpp:33）。
  static const int coverSize = 512;

  String _scope = '';
  List<String> _urls = const <String>[];
  int _generation = 0;
  final Map<String, String> _images = <String, String>{};

  int get generation {
    return _generation;
  }

  String get scope {
    return _scope;
  }

  /// Qt DiscoverArtwork::show（:9-35）。
  void show(String scope, List<String> urls) {
    if (scope == _scope && _sameUrls(urls, _urls)) {
      return;
    }
    _scope = scope;
    _urls = List<String>.of(urls);
    _images.clear();
    final generation = ++_generation;
    for (final url in urls) {
      if (url.isEmpty || _images.containsKey(url)) {
        continue;
      }
      _images[url] = '';
      load(url, (key) {
        if (generation != _generation) {
          return;
        }
        _images[url] = key;
        if (key.isNotEmpty) {
          invalidate();
        }
      }, coverSize);
    }
  }

  /// Qt DiscoverArtwork::image（:37-39）：未知 url 返回空串。
  String image(String url) {
    return _images[url] ?? '';
  }

  static bool _sameUrls(List<String> left, List<String> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }
}

// ---------------------------------------------------------------------------
// MusicDiscover 等价状态机（Qt/src/MusicDiscover.h:5-28、.cpp:1-211）
// ---------------------------------------------------------------------------

class MusicDiscoverState {
  MusicDiscoverState({
    required this.host,
    required this.api,
    required this.data,
  });

  final DiscoverHostPort host;
  final DiscoverApiPort api;
  final DiscoverDataPort data;

  String tab = 'playlists';
  List<DiscoverJson> items = <DiscoverJson>[];
  bool loading = false;
  String status = '';
  int generation = 0;
  int offset = 0;
  bool more = false;
  String category = '全部';
  List<DiscoverJson> categories = <DiscoverJson>[];
  List<DiscoverJson> newSongAreas = <DiscoverJson>[];
  String newSongArea = '5';

  /// Qt MusicDiscover::valid（.cpp:9-13）：列表代数 + 账号代数双重校验。
  bool Function() _valid(int token, int account) {
    return () => generation == token && host.accountGeneration == account;
  }

  /// Qt MusicData::unique（Qt/src/MusicData.cpp:82-96）：按 key 建已见集合，保留
  /// existing 原序，再按 values 原序追加未出现项；重复丢弃，不重排。
  static List<DiscoverJson> uniqueItems(
    List<DiscoverJson> existing,
    List<DiscoverJson> values,
  ) {
    final keys = <String>{for (final value in existing) _string(value['key'])};
    final result = <DiscoverJson>[...existing];
    for (final value in values) {
      final key = _string(value['key']);
      if (!keys.contains(key)) {
        keys.add(key);
        result.add(value);
      }
    }
    return result;
  }

  /// Qt MusicDiscover::load（.cpp:16-122）。
  void load([String nextTab = '', bool append = false]) {
    if (append && (loading || !more)) {
      return;
    }
    if (nextTab.isNotEmpty) {
      tab = nextTab;
    }
    final token = ++generation;
    final alive = _valid(token, host.accountGeneration);
    final start = append ? offset : 0;
    loading = true;
    status = '正在读取…';
    if (!append) {
      items = <DiscoverJson>[];
    }
    host.changed();
    if ((tab == 'daily' || tab == 'guess') && host.uid.isEmpty) {
      accept(const DiscoverReply(error: '登录后查看每日推荐'), tab, start, append);
      return;
    }
    if (tab == 'artists' && (host.uid.isEmpty || host.provider != 'netease')) {
      accept(const DiscoverReply(error: '登录网易云后查看收藏歌手'), tab, start, append);
      return;
    }
    if (tab == 'history') {
      final history = <DiscoverJson>[];
      for (final value in host.history) {
        if (_stringOr(value['provider'], 'netease') == host.provider) {
          history.add(value);
        }
      }
      accept(
        DiscoverReply(value: <String, Object?>{
          'items': history,
          'rawCount': 0,
          'more': false,
        }),
        tab,
        start,
        append,
      );
      return;
    }
    final currentTab = tab;
    if (host.provider != 'netease') {
      api.call(
        'discover',
        <Object?>[tab, start, tab == 'new-songs' ? newSongArea : category],
        (reply) => accept(reply, currentTab, start, append),
        valid: alive,
      );
      return;
    }
    var route = '';
    var parameters = <String, Object?>{};
    var kind = 'playlist';
    var field = '';
    if (tab == 'playlists') {
      route = '/personalized';
      parameters = <String, Object?>{'limit': 30};
      field = 'result';
    } else if (tab == 'daily') {
      route = '/recommend/songs';
      kind = 'song';
    } else if (tab == 'charts') {
      route = '/toplist';
      field = 'list';
    } else if (tab == 'albums') {
      route = '/album/newest';
      field = 'albums';
      kind = 'album';
    } else if (tab == 'categories') {
      route = '/top/playlist';
      parameters = <String, Object?>{
        'cat': category,
        'limit': 30,
        'offset': start,
      };
      field = 'playlists';
    } else if (tab == 'artists') {
      route = '/artist/sublist';
      parameters = <String, Object?>{'limit': 30, 'offset': start};
      field = 'data';
      kind = 'artist';
    } else {
      accept(const DiscoverReply(error: '不支持的发现类别'), tab, start, append);
      return;
    }
    api.request(route, parameters, (reply) {
      if (!reply.ok) {
        accept(reply, currentTab, start, append);
        return;
      }
      final body = _object(reply.value);
      var rawList = _array(body[field]);
      if (currentTab == 'daily') {
        final daily = _object(body['data'])['dailySongs'];
        rawList = daily is List ? daily : _array(body['recommend']);
      }
      final values = <DiscoverJson>[];
      for (final value in rawList) {
        final entry = data.parseItem(_object(value), kind);
        if (entry != null && entry.isNotEmpty) {
          values.add(entry);
        }
      }
      var pageMore = false;
      if (currentTab == 'categories') {
        pageMore = _bool(body['more']);
      } else if (currentTab == 'artists') {
        pageMore = _bool(body['hasMore']);
      }
      accept(
        DiscoverReply(value: <String, Object?>{
          'items': values,
          'rawCount': rawList.length,
          'more': pageMore,
        }),
        currentTab,
        start,
        append,
      );
    }, valid: alive);
  }

  /// Qt MusicDiscover::accept（.cpp:124-150）。
  void accept(DiscoverReply result, String currentTab, int start, bool append) {
    if (!result.ok) {
      status = result.error;
    } else {
      final page = _object(result.value);
      if (currentTab == 'categories' &&
          host.provider == 'qq' &&
          page['category'] is String) {
        category = page['category'] as String;
      }
      if (currentTab == 'new-songs') {
        newSongAreas = <DiscoverJson>[
          for (final value in _array(page['areas'])) _object(value),
        ];
        newSongArea = _int(page['area'], 5).toString();
      }
      final pageItems = <DiscoverJson>[
        for (final value in _array(page['items'])) _object(value),
      ];
      items = append ? uniqueItems(items, pageItems) : pageItems;
      offset = start + _int(page['rawCount']);
      if (currentTab == 'artists') {
        for (final value in items) {
          host.subscriptions.add(_string(value['key']));
        }
      }
      more = _bool(page['more']);
      status = items.isEmpty ? '暂无内容' : '已载入 ' + items.length.toString() + ' 条';
    }
    loading = false;
    host.changed();
  }

  /// Qt MusicDiscover::loadCategories（.cpp:152-181）。
  void loadCategories() {
    final alive = _valid(generation, host.accountGeneration);

    void acceptCategories(DiscoverReply result) {
      if (result.ok) {
        categories = <DiscoverJson>[
          for (final value in _array(result.value)) _object(value),
        ];
        host.changed();
      } else {
        status = result.error;
      }
    }

    if (host.provider != 'netease') {
      api.call('categories', const <Object?>[], acceptCategories, valid: alive);
      return;
    }
    api.request('/playlist/catlist', const <String, Object?>{}, (reply) {
      if (!reply.ok) {
        acceptCategories(reply);
        return;
      }
      final values = <DiscoverJson>[];
      for (final value in _array(_object(reply.value)['sub'])) {
        final text = _string(_object(value)['name']);
        values.add(<String, Object?>{'id': text, 'name': text});
      }
      acceptCategories(DiscoverReply(value: values));
    }, valid: alive);
  }

  /// Qt MusicDiscover::cancel（.cpp:183-194）；Qt 侧不调 changed()。
  void cancel() {
    ++generation;
    loading = false;
    items = <DiscoverJson>[];
    more = false;
    offset = 0;
    categories = <DiscoverJson>[];
    newSongAreas = <DiscoverJson>[];
    newSongArea = '5';
    category = '全部';
    tab = 'playlists';
  }

  /// Qt MusicDiscover::open（.cpp:196-211）。
  void open(int index) {
    if (index < 0 || index >= items.length) {
      return;
    }
    final value = items[index];
    host.setPrivateSelection(tab == 'daily' || tab == 'artists');
    // Qt 的 QJsonArray 是值语义，这里传副本，避免宿主持有同一可变列表。
    host.setPlayContext(List<DiscoverJson>.of(items));
    if (_string(value['kind']) == 'song') {
      host.play(value, List<DiscoverJson>.of(items));
      host.choose(value);
      host.modeRequested('detail');
    } else {
      host.enterDirectory(value);
    }
  }
}

/// Qt NativeHud 上属于发现页的三个字段（Qt/src/NativeHud.h:87-91）。
class DiscoverPanelState {
  bool categoryPicker = false;
  int categoryPage = 0;
  double scroll = 0;
  double scrollMaximum = 0;

  /// Qt m_discoverScrollScope（QString 默认构造为空，任何非空 scope 都算变化）。
  String scrollScope = '';
}

/// Qt NativeHudController.cpp:605-607 的 allCategory：
/// (provider != "qq" || categories.isEmpty) ? 1 : 0 —— 即是否前置「全部」。
int categoryAllCount(String provider, int rawCount) {
  return provider != 'qq' || rawCount == 0 ? 1 : 0;
}

/// Qt NativeHudDiscover.cpp:46-47：pages = max(1, ceil(prepended / 40))，
/// prepended = rawCount + allCount。与 NativeHudController.cpp:606-607 的
/// (rawCount + all + 39) / 40 数学等价，这里只保留一个实现避免漂移。
int categoryPageCount(String provider, int rawCount) {
  final prepared = rawCount + categoryAllCount(provider, rawCount);
  return math.max(1, (prepared + categoryPageSize - 1) ~/ categoryPageSize);
}

/// Qt NativeHud::modalBounds 的 discover 分支（Qt/src/NativeHud.cpp:140-159）。
/// 这是宿主外框的只读镜像；真实外框仍由 HUD 宿主绘制（ARCH_BLOCKED）。
Rect discoverModalBounds(double stageWidth) {
  final modalWidth = math.min(discoverModalMaxWidth, stageWidth - 100);
  final left = (stageWidth - modalWidth) / 2;
  return Rect.fromLTWH(left, discoverModalTop, modalWidth, discoverModalHeight);
}

// ---------------------------------------------------------------------------
// discoverPanel：Qt/src/NativeHudDiscover.cpp:9-148
// ---------------------------------------------------------------------------

/// Qt NativeHud::discoverPanel 的等价函数：只装配只读显示模型，不改平台数据。
DiscoverModel buildDiscoverPanel({
  required double x,
  required double y,
  required double width,
  required MusicDiscoverState discover,
  required DiscoverHostPort host,
  required DiscoverPanelState panel,
  required bool dark,
  required DiscoverArtwork artwork,
  required DiscoverCoverProbe covers,
}) {
  final model = _newModel();
  model.bounds = Rect.fromLTWH(x, y, width, discoverModalHeight);
  model.dark = dark;
  model.tab = discover.tab;
  model.status = discover.status;
  model.loading = discover.loading;
  model.more = discover.more;
  model.loadedCount = discover.items.length;

  final tabs = <List<String>>[
    <String>['playlists', '推荐歌单'],
    <String>['daily', host.provider == 'qq' ? '每日 30 首' : '每日推荐'],
    <String>['charts', '排行榜'],
    <String>['albums', '新专辑'],
    <String>['categories', '分类歌单'],
  ];
  if (host.provider == 'qq') {
    tabs.insert(2, <String>['guess', '猜你喜欢']);
    tabs.insert(3, <String>['new-songs', '新歌速递']);
  }
  if (host.provider == 'netease') {
    tabs.add(<String>['artists', '收藏歌手']);
  }
  tabs.add(<String>['history', '历史']);
  for (final entry in tabs) {
    model.tabs.add(
      _choice(entry[1], 'discover:tab:' + entry[0], discover.tab == entry[0]),
    );
  }

  if (discover.tab == 'categories') {
    // Qt NativeHudDiscover.cpp:37-43：「全部」只在非 qq 或分类为空时前置。
    final prepared = <DiscoverJson>[];
    if (host.provider != 'qq' || discover.categories.isEmpty) {
      prepared.add(<String, Object?>{'id': '全部', 'name': '全部'});
    }
    prepared.addAll(discover.categories);
    if (panel.categoryPicker) {
      model.categoryPicker = true;
      final pages = categoryPageCount(host.provider, discover.categories.length);
      panel.categoryPage = panel.categoryPage.clamp(0, pages - 1).toInt();
      model.categoryPages = pages;
      model.categoryPage = panel.categoryPage;
      model.tools.add(_choice('← 返回列表', 'discover:categories', false));
      final start = panel.categoryPage * categoryPageSize;
      final end = math.min(prepared.length, (panel.categoryPage + 1) * categoryPageSize);
      for (var index = start; index < end; index++) {
        final entry = prepared[index];
        final id = _string(entry['id']);
        model.categories.add(
          _choice(
            _string(entry['name']),
            'discover:category:' + percentEncode(id),
            id == discover.category,
          ),
        );
      }
    } else {
      var name = '全部';
      for (final value in prepared) {
        if (_string(value['id']) == discover.category) {
          name = _string(value['name']);
          break;
        }
      }
      model.tools.add(_choice('分类：' + name + ' ↓', 'discover:categories', false));
    }
  } else if (discover.tab == 'guess') {
    model.tools.add(_choice('换一批推荐 ↻', 'discover:tab:guess', false));
  } else if (discover.tab == 'daily') {
    model.tools.add(_choice('在资料库打开 ↗', 'discover:open', false));
  } else if (discover.tab == 'new-songs') {
    for (final value in discover.newSongAreas) {
      final id = _int(value['id']).toString();
      model.tools.add(
        _choice(_string(value['name']), 'discover:area:' + id, id == discover.newSongArea),
      );
    }
  } else if (discover.tab == 'playlists') {
    model.tools.add(_choice('每日推荐 ↗', 'discover:tab:daily', false));
  }

  final scrollScope =
      host.provider + ':' + host.accountGeneration.toString() + ':' + discover.tab;
  if (panel.scrollScope != scrollScope) {
    panel.scroll = 0;
    panel.scrollScope = scrollScope;
  }
  panel.scrollMaximum = DiscoverCard.layout(model.bounds, model.loadedCount).maximumScroll;
  panel.scroll = panel.scroll.clamp(0.0, panel.scrollMaximum).toDouble();
  model.scroll = panel.scroll;

  final indices = model.categoryPicker
      ? const <int>[]
      : DiscoverCard.visibleIndices(model.bounds, model.loadedCount, model.scroll);
  final urls = <String>[
    for (final index in indices) _string(discover.items[index]['cover']),
  ];
  final scope = host.provider +
      ':' +
      host.accountGeneration.toString() +
      ':' +
      discover.generation.toString();
  artwork.show(scope, urls);
  for (var position = 0; position < urls.length; position++) {
    final item = discover.items[indices[position]];
    final entry = _entry();
    entry.index = indices[position];
    entry.title = _string(item['title']);
    entry.artist = _string(item['artist']);
    entry.kind = _string(item['kind']);
    final key = artwork.image(urls[position]);
    final cover = covers.cover(key);
    if (cover != null) {
      entry.image = key;
      entry.imageAspect = cover.width / cover.height;
    }
    model.entries.add(entry);
  }
  return model;
}

// ---------------------------------------------------------------------------
// 滚轮：Qt/src/NativeHudInput.cpp:60-74 + Qt/src/HudScroll.h:13-26
// ---------------------------------------------------------------------------

/// QRectF::contains：四边闭区间（Dart Rect.contains 是半开区间，这里显式复刻 Qt）。
bool _contains(Rect rectangle, double x, double y) {
  return x >= rectangle.left &&
      x <= rectangle.right &&
      y >= rectangle.top &&
      y <= rectangle.bottom;
}

/// Qt HudScroll::clampOffset（Qt/src/HudScroll.h:17-19）。
double _clampOffset(double offset, double contentHeight, double viewportHeight) {
  final maximum = math.max(0.0, contentHeight - viewportHeight);
  return offset.clamp(0.0, maximum).toDouble();
}

/// Qt HudScroll::applyWheel（Qt/src/HudScroll.h:22-26）。discover 分支把
/// contentHeight 传成 viewport.height() 加 discoverScrollMaximum，等价于以
/// maximumScroll 为上限；落点与近尾判定在 Qt 里是**两个分开的量**，不能合并。
double applyDiscoverWheel({
  required double scroll,
  required double maximumScroll,
  required double viewportHeight,
  double? distance,
  required int step,
  required double x,
  required double y,
  required bool closing,
  required bool categoryPicker,
  required Rect viewport,
  void Function()? onNearEnd,
  double modalOffset = 0,
}) {
  if (closing || categoryPicker || !_contains(viewport, x, y - modalOffset)) {
    return scroll;
  }
  // 落点 delta：Qt/src/HudScroll.h:24 —— distance 有值且非 0 才用它，否则 steps * stepPixels；
  // 因此 distance==0 时滚动仍然走 steps * 60。
  final double delta =
      (distance != null && distance != 0) ? distance : step * discoverWheelStep;
  // 续载位移 movement：Qt/src/NativeHudInput.cpp:64 的 distance.value_or(step * 60.)；
  // distance==0 时就是 0，零距离滚轮事件不触发近尾续载（与落点语义不同）。
  final double movement = distance ?? step * discoverWheelStep;
  final next = _clampOffset(
    scroll + delta,
    viewportHeight + maximumScroll,
    viewportHeight,
  );
  if (movement > 0 && next >= maximumScroll - discoverNearEndThreshold) {
    onNearEnd?.call();
  }
  return next;
}

/// Qt NativeHud::wheel 的 discover 分支（Qt/src/NativeHudInput.cpp:60-74）：
/// 用 layout(bounds, loadedCount).viewport 判定命中，落点写回 panel，并在
/// movement 大于 0 且 discover 未在加载、more 为真时续载下一页。
double discoverWheel({
  required MusicDiscoverState discover,
  required DiscoverPanelState panel,
  required Rect bounds,
  required double x,
  required double y,
  required int step,
  double? distance,
  double modalOffset = 0,
  bool closing = false,
}) {
  final viewport = DiscoverCard.layout(bounds, discover.items.length).viewport;
  panel.scroll = applyDiscoverWheel(
    scroll: panel.scroll,
    maximumScroll: panel.scrollMaximum,
    viewportHeight: viewport.height,
    distance: distance,
    step: step,
    x: x,
    y: y,
    closing: closing,
    categoryPicker: panel.categoryPicker,
    viewport: viewport,
    modalOffset: modalOffset,
    onNearEnd: () {
      if (!discover.loading && discover.more) {
        discover.load(discover.tab, true);
      }
    },
  );
  return panel.scroll;
}

// ---------------------------------------------------------------------------
// discover: 动作分发：Qt/src/NativeHudController.cpp:576-619
// ---------------------------------------------------------------------------

/// 动作执行结果；closeModal 等价于控制器在动作分支里调用 closeModal()。
class DiscoverActionResult {
  const DiscoverActionResult({this.handled = true, this.closeModal = false});

  final bool handled;
  final bool closeModal;
}

/// Qt NativeHudController 的 value.startsWith("discover:") 分支。
///
/// 两类 scroll 归零语义不同，都要保留：
/// 1. 动作侧显式归零：discover:tab:*（NativeHudController.cpp:580）、
///    discover:area:*（:595）、discover:category:*（:611）；
/// 2. 面板装配侧 scope 变化归零（buildDiscoverPanel 内 scrollScope 比较）。
DiscoverActionResult handleDiscoverAction(
  String value, {
  required MusicDiscoverState discover,
  required DiscoverHostPort host,
  required DiscoverPanelState panel,
}) {
  if (!value.startsWith('discover:')) {
    return const DiscoverActionResult(handled: false);
  }
  // Qt NativeHudController.cpp:572-575：本地模式不接受 discover 动作。
  if (host.provider == 'local') {
    return const DiscoverActionResult();
  }
  final parts = value.split(':');
  final name = parts.length > 1 ? parts[1] : '';
  final argument = parts.length > 2 ? parts[2] : '';
  if (name == 'tab') {
    panel.scroll = 0;
    panel.categoryPicker = false;
    panel.categoryPage = 0;
    discover.load(argument);
    if (argument == 'categories' && discover.categories.isEmpty) {
      discover.loadCategories();
    }
  } else if (name == 'item') {
    discover.open(int.tryParse(argument) ?? 0);
    // 控制器无条件关闭弹层（NativeHudController.cpp:589），即使索引越界。
    return const DiscoverActionResult(closeModal: true);
  } else if (name == 'open') {
    return DiscoverActionResult(closeModal: host.openDaily());
  } else if (name == 'area' && host.provider == 'qq') {
    panel.scroll = 0;
    discover.newSongArea = argument;
    discover.load('new-songs');
  } else if (name == 'categories') {
    panel.categoryPicker = !panel.categoryPicker;
    panel.categoryPage = 0;
    if (panel.categoryPicker && discover.categories.length <= 1) {
      discover.loadCategories();
    }
  } else if (name == 'category-page') {
    final pages = categoryPageCount(host.provider, discover.categories.length);
    final step = argument == 'prev' ? -1 : 1;
    panel.categoryPage = (panel.categoryPage + step).clamp(0, pages - 1).toInt();
  } else if (name == 'category') {
    panel.scroll = 0;
    panel.categoryPicker = false;
    discover.category = percentDecode(argument);
    discover.load('categories');
  } else if (name == 'more') {
    discover.load(discover.tab, true);
  }
  return const DiscoverActionResult();
}

// ---------------------------------------------------------------------------
// 与文件 A 的适配层（lib/hud/widgets/discover_card.dart，owner W1）
//
// 依赖 A 侧形状：无参构造 + 可变字段，字段名严格按冻结契约。全部构造点集中在
// 这三个函数，A 侧若调整构造签名只改这里。
// ---------------------------------------------------------------------------

DiscoverModel _newModel() {
  return DiscoverModel();
}

DiscoverChoice _choice(String label, String action, bool selected) {
  final choice = DiscoverChoice();
  choice.label = label;
  choice.action = action;
  choice.selected = selected;
  return choice;
}

DiscoverEntry _entry() {
  return DiscoverEntry();
}
