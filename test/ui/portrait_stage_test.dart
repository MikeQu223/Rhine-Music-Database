/// T43 竖屏舞台几何的静态断言。
///
/// 这些测试按本阶段契约只做「编写」与静态审阅，不执行（禁止 flutter test /
/// dart test / analyze）。每条断言都指向可查的 Qt 源码或 fixture 键。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/ui/layout/portrait_bands.dart';
import 'package:rhine_music_database/ui/layout/portrait_stage.dart';

const double kTol = 1e-6;
const String kBaseline = '8ed3067b0812eb2612f7841ec127a6e8ca93231b';

Map<String, Object?> asMap(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map((Object? key, Object? v) => MapEntry<String, Object?>(key.toString(), v));
  }
  throw StateError('expected a map, got ' + value.toString());
}

double asDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.parse(value);
  }
  throw StateError('expected a number, got ' + value.toString());
}

List<Map<String, Object?>> asMapList(Object? value) {
  if (value is! List) {
    throw StateError('expected a list, got ' + value.toString());
  }
  return value.map(asMap).toList();
}

final RegExp _numberPattern = RegExp(r'-?\d+(?:\.\d+)?');

const List<String> _rectPlaceholders = <String>[
  '同上',
  '内部',
  '…',
  'undefined',
  '—',
  'card 右',
  'actionBlock',
  '主行',
  '次行',
  'SongDetailCard',
  'control',
  'rect',
  'Button',
  'Width=',
];

int _numberCount(Object? value) => _numberPattern.allMatches(value.toString()).length;

bool _hasRectPlaceholder(Object? value) => _rectPlaceholders.any((String token) => value.toString().contains(token));

Map<String, Object?> loadFixture() {
  final File file = File('test/fixtures/portrait_bands.json');
  if (!file.existsSync()) {
    throw StateError('missing fixture: ' + file.path);
  }
  return asMap(jsonDecode(file.readAsStringSync()));
}

Widget host({
  required Size surface,
  required Widget child,
  EdgeInsets padding = EdgeInsets.zero,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) =>
    MediaQuery(
      data: MediaQueryData(
        size: surface,
        padding: padding,
        viewInsets: viewInsets,
        devicePixelRatio: 1.0,
      ),
      child: Directionality(textDirection: TextDirection.ltr, child: child),
    );

class _NullContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('fixture', () {
    test('declares its schema, tolerance and baseline', () {
      final Map<String, Object?> fixture = loadFixture();
      expect(fixture['schema'], 'portrait-bands/v1');
      expect(asDouble(fixture['tolerance']), kTol);
      expect(fixture['baseline'], kBaseline);
    });

    test('records the player input band as 978/102 with bottom 1080', () {
      final Map<String, Object?> fixture = loadFixture();
      final Map<String, Object?> geometry = asMap(fixture['geometry']);
      final Map<String, Object?> input = asMap(geometry['playerInputBounds']);
      expect(asDouble(input['top']), 978);
      expect(asDouble(input['height']), 102);
      expect(asDouble(input['bottom']), 1080);
      expect(asDouble(input['height']), QtStageGeometry.stageHeightLandscape - asDouble(input['top']));
    });

    test('keeps all three portrait candidates as parameters with no winner', () {
      final Map<String, Object?> fixture = loadFixture();
      final Map<String, Object?> candidates = asMap(fixture['candidates']);
      for (final String name in <String>['W', 'Band', 'Hybrid']) {
        final Map<String, Object?> entry = asMap(candidates[name]);
        expect(entry['selected'], isFalse, reason: name);
      }
      expect(candidates['selectionNoteZh'], isNotNull);
      final List<Object?> wait = fixture['wait']! as List<Object?>;
      expect(wait.join(' '), contains('未裁决'));
    });
  });

  group('geometry constants', () {
    test('every Qt constant is carried with its source', () {
      expect(QtStageGeometry.stageHeightLandscape, qtStageHeightLandscape);
      expect(QtStageGeometry.stageHeightLandscape, 1080);
      expect(QtStageGeometry.tolerance, qtGeometryTolerance);
      expect(QtStageGeometry.playerBarHeight, 96);
      expect(QtStageGeometry.playerBarTopAtStageHeight1080, 984);
      expect(QtStageGeometry.playerBarTopAtStageHeight1080 + QtStageGeometry.playerBarHeight, 1080);
      expect(QtStageGeometry.contentClipHeight, 984);
      expect(QtStageGeometry.contentClipHeight, QtStageGeometry.playerBarTopAtStageHeight1080);
      expect(QtStageGeometry.inputShieldTop, 978);
      expect(QtStageGeometry.inputShieldTop, QtStageGeometry.contentClipHeight - 6);
      expect(QtStageGeometry.inputShieldTop + QtStageGeometry.inputBoundsHeight, 1080);
      expect(QtStageGeometry.seekTop, 978);
      expect(QtStageGeometry.seekHeight, 18);
      expect(QtStageGeometry.seekTouchHeight, 50);
      expect(seekTouchHeightFor(true), 50);
      expect(seekTouchHeightFor(false), 18);
      expect(QtStageGeometry.volumeWidth, 100);
      expect(QtStageGeometry.volumeHeight, 28);
      expect(QtStageGeometry.volumeTouchHeight, 60);
      expect(volumeTouchHeightFor(true), 60);
      expect(volumeTouchHeightFor(false), 28);
      expect(QtStageGeometry.volumeRightInset, 300);
      expect(QtStageGeometry.volumeXOffset, 58);
      // 300 是 output 列偏移：右边缘留白 = 300 - 58 - 100 = 142，不是 300。
      expect(
        QtStageGeometry.volumeRightInset - QtStageGeometry.volumeXOffset - QtStageGeometry.volumeWidth,
        142,
      );
      expect(QtStageGeometry.modalTop, 122);
      expect(QtStageGeometry.modalHeight, 836);
      expect(QtStageGeometry.modalTop + QtStageGeometry.modalHeight, 958);
      expect(QtStageGeometry.modalDefaultMaxWidth, 1260);
      expect(QtStageGeometry.modalSideInset, 100);
      expect(QtStageGeometry.modalSearchMinWidth, 760);
      expect(QtStageGeometry.modalSearchMaxWidth, 1000);
      expect(QtStageGeometry.modalSearchRightInset, 59);
      expect(QtStageGeometry.resultListTop, 328);
      expect(QtStageGeometry.resultListBottom, 758);
      expect(QtStageGeometry.resultListHeight, 430);
      expect(QtStageGeometry.resultListTop + QtStageGeometry.resultListHeight, 758);
      expect(QtStageGeometry.resultRowHeight, 72);
      expect(QtStageGeometry.inputTopInset, 180);
      expect(QtStageGeometry.inputHeight, 54);
      expect(QtStageGeometry.inputXInset, 53);
      expect(QtStageGeometry.inputWidthInset, 106);
      expect(QtStageGeometry.inputFontSize, 22);
      expect(QtStageGeometry.inputLeftPadding, 18);
      expect(QtStageGeometry.inputRightPadding, 14);
      expect(QtStageGeometry.settingsViewportTop, 176);
      expect(QtStageGeometry.settingsViewportBottom, 836);
      expect(QtStageGeometry.albumTrackTop, 630);
      expect(QtStageGeometry.albumTrackRowHeight, 48);
      expect(QtStageGeometry.albumTrackRowCount, 6);
      expect(QtStageGeometry.touchHitPadding, 16);
      expect(QtStageGeometry.navigationRightMargin, 789);
      expect(QtStageGeometry.archiveMaskFadeWidth, 300);
      expect(QtStageGeometry.containerSidebarMin, 250);
      expect(QtStageGeometry.containerSidebarMax, 340);
      expect(QtStageGeometry.containerLeft, 40);
      expect(QtStageGeometry.containerGap, 36);
      expect(QtStageGeometry.portraitAspectThreshold, 1.05);
    });

    test('matches the fixture geometry block', () {
      final Map<String, Object?> fixture = loadFixture();
      final Map<String, Object?> geometry = asMap(fixture['geometry']);
      final Map<String, Object?> stage = asMap(fixture['stage']);
      expect(asDouble(stage['widthConstant']), portraitStageWidthConstant);
      expect(portraitStageWidthConstant, 1080);
      expect(asDouble(stage['heightLandscape']), QtStageGeometry.stageHeightLandscape);
      final Map<String, Object?> playerBar = asMap(geometry['playerBar']);
      expect(asDouble(playerBar['top']), QtStageGeometry.playerBarTopAtStageHeight1080);
      expect(asDouble(playerBar['rowHeight']), QtStageGeometry.playerBarHeight);
      final Map<String, Object?> seek = asMap(geometry['seek']);
      expect(asDouble(seek['top']), QtStageGeometry.seekTop);
      expect(asDouble(seek['height']), QtStageGeometry.seekHeight);
      expect(asDouble(seek['touchHeight']), QtStageGeometry.seekTouchHeight);
      expect(asDouble(seek['touchHeightOther']), seekTouchHeightFor(false));
      final Map<String, Object?> volumes = asMap(geometry['volumes']);
      expect(asDouble(volumes['width']), QtStageGeometry.volumeWidth);
      expect(asDouble(volumes['height']), QtStageGeometry.volumeHeight);
      expect(asDouble(volumes['touchHeight']), QtStageGeometry.volumeTouchHeight);
      expect(asDouble(volumes['touchHeightOther']), volumeTouchHeightFor(false));
      expect(asDouble(volumes['rightInset']), QtStageGeometry.volumeRightInset);
      expect(asDouble(volumes['xOffset']), QtStageGeometry.volumeXOffset);
      final Map<String, Object?> modal = asMap(geometry['modal']);
      expect(asDouble(modal['top']), QtStageGeometry.modalTop);
      expect(asDouble(modal['height']), QtStageGeometry.modalHeight);
      expect(asDouble(modal['defaultMaxWidth']), QtStageGeometry.modalDefaultMaxWidth);
      expect(asDouble(modal['sideInset']), QtStageGeometry.modalSideInset);
      expect(asDouble(modal['searchMinWidth']), QtStageGeometry.modalSearchMinWidth);
      expect(asDouble(modal['searchMaxWidth']), QtStageGeometry.modalSearchMaxWidth);
      expect(asDouble(modal['searchRightInset']), QtStageGeometry.modalSearchRightInset);
      final Map<String, Object?> resultList = asMap(geometry['resultList']);
      expect(asDouble(resultList['topInset']), QtStageGeometry.resultListTop);
      expect(asDouble(resultList['height']), QtStageGeometry.resultListHeight);
      expect(resultList['derivedFrom'], '758-328');
      expect(asDouble(resultList['rowHeight']), QtStageGeometry.resultRowHeight);
      final Map<String, Object?> textInput = asMap(geometry['input']);
      expect(asDouble(textInput['topInset']), QtStageGeometry.inputTopInset);
      expect(asDouble(textInput['height']), QtStageGeometry.inputHeight);
      expect(asDouble(textInput['xInset']), QtStageGeometry.inputXInset);
      expect(asDouble(textInput['widthInset']), QtStageGeometry.inputWidthInset);
      expect(asDouble(textInput['fontSize']), QtStageGeometry.inputFontSize);
      expect(asDouble(textInput['leftPadding']), QtStageGeometry.inputLeftPadding);
      expect(asDouble(textInput['rightPadding']), QtStageGeometry.inputRightPadding);
      final Map<String, Object?> settings = asMap(geometry['settingsViewport']);
      expect(asDouble(settings['top']), QtStageGeometry.settingsViewportTop);
      expect(asDouble(settings['bottom']), QtStageGeometry.settingsViewportBottom);
      final Map<String, Object?> album = asMap(geometry['albumTrack']);
      expect(asDouble(album['top']), QtStageGeometry.albumTrackTop);
      expect(asDouble(album['rowHeight']), QtStageGeometry.albumTrackRowHeight);
      expect(asDouble(album['rowCount']), QtStageGeometry.albumTrackRowCount);
      expect(asDouble(geometry['contentClipBottom']), QtStageGeometry.contentClipHeight);
      expect(asDouble(geometry['navigationRightMargin']), QtStageGeometry.navigationRightMargin);
      expect(asDouble(geometry['archiveMaskFadeWidth']), QtStageGeometry.archiveMaskFadeWidth);
      expect(asDouble(geometry['touchHitPadding']), QtStageGeometry.touchHitPadding);
      expect(asDouble(geometry['touchHitPaddingOther']), touchPaddingFor(false));
      expect(geometry['touchHitPaddingSource'], isNotNull);
      final Map<String, Object?> container = asMap(geometry['container']);
      expect(asDouble(container['factor']), QtStageGeometry.containerSidebarFactor);
      expect(asDouble(container['offset']), QtStageGeometry.containerSidebarOffset);
      expect(asDouble(container['min']), QtStageGeometry.containerSidebarMin);
      expect(asDouble(container['max']), QtStageGeometry.containerSidebarMax);
      expect(asDouble(container['left']), QtStageGeometry.containerLeft);
      expect(asDouble(container['gap']), QtStageGeometry.containerGap);
    });
  });

  group('Qt ported formulas', () {
    test('modal bounds at stage width 1080 reuse the horizontal formula', () {
      expect(qtModalBounds(1080, PortraitModalKind.standard), const StageRect(50, 122, 980, 836));
      expect(qtModalBounds(1080, PortraitModalKind.search), const StageRect(261, 122, 760, 836));
      final StageRect standard = qtModalBounds(1080, PortraitModalKind.standard);
      expect(standard.y, QtStageGeometry.modalTop);
      expect(standard.height, QtStageGeometry.modalHeight);
      expect(standard.right, 1030);
    });

    test('modal bounds match the landscape stage widths too', () {
      expect(qtModalBounds(1728, PortraitModalKind.standard), const StageRect(234, 122, 1260, 836));
      expect(qtModalBounds(1728, PortraitModalKind.search), const StageRect(864, 122, 805, 836));
      expect(qtModalBounds(1920, PortraitModalKind.standard), const StageRect(330, 122, 1260, 836));
    });

    test('container layout clamps the sidebar and is reused for detail-sort', () {
      final QtContainerLayout at1080 = qtContainerLayout(1080);
      expect(at1080.sidebar, 250);
      expect(at1080.x, 326);
      expect(at1080.width, 714);
      final QtContainerLayout at1728 = qtContainerLayout(1728);
      expect(at1728.sidebar, 340);
      expect(at1728.x, 416);
      expect(at1728.width, 1272);
      expect(qtModalBounds(1080, PortraitModalKind.detailSort), const StageRect(521, 391, 240, 184));
    });

    test('rejects degenerate widths instead of clamping', () {
      expect(() => qtModalBounds(0, PortraitModalKind.standard), throwsArgumentError);
      expect(() => qtModalBounds(-5, PortraitModalKind.search), throwsArgumentError);
      expect(() => qtContainerLayout(0), throwsArgumentError);
      expect(
        () => computePortraitBands(
          const PortraitInputs(layoutWidth: 0, layoutHeight: 2400),
          PortraitBandMode.hybrid,
        ),
        throwsArgumentError,
      );
    });
  });

  group('touch expansion', () {
    test('only Android expands, and seek/volume expand vertically only', () {
      expect(touchPaddingFor(true), 16);
      expect(touchPaddingFor(false), 0);
      const StageRect hit = StageRect(100, 200, 50, 18);
      expect(expandForTouch(hit, false), hit);
      expect(expandForTouch(hit, true), const StageRect(84, 184, 82, 50));
      const StageRect seek = StageRect(0, 978, 1080, 18);
      final StageRect grown = expandForTouchVertical(seek, true);
      expect(grown.y, closeTo(962, kTol));
      expect(grown.height, closeTo(50, kTol));
      expect(grown.x, seek.x);
      expect(grown.width, seek.width);
      expect(grown.height, QtStageGeometry.seekTouchHeight);
      const StageRect volume = StageRect(980, 1000, 100, 28);
      final StageRect grownVolume = expandForTouchVertical(volume, true);
      expect(grownVolume.width, volume.width);
      expect(grownVolume.height, QtStageGeometry.volumeTouchHeight);
    });

    test('bands resolve the platform padding from PortraitInputs.android', () {
      final PortraitBands android = computePortraitBands(
        const PortraitInputs(layoutWidth: 1080, layoutHeight: 2400, android: true),
        PortraitBandMode.hybrid,
      );
      expect(android.touchPadding, 16);
      expect(android.seekTouchHeight, 50);
      expect(android.volumeTouchHeight, 60);
      expect(android.toJson()['touchPadding'], 16);
      final PortraitBands desktop = computePortraitBands(
        const PortraitInputs(layoutWidth: 1080, layoutHeight: 2400),
        PortraitBandMode.hybrid,
      );
      expect(desktop.touchPadding, 0);
      expect(desktop.seekTouchHeight, 18);
      expect(desktop.volumeTouchHeight, 28);
      expect(desktop.toJson()['touchPadding'], 0);
      // 触摸加宽只影响命中层，绝不改舞台与内容矩形。
      expect(desktop.stageScale, android.stageScale);
      expect(desktop.stageWidth, android.stageWidth);
      expect(desktop.stageHeight, android.stageHeight);
      expect(desktop.content, android.content);
      expect(desktop.playerBar, android.playerBar);
    });
  });

  group('proposed three tiers', () {
    test('each tier reproduces its expected metrics', () {
      final Map<String, Object?> fixture = loadFixture();
      final List<Object?> tiers = fixture['tiers']! as List<Object?>;
      expect(tiers, hasLength(3));
      for (final Object? raw in tiers) {
        final Map<String, Object?> expected = asMap(raw);
        final String id = expected['id']! as String;
        final double width = asDouble(expected['layoutWidth']);
        final double height = asDouble(expected['layoutHeight']);
        final PortraitBands w = computePortraitBands(
          PortraitInputs(layoutWidth: width, layoutHeight: height),
          PortraitBandMode.w,
        );
        expect(w.stageScale, closeTo(asDouble(expected['stageScale']), kTol), reason: id);
        expect(w.stageWidth, closeTo(1080, kTol), reason: id);
        expect(w.stageHeight, closeTo(asDouble(expected['stageHeight']), kTol), reason: id);
        expect(w.bandCount, 1, reason: id);
        final List<Object?> wBar = expected['wPlayerBar']! as List<Object?>;
        expect(w.playerBar.x, closeTo(asDouble(wBar[0]), kTol), reason: id);
        expect(w.playerBar.y, closeTo(asDouble(wBar[1]), kTol), reason: id);
        expect(w.playerBar.width, closeTo(asDouble(wBar[2]), kTol), reason: id);
        expect(w.playerBar.height, closeTo(asDouble(wBar[3]), kTol), reason: id);
        expect(w.contentHeight, closeTo(asDouble(expected['wContentHeight']), kTol), reason: id);
        expect(w.content.bottom, closeTo(w.playerBar.y, kTol), reason: id + ' content must stop at the bar');
        expect(w.isDegenerate, isFalse, reason: id + ' must not be degenerate');

        final PortraitBands band = computePortraitBands(
          PortraitInputs(layoutWidth: width, layoutHeight: height),
          PortraitBandMode.band,
        );
        expect(band.bandCount, expected['bandCountBand'], reason: id);
        expect(band.bands, hasLength(band.bandCount), reason: id);
        expect(band.bandRatio, closeTo(asDouble(expected['bandRatio']), kTol), reason: id);
        expect(band.bandHeight, closeTo(1080, kTol), reason: id);
        expect(band.content.bottom, closeTo(band.stageHeight, kTol), reason: id + ' bar overlays the last band');

        final PortraitBands hybrid = computePortraitBands(
          PortraitInputs(layoutWidth: width, layoutHeight: height),
          PortraitBandMode.hybrid,
        );
        expect(hybrid.contentHeight, closeTo(asDouble(expected['hybridContentHeight']), kTol), reason: id);
        expect(hybrid.content.y, closeTo(96, kTol), reason: id);
        expect(hybrid.isDegenerate, isFalse, reason: id + ' must not be degenerate');
      }
    });

    test('band mode stacks whole 1080-tall bands', () {
      final PortraitBands bands = computePortraitBands(
        const PortraitInputs(layoutWidth: 1080, layoutHeight: 2400),
        PortraitBandMode.band,
      );
      expect(bands.bandCount, 3);
      expect(bands.bands[0], const StageRect(0, 0, 1080, 1080));
      expect(bands.bands[1], const StageRect(0, 1080, 1080, 1080));
      expect(bands.bands[2], const StageRect(0, 2160, 1080, 1080));
    });

    test('band ratio equals layoutHeight / layoutWidth', () {
      final PortraitBands bands = computePortraitBands(
        const PortraitInputs(layoutWidth: 1440, layoutHeight: 3200),
        PortraitBandMode.band,
      );
      expect(bands.bandRatio, closeTo(3200 / 1440, kTol));
      expect(bands.bandCount, 3);
    });

    test('a ratio a hair above an integer does not add a band', () {
      final PortraitBands exact = computePortraitBands(
        const PortraitInputs(layoutWidth: 1080, layoutHeight: 3240),
        PortraitBandMode.band,
      );
      expect(exact.bandRatio, 3.0);
      expect(exact.bandCount, 3);
      final PortraitBands over = computePortraitBands(
        const PortraitInputs(layoutWidth: 1080, layoutHeight: 3240.5),
        PortraitBandMode.band,
      );
      expect(over.bandCount, 4);
      expect(ceilWithTolerance(2.0), 2);
      expect(ceilWithTolerance(2.0000000001), 2);
      expect(ceilWithTolerance(2.5), 3);
      expect(ceilWithTolerance(1.0), 1);
    });

    test('fixture epsilon guard cases resolve as declared', () {
      final Map<String, Object?> fixture = loadFixture();
      final Map<String, Object?> guard = asMap(fixture['epsilonGuard']);
      expect(asDouble(guard['tolerance']), kTol);
      final List<Object?> cases = guard['cases']! as List<Object?>;
      expect(cases, hasLength(3));
      for (final Object? raw in cases) {
        final Map<String, Object?> entry = asMap(raw);
        final PortraitBands bands = computePortraitBands(
          PortraitInputs(
            layoutWidth: asDouble(entry['layoutWidth']),
            layoutHeight: asDouble(entry['layoutHeight']),
          ),
          PortraitBandMode.band,
        );
        expect(bands.bandCount, entry['bandCount'], reason: entry['whyZh'].toString());
      }
    });

    test('every tier keeps its bands contiguous from y = 0', () {
      final Map<String, Object?> fixture = loadFixture();
      final List<Object?> tiers = fixture['tiers']! as List<Object?>;
      for (final Object? raw in tiers) {
        final Map<String, Object?> tier = asMap(raw);
        final String id = tier['id']! as String;
        final double width = asDouble(tier['layoutWidth']);
        final double height = asDouble(tier['layoutHeight']);
        final PortraitBands band = computePortraitBands(
          PortraitInputs(
            layoutWidth: width,
            layoutHeight: height,
            safe: const PortraitInsets(top: 24, bottom: 16, left: 12, right: 12),
          ),
          PortraitBandMode.band,
        );
        expect(band.bands, hasLength(band.bandCount), reason: id);
        double cursor = 0;
        for (final StageRect rect in band.bands) {
          expect(rect.x, closeTo(0, kTol), reason: id);
          expect(rect.width, closeTo(1080, kTol), reason: id);
          expect(rect.y, closeTo(cursor, kTol), reason: id);
          expect(rect.height, closeTo(1080, kTol), reason: id);
          cursor = rect.bottom;
        }
        expect(cursor, greaterThanOrEqualTo(band.stageHeight - kTol), reason: id);

        final PortraitBands hybrid = computePortraitBands(
          PortraitInputs(layoutWidth: width, layoutHeight: height),
          PortraitBandMode.hybrid,
        );
        expect(hybrid.bands, hasLength(3), reason: id);
        expect(hybrid.bands.first, const StageRect(0, 0, 1080, 96), reason: id);
        expect(hybrid.bands.last.bottom, closeTo(hybrid.stageHeight, kTol), reason: id);
        expect(hybrid.playerBar.bottom, closeTo(hybrid.stageHeight, kTol), reason: id);

        final PortraitBands w = computePortraitBands(
          PortraitInputs(layoutWidth: width, layoutHeight: height),
          PortraitBandMode.w,
        );
        expect(w.bands, hasLength(1), reason: id);
        expect(w.bands.single, StageRect(0, 0, w.stageWidth, w.stageHeight), reason: id);
      }
    });
  });

  group('safe area and IME', () {
    test('never move the stage scale or stage width', () {
      final PortraitBands before = computePortraitBands(
        const PortraitInputs(layoutWidth: 1080, layoutHeight: 2400),
        PortraitBandMode.hybrid,
      );
      final PortraitBands after = computePortraitBands(
        const PortraitInputs(
          layoutWidth: 1080,
          layoutHeight: 2400,
          safe: PortraitInsets(top: 60, bottom: 40, left: 30, right: 30),
          imeBottom: 800,
        ),
        PortraitBandMode.hybrid,
      );
      expect(after.stageScale, before.stageScale);
      expect(after.stageWidth, before.stageWidth);
      expect(after.stageHeight, before.stageHeight);
      expect(after.containerTop, closeTo(60, kTol));
      expect(after.imeStage, closeTo(800, kTol));
      expect(after.contentX, closeTo(30, kTol));
      expect(after.contentWidth, closeTo(1020, kTol));
    });

    test('compress shortens the content while shiftUp moves the input', () {
      const PortraitInsets safe = PortraitInsets(top: 60, bottom: 40, left: 0, right: 0);
      final PortraitBands before = computePortraitBands(
        const PortraitInputs(layoutWidth: 1080, layoutHeight: 2400, safe: safe),
        PortraitBandMode.hybrid,
      );
      expect(before.contentHeight, closeTo(2400 - 192 - 60 - 40, kTol));
      final PortraitBands compress = computePortraitBands(
        const PortraitInputs(layoutWidth: 1080, layoutHeight: 2400, safe: safe, imeBottom: 800),
        PortraitBandMode.hybrid,
      );
      expect(compress.imeConsumedStage, closeTo(800, kTol));
      expect(compress.contentHeight, closeTo(before.contentHeight - 800, kTol));
      expect(compress.inputShiftStage, closeTo(0, kTol));
      final PortraitBands shift = computePortraitBands(
        const PortraitInputs(layoutWidth: 1080, layoutHeight: 2400, safe: safe, imeBottom: 800),
        PortraitBandMode.hybrid,
        imePolicy: PortraitImePolicy.shiftUp,
      );
      expect(shift.contentHeight, closeTo(before.contentHeight, kTol));
      expect(shift.inputShiftStage, closeTo(800, kTol));
      expect(shift.imeConsumedStage, closeTo(0, kTol));
    });

    test('logical insets are divided by the stage scale', () {
      final PortraitBands bands = computePortraitBands(
        const PortraitInputs(
          layoutWidth: 1440,
          layoutHeight: 3200,
          safe: PortraitInsets(top: 120, bottom: 60),
          imeBottom: 1200,
        ),
        PortraitBandMode.hybrid,
      );
      expect(bands.stageScale, closeTo(1440 / 1080, kTol));
      expect(bands.containerTop, closeTo(120 / (1440 / 1080), kTol));
      expect(bands.imeStage, closeTo(1200 / (1440 / 1080), kTol));
      expect(bands.contentHeight, closeTo(bands.stageHeight - 192 - bands.containerTop - 60 / (1440 / 1080) - bands.imeStage, kTol));
    });
  });

  group('fixture inset matrix', () {
    test('narrows content on every tier without moving the stage', () {
      final Map<String, Object?> fixture = loadFixture();
      final Map<String, Object?> matrix = asMap(fixture['insetMatrix']);
      final List<Object?> cases = matrix['cases']! as List<Object?>;
      expect(cases, hasLength(5));
      final List<Object?> tiers = fixture['tiers']! as List<Object?>;
      expect(tiers, hasLength(3));
      for (final Object? rawTier in tiers) {
        final Map<String, Object?> tier = asMap(rawTier);
        final String tierId = tier['id']! as String;
        final double width = asDouble(tier['layoutWidth']);
        final double height = asDouble(tier['layoutHeight']);
        final double scale = asDouble(tier['stageScale']);
        final PortraitBands base = computePortraitBands(
          PortraitInputs(layoutWidth: width, layoutHeight: height),
          PortraitBandMode.hybrid,
        );
        for (final Object? rawCase in cases) {
          final Map<String, Object?> entry = asMap(rawCase);
          final String id = tierId + '/' + entry['id'].toString();
          final PortraitInsets safe = PortraitInsets.fromJson(asMap(entry['safe']));
          final double ime = asDouble(entry['imeBottom']);
          final PortraitImePolicy policy =
              entry['imePolicy'] == 'shiftUp' ? PortraitImePolicy.shiftUp : PortraitImePolicy.compress;
          final PortraitBands bands = computePortraitBands(
            PortraitInputs(layoutWidth: width, layoutHeight: height, safe: safe, imeBottom: ime),
            PortraitBandMode.hybrid,
            imePolicy: policy,
          );
          expect(bands.stageScale, closeTo(base.stageScale, kTol), reason: id);
          expect(bands.stageWidth, closeTo(base.stageWidth, kTol), reason: id);
          expect(bands.stageHeight, closeTo(base.stageHeight, kTol), reason: id);
          expect(bands.containerTop, closeTo(safe.top / scale, kTol), reason: id);
          expect(bands.imeStage, closeTo(ime / scale, kTol), reason: id);
          expect(bands.contentX, closeTo(safe.left / scale, kTol), reason: id);
          expect(bands.contentWidth, closeTo(1080 - (safe.left + safe.right) / scale, kTol), reason: id);
          final double imeConsumed = policy == PortraitImePolicy.compress ? ime / scale : 0;
          expect(bands.imeConsumedStage, closeTo(imeConsumed, kTol), reason: id);
          expect(
            bands.contentHeight,
            closeTo(bands.stageHeight - 192 - (safe.top + safe.bottom) / scale - imeConsumed, kTol),
            reason: id,
          );
          expect(bands.inputShiftStage, closeTo(ime / scale - imeConsumed, kTol), reason: id);
          expect(bands.content.y, closeTo(safe.top / scale + 96, kTol), reason: id);
          expect(bands.content.bottom, lessThanOrEqualTo(bands.playerBar.y + kTol), reason: id);
          expect(
            bands.content.isWithin(StageRect(0, 0, bands.stageWidth, bands.stageHeight), epsilon: kTol),
            isTrue,
            reason: id,
          );
          expect(bands.isDegenerate, isFalse, reason: id);
        }
      }
    });

    test('fixture stage-width block agrees with the ported formulas', () {
      final Map<String, Object?> fixture = loadFixture();
      final Map<String, Object?> block = asMap(fixture['atStageWidth1080']);
      final List<Object?> standard = block['modalStandard']! as List<Object?>;
      expect(
        qtModalBounds(1080, PortraitModalKind.standard),
        StageRect(
          asDouble(standard[0]),
          asDouble(standard[1]),
          asDouble(standard[2]),
          asDouble(standard[3]),
        ),
      );
      final List<Object?> search = block['modalSearch']! as List<Object?>;
      expect(
        qtModalBounds(1080, PortraitModalKind.search),
        StageRect(
          asDouble(search[0]),
          asDouble(search[1]),
          asDouble(search[2]),
          asDouble(search[3]),
        ),
      );
      final QtContainerLayout layout = qtContainerLayout(1080);
      final Map<String, Object?> container = asMap(block['containerLayout']);
      expect(layout.sidebar, closeTo(asDouble(container['sidebar']), kTol));
      expect(layout.x, closeTo(asDouble(container['x']), kTol));
      expect(layout.width, closeTo(asDouble(container['width']), kTol));
      final double navigationLeft = asDouble(block['navigationLeft']);
      expect(QtStageGeometry.navigationRightMargin, closeTo(1080 - navigationLeft, kTol));
      expect(
        asDouble(block['archiveMaskFadeStart']),
        closeTo(navigationLeft - QtStageGeometry.archiveMaskFadeWidth, kTol),
      );
    });
  });

  group('degeneracies are surfaced, not clamped', () {
    test('negative insets are reported and treated as zero', () {
      final PortraitBands bands = computePortraitBands(
        const PortraitInputs(
          layoutWidth: 1080,
          layoutHeight: 2400,
          safe: PortraitInsets(top: -10, left: -5),
          imeBottom: -5,
        ),
        PortraitBandMode.hybrid,
      );
      expect(bands.isDegenerate, isTrue);
      expect(bands.degeneracies.join(' '), contains('safe.top'));
      expect(bands.containerTop, 0);
      expect(bands.imeStage, 0);
    });

    test('a stage shorter than the player bar is reported, not clamped', () {
      final PortraitBands bands = computePortraitBands(
        const PortraitInputs(layoutWidth: 1080, layoutHeight: 60),
        PortraitBandMode.hybrid,
      );
      expect(bands.playerBar.y, closeTo(60 - 96, kTol));
      expect(bands.isDegenerate, isTrue);
      expect(bands.degeneracies.join(' '), contains('player bar'));
    });

    test('safe area wider than the stage is reported', () {
      final PortraitBands bands = computePortraitBands(
        const PortraitInputs(
          layoutWidth: 1080,
          layoutHeight: 2400,
          safe: PortraitInsets(left: 700, right: 700),
        ),
        PortraitBandMode.hybrid,
      );
      expect(bands.contentWidth, closeTo(1080 - 1400, kTol));
      expect(bands.isDegenerate, isTrue);
      expect(bands.degeneracies.join(' '), contains('stage width'));
    });
  });

  group('StageRect helpers', () {
    test('edges, containment and growth', () {
      const StageRect rect = StageRect(1, 2, 3, 4);
      expect(rect.right, 4);
      expect(rect.bottom, 6);
      expect(rect.isPositive(), isTrue);
      expect(const StageRect(0, 0, 0, 4).isPositive(), isFalse);
      const StageRect outer = StageRect(0, 0, 100, 100);
      expect(outer.contains(50, 50), isTrue);
      expect(outer.contains(-0.5, 0), isFalse);
      expect(outer.contains(100, 100), isTrue);
      expect(rect.isWithin(outer), isTrue);
      expect(const StageRect(0, 0, 101, 10).isWithin(outer), isFalse);
      expect(const StageRect(0, 0, 101, 10).isWithin(outer, epsilon: 2), isTrue);
      expect(rect.expand(2), const StageRect(-1, 0, 7, 8));
      expect(rect.expandVertical(3), const StageRect(1, -1, 3, 10));
      expect(rect.shiftY(10), const StageRect(1, 12, 3, 4));
    });

    test('json round trip', () {
      const StageRect rect = StageRect(1.5, 2.5, 3.5, 4.5);
      expect(StageRect.fromJson(rect.toJson()), rect);
      expect(rect.toJson()['width'], 3.5);
      expect(StageRect.fromJson(<String, Object?>{'x': 1, 'y': 2, 'width': 3, 'height': 4}), const StageRect(1, 2, 3, 4));
      expect(decodeNumber('2.5'), 2.5);
      expect(decodeNumber(3), 3.0);
      expect(() => decodeNumber('abc'), throwsArgumentError);
    });
  });

  group('branch selection', () {
    test('follows the Qt aspect test instead of the device type', () {
      expect(prefersPortraitBranch(1080, 2400), isTrue);
      expect(prefersPortraitBranch(1040, 1000), isTrue);
      expect(prefersPortraitBranch(1050, 1000), isFalse);
      expect(prefersPortraitBranch(1060, 1000), isFalse);
      expect(prefersPortraitBranch(1080, 1080), isTrue);
      expect(() => prefersPortraitBranch(0, 100), throwsArgumentError);
    });
  });

  // 133 条动作登记拆成四个精确集合：proven 只证明源码行/矩形证据，
  // sourceDependencyBlocked 缺可携带几何，noHit 与 platformAbsent 分别登记。
  // 这不是运行时、golden 或设备证明；T33-T40 集成前不得把本组当 C4 证明。
  group('action registry', () {
    test('splits all 133 source records into four disjoint exact sets', () {
      final Map<String, Object?> coverage = asMap(loadFixture()['actionCoverage']);
      expect(coverage['coverageStatus'], 'REGISTRY_SPLIT_SOURCE_DEPENDENCY_BLOCKED');
      expect(coverage['source'], 'test/fixtures/portrait_bands.json#actionCoverage.registry');
      expect(jsonEncode(coverage), isNot(contains('.agents')));
      final Map<String, Object?> inventory = asMap(coverage['inventory']);
      expect(inventory['id'], 'T43-V4-INV-ACT');
      expect(inventory['actionCount'], 133);
      expect(inventory['faceCount'], 7);
      expect(inventory['verification'], 'SOURCE_VERIFIED_LANDSCAPE');
      expect(inventory['runtime'], 'UNVERIFIED_RUNTIME');
      expect(inventory['assertedHere'], 'registry-integrity-only');
      expect(asDouble(inventory['rectEpsStage']), kTol);
      final Map<String, Object?> registry = asMap(coverage['registry']);
      final List<Map<String, Object?>> proven = asMapList(registry['proven']);
      final List<Map<String, Object?>> blocked = asMapList(registry['sourceDependencyBlocked']);
      final List<Map<String, Object?>> noHit = asMapList(registry['noHit']);
      final List<Map<String, Object?>> absent = asMapList(registry['platformAbsent']);
      expect(proven, hasLength(64));
      expect(blocked, hasLength(46));
      expect(noHit, hasLength(16));
      expect(absent, hasLength(7));
      expect(proven.length + blocked.length + noHit.length + absent.length, 133);
      final Map<String, Object?> counts = asMap(inventory['registryCounts']);
      expect(counts['proven'], 64);
      expect(counts['sourceDependencyBlocked'], 46);
      expect(counts['noHit'], 16);
      expect(counts['platformAbsent'], 7);
      final Map<String, Object?> faceTotals = asMap(inventory['faceTotals']);
      const Map<String, int> expectedFaceTotals = <String, int>{
        '1_home_chrome_archive': 24,
        '2_playerbar_bottom': 12,
        '3_detail_song_container_viewer_lyrics': 37,
        '4_search': 7,
        '5_settings': 32,
        '6_queue': 8,
        '7_login_saved': 13,
      };
      expect(faceTotals, expectedFaceTotals);
      for (final MapEntry<String, int> total in expectedFaceTotals.entries) {
        int actual = 0;
        for (final List<Map<String, Object?>> group in <List<Map<String, Object?>>>[proven, blocked, noHit, absent]) {
          actual += group.where((Map<String, Object?> record) => record['face'] == total.key).length;
        }
        expect(actual, total.value, reason: 'registry face total: ' + total.key);
      }
      final Set<String> keys = <String>{};
      for (final List<Map<String, Object?>> group in <List<Map<String, Object?>>>[proven, blocked, noHit, absent]) {
        for (final Map<String, Object?> record in group) {
          expect(expectedFaceTotals.containsKey(record['face']), isTrue, reason: 'unknown face: ' + record['face'].toString());
          final String key =
              <Object?>[record['face'], record['action'], record['source'], record['region'] ?? '', record['rect'] ?? ''].join('|');
          expect(keys.add(key), isTrue, reason: 'duplicate registry record: ' + key);
        }
      }
    });

    test('proven records have portable Qt sources and numeric rects', () {
      final Map<String, Object?> registry = asMap(asMap(loadFixture()['actionCoverage'])['registry']);
      final List<Map<String, Object?>> proven = asMapList(registry['proven']);
      for (final Map<String, Object?> record in proven) {
        expect(record['action'].toString(), isNotEmpty);
        expect(record['action'].toString().startsWith('—'), isFalse, reason: 'proven must be an action: ' + record.toString());
        expect(record['source'].toString().startsWith('Qt/'), isTrue, reason: 'source must be a Qt path: ' + record.toString());
        expect(_numberCount(record['rect']), greaterThanOrEqualTo(2), reason: 'rect must carry two numbers: ' + record.toString());
        expect(_hasRectPlaceholder(record['rect']), isFalse, reason: 'rect must not be a placeholder: ' + record.toString());
      }
      final List<Map<String, Object?>> blocked = asMapList(registry['sourceDependencyBlocked']);
      const Set<String> owners = <String>{'T33', 'T34', 'T35', 'T36', 'T37', 'T39'};
      for (final Map<String, Object?> record in blocked) {
        expect(record['status'], 'SOURCE_DEPENDENCY_BLOCKED');
        expect(owners.contains(record['blockedBy']), isTrue, reason: 'blockedBy must name a T33-T40 face owner: ' + record.toString());
        expect(
          _numberCount(record['rect']) < 2 || _hasRectPlaceholder(record['rect']),
          isTrue,
          reason: 'blocked rect must stay non-portable: ' + record.toString(),
        );
      }
    });

    test('negative records and platform gates are exact, not a catch-all WAIT', () {
      final Map<String, Object?> coverage = asMap(loadFixture()['actionCoverage']);
      final Map<String, Object?> registry = asMap(coverage['registry']);
      final List<Map<String, Object?>> noHit = asMapList(registry['noHit']);
      final Map<String, int> kinds = <String, int>{};
      for (final Map<String, Object?> record in noHit) {
        expect(record['action'].toString().startsWith('—'), isTrue);
        expect(record['region'].toString(), isNotEmpty);
        expect(record['source'].toString().startsWith('Qt/'), isTrue);
        final String kind = record['kind']! as String;
        kinds[kind] = (kinds[kind] ?? 0) + 1;
      }
      expect(kinds, <String, int>{'NO_HIT': 11, 'GEOMETRY_CONSTANT': 4, 'NON_HIT_VISUAL': 1});
      final Map<String, Object?> noHitSummary = asMap(coverage['noHitExpected']);
      expect(noHitSummary['status'], 'REGISTERED_EXACT_16');
      expect(asMap(noHitSummary['counts']), <String, int>{'NO_HIT': 11, 'GEOMETRY_CONSTANT': 4, 'NON_HIT_VISUAL': 1});
      final List<Map<String, Object?>> absent = asMapList(registry['platformAbsent']);
      expect(absent, hasLength(7));
      final Set<String> reasons = <String>{};
      final Set<String> absentActions = <String>{};
      for (final Map<String, Object?> record in absent) {
        reasons.add(record['reason']! as String);
        absentActions.add(record['action']! as String);
        expect(record['source'].toString().startsWith('Qt/'), isTrue);
      }
      expect(reasons, <String>{'PLATFORM_GATED_MOBILE_ABSENT', 'PLATFORM_DIFF_ANDROID_NO_LABEL_HOTZONE'});
      expect(
        absentActions,
        containsAll(<String>[
          'player:volume-fraction:0',
          'music:official',
          'window:fullscreen',
          'desktop-lyrics:open',
          'binding.action',
        ]),
      );
      final List<Object?> criteria = coverage['criteria']! as List<Object?>;
      expect(criteria, hasLength(7));
      final Map<String, String> states = <String, String>{
        for (final Object? raw in criteria) asMap(raw)['id'].toString(): asMap(raw)['state'].toString(),
      };
      expect(states['A1'], 'PENDING_T33_T40');
      expect(states['A2'], 'PENDING_T33_T40');
      expect(states['A3'], 'PENDING_T33_T40');
      expect(states['A4'], 'PENDING_T33_T40');
      expect(states['A5'], 'PENDING_T33_T40');
      expect(states['A6'], 'PENDING_T33_T40');
      expect(states['A7'], 'REGISTERED_EXACT_16');
      expect(states.values.every((String state) => !state.contains('WAIT')), isTrue);
    });

    test('keeps duplicates, capability gates and the Android label diff', () {
      final Map<String, Object?> coverage = asMap(loadFixture()['actionCoverage']);
      expect(coverage['duplicateActions']! as List<Object?>, hasLength(5));
      final Map<String, Object?> gated = asMap(coverage['platformGatedMobileAbsent']);
      expect(gated['source'], contains('Qt/src/PlatformFeatures.h:7-24'));
      final List<Object?> capabilities = gated['capabilities']! as List<Object?>;
      expect(capabilities, hasLength(6));
      final List<String> gatedActions = <String>[];
      for (final Object? raw in capabilities) {
        final Map<String, Object?> capability = asMap(raw);
        expect(capability['capability'].toString(), isNotEmpty);
        final List<Object?> kills = capability['kills']! as List<Object?>;
        expect(kills, isNotEmpty);
        for (final Object? kill in kills) {
          final Map<String, Object?> entry = asMap(kill);
          expect(entry['action'].toString(), isNotEmpty);
          expect(entry['source'].toString(), contains('Qt/src/'));
          gatedActions.add(entry['action']! as String);
        }
      }
      expect(
        gatedActions,
        containsAll(<String>[
          'music:official',
          'provider:local',
          'player:volume-fraction:0',
          'window:fullscreen',
          'desktop-lyrics:open',
        ]),
      );
      final Map<String, Object?> androidOnly = asMap(coverage['androidOnlyDifference']);
      expect(androidOnly['source'], 'Qt/src/SettingsCard.cpp:82-92');
    });
  });

  group('PortraitBandViewport', () {
    test('reports the band overflow of every proposed tier', () {
      final List<Object?> tiers = loadFixture()['tiers']! as List<Object?>;
      expect(tiers, hasLength(3));
      for (final Object? rawTier in tiers) {
        final Map<String, Object?> tier = asMap(rawTier);
        final double width = asDouble(tier['layoutWidth']);
        final double height = asDouble(tier['layoutHeight']);
        final PortraitBands bands = computePortraitBands(
          PortraitInputs(layoutWidth: width, layoutHeight: height),
          PortraitBandMode.band,
        );
        final PortraitBandViewport viewport = bands.bandViewport;
        final double content = asDouble(tier['bandCountBand']) * 1080;
        final double overflow = content > bands.stageHeight ? content - bands.stageHeight : 0.0;
        expect(viewport.stageWidth, closeTo(1080, kTol), reason: tier['id'].toString());
        expect(viewport.viewportHeight, closeTo(bands.stageHeight, kTol), reason: tier['id'].toString());
        expect(viewport.contentHeight, closeTo(content, kTol), reason: tier['id'].toString());
        expect(viewport.overflow, closeTo(overflow, kTol), reason: tier['id'].toString());
        expect(viewport.overflows, isTrue, reason: tier['id'].toString());
        expect(viewport.fits, isFalse, reason: tier['id'].toString());
        expect(bands.bandsOverflow, closeTo(overflow, kTol), reason: tier['id'].toString());
      }
    });

    test('clamps scroll offsets and reveals the tail band without clipping it', () {
      final PortraitBands bands = computePortraitBands(const PortraitInputs(layoutWidth: 1080, layoutHeight: 2400), PortraitBandMode.band);
      final PortraitBandViewport viewport = bands.bandViewport;
      expect(viewport.clampScrollOffset(-5), 0);
      expect(viewport.clampScrollOffset(0), 0);
      expect(viewport.clampScrollOffset(900), closeTo(840, kTol));
      expect(viewport.clampScrollOffset(1e9), closeTo(840, kTol));
      expect(viewport.visibleRect(-10), const StageRect(0, 0, 1080, 2400));
      expect(viewport.visibleRect(840), const StageRect(0, 840, 1080, 2400));
      expect(viewport.isBandVisible(bands.bands[2], 0), isFalse);
      expect(viewport.isBandVisible(bands.bands[2], 840), isTrue);
      expect(viewport.offsetToReveal(bands.bands[2]), closeTo(840, kTol));
      expect(viewport.offsetToReveal(bands.bands[2], alignment: 0), closeTo(840, kTol));
    });

    test('rejects non-finite offsets and invalid reveal requests', () {
      final PortraitBands bands = computePortraitBands(const PortraitInputs(layoutWidth: 1080, layoutHeight: 2400), PortraitBandMode.band);
      final PortraitBandViewport viewport = bands.bandViewport;
      expect(() => viewport.clampScrollOffset(double.nan), throwsArgumentError);
      expect(() => viewport.clampScrollOffset(double.infinity), throwsArgumentError);
      expect(() => viewport.clampScrollOffset(double.negativeInfinity), throwsArgumentError);
      expect(() => viewport.offsetToReveal(const StageRect(0, 0, 0, 0)), throwsArgumentError);
      expect(() => viewport.offsetToReveal(bands.bands[0], alignment: -0.1), throwsArgumentError);
      expect(() => viewport.offsetToReveal(bands.bands[0], alignment: 1.1), throwsArgumentError);
      expect(() => viewport.offsetToReveal(bands.bands[0], alignment: double.nan), throwsArgumentError);
    });

    test('hybrid and w candidates fit without inventing overflow', () {
      final PortraitBands hybrid = computePortraitBands(const PortraitInputs(layoutWidth: 1080, layoutHeight: 2400), PortraitBandMode.hybrid);
      final PortraitBands w = computePortraitBands(const PortraitInputs(layoutWidth: 1080, layoutHeight: 2400), PortraitBandMode.w);
      expect(hybrid.bandViewport.overflow, 0);
      expect(hybrid.bandViewport.fits, isTrue);
      expect(w.bandViewport.overflow, 0);
      expect(w.bandViewport.fits, isTrue);
    });
  });

  group('PortraitStage', () {
    test('scope is absent outside a stage', () {
      expect(PortraitStageScope.maybeOf(_NullContext()), isNull);
    });

    testWidgets('lays the child out in stage units and scales from the top left', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 2400));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });
      PortraitBands? observed;
      Size? childConstraints;
      await tester.pumpWidget(host(
        surface: const Size(1080, 2400),
        child: PortraitStage(
          child: Builder(builder: (BuildContext context) {
            observed = PortraitStageScope.of(context);
            return LayoutBuilder(builder: (BuildContext context, BoxConstraints constraints) {
              childConstraints = constraints.biggest;
              return const SizedBox.expand();
            });
          }),
        ),
      ));
      expect(observed, isNotNull);
      expect(observed!.stageScale, closeTo(1.0, kTol));
      expect(observed!.stageWidth, closeTo(1080, kTol));
      expect(observed!.stageHeight, closeTo(2400, kTol));
      expect(observed!.contentHeight, closeTo(2208, kTol));
      expect(childConstraints!.width, closeTo(1080, kTol));
      expect(childConstraints!.height, closeTo(2400, kTol));
    });

    testWidgets('positions slots in stage units', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 2400));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(host(
        surface: const Size(1080, 2400),
        child: PortraitStage(
          child: Stack(children: <Widget>[
            PortraitStageSlot(
              rect: const StageRect(0, 984, 1080, 96),
              child: const SizedBox(key: ValueKey<String>('player-bar'), width: 1080, height: 96),
            ),
          ]),
        ),
      ));
      expect(tester.getTopLeft(find.byKey(const ValueKey<String>('player-bar'))), const Offset(0, 984));
      expect(tester.getSize(find.byKey(const ValueKey<String>('player-bar'))), const Size(1080, 96));
    });

    testWidgets('band view emits one slot per band and scrolls the overflow', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 2400));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(host(
        surface: const Size(1080, 2400),
        child: PortraitStage(
          mode: PortraitBandMode.band,
          child: PortraitStageBandsView(
            scrollable: true,
            builder: (BuildContext context, int index, StageRect band) =>
                SizedBox(key: ValueKey<int>(index), width: band.width, height: band.height),
          ),
        ),
      ));
      expect(find.byKey(const ValueKey<int>(0)), findsOneWidget);
      expect(find.byKey(const ValueKey<int>(1)), findsOneWidget);
      expect(find.byKey(const ValueKey<int>(2)), findsOneWidget);
      expect(find.byKey(const ValueKey<int>(3)), findsNothing);
      final ScrollableState scrollable = tester.state<ScrollableState>(
        find.descendant(of: find.byType(SingleChildScrollView), matching: find.byType(Scrollable)),
      );
      expect(scrollable.position.maxScrollExtent, closeTo(840, kTol));
    });

    testWidgets('band view refuses to silently clip when scrolling is not enabled', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 2400));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(host(
        surface: const Size(1080, 2400),
        child: PortraitStage(
          mode: PortraitBandMode.band,
          child: PortraitStageBandsView(
            builder: (BuildContext context, int index, StageRect band) =>
                SizedBox(key: ValueKey<int>(index), width: band.width, height: band.height),
          ),
        ),
      ));
      expect(tester.takeException(), isA<FlutterError>());
    });

    testWidgets('band view does not add a scroll view when every band fits', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 2400));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(host(
        surface: const Size(1080, 2400),
        child: PortraitStage(
          mode: PortraitBandMode.hybrid,
          child: PortraitStageBandsView(
            builder: (BuildContext context, int index, StageRect band) =>
                SizedBox(key: ValueKey<int>(index), width: band.width, height: band.height),
          ),
        ),
      ));
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(find.byKey(const ValueKey<int>(2)), findsOneWidget);
    });

    testWidgets('recomputes when the available size changes', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 2400));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });
      PortraitBands? observed;
      Widget build() => host(
            surface: const Size(1080, 2400),
            child: PortraitStage(
              child: Builder(builder: (BuildContext context) {
                observed = PortraitStageScope.of(context);
                return const SizedBox.expand();
              }),
            ),
          );
      await tester.pumpWidget(build());
      expect(observed, isNotNull);
      expect(observed!.stageScale, closeTo(1.0, kTol));
      await tester.binding.setSurfaceSize(const Size(1200, 2000));
      await tester.pumpWidget(build());
      expect(observed!.stageScale, closeTo(1200 / 1080, kTol));
      expect(observed!.stageHeight, closeTo(1800, kTol));
      expect(observed!.contentHeight, closeTo(1608, kTol));
    });

    testWidgets('keeps the stage scale when the keyboard inset appears', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1080, 2400));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });
      PortraitBands? observed;
      Widget build(EdgeInsets viewInsets) => host(
            surface: const Size(1080, 2400),
            viewInsets: viewInsets,
            child: PortraitStage(
              child: Builder(builder: (BuildContext context) {
                observed = PortraitStageScope.of(context);
                return const SizedBox.expand();
              }),
            ),
          );
      await tester.pumpWidget(build(EdgeInsets.zero));
      expect(observed!.stageScale, closeTo(1.0, kTol));
      expect(observed!.contentHeight, closeTo(2208, kTol));
      await tester.pumpWidget(build(const EdgeInsets.only(bottom: 900)));
      expect(observed!.stageScale, closeTo(1.0, kTol));
      expect(observed!.imeStage, closeTo(900, kTol));
      expect(observed!.contentHeight, closeTo(2208 - 900, kTol));
    });
  });
}
