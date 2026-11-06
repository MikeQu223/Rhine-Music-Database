#!/usr/bin/env python3
"""APK zopfli 后处理（可选工具；构建链默认不调用它）。

背景：AGP 打包对 DEFLATE 条目用的是 zlib 默认档位，.so 是否压缩取决于
useLegacyPackaging（本工程 Qt/android/build.gradle 默认 true，即 .so 也压缩）。
zopfli 是 DEFLATE 的高强度编码器——输出仍是合法 DEFLATE 流，任何解压器都能读，
对已压缩数据通常再省 3~8%，.so / .dex 这类大条目收益最明显。

为什么不能压完就收工：v2/v3 签名的摘要覆盖整个 ZIP 字节流，任何重写都会让签名
失效。所以流程必须是「重压 → zipalign → 重新签名」，全部由本脚本完成，用的钥匙
与 scripts/build-android.cjs 生成的是同一把（output/android-work/debug.keystore，
alias rhine-debug）。zipalign 必须在签名之前——签名后再对齐会破坏 v2/v3 块，
这也是构建脚本里的既定顺序。

条目策略：
  · STORED（resources.arsc、noCompress 'rcc' 的 Qt 资源等）：字节原样拷贝，
    对齐交给 zipalign；
  · DEFLATED：zopfli 重压（≥ --min-size 的条目才值得花迭代时间）；没占到便宜、
    或低于门槛的，字节级保留原始 DEFLATE 流（不经过 zlib 重压，避免引入随机差异）。

并行：zopfli 的 C 扩展不释放 GIL（实测双线程 1.08x，等于没有），所以用
ProcessPoolExecutor（--workers，默认核心数*4）。每个条目一个任务，主进程按 ZIP
顺序写回；峰值内存约 300 MB（原文 + 原 DEFLATE 流 + 结果同时在内存）。

zopfli 参数（--iterations，默认 15）：
  官方默认、也是 zip 命令行工具的默认。每加一档迭代收益不足 0.5%、耗时线性翻倍，
  15 → 50 的实测差距一般 <0.3%，不值得。blocksplitting 保持开（默认最多 15 块，
  每块独立统计，对 .so 这种分段特征明显的数据有效）。

用法：
  VENV=/home/aibeto/.workbuddy/binaries/python/envs/default/bin/python3
  $VENV scripts/optimize-apk.py output/RhineMusicDatabase-<hash>-android-arm64-v8a.apk

依赖：
  · pip install zopfli（0.4.x 的接口在 zopfli.zopfli.compress，输出 zlib 容器，
    本脚本剥成 raw deflate 并做 round-trip 校验）；
  · SDK build-tools 的 zipalign 与 apksigner（自动取版本最高的目录）。
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import zipfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SDK = Path.home() / "Android" / "Sdk"
KEYSTORE = ROOT / "output/android-work/debug.keystore"


def newest_build_tools() -> Path:
    bt = SDK / "build-tools"
    if not bt.is_dir():
        sys.exit(f"找不到 SDK build-tools：{bt}")
    dirs = [p for p in bt.iterdir() if p.is_dir() and p.name[:1].isdigit()]
    if not dirs:
        sys.exit(f"SDK build-tools 目录为空：{bt}")
    return max(dirs, key=lambda p: [int(x) for x in p.name.split(".")])


def zopfli_raw_deflate(data: bytes, iterations: int) -> bytes:
    """zopfli 压缩并剥掉 zlib 容器，返回 raw deflate（zip 条目的存储格式）。"""
    from zopfli.zopfli import compress as zopfli_compress

    out = zopfli_compress(data, numiterations=iterations, gzip_mode=0)
    # zlib 容器 = 2 字节头（CMF/FLG，CM=8 即 deflate，0x78 系）+ raw deflate + Adler-32。
    if len(out) < 8 or out[0] != 0x78:
        raise RuntimeError("zopfli 输出不是预期的 zlib 容器")
    raw = out[2:-4]
    if zlib.decompressobj(-15).decompress(raw) != data:
        raise RuntimeError("zopfli round-trip 校验失败，拒绝写入")
    return raw


def raw_deflate_of(src: zipfile.ZipFile, info: zipfile.ZipInfo) -> bytes:
    """从 ZIP 里取出条目的原始 DEFLATE 字节流（zipfile 公开 API 只给解压结果）。

    local header 的 name/extra 长度可能与 central directory 不同（zipalign 会给
    STORED 条目的 local extra 插对齐 padding），所以要读 local header 自己声明
    的长度来定位数据起点。
    """
    src.fp.seek(info.header_offset)
    header = src.fp.read(30)
    name_len = int.from_bytes(header[26:28], "little")
    extra_len = int.from_bytes(header[28:30], "little")
    src.fp.seek(info.header_offset + 30 + name_len + extra_len)
    return src.fp.read(info.compress_size)


class RawDeflateInjector:
    """让 zipfile.writestr 写入预备好的 raw DEFLATE 流，而不是让它自己再压一遍。

    CPython 的 zipfile 对 DEFLATED 条目通过 zlib.compressobj(level, DEFLATED, -15)
    生成压缩器；zopfli 的输出同样是 wbits=-15 的 raw DEFLATE。这里替换 zipfile
    模块命名空间里的 compressobj，让压缩器第一次 compress() 返回我们的 payload。
    CRC 与 file_size 仍按 writestr 收到的原始数据计算，不需要伪造任何元数据。
    """

    def __init__(self) -> None:
        self.payload: bytes | None = None
        self._orig = None

    def __enter__(self) -> "RawDeflateInjector":
        import zipfile as zf

        self._orig = zf.zlib.compressobj
        injector = self

        def fake_compressobj(*_args, **_kwargs):
            payload = injector.payload
            injector.payload = None

            class _Chunk:
                def __init__(self):
                    self._sent = False

                def compress(self, _data):
                    if not self._sent:
                        self._sent = True
                        return payload
                    return b""

                def flush(self):
                    return b""

            return _Chunk()

        zf.zlib.compressobj = fake_compressobj
        return self

    def __exit__(self, *_exc) -> bool:
        import zipfile as zf

        zf.zlib.compressobj = self._orig
        return False


def run(tool: Path, args: list[str]) -> None:
    proc = subprocess.run([str(tool), *args], capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"{tool.name} 退出码 {proc.returncode}\n{proc.stdout}\n{proc.stderr}")


def scan(src_path: Path, min_size: int) -> None:
    with zipfile.ZipFile(src_path) as src:
        stored = deflate = 0
        print(f"{'大小':>12}  {'现压缩':>12}  条目")
        for info in src.infolist():
            mark = "STORED " if info.compress_type == zipfile.ZIP_STORED else "DEFLATE"
            if info.compress_type == zipfile.ZIP_STORED:
                stored += info.compress_size
            else:
                deflate += info.compress_size
            flag = (
                "  <- 会重压"
                if info.compress_type == zipfile.ZIP_DEFLATED
                and info.file_size >= min_size
                else ""
            )
            print(
                f"{info.file_size:>12,}  {info.compress_size:>12,}  [{mark}] {info.filename}{flag}"
            )
        print(
            f"\nSTORED 合计 {stored / 1048576:.1f} MB，DEFLATE 合计 {deflate / 1048576:.1f} MB"
        )


def rewrite(
    src_path: Path, tmp_path: Path, iterations: int, min_size: int, workers: int
) -> None:
    # zopfli 的 C 扩展不释放 GIL（实测双线程 1.08x ≈ 无加速），并行只能用进程池。
    # 提前把所有条目读进内存再统一提交：进程间 pickle 几 MB 数据的传输开销
    # 相对 zopfli 每秒百 KB 的计算量可以忽略。峰值内存约「原文 + 原 DEFLATE 流 +
    # zopfli 结果」≈ 300 MB，本工程 APK 规模下可接受。
    from concurrent.futures import ProcessPoolExecutor
    import os

    entries = []  # (info, data, original_raw, future|None)，写出时必须保持 ZIP 顺序
    pool = None
    if workers > 1:
        pool = ProcessPoolExecutor(max_workers=workers)
    with zipfile.ZipFile(src_path) as src:
        for info in src.infolist():
            data = src.read(info.filename)
            if info.compress_type == zipfile.ZIP_STORED:
                entries.append((info, data, None, None))
                continue
            if info.compress_type != zipfile.ZIP_DEFLATED:
                sys.exit(f"不支持的压缩类型 {info.compress_type}：{info.filename}")

            original = raw_deflate_of(src, info)
            # 保险：保留原流前先确认它真的是这条目原文的合法 DEFLATE 流。
            # （第一版这里有个偏移 bug，写出的 APK 里 manifest 是 0 字节压缩流，
            # zipalign 不校验放行、apksigner 才炸——round-trip 在写入前就拦住。）
            if zlib.decompressobj(-15).decompress(original) != data:
                sys.exit(f"原始 DEFLATE 流与内容不符（zip 结构异常）：{info.filename}")

            future = None
            if pool is not None and len(data) >= min_size:
                future = pool.submit(zopfli_raw_deflate, data, iterations)
            entries.append((info, data, original, future))

    recompressed = kept = stored_n = 0
    saved = 0
    with zipfile.ZipFile(tmp_path, "w") as dst, RawDeflateInjector() as inj:
        for info, data, original, future in entries:
            ni = zipfile.ZipInfo(info.filename, date_time=info.date_time)
            ni.compress_type = info.compress_type
            ni.external_attr = info.external_attr
            ni.internal_attr = info.internal_attr
            ni.create_system = info.create_system
            ni.comment = info.comment

            if original is None:  # STORED
                dst.writestr(ni, data)
                stored_n += 1
                continue

            payload = original
            if future is not None:
                candidate = future.result()
                if len(candidate) < len(original):
                    payload = candidate
                    recompressed += 1
                    saved += len(original) - len(candidate)
                else:
                    kept += 1
            else:
                kept += 1
            inj.payload = payload
            ni.compress_type = zipfile.ZIP_DEFLATED
            dst.writestr(ni, data)

    if pool is not None:
        pool.shutdown()
    print(
        f"重写完成：zopfli 重压 {recompressed} 条、保留原流 {kept} 条、STORED {stored_n} 条；"
        f"DEFLATE 净省 {saved / 1048576:.1f} MB"
    )


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "apk", type=Path, help="输入 APK（未签名或已签名均可，末尾统一重签）"
    )
    ap.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="输出路径（默认 <stem>-zopfli<suffix>）",
    )
    ap.add_argument(
        "--iterations", type=int, default=15, help="zopfli 迭代次数（默认 15）"
    )
    ap.add_argument(
        "--min-size",
        type=int,
        default=65536,
        help="只重压大于该字节数的条目（默认 64 KiB）",
    )
    ap.add_argument(
        "--workers",
        type=int,
        default=os.cpu_count() * 4,
        help="并行压缩进程数（默认 核心数*4；1 = 串行）",
    )
    ap.add_argument("--scan", action="store_true", help="只列条目清单，不重压")
    ap.add_argument(
        "--keep-unsigned",
        action="store_true",
        help="不重新签名（保持 zipalign 后的未签名 APK）",
    )
    args = ap.parse_args()

    if not args.apk.exists():
        sys.exit(f"找不到 {args.apk}")
    if args.scan:
        scan(args.apk, args.min_size)
        return

    tools = newest_build_tools()
    zipalign = tools / "zipalign"
    apksigner = tools / "apksigner"
    print(f"build-tools: {tools.name}（zipalign / apksigner）")

    out_path = args.output or args.apk.with_name(
        f"{args.apk.stem}-zopfli{args.apk.suffix}"
    )
    tmp_zip = out_path.with_suffix(".tmp.zip")
    aligned = out_path.with_suffix(".tmp.aligned")

    before = args.apk.stat().st_size
    rewrite(args.apk, tmp_zip, args.iterations, args.min_size, args.workers)

    # zipalign 必须在签名之前（v2/v3 签名块按对齐后的布局生成）。-p 对未压缩的
    # .so 做页对齐；本工程 legacy packaging 下 .so 已压缩，这一位无害。
    run(zipalign, ["-p", "-f", "4", str(tmp_zip), str(aligned)])

    if args.keep_unsigned or not KEYSTORE.exists():
        if not args.keep_unsigned:
            print(f"警告：找不到 {KEYSTORE}，输出保持未签名（与 --keep-unsigned 等价）")
        aligned.replace(out_path)
    else:
        run(
            apksigner,
            [
                "sign",
                "--ks",
                str(KEYSTORE),
                "--ks-key-alias",
                "rhine-debug",
                "--ks-pass",
                "pass:android",
                "--key-pass",
                "pass:android",
                "--out",
                str(out_path),
                str(aligned),
            ],
        )
        run(apksigner, ["verify", str(out_path)])
        print("apksigner verify 通过")

    tmp_zip.unlink(missing_ok=True)
    aligned.unlink(missing_ok=True)
    after = out_path.stat().st_size
    print(
        f"{args.apk.name}: {before / 1048576:.1f} MB -> {out_path.name}: {after / 1048576:.1f} MB"
        f"（Δ{(after - before) / 1048576:+.1f} MB）"
    )


if __name__ == "__main__":
    main()
