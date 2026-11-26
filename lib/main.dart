// Siren 基本版的生产入口。
//
// 启动闸门在 Android 侧（ConsentActivity 是唯一 LAUNCHER），Dart 入口不挂 ConsentGate，
// 只把 root 交给 BasicApp：它自带 MaterialApp，入口再套一层会拆出两份主题与 home。
// 构造参数全部留空，生产入口走真实端口，不注入测试替身。
//
// 系统栏用 edgeToEdge：immersiveSticky 下默认输入法 mInputShown=true 却一个像素都不画，
// 搜索框与短信框点了不弹键盘；edgeToEdge 布局与观感不变，输入法正常。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'basic/basic_app.dart';

import 'package:clarity_flutter/clarity_flutter.dart';

void main() {
  final config = ClarityConfig(
    projectId: "z8vbz4b078",
    logLevel: LogLevel.Info, // Note: Use "LogLevel.Verbose" value while testing to debug initialization issues.
  );

  WidgetsFlutterBinding.ensureInitialized();
  // 边到边：系统栏保持可见但完全透明，内容铺到物理边缘。
  // 原生侧负责 setDecorFitsSystemWindows(false) 与关掉导航栏对比度强制；
  // 这里给透明色 + 首帧浅色图标，运行中由 BasicApp 的 AnnotatedRegion 覆盖。
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Color(0x00000000),
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: Color(0x00000000),
    systemNavigationBarDividerColor: Color(0x00000000),
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarContrastEnforced: false,
  ));
  runApp(ClarityWidget(
    app: const BasicApp(),
    clarityConfig: config,
  ));
}
