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
