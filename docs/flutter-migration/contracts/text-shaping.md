# 复杂文本整形（glyph shaping）契约（DEDUP-17）

状态：**ARCH_BLOCKED**。基线 `bf6743e8486d62964cc27a4b8573533fc00f2eb4` 下不存在忠实的 `ComplexTextPort` 实现；本文件冻结“缺口 + 失败语义 + 未来 shim 的最小接口与验收”，不是修复，也不是验收。

证据等级：E1（直接读源码）。产出期间未执行任何 build / test / analyze / flutter run / pub get / Gradle / adb / Qt 编译或运行 / 项目脚本 / formatter / generator / golden。

Owner: TEXT-SHAPING (DEDUP-17)。Consumer: T31（HUD 文本测量与绘制）、T16（宿主裁决）、任何经 `GlyphText` 出字的面。

规范等级：**MUST** / **MUST NOT** / **SHOULD**。

基线漂移：所有 `文件:行` 指向上述基线；若文件漂移，以 `git show bf6743e8:Qt/src/Glyphs.cpp` 与 `git show bf6743e8:lib/hud/text/glyph_run.dart` 为准。

与 T04 的分工：`docs/flutter-migration/contracts/text-color.md` §1.1 已冻结五个字体文件与两张 JSON 表，§3.1 冻结 `needsLayout` 触发表，§3.2 冻结 `layoutText` 步骤；本文件只冻结端口边界、缺口判定与 fail-closed 行为，§3.1 是**端口相关复述**（只保留导出端口三量所需的环节；字体族细节、对齐、`setStyleName`/`setWeight` 等细则一律以 T04 §3.2 `:219-226` 为准）；T04 §3.1 触发表与 §3.3 回退字体顺序不在本文件复制。冲突时以 Qt 源码为准并修订本文件。

## 0. 结论（先读）

1. Qt 的复杂文本路径是 `QTextLayout` + `QRawFont::pathForGlyph`（`Qt/src/Glyphs.cpp:142-188`）；Dart 侧唯一的 `ComplexTextPort` 实现是 `_NoComplexTextPort`，它直接抛 `UnsupportedError`（`lib/hud/text/glyph_run.dart:118-136`）。
2. `dart:ui` / Flutter 只能排版与绘制，不导出字形轮廓、glyph id 或 font unit 级的 per-glyph advance；没有公开的 glyph path API。用它反推 `outlineEm` / `boundsEm` 只能得到伪造值。
3. 因此本卡判 **ARCH_BLOCKED**：不做假修复，不引入近似 hull，不丢字形。现有失败语义（抛错）**保留**，并在 §5 升格为契约。
4. 阻塞有两个独立面：输入（无 shaping 引擎 / 无轮廓）与输出（跨进程序列化在 minSdk 28 无公开 API，`PathIterator` 仅 API 34+）。任一未解都不能交付。
5. 待裁决：T16 宿主（PlatformView 候选 A，`docs/flutter-migration/adr/0001-host-architecture.md:29`）决定 shim 形态；`docs/flutter-migration/02-adjudication.md:110` 已把生产接线判为 ARCH_BLOCKED，等 T16。

## 1. 现状（Dart 侧，逐条带证据）

### 1.1 端口契约要求什么

`SimpleTextLayout`（`lib/hud/text/glyph_run.dart:44-77`）三个量：

| 字段 | 行 | 单位 / 坐标 | 硬要求 |
|---|---|---|---|
| `advanceEm` | `:57` | em | **已扣除** tracking，镜像 `qMax(0., line.horizontalAdvance() - spacing) / 1000`（`Glyphs.cpp:170`） |
| `outlineEm` | `:63` | font units（`kGlyphUnits` = 1000/em），y-up，non-zero fill | 真实整形后的轮廓，与 `Glyph.path` 同空间；绘制时 `translate(x, y + size*1.044)` + `scale(size/1000, -size/1000)`（`:543-556`） |
| `boundsEm` | `:76` | font units | **TIGHT** 包围盒，解析极值；文档明写 “Required, never a hull”（`:65-75`） |

`ComplexTextPort`（`:102-116`）只有一个方法：

```dart
SimpleTextLayout layout(String text, String weight, double trackingEm);
```

三条前置条件（`:108-114`）都是承重的：

- `advanceEm` 已扣 `trackingEm`（`:109-111`，`Glyphs.cpp:170`）；
- `outlineEm` 是真实整形轮廓，font units、y-up、non-zero，与 `Glyph.path` 同空间（`:112-113`）；
- `boundsEm` 是它们的 TIGHT 盒，绝不能用 Skia hull（`:114`）。

端口文档同时排除了三种“伪端口”：返回空 path、把逐码位资源字形拼起来、返回零 advance（`:96-101`），并明确“那会让 complex 分支看起来正确却画出错误的 run，比拒绝构建更糟”。

`ComplexTextGate`（`:79-86`）把“是否需要整形”的**逐串**判断放在端口之外，对应 Qt `needsLayout`（`Glyphs.cpp:109-139`）。`GlyphText` 的构造要求 port 与 gate 成对或都不给（`:162`、`:238-256`）。

### 1.2 唯一实现：抛错，且只该在“接错线”时到达

`_NoComplexTextPort`（`:118-136`）：

```dart
SimpleTextLayout layout(String text, String weight, double trackingEm) {
  throw UnsupportedError(
    'ComplexTextPort.layout was called without a shaping port. Inject one '
    '(fallback_shaper) before measuring text that requires complex layout.',
  );
}
```

（`:131-134`。）它的文档说明：`requiresComplexLayout` 对 resource-only 实例**不会**把 run 路由到这里，因为 resource-only 对“能证明需要 layout”的类先抛 `StateError`；所以到达 `layout()` 意味着 port/gate 配对错了（`:118-125`）。

仓内检索：`ComplexTextPort` 这个名字在 `lib/hud/text/` 共 15 行（`glyph_run.dart:75`/`:79`/`:102`/`:103`/`:126`/`:127`/`:132`/`:183`/`:186`/`:193`/`:248`/`:250`/`:267`/`:280`，以及 `fallback_shaper.dart:276` 的注释）；真正的实现只有 `_NoComplexTextPort` 一处（`glyph_run.dart:126` 类声明、`:127` 构造函数、`:186` 作为 resource-only 的默认 port、`:248` 的类型判别）。`test/hud/glyph_run_test.dart:101-122` 的 `_RecordingPort` 是测试假件，不算 shaper。

### 1.3 字形来源只有 JSON 表，没有 OTF 解析器

- `glyph_font.dart` 不读文件、不读 asset：在 `lib/hud/text/` 与 `test/hud/` 内 grep `dart:io` / `rootBundle` / `AssetBundle` / 字面量 `Assets/fonts` 为 0 命中（范围必须收窄：全树并非 0 —— `lib/` 另有 5 个文件引用 `dart:io`，`lib/ui/pages/boot_page.dart:299` 的注释提到 `rootBundle`，但都不在字形层）；入口是 `parseGlyphResources({required String glyphJson, required String letteringJson, SymbolCoverage symbols = SymbolCoverage.none})`（`lib/hud/text/glyph_font.dart:439`），由调用方把 JSON 文本递进来；它自身不 import `dart:io`，也没有 `Assets/fonts` 字面量。
- 轮廓**只**来自 `Assets/fonts/misans-glyphs.json`；boot lettering 来自 `boot-lettering-art.json`（`glyph_font.dart:439` 起的解析面）。
- 该文件自己写明没有 OTF 解析器（`glyph_font.dart:198-218`）：

  > “This layer has no OTF parser, so the two face steps are unavailable and the resource table is the whole of the search: a character it does not carry resolves to the default glyph (advance 1 em, empty outline). That is narrower than Qt, not an early return inside an equivalent search.”

- `_AxisRange`（类体 `:525`；文档 `:518-524`）只对 JSON 里的 SVG path 做解析极值，并点明这正是 `QPainterPath::boundingRect()` 报的值、而 Skia `Path.getBounds()` 不报的值。**tight bounds 的数学在本仓库只对 JSON 轮廓实现过，从未对“整形后的 run”实现过。**

### 1.4 字体二进制在库里，但没有任何加载者

`Assets/fonts/`（基线字节数）：

| 文件 | 字节 |
|---|---:|
| `RhineMiSans-light.otf` | 6796588 |
| `RhineMiSans-regular.otf` | 6725816 |
| `RhineMiSans-demibold.otf` | 6682092 |
| `RhineMiSans-bold.otf` | 6797880 |
| `NotoSansSymbols2-Regular.ttf` | 1233128 |
| `misans-glyphs.json` | 1683324 |
| `music-fonts.version` | 21 |

`pubspec.yaml:65-73` 只把它们当普通 asset 目录列出（`- Assets/fonts/`），**没有** `fonts:` family 注册：按 `^\s*fonts:\s*$` 与 `^\s*-\s*family:` 检索均为 0 命中，唯一的 `fonts:` 出现在 `:86-99` 的注释示例里。

推论（本文件的事实基础）：Flutter 引擎不加载这五个二进制，Dart 侧也没有解析器 ⇒ 资源表外的字形在整个 Flutter 构建里既无真实轮廓，也无真实 advance（只剩默认 1 em 空字形的兜底值）。这正是 DEDUP-17 的“无 OTF / 系统字体回退”，不是配置遗漏。

### 1.5 差距有多大（为何不能“先近似”）

`lib/hud/text/fallback_shaper.dart:77-101` 记录了离线测量（A1/T31-V4）：

- `RhineMiSans-regular.otf` cmap：**29415** 个码位；
- `misans-glyphs.json` 每个 weight：**1007** 个码位（上述 cmap 的严格子集，0 缺失）；
- `NotoSansSymbols2-Regular.ttf` cmap：**2955** 个码位；
- ⇒ 约 **28400** 个码位“OTF 有、表没有”。对这些码位，`GlyphFontSet.hasOutline` 返回 **false**（`lib/hud/text/glyph_font.dart:236-242`：表外码位走 `return table?.has(character) ?? false`），于是 term (7)（`!fonts.hasOutline(...) && !fonts.symbolSupports(...)`，`fallback_shaper.dart:326-328`）报 **true** —— 源码注释写的是“term (7) in this port reports true while Qt reports false”（`:94-96`，故意比 Qt 宽），指的是该谓词项而非 `hasOutline` 本身 —— 从而把整串送进 complex 分支；而 complex 分支当前没有实现 ⇒ 抛错。

也就是说：今天这些字符串**不会画错，只会失败**。这正是必须保留的 fail-closed 行为；任何“先画个近似”的改动都会把可检测的失败变成不可检测的错误画面。

### 1.6 生产接线状态：尚未接上，所以还没炸

`GlyphText` 在 `lib/` 下只有定义（`:145` class、`:162` 全参构造、`:185-187` resource-only），**没有生产构造点**；`lib/hud/render/hud_painter.dart:78-79` 与 `lib/hud/render/paint_stack.dart:45` 只是 T31 的注释引用。也就是说：文本层尚未接线，本缺口尚未在运行时暴露；T31 一旦接上，任何复杂串/缺字串都会按 §1.7 抛错。**“还没报错”不等于“可用”。**

### 1.7 失败面在哪里：整串失败，不是单字形降级

四个公开测量/绘制入口都会先过 `requiresComplexLayout`，命中即调用 `complex.layout`：

| 入口 | 行 | complex 分支 |
|---|---|---|
| `width` | `:412-430` | `:418-421` |
| `bounds` | `:436-459` | `:441-444` |
| `inset` | `:465-485` | `:473-476` |
| `paintText` | `:494-515` | `:504-507` |

resource-only 实例的抛错点：

- 结构类（非 BMP、孤立代理、U+200D、组合符、Hangul Jamo、非白名单 script）：`:257-270`，消息在 `:261-269`；
- 不可绘制类（该 weight 表内无轮廓）：`:271-283`，消息在 `:275-282`；
- port 有、gate 为 null 的非法配对：`:248-256`。

这三处 `StateError` 与 §1.2 的 `UnsupportedError` 共同构成当前的 fail-closed 面：**API 级整串失败，绝不返回近似值**。

## 2. 引擎事实：`dart:ui` / Flutter 能给什么

本节只引公开 API 名称，不引行号（`dart:ui` 不在本仓库内，且本轮禁止取 SDK 源码）。

| 需要 | `dart:ui` / Flutter 公开面 | 结论 |
|---|---|---|
| 逐字形轮廓（可绘制 `Path`） | `ui.ParagraphBuilder` / `ui.Paragraph` / `ui.Canvas.drawParagraph` 只能排版与绘制；`ui.Path` 只能由调用方用 `moveTo` / `lineTo` / `cubicTo` / `addPath` 构造 | **无导出 API**；没有“按字形取轮廓”的公开方法，`ui.TextBlob` 只能构造与绘制、不能导出轮廓，也没有 glyph atlas 反射 |
| glyph id / cmap 查询 | `ui.FontLoader.loadFontFromList` 只加载字节；`ui.TextStyle` 与字体选择相关的字段只有 `fontFamily` / `fontFamilyFallback` / `fontFeatures` / `letterSpacing`（其余字段是尺寸、装饰、阴影等，无 cmap / glyph id 查询） | **无** |
| font unit 级 per-glyph advance | `ui.Paragraph.longestLine` / `computeLineMetrics` / `getBoxesForRange`、`TextPainter`（`package:flutter/painting`）的 `getBoxesForSelection` / `computeLineMetrics` 都是逻辑像素、行盒或选择盒，且经引擎 shaping + hinting，不可分解到字形 | **无**；无法反推 `advanceEm` |
| 解析 tight bounds | `ui.Path.getBounds()` 是控制点凸包（保守界）；`ui.Path.computeMetrics()` 给长度/切线/子路径（`ui.PathMetric.extractPath`），不给指令流 | **无**；`glyph_run.dart:65-75` 已写明它 “at least as large as the true box” |
| 路径序列化 | 无公开 `Path`→SVG / 指令流 API；`PathMetric.extractPath` 仍返回 `ui.Path` | **无** |

`TextPainter`（`package:flutter/painting`）是 `dart:ui` 之上的排版缓存，能力边界相同：`layout` / `paint` / `getBoxesForSelection` / `computeLineMetrics` 都是行盒与像素度量，不提供轮廓，也不提供字形级 advance。

结论：`Paragraph` / `TextPainter` 能满足“排版 + 绘制”，不能满足“导出 `outlineEm` + `boundsEm` + 净 `advanceEm`”。任何用它们反推的路径都只能是近似，按 §5 禁令不得进入端口。

## 3. 平台侧能力：Qt 参考链与 Android shim 的两个缺口

### 3.1 Qt 是参考实现（唯一权威，逐条 `文件:行`）

`Glyphs::layoutText`（`Qt/src/Glyphs.cpp:142-188`）就是端口要复现的算法（完整步骤已冻结在 T04 §3.2 `:219-226`；下表只列与导出端口三量直接相关的环节）：

| 步骤 | 行 | 说明 |
|---|---|---|
| 字体选择 | `:147-158` | `fonts.value(weight, fonts["regular"])`；基字体 `QFontDatabase::systemFont(QFontDatabase::GeneralFont)`；family 取 `layoutFamilies`，空则保留系统族；`setPixelSize(1000)`；`PreferNoHinting`；`setLetterSpacing(QFont::AbsoluteSpacing, spacing)` |
| 文本规范化 | `:159` | `text.normalized(NFC)` |
| 单行布局 | `:163-168` | `beginLayout` / `createLine` / `setLineWidth(1000000)` / `endLayout` |
| advance | `:170` | `qMax(0., line.horizontalAdvance() - spacing) / 1000` |
| 轮廓 | `:171-183` | `setFillRule(WindingFill)`；遍历 `layout.glyphRuns()`；`run.glyphIndexes()` / `run.positions()` / `run.rawFont()`；`rawFont.pathForGlyph(index)`；`path.translate(positions[i].x(), positions[i].y() - line.ascent())`；`outline.addPath(path)`；最后 `QTransform::fromScale(1,-1).map(outline)` 翻成 y-up |
| 缓存 | `:143-146`、`:184-186` | key = `weight + ':' + spacing('g',17) + ':' + text`；`text.size() <= 4096` 才缓存 |

下游三处给出端口的三个量：

- `width`（`:286-311`）：complex 时 `layoutText(...).advance * size`（`:296-299`），tracking 传 `size > 0 ? tracking * 1000 / size : 0`；
- `bounds`（`:312-338`）：complex 时对 `layoutText(value, weight, 0).path` 做 `translate(0, size*1.044)` + `scale(size/1000, -size/1000)` 后取 `boundingRect()`（`:314-319`，tracking 固定 0）；非 complex 时逐字形 union，只并“path 非空”的字形但仍推进 x（`:321-336`）；
- `inset`（`:339-349`）：complex 时 `layoutText(...,0).path.boundingRect().x() * size / 1000`（`:344-345`）；
- `text`（`:530-564`）：complex 时 `fillPath(shaped.path)`（`:533-539`）；非 complex 逐字形同变换（`:555-562`）。

Qt 侧还有一条本仓库可用的精确导出路径：`QPainterPath` 公开 `elementCount()` / `elementAt()`（以及 `toSubpathPolygons()`），可无损序列化曲线段。**这是“保留 Qt 渲染面”路线成立的原因，也是纯 Flutter 路线的对照物。**

> 说明：`third_party/qt/qtbase` 是 gitlink 子模块（pinned `025bdad181de241e81bf853c8a2d7bf3d19261a9`，branch v6.12.0），本工作树未初始化、目录 0 个文件，因此本文件**不引 qtbase 的 `文件:行`**；`QTextLayout` / `QRawFont` / `QPainterPath` 只以公开 API 名称出现，行为以本项目 `Qt/src/Glyphs.cpp` 的实际调用为证。

### 3.2 Android shim：输入端有 API，输出端被 API level 卡死

输入端（有解，但需平台接线）：

- `android.graphics.Paint.getTextPath(String text, int start, int end, float x, float y, Path path)` 可把整形后的整串轮廓写进 `Path`；
- `Paint.measureText` 给 advance，`Paint.getTextBounds` 给保守框（**不是** tight bounds，见 §5 禁令）。

输出端（无解）：

- 把 `android.graphics.Path` 变成可跨进程/可回传的指令流，公开 API 只有 `PathIterator`（**API 34+**，Android 14）。本仓库基线 minSdk = **28**（`docs/flutter-migration/00-baseline.md:66`、`docs/flutter-migration/evidence/device-2026-11-09.md:67`、`docs/flutter-migration/release.md:26`；`android/app/build.gradle.kts:22` 委派 `flutter.minSdkVersion`，故以基线实测值为准）⇒ API 28..33 上无法枚举路径段。
- `Path.approximate()`（API 26+）返回折线，是有损近似，**不得**用来冒充 tight bounds 或精确轮廓（§5）。
- `PathMeasure` 只给长度/切线/子路径截取，不给段枚举。

> 证据等级说明：Android 的 API 名称与 API level 属平台 SDK 事实，不在本仓库内；本轮未读 `android.jar`、未执行任何命令验证。Qt 侧事实全部来自本仓库 `Qt/src/Glyphs.cpp` 行号。

## 4. 判定：ARCH_BLOCKED

四个独立理由，任一成立即阻塞，四条同时成立：

- **R1 输入端无实现**：Dart 侧无 shaping 引擎；`dart:ui` 不导出 glyph 轮廓、glyph id、font unit advance（§2）。要拿到 Qt 的三量，只能自带 shaper + 字体解析器，或调用平台引擎。
- **R2 输出端无公开序列化**：平台 shim 必须把路径变成可传输数据；Android 在 minSdk 28 上无公开 Path 段枚举，`PathIterator` 仅 API 34+（§3.2）。Qt 侧可精确导出，但那意味着保留 Qt 渲染面。
- **R3 字体不可用即无回退**：五个字体二进制只在 assets，未注册 family；即便注册，Flutter 也不暴露轮廓（§1.4、§2）。注册只会改变引擎测量，不产生 `outlineEm`。
- **R4 宿主未裁决**：ADR 0001 五候选无赢家（`docs/flutter-migration/adr/0001-host-architecture.md:27-34`），生产接线按 `docs/flutter-migration/02-adjudication.md:110` 判为 ARCH_BLOCKED，等 T16。shim 形态由宿主决定。

因此：

- 本卡**不是** DEVICE_BLOCKED：不需要真机就能判定；
- 本卡**不是** TODO：不是“再写点代码”的问题，缺的是架构位置；
- 明确拒绝三种伪修复：(a) 用 `TextPainter` 量一遍再画 hull；(b) 用资源表 1007 个字形的并集/凸包近似；(c) 丢掉缺字形或替换成默认字形。三者都改变 1:1 画面，且 (b)(c) 会把可检测失败变成静默错误。

可选的两条未来路线（都需裁决，不属本卡）：

1. **平台 shim**：Qt 侧（`QPainterPath::elementCount/elementAt`）或 Android 侧（`getTextPath` + API 34+ 序列化 / 抬 floor / 原生序列化器）返回精确轮廓与 advance；
2. **纯 Dart 字体引擎**：OTF 解析 + HarfBuzz 级 shaping，直接在 Dart 里构造 `ui.Path`（无需序列化），但那是自建文本引擎，成本与一致性（bidi、复杂 script、hinting）风险另算。

在 T16 裁决前，MUST NOT 选型、MUST NOT 预埋二者之一的半成品。

## 5. shim 到位前的契约（规范性）

**TS-5.1 fail closed。** 复杂路径 MUST 继续抛错：保留 `_NoComplexTextPort` 的 `UnsupportedError`（`glyph_run.dart:131-134`）与 resource-only 的两处 `StateError`（`:261-269`、`:275-282`）的语义。MUST NOT 改成返回空 `Path`、1 em 默认字形、估算 advance 或“尽力而为”的部分结果；MUST NOT 在调用侧 `catch` 后继续绘制。

**TS-5.2 错误必须可操作。** 消息 MUST 点名缺什么（port / gate）、给出注入点（`fallback_shaper.requiresFallbackGate`）、并说明替代构造（`GlyphText.resourceOnly` 对该串不适用）。现状逐条：`:249-255` 三项俱全（`requiresFallbackGate` + “`GlyphText.resourceOnly` and no port at all”）；`:261-269` 点名 port+gate 与 `requiresFallbackGate`，并要求 “instead of the resource-only constructor”（未解释为何不适用）；`:131-134` 只给注入对象 `fallback_shaper`，未提 gate / `requiresFallbackGate` / `resourceOnly`；`:275-282` 只给“port + gate 对”与“把字形加进资源表”，未提 `requiresFallbackGate` / `resourceOnly`。因此**并非全部满足**：任何改写 MUST 把这四项按上面逐条补齐，并保留“缺哪一类、哪个码位、为什么不能近似”的信息量。

**TS-5.3 不得用“注册字体族”冒充回退。** 给 `pubspec.yaml` 增加 `fonts:` family 会改变引擎测量，但仍拿不到 `outlineEm` / `boundsEm`；MUST NOT 以此宣称 complex 路径已可用。（本卡亦禁改 `pubspec.yaml`。）

**TS-5.4 resource-only 不是生产路径。** 它只对“表内且可判定为 plain”的串承诺正确；bidi（Qt term 6）在 Dart 侧不可判定，已由文档承认（`glyph_run.dart:179-184`、`:228-231`；`fallback_shaper.dart:61-72`）。MUST NOT 把 resource-only 当作“没有 port 时的降级方案”。

**TS-5.5 tight bounds 的唯一合法来源是曲线极值。** MUST NOT 用控制点 hull（`ui.Path.getBounds`）、MUST NOT 用 `Paint.getTextBounds` 的保守框、MUST NOT 用折线近似（`Path.approximate`）冒充。允许的算法：三次贝塞尔解析极值或与之等价的精确算法（本仓库对 JSON 轮廓已有实现，见 `glyph_font.dart:525` 起；对整形 run 尚未实现）。

**TS-5.6 不丢字形、不替换。** 一个码位无轮廓时 MUST 让整串失败（当前行为），MUST NOT 静默跳过、MUST NOT 画默认 1 em 空字形、MUST NOT 用 U+FFFD 替换后再画。

**TS-5.7 可见性由裁决决定，不由实现层决定。** 若某页面无法避免复杂串，MUST 在接线前取得 T16 裁决与产品兜底方案（错误态/禁用态）；MUST NOT 用 `try/catch` 渲染残缺文本。

## 6. 未来 shim 的最小接口与验收

### 6.1 接口（签名不得改）

```dart
abstract class ComplexTextPort {
  const ComplexTextPort();
  SimpleTextLayout layout(String text, String weight, double trackingEm);
}
```

输入：

| 参数 | 语义 | 约束 |
|---|---|---|
| `text` | 调用方原文 | shim 内部 MUST 做 NFC，对齐 `Glyphs.cpp:159` |
| `weight` | `light` / `regular` / `demibold` / `bold`，另有 symbols key | 与 `GlyphFontSet` 的 key 一致；未知 weight 按 Qt `fonts.value(weight, fonts["regular"])` 回落 |
| `trackingEm` | font units 的 letter spacing = `tracking * 1000 / size`（`glyph_run.dart:209-210`；`size <= 0` 时为 0） | 必须从 `advanceEm` 中扣除（`Glyphs.cpp:170`） |

输出（`SimpleTextLayout`，语义见 §1.1）：

- `advanceEm`：已扣 tracking 的净值；
- `outlineEm`：真实整形轮廓，font units（1000/em），y-up，non-zero fill，原点在基线起点；
- `boundsEm`：`outlineEm` 的 TIGHT 矩形，由曲线极值算出。

实现可以跨进程/跨平台，但契约面只有这三个量；MUST NOT 把 glyph id、字体路径、平台句柄暴露给调用方（内部缓存 key 除外）。

### 6.2 验收条件

- **A1 轮廓一致**：对同一语料、同一字体、`pixelSize=1000`、`PreferNoHinting`、同一 spacing，shim 的每条 contour 与 Qt 参考（`layoutText` 导出）逐段一致。容差不在本契约预设：实现卡 MUST 给出数值与依据（字体单位为整数、`qreal` 为 double、序列化精度），并在评审中固定。
- **A2 advance 一致**：与 Qt `qMax(0, line.horizontalAdvance() - spacing) / 1000` 相等（同一比较口径）；`width()` 侧再乘 `size`（`glyph_run.dart:418-421`）。
- **A3 bounds 自洽且可比**：`boundsEm` 必须等于 `outlineEm` 的解析极值（自洽检查，可用独立极值计算复算），并与 Qt `boundingRect()` 的映射结果可比；跨引擎容差同上，由实现卡定值。
- **A4 语料覆盖**：空串、纯 ASCII、单个组合符、Hangul Jamo、非 BMP（含 emoji）、ZWJ 序列、RTL（希伯来/阿拉伯）、非白名单 script（如泰文/天城文）、表内缺字、symbols 码位、长度 > 4096 的串（缓存边界，`Glyphs.cpp:184-186`）。只有 ASCII 通过不算通过。
- **A5 失败语义不变**：shim 不可用时 MUST 抛同族错误（`UnsupportedError` / `StateError`），MUST NOT 返回部分结果或空轮廓。
- **A6 无降级分支**：代码审查 MUST 能指出 tight bounds 的极值计算处；若存在 hull / 折线 / 默认字形分支，判 FAIL。
- **A7 确定性**：同一 `(text, weight, trackingEm)` 重复调用结果一致；缓存（若实现）MUST NOT 改变数值，SHOULD 对齐 Qt 的 `text.size() <= 4096` 上限。
- **A8 证据**：实现卡 MUST 附 Qt 侧导出的参考输出与对比结果；本卡不产出该证据。

### 6.3 非目标

- 不实现 bidi 分类表（由注入的 `UnicodeClassifier` 负责，`fallback_shaper.dart:61-72`、`:188` 起）；
- 不改变 `needsLayout` 的触发集合（T04 §3.1 已冻结）；
- 不注册字体族、不改 `pubspec.yaml`、不改 minSdk（属 T16 / 平台卡）；
- 不做设备像素取证（DEVICE_BLOCKED）。

## 7. 待裁决项（T16 / 平台视图）

| ID | 议题 | 现状 | 阻塞什么 | 归属 |
|---|---|---|---|---|
| D1 | 宿主是否保留 Qt 渲染面（候选 A PlatformView，`adr/0001-host-architecture.md:29`） | 五候选无赢家；生产接线 ARCH_BLOCKED（`02-adjudication.md:110`） | shim 形态（Qt 导出 vs 平台/自建） | T16 |
| D2 | 若纯 Flutter：Android `getTextPath` shim 还是纯 Dart 字体引擎 | 未选型 | 输入端 | T16 + Lead |
| D3 | minSdk 28 vs `PathIterator` 34 的冲突解法（抬 floor / 原生序列化器 / 放弃跨进程） | 无公开 API 可用 | 输出端 | T16 + 平台 |
| D4 | 是否把五个二进制注册为 Flutter font family | 当前未注册 | 仅影响 `TextPainter` 测量，**不解决** outline | T16 |
| D5 | 复杂串的 UX 兜底（错误态/禁用态/提示） | 未定义 | 接线后的用户可见行为 | 产品 + T16 |
| D6 | symbols 字体（`NotoSansSymbols2`）的轮廓来源 | 当前只有 coverage（`glyph_font.dart:214-218`） | 符号字形 | T31 |
| D7 | bidi 分类表来源（Qt term 6） | Dart 侧不可判定 | 纯 Flutter 路线的完整性 | T31 |

## 8. 残余风险

1. 本文件不改变任何运行行为；T31 接线前必须重读本文件，并按 §5 检查 fail-closed 是否仍在。
2. `third_party/qt/qtbase` 未初始化（0 文件），本文件无法给出 qtbase 行号；若评审要求 qtbase 级证据，须先 `git submodule update --init --depth 1 third_party/qt/qtbase` 检出 pinned `025bdad181de241e81bf853c8a2d7bf3d19261a9`，再补证。本轮禁执行，故不补。
3. 约 28400 码位的量化来自 `fallback_shaper.dart:77-101` 的离线测量（A1/T31-V4），本轮禁执行、不可复现；它只用于说明量级，不作为验收阈值。
4. Android API level 事实未在本仓库内验证（未读 SDK）；若平台卡给出不同 API level，以平台卡为准并修订 §3.2。
5. 未做任何设备取证；本文件所有结论均为 E1 源码证据。

## 9. 证据索引

| 声明 | 证据 |
|---|---|
| 端口三量与 tight bounds 要求 | `lib/hud/text/glyph_run.dart:44-77`（`:57`、`:63`、`:76`、`:65-75`） |
| 端口签名与三条前置 | `lib/hud/text/glyph_run.dart:102-116`（`:108-114`） |
| 唯一实现抛 `UnsupportedError` | `lib/hud/text/glyph_run.dart:118-136`（消息 `:131-134`） |
| 配对错误检测 | `lib/hud/text/glyph_run.dart:238-256` |
| resource-only 结构类抛错 | `lib/hud/text/glyph_run.dart:257-270`（消息 `:261-269`） |
| resource-only 缺字抛错 | `lib/hud/text/glyph_run.dart:271-283`（消息 `:275-282`） |
| 四个入口都走端口 | `lib/hud/text/glyph_run.dart:412-430`、`:436-459`、`:465-485`、`:494-515` |
| 无 OTF 解析器、表即全部 | `lib/hud/text/glyph_font.dart:198-218`；`parseGlyphResources` `:439`；tight 极值 `:525` 起 |
| 字体仅在 assets、无 family | `pubspec.yaml:65-73`；无 `fonts:` / `- family:` 命中 |
| 覆盖差距 29415 / 1007 / 2955 | `lib/hud/text/fallback_shaper.dart:77-101` |
| Qt 整形算法 | `Qt/src/Glyphs.cpp:142-188`（`:147-158`、`:159`、`:163-168`、`:170`、`:171-183`） |
| Qt width/bounds/inset/text | `Qt/src/Glyphs.cpp:286-311`、`:312-338`、`:339-349`、`:530-564` |
| Qt 缺字判定 | `Qt/src/Glyphs.cpp:109-139`（`:128-130`） |
| Qt 单字形回落顺序 | `Qt/src/Glyphs.cpp:266-285` |
| 生产接线 ARCH_BLOCKED | `docs/flutter-migration/02-adjudication.md:110` |
| 宿主五候选 | `docs/flutter-migration/adr/0001-host-architecture.md:27-34`（A `:29`） |
| minSdk 28 | `docs/flutter-migration/00-baseline.md:66`、`evidence/device-2026-11-09.md:67`、`release.md:26`、`android/app/build.gradle.kts:22` |

未验证清单（本轮明确没做）：未执行 build / test / analyze / flutter run / pub get / Gradle / adb / Qt / 脚本 / formatter / generator / golden；未读 `android.jar` 或 `dart:ui` 源码；未初始化 qtbase；未做设备取证；未验证任何运行时行为。
