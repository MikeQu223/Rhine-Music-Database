// WRITTEN, NEVER EXECUTED.
//
// Revised by atom T40-C18-F3-PICKERFIX: tests J and M under-counted the hits by
// omitting the header back button that Qt paints on every generic modal
// (Qt/src/NativeHudModal.cpp:199-200) and hit-registers before its fill
// (Qt/src/NativeHud.cpp:112). Both counts are corrected against the Qt source; this
// file is still authored-and-statically-reviewed only, never executed.
//
// Part of atom T40-C14-A3-PICKER. This test file is authored and statically reviewed
// only; no flutter/dart process was started for this atom, so its RED/GREEN status is
// UNEXECUTED, not "passing". The command that would run it, from the tree root
// /home/aibeto/code/Rhine-Music-Database/.agents/parity-20261109/worktrees/T40 :
//
//   flutter test test/hud/t40/playlist_picker_test.dart
//
// Every expected number, string and action below is transcribed from the Qt source
// (Qt/src/NativeHudModal.cpp, Qt/src/NativeHud.cpp, Qt/src/NativeHud.h,
// Qt/src/NativeHudController.cpp, Qt/src/NativeHudMusic.cpp, Qt/src/UiMotion.*) and
// each expectation carries the Qt file:line it comes from. Nothing here is derived
// from the Dart port's own output.
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/playlist_picker.dart';

// --- fixtures ---------------------------------------------------------------

/// Deterministic stand-in for Qt `Glyphs::width(text, size, weight)`
/// (`Qt/src/NativeHud.cpp:57`). Half an em per code unit keeps every label in the
/// default fixture short enough to stay untruncated; [tracking] is added linearly
/// because the port threads it through the injected measurer.
double _measure(String text, double size, String? weight, double tracking) =>
    text.length * size * 0.5 + tracking * text.length;

/// One em per code unit, so `fit()` truncation is arithmetically predictable and the
/// Qt rule `value.left(max(0, length - 1)) + "…"` (`Qt/src/NativeHud.cpp:71-73`) can
/// be asserted exactly rather than approximately.
double _wideMeasure(String text, double size, String? weight, double tracking) =>
    text.length * size;

List<double> _identity(double x, double y, double w, double h) =>
    <double>[x, y, w, h];

List<PlaylistPickerRow> _rows(int count, {Set<int> readOnly = const <int>{}}) =>
    <PlaylistPickerRow>[
      for (int i = 0; i < count; i++)
        PlaylistPickerRow(
          id: 'pl-$i',
          title: 'PLAYLIST $i',
          editable: !readOnly.contains(i),
        ),
    ];

PlaylistPickerModal _picker({
  double width = 1920,
  bool dark = true,
  bool reduced = false,
  bool closing = false,
  bool search = false,
  double opacity = 1,
  double offset = 0,
  String provider = 'netease',
  String status = 'ok',
  int listOffset = 0,
  List<PlaylistPickerRow>? playlists,
  PlaylistPickerMeasureText measureText = _measure,
  PlaylistPickerRectHook rectHook = _identity,
}) =>
    PlaylistPickerModal(
      width: width,
      dark: dark,
      reduced: reduced,
      closing: closing,
      search: search,
      opacity: opacity,
      offset: offset,
      provider: provider,
      status: status,
      listOffset: listOffset,
      playlists: playlists ?? _rows(3),
      measureText: measureText,
      rectHook: rectHook,
    );

double _d(List<Object?> command, int index) => command[index]! as double;

/// `NativeHud::ink` dark (`Qt/src/NativeHud.cpp:10-15`).
const List<Object?> _darkInk = <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite'];

/// `NativeHud::ink` light (`Qt/src/NativeHud.cpp:10-15`).
const List<Object?> _lightInk = <Object?>[0.08, 0.085, 0.075, 1, 'calibratedRGB'];

void main() {
  // -------------------------------------------------------------------------
  // Layer order / envelope
  // -------------------------------------------------------------------------

  test('A. envelope: save, alpha, scrim, translate, panel ... restore, in Qt order', () {
    final PlaylistPickerFrame frame = _picker().build();
    // 23 commands for the default fixture (3 editable rows, no QQ empty state):
    // save + alpha + scrim + translate + panel + 2 header words + subtitle
    // + body title + 3*(tint + label) + 2*(tint + label) + status + restore.
    expect(frame.commands.length, 23);
    expect(
        frame.commands.where((List<Object?> c) => c[0] == 'fill').length, 8,
        reason: 'scrim + panel + 1 back + 3 rows + 2 pager tints');
    expect(
        frame.commands.where((List<Object?> c) => c[0] == 'text').length, 11,
        reason: 'category, back, title, subtitle, body title, 3 rows, 2 pager, status');

    // Qt/src/NativeHud.cpp:19-21 + Qt/src/NativeHudModal.cpp:81.
    expect(frame.commands[0], <Object?>['save']);
    // Qt/src/NativeHudModal.cpp:83-84 (the whole modal inherits motion.opacity).
    expect(frame.commands[1], <Object?>['alpha', 1.0]);
    // Qt/src/NativeHudModal.cpp:163-165: full 1080 stage, dark 17/24/27 at 0.6.
    // Emitted BEFORE the offset translate, so the scrim does not travel.
    expect(frame.commands[2], <Object?>[
      'fill',
      <Object?>[17 / 255, 24 / 255, 27 / 255, 0.6],
      0.0,
      0.0,
      1920.0,
      1080.0,
    ]);
    // Qt/src/NativeHudModal.cpp:166.
    expect(frame.commands[3], <Object?>['translate', 0.0, 0.0]);
    // Qt/src/NativeHud.cpp:153,157,158 -> modalWidth 1260, left 330, y 122, h 836;
    // Qt/src/NativeHudModal.cpp:171-172 -> the panel fill, dark 0.15 calibratedWhite.
    expect(frame.commands[4], <Object?>[
      'fill',
      <Object?>[0.15, 0.15, 0.15, 1, 'calibratedWhite'],
      330.0,
      122.0,
      1260.0,
      836.0,
    ]);
    // Qt/src/NativeHudModal.cpp:255-256.
    expect(frame.commands[22], <Object?>['restore']);
  });

  test('B. panel bounds are min(1260, width - 100) centred, y 122, h 836', () {
    // Qt/src/NativeHud.cpp:153 modalWidth = min(1260, width - 100)
    // Qt/src/NativeHud.cpp:157 left = (width - modalWidth) / 2
    // Qt/src/NativeHud.cpp:158 rect = {left, 122, modalWidth, 836}
    for (final List<double> probe in <List<double>>[
      <double>[1920, 1260, 330],
      <double>[1000, 900, 50],
      <double>[2400, 1260, 570],
      <double>[800, 700, 50],
    ]) {
      final double width = probe[0];
      final double modalWidth = probe[1];
      final double left = probe[2];
      final PlaylistPickerFrame frame = _picker(width: width).build();
      final List<Object?> panel = frame.commands[4];
      expect(_d(panel, 2), left,
          reason: 'left = (width - modalWidth) / 2 at width $width');
      expect(_d(panel, 3), 122.0, reason: 'Qt rect y literal');
      expect(_d(panel, 4), modalWidth, reason: 'min(1260, width - 100)');
      expect(_d(panel, 5), 836.0, reason: 'Qt rect height literal');
      expect(_d(frame.commands[2], 4), width,
          reason: 'the scrim spans the whole width');
      expect(_d(frame.commands[2], 5), 1080.0,
          reason: 'the stage is 1080 tall');
      // usable - 106 is the row width (Qt/src/NativeHudModal.cpp:234-235).
      expect(_d(frame.hits[1], 2), modalWidth - 106,
          reason: 'row width = usable - 106');
      expect(_d(frame.hits[1], 0), left + 53,
          reason: 'row x = panel x + 53');
    }
  });

  // -------------------------------------------------------------------------
  // Header
  // -------------------------------------------------------------------------

  test('C. header: category, back button, title, subtitle at Qt offsets', () {
    final PlaylistPickerFrame frame = _picker().build();
    // Qt/src/NativeHudModal.cpp:188 default category + :198
    // text('RHINE LAB / MUSIC DATABASE / " + category, x + 53, y + 37, 11)
    // size 11 is the non-settings branch (:198 'settings ? 14 : 11').
    expect(frame.commands[5], <Object?>[
      'text',
      'RHINE LAB / MUSIC DATABASE / MUSIC DIRECTORY',
      383.0,
      159.0,
      11.0,
      'regular',
      0.0,
      _darkInk,
    ]);
    // Qt/src/NativeHudModal.cpp:199-200 button('← 返回', x + usable - 220, y + 18,
    // 167, 54, 'close-modal', 20, 'demibold'); tint from Qt/src/NativeHud.cpp:114-117.
    expect(frame.commands[6], <Object?>[
      'fill',
      <Object?>[0.55, 0.59, 0.46, 0.13],
      1370.0,
      140.0,
      167.0,
      54.0,
    ]);
    // Qt/src/NativeHud.cpp:110-120: inset = min(10, 167 / 8) = 10, so x + 10;
    // y + (54 - 20) / 2 - 4 = y + 13; label refit to 167 - 20 = 147.
    expect(frame.commands[7], <Object?>[
      'text',
      '← 返回',
      1380.0,
      153.0,
      20.0,
      'demibold',
      0.0,
      _darkInk,
    ]);
    // Qt/src/NativeHudModal.cpp:36 + :201 text(title, x + 53, y + 91, 38, 'demibold').
    expect(frame.commands[8], <Object?>[
      'text',
      'PLAYLIST DIRECTORY',
      383.0,
      213.0,
      38.0,
      'demibold',
      0.0,
      _darkInk,
    ]);
    // Qt/src/NativeHudModal.cpp:61 + :202 text(subtitle, x + 53, y + 147, 15)
    // (size 15 is the non-settings branch).
    expect(frame.commands[9], <Object?>[
      'text',
      '添加到我的歌单',
      383.0,
      269.0,
      15.0,
      'regular',
      0.0,
      _darkInk,
    ]);
  });

  // -------------------------------------------------------------------------
  // Body: rows, pager, status
  // -------------------------------------------------------------------------

  test('D. body rows: x + 53, y + 290 + index * 60, usable - 106 wide, 52 tall, size 18', () {
    final PlaylistPickerFrame frame = _picker().build();
    // Qt/src/NativeHudModal.cpp:223 text('选择我的歌单', x + 53, y + 240, 18).
    expect(frame.commands[10], <Object?>[
      'text',
      '选择我的歌单',
      383.0,
      362.0,
      18.0,
      'regular',
      0.0,
      _darkInk,
    ]);
    // Qt/src/NativeHudModal.cpp:229-236.
    for (int index = 0; index < 3; index++) {
      final int fillIndex = 11 + index * 2;
      expect(frame.commands[fillIndex], <Object?>[
        'fill',
        <Object?>[0.55, 0.59, 0.46, 0.13],
        383.0,
        412.0 + index * 60,
        1154.0,
        52.0,
      ], reason: 'row $index tint at y + 290 + index * 60');
      expect(frame.commands[fillIndex + 1], <Object?>[
        'text',
        'PLAYLIST $index',
        393.0,
        425.0 + index * 60,
        18.0,
        'regular',
        0.0,
        _darkInk,
      ], reason: 'row $index label at x + 53 + 10, y + (52 - 18) / 2 - 4');
    }
  });

  test('E. pager and status line: usable - 330 / usable - 190 at y + 758, status at y + 775', () {
    final PlaylistPickerFrame frame = _picker().build();
    // Qt/src/NativeHudModal.cpp:237 button('↑ 上一页', x + usable - 330, y + 758, 120, 32,
    // 'music:picker-prev', 12); inset min(10, 120 / 8) = 10; y + (32 - 12) / 2 - 4 = y + 6.
    expect(frame.commands[17], <Object?>[
      'fill',
      <Object?>[0.55, 0.59, 0.46, 0.13],
      1260.0,
      880.0,
      120.0,
      32.0,
    ]);
    expect(frame.commands[18], <Object?>[
      'text',
      '↑ 上一页',
      1270.0,
      886.0,
      12.0,
      'regular',
      0.0,
      _darkInk,
    ]);
    // Qt/src/NativeHudModal.cpp:238.
    expect(frame.commands[19], <Object?>[
      'fill',
      <Object?>[0.55, 0.59, 0.46, 0.13],
      1400.0,
      880.0,
      120.0,
      32.0,
    ]);
    expect(frame.commands[20], <Object?>[
      'text',
      '下一页 ↓',
      1410.0,
      886.0,
      12.0,
      'regular',
      0.0,
      _darkInk,
    ]);
    // Qt/src/NativeHudModal.cpp:239 limited(status, x + 53, y + 775, 12, usable - 420);
    // Qt/src/NativeHud.cpp:77-79 -> a plain text() command, no fill.
    expect(frame.commands[21], <Object?>[
      'text',
      'ok',
      383.0,
      897.0,
      12.0,
      'regular',
      0.0,
      _darkInk,
    ]);
  });

  // -------------------------------------------------------------------------
  // Hits
  // -------------------------------------------------------------------------

  test('F. hits: exactly 6 entries of exactly 6 fields, appended in draw order', () {
    final PlaylistPickerFrame frame = _picker().build();
    expect(frame.hits.length, 6);
    for (final List<Object?> hit in frame.hits) {
      // Qt/src/NativeHud.cpp:102-109: [x, y, width, height, action, label].
      expect(hit.length, 6);
      expect(hit[0], isA<double>());
      expect(hit[1], isA<double>());
      expect(hit[2], isA<double>());
      expect(hit[3], isA<double>());
      expect(hit[4], isA<String>());
      expect(hit[5], isA<String>(), reason: 'label never null: it falls back to action');
    }
    expect(frame.hits[0], <Object?>[1370.0, 140.0, 167.0, 54.0, 'close-modal', '← 返回']);
    expect(frame.hits[1],
        <Object?>[383.0, 412.0, 1154.0, 52.0, 'music:playlist-pick:pl-0', 'PLAYLIST 0']);
    expect(frame.hits[2],
        <Object?>[383.0, 472.0, 1154.0, 52.0, 'music:playlist-pick:pl-1', 'PLAYLIST 1']);
    expect(frame.hits[3],
        <Object?>[383.0, 532.0, 1154.0, 52.0, 'music:playlist-pick:pl-2', 'PLAYLIST 2']);
    expect(frame.hits[4],
        <Object?>[1260.0, 880.0, 120.0, 32.0, 'music:picker-prev', '↑ 上一页']);
    expect(frame.hits[5],
        <Object?>[1400.0, 880.0, 120.0, 32.0, 'music:picker-next', '下一页 ↓']);
  });

  test('G. no outside-click catcher and no popover branch: the base layer keeps its hits', () {
    final PlaylistPickerFrame frame = _picker().build();
    // The full-stage catcher exists only for detail-sort (Qt/src/NativeHudModal.cpp:128).
    expect(
        frame.hits.where((List<Object?> hit) => hit[0] == 0.0 && hit[2] == 1920.0),
        isEmpty,
        reason: 'this modal paints a scrim but never hit-tests it; nothing clears the hits');
    // A one-row page proves the count is 3 controls + the visible rows (no phantom hits).
    expect(_picker(playlists: _rows(1)).build().hits.length, 4);
  });

  // -------------------------------------------------------------------------
  // Actions and the close path
  // -------------------------------------------------------------------------

  test('H. action table: strings, Escape mapping, and the absence of 取消 / a catcher', () {
    // Qt/src/NativeHudModal.cpp:200 -> 'close-modal' (not 'desktop-lyrics:back', :199).
    expect(PlaylistPickerActionTable.closeModal, 'close-modal');
    // Qt/src/NativeHudModal.cpp:234 -> 'music:playlist-pick:' + id.
    expect(PlaylistPickerActionTable.pickPrefix, 'music:playlist-pick:');
    expect(PlaylistPickerActionTable.pick('pl-1'), 'music:playlist-pick:pl-1');
    // Qt/src/NativeHudModal.cpp:237-238.
    expect(PlaylistPickerActionTable.pagePrev, 'music:picker-prev');
    expect(PlaylistPickerActionTable.pageNext, 'music:picker-next');
    // Qt/src/NativeHudModal.cpp:229 -> index < 7, so the pager stride is 7
    // (Qt/src/NativeHudMusic.cpp:255-258 moves listOffset by ±7).
    expect(PlaylistPickerActionTable.pageStride, 7);
    // Qt/src/NativeHudController.cpp:913-922: with a non-empty modal that is not
    // desktop-lyrics, Escape is 'close-modal' and nothing else is produced.
    expect(PlaylistPickerActionTable.keyActions,
        <String, String>{'Escape': 'close-modal'});
    // Qt/src/NativeHudController.cpp:923-925: every other key is swallowed while a
    // modal is open, so the table has exactly one entry.
    expect(PlaylistPickerActionTable.keyActions.length, 1);
    // '取消' is the confirm modal's label (Qt/src/NativeHudModal.cpp:221); this body
    // has no cancel affordance at all, so no command may paint it.
    final PlaylistPickerFrame frame = _picker().build();
    expect(
        frame.commands
            .where((List<Object?> c) => c[0] == 'text' && c[1] == '取消'),
        isEmpty);
  });

  test('I. every emitted action string is one of the four Qt strings', () {
    final PlaylistPickerFrame frame = _picker().build();
    expect(
        frame.hits.map((List<Object?> hit) => hit[4]).toList(),
        <Object?>[
          'close-modal',
          'music:playlist-pick:pl-0',
          'music:playlist-pick:pl-1',
          'music:playlist-pick:pl-2',
          'music:picker-prev',
          'music:picker-next',
        ]);
  });

  // -------------------------------------------------------------------------
  // Windowing (listOffset), QQ gating, empty state
  // -------------------------------------------------------------------------

  test('J. visible window is [listOffset, listOffset + 7) and never wraps', () {
    final PlaylistPickerFrame page =
        _picker(playlists: _rows(12), listOffset: 5).build();
    // Qt/src/NativeHudModal.cpp:229 'index < 7 && listOffset + index < size'.
    expect(page.hits.length, 10, reason: '1 back + 7 rows + 2 pager');
    expect(page.hits[1][5], 'PLAYLIST 5');
    expect(page.hits[7][5], 'PLAYLIST 11');
    expect(_d(page.hits[1], 1), 412.0,
        reason: 'the window is re-based on index 0, not on the absolute row');

    final PlaylistPickerFrame tail =
        _picker(playlists: _rows(12), listOffset: 8).build();
    expect(tail.hits.length, 7, reason: '1 back + 4 rows + 2 pager');
    expect(tail.hits[4][5], 'PLAYLIST 11');

    // An empty list still paints the header back button: Qt/src/NativeHudModal.cpp:199-200
    // runs before the :222-239 body on every generic modal, and Qt/src/NativeHud.cpp:112
    // appends the hit before the fill, so the empty page hit-tests 1 back + 2 pager = 3.
    final PlaylistPickerFrame none = _picker(
      playlists: <PlaylistPickerRow>[],
      listOffset: 0,
    ).build();
    expect(none.hits.length, 3, reason: '1 back + 0 rows + 2 pager');
    expect(none.hits[0],
        <Object?>[1370.0, 140.0, 167.0, 54.0, 'close-modal', '← 返回'],
        reason: 'x + usable - 220, y + 18, 167x54 (Qt/src/NativeHudModal.cpp:199)');
    expect(none.hits[1],
        <Object?>[1260.0, 880.0, 120.0, 32.0, 'music:picker-prev', '↑ 上一页'],
        reason: 'x + usable - 330, y + 758, 120x32 (Qt/src/NativeHudModal.cpp:237)');
    expect(none.hits[2],
        <Object?>[1400.0, 880.0, 120.0, 32.0, 'music:picker-next', '下一页 ↓'],
        reason: 'x + usable - 190, y + 758, 120x32 (Qt/src/NativeHudModal.cpp:238)');
  });

  test('K. qq: a non-editable row is skipped but its index slot is still consumed', () {
    // Qt/src/NativeHudModal.cpp:231-233 'continue' after ++index.
    final PlaylistPickerFrame frame = _picker(
      provider: 'qq',
      playlists: <PlaylistPickerRow>[
        PlaylistPickerRow(id: 'q0', title: 'READONLY', editable: false),
        PlaylistPickerRow(id: 'q1', title: 'MINE', editable: true),
      ],
    ).build();
    expect(frame.hits.length, 4, reason: '1 back + 1 row + 2 pager');
    expect(frame.hits[1],
        <Object?>[383.0, 472.0, 1154.0, 52.0, 'music:playlist-pick:q1', 'MINE'],
        reason: 'the skipped row still consumes index 0, so the kept row is at +60');
    // One editable row exists, so the QQ empty state must NOT be painted (:224-228).
    expect(
        frame.commands.where((List<Object?> c) =>
            c[0] == 'text' && c[1] == '暂无可编辑的自建普通歌单，请先创建歌单。'),
        isEmpty);
  });

  test('L. non-qq: read-only rows are painted', () {
    // Qt/src/NativeHudModal.cpp:231 gates the skip on provider == 'qq' only.
    final PlaylistPickerFrame frame = _picker(
      provider: 'netease',
      playlists: _rows(2, readOnly: <int>{0}),
    ).build();
    expect(frame.hits.length, 5, reason: '1 back + 2 rows + 2 pager');
    expect(frame.hits[1][4], 'music:playlist-pick:pl-0');
    expect(frame.hits[2][4], 'music:playlist-pick:pl-1');
  });

  test('M. qq empty state at y + 320, size 16; the header back button and the pager stay hit-testable', () {
    final PlaylistPickerFrame frame = _picker(
      provider: 'qq',
      playlists: <PlaylistPickerRow>[
        PlaylistPickerRow(id: 'q0', title: 'READONLY', editable: false),
      ],
    ).build();
    // Qt/src/NativeHudModal.cpp:227 text('暂无可编辑的自建普通歌单，请先创建歌单。', x + 53, y + 320, 16).
    // Recount (unchanged by MF-2): 18 = save + alpha + scrim + translate + panel
    // + category + back(fill + text) + title + subtitle + body title + empty state
    // + prev(fill + text) + next(fill + text) + status + restore. The header back
    // button was already inside this count; only its *hit* was missing.
    expect(frame.commands.length, 18);
    expect(frame.commands[11], <Object?>[
      'text',
      '暂无可编辑的自建普通歌单，请先创建歌单。',
      383.0,
      442.0,
      16.0,
      'regular',
      0.0,
      _darkInk,
    ]);
    // provider == 'qq' gates only the row loop (Qt/src/NativeHudModal.cpp:231) and the
    // empty state (:224-228). The header back button is painted for every generic
    // modal at :199-200 before the body, so it stays hit-testable here and stays
    // first (Qt/src/NativeHud.cpp:112 appends the hit before the fill).
    expect(frame.hits.map((List<Object?> hit) => hit[4]).toList(),
        <Object?>['close-modal', 'music:picker-prev', 'music:picker-next']);
    expect(frame.hits[0],
        <Object?>[1370.0, 140.0, 167.0, 54.0, 'close-modal', '← 返回'],
        reason: 'the empty body never displaces the header hit');
  });

  // -------------------------------------------------------------------------
  // Theme, search flag, closing
  // -------------------------------------------------------------------------

  test('N. light theme colours come from the same Qt branches', () {
    final PlaylistPickerFrame frame = _picker(dark: false).build();
    // Qt/src/NativeHudModal.cpp:164-165 light 227/224/215 at 0.45.
    expect(frame.commands[2], <Object?>[
      'fill',
      <Object?>[227 / 255, 224 / 255, 215 / 255, 0.45],
      0.0,
      0.0,
      1920.0,
      1080.0,
    ]);
    // Qt/src/NativeHudModal.cpp:171-172 light 0.929/0.922/0.894 at 1, no colour space.
    expect(frame.commands[4], <Object?>[
      'fill',
      <Object?>[0.929, 0.922, 0.894, 1],
      330.0,
      122.0,
      1260.0,
      836.0,
    ]);
    // Qt/src/NativeHud.cpp:114-117 light tint 0.44/0.49/0.36 at 0.1.
    expect(frame.commands[6], <Object?>[
      'fill',
      <Object?>[0.44, 0.49, 0.36, 0.1],
      1370.0,
      140.0,
      167.0,
      54.0,
    ]);
    // Qt/src/NativeHud.cpp:10-15 light ink.
    expect(frame.commands[5][7], _lightInk);
  });

  test('O. the injected search flag only changes the scrim alpha and the panel colour', () {
    final PlaylistPickerFrame dark = _picker(search: true).build();
    // Qt/src/NativeHudModal.cpp:164 'search ? 0.15 : 0.6'.
    expect(dark.commands[2], <Object?>[
      'fill',
      <Object?>[17 / 255, 24 / 255, 27 / 255, 0.15],
      0.0,
      0.0,
      1920.0,
      1080.0,
    ]);
    // Qt/src/NativeHud.cpp:154-157 is the search bounds branch; a playlist picker
    // never takes it, so the panel geometry is the generic one.
    expect(_d(dark.commands[4], 4), 1260.0);
    final PlaylistPickerFrame light = _picker(search: true, dark: false).build();
    expect(light.commands[2], <Object?>[
      'fill',
      <Object?>[227 / 255, 224 / 255, 215 / 255, 0.12],
      0.0,
      0.0,
      1920.0,
      1080.0,
    ]);
  });

  test('P. closing repaints the identical frame until the curve finishes', () {
    // Qt/src/NativeHud.cpp:262-266 keeps drawing the modal while closing && !finished.
    expect(_picker(closing: true).build().commands,
        _picker(closing: false).build().commands);
    expect(_picker(closing: true).build().hits, _picker(closing: false).build().hits);
  });

  // -------------------------------------------------------------------------
  // Injected placement hook
  // -------------------------------------------------------------------------

  test('Q. rectHook maps the scrim and the panel once; the interior follows the mapped origin', () {
    List<double> hook(double x, double y, double w, double h) =>
        <double>[x + 10, y + 20, w - 40, h + 30];
    final PlaylistPickerFrame frame = _picker(rectHook: hook).build();
    expect(frame.commands[2], <Object?>[
      'fill',
      <Object?>[17 / 255, 24 / 255, 27 / 255, 0.6],
      10.0,
      20.0,
      1880.0,
      1110.0,
    ]);
    // The hook's height is ignored by the panel fill: Qt paints the literal 836
    // (Qt/src/NativeHudModal.cpp:171), while the width follows `usable`.
    expect(frame.commands[4], <Object?>[
      'fill',
      <Object?>[0.15, 0.15, 0.15, 1, 'calibratedWhite'],
      340.0,
      142.0,
      1220.0,
      836.0,
    ]);
    expect(frame.commands[5][2], 393.0, reason: 'mapped panel x + 53');
    expect(frame.commands[5][3], 179.0, reason: 'mapped panel y + 37');
    expect(frame.hits[0],
        <Object?>[1340.0, 160.0, 167.0, 54.0, 'close-modal', '← 返回']);
    expect(frame.hits[4],
        <Object?>[1230.0, 900.0, 120.0, 32.0, 'music:picker-prev', '↑ 上一页']);
    // Interior rects are authored from the mapped origin, never mapped twice.
    expect(_d(frame.hits[1], 0), 393.0);
    expect(_d(frame.hits[1], 2), 1220.0 - 106);
  });

  test('R. rectHook must return exactly four numbers', () {
    expect(
        () => _picker(
              rectHook: (double x, double y, double w, double h) =>
                  <double>[x, y, w],
            ).build(),
        throwsArgumentError);
  });

  // -------------------------------------------------------------------------
  // Text command shape and fit() truncation
  // -------------------------------------------------------------------------

  test('S. every text command carries all eight Qt text fields', () {
    final PlaylistPickerFrame frame = _picker().build();
    for (final List<Object?> command in frame.commands
        .where((List<Object?> c) => c[0] == 'text')) {
      // Qt/src/NativeHud.cpp:40-43 text(value, x, y, size, weight, tracking, color).
      expect(command.length, 8);
      expect(command[1], isA<String>());
      expect(command[5], isA<String>());
      expect(command[6], 0.0, reason: 'no call site passes tracking');
      expect(command[7], isA<List<Object?>>());
    }
  });

  test('T. fit() truncates exactly like Qt: longest fitting prefix minus one unit plus U+2026', () {
    // Qt/src/NativeHud.cpp:48-76. With one em per code unit at size 18 and the row
    // width usable - 106 = 1154, the longest fitting prefix is 64 (64 * 18 = 1152),
    // so Qt paints value.left(63) + '…' for the hit label (:71-73).
    final String title = 'A' * 100;
    final PlaylistPickerFrame frame = _picker(
      playlists: <PlaylistPickerRow>[
        PlaylistPickerRow(id: 'x', title: title, editable: true),
      ],
      measureText: _wideMeasure,
      status: 'S' * 100,
    ).build();
    expect(frame.hits[1][5], 'A' * 63 + '…',
        reason: 'the button label is fit(title, 18, usable - 106)');
    // Qt/src/NativeHud.cpp:110-120 refits the label to width - inset * 2 = 1134, so
    // the painted text is one unit shorter again (longest prefix 63 -> left(62)).
    expect(frame.commands[12][1], 'A' * 62 + '…');
    // Qt/src/NativeHud.cpp:77-79 limited() fits once, at usable - 420 = 840:
    // longest prefix = 70 (70 * 12 = 840) -> left(69) + '…'.
    expect(frame.commands[17][1], 'S' * 69 + '…');
  });

  // -------------------------------------------------------------------------
  // Motion (UiMotion::SurfaceMotion)
  // -------------------------------------------------------------------------

  test('U. motion starts hidden, offset 12, duration 0 and finished', () {
    // Qt/src/UiMotion.h:24-42 member initialisers.
    final PlaylistPickerMotion motion = PlaylistPickerMotion();
    expect(motion.opacity, 0.0);
    expect(motion.offset, 12.0);
    expect(motion.duration, 0.0);
    expect(motion.finished, isTrue);
  });

  test('V. set(shown: true) runs 0.3 s and ends at opacity 1 / offset 0', () {
    // Qt/src/UiMotion.cpp:100-120 entering: opacity 1, offset 0, duration 0.3;
    // the animation starts from the captured current values, not from 0/12.
    final PlaylistPickerMotion motion = PlaylistPickerMotion();
    motion.set(shown: true, time: 5);
    expect(motion.duration, 0.3);
    expect(motion.opacity, 0.0, reason: 'set() samples first, it does not snap');
    expect(motion.offset, 12.0);
    expect(motion.finished, isFalse);

    // Halfway through the 0.3 s curve. Entering easing is bezier(.22, 1, .36, 1)
    // (Qt/src/UiMotion.cpp:93-95); its x component at t = 0.5 is
    // 3*(.5)^2*.5*.22 + 3*.5*(.5)^2*.36 + (.5)^3 = 0.3425 < 0.5, so the solved t is
    // above 0.5 and y = 1 - (1 - t)^3 > 0.875. The curve therefore overshoots the
    // linear midpoint: opacity > 0.875, offset = 12 - 12 * amount < 1.5.
    motion.sample(5.15);
    expect(motion.opacity, greaterThan(0.875));
    expect(motion.opacity, lessThanOrEqualTo(1.0));
    expect(motion.offset, lessThan(1.5));
    expect(motion.offset, greaterThanOrEqualTo(0.0));

    motion.sample(5.5); // progress clamped to 1
    expect(motion.opacity, closeTo(1.0, 1e-9));
    expect(motion.offset, closeTo(0.0, 1e-9));
    expect(motion.duration, 0.0, reason: 'sample() collapses the duration at progress 1');
    expect(motion.finished, isTrue);
  });

  test('W. set(shown: false) runs 0.2 s, targets offset 8 and settles at opacity 0', () {
    // Qt/src/UiMotion.cpp:100-120 leaving: opacity 0, offset 8, duration 0.2.
    final PlaylistPickerMotion motion = PlaylistPickerMotion();
    motion.set(shown: true, time: 0);
    motion.sample(1); // settle at opacity 1 / offset 0
    expect(motion.opacity, closeTo(1.0, 1e-9));
    expect(motion.offset, closeTo(0.0, 1e-9));

    motion.set(shown: false, time: 1);
    expect(motion.duration, 0.2);
    expect(motion.opacity, closeTo(1.0, 1e-9), reason: 'leaving starts from 1');
    expect(motion.offset, closeTo(0.0, 1e-9), reason: 'leaving starts from 0, not from 12');

    // Leaving easing is bezier(.4, 0, 1, 1); x(0.5) = 0.65 > 0.5, so the solved t is
    // below 0.5 and y = t^2 * (3 - 2t) < 0.5: the fade lags the linear midpoint.
    motion.sample(1.1);
    expect(motion.opacity, lessThan(1.0));
    expect(motion.opacity, greaterThan(0.5));
    expect(motion.offset, greaterThan(0.0));
    expect(motion.offset, lessThan(4.0));

    motion.sample(1.3);
    expect(motion.opacity, closeTo(0.0, 1e-9));
    expect(motion.offset, closeTo(8.0, 1e-9));
    expect(motion.duration, 0.0);
    expect(motion.finished, isTrue);
  });

  test('X. reduced motion snaps instantly with duration 0', () {
    // Qt/src/UiMotion.cpp:109-119 'duration = reduced ? 0 : ...' plus the snap.
    final PlaylistPickerMotion entering = PlaylistPickerMotion();
    entering.set(shown: true, time: 0, reduced: true);
    expect(entering.duration, 0.0);
    expect(entering.opacity, 1.0);
    expect(entering.offset, 0.0);
    expect(entering.finished, isTrue);

    final PlaylistPickerMotion leaving = PlaylistPickerMotion();
    leaving.set(shown: false, time: 0, reduced: true);
    expect(leaving.duration, 0.0);
    expect(leaving.opacity, 0.0);
    expect(leaving.offset, 8.0);
    expect(leaving.finished, isTrue);
  });

  test('Y. a retarget mid-flight continues from the value sample() captured', () {
    // Qt/src/UiMotion.cpp:100-120 calls sample(time) before capturing m_from*.
    final PlaylistPickerMotion motion = PlaylistPickerMotion();
    motion.set(shown: true, time: 0);
    motion.sample(0.15);
    final double midOpacity = motion.opacity;
    final double midOffset = motion.offset;
    expect(midOpacity, greaterThan(0.0));
    expect(midOpacity, lessThan(1.0));
    motion.set(shown: false, time: 0.15);
    expect(motion.duration, 0.2);
    expect(motion.opacity, midOpacity,
        reason: 'the retarget must not jump back to the old endpoint');
    expect(motion.offset, midOffset);
    expect(motion.finished, isFalse);
  });
}