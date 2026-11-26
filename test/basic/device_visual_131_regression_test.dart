// DEVICE-VISUAL-131 缺陷②③的回归（现象 → 源码机制）。
//
// ② 缺字时 glyphInset 回退整段 advance，整行被左移一个文字宽，只剩裁剪窗口那几像素。
// ③ pathFor 恒返回 null，paint_stack 记 missingPath 并跳过绘制；线上传的是 SVG 路径数据。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';

SirenSong _song(String id, String title) => SirenSong(
      id: id,
      title: title,
      artist: '塞壬唱片',
      album: '专辑',
      albumId: 'album-1',
      cover: '',
      sourceUrl: 'https://example.invalid/$id.mp3',
      lyricUrl: '',
      durationMs: 180000,
    );

/// 真字形表（不用替身）：缺字判定必须来自 Assets/fonts/misans-glyphs.json 的实际情况。
Future<BasicGlyphPorts> _realPorts() async {
  final String glyphJson = await File(basicGlyphTableAsset).readAsString();
  final GlyphFontSet fonts = parseGlyphResources(glyphJson: glyphJson, letteringJson: '{}');
  final GlyphText text = GlyphText.resourceOnly(fonts);
  return BasicGlyphPorts(glyphs: fonts, text: text);
}

List<double> _titleX(BasicHudFrame frame, String title) => frame.commands
    .where((List<Object?> c) => c.length > 2 && c[0] == 'text' && c[1] == title)
    .map((List<Object?> c) => (c[2] as num).toDouble())
    .toList();

void main() {
  test('缺陷②：缺字形不把整行左移（glyphInset 回 0，不是整段 advance）', () async {
    final BasicGlyphPorts ports = await _realPorts();
    // 触发条件依然存在：缺轮廓的文本让 GlyphText.inset 抛 StateError（glyph_run.dart:249/261/275）。
    expect(() => ports.text.inset('月', 40, weight: 'bold'), throwsStateError);
    // 修复点：与 Qt Glyphs::inset 一样回 0。
    expect(ports.glyphInset('月', 40, 'bold'), 0);
    // 旧回退值（整段 advance）确实是正的——这就是当初整行被左移的位移量。
    expect(ports.glyphWidth('月', 40, 'bold'), greaterThan(0));
    // 有轮廓的字仍然给出真实 inset，不能被顺手改成 0。
    expect(ports.glyphInset('光', 40, 'bold'), greaterThan(0));
  });

  test('缺陷②：含缺字歌名与全轮廓歌名在同一行左边界对齐', () async {
    final BasicGlyphPorts ports = await _realPorts();
    final BasicHudFrame frame = BasicHudFrame.build(
      state: BasicViewState(
        phase: BasicPhase.library,
        songs: <SirenSong>[_song('s1', '月光'), _song('s2', '光束')],
        catalogLoaded: true,
        dark: true,
      ),
      ports: ports,
      width: 1920,
      height: 1080,
      portrait: false,
    );
    final List<double> missing = _titleX(frame, '月光');
    final List<double> covered = _titleX(frame, '光束');
    expect(missing, isNotEmpty, reason: '缺字标题必须画出来，不能因为缺轮廓被丢弃');
    expect(covered, isNotEmpty);
    // 左边界只差字形自身的左边距（1.12px 量级的 bearing），不是整段 advance（≈40px）。
    expect((missing.first - covered.first).abs(), lessThan(5),
        reason: '缺字不能把整行左移一个文字宽（旧实现是 advance 量级）');
    expect(missing.first, greaterThan(960), reason: '标题应落在右栏列表列，而不是被左移出屏');
  });

  test('缺陷③：pathFor 解析线上 SVG 路径数据（不再是恒 null）', () async {
    final BasicGlyphPorts ports = await _realPorts();
    // Qt PlayerBar 真实图标串（与 lib/hud/player/player_bar.dart:205 的 _playPath 同形）。
    final ui.Path? play = ports.pathFor('M -5 -10 L 9 0 L -5 10 Z');
    expect(play, isNotNull);
    final ui.Rect bounds = play!.getBounds();
    expect(bounds.width, closeTo(14, 0.01));
    expect(bounds.height, closeTo(20, 0.01));
    // 空 key 仍然回 null（paint_stack 的 missingPath 只对真正的空路径生效）。
    expect(ports.pathFor(''), isNull);
  });
}
