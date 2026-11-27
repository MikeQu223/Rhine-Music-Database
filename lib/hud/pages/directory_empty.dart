// 空态 + 目录返回上一级 + 未登录/来源分派
// 横屏 1:1 真值源：Qt/src/NativeHud.cpp
//   empty            374-403      三分支 + 标题三分支 + 描述行 + 底部按钮
//   control          121-124      命中 x-10 / width+20 / 54 + aligned(y+14, 20, demibold)
//   limited          77-79        fit 后 text，weight 透传
//   text / fill      40-43 / 37-39
//   rule             125-129      1px fill，alpha 槽换 opacity；NativeHud.h:261 默认 opacity = 0.4
//   hit              102-109      六字段 x/y/width/height/action/label
//   button           110-119      m_modalControls = false（NativeHud.h:222 默认 false，archive 页不置 true）
//                                 -> 只发 hit(x, y, width, height) + text(...)，不发 fill
//   navigationLeft   342-344      width - 789
// 纯 Dart：仅相对导入 './chrome.dart'，不 import 任何 UI 框架 / 渲染框架 / 第三方包。
// 命令与命中按 Qt 发射顺序 append（不排序、不去重、不合并），顺序即语义。
// 公共契约块见 lib/hud/pages/chrome.dart 顶部，本文件只 import 复用，不重定义。
import 'chrome.dart';

/// Qt NativeHud::empty() 读取的 MusicLibrary 状态切片（只读快照）。
/// 字段 ↔ Qt 调用点：
///   libraryName()      -> NativeHud.cpp:380 / 385 / 389
///   directory          -> NativeHud.cpp:377 / 384 / 400
///   status             -> NativeHud.cpp:400（directoryStatus；非目录时为 null）
///   selectedLane       -> NativeHud.cpp:388 / 400（sourceMessage 的入参）
///   sourceLoading()    -> NativeHud.cpp:389
///   isSiren()          -> NativeHud.cpp:390 / 392
///   isLocal()          -> NativeHud.cpp:392
///   uid                -> NativeHud.cpp:392
///   restoringAccount   -> NativeHud.cpp:392
///   providerName()     -> NativeHud.cpp:394
///   sourceMessage(lane)-> NativeHud.cpp:400
class HudDirectoryEmptyState {
  const HudDirectoryEmptyState({
    required this.libraryName,
    required this.selectedLane,
    required this.isLocal,
    required this.isSiren,
    required this.uid,
    required this.restoringAccount,
    required this.sourceLoading,
    required this.providerName,
    required this.directory,
    required this.directoryStatus,
    required this.sourceMessage,
  });

  final String libraryName;
  final int selectedLane;
  final bool isLocal;
  final bool isSiren;
  final String uid;
  final bool restoringAccount;
  final bool sourceLoading;
  final String providerName;
  final bool directory;

  /// Qt MusicLibrary::status（仅目录态有值）。null 等价于 Qt 空 QString。
  final String? directoryStatus;

  /// Qt MusicLibrary::sourceMessage(selectedLane)（仅非目录态使用）。null 等价于 Qt 空 QString。
  final String? sourceMessage;
}

/// Qt NativeHud::empty(double width) (NativeHud.cpp:374-403)。
///
/// 三分支互斥且优先级固定：
///   1) directory            -> title = libraryName,      label = '查看歌单详情 →', action = 'music:directory-info'
///   2) selectedLane > 0     -> title = sourceLoading ? '正在同步音乐资料…' : libraryName,
///                              label = isSiren ? '查看曲库 →' : '查看我的音乐 →', action = 'saved'
///                              （登录覆盖嵌在本分支内部：!isLocal && !isSiren && uid.isEmpty && !restoringAccount
///                                -> title = '登录后查看', label = '登录' + providerName + ' →', action = 'music:login'）
///   3) 否则                 -> title = '音乐资料库',      label = '检索音乐 →',        action = 'search'
///
/// 发射顺序（严格）：[目录返回 control] -> 'MUSIC DATABASE / …' -> 标题 -> rule -> 描述行 -> 底部按钮 hit -> 按钮文案。
class HudDirectoryEmpty {
  HudDirectoryEmpty(this.sink, this.text, {this.dark = false});

  final HudSurfaceSink sink;
  final HudTextPort text;
  final bool dark;

  /// Qt NativeHud::empty() 全体命令 + 命中 (NativeHud.cpp:374-403)。
  void empty({required double width, required HudDirectoryEmptyState s}) {
    // :375 const auto x = navigationLeft(width);  // NativeHud.cpp:342-344 -> width - 789
    final double x = width - HudChrome.navigationRightInset;

    // :377-379 if (music.directory) control("← 返回上一级", 59, 211, 280, "music:parent");
    if (s.directory) {
      hudControl(sink, text, '← 返回上一级', 59, 211, 280, 'music:parent', dark: dark);
    }

    // :380 text("MUSIC DATABASE / " + music.libraryName(), x, 471, 12);  // weight regular / tracking 0 / ink
    hudText(sink, 'MUSIC DATABASE / ${s.libraryName}', x, 471, 12, dark: dark);

    // :381-383 默认分支
    String title = '音乐资料库';
    String label = '检索音乐 →';
    String action = 'search';

    if (s.directory) {
      // :384-387
      title = s.libraryName;
      label = '查看歌单详情 →';
      action = 'music:directory-info';
    } else if (s.selectedLane > 0) {
      // :388-391
      title = s.sourceLoading ? '正在同步音乐资料…' : s.libraryName;
      label = s.isSiren ? '查看曲库 →' : '查看我的音乐 →';
      action = 'saved';
      // :392-396 登录覆盖（嵌在 selectedLane > 0 分支内部，只覆盖 title/label/action）
      if (!s.isLocal && !s.isSiren && s.uid.isEmpty && !s.restoringAccount) {
        title = '登录后查看';
        label = '登录${s.providerName} →';
        action = 'music:login';
      }
    }

    // :398 limited(title, x, 509, 28, width - x - 59, "bold");
    _limited(title, x, 509, 28, width - x - 59, 'bold');
    // :399 rule(x, 601, width - x - 59);  // Qt 头文件默认 opacity 0.4（NativeHud.h:261），此处显式传值
    hudRule(sink, dark, x, 601, width - x - 59, 0.4);
    // :400-401 limited(directory ? status : sourceMessage(selectedLane), x, 624, 16, width - x - 117); // weight regular
    _limited(s.directory ? (s.directoryStatus ?? '') : (s.sourceMessage ?? ''), x, 624, 16, width - x - 117);

    // :402 button(label, x, 703, 300, 32, action, 14);
    // m_modalControls = false（NativeHud.h:222；archive 页不置 true）走 :112 + :118-119 两行：
    //   hit(x, 703, 300, 32, action, label)
    //   text(label, x + 0, 703 + (32 - 14) / 2 - 4 = 708, 14, "regular")
    // 不发 fill（fill 只在 m_modalControls 为 true 时发射，NativeHud.cpp:114-117）。
    sink.hit(HudHit(x: x, y: 703, width: 300, height: 32, action: action, label: label));
    hudText(sink, label, x, 703 + (32 - 14) / 2 - 4, 14, weight: 'regular', dark: dark);
  }

  /// Qt NativeHud::limited() (NativeHud.cpp:77-79)：text(fit(value, size, width, weight), x, y, size, weight)。
  /// weight 默认 "regular"（NativeHud.h:250）。
  void _limited(String value, double x, double y, double size, double width, [String weight = 'regular']) {
    hudText(sink, text.fit(value, size, width, weight), x, y, size, weight: weight, dark: dark);
  }
}
