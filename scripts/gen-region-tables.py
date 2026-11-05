#!/usr/bin/env python3
"""生成 Android 内置的地区表（仅中国大陆 / 欧洲），IPv4 与 IPv6 各一张。

数据来源：RIPE Stat 的 country-resource-list（合并各 RIR 的国家分配），按国家取前缀。
输出：
  Qt/android/res/raw/ipv4_regions.bin
  Qt/android/res/raw/ipv6_regions.bin

IPv4 格式（大端）：
  magic  "RHIP"        4 字节
  version uint8 = 1    1 字节
  reserved             3 字节
  count  uint32        4 字节
  records[count]：start uint32, end uint32, region uint8

IPv6 格式（大端）：
  magic  "RH6P"        4 字节
  version uint8 = 1    1 字节
  reserved             3 字节
  count  uint32        4 字节
  records[count]：start_hi uint64, start_lo uint64, end_hi uint64, end_lo uint64, region uint8
    （128 位地址拆成两个 64 位大端整数，Java 侧用无符号比较）

region: 1 = 中国大陆，2 = 欧洲（EU + EEA + 英国 + 瑞士）

两种前缀写法都要处理：CIDR（a.b.c.d/len、2001:db8::/32）与闭区间（a.b.c.d-e.f.g.h）。
区间已排序并合并相邻段，Java 侧做二分查找。表只用于"是否需要弹隐私许可"，
不追求精确到城市；漏判最多是少弹或多弹一次同意框。

用法：
  python3 scripts/gen-region-tables.py            # 复用 .workbuddy/tmp/geo 下的缓存
  python3 scripts/gen-region-tables.py --refresh  # 重新抓取
"""

import ipaddress
import json
import pathlib
import struct
import sys
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = ROOT / ".workbuddy/tmp/geo"
RAW = ROOT / "Qt/android/res/raw"
OUTPUT_V4 = RAW / "ipv4_regions.bin"
OUTPUT_V6 = RAW / "ipv6_regions.bin"

REGION_CN = 1
REGION_EU = 2

# 欧洲：欧盟 27 国 + EEA（挪威/冰岛/列支敦士登）+ 英国 + 瑞士。
EUROPE = [
    "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR",
    "DE", "GR", "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL",
    "PL", "PT", "RO", "SK", "SI", "ES", "SE",
    "NO", "IS", "LI", "GB", "CH",
]
COUNTRIES = {"CN": REGION_CN, **{code: REGION_EU for code in EUROPE}}


def fetch(code: str, refresh: bool) -> dict:
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / f"{code.lower()}.json"
    if refresh or not path.exists():
        url = f"https://stat.ripe.net/data/country-resource-list/data.json?resource={code}"
        for attempt in range(3):
            try:
                with urllib.request.urlopen(url, timeout=60) as response:
                    path.write_bytes(response.read())
                break
            except Exception as error:  # noqa: BLE001 - 网络问题统一重试
                if attempt == 2:
                    raise SystemExit(f"{code}: 下载失败：{error}")
                time.sleep(2)
    payload = json.loads(path.read_text(encoding="utf-8"))
    return payload["data"]["resources"]


def to_ipv4(text: str) -> int:
    octets = [int(part) for part in text.split(".")]
    return (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]


def to_ipv6(text: str) -> int:
    return int(ipaddress.IPv6Address(text))


def to_range(prefix: str, parse, bits: int):
    """把 CIDR 或闭区间写法统一成 (start, end)。"""
    if "-" in prefix:
        start, end = prefix.split("-", 1)
        return parse(start.strip()), parse(end.strip())
    address, _, length = prefix.partition("/")
    start = parse(address.strip())
    size = 1 << (bits - int(length))
    return start, start + size - 1


def merge(ranges):
    """按 region 合并重叠与相邻区间；跨 region 的相邻段不合并。"""
    ranges.sort(key=lambda item: (item[0], item[1]))
    merged = []
    for start, end, region in ranges:
        if merged and merged[-1][2] == region and start <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end), region)
        else:
            merged.append((start, end, region))
    return merged


def main() -> int:
    refresh = "--refresh" in sys.argv
    v4_ranges = []
    v6_ranges = []
    for code, region in COUNTRIES.items():
        resources = fetch(code, refresh)
        v4 = resources.get("ipv4", [])
        v6 = resources.get("ipv6", [])
        for prefix in v4:
            start, end = to_range(prefix, to_ipv4, 32)
            v4_ranges.append((start, end, region))
        for prefix in v6:
            start, end = to_range(prefix, to_ipv6, 128)
            v6_ranges.append((start, end, region))
        print(f"  {code}: v4 {len(v4)} 段，v6 {len(v6)} 段")

    v4 = merge(v4_ranges)
    v6 = merge(v6_ranges)

    RAW.mkdir(parents=True, exist_ok=True)
    with OUTPUT_V4.open("wb") as stream:
        stream.write(b"RHIP" + bytes([1, 0, 0, 0]) + struct.pack(">I", len(v4)))
        for start, end, region in v4:
            stream.write(struct.pack(">IIB", start, end, region))

    mask = (1 << 64) - 1
    with OUTPUT_V6.open("wb") as stream:
        stream.write(b"RH6P" + bytes([1, 0, 0, 0]) + struct.pack(">I", len(v6)))
        for start, end, region in v6:
            stream.write(
                struct.pack(
                    ">QQQQB",
                    (start >> 64) & mask,
                    start & mask,
                    (end >> 64) & mask,
                    end & mask,
                    region,
                )
            )

    for path, records in ((OUTPUT_V4, v4), (OUTPUT_V6, v6)):
        size = path.stat().st_size
        print(f"写入 {path.relative_to(ROOT)}：{len(records)} 段，{size} 字节（{size / 1024:.0f} KB）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
