#!/usr/bin/env python3
"""验证部署后的 Qt 应用，不读取用户凭据或访问网易云。"""
import json
import os
import plistlib
import re
import pathlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
# 根据产物类型选择静态审计规则，允许在构建主机检查另一平台的部署目录。
mac = app.suffix.lower() == ".app"
# AppDir 是 AppImage 的前缀目录布局，程序与运行时都按 usr/ 前缀存放。
linux = (app / "usr/bin/RhineMusicDatabase").is_file()
if mac:
    resources = app / "Contents/Resources"
    executable = app / "Contents/MacOS/RhineMusicDatabase"
elif linux:
    resources = app / "usr/bin/resources"
    executable = app / "usr/bin/RhineMusicDatabase"
else:
    resources = app / "resources"
    executable = app / "RHINE MUSIC DATABASE.exe"
assert executable.is_file()
if mac:
    service_app = app / "Contents/Helpers/RhinePlaybackService.app"
    service = service_app / "Contents/MacOS/RhinePlaybackService"
    helper_info = plistlib.loads((service_app / "Contents/Info.plist").read_bytes())
    main_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert helper_info.get("LSUIElement") is True, "Playback helper must be a Dock-hidden agent"
    assert helper_info["CFBundleIdentifier"] != main_info["CFBundleIdentifier"], "Shared application identity"
    assert not (executable.parent / "RhinePlaybackService").exists(), "Obsolete unbundled helper"
else:
    service = executable.parent / ("RhinePlaybackService.exe" if not linux else "RhinePlaybackService")
assert service.is_file(), "Missing independent playback service"
for pattern in (
    "diagnose-windows-audio*",
    "windows-audio-snapshot.ps1",
    "AudioRouteProbe*",
    "RhinePlatformRegression*",
    "RhineDesktopFixture*",
):
    assert not list(app.rglob(pattern)), "Local diagnostic or regression tool entered release package"
assert not re.search(
    rb"cc\.[a-z]+\.rhine\.(?:native-panel|music)", executable.read_bytes()
), "Legacy runtime namespace"
for name in [
    "slots.json",
    "scene-fixture.json",
    "misans-glyphs.json",
    "LICENSE",
    "NOTICE",
]:
    assert (resources / name).is_file(), name
for name in (
    "room-pmrem.bin",
    "dfg-lut.bin",
    "ao-kernel.bin",
    "ao-noise.bin",
    "runtime.js",
    "timeline.js",
    "qt-logic.js",
    "archive-cassette-geometry.json",
    "archive-assembly-geometry.json",
):
    assert not (resources / name).exists(), "Retired script or geometry copy entered package: " + name
# 桥接单文件
assert (resources / "MusicBridge" / "worker.cjs").is_file(), "Missing bridge bundle"
assert (resources / "MusicBridge" / "xhr-sync-worker.js").is_file(), "Missing jsdom sync XHR worker"
assert not (resources / "MusicBridge" / "node_modules").exists(), "node_modules must be bundled"
fixture = json.loads((resources / "scene-fixture.json").read_text(encoding="utf-8"))
assert (
    len(fixture["frame"]["view"]) == 16 and len(fixture["frame"]["projection"]) == 16 and fixture["rays"]
), "Invalid offline scene fixture"
if mac:
    with (app / "Contents/Info.plist").open("rb") as file:
        identity = plistlib.load(file)
    assert identity["CFBundleIdentifier"] == "rhine.music.database", "Wrong system application identity"
    assert identity["CFBundleExecutable"] == "RhineMusicDatabase"
    libraries = subprocess.check_output(["otool", "-L", str(executable)], text=True)
    assert "QtQuick" in libraries and "QtQml" in libraries
    assert "QtWidgets" in libraries, "Missing desktop tray runtime dependency"
    assert (
        app / "Contents/Frameworks/QtWidgets.framework/QtWidgets"
    ).is_file(), "Missing bundled desktop tray runtime"
    service_libraries = subprocess.check_output(["otool", "-L", str(service)], text=True)
    assert (
        "QtQuick" not in service_libraries and "QtQml" not in service_libraries
    ), "Renderer linked into playback service"
    assert not any(
        "/Users/" in line or "/opt/homebrew/" in line for line in service_libraries.splitlines()[1:]
    ), "Undeployed playback dependency"
    assert "libswift" not in libraries.lower(), "Swift runtime dependency found"
    assert not any(p.suffix == ".swift" for p in app.rglob("*") if p.is_file())
    assert not any(p.name in {"node_modules", ".git", ".DS_Store"} for p in app.iterdir())
    assert not any(
        "/Users/" in line or "/opt/homebrew/" in line for line in libraries.splitlines()[1:]
    ), "Undeployed Qt dependency"
    load_commands = subprocess.check_output(["otool", "-l", str(executable)], text=True)
    search_paths = [line.strip() for line in load_commands.splitlines() if line.strip().startswith("path ")]
    assert not any(
        "/Users/" in line or "/opt/homebrew/" in line for line in search_paths
    ), "Local binary search path"
    conf = (resources / "qt.conf").read_text(encoding="utf-8")
    assert "/Users/" not in conf and "/opt/homebrew/" not in conf, "Local QML search path"
    assert not (app / "Contents/PlugIns/sqldrivers").exists(), "Unneeded database plugins"
    assert (
        app / "Contents/PlugIns/multimedia/libffmpegmediaplugin.dylib"
    ).is_file(), "Missing FFmpeg backend"
    for library in ("avcodec", "avformat", "avutil", "swresample", "swscale"):
        assert list((app / "Contents/Frameworks").glob(f"lib{library}.*.dylib")), f"Missing {library} runtime"
    audio_libraries = list((app / "Contents/Frameworks").glob("lib*.dylib"))
    for binary in list((app / "Contents/PlugIns").rglob("*.dylib")) + audio_libraries:
        dependencies = subprocess.check_output(["otool", "-L", str(binary)], text=True)
        assert not any(
            "/Users/" in line or "/Applications/Postgres.app/" in line or "/opt/homebrew/" in line
            for line in dependencies.splitlines()
            if line.startswith("\t")
        ), str(binary)
elif linux:
    # 审计验证包内是否自洽，必须排除构建机注入的搜索路径：LD_LIBRARY_PATH
    # 的优先级高于 RUNPATH，CI 的 Qt 目录会盖过 $ORIGIN，把漏部署的库掩盖掉。
    # 只允许引用随包 Qt 与系统图形栈，不得回落到构建机安装前缀。
    bundled = app / "usr/lib"
    # 清空构建机注入的路径后，ldd 只按程序自身的 RUNPATH 解析，
    # 得到与用户直接双击运行时一致的结果。
    probe = {key: value for key, value in os.environ.items() if key != "LD_LIBRARY_PATH"}

    def resolve(binary):
        """返回 (缺失库, 落到包外的库) 两个列表。

        ldd 在包内缺少某个库时会静默回落到构建机的系统目录，
        那样审计永远发现不了漏部署。这里显式记录解析结果并与包内目录比对。
        """
        output = subprocess.run(["ldd", str(binary)], text=True, capture_output=True, env=probe).stdout
        missing, outside = [], []
        for line in output.splitlines():
            if "not found" in line:
                missing.append(line.split("=>")[0].strip())
                continue
            if "=> /" not in line:
                continue
            name, target = line.split("=>", 1)[0].strip(), line.split("=>")[1].split(" (")[0].strip()
            if name.startswith("libQt6") and pathlib.Path(target).resolve().parent != bundled.resolve():
                outside.append(name)
        return missing, outside

    libraries = subprocess.run(["ldd", str(executable)], text=True, capture_output=True, env=probe).stdout
    service_libraries = subprocess.run(
        ["ldd", str(service)], text=True, capture_output=True, env=probe
    ).stdout
    assert "libQt6Quick" not in service_libraries and "libQt6Qml" not in service_libraries
    missing, outside = resolve(service)
    assert not missing and not outside, "Undeployed playback dependency: " + str(missing + outside)
    assert "libQt6Core" in libraries and "libQt6Quick" in libraries, "Missing Qt runtime"
    assert "not found" not in libraries, "Undeployed library dependency"
    assert (bundled / "libQt6Core.so.6").is_file(), "Qt runtime is not bundled"
    for pattern in ("libQt6Gui.so.6", "libQt6Quick.so.6", "libQt6Qml.so.6", "libQt6Multimedia.so.6"):
        assert (bundled / pattern).is_file(), "Missing bundled Qt module: " + pattern
    for line in libraries.splitlines():
        if "=> /" in line:
            # ldd 保留 RUNPATH 里的 $ORIGIN，比较前先归一化到真实路径。
            target = pathlib.Path(line.split("=> ")[1].split(" (")[0]).resolve()
            name = target.name
            if name.startswith("libQt6"):
                assert target.parent == bundled.resolve(), "Qt library resolved outside package: " + name
    assert not list(bundled.rglob("libQt6WebEngine*")), "Unused Qt module entered the package"
    # 音视频运行时必须随包提供：只装 Qt 的机器没有系统 FFmpeg，
    # 缺库时要等到用户点播放才暴露。与 macOS、Windows 分支保持同一份清单。
    for library in ("avcodec", "avformat", "avutil", "swresample", "swscale"):
        assert list(bundled.glob(f"lib{library}.so.*")), "Missing FFmpeg runtime: " + library
    # 插件本身不带指向 usr/lib 的 RUNPATH，运行时靠 AppRun 设置的 LD_LIBRARY_PATH，
    # 因此按同一环境解析，才能发现真实的缺库。
    plugin_probe = dict(probe, LD_LIBRARY_PATH=str(bundled))
    for binary in list((app / "usr/plugins").rglob("*.so")) + list((app / "usr/qml").rglob("*.so")):
        output = subprocess.run(["ldd", str(binary)], text=True, capture_output=True, env=plugin_probe).stdout
        missing = [line.split("=>")[0].strip() for line in output.splitlines() if "not found" in line]
        assert not missing, f"{binary.relative_to(app)} has unresolved libraries: {', '.join(missing)}"
    assert (app / "usr/plugins/platforms/libqxcb.so").is_file(), "Missing X11 platform plugin"
    # 有意不打包 libX11 / libxcb 本体：它们归 Xorg 自己提供，包内再带一份容易和驱动、输入法、
    # 系统主题的 ABI 打架（上面按依赖解析的做法已经能发现"插件缺库"）。xcb-util 系列则相反，
    # 精简系统上常常没有，必须随包——缺了就是 "could not load the Qt platform plugin xcb"。
    for name in ("libxkbcommon-x11.so.0", "libxcb-cursor.so.0", "libxcb-icccm.so.4"):
        assert (bundled / name).is_file(), "Missing X11 helper library: " + name
    # ldd 只查静态依赖：符号缺失、GLX/EGL 集成装错版本都要等运行时才炸。
    # 用包内 LD_LIBRARY_PATH 真的 dlopen 一次平台插件，把这类问题留在构建机上。
    xcb_probe = dict(plugin_probe, QT_QPA_PLATFORM="offscreen")
    loaded = subprocess.run(
        [
            sys.executable,
            "-c",
            "import ctypes,sys; ctypes.CDLL(sys.argv[1], mode=ctypes.RTLD_GLOBAL)",
            str(app / "usr/plugins/platforms/libqxcb.so"),
        ],
        text=True,
        capture_output=True,
        env=xcb_probe,
    )
    assert loaded.returncode == 0, "X11 platform plugin cannot be loaded: " + loaded.stderr.strip()
    # X11 平台插件不自带 OpenGL 上下文；GLX/EGL 集成缺失时会在初始化 RHI 时直接退出。
    xcb_gl = app / "usr/plugins/xcbglintegrations"
    assert any(
        (xcb_gl / name).is_file() for name in ("libqxcb-glx-integration.so", "libqxcb-egl-integration.so")
    ), "Missing X11 OpenGL integration plugin"
    # Wayland 插件名随打包方式不同：发行版是 libqwayland.so，
    # 官方 Qt 包拆成 libqwayland-egl.so 与 libqwayland-generic.so，两者都接受。
    assert list((app / "usr/plugins/platforms").glob("libqwayland*.so")), "Missing Wayland platform plugin"
    assert (
        app / "usr/plugins/platforms/libqoffscreen.so"
    ).is_file(), "Missing offscreen test platform plugin"
    assert (app / "usr/plugins/multimedia/libffmpegmediaplugin.so").is_file(), "Missing FFmpeg audio backend"
    assert (app / "usr/plugins/tls/libqopensslbackend.so").is_file(), "Missing TLS backend"
    assert (app / "usr/qml/QtQuick").is_dir(), "Missing QtQuick QML module"
    assert (resources / "MusicBridge/node").is_file(), "Missing bundled Node runtime"
    conf = (app / "usr/bin/qt.conf").read_text(encoding="utf-8")
    assert "/Users/" not in conf and "/opt/" not in conf, "Local QML search path"
    assert (app / "AppRun").is_file() and (app / "rhine-music-database.desktop").is_file()
    assert not list(app.rglob("*.swift"))
    assert not list(app.rglob("sqldrivers"))
else:
    debug = (app / "Qt6Cored.dll").is_file()
    suffix = "d.dll" if debug else ".dll"
    assert (app / ("Qt6Widgets" + suffix)).is_file(), "Missing desktop tray runtime"
    for name in ("msvcp140", "vcruntime140", "vcruntime140_1"):
        assert (app / (name + suffix)).is_file(), "Missing local MSVC runtime: " + name
    assert not list(app.glob("vc_redist*.exe")), "Portable package must not require a runtime installer"
    assert (app / "Qt6Quick.dll").is_file() or (app / "Qt6Quickd.dll").is_file()
    assert (app / "Qt6Multimedia.dll").is_file() or (
        app / "Qt6Multimediad.dll"
    ).is_file(), "Missing Qt audio runtime"
    assert (app / "multimedia/windowsmediaplugin.dll").is_file() or (
        app / "multimedia/windowsmediaplugind.dll"
    ).is_file(), "Missing Windows native compatibility audio backend"
    assert (app / "multimedia/ffmpegmediaplugin.dll").is_file() or (
        app / "multimedia/ffmpegmediaplugind.dll"
    ).is_file(), "Missing default FFmpeg audio backend"
    for library in ("avcodec", "avformat", "avutil", "swresample", "swscale"):
        assert list(app.glob(library + "-*.dll")), "Missing FFmpeg runtime: " + library
    assert (app / "platforms/qwindows.dll").is_file() or (app / "platforms/qwindowsd.dll").is_file()
    assert (app / "platforms/qoffscreen.dll").is_file() or (
        app / "platforms/qoffscreend.dll"
    ).is_file(), "Missing offscreen test platform plugin"
    assert (resources / "MusicBridge/node.exe").is_file()
    assert (app / "qml").is_dir()
    assert not list(app.rglob("*.swift"))
    assert not (app / "sqldrivers").exists()
result = {"qt_deployed": True, "swift_runtime_required": False, "locked_music_bridge": True}
pathlib.Path("output/qt-package-audit.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
print(json.dumps(result))
