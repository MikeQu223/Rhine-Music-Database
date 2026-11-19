/// MV 状态机的单测：逐条对照 `Qt/src/MvController.cpp`。
///
/// 真值行号：:561-598（refresh 的三段基础状态串与 supported 判定）、:636-671
/// （resolveVideo 的四段状态串）、:474-495（版本选择落偏好）、:677-702（sync 阈值）。
/// 纯 Dart：假网关只实现被调到的方法，越界调用会直接抛 UnimplementedError。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/domain/mv/mv_controller.dart';
import 'package:rhine_music_database/domain/mv/mv_track_validator.dart';
import 'package:rhine_music_database/domain/player/music_player.dart' show PreferencePort;
import 'package:rhine_music_database/provider/provider_gateway.dart';

/// 内存偏好（Qt `Host::preference` 的等价物：缺键读空串、写即存）。
class _MemoryPreferences implements PreferencePort {
  _MemoryPreferences([Map<String, String>? seed])
      : values = <String, String>{...?seed};

  final Map<String, String> values;
  final List<String> writes = <String>[];

  @override
  String read(String key) => values[key] ?? '';

  @override
  void write(String key, String value) {
    writes.add(key);
    values[key] = value;
  }
}

/// 单调时钟桩：只有显式 [advance] 才走字。
class _FakeClock {
  DateTime now = DateTime.utc(2026, 11, 20, 4, 0, 0);

  DateTime call() => now;

  void advance(int milliseconds) => now = now.add(Duration(milliseconds: milliseconds));
}

class _FakeGateway implements ProviderGateway {
  _FakeGateway({
    this.versions = const <ProviderMvVersion>[],
    this.track = const ProviderMvTrack(id: 'mv1', title: 'MV', url: 'https://e.com/v.mp4', resolution: 720),
    this.mvError,
    this.versionsError,
  });

  List<ProviderMvVersion> versions;
  ProviderMvTrack track;
  String? mvError;
  String? versionsError;

  final List<String> mvVersionIds = <String>[];
  final List<String> versionTrackIds = <String>[];
  int mvCalls = 0;
  int versionsCalls = 0;

  @override
  String get providerId => 'fake';

  @override
  bool capability(String key, {bool fallback = true}) => throw UnimplementedError();

  @override
  bool operation(String key, {bool fallback = false}) => throw UnimplementedError();

  @override
  List<ProviderLoginMethod> get loginMethods => throw UnimplementedError();

  @override
  Future<ProviderAccount> account() => throw UnimplementedError();

  @override
  Future<ProviderLoginSession> beginLogin(String method) => throw UnimplementedError();

  @override
  Future<ProviderLoginPoll> pollLogin(String token) => throw UnimplementedError();

  @override
  Future<void> cancelLogin() => throw UnimplementedError();

  @override
  Future<void> sendLoginCode(String phone, String method) => throw UnimplementedError();

  @override
  Future<void> submitLoginCode(String phone, String code, String method) =>
      throw UnimplementedError();

  @override
  Future<void> logout() => throw UnimplementedError();

  @override
  Future<ProviderCommentPage> comments({
    required String trackId,
    required ProviderCommentSort sort,
    required int page,
    String cursor = '',
  }) => throw UnimplementedError();

  @override
  Future<ProviderRepliesPage> replies({required String commentId, required int page}) =>
      throw UnimplementedError();

  @override
  Future<List<ProviderMvVersion>> mvVersions({required String trackId}) async {
    versionsCalls++;
    versionTrackIds.add(trackId);
    if (versionsError != null) {
      throw ProviderUnavailableError(versionsError!);
    }
    return versions;
  }

  @override
  Future<ProviderMvTrack> mv({required String versionId}) async {
    mvCalls++;
    mvVersionIds.add(versionId);
    if (mvError != null) {
      throw ProviderUnavailableError(mvError!);
    }
    return track;
  }

  @override
  Future<List<Map<String, Object?>>> search({
    required String query,
    required ProviderSearchKind kind,
    required int start,
  }) => throw UnimplementedError();
}

void main() {
  test('来源不支持时落 unsupported 并给出拒绝串，且不发任何请求（:589-598）', () async {
    final _FakeGateway gateway = _FakeGateway();
    final MvController controller = MvController(preferences: _MemoryPreferences());
    await controller.attach(gateway, providerSupportsMv: false, providerSupportsMvVersions: false);
    await controller.refresh(trackId: 't1');

    expect(controller.state.phase, MvPhase.unsupported);
    expect(controller.state.status, mvUnsupportedStatus);
    expect(controller.supported, isFalse);
    expect(gateway.mvCalls, 0);
    expect(gateway.versionsCalls, 0);
  });

  test('没有播放曲目时是 idle 串（:590）', () async {
    final MvController controller = MvController(preferences: _MemoryPreferences());
    await controller.attach(_FakeGateway(), providerSupportsMv: true, providerSupportsMvVersions: true);
    await controller.refresh(trackId: '');

    expect(controller.state.phase, MvPhase.idle);
    expect(controller.state.status, mvIdleStatus);
    expect(controller.state.trackId, '');
  });

  test('查找中先给「正在查找歌曲关联 MV…」再给「正在加载视频版本…」（:600-638）', () async {
    final _FakeGateway gateway = _FakeGateway(
      versions: const <ProviderMvVersion>[
        ProviderMvVersion(id: 'mv1', title: '官方 MV', associated: true),
      ],
    );
    final List<String> seen = <String>[];
    final MvController controller = MvController(
      preferences: _MemoryPreferences(),
      onChanged: (MvState state) => seen.add(state.status),
    );
    await controller.attach(gateway, providerSupportsMv: true, providerSupportsMvVersions: true);
    await controller.refresh(trackId: 't1');

    expect(seen.first, '正在查找关联 MV…');
    expect(seen, contains('正在查找歌曲关联 MV…'));
    expect(seen, contains('正在加载视频版本…'));
    expect(seen.last, '静音跟随音乐 · 720p');
    expect(controller.state.phase, MvPhase.playing);
    // 没有选中版本时网关收到曲目 id（本侧契约的默认版本口径）。
    expect(gateway.mvVersionIds.single, 't1');
    expect(gateway.versionTrackIds.single, 't1');
  });

  test('本曲没有关联 MV 但有版本列表时落 versions 串（:654-655）', () async {
    final _FakeGateway gateway = _FakeGateway(
      track: const ProviderMvTrack(id: '', title: '', url: ''),
      versions: const <ProviderMvVersion>[
        ProviderMvVersion(id: 'other', title: '翻唱', artist: '某人'),
        ProviderMvVersion(id: 'live', title: '现场版'),
      ],
    );
    final MvController controller = MvController(preferences: _MemoryPreferences());
    await controller.attach(gateway, providerSupportsMv: true, providerSupportsMvVersions: true);
    await controller.refresh(trackId: 't2');

    expect(controller.state.phase, MvPhase.versions);
    expect(controller.state.status, '此歌曲没有关联 MV，可手动选择视频版本');
    expect(controller.versions.length, 2);
    expect(controller.versions.first.label, '[搜索结果] 翻唱 · 某人 · #other');
    // 首项不是「歌曲关联」⇒ Qt :619-623 会拿首项再解析一次。
    expect(gateway.mvVersionIds, <String>['t2', 'other']);
  });

  test('网关报错时状态串是「MV 加载失败：<原因>」（:648-649）', () async {
    final _FakeGateway gateway = _FakeGateway(mvError: '通道未接通');
    final MvController controller = MvController(preferences: _MemoryPreferences());
    await controller.attach(gateway, providerSupportsMv: true, providerSupportsMvVersions: true);
    await controller.refresh(trackId: 't3');

    expect(controller.state.phase, MvPhase.failed);
    expect(controller.state.status, 'MV 加载失败：通道未接通');
    expect(controller.state.track, isNull);
  });

  test('地址校验三种非法 + 一种合法（:655-658）', () {
    final MvController controller = MvController(preferences: _MemoryPreferences());
    expect(controller.validUrl('https://e.com/v.mp4'), isTrue);
    // 1. 非 http(s)
    expect(controller.validUrl('ftp://e.com/v.mp4'), isFalse);
    // 2. host 为空
    expect(controller.validUrl('https:///v.mp4'), isFalse);
    // 3. 带 userInfo
    expect(controller.validUrl('https://user:pass@e.com/v.mp4'), isFalse);
    expect(controller.validUrl('https://e.com/v.mp4'), isTrue, reason: '合法地址仍合法');
  });

  test('版本选择落 mv-versions 偏好，并记住选择（:474-495）', () async {
    final _MemoryPreferences preferences = _MemoryPreferences();
    final _FakeGateway gateway = _FakeGateway(
      versions: const <ProviderMvVersion>[
        ProviderMvVersion(id: 'live', title: '现场版', artist: '某人'),
      ],
    );
    final MvController controller = MvController(preferences: preferences);
    await controller.attach(gateway, providerSupportsMv: true, providerSupportsMvVersions: true);
    await controller.refresh(trackId: 't4');
    await controller.selectVersion('live');

    expect(controller.state.selectedVersionId, 'live');
    expect(preferences.values[mvVersionsPreferenceKey], contains('fake:t4'));
    expect(preferences.writes.last, mvVersionsPreferenceKey);
    // 重新解析用的是选中的版本 id。
    expect(gateway.mvVersionIds.last, 'live');

    // 新实例（= 下次启动）能读回这条选择。
    final MvController restarted =
        MvController(preferences: _MemoryPreferences(preferences.values));
    await restarted.attach(gateway, providerSupportsMv: true, providerSupportsMvVersions: true);
    await restarted.refresh(trackId: 't4');
    expect(restarted.state.selectedVersionId, 'live');
    expect(gateway.mvVersionIds.last, 'live');
  });

  test('syncToMusic 播放中阈值 400（:691）', () async {
    final MvController controller = await _playing();
    // 视频刚解析出来时对齐在 0，音乐也还在 0：不需要 seek。
    expect(controller.syncToMusic(0, playing: true), isFalse);
    // 偏差正好 400：Qt 是严格大于，所以不 seek。
    expect(controller.syncToMusic(400, playing: true), isFalse);
    expect(controller.videoPositionMs, 0);
    // 401：seek，并把视频目标记为 401。
    expect(controller.syncToMusic(401, playing: true), isTrue);
    expect(controller.videoPositionMs, 401);
    // 回来时偏差又正好 400：不 seek；再回 1ms 才 seek。
    expect(controller.syncToMusic(1, playing: true), isFalse);
    expect(controller.syncToMusic(0, playing: true), isTrue);
  });

  test('syncToMusic 暂停时阈值 100（:691）', () async {
    final MvController controller = await _playing();
    expect(controller.syncToMusic(0, playing: false), isFalse);
    expect(controller.syncToMusic(100, playing: false), isFalse, reason: '100 不严格大于 100');
    expect(controller.videoPositionMs, 0);
    expect(controller.syncToMusic(101, playing: false), isTrue);
    expect(controller.videoPositionMs, 101);
    expect(controller.syncToMusic(1, playing: false), isFalse, reason: '偏差回到 100');
    expect(controller.syncToMusic(0, playing: false), isTrue);
  });

  test('静音跟随音乐 · 720p 与 resolution/静音字段（:664）', () async {
    final MvController controller = await _playing(clock: _FakeClock());
    expect(controller.state.status, '静音跟随音乐 · 720p');
    expect(controller.state.resolution, 720);
    expect(controller.state.muted, isTrue, reason: 'Qt 刻意不建 QAudioOutput');
    expect(controller.state.rendered, isFalse, reason: 'Android 侧没有解码器');
    expect(controller.state.track?.id, 'mv1');
  });

  test('自动查找关掉时不动网关（Qt setEnabled → refresh(true) 的前置）', () async {
    final _FakeGateway gateway = _FakeGateway();
    final MvController controller =
        MvController(preferences: _MemoryPreferences(<String, String>{mvAutoPreferenceKey: 'off'}));
    await controller.attach(gateway, providerSupportsMv: true, providerSupportsMvVersions: true);
    await controller.refresh(trackId: 't5');

    expect(controller.auto, isFalse);
    expect(controller.state.status, '正在查找关联 MV…', reason: '基础串仍是"正在查找"（:591）');
    expect(gateway.mvCalls, 0, reason: '不自动查找就不发请求（:595）');
  });
}

/// 造一个已经进入 playing 的控制器；[clock] 由调用方给，便于量 seek 阈值。
Future<MvController> _playing({_FakeClock? clock}) async {
  final _FakeClock fake = clock ?? _FakeClock();
  final _FakeGateway gateway = _FakeGateway(
    versions: const <ProviderMvVersion>[
      ProviderMvVersion(id: 'mv1', title: '官方 MV', associated: true),
    ],
  );
  final MvController controller = MvController(
    preferences: _MemoryPreferences(),
    clock: fake.call,
  );
  await controller.attach(gateway, providerSupportsMv: true, providerSupportsMvVersions: true);
  await controller.refresh(trackId: 't1');
  return controller;
}
