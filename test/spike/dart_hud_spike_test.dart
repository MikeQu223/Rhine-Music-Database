// T13-S05 companion：Dart HUD spike 的静态/单元断言（authored only，未执行）。
//
// 未执行声明（用户禁令：本 atom 禁止 flutter build/test/analyze、dart test/analyze、
// Gradle/gradlew、pub get、formatter、generator、golden、Qt 编译、adb、装包与任何
// 验证脚本）：本文件的每一行断言在本原子内**一次都没跑过**。RED 未验证 / GREEN 未验证；
// 结论只能来自静态阅读。不要在任何报告或对话里写成「测试通过」。
//
// 本文件锁定的契约：
//   1. 17 个 op 的名称/顺序/索引语义来自生产协议
//      lib/hud/protocol/hud_command.dart（hudKnownOperationNames:399-417，
//      HudCommand.index:11-16，decodeHudCommands:428-471）；
//   2. 每条 op 的字段名与索引位置来自 _decodeOne:473 起的 wire 布局
//      （Qt/src/Glyphs.cpp:637-829 是同一份布局的 Qt 侧权威）；
//   3. 状态机（save/restore/alpha/clip/transform）复刻
//      lib/hud/render/paint_stack.dart 的 HudPaintStateStack 语义
//      （save/restore 配对、alpha 乘性累计、clip 交集）；
//   4. glyph 加载器的 fail-closed：缺文件/坏 JSON 只报告，不抛、不合成 outline；
//   5. 四页命令流由生产构建器产出（archive_page / song_detail / search_results /
//      queue_modal），probe 只做字段搬运，不自绘。
//
// 依赖：本文件只 import 生产协议与 lib/spike/dart_hud/**，不碰 lib/main.dart、
// lib/hud/render/hud_painter.dart、pubspec.yaml。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/protocol/hud_command.dart';
import 'package:rhine_music_database/spike/dart_hud/archive_probe.dart';
import 'package:rhine_music_database/spike/dart_hud/glyph_loader.dart';
import 'package:rhine_music_database/spike/dart_hud/hud_painter.dart';

/// 仓库根：从当前目录向上找 Assets/fonts/misans-glyphs.json（最多 6 层）。
String _repoRoot() {
  Directory directory = Directory.current;
  for (int depth = 0; depth < 6; depth += 1) {
    final File probe = File('${directory.path}/Assets/fonts/misans-glyphs.json');
    if (probe.existsSync()) {
      return directory.path;
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      break;
    }
    directory = parent;
  }
  return Directory.current.path;
}

/// 一条 op 一份合法 wire 数组，顺序必须与 hudKnownOperationNames 一致。
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

/// 17 个 op 的 arguments 键集合（字段名与 _decodeOne 的 getter 同名）。
const Map<String, Set<String>> _expectedArgumentKeys = <String, Set<String>>{
  'save': <String>{},
  'restore': <String>{},
  'alpha': <String>{'value'},
  'translate': <String>{'x', 'y'},
  'scale': <String>{'sx', 'sy'},
  'rotate': <String>{'radians'},
  'clip': <String>{'x', 'y', 'width', 'height'},
  'fill': <String>{'color', 'x', 'y', 'width', 'height'},
  'ellipse': <String>{'color', 'x', 'y', 'width', 'height'},
  'text': <String>{'value', 'x', 'y', 'size', 'weight', 'tracking', 'color'},
  'art': <String>{'key', 'x', 'y', 'size', 'count', 'tracking', 'color'},
  'fill-path': <String>{'key', 'color'},
  'path': <String>{'key', 'penWidth', 'color', 'dashPattern', 'dashOffset'},
  'arc': <String>{'cx', 'cy', 'radius', 'start', 'sweep', 'penWidth', 'color'},
  'right-mask': <String>{'color', 'start', 'span', 'right', 'height'},
  'gradient': <String>{'dark'},
  'image': <String>{'key', 'x', 'y', 'width', 'height'},
};

void main() {
  group('1) 17 ops 表与生产协议一致', () {
    test('名称、顺序、总数与 hudKnownOperationNames 相同', () {
      expect(kSpikeHudOperationNames, hasLength(kSpikeHudOperationCount));
      expect(kSpikeHudOperationCount, 17);
      expect(kSpikeHudOperationNames.toSet(), hudKnownOperationNames);
      for (int i = 0; i < kSpikeHudOperationNames.length; i += 1) {
        expect(hudKnownOperationNames.contains(kSpikeHudOperationNames[i]), isTrue,
            reason: 'op ${kSpikeHudOperationNames[i]} 不在生产协议里');
      }
      // hudKnownOperationNames 是 Set；顺序真值来自 decode 的 wire 布局。
      expect(_expectedArgumentKeys.keys.toSet(), hudKnownOperationNames);
    });

    test('wire 布局逐 op 解码成对应 HudCommand 子类，index 等于数组下标', () {
      final HudCommandDecode decode = decodeHudCommands(<Object?>[
        for (final List<Object?> command in _seventeenOpWire()) command,
      ]);
      expect(decode.issues, isEmpty);
      expect(decode.commands, hasLength(17));
      for (int i = 0; i < decode.commands.length; i += 1) {
        expect(decode.commands[i].index, i, reason: 'op ${kSpikeHudOperationNames[i]} 的 wire index');
      }
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
    });

    test('解码后的字段逐条等于 wire 输入（不发明、不重排）', () {
      final HudCommandDecode decode = decodeHudCommands(<Object?>[..._seventeenOpWire()]);
      final List<HudCommand> commands = decode.commands;
      expect((commands[2] as HudAlpha).value, 0.5);
      expect((commands[3] as HudTranslate).x, 10.0);
      expect((commands[3] as HudTranslate).y, 20.0);
      expect((commands[4] as HudScale).sx, 2.0);
      expect((commands[5] as HudRotate).radians, 0.25);
      expect((commands[7] as HudFill).width, 7.0);
      expect((commands[8] as HudEllipse).height, 12.0);
      expect((commands[9] as HudText).weight, 'regular');
      expect((commands[10] as HudArt).count, 4);
      expect((commands[12] as HudStrokePath).dashPattern, <double>[4.0, 2.0]);
      expect((commands[13] as HudArc).penWidth, 2.4);
      expect((commands[14] as HudRightMask).height, 984.0);
      expect((commands[15] as HudGradient).dark, isTrue);
      expect((commands[16] as HudImage).key, 'img:key');
    });
  });

  group('2) 执行器：17 op 的记录与状态机', () {
    test('每条 op 一条记录，operation/arguments 与协议字段一一对应', () {
      final HudCommandDecode decode = decodeHudCommands(<Object?>[..._seventeenOpWire()]);
      final SpikeHudExecution execution = executeSpikeHudCommands(decode.commands);
      expect(execution.records, hasLength(17));
      expect(execution.issues, isEmpty);
      expect(execution.openFrames, 0);
      expect(execution.balanced, isTrue);
      for (int i = 0; i < execution.records.length; i += 1) {
        final SpikeHudRecord record = execution.records[i];
        expect(record.index, i);
        expect(record.sequence, i);
        expect(record.operation, kSpikeHudOperationNames[i]);
        expect(record.arguments.keys.toSet(), _expectedArgumentKeys[record.operation],
            reason: 'op ${record.operation} 的字段集合');
      }
      expect(execution.operationSequence, kSpikeHudOperationNames);
    });

    test('save/restore 配对、alpha 乘性累计、translate/scale/rotate 组成矩阵', () {
      final SpikeHudExecution execution = executeSpikeHudCommands(<HudCommand>[
        const HudSave(0),
        const HudAlpha(1, 0.5),
        const HudTranslate(2, 10, 20),
        const HudScale(3, 2, 3),
        const HudFill(4, HudColor(1, 0, 0, 1), 0, 0, 10, 10),
        const HudRestore(5),
        const HudFill(6, HudColor(0, 0, 1, 1), 0, 0, 10, 10),
      ]);
      expect(execution.issues, isEmpty);
      expect(execution.balanced, isTrue);
      final SpikeHudRecord inside = execution.records[4];
      expect(inside.opacity, 0.5);
      expect(inside.saveDepth, 1);
      // x' = 2x + 10, y' = 3y + 20（translate 后 scale，作用点按矩阵累计）。
      final List<double> point = inside.transform.apply(1, 1);
      expect(point[0], 12.0);
      expect(point[1], 23.0);
      final SpikeHudRecord afterRestore = execution.records[6];
      expect(afterRestore.opacity, 1.0);
      expect(afterRestore.saveDepth, 0);
      final List<double> identityPoint = afterRestore.transform.apply(1, 1);
      expect(identityPoint[0], 1.0);
      expect(identityPoint[1], 1.0);
    });

    test('clip 取交集（负宽高归一化），restore 恢复外层 clip', () {
      final SpikeHudExecution execution = executeSpikeHudCommands(<HudCommand>[
        const HudClip(0, 10, 20, 100, 200),
        const HudSave(1),
        const HudClip(2, 50, 0, 100, 100),
        const HudFill(3, HudColor(1, 1, 1, 1), 0, 0, 1, 1),
        const HudRestore(4),
        const HudFill(5, HudColor(1, 1, 1, 1), 0, 0, 1, 1),
      ]);
      final SpikeHudRecord inner = execution.records[3];
      expect(inner.clip, isNotNull);
      expect(inner.clip!.left, 50.0);
      expect(inner.clip!.top, 20.0);
      expect(inner.clip!.right, 110.0);
      expect(inner.clip!.bottom, 100.0);
      final SpikeHudRecord outer = execution.records[5];
      expect(outer.clip!.left, 10.0);
      expect(outer.clip!.right, 110.0);
      expect(outer.clip!.bottom, 220.0);
    });

    test('不配对的 restore 记 unbalancedRestore，结尾未闭合 save 记 unbalancedSave', () {
      final SpikeHudExecution stray = executeSpikeHudCommands(<HudCommand>[
        const HudRestore(0),
        const HudFill(1, HudColor(0, 0, 0, 1), 0, 0, 1, 1),
      ]);
      expect(stray.issues, hasLength(1));
      expect(stray.issues.single.kind, 'unbalancedRestore');
      expect(stray.issues.single.index, 0);
      expect(stray.balanced, isFalse);

      final SpikeHudExecution open = executeSpikeHudCommands(<HudCommand>[
        const HudSave(0),
        const HudFill(1, HudColor(0, 0, 0, 1), 0, 0, 1, 1),
      ]);
      expect(open.openFrames, 1);
      expect(open.issues.single.kind, 'unbalancedSave');
      expect(open.issues.single.index, -1);
      expect(open.balanced, isFalse);
    });

    test('颜色在记录里被摊平成 0..1 RGBA，calibrated 与解码同路径', () {
      final HudColor color = decodeHudColor(<Object?>[0.92, 0.92, 0.92, 0.4, 'calibratedWhite']);
      expect(color.red, closeTo(hudCalibratedChannel(0.92), 1e-12));
      expect(color.alpha, 0.4);
      expect(spikeColorWire(color), <double>[color.red, color.green, color.blue, 0.4]);
    });
  });

  group('3) glyph 加载器', () {
    test('仓库内 atlas 可解析：四 weight、路径非空、advance 非负', () {
      final GlyphLoadResult glyphs = loadSpikeGlyphs(root: _repoRoot());
      expect(glyphs.errors, isEmpty, reason: 'atlas 结构问题：${glyphs.errors}');
      expect(glyphs.missingFiles, isEmpty, reason: '缺文件：${glyphs.missingFiles}');
      expect(glyphs.weights.keys.toSet(), kGlyphWeightNames.toSet());
      expect(glyphs.paintable, isTrue);
      expect(glyphs.glyphCount, greaterThan(3000));
      expect(glyphs.coverage.keys.toSet(), kGlyphWeightNames.toSet());
      final GlyphWeight regular = glyphs.weights['regular']!;
      expect(regular.units, 1000);
      expect(regular.ascent, greaterThan(0));
      expect(regular.descent, lessThan(0));
      for (final GlyphEntry entry in regular.glyphs.values.take(64)) {
        expect(entry.path, isNotEmpty);
        expect(entry.advance, greaterThanOrEqualTo(0));
      }
    });

    test('缺文件 fail-closed：不抛、paintable=false、missingFiles 覆盖全部探测路径', () {
      final GlyphLoadResult glyphs = loadSpikeGlyphs(root: '/nonexistent-T13-spike-root');
      expect(glyphs.paintable, isFalse);
      expect(glyphs.weights, isEmpty);
      expect(glyphs.glyphCount, 0);
      expect(glyphs.missingFiles, hasLength(1 + kGlyphFontRelativePaths.length + 1));
      expect(glyphs.missingFiles.any((String p) => p.endsWith(kGlyphAtlasRelativePath)), isTrue);
      expect(glyphs.missingFiles.any((String p) => p.endsWith(kMusicFontsVersionRelativePath)), isTrue);
      expect(glyphs.fallbackGaps('青花瓷')['regular'], <String>['青', '花', '瓷']);
    });
  });

  group('4) 四页命令流（生产构建器 + probe 搬运）', () {
    late GlyphLoadResult glyphs;
    late Map<SlicePage, PageCommandStream> streams;

    setUpAll(() {
      glyphs = loadSpikeGlyphs(root: _repoRoot());
      streams = buildSlicePageStreams(const SliceState(), glyphs: glyphs);
    });

    test('四页都有非空、可解码、零 issue 的命令流', () {
      expect(streams.keys.toSet(), SlicePage.values.toSet());
      for (final SlicePage page in SlicePage.values) {
        final PageCommandStream stream = streams[page]!;
        expect(stream.page, page);
        expect(stream.wire, isNotEmpty, reason: '$page 没有命令');
        expect(stream.issues, isEmpty, reason: '$page 解码 issue：${stream.issues}');
        expect(stream.decoded, hasLength(stream.wire.length));
        expect(stream.operations.every(hudKnownOperationNames.contains), isTrue);
        final SpikeHudExecution execution = stream.execution;
        expect(execution.records, hasLength(stream.decoded.length));
      }
    });

    test('archive 页至少有 fill + text（chrome 由生产 HudArchivePage 发出）', () {
      final PageCommandStream stream = streams[SlicePage.archive]!;
      expect(stream.operations, contains('fill'));
      expect(stream.operations, contains('text'));
      expect(stream.hits, isNotEmpty);
    });

    test('detail 页至少有 text，且首帧是生产 SongDetail builder 的 save 帧', () {
      final PageCommandStream stream = streams[SlicePage.detail]!;
      expect(stream.operations, contains('text'));
      expect(stream.decoded.first, isA<HudSave>());
      expect(stream.execution.recordsOf('text'), isNotEmpty);
      expect(stream.hits, isNotEmpty);
    });

    test('search 页有 toolbar/footer 的 text 与结果层的 clip 帧', () {
      final PageCommandStream stream = streams[SlicePage.search]!;
      expect(stream.operations, contains('text'));
      expect(stream.operations, contains('clip'));
      expect(stream.operations, contains('fill'));
      expect(stream.execution.recordsOf('clip'), isNotEmpty);
      expect(stream.hits, isNotEmpty);
    });

    test('queue 页至少有 fill + text（生产 QueueModal 发出）', () {
      final PageCommandStream stream = streams[SlicePage.queue]!;
      expect(stream.operations, contains('fill'));
      expect(stream.operations, contains('text'));
      expect(stream.hits, isNotEmpty);
    });

    test('同一 SliceState 是幂等的：两次构建的 wire 完全相同', () {
      final Map<SlicePage, PageCommandStream> again =
          buildSlicePageStreams(const SliceState(), glyphs: glyphs);
      for (final SlicePage page in SlicePage.values) {
        expect(again[page]!.wire, streams[page]!.wire, reason: '$page 非确定性');
      }
    });
  });
}
