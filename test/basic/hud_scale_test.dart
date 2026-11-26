// DPI 适配（lib/hud/scale/hud_scale.dart）的数值契约。
//
// 竖屏 1 网格 = clamp(逻辑宽/393, 0.9, 1.3) dp；横屏跟随屏幕尺寸（基准 762dp / 1080）。
// 只钉纯函数与画布单位，渲染路径由 ui_portrait_test 的命中测试覆盖。

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/hud/portrait/portrait_layout.dart';
import 'package:rhine_music_database/hud/scale/hud_scale.dart';

void main() {
  group('HudScale 竖屏网格 dp 带', () {
    test('基准机（762dp 宽）被夹到 1.3dp/网格', () {
      expect(HudScale.gridDp(762), closeTo(1.3, 1e-9));
    });

    test('参考图那台（419dp 宽）不需要夹，仍是自然值', () {
      expect(HudScale.gridDp(419), closeTo(419 / 393, 1e-9));
    });

    test('窄屏（320dp 宽）被抬到 0.9dp 下限', () {
      expect(HudScale.gridDp(320), closeTo(0.9, 1e-9));
    });

    test('非法输入退回 1.0dp，不抛异常', () {
      expect(HudScale.gridDp(double.nan), 1.0);
      expect(HudScale.gridDp(0), 1.0);
      expect(HudScale.gridDp(-10), 1.0);
    });
  });

  group('HudScale 竖屏压缩系数', () {
    test('基准机压到 1.3dp（系数 1.3 / (762/393)）', () {
      // 竖屏舞台宽恒 1080，stageScale = 762/1080。
      final double stageScale = 762 / HudScale.designStageHeight;
      expect(
        HudScale.portraitUnitFactor(stageScale),
        closeTo(1.3 / (762 / 393), 1e-9),
      );
    });

    test('419dp 宽（参考机）系数为 1：与 Qt 的「铺满宽度」逐像素一致', () {
      final double stageScale = 419 / HudScale.designStageHeight;
      expect(HudScale.portraitUnitFactor(stageScale), closeTo(1.0, 1e-9));
    });

    test('窄屏不放大（系数仍为 1），避免内容被裁切', () {
      final double stageScale = 320 / HudScale.designStageHeight;
      expect(HudScale.portraitUnitFactor(stageScale), closeTo(1.0, 1e-9));
    });

    test('缺省/非法 stageScale 视为不压缩', () {
      expect(HudScale.portraitUnitFactor(0), 1.0);
      expect(HudScale.portraitUnitFactor(double.infinity), 1.0);
    });
  });

  group('竖屏画布单位与网格宽度', () {
    test('基准机：1 网格 = 1.3dp，页宽铺满 1080 舞台（约 586 网格）', () {
      const double stageWidth = HudScale.designStageHeight; // 竖屏舞台宽恒 1080
      final double stageScale = 762 / HudScale.designStageHeight;
      final double unit = HudScale.portraitUnit(stageWidth, stageScale);
      final double gridWidth = HudScale.portraitGridWidth(stageWidth, stageScale);

      // 1 网格 = unit × stageScale dp，正好落在上限 1.3dp。
      expect(unit * stageScale, closeTo(1.3, 1e-9));
      // 页宽 × unit = 舞台宽：页面铺满，没有居中留白。
      expect(gridWidth * unit, closeTo(stageWidth, 1e-9));
      expect(gridWidth, greaterThan(HudScale.designGridWidth));
    });

    test('参考机（419dp）：无压缩，页宽就是 393 网格，与 Qt 一致', () {
      const double stageWidth = HudScale.designStageHeight;
      final double stageScale = 419 / HudScale.designStageHeight;
      expect(HudScale.portraitUnit(stageWidth, stageScale), closeTo(stageWidth / 393, 1e-9));
      expect(HudScale.portraitGridWidth(stageWidth, stageScale), closeTo(393, 1e-9));
    });

    test('本机（762dp）：网格压到 1.3dp，页宽铺满到 586 网格', () {
      const double stageWidth = HudScale.designStageHeight;
      final double stageScale = 762 / HudScale.designStageHeight;
      final double unit = HudScale.portraitUnit(stageWidth, stageScale);
      // 1 网格 = unit × stageScale dp = 1.3dp
      expect(unit * stageScale, closeTo(HudScale.maxGridDp, 1e-9));
      // 页宽 = 舞台宽 / unit，正好铺满（不留空边）
      expect(HudScale.portraitGridWidth(stageWidth, stageScale) * unit,
          closeTo(stageWidth, 1e-9));
      expect(HudScale.portraitGridWidth(stageWidth, stageScale), closeTo(586, 1));
    });

    test('portrait_layout 的包装函数与 HudScale 同步', () {
      final double stageScale = 762 / HudScale.designStageHeight;
      expect(portraitUnit(1080, stageScale: stageScale),
          closeTo(HudScale.portraitUnit(1080, stageScale), 1e-12));
      expect(portraitGridWidth(1080, stageScale: stageScale),
          closeTo(HudScale.portraitGridWidth(1080, stageScale), 1e-12));
      // 不传 stageScale 时退回「铺满宽度」的旧口径（测试/离屏调用点）。
      expect(portraitUnit(1080), closeTo(1080 / 393, 1e-12));
      expect(portraitGridWidth(1080), closeTo(393, 1e-12));
    });
  });

  group('横屏 scale（线性，等同 Qt 视口口径）', () {
    test('基准机 762dp 逻辑高保持 0.7056（已验收的横屏像素不变）', () {
      expect(HudScale.landscapeStageScale(762), closeTo(762 / 1080, 1e-12));
    });

    test('大窗口按同一比例线性放大（不夹带）', () {
      expect(HudScale.landscapeStageScale(2400), closeTo(2400 / 1080, 1e-12));
    });

    test('小窗口按同一比例线性缩小（不夹带）', () {
      expect(HudScale.landscapeStageScale(600), closeTo(600 / 1080, 1e-12));
    });
  });

  group('竖屏命中与绘制共用同一套网格宽度', () {
    test('listTop 行的命中带横向铺满舞台', () {
      const double width = 1080;
      final double stageScale = 762 / HudScale.designStageHeight;
      final double unit = portraitUnit(width, stageScale: stageScale);
      final double gridWidth = portraitGridWidth(width, stageScale: stageScale);
      final Rect band = basicLibraryListStageRect(
        portrait: true,
        width: width,
        height: 1728,
        stageScale: stageScale,
      );
      // 左边界 0、宽度 = gridWidth × unit = 舞台宽（元素变小、页面铺满）。
      expect(band.left, closeTo(0, 1e-9));
      expect(band.width, closeTo(gridWidth * unit, 1e-9));
      // 命中带右缘不超出舞台。
      expect(math.max(band.right, width), width);
    });
  });
}
