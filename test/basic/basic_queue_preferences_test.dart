/// 播放器窄偏好的同步桥（`BasicPlayerPreferences`）与模式回填（`MusicPlayer.resyncPreferences`）。
///
/// 真值（Qt/src/MusicPlayer.cpp:643-651 / :749-780）：模式只有白名单
/// `{off, all, one, shuffle}` 能进状态；Qt 的 mode 只经 `sessionState` 持久化，
/// Flutter 侧补一条独立的 `play-mode` 偏好键（`kPlayModePreference`），
/// 落在与设置页同一个 `panel/` 键空间里（Qt/src/Host.cpp:1075）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_player_preferences.dart';
import 'package:rhine_music_database/basic/basic_settings_store.dart';
import 'package:rhine_music_database/domain/player/music_player.dart' as player;

/// [player.MediaHostPort] 的最小替身：本组测试不需要真实传输。
class _Media implements player.MediaHostPort {
  final List<String> calls = <String>[];

  @override
  void mediaControl(String action, [double value = 0]) => calls.add(action);

  @override
  Map<String, Object?> mediaState() => const <String, Object?>{};

  @override
  void mediaMetadata(String title, String artist, String album, String cover) {}
}

/// [player.PlaybackEnginePort] 的最小替身：prepare 只记录，不真的开播。
class _Engine implements player.PlaybackEnginePort {
  @override
  Future<void> prepare(
    Map<String, Object?> track,
    int generation, {
    bool reload = false,
  }) async {}
}

void main() {
  group('BasicPlayerPreferences（同步镜像 + 异步落盘）', () {
    test('seed 只收 panel/ 前缀键，且按裸键读得回来', () async {
      final MemoryBasicSettingsPort port = MemoryBasicSettingsPort(
        values: <String, String>{
          '${basicSettingsPreferencePrefix}play-mode': 'shuffle',
          '${basicSettingsPreferencePrefix}play-history': '[{"kind":"song","id":"a"}]',
          // 别人的键不进镜像。
          'someone-else/key': 'x',
        },
      );
      final BasicPlayerPreferences prefs = BasicPlayerPreferences(port)..seed(await port.readAll());

      expect(prefs.read('play-mode'), 'shuffle');
      expect(prefs.read('play-history'), '[{"kind":"song","id":"a"}]');
      expect(prefs.read('someone-else/key'), '');
      // 镜像里只存裸键。
      expect(prefs.knownKeys, containsAll(<String>['play-mode', 'play-history']));
    });

    test('write 同步生效并异步落盘到 panel/<裸键>', () async {
      final MemoryBasicSettingsPort port = MemoryBasicSettingsPort();
      final BasicPlayerPreferences prefs = BasicPlayerPreferences(port);

      prefs.write('play-mode', 'one');
      // 同步读回立刻可见（MusicPlayer 的端口契约就是同步的）。
      expect(prefs.read('play-mode'), 'one');
      await prefs.flush();

      expect(port.values['${basicSettingsPreferencePrefix}play-mode'], 'one');
    });

    test('端口写失败不抛也不回退内存值（本会话内一致，下次启动读旧值）', () async {
      final MemoryBasicSettingsPort port = MemoryBasicSettingsPort(failWrites: true);
      final BasicPlayerPreferences prefs = BasicPlayerPreferences(port);

      prefs.write('play-mode', 'shuffle');
      await prefs.flush();

      expect(prefs.read('play-mode'), 'shuffle');
      expect(port.values.containsKey('${basicSettingsPreferencePrefix}play-mode'), isFalse);
    });

    test('读不到（空端口）时给空串，与 Qt Host::preference 的缺键语义一致', () {
      final BasicPlayerPreferences prefs =
          BasicPlayerPreferences(MemoryBasicSettingsPort(failReads: true));
      expect(prefs.read('play-mode'), '');
      expect(prefs.mirror('play-mode'), '');
    });
  });

  group('MusicPlayer.resyncPreferences（偏好晚到时回填）', () {
    BasicPlayerPreferences prefs0(String mode) {
      final MemoryBasicSettingsPort port = MemoryBasicSettingsPort(
        values: <String, String>{
          if (mode.isNotEmpty) '${basicSettingsPreferencePrefix}play-mode': mode,
        },
      );
      return BasicPlayerPreferences(port);
    }

    test('构造时镜像为空 → resync 后模式变成存档值并 emit 一次', () {
      final BasicPlayerPreferences prefs = prefs0('shuffle');
      final player.MusicPlayer music = player.MusicPlayer(
        media: _Media(),
        preferences: prefs,
        engine: _Engine(),
      );
      // 镜像还没灌入：构造时读不到存档，保持默认 all。
      expect(music.mode, 'all');

      int changes = 0;
      music.addListener(() => changes += 1);
      prefs.seed(<String, String>{
        '${basicSettingsPreferencePrefix}play-mode': 'shuffle',
      });
      music.resyncPreferences();

      expect(music.mode, 'shuffle');
      expect(changes, 1);
    });

    test('resync 不覆盖本会话已切过的模式以外的东西：白名单外值被忽略', () {
      final BasicPlayerPreferences prefs = prefs0('');
      final player.MusicPlayer music = player.MusicPlayer(
        media: _Media(),
        preferences: prefs,
        engine: _Engine(),
      );
      expect(music.setMode('one'), isTrue);
      // 端口里是垃圾值：不应该把刚切好的 one 改回 all。
      prefs.seed(<String, String>{
        '${basicSettingsPreferencePrefix}play-mode': 'repeat',
      });
      music.resyncPreferences();
      expect(music.mode, 'one');
    });

    test('resync 重复调用不重复 emit（值没变）', () {
      final BasicPlayerPreferences prefs = prefs0('');
      final player.MusicPlayer music = player.MusicPlayer(
        media: _Media(),
        preferences: prefs,
        engine: _Engine(),
      );
      prefs.seed(<String, String>{
        '${basicSettingsPreferencePrefix}play-mode': 'off',
      });
      int changes = 0;
      music.addListener(() => changes += 1);
      music.resyncPreferences();
      expect(music.mode, 'off');
      expect(changes, 1);
      music.resyncPreferences();
      expect(changes, 1);
    });

    test('切模式会双向同步：setMode 之后镜像里立刻是同一个值', () {
      final BasicPlayerPreferences prefs = prefs0('');
      final player.MusicPlayer music = player.MusicPlayer(
        media: _Media(),
        preferences: prefs,
        engine: _Engine(),
      );
      expect(music.setMode('one'), isTrue);
      expect(prefs.read(player.kPlayModePreference), 'one');
    });
  });
}
