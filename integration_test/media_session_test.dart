// DEVICE_BLOCKED / EXECUTION STATUS: NOT EXECUTED.
//
// This is the device slice for T25. It needs a real Android device or emulator
// with the app installed, so it is skipped by default and must not be reported
// as a pass. Planned command:
//
//   flutter test integration_test/media_session_test.dart -d <device-id>
//
// The skeleton only proves the facade is constructible and the channel names
// are the fixed cross-language contract. It does not start a foreground
// service, does not post a notification, and does not assert media buttons.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rhine_music_database/platform/media_session.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'media session facade constructs with the fixed channel names',
    (WidgetTester tester) async {
      final MethodChannelMediaSession session = MethodChannelMediaSession();
      expect(session, isA<MediaSessionPort>());
      expect(mediaSessionMethodChannelName,
          'rhine.music.database/media_session');
      expect(mediaSessionEventChannelName,
          'rhine.music.database/media_session/events');
      await session.dispose();
    },
    skip: true,
  );
}
