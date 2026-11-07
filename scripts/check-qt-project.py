#!/usr/bin/env python3
"""检查源码及构建命令，防止重新引入旧版原生依赖。"""

import json
import os
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
# 这条守卫针对的是"本项目自己的源码里混进 Swift"，第三方目录不算：
# third_party 里的 Qt 子模块自带 iOS 平台的 .swift 和 Swift 示例，node_modules / 构建产物同理。
SKIPPED_DIRECTORIES = {
    ".git",
    ".workbuddy",
    "build",
    "generated",
    "node_modules",
    "output",
    "third_party",
    "vendor",
}
legacy_sources = []
for folder, directories, files in os.walk(root):
    directories[:] = [name for name in directories if name not in SKIPPED_DIRECTORIES]
    for name in files:
        if name.lower().endswith(".swift"):
            legacy_sources.append(str((Path(folder) / name).relative_to(root)))
assert not legacy_sources, f"Legacy sources remain: {legacy_sources}"
assert not (root / ".swift-format").exists()
manifest = json.loads((root / "package.json").read_text(encoding="utf-8"))
assert not any(
    "swift" in key.lower() or "swift" in value.lower()
    for key, value in manifest["scripts"].items()
)
for path in [
    root / "build.sh",
    root / "share.sh",
    *sorted((root / "scripts").glob("*.sh")),
]:
    source = path.read_text(encoding="utf-8")
    assert not re.search(
        r"\b(?:swiftc|swift|swift-format)\b|Sources/.*\.swift", source
    ), str(path)
cmake = (root / "CMakeLists.txt").read_text(encoding="utf-8")
assert re.search(r"LANGUAGES\s+CXX", cmake) and not re.search(
    r"\bSwift\b|\.swift\b", cmake
)
for path in (root / "Qt/src").glob("*"):
    if path.suffix in {".h", ".cpp"}:
        source = path.read_text(encoding="utf-8")
        assert not re.search(
            r"JavaScriptCore|CoreGraphics|CoreText|<Metal/|<simd/", source
        ), str(path)
assert not (root / "Qt/src/MetalScene.mm").exists()
assert not (root / "Resources/Archive.metal").exists()
identity = "rhine.music.database"
assert f'set(RHINE_APPLICATION_ID "{identity}")' in cmake
plist = (root / "Qt/Info.plist.in").read_text(encoding="utf-8")
assert "<key>CFBundleIdentifier</key><string>@RHINE_APPLICATION_ID@</string>" in plist
assert "<key>CFBundleExecutable</key><string>RhineMusicDatabase</string>" in plist
runtime_sources = "\n".join(
    path.read_text(encoding="utf-8")
    for path in (root / "Qt/src").glob("*")
    if path.suffix in {".cpp", ".h", ".mm"}
)
assert not re.search(r"QJSEngine|QJSValue|QWebEngine|QWebView", runtime_sources), (
    "Script runtime in native business"
)
for retired in [
    "Scene",
    "Qt/logic",
    "Qt/src/SceneRuntime.cpp",
    "scripts/bundle-qt.mjs",
]:
    assert not (root / retired).exists(), (
        f"Retired application source remains: {retired}"
    )
assert not re.search(
    r"cc\.[a-z]+\.rhine|native-panel|RhineMusicPanel", runtime_sources + plist + cmake
), "Legacy application namespace"
assert (
    "kSecAttrService : QString::fromLatin1(AppIdentity::Id).toNSString()"
    in runtime_sources
)
assert "setApplicationName(AppIdentity::Id)" in runtime_sources
assert "setOrganizationDomain(AppIdentity::Id)" in runtime_sources

assert (root / "Qt/src/PlatformWindows.cpp").exists()
assert not (root / "output/RhineNativePanel.app").exists()
assert not (root / "output/qt-reference").exists()
result = {
    "swift_source_files": 0,
    "swift_compiler_required": False,
    "build_and_test_aliases_removed": True,
}
output = root / "output/qt-source-audit.json"
output.parent.mkdir(exist_ok=True)
output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
print("Qt source tree and build commands: no legacy language dependencies")
