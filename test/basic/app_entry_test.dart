// 生产入口契约（原子 APP-ENTRY-108）。
//
// 被测文件：lib/main.dart —— 整个 App 唯一的生产调用点。
//
// 对照来源：
//   Qt/android/AndroidManifest.xml:78-96
//                                ConsentActivity 是唯一 LAUNCHER，应用级许可闸门在这里
//   Qt/android/src/rhine/music/database/ConsentActivity.java:66-108
//                                未同意时先判地区，CN/EU 才弹窗，其他地区直接放行
//   Qt/src/main.cpp:830          Qt 的 int main(...)：闸门之后的进程内启动（窗口/引擎/字体）
//   Qt/src/main.cpp:1072-1077    注册字体与 rootContext 属性
//   Qt/src/main.cpp:1078-1084    唯一的遥测动作：非 offline 的 release 构建才在 8s 后
//                                updater.check()
//   Qt/src/main.cpp:3            Bugly 由 ConsentStore 的 JNI 侧接管，不在 Dart 组合根
//   lib/basic/basic_app.dart:226 BasicApp 自带 MaterialApp，入口用 ClarityWidget 包住它
//   lib/app/consent_gate.dart    ConsentGate 要宿主注入端口；入口不构造它就没有弹窗可弹
//
// 这些断言只读源码文本（与 test/app/android_host_contract_test.dart 同一手法）：本 worktree
// 禁止执行验证，**RED/GREEN 均未执行**，文件头如实声明，不写成「已验证通过」。
//
// 不 pump 真实入口的理由：runApp(ClarityWidget(app: BasicApp())) 会真的启动 BasicApp 和
// Clarity —— boot 会去取曲库，
// 资源装载要读随包字体与字形表（清单见 lib/hud/text/glyph_font.dart:5-10）：Assets/fonts 下
// 4 个字重（合计 27,002,376 B）、符号字体 1,233,128 B 与 Assets/fonts/misans-glyphs.json
// （1,683,324 B），既超出「只写不执行」的边界，也不是本原子要证明的东西（首屏行为由
// test/basic/runtime_startup_test.dart 覆盖）。所以这里用「源码形状 + 零注入可构造性」钉住入口。
//
// 计划执行入口：flutter test test/basic/app_entry_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_app.dart';

/// 去掉 Dart 行注释与块注释。
///
/// 「入口没有 ConsentGate」这类守卫必须只看代码：lib/main.dart 的文档注释会逐字解释为什么
/// 入口不挂 gate（引用 Qt 的 ConsentActivity / ConsentStore），把注释算进来会把「解释为什么
/// 没有」误判成「有」。与 test/app/android_host_contract_test.dart 的 _stripKotlinComments 同一理由。
String _stripDartComments(String text) {
  final String noBlocks = text.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return noBlocks.replaceAll(RegExp(r'//[^\n]*'), '');
}

/// [needle] 在 [text] 里出现的次数。
int _occurrences(String text, String needle) {
  int count = 0;
  int from = 0;
  while (true) {
    final int at = text.indexOf(needle, from);
    if (at < 0) {
      return count;
    }
    count += 1;
    from = at + needle.length;
  }
}

/// 源码里的 import 行（去首尾空白，保持书写顺序）。
List<String> _imports(String text) => <String>[
      for (final String line in text.split('\n'))
        if (line.trimLeft().startsWith('import ')) line.trim(),
    ];

/// 逐个断言 [tokens] 不在 [code] 里。
void _expectAbsent(String code, List<String> tokens, String why) {
  for (final String token in tokens) {
    expect(code.contains(token), isFalse, reason: '入口不该再出现 $token：$why');
  }
}

void main() {
  final String entry = File('lib/main.dart').readAsStringSync();
  final String code = _stripDartComments(entry);

  group('生产入口挂的是 BasicApp（CLOSURE-1）', () {
    test('main() 的顺序：建 Clarity 配置、钉住宿主沉浸位、runApp(ClarityWidget(BasicApp))', () {
      // 合并 APP-ENTRY-108 时的取舍：108 的 main() 原本只有 runApp 一句，但那样会丢掉
      // RUNTIME-STARTUP-94 的沉浸位 —— 宿主 MainActivity.kt:220-228 只在 onCreate/onResume
      // 写 IMMERSIVE_STICKY_FLAGS(5894)，而引擎的 FlutterActivity.onPostResume →
      // PlatformPlugin.updateSystemUiOverlays() 会在没有 Dart 侧设置时把
      // mEnabledOverlays(=DEFAULT_SYSTEM_UI 1280) 重放回去，API 28/29 上导航栏与
      // LAYOUT_HIDE_NAVIGATION 就回来了。所以允许（也只允许）这一条前置语句。
      // Clarity 配置必须建在 runApp 之前，并且只包一层 ClarityWidget。
      expect(
        RegExp(
          r'void main\(\)\s*\{\s*final config = ClarityConfig\(\s*projectId: "z8vbz4b078",'
          r'\s*logLevel: LogLevel\.Info,?\s*\);\s*'
          r'WidgetsFlutterBinding\.ensureInitialized\(\);\s*'
          // 2026-11-22 起入口钉的是 edgeToEdge，不再是 immersiveSticky：
          // 真机上 immersiveSticky 与默认输入法（微信键盘）不兼容，
          // mInputShown=true 却一个像素都不画（搜索框/短信框点了不弹键盘）。
          // 换成 edgeToEdge 后布局与全屏观感不变、输入法正常，见 lib/main.dart 注释。
          r'SystemChrome\.setEnabledSystemUIMode\(SystemUiMode\.edgeToEdge\);\s*'
          r'runApp\(ClarityWidget\(\s*app: const BasicApp\(\),\s*clarityConfig: config,?\s*\)\);'
          r'\s*\}',
        ).hasMatch(code),
        isTrue,
        reason: '入口的 main() 必须按顺序完成 Clarity 配置、沉浸位与 ClarityWidget 包裹的 BasicApp 挂载',
      );
      expect(_occurrences(code, 'runApp('), 1, reason: '一个入口只能有一个 root 挂载点');
      expect(_occurrences(code, 'void main('), 1, reason: '一个入口只能有一个 main()');
      expect(_occurrences(code, 'SystemChrome.setEnabledSystemUIMode('), 1,
          reason: '沉浸位只钉一次；多一次就是多一条没被审的窗口状态写入');
      expect(_occurrences(code, 'ClarityConfig('), 1, reason: 'Clarity 配置只能创建一个');
      expect(code.contains('projectId: "z8vbz4b078"'), isTrue,
          reason: 'Clarity 项目 ID 必须显式写在入口，不能从环境或测试注入');
    });

    test('import 面只有 material、services、basic/basic_app.dart 与 clarity_flutter', () {
      expect(
        _imports(entry),
        <String>[
          "import 'package:flutter/material.dart';",
          "import 'package:flutter/services.dart';",
          "import 'basic/basic_app.dart';",
          "import 'package:clarity_flutter/clarity_flutter.dart';",
        ],
        reason: '入口不拉 application 层、不拉 ui/pages：多一个 import 就是多一条没被审的启动路径',
      );
    });

    test('入口只引用实现，不自带任何 App 类', () {
      expect(_imports(entry), contains("import 'basic/basic_app.dart';"));
      _expectAbsent(code, <String>['class ', 'extends StatelessWidget', 'extends StatefulWidget'],
          '入口是组合根（只 runApp），不是又一个 App widget');
    });
  });

  group('计数器 demo 已整份删除', () {
    test('flutter create 的 MyApp / MyHomePage / _counter 全都消失', () {
      _expectAbsent(
        code,
        <String>[
          'MyApp',
          'MyHomePage',
          '_MyHomePageState',
          '_counter',
          '_incrementCounter',
          'FloatingActionButton',
          'floatingActionButton',
          'Icons.add',
          'setState',
          'Flutter Demo',
          'You have pushed the button this many times',
        ],
        '删掉的是假首屏，入口的 root 只能是 BasicApp（commit 89493eb 的 demo 不能留）',
      );
    });
  });

  group('启动序列只接入 Clarity，不构造 ConsentGate / 其它 SDK', () {
    test('入口不构造 ConsentGate / ConsentPage，也不自己起 Bugly 或 updater', () {
      _expectAbsent(
        code,
        <String>[
          'ConsentGate',
          'ConsentPage',
          'ConsentActivity',
          'ConsentRegion',
          'startSdks',
          'Bugly',
          'updater',
          'MethodChannel',
        ],
        '许可闸门在 Android 的 ConsentActivity（Qt/android/AndroidManifest.xml:78-96），'
            'Qt/src/main.cpp 的 main() 体内没有 Consent 分支；Flutter 版只在入口用 ClarityWidget 接入 Clarity，'
            'Bugly/updater 仍不该出现在 Dart 入口',
      );
    });

    test('入口不给 BasicApp 传 gate，也没有第二层 MaterialApp', () {
      expect(
        code.contains('gate:'),
        isFalse,
        reason: 'BasicApp 不读 gate（lib/basic/basic_app.dart:102），传它只会制造「入口在管弹窗」的假象',
      );
      expect(
        code.contains('MaterialApp'),
        isFalse,
        reason: 'BasicApp 自带 MaterialApp（lib/basic/basic_app.dart:226）；入口再套一层会把主题与 home 拆成两份',
      );
    });

    test('BasicApp 以零注入形态就是生产 root：真实端口、无测试替身', () {
      const BasicApp app = BasicApp();
      expect(app.controller, isNull,
          reason: '生产入口不注入 controller：BasicApp 自建并持有，boot 恰一次');
      expect(app.audio, isNull,
          reason: '生产入口不注入 audio：BasicApp 的默认端口是 MethodChannelBasicAudio'
              '（lib/basic/basic_app.dart:129-138 → lib/basic/platform_playback.dart:211-226）');
      expect(app.gate, isNull, reason: '没有 gate 对象就没有弹窗分支可按');
      expect(app.bundle, isNull, reason: '生产入口用 rootBundle，不注入 stub 资源包');
    });
  });
}
