#!/usr/bin/env python3
"""逐 ROI 比较 slice 证据（只读、确定性、仅标准库）。

调用：
    compare.py --fixture <slice_cases.json> --units <units.jsonl> --out <report.json>
               [--candidate A,B] [--step S2,S4]

判据来源（本文件不含任何阈值数值，只绑 id；值和状态一律读 fixture）：
    test/fixtures/slice_cases.json      steps[].rois / rois[] / thresholds[] / capture / verdicts / unmeasured
    docs/flutter-migration/01-slice.md  §4 unit 形状（:130-153）、§5 ROI 表与比较类型（:154-209）、
                                        §7 预登记判据、§8 未测量清单
    contracts/hud-protocol.md           §3.1/§3.3 hits 六字段与 fixed、§4 frame 顶层键、§4.5 同代发布
    Qt/src/NativeHud.cpp:175-219        state() 实际键：:192 playerBounds、:193 seek、:194 volume、:218 mode；
                                        没有 seekable / durationMs / hasTrack / applicationVolume
    Qt/src/NativeHudPlayer.cpp:39-41    state.seek / state.volume 直接取 PlayerBar 的 drawing.seek / drawing.volume
    Qt/src/PlayerBar.cpp:148-149        drawing.seek 只在 seekable && durationMs>0 时赋值
    Qt/src/PlayerBar.cpp:212-214        drawing.volume 只在 applicationVolume 时赋值

判定模型（每行 = candidate × step × roi）：
    PASS        该 ROI 的判据被完整测量，且落在冻结容差内
    FAIL        已证伪：ROI 的 state 锚点与 fixture 矩形不一致，或 frame 不是自洽的真实 3D draw
    UNMEASURED  其余一切（阈值未冻结或无值、无锚点、无载荷、采样不足、条件不成立）

    FAIL 优先于 UNMEASURED：已发现的缺陷不得被「还没测完」掩盖。
    PASS 必须同时满足：采样达标、条件成立（若声明了 conditional）、阈值 FROZEN 且带数值、
    判据被完整测量。退出码 0 仅当全部行 PASS；存在 UNMEASURED/FAIL 为 1；输入错误为 2。

确定性：
    json.dumps(sort_keys=True, indent=2, allow_nan=False) + 固定换行；计算出的浮点统一格式化成
    固定 9 位小数科学记数（_fmt_delta）；不写时间戳、随机数、绝对路径、环境信息；不联网、不读设备、
    不起子进程。只有三个 I/O 入口（load_fixture / load_units / write_report），其余全是纯函数。
"""

import argparse
import json
import math
import re
import sys

EXIT_ALL_PASS = 0
EXIT_NOT_PASS = 1
EXIT_INPUT = 2

REPORT_SCHEMA = "slice-compare-report/v1"
FIXTURE_SCHEMA = "slice-cases/v1"

# 比较类型 -> 阈值 id。这里只绑 id：数值、状态、适用范围全部来自 fixture.thresholds，
# 本文件不存任何默认阈值，也不给任何比较类型内置容差。
#   layout  : §5「静态 stage 矩形容差 1e-6」                      => th.stage.metric
#   scene3d : §5/§7「view/projection/eye 自洽」+ plan :159 1e-9    => th.frame.matrix
#   pixels  : §5「整块裁切逐像素」；th.pixels.ssim 是 PROPOSED_UNFROZEN => 不是门，只能 UNMEASURED
#   text    : 文本度量跨引擎无基线（§8 末条）                        => th.hit.textDerived（value=null）
#   glyph   : 字形 advance 派生，同 text                           => th.hit.textDerived（value=null）
THRESHOLD_BINDING = {
    "layout": "th.stage.metric",
    "scene3d": "th.frame.matrix",
    "pixels": "th.pixels.ssim",
    "text": "th.hit.textDerived",
    "glyph": "th.hit.textDerived",
}

# 这些比较类型在 slice-unit/v1 里没有可比载荷（01-slice.md:134-138：unit 只有
# commands/hits/frame/state），只能判 UNMEASURED，不得用相邻阈值顶替。
UNMEASURABLE_KINDS = ("pixels", "text", "glyph")

PAYLOAD_NOTES = {
    "pixels": "payload:pixels — slice-unit/v1 无像素载荷，且 §8 首条「像素 1:1：无同设备同场景 Qt 基线截图」",
    "text": "payload:text — commands 含文本绘制项，但无跨引擎文本度量基线（§8 末条「文本度量跨引擎一致性…未测量」）",
    "glyph": "payload:glyph — 字形路径与 1.044 行为无跨引擎基线（§8 末条），只能人工对照",
}

# 覆盖判据的参数一律拒绝（出现即 exit 2）：判据的唯一来源是 fixture.thresholds。
FORBIDDEN_FLAGS = (
    "--threshold",
    "--thresholds",
    "--tolerance",
    "--tolerances",
    "--global-score",
    "--global_score",
    "--score",
    "--scores",
    "--override",
    "--overrides",
    "--ssim",
    "--delta-e",
    "--deltae",
    "--eps",
)

# fixture.thresholds[].status 的取值域；只有 FROZEN 有资格当门（见 §7）。
FROZEN_STATUS = "FROZEN"

CONTAINER_FIELDS = (
    ("commands", list),
    ("hits", list),
    ("frame", dict),
    ("state", dict),
    ("current", dict),
    ("session", dict),
)

GENERATION_FIELDS = ("commands", "hits", "frame", "state")

MAX_FAILURE_LINES = 5

CONVENTIONS = {
    "row": "一行 = candidate x step x roi；step/roi/candidate/verdict/metrics/evidence 必含。",
    "verdict": "PASS=判据完整测量且在冻结容差内；FAIL=已证伪；UNMEASURED=其余一切。FAIL 优先于 UNMEASURED。",
    "thresholds": "阈值只按 id 绑定，值/状态一律读 fixture.thresholds；未冻结或无值的阈值只能判 UNMEASURED，禁止写成 PASS。",
    "conditional": "conditional=true 表示该 ROI 参与 PASS 判定；false 表示条件不成立或无法判定，不参与 PASS。conditionalState 记录 satisfied/unsatisfied/unknown/notDeclared。",
    "sampling": "每步有效 unit 数必须 >= capture.minUnitsPerStep + capture.extraUnits[step]，否则该步所有 ROI 判 UNMEASURED。",
    "generation": "同一 unit 的 commands/hits/frame/state 必须同代；缺字段或代次不一致整份快照丢弃并记入 discardedUnits（hud-protocol.md §4.5）。",
    "determinism": "键排序、固定缩进、固定浮点格式；无时间戳、随机数、绝对路径。",
    "scope": "本工具只比较 ROI 判据；fixture.checks 由 hud_protocol_test 与现场采集核对，不折算成分数。",
}


class InputError(Exception):
    """输入不满足契约：main() 打印原因并以 EXIT_INPUT 退出，不产出报告。"""


# ---------------------------------------------------------------- 基础工具（纯函数）


def _is_number(value):
    """JSON 数字；布尔不算数字（Python 里 True 是 int 的子类）。"""
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _finite(value):
    return _is_number(value) and math.isfinite(float(value))


def _text(value):
    """JSON 值的稳定文本形态，用于 evidence 字符串。"""
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True)
    except (TypeError, ValueError):
        return repr(value)


def _component(value):
    """输入坐标系里的数字：整数保持整数形态，浮点用最短可逆表示（repr 决定，跨运行稳定）。"""
    if not _is_number(value):
        return None
    number = float(value)
    if not math.isfinite(number):
        return None
    if number.is_integer():
        return int(number)
    return float(repr(number))


def _fmt_rect(rect):
    if rect is None:
        return "null"
    return "(" + ", ".join("null" if item is None else str(item) for item in rect) + ")"


def _fmt_delta(value):
    """计算出的浮点：固定 9 位小数科学记数，能表达 1e-9 级残差且跨平台稳定。"""
    number = float(value)
    if abs(number) < 1e-12:
        number = 0.0
    return "{:.9e}".format(number)


def _sanitize(value):
    """把非有限浮点换成 null，保证 allow_nan=False 也能稳定落盘。"""
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, dict):
        return {key: _sanitize(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_sanitize(item) for item in value]
    return value


def _cap(lines, limit=MAX_FAILURE_LINES):
    if len(lines) <= limit:
        return list(lines)
    return list(lines[:limit]) + ["...(+{} more)".format(len(lines) - limit)]


def _unit_order(unit):
    """unit 排序键：数字 id 在前按数值，其它按文本；同键保持文件顺序（sorted 稳定）。"""
    value = unit.get("unit")
    if _is_number(value):
        return (0, float(value), "")
    return (1, 0.0, _text(value))


def _key_part(value):
    """分组键的安全形态：非字符串（坏行）也不会污染 dict 键。"""
    return value if isinstance(value, str) else _text(value)


def rect_of(value):
    """把 state 里的矩形规范成 4 元组；Qt 发布 {x,y,width,height}（Qt/src/NativeHud.cpp:181-183）。"""
    if isinstance(value, dict):
        keys = ("x", "y", "width", "height")
        if all(key in value for key in keys) and all(_finite(value[key]) for key in keys):
            return tuple(float(value[key]) for key in keys)
        return None
    if isinstance(value, list) and len(value) == 4 and all(_finite(item) for item in value):
        return tuple(float(item) for item in value)
    return None


def hit_rect(value):
    if not isinstance(value, dict):
        return None
    keys = ("x", "y", "width", "height")
    if not all(key in value and _finite(value[key]) for key in keys):
        return None
    return tuple(float(value[key]) for key in keys)


def overlaps(left, right):
    return (
        left[0] < right[0] + right[2]
        and right[0] < left[0] + left[2]
        and left[1] < right[1] + right[3]
        and right[1] < left[1] + left[3]
    )


def count_hits(units, rect):
    """统计落在 ROI 内的命中；几何不可定位的单独计数（只作证据，不参与判定）。"""
    inside = 0
    unlocatable = 0
    for unit in units:
        hits = unit.get("hits")
        if not isinstance(hits, list):
            continue
        for hit in hits:
            box = hit_rect(hit)
            if box is None:
                unlocatable += 1
            elif overlaps(box, rect):
                inside += 1
    return inside, unlocatable


# ---------------------------------------------------------------- 条件与锚点（纯函数）


_CONDITION_CLAUSE = re.compile(r"^state\.([A-Za-z_][A-Za-z0-9_]*)\s*(?:>\s*(-?[0-9]+(?:\.[0-9]+)?))?$")


def parse_condition(text, roi_id):
    """解析 fixture 的 conditional 文本 -> (子句列表, 末尾源码引用)。

    现有三条都是 state.<key> 真值或 state.<key> > N，用 && 串联，末尾括号是源码引用。
    解析不了就报输入错误：宁可拒绝运行，也不猜判据语义。
    """
    if not isinstance(text, str) or not text.strip():
        raise InputError("roi {} 的 conditional 不是非空字符串：{}".format(roi_id, _text(text)))
    body = text.strip()
    citation = ""
    start = _trailing_parenthesis_start(body)
    if start is not None:
        citation = body[start:].strip()
        body = body[:start].strip()
    clauses = []
    for raw in body.split("&&"):
        matched = _CONDITION_CLAUSE.match(raw.strip())
        if matched is None:
            raise InputError("roi {} 的 conditional 子句无法解析：{}".format(roi_id, _text(raw.strip())))
        number = matched.group(2)
        clauses.append(
            {
                "key": matched.group(1),
                "operator": ">" if number else None,
                "value": float(number) if number else None,
            }
        )
    return clauses, citation


def _trailing_parenthesis_start(text):
    if not text.endswith(")"):
        return None
    depth = 0
    for index in range(len(text) - 1, -1, -1):
        character = text[index]
        if character == ")":
            depth += 1
        elif character == "(":
            depth -= 1
            if depth == 0:
                return index if index > 0 else None
    return None


def evaluate_condition(clauses, state):
    """三值求值：True / False / None（引用键未发布或值不是标量）。

    只有 False 能证明「条件不成立」；None 是未知，既不能当成立也不能当不成立。
    """
    if not isinstance(state, dict):
        return None
    unknown = False
    for clause in clauses:
        key = clause["key"]
        if key not in state:
            unknown = True
            continue
        value = state[key]
        if clause["operator"] == ">":
            if not _finite(value):
                unknown = True
                continue
            if not float(value) > clause["value"]:
                return False
            continue
        truth = _truth(value)
        if truth is None:
            unknown = True
            continue
        if not truth:
            return False
    return None if unknown else True


def _truth(value):
    if isinstance(value, bool):
        return value
    if _is_number(value):
        return float(value) != 0.0
    return None


def state_anchor(state, roi_id):
    """按 ROI id 末段在 NativeHud::state() 的键里找几何锚点（Qt/src/NativeHud.cpp:175-219）。

    只认 rect 形状：Qt 只发布 state.seek(:193) / state.volume(:194) 两个矩形，以及
    state.inputX / inputY / inputWidth 三个标量(:184-186)。末段匹配是机械规则，
    没有 ROI 名单，也不给任何 ROI 特判。
    """
    result = {"kind": "absent", "key": None, "rect": None, "components": {}}
    if not isinstance(state, dict) or not isinstance(roi_id, str) or "." not in roi_id:
        return result
    segment = roi_id.rsplit(".", 1)[-1]
    result["key"] = segment
    rect = rect_of(state.get(segment))
    if rect is not None:
        result["kind"] = "rect"
        result["rect"] = rect
        return result
    components = {}
    for name in ("x", "y", "width", "height"):
        key = segment + name.capitalize()
        if key in state and _finite(state[key]):
            components[name] = float(state[key])
    if components:
        result["kind"] = "partial"
        result["components"] = components
    return result


# ---------------------------------------------------------------- fixture（I/O + 校验）


def load_fixture(path):
    """读 fixture（唯一的 JSON 文件入口）。"""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except OSError as error:
        raise InputError("读不到 fixture {}：{}".format(path, error))
    except ValueError as error:
        raise InputError("fixture {} 不是合法 JSON：{}".format(path, error))
    return data


def build_context(fixture):
    """把 fixture 校验成只读上下文；任何契约缺口都报输入错误，不回退默认值。"""
    if not isinstance(fixture, dict):
        raise InputError("fixture 顶层必须是对象")
    if fixture.get("schema") != FIXTURE_SCHEMA:
        raise InputError("fixture.schema 必须是 {}，实际 {}".format(FIXTURE_SCHEMA, _text(fixture.get("schema"))))
    capture = fixture.get("capture")
    if not isinstance(capture, dict):
        raise InputError("fixture.capture 缺失")
    unit_fields = capture.get("unitFields")
    if not isinstance(unit_fields, list) or not unit_fields:
        raise InputError("fixture.capture.unitFields 缺失或为空")
    unit_schema = capture.get("unitSchema")
    if not isinstance(unit_schema, str) or not unit_schema:
        raise InputError("fixture.capture.unitSchema 缺失")
    min_units = capture.get("minUnitsPerStep")
    if not _is_number(min_units) or float(min_units) < 1:
        raise InputError("fixture.capture.minUnitsPerStep 必须是 >=1 的数字")
    extra_units = capture.get("extraUnits") or {}
    if not isinstance(extra_units, dict):
        raise InputError("fixture.capture.extraUnits 必须是对象")

    thresholds = _threshold_index(fixture.get("thresholds"))
    rois = _roi_index(fixture.get("rois"))
    steps = _step_list(fixture.get("steps"))
    step_ids = [step["id"] for step in steps]
    for step_id in extra_units:
        if step_id not in step_ids:
            raise InputError("fixture.capture.extraUnits 引用了未知 step：{}".format(step_id))
    for step in steps:
        for roi_id in step["rois"]:
            if roi_id not in rois:
                raise InputError("step {} 引用了未定义的 ROI：{}".format(step["id"], roi_id))

    binding = {}
    for compare in sorted(THRESHOLD_BINDING):
        threshold_id = THRESHOLD_BINDING[compare]
        if threshold_id not in thresholds:
            raise InputError(
                "fixture.thresholds 缺少 {}（比较类型 {} 的判据）；本工具不回退任何默认阈值".format(
                    threshold_id, compare
                )
            )
        binding[compare] = threshold_id
    for roi in rois.values():
        if roi["compare"] not in binding:
            raise InputError("ROI {} 的比较类型 {} 没有绑定阈值；不内置容差".format(roi["id"], roi["compare"]))

    conditions = {}
    for roi in rois.values():
        if "conditional" in roi:
            conditions[roi["id"]] = parse_condition(roi["conditional"], roi["id"])

    candidates = []
    for entry in fixture.get("candidates") or []:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            raise InputError("fixture.candidates 每项都必须是带 id 的对象")
        candidates.append(entry["id"])
    if not candidates:
        raise InputError("fixture.candidates 为空")

    return {
        "fixture": fixture,
        "capture": capture,
        "unit_fields": [str(field) for field in unit_fields],
        "unit_schema": unit_schema,
        "min_units": int(min_units),
        "extra_units": {str(key): int(value) for key, value in extra_units.items()},
        "thresholds": thresholds,
        "threshold_binding": binding,
        "rois": rois,
        "steps": steps,
        "step_ids": step_ids,
        "candidate_ids": candidates,
        "conditions": conditions,
    }


def _threshold_index(entries):
    if not isinstance(entries, list) or not entries:
        raise InputError("fixture.thresholds 缺失或为空")
    index = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise InputError("fixture.thresholds 每项都必须是对象")
        identifier = entry.get("id")
        if not isinstance(identifier, str) or not identifier:
            raise InputError("fixture.thresholds 存在没有 id 的条目")
        if identifier in index:
            raise InputError("fixture.thresholds 存在重复 id：{}".format(identifier))
        if "value" not in entry:
            raise InputError("阈值 {} 缺 value 字段（null 也要显式写）".format(identifier))
        if "status" not in entry:
            raise InputError("阈值 {} 缺 status 字段".format(identifier))
        index[identifier] = entry
    return index


def _roi_index(entries):
    if not isinstance(entries, list) or not entries:
        raise InputError("fixture.rois 缺失或为空")
    index = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise InputError("fixture.rois 每项都必须是对象")
        identifier = entry.get("id")
        if not isinstance(identifier, str) or not identifier:
            raise InputError("fixture.rois 存在没有 id 的条目")
        if identifier in index:
            raise InputError("fixture.rois 存在重复 id：{}".format(identifier))
        rect = entry.get("rect")
        if not isinstance(rect, list) or len(rect) != 4 or not all(_is_number(item) for item in rect):
            raise InputError("ROI {} 的 rect 必须是 4 个数字".format(identifier))
        if not isinstance(entry.get("compare"), str):
            raise InputError("ROI {} 缺 compare".format(identifier))
        index[identifier] = entry
    return index


def _step_list(entries):
    if not isinstance(entries, list) or not entries:
        raise InputError("fixture.steps 缺失或为空")
    steps = []
    seen = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise InputError("fixture.steps 每项都必须是对象")
        identifier = entry.get("id")
        if not isinstance(identifier, str) or not identifier:
            raise InputError("fixture.steps 存在没有 id 的条目")
        if identifier in seen:
            raise InputError("fixture.steps 存在重复 id：{}".format(identifier))
        seen.add(identifier)
        rois = entry.get("rois")
        if not isinstance(rois, list) or not rois or not all(isinstance(item, str) for item in rois):
            raise InputError("step {} 的 rois 必须是非空字符串数组（step.rois 是唯一采样源）".format(identifier))
        steps.append({"id": identifier, "rois": list(rois)})
    return steps


def select_candidates(candidate_ids, requested):
    """--candidate 过滤；未知候选直接报错，避免拼错名字时静默给出空矩阵。"""
    if not requested:
        return list(candidate_ids)
    unknown = sorted(set(requested) - set(candidate_ids))
    if unknown:
        raise InputError("--candidate 引用了 fixture 里不存在的候选：{}".format(", ".join(unknown)))
    chosen = [item for item in candidate_ids if item in set(requested)]
    if not chosen:
        raise InputError("--candidate 过滤后没有候选")
    return chosen


def select_steps(steps, requested):
    if not requested:
        return list(steps)
    known = {step["id"] for step in steps}
    unknown = sorted(set(requested) - known)
    if unknown:
        raise InputError("--step 引用了 fixture 里不存在的 step：{}".format(", ".join(unknown)))
    return [step for step in steps if step["id"] in set(requested)]


# ---------------------------------------------------------------- units（I/O + 校验）


def load_units(path, context):
    """读 units JSONL 并逐行校验；返回 (行数, 有效 unit 列表, 丢弃记录列表)。

    丢弃是整份快照级别的（01-slice.md:144、hud-protocol.md §4.5）：只要缺字段、类型不对或
    代次不一致，就整 unit 丢弃并写进 discardedUnits，绝不只丢一个数组。
    """
    accepted = []
    discarded = []
    lines = 0
    try:
        handle = open(path, "r", encoding="utf-8")
    except OSError as error:
        raise InputError("读不到 units {}：{}".format(path, error))
    with handle:
        for number, raw in enumerate(handle, start=1):
            text = raw.strip()
            if not text:
                continue
            lines += 1
            try:
                unit = json.loads(text)
            except ValueError as error:
                raise InputError("units 第 {} 行不是合法 JSON：{}".format(number, error))
            reasons = unit_rejection(unit, context)
            if reasons:
                discarded.append(
                    {
                        "line": number,
                        "candidate": unit.get("candidate") if isinstance(unit, dict) else None,
                        "step": unit.get("step") if isinstance(unit, dict) else None,
                        "unit": unit.get("unit") if isinstance(unit, dict) else None,
                        "reasons": reasons,
                    }
                )
            else:
                accepted.append(unit)
    return lines, accepted, discarded


def unit_rejection(unit, context):
    """返回丢弃原因列表；空列表表示整份快照可用。"""
    if not isinstance(unit, dict):
        return ["notAnObject"]
    reasons = []
    missing = [field for field in context["unit_fields"] if field not in unit]
    if missing:
        reasons.append("missingFields:" + ",".join(missing))
    if unit.get("schema") != context["unit_schema"]:
        reasons.append("schemaMismatch:" + _text(unit.get("schema")))
    if unit.get("candidate") not in context["candidate_ids"]:
        reasons.append("unknownCandidate:" + _text(unit.get("candidate")))
    if unit.get("step") not in context["step_ids"]:
        reasons.append("unknownStep:" + _text(unit.get("step")))
    for field, expected in CONTAINER_FIELDS:
        if field in unit and not isinstance(unit[field], expected):
            reasons.append("badType:" + field)
    generation = unit.get("generation")
    if "generation" in unit and generation is not None and not _is_number(generation):
        reasons.append("generationNotNumber:" + _text(generation))
    reasons.extend(generation_reasons(unit, generation))
    return reasons


def generation_reasons(unit, generation):
    """数组级代次标记必须与顶层 generation 同值（hud-protocol.md §4.5）。

    接受两种等价信封写法：并列键 <field>Generation，或对象 generations。
    frame 内出现 generation 属协议违例（01-slice.md:140），这里只做同值校验、不改写数据。
    """
    reasons = []
    for field in GENERATION_FIELDS:
        key = field + "Generation"
        if key in unit:
            reasons.extend(_generation_mismatch(key, unit[key], generation))
    nested = unit.get("generations")
    if isinstance(nested, dict):
        for field in sorted(nested):
            if field in GENERATION_FIELDS:
                reasons.extend(_generation_mismatch("generations." + field, nested[field], generation))
    frame = unit.get("frame")
    if isinstance(frame, dict) and "generation" in frame:
        reasons.extend(_generation_mismatch("frame.generation", frame["generation"], generation))
    return reasons


def _generation_mismatch(label, marker, generation):
    if _same_generation(marker, generation):
        return []
    return ["generationMismatch:{}={}!=unit={}".format(label, _text(marker), _text(generation))]


def _same_generation(left, right):
    if left is None or right is None:
        return left is None and right is None
    if _is_number(left) and _is_number(right):
        return float(left) == float(right)
    if isinstance(left, str) and isinstance(right, str):
        return left == right
    return False


# ---------------------------------------------------------------- 判定（纯函数）


def threshold_usable(threshold):
    """冻结且带有限数值才能当门；UNMEASURED / PROPOSED_UNFROZEN / NO_THRESHOLD 一律不能判 PASS。"""
    return threshold.get("status") == FROZEN_STATUS and _finite(threshold.get("value"))


def new_part():
    return {"metrics": {}, "evidence": [], "failures": [], "reasons": [], "complete": False}


def conditional_gate(context, roi, pairs):
    """决定该 ROI 是否参与 PASS 判定；返回 (conditional, state, participants, notes, reasons)。

    顺序：① 表达式可求值就用表达式；② 引用键未发布（NativeHud::state() 没有
    seekable / durationMs / hasTrack / applicationVolume）时，用 ROI 自身的 state 锚点存在性判定——
    state.seek / state.volume 只在 PlayerBar.cpp:148-149 / :212-214 的条件成立时才被赋值
    （NativeHudPlayer.cpp:39-41），因此 null 等价于条件不成立；③ 两者都没有就是 unknown，不许猜。
    """
    if "conditional" not in roi:
        return True, "notDeclared", list(pairs), [], []
    clauses, citation = context["conditions"][roi["id"]]
    keys = sorted({clause["key"] for clause in clauses})
    notes = [
        "conditional:expr={} keys=[{}] citation={}".format(
            _text(roi["conditional"]), ", ".join(keys), citation or "none"
        )
    ]
    results = [(pair, evaluate_condition(clauses, pair[0].get("state"))) for pair in pairs]
    if any(result is True for _, result in results):
        participants = [pair for pair, result in results if result is True]
        notes.append("conditional:satisfiedByExpression units={}".format(len(participants)))
        return True, "satisfied", participants, notes, []
    if any(result is False for _, result in results):
        notes.append("conditional:unsatisfiedByExpression => 该 ROI 不存在，不参与 PASS")
        return False, "unsatisfied", [], notes, ["conditionalUnsatisfied"]
    anchored = [pair for pair, _ in results if pair[1]["kind"] != "absent"]
    if anchored:
        notes.append(
            "conditional:satisfiedByAnchor units={} — 表达式键未发布，按 state.{} 是否存在判定"
            "（PlayerBar.cpp:148-149/:212-214；NativeHudPlayer.cpp:39-41）".format(
                len(anchored), anchored[0][1]["key"]
            )
        )
        return True, "satisfied", anchored, notes, []
    notes.append("conditional:unknown — 表达式键未发布且无 state 锚点；不得当作成立，也不得当作不成立")
    return False, "unknown", [], notes, ["conditionalUnknown"]


def _is_matrix(value):
    return isinstance(value, list) and len(value) == 16 and all(_finite(item) for item in value)


def view_eye_residual(view, eye, column_major=True):
    """view * (eye,1) 应等于 (0,0,0,1)。

    Qt 的 QMatrix4x4 按列主序序列化：element(row, col) = view[col*4 + row]；相机矩阵的平移在
    第 4 列（SceneMath.cpp:94），而 view = camera(eye, aim).inverse()（NativeScene.cpp:50、
    NativeSceneCamera.cpp:106），所以相机自身原点必然映射到原点。
    """
    residual = 0.0
    for row in range(4):
        total = 0.0
        for column in range(3):
            index = column * 4 + row if column_major else row * 4 + column
            total += view[index] * eye[column]
        index = 3 * 4 + row if column_major else row * 4 + 3
        total += view[index]
        target = 1.0 if row == 3 else 0.0
        residual = max(residual, abs(total - target))
    return residual


def measure_layout(roi, pairs, threshold):
    """静态 stage 矩形比较：ROI rect（stage 坐标）对照 NativeHud::state() 的几何键。

    只有 state 发布出来的矩形才算测过：Qt 只发 playerBounds(:192)、seek(:193)、volume(:194)，
    以及 inputX/inputY/inputWidth(:184-186) 三个标量——后者缺 height，因此只能部分测量。
    """
    part = new_part()
    tolerance = float(threshold["value"])
    expected = [float(item) for item in roi["rect"]]
    names = ("x", "y", "width", "height")
    counts = {"rectUnits": 0, "partialUnits": 0, "absentUnits": 0}
    observations = []
    worst = 0.0
    key = pairs[0][1]["key"] if pairs else (roi["id"].rsplit(".", 1)[-1] if "." in roi["id"] else roi["id"])
    for unit, anchor in pairs:
        state = unit.get("state") if isinstance(unit.get("state"), dict) else {}
        label = _text(unit.get("unit"))
        if anchor["kind"] == "rect":
            counts["rectUnits"] += 1
            observed = [float(item) for item in anchor["rect"]]
            deltas = [observed[index] - expected[index] for index in range(4)]
            local = max(abs(item) for item in deltas)
            worst = max(worst, local)
            observations.append(
                {
                    "unit": label,
                    "source": "state." + str(anchor["key"]),
                    "observed": _fmt_rect([_component(item) for item in observed]),
                    "delta": _fmt_rect([_fmt_delta(item) for item in deltas]),
                }
            )
            if local > tolerance:
                part["failures"].append(
                    "anchorMismatch:unit={} state.{}={} rect={} maxAbsDelta={} > tol={}".format(
                        label,
                        anchor["key"],
                        _fmt_rect([_component(item) for item in observed]),
                        _fmt_rect([_component(item) for item in expected]),
                        _fmt_delta(local),
                        _fmt_delta(tolerance),
                    )
                )
        elif anchor["kind"] == "partial":
            counts["partialUnits"] += 1
            offset = None
            if isinstance(roi.get("expr"), str) and "modalOffset" in roi["expr"] and _finite(state.get("modalOffset")):
                offset = float(state["modalOffset"])
            deltas = {}
            unknown = []
            for index, name in enumerate(names):
                if name not in anchor["components"]:
                    unknown.append(name)
                    continue
                reference = expected[index] + (offset if (index == 1 and offset is not None) else 0.0)
                deltas[name] = anchor["components"][name] - reference
            entry = {
                "unit": label,
                "source": "state." + str(anchor["key"]) + "*",
                "observed": _fmt_rect([_component(anchor["components"].get(name)) for name in names]),
                "delta": _fmt_rect([_fmt_delta(deltas[name]) if name in deltas else "unknown" for name in names]),
                "unmeasured": unknown,
            }
            if offset is not None:
                entry["modalOffset"] = _component(offset)
            observations.append(entry)
            exceeded = [name for name, delta in deltas.items() if abs(delta) > tolerance]
            if exceeded:
                part["evidence"].append(
                    "partialMismatch:unit={} 已发布分量中 {} 超出容差 {}（其余分量未发布，仍不能判 FAIL）".format(
                        label, ", ".join(sorted(exceeded)), _fmt_delta(tolerance)
                    )
                )
            part["reasons"].append("partialStateAnchor")
            part["evidence"].append(
                "partialStateAnchor:unit={} state.{} 只发布 {}，ROI rect 有 4 个分量；缺 {} 无法比较".format(
                    label, anchor["key"], ", ".join(sorted(anchor["components"])), ", ".join(unknown) or "none"
                )
            )
        else:
            counts["absentUnits"] += 1
            detail = "unit={} state.{} 未发布".format(label, anchor["key"])
            if "conditional" in roi:
                # 条件门刚刚用该键的存在性判定条件成立，此刻键却消失：这是矛盾，可判 FAIL。
                part["failures"].append("anchorMissing:" + detail + "（条件成立却无几何，与条件门冲突）")
            else:
                # 非条件 ROI 没有对应 state 键（NativeHud::state() 只发布
                # playerBounds/seek/volume 与 inputX/inputY/inputWidth）：只是没测量，不是证伪。
                part["reasons"].append("noStateAnchor")
                part["evidence"].append("noStateAnchor:" + detail + "（该 key 不在 state 发布面内，无法测量）")
    part["metrics"] = {
        "anchor": {
            "key": str(key),
            "rectUnits": counts["rectUnits"],
            "partialUnits": counts["partialUnits"],
            "absentUnits": counts["absentUnits"],
        },
        "expected": _fmt_rect([_component(item) for item in expected]),
        "tolerance": _component(tolerance),
        "maxAbsDelta": _fmt_delta(worst),
        "observations": observations[:10],
        "observationsTotal": len(observations),
    }
    part["complete"] = (
        counts["rectUnits"] > 0
        and counts["partialUnits"] == 0
        and counts["absentUnits"] == 0
        and not part["failures"]
    )
    return part


def measure_scene3d(roi, pairs, threshold):
    """真实 3D 场景 ROI：frame 必须是自洽的真 draw，而不是贴图/占位。

    判据（不是 §7 里 PROPOSED_UNFROZEN 的 SSIM/ΔE）：
      - frame 存在且 draws 是数组；draws 为空只允许 viewer=true（HUD 无绘制时仍上报观察者）；
      - view / projection 是 16 个有限数，eye 是 3 个有限数（hud-protocol.md §4）；
      - view*(eye,1)=(0,0,0,1) 在 th.frame.matrix 容差内（列主序，SceneMath.cpp:94）。
    """
    part = new_part()
    tolerance = float(threshold["value"])
    checked = 0
    participating = 0
    draws_min = None
    residual_max = 0.0
    frames = []
    for unit, anchor in pairs:
        label = _text(unit.get("unit"))
        frame = unit.get("frame")
        if not isinstance(frame, dict):
            part["reasons"].append("frameMissing")
            part["evidence"].append("frameMissing:unit=" + label)
            continue
        checked += 1
        draws = frame.get("draws")
        if not isinstance(draws, list):
            part["reasons"].append("frameDrawsNotArray")
            part["evidence"].append("frameDrawsNotArray:unit=" + label)
        else:
            draws_min = len(draws) if draws_min is None else min(draws_min, len(draws))
            if not draws:
                # 空 draws 无法区分「没画」与「没记录」，只记证据不判 PASS，也不判 FAIL。
                part["reasons"].append("frameDrawsEmpty")
                part["evidence"].append("frameDrawsEmpty:unit={} viewer={}".format(label, _text(frame.get("viewer"))))
        view = frame.get("view")
        projection = frame.get("projection")
        eye = frame.get("eye")
        invalid = []
        if not _is_matrix(view):
            invalid.append("view")
        if not _is_matrix(projection):
            invalid.append("projection")
        if not (isinstance(eye, list) and len(eye) == 3 and all(_finite(item) for item in eye)):
            invalid.append("eye")
        if invalid:
            part["reasons"].append("frameMatrixInvalid")
            part["evidence"].append("frameMatrixInvalid:{}:unit={}".format(",".join(invalid), label))
            continue
        participating += 1
        residual = view_eye_residual(view, [float(item) for item in eye], True)
        if residual > tolerance:
            mirrored = view_eye_residual(view, [float(item) for item in eye], False)
            if mirrored <= tolerance:
                part["reasons"].append("matrixOrderAmbiguous")
                part["evidence"].append(
                    "matrixOrderAmbiguous:unit={} 列主序残差={} 行主序残差={}；存储序待定，不判 PASS".format(
                        label, _fmt_delta(residual), _fmt_delta(mirrored)
                    )
                )
            else:
                part["failures"].append(
                    "viewEyeResidual:unit={} maxAbs={} > tol={}（view*(eye,1) 应为 (0,0,0,1)）".format(
                        label, _fmt_delta(residual), _fmt_delta(tolerance)
                    )
                )
        else:
            residual_max = max(residual_max, residual)
        frames.append(
            {
                "unit": label,
                "draws": len(draws) if isinstance(draws, list) else None,
                "viewer": frame.get("viewer"),
                "viewEyeResidual": _fmt_delta(residual),
            }
        )
    part["metrics"] = {
        "frames": {
            "checked": checked,
            "participating": participating,
            "drawsMin": draws_min,
            "viewEyeResidualMax": _fmt_delta(residual_max),
            "tolerance": _component(tolerance),
        },
        "observations": frames[:10],
    }
    part["complete"] = (
        bool(pairs)
        and checked == len(pairs)
        and participating == checked
        and not part["failures"]
        and not part["reasons"]
    )
    return part


# ---------------------------------------------------------------- 行组装（纯函数）


def build_row(context, candidate, step, roi_id, units, discarded):
    """一条结果 = 一个 candidate × 一个 step × 一个 ROI；绝不合并成单一全局分数。"""
    roi = context["rois"][roi_id]
    step_id = step["id"]
    required = context["min_units"] + context["extra_units"].get(step_id, 0)
    threshold = context["thresholds"][context["threshold_binding"][roi["compare"]]]

    pairs = [(unit, state_anchor(unit.get("state"), roi_id)) for unit in units]
    rect = [float(item) for item in roi["rect"]]
    inside, unlocatable = count_hits(units, rect)

    metrics = {
        "units": len(units),
        "unitsRequired": required,
        "unitsDiscarded": len(discarded),
        "unitIds": [_text(unit.get("unit")) for unit in units],
        "hitsInRoi": inside,
        "hitsUnlocatable": unlocatable,
    }

    conditional, conditional_state, participants, notes, gates = conditional_gate(context, roi, pairs)
    reasons = list(gates)
    part = new_part()

    if threshold_usable(threshold):
        notes.append(
            "threshold:{} value={} status={}".format(
                threshold.get("id"), _text(threshold.get("value")), threshold.get("status")
            )
        )
        if len(units) < required:
            reasons.append("samplingShortfall")
            notes.append("samples:{} < required {}（capture.minUnitsPerStep+extraUnits）".format(len(units), required))
        elif conditional:
            if roi["compare"] == "layout":
                part = measure_layout(roi, participants, threshold)
            elif roi["compare"] == "scene3d":
                part = measure_scene3d(roi, participants, threshold)
            elif roi["compare"] in UNMEASURABLE_KINDS:
                reasons.append("noPayload")
                notes.append(PAYLOAD_NOTES.get(roi["compare"], "payload:none"))
            else:
                reasons.append("unsupportedCompare")
                notes.append("compare:{} 没有测量实现".format(roi["compare"]))
            metrics.update(part["metrics"])
            reasons.extend(part["reasons"])
            notes.extend(part["evidence"])
    else:
        reasons.append("noFrozenThreshold")
        notes.append(
            "threshold:{} value={} status={} — 非 FROZEN 或无值，不能当门（§7 预登记：只有 FROZEN 才能判 PASS）".format(
                threshold.get("id"), _text(threshold.get("value")), threshold.get("status")
            )
        )

    failures = part["failures"]
    if not failures and not reasons and not part["complete"]:
        reasons.append("incompleteMeasurement")

    if failures:
        verdict = "FAIL"
    elif reasons:
        verdict = "UNMEASURED"
    elif part["complete"]:
        verdict = "PASS"
    else:  # 理论上不可达：complete 为真时才有资格 PASS
        verdict = "UNMEASURED"
        reasons.append("incompleteMeasurement")

    unique_reasons = sorted({item for item in reasons if item})
    if unique_reasons:
        metrics["reasons"] = unique_reasons
    if failures:
        metrics["failures"] = len(failures)

    evidence = []
    if failures:
        evidence.extend(_cap(failures))
    else:
        evidence.extend("reason:" + item for item in unique_reasons)
    evidence.extend(notes)
    if not evidence:
        evidence.append("ok:所有参与测量的 unit 均落在冻结容差内")

    return {
        "candidate": candidate,
        "step": step_id,
        "roi": roi_id,
        "compare": roi["compare"],
        "rect": [_component(item) for item in rect],
        "verdict": verdict,
        "conditional": conditional,
        "conditionalState": conditional_state,
        "conditionalExpression": roi.get("conditional"),
        "threshold": {
            "id": threshold.get("id"),
            "value": threshold.get("value"),
            "status": threshold.get("status"),
            "appliesTo": roi["compare"],
        },
        "metrics": metrics,
        "evidence": _cap(evidence, 8),
    }


# ---------------------------------------------------------------- 报告组装（纯函数）


def build_report(context, candidates, steps, unit_lines, units, discarded):
    units_by_key = {}
    for unit in units:
        key = (_key_part(unit.get("candidate")), _key_part(unit.get("step")))
        units_by_key.setdefault(key, []).append(unit)
    discarded_by_key = {}
    for entry in discarded:
        key = (_key_part(entry.get("candidate")), _key_part(entry.get("step")))
        discarded_by_key.setdefault(key, []).append(entry)

    results = []
    summaries = []
    for candidate in candidates:
        for step in steps:
            key = (candidate, step["id"])
            step_units = sorted(units_by_key.get(key, []), key=_unit_order)
            step_discarded = discarded_by_key.get(key, [])
            required = context["min_units"] + context["extra_units"].get(step["id"], 0)
            counts = {"PASS": 0, "FAIL": 0, "UNMEASURED": 0}
            conditional_false = 0
            for roi_id in step["rois"]:
                row = build_row(context, candidate, step, roi_id, step_units, step_discarded)
                results.append(row)
                counts[row["verdict"]] += 1
                if row["conditional"] is False:
                    conditional_false += 1
            summaries.append(
                {
                    "candidate": candidate,
                    "step": step["id"],
                    "unitsValid": len(step_units),
                    "unitsRequired": required,
                    "unitsDiscarded": len(step_discarded),
                    "rows": len(step["rois"]),
                    "rowCounts": counts,
                    "conditionalFalse": conditional_false,
                }
            )

    row_counts = {"PASS": 0, "FAIL": 0, "UNMEASURED": 0}
    for row in results:
        row_counts[row["verdict"]] += 1
    reason_counts = {}
    for row in results:
        for reason in row["metrics"].get("reasons", []):
            reason_counts[reason] = reason_counts.get(reason, 0) + 1

    exit_code = EXIT_ALL_PASS if (results and row_counts["PASS"] == len(results)) else EXIT_NOT_PASS
    if exit_code == EXIT_ALL_PASS:
        gate_reason = "allRowsPass"
    elif row_counts["FAIL"]:
        gate_reason = "failPresent"
    else:
        gate_reason = "unmeasuredPresent"

    fixture = context["fixture"]
    return {
        "schema": REPORT_SCHEMA,
        "conventions": CONVENTIONS,
        "fixture": {
            "sliceId": fixture.get("sliceId"),
            "sliceVersion": fixture.get("sliceVersion"),
            "baselineCommit": fixture.get("baselineCommit"),
            "status": fixture.get("status"),
            "unitSchema": context["unit_schema"],
            "unitFields": list(context["unit_fields"]),
            "minUnitsPerStep": context["min_units"],
            "extraUnits": dict(context["extra_units"]),
        },
        "candidates": list(candidates),
        "steps": [step["id"] for step in steps],
        "thresholds": {identifier: _threshold_echo(context, identifier) for identifier in sorted(context["thresholds"])},
        "thresholdBindings": dict(context["threshold_binding"]),
        "units": {"lines": unit_lines, "accepted": len(units), "discarded": len(discarded)},
        "rowCounts": row_counts,
        "reasonCounts": reason_counts,
        "gate": {"exitCode": exit_code, "reason": gate_reason},
        "results": results,
        "stepSummaries": summaries,
        "rois": [
            {
                "id": roi_id,
                "compare": context["rois"][roi_id]["compare"],
                "rect": [_component(item) for item in context["rois"][roi_id]["rect"]],
                "conditional": context["rois"][roi_id].get("conditional"),
            }
            for roi_id in sorted(context["rois"])
            if any(roi_id in step["rois"] for step in steps)
        ],
        "discardedUnits": discarded,
        "notEvaluated": {
            "checks": [
                entry.get("id") for entry in (fixture.get("checks") or []) if isinstance(entry, dict)
            ],
            "reason": "fixture.checks 是 HUD 协议行为断言（hit/commands/IME/scene 等），"
            "由 hud_protocol_test 与现场采集核对；本工具只比较 ROI 判据，不把 checks 折算成分数。",
            "fixtureUnmeasured": [
                entry.get("id") if isinstance(entry, dict) else entry
                for entry in (fixture.get("unmeasured") or [])
            ],
            "fixtureVerdicts": fixture.get("verdicts"),
        },
    }


def _threshold_echo(context, identifier):
    threshold = context["thresholds"][identifier]
    return {
        "id": threshold.get("id"),
        "value": threshold.get("value"),
        "status": threshold.get("status"),
        "metric": threshold.get("metric"),
        "binding": [compare for compare, bound in sorted(context["threshold_binding"].items()) if bound == identifier],
    }


def write_report(path, report):
    """唯一的报告出口：键排序 + 固定缩进 + 禁用 NaN，保证同一输入逐字节相同。"""
    text = json.dumps(_sanitize(report), ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False)
    try:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    except OSError as error:
        raise InputError("写不了报告 {}：{}".format(path, error))
    return len(text) + 1


# ---------------------------------------------------------------- CLI（薄壳）


def reject_forbidden_flags(argv):
    """判据只能来自 fixture：任何覆盖阈值/容差/全局分数的参数一律拒绝（退出码 2）。"""
    for token in argv:
        name = token.split("=", 1)[0]
        if name in FORBIDDEN_FLAGS:
            raise InputError(
                "不接受 {}：判据只从 fixture 的 checks/thresholds 读取，命令行不得覆盖阈值/容差/全局分数".format(name)
            )


def split_values(values):
    """--candidate A,B --candidate C 与 --candidate A --candidate B 等价；保持出现顺序并去重。"""
    result = []
    for value in values or []:
        for item in str(value).split(","):
            text = item.strip()
            if text and text not in result:
                result.append(text)
    return result


def parse_args(argv):
    reject_forbidden_flags(argv)
    parser = argparse.ArgumentParser(
        prog="compare.py",
        description="逐 ROI 比较 slice 证据（只读、确定性）；判据只来自 fixture，不内置默认阈值。",
    )
    parser.add_argument("--fixture", required=True, metavar="JSON", help="test/fixtures/slice_cases.json")
    parser.add_argument("--units", required=True, metavar="JSONL", help="slice-unit/v1 快照，每行一份")
    parser.add_argument("--out", required=True, metavar="JSON", help="报告输出路径")
    parser.add_argument(
        "--candidate", action="append", default=[], metavar="A,B", help="只比较这些候选（可重复，逗号分隔）"
    )
    parser.add_argument(
        "--step", action="append", default=[], metavar="S2,S4", help="只比较这些 step（可重复，逗号分隔）"
    )
    return parser.parse_args(argv)


def main(argv):
    report = None
    try:
        args = parse_args(argv)
        context = build_context(load_fixture(args.fixture))
        candidates = select_candidates(context["candidate_ids"], split_values(args.candidate))
        steps = select_steps(context["steps"], split_values(args.step))
        lines, units, discarded = load_units(args.units, context)
        report = build_report(context, candidates, steps, lines, units, discarded)
        write_report(args.out, report)
    except InputError as error:
        sys.stderr.write("compare.py: input error: {}\n".format(error))
        return EXIT_INPUT
    return report["gate"]["exitCode"]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
