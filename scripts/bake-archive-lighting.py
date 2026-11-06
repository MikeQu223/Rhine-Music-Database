"""离线烘焙重复唱片壳的外观及选中光源的柔光场，只在构建时执行。

表面与光场使用 RGBA8 sRGB 存储（RGB 为线性辐亮度/4，alpha 保持线性），
着色器采样后手工解码；法线响应仍使用 RGBA16F，这样既保留 HDR 余量，又把固定贴图占用压到原来的一半左右。
表面图集额外生成完整 mip 链，并按需输出 BC7 压缩版本，运行时根据 RHI 能力选择。
"""

import math
import os
import pathlib
import struct


ROOT = pathlib.Path(__file__).resolve().parents[1]
# Android 的烘焙贴图输出到独立目录（scripts/build-android.cjs 设置变量）；
# 不设置时仍是公共的 output/resources，桌面与 iOS 的产物不受影响。
OUTPUT = pathlib.Path(os.environ.get("RHINE_3D_OUTPUT", ROOT / "output/resources"))
# 表面图集按实际屏幕投影分配分辨率：正面/背面 448²，侧面和顶面在
# 高频视角下也只有几十像素宽，收紧到 56 texel 即可，避免 7~24 倍过采样。
FACE_SIZE = 448
ATLAS_SIZE = 1024
NIGHT_OFFSET = ATLAS_SIZE // 2
SIDE_SIZE = 56
TOP_SIZE = 56
GUTTER = 4
# 线性辐亮度/4 后写入 sRGB8；所有烘焙值都小于 4，解码时乘 4 即可还原，
# 这不是 LDR clamp，而是可逆的 HDR 编码。
HDR_SCALE = 4.0
# 六个朝向在昼夜各半张图集中的位置：(left, top, width, height)。
# 4 px 间隙用于 mip 过滤时的边缘过渡，间隙会在烘焙后按最近边缘补齐。
FACE_RECTS = {
    0: (904, 0, SIDE_SIZE, FACE_SIZE),
    1: (0, 452, FACE_SIZE, TOP_SIZE),
    2: (0, 0, FACE_SIZE, FACE_SIZE),
    3: (964, 0, SIDE_SIZE, FACE_SIZE),
    4: (452, 452, FACE_SIZE, TOP_SIZE),
    5: (452, 0, FACE_SIZE, FACE_SIZE),
}
# 高度切片是光场误差的主导项：24 层在 96² 空间分辨率下把误差压到接近
# 128x16 的水平，同时 3D 纹理仍只有 5.06 MiB。
#
# RHINE_BAKE_LIGHT_HALF=1（Android）只把**空间**分辨率减半：96² → 48²，三维纹理
# 从 5.3 MB 降到 1.33 MB。这个尺寸才有可能留在移动 GPU 的 L2 里，而硬件三线性
# 在 5.3 MB 上必然穿到 DRAM。层数刻意不动——按上面的结论它才是误差主导项，
# 砍层会直接看出来；光场是低频数据，空间维减半有三线性插值兜着。
_FIELD_BASE = 96
FIELD_SIZE = (_FIELD_BASE // 2
              if os.environ.get("RHINE_BAKE_LIGHT_HALF", "").strip() == "1" else _FIELD_BASE)
HEIGHT_SLICES = 24
# RHINE_BAKE_NORMAL_RGBA8=1（Android）：法线响应用 RGBA8 UNORM 代替 RGBA16F。
# 它存的是烘焙好的 N·L 比值（0..4）与一处柔和高光（0..0.18），不是真法线，
# 8 位量化够用；着色器按 RHINE_NORMAL_RGBA8 宏乘回同样的比例。
NORMAL_RGBA8 = os.environ.get("RHINE_BAKE_NORMAL_RGBA8", "").strip() == "1"
NORMALS = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (-1, 0, 0), (0, -1, 0), (0, 0, -1)]
EMITTERS = [
    (-2.22, 0.60, 0.08),
    (-2.22, 1.65, 0.08),
    (-2.22, 2.75, 0.08),
    (-0.9, 1.8, 0.08),
    (1.1, 1.8, 0.08),
]


def smoothstep(low, high, value):
    amount = min(1, max(0, (value - low) / (high - low)))
    return amount * amount * (3 - 2 * amount)


def inverse_display_curve(value):
    """将目标 sRGB 灰阶反解为最终 ACES 通道之前的线性辐亮度。"""
    target = value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4
    low = 0.0
    high = 16.0
    for _ in range(24):
        middle = (low + high) / 2
        exposed = middle * 1.02 / 0.6
        output = (exposed * (exposed + 0.0245786) - 0.000090537) / (
            exposed * (0.983729 * exposed + 0.4329510) + 0.238081
        )
        if output < target:
            low = middle
        else:
            high = middle
    return (low + high) / 2


DISPLAY_TO_LINEAR = [inverse_display_curve(index / 1023) for index in range(1024)]


def radiance(value):
    return DISPLAY_TO_LINEAR[round(min(1, max(0, value)) * 1023)]


def face_sample(face, u, v, dark):
    """在物体局部坐标中烘焙乳白端面、暖色宽面、接触暗部和内部发光条。"""
    x = u * 5 - 2.5
    y = v * 3.7
    if face in (0, 3):
        x = 2.5 if face == 0 else -2.5
    elif face in (1, 4):
        y = 3.7 if face == 1 else 0
    border = math.exp(-min(u, 1 - u, v, 1 - v) / 0.025)
    if dark:
        color = (0.14, 0.17, 0.18) if face in (0, 1, 3) else (0.075, 0.102, 0.114)
        color = tuple(channel + border * 0.035 for channel in color)
    elif face in (2, 5):
        center = (0.70 + 0.16 * v, 0.60 + 0.19 * v, 0.46 + 0.24 * v)
        edge = (0.94, 0.91, 0.85)
        color = tuple(center[index] * (1 - border * 0.65) + edge[index] * border * 0.65 for index in range(3))
    elif face == 1:
        color = (0.965, 0.95, 0.925)
    else:
        color = (0.90 + v * 0.055, 0.875 + v * 0.065, 0.825 + v * 0.085)
    height = smoothstep(0.08, 0.5, y) * (1 - smoothstep(3.25, 3.67, y))
    guide = abs(x + 2.22)
    # 仅移除窄而亮的白色核心，保留原有宽范围的暖色扩散和内部柔光。
    emission = (0.55 * math.exp(-guide / 0.48) + 0.05) * height
    return (*[radiance(channel) for channel in color], emission)


def srgb_byte(value):
    """把 0..1 线性值编码为 sRGB8；着色器采样后手工解码回线性。"""
    value = min(1.0, max(0.0, value))
    encoded = value * 12.92 if value <= 0.0031308 else 1.055 * (value ** (1.0 / 2.4)) - 0.055
    return int(round(min(1.0, max(0.0, encoded)) * 255.0))


SRGB_DECODE = [
    (value / 255.0) / 12.92 if value / 255.0 <= 0.04045 else (((value / 255.0) + 0.055) / 1.055) ** 2.4
    for value in range(256)
]


def store_texel(pixels, offset, color):
    """RGB 写入 sRGB8(线性/4)，alpha 直接写线性 8 位。"""
    struct.pack_into("<4B", pixels, offset,
                     srgb_byte(color[0] / HDR_SCALE),
                     srgb_byte(color[1] / HDR_SCALE),
                     srgb_byte(color[2] / HDR_SCALE),
                     int(round(min(1.0, max(0.0, color[3])) * 255.0)))


def fill_gutters(pixels, block):
    """把每个面的边缘像素复制到 4 px 间隙，避免 mip 过滤把透明黑带进面内。"""
    mask = bytearray(ATLAS_SIZE * ATLAS_SIZE)
    for left, top, width, height in FACE_RECTS.values():
        y0 = block + top
        for row in range(y0, y0 + height):
            mask[row * ATLAS_SIZE + left:row * ATLAS_SIZE + left + width] = b"\x01" * width
    for left, top, width, height in FACE_RECTS.values():
        y0 = block + top
        for row in range(max(block, y0 - GUTTER), min(block + NIGHT_OFFSET, y0 + height + GUTTER)):
            source_y = min(max(row, y0), y0 + height - 1)
            for column in range(max(0, left - GUTTER), min(ATLAS_SIZE, left + width + GUTTER)):
                index = row * ATLAS_SIZE + column
                if mask[index]:
                    continue
                source_x = min(max(column, left), left + width - 1)
                source = (source_y * ATLAS_SIZE + source_x) * 4
                target = index * 4
                pixels[target:target + 4] = pixels[source:source + 4]
                mask[index] = 1


def downsample(source, width, height):
    """按线性光平均 2x2 像素，再编码回 sRGB8；alpha 保持线性。"""
    next_width = max(1, width // 2)
    next_height = max(1, height // 2)
    pixels = bytearray(next_width * next_height * 4)
    for row in range(next_height):
        source_row = min(height - 1, row * 2)
        source_row_next = min(height - 1, source_row + 1)
        for column in range(next_width):
            left = min(width - 1, column * 2)
            right = min(width - 1, left + 1)
            offsets = (source_row * width + left, source_row * width + right,
                       source_row_next * width + left, source_row_next * width + right)
            target = (row * next_width + column) * 4
            for channel in range(3):
                value = sum(SRGB_DECODE[source[offset * 4 + channel]] for offset in offsets) * 0.25
                pixels[target + channel] = srgb_byte(value)
            pixels[target + 3] = int(round(
                sum(source[offset * 4 + 3] for offset in offsets) * 0.25))
    return pixels


def build_mips(base):
    """生成从 ATLAS_SIZE 到 1x1 的完整 mip 链。"""
    levels = [bytes(base)]
    width = height = ATLAS_SIZE
    current = base
    while width > 1 or height > 1:
        current = downsample(current, width, height)
        width = max(1, width // 2)
        height = max(1, height // 2)
        levels.append(bytes(current))
    return levels


# BC7 mode 6：RGBA 各 7 位端点 + 共享奇偶位 + 16 个 4 位选择子。
BC7_WEIGHTS = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64]


def quantize_endpoint(values, parity):
    """把一个端点的四个通道量化到共享同一奇偶位的 7 位值。"""
    quantized = []
    error = 0
    for value in values:
        quantized_value = max(0, min(127, int(round((value - parity) / 2.0))))
        restored = (quantized_value << 1) | parity
        error += (restored - value) ** 2
        quantized.append(quantized_value)
    return error, quantized


def best_endpoint(values):
    """分别尝试偶/奇端点，返回量化误差较小的那个。"""
    best = None
    for parity in (0, 1):
        candidate = quantize_endpoint(values, parity)
        if best is None or candidate[0] < best[0]:
            best = (candidate[0], parity, candidate[1])
    return best[1], best[2]


def select_weights(block, endpoint0, endpoint1):
    """对每个像素暴力搜索 16 个权重，返回选择子与平方误差。"""
    base = [endpoint0[channel] * 64 + 32 for channel in range(4)]
    delta = [endpoint1[channel] - endpoint0[channel] for channel in range(4)]
    values = [[(base[channel] + delta[channel] * weight) >> 6 for channel in range(4)]
              for weight in BC7_WEIGHTS]
    selectors = []
    total = 0
    for pixel in block:
        best_error = 1 << 30
        best_index = 0
        for index, candidate in enumerate(values):
            error = 0
            for channel in range(4):
                difference = candidate[channel] - pixel[channel]
                error += difference * difference
            if error < best_error:
                best_error = error
                best_index = index
        total += best_error
        selectors.append(best_index)
    return selectors, total


def encode_bc7_block(block):
    """把 16 个 RGBA 像素编码为一个 BC7 mode 6 块。"""
    low = [min(pixel[channel] for pixel in block) for channel in range(4)]
    high = [max(pixel[channel] for pixel in block) for channel in range(4)]
    parity0, quantized0 = best_endpoint(low)
    parity1, quantized1 = best_endpoint(high)
    endpoint0 = [(value << 1) | parity0 for value in quantized0]
    endpoint1 = [(value << 1) | parity1 for value in quantized1]
    selectors, _ = select_weights(block, endpoint0, endpoint1)
    # 锚点像素只有 3 位；若选择子超过 7，交换端点并反转选择子。
    if selectors[0] > 7:
        endpoint0, endpoint1 = endpoint1, endpoint0
        parity0, parity1 = parity1, parity0
        selectors = [15 - value for value in selectors]
    packed = 0x40  # 7 位 mode 6 前缀
    shift = 7
    for channel in range(4):
        packed |= (endpoint0[channel] >> 1) << shift
        shift += 7
        packed |= (endpoint1[channel] >> 1) << shift
        shift += 7
    packed |= parity0 << shift
    shift += 1
    packed |= parity1 << shift
    shift += 1
    packed |= selectors[0] << shift
    shift += 3
    for selector in selectors[1:]:
        packed |= selector << shift
        shift += 4
    assert shift == 128
    return packed.to_bytes(16, "little")


def bc7_encode_level(pixels, width, height):
    """把一个 RGBA8 mip 层编码为 BC7；边缘块用边缘像素补齐。"""
    output = bytearray()
    for block_y in range(0, height, 4):
        for block_x in range(0, width, 4):
            block = []
            for row in range(4):
                y = min(height - 1, block_y + row)
                for column in range(4):
                    x = min(width - 1, block_x + column)
                    offset = (y * width + x) * 4
                    block.append((pixels[offset], pixels[offset + 1],
                                  pixels[offset + 2], pixels[offset + 3]))
            output += encode_bc7_block(block)
    return bytes(output)


# ---------------------------------------------------------------- ETC2 RGB8
# 移动端（GLES 3.0）没有 BC7，运行时原本回退到 RGBA8，1024² 全 mip 链 5.6 MB、
# 每 texel 4 字节。而 surfaceAtlas 的 alpha 在着色器里**从未被读取**——
# `color = baked.rgb * normalResponse.rgb + vec3(normalResponse.a)` 里那个 a 来自
# 法线图集。所以只需要 RGB，ETC2 RGB8（4×4 块 64 bit = 0.5 B/px）就够：
# 比 RGBA8 省 8 倍、比 BC7 还省一半，且 GLES 3.0 强制支持。
# 下面是一个只用 ETC1 兼容「个体模式」的编码器：每块试两种翻转划分 × 8 张修改表，
# 取平方误差最小的组合。sRGB 字节直接在 8 位域上量化，误差落在 sRGB 空间，
# 视觉上比在线性域量化更均匀。
ETC2_MODIFIERS = ((2, 8), (5, 17), (9, 29), (13, 42),
                  (18, 60), (24, 80), (33, 106), (47, 183))


def _etc2_clamp(value):
    return 0 if value < 0 else (255 if value > 255 else value)


def _etc2_fit_group(colors):
    """给一组像素选基色与修改表。

    返回 (error, base4, table, indices)，其中 base4 是 4 位/通道的个体模式基色。
    个体模式的两个子块各带一个 4 位基色，重建值 = base4 * 17 + modifier。

    修改表不全试：每张表的最大 modifier 是递增的（8, 17, 29, …, 183），
    块内相对基色的最大偏差决定至少要多大跨度，所以只需在"刚好够"和"再小一档"
    两张表里挑最优。8 张表降到 2 张，烘焙时间从近两分钟压到十几秒，
    而 ETC1 的量化质量由跨度覆盖决定，这一点没有损失。
    """
    count = len(colors)
    average = [sum(c[channel] for c in colors) / count for channel in range(3)]
    base4 = [min(15, max(0, int(round(average[channel] / 17.0)))) for channel in range(3)]
    rebuilt = (base4[0] * 17, base4[1] * 17, base4[2] * 17)
    spread = 0
    for color in colors:
        for channel in range(3):
            delta = color[channel] - rebuilt[channel]
            if delta < 0:
                delta = -delta
            if delta > spread:
                spread = delta
    start = len(ETC2_MODIFIERS) - 1
    for index, (_, large) in enumerate(ETC2_MODIFIERS):
        if large >= spread:
            start = index
            break
    tables = (start - 1, start) if start > 0 else (start,)
    best = None
    for table in tables:
        small, large = ETC2_MODIFIERS[table]
        # 四个候选值一次算好：clamp 从「每像素每候选 3 次」降到「每条表 12 次」。
        values = (
            (_etc2_clamp(rebuilt[0] - large), _etc2_clamp(rebuilt[1] - large),
             _etc2_clamp(rebuilt[2] - large)),
            (_etc2_clamp(rebuilt[0] - small), _etc2_clamp(rebuilt[1] - small),
             _etc2_clamp(rebuilt[2] - small)),
            (_etc2_clamp(rebuilt[0] + small), _etc2_clamp(rebuilt[1] + small),
             _etc2_clamp(rebuilt[2] + small)),
            (_etc2_clamp(rebuilt[0] + large), _etc2_clamp(rebuilt[1] + large),
             _etc2_clamp(rebuilt[2] + large)),
        )
        error = 0
        indices = []
        for color in colors:
            red, green, blue = color
            best_index = 0
            best_error = 1 << 30
            for index in range(4):
                values_at = values[index]
                dr = red - values_at[0]
                dg = green - values_at[1]
                db = blue - values_at[2]
                delta = dr * dr + dg * dg + db * db
                if delta < best_error:
                    best_error = delta
                    best_index = index
            error += best_error
            indices.append(best_index)
        if best is None or error < best[0]:
            best = (error, base4, table, indices)
    return best


def _etc2_encode_block(pixels, block_x, block_y, width, height):
    """把一个 4×4 块编码为 8 字节的 ETC2 RGB8；边缘块用边缘像素补齐。"""
    block = []
    for row in range(4):
        y = min(height - 1, block_y + row)
        for column in range(4):
            x = min(width - 1, block_x + column)
            offset = (y * width + x) * 4
            block.append((pixels[offset], pixels[offset + 1], pixels[offset + 2]))
    best = None
    for flip in (0, 1):
        groups = ([], [])
        for row in range(4):
            for column in range(4):
                half = (column // 2) if flip == 0 else (row // 2)
                groups[half].append(block[row * 4 + column])
        first = _etc2_fit_group(groups[0])
        second = _etc2_fit_group(groups[1])
        total = first[0] + second[0]
        if best is None or total < best[0]:
            best = (total, flip, first, second)
    _, flip, first, second = best
    # 逐像素把索引放回 16 个位置：ETC1 的索引位序是列优先，(x * 4 + y) * 2。
    indices = [0] * 16
    cursor = [0, 0]
    for row in range(4):
        for column in range(4):
            half = (column // 2) if flip == 0 else (row // 2)
            indices[row * 4 + column] = (first[3] if half == 0 else second[3])[cursor[half]]
            cursor[half] += 1
    value = 0
    for row in range(4):
        for column in range(4):
            value |= (indices[row * 4 + column] & 3) << ((column * 4 + row) * 2)
    base1, base2 = first[1], second[1]
    if base1 == [15, 15, 15]:
        # 个体模式下 R1=G1=B1=15 且 diff=0 是 T/H/planar 模式的标记位，
        # 会被解码器当成别的模式而整块花掉。红色亮度权重最低，降一级的代价最小。
        base1 = [14, 15, 15]
    value |= base1[0] << 60
    value |= base2[0] << 56
    value |= base1[1] << 52
    value |= base2[1] << 48
    value |= base1[2] << 44
    value |= base2[2] << 40
    value |= first[2] << 37
    value |= second[2] << 34
    value |= flip << 32  # diff = 0（个体模式）
    return struct.pack("<Q", value)


def etc2_encode_level(pixels, width, height):
    """把一个 RGBA8 mip 层编码为 ETC2 RGB8；每层按 4×4 块铺满。"""
    output = bytearray()
    for block_y in range(0, height, 4):
        for block_x in range(0, width, 4):
            output += _etc2_encode_block(pixels, block_x, block_y, width, height)
    return bytes(output)


def bake_surface():
    """六个朝向共享一张昼夜图集；alpha 只保留柔和自发光，不烘焙白色窄光条。"""
    pixels = bytearray(ATLAS_SIZE * ATLAS_SIZE * 4)
    for dark in (False, True):
        block = NIGHT_OFFSET if dark else 0
        for face, (left, top, width, height) in FACE_RECTS.items():
            for row in range(height):
                v = row / (height - 1)
                for column in range(width):
                    u = column / (width - 1)
                    offset = ((block + top + row) * ATLAS_SIZE + left + column) * 4
                    store_texel(pixels, offset, face_sample(face, u, v, dark))
    for block in (0, NIGHT_OFFSET):
        fill_gutters(pixels, block)
    levels = build_mips(pixels)
    (OUTPUT / "archive-baked-surface.bin").write_bytes(b"".join(levels))
    (OUTPUT / "archive-baked-surface-bc7.bin").write_bytes(
        b"".join(bc7_encode_level(level, max(1, ATLAS_SIZE >> index), max(1, ATLAS_SIZE >> index))
                 for index, level in enumerate(levels)))
    # Android 用：GLES 没有 BC7，ETC2 RGB8 只要 BC7 一半、RGBA8 八分之一的带宽。
    # 只在构建 Android 资源时输出，桌面 / iOS 的产物逐字节不变。
    if os.environ.get("RHINE_BAKE_ETC2", "").strip() == "1":
        (OUTPUT / "archive-baked-surface-etc2.bin").write_bytes(
            b"".join(etc2_encode_level(level, max(1, ATLAS_SIZE >> index), max(1, ATLAS_SIZE >> index))
                     for index, level in enumerate(levels)))
    return levels


def field_sample(position, normal):
    """离线累积面积光、层间吸收和磨砂散射；运行时不再逐光源求值。"""
    x, y, z = position
    shell_count = max(abs(z) / 0.62 - 0.35, 0)
    layer = 0.78 ** min(shell_count, 12)
    result = [0.0, 0.0, 0.0]
    for index, emitter in enumerate(EMITTERS):
        offset = [emitter[axis] - position[axis] for axis in range(3)]
        distance_squared = sum(value * value for value in offset)
        inverse_distance = 1 / math.sqrt(max(distance_squared, 0.04))
        cosine = sum(normal[axis] * offset[axis] * inverse_distance for axis in range(3))
        scattering = 0.82 * (0.26 + 0.74 * max(-cosine, 0) ** 0.65)
        power = 0.85 if index < 3 else 0.28
        intensity = power * (max(cosine, 0) * 0.28 + scattering) / (0.30 + distance_squared)
        for channel, (tint, absorption) in enumerate(zip((1.0, 0.72, 0.38), (0.32, 0.90, 2.5))):
            result[channel] += tint * intensity * math.exp(-absorption * 0.12 / max(abs(cosine), 0.22))
    return (*[value * layer for value in result], 1.0)


def bake_light_field():
    """把固定局部光场的二十四个高度切片打包成三维纹理：宽=6*96，高=96，深度=24。"""
    pixels = bytearray(FIELD_SIZE * 6 * FIELD_SIZE * HEIGHT_SLICES * 4)
    offset = 0
    for height in range(HEIGHT_SLICES):
        y = -0.4 + height * 5.2 / (HEIGHT_SLICES - 1)
        for row in range(FIELD_SIZE):
            z = -7 + row * 14 / (FIELD_SIZE - 1)
            for column in range(FIELD_SIZE * 6):
                face = column // FIELD_SIZE
                x = -9 + (column % FIELD_SIZE) * 18 / (FIELD_SIZE - 1)
                store_texel(pixels, offset, field_sample((x, y, z), NORMALS[face]))
                offset += 4
    (OUTPUT / "archive-baked-light.bin").write_bytes(pixels)


def bake_normal_response():
    """预积分倒角朝向的明暗与柔和高光，避免运行时计算 BRDF 或采样环境光。"""
    size = 128
    pixels = bytearray()
    for row in range(size * 2):
        dark = row >= size
        v = 2 * (row % size) / (size - 1) - 1
        for column in range(size):
            u = 2 * column / (size - 1) - 1
            normal = [u, v, 1 - abs(u) - abs(v)]
            if normal[2] < 0:
                normal[0] = (1 - abs(v)) * (1 if u >= 0 else -1)
                normal[1] = (1 - abs(u)) * (1 if v >= 0 else -1)
            length = math.sqrt(sum(value * value for value in normal))
            normal = [value / length for value in normal]
            primary_axis = max(range(3), key=lambda axis: abs(normal[axis]))
            primary_face = primary_axis + (0 if normal[primary_axis] >= 0 else 3)
            primary = face_sample(primary_face, 0.5, 0.5, dark)
            weights = [abs(value) ** 2 for value in normal]
            total = sum(weights)
            blended = [0.0, 0.0, 0.0]
            for axis, weight in enumerate(weights):
                face = axis + (0 if normal[axis] >= 0 else 3)
                color = face_sample(face, 0.5, 0.5, dark)
                for channel in range(3):
                    blended[channel] += color[channel] * weight / total
            cosine = max(0, sum(normal[axis] * (-0.48, 0.80, 0.36)[axis] for axis in range(3)))
            highlight = 0.18 * cosine**24 * (0.25 if dark else 1)
            response = [min(4, blended[channel] / max(primary[channel], 0.0001)) for channel in range(3)]
            if NORMAL_RGBA8:
                # Android：8 位 UNORM 代替 RGBA16F，逐像素带宽从 8 B 降到 4 B
                # （夜间要采两次，等于每片元省 8 B）。rgb 存 response/4（值域 0..4），
                # a 存 highlight/0.25（值域 0..0.18）；着色器按同样比例乘回，
                # 见 CMake 的 RHINE_NORMAL_RGBA8。
                pixels.extend((
                    max(0, min(255, int(round(response[0] * 63.75)))),
                    max(0, min(255, int(round(response[1] * 63.75)))),
                    max(0, min(255, int(round(response[2] * 63.75)))),
                    max(0, min(255, int(round(highlight * 1020.0)))),
                ))
            else:
                pixels.extend(struct.pack("<4e", *response, highlight))
    (OUTPUT / "archive-baked-normal.bin").write_bytes(pixels)


def main():
    """构建期生成二进制贴图；表面/光场为 sRGB8，法线响应仍为 RGBA16F。"""
    OUTPUT.mkdir(parents=True, exist_ok=True)
    bake_surface()
    bake_light_field()
    bake_normal_response()


if __name__ == "__main__":
    main()
