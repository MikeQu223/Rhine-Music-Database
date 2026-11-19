// MV 侧：mv_track_validator.dart 的纯函数单测。
//
// 对照 Qt/src/MvController.cpp:589-592（状态串）、:655-658（地址校验）、:691（seek 阈值）。
// 纯 Dart：不建 Widget、不启动引擎、不碰文件与网络。

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/domain/mv/mv_track_validator.dart';

void main() {
  group('validateUrl', () {
    test('空串非法', () {
      expect(MvTrackValidator.validateUrl(''), mvInvalidUrlStatus);
    });

    test('非 http/https 前缀非法', () {
      expect(MvTrackValidator.validateUrl('ftp://example.com/video.mp4'), mvInvalidUrlStatus);
      expect(MvTrackValidator.validateUrl('file:///tmp/video.mp4'), mvInvalidUrlStatus);
      expect(MvTrackValidator.validateUrl('example.com/video.mp4'), mvInvalidUrlStatus);
    });

    test('Uri.tryParse 失败非法', () {
      expect(MvTrackValidator.validateUrl('http://[::1'), mvInvalidUrlStatus);
    });

    test('host 为空非法', () {
      expect(MvTrackValidator.validateUrl('https:///video.mp4'), mvInvalidUrlStatus);
      expect(MvTrackValidator.validateUrl('http://'), mvInvalidUrlStatus);
    });

    test('带 userInfo 非法（MvController.cpp:656-657）', () {
      expect(MvTrackValidator.validateUrl('https://user:pass@example.com/video.mp4'), mvInvalidUrlStatus);
      expect(MvTrackValidator.validateUrl('https://user@example.com/video.mp4'), mvInvalidUrlStatus);
    });

    test('合法 https 返回 null', () {
      expect(MvTrackValidator.validateUrl('https://example.com/video.mp4'), isNull);
      expect(MvTrackValidator.validateUrl('http://example.com/video.mp4'), isNull);
    });
  });

  group('statusFor', () {
    test('不支持来源优先（MvController.cpp:592）', () {
      expect(
        MvTrackValidator.statusFor(supported: false, hasTrack: true, url: 'https://example.com/v.mp4'),
        mvUnsupportedStatus,
      );
      expect(
        MvTrackValidator.statusFor(supported: false, hasTrack: false, url: ''),
        mvUnsupportedStatus,
      );
    });

    test('无曲目（MvController.cpp:590）', () {
      expect(
        MvTrackValidator.statusFor(supported: true, hasTrack: false, url: ''),
        mvIdleStatus,
      );
    });

    test('地址非法（MvController.cpp:658）', () {
      expect(
        MvTrackValidator.statusFor(supported: true, hasTrack: true, url: 'ftp://example.com/v.mp4'),
        mvInvalidUrlStatus,
      );
    });

    test('一切正常返回空串，由调用方拼静音跟随串（MvController.cpp:664）', () {
      expect(
        MvTrackValidator.statusFor(supported: true, hasTrack: true, url: 'https://example.com/v.mp4'),
        '',
      );
    });
  });

  group('shouldSeek', () {
    test('播放中阈值 400（MvController.cpp:691）', () {
      expect(MvTrackValidator.shouldSeek(1000, 1000, playing: true), isFalse);
      expect(MvTrackValidator.shouldSeek(1400, 1000, playing: true), isFalse);
      expect(MvTrackValidator.shouldSeek(1401, 1000, playing: true), isTrue);
      expect(MvTrackValidator.shouldSeek(1000, 1401, playing: true), isTrue);
      expect(MvTrackValidator.shouldSeek(1000, 1399, playing: true), isFalse);
    });

    test('暂停时阈值 100（MvController.cpp:691）', () {
      expect(MvTrackValidator.shouldSeek(1000, 1000, playing: false), isFalse);
      expect(MvTrackValidator.shouldSeek(1100, 1000, playing: false), isFalse);
      expect(MvTrackValidator.shouldSeek(1101, 1000, playing: false), isTrue);
      expect(MvTrackValidator.shouldSeek(1100, 1000, playing: true), isFalse, reason: '播放中 100ms 偏差不 seek');
    });
  });
}
