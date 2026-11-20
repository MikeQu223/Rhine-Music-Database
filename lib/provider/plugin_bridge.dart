/// 插件平台的 Node 传输桥（Dart 侧）。
///
/// Kotlin 实现在 `android/app/src/main/kotlin/rhine/music/database/porting/`：
/// `PluginBridgeChannel.kt`（通道）+ `PluginBridge.kt`（TCP 行协议）+ `NodeHost.kt`
/// （`node::Start` 的 JNI 接缝），原生侧 `android/app/src/main/cpp/node_host.cpp`。
///
/// 协议真值是 `MusicBridge/ios-runtime.cjs`：内嵌 Node 连回本机，首帧 `{token}` 握手，
/// 之后一行一个 JSON；业务请求 `{id, route:'/native/<provider>/<operation>', params:{args}}`，
/// 响应 `{id, body:{code,value}, cookies}`。语义与 Qt `MusicApi::call` 一致。
library;

import 'package:flutter/services.dart';

/// 通道名，与 Kotlin `PluginBridgeChannel.channelName` 逐字节相同。
const String pluginBridgeChannelName = 'rhine.music/plugin_bridge';

/// 一次插件请求的结果。
class PluginBridgeReply {
  const PluginBridgeReply({this.value, this.error = '', this.cookies = const <String>[]});

  /// `body.value`（已转成普通 Dart 结构）。
  final Object? value;

  /// 失败原因（`body.message` / `body.errorKey` / 传输错误）；空串表示成功。
  final String error;

  /// 上游下发的 cookie（登录态需要它，但持久化由插件自己管）。
  final List<String> cookies;

  /// 是否成功。
  bool get ok => error.isEmpty;

  /// `value` 作为 Map 读（非 Map 时返回空表）。
  Map<String, Object?> get map {
    final Object? raw = value;
    if (raw is Map) {
      return raw.map((Object? key, Object? item) => MapEntry<String, Object?>('$key', item));
    }
    return const <String, Object?>{};
  }
}

/// 插件运行时状态（面板/诊断要显示真话，所以连资源根一起回报）。
class PluginBridgeStatus {
  const PluginBridgeStatus({
    this.running = false,
    this.session = '',
    this.error = '',
    this.resources = '',
    this.plugins = '',
    this.worker = false,
  });

  final bool running;
  final String session;
  final String error;
  final String resources;
  final String plugins;
  final bool worker;

  static PluginBridgeStatus fromMap(Object? raw) {
    if (raw is! Map) {
      return const PluginBridgeStatus(error: '插件通道不可用');
    }
    bool flag(Object? value) => value == true;
    String text(Object? value) => value == null ? '' : '$value';
    return PluginBridgeStatus(
      running: flag(raw['running']),
      session: text(raw['session']),
      error: text(raw['error']),
      resources: text(raw['resources']),
      plugins: text(raw['plugins']),
      worker: flag(raw['worker']),
    );
  }
}

/// 通道的薄封装：只负责编解码，不藏状态机。
class PluginBridgeClient {
  PluginBridgeClient({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(pluginBridgeChannelName);

  final MethodChannel _channel;

  /// 运行时状态（会顺带把 Node 拉起来，首次调用可能要等握手）。
  Future<PluginBridgeStatus> status() async {
    try {
      return PluginBridgeStatus.fromMap(await _channel.invokeMethod<Object?>('status'));
    } on PlatformException catch (error) {
      return PluginBridgeStatus(error: error.message ?? '插件通道调用失败');
    } on MissingPluginException {
      return const PluginBridgeStatus(error: '当前构建没有插件通道');
    }
  }

  /// 发一条 `/native/<provider>/<operation>` 请求。
  Future<PluginBridgeReply> request(
    String provider,
    String operation, [
    Object? args = const <Object?>[],
    Map<String, String> cookies = const <String, String>{},
  ]) async {
    try {
      final Object? raw = await _channel.invokeMethod<Object?>('request', <String, Object?>{
        'provider': provider,
        'operation': operation,
        'args': args,
        'cookies': cookies,
      });
      if (raw is! Map) {
        return const PluginBridgeReply(error: '插件通道返回了意外的结果');
      }
      final List<String> replyCookies = <String>[
        if (raw['cookies'] is List) ...<String>[for (final Object? item in raw['cookies'] as List) '$item'],
      ];
      if (raw['ok'] != true) {
        final String message = '${raw['error'] ?? ''}';
        return PluginBridgeReply(
          error: message.isEmpty ? '插件请求失败' : message,
          cookies: replyCookies,
        );
      }
      return PluginBridgeReply(value: raw['value'], cookies: replyCookies);
    } on PlatformException catch (error) {
      return PluginBridgeReply(error: error.message ?? '插件通道调用失败');
    } on MissingPluginException {
      return const PluginBridgeReply(error: '当前构建没有插件通道');
    }
  }
}
