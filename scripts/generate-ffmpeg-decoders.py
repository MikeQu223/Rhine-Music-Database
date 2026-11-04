#!/usr/bin/env python3
"""生成 Linux 随包 FFmpeg 的音频解码器白名单（vendor/ffmpeg/decoders-linux.json）。

只读 third_party/ffmpeg 源码，不需要先构建：

1. 从 libavcodec/allcodecs.c 取出全部 decoder 名；
2. 剔除 lib* 前缀的外部库解码器（--disable-autodetect 下不会编译，写进白名单会让 configure 报错）；
3. 剔除 configure 里声明了 _decoder_deps 的条目——这类要么依赖 GPL 组件（lgpl_gpl，会把整个构建
   拖成 GPL），要么依赖平台专有框架（audiotoolbox 等），在 Linux 上不可用或不合规；
4. 按 FFCodec 定义块里的 .p.type 判定类型，只保留 AVMEDIA_TYPE_AUDIO；
5. 用宏声明的解码器（pcm_*、adpcm_*、dsd_*、dpcm、aac_latm）在源码里看不到 .p.type，
   按命名规则归为音频。

升级 FFmpeg 后重跑本脚本即可刷新清单。用法：python3 scripts/generate-ffmpeg-decoders.py
"""
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "third_party/ffmpeg/libavcodec")
OUT = os.path.join(ROOT, "vendor/ffmpeg/decoders-linux.json")

DECLARE = re.compile(r"const\s+FFCodec\s+ff_([A-Za-z0-9_]+)_decoder\s*=\s*\{")
EXTERN = re.compile(r"extern\s+const\s+FFCodec\s+ff_([A-Za-z0-9_]+)_decoder;")
# configure 里的条件解码器：<name>_decoder_deps="lgpl_gpl" 之类
WITH_DEPS = re.compile(r'^(\w+)_decoder_deps="([^"]*)"', re.MULTILINE)
# deps 只由这些库组成的解码器可以安全启用；其余（lgpl_gpl、audiotoolbox、videotoolbox 等）
# 要么会把构建拖成 GPL，要么依赖平台专有框架。
SAFE_DEPS = {"avcodec", "avutil", "swresample", "swscale"}

# 宏声明、源码里不含 .p.type 的音频解码器
MACRO_AUDIO_PREFIX = ("adpcm_", "pcm_", "dsd_")
MACRO_AUDIO_EXACT = {
    "aac_latm",
    "cbd2_dpcm",
    "derf_dpcm",
    "gremlin_dpcm",
    "interplay_dpcm",
    "roq_dpcm",
    "sdx2_dpcm",
    "sol_dpcm",
    "wady_dpcm",
    "xan_dpcm",
}
# 测试/合成音源，播放器用不到
EXCLUDE = {"anull", "comfortnoise", "ffwavesynth"}


def block_after(text, start):
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    return text[start : start + 4000]


def collect():
    audio = set()
    for dirpath, _dirs, files in os.walk(SRC):
        for name in files:
            if not name.endswith(".c"):
                continue
            text = open(os.path.join(dirpath, name), encoding="utf-8", errors="replace").read()
            for m in DECLARE.finditer(text):
                block = block_after(text, text.index("{", m.end() - 1))
                if "AVMEDIA_TYPE_AUDIO" in block:
                    audio.add(m.group(1))

    externs = set(EXTERN.findall(open(os.path.join(SRC, "allcodecs.c"), encoding="utf-8").read()))
    for name in externs:
        if name.startswith(MACRO_AUDIO_PREFIX) or name in MACRO_AUDIO_EXACT:
            audio.add(name)

    configure = open(os.path.join(ROOT, "third_party/ffmpeg/configure"), encoding="utf-8").read()
    unsafe = {
        name for name, deps in WITH_DEPS.findall(configure) if not set(deps.split()).issubset(SAFE_DEPS)
    }

    return sorted(
        name
        for name in audio
        if name in externs and not name.startswith("lib") and name not in EXCLUDE and name not in unsafe
    )


def main():
    decoders = collect()
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(
            {
                "$comment": (
                    "Linux 随包 FFmpeg 的解码器白名单：音频与关联 MV 的 H.264 / HEVC 解码。"
                    "由 scripts/prepare-linux-ffmpeg.cjs 读取后拼成 --enable-decoder 参数；"
                    "新增格式时在此追加，或用 RHINE_FFMPEG_EXTRA_DECODERS 临时覆盖。"
                    "本文件由 scripts/generate-ffmpeg-decoders.py 生成。"
                ),
                "decoders": decoders,
                "videoDecoders": ["h264", "hevc"],
            },
            f,
            indent=4,
            ensure_ascii=False,
        )
        f.write("\n")
    print(f"{OUT}: {len(decoders)} 个音频解码器")


main()
