// Qt -> Flutter 迁移 · 共享模型 SHARED-S2：provider 身份模型（ProviderId）。
//
// 契约来源（逐条对照 Qt 原文，行号即依据）：
// - Qt/src/MusicApi.h:21         QString provider = "netease"：未显式赋值时的默认身份。
// - Qt/src/MusicApi.cpp:10-24    providerName()：local / qq / kugou / siren 命中；其余（netease、空串、未知值）
//                                一律返回「网易云音乐」。
// - Qt/src/MusicApi.cpp:61-70    call()：provider == "local" 时直接失败；否则路由
//                                "/native/" + provider + "/" + operation，
//                                参数 {{"args", arguments}}、adapted = true、allowed = {200}。
// - Qt/src/MusicApi.cpp:72-84    request()：provider == "local" 同样直接失败；仅当 provider != "netease" 时
//                                route = "/" + provider + route（netease 走裸路由）。
// - Qt/src/MusicLibrary.cpp:19-25、Qt/src/PlaybackService.cpp:37-41：Qt 侧 provider 取值集合固定为
//   {netease, qq, kugou, local, siren}；preference 里的其它值（含 QSettings 缺键读到的空串）由这两处
//   调用方归一到 "netease"。MusicApi 自身不改写 provider，它只做字符串比较（MusicApi.cpp:11/14/17/20/80）。
//   因此 ProviderId.parse 只把「缺省表示」（null 与空串）落到 netease 常量，其余未知非空值原样保留
//   （不 trim、不归一、不改大小写）；未知值的展示落到 providerName 的默认分支「网易云音乐」。
//
// 本文件是纯值对象，不含请求执行与生命周期逻辑：Qt 的迟到响应屏障（QPointer owner + valid()）
// 由 Dart 调用方负责，见 lib/domain/models/api_result.dart 顶部文档。

/// Qt/src/MusicApi.h:21 的 QString provider。
///
/// [wire] 与 Qt 字符串完全同字面（不 trim、不归一、大小写敏感）；唯一例外是 [parse] 的缺省分支
/// （null 与空串 → netease 常量，依据 Qt 调用方对非白名单值的归一，见 parse 文档）。
/// provider 是身份而不是封闭枚举，未知值必须保留原样，才能让 request() 的前缀语义与 Qt 一致。
///
/// 本类不重复 MusicData::item() 的 "key" 公式（Qt/src/MusicData.cpp:38）：该公式由
/// lib/domain/models/music_item.dart 的 MusicItem.key 独占持有，避免同一格式出现两处真源。
class ProviderId {
  /// 有线标识：Qt 的 provider 字符串本身。
  final String wire;

  const ProviderId(this.wire);

  /// Qt/src/MusicApi.cpp:11-13。
  static const ProviderId local = ProviderId('local');

  /// Qt/src/MusicApi.cpp:14-16。
  static const ProviderId qq = ProviderId('qq');

  /// Qt/src/MusicApi.cpp:17-19。
  static const ProviderId kugou = ProviderId('kugou');

  /// Qt/src/MusicApi.cpp:20-22。
  static const ProviderId siren = ProviderId('siren');

  /// Qt/src/MusicApi.cpp:23（默认分支）：provider == "netease" 时 providerName 也走这一支。
  static const ProviderId netease = ProviderId('netease');

  /// Qt/src/MusicApi.h:21 的默认身份。
  ///
  /// 缺省表示返回 netease 常量（identical 成立）：null，以及 Qt 从 QSettings 缺键读到的空串。
  /// 空串归到 netease 的依据不是 MusicApi，而是两处调用方对非白名单值的归一
  /// （Qt/src/MusicLibrary.cpp:19-25、Qt/src/PlaybackService.cpp:37-41）。
  /// 其余未知非空值原样保留且不归一，这与 MusicApi 一致：它只比较 provider 字符串，从不改写。
  static ProviderId parse(String? wire) {
    if (wire == null || wire.isEmpty) {
      return netease;
    }
    if (wire == 'netease') {
      return netease;
    }
    if (wire == 'qq') {
      return qq;
    }
    if (wire == 'kugou') {
      return kugou;
    }
    if (wire == 'siren') {
      return siren;
    }
    if (wire == 'local') {
      return local;
    }
    return ProviderId(wire);
  }

  /// Qt/src/MusicApi.cpp:62、:74：provider == "local" 时 call/request 直接失败，不发出任何请求。
  bool get isLocal => wire == 'local';

  /// Qt/src/MusicApi.cpp:80：只有 netease 不加前缀。
  bool get isNetease => wire == 'netease';

  /// Qt/src/MusicApi.cpp:10-24 providerName() 的逐字映射；
  /// 默认分支（netease / 空串 / 未知值）为「网易云音乐」。
  String get displayName {
    if (wire == 'local') {
      return '本地音乐';
    }
    if (wire == 'qq') {
      return 'QQ 音乐';
    }
    if (wire == 'kugou') {
      return '酷狗音乐';
    }
    if (wire == 'siren') {
      return '塞壬唱片';
    }
    return '网易云音乐';
  }

  /// Qt/src/MusicApi.cpp:80-82：netease 走裸路由（前缀为空串），其它身份前置 "/" + wire。
  String get routePrefix => isNetease ? '' : '/$wire';

  /// Qt/src/MusicApi.cpp:68："/native/" + provider + "/" + operation。
  ///
  /// 调用方在该路由上的固定包络是 {{"args": arguments}}、adapted = true、allowed = {200}。
  /// 注意：provider == "local" 时 Qt 根本不会构造该路由（先失败，见 Qt/src/MusicApi.cpp:62-67），
  /// 这个守卫由调用方完成（见 api_result.dart 的 ApiResult.localModeDisabled）。
  String nativeOperationRoute(String operation) => '/native/$wire/$operation';

  /// 与 Qt 直接比较 QString provider 的写法一致：字符串本身即身份。
  @override
  String toString() => wire;

  @override
  bool operator ==(Object other) => other is ProviderId && other.wire == wire;

  @override
  int get hashCode => wire.hashCode;
}
