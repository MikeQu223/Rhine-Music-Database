// Dart HUD spike 的切片级集成断言。当前无法在设备上运行，原因有三。
//
// 1. NativeSceneFrame/scene_surface 的 Dart 侧宿主尚未落地，spike 未接进
//    lib/main.dart，也没有可 pump 的页面；本文件只验证数据面（命令流），
//    不做首帧/黑屏的视觉断言 —— 因此它不会把静态首帧或黑屏当作通过。
// 2. glyph 加载器按仓库相对路径用 dart:io 读取 Assets/fonts/**（不接生产字体、
//    不改 pubspec）；设备沙箱里没有该目录，加载结果必须是 fail-closed
//    （paintable=false + missingFiles），本文件按此断言，不伪造通过。
// 3. 设备运行命令（flutter test integration_test/... -d <device>）需由装配方
//    在宿主接线后执行。
//
// 契约来源：
//   - 17 op 名称/索引：lib/hud/protocol/hud_command.dart:399-417、:11-16、
//     decodeHudCommands:428-471（Qt/src/Glyphs.cpp:637-829）；
//   - 四页命令：archive_page.dart:223（archive）、song_detail.dart:663
//     （renderSongDetail）、search_modal.dart（toolbar/footer 布局）+
//     search_results.dart（SearchResultsLayer.draw）、queue_modal.dart（renderQueueModal）；
//   - slice 输入：docs/flutter-migration/01-slice.md（width=1728、libraryIndex=16、
//     query/keyword=青花瓷、dark 基线）。
//
// 本文件只 import 生产协议与 lib/spike/dart_hud/**；不写 lib/main.dart、pubspec.yaml。

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rhine_music_database/hud/protocol/hud_command.dart';
import 'package:rhine_music_database/spike/dart_hud/archive_probe.dart';
import 'package:rhine_music_database/spike/dart_hud/glyph_loader.dart';

/// 17 op 的最小合法 wire 数组（顺序 = hudKnownOperationNames 的 wire 布局）。
List<List<Object?>> _seventeenOpWire() => <List<Object?>>[
      <Object?>['save'],
      <Object?>['restore'],
      <Object?>['alpha', 0.5],
      <Object?>['translate', 10.0, 20.0],
      <Object?>['scale', 2.0, 3.0],
      <Object?>['rotate', 0.25],
      <Object?>['clip', 1.0, 2.0, 3.0, 4.0],
      <Object?>['fill', <Object?>[1.0, 0.0, 0.0, 1.0], 5.0, 6.0, 7.0, 8.0],
      <Object?>['ellipse', <Object?>[0.0, 1.0, 0.0, 1.0], 9.0, 10.0, 11.0, 12.0],
      <Object?>['text', 'A', 13.0, 14.0, 15.0, 'regular', 1.5, <Object?>[1.0, 1.0, 1.0, 1.0]],
      <Object?>['art', 'glyph:key', 16.0, 17.0, 18.0, 4, 1.5, <Object?>[1.0, 1.0, 1.0, 1.0]],
      <Object?>['fill-path', 'path:fill', <Object?>[1.0, 1.0, 1.0, 1.0]],
      <Object?>['path', 'path:stroke', 2.4, <Object?>[1.0, 1.0, 1.0, 1.0], <Object?>[4.0, 2.0], 0.5],
      <Object?>['arc', 960.0, 540.0, 300.0, 1.57, 3.14, 2.4, <Object?>[1.0, 1.0, 1.0, 1.0]],
      <Object?>['right-mask', <Object?>[0.0, 0.0, 0.0, 1.0], 100.0, 200.0, 500.0, 984.0],
      <Object?>['gradient', true],
      <Object?>['image', 'img:key', 1.0, 2.0, 300.0, 400.0],
    ];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('T13-S05 设备数据面（不含视觉断言）', () {
    test('17 op 的 wire index 与协议顺序逐条一致', () {
      final HudCommandDecode decode = decodeHudCommands(<Object?>[..._seventeenOpWire()]);
      expect(decode.issues, isEmpty);
      expect(decode.commands, hasLength(17));
      expect(decode.commands.map((HudCommand c) => c.runtimeType.toString()).toList(), <String>[
        'HudSave',
        'HudRestore',
        'HudAlpha',
        'HudTranslate',
        'HudScale',
        'HudRotate',
        'HudClip',
        'HudFill',
        'HudEllipse',
        'HudText',
        'HudArt',
        'HudFillPath',
        'HudStrokePath',
        'HudArc',
        'HudRightMask',
        'HudGradient',
        'HudImage',
      ]);
      for (int i = 0; i < decode.commands.length; i += 1) {
        expect(decode.commands[i].index, i);
      }
    });

    test('glyph 在设备沙箱必须 fail-closed（不伪造 paintable）', () {
      // 仓库相对路径在设备上不存在：结果只允许「结构化缺失」，不允许抛异常。
      final GlyphLoadResult glyphs = loadSpikeGlyphs();
      expect(glyphs.paintable, isFalse);
      expect(glyphs.missingFiles, isNotEmpty);
      expect(glyphs.glyphCount, 0);

      // 显式缺根：仍不抛，且 missingFiles 覆盖 atlas + 5 字体 + version。
      final GlyphLoadResult missing = loadSpikeGlyphs(root: '/nonexistent-T13-device-root');
      expect(missing.paintable, isFalse);
      expect(missing.missingFiles, hasLength(1 + kGlyphFontRelativePaths.length + 1));
      expect(missing.errors, isEmpty);
    });

    test('四页命令流可产出、可解码、无未知 op（切片 S1/S2/S4/S7 输入）', () {
      final GlyphLoadResult glyphs = loadSpikeGlyphs();
      final Map<SlicePage, PageCommandStream> streams =
          buildSlicePageStreams(const SliceState(), glyphs: glyphs);
      expect(streams.keys.toSet(), SlicePage.values.toSet());
      for (final SlicePage page in SlicePage.values) {
        final PageCommandStream stream = streams[page]!;
        expect(stream.wire, isNotEmpty, reason: '${page} 在设备上必须产出命令');
        expect(stream.issues, isEmpty, reason: '${page} 解码 issue：${stream.issues}');
        expect(stream.decoded, hasLength(stream.wire.length));
        expect(stream.operations.every(hudKnownOperationNames.contains), isTrue);
        expect(stream.execution.records, hasLength(stream.decoded.length));
      }
    });

    test('四页各自的最小可断言序列（不是视觉 PASS）', () {
      final Map<SlicePage, PageCommandStream> streams = buildSlicePageStreams(
        const SliceState(),
        glyphs: loadSpikeGlyphs(),
      );
      expect(streams[SlicePage.archive]!.operations, containsAll(<String>['fill', 'text']));
      expect(streams[SlicePage.detail]!.operations, contains('text'));
      expect(streams[SlicePage.detail]!.decoded.first, isA<HudSave>());
      expect(streams[SlicePage.search]!.operations, containsAll(<String>['fill', 'text', 'clip']));
      expect(streams[SlicePage.queue]!.operations, containsAll(<String>['fill', 'text']));
      // 命中区域是命令流的伴随产物，四页都必须给出（否则点击面为空）。
      for (final SlicePage page in SlicePage.values) {
        expect(streams[page]!.hits, isNotEmpty, reason: '${page} 无命中');
      }
    });
  });
}
