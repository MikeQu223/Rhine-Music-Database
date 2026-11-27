// Geometry assertions for the T35 search modal chrome (W1, atom
// T35-C19-A1-search_modal). The expected numbers are transcribed from Qt:
//   NativeHud.cpp:140-158   modalBounds / search modalWidth / left
//   NativeHud.cpp:184-191   input + search list stage geometry
//   NativeHud.h:96-98       ResultListTop/Bottom/RowHeight (frozen, W2)
//   NativeHudSearch.cpp:8-18 toolbar constants
//   Overlay.qml:520-566     input layer geometry (height 54, font 22, pads)
// Tests only; never executed in this card (RED/GREEN unexecuted).

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/search_modal.dart';
import 'package:rhine_music_database/hud/modals/search_results.dart';

void main() {
  group('frozen cross-module constants (search_results.dart, W2 owned)', () {
    test('values are the Qt ones and are reused, not redefined', () {
      expect(kSearchInset, 53);
      expect(kSearchResultListTop, 328);
      expect(kSearchResultListBottom, 758);
      expect(kSearchResultRowHeight, 72);
    });
  });

  group('toolbar constants == Qt/src/NativeHudSearch.cpp:8-18', () {
    test('one to one', () {
      expect(kSearchToolbarInset, 53); // SearchInset
      expect(kSearchBarTop, 172);
      expect(kSearchBarHeight, 66);
      expect(kSearchTabTop, 252);
      expect(kSearchTabHeight, 36);
      expect(kSearchTableY, 302);
      expect(kSearchFooterY, 786);
      expect(kSearchKindGap, 26);
      expect(kSearchSortGap, 20);
      expect(kSearchTitleX, 107);
      expect(kSearchActionWidth, 136);
    });

    test('frame constants (NativeHud.cpp:153-158)', () {
      expect(kSearchModalTop, 122);
      expect(kSearchModalHeight, 836);
      expect(kSearchModalRightInset, 59);
      expect(kSearchModalStageMargin, 100);
      expect(kSearchModalMinWidth, 760);
      expect(kSearchModalMaxWidth, 1000);
      expect(kSearchModalWidthFactor, 0.5);
      expect(kSearchModalWidthBias, 59);
    });

    test('input layer constants (NativeHud.cpp:184-186 + Overlay.qml:520-566)', () {
      expect(kSearchInputHeight, 54);
      expect(kSearchInputVerticalOffset, 180); // bounds.y + 180 == 302
      expect(kSearchInputFontSize, 22);
      expect(kSearchInputLeftPadding, 18);
      expect(kSearchInputRightPadding, 14);
      expect(kSearchInputClip, isTrue);
    });
  });

  group('modal width formula (NativeHud.cpp:154-156)', () {
    test('stageWidth 1920 -> 901', () {
      expect(searchModalWidth(1920), 901);
    });

    test('stageWidth 2340 -> 1000 (max clamp)', () {
      expect(searchModalWidth(2340), 1000);
    });

    test('stageWidth 1080 -> 760 (min clamp)', () {
      expect(searchModalWidth(1080), 760);
    });

    test('stageWidth 800 -> 700 (available width pins below min)', () {
      expect(searchModalWidth(800), 700);
    });

    test('matches min(w-100, max(760, min(1000, w*0.5-59))) across widths', () {
      for (final double width in <double>[
        640,
        700,
        760,
        800,
        860,
        1080,
        1280,
        1600,
        1920,
        2340,
        2560,
      ]) {
        final double expected = math.min(
          width - 100,
          math.max(760.0, math.min(1000.0, width * 0.5 - 59)),
        );
        expect(
          searchModalWidth(width),
          closeTo(expected, 1e-9),
          reason: 'stageWidth $width',
        );
      }
    });

    test('narrow/portrait branch marker has no invented pixel values', () {
      expect(searchModalNarrowBranch(800), isTrue); // 800-100 < 760
      expect(searchModalNarrowBranch(850), isTrue); // 750 < 760
      expect(searchModalNarrowBranch(860), isFalse); // 760 not < 760
      expect(searchModalNarrowBranch(1080), isFalse);
      // Degradation is the Qt outer clamp only: 700 -> 600, never below it.
      expect(searchModalWidth(700), 600);
    });
  });

  group('modal bounds (NativeHud.cpp:157-158)', () {
    test('1920', () {
      expect(searchModalLeft(1920), 960);
      final Rect bounds = searchModalBounds(1920);
      expect(bounds.left, 960);
      expect(bounds.top, 122);
      expect(bounds.width, 901);
      expect(bounds.height, 836);
      expect(bounds.right, 1861); // stageWidth - 59
    });

    test('2340', () {
      expect(searchModalLeft(2340), 1281);
      final Rect bounds = searchModalBounds(2340);
      expect(bounds.left, 1281);
      expect(bounds.top, 122);
      expect(bounds.width, 1000);
      expect(bounds.height, 836);
    });

    test('1080', () {
      expect(searchModalLeft(1080), 261);
      final Rect bounds = searchModalBounds(1080);
      expect(bounds.left, 261);
      expect(bounds.width, 760);
    });

    test('800', () {
      expect(searchModalLeft(800), 41);
      final Rect bounds = searchModalBounds(800);
      expect(bounds.left, 41);
      expect(bounds.width, 700);
    });
  });

  group('input rect (NativeHud.cpp:184-186 + Overlay.qml:520-566)', () {
    test('1920 default', () {
      final Rect rect = searchInputRect(1920);
      expect(rect.left, 1013); // 960 + 53
      expect(rect.top, 302); // 122 + 180
      expect(rect.width, 795); // 901 - 106
      expect(rect.height, 54);
    });

    test('1920 minus libraryToolbarActionWidth', () {
      final Rect rect =
          searchInputRect(1920, libraryToolbarActionWidth: 136);
      expect(rect.left, 1013);
      expect(rect.width, 659); // 795 - 136
      expect(rect.height, 54);
    });

    test('2340 / 1080 / 800', () {
      expect(searchInputRect(2340).left, 1334);
      expect(searchInputRect(2340).width, 894);
      expect(searchInputRect(1080).left, 314);
      expect(searchInputRect(1080).width, 654);
      expect(searchInputRect(800).left, 94);
      expect(searchInputRect(800).width, 594);
      expect(searchInputRect(800).top, 302);
      expect(searchInputRect(800).height, 54);
    });
  });

  group('search list viewport (NativeHud.cpp:188-191 + NativeHud.h:96-98)', () {
    test('1920', () {
      final Rect rect = searchListRect(1920);
      expect(rect.left, 1013); // 960 + kSearchInset
      expect(rect.top, 450); // 122 + kSearchResultListTop
      expect(rect.width, 795); // 901 - 106
      expect(rect.height, 430); // 758 - 328
    });

    test('2340 / 1080 / 800', () {
      expect(searchListRect(2340).left, 1334);
      expect(searchListRect(2340).width, 894);
      expect(searchListRect(1080).left, 314);
      expect(searchListRect(1080).width, 654);
      expect(searchListRect(800).left, 94);
      expect(searchListRect(800).width, 594);
      for (final double width in <double>[800, 1080, 1920, 2340]) {
        expect(searchListRect(width).height, 430);
        expect(
          searchListRect(width).width,
          searchModalWidth(width) - 2 * kSearchInset,
        );
      }
    });

    test('usable width is modalWidth - 2 * SearchInset', () {
      expect(searchUsableWidth(1920), 795);
      expect(searchUsableWidth(2340), 894);
      expect(searchUsableWidth(1080), 654);
      expect(searchUsableWidth(800), 594);
    });
  });

  group('toolbar draw offsets (NativeHudSearch.cpp:59-127)', () {
    test('derived absolute offsets at 1920', () {
      final Rect bounds = searchModalBounds(1920);
      // bar
      expect(bounds.top + kSearchBarTop, 294);
      expect(bounds.top + kSearchBarTop + kSearchBarHeight, 360);
      // kind tabs
      expect(bounds.top + kSearchTabTop, 374);
      expect(bounds.top + kSearchTabTop + kSearchTabBaselineOffset, 384);
      expect(
        bounds.top + kSearchTabTop + kSearchTabHeight - kSearchTabUnderlineBottomInset,
        407,
      );
      // group tabs
      expect(bounds.top + kSearchTabTop + kSearchGroupBaselineOffset, 385);
      expect(
        bounds.top + kSearchTabTop + kSearchTabHeight - kSearchGroupUnderlineBottomInset,
        408,
      );
      expect(bounds.top + kSearchTabTop + kSearchGroupDividerTopOffset, 380);
      expect(kSearchTabHeight - kSearchGroupDividerBottomInset, 24);
      // table header + rules
      expect(bounds.top + kSearchTableY, 424);
      expect(bounds.top + kSearchTabTop + kSearchTabHeight, 410);
      expect(bounds.top + kSearchTableY + kSearchTableRuleOffset, 440);
      // footer
      expect(bounds.top + kSearchFooterY, 908);
      expect(bounds.top + kSearchFooterY + kSearchFooterGoldTopOffset, 911);
    });
  });
}
