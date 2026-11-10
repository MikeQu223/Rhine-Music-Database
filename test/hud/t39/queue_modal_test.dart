// T39-W2 / QueueModal 1:1 Qt 语义验收测试（先写后实现，全程不执行）。
//
// 唯一真值来源：Qt/src/PlaybackQueueCard.h（VisibleRows=7 / Model / Canvas 签名）、
// Qt/src/PlaybackQueueCard.cpp:6-107（maximumOffset :6-8、paint :11-107，全部绘制与命中逐条 1:1）、
// Qt/src/NativeHudPlayer.cpp:45-75（bounds 高 836 与 canvas → HUD 原语转发）、
// Qt/src/NativeHud.cpp:48-76（fit 二分 + 省略号）、:102-109（hit 仅六键，无 fixed）、
// Qt/src/NativeHud.cpp:140-158（modalBounds：1920 宽 → (330,122,1260,836)）、
// Qt/src/NativeHudInput.cpp:76-80（队列唯一滚动实现：offset clamp；Qt 无拖动排序）、
// Qt/src/MusicData.cpp:148-158（pad / time）、Qt/src/MusicData.h:17（pad 缺省 width=2）、
// Qt/tests/NativeHudChecks.cpp:1333-1437（队列卡片回归：几何 / 模式 / 滚动 / 命中不重叠 / 空队列）。
// 断言口径：精确命令形状 + 精确几何 + 相对顺序，禁止集合化/排序化比较。
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/queue_modal.dart';

// ── 调色板：Qt/src/PlaybackQueueCard.cpp:15-20 ──────────────────────────────
const List<double> inkLight = <double>[0.145, 0.176, 0.153, 1.0];
const List<double> inkDark = <double>[0.93, 0.94, 0.88, 1.0];
const List<double> mutedLight = <double>[0.41, 0.44, 0.39, 1.0];
const List<double> mutedDark = <double>[0.68, 0.71, 0.64, 1.0];
const List<double> lineLight = <double>[0.79, 0.80, 0.74, 1.0];
const List<double> lineDark = <double>[0.31, 0.35, 0.29, 1.0];
const List<double> selectedLight = <double>[0.90, 0.90, 0.83, 1.0];
const List<double> selectedDark = <double>[0.24, 0.28, 0.22, 1.0];
const List<double> amber = <double>[0.83, 0.64, 0.27, 1.0];

/// 只读度量替身：宽度 = UTF-16 code unit 数 × unit，与 Glyphs::width 的
/// 逐 QChar 累加同构；队列卡片只用得到 width（Canvas::fit）。
class UnitGlyphs implements QueueModalGlyphs {
  const UnitGlyphs({this.unit = 1.0});

  final double unit;

  @override
  double width(String value, double size, String weight) => value.length * unit;
}

/// 记录度量顺序的替身，用于证明 fit 的二分探测序列与 Qt 相同。
class RecordingGlyphs implements QueueModalGlyphs {
  RecordingGlyphs({this.unit = 1.0});

  final double unit;
  final List<String> widthCalls = <String>[];

  @override
  double width(String value, double size, String weight) {
    widthCalls.add(value);
    return value.length * unit;
  }
}

// ── 只读便捷读取器 ────────────────────────────────────────────────────────
List<List<Object?>> commandsOf(QueueModalDrawing drawing, String op) =>
    drawing.commands.where((List<Object?> c) => c[0] == op).toList();

List<String> textValues(QueueModalDrawing drawing) => drawing.commands
    .where((List<Object?> c) => c[0] == 'text')
    .map((List<Object?> c) => c[1] as String)
    .toList();

List<String> hitActions(QueueModalDrawing drawing) =>
    drawing.hits.map((Map<String, Object?> h) => h['action'] as String).toList();

Map<String, Object?> hitOf(QueueModalDrawing drawing, String action) =>
    drawing.hits.firstWhere((Map<String, Object?> h) => h['action'] == action);

List<Map<String, Object?>> hitsOf(QueueModalDrawing drawing, String action) =>
    drawing.hits.where((Map<String, Object?> h) => h['action'] == action).toList();

/// 深比较：命令里的颜色是 List<double>，Dart 的 List 用引用相等。
bool _deepEquals(Object? a, Object? b) {
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i += 1) {
      if (!_deepEquals(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }
  return a == b;
}

bool _sameList(List<Object?> a, List<Object?> b) => _deepEquals(a, b);

int indexOfCommand(QueueModalDrawing drawing, List<Object?> probe) {
  final int index = drawing.commands.indexWhere((List<Object?> c) => _sameList(c, probe));
  expect(index, isNonNegative, reason: 'expected command in frame');
  return index;
}

/// 逐条比较整帧命令，失败时打印首个差异下标，便于定位顺序错误。
void expectCommands(QueueModalDrawing drawing, List<List<Object?>> expected) {
  expect(drawing.commands.length, expected.length, reason: 'command count');
  for (int i = 0; i < expected.length; i += 1) {
    expect(_sameList(drawing.commands[i], expected[i]), isTrue,
        reason: 'command #' + i.toString() + ' expected ' + expected[i].toString() +
            ' actual ' + drawing.commands[i].toString());
  }
}

void expectHits(QueueModalDrawing drawing, List<Map<String, Object?>> expected) {
  expect(drawing.hits.length, expected.length, reason: 'hit count');
  for (int i = 0; i < expected.length; i += 1) {
    expect(drawing.hits[i], expected[i], reason: 'hit #' + i.toString());
  }
}

Map<String, Object?> hit(String action, String label, double x, double y, double width, double height) =>
    <String, Object?>{
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'action': action,
      'label': label,
    };

void main() {
  // 基准面板：bounds=(0,0,1006,836) → 卡片 x=53、width=900（Qt 卡内 x=bounds.x+53、
  // width=bounds.width-106）；900×0.58=522、900×0.42=378、900×0.65=585、
  // 900×0.68=612、900×0.32=288 在 IEEE754 下均为精确值，派生几何可逐字书写。
  const QueueModalRect panel = QueueModalRect(0.0, 0.0, 1006.0, 836.0);

  group('常量与纯函数（Qt PlaybackQueueCard.h:9、PlaybackQueueCard.cpp:6-8、MusicData.cpp:148-158）', () {
    test('可视行数为 7（Qt PlaybackQueueCard::VisibleRows）', () {
      expect(queueModalVisibleRows, 7);
    });

    test('maximumOffset 允许最后一首置顶：max(0, count-1)', () {
      expect(queueModalMaximumOffset(0), 0);
      expect(queueModalMaximumOffset(1), 0);
      expect(queueModalMaximumOffset(2), 1);
      expect(queueModalMaximumOffset(7), 6);
      expect(queueModalMaximumOffset(100), 99);
    });

    test('pad 默认两位右补零，宽度可调（Qt MusicData::pad）', () {
      expect(queueModalPad(1), '01');
      expect(queueModalPad(9), '09');
      expect(queueModalPad(10), '10');
      expect(queueModalPad(100), '100');
      expect(queueModalPad(1, 4), '0001');
    });

    test('time：duration<=0 显示「暂无」，否则 mm:ss（Qt MusicData::time）', () {
      expect(queueModalTime(const QueueModalTrack()), '暂无');
      expect(queueModalTime(const QueueModalTrack(duration: -1)), '暂无');
      expect(queueModalTime(const QueueModalTrack(duration: 1000)), '00:01');
      expect(queueModalTime(const QueueModalTrack(duration: 59999)), '00:59');
      expect(queueModalTime(const QueueModalTrack(duration: 60000)), '01:00');
      expect(queueModalTime(const QueueModalTrack(duration: 65000)), '01:05');
      // 分钟不封顶：Qt 用 int(duration/60000) + pad(width=2) 拼接。
      expect(queueModalTime(const QueueModalTrack(duration: 3600000)), '60:00');
    });
  });

  group('空队列整帧：23 条命令 / 5 条命中（Qt PlaybackQueueCard.cpp:97-106）', () {
    late QueueModalDrawing drawing;
    setUp(() {
      drawing = renderQueueModal(
        const QueueModalState(bounds: panel),
        const UnitGlyphs(),
      );
    });

    test('整帧命令逐条相等（顺序即 Qt append 顺序）', () {
      final List<List<Object?>> expected = <List<Object?>>[
        // label("RHINE LAB / MUSIC DATABASE / AUDIO TERMINAL", x, y+37, 11, width-220, true)
        <Object?>['text', 'RHINE LAB / MUSIC DATABASE / AUDIO TERMINAL', 53.0, 37.0, 11.0, 'regular', 0, mutedLight],
        // action({x+width-167, y+18, 167, 54}, "← 返回", "close-modal")：未激活不画底
        <Object?>['text', '← 返回', 798.0, 30.0, 14.0, 'regular', 0, inkLight],
        // label("Now Playing", x, y+91, 38, width*0.5, false, "demibold")
        <Object?>['text', 'Now Playing', 53.0, 91.0, 38.0, 'demibold', 0, inkLight],
        <Object?>['text', '播放队列 / SESSION TRACKS', 53.0, 147.0, 13.0, 'regular', 0, mutedLight],
        // current 为空 → 「等待音轨 / STANDBY」
        <Object?>['text', '等待音轨 / STANDBY', 575.0, 98.0, 10.0, 'regular', 0, mutedLight],
        // current.value("title").toString("暂无播放歌曲")
        <Object?>['text', '暂无播放歌曲', 575.0, 116.0, 18.0, 'demibold', 0, inkLight],
        // artist 为空仍发一条空文本（Qt label 无条件 canvas.text）
        <Object?>['text', '', 575.0, 143.0, 11.0, 'regular', 0, mutedLight],
        <Object?>['text', '播放队列  0', 53.0, 194.0, 20.0, 'demibold', 0, inkLight],
        // 空队列不画「清空队列」
        <Object?>['fill', inkLight, 53.0, 233.0, 900.0, 2.0],
        <Object?>['text', 'PLAYBACK MODE / 播放模式', 53.0, 247.0, 10.0, 'regular', 0, mutedLight],
        <Object?>['text', '顺序播放', 65.0, 281.0, 14.0, 'regular', 0, inkLight],
        <Object?>['text', '列表循环', 292.0, 281.0, 14.0, 'regular', 0, inkLight],
        <Object?>['text', '单曲循环', 519.0, 281.0, 14.0, 'regular', 0, inkLight],
        <Object?>['text', '随机播放', 746.0, 281.0, 14.0, 'regular', 0, inkLight],
        <Object?>['fill', lineLight, 53.0, 322.0, 900.0, 1.0],
        <Object?>['text', '#', 63.0, 334.0, 10.0, 'regular', 0, mutedLight],
        <Object?>['text', '曲目 / TRACK', 97.0, 334.0, 10.0, 'regular', 0, mutedLight],
        <Object?>['text', '时长', 853.0, 334.0, 10.0, 'regular', 0, mutedLight],
        // 空态
        <Object?>['text', '播放队列为空', 83.0, 476.0, 24.0, 'demibold', 0, inkLight],
        <Object?>['text', '从音乐资料库添加歌曲，开启下一段音乐。', 83.0, 523.0, 15.0, 'regular', 0, mutedLight],
        <Object?>['text', '清空仅移除待播歌曲，当前歌曲继续播放。', 53.0, 768.0, 11.0, 'regular', 0, mutedLight],
        <Object?>['text', '0–0 / 0  · 滚轮浏览', 665.0, 768.0, 11.0, 'regular', 0, mutedLight],
        <Object?>['text', '', 53.0, 800.0, 11.0, 'regular', 0, mutedLight],
      ];
      expectCommands(drawing, expected);
    });

    test('命中只有返回与四个模式键，六键无 fixed', () {
      expectHits(drawing, <Map<String, Object?>>[
        hit('close-modal', '← 返回', 786.0, 18.0, 167.0, 54.0),
        hit('player:mode:off', '顺序播放', 53.0, 269.0, 219.0, 40.0),
        hit('player:mode:all', '列表循环', 280.0, 269.0, 219.0, 40.0),
        hit('player:mode:one', '单曲循环', 507.0, 269.0, 219.0, 40.0),
        hit('player:mode:shuffle', '随机播放', 734.0, 269.0, 219.0, 40.0),
      ]);
    });

    test('无封面时不发 image 命令', () {
      expect(drawing.commands.where((List<Object?> c) => c[0] == 'image'), isEmpty);
    });

    test('status 为空仍发一条空文本（对齐 Qt 无条件 label）', () {
      final List<List<Object?>> texts = commandsOf(drawing, 'text');
      expect((texts.last[1] as String), '');
      expect(texts.last[2], 53.0);
      expect(texts.last[3], 800.0);
    });
  });

  group('单曲当前行整帧：30 条命令 / 7 条命中（Qt PlaybackQueueCard.cpp:11-107）', () {
    late QueueModalDrawing drawing;
    setUp(() {
      drawing = renderQueueModal(
        const QueueModalState(
          bounds: panel,
          tracks: <QueueModalTrack>[
            QueueModalTrack(title: 'A', artist: 'B', duration: 65000),
          ],
          current: QueueModalTrack(title: 'A', artist: 'B', duration: 65000),
          mode: 'one',
          status: '同步中',
          currentIndex: 0,
          playing: true,
        ),
        const UnitGlyphs(),
      );
    });

    test('整帧命令逐条相等', () {
      final List<List<Object?>> expected = <List<Object?>>[
        <Object?>['text', 'RHINE LAB / MUSIC DATABASE / AUDIO TERMINAL', 53.0, 37.0, 11.0, 'regular', 0, mutedLight],
        <Object?>['text', '← 返回', 798.0, 30.0, 14.0, 'regular', 0, inkLight],
        <Object?>['text', 'Now Playing', 53.0, 91.0, 38.0, 'demibold', 0, inkLight],
        <Object?>['text', '播放队列 / SESSION TRACKS', 53.0, 147.0, 13.0, 'regular', 0, mutedLight],
        <Object?>['text', '正在播放 / ON AIR', 575.0, 98.0, 10.0, 'regular', 0, mutedLight],
        <Object?>['text', 'A', 575.0, 116.0, 18.0, 'demibold', 0, inkLight],
        <Object?>['text', 'B', 575.0, 143.0, 11.0, 'regular', 0, mutedLight],
        <Object?>['text', '播放队列  1', 53.0, 194.0, 20.0, 'demibold', 0, inkLight],
        <Object?>['text', '清空队列', 835.0, 197.0, 14.0, 'regular', 0, inkLight],
        <Object?>['fill', inkLight, 53.0, 233.0, 900.0, 2.0],
        <Object?>['text', 'PLAYBACK MODE / 播放模式', 53.0, 247.0, 10.0, 'regular', 0, mutedLight],
        <Object?>['text', '顺序播放', 65.0, 281.0, 14.0, 'regular', 0, inkLight],
        <Object?>['text', '列表循环', 292.0, 281.0, 14.0, 'regular', 0, inkLight],
        // 激活项先画底再写文案（Qt action()：fill → text → hit）
        <Object?>['fill', inkLight, 507.0, 269.0, 219.0, 40.0],
        <Object?>['text', '单曲循环', 519.0, 281.0, 14.0, 'regular', 0, selectedLight],
        <Object?>['text', '随机播放', 746.0, 281.0, 14.0, 'regular', 0, inkLight],
        <Object?>['fill', lineLight, 53.0, 322.0, 900.0, 1.0],
        <Object?>['text', '#', 63.0, 334.0, 10.0, 'regular', 0, mutedLight],
        <Object?>['text', '曲目 / TRACK', 97.0, 334.0, 10.0, 'regular', 0, mutedLight],
        <Object?>['text', '时长', 853.0, 334.0, 10.0, 'regular', 0, mutedLight],
        // 当前行：选中底 + 强调竖条 + ●
        <Object?>['fill', selectedLight, 53.0, 358.0, 900.0, 56.0],
        <Object?>['fill', amber, 53.0, 358.0, 3.0, 56.0],
        <Object?>['text', '●', 63.0, 376.0, 12.0, 'regular', 0, inkLight],
        <Object?>['text', 'A', 97.0, 365.0, 17.0, 'demibold', 0, inkLight],
        <Object?>['text', 'B', 97.0, 390.0, 11.0, 'regular', 0, mutedLight],
        <Object?>['text', '01:05', 853.0, 376.0, 12.0, 'regular', 0, mutedLight],
        <Object?>['fill', lineLight, 53.0, 413.0, 900.0, 1.0],
        <Object?>['text', '清空仅移除待播歌曲，当前歌曲继续播放。', 53.0, 768.0, 11.0, 'regular', 0, mutedLight],
        <Object?>['text', '1–1 / 1  · 滚轮浏览', 665.0, 768.0, 11.0, 'regular', 0, mutedLight],
        <Object?>['text', '同步中', 53.0, 800.0, 11.0, 'regular', 0, mutedLight],
      ];
      // 命中不占命令位：上面的 30 条命令对应 37 个"绘制步骤"，这里只比对命令。
      expectCommands(drawing, expected);
    });

    test('命中顺序 = 绘制顺序：返回、清空、四个模式、当前行', () {
      expect(hitActions(drawing), <String>[
        'close-modal',
        'player:clear',
        'player:mode:off',
        'player:mode:all',
        'player:mode:one',
        'player:mode:shuffle',
        'player:queue:0',
      ]);
    });

    test('当前行不画移除键，其余行每行一个（Qt !current 才 action）', () {
      expect(hitsOf(drawing, 'player:remove:0'), isEmpty);
    });
  });

  group('几何与平移（Qt PlaybackQueueCard.cpp:12-14、:74-78）', () {
    test('卡片内缩：x=bounds.x+53、width=bounds.width-106', () {
      final QueueModalDrawing drawing = renderQueueModal(
        const QueueModalState(bounds: QueueModalRect(100.0, 50.0, 1006.0, 836.0)),
        const UnitGlyphs(),
      );
      final List<List<Object?>> texts = commandsOf(drawing, 'text');
      expect(texts.first[2], 153.0);
      expect(texts.first[3], 87.0);
      expect(hitOf(drawing, 'close-modal')['x'], 886.0);
      expect(hitOf(drawing, 'close-modal')['y'], 68.0);
      expect(hitOf(drawing, 'player:mode:off')['x'], 153.0);
      expect(hitOf(drawing, 'player:mode:off')['y'], 319.0);
    });

    test('行几何：top=y+358+row*56、高度 56、分隔线在 top+55', () {
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(
          bounds: const QueueModalRect(0.0, 50.0, 1006.0, 836.0),
          tracks: List<QueueModalTrack>.generate(
            3,
            (int index) => QueueModalTrack(title: 'T' + index.toString(), duration: 1000),
          ),
        ),
        const UnitGlyphs(),
      );
      expect(hitOf(drawing, 'player:queue:0')['y'], 408.0);
      expect(hitOf(drawing, 'player:queue:0')['x'], 58.0);
      expect(hitOf(drawing, 'player:queue:0')['width'], 850.0);
      expect(hitOf(drawing, 'player:queue:0')['height'], 55.0);
      expect(hitOf(drawing, 'player:queue:1')['y'], 464.0);
      expect(hitOf(drawing, 'player:queue:2')['y'], 520.0);
      expect(hitOf(drawing, 'player:remove:0')['y'], 414.0);
      expect(hitOf(drawing, 'player:remove:0')['x'], 915.0);
      expect(hitOf(drawing, 'player:remove:0')['width'], 38.0);
      expect(hitOf(drawing, 'player:remove:0')['height'], 42.0);
      final List<List<Object?>> fills = commandsOf(drawing, 'fill');
      // 233 分隔、322 分隔、三条行分隔 463/519/575
      expect(fills.map((List<Object?> c) => c[3]).toList(),
          <Object?>[50.0 + 233.0, 50.0 + 322.0, 50.0 + 413.0, 50.0 + 469.0, 50.0 + 525.0]);
    });
  });

  group('摘要区（Now Playing，Qt PlaybackQueueCard.cpp:36-53）', () {
    test('有封面：先 image 再文案，copyX 右移 72、copyWidth 减 72', () {
      final QueueModalDrawing drawing = renderQueueModal(
        const QueueModalState(
          bounds: panel,
          cover: 'cover-key',
          current: QueueModalTrack(title: 'A', artist: 'B'),
          playing: true,
        ),
        const UnitGlyphs(),
      );
      final List<List<Object?>> images = commandsOf(drawing, 'image');
      expect(images.length, 1);
      expect(images.first, <Object?>['image', 'cover-key', 575.0, 100.0, 58.0, 58.0]);
      final int imageIndex = indexOfCommand(
          drawing, <Object?>['image', 'cover-key', 575.0, 100.0, 58.0, 58.0]);
      final int statusIndex = indexOfCommand(
          drawing, <Object?>['text', '正在播放 / ON AIR', 647.0, 98.0, 10.0, 'regular', 0, mutedLight]);
      expect(imageIndex < statusIndex, isTrue);
      // 可观测项：copyX 右移 72 后 title 的 x = summaryX(575) + 72 = 647（Qt/src/PlaybackQueueCard.cpp:46-47,51）
      expect(commandsOf(drawing, 'text')[5][2], 647.0);
    });

    test('copyWidth 减 72：超宽标题按 306 截断并加省略号（Qt:47,51 + NativeHud.cpp:48-76）', () {
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(
          bounds: panel,
          cover: 'cover-key',
          current: QueueModalTrack(title: 'X' * 400),
        ),
        const UnitGlyphs(),
      );
      final String fitted = commandsOf(drawing, 'text')[5][1] as String;
      expect(fitted.length, 306); // summaryWidth(378) - 72
      expect(fitted.endsWith('\u2026'), isTrue);
    });

    test('无封面：不发 image，copyX 不偏移', () {
      final QueueModalDrawing drawing = renderQueueModal(
        const QueueModalState(
          bounds: panel,
          current: QueueModalTrack(title: 'A'),
          playing: true,
        ),
        const UnitGlyphs(),
      );
      expect(commandsOf(drawing, 'image'), isEmpty);
      expect(commandsOf(drawing, 'text')[4][2], 575.0); // summary x = copyX（无封面不偏移）
      expect(commandsOf(drawing, 'text')[5][2], 575.0); // title x = copyX
      // copyWidth 仍为 378：超宽标题按 378 截断（Qt:46-47,51 + NativeHud.cpp:48-76）
      final String fitted = commandsOf(
        renderQueueModal(
          QueueModalState(bounds: panel, current: QueueModalTrack(title: 'X' * 400)),
          const UnitGlyphs(),
        ),
        'text',
      )[5][1] as String;
      expect(fitted.length, 378);
      expect(fitted.endsWith('\u2026'), isTrue);
    });

    test('三态文案：无 current 待机、playing 播放中、否则暂停', () {
      String summaryOf(QueueModalState state) =>
          commandsOf(renderQueueModal(state, const UnitGlyphs()), 'text')[4][1] as String;
      expect(summaryOf(const QueueModalState(bounds: panel)), '等待音轨 / STANDBY');
      expect(
        summaryOf(const QueueModalState(
            bounds: panel, current: QueueModalTrack(title: 'A'), playing: true)),
        '正在播放 / ON AIR',
      );
      expect(
        summaryOf(const QueueModalState(
            bounds: panel, current: QueueModalTrack(title: 'A'), playing: false)),
        '已暂停 / PAUSED',
      );
    });

    test('标题：null 才回退「暂无播放歌曲」，空串原样透传（Qt toString 默认值语义）', () {
      String titleOf(QueueModalTrack? current) => commandsOf(
            renderQueueModal(
                QueueModalState(bounds: panel, current: current), const UnitGlyphs()),
            'text',
          )[5][1] as String;
      // Qt/src/PlaybackQueueCard.cpp:51：current.value("title").toString("暂无播放歌曲")
      // 只在值不是字符串（键缺失 / current 为空对象）时回退；空串是字符串，原样输出。
      expect(titleOf(null), '暂无播放歌曲');
      expect(titleOf(const QueueModalTrack()), '');
      expect(titleOf(const QueueModalTrack(title: '夜航')), '夜航');
    });

    test('artist 原样透传，空串也发文本命令', () {
      final QueueModalDrawing drawing = renderQueueModal(
        const QueueModalState(bounds: panel, current: QueueModalTrack(title: 'A')),
        const UnitGlyphs(),
      );
      expect(commandsOf(drawing, 'text')[6], <Object?>['text', '', 575.0, 143.0, 11.0, 'regular', 0, mutedLight]);
    });
  });

  group('模式条（四键同宽，Qt PlaybackQueueCard.cpp:61-68）', () {
    test('modeWidth=(width-24)/4，间距 8，激活项画底并按 selected 上色', () {
      final QueueModalDrawing drawing = renderQueueModal(
        const QueueModalState(bounds: panel, mode: 'shuffle'),
        const UnitGlyphs(),
      );
      expect(hitOf(drawing, 'player:mode:shuffle')['x'], 734.0);
      expect(hitOf(drawing, 'player:mode:shuffle')['width'], 219.0);
      expect(hitOf(drawing, 'player:mode:off')['width'], 219.0);
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['fill', inkLight, 734.0, 269.0, 219.0, 40.0])),
        isTrue,
      );
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['text', '随机播放', 746.0, 281.0, 14.0, 'regular', 0, selectedLight])),
        isTrue,
      );
    });

    test('未激活项文字用 ink，且不画底', () {
      final QueueModalDrawing drawing = renderQueueModal(
        const QueueModalState(bounds: panel, mode: 'all'),
        const UnitGlyphs(),
      );
      final List<List<Object?>> fills = commandsOf(drawing, 'fill');
      expect(fills.length, 3); // 233 分隔、激活底、322 分隔
    });

    test('未知 mode 不激活任何键（Qt 精确字符串比较）', () {
      final QueueModalDrawing drawing = renderQueueModal(
        const QueueModalState(bounds: panel, mode: 'ONE'),
        const UnitGlyphs(),
      );
      expect(commandsOf(drawing, 'fill').length, 2);
    });
  });

  group('队列行（Qt PlaybackQueueCard.cpp:74-95）', () {
    List<QueueModalTrack> tracks(int count) => List<QueueModalTrack>.generate(
          count,
          (int index) => QueueModalTrack(
            title: '曲目' + (index + 1).toString(),
            artist: '歌手' + (index + 1).toString(),
            duration: 60000.0 + index * 1000,
          ),
        );

    test('当前行：选中底 + 3 宽强调条 + ● + demibold', () {
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(bounds: panel, tracks: tracks(3), currentIndex: 1),
        const UnitGlyphs(),
      );
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['fill', selectedLight, 53.0, 414.0, 900.0, 56.0])),
        isTrue,
      );
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['fill', amber, 53.0, 414.0, 3.0, 56.0])),
        isTrue,
      );
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['text', '●', 63.0, 432.0, 12.0, 'regular', 0, inkLight])),
        isTrue,
      );
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['text', '曲目2', 97.0, 421.0, 17.0, 'demibold', 0, inkLight])),
        isTrue,
      );
    });

    test('非当前行：两位序号 + regular + muted 歌手 + 时长 + 移除键', () {
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(bounds: panel, tracks: tracks(3), currentIndex: 1),
        const UnitGlyphs(),
      );
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['text', '01', 63.0, 376.0, 12.0, 'regular', 0, mutedLight])),
        isTrue,
      );
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['text', '曲目1', 97.0, 365.0, 17.0, 'regular', 0, inkLight])),
        isTrue,
      );
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['text', '歌手1', 97.0, 390.0, 11.0, 'regular', 0, mutedLight])),
        isTrue,
      );
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['text', '01:00', 853.0, 376.0, 12.0, 'regular', 0, mutedLight])),
        isTrue,
      );
      expect(hitOf(drawing, 'player:remove:0'), hit('player:remove:0', '×', 915.0, 364.0, 38.0, 42.0));
      expect(hitsOf(drawing, 'player:remove:1'), isEmpty);
      expect(hitOf(drawing, 'player:queue:1'),
          hit('player:queue:1', '播放 曲目2', 58.0, 414.0, 850.0, 55.0));
    });

    test('第 10 条索引不补零（pad 只保证两位）', () {
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(bounds: panel, tracks: tracks(12), offset: 9),
        const UnitGlyphs(),
      );
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['text', '10', 63.0, 376.0, 12.0, 'regular', 0, mutedLight])),
        isTrue,
      );
    });

    test('最多 7 行：第 8 条不画也不命中', () {
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(bounds: panel, tracks: tracks(12)),
        const UnitGlyphs(),
      );
      expect(hitsOf(drawing, 'player:queue:6').length, 1);
      expect(hitsOf(drawing, 'player:queue:7'), isEmpty);
      expect(commandsOf(drawing, 'text').where((List<Object?> c) => c[1] == '曲目8'), isEmpty);
    });

    test('offset 越界被 clamp 到 maximumOffset（末尾一首置顶）', () {
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(bounds: panel, tracks: tracks(10), offset: 100),
        const UnitGlyphs(),
      );
      expect(hitsOf(drawing, 'player:queue:9').length, 1);
      expect(hitsOf(drawing, 'player:queue:8'), isEmpty);
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['text', '10–10 / 10  · 滚轮浏览', 665.0, 768.0, 11.0, 'regular', 0, mutedLight])),
        isTrue,
      );
    });

    test('负 offset 被 clamp 到 0', () {
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(bounds: panel, tracks: tracks(3), offset: -5),
        const UnitGlyphs(),
      );
      expect(hitsOf(drawing, 'player:queue:0').length, 1);
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['text', '1–3 / 3  · 滚轮浏览', 665.0, 768.0, 11.0, 'regular', 0, mutedLight])),
        isTrue,
      );
    });

    test('中段窗口：offset=3 首行即第 4 首，末行第 10 首', () {
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(bounds: panel, tracks: tracks(10), offset: 3),
        const UnitGlyphs(),
      );
      expect(hitOf(drawing, 'player:queue:3')['y'], 358.0);
      expect(hitOf(drawing, 'player:queue:9')['y'], 694.0);
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['text', '4–10 / 10  · 滚轮浏览', 665.0, 768.0, 11.0, 'regular', 0, mutedLight])),
        isTrue,
      );
    });

    test('currentIndex 越界时没有任何行被标记为当前', () {
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(bounds: panel, tracks: tracks(3), currentIndex: 99),
        const UnitGlyphs(),
      );
      expect(commandsOf(drawing, 'fill').length, 5); // 233 / 322 / 三条行分隔
      expect(hitsOf(drawing, 'player:remove:0').length, 1);
      expect(hitsOf(drawing, 'player:remove:2').length, 1);
    });

    test('重复文案不去重：多行各留一个「×」文本与命中', () {
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(bounds: panel, tracks: tracks(3)),
        const UnitGlyphs(),
      );
      expect(commandsOf(drawing, 'text').where((List<Object?> c) => c[1] == '×').length, 3);
      expect(drawing.hits.where((Map<String, Object?> h) => h['label'] == '×').length, 3);
    });
  });

  group('fit 省略号（Qt NativeHud.cpp:48-76 二分）', () {
    List<String> titleTexts(QueueModalDrawing drawing) => commandsOf(drawing, 'text')
        .where((List<Object?> c) => c[4] == 17.0)
        .map((List<Object?> c) => c[1] as String)
        .toList();

    test('恰好放下不截断（width == limit）', () {
      final String title = 'a' * 725;
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(bounds: panel, tracks: <QueueModalTrack>[QueueModalTrack(title: title)]),
        const UnitGlyphs(),
      );
      expect(titleTexts(drawing).first, title);
    });

    test('超 1 即截断：保留 length-1 再补 U+2026', () {
      final String title = 'a' * 726;
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(bounds: panel, tracks: <QueueModalTrack>[QueueModalTrack(title: title)]),
        const UnitGlyphs(),
      );
      final String shown = titleTexts(drawing).first;
      expect(shown.length, 725);
      expect(shown.endsWith('…'), isTrue);
      expect(shown, 'a' * 724 + '…');
    });

    test('汉字按 UTF-16 code unit 计宽时同样按 length-1 截断', () {
      final String title = '夜' * 730;
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(bounds: panel, tracks: <QueueModalTrack>[QueueModalTrack(title: title)]),
        const UnitGlyphs(),
      );
      expect(titleTexts(drawing).first, '夜' * 724 + '…');
    });

    test('单字符超宽仍原样返回（Qt 边界：length 未变则不加省略号）', () {
      // bounds.width=280 → 卡片 width=174 → 标题 limit=174-175=-1
      final QueueModalDrawing drawing = renderQueueModal(
        const QueueModalState(
          bounds: QueueModalRect(0.0, 0.0, 280.0, 836.0),
          tracks: <QueueModalTrack>[QueueModalTrack(title: 'A')],
        ),
        const UnitGlyphs(),
      );
      expect(titleTexts(drawing).first, 'A');
    });

    test('两字符超宽退化为单个省略号', () {
      final QueueModalDrawing drawing = renderQueueModal(
        const QueueModalState(
          bounds: QueueModalRect(0.0, 0.0, 280.0, 836.0),
          tracks: <QueueModalTrack>[QueueModalTrack(title: 'AB')],
        ),
        const UnitGlyphs(),
      );
      expect(titleTexts(drawing).first, '…');
    });

    test('空串不截断，直接发空文本', () {
      final QueueModalDrawing drawing = renderQueueModal(
        const QueueModalState(
          bounds: panel,
          tracks: <QueueModalTrack>[QueueModalTrack(title: '')],
        ),
        const UnitGlyphs(),
      );
      expect(titleTexts(drawing).first, '');
    });

    test('二分探测序列与 Qt 一致：先整串，再 middle=(low+high+1)/2', () {
      // bounds.width=284 → 卡片 width=178 → 标题 limit=3；title='abcde'
      final RecordingGlyphs glyphs = RecordingGlyphs();
      final QueueModalDrawing drawing = renderQueueModal(
        const QueueModalState(
          bounds: QueueModalRect(0.0, 0.0, 284.0, 836.0),
          tracks: <QueueModalTrack>[QueueModalTrack(title: 'abcde')],
        ),
        glyphs,
      );
      // label 先量整串，再按 middle=(1+5+1)/2=3 → 'abc'，再 middle=(3+5+1)/2=4 → 'abcd'
      final List<String> probes = glyphs.widthCalls
          .where((String value) => value == 'abcde' || value == 'abc' || value == 'abcd' || value == 'ab')
          .toList();
      expect(probes.length >= 3, isTrue);
      expect(probes[0], 'abcde');
      expect(probes[1], 'abc');
      expect(probes[2], 'abcd');
      expect(commandsOf(drawing, 'text').where((List<Object?> c) => c[4] == 17.0).first[1], 'ab…');
    });

    test('命中标签用完整标题，不截断（Qt hit 不走 fit）', () {
      final String title = 'a' * 726;
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(bounds: panel, tracks: <QueueModalTrack>[QueueModalTrack(title: title)]),
        const UnitGlyphs(),
      );
      expect(hitOf(drawing, 'player:queue:0')['label'], '播放 ' + title);
    });
  });

  group('暗色调色板（Qt PlaybackQueueCard.cpp:15-20）', () {
    test('dark=true 全套换色，强调色不变', () {
      final QueueModalDrawing drawing = renderQueueModal(
        const QueueModalState(bounds: panel, dark: true, mode: 'one', currentIndex: -1),
        const UnitGlyphs(),
      );
      final List<List<Object?>> texts = commandsOf(drawing, 'text');
      expect(texts.first[7], mutedDark);
      expect(texts[1][7], inkDark);
      final List<List<Object?>> fills = commandsOf(drawing, 'fill');
      // fills = 233 分隔(ink)、激活模式底(ink)、322 分隔(line)
      expect(fills[0][1], inkDark);
      expect(fills[1][1], inkDark);
      expect(fills[2][1], lineDark);
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['fill', inkDark, 507.0, 269.0, 219.0, 40.0])),
        isTrue,
      );
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['text', '单曲循环', 519.0, 281.0, 14.0, 'regular', 0, selectedDark])),
        isTrue,
      );
    });

    test('当前行强调条在暗色下仍是同一 amber', () {
      final QueueModalDrawing drawing = renderQueueModal(
        const QueueModalState(
          bounds: panel,
          dark: true,
          tracks: <QueueModalTrack>[QueueModalTrack(title: 'A')],
          currentIndex: 0,
        ),
        const UnitGlyphs(),
      );
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['fill', amber, 53.0, 358.0, 3.0, 56.0])),
        isTrue,
      );
      expect(
        drawing.commands.any((List<Object?> c) =>
            _sameList(c, <Object?>['fill', selectedDark, 53.0, 358.0, 900.0, 56.0])),
        isTrue,
      );
    });
  });

  group('命中表契约（Qt NativeHud.cpp:102-109）', () {
    test('每条命中恰好六键，无 fixed（fixed:true 仅 PlayerBar）', () {
      final QueueModalDrawing drawing = renderQueueModal(
        QueueModalState(
          bounds: panel,
          tracks: List<QueueModalTrack>.generate(
            3,
            (int index) => QueueModalTrack(title: 'T' + index.toString()),
          ),
          currentIndex: 1,
        ),
        const UnitGlyphs(),
      );
      expect(drawing.hits, isNotEmpty);
      for (final Map<String, Object?> entry in drawing.hits) {
        // Qt/src/NativeHud.cpp:102-109：六键按 x,y,width,height,action,label 的插入序写入，
        // 不排序、不去重、不合并且不得出现 fixed。
        expect(entry.keys.toList(),
            <String>['x', 'y', 'width', 'height', 'action', 'label']);
        expect(entry.containsKey('fixed'), isFalse);
      }
    });

    test('命中数值均为 double、动作为字符串', () {
      final QueueModalDrawing drawing = renderQueueModal(
        const QueueModalState(bounds: panel),
        const UnitGlyphs(),
      );
      for (final Map<String, Object?> entry in drawing.hits) {
        expect(entry['x'], isA<double>());
        expect(entry['y'], isA<double>());
        expect(entry['width'], isA<double>());
        expect(entry['height'], isA<double>());
        expect(entry['action'], isA<String>());
        expect(entry['label'], isA<String>());
      }
    });

    test('命令只出现 fill/text/image 三种 op', () {
      final QueueModalDrawing drawing = renderQueueModal(
        const QueueModalState(
          bounds: panel,
          cover: 'k',
          tracks: <QueueModalTrack>[QueueModalTrack(title: 'A')],
        ),
        const UnitGlyphs(),
      );
      final Set<String> ops =
          drawing.commands.map((List<Object?> c) => c[0] as String).toSet();
      expect(ops, <String>{'fill', 'text', 'image'});
    });

    test('每次渲染返回独立容器，可重复调用得到相同结果', () {
      const QueueModalState state = QueueModalState(bounds: panel);
      final QueueModalDrawing first = renderQueueModal(state, const UnitGlyphs());
      final QueueModalDrawing second = renderQueueModal(state, const UnitGlyphs());
      expect(identical(first.commands, second.commands), isFalse);
      expect(first.commands.length, second.commands.length);
      for (int i = 0; i < first.commands.length; i += 1) {
        expect(_sameList(first.commands[i], second.commands[i]), isTrue);
      }
    });
  });

  // ── Qt 回归不变量（强外部真值）：Qt/src/NativeHud.cpp:140-158 在 1920 宽下给出
  // modalBounds=(330,122,1260,836)，与 Qt/tests/NativeHudChecks.cpp:1338 的
  // queueBounds==QRectF(330,122,1260,836) 同值；下列断言逐条对应同一回归清单。 ──
  group('Qt 回归不变量（1920 真实面板 330,122,1260,836）', () {
    // 卡内几何 x=330+53=383、y=122、width=1260-106=1154（PlaybackQueueCard.cpp:12-14）→
    // modeWidth=(1154-24)/4=282.5（:64）、模式键间距 8（:66）、行 top=122+358+row*56（:78）。
    const QueueModalRect real = QueueModalRect(330.0, 122.0, 1260.0, 836.0);
    const List<QueueModalTrack> nine = <QueueModalTrack>[
      QueueModalTrack(title: 'T0', artist: 'A0', duration: 1000),
      QueueModalTrack(title: 'T1', artist: 'A1', duration: 2000),
      QueueModalTrack(title: 'T2', artist: 'A2', duration: 3000),
      QueueModalTrack(title: 'T3', artist: 'A3', duration: 4000),
      QueueModalTrack(title: 'T4', artist: 'A4', duration: 5000),
      QueueModalTrack(title: 'T5', artist: 'A5', duration: 6000),
      QueueModalTrack(title: 'T6', artist: 'A6', duration: 7000),
      QueueModalTrack(title: 'T7', artist: 'A7', duration: 8000),
      QueueModalTrack(title: 'T8', artist: 'A8', duration: 9000),
    ];

    test('返回键贴住卡片右缘：x=1370、width=167 → 右缘 1537（Qt:35）', () {
      final QueueModalDrawing drawing = renderQueueModal(
          const QueueModalState(bounds: real), const UnitGlyphs());
      final Map<String, Object?> back = hitOf(drawing, 'close-modal');
      expect(back, hit('close-modal', '← 返回', 1370.0, 140.0, 167.0, 54.0));
      expect((back['x'] as double) + (back['width'] as double), 1537.0);
    });

    test('四个模式键 x=383/673.5/964/1254.5、宽 282.5、y=391（Qt:64-68）', () {
      final QueueModalDrawing drawing = renderQueueModal(
          const QueueModalState(bounds: real, mode: 'shuffle'), const UnitGlyphs());
      expect(hitOf(drawing, 'player:mode:off'),
          hit('player:mode:off', '顺序播放', 383.0, 391.0, 282.5, 40.0));
      expect(hitOf(drawing, 'player:mode:all'),
          hit('player:mode:all', '列表循环', 673.5, 391.0, 282.5, 40.0));
      expect(hitOf(drawing, 'player:mode:one'),
          hit('player:mode:one', '单曲循环', 964.0, 391.0, 282.5, 40.0));
      expect(hitOf(drawing, 'player:mode:shuffle'),
          hit('player:mode:shuffle', '随机播放', 1254.5, 391.0, 282.5, 40.0));
    });

    test('尾曲置顶：currentIndex=8、offset=8 → queue:8 的 y=480（NativeHudChecks.cpp:1392-1401）', () {
      final QueueModalDrawing drawing = renderQueueModal(
          const QueueModalState(
            bounds: real,
            tracks: nine,
            current: QueueModalTrack(title: 'T8', artist: 'A8', duration: 9000),
            currentIndex: 8,
            offset: 8,
          ),
          const UnitGlyphs());
      expect(hitOf(drawing, 'player:queue:8'),
          hit('player:queue:8', '播放 T8', 388.0, 480.0, 1104.0, 55.0));
      expect(hitsOf(drawing, 'player:remove:8'), isEmpty);
      expect(hitsOf(drawing, 'player:queue:9'), isEmpty);
    });

    test('选中与移除命中不重叠：queue:5 右缘 1492 <= remove:5 的 x=1499（NativeHudChecks.cpp:1408-1414）', () {
      final QueueModalDrawing drawing = renderQueueModal(
          const QueueModalState(
              bounds: real, tracks: nine, currentIndex: 0, offset: 0),
          const UnitGlyphs());
      final Map<String, Object?> select = hitOf(drawing, 'player:queue:5');
      final Map<String, Object?> remove = hitOf(drawing, 'player:remove:5');
      expect(select, hit('player:queue:5', '播放 T5', 388.0, 760.0, 1104.0, 55.0));
      expect(remove, hit('player:remove:5', '×', 1499.0, 766.0, 38.0, 42.0));
      expect((select['x'] as double) + (select['width'] as double), 1492.0);
      expect((select['x'] as double) + (select['width'] as double),
          lessThanOrEqualTo(remove['x'] as double));
    });

    test('重绘不偷走手动 offset：currentIndex=8 但 offset=3 → 首行仍是 queue:3（NativeHudChecks.cpp:1402-1407）', () {
      final QueueModalState state = QueueModalState(
          bounds: real, tracks: nine, currentIndex: 8, offset: 3);
      final QueueModalDrawing first = renderQueueModal(state, const UnitGlyphs());
      final QueueModalDrawing second = renderQueueModal(state, const UnitGlyphs());
      expect(hitActions(first), hitActions(second));
      expect(hitOf(first, 'player:queue:3'),
          hit('player:queue:3', '播放 T3', 388.0, 480.0, 1104.0, 55.0));
      expect(hitsOf(first, 'player:queue:2'), isEmpty);
      expect(state.offset, 3);
    });

    test('空队列：无 player:queue / player:remove / player:clear 命中（NativeHudChecks.cpp:1430-1437）', () {
      final QueueModalDrawing drawing = renderQueueModal(
          const QueueModalState(bounds: real), const UnitGlyphs());
      expect(hitActions(drawing), <String>[
        'close-modal',
        'player:mode:off',
        'player:mode:all',
        'player:mode:one',
        'player:mode:shuffle',
      ]);
      expect(hitsOf(drawing, 'player:queue:0'), isEmpty);
      expect(hitsOf(drawing, 'player:remove:0'), isEmpty);
      expect(hitsOf(drawing, 'player:clear'), isEmpty);
    });

    test('全部命中落在面板矩形内（NativeHudChecks.cpp:1354-1367）', () {
      final QueueModalDrawing drawing = renderQueueModal(
          const QueueModalState(
              bounds: real, tracks: nine, currentIndex: 4),
          const UnitGlyphs());
      expect(drawing.hits, isNotEmpty);
      for (final Map<String, Object?> h in drawing.hits) {
        final double hx = h['x'] as double;
        final double hy = h['y'] as double;
        expect(hx, greaterThanOrEqualTo(330.0));
        expect(hy, greaterThanOrEqualTo(122.0));
        expect(hx + (h['width'] as double), lessThanOrEqualTo(1590.0));
        expect(hy + (h['height'] as double), lessThanOrEqualTo(958.0));
      }
    });
  });
}
