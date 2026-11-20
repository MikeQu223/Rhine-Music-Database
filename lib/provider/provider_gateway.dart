/// 平台数据网关：Flutter 侧所有"平台能力"的唯一出入口。
///
/// 背景（当前进程事实，改动前必须核对）：
/// - Qt 的 `Host`/`MusicApi` 在 Flutter 进程里**确实在跑**（`RhineQtViews.create()` 加载 Qt，
///   `EmbeddedSceneHost.h:68` 的 `Engine *engine()` 是进程级指针），但 Java/Kotlin 侧只暴露
///   `nativePushSceneState`/`PushScenePointer`/`PushSceneWheel` 三个 native 出口，
///   **没有任何通道能让 Dart 调 `api.call(...)`**；
/// - 插件运行时（`NodeRuntimeHost.kt`）`prepare` 恒返回 `arch_blocked`，也没有 MethodChannel；
/// - 因此本接口的实现分两类：
///   * [SirenProviderGateway]：塞壬（内置平台）的真实实现，走 `SirenRepository` 的 HTTP；
///   * [UnavailableProviderGateway]：第三方平台插件的占位实现，**按插件声明的能力返回
///     Qt 同款状态串**，在运行时通道接通前保证"逻辑正确、状态诚实"。
///
/// 契约来源：`MusicBridge/plugins/sdk/port.d.ts` 的 `ProviderAdapter` 方法面、
/// `Qt/src/MusicAccount.cpp` 的登录流程、`Qt/src/CommentsController.cpp` 的分页语义、
/// `Qt/src/MvController.cpp` 的版本/静音跟随语义。改签名先改 port.d.ts。
library;

import '../provider/provider_descriptor.dart';

/// 登录方式（一份 descriptor 的 `login.methods` 投影，便于 UI 直接用）。
class ProviderLoginMethod {
  const ProviderLoginMethod({
    required this.id,
    required this.type,
    required this.label,
    this.phonePattern = '',
    this.codePattern = '',
    this.countryCode = '86',
    this.resendCooldownMs = 60000,
  });

  /// 方法 id（qr / phone / wechat …）。
  final String id;

  /// 类型：`qr` / `sms`。
  final String type;

  /// 按钮文案（插件 manifest 的 `label`）。
  final String label;

  /// 手机号正则（Qt 缺省 `^\d{6,15}$`）。
  final String phonePattern;

  /// 验证码正则（Qt 缺省 `^[0-9]{4,8}$`）。
  final String codePattern;

  /// 国家码。
  final String countryCode;

  /// 重发验证码冷却（毫秒）。
  final int resendCooldownMs;

  /// 从 manifest 的 `login.methods` 条目解析（缺失字段退到 Qt 缺省）。
  static ProviderLoginMethod parse(Map<String, Object?> json, {int fallbackCooldownMs = 60000}) {
    final String type = '${json['type'] ?? 'qr'}';
    return ProviderLoginMethod(
      id: '${json['id'] ?? ''}',
      type: type,
      label: '${json['label'] ?? (type == 'sms' ? '手机号登录' : '扫码登录')}',
      phonePattern: '${json['phonePattern'] ?? ''}',
      codePattern: '${json['codePattern'] ?? ''}',
      countryCode: '${json['countryCode'] ?? '86'}',
      resendCooldownMs: json['resendCooldownMs'] is num
          ? (json['resendCooldownMs'] as num).toInt()
          : fallbackCooldownMs,
    );
  }
}

/// 登录会话（`loginBegin` 的返回，对应 port.d.ts 的 `NativeLoginSession`）。
class ProviderLoginSession {
  const ProviderLoginSession({
    required this.token,
    this.qrText = '',
    this.qrImage = '',
    this.pollIntervalMs = 1000,
  });

  /// 轮询令牌。
  final String token;

  /// 二维码内容（文本形式）。
  final String qrText;

  /// 二维码图片 URL（与 [qrText] 二选一）。
  final String qrImage;

  /// 轮询间隔（毫秒）。
  final int pollIntervalMs;
}

/// 登录轮询结果（`loginPoll` 的返回，对应 port.d.ts 的 `NativeLoginPoll`）。
class ProviderLoginPoll {
  const ProviderLoginPoll({
    this.status = 'waiting',
    this.code = '',
    this.message = '',
    this.accountId = '',
    this.nickname = '',
  });

  /// `waiting` / `scanned` / `confirmed` / `expired`。
  final String status;

  /// 上游错误码（如 `800`/`802`/`803`，或插件自定义键）。
  final String code;

  /// 上游给的提示（缺省空，UI 用自己的文案）。
  final String message;

  /// 登录成功后的账号 id。
  final String accountId;

  /// 登录成功后的昵称。
  final String nickname;
}

/// 一条评论（对应 port.d.ts 的 `CommentItem`，字段裁剪到 UI 真的会用的那些）。
class ProviderComment {
  const ProviderComment({
    required this.id,
    required this.content,
    required this.nickname,
    this.avatarUrl = '',
    this.timeLabel = '',
    this.likedCount = 0,
    this.replyCount = 0,
    this.replyTo = '',
    this.truncated = false,
    this.inlineReplies = const <ProviderComment>[],
    this.inlineMore = false,
  });

  /// 评论 id。
  final String id;

  /// 正文（可能被平台截断，见 [truncated]）。
  final String content;

  /// 昵称。
  final String nickname;

  /// 头像 URL（空则画首字）。
  final String avatarUrl;

  /// 时间文案（平台已格式化的那份）。
  final String timeLabel;

  /// 点赞数。
  final int likedCount;

  /// 回复数。
  final int replyCount;

  /// 被回复者昵称（当前评论是回复时非空）。
  final String replyTo;

  /// 是否被平台截断（UI 显示"展开全文"）。
  final bool truncated;

  /// 随页内联的回复。
  final List<ProviderComment> inlineReplies;

  /// 内联回复是否还有更多。
  final bool inlineMore;
}

/// 一页评论（对应 port.d.ts 的 `CommentsPage`）。
class ProviderCommentPage {
  const ProviderCommentPage({
    required this.comments,
    this.totalCount = 0,
    this.hasMore = false,
    this.cursor = '',
  });

  /// 本页评论。
  final List<ProviderComment> comments;

  /// 总条数（0 表示平台没给）。
  final int totalCount;

  /// 是否还有下一页。
  final bool hasMore;

  /// 游标（部分平台用游标而非页码）。
  final String cursor;
}

/// 评论排序：`hot` / `new`（Qt `comments:sort:hot|new`）。
enum ProviderCommentSort {
  hot('hot', '热门'),
  newest('new', '最新');

  const ProviderCommentSort(this.id, this.label);

  /// 平台参数值。
  final String id;

  /// 中文标签。
  final String label;
}

/// 一页回复。
class ProviderRepliesPage {
  const ProviderRepliesPage({required this.comments, this.hasMore = false, this.timeLabel = ''});

  /// 本页回复。
  final List<ProviderComment> comments;

  /// 是否还有更多。
  final bool hasMore;

  /// 服务器时间（对齐 Qt `time`）。
  final String timeLabel;
}

/// MV 版本（对应 Qt `MvController::versionLabels()` 的来源）。
class ProviderMvVersion {
  const ProviderMvVersion({
    required this.id,
    required this.title,
    this.artist = '',
    this.associated = false,
  });

  /// 版本 id。
  final String id;

  /// 标题。
  final String title;

  /// 艺人。
  final String artist;

  /// 是否是该歌曲的关联 MV（对应 Qt 的 `[歌曲关联]` 前缀）。
  final bool associated;

  /// 列表标签，沿用 Qt `versionLabels()` 的拼法：
  /// `[歌曲关联] `/`[搜索结果] ` + `title · artist · #id`。
  String get label {
    final String prefix = associated ? '[歌曲关联] ' : '[搜索结果] ';
    final StringBuffer buffer = StringBuffer(prefix)..write(title);
    if (artist.isNotEmpty) {
      buffer..write(' · ')..write(artist);
    }
    return (buffer..write(' · #')..write(id)).toString();
  }
}

/// 一首 MV 的播放信息（Qt `mv` 操作的返回）。
class ProviderMvTrack {
  const ProviderMvTrack({
    required this.id,
    required this.title,
    required this.url,
    this.resolution = 0,
  });

  /// MV id。
  final String id;

  /// 标题。
  final String title;

  /// 播放地址（必须 http(s)，Qt 会拒绝其它协议/带 userInfo 的地址）。
  final String url;

  /// 分辨率（像素高度，0 表示未知）。
  final int resolution;
}

/// 账号快照（对应 port.d.ts 的 `account()` 返回）。
class ProviderAccount {
  const ProviderAccount({this.id = '', this.nickname = '', this.vipLevel = 'unknown'});

  /// 账号 id。
  final String id;

  /// 昵称。
  final String nickname;

  /// 会员等级（`unknown`/`none`/`vip`）。
  final String vipLevel;

  /// 是否已登录。
  bool get loggedIn => id.isNotEmpty;
}

/// 平台数据网关。
///
/// 所有实现都必须是**纯 Dart**（不 import flutter），这样 UI 与测试共用一套。
abstract class ProviderGateway {
  /// 平台 id。
  String get providerId;

  /// 平台能力（来自 descriptor/manifest，UI 用它决定按钮显隐）。
  bool capability(String key, {bool fallback = true});

  /// 是否支持某个操作（manifest 的 `operations`）。
  bool operation(String key, {bool fallback = false});

  /// 登录方式列表（扫码/短信等）。
  List<ProviderLoginMethod> get loginMethods;

  /// 当前账号（未登录返回 `id` 为空的对象）。
  Future<ProviderAccount> account();

  /// 开始登录（对应 `loginBegin`）。
  Future<ProviderLoginSession> beginLogin(String method);

  /// 轮询登录状态（对应 `loginPoll`）。
  Future<ProviderLoginPoll> pollLogin(String token);

  /// 取消登录（对应 `loginCancel`）。
  Future<void> cancelLogin();

  /// 发送短信验证码（对应 `loginSms`）。
  Future<void> sendLoginCode(String phone, String method);

  /// 提交短信验证码（对应 `loginSubmit`）。
  Future<void> submitLoginCode(String phone, String code, String method);

  /// 退出登录。
  Future<void> logout();

  /// 读取评论首页（对应 `comments(track, id, sort, page, cursor)`）。
  Future<ProviderCommentPage> comments({
    required String trackId,
    required ProviderCommentSort sort,
    required int page,
    String cursor = '',
  });

  /// 读取某条评论的回复（对应 `commentReplies`）。
  Future<ProviderRepliesPage> replies({required String commentId, required int page});

  /// 查找歌曲关联的 MV 版本（对应 `mvVersions`）。
  Future<List<ProviderMvVersion>> mvVersions({required String trackId});

  /// 取某个版本的播放地址（对应 `mv`）。
  Future<ProviderMvTrack> mv({required String versionId});

  /// 分类检索（对应 `search(query, kind, start)`）。
  Future<List<Map<String, Object?>>> search({
    required String query,
    required ProviderSearchKind kind,
    required int start,
  });

  /// 取曲目播放地址（对应 `playback(value, quality, alternative)`）。
  ///
  /// 三个参数都是位置参数：`value` 是 `{id}`，`quality` 是平台音质 id
  /// （缺省用 descriptor 的 `quality.default`，网易云是 `exhigh`），`alternative`
  /// 是「用替代音源兜底」。只传 `value` 会让插件拼出 `level=undefined`，
  /// 上游直接回「暂无可用音源」——真机上踩过。
  Future<String> playback({
    required String trackId,
    String quality = '',
    bool alternative = false,
  });

  /// 服务端「喜欢的歌曲」id 列表（Qt `MusicLibrary.cpp:969` 的 `likedIDs(uid)`；
  /// 插件侧签名 `likedIDs(uid)`，uid 为空时插件用会话里的账号）。
  ///
  /// 默认实现抛 [ProviderUnavailableError]：只有真正有账号的平台（插件网关）覆盖它，
  /// 塞壬这类没有服务端账号的来源不需要实现，控制器会把异常翻成可见状态串。
  Future<List<String>> likedTrackIds({String uid = ''}) async {
    throw const ProviderUnavailableError('当前来源不支持账号收藏');
  }

  /// 服务端收藏歌单（Qt `userPlaylists(uid)`；插件返回 `items`，`kind` 为 `playlist`）。
  Future<List<Map<String, Object?>>> userPlaylists({String uid = ''}) async {
    throw const ProviderUnavailableError('当前来源不支持账号歌单');
  }

  /// 服务端收藏状态（Qt `likedState(ids)`，返回哪些 id 已喜欢）。
  Future<List<String>> likedState(List<String> trackIds) async {
    throw const ProviderUnavailableError('当前来源不支持账号收藏');
  }

  /// 服务端「喜欢/取消喜欢」（Qt `MusicMutation.cpp:337` 的 `mutate("/like", {id, like})`，
  /// 返回 `state` 为 `subscribed`/`not-subscribed`）。
  Future<bool> setTrackLiked({required String trackId, required bool liked}) async {
    throw const ProviderUnavailableError('当前来源不支持账号收藏');
  }

  /// 按 id 批量取曲目（Qt `MusicLibrary.cpp:947` 的 `songs(ids)`），
  /// 用于把服务端 `likedIDs` 的裸 id 变成可画的曲目行。
  Future<List<Map<String, Object?>>> songsByIds(List<String> ids) async {
    throw const ProviderUnavailableError('当前来源不支持账号收藏');
  }

  /// 读取一个集合（歌单/专辑/歌手）的曲目（Qt `MusicDirectory.cpp:88-150` 的 `detail`，
  /// 插件返回 `[item, songs, ids]`，这里只要 songs）。
  Future<List<Map<String, Object?>>> detailSongs(Map<String, Object?> item) async {
    throw const ProviderUnavailableError('当前来源不支持集合详情');
  }
}

/// 检索分类（`SearchKind` in `port.d.ts`）。
enum ProviderSearchKind {
  /// 歌曲。
  song('song', '歌曲'),

  /// 专辑。
  album('album', '专辑'),

  /// 歌单。
  playlist('playlist', '歌单'),

  /// 歌手。
  artist('artist', '歌手');

  const ProviderSearchKind(this.id, this.label);

  /// 平台参数值。
  final String id;

  /// 中文标签。
  final String label;
}

/// 缺省网关：任何调用都返回"当前来源不支持"的诚实状态。
///
/// 用于第三方平台插件在运行时通道接通前的占位；调用方据 [supported] 决定是走
/// 真网关还是这个占位，所以占位实现**不应被当作成功**（登录/评论/MV 一律报不支持）。
class UnavailableProviderGateway implements ProviderGateway {
  UnavailableProviderGateway(this.descriptor, {this.reason = '当前来源不支持该功能'});

  /// 对应的平台描述符。
  final ProviderDescriptor descriptor;

  /// 拒绝原因（进 UI 状态串）。
  final String reason;

  /// 是否真的不可用（恒 true；调用方无需再判断）。
  bool get supported => false;

  @override
  String get providerId => descriptor.id;

  @override
  bool capability(String key, {bool fallback = true}) => descriptor.capability(key, fallback: fallback);

  @override
  bool operation(String key, {bool fallback = false}) => descriptor.operation(key, fallback: fallback);

  @override
  List<ProviderLoginMethod> get loginMethods => <ProviderLoginMethod>[
        for (final Map<String, Object?> method in descriptor.loginMethods)
          ProviderLoginMethod.parse(method),
      ];

  @override
  Future<ProviderAccount> account() async => const ProviderAccount();

  @override
  Future<ProviderLoginSession> beginLogin(String method) async {
    throw ProviderUnavailableError(reason);
  }

  @override
  Future<ProviderLoginPoll> pollLogin(String token) async => ProviderLoginPoll(status: 'expired', message: reason);

  @override
  Future<void> cancelLogin() async {}

  @override
  Future<void> sendLoginCode(String phone, String method) async {
    throw ProviderUnavailableError(reason);
  }

  @override
  Future<void> submitLoginCode(String phone, String code, String method) async {
    throw ProviderUnavailableError(reason);
  }

  @override
  Future<void> logout() async {}

  @override
  Future<ProviderCommentPage> comments({
    required String trackId,
    required ProviderCommentSort sort,
    required int page,
    String cursor = '',
  }) async {
    throw ProviderUnavailableError(reason);
  }

  @override
  Future<ProviderRepliesPage> replies({required String commentId, required int page}) async {
    throw ProviderUnavailableError(reason);
  }

  @override
  Future<List<ProviderMvVersion>> mvVersions({required String trackId}) async {
    throw ProviderUnavailableError(reason);
  }

  @override
  Future<ProviderMvTrack> mv({required String versionId}) async {
    throw ProviderUnavailableError(reason);
  }

  @override
  Future<List<Map<String, Object?>>> search({
    required String query,
    required ProviderSearchKind kind,
    required int start,
  }) async {
    throw ProviderUnavailableError(reason);
  }

  @override
  Future<String> playback({
    required String trackId,
    String quality = '',
    bool alternative = false,
  }) async {
    throw ProviderUnavailableError(reason);
  }

  @override
  Future<List<String>> likedTrackIds({String uid = ''}) async {
    throw ProviderUnavailableError(reason);
  }

  @override
  Future<List<Map<String, Object?>>> userPlaylists({String uid = ''}) async {
    throw ProviderUnavailableError(reason);
  }

  @override
  Future<List<String>> likedState(List<String> trackIds) async {
    throw ProviderUnavailableError(reason);
  }

  @override
  Future<bool> setTrackLiked({required String trackId, required bool liked}) async {
    throw ProviderUnavailableError(reason);
  }

  @override
  Future<List<Map<String, Object?>>> detailSongs(Map<String, Object?> item) async {
    throw ProviderUnavailableError(reason);
  }

  @override
  Future<List<Map<String, Object?>>> songsByIds(List<String> ids) async {
    throw ProviderUnavailableError(reason);
  }
}

/// 平台功能不可用（UI 直接把 [message] 显示成状态串）。
class ProviderUnavailableError implements Exception {
  const ProviderUnavailableError(this.message);

  /// 可显示的中文原因。
  final String message;

  @override
  String toString() => 'ProviderUnavailableError($message)';
}
