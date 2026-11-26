// 媒体会话的设备切片测试：需要已安装应用的 Android 设备，默认跳过。
//   flutter test integration_test/media_session_test.dart -d <device-id>
// 骨架只证明 facade 可构造、通道名是跨语言契约，不启动服务、不投递通知。

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
