import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 登录矩阵夹具契约测试。
///
/// 只读取 test/fixtures/login_matrix.json，不联网、不依赖 WidgetsFlutterBinding，
/// 不实例化任何生产实现。夹具是规格（见 docs/flutter-migration/contracts/domain.md §7）。
///
/// 注意：本文件按任务约束只编写、不执行；仓库 dev_dependencies 仅含 flutter_test，
/// 因此引入 flutter_test 的 test API，但全程不调用 TestWidgetsFlutterBinding。
const String fixturePath = 'test/fixtures/login_matrix.json';

Map<String, dynamic> _asMap(Object? value, String where) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  fail('$where 期望 object，实际为 ${value.runtimeType}: $value');
}

List<dynamic> _asList(Object? value, String where) {
  if (value is List) return value;
  fail('$where 期望 array，实际为 ${value.runtimeType}: $value');
}

String _asString(Object? value, String where) {
  if (value is String) return value;
  fail('$where 期望 string，实际为 ${value.runtimeType}: $value');
}

int _asInt(Object? value, String where) {
  if (value is int) return value;
  fail('$where 期望 int，实际为 ${value.runtimeType}: $value');
}

void main() {
  late Map<String, dynamic> fixture;
  late Map<String, dynamic> shared;
  late List<Map<String, dynamic>> paths;

  setUpAll(() {
    final file = File(fixturePath);
    expect(file.existsSync(), isTrue, reason: '缺少夹具 $fixturePath（相对包根运行）');
    final decoded = jsonDecode(file.readAsStringSync());
    fixture = _asMap(decoded, fixturePath);
    shared = _asMap(fixture['shared'], 'shared');
    paths = _asList(fixture['paths'], 'paths')
        .asMap()
        .entries
        .map((e) => _asMap(e.value, 'paths[${e.key}]'))
        .toList();
  });

  /// 该路径是否含二维码轮询步（按 steps 判定，不按 method——
  /// qq-wechat 的 method 是 wechat，但同样有 801/802/803/800）。
  bool hasQrStep(Map<String, dynamic> p) => _asList(p['steps'], '${p['id']}.steps')
      .any((s) => _asString(_asMap(s, '${p['id']}.steps[]')['on'], '${p['id']}.on')
          .startsWith('qr-code:'));

  Map<String, dynamic> pathById(String id) {
    final matches = paths.where((p) => p['id'] == id).toList();
    expect(matches.length, 1, reason: '路径 id=$id 应恰好出现一次，实际 ${matches.length}');
    return matches.single;
  }

  Map<String, dynamic> stepFor(Map<String, dynamic> path, String on) {
    final steps = _asList(path['steps'], '${path['id']}.steps');
    final matches = steps
        .map((s) => _asMap(s, '${path['id']}.steps[]'))
        .where((s) => s['on'] == on)
        .toList();
    expect(matches.length, 1,
        reason: '${path['id']} 应恰有一个 on=$on 的步骤，实际 ${matches.length}');
    return matches.single;
  }

  test('A1 六条路径且 id 集合精确', () {
    expect(paths.length, 6, reason: 'paths 实际 ${paths.length} 条');
    final ids = paths.map((p) => _asString(p['id'], 'paths[].id')).toSet();
    expect(
      ids,
      equals(<String>{
        'netease-qr',
        'netease-phone',
        'qq-qr',
        'qq-wechat',
        'kugou-standard',
        'kugou-lite',
      }),
      reason: '实际 id 集合: $ids',
    );
  });

  test('A2 每个 provider 的 method 与 edition 组合', () {
    Set<String> methodsOf(String provider) => paths
        .where((p) => p['provider'] == provider)
        .map((p) => _asString(p['method'], '${p['id']}.method'))
        .toSet();
    expect(methodsOf('netease'), equals(<String>{'qr', 'phone'}));
    expect(methodsOf('qq'), equals(<String>{'qr', 'wechat'}));
    expect(methodsOf('kugou'), equals(<String>{'qr'}));

    final editions = paths
        .where((p) => p['provider'] == 'kugou')
        .map((p) => p['edition'])
        .toSet();
    expect(editions, equals(<Object?>{'standard', 'lite'}),
        reason: '酷狗 edition 实际: $editions');

    for (final p in paths) {
      expect(_asString(p['method'], '${p['id']}.method'), isNot('sms'),
          reason: '${p['id']} 不得出现 sms method');
    }
  });

  test('A3 仅 netease-phone 支持 SMS', () {
    final smsPaths = paths.where((p) => p['supportsSms'] == true).toList();
    expect(smsPaths.length, 1,
        reason: 'supportsSms=true 实际 ${smsPaths.map((p) => p['id']).toList()}');
    expect(smsPaths.single['provider'], 'netease');
    expect(smsPaths.single['id'], 'netease-phone');
  });

  test('A4 酷狗两条路径使用互异 accountKey', () {
    final kugou = paths.where((p) => p['provider'] == 'kugou').toList();
    final keys = kugou.map((p) => _asString(p['accountKey'], '${p['id']}.accountKey')).toSet();
    expect(keys.length, kugou.length, reason: '酷狗 accountKey 重复: $keys');
    for (final p in kugou) {
      final edition = _asString(p['edition'], '${p['id']}.edition');
      expect(p['accountKey'], 'kugou-$edition', reason: '${p['id']}.accountKey');
    }
  });

  test('A5 六阶段且顺序固定', () {
    final phases = _asList(shared['phases'], 'shared.phases');
    expect(phases, equals(<String>[
      'idle',
      'preparing',
      'waiting',
      'confirming',
      'failed',
      'complete',
    ]));
  });

  test('A6 轮询与重发常量', () {
    expect(_asInt(shared['pollIntervalMs'], 'shared.pollIntervalMs'), 1000);
    expect(_asInt(shared['pollLimit'], 'shared.pollLimit'), 300);
    expect(_asInt(shared['smsResendMs'], 'shared.smsResendMs'), 60000);
  });

  test('A7 QR 码取值且 801 不推进阶段', () {
    final qrCodes = _asMap(shared['qrCodes'], 'shared.qrCodes');
    expect(qrCodes, equals(<String, dynamic>{
      'expired': 800,
      'waiting': 801,
      'scanned': 802,
      'confirmed': 803,
    }));
    for (final p in paths) {
      var sawWaiting = false;
      for (final raw in _asList(p['steps'], '${p['id']}.steps')) {
        final step = _asMap(raw, '${p['id']}.steps[]');
        if (step['on'] == 'qr-code:801') {
          sawWaiting = true;
          expect(step['phaseChanged'], isFalse, reason: '${p['id']} 的 801 推进了阶段');
        }
      }
      if (hasQrStep(p)) {
        expect(sawWaiting, isTrue,
            reason: '${p['id']} 缺少 qr-code:801 步，A7 不得静默通过');
      }
    }
  });

  test('A8 取消屏障当且仅当 QQ', () {
    for (final p in paths) {
      final barrier = _asString(p['cancelBarrier'], '${p['id']}.cancelBarrier');
      if (p['provider'] == 'qq') {
        expect(barrier, 'upstream', reason: '${p['id']} 缺 QQ 取消屏障');
      } else {
        expect(barrier, 'none', reason: '${p['id']} 不应有上游取消屏障');
      }
    }
  });

  test('A9 重试单位毫秒、冷却墙钟', () {
    expect(shared['retryAfterUnit'], 'ms');
    expect(shared['cooldownClock'], 'wall');
  });

  test('A10 每条 QR 路径覆盖四阶段', () {
    for (final p in paths.where(hasQrStep)) {
      final phases = _asList(p['steps'], '${p['id']}.steps')
          .map((s) => _asMap(s, '${p['id']}.steps[]')['phase'])
          .toSet();
      for (final required in <String>['waiting', 'confirming', 'complete', 'failed']) {
        expect(phases.contains(required), isTrue,
            reason: '${p['id']} 缺阶段 $required，实际 $phases');
      }
    }
  });

  test('A11 手机号与验证码正则逐字', () {
    expect(shared['phonePattern'], r'^1[0-9]{10}$');
    expect(shared['captchaPattern'], r'^[0-9]{4,8}$');
  });

  test('A12 夹具不含六态模板键名', () {
    final pattern = RegExp(r'logged.?out|six.?state', caseSensitive: false);
    final hits = <String>[];
    void walk(Object? node, String trail) {
      if (node is Map) {
        for (final entry in node.entries) {
          final key = entry.key.toString();
          if (pattern.hasMatch(key)) hits.add('$trail.$key');
          walk(entry.value, '$trail.$key');
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], '$trail[$i]');
        }
      }
    }

    walk(fixture, r'$');
    expect(hits, isEmpty, reason: '发现六态模板键: $hits');
  });

  test('A13 captcha 成功保持 idle 且状态取 loginStatus', () {
    final step = stepFor(pathById('netease-phone'), 'action:captcha-login');
    expect(step['phase'], 'idle', reason: 'captcha 成功不得写 complete');
    expect(step['phaseChanged'], isFalse);
    expect(step['statusFrom'], 'loginStatus');
    final status = _asString(step['status'], 'netease-phone.captcha.status');
    expect(status, contains('{nickname}'));
    expect(status, startsWith('已登录：'));
  });

  test('A14 801/802 继续轮询，800/803 终止', () {
    for (final p in paths) {
      for (final raw in _asList(p['steps'], '${p['id']}.steps')) {
        final step = _asMap(raw, '${p['id']}.steps[]');
        final on = step['on'];
        if (on == 'qr-code:801' || on == 'qr-code:802') {
          expect(step['continuesPolling'], isTrue,
              reason: '${p['id']} 的 $on 未标记继续轮询');
        }
        if (on == 'qr-code:800' || on == 'qr-code:803') {
          expect(step.containsKey('continuesPolling'), isFalse,
              reason: '${p['id']} 的 $on 不应继续轮询');
        }
      }
    }
  });

  test('A15 发码静默门控不得伪装成失败', () {
    final step = stepFor(pathById('netease-phone'), 'action:send-login-code-blocked');
    expect(step['silent'], isTrue);
    expect(step['status'], isNull);
    final reason = _asString(step['reason'], 'blocked.reason');
    // Qt/src/MusicAccount.cpp:403:
    //   if (provider != "netease" || accountLoading || smsRetrySeconds() > 0) { return; }
    // 该串是「拦截」谓词，与 shared.smsSendGuard 的「放行」谓词互为补集，极性相反。
    expect(
        reason,
        equals('provider!=netease || accountLoading || smsRetrySeconds()>0'),
        reason: 'blocked.reason 必须是拦截谓词全串（>0 且无取反），不得写成放行条件（==0）');
  });

  test('A16 状态文案表与模板串保留占位符', () {
    final statuses = _asMap(shared['statuses'], 'shared.statuses');
    expect(statuses, isNotEmpty, reason: 'shared.statuses 不得为空');
    for (final entry in statuses.entries) {
      final value = _asString(entry.value, 'shared.statuses.${entry.key}');
      expect(value.trim().isNotEmpty, isTrue,
          reason: 'shared.statuses.${entry.key} 为空串');
    }
    expect(_asString(shared['scanPromptTemplate'], 'shared.scanPromptTemplate'),
        contains('{scanner}'),
        reason: '扫码提示模板必须保留 {scanner} 占位符');
    expect(_asString(shared['loginStatusSuccessTemplate'], 'shared.loginStatusSuccessTemplate'),
        contains('{nickname}'),
        reason: '登录成功模板必须保留 {nickname} 占位符');
    // 放行谓词：与 netease-phone 的 action:send-login-code-blocked 拦截谓词互为补集。
    expect(
        _asString(shared['smsSendGuard'], 'shared.smsSendGuard'),
        equals('provider==netease && !accountLoading && smsRetrySeconds()==0'),
        reason: 'shared.smsSendGuard 是放行谓词全串（==0 且含 !accountLoading）');
  });

  test('附加：所有非静默步骤都有 non-empty status', () {
    for (final p in paths) {
      for (final raw in _asList(p['steps'], '${p['id']}.steps')) {
        final step = _asMap(raw, '${p['id']}.steps[]');
        if (step['silent'] == true) continue;
        final status = _asString(step['status'], '${p['id']}.${step['on']}.status');
        expect(status.trim().isNotEmpty, isTrue,
            reason: '${p['id']}.${step['on']} 的 status 为空');
      }
    }
  });
}
