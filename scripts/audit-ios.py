"""检查最终 iOS 应用的架构、平台、资源和动态依赖；不代替真机功能验收。"""

import json
import ctypes
import os
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
simulator = "--simulator" in sys.argv
expected_platform = "IOSSIMULATOR" if simulator else "IOS"
info = plistlib.loads((app / "Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "rhine.music.database"
assert "audio" in info["UIBackgroundModes"]
landscape_orientations = {"UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"}
phone_orientations = info["UISupportedInterfaceOrientations"]
assert set(phone_orientations) == {"UIInterfaceOrientationPortrait"}, "iPhone must be portrait only"
ipad_orientations = info["UISupportedInterfaceOrientations~ipad"]
assert set(ipad_orientations) == landscape_orientations, "iPad must be landscape only"
assert info.get("UIRequiresFullScreen") is True
assert "CADisableMinimumFrameDurationOnPhone" not in info, "iPhone refresh opt-in must remain disabled"


def system_bundle_identifier(directory):
    """通过安装服务同源的 CFBundle 识别布局，避免只解析 plist 而漏掉系统拒绝。"""
    core = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    pointer = ctypes.c_void_p
    core.CFURLCreateFromFileSystemRepresentation.argtypes = [
        pointer,
        ctypes.c_char_p,
        ctypes.c_long,
        ctypes.c_bool,
    ]
    core.CFURLCreateFromFileSystemRepresentation.restype = pointer
    core.CFBundleCreate.argtypes = [pointer, pointer]
    core.CFBundleCreate.restype = pointer
    core.CFBundleGetIdentifier.argtypes = [pointer]
    core.CFBundleGetIdentifier.restype = pointer
    core.CFStringGetCString.argtypes = [pointer, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
    core.CFStringGetCString.restype = ctypes.c_bool
    core.CFRelease.argtypes = [pointer]
    encoded = os.fsencode(directory)
    url = core.CFURLCreateFromFileSystemRepresentation(None, encoded, len(encoded), True)
    if not url:
        return ""
    bundle = core.CFBundleCreate(None, url)
    try:
        if not bundle:
            return ""
        identifier = core.CFBundleGetIdentifier(bundle)
        buffer = ctypes.create_string_buffer(1024)
        if identifier and core.CFStringGetCString(identifier, buffer, len(buffer), 0x08000100):
            return buffer.value.decode("utf-8")
        return ""
    finally:
        if bundle:
            core.CFRelease(bundle)
        core.CFRelease(url)


recognized_identifier = system_bundle_identifier(app)
assert recognized_identifier == info["CFBundleIdentifier"], "Apple CFBundle cannot identify application"
assert not any(child.name.lower() == "resources" for child in app.iterdir()), "Legacy bundle layout"
resources = app / "RhineAssets"
for name in [
    "slots.json",
    "RhineMiSans-regular.otf",
    "MusicBridge/worker.cjs",
    "MusicBridge/ios-runtime.cjs",
    "MusicBridge/xhr-sync-worker.js",
    "MusicBridge/NODE-LICENSE",
    "third-party/nodejs-mobile/source.json",
]:
    assert (resources / name).is_file(), f"Missing iOS resource: {name}"
assert not (resources / "MusicBridge/node").exists()
frameworks = app / "Frameworks"
for name in ["NodeMobile", "libavcodec", "libavformat", "libavutil", "libswresample", "libswscale"]:
    assert (frameworks / f"{name}.framework" / name).is_file(), f"Missing framework: {name}"
executables = [app / "RhineMusicDatabase"] + [
    folder / folder.stem for folder in frameworks.glob("*.framework")
]
for executable in executables:
    platform = subprocess.check_output(["xcrun", "vtool", "-show-build", executable], text=True)
    assert f"platform {expected_platform}\n" in platform, f"Wrong platform: {executable}"
    architectures = subprocess.check_output(["lipo", "-archs", executable], text=True).strip()
    allowed_architectures = {"arm64", "x86_64"} if simulator else {"arm64"}
    assert "arm64" in architectures.split(), f"Missing arm64: {executable}"
    assert set(architectures.split()) <= allowed_architectures, executable
    dependencies = subprocess.check_output(
        ["otool", "-arch", "arm64", "-L", executable], text=True
    ).splitlines()[1:]
    for dependency in dependencies:
        library = dependency.strip().split(" (", 1)[0]
        assert "swift" not in library.lower(), f"Unexpected runtime: {library}"
        assert library.startswith(("@rpath/", "/usr/lib/", "/System/Library/")), library
        if library.startswith("@rpath/"):
            assert (frameworks / library.removeprefix("@rpath/")).is_file(), library
for file in app.rglob("*"):
    assert file.name not in {"node_modules", "credentials.json", "cookies.json", ".DS_Store"}, file
report = {
    "platform": expected_platform,
    "system_bundle_identifier": recognized_identifier,
    "architecture": "arm64",
    "frameworks_checked": len(executables) - 1,
    "swift_runtime_required": False,
    "device_functionality_verified": False,
}
print(json.dumps(report, indent=4))
