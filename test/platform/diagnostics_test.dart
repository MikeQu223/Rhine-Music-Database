// test/platform/diagnostics_test.dart
//
// Qt parity sources (line numbers are the grounds for every assertion):
//   Qt/src/PlaybackDiagnostics.h:7-24     class shape, initial field values
//   Qt/src/PlaybackDiagnostics.cpp:5-11    start()
//   Qt/src/PlaybackDiagnostics.cpp:13-18   clear()
//   Qt/src/PlaybackDiagnostics.cpp:20-22   stop()
//   Qt/src/PlaybackDiagnostics.cpp:24-104  numericFields() whitelist (72 keys)
//   Qt/src/PlaybackDiagnostics.cpp:106-125 record() gating, 8192 cap, relative elapsedMs
//   Qt/src/PlaybackDiagnostics.cpp:127-164 report() fixed shape, verbatim notes/codes
//   Qt/src/SettingsSchema.cpp:56-58,697,699  update/performance sections use alwaysVisible
//   Qt/src/MobileTarget.h:12,22 + Qt/src/PlatformFeatures.h:20  matrix platform ids
//
// EXECUTION STATUS: NOT EXECUTED. Running flutter test / dart test / dart analyze is
// forbidden in this tree; the file is written and statically reviewed only. The suite is
// recorded as RED/GREEN-unexecuted in reports/T27-C18-A3.json.
import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/diagnostics/diagnostics_service.dart';

/// Walks any report value and yields every scalar leaf, so the data-independence
/// assertions can scan the whole structure without dart:convert.
Iterable<Object?> leafValues(Object? value) sync* {
  if (value is Map) {
    for (final Object? entry in value.values) {
      yield* leafValues(entry);
    }
  } else if (value is Iterable) {
    for (final Object? entry in value) {
      yield* leafValues(entry);
    }
  } else {
    yield value;
  }
}

List<Map<String, Object?>> reportEvents(Map<String, Object?> report) =>
    (report['events']! as List<Object?>).cast<Map<String, Object?>>();

void main() {
  group('session semantics (PlaybackDiagnostics.cpp:5-18)', () {
    test('session starts at 0 and start() increments it', () {
      final DiagnosticsService service =
          DiagnosticsService(elapsed: () => Duration.zero);
      expect(service.session, 0); // .h:24 m_session = 0
      service.start();
      expect(service.session, 1); // .cpp:6 ++m_session
      service.start();
      expect(service.session, 2);
    });

    test('start() clears events/omitted and restarts the relative clock', () {
      Duration now = const Duration(milliseconds: 5);
      final DiagnosticsService service =
          DiagnosticsService(elapsed: () => now);
      service.start();
      now = const Duration(milliseconds: 40);
      service.record('load', <String, Object?>{'positionMs': 10});
      expect(reportEvents(service.report()).length, 1);

      service.start(); // .cpp:7-9 events cleared, omitted 0, clock restarted
      now = const Duration(milliseconds: 7);
      service.record('load', <String, Object?>{'positionMs': 11});
      final List<Map<String, Object?>> events = reportEvents(service.report());
      expect(events.length, 1);
      expect(events.single['elapsedMs'], 7.0); // relative to the latest start()
      expect(service.session, 2);
    });

    test('clear() increments session, clears events/omitted and ends recording', () {
      final DiagnosticsService service =
          DiagnosticsService(elapsed: () => Duration.zero);
      service.start();
      service.record('buffer', <String, Object?>{'positionMs': 1});
      final int beforeClear = service.session;

      service.clear(); // .cpp:13-18
      expect(service.session, beforeClear + 1); // .cpp:17 ++m_session
      expect(reportEvents(service.report()), isEmpty);
      expect(service.report()['omittedEvents'], 0);

      service.record('buffer', <String, Object?>{'positionMs': 2});
      expect(reportEvents(service.report()), isEmpty); // recording == false
    });

    test('stop() only ends recording and keeps session/events', () {
      final DiagnosticsService service =
          DiagnosticsService(elapsed: () => Duration.zero);
      service.start();
      service.record('buffer', <String, Object?>{'positionMs': 1});
      final int stoppedSession = service.session;

      service.stop(); // .cpp:20-22
      expect(service.session, stoppedSession);
      expect(reportEvents(service.report()).length, 1);
      service.record('buffer', <String, Object?>{'positionMs': 2});
      expect(reportEvents(service.report()).length, 1); // dropped after stop
    });
  });

  group('record gating (PlaybackDiagnostics.cpp:106-125)', () {
    test('record before start() is dropped', () {
      final DiagnosticsService service =
          DiagnosticsService(elapsed: () => Duration.zero);
      service.record('snapshot', <String, Object?>{'positionMs': 1});
      expect(reportEvents(service.report()), isEmpty);
      expect(service.session, 0);
    });

    test('unknown event names are dropped without error', () {
      final DiagnosticsService service =
          DiagnosticsService(elapsed: () => Duration.zero);
      service.start();
      service.record('not-an-event', <String, Object?>{'positionMs': 1});
      service.record('', <String, Object?>{'positionMs': 1});
      service.record('SNAPSHOT', <String, Object?>{'positionMs': 1}); // case sensitive
      service.record('media_status', <String, Object?>{'positionMs': 1});
      expect(reportEvents(service.report()), isEmpty); // .cpp:114-116
    });

    test('the 15 fixed event names are accepted in source order', () {
      // .cpp:110-113 verbatim.
      expect(kDiagnosticEvents, <String>[
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
      ]);
      expect(kDiagnosticEvents.length, 15);

      final DiagnosticsService service =
          DiagnosticsService(elapsed: () => Duration.zero);
      service.start();
      for (final String event in kDiagnosticEvents) {
        service.record(event, <String, Object?>{'positionMs': 1});
      }
      expect(
        reportEvents(service.report())
            .map((Map<String, Object?> entry) => entry['event'])
            .toList(),
        kDiagnosticEvents,
      );
    });

    test('8192 event cap counts omitted events (cpp:117-120)', () {
      expect(kDiagnosticEventLimit, 8192);
      final DiagnosticsService service =
          DiagnosticsService(elapsed: () => Duration.zero);
      service.start();
      for (int index = 0; index < kDiagnosticEventLimit; index += 1) {
        service.record('buffer', <String, Object?>{'positionMs': index});
      }
      expect(reportEvents(service.report()).length, 8192);
      expect(service.report()['omittedEvents'], 0);

      service.record('buffer', <String, Object?>{'positionMs': 8192});
      service.record('buffer', <String, Object?>{'positionMs': 8193});
      expect(reportEvents(service.report()).length, 8192);
      expect(service.report()['omittedEvents'], 2);
    });
  });

  group('numeric whitelist (PlaybackDiagnostics.cpp:24-104)', () {
    test('whitelist holds 72 keys in source order', () {
      // Counting basis: Qt/src/PlaybackDiagnostics.cpp:26-97 lists one quoted key
      // per line, "sourceSerial" (line 26) .. "networkCaptive" (line 97) = 72 keys,
      // matching the atom brief's 72-key count; the source is authoritative.
      expect(kDiagnosticNumericFields.length, 72);
      expect(kDiagnosticNumericFields.first, 'sourceSerial');
      expect(kDiagnosticNumericFields.last, 'networkCaptive');
      expect(kDiagnosticNumericFields.toSet().length, 72); // no duplicates
      expect(kDiagnosticNumericFields[25], 'requested');
      expect(kDiagnosticNumericFields[50], 'elapsedMs');
      expect(kDiagnosticNumericFields[69], 'networkTransport');
    });

    test('bool and finite numbers are kept, every other type is dropped', () {
      final Map<String, Object?> safe =
          DiagnosticsService.numericFields(<String, Object?>{
        'playing': true,
        'latchedError': false,
        'positionMs': 1234,
        'bufferProgress': 0.5,
        'nan': double.nan,
        'durationMs': double.nan,
        'seekable': double.infinity,
        'volume': double.negativeInfinity,
        'codec': 'aac', // string
        'mediaStatus': <String, Object?>{'raw': 'error'}, // object
        'provider': <Object?>['netease'], // list
        'stale': null,
      });

      expect(safe['playing'], true);
      expect(safe['latchedError'], false);
      expect(safe['positionMs'], 1234);
      expect(safe['bufferProgress'], 0.5);
      expect(safe.containsKey('nan'), isFalse);
      expect(safe.containsKey('durationMs'), isFalse);
      expect(safe.containsKey('seekable'), isFalse);
      expect(safe.containsKey('volume'), isFalse);
      expect(safe.containsKey('codec'), isFalse);
      expect(safe.containsKey('mediaStatus'), isFalse);
      expect(safe.containsKey('provider'), isFalse);
      expect(safe.containsKey('stale'), isFalse);
    });

    test('keys outside the whitelist never reach a record', () {
      final DiagnosticsService service =
          DiagnosticsService(elapsed: () => Duration.zero);
      service.start();
      service.record('error', <String, Object?>{
        'errorCode': 4,
        'url': 'SENTINEL_URL_sentinel',
        'host': 'SENTINEL_HOST_sentinel',
        'deviceId': 'SENTINEL_DEVICE_sentinel',
        'rawError': 'SENTINEL_ERROR_sentinel',
        'account': 'SENTINEL_ACCOUNT_sentinel',
        'track': 'SENTINEL_TRACK_sentinel',
        'filePath': 'SENTINEL_PATH_sentinel',
      });
      final Map<String, Object?> entry = reportEvents(service.report()).single;
      expect(entry['errorCode'], 4);
      expect(entry.keys.toSet(), <String>{'errorCode', 'elapsedMs', 'event'});
    });

    test('a caller supplied elapsedMs is overwritten by the relative clock', () {
      final DiagnosticsService service = DiagnosticsService(
          elapsed: () => const Duration(milliseconds: 321));
      service.start();
      service.record('stalled', <String, Object?>{'elapsedMs': 999999});
      final Map<String, Object?> entry = reportEvents(service.report()).single;
      expect(entry['elapsedMs'], 321.0); // .cpp:122 wins over the whitelisted value
      expect(entry['elapsedMs'], isNot(999999.0));
    });

    test('elapsedMs is whole milliseconds, like QElapsedTimer::elapsed', () {
      // Qt/src/PlaybackDiagnostics.cpp:122 stores double(m_clock.elapsed()); QElapsedTimer
      // has millisecond resolution, so sub-millisecond input truncates instead of leaking
      // precision Qt never reports.
      final DiagnosticsService service = DiagnosticsService(
          elapsed: () => const Duration(microseconds: 1500));
      service.start();
      service.record('buffer', <String, Object?>{});
      expect(reportEvents(service.report()).single['elapsedMs'], 1.0);
    });

    test('elapsedMs is relative (restarts per start), never a wall-clock value', () {
      Duration now = Duration.zero;
      final DiagnosticsService service =
          DiagnosticsService(elapsed: () => now);
      service.start();
      now = const Duration(milliseconds: 120);
      service.record('buffer', <String, Object?>{});
      now = const Duration(milliseconds: 150);
      service.record('buffer', <String, Object?>{});
      final List<double> elapsed = reportEvents(service.report())
          .map((Map<String, Object?> entry) => entry['elapsedMs']! as double)
          .toList();
      expect(elapsed, <double>[120.0, 150.0]);
      expect(elapsed.last, greaterThan(elapsed.first)); // relative, monotonic
    });
  });

  group('report shape (PlaybackDiagnostics.cpp:127-164)', () {
    test('fixed keys, verbatim coverage text and capability flags', () {
      final DiagnosticsService service =
          DiagnosticsService(elapsed: () => Duration.zero);
      final Map<String, Object?> report = service.report();
      expect(report.keys.toSet(), <String>{
        'events',
        'omittedEvents',
        'mediaHttpStatusAvailable',
        'upstreamHttpCoverage',
        'upstreamEventLimitPerRequest',
        'networkPacketLossAvailable',
        'networkDnsTlsTimingAvailable',
        'mediaTransferBytesAvailable',
        'deviceOutputSamplesAvailable',
        'notes',
        'codes',
      });
      expect(report['omittedEvents'], 0);
      expect(report['mediaHttpStatusAvailable'], true); // .cpp:131
      expect(report['upstreamHttpCoverage'],
          'shared-axios-and-global-fetch; other SDK transports may be unavailable'); // .cpp:132
      expect(report['upstreamEventLimitPerRequest'], 64); // .cpp:133
      expect(kUpstreamEventLimitPerRequest, 64);
      expect(report['networkPacketLossAvailable'], false); // .cpp:134
      expect(report['networkDnsTlsTimingAvailable'], false); // .cpp:135
      expect(report['mediaTransferBytesAvailable'], true); // .cpp:136
      expect(report['deviceOutputSamplesAvailable'], false); // .cpp:137
      expect(
        report['notes'],
        'Relative times only. Request success is not media transfer success. '
        'Decoded frames do not prove audible device output. No raw errors, URLs, '
        'hosts, IPs, headers, payloads, account, track, file paths, device names '
        'or device IDs are collected.',
      ); // .cpp:138-140 verbatim
    });

    test('codes legend is verbatim (cpp:141-164)', () {
      final Map<String, String> codes = kDiagnosticCodes;
      expect(codes.length, 20);
      expect(codes.keys.toSet(), <String>{
        'mediaStatus',
        'playbackState',
        'errorCode',
        'backendFailureCategory',
        'reportedHttpStatus',
        'mediaHttpStatus',
        'mediaNetworkError',
        'sampleFormat',
        'bridgeState',
        'bridgeError',
        'stale',
        'provider',
        'sourceKind',
        'action',
        'operation',
        'codec',
        'httpPhase',
        'networkError',
        'networkReachability',
        'networkTransport',
      });
      expect(codes['mediaStatus'], 'QMediaPlayer::MediaStatus');
      expect(codes['playbackState'], 'QMediaPlayer::PlaybackState');
      expect(codes['errorCode'], 'QMediaPlayer::Error');
      expect(
        codes['backendFailureCategory'],
        'Heuristic:0=unknown,1=timeout,2=dns,3=reset,4=invalid-data,5=codec,'
        '6=audio-device,7=permission,8=tls,9=eof,10=not-found,11=http',
      );
      expect(codes['reportedHttpStatus'],
          '0=unavailable; otherwise extracted from an explicit backend HTTP error');
      expect(codes['mediaHttpStatus'],
          'HTTP status from managed media stream; 0=unavailable');
      expect(codes['mediaNetworkError'], 'QNetworkReply::NetworkError');
      expect(codes['sampleFormat'], 'QAudioFormat::SampleFormat');
      expect(codes['bridgeState'], 'QProcess::ProcessState');
      expect(codes['bridgeError'],
          'QProcess::ProcessError; may reflect the last error');
      expect(codes['stale'],
          'credential epoch mismatch; playback request validity is managed separately');
      expect(codes['provider'], '0=other,1=netease,2=qq,3=kugou,4=local,5=siren');
      expect(codes['sourceKind'], '0=other,1=https,2=http,3=local-file');
      expect(codes['action'], '0=other,1=pause,2=resume,3=stop,4=seek,5=volume');
      expect(codes['operation'],
          '1=playback,2=preview,3=media-url,4=other-playback-upstream,5=upstream-http');
      expect(codes['codec'], 'QMediaFormat::AudioCodec; -1=unknown');
      expect(codes['httpPhase'],
          '1=response-headers-only(fetch),2=response-complete(axios)');
      expect(codes['networkError'],
          '0=other,1=timeout,2=reset,3=dns-not-found,4=dns-retry,5=refused,'
          '6=network-unreachable,7=host-unreachable,8=canceled');
      expect(codes['networkReachability'],
          'QNetworkInformation::Reachability; absent=unavailable');
      expect(codes['networkTransport'],
          'QNetworkInformation::TransportMedium; absent=unavailable');
    });

    test('report entries keep whitelist order, then elapsedMs, then event', () {
      final DiagnosticsService service =
          DiagnosticsService(elapsed: () => Duration.zero);
      service.start();
      service.record('control', <String, Object?>{
        'volume': 1,
        'muted': false,
        'positionMs': 3,
      });
      final Map<String, Object?> entry = reportEvents(service.report()).single;
      expect(entry.keys.toList(), <String>[
        'positionMs',
        'volume',
        'muted',
        'elapsedMs',
        'event',
      ]);
    });

    test('report events are copies, not the live recording buffer', () {
      final DiagnosticsService service =
          DiagnosticsService(elapsed: () => Duration.zero);
      service.start();
      service.record('buffer', <String, Object?>{'positionMs': 1});
      final List<Map<String, Object?>> first = reportEvents(service.report());
      first.single['positionMs'] = 999; // mutate the returned copy
      expect(reportEvents(service.report()).single['positionMs'], 1);
    });
  });

  group('data independence (PlaybackDiagnostics.h:6, .cpp:138-140)', () {
    test('no business string reaches the report, even as a whitelisted key value', () {
      final DiagnosticsService service =
          DiagnosticsService(elapsed: () => Duration.zero);
      service.start();
      service.record('error', <String, Object?>{
        'errorCode': 5,
        'url': 'SENTINEL_URL_sentinel',
        'host': 'SENTINEL_HOST_sentinel',
        'ip': 'SENTINEL_IP_sentinel',
        'header': 'SENTINEL_HEADER_sentinel',
        'payload': 'SENTINEL_PAYLOAD_sentinel',
        'account': 'SENTINEL_ACCOUNT_sentinel',
        'track': 'SENTINEL_TRACK_sentinel',
        'filePath': 'SENTINEL_PATH_sentinel',
        'deviceName': 'SENTINEL_DEVICE_NAME_sentinel',
        'deviceId': 'SENTINEL_DEVICE_ID_sentinel',
        'rawError': 'SENTINEL_RAW_ERROR_sentinel',
      });
      service.record('playback-state', <String, Object?>{
        'codec': 'SENTINEL_CODEC_sentinel', // string value on a whitelisted key
        'sampleFormat': 'SENTINEL_FORMAT_sentinel',
        'mediaHttpStatus': 'SENTINEL_STATUS_sentinel',
      });

      final Map<String, Object?> report = service.report();
      final List<String> strings = leafValues(report)
          .whereType<String>()
          .toList();
      expect(strings.any((String value) => value.contains('SENTINEL_')), isFalse);

      // The recorded entries carry only whitelisted numeric keys plus elapsedMs/event.
      for (final Map<String, Object?> entry in reportEvents(report)) {
        for (final String key in entry.keys) {
          expect(
            key == 'event' ||
                key == 'elapsedMs' ||
                kDiagnosticNumericFields.contains(key),
            isTrue,
          );
        }
        expect(entry['event'], isA<String>());
      }
    });

    test('device output samples and network loss/DNS-TLS timing stay unavailable', () {
      final Map<String, Object?> report = DiagnosticsService().report();
      expect(report['deviceOutputSamplesAvailable'], false);
      expect(report['networkPacketLossAvailable'], false);
      expect(report['networkDnsTlsTimingAvailable'], false);
      expect(kDiagnosticsCapabilities.deviceOutputSamplesAvailable, false);
      expect(kDiagnosticsCapabilities.networkPacketLossAvailable, false);
      expect(kDiagnosticsCapabilities.networkDnsTlsTimingAvailable, false);
    });
  });

  group('platform capability port', () {
    const PlatformCapabilityQuery query = PlatformCapabilityQuery();

    test('update/diagnostics/consent entries never disappear on any platform', () {
      expect(
        kPlatformServiceEntries,
        <String>['update', 'diagnostics', 'consent'],
      );
      for (final String platform in kPlatformCapabilityPlatforms) {
        for (final String entry in kPlatformServiceEntries) {
          expect(query.entryPresent(entry, platform), isTrue,
              reason: 'matrix hiding must not delete the $entry capability on $platform');
        }
      }
      expect(kPlatformServiceEntrySurfaces['update'], 'SOFTWARE UPDATE');
      expect(kPlatformServiceEntrySurfaces['diagnostics'], 'PERFORMANCE');
    });

    test('Qt-false metric classes stay unavailable on every matrix platform', () {
      // Qt/src/PlaybackDiagnostics.cpp:134,135,137 are compile-time false flags, so the
      // unavailability is global; the matrix repeats it per platform instead of inventing
      // platform-specific claims.
      const List<String> expected = <String>[
        'deviceOutputSamples',
        'networkPacketLoss',
        'networkDnsTlsTiming',
      ];
      for (final String platform in kPlatformCapabilityPlatforms) {
        expect(query.unavailableMetricClasses(platform), expected);
        expect(query.metricClassAvailable('deviceOutputSamples', platform), isFalse);
        expect(query.metricClassAvailable('networkPacketLoss', platform), isFalse);
        expect(query.metricClassAvailable('networkDnsTlsTiming', platform), isFalse);
        expect(query.metricClassAvailable('mediaHttpStatus', platform), isTrue);
        expect(query.metricClassAvailable('mediaTransferBytes', platform), isTrue);
      }
      // No metric class beyond the three Qt flags is invented anywhere in the matrix.
      expect(
        kUnavailableDiagnosticMetricClasses.values
            .expand((List<String> classes) => classes)
            .toSet(),
        expected.toSet(),
      );
      // A platform outside the matrix inherits only the Qt compile-time flags.
      expect(query.unavailableMetricClasses('plan9'), expected);
    });
  });
}
