#!/usr/bin/env python3
"""依次单击若干按键（uinput 虚拟键盘）。

用法: press.py <keycode> [keycode ...]
KEY_ESC=1  KEY_F11=87  KEY_DOWN=108  KEY_UP=103  KEY_RIGHT=106

与 holdkey.py 的区别：这个是"按下即抬起"，按键之间留 0.9s 让界面完成重排。
注册了 1..255 全部 KEYBIT，所以任何键位都能发（holdkey 只注册了 KEY_DOWN）。
"""

import ctypes
import fcntl
import os
import struct
import sys
import time

UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
EV_SYN, EV_KEY = 0, 1
SYN_REPORT = 0
MAXKEY = 256


class Event(ctypes.Structure):
    _fields_ = [
        ("s", ctypes.c_long),
        ("u", ctypes.c_long),
        ("t", ctypes.c_uint16),
        ("c", ctypes.c_uint16),
        ("v", ctypes.c_int32),
    ]


def emit(fd, etype, code, value):
    os.write(fd, bytes(Event(0, 0, etype, code, value)))


def create(name=b"mb-kbd2"):
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
    for code in range(1, MAXKEY):
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    buf = name + b"\0" * (80 - len(name))
    buf += struct.pack("HHHH", 3, 0x1234, 0x5679, 1) + struct.pack("I", 0)
    for _ in range(4):
        buf += struct.pack("64i", *([0] * 64))
    os.write(fd, buf)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(0.7)
    return fd


def main():
    codes = [int(c) for c in sys.argv[1:]] or [1]
    fd = create()
    try:
        for code in codes:
            emit(fd, EV_KEY, code, 1)
            emit(fd, EV_SYN, SYN_REPORT, 0)
            time.sleep(0.08)
            emit(fd, EV_KEY, code, 0)
            emit(fd, EV_SYN, SYN_REPORT, 0)
            print(f"tap {code}", flush=True)
            time.sleep(0.9)
        time.sleep(0.4)
    finally:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)


if __name__ == "__main__":
    main()
