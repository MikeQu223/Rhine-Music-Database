// T42-C18 / test/ui/t42/boot_page_test.dart
//
// Boot 门槛页（BootPage / BootController / BootTimeline 采样 / resolveBootLayout）原子测试。
// 依据 Qt/ 只读源，行号即证据（与 lib/ui/pages/boot_page.dart 内的注释一一对应）：
//   Qt/src/BootTimeline.cpp:9-21      typed() / progress() / at()
//   Qt/src/BootTimeline.cpp:126-214   sample(appTime)：time = appTime + 5；frame = floor(time*25 + 0.00001)
//   Qt/src/SceneMotion.cpp:46-49      ease() = smoothstep
//   Qt/src/NativeSceneFrame.cpp:18    elapsed = time - m_bootStart
//   Qt/src/NativeSceneFrame.cpp:19-21 mode == "boot" && elapsed >= 35 -> setMode("detail")
//   Qt/src/NativeSceneFrame.cpp:117   boot 时间轴入参就是 elapsed
//   Qt/src/NativeScene.cpp:176-179    进入 boot：m_bootStart = m_clock - 1.76（进入即 elapsed = 1.76）
//   Qt/src/NativeHudController.cpp:682-683  skip -> mode("archive")（不是 detail）
//   Qt/src/NativeHudController.cpp:698      replay -> mode("boot")
//   Qt/src/NativeHudBoot.cpp:161      offset = (width - 1920) / 2
//   Qt/src/NativeHudBoot.cpp:310      button("ENTER SYSTEM ↗", width - 261, 994, 202, 40, "skip", 14)
//                                     （位于 :292 restore() 之后 => 屏幕坐标右锚，不加 offsetX）
//   Qt/src/NativeHud.cpp:118-119      文本 y = 994 + (40 - 14) / 2 - 4 = 1003
//   Qt/src/Glyphs.cpp:806-812         boot 背景径向渐变（中心 979.2,518.4；半径 1100；三段停靠）
//
// 本文件只写不执行。所有期望值均按上述源行逐字推导，并用 IEEE754 双精度语义核对：
// 采样以帧号入参时使用 frame / kTimelineFrameRate，floor(frame/25*25 + 1e-5) == frame 已逐帧验证。
//
// 不伪造原则（硬约束）：hudBuilder == null 时页面只画门槛层（背景 + 白闪 + ENTER SYSTEM 按钮），
// 绝不绘制 RHINE·LAB / POWERED BY RHINE LAB / auth / access 等真 HUD 字形文本（那属于共享 HUD 层）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/ui/pages/boot_page.dart';

/// 可注入假时钟：测试禁止真实计时（不依赖真实秒表，也不用 pumpAndSettle）。
class FakeBootClock implements BootClock {
  double _seconds = 0;

  void setSeconds(double value) {
    _seconds = value;
  }

  void advance(double delta) {
    _seconds += delta;
  }

  @override
  double nowSeconds() => _seconds;
}

/// 以时间轴秒采样（BootTimeline::sample 的入参 appTime 语义，BootTimeline.cpp:126）。
BootFrame atTimelineSeconds(double seconds) => sampleBootTimeline(seconds);

/// 以帧号采样（frame / 25 后内部 floor(frame + 1e-5) == frame）。
BootFrame atFrame(int frame) => sampleBootTimeline(frame / kTimelineFrameRate);

/// 以 elapsed 秒采样（控制器语义：时间轴 = elapsed + 5，NativeSceneFrame.cpp:117）。
BootFrame atElapsed(double seconds) => sampleBootFrame(seconds);

/// 固定测试视口尺寸（logical = physical / devicePixelRatio）。
void useScreen(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Text 需要 Directionality；页面本身不提供（叠加层由 host 的 WidgetsApp 提供方向）。
Future<void> pumpBoot(WidgetTester tester, Widget page) {
  return tester.pumpWidget(
    Directionality(textDirection: TextDirection.ltr, child: page),
  );
}

/// 卸载页面以 dispose Ticker（否则 flutter_test 报 Ticker 未释放）。
Future<void> unmountBoot(WidgetTester tester) {
  return tester.pumpWidget(const SizedBox.shrink());
}

void main() {
  // -------------------------------------------------------------------------
  // 1) 数值常量（契约：全部带 Qt 证据）
  // -------------------------------------------------------------------------
  group('数值常量与 Qt 证据一致', () {
    test('boot 时间锚点/闸门/时间轴常量', () {
      expect(kBootStartOffsetSeconds, 1.76); // NativeScene.cpp:178
      expect(kBootGateSeconds, 35); // NativeSceneFrame.cpp:19
      expect(kTimelineStartOffsetSeconds, 5); // BootTimeline.cpp:127
      expect(kTimelineFrameRate, 25); // BootTimeline.cpp:128
      expect(kQtDesignWidth, 1920); // NativeHudBoot.cpp:161
      expect(kQtDesignHeight, 1080); // Engine.cpp:1353 舞台高
    });

    test('ENTER SYSTEM 按钮几何与文本（NativeHudBoot.cpp:310 / NativeHud.cpp:118-119）', () {
      expect(kEnterSystemRightInset, 261);
      expect(kEnterSystemTop, 994);
      expect(kEnterSystemWidth, 202);
      expect(kEnterSystemHeight, 40);
      expect(kEnterSystemLabel, 'ENTER SYSTEM ↗');
      expect(kEnterSystemAction, 'skip');
      expect(kEnterSystemTextSize, 14);
      // y = 994 + (40 - 14) / 2 - 4
      expect(kEnterSystemTextTop, 1003);
    });

    test('时间轴表数据（BootTimeline.cpp:162-164, :174, :153, :195）', () {
      expect(kAccessText, 'ACCESS PERMISSION REQUIRED');
      expect(kAccessText.length, 26);
      expect(kAccessCounts.length, 18);
      expect(kAccessCounts.last, 26);
      expect(kWelcomePanel, <double>[1, 0, 0.28, 0, 1, 0, 0]);
      expect(kWelcomeInk, <double>[0, 0, 0.2, 1, 0, 0, 0.25]);
      // SING 前 14 个空格
      expect(kAuthSingText.length, 21);
      expect(kAuthSingText.startsWith(' ' * 14), isTrue);
      expect(kAuthSingText.trim(), 'SING...');
      expect(kScanFontSize, 26.5);
      expect(kRingScaleGlitch, 1.94);
      expect(kRingOpacityGlitch, 0.32);
      expect(kRingBlurGlitch, 2.2);
    });

    test('背景径向渐变常量（Glyphs.cpp:806-812）', () {
      expect(kQtBackgroundCenterX, 979.2);
      expect(kQtBackgroundCenterY, 518.4);
      expect(kQtBackgroundRadius, 1100);
      expect(kBootGradientStops, <double>[0, 0.76, 1]);
      expect(kBootGradientDark.length, 3);
      expect(kBootGradientLight.length, 3);
      // 暗色末端 17,24,27 与场景底色 #11181b 一致（NativeSceneFrame.cpp:111）
      expect(kBootGradientDark.last, const Color(0xFF11181B));
    });
  });

  // -------------------------------------------------------------------------
  // 2) 时间轴边界（step / backgroundOpacity / white）
  // -------------------------------------------------------------------------
  group('时间轴边界（BootTimeline.cpp:127-138, :212-213）', () {
    test('time = 9.12：access -> logo 的分界（:130 用 time < 9.12 判 access）', () {
      final BootFrame f = atTimelineSeconds(9.12);
      expect(f.timelineSeconds, 9.12);
      expect(f.frame, 228.0);
      expect(f.step, BootStep.logo);
      expect(f.backgroundOpacity, 1); // :212 time < 26.92
      expect(f.white, 0); // :213 26.16 之后才上升
      expect(f.accessOpacity, 0); // :165-168（228 已出 [170,227)）
      expect(f.accessLetters, kAccessText); // :179 228 >= 170 => accessCounts[17] = 26
      expect(f.authLetters, ''); // :141 typed(..., 282, 295)，228 < 282
      expect(f.logoOpacity, 0); // :181 9.16 起
      expect(f.logoLetters, ''); // :183 typed(..., 232, 255)，228 < 232
      expect(f.poweredLetterCount, 0); // :186
      expect(f.scanVisible, isFalse);
      expect(f.ornament, isFalse);
      expect(f.welcomeVisible, isFalse);
      expect(f.exit, 0);
    });

    test('time = 9.16：logoOpacity 起点（:181）', () {
      expect(atTimelineSeconds(9.16).frame, 229.0);
      expect(atTimelineSeconds(9.16).logoOpacity, 1);
      expect(atTimelineSeconds(9.16).logoLetters, ''); // 229 < 232
    });

    test('time = 11.12：logo -> auth 的分界（:132）', () {
      final BootFrame f = atTimelineSeconds(11.12);
      expect(f.frame, 278.0);
      expect(f.step, BootStep.auth);
      expect(f.logoOpacity, 1);
      expect(f.logoLetters, kLogoText); // 278 >= 232 => 全串
      expect(f.poweredLetterCount, 0); // 278 < 279
      expect(f.authOpacity, 0); // :184 281 起
      expect(f.authLetters, ''); // 278 < 282
      expect(f.backgroundOpacity, 1);
      expect(f.white, 0);
    });

    test('time = 19.48：auth -> scan 的分界（:134），authorOpacity 下限 487（:184）', () {
      final BootFrame f = atTimelineSeconds(19.48);
      expect(f.frame, 487.0);
      expect(f.step, BootStep.scan);
      expect(f.scanVisible, isTrue); // :187
      expect(f.authOpacity, 0); // 487 不 < 487
      expect(f.authLetters, 'START PROCESSING...'); // :148-151
      expect(f.poweredLetterCount, 20); // 487 超出 295 => 全串 'POWERED BY RHINE LAB'
      expect(f.logoOpacity, 0); // 19.48 不 < 19.48
      expect(f.logoLetters, kLogoText);
      expect(f.accessOpacity, 0);
      expect(f.ornament, isFalse); // 21.84 起
      expect(f.welcomeVisible, isFalse);
      expect(f.permissionOpacity, 0); // :196-197 progress(19.48, 19.48, 19.88) = 0
    });

    test('ornament 起点 21.84（:198）', () {
      expect(atTimelineSeconds(21.8).frame, 545.0);
      expect(atTimelineSeconds(21.8).ornament, isFalse);
      expect(atTimelineSeconds(21.84).frame, 546.0);
      expect(atTimelineSeconds(21.84).ornament, isTrue);
    });

    test('time = 22.76：scan -> welcome 的分界（:136），welcome flash 首帧（:200-202）', () {
      final BootFrame f = atTimelineSeconds(22.76);
      expect(f.frame, 569.0);
      expect(f.step, BootStep.welcome);
      expect(f.scanVisible, isFalse); // 22.76 不 < 22.76
      expect(f.ornament, isTrue);
      expect(f.welcomeVisible, isTrue);
      expect(f.welcomePanel, 1); // flashIndex = 0 => welcomeIntro[0]
      expect(f.welcomeInk, 0); // => welcomeInk[0]
      expect(f.backgroundOpacity, 1);
      expect(f.white, 0);
      expect(f.exit, 0);
      expect(f.welcomeScale, 1);
      expect(f.welcomeOpacity, 1);
      expect(f.exitBlur, 0);
    });

    test('time = 26.16 / 26.56：白闪与退场起点（:161, :213）', () {
      expect(atTimelineSeconds(26.16).frame, 654.0);
      expect(atTimelineSeconds(26.16).white, 0);
      expect(atTimelineSeconds(26.16).exit, 0);
      expect(atTimelineSeconds(26.16).backgroundOpacity, 1);
      expect(atTimelineSeconds(26.56).frame, 664.0);
      expect(atTimelineSeconds(26.56).exit, 0);
      expect(atTimelineSeconds(26.56).backgroundOpacity, 1);
      expect(atTimelineSeconds(26.56).welcomeVisible, isTrue);
    });

    test('time = 26.88：退场中段（:161, :208-210）', () {
      final BootFrame f = atTimelineSeconds(26.88);
      expect(f.frame, 672.0);
      expect(f.white, 1);
      expect(f.backgroundOpacity, 1);
      expect(f.exit, closeTo(0.9657064471879248, 1e-15));
      expect(f.welcomeScale, closeTo(0.5557750342935546, 1e-15));
      expect(f.exitBlur, closeTo(7.725651577503398, 1e-15));
      expect(f.welcomeOpacity, closeTo(1 - 0.9657064471879248 * 0.9657064471879248 * 0.9657064471879248, 1e-12));
    });

    test('time = 26.92：背景转透明、白闪满、alert 退场完成（:208-213）', () {
      final BootFrame f = atTimelineSeconds(26.92);
      expect(f.frame, 673.0);
      expect(f.step, BootStep.welcome);
      expect(f.backgroundOpacity, 0); // 26.92 不 < 26.92 => 透明叠加，底下 3D 透出
      expect(f.white, 1);
      expect(f.exit, 1);
      expect(f.welcomeScale, closeTo(0.54, 1e-15)); // 1 - 0.46 * 1
      expect(f.welcomeOpacity, 0); // 1 - 1^3
      expect(f.exitBlur, 8);
      expect(f.welcomeVisible, isFalse);
      expect(f.welcomePanel, 0);
      expect(f.welcomeInk, 1);
    });

    test('帧号 <-> 时间轴秒 往返一致', () {
      for (final int frame in <int>[170, 187, 226, 282, 320, 363, 367, 421, 423, 449, 479, 485, 486, 525, 569, 576, 588, 590, 594, 626, 628, 1000]) {
        expect(atFrame(frame).frame, frame.toDouble(), reason: 'frame $frame 往返');
      }
    });
  });

  // -------------------------------------------------------------------------
  // 3) access 文本与 opacity
  // -------------------------------------------------------------------------
  group('ACCESS PERMISSION REQUIRED 截断与 opacity（BootTimeline.cpp:162, :165-168, :174, :179）', () {
    test('frame 170：首字符；169 及之前为空串（三元式整体取 0）', () {
      final BootFrame at169 = atFrame(169);
      expect(at169.frame, 169.0);
      expect(at169.accessLetters, ''); // Qt：frame < 170 ? 0 => left(0)
      expect(at169.accessOpacity, 0);
      expect(at169.step, BootStep.access);

      final BootFrame at170 = atFrame(170);
      expect(at170.accessLetters, 'A'); // accessCounts[0] = 1
      expect(at170.accessOpacity, 1); // [170, 227)
      expect(atFrame(171).accessLetters, 'A'); // accessCounts[1] = 1
      expect(atFrame(172).accessLetters, 'ACC'); // accessCounts[2] = 3
    });

    test('frame 187：满 26 字符（index 触顶 min(17, frame-170)）', () {
      final BootFrame f = atFrame(187);
      expect(f.accessLetters, kAccessText);
      expect(f.accessLetters.length, 26);
      expect(f.accessOpacity, 1);
    });

    test('frame 226：opacity 0.25 特例（:167）', () {
      final BootFrame f = atFrame(226);
      expect(f.accessLetters, kAccessText);
      expect(f.accessOpacity, 0.25);
    });

    test('frame 227：文本仍满长但 opacity 归 0（:166 frame < 227）', () {
      final BootFrame f = atFrame(227);
      expect(f.accessLetters, kAccessText);
      expect(f.accessOpacity, 0);
    });
  });

  // -------------------------------------------------------------------------
  // 4) auth 三段文本
  // -------------------------------------------------------------------------
  group('auth 三段文本（BootTimeline.cpp:139-155）', () {
    test('第一段 ID CONFIRMED（282 起，320 起追加 " : "）', () {
      expect(atFrame(281).authLetters, ''); // 281 < 282
      expect(atFrame(282).authLetters, 'I');
      expect(atFrame(295).authLetters, 'ID CONFIRMED'); // 12 字符满
      expect(atFrame(296).authLetters, 'ID CONFIRMED'); // 未到 320，无 " : "
      expect(atFrame(319).authLetters, 'ID CONFIRMED');
      expect(atFrame(320).authLetters, 'ID CONFIRMED : '); // 15 字符
      expect(atFrame(362).authLetters, 'ID CONFIRMED : ');
      expect(atFrame(363).authLetters, ''); // 切到第二段分支，367 才开始逐字
      expect(atFrame(366).authLetters, '');
    });

    test('第二段 REQUEST RECEIVED（367 起，421 切换）', () {
      expect(atFrame(367).authLetters, 'R');
      expect(atFrame(389).authLetters, 'REQUEST RECEIVED'); // 16 字符满
      expect(atFrame(420).authLetters, 'REQUEST RECEIVED');
      expect(atFrame(421).authLetters, ''); // 切到第三段分支，423 才开始逐字
      expect(atFrame(422).authLetters, '');
    });

    test('第三段 START PROCESSING + 省略号（423 起，449 起加点，上限 3）', () {
      expect(atFrame(423).authLetters, 'S');
      expect(atFrame(440).authLetters, 'START PROCESSING'); // 16 字符满
      expect(atFrame(448).authLetters, 'START PROCESSING'); // 448 < 449 无点
      expect(atFrame(449).authLetters, 'START PROCESSING.'); // min(3, 1 + 0/4) = 1
      expect(atFrame(452).authLetters, 'START PROCESSING.');
      expect(atFrame(453).authLetters, 'START PROCESSING..'); // 1 + 4/4 = 2
      expect(atFrame(457).authLetters, 'START PROCESSING...'); // 1 + 8/4 = 3
      expect(atFrame(464).authLetters, 'START PROCESSING...'); // 封顶 3
      expect(atFrame(478).authLetters, 'START PROCESSING...');
    });

    test('终态 14 空格 + SING...（479 / 485 / 486；480 与 487 不是）', () {
      expect(kAuthSingText, '              SING...');
      expect(atFrame(479).authLetters, kAuthSingText);
      expect(atFrame(480).authLetters, 'START PROCESSING...'); // 不在 {479,485,486}
      expect(atFrame(485).authLetters, kAuthSingText);
      expect(atFrame(486).authLetters, kAuthSingText);
      expect(atFrame(487).authLetters, 'START PROCESSING...');
    });

    test('authOpacity 区间 [281, 487)（:184）', () {
      expect(atFrame(280).authOpacity, 0);
      expect(atFrame(281).authOpacity, 1);
      expect(atFrame(486).authOpacity, 1);
      expect(atFrame(487).authOpacity, 0);
    });
  });

  // -------------------------------------------------------------------------
  // 5) scan 期的 glitch / ring / brand 兜底（track 未接线 => 0）
  // -------------------------------------------------------------------------
  group('glitch 与 track 兜底（BootTimeline.cpp:159, :191-197）', () {
    test('glitch 帧 {525,526,528,529}：ringScale 1.94 / ringOpacity 0.32 / ringBlur 2.2', () {
      for (final int frame in kGlitchFrames) {
        final BootFrame f = atFrame(frame);
        expect(f.ringScale, 1.94, reason: 'frame $frame');
        expect(f.ringOpacity, 0.32, reason: 'frame $frame');
        expect(f.ringBlur, 2.2, reason: 'frame $frame');
      }
    });

    test('非 glitch 帧：ring 由 track 驱动，未接线时全 0（不得编造实测值）', () {
      for (final int frame in <int>[524, 527, 530]) {
        final BootFrame f = atFrame(frame);
        expect(f.ringScale, 1, reason: 'frame $frame');
        expect(f.ringOpacity, 0, reason: 'frame $frame ringOpacity 来自 track');
        expect(f.ringBlur, 0, reason: 'frame $frame');
      }
    });

    test('permissionOpacity 尾段来自 track：21.8 前用 progress，之后为 0（未接线）', () {
      expect(atFrame(487).permissionOpacity, 0); // t = 19.48
      expect(atFrame(492).permissionOpacity, closeTo(0.5, 1e-12)); // t = 19.68
      expect(atTimelineSeconds(19.88).permissionOpacity, 1);
      expect(atTimelineSeconds(21.8).permissionOpacity, 0); // 21.8 起走 track
      expect(atTimelineSeconds(23.0).permissionOpacity, 0);
    });

    test('scanFont 恒为 26.5（:195）', () {
      expect(atTimelineSeconds(20.0).scanFontSize, 26.5);
      expect(atTimelineSeconds(5.0).scanFontSize, 26.5);
    });

    test('welcome flash 序号取值表（:160, :201-202）', () {
      expect(atFrame(569).welcomePanel, 1);
      expect(atFrame(569).welcomeInk, 0);
      expect(atFrame(570).welcomePanel, 0);
      expect(atFrame(571).welcomePanel, 0.28);
      expect(atFrame(573).welcomePanel, 1); // flashIndex = 4 => welcomeIntro[4] = 1
      expect(atFrame(575).welcomePanel, 0); // flashIndex = 6 => welcomeIntro[6] = 0
      expect(atFrame(576).welcomePanel, 0); // flashIndex = 7 => 越界 => 0
      expect(atFrame(576).welcomeInk, 1); // 越界 => 1
      expect(atFrame(573).welcomeInk, 0); // welcomeInk[4] = 0
      expect(atFrame(574).welcomePanel, 0); // flashIndex = 5 => welcomeIntro[5] = 0
      expect(atFrame(574).welcomeInk, 0);
      expect(atFrame(575).welcomeInk, 0.25); // welcomeInk[6] = 0.25
    });

    test('company / database / welcomeLogo 帧门槛（:203-207）', () {
      expect(atFrame(587).companyVisible, isFalse);
      expect(atFrame(588).companyVisible, isTrue);
      expect(atFrame(588).welcomeLogo, isTrue);
      expect(atFrame(590).companyVisible, isFalse);
      expect(atFrame(591).companyVisible, isFalse);
      expect(atFrame(592).companyVisible, isTrue);
      expect(atFrame(594).companyMask, isTrue);
      expect(atFrame(595).companyMask, isTrue);
      expect(atFrame(593).companyMask, isFalse);
      expect(atFrame(626).databaseOpacity, 1); // 626 不满足 frame < 626，也不在 {628,629,631,634} 内
      expect(atFrame(628).databaseOpacity, 0);
      expect(atFrame(629).databaseOpacity, 0);
      expect(atFrame(630).databaseOpacity, 1);
      expect(atFrame(631).databaseOpacity, 0);
      expect(atFrame(634).databaseOpacity, 0);
      expect(atFrame(627).databaseOpacity, 1);
      expect(atFrame(1000).databaseOpacity, 1);
    });
  });

  // -------------------------------------------------------------------------
  // 6) 控制器：35s 闸门 / skip / restart（两条交割路径分离）
  // -------------------------------------------------------------------------
  group('BootController 交割状态机', () {
    test('未 start：elapsed = startOffset，frame 取首帧（NativeScene.cpp:178）', () {
      final BootController c = BootController(clock: FakeBootClock());
      expect(c.started, isFalse);
      expect(c.elapsedSeconds, 1.76);
      expect(c.handoff, isNull);
      expect(c.finished, isFalse);
      // elapsed 1.76 => time 6.76 => frame 169
      expect(c.frame.frame, 169.0);
      expect(c.frame.step, BootStep.access);
      expect(c.frame.accessLetters, '');
      expect(c.frame.backgroundOpacity, 1);
      c.dispose();
    });

    test('start()：_startAt = now - 1.76 => 进入即 elapsed 1.76，不是 0', () {
      final FakeBootClock clock = FakeBootClock();
      final BootController c = BootController(clock: clock);
      clock.setSeconds(0);
      expect(c.started, isFalse);
      c.start();
      expect(c.started, isTrue);
      expect(c.elapsedSeconds, 1.76); // 0 - (0 - 1.76)
      expect(c.frame.timelineSeconds, closeTo(6.76, 1e-12)); // 时间轴 = elapsed + 5
      expect(c.frame.measuredFrame, closeTo(169, 1e-9)); // (1.76 + 5) * 25
      expect(c.frame.frame, 169.0);
      c.dispose();
    });

    test('sampleBootFrame：elapsed 入口与时间轴入口一致（+5）', () {
      expect(atElapsed(0).timelineSeconds, 5);
      expect(atElapsed(0).frame, 125.0);
      expect(atElapsed(0).step, BootStep.access);
      expect(atElapsed(0).accessLetters, '');
      expect(atElapsed(1.76).frame, 169.0);
      expect(atElapsed(1.76).accessLetters, '');
      expect(atElapsed(21.92).backgroundOpacity, 0); // time 26.92 => 透明
      expect(atElapsed(21.92).white, 1);
    });

    test('35s 闸门：34.999 不交割；35.0 => detail 且只交割一次', () {
      final FakeBootClock clock = FakeBootClock();
      final List<BootHandoff> handoffs = <BootHandoff>[];
      final BootController c = BootController(clock: clock, startOffsetSeconds: 0);
      c.onHandoff = handoffs.add;
      c.start();
      expect(c.elapsedSeconds, 0);

      clock.setSeconds(34.999);
      c.tick();
      expect(c.handoff, isNull);
      expect(c.finished, isFalse);
      expect(handoffs, isEmpty);

      clock.setSeconds(35);
      c.tick();
      expect(c.handoff, BootHandoff.detail);
      expect(c.finished, isTrue);
      expect(handoffs, <BootHandoff>[BootHandoff.detail]);

      clock.setSeconds(40);
      c.tick();
      c.tick();
      expect(c.handoff, BootHandoff.detail);
      expect(handoffs.length, 1, reason: '跨越瞬间只交割一次');
      c.dispose();
    });

    test('默认 1.76 偏移下：raw 33.24 才是闸门（elapsed 35.0）', () {
      final FakeBootClock clock = FakeBootClock();
      final List<BootHandoff> handoffs = <BootHandoff>[];
      final BootController c = BootController(clock: clock);
      c.onHandoff = handoffs.add;
      clock.setSeconds(0);
      c.start();

      clock.setSeconds(33.23); // elapsed = 34.989999999999995 < 35
      c.tick();
      expect(c.elapsedSeconds, lessThan(kBootGateSeconds));
      expect(c.handoff, isNull);

      clock.setSeconds(33.24); // elapsed = 35.0
      c.tick();
      expect(c.elapsedSeconds, kBootGateSeconds);
      expect(c.handoff, BootHandoff.detail);
      expect(handoffs.length, 1);
      c.dispose();
    });

    test('skip：任意 elapsed 都交割 archive；交割后 tick 不再改判 detail', () {
      final FakeBootClock clock = FakeBootClock();
      final List<BootHandoff> handoffs = <BootHandoff>[];
      final BootController c = BootController(clock: clock, startOffsetSeconds: 0);
      c.onHandoff = handoffs.add;
      c.start();

      clock.setSeconds(3.5);
      c.skip();
      expect(c.handoff, BootHandoff.archive);
      expect(handoffs, <BootHandoff>[BootHandoff.archive]);

      c.skip(); // 幂等
      expect(handoffs.length, 1);

      clock.setSeconds(100);
      c.tick();
      expect(c.handoff, BootHandoff.archive, reason: 'skip 抢占；35s 之后也不得改判 detail');
      expect(handoffs.length, 1);
      c.dispose();
    });

    test('交割后 tick 不再 notify（页面已冻结，避免 60fps 重建）', () {
      final FakeBootClock clock = FakeBootClock();
      final BootController c = BootController(clock: clock, startOffsetSeconds: 0);
      c.start();
      clock.setSeconds(3);
      c.skip();
      int notifications = 0;
      c.addListener(() => notifications++);

      clock.setSeconds(40);
      c.tick();
      expect(c.handoff, BootHandoff.archive);
      expect(notifications, 0, reason: '已交割后 tick 必须直接返回');
      c.dispose();
    });

    test('restart：清交割并重锚（NativeHudController.cpp:698 replay）', () {
      final FakeBootClock clock = FakeBootClock();
      final List<BootHandoff> handoffs = <BootHandoff>[];
      final BootController c = BootController(clock: clock);
      c.onHandoff = handoffs.add;
      clock.setSeconds(0);
      c.start();

      clock.setSeconds(35); // elapsed = 36.76 >= 35
      c.tick();
      expect(c.handoff, BootHandoff.detail);

      clock.setSeconds(100);
      c.restart();
      expect(c.handoff, isNull);
      expect(c.finished, isFalse);
      expect(c.elapsedSeconds, closeTo(1.76, 1e-9)); // 回到 startOffset
      expect(c.frame.step, BootStep.access);

      clock.setSeconds(101);
      c.tick(); // elapsed 2.76 < 35：不立刻交割
      expect(c.handoff, isNull);
      c.dispose();
    });

    test('restart 在 startOffset 0 时精确归零', () {
      final FakeBootClock clock = FakeBootClock();
      final BootController c = BootController(clock: clock, startOffsetSeconds: 0);
      c.start();
      clock.setSeconds(80);
      c.tick();
      expect(c.handoff, BootHandoff.detail);
      c.restart();
      expect(c.elapsedSeconds, 0);
      expect(c.handoff, isNull);
      c.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // 7) 布局：横屏 1:1 Qt；竖屏新增响应式语义
  // -------------------------------------------------------------------------
  group('resolveBootLayout', () {
    test('1920x1080：按钮 = Rect(1659, 994, 202, 40)，offsetX = 0', () {
      final BootLayout layout = resolveBootLayout(const Size(1920, 1080));
      expect(layout.portrait, isFalse);
      expect(layout.offsetX, 0);
      expect(layout.designWidthUsed, 1920);
      expect(layout.buttonRect, const Rect.fromLTWH(1659, 994, 202, 40));
    });

    test('2400x1080：offsetX = 240，按钮右锚 left = 2139（不加 offsetX）', () {
      final BootLayout layout = resolveBootLayout(const Size(2400, 1080));
      expect(layout.portrait, isFalse);
      expect(layout.offsetX, 240);
      expect(layout.buttonRect.left, 2139);
      expect(layout.buttonRect.top, 994);
      expect(layout.buttonRect.width, 202);
      expect(layout.buttonRect.height, 40);
      // 若错误地叠加了设计区偏移，left 会是 240 + 1659 = 1899；Qt 的按钮在 restore() 之后，故不是。
      expect(layout.buttonRect.left, isNot(1899));
    });

    test('竖屏 1080x2400：新增全语义（贴底、24 边距、触控最小 48）', () {
      final BootLayout layout = resolveBootLayout(const Size(1080, 2400));
      expect(layout.portrait, isTrue);
      expect(layout.offsetX, 0);
      expect(layout.designWidthUsed, 1080);
      expect(layout.buttonRect.left, 24);
      expect(layout.buttonRect.right, 1056); // 24 右边距
      expect(layout.buttonRect.width, 1032);
      expect(layout.buttonRect.height, greaterThanOrEqualTo(48));
      expect(layout.buttonRect.bottom, 2376); // 贴底 24
    });

    test('竖屏让出 SafeArea（y 由安全区决定）', () {
      final BootLayout layout = resolveBootLayout(
        const Size(1080, 2400),
        safeArea: const EdgeInsets.only(left: 16, right: 8, bottom: 48),
      );
      expect(layout.buttonRect.left, 40); // 24 + 16
      expect(layout.buttonRect.width, 1008); // 1080 - 40 - 32
      expect(layout.buttonRect.bottom, 2400 - 48 - 24);
      expect(layout.buttonRect.height, greaterThanOrEqualTo(48));
    });

    test('横屏小尺寸不静默缩放（Qt 1:1，超出即超出）', () {
      final BootLayout layout = resolveBootLayout(const Size(800, 480));
      expect(layout.portrait, isFalse);
      expect(layout.buttonRect.left, 539); // 800 - 261
      expect(layout.offsetX, (800 - 1920) / 2);
    });

    test('正方形按横屏处理（portrait = height > width）', () {
      final BootLayout layout = resolveBootLayout(const Size(1080, 1080));
      expect(layout.portrait, isFalse);
      expect(layout.buttonRect.left, 819); // 1080 - 261
    });
  });

  // -------------------------------------------------------------------------
  // 8) 组件：透明叠加层、按钮命中与交割
  // -------------------------------------------------------------------------
  group('BootPage 组件行为', () {
    testWidgets('1920x1080：无 Scaffold/Material；按钮矩形精确；tap => archive', (WidgetTester tester) async {
      useScreen(tester, const Size(1920, 1080));
      final FakeBootClock clock = FakeBootClock();
      final List<BootHandoff> handoffs = <BootHandoff>[];
      final BootController controller = BootController(clock: clock);

      await pumpBoot(tester, BootPage(controller: controller, onHandoff: handoffs.add));

      // 透明叠加层：不是整页 Scaffold/Material
      expect(find.byType(Scaffold), findsNothing);
      expect(find.byType(Material), findsNothing);
      // elapsed 1.76 => time 6.76 => backgroundOpacity 1；white 0 => 无白闪层
      expect(find.byKey(kBootBackgroundLayerKey), findsOneWidget);
      expect(find.byKey(kBootFlashLayerKey), findsNothing);

      expect(find.text(kEnterSystemLabel), findsOneWidget);
      expect(
        tester.getRect(find.byType(GestureDetector)),
        const Rect.fromLTWH(1659, 994, 202, 40),
      );
      // Qt/src/NativeHud.cpp:118-119：文本左对齐、顶边 1003，不是居中。
      expect(tester.getTopLeft(find.text(kEnterSystemLabel)), const Offset(1659, 1003));

      await tester.tap(find.text(kEnterSystemLabel));
      expect(handoffs, <BootHandoff>[BootHandoff.archive]);
      expect(controller.handoff, BootHandoff.archive);

      // 已交割：按钮不再响应（幂等）
      await tester.pump();
      await tester.tap(find.text(kEnterSystemLabel));
      await tester.pump();
      expect(handoffs.length, 1);

      await unmountBoot(tester);
    });

    testWidgets('backgroundOpacity > 0 时背景层是 Qt 径向渐变（Glyphs.cpp:806-812）', (WidgetTester tester) async {
      useScreen(tester, const Size(1920, 1080));
      final BootController controller = BootController(clock: FakeBootClock());
      await pumpBoot(tester, BootPage(controller: controller));

      final DecoratedBox box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(kBootBackgroundLayerKey),
          matching: find.byType(DecoratedBox),
        ),
      );
      final RadialGradient gradient =
          (box.decoration as BoxDecoration).gradient! as RadialGradient;
      expect(gradient.colors, kBootGradientDark); // 默认 themeDark = true
      expect(gradient.stops, kBootGradientStops);
      expect(gradient.center.x, closeTo(2 * 979.2 / 1920 - 1, 1e-12));
      expect(gradient.center.y, closeTo(2 * 518.4 / 1080 - 1, 1e-12));
      expect(gradient.radius, closeTo(1100 / 1080, 1e-12));

      await unmountBoot(tester);
    });

    testWidgets('26.92s 之后背景层与白闪层都消失，ENTER SYSTEM 仍在且仍可点（NativeHudBoot.cpp:164-171, :310）', (WidgetTester tester) async {
      useScreen(tester, const Size(1920, 1080));
      final FakeBootClock clock = FakeBootClock();
      final List<BootHandoff> handoffs = <BootHandoff>[];
      final BootController controller = BootController(clock: clock, startOffsetSeconds: 0);

      await pumpBoot(tester, BootPage(controller: controller, onHandoff: handoffs.add));
      await tester.pump();
      expect(find.byKey(kBootBackgroundLayerKey), findsOneWidget); // elapsed 0 => time 5

      clock.setSeconds(22); // time 27 > 26.92：越过背景转透明边界
      await tester.pump();
      expect(controller.elapsedSeconds, 22);
      expect(controller.frame.timelineSeconds, 27);
      expect(controller.frame.backgroundOpacity, 0);
      expect(controller.frame.white, 1);
      expect(find.byKey(kBootBackgroundLayerKey), findsNothing);
      // Qt 的 white fill 嵌在 backgroundOpacity > 0 块内：26.92s 后 bg=0，white=1 也不画。
      expect(find.byKey(kBootFlashLayerKey), findsNothing);
      expect(find.text(kEnterSystemLabel), findsOneWidget);

      await tester.tap(find.text(kEnterSystemLabel));
      expect(handoffs, <BootHandoff>[BootHandoff.archive]);

      await unmountBoot(tester);
    });

    testWidgets('Ticker 每帧 tick：35s 闸门由页面驱动，onHandoff 收到 detail；交割后停 ticker', (WidgetTester tester) async {
      useScreen(tester, const Size(1920, 1080));
      final FakeBootClock clock = FakeBootClock();
      final List<BootHandoff> handoffs = <BootHandoff>[];
      final BootController controller = BootController(clock: clock, startOffsetSeconds: 0);
      int hudBuilds = 0;

      await pumpBoot(
        tester,
        BootPage(
          controller: controller,
          onHandoff: handoffs.add,
          hudBuilder: (BuildContext context, BootFrame frame) {
            hudBuilds++;
            return const SizedBox.shrink();
          },
        ),
      );
      await tester.pump();
      expect(handoffs, isEmpty);

      clock.setSeconds(35);
      await tester.pump(); // 一帧 => controller.tick()
      expect(handoffs, <BootHandoff>[BootHandoff.detail]);
      expect(controller.handoff, BootHandoff.detail);

      final int buildsAtGate = hudBuilds;
      clock.setSeconds(60);
      await tester.pump();
      expect(handoffs.length, 1, reason: '只交割一次');
      expect(hudBuilds, buildsAtGate, reason: '交割后 ticker 停止，不再 setState/重建');

      await unmountBoot(tester);
    });

    testWidgets('themeDark = false：浅色渐变 + 白色闪（NativeHudBoot.cpp:169 flash = dark ? 0 : 1）', (WidgetTester tester) async {
      useScreen(tester, const Size(1920, 1080));
      final FakeBootClock clock = FakeBootClock();
      final BootController controller = BootController(clock: clock, startOffsetSeconds: 0);

      await pumpBoot(tester, BootPage(controller: controller, themeDark: false));
      await tester.pump();

      final DecoratedBox box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(kBootBackgroundLayerKey),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect(((box.decoration as BoxDecoration).gradient! as RadialGradient).colors, kBootGradientLight);

      clock.setSeconds(21.88); // time 26.88 => backgroundOpacity 1, white 1
      await tester.pump();
      expect(controller.frame.backgroundOpacity, 1);
      expect(controller.frame.white, 1);
      final ColoredBox flash = tester.widget<ColoredBox>(find.byKey(kBootFlashLayerKey));
      expect(flash.color, const Color(0xFFFFFFFF));

      await unmountBoot(tester);
    });

    testWidgets('默认 dark 主题白闪为黑（NativeHudBoot.cpp:169-170）', (WidgetTester tester) async {
      useScreen(tester, const Size(1920, 1080));
      final FakeBootClock clock = FakeBootClock();
      final BootController controller = BootController(clock: clock, startOffsetSeconds: 0);
      await pumpBoot(tester, BootPage(controller: controller));
      await tester.pump();

      clock.setSeconds(21.88); // time 26.88 => backgroundOpacity 1, white 1
      await tester.pump();
      expect(controller.frame.backgroundOpacity, 1);
      expect(controller.frame.white, 1);
      final ColoredBox flash = tester.widget<ColoredBox>(find.byKey(kBootFlashLayerKey));
      expect(flash.color, const Color(0xFF000000));

      await unmountBoot(tester);
    });

    testWidgets('竖屏 1080x2400：背景渐变居中（新增语义，不沿用横屏舞台锚点）', (WidgetTester tester) async {
      useScreen(tester, const Size(1080, 2400));
      final BootController controller = BootController(clock: FakeBootClock());
      await pumpBoot(tester, BootPage(controller: controller));

      final DecoratedBox box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(kBootBackgroundLayerKey),
          matching: find.byType(DecoratedBox),
        ),
      );
      final RadialGradient gradient =
          (box.decoration as BoxDecoration).gradient! as RadialGradient;
      expect(gradient.center, Alignment.center);

      await unmountBoot(tester);
      controller.dispose();
    });

    testWidgets('竖屏 1080x2400：按钮贴底、高度 >= 48（新增响应式语义，非 Qt 像素）', (WidgetTester tester) async {
      useScreen(tester, const Size(1080, 2400));
      final BootController controller = BootController(clock: FakeBootClock());
      await pumpBoot(tester, BootPage(controller: controller));

      final Rect rect = tester.getRect(find.byType(GestureDetector));
      expect(rect.left, 24);
      expect(rect.width, 1032);
      expect(rect.height, greaterThanOrEqualTo(48));
      expect(rect.bottom, 2376);
      expect(find.text(kEnterSystemLabel), findsOneWidget);

      await unmountBoot(tester);
    });

    testWidgets('注入已 start 的 controller：页面挂载不重锚（Qt 锚点在 scene mode，NativeScene.cpp:176-179）', (WidgetTester tester) async {
      useScreen(tester, const Size(1920, 1080));
      final FakeBootClock clock = FakeBootClock();
      final BootController controller = BootController(clock: clock);
      clock.setSeconds(0);
      controller.start(); // 宿主在进入 boot 时已锚定：elapsed = 1.76
      clock.setSeconds(5); // 5 秒后挂载页面：elapsed 应为 6.76，而不是被页面重置回 1.76

      await pumpBoot(tester, BootPage(controller: controller));
      await tester.pump();

      expect(controller.started, isTrue);
      expect(controller.elapsedSeconds, closeTo(6.76, 1e-9));
      expect(find.byKey(kBootBackgroundLayerKey), findsOneWidget);

      await unmountBoot(tester);
      controller.dispose();
    });

    testWidgets('页面临时覆盖注入 controller 的 onHandoff，卸载还原宿主回调', (WidgetTester tester) async {
      useScreen(tester, const Size(1920, 1080));
      final FakeBootClock clock = FakeBootClock();
      final BootController controller = BootController(clock: clock, startOffsetSeconds: 0);
      int hostCalls = 0;
      void hostHandoff(BootHandoff handoff) {
        hostCalls++;
      }

      controller.onHandoff = hostHandoff;
      await pumpBoot(
        tester,
        BootPage(controller: controller, onHandoff: (_) {}),
      );

      clock.setSeconds(35);
      await tester.pump();
      expect(controller.handoff, BootHandoff.detail);
      expect(hostCalls, 0, reason: '页面回调覆盖宿主回调');

      await unmountBoot(tester);
      expect(identical(controller.onHandoff, hostHandoff), isTrue);
      controller.dispose();
    });

    testWidgets('注入 controller 时不被页面 dispose（页面只 dispose 自建 controller）', (WidgetTester tester) async {
      useScreen(tester, const Size(1920, 1080));
      final FakeBootClock clock = FakeBootClock();
      final BootController controller = BootController(clock: clock, startOffsetSeconds: 0);
      await pumpBoot(tester, BootPage(controller: controller));
      await unmountBoot(tester);

      clock.setSeconds(1);
      controller.tick(); // 已卸载：注入的 controller 仍可用（ChangeNotifier 未被 dispose）
      expect(controller.handoff, isNull);
      controller.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // 9) hudBuilder seam 与「不伪造」断言
  // -------------------------------------------------------------------------
  group('hudBuilder seam 与不伪造', () {
    testWidgets('hudBuilder 注入：收到当前 BootFrame，且页面自身只画按钮文字', (WidgetTester tester) async {
      useScreen(tester, const Size(1920, 1080));
      final BootController controller = BootController(clock: FakeBootClock());
      final List<BootStep> seenSteps = <BootStep>[];

      await pumpBoot(
        tester,
        BootPage(
          controller: controller,
          hudBuilder: (BuildContext context, BootFrame frame) {
            seenSteps.add(frame.step);
            return const SizedBox.expand(key: Key('hud.probe'));
          },
        ),
      );

      expect(find.byKey(const Key('hud.probe')), findsOneWidget);
      expect(seenSteps, isNotEmpty);
      expect(seenSteps.first, BootStep.access);

      final List<Text> texts = tester.widgetList<Text>(find.byType(Text)).toList();
      expect(texts.length, 1);
      expect(texts.single.data, kEnterSystemLabel);

      await unmountBoot(tester);
    });

    testWidgets('hudBuilder == null：除按钮 label 外没有任何伪造 glyph/状态文本', (WidgetTester tester) async {
      useScreen(tester, const Size(1920, 1080));
      final FakeBootClock clock = FakeBootClock();
      // 让当前帧落在「本该有 auth 文本」的时间窗内（elapsed 12.76 => time 17.76 => frame 444）
      final BootController controller = BootController(clock: clock, startOffsetSeconds: 0);
      await pumpBoot(tester, BootPage(controller: controller));
      await tester.pump();
      clock.setSeconds(12.76);
      await tester.pump();

      expect(controller.frame.frame, 444.0);
      expect(controller.frame.authLetters, 'START PROCESSING');
      expect(controller.frame.logoLetters, kLogoText);
      expect(controller.frame.poweredLetterCount, 20);

      // 模型里有这些文本，但页面一个字都不许画（真 HUD 层负责 glyph）
      expect(find.textContaining('START PROCESSING'), findsNothing);
      expect(find.textContaining('RHINE'), findsNothing);
      expect(find.textContaining('POWERED'), findsNothing);
      expect(find.textContaining('SING'), findsNothing);
      expect(find.textContaining('ACCESS'), findsNothing);
      expect(find.textContaining('ID CONFIRMED'), findsNothing);

      final List<Text> texts = tester.widgetList<Text>(find.byType(Text)).toList();
      expect(texts.length, 1, reason: '门槛层只允许一个文本：ENTER SYSTEM 按钮标签');
      expect(texts.single.data, kEnterSystemLabel);

      await unmountBoot(tester);
    });

    testWidgets('页面不引入路由（交割只回调 host，控制器不 push）', (WidgetTester tester) async {
      useScreen(tester, const Size(1920, 1080));
      final FakeBootClock clock = FakeBootClock();
      final List<BootHandoff> handoffs = <BootHandoff>[];
      final BootController controller = BootController(clock: clock, startOffsetSeconds: 0);
      await pumpBoot(tester, BootPage(controller: controller, onHandoff: handoffs.add));

      expect(find.byType(Navigator), findsNothing);

      clock.setSeconds(35);
      await tester.pump();
      expect(handoffs, <BootHandoff>[BootHandoff.detail]);
      expect(find.byType(Navigator), findsNothing);

      await unmountBoot(tester);
    });
  });
}
