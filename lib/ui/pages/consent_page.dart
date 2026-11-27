// Consent 门槛页（对应 Qt ConsentActivity 的 presentation 层）。
//
// Qt 行为（Qt/android/src/rhine/music/database/ConsentActivity.java）：
// - 清单里 ConsentActivity 是 LAUNCHER，同意之前 Qt/Clarity/Bugly 一个都不启动。
// - 已同意 → 直接按持久 region 放行；未同意 → 判定地区（3 秒硬闸门）→ CN/EU 弹窗，
//   其他/超时/异常直接放行，且不写持久标记。
// - 弹窗 setCancelable(false)，返回键无效，隐私链接可点；放行时先启动 SDK 再进业务页。
// - RhineConsent 主题为纯黑（windowDisablePreview），避免弹窗路径闪白。
//
// 唯一流程/持久化/SDK starter 在 lib/app/consent_gate.dart（ConsentGate /
// ConsentPorts / ConsentSdkStarter）。本文件不实现流程、不复制地区判定与文案、
// 不建第二个 SDK starter；只负责渲染弹窗、把按钮与返回键翻译成一次流程调用、
// 把「已放行」通知宿主导航钩子。
//
// 待决地区直接读 ConsentGate.pendingRegion：它只在 awaitingConsent 时非 null；
// 回答失败时流程机在 rethrow 前恢复该值，因此这里读到的是恢复后的真实读数。

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:rhine_music_database/app/consent_gate.dart';

// 页面

/// 谁执行 ConsentActivity.java:148-155 的「startActivity(QtActivity)」。
///
/// Qt 只有一处导航；Flutter 有两个天然落点：流程机的 [ConsentPorts.enterBusiness]
/// （流程机内部）与页面的 [ConsentPage.onProceed]（宿主钩子）。两者同时生效会叠出
/// 第二个业务页，所以这里把它变成构造期必须声明的类型，而不是注释里的君子协定。
enum BusinessEntryOwner {
  /// 流程机的 ConsentPorts.enterBusiness 负责导航；页面不再调 onProceed。
  ports,

  /// 宿主在 onProceed 里导航；ConsentPorts.enterBusiness 必须实现成空操作。
  host,
}

/// Consent 门槛页（ConsentActivity.java:66-164 的画面部分）。
///
/// Qt 侧 ConsentActivity 没有自己的界面，只有系统 AlertDialog；这里用 Material AlertDialog
/// 对齐同一份文案/按钮/不可取消语义，不假造 Qt 像素。
/// 路由归属见 [BusinessEntryOwner]：本页自己从不导航，只发一次「已放行」通知。
class ConsentPage extends StatefulWidget {
  const ConsentPage({
    required this.gate,
    this.businessEntry = BusinessEntryOwner.host,
    this.onProceed,
    this.onPrivacyLinkTap,
    this.onPresentationBroken,
    super.key,
  }) : assert(
          businessEntry == BusinessEntryOwner.ports ? onProceed == null : onProceed != null,
          'BusinessEntryOwner.ports 时不要传 onProceed（T27 enterBusiness 已在导航）；'
          'BusinessEntryOwner.host 时必须传 onProceed。两者只允许一个生效。',
        );

  /// 流程机的唯一流程机。本页只调用 start/approve/decline/backPressed 并读 phase。
  final ConsentGate gate;

  /// 导航归属（见 [BusinessEntryOwner]）：默认由宿主在 [onProceed] 里导航。
  final BusinessEntryOwner businessEntry;

  /// 放行通知，仅在 [businessEntry] == host 时存在；每次 proceeded 只通知一次。
  ///
  /// 用 [businessEntry] 二选一，而不是注释里的「二选一」：两处同时导航会叠出第二个
  /// 业务页（ConsentActivity.java:150-155 只有一处 startActivity）。
  final VoidCallback? onProceed;

  /// 视图无法呈现当前流程状态（或无法把一次回答交给流程机）时的上报口。
  ///
  /// 触发点（全部是「不变量被破坏」，本层既不猜也不静默）：
  /// -  说 phase==awaitingConsent，但 `gate.pendingRegion` 为 null/other；
  /// - 一次回答被流程机拒绝（approve/decline 抛错）：弹窗已关、错误已上报，
  ///   但只要流程仍停在 awaitingConsent，页面会重新弹窗让人再答（见 [_showConsentDialogLoop]）；
  /// - 弹窗既不是同意也不是退出被关掉（外部 pop）：无法判断意图。
  final void Function(String reason)? onPresentationBroken;

  /// 隐私链接点击回调。本仓库没有 url_launcher 之类依赖，默认 null 表示不跳转；
  /// 宿主可注入真正的打开实现（ConsentActivity.java:136-140 的 LinkMovementMethod 对应物）。
  final void Function(String url)? onPrivacyLinkTap;

  @override
  State<ConsentPage> createState() => _ConsentPageState();
}

class _ConsentPageState extends State<ConsentPage> {
  TapGestureRecognizer? _privacyLinkRecognizer;

  /// 当前正文里被点击的 URL：识别器是复用的，所以 URL 必须随 span 一起更新，
  /// 不能在上报时再去猜（那时弹窗可能已经关了）。
  String? _privacyUrl;

  /// 当前这一轮弹窗是否已经收下一次回答（防重复 pop / 重复 approve）。
  ///
  /// 流程机的 approve/decline 只在 ConsentPhase.awaitingConsent 合法，
  /// 否则抛 StateError；视图层的重复点击必须在这里挡住，不能靠流程机兜底。
  /// **只挡「同一轮弹窗」**：每轮展示前 [_showConsentDialogLoop] 都会复位它，
  /// 否则一次失败的回答会把页面永久锁死（ 原缺陷：_decisionTaken 在
  /// gate.approve() 抛错前就置 true 且再无人复位）。
  bool _decisionTaken = false;

  /// 弹窗循环是否已在跑：防止重复 _settleFlow 叠出两个对话框。
  bool _dialogLoopActive = false;

  /// 是否已经通知过宿主的 onProceed：保证每次 proceeded 只通知一次。
  bool _proceedNotified = false;

  @override
  void initState() {
    super.initState();
    // 不 await：门槛判定与弹窗都在后台推进，页面本身只是承载。
    unawaited(_runGate());
  }

  @override
  void dispose() {
    _privacyLinkRecognizer?.dispose();
    super.dispose();
  }

  Future<void> _runGate() async {
    await widget.gate.start();
    if (!mounted) {
      return;
    }
    await _settleFlow();
  }

  /// 按流程机的真实阶段决定「还要不要再展示一次」。
  Future<void> _settleFlow() async {
    // canPop 是 build 期捕获的：phase 变化后必须重建，否则同意之后 PopScope 仍停在
    // false，返回键永远被吃掉（ConsentActivity.java:159-162 是每次按键实时读 isGranted）。
    setState(() {});
    switch (widget.gate.phase) {
      case ConsentPhase.proceeded:
        _notifyProceeded();
        return;
      case ConsentPhase.awaitingConsent:
        await _showConsentDialogLoop();
        return;
      case ConsentPhase.idle:
      case ConsentPhase.probing:
      case ConsentPhase.declined:
      case ConsentPhase.terminated:
        // 退出由 ConsentPorts.exitApp 完成（ConsentActivity.java:126-128），
        // 宿主销毁时不做事（:95-97）。这里既不导航也不推进流程。
        return;
    }
  }

  void _notifyProceeded() {
    if (_proceedNotified) {
      return;
    }
    _proceedNotified = true;
    // ports 模式：导航已由 流程机的 enterBusiness 完成，这里绝不重复导航。
    widget.onProceed?.call();
  }

  /// 展示待决同意弹窗；一次回答失败后必须能重来。
  ///
  /// 流程机的 approve 在 writeGrant/startSdks/enterBusiness 抛错时会恢复 _pendingRegion
  /// 并 rethrow（consent_gate.dart:513-552），phase 仍是 awaitingConsent：流程机还在等人
  /// 回答，视图却已经把弹窗关掉了。所以这里按流程机的**真实阶段**循环：
  ///
  /// - 只要仍是 awaitingConsent，就重新读 `gate.pendingRegion`（失败时它已被恢复）再弹；
  /// - 每轮展示前复位 [_decisionTaken]：它只挡同一轮内的重复点击/重复 pop，
  ///   不能变成「失败一次就永久锁死」；
  /// - proceeded 才通知宿主；declined/terminated 由 while 条件自然退出。
  ///
  /// 已落盘的 grant 不会被重复写：重试仍走 流程机的 approve，它用 _recordPersisted
  /// 判别，只有写盘失败过才会再 writeGrant（consent_gate.dart:513-552）。
  Future<void> _showConsentDialogLoop() async {
    if (_dialogLoopActive) {
      return;
    }
    _dialogLoopActive = true;
    try {
      while (mounted && widget.gate.phase == ConsentPhase.awaitingConsent) {
        final ConsentRegion? region = widget.gate.pendingRegion;
        if (region == null || region == ConsentRegion.other) {
          // 没有待决地区（或读数给了 other）却进了 awaitingConsent： 不变量被破坏。
          // 不弹空窗、不猜地区（ConsentDialogCopy.forRegion(other) 会抛），但也不能静默：
          // 上报宿主。 会停在 awaitingConsent，本页不伪造放行。
          final String broken = region == null ? 'null' : region.name;
          widget.onPresentationBroken?.call(
            'awaitingConsent without a pending region: $broken',
          );
          return;
        }
        // 新一轮展示 = 一次新的首答窗口：上一轮失败留下的锁必须在这里释放。
        _decisionTaken = false;
        await showDialog<void>(
          context: context,
          // ConsentActivity.java:121 setCancelable(false)、:130 setCanceledOnTouchOutside(false)。
          barrierDismissible: false,
          builder: (BuildContext dialogContext) => _consentDialog(dialogContext, region),
        );
        if (!mounted) {
          return;
        }
        // 决定之后 phase 已经不是 awaitingConsent：重建，让 PopScope 拿到新的 canPop。
        setState(() {});
        if (widget.gate.phase == ConsentPhase.proceeded) {
          _notifyProceeded();
          return;
        }
        if (!_decisionTaken) {
          // 弹窗不是被两个按钮关掉的（外部 pop 等）：不猜意图，交给宿主。
          widget.onPresentationBroken?.call('consent dialog dismissed without a decision');
          return;
        }
        // 否则仍是 awaitingConsent（一次回答被流程机拒绝）：循环重弹，读恢复后的真实读数。
      }
    } finally {
      _dialogLoopActive = false;
    }
  }

  /// 弹窗本体（ConsentActivity.java:116-141）。
  ///
  /// 几何只留一层：Qt 用的是**系统** AlertDialog，自己没有任何 padding
  /// （ConsentActivity.java:116-141 只 setTitle/setMessage/setButton）。Flutter 的
  /// AlertDialog 自带 insetPadding（SDK 默认横 40/竖 24，dialog.dart:32/:267-269）与
  /// minWidth 280（:274-275），这里显式写出同一组值并作为唯一一层，不再套外层
  /// Padding —— 旧实现外层 Padding（竖屏横 48/侧）与默认 inset（横 40/侧）叠加，
  /// 每侧横 88（合计 176）；360dp 竖屏下 AlertDialog 盒只剩 264dp，Material 内部
  /// 内容宽 184dp（< 280dp minWidth）。
  Widget _consentDialog(BuildContext dialogContext, ConsentRegion region) {
    final ConsentDialogCopy copy = ConsentDialogCopy.forRegion(region);
    return PopScope(
      // ConsentActivity.java:134：弹窗期间返回键被吃掉。
      canPop: false,
      child: AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 560),
        title: Text(copy.title),
        scrollable: true,
        content: Text.rich(
          _messageSpan(dialogContext, copy.message),
        ),
        actions: <Widget>[
          // 负向按钮在前（Android AlertDialog 的按钮顺序）。
          TextButton(
            onPressed: () => _answer(dialogContext, agreed: false),
            child: Text(copy.exitLabel),
          ),
          TextButton(
            onPressed: () => _answer(dialogContext, agreed: true),
            child: Text(copy.approveLabel),
          ),
        ],
      ),
    );
  }

  /// 回答弹窗（ConsentActivity.java:122-125 同意 / :126-128 退出）。
  ///
  /// 副作用全部由 流程机的流程机完成（writeGrant / startSdks / enterBusiness / exitApp），
  /// 这里只调用一次并关掉弹窗。
  void _answer(BuildContext dialogContext, {required bool agreed}) {
    if (_decisionTaken) {
      return;
    }
    //  只允许在 awaitingConsent 回答；否则 approve/decline 抛 StateError。
    if (widget.gate.phase != ConsentPhase.awaitingConsent) {
      return;
    }
    _decisionTaken = true;
    Object? failure;
    try {
      if (agreed) {
        widget.gate.approve();
      } else {
        widget.gate.decline();
      }
    } catch (error) {
      // 流程机拒绝这次回答：可能是某次端口调用抛错（writeGrant/startSdks/
      // enterBusiness），也可能是阶段已被并发改掉。无论哪种，弹窗必须照样
      // 关掉，否则页面留着一个永远点不动的对话框；失败只上报，不吞掉。
      failure = error;
    } finally {
      if (dialogContext.mounted) {
        Navigator.of(dialogContext).pop();
      }
    }
    if (failure != null) {
      widget.onPresentationBroken?.call('consent decision rejected: $failure');
    }
  }

  /// 文案 span：文本逐字节等于  常量（= Qt text block）；正文里的隐私 URL
  /// 单独成 span 并可点（ConsentActivity.java:136-140 给正文装 LinkMovementMethod）。
  ///
  /// URL 从文案里现场定位，不在本层再抄一份字面量：文案只有一个真值。
  InlineSpan _messageSpan(BuildContext context, String message) {
    final int urlIndex = message.indexOf('https://');
    if (urlIndex < 0) {
      // EU 文案没有链接：清掉上一次（CN）残留的 URL —— 识别器是复用的，
      // 回调不能报出上一个弹窗的地址。
      _privacyUrl = null;
      return TextSpan(text: message);
    }
    int urlEnd = urlIndex;
    while (urlEnd < message.length && !_isUrlTerminator(message[urlEnd])) {
      urlEnd += 1;
    }
    final String url = message.substring(urlIndex, urlEnd);
    _privacyUrl = url;
    TapGestureRecognizer? recognizer = _privacyLinkRecognizer;
    if (recognizer == null) {
      recognizer = TapGestureRecognizer()..onTap = _handlePrivacyLinkTap;
      _privacyLinkRecognizer = recognizer;
    }
    return TextSpan(
      text: message.substring(0, urlIndex),
      children: <InlineSpan>[
        TextSpan(
          text: url,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            decoration: TextDecoration.underline,
          ),
          recognizer: recognizer,
        ),
        TextSpan(text: message.substring(urlEnd)),
      ],
    );
  }

  static bool _isUrlTerminator(String ch) =>
      ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t';

  void _handlePrivacyLinkTap() {
    final String? url = _privacyUrl;
    if (url == null) {
      return;
    }
    widget.onPrivacyLinkTap?.call(url);
  }

  @override
  Widget build(BuildContext context) {
    // Qt 侧 ConsentActivity 没有自己的界面（只有对话框），这里给一个空承载页；
    // 返回键语义由 PopScope 复刻 ConsentActivity.java:158-164（backPressed 是权威读数）。
    //
    // 底色必须是黑的：Qt 的 RhineConsent 主题是 Theme.DeviceDefault.NoActionBar +
    // android:windowBackground=black + android:windowDisablePreview=true
    // （Qt/android/res/values/styles.xml:8-14），目的是「已同意」时几乎看不见这一屏、
    // 弹窗路径也不闪白。显式黑底是复刻这条既有关窗行为，不是新增竖屏像素。
    return PopScope(
      // 固定 key：测试要能区分「页面级返回键策略」与「弹窗内那条 canPop:false」。
      key: const ValueKey<String>('consent-page-pop'),
      canPop: widget.gate.backPressed(),
      child: const Scaffold(
        // 固定 key：测试要能区分承载页与弹窗内部的 Scaffold（AlertDialog 不带 Scaffold，
        // 但按钮/滚动视图会带 key，明确一个更稳）。
        key: ValueKey<String>('consent-gate-surface'),
        backgroundColor: Color(0xFF000000),
        body: SizedBox.expand(),
      ),
    );
  }
}
