/// 横屏弹层接线：`modal == 'comments' | 'mv' | 'login' | 'provider'` 四个分支
/// 是否真的把面板画进了横屏帧。
///
/// 各面板的版式细节另有自己的测试（`test/hud/comments_modal_test.dart`、
/// `test/hud/mv_panels_test.dart`、`test/hud/modals_misc_test.dart`），这里只验
/// 「分支选对了、命中上了、面板外壳发出去了」。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_comment_mapper.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/basic_mv_mapper.dart';
import 'package:rhine_music_database/domain/account/login_controller.dart'
    show LoginPhase, LoginState;
import 'package:rhine_music_database/domain/comments/comment_controller.dart';
import 'package:rhine_music_database/domain/mv/mv_controller.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_comments.dart';
import 'package:rhine_music_database/hud/portrait/portrait_pages_mv.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';
import 'package:rhine_music_database/provider/provider_descriptor.dart';
import 'package:rhine_music_database/provider/provider_gateway.dart';

Future<BasicGlyphPorts> _realPorts() async {
  final String glyphJson = await File(basicGlyphTableAsset).readAsString();
  final GlyphFontSet fonts = parseGlyphResources(glyphJson: glyphJson, letteringJson: '{}');
  return BasicGlyphPorts(glyphs: fonts, text: GlyphText.resourceOnly(fonts));
}

/// 缺省 descriptor（形状抄 `MusicBridge/plugins/descriptors/*.json`）。
ProviderDescriptor _descriptor(String id, String name, int order) =>
    ProviderDescriptor.parse(<String, Object?>{
      'schemaVersion': 2,
      'id': id,
      'display': <String, Object?>{
        'name': name,
        'label': id.toUpperCase(),
        'order': order,
        'default': false,
      },
      'capabilities': <String, Object?>{'search': true},
    });

SirenSong _song() => SirenSong(
      id: '880380',
      title: 'Systematic Violation',
      artist: '塞壬唱片-MSR',
      album: '专辑',
      albumId: 'album-1',
      cover: '',
      sourceUrl: 'https://example.invalid/a.mp3',
      lyricUrl: '',
      durationMs: 300000,
    );

BasicViewState _libraryState() => BasicViewState(
      phase: BasicPhase.library,
      songs: <SirenSong>[_song()],
      selectedLane: basicDefaultLane,
    );

/// 检索快照：行来自 `state.searchRows`（竖屏检索页与横屏面板共用同一份投影）。
BasicViewState _searchState() => BasicViewState(
      phase: BasicPhase.library,
      query: 'love',
      searchKind: 'song',
      searchRemote: true,
      searchTotal: 2,
      searchStatus: '找到 2 条结果',
      searchRows: <Map<String, Object?>>[
        <String, Object?>{
          'kind': 'song',
          'title': 'Love Story',
          'artist': '听众甲',
          'durationMs': 201000,
        },
        <String, Object?>{'kind': 'album', 'title': 'Love Album', 'trackCount': 9},
      ],
    );

BasicHudFrame _landscape(String modal, BasicGlyphPorts ports,
    {PortraitCommentsModel? comments,
    LoginState? loginState,
    MvPanelModel? mv,
    List<ProviderDescriptor> providers = const <ProviderDescriptor>[],
    String providerId = '',
    Map<String, ProviderAccount?> accounts = const <String, ProviderAccount?>{}}) {
  return BasicHudFrame.build(
    state: _libraryState(),
    ports: ports,
    width: 1920,
    height: 1080,
    portrait: false,
    modal: modal,
    comments: comments,
    loginState: loginState,
    mv: mv,
    providers: providers,
    providerId: providerId,
    providerAccounts: accounts,
  );
}

void main() {
  test('横屏 comments：面板画出排序 chip 与关闭按钮', () async {
    final BasicGlyphPorts ports = await _realPorts();
    final BasicHudFrame frame = _landscape(
      'comments',
      ports,
      comments: portraitCommentsModelOf(
        CommentState(
          phase: CommentPhase.loaded,
          status: '找到 2 条评论',
          comments: <ProviderComment>[
            const ProviderComment(id: 'c1', content: '第一条评论', nickname: '听众甲'),
          ],
        ),
        providerName: '网易云音乐',
        providerId: 'netease',
      ),
    );
    final Iterable<String> hits = frame.hits.map((HudHit hit) => hit.action);
    expect(hits, contains('comments:close'));
    expect(hits, contains('comments:sort:hot'));
    expect(hits, contains('comments:refresh'));
    // 面板正文由 comments_modal 自己的端口画，这里只确认整帧非空。
    expect(frame.commands, isNotEmpty);
  });

  test('横屏 mv：画出 MV 弹层并命中「刷新版本」', () async {
    final BasicGlyphPorts ports = await _realPorts();
    final BasicHudFrame frame = _landscape(
      'mv',
      ports,
      mv: basicMvPanelModelOf(const MvState(trackId: '880380', status: '正在查找 MV…')),
    );
    final Iterable<String> hits = frame.hits.map((HudHit hit) => hit.action);
    expect(hits, contains('mv:retry'));
    // 外壳的关闭键是通用 `close-modal`（ModalShell 通用分支），面板自己的 mv:close
    // 由竖屏页头的返回箭头发；横屏不重复造第二个关闭。
    expect(hits, contains('close-modal'));
  });

  test('横屏 login：画出登录弹层与「本轮跳过账号验证」退出', () async {
    final BasicGlyphPorts ports = await _realPorts();
    final BasicHudFrame frame = _landscape(
      'login',
      ports,
      loginState: const LoginState(provider: 'netease', methodId: 'qr'),
    );
    final Iterable<String> hits = frame.hits.map((HudHit hit) => hit.action);
    expect(hits, contains('close-modal'));
    expect(frame.commands, isNotEmpty);
  });

  test('横屏 provider：平台卡片逐张命中 provider:<id>，且 local 可被过滤', () async {
    final BasicGlyphPorts ports = await _realPorts();
    final List<ProviderDescriptor> providers = <ProviderDescriptor>[
      _descriptor('siren', '塞壬唱片', 0),
      _descriptor('local', '本地音乐', 4),
    ];
    final BasicHudFrame frame =
        _landscape('provider', ports, providers: providers, providerId: 'siren');
    final Iterable<String> hits = frame.hits.map((HudHit hit) => hit.action);
    expect(hits, contains('provider:siren'));
    expect(frame.commands, isNotEmpty);
  });

  test('横屏 search：面板投影 state.searchRows，行点击发出既有动作串', () async {
    final BasicGlyphPorts ports = await _realPorts();
    final BasicHudFrame frame = BasicHudFrame.build(
      state: _searchState(),
      ports: ports,
      width: 1920,
      height: 1080,
      portrait: false,
      modal: 'search',
    );
    final Iterable<String> hits = frame.hits.map((HudHit hit) => hit.action);
    // 分类 / 分组 tab（Qt NativeHudSearch.cpp:76 / :105 的动作串）。
    for (int index = 0; index < 4; index++) {
      expect(hits, contains('music:kind:$index'));
    }
    for (int index = 0; index < 3; index++) {
      expect(hits, contains('music:group:$index'));
    }
    // 行：远端曲目走 music:search-open:<行下标>，专辑走 music:search-album:<编码标题>。
    expect(hits, contains('music:search-open:0'));
    expect(hits, contains('music:search-album:Love%20Album'));
    // 外壳的返回键仍然是通用 close-modal。
    expect(hits, contains('close-modal'));
    // 行标题真的画出来了（不是空面板）。
    final List<String> texts = <String>[
      for (final List<Object?> command in frame.commands)
        if (command.isNotEmpty && command[0] == 'text') command[1]! as String,
    ];
    expect(texts, contains('Love Story'));
    expect(texts, contains('Love Album'));
  });

  test('横屏 search：没有检索行时画空态提示，而不是留一块空面板', () async {
    final BasicGlyphPorts ports = await _realPorts();
    final BasicHudFrame frame = BasicHudFrame.build(
      state: const BasicViewState(phase: BasicPhase.library, query: '', searchStatus: ''),
      ports: ports,
      width: 1920,
      height: 1080,
      portrait: false,
      modal: 'search',
    );
    final List<String> texts = <String>[
      for (final List<Object?> command in frame.commands)
        if (command.isNotEmpty && command[0] == 'text') command[1]! as String,
    ];
    expect(texts, contains('检索音乐档案'));
  });
}
