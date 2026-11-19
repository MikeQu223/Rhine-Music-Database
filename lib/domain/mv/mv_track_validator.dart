/// Qt -> Flutter 迁移 · MV 侧的纯函数部分。
///
/// Qt 移植源：Qt/src/MvController.cpp
///   :589       supported = capabilities.mv && operations.mv
///   :590-592   m_status 的三元串：空曲目 / 不支持 / 正在查找
///   :655-658   MV 地址校验（scheme ∈ {http, https}、host 非空、userInfo 为空）
///   :664       MV 播放地址无效之外的成功串由调用方拼 `静音跟随音乐 · Np`
///   :691       sync 的 seek 阈值 `(playing ? 400 : 100)`
///
/// 纯函数层：MV 地址校验、状态串判定、音画 seek 判定。无状态、无 IO、
/// 不 import flutter、不 import lib/data。
///
/// 反例约束（KEEP OUT）：
/// - 不拼成功串：Qt :664 的 `静音跟随音乐 · %1p` 依赖 resolution，属于调用方的展示；
///   本文件的 statusFor 只判到空串为止；
/// - 不引入 Qt 之外的收藏/纠偏策略：Qt 的 sync 只按 :691 的阈值 setPosition，
///   不做倍速、不做淡入、不做漂移累计；
/// - 不解析视频 URL 的内容：只做 scheme/host/userInfo 三项准入（Qt :655-658）；
/// - 不缓存、不做网络请求：resolver 是宿主注入的端口。
library;

/// MV 播放地址的无效提示：Qt/src/MvController.cpp:658
const String mvInvalidUrlStatus = 'MV 播放地址无效';

/// 当前来源不支持 MV：Qt/src/MvController.cpp:592
const String mvUnsupportedStatus = '当前来源不支持关联 MV';

/// 尚无播放曲目：Qt/src/MvController.cpp:590（对应 Qt 的 `track.isEmpty()` 分支）
const String mvIdleStatus = '播放歌曲后，将自动查找关联 MV';

/// playing 时的 seek 阈值（毫秒）：Qt/src/MvController.cpp:691
const double mvSeekPlayingThresholdMs = 400;

/// 暂停时的 seek 阈值（毫秒）：Qt/src/MvController.cpp:691
const double mvSeekPausedThresholdMs = 100;

/// MV 侧纯函数。
abstract final class MvTrackValidator {
  /// 校验 MV 播放地址，合法返回 null，否则返回 [mvInvalidUrlStatus]。
  ///
  /// 逐条对应 Qt/src/MvController.cpp:655-658：
  /// 1. 空串 ⇒ 无效；
  /// 2. 不以 `http://` / `https://` 开头 ⇒ 无效（QUrl 的 scheme 只认这两个）；
  /// 3. `Uri.tryParse` 失败 ⇒ 无效；
  /// 4. host 为空 ⇒ 无效；
  /// 5. 带 userInfo ⇒ 无效（Qt 的 `!url.userInfo().isEmpty()`）。
  static String? validateUrl(String url) {
    if (url.isEmpty) {
      return mvInvalidUrlStatus;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return mvInvalidUrlStatus;
    }
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) {
      return mvInvalidUrlStatus;
    }
    if (uri.host.isEmpty) {
      return mvInvalidUrlStatus;
    }
    if (uri.userInfo.isNotEmpty) {
      return mvInvalidUrlStatus;
    }
    return null;
  }

  /// 状态串判定：Qt/src/MvController.cpp:590-592 的分支顺序。
  ///
  /// 返回空串表示“无异常”，由调用方拼 `静音跟随音乐 · Np`（Qt :664）。
  static String statusFor({
    required bool supported,
    required bool hasTrack,
    required String url,
  }) {
    if (!supported) {
      return mvUnsupportedStatus;
    }
    if (!hasTrack) {
      return mvIdleStatus;
    }
    if (validateUrl(url) != null) {
      return mvInvalidUrlStatus;
    }
    return '';
  }

  /// 是否应该把视频 seek 到音乐位置：Qt/src/MvController.cpp:691。
  ///
  /// `std::abs(m_video.position() - target) > (playing ? 400 : 100)`；
  /// 等于阈值时不 seek（Qt 用的是严格大于）。
  static bool shouldSeek(double videoMs, double musicMs, {required bool playing}) {
    return (videoMs - musicMs).abs() > (playing ? mvSeekPlayingThresholdMs : mvSeekPausedThresholdMs);
  }
}
