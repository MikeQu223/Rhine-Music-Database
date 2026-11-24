// Siren 基本版的生产入口（原子 APP-ENTRY-108）。
//
// Qt 的启动是两段，不是一个函数。应用级闸门在 Android 侧：
// Qt/android/AndroidManifest.xml:78-96 把 rhine.music.database.ConsentActivity 写成唯一的
// LAUNCHER，QtActivity 因此 exported=false ——「同意之前」Qt 界面、Clarity、Bugly 一个都不会
// 起来。Qt/android/src/rhine/music/database/ConsentActivity.java:66-108 的 onCreate 在未同意
// 时先 3 秒实时判地区：CN/EU 才弹不可取消的对话框，其他地区（含超时）直接放行；同意记录
// 同时被 Qt/android/src/rhine/music/database/RhineApplication.java:16-23 用来决定是否
// startSdks（覆盖不经过 ConsentActivity 的后台唤醒）。
// 闸门之后的进程内启动才是 Qt/src/main.cpp:830 int main(...)：建 QGuiApplication、选图形后端、
// 起 Engine、载入 Main.qml（窗口 + Scene3D/Overlay 两层），到 :1072-1077 注册字体与
// rootContext 属性后进业务界面。main() 体内没有任何 Consent 分支；与遥测有关的动作只有
// :1078-1084 的 `if (!offline && RHINE_RELEASE_BUILD)` 分支里 8 秒后 updater.check()
// （:1079 QTimer::singleShot，还要 auto-update 偏好不是 off）。Bugly 的记录读取发生在
// ConsentStore 的 JNI 侧（见 Qt/src/main.cpp:3 的说明）；Qt 版的 Clarity 在放行路径上由
// ConsentStore.java:20-21 启动。Flutter 版没有这层宿主逻辑，Clarity 直接在下面的 Dart 入口启动。
//
// Flutter 基本版捆绑 clarity_flutter（pubspec.yaml），入口用 ClarityWidget 包一层 BasicApp；
// Bugly 仍未接入。入口不挂 ConsentGate，只负责把 root 交给 BasicApp。
//
// 挂的是 BasicApp（RUNTIME-STARTUP-96 的交付，lib/basic/basic_app.dart）：它自带
// MaterialApp（lib/basic/basic_app.dart:226 build → MaterialApp(theme: dark, home: _home())），
// 入口再套一层只会把主题与 home 拆成两份，所以这里不建第二个。构造参数全部留空：
// 生产入口必须走真实端口（MethodChannelBasicAudio 背后的 MediaPlayer，platform_playback.dart），
// 不注入任何测试替身；gate 也不传 —— BasicApp 不读它，入口也不挂 ConsentGate。
//
// 原先 flutter create 的计数器 demo（MyApp / MyHomePage / _counter / FloatingActionButton）
// 已整份删除：它是假首屏，而且会让「入口挂的是哪个 App」在测试与审阅时产生歧义。
//
// 合并 APP-ENTRY-108（2b0f9f7 + 6d5ac4a）时按 Lead 裁决取行为并集：上面「只做一件事」说的是
// 入口只有一个 App、一条启动路径、没有 ConsentGate；main() 里另外那一行是宿主沉浸位。
// 沉浸式与方向交给宿主：这里只隐藏系统栏，不锁定方向——横竖屏切换由 BasicApp 内的
// LayoutBuilder 分支处理（见 basic_app.dart；这是 RUNTIME-STARTUP-94 的既有行为，逐句保留）。
//
// 为什么 main() 里还要钉一次沉浸位：
// 宿主侧 android/app/src/main/kotlin/rhine/music/database/MainActivity.kt:220-228 的
// applyImmersiveSticky() 只在 onCreate（:69）与 onResume（:101）调用，:242-245 写
// decorView.systemUiVisibility = IMMERSIVE_STICKY_FLAGS（0x1706 = 5894）。
// 但 FlutterActivity.onPostResume → FlutterActivityAndFragmentDelegate.onPostResume 会无条件
// 调 PlatformPlugin.updateSystemUiOverlays()：没有 Dart 侧设置时 mEnabledOverlays 是
// PlatformPlugin.DEFAULT_SYSTEM_UI = 1280（只有 LAYOUT_STABLE|LAYOUT_FULLSCREEN，没有任何
// hide 位），于是每一轮 onPostResume 都把原生刚写好的 5894 覆盖成 1280 —— API 28/29
// （minSdk=28，android/app/build.gradle.kts:116）上 HIDE_NAVIGATION 与
// LAYOUT_HIDE_NAVIGATION 就此丢失。Dart 侧调一次 SystemChrome 之后 mEnabledOverlays 变成
// 5894，引擎的重放才与原生一致，所以这一行不是直达装饰。（更干净的宿主侧兜底是给
// MainActivity 加 onPostResume 覆写，但那属于 android/ 改动范围，超出本次整合范围，已上报。）
//
// 2026-11-22：这里从 `immersiveSticky` 改成 `edgeToEdge`。真机上 `immersiveSticky`
// 下系统输入法（默认的微信键盘 `com.tencent.wetype/.plugin.hld.WxHldService`）窗口
// 报告 `mInputShown=true`、`isVisible=true`，但一个像素都不画 —— 搜索框、登录短信框
// 全部「点了不弹键盘」。切到 `edgeToEdge` 后同一个输入法立刻正常显示，且页面布局、
// 全屏观感与改前一致（状态栏/导航栏仍由 HUD 自己占满，见 device 截图）。

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
  // 边到边：系统栏（状态栏 + 手势/三键区）**保持可见**，但底色完全透明。
  // 2026-11-22 之前用的是 immersiveSticky（把系统栏藏掉），两个问题：
  //  1. 用户 2026-11-24 明确要求「竖屏时不全屏，显示状态栏和系统手势/三键操作区域，
  //     最好完全透明底、不要灰色遮罩」；
  //  2. 微信键盘在 immersiveSticky 下 mInputShown=true 却一个像素都不画（已改过一次）。
  // 这里与 MainActivity.applyImmersiveSticky 同源：Flutter 侧给透明色 + 浅色图标，
  // 原生侧负责 setDecorFitsSystemWindows(false) 与关掉导航栏对比度强制。
  // 图标明暗随主题走：这里是首帧默认（浅色纸面 → 深色图标），运行中由
  // `BasicApp` 的 AnnotatedRegion 按 `state.dark` 覆盖。
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
