# Qt Android 基线出处与证据台账（T01）

> 归档说明（2026-11-19）：本文引用的 `.agents/` 目录已删除（含 227 个 worktree、控制面报告与日志）。文中的 `.agents/...` 路径仅作历史出处；控制面摘要、实测数字与残留材料见 `docs/flutter-migration/archive/2026-11-19-control-plane.md` 与 `docs/flutter-migration/archive/qt-flutter-state-2026-11-19.md`。

状态：**G1 CLOSED（artifact-level 证据链）**。出处基线可用；像素参考当前不可用，须由 T50 从同一 APK 重采。
fixture 与测试代码随 **T01-F01** 原子步骤落盘（字段契约见 §12）；本轮**未执行** `flutter test`，不得把“已编写”写成“已通过”。

- 任务：T01 Qt 基线出处与证据台账
- Owner：BASE
- 证据日期：2026-11-09（设备采集） / 2026-11-10（T01 只读复核）
- 计划：docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:386-395
- 设备原始记录：.agents/qt-plan-device-2026-11-09.md
- 机器可读副本：`test/fixtures/baseline_manifest.json`（T01-F01 落盘）
- 测试：`test/baseline_manifest_test.dart`（T01-F01 落盘；未执行）

## 1. 结论摘要

1. **G1 已闭合（artifact-level）。** APK 自身的原生 payload（`lib/arm64-v8a/libRhineMusicDatabase_arm64-v8a.so`）内嵌由 CMake 在配置期从 Git 生成的构建身份 `01ee85b96fee` 与提交标题；该条目与构建树 stripped 中间产物逐字节相同（`3f50afc0...`），二者字符串偏移一致。身份指向候选 commit `01ee85b96feeac875660e963ff78fbd383da0ae5`，其 `Qt` 树与基线 `8ed3067b...` 的 `Qt` 树相同。**这是产物级（E2）证据，不是签名级/CI 级证明**，边界见 §5.4、§14。
2. **Qt 源码同一。** `01ee85b96fee:Qt` 与 T01 实际基线 `8ed3067b0812eb2612f7841ec127a6e8ca93231b:Qt` 的 tree ID 完全相同（`12da26f0b9163592a9f6b69a2a0df4c806c12e0b`），`git diff --stat` 为空，且 `git log -1 -- Qt/` 正是候选 commit。当前工作树 `Qt/` 无未提交改动。
3. **APK 身份同一。** output 顶层唯一的 APK 为 `output/RhineMusicDatabase-01ee85b96fee-android-arm64-v8a-signed.apk`，SHA256 `bd58d95a5edee4c66a9704a108fb335163dc4274239b5f32b2a0c4cb221b5a1e`，大小 73,776,456 bytes；设备报告记录安装的是同一路径、同一 SHA256。
4. **证书全值可复核。** 从 APK 直接读出 Qt 证书：SHA256 `39396cd06f2b7980302bad220ed071e09286540be4d224a2f9b047ca65205bdf`，主体/签发者、序列号、有效期、3072-bit RSA、SHA384withRSA 均见 §4。该指纹与计划 §2.1 的声明值一致。证书身份已由 APK 直接证明；**keystore/别名/口令材料是否可用仍属 G8/T53**。
5. **像素基线不可用。** 12 张基准 PNG 的目录 `/tmp/rhine-qt-baseline-2026-11-09/` 在 2026-11-10 00:01 已不存在；全盘有界查找未找到 `01-consent.png` 或 `03-home-all-songs.png`。只剩设备报告中的索引（文件名、时间、字节数、SHA256 前 16 位），无完整哈希、无像素实体。T01 **不宣称**任何像素通过；T50 必须从同一 APK 重采。
6. **测试状态。** `test/fixtures/baseline_manifest.json` 与 `test/baseline_manifest_test.dart` 在 T01-F01 落盘；按用户禁令本轮不执行 `flutter test`/`dart analyze`/构建。计划中的 Pass 条件“`flutter test` 通过”因此**仍未被本任务验证**，执行留给获准的验证步骤；T01 的交付以本文件的只读复核、§12 的 fixture 字段契约与证据链为准；fixture 与测试文件本身随 T01-F01 落盘，未审未执行。

### 1.1 基线可用性裁决（明确二分）

| 维度 | 裁决 | 含义 |
|---|---|---|
| 出处/身份基线 | **USABLE** | APK、Qt commit、Qt tree、设备、安装记录、Manifest 可复核；可用于 T02-T07 的源码契约与后续同一 APK 重采 |
| G1 出处结论 | **CLOSED（artifact-level）** | 构建身份直接存在于 APK payload；证据等级为 E2 产物证据，不冒充签名/CI 证明；实测与边界见 §5.4、§14 |
| 像素参考基线 | **UNAVAILABLE_RECAPTURE_REQUIRED** | 12 张 PNG 实体丢失，且原覆盖仅 12 个局部横屏状态；不能做现有像素对照 |
| 像素验收结论 | **NOT_USABLE / 不得宣称通过** | 在 T50 从同一 APK、同一设备、同一状态脚本重采并建立新索引前，不得写“像素通过”或“1:1 完成” |

因此：**G1 闭合，P1 可以继续做源码/几何契约；T50 不得引用已丢失的 12 图作为像素证据；T01 不裁决 P1，也不宣称 T50 通过。**

## 2. 冻结坐标

| 项 | 值 | 证据 |
|---|---|---|
| 仓库 | `/home/aibeto/code/Rhine-Music-Database` | CMakeCache `CMAKE_HOME_DIRECTORY` |
| 主集成分支 | `feat/flutter` | 运行上下文 / 计划 §1.4 |
| 实际执行基线 | `8ed3067b0812eb2612f7841ec127a6e8ca93231b` | .agents/parity-20261109/scheduler.json `actualBaseline`；T01 worktree HEAD |
| 计划历史基线 | `89493eb3c3d2c1e6c050891718134ac7670e4d6c` | 计划 §1.4、§2.1；HEAD 祖先；仅作历史注记，不作为 APK 构建身份 |
| T01 工作树 | `.agents/parity-20261109/worktrees/T01` | INTEGRATE-001 创建；HEAD=8ed3067 |
| T01 分支 | `flutter/p0-t01-baseline` | worktree `git status -b` |
| 候选 Qt commit | `01ee85b96feeac875660e963ff78fbd383da0ae5` | 计划 §2.1；Git 对象存在 |
| 候选 commit 标题 | `feat: 新增双指平移手势处理逻辑` | `git log -1` |
| 候选 commit 时间 | `2026-11-07T05:39:43+08:00` | `git log -1 --format=%cI` |
| Qt tree（候选） | `12da26f0b9163592a9f6b69a2a0df4c806c12e0b` | `git rev-parse 01ee85b:Qt` |
| Qt tree（基线） | `12da26f0b9163592a9f6b69a2a0df4c806c12e0b` | `git rev-parse HEAD:Qt` |
| APK | `output/RhineMusicDatabase-01ee85b96fee-android-arm64-v8a-signed.apk` | output 顶层唯一 APK |
| APK SHA256 | `bd58d95a5edee4c66a9704a108fb335163dc4274239b5f32b2a0c4cb221b5a1e` | `sha256sum` |
| 设备 | serial `526f6b6d`，OPD2511，Android 16/API 36，arm64-v8a，density 315，2880×1800 | .agents/qt-plan-device-2026-11-09.md §1 |

**基线差异说明。** 计划 §1.4/§2.1 写的是历史起点 `89493eb3...`；执行时 scheduler 的实际基线是 `8ed3067b...`。二者关系是：`89493eb` 为 HEAD 祖先，`8ed3067` 是当前主集成工作树；`01ee85b` 也是 HEAD 祖先。T01 以实际工作树 `8ed3067` 为基线，同时保留计划的历史基线注记，避免把“计划写作时的 base”误当成“APK 构建 commit”。

## 3. APK 身份

| 项 | 值 |
|---|---|
| 路径 | `output/RhineMusicDatabase-01ee85b96fee-android-arm64-v8a-signed.apk` |
| 大小 | 73,776,456 bytes |
| mtime | `2026-11-07 21:30:29.884500248 +0800` |
| SHA256 | `bd58d95a5edee4c66a9704a108fb335163dc4274239b5f32b2a0c4cb221b5a1e` |
| package | `rhine.music.database`（merged manifest） |
| versionName | `0.0.0` |
| versionCode | `1`（实测；行为报告已同步为 1） |
| minSdk | `28` |
| targetSdk | `36` |
| ABI | `arm64-v8a` |
| output 顶层 APK 数 | 1 |

**证据纪律。** 文件名里的 `01ee85b96fee`、`-signed` 后缀、`versionName=0.0.0` 都**不是**构建对应关系的证明；它们只用于索引。真正的证明是 §5 的构建身份头和打包链。`-signed` 只表示构建脚本走了 release key 分支，不能单独证明 keystore/证书匹配（见 .agents/qt-plan-behavior-2026-11-09.md:52）。

## 4. 签名证书（APK 直接读出）

T01 在 2026-11-10 对上述 APK 执行只读命令：

```
keytool -printcert -jarfile output/RhineMusicDatabase-01ee85b96fee-android-arm64-v8a-signed.apk
```

输出归一化如下（保留原值）：

| 字段 | 值 |
|---|---|
| SHA256 | `39:39:6C:D0:6F:2B:79:80:30:2B:AD:22:0E:D0:71:E0:92:86:54:0B:E4:D2:24:A2:F9:B0:47:CA:65:20:5B:DF` |
| SHA256（小写无冒号） | `39396cd06f2b7980302bad220ed071e09286540be4d224a2f9b047ca65205bdf` |
| SHA1 | `27:D5:CA:30:9A:19:EF:15:44:48:94:12:D1:14:84:F5:49:E8:46:CA` |
| 主体（Owner） | `CN=Unknown, OU=Rhine-Music-Database, O=android, L=Unknown, ST=Unknown, C=CN` |
| 签发者（Issuer） | 同上（自签名） |
| 序列号 | `c72f9f0bf588afa3` |
| 生效时间 | `Fri Nov 06 17:49:09 CST 2026` |
| 失效时间 | `Sun Oct 13 17:49:09 CST 2126` |
| 签名算法 | `SHA384withRSA` |
| 公钥算法 | `3072 位 RSA` |
| 证书版本 | v3 |
| APK 内签名条目 | `META-INF/MYKEY.RSA`、`META-INF/MYKEY.SF`、`META-INF/MANIFEST.MF` |

**来源与边界。**

- 该指纹由 APK 的 JAR 签名块直接读出，不是用户口径，也不是从文件名反推；没有读取 `Rhine-Music-Database.key`、`.key.password.key` 或任何私钥/口令。
- 计划 §2.1 声明的 Qt 证书 SHA256 正是 `39396cd0...`；本结果与其一致。
- 旧 Flutter debug 证书 `7c514fe8cf95411117b6a4d1cba78768c1cda1d665c42f4828398d8587239dd4` 见 .agents/final-reports/apk-package-arm64.md:70，与本证书不同；不得把旧 Flutter 包当作 Qt 基线。
- **G8 仍未闭合**：证书身份已证明，但 T53 还要只读核对 keystore、别名、口令材料是否可用；不可用则停并提供迁移方案。
- `keytool` 只验证/打印证书，不执行 APK 安装、不构建、不跑测试。T01 没有执行 `apksigner verify`。

## 5. G1：APK 与 Qt commit 的构建出处

### 5.1 构建身份如何生成

候选 commit `01ee85b96feeac875660e963ff78fbd383da0ae5` 存在，标题为 `feat: 新增双指平移手势处理逻辑`，是 HEAD 的祖先。

CMake 在配置期从源码目录读取 Git：

- CMakeLists.txt:30-48：`find_package(Git QUIET)`，然后执行
  - `git log -1 --format=%h --abbrev=12`（WORKING_DIRECTORY=${CMAKE_CURRENT_SOURCE_DIR}）
  - `git -c i18n.logOutputEncoding=UTF-8 log -1 --format=%s`
- CMakeLists.txt:52：`configure_file(Qt/BuildIdentity.h.in "${CMAKE_CURRENT_BINARY_DIR}/BuildIdentity.h" @ONLY)`
- Qt/BuildIdentity.h.in 只有两个占位符：`RHINE_COMMIT_SHA`、`RHINE_COMMIT_TITLE`。

生成文件 `output/android-build/BuildIdentity.h`（204 bytes，mtime `2026-11-07 21:22:04.720795696 +0800`）内容：

```c
#pragma once

// 构建时从当前仓库读取，运行时不依赖 Git 或源码目录。
#define RHINE_COMMIT_SHA "01ee85b96fee"
#define RHINE_COMMIT_TITLE "feat: 新增双指平移手势处理逻辑"
```

该头被以下 Qt 源码使用：

- Qt/src/AndroidAssets.cpp:3 `#include "BuildIdentity.h"`；:35-38 用 `RHINE_VERSION`、`RHINE_COMMIT_SHA` 生成资源 stamp。
- Qt/src/AppUpdater.cpp:2 `#include "BuildIdentity.h"`；:66 返回 `RHINE_COMMIT_SHA`；:70 返回 `RHINE_COMMIT_TITLE`。

CMakeCache 记录构建源目录与配置：

- `CMAKE_HOME_DIRECTORY:INTERNAL=/home/aibeto/code/Rhine-Music-Database`
- `CMAKE_BUILD_TYPE:STRING=Release`
- `ANDROID_ABI:STRING=arm64-v8a`
- `ANDROID_PLATFORM:UNINITIALIZED=android-28`
- `QT_ANDROID_ABIS:STRING=arm64-v8a`

### 5.2 从构建头到 APK 的字节链

| 环节 | 文件 | 大小 | SHA256 | mtime |
|---|---|---:|---|---|
| 构建身份头 | `output/android-build/BuildIdentity.h` | 204 | — | 2026-11-07 21:22:04.720795696 +0800 |
| 最终未 strip 链接库 | `output/android-build/Qt/android-build/libs/arm64-v8a/libRhineMusicDatabase_arm64-v8a.so` | 149,401,128 | `7790160fccdd004efc8efe230adce582ddbd67420d1125bcb2782322de0f9def` | 2026-11-07 21:30:05.760465353 +0800 |
| stripped 中间产物 | `output/android-build/Qt/android-build/build/intermediates/stripped_native_libs/release/stripReleaseDebugSymbols/out/lib/arm64-v8a/libRhineMusicDatabase_arm64-v8a.so` | 41,535,456 | `3f50afc04508fac0d01647efb307efa73c6dc978fb71d79d85dd17f8967bf0cf` | 2026-11-07 21:30:13.222475921 +0800 |
| APK 内条目 | `lib/arm64-v8a/libRhineMusicDatabase_arm64-v8a.so` | 41,535,456 | `3f50afc04508fac0d01647efb307efa73c6dc978fb71d79d85dd17f8967bf0cf` | —（zip 条目，构建时打包） |
| APK | `output/RhineMusicDatabase-01ee85b96fee-android-arm64-v8a-signed.apk` | 73,776,456 | `bd58d95a5edee4c66a9704a108fb335163dc4274239b5f32b2a0c4cb221b5a1e` | 2026-11-07 21:30:29.884500248 +0800 |

关键证明：

1. 构建身份在**最终未 strip 的 `.so` 与 APK 内条目中都能直接读到，且偏移相同**：
   - `01ee85b96fee` UTF-8 offset `976021`；
   - `01ee85b96fee` UTF-16LE offset `1002496`；
   - `feat: 新增双指平移手势处理逻辑` UTF-16LE offset `1001900`（没有 UTF-8 副本；QStringLiteral 为 UTF-16）。
   - stripped 条目与未 strip 库偏移相同，符合 `strip` 只摘除尾部符号/调试节、不改 `.rodata` 布局的行为；因此“stripped 由该未 strip 库派生”不再只依赖 mtime 推断。
2. APK 内同名 `.so` 的 SHA256 与 stripped 中间产物**逐字节相同**（`3f50afc0...`），大小同为 41,535,456 bytes。
3. stripped 中间产物 mtime `21:30:13` 晚于最终链接 `.so` 的 `21:30:05`，早于 APK 的 `21:30:29`；三者位于同一构建树 `output/android-build/Qt/android-build/`。
4. APK 的 SHA256 与设备报告记录安装的 APK SHA256 相同；设备报告明确 `adb -s 526f6b6d install "<APK>"` 使用同一路径、同一 SHA256。
5. **直接性**：身份字符串是在 APK 内的 `.so` 自身命中的，不是从构建树旁证推得，因此“APK payload 携带该构建身份”是产物直读结论；它仍不能证明构建时 `Qt/` 工作树洁净（§5.4）。

### 5.3 Qt 源码同一性

在 T01 worktree 中：

```text
git rev-parse 01ee85b96feeac875660e963ff78fbd383da0ae5:Qt
# 12da26f0b9163592a9f6b69a2a0df4c806c12e0b
git rev-parse HEAD:Qt
# 12da26f0b9163592a9f6b69a2a0df4c806c12e0b
git diff --stat 01ee85b96feeac875660e963ff78fbd383da0ae5 HEAD -- Qt/
# （无输出）
git status --porcelain -- Qt/
# （无输出）
git log -1 --format='%H %cI %s' -- Qt/
# 01ee85b96feeac875660e963ff78fbd383da0ae5 2026-11-07T05:39:43+08:00 feat: 新增双指平移手势处理逻辑
```

这比“diff 为空”更强：两棵 Qt 树的 Git tree ID 完全相同；当前 `Qt/` 也没有未提交改动。候选 commit 是 HEAD 的祖先（`git merge-base --is-ancestor` 退出 0）。

### 5.4 G1 结论与边界

**结论：G1 CLOSED（artifact-level）。** 依据四条可复核事实：

1. APK 内 `lib/arm64-v8a/libRhineMusicDatabase_arm64-v8a.so` **自身**含构建身份 `01ee85b96fee`（UTF-8 @976021、UTF-16LE @1002496）与提交标题（UTF-16LE @1001900）；
2. 该条目与构建树 stripped 中间产物 SHA256 相同（`3f50afc0...`），且二者字符串偏移相同，符合 strip 摘尾不改 .rodata 的机制；
3. `BuildIdentity.h` 由 CMake 从 Git 生成（CMakeLists.txt:30-52），其值即上述身份；
4. 候选 commit 的 `Qt` tree ID 与基线 `8ed3067b...` 的 `Qt` tree ID 相同（`12da26f0...`），diff 为空，且候选 commit 是 HEAD 祖先；设备安装记录使用同一 APK SHA256。

**证据等级：E2（可复核产物）。** 计划 §2.3 对 G1 的要求是“只用构建记录/产物元数据/可复现参数判定 APK 是否对应该 commit，不得用 `-signed` 文件名、versionName 或‘应该一致’反推”。本结论满足该要求，且没有使用被禁止的推断。

**没有证明的部分（不得写成已证明）：**

- 没有外部 CI/构建服务器的完整命令行日志；证据来自构建树产物、CMake 生成头、文件哈希、字符串偏移与 mtime 链。
- **不能证明构建时 `Qt/` 工作树是洁净的。** 能证明的是：构建配置期仓库 HEAD 为候选 commit（身份串），以及**现在**候选 commit 的 `Qt` 树、基线 `Qt` 树与工作树 `Qt/` 三者相同。若构建当时 `Qt/` 有未提交改动，身份串仍会写出候选 commit。这是本结论的残余缺口，不做隐藏。
- 不能证明 APK 内每个资源/字体/Node 二进制都来自同一 commit；这属于更细的资源清单，不影响 Qt 源码身份结论，但 T50 重采时仍应使用同一 APK。
- 本结论不构成签名级证明：APK 签名只证明签名密钥，不证明源码 commit；`-signed` 后缀与 `versionName` 均未被当作证据。

## 6. Manifest 复核

### 6.1 源清单与 merged manifest

| 项 | 源清单 `Qt/android/AndroidManifest.xml` | 构建产物 merged manifest |
|---|---|---|
| package | :13 `org.qtproject.example`（占位） | :12 `rhine.music.database` |
| versionCode / versionName | :15-16 占位 | :14-15 `1` / `0.0.0` |
| minSdk / targetSdk | 由 Gradle 注入 | :18-19 `28` / `36` |
| GLES | :38 `uses-feature android:glEsVersion="0x00030000" android:required="true"` | :39 同值 |
| touchscreen | :40-43 `required="false"` | 保留 |
| allowBackup | :65 `false` | :67 `false` |
| resizeableActivity | :67 `false` | :74 `false` |
| screenOrientation（ConsentActivity） | :89 `sensorLandscape` | :97 `sensorLandscape` |
| screenOrientation（QtActivity） | :103 `sensorLandscape` | :111 `sensorLandscape` |
| launcher | :84-94 ConsentActivity（:87 exported=true，:94 LAUNCHER，唯一） | 保留 |
| QtActivity | :102 launchMode=singleTop；:103 screenOrientation=sensorLandscape；:104 exported=false | 保留 |
| 前台服务 | :146 `foregroundServiceType="mediaPlayback"` | 保留 |
| 权限 | :20 INTERNET、:21 ACCESS_NETWORK_STATE、:28 FOREGROUND_SERVICE、:29-31 FOREGROUND_SERVICE_MEDIA_PLAYBACK、:32 POST_NOTIFICATIONS | 保留 |
| 其他 | :64 `enableOnBackInvokedCallback="true"`；:66 `usesCleartextTraffic="true"` | 保留 |

merged manifest 路径：

`output/android-build/Qt/android-build/build/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml`

### 6.2 四项必核

- **sensorLandscape**：两个 Activity 都是 `sensorLandscape`；不是 `landscape`，也不是 `unspecified`。
- **allowBackup=false**：源与 merged 都是 false；不得承诺 `adb backup` 私有备份可用。
- **resizeableActivity=false**：源与 merged 都是 false；与“仅横屏舞台”一致。
- **GLES3**：`glEsVersion="0x00030000"`，`required="true"`；不是 2.0，也不是可选。

**注意。** 源清单的 package/version 是占位；判断 APK 身份必须用 merged manifest 与 APK 实际值。Manifest 只能证明声明，不能证明运行时所有窗口都保持横屏；设备证据见 §7 与 evidence/device-2026-11-09.md。

## 7. 安装、启动与设备状态（E0）

完整原始记录：.agents/qt-plan-device-2026-11-09.md；归一化副本：docs/flutter-migration/evidence/device-2026-11-09.md。

| 项 | 值 |
|---|---|
| serial | `526f6b6d` |
| 型号 | OPD2511 |
| Android | 16 / API 36 |
| ABI | arm64-v8a |
| density | 315 |
| 物理分辨率 | 2880×1800 |
| fingerprint | `OPPO/OPD2511/OP6546L1:16/BP2A.250605.015/B.4a2d817-2503cdb-254d651:user/release-keys` |
| 安装前包 | 不存在：`pm path` 退出 1 无输出；`resolve-activity` 返回 `No activity found` |
| 安装方式 | `adb -s 526f6b6d install "<APK>"`；`Performing Incremental Install`；`Success`；`11169 ms` |
| 卸载/清数据 | 本轮未执行（设备报告 §7 预算与文字均记录） |
| 安装后路径 | `package:/data/app/~~VVe9833Tp2YUQpcayb_B0w==/rhine.music.database-8FcIEsrc2Qf4r5C1wmaoZA==/base.apk` |
| versionName / versionCode | `0.0.0` / `1` |
| minSdk / targetSdk | `28` / `36` |
| firstInstallTime / lastUpdateTime | `2026-11-09 16:28:32`（两者相同） |
| launcher | `rhine.music.database/.ConsentActivity` |
| 冷启动 | `TotalTime 544` / `WaitTime 599`（单次 E0 样本，不是性能门） |
| 隐私同意 | 用户 16:53 手动点击，非采集者代点 |
| 同意后 top activity | `org.qtproject.qt.android.bindings.QtActivity` |
| 返回键 | Android 返回键直接退出 APP；无应用内返回栈；应用内返回靠面板 `← 返回` |

**无障碍。** `uiautomator dump` 只暴露 11 个有标签节点：返回/歌曲/专辑/歌单/歌手/上一首/播放/下一首/列表循环/播放队列/搜索 EditText。顶部导航、底栏词/音量/心形、主区标题计数未暴露。不能把这 11 个节点当成完整语义树。

**预算。** install 1、`am start` 3、`input tap` 13、`keyevent` 4、`input text` 1（22 次交互）；`screencap` 13；无滚动、长按、多点触控；无卸载/清数据/登录/收藏。

## 8. 12 图索引、覆盖与实体丢失

### 8.1 索引（原始记录，非本轮截图）

原始目录 `/tmp/rhine-qt-baseline-2026-11-09/` 已不存在。下表来自 .agents/qt-plan-device-2026-11-09.md §8；**只有 SHA256 前 16 位**，没有完整哈希，也没有像素文件。

| # | 文件 | 采集时间 | 字节 | SHA256 前 16 |
|---|---|---|---:|---|
| 01 | `01-consent.png` | 2026-11-09 16:31:45 | 326,988 | `425d7c7c890ee7ab` |
| 02 | `02-consent-relaunch.png` | 2026-11-09 16:39:11 | 325,005 | `7a5e6f38f8bd1de0` |
| 03 | `03-home-all-songs.png` | 2026-11-09 17:02:12 | 2,308,837 | `820737b3deb4824f` |
| 04 | `04-search.png` | 2026-11-09 17:09:47 | 1,719,597 | `deebd279a69bce6b` |
| 05 | `05-search-restored.png` | 2026-11-09 17:19:59 | 1,708,373 | `2b61ebdc1323bf30` |
| 06 | `06-settings.png` | 2026-11-09 17:21:58 | 805,298 | `4aca0c49e9899078` |
| 07 | `07-platform.png` | 2026-11-09 17:23:12 | 838,956 | `04a2e15a3716201e` |
| 08 | `08-queue.png` | 2026-11-09 17:24:31 | 765,047 | `083020ab22768018` |
| 09 | `09-library.png` | 2026-11-09 17:26:34 | 2,315,575 | `7e0f673f85665b9a` |
| 10 | `10-library-track17.png` | 2026-11-09 17:28:42 | 2,318,252 | `e02fcff7ce30b8cc` |
| 11 | `11-song-detail.png` | 2026-11-09 17:30:55 | 1,098,093 | `4e56235b00e25a01` |
| 12 | `12-search-results.png` | 2026-11-09 17:35:02 | 1,492,312 | `553963e921ea19ed` |

采集共执行 13 次 `screencap`，留存 12 张；1 张误退桌面图已删、未查看。设备报告没有记录 12 张图的完整 SHA256，T01 也没有原始 PNG，因此**不能补算完整哈希**。

### 8.2 覆盖与不能证明

| 图 | 覆盖 | 不能证明 |
|---|---|---|
| 01/02 | 隐私门槛、退出后重启复现 | 没有“拒绝后继续”入口；不能证明拒绝路径 |
| 03 | 首页/全部歌曲、3D 墙、底栏 | 播放、登录、其他 lane |
| 04 | 搜索空查询、四标签、IME | 搜索命中、排序、中文输入正确 |
| 05 | 同安装重复启动恢复搜索页 | process-death 冷启动恢复 |
| 06 | 设置首屏 5 项 | 第 6 项以后、展开项、保存失败 |
| 07 | 四平台卡、未登录态 | 登录后个人音乐/发现 |
| 08 | 空队列、四种播放模式 | 有队列、拖动、删除 |
| 09/10 | 资料库层级、曲目列、17/933 | “查看歌单详情”独立页（未出现） |
| 11 | 歌曲档案、3D 封面 DRAG TO INSPECT、动作 | 播放、喜欢、加入歌单/队列 |
| 12 | 搜索空态、喜欢歌曲文案 | 结果命中（输入实际显示 `cesseary`，不是 `Necessary`） |

**未覆盖：** 我的音乐/发现、登录后状态、播放中、Tab Mode、设置后续项、弹层展开/关闭、错误/加载态、竖屏。以上不能由源码、QML 预览或桌面离屏图替代为“真机已对齐”。

### 8.3 实体丢失（2026-11-10 复核）

- `/tmp/rhine-qt-baseline-2026-11-09/` 不存在。
- `find /tmp /home/aibeto -maxdepth 8 \( -name 01-consent.png -o -name 03-home-all-songs.png \)` 无结果。
- 因此：12 图只能作为**索引**，不能作为像素比较输入；T50 必须从同一 APK 重新采集并建立包含完整 SHA256、尺寸、状态脚本、设备 fingerprint 的新索引。
- 这不是“像素比较失败”，而是“像素证据实体不可用”；不能写成通过，也不能写成功能失败。

## 9. G1-G8 状态

| 缺口 | 状态 | 说明 / 归属 |
|---|---|---|
| G1 APK 与 Qt 源码同 commit | **CLOSED（artifact-level，T01）** | §5 构建身份 + stripped/APK 字节链 + Qt tree 同一 + 设备同 SHA；证据等级 E2，残余缺口见 §5.4 |
| G2 业务页仅 12 张局部横屏 | **OPEN** | 原 12 图实体丢失；播放/登录/竖屏/设置后续/Tab Mode 未覆盖；T50/T51 补采与逐页降级 |
| G3 Qt 无竖屏规范 | **OPEN** | 竖屏只能称新增重排；T02 定义几何，T43/T51 样板与 golden |
| G4 设置七区逐项可见性未全量 | **OPEN** | T06 全量 inventory，T37 实现 |
| G5 存储逐键 schema/损坏回退未全量 | **OPEN** | T07 逐文件/逐键冻结，T26 实现 |
| G6 登录后个人音乐/发现无真机画面 | **OPEN** | T36/T38 源码规格 + 账号 mock；T50 标“视觉未取证” |
| G7 Android 内嵌 Node 的 Flutter 生命周期未验证 | **OPEN** | T21 spike；失败改用上游策略，不删功能 |
| G8 签名材料可用性未核对 | **OPEN** | 证书身份已由 APK 证明；keystore/别名/口令材料仍由 T53 只读核对 |

**G1 闭合不关闭 G2-G8。** 基线出处可用，不等于像素、竖屏、设置、存储、登录、Node、签名材料都已验收。

## 10. 对下游的约束

1. **T02-T07 可以按源码编写契约**，但必须引用本文件的 APK/commit/tree 坐标；不得把旧 Flutter 产物或 912 行旧计划当规范。
2. **T50 像素对照**必须使用 APK SHA256 `bd58d95a...`、设备 serial `526f6b6d`、同一状态脚本；重采前不得引用已丢失的 12 图。
3. **T51 竖屏**只能称“新增重排”，不得称“1:1 复刻”；Qt 没有竖屏基线。
4. **T53/G8** 仍需只读核对 keystore/别名/口令材料；本文件只证明 APK 证书身份，不证明签名材料可再次使用。
5. **不可变契约**（17 条 flat HUD 数组、commands/hits/frame 同代且不重排不去重、六登录路径与六阶段、七设置区、Node 单例/token/48MiB/30s/8MiB 栈、Qt session/QSettings/AppStorage/凭据兼容、播放歌词队列搜索返回 IME 通知恢复）由对应 T03/T05/T06/T07 等任务冻结；T01 只提供基线出处，不在此重新定义或放宽。
6. **测试**：`test/baseline_manifest_test.dart` 属 T01-F01 原子步骤（字段契约见 §12）；该文件与 `test/fixtures/baseline_manifest.json` 尚未落盘（随 T01-F01 落盘），本轮不审查、不执行，T01 不声称 `flutter test` 通过。

## 11. 复现命令（只读）

以下命令是 T01 实际做过的只读检查，不包含构建、测试、analyze、adb 或设备操作：

```bash
# APK 身份
sha256sum output/RhineMusicDatabase-01ee85b96fee-android-arm64-v8a-signed.apk
stat -c '%n %s %y' output/RhineMusicDatabase-01ee85b96fee-android-arm64-v8a-signed.apk

# 证书（只读，不读私钥/口令）
keytool -printcert -jarfile output/RhineMusicDatabase-01ee85b96fee-android-arm64-v8a-signed.apk

# 构建身份
sed -n '1,20p' output/android-build/BuildIdentity.h

# Qt 源码同一性（在 T01 worktree 内）
git rev-parse 01ee85b96feeac875660e963ff78fbd383da0ae5:Qt HEAD:Qt
git diff --stat 01ee85b96feeac875660e963ff78fbd383da0ae5 HEAD -- Qt/
git status --porcelain -- Qt/

# APK 内 native lib 与 stripped 中间产物哈希
python3 - <<'PY'
import hashlib, zipfile
apk = 'output/RhineMusicDatabase-01ee85b96fee-android-arm64-v8a-signed.apk'
entry = 'lib/arm64-v8a/libRhineMusicDatabase_arm64-v8a.so'
data = zipfile.ZipFile(apk).read(entry)
print(len(data), hashlib.sha256(data).hexdigest())
PY
sha256sum output/android-build/Qt/android-build/build/intermediates/stripped_native_libs/release/stripReleaseDebugSymbols/out/lib/arm64-v8a/libRhineMusicDatabase_arm64-v8a.so
```

## 12. fixture 与测试字段契约

`test/fixtures/baseline_manifest.json` 与 `test/baseline_manifest_test.dart` 在 T01-F01 原子步骤落盘；本节先固定它们必须固化的字段与断言，避免后续改动漂移。本节不是“已存在”的声明。

### 12.1 fixture 顶层键

| 键 | 必须包含 |
|---|---|
| `schemaVersion` / `task` / `generatedAt` | `1` / `"T01"` / 生成日期 |
| `repo` / `worktree` / `branch` | 冻结坐标 |
| `baselineCommit` / `planHistoricalBaseline` | `8ed3067b...` / `89493eb3...`（后者仅历史注记，不作为当前基线） |
| `apk` | `path`、`sizeBytes`、`mtime`、`sha256`、`package`、`versionName`、`versionCode`、`minSdk`、`targetSdk`、`abi`、`topLevelApkCount` |
| `certificate` | `sha256`、`sha256Compact`、`sha1`、`owner`、`issuer`、`serialNumber`、`validFrom`、`validTo`、`signatureAlgorithm`、`publicKey`、`signatureEntries`、`source` |
| `qtSource` | `candidateCommit`、`candidateCommitTitle`、`candidateCommitTime`、`qtTreeCandidate`、`qtTreeBaseline`、`diffStatLines`、`isAncestorOfBaseline` |
| `buildIdentity` | `headerPath`、`headerBytes`、`commitSha`、`commitTitle`、`stringsInPayload.{utf8ShaOffset,utf16ShaOffset,utf16TitleOffset}` |
| `nativeChain` | 三段，`stage` ∈ `linked-unstripped`/`stripped-intermediate`/`apk-entry`，各带 `path`、`sizeBytes`、`sha256` |
| `manifest` | `sourcePath`、`mergedPath`、`screenOrientation`、`allowBackup`、`resizeableActivity`、`glesVersion`、`glesRequired` |
| `device` | `serial`、`model`、`androidVersion`、`apiLevel`、`abi`、`density`、`physicalResolution`、`fingerprint` |
| `installation` | `preinstallPackageAbsent`、`command`、`incremental`、`success`、`durationMs`、`uninstallPerformed`、`clearDataPerformed`、`firstInstallTime`、`lastUpdateTime`、`packagePathAfterInstall` |
| `screenshots` | `indexAvailable`、`entitiesAvailable`、`originalDirectory`、`entityStatus`、`fullHashAvailable`、`items[12]`（`id`、`file`、`capturedAt`、`bytes`、`sha256Prefix16`） |
| `gaps` | `G1`…`G8`，每项 `status`；G1 另带 `scope` |
| `pixelBaseline` | `status` |
| `testExecution` | `performed` 与原因 |

### 12.2 测试断言

- 顶层 `schemaVersion == 1`、`task == "T01"`；必填字符串非空（APK 路径/哈希、证书全值、设备 serial、安装命令）。
- `apk.sha256`、`certificate.sha256Compact`、`nativeChain[*].sha256` 均为 64 位小写十六进制；`buildIdentity.commitSha` 为 12 位十六进制。
- `apk.versionCode >= 1`；`minSdk`/`targetSdk` 为整数且 `targetSdk >= minSdk`。
- Manifest 四项精确匹配：`sensorLandscape`、`false`、`false`、`0x00030000`。
- 安装事实：安装前包不存在、未卸载、未清数据、增量安装成功。
- 12 图索引长度恰为 12，每项 `bytes > 0`、`sha256Prefix16` 为 16 位十六进制。
- `screenshots.entitiesAvailable == false`；`pixelBaseline.status == "unavailable_recapture_required"`。
- `gaps.G1.status == "closed"` 且 `scope == "artifact-level"`；`G2`…`G8` 均存在；本 fixture 中 `closed` 数量恰为 1（若后续任务要改任何 gap 状态，必须显式改 fixture 与本文件，让测试失败暴露契约变更）。
- `nativeChain` 的 `stripped-intermediate` 与 `apk-entry` 的 `sha256` 相同、`sizeBytes` 相同。

### 12.3 未执行

本轮禁止运行 `flutter test`、`dart analyze` 或任何构建；`test/baseline_manifest_test.dart` 与 `test/fixtures/baseline_manifest.json` 尚未落盘（随 T01-F01 落盘），本轮不对其做任何执行或静态审查。执行命令留给获准的验证步骤：

```bash
flutter test test/baseline_manifest_test.dart
```

## 13. 引用

- 计划：docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:386-395（T01）；:72-82（设备/APK 基线）；:84-99（12 图覆盖）；:101-114（G1-G8）；:116-125（逻辑/物理/舞台）。
- 设备原始记录：.agents/qt-plan-device-2026-11-09.md（安装、Manifest、12 图索引、预算、未覆盖）。
- 构建脚本：scripts/build-android.cjs:24、:249-258、:385-409、:419-455、:478。
- CMake：CMakeLists.txt:6-16、:30-52。
- 构建头模板：Qt/BuildIdentity.h.in。
- 构建头产物：output/android-build/BuildIdentity.h。
- merged manifest：output/android-build/Qt/android-build/build/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml。
- 源 Manifest：Qt/android/AndroidManifest.xml。
- 证书来源：keytool 对 APK 的只读输出（本文件 §4）。
- 旧 Flutter 证书：.agents/final-reports/apk-package-arm64.md:70（仅用于说明二者不同）。
- 行为报告：.agents/qt-plan-behavior-2026-11-09.md:52（`-signed` 不等于证书匹配的纪律来源）。
- 既有分歧记录：.agents/parity-20261109/reports/GRAPH-001.json:6223（认为 G1 仅为 artifact-level、非 signature-level，故"不闭合"）；本文件的裁决口径见 §14.2。
- 独立复核报告：.agents/parity-20261109/reports/T01-V2-R01.json（T01-C01 只读 reviewer）；.agents/parity-20261109/reports/T01-V2-R02.json（T01-F01 只读 reviewer）。

## 14. V2 静态复核（只读；无构建/测试/adb）

复核时间 2026-11-10 00:34–00:42 +0800。全部命令只读：`sha256sum`、`stat`、`keytool -printcert -jarfile`、`python3` 读 zip 条目/字节搜索、`git rev-parse/diff/merge-base`、`grep -n`。未构建、未运行测试、未 analyze、未 adb、未安装、未截图。

### 14.1 实测输出

| 检查 | 命令 | 实测结果 |
|---|---|---|
| APK 大小/mtime | `stat -c '%s %y'` | `73,776,456` / `2026-11-07 21:30:29.884500248 +0800` |
| APK SHA256 | `sha256sum` | `bd58d95a5edee4c66a9704a108fb335163dc4274239b5f32b2a0c4cb221b5a1e` |
| `output` 顶层 APK 数 | `ls output/*.apk` | 1（无第二个候选 APK） |
| 构建身份头 | `cat output/android-build/BuildIdentity.h` | `RHINE_COMMIT_SHA "01ee85b96fee"`；标题 `feat: 新增双指平移手势处理逻辑` |
| 未 strip 库 | `sha256sum` | `7790160f...` / 149,401,128 B |
| stripped 中间产物 | `sha256sum` | `3f50afc0...` / 41,535,456 B |
| APK 内同名条目 | `zipfile` 读取 | `3f50afc0...` / 41,535,456 B（与 stripped 逐字节相同） |
| APK 条目含身份串 | 字节搜索 | UTF-8 `01ee85b96fee` @976021（1 次）、UTF-16LE @1002496（1 次）、标题 UTF-16LE @1001900（1 次） |
| 偏移一致性 | 与未 strip 库对比 | 三个偏移完全相同；UTF-8 标题副本 0 次（QStringLiteral 为 UTF-16） |
| APK 签名条目 | `zipfile` 列表 | `META-INF/MYKEY.SF`、`META-INF/MYKEY.RSA`、`META-INF/MANIFEST.MF` |
| 候选 commit Qt 树 | `git rev-parse <commit>:Qt` | `12da26f0b9163592a9f6b69a2a0df4c806c12e0b` |
| 基线 HEAD Qt 树 | `git rev-parse HEAD:Qt` | `12da26f0b9163592a9f6b69a2a0df4c806c12e0b`（相同） |
| Qt 差异 | `git diff --stat <commit> HEAD -- Qt/` | 0 行 |
| 祖先关系 | `git merge-base --is-ancestor` | 退出码 0 |
| 源 Manifest 关键行 | `grep -n` | 见 §6.1；权限行号已按实测修正为 `:20`、`:21`、`:28`、`:29-31`、`:32` |

### 14.2 与 GRAPH-001 的分歧

`.agents/parity-20261109/reports/GRAPH-001.json:6223` 记录：`G1 provenance improved but not closed: output/android-build/BuildIdentity.h says 01ee85b96fee, the APK lib embeds the same string, both mtime-consistent with the 2026-11-07 21:30 APK; still artifact-level evidence, not signature-level proof`。

分歧点是**证据等级口径**，不是事实冲突——双方对事实的描述一致，都承认是产物级证据。本文件的裁决：计划 §2.3 对 G1 的要求是"只用构建记录/产物元数据/可复现参数判定 APK 是否对应该 commit"，产物级证据满足该要求且未使用被禁止的推断，故记为 CLOSED（artifact-level）；GRAPH-001 的口径是"非签名级证明即不闭合"。本文件同时明确：不把 artifact-level 升级成签名级/CI 级证明，残余缺口（构建时 `Qt/` 是否洁净）如实保留于 §5.4。

### 14.3 独立复核

T01-C01 的独立只读 reviewer 将复核 §5 构建身份链、§6 Manifest 四项、§8 12 图索引与实体丢失、§9 G1-G8 状态、以及本节实测输出。上一轮独立审查（`.agents/parity-20261109/reports/T01-V2-R01.json`）结论为 **PASS_WITH_FIXES**（1 项 must-fix + 4 项表述问题），**尚未 PASS**；该报告的 must-fix 与表述问题在本轮逐条修正。**本文件不自行宣称审查通过**：本轮结论以独立 reviewer 的复核报告为准；若结论为 BLOCKED，则 G1 改记 DEVICE_BLOCKED 并停止后续。

