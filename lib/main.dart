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
// cupertino_icons，android/app/build.gradle.kts 的 dependencies 只有 testImplementation
// junit），也就没有要征求同意的 SDK。所以入口不挂 ConsentGate，只做一件事：把 root 交给
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

import 'package:flutter/material.dart';

import 'basic/basic_app.dart';

void main() {
  runApp(const BasicApp());
}
