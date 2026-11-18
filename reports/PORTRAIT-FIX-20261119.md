# PORTRAIT-FIX-20261119 — 竖屏曲目列被播放条吞掉

> 分支 `feat/portrait-fix`（worktree `.agents/parity-20261109/worktrees/PORTRAIT-FIX-20261119`，基线 `ea15a94`，与 `feat/flutter` 同内容）
> 设备 OPD2511（`adb -s 526f6b6d`，SDK 36），物理 1800×2880，density override 378 → dpr 2.3625（逻辑 762×1219 dp）
> 截图与哈希见 §8，APK/装机/设备状态见 §9

---

## 1. 结论

竖屏下**不是 3D 场景错了、也不是方向没转**，是 HUD 曲目列（ruler 列表块）在搬进第二带时整体平移了 `basicPortraitListOffset = 1080` 个舞台单位，**多平移了一个 219 单位（=509−290）的表头空档**：ruler 的裁剪/命中窗口上沿本来就坐在 219，平移 1080 之后落到 1299，而可用带只有 1080..1632（552 单位）——610 高的窗口有 4 行掉进播放条下面、带顶还空出 219。

修法：把「平移量」改成 `1080 − 219 = 861`，让窗口上沿正好压在带顶 1080；命中矩形同源改成同一个换算。改后竖屏可见行 1 → 4 行（+1 行露上沿），横屏逐像素回归 diff = 0.103（无变化）。

---

## 2. 复现步骤（一条不漏）

```bash
PKG=rhine.music.database
LOCK=/tmp/rhine-device-526f6b6d.lock

# 0) 固定为竖屏（关自动旋转，user_rotation=0）
( exec 9>$LOCK; flock -w 600 9
  adb -s 526f6b6d shell settings put system accelerometer_rotation 0
  adb -s 526f6b6d shell settings put system user_rotation 0 ) || exit 3

# 1) 冷启动并计时
( exec 9>$LOCK; flock -w 600 9
  adb -s 526f6b6d shell am force-stop $PKG
  adb -s 526f6b6d shell am start -W -n $PKG/.MainActivity )

# 2) 截图（修前：builds/PORTRAIT-FIX-20261119/01-portrait-coldstart.png）
( exec 9>$LOCK; flock -w 600 9
  adb -s 526f6b6d exec-out screencap -p > /tmp/portrait.png )
```

复现现象（修前 APK `…/app-debug.apk` 上一版，`lastUpdateTime 2026-11-18 18:30:59`）：

- 3D 场景正常铺满顶部正方形（0..1800 × 0..1800 px），**但下面 1080 px 高的列表带除了一条竖线的刻度，只有一行字**紧贴播放条（y 2658..2707），带顶 1800..2657 纯黑。
- 在列表区上下滑能滑出曲目（`10/11-portrait-*`），说明**列表在画、也在命中**，只是锚点太低、可视行全被播放条压住。

---

## 3. 数字取证（修前）

### 3.1 坐标换算链（全部可重算）

| 量 | 公式 | 值 |
| --- | --- | --- |
| dpr | `density/160 = 378/160` | 2.3625 |
| 逻辑竖屏 | `1800/2.3625 × 2880/2.3625` | 762 × 1219 dp |
| stageScale（px / 舞台单位） | `physicalWidth / stageWidth = 1800/1080` | 1.6666667 |
| stageHeight | `2880 / stageScale` | **1728** |
| 第二带顶 | `basicPortraitListOffset` | 1080（=1800 px） |
| 播放条上沿 | `stageHeight − playerBarRowHeight = 1728 − 96` | **1632**（=2720 px） |
| 可用带高 | `1632 − 1080` | 552 单位 |
| ruler 窗口 | `[titleY−290, titleY+320]`，高 610 | 比可用带高 58 |

### 3.2 像素实测（`01-portrait-coldstart.png`，1800×2880）

| 区域（物理 px） | 实测 | 换算到舞台 | 期望 |
| --- | --- | --- | --- |
| 3D 方块 | x 0..1800, y 0..1800 | 0..1080 × 0..1080 | 1080×1080 带（`basicSceneStageRect`）✅ |
| 列表带空白 | y 1800..2657 纯黑（max 像素=0） | 1080..1594 | 应填 4 行曲目 ❌ |
| 竖线（ruler 刻度） | x 1533..1535, y 2225..2649 | x 920, y 1335..1589 | `x=width−160=920`、`centerY−272` ✅ 位置对 |
| 选中行文字 | y 2658..2707 | 1595..1624 | 窗口内、但只看得到这一行 ❌ |
| 播放条 | y 2720..2850 | 1632..1710 | `stageHeight−96 = 1632` ✅ |

**修前可见曲目行 = 1 行**（选中行），且它压在播放条上沿。

### 3.3 为什么只有一行（算术）

- ruler 窗口上沿 = `titleY − 290 = 219`，竖屏平移 1080 → 窗口落在 **1299..1909**。
- 选中行 `titleY = 1080 + 509 = 1589`（px 2648，实测文字墨迹 2658 起，差值是字体 ascender 内边距）。
- 下一行 `+88 → 1677`、再下一行 `+140 → 1729`：**1677 已经在播放条（1632）下面，1729 直接越过 stageHeight 1728**。
- 反方向：选区之前没有行（`selected=0`），所以 1080..1299 那段 219 是空的 —— 于是整条带只剩一行。

### 3.4 排除项（不是这些原因）

| 怀疑项 | 证据 | 结论 |
| --- | --- | --- |
| 被强制成横屏 | `wm size` 1800×2880、`user_rotation=0`、SF 全窗 1800×2880 | 否，确实是竖屏 |
| HUD 缩放错（stageScale 变成竖屏专用值） | 竖屏标题左沿 x=98 vs 横屏 99，两侧同为 1.6667 | 否，尺度一致 |
| 3D 场景被裁/被拉伸 | 3D 方块实测 1800×1800 = 1080×1080 舞台 @1.6667，与 `basicSceneStageRect` 一致；SF 中除全窗 BLAST SurfaceView（1800×2880）外没有尺寸异常的场景 layer | 否（截图像素比对 3D 内容不可靠：最优 s=0.92、mean diff 22.65 的相机/动画底噪） |
| 横屏被改动 | 见 §7.3，diff 0.103 | 否 |

---

## 4. 根因

矛盾点在「列表块整体平移」和「ruler 自己的窗口原点不是 0」这两处口径不一致。

**修前** `lib/basic/basic_hud.dart:287`（HEAD `ea15a94`）：

```dart
if (!singleItemForm) sink.shifted(0, basicPortraitListOffset, drawList);
```

**修前** `lib/hud/widgets/track_ruler.dart:267,283`：

```dart
const titleY = 509.0;
…
sink.op(<Object?>['clip', x - 4, titleY - 290, width - x, 610]);
```

也就是说：ruler 把内容画在以「窗口原点 y=219」为基线的坐标系里（`titleY=509` 绝对定位），而 `shifted` 是给**整块**加 1080。于是窗口上沿 = 219+1080 = 1299，而不是注释里说的 1080（`basic_hud.dart:34`「曲目列从 1080 设计高度之后开始」）；命中矩形 `basicLibraryListStageRect` 的 `509 - 290 + 1080 = 1299`（`basic_hud.dart:457`）忠实复制了同一个错误 —— 所以「看得见的行」和「点得中的行」是一致的，只是整体低了一个表头空档，并且把 610 高的窗口越出可用带 552 的部分交给播放条/舞台底边裁掉。

竖屏 stage 高度只有 1728（`basicSceneStageRect` 4:3 方块占 1080），带高只有 552，这个 219 的偏差正好等于「少 4 行」。

---

## 5. 修复（只改 Dart，未碰 Qt/C++）

### 5.1 `lib/hud/widgets/track_ruler.dart`（+16 / −2）

把 ruler 窗口的三个真正值提成常量（Qt `NativeHud.cpp:543-555` 的 509/290/610 原本散在函数体里、被 `basic_hud.dart` 手抄一遍）：

```dart
const double trackRulerTitleY = 509.0;
const double trackRulerWindowTopOffset = 290.0;
const double trackRulerWindowHeight = 610.0;

/// 窗口上沿相对列表块原点的 y（= 219）。竖屏把窗口上沿对齐到带顶时用它换算。
const double trackRulerWindowTop = trackRulerTitleY - trackRulerWindowTopOffset;
```

`archiveTrackList` 里 `const titleY = 509.0;` → `const titleY = trackRulerTitleY;`，clip 改成 `titleY - trackRulerWindowTopOffset` / `trackRulerWindowHeight`（**数值不变**，`test/hud/t33/track_ruler_test.dart:189` 的 `['clip', 1131-4, 509-290, 1920-1131, 610]` 断言依旧成立）。

### 5.2 `lib/basic/basic_hud.dart`（+20 / −7）

新增唯一的换算常量，并让绘制与命中都用它：

```dart
/// 竖屏列表块的位移（stage unit）：让 ruler 裁剪窗口的上沿
/// （[ruler.trackRulerWindowTop] = 219）正好落在 [basicPortraitListOffset] 那条带顶线上，
/// 也就是「曲目列从 1080 开始」这句注释的字面含义。
const double basicPortraitListShift =
    basicPortraitListOffset - ruler.trackRulerWindowTop;   // = 861
```

- `:298` 绘制：`sink.shifted(0, basicPortraitListShift, drawList)`（原来 `basicPortraitListOffset`）。
- `:464-474` 命中：`basicLibraryListStageRect` 的 y 由 `509 - 290 + (portrait ? 1080 : 0)` 改成
  `portrait ? basicPortraitListOffset : ruler.trackRulerWindowTop`，高用 `ruler.trackRulerWindowHeight`
  —— 竖屏 = `Rect(291, 1080, 789, 610)`（与绘制平移同一换算），横屏 = `Rect(291, 219, 789, 610)`（与旧值逐位等价）。
- 文档注释同步改写（`basic_hud.dart:37-46`、`:424-436`、`:458-463`），把「1080 是带顶、不是平移量」写死。

### 5.3 测试同步（不新增用例，只改被修行为影响的断言）

| 文件 | 改动 |
| --- | --- |
| `test/basic/interaction_134_native_test.dart:586` | `expect(list.top, basicPortraitListOffset)`（原断言 1299），注释里窗口 1299..1909 → 1080..1690 |
| `test/basic/portrait_hud_142_test.dart:246-247` | 注释改「列表窗口上沿对齐带顶：舞台 y=1080..1690」；拖动起点 `Offset(700,1700)` → `Offset(700,1400)`（移进新窗口） |
| `test/basic/portrait_hud_142_test.dart:301-302` | 点击点 `(600,1200)` → `(600,933)`（=舞台 900,1400，仍在第二带内） |

---

## 6. 修复后（真机，同机同密度）

冷启动 pid **19098**，COLD TotalTime 2264 ms → `20-portrait-fixed.png`

| 区域（物理 px） | 修前 | 修后 | 换算到舞台 |
| --- | --- | --- | --- |
| 列表带空白 | 1800..2657 | **1800..1859** | 1080..1116 |
| 第 1 行（选中 `Systematic Violation`） | 2658..2707 | 2293..2342 | 1376..1405 |
| 第 2 行 `Ens Inexorable` | 无 | 2440..2479 | 1464..1487 |
| 第 3 行 `Kernel Overflow` | 无 | 2528..2565 | 1517..1539 |
| 第 4 行 `Тонкий счер (Instrumental)` | 无 | 2615..2655 | 1569..1593 |
| 第 5 行（露上沿，被播放条切） | 无 | 2701..2719 | 1621..1631（播放条 1632 起） |
| 播放条 | 2746..2850 | 2746..2850 | 1632..1710 |

**可见行 1 → 4 行（+1 行露上沿），带顶空档 514 单位 → 21 单位。**

与 §3.3 的算术完全对得上：`861+509=1370`（px 2283，墨迹 2293）→ `+88=1458`（2430→2440）→ `+140=1510`（2517→2528）→ `+192=1562`（2603→2615）→ `+244=1614`（2690→2701）。

### 6.1 交互（命中与绘制同源，无错位）

- `21-portrait-tap-row.png`：点物理 (700,2460) = 舞台 (420,1476) → 选中 `Ens Inexorable`，行随曲线重排（上方重新出现 `Systematic Violation` 墨迹 2147..2195 = 舞台 1288..1317），高亮跟选中、窗口跟着走。
- `22-portrait-drag.png`：从 (800,2500) 拖到 (800,2000)，墨迹 1887..2656 ≈ 8 行，滚动平滑、没有断层（列表块整块移动，clip 跟着走）。

### 6.2 SurfaceFlinger（修后竖屏）

```
SurfaceView[rhine.music.database/rhine.music.database.MainActivity](BLAST)#19691
  geomBufferSize 0 0 1800 2880 | bounds 0,0,1800,2880 | buffer=0xb400006fa4c8c200 | visible
SurfaceView[...MainActivity]#19690
  geomBufferSize 0 0 -1 -1 | buffer=0x0 | invisible reason=nothing to draw
```

全窗只有一个有效 buffer，没有尺寸异常的场景 layer（3D 矩形的正确性由 §3.2/§3.4 的像素实测 + 代码一致来保）。

---

## 7. 回归

### 7.1 横屏布局

`30-landscape-regression.png`（pid 22486，COLD 2351 ms，`user_rotation=1`）与修前 `02-landscape-coldstart.png` 逐像素对比：

- **mean abs diff = 0.103**
- 差异 > 40 的像素仅 **4045 px**，bbox x 667..960 / y 263..576 —— 全部落在右侧诊断面板的动态数值区。

→ 横屏零回归。判定依据：`basicLibraryListStageRect` 横屏分支换成 `trackRulerWindowTop` 后与旧 `509-290` 完全相等；`shifted` 只有 `portrait` 分支用。

### 7.2 静态检查

`flutter analyze lib/` → **676 issues**，全部 `info`，加一条**改动前就有**的 warning `unused_element_parameter · lib/basic/basic_hud.dart:608`（`_LibraryDragRecognizer.allows`）。无 error；本次改动行没有新增任何告警（676 与基线一致）。

### 7.3 竖屏再冷启动（还原后）

`31-final-portrait-restored.png`：pid **23351**，`am start -W` COLD TotalTime 2513 ms，`wm size` 1800×2880，与 §6 一致。

### 7.4 受影响测试

```
flutter test test/hud/t33/track_ruler_test.dart \
             test/basic/interaction_134_native_test.dart \
             test/basic/portrait_hud_142_test.dart
→ 00:02 +33: All tests passed!
```

包含 `竖屏：列表在 1080 之后，ownership 跟着真机 720 宽的 stage 坐标`、`D7：720 逻辑宽仍是 1080 舞台 + 唯一 scale，列表命中不被 720-789<0 误判` 两条直接覆盖本次换算的用例。

---

## 8. 交付物与哈希

目录：`builds/PORTRAIT-FIX-20261119/`（截图未入库，见 §10 说明）

| 文件 | 内容 | sha256 |
| --- | --- | --- |
| `00-baseline-current.png` | 会话开始现场（竖屏） | `078f481f948dc20ed438e59277d3e5d171f78c490c3deab422da7e37c74336be` |
| `01-portrait-coldstart.png` | **修前**竖屏冷启动 | `413db53b6d4d2f655d533d4017a00ac0ac73f42455c2147b8db6d6d704a1559a` |
| `02-landscape-coldstart.png` | **修前**横屏冷启动（回归基线） | `78a54ba0029f044ef2aa47dfae259f4ad726bc1ac25eea342533fecc8fcb0032` |
| `03-compare-scene-square.png` | 横屏裁 1800² / 竖屏方形 对比 | `a9840f9f800ceb057d4763daa341072fade9419de30e0897bcf86e0644d84f7f` |
| `10-portrait-relaunch.png` | 修前竖屏复测（pid 7929） | `ba846a12dbbc695a604f1822531226e82ddfef513cf1da61f947fd39e57ee6ff` |
| `11-portrait-after-swipe.png` | 修前滑三次可滑出曲目（证明列表在画） | `800fd0b6e3ba464987c2b1d78df67f7b9a519e358ccd8252c80d612a774c8758` |
| `20-portrait-fixed.png` | **修后**竖屏（pid 19098） | `25053a5554f092be7c039d7c19102d877472c4f6f08a09278a546568d51fd58b` |
| `21-portrait-tap-row.png` | 修后点选 `Ens Inexorable` | `3b35ade71791969c0a1e1bc5efd1b4bc0a1e4a31058d1d162946bdbf6bc3d8fa` |
| `22-portrait-drag.png` | 修后拖动滚动（≈8 行） | `7a575fd5423db185f8a4713afcd15737d3c10ef6fa6d4c2d46267cdaf0491bbe` |
| `30-landscape-regression.png` | **修后**横屏回归（pid 22486） | `0232075798cca3cabc2ed8eaae0acb36a9d4b18ef08283228cf88b28cf46a901` |
| `31-final-portrait-restored.png` | 旋转还原后竖屏（pid 23351） | `7d45e8c9d72abd5d9e335c83fd8923754389b3e2d46b6bdde691cb1ecc7b78e3` |
| `40-portrait-before-after.png` | 左修前 / 右修后 对比（930×750） | `343e08a8c4b1c373e3b794c7f4b6ac03dd882e7a2ba0e705f425ec73a9ba3e48` |

---

## 9. APK、装机回执、设备状态

- 构建：`flutter build apk --debug --target-platform android-arm64 --no-pub`（Gradle 110.7 s；Qt 依赖沿用共享部署树 `…/FLUTTER-ONLY-ANDROID-20261117/qt-native/Qt/android-build`，javapatch 报 `status: already patched (skip) jar_sha256=9159cc5e…bbf1fc`，未改 Qt/C++）。
- 产物：`build/app/outputs/flutter-apk/app-debug.apk`，185748659 B，sha256 **`e6658135c193d652c6a8df36067c8bd9d27fcd7db5d4be4890fee72dea875b7a`**
- 装机：`adb -s 526f6b6d install -r -t build/app/outputs/flutter-apk/app-debug.apk` → `Performing Streamed Install / Success`
- `dumpsys package rhine.music.database`：`versionName=1.0.0`、`lastUpdateTime=2026-11-18 19:12:05`
- 运行时：竖屏 pid **19098**（验证用）→ 还原后冷启动 pid **23351**；横屏 pid 22486。
- 设备旋转：会话原始 `accelerometer_rotation=0`、`user_rotation=0`；操作中曾置 `user_rotation=1` 拍横屏；**结束已还原：`accelerometer_rotation=0`、`user_rotation=0`**（装机后系统把 `accelerometer_rotation` 翻成 1，已重新写回 0）。

---

## 10. 未验证 / 风险

1. **只在一台机器一种密度验证**（1800×2880 @ 378，dpr 2.3625 / 舞台 1080×1728，2 带里第 2 带只有 552 单位高）。`docs/flutter-migration/acceptance/portrait.md` 的 P1/P2/P3 矩阵（1080×2400@2.625 → 3 带、1440×3200@3.0 → 3 带、1200×2000@2.5 → 2 带）没跑；不同带高下「窗口 610 高于可用带」仍会出现 58 单位以内的裁切 —— 这是 610 常量与带高 648 的固有关系，本轮不再改常量。
2. **竖屏沿用横屏 HUD 底稿**：右侧锚定元素（音乐检索 / 塞王曲库 / 设置、`Tab Mode`、`POWERED BY RHINE LAB`、`COLLECTION 03/05`）按 `basicNavigationLeft(1080)=291` 排进 1080 宽舞台，压在 3D 方块上。规格文档的三候选（Portrait-W / Portrait-Band / Portrait-Hybrid）仍标 `WAIT-CANDIDATE`，**未裁决，本轮不动**。
3. **底部 chrome 没有重排**：`TRACK / SELECT`、`01 / 936`、`← →` 仍在舞台 y≈884..1050，与 1632 的播放条之间隔了一整条列表带。同属「竖屏底栏未重排」，不在本 bug 范围。
4. `selected=0` 时带顶仍空 ~290 单位（ruler 窗口上沿 219 + 字体内边距是固有结构，滚上去即填满，见 `22-portrait-drag.png`）——行为符合 ruler 曲线设计，未改。
5. 只跑了 `flutter analyze lib/`（676 issues / 0 error）与三个受影响测试文件（33 passed）；**没有跑全量测试**（未要求，改动只涉及两个常量与窗口锚点）。
6. 3D 场景的合成路径（SurfaceView / TextureView）与舞台尺寸 1080×1080 没有独立的 SurfaceFlinger layer 可直接证实（竖屏只有一个全窗 BLAST SurfaceView），结论依赖像素实测（1800×1800 方块）+ 代码矩形 + SF 中无异常 layer 三点。
7. 截图（约 13 MB）留在 worktree 的 `builds/PORTRAIT-FIX-20261119/` **未入库**（仓库目前没有任何 `builds/`、`reports/` 被跟踪的先例），哈希即上表；报告本身随分支提交。
