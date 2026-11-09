// Qt -> Flutter 迁移 · SHARED-S2 测试规格：provider 身份模型（ProviderId）。
//
// 依据（每条断言上方注释给出 Qt 行号）：
//   Qt/src/MusicApi.h:21          QString provider = "netease"
//   Qt/src/MusicApi.cpp:10-24     providerName() 五种映射 + 默认分支
//   Qt/src/MusicApi.cpp:61-70     call()：local 守卫 + "/native/" + provider + "/" + operation
//   Qt/src/MusicApi.cpp:72-84     request()：local 守卫 + provider != "netease" 时前置 "/" + provider
//   Qt/src/MusicLibrary.cpp:19-25、Qt/src/PlaybackService.cpp:37-41
//                                 provider 取值集合 {netease, qq, kugou, local, siren}
//
// 【本测试未执行】受任务禁令约束：禁止 flutter/dart test、dart analyze、构建、代码生成与任何测试执行。
// 执行入口与 RED/GREEN 结论由 Lead 统一决定（候选命令：flutter test test/domain/provider_id_test.dart）。
// 依赖提示：import 取 package:flutter_test/flutter_test.dart（项目既有约定：pubspec.yaml 的 dev_dependencies 已含
// flutter_test；package:test 不在 pubspec.lock 中，直接 import 会解析失败）。不新增依赖、不改 pubspec。
import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/domain/models/provider_id.dart';

void main() {
  group('R1 displayName（Qt/src/MusicApi.cpp:10-24 providerName 逐字映射）', () {
    test('R1 local → 本地音乐', () {
      // MusicApi.cpp:11-13
      expect(ProviderId.local.displayName, '本地音乐');
    });

    test('R1 qq → QQ 音乐', () {
      // MusicApi.cpp:14-16（注意 "QQ 音乐" 中间是一个半角空格）
      expect(ProviderId.qq.displayName, 'QQ 音乐');
    });

    test('R1 kugou → 酷狗音乐', () {
      // MusicApi.cpp:17-19
      expect(ProviderId.kugou.displayName, '酷狗音乐');
    });

    test('R1 siren → 塞壬唱片', () {
      // MusicApi.cpp:20-22
      expect(ProviderId.siren.displayName, '塞壬唱片');
    });

    test('R1 netease → 网易云音乐（默认分支）', () {
      // MusicApi.cpp:23 return QStringLiteral("网易云音乐")
      expect(ProviderId.netease.displayName, '网易云音乐');
    });

    test('R1 空串 / 未知值 / 大小写变体都落到默认分支「网易云音乐」', () {
      // MusicApi.cpp:10-24：Qt 逐字比较，未命中一律返回 "网易云音乐"
      expect(ProviderId.parse('').displayName, '网易云音乐');
      expect(ProviderId.parse('spotify').displayName, '网易云音乐');
      expect(const ProviderId('').displayName, '网易云音乐');
      expect(const ProviderId('QQ').displayName, '网易云音乐');
      expect(const ProviderId('Netease').displayName, '网易云音乐');
    });
  });

  group('R2 parse / 默认身份（Qt/src/MusicApi.h:21 QString provider = "netease"）', () {
    test('R2 parse(null) → netease 常量身份', () {
      // MusicApi.h:21 默认值；Dart 侧 null 与 Qt 未赋值的语义对齐
      expect(ProviderId.parse(null), same(ProviderId.netease));
      expect(ProviderId.parse(null).wire, 'netease');
    });

    test('R2 parse("") → netease（空串等于缺省）', () {
      expect(ProviderId.parse(''), same(ProviderId.netease));
      expect(ProviderId.parse('').wire, 'netease');
    });

    test('R2 parse 五个已知 wire → 对应常量身份（identical）', () {
      expect(ProviderId.parse('netease'), same(ProviderId.netease));
      expect(ProviderId.parse('qq'), same(ProviderId.qq));
      expect(ProviderId.parse('kugou'), same(ProviderId.kugou));
      expect(ProviderId.parse('siren'), same(ProviderId.siren));
      expect(ProviderId.parse('local'), same(ProviderId.local));
    });

    test('R2 parse 未知非空值原样保留，不归一、不 trim', () {
      // Qt 的 MusicApi 只读取 provider，不会把它改写成 netease；
      // 归一发生在 MusicLibrary.cpp:19-25 / PlaybackService.cpp:37-41 的 preference 读取处。
      expect(ProviderId.parse('spotify').wire, 'spotify');
      expect(ProviderId.parse('QQ').wire, 'QQ');
      expect(ProviderId.parse('netease ').wire, 'netease ');
      expect(ProviderId.parse('spotify').isNetease, isFalse);
      expect(ProviderId.parse('spotify').isLocal, isFalse);
    });

    test('R2 五个常量的 wire 字面值与 Qt 字符串逐字一致', () {
      expect(ProviderId.netease.wire, 'netease');
      expect(ProviderId.qq.wire, 'qq');
      expect(ProviderId.kugou.wire, 'kugou');
      expect(ProviderId.siren.wire, 'siren');
      expect(ProviderId.local.wire, 'local');
    });

    test('R2 isLocal / isNetease 只认字面相等（Qt/src/MusicApi.cpp:62、:74、:80）', () {
      expect(ProviderId.local.isLocal, isTrue);
      expect(ProviderId.qq.isLocal, isFalse);
      expect(ProviderId.parse('').isLocal, isFalse);
      expect(ProviderId.netease.isNetease, isTrue);
      expect(ProviderId.qq.isNetease, isFalse);
      expect(ProviderId.parse('spotify').isNetease, isFalse);
    });

    test('R2 == / hashCode 按 wire（可作为 Map/Set 键）', () {
      expect(const ProviderId('qq'), ProviderId.qq);
      expect(const ProviderId('qq').hashCode, ProviderId.qq.hashCode);
      expect(const ProviderId('qq') == const ProviderId('netease'), isFalse);
      expect(const ProviderId('qq') == 'qq', isFalse);
      expect(<ProviderId>{ProviderId.qq, const ProviderId('qq')}.length, 1);
      expect(<ProviderId>{ProviderId.qq, ProviderId.netease}.length, 2);
    });

    test('R2 toString 返回 wire（Qt 直接比较 QString provider）', () {
      expect(ProviderId.qq.toString(), 'qq');
      expect(ProviderId.netease.toString(), 'netease');
      expect(ProviderId.parse('spotify').toString(), 'spotify');
    });
  });

  group('R3 nativeOperationRoute（Qt/src/MusicApi.cpp:61-70 call 的路由）', () {
    test('R3 路由 = "/native/" + wire + "/" + operation', () {
      // MusicApi.cpp:68 send("/native/" + provider + "/" + operation, ...)
      expect(ProviderId.netease.nativeOperationRoute('search'), '/native/netease/search');
      expect(ProviderId.qq.nativeOperationRoute('search'), '/native/qq/search');
      expect(ProviderId.kugou.nativeOperationRoute('login'), '/native/kugou/login');
      expect(ProviderId.siren.nativeOperationRoute('catalog'), '/native/siren/catalog');
      expect(ProviderId.local.nativeOperationRoute('search'), '/native/local/search');
    });

    test('R3 未知 wire 也按同一规则拼接（provider 是身份不是枚举）', () {
      expect(ProviderId.parse('spotify').nativeOperationRoute('search'), '/native/spotify/search');
    });

    test('R3 operation 为空串时保留尾斜杠（纯拼接，不做校验）', () {
      // MusicApi.cpp:68 是字符串拼接，Qt 不校验 operation 是否为空
      expect(ProviderId.qq.nativeOperationRoute(''), '/native/qq/');
    });

    test('R3 local 也生成 native 路由：守卫在调用方（MusicApi.cpp:62-67 先失败）', () {
      // Qt 的 call() 在 local 时先返回失败、根本不会构造路由；
      // Dart 侧同样的守卫是 ApiResult.localModeDisabled()（见 api_result_test.dart）。
      expect(ProviderId.local.nativeOperationRoute('search'), '/native/local/search');
      expect(ProviderId.local.isLocal, isTrue);
    });
  });

  group('R4 routePrefix（Qt/src/MusicApi.cpp:72-84 request 的前缀）', () {
    test('R4 netease → 空前缀（裸路由）', () {
      // MusicApi.cpp:80 if (provider != "netease") 之外的分支：路由原样
      expect(ProviderId.netease.routePrefix, '');
      expect(ProviderId.netease.routePrefix + '/api/account', '/api/account');
    });

    test('R4 qq / kugou / siren / local → "/" + wire', () {
      // MusicApi.cpp:80-82 route = "/" + provider + route
      expect(ProviderId.qq.routePrefix, '/qq');
      expect(ProviderId.kugou.routePrefix, '/kugou');
      expect(ProviderId.siren.routePrefix, '/siren');
      expect(ProviderId.local.routePrefix, '/local');
    });

    test('R4 前缀合成不产生双斜杠（Qt 直接拼接 route）', () {
      expect(ProviderId.qq.routePrefix + '/api/account', '/qq/api/account');
      expect(ProviderId.kugou.routePrefix + '/native/kugou/search', '/kugou/native/kugou/search');
    });

    test('R4 parse("") 归一到 netease（裸路由）；裸空串身份 provider != "netease"，故前缀为 "/"', () {
      // MusicLibrary.cpp:19-25 / PlaybackService.cpp:37-41：Qt 调用方把缺省/空值归一到 netease，
      // 因此 parse('') 是 netease 身份。
      expect(ProviderId.parse('').routePrefix, '');
      expect(ProviderId.parse('spotify').routePrefix, '/spotify');
      // 但 MusicApi.cpp:80 只对字面 "netease" 免前缀：直接构造的空串身份不等 "netease"，
      // 于是 route = "/" + "" + route，前缀是单独一个 "/"。
      expect(const ProviderId('').isNetease, isFalse);
      expect(const ProviderId('').routePrefix, '/');
    });
  });

  group('provider 取值集合（Qt/src/MusicLibrary.cpp:19-25、PlaybackService.cpp:37-41）', () {
    test('Qt 白名单固定为五个值，且 parse 的常量集合与之一致', () {
      // MusicLibrary.cpp:20 / PlaybackService.cpp:38：
      // QStringList{"netease", "qq", "kugou", "local", "siren"}
      const List<String> qtWhitelist = <String>['netease', 'qq', 'kugou', 'local', 'siren'];
      final Set<String> dartConsts = <ProviderId>[
        ProviderId.netease,
        ProviderId.qq,
        ProviderId.kugou,
        ProviderId.local,
        ProviderId.siren,
      ].map((ProviderId id) => id.wire).toSet();
      expect(dartConsts, qtWhitelist.toSet());
      for (final String wire in qtWhitelist) {
        expect(ProviderId.parse(wire).wire, wire);
        expect(ProviderId.parse(wire).displayName.isNotEmpty, isTrue);
      }
    });
  });
}
