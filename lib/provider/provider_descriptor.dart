/// 平台 descriptor 的 Dart 侧只读投影（Qt `ProviderRegistry` 的纯数据面）。
///
/// 真值来源（逐条对应，改字段先改这里并同步测试）：
/// - `Qt/src/ProviderRegistry.cpp:11-24`   `validDescriptor`（schemaVersion==2、id 非空、
///   display/capabilities 为对象）与 `descriptorFields`（哪些键算 descriptor 字段）。
/// - `Qt/src/ProviderRegistry.cpp:34-58`   `validManifest`（schemaVersion==2、version 非空、
///   `apiVersion` 匹配 `^\d+\.\d+$` 且主版本 2、次版本 ≤0、`entry.file` 是安全相对路径、
///   display/capabilities 为对象、`routes.legacyRoutes|prefixes` 若存在必须是 `/` 开头的字符串数组）。
/// - `Qt/src/ProviderRegistry.cpp` 的 `loadManifestFallback`：**插件 manifest 本身就是
///   descriptor 的超集**，装载时按 `descriptorFields` 逐键拷进 descriptor。所以这里只需要
///   一个解析器，`descriptor == manifest` 形状即可（本文件正是按该前提写的）。
/// - `Qt/src/ProviderRegistry.cpp:251-267` `loginMethods(id)` = `descriptor["login"]["methods"]`，
///   每项至少要有 `id`；`loginMethod(id, method)` 按 `id` 线性查找。
/// - 内置 `MusicBridge/plugins/descriptors/siren.json`、`local.json`（schemaVersion 2），
///   打包进 Flutter assets（`pubspec.yaml` 的 `MusicBridge/plugins/descriptors/`）。
///
/// 本文件是**纯 Dart**：不 import flutter，不触网、不写盘。
library;

/// 平台描述符解析失败的原因（与 Qt 的拒绝条件一一对应）。
///
/// 文案与 `Qt/src/Host.cpp` 的插件校验串同源，出现在插件页/平台页之前，所以保持原样。
class ProviderDescriptorError implements Exception {
  const ProviderDescriptorError(this.message);

  /// 可显示的中文原因。
  final String message;

  @override
  String toString() => 'ProviderDescriptorError($message)';
}

/// 一个平台（Qt `ProviderRegistry` 里的 descriptor）的全部纯数据。
///
/// 字段全部是 `final`，构造只走 [ProviderDescriptor.parse]；UI 侧只读。
class ProviderDescriptor {
  const ProviderDescriptor({
    required this.id,
    required this.name,
    required this.label,
    required this.detail,
    required this.sessionLabel,
    required this.archiveIdPrefix,
    required this.order,
    required this.isDefault,
    required this.columns,
    required this.sourceOrder,
    required this.lanes,
    required this.likedModel,
    required this.playlistNameMaxLength,
    required this.playlistEditableRule,
    required this.capabilities,
    required this.operations,
    required this.loginMethods,
    required this.loginFailureMessages,
    required this.loginPollIntervalMs,
    required this.loginTimeoutMs,
    required this.loginRequired,
    required this.qualityDefault,
    required this.qualityOptions,
    required this.discoverEnabled,
    required this.discoverTabs,
    required this.discoverDefaultTab,
    required this.strings,
    required this.variants,
    required this.variantPreferenceKey,
    required this.maxQueryLength,
    required this.userInstalled,
    required this.raw,
  });

  /// 平台 id（siren / local / netease / qq / kugou / …）。
  final String id;

  /// 中文显示名（`display.name`）。
  final String name;

  /// 拉丁标签（`display.label`），缺省为 id 大写。
  final String label;

  /// 一句话定位（`display.detail`）。
  final String detail;

  /// 会话标签（`display.sessionLabel`），缺省 `label + ' SESSION'`。
  final String sessionLabel;

  /// 档案编号前缀（`display.archiveIdPrefix`）。
  final String archiveIdPrefix;

  /// 排序权重（`display.order`，缺省 100）。
  final int order;

  /// `display.default`。
  final bool isDefault;

  /// 资料库列名（`library.columns`）。
  final List<String> columns;

  /// 列的来源顺序（`library.sourceOrder`）。
  final List<int> sourceOrder;

  /// 列数（`library.lanes`，缺省为 [columns] 长度）。
  final int lanes;

  /// 收藏模型（`library.likedModel`：local / likedIDs）。
  final String likedModel;

  /// 歌单名长度上限（`library.playlistNameMaxLength`）。
  final int playlistNameMaxLength;

  /// 歌单可编辑规则（`library.playlistEditableRule`：owned / all）。
  final String playlistEditableRule;

  /// 能力开关（`capabilities`，原始混合类型，见 [capability]）。
  final Map<String, Object?> capabilities;

  /// 操作开关（`operations`，见 [operation]）。
  final Map<String, Object?> operations;

  /// 登录方式（`login.methods`，每项是一份原始 map，见 [loginMethod]）。
  final List<Map<String, Object?>> loginMethods;

  /// 登录失败文案表（`login.failureMessages`：键 → 可显示中文）。
  final Map<String, String> loginFailureMessages;

  /// 二维码轮询间隔（`login.pollIntervalMs`，Qt 夹到 100..60000）。
  final int loginPollIntervalMs;

  /// 二维码轮询总超时（`login.pollTimeoutMs`，Qt 取 max(interval, value)）。
  final int loginTimeoutMs;

  /// `login.required`（缺省 false：不登录也能用）。
  final bool loginRequired;

  /// 默认音质键（`quality.default`）。
  final String qualityDefault;

  /// 音质档位（`quality.options`，每项 `{id,label,tier}`）。
  final List<Map<String, Object?>> qualityOptions;

  /// `discover.enabled`。
  final bool discoverEnabled;

  /// 发现页 tab（`discover.tabs`，每项 `{id,label}`）。
  final List<Map<String, Object?>> discoverTabs;

  /// 发现页默认 tab（`discover.defaultTab`）。
  final String discoverDefaultTab;

  /// 文案表（`strings`）。
  final Map<String, String> strings;

  /// 变体（`variants`，每项 `{id,label}`）；非空时切平台会先选变体。
  final List<Map<String, Object?>> variants;

  /// 变体偏好键（`variantPreference`）。
  final String variantPreferenceKey;

  /// 检索词上限（`search.maxQueryLength`，缺省 100）。
  final int maxQueryLength;

  /// 是否来自用户插件目录（可卸载），而不是构建期内置 descriptor。
  final bool userInstalled;

  /// 原始 JSON（调试/诊断用，不参与业务判断）。
  final Map<String, Object?> raw;

  /// 布尔能力：`capabilities[key]`（Qt `ProviderRegistry::capability`，缺省 `fallback`）。
  bool capability(String key, {bool fallback = true}) => _flag(capabilities[key], fallback);

  /// 布尔操作面：`operations[key]`（Qt 用同一份 JSON 判断某个操作是否可用）。
  bool operation(String key, {bool fallback = false}) => _flag(operations[key], fallback);

  /// 文案：`strings[key]`（Qt `ProviderRegistry::text`，缺失返回空串）。
  String text(String key) => strings[key] ?? '';

  /// 按 id 找登录方式（Qt `ProviderRegistry::loginMethod` 的线性查找）。
  Map<String, Object?>? loginMethod(String method) {
    for (final Map<String, Object?> entry in loginMethods) {
      if ('${entry['id'] ?? ''}' == method) {
        return entry;
      }
    }
    return null;
  }

  /// 是否声明了短信（手机号）登录方式（Qt `smsLoginMethod` 按 `type == 'sms'` 找）。
  Map<String, Object?>? get smsLoginMethod {
    for (final Map<String, Object?> entry in loginMethods) {
      if ('${entry['type'] ?? ''}' == 'sms') {
        return entry;
      }
    }
    return null;
  }

  /// 首个登录方式 id（Qt 切平台时 `loginMethod = methods.first().id`，缺省 'qr'）。
  String get defaultLoginMethod {
    if (loginMethods.isEmpty) {
      return '';
    }
    final String id = '${loginMethods.first['id'] ?? ''}';
    return id.isEmpty ? 'qr' : id;
  }

  /// 变体显示名（Qt `nameForVariant`：`display.nameByVariant[variant]` 优先）。
  String nameForVariant(String variant) {
    if (variant.isEmpty) {
      return name;
    }
    final Object? display = raw['display'];
    if (display is Map) {
      final Object? names = display['nameByVariant'];
      if (names is Map) {
        final Object? value = names[variant];
        if (value is String && value.isNotEmpty) {
          return value;
        }
      }
    }
    return name;
  }

  /// 解析一份 descriptor/manifest（同一形状）。
  ///
  /// 校验顺序与 `Qt/src/ProviderRegistry.cpp` 同：先 `validDescriptor` 的硬条件，
  /// 再逐字段容错读（缺失一律退到 Qt 的缺省值，绝不抛字段级异常）。
  static ProviderDescriptor parse(
    Map<String, Object?> json, {
    bool userInstalled = false,
  }) {
    if ('${json['schemaVersion'] ?? ''}' != '2') {
      throw const ProviderDescriptorError('平台描述符版本不受支持');
    }
    final String id = _trim(json['id']);
    if (id.isEmpty) {
      throw const ProviderDescriptorError('平台描述符缺少 id');
    }
    final Object? display = json['display'];
    if (display is! Map) {
      throw const ProviderDescriptorError('平台描述符缺少 display');
    }
    final Object? capabilities = json['capabilities'];
    if (capabilities is! Map) {
      throw const ProviderDescriptorError('平台描述符缺少 capabilities');
    }
    final Map<String, Object?> displayMap = _map(display);
    final String label = _text(displayMap['label'], id.toUpperCase());
    final Object? library = json['library'];
    final Map<String, Object?> libraryMap = _map(library);
    final List<String> columns = _stringList(libraryMap['columns']);
    final String name = _text(displayMap['name'], id);
    final String sessionLabel = _text(displayMap['sessionLabel'], '$label SESSION');
    final Object? quality = json['quality'];
    final Map<String, Object?> qualityMap = _map(quality);
    final Object? login = json['login'];
    final Map<String, Object?> loginMap = _map(login);
    final Object? discover = json['discover'];
    final Map<String, Object?> discoverMap = _map(discover);
    final Object? search = json['search'];
    final Map<String, Object?> searchMap = _map(search);
    final List<Map<String, Object?>> loginMethods = <Map<String, Object?>>[
      for (final Object? value in _list(loginMap['methods']))
        if (value is Map) ...<Map<String, Object?>>[_map(value)],
    ];
    final Map<String, String> failures = <String, String>{};
    final Object? failureRaw = loginMap['failureMessages'];
    if (failureRaw is Map) {
      for (final MapEntry<Object?, Object?> entry in failureRaw.entries) {
        failures['${entry.key}'] = '${entry.value}';
      }
    }
    return ProviderDescriptor(
      id: id,
      name: name,
      label: label,
      detail: _text(displayMap['detail'], ''),
      sessionLabel: sessionLabel,
      archiveIdPrefix: _text(displayMap['archiveIdPrefix'], ''),
      order: _int(displayMap['order'], 100),
      isDefault: _flag(displayMap['default'], false),
      columns: columns,
      sourceOrder: <int>[
        for (final Object? value in _list(libraryMap['sourceOrder']))
          if (value is num) value.toInt(),
      ],
      lanes: _int(libraryMap['lanes'], columns.length),
      likedModel: _text(libraryMap['likedModel'], 'local'),
      playlistNameMaxLength: _int(libraryMap['playlistNameMaxLength'], 100),
      playlistEditableRule: _text(libraryMap['playlistEditableRule'], 'owned'),
      capabilities: _map(capabilities),
      operations: _map(json['operations']),
      loginMethods: loginMethods,
      loginFailureMessages: failures.isEmpty
          ? const <String, String>{}
          : Map<String, String>.of(failures),
      loginPollIntervalMs: _int(loginMap['pollIntervalMs'], 1000),
      loginTimeoutMs: _int(loginMap['pollTimeoutMs'], 300000),
      loginRequired: _flag(loginMap['required'], false),
      qualityDefault: _text(qualityMap['default'], ''),
      qualityOptions: <Map<String, Object?>>[
        for (final Object? value in _list(qualityMap['options']))
          if (value is Map) ...<Map<String, Object?>>[_map(value)],
      ],
      discoverEnabled: _flag(discoverMap['enabled'], false),
      discoverTabs: <Map<String, Object?>>[
        for (final Object? value in _list(discoverMap['tabs']))
          if (value is Map) ...<Map<String, Object?>>[_map(value)],
      ],
      discoverDefaultTab: _text(discoverMap['defaultTab'], ''),
      strings: _stringMap(json['strings']),
      variants: <Map<String, Object?>>[
        for (final Object? value in _list(json['variants']))
          if (value is Map) ...<Map<String, Object?>>[_map(value)],
      ],
      variantPreferenceKey: _text(json['variantPreference'], ''),
      maxQueryLength: _int(searchMap['maxQueryLength'], 100),
      userInstalled: userInstalled,
      raw: Map<String, Object?>.of(json),
    );
  }

  /// 只读一份 manifest 的版本/入口（插件市场与插件页用，不参与 descriptor 语义）。
  static String manifestVersion(Map<String, Object?> json) => _trim(json['version']);
}

String _trim(Object? value) => value is String ? value.trim() : '';

String _text(Object? value, String fallback) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return fallback;
}

int _int(Object? value, int fallback) {
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? fallback;
  }
  return fallback;
}

bool _flag(Object? value, bool fallback) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  if (value is String) {
    if (value == 'true') {
      return true;
    }
    if (value == 'false') {
      return false;
    }
  }
  return fallback;
}

Map<String, Object?> _map(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> entry in value.entries)
        '${entry.key}': entry.value,
    };
  }
  return const <String, Object?>{};
}

Map<String, String> _stringMap(Object? value) {
  if (value is Map) {
    return <String, String>{
      for (final MapEntry<Object?, Object?> entry in value.entries)
        '${entry.key}': '${entry.value}',
    };
  }
  return const <String, String>{};
}

List<Object?> _list(Object? value) => value is List ? value : const <Object?>[];

List<String> _stringList(Object? value) {
  if (value is! List) {
    return const <String>[];
  }
  return <String>[
    for (final Object? entry in value)
      if (entry is String && entry.isNotEmpty) entry,
  ];
}
