import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/provider/provider_descriptor.dart';

/// descriptor 解析的契约测试。
///
/// 被测真值来自仓内两份 schemaVersion 2 descriptor（`MusicBridge/plugins/descriptors/`）
/// 与 Qt `ProviderRegistry` 的读取语义；这里只做纯数据校验，不读盘、不触网。
void main() {
  group('ProviderDescriptor.parse 拒绝条件与 Qt validDescriptor 一致', () {
    test('schemaVersion 不是 2 时拒绝', () {
      expect(
        () => ProviderDescriptor.parse(<String, Object?>{
          'schemaVersion': 3,
          'id': 'x',
          'display': <String, Object?>{},
          'capabilities': <String, Object?>{},
        }),
        throwsA(
          isA<ProviderDescriptorError>().having(
            (ProviderDescriptorError error) => error.message,
            'message',
            '平台描述符版本不受支持',
          ),
        ),
      );
    });

    test('缺少 id / display / capabilities 时分别拒绝', () {
      final Map<String, Object?> base = <String, Object?>{
        'schemaVersion': 2,
        'display': <String, Object?>{},
        'capabilities': <String, Object?>{},
      };
      expect(
        () => ProviderDescriptor.parse(base),
        throwsA(
          isA<ProviderDescriptorError>().having(
            (ProviderDescriptorError error) => error.message,
            'message',
            '平台描述符缺少 id',
          ),
        ),
      );
      expect(
        () => ProviderDescriptor.parse(<String, Object?>{
          'schemaVersion': 2,
          'id': 'x',
          'capabilities': <String, Object?>{},
        }),
        throwsA(
          isA<ProviderDescriptorError>().having(
            (ProviderDescriptorError error) => error.message,
            'message',
            '平台描述符缺少 display',
          ),
        ),
      );
      expect(
        () => ProviderDescriptor.parse(<String, Object?>{
          'schemaVersion': 2,
          'id': 'x',
          'display': <String, Object?>{},
        }),
        throwsA(
          isA<ProviderDescriptorError>().having(
            (ProviderDescriptorError error) => error.message,
            'message',
            '平台描述符缺少 capabilities',
          ),
        ),
      );
    });
  });

  group('siren descriptor 逐字段投影', () {
    final ProviderDescriptor siren = ProviderDescriptor.parse(_siren);

    test('显示面与排序', () {
      expect(siren.id, 'siren');
      expect(siren.name, '塞壬唱片');
      expect(siren.label, 'SIREN');
      expect(siren.qualityDefault, 'lossless');
      expect(siren.isDefault, isFalse);
      expect(siren.userInstalled, isFalse);
    });

    test('五列与来源顺序', () {
      expect(siren.columns, <String>['搜索结果', '喜欢的歌曲', '我的歌单', '全部歌曲', '全部专辑']);
      expect(siren.sourceOrder, <int>[1, 2, 3, 4, 0]);
      expect(siren.lanes, 5);
    });

    test('能力与操作面分流', () {
      expect(siren.capability('search'), isTrue);
      expect(siren.capability('account'), isFalse);
      expect(siren.capability('mv'), isFalse);
      // 未知能力按 Qt 缺省 true；未知操作按 false。
      expect(siren.capability('unknown'), isTrue);
      expect(siren.operation('unknown'), isFalse);
    });

    test('没有登录方式（内置平台无需登录）', () {
      expect(siren.loginMethods, isEmpty);
      expect(siren.smsLoginMethod, isNull);
      expect(siren.loginRequired, isFalse);
    });
  });

  group('netease 形状的插件 manifest 可作为 descriptor 使用', () {
    final ProviderDescriptor netease = ProviderDescriptor.parse(_netease, userInstalled: true);

    test('入口与版本来自 manifest', () {
      expect(ProviderDescriptor.manifestVersion(_netease), '2.1.1');
      expect(netease.userInstalled, isTrue);
      expect(netease.qualityDefault, 'exhigh');
    });

    test('登录方式两种：扫码与手机号', () {
      expect(netease.loginMethods.length, 2);
      expect(netease.defaultLoginMethod, 'qr');
      expect(netease.loginMethod('phone')?['type'], 'sms');
      expect(netease.smsLoginMethod?['phonePattern'], '^1[0-9]{10}\$');
      expect(netease.loginPollIntervalMs, 1000);
      expect(netease.loginTimeoutMs, 300000);
    });

    test('能力面 mv/comments 为 true，可编辑歌单规则 all', () {
      expect(netease.capability('mv'), isTrue);
      expect(netease.capability('comments'), isTrue);
      expect(netease.playlistEditableRule, 'all');
      expect(netease.likedModel, 'likedIDs');
    });
  });
}

const Map<String, Object?> _siren = <String, Object?>{
  'schemaVersion': 2,
  'id': 'siren',
  'display': <String, Object?>{
    'name': '塞壬唱片',
    'label': 'SIREN',
    'detail': '官网曲库 · 本地索引',
    'sessionLabel': 'SIREN SESSION',
    'archiveIdPrefix': 'SIREN ID / ',
    'order': 0,
    'default': false,
  },
  'capabilities': <String, Object?>{
    'search': true,
    'detail': true,
    'playback': true,
    'lyrics': true,
    'account': false,
    'login': false,
    'vip': false,
    'discover': false,
    'categories': false,
    'mv': false,
    'userPlaylists': true,
    'likedSongs': true,
  },
  'operations': <String, Object?>{
    'search': true,
    'detail': true,
    'playback': true,
    'lyrics': true,
  },
  'library': <String, Object?>{
    'columns': <String>['搜索结果', '喜欢的歌曲', '我的歌单', '全部歌曲', '全部专辑'],
    'sourceOrder': <int>[1, 2, 3, 4, 0],
    'likedModel': 'local',
  },
  'quality': <String, Object?>{'default': 'lossless'},
  'login': null,
};

const Map<String, Object?> _netease = <String, Object?>{
  'schemaVersion': 2,
  'id': 'netease',
  'version': '2.1.1',
  'apiVersion': '2.0',
  'entry': <String, Object?>{'file': 'plugin.cjs'},
  'display': <String, Object?>{
    'name': '网易云音乐',
    'label': 'NETEASE',
    'detail': '搜索 · 个人音乐 · 推荐 · 播放 · 歌单编辑',
    'sessionLabel': 'NETEASE SESSION',
    'archiveIdPrefix': 'NETEASE ID / ',
    'order': 1,
    'default': true,
  },
  'capabilities': <String, Object?>{
    'search': true,
    'detail': true,
    'playback': true,
    'lyrics': true,
    'account': true,
    'login': true,
    'vip': true,
    'discover': true,
    'categories': true,
    'mv': true,
    'comments': true,
    'userPlaylists': true,
    'likedSongs': true,
  },
  'operations': <String, Object?>{'mv': true, 'mvVersions': true, 'loginBegin': true, 'loginPoll': true},
  'library': <String, Object?>{
    'columns': <String>['搜索结果', '喜欢的歌曲', '我的歌单', '收藏歌单', '收藏专辑'],
    'sourceOrder': <int>[1, 2, 3, 4, 0],
    'likedModel': 'likedIDs',
    'playlistEditableRule': 'all',
  },
  'quality': <String, Object?>{
    'default': 'exhigh',
    'options': <Map<String, Object?>>[
      <String, Object?>{'id': 'standard', 'label': '标准'},
      <String, Object?>{'id': 'exhigh', 'label': '极高'},
    ],
  },
  'login': <String, Object?>{
    'required': false,
    'pollIntervalMs': 1000,
    'pollTimeoutMs': 300000,
    'methods': <Map<String, Object?>>[
      <String, Object?>{'id': 'qr', 'type': 'qr', 'label': '扫码登录'},
      <String, Object?>{
        'id': 'phone',
        'type': 'sms',
        'label': '手机号登录',
        'phonePattern': '^1[0-9]{10}\$',
        'countryCode': '86',
      },
    ],
  },
  'strings': <String, Object?>{
    'officialEntry': '官网曲库 ↗',
    'loginHint': '登录后可同步收藏与歌单',
  },
  'search': <String, Object?>{'maxQueryLength': 100},
};
