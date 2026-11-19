// ===========================================================================
// FINAL-ACCEPTANCE-155  settings window = real Flutter widget layer
//
// m03428（LATEST_DIRECT_USER_FLUTTER_SETTINGS4）把设置页从"HUD 命令/命中
// 画布"改成"真实 Flutter 控件"：文本、可点击控件、滚动、焦点、语义都必须
// 是 widget；只有装饰性自绘（1px 分隔线、轨道底色、金色进度条）沿用现有
// 绘制常量。因此本文件不调 any HUD painter / hit 列表来冒充控件，而是按
// lib/hud/modals/settings_modal.dart 与 lib/hud/widgets/settings_row.dart
// 里逐字记录的几何/文案/动作串，摆一套等价 widget。
//
// 真值只有一份：
//   * 行/选项/可见性/enable 来自 BasicSettingsPanelModel（settingsRowSpecFor）；
//   * 动作串沿用 paintSettingsRow 系列同一套（'expand:<id>'、
//     actionFor(row)+choice.value、'setting-edit:<id>'、'close-modal'、
//     'settings:scroll-up'/'settings:scroll-down'），全部回灌 BasicApp 的
//     _onSettingsAction → _settings.apply(...)，不新建状态；
//   * 几何/配色/字号来自 SettingsModalMetrics / SettingsPanelGeometry /
//     SettingsRowMetrics / SettingsHeaderMetrics / settingsScrollRail，
//     不复制数字。
//
// 舞台坐标：横屏时本层在逻辑像素里，需要自己按 stage.scale 缩放；竖屏由
// PortraitStage 的 Transform.scale 承担，本层直接吃 stage 单位（portrait）。
//
// 不做：持久化、生效、native 调用、路由。模态壳/返回键由 BasicApp 的
// PopScope 负责（_modal 非空时 Back 只收模态）。
// ===========================================================================
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../hud/modals/settings_modal.dart';
import '../hud/protocol/hud_frame.dart' show HudStage;
import '../hud/widgets/settings_row.dart';
import 'basic_settings.dart';
import 'basic_settings_surface.dart';

/// 设置窗口根 widget 的 key（测试用 finder）。
const Key basicSettingsWindowKey = ValueKey<String>('settings-window');

/// 单行控件的 key 前缀：`settings-control-<rowId>`。
String basicSettingsControlKey(String rowId) => 'settings-control-$rowId';

/// ONLY14 设置窗口：遮罩 + 面板 + 表头 + 真实控件行 + 滚动轨道。
class BasicSettingsWindow extends StatefulWidget {
  const BasicSettingsWindow({
    super.key,
    required this.stage,
    required this.model,
    required this.dark,
    required this.onAction,
    this.portrait = false,
    this.pluginsEntry = false,
    this.scrollStorage,
    this.scrollMaximumStorage,
  });

  /// 舞台几何：横屏用于换算逻辑像素，竖屏只读 width/height。
  final HudStage stage;

  /// 唯一真值来源（BasicApp._settingsPanelModel()）。
  final BasicSettingsPanelModel model;

  final bool dark;

  /// 动作统一回灌宿主（BasicApp._onSettingsAction）；只有滚动两枚就地消费。
  final ValueChanged<String> onAction;

  /// 竖屏时本层已在 stage 单位里（PortraitStage 负责缩放）。
  final bool portrait;

  /// 末尾追加「插件管理」入口卡（竖屏设置页末尾那张的横屏等价物）。
  ///
  /// Qt 横屏设置面板里没有这个入口；但插件页在横屏已经是独立 modal，
  /// 没有入口就进不去，所以在横屏设置末尾补一张同义的整宽卡片。
  final bool pluginsEntry;

  /// 可选：把滚动偏移存到宿主，重开面板时接上（null = 每次从 0 开始）。
  ///
  /// 宿主（BasicApp）既是读写这一份偏移的唯一入口，也是把键盘上下键的步进写回这里
  /// 的地方——见 [_onStorageOffset]。
  final ValueNotifier<double>? scrollStorage;

  /// 可选：把当前内容的真实可滚动距离（maxScrollExtent）公布给宿主。
  ///
  /// 键盘路径（NativeHudController.cpp:891-897 的 settingsScroll clamp）需要的是
  /// 舞台坐标下的 contentBottom；这个值只能由真正排完版的卡片给出，不能拍一个常数。
  final ValueNotifier<double>? scrollMaximumStorage;

  @override
  State<BasicSettingsWindow> createState() => _BasicSettingsWindowState();
}

class _BasicSettingsWindowState extends State<BasicSettingsWindow> {
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
  void didUpdateWidget(covariant BasicSettingsWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollStorage != widget.scrollStorage) {
      oldWidget.scrollStorage?.removeListener(_onStorageOffset);
      widget.scrollStorage?.addListener(_onStorageOffset);
    }
  }

  /// 宿主改偏移（键盘上下键）→ 真实 ScrollController 跟随。
  ///
  /// 面板自己的滚动仍然只经 [_onScroll] 写回存储；两边用 0.5px 的死区断开回环。
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
    // 轨道 thumb 跟随偏移：只重建本层（面板内容由 SingleChildScrollView 自己移位）。
    setState(() {});
  }

  void _handle(String action) {
    if (action == SettingsPanelGeometry.scrollUpAction) {
      _scrollBy(-SettingsModalMetrics.wheelStep);
      return;
    }
    if (action == SettingsPanelGeometry.scrollDownAction) {
      _scrollBy(SettingsModalMetrics.wheelStep);
      return;
    }
    widget.onAction(action);
  }

  void _scrollBy(double delta) {
    if (!_scroll.hasClients) {
      return;
    }
    final double max =
        _scroll.position.maxScrollExtent.clamp(0.0, double.infinity).toDouble();
    final double next = (_scroll.offset + delta).clamp(0.0, max).toDouble();
    if (next == _scroll.offset) {
      return;
    }
    _scroll.jumpTo(next);
  }

  void _scrollToFraction(double fraction) {
    if (!_scroll.hasClients) {
      return;
    }
    final double max = _scroll.position.maxScrollExtent;
    if (max <= 0) {
      return;
    }
    _scroll.jumpTo((fraction.clamp(0.0, 1.0) * max).toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final Widget content = _buildStage(context);
    if (widget.portrait) {
      return content;
    }
    final double scale = widget.stage.scale > 0 ? widget.stage.scale : 1.0;
    // 横屏：本层的外部空间是逻辑像素，HUD 绘制层内部同样按 stage.scale 缩放
    // （HudStagePainter.paint 的 canvas.scale(stage.scale)）。OverflowBox 让
    // stage 大小的子树不被父级紧约束压扁，Transform 只缩放绘制。
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: widget.stage.width,
        maxWidth: widget.stage.width,
        minHeight: widget.stage.height,
        maxHeight: widget.stage.height,
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: widget.stage.width,
            height: widget.stage.height,
            child: content,
          ),
        ),
      ),
    );
  }

  Widget _buildStage(BuildContext context) {
    final double stageWidth = widget.stage.width;
    // 竖屏（compact）的设置是整页，不是浮在主页上的卡片：参考图里它和资料库、检索
    // 一样是全屏页面，标题区在上、条目铺满整幅。横屏仍走既有的浮动卡片几何。
    final Rect bounds = widget.portrait
        ? Rect.fromLTWH(0, 0, stageWidth, math.max(widget.stage.height, 1))
        : settingsModalBounds(stageWidth);
    final Rect viewport = SettingsPanelGeometry.viewport(
      x: bounds.left,
      y: bounds.top,
      width: bounds.width,
    );
    final SettingsCardLayout baseLayout =
        layoutSettingsCard(viewport: viewport, model: widget.model.sections);
    // 末尾入口卡不在 settings 模型里：把内容高度补一行链接的高度，
    // 滚动上界用同一份 contentHeight 重算，否则卡片会被裁在可视区外。
    final double pluginsEntryHeight =
        widget.pluginsEntry ? SettingsRowMetrics.linkRowHeight : 0;
    final SettingsCardLayout layout = pluginsEntryHeight == 0
        ? baseLayout
        : SettingsCardLayout(
            viewport: baseLayout.viewport,
            sections: baseLayout.sections,
            contentHeight: baseLayout.contentHeight + pluginsEntryHeight,
            maximumScroll: SettingsRowMetrics.maximumScroll(
              baseLayout.contentHeight + pluginsEntryHeight,
              baseLayout.viewport.height,
            ),
          );
    // 真实可滚动距离公布给宿主：键盘上下键的 clamp 上界（NativeHudController.cpp:891-897）
    // 必须与这条 SingleChildScrollView 的实际内容一致，不能拍一个 1600 常数。
    final ValueNotifier<double>? maximum = widget.scrollMaximumStorage;
    if (maximum != null && (maximum.value - layout.maximumScroll).abs() > 0.01) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted) {
          maximum.value = layout.maximumScroll;
        }
      });
    }
    final SettingsPalette palette = basicSettingsPalette(dark: widget.dark);
    final double offset = _scroll.hasClients ? _scroll.offset : 0;
    final double maxScroll = layout.maximumScroll;
    if (_scroll.hasClients && offset > maxScroll) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted && _scroll.hasClients && _scroll.offset > maxScroll) {
          _scroll.jumpTo(maxScroll);
        }
      });
    }
    final Rect track = SettingsPanelGeometry.scrollTrack(
      x: bounds.left,
      y: bounds.top,
      width: bounds.width,
    );
    final Rect upButton =
        SettingsPanelGeometry.scrollUpButton(track: track, y: bounds.top);
    final Rect downButton =
        SettingsPanelGeometry.scrollDownButton(track: track, y: bounds.top);
    final SettingsScrollRail rail = settingsScrollRail(
      track: track,
      contentHeight: layout.contentHeight,
      viewportHeight: viewport.height,
      offset: offset,
    );

    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        key: basicSettingsWindowKey,
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: SettingsModalFrame.subtitle,
        child: FocusScope(
          autofocus: true,
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // 1) 全屏遮罩：吃掉所有落在面板外的指针（Qt/HUD 在下面，永不接手），
                //    点击空白处＝返回（Qt 只把关闭挂在返回按钮上，这里保持一致：遮罩
                //    本身不关闭，只拦截）。
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics: true,
                    onTap: () {},
                    child: ColoredBox(
                      // 竖屏整页设置：下层是主页，再压一层暗遮罩会变成两层页面的错觉。
                      color: widget.portrait
                          ? const Color(0x00000000)
                          : _color(SettingsModalMetrics.mask(widget.dark)),
                    ),
                  ),
                ),
                // 2) 面板底：同样是拦截层，点面板空白不穿透到 Qt。
                Positioned.fromRect(
                  rect: bounds,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics: true,
                    onTap: () {},
                    child: ColoredBox(
                      color: _color(SettingsModalMetrics.panel(widget.dark)),
                    ),
                  ),
                ),
                // 3) 框架文本 + 返回按钮（真实 widget，不是画出来的字）。
                _frame(widget.model, bounds, palette),
                // 4) 卡片视口：真实 SingleChildScrollView + 真实控件。
                Positioned.fromRect(
                  rect: viewport,
                  child: ClipRect(
                    child: SingleChildScrollView(
                      controller: _scroll,
                      physics: maxScroll > 0
                          ? const ClampingScrollPhysics()
                          : const NeverScrollableScrollPhysics(),
                      child: SizedBox(
                        width: viewport.width,
                        height: layout.contentHeight,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: _cardChildren(layout, viewport, palette),
                        ),
                      ),
                    ),
                  ),
                ),
                // 5) 滚动轨道 + 上下按钮（装饰自绘，交互是真 widget）。
                if (rail.visible) ...<Widget>[
                  Positioned.fromRect(
                    rect: rail.track,
                    child: IgnorePointer(
                      child: ColoredBox(color: _color(palette.faint)),
                    ),
                  ),
                  Positioned.fromRect(
                    rect: rail.thumb,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (DragUpdateDetails details) {
                        final double span = rail.track.height - rail.thumb.height;
                        if (span <= 0) {
                          return;
                        }
                        _scrollToFraction(
                          (rail.thumb.top - rail.track.top + details.delta.dy) / span,
                        );
                      },
                      onTap: () {},
                      child: ColoredBox(color: _color(palette.muted)),
                    ),
                  ),
                ],
                _scrollButton(
                  rect: upButton,
                  glyph: SettingsPanelGeometry.scrollUpGlyph,
                  palette: palette,
                  action: SettingsPanelGeometry.scrollUpAction,
                  keyName: 'settings-scroll-up',
                ),
                _scrollButton(
                  rect: downButton,
                  glyph: SettingsPanelGeometry.scrollDownGlyph,
                  palette: palette,
                  action: SettingsPanelGeometry.scrollDownAction,
                  keyName: 'settings-scroll-down',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 框架（类别 / 标题 / 副标题 / 返回）
  // -------------------------------------------------------------------------
  Widget _frame(
    BasicSettingsPanelModel model,
    Rect bounds,
    SettingsPalette palette,
  ) {
    final double left = bounds.left + SettingsModalMetrics.categoryX;
    final Rect back = SettingsPanelGeometry.backButton(
      x: bounds.left,
      y: bounds.top,
      usable: bounds.width,
    );
    final double backInset = SettingsModalMetrics.modalButtonInset(back.width);
    return Stack(
      children: <Widget>[
        Positioned(
          left: left,
          top: bounds.top + SettingsModalMetrics.categoryY,
          child: _text(
            SettingsModalFrame.categoryText,
            SettingsModalFrame.categorySize,
            palette.ink,
          ),
        ),
        Positioned(
          left: left,
          top: bounds.top + SettingsModalMetrics.titleY,
          child: _text(
            SettingsModalFrame.title,
            SettingsModalFrame.titleSize,
            palette.ink,
            weight: SettingsFontWeight.demibold,
          ),
        ),
        Positioned(
          left: left,
          top: bounds.top + SettingsModalMetrics.subtitleY,
          child: _text(
            SettingsModalFrame.subtitle,
            SettingsModalFrame.subtitleSize,
            palette.ink,
          ),
        ),
        Positioned.fromRect(
          rect: back,
          child: Semantics(
            button: true,
            label: SettingsModalFrame.backLabel,
            child: InkWell(
              key: const ValueKey<String>('settings-back'),
              onTap: () => _handle(SettingsModalFrame.backAction),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _color(SettingsModalMetrics.modalButtonTint(widget.dark)),
                ),
                child: Padding(
                  padding: EdgeInsets.only(left: backInset, right: backInset),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _text(
                      SettingsModalFrame.backLabel,
                      SettingsModalFrame.backTextSize,
                      palette.ink,
                      weight: SettingsFontWeight.demibold,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _scrollButton({
    required Rect rect,
    required String glyph,
    required SettingsPalette palette,
    required String action,
    required String keyName,
  }) {
    return Positioned.fromRect(
      rect: rect,
      child: Semantics(
        button: true,
        label: glyph,
        child: InkWell(
          key: ValueKey<String>(keyName),
          onTap: () => _handle(action),
          child: Center(
            child: _text(
              glyph,
              SettingsModalMetrics.scrollButtonTextSize,
              palette.muted,
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 卡片内容
  // -------------------------------------------------------------------------
  List<Widget> _cardChildren(
    SettingsCardLayout layout,
    Rect viewport,
    SettingsPalette palette,
  ) {
    final List<Widget> children = <Widget>[];
    for (final SettingsSectionLayout section in layout.sections) {
      children.addAll(_sectionWidgets(section, viewport, palette));
    }
    if (widget.pluginsEntry) {
      final double top = (layout.sections.isEmpty
                  ? viewport.top
                  : layout.sections.last.body.bottom) -
              viewport.top +
          SettingsRowMetrics.sectionGap;
      children.add(Positioned(
        left: SettingsRowMetrics.contentInset,
        top: top,
        width: viewport.width - SettingsRowMetrics.contentInset * 2,
        height: SettingsRowMetrics.linkRowHeight,
        child: _pluginsEntry(palette),
      ));
    }
    return children;
  }

  /// 横屏设置末尾的「插件管理」入口（与项目链接同一种整宽卡片）。
  Widget _pluginsEntry(SettingsPalette palette) {
    return Semantics(
      button: true,
      link: true,
      label: '插件管理',
      child: InkWell(
        key: const ValueKey<String>('settings-plugins-entry'),
        onTap: () => _handle('plugins'),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _color(palette.soft),
            border: Border.all(color: _color(palette.line)),
          ),
          child: Padding(
            padding: const EdgeInsets.only(left: 12, top: 15),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _text('插件管理', 14, palette.ink),
                ),
                _text('↗', 13, palette.ink),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _sectionWidgets(
    SettingsSectionLayout section,
    Rect viewport,
    SettingsPalette palette,
  ) {
    final Rect header = section.header;
    final double left = header.left - viewport.left;
    final double top = header.top - viewport.top;
    final List<Widget> children = <Widget>[];

    // 表头：序号 + "EN / 中文" + 1px 线（SettingsCard.cpp:36-45 同一组偏移）。
    children.add(Positioned(
      left: left + SettingsRowMetrics.contentInset,
      top: top + SettingsHeaderMetrics.indexInsetTop,
      child: _text(
        section.section.numberText,
        SettingsHeaderMetrics.indexSize,
        palette.muted,
        tracking: SettingsHeaderMetrics.indexTracking,
      ),
    ));
    children.add(Positioned(
      left: left + SettingsRowMetrics.contentInset + SettingsHeaderMetrics.titleInsetLeft,
      top: top + SettingsHeaderMetrics.titleInsetTop,
      child: _text(
        section.section.titleText,
        SettingsHeaderMetrics.titleSize,
        palette.ink,
        weight: SettingsFontWeight.demibold,
        tracking: SettingsHeaderMetrics.titleTracking,
      ),
    ));
    children.add(Positioned(
      left: left + SettingsRowMetrics.contentInset,
      top: top + header.height - 1,
      width: header.width - SettingsRowMetrics.contentInset * 2,
      height: 1,
      child: ColoredBox(color: _color(palette.line)),
    ));

    if (section.section.hasCustomRenderer) {
      final Widget? custom = _customSection(section, viewport, palette);
      if (custom != null) {
        children.add(custom);
      }
      return children;
    }

    for (int index = 0; index < section.rows.length; index++) {
      children.addAll(_rowWidgets(section.rows[index], index, viewport, palette));
    }
    return children;
  }

  /// 两个自定义区（只授权 ONLY14 的部分）：
  /// - 唱片旋转：一行真实开关控件（点击＝disc-rotation），不画未授权的第一行；
  /// - 版本：两行只读文本（无命中，Qt 侧同样只读）。
  Widget? _customSection(
    SettingsSectionLayout section,
    Rect viewport,
    SettingsPalette palette,
  ) {
    final Rect body = section.body;
    final String renderer = section.section.customRenderer;
    if (renderer == basicSettingsDiscRotationRenderer) {
      final double rowTop =
          body.top + SettingsPerformanceSectionMetrics.firstRowTop;
      final double left = body.left - viewport.left;
      final double top = rowTop - viewport.top;
      final Rect control = Rect.fromLTWH(
        body.right - SettingsRowMetrics.controlWidth,
        rowTop + SettingsPerformanceSectionMetrics.controlInsetTop,
        SettingsRowMetrics.controlWidth,
        SettingsPerformanceSectionMetrics.controlHeight,
      );
      final bool on = widget.model.discRotation;
      return Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: left,
            top: top + SettingsPerformanceSectionMetrics.titleInsetTop,
            child: _text(
              SettingsPerformanceContent.secondTitleEn,
              SettingsPerformanceSectionMetrics.titleSize,
              palette.muted,
              tracking: SettingsPerformanceSectionMetrics.titleTracking,
            ),
          ),
          Positioned(
            left: left,
            top: top + SettingsPerformanceSectionMetrics.subtitleInsetTop,
            child: _text(
              SettingsPerformanceContent.secondTitleZh,
              SettingsPerformanceSectionMetrics.subtitleSize,
              palette.ink,
              weight: SettingsFontWeight.demibold,
              tracking: SettingsPerformanceSectionMetrics.subtitleTracking,
            ),
          ),
          Positioned.fromRect(
            rect: control.translate(-viewport.left, -viewport.top),
            child: _actionBlock(
              key: ValueKey<String>(basicSettingsControlKey('disc-rotation')),
              label: on
                  ? SettingsPerformanceContent.secondLabelOn
                  : SettingsPerformanceContent.secondLabelOff,
              semanticLabel: SettingsPerformanceContent.secondHitLabel,
              action: SettingsPerformanceContent.secondAction,
              palette: palette,
            ),
          ),
          Positioned(
            left: left,
            top: top + SettingsPerformanceSectionMetrics.ruleInsetTop,
            width: body.width,
            height: 1,
            child: ColoredBox(color: _color(palette.line)),
          ),
          Positioned(
            left: left,
            top: top + SettingsPerformanceSectionMetrics.firstHelpInsetTop,
            child: _text(
              SettingsPerformanceContent.secondHelp,
              SettingsPerformanceSectionMetrics.helpSize,
              palette.muted,
            ),
          ),
        ],
      );
    }
    if (renderer == basicSettingsVersionRenderer) {
      final BasicSettingsVersion version = widget.model.version;
      final double left = body.left - viewport.left;
      final double top = body.top - viewport.top;
      final String secondary = version.secondaryLabel;
      return Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: left,
            top: top + SettingsUpdateContent.versionInsetTop,
            child: _text(
              version.label,
              SettingsUpdateContent.versionSize,
              palette.ink,
              weight: SettingsFontWeight.demibold,
            ),
          ),
          if (secondary.isNotEmpty)
            Positioned(
              left: left,
              top: top + SettingsUpdateContent.commitInsetTop,
              child: _text(
                secondary,
                SettingsUpdateContent.commitSize,
                palette.muted,
              ),
            ),
        ],
      );
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // 普通行
  // -------------------------------------------------------------------------
  List<Widget> _rowWidgets(
    SettingsRowLayout layout,
    int index,
    Rect viewport,
    SettingsPalette palette,
  ) {
    final SettingsRowSpec row = layout.row;
    final Rect bounds = layout.bounds;
    final List<Widget> children = <Widget>[];
    final double left = bounds.left - viewport.left;
    final double top = bounds.top - viewport.top;

    if (row.kind == SettingsRowKind.link) {
      children.add(Positioned.fromRect(
        rect: bounds.translate(-viewport.left, -viewport.top),
        child: Semantics(
          button: true,
          link: true,
          label: row.titleZh,
          child: InkWell(
            key: ValueKey<String>(basicSettingsControlKey(row.id)),
            onTap: () => _handle(row.action),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _color(palette.soft),
                border: Border.all(color: _color(palette.line)),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 12, top: 15),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: _fittedText(
                        row.actionLabel,
                        14,
                        bounds.width - 40,
                        palette.ink,
                      ),
                    ),
                    _text('↗', 13, palette.ink),
                  ],
                ),
              ),
            ),
          ),
        ),
      ));
      return children;
    }

    // 行号 / 英中标题 / 重启提示（paintSettingsRow 同一组偏移）。
    children.add(Positioned(
      left: left,
      top: top + 24,
      child: _text(
        SettingsRowMetrics.rowIndex(index),
        11,
        palette.muted,
        tracking: 0.04,
      ),
    ));
    children.add(Positioned(
      left: left + 30,
      top: top + 10,
      child: _text(row.titleEn, 11, palette.muted, tracking: 0.08),
    ));
    children.add(Positioned(
      left: left + 30,
      top: top + 25,
      child: _text(
        row.titleZh,
        17,
        palette.ink,
        weight: SettingsFontWeight.demibold,
        tracking: -0.01,
      ),
    ));
    if (row.restartHint.isNotEmpty) {
      children.add(Positioned(
        left: left + 30,
        top: top + 50,
        child: _text(row.restartHint, 10, palette.muted),
      ));
    }
    children.add(Positioned(
      left: left,
      top: top + bounds.height - 1,
      width: bounds.width,
      height: 1,
      child: ColoredBox(color: _color(palette.line)),
    ));
    final Widget? control = _rowControl(row, layout, viewport, palette);
    if (control != null) {
      children.add(control);
    }
    if (layout.optionsHeight > 0 && !layout.options.isEmpty) {
      children.addAll(_options(layout, viewport, palette));
    }
    return children;
  }

  Widget? _rowControl(
    SettingsRowSpec row,
    SettingsRowLayout layout,
    Rect viewport,
    SettingsPalette palette,
  ) {
    final Rect control = layout.control.translate(-viewport.left, -viewport.top);
    switch (row.kind) {
      case SettingsRowKind.switchRow:
      case SettingsRowKind.choice:
        return Positioned.fromRect(
          rect: control,
          child: _choiceControl(row, palette),
        );
      case SettingsRowKind.stepper:
      case SettingsRowKind.slider:
        return Positioned.fromRect(
          rect: control,
          child: _stepperControl(row, palette),
        );
      case SettingsRowKind.action:
        return Positioned.fromRect(
          rect: control,
          child: _actionBlock(
            key: ValueKey<String>(basicSettingsControlKey(row.id)),
            label: row.actionLabel,
            semanticLabel: row.titleZh,
            action: row.action,
            palette: palette,
          ),
        );
      case SettingsRowKind.textInput:
        return Positioned.fromRect(
          rect: control,
          child: _actionBlock(
            key: ValueKey<String>(basicSettingsControlKey(row.id)),
            label: row.actionLabel,
            semanticLabel: row.titleZh,
            action: 'setting-edit:${row.id}',
            palette: palette,
            glyph: '✎',
          ),
        );
      case SettingsRowKind.link:
      case SettingsRowKind.custom:
        return null;
    }
  }

  Widget _choiceControl(SettingsRowSpec row, SettingsPalette palette) {
    final bool enabled = row.enabled;
    final bool expanded = row.expanded && enabled;
    return Semantics(
      button: true,
      enabled: enabled,
      label: row.titleZh,
      child: InkWell(
        key: ValueKey<String>(basicSettingsControlKey(row.id)),
        onTap: enabled ? () => _handle('expand:${row.id}') : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _color(palette.soft),
            border: Border.all(color: _color(palette.line)),
          ),
          child: Padding(
            padding: const EdgeInsets.only(left: 14, right: 14),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _fittedText(
                    row.label,
                    15,
                    SettingsRowMetrics.controlWidth - 48,
                    enabled ? palette.ink : palette.ink.fade(0.35),
                  ),
                ),
                const SizedBox(width: 8),
                _text(expanded ? '▴' : '▾', 14, palette.ink),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stepperControl(SettingsRowSpec row, SettingsPalette palette) {
    const double w = SettingsRowMetrics.controlWidth;
    const double h = 48;
    final String prefix = SettingsRowMetrics.actionFor(row);
    final double trackLeft = 100 + 32 + 12;
    final double trackRight = w - 40 - 12;
    final double trackWidth = trackRight - trackLeft;
    final int selected = _selectedIndex(row);
    // LEAF-159 MUST-1：与 Qt 画家同一套映射（lib/hud/widgets/settings_row.dart:744
    // 的 `count <= 1 ? 0 : selected / (count - 1)`）。用 (selected+1)/count 会把
    // 首档画到 1/count 处，knob 永远贴不到左端，和分段命中也对不上。
    final int count = row.numericValues.length;
    final double fraction = count <= 1 ? 0 : selected / (count - 1);
    return Stack(
      // 真控件入口（测试/无障碍都从这里点这一行）。
      key: ValueKey<String>(basicSettingsControlKey(row.id)),
      children: <Widget>[
        Positioned(
          left: 2,
          top: 15,
          width: 96,
          child: _fittedText(
            row.label,
            15,
            96,
            // Qt 同一行（lib/hud/widgets/settings_row.dart:722）：禁用态文字渐隐。
            row.enabled ? palette.ink : palette.ink.fade(0.35),
            weight: SettingsFontWeight.demibold,
          ),
        ),
        Positioned(
          left: 100,
          top: 8,
          width: 32,
          height: 32,
          child: _stepButton(
            glyph: '−',
            size: 19,
            enabled: row.enabled && row.decrementValue.isNotEmpty,
            palette: palette,
            action: row.decrementValue.isEmpty ? null : '$prefix${row.decrementValue}',
            semanticLabel: '${row.titleZh} 减',
          ),
        ),
        Positioned(
          left: w - 40,
          top: 8,
          width: 32,
          height: 32,
          child: _stepButton(
            glyph: '＋',
            size: 16,
            enabled: row.enabled && row.incrementValue.isNotEmpty,
            palette: palette,
            action: row.incrementValue.isEmpty ? null : '$prefix${row.incrementValue}',
            semanticLabel: '${row.titleZh} 加',
          ),
        ),
        Positioned(
          left: trackLeft,
          top: h / 2 - 2,
          width: trackWidth,
          height: 4,
          child: ColoredBox(color: _color(palette.faint)),
        ),
        Positioned(
          key: ValueKey<String>('settings-fill-${row.id}'),
          left: trackLeft,
          top: h / 2 - 2,
          width: trackWidth * fraction,
          height: 4,
          child: IgnorePointer(child: ColoredBox(color: _color(palette.gold))),
        ),
        Positioned(
          key: ValueKey<String>('settings-knob-${row.id}'),
          left: trackLeft + trackWidth * fraction - 4,
          top: h / 2 - 2 - 5,
          width: 8,
          height: 14,
          child: IgnorePointer(child: ColoredBox(color: _color(palette.ink))),
        ),
        // 每一档都是可点区域（Qt 的分段命中同一套 actionFor(row)+value）。
        for (int i = 0; i < row.numericValues.length; i++)
          Positioned(
            left: trackLeft + trackWidth * i / row.numericValues.length,
            top: 0,
            width: trackWidth / row.numericValues.length,
            height: h,
            child: Semantics(
              button: true,
              label: row.numericValues[i].toString(),
              child: GestureDetector(
                key: ValueKey<String>(
                    'settings-notch-${row.id}-${row.numericValues[i]}'),
                behavior: HitTestBehavior.translucent,
                onTap: row.enabled
                    ? () => _handle('$prefix${row.numericValues[i]}')
                    : null,
                child: const SizedBox.expand(),
              ),
            ),
          ),
      ],
    );
  }

  int _selectedIndex(SettingsRowSpec row) {
    for (int i = row.numericValues.length - 1; i >= 0; i--) {
      if (row.numericValues[i] == row.value.integer) {
        return i;
      }
    }
    return 0;
  }

  Widget _stepButton({
    required String glyph,
    required double size,
    required bool enabled,
    required SettingsPalette palette,
    required String? action,
    required String semanticLabel,
  }) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: InkWell(
        onTap: enabled && action != null ? () => _handle(action) : null,
        child: DecoratedBox(
          decoration: BoxDecoration(border: Border.all(color: _color(palette.ink))),
          child: Center(
            child: _text(
              glyph,
              size,
              enabled ? palette.ink : palette.ink.fade(0.35),
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionBlock({
    required Key key,
    required String label,
    required String semanticLabel,
    required String action,
    required SettingsPalette palette,
    String glyph = '→',
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(
        key: key,
        onTap: () => _handle(action),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _color(palette.soft),
            border: Border.all(color: _color(palette.line)),
          ),
          child: Padding(
            padding: const EdgeInsets.only(left: 14, right: 14),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _fittedText(
                    label,
                    15,
                    SettingsRowMetrics.controlWidth - 48,
                    palette.ink,
                  ),
                ),
                _text(glyph, 14, palette.ink),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _options(
    SettingsRowLayout layout,
    Rect viewport,
    SettingsPalette palette,
  ) {
    final SettingsRowSpec row = layout.row;
    final Rect options = layout.options;
    final String prefix = SettingsRowMetrics.actionFor(row);
    final List<Widget> children = <Widget>[];
    children.add(Positioned.fromRect(
      rect: options.translate(-viewport.left, -viewport.top),
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _color(palette.soft),
            border: Border.all(color: _color(palette.line)),
          ),
        ),
      ),
    ));
    for (int i = 0; i < row.choices.length; i++) {
      final SettingsChoice choice = row.choices[i];
      final Rect item = Rect.fromLTWH(
        options.left + 2,
        options.top + 2 + i * SettingsRowMetrics.optionHeight,
        options.width - 4,
        46,
      );
      final bool active = choice.value == row.value.canonical;
      children.add(Positioned.fromRect(
        rect: item.translate(-viewport.left, -viewport.top),
        child: Semantics(
          button: true,
          selected: active,
          label: choice.label,
          child: InkWell(
            key: ValueKey<String>(basicSettingsControlKey('${row.id}-${choice.value}')),
            onTap: () => _handle('$prefix${choice.value}'),
            child: Stack(
              children: <Widget>[
                if (active)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 3,
                    child: ColoredBox(color: _color(palette.gold)),
                  ),
                Padding(
                  padding: const EdgeInsets.only(left: 14, top: 15),
                  child: _fittedText(
                    choice.label,
                    15,
                    item.width - 32,
                    palette.ink,
                    weight: active
                        ? SettingsFontWeight.demibold
                        : SettingsFontWeight.regular,
                  ),
                ),
              ],
            ),
          ),
        ),
      ));
    }
    return children;
  }

  // -------------------------------------------------------------------------
  // 文本 helpers（尺寸/字重/字距照 Qt；颜色走 SettingsPalette）
  // -------------------------------------------------------------------------
  Widget _text(
    String text,
    double size,
    SettingsRgba color, {
    SettingsFontWeight weight = SettingsFontWeight.regular,
    double tracking = 0,
  }) {
    return Text(
      text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      style: TextStyle(
        color: _color(color),
        fontSize: size,
        height: 1.0,
        letterSpacing: tracking * size,
        fontWeight: weight == SettingsFontWeight.demibold
            ? FontWeight.w600
            : FontWeight.w400,
      ),
    );
  }

  Widget _fittedText(
    String text,
    double size,
    double width,
    SettingsRgba color, {
    SettingsFontWeight weight = SettingsFontWeight.regular,
  }) {
    return SizedBox(
      width: width,
      height: size * 1.4,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: _text(text, size, color, weight: weight),
      ),
    );
  }

  static Color _color(SettingsRgba rgba) => Color.fromRGBO(
        (rgba.r * 255).round().clamp(0, 255),
        (rgba.g * 255).round().clamp(0, 255),
        (rgba.b * 255).round().clamp(0, 255),
        rgba.a.clamp(0.0, 1.0),
      );

}

/// 供测试/semantics 断言：本层现在展示的控件动作（不含滚动两枚）。
/// 供测试/semantics 断言：本层现在展示的控件动作（不含滚动两枚）。
@visibleForTesting
List<String> basicSettingsWindowActions(BasicSettingsPanelModel model) {
  final List<String> actions = <String>[];
  actions.add(SettingsModalFrame.backAction);
  for (final SettingsSectionModel section in model.sections) {
    for (final SettingsRowSpec row in section.rows) {
      final String prefix = SettingsRowMetrics.actionFor(row);
      switch (row.kind) {
        case SettingsRowKind.switchRow:
        case SettingsRowKind.choice:
          actions.add('expand:${row.id}');
          for (final SettingsChoice choice in row.choices) {
            actions.add('$prefix${choice.value}');
          }
        case SettingsRowKind.stepper:
        case SettingsRowKind.slider:
          if (row.decrementValue.isNotEmpty) {
            actions.add('$prefix${row.decrementValue}');
          }
          if (row.incrementValue.isNotEmpty) {
            actions.add('$prefix${row.incrementValue}');
          }
          for (final int value in row.numericValues) {
            actions.add('$prefix$value');
          }
        case SettingsRowKind.action:
          actions.add(row.action);
        case SettingsRowKind.textInput:
          actions.add('setting-edit:${row.id}');
        case SettingsRowKind.link:
          actions.add(row.action);
        case SettingsRowKind.custom:
          break;
      }
    }
  }
  return actions;
}
