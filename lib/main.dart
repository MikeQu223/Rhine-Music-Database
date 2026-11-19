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
// ConsentStore 的 JNI 侧（见 Qt/src/main.cpp:3 的说明）；Clarity 则在所有放行路径上启动
// （Qt/android/src/rhine/music/database/ConsentStore.java:20-21）——两者都不在 Dart 组合根里。
//
// Flutter 基本版没有捆绑 Clarity / Bugly（pubspec.yaml 的 dependencies 只有 flutter 与
// shared_preferences 这两个官方包，android/app/build.gradle.kts 的 dependencies 只有
// testImplementation junit），也就没有要征求同意的 SDK。所以入口不挂 ConsentGate，只做一件事：把 root 交给
// BasicApp。
//
// 挂的是 BasicApp（RUNTIME-STARTUP-96 的交付，lib/basic/basic_app.dart）：它自带
// MaterialApp（lib/basic/basic_app.dart:226 build → MaterialApp(theme: dark, home: _home())），
// 入口再套一层只会把主题与 home 拆成两份，所以这里不建第二个。构造参数全部留空：
// 生产入口必须走真实端口（MethodChannelBasicAudio 背后的 MediaPlayer，platform_playback.dart），
// 不注入任何测试替身；gate 也不传 —— BasicApp 不读它，而本入口没有要征求同意的 SDK，
// 不会弹出、也没有可弹的无授权遥测窗。
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
// 5894，引擎的重放才与原生一致，所以这一行不是装饰。（更干净的宿主侧兜底是给
// MainActivity 加 onPostResume 覆写，但那属于 android/ 改动范围，超出本次整合范围，已上报。）

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'basic/basic_app.dart';

void main() {
  // runApp 自己会 ensureInitialized，但下面的 SystemChrome 调用需要 ServicesBinding。
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const BasicApp());
}
