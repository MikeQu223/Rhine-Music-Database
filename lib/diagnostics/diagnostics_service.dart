// lib/diagnostics/diagnostics_service.dart
//
// Qt parity source (read-only evidence, line numbers are the grounds for every field):
//   Qt/src/PlaybackDiagnostics.h:7-24    class shape (start/stop/clear/record/report/
//                                        session/numericFields; m_recording=false,
//                                        m_omitted=0, m_session=0)
//   Qt/src/PlaybackDiagnostics.cpp:5-11   start(): ++m_session, events cleared, omitted=0,
//                                        clock.start(), recording=true
//   Qt/src/PlaybackDiagnostics.cpp:13-18  clear(): recording=false, events cleared,
//                                        omitted=0, ++m_session (clock NOT restarted)
//   Qt/src/PlaybackDiagnostics.cpp:20-22  stop(): recording=false
//   Qt/src/PlaybackDiagnostics.cpp:24-104 numericFields() whitelist, 72 keys, source order
//   Qt/src/PlaybackDiagnostics.cpp:106-125 record(): fixed events, 8192 cap, relative elapsedMs
//   Qt/src/PlaybackDiagnostics.cpp:127-164 report(): fixed shape, notes and codes verbatim
//
// Data-independence rule (Qt/src/PlaybackDiagnostics.h:6, .cpp:138-140): only the fixed
// event names and the bool/finite-number whitelist can reach a record. Raw errors, URLs,
// hosts, IPs, headers, payloads, account, track, file paths, device names and device IDs
// have no entry point into this class. Device output samples and network packet-loss /
// DNS-TLS timing are reported as unavailable (false), never faked.
//
// Zero imports on purpose: the class mirrors Qt value semantics only, and its relative
// clock is injected (no direct DateTime.now anywhere), so tests stay deterministic.
// `Map<String, Object?>` below is the null-safe spelling of the brief's Map<String, dynamic>.

/// Relative elapsed-time source, injected for deterministic tests.
typedef DiagnosticElapsed = Duration Function();

/// Qt/src/PlaybackDiagnostics.cpp:110-113 — fixed event whitelist in source order.
const List<String> kDiagnosticEvents = <String>[
  'snapshot',
  'load',
  'load-rejected',
  'control',
  'media-status',
  'playback-state',
  'error',
  'buffer',
  'metadata',
  'output',
  'request-start',
  'request-finish',
  'upstream',
  'stalled',
  'media-transfer',
];

/// Qt/src/PlaybackDiagnostics.cpp:117 — `if (m_events.size() >= 8192)`.
const int kDiagnosticEventLimit = 8192;

/// Qt/src/PlaybackDiagnostics.cpp:133 — `{"upstreamEventLimitPerRequest", 64}`.
const int kUpstreamEventLimitPerRequest = 64;

/// Qt/src/PlaybackDiagnostics.cpp:132 — verbatim.
const String kUpstreamHttpCoverage =
    'shared-axios-and-global-fetch; other SDK transports may be unavailable';

/// Qt/src/PlaybackDiagnostics.cpp:138-140 — verbatim (the three C++ literals joined).
const String kDiagnosticNotes =
    'Relative times only. Request success is not media transfer success. Decoded frames do not prove audible device output. No raw errors, URLs, hosts, IPs, headers, payloads, account, track, file paths, device names or device IDs are collected.';

/// Qt/src/PlaybackDiagnostics.cpp:26-97 — numeric whitelist, source order.
///
/// Counting basis: the source lists one quoted key per line, from "sourceSerial"
/// (line 26) through "networkCaptive" (line 97) = 72 keys in source order; the atom
/// brief and this file both state 72, and test/platform/diagnostics_test.dart asserts
/// kDiagnosticNumericFields.length == 72.
const List<String> kDiagnosticNumericFields = <String>[
  'sourceSerial',
  'mediaStatus',
  'playbackState',
  'errorCode',
  'backendFailureCategory',
  'reportedHttpStatus',
  'playing',
  'latchedError',
  'pendingFailure',
  'recoverable',
  'mediaHttpStatus',
  'mediaNetworkError',
  'mediaTransferBytes',
  'mediaExpectedBytes',
  'mediaReconnects',
  'mediaTransferActive',
  'mediaTransferFailed',
  'hasActiveSource',
  'controllerFailed',
  'controllerLoading',
  'controllerPlaying',
  'positionMs',
  'durationMs',
  'seekable',
  'bufferProgress',
  'requested',
  'volume',
  'muted',
  'endedSerial',
  'recoveryPositionMs',
  'outputUnavailable',
  'outputCount',
  'outputPreferredSampleRateHz',
  'outputPreferredChannels',
  'outputPreferredSampleFormat',
  'outputChannelConfig',
  'outputChanged',
  'sampleRateHz',
  'channels',
  'sampleFormat',
  'decodedBuffers',
  'decodedBytes',
  'decodedFrames',
  'lastDecodedElapsedMs',
  'lastDecodedEndMs',
  'codec',
  'bitrate',
  'sourceKind',
  'provider',
  'action',
  'elapsedMs',
  'serviceCode',
  'upstreamHttpStatus',
  'upstreamCode',
  'transportFailed',
  'stale',
  'requestSerial',
  'operation',
  'queueMs',
  'workerMs',
  'requestDurationMs',
  'workerOffsetMs',
  'replyBytes',
  'networkError',
  'httpPhase',
  'omittedUpstreamEvents',
  'bridgeState',
  'bridgeError',
  'networkReachability',
  'networkTransport',
  'networkMetered',
  'networkCaptive',
];

/// Qt/src/PlaybackDiagnostics.cpp:141-164 — code legend, verbatim.
const Map<String, String> kDiagnosticCodes = <String, String>{
  'mediaStatus': 'QMediaPlayer::MediaStatus',
  'playbackState': 'QMediaPlayer::PlaybackState',
  'errorCode': 'QMediaPlayer::Error',
  'backendFailureCategory': 'Heuristic:0=unknown,1=timeout,2=dns,3=reset,4=invalid-data,5=codec,6=audio-device,7=permission,8=tls,9=eof,10=not-found,11=http',
  'reportedHttpStatus': '0=unavailable; otherwise extracted from an explicit backend HTTP error',
  'mediaHttpStatus': 'HTTP status from managed media stream; 0=unavailable',
  'mediaNetworkError': 'QNetworkReply::NetworkError',
  'sampleFormat': 'QAudioFormat::SampleFormat',
  'bridgeState': 'QProcess::ProcessState',
  'bridgeError': 'QProcess::ProcessError; may reflect the last error',
  'stale': 'credential epoch mismatch; playback request validity is managed separately',
  'provider': '0=other,1=netease,2=qq,3=kugou,4=local,5=siren',
  'sourceKind': '0=other,1=https,2=http,3=local-file',
  'action': '0=other,1=pause,2=resume,3=stop,4=seek,5=volume',
  'operation': '1=playback,2=preview,3=media-url,4=other-playback-upstream,5=upstream-http',
  'codec': 'QMediaFormat::AudioCodec; -1=unknown',
  'httpPhase': '1=response-headers-only(fetch),2=response-complete(axios)',
  'networkError': '0=other,1=timeout,2=reset,3=dns-not-found,4=dns-retry,5=refused,6=network-unreachable,7=host-unreachable,8=canceled',
  'networkReachability': 'QNetworkInformation::Reachability; absent=unavailable',
  'networkTransport': 'QNetworkInformation::TransportMedium; absent=unavailable',
};

/// Qt/src/PlaybackDiagnostics.cpp:131 — `{"mediaHttpStatusAvailable", true}`.
const bool kMediaHttpStatusAvailable = true;

/// Qt/src/PlaybackDiagnostics.cpp:134 — `{"networkPacketLossAvailable", false}`.
const bool kNetworkPacketLossAvailable = false;

/// Qt/src/PlaybackDiagnostics.cpp:135 — `{"networkDnsTlsTimingAvailable", false}`.
const bool kNetworkDnsTlsTimingAvailable = false;

/// Qt/src/PlaybackDiagnostics.cpp:136 — `{"mediaTransferBytesAvailable", true}`.
const bool kMediaTransferBytesAvailable = true;

/// Qt/src/PlaybackDiagnostics.cpp:137 — `{"deviceOutputSamplesAvailable", false}`.
const bool kDeviceOutputSamplesAvailable = false;

/// Read-only capability view of the report flags (Qt/src/PlaybackDiagnostics.cpp:131-137).
class DiagnosticsCapabilities {
  const DiagnosticsCapabilities({
    required this.mediaHttpStatusAvailable,
    required this.upstreamHttpCoverage,
    required this.upstreamEventLimitPerRequest,
    required this.networkPacketLossAvailable,
    required this.networkDnsTlsTimingAvailable,
    required this.mediaTransferBytesAvailable,
    required this.deviceOutputSamplesAvailable,
  });

  final bool mediaHttpStatusAvailable;
  final String upstreamHttpCoverage;
  final int upstreamEventLimitPerRequest;
  final bool networkPacketLossAvailable;
  final bool networkDnsTlsTimingAvailable;
  final bool mediaTransferBytesAvailable;
  final bool deviceOutputSamplesAvailable;
}

/// The single capability instance consumed by [DiagnosticsService.report]; values are
/// the Qt report literals above, not new thresholds.
const DiagnosticsCapabilities kDiagnosticsCapabilities = DiagnosticsCapabilities(
  mediaHttpStatusAvailable: kMediaHttpStatusAvailable,
  upstreamHttpCoverage: kUpstreamHttpCoverage,
  upstreamEventLimitPerRequest: kUpstreamEventLimitPerRequest,
  networkPacketLossAvailable: kNetworkPacketLossAvailable,
  networkDnsTlsTimingAvailable: kNetworkDnsTlsTimingAvailable,
  mediaTransferBytesAvailable: kMediaTransferBytesAvailable,
  deviceOutputSamplesAvailable: kDeviceOutputSamplesAvailable,
);

/// Platform ids used by the settings capability matrix.
/// Evidence: Qt/src/MobileTarget.h:12 (`Q_OS_IOS || Q_OS_ANDROID` -> RHINE_MOBILE),
/// Qt/src/MobileTarget.h:22 (`Q_OS_LINUX && !Q_OS_ANDROID` -> desktop Linux),
/// Qt/src/PlatformFeatures.h:20 (`Q_OS_MACOS || Q_OS_WIN`).
const List<String> kPlatformCapabilityPlatforms = <String>[
  'android',
  'ios',
  'windows',
  'macos',
  'linux',
];

/// Platform-service entries that must never disappear from a platform.
///
/// Evidence: Qt/src/SettingsSchema.cpp:697
/// `{SectionId::Performance, 3, 30, "PERFORMANCE", "性能与诊断", "performance", 220, alwaysVisible}`
/// and Qt/src/SettingsSchema.cpp:699
/// `{SectionId::Update, 5, 50, "SOFTWARE UPDATE", "软件更新", "update", 220, alwaysVisible}`
/// (both resolve to `alwaysVisible`, Qt/src/SettingsSchema.cpp:56-58). reports/T06-V2.json
/// asserts "Update 与 Performance 不得被排除" and the parity plan line 577 states
/// "平台能力开关按矩阵隐藏入口，不删能力" — matrix hiding is not capability removal.
const List<String> kPlatformServiceEntries = <String>[
  'update',
  'diagnostics',
  'consent',
];

/// Entry id -> Qt surface that hosts it.
/// update      -> Qt/src/SettingsSchema.cpp:699 SectionId::Update ("SOFTWARE UPDATE" / "软件更新")
/// diagnostics -> Qt/src/SettingsSchema.cpp:697 SectionId::Performance ("PERFORMANCE" / "性能与诊断")
/// consent     -> Qt/android/src/rhine/music/database/ConsentActivity.java, a pre-SDK gate;
///                SettingsSchema.cpp has no consent section id, so the surface name is the
///                activity itself and not an invented section.
const Map<String, String> kPlatformServiceEntrySurfaces = <String, String>{
  'update': 'SOFTWARE UPDATE',
  'diagnostics': 'PERFORMANCE',
  'consent': 'ConsentActivity',
};

/// Metric classes whose data is not produced at all, so no platform may present them as
/// evidence. Evidence is the Qt report itself, not a per-platform claim:
///   - deviceOutputSamples: Qt/src/PlaybackDiagnostics.cpp:137 `deviceOutputSamplesAvailable: false`
///   - networkPacketLoss:   Qt/src/PlaybackDiagnostics.cpp:134 `networkPacketLossAvailable: false`
///   - networkDnsTlsTiming: Qt/src/PlaybackDiagnostics.cpp:135 `networkDnsTlsTimingAvailable: false`
/// Those three flags are compile-time constants, so the same list holds on every platform;
/// the per-platform map repeats it rather than inventing platform-specific unavailability
/// that no Qt source states. Device pixel/performance proof is a separate device gate
/// (DEVICE_BLOCKED) and is not claimed here.
const List<String> _qtUnavailableMetricClasses = <String>[
  'deviceOutputSamples',
  'networkPacketLoss',
  'networkDnsTlsTiming',
];

/// Platform -> metric classes that stay unavailable while the "性能与诊断" entry itself
/// remains present on that platform (matrix hiding, never capability removal; plan line 577).
const Map<String, List<String>> kUnavailableDiagnosticMetricClasses =
    <String, List<String>>{
  'android': _qtUnavailableMetricClasses,
  'ios': _qtUnavailableMetricClasses,
  'windows': _qtUnavailableMetricClasses,
  'macos': _qtUnavailableMetricClasses,
  'linux': _qtUnavailableMetricClasses,
};

/// Read-only platform capability port: entry presence never depends on the platform
/// matrix; only entry visibility does (plan line 577).
class PlatformCapabilityQuery {
  const PlatformCapabilityQuery();

  /// Every entry in [kPlatformServiceEntries] exists on every platform; the matrix only
  /// decides whether the entry is shown.
  bool entryPresent(String entryId, String platform) =>
      kPlatformServiceEntries.contains(entryId) &&
      kPlatformCapabilityPlatforms.contains(platform);

  /// Unavailable metric classes for [platform]. A platform outside the matrix still
  /// inherits the three Qt compile-time `false` flags, because those are not platform
  /// claims; no other class is ever claimed unavailable.
  List<String> unavailableMetricClasses(String platform) =>
      List<String>.unmodifiable(kUnavailableDiagnosticMetricClasses[platform] ??
          _qtUnavailableMetricClasses);

  /// True when [metricClass] can be reported on [platform].
  bool metricClassAvailable(String metricClass, String platform) =>
      !unavailableMetricClasses(platform).contains(metricClass);
}

/// Qt parity port of `PlaybackDiagnostics` (Qt/src/PlaybackDiagnostics.h:7-24).
/// Public surface is exactly the Qt one: start/stop/clear/record/report/session plus the
/// static numericFields whitelist.
class DiagnosticsService {
  DiagnosticsService({DiagnosticElapsed? elapsed}) : _injectedElapsed = elapsed;

  final DiagnosticElapsed? _injectedElapsed;
  final Stopwatch _stopwatch = Stopwatch();
  bool _recording = false; // Qt/src/PlaybackDiagnostics.h:20, initial false
  final List<Map<String, Object?>> _events = <Map<String, Object?>>[]; // .h:22
  int _omitted = 0; // Qt/src/PlaybackDiagnostics.h:23, initial 0
  int _session = 0; // Qt/src/PlaybackDiagnostics.h:24, initial 0

  /// Qt/src/PlaybackDiagnostics.h:14-16.
  int get session => _session;

  Duration _elapsed() => _injectedElapsed?.call() ?? _stopwatch.elapsed;

  /// Qt/src/PlaybackDiagnostics.cpp:5-11.
  void start() {
    _session += 1;
    _events.clear();
    _omitted = 0;
    _stopwatch
      ..reset()
      ..start(); // m_clock.start() restarts the relative clock
    _recording = true;
  }

  /// Qt/src/PlaybackDiagnostics.cpp:13-18. clear() does not restart m_clock in Qt,
  /// so it does not restart the relative clock here either.
  void clear() {
    _recording = false;
    _events.clear();
    _omitted = 0;
    _session += 1;
  }

  /// Qt/src/PlaybackDiagnostics.cpp:20-22.
  void stop() {
    _recording = false;
  }

  /// Qt/src/PlaybackDiagnostics.cpp:24-104: keep a whitelisted key only when the value is
  /// a bool or a finite number (`value.isBool() || (value.isDouble() && std::isfinite(...))`);
  /// every other key and type is dropped.
  static Map<String, Object?> numericFields(Map<String, Object?> values) {
    final Map<String, Object?> safe = <String, Object?>{};
    for (final String key in kDiagnosticNumericFields) {
      final Object? value = values[key];
      if (value is bool || (value is num && value.isFinite)) {
        safe[key] = value;
      }
    }
    return safe;
  }

  /// Qt/src/PlaybackDiagnostics.cpp:106-125.
  void record(String event, Map<String, Object?> values) {
    if (!_recording) {
      return; // .cpp:107-109
    }
    if (!kDiagnosticEvents.contains(event)) {
      return; // .cpp:114-116: unknown event names are dropped without an error
    }
    if (_events.length >= kDiagnosticEventLimit) {
      _omitted += 1; // .cpp:117-120
      return;
    }
    final Map<String, Object?> safe = numericFields(values);
    // Qt/src/PlaybackDiagnostics.cpp:122 stores double(m_clock.elapsed()); QElapsedTimer has
    // millisecond resolution, so elapsedMs stays whole milliseconds instead of publishing
    // sub-millisecond precision Qt never reports.
    safe['elapsedMs'] = _elapsed().inMilliseconds.toDouble(); // .cpp:122, relative ms
    safe['event'] = event; // .cpp:123
    _events.add(safe); // .cpp:124
  }

  /// Qt/src/PlaybackDiagnostics.cpp:127-164: fixed shape; events are returned as copies
  /// (QJsonArray value semantics) and the notes/codes text is verbatim.
  Map<String, Object?> report() {
    return <String, Object?>{
      'events': _events
          .map((Map<String, Object?> entry) => Map<String, Object?>.of(entry))
          .toList(),
      'omittedEvents': _omitted,
      'mediaHttpStatusAvailable': kDiagnosticsCapabilities.mediaHttpStatusAvailable,
      'upstreamHttpCoverage': kDiagnosticsCapabilities.upstreamHttpCoverage,
      'upstreamEventLimitPerRequest':
          kDiagnosticsCapabilities.upstreamEventLimitPerRequest,
      'networkPacketLossAvailable':
          kDiagnosticsCapabilities.networkPacketLossAvailable,
      'networkDnsTlsTimingAvailable':
          kDiagnosticsCapabilities.networkDnsTlsTimingAvailable,
      'mediaTransferBytesAvailable':
          kDiagnosticsCapabilities.mediaTransferBytesAvailable,
      'deviceOutputSamplesAvailable':
          kDiagnosticsCapabilities.deviceOutputSamplesAvailable,
      'notes': kDiagnosticNotes,
      'codes': kDiagnosticCodes,
    };
  }
}
