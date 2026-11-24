/// 精确命中优先于触摸外扩（用户 2026-11-24 报「横屏底栏按钮点了没反应」的回归锁）。
///
/// 横屏播放条上「词」与「MV」两个 48 宽的键中心只隔 55，而 Android 的触摸外扩
/// `pad = 16` 让两个键的外扩区互相侵入 25 单位；`hitAt` 原本「最后一个胜出」，
/// 于是点「词」的右半格打开 MV。修法是把 [HitLayer.hitAt] 拆成两趟：
/// 先只认**源矩形**（仍最后一个胜出），一个都没有才退回外扩矩形。
///
/// 这里同时锁住两件事：精确命中必须叠加 modalOffset（弹层里的条目按滚动量位移，
/// 用未位移的 y 去比对会命中到屏幕别处——同一处改动引入过的回归）。
library;

import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/input/hit_layer.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';

HudHit _hit(double x, double y, double width, double height, String action) => HudHit(
      x: x,
      y: y,
      width: width,
      height: height,
      action: action,
      label: action,
    );

void main() {
  // logicalHeight = 1080 ⇒ stageScale = 1，stage 坐标与逻辑坐标同值。
  const StageGeometry unit = StageGeometry(logicalWidth: 1080, logicalHeight: 1080);
  final HitLayer android = HitLayer(geometry: unit, android: true);
  final HitLayer ios = HitLayer(geometry: unit, android: false);

  final HudHit lyrics = _hit(0, 0, 48, 48, 'player:lyrics');
  final HudHit mv = _hit(55, 0, 48, 48, 'player:mv');

  test('an exact source rect beats a later neighbour\'s expanded spillover', () {
    // 45 在「词」的源矩形里（0..48），同时也在「MV」的外扩区里（39..119）。
    expect(android.hitAt(<HudHit>[lyrics, mv], const Offset(45, 20)), lyrics);
  });

  test('a point outside both source rects still falls back to the last expanded', () {
    // 52 落在两个源矩形之间（48..55），只能靠外扩命中；仍是「最后一个胜出」。
    expect(android.hitAt(<HudHit>[lyrics, mv], const Offset(52, 20)), mv);
  });

  test('a tiny source rect keeps its touch expansion when nothing else contains the point', () {
    final HudHit tiny = _hit(30, 0, 0.5, 0.5, 'music:tiny');
    expect(android.hitAt(<HudHit>[tiny], const Offset(38, 8)), tiny);
    expect(ios.hitAt(<HudHit>[tiny], const Offset(38, 8)), isNull);
  });

  test('the exact pass honours modalOffset like the expanded pass', () {
    final HitLayer modal = HitLayer(
      geometry: unit,
      android: true,
      modal: 'queue',
      modalOffset: -300,
    );
    final HudHit row = _hit(0, 300, 100, 48, 'player:queue:0');
    // offsetY = 300 - 300 = 0 ⇒ 屏幕上的矩形是 (0,0,100,48)。
    expect(modal.hitAt(<HudHit>[row], const Offset(50, 24)), row);
    // 未位移的 y=324 处不该命中同一行。
    expect(modal.hitAt(<HudHit>[row], const Offset(50, 324)), isNull);
  });

  test('a fixed hit ignores modalOffset on both passes', () {
    final HitLayer modal = HitLayer(
      geometry: unit,
      android: true,
      modal: 'queue',
      modalOffset: -300,
    );
    final HudHit fixed = HudHit(
      x: 0,
      y: 300,
      width: 100,
      height: 48,
      action: 'player:open',
      label: 'player:open',
      fixed: true,
    );
    expect(modal.hitAt(<HudHit>[fixed], const Offset(50, 324)), fixed);
    expect(modal.hitAt(<HudHit>[fixed], const Offset(50, 24)), isNull);
  });
}
