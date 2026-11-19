///  账号领域：来源选择、身份缓存、恢复与登出。
///
/// 契约来源：
/// - Qt/src/MusicLibrary.cpp:16-40 构造（kugou-edition/provider 白名单/identityNames/restoreCachedAccount）、
///   :106-111 providerName、:169-171 accountKey、:173-183 identityName。
/// - Qt/src/MusicAccount.cpp:61-72 rememberIdentityName、:94-111 restoreCachedAccount、
///   :139-190 restoreAccount、:193-297 switchProvider、:670-717 logout。
/// - Qt/src/Host.cpp:541-553 hasCredential、:557-574 setProvider、:579-597 setKugouEdition、:609-662 logout。
///
/// 边界说明（ 宿主接线未裁决）：Qt 的 MusicAccount 就是 MusicLibrary，账号流程会就地改库状态。
/// Flutter 侧把这些副作用收进 AccountEffects 端口（login_session.dart），由宿主在唯一写点执行；
/// 宿主必须给 LoginSession 与 AccountManager 传同一个实现实例，Qt 的调用顺序才成立。
/// Host 能力（凭据是否有效、QSettings 偏好、来源切换、登出落盘）通过 AccountHostPort 注入。
/// 不新增任何传输字段。
///
/// 账号世代（MusicLibrary.h:234 的 m_accountGeneration）在 Qt 只有一份：登录域 confirmLogin
/// 成功时 ++（MusicAccount.cpp:500），账号域的 switchProvider(:211)、logout(:690) 与
/// restoreAccount 的 uid 变化(:163) 也 ++；restoreAccount(:189) 与 restoreIdentityName(:91)
/// 的回调都用 valid(m_accountGeneration, …) 把关。Flutter 侧 LoginSession 与 AccountManager
/// 各自持有计数器，所以本类的守卫把 session.accountGeneration 一起纳入（见 _generation）：
/// confirmLogin 成功同样会作废在途的 restoreAccount/restoreIdentityName 回包。宿主接线只要
/// 传入同一个 session 实例即可，不需要额外端口。
///
/// 通知模型：Qt 在各处发 changed()；这里不发明通知端口，状态是拉取式（读字段），
/// 由  宿主接线决定何时刷新。登录面板自身的通知仍走 LoginSession.addListener。
library;

import 'login_session.dart';

/// Qt Host 的账号面端口（Host.cpp:541-662）。生产实现由  接线提供。
abstract class AccountHostPort {
  /// Host::authenticated()：Host.cpp:538-540，等价 hasCredential(provider)。
  bool get authenticated;

  /// Host::hasCredential()：Host.cpp:541-553。MusicAccount.cpp:79 用它判断另一来源是否值得恢复身份名。
  bool hasCredential(AccountProvider source);

  /// Host::preference()：QSettings 读取（MusicLibrary.cpp:18-33）。
  String preference(String key);

  /// Host::setPreference()：QSettings 写入。
  void setPreference(String key, String value);

  /// Host::setProvider()：Host.cpp:557-574。
  void setProvider(AccountProvider provider);

  /// Host::setKugouEdition()：Host.cpp:579-597。
  void setKugouEdition(KugouEdition edition);

  /// Host::logout()：Host.cpp:609-662（按来源删凭据并落盘）。
  void logout();
}

/// 账号领域状态机（Qt MusicAccount 的账号部分）。
class AccountManager {
  AccountManager({
    required this.host,
    required this.transport,
    this.session,
    this.effects = const AccountEffects(),
    this.localMusicAvailable = true,
  });

  final AccountHostPort host;
  final LoginTransport transport;
  final LoginSession? session;

  /// 库级副作用端口；必须与 session.effects 是同一实例（Qt 里两者都是 MusicLibrary）。
  final AccountEffects effects;

  /// PlatformFeatures::LocalMusic（MusicLibrary.cpp:23-25；本地库构造另见 :41）； 架构未裁决，先由宿主传入。
  final bool localMusicAvailable;

  AccountProvider provider = AccountProvider.netease;
  KugouEdition edition = KugouEdition.standard;
  String uid = '';
  String nickname = '未登录';

  /// 库级 status（MusicLibrary.h:160），与 LoginSession.status（loginStatus）不同字段。
  String status = '';

  bool restoringAccount = false;
  String accountError = '';
  int pendingLane = -1;

  /// Qt identityNames：键为 netease/qq/kugou，酷狗槽位随 edition 换值（MusicAccount.cpp:225；
  /// 构造期由 MusicLibrary.cpp:36-39 从 welcome-name-* 读入）。
  final Map<String, String> identityNames = <String, String>{};

  int _accountGeneration = 0;

  /// Qt 的单一 m_accountGeneration：本类的推进量加上 LoginSession 的推进量。
  /// 两者都只增不减，所以任一侧 ++ 都会让快照失配（MusicAccount.cpp:189、:91 是等值判定）。
  int get _generation => _accountGeneration + (session?.accountGeneration ?? 0);

  /// 对应 MusicLibrary.h:103 accountGeneration()。
  int get accountGeneration => _generation;

  bool get isLocal => provider == AccountProvider.local;
  bool get isSiren => provider == AccountProvider.siren;

  /// MusicLibrary.cpp:106-111。
  String get providerName => accountProviderName(provider, edition);

  /// MusicLibrary.cpp:169-171（实现复用 login_session.dart 的 accountKeyOf）。
  String get accountKey => accountKeyOf(provider, edition);

  /// MusicLibrary.cpp:173-183：塞壬返回空；否则按 netease/qq/kugou 顺序取第一个非空身份名。
  String get identityName {
    if (isSiren) {
      return '';
    }
    for (final String source in const <String>['netease', 'qq', 'kugou']) {
      final String name = identityNames[source] ?? '';
      if (name.isNotEmpty) {
        return name;
      }
    }
    return '';
  }

  /// MusicLibrary.cpp:16-40：读取偏好、按白名单定来源、恢复身份名与缓存账号。
  void bootstrap() {
    edition = host.preference('kugou-edition') == 'lite' ? KugouEdition.lite : KugouEdition.standard;
    AccountProvider selected = AccountProvider.netease;
    final String stored = host.preference('provider');
    for (final AccountProvider candidate in AccountProvider.values) {
      if (candidate.wire == stored) {
        selected = candidate;
      }
    }
    if (selected == AccountProvider.local && !localMusicAvailable) {
      selected = AccountProvider.netease;
    }
    provider = selected;
    identityNames['netease'] = host.preference('welcome-name-netease');
    identityNames['qq'] = host.preference('welcome-name-qq');
    identityNames['kugou'] = host.preference('welcome-name-kugou-${edition.wire}');
    if (isSiren) {
      // MusicLibrary.cpp:26-30：塞壬的列头与 LocalCollections 在发布来源之前建立。
      effects.reloadSiren();
    }
    if (session != null) {
      // MusicLibrary.cpp:31 api.provider = provider：主 api 开机即用偏好来源。
      session!.provider = provider;
      session!.edition = edition;
    }
    host.setProvider(provider);
    if (isSiren) {
      // MusicLibrary.cpp:33-35：塞壬开机拉目录。
      effects.loadSirenCatalog();
    }
    restoreCachedAccount();
  }

  /// MusicAccount.cpp:94-111。
  void restoreCachedAccount() {
    if (isLocal) {
      uid = '';
      nickname = '本地音乐';
      return;
    }
    if (isSiren) {
      uid = '';
      nickname = '本地收藏';
      return;
    }
    final bool authenticated = host.authenticated;
    uid = authenticated ? host.preference('account-id-$accountKey') : '';
    nickname = authenticated ? (identityNames[provider.wire] ?? '') : '未登录';
    if (authenticated && nickname.isEmpty) {
      nickname = '正在恢复登录…';
    }
  }

  /// MusicAccount.cpp:61-72。
  void rememberIdentityName(AccountProvider source, String name) {
    final String normalized = name.trim();
    if (normalized.isEmpty) {
      return;
    }
    identityNames[source.wire] = normalized;
    final String key = source == AccountProvider.kugou ? accountKey : source.wire;
    host.setPreference('welcome-name-$key', normalized);
    if (source == provider && uid.isNotEmpty) {
      host.setPreference('account-id-$key', uid);
    }
  }

  /// MusicAccount.cpp:74-92：启动时补全**另一个**来源的缓存身份名。
  ///
  /// Qt 用独立的 m_identityApi：:82 把它的 provider 指向另一来源，:83-91 仍 call("account", {})，
  /// 主 api 的来源不受影响。这里对应 transport.account(provider: source)。
  /// 守卫：本地/塞壬直接返回（:75-77）；已有身份名或无凭据则不请求（:79-81）；
  /// 回调由 valid(m_accountGeneration, &m_accountGeneration) 把关（:91），只做等值比较，
  /// 且该计数器与登录域共用（confirmLogin 的 :500 ++ 也会让它失配）。
  Future<void> restoreIdentityName() async {
    if (isLocal || isSiren) {
      return;
    }
    final AccountProvider source =
        provider == AccountProvider.netease ? AccountProvider.qq : AccountProvider.netease;
    if ((identityNames[source.wire] ?? '').isNotEmpty || !host.hasCredential(source)) {
      return;
    }
    final int token = _generation;
    final LoginResult result = await transport.account(provider: source);
    if (token != _generation) {
      return;
    }
    if (!result.ok) {
      return;
    }
    final List<Object?> values = result.list;
    rememberIdentityName(source, values.length > 1 ? _text(values[1]) : '');
  }

  /// MusicAccount.cpp:139-190。
  ///
  /// 返回值对应 Qt 的 done(bool)；null 表示 Qt:189 的 valid() 守卫把整个回调丢弃了
  /// （世代已变），调用方不得把 null 当成失败。
  Future<bool?> restoreAccount() async {
    if (isLocal || isSiren) {
      return true;
    }
    // MusicAccount.cpp:146：refreshQQFeatures() 在凭据检查之前无条件执行。
    effects.refreshQqFeatures();
    if (!host.authenticated) {
      return true;
    }
    restoringAccount = true;
    accountError = '';
    final int token = _generation;
    final LoginResult result = await transport.account();
    // Qt:189 valid(m_accountGeneration, &m_accountGeneration)：只做等值比较，不递增；
    // 回调被丢弃时 restoringAccount 保持 true（:159 不执行）。
    if (token != _generation) {
      return null;
    }
    restoringAccount = false;
    if (result.ok) {
      final List<Object?> values = result.list;
      final String nextUid = values.isNotEmpty ? _text(values[0]) : '';
      final String nextNickname = values.length > 1 ? _text(values[1]) : '';
      // MusicAccount.cpp:162-165：只有新 uid 与旧 uid 不同时，才 ++m_accountGeneration 并
      // resetLikeState()——两者同一个条件。注意这不是 confirmLogin 的语义
      //（:500 无条件 ++、:503-505 才按 uid 条件 reset），两个函数不可互相套用。
      if (uid != nextUid) {
        _accountGeneration++;
        effects.resetLikedState();
      }
      uid = nextUid;
      nickname = nextNickname;
      rememberIdentityName(provider, nickname);
    } else {
      final Map<String, Object?> failure = result.failure;
      final int code = _intOrNull(failure['code']) ?? 0;
      final bool expired = code == 401 ||
          failure['authExpired'] == true ||
          (provider == AccountProvider.netease && code == 301);
      if (expired) {
        uid = '';
        nickname = '登录已失效';
        host.setPreference('account-id-$accountKey', '');
        status = '登录已失效，请重新登录';
      } else {
        status = '账号验证暂不可用，已保留本机登录记录';
      }
    }
    accountError = result.ok ? '' : status;
    final int pending = pendingLane;
    pendingLane = -1;
    if (result.ok && pending > 0) {
      effects.loadMore(pending);
    }
    return result.ok;
  }

  /// MusicAccount.cpp:193-297。返回 Qt 的 done(bool)，null 语义同 restoreAccount。
  Future<bool?> switchProvider(AccountProvider source, {KugouEdition? edition}) async {
    if (source == AccountProvider.local && !localMusicAvailable) {
      return false;
    }
    final KugouEdition? requested = edition;
    final bool editionChanged =
        source == AccountProvider.kugou && requested != null && requested != this.edition;
    if (source == provider && !editionChanged) {
      return true;
    }
    session?.cancelLogin();
    _accountGeneration++;
    effects.cancelDiscover();
    effects.stopPlayback();
    effects.cancelLocal();
    effects.clearMusic();
    provider = source;
    // MusicAccount.cpp:221-226：先落 edition（host + 偏好），再按新 accountKey 读身份名。
    if (source == AccountProvider.kugou && requested != null && requested != this.edition) {
      this.edition = requested;
      host.setKugouEdition(requested);
      host.setPreference('kugou-edition', requested.wire);
      identityNames['kugou'] = host.preference('welcome-name-$accountKey');
    }
    host.setProvider(source);
    host.setPreference('provider', source.wire);
    if (session != null) {
      // MusicAccount.cpp:229 api.provider = source：登录面板随之换来源。
      session!.provider = source;
      session!.edition = this.edition;
    }
    restoreCachedAccount();
    restoringAccount = false;
    pendingLane = -1;
    effects.resetAccountFlags();
    accountError = '';
    if (session != null) {
      // MusicAccount.cpp:236-237 loginStatus.clear()、loginDiagnostics = {}。
      session!.status = '';
      session!.diagnostics = <String, Object?>{};
    }
    effects.resetLibraryState();
    if (session != null) {
      // MusicAccount.cpp:279 loginMethod = "qr"。
      session!.method = LoginMethod.qr;
    }
    if (isSiren) {
      effects.reloadSiren();
      effects.loadSirenCatalog();
    }
    status = '已切换至$providerName';
    return restoreAccount();
  }

  /// MusicAccount.cpp:670-717：只清当前来源，其它来源凭据保留。
  void logout() {
    if (isLocal || isSiren) {
      return;
    }
    effects.clearCapabilities();
    effects.cancelDiscover();
    effects.stopPlayback();
    effects.clearPlayHistory();
    host.setPreference('play-history', '[]');
    effects.leaveDirectories();
    session?.cancelLogin();
    _accountGeneration++;
    restoringAccount = false;
    pendingLane = -1;
    effects.resetAccountFlags();
    accountError = '';
    host.logout();
    host.setPreference('account-id-$accountKey', '');
    uid = '';
    nickname = '未登录';
    effects.clearLanes();
    effects.clearMusic();
    effects.resetSelection();
    status = '已退出登录';
    // Qt 的 uid/nickname 只有一份（MusicLibrary）；这里两份实现必须同步，避免恢复后分叉。
    // loginStatus 在 Qt logout 里不被改写，故不动 session.status。
    if (session != null) {
      session!.uid = '';
      session!.nickname = '未登录';
    }
  }
}

String _text(Object? value) {
  if (value == null) {
    return '';
  }
  return value.toString();
}

int? _intOrNull(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}
