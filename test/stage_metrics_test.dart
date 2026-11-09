// T02 executable reference for docs/flutter-migration/contracts/layout.md.
//
// P0/T02 writes contracts only: there is no product StageMetrics implementation yet
// (plan section 7, T02). These pure functions are therefore the reference form of the
// frozen formulas, and the fixture is their golden data. When T20/T30 land the shared
// StageMetrics, this test must import it and keep the same assertions.
//
// Not executed by T02 (no build/test/analyze allowed); owns only assertions, no product code.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _fixturePath = 'test/fixtures/stage_metrics.json';
const double _stageHeight = 1080.0;
const double _tolerance = 1e-6;

double _asDouble(Object? value) => (value as num).toDouble();

double dprFromDensity(num density) => density / 160.0;
double logicalFromPhysical(num physical, num dpr) => physical / dpr;
double landscapeStageScale(num logicalHeight) => logicalHeight / _stageHeight;
double landscapeStageWidth(num logicalWidth, num scale) => logicalWidth / scale;
double portraitStageScale(num logicalWidth) => logicalWidth / _stageHeight;
double portraitStageHeight(num logicalHeight, num scale) => logicalHeight / scale;
double physicalPerStage(num scale, num dpr) => scale * dpr;
int portraitBandCount(num stageHeight) => (stageHeight / 1080.0).ceil();

Map<String, dynamic> _loadFixture() {
  final file = File(_fixturePath);
  if (!file.existsSync()) {
    fail('missing fixture: ' + file.absolute.path + ' (run from package root)');
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

List<Map<String, dynamic>> _groups(Map<String, dynamic> fixture) =>
    (fixture['groups'] as List).cast<Map<String, dynamic>>();

Map<String, dynamic> _group(Map<String, dynamic> fixture, String id) =>
    _groups(fixture).firstWhere((group) => group['id'] == id);

void _near(num actual, num expected, String reason) {
  expect(actual, closeTo(expected, _tolerance), reason: reason);
}

void _mask(List<dynamic> rgba, double red, double green, double blue, double alpha, String reason) {
  _near(_asDouble(rgba[0]), red, reason + ' red');
  _near(_asDouble(rgba[1]), green, reason + ' green');
  _near(_asDouble(rgba[2]), blue, reason + ' blue');
  _near(_asDouble(rgba[3]), alpha, reason + ' alpha');
}

void main() {
  test('fixture freezes the four required matrices', () {
    final fixture = _loadFixture();
    final ids = _groups(fixture).map((group) => group['id']).toList();
    expect(ids, containsAll(<String>[
      'android-landscape-2880x1800',
      'desktop-landscape-1280x720',
      'android-portrait-1080x2400',
      'android-portrait-1440x3200',
    ]));
    expect(_asDouble(fixture['stageHeight']), _stageHeight);
    expect(_asDouble(fixture['tolerance']), _tolerance);
    final portraitBaseline = fixture['portraitBaseline'] as Map<String, dynamic>;
    expect(portraitBaseline['status'], 'PROPOSED_ARITHMETIC_NOT_DEVICE');
    final topInsets = portraitBaseline['insets'] as Map<String, dynamic>;
    for (final side in <String>['top', 'right', 'bottom', 'left']) {
      _near(_asDouble(topInsets[side]), 0.0, 'fixture portrait inset assumption ' + side);
    }
    for (final group in _groups(fixture)) {
      expect(group['kind'], anyOf('landscape', 'portrait'));
      expect((group['physical'] as List).length, 2);
      expect((group['logical'] as List).length, 2);
      expect(group.containsKey(group['kind'] == 'landscape' ? 'landscape' : 'portrait'), isTrue);
    }
  });

  test('portrait candidates declare three formulas without picking a winner', () {
    final fixture = _loadFixture();
    final candidates = (fixture['portraitCandidates'] as List).cast<Map<String, dynamic>>();
    expect(candidates.map((candidate) => candidate['id'] as String).toList(),
        <String>['Portrait-W', 'Portrait-Band', 'Portrait-Hybrid']);
    for (final candidate in candidates) {
      expect(candidate['stageScale'], 'logicalWidth / 1080', reason: 'candidate scale formula ' + candidate['id']);
      _near(_asDouble(candidate['stageWidth']), 1080.0, 'candidate stage width ' + candidate['id']);
    }
  });

  test('density, dpr and logical conversion match the source', () {
    for (final group in _groups(_loadFixture())) {
      final dpr = _asDouble(group['dpr']);
      final physical = (group['physical'] as List).cast<num>();
      final logical = (group['logical'] as List).cast<num>();
      _near(dpr, dprFromDensity(_asDouble(group['density'])), 'density/160 for ' + group['id']);
      _near(logical[0], logicalFromPhysical(physical[0], dpr), 'logical width for ' + group['id']);
      _near(logical[1], logicalFromPhysical(physical[1], dpr), 'logical height for ' + group['id']);
    }
  });

  test('landscape stage formula is height over 1080', () {
    for (final group in _groups(_loadFixture())) {
      if (group['kind'] != 'landscape') {
        continue;
      }
      final expected = group['landscape'] as Map<String, dynamic>;
      final logical = (group['logical'] as List).cast<num>();
      final dpr = _asDouble(group['dpr']);
      final scale = landscapeStageScale(logical[1]);
      final width = landscapeStageWidth(logical[0], scale);
      _near(expected['stageScale'], scale, 'stageScale for ' + group['id']);
      _near(expected['stageWidth'], width, 'stageWidth for ' + group['id']);
      _near(expected['stageHeight'], _stageHeight, 'stage height for ' + group['id']);
      _near(expected['physicalPerStage'], physicalPerStage(scale, dpr), 'physical scale for ' + group['id']);
      _near(width * scale, logical[0], 'stageWidth * scale for ' + group['id']);
      _near(_stageHeight * physicalPerStage(scale, dpr), (group['physical'] as List)[1],
          'stage height to physical for ' + group['id']);
    }
  });

  test('frozen goldens: 0.846561/1728 and 0.666667/1920', () {
    final fixture = _loadFixture();
    final device = _group(fixture, 'android-landscape-2880x1800')['landscape'] as Map<String, dynamic>;
    final desktop = _group(fixture, 'desktop-landscape-1280x720')['landscape'] as Map<String, dynamic>;
    _near(device['stageScale'], 0.846561, 'device stageScale golden');
    _near(device['stageWidth'], 1728.0, 'device stageWidth golden');
    _near(desktop['stageScale'], 0.666667, 'desktop stageScale golden');
    _near(desktop['stageWidth'], 1920.0, 'desktop stageWidth golden');
    _near(device['stageScale'], 914.2857142857143 / 1080.0, 'device scale from logical height');
    _near(desktop['stageScale'], 720.0 / 1080.0, 'desktop scale from logical height');
  });

  test('portrait candidates share one width-based scale, never the landscape one', () {
    final fixture = _loadFixture();
    final landscapeScaleOfPortraitHeight = landscapeStageScale(914.2857142857143);
    for (final group in _groups(fixture)) {
      if (group['kind'] != 'portrait') {
        continue;
      }
      final expected = group['portrait'] as Map<String, dynamic>;
      final logical = (group['logical'] as List).cast<num>();
      final dpr = _asDouble(group['dpr']);
      final scale = portraitStageScale(logical[0]);
      final height = portraitStageHeight(logical[1], scale);
      _near(expected['stageScale'], scale, 'portrait scale for ' + group['id']);
      _near(expected['stageWidth'], 1080.0, 'portrait stage width for ' + group['id']);
      _near(expected['stageHeight'], height, 'portrait stage height for ' + group['id']);
      _near(expected['physicalPerStage'], physicalPerStage(scale, dpr), 'portrait physical scale for ' + group['id']);
      _near(expected['bandHeight'], 1080.0, 'band height for ' + group['id']);
      expect(expected['bandCount'], portraitBandCount(height), reason: 'band count for ' + group['id']);
      _near(expected['topBar'], 96.0, 'top bar for ' + group['id']);
      _near(expected['bottomBar'], 96.0, 'bottom bar for ' + group['id']);
      _near(expected['contentHeight'], height - 192.0, 'hybrid content for ' + group['id']);
      final insets = expected['insets'] as Map<String, dynamic>;
      final available = logical[1] - _asDouble(insets['top']) - _asDouble(insets['bottom']);
      expect(expected['baselineStatus'], 'PROPOSED_ARITHMETIC_NOT_DEVICE',
          reason: 'portrait matrix is arithmetic, not a device baseline for ' + group['id']);
      _near(expected['stageHeight'], available / scale,
          'stageHeight derives from available logical height for ' + group['id']);
    }

    final portraitGroup = _group(fixture, 'android-portrait-1080x2400');
    final portraitScale = portraitStageScale((portraitGroup['logical'] as List)[0]);
    expect(portraitScale, isNot(closeTo(landscapeScaleOfPortraitHeight, _tolerance)),
        reason: 'portrait must not reuse the landscape height/1080 formula');
    expect(portraitScale, closeTo(0.38095238095238093, _tolerance));
  });

  test('layout constants are internally consistent and match Qt source', () {
    final layout = _loadFixture()['layout'] as Map<String, dynamic>;
    final playerBar = layout['playerBar'] as Map<String, dynamic>;
    _near(_asDouble(layout['contentBottom']), 984.0, 'content bottom');
    _near(_asDouble(playerBar['top']) + _asDouble(playerBar['height']), 1080.0, 'player bar fills to stage bottom');
    _near(_asDouble(playerBar['inputTop']) + _asDouble(playerBar['inputHeight']), 1080.0,
        'player input band: 978 + 102, not 978 + 96');
    _near(_asDouble(playerBar['inputHeight']), _asDouble(playerBar['height']) + 6.0,
        'input band height is the 96 row grown by 6');
    _near(_asDouble(playerBar['inputHeight']), _asDouble(playerBar['inputBottom']) - _asDouble(playerBar['inputTop']),
        'input band bottom stays at stage bottom');
    _near(_asDouble(playerBar['seekTop']) + _asDouble(playerBar['seekHeight']), 996.0, 'seek band');

    final modal = layout['modal'] as Map<String, dynamic>;
    _near(_asDouble(modal['top']) + _asDouble(modal['height']), 958.0, 'modal panel ends above player bar');
    expect(_asDouble(modal['top']) + _asDouble(modal['height']), lessThan(_asDouble(layout['contentBottom'])),
        reason: 'modal bottom 958 stays above content bottom 984');
    _near(_asDouble(modal['searchRightInset']), 59.0, 'search modal right inset');
    expect(_asDouble(modal['searchMinWidth']), lessThanOrEqualTo(_asDouble(modal['searchMaxWidth'])));

    final searchList = layout['searchList'] as Map<String, dynamic>;
    _near(_asDouble(searchList['topInset']) + _asDouble(searchList['height']), 758.0, 'result viewport bottom');

    final input = layout['input'] as Map<String, dynamic>;
    _near(_asDouble(input['topInset']), 180.0, 'input top inset');
    _near(_asDouble(input['height']), 54.0, 'input height');
    _near(_asDouble(input['xInset']), 53.0, 'input x inset');
    _near(_asDouble(input['leftPadding']) + _asDouble(input['rightPadding']), 32.0, 'input padding');

    final form = layout['form'] as Map<String, dynamic>;
    _near(_asDouble(form['accountTopInset']) + _asDouble(form['accountHeight']), 485.0, 'account bottom');
    _near(_asDouble(form['captchaTopInset']) + _asDouble(form['captchaHeight']), 596.0, 'captcha bottom');

    // Overlay.qml:449 subtracts 28 * stageScale from parent.width = inputWidth * stageScale.
    const double formInputWidth = 1154.0;
    const double formScale = 0.8465608465608465;
    final double captchaInset = _asDouble(form['captchaWidthInset']);
    _near(captchaInset, 28.0, 'captcha width inset is a stage constant');
    _near(_asDouble(form['captchaTextXInset']), 14.0, 'captcha text x inset');
    _near((formInputWidth - captchaInset) * formScale,
        formInputWidth * formScale - captchaInset * formScale, 'captcha inset is scaled with the parent');
    expect(formInputWidth * formScale - captchaInset,
        isNot(closeTo((formInputWidth - captchaInset) * formScale, _tolerance)),
        reason: 'subtracting 28 logical px instead of 28 * scale is a different width');
    _near(_asDouble(form['submitWidth']), _asDouble(form['sendWidth']), 'submit/send share width');

    final volume = playerBar['volume'] as Map<String, dynamic>;
    _near(_asDouble(volume['width']), 100.0, 'volume width');
    _near(_asDouble(volume['height']), 28.0, 'volume height');
    _near(_asDouble(volume['rightInset']) - _asDouble(volume['dxFromOutput']), 242.0,
        'volume x is outputX + 58');
    _near(_asDouble(playerBar['top']) + _asDouble(volume['dy']), 1031.0, 'volume y');

    final camera = layout['camera'] as Map<String, dynamic>;
    _near(_asDouble(camera['portraitAspectThreshold']), 1.05, 'camera portrait aspect threshold');
    _near(_asDouble(camera['compactWidthThreshold']), 1100.0, 'camera compact width threshold');
    _near(_asDouble(camera['perspectiveNear']), 5.0, 'camera perspective near');
    _near(_asDouble(camera['perspectiveFar']), 300.0, 'camera perspective far');

    final viewport = layout['settingsViewport'] as Map<String, dynamic>;
    _near(_asDouble(viewport['topInset']), 176.0, 'settings viewport top');
    _near(_asDouble(viewport['bottomInset']), 836.0, 'settings viewport bottom');
    _near(_asDouble(layout['touchHitPadding']), 16.0, 'android touch expansion');

    final masks = layout['modalMask'] as Map<String, dynamic>;
    final panelMask = masks['panel'] as Map<String, dynamic>;
    final searchMask = masks['search'] as Map<String, dynamic>;
    expect((panelMask['dark'] as List)[3], greaterThan((searchMask['dark'] as List)[3] as num));
    expect((panelMask['light'] as List)[3], greaterThan((searchMask['light'] as List)[3] as num));
  });

  test('doc section 9 exact layout constants are pinned', () {
    final layout = _loadFixture()['layout'] as Map<String, dynamic>;
    final playerBar = layout['playerBar'] as Map<String, dynamic>;
    _near(_asDouble(playerBar['height']), 96.0, 'player bar row height');
    _near(_asDouble(playerBar['seekTop']), 978.0, 'seek top');
    _near(_asDouble(playerBar['seekHeight']), 18.0, 'seek height');

    final volume = playerBar['volume'] as Map<String, dynamic>;
    _near(_asDouble(playerBar['top']) + _asDouble(volume['dy']) + _asDouble(volume['height']), 1059.0,
        'volume bottom is 1031 + 28');

    final modal = layout['modal'] as Map<String, dynamic>;
    _near(_asDouble(modal['defaultMaxWidth']), 1260.0, 'default modal max width');
    _near(_asDouble(modal['sideInset']), 50.0, 'narrow default modal is centred with 50 per side');

    final searchList = layout['searchList'] as Map<String, dynamic>;
    _near(_asDouble(searchList['rowHeight']), 72.0, 'result row height (NativeHud.h:98)');
    _near(_asDouble(searchList['widthInset']), 106.0, 'result list width inset');

    final input = layout['input'] as Map<String, dynamic>;
    _near(_asDouble(input['widthInset']), 106.0, 'input width inset');
    _near(_asDouble(input['fontSize']), 22.0, 'input font size (Overlay.qml:533)');

    final form = layout['form'] as Map<String, dynamic>;
    _near(_asDouble(form['accountWidthInsetLogin']), 208.0, 'account width inset login (Overlay.qml:389)');
    _near(_asDouble(form['accountWidthInsetForm']), 28.0, 'account width inset form (Overlay.qml:389)');
    _near(_asDouble(form['accountTextXInset']), 14.0, 'account text x inset (Overlay.qml:387)');
    _near(_asDouble(form['captchaHeight']), 55.0, 'captcha field height');
    _near(_asDouble(form['sendHeight']), 55.0, 'send button height');
    _near(_asDouble(form['submitHeight']), 36.0, 'submit button height');
    _near(_asDouble(form['submitLoginTopInset']), 611.0, 'submit top inset login (Overlay.qml:464)');
    _near(_asDouble(form['submitFormTopInset']), 530.0, 'submit top inset form (Overlay.qml:464)');

    final masks = layout['modalMask'] as Map<String, dynamic>;
    final searchMask = masks['search'] as Map<String, dynamic>;
    final panelMask = masks['panel'] as Map<String, dynamic>;
    _mask(searchMask['dark'] as List<dynamic>, 17, 24, 27, 0.15, 'search dark mask (NativeHudModal.cpp:163-165)');
    _mask(searchMask['light'] as List<dynamic>, 227, 224, 215, 0.12, 'search light mask (NativeHudModal.cpp:163-165)');
    _mask(panelMask['dark'] as List<dynamic>, 17, 24, 27, 0.60, 'saved/other panel dark mask (NativeHudModal.cpp:163-165)');
    _mask(panelMask['light'] as List<dynamic>, 227, 224, 215, 0.45, 'saved/other panel light mask (NativeHudModal.cpp:163-165)');
  });

  test('rotation recompute yields a new portrait stage without reusing old hit geometry', () {
    final fixture = _loadFixture();
    final logical = (_group(fixture, 'android-landscape-2880x1800')['logical'] as List).cast<num>();
    // Rotate the view: width becomes the old height and vice versa.
    final rotatedWidth = logical[1];
    final rotatedHeight = logical[0];
    final scale = portraitStageScale(rotatedWidth);
    _near(scale, 0.8465608465608466, 'rotated portrait scale');
    _near(portraitStageHeight(rotatedHeight, scale), 1728.0, 'rotated portrait stage height');
    expect(scale, isNot(closeTo(landscapeStageScale(rotatedHeight), _tolerance)),
        reason: 'rotation must switch formula, not keep the landscape one');
    expect(portraitStageHeight(rotatedHeight, scale), isNot(closeTo(1080.0, _tolerance)),
        reason: 'portrait stage height is derived, not fixed at 1080');
  });
}
