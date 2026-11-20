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
import 'package:rhine_music_database/hud/input/hit_layer.dart';
import 'package:rhine_music_database/hud/input/key_router.dart' show HudAction;
import 'package:rhine_music_database/hud/input/text_input_overlay.dart';
import 'package:rhine_music_database/ui/layout/portrait_stage.dart';
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
  int playCalls = 0;
  int lyricsOpens = 0;
  int libraryOpens = 0;
  int allSirenOpens = 0;
  int backCalls = 0;
  int closeLyricsCalls = 0;

  /// 命中动作真正落到 controller 的证据（不是“点了就算”）。
  final List<String> queries = <String>[];
  final List<double> seeks = <double>[];
  final List<String> openedSongs = <String>[];
  final List<String> openedAlbums = <String>[];

  /// 行点击 = 纯选中（Qt/src/NativeHudMusic.cpp:47-91 的 selectResult/selectDirectory
  /// 都是 open=false）：只记列表下标，不打开、不播放。
  final List<int> selectedRows = <int>[];

  /// ←/→ 的方向（Qt/src/NativeHudController.cpp:650-662：目录内 navigateDirectory(±8)、
  /// 目录外 showSource(sourceOrder ±1)）——换列/换页，不打开、不播放。
  final List<int> columnDirections = <int>[];

  /// ↑/↓ 的方向（Qt `music.next(±1)`：资料库逐项选曲，**不是**播放器的 previous/next）。
  final List<int> stepDirections = <int>[];

  /// 只在这些动作测试里顶掉真实状态：外壳的分派必须按 state 的真实结构走
  /// （首屏单曲行的 index 指回 state.songs，专辑详情指回 album.songs）。
  BasicViewState? stateOverride;

  @override
  BasicViewState get state => stateOverride ?? super.state;

  /// 模拟真实 controller 的一次状态发布：外壳只靠 [ListenableBuilder] 监听
  /// [BasicController] 重绘，单纯改 [stateOverride] 不会触发重建。
  void publish(BasicViewState value) {
    stateOverride = value;
    notifyListeners();
  }

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
  Future<void> openSong(SirenSong song, {bool play = true}) async {
    openedSongs.add(song.id);
  }

  @override
  Future<void> selectLibraryRow(int row) async {
    selectedRows.add(row);
  }

  @override
  Future<void> stepLibrarySelection(int direction) async {
    stepDirections.add(direction);
  }

  @override
  Future<void> navigateColumn(int direction) async {
    columnDirections.add(direction);
  }

  @override
  Future<void> openAlbum(SirenAlbum album) async {
    openedAlbums.add(album.id);
  }

  /// 进专辑 = 换列（Qt/src/MusicLibrary.cpp:863-869 的 enterDirectory），不抽唱片。
  final List<String> enteredAlbums = <String>[];

  @override
  Future<void> enterAlbumColumn(SirenAlbum album, {bool play = false}) async {
    enteredAlbums.add(album.id);
  }

  /// 控制键回车走 NativeHudController.cpp:905-907 的 m_music->play()：
  /// 真实 controller.play()（幂等，已播不暂停），不是 toggle。
  @override
  Future<void> play() async {
    playCalls += 1;
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

  /// 94 当年的近似入口：只回完整曲库、不开目录。98 交付真实目录后它不再被入口调用，
  /// 计数留着是为了证明“没有退回近似”。
  @override
  Future<void> openSirenLibrary() async {
    libraryOpens += 1;
  }

  /// 98 的 Qt 真实虚拟目录入口（archive 页 'music:open-all-siren'，Qt/src/MusicSiren.cpp:193-246）。
  @override
  Future<void> openAllSirenSongs() async {
    allSirenOpens += 1;
  }

  @override
  Future<void> back() async {
    backCalls += 1;
  }

  /// 94 的歌词返回只关面板、不经过 back()（basic_app.dart 的 _popScope）；
  /// 单独计数才能证明系统返回键没有把这两个语义合并。
  @override
  Future<void> closeLyrics() async {
    closeLyricsCalls += 1;
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

/// 记录外壳向宿主发出的系统级调用（本组只关心 SystemNavigator.pop = 退出 App）。
List<MethodCall> _watchPlatformChannel(WidgetTester tester) {
  final List<MethodCall> calls = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async {
      calls.add(call);
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  return calls;
}

/// Android 系统返回键：平台侧向 'flutter/navigation' 发 popRoute，正是
/// test/ui/consent_test.dart:204-219 用的同一手法（tester.binding.handlePopRoute()
/// 是 @protected，测试里直接调会报 invalid_use_of_protected_member）。
/// 这里用固定次数的 pump 而不是 pumpAndSettle：HUD 的入场动画不会自行停下。
Future<void> _sendSystemBack(WidgetTester tester) async {
  final ByteData message =
      const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute'));
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    message,
    (ByteData? _) {},
  );
  await tester.pump();
  await tester.pump();
}

int _exitCalls(List<MethodCall> calls) => calls
    .where((MethodCall call) => call.method == 'SystemNavigator.pop')
    .length;

/// HUD 外面那一层 PopScope 的 canPop：false 表示系统返回键会在 App 内被吃掉。
bool _canPopAboveHud(WidgetTester tester) {
  final Finder finder = find.ancestor(
    of: find.byType(BasicHudSurface),
    matching: find.byWidgetPredicate((Widget widget) => widget is PopScope),
  );
  expect(finder, findsOneWidget);
  // 实例是 PopScope<Object?>；这里按裸类型取，与 test/ui/consent_test.dart:482-497
  // 读 consent 那层 canPop 的写法一致（find.byType(PopScope) 会把类型参数实例化成
  // dynamic，对不上实例的 Object?，所以用 byWidgetPredicate 而不是 byType）。
  return tester.widget<PopScope>(finder).canPop;
}

/// 资料库根（Qt 的 music.directory == null）：唯一允许系统返回键退出 App 的相位。
BasicViewState _libraryRootState() => const BasicViewState(
      phase: BasicPhase.library,
      catalogLoaded: true,
    );

/// 「在资料库中打开 →」之后的真实投影（siren_controller.dart:532-560 的
/// _openAllSirenDirectory）：目录打开时 phase 仍是 [BasicPhase.library]，
/// 只有 state.directory 变了 —— 只看 phase 判退出权正是本次要修的 bug。
///
/// [phase] 允许复刻「目录里再进详情/歌词」：Qt 的 directory 在详情里不会丢
/// （MusicDirectory.cpp:400-415 的 returnToDirectory），98 也照此保留。
BasicViewState _directoryState({
  BasicPhase phase = BasicPhase.library,
  SirenAlbum? album,
  List<BasicLyricLine> lyrics = const <BasicLyricLine>[],
  double durationMs = 0,
}) {
  final List<SirenSong> songs = <SirenSong>[
    _song('s1', '第一首'),
    _song('s2', '第二首'),
  ];
  return BasicViewState(
    phase: phase,
    songs: songs,
    album: album,
    durationMs: durationMs,
    lyrics: lyrics,
    directory: BasicDirectory(
      provider: sirenProvider,
      kind: 'playlist',
      id: sirenAllSongsId,
      key: sirenAllSongsKey,
      title: sirenAllSongsTitle,
      artist: sirenProviderLabel,
      cover: '',
      description: sirenAllSongsDescription,
      trackCount: songs.length,
      virtual: true,
      songs: songs,
      ids: <String>[for (final SirenSong song in songs) song.id],
      cursor: songs.length,
      index: 0,
    ),
    song: songs.first,
    status: '$sirenOpenedPrefix$sirenAllSongsTitle',
    catalogLoaded: true,
  );
}

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

    testWidgets('search:<query> payload still reaches controller.setQuery',
        (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);

      fire(tester, '$basicSearchActionPrefix周杰伦');
      await tester.pump();

      // setQuery 是 controller 的真实过滤入口（Qt/src/MusicSiren.cpp:91-124）。
      expect(controller.queries, <String>['周杰伦']);
      expect(find.textContaining(basicUnimplementedPrefix), findsNothing);

      // 空载荷是真实的“清空检索”（controller 自己对空串有分支），不是伪造。
      fire(tester, basicSearchActionPrefix);
      await tester.pump();
      expect(controller.queries, <String>['周杰伦', '']);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('bare search opens the real TextInputOverlay and typing feeds setQuery',
        (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);

      // Qt 里 Overlay 的 QML 对象常驻：输入层一直挂在树上，弹层关闭时只是不可见。
      expect(find.byType(TextInputOverlay), findsOneWidget);
      expect(find.byType(EditableText), findsNothing);

      fire(tester, HudAction.search);
      await tester.pump();

      // 'search' 是弹层开关（Qt/src/NativeHudController.cpp:684-687），
      // 不再是“尚未接线”的可见反馈；输入框是真控件。
      expect(find.byType(EditableText), findsOneWidget);
      // 打开弹层本身不发检索：Qt openModal 只把 m_music->keyword 灌进输入框
      // （NativeHudController.cpp:117-119），不调 m_music->search。
      expect(controller.queries, isEmpty);

      // Qt/src/NativeHud.cpp:140-158（检索分支 :154-157）+ :184-186。默认测试窗口 800x600 →
      // stageScale = 600/1080、舞台宽 = 800/stageScale = 1440 →
      // modalWidth 760、left 621、inputX 674、inputY 302、inputWidth 654。
      final TextInputOverlay overlay =
          tester.widget<TextInputOverlay>(find.byType(TextInputOverlay));
      expect(overlay.state.modal, 'search');
      expect(overlay.state.stageScale, closeTo(600 / 1080, 1e-12));
      expect(overlay.state.inputX, 674.0);
      expect(overlay.state.inputY, 302.0);
      expect(overlay.state.inputWidth, 654.0);
      expect(overlay.state.modalOpacity, 1.0);
      // 钉住字体族接线本身：Qt Overlay.qml:532 font.family: rhineFontFamily，
      // Flutter 侧同名字族由 basic_hud_resources.dart:87 注册（常量 :32）。
      expect(overlay.state.rhineFontFamily, basicRhineMiSansFamily);

      // 输入层必须落在窗口坐标系（逻辑像素 = 舞台值 × stageScale）。
      // 若被塞进 PortraitStage 的 Transform.scale 里会再乘一次：384.4 → 213.6。
      final double s = 600 / 1080;
      expect(
        tester.getRect(find.byType(EditableText)).left,
        closeTo((674 + 18) * s, 0.5),
      );

      // 组合态（拼音未上屏）不得提交：committedText 剥掉 composing 段得到 ''，
      // 与 TextCommitTracker 的基线相同 → 返回 null，不碰 ports.query。
      await tester.showKeyboard(find.byType(EditableText));
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'zhoujielun',
        selection: TextSelection.collapsed(offset: 10),
        composing: TextRange(start: 0, end: 10),
      ));
      await tester.pump();
      expect(controller.queries, isEmpty);

      // 上屏（composing 清掉）才提交：TextInputPorts.query → setQuery。
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '周杰伦',
        selection: TextSelection.collapsed(offset: 3),
      ));
      await tester.pump();
      expect(controller.queries, <String>['周杰伦']);

      // Esc：Overlay.qml:549 → rhine.action("close-modal") → 弹层收起（输入框不再可见）。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(EditableText), findsNothing);
      expect(
        tester.widget<TextInputOverlay>(find.byType(TextInputOverlay)).state.modal,
        '',
      );
      expect(controller.queries, <String>['周杰伦']);

      // 再开一次：输入框应该被 state.query 重新播种（这里 controller 的 query 仍是空），
      // 然后回车必须重新提交——Qt Engine::searchAccepted 无 Control 时重新 query(text)
      // （Qt/src/Engine.cpp:1006-1012；NativeHud::setQuery 不去重，NativeHudController.cpp:145-163）。
      fire(tester, HudAction.search);
      await tester.pump();
      expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, '');
      await tester.enterText(find.byType(EditableText), 'a');
      await tester.pump();
      expect(controller.queries, <String>['周杰伦', 'a']);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(controller.queries, <String>['周杰伦', 'a', 'a']);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('control+return 走真实 play()（幂等），不落成 toggle 也不落成检索',
        (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);

      fire(tester, HudAction.search);
      await tester.pump();
      await tester.enterText(find.byType(EditableText), '摩天轮');
      await tester.pump();
      expect(controller.queries, <String>['摩天轮']);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      // Qt 这条分支是 m_music->play()（NativeHudController.cpp:905-907）。161 把
      // 「只有 togglePlay」的判断撤回：siren_controller.dart:965 的 play() 是幂等
      // 播放（已在播就不动，绝不变成暂停），就是这条分支的真实对应物。
      expect(find.textContaining('控制键回车尚未接入'), findsNothing);
      expect(controller.playCalls, 1);
      expect(controller.toggleCalls, 0);
      expect(controller.queries, <String>['摩天轮']);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('portrait overlay consumes the single PortraitStage geometry',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 900);
      tester.view.devicePixelRatio = 1.0;
      // 真机上 status bar 会给竖屏舞台一个下移原点（originY）；这里用 safe.top=48
      // 让 originY > 0，检索框的 y 才会真的走到「302 + originY」这条折算上。
      tester.view.padding = const FakeViewPadding(top: 48.0);
      addTearDown(tester.view.reset);

      final _TrackingController controller = await pumpShell(tester);
      fire(tester, HudAction.search);
      // 竖屏几何体由 PortraitStage 在首帧后交给外壳：多 pump 让接管落地。
      await tester.pump();
      await tester.pump();

      final TextInputOverlay overlay =
          tester.widget<TextInputOverlay>(find.byType(TextInputOverlay));
      // 唯一 scale 来自 PortraitStage 自己（lib/ui/layout/portrait_bands.dart:776）：
      // 600 / 1080。自己重算一份会是 1.0，叠两次会是 0.3086。
      final StageGeometry geometry =
          StageGeometryScope.of(tester.element(find.byType(BasicHudSurface)));
      expect(overlay.state.stageScale, geometry.stageScale);
      expect(overlay.state.stageScale, closeTo(600 / 1080, 1e-12));
      // 竖屏舞台宽恒为 1080（portraitStageWidthConstant）→ 检索框 314 / 654；
      // y = Qt 的 302 + 舞台原点 originY（状态栏带），否则会盖到状态栏上。
      expect(overlay.state.inputX, 314.0);
      expect(overlay.state.inputWidth, 654.0);
      expect(geometry.originY, greaterThan(0));
      expect(overlay.state.inputY, 302.0 + geometry.originY);

      final double s = 600 / 1080;
      expect(
        tester.getRect(find.byType(EditableText)).left,
        closeTo((314 + 18) * s, 0.5),
      );

      await tester.enterText(find.byType(EditableText), '本地');
      await tester.pump();
      expect(controller.queries, <String>['本地']);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('unimplemented clicks show visible feedback instead of a silent no-op',
        (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);

      fire(tester, 'music:unknown-action');
      await tester.pump();
      // 未接入的动作必须给可见反馈、绝不静默 no-op。
      // （`music:login` 已改为开登录弹层（provider/登录接线），所以这里换一个
      //  仍未接入的动作，守住同一条契约。）
      expect(find.textContaining(basicUnimplementedPrefix), findsOneWidget);

      fire(tester, 'player:next');
      await tester.pump();
      // 已接入的动作真的到 controller，并且清掉上一条反馈。
      expect(controller.nextCalls, 1);
      expect(find.textContaining(basicUnimplementedPrefix), findsNothing);

      fire(tester, 'music:like');
      await tester.pump();
      expect(find.textContaining('${basicUnimplementedPrefix}music:like'), findsOneWidget);

      // 音量条有真实热区（player_bar.dart:529），但 BasicController 没有音量 API。
      fire(tester, 'player:volume-fraction:0.5');
      await tester.pump();
      expect(find.textContaining('音量调节尚未接入'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('open-all-siren opens the Qt all-songs virtual directory through the reviewed API',
        (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);

      fire(tester, 'music:open-all-siren');
      await tester.pump();

      // archive 页「在资料库中打开 →」（archive_page.dart:255 = Qt/src/NativeHud.cpp:426）
      // 在 Qt 里走 openSirenAllSongs()（NativeHudMusic.cpp:365-369 → MusicSiren.cpp:193-246），
      // 98 的功能就是把这个虚拟目录做出来。所以入口必须落到 openAllSirenSongs()，
      // 而不是 94 当年没有目录 API 时的近似 openSirenLibrary()。
      expect(controller.allSirenOpens, 1);
      expect(controller.libraryOpens, 0);
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

      // 曲库首屏（默认列 = 全部歌曲 lane 3）「播放全部」：落到**该列第一条曲目**。
      // Qt 的列表只列 selectedLane 这一列（MusicLibrary.cpp:195-207 sourceItems(lane)），
      // 专辑与曲目不再是同一列里混排的一句“取第一条”。
      controller.stateOverride = BasicViewState(
        phase: BasicPhase.library,
        albums: <SirenAlbum>[_album()],
        songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
        catalogLoaded: true,
      );
      await tester.pump();
      fire(tester, 'music:play-loaded');
      await tester.pump();
      expect(controller.openedSongs, <String>['s1'],
          reason: '全部歌曲列的第一条是曲目 s1');
      expect(controller.openedAlbums, isEmpty,
          reason: '专辑在 lane 4，不属于全部歌曲列');

      // ←/→ 是换资料库列：Qt NativeHudController.cpp:658-662
      // `showSource(sourceOrder().at(wrap(index ± 1, size)))`——不打开专辑、不播放。
      fire(tester, 'column-next');
      await tester.pump();
      expect(controller.columnDirections, <int>[1]);
      expect(controller.openedAlbums, isEmpty, reason: 'column-next 换列，不是翻专辑');
      expect(controller.openedSongs, <String>['s1'], reason: '换列不播放');

      // 'music:slot:<i>'（archive_page.dart:311）与 music:index:<i> 共用一份下标，
      // 且都是**只选中**（Qt NativeHudMusic.cpp:47-66 selectResult(..., false)）。
      fire(tester, 'music:index:1');
      await tester.pump();
      expect(controller.selectedRows, <int>[1]);
      expect(controller.openedSongs, <String>['s1'], reason: '点行不播放');
      expect(controller.openedAlbums, isEmpty, reason: '点行不打开');

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
      expect(controller.openedSongs, <String>['s1', 's1']);
      expect(controller.toggleCalls, 0);

      // 没有当前曲目时走 controller.play()（NativeHudController.cpp:905-907 的
      // m_music->play()；161 撤回了「用 toggle 顶替」的旧实现），仍只走唯一 controller。
      controller.stateOverride = BasicViewState(
        phase: BasicPhase.detail,
        album: _album(),
        songs: <SirenSong>[_song('s1', '第一首')],
        catalogLoaded: true,
      );
      await tester.pump();
      fire(tester, 'music:play');
      await tester.pump();
      expect(controller.playCalls, 1);
      expect(controller.toggleCalls, 0);

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

    testWidgets('library row click only selects; open opens the selected row',
        (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);

      // 全部歌曲列（lane 3）：列表 = 该列曲目行。点行只写选中身份
      // （Qt/src/NativeHudMusic.cpp:47-66 selectResult(raw, lane, false)）。
      controller.stateOverride = BasicViewState(
        phase: BasicPhase.library,
        albums: <SirenAlbum>[_album()],
        songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
        catalogLoaded: true,
      );
      await tester.pump();
      fire(tester, 'music:index:1');
      await tester.pump();
      expect(controller.selectedRows, <int>[1]);
      expect(controller.openedSongs, isEmpty, reason: '点行不播放');
      expect(controller.openedAlbums, isEmpty, reason: '点行不打开');
      expect(find.textContaining(basicUnimplementedPrefix), findsNothing);

      // 全部专辑列（lane 4）：列表 = 专辑行；行号按**本列**算，不会串到曲目列。
      controller.stateOverride = BasicViewState(
        phase: BasicPhase.library,
        selectedLane: 4,
        albums: <SirenAlbum>[_album()],
        songs: <SirenSong>[_song('s1', '第一首')],
        catalogLoaded: true,
      );
      await tester.pump();
      fire(tester, 'music:index:0');
      await tester.pump();
      expect(controller.selectedRows, <int>[1, 0]);
      expect(controller.openedAlbums, isEmpty, reason: '点专辑行也不打开');

      // 真正打开走 'open'（Qt `music:open`）。专辑行不是 song：Qt
      // MusicLibrary.cpp:863-869 只进目录（enterDirectory），**不抽唱片**。
      controller.stateOverride = BasicViewState(
        phase: BasicPhase.library,
        selectedLane: 4,
        albums: <SirenAlbum>[_album()],
        songs: <SirenSong>[_song('s1', '第一首')],
        selection: const BasicSelection(kind: 'album', id: 'album-1'),
        catalogLoaded: true,
      );
      await tester.pump();
      fire(tester, 'open');
      await tester.pump();
      expect(controller.enteredAlbums, <String>['album-1']);
      expect(controller.openedAlbums, isEmpty, reason: '进专辑列不抽唱片');
      expect(controller.openedSongs, isEmpty);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('detail row click selects; open opens the album track it names',
        (WidgetTester tester) async {
      final _TrackingController controller = await pumpShell(tester);
      controller.stateOverride = BasicViewState(
        phase: BasicPhase.detail,
        album: _album(),
        songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
        catalogLoaded: true,
      );
      await tester.pump();

      // 专辑详情：items 只来自 album.songs，item.index 指回 album.songs。
      fire(tester, 'music:index:1');
      await tester.pump();
      expect(controller.selectedRows, <int>[1]);
      expect(controller.openedSongs, isEmpty, reason: '点行只选中');

      // 打开：Qt music:open → selectResult(..., true) / detail，
      // 基础版 'open' 按选中身份落到 openSong(album.songs[index])。
      controller.stateOverride = BasicViewState(
        phase: BasicPhase.detail,
        album: _album(),
        song: _song('s2', '第二首'),
        songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
        selection: const BasicSelection(kind: 'song', id: 's2'),
        catalogLoaded: true,
      );
      await tester.pump();
      fire(tester, 'open');
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
      fire(tester, 'music:unknown-action');
      await tester.pump();
      expect(find.textContaining(basicUnimplementedPrefix), findsOneWidget);
      expect(find.textContaining(basicResourceFailurePrefix), findsOneWidget);

      fire(tester, 'player:next');
      await tester.pump();
      expect(controller.nextCalls, 1);
      expect(find.textContaining(basicUnimplementedPrefix), findsNothing);
      expect(find.textContaining(basicResourceFailurePrefix), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });

  /// 系统返回键 = Android 的 popRoute。Qt 的返回键由 HUD 自己消费：
  /// Qt/src/NativeHudController.cpp:643-654 —— 目录打开时走 returnToDirectory()/
  /// leaveDirectory() 后直接 return，只有资料库根才冒泡到宿主退出。
  /// Flutter 侧对应的判据是 PopScope.canPop（routes.dart:2034-2042 的 popDisposition：
  /// 只要有 PopScope canPop == false 就是 doNotPop，navigator.dart 的 maybePop 会消费掉
  /// 这次返回、不再冒泡到 SystemNavigator.pop）。
  group('system back', () {
    Future<_TrackingController> pumpShell(
      WidgetTester tester, {
      BasicViewState? initial,
    }) async {
      final _FakeAudio audio = _FakeAudio();
      final _TrackingController controller = _TrackingController(audio: audio);
      // 首帧就带真实状态：canPop 由首帧的 state 决定，晚一帧会把断言搬到
      // “重建之后”，反而测不到首帧行为。
      controller.stateOverride = initial;
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

    testWidgets('only the library root lets the system back leave the app',
        (WidgetTester tester) async {
      final List<MethodCall> platformCalls = _watchPlatformChannel(tester);
      final _TrackingController controller = await pumpShell(tester);

      // 启动相位（boot）不是资料库根：返回被吃掉，但既不退 App，也不假装 back()。
      expect(_canPopAboveHud(tester), isFalse);
      await _sendSystemBack(tester);
      expect(_exitCalls(platformCalls), 0);
      expect(controller.backCalls, 0);
      expect(controller.closeLyricsCalls, 0);

      // 资料库根（directory == null）是唯一能让返回键冒泡到宿主的相位。
      controller.publish(_libraryRootState());
      await tester.pump();
      expect(_canPopAboveHud(tester), isTrue);

      await _sendSystemBack(tester);
      expect(_exitCalls(platformCalls), 1);
      // 退出是宿主的事，不是 controller.back() 的近似。
      expect(controller.backCalls, 0);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an open directory consumes the system back and keeps the app alive',
        (WidgetTester tester) async {
      final List<MethodCall> platformCalls = _watchPlatformChannel(tester);
      final _TrackingController controller =
          await pumpShell(tester, initial: _libraryRootState());
      final State<BasicApp> shell =
          tester.state<State<BasicApp>>(find.byType(BasicApp));

      // 「在资料库中打开 →」后的真实投影：phase 仍是 library，只多出 directory。
      controller.publish(_directoryState());
      await tester.pump();
      expect(_canPopAboveHud(tester), isFalse);

      await _sendSystemBack(tester);

      // 关键回归：修前 canPop 只看 phase（library == true），这里会直接
      // SystemNavigator.pop 退出 App，用户就丢了刚打开的目录。
      expect(_exitCalls(platformCalls), 0);
      expect(controller.backCalls, 1);
      expect(controller.closeLyricsCalls, 0);

      // 留在 App 内：HUD 还在、State 还是同一个、注入的 controller 没有被释放重建。
      expect(find.byType(BasicHudSurface), findsOneWidget);
      expect(
        identical(tester.state<State<BasicApp>>(find.byType(BasicApp)), shell),
        isTrue,
      );
      expect(controller.disposeCalls, 0);

      // 退回资料库根之后，退出权才回到系统。
      controller.publish(_libraryRootState());
      await tester.pump();
      expect(_canPopAboveHud(tester), isTrue);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('detail keeps its in-app back and never exits',
        (WidgetTester tester) async {
      final List<MethodCall> platformCalls = _watchPlatformChannel(tester);
      final _TrackingController controller = await pumpShell(
        tester,
        initial: BasicViewState(
          phase: BasicPhase.detail,
          album: _album(),
          songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
          durationMs: 180000,
          catalogLoaded: true,
        ),
      );

      expect(_canPopAboveHud(tester), isFalse);
      await _sendSystemBack(tester);
      expect(_exitCalls(platformCalls), 0);
      // 94 已上线的详情返回：一次 controller.back()（controller 自己清 _album）。
      expect(controller.backCalls, 1);
      expect(controller.closeLyricsCalls, 0);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('lyrics keeps closing the panel instead of calling back',
        (WidgetTester tester) async {
      final List<MethodCall> platformCalls = _watchPlatformChannel(tester);
      final _TrackingController controller = await pumpShell(
        tester,
        initial: BasicViewState(
          phase: BasicPhase.lyrics,
          song: _song('s1', '第一首'),
          durationMs: 180000,
          lyrics: const <BasicLyricLine>[
            BasicLyricLine(startMs: 0, text: '第一行'),
          ],
          catalogLoaded: true,
        ),
      );

      expect(_canPopAboveHud(tester), isFalse);
      await _sendSystemBack(tester);
      expect(_exitCalls(platformCalls), 0);
      // 歌词返回只关面板（_phaseBeforeLyrics 由 controller 恢复），不经过 back()。
      expect(controller.closeLyricsCalls, 1);
      expect(controller.backCalls, 0);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('detail inside an open directory still dispatches exactly one back',
        (WidgetTester tester) async {
      final List<MethodCall> platformCalls = _watchPlatformChannel(tester);
      final _TrackingController controller = await pumpShell(
        tester,
        initial: _directoryState(
          phase: BasicPhase.detail,
          album: _album(),
          durationMs: 180000,
        ),
      );

      expect(_canPopAboveHud(tester), isFalse);
      await _sendSystemBack(tester);
      expect(_exitCalls(platformCalls), 0);
      // 目录 + 详情两个条件同时成立时不能重复分派：Qt 里这也是同一次 back
      // （NativeHudController.cpp:644-652 目录分支里的 returnToDirectory）。
      expect(controller.backCalls, 1);
      expect(controller.closeLyricsCalls, 0);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
