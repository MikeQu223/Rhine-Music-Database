# T53 发布签名、数据升级与回滚门（源码态冻结）

状态：**SOURCE_ONLY / 未执行**。本文件与 `tool/release/verify_signing.sh` 只做源码编写与独立逻辑审查；
本树**未运行**任何构建、签名核对、adb、APK 安装/卸载/清数据。T16 生产宿主接线 `ARCH_BLOCKED`、
像素/性能设备门 `DEVICE_BLOCKED` 保持原样，本文件不解除、不代替它们。

| 项 | 值 |
|---|---|
| 原子 | T53-C01-M12 |
| 计划映射 | T53 签名、数据升级与回滚，docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:726-732（Owner: RELEASE · Deps: T52） |
| 工作树 | .agents/parity-20261109/worktrees/T53 |
| 分支 | flutter/p4-t53-release-gate |
| 基线 | 8ed3067b0812eb2612f7841ec127a6e8ca93231b |
| 本原子写域 | docs/flutter-migration/release.md、tool/release/verify_signing.sh（仓库内写域仅此两文件；reports/、control/ 属控制面台账，不在仓库写域内） |
| 前置缺口 | G8「签名材料可用性未核对」仍未闭合（plan:112）；reports/T53-V4.json 在本树不存在（glob 核名，未找到），不引用未核实的旧结论 |

## 1. 只读证据台账（本文件所有断言均可回溯到这些行）

| 事实 | 值 | 出处 |
|---|---|---|
| Qt 包签名证书 SHA256 | 39396cd06f2b7980302bad220ed071e09286540be4d224a2f9b047ca65205bdf | plan:81、plan:728；APK JAR 签名块读出，T01 基线 §4 |
| 旧 Flutter 证书 SHA256 | 7c514fe8cf95411117b6a4d1cba78768c1cda1d665c42f4828398d8587239dd4 | plan:81 |
| 两证书关系 | 不同（不兼容签名） | plan:81 |
| Qt 包名（模板） | org.qtproject.example（占位符，由 androiddeployqt 替换） | Qt/android/AndroidManifest.xml:13 |
| Qt 版本注入 | android:versionCode/versionName 为 %%INSERT_*%% 占位符 | Qt/android/AndroidManifest.xml:15-16 |
| 基线 APK 实测 | package rhine.music.database、versionName 0.0.0、versionCode 1、minSdk 28、targetSdk 36、arm64-v8a | T01 基线 §3（worktrees/T01/docs/flutter-migration/00-baseline.md:63-69） |
| Flutter applicationId | rhine.music.database | android/app/build.gradle.kts:19 |
| Flutter 版本来源 | versionCode/versionName 取自 pubspec（flutter.versionCode/versionName） | android/app/build.gradle.kts:28-29 |
| Flutter pubspec 版本 | version: 1.0.0+1 → versionCode 1、versionName 1.0.0 | pubspec.yaml:19 |
| Flutter release 签名 | signingConfig = signingConfigs.getByName("debug")（仍用 debug 密钥） | android/app/build.gradle.kts:33-37 |
| Qt allowBackup | false | Qt/android/AndroidManifest.xml:65；plan:82 |
| Flutter main manifest | 未声明 android:allowBackup（默认 true），与 Qt 行为不一致 | android/app/src/main/AndroidManifest.xml:2-45 |
| Qt 其它窗口属性 | resizeableActivity=false、enableOnBackInvokedCallback=true、usesCleartextTraffic=true、glEsVersion 0x00030000 required | Qt/android/AndroidManifest.xml:38,63-67 |
| 桌面发布版本脚本 | RHINE_VERSION 缺失时 version=0.0.0 且 release=false；组件上限 65535 | scripts/release-version.cjs:13-35 |

**版本通道结论**：Android 版本由 pubspec.yaml + android/app/build.gradle.kts 决定（Flutter Gradle 插件读取），
scripts/release-version.cjs 只服务桌面打包身份，**不得**拿它当 Android versionCode 依据。

## 2. 签名不兼容是硬事实，不是策略选择

1. 39396cd0…（Qt）与 7c514f…（旧 Flutter）是两把不同的密钥：同一 applicationId 的两个 APK 只有
   **（package, 签名证书）对**都一致才能覆盖安装。签名不同即拒装（平台返回
   INSTALL_FAILED_UPDATE_INCOMPATIBLE；本树按禁令未实测，属 Android 包管理既定行为，不作“已验证”声明）。
2. 因此发布包**必须**用 Qt 证书私钥签名（复用同一 keystore/别名）。若私钥不可达，则**不存在**“覆盖安装且保留数据”的路径，
   只能走正式迁移路径（例如用户侧重新登录/导出，或改用新 applicationId 按新应用处理），并在 T54 声明中如实标注。
3. 绝对禁止：卸载后重装、清应用数据、`adb install -d`（降级标志）、改包名后宣称数据保留、
   为“让流程跑通”临时自造证书。自造证书必然落入脚本的 UNKNOWN/INCOMPATIBLE 分支并以非零码退出。
4. 旧 Flutter 包若已被安装过，它同样无法覆盖 Qt 包；本文件不假设设备上的安装历史，只固定判定规则。

## 3. 版本、升级与回滚的真实约束

- **versionCode 单调递增且不低于 1**（plan:729）。已安装 Qt 基线为 1，因此首个 Flutter 发布包 versionCode ≥ 2
  （现 pubspec 为 1.0.0+1 → 1，**未满足**，落地时必须上调 build number）。
- **回滚同样受签名与 versionCode 约束**：回滚包必须同签名且 versionCode **更高**，不能靠
  `adb install -d` 降级安装（plan:729）。
- **数据保留的三个必要条件同时成立**：applicationId 不变、签名相同、不卸载。任一破坏即等同换应用。
- **allowBackup=false**：不得承诺 `adb backup`/私有备份可用，也不得把“没有备份”当成恢复手段（plan:82）。
- **必须原样保留的数据面**（不得以清数据“修复”崩溃）：Qt AppStorage 键、QSettings、Qt session、账号/收藏/device id（plan:730；Qt 源证：Qt/src/AppStorage.h/.cpp 经 QSettings 落盘）。
  具体键位 schema 由 T07 冻结、T26 实现，本文件不重复冻结，只固定“覆盖安装必须保留”的门。
- **versionName 变化**（0.0.0 → 1.0.0）本身不阻塞覆盖安装；它只影响用户可见版本串，不参与安装判定（平台既定行为，本树未实测，同 §2 的标注纪律）。

## 4. 签名材料缺失时的门状态：BLOCKED，不伪成功

- 状态名：`BLOCKED_SIGNING_MATERIAL`。处置：只读核对 keystore 文件、别名、口令保管（G8，plan:112），
  不可用则**停**并输出迁移方案；禁止把“未核对”写成“已通过”，禁止用 debug 密钥或新证书宣称发布门通过。
- 缺口令同样算 BLOCKED：脚本以退出码 5 结束，绝不回显、落盘或破解口令。
- 当前源码事实：android/app/build.gradle.kts:36 仍指向 debug 签名 → `gradle` 模式会以 **7** 退出。
  这是“门未满足”的诚实表示；切换 release signingConfig 属 android/app/build.gradle.kts 的 owner，
  **不在本原子写域**，本文件只记录该缺口。

## 5. 离线核对脚本 tool/release/verify_signing.sh

只读门；不联网、不下载、不安装/卸载、不改数据、不签名、不构建。只调用只读查询
（apksigner verify --print-certs / keytool -printcert -jarfile / keytool -list -v / aapt dump badging / apkanalyzer）。

| 模式 | 作用 |
|---|---|
| `apk <apk>` | 打印 APK SHA256、证书 SHA256、包名、versionCode，并与 Qt 证书比对 |
| `keystore <ks>` | 口令从 RHINE_KEYSTORE_PASSWORD 传入，只读列出别名与证书指纹并比对 |
| `session <old.apk> <new.apk>` | 两包同签名 + versionCode 严格递增（覆盖安装前提） |
| `gradle <build.gradle.kts>` | release 构建类型不得使用 debug signingConfig |

| 退出码 | 含义 |
|---|---|
| 0 | PASS |
| 1 | 用法/IO 错误 |
| 2 | 证书未知或不匹配 Qt 证书 |
| 3 | 缺少只读工具（拒绝改用联网或 adb 手段补足） |
| 4 | 两个 APK 签名不同 |
| 5 | 缺签名材料/口令（BLOCKED） |
| 6 | 旧 Flutter 证书（不可覆盖安装） |
| 7 | release 仍用 debug 签名（发布门未满足） |
| 8 | versionCode 非单调 / 低于已安装基线 |
| 9 | applicationId 不是 rhine.music.database |

脚本**不执行**任何写操作；除被指定路径外不读仓库其它内容，不产生临时文件、不修改 APK 与 keystore。

**fail-closed 语义**：apk 模式在缺少 sha256sum/aapt/apkanalyzer、或读不出 APK SHA256/applicationId/versionCode 时一律以 3（缺工具）或 1（IO）退出——
“读不出”不得当成 PASS；session 模式的 SESSION=SAME_SIGNER_AND_MONOTONIC_VERSION 只在 rc=0（证书=Qt 证书且 versionCode 严格递增）时打印。

**已知边界（静态审查，未执行）**：
1. apk 模式对 versionCode 只设“不低于已安装基线 1”的下限；首个 Flutter 发布包必须 ≥2 的判定由 §7 步骤 5 的 session 模式（严格递增）承担。
2. keytool -printcert -jarfile 需要 JAR/v1 签名条目；纯 v2/v3 签名的 APK 读不出指纹（fail-closed 退 2）。Qt 基线 APK 含 META-INF/MYKEY.RSA 等 v1 条目（T01 基线 §4/§3），故基线可读。
3. keystore 模式只比对 keytool 输出的**第一处** SHA256；若 keystore 含多别名，其余条目不被覆盖。
4. keytool 输出的**别名列表**（`Alias name:`）依赖英文 locale（本机可能为 zh_CN）；SHA256 指纹标签为 ASCII（T01 基线 :85-86 佐证），静态解析的真实风险在别名段而非指纹段。
5. gradle 模式是字面量匹配 signingConfigs.getByName("debug")，其它等价写法可能漏判（脚本内已注明“仍需核对实际证书指纹”）。
6. **apk 模式退出码优先级**：先判证书（0/2/6），再判包名与 versionCode；若宿主缺 aapt/apkanalyzer，包名/versionCode 的 `die 3` 会覆盖已判定的 2/6。两种结果都 fail-closed，但排障须知：报 3 不代表证书没问题，补上只读工具重跑才能得到 2/6。

## 6. 本原子未执行、未取证的项（RED 未执行）

未执行：flutter build/test/analyze、dart test/analyze、gradle/gradlew、pub get、格式化/代码生成/验证脚本、
Qt 编译运行、adb、APK 安装/卸载/清数据/截图/性能/协议验证、以及本文件所示脚本本身（含 `sh -n`）。
因此脚本的 shell 语法、工具输出解析、退出码分支均为**静态审查对象**，不得写成“已通过执行验证”。
设备门、像素门、性能门与 T16 生产 ARCH 门保持 blocked，不在本原子范围。

## 7. 发布序列（待签名材料到位后由获准方执行；本原子不执行）

1. 只读核对 keystore + 别名 + 口令保管 → 记 `keystore` 模式输出；不可达则停（§4）。
2. 把 release signingConfig 指向该 keystore（android/app/build.gradle.kts 的 owner 执行），并确认口令仅经环境变量/凭据存储传入。
3. versionCode 上调到 ≥ 2 且严格大于已安装版本；构建 release APK（获准环境执行）。
4. `verify_signing.sh apk <apk>` 必须 PASS（证书=Qt、package=rhine.music.database）。
5. `verify_signing.sh session <已安装基线apk> <新apk>` 必须同签名且 versionCode 递增。
6. 覆盖安装（不清数据、不卸载），核对账号/收藏/device/session 保留 → 记入 T50-T54 验收。
7. 回滚演练：用同签名、更高 versionCode 的回滚包覆盖，同样不清数据。

## 8. 独立审查与提交记录

- Reviewer：agent 030c4364-0a00-4ac1-862f-85a1bc7511ad，depth2 叶、只读、无 Git 权限、未派生后代；
  route vclib-cn / deepseek-v4.1-flash / reasoning_effort=max（派发方固定，未回退）。报告：.agents/parity-20261109/reports/T53-C01-M12-R.json。
- 首轮裁决：**PASS_WITH_MUST_FIX**（2 必修，12 NIT）。产物身份获核验：release.md sha256 984fd010186e4bb2d104d77d9937e5913a8e094cf6dbe5f400e40db7f1b7d78c（119 行）、
  verify_signing.sh sha256 6d8d719bbb734fa8d33667efb65f36dd57761e19a8f21f6b8e1cca0dffcee0e5（217 行，755）；HEAD=基线，post-HEAD 改动仅本两文件。
- MUST_FIX 关闭记录（owner 实收修正）：
  1. MF-1 apk 模式 fail-open（脚本 112/118-137）：现 sha256sum 缺失/空值即退 3/1，读不出 applicationId 或 versionCode 即 die 3，不再打印 UNKNOWN 后 PASS。
  2. MF-2 session 模式假成功日志（脚本 177-180）：SESSION=SAME_SIGNER_AND_MONOTONIC_VERSION 移入 rc=0 分支。
- NIT 处置：N-1 已修（session 模式先验 APK 存在，避免 die 被命令替换吞掉）；N-12 已修（未知模式先报模式名）；
  N-2/N-3/N-4/N-5/N-6 已写入 §5「已知边界」；N-7/N-8 已补出处与“未实测”标注；N-11 已更正控制面报告行数。
- 复核（第 2 轮，同一 reviewer）：必修关闭裁决 **CLOSED**（MF-1a/MF-1b/MF-2 逐项成立），另报 N-11 未关闭与 R-1..R-5 残留 NIT；
  复核证据按 文件:行号 记入 reports/T53-C01-M12-R.json（closureRound2 段），台账记入 reports/T53-C01-M12.json 的 reviewClosure。
- 残留 NIT 处置：N-11（台账行数漂移）已更正；R-1 已修（去掉 cut 依赖，改用 `${apk_sha%% *}`）；
  R-2 已修（缺 keytool 时诊断改走 stderr，不再被命令替换吞掉，退出码仍 3）；R-3 已写入 §5 已知边界 6（退出码优先级）；
  R-4 已改写 §5 已知边界 4（locale 风险限别名段）；R-5 由本轮 §8 回填与报告的 reviewClosure 键落实。
- 修改后需由同一 reviewer 就新修订复核（第 3 轮），确认未回归必修项；最终 sha256 与提交 SHA 见控制面报告。
- 提交标题（单标题、无正文、无署名）：`docs(release): preserve signing and migration release gates`；SHA 事后回填。
