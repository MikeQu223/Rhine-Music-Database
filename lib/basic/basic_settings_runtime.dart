import '../hud/modals/settings_modal.dart';
import 'basic_settings.dart';
import 'basic_settings_store.dart';

/// 一次设置动作的结果：命令 + 真实落盘情况 + 用户可见反馈 + 是否需要重启生效。
///
/// 为什么把"命令"也回出来：生效动作（换配色、换音质、换图形后端、重放初始化动画…）
/// 需要 controller / Qt 场景 / 播放器参与，那些都在宿主外壳里；本类只负责
/// **解析 + 持久化 + 真话**，不自己动播放器，也不假装副作用已经发生。
class BasicSettingsApplyResult {
  const BasicSettingsApplyResult({
    required this.command,
    this.persisted = false,
    this.persistedValue = '',
    this.notice = '',
    this.restartPending = false,
    this.requiresWarning = false,
  });

  final BasicSettingsCommand command;

  /// true = 值真的写进了偏好存储（读回能拿到同一个值）。
  final bool persisted;

  /// 真正落盘的归一化值（用户看到的就是它）。
  final String persistedValue;

  /// 需要给用户看的一句话（'' = 不出提示）。
  final String notice;

  /// true = 该值下次启动才生效（图形后端 / 垂直同步的 requested-vs-effective 口径）。
  final bool restartPending;

  /// true = 唱片旋转要开，但必须先过风险确认（宿主弹 NativeHudModal 的
  /// 'disc-rotation-warning'，按钮 disc-rotation:enable / disc-rotation:cancel）。
  final bool requiresWarning;
}

/// ONLY14 设置面板的运行时：真实偏好读取/写入 + 面板模型真值。
///
/// 只在宿主外壳里持有一份（BasicApp）。面板模型每次按当前快照重建，
/// 因此"写进去 -> 立刻读回 -> 行显示新值"是同一条真值链，不是两份状态。
class BasicSettingsRuntime {
  BasicSettingsRuntime({required BasicSettingsStore store, bool dark = true})
      : _store = store,
        _dark = dark;


  final BasicSettingsStore _store;

  BasicSettingsLoad? _load;
  SettingsPreferenceSnapshot _snapshot = const SettingsPreferenceSnapshot();
  BasicSettingsVersion? _version;
  String _expandedId = '';

  bool _dark;
  bool _detailAutoplay = false;
  bool _singlePlayAppend = false;
  int _archiveMaskStrength = 55;
  bool _discRotation = false;
  bool _startupAnimation = false;
  String _quality = 'lossless';
  String _graphicsBackend = '';
  bool _vsync = true;
  String _renderScale = '';
  String _aaMode = '';
  String _aaScale = '';
  String _msaa = '';
  String _fsrQuality = '';
  String _fsrSharpness = '';

  /// 本次进程内"已请求但未生效"的重启项（图形后端 / 垂直同步）。
  final List<String> _pendingRestart = <String>[];

  /// 本进程启动瞬间读到的偏好（"已生效"的那一份，重启才会变）。
  Map<String, String> _bootRaw = const <String, String>{};

  BasicSettingsStore get store => _store;

  SettingsPreferenceSnapshot get snapshot => _snapshot;

  BasicSettingsVersion? get version => _version;

  BasicSettingsPackageInfo get package =>
      _load?.package ?? BasicSettingsPackageInfo.unknown;

  /// 面板行的展开态（'' = 全部收起）。
  String get expandedId => _expandedId;

  /// 已加载的原始偏好（`panel/<key>`，逐字）。
  Map<String, String> get raw => _load?.raw ?? const <String, String>{};

  bool get dark => _dark;
  bool get detailAutoplay => _detailAutoplay;
  bool get singlePlayAppend => _singlePlayAppend;
  int get archiveMaskStrength => _archiveMaskStrength;
  bool get discRotation => _discRotation;

  bool get startupAnimation => _startupAnimation;
  String get quality => _quality;

  /// 请求值（Qt requested）与生效值（Qt effective）分开报：
  /// 图形后端 / 垂直同步改了之后要重启才生效，面板与诊断都必须说清是哪一边。
  ///
  /// 生效值取**本进程启动时读到的**偏好（Qt 在 main 里只读一次交给
  /// RhineGraphics），因此同一次会话里写新值只改 requested，effective 不动，
  /// 直到真的重启。
  String get requestedGraphicsBackend => _graphicsBackend;
  bool get requestedVsync => _vsync;
  String get effectiveGraphicsBackend =>
      _bootRaw['${basicSettingsPreferencePrefix}graphics-backend'] ?? '';
  bool get effectiveVsync =>
      (_bootRaw['${basicSettingsPreferencePrefix}vsync'] ?? '') != 'off';
  String get renderScale => _renderScale;
  String get aaMode => _aaMode;
  String get aaScale => _aaScale;
  String get msaa => _msaa;
  String get fsrQuality => _fsrQuality;
  String get fsrSharpness => _fsrSharpness;

  List<String> get pendingRestart => List<String>.unmodifiable(_pendingRestart);

  /// 载入真实偏好（进程启动时一次）。失败也返回，只是快照是默认值。
  Future<void> load() async {
    final BasicSettingsLoad load = await _store.load(dark: _dark);
    _load = load;
    _snapshot = load.snapshot;
    _version = load.package.version;
    _bootRaw = Map<String, String>.from(load.raw);
    _applyFromSnapshot();
  }

  void _applyFromSnapshot() {
    // 配色是唯一一个"值就是主题本身"的偏好：写进去的 'light'/'dark' 必须
    // 反映到 host 的深色开关（Qt 里是 theme -> dark + 场景主题）。
    final String theme = rawValue('theme');
    if (theme == 'light') {
      _dark = false;
    } else if (theme == 'dark') {
      _dark = true;
    }
    _detailAutoplay = rawValue('detail-autoplay') == 'on';
    _singlePlayAppend = rawValue('single-play-mode') == 'append';
    _archiveMaskStrength = int.tryParse(rawValue('archive-mask-strength')) ?? 55;
    _discRotation = rawValue('disc-rotation') == 'on';
    _startupAnimation = rawValue('startup-animation') == 'on';
    final String quality = rawValue('quality');
    _quality = quality.isEmpty ? 'lossless' : quality;
    _graphicsBackend = rawValue('graphics-backend');
    _vsync = rawValue('vsync') != 'off';
    _renderScale = rawValue('render-scale');
    _aaMode = rawValue('aa-mode');
    _aaScale = rawValue('aa-scale');
    _msaa = rawValue('msaa');
    _fsrQuality = rawValue('fsr-quality');
    _fsrSharpness = rawValue('fsr-sharpness');
  }

  /// 一个 panel key 的已存值（不带 `panel/` 前缀；缺键给空串）。
  String rawValue(String panelKey) => raw['$basicSettingsPreferencePrefix$panelKey'] ?? '';

  /// 宿主构造 [SettingsPreferenceContext] 用的"已生效"读数（Qt 是 host->preference
  /// 与 RhineGraphics::activeBackend()）。
  String get appliedGraphicsBackend => rawValue('graphics-backend');
  bool get appliedVsync => rawValue('vsync') != 'off';

  void setExpanded(String rowId) {
    _expandedId = rowId;
  }

  void setDark(bool dark) {
    _dark = dark;
  }

  /// 把一次命中动作落成真值：解析 -> 持久化 -> 更新本运行时的快照。
  ///
  /// 不修改任何播放器/场景：那是宿主的生效动作（见 [BasicSettingsApplyResult] 的注释）。
  Future<BasicSettingsApplyResult> apply(
    String action, {
    required SettingsPreferenceContext context,
  }) async {
    final BasicSettingsCommand command =
        basicSettingsCommandFor(action, context: context, snapshot: _snapshot);
    switch (command) {
      case BasicSettingsExpandCommand():
        _expandedId = command.rowId;
        return BasicSettingsApplyResult(command: command);
      case BasicSettingsWriteCommand():
        final String key = command.declaredPreferenceKey.isNotEmpty
            ? command.declaredPreferenceKey
            : command.preferenceKey;
        if (key.isEmpty) {
          // 解析得出一条写入命令却没有可写的键：如实拒绝，不写一个猜的键。
          return BasicSettingsApplyResult(
            command: command,
            notice: '这一项没有可持久化的偏好键，未写入',
          );
        }
        final bool ok = await _store.write(key, command.value);
        if (!ok) {
          return BasicSettingsApplyResult(
            command: command,
            notice: '写入失败：$key 未能保存（仍是 ${command.currentValue}）',
          );
        }
        _adoptWrittenValue(key, command.value);
        final bool restart = command.restart == BasicSettingsRestart.nextLaunch;
        if (restart && !_pendingRestart.contains(_restartLabelFor(key))) {
          _pendingRestart.add(_restartLabelFor(key));
        }
        return BasicSettingsApplyResult(
          command: command,
          persisted: true,
          persistedValue: command.value,
          restartPending: restart,
        );
      case BasicSettingsDiscRotationCommand():
        if (command.setOn && command.requiresConfirmation) {
          return BasicSettingsApplyResult(command: command, requiresWarning: true);
        }
        final bool ok = await _store.write('disc-rotation', command.setOn ? 'on' : 'off');
        if (!ok) {
          return BasicSettingsApplyResult(
            command: command,
            notice: '写入失败：唱片旋转未能保存',
          );
        }
        _adoptWrittenValue('disc-rotation', command.setOn ? 'on' : 'off');
        return BasicSettingsApplyResult(
          command: command,
          persisted: true,
          persistedValue: command.setOn ? 'on' : 'off',
        );
      case BasicSettingsActionRowCommand():
        // 'replay' 是纯动作行（无持久化值）：宿主去真正重放初始化动画。
        return BasicSettingsApplyResult(command: command);
      case BasicSettingsOpenProjectCommand():
        final bool opened = await _store.openUrl(command.url);
        return BasicSettingsApplyResult(
          command: command,
          notice: opened ? '' : '无法打开链接：${command.url}（设备上没有可处理的App）',
        );
      case BasicSettingsUnavailableCommand(:final String message):
        return BasicSettingsApplyResult(command: command, notice: message);
    }
  }

  static String _restartLabelFor(String key) {
    switch (key) {
      case 'graphics-backend':
        return '图形后端';
      case 'vsync':
        return '垂直同步';
      case 'render-scale':
        return '渲染分辨率';
      default:
        return key;
    }
  }

  /// 写入成功后更新本地真值 + 快照（面板立刻显示新值，不需重新读盘）。
  void _adoptWrittenValue(String key, String value) {
    final Map<String, String> next = <String, String>{...raw};
    next['$basicSettingsPreferencePrefix$key'] = value;
    _load = BasicSettingsLoad(
      snapshot: basicSettingsSnapshotFrom(next, dark: _dark),
      package: package,
      raw: next,
    );
    _snapshot = _load!.snapshot;
    _applyFromSnapshot();
  }

  /// 重放初始化动画后由宿主回调：把一次性重启提示清掉（动画已经放过一遍）。
  void clearPendingRestart() => _pendingRestart.clear();

  /// 应用真实生效（外部改了值，例如从 Qt 场景回执回来）：同步快照。
  void syncFromRaw(Map<String, String> next) {
    _load = BasicSettingsLoad(
      snapshot: basicSettingsSnapshotFrom(next, dark: _dark),
      package: package,
      raw: next,
    );
    _snapshot = _load!.snapshot;
    _applyFromSnapshot();
  }
}
