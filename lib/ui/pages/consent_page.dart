// T42 —— Consent 门槛页（Qt ConsentActivity 的 1:1 presentation 层）。
//
// Qt 侧证据（唯一真值，Qt/android/src/rhine/music/database/）：
// - ConsentActivity.java:22-24 清单里 ConsentActivity 是 LAUNCHER、QtActivity 不对外暴露：
//   同意之前 Qt/Clarity/Bugly 一个都没起来，不是「先加载界面再补弹窗」。
// - ConsentActivity.java:69-72 已同意 → 直接按持久 region 放行，不再判定地区、不再弹窗。
// - ConsentActivity.java:76-107 未同意 → 判定地区（3 秒硬闸门）→ CN/EU 弹窗；
//   其他/超时/异常直接放行，且不写持久标记（:101-104）。
// - ConsentActivity.java:116-141 弹窗：标题/正文/按钮按地区取值、setCancelable(false)、
//   返回键无效、隐私链接可点。
// - ConsentActivity.java:143-156 放行：先启动 SDK，再进业务页（CLEAR_TOP | SINGLE_TOP）。
// - ConsentActivity.java:158-164 系统返回键只在已同意时有效。
// - Qt/android/res/values/styles.xml:8-14 RhineConsent 主题：windowBackground=black、
//   windowDisablePreview=true —— 这一屏是纯黑承载页，弹窗路径不会闪白。
//
// ── 流程 owner（X20-LIFECYCLE；adjudication-handover-26.json decisions[2]）──
// 唯一流程 / 持久化 / SDK starter owner 是 T27 的 lib/app/consent_gate.dart：
//   ConsentGate（start/approve/decline/backPressed/terminate + phase/snapshot/计数）
//   ConsentPorts（readRecord/writeGrant/probeRegion/startSdks/enterBusiness/exitApp）
//   ConsentSdkStarter（Clarity 与 Bugly 两个分开的幂等标志）
//   ConsentRegion / ConsentPhase / ConsentDialogCopy / CN|EU 文案常量 / 3000ms。
// 本文件**不实现**任何流程、不复制地区判定、不复制文案、不建第二个 SDK starter；
// 它只做三件事：渲染弹窗、把两个按钮与返回键翻译成一次 T27 调用、把「已放行」
// 通知给宿主导航钩子。
//
// ── 待集成依赖（精确给出，不越 scope 复制第三份）──
// import 'package:rhine_music_database/app/consent_gate.dart';
// 该文件由 T27 在 commit e46b08cf 引入（blob 87aecd0c4717b7e2022f173d7863ed2028407255，
// 658 行），本 T42 基线（8ed3067）尚未包含它：T42 只写依赖与所需接口，合并时由
// 主集成把 T27 的这一个文件带入即可，双方都不需要第二套实现。
// 本页需要的 T27 读数中，唯一还不存在的成员是「待决地区」：ConsentGate 目前只在
// _pendingRegion 里保存它、未公开。集成时二选一（二选一即可，勿两种都加）：
//   (a) ConsentGate 增加 `ConsentRegion? get pendingRegion => _pendingRegion;`，页面直接读；
//   (b) 保持 T27 不变，由 host 构造本页时传 regionOfPendingDecision（见构造参数）。
// 本文件按 (b) 编写，因此不编译依赖任何尚不存在的成员。

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:rhine_music_database/app/consent_gate.dart';

// ============================================================================
// 页面
// ============================================================================

/// 谁执行 ConsentActivity.java:148-155 的「startActivity(QtActivity)」。
///
/// Qt 只有一处导航；Flutter 有两个天然落点：T27 的 [ConsentPorts.enterBusiness]
/// （流程机内部）与页面的 [ConsentPage.onProceed]（宿主钩子）。两者同时生效会叠出
/// 第二个业务页，所以这里把它变成构造期必须声明的类型，而不是注释里的君子协定。
enum BusinessEntryOwner {
  /// T27 的 ConsentPorts.enterBusiness 负责导航；页面不再调 onProceed。
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
    required this.regionOfPendingDecision,
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

  /// T27 的唯一流程机。本页只调用 start/approve/decline/backPressed 并读 phase。
  final ConsentGate gate;

  /// 导航归属（见 [BusinessEntryOwner]）：默认由宿主在 [onProceed] 里导航。
  final BusinessEntryOwner businessEntry;

  /// 放行通知，仅在 [businessEntry] == host 时存在；每次 proceeded 只通知一次。
  ///
  /// 用 [businessEntry] 二选一，而不是注释里的「二选一」：两处同时导航会叠出第二个
  /// 业务页（ConsentActivity.java:150-155 只有一处 startActivity）。
  final VoidCallback? onProceed;

  /// 待决地区读数（见文件头的待集成接口 a/b 二选一）。
  ///
  /// 集成 T27 提供 `ConsentGate.pendingRegion` 之后，宿主传 `() => gate.pendingRegion`
  /// 即可，本页与测试都不需要改。本层不自己维护地区状态。
  final ConsentRegion? Function() regionOfPendingDecision;

  /// 视图无法呈现当前流程状态时的上报口。
  ///
  /// 目前只有一个触发点：T27 说 phase==awaitingConsent，但待决地区读数为 null/other。
  /// 这是流程不变量被破坏，本层既不猜地区也不静默吞掉——交给宿主记录并决定处置
  /// （T27 会一直停在 awaitingConsent，本页不会伪造放行）。
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

  /// 弹窗的两个按钮只接受第一次回答（防重复 pop / 重复 approve）。
  ///
  /// T27 的 approve()/decline() 只在 ConsentPhase.awaitingConsent 合法，
  /// 否则抛 StateError；视图层的重复点击必须在这里挡住，不能靠流程机兜底。
  bool _decisionTaken = false;

  /// 已经通知过宿主几次 onProceed：保证每次 proceeded 只通知一次。
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
    // canPop 是 build 期捕获的：phase 变化后必须重建，否则同意之后 PopScope 仍停在
    // false，返回键永远被吃掉（ConsentActivity.java:159-162 是每次按键实时读 isGranted）。
    setState(() {});
    switch (widget.gate.phase) {
      case ConsentPhase.proceeded:
        _notifyProceeded();
        return;
      case ConsentPhase.awaitingConsent:
        await _showConsentDialog();
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
    // ports 模式：导航已由 T27 的 enterBusiness 完成，这里绝不重复导航。
    widget.onProceed?.call();
  }

  Future<void> _showConsentDialog() async {
    final ConsentRegion? region = widget.regionOfPendingDecision();
    if (region == null || region == ConsentRegion.other) {
      // 没有待决地区（或读数给了 other）却进了 awaitingConsent：T27 不变量被破坏。
      // 不弹空窗、不猜地区（ConsentDialogCopy.forRegion(other) 会抛），但也不能静默：
      // 上报宿主。T27 会停在 awaitingConsent，本页不伪造放行。
      final String broken = region == null ? 'null' : region.name;
      widget.onPresentationBroken?.call(
        'awaitingConsent without a pending region: ' + broken,
      );
      return;
    }
    await showDialog<void>(
      context: context,
      // ConsentActivity.java:121 setCancelable(false)、:130 setCanceledOnTouchOutside(false)。
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        final ConsentDialogCopy copy = ConsentDialogCopy.forRegion(region);
        final bool portrait =
            MediaQuery.orientationOf(dialogContext) == Orientation.portrait;
        // 竖屏给双倍安全边距；横屏额外限宽 560，避免长文案在大屏上拉成一行。
        return PopScope(
          // ConsentActivity.java:134：弹窗期间返回键被吃掉。
          canPop: false,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: portrait ? 48 : 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: AlertDialog(
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
            ),
          ),
        );
      },
    );
    if (!mounted) {
      return;
    }
    // 决定之后 phase 已经不是 awaitingConsent：重建，让 PopScope 拿到新的 canPop。
    setState(() {});
    if (widget.gate.phase == ConsentPhase.proceeded) {
      _notifyProceeded();
    }
  }

  /// 回答弹窗（ConsentActivity.java:122-125 同意 / :126-128 退出）。
  ///
  /// 副作用全部由 T27 的流程机完成（writeGrant / startSdks / enterBusiness / exitApp），
  /// 这里只调用一次并关掉弹窗。
  void _answer(BuildContext dialogContext, {required bool agreed}) {
    if (_decisionTaken) {
      return;
    }
    // T27 只允许在 awaitingConsent 回答；否则 approve/decline 抛 StateError。
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
      // 流程机拒绝这次回答（阶段已被并发改掉）：弹窗必须照样关掉，否则页面
      // 留着一个永远点不动的对话框。失败只上报，不吞掉。
      failure = error;
    } finally {
      if (dialogContext.mounted) {
        Navigator.of(dialogContext).pop();
      }
    }
    if (failure != null) {
      widget.onPresentationBroken?.call('consent decision rejected: ' + failure.toString());
    }
  }

  /// 文案 span：文本逐字节等于 T27 常量（= Qt text block）；正文里的隐私 URL
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
    // 返回键语义由 PopScope 复刻 ConsentActivity.java:158-164（T27 backPressed 是权威读数）。
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
