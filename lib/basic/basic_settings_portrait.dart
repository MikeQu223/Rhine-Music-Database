// ===========================================================================
// 竖屏设置整页（Qt compact `ResponsiveHudLayout::settings()`）
//
// 为什么不再复用 BasicSettingsWindow：那套几何是给 1080 舞台 + 1260 面板设计的
// 绝对坐标（SettingsPanelGeometry.viewport 写死 viewportTop=176/height=660，
// placeSettingsRow 的控件宽 SettingsRowMetrics.controlWidth=300 固定），竖屏
// 把 456 宽的稿子整体放大到 1080 舞台后，控件必然压住标题，字号也一起被放大
// （实机「全部挤在一起、元素过大」）。
//
// 因此这一层按 Qt compact 的真实规格重排：393 设计网格 + Transform.scale(unit)，
// 行高 56、标题 (20, y+19) 12 号、控件 (201, y+9) 172×34、展开项 chip 353×40，
// 页面只铺到 `h - portraitFooterHeight`（播放条与底栏仍由 HUD 画布负责）。
//
// 真值仍只有一份：行/选项/可见性/enable/展开态来自 BasicSettingsPanelModel，
// 动作串沿用既有契约（'expand:<id>'、'setting-edit:<id>'、
// `<actionPrefix><value>`、row.action、'disc-rotation'），全部回灌 BasicApp 的
// _onSettingsAction → _settings.apply(...)，不新建状态、不做持久化。
// ===========================================================================
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../hud/modals/settings_modal.dart';
import '../hud/portrait/portrait_layout.dart'
    show portraitDesignWidth, portraitFooterHeight, portraitGridWidth, portraitUnit;
import '../hud/protocol/hud_frame.dart' show HudStage;
import '../hud/widgets/settings_row.dart';
import 'basic_settings.dart';

/// 设置整页的 root key（测试用 finder）。
const Key basicPortraitSettingsPageKey =
    ValueKey<String>('settings-portrait-page');

/// 内容区起点（Qt `c.beginContent(terminalPage ? 130 : …)`）。
///
/// 130 之前是 HUD 画的终端页头（品牌 / 大标题 / 编号块 / 墨线 / 校准刻度）：
/// 页头留在命令流里，才能和其它竖屏页共用同一份字形真值。
const double basicPortraitSettingsContentTop = 130;

/// 竖屏设置整页：只有内容区是真实 Flutter 控件（文本/点击/滚动/焦点都是 widget）。
class BasicPortraitSettingsPage extends StatefulWidget {
  const BasicPortraitSettingsPage({
    super.key,
    required this.stage,
    required this.model,
    required this.dark,
    required this.onAction,
    this.scrollStorage,
    this.scrollMaximumStorage,
    this.stageScale = 0,
  });

  /// 竖屏舞台：width 恒 1080，height 为舞台高，scale 恒 1（缩放在 PortraitStage）。
  final HudStage stage;

  /// 唯一真值来源（BasicApp._settingsPanelModel()）。
  final BasicSettingsPanelModel model;

  final bool dark;

  /// 动作统一回灌宿主；只有滚动两枚就地消费。
  final ValueChanged<String> onAction;

  /// 可选：滚动偏移存到宿主，重开面板时接上。
  final ValueNotifier<double>? scrollStorage;

  /// 可选：把真实可滚动距离公布给宿主（键盘滚动 clamp 的上界）。
  final ValueNotifier<double>? scrollMaximumStorage;

  /// 竖屏窗口缩放比（逻辑 dp / 舞台像素，= PortraitBands.stageScale）。
  /// 用来和 HUD 画布同一口径把 393 网格压进 clamp 后的 dp 带；0 = 不压缩。
  final double stageScale;

  @override
  State<BasicPortraitSettingsPage> createState() =>
      _BasicPortraitSettingsPageState();
}

class _BasicPortraitSettingsPageState extends State<BasicPortraitSettingsPage> {
  /// 当前页宽（网格）：DPI 适配后比设计稿 393 宽，行内控件按右缘锚定。
  double _pageWidth = portraitDesignWidth;

  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: widget.scrollStorage?.value ?? 0,
  );

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    widget.scrollStorage?.addListener(_onStorageOffset);
  }

  @override
  void didUpdateWidget(covariant BasicPortraitSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollStorage != widget.scrollStorage) {
      oldWidget.scrollStorage?.removeListener(_onStorageOffset);
      widget.scrollStorage?.addListener(_onStorageOffset);
    }
  }

  /// 宿主改偏移（键盘上下键）→ 真实 ScrollController 跟随；0.5px 死区断回环。
  void _onStorageOffset() {
    final ValueNotifier<double>? storage = widget.scrollStorage;
    if (storage == null || !_scroll.hasClients) {
      return;
    }
    final double max =
        _scroll.position.maxScrollExtent.clamp(0.0, double.infinity).toDouble();
    final double target = storage.value.clamp(0.0, max).toDouble();
    if ((target - _scroll.offset).abs() > 0.5) {
      _scroll.jumpTo(target);
    }
  }

  @override
  void dispose() {
    widget.scrollStorage?.removeListener(_onStorageOffset);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    widget.scrollStorage?.value = _scroll.offset;
    final ValueNotifier<double>? maximum = widget.scrollMaximumStorage;
    if (maximum != null && _scroll.hasClients) {
      maximum.value = _scroll.position.maxScrollExtent;
    }
  }

  void _handle(String action) {
    if (action.isEmpty) {
      return;
    }
    widget.onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    // DPI 适配：网格单位与网格宽度都从 portrait_layout 取，和 HUD 命令流同源——
    // 页面宽度 = 舞台宽 / 网格单位（比设计稿 393 宽），元素尺寸不变、页面铺满。
    final double unit = portraitUnit(widget.stage.width, stageScale: widget.stageScale);
    final double gridWidth = portraitGridWidth(widget.stage.width, stageScale: widget.stageScale);
    final double gridHeight =
        unit > 0 ? widget.stage.height / unit : portraitDesignWidth;
    final double pageBottom = math.max(0.0, gridHeight - portraitFooterHeight);
    if (unit <= 0 || pageBottom <= basicPortraitSettingsContentTop) {
      return const SizedBox.shrink();
    }
    _pageWidth = gridWidth;
    final _PortraitInk ink = _PortraitInk.of(widget.dark);
    return ClipRect(
      key: basicPortraitSettingsPageKey,
      child: SizedBox(
        width: widget.stage.width,
        height: pageBottom * unit,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          maxWidth: double.infinity,
          minHeight: 0,
          maxHeight: double.infinity,
          child: Transform.scale(
            scale: unit,
            alignment: Alignment.topLeft,
            child: Padding(
              padding: EdgeInsets.zero,
              child: SizedBox(
                width: gridWidth,
                height: pageBottom,
                child: Stack(
                  children: <Widget>[
                    Positioned(
                      left: 0,
                      right: 0,
                      top: basicPortraitSettingsContentTop,
                      bottom: 0,
                      child: SingleChildScrollView(
                        controller: _scroll,
                        padding: EdgeInsets.zero,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: _content(ink),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 内容排版
  // -------------------------------------------------------------------------

  List<Widget> _content(_PortraitInk ink) {
    final List<Widget> children = <Widget>[];
    for (final SettingsSectionModel section in widget.model.sections) {
      children.add(_sectionHeader(section.spec, ink));
      final String renderer = section.spec.customRenderer;
      if (renderer == basicSettingsDiscRotationRenderer) {
        children.add(_discRotationRow(ink));
      } else if (renderer == basicSettingsVersionRenderer) {
        children.add(_versionLines(ink));
      } else if (renderer.isNotEmpty) {
        // 其它自定义区没有竖屏版式：不画半截假控件，留一行诚实文案。
        children.add(_notice('该分区尚未移植到竖屏', ink));
      } else {
        for (final SettingsRowSpec row in section.rows) {
          children.add(_row(row, ink));
          if (row.expanded && row.choices.isNotEmpty) {
            for (final SettingsChoice choice in row.choices) {
              children.add(_choiceChip(row, choice, ink));
            }
          }
        }
      }
      children.add(const SizedBox(height: 14));
    }
    children.add(const SizedBox(height: 28));
    return children;
  }

  /// 分区头（Qt `terminalSection`）：墨块序号 + 中文标题 + 右对齐英文。
  Widget _sectionHeader(SettingsSectionSpec spec, _PortraitInk ink) {
    return SizedBox(
      height: 27,
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 20,
            top: 0,
            child: Container(
              width: 23,
              height: 18,
              color: ink.ink,
              alignment: Alignment.center,
              child: Text(
                spec.numberText,
                style: _style(8, ink.paper),
              ),
            ),
          ),
          Positioned(
            left: 51,
            top: 2,
            child: Text(spec.titleZh, style: _style(13, ink.ink, demibold: true)),
          ),
          _rightText(spec.titleEn, top: 5, size: 7, color: ink.muted),
        ],
      ),
    );
  }

  /// 普通行（Qt settings() 的行分支，行高 56）。
  Widget _row(SettingsRowSpec row, _PortraitInk ink) {
    final bool isChoice = row.kind == SettingsRowKind.choice ||
        row.kind == SettingsRowKind.switchRow;
    final String hitAction = !row.enabled
        ? ''
        : isChoice
            ? 'expand:' + row.id
            : row.kind == SettingsRowKind.textInput
                ? 'setting-edit:' + row.id
                : row.action;
    final String controlText =
        row.actionLabel.isEmpty ? row.label : row.actionLabel;
    final bool stepper = row.kind == SettingsRowKind.slider ||
        row.kind == SettingsRowKind.stepper;
    final String route =
        row.actionPrefix.isNotEmpty ? row.actionPrefix : row.action;

    return SizedBox(
      height: 56,
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 20,
            top: 19,
            width: _pageWidth - 222,
            child: Text(
              row.titleZh,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _style(12, row.enabled ? ink.ink : ink.muted),
            ),
          ),
          if (row.restartHint.isNotEmpty)
            Positioned(
              left: 20,
              top: 36,
              width: _pageWidth - 222,
              child: Text(
                row.restartHint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _style(10, ink.muted),
              ),
            ),
          if (stepper) ...<Widget>[
            Positioned(
              left: _pageWidth - 192,
              top: 19,
              width: 70,
              child: Text(
                controlText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _style(11, ink.muted),
              ),
            ),
            _stepButton(
              left: _pageWidth - 115,
              glyph: '−',
              action: row.enabled ? route + row.decrementValue : '',
              ink: ink,
            ),
            _stepButton(
              left: _pageWidth - 65,
              glyph: '+',
              action: row.enabled ? route + row.incrementValue : '',
              ink: ink,
            ),
          ] else ...<Widget>[
            Positioned(
              left: _pageWidth - 192,
              top: 9,
              child: Container(width: 172, height: 34, color: ink.surface),
            ),
            Positioned(
              left: _pageWidth - 182,
              top: 19,
              width: 137,
              child: Text(
                controlText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _style(11, row.enabled ? ink.muted : ink.faint),
              ),
            ),
            Positioned(
              left: _pageWidth - 38,
              top: 18,
              width: 16,
              child: Text(
                isChoice ? '⌄' : '↗',
                style: _style(12, ink.muted),
              ),
            ),
          ],
          _tapArea(
            left: _pageWidth - 198,
            top: 4,
            width: 178,
            height: 44,
            action: hitAction,
            label: row.titleZh,
          ),
          Positioned(
            left: 20,
            top: 55,
            right: 20,
            height: .6,
            child: ColoredBox(color: ink.line),
          ),
        ],
      ),
    );
  }

  /// 展开后的选项（Qt `chip({20, y, 353, 40})`，步进 48）。
  Widget _choiceChip(
    SettingsRowSpec row,
    SettingsChoice choice,
    _PortraitInk ink,
  ) {
    final bool selected = choice.value == row.value.canonical;
    final String route =
        row.actionPrefix.isNotEmpty ? row.actionPrefix : row.action;
    return SizedBox(
      height: 48,
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 20,
            top: 4,
            child: Container(
              width: _pageWidth - 40,
              height: 40,
              color: selected ? ink.raised : ink.surface,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                choice.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _style(11, selected ? ink.ink : ink.muted),
              ),
            ),
          ),
          Positioned(
            left: 20,
            top: 4,
            child: Container(
              width: _pageWidth - 40,
              height: 40,
              decoration: BoxDecoration(
                border: Border.all(
                  color: selected ? ink.muted : ink.line,
                  width: .7,
                ),
              ),
            ),
          ),
          _tapArea(
            left: 20,
            top: 4,
            width: _pageWidth - 40,
            height: 40,
            action: row.enabled ? route + choice.value : '',
            label: choice.label,
          ),
        ],
      ),
    );
  }

  /// 唱片旋转（Qt 自定义区 basic-disc-rotation 的单行版）。
  Widget _discRotationRow(_PortraitInk ink) {
    final bool on = widget.model.discRotation;
    return SizedBox(
      height: 56,
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 20,
            top: 19,
            width: _pageWidth - 222,
            child: Text('唱片旋转', style: _style(12, ink.ink)),
          ),
          Positioned(
            left: _pageWidth - 192,
            top: 9,
            child: Container(width: 172, height: 34, color: ink.surface),
          ),
          Positioned(
            left: _pageWidth - 182,
            top: 19,
            width: 137,
            child: Text(on ? '开启' : '关闭', style: _style(11, ink.muted)),
          ),
          Positioned(
            left: _pageWidth - 38,
            top: 18,
            width: 16,
            child: Text('⌄', style: _style(12, ink.muted)),
          ),
          _tapArea(
            left: _pageWidth - 198,
            top: 4,
            width: 178,
            height: 44,
            // 开启要走风险确认（BasicSettingsRuntime 的 disc-rotation-warning），
            // 分发仍由宿主的 _onSettingsAction 负责。
            action: 'disc-rotation',
            label: '唱片旋转',
          ),
          Positioned(
            left: 20,
            top: 55,
            right: 20,
            height: .6,
            child: ColoredBox(color: ink.line),
          ),
        ],
      ),
    );
  }

  /// 版本区（Qt 自定义区 basic-version 的两行纯文本）。
  Widget _versionLines(_PortraitInk ink) {
    return SizedBox(
      height: 52,
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 20,
            top: 4,
            width: _pageWidth - 40,
            child: Text(
              widget.model.version.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _style(12, ink.ink),
            ),
          ),
          if (!widget.model.version.releaseBuild &&
              widget.model.version.commitTitle.isNotEmpty)
            Positioned(
              left: 20,
              top: 26,
              width: _pageWidth - 40,
              child: Text(
                widget.model.version.commitTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _style(10, ink.muted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _notice(String text, _PortraitInk ink) {
    return SizedBox(
      height: 44,
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 20,
            top: 14,
            width: _pageWidth - 40,
            child: Text(text, style: _style(11, ink.muted)),
          ),
        ],
      ),
    );
  }

  /// ± 按钮（Qt `button({279|329, y+4, 44, 44})`）。
  Widget _stepButton({
    required double left,
    required String glyph,
    required String action,
    required _PortraitInk ink,
  }) {
    return Positioned(
      left: left,
      top: 4,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          children: <Widget>[
            Container(color: ink.surface),
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: ink.line, width: .7),
                ),
              ),
            ),
            Center(child: Text(glyph, style: _style(16, ink.ink))),
            _tapArea(
              left: 0,
              top: 0,
              width: 44,
              height: 44,
              action: action,
              label: glyph,
            ),
          ],
        ),
      ),
    );
  }

  /// 一块可点区域；动作串为空时只占位不响应（disabled 行）。
  Widget _tapArea({
    required double left,
    required double top,
    required double width,
    required double height,
    required String action,
    required String label,
  }) {
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: action.isEmpty ? null : () => _handle(action),
        child: Semantics(
          button: action.isNotEmpty,
          label: label,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  /// 右对齐小字（Qt `rightText`：右边界在 373）。
  Widget _rightText(
    String value, {
    required double top,
    required double size,
    required Color color,
  }) {
    return Positioned(
      left: 20,
      right: 20,
      top: top,
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(value, style: _style(size, color)),
      ),
    );
  }

  TextStyle _style(double size, Color color, {bool demibold = false}) {
    return TextStyle(
      fontSize: size,
      color: color,
      fontWeight: demibold ? FontWeight.w600 : FontWeight.w400,
      height: 1.2,
      letterSpacing: .2,
    );
  }
}

/// 竖屏配色（与 `PortraitCanvas` 的暗/亮两套同一组真值）。
class _PortraitInk {
  const _PortraitInk({
    required this.ink,
    required this.muted,
    required this.faint,
    required this.line,
    required this.surface,
    required this.raised,
    required this.paper,
  });

  factory _PortraitInk.of(bool dark) {
    Color rgb(double r, double g, double b) => Color.fromRGBO(
          (r * 255).round(),
          (g * 255).round(),
          (b * 255).round(),
          1,
        );
    if (dark) {
      final Color ink = rgb(.925, .933, .886);
      return _PortraitInk(
        ink: ink,
        muted: rgb(.63, .68, .60),
        faint: ink.withValues(alpha: .35),
        line: rgb(.23, .28, .24),
        surface: rgb(.125, .165, .137),
        raised: rgb(.165, .208, .173),
        paper: rgb(.075, .110, .094),
      );
    }
    final Color ink = rgb(.082, .110, .090);
    return _PortraitInk(
      ink: ink,
      muted: rgb(.404, .431, .388),
      faint: ink.withValues(alpha: .35),
      line: rgb(.741, .753, .702),
      surface: rgb(.910, .902, .863),
      raised: rgb(.871, .875, .820),
      paper: rgb(.933, .925, .894),
    );
  }

  final Color ink;
  final Color muted;
  final Color faint;
  final Color line;
  final Color surface;
  final Color raised;
  final Color paper;
}
