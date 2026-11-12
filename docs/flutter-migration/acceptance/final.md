# 最终验收与发布门（T54-D01/D02/D03）

- 状态：**NOT_ACCEPTED / 0 PASS**。本文件是门台账与发布检查清单，不是验收结论，不宣称迁移完成、1:1 对齐、视觉通过、性能达标或可发布。
- 基线：root `feat/flutter` 的 `712b1c52ff1b37a31bf495840da2424c504385e2`；worktree `OPS86-A48-DOCS`，branch `flutter/ops86-final-docs`。本树未 build、未 test、未 analyze、未 adb、未安装、未截图、未跑性能采集。
- 计划依据：`docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:734-741`（T54）。T54 要求汇总功能/画面/动作/状态/性能/签名门，逐项标通过/未取证/失败；未过门不得写「1:1 完成」；发布检查覆盖 consent、更新、诊断、媒体会话、返回键、存储、账号迁移；Pass = 所有硬门有证据，Fail = 用文档替代软件验收。
- 判定纪律：`docs/flutter-migration/02-adjudication.md:10-26` 的 E0-E3 分级仍然有效。E0（真机安装/启动/截图/无障碍树实证）是唯一可填设备门的等级；E1 源码、E2 产物哈希、E3 推断都不能替代 E0。当前 E0 采集数为 0（`02-adjudication.md:14`）。

## 0. 判定词与阻塞词

### 0.1 门判定（只用这三个词）

| 判定 | 含义 | 使用条件 |
| --- | --- | --- |
| `PASS` | 该门在指定基线与设备上有可复核证据，且判定标准已冻结 | 当前 0 项 |
| `UNCAPTURED` | 没有该门所需的 E0 证据，或证据实体不可用 | 不得写成「暂缺」「基本通过」 |
| `FAIL` | 有源码或产物证据表明该门当前不成立 | 必须给出具体行号或产物事实 |

`UNCAPTURED` 不是 `FAIL`，也不是 `PASS`。没有数据不等于失败，更不等于通过；不得为了凑一个结论把 `UNCAPTURED` 改写成任一方向。

### 0.2 阻塞状态（只描述原因，不替代门判定）

| 阻塞词 | 含义 | 本文件中的位置 |
| --- | --- | --- |
| `ARCH_BLOCKED` | 宿主架构未裁决，生产接线无法成立 | T16；功能门、发布清单 |
| `DEVICE_BLOCKED` | 需要真机帧/设备行为，当前没有 | 画面、动作、状态、性能、存储迁移 |
| `EXTERNAL_BLOCKED` | 依赖仓库外材料或第三方决定 | 签名材料（keystore/别名/口令） |
| `PAUSED_BY_USER` | 用户明确暂停的领域，不得自行恢复 | 账号迁移、登录路径 |
| `NOT_RUN` | 设备轴整体未执行 | 本树所有设备门 |
| `UNMEASURED` | 指标级状态：无样本或样本不足 | 性能门、T52 指标 |

阻塞词不得互换，也不得降级为「待办」「后续优化」或「已知问题」。`02-adjudication.md:118-129` 明确要求逐字使用，不得改写。

### 0.3 总判定

| 项 | 值 |
| --- | --- |
| 验收门总数 | 6（功能、画面、动作、状态、性能、签名） |
| `PASS` | **0** |
| `UNCAPTURED` | **6**（功能、画面、动作、状态、性能、签名） |
| `FAIL` | **0** |
| 发布检查项 | 7（consent、更新、诊断、媒体会话、返回键、存储、账号迁移） |
| 发布就绪项 | **0** |
| 总判定 | **NOT_ACCEPTED** |

## 1. 验收门表（T54-D01）

### 1.1 六门总表

| # | 门 | 必须成立（判定标准） | 当前判定 | 阻塞 | 证据/缺口 |
| --- | --- | --- | --- | --- | --- |
| G-FUNC | 功能门 | P01-P20 的适用页面、登录六路径、设置七区、搜索/队列/播放/存储等主路径在真机上按 Qt 行为工作，且有 E0 记录 | `UNCAPTURED` | `ARCH_BLOCKED` + `DEVICE_BLOCKED` + `PAUSED_BY_USER`（账号域） | 页面台账全行未取证（`acceptance/landscape.md:135-156`）；未取证登记（`evidence/uncaptured-pages.md:104-127`）；T16 未裁决（`02-adjudication.md:6`、:68-80）；账号域暂停（`addenda/2026-11-11-t16-dependency-annotations.md:27`、:72） |
| G-SCREEN | 画面门 | 每页每状态有真机帧，逐 ROI 人工对照可追溯，命中协议无缺陷，阈值已冻结 | `UNCAPTURED` | `DEVICE_BLOCKED` | 已采集真机帧 0/12（`landscape.md:19`）；12 图实体丢失（`device-2026-11-09.md:130-156`；`00-baseline.md:308-311`）；逐 ROI 通过当前 0 行（`landscape.md:26-29`）；本文件不把 previews 当真机帧（`landscape.md:20`） |
| G-ACTION | 动作门 | 点击/滚动/返回/IME 等动作的 hit 坐标、消费顺序、系统返回语义与 Qt 一致，且有设备记录 | `UNCAPTURED` | `DEVICE_BLOCKED` | hit 源码已读未比对（`landscape.md:23`）；脚本裁决词未执行（`landscape.md:256-267`）；返回键见 §2.5，Dart 侧 handler 缺失 |
| G-STATE | 状态门 | session/playback/view 的保存与恢复、旋转/尺寸变化、队列与播放态、登录态在设备上按契约工作 | `UNCAPTURED` | `DEVICE_BLOCKED` | 存储契约已冻结但未做设备往返（`contracts/storage.md:63-221`、:248-275）；旋转连续性模板未填未跑（`acceptance/portrait.md:427-469`）；竖屏状态机不变式 S4/S7（`portrait.md:52-62`）无设备证据 |
| G-PERF | 性能门 | 按 T52 方法采集帧时间分布、首帧、内存、启动、30 分钟稳定，并与 Qt 同设备同场景对比；阈值已冻结 | `UNCAPTURED`（指标 `UNMEASURED`） | `DEVICE_BLOCKED` + `NOT_RUN` | `03-performance.md:172-187` 全 `UNMEASURED`；采集器未执行、无 JSONL（`tool/perf/README.md:278-288`）；稳定门与阈值未冻结（`02-adjudication.md:94-102`、:131-139） |
| G-SIGN | 签名门 | release 包使用 Qt 证书签名，applicationId 一致，versionCode 单调，可覆盖安装保留数据 | `UNCAPTURED` | `EXTERNAL_BLOCKED`（签名材料） | 无已签名的 release APK 证据，未核对 keystore/别名/口令；当前源码为 fail-closed：材料缺失时配置阶段与任务图阶段双重拒绝，且无 debug 回退（`android/app/build.gradle.kts:81-87`、:121-141、:144-152）；applicationId 为 `rhine.music.database`（:106）；Qt 证书与旧 Flutter 证书不同（`release.md:21-23`）；缺材料即 `BLOCKED_SIGNING_MATERIAL`（`release.md:62-69`）；G8 OPEN（`00-baseline.md:324`）。`release.md:30` 的「release 仍用 debug」断言已被 `af5ab6d` 取代，不作为当前源码事实 |

### 1.2 门与 `00-baseline.md` §9 的 G1-G8

| 编号 | 内容 | 状态 | 与 T54 的关系 |
| --- | --- | --- | --- |
| G1 | APK 与 Qt 源码同 commit | `CLOSED`（artifact-level，E2） | 只证明产物来源；不关闭 G2-G8（`00-baseline.md:317`、:326） |
| G2 | 业务页仅 12 张局部横屏 | `OPEN`（原图实体丢失） | 画面门 `UNCAPTURED` 的直接原因（`00-baseline.md:318`） |
| G3 | Qt 无竖屏规范 | `OPEN` | 竖屏只能称新增重排，不能称 1:1（`00-baseline.md:319`；`portrait.md:3`） |
| G4 | 设置七区逐项可见性 | `OPEN` | 功能/画面门均缺设置第 6 项以后证据（`00-baseline.md:320`） |
| G5 | 存储逐键 schema/损坏回退 | `OPEN` | 状态门缺设备往返（`00-baseline.md:321`） |
| G6 | 登录后个人音乐/发现无真机画面 | `OPEN` | 账号域 `PAUSED_BY_USER`；G6 不得用 mock 补位（`00-baseline.md:322`） |
| G7 | Android 内嵌 Node Flutter 生命周期 | `OPEN` | 功能门/稳定性门的上游风险（`00-baseline.md:323`） |
| G8 | 签名材料可用性 | `OPEN` | 签名门 `UNCAPTURED` + `EXTERNAL_BLOCKED`（`00-baseline.md:324`） |

### 1.3 屏幕/页面覆盖

- P01-P18：全部 `UNCAPTURED`（`landscape.md:135-156`；逐项登记见 `uncaptured-pages.md:104-127`）。其中 P01-P18 没有任何一页满足「逐 ROI 通过」的四条件（`landscape.md:244-252`）。
- P19（桌面歌词）：Android 不适用，不列为待取证页面（`landscape.md:155`）。
- P20（通知/前台 Service）：移交 T25，不属本台账页面（`landscape.md:156`）。
- 12 张基线 PNG：索引存在、实体丢失，像素可用性为 0（`uncaptured-pages.md:40`；`device-2026-11-09.md:151-156`）。索引不是帧，不能用于像素比较，也不能用于「已对齐」声明。
- 已取证页面：0 行（`uncaptured-pages.md:42-44`）。

### 1.4 T16 与设备轴

- T16 宿主架构裁决：**未裁决**。五候选 A-E 的七门全部 `UNMEASURED`，赢家 `UNASSIGNED`（`02-adjudication.md:6`、:68-80）。生产接线 `ARCH_BLOCKED`，测量 `DEVICE_BLOCKED`（`02-adjudication.md:104-116`）。这两个状态不得互换，也不得降级（:118-129）。
- 设备轴：**NOT_RUN**。本树没有 adb、没有安装、没有截图、没有性能采集；E0 采集数 = 0（`02-adjudication.md:14`）。设备 serial 526f6b6d、2880×1800、dpr 1.96875 的参照几何来自旧记录（`landscape.md:8-9`；`device-2026-11-09.md:7`、:16-29），不是本次运行。
- T16 未裁决意味着功能门无法用「源码已实现」替代生产宿主验证；在裁决前，任何「功能完成」声明都不成立。

### 1.5 T54-D01 结论

- 六门中 6 项 `UNCAPTURED`、0 项 `FAIL`、0 项 `PASS`。
- 因此本文件不写「1:1 完成」「功能对齐」「视觉对齐」「性能达标」「可发布」。
- 也不把 `UNCAPTURED` 写成「待验」这种听起来接近完成的词；它就是「没有证据」。
- 唯一有产物级证据的是 G1（APK 与 Qt 源码同 commit，E2），但它不关闭任何业务门（`00-baseline.md:326`）。

## 2. 发布检查清单（T54-D02）

### 2.1 七项检查

判定列只使用 `SOURCE_READY`、`UNCAPTURED`、`DEVICE_BLOCKED`、`PAUSED`、`EXTERNAL`。`SOURCE_READY` 只表示源码/契约存在且可读，不表示设备行为通过。

| # | 检查项 | 必须成立 | 现状与证据 | 判定 | 阻塞/缺口 |
| --- | --- | --- | --- | --- | --- |
| R1 | consent | 首启 CN/EU 弹窗、不可 dismiss、同意写一次、其他地区不弹不写、返回键语义与 Qt 一致，并有真机记录 | `lib/app/consent_gate.dart:9-32` 记录 ConsentActivity/ConsentStore 1:1 与 3000 ms 地区探测门（:92）；`lib/ui/pages/consent_page.dart:255-257`、:375-378 复刻 PopScope 返回键语义；12 图索引只有 01/02 两张 consent 帧，实体已丢失（`device-2026-11-09.md:106-107`、:151-156） | `SOURCE_READY` + `UNCAPTURED` | 无真机 consent 帧；无 CN/EU/其他地区三态设备记录 |
| R2 | 更新 | 检查更新、打开发布页、错误与重试分支按 Qt 行为工作；不在应用内下载或安装 | `lib/platform/update_service.dart:19-46`：repo `MikeQu223/Rhine-Music-Database`、包上限 2 GiB（:22）、响应上限 1 MiB（:25）、超时 30 s（:31）、退避 60 s（:34）、Retry-After 上限 86400 s（:37）；应用内不下载不安装 | `SOURCE_READY` + `UNCAPTURED` | 未联网、未构造更新响应、未在设备上验证打开发布页/取消/错误 |
| R3 | 诊断 | 72 个数值键、8192 事件上限、相对 elapsedMs、固定事件白名单、无敏感字段；设备输出样本标记为不可用 | `lib/diagnostics/diagnostics_service.dart:12-13`（72 键/8192 上限）、:48-49、:65-67；`deviceOutputSamplesAvailable=false`（:179-180、:399-400）；设备像素/性能 proof 属 `DEVICE_BLOCKED`（:261-262） | `SOURCE_READY` + `UNCAPTURED` | 未导出真实诊断快照；未验证 8192 边界；无设备日志对齐 |
| R4 | 媒体会话 | 前台服务/MediaSession/MediaStyle/音频焦点与 Qt 1:1，设备上可被系统媒体控件控制 | A45 分支 `flutter/ops86-media-session` 已交付，源码静态评审通过（仅源码，不是设备验收）：`OPS86-A45-REVIEW.json:13-50` 六文件、:51 verdict、:111-121 post_commit；base 已有 `android/app/src/main/kotlin/rhine/music/database/porting/MediaSessionHost.kt:19-21`、:60 与 `porting/MediaPlaybackService.kt:22-33`、:49；但 base 无 `lib/platform/media_session.dart`、无 `porting/MediaSessionChannel.kt`，A45 五个 commit（cc4539d..1df0be2）未并入 `712b1c5` | `SOURCE_READY`（仅 A45 分支）+ `DEVICE_BLOCKED` | **source channel ready at A45；设备未验**；且 A45 未并入 base，当前 base 不构成可发布链路 |
| R5 | 返回键 | IME 可见先隐并消费；否则询问 Qt 宿主，仅显式 true 认领；未认领落回 Flutter；250 ms 超时降级 | `MainActivity.kt:20-40` 记录顺序与 250 ms 超时；:110-134 实现 `dispatchHostBack`/`fallBackToFlutter`；:37-40 明示 Dart 侧还没有 `METHOD_BACK` handler，Qt 认领分支在 Dart 落地前不可达，本原子不声称端到端验证过 | `UNCAPTURED` | 源码缺口：Dart handler 缺失；无设备返回键记录；不得把「宿主已实现」写成「返回键通过」 |
| R6 | 存储 | session.json/playback-session.json/panel 键/credential/collections 的 schema、64 MiB 边界、损坏回退、迁移与 Qt 双向可读 | 契约已冻结：`contracts/storage.md:42-57`（文件表）、:61（64 MiB 边界 67,108,864 收 / 67,108,865 拒）、:63-221（session）、:248-275（playback-session）、:277-355（panel 53 键）、:361-373（credential 路径/0600/写入）、:440-463（collections）、:475-482（迁移）；Dart 实现已存在：`lib/data/storage/session_store.dart`（815 行）、`playback_store.dart`（494）、`preference_store.dart`（202）、`app_storage.dart`（385） | `SOURCE_READY` + `DEVICE_BLOCKED` | 未做 Qt↔Flutter 往返；未验证 64 MiB 边界、损坏文件、部分字段、SIGKILL 节拍 |
| R7 | 账号迁移 | 登录六路径、凭据 0600、账号切换/登出、provider/edition/uid 身份门与 Qt 一致 | 账号域 **PAUSED_BY_USER**：DEDUP-15/16/30/32 保持暂停，不重启账号测试/制作（`addenda/2026-11-11-t16-dependency-annotations.md:27`、:72）；`lib/domain/account/account_manager.dart:11-13` 记录 AccountEffects/AccountHostPort；`credential_store.dart:4`、:24-37、:108-115 记录 PlatformAndroid 路径/0600/截断写语义；身份门见 `storage.md:80`、`domain.md:586` | `PAUSED` + `UNCAPTURED` | 用户暂停；无登录真机帧；不得用 mock 或源码补位 |

### 2.2 横切状态

| 轴 | 状态 | 证据 |
| --- | --- | --- |
| T16 宿主架构 | **未裁决** / `ARCH_BLOCKED` | `02-adjudication.md:6`、:68-80、:104-116 |
| 设备轴 | **NOT_RUN** | E0=0（`02-adjudication.md:14`）；本树无 adb/安装/截图 |
| 签名材料 | **EXTERNAL_BLOCKED** | `release.md:62-69`；G8 OPEN（`00-baseline.md:324`） |
| 账号域 | **PAUSED_BY_USER** | `addenda/2026-11-11-t16-dependency-annotations.md:27`、:72 |
| 像素/视觉 | `DEVICE_BLOCKED` | `landscape.md:4`、:19-29；`00-baseline.md:308-311` |
| 性能 | `UNMEASURED` | `03-performance.md:172-187` |
| 媒体会话 | A45 源码静态评审通过；base 未合并；设备未验 | A45 review :51、:111-121；base 文件缺失 |
| 返回键 | 源码部分就绪；Dart handler 缺失 | `MainActivity.kt:37-40` |

### 2.3 T54-D02 结论

- 7 项发布检查：0 项达到「可发布」；4 项 `SOURCE_READY`（consent、更新、诊断、存储），1 项仅 A45 分支 `SOURCE_READY`（媒体会话），1 项源码缺口（返回键），1 项用户暂停（账号迁移）。
- `SOURCE_READY` 不是 `PASS`；它只说明「代码/契约可读」，不说明「设备行为正确」。
- 媒体会话的准确表述是：**source channel ready at A45；设备未验；A45 分支未并入 base**。不得写成「媒体会话已通过」。
- 本文件不提供发布序列；发布序列仍以 `release.md:116-124` 为准，且其前置签名材料未到位。

## 3. 阻塞与最终声明门（T54-D03）

### 3.1 声明规则

1. 任一硬门没有 E0 证据，就阻塞最终声明；不管源码多完整、评审多充分。
2. `ARCH_BLOCKED`、`DEVICE_BLOCKED`、`EXTERNAL_BLOCKED`、`PAUSED_BY_USER`、`NOT_RUN` 不得改写成绿色，也不得用「已知问题」「后续优化」「设计如此」降级。
3. 文档不能替代软件验收（计划 :739）。本文件写得再完整，也不能让 0 帧变成 1 帧。
4. 不得编造 golden、截图、签名、性能数字、设备日志或时间表；没有就写没有。
5. 只有在所有硬门均有可复核 E0 证据、阈值已冻结、独立评审通过后，才可另写验收结论；本文件不预留「自动通过」通道。

### 3.2 阻塞矩阵

| 阻塞 | 直接阻塞的门/检查 | 关闭条件 | 当前状态 |
| --- | --- | --- | --- |
| T16 未裁决 | 功能门、生产接线、登录/个人库 | 五候选有设备证据并形成裁决；ADR 与接线评审通过 | 未裁决（`02-adjudication.md:6`） |
| 设备轴 NOT_RUN | 画面、动作、状态、性能、发布检查 | 在 526f6b6d 上按状态脚本采集并登记 | 0 次（`02-adjudication.md:14`） |
| 12 图实体丢失 | 画面门 | 用完整 SHA256/尺寸/指纹/APK SHA/状态脚本重采 12 页并入库 | 实体不可用（`device-2026-11-09.md:151-156`） |
| 逐 ROI 阈值未冻结 | 画面门 | 冻结 SSIM/ΔE/容差并写明来源 | 拟议未冻结（`02-adjudication.md:101`；`landscape.md:21`） |
| 性能阈值未冻结 | 性能门 | 冻结指标/场景/对比方式；完成 30 分钟 run 与日志 | 全 `UNMEASURED`（`03-performance.md:189-202`） |
| 签名材料未到位 | 签名门、发布 | keystore/别名/口令可用；release signingConfig 指向 Qt 证书；versionCode 单调 | `EXTERNAL_BLOCKED`（`release.md:62-69`） |
| 账号域暂停 | 登录六路径、个人库、账号迁移 | 用户明确解除暂停；提供账号测试授权 | `PAUSED_BY_USER`（addenda :27、:72） |
| A45 未并入 base | 媒体会话、发布 | 决定合并策略并完成合并/复核；设备验证系统媒体控件 | 分支 PASS，base 缺文件 |
| Dart METHOD_BACK 缺失 | 返回键、发布 | 实现 Dart handler；设备端验证 IME/Qt/Flutter 三条路径 | 源码缺口（`MainActivity.kt:37-40`） |
| 竖屏模板未跑 | 状态门、T51 | 填模板并按三档设备跑；冻结候选 | `WAIT-` 系列（`portrait.md:471-485`） |

### 3.3 剩余采集任务

| ID | 任务 | 需要什么证据 | 退出条件 | 依赖 |
| --- | --- | --- | --- | --- |
| C1 | 重采 12 张基线页 | 完整 SHA256、PNG 尺寸、device fingerprint、APK SHA256、状态脚本、操作序列、commands/hits/frame JSON | 12 张实体入库且可像素比对 | 设备、APK、脚本 |
| C2 | P01-P18 逐页/逐状态取证 | 每页每状态每方向至少一帧；逐 ROI 四项人工结论；评审人/日期 | 逐 ROI 通过行 >0 且可追溯 | C1、阈值冻结 |
| C3 | 登录六路径 | 未登录/输入/错误/成功/登出帧；账号授权；不记录凭据 | 六路径均有 E0；账号域解除暂停 | 用户授权、T16 |
| C4 | 播放/队列/seek/歌词 | 播放中、暂停、seek、队列有内容、删除、拖动、歌词面板帧 | 动作与状态均有 E0 | 设备、状态脚本 |
| C5 | 设置七区 | 第 6 项以后、展开、保存失败、重启后保持 | 七区逐项可见性与持久化有 E0 | 设备、存储契约 |
| C6 | Tab Mode / 发现 / 我的音乐 | 各入口、切换、空态/有数据态 | 页面与状态均有 E0 | 设备、T16 |
| C7 | 竖屏三档 | 1080×2400@420、1440×3200@480、1200×2000（density 待冻结）的布局/安全区/48dp | 三档模板填完并评审 | 设备、候选冻结 |
| C8 | 性能两侧采集 | Flutter/Qt 同设备同场景 JSONL、30 分钟 run、logcat、刷新率/热状态 | 指标 `MEASURED` 且可重放；阈值冻结 | 生产者、设备 |
| C9 | 存储往返/迁移 | Qt 写→Flutter 读、Flutter 写→Qt 读、64 MiB 边界、损坏/部分字段、SIGKILL | 全部路径有 E0 或明确的 UNMEASURED 说明 | 设备、契约 |
| C10 | 签名材料 | keystore/别名/口令可用；release 用 Qt 证书；versionCode 单调；覆盖安装 | 签名门 PASS；可覆盖安装保留数据 | 外部材料 |
| C11 | 媒体会话合入与设备验证 | 合并决定；系统媒体控件/通知/音频焦点设备记录 | 源码在 base；设备行为 PASS | A45、T16 |
| C12 | 返回键端到端 | Dart handler；IME/Qt/Flutter 三路径设备记录 | 三条路径均有 E0 | 源码、设备 |
| C13 | T16 架构裁决 | 五候选设备证据、ADR、生产接线评审 | 裁决完成；ARCH_BLOCKED 解除 | 设备、架构评审 |

### 3.4 未关闭项

- G2-G8 全部 `OPEN`；G1 仅产物级 `CLOSED`，不关闭其余门（`00-baseline.md:317-326`）。
- T16 未裁决；生产宿主/窗口/平台视图形态未定（`02-adjudication.md:6`、:104-116）。
- T50 横屏台账：0/12 真机帧，逐 ROI 通过 0 行（`landscape.md:19`、:26-29）。
- T51 竖屏：候选未冻结、golden 缺失、设备未跑（`portrait.md:471-485`）。
- T52 性能：0 run、无生产者、全 `UNMEASURED`（`03-performance.md:172-187`）。
- T53 签名：无已签名的 release APK 证据；源码为 fail-closed（`build.gradle.kts:121-141`）；G8 `OPEN`；材料 `EXTERNAL_BLOCKED`（`release.md:62-69`；其 :30 的 debug 断言已过期）。
- A45 媒体会话：分支 PASS，base 未并入，设备未验（A45 review :51、:111-121）。
- 返回键：Dart `METHOD_BACK` handler 缺失（`MainActivity.kt:37-40`）。
- 账号域：`PAUSED_BY_USER`（addenda :27、:72）。

### 3.5 最终声明模板（仅在全部关闭后使用）

```text
声明：Rhine Music Database Flutter 迁移在 <device> / <build SHA> / <APK SHA256> 上，
对 <页面清单> 的 <状态清单> 满足 <冻结后的验收标准>。
证据：<帧清单 + JSON + 评审报告>。
未覆盖：<明确列出>。
```

当前不能填写上述模板：设备、构建、帧清单、冻结标准、评审报告均不完整。任何提前填写都属伪造。

### 3.6 当前可说的与不可说的

可以说：

- 契约与部分源码已存在；A45 媒体会话源码在独立分支通过静态评审；G1 有产物级证据。
- 12 张基线图只剩索引；像素证据实体不可用。
- 功能、画面、动作、状态、性能均未取证；签名门未取证，外部签名材料未核对。

不可说：

- 「1:1 完成」「功能已对齐」「视觉已通过」「性能达标」「可发布」「只剩收尾」。
- 「12 张图已取证」「A45 已可用」「返回键已通过」「账号迁移已验证」。
- 任何带日期或百分比的完成度承诺；没有证据支持。

### 3.7 T54-D03 结论

- 最终声明被 6 个门全部 `UNCAPTURED`（0 `PASS`、0 `FAIL`）阻塞；发布检查 7 项中 0 项可发布。
- 阻塞不是「文档没写好」，而是「设备证据不存在 / 架构未裁决 / 签名材料不可用 / 账号域被暂停」。
- 本文件不设定新的完成日期，也不把任何阻塞项转成「已知风险接受」。在用户明确解除账号暂停、签名材料到位、T16 裁决、设备采集完成之前，迁移不得宣称完成。

## 4. 本文件未执行的事

未执行：`flutter build`、`flutter test`、`dart analyze`、`dart test`、`dart run`、Gradle/gradlew、adb、安装/卸载/清数据、截图、性能采集、Qt 编译/运行、任何项目验证脚本。未生成 golden、未生成 JSONL、未修改产品源码、未修改 `tool/perf/collect_frame_times.dart`。

## 5. 变更记录

- 2026-11-12：创建。只登记门、发布检查与阻塞；未采集、未执行、未宣称任何门通过。
