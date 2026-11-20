/// 设置页顶部「ACCESS / 音乐平台」卡的 widget 版。
///
/// 为什么放在 widget 层而不是搬 HuD 画笔：设置整页是真实 Flutter 控件
/// （`lib/basic/basic_settings_portrait.dart`），平台卡属于它的第一屏内容，
/// 若用命令流画在下方 HUD 画面上会被 widget 层整块盖住（`BasicSettingsWindow`
/// 时代就是这么丢的）。所以这里用与设置行完全同一套网格单位与行高来画。
///
/// 几何与文案逐字照 `Qt/src/ResponsiveHudPages.cpp:527-544`（393 网格）：
/// 卡 96 高、左缘 2px amber 竖条、标题 8 号 muted、平台名 18 号 demibold、
/// 右上「切换平台 ↗」+ 命中 `provider`、左下登录态、右下「退出登录 ↗」/
/// 「登录账号 ↗」（命中 `music:logout` / `music:login`）、`y += 116`。
library;

import 'package:flutter/material.dart';

/// 平台卡的固定几何（网格单位，与 `BasicPortraitSettingsPage` 的 393 网格同源）。
const double basicProviderAccessCardHeight = 96;
const double basicProviderAccessCardStride = 116;
const double basicProviderAccessInset = 20;

/// 设置页第一屏的平台访问卡。
class BasicProviderAccessCard extends StatelessWidget {
  const BasicProviderAccessCard({
    super.key,
    required this.pageWidth,
    required this.providerName,
    required this.loggedIn,
    this.supportsLogin = false,
    this.userName = '',
    required this.onAction,
    this.dark = false,
  });

  /// 当前页宽（网格）：DPI 适配后比 393 宽，右侧锚点按它算。
  final double pageWidth;

  /// 平台显示名（`ProviderDescriptor.name`）。
  final String providerName;

  /// 是否已登录（决定右下角是「退出登录 ↗」还是「登录账号 ↗」）。
  final bool loggedIn;

  /// 该平台是否支持登录（`capabilities.login`）。
  ///
  /// 塞壬唱片没有账号体系（`MusicBridge/plugins/descriptors/siren.json` 的
  /// `capabilities.account`/`login` 皆 false），Qt `MusicMutation.cpp` 对它的
  /// `music:login` 直接早退 ⇒ 这里不画会点空的入口，改成一句状态说明。
  final bool supportsLogin;

  /// 已登录时的昵称。
  final String userName;

  /// 动作出口：`provider` / `music:login` / `music:logout`。
  final ValueChanged<String> onAction;

  final bool dark;

  @override
  Widget build(BuildContext context) {
    final _CardInk ink = _CardInk.of(dark);
    final double width = pageWidth - basicProviderAccessInset * 2;
    return SizedBox(
      height: basicProviderAccessCardStride,
      child: Stack(
        children: <Widget>[
          // :528-530 —— 卡片底 + 左缘 amber 竖条。
          Positioned(
            left: basicProviderAccessInset,
            top: 0,
            width: width,
            height: basicProviderAccessCardHeight,
            child: Container(color: ink.surface),
          ),
          Positioned(
            left: basicProviderAccessInset,
            top: 0,
            width: 2,
            height: basicProviderAccessCardHeight,
            child: Container(color: const Color(0xFFC79B39)),
          ),
          // :531 —— `ACCESS / 音乐平台`（y+12，8 号 muted）。
          Positioned(
            left: basicProviderAccessInset + 13,
            top: 8,
            width: width - 26,
            child: Text('ACCESS / 音乐平台',
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: _style(8, ink.muted)),
          ),
          // :532 —— 平台名（y+32 基线，18 号 demibold）。
          Positioned(
            left: basicProviderAccessInset + 13,
            top: 24,
            width: width - 26,
            child: Text(providerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _style(18, ink.ink, demibold: true)),
          ),
          // :533 —— 右上「切换平台 ↗」（281 = 393-112，宽 83）。
          Positioned(
            right: basicProviderAccessInset + 1,
            top: 12,
            width: 94,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text('切换平台 ↗',
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: _style(10, ink.ink)),
            ),
          ),
          // :534 —— 切换命中：269 = 393-124，104×44。
          Positioned(
            right: basicProviderAccessInset - 2,
            top: 0,
            width: 104,
            height: 44,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onAction('provider'),
            ),
          ),
          // :535-536 —— 左下登录态（y+71，10 号 muted）。
          Positioned(
            left: basicProviderAccessInset + 13,
            top: 62,
            width: width * .62,
            child: Text(
                !supportsLogin
                    ? '公开曲库 · 无需账号'
                    : loggedIn
                        ? userName
                        : '尚未登录',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _style(10, ink.muted)),
          ),
          // :537 —— 右下登录/退登入口；平台没有账号体系时只给状态说明。
          Positioned(
            right: basicProviderAccessInset + 1,
            top: 62,
            width: supportsLogin ? 94 : 140,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                  !supportsLogin
                      ? '无需登录'
                      : loggedIn
                          ? '退出登录 ↗'
                          : '登录账号 ↗',
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: _style(10, ink.muted)),
            ),
          ),
          // :538 —— 命中：269 / y+52 / 104×44（平台无账号体系时不给命中）。
          if (supportsLogin)
            Positioned(
              right: basicProviderAccessInset - 2,
              top: 52,
              width: 104,
              height: 44,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onAction(loggedIn ? 'music:logout' : 'music:login'),
              ),
            ),
          // 上边距：Qt 里这张卡接着 y = 130 的内容起点，控件底对齐行网格。
          Positioned(
            left: 0,
            top: basicProviderAccessCardHeight,
            right: 0,
            height: basicProviderAccessCardStride - basicProviderAccessCardHeight,
            child: const SizedBox(),
          ),
        ],
      ),
    );
  }

  static TextStyle _style(double size, Color color, {bool demibold = false}) {
    return TextStyle(
      fontSize: size,
      color: color,
      fontWeight: demibold ? FontWeight.w600 : FontWeight.w400,
      height: size >= 14 ? 1.15 : 1.2,
      letterSpacing: .2,
    );
  }
}

/// 与 `_PortraitInk` 同一套取值（设置页那个是私有的，这里只取需要的三色）。
class _CardInk {
  const _CardInk({required this.ink, required this.muted, required this.surface});

  final Color ink;
  final Color muted;
  final Color surface;

  factory _CardInk.of(bool dark) {
    Color rgb(double r, double g, double b) =>
        Color.fromRGBO((r * 255).round(), (g * 255).round(), (b * 255).round(), 1);
    if (dark) {
      return _CardInk(
        ink: rgb(.925, .933, .886),
        muted: rgb(.63, .68, .60),
        surface: rgb(.125, .165, .137),
      );
    }
    return _CardInk(
      ink: rgb(.082, .110, .090),
      muted: rgb(.404, .431, .388),
      surface: rgb(.910, .902, .863),
    );
  }
}
