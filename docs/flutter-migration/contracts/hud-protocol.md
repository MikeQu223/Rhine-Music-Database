# Native HUD 命令、命中与帧协议（冻结 v1）

状态：`FROZEN_FOR_IMPLEMENTATION`  
冻结基线：`8ed3067b0812eb2612f7841ec127a6e8ca93231b`  
适用：横屏 Qt 行为按本协议 1:1 迁移；竖屏只做重排新设计，不伪造 Qt 竖屏基线。  
生产接线：`ARCH_BLOCKED`。设备画面/手感证据：`DEVICE_BLOCKED`。本文件只冻结协议，不表示任何页面、设备或性能已验收。

本文件的规范来源是当前仓库的 Qt 源码，不是旧 Flutter 实现。所有行号以冻结基线为准。计划中的 `§4.2`、`§4.3`、`§9.1` 与附录 `B.2`/`B.5` 是本协议的验收锚点；T01 的 session/QSettings/AppStorage 冻结若晚于本文件发布，只需核对引用，不改变本文件已冻结的数组形状与语义。

## 1. 发布单位与同代次规则

### 1.1 Qt 的实际产生链

一次 step 的 HUD 数据来自同一次绘制调用：

1. `NativeApplication::step` 在 `Qt/src/NativeApplication.cpp:110` 取 `reuseScene ? music.frame : m_scene->sample(time)`，随后在 `:117` 写回 `music.frame = frame`。
2. 同一个 `frame` 在 `Qt/src/NativeApplication.cpp:131` 传给 `hud.draw(frame, width, time)`。
3. `NativeHud::draw` 在 `Qt/src/NativeHud.cpp:252-253` 清空 `commands` 与 `hits`，然后按绘制顺序重新生成；PlayerBar 在 `:310` 最后绘制（但 boot 页面除外，见 `Qt/src/NativeHud.cpp:309-311` 的 `frame["mode"] != "boot"` 守卫），因此非 boot 页面的 PlayerBar commands/hits 位于尾部。
4. `Qt/src/NativeApplication.cpp:147-151` 一次性返回 `commands`、`hits`、`state`（以及 `current`、`cover`）。`frame` 不在这个返回对象里，但就是第 1 步产生、第 2 步消费的同一份场景帧。
5. `Engine::step` 在 `Qt/src/Engine.cpp:1143` 执行 `m_frame = scene.frame`，随后在 `:1348-1387` 消费 `commands`、`:1402-1411` 消费 `state`、`:1412-1416` 消费 `hits`。

因此 Qt 的一次 step 已经是一个发布单位：commands、hits、state 与 frame 都来自同一个 step/draw。Qt 没有 `generation` 字段；`generation` 是 Flutter 侧新增信封的可选一致性字段，不能反过来改变 Qt 的数组语义。

### 1.2 允许的帧复用

`Engine::step` 在 `Qt/src/Engine.cpp:1126-1132` 允许睡眠场景复用 `music.frame`，但页面切换、viewer、detail 过渡期间通过 `hudTransition` 禁止复用，避免 HUD 拿到旧 detail 而冻结命令流。复用只表示场景采样可复用，不表示 commands/hits 可以跨代次拼接；复用的 frame 与本次 draw 生成的 commands/hits/state 仍构成同一发布单位。

### 1.3 Flutter 侧拟议信封（只拟议，尚未接线）

为了把“同一发布单位”显式化，Flutter 桥可使用：

```json
{"generation": 7, "frame": {}, "commands": [], "hits": [], "state": {}}
```

约束：

- `generation` 单调递增，只用于一致性校验与丢弃错配快照；不得用于去重或重排。
- `frame`、`commands`、`hits`、`state` 必须来自同一 step/draw。
- 该信封不是 Qt 既有对象；未接线前不得声称 Qt 已输出 `generation`。
- `generation` 在 Qt 源码里没有任何可引行号，本文件不为它标注 Qt 源。任何用 Qt 文件:行号给 `generation` 背书、或把 T30 侧本地信封写成既有 Qt wire 的写法都是伪造；T30 的本地 generation/envelope 只属于 Flutter 侧草稿，不构成本协议的 Qt 证据。
- 生产接线未完成，标记 `ARCH_BLOCKED`；设备实测未完成，标记 `DEVICE_BLOCKED`。

### 1.4 四条硬规则

1. **不去重**：逐项相同的命令是合法输入，必须逐条执行。`Engine.cpp:1348-1387` 的“命令是否有变化”只决定是否发布，不是去重；Flutter 渲染器不得用 Set/Map 合并相同命令。
2. **不重排**：hits 按源生成顺序消费，commands 按数组顺序执行。不得按 z、按矩形坐标、按 action 名称重新排序。
3. **不伪造 z**：commands 是数组，hits 没有 z 字段。禁止把 `{id,opcode,args,seq}` 或带 `z` 的对象当作契约。
4. **同几何**：measure、hit、IME 必须共用同一份 layout geometry 与同一 stage 坐标；外扩只发生在触摸层，绝不回写源矩形。

## 2. commands：17 个原始数组 op

### 2.1 通用形状

每条命令是一个 JSON 数组，`a[0]` 是字符串 op。参数从 `a[1]` 开始。不存在 `id`、`opcode`、`args`、`seq`、`frameId`、`z`。

数值参数按 `QJsonValue::toDouble()` 读取；数组尾部缺失时该值为 `0`。颜色参数按数组读取；第 4 项 alpha 缺省为 `1`；第 5 项是可选色彩空间标记，不是 alpha。Flutter 侧生产者应始终发出下表所列的完整位置；渲染器必须对合法的短尾形式按下文默认值兼容。这条规则不约束既有 Qt 流：Qt 参考生产者自己就发出合法的 4 项短 `path`（`Qt/src/NativeHud.cpp:507,513,619`），也发出完整 6 项形式（非 boot 页面的 `Qt/src/PlayerBar.cpp:59`，以及 boot 分支的 `Qt/src/NativeHudBoot.cpp:147-150,151,187,196,202-203`）。穷举 `Qt/src` 里 HUD `path` op 的全部发出点就只有这两种长度，不存在 5 项形式（`Qt/src` 里另有多处 `path` 字段——曲目、根目录、字形 JSON 等，例如 `Qt/src/LocalMusicLibrary.cpp:183,385`——但以 `{"path", ...}` 构造命令数组的只有这 9 处）；所以解析器不得假设任何可选位置一定存在。

命令流是有状态的：`save`/`restore` 管理 QPainter 状态栈，`translate`/`scale`/`rotate` 修改当前变换，`clip` 与当前裁剪区求交，`alpha` 与当前 opacity 相乘。命令之间不得并行化或重排。

### 2.2 冻结表

| # | op | 数组形状（含 a[0]） | 参数位置与类型 | 语义 |
|---|---|---|---|---|
| 1 | `save` | `["save"]` | 无 | 当前绘制状态入栈 |
| 2 | `restore` | `["restore"]` | 无 | 当前绘制状态出栈 |
| 3 | `alpha` | `["alpha", v]` | `a[1]: number` | `c.setOpacity(c.opacity() * v)`，乘算，不覆盖 |
| 4 | `translate` | `["translate", x, y]` | `a[1],a[2]: number` | 当前变换平移 |
| 5 | `scale` | `["scale", sx, sy]` | `a[1],a[2]: number` | 当前变换缩放 |
| 6 | `rotate` | `["rotate", radians]` | `a[1]: number` | 输入弧度；Qt 内部转 `radians*180/pi` 度 |
| 7 | `clip` | `["clip", x, y, w, h]` | `a[1..4]: number` | `QRectF(x,y,w,h)`，`Qt::IntersectClip` |
| 8 | `fill` | `["fill", color, x, y, w, h]` | `a[1]: color`；`a[2..5]: number` | `fillRect(QRectF(x,y,w,h), color)`；颜色在 a[1] |
| 9 | `ellipse` | `["ellipse", color, x, y, w, h]` | `a[1]: color`；`a[2..5]: number` | 无描边、画刷 color，画左上矩形 (x,y,w,h) 的内切椭圆；不是圆心/半径 |
| 10 | `text` | `["text", value, x, y, size, weight, tracking, color]` | `a[1]: string`；`a[2..4],a[6]: number`；`a[5]: string`；`a[7]: color` | 字形路径文字；基线 `y + size*1.044`；逐字 `advance*size + tracking` |
| 11 | `art` | `["art", key, x, y, size, count, tracking, color]` | `a[1]: string`；`a[2..4],a[6]: number`；`a[5]: int`；`a[7]: color` | 图标字形串；`count < 0` 表示整串；**没有** text 的 `1.044` 基线偏移 |
| 12 | `fill-path` | `["fill-path", svg, color]` | `a[1]: string`；`a[2]: color` | 按 SVG path 填充 |
| 13 | `path` | `["path", svg, penWidth, color, dash, dashOffset]` | `a[1]: string`；`a[2]: number`；`a[3]: color`；`a[4]: array<number>` 可选；`a[5]: number` 可选 | 描边路径；dash 每项与 dashOffset 都除以 `max(penWidth, .0001)`；FlatCap/MiterJoin；无画刷 |
| 14 | `arc` | `["arc", cx, cy, r, start, sweep, penWidth, color]` | `a[1..6]: number`；`a[7]: color` | 圆心 (cx,cy)、半径 r；start/sweep 为弧度；Qt 内部取 `-start`/`-sweep`；RoundCap；无画刷 |
| 15 | `right-mask` | `["right-mask", color, start, span, right, height]` | `a[1]: color`；`a[2..5]: number` | 从 start 到 start+span 的线性透明渐隐；MaskSteps=16，step=0..16 共 17 个 stop/16 段 smoothstep；填充 `QRectF(start,0,right-start,height)` |
| 16 | `gradient` | `["gradient", dark?]` | `a[1]: bool` 可选，缺省 `false` | 固定中心 `(979.2,518.4)`、半径 `1100` 的径向渐变；覆盖 `(-4096,-4096,8192,8192)` |
| 17 | `image` | `["image", key, x, y, w, h]` | `a[1]: string`；`a[2..5]: number` | 宿主按 key 取图；图非空时 `drawImage(QRectF(x,y,w,h), image)` |

表顺序只用于核对 17 个 op 名称，不是要求命令流按这个顺序排列。实际命令流由页面绘制顺序决定，且必须原序执行。

### 2.3 默认值、可选位置与短尾形式

| 位置 | 缺省行为 | 说明 |
|---|---|---|
| 颜色 `a[3]` | `1.0` | alpha；不是第 5 项 |
| 颜色第 5 项 | 无 | 只有 `toString().startsWith("calibrated")` 才触发 Gamma 1.8 → sRGB；普通 RGBA 只读前四项 |
| `art` 的 count | `-1` | `count < 0` 画整串 |
| `path` 的 `a[4]` | 空数组 | 空 dash 表示实线；此时不设置 dashOffset |
| `path` 的 `a[5]` | `0` | 仅当 dash 非空时应用 |
| `gradient` 的 `a[1]` | `false` | `a.size() > 1 && a[1].toBool()` |
| `text`/`art` 的 weight/tracking | 空串/`0` | 生产路径总会发出；渲染器按位置读取 |

Qt 源码中 `path` 既有完整的 6 项形式，也有省略 dash/offset 的 4 项短形式（4 项短形式例如 `Qt/src/NativeHud.cpp:507`、`:513`、`:619`；完整 6 项形式是 `Qt/src/PlayerBar.cpp:59` 与 boot 分支的 `Qt/src/NativeHudBoot.cpp:147-150,151,187,196,202-203`）。Flutter 解析器必须同时接受二者：4 项时 dash 为空、offset 为 0，按实线绘制。

### 2.4 颜色

颜色值是 RGBA 数组：

```
[red, green, blue, alpha?, "calibrated..."?]
```

- `a[0..2]` 是 RGB，范围按 Qt `QColor::fromRgbF` 的 0..1 解释。
- `a[3]` 是 alpha，缺省 1；不是第 5 项。
- `a[4]` 只有当字符串以 `calibrated` 开头时才生效（如 `calibratedRGB`、`calibratedWhite`）。

校准颜色的转换必须逐通道执行：

```text
linear = pow(value, 1.8)
srgb = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1/2.4) - 0.055
```

普通 RGBA（没有 calibrated 第 5 项）不执行该转换。第 5 项不是 alpha，禁止把它当透明度。

- 转换只作用于 `a[0..2]` 三个通道；`a[3]` alpha 在 `Qt/src/Glyphs.cpp:48` 里直接 `toDouble()`，永远不经过 Gamma 转换。
- 颜色项整体缺失时 `a` 是空数组：逐通道读到 `0`，alpha 落到默认 `1`，等价于 `QColor::fromRgbF(0, 0, 0, 1)`（不透明黑）。生产者不会发出这种形态（`NativeHud::fill`/`text` 在 `Qt/src/NativeHud.cpp:37-43`、`NativeHud::art` 在 `Qt/src/NativeHud.cpp:135-138` 对空颜色注入 `ink()`），但解析器必须按此默认解析，不得因此拒绝、跳过或改写后面命令里的颜色位置。

### 2.5 必须逐项对齐的绘制语义

- **text 基线**：`translate(x, y + size*1.044)`，再 `scale(size/1000, -size/1000)` 填充字形路径；逐字 `x += advance*size + tracking`。不要用普通 Text 的全量重排替换。
- **art 基线**：`translate(x, y)`，再 `scale(size/1000, size/1000)`；没有 `1.044`。`count < 0` 取整串，否则取前 count 个。
- **path 虚线**：dash 每项除以 `max(penWidth, .0001)`，offset 同样除；dash 为空时保持实线且不设置 offset；端点 FlatCap、连接 MiterJoin、无画刷。
- **arc 方向**：输入是弧度；Qt 用 `arcMoveTo(rect, -start*180/pi)` 与 `arcTo(rect, -start*180/pi, -sweep*180/pi)`；RoundCap、无画刷。不要按屏幕坐标自行反转角度。
- **right-mask**：`MaskSteps = 16`，循环 `step = 0; step <= 16`，即 17 个 stop、16 段；`progress = step/16`，`eased = p*p*(3-2p)`，stop alpha = `baseAlpha*eased`。不要写成 15 段或 17 段。
- **gradient 固定几何**：中心 `(979.2, 518.4)`、半径 `1100`；stop 0/.76/1 的亮暗常量见 `Qt/src/Glyphs.cpp:807-812`；填充矩形 `(-4096,-4096,8192,8192)`。dark 缺省 false。
- **image**：只按 key 解析，宿主图非空才画；不得把 key 当 URL 或文件路径。

### 2.6 入口前置条件与未知 op

- **抗锯齿前置条件**：整条命令流在 `Qt/src/Glyphs.cpp:595` 的 `c.setRenderHints(QPainter::Antialiasing | QPainter::SmoothPixmapTransform)` 之下执行。Flutter 侧必须保持等价抗锯齿与位图平滑；关掉任一项都会改变边缘像素与缩放采样，属于协议外改动。
- **未知 op 静默跳过**：`Qt/src/Glyphs.cpp:637-829` 是逐条分派，未匹配任何分支的 op 既不绘制也不报错，更不中止后续命令。Flutter 遇到未知 op 必须跳过整条并继续执行后面的命令，不得抛异常、不得清空命令流、不得因未知 op 触发降级重排。
- **文本测量**：`Glyphs::width`（`Qt/src/Glyphs.cpp:286-311`）有两条不同路径。整形串走 `Qt/src/Glyphs.cpp:296-299`，返回 `layoutText(text, weight, size > 0 ? tracking*1000/size : 0).advance * size`，**不扣**尾部 tracking；非整形串走 `Qt/src/Glyphs.cpp:301-306`，返回 `max(0, sum(advance*size + tracking) - tracking)`，即尾部 tracking 被扣除。用它做居中或裁切必须按路径区分：对非整形串漏掉减法会逐字累积偏移，对整形串再套减法同样是错的。
- **整形回退**：`Glyphs::needsLayout`（`Qt/src/Glyphs.cpp:109-139`）在组合附加符、Hangul jamo（U+AC00–U+D7A3 之外）、非 {Common, Inherited, Latin, Han, Hiragana, Katakana, Hangul} 脚本、U+200D、大于 U+FFFF 的码点、方向 R/AL，或主字体与符号字体都缺字时返回真；此时整串改走 `QTextLayout` 整形，基线与 `1.044` 不变，但逐字 `advance` 累加不再适用。Flutter 对这些串必须用等价整形，不得用逐字累加伪造。
- **颜色位置总是被填满**：`NativeHud::fill`（`Qt/src/NativeHud.cpp:37-39`）把颜色写在 `a[1]`；`NativeHud::text`（`Qt/src/NativeHud.cpp:40-43`）与 `NativeHud::art`（`Qt/src/NativeHud.cpp:135-138`）把颜色写在 `a[7]`。三者都对空颜色注入 `ink()`，所以 `fill` 的 `a[1]` 与 `text`/`art` 的 `a[7]` 在实际流里总是被填满；解析器仍按各 op 自己的位置读取，不得因为默认值存在就把颜色挪位，也不得由此推断其它位置（如 `path` 的 `a[4]`/`a[5]`）一定存在。

## 3. hits：六必需字段与唯一 fixed 例外

### 3.1 字段

每个 hit 是 JSON 对象，必需且仅必需：

```json
{"x": 0, "y": 0, "width": 0, "height": 0, "action": "", "label": ""}
```

- `x/y/width/height`：number，舞台坐标矩形；不是物理像素，不是屏幕坐标。
- `action`：string，消费端动作标识。
- `label`：string，无障碍/动作标签。C++ 默认参数为空 QString 时，`NativeHud::hit` 用 `label.isNull() ? action : label`，即省略 label 时它等于 action，不是空串。
- 这个回退只存在于 `NativeHud::hit`（`Qt/src/NativeHud.cpp:102-109`）。PlayerBar 的 `Painter::hit`（`Qt/src/PlayerBar.cpp:46-53`）把传入 label 原样写入，不走 `isNull()` 回退，也不补 action。它的 10 个调用点（`Qt/src/PlayerBar.cpp:85-87,136,150,170,198,204,217,224`）全部传显式非空中文 label（如 `上一首`、`暂停`/`播放`、`下一首`、`当前歌曲歌词`、`播放进度`、`音量`、`播放队列`、`喜欢当前歌曲`）。
- 因此 PlayerBar 的 hit 不得出现空 label：为空既不是 action 也不是合法标签，属于契约失败。

### 3.2 唯一允许的附加字段

仅 PlayerBar 的 `Painter::hit` 在 `Qt/src/PlayerBar.cpp:46-53` 无条件追加：

```json
{"fixed": true}
```

这是 Qt 全仓库唯一产生 `fixed` 的位置。`fixed` 的含义只有一个：`Qt/qml/Overlay.qml:191` 在 modal 打开时跳过 `modalOffset` 的位移，即

```qml
y: area.y + (rhine.state.modal && !modelData.fixed ? rhine.state.modalOffset || 0 : 0)
```

它不是 z，不是层级，不是页面坐标，也不得推广到例如 `music:like-current` 这类恰好不以 `player:` 开头的 PlayerBar hit。判断依据只能是“是否由 PlayerBar 产生”，不是 action 前缀。非 PlayerBar hit 出现 `fixed` 即为契约失败。

### 3.3 顺序、重叠与消费

- hits 的生成顺序就是调用顺序；`NativeHud::draw` 先清空，再按页面绘制顺序 append，PlayerBar 最后绘制（`Qt/src/NativeHud.cpp:252-253,310`），但**只在非 boot 页面**：`Qt/src/NativeHud.cpp:309-311` 是 `if (frame["mode"] != "boot") { playerBar(0, 984, width); }`，所以 boot 页面既不产生 PlayerBar 命令，也不产生任何 PlayerBar hit（包括 `Qt/src/PlayerBar.cpp:170` 那个不以 `player:` 开头的 `music:like-current`），更不存在任何 `fixed`。
- 消费端是 `Qt/qml/Overlay.qml:185-220` 的 Repeater，按 `rhine.hits` 数组顺序创建项；QML 同 z 时后创建的项覆盖先创建的项。**没有 z 排序，也没有按坐标排序。**
- 重叠 hits 的顺序是行为的一部分。例如搜索结果区在 `Qt/qml/Overlay.qml:268-277` 从索引 0 向上扫描，遇到第一个包含点的 `music:result:`/`music:expand:` 就停止；重排会让点击落到另一个 action。
- `fixed` 只影响 modalOffset；不影响数组顺序、命中测试或 z。
- 触摸外扩是消费策略：`Qt/qml/Overlay.qml:38-43` 在 Android 上使用 `touchHitPadding = 16`，在命中测试时临时扩大 x/y/w/h。源 JSON 矩形不得改写，measure/hit/IME 也不得各自维护一套外扩后的矩形。

### 3.4 失败形态

以下任一出现即失败：

- command 是 `{id,opcode,args,seq}` 之类的对象；
- command 或 hit 带 `z`/`frameId`；
- 非 PlayerBar hit 带 `fixed`；
- 按 z 或坐标重排 hits；
- 把相同 command 去重；
- 把触摸外扩写回源 hit 矩形。

### 3.5 参数化 action：fraction 模板

PlayerBar 的进度与音量以**模板**形式注册 hit：

- `Qt/src/PlayerBar.cpp:149-150`：`drawing.seek = QRectF(row.x(), row.y() - 6, row.width(), 18)`，随后 `hit(*drawing.seek, "player:seek-fraction:0", "播放进度")`。
- `Qt/src/PlayerBar.cpp:214-217`：`drawing.volume = QRectF(volumeX, y + 47, 100, 28)`，随后 `hit(*drawing.volume, "player:volume-fraction:0", "音量")`。

这里的 `:0` 是占位，不是已解析的取值。真实指针路径不复用 hit 表：

1. `NativeHud::state()` 在 `Qt/src/NativeHud.cpp:193-194` 发布 `seek`/`volume` 矩形，来源是 `Qt/src/NativeHudPlayer.cpp:40-41` 保存的 `drawing.seek`/`drawing.volume`，与上面两个 hit 是**同一份矩形**。
2. `Qt/qml/Overlay.qml:485-508` 的 Repeater 按 `rhine.state["seek"|"volume"]` 建 MouseArea，`onPressed` 调 `rhine.adjustPlayer(modelData, mouse.x, width)`。
3. `Engine::adjustPlayer`（`Qt/src/Engine.cpp:1016-1021`）先拒绝 `width <= 0` 与非 `seek|volume` 的 control，再拼 `"player:" + control + "-fraction:" + QString::number(clamp(x/width, 0., 1.), 'g', 16)`，即 16 位有效数字的比例。
4. `NativeHudController` 在 `Qt/src/NativeHudController.cpp:369-372` 解析：`seek-fraction` 直接用值、`seek` 用值/20；`volume-fraction` 直接用值、`volume` 用值/10。

因此 hit 矩形必须与被绘制的轨道矩形逐值相同，并与 `state.seek`/`state.volume` 同源。横向触摸外扩必须为 0：`Qt/qml/Overlay.qml:493-497` 只对 y 与 height 加 `touchHitPadding`，注释明确横向保持原样，否则 `mouse.x/width` 的比例会偏。若消费端把模板当动作直接执行，取值为 `0`；Flutter 必须复现“state 矩形 + x/width”的 Qt 路径，不得把 `:0` 当常量，也不得另造比例算法。

### 3.6 modal 期间的命中表替换

- `NativeHud::modalDraw`（`Qt/src/NativeHudModal.cpp:81-256`）在每个 modal 分支内执行 `hits = {}`（`:93` lyrics-offset、`:125` detail-sort、`:147` lyrics-source、`:173` 其余面板），把此前注册的页面 hit **整表清空**，只留 modal 自身 hit。
- `NativeHud::draw` 在 `Qt/src/NativeHud.cpp:306-311` 先 `modalDraw`（`:306-308`）再 `playerBar`（`:309-311`，且带 `frame["mode"] != "boot"` 守卫），所以 PlayerBar hit 在清空之后重新追加（boot 页面例外：那里根本没有 PlayerBar hit）。这正是 `fixed:true` 存在的实际原因：modal 打开时页面 hit 消失、播放条 hit 仍在，且不得被 `modalOffset` 位移。
- modal 内容用 `translate(0, motion.offset)` 绘制，而 hit 坐标按 modal 关闭态登记；`state()` 在 `Qt/src/NativeHud.cpp:205` 发布 `modalOffset = motion.offset`，消费端在 `Qt/qml/Overlay.qml:191` 对非 fixed hit 加回该位移，两边抵消。detail-sort 的全屏收起 hit 因此写成 `hit(0, -motion.offset, width, 1080, "close-modal", "关闭排序菜单")`（`Qt/src/NativeHudModal.cpp:128`）——负 offset 是补偿，不是坐标错误。
- modal 的 `save()` 与 `alpha(motion.opacity)`（`Qt/src/NativeHudModal.cpp:83-84`）在 `restore()`（`:119`、`:139`、`:159`、`:178`、`:185`、`:256`）处闭合；PlayerBar 的 commands 在该 restore 之后追加，所以播放条绘制与 fixed hit 都不受 modal 透明度影响，Flutter 不得额外乘 modal alpha。

## 4. frame：公开顶层字段

`frame` 是 3D 与 HUD 共用的一份渲染帧；HUD 只读其中三个字段：`mode`、`viewer`、`detail`（`Qt/src/NativeHud.cpp:246,257,267-280`，并由 `state()` 在 `:218-219` 复制 `mode`/`viewer`）。其余字段供 3D 渲染器使用，HUD 不得据此发明布局。

### 4.1 基础帧顶层键

以下键由 `NativeScene::emitFrame` 在 `Qt/src/NativeSceneFrame.cpp:87-119` 建立，后续 `NativeCards`/`NativeSceneFrame` 补齐：

| 键 | 类型 | HUD 读取 | 说明 |
|---|---|---|---|
| `pendingAnimations` | bool | 否 | viewer 待处理动画 |
| `pointerCursor` | string | 否 | 光标提示 |
| `aoProjection` | array<number> (16) | 否 | 列主序矩阵 |
| `reference` | bool | 否 | 场景冻结/参考模式 |
| `near` | number | 否 | 基础 5；viewer 0.3 |
| `far` | number | 否 | 基础 300；viewer 120 |
| `viewer` | bool | **是** | 是否 viewer |
| `viewerReady` | bool | 否 | viewer 就绪 |
| `viewerState` | object | 否 | 非 viewer 为空对象；viewer 见 4.2 |
| `mode` | string | **是** | archive/detail/boot 等页面模式 |
| `selected` | number | 否 | 选中索引 |
| `culledCards` | number | 否 | 剔除卡片数 |
| `shadowCards` | number | 否 | 仅阴影卡片数 |
| `returningCards` | number | 否 | 返回动画卡片数 |
| `returningPartNodes` | number | 否 | 返回动画部件数 |
| `globalSubdued` | number | 否 | 全局压暗 |
| `returningMusicKeys` | array<string> | 否 | 返回动画 key |
| `returningAgeMax` | number | 否 | 返回动画最大年龄 |
| `time` | number | 否 | 场景时间 |
| `draws` | array<object> | 否 | 3D 绘制项；HUD 不解释 |
| `view` | array<number> (16) | 否 | 列主序视图矩阵 |
| `projection` | array<number> (16) | 否 | 列主序投影矩阵 |
| `eye` | array<number> (3) | 否 | 相机位置 |
| `background` | array<number> (3) | 否 | 线性 RGB，无 alpha |
| `fogColor` | array<number> (3) | 否 | 线性 RGB，无 alpha |
| `fogNear` | number | 否 | 基础 22；viewer 见 4.2 |
| `fogFar` | number | 否 | 基础 47；viewer 见 4.2 |
| `detail` | number | **是** | detail 过渡值 |
| `boot` | number | 否 | boot 过渡值 |
| `focus` | number | 否 | 焦点/光圈参数 |
| `aperture` | number | 否 | 光圈参数 |
| `actorTemplate` | array<object> | 否 | 角色模板；3D 材质/部件 |
| `appearanceRevision` | number | 否 | 模板代号 |
| `actors` | array<object> | 否 | 每个含 `id`、`musicKey`（可为 null）、`selected`、`shadowOnly` |
| `stats` | object | 否 | 3D 诊断，键见 4.3 |

`draws`、`view`、`projection`、`aoProjection`、`actorTemplate` 的嵌套内容由 RhiScene/Engine 解释；本协议冻结其顶层键名与容器类型，不把嵌套的 eye/fog 等非顶层键写成 HUD 契约。未知顶层键必须忽略，不得据此改变 HUD 布局。

### 4.2 viewer 模式覆盖

`NativeViewer::frame` 在 `Qt/src/NativeViewer.cpp:276-354` 只在 viewer 打开时改写：

- `viewer = true`，`viewerReady = m_ready`；
- `near = 0.3`，`far = 120`；
- `view`、`eye`、`projection` 重算；projection 为 34° 透视，`aspect < 1.05` 时对 x/y 缩放做 zoom 分支；
- `fogNear = max(0, |eye| - 1)`，`fogFar = |eye| + 12`；
- `draws = []`；
- `actorTemplate` 只保留 viewer 需要的部件，附 `partIndex`、`mesh`、`asset`、`side`、`castShadow`、`localMatrix`；
- `actors = [{"id":100000,"musicKey":null,"selected":true,"shadowOnly":false}]`；
- `viewerState = {"transition":..., "surface":..., "exploded":"true"|"false", "stats":"<compact JSON string>"}`。其中 `stats` 是字符串，不是对象；解析后包含 `ready`、`clarity`、`targetClarity`、`spread`、`target`、`distance`、`targetPosition`、`requestedTarget`、`requestedDistance`、`cameraPosition`、`resetting`、`azimuth`、`polar`。

### 4.3 stats 顶层键

`stats` 由 `Qt/src/NativeSceneFrame.cpp:195-213` 建立，包含：

`loaded` (bool)、`fieldOfView`、`decryption` (object)、`topLeft`/`topRight`/`labelTopLeft`/`labelBottomLeft` (array<number> 2)、`modelPosition`/`cameraPosition` (array<number> 3)、`selectedCell`/`coordinateOrigin` (`{lane,row}`)、`selectedSlot`、`archiveCount`、`archiveCandidates`、`returningFiles`、`pulses` (array)、`clearance`、`holdingArchive`。

### 4.4 Engine 追加键（不属于 HUD draw 输入）

`Engine::step` 在 `Qt/src/Engine.cpp:1143` 之后为渲染器追加：

- `jitter`：array<number>(2)，仅抗锯齿抖动开启时（`:1196-1202`）；
- `temporalReset`：bool，仅待重置时（`:1203-1206`）；
- `discAngle`：number，唱片角度（`:1248`）。

这些键在 `NativeApplication::step` 返回对象和 `hud.draw` 的输入中不存在；Flutter 不得把它们当作 HUD 字段，也不得要求 Qt 的 HUD 对象携带它们。

### 4.5 同代次发布

- 同一刷新周期内，`frame`、`commands`、`hits`、`state` 必须来自同一次 step/draw；不得把上一帧的 commands 与下一帧的 hits 拼接。
- 命令流变化必须触发一帧呈现；仅 `setState` 不保证呈现帧。Qt 侧由 `Engine.cpp:1401` 的 `hudChanged` 通知渲染；Flutter 侧必须有等价的“命令流变化 → 请求呈现帧”测试。
- `generation` 只做一致性校验；发现错配时丢弃整份快照，不能只丢弃 commands 或只丢弃 hits。

## 5. 舞台几何：measure、hit、IME 同源

横屏 Qt 公式：

```text
stageScale = heightLogical / 1080
stageWidth = widthLogical / stageScale
```

`Qt/qml/Overlay.qml:22-23` 与 `Qt/qml/Main.qml:32-33` 使用同一公式；输入坐标除以 `stageScale`，state 的 input 矩形乘以 `stageScale`，hits 直接使用舞台坐标。measure、hit、IME 必须共用这一份 geometry；禁止 HUD 用 stage 坐标、触摸用物理坐标、IME 用第三套坐标。

竖屏是新增重排设计：由可用窗口、安全区与 IME 共同计算一份 layout geometry，再由它同时输出 draw 与 hit；不得把横屏公式套到竖屏，也不得声称存在 Qt 竖屏基线。横屏 Qt 已取证的行为才是 1:1 目标；竖屏只保留语义并重排。

## 6. Fixture 与测试映射

本任务只写代码/fixture，不执行测试（用户明令禁止所有构建、测试、analyze、run、Gradle、pub get、代码生成、formatter、设备与性能验证）。测试的静态审查由独立 reviewer 完成；设备证据标记 `DEVICE_BLOCKED`。本节冻结的是 fixture 与测试必须满足的形状与断言，不是对现有文件的排点：`test/fixtures/hud_commands_17.json`、`test/fixtures/hud_hits.json` 是本切片已产出的待提交 fixture；`test/hud_protocol_test.dart` 为本切片已产出的待提交测试草稿，只做静态审查，不执行。

### 6.1 `test/fixtures/hud_commands_17.json`

- `commands`：17 条，恰好每个 op 一条，顺序为 `save → ... → restore`；用于断言 op 名称与参数位置。
- `duplicates`：两条逐项相同的 `fill`，用于锁定“合法相同命令不得去重”。
- `shortPath`：4 项 `path`，用于锁定 dash/offset 可省略、默认实线。
- `envelope`：声明 `generation` 只做一致性校验、`deduplicateCommands:false`、`reorderHits:false`。
- 覆盖：save/restore、alpha 乘算、translate/scale/rotate、clip、fill/ellipse 的 color 在 a[1]、text/art 基线差异、path dash 归一化、arc 弧度、right-mask 16 段、gradient 固定中心、image。

### 6.2 `test/fixtures/hud_hits.json`

- 基础六字段样例（settings、搜索结果）；
- 两个重叠的搜索结果 hit，锁定源顺序（result 在 expand 前，不按 z 排序）；
- PlayerBar 的 `fixed:true` 样例，包含 `music:like-current` 这种非 `player:` 前缀但由 PlayerBar 产生的 hit，证明判断依据是来源而非前缀；
- `playerBarIndices` 明确哪些 hit 允许 `fixed`；
- 所有非 PlayerBar hit 不得含 `fixed`，不得含 `z`。

### 6.3 `test/hud_protocol_test.dart`（本切片草稿，未执行）

测试断言：

1. 17 条命令都是数组，`a[0]` 名称与 `expectedOpOrder` 全等；不存在对象信封。
2. 每个 op 的数组长度与参数位置/类型精确匹配；颜色第 4 项 alpha、第 5 项 calibrated 标记不被误读。
3. `duplicates` 两条逐项相同且都保留；`shortPath` 为 4 项且可按默认实线解释。
4. hits 每项键集合为六字段；仅 `playerBarIndices` 的项额外有且仅有 `fixed:true`；其余项无 `fixed`；无 `z`。
5. hits 的 action 顺序与 `expectedOrder` 全等；重叠矩形不触发重排。
6. frame 的 HUD 必需键 `mode`/`viewer`/`detail` 为顶层字段；不把 Engine 的 `jitter`/`temporalReset`/`discAngle` 当作 HUD 字段。

测试只读本地文件（两个 fixture 与契约文档）与文件内联的最小 frame 样例；不访问设备、不启动应用、不写生产文件。

## 7. 源索引

| 主题 | 源 |
|---|---|
| 17 op 分派 | `Qt/src/Glyphs.cpp:637-829` |
| 颜色/校准 | `Qt/src/Glyphs.cpp:35-49` |
| text/art | `Qt/src/Glyphs.cpp:530-588` |
| 命令/命中清空与 PlayerBar 最后绘制 | `Qt/src/NativeHud.cpp:223-312` |
| hit 六字段 | `Qt/src/NativeHud.cpp:102-109` |
| PlayerBar fixed | `Qt/src/PlayerBar.cpp:46-53` |
| 同 step 发布 | `Qt/src/NativeApplication.cpp:98-151` |
| Engine 消费/追加 | `Qt/src/Engine.cpp:1103-1143,1196-1206,1248,1348-1416` |
| 帧字段 | `Qt/src/NativeSceneFrame.cpp:87-213` |
| viewer 覆盖 | `Qt/src/NativeViewer.cpp:276-354` |
| hits 消费/外扩 | `Qt/qml/Overlay.qml:38-43,185-220,268-277` |
| stage 公式 | `Qt/qml/Overlay.qml:22-23`，`Qt/qml/Main.qml:32-33` |
| 计划契约 | `docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:183-214,762,827-865` |

## 8. 冻结边界与未决项

- T01 的 session/QSettings/AppStorage/凭据冻结在本文件写作时尚未合并；本文件只按当前 Qt 源码冻结 HUD 协议，T01 发布后核对引用，不改变已冻结的数组形状、字段集合和顺序规则。
- 生产桥接/接线未实现，`ARCH_BLOCKED`；没有设备截图、性能或运行记录，`DEVICE_BLOCKED`。不得把静态契约审查写成设备通过。
- 旧 Flutter 实现不是规范；不得从旧 UI 反推命令/命中字段。
- 本文件不定义 Qt 竖屏基线；竖屏重排是新增设计，只保留语义。
