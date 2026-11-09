/// Qt 移植源：Qt/src/PlaybackQueue.h、Qt/src/PlaybackQueue.cpp
///
/// 播放队列的唯一状态源。
/// 负责曲目顺序、当前索引、入队/移除/切歌、元数据补全和会话存档。
/// 队列只保存完整曲目；缺少元数据的 ID 先补全再发布，界面不会出现占位歌曲。
library;

import 'dart:math' as math;

/// 队列元数据来源端口，对齐 Qt `MusicApi::call("songs", {batch}, ...)`。
/// 失败以抛异常表达；调用方按 Qt 语义跳过该批次，不产生占位条目。
abstract class QueueMetadataPort {
  /// 当前来源，决定本地曲目隔离与 load 期间的 provider。
  String get provider;

  /// 按 ID 批量取完整歌曲，返回项需带 kind/id。
  Future<List<Map<String, Object?>>> songs(List<String> ids);
}

/// 曲目对象，字段名与 Qt JSON 一致。
typedef Track = Map<String, Object?>;

/// 播放队列的唯一状态源。
class PlaybackQueue {
  PlaybackQueue(this._api, {math.Random? random}) : _random = random ?? math.Random();

  /// 与目录分页一致，避免单次请求携带过多 ID。
  static const int fetchBatchSize = 100;

  /// 只保留最近的实际播放顺序，随机回退不无限增长。
  static const int shuffleHistoryLimit = 200;

  final QueueMetadataPort? _api;
  final math.Random _random;

  final List<Track> _items = <Track>[];
  List<String> _ids = <String>[];
  List<String> _missing = <String>[];
  final Map<String, Track> _resolved = <String, Track>{};
  final List<String> _history = <String>[];
  String _provider = 'netease';
  String _selectedKey = '';
  int _index = -1;
  int _generation = 0;
  bool _loading = false;

  final List<void Function()> _listeners = <void Function()>[];

  /// 订阅 changed（Qt `PlaybackQueue::changed`）。
  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _emit() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  static String _text(Object? value) => value is String ? value : '';

  /// 歌曲身份：provider 缺省为 netease。
  static String identity(Map<String, Object?> track) {
    final raw = track['provider'];
    final provider = raw is String ? raw : 'netease';
    return '$provider:${_text(track['id'])}';
  }

  /// 去重并剔除无效条目，队列只接受完整歌曲。
  static List<Track> _sanitized(List<Track> values) {
    final result = <Track>[];
    final seen = <String>{};
    for (final value in values) {
      if (value['kind'] != 'song' || _text(value['id']).isEmpty) {
        continue;
      }
      final key = identity(value);
      if (seen.contains(key)) {
        continue;
      }
      seen.add(key);
      result.add(Map<String, Object?>.of(value));
    }
    return result;
  }

  List<Track> get items => [for (final track in _items) Map<String, Object?>.of(track)];

  int get size => _items.length;

  bool get isEmpty => _items.isEmpty;

  bool get isLoading => _loading;

  int get index => _index;

  Map<String, Object?> at(int row) {
    if (row < 0 || row >= _items.length) {
      return <String, Object?>{};
    }
    return Map<String, Object?>.of(_items[row]);
  }

  Map<String, Object?> current() => at(_index);

  int indexOf(Map<String, Object?> track) {
    final key = identity(track);
    for (var row = 0; row < _items.length; row++) {
      if (identity(_items[row]) == key) {
        return row;
      }
    }
    return -1;
  }

  int indexOfId(String id) {
    for (var row = 0; row < _items.length; row++) {
      if (_text(_items[row]['id']) == id) {
        return row;
      }
    }
    return -1;
  }

  void cancelLoad() {
    ++_generation;
    _loading = false;
    _ids = <String>[];
    _missing = <String>[];
    _resolved.clear();
    _selectedKey = '';
  }

  void _publish(List<Track> values, String selectedKey) {
    _items
      ..clear()
      ..addAll(values);
    _index = -1;
    if (selectedKey.isNotEmpty) {
      for (var row = 0; row < _items.length; row++) {
        if (identity(_items[row]) == selectedKey) {
          _index = row;
          break;
        }
      }
    }
    _emit();
  }

  /// 用完整曲目替换队列；selected 非空时按歌曲身份选中。
  void replace(List<Track> values, [Map<String, Object?>? selected]) {
    cancelLoad();
    resetHistory();
    final key = (selected == null || selected.isEmpty) ? '' : identity(selected);
    _publish(_sanitized(values), key);
  }

  /// 同步服务端快照；调用方负责通知界面，避免中间状态被提前绘制。
  void syncSnapshot(List<Track> values, int row) {
    cancelLoad();
    resetHistory();
    _items
      ..clear()
      ..addAll(_sanitized(values));
    _index = (row >= 0 && row < _items.length) ? row : -1;
  }

  void select(int row) {
    _moveTo(row, true);
  }

  /// 保持已选中的同一首歌，否则查找或追加到队尾。
  void selectTrack(Map<String, Object?> track) {
    final key = identity(track);
    if (_index >= 0 && _index < _items.length && identity(_items[_index]) == key) {
      return;
    }
    final found = indexOf(track);
    if (found >= 0) {
      _moveTo(found, true);
      return;
    }
    if (track['kind'] == 'song' && _text(track['id']).isNotEmpty) {
      rememberCurrent();
      _items.add(Map<String, Object?>.of(track));
      _index = _items.length - 1;
      _selectedKey = key;
      _emit();
    }
  }

  bool enqueue(Map<String, Object?> track, {bool next = false}) {
    if (track['kind'] != 'song' || _text(track['id']).isEmpty) {
      return false;
    }
    // 本地曲目只进入本地队列，避免跨来源混入无法播放的条目。
    final api = _api;
    if (api != null && ((api.provider == 'local') != (track['provider'] == 'local'))) {
      return false;
    }
    final key = identity(track);
    for (var row = 0; row < _items.length; row++) {
      if (row != _index && identity(_items[row]) == key) {
        _items.removeAt(row);
        if (row < _index) {
          --_index;
        }
        break;
      }
    }
    final position = next ? math.max(0, _index + 1) : _items.length;
    _items.insert(position, Map<String, Object?>.of(track));
    _emit();
    return true;
  }

  bool remove(int row) {
    if (row < 0 || row >= _items.length || row == _index) {
      return false;
    }
    _items.removeAt(row);
    if (row < _index) {
      --_index;
    }
    _emit();
    return true;
  }

  /// 用同一首歌的新元数据刷新当前项，身份不一致时忽略。
  void updateCurrent(Map<String, Object?> track) {
    if (_index < 0 || _index >= _items.length || identity(_items[_index]) != identity(track)) {
      return;
    }
    _items[_index] = Map<String, Object?>.of(track);
    _emit();
  }

  void clearUpcoming(Map<String, Object?> current) {
    cancelLoad();
    resetHistory();
    if (current.isEmpty || current['kind'] != 'song') {
      _items.clear();
      _index = -1;
    } else {
      _items
        ..clear()
        ..add(Map<String, Object?>.of(current));
      _index = 0;
    }
    _emit();
  }

  void clear() {
    cancelLoad();
    resetHistory();
    _items.clear();
    _index = -1;
    _emit();
  }

  void rememberCurrent() {
    if (_index < 0 || _index >= _items.length) {
      return;
    }
    final key = identity(_items[_index]);
    if (_history.isNotEmpty && _history.last == key) {
      return;
    }
    _history.add(key);
    while (_history.length > shuffleHistoryLimit) {
      _history.removeAt(0);
    }
  }

  void _moveTo(int row, bool remember) {
    if (row < 0 || row >= _items.length || row == _index) {
      return;
    }
    if (remember) {
      rememberCurrent();
    }
    _index = row;
    _selectedKey = identity(_items[row]);
    _emit();
  }

  int _takeShuffledPrevious() {
    while (_history.isNotEmpty) {
      final key = _history.removeLast();
      for (var row = 0; row < _items.length; row++) {
        if (row != _index && identity(_items[row]) == key) {
          return row;
        }
      }
    }
    return -1;
  }

  void resetHistory() {
    _history.clear();
  }

  /// 计算并应用下一首；随机模式的后退回到实际播放过的上一首。-1 表示顺序播放已经结束。
  int navigate(int direction, String mode) {
    if (_items.isEmpty) {
      return -1;
    }
    // 单曲循环的前后项都指向当前歌曲，手动切换与播放结束共用同一索引。
    if (mode == 'one') {
      return _index >= 0 ? _index : 0;
    }
    // 随机模式下后退沿实际播放顺序回退，不能重新抽一首。
    if (mode == 'shuffle' && direction < 0) {
      final previous = _takeShuffledPrevious();
      if (previous >= 0) {
        _moveTo(previous, false);
        return previous;
      }
    }
    final count = _items.length;
    var selected = _index + direction;
    if (mode == 'shuffle' && direction > 0 && count > 1) {
      selected = (_index + 1 + _random.nextInt(count - 1)) % count;
    }
    if (selected >= count && mode == 'off') {
      return -1;
    }
    selected = (selected % count + count) % count;
    _moveTo(selected, true);
    return selected;
  }

  /// 按 ID 顺序补全缺失元数据后发布；ids 为空时直接使用 known。
  Future<void> load(List<String> ids, List<Track> known) async {
    cancelLoad();
    final api = _api;
    _provider = (api != null && api.provider.isNotEmpty) ? api.provider : 'netease';
    if (_index >= 0 && _index < _items.length) {
      _selectedKey = identity(_items[_index]);
    }
    final seen = <String>{};
    void appendId(String id) {
      if (id.isEmpty) {
        return;
      }
      final key = '$_provider:$id';
      if (seen.contains(key)) {
        return;
      }
      seen.add(key);
      _ids.add(id);
    }

    // 已在队列中的完整曲目（例如刚插入的当前曲）必须保留，不能被补全过程挤掉。
    void absorb(List<Track> values) {
      for (final value in values) {
        if (value['kind'] != 'song' || _text(value['id']).isEmpty) {
          continue;
        }
        _resolved['$_provider:${_text(value['id'])}'] = Map<String, Object?>.of(value);
        appendId(_text(value['id']));
      }
    }

    for (final value in ids) {
      appendId(value);
    }
    absorb(_items);
    absorb(known);
    _missing = <String>[];
    for (final value in _ids) {
      if (!_resolved.containsKey('$_provider:$value')) {
        _missing.add(value);
      }
    }
    _publishResolved();
    if (_missing.isEmpty) {
      return;
    }
    _loading = true;
    await _fetchNext();
  }

  List<Track> _orderedResolved() {
    final result = <Track>[];
    final seen = <String>{};
    for (final value in _ids) {
      final key = '$_provider:$value';
      final track = _resolved[key];
      if (track == null || track.isEmpty || seen.contains(key)) {
        continue;
      }
      seen.add(key);
      result.add(track);
    }
    return result;
  }

  void _publishResolved() {
    // 补全期间用户可能换曲，优先使用当前索引对应的歌曲身份。
    var selected = _selectedKey;
    if (_index >= 0 && _index < _items.length) {
      selected = identity(_items[_index]);
    }
    _publish(_orderedResolved(), selected);
  }

  Future<void> _fetchNext() async {
    if (_missing.isEmpty) {
      _loading = false;
      _publishResolved();
      return;
    }
    final batch = _missing.take(fetchBatchSize).toList();
    _missing = _missing.skip(fetchBatchSize).toList();
    final generation = _generation;
    final api = _api;
    if (api == null) {
      _loading = false;
      _publishResolved();
      return;
    }
    List<Track> values;
    try {
      values = await api.songs(batch);
    } catch (_) {
      if (generation != _generation) {
        return;
      }
      // 失败的批次直接跳过，未读取到的曲目不会以占位条目进入队列。
      _loading = false;
      _publishResolved();
      return;
    }
    if (generation != _generation) {
      return;
    }
    for (final value in values) {
      if (value['kind'] == 'song' && _text(value['id']).isNotEmpty) {
        _resolved['$_provider:${_text(value['id'])}'] = Map<String, Object?>.of(value);
      }
    }
    _publishResolved();
    await _fetchNext();
  }

  /// 恢复会话；只有完整曲目会立即进入队列，占位 ID 在后台补全。
  void restore(List<Track> saved, int savedIndex, bool hydrate) {
    cancelLoad();
    final ids = <String>[];
    final complete = <Track>[];
    for (final value in saved) {
      if (value['kind'] != 'song' || _text(value['id']).isEmpty) {
        continue;
      }
      ids.add(_text(value['id']));
      if (value['deferred'] != true) {
        complete.add(value);
      }
    }
    final selected =
        (savedIndex >= 0 && savedIndex < saved.length) ? saved[savedIndex] : <String, Object?>{};
    replace(complete, selected['deferred'] == true ? <String, Object?>{} : selected);
    if (hydrate) {
      load(ids, complete);
    }
  }

  List<Track> toJson() => items;
}
