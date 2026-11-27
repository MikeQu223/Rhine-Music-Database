/// Qt -> Flutter 迁移 · 歌词侧的纯函数部分（的运行时依赖）。
///
/// Qt 移植源：Qt/src/LyricsController.cpp
///   :60-64    全局偏移的读取与夹取（preference("lyrics-global-offset-ms") → toDouble → isfinite → clamp）
///   :86-102   validDocument
///   :117-131  activeLineIndex（offset 之后的时间轴 + upper_bound）
///   :473-476  accept 里从 document 抽取 starts
///   :501-509  sync 的时间轴（position + document.offsetMs + offsetMs）
///   :534-544  applyGlobalOffset 的写回文本（QString::number）
///
/// 歌词时间轴的纯函数层：偏移夹取与偏好文本语义、文档校验、starts 抽取、活动行二分、
/// QJson 值语义的默认值兜底。无状态、无 IO、不 import flutter、不 import lib/data。
///
/// 反例约束（KEEP OUT）：
/// - 不做插值：Qt 只在行 startMs 上取 upper_bound（:504、:124），两行之间没有过渡值，
///   也不按字/按帧推进；
/// - 不引入 Qt 之外的阈值：本文件只有 :63/:515 的 10000 与 :89 的 5000，外加 QJsonValue::toInt
///   自带的 int32 区间（qjsonvalue.cpp:695-700、qnumeric_p.h:214-221）——那是 Qt 的类型约束，
///   不是歌词阈值；
/// - 不排序 lines、不校验 starts 是否升序：Qt 的 upper_bound 直接假定升序（:504），补排序就是新行为；
/// - 不解析 lrc / 纯文本、不构造文档：取词与归一化属于调用方；
/// - 不缓存、不做偏好的读写实现：那是宿主注入的端口。
library;

/// 歌词偏移的夹取边界（毫秒）：Qt/src/LyricsController.cpp:63（读取时）与 :515（调节时）。
const double lyricsOffsetLimitMs = 10000;

/// 歌词文档的行数上限：Qt/src/LyricsController.cpp:89
/// （`document["lines"].toArray().size() > 5000` → 非法）。
const int lyricsDocumentLineLimit = 5000;

/// Qt 认可的 timing 取值：Qt/src/LyricsController.cpp:88 的
/// `QStringList{"line", "word", "none"}.contains(document["timing"].toString())`。
const List<String> lyricsTimings = <String>['line', 'word', 'none'];

/// `std::clamp(value, -10000., 10000.)` 的等价物（Qt/src/LyricsController.cpp:63、:515）。
///
/// 写法与 lib/hud/pages/desktop_lyrics_settings.dart:631-648 的 desktopLyricsClampDouble 一致
/// （`value < minimum ? minimum : (maximum < value ? maximum : value)`，不写 isNaN 早退）：
/// std::clamp 的比较对 NaN 恒为假，NaN 会原样穿过，这里同样原样返回。
double clampLyricsOffsetMs(double value) {
  return value < -lyricsOffsetLimitMs
      ? -lyricsOffsetLimitMs
      : (lyricsOffsetLimitMs < value ? lyricsOffsetLimitMs : value);
}

/// 从偏好文本解析全局偏移；返回 null 表示「没有可用值」，调用方保持 Qt 的初值 0（LyricsController.h:64）。
///
/// Qt/src/LyricsController.cpp:60-64：
/// ```cpp
/// bool validOffset = false;
/// const auto savedOffset = host->preference("lyrics-global-offset-ms").toDouble(&validOffset);
/// if (validOffset && std::isfinite(savedOffset)) {
///     m_globalOffsetMs = std::clamp(savedOffset, -10000., 10000.);
/// }
/// ```
/// 三个条件缺一不可：能解析（validOffset）、有限（:62 的 isfinite）、然后才夹取（:63）。
/// QString::toDouble 会先去掉首尾空白再按 C 语言环境解析，故这里先 trim。
///
/// 与 QString::toDouble 的拼写差异不影响结果：Dart 的 double.tryParse 不认 C99 的 "inf"/"nan"
/// 拼写（只认 "Infinity"/"NaN"），而这几种文本即便被解析出来也是非有限值，
/// 在 :62 的 isfinite 处一律被拒——两条路径的最终答案都是 null。
double? parseLyricsOffsetPreference(String? text) {
  if (text == null) {
    return null;
  }
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final value = double.tryParse(trimmed);
  if (value == null || !value.isFinite) {
    return null;
  }
  return clampLyricsOffsetMs(value);
}

/// 全局偏移写回偏好时的文本，格式等价于 `QString::number(value, 'g', 6)`：
/// 6 位有效数字、去尾零，|value| < 1e-4 才用指数形式。取值域 ±10000，实际总是定点。
String formatLyricsOffsetPreference(double value) {
  // printf("%g") 的非有限拼写（小写），Qt 的 QString::number 同形。
  if (value.isNaN) {
    return 'nan';
  }
  if (value == double.infinity) {
    return 'inf';
  }
  if (value == double.negativeInfinity) {
    return '-inf';
  }
  // toStringAsExponential(5) 恰好给 6 位有效数字，与 'g'/precision 6 的舍入位一致。
  final exponential = value.toStringAsExponential(5); // 形如 "-1.23457e+3"
  final marker = exponential.indexOf('e');
  final mantissa = exponential.substring(0, marker);
  final exponent = int.parse(exponential.substring(marker + 1));
  if (exponent < -4 || exponent >= 6) {
    // %g 的指数分支：尾零去掉，指数符号必带、至少两位。
    final digits = exponent.abs().toString().padLeft(2, '0');
    return '${_stripTrailingZeros(mantissa)}e${exponent < 0 ? '-' : '+'}$digits';
  }
  // %g 的定点分支：小数点后 5 - exponent 位，再去尾零与孤立的小数点。
  return _stripTrailingZeros(value.toStringAsFixed(5 - exponent));
}

String _stripTrailingZeros(String text) {
  if (!text.contains('.')) {
    return text;
  }
  var end = text.length;
  while (end > 0 && text[end - 1] == '0') {
    end -= 1;
  }
  if (end > 0 && text[end - 1] == '.') {
    end -= 1;
  }
  return text.substring(0, end);
}

/// QJsonValue::toDouble() 的默认值语义：非数值（缺失/字符串/对象/数组/布尔/null）→ 0。
///
/// 直接对应 Qt/src/LyricsController.cpp:119（document["offsetMs"]）、:503（m_document["offsetMs"]）、
/// :475（每一行的 startMs）与 :657-659（快照里的三个 double）。
double lyricsNumberValue(Object? value) => value is num ? value.toDouble() : 0;

/// QJsonValue::toInt(defaultValue) 的默认值语义：不是「能精确表示成 int 的整数」→ [fallback]。
///
/// 直接对应 Qt/src/LyricsController.cpp:87（version 判定，默认值 0）与 :656
/// （`snapshot["index"].toInt(-1)`，默认值 -1）。
///
/// 判据取自 vendored Qt 源码，不按「向零截断」推断：
/// - third_party/qt/qtbase/src/corelib/serialization/qjsonvalue.cpp:683-705：Double 分支走
///   `convertDoubleTo<int>`，失败即落到 defaultValue；doc 原文 :683-684 是
///   "If type() is not Double or the value is not a whole number, the defaultValue will be
///   returned"；
/// - third_party/qt/qtbase/src/corelib/global/qnumeric_p.h:202-227（x86-64 路径）：先按
///   CVTTSD2SI 向零截断，再把整数换回 double 与原值比较，不等就失败；:214-221 处理越界
///   （NaN 的比较恒假，±Inf 落进越界分支），同样是失败。
///
/// 于是 1.5 得到的是 defaultValue 而不是 1；NaN/±Inf 在 Qt 里安静地给默认值，
/// 而 Dart 的 double.toInt() 对它们会抛 UnsupportedError，所以这里先判 isFinite。
/// int 输入按 Qt :695-700 的 Integer 分支判 int32 可表示。
int lyricsIntegerValue(Object? value, {int fallback = 0}) {
  if (value is int) {
    return value >= -2147483648 && value <= 2147483647 ? value : fallback;
  }
  if (value is! num) {
    return fallback;
  }
  final number = value.toDouble();
  if (!number.isFinite) {
    return fallback;
  }
  if (number < -2147483648.0 || number > 2147483647.0) {
    return fallback;
  }
  if (number != number.truncateToDouble()) {
    return fallback;
  }
  return number.toInt();
}

/// QJsonValue::toString(defaultValue) 的默认值语义：非字符串 → [fallback]。
///
/// 直接对应 Qt/src/LyricsController.cpp:82（`track["provider"].toString("netease")`）、
/// :88（timing，默认值空串）、:642-648（快照文本键，默认值空串）与 :653/:660
/// （`status` / `localSource` 的快照默认值 "idle" / "auto"）。
String lyricsTextValue(Object? value, {String fallback = ''}) =>
    value is String ? value : fallback;

/// QJsonValue::toObject() 的默认值语义：非对象 → 空对象。
///
/// 直接对应 Qt/src/LyricsController.cpp:95（每行 toObject()）与 :652（快照 document）。
/// 键一律归一成 String（QJsonObject 的键只能是字符串），非字符串键按 toString 处理。
Map<String, Object?> lyricsObjectValue(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }
  return const <String, Object?>{};
}

/// Qt/src/LyricsController.cpp:86-102 `LyricsController::validDocument` 的等价物。
///
/// 逐条件对齐原文：
/// - :87  `document["version"].toInt() != 1`：非数值、非整数、int32 越界一律按 0
///   （见 [lyricsIntegerValue]），所以 1.5 与 1.0 不同：1.0 合法，1.5 判非法；
/// - :88  timing 必须在 {"line","word","none"} 内，非字符串按空串落空；
/// - :89  lines 必须是数组且元素数不超过 5000；
/// - :90  plainText 必须是字符串；:90-91 offsetMs 必须是数值且有限；
/// - :94-100 每一行 startMs 必须是有限数值、text 必须是字符串；
///        非对象元素经 toObject() 变成空对象后在 startMs 处落空（与 Qt 同）。
///
/// 数值判定用 `is num` 而不是复刻 Qt 的 isDouble()（:90、:96）：Qt 的 JSON 数字一律存成
/// double，而 Dart 的 json.decode 会把整数值解成 int，所以这里把 int 视作 Qt 的 Double。
/// 这是有意的等价，不是放宽——测试里 `'version': 1`、`'startMs': 0` 这类 int 文档正因此合法。
bool validLyricsDocument(Map<String, Object?> document) {
  final lines = document['lines'];
  if (lyricsIntegerValue(document['version']) != 1 ||
      !lyricsTimings.contains(lyricsTextValue(document['timing'])) ||
      lines is! List ||
      lines.length > lyricsDocumentLineLimit ||
      document['plainText'] is! String ||
      document['offsetMs'] is! num ||
      !lyricsNumberValue(document['offsetMs']).isFinite) {
    return false;
  }
  for (final value in lines) {
    final line = lyricsObjectValue(value);
    if (line['startMs'] is! num ||
        !lyricsNumberValue(line['startMs']).isFinite ||
        line['text'] is! String) {
      return false;
    }
  }
  return true;
}

/// Qt/src/LyricsController.cpp:473-476 的 starts 抽取（accept 里逐行 append startMs）。
///
/// `line.toObject()["startMs"].toDouble()` 对非数值给 0（QVariant 默认值语义），这里同样按 0 兜底；
/// 正常路径只有 validLyricsDocument 通过的文档才会进来，所以兜底不会改写任何合法值。
/// 与 Qt 一样保持文档顺序，不排序（:504 的 upper_bound 依赖这个顺序）。
List<double> lyricsDocumentStarts(Map<String, Object?> document) {
  final lines = document['lines'];
  if (lines is! List) {
    return <double>[];
  }
  return <double>[
    for (final value in lines) lyricsNumberValue(lyricsObjectValue(value)['startMs']),
  ];
}

/// Qt/src/LyricsController.cpp:503 的文档级偏移：`m_document["offsetMs"].toDouble()`，非数值 → 0。
double lyricsDocumentOffsetMs(Map<String, Object?> document) =>
    lyricsNumberValue(document['offsetMs']);

/// Qt/src/LyricsController.cpp:504、:120-130 的 upper_bound 二分：
/// 返回最后一个 `starts[i] <= time` 的下标；早于第一行时返回 -1。
///
/// 与 Qt 完全同构（:120-130 的 lower/upper 循环），同样是「不排序、不校验升序」：
/// Qt 默认 starts 升序，这里不补校验，也不引入容差（time 恰好等于某行 start 时命中该行，
/// 因为比较是 `<=`）。
/// time 为 NaN 时比较恒假，二分收敛到 lower == 0，结果同样是 -1。
int lyricsLineIndexAt(List<double> starts, double time) {
  var lower = 0;
  var upper = starts.length;
  while (lower < upper) {
    final middle = (lower + upper) ~/ 2;
    if (starts[middle] <= time) {
      lower = middle + 1;
    } else {
      upper = middle;
    }
  }
  return lower - 1;
}

/// Qt `LyricsController::activeLineIndex(document, positionMs, offsetMs = 0)`
/// （Qt/src/LyricsController.h:38、.cpp:117-131）。
///
/// 时间轴 = positionMs + 文档级 offsetMs + 传入的 offsetMs（:119 原文
/// `positionMs + document["offsetMs"].toDouble() + offsetMs`），
/// 再在 lines 的 startMs 上二分（:120-130）。空文档返回 -1（Qt 对空 lines 同样返回 -1）。
///
/// [offsetMs] 命名参数对应 Qt 的默认实参 `= 0`（.h:38）。
int lyricsActiveLineIndex(
  Map<String, Object?> document,
  double positionMs, {
  double offsetMs = 0,
}) {
  final time = positionMs + lyricsDocumentOffsetMs(document) + offsetMs;
  return lyricsLineIndexAt(lyricsDocumentStarts(document), time);
}

/// QJsonObject 值语义的深拷贝。
///
/// Qt/src/LyricsController.cpp:471-472 是 `document["trackKey"] = ...; m_document = document;`：
/// QJsonObject 是隐式共享的值类型，赋值之后再改调用方手里的 document 不会影响 m_document。
/// Dart 的 Map 是引用，`accept` 必须先拷贝才能保持同一可见语义。
Map<String, Object?> copyLyricsDocument(Map<String, Object?> document) {
  return <String, Object?>{
    for (final entry in document.entries) entry.key: copyLyricsValue(entry.value),
  };
}

/// [copyLyricsDocument] 的递归体：Map/List 逐层复制，其余按不可变叶子原样返回。
Object? copyLyricsValue(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): copyLyricsValue(entry.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) copyLyricsValue(item)];
  }
  return value;
}
