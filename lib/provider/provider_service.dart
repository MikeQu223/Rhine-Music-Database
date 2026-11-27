/// 平台服务：把 [ProviderRegistry] 与"每个平台一个网关"绑在一起，供 UI 与控制器使用。
///
/// 设计约束（来自当前进程事实，改之前先读 `lib/provider/provider_gateway.dart` 文件头）：
/// - 塞壬内置平台：Flutter 侧有真实 HTTP 实现（`SirenRepository`），但要由 Lead 接线时才注入；
///   在没注入之前本类给 `UnavailableProviderGateway`，状态串是"当前来源不支持该功能"。
/// - 第三方平台插件（netease/qq/kugou/bodian）：Flutter 侧没有 Node 运行时通道
///   （`NodeRuntimeHost.kt` 的 `prepare` 恒 `arch_blocked`、无 MethodChannel），所以它们的网关
///   一律是 `UnavailableProviderGateway`。这是**诚实的边界**，不要用假数据掩盖。
///
/// 本类不 import flutter，可在纯 Dart 测试里构造。
library;

import '../provider/provider_descriptor.dart';
import '../provider/provider_gateway.dart';
import '../provider/provider_registry.dart';

/// 平台服务：注册表 + 网关工厂 + 当前平台状态。
class ProviderService {
  ProviderService({
    required ProviderRegistry registry,
    ProviderGateway Function(ProviderDescriptor descriptor)? gatewayFactory,
    String? initialProvider,
  })  : _registry = registry,
        // ignore: prefer_initializing_formals
        _gatewayFactory = gatewayFactory,
        _currentId = initialProvider ?? registry.defaultId ?? '' {
    _gateway = _build(_currentId);
  }

  final ProviderRegistry _registry;
  final ProviderGateway Function(ProviderDescriptor descriptor)? _gatewayFactory;

  String _currentId;
  ProviderGateway? _gateway;

  /// 注册表（只读快照）。
  ProviderRegistry get registry => _registry;

  /// 当前平台 id。
  String get currentId => _currentId;

  /// 当前平台描述符（可能为空表，返回 null）。
  ProviderDescriptor? get current => _registry.descriptor(_currentId);

  /// 当前平台网关（永远非空；不可用平台返回 `UnavailableProviderGateway`）。
  ProviderGateway get gateway => _gateway ?? _build(_currentId)!;

  /// 当前平台中文名。
  String get currentName => _registry.name(_currentId);

  /// 当前平台是否有可用的真实网关（false = 只能显示"不支持"的占位状态）。
  bool get currentSupported => _gateway != null && _gateway is! UnavailableProviderGateway;

  /// 全部平台 id（按 `display.order` 排序）。
  List<String> get ids => _registry.ids;

  /// 某个平台的网关（不改变当前平台）。
  ProviderGateway gatewayFor(String id) => _build(id) ?? UnavailableProviderGateway(
        _registry.descriptor(id) ?? _fallbackDescriptor(id),
        reason: '当前来源不支持该功能',
      );

  /// 切换平台（Qt `MusicAccount::choose` 的数据面部分）。
  ///
  /// 返回 true 表示真的切换了；false 表示平台不存在或本来就选它。
  /// UI 层还要额外做 Qt 的那些动作（停播、清列表、写偏好），那些不在这里做。
  bool select(String id) {
    if (!_registry.contains(id) || id == _currentId) {
      return false;
    }
    _currentId = id;
    _gateway = _build(id);
    // 旧网关若在后台轮询，切换平台后由调用方负责 cancel；这里只丢弃引用。
    return true;
  }

  ProviderGateway? _build(String id) {
    final ProviderDescriptor? descriptor = _registry.descriptor(id);
    if (descriptor == null) {
      return null;
    }
    final ProviderGateway Function(ProviderDescriptor)? factory = _gatewayFactory;
    if (factory == null) {
      return null;
    }
    try {
      return factory(descriptor);
    } on Object {
      return null;
    }
  }

  ProviderDescriptor _fallbackDescriptor(String id) => ProviderDescriptor.parse(<String, Object?>{
        'schemaVersion': 2,
        'id': id,
        'display': <String, Object?>{'name': id},
        'capabilities': <String, Object?>{},
      });
}
