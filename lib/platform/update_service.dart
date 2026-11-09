/// T27-C14-W02 · 平台服务：Qt 更新检查（AppUpdater）→ Flutter 端口化移植。
///
/// 依据 = 本 worktree 内 Qt/src/AppUpdater.cpp（277 行）与 Qt/src/AppUpdater.h（42 行），
/// 每条语义后的行号即其 Qt 源依据；另参照 T06 冻结契约
/// worktrees/T06/test/fixtures/settings_sections.json:858-888（update 区块）。
///
/// 设计约束：
/// * 本文件零 import：宿主注入 [UpdatePorts]，不直接触碰 dart:io / Flutter。
///   JSON 解码由端口完成，端口以 [UpdateHttpResponse.jsonParseFailed] 复现 Qt :240 的解析失败分支。
/// * 状态文案与阈值逐字照抄 Qt 与 T06 契约，不得意译（见下方常量）。
/// * 安装/下载意图 = 交给系统浏览器打开发布页；应用内不下载、不安装（AppUpdater.cpp:275-277）。
library;

// ---------------------------------------------------------------------------
// 常量（行号即 Qt 源依据）
// ---------------------------------------------------------------------------

/// GitHub 仓库（AppUpdater.cpp:14 REPOSITORY）。
const String kUpdateRepository = 'MikeQu223/Rhine-Music-Database';

/// 单个更新包字节上限 2 GiB（AppUpdater.cpp:15 MAX_PACKAGE_BYTES）。
const int kMaxPackageBytes = 2147483648;

/// 响应体字节上限 1 MiB（AppUpdater.cpp:217 超过 1024*1024 即 abort）。
const int kMaxResponseBytes = 1048576;

/// 读取缓冲 1024*1024+1（AppUpdater.cpp:215 setReadBufferSize）。
const int kResponseReadBufferBytes = 1048577;

/// 传输超时 30 s（AppUpdater.cpp:47 setTransferTimeout(30000)）。
const int kTransferTimeoutMs = 30000;

/// 限流默认退避 60 s（AppUpdater.cpp:169-171 DEFAULT_RETRY_SECONDS）。
const int kDefaultRetrySeconds = 60;

/// Retry-After 夹取上限 86400 s（AppUpdater.cpp:175 qMin(seconds, 86400)）。
const int kMaxRetryAfterSeconds = 86400;

/// User-Agent 前缀（AppUpdater.cpp:45 "RhineMusicDatabase/" + currentVersion）。
const String kUserAgentPrefix = 'RhineMusicDatabase/';

/// 静态清单地址（AppUpdater.cpp:207）。
const String kManifestUrl = 'https://github.com/' + kUpdateRepository + '/releases/latest/download/update.json';

/// REST API 回退地址（AppUpdater.cpp:206）。
const String kApiUrl = 'https://api.github.com/repos/' + kUpdateRepository + '/releases/latest';

/// 发布页地址（AppUpdater.cpp:276）。
const String kReleasePageUrl = 'https://github.com/' + kUpdateRepository + '/releases';

/// API 回退请求头（AppUpdater.cpp:210-211）。
const String kApiAcceptHeader = 'Accept';
const String kApiAcceptValue = 'application/vnd.github+json';
const String kApiVersionHeader = 'X-GitHub-Api-Version';
const String kApiVersionValue = '2022-11-28';

/// 限流判定相关响应头（AppUpdater.cpp:163-164、173）。
const String kRetryAfterHeader = 'Retry-After';
const String kRateLimitRemainingHeader = 'X-RateLimit-Remaining';
const String kRateLimitResetHeader = 'X-RateLimit-Reset';

/// 产物名模板前缀（AppUpdater.cpp:118 "RhineMusicDatabase-" + tag + '-' + platform）。
const String kAssetNamePrefix = 'RhineMusicDatabase-';

/// 官方 URL 前缀（AppUpdater.cpp:40、113、125、127）。
const String kReleaseTagPrefix = '/releases/tag/';
const String kReleaseDownloadPrefix = '/releases/download/';

// ---------------------------------------------------------------------------
// 状态文案（Qt 逐字；键名对齐 T06 契约 settings_sections.json:858-888）
// ---------------------------------------------------------------------------

/// 初始状态（AppUpdater.cpp:36 m_status 初值）。
const String kInitialStatus = '尚未检查更新';

/// 离线（AppUpdater.cpp:193）。
const String kOfflineStatus = '离线模式不检查更新';

/// 正在检查（AppUpdater.cpp:200）。
const String kCheckingStatus = '正在检查更新…';

/// 两次都 404（AppUpdater.cpp:231）。
const String kNoReleaseStatus = '尚无正式发布版本';

/// JSON 非法（AppUpdater.cpp:241）。
const String kInvalidDataStatus = '更新服务返回了无效数据';

/// 已是最新（AppUpdater.cpp:257）。
const String kUpToDateStatus = '当前已是最新版本';

/// 发现新版本（AppUpdater.cpp:254 "发现新版本 " + latestVersion）。
const String kUpdateAvailablePrefix = '发现新版本 ';

/// 取消（AppUpdater.cpp:273）。
const String kCancelledStatus = '已取消，可重新检查';

/// 网络失败（AppUpdater.cpp:184）。
const String kNetworkErrorStatus = '检查失败，请检查网络后重试';

/// 普通 403（AppUpdater.cpp:182）。
const String kForbiddenStatus = 'GitHub 拒绝访问更新服务（HTTP 403），请检查代理或查看发布页面';

/// 限流文案（AppUpdater.cpp:156-157）：前缀 + 本地时间 HH:mm:ss + 后缀。
const String kRateLimitPrefix = '当前网络出口的 GitHub 更新检查额度已用尽，请在 ';
const String kRateLimitSuffix = ' 后重试或查看发布页面';

// ---------------------------------------------------------------------------
// selectRelease 错误文案（Qt 逐字，AppUpdater.cpp:106、114、129、135）
// ---------------------------------------------------------------------------

/// 非法 tag / draft / prerelease（AppUpdater.cpp:106）。
const String kInvalidReleaseStatus = '发布版本格式无效，或不是正式版本';

/// 发布页面地址无效（AppUpdater.cpp:114）。
const String kInvalidPageStatus = '发布页面地址无效';

/// 产物信息不完整（AppUpdater.cpp:129）。
const String kIncompleteAssetStatus = '发布产物信息不完整，请查看发布页面';

/// 找不到本平台产物（AppUpdater.cpp:135；Android platform 为空串时必然走到这里）。
const String kNoPlatformAssetStatus = '新版本尚无适合当前架构的更新包，请查看发布页面';

// ---------------------------------------------------------------------------
// 私有工具（零 import：不使用 dart:convert，JSON 由端口解码）
// ---------------------------------------------------------------------------

/// JSON 字符串取值；非字符串一律为空串（等价 QJsonValue::toString）。
String stringOf(Object? value) => value is String ? value : '';

/// JSON 布尔取值；仅 true 为真（等价 QJsonValue::toBool）。
bool boolOf(Object? value) => value is bool && value;

/// JSON 数值取值；非数值为 null（等价 QJsonValue::toDouble 的可用性判断）。
num? numOf(Object? value) => value is num ? value : null;

/// 把 JSON 对象规整为 Map；非对象返回空表。
Map<String, Object?> objectOf(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    final Map<String, Object?> result = <String, Object?>{};
    value.forEach((Object? key, Object? item) {
      if (key is String) {
        result[key] = item;
      }
    });
    return result;
  }
  return const <String, Object?>{};
}

/// 宽松解析前导整数（AppUpdater.cpp:172、173 QString::toLongLong 语义，
/// 且 Qt 完全忽略其 ok 出参：非数字开头一律得 0）。
int leadingInt(String value) {
  var index = 0;
  while (index < value.length) {
    final int unit = value.codeUnitAt(index);
    if (unit == 0x20 || unit == 0x09) {
      index++;
      continue;
    }
    break;
  }
  var sign = 1;
  if (index < value.length) {
    final int unit = value.codeUnitAt(index);
    if (unit == 0x2B || unit == 0x2D) {
      if (unit == 0x2D) {
        sign = -1;
      }
      index++;
    }
  }
  final int start = index;
  while (index < value.length) {
    final int unit = value.codeUnitAt(index);
    if (unit < 0x30 || unit > 0x39) {
      break;
    }
    index++;
  }
  if (index == start) {
    return 0;
  }
  final int? parsed = int.tryParse(value.substring(start, index));
  if (parsed == null) {
    return 0;
  }
  return sign * parsed;
}

/// 两位补零（AppUpdater.cpp:156 "HH:mm:ss"）。
String twoDigits(int value) => value < 10 ? '0' + value.toString() : value.toString();

/// 秒级时间戳 → 本地时间 HH:mm:ss（AppUpdater.cpp:156 fromSecsSinceEpoch + toLocalTime）。
String localClock(int unixSeconds) {
  final DateTime time = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000).toLocal();
  return twoDigits(time.hour) + ':' + twoDigits(time.minute) + ':' + twoDigits(time.second);
}

// ---------------------------------------------------------------------------
// 值类型（零 import，不依赖 dart:io / Flutter）
// ---------------------------------------------------------------------------

/// 解析成功的三段版本号（AppUpdater.cpp:17-35 parseVersion）。
class UpdateVersion {
  const UpdateVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  /// Qt 只接受 segmentCount == 3（AppUpdater.cpp:26-28），本类型恒为 3 段。
  static const int segmentCount = 3;

  /// 等价 QVersionNumber::compare（AppUpdater.cpp:94）。
  int compareTo(UpdateVersion other) {
    if (major != other.major) {
      return major < other.major ? -1 : 1;
    }
    if (minor != other.minor) {
      return minor < other.minor ? -1 : 1;
    }
    if (patch != other.patch) {
      return patch < other.patch ? -1 : 1;
    }
    return 0;
  }

  @override
  bool operator ==(Object other) =>
      other is UpdateVersion && other.major == major && other.minor == minor && other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => major.toString() + '.' + minor.toString() + '.' + patch.toString();
}

/// 重定向策略：Qt 只用 NoLessSafeRedirectPolicy（AppUpdater.cpp:46）。
enum UpdateRedirectPolicy {
  /// 不降级跳转（Qt QNetworkRequest::NoLessSafeRedirectPolicy）。
  noLessSafe,
}

/// 一次 GET 的请求参数（AppUpdater.cpp:43-49 request()）。
class UpdateRequest {
  UpdateRequest({
    required this.url,
    required this.userAgent,
    Map<String, String> headers = const <String, String>{},
  }) : headers = Map<String, String>.unmodifiable(headers);

  final String url;

  /// AppUpdater.cpp:45 "RhineMusicDatabase/" + currentVersion。
  final String userAgent;

  /// 额外请求头（API 回退时 Accept / X-GitHub-Api-Version，AppUpdater.cpp:210-211）。
  final Map<String, String> headers;

  /// AppUpdater.cpp:47。
  static const int transferTimeoutMs = kTransferTimeoutMs;

  /// AppUpdater.cpp:215。
  static const int readBufferBytes = kResponseReadBufferBytes;

  /// AppUpdater.cpp:46。
  static const UpdateRedirectPolicy redirectPolicy = UpdateRedirectPolicy.noLessSafe;
}

/// 一次 GET 的结果（抽象 QNetworkReply 的 attribute/rawHeader/readAll）。
class UpdateHttpResponse {
  const UpdateHttpResponse({
    required this.statusCode,
    this.headers = const <String, String>{},
    this.body = '',
    this.bodyBytes = 0,
    this.json,
    this.jsonParseFailed = false,
    this.networkFailed = false,
  });

  /// HTTP 状态码；无响应（网络失败或被 abort）为 0（AppUpdater.cpp:224）。
  final int statusCode;

  final Map<String, String> headers;

  /// 原始响应体；JSON 解码在端口完成。
  final String body;

  /// 实际收到字节数，用于复现 1 MiB 读缓冲 abort（AppUpdater.cpp:215-220）。
  final int bodyBytes;

  /// 已解码的 JSON 对象；非对象或解析失败为 null。
  final Map<String, Object?>? json;

  /// JSON 解析失败或顶层不是对象（AppUpdater.cpp:240-243）。
  final bool jsonParseFailed;

  /// 传输层错误（QNetworkReply::error() != NoError，AppUpdater.cpp:234）。
  final bool networkFailed;

  /// 头部大小写不敏感取值（Qt rawHeader 语义，AppUpdater.cpp:163-164、173）。
  String headerValue(String name) {
    final String wanted = name.toLowerCase();
    for (final MapEntry<String, String> entry in headers.entries) {
      if (entry.key.toLowerCase() == wanted) {
        return entry.value;
      }
    }
    return '';
  }
}

/// 选中产物的原始信息（AppUpdater.cpp:120-132 直接回传 asset 对象）。
class UpdateReleaseAsset {
  const UpdateReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    required this.state,
    this.json = const <String, Object?>{},
  });

  final String name;
  final String downloadUrl;
  final int size;
  final String state;

  /// 原始 asset JSON。
  final Map<String, Object?> json;
}

/// 选中的正式发布（Qt selectRelease 成功时的 {"version", "page", "asset"}）。
class UpdateReleaseInfo {
  const UpdateReleaseInfo({required this.version, required this.pageUrl, this.asset});

  final String version;
  final String pageUrl;

  /// Android 等 platform 为空串时恒为 null（AppUpdater.cpp:117-136）。
  final UpdateReleaseAsset? asset;
}

/// selectRelease 的三态结果（替代 Qt 的 QString *error 出参 + 空对象返回）。
class UpdateReleaseSelection {
  const UpdateReleaseSelection._(this.release, this.error);

  /// 命中且全部校验通过（AppUpdater.cpp:132）。
  const UpdateReleaseSelection.found(UpdateReleaseInfo release) : this._(release, '');

  /// 不是更新版本，无错误（AppUpdater.cpp:109-111）。
  const UpdateReleaseSelection.empty() : this._(null, '');

  /// 校验失败并带文案（AppUpdater.cpp:106/114/129/135）。
  const UpdateReleaseSelection.failed(String error) : this._(null, error);

  final UpdateReleaseInfo? release;
  final String error;

  bool get isFound => release != null;
  bool get isEmpty => release == null && error.isEmpty;
  bool get isFailed => error.isNotEmpty;
}

// ---------------------------------------------------------------------------
// 宿主注入端口（本层唯一 I/O 出口）
// ---------------------------------------------------------------------------

/// 更新检查依赖的外部能力，全部由宿主注入；本层零 import。
abstract interface class UpdatePorts {
  /// Qt m_offline（AppUpdater.cpp:192-195）。
  bool get offline;

  /// Qt RHINE_RELEASE_BUILD（AppUpdater.cpp:62-68、245）。
  bool get isReleaseBuild;

  /// 当前版本：release 构建为 RHINE_VERSION，否则 RHINE_COMMIT_SHA（AppUpdater.cpp:62-68）。
  String get currentVersion;

  /// 构建标题 RHINE_COMMIT_TITLE（AppUpdater.cpp:69-71）；Qt 侧由设置页显示（NativeHudSettings.cpp:349）。
  String get commitTitle;

  /// 平台产物名；Android 返回空串（AppUpdater.cpp:72-88）。
  /// 空串只表示 selectRelease 跳过产物匹配，check() 仍照常发起请求。
  String get platformAsset;

  /// 本地墙钟秒（Qt QDateTime::currentSecsSinceEpoch）。
  int nowSeconds();

  /// 发起一次 GET（Qt m_network->get，AppUpdater.cpp:213）。
  Future<UpdateHttpResponse> fetch(UpdateRequest request);

  /// 用系统浏览器打开 URL（Qt QDesktopServices::openUrl，AppUpdater.cpp:276）。
  Future<bool> openExternalUrl(String url);

  /// 终止在飞请求（Qt reply->abort()，AppUpdater.cpp:271）。
  void abortInFlight() {}
}

// ---------------------------------------------------------------------------
// UpdateService：Qt AppUpdater 的机器等价物
// ---------------------------------------------------------------------------

/// 更新检查服务；控制流、文案、阈值与 Qt/src/AppUpdater.cpp 一一对应。
///
/// 与 Qt 的差异仅为端口化：网络/时钟/浏览器交给 [UpdatePorts]，
/// 本层只保留判定逻辑、文案选择、退避时间与可观察状态。
class UpdateService {
  UpdateService(this.ports);

  /// 宿主注入的外部能力。
  final UpdatePorts ports;

  String _status = kInitialStatus; // AppUpdater.cpp:36 m_status 初值
  UpdateReleaseInfo? _release; // AppUpdater.cpp:30 m_release
  int _retryAtUnix = 0; // AppUpdater.cpp:37 m_retryAtUnix
  bool _busy = false; // 等价 !m_reply.isNull()（AppUpdater.cpp:139）
  int _generation = 0; // 请求代号：cancel() 后作废迟到响应

  /// 已发出的 GET 次数（清单与 API 回退分别计数，AppUpdater.cpp:213）。
  int httpRequests = 0;

  /// 清单 404 后回退 API 的次数（AppUpdater.cpp:226-229）。
  int manifestFallbackCount = 0;

  /// 响应体超过 1 MiB 被 abort 的次数（AppUpdater.cpp:216-220）。
  int abortCount = 0;

  /// 状态变更通知次数，对应 Qt emit changed()（AppUpdater.cpp:152、259、261）。
  int changedEvents = 0;

  /// 更新可用通知次数，对应 Qt emit updateAvailable()（AppUpdater.h:28、AppUpdater.cpp:255）。
  int updateAvailableEvents = 0;

  // -------------------------------------------------------------------------
  // 静态判定（与 Qt 同名同义；供宿主与测试直接调用）
  // -------------------------------------------------------------------------

  /// AppUpdater.cpp:18 的正则：整串、可选前导 v、无前导零、恰三段。
  static final RegExp versionPattern =
      RegExp(r'^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$');

  /// Qt parseVersion（AppUpdater.cpp:17-35）：整串匹配、去前导 v、恰 3 段、每段 <= 65535。
  static UpdateVersion? parseVersion(String value) {
    final RegExpMatch? match = versionPattern.firstMatch(value);
    if (match == null || match.end != value.length) {
      // :19 capturedLength == value.size —— 必须整串匹配（尾随字符一律非法）。
      return null;
    }
    final List<int> segments = <int>[];
    for (var index = 1; index <= 3; index++) {
      final int? segment = int.tryParse(match.group(index) ?? '');
      if (segment == null || segment > 65535) {
        return null; // :29-33 每段上限 65535
      }
      segments.add(segment);
    }
    return UpdateVersion(segments[0], segments[1], segments[2]); // :26-28 恰 3 段
  }

  /// Qt isNewer(candidate, current)（AppUpdater.cpp:90-95）。
  ///
  /// current 为空串时任意合法候选版本都算更新（:93）。
  static bool isNewer(String candidate, String current) {
    final UpdateVersion? version = parseVersion(candidate);
    if (version == null) {
      return false;
    }
    if (current.isEmpty) {
      return true;
    }
    final UpdateVersion? installed = parseVersion(current);
    if (installed == null) {
      return false;
    }
    return version.compareTo(installed) > 0;
  }

  /// Qt officialUrl（AppUpdater.cpp:37-41）。
  static bool officialUrl(String url, String prefix) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }
    return uri.scheme == 'https' &&
        uri.host == 'github.com' &&
        uri.userInfo.isEmpty &&
        !_hasExplicitPort(url) && // 等价 Qt url.port(-1) == -1
        !uri.hasQuery &&
        !uri.hasFragment &&
        uri.path.startsWith('/' + kUpdateRepository + prefix);
  }

  /// Qt QUrl::port(-1) == -1（AppUpdater.cpp:39）：URL 里不得出现显式端口。
  ///
  /// 不能用 Dart 的 [Uri.hasPort]：Dart 在解析时会丢掉与 scheme 默认值相同的显式端口
  /// （https 的 :443），于是 'https://github.com:443/…' 的 hasPort 为 false，而 Qt 的 QUrl
  /// 会保留该端口、port(-1) 返回 443、officialUrl 直接拒绝。只有回到原始字符串的 authority
  /// 片段判断，才与 Qt 1:1。
  static bool _hasExplicitPort(String url) {
    final int schemeEnd = url.indexOf('://');
    if (schemeEnd < 0) {
      return false;
    }
    final int authorityStart = schemeEnd + 3;
    int authorityEnd = url.length;
    for (int index = authorityStart; index < url.length; index++) {
      final int unit = url.codeUnitAt(index);
      if (unit == 0x2F || unit == 0x3F || unit == 0x23) {
        authorityEnd = index;
        break;
      }
    }
    final String authority = url.substring(authorityStart, authorityEnd);
    final int at = authority.lastIndexOf('@');
    final String hostPort = at < 0 ? authority : authority.substring(at + 1);
    if (hostPort.startsWith('[')) {
      // IPv6 字面量：[::1]:443 —— 端口只能出现在 ']' 之后。
      final int close = hostPort.indexOf(']');
      return close >= 0 && hostPort.indexOf(':', close) >= 0;
    }
    return hostPort.contains(':');
  }

  /// 产物名模板（AppUpdater.cpp:118）：RhineMusicDatabase-<tag>-<platform>。
  static String expectedAssetName(String tag, String platform) =>
      kAssetNamePrefix + tag + '-' + platform;

  /// Qt selectRelease（AppUpdater.cpp:101-137）。
  ///
  /// 四种失败文案与"非更新返回空结果且无错误"的语义逐条对应；
  /// platform 为空串（Android）时跳过产物匹配，并必然落到 :135 的失败分支。
  static UpdateReleaseSelection selectRelease(
    Map<String, Object?> release,
    String platform,
    String current,
  ) {
    final String tag = stringOf(release['tag_name']);
    if (boolOf(release['draft']) || boolOf(release['prerelease']) || parseVersion(tag) == null) {
      return const UpdateReleaseSelection.failed(kInvalidReleaseStatus); // :105-107
    }
    if (!isNewer(tag, current)) {
      return const UpdateReleaseSelection.empty(); // :109-111
    }
    final String pageUrl = stringOf(release['html_url']);
    final Uri? page = Uri.tryParse(pageUrl);
    if (!officialUrl(pageUrl, kReleaseTagPrefix) ||
        page == null ||
        page.path != '/' + kUpdateRepository + kReleaseTagPrefix + tag) {
      return const UpdateReleaseSelection.failed(kInvalidPageStatus); // :112-115
    }
    if (platform.isNotEmpty) {
      final String expectedName = expectedAssetName(tag, platform);
      final Object? assets = release['assets'];
      if (assets is List) {
        for (final Object? value in assets) {
          final Map<String, Object?> asset = objectOf(value);
          if (stringOf(asset['name']) != expectedName) {
            continue; // :121-123
          }
          final String downloadUrl = stringOf(asset['browser_download_url']);
          final Uri? download = Uri.tryParse(downloadUrl);
          final String expectedPath =
              '/' + kUpdateRepository + kReleaseDownloadPrefix + tag + '/' + expectedName;
          final num? size = numOf(asset['size']);
          if (!officialUrl(downloadUrl, kReleaseDownloadPrefix) ||
              download == null ||
              download.path != expectedPath ||
              size == null ||
              size <= 0 ||
              size > kMaxPackageBytes || // :15、:128 2 GiB 上限
              size != size.truncate() || // :128 size != qint64(size) 必须是整数
              stringOf(asset['state']) != 'uploaded') {
            return const UpdateReleaseSelection.failed(kIncompleteAssetStatus); // :127-131
          }
          return UpdateReleaseSelection.found(UpdateReleaseInfo(
            version: tag,
            pageUrl: pageUrl,
            asset: UpdateReleaseAsset(
              name: expectedName,
              downloadUrl: downloadUrl,
              size: size.toInt(),
              state: 'uploaded',
              json: asset,
            ),
          )); // :132
        }
      }
    }
    // :135 platform 为空串（Android）或找不到产物时必然到这里。
    return const UpdateReleaseSelection.failed(kNoPlatformAssetStatus);
  }

  // -------------------------------------------------------------------------
  // 可观察状态（Qt 的 busy()/available()/latestVersion()/status()）
  // -------------------------------------------------------------------------

  /// Qt busy()（AppUpdater.cpp:138-140）：请求在飞期间为真。
  bool get busy => _busy;

  /// Qt available()（AppUpdater.cpp:141-143）：已确认存在可更新版本。
  bool get available => _release != null;

  /// 已选中的正式发布信息；无则 null（Qt m_release 为空）。
  UpdateReleaseInfo? get release => _release;

  /// Qt latestVersion()（AppUpdater.cpp:144-146）。
  String get latestVersion => _release == null ? '' : _release!.version;

  /// Qt status()（AppUpdater.cpp:147-149）。
  String get status => _status;

  /// Qt AppUpdater::commitTitle()（AppUpdater.cpp:69-71）：构建标题，仅供设置页展示。
  String get commitTitle => ports.commitTitle;

  /// 限流退避截止（秒级时间戳），等价 m_retryAtUnix（AppUpdater.cpp:37）。
  int get retryAtUnix => _retryAtUnix;

  /// 限流文案（AppUpdater.cpp:155-158）：前缀 + 本地 HH:mm:ss + 后缀。
  String get rateLimitStatus => kRateLimitPrefix + localClock(_retryAtUnix) + kRateLimitSuffix;

  // -------------------------------------------------------------------------
  // 动作
  // -------------------------------------------------------------------------

  /// Qt check()（AppUpdater.cpp:188-202）。
  Future<void> check() async {
    if (_busy) {
      return; // :189-191
    }
    if (ports.offline) {
      _fail(kOfflineStatus); // :192-195
      return;
    }
    if (ports.nowSeconds() < _retryAtUnix) {
      _fail(rateLimitStatus); // :196-199
      return;
    }
    _status = kCheckingStatus; // :200
    await _fetchRelease(useApi: false); // :201
  }

  /// Qt cancel()（AppUpdater.cpp:264-274）：无在飞请求直接返回，否则作废并改文案。
  void cancel() {
    if (!_busy) {
      return;
    }
    _busy = false;
    _generation++; // 作废迟到响应：Qt 断开连接后回调不再触发（:270）
    ports.abortInFlight(); // :271 等价 reply->abort()
    _fail(kCancelledStatus); // :273
  }

  /// Qt AppUpdater 析构（AppUpdater.cpp:55-61）：让回调失效并终止在飞请求。
  ///
  /// Qt 的 disconnect 对应 _generation 作废；Qt 析构不改状态文案，故这里不调用 _fail。
  void dispose() {
    if (!_busy) {
      return; // :57 if (m_reply)
    }
    _busy = false;
    _generation++; // :58 disconnect(m_reply, nullptr, this, nullptr)
    ports.abortInFlight(); // :59 m_reply->abort()
  }

  /// Qt openRelease()（AppUpdater.cpp:275-277）：交给系统浏览器打开发布页。
  Future<bool> openReleasePage() => ports.openExternalUrl(kReleasePageUrl);

  /// 安装/下载意图 —— 明确等于"交给系统浏览器打开发布页"。
  ///
  /// inAppDownloadOrInstall = false：AppUpdater.cpp:275-277 只调用
  /// QDesktopServices::openUrl(REPO/releases)，Qt 侧没有下载器，也没有安装器；
  /// 产物信息只用于展示"有新版本"，具体下载/安装由用户在浏览器完成。
  Future<bool> installIntent() => openReleasePage();

  // -------------------------------------------------------------------------
  // 内部：Qt fetchRelease（AppUpdater.cpp:204-262）
  // -------------------------------------------------------------------------

  Future<void> _fetchRelease({required bool useApi}) async {
    final int generation = _generation;
    httpRequests++; // :213 m_network->get()
    _busy = true; // :214 m_reply = reply
    final Map<String, String> headers = useApi
        ? <String, String>{
            kApiAcceptHeader: kApiAcceptValue, // :210
            kApiVersionHeader: kApiVersionValue, // :211
          }
        : const <String, String>{};
    // :213 m_network->get() 先发生、:261 emit changed() 在其后：端口调用即等价 get()，
    // 必须先发起请求再通知，changed() 相对请求发起的时序才与 Qt 一致。
    final Future<UpdateHttpResponse> pending = ports.fetch(UpdateRequest(
      url: useApi ? kApiUrl : kManifestUrl, // :205-207
      userAgent: kUserAgentPrefix + ports.currentVersion, // :45
      headers: headers,
    ));
    _notify(); // :261 emit changed()
    final UpdateHttpResponse response = await pending;
    if (generation != _generation) {
      return; // 已被 cancel() 作废，迟到响应不得改动任何状态
    }
    _busy = false; // :222 m_reply.clear()
    final int code = response.statusCode; // :224 HttpStatusCodeAttribute
    final bool oversized = response.bodyBytes > kMaxResponseBytes; // :216-220
    if (oversized) {
      abortCount++;
    }
    if (code == 404 && !useApi) {
      manifestFallbackCount++;
      await _fetchRelease(useApi: true); // :226-229 清单缺失时才回退 REST API
      return;
    }
    if (code == 404) {
      _fail(kNoReleaseStatus); // :230-233
      return;
    }
    // :216-220 的 abort 只让 :234 的 error != NoError 成立，不改变 :226-233 的判定次序：
    // 超大响应按传输错误处理（走 :234-237），但 404 仍先回退。
    if (oversized || response.networkFailed || code != 200) {
      _fail(_responseError(response, code)); // :234-237
      return;
    }
    if (response.jsonParseFailed || response.json == null) {
      _fail(kInvalidDataStatus); // :238-243
      return;
    }
    final String current = ports.isReleaseBuild ? ports.currentVersion : ''; // :245
    final UpdateReleaseSelection selection =
        selectRelease(response.json!, ports.platformAsset, current); // :246
    // :247-248 先替换旧信息再判错：selectRelease 校验失败会清空旧 release，
    // 而上面所有网络/HTTP/解析失败的提前 return 都保留旧 release。
    _release = selection.release;
    if (selection.isFailed) {
      _fail(selection.error); // :249-252
      return;
    }
    if (available) {
      _status = kUpdateAvailablePrefix + latestVersion; // :253-254
      updateAvailableEvents++; // :255 emit updateAvailable()
    } else {
      _status = kUpToDateStatus; // :256-258
    }
    _notify(); // :259 emit changed()
  }

  // -------------------------------------------------------------------------
  // 内部：Qt responseError（AppUpdater.cpp:161-185）
  // -------------------------------------------------------------------------

  String _responseError(UpdateHttpResponse response, int code) {
    final String message = stringOf(response.json?['message']); // :162
    final String retryAfter = response.headerValue(kRetryAfterHeader); // :163
    final bool exhausted = response.headerValue(kRateLimitRemainingHeader) == '0'; // :164
    final bool limited = code == 429 ||
        (code == 403 &&
            (exhausted || retryAfter.isNotEmpty || message.toLowerCase().contains('rate limit')));
    if (!limited) {
      if (code == 403) {
        return kForbiddenStatus; // :181-183 普通 403，不误报为限流
      }
      return kNetworkErrorStatus; // :184
    }
    final int now = ports.nowSeconds(); // :170
    _retryAtUnix = now + kDefaultRetrySeconds; // :171
    final int seconds = leadingInt(retryAfter); // :172
    final int reset = leadingInt(response.headerValue(kRateLimitResetHeader)); // :173
    if (seconds > 0) {
      _retryAtUnix = now + (seconds < kMaxRetryAfterSeconds ? seconds : kMaxRetryAfterSeconds); // :174-175
    } else if (exhausted && reset > now) {
      _retryAtUnix = reset; // :176-178
    }
    return rateLimitStatus; // :179
  }

  /// Qt fail()（AppUpdater.cpp:150-153）：只改文案，不动 release。
  void _fail(String message) {
    _status = message;
    _notify();
  }

  /// 对应 Qt emit changed()（AppUpdater.cpp:152、259、261）。
  void _notify() {
    changedEvents++;
  }
}
