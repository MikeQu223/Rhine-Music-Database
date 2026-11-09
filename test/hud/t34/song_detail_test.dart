/// T34-S01-M12 歌曲详情页（lib/hud/pages/song_detail.dart）的独立单元测试。
///
/// 断言全部对着 Qt 真值写：Qt/src/NativeHudDetail.cpp:8-215、Qt/src/SongDetailCard.cpp:11-111、
/// Qt/src/NativeHud.cpp:10-138/167-174、Qt/src/NativeHud.h 的六行同专辑常量。
///
/// 本任务禁止执行任何构建/测试命令，因此本文件的 RED/GREEN 均为"未执行"，
/// 只作为待执行的源码证据提交（报告里记录 validationExecuted=false）。

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/pages/song_detail.dart';

/// 字形端口替身：等宽近似，字符宽 = size * charWidth。
class _FakeGlyphs implements SongDetailGlyphsPort {
  const _FakeGlyphs({this.charWidth = 0.5});
  final double charWidth;

  @override
  double width(String value, double size, String weight, [double tracking = 0]) =>
      value.length * size * charWidth + value.length * tracking;

  @override
  List<String> wrap(String value, double width, double size, String weight) {
    if (value.isEmpty) {
      return <String>[];
    }
    final int perLine = math.max(1, (width / (size * charWidth)).floor());
    final List<String> out = <String>[];
    for (int i = 0; i < value.length; i += perLine) {
      out.add(value.substring(i, math.min(value.length, i + perLine)));
    }
    return out;
  }

  @override
  double inset(String value, double size, String weight) => width(value, size, weight) / 2;
}

/// 位图端口替身：只对登记过的 key 返回位图（对应 Qt m_host->image）。
class _FakeImages implements SongDetailImagePort {
  _FakeImages([this.sizes = const <String, List<int>>{}]);
  final Map<String, List<int>> sizes;

  @override
  SongDetailImage? image(String key) {
    final List<int>? size = sizes[key];
    if (size == null) {
      return null;
    }
    return SongDetailImage(key: key, width: size[0], height: size[1]);
  }
}

const _FakeGlyphs _glyphs = _FakeGlyphs();
const double _width = 1920;

SongDetailItem _item({
  String id = '42',
  String kind = 'song',
  String title = '测试歌曲',
  String artist = '测试歌手',
  List<String> artists = const <String>[],
  String album = '测试专辑',
  String description = '',
  String wiki = '',
  String date = '',
  double durationMs = 245000,
  String provider = 'netease',
}) =>
    SongDetailItem(
      id: id,
      kind: kind,
      title: title,
      artist: artist,
      artists: artists,
      album: album,
      description: description,
      wiki: wiki,
      date: date,
      durationMs: durationMs,
      provider: provider,
    );

SongDetailState _state({
  SongDetailItem? item,
  bool local = false,
  bool dark = false,
  String tab = 'overview',
  List<SongDetailTrack> tracks = const <SongDetailTrack>[],
  int trackOffset = 0,
  int bodyOffset = 0,
  bool detailLoading = false,
  bool lyricsMode = false,
  String uid = 'u1',
  String provider = 'netease',
  String providerName = '',
  bool officialPlayback = true,
  bool isSiren = false,
  bool canMutateLike = false,
  bool likedInIds = false,
  bool likedInList = false,
  String? likeSubscriptionState,
  String? queueFeedbackKey,
  SongDetailPlayerState player = const SongDetailPlayerState(),
  bool directory = false,
  bool canEditPlaylist = false,
  String localQuality = '',
}) =>
    SongDetailState(
      provider: provider,
      officialPlayback: officialPlayback,
      item: item ?? _item(),
      local: local,
      dark: dark,
      tab: tab,
      tracks: tracks,
      trackOffset: trackOffset,
      bodyOffset: bodyOffset,
      detailLoading: detailLoading,
      lyricsMode: lyricsMode,
      uid: uid,
      providerName: providerName,
      isSiren: isSiren,
      canMutateLike: canMutateLike,
      likedInIds: likedInIds,
      likedInList: likedInList,
      likeSubscriptionState: likeSubscriptionState,
      queueFeedbackKey: queueFeedbackKey,
      player: player,
      directory: directory,
      canEditPlaylist: canEditPlaylist,
      localQuality: localQuality,
    );

List<Object?> _commands(SongDetailState state, {SongDetailImagePort? images, double opacity = 1.0}) =>
    renderSongDetail(state, _width, glyphs: _glyphs, images: images ?? _FakeImages(), opacity: opacity)
        .commands;

List<Map<String, Object?>> _hits(SongDetailState state, {SongDetailImagePort? images}) =>
    renderSongDetail(state, _width, glyphs: _glyphs, images: images ?? _FakeImages()).hits;

/// 所有命令中 op 等于 op 的子列表。
List<List<Object?>> _byOp(List<Object?> commands, String op) => commands
    .whereType<List<Object?>>()
    .where((List<Object?> command) => command.isNotEmpty && command.first == op)
    .toList();

List<String> _texts(List<Object?> commands) => _byOp(commands, 'text')
    .map((List<Object?> command) => command[1]! as String)
    .toList();

Map<String, Object?> _hitByAction(List<Map<String, Object?>> hits, String action) =>
    hits.firstWhere((Map<String, Object?> hit) => hit['action'] == action,
        orElse: () => <String, Object?>{});

bool _hasHit(List<Map<String, Object?>> hits, String action) =>
    hits.any((Map<String, Object?> hit) => hit['action'] == action);

/// 逐元素比较颜色列表。
/// 命令里的颜色是发射时拷贝的（song_detail.dart 的 _Painter.fill/text 走 List<Object?>.of），
/// 所以颜色不能用 List 身份比较，必须比内容。
bool _sameColor(Object? value, List<Object?> expected) {
  if (value is! List<Object?> || value.length != expected.length) {
    return false;
  }
  for (int index = 0; index < expected.length; index++) {
    if (value[index] != expected[index]) {
      return false;
    }
  }
  return true;
}

void main() {
  group('页面骨架与契约', () {
    test('首个命令是 save，随后是 alpha(opacity)，最后 restore（NativeHudDetail.cpp:63-64/215）', () {
      final List<Object?> commands = _commands(_state(), opacity: 0.5);
      expect(commands.first, <Object?>['save']);
      final List<Object?> alpha = _byOp(commands, 'alpha').first;
      expect(alpha[1], 0.5);
      expect(commands.last, <Object?>['restore']);
    });

    test('面板底按 detailBounds(song) 绘制（NativeHud.cpp:167-170）', () {
      final List<Object?> commands = _commands(_state());
      final List<Object?> panel = _byOp(commands, 'fill').first;
      final double left = _width * 0.56 - 24;
      expect(panel[1], <Object?>[0.973, 0.969, 0.933, 0.96]);
      expect(panel[2], left);
      expect(panel[3], 260);
      expect(panel[4], _width - left - 35);
      expect(panel[5], 696);
    });

    test('所有命中都是六字段且没有 fixed（NativeHud.cpp:102-108）', () {
      final List<Map<String, Object?>> hits =
          _hits(_state(canMutateLike: true, directory: true, canEditPlaylist: true, tab: 'history'));
      expect(hits, isNotEmpty);
      for (final Map<String, Object?> hit in hits) {
        expect(hit.keys.toSet(), <String>{'x', 'y', 'width', 'height', 'action', 'label'});
        expect(hit.containsKey('fixed'), isFalse);
      }
    });
  });

  group('左列（DRAG TO INSPECT 与封面入口）', () {
    test('返回/ID/MUSIC DATABASE/DRAG TO INSPECT/查看封面 全部按 Qt 坐标产出', () {
      final List<Object?> commands = _commands(_state());
      final List<Map<String, Object?>> hits = _hits(_state());
      final Map<String, Object?> back = _hitByAction(hits, 'back');
      expect(back['x'], 59);
      expect(back['y'], 211);
      expect(back['width'], 360);
      expect(back['height'], 54);
      final Map<String, Object?> viewer = _hitByAction(hits, 'viewer');
      expect(viewer['x'], 60);
      expect(viewer['y'], 944);
      expect(viewer['width'], 260);
      expect(viewer['height'], 35);
      expect(_texts(commands), contains('DRAG TO INSPECT'));
      expect(_texts(commands), contains('MUSIC DATABASE'));
      expect(_texts(commands), contains('← 返回资料库   ESC'));
      expect(_texts(commands), contains('查看封面 ↗'));
    });

    test('limited() 产出的 text 命令使用 calibrated ink（NativeHud.cpp:77-79）', () {
      final List<Object?> commands = _commands(_state(item: _item(id: 'a-very-long-identifier-0001')));
      final List<Object?> limitedText = _byOp(commands, 'text')
          .firstWhere((List<Object?> command) => command[1] == 'a-very-long-identifier-0001' ||
              (command[1]! as String).endsWith('…'));
      expect(limitedText[7], <Object?>[0.08, 0.085, 0.075, 1, 'calibratedRGB']);
    });
  });

  group('动作行（SongDetailCard.cpp:17-46）', () {
    test('未登录（canMutateLike=false）时主行只有播放一格，其余 route 为空不产出', () {
      final List<Map<String, Object?>> hits = _hits(_state());
      expect(_hasHit(hits, 'music:play'), isTrue);
      expect(_hasHit(hits, 'music:like'), isFalse);
      expect(_hasHit(hits, 'music:add-to-playlist'), isFalse);
      expect(_hasHit(hits, 'music:enqueue'), isTrue);
      expect(_hasHit(hits, 'music:play-next'), isTrue);
      expect(_hasHit(hits, 'music:artist:0'), isFalse);
    });

    test('登录后主行三格齐备且副行按 artists 决定第三格', () {
      final List<Map<String, Object?>> hits =
          _hits(_state(canMutateLike: true, likedInList: true, item: _item(artists: <String>['a'])));
      expect(_hasHit(hits, 'music:play'), isTrue);
      expect(_hasHit(hits, 'music:like'), isTrue);
      expect(_hasHit(hits, 'music:add-to-playlist'), isTrue);
      expect(_hasHit(hits, 'music:artist:0'), isTrue);
      final Map<String, Object?> like = _hitByAction(hits, 'music:like');
      expect(like['label'], '♥ 已喜欢');
    });

    test('QQ unknown 订阅态给出核实文案（NativeHudDetail.cpp:123-129）', () {
      final List<Map<String, Object?>> hits =
          _hits(_state(provider: 'qq', canMutateLike: true, likeSubscriptionState: 'unknown'));
      expect(_hitByAction(hits, 'music:like')['label'], '红心 / 核实后切换');
    });

    test('队列反馈键命中时替换副行文案（NativeHudDetail.cpp:134-137）', () {
      final List<Map<String, Object?>> hits = _hits(_state(
        uid: 'u9',
        queueFeedbackKey: 'u9:netease:42',
      ));
      expect(_hitByAction(hits, 'music:enqueue')['label'], '＋ 加入队列');
      final List<Map<String, Object?>> custom = _hits(SongDetailState(
        provider: 'netease',
        officialPlayback: true,
        item: _item(),
        uid: 'u9',
        queueFeedbackKey: 'u9:netease:42',
        queueFeedbackEnqueueLabel: '✓ 已加入队列',
        queueFeedbackPlayNextLabel: '✓ 已设为下一首',
      ));
      expect(_hitByAction(custom, 'music:enqueue')['label'], '✓ 已加入队列');
      expect(_hitByAction(custom, 'music:play-next')['label'], '✓ 已设为下一首');
    });

    test('三格宽度为 (usable - 24) / 3（SongDetailCard.cpp:19-21）', () {
      final double x = _width * 0.56;
      final double usable = _width - x - 59;
      final double buttonWidth = (usable - 24) / 3;
      final List<Map<String, Object?>> hits = _hits(_state(canMutateLike: true));
      final Map<String, Object?> play = _hitByAction(hits, 'music:play');
      final Map<String, Object?> like = _hitByAction(hits, 'music:like');
      expect(play['width'], buttonWidth);
      expect(play['x'], x);
      expect(like['x'], x + buttonWidth + 12);
    });
  });

  group('四字段与三 tabs（SongDetailCard.cpp:72-110）', () {
    test('非 history 有 4 个字段标题，空值回落 暂无', () {
      final List<Object?> commands =
          _commands(_state(item: _item(album: '', durationMs: 0), player: const SongDetailPlayerState()));
      final List<String> texts = _texts(commands);
      expect(texts, contains('ALBUM / 所属专辑'));
      expect(texts, contains('QUALITY / 音质'));
      expect(texts, contains('DURATION / 时长'));
      expect(texts, contains('PLAYBACK / 播放方式'));
      expect(texts, contains('AUDIO ARCHIVE / 音频档案'));
      expect(texts.where((String text) => text == '暂无').length, greaterThanOrEqualTo(2));
      expect(texts, contains('面板内播放 / 官方入口'));
      expect(_hasHit(_hits(_state()), 'quality:open'), isFalse);
    });

    test('本地文件使用文件信息标签与本地播放方式（NativeHudDetail.cpp:10-14/99-101）', () {
      final SongDetailState state = SongDetailState(
        provider: 'netease',
        officialPlayback: true,
        item: const SongDetailItem(
          id: 'l1',
          title: '本地歌曲',
          artist: '本地歌手',
          path: '/sdcard/a.flac',
          format: 'FLAC',
          sampleRate: 96000,
          bitrate: 1411,
        ),
        local: true,
        localQuality: 'lossless',
      );
      final List<Object?> commands = _commands(state);
      expect(_texts(commands), contains('文件信息'));
      expect(_texts(commands), contains('本地文件 / 面板内播放'));
      final String body = songDetailBody(state);
      expect(body, '/sdcard/a.flac\nFLAC / 96000 Hz / 1411 kbps');
    });

    test('三 tabs 命中顺序与选中下划线（SongDetailCard.cpp:94-109）', () {
      final List<Object?> commands = _commands(_state(tab: 'notes'));
      final List<Map<String, Object?>> hits = _hits(_state(tab: 'notes'));
      final List<Map<String, Object?>> tabs = hits
          .where((Map<String, Object?> hit) => (hit['action']! as String).startsWith('tab:'))
          .toList();
      expect(tabs.length, 3);
      expect(tabs.map((Map<String, Object?> hit) => hit['action']).toList(),
          <String>['tab:overview', 'tab:notes', 'tab:history']);
      expect(tabs.map((Map<String, Object?> hit) => hit['label']).toList(),
          <String>['歌曲百科', '专辑信息', '同专辑曲目']);
      expect(tabs.first['y'], 720);
      final List<List<Object?>> amber = _byOp(commands, 'fill')
          .where((List<Object?> command) => _sameColor(command[1], songDetailAmber))
          .toList();
      expect(amber.length, 1);
      expect(amber.first[5], 3);
    });

    test('history tab 把 tabs 提前并给同专辑曲目补计数（SongDetailCard.cpp:96-100）', () {
      final List<SongDetailTrack> tracks = List<SongDetailTrack>.generate(
          8, (int index) => SongDetailTrack(id: 't$index', title: 'T$index', artist: 'A'));
      final List<Map<String, Object?>> hits = _hits(_state(tab: 'history', tracks: tracks));
      final List<Map<String, Object?>> tabs = hits
          .where((Map<String, Object?> hit) => (hit['action']! as String).startsWith('tab:'))
          .toList();
      expect(tabs.first['y'], 584);
      expect(tabs.last['label'], '同专辑曲目 · 8 首');
    });
  });

  group('同专辑六行（NativeHudDetail.cpp:166-193）', () {
    List<SongDetailTrack> tracks(int count) => List<SongDetailTrack>.generate(
        count,
        (int index) => SongDetailTrack(
            id: 't$index', title: '曲目$index', artist: '歌手$index', durationMs: 60000 + index * 1000));

    test('六行上限、0 基 action、行分隔线与滚动条', () {
      final List<Object?> commands = _commands(_state(tab: 'history', tracks: tracks(10)));
      final List<Map<String, Object?>> hits = _hits(_state(tab: 'history', tracks: tracks(10)));
      final List<Map<String, Object?>> rows = hits
          .where((Map<String, Object?> hit) => (hit['action']! as String).startsWith('music:album-track:'))
          .toList();
      expect(rows.length, 6);
      expect(rows.first['action'], 'music:album-track:0');
      expect(rows.last['action'], 'music:album-track:5');
      expect(rows.first['label'], '曲目0');
      expect(rows.first['height'], 42);
      final List<String> texts = _texts(commands);
      expect(texts, contains('01'));
      expect(texts, contains('06'));
      expect(texts, contains('曲目0 / 歌手0'));
      expect(texts, contains('01:00'));
      // 滚动条：轨道 0.12 + 手柄 0.6，两段都在 x + usable + 10。
      final double x = _width * 0.56;
      final double usable = _width - x - 59;
      final List<List<Object?>> bars = _byOp(commands, 'fill')
          .where((List<Object?> command) => command[2] == x + usable + 10)
          .toList();
      expect(bars.length, 2);
      expect((bars.first[1]! as List<Object?>)[3], 0.12);
      expect((bars.last[1]! as List<Object?>)[3], 0.6);
      expect(bars.last[5], math.max(28.0, (6 * 48 - 12) * 6 / 10));
    });

    test('trackOffset 被 clamp 到 tracks.length - 6 并影响行号与 action', () {
      final SongDetailDrawing drawing =
          renderSongDetail(_state(tab: 'history', tracks: tracks(8), trackOffset: 5), _width,
              glyphs: _glyphs, images: _FakeImages());
      expect(drawing.trackOffset, 2);
      final List<Map<String, Object?>> rows = drawing.hits
          .where((Map<String, Object?> hit) => (hit['action']! as String).startsWith('music:album-track:'))
          .toList();
      expect(rows.first['action'], 'music:album-track:2');
      expect(_texts(drawing.commands), contains('03'));

      // 负偏移夹到 0：行号与 action 都从 1 / 0 基起点开始。
      final SongDetailDrawing negative = renderSongDetail(
          _state(tab: 'history', tracks: tracks(8), trackOffset: -3), _width,
          glyphs: _glyphs, images: _FakeImages());
      expect(negative.trackOffset, 0);
      expect(
        negative.hits
            .where((Map<String, Object?> hit) =>
                (hit['action']! as String).startsWith('music:album-track:'))
            .first['action'],
        'music:album-track:0',
      );
    });

    test('空同专辑在加载态与静态态给出不同文案', () {
      expect(_texts(_commands(_state(tab: 'history', detailLoading: true))), contains('正在载入曲目…'));
      expect(_texts(_commands(_state(tab: 'history'))), contains('暂无曲目信息'));
    });
  });

  group('正文三行与底部按钮（NativeHudDetail.cpp:194-214）', () {
    test('overview 未读到 wiki 时按 detailLoading 给文案，并产出 detail:copy 命中', () {
      final List<Object?> loading = _commands(_state(detailLoading: true));
      expect(_texts(loading), contains('正在读取歌曲百科…'));
      expect(_texts(loading), isNot(contains('暂无歌曲百科')));
      final List<Map<String, Object?>> hits = _hits(_state());
      final Map<String, Object?> copy = _hitByAction(hits, 'detail:copy');
      expect(copy['x'], _width * 0.56);
      expect(copy['y'], 786);
    });

    test('bodyOffset 被 clamp，且最多渲染三行（NativeHudDetail.cpp:194-202）', () {
      final SongDetailDrawing drawing =
          renderSongDetail(_state(bodyOffset: 99), _width, glyphs: _glyphs, images: _FakeImages());
      // 正文行的 x 恒为 width*0.56（左列的 MUSIC DATABASE / DRAG TO INSPECT 在 x=60），
      // 只按 y 过滤会连带选中左列文本。
      final List<String> bodyLines = _byOp(drawing.commands, 'text')
          .where((List<Object?> command) =>
              (command[2]! as double) == _width * 0.56 && (command[3]! as double) >= 790)
          .map((List<Object?> command) => command[1]! as String)
          .toList();
      expect(bodyLines.length, lessThanOrEqualTo(3));
      expect(drawing.bodyOffset, 0);

      // 负偏移：Qt 只夹上界（NativeHudDetail.cpp:196），本实现额外把负值夹到 0。
      final SongDetailDrawing negative = renderSongDetail(_state(bodyOffset: -4), _width,
          glyphs: _glyphs, images: _FakeImages());
      expect(negative.bodyOffset, 0);
    });

    test('官方入口/试听片段/从歌单移除 三格命中与排除条件', () {
      final List<Map<String, Object?>> hits =
          _hits(_state(provider: 'qq', providerName: 'QQ音乐', directory: true, canEditPlaylist: true));
      expect(_hitByAction(hits, 'music:official')['label'], 'QQ音乐 ↗');
      expect(_hasHit(hits, 'music:preview'), isTrue);
      expect(_hasHit(hits, 'music:remove-track'), isTrue);
      final List<Map<String, Object?>> localHits = _hits(_state(local: true));
      expect(_hasHit(localHits, 'music:official'), isFalse);
      final List<Map<String, Object?>> neteaseHits = _hits(_state());
      expect(_hitByAction(neteaseHits, 'music:official')['label'], '官方客户端 ↗');
      expect(_hasHit(neteaseHits, 'music:preview'), isFalse);
    });
  });

  group('封面通道隔离与委派', () {
    test('本页永不产出封面贴图命令，3D 封面只属于场景 draw 通道', () {
      final List<Object?> commands = _commands(
        // 只有同源播放中（isCurrent）且 actualQuality 非空时才去取徽标位图
        // （NativeHudDetail.cpp:103-114）；否则本页一条 image 命令都不该产出。
        _state(
          canMutateLike: true,
          player: const SongDetailPlayerState(currentIdentity: 'netease:42', actualQuality: 'high'),
        ),
        images: _FakeImages(<String, List<int>>{
          'quality:netease-high': <int>[3, 1],
        }),
      );
      final List<List<Object?>> images = _byOp(commands, 'image');
      expect(images.length, 1);
      expect(images.first[1], 'quality:netease-high');
      expect(songDetailCoverChannel, 'scene-draw');
      expect(_texts(commands), isNot(contains('cover')));
    });

    test('音质徽标宽度取 22 * (w/h) 与 (usable - 12) / 2 - 12 的较小值（NativeHudDetail.cpp:109-117）', () {
      final double x = _width * 0.56;
      final double usable = _width - x - 59;
      final SongDetailDrawing drawing = renderSongDetail(
        _state(item: _item(provider: 'netease'), player: const SongDetailPlayerState(currentIdentity: 'netease:42', actualQuality: 'high')),
        _width,
        glyphs: _glyphs,
        images: _FakeImages(<String, List<int>>{'quality:netease-high': <int>[300, 100]}),
      );
      final List<Object?> image = _byOp(drawing.commands, 'image').first;
      expect(image[1], 'quality:netease-high');
      expect(image[4], math.min(22.0 * 300 / 100, (usable - 12) / 2 - 12));
      expect(image[5], 22);
      // 徽标存在时 QUALITY 字段只画位图，值文案不再输出（SongDetailCard.cpp:83-88）。
      expect(_texts(drawing.commands), isNot(contains('高品质')));

      // 同一路径下 actualQuality='standard' 也只是值文案不同，仍被徽标顶掉。
      final SongDetailDrawing standardBadge = renderSongDetail(
        _state(
          item: _item(),
          player: const SongDetailPlayerState(currentIdentity: 'netease:42', actualQuality: 'standard'),
        ),
        _width,
        glyphs: _glyphs,
        images: _FakeImages(<String, List<int>>{'quality:netease-standard': <int>[300, 100]}),
      );
      expect(_byOp(standardBadge.commands, 'image').first[1], 'quality:netease-standard');
      expect(_texts(standardBadge.commands), isNot(contains('标准')));
    });

    test('无徽标时 QUALITY 字段回落值文案，并给出 quality:open 命中（SongDetailCard.cpp:83-92）', () {
      final SongDetailDrawing high = renderSongDetail(
        _state(
          item: _item(),
          player: const SongDetailPlayerState(currentIdentity: 'netease:42', actualQuality: 'high'),
        ),
        _width,
        glyphs: _glyphs,
        images: _FakeImages(),
      );
      expect(_texts(high.commands), contains('高品质'));
      expect(_hasHit(high.hits, 'quality:open'), isTrue);
      expect(_hitByAction(high.hits, 'quality:open')['label'], '音质说明与切换');

      final SongDetailDrawing standard = renderSongDetail(
        _state(
          item: _item(),
          player: const SongDetailPlayerState(currentIdentity: 'netease:42', actualQuality: 'standard'),
        ),
        _width,
        glyphs: _glyphs,
        images: _FakeImages(),
      );
      expect(_texts(standard.commands), contains('标准'));

      final SongDetailDrawing loading = renderSongDetail(
        _state(item: _item(), player: const SongDetailPlayerState(currentIdentity: 'netease:42', loading: true)),
        _width,
        glyphs: _glyphs,
        images: _FakeImages(),
      );
      expect(_texts(loading.commands), contains('暂无'));
      expect(_hasHit(loading.hits, 'quality:open'), isFalse);

      final SongDetailDrawing local = renderSongDetail(
        _state(local: true, localQuality: 'lossless'),
        _width,
        glyphs: _glyphs,
        images: _FakeImages(),
      );
      expect(_texts(local.commands), contains('高品质'));
      expect(_hasHit(local.hits, 'quality:open'), isFalse);
    });

    test('空 item 走 archive，非 song 走 container，lyricsMode 交回歌词原子', () {
      final SongDetailDrawing archive = renderSongDetail(
        SongDetailState(provider: 'netease', officialPlayback: true),
        _width,
        glyphs: _glyphs,
        images: _FakeImages(),
      );
      expect(archive.delegatedTo, songDetailDelegateArchive);
      expect(archive.commands, isEmpty);

      final SongDetailDrawing container = renderSongDetail(_state(item: _item(kind: 'album')), _width,
          glyphs: _glyphs, images: _FakeImages());
      expect(container.delegatedTo, songDetailDelegateContainer);

      final SongDetailDrawing lyrics = renderSongDetail(
        _state(
          lyricsMode: true,
          player: const SongDetailPlayerState(currentIdentity: 'netease:42'),
        ),
        _width,
        glyphs: _glyphs,
        images: _FakeImages(),
      );
      expect(lyrics.delegatedTo, songDetailDelegateLyricsPanel);
      expect(lyrics.commands.first, <Object?>['save']);
      expect(lyrics.commands.last, <Object?>['restore']);
    });

    test('lyricsMode 在条目与播放条目不同源时自动失效（NativeHudDetail.cpp:57-59）', () {
      final SongDetailDrawing drawing = renderSongDetail(
        _state(lyricsMode: true, player: const SongDetailPlayerState(currentIdentity: 'netease:other')),
        _width,
        glyphs: _glyphs,
        images: _FakeImages(),
      );
      expect(drawing.delegatedTo, isNull);
      expect(_texts(drawing.commands), contains('DRAG TO INSPECT'));
    });
  });

  group('纯函数助手（MusicData 对齐）', () {
    test('songDetailPad / songDetailTime / songDetailSlice', () {
      expect(songDetailPad(7), '07');
      expect(songDetailPad(123), '123');
      expect(songDetailTime(0), '暂无');
      expect(songDetailTime(245000), '04:05');
      expect(songDetailTime(3600000), '60:00');
      expect(songDetailSlice<int>(<int>[1, 2, 3, 4], 1, 2), <int>[2, 3]);
      expect(songDetailSlice<int>(<int>[1, 2], 5, 2), isEmpty);
    });

    test('songDetailBody 四分支与 Qt 文案一致', () {
      expect(songDetailBody(_state(item: _item(wiki: '百科正文'))), '百科正文');
      expect(songDetailBody(_state(detailLoading: true)), '正在读取歌曲百科…');
      expect(songDetailBody(_state()), '暂无歌曲百科');
      expect(
        songDetailBody(_state(tab: 'notes', item: _item(album: 'A', artist: 'B', date: '2020', description: 'D'))),
        '专辑：A\n歌手：B\n发行日期：2020\nD',
      );
      expect(
        songDetailBody(_state(tab: 'notes', item: _item(album: 'A', artist: 'B'))),
        '专辑：A\n歌手：B\n发行日期：暂无\n暂无专辑介绍',
      );
    });

    // 非 song 的 body 分支在 renderSongDetail 里不可达（kind != 'song' 先委派 container），
    // 因此直接单测纯函数（对应 NativeHudDetail.cpp:30-42）。
    test('songDetailBody 非 song 分支（容器详情文案）', () {
      expect(songDetailBody(_state(item: _item(kind: 'album', description: '专辑简介'))), '专辑简介');
      expect(songDetailBody(_state(item: _item(kind: 'album'))), '暂无简介');
      expect(
        songDetailBody(_state(
            tab: 'notes', item: _item(kind: 'album', id: '9', title: 'T', artist: 'A'))),
        '编号：9\n名称：T\nA\n已载入 0 首',
      );
    });
  });

  group('深色主题调色板', () {
    test('深色时面板色与 ink 切换（NativeHudDetail.cpp:65-69 / NativeHud.cpp:10-15）', () {
      final List<Object?> commands = _commands(_state(dark: true));
      expect(_byOp(commands, 'fill').first[1], <Object?>[0.08, 0.095, 0.09, 0.96]);
      final List<Object?> dragText = _byOp(commands, 'text')
          .firstWhere((List<Object?> command) => command[1] == 'DRAG TO INSPECT');
      expect(dragText[7], <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite']);
      final List<Object?> titleText = _byOp(commands, 'text')
          .firstWhere((List<Object?> command) => command[1] == 'TRACK RECORD / 歌曲档案');
      expect(titleText[7], <Object?>[0.92, 0.93, 0.88, 0.62]);
    });
  });
}
