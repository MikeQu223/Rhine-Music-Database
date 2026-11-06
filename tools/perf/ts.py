#!/usr/bin/env python3
"""给每一行日志打上精确时间戳（秒，相对启动），供测速解析。

Qt 的诊断行是 1s CoarseTimer 打印的，行与行之间的名义间隔并不精确；
带上真实时间戳后，累计计数器（FG presented/rendered）与每秒计数（render/s）
都能折算成准确的帧率。

用法：<程序> 2>&1 | python3 -u ts.py > run.log
"""

import sys
import time

start = time.monotonic()
out = sys.stdout
for line in sys.stdin:
    out.write("%.3f\t%s" % (time.monotonic() - start, line))
    out.flush()
