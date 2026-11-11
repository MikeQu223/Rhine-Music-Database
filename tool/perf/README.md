# 帧时间采集协议（T52-D02）

- 状态：协议文档，不是测量报告，也不是性能承诺。仓库当前没有 JSONL 样本，采集器尚未执行；`tool/perf/` 只有 `collect_frame_times.dart`（1518 行，revision `T52-S01`）。
- 适用对象：`tool/perf/collect_frame_times.dart`。本文件描述「输入长什么样、怎样被校验、拒绝怎样计数、统计怎样派生、输出怎样读」。
- 本文件不定义通过/失败，不定义帧率、jank、内存或启动的目标值；采集器本身也没有阈值与判定（`thresholds: 'none'`、`verdicts: 'none'`，collector :600-638）。
- 方法背景与指标族见 `docs/flutter-migration/03-performance.md`。本文件只写协议；两份文件都不替代设备采集。

## 1. 范围与边界

采集器是纯 Dart 离线工具：

- 只 import `dart:convert` 与 `dart:io`（collector :59-60；报告 tool 段亦只列这两项，:582-589）。
- 不 import Flutter，不联网，不 fork 子进程，不调用 adb 或任何外部命令（collector :211-212）。
- 只读一个 JSONL 输入文件，只写一个 JSON 报告文件；不读设备、不读日志、不读截图。
- 不判断「好/坏」，不给「通过/失败」，不计算 fps，不定义 jank。

因此采集器能回答的是「这批被接受的帧，其分布/跨度/峰值是多少」；不能回答「是否达到 60 fps」「是否卡顿」「是否比 Qt 好」。后者需要冻结后的验收流程与设备日志。

## 2. 输入格式

输入是 UTF-8 文本，每行一个 JSON 对象，一行一个帧样本。空行（`trim()` 后为空）只计入 `input.blankLines`，不构成记录（collector :337-346）。文件末尾的换行不会被当成额外空行（:327-332）。每行可带 `\r`，读取时去掉行尾 `\r`（:339-341）。UTF-8 BOM 会被去掉（:324-326）。

### 2.1 必填字段（9 个，顺序即缺失检查顺序）

| # | 字段 | JSON 类型 | 约束 | 语义 | 读取行 |
| --- | --- | --- | --- | --- | --- |
| 1 | `deviceId` | string | `trim()` 后非空 | 设备稳定标识 | :444-453 |
| 2 | `sceneId` | string | `trim()` 后非空 | 冻结后的场景标识 | :444-453 |
| 3 | `runId` | string | `trim()` 后非空；一个 run 只对应一个 device+scene | 单次采集标识 | :444-453 |
| 4 | `frameIndex` | int | >= 0；必须是 JSON 整数，`1.0` 被拒 | run 内帧序号 | :455-464 |
| 5 | `frameTimeMs` | num | 有限且 >= 0 | 帧耗时（ms） | :466-479 |
| 6 | `timestampMs` | int | >= 0；必须是 JSON 整数，`1.0` 被拒 | 帧时间戳（epoch ms） | :455-464 |
| 7 | `firstFrame` | bool | true/false | 是否启动后首帧标记 | :481-487 |
| 8 | `memoryMb` | num | 有限且 >= 0 | 该帧上报内存（MiB） | :466-479 |
| 9 | `startupMs` | num | 有限且 >= 0 | 生产者自报启动耗时（ms） | :466-479 |

说明：

- string 字段只做「trim 后非空」校验，值本身不 trim；带首尾空白的标识符会被 `runs[].integrity.identifiersPadded` 标出（collector :629-632、:831-837）。`" opd2511"` 与 `"opd2511"` 是两个设备，不会被悄悄合并。
- int 字段必须是 JSON 整数。`1.0` 在 Dart 中解码为 double，会被判 `field_wrong_type`，不是「宽容地取整」。
- num 字段允许整数值的 JSON 数，统一转 double 存储；`NaN`/`Infinity` 不是合法 JSON，但若生产者构造出非有限值，会被判 `non_finite_value`。
- 未知字段不拒绝，只计数（见 §4.4）。生产者可以带额外调试字段，但不要依赖它们被消费。

### 2.2 输入示例

以下仅是格式示例，不是实测数据，不得复制成证据：

```json
{"deviceId":"526f6b6d","sceneId":"archive_idle_landscape","runId":"r-001","frameIndex":0,"frameTimeMs":16.7,"timestampMs":1700000000000,"firstFrame":true,"memoryMb":412.5,"startupMs":1830.2}
```

## 3. 读取与校验顺序

对每一行，校验顺序是固定的；这保证「同一行坏多处」时拒绝原因稳定、可跨报告聚合。

1. JSON 语法解析。失败 ⇒ `json_syntax_error`（collector :383-389）。
2. 顶层必须是对象。数组、字符串、数字、null ⇒ `line_not_a_json_object`（:390-396）。
3. 按 §2.1 的 9 个字段顺序检查「键是否存在」。第一个缺失字段决定 `missing_field` 的 `field`（:405-409）。
4. 按读取顺序校验值：
   `deviceId` → `sceneId` → `runId` → `frameIndex` → `frameTimeMs` → `timestampMs` → `firstFrame` → `memoryMb` → `startupMs`（:410-440）。
5. 每个字段先判类型，再判值域：string 判非空、int 判 >=0、num 判有限且 >=0、bool 判布尔（:444-487）。
6. 记录该行的未知字段（不拒绝），把样本加入解析结果。

一行只产生一个拒绝原因：遇到第一个失败就抛出，不会把该行部分字段保留（:383-440）。因此不存在「半条样本」。

## 4. 拒绝模型

### 4.1 行级拒绝原因（固定顺序）

报告中的 `rejections.byReason` 预种以下 7 个键，即使计数为 0 也会出现（collector :111-120、:560-566）：

| 顺序 | reason | 触发条件 |
| --- | --- | --- |
| 1 | `json_syntax_error` | 该行不是合法 JSON |
| 2 | `line_not_a_json_object` | JSON 顶层不是对象 |
| 3 | `missing_field` | 9 个必填字段中至少一个缺失；报告给第一个缺失字段名 |
| 4 | `field_wrong_type` | 字段类型不符（string/int/num/bool） |
| 5 | `empty_identifier` | deviceId/sceneId/runId 为字符串但 trim 后为空 |
| 6 | `negative_value` | int 或 num 字段为负 |
| 7 | `non_finite_value` | num 字段不是有限值 |

### 4.2 拒绝样例

- `rejections.examples` 最多 8 条（`_maxRejectionExamples = 8`，collector :74），按输入行号顺序取前 8 条，不做抽样、不按原因挑（:567-578）。
- 每条样例含 `line`、`reason`、`field`、`detail`。
- 超过 8 条的拒绝仍计入 `total` 与 `byReason`，只是不逐条列出。需要看全部时，回到原始 JSONL 按行号核对。

### 4.3 一行被拒的后果

- 该行不进入任何 run，不参与任何分布、跨度、峰值。
- 其他行照常处理；不会被连带拒绝。
- 报告不会因为存在拒绝行而失败退出；只要输入有至少一条记录，报告就会写出（即使 0 条被接受）。

### 4.4 未知字段

- 未知字段不会被拒绝，也不会被消费；报告在 run 级 `integrity` 中给出 `unknownFieldCount`、`unknownFields`、`recordsWithUnknownFields`（collector :719-722、:813-817）。
- 未知字段是 schema 漂移信号：如果生产者新增了影响语义的字段，采集器不会解释它。评审时必须人工确认「这个字段是否应该进入协议」，不能默认它已被统计。

## 5. run 冲突：全量拒绝，不做部分保留

一个 `runId` 只能对应一个 `(deviceId, sceneId)` 组合（collector :490-521）。判定方式：

1. 先按 `runId` 分组；
2. 再在每个 `runId` 内按 `(deviceId, sceneId)` 分组；
3. 若一个 `runId` 下出现 2 个及以上不同组合，则该 `runId` 的所有帧全部拒绝，记入 `rejectedRuns`，reason `identifier_conflict`（:547-556）。

拒绝报告的字段：`reason`、`runId`、`frameCount`、`identityCount`、`identities`、`decision`。`decision` 原文是「every frame carrying this runId is rejected; conflicting rows are never partially kept」。

这条规则是防污染的硬约束：不得把一个冲突 run 的帧拆到多个 runId 里规避；不得只保留「看起来正常」的那一组。冲突帧计入 `conflictedRunFrames`，不进入 `acceptedFrames`。

## 6. 计数与守恒

`counts` 恰有 6 个键（collector :639-646）：

| 键 | 含义 |
| --- | --- |
| `records` | 非空行数（空行不算） |
| `acceptedFrames` | 进入被接受 run 的帧数 |
| `rejectedLines` | 行级拒绝数 |
| `conflictedRunFrames` | 因 runId 冲突被整体拒绝的帧数 |
| `acceptedRuns` | 被接受的 run 数 |
| `rejectedRuns` | 冲突 run 数 |

守恒式（collector :636-637）：

```text
records == acceptedFrames + rejectedLines + conflictedRunFrames
```

读报告时必须先核对这条等式。等式不成立说明报告被手改、输入被替换或工具版本不一致；此时所有结论作废，记 `UNMEASURED`。

## 7. 派生规则

### 7.1 排序

- 样本：按 `(timestampMs, frameIndex, line)` 升序（collector :289-298、:610-612）。
- runs：按 `(deviceId, sceneId, runId)` 升序（:522-525、:610-612）。
- 拒绝样例：按行号升序（:567-578、:610-612）。

排序是确定性的；同一输入必须得到同一顺序。

### 7.2 分位与舍入

- 分位：nearest-rank，`ceil(q*n)-1`，夹到 `[0,n-1]`，不插值（collector :238-250、:609）。
- 分布字段：`count`、`min`、`p50`、`p95`、`p99`、`max`、`mean`（:278-286）。
- 派生值保留 6 位小数；直接来自样本的值（`samples[].*`、`memoryPeakMb.value`、`startupMs.value`、`firstFrame.frameTimeMs`）原样回显，不改写（:613-616、:216-229）。
- 空序列的分布是 `null`，不是 0（:252-262）。读作「无样本」。

### 7.3 run 级摘要

每个被接受的 run 含（collector :665-828）：

- `runKey`、`deviceId`、`sceneId`、`runId`、`frameCount`、`lineRange{first,last}`。
- `summary.frameTimeMs`：§7.2 的分布。
- `summary.firstFrame`：`present`、`markerCount`、`frameIndex`、`timestampMs`、`frameTimeMs`、`offsetFromRunStartMs`、`indexInTimeOrder`。无标记时 `present=false`，其余为 null（:742-762）。
- `summary.memoryPeakMb`：`value`、`timestampMs`、`frameIndex`（:790-794）。
- `summary.startupMs`：`value`（最早样本的 startupMs）、`basis`、`distinctValueCount`、`distinctValues`（最多 8 个）、`distinctValuesTruncated`（:795-801）。
- `summary.timestampRange`：`firstTimestampMs`、`lastTimestampMs`、`spanMs`。
- `summary.frameIndexRange`：`min`、`max`、`distinctCount`。
- `integrity`：`identifiersPadded`、`unknownFieldCount`、`unknownFields`、`recordsWithUnknownFields`、`duplicateFrameIndexCount`、`nonIncreasingFrameIndexCount`、`firstFrameMarkerCount`。
- `stability`：见 §8。
- `samples`：逐帧回显 `line`、`frameIndex`、`frameTimeMs`、`timestampMs`、`firstFrame`、`memoryMb`、`startupMs`；数值统一为 JSON double。

### 7.4 首帧偏移不是启动延迟

`offsetFromRunStartMs` 的定义是「标记帧的 timestampMs 减该 run 第一个样本的 timestampMs」（collector :742-762）。它不包含生产者开始记录之前的时间；不能把它叫作「启动到首帧耗时」。同理，`startupMs` 是生产者自报值，采集器不验证起止点。详见 `03-performance.md` §5.3。

## 8. 30 分钟稳定语义

采集器默认窗口 `30.0` 分钟（collector :68），窗口毫秒数 = 分钟 × 60000 四舍五入（:1323-1324），窗口切成 6 段（:71）。窗口长度可由 `--window-minutes` 覆盖，但必须为正有限数且窗口 >= 6000 ms（:1325-1329、:1356-1362）。

`stability` 的关键字段（collector :839-945）：

| 字段 | 含义 |
| --- | --- |
| `status` | `MEASURED` iff `observedSpanMs >= requiredSpanMs`；否则 `UNMEASURED` |
| `statusRule` | 原文规则：跨度 = 末样本时间戳 - 首样本时间戳 |
| `durationBasis` | 只用 timestampMs；样本数与帧时间和不能推断时长 |
| `windowMinutes`/`windowMs`/`requiredSpanMs` | 协议常量 |
| `observedSpanMs` | 实际首末跨度 |
| `shortfallMs` | 不足窗口时 = 窗口 - 跨度；满足时为 0 |
| `windowCount` | `observedSpanMs ~/ windowMs + 1`；短 run 也至少有 1 个窗口 |
| `fullySpannedWindows`/`partialWindows` | 完整覆盖窗口数 / 部分窗口数 |
| `sampleCount` | 样本数；仅作参考 |
| `sampleCountUsedForDuration` | 恒为 `false`（:936） |
| `largestGapMs`/`largestGapStartTimestampMs` | 相邻样本最大间隙及起点 |
| `windowDriftRollup` | 跨窗口漂移汇总，见 §8.2 |
| `windows[]` | 每窗口的样本分布与 drift |

### 8.1 窗口状态

- 窗口未满（`endTimestampMs > lastTimestampMs`）⇒ 该窗口 drift `NOT_EVALUATED`，reason `window_not_fully_spanned`（collector :1054-1061）。
- 窗口内非空段少于 2 ⇒ `NOT_EVALUATED`，reason `fewer_than_two_non_empty_segments`（:1062-1069）。
- 否则 `EVALUATED`，比较首末非空段的 `frameTimeMs.p50`、`frameTimeMs.p95`、`memoryMb.peak`（:1070-1108）。
- `NOT_EVALUATED` 不等于「漂移为 0」，也不等于「稳定」。报告中必须原样保留该状态。

### 8.2 漂移只给带符号差值

每个 marker 含 `metric`、`unit`、`fromSegment`、`toSegment`、`fromValue`、`toValue`、`delta`、`ratio`、`direction`（collector :1236-1246）；`markerSemantics` 原文是「signed deltas only; no threshold and no pass/fail verdict」（:82-83、:1100-1108）。

- `ratio` 在较早值为 0 或商非有限时为 `null`（:620-622）。
- 跨窗口 rollup 只汇总 EVALUATED 窗口，三个指标固定出现；没有阈值（:1111-1199）。
- 不得把 `delta > 0` 自动读作「退化」，也不得把 `delta == 0` 读作「通过」；方向和幅度只是描述。

### 8.3 稳定性不等于无崩溃

采集器不读 logcat，不知道是否发生崩溃、ANR 或 OOM。`stability.status == MEASURED` 只表示「样本时间跨度覆盖了窗口」。稳定门还需要设备侧日志与时间对齐（见 `03-performance.md` §4.3、§8）。

## 9. 输出报告

报告是 UTF-8 JSON，缩进 2 空格，末尾一个换行（collector :163-164）。顶层键（:580-654）：

| 键 | 内容 |
| --- | --- |
| `schema` | `rhine.frame-times/1`（:65） |
| `tool` | `path`、`revision`、`language`、`imports`、`importsFlutter:false`、`spawnsProcesses:false`、`network:false` |
| `input` | `path`、`bytes`、`fingerprintFnv1a32`、`lines`、`blankLines`、`records` |
| `contract` | 字段表、窗口、分位方法、排序、舍入、时长基准、比值规则、drift 规则、`thresholds:'none'`、`verdicts:'none'`、`deviceData`、标识符规则、accountingRule |
| `counts` | 6 个计数，见 §6 |
| `rejections` | `total`、`byReason`、`examples` |
| `rejectedRuns` | 冲突 run 列表，见 §5 |
| `runs` | 被接受 run 列表，见 §7.3 |

报告不含生成时间、主机名、用户名、命令行、随机 ID。同一输入 + 同一 revision 应产生同字节报告（除输出路径不同外，报告里只记输入路径）。

`input.fingerprintFnv1a32` 是 FNV-1a 32 位指纹，只用于绑定输入字节，**不是安全哈希**（collector :373-381）。证据完整性请另记 SHA256。

写入采用「同目录临时文件 + rename」，失败会清理临时文件；父目录不存在时会创建（collector :1249-1269）。因此正常退出时不会留下半截报告。

## 10. CLI 与退出码

```text
dart run tool/perf/collect_frame_times.dart --in <jsonl> --out <json> [--window-minutes 30]
```

| 退出码 | 含义 | 是否写报告 |
| --- | --- | --- |
| 0 | 报告已写出 | 是（即使 0 个 run） |
| 0 | `-h`/`--help` | 否（只打印用法） |
| 1 | 报告写入失败 | 否（临时文件会清理） |
| 2 | 参数错误 / 输入不可读 / 非 UTF-8 / 无记录 | 否 |

补充：

- 输入没有非空记录 ⇒ 退出码 2，不写报告（collector :155-160）。
- 输入有记录但全部被拒 ⇒ 报告照写，`runs: []`，退出码 0。退出码 0 只表示「报告已写出」，不表示「有可用样本」。
- `--window-minutes` 只接受正有限数；窗口换算后小于 6000 ms 会被拒（:1325-1329）。
- `--in=x` 与 `--in x` 两种写法都支持；缺值会报参数错误（:1298-1354）。

## 11. 确定性与可重放

- 采集器不写墙钟时间、不生成随机 ID、不依赖环境变量；同一输入与 revision 的输出可逐字节比对。
- 报告通过 `input.bytes` 与 `fingerprintFnv1a32` 绑定输入；归档时必须同时保留原始 JSONL。
- 原始 JSONL 不得手改；被拒行不得删除；冲突 run 不得拆分。
- 报告不得手工编辑；需要修正时重跑采集器，并在元数据中记录新旧两份。
- 评审时至少核对：守恒式、`counts` 与 `rejections.total`、`input.records`、`stability.observedSpanMs`、`thresholds/verdicts` 仍为 `none`。

## 12. 本工具不做什么

- 不采集：不读设备、不读 logcat、不截图、不调用 adb、不启动应用。
- 不判定：没有阈值、没有通过/失败、没有「达标」字段、没有 jank 定义、没有 fps 计算。
- 不补齐：缺失窗口记 `UNMEASURED`，缺失段记 `NOT_EVALUATED`，空序列记 `null`；不编 0，不外推。
- 不比较：不把两个 run 自动比出胜负；跨实现对比由人按 `03-performance.md` §5.4 执行。
- 不承诺：本文件与采集器都不承诺任何帧率、延迟、内存或启动目标。冻结前所有指标都是「拟议待冻结」。

## 13. 采集步骤（待执行，本文件不执行）

1. 冻结场景与 sceneId；写清 idle/active、方向、主题、账号态、数据规模、播放态、网络态。
2. 实现帧时间生产者；写明帧时间起止点、内存采样口径、startupMs 起止点、首帧标记插入点。
3. 在设备 `526f6b6d` 上安装待测包；记录 APK SHA256、commit SHA、证书 SHA256（只记证书）。
4. 跑短分布 run 与 30 分钟稳定 run；每 run 单独 runId；同时收 logcat 与热状态/刷新率。
5. 运行 §10 的命令；保存原始 JSONL、报告、外围记录。
6. 核对 §11 的守恒与字段；由独立 reviewer 复核后再进入阈值冻结讨论。
7. 任何一步没有证据，对应指标保持 `UNMEASURED`。

以上步骤全部**未执行**；本原子禁止 build/test/analyze/adb/性能采集。

## 14. 当前状态

| 项 | 状态 | 依据 |
| --- | --- | --- |
| JSONL 输入 | 不存在 | `tool/perf/` 只有采集器 |
| 采集器执行 | 未执行 | 本原子禁令 |
| 报告 | 不存在 | 无输入 |
| Flutter 性能 run | 0 | 未采集 |
| Qt 性能 run | 0 | 未采集 |
| 30 分钟 run | 0 | 未采集 |
| 证据等级 | 无 E0 性能证据 | `02-adjudication.md:14` E0=0 |

## 15. 变更记录

- 2026-11-12：创建协议文档。只描述采集器既有行为；未执行采集器，未生成样本或报告，未定义任何性能目标。
