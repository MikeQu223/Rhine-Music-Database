/// boot 曲线源：载入 Assets/animation/boot-tracks.json 并复刻 Qt 的采样语义。
///
/// 载入时做特殊键映射（brandX 按下标、logo.draw、orbit.sides/orbit），未命中 key 返回 0；
/// track() 是单调 Hermite 插值，端点保留斜率、内部异号切线归零。
/// 失败只记录 error 并保持 0 值，不抛到 UI。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// boot 曲线资产路径（pubspec.yaml:65-67 已声明 `Assets/animation/`）。
const String kBootTracksAssetPath = 'Assets/animation/boot-tracks.json';

/// 曲线注入 seam：logo 描边、scan 弧与轨道、brand 行、highlightKeys、ringOpacity 等。
abstract class BootTrackSource {
  const BootTrackSource();

  /// [key] 为 Qt 侧 track 名，[frame] 为时间轴的 `measuredFrame`（= time * 25，未取整）；
  /// 未载入/未命中时返回 0（Qt/src/BootTimeline.cpp:64-67）。
  double value(String key, double frame);
}

/// 零曲线源：任何 track 一律 0（显式降级/测试用，不再是生产默认）。
class ZeroBootTrackSource extends BootTrackSource {
  const ZeroBootTrackSource();

  @override
  double value(String key, double frame) => 0;
}

/// 一条关键帧（Qt/src/SceneMotion.h 的 Curve 元素 {frame, value}）。
class BootTrackKey {
  const BootTrackKey(this.frame, this.value);

  final double frame;
  final double value;

  @override
  bool operator ==(Object other) =>
      other is BootTrackKey && other.frame == frame && other.value == value;

  @override
  int get hashCode => Object.hash(frame, value);

  @override
  String toString() => 'BootTrackKey($frame, $value)';
}

/// 已解析的 boot 曲线集合，键与 Qt 的 m_tracks 完全一致（BootTimeline.cpp:26-62）。
class BootTrackCurves {
  const BootTrackCurves.empty() : _curves = const <String, List<BootTrackKey>>{};

  BootTrackCurves._(this._curves);

  final Map<String, List<BootTrackKey>> _curves;

  /// 曲线键数量（诊断用）。
  int get keyCount => _curves.length;

  /// 是否包含某键（诊断用）。
  bool hasKey(String key) => _curves.containsKey(key);

  /// Qt/src/BootTimeline.cpp:64-67：未命中返回 0，否则 [bootTrackValue]。
  double value(String key, double frame) {
    final List<BootTrackKey>? curve = _curves[key];
    if (curve == null || curve.isEmpty) {
      return 0;
    }
    return bootTrackValue(curve, frame);
  }

  /// 解析 boot-tracks.json 的根对象。结构不符抛 [FormatException]（由载入器转成诊断错误）。
  static BootTrackCurves parse(Object? json) {
    if (json is! Map) {
      throw const FormatException('boot-tracks root must be a JSON object');
    }
    final Map<String, List<BootTrackKey>> curves = <String, List<BootTrackKey>>{};
    final Map<Object?, Object?> root = json;

    for (final MapEntry<Object?, Object?> entry in root.entries) {
      final Object? key = entry.key;
      if (key is! String) {
        throw const FormatException('boot-tracks keys must be strings');
      }
      final Object? value = entry.value;
      if (key == 'brandX') {
        // BootTimeline.cpp:39-42：数组下标即帧。
        if (value is! List) {
          throw FormatException('$key must be a JSON array');
        }
        final List<BootTrackKey> curve = <BootTrackKey>[];
        for (int index = 0; index < value.length; index++) {
          curve.add(BootTrackKey(index.toDouble(), _number(key, value[index])));
        }
        curves[key] = _checked(key, curve);
      } else if (key == 'logo.draw') {
        // BootTimeline.cpp:43-47：每行 [frame, start, end] → drawStart/drawEnd。
        final List<Object?> rows = _rows(key, value, minLength: 3);
        final List<BootTrackKey> starts = <BootTrackKey>[];
        final List<BootTrackKey> ends = <BootTrackKey>[];
        for (final Object? row in rows) {
          final List<Object?> cells = _cells(key, row, minLength: 3);
          final double frame = _number(key, cells[0]);
          starts.add(BootTrackKey(frame, _number(key, cells[1])));
          ends.add(BootTrackKey(frame, _number(key, cells[2])));
        }
        curves['logo.drawStart'] = _checked('logo.drawStart', starts);
        curves['logo.drawEnd'] = _checked('logo.drawEnd', ends);
      } else if (key == 'orbit.sides') {
        // BootTimeline.cpp:48-54：每行 [frame, c0..c8] → orbit.column0..8。
        final List<Object?> rows = _rows(key, value, minLength: 10);
        final List<List<BootTrackKey>> columns = <List<BootTrackKey>>[
          for (int column = 0; column < 9; column++) <BootTrackKey>[],
        ];
        for (final Object? row in rows) {
          final List<Object?> cells = _cells(key, row, minLength: 10);
          final double frame = _number(key, cells[0]);
          for (int column = 0; column < 9; column++) {
            columns[column].add(BootTrackKey(frame, _number(key, cells[column + 1])));
          }
        }
        for (int column = 0; column < 9; column++) {
          curves['orbit.column$column'] = _checked('orbit.column$column', columns[column]);
        }
      } else if (key == 'orbit.orbit') {
        // BootTimeline.cpp:55-61：以 (959.5, 539.5) 为圆心拆成 angle/radius。
        final List<Object?> rows = _rows(key, value, minLength: 3);
        final List<BootTrackKey> angles = <BootTrackKey>[];
        final List<BootTrackKey> radii = <BootTrackKey>[];
        for (final Object? row in rows) {
          final List<Object?> cells = _cells(key, row, minLength: 3);
          final double frame = _number(key, cells[0]);
          final double x = _number(key, cells[1]) - 959.5; // BootTimeline.cpp:57
          final double y = _number(key, cells[2]) - 539.5; // BootTimeline.cpp:58
          angles.add(BootTrackKey(frame, math.atan2(y, x))); // :59
          radii.add(BootTrackKey(frame, math.sqrt(x * x + y * y))); // :60
        }
        curves['orbit.angle'] = _checked('orbit.angle', angles);
        curves['orbit.radius'] = _checked('orbit.radius', radii);
      } else {
        // BootTimeline.cpp:32-37：普通键逐行 [frame, value]。
        final List<Object?> rows = _rows(key, value, minLength: 2);
        curves[key] = _checked(key, <BootTrackKey>[
          for (final Object? row in rows)
            BootTrackKey(
              _number(key, _cells(key, row, minLength: 2)[0]),
              _number(key, _cells(key, row, minLength: 2)[1]),
            ),
        ]);
      }
    }
    return BootTrackCurves._(Map<String, List<BootTrackKey>>.unmodifiable(curves));
  }

  static List<Object?> _rows(String key, Object? value, {required int minLength}) {
    if (value is! List) {
      throw FormatException('$key must be a JSON array');
    }
    for (final Object? row in value) {
      if (row is! List || row.length < minLength) {
        throw FormatException('$key rows must be arrays of length >= $minLength');
      }
    }
    return value;
  }

  static List<Object?> _cells(String key, Object? row, {required int minLength}) {
    if (row is! List || row.length < minLength) {
      throw FormatException('$key rows must be arrays of length >= $minLength');
    }
    return row;
  }

  static double _number(String key, Object? value) {
    if (value is! num) {
      throw FormatException('$key has a non-numeric value: $value');
    }
    return value.toDouble();
  }

  static List<BootTrackKey> _checked(String key, List<BootTrackKey> curve) {
    final List<BootTrackKey> frozen = List<BootTrackKey>.unmodifiable(curve);
    for (int index = 1; index < frozen.length; index++) {
      if (frozen[index].frame <= frozen[index - 1].frame) {
        throw FormatException('$key frames must be strictly increasing');
      }
    }
    return frozen;
  }
}

/// Qt/src/SceneMotion.cpp:52-95 的 track() 等价实现（stationaryEnds = false）。
///
/// 空曲线 → 0；time <= 首帧 → 首值；time >= 末帧 → 末值；否则单调 Hermite：
/// - 端点切线 = 端点斜率（开场保留端点斜率）；
/// - 内部切线：相邻斜率异号（a*b <= 0）→ 0，否则按帧距加权 `(w0+w1)/(w0/a+w1/b)`；
/// - 区间由 lower_bound（首个 frame >= time）定位；返回值是 Qt 的四项 Hermite 基函数组合。
double bootTrackValue(List<BootTrackKey> keys, double frame) {
  if (keys.isEmpty) {
    return 0;
  }
  if (frame <= keys.first.frame) {
    return keys.first.value;
  }
  final int last = keys.length - 1;
  if (frame >= keys.last.frame) {
    return keys.last.value;
  }

  double slope(int index) =>
      (keys[index + 1].value - keys[index].value) / (keys[index + 1].frame - keys[index].frame);

  double tangent(int index) {
    if (index == 0 || index == last) {
      return slope(index == 0 ? 0 : last - 1);
    }
    final double a = slope(index - 1);
    final double b = slope(index);
    if (a * b <= 0) {
      return 0;
    }
    final double left = keys[index].frame - keys[index - 1].frame;
    final double right = keys[index + 1].frame - keys[index].frame;
    final double w0 = 2 * right + left;
    final double w1 = right + 2 * left;
    return (w0 + w1) / (w0 / a + w1 / b);
  }

  int low = 0;
  int high = keys.length;
  while (low < high) {
    final int mid = (low + high) >> 1;
    if (keys[mid].frame < frame) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  final int index = low - 1;
  final double span = keys[index + 1].frame - keys[index].frame;
  final double amount = (frame - keys[index].frame) / span;
  final double square = amount * amount;
  final double cube = square * amount;
  return (2 * cube - 3 * square + 1) * keys[index].value +
      (cube - 2 * square + amount) * span * tangent(index) +
      (-2 * cube + 3 * square) * keys[index + 1].value +
      (cube - square) * span * tangent(index + 1);
}

/// 载入结果：成功带 curves，失败带 error；永不抛到调用方。
class BootTrackLoad {
  const BootTrackLoad.loaded(BootTrackCurves this.curves) : error = null;

  const BootTrackLoad.failed(String this.error) : curves = null;

  final BootTrackCurves? curves;
  final String? error;

  bool get loaded => curves != null;
}

/// 读取并解析 boot-tracks.json（rootBundle 或注入的 [bundle]）。
///
/// 任何异常（平台未初始化、资产缺失、JSON 非法、结构不符）都收敛为 [BootTrackLoad.failed]。
Future<BootTrackLoad> loadBootTrackCurves({
  AssetBundle? bundle,
  String assetPath = kBootTracksAssetPath,
}) async {
  try {
    final String source = await (bundle ?? rootBundle).loadString(assetPath);
    final Object? decoded = jsonDecode(source);
    return BootTrackLoad.loaded(BootTrackCurves.parse(decoded));
  } catch (error) {
    return BootTrackLoad.failed('$error');
  }
}

/// 生产默认曲线源：异步载入 boot-tracks.json；载入前/失败时 value 返回 0。
///
/// 载入完成（成功或降级）notifyListeners 一次，BootController 转发后页面重绘；
/// 不重置 BootController 的 35s 锚点，也不新增 ticker。
class AssetBootTrackSource extends BootTrackSource with ChangeNotifier {
  AssetBootTrackSource({this._bundle, this.assetPath = kBootTracksAssetPath});

  final AssetBundle? _bundle;
  final String assetPath;

  BootTrackCurves? _curves;
  String? _error;
  bool _started = false;
  bool _loading = false;
  bool _disposed = false;

  /// 曲线数量（诊断用；载入前为 0）。
  int get curveCount => _curves?.keyCount ?? 0;

  /// 载入是否已成功（可查询真实曲线）。
  bool get loaded => _curves != null;

  /// 是否处于降级态（资源缺失/解析失败）。
  bool get degraded => _error != null;

  /// 载入错误（成功时为 null）；用于诊断，不静默。
  String? get loadError => _error;

  bool get loadStarted => _started;

  bool get loading => _loading;

  @override
  double value(String key, double frame) => _curves?.value(key, frame) ?? 0;

  /// 幂等载入；重入直接返回。永不抛。
  Future<void> load() async {
    if (_started) {
      return;
    }
    _started = true;
    _loading = true;
    final BootTrackLoad result = await loadBootTrackCurves(bundle: _bundle, assetPath: assetPath);
    _curves = result.curves;
    _error = result.error;
    _loading = false;
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
