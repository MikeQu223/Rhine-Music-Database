# 竖屏界面移植 — 2026-11-19

范围：按用户给的 6 张参考图（m13771 播放队列 / m13773 我的歌单 / m13775 唱片档案详情 /
m13777 歌词 / m13779 音乐检索 / m13781 设置）把 compact 竖屏界面移植到 Flutter HUD。
只做界面移植，不追加功能；缺功能按用户指示可接受，未接入的动作一律给可见提示，不静默 no-op。

## 依据
`Qt/src/ResponsiveHudLayout.cpp`、`ResponsiveHudPages.cpp`、`ResponsiveHudCanvas.cpp`、`PlayerBar.cpp`
（main 上的 compact HUD；feat/flutter 已删除，用 `git show origin/main:` 读）。核心数学：
`m_compact = stageWidth < 1080`、`m_unit = stageWidth/393`、`m_height = 1080/m_unit`、
行高 48、底部手势 34，整份命令流 `save` + `scale(unit, unit)`。

## 新增
- `lib/hud/portrait/portrait_canvas.dart`：393 网格命令流画布（C++ 同名 API、30 个图标路径、
  hit/field 矩形乘 unit）。
- `lib/hud/portrait/portrait_layout.dart`：`portraitUnit/portraitGridHeight/portraitRowHeight/
  portraitGestureInset`、`PortraitNav`、`PortraitArchive/Player/Frame`、`portraitListTop`、`paintPortraitHome`。
- `lib/hud/portrait/portrait_pages_song.dart`：详情页 + 歌词页。
- `lib/hud/portrait/portrait_pages_library.dart`：收藏/歌单内页 + 音乐检索页。

## 接线
- `lib/basic/basic_hud.dart`：`BasicHudFrame.build` 的 `portrait` 分支 → `_buildPortraitFrame`
  四路由（歌曲页 / 检索页 / 收藏内页 / 主页）；`basicLibraryListStageRect`、`basicHudRegionRects`
  增可选 `height`；`BasicHudSurface` 记 `_stageSize`、竖屏拖动步长按 393 网格换算、新增 `modal`。
- `lib/basic/basic_app.dart`：`mobile:lane:<n>` → `controller.selectLane`（只选中不播放不改队列）、
  `mobile:nav:*`、`mobile:search-tab:<i>`、`player:mode`、`mobile:song-options`；竖屏检索输入框
  与画布 `field('search')` 同一份网格矩形。
- `lib/basic/siren_controller.dart`：新增 `selectLane(int lane)`。
- `lib/basic/basic_settings_window.dart`：竖屏设置改整页（bounds 铺满舞台、去掉暗遮罩），横屏不变。
- 返回语义：详情页 X / 内页返回 = `back`（`controller.back()`），检索弹层 = `close-modal`。

## 实机（526f6b6d / 1800×2880 / user_rotation=0）
截图：`.agents/parity-20261109/builds/PORTRAIT-PORT-20261119/device2/`
`20-home.png`、`30-detail.png`、`51-lyrics.png`、`53-search.png`、`60-settings-full.png`。

## 已知差异（按「缺功能可接受」保留）
1. 真实封面像素未接：Dart 侧 `BasicGlyphPorts.imageFor` 恒 null，页面画空槽而不是假图。
2. 检索页缺 `02 SEARCH / 档案检索` 标签行与每行时长列（数据未提供）。
3. 设置页只有「终端偏好」一节（main 的 ACCESS 平台卡与音量等未移植）。
4. 播放队列 / 我的歌单 / 收藏歌单 / 收藏专辑的来源列仍是本地集合不可用时的诚实空态。

## 验证
- `flutter analyze lib/`：677 issues / **0 error**。
- `flutter test test/basic`：`+541 -27`，27 条失败全在 `basic_settings_wiring_test.dart`，
  已在 `b38cc6c` worktree 复核为既有失败（同批 17 条），非本次引入。
- APK：`build/app/outputs/flutter-apk/app-debug.apk` SHA
  `42d76fea832766ec10f77b651ca743972a51fce3c8d0a33ae0cdb2a8b3a41351`，`adb install -r -t` 成功。
