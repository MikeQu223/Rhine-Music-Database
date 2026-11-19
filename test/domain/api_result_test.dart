// Qt -> Flutter 迁移 · SHARED-S3 测试规格：ApiResult / ApiFailure（调用结果 + safeFailure 白名单 + 消息合成）。
//
// 依据（每条断言上方注释给出 Qt 行号）：
//   Qt/src/MusicApi.h:7-14        MusicReply{value, error, failure, ok() = error.isEmpty()}
//   Qt/src/MusicApi.cpp:26-58     safeFailure 白名单（字符串正则 / 数值 isDouble+isfinite / 布尔 isBool /
//                                 嵌套一层 / verification / authExpired）
//   Qt/src/MusicApi.cpp:61-70     call()：local 守卫、adapted = true、allowed = {200}
//   Qt/src/MusicApi.cpp:72-84     request()：local 守卫、adapted = false
//   Qt/src/MusicApi.cpp:98-123    send()：宿主错误 / body 非对象 / code+allowed / message 合成 / value 投影
//
// 【本测试未执行】受任务禁令约束：禁止 flutter/dart test、dart analyze、构建、代码生成与任何测试执行。
// 执行入口与 RED/GREEN 结论由 Lead 统一决定（候选命令：flutter test test/domain/api_result_test.dart）。
// 依赖提示：import 取 package:flutter_test/flutter_test.dart（项目既有约定：pubspec.yaml 的 dev_dependencies 已含
// flutter_test；package:test 不在 pubspec.lock 中，直接 import 会解析失败）。不新增依赖、不改 pubspec。
import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/domain/models/api_result.dart';
import 'package:rhine_music_database/domain/models/provider_id.dart';

const List<String> _diagnosticFields = <String>[
  'failureStage',
  'failureReason',
  'errorKey',
  'upstreamErrorKey',
];

const List<String> _numberFields = <String>[
  'code',
  'retryAfterMs',
  'upstreamHttpStatus',
  'upstreamCode',
  'upstreamGlobalCode',
  'upstreamSubCode',
];

const List<String> _boolFields = <String>['retryable', 'writeAttempted'];

void main() {
  group('ApiResult 基本形状（Qt/src/MusicApi.h:7-14 MusicReply）', () {
    test('ok 只由 error 是否为空决定', () {
      // MusicApi.h:11-13 ok() const { return error.isEmpty(); }
      expect(const ApiResult().ok, isTrue);
      expect(const ApiResult(value: 1).ok, isTrue);
      expect(const ApiResult(error: 'x').ok, isFalse);
      expect(const ApiResult(value: 'v', error: '', failure: null).ok, isTrue);
    });

    test('const 构造的默认值：error 空串、value/failure 为空', () {
      const ApiResult result = ApiResult();
      expect(result.error, '');
      expect(result.value, isNull);
      expect(result.failure, isNull);
    });

    test('success 工厂：error 空、failure 空、value 原样保留', () {
      // MusicApi.cpp:123 callback({adapted ? body["value"] : QJsonValue(body), {}, {}})
      final ApiResult result = ApiResult.success(<String, dynamic>{'id': '1'});
      expect(result.ok, isTrue);
      expect(result.error, '');
      expect(result.failure, isNull);
      expect(result.value, <String, dynamic>{'id': '1'});
      expect(ApiResult.success(null).ok, isTrue);
      expect(ApiResult.success(null).value, isNull);
    });

    test('failure 工厂：error 逐字保留，failure 可选', () {
      // MusicApi.cpp:102（宿主错误）、:106（元数据格式无效）、:116（safeFailure）
      final ApiResult bare = ApiResult.failure('宿主错误');
      expect(bare.ok, isFalse);
      expect(bare.error, '宿主错误');
      expect(bare.value, isNull);
      expect(bare.failure, isNull);

      final ApiFailure projection = ApiFailure.fromJson(<String, dynamic>{'code': 503})!;
      final ApiResult withFailure = ApiResult.failure('宿主错误', projection);
      expect(withFailure.ok, isFalse);
      expect(withFailure.failure, same(projection));
    });

    test('三个文案常量逐字（Qt/src/MusicApi.cpp:106、:64/:76、:112）', () {
      expect(ApiResult.metadataFormatError, '元数据格式无效');
      expect(ApiResult.localModeError, '本地模式不提供在线平台操作');
      expect(ApiResult.fallbackMessage, '请稍后重试');
    });

    test('R3/R4 localModeDisabled：error 逐字、value/failure 空、ok 为假', () {
      // MusicApi.cpp:62-67（call）与 :74-79（request）：local 直接 callback({{}, "本地模式不提供在线平台操作", {}})
      final ApiResult result = ApiResult.localModeDisabled();
      expect(result.ok, isFalse);
      expect(result.error, '本地模式不提供在线平台操作');
      expect(result.error, ApiResult.localModeError);
      expect(result.value, isNull);
      expect(result.failure, isNull);
    });
  });

  group('ApiFailure.fromJson 非对象输入（Qt/src/MusicApi.cpp:40-45 isObject 语义）', () {
    test('非 Map → null', () {
      expect(ApiFailure.fromJson(null), isNull);
      expect(ApiFailure.fromJson('text'), isNull);
      expect(ApiFailure.fromJson(7), isNull);
      expect(ApiFailure.fromJson(true), isNull);
      expect(ApiFailure.fromJson(<Object?>[]), isNull);
    });

    test('空 Map → 非 null 的空投影（Qt safeFailure 总是返回 QJsonObject）', () {
      // MusicApi.cpp:27 QJsonObject result; :57 return result;（即使全被过滤也返回空对象）
      final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{})!;
      expect(failure.toJson(), <String, dynamic>{});
      expect(failure.unconfirmed, isFalse);
      expect(failure.authExpired, isFalse);
    });
  });

  group('R5 字符串白名单（Qt/src/MusicApi.cpp:29-33）', () {
    test('R5 四个字符串字段的合法诊断串收录（isString && ^[a-z.-]{1,80}$）', () {
      // MusicApi.cpp:29-33
      final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{
        'failureStage': 'recover',
        'failureReason': 'a.b-c',
        'errorKey': 'upstream.timeout',
        'upstreamErrorKey': 'x',
      })!;
      expect(failure.failureStage, 'recover');
      expect(failure.failureReason, 'a.b-c');
      expect(failure.errorKey, 'upstream.timeout');
      expect(failure.upstreamErrorKey, 'x');
      expect(failure.toJson(), <String, dynamic>{
        'failureStage': 'recover',
        'failureReason': 'a.b-c',
        'errorKey': 'upstream.timeout',
        'upstreamErrorKey': 'x',
      });
    });

    test('R5 含大写 / 下划线 / 数字 / 空格 / 中文 / 空串 / 非 String 一律丢弃', () {
      // MusicApi.cpp:28 正则只允许 [a-z.-]，且 isString() 必须为真
      final List<Object?> invalid = <Object?>[
        'FailureStage',
        'failure_stage',
        'code2',
        'a b',
        '失败',
        '',
        'a/B',
        7,
        1.5,
        true,
        null,
        <String, dynamic>{},
        <Object?>[],
      ];
      for (final Object? value in invalid) {
        final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{
          'failureStage': value,
        })!;
        expect(failure.failureStage, isNull, reason: '非法诊断串必须被丢弃：$value');
        expect(failure.toJson().containsKey('failureStage'), isFalse, reason: value.toString());
      }
    });

    test('R5 长度边界：80 收录、81 丢弃、0 丢弃（{1,80}）', () {
      // MusicApi.cpp:28 {1,80}
      final String ok80 = 'a' * 80;
      final String tooLong = 'a' * 81;
      expect(ApiFailure.fromJson(<String, dynamic>{'errorKey': ok80})!.errorKey, ok80);
      expect(ApiFailure.fromJson(<String, dynamic>{'errorKey': tooLong})!.errorKey, isNull);
      expect(ApiFailure.fromJson(<String, dynamic>{'errorKey': ''})!.errorKey, isNull);
    });

    test('R5 每个字符串字段都各自执行同一白名单', () {
      for (final String field in _diagnosticFields) {
        expect(ApiFailure.fromJson(<String, dynamic>{field: 'A'})!.toJson().containsKey(field), isFalse, reason: field);
        expect(ApiFailure.fromJson(<String, dynamic>{field: 'ok.reason'})!.toJson()[field], 'ok.reason', reason: field);
      }
    });
  });

  group('R5 数值白名单（Qt/src/MusicApi.cpp:34-39 isDouble && std::isfinite）', () {
    test('R5 六个数值字段的 int / double / 0 / 负数都收录', () {
      // MusicApi.cpp:34-39
      final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{
        'code': 403,
        'retryAfterMs': 1500.5,
        'upstreamHttpStatus': 429,
        'upstreamCode': 0,
        'upstreamGlobalCode': -1,
        'upstreamSubCode': 200.25,
      })!;
      expect(failure.code, 403);
      expect(failure.retryAfterMs, 1500.5);
      expect(failure.upstreamHttpStatus, 429);
      expect(failure.upstreamCode, 0);
      expect(failure.upstreamGlobalCode, -1);
      expect(failure.upstreamSubCode, 200.25);
      expect(failure.toJson().length, 6);
    });

    test('R5 字符串数字（"403"）与 bool / null / 容器一律丢弃', () {
      // Qt 只接受 isDouble()：字符串数字不是 Double，bool 不是 Double
      final List<Object?> invalid = <Object?>['403', '1.5', true, false, null, '', <String, dynamic>{}, <Object?>[]];
      for (final String field in _numberFields) {
        for (final Object? value in invalid) {
          final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{field: value})!;
          expect(failure.toJson().containsKey(field), isFalse, reason: '$field=$value');
        }
      }
    });

    test('R5 缺失键不产生投影键', () {
      expect(ApiFailure.fromJson(<String, dynamic>{})!.toJson().containsKey('code'), isFalse);
    });

    test('R5 NaN / Infinity / -Infinity 丢弃（std::isfinite）', () {
      // MusicApi.cpp:36 std::isfinite(body[name].toDouble())
      final List<double> notFinite = <double>[double.nan, double.infinity, double.negativeInfinity];
      for (final String field in _numberFields) {
        for (final double value in notFinite) {
          final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{field: value})!;
          expect(failure.toJson().containsKey(field), isFalse, reason: '$field=$value');
        }
      }
    });
  });

  group('R5 布尔白名单（Qt/src/MusicApi.cpp:46-50 isBool）', () {
    test('R5 retryable / writeAttempted 的 true 与 false 都收录', () {
      // MusicApi.cpp:46-50：isBool() 为真即收录，false 不是「缺失」
      final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{
        'retryable': true,
        'writeAttempted': false,
      })!;
      expect(failure.retryable, isTrue);
      expect(failure.writeAttempted, isFalse);
      expect(failure.toJson(), <String, dynamic>{'retryable': true, 'writeAttempted': false});
    });

    test('R5 字符串 "true" / 数字 1/0 / null 一律丢弃', () {
      final List<Object?> invalid = <Object?>['true', 'false', 1, 0, null, <String, dynamic>{}];
      for (final String field in _boolFields) {
        for (final Object? value in invalid) {
          final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{field: value})!;
          expect(failure.toJson().containsKey(field), isFalse, reason: '$field=$value');
        }
      }
    });
  });

  group('R5 嵌套投影（Qt/src/MusicApi.cpp:40-45，递归深度上限 1）', () {
    test('R5 lastFailure / primaryFailure 是对象时各自递归收录', () {
      final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{
        'code': 500,
        'lastFailure': <String, dynamic>{'code': 403, 'failureStage': 'recover'},
        'primaryFailure': <String, dynamic>{'errorKey': 'upstream.timeout', 'retryable': true},
      })!;
      expect(failure.lastFailure, isNotNull);
      expect(failure.lastFailure!.code, 403);
      expect(failure.lastFailure!.failureStage, 'recover');
      expect(failure.primaryFailure, isNotNull);
      expect(failure.primaryFailure!.errorKey, 'upstream.timeout');
      expect(failure.primaryFailure!.retryable, isTrue);
    });

    test('R5 内层不再带 lastFailure / primaryFailure（includePrevious = false）', () {
      // MusicApi.cpp:41、:44 递归调用时显式传 false
      final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{
        'code': 500,
        'lastFailure': <String, dynamic>{
          'code': 403,
          'lastFailure': <String, dynamic>{'code': 999},
          'primaryFailure': <String, dynamic>{'code': 998},
        },
      })!;
      expect(failure.code, 500);
      expect(failure.lastFailure!.code, 403);
      expect(failure.lastFailure!.lastFailure, isNull);
      expect(failure.lastFailure!.primaryFailure, isNull);
      final Map<String, dynamic> nested = failure.toJson()['lastFailure']! as Map<String, dynamic>;
      expect(nested, <String, dynamic>{'code': 403});
    });

    test('R5 内层同样执行白名单（非法内层字段不出现）', () {
      final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{
        'lastFailure': <String, dynamic>{
          'code': 403,
          'token': 'secret',
          'failureStage': 'BadStage',
          'retryAfterMs': double.nan,
          'retryable': true,
        },
      })!;
      expect(failure.lastFailure!.toJson(), <String, dynamic>{'code': 403, 'retryable': true});
    });

    test('R5 空对象内层保留为空投影（isObject 为真即收录）', () {
      // MusicApi.cpp:40-45：只要 isObject() 就 result["lastFailure"] = {}
      final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{
        'lastFailure': <String, dynamic>{},
      })!;
      expect(failure.lastFailure, isNotNull);
      expect(failure.lastFailure!.toJson(), <String, dynamic>{});
      expect(failure.toJson(), <String, dynamic>{'lastFailure': <String, dynamic>{}});
    });

    test('R5 内层不是对象（字符串 / 数组 / null）时该键不出现', () {
      final List<Object?> invalid = <Object?>['x', 'text', <Object?>[], null, 3, true];
      for (final Object? value in invalid) {
        final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{
          'lastFailure': value,
          'primaryFailure': value,
        })!;
        expect(failure.lastFailure, isNull, reason: value.runtimeType.toString());
        expect(failure.primaryFailure, isNull, reason: value.runtimeType.toString());
        expect(failure.toJson().containsKey('lastFailure'), isFalse);
        expect(failure.toJson().containsKey('primaryFailure'), isFalse);
      }
    });

    test('R5 includePrevious = false：顶层不递归两个前序失败', () {
      // MusicApi.cpp:40、:43 条件里的 includePrevious
      final ApiFailure failure = ApiFailure.fromJson(
        <String, dynamic>{
          'code': 500,
          'lastFailure': <String, dynamic>{'code': 403},
          'primaryFailure': <String, dynamic>{'code': 404},
        },
        includePrevious: false,
      )!;
      expect(failure.code, 500);
      expect(failure.lastFailure, isNull);
      expect(failure.primaryFailure, isNull);
      expect(failure.toJson(), <String, dynamic>{'code': 500});
    });
  });

  group('R5 verification / authExpired 标记（Qt/src/MusicApi.cpp:51-56）', () {
    test('R5 verification == "unconfirmed" → unconfirmed 为真并出现在投影里', () {
      // MusicApi.cpp:51-53
      final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{
        'verification': 'unconfirmed',
      })!;
      expect(failure.unconfirmed, isTrue);
      expect(failure.toJson(), <String, dynamic>{'verification': 'unconfirmed'});
    });

    test('R5 verification 其它值一律不置（含大小写变体与非字符串）', () {
      // MusicApi.cpp:51 body["verification"] == "unconfirmed" 逐字比较
      final List<Object?> others = <Object?>['confirmed', 'Unconfirmed', 'unconfirmed ', '', true, 1, null, <String, dynamic>{}];
      for (final Object? value in others) {
        final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{'verification': value})!;
        expect(failure.unconfirmed, isFalse, reason: value.toString());
        expect(failure.toJson().containsKey('verification'), isFalse, reason: value.toString());
      }
    });

    test('R5 authExpired 只认布尔 true', () {
      // MusicApi.cpp:54 body["authExpired"].toBool()：非 bool 一律 false
      expect(ApiFailure.fromJson(<String, dynamic>{'authExpired': true})!.authExpired, isTrue);
      expect(ApiFailure.fromJson(<String, dynamic>{'authExpired': true})!.toJson(), <String, dynamic>{'authExpired': true});
      final List<Object?> others = <Object?>[false, 'true', 'True', 1, 0, null, <String, dynamic>{}];
      for (final Object? value in others) {
        final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{'authExpired': value})!;
        expect(failure.authExpired, isFalse, reason: value.toString());
        expect(failure.toJson().containsKey('authExpired'), isFalse, reason: value.toString());
      }
    });
  });

  group('R5 白名单制（Qt/src/MusicApi.cpp:26-58 不透传原始对象）', () {
    test('R5 未列入白名单的键在投影里完全不出现', () {
      final ApiFailure failure = ApiFailure.fromJson(<String, dynamic>{
        'code': 200,
        'token': 'secret',
        'cookies': <Object?>['a'],
        'message': 'hi',
        'value': 1,
        'verification': 'confirmed',
        'authExpired': false,
        '_epoch': 3,
        'nested': <String, dynamic>{'code': 500},
        'upstreamBody': <String, dynamic>{'x': 1},
      })!;
      expect(failure.toJson(), <String, dynamic>{'code': 200});
    });

    test('R5 toJson → fromJson 往返保持投影不变', () {
      final Map<String, dynamic> source = <String, dynamic>{
        'failureStage': 'recover',
        'code': 503,
        'retryAfterMs': 2000,
        'retryable': false,
        'writeAttempted': true,
        'verification': 'unconfirmed',
        'authExpired': true,
        'lastFailure': <String, dynamic>{'code': 500, 'errorKey': 'upstream.timeout'},
        'token': 'secret',
      };
      final ApiFailure first = ApiFailure.fromJson(source)!;
      final ApiFailure second = ApiFailure.fromJson(first.toJson())!;
      expect(second.toJson(), first.toJson());
      expect(second.toJson().containsKey('token'), isFalse);
    });
  });

  group('R6 codeOf（Qt/src/MusicApi.cpp:110 toInt(200)）', () {
    test('R6 整数值且在 int32 范围内才转换（QJsonValue::toInt 的 Double 分支）', () {
      // qjsonvalue.cpp:686-694 只有 convertDoubleTo<int>(toDouble(), &dblInt) 成功才返回；
      // qnumeric_p.h:281-286 取整后回比「整型回填 double == 原值」判整性。
      expect(ApiResult.codeOf(<String, dynamic>{'code': 200}), 200);
      expect(ApiResult.codeOf(<String, dynamic>{'code': 200.0}), 200);
      expect(ApiResult.codeOf(<String, dynamic>{'code': 403}), 403);
      expect(ApiResult.codeOf(<String, dynamic>{'code': 403.0}), 403);
      expect(ApiResult.codeOf(<String, dynamic>{'code': 0}), 0);
      expect(ApiResult.codeOf(<String, dynamic>{'code': 801}), 801);
      expect(ApiResult.codeOf(<String, dynamic>{'code': -1}), -1);
    });

    test('R6 非整数 double 回落默认 200（Qt toInt 对非整数取 default）', () {
      // qnumeric_p.h:286 return *value == v; → 403.9 取整回 403 != 403.9 → false → defaultValue 200。
      // 因此 code=403.9 在 Qt 侧落在默认 allowed {200} 内 → 成功，而非失败（403）。
      expect(ApiResult.codeOf(<String, dynamic>{'code': 403.9}), 200);
      expect(ApiResult.codeOf(<String, dynamic>{'code': -3.7}), 200);
      expect(ApiResult.codeOf(<String, dynamic>{'code': 200.7}), 200);
      expect(ApiResult.codeOf(<String, dynamic>{'code': 403.000001}), 200);
    });

    test('R6 int32 边界：Tmin 与 Tmax 收录，越界回落默认 200', () {
      // qnumeric_p.h:268-269（v < Tmin → false）、:276-278（v >= supremum = 2^31 → false）；
      // qjsonvalue.cpp:697 的 Integer 分支同样要求 qint64(int(n)) == n。
      expect(ApiResult.codeOf(<String, dynamic>{'code': -2147483648}), -2147483648);
      expect(ApiResult.codeOf(<String, dynamic>{'code': 2147483647}), 2147483647);
      expect(ApiResult.codeOf(<String, dynamic>{'code': 2147483648}), 200);
      expect(ApiResult.codeOf(<String, dynamic>{'code': -2147483649}), 200);
      expect(ApiResult.codeOf(<String, dynamic>{'code': 4294967296}), 200);
    });

    test('R6 超出 int32 的 double（1e300 等）回落默认 200 且不抛异常', () {
      // qnumeric_p.h:276-278 的上界守卫直接 return false → qjsonvalue.cpp:704 回落 200；
      // Dart 侧不依赖规范未定义的 double.toInt()。
      expect(ApiResult.codeOf(<String, dynamic>{'code': 1e300}), 200);
      expect(ApiResult.codeOf(<String, dynamic>{'code': -1e300}), 200);
      expect(ApiResult.codeOf(<String, dynamic>{'code': 1e18}), 200);
      expect(ApiResult.codeOf(<String, dynamic>{'code': 2147483648.0}), 200);
      expect(ApiResult.codeOf(<String, dynamic>{'code': -2147483648.5}), 200);
    });

    test('R6 非 num（含字符串 "403"）一律取默认 200', () {
      // Qt QJsonValue::toInt 只在类型为 Double/Integer 时转换，其它类型返回默认值（qjsonvalue.cpp:701-704）
      final List<Object?> invalid = <Object?>['403', '200', true, false, null, '', <Object?>[], <String, dynamic>{}];
      for (final Object? value in invalid) {
        expect(ApiResult.codeOf(<String, dynamic>{'code': value}), 200, reason: value.toString());
      }
      expect(ApiResult.codeOf(<String, dynamic>{}), 200);
    });

    test('R6 NaN / ±Infinity 回落默认 200（范围检查与回比判失败，非 UB 兜底）', () {
      // qnumeric_p.h:268-278 对 ±Inf 范围判失败；NaN 由 :286 的整型回比判失败；
      // 两者在 qjsonvalue.cpp:704 都回落 defaultValue。
      expect(ApiResult.codeOf(<String, dynamic>{'code': double.nan}), 200);
      expect(ApiResult.codeOf(<String, dynamic>{'code': double.infinity}), 200);
      expect(ApiResult.codeOf(<String, dynamic>{'code': double.negativeInfinity}), 200);
    });
  });

  group('R7 messageOf（Qt/src/MusicApi.cpp:112-115 消息合成）', () {
    test('R7 message 优先于 msg', () {
      // MusicApi.cpp:112 body["message"].toString(body["msg"].toString("请稍后重试"))
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': 'A', 'msg': 'B'}, adapted: true, source: ProviderId.qq),
        'A',
      );
    });

    test('R7 message 非字符串时回退 msg', () {
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': 5, 'msg': 'B'}, adapted: true, source: ProviderId.qq),
        'B',
      );
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': null, 'msg': 'B'}, adapted: true, source: ProviderId.qq),
        'B',
      );
    });

    test('R7 message 与 msg 都不是字符串时回退「请稍后重试」', () {
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': 5, 'msg': <Object?>[]}, adapted: true, source: ProviderId.qq),
        ApiResult.fallbackMessage,
      );
      expect(ApiResult.messageOf(<String, dynamic>{}, adapted: true, source: ProviderId.qq), '请稍后重试');
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': true, 'msg': null}, adapted: true, source: ProviderId.netease),
        '请稍后重试',
      );
    });

    test('R7 空串短路：message == "" 不回退 msg', () {
      // Qt 的 toString(defaultValue) 只在类型不是 String 时取默认值，空串是合法 String
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': '', 'msg': 'B'}, adapted: true, source: ProviderId.qq),
        '',
      );
    });

    test('R7 adapted = true 不加前缀（call 的适配路径）', () {
      // MusicApi.cpp:113 if (!adapted) 之外：消息原样
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': 'A'}, adapted: true, source: ProviderId.kugou),
        'A',
      );
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': 'A', 'code': 500}, adapted: true, source: ProviderId.kugou),
        'A',
      );
    });

    test('R7 adapted = false 加前缀：displayName + "返回 " + code + "："（全角冒号）', () {
      // MusicApi.cpp:114 providerName(source) + "返回 " + QString::number(code) + "：" + message
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': 'A', 'code': 403}, adapted: false, source: ProviderId.qq),
        'QQ 音乐返回 403：A',
      );
      expect(
        ApiResult.messageOf(<String, dynamic>{'msg': 'B', 'code': 500}, adapted: false, source: ProviderId.kugou),
        '酷狗音乐返回 500：B',
      );
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': 'C', 'code': 500}, adapted: false, source: ProviderId.local),
        '本地音乐返回 500：C',
      );
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': 'D', 'code': 500}, adapted: false, source: ProviderId.siren),
        '塞壬唱片返回 500：D',
      );
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': 'E', 'code': 500}, adapted: false, source: ProviderId.netease),
        '网易云音乐返回 500：E',
      );
    });

    test('R7 adapted = false 时未知 provider 落到网易云音乐（providerName 默认分支）', () {
      // MusicApi.cpp:10-24 默认分支 + :114 前缀
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': 'A', 'code': 500}, adapted: false, source: ProviderId.parse('spotify')),
        '网易云音乐返回 500：A',
      );
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': 'A', 'code': 500}, adapted: false, source: ProviderId.parse('')),
        '网易云音乐返回 500：A',
      );
    });

    test('R7 前缀里的 code 走 R6 解析（字符串 code → 200）', () {
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': 'A', 'code': '403'}, adapted: false, source: ProviderId.kugou),
        '酷狗音乐返回 200：A',
      );
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': 'A'}, adapted: false, source: ProviderId.kugou),
        '酷狗音乐返回 200：A',
      );
    });

    test('R7 空消息 + adapted = false 时以全角冒号结尾', () {
      expect(
        ApiResult.messageOf(<String, dynamic>{'message': '', 'code': 403}, adapted: false, source: ProviderId.local),
        '本地音乐返回 403：',
      );
    });
  });

  group('R8 fromResponse（Qt/src/MusicApi.cpp:98-123 send 的形状判定）', () {
    test('R8 body 不是对象 → error 逐字「元数据格式无效」，value/failure 空', () {
      // MusicApi.cpp:105-108
      final List<Object?> bodies = <Object?>[null, 'text', 7, true, <Object?>[], <Object?>[<String, dynamic>{'code': 500}]];
      for (final Object? body in bodies) {
        final ApiResult result = ApiResult.fromResponse(
          <String, dynamic>{'body': body},
          adapted: true,
          source: ProviderId.netease,
        );
        expect(result.ok, isFalse, reason: body.runtimeType.toString());
        expect(result.error, '元数据格式无效');
        expect(result.error, ApiResult.metadataFormatError);
        expect(result.value, isNull);
        expect(result.failure, isNull);
      }
    });

    test('R8 response 本身不是对象 → 同样「元数据格式无效」', () {
      // Qt 里 response["body"] 对非对象 response 返回 undefined，isObject() 为假
      expect(
        ApiResult.fromResponse('boom', adapted: false, source: ProviderId.qq).error,
        ApiResult.metadataFormatError,
      );
      expect(ApiResult.fromResponse(null, adapted: false, source: ProviderId.qq).error, '元数据格式无效');
      expect(
        ApiResult.fromResponse(<Object?>[], adapted: true, source: ProviderId.qq).error,
        '元数据格式无效',
      );
    });

    test('R8 response 缺 body 键 → 同样「元数据格式无效」', () {
      expect(
        ApiResult.fromResponse(<String, dynamic>{'cookies': <Object?>[]}, adapted: true, source: ProviderId.netease).error,
        '元数据格式无效',
      );
    });

    test('R8 code 在 allowed 内 → ok；adapted = true 时 value = body["value"]', () {
      // MusicApi.cpp:111 allowed.contains(code) 为真 + :123 adapted ? body["value"] : body
      final ApiResult result = ApiResult.fromResponse(
        <String, dynamic>{
          'body': <String, dynamic>{'code': 200, 'value': <String, dynamic>{'id': '1'}},
        },
        adapted: true,
        source: ProviderId.netease,
      );
      expect(result.ok, isTrue);
      expect(result.error, '');
      expect(result.failure, isNull);
      expect(result.value, <String, dynamic>{'id': '1'});
    });

    test('R8 code 在 allowed 内 + adapted = false → 整个 body 就是 value', () {
      // MusicApi.cpp:123 QJsonValue(body)
      const Map<String, dynamic> body = <String, dynamic>{'code': 200, 'data': 'raw'};
      final ApiResult result = ApiResult.fromResponse(
        <String, dynamic>{'body': body},
        adapted: false,
        source: ProviderId.qq,
      );
      expect(result.ok, isTrue);
      expect(result.value, body);
      expect((result.value! as Map<String, dynamic>)['code'], 200);
    });

    test('R8 adapted = true 且 body 无 value → value 为 null 但 ok', () {
      // Qt 对缺失键取 QJsonValue undefined，error 仍为空
      final ApiResult result = ApiResult.fromResponse(
        <String, dynamic>{'body': <String, dynamic>{'code': 200}},
        adapted: true,
        source: ProviderId.netease,
      );
      expect(result.ok, isTrue);
      expect(result.value, isNull);
    });

    test('R8 缺省 code → 200，落在默认 allowed {200} 内 → ok', () {
      // MusicApi.cpp:110 toInt(200) 默认值 + :69 allowed = {200}
      final ApiResult result = ApiResult.fromResponse(
        <String, dynamic>{'body': <String, dynamic>{'value': 'x'}},
        adapted: true,
        source: ProviderId.netease,
      );
      expect(result.ok, isTrue);
      expect(result.value, 'x');
    });

    test('R8 code 不在 allowed → 失败：error = 合成 message，failure = 白名单投影', () {
      // MusicApi.cpp:111-117
      final ApiResult result = ApiResult.fromResponse(
        <String, dynamic>{
          'body': <String, dynamic>{
            'code': 403,
            'message': '需要登录',
            'failureStage': 'auth',
            'token': 'secret',
            'retryable': true,
          },
        },
        adapted: false,
        source: ProviderId.qq,
      );
      expect(result.ok, isFalse);
      expect(result.error, 'QQ 音乐返回 403：需要登录');
      expect(result.value, isNull);
      expect(result.failure, isNotNull);
      expect(result.failure!.failureStage, 'auth');
      expect(result.failure!.code, 403);
      expect(result.failure!.retryable, isTrue);
      expect(result.failure!.toJson().containsKey('token'), isFalse);
      expect(result.failure!.toJson().length, 3);
    });

    test('R8 失败路径的 message 与 adapted 联动（adapted = true 不加前缀）', () {
      final ApiResult result = ApiResult.fromResponse(
        <String, dynamic>{'body': <String, dynamic>{'code': 500, 'msg': '上游超时'}},
        adapted: true,
        source: ProviderId.kugou,
      );
      expect(result.ok, isFalse);
      expect(result.error, '上游超时');
      expect(result.failure!.code, 500);
    });

    test('R8 字符串 code → 200 → 默认 allowed 判定为成功（R6 与 R8 联动）', () {
      final ApiResult result = ApiResult.fromResponse(
        <String, dynamic>{'body': <String, dynamic>{'code': '403', 'value': 'v'}},
        adapted: true,
        source: ProviderId.qq,
      );
      expect(result.ok, isTrue);
      expect(result.value, 'v');
    });

    test('R8 自定义 allowed 生效（request 的 allowed 由调用方给出）', () {
      // MusicApi.cpp:83 send(route, parameters, false, ..., allowed)
      final ApiResult allowed = ApiResult.fromResponse(
        <String, dynamic>{'body': <String, dynamic>{'code': 403, 'message': 'ok'}},
        adapted: false,
        source: ProviderId.netease,
        allowed: <int>{200, 403},
      );
      expect(allowed.ok, isTrue);
      expect(allowed.value! as Map<String, dynamic>, <String, dynamic>{'code': 403, 'message': 'ok'});

      final ApiResult denied = ApiResult.fromResponse(
        <String, dynamic>{'body': <String, dynamic>{'code': 403, 'message': 'ok'}},
        adapted: false,
        source: ProviderId.netease,
        allowed: <int>{800, 801},
      );
      expect(denied.ok, isFalse);
      expect(denied.error, '网易云音乐返回 403：ok');
    });

    test('R8 code 为 bool / null / 容器 → 200 → 默认 allowed 判定为成功', () {
      final List<Object?> values = <Object?>[true, '200', null, <Object?>[]];
      for (final Object? value in values) {
        final ApiResult result = ApiResult.fromResponse(
          <String, dynamic>{'body': <String, dynamic>{'code': value, 'value': 'v'}},
          adapted: true,
          source: ProviderId.netease,
        );
        expect(result.ok, isTrue, reason: value.toString());
      }
    });

    test('R8 失败时不透传未白名单键（含 cookies / _epoch / _credentialKey）', () {
      // MusicApi.cpp:116 safeFailure(body) 只投影白名单；cookies/_epoch 由 :119-122 单独消费
      final ApiResult result = ApiResult.fromResponse(
        <String, dynamic>{
          'cookies': <Object?>['a=1'],
          '_epoch': 7,
          '_credentialKey': 'k',
          'body': <String, dynamic>{
            'code': 500,
            'message': 'x',
            'cookies': <Object?>['b=2'],
            '_epoch': 8,
            '_credentialKey': 'k2',
            'verification': 'unconfirmed',
          },
        },
        adapted: false,
        source: ProviderId.siren,
      );
      expect(result.failure!.toJson(), <String, dynamic>{'code': 500, 'verification': 'unconfirmed'});
    });
  });
}
