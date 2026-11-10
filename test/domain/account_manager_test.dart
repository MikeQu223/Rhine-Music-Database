/// T24-S05 账号领域测试：逐条对齐 Qt/src/MusicAccount.cpp 与 MusicLibrary.cpp。
///
/// 契约来源（每条断言在注释里给出 Qt 行号）：
/// - 构造/偏好：MusicLibrary.cpp:16-40（kugou-edition/provider 白名单/identityNames/restoreCachedAccount）。
/// - 身份缓存：MusicAccount.cpp:61-72 rememberIdentityName、:94-111 restoreCachedAccount。
/// - 恢复登录：MusicAccount.cpp:139-190 restoreAccount（401/authExpired/netease 301 分支、m_accountError、m_pendingLane）。
/// - 换来源：MusicAccount.cpp:193-297 switchProvider（本地不可用 done(false)、同源同版 done(true)、
///   editionChanged、六个世代、cancelLogin、host->setProvider/setKugouEdition、重置登录展示、restoreAccount）。
/// - 登出：MusicAccount.cpp:670-717 logout（只清当前来源、play-history、account-id 偏好、musicClearRequested）。
///
/// 任务契约禁止执行 flutter/dart test；本文件只编写、不运行，RED/GREEN 均未执行。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/domain/account/account_manager.dart';
import 'package:rhine_music_database/domain/account/login_session.dart';

class _FakeAccountHost implements AccountHostPort {
  _FakeAccountHost({this.authenticated = false, Map<String, String>? prefs})
      : prefs = <String, String>{...?prefs};

  @override
  bool authenticated;

  final Map<String, String> prefs;
  final List<String> calls = <String>[];
  /// Host::hasCredential 的分来源结果（Host.cpp:541-553）。
  final Set<AccountProvider> credentials = <AccountProvider>{};
  AccountProvider? lastProvider;
  KugouEdition? lastEdition;
  int logouts = 0;

  @override
  bool hasCredential(AccountProvider source) {
    calls.add('hasCredential:' + source.wire);
    return credentials.contains(source);
  }

  @override
  String preference(String key) => prefs[key] ?? '';

  @override
  void setPreference(String key, String value) {
    prefs[key] = value;
    calls.add('pref:' + key + '=' + value);
  }

  @override
  void setProvider(AccountProvider provider) {
    lastProvider = provider;
    calls.add('provider:' + provider.wire);
  }

  @override
  void setKugouEdition(KugouEdition edition) {
    lastEdition = edition;
    calls.add('edition:' + edition.wire);
  }

  @override
  void logout() {
    logouts++;
    calls.add('logout');
  }
}

class _FakeAccountTransport implements LoginTransport {
  final List<String> routes = <String>[];
  final List<LoginResult> queued = <LoginResult>[];

  /// request() 的顺序回包（登录域用例驱动 confirmLogin 时需要真实回包）。
  final List<LoginResult> routeResponses = <LoginResult>[];

  /// 非空时 account() 挂起，由测试决定何时回包，用来精确构造"等包期间世代变化"的窗口。
  Completer<LoginResult>? gate;

  @override
  Future<LoginResult> request(String route, Map<String, Object?> parameters, {Set<int>? allowedCodes}) async {
    routes.add(route);
    return routeResponses.isEmpty
        ? const LoginResult.failure('unexpected request')
        : routeResponses.removeAt(0);
  }

  @override
  Future<LoginResult> account({AccountProvider? provider}) async {
    // Qt 的 m_identityApi 只换 provider，不改请求体（MusicAccount.cpp:82-84）。
    routes.add(provider == null ? 'account' : 'account:' + provider.wire);
    final Completer<LoginResult>? pending = gate;
    if (pending != null) {
      gate = null;
      return pending.future;
    }
    return queued.isEmpty ? const LoginResult.failure('no queued response') : queued.removeAt(0);
  }
}

class _IdleScheduler implements LoginScheduler {
  int now = 1700000000000;

  @override
  int nowMs() => now;

  @override
  void schedule(int ms, void Function() callback) {}
}

class _IdleQrRenderer implements QrRenderer {
  @override
  String render(String key) => 'qr';

  @override
  String renderImage(String dataUrl) => 'qr-image';
}

class _IdleCredentials implements CredentialPort {
  @override
  bool hasCredential(AccountProvider source) => false;

  @override
  String saveCredential() => '';

  @override
  void deleteCredential() {}

  @override
  void logoutSource(AccountProvider source, KugouEdition edition) {}
}

/// 记录 AccountEffects 的调用序列：Qt 的顺序就是断言的顺序（宿主必须按此顺序执行）。
class _RecordingEffects extends AccountEffects {
  final List<String> calls = <String>[];

  @override
  void resetLikedState() => calls.add('resetLikedState');

  @override
  void rememberIdentity(AccountProvider provider, String nickname) =>
      calls.add('rememberIdentity:' + provider.wire + ':' + nickname);

  @override
  void refreshQqFeatures() => calls.add('refreshQqFeatures');

  @override
  void loadMore(int lane) => calls.add('loadMore:' + lane.toString());

  @override
  void cancelDiscover() => calls.add('cancelDiscover');

  @override
  void stopPlayback() => calls.add('stopPlayback');

  @override
  void cancelLocal() => calls.add('cancelLocal');

  @override
  void clearPlayHistory() => calls.add('clearPlayHistory');

  @override
  void clearMusic() => calls.add('clearMusic');

  @override
  void clearCapabilities() => calls.add('clearCapabilities');

  @override
  void leaveDirectories() => calls.add('leaveDirectories');

  @override
  void resetLibraryState() => calls.add('resetLibraryState');

  @override
  void resetAccountFlags() => calls.add('resetAccountFlags');

  @override
  void clearLanes() => calls.add('clearLanes');

  @override
  void resetSelection() => calls.add('resetSelection');

  @override
  void reloadSiren() => calls.add('reloadSiren');

  @override
  void loadSirenCatalog() => calls.add('loadSirenCatalog');
}

class _Harness {
  _Harness({
    bool authenticated = false,
    Map<String, String>? prefs,
    bool localMusicAvailable = true,
  }) {
    host = _FakeAccountHost(authenticated: authenticated, prefs: prefs);
    transport = _FakeAccountTransport();
    scheduler = _IdleScheduler();
    qr = _IdleQrRenderer();
    credentials = _IdleCredentials();
    effects = _RecordingEffects();
    session = LoginSession(
      transport: transport,
      scheduler: scheduler,
      qrRenderer: qr,
      credentials: credentials,
      // Qt 里登录流程与账号流程写的是同一份库状态，所以两者共用一个端口实例。
      effects: effects,
    );
    manager = AccountManager(
      host: host,
      transport: transport,
      session: session,
      effects: effects,
      localMusicAvailable: localMusicAvailable,
    );
  }

  late final _FakeAccountHost host;
  late final _FakeAccountTransport transport;
  late final _IdleScheduler scheduler;
  late final _IdleQrRenderer qr;
  late final _IdleCredentials credentials;
  late final _RecordingEffects effects;
  late final LoginSession session;
  late final AccountManager manager;
}

Future<void> pumpMicrotasks() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('bootstrap (MusicLibrary.cpp:16-40)', () {
    test('reads kugou edition, provider and cached identity, then publishes the provider', () {
      final _Harness h = _Harness(
        authenticated: true,
        prefs: <String, String>{
          'kugou-edition': 'lite',
          'provider': 'qq',
          'welcome-name-qq': '小 Q',
          'account-id-qq': '42',
          'welcome-name-kugou-lite': '酷狗君',
        },
      );

      h.manager.bootstrap();

      expect(h.manager.provider, AccountProvider.qq);
      expect(h.manager.edition, KugouEdition.lite);
      expect(h.manager.identityNames['qq'], '小 Q');
      expect(h.manager.identityNames['kugou'], '酷狗君');
      expect(h.manager.uid, '42');
      expect(h.manager.nickname, '小 Q');
      expect(h.host.lastProvider, AccountProvider.qq);
    });

    test('an unknown provider falls back to netease (MusicLibrary.cpp:20-22)', () {
      final _Harness h = _Harness(prefs: <String, String>{'provider': 'bogus'});

      h.manager.bootstrap();

      expect(h.manager.provider, AccountProvider.netease);
      expect(h.host.lastProvider, AccountProvider.netease);
    });

    test('local is refused when the platform has no local music feature (MusicLibrary.cpp:23-25)', () {
      final _Harness h = _Harness(prefs: <String, String>{'provider': 'local'}, localMusicAvailable: false);

      h.manager.bootstrap();

      expect(h.manager.provider, AccountProvider.netease);
    });

    test('publishes the bootstrapped provider to the login panel (MusicLibrary.cpp:31)', () {
      final _Harness h = _Harness(
        authenticated: true,
        prefs: <String, String>{'provider': 'kugou', 'kugou-edition': 'lite'},
      );

      h.manager.bootstrap();

      // Qt:31 api.provider = provider：主 api 与面板的来源随偏好，酷狗版本一起带过去。
      expect(h.session.provider, AccountProvider.kugou);
      expect(h.session.edition, KugouEdition.lite);
      expect(h.manager.accountKey, 'kugou-lite');
    });

    test('a siren provider builds its columns first and loads the catalog last (MusicLibrary.cpp:26-35)', () {
      final _Harness h = _Harness(prefs: <String, String>{'provider': 'siren'});

      h.manager.bootstrap();

      expect(h.manager.provider, AccountProvider.siren);
      expect(h.manager.nickname, '本地收藏');
      expect(h.manager.uid, '');
      // Qt:26-30 在 host->setProvider(:32) 之前，:33-35 的 loadSirenCatalog() 在之后。
      expect(h.effects.calls, <String>['reloadSiren', 'loadSirenCatalog']);
      expect(h.host.calls, <String>['provider:siren']);
    });

    test('local stays local when the platform supports it', () {
      final _Harness h = _Harness(prefs: <String, String>{'provider': 'local'});

      h.manager.bootstrap();

      expect(h.manager.provider, AccountProvider.local);
      expect(h.manager.nickname, '本地音乐');
      expect(h.manager.uid, '');
    });
  });

  group('restoreCachedAccount (MusicAccount.cpp:94-111)', () {
    test('siren shows the local collection name without a uid', () {
      final _Harness h = _Harness(authenticated: true);
      h.manager.provider = AccountProvider.siren;

      h.manager.restoreCachedAccount();

      expect(h.manager.uid, '');
      expect(h.manager.nickname, '本地收藏');
    });

    test('an authenticated account without a cached name shows 正在恢复登录…', () {
      final _Harness h = _Harness(
        authenticated: true,
        prefs: <String, String>{'account-id-kugou-standard': '77'},
      );
      h.manager.provider = AccountProvider.kugou;
      h.manager.edition = KugouEdition.standard;

      h.manager.restoreCachedAccount();

      expect(h.manager.uid, '77');
      expect(h.manager.nickname, '正在恢复登录…');
    });

    test('an unauthenticated host clears the uid and shows 未登录', () {
      final _Harness h = _Harness(prefs: <String, String>{'account-id-qq': '42'});
      h.manager.provider = AccountProvider.qq;
      h.manager.uid = '42';
      h.manager.nickname = '小 Q';

      h.manager.restoreCachedAccount();

      expect(h.manager.uid, '');
      expect(h.manager.nickname, '未登录');
    });
  });

  group('rememberIdentityName (MusicAccount.cpp:61-72)', () {
    test('trims, ignores empty names and writes the welcome name', () {
      final _Harness h = _Harness();
      h.manager.provider = AccountProvider.qq;

      h.manager.rememberIdentityName(AccountProvider.qq, '   ');
      expect(h.manager.identityNames.containsKey('qq'), isFalse);
      expect(h.host.prefs.containsKey('welcome-name-qq'), isFalse);

      h.manager.rememberIdentityName(AccountProvider.qq, '  小 Q  ');
      expect(h.manager.identityNames['qq'], '小 Q');
      expect(h.host.prefs['welcome-name-qq'], '小 Q');
      // uid 为空时不写 account-id（Qt:69-71 的 !uid.isEmpty() 守卫）。
      expect(h.host.prefs.containsKey('account-id-qq'), isFalse);
    });

    test('writes account-id only for the current provider with a uid, keyed by kugou edition', () {
      final _Harness h = _Harness();
      h.manager.provider = AccountProvider.kugou;
      h.manager.edition = KugouEdition.lite;
      h.manager.uid = '99';

      h.manager.rememberIdentityName(AccountProvider.kugou, '酷狗君');

      expect(h.host.prefs['welcome-name-kugou-lite'], '酷狗君');
      expect(h.host.prefs['account-id-kugou-lite'], '99');
      expect(h.manager.identityNames['kugou'], '酷狗君');
    });

    test('a foreign source never writes the current account id (Qt:69)', () {
      final _Harness h = _Harness();
      h.manager.provider = AccountProvider.qq;
      h.manager.uid = '42';

      h.manager.rememberIdentityName(AccountProvider.netease, '网易君');

      expect(h.host.prefs['welcome-name-netease'], '网易君');
      expect(h.host.prefs.containsKey('account-id-netease'), isFalse);
    });
  });

  group('restoreAccount (MusicAccount.cpp:139-190)', () {
    test('local and siren return immediately without any account call', () async {
      final _Harness h = _Harness(authenticated: true);
      h.manager.provider = AccountProvider.local;
      expect(await h.manager.restoreAccount(), isTrue);
      h.manager.provider = AccountProvider.siren;
      expect(await h.manager.restoreAccount(), isTrue);
      expect(h.transport.routes, isEmpty);
      // Qt:140-144 在 :146 之前就返回，本地/塞壬连 refreshQQFeatures() 都不发。
      expect(h.effects.calls, isEmpty);
    });

    test('refreshes qq features before the auth check, but not for local/siren (Qt:139-152)', () async {
      final _Harness h = _Harness();
      h.manager.provider = AccountProvider.qq;

      expect(await h.manager.restoreAccount(), isTrue);
      expect(h.effects.calls, <String>['refreshQqFeatures']);
      expect(h.transport.routes, isEmpty);

      // Qt:140-144 在 :146 之前就返回，本地/塞壬不刷新 QQ 能力。
      h.manager.provider = AccountProvider.local;
      expect(await h.manager.restoreAccount(), isTrue);
      expect(h.effects.calls, <String>['refreshQqFeatures']);
    });

    test('an unauthenticated host returns true without any account call (Qt:147-152)', () async {
      final _Harness h = _Harness();
      h.manager.provider = AccountProvider.qq;

      expect(await h.manager.restoreAccount(), isTrue);
      expect(h.transport.routes, isEmpty);
      expect(h.manager.restoringAccount, isFalse);
    });

    test('a successful restore stores uid/nickname, clears the error and drains the pending lane', () async {
      final _Harness h = _Harness(authenticated: true);
      h.manager.provider = AccountProvider.qq;
      h.manager.pendingLane = 2;
      h.manager.accountError = '旧错误';
      h.transport.queued.add(const LoginResult.ok(<Object?>['uid-9', '九号']));

      expect(await h.manager.restoreAccount(), isTrue);

      expect(h.transport.routes, <String>['account']);
      expect(h.manager.uid, 'uid-9');
      expect(h.manager.nickname, '九号');
      expect(h.manager.accountError, '');
      expect(h.manager.restoringAccount, isFalse);
      expect(h.manager.pendingLane, -1);
      // Qt:164 的 resetLikeState() 只在新 uid 与旧 uid 不同时执行，随后 :182 排空待定列。
      expect(h.effects.calls, <String>['refreshQqFeatures', 'resetLikedState', 'loadMore:2']);
      expect(h.host.prefs['welcome-name-qq'], '九号');
    });

    test('a 401 clears the uid and asks for a new login (Qt:169-174)', () async {
      final _Harness h = _Harness(authenticated: true);
      h.manager.provider = AccountProvider.qq;
      h.manager.uid = 'uid-9';
      h.manager.nickname = '九号';
      h.host.prefs['account-id-qq'] = 'uid-9';
      h.transport.queued.add(const LoginResult.failure('expired', failure: <String, Object?>{'code': 401}));

      expect(await h.manager.restoreAccount(), isFalse);

      expect(h.manager.uid, '');
      expect(h.manager.nickname, '登录已失效');
      expect(h.manager.status, '登录已失效，请重新登录');
      expect(h.manager.accountError, '登录已失效，请重新登录');
      expect(h.host.prefs['account-id-qq'], '');
    });

    test('netease 301 counts as expired, qq 301 does not (Qt:169-170)', () async {
      final _Harness h = _Harness(authenticated: true);
      h.manager.provider = AccountProvider.netease;
      h.transport.queued.add(const LoginResult.failure('expired', failure: <String, Object?>{'code': 301}));
      expect(await h.manager.restoreAccount(), isFalse);
      expect(h.manager.nickname, '登录已失效');

      final _Harness q = _Harness(authenticated: true);
      q.manager.provider = AccountProvider.qq;
      q.manager.uid = 'uid-1';
      q.transport.queued.add(const LoginResult.failure('denied', failure: <String, Object?>{'code': 301}));
      expect(await q.manager.restoreAccount(), isFalse);
      expect(q.manager.uid, 'uid-1');
      expect(q.manager.status, '账号验证暂不可用，已保留本机登录记录');
    });

    test('any other failure keeps the cached login (Qt:175-177)', () async {
      final _Harness h = _Harness(authenticated: true);
      h.manager.provider = AccountProvider.qq;
      h.manager.uid = 'uid-9';
      h.manager.nickname = '九号';
      h.transport.queued.add(const LoginResult.failure('offline', failure: <String, Object?>{'code': 500}));

      expect(await h.manager.restoreAccount(), isFalse);

      expect(h.manager.uid, 'uid-9');
      expect(h.manager.nickname, '九号');
      expect(h.manager.status, '账号验证暂不可用，已保留本机登录记录');
      expect(h.manager.accountError, '账号验证暂不可用，已保留本机登录记录');
      // 失败分支不重置喜欢状态、不排空待定列（Qt:160-177 没有这两步）。
      expect(h.effects.calls, <String>['refreshQqFeatures']);
    });
  });

  group('switchProvider (MusicAccount.cpp:193-297)', () {
    test('an unchanged provider is a no-op success (Qt:202-208)', () async {
      final _Harness h = _Harness();
      h.manager.provider = AccountProvider.qq;

      expect(await h.manager.switchProvider(AccountProvider.qq), isTrue);

      // Qt:202-208 在 :209 之前早退，连库副作用与 restoreAccount 都不触发。
      expect(h.effects.calls, isEmpty);
      expect(h.host.calls, isEmpty);
      expect(h.transport.routes, isEmpty);
    });

    test('local without the platform feature is refused (Qt:193-198)', () async {
      final _Harness h = _Harness(localMusicAvailable: false);

      expect(await h.manager.switchProvider(AccountProvider.local), isFalse);

      expect(h.manager.provider, AccountProvider.netease);
      expect(h.effects.calls, isEmpty);
    });

    test('switching cancels the old login, publishes the provider and resets the library in Qt order', () async {
      final _Harness h = _Harness();
      h.manager.provider = AccountProvider.netease;
      h.session.qrKey = 'key-old';
      h.session.qr = 'qr-old';
      h.session.status = '请用网易云音乐扫描并确认登录';
      h.session.diagnostics = <String, Object?>{'code': 800};
      h.session.method = LoginMethod.phone;

      expect(await h.manager.switchProvider(AccountProvider.qq), isTrue);

      expect(h.session.phase, LoginPhase.idle);
      expect(h.session.qrKey, '');
      expect(h.session.qr, '');
      expect(h.session.status, '');
      expect(h.session.diagnostics, isEmpty);
      expect(h.session.method, LoginMethod.qr);
      expect(h.session.provider, AccountProvider.qq);
      expect(h.host.lastProvider, AccountProvider.qq);
      expect(h.host.prefs['provider'], 'qq');
      expect(h.manager.status, '已切换至QQ 音乐');
      // Qt:216-219 先停旧来源，:233/:235 清账号级标志，:238-278 大重置，:296 再恢复登录。
      expect(h.effects.calls, <String>[
        'cancelDiscover',
        'stopPlayback',
        'cancelLocal',
        'clearMusic',
        'resetAccountFlags',
        'resetLibraryState',
        'refreshQqFeatures',
      ]);
    });

    test('a kugou edition change rewrites the edition preference and its identity (Qt:212-231)', () async {
      final _Harness h = _Harness(prefs: <String, String>{'welcome-name-kugou-lite': '酷狗君'});
      h.manager.provider = AccountProvider.kugou;
      h.manager.edition = KugouEdition.standard;

      expect(await h.manager.switchProvider(AccountProvider.kugou, edition: KugouEdition.lite), isTrue);

      expect(h.manager.edition, KugouEdition.lite);
      expect(h.host.lastEdition, KugouEdition.lite);
      expect(h.host.prefs['kugou-edition'], 'lite');
      expect(h.manager.identityNames['kugou'], '酷狗君');
      expect(h.manager.status, '已切换至酷狗概念版');
    });

    test('siren reloads its collections after the switch (Qt:287-293)', () async {
      final _Harness h = _Harness();

      expect(await h.manager.switchProvider(AccountProvider.siren), isTrue);

      // 塞壬在 restoreAccount(:140-144) 直接返回，所以没有 refreshQqFeatures。
      expect(h.effects.calls, <String>[
        'cancelDiscover',
        'stopPlayback',
        'cancelLocal',
        'clearMusic',
        'resetAccountFlags',
        'resetLibraryState',
        'reloadSiren',
        'loadSirenCatalog',
      ]);
      expect(h.manager.status, '已切换至塞壬唱片');
      expect(h.manager.nickname, '本地收藏');
    });
  });

  group('logout (MusicAccount.cpp:670-717)', () {
    test('local and siren never log out', () {
      final _Harness h = _Harness(authenticated: true);
      h.manager.provider = AccountProvider.local;
      h.manager.logout();
      h.manager.provider = AccountProvider.siren;
      h.manager.logout();

      expect(h.host.logouts, 0);
      expect(h.effects.calls, isEmpty);
    });

    test('clears only the current source and resets the account state', () {
      final _Harness h = _Harness(authenticated: true);
      h.manager.provider = AccountProvider.qq;
      h.manager.uid = 'uid-9';
      h.manager.nickname = '九号';
      h.manager.accountError = '旧错误';
      h.manager.pendingLane = 3;
      h.host.prefs['account-id-qq'] = 'uid-9';
      h.host.prefs['account-id-kugou-standard'] = 'keep-me';
      h.session.qrKey = 'key-old';
      h.session.phase = LoginPhase.waiting;

      h.manager.logout();

      expect(h.host.logouts, 1);
      expect(h.host.prefs['account-id-qq'], '');
      // 其它来源的凭据偏好不动（Host::logout 只清当前来源）。
      expect(h.host.prefs['account-id-kugou-standard'], 'keep-me');
      expect(h.host.prefs['play-history'], '[]');
      expect(h.manager.uid, '');
      expect(h.manager.nickname, '未登录');
      expect(h.manager.accountError, '');
      expect(h.manager.pendingLane, -1);
      expect(h.manager.status, '已退出登录');
      expect(h.session.phase, LoginPhase.idle);
      // 严格按 Qt:675-714 的顺序：能力/播放/历史 → 逐层退出 → 账号标志 → 列 → 清歌单 → 选择。
      expect(h.effects.calls, <String>[
        'clearCapabilities',
        'cancelDiscover',
        'stopPlayback',
        'clearPlayHistory',
        'leaveDirectories',
        'resetAccountFlags',
        'clearLanes',
        'clearMusic',
        'resetSelection',
      ]);
    });
  });

  group('restoreAccount generation guard (MusicAccount.cpp:189)', () {
    test('a stale account reply is dropped and never reports success', () async {
      final _Harness h = _Harness(authenticated: true);
      h.manager.provider = AccountProvider.qq;
      h.transport.queued.add(const LoginResult.ok(<Object?>['uid-9', '九号']));

      final Future<bool?> stale = h.manager.restoreAccount();
      // Qt:211 ++m_accountGeneration 让 :189 的 valid() 判定失败，回调整个被丢弃。
      final Future<bool?> switched = h.manager.switchProvider(AccountProvider.netease);

      expect(await stale, isNull);
      expect(h.manager.uid, isNot('uid-9'));
      expect(h.host.prefs.containsKey('welcome-name-qq'), isFalse);
      await switched;
    });

    test('an unchanged uid keeps the generation and skips the liked reset (Qt:162-165)', () async {
      final _Harness h = _Harness(authenticated: true);
      h.manager.provider = AccountProvider.qq;
      h.manager.uid = 'uid-1';
      h.manager.nickname = '九号';
      final int base = h.manager.accountGeneration;

      h.transport.queued.add(const LoginResult.ok(<Object?>['uid-1', '九号']));
      expect(await h.manager.restoreAccount(), isTrue);

      // MusicAccount.cpp:162-165 的条件不成立：既不 ++m_accountGeneration，也不 resetLikeState()。
      //（confirmLogin 的 :500/:503-505 是另一套条件，不能搬到 restoreAccount 上。）
      expect(h.manager.uid, 'uid-1');
      expect(h.manager.accountGeneration, base);
      expect(h.effects.calls, <String>['refreshQqFeatures']);
    });

    test('a changed uid bumps the generation exactly once and resets the liked state (Qt:162-165)', () async {
      final _Harness h = _Harness(authenticated: true);
      h.manager.provider = AccountProvider.qq;
      final int base = h.manager.accountGeneration;

      h.transport.queued.add(const LoginResult.ok(<Object?>['uid-1', '九号']));
      expect(await h.manager.restoreAccount(), isTrue);
      expect(h.manager.accountGeneration, base + 1);
      expect(h.effects.calls, <String>['refreshQqFeatures', 'resetLikedState']);

      // 同一个 uid 再恢复一次：条件不再成立，世代不动、喜欢状态不再重置。
      h.transport.queued.add(const LoginResult.ok(<Object?>['uid-1', '九号']));
      expect(await h.manager.restoreAccount(), isTrue);
      expect(h.manager.accountGeneration, base + 1);
      // refreshQqFeatures 每次 restoreAccount 都无条件执行（Qt:146），所以它出现两次。
      expect(h.effects.calls, <String>['refreshQqFeatures', 'resetLikedState', 'refreshQqFeatures']);
    });
  });

  group('shared account generation across login and account domains (MusicLibrary.h:234)', () {
    test('a successful confirmLogin invalidates an in-flight restoreAccount reply (Qt:500 vs :189)', () async {
      final _Harness h = _Harness(authenticated: true);
      final Completer<LoginResult> gate = Completer<LoginResult>();
      h.transport.gate = gate;

      final Future<bool?> restoring = h.manager.restoreAccount();
      expect(h.manager.restoringAccount, isTrue);

      // 登录域另起一次成功登录（网易云短信验证码路径）：Qt:500 的 ++m_accountGeneration
      // 会让 :189 的 valid() 失配，旧的恢复回包整个被丢弃。
      h.transport.routeResponses.add(const LoginResult.ok(<Object?>['uid-2', '二号']));
      h.transport.queued.add(const LoginResult.ok(<Object?>['uid-2', '二号']));
      h.session.captchaLogin('13800138000', '123456');
      await pumpMicrotasks();

      gate.complete(const LoginResult.ok(<Object?>['uid-1', '一号']));
      expect(await restoring, isNull);
      // 回包被丢弃：账号域既没有写入旧 uid，也没有把 restoringAccount 放回 false（Qt:159 不执行）。
      expect(h.manager.uid, '');
      expect(h.manager.restoringAccount, isTrue);
      // 登录域自己写的是 session 的那一份。
      expect(h.session.uid, 'uid-2');
      expect(h.session.nickname, '二号');
      // 公开的 accountGeneration 就是 Qt 的单一计数器：本类 0 次推进 + 登录域 1 次。
      expect(h.manager.accountGeneration, 1);
    });

    test('a successful confirmLogin invalidates an in-flight identity reply (Qt:500 vs :91)', () async {
      final _Harness h = _Harness(authenticated: true);
      h.manager.provider = AccountProvider.qq;
      h.host.credentials.add(AccountProvider.netease);
      final Completer<LoginResult> gate = Completer<LoginResult>();
      h.transport.gate = gate;

      final Future<void> identity = h.manager.restoreIdentityName();
      h.transport.routeResponses.add(const LoginResult.ok(<Object?>['uid-2', '二号']));
      h.transport.queued.add(const LoginResult.ok(<Object?>['uid-2', '二号']));
      h.session.captchaLogin('13800138000', '123456');
      await pumpMicrotasks();

      gate.complete(const LoginResult.ok(<Object?>['uid-1', '云村君']));
      await identity;

      expect(h.manager.identityNames.containsKey('netease'), isFalse);
      expect(h.host.prefs.containsKey('welcome-name-netease'), isFalse);
    });
  });

  group('restoreIdentityName (MusicAccount.cpp:74-92)', () {
    test('local and siren never ask for the other source', () async {
      final _Harness h = _Harness();
      h.manager.provider = AccountProvider.local;
      await h.manager.restoreIdentityName();
      h.manager.provider = AccountProvider.siren;
      await h.manager.restoreIdentityName();

      expect(h.transport.routes, isEmpty);
      expect(h.host.calls, isEmpty);
    });

    test('skips a source that already has a cached name (Qt:79)', () async {
      final _Harness h = _Harness();
      h.manager.provider = AccountProvider.qq;
      h.manager.identityNames['netease'] = '云村君';
      h.host.credentials.add(AccountProvider.netease);

      await h.manager.restoreIdentityName();

      expect(h.transport.routes, isEmpty);
    });

    test('skips a source without a credential (Qt:79)', () async {
      final _Harness h = _Harness();
      h.manager.provider = AccountProvider.qq;

      await h.manager.restoreIdentityName();

      expect(h.host.calls, <String>['hasCredential:netease']);
      expect(h.transport.routes, isEmpty);
    });

    test('fetches the flipped source and caches its name (Qt:78-91)', () async {
      final _Harness h = _Harness();
      h.manager.provider = AccountProvider.qq;
      h.host.credentials.add(AccountProvider.netease);
      h.transport.queued.add(const LoginResult.ok(<Object?>['uid-1', '云村君']));

      await h.manager.restoreIdentityName();

      // Qt:82 只换 provider，:84 的请求体仍是 {}，所以路由记在 netease 上而不是当前来源。
      expect(h.transport.routes, <String>['account:netease']);
      expect(h.manager.identityNames['netease'], '云村君');
      expect(h.host.prefs['welcome-name-netease'], '云村君');
      // :69-71 只在 source == provider 时补写 account-id，这里 source 是另一来源。
      expect(h.host.prefs.containsKey('account-id-netease'), isFalse);
      expect(h.manager.uid, '');
    });

    test('drops the reply when the generation moved (Qt:91)', () async {
      final _Harness h = _Harness(authenticated: true);
      h.manager.provider = AccountProvider.qq;
      h.host.credentials.add(AccountProvider.netease);
      final Completer<LoginResult> gate = Completer<LoginResult>();
      h.transport.gate = gate;

      final Future<void> pending = h.manager.restoreIdentityName();
      // Qt:690 的 ++m_accountGeneration 让 :91 的 valid() 判定失败。
      h.manager.logout();
      gate.complete(const LoginResult.ok(<Object?>['uid-1', '云村君']));
      await pending;

      expect(h.manager.identityNames.containsKey('netease'), isFalse);
      expect(h.host.prefs.containsKey('welcome-name-netease'), isFalse);
    });

    test('ignores a failed reply', () async {
      final _Harness h = _Harness();
      h.manager.provider = AccountProvider.qq;
      h.host.credentials.add(AccountProvider.netease);
      h.transport.queued.add(const LoginResult.failure('expired'));

      await h.manager.restoreIdentityName();

      expect(h.transport.routes, <String>['account:netease']);
      expect(h.manager.identityNames.containsKey('netease'), isFalse);
    });
  });
}
