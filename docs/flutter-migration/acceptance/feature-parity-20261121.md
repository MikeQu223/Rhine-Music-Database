# 八项功能迁移验收记录（2026-11-21）

- 分支：`flutter/feature-parity`（自 `feat/flutter` 的 `64f3a15` 起，80 个提交）
- 基线口径：`flutter analyze lib/` = 0 error；`flutter test test/basic test/hud test/domain` = `+2850 -120`，失败集合为既有那批（`test/hud/paint_stack_test.dart` 34 条 `createTestImage` 守卫冲突、`test/hud/ime_test.dart` 13、`test/hud/settings_sections_test.dart` 11、`test/hud/t36/playlist_form_test.dart` 10 …）。抽查 `test/basic/interaction_133_native_test.dart` 的两条在 `feat/flutter` 干净工作树上同样失败，确认非本轮引入。
- 真机：`526f6b6d` / OPD2511 / 1800×2880 / `user_rotation=0`；截图在 `.agents/parity-20261109/builds/PORTRAIT-PORT-20261119/device16…20/`（未提交）。

## 1. 插件系统

- Qt 真值：`Qt/src/ResponsiveHudPages.cpp:683-852`（页面）、`Qt/src/ProviderRegistry.cpp:34-58`（manifest 校验）、`Qt/src/Host.cpp`（安装/回滚/卸载）。
- Flutter 落点：`lib/plugin/{plugin_models,plugin_paths,plugin_manager}.dart`、`lib/basic/basic_plugins_portrait.dart`、`android/.../porting/MediaSessionChannel.kt` 的 `pluginDir()`。
- 动作：`plugins`、`plugin:refresh`、`plugin:market:<id>`、`plugin:detail:<id>`、`plugin:toggle:<id>`、`plugin:uninstall[-confirm|-cancel]`、`plugin:rollback:<id>`、`plugin:close-detail`。
- 验证：市场走六级镜像（`pluginMarketMirrorPrefixes`，200 ms 逐级起跑对冲）拉到 4 条；安装 netease 24 文件约 3 分钟并显示 `N/M 文件 · MB · KB/s`；禁用状态写 `plugins-state.json` 冷启仍生效；重装生成 `.backup-<id>` 后回滚成功；卸载二次确认后目录清空。

## 2. 多平台切换

- Qt 真值：`Qt/src/MusicAccount.cpp:200-330`（`choose()` 的变体解析、停播、清 20+ 状态）、`Qt/src/ProviderRegistry.cpp`（`addBuiltin` + `loadManifestFallback` 的 `descriptorFields` 白名单）。
- Flutter 落点：`lib/provider/{provider_descriptor,provider_registry,provider_assets,provider_service,platform_switcher}.dart`、`lib/hud/portrait/portrait_pages_provider.dart`、`lib/basic/basic_app.dart` 的 `_loadProviders()` / `_installProviderService()`。
- 动作：`provider`、`provider:<id>`、`music:login`、`music:logout`。
- 验证：设置页 ACCESS 卡与平台页三区（音乐平台 / 第三方平台插件 / 账号与歌单）真机可达；落盘 `provider` 偏好优先于 `display.default`，装插件后不再跳台；切换时按 Qt 语义停播清队列。
- **边界**：Flutter 侧没有 Node 网关（`NodeRuntimeHost.kt` 全仓无调用点，Qt 的端口/令牌没有 JNI 或 MethodChannel 通道），资料库恒为塞壬曲库；平台切换只影响登录/评论/MV/发现页的可用性与界面。

## 3. 多平台登录

- Qt 真值：`Qt/src/MusicAccount.cpp:421-676`（`startLogin`/`prepareQR`/`pollQR`/`confirmLogin`/`sendLoginCode`/`captchaLogin`/`logout` 的逐字文案与冷却）、`Qt/src/NativeHudLibrary.cpp:271-330`（横屏面板几何）。
- Flutter 落点：`lib/domain/account/login_controller.dart`、`lib/hud/portrait/portrait_pages_login.dart`、`lib/hud/modals/login_modal.dart`。
- 动作：`music:login`、`music:logout`、`music:qr`、`music:login-method:<id>`、`music:login-send-code`、`music:login-submit`。
- 验证：`test/domain/login_controller_test.dart` 28 条（含六相位、失败映射、冷却、短信、变体键 `account-id-<provider>-<variant>`）。
- **边界**：内置平台（`siren`/`local`）没有账号体系，网关恒回「当前来源不支持该功能」；`accountKey` 已按 Qt `MusicLibrary.cpp:363-365` 加变体后缀。
- **插件平台走真实数据面**（2026-11-21 补齐，提交 `bda7a27e6`）：用户安装的插件平台（`netease`/`qq`/`kugou`/`bodian`）不再落到 `UnavailableProviderGateway`，而是
  `lib/provider/plugin_gateway.dart` → `lib/provider/plugin_bridge.dart` → Kotlin `porting/PluginBridgeChannel.kt` → `porting/PluginBridge.kt`（`ServerSocket` 行协议）→ `android/app/src/main/cpp/node_host.cpp`（JNI `dlopen("libnode.so")` + `node::Start`）→ `MusicBridge/ios-runtime.cjs` + `MusicBridge/worker.cjs` → 插件 `plugin.cjs`。
  三条从真机失败里挖出来的契约（写在这里防回归）：
  1. **插件方法参数是位置数组**，不是对象。`MusicBridge/worker.cjs:70` 调 `plugin.dispatchNative(operation, args)`，插件侧 `method.apply(api, args)`，传 `{qrKey: …}` 会让 `token` 变成对象、上游回 `400 参数错误`。
  2. **会话 cookie 必须是 `{name: value}` 对象**。`MusicBridge/core/host.cjs:8` 是 `{...message.cookies}`，传 `Set-Cookie` 行数组会被摊成 `{"0": "MUSIC_U=…"}`，扫码成功后 `account` 仍回未登录。
  3. **首帧必须 base64 套信封**：请求是 `{type:'input', session, data: base64(line)}`，响应是 `{type:'output', session, data: base64}`。
  4. `ensureStarted` 必须阻塞到握手完成（`CountDownLatch`），否则并发进来的第一个请求会看到 `running=false` 被判「插件运行时不可用」。
- 会话落盘：`plugin-cookies-<id>`（JSON 对象）写进设置偏好，重启后 `account()` 仍认得出；`_restoreAccount()` 在装配平台服务时后台恢复昵称（对应 Qt `MusicAccount::restoreCachedAccount`），所以设置页 ACCESS 卡不需要先打开登录页就能显示已登录账号。
- 验证（真机 526f6b6d）：扫码 → `802 scanned` → `803 confirmed` → 登录页显示 `已登录 / Aibeto / 账号 id / 3349683307`；`am force-stop` 冷启后仍登录；切到「酷狗音乐」再切回「网易云音乐」后 ACCESS 卡直接显示 `Aibeto / 退出登录`。
- **首启代价**：`node::Start` 冷启约 90 秒（`dlopen`/`dlsym` 各 0ms，慢在 node 自身初始化），期间登录页停在「准备二维码…」；同进程内后续请求秒回。

## 4. 评论

- Qt 真值：`Qt/src/CommentsController.cpp`、`Qt/src/ResponsiveComments.cpp`（竖屏）、`Qt/src/NativeHudComments.cpp`（横屏）。
- Flutter 落点：`lib/domain/comments/{comment_controller,comment_actions}.dart`、`lib/basic/basic_comment_mapper.dart`、`lib/hud/portrait/portrait_pages_comments.dart`、`lib/hud/modals/comments_modal.dart`。
- 动作：`music:comments`、`music:comments-close`/`comments:close`、`comments:sort:hot|new`、`comments:refresh`、`comments:retry`、`comments:load-more`、`comments:expand:<id>`、`comments:replies:<id>`、`comments:replies-more:<id>`。
- **边界**：siren descriptor 的 `operations` 里没有 `comments`，`_commentsAvailable` 因此恒 false，入口按能力隐藏——与主线 `MusicMutation.cpp:23` 的判定一致。

## 5. MV

- Qt 真值：`Qt/src/MvController.cpp`、`Qt/src/PlatformFeatures.h:23-27`（移动端 `MusicVideo = !RHINE_MOBILE && …` 恒关）。
- Flutter 落点：`lib/domain/mv/{mv_controller,mv_track_validator}.dart`、`lib/basic/basic_mv_mapper.dart`、`lib/hud/portrait/portrait_pages_mv.dart`、`lib/hud/modals/mv_modal.dart`。
- 动作：`mv:open`、`mv:close`、`mv:retry`、`mv:versions`、`mv:auto:on|off`、`mv:offset:reset`、`mv:offset:<±ms>`、`mv:version:<id>`。
- **边界**：Android 上特性位恒 false ⇒ `decodable` 恒 false，面板固定画「本机未接入视频解码」；仓库没有竖屏 MV 版式真值，几何自拟。

## 6. 喜欢 / 我的歌单

- Qt 真值：`Qt/src/LocalCollections.cpp`、`Qt/src/ResponsiveHudPages.cpp:845-1010`（savedOverview / 喜欢列 / 画廊三分支）、`Qt/src/NativeHudDetail.cpp:153-190`（详情页动作表）。
- Flutter 落点：`lib/domain/collection/local_collection_store.dart`、`lib/hud/portrait/{portrait_pages_collection_likes,portrait_pages_collection_playlists,portrait_saved_overview,portrait_playlist_picker}.dart`、`lib/basic/basic_app.dart` 的 `_BasicSettingsPreferencePort`。
- 动作：`music:like`、`music:like-current`、`mobile:mine`、`saved`、`music:collection:<lane>`、`music:result:1|2:<i>`、`mobile:play-liked`、`music:add-to-playlist`、`music:playlist-pick:<id>`、`music:create-playlist`、`music:rename-playlist:`、`music:delete-playlist:`。
- 验证：真机点心形 → 提示「已加入喜欢的歌曲」→ `shared_prefs` 出现 `flutter.panel/collections/siren.json` = `{"version":1,"provider":"siren","liked":["880380"],"playlists":[]}` → 「喜欢的歌曲」列显示该曲且计数 `01 / 01`。
- **踩坑（已修）**：`PreferenceStore` 的键白名单（`Qt/src/Host.cpp:1107-1109` 的裸键）不含 `collections/`，走 `BasicSettingsStore.write` 会被静默丢弃（心形变实心但没落盘）；改为直接走 `BasicSettingsPort` 并自带 `panel/` 前缀（该端口只校验前缀）。

## 7. 分类搜索

- Qt 真值：`Qt/src/MusicSiren.cpp:91-190`（本地分类检索与状态串）、`Qt/src/NativeHudSearch.cpp:66-117`（kind/group 动作）、`Qt/src/ResponsiveHudLayout.cpp:150-176`（终端页头）。
- Flutter 落点：`lib/domain/search/catalog_search.dart`、`lib/hud/portrait/portrait_pages_search_kinds.dart`、`lib/basic/basic_hud.dart` 的 `_portraitSearchRows()`。
- 动作：`music:kind:<i>`、`music:group:<i>`、`music:expand:<key>`、`music:group-back`、`mobile:search-submit`、`music:index:<i>`、`music:search-album|artist|playlist:<key>`。
- 验证：真机 `02 SEARCH / 档案检索` 终端页头 + 四 tab + 分组条 + `01 检索结果 / INDEX / 00` + 空态「检索音乐档案」；曲目行右列显示时长。

## 8. 播放队列

- Qt 真值：`Qt/src/ResponsiveHudPages.cpp:468-533`（竖屏队列页）、`Qt/src/PlaybackQueueCard.cpp`（横屏）。
- Flutter 落点：`lib/hud/portrait/portrait_pages_queue.dart`、`lib/hud/modals/queue_modal.dart`、`lib/domain/player/music_player.dart`（`setMode`/`removeFromQueue`/`clearUpcoming`）、`lib/basic/basic_player_preferences.dart`。
- 动作：`player:open`、`player:mode:<off|all|one|shuffle>`、`player:mode`（无载荷循环）、`mobile:queue-modes`、`player:queue:<i>`、`player:remove:<i>`、`player:clear`。
- 验证：竖屏队列页真机可达（当前歌曲卡 / 模式按钮 / 四 chip / 队列行 / 清空）；横屏走 `ModalShell(modalId: 'player')`；播放模式落 `play-mode` 偏好，冷启读回。

## 9. 顺带补掉的死链

- 发现页 + 播放历史：`mobile:nav:discover`、`mobile:history`、`mobile:artists`、`discover:tab:<id>`、`discover:item:<i>`、`discover:more`、`mobile:play-discover:<i>`（`lib/hud/portrait/portrait_discover_page.dart`、`lib/basic/basic_discover_mapper.dart`）。塞壬 descriptor 的 `discover.enabled=false` ⇒ 页面显示「塞壬唱片不提供发现页」，与主线一致。
- 歌曲操作面板：`mobile:song-options` → `lib/hud/portrait/portrait_song_options.dart`（Qt `ResponsiveLyrics.cpp:236-300`）。
- 横屏 `saved`/`discover`/`playlist-picker` 没有桌面稿，按舞台高度重采样渲染，保证内容与动作可达。
- `paintPortraitShell` 的 `ensureScale()`：painter 自己 `finish()` 会撤销画布的 `save`+`scale(unit)`，之前导致检索/发现/我的音乐三页的迷你播放条按逻辑像素画成一小团。

## 10. 仍未做 / 待裁决

- 240Hz 3D 与列表卡顿本体（GPU fence stall，见 `docs/vulkan-igpu` 与 `reports/GPU-FENCE-STALL-20261118.md`）；Impeller→Skia 只是止血。
- 封面查看器默认 SDK fault 0x28。
- 两次 `git -c core.hooksPath=/dev/null` 历史违规（按 subject 定位 `99cd87c`、`8efaba8`）待用户裁决；本轮所有提交均为默认身份、subject-only、未使用 `git -c`。
- 横屏插件管理页沿用竖屏 widget 页（Qt 桌面端是 `pluginsPage` 画布版），未做桌面专用版式。
