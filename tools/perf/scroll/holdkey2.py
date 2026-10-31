#!/usr/bin/env python3
"""按住某个键 hold 秒（uinput 虚拟键盘，走真实输入路径）。

用法: holdkey.py <hold_seconds> [keycode]
KEY_DOWN=108。按下后保持 hold 秒再松开；内核自动重复会让合成器产生连续按键。

选择 uinput 而不是合成器私有接口，是因为这台机器上没有 wtype/ydotool，
而 niri 的 IPC 不提供按键注入。
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


class E(ctypes.Structure):
    _fields_ = [("s", ctypes.c_long), ("u", ctypes.c_long),
                ("t", ctypes.c_uint16), ("c", ctypes.c_uint16), ("v", ctypes.c_int32)]


def write_event(fd, etype, code, value):
    os.write(fd, bytes(E(0, 0, etype, code, value)))


def create_keyboard(name=b"mb-kbd"):
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
    fcntl.ioctl(fd, UI_SET_KEYBIT, KEYCODE)
    buf = name + b"\0" * (80 - len(name))
    buf += struct.pack("HHHH", 3, 0x1234, 0x5678, 1) + struct.pack("I", 0)
    for arr in ([0] * 64, [0] * 64, [0] * 64, [0] * 64):
        buf += struct.pack("64i", *arr)
    os.write(fd, buf)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(0.7)
    return fd


KEYCODE = 108


def main():
    global KEYCODE
    hold = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0
    KEYCODE = int(sys.argv[2]) if len(sys.argv) > 2 else 108
    fd = create_keyboard()
    try:
        print(f"press keycode={KEYCODE}", flush=True)
        write_event(fd, EV_KEY, KEYCODE, 1)
        write_event(fd, EV_SYN, SYN_REPORT, 0)
        time.sleep(hold)
        write_event(fd, EV_KEY, KEYCODE, 0)
        write_event(fd, EV_SYN, SYN_REPORT, 0)
        print(f"release after {hold}s", flush=True)
        time.sleep(0.5)
    finally:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)


if __name__ == "__main__":
    main()
