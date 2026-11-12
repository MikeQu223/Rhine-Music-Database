import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/app/consent_gate.dart';
import 'package:rhine_music_database/basic/basic_app.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/platform_playback.dart';
import 'package:rhine_music_database/basic/siren_controller.dart';
import 'package:rhine_music_database/ui/pages/consent_page.dart';

/// 播放端口替身：只记录 dispose，播放方法全部是空操作。
///
/// 用它的原因不是“省事”，而是 [MethodChannelBasicAudio] 会真的去订阅
/// EventChannel；启动入口的测试不该依赖平台通道。
class _FakeAudio implements BasicAudioPort {
  final List<void Function(BasicAudioState)> _listeners =
      <void Function(BasicAudioState)>[];

  int disposes = 0;
  final BasicAudioState _state = BasicAudioState.idle;

  @override
  BasicAudioState get state => _state;

  @override
  void addListener(void Function(BasicAudioState) listener) {
    _listeners.add(listener);
  }

  @override
  void removeListener(void Function(BasicAudioState) listener) {
    _listeners.remove(listener);
  }

  @override
  Future<void> prepare(String url, {required int generation}) async {}

  @override
  Future<void> play({required int generation}) async {}

  @override
  Future<void> pause({required int generation}) async {}

  @override
  Future<void> seekTo(double positionMs, {required int generation}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    disposes += 1;
  }
}

/// controller 替身：**不调** super.boot()，所以不会真的起 100ms ticker，
/// 也不会真的去读网络曲库；只数调用次数。
class _TrackingController extends BasicController {
  _TrackingController({required _FakeAudio audio}) : super(audio: audio);

  int bootCalls = 0;
  int retryCalls = 0;
  int disposeCalls = 0;
  int nextCalls = 0;
  int toggleCalls = 0;
  int lyricsOpens = 0;
  int libraryOpens = 0;
  int backCalls = 0;

  /// 命中动作真正落到 controller 的证据（不是“点了就算”）。
  final List<String> queries = <String>[];
  final List<double> seeks = <double>[];
  final List<String> openedSongs = <String>[];
  final List<String> openedAlbums = <String>[];

  /// 只在这些动作测试里顶掉真实状态：外壳的分派必须按 state 的真实结构走
  /// （首屏单曲行的 index 指回 state.songs，专辑详情指回 album.songs）。
  BasicViewState? stateOverride;

  @override
  BasicViewState get state => stateOverride ?? super.state;

  @override
  Future<void> boot() async {
    bootCalls += 1;
  }

  @override
  Future<void> retry() async {
    retryCalls += 1;
  }

  @override
  Future<void> setQuery(String value) async {
    queries.add(value);
  }

  @override
  Future<void> seekToFraction(double fraction) async {
    seeks.add(fraction);
  }

  @override
  Future<void> openSong(SirenSong song) async {
    openedSongs.add(song.id);
  }

  @override
  Future<void> openAlbum(SirenAlbum album) async {
    openedAlbums.add(album.id);
  }

  @override
  Future<void> togglePlay() async {
    toggleCalls += 1;
  }

  @override
  Future<void> next() async {
    nextCalls += 1;
  }

  @override
  Future<void> openLyrics() async {
    lyricsOpens += 1;
  }

  /// 94 已上线的“回完整曲库”入口（archive 页 'music:open-all-siren'）。
  @override
  Future<void> openSirenLibrary() async {
    libraryOpens += 1;
  }

  @override
  Future<void> back() async {
    backCalls += 1;
  }

  @override
  void dispose() {
    disposeCalls += 1;
    super.dispose();
  }
}

/// boot() 直接抛错的 controller（真实 controller 几乎不会抛，外壳仍要兜住）。
class _ThrowingBootController extends _TrackingController {
  _ThrowingBootController({required super.audio});

  @override
  Future<void> boot() async {
    bootCalls += 1;
    throw StateError('曲库炸了');
  }
}

/// 任何 asset 都读不到的资源包：走 [BasicHudResources] 的失败记账路径
/// （glyphs 失败 + 各字体失败），最终字形表为空。
class _BrokenBundle extends AssetBundle {
  @override
  Future<ByteData> load(String key) async {
    throw FlutterError('测试资源包缺少 $key');
  }
}

/// 最小可用字形表：一个空字重，字形表非空但没有任何轮廓。
///
/// 用它（而不是真 rootBundle）是为了让 entry actions 组不依赖 1.68MB 真字形表 +
/// 26MB OTF + FontLoader 的真实 IO：本组要验的是“外壳把动作交给谁”，不是字形装载。
/// 缺字形时的绘制由 GlyphText 的 TextPainter 回退承担（glyph_font.dart:93-206 的说明），
/// 与 test/basic/ui_landscape_test.dart 用 GlyphFontSet.empty 直接渲染 HUD 的做法一致。
class _StubGlyphBundle extends AssetBundle {
  static const String _glyphTable =
      '{"light":{"units":1000,"ascent":1044,"descent":-282,"glyphs":{}}}';

  @override
  Future<ByteData> load(String key) async {
    throw FlutterError('测试资源包没有字体文件 $key');
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    if (key == basicGlyphTableAsset) {
      return _glyphTable;
    }
    if (key == basicLetteringAsset) {
      return '{}';
    }
    throw FlutterError('测试资源包缺少 $key');
  }
}

/// 永远不返回的资源包：用来停在“正在装载字形资源…”这一帧。
class _PendingBundle extends AssetBundle {
  final Completer<ByteData> _pending = Completer<ByteData>();

  @override
  Future<ByteData> load(String key) => _pending.future;
}

class _FakeConsentPorts implements ConsentPorts {
  ConsentRecord record = const ConsentRecord.empty();
  final List<ConsentRegion> sdkStarts = <ConsentRegion>[];
  int entered = 0;
  int exits = 0;
  int probes = 0;

  @override
  ConsentRecord readRecord() => record;

  @override
  void writeGrant(ConsentRegion region) {
    record = ConsentRecord(granted: true, region: region);
  }

  @override
  Future<ConsentRegion> probeRegion() async {
    probes += 1;
    return ConsentRegion.cn;
  }

  @override
  void startSdks(ConsentRegion region) {
    sdkStarts.add(region);
  }

  @override
  void enterBusiness() {
    entered += 1;
  }

  @override
  void exitApp() {
    exits += 1;
  }
}

/// 最小曲目/专辑样本：只要 id/title 与 songs 关系，够验“行 → 打开谁”。
SirenSong _song(String id, String title) => SirenSong(
      id: id,
      title: title,
      artist: '塞壬唱片',
      album: '专辑',
      albumId: 'album-1',
      cover: '',
      sourceUrl: 'https://example.invalid/$id.mp3',
      lyricUrl: '',
      durationMs: 180000,
    );

SirenAlbum _album() => SirenAlbum(
      id: 'album-1',
      name: '测试专辑',
      artist: '塞壬唱片',
      cover: '',
      songCount: 2,
      songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
    );

void main() {
  group('startup entry', () {
    testWidgets('boots the single controller exactly once and never gates the preview',
        (WidgetTester tester) async {
      final _FakeAudio audio = _FakeAudio();
      final _TrackingController controller = _TrackingController(audio: audio);
      final _FakeConsentPorts ports = _FakeConsentPorts();
      final ConsentGate gate = ConsentGate(ports);

      await tester.pumpWidget(BasicApp(
        controller: controller,
        audio: audio,
        gate: gate,
        bundle: _StubGlyphBundle(),
      ));
      await tester.pump();
      await tester.pump();

      // 92 的 bug：首屏停在 ConsentPage，onProceed 只置 _entered，boot 从未发生。
      expect(controller.bootCalls, 1);
      expect(controller.retryCalls, 0);
      // 首屏真的进了业务 HUD（不是 ConsentPage，也不是装载占位）。
      expect(find.byType(BasicHudSurface), findsOneWidget);

      // 预览不再拦 ConsentPage，也不 start()（probeRegion 是 start() 的第一个外部动作）。
      expect(find.byType(ConsentPage), findsNothing);
      expect(find.text(kCnConsentApprove), findsNothing);
      expect(ports.probes, 0);
      expect(ports.sdkStarts, isEmpty);
      expect(ports.entered, 0);
      expect(gate.snapshot.isProceeded, isFalse);

      // 注入方持有所有权：卸载时不 dispose 注入的 controller/audio。
      expect(audio.disposes, 0);
      await tester.pumpWidget(const SizedBox());
      expect(controller.disposeCalls, 0);
      expect(audio.disposes, 0);
    });

    testWidgets('rebuild and rotation neither boot twice nor rebuild dependencies',
        (WidgetTester tester) async {
      final _FakeAudio audio = _FakeAudio();
      final _TrackingController controller = _TrackingController(audio: audio);
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(BasicApp(
        controller: controller,
        audio: audio,
        bundle: _BrokenBundle(),
      ));
      await tester.pump();
      final State<BasicApp> before = tester.state<State<BasicApp>>(find.byType(BasicApp));

      // 横屏 -> 竖屏：同一个 State 只重建，不重建 controller/audio，也不二次 boot。
      await tester.binding.setSurfaceSize(const Size(1080, 1920));
      await tester.pump();
      // 再换一次 widget 配置（同类型、同 State）：didUpdateWidget 也不该重新 boot。
      await tester.pumpWidget(BasicApp(
        controller: controller,
        audio: audio,
        bundle: _BrokenBundle(),
      ));
      await tester.pump();

      final State<BasicApp> after = tester.state<State<BasicApp>>(find.byType(BasicApp));
      expect(identical(before, after), isTrue);
      expect(controller.bootCalls, 1);
      expect(controller.retryCalls, 0);
      expect(audio.disposes, 0);

      await tester.pumpWidget(const SizedBox());
      expect(controller.disposeCalls, 0);
    });

    testWidgets('boot failure is visible and retry uses controller.retry',
        (WidgetTester tester) async {
      final _FakeAudio audio = _FakeAudio();
      final _ThrowingBootController controller = _ThrowingBootController(audio: audio);

      await tester.pumpWidget(BasicApp(
        controller: controller,
        audio: audio,
        bundle: _BrokenBundle(),
      ));
      await tester.pump();

      expect(controller.bootCalls, 1);
      expect(find.textContaining(basicBootFailurePrefix), findsOneWidget);
      expect(find.textContaining('曲库炸了'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pump();

      // 重试只能走 retry()：真实 boot 有 _booted 幂等（替身不置 _booted，
      // 所以这里如果外壳错调 boot()，bootCalls 会变成 2，断言会抓住它）。
      expect(controller.retryCalls, 1);
      expect(controller.bootCalls, 1);
      expect(find.textContaining(basicBootFailurePrefix), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('glyph bundle still loading shows the loading line, not an empty HUD',
        (WidgetTester tester) async {
      final _FakeAudio audio = _FakeAudio();
      final _TrackingController controller = _TrackingController(audio: audio);

      await tester.pumpWidget(BasicApp(
        controller: controller,
        audio: audio,
        bundle: _PendingBundle(),
      ));
      await tester.pump();

      expect(find.text(basicResourceLoadingText), findsOneWidget);
      // 曲库那一路是并行的：资源没读完不影响 boot 已经发生。
      expect(controller.bootCalls, 1);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('missing glyph table is reported instead of rendering an empty HUD',
        (WidgetTester tester) async {
      final _FakeAudio audio = _FakeAudio();
      final _TrackingController controller = _TrackingController(audio: audio);

      await tester.pumpWidget(BasicApp(
        controller: controller,
        audio: audio,
        bundle: _BrokenBundle(),
      ));
      await tester.pump();

      // 字形表为空 = 没有可画轮廓（GlyphFontSet.empty 不允许当出货默认值）。
      expect(find.textContaining(basicGlyphMissingPrefix), findsOneWidget);
      // 失败项逐条保留，不是静默 fallback。
      expect(find.textContaining('Assets/fonts/misans-glyphs.json'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('self-owned controller is released on unmount, injected audio is not',
        (WidgetTester tester) async {
      // 只注入 audio（替身），controller 由 widget 自己创建：真 boot 会起 100ms ticker，
      // 若 unmount 没 dispose，flutter_test 会直接报 “A Timer is still pending”。
      // 注入 audio 同时钉住所有权边界：注入的那份不许被 widget dispose。
      //
      // 这里刻意不让 widget 自建 MethodChannelBasicAudio：flutter_test 没有平台 handler，
      // EventChannel 的 listen 会抛 MissingPluginException 并被测试框架记成异常，
      // 那样测到的是测试环境缺插件，而不是本 widget 的释放语义。自持 audio 的释放由
      // basic_app.dart dispose() 的 _ownsAudio 分支承担，真机路径由 94 构建/装机覆盖
      // （本原子 NOT_RUN）。
      final _FakeAudio audio = _FakeAudio();
      await tester.pumpWidget(BasicApp(audio: audio, bundle: _BrokenBundle()));
      await tester.pump();
      expect(find.textContaining(basicGlyphMissingPrefix), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(audio.disposes, 0);
    });
  });

  group('entry actions', () {
    /// 字形表非空 → 外壳渲染出 [BasicHudSurface]，命中动作才有落点。
    /// controller 仍是替身（不联网、不起 ticker），所以不受曲库影响。
    Future<_TrackingController> pumpShell(WidgetTester tester) async {
      final _FakeAudio audio = _FakeAudio();
      final _TrackingController controller = _TrackingController(audio: audio);
      await tester.pumpWidget(BasicApp(
        controller: controller,
        audio: audio,
        bundle: _StubGlyphBundle(),
      ));
      await tester.pump();
      await tester.pump();
      expect(find.byType(BasicHudSurface), findsOneWidget);
      return controller;
    }

    /// 直接走外壳交给 HUD 的那个回调（[BasicHudSurface.onAction] 是公开签名），
    /// 等价于点击某个热区，但不需要构造像素坐标。
    void fire(WidgetTester tester, String action) {
      tester.widget<BasicHudSurface>(find.byType(BasicHudSurface)).onAction(action);
    }

    testWidgets('search action feeds the real controller query', (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);

      fire(tester, '${basicSearchActionPrefix}周杰伦');
      await tester.pump();

      // setQuery 是 controller 的真实过滤入口（Qt/src/MusicSiren.cpp:100-124）。
      expect(controller.queries, <String>['周杰伦']);
      expect(find.textContaining(basicUnimplementedPrefix), findsNothing);

      // 空载荷是真实的“清空检索”（controller 自己对空串有分支），不是伪造。
      fire(tester, basicSearchActionPrefix);
      await tester.pump();
      expect(controller.queries, <String>['周杰伦', '']);

      // 裸 'search' 是 HUD 检索页签的真实动作（lib/hud/pages/chrome.dart:166）；
      // 输入层还没铺进预览，所以必须给可见反馈，绝不静默 no-op。
      fire(tester, 'search');
      await tester.pump();
      expect(find.textContaining('检索输入框尚未接线'), findsOneWidget);
      expect(controller.queries, <String>['周杰伦', '']);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('unimplemented clicks show visible feedback instead of a silent no-op',
        (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);

      fire(tester, 'settings');
      await tester.pump();
      // 设置页确实没接：给可见反馈，且绝不假装打开了设置。
      expect(find.textContaining('设置页尚未接入'), findsOneWidget);

      fire(tester, 'player:next');
      await tester.pump();
      // 已接入的动作真的到 controller，并且清掉上一条反馈。
      expect(controller.nextCalls, 1);
      expect(find.textContaining('设置页尚未接入'), findsNothing);

      fire(tester, 'music:like');
      await tester.pump();
      expect(find.textContaining(basicUnimplementedPrefix + 'music:like'), findsOneWidget);

      // 音量条有真实热区（player_bar.dart:529），但 BasicController 没有音量 API。
      fire(tester, 'player:volume-fraction:0.5');
      await tester.pump();
      expect(find.textContaining('音量调节尚未接入'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('open-all-siren returns to the full Siren library through the real controller API',
        (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);

      fire(tester, 'music:open-all-siren');
      await tester.pump();

      // archive 页「在资料库中打开 →」（archive_page.dart:255）在 94 已真接线到
      // BasicController.openSirenLibrary()（siren_controller.dart:292）。合并保留了这条
      // 真动作，所以这里必须证明它落到 controller，而不是变成一条"尚未接入"的提示。
      expect(controller.libraryOpens, 1);
      expect(find.textContaining('「全部歌曲」尚未接入'), findsNothing);
      // 也不许顺带伪造打开某张专辑/某首歌。
      expect(controller.openedAlbums, isEmpty);
      expect(controller.openedSongs, isEmpty);

      await tester.pumpWidget(const SizedBox());
    });

    /// 合并面：96 的分派结构 + 94 已上线的真实动作（详情播放、播放全部、选曲槽、
    /// 专辑列翻页、歌词行跳转、返回别名）。这些热区在原 94 树里都真的接上了
    /// controller，合并若只留 96 的"尚未接入"提示就是用户报的"点了没反应"。
    testWidgets('merged 94 wiring lands every real action on the single controller',
        (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);

      // 曲库首屏「播放全部」：落到列表第一条真实条目（专辑 0）。
      controller.stateOverride = BasicViewState(
        phase: BasicPhase.library,
        albums: <SirenAlbum>[_album()],
        songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
        catalogLoaded: true,
      );
      await tester.pump();
      fire(tester, 'music:play-loaded');
      await tester.pump();
      expect(controller.openedAlbums, <String>['album-1']);

      // 专辑列翻页 column-next：没有当前专辑时取第一张，仍是真实 openAlbum。
      fire(tester, 'column-next');
      await tester.pump();
      expect(controller.openedAlbums, <String>['album-1', 'album-1']);

      // 'music:slot:<i>'（archive_page.dart:311）与 music:index:<i> 共用一份下标。
      fire(tester, 'music:slot:2');
      await tester.pump();
      expect(controller.openedSongs, <String>['s2']);

      // 详情页主按钮 'music:play'（song_detail.dart:755）：当前曲目 → 真实 openSong。
      controller.stateOverride = BasicViewState(
        phase: BasicPhase.detail,
        album: _album(),
        song: _song('s1', '第一首'),
        songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
        durationMs: 180000,
        catalogLoaded: true,
      );
      await tester.pump();
      fire(tester, 'music:play');
      await tester.pump();
      expect(controller.openedSongs, <String>['s2', 's1']);
      expect(controller.toggleCalls, 0);

      // 没有当前曲目时退化为播放条语义的 toggle（仍只走唯一 controller）。
      controller.stateOverride = BasicViewState(
        phase: BasicPhase.detail,
        album: _album(),
        songs: <SirenSong>[_song('s1', '第一首')],
        catalogLoaded: true,
      );
      await tester.pump();
      fire(tester, 'music:play');
      await tester.pump();
      expect(controller.toggleCalls, 1);

      // 歌词行点击 'player:lyric-line:1'：按真实时间轴换算进度（90s / 180s = 0.5）。
      controller.stateOverride = BasicViewState(
        phase: BasicPhase.lyrics,
        song: _song('s1', '第一首'),
        durationMs: 180000,
        lyrics: const <BasicLyricLine>[
          BasicLyricLine(startMs: 0, text: '第一行'),
          BasicLyricLine(startMs: 90000, text: '第二行'),
        ],
        catalogLoaded: true,
      );
      await tester.pump();
      fire(tester, '${basicLyricLineActionPrefix}1');
      await tester.pump();
      expect(controller.seeks, <double>[0.5]);

      // 返回别名 'music:parent' 与 back 同一条 controller 路径。
      fire(tester, 'music:parent');
      await tester.pump();
      expect(controller.backCalls, 1);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('seek fraction is parsed from the payload, garbage payload is surfaced',
        (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);

      fire(tester, 'player:seek-fraction:0.25');
      await tester.pump();
      expect(controller.seeks, <double>[0.25]);

      fire(tester, 'player:seek-fraction:半首歌');
      await tester.pump();
      expect(controller.seeks, <double>[0.25]);
      expect(find.textContaining(basicUnimplementedPrefix), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('empty library open is reported, not treated as an opened row',
        (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);

      fire(tester, 'open');
      await tester.pump();

      expect(find.text(basicEmptyLibraryNotice), findsOneWidget);
      expect(controller.openedAlbums, isEmpty);
      expect(controller.openedSongs, isEmpty);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('library song row opens its song, album row opens its album',
        (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);
      controller.stateOverride = BasicViewState(
        phase: BasicPhase.library,
        albums: <SirenAlbum>[_album()],
        songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
        catalogLoaded: true,
      );
      await tester.pump();

      // items = [album(0), song s1(1), song s2(2)]（basic_hud.dart:39-66 的顺序）。
      fire(tester, 'music:index:0');
      await tester.pump();
      expect(controller.openedAlbums, <String>['album-1']);
      expect(controller.openedSongs, isEmpty);

      // 首屏的曲目行：此时 state.album == null，index 指回 state.songs。
      // 只看 album 的实现在这里会落进“尚未实现”——正是用户报的点击没反应。
      fire(tester, 'music:index:2');
      await tester.pump();
      expect(controller.openedSongs, <String>['s2']);
      expect(find.textContaining(basicUnimplementedPrefix), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('detail song row opens the album track it names', (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);
      controller.stateOverride = BasicViewState(
        phase: BasicPhase.detail,
        album: _album(),
        songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
        catalogLoaded: true,
      );
      await tester.pump();

      // 专辑详情：items 只来自 album.songs，index 指回 album.songs。
      fire(tester, 'music:index:1');
      await tester.pump();
      expect(controller.openedSongs, <String>['s2']);
      expect(controller.openedAlbums, isEmpty);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('index outside the list is surfaced, never an out-of-range open',
        (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);
      controller.stateOverride = BasicViewState(
        phase: BasicPhase.library,
        albums: <SirenAlbum>[_album()],
        songs: <SirenSong>[_song('s1', '第一首')],
        catalogLoaded: true,
      );
      await tester.pump();

      fire(tester, 'music:index:9');
      await tester.pump();
      expect(find.textContaining(basicUnimplementedPrefix), findsOneWidget);
      expect(controller.openedAlbums, isEmpty);
      expect(controller.openedSongs, isEmpty);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('partial resource failures stay visible instead of a silently broken HUD',
        (WidgetTester tester) async {
      // 字形表有一个字重（外壳照常渲染 HUD），但字体文件读不到：
      // BasicHudResources.load 只把失败记进 failures、从不抛错，
      // 所以外壳必须自己把 failures 显示出来（basic_hud_resources.dart:35-36 的契约）。
      final _TrackingController controller = await pumpShell(tester);

      expect(controller.bootCalls, 1);
      expect(find.textContaining(basicResourceFailurePrefix), findsOneWidget);
      expect(find.textContaining('font '), findsOneWidget);

      // 资源失败是状态，不是一次性提示：动作反馈出现时它必须还在，
      // 动作反馈消失后它也必须还在（否则一次点击就把失败静默抹掉了）。
      fire(tester, 'settings');
      await tester.pump();
      expect(find.textContaining('设置页尚未接入'), findsOneWidget);
      expect(find.textContaining(basicResourceFailurePrefix), findsOneWidget);

      fire(tester, 'player:next');
      await tester.pump();
      expect(controller.nextCalls, 1);
      expect(find.textContaining('设置页尚未接入'), findsNothing);
      expect(find.textContaining(basicResourceFailurePrefix), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
