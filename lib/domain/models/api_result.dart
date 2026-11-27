// Qt -> Flutter 迁移 · 共享模型 SHARED-S3：调用结果与失败投影（ApiResult / ApiFailure）。
//
// 契约来源（逐条对照 Qt 原文，行号即依据）：
// - Qt/src/MusicApi.h:7-14      struct MusicReply { value; error; failure; ok() = error.isEmpty() }
// - Qt/src/MusicApi.cpp:26-58   safeFailure()：白名单投影（字符串正则、数值 isDouble && isfinite、
//                               布尔 isBool、lastFailure/primaryFailure 只递归一层、
//                               verification == "unconfirmed"、authExpired 真值）。
// - Qt/src/MusicApi.cpp:61-70   call()：local 守卫；adapted = true、allowed = {200}。
// - Qt/src/MusicApi.cpp:72-84   request()：local 守卫；adapted = false、allowed 由调用方给出。
// - Qt/src/MusicApi.cpp:98-123  send()：owner/valid 屏障 → 宿主错误 → body 非对象 → code/allowed →
//                               message 合成 → value = adapted ? body["value"] : body。
//
// 迟到响应（Qt/src/MusicApi.cpp:90-124 的 QPointer owner + valid() 屏障）：
//   Dart 侧【不实现】该机制，也不新增任何协议字段来替代它。调用方负责丢弃迟到响应：在结果回调处
//   比较「发起调用时的身份与世代」，过期结果直接 return，不得写回业务状态或凭据
//   （Qt 侧的对应屏障：MusicLibrary.cpp 的 valid 世代、MusicAccount.cpp 的 m_accountGeneration）。
//
// 本文件不声明 JsonMap typedef：SHARED-S1 会在 lib/domain/models/music_item.dart 定义同名 typedef，
// 同时 import 两者会产生歧义，因此这里统一使用 Map<String, dynamic>，也不 import music_item.dart。

import 'provider_id.dart';

/// Qt/src/MusicApi.cpp:28 的诊断串白名单正则 ^[a-z.-]{1,80}$（anchored）。
///
/// 与源码逐字核对后的已知微差异：Qt 使用 PCRE 且未开启 DOLLAR_ENDONLY，因此 $ 也匹配「末尾换行之前」，
/// Qt 会接受 "recover\n" 这样的串；Dart 的 $ 只匹配输入末尾，不接受它。真实诊断串不含换行，
/// 这里按冻结的 anchored 语义实现，不做额外放宽（已记入报告 openRisks）。
final RegExp _diagnosticPattern = RegExp(r'^[a-z.-]{1,80}$');

/// Qt/src/MusicApi.cpp:26-58 safeFailure() 的投影结果。
///
/// 白名单语义是「缺键」而不是「置空」，因此可以用 toJson() 区分
/// 「键不存在」与「键存在但值为 false」。
/// - 字符串：failureStage / failureReason / errorKey / upstreamErrorKey，值必须是 String 且匹配
///   ^[a-z.-]{1,80}$（Qt/src/MusicApi.cpp:29-33）。
/// - 数值：code / retryAfterMs / upstreamHttpStatus / upstreamCode / upstreamGlobalCode /
///   upstreamSubCode，值必须是 num 且有限（Qt 只接受 isDouble 且 std::isfinite；
///   Qt/src/MusicApi.cpp:34-39）。
/// - 布尔：retryable / writeAttempted，值必须是 bool（false 也收录；Qt/src/MusicApi.cpp:46-50）。
/// - 嵌套：lastFailure / primaryFailure，值必须是对象，且只递归一层
///   （内层 includePrevious = false；Qt/src/MusicApi.cpp:40-45）。
/// - 标记：verification 与字符串 "unconfirmed" 完全相等时置 unconfirmed
///   （Qt/src/MusicApi.cpp:51-53）；authExpired 为布尔 true 时置 authExpired
///   （Qt 用 toBool()，非 bool 一律 false；Qt/src/MusicApi.cpp:54-56）。
/// - 其余键一律不透传（白名单制；Qt/src/MusicApi.cpp:57）。
class ApiFailure {
  final String? failureStage;
  final String? failureReason;
  final String? errorKey;
  final String? upstreamErrorKey;
  final num? code;
  final num? retryAfterMs;
  final num? upstreamHttpStatus;
  final num? upstreamCode;
  final num? upstreamGlobalCode;
  final num? upstreamSubCode;
  final bool? retryable;
  final bool? writeAttempted;
  final ApiFailure? lastFailure;
  final ApiFailure? primaryFailure;
  final bool unconfirmed;
  final bool authExpired;

  const ApiFailure({
    this.failureStage,
    this.failureReason,
    this.errorKey,
    this.upstreamErrorKey,
    this.code,
    this.retryAfterMs,
    this.upstreamHttpStatus,
    this.upstreamCode,
    this.upstreamGlobalCode,
    this.upstreamSubCode,
    this.retryable,
    this.writeAttempted,
    this.lastFailure,
    this.primaryFailure,
    this.unconfirmed = false,
    this.authExpired = false,
  });

  /// Qt/src/MusicApi.cpp:26-58 safeFailure(body, includePrevious)。
  ///
  /// [body] 不是对象（Qt 的 isObject() 为假）时返回 null：Qt 在这种情况下不会产生投影。
  /// 空对象返回「非 null 的空投影」（Qt 的 safeFailure 总是返回一个 QJsonObject）。
  /// [includePrevious] 为 false 时顶层不再递归 lastFailure / primaryFailure（递归深度上限 1）。
  static ApiFailure? fromJson(Object? body, {bool includePrevious = true}) {
    if (body is! Map) {
      return null;
    }
    String? diagnostic(String name) {
      final Object? value = body[name];
      if (value is String && _diagnosticPattern.hasMatch(value)) {
        return value;
      }
      return null;
    }

    num? number(String name) {
      final Object? value = body[name];
      if (value is num && value.isFinite) {
        return value;
      }
      return null;
    }

    bool? boolean(String name) {
      final Object? value = body[name];
      return value is bool ? value : null;
    }

    ApiFailure? previous(String name) {
      if (!includePrevious) {
        return null;
      }
      final Object? value = body[name];
      if (value is! Map) {
        return null;
      }
      return ApiFailure.fromJson(value, includePrevious: false);
    }

    return ApiFailure(
      failureStage: diagnostic('failureStage'),
      failureReason: diagnostic('failureReason'),
      errorKey: diagnostic('errorKey'),
      upstreamErrorKey: diagnostic('upstreamErrorKey'),
      code: number('code'),
      retryAfterMs: number('retryAfterMs'),
      upstreamHttpStatus: number('upstreamHttpStatus'),
      upstreamCode: number('upstreamCode'),
      upstreamGlobalCode: number('upstreamGlobalCode'),
      upstreamSubCode: number('upstreamSubCode'),
      retryable: boolean('retryable'),
      writeAttempted: boolean('writeAttempted'),
      lastFailure: previous('lastFailure'),
      primaryFailure: previous('primaryFailure'),
      unconfirmed: body['verification'] == 'unconfirmed',
      authExpired: body['authExpired'] == true,
    );
  }

  /// Qt/src/MusicApi.cpp:26-58 的投影输出（与 safeFailure 的键集合一一对应）。
  /// 标记键只在其值为真时出现：unconfirmed 为假时不输出 "verification"，
  /// authExpired 为假时不输出 "authExpired"（Qt/src/MusicApi.cpp:51-56 只在命中时赋值）。
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = <String, dynamic>{};
    if (failureStage != null) {
      result['failureStage'] = failureStage;
    }
    if (failureReason != null) {
      result['failureReason'] = failureReason;
    }
    if (errorKey != null) {
      result['errorKey'] = errorKey;
    }
    if (upstreamErrorKey != null) {
      result['upstreamErrorKey'] = upstreamErrorKey;
    }
    if (code != null) {
      result['code'] = code;
    }
    if (retryAfterMs != null) {
      result['retryAfterMs'] = retryAfterMs;
    }
    if (upstreamHttpStatus != null) {
      result['upstreamHttpStatus'] = upstreamHttpStatus;
    }
    if (upstreamCode != null) {
      result['upstreamCode'] = upstreamCode;
    }
    if (upstreamGlobalCode != null) {
      result['upstreamGlobalCode'] = upstreamGlobalCode;
    }
    if (upstreamSubCode != null) {
      result['upstreamSubCode'] = upstreamSubCode;
    }
    if (lastFailure != null) {
      result['lastFailure'] = lastFailure!.toJson();
    }
    if (primaryFailure != null) {
      result['primaryFailure'] = primaryFailure!.toJson();
    }
    if (retryable != null) {
      result['retryable'] = retryable;
    }
    if (writeAttempted != null) {
      result['writeAttempted'] = writeAttempted;
    }
    if (unconfirmed) {
      result['verification'] = 'unconfirmed';
    }
    if (authExpired) {
      result['authExpired'] = true;
    }
    return result;
  }
}

/// Qt/src/MusicApi.h:7-14 MusicReply 的 Dart 投影。
///
/// ok 只由 error 是否为空决定（Qt/src/MusicApi.h:11-13），与 value / failure 无关。
/// 失败形状（Qt/src/MusicApi.cpp:98-123）：
/// - 宿主错误：error = 宿主返回的 error，value / failure 为空（Qt/src/MusicApi.cpp:101-104）；
///   Dart 侧等价写法是 ApiResult.failure(hostError)。
/// - response 的 body 不是对象：error 逐字「元数据格式无效」，value / failure 为空
///   （Qt/src/MusicApi.cpp:105-108）。
/// - code 不在 allowed：error = 合成后的 message，failure = safeFailure(body)
///   （Qt/src/MusicApi.cpp:111-117）。
/// - 成功：error 为空，value = adapted ? body["value"] : body（Qt/src/MusicApi.cpp:123）。
class ApiResult {
  final Object? value;
  final String error;
  final ApiFailure? failure;

  const ApiResult({this.value, this.error = '', this.failure});

  /// Qt/src/MusicApi.h:11-13 ok() const { return error.isEmpty(); }。
  bool get ok => error.isEmpty;

  /// 成功结果：error 为空、无 failure（Qt/src/MusicApi.cpp:123）。
  factory ApiResult.success(Object? value) => ApiResult(value: value);

  /// 失败结果：error 逐字保留，可选的 failure 投影
  /// （Qt/src/MusicApi.cpp:102 宿主错误、:106 元数据格式无效、:116 safeFailure）。
  factory ApiResult.failure(String error, [ApiFailure? failure]) =>
      ApiResult(error: error, failure: failure);

  /// Qt/src/MusicApi.cpp:106 QStringLiteral("元数据格式无效")。
  static const String metadataFormatError = '元数据格式无效';

  /// Qt/src/MusicApi.cpp:64、:76 QStringLiteral("本地模式不提供在线平台操作")。
  static const String localModeError = '本地模式不提供在线平台操作';

  /// Qt/src/MusicApi.cpp:112 toString("请稍后重试")。
  static const String fallbackMessage = '请稍后重试';

  /// qnumeric_p.h:265-269 的 int 下界：Tmin = -2^31（含）。
  static const double _int32Min = -2147483648.0;

  /// qnumeric_p.h:266、:277-278 的上界 supremum = -1.0 * int32_min = 2^31（不含）。
  static const double _int32Supremum = 2147483648.0;

  /// qnumeric_p.h:180-181 的 numeric_limits<int>（Integer 分支 :697 的 qint64(int(n)) == n 同界）。
  static const int _int32MinValue = -2147483648;
  static const int _int32MaxValue = 2147483647;

  /// Qt/src/MusicApi.cpp:110 `body["code"].toInt(200)`。
  ///
  /// 语义按 Qt 6.12.0 的真实实现，**不是** C++ static_cast / 向零截断：
  /// - qjsonvalue.cpp:686-705 QJsonValue::toInt(int defaultValue)：Double 分支只有在
  ///   convertDoubleTo<int>(toDouble(), &dblInt) 返回 true 时才返回 dblInt，否则一律回落
  ///   defaultValue；同函数 :695-700 的 Integer 分支还要求 qint64(int(n)) == n，即超出 int
  ///   表示范围的整数同样回落 defaultValue（toInt 自己的文档块在 :679-685；:707-713 是
  ///   toInteger 的文档，讲的是 qint64 可表示范围，不可拿来解释 int 分支）。
  /// - qnumeric_p.h:164-289 convertDoubleTo 整型重载：:268-269 用 `v < Tmin` 判下界、
  ///   :276-278 用 `v >= supremum`（int 时 supremum = 2^31）判上界，越界即 return false；
  ///   :281 取整后 :286 `return *value == v;` 用「整型回填 double 是否等于原值」判整性。
  /// - qjsonparser.cpp:688-693、:704-706：JSON 文本里的整数值（含 "403.0" 这种小数位全零的写法）
  ///   在 Qt 侧被解析成 QCborValue::Integer，其余才是 Double；两条分支对 int32 范围的收敛结果一致
  ///   （Integer 分支 :697 的 qint64(int(n)) == n 与 Double 分支的范围检查同界），所以 Dart 的
  ///   int / double 两种载荷可以用同一条 int32 收敛规则。
  ///
  /// 因此只有「整数值且落在 int32 可表示范围」才转换；其余（非整数 double 如 403.9 /
  /// -3.7 / 200.7、超出 int32 的 double 如 1e300、字符串 "403"、bool、null、缺失键、
  /// NaN 与 ±Infinity）全部取默认 200。
  /// Qt 侧同结论的路径依赖构建：±Inf 在通用路径经 :268-269 / :277-278 的范围检查即失败；
  /// NaN 在 x86-64 SSE2 快路径由 :216-221 判失败，而通用路径的 T(NaN) 形式上是 UB
  /// （qnumeric_p.h:161-162 明说本函数不保证 NaN，由调用方排除）。Dart 侧统一返回 200，
  /// 与 x86-64 上的 Qt 行为一致，且不依赖任何未定义行为。
  static int codeOf(Map<String, dynamic> body) {
    final Object? value = body['code'];
    if (value is int) {
      // qjsonparser.cpp:688-693、:704-706：JSON 整数在 Qt 侧被解析成 QCborValue::Integer，
      // toInt 走 qjsonvalue.cpp:695-700 的 Integer 分支（要求 qint64(int(n)) == n）；
      // 超出 int32 的整数与 Double 分支同样回落默认 200。
      return value >= _int32MinValue && value <= _int32MaxValue ? value : 200;
    }
    if (value is double) {
      // qnumeric_p.h:268-269 / :276-278 的范围守卫：先挡掉 NaN / ±Infinity 与越界值，
      // 不把超范围 double 交给 Dart 规范未定义的 double.toInt()。
      if (!value.isFinite || value < _int32Min || value >= _int32Supremum) {
        return 200;
      }
      // qnumeric_p.h:281-286：向零取整（C++ 的 T(v)）后回填 double 与原值比较判整性。
      final int truncated = value.truncate();
      return truncated.toDouble() == value ? truncated : 200;
    }
    return 200;
  }

  /// Qt/src/MusicApi.cpp:112-115 的消息合成，逐字复刻：
  /// message = body["message"] 是 String ? 它 : (body["msg"] 是 String ? 它 : "请稍后重试")；
  /// 且仅当 !adapted 时前缀 providerName(source) + "返回 " + code + "："（中文全角冒号）。
  /// 空串短路：message == "" 时不会回退到 msg（Qt 的 toString(defaultValue) 只在类型不匹配时取默认值）。
  static String messageOf(
    Map<String, dynamic> body, {
    required bool adapted,
    required ProviderId source,
  }) {
    final Object? raw = body['message'];
    final Object? fallback = body['msg'];
    final String message = raw is String
        ? raw
        : (fallback is String ? fallback : fallbackMessage);
    if (adapted) {
      return message;
    }
    return '${source.displayName}返回 ${codeOf(body)}：$message';
  }

  /// Qt/src/MusicApi.cpp:98-123 send() 收到宿主响应之后的形状判定
  /// （不含 owner/valid 屏障与宿主错误分支，二者由调用方负责）。
  ///
  /// - [response] 不是对象，或 response["body"] 不是对象 →
  ///   ApiResult.failure(metadataFormatError)（value / failure 为空）；
  /// - response["body"]["code"] 不在 [allowed] → error = 合成 message，
  ///   failure = ApiFailure.fromJson(body)；
  /// - 否则成功：value = [adapted] ? body["value"] : body（非 adapted 时整个 body 就是 value）。
  ///
  /// [allowed] 默认 {200}，与 Qt/src/MusicApi.cpp:69 的 call() 一致；
  /// request() 由调用方传入自己的 allowed（Qt/src/MusicApi.cpp:83）。
  static ApiResult fromResponse(
    Object? response, {
    required bool adapted,
    required ProviderId source,
    Set<int> allowed = const <int>{200},
  }) {
    if (response is! Map) {
      return const ApiResult(error: metadataFormatError);
    }
    final Object? body = response['body'];
    if (body is! Map) {
      return const ApiResult(error: metadataFormatError);
    }
    final Map<String, dynamic> normalized = <String, dynamic>{};
    body.forEach((Object? key, Object? value) {
      if (key is String) {
        normalized[key] = value;
      }
    });
    final int code = codeOf(normalized);
    if (!allowed.contains(code)) {
      return ApiResult(
        error: messageOf(normalized, adapted: adapted, source: source),
        failure: ApiFailure.fromJson(normalized),
      );
    }
    return ApiResult(value: adapted ? normalized['value'] : normalized);
  }

  /// Qt/src/MusicApi.cpp:62-67、:74-79：provider == "local" 时的固定失败
  /// （value 空、failure 空、error 逐字 localModeError）。
  static ApiResult localModeDisabled() => const ApiResult(error: localModeError);
}
