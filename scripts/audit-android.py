"""静态检查 Android 安装包：ABI、横屏声明、权限、Node 运行时与签名。

只读 APK 与 SDK 工具，不安装、不连接设备——真机验收不在这里做。
用法：python3 scripts/audit-android.py <apk> [--sdk <Android SDK 根目录>]
"""

import os
import pathlib
import re
import subprocess
import sys
import zipfile

apk = pathlib.Path(sys.argv[1]).resolve()
sdk = pathlib.Path(
    sys.argv[sys.argv.index("--sdk") + 1]
    if "--sdk" in sys.argv
    else os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME") or ""
)

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def build_tools():
    """取 SDK 里版本号最大的一套 build-tools；找不到就让调用方显式传 --sdk。"""
    base = sdk / "build-tools"
    if not base.is_dir():
        raise SystemExit(f"build-tools not found under {base}")
    versions = [name for name in os.listdir(base) if re.fullmatch(r"\d+\.\d+\.\d+", name)]

    def key(name):
        return tuple(int(part) for part in name.split("."))

    return base / sorted(versions, key=key)[-1]


tools = build_tools()
aapt2 = tools / "aapt2"
apksigner = tools / "apksigner"

check(apk.is_file(), f"APK missing: {apk}")
if failures:
    raise SystemExit("\n".join(failures))

with zipfile.ZipFile(apk) as archive:
    names = archive.namelist()
    # 地区表按 magic 识别，不依赖 res/raw 下的文件名——AGP 的资源优化可能重命名路径。
    region_tables = set()
    for name in names:
        if not name.startswith("res/") or name.endswith("/"):
            continue
        info = archive.getinfo(name)
        if info.file_size < 12:
            continue
        with archive.open(name) as stream:
            magic = stream.read(4)
        if magic in (b"RHIP", b"RH6P"):
            region_tables.add(magic)

# 1) 只允许 arm64-v8a：多 ABI 会让包体积翻倍，而这个包只承诺 arm64-v8a。
abis = sorted({name.split("/")[1] for name in names if name.startswith("lib/")})
check(abis == ["arm64-v8a"], f"unexpected ABIs: {abis}")

# 2) Node 运行时与主库必须在同一个 ABI 目录里，缺一个就是启动即崩。
libraries = {pathlib.PurePosixPath(name).name for name in names if name.startswith("lib/")}
check("libnode.so" in libraries, "libnode.so missing from the APK")
check(
    any(name.startswith("libRhineMusicDatabase") for name in libraries),
    f"application library missing; found {sorted(libraries)}",
)
check(
    any(name.startswith("libQt6Multimedia") for name in libraries),
    "Qt Multimedia backend missing from the APK",
)

# 2b) 地区表：缺任何一张，启动许可的判定就会退化（IPv6 缺失时纯 IPv6 网络直接按其他地区放行）。
check(b"RHIP" in region_tables, "IPv4 region table missing from the APK")
check(b"RH6P" in region_tables, "IPv6 region table missing from the APK")

# 3) 清单：包名、SDK 区间、横屏、权限。默认清单里的 screenOrientation 是 unspecified，
#    一旦有人覆盖掉我们的清单，这里就是唯一会失败的地方。
badging = subprocess.run(
    [str(aapt2), "dump", "badging", str(apk)], capture_output=True, text=True, check=True
).stdout
# aapt2 的 badging 用单引号包值，第一行就是 package 行。
check(
    "package: name='rhine.music.database'" in badging,
    f"unexpected package: {badging.splitlines()[0] if badging else '(empty)'}",
)
check("minSdkVersion:'28'" in badging, "minSdk is not 28")
check("targetSdkVersion:'36'" in badging, "targetSdk is not 36")
permissions = set(re.findall(r"uses-permission: name='([^']+)'", badging))
for required in ["android.permission.INTERNET", "android.permission.ACCESS_NETWORK_STATE"]:
    check(required in permissions, f"missing permission: {required}")
# 申请的权限越少越好：除下面几条外不应再要任何危险权限。
# DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION 是 AGP 在清单合并时自己注入的 signature 级
# 权限（androidx.core 的 registerReceiver(RECEIVER_NOT_EXPORTED) 需要它），不是我们
# 主动申请的，也不授予任何能力。
allowed = {
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    # 系统媒体控件：前台服务（API 28 起 startForeground 的硬性要求）+ Android 14 起
    # mediaPlayback 类型的配套权限（都是 normal 级，安装即授予）。
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK",
    # Android 13+ 运行时权限，拒绝时只是通知不显示。
    "android.permission.POST_NOTIFICATIONS",
    "rhine.music.database.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION",
    # Clarity 的传递依赖 com.android.installreferrer 自己声明的权限。它由 Play 商店
    # 按 signature 级授予，非 Play 分发的设备上等于没有；我们没有主动申请它，
    # 也无法在应用内取得。这条是清单合并带进来的，不是新增能力。
    "com.google.android.finsky.permission.BIND_GET_INSTALL_REFERRER_SERVICE",
}
check(permissions <= allowed, f"unexpected permissions: {sorted(permissions - allowed)}")

manifest = subprocess.run(
    [str(aapt2), "dump", "xmltree", "--file", "AndroidManifest.xml", str(apk)],
    capture_output=True,
    text=True,
    check=True,
).stdout
# 不锚定属性前缀：aapt2 各版本对 android: 命名空间的打印形式不同（前缀或完整 URI）。
# 枚举值也有两种打印：旧版给名字，新版给序号（screenOrientation 的 sensorLandscape = 6），
# 所以两种形式都接受。
check(
    re.search(r'screenOrientation[^=]*=(?:"sensorLandscape"|6)\b', manifest) is not None,
    "screenOrientation is not sensorLandscape",
)
check(
    "org.qtproject.qt.android.bindings.QtActivity" in manifest,
    "QtActivity entry point missing",
)
# 启动闸门必须是 launcher：QtActivity 抢回 LAUNCHER 就等于跳过了许可确认。
check(
    "rhine.music.database.ConsentActivity" in manifest,
    "ConsentActivity (startup consent gate) missing from manifest",
)
# Clarity 的初始化挂在 Application 上：清单里的 application 节点被改回 Qt 默认值时
# 应用照样能跑，但分析会静默失效，所以在这里钉死。
check(
    "rhine.music.database.RhineApplication" in manifest,
    "RhineApplication (Clarity entry point) missing from manifest",
)

# 4) 签名：只要验得过就行，具体证书由打包脚本决定（默认是工作区里的调试密钥）。
signature = subprocess.run(
    [str(apksigner), "verify", "--print-certs", "--min-sdk-version", "28", str(apk)],
    capture_output=True,
    text=True,
)
check(signature.returncode == 0, f"APK signature verification failed: {signature.stderr.strip()}")
certificate = ""
for line in signature.stdout.splitlines():
    if "certificate DN:" in line:
        certificate = line.split("certificate DN:", 1)[1].strip()
        break
check(bool(certificate), "no signing certificate found")

if failures:
    raise SystemExit("Android audit failed:\n" + "\n".join(f"  - {item}" for item in failures))

print(f"Android audit OK: {apk.name}")
print(f"  abi={abis[0]} libraries={len(libraries)} permissions={len(permissions)}")
print("  orientation=sensorLandscape minSdk=28 targetSdk=36")
print(f"  signer={certificate}")
