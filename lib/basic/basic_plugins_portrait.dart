// ===========================================================================
// 竖屏「插件管理」/「插件详情」整页（Qt compact `ResponsiveHudPages.cpp:683-852`）
//
// 为什么是真实 widget 而不是命令流：插件列表要能被手指拖动滚动、按钮要有按压态，
// 这些在命令流页面里都要自己造一套（列表拖动/_dragPosition/命中带走溢出裁剪），
// 而设置整页已经证明「HUD 画 chrome + widget 画内容」这条路可行且可测。
// 于是这里和 `basic_settings_portrait.dart` 同构：HUD 画纸色/页头/迷你播放条/底栏，
// 内容区（自 y=158 起）是 Flutter 控件，单位仍是 393 设计网格 + Transform.scale(unit)。
//
// 几何真值取自 Qt（网格单位、y 为屏幕 y、内容自 158 起）：
//  - 分区头 26 高：墨块 {20,y,23,18} + 编号 8pt + 标题 13pt + 右缘 7pt 英文；
//  - 市场行 78 高：名称 (20,y+10) 14pt、元信息 (20,y+32) 9pt、
//    按钮 {261,y+10,112,40}、分隔线 {20,y+76,353,.6}；
//  - 已安装行 106 高：名称 (20,y+10) 14pt、状态文字右对齐、状态方块 5×5、
//    元信息 (20,y+31) 9pt、按钮行 y+50 高 44、分隔线 {20,y+104,353,.6}；
//  - 三键分支（用户安装）详情/卸载/禁用-启用，0 间隙；内置插件两键（详情/禁用）。
// 右缘常量按 `gridWidth - 20` 算（DPI 适配后页宽不再等于 393）。
//
// 动作串沿用 Qt 契约，不新造：`plugin:refresh`、`plugin:market:<id>`、
// `plugin:detail:<id>`、`plugin:uninstall:<id>`、`plugin:toggle:<id>`、
// `plugin:rollback:<id>`；详情页返回 `close-modal`（HUD 侧的 `back` 语义）。
// ===========================================================================
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../hud/portrait/portrait_layout.dart'
    show portraitDesignWidth, portraitFooterHeight, portraitGridWidth, portraitUnit;
import '../hud/protocol/hud_frame.dart' show HudStage;
import '../plugin/plugin_models.dart';
import '../plugin/plugin_manager.dart';

/// 插件整页的 root key（测试用 finder）。
const Key basicPortraitPluginsPageKey = ValueKey<String>('plugins-portrait-page');

/// 插件详情页的 root key。
const Key basicPortraitPluginDetailPageKey =
    ValueKey<String>('plugin-detail-portrait-page');

/// 内容区起点：Qt `c.beginContent(158)`（158 之前是 HUD 画的通用页头）。
const double basicPortraitPluginsContentTop = 158;

/// 页末镜像信息块（当前域名 / 未响应域名）的 key，测试与截图定位用。
const Key basicPortraitPluginsMirrorFooterKey = ValueKey<String>('plugins-mirror-footer');

/// 分区头高（Qt `terminalSection` 推进 `y += 26`）。
const double _sectionHeight = 26;

/// 市场行高 / 已安装行高（Qt 78 / 106）。
const double _marketRowHeight = 78;
const double _installedRowHeight = 106;

/// 竖屏插件管理页：市场列表 + 已安装列表。
class BasicPortraitPluginsPage extends StatefulWidget {
  const BasicPortraitPluginsPage({
    super.key,
    required this.stage,
    required this.snapshot,
    required this.dark,
    required this.onAction,
    this.installing = false,
    this.installLabel = '',
    this.pendingUninstall = '',
    this.stageScale = 0,
  });

  final HudStage stage;
  final PluginSnapshot snapshot;
  final bool dark;
  final ValueChanged<String> onAction;

  /// 安装中时把对应市场行的按钮换成「安装中…」且不可点（Qt 文案带 U+2026）。
  final bool installing;
  final String installLabel;

  /// 非空 = 正在对该 id 做卸载二次确认（Qt 弹层，见 [_pluginUninstallConfirm]）。
  final String pendingUninstall;
  final double stageScale;

  @override
  State<BasicPortraitPluginsPage> createState() => _BasicPortraitPluginsPageState();
}

class _BasicPortraitPluginsPageState extends State<BasicPortraitPluginsPage> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double unit =
        portraitUnit(widget.stage.width, stageScale: widget.stageScale);
    final double gridWidth =
        portraitGridWidth(widget.stage.width, stageScale: widget.stageScale);
    final double gridHeight =
        unit > 0 ? widget.stage.height / unit : portraitDesignWidth;
    // 只铺到播放条顶（与 HUD 的 _playerAndNav 同源），底栏留给命令流。
    final double pageBottom = math.max(0.0, gridHeight - portraitFooterHeight);
    if (unit <= 0 || pageBottom <= basicPortraitPluginsContentTop) {
      return const SizedBox.shrink();
    }
    final _PluginInk ink = _PluginInk.of(widget.dark);
    return ClipRect(
      key: basicPortraitPluginsPageKey,
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
            child: SizedBox(
              width: gridWidth,
              height: pageBottom,
              child: Stack(
                children: <Widget>[
                  Positioned(
                    left: 0,
                    right: 0,
                    top: basicPortraitPluginsContentTop,
                    bottom: 0,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      // Qt compact 的滚动是连续距离、无吸附无回弹
                      // （ResponsiveHudLayout.cpp:420-445 的滚轮每档 60 舞台 px）。
                      physics: const ClampingScrollPhysics(),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 20, right: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: _content(ink, gridWidth),
                        ),
                      ),
                    ),
                  ),
                  if (widget.pendingUninstall.isNotEmpty)
                    _pluginUninstallConfirm(
                      ink: ink,
                      gridWidth: gridWidth,
                      id: widget.pendingUninstall,
                      label: widget.snapshot
                              .installedById(widget.pendingUninstall)
                              ?.manifest
                              .label ??
                          widget.pendingUninstall,
                      onAction: widget.onAction,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _content(_PluginInk ink, double gridWidth) {
    final PluginSnapshot snapshot = widget.snapshot;
    final List<Widget> children = <Widget>[];
    children.add(_section(ink, '01', '插件市场', 'MARKETPLACE'));
    children.add(Padding(
      padding: const EdgeInsets.only(top: 4),
      child: _PluginButton(
        label: '刷新市场',
        primary: false,
        ink: ink,
        onTap: () => widget.onAction('plugin:refresh'),
        fullWidth: true,
      ),
    ));
    // 状态行（Qt 基线 240 起、10pt muted，段落行距 1.5）。
    children.add(Padding(
      padding: const EdgeInsets.only(top: 12, left: 0, right: 0),
      child: Text(
        snapshot.status.isEmpty ? '尚未读取插件市场' : snapshot.status,
        style: ink.paragraph,
      ),
    ));
    // 拉取过程中只显示状态行；「索引为空」是结束态文案（Qt `pluginMarketplaceState`
    // 在 loading 时不写这条），否则会出现「正在读取…」+「索引为空」并列的自相矛盾画面。
    final bool marketEmpty = !snapshot.loading && snapshot.market.isEmpty;
    if (widget.installing) {
      children.add(const SizedBox(height: 8));
      children.add(_progressBar(ink, snapshot.progress));
    }
    if (marketEmpty) {
      children.add(_emptyCard(
        ink,
        '暂无可用插件',
        snapshot.marketUrl.isEmpty
            ? '设置 RHINE_PLUGIN_MARKETPLACE_URL 后刷新。'
            : '市场索引为空，或当前网络不可用。',
      ));
    } else {
      for (final MarketPluginEntry entry in snapshot.market) {
        final InstalledPlugin? installed = snapshot.installedById(entry.id);
        children.add(_marketRow(ink, entry, installed, gridWidth));
      }
    }
    children.add(const SizedBox(height: 12));
    children.add(_section(
      ink,
      '02',
      '已安装',
      snapshot.installed.isEmpty ? 'INSTALLED' : 'INSTALLED / ${snapshot.installed.length}',
    ));
    if (snapshot.installed.isEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('尚未安装插件', style: ink.title),
            const SizedBox(height: 10),
            Text('从上面的市场里选一个插件安装。', style: ink.paragraph),
          ],
        ),
      ));
    } else {
      for (final InstalledPlugin plugin in snapshot.installed) {
        children.add(_installedRow(ink, plugin, gridWidth));
      }
    }
    // 页面末尾：镜像链路的当前域名与未响应域名（用户要求能直接看到卡在哪一级）。
    children.add(Padding(
      padding: const EdgeInsets.only(top: 18),
      child: _mirrorFooter(ink, snapshot),
    ));
    children.add(Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      child: Text(
        snapshot.message.isNotEmpty
            ? snapshot.message
            : '插件下载到应用数据目录；禁用后不会加载。',
        style: ink.paragraph,
      ),
    ));
    return children;
  }

  /// 页末镜像信息：当前使用的域名 + 本轮未响应（或直接失败）的域名。
  ///
  /// 顺序固定按镜像链（`pluginMarketMirrorPrefixes`），方便用户对照自己给的顺序。
  Widget _mirrorFooter(_PluginInk ink, PluginSnapshot snapshot) {
    final String active = snapshot.activeHost.isNotEmpty
        ? snapshot.activeHost
        : (snapshot.probingHost.isNotEmpty
            ? '正在尝试 ${snapshot.probingHost}…'
            : '尚未连接');
    final String dead =
        snapshot.deadHosts.isEmpty ? '无' : snapshot.deadHosts.join('、');
    return Container(
      key: basicPortraitPluginsMirrorFooterKey,
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
      color: ink.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('网络', style: ink.sectionTrailing),
          const SizedBox(height: 8),
          Text('当前域名  $active', style: ink.paragraph),
          const SizedBox(height: 6),
          Text('未响应域名  $dead', style: ink.paragraph),
          if (snapshot.mirrors.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '回退顺序  ${snapshot.mirrors.join(' → ')}',
              style: ink.paragraph,
            ),
          ],
        ],
      ),
    );
  }

  /// 字节 → `12.3 MB` / `812 KB`（页脚与进度都按这个口径）。
  static String _megabytes(double bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${bytes.toStringAsFixed(0)} B';
  }

  Widget _section(_PluginInk ink, String code, String title, String trailing) {
    return SizedBox(
      height: _sectionHeight,
      child: Stack(
        children: <Widget>[
          Positioned(left: 0, top: 0, child: _inkBlock(ink, code)),
          Positioned(
            left: 31,
            top: 2,
            child: Text(title, style: ink.sectionTitle),
          ),
          Positioned(
            right: 0,
            top: 5,
            child: Text(trailing, style: ink.sectionTrailing),
          ),
        ],
      ),
    );
  }

  Widget _inkBlock(_PluginInk ink, String code) {
    return Container(
      width: 23,
      height: 18,
      color: ink.block,
      alignment: Alignment.center,
      child: Text(code, style: ink.blockCode),
    );
  }

  Widget _marketRow(
    _PluginInk ink,
    MarketPluginEntry entry,
    InstalledPlugin? installed,
    double gridWidth,
  ) {
    final bool installingThis = widget.installing && widget.installLabel == entry.id;
    final String label = installingThis
        ? '安装中…'
        : (installed != null ? '重新安装' : '安装');
    final bool canUpdate = installed == null || installed.updateAvailable;
    return SizedBox(
      height: _marketRowHeight,
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 0,
            top: 10,
            width: math.max(80, gridWidth - 40 - 132),
            child: Text(entry.label, style: ink.rowTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Positioned(
            left: 0,
            top: 32,
            width: math.max(80, gridWidth - 40 - 130),
            child: Text(
              _marketMeta(entry, installed),
              style: canUpdate ? ink.rowMetaInk : ink.rowMeta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Positioned(
            right: 0,
            top: 10,
            child: _PluginButton(
              label: label,
              primary: installed == null,
              ink: ink,
              tapEnabled: !installingThis,
              height: 40,
              onTap: () => widget.onAction('plugin:market:${entry.id}'),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: .6,
            child: Container(height: .6, color: ink.line),
          ),
        ],
      ),
    );
  }

  /// Qt：`<id> / 市场版本 <v> / 已安装 <cur>`。
  String _marketMeta(MarketPluginEntry entry, InstalledPlugin? installed) {
    final String version = entry.version.isEmpty ? '—' : entry.version;
    if (installed == null) {
      return '${entry.id} / 市场版本 $version';
    }
    return '${entry.id} / 市场版本 $version / 已安装 ${installed.version}';
  }

  Widget _installedRow(_PluginInk ink, InstalledPlugin plugin, double gridWidth) {
    final List<Widget> buttons = <Widget>[];
    if (plugin.userInstalled) {
      buttons.add(Expanded(
        flex: 111,
        child: _PluginButton(
          label: '详情',
          primary: false,
          ink: ink,
          onTap: () => widget.onAction('plugin:detail:${plugin.id}'),
        ),
      ));
      buttons.add(Expanded(
        flex: 111,
        child: _PluginButton(
          label: '卸载',
          primary: false,
          ink: ink,
          onTap: () => widget.onAction('plugin:uninstall:${plugin.id}'),
        ),
      ));
      buttons.add(Expanded(
        flex: 131,
        child: _PluginButton(
          label: plugin.enabled ? '禁用' : '启用',
          primary: false,
          ink: ink,
          onTap: () => widget.onAction('plugin:toggle:${plugin.id}'),
        ),
      ));
    } else {
      buttons.add(Expanded(
        flex: 172,
        child: _PluginButton(
          label: '详情',
          primary: false,
          ink: ink,
          onTap: () => widget.onAction('plugin:detail:${plugin.id}'),
        ),
      ));
      buttons.add(const SizedBox(width: 9));
      buttons.add(Expanded(
        flex: 172,
        child: _PluginButton(
          label: plugin.enabled ? '禁用' : '启用',
          primary: false,
          ink: ink,
          onTap: () => widget.onAction('plugin:toggle:${plugin.id}'),
        ),
      ));
    }
    final String state = plugin.enabled ? '已启用' : '已禁用';
    return SizedBox(
      height: _installedRowHeight,
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 0,
            top: 10,
            width: math.max(60, gridWidth - 40 - 120),
            child: Text(plugin.name, style: ink.rowTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Positioned(
            right: 16,
            top: 10,
            child: Text(state, style: ink.rowMeta),
          ),
          Positioned(
            right: 8,
            top: 14,
            child: Container(
              width: 5,
              height: 5,
              color: plugin.enabled ? ink.amber : ink.muted,
            ),
          ),
          Positioned(
            left: 0,
            top: 31,
            width: math.max(80, gridWidth - 40),
            child: Text(
              '${plugin.id} / ${plugin.version} / ${plugin.manifest.publisher.isEmpty ? 'local' : plugin.manifest.publisher}',
              style: ink.rowMeta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 50,
            height: 44,
            child: Row(children: buttons),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: .6,
            child: Container(height: .6, color: ink.line),
          ),
        ],
      ),
    );
  }

  Widget _progressBar(_PluginInk ink, PluginInstallProgress progress) {
    final String file = progress.file.isEmpty ? '准备中…' : progress.file;
    final String meta = <String>[
      '${progress.filesDone}/${progress.filesTotal} 文件',
      _megabytes(progress.bytes.toDouble()),
      if (progress.speed > 0) '${_megabytes(progress.speed)}/s',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(file, style: ink.title),
        const SizedBox(height: 4),
        Text(meta, style: ink.paragraph),
        const SizedBox(height: 8),
        SizedBox(
          height: 3,
          child: Stack(
            children: <Widget>[
              Positioned.fill(child: Container(color: ink.line)),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: progress.progress.clamp(0.0, 1.0),
                child: Container(color: ink.amber),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _emptyCard(_PluginInk ink, String title, String body) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(13, 16, 13, 16),
      color: ink.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: ink.title),
          const SizedBox(height: 12),
          Text(body, style: ink.paragraph),
        ],
      ),
    );
  }
}

/// 卸载二次确认弹层（Qt `Host.cpp:797-826` 的 `卸载插件：<name>` 确认框）。
///
/// Qt 原文：标题 `卸载插件：<name>`、正文 `只删除应用数据目录中的插件文件，不删除账号数据。`
/// 确认键 `确认卸载`。动作串 `plugin:uninstall-confirm:<id>` / `plugin:uninstall-cancel`。
Widget _pluginUninstallConfirm({
  required _PluginInk ink,
  required double gridWidth,
  required String id,
  required String label,
  required ValueChanged<String> onAction,
}) {
  return Positioned.fill(
    child: ColoredBox(
      // 半透明纸色压暗底层，保留页面上下文（Qt 弹层也是压暗而非全遮）。
      color: ink.paper.withValues(alpha: 0.90),
      child: Center(
        child: Container(
          width: math.min(353, math.max(200, gridWidth - 40)),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          decoration: BoxDecoration(
            color: ink.surface,
            border: Border.all(color: ink.line),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('卸载插件：$label', style: ink.rowTitle),
              const SizedBox(height: 10),
              Text('只删除应用数据目录中的插件文件，不删除账号数据。',
                  style: ink.paragraph),
              const SizedBox(height: 18),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _PluginButton(
                      label: '取消',
                      primary: false,
                      ink: ink,
                      onTap: () => onAction('plugin:uninstall-cancel'),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: _PluginButton(
                      label: '确认卸载',
                      primary: true,
                      ink: ink,
                      onTap: () => onAction('plugin:uninstall-confirm:$id'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 竖屏「插件详情」页（Qt `ResponsiveHudPages.cpp:793-852`）。
class BasicPortraitPluginDetailPage extends StatelessWidget {
  const BasicPortraitPluginDetailPage({
    super.key,
    required this.stage,
    required this.plugin,
    required this.enabled,
    required this.userInstalled,
    required this.dark,
    required this.onAction,
    this.message = '',
    this.canRollback = false,
    this.pendingUninstall = '',
    this.stageScale = 0,
  });

  final HudStage stage;

  /// 已安装插件的 manifest；未安装时用市场条目临时构造一个（见 [_detailFromMarket]）。
  final PluginManifest plugin;
  final bool enabled;
  final bool userInstalled;
  final bool dark;
  final ValueChanged<String> onAction;
  final String message;
  final bool canRollback;

  /// 非空 = 正在对该 id 做卸载二次确认。
  final String pendingUninstall;
  final double stageScale;

  @override
  Widget build(BuildContext context) {
    final double unit = portraitUnit(stage.width, stageScale: stageScale);
    final double gridWidth = portraitGridWidth(stage.width, stageScale: stageScale);
    final double gridHeight =
        unit > 0 ? stage.height / unit : portraitDesignWidth;
    final double pageBottom = math.max(0.0, gridHeight - portraitFooterHeight);
    if (unit <= 0 || pageBottom <= basicPortraitPluginsContentTop) {
      return const SizedBox.shrink();
    }
    final _PluginInk ink = _PluginInk.of(dark);
    final double columnWidth = math.max(100.0, (gridWidth - 40 - 15) / 2);
    return ClipRect(
      key: basicPortraitPluginDetailPageKey,
      child: SizedBox(
        width: stage.width,
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
            child: SizedBox(
              width: gridWidth,
              height: pageBottom,
              child: Stack(
                children: <Widget>[
                  Positioned(
                    left: 20,
                    right: 20,
                    top: basicPortraitPluginsContentTop,
                    bottom: 0,
                    child: SingleChildScrollView(
                      physics: const ClampingScrollPhysics(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Text(plugin.label, style: ink.detailTitle),
                          const SizedBox(height: 8),
                          Text('${plugin.id} / ${plugin.version}', style: ink.rowMeta),
                          const SizedBox(height: 24),
                          Container(height: 1, color: ink.ink),
                          const SizedBox(height: 16),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              SizedBox(
                                width: columnWidth,
                                child: _field(ink, 'PUBLISHER / 发布者',
                                    plugin.publisher.isEmpty ? '—' : plugin.publisher),
                              ),
                              const SizedBox(width: 15),
                              SizedBox(
                                width: columnWidth,
                                child: _field(ink, 'LICENSE / 许可证',
                                    plugin.license.isEmpty ? '—' : plugin.license),
                              ),
                            ],
                          ),
                          const SizedBox(height: 30),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              SizedBox(
                                width: columnWidth,
                                child: _field(ink, 'CAPABILITIES / 能力',
                                    '${plugin.capabilities.length} 项'),
                              ),
                              const SizedBox(width: 15),
                              SizedBox(
                                width: columnWidth,
                                child: _field(ink, 'SOURCE / 来源',
                                    userInstalled ? '用户安装' : '内置'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 30),
                          _field(ink, 'ENTRY / 入口',
                              plugin.entryFile.isEmpty ? '—' : plugin.entryFile),
                          const SizedBox(height: 30),
                          _field(ink, 'STATE / 状态', _stateLabel()),
                          const SizedBox(height: 30),
                          if (userInstalled || true) ...<Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: _PluginButton(
                                    label: enabled ? '禁用插件' : '启用插件',
                                    primary: false,
                                    ink: ink,
                                    onTap: () => onAction('plugin:toggle:${plugin.id}'),
                                  ),
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: _PluginButton(
                                    label: '回滚上一版本',
                                    primary: false,
                                    ink: ink,
                                    tapEnabled: canRollback,
                                    onTap: () => onAction('plugin:rollback:${plugin.id}'),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                          ],
                          _PluginButton(
                            label: userInstalled ? '卸载插件' : '安装插件',
                            primary: !userInstalled,
                            ink: ink,
                            fullWidth: true,
                            onTap: () => onAction(
                              userInstalled
                                  ? 'plugin:uninstall:${plugin.id}'
                                  : 'plugin:market:${plugin.id}',
                            ),
                          ),
                          if (message.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 12),
                            Text(message, style: ink.paragraph),
                          ],
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                  ),
                  if (pendingUninstall.isNotEmpty)
                    _pluginUninstallConfirm(
                      ink: ink,
                      gridWidth: gridWidth,
                      id: pendingUninstall,
                      label: plugin.label,
                      onAction: onAction,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _stateLabel() {
    if (!userInstalled) {
      return '未安装';
    }
    return enabled ? '已安装 / 已启用' : '已安装 / 已禁用';
  }

  Widget _field(_PluginInk ink, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: ink.fieldLabel),
        const SizedBox(height: 6),
        Text(value, style: ink.fieldValue),
      ],
    );
  }

  /// 未安装插件时用市场条目临时拼一个 manifest，只为把详情页字段画全。
  static PluginManifest fromMarket(MarketPluginEntry entry) {
    return PluginManifest(
      id: entry.id,
      name: entry.label,
      version: entry.version,
      apiVersion: '',
      entryFile: entry.entryFile,
      publisher: entry.publisher,
      license: entry.license,
      capabilities: const <String>[],
      raw: entry.raw,
    );
  }
}

/// Qt compact 的按钮：次要 = surface 填充 + line 描边 + 13pt ink；
/// primary = amber 填充 + 深字；左内边距 12、高 44（市场行里高 40）。
class _PluginButton extends StatelessWidget {
  const _PluginButton({
    required this.label,
    required this.primary,
    required this.ink,
    required this.onTap,
    this.fullWidth = false,
    this.tapEnabled = true,
    this.height = 44,
  });

  final String label;
  final bool primary;
  final _PluginInk ink;
  final VoidCallback onTap;
  final bool fullWidth;
  final bool tapEnabled;
  final double height;

  @override
  Widget build(BuildContext context) {
    final Widget body = Container(
      height: height,
      width: fullWidth ? null : 112,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: primary ? ink.amber : ink.surface,
        border: primary ? null : Border.all(color: ink.line, width: .7),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          height: 1.1,
          color: primary ? ink.amberInk : ink.ink,
          fontWeight: primary ? FontWeight.w600 : FontWeight.w400,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    if (!tapEnabled) {
      return Opacity(opacity: .55, child: body);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: body,
    );
  }
}

/// 插件页用到的颜色/字号（与设置整页同一套暗/亮取值）。
class _PluginInk {
  const _PluginInk({
    required this.ink,
    required this.muted,
    required this.line,
    required this.surface,
    required this.block,
    required this.paper,
    required this.amber,
    required this.amberInk,
  });

  factory _PluginInk.of(bool dark) {
    return dark
        ? const _PluginInk(
            ink: Color(0xFFECEEE2),
            muted: Color(0xFFA1AD99),
            line: Color(0xFF3B473D),
            surface: Color(0xFF202A23),
            block: Color(0xFFECEEE2),
            paper: Color(0xFF141C18),
            amber: Color(0xFFC79B39),
            amberInk: Color(0xFF17201A),
          )
        : const _PluginInk(
            ink: Color(0xFF151C17),
            muted: Color(0xFF676E63),
            line: Color(0xFFBDC0B3),
            surface: Color(0xFFE8E6DC),
            block: Color(0xFF151C17),
            paper: Color(0xFFEFEDE4),
            amber: Color(0xFFC79B39),
            amberInk: Color(0xFF17201A),
          );
  }

  final Color ink;
  final Color muted;
  final Color line;
  final Color surface;
  final Color block;
  final Color paper;
  final Color amber;
  final Color amberInk;

  TextStyle get rowTitle => TextStyle(
        fontSize: 14,
        height: 1.15,
        fontWeight: FontWeight.w600,
        color: ink,
      );
  TextStyle get rowMeta => TextStyle(fontSize: 9, height: 1.3, color: muted);
  TextStyle get rowMetaInk => TextStyle(fontSize: 9, height: 1.3, color: ink);
  TextStyle get paragraph => TextStyle(fontSize: 10, height: 1.5, color: muted);
  TextStyle get title => TextStyle(
        fontSize: 14,
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: ink,
      );
  TextStyle get detailTitle => TextStyle(
        fontSize: 22,
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: ink,
      );
  TextStyle get sectionTitle => TextStyle(
        fontSize: 13,
        height: 1.1,
        fontWeight: FontWeight.w600,
        color: ink,
      );
  TextStyle get sectionTrailing => TextStyle(fontSize: 7, height: 1.1, color: muted);
  TextStyle get blockCode => TextStyle(
        fontSize: 8,
        height: 1.1,
        fontWeight: FontWeight.w600,
        // Qt `terminalSection` 的编号画在墨块上、取纸色：暗色主题是深底浅字反相，
        // 原来写死浅色在白块上等于隐形（实机 device10/q2-plugins-wait.png）。
        color: paper,
      );
  TextStyle get fieldLabel => TextStyle(fontSize: 8, height: 1.2, color: muted);
  TextStyle get fieldValue => TextStyle(fontSize: 12, height: 1.2, color: ink);
}
