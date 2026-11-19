// QueueModal：横屏播放队列面板（Now Playing 摘要 + 模式条 + 七行队列）的
// 纯数据命令 / 命中构建器。
//
// 语义与顺序逐条移植自 Qt/src/PlaybackQueueCard.h 与
// Qt/src/PlaybackQueueCard.cpp:6-107（maximumOffset :6-8、paint :11-107，1:1 真值）；装配方式对齐
// Qt/src/NativeHudPlayer.cpp:45-75（bounds 高 836、canvas 转发到 HUD 原语）；
// fit / hit 形状对齐 Qt/src/NativeHud.cpp:48-76 与 :102-109；
// pad / time 对齐 Qt/src/MusicData.cpp:148-158。
//
// 面板底色、圆角与滚动裁切由宿主 modal 层负责，本文件只产出卡片内容。
// 不依赖 Flutter Widget / Material，也不 import lib/hud/protocol/* 与 lib/domain/*：
// 宿主负责把 commands 追加进整帧、把 hits 追加进命中表，命令是 Qt 的 flat JSON 形态，
// 同代发布、不排序、不去重、不合并。
//
// 命中集合固定六键（x/y/width/height/action/label），不带 fixed：fixed:true 只属于
// PlayerBar（Qt PlayerBar.cpp:46-54 自行追加），modal 内命中由输入分发按坐标系处理。

/// 可视行数（Qt PlaybackQueueCard::VisibleRows，PlaybackQueueCard.h:9）。
const int queueModalVisibleRows = 7;

/// 面板高度（Qt NativeHudPlayer.cpp:49 传入的 836）；卡片内几何全部相对 bounds.y。
const double queueModalPanelHeight = 836.0;

/// 允许最后一首置顶：max(0, trackCount - 1)（PlaybackQueueCard.cpp:7）。
///
/// 尾页不足七行时保留空白，而不是把 offset 收回到 count-7。
int queueModalMaximumOffset(int trackCount) => trackCount > 1 ? trackCount - 1 : 0;

/// QString::number(value).rightJustified(width, '0')（Qt MusicData::pad）。
String queueModalPad(int value, [int width = 2]) => value.toString().padLeft(width, '0');

/// 歌曲时长文案（Qt MusicData::time）：duration <= 0 显示「暂无」，否则 mm:ss。
///
/// Qt 用 int(duration/60000) 与 int(duration/1000)%60 截断取整，分钟不封顶。
String queueModalTime(QueueModalTrack track) {
  if (track.duration <= 0) {
    return '暂无';
  }
  final int minutes = (track.duration / 60000).truncate();
  final int seconds = (track.duration / 1000).truncate() % 60;
  return '${queueModalPad(minutes)}:${queueModalPad(seconds)}';
}

/// 播放队列条目（Qt 的 song QJsonObject 中本绘制器用到的三个字段）。
class QueueModalTrack {
  const QueueModalTrack({
    this.title = '',
    this.artist = '',
    this.duration = 0.0,
  });

  final String title;
  final String artist;

  /// 毫秒；<= 0 时列表时长列显示「暂无」（Qt MusicData::time）。
  final double duration;

  @override
  String toString() => 'QueueModalTrack($title, $artist, $duration)';
}

/// Qt QRectF 的值等价物（只读）。
class QueueModalRect {
  const QueueModalRect(this.x, this.y, this.width, this.height);

  final double x;
  final double y;
  final double width;
  final double height;

  double get left => x;
  double get top => y;
  double get right => x + width;
  double get bottom => y + height;

  @override
  bool operator ==(Object other) =>
      other is QueueModalRect &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() =>
      'QueueModalRect($x, $y, $width, $height)';
}

/// 展示快照（Qt PlaybackQueueCard::Model，PlaybackQueueCard.h:13-25）。
///
/// 不持有播放器或页面控制器：队列内容、当前歌曲与滚动位置都由宿主装配。
class QueueModalState {
  const QueueModalState({
    required this.bounds,
    this.tracks = const <QueueModalTrack>[],
    this.current,
    this.cover = '',
    this.mode = '',
    this.status = '',
    this.currentIndex = -1,
    this.offset = 0,
    this.playing = false,
    this.dark = false,
  });

  /// 面板矩形；Qt 传 {x, y, width, 836}（NativeHudPlayer.cpp:49）。
  final QueueModalRect bounds;

  /// 队列快照，顺序即播放顺序。
  final List<QueueModalTrack> tracks;

  /// 当前歌曲；null 等价于 Qt 的 current.isEmpty()（空对象）。
  ///
  /// 标题语义严格对齐 Qt/src/PlaybackQueueCard.cpp:51 的
  /// current.value("title").toString("暂无播放歌曲")：QJsonValue::toString(default)
  /// 只在值不是字符串时回退，空串 "" 是字符串、原样输出。因此这里只有 current ==
  /// null（= Qt 空对象）才用「暂无播放歌曲」，非 null 时 title 逐字透传（含空串）。
  final QueueModalTrack? current;

  /// 封面键；非空才发 image 命令（Qt NativeHud::image 对空 key 直接返回）。
  final String cover;

  /// off / all / one / shuffle；其它取值不点亮任何模式键（Qt 精确字符串比较）。
  final String mode;

  /// 状态尾文案（图例下方、y+800）。
  final String status;

  /// 当前歌曲在 [tracks] 中的下标；-1 表示无（Qt queue.indexOf(current)）。
  final int currentIndex;

  /// 首行下标；绘制前 clamp 到 [0, queueModalMaximumOffset(count)]。
  final int offset;

  final bool playing;
  final bool dark;
}

/// 字形度量端口：队列卡片只用得到 width（Qt Canvas::fit → NativeHud::fit）。
abstract class QueueModalGlyphs {
  /// 文本排版宽度（已含 tracking，与 Glyphs::width(value, size, weight) 一致）。
  double width(String value, double size, String weight);
}

/// 一帧的绘制产物（Qt PlaybackQueueCard::Canvas 的录制结果）。
class QueueModalDrawing {
  QueueModalDrawing({required this.commands, required this.hits});

  /// flat 命令数组，顺序即 Qt append 顺序。
  final List<List<Object?>> commands;

  /// 命中表；每条恰好 x/y/width/height/action/label 六键（无 fixed）。
  final List<Map<String, Object?>> hits;
}

/// 绘制整块队列卡片（Qt PlaybackQueueCard::paint）。
QueueModalDrawing renderQueueModal(QueueModalState state, QueueModalGlyphs glyphs) {
  final _Painter paint = _Painter(glyphs, state.dark);
  paint.card(state);
  return QueueModalDrawing(commands: paint.commands, hits: paint.hits);
}

/// 省略号（U+2026），与 Qt NativeHud::fit 的补字一致。
const String _ellipsis = '…';

/// std::clamp 语义（要求 low <= high）。
int _clampInt(int value, int low, int high) {
  if (value < low) {
    return low;
  }
  if (value > high) {
    return high;
  }
  return value;
}

/// 单帧绘制累加器（Qt PlaybackQueueCard.cpp:21-32 的 label / action 与
/// NativeHud.cpp 的 fill / text / fit / hit / image）。
class _Painter {
  _Painter(this.glyphs, bool dark)
      : ink = dark ? _inkDark : _inkLight,
        muted = dark ? _mutedDark : _mutedLight,
        line = dark ? _lineDark : _lineLight,
        selected = dark ? _selectedDark : _selectedLight;

  final QueueModalGlyphs glyphs;

  final List<List<Object?>> commands = <List<Object?>>[];
  final List<Map<String, Object?>> hits = <Map<String, Object?>>[];

  final List<double> ink;
  final List<double> muted;
  final List<double> line;
  final List<double> selected;

  /// 强调色在明暗两套调色板下相同（PlaybackQueueCard.cpp:20）。
  static const List<double> amber = <double>[0.83, 0.64, 0.27, 1.0];

  static const List<double> _inkLight = <double>[0.145, 0.176, 0.153, 1.0];
  static const List<double> _inkDark = <double>[0.93, 0.94, 0.88, 1.0];
  static const List<double> _mutedLight = <double>[0.41, 0.44, 0.39, 1.0];
  static const List<double> _mutedDark = <double>[0.68, 0.71, 0.64, 1.0];
  static const List<double> _lineLight = <double>[0.79, 0.80, 0.74, 1.0];
  static const List<double> _lineDark = <double>[0.31, 0.35, 0.29, 1.0];
  static const List<double> _selectedLight = <double>[0.90, 0.90, 0.83, 1.0];
  static const List<double> _selectedDark = <double>[0.24, 0.28, 0.22, 1.0];

  /// ["fill", color, x, y, width, height]（NativeHud.cpp fill）。
  void fill(double x, double y, double width, double height, List<double> color) {
    commands.add(<Object?>['fill', color, x, y, width, height]);
  }

  /// ["image", key, x, y, width, height]；key 为空不发命令（NativeHud::image）。
  void image(String key, double x, double y, double width, double height) {
    if (key.isEmpty) {
      return;
    }
    commands.add(<Object?>['image', key, x, y, width, height]);
  }

  /// ["text", value, x, y, size, weight, tracking, color]（NativeHud.cpp text）。
  ///
  /// tracking 在 Qt 用整数字面量 0，这里保持同样的 JSON 形态。
  void text(String value, double x, double y, double size, String weight, List<double> color) {
    commands.add(<Object?>['text', value, x, y, size, weight, 0, color]);
  }

  /// Qt NativeHud::fit：整串放不下时二分求最长可放前缀，再留一格补省略号。
  ///
  /// 复刻点（NativeHud.cpp:56-73）：low 从 1 起、middle=(low+high+1)/2、
  /// 最终 length==1 且原串更长时 left(0)+"…" 只剩省略号；单字符本身超宽时
  /// length 未变，原样返回（Qt 边界行为）。Qt 的 m_fitCache 是纯缓存，不改变输出，
  /// 这里保持无状态纯函数。
  String fit(String value, double size, double width, String weight) {
    int length = value.length;
    if (glyphs.width(value, size, weight) > width) {
      int low = 1;
      int high = length;
      while (low < high) {
        final int middle = (low + high + 1) ~/ 2;
        if (glyphs.width(value.substring(0, middle), size, weight) <= width) {
          low = middle;
        } else {
          high = middle - 1;
        }
      }
      length = low;
    }
    if (length != value.length) {
      final int keep = length - 1 < 0 ? 0 : length - 1;
      return value.substring(0, keep) + _ellipsis;
    }
    return value;
  }

  /// 六键命中（NativeHud.cpp:102-109；不带 fixed）。
  void hit(QueueModalRect rect, String action, String label) {
    hits.add(<String, Object?>{
      'x': rect.x,
      'y': rect.y,
      'width': rect.width,
      'height': rect.height,
      'action': action,
      'label': label,
    });
  }

  /// Qt PlaybackQueueCard.cpp:21-24：超宽先 fit，再按 secondary 选色。
  void label(
    String value,
    double left,
    double top,
    double size,
    double limit, {
    bool secondary = false,
    String weight = 'regular',
  }) {
    text(fit(value, size, limit, weight), left, top, size, weight, secondary ? muted : ink);
  }

  /// Qt PlaybackQueueCard.cpp:25-32：可选中键（激活时先铺 ink 底，文字用 selected）。
  void action(QueueModalRect rect, String title, String id, {bool active = false}) {
    if (active) {
      fill(rect.x, rect.y, rect.width, rect.height, ink);
    }
    text(
      fit(title, 14, rect.width - 24, 'regular'),
      rect.x + 12,
      rect.y + 12,
      14,
      'regular',
      active ? selected : ink,
    );
    hit(rect, id, title);
  }

  /// 整块卡片（Qt PlaybackQueueCard::paint，PlaybackQueueCard.cpp:34-106）。
  void card(QueueModalState state) {
    final double x = state.bounds.x + 53;
    final double y = state.bounds.y;
    final double width = state.bounds.width - 106;
    final List<QueueModalTrack> tracks = state.tracks;
    final int count = tracks.length;
    final QueueModalTrack? current = state.current;

    label('RHINE LAB / MUSIC DATABASE / AUDIO TERMINAL', x, y + 37, 11, width - 220,
        secondary: true);
    action(QueueModalRect(x + width - 167, y + 18, 167, 54), '← 返回', 'close-modal');
    label('Now Playing', x, y + 91, 38, width * 0.5, weight: 'demibold');
    label('播放队列 / SESSION TRACKS', x, y + 147, 13, width * 0.5, secondary: true);

    final double summaryX = x + width * 0.58;
    final double summaryWidth = width * 0.42;
    final bool hasCover = state.cover.isNotEmpty;
    image(state.cover, summaryX, y + 100, 58, 58);
    final double copyX = summaryX + (hasCover ? 72 : 0);
    final double copyWidth = summaryWidth - (hasCover ? 72 : 0);
    // 三态文案与标题兜底：current 为空（Qt isEmpty）时待机 + 暂无播放歌曲。
    final String summary;
    final String titleText;
    final String artistText;
    if (current == null) {
      summary = '等待音轨 / STANDBY';
      titleText = '暂无播放歌曲';
      artistText = '';
    } else {
      summary = state.playing ? '正在播放 / ON AIR' : '已暂停 / PAUSED';
      // Qt:51 toString(default) 只对非字符串回退；空串是合法字符串，逐字透传。
      titleText = current.title;
      artistText = current.artist;
    }
    label(summary, copyX, y + 98, 10, copyWidth, secondary: true);
    label(titleText, copyX, y + 116, 18, copyWidth, weight: 'demibold');
    label(artistText, copyX, y + 143, 11, copyWidth, secondary: true);

    label('播放队列  $count', x, y + 194, 20, width - 160, weight: 'demibold');
    if (count > 0) {
      action(QueueModalRect(x + width - 130, y + 185, 130, 40), '清空队列', 'player:clear');
    }
    fill(x, y + 233, width, 2, ink);

    label('PLAYBACK MODE / 播放模式', x, y + 247, 10, width, secondary: true);
    const List<String> modes = <String>['off', 'all', 'one', 'shuffle'];
    const List<String> names = <String>['顺序播放', '列表循环', '单曲循环', '随机播放'];
    final double modeWidth = (width - 24) / 4;
    for (int index = 0; index < modes.length; index += 1) {
      action(
        QueueModalRect(x + index * (modeWidth + 8), y + 269, modeWidth, 40),
        names[index],
        'player:mode:${modes[index]}',
        active: state.mode == modes[index],
      );
    }
    fill(x, y + 322, width, 1, line);

    label('#', x + 10, y + 334, 10, 28, secondary: true);
    label('曲目 / TRACK', x + 44, y + 334, 10, width - 160, secondary: true);
    label('时长', x + width - 100, y + 334, 10, 55, secondary: true);

    final int offset = _clampInt(state.offset, 0, queueModalMaximumOffset(count));
    for (int row = 0; row < queueModalVisibleRows && offset + row < count; row += 1) {
      final int index = offset + row;
      final QueueModalTrack song = tracks[index];
      final double top = y + 358 + row * 56;
      final bool isCurrent = index == state.currentIndex;
      if (isCurrent) {
        fill(x, top, width, 56, selected);
        fill(x, top, 3, 56, amber);
      }
      label(isCurrent ? '●' : queueModalPad(index + 1), x + 10, top + 18, 12, 28,
          secondary: !isCurrent);
      label(song.title, x + 44, top + 7, 17, width - 175,
          weight: isCurrent ? 'demibold' : 'regular');
      label(song.artist, x + 44, top + 32, 11, width - 175, secondary: true);
      label(queueModalTime(song), x + width - 100, top + 18, 12, 55, secondary: true);
      // 曲目与移除按钮使用独立命中区域，避免点击移除时触发播放（:89 注释）。
      hit(QueueModalRect(x + 5, top, width - 50, 55), 'player:queue:$index',
          '播放 ${song.title}');
      if (!isCurrent) {
        action(QueueModalRect(x + width - 38, top + 6, 38, 42), '×',
            'player:remove:$index');
      }
      fill(x, top + 55, width, 1, line);
    }

    if (count == 0) {
      label('播放队列为空', x + 30, y + 476, 24, width - 60, weight: 'demibold');
      label('从音乐资料库添加歌曲，开启下一段音乐。', x + 30, y + 523, 15, width - 60,
          secondary: true);
    }

    label('清空仅移除待播歌曲，当前歌曲继续播放。', x, y + 768, 11, width * 0.65,
        secondary: true);
    final int rangeStart = offset + (count == 0 ? 0 : 1);
    final int rangeEnd = offset + queueModalVisibleRows < count
        ? offset + queueModalVisibleRows
        : count;
    label(
      '$rangeStart–$rangeEnd / $count  · 滚轮浏览',
      x + width * 0.68,
      y + 768,
      11,
      width * 0.32,
      secondary: true,
    );
    label(state.status, x, y + 800, 11, width, secondary: true);
  }
}
