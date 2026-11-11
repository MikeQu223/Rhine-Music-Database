// tool/perf/collect_frame_times.dart
//
// T52-S01（OPS86-A35）帧时间采集器 —— 纯 Dart、离线、只读输入。
//
// 目的
//   Qt→Flutter 对照需要一份“只记录、不下结论”的帧时间报告：把设备上导出的逐帧
//   JSONL 归一化成可复核的 JSON，供 T50/T51 的对照与 T52 的 30 min 稳定切片使用。
//
// 边界（硬约束，任何一条都不得放宽）
//   1. 只 import dart:convert 与 dart:io。不 import Flutter，不联网，不 fork 进程
//      （不调用 adb / 外部命令），不读设备。
//   2. 不内置任何阈值：没有 16.6 ms、没有 60 fps、没有 jank 1%、没有 +10%，也没有
//      “通过/失败”字段。计划 :721 与 9.2 节要求性能比例“拟议待冻结”，
//      docs/flutter-migration/01-slice.md:265 把性能标成 NO_THRESHOLD。
//      漂移标记只给带符号的差值，不给判定。
//   3. 不伪造设备数据：报告里的每一帧都是输入行的原值；派生值只做确定性算术。
//   4. 可复现：同一输入字节 + 同一参数 ⇒ 同一份 JSON。报告正文不写时间戳、不写
//      随机数、不写 pid（只有临时文件名里带 pid，落盘后立刻改名，内容不含它），
//      键序固定，排序与分位数口径固定。
//
// 输入（JSONL：一行一个帧样本）
//   {"deviceId":"opd2511","sceneId":"archive","runId":"r1","frameIndex":0,
//    "frameTimeMs":16.7,"timestampMs":1700000000000,"firstFrame":true,
//    "memoryMb":412.5,"startupMs":1830.2}
//   9 个字段全部必填；校验顺序即下面的字段顺序，保证同一坏行总得到同一原因：
//     deviceId / sceneId / runId        string，非空（trim 后为空视为空）
//     frameIndex / timestampMs          int，>= 0（不接受 1.0 这种浮点写法）
//     frameTimeMs / memoryMb / startupMs num，有限且 >= 0
//     firstFrame                        bool
//   缺字段 / 类型错 / 负数 / 非有限值 ⇒ 整行拒绝并计数；其它行照常采集。
//   允许 0（契约只拒绝负数和非有限值）；0 会让 p50 可能为 0，比率退化为 null。
//   同一 runId 只允许一个 (deviceId, sceneId) 组合。出现第二种组合 ⇒ 该 runId 的
//   所有帧全部拒绝（不做“只丢冲突行”的部分保留），并记进 rejectedRuns。
//
// 输出
//   {schema, tool, input(含输入字节指纹), contract, counts, rejections,
//    rejectedRuns, runs[]}
//   runs[].samples 逐帧保留（数值字段统一成 JSON double，不改值）；
//   runs[].summary 只做确定性派生：帧数、min/p50/p95/p99/max/mean、首帧时间、
//   内存峰值、启动耗时；runs[].stability 按 timestampMs 切窗口，窗口内再切
//   _segmentsPerWindow 段，给带符号的漂移/退化标记，并用 windowDriftRollup
//   把各窗口的标记汇总（同样只有符号与计数，没有判定）。
//   全行被拒也照样写出报告（0 个 run）：拒绝计数本身是待复核的数据，不是失败。
//
// 30 分钟语义
//   时长只由 timestampMs 决定：observedSpanMs = lastTimestampMs - firstTimestampMs。
//   样本数、帧时间之和都不参与时长推断。observedSpanMs < windowMs ⇒
//   stability.status = UNMEASURED；未满窗口不做漂移评估（drift.status =
//   NOT_EVALUATED），避免把半截数据说成 30 min。静态画面帧率低是正常行为
//   （计划 :722“静止低 fps 正常”），所以“帧少 / 有间隙”既不算未覆盖，也不算退化。
//
// CLI
//   dart run tool/perf/collect_frame_times.dart --in <jsonl> --out <json> [--window-minutes 30]
//   退出码：0 = 已写出；2 = 参数/输入错误（不写出）；1 = 报告写入失败。
//
// 本原子禁止执行 dart/flutter/gradle/adb，因此下面的代码没有跑过 analyze/run；
// 未执行清单与残余风险见 .agents/parity-20261109/reports/OPS86-A35.json。

import 'dart:convert';
import 'dart:io';

/// 采集器标识，写进报告的 tool 段。
const String _toolPath = 'tool/perf/collect_frame_times.dart';
const String _toolRevision = 'T52-S01';
const String _reportSchema = 'rhine.frame-times/1';

/// 默认稳定性窗口（分钟）。CLI 的 --window-minutes 覆盖它。
const double _defaultWindowMinutes = 30.0;

/// 每个窗口切成的段数。段只用于“窗口内漂移”比较，不参与 30 min 判定。
const int _segmentsPerWindow = 6;

/// 拒绝样例上限（只影响报告体积，不影响计数）。
const int _maxRejectionExamples = 8;

/// distinctValues 上限（只影响报告体积）。
const int _maxDistinctStartupValues = 8;

/// 窗口下限：段长 = windowMs ~/ _segmentsPerWindow，必须 >= 1 ms。
const int _minWindowMs = _segmentsPerWindow * 1000;

const String _markerSemantics =
    'signed deltas only; no threshold and no pass/fail verdict';

const String _runConflictReason = 'identifier_conflict';

/// 9 个必填字段，顺序即校验顺序。
const List<String> _requiredFields = <String>[
  'deviceId',
  'sceneId',
  'runId',
  'frameIndex',
  'frameTimeMs',
  'timestampMs',
  'firstFrame',
  'memoryMb',
  'startupMs',
];

const List<String> _stringFields = <String>['deviceId', 'sceneId', 'runId'];
const List<String> _integerFields = <String>['frameIndex', 'timestampMs'];
const List<String> _numberFields = <String>[
  'frameTimeMs',
  'memoryMb',
  'startupMs',
];
const List<String> _booleanFields = <String>['firstFrame'];

final Set<String> _requiredFieldSet = _requiredFields.toSet();

/// 行级拒绝原因。预先按固定顺序种进报告，避免跨报告聚合时把“0 次”误当成未知原因。
const List<String> _lineRejectReasons = <String>[
  'json_syntax_error',
  'line_not_a_json_object',
  'missing_field',
  'field_wrong_type',
  'empty_identifier',
  'negative_value',
  'non_finite_value',
];

const String _usageLine =
    'dart run tool/perf/collect_frame_times.dart --in <jsonl> --out <json> '
    '[--window-minutes 30]';

Future<void> main(List<String> arguments) async {
  exitCode = await _run(arguments);
}

Future<int> _run(List<String> arguments) async {
  _Options options;
  try {
    options = _Options.parse(arguments);
  } on _HelpRequested {
    stdout.write(_usageText());
    return 0;
  } on _UsageError catch (error) {
    stderr.writeln('collect_frame_times: ${error.message}');
    stderr.writeln(_usageLine);
    return 2;
  }

  _Input input;
  try {
    input = await _readInput(options.inputPath);
  } on FileSystemException catch (error) {
    stderr.writeln(
      'collect_frame_times: 无法读取输入 ${options.inputPath}：${error.message}',
    );
    return 2;
  } on FormatException catch (error) {
    stderr.writeln('collect_frame_times: 输入不是合法 UTF-8：${error.message}');
    return 2;
  }
  if (input.records == 0) {
    stderr.writeln(
      'collect_frame_times: 输入没有 JSONL 记录：${options.inputPath}',
    );
    return 2;
  }

  final _Report report = _buildReport(options, input);
  final JsonEncoder encoder = JsonEncoder.withIndent('  ');
  final String encoded = '${encoder.convert(report.json)}\n';
  try {
    await _writeReport(options.outputPath, encoded);
  } on FileSystemException catch (error) {
    stderr.writeln(
      'collect_frame_times: 无法写出 ${options.outputPath}：${error.message}',
    );
    return 1;
  }
  stdout.writeln(
    'collect_frame_times: wrote ${options.outputPath} '
    '(runs=${report.acceptedRuns}, frames=${report.acceptedFrames}, '
    'rejectedLines=${report.rejectedLines}, '
    'rejectedRuns=${report.rejectedRuns})',
  );
  return 0;
}

String _usageText() {
  return '''
tool/perf/collect_frame_times.dart（$_toolRevision）—— 帧时间采集器（纯 Dart、离线）

用法:
  $_usageLine

参数:
  --in <path>            必填。JSONL 输入，一行一个帧样本。
  --out <path>           必填。JSON 报告输出路径。
  --window-minutes <n>   可选，默认 $_defaultWindowMinutes。稳定性窗口长度（分钟）。
  -h, --help             打印本说明。

输入字段（全部必填；缺失/类型错/负数/非有限值 ⇒ 整行拒绝并计数）:
  deviceId     string 非空    设备标识
  sceneId      string 非空    场景标识
  runId        string 非空    一次采集的唯一标识
  frameIndex   int    >= 0    该 run 内的帧序号
  frameTimeMs  num    >= 0    帧时间（毫秒）
  timestampMs  int    >= 0    帧时间戳（毫秒）
  firstFrame   bool           是否该 run 的第一帧
  memoryMb     num    >= 0    进程内存（MB）
  startupMs    num    >= 0    启动耗时（毫秒）

退出码:
  0  已写出报告
  1  报告写入失败
  2  参数/输入错误（未写出报告）

本工具不联网、不调用 adb 或任何外部命令、不 import Flutter；报告里没有通过/
失败判定，也没有任何阈值。
''';
}

/// 派生统计量的统一四舍五入：6 位小数，避免浮点尾巴让同一输入产生不同文本。
/// 直接取自样本的值（内存峰值、启动耗时、首帧帧时间、逐帧 samples）不做此处理。
double _roundDerived(double value) {
  if (!value.isFinite) {
    return value;
  }
  const double factor = 1000000.0;
  final double scaled = value * factor;
  if (scaled.abs() > 9.0e15) {
    return value;
  }
  final double rounded = scaled.roundToDouble() / factor;
  return rounded == 0.0 ? 0.0 : rounded;
}

double? _roundNullable(double? value) {
  if (value == null) {
    return null;
  }
  return _roundDerived(value);
}

/// nearest-rank 分位数（不插值）：index = ceil(q * n) - 1，夹到 [0, n-1]。
/// 选择它是因为结果一定是样本里的某个值，读者能回去逐帧核对。
double _nearestRankPercentile(List<double> sortedAscending, double quantile) {
  final int rawIndex = (quantile * sortedAscending.length).ceil() - 1;
  int index = rawIndex;
  if (index < 0) {
    index = 0;
  }
  if (index >= sortedAscending.length) {
    index = sortedAscending.length - 1;
  }
  return sortedAscending[index];
}

/// 一个数值序列的确定性分布；空序列返回 null（而不是编一个 0）。
Map<String, Object?>? _distribution(List<double> values) {
  if (values.isEmpty) {
    return null;
  }
  final List<double> sorted = List<double>.of(values)..sort();
  // 均值默认按 sum/n 算；只有逐帧值接近 double 上限、求和溢出时才退化成增量均值，
  // 否则 Infinity 进不了 JSON，报告会在编码阶段炸掉。
  double sum = 0.0;
  bool sumOverflowed = false;
  for (final double value in sorted) {
    sum += value;
    if (!sum.isFinite) {
      sumOverflowed = true;
      break;
    }
  }
  double mean;
  if (sumOverflowed) {
    mean = sorted.first;
    for (int index = 1; index < sorted.length; index += 1) {
      mean += (sorted[index] - mean) / (index + 1);
    }
  } else {
    mean = sum / sorted.length;
  }
  return <String, Object?>{
    'count': sorted.length,
    'min': _roundDerived(sorted.first),
    'p50': _roundDerived(_nearestRankPercentile(sorted, 0.50)),
    'p95': _roundDerived(_nearestRankPercentile(sorted, 0.95)),
    'p99': _roundDerived(_nearestRankPercentile(sorted, 0.99)),
    'max': _roundDerived(sorted.last),
    'mean': _roundDerived(mean),
  };
}

int _compareSamples(_Sample a, _Sample b) {
  final int byTimestamp = a.timestampMs.compareTo(b.timestampMs);
  if (byTimestamp != 0) {
    return byTimestamp;
  }
  final int byFrameIndex = a.frameIndex.compareTo(b.frameIndex);
  if (byFrameIndex != 0) {
    return byFrameIndex;
  }
  return a.lineNumber.compareTo(b.lineNumber);
}

int _compareIdentities(_RunIdentity a, _RunIdentity b) {
  final int byDevice = a.deviceId.compareTo(b.deviceId);
  if (byDevice != 0) {
    return byDevice;
  }
  final int byScene = a.sceneId.compareTo(b.sceneId);
  if (byScene != 0) {
    return byScene;
  }
  return a.runId.compareTo(b.runId);
}

int _compareRejectedRuns(_RejectedRun a, _RejectedRun b) {
  final int byRunId = a.runId.compareTo(b.runId);
  if (byRunId != 0) {
    return byRunId;
  }
  return _compareIdentities(a.identities.first, b.identities.first);
}

Future<_Input> _readInput(String path) async {
  final List<int> bytes = await File(path).readAsBytes();
  String text = utf8.decode(bytes);
  if (text.startsWith('\uFEFF')) {
    text = text.substring(1);
  }
  final List<String> splitLines = text.isEmpty ? <String>[] : text.split('\n');
  // 以换行结尾的文件会被 split 多切出一个空串：它是“文件到此结束”，不是空行。
  final List<String> rawLines =
      splitLines.isNotEmpty && splitLines.last.isEmpty
      ? splitLines.sublist(0, splitLines.length - 1)
      : splitLines;
  final List<_Sample> samples = <_Sample>[];
  final List<_Rejection> rejections = <_Rejection>[];
  int blankLines = 0;
  int records = 0;
  for (int index = 0; index < rawLines.length; index += 1) {
    String line = rawLines[index];
    if (line.endsWith('\r')) {
      line = line.substring(0, line.length - 1);
    }
    if (line.trim().isEmpty) {
      blankLines += 1;
      continue;
    }
    records += 1;
    final int lineNumber = index + 1;
    try {
      samples.add(_parseRecord(line, lineNumber));
    } on _RecordInvalid catch (invalid) {
      rejections.add(
        _Rejection(
          line: lineNumber,
          reason: invalid.reason,
          field: invalid.field,
          detail: invalid.detail,
        ),
      );
    }
  }
  return _Input(
    path: path,
    byteLength: bytes.length,
    fingerprintFnv1a32: _fingerprintFnv1a32(bytes),
    totalLines: rawLines.length,
    blankLines: blankLines,
    records: records,
    samples: samples,
    rejections: rejections,
  );
}

/// FNV-1a 32 位：只用于“报告对应哪份输入字节”的可复核指纹，不是安全哈希。
String _fingerprintFnv1a32(List<int> bytes) {
  int hash = 0x811c9dc5;
  for (final int value in bytes) {
    hash = (hash ^ value) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return '0x${hash.toRadixString(16).padLeft(8, '0')}';
}

_Sample _parseRecord(String line, int lineNumber) {
  Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    throw const _RecordInvalid('json_syntax_error', '', 'invalid-json');
  }
  if (decoded is! Map) {
    throw const _RecordInvalid(
      'line_not_a_json_object',
      '',
      'not-an-object',
    );
  }
  final Map<String, Object?> fields = <String, Object?>{};
  final Map<dynamic, dynamic> rawFields = decoded;
  for (final MapEntry<dynamic, dynamic> entry in rawFields.entries) {
    final dynamic key = entry.key;
    final String keyText = key is String ? key : '$key';
    fields[keyText] = entry.value;
  }

  // 先按固定顺序查一遍缺失，保证“缺 A 又缺 B”时原因稳定落在第一个缺失字段。
  for (final String name in _requiredFields) {
    if (!fields.containsKey(name)) {
      throw _RecordInvalid('missing_field', name, 'absent');
    }
  }

  final String deviceId = _readString(fields, 'deviceId');
  final String sceneId = _readString(fields, 'sceneId');
  final String runId = _readString(fields, 'runId');
  final int frameIndex = _readInteger(fields, 'frameIndex');
  final double frameTimeMs = _readFiniteNumber(fields, 'frameTimeMs');
  final int timestampMs = _readInteger(fields, 'timestampMs');
  final bool firstFrame = _readBoolean(fields, 'firstFrame');
  final double memoryMb = _readFiniteNumber(fields, 'memoryMb');
  final double startupMs = _readFiniteNumber(fields, 'startupMs');

  final List<String> unknownFields = <String>[];
  for (final String key in fields.keys) {
    if (!_requiredFieldSet.contains(key)) {
      unknownFields.add(key);
    }
  }

  return _Sample(
    lineNumber: lineNumber,
    deviceId: deviceId,
    sceneId: sceneId,
    runId: runId,
    frameIndex: frameIndex,
    frameTimeMs: frameTimeMs,
    timestampMs: timestampMs,
    firstFrame: firstFrame,
    memoryMb: memoryMb,
    startupMs: startupMs,
    unknownFields: unknownFields,
  );
}

String _readString(Map<String, Object?> fields, String name) {
  final Object? value = fields[name];
  if (value is! String) {
    throw _RecordInvalid('field_wrong_type', name, 'expected-string');
  }
  if (value.trim().isEmpty) {
    throw _RecordInvalid('empty_identifier', name, 'empty');
  }
  return value;
}

int _readInteger(Map<String, Object?> fields, String name) {
  final Object? value = fields[name];
  if (value is! int) {
    throw _RecordInvalid('field_wrong_type', name, 'expected-integer');
  }
  if (value < 0) {
    throw _RecordInvalid('negative_value', name, 'negative');
  }
  return value;
}

double _readFiniteNumber(Map<String, Object?> fields, String name) {
  final Object? value = fields[name];
  if (value is! num) {
    throw _RecordInvalid('field_wrong_type', name, 'expected-finite-number');
  }
  final double number = value.toDouble();
  if (!number.isFinite) {
    throw _RecordInvalid('non_finite_value', name, 'not-finite');
  }
  if (number < 0) {
    throw _RecordInvalid('negative_value', name, 'negative');
  }
  return number;
}

bool _readBoolean(Map<String, Object?> fields, String name) {
  final Object? value = fields[name];
  if (value is! bool) {
    throw _RecordInvalid('field_wrong_type', name, 'expected-bool');
  }
  return value;
}

_Report _buildReport(_Options options, _Input input) {
  // 1) 先按 runId 分组，再按 (deviceId, sceneId) 判断是否自相矛盾。
  final Map<String, Map<_RunIdentity, List<_Sample>>> byRunId =
      <String, Map<_RunIdentity, List<_Sample>>>{};
  for (final _Sample sample in input.samples) {
    final Map<_RunIdentity, List<_Sample>> identities = byRunId.putIfAbsent(
      sample.runId,
      () => <_RunIdentity, List<_Sample>>{},
    );
    final _RunIdentity identity = _RunIdentity(
      sample.deviceId,
      sample.sceneId,
      sample.runId,
    );
    identities.putIfAbsent(identity, () => <_Sample>[]).add(sample);
  }

  final List<_AcceptedRun> acceptedRuns = <_AcceptedRun>[];
  final List<_RejectedRun> rejectedRuns = <_RejectedRun>[];
  byRunId.forEach((String runId, Map<_RunIdentity, List<_Sample>> identities) {
    if (identities.length == 1) {
      final _RunIdentity identity = identities.keys.first;
      acceptedRuns.add(_AcceptedRun(identity, identities[identity]!));
      return;
    }
    final List<_RunIdentity> conflicting = identities.keys.toList()
      ..sort(_compareIdentities);
    int frameCount = 0;
    for (final List<_Sample> group in identities.values) {
      frameCount += group.length;
    }
    rejectedRuns.add(_RejectedRun(runId, conflicting, frameCount));
  });
  acceptedRuns.sort(
    (_AcceptedRun a, _AcceptedRun b) => _compareIdentities(a.identity, b.identity),
  );
  rejectedRuns.sort(_compareRejectedRuns);

  // 2) 逐 run 出报告。samples 保序、保原值；summary 只做确定性派生。
  final List<Map<String, Object?>> runReports = <Map<String, Object?>>[];
  int acceptedFrames = 0;
  for (final _AcceptedRun run in acceptedRuns) {
    acceptedFrames += run.samples.length;
    runReports.add(_describeRun(run, options));
  }

  final List<Map<String, Object?>> rejectedRunReports = <Map<String, Object?>>[];
  int conflictedFrames = 0;
  for (final _RejectedRun run in rejectedRuns) {
    conflictedFrames += run.frameCount;
    final List<Map<String, Object?>> identities = <Map<String, Object?>>[];
    for (final _RunIdentity identity in run.identities) {
      identities.add(<String, Object?>{
        'deviceId': identity.deviceId,
        'sceneId': identity.sceneId,
        'runId': identity.runId,
      });
    }
    rejectedRunReports.add(<String, Object?>{
      'reason': _runConflictReason,
      'runId': run.runId,
      'frameCount': run.frameCount,
      'identityCount': identities.length,
      'identities': identities,
      'decision':
          'every frame carrying this runId is rejected; conflicting rows are '
          'never partially kept',
    });
  }

  // 3) 拒绝计数：固定原因表 + 前 N 条样例（按行号顺序，不做抽样）。
  final Map<String, int> byReason = <String, int>{};
  for (final String reason in _lineRejectReasons) {
    byReason[reason] = 0;
  }
  for (final _Rejection rejection in input.rejections) {
    byReason[rejection.reason] = (byReason[rejection.reason] ?? 0) + 1;
  }
  final List<Map<String, Object?>> examples = <Map<String, Object?>>[];
  for (final _Rejection rejection in input.rejections) {
    if (examples.length >= _maxRejectionExamples) {
      break;
    }
    examples.add(<String, Object?>{
      'line': rejection.line,
      'reason': rejection.reason,
      'field': rejection.field,
      'detail': rejection.detail,
    });
  }

  final Map<String, Object?> json = <String, Object?>{
    'schema': _reportSchema,
    'tool': <String, Object?>{
      'path': _toolPath,
      'revision': _toolRevision,
      'language': 'dart',
      'imports': <String>['dart:convert', 'dart:io'],
      'importsFlutter': false,
      'spawnsProcesses': false,
      'network': false,
    },
    'input': <String, Object?>{
      // 用真正被读取的那个路径，而不是再抄一次命令行参数（两者恒等，但少一处漂移）。
      'path': input.path,
      'bytes': input.byteLength,
      'fingerprintFnv1a32': input.fingerprintFnv1a32,
      'lines': input.totalLines,
      'blankLines': input.blankLines,
      'records': input.records,
    },
    'contract': <String, Object?>{
      'sampleFields': _requiredFields,
      'stringFields': _stringFields,
      'integerFields': _integerFields,
      'numberFields': _numberFields,
      'booleanFields': _booleanFields,
      'windowMinutes': _roundDerived(options.windowMinutes),
      'windowMs': options.windowMs,
      'segmentsPerWindow': _segmentsPerWindow,
      'percentileMethod': 'nearest-rank: ceil(q*n)-1 clamped to [0,n-1]; no interpolation',
      'ordering':
          'samples by (timestampMs, frameIndex, line); runs by '
          '(deviceId, sceneId, runId); rejection examples by line',
      'rounding':
          'derived values rounded to 6 decimals; values taken from a sample '
          '(samples[].*, memoryPeakMb.value, startupMs.value, '
          'firstFrame.frameTimeMs) are echoed unchanged',
      'durationBasis':
          'timestampMs only; sample count and summed frame times never imply '
          'duration',
      'ratioRule':
          'ratio is null when the earlier value is 0 or the quotient is not '
          'finite',
      'driftRollupRule':
          'per window: first vs last non-empty segment; rollup: first vs last '
          'window whose drift was evaluated; signed values only',
      'thresholds': 'none',
      'verdicts': 'none',
      'deviceData': 'echoed from the input; nothing is synthesised',
      'identifierRule':
          'identifiers are kept verbatim (no trim); runs[].integrity.'
          'identifiersPadded flags values that carry leading or trailing '
          'whitespace',
      'sampleEcho':
          'runs[].samples echoes every frame with its numeric and boolean '
          'fields; deviceId/sceneId/runId are echoed once per run',
      'accountingRule':
          'records == acceptedFrames + rejectedLines + conflictedRunFrames',
    },
    'counts': <String, Object?>{
      'records': input.records,
      'acceptedFrames': acceptedFrames,
      'rejectedLines': input.rejections.length,
      'conflictedRunFrames': conflictedFrames,
      'acceptedRuns': acceptedRuns.length,
      'rejectedRuns': rejectedRuns.length,
    },
    'rejections': <String, Object?>{
      'total': input.rejections.length,
      'byReason': byReason,
      'examples': examples,
    },
    'rejectedRuns': rejectedRunReports,
    'runs': runReports,
  };

  return _Report(
    json: json,
    acceptedRuns: acceptedRuns.length,
    acceptedFrames: acceptedFrames,
    rejectedLines: input.rejections.length,
    rejectedRuns: rejectedRuns.length,
  );
}

Map<String, Object?> _describeRun(_AcceptedRun run, _Options options) {
  final List<_Sample> samples = List<_Sample>.of(run.samples)
    ..sort(_compareSamples);
  final int firstTimestampMs = samples.first.timestampMs;
  final int lastTimestampMs = samples.last.timestampMs;
  final int observedSpanMs = lastTimestampMs - firstTimestampMs;

  final List<double> frameTimes = <double>[];
  final Set<int> seenFrameIndexes = <int>{};
  final Set<double> startupValues = <double>{};
  final Set<String> unknownFields = <String>[];
  int minLine = samples.first.lineNumber;
  int maxLine = samples.first.lineNumber;
  int minFrameIndex = samples.first.frameIndex;
  int maxFrameIndex = samples.first.frameIndex;
  int previousFrameIndex = samples.first.frameIndex;
  int duplicateFrameIndexCount = 0;
  int nonIncreasingFrameIndexCount = 0;
  int recordsWithUnknownFields = 0;
  int firstFrameMarkers = 0;
  int firstFrameRank = -1;
  _Sample? firstFrameSample;
  double memoryPeakMb = samples.first.memoryMb;
  int memoryPeakTimestampMs = samples.first.timestampMs;
  int memoryPeakFrameIndex = samples.first.frameIndex;

  for (int index = 0; index < samples.length; index += 1) {
    final _Sample sample = samples[index];
    frameTimes.add(sample.frameTimeMs);
    if (!seenFrameIndexes.add(sample.frameIndex)) {
      duplicateFrameIndexCount += 1;
    }
    if (index > 0 && sample.frameIndex <= previousFrameIndex) {
      nonIncreasingFrameIndexCount += 1;
    }
    previousFrameIndex = sample.frameIndex;
    if (sample.frameIndex < minFrameIndex) {
      minFrameIndex = sample.frameIndex;
    }
    if (sample.frameIndex > maxFrameIndex) {
      maxFrameIndex = sample.frameIndex;
    }
    if (sample.lineNumber < minLine) {
      minLine = sample.lineNumber;
    }
    if (sample.lineNumber > maxLine) {
      maxLine = sample.lineNumber;
    }
    if (sample.memoryMb > memoryPeakMb) {
      memoryPeakMb = sample.memoryMb;
      memoryPeakTimestampMs = sample.timestampMs;
      memoryPeakFrameIndex = sample.frameIndex;
    }
    startupValues.add(sample.startupMs);
    if (sample.unknownFields.isNotEmpty) {
      recordsWithUnknownFields += 1;
      unknownFields.addAll(sample.unknownFields);
    }
    if (sample.firstFrame) {
      firstFrameMarkers += 1;
      if (firstFrameSample == null) {
        firstFrameSample = sample;
        firstFrameRank = index;
      }
    }
  }

  final List<String> unknownFieldList = unknownFields.toList()..sort();
  final List<double> startupList = startupValues.toList()..sort();
  final List<double> distinctStartup = <double>[];
  for (final double value in startupList) {
    if (distinctStartup.length >= _maxDistinctStartupValues) {
      break;
    }
    distinctStartup.add(value);
  }

  final Map<String, Object?> firstFrameBlock;
  if (firstFrameSample == null) {
    firstFrameBlock = <String, Object?>{
      'present': false,
      'markerCount': 0,
      'frameIndex': null,
      'timestampMs': null,
      'frameTimeMs': null,
      'offsetFromRunStartMs': null,
      'indexInTimeOrder': null,
    };
  } else {
    firstFrameBlock = <String, Object?>{
      'present': true,
      'markerCount': firstFrameMarkers,
      'frameIndex': firstFrameSample.frameIndex,
      'timestampMs': firstFrameSample.timestampMs,
      'frameTimeMs': firstFrameSample.frameTimeMs,
      'offsetFromRunStartMs': firstFrameSample.timestampMs - firstTimestampMs,
      'indexInTimeOrder': firstFrameRank,
    };
  }

  final List<Map<String, Object?>> sampleRecords = <Map<String, Object?>>[];
  for (final _Sample sample in samples) {
    sampleRecords.add(<String, Object?>{
      'line': sample.lineNumber,
      'frameIndex': sample.frameIndex,
      'frameTimeMs': sample.frameTimeMs,
      'timestampMs': sample.timestampMs,
      'firstFrame': sample.firstFrame,
      'memoryMb': sample.memoryMb,
      'startupMs': sample.startupMs,
    });
  }

  return <String, Object?>{
    'runKey':
        '${run.identity.deviceId}/${run.identity.sceneId}/${run.identity.runId}',
    'deviceId': run.identity.deviceId,
    'sceneId': run.identity.sceneId,
    'runId': run.identity.runId,
    'frameCount': samples.length,
    'lineRange': <String, Object?>{'first': minLine, 'last': maxLine},
    'summary': <String, Object?>{
      'frameCount': samples.length,
      'frameTimeMs': _distribution(frameTimes),
      'firstFrame': firstFrameBlock,
      'memoryPeakMb': <String, Object?>{
        'value': memoryPeakMb,
        'timestampMs': memoryPeakTimestampMs,
        'frameIndex': memoryPeakFrameIndex,
      },
      'startupMs': <String, Object?>{
        'value': samples.first.startupMs,
        'basis': 'startupMs reported by the earliest sample in the run',
        'distinctValueCount': startupList.length,
        'distinctValues': distinctStartup,
        'distinctValuesTruncated': startupList.length > distinctStartup.length,
      },
      'timestampRange': <String, Object?>{
        'firstTimestampMs': firstTimestampMs,
        'lastTimestampMs': lastTimestampMs,
        'spanMs': observedSpanMs,
      },
      'frameIndexRange': <String, Object?>{
        'min': minFrameIndex,
        'max': maxFrameIndex,
        'distinctCount': seenFrameIndexes.length,
      },
    },
    'integrity': <String, Object?>{
      'identifiersPadded': _hasPaddedIdentifier(run.identity),
      'unknownFieldCount': unknownFieldList.length,
      'unknownFields': unknownFieldList,
      'recordsWithUnknownFields': recordsWithUnknownFields,
      'duplicateFrameIndexCount': duplicateFrameIndexCount,
      'nonIncreasingFrameIndexCount': nonIncreasingFrameIndexCount,
      'firstFrameMarkerCount': firstFrameMarkers,
    },
    'stability': _stability(
      samples: samples,
      windowMs: options.windowMs,
      windowMinutes: options.windowMinutes,
    ),
    'samples': sampleRecords,
  };
}

/// 标识符只做“非空”校验，不做 trim：这里只是把“带首尾空白”这件事标出来，
/// 让读者知道 "opd2511" 与 " opd2511" 在报告里是两个不同设备，而不是被悄悄改写。
bool _hasPaddedIdentifier(_RunIdentity identity) {
  return identity.deviceId != identity.deviceId.trim() ||
      identity.sceneId != identity.sceneId.trim() ||
      identity.runId != identity.runId.trim();
}

Map<String, Object?> _stability({
  required List<_Sample> samples,
  required int windowMs,
  required double windowMinutes,
}) {
  final int firstTimestampMs = samples.first.timestampMs;
  final int lastTimestampMs = samples.last.timestampMs;
  final int observedSpanMs = lastTimestampMs - firstTimestampMs;
  final bool measured = observedSpanMs >= windowMs;
  final int windowCount = (observedSpanMs ~/ windowMs) + 1;

  // 一次分桶：窗口 k = [first + k*windowMs, first + (k+1)*windowMs)。
  final List<List<_Sample>> buckets = List<List<_Sample>>.generate(
    windowCount,
    (_) => <_Sample>[],
  );
  int largestGapMs = 0;
  int largestGapStartTimestampMs = firstTimestampMs;
  int previousTimestampMs = firstTimestampMs;
  for (final _Sample sample in samples) {
    int index = (sample.timestampMs - firstTimestampMs) ~/ windowMs;
    if (index < 0) {
      index = 0;
    }
    if (index >= windowCount) {
      index = windowCount - 1;
    }
    buckets[index].add(sample);
    final int gap = sample.timestampMs - previousTimestampMs;
    if (gap > largestGapMs) {
      largestGapMs = gap;
      largestGapStartTimestampMs = previousTimestampMs;
    }
    previousTimestampMs = sample.timestampMs;
  }

  final List<Map<String, Object?>> windows = <Map<String, Object?>>[];
  // 逐窗口的带符号差值，按窗口顺序摊平；用于“跨窗口漂移/退化标记”的汇总。
  final List<Map<String, Object?>> windowDeltas = <Map<String, Object?>>[];
  final Set<int> evaluatedWindows = <int>{};
  int fullySpannedWindows = 0;
  for (int index = 0; index < windowCount; index += 1) {
    final int startTimestampMs = firstTimestampMs + index * windowMs;
    final int endTimestampMs = startTimestampMs + windowMs;
    final bool fullySpanned = endTimestampMs <= lastTimestampMs;
    if (fullySpanned) {
      fullySpannedWindows += 1;
    }
    final Map<String, Object?> windowJson = _windowReport(
      index: index,
      startTimestampMs: startTimestampMs,
      endTimestampMs: endTimestampMs,
      windowMs: windowMs,
      fullySpanned: fullySpanned,
      samples: buckets[index],
    );
    windows.add(windowJson);
    final Object? driftValue = windowJson['drift'];
    if (driftValue is Map<String, Object?> &&
        driftValue['status'] == 'EVALUATED') {
      evaluatedWindows.add(index);
      final Object? markerValue = driftValue['markers'];
      if (markerValue is List<Map<String, Object?>>) {
        for (final Map<String, Object?> marker in markerValue) {
          windowDeltas.add(<String, Object?>{
            'windowIndex': index,
            'windowStartTimestampMs': startTimestampMs,
            'metric': marker['metric'],
            'unit': marker['unit'],
            'fromValue': marker['fromValue'],
            'toValue': marker['toValue'],
            'delta': marker['delta'],
            'ratio': marker['ratio'],
            'direction': marker['direction'],
          });
        }
      }
    }
  }

  return <String, Object?>{
    'status': measured ? 'MEASURED' : 'UNMEASURED',
    'statusRule':
        'MEASURED iff observedSpanMs >= requiredSpanMs, where '
        'observedSpanMs = lastTimestampMs - firstTimestampMs',
    'durationBasis':
        'timestampMs only; sample count and summed frame times never imply '
        'duration',
    'windowMinutes': _roundDerived(windowMinutes),
    'windowMs': windowMs,
    'requiredSpanMs': windowMs,
    'observedSpanMs': observedSpanMs,
    'shortfallMs': measured ? 0 : windowMs - observedSpanMs,
    'windowCount': windowCount,
    'fullySpannedWindows': fullySpannedWindows,
    'partialWindows': windowCount - fullySpannedWindows,
    'sampleCount': samples.length,
    'sampleCountUsedForDuration': false,
    'largestGapMs': largestGapMs,
    'largestGapStartTimestampMs': largestGapStartTimestampMs,
    'windowDriftRollup': _driftSummary(
      deltas: windowDeltas,
      evaluatedWindowCount: evaluatedWindows.length,
      stabilityMeasured: measured,
    ),
    'windows': windows,
  };
}

Map<String, Object?> _windowReport({
  required int index,
  required int startTimestampMs,
  required int endTimestampMs,
  required int windowMs,
  required bool fullySpanned,
  required List<_Sample> samples,
}) {
  final List<double> frameTimes = <double>[];
  double? memoryPeakMb;
  for (final _Sample sample in samples) {
    frameTimes.add(sample.frameTimeMs);
    if (memoryPeakMb == null || sample.memoryMb > memoryPeakMb) {
      memoryPeakMb = sample.memoryMb;
    }
  }

  final int segmentMs = windowMs ~/ _segmentsPerWindow;
  final List<List<_Sample>> segmentBuckets = List<List<_Sample>>.generate(
    _segmentsPerWindow,
    (_) => <_Sample>[],
  );
  for (final _Sample sample in samples) {
    int segmentIndex = (sample.timestampMs - startTimestampMs) ~/ segmentMs;
    if (segmentIndex < 0) {
      segmentIndex = 0;
    }
    if (segmentIndex >= _segmentsPerWindow) {
      segmentIndex = _segmentsPerWindow - 1;
    }
    segmentBuckets[segmentIndex].add(sample);
  }

  final List<double?> segmentP50 = List<double?>.filled(
    _segmentsPerWindow,
    null,
  );
  final List<double?> segmentP95 = List<double?>.filled(
    _segmentsPerWindow,
    null,
  );
  final List<double?> segmentMemoryPeak = List<double?>.filled(
    _segmentsPerWindow,
    null,
  );
  final List<Map<String, Object?>> segments = <Map<String, Object?>>[];
  final List<int> nonEmptySegments = <int>[];
  for (int segmentIndex = 0; segmentIndex < _segmentsPerWindow; segmentIndex += 1) {
    final List<_Sample> bucket = segmentBuckets[segmentIndex];
    final int segmentStartTimestampMs = startTimestampMs + segmentIndex * segmentMs;
    final int segmentEndTimestampMs = segmentIndex == _segmentsPerWindow - 1
        ? endTimestampMs
        : segmentStartTimestampMs + segmentMs;
    final List<double> segmentFrameTimes = <double>[];
    double? segmentPeakMb;
    for (final _Sample sample in bucket) {
      segmentFrameTimes.add(sample.frameTimeMs);
      if (segmentPeakMb == null || sample.memoryMb > segmentPeakMb) {
        segmentPeakMb = sample.memoryMb;
      }
    }
    segmentMemoryPeak[segmentIndex] = segmentPeakMb;
    if (segmentFrameTimes.isNotEmpty) {
      nonEmptySegments.add(segmentIndex);
      final List<double> sorted = List<double>.of(segmentFrameTimes)..sort();
      segmentP50[segmentIndex] = _nearestRankPercentile(sorted, 0.50);
      segmentP95[segmentIndex] = _nearestRankPercentile(sorted, 0.95);
    }
    segments.add(<String, Object?>{
      'index': segmentIndex,
      'startTimestampMs': segmentStartTimestampMs,
      'endTimestampMs': segmentEndTimestampMs,
      'frameCount': bucket.length,
      'frameTimeMs': _distribution(segmentFrameTimes),
      'memoryPeakMb': _roundNullable(segmentPeakMb),
    });
  }

  return <String, Object?>{
    'index': index,
    'startTimestampMs': startTimestampMs,
    'endTimestampMs': endTimestampMs,
    'windowMs': windowMs,
    'fullySpanned': fullySpanned,
    'frameCount': samples.length,
    'frameTimeMs': _distribution(frameTimes),
    'memoryPeakMb': _roundNullable(memoryPeakMb),
    'segmentMs': segmentMs,
    'segments': segments,
    'drift': _driftReport(
      fullySpanned: fullySpanned,
      nonEmptySegments: nonEmptySegments,
      segmentP50: segmentP50,
      segmentP95: segmentP95,
      segmentMemoryPeak: segmentMemoryPeak,
    ),
  };
}

Map<String, Object?> _driftReport({
  required bool fullySpanned,
  required List<int> nonEmptySegments,
  required List<double?> segmentP50,
  required List<double?> segmentP95,
  required List<double?> segmentMemoryPeak,
}) {
  if (!fullySpanned) {
    return <String, Object?>{
      'status': 'NOT_EVALUATED',
      'reason': 'window_not_fully_spanned',
      'markerSemantics': _markerSemantics,
      'markers': <Object?>[],
    };
  }
  if (nonEmptySegments.length < 2) {
    return <String, Object?>{
      'status': 'NOT_EVALUATED',
      'reason': 'fewer_than_two_non_empty_segments',
      'markerSemantics': _markerSemantics,
      'markers': <Object?>[],
    };
  }
  final int fromSegment = nonEmptySegments.first;
  final int toSegment = nonEmptySegments.last;
  final List<Map<String, Object?>> markers = <Map<String, Object?>>[];
  _addDeltaMarker(
    markers,
    metric: 'frameTimeMs.p50',
    unit: 'ms',
    fromSegment: fromSegment,
    toSegment: toSegment,
    fromValue: segmentP50[fromSegment],
    toValue: segmentP50[toSegment],
  );
  _addDeltaMarker(
    markers,
    metric: 'frameTimeMs.p95',
    unit: 'ms',
    fromSegment: fromSegment,
    toSegment: toSegment,
    fromValue: segmentP95[fromSegment],
    toValue: segmentP95[toSegment],
  );
  _addDeltaMarker(
    markers,
    metric: 'memoryMb.peak',
    unit: 'Mb',
    fromSegment: fromSegment,
    toSegment: toSegment,
    fromValue: segmentMemoryPeak[fromSegment],
    toValue: segmentMemoryPeak[toSegment],
  );
  return <String, Object?>{
    'status': 'EVALUATED',
    'basis': 'first non-empty segment vs last non-empty segment of this window',
    'fromSegment': fromSegment,
    'toSegment': toSegment,
    'nonEmptySegments': nonEmptySegments,
    'markerSemantics': _markerSemantics,
    'markers': markers,
  };
}

/// 跨窗口的漂移汇总：只做带符号的加总与方向计数，不做判定，也没有阈值。
/// 结构固定（三个指标永远出现），所以“没有窗口被评估”与“差值为 0”不会混在一起。
Map<String, Object?> _driftSummary({
  required List<Map<String, Object?>> deltas,
  required int evaluatedWindowCount,
  required bool stabilityMeasured,
}) {
  const List<String> metrics = <String>[
    'frameTimeMs.p50',
    'frameTimeMs.p95',
    'memoryMb.peak',
  ];
  final List<Map<String, Object?>> reports = <Map<String, Object?>>[];
  for (final String metric in metrics) {
    final List<Map<String, Object?>> entries = <Map<String, Object?>>[];
    for (final Map<String, Object?> delta in deltas) {
      if (delta['metric'] == metric) {
        entries.add(delta);
      }
    }
    if (entries.isEmpty) {
      reports.add(<String, Object?>{
        'metric': metric,
        'unit': null,
        'windowCount': 0,
        'windowsWithPositiveDelta': 0,
        'windowsWithNegativeDelta': 0,
        'windowsWithZeroDelta': 0,
        'firstValue': null,
        'lastValue': null,
        'netDelta': null,
        'netRatio': null,
        'direction': 'unknown',
        'deltas': <Map<String, Object?>>[],
      });
      continue;
    }
    int positive = 0;
    int negative = 0;
    int zero = 0;
    for (final Map<String, Object?> entry in entries) {
      final Object? direction = entry['direction'];
      if (direction == 'increase') {
        positive += 1;
      } else if (direction == 'decrease') {
        negative += 1;
      } else {
        zero += 1;
      }
    }
    final Object? firstValue = entries.first['fromValue'];
    final Object? lastValue = entries.last['toValue'];
    double? netDelta;
    double? netRatio;
    String direction = 'unknown';
    if (firstValue is double && lastValue is double) {
      final double delta = _roundDerived(lastValue - firstValue);
      netDelta = delta;
      if (firstValue != 0.0) {
        final double rawRatio = lastValue / firstValue;
        netRatio = rawRatio.isFinite ? _roundDerived(rawRatio) : null;
      }
      if (delta > 0.0) {
        direction = 'increase';
      } else if (netDelta < 0.0) {
        direction = 'decrease';
      } else {
        direction = 'unchanged';
      }
    }
    reports.add(<String, Object?>{
      'metric': metric,
      'unit': entries.first['unit'],
      'windowCount': entries.length,
      'windowsWithPositiveDelta': positive,
      'windowsWithNegativeDelta': negative,
      'windowsWithZeroDelta': zero,
      'firstValue': firstValue,
      'lastValue': lastValue,
      'netDelta': netDelta,
      'netRatio': netRatio,
      'direction': direction,
      'deltas': entries,
    });
  }
  return <String, Object?>{
    'status': stabilityMeasured ? 'MEASURED' : 'UNMEASURED',
    'statusRule':
        'rollup only covers windows whose drift.status is EVALUATED; it never '
        'promotes a short capture to 30 min',
    'evaluatedWindowCount': evaluatedWindowCount,
    'metrics': reports,
    'markerSemantics': _markerSemantics,
    'thresholds': 'none',
    'verdicts': 'none',
    'note': 'signed deltas and counts only; nothing here decides pass or fail',
  };
}

/// 记录一个带符号差值。没有阈值：这里只决定 delta 的符号，不决定好坏。
void _addDeltaMarker(
  List<Map<String, Object?>> markers, {
  required String metric,
  required String unit,
  required int fromSegment,
  required int toSegment,
  required double? fromValue,
  required double? toValue,
}) {
  if (fromValue == null || toValue == null) {
    return;
  }
  final double delta = _roundDerived(toValue - fromValue);
  double? ratio;
  if (fromValue != 0.0) {
    final double rawRatio = toValue / fromValue;
    // 极小分母会把比率放大到 Infinity；JSON 表达不了它，降级成 null 而不是编一个数。
    ratio = rawRatio.isFinite ? _roundDerived(rawRatio) : null;
  }
  String direction = 'unchanged';
  if (delta > 0.0) {
    direction = 'increase';
  } else if (delta < 0.0) {
    direction = 'decrease';
  }
  markers.add(<String, Object?>{
    'metric': metric,
    'unit': unit,
    'fromSegment': fromSegment,
    'toSegment': toSegment,
    'fromValue': _roundDerived(fromValue),
    'toValue': _roundDerived(toValue),
    'delta': delta,
    'ratio': ratio,
    'direction': direction,
  });
}

Future<void> _writeReport(String path, String contents) async {
  final File target = File(path);
  final Directory parent = target.parent;
  if (!parent.existsSync()) {
    parent.createSync(recursive: true);
  }
  // 先写临时文件再改名：中途失败不会留下半截 JSON 让下游把坏报告当成好报告。
  final File temporary = File('$path.tmp.$pid');
  try {
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(path);
  } on FileSystemException {
    if (temporary.existsSync()) {
      try {
        temporary.deleteSync();
      } on FileSystemException {
        // 清理失败不改变退出码：真正的错误是原始写入/改名失败。
      }
    }
    rethrow;
  }
}

class _Options {
  const _Options({
    required this.inputPath,
    required this.outputPath,
    required this.windowMinutes,
    required this.windowMs,
  });

  final String inputPath;
  final String outputPath;
  final double windowMinutes;
  final int windowMs;

  static _Options parse(List<String> arguments) {
    String? inputPath;
    String? outputPath;
    double? windowMinutes;
    final _ArgumentCursor cursor = _ArgumentCursor(arguments);
    while (cursor.hasNext) {
      final String argument = cursor.next();
      if (argument == '--help' || argument == '-h') {
        throw const _HelpRequested();
      }
      if (!argument.startsWith('--')) {
        throw _UsageError('无法识别的参数：$argument');
      }
      final int equalsIndex = argument.indexOf('=');
      final String flag = equalsIndex > 1
          ? argument.substring(0, equalsIndex)
          : argument;
      final String? inlineValue = equalsIndex > 1
          ? argument.substring(equalsIndex + 1)
          : null;
      if (flag == '--in') {
        inputPath = _valueFor(flag, inlineValue, cursor);
      } else if (flag == '--out') {
        outputPath = _valueFor(flag, inlineValue, cursor);
      } else if (flag == '--window-minutes') {
        windowMinutes = _parseWindowMinutes(
          _valueFor(flag, inlineValue, cursor),
        );
      } else {
        throw _UsageError('无法识别的参数：$flag');
      }
    }
    if (inputPath == null) {
      throw const _UsageError('缺少 --in');
    }
    if (outputPath == null) {
      throw const _UsageError('缺少 --out');
    }
    final double minutes = windowMinutes ?? _defaultWindowMinutes;
    final int windowMs = (minutes * 60000.0).round();
    if (windowMs < _minWindowMs) {
      throw _UsageError(
        '--window-minutes 太小：窗口需 >= $_minWindowMs ms',
      );
    }
    return _Options(
      inputPath: inputPath,
      outputPath: outputPath,
      windowMinutes: minutes,
      windowMs: windowMs,
    );
  }
}

String _valueFor(String flag, String? inlineValue, _ArgumentCursor cursor) {
  if (inlineValue != null) {
    if (inlineValue.isEmpty) {
      throw _UsageError('参数 $flag 缺少取值');
    }
    return inlineValue;
  }
  if (!cursor.hasNext) {
    throw _UsageError('参数 $flag 缺少取值');
  }
  final String value = cursor.next();
  if (value.isEmpty || value.startsWith('--')) {
    throw _UsageError('参数 $flag 缺少取值');
  }
  return value;
}

double _parseWindowMinutes(String raw) {
  final double? parsed = double.tryParse(raw);
  if (parsed == null || !parsed.isFinite || parsed <= 0.0) {
    throw _UsageError('--window-minutes 需要正有限数：$raw');
  }
  return parsed;
}

class _ArgumentCursor {
  _ArgumentCursor(this.arguments);

  final List<String> arguments;
  int _index = 0;

  bool get hasNext => _index < arguments.length;

  String next() {
    final String value = arguments[_index];
    _index += 1;
    return value;
  }
}

class _HelpRequested implements Exception {
  const _HelpRequested();
}

class _UsageError implements Exception {
  const _UsageError(this.message);

  final String message;

  @override
  String toString() => message;
}

class _RecordInvalid implements Exception {
  const _RecordInvalid(this.reason, this.field, this.detail);

  final String reason;
  final String field;
  final String detail;

  @override
  String toString() => '$reason/$field/$detail';
}

class _RunIdentity {
  const _RunIdentity(this.deviceId, this.sceneId, this.runId);

  final String deviceId;
  final String sceneId;
  final String runId;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is _RunIdentity &&
        other.deviceId == deviceId &&
        other.sceneId == sceneId &&
        other.runId == runId;
  }

  @override
  int get hashCode => Object.hash(deviceId, sceneId, runId);
}

class _Sample {
  const _Sample({
    required this.lineNumber,
    required this.deviceId,
    required this.sceneId,
    required this.runId,
    required this.frameIndex,
    required this.frameTimeMs,
    required this.timestampMs,
    required this.firstFrame,
    required this.memoryMb,
    required this.startupMs,
    required this.unknownFields,
  });

  final int lineNumber;
  final String deviceId;
  final String sceneId;
  final String runId;
  final int frameIndex;
  final double frameTimeMs;
  final int timestampMs;
  final bool firstFrame;
  final double memoryMb;
  final double startupMs;
  final List<String> unknownFields;
}

class _Rejection {
  const _Rejection({
    required this.line,
    required this.reason,
    required this.field,
    required this.detail,
  });

  final int line;
  final String reason;
  final String field;
  final String detail;
}

class _AcceptedRun {
  const _AcceptedRun(this.identity, this.samples);

  final _RunIdentity identity;
  final List<_Sample> samples;
}

class _RejectedRun {
  const _RejectedRun(this.runId, this.identities, this.frameCount);

  final String runId;
  final List<_RunIdentity> identities;
  final int frameCount;
}

class _Input {
  const _Input({
    required this.path,
    required this.byteLength,
    required this.fingerprintFnv1a32,
    required this.totalLines,
    required this.blankLines,
    required this.records,
    required this.samples,
    required this.rejections,
  });

  final String path;
  final int byteLength;
  final String fingerprintFnv1a32;
  final int totalLines;
  final int blankLines;
  final int records;
  final List<_Sample> samples;
  final List<_Rejection> rejections;
}

class _Report {
  const _Report({
    required this.json,
    required this.acceptedRuns,
    required this.acceptedFrames,
    required this.rejectedLines,
    required this.rejectedRuns,
  });

  final Map<String, Object?> json;
  final int acceptedRuns;
  final int acceptedFrames;
  final int rejectedLines;
  final int rejectedRuns;
}
