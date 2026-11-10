# 横屏逐页验收台账（T50）

本文件是 Qt Android → Flutter 迁移的**横屏逐页人工验收台账与制程契约**，不是验收结论。
截至本文件写入时，仓库内**不存在任何真机帧**，因此**没有任何一页可以标记为已取证**，
任何页面都不得据此宣称“视觉已对齐”（计划 §9.4）。

- 计划卡片：`docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md` T50（702-708 行）
- 参照几何：真机 526f6b6d，physical 2880×1800，dpr 1.96875，logical 1462.8571428571×914.2857142857，
  stage 1728×1080，stageScale 0.846560846561（计划 §2.4，116-125 行；附录 B.1，819-825 行）
- 机器可读输入：`test/fixtures/parity_cases/{archive_default,song_detail,search_empty,queue_empty}.json`
- 比对脚本：`tool/parity/compare.py`（**仅编写，未执行**；本仓库禁令不允许运行验证脚本）
- 本次修订范围：仅 `docs/flutter-migration/acceptance/landscape.md` 与 `test/fixtures/parity_cases/search_empty.json`。
  另外三个 fixture 与 `compare.py` 属另立原子，**仍未独立审查**，本文件不为它们的正确性或通过性背书。

## 1. 当前证据状态

| 项 | 值 | 依据 |
| --- | --- | --- |
| 已采集真机帧 | 0 / 12 | 计划 §2.2（84-97 行）要求 12 张真机截图，仓库内一张都没有 |
| `Assets/previews/*.png` | **不是**真机帧 | 9 张桌面离屏预览，3024×1898，物理尺寸与 2880×1800 真机不符，只能证明规格 |
| 可用阈值（SSIM ≥ 0.97、ΔE ≤ 3） | **拟议，未冻结** | 计划 §9.2（767-769 行）定性为拟议；`compare.py:140-144` 同值仅供形状参考 |
| 逐 ROI 人工对照 | **未执行** | 无帧可比 |
| 命中协议（hits/commands/frame） | 源码已读，**未与真机帧比对** | `Qt/src/NativeHud.cpp:102-109`（hit 六字段）、`:309-311`（PlayerBar 尾部）、`:253`（每帧清空） |
| 总判定 | `UNMEASURED_THRESHOLDS_NOT_FROZEN` | 四个 fixture 的 `manual_review.verdict` 同值；`compare.py:1155` 字面量 |

因此本台账的每一行证据状态只能是下面两种之一：

- `视觉未取证` —— 没有该页真机帧，禁止填 PASS；
- `逐 ROI 通过` —— 仅在真机帧到齐、逐 ROI 人工对照完成、且评审记录可追溯时才允许填写（当前 0 行）。

**禁止**用整页 SSIM/ΔE、整页平均差或任何全局分数把一页放行；**禁止**用大 mask 掩盖未对齐区域
（计划 §9.2；mask 面积上限 5%/ROI，见 §3.2）。

## 2. 覆盖矩阵（页面 × 状态 × 动作 × 方向）

方向列含义：`横屏` = 必须与 Qt Android 逐像素语义 1:1，逐 ROI 取证；`竖屏` = 新增响应式语义，
**不得**假造 Qt 竖屏像素，也不得沿用旧 Flutter UI 作为证据。

### 2.1 三维状态空间（先读这一节，再看矩阵）

HUD 每帧由 `Qt/src/NativeHud.cpp:224-312` 的 `draw()` 分发，状态是三个正交维度的组合，不是一维页面列表：

| 维度 | 取值 | 源码 |
| --- | --- | --- |
| `mode` | `boot` / `archive` / `detail` | `NativeHud.cpp:246`（inDetail）、`:269`（boot 分支）、`:272`（archive 分支）、`:279`（detail 分支）、`:302`（else archive） |
| `frame["viewer"]`（布尔） | true 时整屏画封面查看器，压过 mode | `NativeHud.cpp:267-268` |
| `modal`（17 值，见 §2.2） | 非空时在页面之后叠加弹层，且先清空页面 hits | `NativeHud.cpp:306-308`、`NativeHudModal.cpp:81-257` |
| `lyricsMode`（布尔） | archive/detail 上叠歌词面板 | `NativeHud.cpp:272`、`:279-280` |
| `trackListMode`（布尔） | 仅 modal 为空 + archive + 单曲 + 非 viewer + 非 lyricsMode 时可用 | `NativeHud.cpp:491-493`、`NativeHudController.cpp:945-947`（含 `modal.isEmpty()` 与 `!lyricsMode`） |
| `music.directory` | 目录栈非空时换成目录语境 | `NativeHud.cpp:409-427` |

因此“页面”= 上述组合下的一个可识别表面。**同一 mode 下 modal 不同、viewer 不同、歌词态不同，都是不同的验收对象**；
只按 mode 三值列表会漏掉全部弹层（这正是旧稿 7 个 P0 里的第一个）。

### 2.2 弹层全枚举（17 个 modal 分支）

Qt 的 modal 字面量共 17 个，分发在 `NativeHudModal.cpp`。**Android 上实际可达 14 个**——不是“UI 14 + 恢复再多 1 个”，
恢复也补不回来，理由见本节末尾的“白名单里两个没有 writer 的名字”。

`hud.modal` 全树只有一个写入点：`NativeHudController.cpp:84` 的 `modal = kind;`，因此能被持久化的 modal 值
必然是某个 `openModal(...)` 实参；恢复路径（`MusicSession.cpp:241-245`）只是把这个值再喂回 `openModal`。

与计划 §6.2（351-353 行）的弹层清单逐名对账（集合差，不再只说个数）：

- 计划是 16 个条目，其中 `player/queue` 合写；按名字展开是 17 个名字。
- **Qt 有、计划没有**：`local`（`NativeHudModal.cpp:173` 清空后由 `:244-245` 的 `modal == "local"` 分支绘制 `localPanel`），
  计划 351-353 行的清单里确实没有它；Android 上它没有任何 UI 入口（见下面的 bullet 与本节末尾）。
- **计划有、Qt 没有**：`queue`。`NativeHudModal.cpp` 不存在 `modal == "queue"` 分支，`openModal("queue")` 会落到
  `:252-253` 的 else `libraryPanel()`；队列面板的真名是 `player`（`NativeHudController.cpp:85`、`:360-363`）。
  恢复白名单（`MusicSession.cpp:243`）虽然含 `queue`，但 `queue` 没有 writer，见本节末尾。

所以三个数字都对但含义不同，不得互相替代：Qt 17 个分支 / 计划 17 个名字（含 queue、缺 local）/ Android 可达 14。

Android 不可达的 3 个如下（必须仍登记：桌面/竖屏或未来平台开关会改变可达性）：

三个排除项各自的**真实**理由（其中 `local` 的旧写法是错的，这里更正）：

- `desktop-lyrics`：`PlatformFeatures::DesktopLyrics` 在 Android 为 false（`PlatformFeatures.h:20-23`），设置入口随之隐藏。
- `lyrics-source`：需要本地曲库的 local 曲目（`NativeHudDetail.cpp:226-227` 的 `isLocal() && provider == "local"`，
  处理器同条件在 `NativeHudController.cpp:336-341`，`:336` 是条件本身）；而 Android 上 `provider` 被强制改回 `netease`
  （`MusicLibrary.cpp:23-24`，注意不是 :21——:21 是非法值兜底，对合法值 `local` 不生效），
  `switchProvider` 也拒绝 `local`（`MusicAccount.cpp:194-199`）。
- `local`：**不是** `openModal()` 里有 `kind == "local"` 的 guard——`NativeHudController.cpp:64-69` 那个 guard 只拦
  `isLocal()` 下的 login/quality/playlist-picker/playlist-form，与 `local` 无关。真实理由是**没有 UI 入口**：唯一通向
  `local` 的代码是 `discover` 在 `isLocal()` 时改名（`NativeHudController.cpp:73-75`），而 Android 上 `isLocal()` 不成立；
  provider 列表本身也移除 `local`（`NativeHudModal.cpp:20-22`）。恢复路径同样进不来——见本节末尾。

| # | modal | Qt 分支 | Android 可达 | 关闭路径 | 动作（逐字 action） |
| --- | --- | --- | --- | --- | --- |
| M01 | `search` | `NativeHudModal.cpp:162-257`（公共框）→ `NativeHudSearch.cpp` | 是 | 公共框 `close-modal`（`:199-200`） | `music:kind:<i>`（`:75-76`）、`music:group:<i>`（`:104-105`）、`music:group-back`（`:126`）、`music:result:0:<n>`、`music:expand:<pct>`（`:206-210`） |
| M02 | `saved` | 公共框 → `NativeHudLibrary.cpp:54-58` | 是 | `close-modal` | `music:create-playlist`（`:110`）、`music:refresh-personal`（`:116`）、`music:collection:<n>`（`:126-127`）、`music:group:<i>`（`:156-157`）、`music:group-back`（`:177`）、`music:login`（`:198`）、`music:result:<lane>:<n>`、`music:expand:<pct>`（共用 `resultListRow`：`NativeHudSearch.cpp:206-210`，lane=musicCollection 即 1–4） |
| M03 | `login` | 公共框 → `loginPanel`（`NativeHudLibrary.cpp:270-323`） | 是 | `close-modal`（`:321` “本轮跳过账号验证”） | `music:login-method:<qr|wechat|phone>`（`:294`）、`music:kugou-edition:<standard|lite>`（`:284`）、`music:qr`（`:308`） |
| M04 | `settings` | 公共框 → `settingsPanel`（`NativeHudSettings.cpp:163-225`） | 是 | `close-modal` | `expand:<id>`（`SettingsCard.cpp:75-76`）、`setting:<id>:<value>`（`:60-61`、`:129-131`、`:137-139`、`:141-143`）、`setting-edit:<id>`（`:172-173`）、各设置行 binding action（`:184`）、`settings:scroll-up`/`settings:scroll-down`（`NativeHudSettings.cpp:223-224`）、`settings:restore-defaults`（`:374`） |
| M05 | `discover` | 公共框 → `discoverPanel`（`NativeHudDiscover.cpp`） | 是 | `close-modal`（`DiscoverMusicCard.cpp:128`） | `discover:tab:<key>`（`:145`、`NativeHudDiscover.cpp:34`）、`discover:categories`（`:50`、`:69`）、`discover:category:<urlenc>`（`:57`）、`discover:area:<id>`（`:79`）、`discover:open`（`:74`）、`discover:item:<n>`（`DiscoverMusicCard.cpp:219`）、`discover:more`（`:365`）、`discover:category-page:prev|next`（`:362-363`） |
| M06 | `player`（播放队列） | 公共框 → `playerPanel`（`NativeHudPlayer.cpp:45-75`） | 是 | `close-modal`（`PlaybackQueueCard.cpp:35`） | `player:clear`（`:58`）、`player:mode:<off|all|one|shuffle>`（`:66-67`）、`player:queue:<n>`（`:90`）、`player:remove:<n>`（`:93`） |
| M07 | `quality` | 公共框 → `qualityPanel`（`NativeHudModal.cpp:380-446`） | 是 | `close-modal` | `quality:set:<id>`（`:344`） |
| M08 | `provider` | 公共框 → `platformPanel`（`:292-306`） | 是 | `close-modal` | `provider:<siren|netease|qq|kugou|local>`（`:270`）、`music:login`（`:304`） |
| M09 | `playlist-form` | 公共框（`:240-243`） | 是 | `close-modal`（本体无按钮，靠 QML 表单） | 本体无 hit；输入框与 ENTER 提交在 QML（`Overlay.qml:357-400`） |
| M10 | `playlist-picker` | 公共框（`:222-239`） | 是 | `close-modal` | `music:playlist-pick:<id>`（`:235`）、`music:picker-prev`（`:237`）、`music:picker-next`（`:238`） |
| M11 | `confirm` | 公共框（`:214-221`） | 是 | `close-modal`（`:221`） | `confirm:yes`（`:220`） |
| M12 | `disc-rotation-warning` | 公共框（`:203-209`） | 是 | `close-modal` | `disc-rotation:enable`（`:208`）、`disc-rotation:cancel`（`:209`） |
| M13 | `lyrics-offset` | 独立分支（`:85-121`） | 是 | 本分支自绘 `close-modal`（`:96`） | `player:lyrics-earlier`（`:104`）、`player:lyrics-later`（`:105`）、`player:lyrics-reset`（`:109`，仅 offset≠0）、`player:lyrics-apply-global`（`:114`，仅 offset≠global） |
| M14 | `lyrics-source` | 独立分支（`:142-161`） | **否**（需本地曲库的 local 曲目：`NativeHudDetail.cpp:226-227`、`NativeHudController.cpp:336-341`，`:336` 是条件本身；Android 的 provider 由 `MusicLibrary.cpp:23-24` 保证不为 local） | **本分支不画关闭按钮**；靠再点 `player:lyrics-sources` 切换关闭 | `player:lyrics-source:<auto|local|netease|qq|kugou>`（`:155-156`） |
| M15 | `detail-sort` | 独立分支（`:122-140`） | 是（仅歌单详情，`NativeHudMusic.cpp:41-44`） | 全屏 `close-modal`（`:128`，覆盖 1080 高） | `music:sort:detail:<none|title|album|artist>`（`:135-136`） |
| M16 | `desktop-lyrics` | 公共框 → `desktopLyricsPanel` | **否**（`PlatformFeatures.h:21-23`） | `desktop-lyrics:back`（`:199-200`） | `desktop-lyrics:scroll-up`/`-down`（`NativeHudDesktopLyrics.cpp:117-118`）、`desktop-lyrics:enabled:<on|off>`（`DesktopLyricsSettingsPage.cpp:169`）、`desktop-lyrics:opacity:<v>`（`:175-176`）、`desktop-lyrics:line-size:<v>`（`:185-187`）、`desktop-lyrics:line-weight`（`:199`）、`desktop-lyrics:line-color:<v>`（`:202`）、`desktop-lyrics:line-outline:<v>`（`:208-210`）、`desktop-lyrics:line-outline-color:<v>`（`:216`）、`desktop-lyrics:translation-size:<v>`（`:224-226`）、`desktop-lyrics:translation-weight`（`:238`）、`desktop-lyrics:translation-color:<v>`（`:241`）、`desktop-lyrics:translation-outline:<v>`（`:247-249`）、`desktop-lyrics:translation-outline-color:<v>`（`:255`）、`desktop-lyrics:offset-earlier`/`offset-later`/`offset-reset`/`offset-global`（`:277-278`）、`desktop-lyrics:reset-style`（`:298`） |
| M17 | `local` | 公共框 → `localPanel`（`NativeHudLocal.cpp:6-48`） | **否**（无 `openModal("local")` 实参；唯一入口 `NativeHudController.cpp:73-75` 需 `isLocal()`，Android 上由 `MusicLibrary.cpp:23-24` 保证 provider 恒不为 local） | `close-modal` | `local:cancel`（`:11`）、`local:folder`（`:13`）、`local:files`（`:14`）、`local:rescan`（`:15`）、`local:remove:<n>`（`:31`）、`local:browse`（`:41`）、`local:prev`（`:43`）、`local:next`（`:46`） |

弹层共同契约（三项都会直接改变 hits，必须写进验收）：

1. **弹层先清空页面 hits**：`modalDraw()` 在 `NativeHudModal.cpp:173` 执行 `hits = {}`；三个独立分支各自在 `:93`、`:125`、`:147` 清空。
   因此弹层打开后，帧里**只有弹层命中**，页面命中全部消失——拿“页面 hit 不见了”当回归会误判。
2. **search 态不画页面**：`NativeHud.cpp:278` 的 `if (modal != "search")` 使检索弹层下 archive/detail 本体整块不绘制。
3. **同一 action 不得去重**：`player:lyrics` 在同帧发两次（`PlayerBar.cpp:136` 歌曲行、`:204` 词图标），
   `open` 也发两次（`NativeHud.cpp:436` 标题、`:452` 控件）。按 action 去重会把 2 次压成 1 次，属协议缺陷。

**白名单里两个没有 writer 的名字（记录，不作为必采项）**：会话恢复白名单（`Qt/src/MusicSession.cpp:243`）是
`{saved, search, discover, queue, settings, player, local}`，其中 `queue` 与 `local` **没有任何 writer 会产出**，
所以 Android 正常运行时生成的 `session.json` 里永远不会有这两个值（modal 的快照见 `MusicSession.cpp:222`，
唯一写入点见 `NativeHudController.cpp:84`）。这意味着：

- `queue`：不存在 `modal == "queue"` 分支（会落到 `NativeHudModal.cpp:252-253` 的 `libraryPanel()`）；
  只有**手工构造/跨平台拷贝**的 session 才可能命中，且还要先过 version 与 library 恢复门（`MusicSession.cpp:238`）。
  队列面板的真名是 `player`（`NativeHudController.cpp:85`、`:360-363`）。
- `local`：即便手工构造也进不来——library 恢复的第一道门要求 ` saved["provider"] == provider`（`MusicSession.cpp:89`），
  而 Android 的 provider 恒不为 `local`（`MusicLibrary.cpp:23-24`），`switchProvider` 也拒绝它（`MusicAccount.cpp:194-199`）。

结论：这两个名字**不进必采清单**，也不改变“Android 可达 14”。这里只记录事实（白名单比 writer 集宽），
是否属缺陷由产品 owner 判定，本台账不擅自扩成页面、也不改行为。

### 2.3 页面 / 表面覆盖矩阵

`Qt 源` 列给的是该表面绘制与命中的**权威源**；`动作集` 列只记录该表面会产生的 hit action 名称
（逐字，含冒号载荷），不代表几何已冻结；几何冻结范围见 §3。

| # | 页面 / 表面 | Qt 源（证据） | 状态集（mode/frame/modal 组合） | 动作集（hit action） | 竖屏语义 | 证据状态 |
| --- | --- | --- | --- | --- | --- | --- |
| P01 | Consent 隐私门槛（原生） | `Qt/android/src/rhine/music/database/ConsentActivity.java:66-141`；`AndroidManifest.xml:65,84-96`；计划 §6.1:331 | 首次/已同意/退出/重入；CN 与 EU 两套文案（`:36-62`）；只有“同意/退出”两个按钮且不可取消（`:121-134`） | 无 HUD hit（原生 `AlertDialog`，非 HUD 页面） | 保持系统对话框语义 | 视觉未取证 |
| P02 | 启动 boot | `Qt/src/NativeHudBoot.cpp:155-311`；`NativeHud.cpp:269-270` | 载入、进度、完成、扫描中（`boot["scanVisible"]`，`NativeHudBoot.cpp:252-253`）、欢迎层（`:255`）、品牌行（`:293-301`） | `skip`（`:310`，`ENTER SYSTEM ↗`） | 同语义重排 | 视觉未取证 |
| P03 | 资料库列表 archive | `Qt/src/NativeHud.cpp:404-497`；`NativeHud.h:96-98` | 有数据、空列表、加载、失败、分组过滤、排序切换、目录栈非空 | `open`（`:436`、`:452`）、`prev`（`:465`）、`next`（`:478`）、`music:slot:<n>`（`:474`）、`column-prev`（`:480`）、`column-next`（`:490`）、`archive:tab-mode`（`:502`）、`music:parent`（`:410`）、`music:directory-info`（`:418`）、`music:play-loaded`（`:423`、`:425`）、`music:open-all-siren`（`:426`） | 单列 + 抽屉筛选 | 视觉未取证（fixture `archive_default`，未审查） |
| P04 | 目录空态 | `Qt/src/NativeHud.cpp:374-403`（`empty()`） | 目录空、来源空、未登录、同步中 | `music:parent`（`:378`）、`search`（`:402`）、`music:directory-info`（`:387`）、`saved`（`:391`）、`music:login`（`:395`） | 同语义 | 视觉未取证 |
| P05 | 歌曲详情（detail + kind=song） | `Qt/src/NativeHudDetail.cpp:45-215`；`SongDetailCard.cpp:50-111`；`NativeHud.cpp:246,279-301` | 播放中、暂停、喜欢/未喜欢/未知、可 seek/不可 seek、overview/notes/history、有无同专辑、body 三行滚动 | `back`（`NativeHudDetail.cpp:70`）、`viewer`（`:74`）、`music:play`（`:118`）、`music:like`（`:131`）、`music:add-to-playlist`（`:132`）、`music:enqueue`（`:134`）、`music:play-next`（`:134`）、`music:artist:0`（`:140`）、`detail:copy`（`:200`）、`quality:open`（`SongDetailCard.cpp:90`）、`tab:overview|notes|history`（`:105`）、`music:album-track:<n>`（`NativeHudDetail.cpp:178`）、`music:official`（`:205-206`）、`music:preview`（`:209`）、`music:remove-track`（`:212`） | 同语义 | 视觉未取证（fixture `song_detail`，未审查） |
| P06 | 歌单 / 专辑 / 歌手详情 container（detail + kind≠song） | `Qt/src/NativeHudDetail.cpp:340-511`（`container()`）；`CollectionDetailCard.cpp:27-254` | artist 双 tab、当前行高亮、收藏态、排序（含 `detail-sort` 弹层）、加载更多、空曲目 | `music:directory`（`:508`）、`music:play-loaded`（`:403`）、`music:sort-menu`（`:406`）、`music:artist-tab:songs|albums`（`:409-410`）、`music:rename-playlist`（`:413`）、`music:delete-playlist`（`:414`）、`music:subscribe`（`:440`）、`music:source`（`:443`）、`music:artist-more`（`:446`）、`music:directory-more`（`:448`）、`music:track:<n>`、`music:artist-album:<n>`（`:479`） | 单列 + 吸底播放器 | 视觉未取证 |
| P07 | 歌词面板（lyricsMode） | `Qt/src/NativeHudDetail.cpp:218-338`；`NativeHud.cpp:272,279-280` | 滚动中、跟随、偏移调整、无歌词/错误、来源切换（仅本地曲目） | `player:lyrics-close`（`:225`）、`player:lyrics-sources`（`:227`，仅 local 曲目）、`player:lyrics-retry`（`:249`）、`player:lyric-line:<n>`（`:331-332`，仅 seekable）、`player:lyrics-offset`（`:336`）、`player:lyrics-follow`（`:337`） | 全屏歌词 | 视觉未取证 |
| P08 | 封面查看器（frame[viewer]=true） | `Qt/src/NativeHudDetail.cpp:513-529`；`NativeHud.cpp:267-268` | 默认、清晰/磨砂、复位、opening/closing | `viewer:close`（`:518`）、`viewer:clear`（`:523`）、`viewer:frosted`（`:524`）、`viewer:reset`（`:526` **与** `:528`，同帧两次）、`music:cover-front`（`:527`） | 手势化 | 视觉未取证 |
| P09 | 搜索 modal（M01） | `Qt/src/NativeHudSearch.cpp:46-281`；`NativeHudModal.cpp:162-257` | 空查询、有结果、无结果、加载、失败、分组态、四标签 | 见 §2.2 M01；另 `close-modal`（`NativeHudModal.cpp:199-200`） | 全屏搜索 | 视觉未取证（fixture `search_empty`，本原子校正） |
| P10 | 个人库 / 收藏 modal（M02） | `Qt/src/NativeHudLibrary.cpp:45-251`；`NativeHudModal.cpp:162-257` | 未登录、已登录、空、加载、分组过滤条、分组态、创建歌单、QQ 刷新 | 见 §2.2 M02；另 `close-modal` | 同语义 | 视觉未取证 |
| P11 | 登录面板（M03） | `Qt/src/NativeHudLibrary.cpp:270-323`；`MusicAccount.cpp:279-667` | qr/phone/wechat、preparing/waiting/confirming/complete/failed（`MusicLibrary.h:174`）、酷狗 standard/lite、短信倒计时 | 见 §2.2 M03；QML 表单提交 `Overlay.qml:357-400` | 同语义 | 视觉未取证 |
| P12 | 设置（M04，7 区） | `Qt/src/NativeHudSettings.cpp:163-380`；`SettingsSchema.cpp:693-703`；`SettingsCard.cpp` | 7 区各自默认/修改中/保存失败、展开项、滚动、缓存提示、文本编辑浮层 | `provider`（`NativeHudSettings.cpp:272`）、`music:login`（`:284`）、`music:logout`（`:287`）、`performance:toggle`（`:321`）、`disc-rotation`（`:326`）、`cache:clear`（`:337`）、`update:auto`（`:355`）、`update:check`/`update:cancel`（`:360`）、`update:release`（`:363`、`:366`）、`settings:restore-defaults`（`:374`）、`desktop-lyrics:open`（`SettingsSchema.cpp:486`）、`music:project-<home|author|player|kugou|rhine|lyricsx|lyricskit|lyrimuse>`（`SettingsSchema.cpp:668-675`）、`setting:theme:<v>`（`:379`）、`close-behavior`（`:367`）、`motion`（`:391`）、`startup-animation`（`:403`）、`replay`（`:414`）、`quality:set:<id>`（`:423`）、`alternative`（`:435`）、`music:activate`（`:448`）、`detail-autoplay`（`:462`）、`single-play-mode`（`:475`）、`graphics-backend`（`:510`）、`setting:vsync:<v>`（`:546`）、`fg`（`:652`） | 分区列表 + 子页 | 视觉未取证 |
| P13 | 发现 modal（M05） | `Qt/src/NativeHudDiscover.cpp:20-95`；`DiscoverMusicCard.cpp:120-381` | 首屏、分页、错误、分类选择器、provider 差异 tab（基线 6 个：playlists/daily/charts/albums/categories/history；QQ 在索引 2/3 各插 1 个共 +2；网易多 1 个 artists） | 见 §2.2 M05；另 `close-modal` | 同语义 | 视觉未取证 |
| P14 | 播放栏 PlayerBar | `Qt/src/PlayerBar.cpp:229-252`；`NativeHudPlayer.cpp:8-42`；`NativeHud.cpp:309-311` | 播放、暂停、缓冲、失败、无曲目、可 seek/不可 seek、喜欢三态、音量（Android 不发射） | `player:lyrics`（`PlayerBar.cpp:136` **与** `:204`）、`music:like-current`（`:170`）、`player:prev`（`:85`）、`player:toggle`（`:86`）、`player:next`（`:87`）、`player:seek-fraction:0`（`:150`）、`player:mode`（`:198`）、`player:open`（`:224`）、`player:volume-fraction:0`（`:217`，Android 不发） | 迷你条 + 全屏 | 视觉未取证 |
| P15 | 播放队列 modal（M06） | `Qt/src/NativeHudPlayer.cpp:45-75`；`PlaybackQueueCard.cpp:11-107` | 空队列、有队列、滚动、当前曲目高亮、四种模式、移除 | 见 §2.2 M06；另 `close-modal`（`PlaybackQueueCard.cpp:35`） | 底部抽屉 | 视觉未取证（fixture `queue_empty`，未审查） |
| P16 | 更新（设置 §5 区） | `Qt/src/NativeHudSettings.cpp:344-370`；`AppUpdater.h:7-30`（`check`/`cancel`/`openRelease`/`busy`/`status`/`latestVersion`/`available`，即 P16 的四个动作与状态源） | 未检查、检查中、有更新、无更新、失败、限流 | `update:auto`（`:355`）、`update:check`/`update:cancel`（`:360`）、`update:release`（`:363`、`:366`） | 同语义 | 视觉未取证 |
| P17 | 诊断 / 性能面板（QML） | `Qt/qml/PerformancePanel.qml:1-150`（`Overlay.qml:618-620` 实例化）；`Overlay.qml:174-177`（F10） | 开/关、展开/精简、录制/停止、打开诊断目录 | 无 HUD hit（QML `MouseArea` + `Accessible.onPressAction`，非 `rhine.hits`） | 同语义 | 视觉未取证 |
| P18 | Tab Mode（archive 的 trackListMode 子态） | `Qt/src/NativeHud.cpp:500-514`、`:536-593`；`NativeHudController.cpp:945-950` | 开/关、列布局、连续曲目滚动 | `archive:tab-mode`（`:502`）、`open`、`music:index:<n>`（`:588`） | 进入/退出、选列 | 视觉未取证 |
| P19 | 桌面歌词（仅桌面） | `Qt/src/NativeHudDesktopLyrics.cpp`；`SettingsSchema.cpp:64-66` | 仅桌面；Android `PlatformFeatures::DesktopLyrics=false` | `desktop-lyrics:*` | 竖屏不适用 | 不适用于 Android（矩阵保留） |
| P20 | 系统能力：通知 / 前台 Service（**不属本台账页面**） | 计划 §5.1:252、T25（`:557-560`）；`Qt/src/AndroidMediaSession.cpp` | 权限授予/拒绝、点击进入、媒体会话 | 无（系统层，不在 HUD hits） | 同语义 | 移交 T25，本台账不验收 |

旧稿把“通知”当作 Qt 页面（P17）是**事实错误**：计划 §6.1 的 19 个页面（331-349 行）没有它，
§6.2 的弹层清单（353 行）也没有它。`Qt/src` 里提到“通知”的只有系统媒体会话/前台服务相关代码
（`AndroidMediaSession.h:5,7,16`、`AndroidMediaSession.cpp:33`、`PlatformAndroid.cpp:53,55`、`AndroidWindow.cpp:77`）
与若干无关文件里的普通词用法，**没有任何 HUD 页面**。现按 P20 移交 T25，不再占页面行。

计划 §6.1 的 19 行与本矩阵的映射（防漏项自查）：Consent→P01、Boot→P02、Archive/首页→P03、目录空态→P04、
歌曲详情→P05、歌单/专辑/歌手详情→P06、3D 查看器→P08、搜索→P09、个人库/收藏→P10、登录面板→P11、设置→P12、
发现→P13、播放栏→P14、播放队列→P15、歌词→P07、更新→P16、诊断/性能面板→P17、Tab Mode→P18、桌面歌词→P19。
19 行全部有落点；P20 是**超出计划页面清单**的系统能力边界声明，不是新增页面。

## 3. 逐 ROI 人工对照契约

三个坐标系必须先分清，否则会出现旧稿那种把相对量当绝对量的错误：

- **stage 坐标**：1728×1080，HUD 命令与 hit 矩形都用它。
- **弹层相对量**：`NativeHudSearch.cpp:8-18` 的 `SearchInset/SearchBarTop/SearchTabTop/SearchTableY/SearchFooterY`
  是**相对弹层左上角**的常量，必须加弹层原点 `bounds.y()`（默认 122，见 `NativeHud.cpp:153-158`）才是 stage 绝对量。
- **ROI 对照区**：本表矩形是**人工选定的对照区域**，不是 Qt 输出；Qt 只输出 hit 矩形（`NativeHud.cpp:102-109`）。
  因此每个 ROI 行写的是“区域内应出现哪个 action 的 hit”，不是“Qt 画了这个矩形”。

四个 fixture 冻结的是**常量几何**部分（PlayerBar 尾部与少量固定按钮），运行期字形宽度决定的命中区
（Tab、排序、分组返回、表格行）**不冻结**，在 fixture 的 `hits_excluded` 里逐条列明；其宽度来自
`Glyphs::width()` 的 advance 求和（`Qt/src/Glyphs.cpp:286-311`，字形来自 `Assets/fonts/misans-glyphs.json`，
units 1000，汉字 advance=1.0，故 size 13 的两字标签宽 26、hit 宽 34、标签步进 52）。
比对脚本对 fixture 使用 `hits_mode="subset"`：fixture 里的每个 hit 必须按原顺序原字段出现在真机帧中，
多出来的真机 hit 只记 note，不判失败（`compare.py:123-128`）。

本表列 **11 个本次已逐条回到 Qt 源码复算的 ROI**：播放栏 band 1 个（`player-bar-row`，多页共用）、
PlayerBar 内部 hit 2 个（`song-row`、`like-button`——矩形出自 `PlayerBar.cpp:136`/`:170`，band 由 `NativeHud.cpp:309-310` 每帧末尾绘制）、
歌曲详情本体 2 个（`detail-back`、`detail-cover-open`）、播放队列 3 个、搜索 3 个。

这 11 个矩形全部由本文件作者回到 Qt 源码重算，**不抄任何现有 fixture 数值**；它们只描述“该区域应出现哪个 hit”，不冻结像素。
已知与另立原子不一致的两处，本文件按 Qt 真源取值并显式标注，交由对应原子的 owner 处理，不由本文件静默覆盖：

- `queue_empty.json`（未审查）把 `queue-card` 写成 `287,122,1154,836`，那是**内容区**（卡片内缩 53）不是卡片本身；
  卡片按 `NativeHud.cpp:153-158` 应为 `234,122,1260,836`。两者都可用，但必须改名分清，不能同名两义。
- `search_empty.json`（本原子）的 `search-tab-band` 宽 540 是人工对照带，不是 Qt 输出；Qt 只输出四个标签 hit，
  宽=字形宽+8、步进 52（`NativeHudSearch.cpp:71-83` + `Glyphs.cpp:286-311`）。

`archive_default`、`song_detail`、`queue_empty` 三个 fixture 里另有 `archive-tabs`、`archive-table-head` 等 ROI 声明，
属另立原子且**仍未独立审查**；本文件**不采用、不转抄、也不宣称**其矩形或来源正确。
如果要让它们进入本台账，必须先由对应原子的独立审查核实后再补行——不得在此静默继承。

| ROI | 矩形（stage 绝对） | 区域来源 / 应出现的 hit | 人工对照要点 |
| --- | --- | --- | --- |
| `player-bar-row` | 0,984,1728,96 | `Qt/src/NativeHud.cpp:309-311`；行高 96 见 `Qt/src/PlayerBar.h:42` | 行高 96、y=984、输出区右边界、队列图标 x=right-65；band 顶=984 |
| `song-row` | 28,998,335.44,74 | `Qt/src/PlayerBar.cpp:136`（`hit{x, y+14, width, 74}`，x=28、width=0.23×1728−62） | 封面 54×54、标题基线、`size*1.044`（`Qt/src/Glyphs.cpp:316`） |
| `like-button` | 373.44,1008,48,48 | `Qt/src/PlayerBar.cpp:170`（`hit{x−24, y−24, 48, 48}`，x=0.23×1728=397.44） | 心形路径字形 advance、三态标签 |
| `detail-back` | 59,211,360,54 | `Qt/src/NativeHudDetail.cpp:70` | 按钮文字与 hit label 一致（`Qt/src/NativeHud.cpp:110-112`） |
| `detail-cover-open` | 60,944,260,35 | `Qt/src/NativeHudDetail.cpp:74` | 同上 |
| `queue-card` | 234,122,1260,836 | `Qt/src/NativeHud.cpp:153-158`（非 search：`modalWidth = min(1260, width−100) = 1260`，`left = (1728−1260)/2 = 234`，高 836） | 面板左 234、宽 1260；内部内容区再内缩 53 → x 287、宽 1154 |
| `queue-mode-row` | 287,391,1154,40 | `Qt/src/PlaybackQueueCard.cpp:12-14`（内容 x=`bounds.x()+53`、width=`bounds.width()−106`）+ `:64-67`（`modeWidth=(width−24)/4`，rect 在 `y+269`） | 4 等分、间距 8、激活态只用填充不用 hit；这是**内容区**坐标，不是卡片边框 |
| `queue-empty-notice` | 317,598,1094,90 | `Qt/src/PlaybackQueueCard.cpp:12-14` + `:97-100`（`x+30`、`y+476`、limit `width−60`；第二行基线是 `y+523`，同段源码，不是行号） | 空队列文案位置，无命中区；高 90 为人工选定覆盖两行 |
| `search-panel` | 864,122,805,836 | `Qt/src/NativeHud.cpp:153-158`（宽 `min(width−100, max(760, min(1000, width×0.5−59)))`，左 `width−modalWidth−59`，高 836） | 右对齐 modal；1728 下宽 805、左 864 |
| `search-tab-band` | 917,374,540,36 | y=`bounds.y()+SearchTabTop(252)`=`122+252`；x=`864+SearchInset(53)`；高=`SearchTabHeight(36)`；来源 `Qt/src/NativeHudSearch.cpp:11-12,71-83`；宽 540 为人工选定对照带（覆盖四标签簇与左侧留白） | 与资料库同一 Tab 基线；四标签 hit 宽=字形宽+8（运行期，不冻结） |
| `search-result-area` | 917,450,699,430 | x=864+53、y=`bounds.y()+ResultListTop(328)`=`122+328`、宽=`805−106`、高=`ResultListBottom−ResultListTop`=`758−328`；来源 `Qt/src/NativeHud.h:96-97`、`Qt/src/NativeHud.cpp:188-191`、`Qt/src/NativeHudSearch.cpp:131-134` | 空结果时应无行命中；同一矩形也是 QML 结果视口（`Overlay.qml:224-229`） |

人工对照必须**逐 ROI**记录：字形（advance、1.044 基线、tracking）、布局（矩形、层叠、裁切）、
动作（action + label + 是否 `fixed:true` + 顺序）、时序（commands/hits/frame 同代、动画收尾）。
四项缺一不算通过。

### 3.1 命中采集契约（决定“怎么采”，错一条结论即无效）

1. hits 六字段 `x/y/width/height/action/label` 由 `Qt/src/NativeHud.cpp:102-109` 产生，`label` 为空时回落为 action。
2. `fixed:true` **只有** PlayerBar 会写，来源唯一：`Qt/src/PlayerBar.cpp:46-53`（该 helper 被 PlayerBar 所有 hit 共用，
   含 `music:like-current`、`player:seek-fraction:0`）。其余 hit 一律不得带 `fixed`（`compare.py:318-404` 会抛错）。
3. PlayerBar 在 `draw()` 末尾绘制（`Qt/src/NativeHud.cpp:309-311`），所以 hits 尾部是**连续**的 PlayerBar 段；
   `compare.py:287-316` 用尾部最大连续段校验声明的 `player_bar_hits`，声明与实际不符即抛错。
4. boot 态不画播放栏（`Qt/src/NativeHud.cpp:309` 的 `if (frame["mode"] != "boot")`），所以 boot 帧里不得有 PlayerBar hit。
5. **弹层位移只作用于非 fixed hit**：`Qt/qml/Overlay.qml:191` 的 `y = area.y + (state.modal && !modelData.fixed ? modalOffset : 0)`；
   协议层 hits 仍是未位移的原始矩形，采集时不要预先加上 modalOffset。
6. **触摸外扩不是协议矩形**：Android 上 `Overlay.qml:38-43` 给每个 hit 四周各加 16 stage px 仅用于命中派发；
   导出的 hits 必须是未外扩的原始矩形，否则与 fixture 恒不等。
7. 顺序即协议：hits 按源码生成顺序消费，禁止按 z 排序、禁止按 action 去重、禁止外扩写回源矩形。

### 3.2 mask 规则

- 只允许 ROI 内小 mask，面积 ≤ 5%/ROI（`tool/parity/compare.py` `MAX_MASK_AREA_RATIO`，`:137`）；
- 每个 mask 必须写 `reason` 与 `source`，缺失即失败（`:949`）；
- mask 越出 ROI 即抛错（`:951`），总面积比超过 5% 即抛错（`:956`）；**这两个抛错会中断整次运行**：
  `validate_masks()` 在 `compare_case()` 内被调用（`:1282`），`main()` 的 case 列表推导（`:1598-1600`）没有任何
  `try/except`，于是整次比对 traceback、退出码 1、`--out` 文件不产出。这**比判 FAIL 更强**：不是“该 ROI 一行 FAIL”，
  而是“整批没有结论”，因此更不允许靠 mask 绕行。`:1302-1304` 是另一回事——那是 hit 协议 findings 把 `overall`
  升级为 FAIL 的位置，与 mask 无关。
- `space="global"` 的 mask 被直接拒绝（`:945`）：全局遮罩等于放弃逐 ROI 判定。

## 4. 判定规则与裁决词

一页只有在下列条件**全部**满足时才可写“逐 ROI 通过”：

1. 该页 × 状态 × 动作 × 方向的帧已采集，帧文件名与设备信息写入本台账；
2. 每个 ROI 的字形/布局/动作/时序四项均有人工结论，且结论引用具体帧坐标；
3. hit 协议无缺陷：六字段齐全、`fixed:true` 只出现在 PlayerBar 尾部、顺序与 Qt 源码顺序一致
   （`tool/parity/compare.py` `diff_hits` 的 finding 为空）；
4. 阈值已冻结（当前未冻结 ⇒ 第 4 条恒不满足 ⇒ 全页不可 PASS）。

任一 ROI 未对齐即该页 FAIL；不得用其它 ROI 的通过抵消。

### 4.1 裁决词与脚本字面值的对应（不得自造第五个词）

| 裁决词 | 出现条件 | 脚本位置 |
| --- | --- | --- |
| `UNMEASURED_THRESHOLDS_NOT_FROZEN` | 没有可用阈值文件（阈值未冻结，当前状态） | `compare.py:1155`、`:1179-1191` |
| `FAIL` | 任一辅助指标越过已冻结阈值，或 hit 协议出现任一 FAIL finding | `compare.py:1154`、`:1179-1192`、`:1302-1304` |
| `AUX_METRIC_PASS_MANUAL_REVIEW_REQUIRED` | 辅助指标全部达标——仍**不是**视觉通过，必须人工逐 ROI 复核 | `compare.py:1156`、`:1191`、`:1194-1208` |
| `HIT_PROTOCOL_MATCH_NOT_VISUAL` | hit/命令契约匹配；只说明协议一致，不说明像素对齐 | `compare.py:1157` |
| `HIT_PROTOCOL_NOT_COMPARED` | 没有可比对的参考帧 | `compare.py:1160` |

`FAIL` 是**脚本裁决词**，不是本台账的填写值；本台账只填 §1 的两种证据状态。
`overall_verdict()` 是各 ROI 的最坏值，且**结构上不可能返回 PASS**（`compare.py:1194-1208`）。

### 4.2 阈值文件前置条件

阈值文件只有在**显式冻结**时才生效（`compare.py:1163-1177`）：

1. 顶层必须 `"frozen": true`，否则 `load_thresholds()` 直接返回 None（等价于未冻结）；
2. 必须同时含 `ssim_min`、`delta_e_max`、`pixel_tolerance` 三键，缺任一即抛错；
3. 必须含 `baseline`，说明在哪个 Qt 同设备同场景基线上冻结；
4. 冻结前，任何 SSIM/ΔE/像素容差都只是拟议（计划 §9.2）。

## 5. 未取证页与补采清单

以下表面在计划里被点名，本轮**没有任何帧**，一律“视觉未取证”，需要补采：

- 原生门槛 Consent（P01）、启动 boot（P02）、目录空态（P04）、歌单/专辑/歌手 container（P06）、
  歌词面板（P07）、封面查看器（P08）、个人库（P10）、登录（P11）、设置 7 区（P12）、发现（P13）、
  播放中（P14）、更新（P16）、性能面板（P17）、Tab Mode（P18）。
- 已有 fixture 但无帧：archive（P03）、歌曲详情（P05）、搜索（P09）、播放队列（P15）。
- 桌面歌词（P19）在 Android 不实施；通知（P20）属 T25，不在本台账补采。

补采要求（由具备设备权限的后续任务执行，本树禁止 adb/截图/性能）：

1. 设备固定 526f6b6d（2880×1800，dpr 1.96875），同一构建、同一主题（浅/深各一轮）；
2. 每页 × 每状态一张，命名 `<page>_<state>_<orientation>.png`，同时导出该帧 `commands/hits/frame` JSON；
3. 关键动作补拍“按下前/按下后/动画结束”三帧，用于时序核对；
4. 采集完成前，本台账不得新增“逐 ROI 通过”行。

## 6. 门与不可宣称

| 门 | 状态 | 说明 |
| --- | --- | --- |
| ARCH（T16 五候选同 slice 真实裁决） | `ARCH_BLOCKED` | 未测；本台账不代替架构裁决 |
| DEVICE（像素/性能真机） | `DEVICE_BLOCKED` | 无真机帧、无性能采样 |
| 视觉对齐 | 未取真机帧 ⇒ **不可宣称** | 计划 §9.4（792-799 行） |
| 1:1 完成 | 未跑完 T54 ⇒ **不可宣称** | 计划 §9.4 |
| 竖屏 1:1 | 未审定竖屏 ⇒ **不可宣称** | 计划 §9.4；Qt 两个 Activity 都是 `sensorLandscape`（`AndroidManifest.xml:89`、`:103`），无竖屏像素基线 |

## 7. 记录格式（后续填写）

每一行补采记录至少包含：页面、状态（mode/frame/modal 组合）、方向、设备与 dpr、帧文件名、
`commands/hits/frame` JSON 路径、逐 ROI 结论（字形/布局/动作/时序）、评审人、日期。缺任一项视为未取证。

## 8. 变更记录

| 日期 | 变更 | 说明 |
| --- | --- | --- |
| 2026-11-09 | 建立台账 | 冻结覆盖矩阵、逐 ROI 契约、mask 与判定规则；四场景 fixture 同步落地；真机帧 0 张，全部页面视觉未取证 |
| 2026-11-10 | 全量重写为 18 行 P 编号 | 覆盖矩阵由 29 行压缩为 18 行，删除全序 hits 与四张对照表 |
| 2026-11-10 | 修订（独立审查 7 P0 + 10 P1 闭合） | 补 17 modal 全枚举（含 Android 不可达 3 个）与 mode/viewer/modal 三维（§2.1-2.2）；补 Consent/目录空态/container/更新/性能面板五类（P01/P04/P06/P16/P17）；删除编造的“通知”页并移交 T25（P20）；search 两 ROI 改为 917,374,540,36 与 917,450,699,430；boot 补 `skip`；P05/P06 动作按 song/container 分源重写，歌词与查看器动作归 P07/P08；补三裁决词与阈值 frozen+baseline 前置；补弹层清空 hits、search 态不画页面、同 action 不去重；补 `fixed:true` 唯一来源与触摸外扩区别；修正全部引用行号（含把不存在的“计划 §8.1”改为 §2.4 与附录 B.1） |
| 2026-11-10 | 二轮修订（独立复核 PASS_WITH_FIXES 的 P1/P2 与增量 P1） | §2.1 trackListMode 补 modal 为空 + 非 lyricsMode；§2.2 可达性统一为 Android 14（删去“含恢复 15”）、`local` 不可达理由改为“无 UI 入口”（旧稿误引 `openModal` guard）、M14 条件改 `:336-341`、M16 动作逐字枚举、M17 可达性改“否”；§2.2 末尾把“恢复期特例”改写为“白名单里两个没有 writer 的名字（queue / local）”，说明二者不进必采清单；§3 ROI 归类改为 band 1 + PlayerBar 内 2 + 详情 2 + 队列 3 + 搜索 3；§3.2 mask 违规改为“中断整次运行，比 FAIL 更强”；§2.3 P13 discover tab 差异改为 QQ +2 / 网易 +1、P16 引 `AppUpdater.h:7-30`、P19/P20 措辞收敛 |

## 9. 本文件明确不做的事

- 不宣称任何页面已取证、已对齐、1:1 完成；当前真机帧 0 张、逐 ROI 通过 0 行。
- 不把 `Assets/previews/*.png`（9 张桌面离屏图，3024×1898）当真机证据。
- 不为 `archive_default`、`song_detail`、`queue_empty` 三个 fixture 与 `tool/parity/compare.py` 背书：
  它们属另立原子，仍未独立审查；本文件引用其文件名只为指明输入，不代表其数值已复核。
- 不执行 `flutter build/test/analyze`、`dart test/analyze`、Gradle、pub get、代码生成、formatter、
  任何语法验证脚本、Qt 编译运行、adb、设备安装、截图或性能协议验证。