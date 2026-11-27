// Qt -> Flutter 迁移 · 媒体状态共同值对象（MediaSnapshot）。
//
// 本文件是全仓唯一的「媒体状态共同元组」值对象。
// MediaSessionPort.update 只把它当类型使用（不读字段），因此字段命名可自定；
// 本类型不构成第二份队列 / session 状态，也不持有或替换任何播放器状态——
// 它只是 Qt platformMediaInfo() 一次上报所用的那七个值的不可变载体。
//
// 契约来源（逐条对照 Qt 原文，行号即依据）：
// - Qt/src/AndroidMediaSession.h:19-22  update(bool playing, qint64 positionMs, qint64 durationMs,
//                                       const QString &title, const QString &artist, const QString &album,
//                                       const QString &coverPath = {})：七个入参即本类型的七个字段，
//                                       顺序与类型逐一对齐（bool / 两个 64 位整数 / 四个 QString）。
// - Qt/src/AndroidMediaSession.h:19-20  title 为空或 duration <= 0 表示转入待机（服务保持前台保活）；
//                                       coverPath 是 C++ 侧已下载到应用私有目录的封面文件，为空表示无封面
//                                       → Dart 侧 coverPath 默认空串，即 Qt 的默认实参 {}。
// - Qt/src/AndroidMediaSession.h:24-25  stop()：播放被清空（切页/退出）→ 待机；
//                                       本类型不建模该动作，只承载待机判据的只读派生 isStandby。
// - Qt/src/PlatformAndroid.cpp:62-71    platformMediaInfo(title, artist, album, state, coverPath)：
//                                       :64 `if (title.isEmpty() || state.value("duration").toLongLong() <= 0)`
//                                       命中则 AndroidMediaSession::stop()（:66）并 return；
//                                       否则 ensureStarted()（:69）后用 state 的 playing（toBool）、
//                                       position（toLongLong）、duration（toLongLong）与
//                                       title/artist/album/coverPath 调 update（:70-71）。
// - Qt/src/AndroidMediaSession.cpp:58-66 update() 的 JNI 签名
//                                       "(ZJJLjava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V"：
//                                       Z=bool（playing），JJ=两个有符号 64 位整数（positionMs、durationMs）→ Dart int。
// - Qt/src/Platform.mm:170-181          同一共同元组的 iOS 侧消费点（title/artist/album + state 的
//                                       playing/duration/position）：待机判据与 Android 逐字一致
//                                       （:177 title.isEmpty() || duration.toLongLong() <= 0），
//                                       故这是跨平台共同元组，不是 Android 专有结构。
//
// 反例约束（KEEP OUT）：本文件不含网络 / 请求 / 播放控制 / 音频焦点 / 队列 / session / 通知 /
// 事件或回调语义；不含 fromJson / toJson（Qt 侧没有与之对应的协议形状，QVariantMap state 的
// 解析属于调用方边界，不属于本值对象）；不声明第二个状态类型，也不含任何常量词表。

/// 一次媒体状态上报的七个值（Qt/src/AndroidMediaSession.h:19-22 的 update 入参）。
///
/// 纯数据值对象：const 构造、全部字段 final、无校验、无副作用。
/// 数值字段是「已解析后的」qint64 等价物——QVariant::toLongLong() 的默认值语义
/// （非数值 / 缺失 / 空串 → 0）发生在调用方边界（PlatformAndroid.cpp:70-71），
/// 本类型不再做任何类型转换或截断。
class MediaSnapshot {
  /// 七个字段按 Qt update() 的形参顺序排列（AndroidMediaSession.h:21-22）。
  ///
  /// [coverPath] 默认空串，对齐 Qt 的默认实参 `const QString &coverPath = {}`
  /// （AndroidMediaSession.h:22）与其「为空表示无封面」的语义（:20）。
  /// 其余六个字段在 Qt 侧均无默认值，故此处一律 required。
  const MediaSnapshot({
    required this.playing,
    required this.positionMs,
    required this.durationMs,
    required this.title,
    required this.artist,
    required this.album,
    this.coverPath = '',
  });

  /// state.value("playing").toBool()（PlatformAndroid.cpp:70）。
  final bool playing;

  /// state.value("position").toLongLong()（PlatformAndroid.cpp:70）；毫秒。
  final int positionMs;

  /// state.value("duration").toLongLong()（PlatformAndroid.cpp:71）；毫秒。
  final int durationMs;

  /// Host::mediaMetadata 截断后的标题（Host.cpp:953 title.left(256)）；空串表示无标题。
  final String title;

  /// Host::mediaMetadata 截断后的艺术家（Host.cpp:954 artist.left(256)）。
  final String artist;

  /// Host::mediaMetadata 截断后的专辑名（Host.cpp:955 album.left(256)）。
  final String album;

  /// C++ 侧已下载到应用私有目录的封面文件路径（AndroidMediaSession.h:20）；
  /// 空串表示无封面。
  final String coverPath;

  /// 待机判据：title 为空 或 duration <= 0（PlatformAndroid.cpp:64，语义见
  /// AndroidMediaSession.h:19-20；iOS 侧 Platform.mm:177 逐字相同）。
  ///
  /// 这是只读派生，不是隐藏字段；置真时 Qt 的行为是 AndroidMediaSession::stop()
  /// （PlatformAndroid.cpp:66，播放态撤下而前台服务保活），该动作由调用方执行。
  bool get isStandby => title.isEmpty || durationMs <= 0;

  /// 纯值语义的部分更新：未给出的字段沿用当前值。
  ///
  /// 不引入哨兵值也不缓存任何状态；返回的是新实例。
  ///
  /// Dart 侧的纯值便利方法，不属于 Qt 的上报契约：AndroidMediaSession.h:11-25 只有
  /// setCommandCallback / ensureStarted / update / stop 四个入口，没有对应的复制语义符号；
  /// 保留它是因为 C2 允许纯值语义的 copyWith，且当前无必须调用方。
  MediaSnapshot copyWith({
    bool? playing,
    int? positionMs,
    int? durationMs,
    String? title,
    String? artist,
    String? album,
    String? coverPath,
  }) {
    return MediaSnapshot(
      playing: playing ?? this.playing,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      coverPath: coverPath ?? this.coverPath,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is MediaSnapshot &&
        other.playing == playing &&
        other.positionMs == positionMs &&
        other.durationMs == durationMs &&
        other.title == title &&
        other.artist == artist &&
        other.album == album &&
        other.coverPath == coverPath;
  }

  @override
  int get hashCode =>
      Object.hash(playing, positionMs, durationMs, title, artist, album, coverPath);

  @override
  String toString() => 'MediaSnapshot(playing: $playing, positionMs: $positionMs, '
      'durationMs: $durationMs, title: $title, artist: $artist, album: $album, '
      'coverPath: $coverPath)';
}
