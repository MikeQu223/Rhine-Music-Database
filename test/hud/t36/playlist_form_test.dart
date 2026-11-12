// test/hud/t36/playlist_form_test.dart
//
// T36 / PAGE-LIBRARY —— playlist-form（创建/重命名歌单写操作浮层）测试。
// 状态：RED 未执行（用户禁运行验证）—— 本文件只写不执行，禁止 flutter/dart test/analyze。
//
// 判据来源（只读 Qt 源，基线 8ed3067b0812eb2612f7841ec127a6e8ca93231b）：
//   Qt/src/MusicMutation.cpp:410-420  校验（trimmed、maximum = qq?20:100、空/超长文案）
//   Qt/src/MusicMutation.cpp:457-465  rename 所有权门文案
//   Qt/src/MusicMutation.cpp:466-493  写路由与表格写回语义
//   Qt/src/MusicMutation.cpp:186-200  writeLoading 串行化门
//   Qt/qml/Overlay.qml:363-369        可见性变化清空输入 + 抢焦点
//   Qt/qml/Overlay.qml:370-376        submit()
//   Qt/qml/Overlay.qml:384-407        字段：maximumLength 100 / ImhNone / Accessible.name
//   Qt/qml/Overlay.qml:462-483        提交按钮（保存 → / 提交表单 / #777b60）
//   Qt/qml/Overlay.qml:406            Escape → close-modal
//   Qt/src/NativeHudModal.cpp:198-202 头部与返回按钮几何
//   Qt/src/NativeHudModal.cpp:240-243 标签/提示/状态行
//   Qt/src/NativeHud.cpp:140-159      modalBounds
//   Qt/src/NativeHud.cpp:102-108      hits 六字段原序

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/modals/playlist_form.dart';

/// 假端口：记录调用参数，可切换「立即返回」与「在飞 Completer」两种模式。
class _FakePort implements PlaylistFormPort {
  _FakePort({this.createResult, this.renameResult});

  final List<String> calls = <String>[];
  PlaylistFormResult? createResult;
  PlaylistFormResult? renameResult;

  /// 非空时挂起，直到测试显式完成（用于在飞/代次语义）。
  Completer<PlaylistFormResult>? pending;

  @override
  Future<PlaylistFormResult> createPlaylist({required String name}) {
    calls.add('create:' + name);
    final Completer<PlaylistFormResult>? inFlight = pending;
    if (inFlight != null) {
      return inFlight.future;
    }
    return Future<PlaylistFormResult>.value(
      createResult ?? const PlaylistFormResult.accepted(),
    );
  }

  @override
  Future<PlaylistFormResult> renamePlaylist({required String id, required String name}) {
    calls.add('rename:' + id + ':' + name);
    final Completer<PlaylistFormResult>? inFlight = pending;
    if (inFlight != null) {
      return inFlight.future;
    }
    return Future<PlaylistFormResult>.value(
      renameResult ?? const PlaylistFormResult.accepted(),
    );
  }
}

/// 假表格端口：只记录语义调用顺序（MusicMutation.cpp:470-491 / :432-433 / :441-442）。
class _FakeTable implements SavedPlaylistTablePort {
  final List<String> calls = <String>[];
  PlaylistFormRow? created;
  String? renamedId;
  String? renamedTitle;

  @override
  void upsertCreated(PlaylistFormRow row) {
    calls.add('upsert');
    created = row;
  }

  @override
  void applyRenamed({required String id, required String verifiedTitle}) {
    calls.add('rename');
    renamedId = id;
    renamedTitle = verifiedTitle;
  }

  @override
  void reloadFromLocalCollections() {
    calls.add('reload');
  }

  @override
  void syncTotals() {
    calls.add('totals');
  }
}

Widget _harness({
  required PlaylistFormView view,
  required PlaylistFormPort port,
  SavedPlaylistTablePort? table,
  VoidCallback? onCloseModal,
  void Function(PlaylistFormCommit commit)? onCommitted,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 1920,
        height: 1080,
        child: PlaylistFormLayer(
          view: view,
          port: port,
          table: table,
          onCloseModal: onCloseModal,
          onCommitted: onCommitted,
        ),
      ),
    ),
  );
}

String _fieldText(WidgetTester tester) {
  // 输入框必须由 TextInputOverlay 的 EditableText 承接；raw TextField 已删除。
  final EditableText field = tester.widget<EditableText>(
    find.byKey(PlaylistFormKeys.nameField),
  );
  return field.controller.text;
}

void main() {
  group('逐字常量（禁止同义改写）', () {
    test('action / 文案 / 上限逐字对齐 Qt 源', () {
      expect(PlaylistFormSpec.modalKind, 'playlist-form');
      expect(PlaylistFormKind.create.wire, 'create');
      expect(PlaylistFormKind.rename.wire, 'rename');
      // NativeHudLibrary.cpp:110 / NativeHudDetail.cpp:413 / NativeHudLibrary.cpp:116
      expect(PlaylistFormSpec.actionCreatePlaylist, 'music:create-playlist');
      expect(PlaylistFormSpec.actionRenamePlaylist, 'music:rename-playlist');
      expect(PlaylistFormSpec.actionRefreshPersonal, 'music:refresh-personal');
      // NativeHudModal.cpp:199/200、NativeHudController.cpp:686
      expect(PlaylistFormSpec.actionCloseModal, 'close-modal');
      expect(PlaylistFormSpec.backLabel, '← 返回');
      // Overlay.qml:472 / :398 / :477
      expect(PlaylistFormSpec.submitLabel, '保存 →');
      expect(PlaylistFormSpec.loginSubmitLabel, '登录 →');
      expect(PlaylistFormSpec.fieldAccessibleName, '歌单名称');
      expect(PlaylistFormSpec.submitAccessibleName, '提交表单');
      // NativeHudModal.cpp:241/242/35/60
      expect(PlaylistFormSpec.labelCreate, '歌单名称');
      expect(PlaylistFormSpec.labelRename, '新歌单名称');
      expect(PlaylistFormSpec.hintPlain, '按 ENTER 提交');
      expect(PlaylistFormSpec.hintQq, '1–20 字 / 按 ENTER 提交');
      expect(PlaylistFormSpec.panelTitle, 'PLAYLIST EDITOR');
      expect(PlaylistFormSpec.panelSubtitle, '编辑我的歌单');
      expect(PlaylistFormSpec.panelHeader, 'RHINE LAB / MUSIC DATABASE / MUSIC DIRECTORY');
      // Overlay.qml:395 / MusicMutation.cpp:412
      expect(PlaylistFormSpec.fieldMaxLength, 100);
      expect(PlaylistFormSpec.loginPhoneMaxLength, 11);
      expect(PlaylistFormSpec.nameMaximumQq, 20);
      expect(PlaylistFormSpec.nameMaximumDefault, 100);
      // MusicMutation.cpp:414：请输入 1–N 字歌单名称（U+2013）
      expect(PlaylistFormSpec.nameInvalidMessage(100), '请输入 1–100 字歌单名称');
      expect(PlaylistFormSpec.nameInvalidMessage(20), '请输入 1–20 字歌单名称');
      // MusicMutation.cpp:459/436/448/190/192/194
      expect(PlaylistFormSpec.statusRenameNotOwned, '只能编辑自己创建的歌单');
      expect(PlaylistFormSpec.statusSirenCreateFailed, '无法创建歌单，请检查名称或数量上限');
      expect(PlaylistFormSpec.statusSirenRenameFailed, '无法重命名歌单');
      expect(PlaylistFormSpec.statusQqFeatureClosed, '当前 QQ 服务未开放此编辑功能');
    });

    test('PlaylistFormKind.fromWire 只认 Qt 的两个串', () {
      expect(PlaylistFormKind.fromWire('create'), PlaylistFormKind.create);
      expect(PlaylistFormKind.fromWire('rename'), PlaylistFormKind.rename);
      expect(PlaylistFormKind.fromWire('Create'), isNull);
      expect(PlaylistFormKind.fromWire(''), isNull);
    });
  });

  group('校验：MusicMutation.cpp:410-420', () {
    test('空名 / 纯空白 → 拒绝并回显 1–100 文案；trim 后为空', () {
      for (final String raw in <String>['', '   ', '\t\n ']) {
        final PlaylistFormValidation result =
            PlaylistFormValidator.validateName(rawName: raw, provider: 'netease');
        expect(result.accepted, isFalse, reason: raw);
        expect(result.trimmedName, '');
        expect(result.message, PlaylistFormSpec.nameInvalidMessage(100));
      }
    });

    test('trimmed 后 1 与 100 个码点通过，101 个拒绝（netease/其它平台）', () {
      final String one = 'a';
      final String hundred = List<String>.filled(100, 'a').join();
      final String hundredOne = List<String>.filled(101, 'a').join();
      expect(PlaylistFormValidator.validateName(rawName: '  ' + one + '  ', provider: 'netease').accepted,
          isTrue);
      expect(PlaylistFormValidator.validateName(rawName: hundred, provider: 'netease').accepted, isTrue);
      final PlaylistFormValidation tooLong =
          PlaylistFormValidator.validateName(rawName: hundredOne, provider: 'netease');
      expect(tooLong.accepted, isFalse);
      expect(tooLong.message, '请输入 1–100 字歌单名称');
    });

    test('qq 上限 20 码点：20 通过、21 拒绝并回显 1–20 文案', () {
      expect(PlaylistFormValidator.maximumFor('qq'), 20);
      expect(PlaylistFormValidator.maximumFor('netease'), 100);
      expect(PlaylistFormValidator.maximumFor('siren'), 100);
      final String twenty = List<String>.filled(20, '字').join();
      final String twentyOne = List<String>.filled(21, '字').join();
      expect(PlaylistFormValidator.validateName(rawName: twenty, provider: 'qq').accepted, isTrue);
      final PlaylistFormValidation tooLong =
          PlaylistFormValidator.validateName(rawName: twentyOne, provider: 'qq');
      expect(tooLong.accepted, isFalse);
      expect(tooLong.message, '请输入 1–20 字歌单名称');
    });

    test('校验用 toUcs4().size()（码点）：50 个代理对 = 50 码点，通过', () {
      final String emoji = '\u{1F3B5}'; // 每个 2 个 UTF-16 码元
      final String fifty = List<String>.filled(50, emoji).join();
      expect(fifty.length, 100); // UTF-16 码元
      expect(fifty.runes.length, 50); // 码点
      expect(PlaylistFormValidator.validateName(rawName: fifty, provider: 'netease').accepted, isTrue);
      // 51 个代理对 = 51 码点 > 20（qq）但 <= 100（其它）
      final String fiftyOne = List<String>.filled(51, emoji).join();
      expect(PlaylistFormValidator.validateName(rawName: fiftyOne, provider: 'netease').accepted, isTrue);
      expect(PlaylistFormValidator.validateName(rawName: fiftyOne, provider: 'qq').accepted, isFalse);
    });

    test('校验结果带回 trimmedName（下游用 trimmed 值）', () {
      final PlaylistFormValidation result =
          PlaylistFormValidator.validateName(rawName: '  我的歌单  ', provider: 'netease');
      expect(result.accepted, isTrue);
      expect(result.trimmedName, '我的歌单');
      expect(result.message, '');
    });
  });

  group('字段截断：Overlay.qml:395 maximumLength（UTF-16 码元）', () {
    const PlaylistFormTextInputFormatter formatter = PlaylistFormTextInputFormatter(100);

    test('100 码元原样通过（含 selection 不变）', () {
      final String text = List<String>.filled(100, 'a').join();
      final TextEditingValue value = TextEditingValue(
        text: text,
        selection: const TextSelection.collapsed(offset: 100),
      );
      final TextEditingValue out = formatter.formatEditUpdate(TextEditingValue.empty, value);
      expect(out.text, text);
      expect(out.selection.baseOffset, 100);
    });

    test('150 码元截断到 100，光标夹到 100，composing 清空', () {
      final TextEditingValue value = TextEditingValue(
        text: List<String>.filled(150, 'a').join(),
        selection: const TextSelection.collapsed(offset: 150),
      );
      final TextEditingValue out = formatter.formatEditUpdate(TextEditingValue.empty, value);
      expect(out.text.length, 100);
      expect(out.selection.baseOffset, 100);
      expect(out.selection.extentOffset, 100);
      expect(out.composing, TextRange.empty);
    });

    test('代理对按 2 个码元计数：51 个 emoji 截断为 50 个', () {
      final String emoji = '\u{1F3B5}';
      final String input = List<String>.filled(51, emoji).join();
      final TextEditingValue value = TextEditingValue(
        text: input,
        selection: TextSelection.collapsed(offset: input.length),
      );
      final TextEditingValue out = formatter.formatEditUpdate(TextEditingValue.empty, value);
      expect(out.text.length, 100);
      expect(out.text.runes.length, 50);
      expect(out.text, List<String>.filled(50, emoji).join());
    });

    test('范围内 composing 保留（IME 语义不被破坏）', () {
      final TextEditingValue value = TextEditingValue(
        text: List<String>.filled(120, 'a').join(),
        selection: const TextSelection.collapsed(offset: 120),
        composing: const TextRange(start: 0, end: 5),
      );
      final TextEditingValue out = formatter.formatEditUpdate(TextEditingValue.empty, value);
      expect(out.text.length, 100);
      expect(out.composing, const TextRange(start: 0, end: 5));
    });
  });

  group('横屏几何：NativeHud.cpp:140-159 + Overlay.qml:358-390/462-467 + NativeHudModal.cpp:198-243', () {
    test('1920 舞台逐值', () {
      final PlaylistFormLayout layout = PlaylistFormLayout.stage(stageWidth: 1920, scale: 1);
      expect(layout.portrait, isFalse);
      expect(layout.panel, const Rect.fromLTWH(330, 122, 1260, 836));
      // 头部：button("← 返回", x+usable-220, y+18, 167, 54)
      expect(layout.backButton, const Rect.fromLTWH(1370, 140, 167, 54));
      expect(layout.header.at, const Offset(383, 159)); // x+53, y+37
      expect(layout.header.size, 11);
      expect(layout.title.at, const Offset(383, 213)); // x+53, y+91
      expect(layout.title.size, 38);
      expect(layout.title.demibold, isTrue);
      expect(layout.subtitle.at, const Offset(383, 269)); // x+53, y+147
      expect(layout.subtitle.size, 15);
      // 面板内容：标签 y+240 / 提示 y+420 / 状态 y+775
      expect(layout.fieldLabel.at, const Offset(383, 362));
      expect(layout.fieldLabel.size, 15);
      expect(layout.hint.at, const Offset(383, 542));
      expect(layout.hint.size, 12);
      expect(layout.status.at, const Offset(383, 897));
      expect(layout.status.size, 12);
      expect(layout.statusMaxWidth, 1154); // usable-106
      // 字段：inputWidth = usable-106-libraryToolbarActionWidth()（modal != "saved" → 0）
      expect(layout.fieldBox, const Rect.fromLTWH(383, 430, 1154, 55));
      expect(layout.fieldRect, const Rect.fromLTWH(397, 430, 1126, 55)); // x+14, width-28
      // 提交：y=530（非 login 分支），170x36，右贴
      expect(layout.submitButton, const Rect.fromLTWH(1367, 530, 170, 36));
    });

    test('1000 舞台：modalWidth = min(1260, width-100)，left 居中', () {
      final PlaylistFormLayout layout = PlaylistFormLayout.stage(stageWidth: 1000, scale: 1);
      expect(layout.panel, const Rect.fromLTWH(50, 122, 900, 836));
      expect(layout.fieldBox, const Rect.fromLTWH(103, 430, 794, 55));
      expect(layout.submitButton, const Rect.fromLTWH(727, 530, 170, 36));
      expect(layout.backButton, const Rect.fromLTWH(730, 140, 167, 54));
      expect(layout.statusMaxWidth, 794);
    });

    test('stageScale 缩放（Overlay.qml:22 stageScale = height/1080）', () {
      final PlaylistFormLayout layout = PlaylistFormLayout.stage(stageWidth: 1920, scale: 0.5);
      final Rect back = layout.scaled(layout.backButton);
      expect(back.left, closeTo(685, 1e-9));
      expect(back.top, closeTo(70, 1e-9));
      expect(back.width, closeTo(83.5, 1e-9));
      expect(back.height, closeTo(27, 1e-9));
    });

    test('本层不发命中：close-modal 归 chrome 层唯一 owner', () {
      final PlaylistFormLayout layout = PlaylistFormLayout.stage(stageWidth: 1920, scale: 1);
      // 返回按钮的几何仍作为 chrome 层契约保留（x+usable-220, y+18, 167x54），
      // 但本层不画它、也不登记 close-modal；否则会与 chrome 层重复。
      expect(layout.backButton, const Rect.fromLTWH(1370, 140, 167, 54));
      expect(layout.nativeHits(), isEmpty);
    });
  });

  group('竖屏响应式（新增语义，无 Qt 竖屏像素证据）', () {
    test('portrait 布局存在、全宽字段、无横向溢出', () {
      final PlaylistFormLayout layout = PlaylistFormLayout.portrait(viewport: const Size(390, 844));
      expect(layout.portrait, isTrue);
      expect(layout.scale, 1);
      expect(layout.panel, const Rect.fromLTWH(16, 0, 358, 844));
      expect(layout.fieldBox, const Rect.fromLTWH(32, 264, 326, 64));
      expect(layout.submitButton.left, 32);
      expect(layout.submitButton.width, 326);
      expect(layout.fieldBox.right <= layout.panel.right, isTrue);
      expect(layout.submitButton.right <= layout.panel.right, isTrue);
      // 纵向顺序：标题 → 字段 → 提交 → 提示 → 状态
      expect(layout.title.at.dy < layout.fieldBox.top, isTrue);
      expect(layout.fieldBox.bottom < layout.submitButton.top, isTrue);
      expect(layout.submitButton.bottom < layout.hint.at.dy, isTrue);
      expect(layout.hint.at.dy < layout.status.at.dy, isTrue);
      expect(layout.statusMaxWidth, layout.panel.width - PlaylistFormSpec.inputWidthInset);
    });
  });

  group('视图快照语义', () {
    test('enabled 表达式在 playlist-form 下恒真（Overlay.qml:396/414/465）——不自创禁用规则', () {
      const PlaylistFormView view = PlaylistFormView(formKind: PlaylistFormKind.create, provider: 'netease');
      expect(view.fieldEnabled, isTrue);
      expect(view.submitEnabled, isTrue);
      expect(view.fieldMaximumLength, 100);
      expect(view.nameMaximum, 100);
      expect(view.nameLabel, '歌单名称');
      expect(view.nameHint, '按 ENTER 提交');
      expect(view.openable, isTrue);
    });

    test('qq：hint 与上限随 provider 切换；rename 标签为「新歌单名称」', () {
      const PlaylistFormView view = PlaylistFormView(formKind: PlaylistFormKind.rename, provider: 'qq');
      expect(view.nameLabel, '新歌单名称');
      expect(view.nameHint, '1–20 字 / 按 ENTER 提交');
      expect(view.nameMaximum, 20);
    });

    test('local 平台不可打开（NativeHudController.cpp:64-69）', () {
      const PlaylistFormView view = PlaylistFormView(formKind: PlaylistFormKind.create, provider: 'local');
      expect(view.openable, isFalse);
    });
  });

  group('浮层行为：提交 / 取消 / ESC / 门', () {
    testWidgets('不可见时不渲染浮层', (WidgetTester tester) async {
      final _FakePort port = _FakePort();
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(
          formKind: PlaylistFormKind.create,
          provider: 'netease',
          visible: false,
        ),
        port: port,
      ));
      expect(find.byKey(PlaylistFormKeys.layer), findsNothing);
      expect(find.byKey(PlaylistFormKeys.nameField), findsNothing);
    });

    testWidgets('横屏渲染表单内容；弹层框架留给 chrome 层', (WidgetTester tester) async {
      final _FakePort port = _FakePort();
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(formKind: PlaylistFormKind.create, provider: 'netease'),
        port: port,
      ));
      expect(find.byKey(PlaylistFormKeys.layer), findsOneWidget);
      // 框架（RHINE LAB / 标题 / 副标题 / 返回）由 lib/hud/pages/chrome.dart 统一绘制。
      expect(find.text(PlaylistFormSpec.panelHeader), findsNothing);
      expect(find.text(PlaylistFormSpec.panelTitle), findsNothing);
      expect(find.text(PlaylistFormSpec.panelSubtitle), findsNothing);
      expect(find.text(PlaylistFormSpec.backLabel), findsNothing);
      expect(find.text(PlaylistFormSpec.labelCreate), findsOneWidget);
      expect(find.text(PlaylistFormSpec.hintPlain), findsOneWidget);
      expect(find.text(PlaylistFormSpec.submitLabel), findsOneWidget);
      // 状态行为空时不渲染
      expect(find.byKey(PlaylistFormKeys.status), findsNothing);
    });

    testWidgets('空名提交：不调用端口，回显 1–100 文案，浮层不关闭', (WidgetTester tester) async {
      final _FakePort port = _FakePort();
      int closed = 0;
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(formKind: PlaylistFormKind.create, provider: 'netease'),
        port: port,
        onCloseModal: () => closed++,
      ));
      await tester.tap(find.byKey(PlaylistFormKeys.submit));
      await tester.pumpAndSettle();
      expect(port.calls, isEmpty);
      expect(closed, 0);
      expect(find.text('请输入 1–100 字歌单名称'), findsOneWidget);
    });

    testWidgets('纯空白名提交：同样被校验拦下', (WidgetTester tester) async {
      final _FakePort port = _FakePort();
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(formKind: PlaylistFormKind.create, provider: 'netease'),
        port: port,
      ));
      await tester.enterText(find.byKey(PlaylistFormKeys.nameField), '   ');
      await tester.tap(find.byKey(PlaylistFormKeys.submit));
      await tester.pumpAndSettle();
      expect(port.calls, isEmpty);
      expect(find.text('请输入 1–100 字歌单名称'), findsOneWidget);
    });

    testWidgets('字段截断 100 码元（tester 输入 150）', (WidgetTester tester) async {
      final _FakePort port = _FakePort();
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(formKind: PlaylistFormKind.create, provider: 'netease'),
        port: port,
      ));
      await tester.enterText(
        find.byKey(PlaylistFormKeys.nameField),
        List<String>.filled(150, 'a').join(),
      );
      await tester.pump();
      expect(_fieldText(tester).length, 100);
    });

    testWidgets('字段按 UTF-16 码元截断（Qt QString 口径，不是 grapheme）', (WidgetTester tester) async {
      final _FakePort port = _FakePort();
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(formKind: PlaylistFormKind.create, provider: 'netease'),
        port: port,
      ));
      await tester.enterText(
        find.byKey(PlaylistFormKeys.nameField),
        List<String>.filled(60, '😀').join(),
      );
      await tester.pump();
      expect(_fieldText(tester).length, 100);
      expect(_fieldText(tester).runes.length, 50);
    });

    testWidgets('create 成功：端口收到 trimmed 名，表格 upsert + syncTotals，onCommitted 与关闭', (
      WidgetTester tester,
    ) async {
      final _FakePort port = _FakePort(
        createResult: const PlaylistFormResult.accepted(
          row: PlaylistFormRow(id: 'p1', title: '我的歌单', creatorId: 'u1'),
        ),
      );
      final _FakeTable table = _FakeTable();
      final List<PlaylistFormCommit> commits = <PlaylistFormCommit>[];
      int closed = 0;
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(formKind: PlaylistFormKind.create, provider: 'netease', uid: 'u1'),
        port: port,
        table: table,
        onCloseModal: () => closed++,
        onCommitted: commits.add,
      ));
      await tester.enterText(find.byKey(PlaylistFormKeys.nameField), '  我的歌单  ');
      await tester.tap(find.byKey(PlaylistFormKeys.submit));
      await tester.pumpAndSettle();
      expect(port.calls, <String>['create:我的歌单']); // trimmed（MusicMutation.cpp:411）
      expect(table.calls, <String>['upsert', 'totals']); // :470-476 + :491
      expect(table.created?.id, 'p1');
      expect(commits.length, 1);
      expect(commits.single.kind, PlaylistFormKind.create);
      expect(commits.single.requestedName, '我的歌单');
      expect(commits.single.verifiedTitle, '我的歌单');
      expect(closed, 1);
    });

    testWidgets('rename 成功：端口收到 formPID，表格按 verifiedTitle 改名', (WidgetTester tester) async {
      final _FakePort port = _FakePort(
        renameResult: const PlaylistFormResult.accepted(verifiedTitle: '新名字'),
      );
      final _FakeTable table = _FakeTable();
      int closed = 0;
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(
          formKind: PlaylistFormKind.rename,
          provider: 'netease',
          uid: 'u1',
          formPid: 'p9',
        ),
        port: port,
        table: table,
        onCloseModal: () => closed++,
      ));
      expect(find.text(PlaylistFormSpec.labelRename), findsOneWidget);
      await tester.enterText(find.byKey(PlaylistFormKeys.nameField), '新名字');
      await tester.tap(find.byKey(PlaylistFormKeys.submit));
      await tester.pumpAndSettle();
      expect(port.calls, <String>['rename:p9:新名字']); // MusicMutation.cpp:468
      expect(table.calls, <String>['rename', 'totals']);
      expect(table.renamedId, 'p9');
      expect(table.renamedTitle, '新名字'); // MusicMutation.cpp:479 body["name"] 优先
      expect(closed, 1);
    });

    testWidgets('siren 分支：走本地集合重载 + syncTotals，不做 upsert（MusicMutation.cpp:432/441）', (
      WidgetTester tester,
    ) async {
      final _FakePort port = _FakePort(
        createResult: const PlaylistFormResult.accepted(
          row: PlaylistFormRow(id: 'l1', title: '本地歌单', creatorId: 'local', provider: 'siren'),
        ),
      );
      final _FakeTable table = _FakeTable();
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(formKind: PlaylistFormKind.create, provider: 'siren'),
        port: port,
        table: table,
      ));
      await tester.enterText(find.byKey(PlaylistFormKeys.nameField), '本地歌单');
      await tester.tap(find.byKey(PlaylistFormKeys.submit));
      await tester.pumpAndSettle();
      expect(table.calls, <String>['reload', 'totals']);
    });

    testWidgets('失败回显模型原文，表格不动、浮层不关', (WidgetTester tester) async {
      final _FakePort port = _FakePort(
        renameResult: const PlaylistFormResult.rejected(status: '只能编辑自己创建的歌单'),
      );
      final _FakeTable table = _FakeTable();
      int closed = 0;
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(
          formKind: PlaylistFormKind.rename,
          provider: 'netease',
          uid: 'u1',
          formPid: 'p9',
        ),
        port: port,
        table: table,
        onCloseModal: () => closed++,
      ));
      await tester.enterText(find.byKey(PlaylistFormKeys.nameField), '别人的歌单');
      await tester.tap(find.byKey(PlaylistFormKeys.submit));
      await tester.pumpAndSettle();
      expect(find.text(PlaylistFormSpec.statusRenameNotOwned), findsOneWidget);
      expect(table.calls, isEmpty);
      expect(closed, 0);
    });

    testWidgets('writeLoading：门在端口，层仍调用端口并回显 Qt 状态', (
      WidgetTester tester,
    ) async {
      final _FakePort port = _FakePort(
        createResult: const PlaylistFormResult.rejected(
          status: PlaylistFormSpec.statusQqFeatureClosed,
        ),
      );
      int closed = 0;
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(
          formKind: PlaylistFormKind.create,
          provider: 'qq',
          uid: 'u1',
          writeLoading: true,
        ),
        port: port,
        onCloseModal: () => closed++,
      ));
      await tester.enterText(find.byKey(PlaylistFormKeys.nameField), '有效名字');
      await tester.tap(find.byKey(PlaylistFormKeys.submit));
      await tester.pumpAndSettle();
      expect(port.calls, <String>['create:有效名字']);
      expect(find.text(PlaylistFormSpec.statusQqFeatureClosed), findsOneWidget);
      expect(closed, 0);
    });

    testWidgets('writeLoading + siren create：siren 分支先于远端门，仍创建成功', (
      WidgetTester tester,
    ) async {
      final _FakePort port = _FakePort(
        createResult: const PlaylistFormResult.accepted(
          row: PlaylistFormRow(id: 'l1', title: '本地歌单', creatorId: 'local', provider: 'siren'),
        ),
      );
      final _FakeTable table = _FakeTable();
      int closed = 0;
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(
          formKind: PlaylistFormKind.create,
          provider: 'siren',
          uid: 'u1',
          writeLoading: true,
        ),
        port: port,
        table: table,
        onCloseModal: () => closed++,
      ));
      await tester.enterText(find.byKey(PlaylistFormKeys.nameField), '本地歌单');
      await tester.tap(find.byKey(PlaylistFormKeys.submit));
      await tester.pumpAndSettle();
      expect(port.calls, <String>['create:本地歌单']);
      expect(table.calls, <String>['reload', 'totals']);
      expect(closed, 1);
    });

    testWidgets('writeLoading + 非 owner rename：所有权门先于远端门，回显 Qt 文案', (
      WidgetTester tester,
    ) async {
      final _FakePort port = _FakePort(
        renameResult: const PlaylistFormResult.rejected(
          status: PlaylistFormSpec.statusRenameNotOwned,
        ),
      );
      final _FakeTable table = _FakeTable();
      int closed = 0;
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(
          formKind: PlaylistFormKind.rename,
          provider: 'netease',
          uid: 'u1',
          formPid: 'p9',
          writeLoading: true,
        ),
        port: port,
        table: table,
        onCloseModal: () => closed++,
      ));
      await tester.enterText(find.byKey(PlaylistFormKeys.nameField), '别人的歌单');
      await tester.tap(find.byKey(PlaylistFormKeys.submit));
      await tester.pumpAndSettle();
      expect(port.calls, <String>['rename:p9:别人的歌单']);
      expect(find.text(PlaylistFormSpec.statusRenameNotOwned), findsOneWidget);
      expect(table.calls, isEmpty);
      expect(closed, 0);
    });

    testWidgets('在飞期间重复提交被吞（只发一次）', (WidgetTester tester) async {
      final _FakePort port = _FakePort();
      final Completer<PlaylistFormResult> pending = Completer<PlaylistFormResult>();
      port.pending = pending;
      int closed = 0;
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(formKind: PlaylistFormKind.create, provider: 'netease', uid: 'u1'),
        port: port,
        onCloseModal: () => closed++,
      ));
      await tester.enterText(find.byKey(PlaylistFormKeys.nameField), '名字');
      await tester.tap(find.byKey(PlaylistFormKeys.submit));
      await tester.pump();
      await tester.tap(find.byKey(PlaylistFormKeys.submit));
      await tester.pump();
      expect(port.calls.length, 1);
      pending.complete(const PlaylistFormResult.accepted());
      await tester.pumpAndSettle();
      expect(port.calls.length, 1);
      expect(closed, 1);
    });

    testWidgets('代次变化丢弃结果（NativeHudController.cpp:173-177）', (WidgetTester tester) async {
      final _FakePort port = _FakePort();
      final Completer<PlaylistFormResult> pending = Completer<PlaylistFormResult>();
      port.pending = pending;
      final _FakeTable table = _FakeTable();
      int closed = 0;
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(
          formKind: PlaylistFormKind.create,
          provider: 'netease',
          uid: 'u1',
          generation: 1,
        ),
        port: port,
        table: table,
        onCloseModal: () => closed++,
      ));
      await tester.enterText(find.byKey(PlaylistFormKeys.nameField), '名字');
      await tester.tap(find.byKey(PlaylistFormKeys.submit));
      await tester.pump();
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(
          formKind: PlaylistFormKind.create,
          provider: 'netease',
          uid: 'u1',
          generation: 2,
        ),
        port: port,
        table: table,
        onCloseModal: () => closed++,
      ));
      pending.complete(const PlaylistFormResult.accepted());
      await tester.pumpAndSettle();
      expect(table.calls, isEmpty);
      expect(closed, 0);
    });

    testWidgets('本层无返回按钮；字段 ESC 仍发 close-modal', (WidgetTester tester) async {
      final _FakePort port = _FakePort();
      int closed = 0;
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(formKind: PlaylistFormKind.create, provider: 'netease'),
        port: port,
        onCloseModal: () => closed++,
      ));
      expect(find.byKey(PlaylistFormKeys.back), findsNothing);
      // Overlay.qml:406 Keys.onEscapePressed → rhine.action("close-modal")
      await tester.tap(find.byKey(PlaylistFormKeys.nameField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(closed, 1);
      expect(port.calls, isEmpty);
    });

    testWidgets('回车提交（Overlay.qml:399-405）', (WidgetTester tester) async {
      final _FakePort port = _FakePort();
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(formKind: PlaylistFormKind.create, provider: 'netease', uid: 'u1'),
        port: port,
      ));
      await tester.enterText(find.byKey(PlaylistFormKeys.nameField), '回车歌单');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(port.calls, <String>['create:回车歌单']);
    });

    testWidgets('输入框由 TextInputOverlay 的真实 EditableText 承接，无 raw TextField', (
      WidgetTester tester,
    ) async {
      final _FakePort port = _FakePort();
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(formKind: PlaylistFormKind.create, provider: 'netease'),
        port: port,
      ));
      // 旧实现直接在 playlist_form.dart 里建 TextField；A55 后必须只有 overlay 一套。
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(EditableText), findsOneWidget);
      expect(find.byKey(PlaylistFormKeys.nameField), findsOneWidget);
    });

    testWidgets('rename 初值进入 overlay controller（Overlay.qml:390）', (WidgetTester tester) async {
      final _FakePort port = _FakePort();
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(
          formKind: PlaylistFormKind.rename,
          provider: 'netease',
          formPid: 'p1',
          initialName: '旧歌单名',
        ),
        port: port,
      ));
      expect(_fieldText(tester), '旧歌单名');
    });

    testWidgets('同一 overlay 切换 rename 目标时用新初值重置（formIdentity）', (
      WidgetTester tester,
    ) async {
      final _FakePort port = _FakePort();
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(
          formKind: PlaylistFormKind.rename,
          provider: 'netease',
          formPid: 'p1',
          initialName: '第一首',
        ),
        port: port,
      ));
      expect(_fieldText(tester), '第一首');
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(
          formKind: PlaylistFormKind.rename,
          provider: 'netease',
          formPid: 'p2',
          initialName: '第二首',
        ),
        port: port,
      ));
      await tester.pump();
      expect(_fieldText(tester), '第二首');
    });

    testWidgets('可见性变化清空输入（Overlay.qml:363-369）', (WidgetTester tester) async {
      final _FakePort port = _FakePort();
      const PlaylistFormView shown =
          PlaylistFormView(formKind: PlaylistFormKind.create, provider: 'netease');
      await tester.pumpWidget(_harness(view: shown, port: port));
      await tester.enterText(find.byKey(PlaylistFormKeys.nameField), '待清空');
      await tester.pump();
      expect(_fieldText(tester), '待清空');
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(
          formKind: PlaylistFormKind.create,
          provider: 'netease',
          visible: false,
        ),
        port: port,
      ));
      await tester.pump();
      await tester.pumpWidget(_harness(view: shown, port: port));
      await tester.pump();
      // formInitialText 为空串（create）时，onVisibleChanged 必须清空并重新聚焦；
      // controller 由 overlay 持有，重开时不能把旧文本带回来。
      expect(_fieldText(tester), '');
    });

    testWidgets('视图注入的状态行原文渲染（NativeHudModal.cpp:243）', (WidgetTester tester) async {
      final _FakePort port = _FakePort();
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(
          formKind: PlaylistFormKind.create,
          provider: 'netease',
          status: '请先登录网易云音乐',
        ),
        port: port,
      ));
      expect(find.text('请先登录网易云音乐'), findsOneWidget);
      expect(find.byKey(PlaylistFormKeys.status), findsOneWidget);
      final Text statusText = tester.widget<Text>(find.text('请先登录网易云音乐'));
      expect(statusText.maxLines, 1);
      expect(statusText.overflow, TextOverflow.ellipsis); // NativeHud.cpp fit() 的「…」
    });

    testWidgets('竖屏渲染：全宽字段、无异常', (WidgetTester tester) async {
      final _FakePort port = _FakePort();
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(
          formKind: PlaylistFormKind.create,
          provider: 'netease',
          portrait: true,
          viewport: Size(390, 844),
        ),
        port: port,
      ));
      expect(find.byKey(PlaylistFormKeys.layer), findsOneWidget);
      final Rect fieldRect = tester.getRect(find.byKey(PlaylistFormKeys.nameField));
      // EditableText 在 64 高字段框内垂直居中（Overlay.qml:391 AlignVCenter），
      // 其自身 rect 的 top 不是框 top；宽度仍是整框宽（326-24）。
      expect(fieldRect.width, closeTo(326 - 24, 1e-6));
      expect(fieldRect.center.dy, closeTo(264 + 32, 1e-6));
      expect(tester.takeException(), isNull);
    });
  });

  group('无障碍语义（Overlay.qml:398/477）', () {
    testWidgets('字段与提交按钮语义标签', (WidgetTester tester) async {
      final _FakePort port = _FakePort();
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(_harness(
        view: const PlaylistFormView(formKind: PlaylistFormKind.create, provider: 'netease'),
        port: port,
      ));
      // 标签同时存在于 HUD 文本节点与显式 Semantics 上，故用「至少一个」
      expect(find.bySemanticsLabel(PlaylistFormSpec.fieldAccessibleName), findsAtLeastNWidgets(1));
      expect(find.bySemanticsLabel(PlaylistFormSpec.submitAccessibleName), findsAtLeastNWidgets(1));
      handle.dispose();
    });
  });
}
