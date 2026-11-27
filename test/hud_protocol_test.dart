// test/hud_protocol_test.dart
//
// T03 HUD 协议契约冻结测试：commands 的 17 个 flat array op、hits 六字段与 PlayerBar 专属
// fixed、frame 的 HUD 只读顶层字段。
//
// 规范来源：docs/flutter-migration/contracts/hud-protocol.md
// 基线：8ed3067b0812eb2612f7841ec127a6e8ca93231b
//
// 未执行声明：T03-C18 明令禁止执行 flutter/dart 的 build/test/analyze/run、Gradle、
// pub get、代码生成与 formatter、设备与性能验证。本文件只编写、不运行：
// RED 与 GREEN 均为「未执行」，静态结论由独立只读 reviewer 给出；
// 生产接线计为 ARCH_BLOCKED，设备证据计为 DEVICE_BLOCKED。
//
// 本文件只读 fixture 与本地内联的最小 frame 样例；不访问设备、不启动应用、不写生产文件。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

const String _commandsFixturePath = 'test/fixtures/hud_commands_17.json';
const String _hitsFixturePath = 'test/fixtures/hud_hits.json';
const String _contractDocPath = 'docs/flutter-migration/contracts/hud-protocol.md';
const String _baseline = '8ed3067b0812eb2612f7841ec127a6e8ca93231b';

// Qt/src/NativeHudSearch.cpp:208 用 QUrl::toPercentEncoding 对 UTF-8 字节做百分号编码，
// 这里取一个必须编码的 key（中文原样透传是错的）。
const String _expandKeyRaw = '全部歌曲';
const String _expandKeyEncoded = '%E5%85%A8%E9%83%A8%E6%AD%8C%E6%9B%B2';
const String _expandAction = 'music:expand:$_expandKeyEncoded';

// ---------------------------------------------------------------------------
// 冻结表：17 个 op 的数组形状（含 a[0]）。
//
// 位置标签：
//   'num'   number（QJsonValue::toDouble() 可读）
//   'int'   整数值 number（art 的 count，Qt/src/Glyphs.cpp:718 用 a[5].toInt(-1)）
//   'str'   字符串
//   'bool'  布尔
//   'color' RGBA 数组，见 _decodeColor
//   'dash'  number 数组
// 后缀 '?' 表示该位置可整体缺省，且只允许出现在尾部；默认值见契约 2.3。
// ---------------------------------------------------------------------------
const Map<String, List<String>> _opShape = <String, List<String>>{
  'save': <String>[],
  'restore': <String>[],
  'alpha': <String>['num'],
  'translate': <String>['num', 'num'],
  'scale': <String>['num', 'num'],
  'rotate': <String>['num'],
  'clip': <String>['num', 'num', 'num', 'num'],
  'fill': <String>['color', 'num', 'num', 'num', 'num'],
  'ellipse': <String>['color', 'num', 'num', 'num', 'num'],
  'text': <String>['str', 'num', 'num', 'num', 'str', 'num', 'color'],
  'art': <String>['str', 'num', 'num', 'num', 'int', 'num', 'color'],
  'fill-path': <String>['str', 'color'],
  'path': <String>['str', 'num', 'color', 'dash?', 'num?'],
  'arc': <String>['num', 'num', 'num', 'num', 'num', 'num', 'color'],
  'right-mask': <String>['color', 'num', 'num', 'num', 'num'],
  'gradient': <String>['bool?'],
  'image': <String>['str', 'num', 'num', 'num', 'num'],
};

/// 契约 2.2 冻结的颜色位置，逐 op 硬编码，防止 _opShape 被整体改坏后仍自洽通过。
const Map<String, int> _colorIndexOfOp = <String, int>{
  'fill': 1,
  'ellipse': 1,
  'text': 7,
  'art': 7,
  'fill-path': 2,
  'path': 3,
  'arc': 7,
  'right-mask': 1,
};

const Set<String> _hitRequiredFields = <String>{
  'x',
  'y',
  'width',
  'height',
  'action',
  'label',
};

const Set<String> _frameHudReadKeys = <String>{'mode', 'viewer', 'detail'};

const Set<String> _frameEngineOnlyKeys = <String>{
  'jitter',
  'temporalReset',
  'discAngle',
};

/// 契约 1.4 规则 3：commands 是数组，不存在对象信封。
bool _isFlatCommand(Object? candidate) =>
    candidate is List<dynamic> &&
    candidate.isNotEmpty &&
    candidate.first is String;

Map<String, dynamic> _loadFixture(String relativePath) {
  final file = File(relativePath);
  if (!file.existsSync()) {
    throw StateError('fixture 不存在：$relativePath（请从包根运行）');
  }
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw StateError('$relativePath 顶层必须是对象');
  }
  return decoded;
}

String _loadContractDoc() {
  final file = File(_contractDocPath);
  if (!file.existsSync()) {
    throw StateError('契约文档不存在：$_contractDocPath');
  }
  return file.readAsStringSync();
}

// ---------------------------------------------------------------------------
// 颜色：逐字对应 Qt/src/Glyphs.cpp:35-48 color()
//
//   const bool calibrated = a.size() > 4 && a.at(4).toString().startsWith("calibrated");
//   linear = pow(value, 1.8); value = linear <= .0031308 ? 12.92*linear
//                                                    : 1.055*pow(linear, 1/2.4) - .055;
//   QColor::fromRgbF(channel(0), channel(1), channel(2), a.size() > 3 ? a[3].toDouble() : 1)
//
// 第 4 项是 alpha，第 5 项是色彩空间标记，绝不是 alpha。
// ---------------------------------------------------------------------------
class HudColor {
  final double r;
  final double g;
  final double b;
  final double a;
  final bool calibrated;

  const HudColor(this.r, this.g, this.b, this.a, this.calibrated);
}

HudColor _decodeColor(List<dynamic> a) {
  final bool calibrated = a.length > 4 && a[4].toString().startsWith('calibrated');
  final double alpha = a.length > 3 ? (a[3] as num).toDouble() : 1.0;
  double channel(int i) {
    final double raw = (a[i] as num).toDouble();
    if (!calibrated) {
      return raw;
    }
    final double linear = math.pow(raw, 1.8).toDouble();
    if (linear <= 0.0031308) {
      return 12.92 * linear;
    }
    return 1.055 * math.pow(linear, 1 / 2.4).toDouble() - 0.055;
  }

  return HudColor(channel(0), channel(1), channel(2), alpha, calibrated);
}

/// 颜色形状探测（契约 2.4）：长度 3..5，前三项 number，a[3] 是 number，
/// 若存在第 5 项必须是字符串标记。用于反向断言颜色下标没有整体漂移
/// （dash 也是数组，所以不能只判 isA<List>）。
bool _looksLikeColor(Object? candidate) {
  if (candidate is! List<dynamic>) {
    return false;
  }
  if (candidate.length < 3 || candidate.length > 5) {
    return false;
  }
  for (int i = 0; i < 3; i++) {
    if (candidate[i] is! num) {
      return false;
    }
  }
  if (candidate.length > 3 && candidate[3] is! num) {
    return false;
  }
  if (candidate.length > 4 && candidate[4] is! String) {
    return false;
  }
  return true;
}

/// Qt/src/Glyphs.cpp:659 —— alpha 是乘算，不覆盖：c.setOpacity(c.opacity() * n(1))。
double _alphaMultiply(double current, double value) => current * value;

class HudDash {
  final List<double> pattern;
  final double offset;

  const HudDash(this.pattern, this.offset);
}

/// Qt/src/Glyphs.cpp:748-757 —— 每段 dash 与 dashOffset 都除以 max(penWidth, .0001)；
/// dash 为空时保持实线且不设置 offset。
HudDash _dashNormalize(double penWidth, Object? dash, Object? dashOffset) {
  final double divisor = penWidth > 0.0001 ? penWidth : 0.0001;
  final List<dynamic> raw = dash is List<dynamic> ? dash : const <dynamic>[];
  final List<double> pattern = <double>[];
  for (final dynamic item in raw) {
    pattern.add((item as num).toDouble() / divisor);
  }
  if (pattern.isEmpty) {
    return const HudDash(<double>[], 0);
  }
  final double offset = dashOffset is num ? dashOffset.toDouble() : 0.0;
  return HudDash(pattern, offset / divisor);
}

/// Qt/src/Glyphs.cpp:792-804 —— MaskSteps = 16，step = 0..16（17 个 stop、16 段），
/// progress = step / MaskSteps，eased = progress^2 * (3 - 2*progress)，
/// stop alpha = baseColor.alpha * eased。
List<double> _rightMaskStops(double baseAlpha) {
  const int steps = 16;
  return List<double>.generate(steps + 1, (int step) {
    final double progress = step / steps;
    final double eased = progress * progress * (3 - 2 * progress);
    return baseAlpha * eased;
  });
}

/// 契约 2.2 与 Qt/src/Glyphs.cpp:536,547,558 —— text 基线是 y + size*1.044
/// （字形变换与 bounds 路径同样带 1.044：Qt/src/Glyphs.cpp:316,329,910）；
/// 而 Qt/src/Glyphs.cpp:571-575 与 :582-584 的 art 只做 translate(x, y)，没有这个 1.044。
double _textBaselineY(double y, double size) => y + size * 1.044;

class HudRect {
  final double x;
  final double y;
  final double width;
  final double height;

  const HudRect(this.x, this.y, this.width, this.height);

  bool overlaps(HudRect other) =>
      x < other.x + other.width &&
      other.x < x + width &&
      y < other.y + other.height &&
      other.y < y + height;

  HudRect padded(double pad) =>
      HudRect(x - pad, y - pad, width + 2 * pad, height + 2 * pad);
}

HudRect _rectOf(Map<String, dynamic> hit) => HudRect(
      (hit['x'] as num).toDouble(),
      (hit['y'] as num).toDouble(),
      (hit['width'] as num).toDouble(),
      (hit['height'] as num).toDouble(),
    );

/// Qt/qml/Overlay.qml:38 —— readonly property real touchHitPadding: android ? 16 : 0。
/// 外扩只发生在触摸命中的外层，源矩形（hits 契约）不因平台改变。
double _touchHitPaddingFor({required bool android}) => android ? 16 : 0;

class HudFrameInput {
  final String mode;
  final bool viewer;
  final double detail;

  const HudFrameInput(this.mode, this.viewer, this.detail);
}

/// 契约第 4 章 —— HUD 只读 mode / viewer / detail 三个顶层键；
/// Engine 追加的 jitter / temporalReset / discAngle 不参与 HUD 布局。
HudFrameInput _readHudFrame(Map<String, dynamic> frame) => HudFrameInput(
      frame['mode'] as String,
      frame['viewer'] as bool,
      (frame['detail'] as num).toDouble(),
    );

/// 断言单个参数位置的类型；where 用于定位失败位置。
void _expectToken(String token, Object? value, String where) {
  switch (token) {
    case 'num':
      expect(value, isA<num>(), reason: '$where 期望 number');
      break;
    case 'int':
      expect(value, isA<num>(), reason: '$where 期望整数值 number');
      expect(
        (value! as num).toDouble(),
        (value as num).truncateToDouble(),
        reason: '$where 期望整数值',
      );
      break;
    case 'str':
      expect(value, isA<String>(), reason: '$where 期望 string');
      break;
    case 'bool':
      expect(value, isA<bool>(), reason: '$where 期望 bool');
      break;
    case 'dash':
      expect(value, isA<List<dynamic>>(), reason: '$where 期望 number 数组');
      for (final dynamic item in value! as List<dynamic>) {
        expect(item, isA<num>(), reason: '$where 的每一项都必须是 number');
      }
      break;
    case 'color':
      expect(value, isA<List<dynamic>>(), reason: '$where 期望 RGBA 数组');
      final List<dynamic> color = value! as List<dynamic>;
      expect(color.length, greaterThanOrEqualTo(3), reason: '$where 至少 RGB 三项');
      expect(color.length, lessThanOrEqualTo(5), reason: '$where 至多 5 项');
      for (int i = 0; i < 3; i++) {
        expect(color[i], isA<num>(), reason: '$where 的 RGB 通道必须是 number');
      }
      if (color.length > 3) {
        expect(color[3], isA<num>(), reason: '$where a[3] 是 alpha，必须是 number');
      }
      if (color.length > 4) {
        expect(
          color[4],
          isA<String>(),
          reason: '$where 第 5 项是色彩空间标记，必须是字符串',
        );
      }
      break;
    default:
      fail('未知的位置标签 $token（$where）');
  }
}

/// 逐条断言：a[0] 必须是已知 op，参数长度落在必需值与完整形状之间，
/// 每个出现的位置都符合冻结类型。
void _expectCommandShape(List<dynamic> command, String where) {
  final String op = command.first as String;
  final List<String>? spec = _opShape[op];
  expect(spec, isNotNull, reason: '$where：未知 op $op');
  final List<String> shape = spec!;
  final List<dynamic> args = command.sublist(1);
  final int required = shape.where((String t) => !t.endsWith('?')).length;
  expect(
    args.length,
    greaterThanOrEqualTo(required),
    reason: '$where：$op 缺少必需参数',
  );
  expect(
    args.length,
    lessThanOrEqualTo(shape.length),
    reason: '$where：$op 参数过多',
  );
  for (int i = 0; i < args.length; i++) {
    final String token = shape[i].replaceAll('?', '');
    _expectToken(token, args[i], '$where a[${i + 1}]');
  }
}

void main() {
  final Map<String, dynamic> commandsFixture = _loadFixture(_commandsFixturePath);
  final Map<String, dynamic> hitsFixture = _loadFixture(_hitsFixturePath);

  group('fixture 基线与公共形状', () {
    test('两个 fixture 声明同一基线且为对象契约', () {
      expect(commandsFixture['contract'], 'qt-hud-commands');
      expect(hitsFixture['contract'], 'qt-hud-hits');
      expect(commandsFixture['baseline'], _baseline);
      expect(hitsFixture['baseline'], _baseline);
    });

    test('commands fixture 的 stage 是横屏 1728x1080', () {
      expect(commandsFixture['stage'], <dynamic>[1728, 1080]);
    });
  });

  group('commands：17 op flat array', () {
    final List<dynamic> commands = commandsFixture['commands'] as List<dynamic>;
    final List<dynamic> expectedOrder =
        commandsFixture['expectedOpOrder'] as List<dynamic>;

    test('17 条命令都是数组，a[0] 名称与 expectedOpOrder 全等', () {
      expect(expectedOrder.length, 17);
      expect(commands.length, 17);
      final List<String> names = <String>[];
      for (int i = 0; i < commands.length; i++) {
        expect(
          _isFlatCommand(commands[i]),
          isTrue,
          reason: 'commands[$i] 必须是非空数组且 a[0] 是字符串',
        );
        final List<dynamic> command = commands[i] as List<dynamic>;
        names.add(command.first as String);
      }
      expect(names, expectedOrder);
      expect(names.toSet().length, 17, reason: '17 个 op 名称必须互不相同');
    });

    test('flat 形状判定拒绝 {id,opcode,args,seq} 对象信封', () {
      final Map<String, dynamic> banned = <String, dynamic>{
        'id': 1,
        'opcode': 'fill',
        'args': <dynamic>[0, 0, 10, 10],
        'seq': 0,
      };
      expect(_isFlatCommand(banned), isFalse);
      expect(
        _isFlatCommand(<dynamic>[
          <dynamic>[0.1, 0.2, 0.3],
          0,
          0,
          10,
          10,
        ]),
        isFalse,
        reason: '首项不是字符串（颜色数组）时也不得当成命令',
      );
      expect(_isFlatCommand(<dynamic>['fill']), isTrue);
    });

    test('对象里没有 opcode/seq 之类的信封键', () {
      for (final String banned in <String>['opcode', 'seq', 'frameId']) {
        expect(commandsFixture.containsKey(banned), isFalse);
        expect(hitsFixture.containsKey(banned), isFalse);
      }
    });

    test('命令流以 save 开始、以 restore 结束（同一次状态栈配对）', () {
      expect((commands.first as List<dynamic>).first, 'save');
      expect((commands.last as List<dynamic>).first, 'restore');
    });

    test('每个 op 的数组长度、参数位置与类型与冻结表全等', () {
      for (int i = 0; i < commands.length; i++) {
        _expectCommandShape(
          commands[i] as List<dynamic>,
          'commands[$i]',
        );
      }
    });

    test('颜色位置逐 op 正确：fill/ellipse/right-mask a[1]，text/art/arc a[7]，'
        'fill-path a[2]，path a[3]', () {
      for (final MapEntry<String, int> entry in _colorIndexOfOp.entries) {
        final List<dynamic> command = commands.firstWhere(
          (dynamic c) => (c as List<dynamic>).first == entry.key,
        ) as List<dynamic>;
        // 反向断言：整条命令里只有一个位置是颜色形状，且正好是冻结表声明的位置，
        // 避免下标整体漂移后仍然自洽（dash 也是数组，必须用形状而不是 isA<List>）。
        final List<int> colorPositions = <int>[];
        for (int i = 1; i < command.length; i++) {
          if (_looksLikeColor(command[i])) {
            colorPositions.add(i);
          }
        }
        expect(
          colorPositions,
          <int>[entry.value],
          reason: '${entry.key} 只有 a[${entry.value}] 是颜色数组',
        );
      }
    });

    test('颜色第 4 项是 alpha、第 5 项是 calibrated 标记，不被误读', () {
      final List<dynamic> fill = commands.firstWhere(
        (dynamic c) => (c as List<dynamic>).first == 'fill',
      ) as List<dynamic>;
      final List<dynamic> rawColor = fill[1] as List<dynamic>;
      expect(rawColor.length, 5);
      expect(rawColor[3], 1);
      expect(rawColor[4], 'calibratedRGB');

      final HudColor decoded = _decodeColor(rawColor);
      expect(decoded.a, 1.0, reason: 'alpha 只读 a[3]');
      expect(decoded.calibrated, isTrue);

      // 没有第 5 项时 alpha 仍取自 a[3]；没有 a[3] 时 alpha 缺省为 1。
      final HudColor fourItem = _decodeColor(<dynamic>[0.25, 0.5, 0.75, 0.5]);
      expect(fourItem.a, 0.5);
      expect(fourItem.calibrated, isFalse);
      final HudColor threeItem = _decodeColor(<dynamic>[0.25, 0.5, 0.75]);
      expect(threeItem.a, 1.0, reason: '契约 2.3：颜色 a[3] 缺省为 1.0');
      expect(threeItem.r, 0.25, reason: '未标 calibrated 时不做 Gamma 变换');

      // calibrated 触发 Gamma 1.8 -> sRGB；普通 RGBA 只读前四项。
      final HudColor calibrated = _decodeColor(
        <dynamic>[0.945, 0.941, 0.906, 1, 'calibratedRGB'],
      );
      expect(calibrated.r, isNot(0.945));
      expect(calibrated.r, closeTo(0.9562, 0.002));
      final HudColor plain = _decodeColor(
        <dynamic>[0.945, 0.941, 0.906, 1, 'displayP3'],
      );
      expect(plain.calibrated, isFalse);
      expect(plain.r, 0.945);
      expect(plain.a, 1.0, reason: '第 5 项不是 alpha');
    });

    test('alpha 是乘算而非覆盖', () {
      final List<dynamic> alpha = commands.firstWhere(
        (dynamic c) => (c as List<dynamic>).first == 'alpha',
      ) as List<dynamic>;
      expect(alpha[1], 0.5);
      expect(_alphaMultiply(1.0, 0.5), 0.5);
      expect(
        _alphaMultiply(0.5, 0.5),
        0.25,
        reason: '嵌套 save/alpha/alpha 时必须相乘，不能取后一个值',
      );
      expect(_alphaMultiply(0.25, 0.5), isNot(0.5));
    });

    test('path dash 按 max(penWidth, .0001) 归一，短形式默认实线', () {
      final List<dynamic> path = commands.firstWhere(
        (dynamic c) => (c as List<dynamic>).first == 'path',
      ) as List<dynamic>;
      expect(path.length, 6);
      expect(path[2], 4);
      final HudDash full = _dashNormalize(
        (path[2] as num).toDouble(),
        path[4],
        path[5],
      );
      expect(full.pattern, <double>[0.5, 0.25]);
      expect(full.offset, 0.5);

      final List<dynamic> shortPath = commandsFixture['shortPath'] as List<dynamic>;
      expect(shortPath.length, 4);
      expect(shortPath.first, 'path');
      final HudDash short = _dashNormalize(
        (shortPath[2] as num).toDouble(),
        null,
        null,
      );
      expect(short.pattern, isEmpty, reason: '空 dash 表示实线');
      expect(short.offset, 0.0, reason: '契约 2.3：dash 为空时不应用 offset');

      final HudDash tinyPen = _dashNormalize(0, <dynamic>[1], 1);
      expect(tinyPen.pattern.single, closeTo(10000, 1e-6), reason: '除数下限 0.0001');
    });

    test('right-mask 是 MaskSteps=16 的 17 stop/16 段 smoothstep', () {
      final List<dynamic> mask = commands.firstWhere(
        (dynamic c) => (c as List<dynamic>).first == 'right-mask',
      ) as List<dynamic>;
      expect(mask.length, 6);
      final double baseAlpha = _decodeColor(mask[1] as List<dynamic>).a;
      final List<double> stops = _rightMaskStops(baseAlpha);
      expect(stops.length, 17);
      expect(stops.length - 1, 16, reason: '契约 2.2：16 段');
      expect(stops.first, 0.0);
      expect(stops.last, closeTo(baseAlpha, 1e-9));
      for (int i = 1; i < stops.length; i++) {
        expect(stops[i], greaterThanOrEqualTo(stops[i - 1]));
      }
      expect(_rightMaskStops(1.0)[8], closeTo(0.5, 1e-9));
    });

    test('text 有 1.044 基线、art 没有；arc 用弧度', () {
      expect(commandsFixture['semantics'], isA<Map<String, dynamic>>());
      final Map<String, dynamic> semantics =
          commandsFixture['semantics'] as Map<String, dynamic>;
      expect((semantics['textBaselineFactor'] as num).toDouble(), 1.044);
      expect(_textBaselineY(100, 50), closeTo(152.2, 1e-9));

      final List<dynamic> text = commands.firstWhere(
        (dynamic c) => (c as List<dynamic>).first == 'text',
      ) as List<dynamic>;
      expect(text.length, 8);
      expect(text[5], isA<String>(), reason: 'a[5] 是 weight');
      expect((text[4] as num).toDouble(), 44.0);
      expect(_textBaselineY((text[3] as num).toDouble(), 44.0), closeTo(161.361, 1e-9));

      final List<dynamic> art = commands.firstWhere(
        (dynamic c) => (c as List<dynamic>).first == 'art',
      ) as List<dynamic>;
      expect(art.length, 8);
      expect(art[5], -1, reason: 'count < 0 表示整串');

      final List<dynamic> arc = commands.firstWhere(
        (dynamic c) => (c as List<dynamic>).first == 'arc',
      ) as List<dynamic>;
      expect(arc.length, 8);
      expect((arc[4] as num).toDouble(), 0.0);
      expect((arc[5] as num).toDouble(), closeTo(1.5708, 1e-9));
      expect(semantics['arcUnit'], 'radians');
    });

    test('semantics 常量与冻结表一致', () {
      final Map<String, dynamic> semantics =
          commandsFixture['semantics'] as Map<String, dynamic>;
      expect(semantics['alphaMode'], 'multiply');
      expect((semantics['textBaselineFactor'] as num).toDouble(), 1.044);
      expect(semantics['pathDashDivisor'], 'max(penWidth,0.0001)');
      expect(semantics['arcUnit'], 'radians');
      expect(semantics['rightMaskSegments'], 16);
      final List<dynamic> center = semantics['gradientCenter'] as List<dynamic>;
      expect(center.length, 2);
      expect((center[0] as num).toDouble(), closeTo(979.2, 1e-9));
      expect((center[1] as num).toDouble(), closeTo(518.4, 1e-9));
      expect((semantics['gradientRadius'] as num).toDouble(), 1100.0);

      final List<dynamic> gradient = commands.firstWhere(
        (dynamic c) => (c as List<dynamic>).first == 'gradient',
      ) as List<dynamic>;
      expect(gradient.length, 2, reason: 'gradient 只有可选的 dark 标记');
      expect(gradient[1], isA<bool>());
    });

    test('逐项相同的命令不得去重，envelope 明确声明', () {
      final List<dynamic> duplicates = commandsFixture['duplicates'] as List<dynamic>;
      expect(duplicates.length, 2);
      expect(duplicates[0], equals(duplicates[1]));
      expect(_isFlatCommand(duplicates[0]), isTrue);
      _expectCommandShape(duplicates[0] as List<dynamic>, 'duplicates[0]');
      _expectCommandShape(duplicates[1] as List<dynamic>, 'duplicates[1]');
      expect(
        <String>{(duplicates[0] as List<dynamic>).first, (duplicates[1] as List<dynamic>).first}.length,
        1,
      );

      final Map<String, dynamic> envelope =
          commandsFixture['envelope'] as Map<String, dynamic>;
      expect(envelope['deduplicateCommands'], isFalse);
      expect(envelope['reorderHits'], isFalse);
      expect(envelope['generationUsage'], 'consistency-only');
      expect(envelope['kind'], 'snapshot');
      expect(
        envelope['required'],
        <dynamic>['generation', 'frame', 'commands', 'hits', 'state'],
      );
    });
  });

  group('hits：六字段与 PlayerBar 专属 fixed', () {
    final List<dynamic> hits = hitsFixture['hits'] as List<dynamic>;
    final List<dynamic> expectedOrder = hitsFixture['expectedOrder'] as List<dynamic>;
    final List<int> playerBarIndices = (hitsFixture['playerBarIndices'] as List<dynamic>)
        .map((dynamic v) => v as int)
        .toList();

    test('fixture 声明的六字段就是契约六字段', () {
      expect((hitsFixture['requiredFields'] as List<dynamic>).toSet(),
          _hitRequiredFields);
      expect(hits.length, expectedOrder.length);
      expect(playerBarIndices, <int>[3, 4, 5]);
    });

    test('每项键集合为六字段；仅 playerBarIndices 的项额外有且仅有 fixed:true', () {
      for (int i = 0; i < hits.length; i++) {
        final Map<String, dynamic> hit = hits[i] as Map<String, dynamic>;
        final bool isPlayerBar = playerBarIndices.contains(i);
        final Set<String> keys = hit.keys.toSet();
        expect(
          keys.containsAll(_hitRequiredFields),
          isTrue,
          reason: 'hits[$i] 缺少六字段之一',
        );
        if (isPlayerBar) {
          expect(keys, _hitRequiredFields.union(<String>{'fixed'}),
              reason: 'hits[$i] 是 PlayerBar hit');
          expect(hit['fixed'], isTrue);
        } else {
          expect(keys, _hitRequiredFields,
              reason: 'hits[$i] 不是 PlayerBar hit，不得带 fixed');
          expect(hit.containsKey('fixed'), isFalse);
        }
        expect(hit.containsKey('z'), isFalse, reason: '契约 1.4：hits 没有 z');
        // 契约 3.1：action 与 label 都不得为空；Qt/src/NativeHud.cpp:102-109 在 label 缺失时
        // 回落到 action，所以空 label 说明产生了非法 hit。
        expect((hit['action'] as String).isNotEmpty,
            reason: 'hits[$i] 的 action 不得为空');
        expect((hit['label'] as String).isNotEmpty,
            reason: 'hits[$i] 的 label 不得为空');
      }
    });

    test('fixed 的判断依据是来源而非 action 前缀', () {
      final List<String> fixedActions = <String>[];
      for (final int i in playerBarIndices) {
        fixedActions.add((hits[i] as Map<String, dynamic>)['action'] as String);
      }
      expect(fixedActions.contains('music:like-current'), isTrue,
          reason: 'music:like-current 由 PlayerBar 产生，但没有 player: 前缀');
      expect(fixedActions.contains('settings'), isFalse);
      expect(fixedActions.contains('player:prev'), isTrue);
    });

    test('action 顺序与 expectedOrder 全等；重叠矩形不触发重排', () {
      final List<String> actions = hits
          .map((dynamic h) => (h as Map<String, dynamic>)['action'] as String)
          .toList();
      expect(actions, expectedOrder);

      final HudRect result = _rectOf(hits[1] as Map<String, dynamic>);
      final HudRect expand = _rectOf(hits[2] as Map<String, dynamic>);
      expect(result.overlaps(expand), isTrue, reason: '两条搜索结果矩形必须重叠');
      expect(actions.indexOf('music:result:0:17'), lessThan(actions.indexOf(_expandAction)),
          reason: '重叠矩形保持源顺序，不得按 z 或坐标重排');

      expect(hitsFixture['orderPolicy'], 'source-order');
      expect(hitsFixture['zSort'], isFalse);
      expect(hitsFixture['fixedPolicy'], 'PlayerBar-only');
    });

    test('搜索结果 action 是 music:result:<lane>:<index> 与百分号编码的 music:expand:<key>', () {
      final String resultAction = (hits[1] as Map<String, dynamic>)['action'] as String;
      expect(RegExp(r'^music:result:[0-9]+:[0-9]+$').hasMatch(resultAction), isTrue,
          reason: 'Qt/src/NativeHudSearch.cpp:208-209 是三段式 lane:index');
      final String expandAction = (hits[2] as Map<String, dynamic>)['action'] as String;
      expect(expandAction.startsWith('music:expand:'), isTrue);
      final String key = expandAction.substring('music:expand:'.length);
      expect(key, isNotEmpty);
      // Qt/src/NativeHudSearch.cpp:208 对 UTF-8 字节做 QUrl::toPercentEncoding；
      // 中文必须被编码，不能原样透传。
      expect(key, _expandKeyEncoded);
      expect(Uri.encodeComponent(_expandKeyRaw), _expandKeyEncoded);
      expect(Uri.decodeComponent(key), _expandKeyRaw);
      expect(key.contains(' '), isFalse, reason: 'key 必须百分号编码');
    });

    test('fraction 类 action 是模板加 0 的开始值', () {
      final List<String> actions = hits
          .map((dynamic h) => (h as Map<String, dynamic>)['action'] as String)
          .toList();
      expect(actions.contains('player:seek-fraction:0'), isTrue);
      for (final String action in actions) {
        if (action.startsWith('player:seek-fraction:') ||
            action.startsWith('player:volume-fraction:')) {
          final String fraction = action.split(':').last;
          expect(double.parse(fraction), isLessThanOrEqualTo(1.0));
        }
      }
    });

    test('触摸外扩只发生在触摸层，源矩形不因平台改变', () {
      expect(hitsFixture['touchPadding'], isA<Map<String, dynamic>>());
      final Map<String, dynamic> padding =
          hitsFixture['touchPadding'] as Map<String, dynamic>;
      expect(padding['android'], 16);
      expect(padding['other'], 0);
      expect(_touchHitPaddingFor(android: true), 16.0);
      expect(_touchHitPaddingFor(android: false), 0.0);

      final HudRect source = _rectOf(hits[0] as Map<String, dynamic>);
      final HudRect android = source.padded(_touchHitPaddingFor(android: true));
      expect(android.x, source.x - 16);
      expect(android.width, source.width + 32);
      expect(_rectOf(hits[0] as Map<String, dynamic>).x, source.x,
          reason: '外扩不得回写源矩形');
    });

    test('命中区形状来自 Qt 常量：control 54 高、结果行 72、seek 18', () {
      // Qt/src/NativeHud.cpp:121-122 control() 注册 (x - 10, y, width + 20, 54)；
      // :355 设置项 width = 120，所以设置 hit 是 140x54。
      final HudRect settings = _rectOf(hits[0] as Map<String, dynamic>);
      expect(settings.width, 140, reason: 'width + 20');
      expect(settings.height, 54, reason: 'control() 固定 54 高');

      // Qt/src/NativeHud.h:98 ResultRowHeight = 72；Qt/src/NativeHudSearch.cpp:210
      // hit(left, y, usable, ResultRowHeight, action, title)。
      for (final int i in <int>[1, 2]) {
        expect(_rectOf(hits[i] as Map<String, dynamic>).height, 72,
            reason: 'hits[$i] 是结果行，高 72');
      }

      // Qt/src/NativeHud.cpp:310 playerBar(0, 984, width) → Qt/src/PlayerBar.h:42
      // RowHeight = 96 的整行；timeline 的命中区是
      // QRectF(row.x(), row.y() - 6, row.width(), 18)（Qt/src/PlayerBar.cpp:149），
      // 注释里写明「始终沿用整行宽度」。
      final HudRect seek = _rectOf(hits[4] as Map<String, dynamic>);
      expect(seek.y, 984 - 6, reason: 'row.y 上移 6');
      expect(seek.height, 18);
      expect(seek.width, 1728, reason: '始终沿用整行宽度');

      // Qt/src/PlayerBar.cpp:85 固定 44x48；:170 固定 48x48。
      final HudRect prev = _rectOf(hits[3] as Map<String, dynamic>);
      expect(prev.width, 44);
      expect(prev.height, 48);
      final HudRect like = _rectOf(hits[5] as Map<String, dynamic>);
      expect(like.width, 48);
      expect(like.height, 48);
    });
  });

  group('frame：HUD 只读顶层字段', () {
    test('mode/viewer/detail 是 HUD 必需的顶层字段', () {
      expect((hitsFixture['frameHudReadKeys'] as List<dynamic>).toSet(),
          _frameHudReadKeys);
      final Map<String, dynamic> frame = <String, dynamic>{
        'mode': 'home',
        'viewer': false,
        'detail': 0.5,
      };
      for (final String key in _frameHudReadKeys) {
        expect(frame.containsKey(key), isTrue);
      }
      final HudFrameInput input = _readHudFrame(frame);
      expect(input.mode, 'home');
      expect(input.viewer, isFalse);
      expect(input.detail, 0.5);
    });

    test('Engine 的 jitter/temporalReset/discAngle 不是 HUD 字段', () {
      expect((hitsFixture['frameEngineOnlyKeys'] as List<dynamic>).toSet(),
          _frameEngineOnlyKeys);
      final Map<String, dynamic> withEngineKeys = <String, dynamic>{
        'mode': 'home',
        'viewer': false,
        'detail': 0.5,
        'jitter': <dynamic>[0.1, -0.1],
        'temporalReset': true,
        'discAngle': 1.25,
      };
      final HudFrameInput input = _readHudFrame(withEngineKeys);
      expect(input.mode, 'home');
      expect(input.detail, 0.5);
      expect(_frameHudReadKeys.intersection(_frameEngineOnlyKeys), isEmpty);

      // 缺这三键的帧仍然是合法的 HUD 输入：HUD 不得要求它们存在。
      final Map<String, dynamic> hudOnly = <String, dynamic>{
        'mode': 'home',
        'viewer': false,
        'detail': 0.0,
      };
      expect(_readHudFrame(hudOnly).detail, 0.0);
    });
  });

  group('契约文档与 fixture 一致', () {
    test('文档冻结了 17 个 op 名称与关键常量', () {
      final String doc = _loadContractDoc();
      for (final String op in _opShape.keys) {
        expect(doc.contains(op), isTrue, reason: '文档缺少 op $op');
      }
      expect(_opShape.length, 17);
      for (final String token in <String>[
        _baseline,
        '1.044',
        '979.2',
        '1100',
        'penWidth',
        'MaskSteps',
        'calibrated',
        'PlayerBar',
        'fixed',
      ]) {
        expect(doc.contains(token), isTrue, reason: '文档缺少 $token');
      }
    });
  });
}
