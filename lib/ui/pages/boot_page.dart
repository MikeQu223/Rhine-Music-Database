/// T42-C18 Boot 门槛页（Qt Android → Flutter 1:1 迁移，boot 阶段叠加层）。
///
/// 证据（Qt/ 只读源，行号即证据）：
/// - Qt/src/NativeScene.h:161            默认 `m_mode = "boot"`
/// - Qt/src/NativeScene.cpp:176-179      进入 boot：`m_bootStart = m_clock - 1.76` ⇒ 进入即 elapsed = 1.76（不是 0）
/// - Qt/src/NativeSceneFrame.cpp:18      `elapsed = m_freeze.value_or(time - m_bootStart)`
/// - Qt/src/NativeSceneFrame.cpp:19-21   `if (m_mode == "boot" && elapsed >= 35) setMode("detail")`（35s 硬闸门）
/// - Qt/src/NativeSceneFrame.cpp:117     boot 时间轴入参就是 elapsed
/// - Qt/src/BootTimeline.cpp:126-214     `BootTimeline::sample(appTime)`：`time = appTime + 5`，25fps
/// - Qt/src/NativeHudBoot.cpp:155-311    boot HUD 绘制；:161 `offset = (width - 1920) / 2`；:310 按钮屏幕坐标右锚
/// - Qt/src/NativeHud.cpp:102-120        `hit()` / `button()` 几何与文本公式
/// - Qt/src/NativeHudController.cpp:682-683  `value == "skip"` → `m_scene.mode("archive")`
/// - Qt/src/NativeHudController.cpp:698      `m_scene.mode("boot")`（replay，等价 restart）
/// - Qt/src/SceneMotion.cpp:46-49        `ease(value)` = smoothstep
/// - Qt/src/Glyphs.cpp:806-812           `op == "gradient"`：径向渐变（中心 979.2,518.4；半径 1100）
/// - Qt/src/Glyphs.cpp:761-774           `op == "arc"`：`{"arc", cx, cy, radius, start, sweep, penWidth, color}`
/// - Qt/src/NativeHudBoot.cpp:164-171    门槛层：`gradient` 在 backgroundOpacity 的 alpha 内，白闪 `fill` 在其外
/// - Qt/src/NativeHudBoot.cpp:330-350    `scan()` 的弧段（scan.* / orbit.* 曲线，度→radians）
///
/// 阶段语义（务必保留，Qt 门槛行为一致）：
/// - time < 26.92 时 backgroundOpacity = 1（不透明门槛背景）；26.92 起 backgroundOpacity = 0 且 exit 完成
///   （welcomeOpacity = 0、exitBlur = 8），画面透明、底下 3D archive 场景透出；直到 elapsed >= 35 才切 detail。
///   ⇒ 本页是**叠加层（overlay）**，不是不透明整页：背景层只在 backgroundOpacity > 0 时存在。
/// - ENTER SYSTEM 按钮（NativeHudBoot.cpp:310）在所有 opacity 之外无条件绘制，所以淡出后按钮仍在、仍可点。
///
/// 不伪造声明（职责边界）：
/// - 真实 HUD 绘制（glyph 真 advance/path、baseline 1.044、art 零偏移、Gamma1.8→sRGB）由共享 HUD 层负责，
///   经 [BootPage.hudBuilder] 注入；本页绝不自绘 boot glyph 文本。
/// - 门槛层（`gradient` / `fill` / `arc`）在 DEDUP-18 后由本页的**命令生产者**产出 [HudCommand]，
///   再交给共享 [paintHudCommands] 执行：页面不再用 `DecoratedBox`/`RadialGradient`/`ColoredBox`
///   自绘渐变或白闪，也不再自己算渐变几何（中心/半径/色标/填充矩形归 lib/hud/render/gradient_mask.dart）。
/// - track 驱动量（logo 描边、scan 弧、orbit 卫星、brand 行、highlightKeys、ringOpacity、permissionOpacity 尾段）
///   在 Qt 侧来自 Assets/animation/boot-tracks.json 实测曲线；本卡 pubspec.yaml 未声明任何 assets、且 pubspec
///   不在本卡写域 ⇒ 只能经 [BootTrackSource] 注入，默认 [ZeroBootTrackSource] 一律返回 0，不得编造实测值。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../hud/protocol/hud_command.dart';
import '../../hud/render/paint_stack.dart';

// ---------------------------------------------------------------------------
// 1) 数值常量（全部带 Qt 证据注释；语义/数值不得改）
// ---------------------------------------------------------------------------

/// boot 起始偏移（秒）：Qt/src/NativeScene.cpp:178 `m_bootStart = m_clock - 1.76;`
///
/// ⇒ 进入 boot 模式那一刻 elapsed 已经是 1.76，不是 0（首帧时间轴 time = 1.76 + 5 = 6.76）。
const double kBootStartOffsetSeconds = 1.76;

/// 35 秒硬闸门：Qt/src/NativeSceneFrame.cpp:19-21 `if (m_mode == "boot" && elapsed >= 35) setMode("detail");`
///
/// 比较的是 elapsed（含 1.76 偏移）⇒ raw（进入 boot 后实际耗时）约 33.24s 触发，不是 35s。
const double kBootGateSeconds = 35;

/// 时间轴常量偏移（秒）：Qt/src/BootTimeline.cpp:127 `const auto time = appTime + 5;`
const double kTimelineStartOffsetSeconds = 5;

/// 时间轴帧率：Qt/src/BootTimeline.cpp:128 `int(floor(time * 25 + 0.00001))`
const double kTimelineFrameRate = 25;

/// Qt 设计宽：Qt/src/NativeHudBoot.cpp:161 `const auto offset = (width - 1920) / 2;`（设计区 1920，水平居中、不缩放）
const double kQtDesignWidth = 1920;

/// Qt 舞台高：HUD 舞台恒为 1080 高（Qt/src/Engine.cpp:1353 `m_width / (m_height / 1080)`，Qt/qml/Main.qml:32-33）
const double kQtDesignHeight = 1080;

/// ENTER SYSTEM 按钮几何：Qt/src/NativeHudBoot.cpp:310
/// `button("ENTER SYSTEM ↗", width - 261, 994, 202, 40, "skip", 14);`
/// 该调用位于 :292 `restore()` 之后 ⇒ **屏幕坐标右锚**，不再叠加 offsetX。
const double kEnterSystemRightInset = 261;
const double kEnterSystemTop = 994;
const double kEnterSystemWidth = 202;
const double kEnterSystemHeight = 40;
const String kEnterSystemLabel = 'ENTER SYSTEM ↗';
const String kEnterSystemAction = 'skip';
const double kEnterSystemTextSize = 14;

/// ENTER SYSTEM 文本的 Qt `text()` y 参数 = 994 + (40 - 14) / 2 - 4 = 1003（Qt/src/NativeHud.cpp:118-119）。
///
/// 注意：Qt `text(x, y, size)` 的 y **不是**字形盒顶，而是基线前的一定位移
/// （内部 `translate(x, y + size * 1.044)`，见 [kQtTextBaselineFactor]）。
/// 本页的真实纵向锚点因此是 [kEnterSystemTextBaseline]，不是这个值。
const double kEnterSystemTextTop =
    kEnterSystemTop + (kEnterSystemHeight - kEnterSystemTextSize) / 2 - 4;

/// Qt 文字基线系数：Qt/src/Glyphs.cpp:530-540 `Glyphs::text` 内部
/// `c.translate(x, y + size * 1.044)`；字形路径在 :141-190 `layoutText` 里已把基线归零
/// （逐 glyph `path.translate(positions[i].x(), positions[i].y() - line.ascent())`，
/// 末尾 `QTransform::fromScale(1, -1)`）⇒ `text(x, y, size)` 的 alphabetic baseline 恒为
/// `y + size * 1.044`。Glyphs.cpp:629-634 只是保守 cull 盒（y-1.15em 到 y+0.45em），不是基线语义。
const double kQtTextBaselineFactor = 1.044;

/// ENTER SYSTEM 文本的真实 alphabetic baseline（屏幕 y）= 1003 + 14 × 1.044 = 1017.616。
///
/// Qt 钉的是**基线**；6980ac4 把 Flutter `Text` 的**盒顶**钉在 1003，基线于是随字体
/// ascent 漂移（Flutter 侧字体 ascent ≠ Qt 共享字体 ascent），这是原审 NOTE-1 的确定偏差。
const double kEnterSystemTextBaseline =
    kEnterSystemTextTop + kEnterSystemTextSize * kQtTextBaselineFactor;

/// step 阈值（秒）：Qt/src/BootTimeline.cpp:129-138（`< 9.12` access，`< 11.12` logo，`< 19.48` auth，
/// `< 22.76` scan，否则 welcome）。
const double kBootStepLogoSeconds = 9.12;
const double kBootStepAuthSeconds = 11.12;
const double kBootStepScanSeconds = 19.48;
const double kBootStepWelcomeSeconds = 22.76;

/// ACCESS PERMISSION REQUIRED：Qt/src/BootTimeline.cpp:174（26 字符）。
const String kAccessText = 'ACCESS PERMISSION REQUIRED';

/// 逐帧字符数表：Qt/src/BootTimeline.cpp:162 `accessCounts[]{1,1,3,4,5,6,9,11,12,14,17,18,19,20,22,23,25,26}`。
const List<int> kAccessCounts = <int>[
  1, 1, 3, 4, 5, 6, 9, 11, 12, 14, 17, 18, 19, 20, 22, 23, 25, 26,
];

/// access 显现起点帧：Qt/src/BootTimeline.cpp:179 `frame < 170 ? 0 : accessCounts[min(17, frame - 170)]`。
const double kAccessRevealStartFrame = 170;

/// accessOpacity 区间 [170, 227)：Qt/src/BootTimeline.cpp:166-168。
const double kAccessOpacityEndFrame = 227;

/// accessOpacity 唯一衰减特例：Qt/src/BootTimeline.cpp:167 `frame == 226 ? 0.25 : 1`。
const double kAccessOpacityFadeFrame = 226;
const double kAccessOpacityFadeValue = 0.25;

/// auth 第一段：Qt/src/BootTimeline.cpp:141 `typed("ID CONFIRMED", frame, 282, 295)`。
const String kAuthIdConfirmed = 'ID CONFIRMED';
const double kAuthIdConfirmedStartFrame = 282;
const double kAuthIdConfirmedEndFrame = 295;

/// auth 追加 " : "：Qt/src/BootTimeline.cpp:142-144。
const double kAuthColonFrame = 320;
const String kAuthColonSuffix = ' : ';

/// auth 分支切换点：Qt/src/BootTimeline.cpp:140 `frame < 363` ⇒ 363 起走 REQUEST RECEIVED 支线（367 才开始逐字）。
const double kAuthRequestReceivedBranchFrame = 363;

/// auth 第二段：Qt/src/BootTimeline.cpp:146 `typed("REQUEST RECEIVED", frame, 367, 389)`。
const String kAuthRequestReceived = 'REQUEST RECEIVED';
const double kAuthRequestReceivedStartFrame = 367;
const double kAuthRequestReceivedEndFrame = 389;

/// auth 分支切换点：Qt/src/BootTimeline.cpp:145 `frame < 421` ⇒ 421 起走 START PROCESSING 支线（423 才开始逐字）。
const double kAuthStartProcessingBranchFrame = 421;

/// auth 第三段：Qt/src/BootTimeline.cpp:148 `typed("START PROCESSING", frame, 423, 440)`。
const String kAuthStartProcessing = 'START PROCESSING';
const double kAuthStartProcessingStartFrame = 423;
const double kAuthStartProcessingEndFrame = 440;

/// 省略号：Qt/src/BootTimeline.cpp:149-151 `min(3, 1 + (frame - 449) / 4)`（整数除法）。
const double kAuthDotsStartFrame = 449;
const int kAuthDotsFrameStep = 4;
const int kAuthDotsMax = 3;

/// 终态文本：Qt/src/BootTimeline.cpp:152-154 `at(frame, {479, 485, 486}) → "              SING..."`。
/// 前缀正好 14 个空格（已逐字符核对）。
const String kAuthSingText = '              SING...';
const List<double> kAuthSingFrames = <double>[479, 485, 486];

/// logo 文本：Qt/src/BootTimeline.cpp:183 `typed("RHINE·LAB", frame, 232, 255)`（中点为 U+00B7）。
const String kLogoText = 'RHINE·LAB';
const double kLogoTextStartFrame = 232;
const double kLogoTextEndFrame = 255;

/// logoOpacity 区间：Qt/src/BootTimeline.cpp:181 `time >= 9.16 && time < 19.48 ? 1 : 0`。
const double kLogoOpacityStartSeconds = 9.16;
const double kLogoOpacityEndSeconds = 19.48;

/// authOpacity 区间 [281, 487)：Qt/src/BootTimeline.cpp:184。
const double kAuthOpacityStartFrame = 281;
const double kAuthOpacityEndFrame = 487;

/// poweredLetters：Qt/src/BootTimeline.cpp:186 `typed("POWERED BY RHINE LAB", frame, 279, 295).size()`。
const String kPoweredText = 'POWERED BY RHINE LAB';
const double kPoweredTextStartFrame = 279;
const double kPoweredTextEndFrame = 295;

/// glitch 帧：Qt/src/BootTimeline.cpp:159 `at(frame, {525, 526, 528, 529})`。
const List<double> kGlitchFrames = <double>[525, 526, 528, 529];

/// glitch 时的 ring 参数：Qt/src/BootTimeline.cpp:191-193 `1.94 / 0.32 / 2.2`。
const double kRingScaleGlitch = 1.94;
const double kRingOpacityGlitch = 0.32;
const double kRingBlurGlitch = 2.2;

/// scanFont：Qt/src/BootTimeline.cpp:195。
const double kScanFontSize = 26.5;

/// orbit 侧弧起帧：Qt/src/BootTimeline.cpp:123 `"sideVisible", frame >= 544`
/// （比较对象是未取整的 measuredFrame，:157-158）。
const double kOrbitSideVisibleFrame = 544;

/// ornament 起点：Qt/src/BootTimeline.cpp:198 `time >= 21.84`。
const double kOrnamentSeconds = 21.84;

/// welcome flash 基准帧：Qt/src/BootTimeline.cpp:160 `flashIndex = frame - 569`。
const double kWelcomeFlashBaseFrame = 569;

/// welcome 面板/墨色逐帧表：Qt/src/BootTimeline.cpp:163-164（长度 7 ⇒ [0,7)）。
const List<double> kWelcomePanel = <double>[1, 0, 0.28, 0, 1, 0, 0];
const List<double> kWelcomeInk = <double>[0, 0, 0.2, 1, 0, 0, 0.25];

/// company/welcomeLogo 起点与隐藏帧：Qt/src/BootTimeline.cpp:203, 207-208。
const double kCompanyStartFrame = 588;
const List<double> kCompanyHiddenFrames = <double>[590, 591];

/// companyMask 帧：Qt/src/BootTimeline.cpp:204 `at(frame, {594, 595})`。
const List<double> kCompanyMaskFrames = <double>[594, 595];

/// databaseOpacity 起点与隐藏帧：Qt/src/BootTimeline.cpp:206。
const double kDatabaseStartFrame = 626;
const List<double> kDatabaseHiddenFrames = <double>[628, 629, 631, 634];

/// 退场 / 背景 / 白闪：Qt/src/BootTimeline.cpp:161, 212-213。
const double kExitStartSeconds = 26.56;
const double kExitEndSeconds = 26.92;
const double kWelcomeScaleExitAmount = 0.46;
const double kExitBlurMax = 8;
const double kBackgroundEndSeconds = 26.92;
const double kWhiteStartSeconds = 26.16;
const double kWhiteEndSeconds = 26.88;

/// permissionOpacity 尾段起算：Qt/src/BootTimeline.cpp:196-197 `time < 21.8 ? progress(...) : value("permissionOpacity", ...)`。
const double kPermissionTrackFromSeconds = 21.8;
const double kPermissionFadeEndSeconds = 19.88;

/// 背景径向渐变（op == "gradient"）：Qt/src/Glyphs.cpp:806-812。
///
/// DEDUP-18 起本页**不再自绘**渐变：中心 979.2/518.4、半径 1100、色标 [0, .76, 1]、填充矩形
/// -4096..4096 的唯一权威在共享命令层 —— `hudBackgroundGradientCenterX` /
/// `hudBackgroundGradientCenterY` / `hudBackgroundGradientRadius` /
/// `hudBackgroundGradientStops` / `hudBackgroundGradientColor` / `hudBackgroundGradientRect`
/// （lib/hud/render/gradient_mask.dart）。
/// 本页只产出 [HudGradient] 命令（见 [buildBootBackgroundCommands]），几何由 painter 提供。

/// Qt 舞台中心 = 1920x1080 设计区中心，也是 scan 弧心：Qt/src/NativeHudBoot.cpp:331
/// `translate(960, 540)`（:319 `arc()` 的默认 x/y 也是 960/540）。
/// 竖屏（Qt 无竖屏舞台）用它把舞台中心平移到页面中心，见 [bootStageTranslate]。
const double kQtStageCenterX = 960;
const double kQtStageCenterY = 540;

/// 度→弧度：Qt/src/BootTimeline.cpp:22 `constexpr double radians = std::numbers::pi / 180;`
/// （scan.*/orbit.* 的 start/sweep 曲线是度数，取用前乘它：:89、:108-113）。
const double kDegreesToRadians = math.pi / 180;

/// scan.* track 键前缀：Qt/src/BootTimeline.cpp:91 `value("scan." + key, frame)`。
const String kTrackScanPrefix = 'scan.';

/// 文本基色：Qt/src/NativeHud.cpp:10-15 `ink()`（dark → calibratedWhite 0.92/0.92/0.92；
/// 亮色 → calibratedRGB 0.08/0.085/0.075）。此处按 8bit 量化（0.92*255 = 234.6 → 235）。
const Color kBootInkDark = Color(0xFFEBEBEB);
const Color kBootInkLight = Color(0xFF141613);

/// 竖屏（新增响应式语义）：左右安全边距 24，触控最小高度 48。
/// 说明：Qt 无竖屏像素，此处不假造 Qt 竖屏几何，只给全语义降级布局。
const double kPortraitButtonMargin = 24;
const double kPortraitTouchMinHeight = 48;

/// track 曲线键名（Qt/src/BootTimeline.cpp 的 `value(...)` 调用），仅本页用到的两条在此声明为常量。
const String kTrackRingOpacity = 'ringOpacity';
const String kTrackPermissionOpacity = 'permissionOpacity';

/// 叠加层 key：让「backgroundOpacity == 0 后不画背景」「white == 0 时不画白闪」
/// 「scanVisible == false 时不画弧」可被文本化核对。
const Key kBootBackgroundLayerKey = Key('boot.background');
const Key kBootFlashLayerKey = Key('boot.flash');
const Key kBootScanLayerKey = Key('boot.scan');

// ---------------------------------------------------------------------------
// 2) 纯函数（与 Qt 逐字等价，可独立测试）
// ---------------------------------------------------------------------------

/// `std::clamp(value, 0.0, 1.0)`（Qt/src/BootTimeline.cpp:17、Qt/src/SceneMotion.cpp:47）。
double bootClampUnit(double value) {
  if (value < 0) {
    return 0;
  }
  if (value > 1) {
    return 1;
  }
  return value;
}

/// Qt/src/BootTimeline.cpp:16-18 `progress(t, s, e) = clamp((t - s) / (e - s), 0, 1)`。
double bootProgress(double time, double start, double end) {
  return bootClampUnit((time - start) / (end - start));
}

/// Qt/src/SceneMotion.cpp:46-49 `ease(value)`（smoothstep：`v * v * (3 - 2v)`）。
double bootEase(double value) {
  final double clamped = bootClampUnit(value);
  return clamped * clamped * (3 - 2 * clamped);
}

/// Qt/src/BootTimeline.cpp:9-15 `typed(text, frame, start, end)`：
/// `frame < start` → 空串；否则取前 `min(size, 1 + floor((frame - start) * (size - 1) / (end - start)))` 个字符。
String bootTyped(String text, double frame, double start, double end) {
  if (frame < start) {
    return '';
  }
  final int count = 1 + ((frame - start) * (text.length - 1) / (end - start)).floor();
  return text.substring(0, math.min(text.length, count));
}

// ---------------------------------------------------------------------------
// 3) seam：track 曲线注入（默认 0，不伪造实测值）
// ---------------------------------------------------------------------------

/// 实测曲线注入 seam。
///
/// Qt 侧这些量来自 Assets/animation/boot-tracks.json 的实测曲线（BootTimeline.cpp:26-60 载入，
/// :192/:197/:205 等处消费）：logo 描边（logo.leftEdge / logo.movingCut / logo.drawStart / logo.drawEnd）、
/// scan 弧与轨道（scan.* / scanTracking / orbit.*）、brand 行（brandX / brandOpacity）、
/// highlightKeys、ringOpacity、permissionOpacity 尾段。
///
/// **本卡 pubspec.yaml 未声明任何 assets（assets 段整体被注释），且 pubspec 不在 T42 写域**，
/// 因此这里只能给出一律返回 0 的默认实现：不得编造实测值，也不得读 rootBundle/AssetManifest。
/// 真正接线由 HUD/资产层负责（记为 ARCH 依赖，不是本卡通过项）。
abstract class BootTrackSource {
  const BootTrackSource();

  /// [key] 为 Qt 侧 track 名，[frame] 为时间轴的 `measuredFrame`（= time * 25，未取整）；未接线时返回 0。
  double value(String key, double frame);
}

/// 未接线默认实现：任何 track 一律 0（见 [BootTrackSource] 说明）。
class ZeroBootTrackSource extends BootTrackSource {
  const ZeroBootTrackSource();

  @override
  double value(String key, double frame) => 0;
}

// ---------------------------------------------------------------------------
// 4) 时间轴采样（Qt/src/BootTimeline.cpp:126-214 的等价实现）
// ---------------------------------------------------------------------------

/// step（Qt/src/BootTimeline.cpp:129-138 的字符串，同名枚举）。
enum BootStep { access, logo, auth, scan, welcome }

/// boot 时间轴单帧状态（字段名自定，语义与 Qt JSON 键一一对应）。
class BootFrame {
  const BootFrame({
    required this.timelineSeconds,
    required this.measuredFrame,
    required this.frame,
    required this.step,
    required this.authLetters,
    required this.accessLetters,
    required this.accessOpacity,
    required this.logoOpacity,
    required this.logoLetters,
    required this.authOpacity,
    required this.poweredLetterCount,
    required this.scanVisible,
    required this.ringScale,
    required this.ringOpacity,
    required this.ringBlur,
    required this.scanFontSize,
    required this.permissionOpacity,
    required this.ornament,
    required this.welcomeVisible,
    required this.welcomePanel,
    required this.welcomeInk,
    required this.companyVisible,
    required this.companyMask,
    required this.welcomeLogo,
    required this.databaseOpacity,
    required this.welcomeScale,
    required this.welcomeOpacity,
    required this.exitBlur,
    required this.exit,
    required this.backgroundOpacity,
    required this.white,
  });

  /// Qt 键 `t`：时间轴秒（= elapsed + 5）。
  final double timelineSeconds;

  /// Qt 键的 track 查询基准 `time * 25`（BootTimeline.cpp:156，未取整）。
  final double measuredFrame;

  /// Qt 键 `f`：帧号（25fps）。
  final double frame;

  /// Qt 键 `step`。
  final BootStep step;

  /// Qt 键 `auth`：三段文本（含 " : " / 省略号 / 14 空格 SING...）。
  final String authLetters;

  /// Qt 键 `access`：ACCESS PERMISSION REQUIRED 的逐帧截断。
  final String accessLetters;

  /// Qt 键 `accessOpacity`。
  final double accessOpacity;

  /// Qt 键 `logoOpacity`。
  final double logoOpacity;

  /// Qt 键 `logoLetters`。
  final String logoLetters;

  /// Qt 键 `authOpacity`。
  final double authOpacity;

  /// Qt 键 `poweredLetters`（Qt 侧是字符数）。
  final int poweredLetterCount;

  /// Qt 键 `scanVisible`。
  final bool scanVisible;

  /// Qt 键 `ringScale`。
  final double ringScale;

  /// Qt 键 `ringOpacity`（非 glitch 时来自 track，默认 0）。
  final double ringOpacity;

  /// Qt 键 `ringBlur`。
  final double ringBlur;

  /// Qt 键 `scanFont`。
  final double scanFontSize;

  /// Qt 键 `permissionOpacity`（尾段来自 track，默认 0）。
  final double permissionOpacity;

  /// Qt 键 `ornament`。
  final bool ornament;

  /// Qt 键 `welcomeVisible`。
  final bool welcomeVisible;

  /// Qt 键 `welcomePanel`。
  final double welcomePanel;

  /// Qt 键 `welcomeInk`。
  final double welcomeInk;

  /// Qt 键 `companyVisible`。
  final bool companyVisible;

  /// Qt 键 `companyMask`。
  final bool companyMask;

  /// Qt 键 `welcomeLogo`。
  final bool welcomeLogo;

  /// Qt 键 `databaseOpacity`。
  final double databaseOpacity;

  /// Qt 键 `welcomeScale`。
  final double welcomeScale;

  /// Qt 键 `welcomeOpacity`。
  final double welcomeOpacity;

  /// Qt 键 `exitBlur`。
  final double exitBlur;

  /// Qt 键 `exit`。
  final double exit;

  /// Qt 键 `backgroundOpacity`：1 = 门槛不透明背景，0 = 透明叠加（26.92 起）。
  final double backgroundOpacity;

  /// Qt 键 `white`：白/黑闪 alpha（dark 主题闪黑，见 NativeHudBoot.cpp:169-170）。
  final double white;
}

/// 等价于 `BootTimeline::sample(appTime)` 的解析部分（Qt/src/BootTimeline.cpp:126-214）。
///
/// [timelineSeconds] 是 Qt 的 `time`（= appTime + 5，:127）；本函数不再加 5。
/// 从 Scene 的 elapsed 进入时用 [sampleBootFrame]（它负责 +5）。
BootFrame sampleBootTimeline(
  double timelineSeconds, {
  BootTrackSource tracks = const ZeroBootTrackSource(),
}) {
  final double time = timelineSeconds;
  final double frame = (time * kTimelineFrameRate + 0.00001).floorToDouble(); // :128
  final double measuredFrame = time * kTimelineFrameRate; // :156

  final BootStep step; // :129-138
  if (time < kBootStepLogoSeconds) {
    step = BootStep.access;
  } else if (time < kBootStepAuthSeconds) {
    step = BootStep.logo;
  } else if (time < kBootStepScanSeconds) {
    step = BootStep.auth;
  } else if (time < kBootStepWelcomeSeconds) {
    step = BootStep.scan;
  } else {
    step = BootStep.welcome;
  }

  final String authLetters; // :139-155
  if (frame < kAuthRequestReceivedBranchFrame) {
    String text = bootTyped(
      kAuthIdConfirmed,
      frame,
      kAuthIdConfirmedStartFrame,
      kAuthIdConfirmedEndFrame,
    );
    if (frame >= kAuthColonFrame) {
      text += kAuthColonSuffix;
    }
    authLetters = text;
  } else if (frame < kAuthStartProcessingBranchFrame) {
    authLetters = bootTyped(
      kAuthRequestReceived,
      frame,
      kAuthRequestReceivedStartFrame,
      kAuthRequestReceivedEndFrame,
    );
  } else {
    String text = bootTyped(
      kAuthStartProcessing,
      frame,
      kAuthStartProcessingStartFrame,
      kAuthStartProcessingEndFrame,
    );
    if (frame >= kAuthDotsStartFrame) {
      final int dots = math.min(kAuthDotsMax, 1 + (frame - kAuthDotsStartFrame) ~/ kAuthDotsFrameStep);
      text += '.' * dots;
    }
    if (kAuthSingFrames.contains(frame)) {
      text = kAuthSingText;
    }
    authLetters = text;
  }

  double accessOpacity = 0; // :165-168
  if (frame >= kAccessRevealStartFrame && frame < kAccessOpacityEndFrame) {
    accessOpacity = frame == kAccessOpacityFadeFrame ? kAccessOpacityFadeValue : 1;
  }

  // :179：access.left(frame < 170 ? 0 : accessCounts[min(17, frame - 170)])
  // 注意：frame < 170 时 Qt 的整个三元式取 0（不是 accessCounts[0]）⇒ left(0) 为空串；
  // 只有 frame >= 170 才查 accessCounts 表（180 行附近逐帧核对：169 -> ""，170 -> "A"）。
  final int accessCount = frame < kAccessRevealStartFrame
      ? 0
      : kAccessCounts[math.min(kAccessCounts.length - 1, (frame - kAccessRevealStartFrame).toInt())];
  final String accessLetters =
      kAccessText.substring(0, math.min(kAccessText.length, accessCount));

  final double logoOpacity = // :181
      time >= kLogoOpacityStartSeconds && time < kLogoOpacityEndSeconds ? 1 : 0;

  double ringOpacity; // :191-193
  final bool glitch = kGlitchFrames.contains(frame); // :159
  if (glitch) {
    ringOpacity = kRingOpacityGlitch;
  } else {
    ringOpacity = tracks.value(kTrackRingOpacity, measuredFrame);
  }

  double permissionOpacity; // :196-197
  if (time < kPermissionTrackFromSeconds) {
    permissionOpacity = bootProgress(time, kBootStepScanSeconds, kPermissionFadeEndSeconds);
  } else {
    permissionOpacity = tracks.value(kTrackPermissionOpacity, measuredFrame);
  }

  final double exit = bootEase(bootProgress(time, kExitStartSeconds, kExitEndSeconds)); // :161
  final int flashIndex = (frame - kWelcomeFlashBaseFrame).toInt(); // :160
  final bool flashActive = flashIndex >= 0 && flashIndex < kWelcomePanel.length; // :201-202

  return BootFrame(
    timelineSeconds: time,
    measuredFrame: measuredFrame,
    frame: frame,
    step: step,
    authLetters: authLetters,
    accessLetters: accessLetters,
    accessOpacity: accessOpacity,
    logoOpacity: logoOpacity, // :181
    logoLetters: bootTyped(kLogoText, frame, kLogoTextStartFrame, kLogoTextEndFrame), // :183
    authOpacity: frame >= kAuthOpacityStartFrame && frame < kAuthOpacityEndFrame ? 1 : 0, // :184
    poweredLetterCount: bootTyped(
      kPoweredText,
      frame,
      kPoweredTextStartFrame,
      kPoweredTextEndFrame,
    ).length, // :186
    scanVisible: time >= kBootStepScanSeconds && time < kBootStepWelcomeSeconds, // :187
    ringScale: glitch ? kRingScaleGlitch : 1, // :191
    ringOpacity: ringOpacity, // :192
    ringBlur: glitch ? kRingBlurGlitch : 0, // :193
    scanFontSize: kScanFontSize, // :195
    permissionOpacity: permissionOpacity, // :196-197
    ornament: time >= kOrnamentSeconds, // :198
    welcomeVisible: time >= kBootStepWelcomeSeconds && time < kBackgroundEndSeconds, // :200
    welcomePanel: flashActive ? kWelcomePanel[flashIndex] : 0, // :201
    welcomeInk: flashActive ? kWelcomeInk[flashIndex] : 1, // :202
    companyVisible:
        frame >= kCompanyStartFrame && !kCompanyHiddenFrames.contains(frame), // :203
    companyMask: kCompanyMaskFrames.contains(frame), // :204
    welcomeLogo: frame >= kCompanyStartFrame, // :207
    databaseOpacity:
        frame < kDatabaseStartFrame || kDatabaseHiddenFrames.contains(frame) ? 0 : 1, // :206
    welcomeScale: 1 - kWelcomeScaleExitAmount * exit, // :208
    welcomeOpacity: 1 - math.pow(exit, 3).toDouble(), // :209
    exitBlur: kExitBlurMax * exit, // :210
    exit: exit, // :211
    backgroundOpacity: time < kBackgroundEndSeconds ? 1 : 0, // :212
    white: bootEase(bootProgress(time, kWhiteStartSeconds, kWhiteEndSeconds)), // :213
  );
}

/// 以 elapsed（Qt/src/NativeSceneFrame.cpp:18 的量）为入参采样：内部加 kTimelineStartOffsetSeconds。
BootFrame sampleBootFrame(
  double elapsedSeconds, {
  BootTrackSource tracks = const ZeroBootTrackSource(),
}) {
  return sampleBootTimeline(elapsedSeconds + kTimelineStartOffsetSeconds, tracks: tracks);
}

// ---------------------------------------------------------------------------
// 5) 时钟与控制器（可测状态机）
// ---------------------------------------------------------------------------

/// 单调时钟抽象（产品用 [StopwatchBootClock]，测试用 Fake）。
abstract class BootClock {
  /// 单调递增秒数（不要求与墙钟对齐）。
  double nowSeconds();
}

/// 基于 [Stopwatch] 的单调时钟。
class StopwatchBootClock implements BootClock {
  StopwatchBootClock() {
    _stopwatch.start();
  }

  final Stopwatch _stopwatch = Stopwatch();

  @override
  double nowSeconds() => _stopwatch.elapsedMicroseconds / 1000000;

  /// 归零并继续计时。
  void reset() {
    _stopwatch
      ..reset()
      ..start();
  }
}

/// boot 交割去向（先到者胜，只回调一次）。
enum BootHandoff {
  /// 35s 自然到期 → detail（Qt/src/NativeSceneFrame.cpp:19-21 `setMode("detail")`）。
  detail,

  /// 用户点 ENTER SYSTEM（action "skip"）→ archive（Qt/src/NativeHudController.cpp:682-683 `mode("archive")`）。
  archive,
}

/// Boot 门槛状态机：时间锚点 + 35s 闸门 + skip/restart 交割。
///
/// 只负责状态与回调：**不 push 路由**（路由归 host，共享 router 不在本卡写域）。
class BootController extends ChangeNotifier {
  BootController({
    required BootClock clock,
    BootTrackSource? tracks,
    this.gateSeconds = kBootGateSeconds,
    this.startOffsetSeconds = kBootStartOffsetSeconds,
    this.themeDark = true,
  })  : _clock = clock,
        _tracks = tracks ?? const ZeroBootTrackSource();

  final BootClock _clock;
  final BootTrackSource _tracks;

  /// 闸门阈值（秒，比较对象是 elapsed）。
  final double gateSeconds;

  /// 进入 boot 时的起始偏移（秒），见 [kBootStartOffsetSeconds]。
  final double startOffsetSeconds;

  /// 主题：供 host/HUD 层查询（本页优先使用 [BootPage.themeDark]）。
  final bool themeDark;

  /// 交割回调（由 host/页面注入；控制器自身不做路由）。
  void Function(BootHandoff handoff)? onHandoff;

  double? _startAt;
  BootHandoff? _handoff;

  /// 进入 boot：Qt/src/NativeScene.cpp:178 `m_bootStart = m_clock - 1.76;`（清空上一次交割）。
  void start() {
    _startAt = _clock.nowSeconds() - startOffsetSeconds;
    _handoff = null;
    notifyListeners();
  }

  /// 是否已经进入 boot（有真实时间锚点）。Qt 侧锚点属于 scene mode，不随 widget 重建重置。
  bool get started => _startAt != null;

  /// 当前 elapsed（秒）。未 start 时等于 [startOffsetSeconds]（等价于刚进入 boot 的瞬间）。
  double get elapsedSeconds {
    final double? startAt = _startAt;
    if (startAt == null) {
      return startOffsetSeconds;
    }
    return _clock.nowSeconds() - startAt;
  }

  /// 当前时间轴帧（= [BootTimeline] 语义，见 [sampleBootFrame]）。
  BootFrame get frame => sampleBootFrame(elapsedSeconds, tracks: _tracks);

  /// 本控制器使用的 track 曲线源（页面侧 arc 生产者必须与时间轴采样同源）。
  BootTrackSource get tracks => _tracks;

  /// 已交割去向；null 表示仍在 boot。
  BootHandoff? get handoff => _handoff;

  /// 是否已交割。
  bool get finished => _handoff != null;

  /// 每帧推进：跨越 35s 闸门时一次性交割 detail（Qt/src/NativeSceneFrame.cpp:19-21）。
  void tick() {
    // 已交割即冻结：Qt 侧 mode 离开 boot 后不再采样/绘制 boot，页面也不应继续逐帧重建。
    if (_handoff != null) {
      return;
    }
    if (elapsedSeconds >= gateSeconds) {
      _finish(BootHandoff.detail);
    }
    notifyListeners();
  }

  /// 用户 skip（ENTER SYSTEM）→ archive（Qt/src/NativeHudController.cpp:682-683）。已交割时幂等无副作用。
  void skip() {
    if (_handoff != null) {
      return;
    }
    _finish(BootHandoff.archive);
  }

  /// replay：重新进入 boot（Qt/src/NativeHudController.cpp:698）⇒ 重锚 + 清交割。
  void restart() {
    start();
  }

  void _finish(BootHandoff handoff) {
    _handoff = handoff;
    onHandoff?.call(handoff);
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// 6) 布局（横屏 1:1 Qt；竖屏新增响应式语义）
// ---------------------------------------------------------------------------

/// 布局解析结果（纯数据，便于静态核对）。
class BootLayout {
  const BootLayout({
    required this.portrait,
    required this.buttonRect,
    required this.offsetX,
    required this.designWidthUsed,
  });

  /// 是否竖屏（height > width）。
  final bool portrait;

  /// ENTER SYSTEM 按钮命中矩形（屏幕坐标）。
  final Rect buttonRect;

  /// 设计区水平偏移 `(width - 1920) / 2`（只作用于设计区元素；按钮是屏幕坐标右锚，不加它）。
  final double offsetX;

  /// 设计区宽度（横屏 1920；竖屏无 Qt 依据，取可用宽）。
  final double designWidthUsed;
}

/// 解析 boot 页布局。
///
/// - 横屏：与 Qt 1:1，不缩放。按钮 = `Rect.fromLTWH(width - 261, 994, 202, 40)`
///   （Qt/src/NativeHudBoot.cpp:310，在 :292 restore() 之后 ⇒ 屏幕坐标右锚）。
/// - 竖屏：**新增响应式全语义**，Qt 无竖屏像素，此处不假造 Qt 竖屏几何：按钮贴底、左右 24 边距、
///   宽度取可用宽、高度满足触控最小 48，并让出 [safeArea]。
BootLayout resolveBootLayout(Size size, {EdgeInsets safeArea = EdgeInsets.zero}) {
  final bool portrait = size.height > size.width;
  if (portrait) {
    final double left = kPortraitButtonMargin + safeArea.left;
    final double right = size.width - kPortraitButtonMargin - safeArea.right;
    final double width = math.max(0.0, right - left);
    final double height = math.max(kPortraitTouchMinHeight, kEnterSystemHeight);
    final double top = size.height - safeArea.bottom - kPortraitButtonMargin - height;
    return BootLayout(
      portrait: true,
      buttonRect: Rect.fromLTWH(left, top, width, height),
      offsetX: 0,
      designWidthUsed: size.width,
    );
  }
  return BootLayout(
    portrait: false,
    buttonRect: Rect.fromLTWH(
      size.width - kEnterSystemRightInset,
      kEnterSystemTop,
      kEnterSystemWidth,
      kEnterSystemHeight,
    ),
    offsetX: (size.width - kQtDesignWidth) / 2, // NativeHudBoot.cpp:161
    designWidthUsed: kQtDesignWidth,
  );
}

// ---------------------------------------------------------------------------
// 7) 门槛层命令生产者（gradient / fill / arc —— DEDUP-18）
// ---------------------------------------------------------------------------

// 门槛层命令生产者（DEDUP-18）：把 Qt `NativeHud::boot()` / `NativeHud::scan()` 里那几条
// `gradient` / `fill` / `arc` op 在 Dart 侧等价产出，页面再交给共享 paintHudCommands 执行。
//
// 三条验收约束：
// 1. 命令字段、坐标空间、颜色来源全部取自 Qt 源码，逐条标 `Qt 文件:行`，不发明字段；
// 2. 页面不再用 Flutter widget 自绘门槛层（渐变/白闪/弧线），只按命令流画；
// 3. 每个图层是一条独立命令流（各自从 index 0 编号）。一次 painter 就是一次
//    paintHudCommands，canvas 状态不能跨图层传递，所以 Qt 里共享的
//    `save()` + `translate(offset, 0)` 帧（Qt/src/NativeHudBoot.cpp:162-163）在每层各自重建。
//
// 颜色一律经 decodeHudColor 构造：它与 wire 解码共用同一条 Gamma1.8→sRGB 路径
// （Qt/src/Glyphs.cpp:35-49），手写 HudColor 会漏掉 `calibrated*` 分支。

/// 页面坐标 → Qt 舞台坐标的 `translate` 量（`op({"translate", x, y})`：
/// Qt/src/NativeHud.cpp:16-43 的包装、Qt/src/Glyphs.cpp:660-661 的执行）。
///
/// - 横屏：Qt/src/NativeHudBoot.cpp:161 `const auto offset = (width - 1920) / 2;` 与
///   :163 `translate(offset, 0)` —— 只平移 x，y 恒 0；offset 即 [BootLayout.offsetX]。
/// - 竖屏：Qt 没有竖屏舞台（本页新增响应式语义，见 [resolveBootLayout]），把舞台中心
///   ([kQtStageCenterX], [kQtStageCenterY]) 平移到页面中心；半径/色标/弧长仍是舞台单位，不缩放。
({double dx, double dy}) bootStageTranslate(Size size, BootLayout layout) {
  if (layout.portrait) {
    return (
      dx: size.width / 2 - kQtStageCenterX,
      dy: size.height / 2 - kQtStageCenterY,
    );
  }
  return (dx: layout.offsetX, dy: 0);
}

/// `NativeHud::ink()`：Qt/src/NativeHud.cpp:10-15 —— dark 走 `calibratedWhite` 的
/// 0.92/0.92/0.92，亮色走 `calibratedRGB` 的 0.08/0.085/0.075（第 5 项字符串是 gamma 开关，
/// Qt/src/Glyphs.cpp:35-49）。
HudColor _bootInk(bool dark) => decodeHudColor(<Object?>[
      dark ? 0.92 : 0.08,
      dark ? 0.92 : 0.085,
      dark ? 0.92 : 0.075,
      1,
      dark ? 'calibratedWhite' : 'calibratedRGB',
    ]);

/// scan 白环的纸色：Qt/src/NativeHudBoot.cpp:332
/// `paper = dark ? {17/255, 24/255, 27/255, 1} : {1, 1, 1, 1}`（4 项 ⇒ 普通 RGBA，不做 gamma）。
HudColor _bootPaper(bool dark) => decodeHudColor(
      dark
          ? <Object?>[17 / 255, 24 / 255, 27 / 255, 1]
          : <Object?>[1, 1, 1, 1],
    );

/// `value("scan." + key, frame)`：Qt/src/BootTimeline.cpp:80-94（未命中 track 返回 0，:64-67）。
double _scanTrack(BootTrackSource tracks, double frame, String key) =>
    tracks.value(kTrackScanPrefix + key, frame);

/// `gradient` 图层命令：Qt/src/NativeHudBoot.cpp:162-168。
///
/// save(); translate(offset, 0); if (backgroundOpacity > 0) { save(); alpha(...);
/// gradient; restore(); }
///
/// - 字段：`gradient` op 只带一个参数 `dark`（Qt/src/NativeHudBoot.cpp:167、
///   Qt/src/Glyphs.cpp:806-812）；中心 (979.2, 518.4)、半径 1100、色标 [0, .76, 1] 全部写死在
///   Glyphs.cpp:807-811，wire 上不可配 ⇒ 由共享 painter 的 `hudBackgroundGradient` 提供。
/// - 坐标空间：op 在 `translate(offset, 0)` 之后执行，填充矩形 -4096..4096
///   （Qt/src/Glyphs.cpp:812）⇒ 渐变中心 = 舞台坐标 + offset。
/// - alpha：Qt 的 `gradient` 分支没有 alpha 参数，透明度走 painter opacity（:166 `alpha(...)`）；
///   共享 painter 用 `saveLayer` 承载（lib/hud/render/paint_stack.dart:578-604）。
///
/// [backgroundOpacity] <= 0 时返回空流：Qt 的 `if` 守卫（:164）⇒ 26.92s 后图层不存在（透明叠加）。
List<HudCommand> buildBootBackgroundCommands({
  required Size size,
  required BootLayout layout,
  required double backgroundOpacity,
  required bool dark,
}) {
  if (backgroundOpacity <= 0) {
    return const <HudCommand>[];
  }
  final ({double dx, double dy}) shift = bootStageTranslate(size, layout);
  int index = 0;
  return <HudCommand>[
    HudSave(index++),
    HudTranslate(index++, shift.dx, shift.dy),
    HudSave(index++),
    HudAlpha(index++, backgroundOpacity),
    HudGradient(index++, dark),
    HudRestore(index++),
    HudRestore(index++),
  ];
}

/// 白闪 `fill` 图层命令：Qt/src/NativeHudBoot.cpp:169-170。
///
/// const double flash = dark ? 0 : 1; fill(-offset, 0, width, 1080, {flash, flash, flash, white});
///
/// - 字段：`fill` op 的 wire 顺序是 `{"fill", color, x, y, w, h}`（Qt/src/NativeHud.cpp:16-43
///   的包装、Qt/src/Glyphs.cpp:684-691 的执行）⇒ [HudFill] 也是颜色在前。
/// - 颜色：`{flash, flash, flash, white}` 是 4 项数组，走普通 RGBA 分支（无 `calibrated` 第 5 项，
///   Qt/src/Glyphs.cpp:35-49），alpha 取第 4 项 `white`（:170）。
/// - 坐标空间：矩形是屏幕 `-offset .. -offset + width`、`0 .. 1080`（:170），在
///   `translate(offset, 0)` 之内 ⇒ 平移后正好覆盖页面。本页取 `(-dx, -dy, size.width,
///   size.height)`：1920x1080 时逐值等于 Qt（dy == 0、height == 1080）；横屏其它尺寸下
///   Qt 的 1080 高会被视口裁掉，本式的页面高与它像素等价；竖屏无 Qt 像素，用页面高让整层
///   真正铺满（否则白闪只盖 1080 高的带子）。⇒ 字面高度 1080 见 `kQtDesignHeight`，
///   这里的替换已记入残余风险。
/// - 白光**不乘 backgroundOpacity**：Qt 的 fill 在 `alpha(...)` 的 save/restore 之外（:169）。
/// - 已知偏差（RESIDUAL_RISK）：Qt 在 height <= 1080 时那 1080 高的矩形被视口裁掉，覆盖整屏，
///   与本节等价；height > 1080 时 Qt 只涂上 1080 高的一条，本式会多涂底部 height - 1080 的带子。
List<HudCommand> buildBootFlashCommands({
  required Size size,
  required BootLayout layout,
  required double white,
  required bool dark,
}) {
  final ({double dx, double dy}) shift = bootStageTranslate(size, layout);
  final double flash = dark ? 0.0 : 1.0; // :169 const double flash = dark ? 0 : 1;
  final HudColor color = decodeHudColor(<Object?>[flash, flash, flash, white]); // :170
  int index = 0;
  return <HudCommand>[
    HudSave(index++),
    HudTranslate(index++, shift.dx, shift.dy),
    HudFill(index++, color, -shift.dx, -shift.dy, size.width, size.height),
    HudRestore(index++),
  ];
}

/// `arc` 图层命令：Qt/src/NativeHudBoot.cpp:330-350（`scan()` 的弧段）。
///
/// save(); translate(960, 540); scale(ringScale); translate(-960, -540); alpha(ringOpacity);
/// 之后 arc(radius, start, sweep, x = 960, y = 540, width = 2, color = {}) 内：
/// if (radius > 0 && sweep > 0) op({"arc", x, y, radius, start, sweep, width,
/// color.isEmpty() ? ink() : color});
///
/// - 字段（Qt/src/Glyphs.cpp:761-774）：`{"arc", cx, cy, radius, start, sweep, penWidth, color}`；
///   `start`/`sweep` 是**弧度** —— Qt 先按 `radians = pi/180` 把度数换成弧度
///   （Qt/src/BootTimeline.cpp:22、:89），画的时候再取负（`-n(4)*180/pi`）；
///   共享 painter 直接按 wire 值 `arcTo`（lib/hud/render/paint_stack.dart:511-560）。
/// - 曲线来源：三条半径键（radius / whiteRadius / innerRadius）+ 六个角度键（outerStart,
///   outerSweep, whiteStart, whiteSweep, innerStart, innerSweep，:86-91 乘 radians）+ 侧弧的
///   orbit.column0..8，全部在 `measuredFrame = time * 25`（未取整，Qt/src/BootTimeline.cpp:156）
///   上取值；未接线时 [ZeroBootTrackSource] 一律 0 ⇒ 守卫全部拦掉，只留
///   save/translate/scale/alpha/restore 骨架（与 Qt 对空曲线的行为一致，:319-324）。
/// - 顺序即语义：:162-163 的 `translate(offset, 0)` → :330-336 的 scale/alpha →
///   :337-343 四条主弧 → :344-350 两条侧弧 → :370 `restore()`。
/// - 范围外（不生产）：scan() 还画 orbit 圆点与 ornament 核心（:351-369 的 `dot()` → `ellipse`
///   op）以及 :371-377 的 permission art；它们不属于 DEDUP-18 的 `gradient`/`arc` 两个 op，
///   本节只覆盖弧线。真正补 ellipse/art 生产者需另立原子（RESIDUAL_RISK，见报告）。
List<HudCommand> buildBootScanCommands({
  required BootFrame frame,
  required Size size,
  required BootLayout layout,
  required BootTrackSource tracks,
  required bool dark,
}) {
  // Qt/src/NativeHudBoot.cpp:252-254：if (boot["scanVisible"].toBool()) scan(boot);
  // scanVisible = time >= 19.48 && time < 22.76（Qt/src/BootTimeline.cpp:187）。
  if (!frame.scanVisible) {
    return const <HudCommand>[];
  }
  final ({double dx, double dy}) shift = bootStageTranslate(size, layout);
  final HudColor ink = _bootInk(dark); // :319-324 color.isEmpty() ? ink() : color
  final HudColor paper = _bootPaper(dark); // :332
  // :156 const auto measuredFrame = time * 25; —— scan()/orbit() 收到的就是这个未取整帧。
  final double measured = frame.measuredFrame;
  final List<HudCommand> commands = <HudCommand>[];
  int index = 0;

  void push(HudCommand command) {
    commands.add(command);
  }

  // :319-324 的 arc() lambda：守卫 radius > 0 && sweep > 0，默认 x/y = 960/540、宽 2、色 = ink。
  void arc(
    double radius,
    double start,
    double sweep, {
    double x = kQtStageCenterX,
    double y = kQtStageCenterY,
    double penWidth = 2,
    HudColor? color,
  }) {
    if (radius > 0 && sweep > 0) {
      push(HudArc(index++, x, y, radius, start, sweep, penWidth, color ?? ink));
    }
  }

  // Qt/src/NativeHudBoot.cpp:162-163：boot() 帧 save(); translate(offset, 0);
  push(HudSave(index++));
  push(HudTranslate(index++, shift.dx, shift.dy));
  // Qt/src/NativeHudBoot.cpp:330-336：scan() 的 save、绕弧心 (960,540) 的 scale、alpha(ringOpacity)。
  push(HudSave(index++));
  push(HudTranslate(index++, kQtStageCenterX, kQtStageCenterY)); // :331
  push(HudScale(index++, frame.ringScale, frame.ringScale)); // :334
  push(HudTranslate(index++, -kQtStageCenterX, -kQtStageCenterY)); // :335
  push(HudAlpha(index++, frame.ringOpacity)); // :336
  // :337-338 外环：scan.radius / outerStart / outerSweep，宽 2.4，ink。
  arc(
    _scanTrack(tracks, measured, 'radius'),
    _scanTrack(tracks, measured, 'outerStart') * kDegreesToRadians,
    _scanTrack(tracks, measured, 'outerSweep') * kDegreesToRadians,
    penWidth: 2.4,
  );
  // :339-340 白环：scan.whiteRadius / whiteStart / whiteSweep，宽 4，paper。
  arc(
    _scanTrack(tracks, measured, 'whiteRadius'),
    _scanTrack(tracks, measured, 'whiteStart') * kDegreesToRadians,
    _scanTrack(tracks, measured, 'whiteSweep') * kDegreesToRadians,
    penWidth: 4,
    color: paper,
  );
  // :341-343 内环两段：同一组 scan.innerRadius/innerStart/innerSweep，第二段起点 +pi，宽 2，ink。
  final double innerRadius = _scanTrack(tracks, measured, 'innerRadius');
  final double innerStart =
      _scanTrack(tracks, measured, 'innerStart') * kDegreesToRadians;
  final double innerSweep =
      _scanTrack(tracks, measured, 'innerSweep') * kDegreesToRadians;
  arc(innerRadius, innerStart, innerSweep);
  arc(innerRadius, innerStart + math.pi, innerSweep);
  // :344-350 侧弧：if (orbit["sideVisible"])（= frame >= 544，Qt/src/BootTimeline.cpp:123）
  // ⇒ 两条 side，几何取自 orbit.column0..8（:95-124）：x = column0/2、y = column1/3、
  // radius = column4（两段同半径）、start/sweep = column5..8（度→弧度），宽 2，ink。
  if (measured >= kOrbitSideVisibleFrame) {
    final List<double> column = <double>[
      for (int i = 0; i < 9; i++)
        tracks.value('orbit.column' + i.toString(), measured),
    ];
    arc(
      column[4],
      column[5] * kDegreesToRadians,
      column[7] * kDegreesToRadians,
      x: column[0],
      y: column[1],
    );
    arc(
      column[4],
      column[6] * kDegreesToRadians,
      column[8] * kDegreesToRadians,
      x: column[2],
      y: column[3],
    );
  }
  // :370 scan() 的 restore()；紧接 :162 帧的 restore()。
  push(HudRestore(index++));
  push(HudRestore(index++));
  return commands;
}

/// 执行一条门槛层命令流（共享 17-op 执行器，lib/hud/render/paint_stack.dart:237-245）。
///
/// 只做转发：字段已按 Qt 值产出，换算（arc 取负、alpha 乘性叠加、gradient 的 saveLayer）
/// 全部在共享层，页面不再介入几何。
class BootHudCommandPainter extends CustomPainter {
  const BootHudCommandPainter(this.commands);

  final List<HudCommand> commands;

  @override
  void paint(Canvas canvas, Size size) {
    paintHudCommands(canvas: canvas, commands: commands);
  }

  @override
  bool shouldRepaint(BootHudCommandPainter oldDelegate) =>
      oldDelegate.commands != commands;
}

// ---------------------------------------------------------------------------
// 8) 页面（透明叠加层）
// ---------------------------------------------------------------------------

/// Boot 门槛页：透明叠加层（门槛层命令流 + ENTER SYSTEM 按钮；真 HUD glyph 由 [hudBuilder] 注入）。
///
/// 约束：必须有界（全屏叠加层）；本页坐标即 Qt 的 1080 高舞台坐标，logical → stage 的缩放由 host 负责
/// （Qt/src/Engine.cpp:1353、Qt/qml/Main.qml:32-33）。
class BootPage extends StatefulWidget {
  const BootPage({
    this.controller,
    this.clock,
    this.tracks,
    this.themeDark = true,
    this.hudBuilder,
    this.onHandoff,
    super.key,
  });

  /// 外部控制器（不传则自建并自行 dispose）。
  final BootController? controller;

  /// 自建控制器时使用的时钟（不传用 [StopwatchBootClock]）。
  final BootClock? clock;

  /// track 曲线源（默认 [ZeroBootTrackSource]，一律 0，不伪造实测值）。
  final BootTrackSource? tracks;

  /// 主题：dark 时白闪为黑、文本用 calibratedWhite（Qt/src/NativeHudBoot.cpp:169、NativeHud.cpp:10-15）。
  final bool themeDark;

  /// 真 HUD 绘制 seam：null 时只画门槛层（窗口渐变/白闪/扫描弧的命令流 + ENTER SYSTEM 按钮）。
  ///
  /// 这是可接受的降级（不是像素通过）：glyph 真 advance/path、baseline 1.044、art 零偏移、
  /// Gamma1.8→sRGB 都由共享 HUD 层实现。约定：[hudBuilder] 只负责 glyph/art，不重绘门槛层
  /// （见 [kBootBackgroundLayerKey] / [kBootFlashLayerKey] / [kBootScanLayerKey]）。
  final Widget Function(BuildContext context, BootFrame frame)? hudBuilder;

  /// 交割回调（透传给控制器；35s→detail，skip→archive）。
  final void Function(BootHandoff handoff)? onHandoff;

  @override
  State<BootPage> createState() => _BootPageState();
}

class _BootPageState extends State<BootPage> with SingleTickerProviderStateMixin {
  late final BootController _controller;
  late final bool _ownsController;
  late final _ticker = createTicker(_onTick);
  void Function(BootHandoff handoff)? _previousOnHandoff;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ??
        BootController(
          clock: widget.clock ?? StopwatchBootClock(),
          tracks: widget.tracks,
          themeDark: widget.themeDark,
        );
    final void Function(BootHandoff handoff)? onHandoff = widget.onHandoff;
    _previousOnHandoff = _controller.onHandoff;
    if (onHandoff != null) {
      _controller.onHandoff = onHandoff;
    }
    // 锚点属于 scene mode：只有自建 controller 或宿主尚未 start 时才补一次 start()。
    // 已 start 的注入 controller 不能被页面重建重新锚定（Qt/src/NativeScene.cpp:178）。
    if (_ownsController || !_controller.started) {
      _controller.start();
    }
    _controller.addListener(_onControllerChanged);
    if (!_controller.finished) {
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) {
      _controller.dispose();
    } else {
      // 注入 controller 的宿主回调属于宿主：页面只临时覆盖，卸载时还原。
      _controller.onHandoff = _previousOnHandoff;
    }
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    // 每帧允许控制器推进闸门；交割由控制器一次性完成，页面不重复判断时间。
    _controller.tick();
    if (_controller.finished && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onControllerChanged() {
    if (!mounted) {
      return;
    }
    // replay/restart 会清除 handoff；此时恢复 ticker，否则页面停在冻结帧。
    if (!_controller.finished && !_ticker.isActive) {
      _ticker.start();
    }
    setState(() {});
  }

  /// ENTER SYSTEM / skip：几何在 [resolveBootLayout]，这里只做命中与语义（无涟漪 —— Qt 无涟漪）。
  ///
  /// 纵向用 [Baseline] 把 alphabetic baseline 钉在 [kEnterSystemTextBaseline]（相对按钮顶
  /// 为 1017.616 - 994 = 23.616），而不是钉盒顶：Qt 的 `translate(x, y + size * 1.044)`
  /// 定义的是基线（Glyphs.cpp:530-540），Flutter `Text` 的盒顶由字体 ascent/descent 决定，
  /// 钉盒顶会让基线随字体度量漂移（原审 NOTE-1）。
  /// 横向仍是 Qt/src/NativeHud.cpp:118-119 的 inset=0：从按钮左边界起排，不居中。
  Widget _buildEnterSystemButton() {
    final bool finished = _controller.finished;
    return Semantics(
      button: true,
      label: kEnterSystemLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: finished ? null : _controller.skip,
        child: Baseline(
          baseline: kEnterSystemTextBaseline - kEnterSystemTop,
          baselineType: TextBaseline.alphabetic,
          child: Text(
            kEnterSystemLabel,
            // 系统字体缩放不得改变 Qt 设计稿里的字形位置（Qt 端亦不随系统字体缩放）。
            textScaler: TextScaler.noScaling,
            style: TextStyle(
              fontSize: kEnterSystemTextSize,
              color: widget.themeDark ? kBootInkDark : kBootInkLight,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final BootFrame frame = _controller.frame;
    final EdgeInsets safeArea = MediaQuery.maybeOf(context)?.padding ?? EdgeInsets.zero;
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size size = constraints.biggest;
        final BootLayout layout = resolveBootLayout(size, safeArea: safeArea);
        final Widget? hud = widget.hudBuilder?.call(context, frame);
        final List<HudCommand> background = buildBootBackgroundCommands(
          size: size,
          layout: layout,
          backgroundOpacity: frame.backgroundOpacity,
          dark: widget.themeDark,
        );
        // 白闪：Qt/src/NativeHudBoot.cpp:169-170 发 fill（RGB = dark ? 0 : 1，alpha = white），
        // 且仍在 `if (backgroundOpacity > 0)` 块内（:164-171）⇒ 26.92s 后即使 white = 1 也不再画。
        // white == 0 时整层不可见 ⇒ 不建层（零像素差异，保留既有 [kBootFlashLayerKey] 语义）。
        final List<HudCommand> flash = frame.backgroundOpacity > 0 && frame.white > 0
            ? buildBootFlashCommands(
                size: size,
                layout: layout,
                white: frame.white,
                dark: widget.themeDark,
              )
            : const <HudCommand>[];
        final List<HudCommand> scan = buildBootScanCommands(
          frame: frame,
          size: size,
          layout: layout,
          tracks: _controller.tracks,
          dark: widget.themeDark,
        );
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 背景层：只在 backgroundOpacity > 0 时存在（26.92 起透明叠加，底下 3D 场景透出）。
            if (background.isNotEmpty) _commandLayer(kBootBackgroundLayerKey, background),
            if (flash.isNotEmpty) _commandLayer(kBootFlashLayerKey, flash),
            // 扫描弧层：只在 scanVisible（19.48s <= time < 22.76）时存在（NativeHudBoot.cpp:252-254）。
            if (scan.isNotEmpty) _commandLayer(kBootScanLayerKey, scan),
            // z 序：三层都在 hud 之下。Qt 顺序是 scan(:252-254) → welcome(:255-291) → brand，
            // 弧线压在 welcome 面板之下是对的；而 access/logo/auth 细字在 scan 之前绘制，
            // 会被弧线覆盖 —— 跨 seam 的层间 z 序无法用一条命令流表达（RESIDUAL_RISK，见报告）。
            if (hud != null) hud,
            // 按钮：NativeHudBoot.cpp:310 在所有 opacity 之外无条件绘制 ⇒ 淡出后仍在、仍可点。
            Positioned.fromRect(rect: layout.buttonRect, child: _buildEnterSystemButton()),
          ],
        );
      },
    );
  }

  /// 一层门槛层命令流：一个 painter 对应一次 `paintHudCommands`（不复用 canvas 状态）。
  Widget _commandLayer(Key key, List<HudCommand> commands) => CustomPaint(
        key: key,
        painter: BootHudCommandPainter(commands),
        child: const SizedBox.expand(),
      );
}
