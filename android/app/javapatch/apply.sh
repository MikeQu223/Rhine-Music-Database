#!/usr/bin/env bash
# 可重现的局部 jar 补丁（NATIVE-RECOVERY-132R）。
#
# 背景：DEVICE-VISUAL-131 在 builds/DEVICE-VISUAL-131/javapatch 里手改过
# org.qtproject.qt.android 的两个类，但那份补丁只有 class 与改好的 jar，没有源码、
# 没有 recipe、也不在版本控制里——谁都无法从提交重建它，更无法核对"装的 jar 到底
# 是不是这份源码编出来的"。
#
# 这个脚本只改**本卡的 deploy 目录**里的 Qt6Android.jar：
#   - 不动全局 Qt SDK（output/dependencies/qt-android）；
#   - 不动任何冻结产物（builds/QT-OVERLAY-128、builds/DEVICE-VISUAL-131）；
#   - 从 src/ 现编现打，patch 前后 sha256、entry 数、源码 sha256、以及两个 class 的
#     **内容** sha256 全部打出来（jar 级 sha 会随 androiddeployqt 复制的时间戳漂移，
#     不能当补丁证据）。
#
# 幂等：jar 里这两个 class 的内容已与 EXPECTED.sha256 一致时直接跳过编译（构建每次都会
# 调它，跳过时只有几百毫秒）。androiddeployqt 每次 Qt 构建都会用 SDK 里的 stock jar
# 覆盖 deploy，所以这一步必须挂在构建里（见 android/app/build.gradle.kts 的
# patchQtAndroidJar），不能靠人手跑。
#
# 用法：
#   android/app/javapatch/apply.sh [deploy-dir]
# deploy-dir 缺省 = $RHINE_QT_ANDROID_DEPLOY_DIR，再缺省 = 本卡 qt-build 的 staging。
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
card_root="$(cd "$here/../../.." && pwd)"
parity_root="$(cd "$card_root/../.." && pwd)"

deploy="${1:-${RHINE_QT_ANDROID_DEPLOY_DIR:-$parity_root/builds/NATIVE-RECOVERY-132/qt-build/Qt/android-build}}"
jar="$deploy/libs/Qt6Android.jar"
# android.jar 只用来给 javac 提供 bootclasspath：先认环境变量，再认这台机器上的默认位置，
# 两者都没有就明确报错（不猜路径，避免编到一半才发现 classpath 是空的）。
sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [ -z "$sdk" ]; then
    for candidate in "$HOME/Android/Sdk" /opt/android-sdk /usr/lib/android-sdk; do
        if [ -d "$candidate/platforms" ]; then sdk="$candidate"; break; fi
    done
fi
[ -n "$sdk" ] && [ -d "$sdk" ] || { echo "ANDROID_SDK_ROOT/ANDROID_HOME 未设置，也找不到 Android SDK" >&2; exit 1; }
android_jar="$(ls -d "$sdk"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)"
[ -n "$android_jar" ] || { echo "在 $sdk/platforms 下找不到 android.jar" >&2; exit 1; }
expected="$here/EXPECTED.sha256"

[ -f "$jar" ] || { echo "missing $jar" >&2; exit 1; }
[ -f "$expected" ] || { echo "missing $expected" >&2; exit 1; }

class_sha() { unzip -p "$jar" "$1" | sha256sum | cut -d' ' -f1; }

want_delegate="$(awk '$2 ~ /QtEmbeddedDelegate.class$/ {print $1}' "$expected")"
want_view="$(awk '$2 ~ /QtView.class$/ {print $1}' "$expected")"
[ -n "$want_delegate" ] && [ -n "$want_view" ] || { echo "bad $expected" >&2; exit 1; }

patched_ok() {
  [ "$(class_sha org/qtproject/qt/android/QtEmbeddedDelegate.class)" = "$want_delegate" ] &&
  [ "$(class_sha org/qtproject/qt/android/QtView.class)" = "$want_view" ]
}

echo "== javapatch =="
echo "deploy   : $deploy"
echo "jar      : $jar"
echo "expected : delegate=$want_delegate view=$want_view"

if patched_ok; then
  echo "status   : already patched (skip) jar_sha256=$(sha256sum "$jar" | cut -d' ' -f1)"
  echo "patched class content sha256:"
  printf '%s  %s\n' "$want_delegate" org/qtproject/qt/android/QtEmbeddedDelegate.class
  printf '%s  %s\n' "$want_view" org/qtproject/qt/android/QtView.class
  exit 0
fi

[ -f "$android_jar" ] || { echo "missing $android_jar" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "android  : $android_jar"
echo "javac    : $(javac -version 2>&1)"
echo "src sha  :"
( cd "$here/src" && find . -name '*.java' -print0 | sort -z | xargs -0 sha256sum )
echo "before   : sha256=$(sha256sum "$jar" | cut -d' ' -f1) entries=$(unzip -l "$jar" | awk 'END{print $2}')"

# 两份被替换的类；其余 entry 原样保留。
javac -nowarn -Xlint:-options --release 17 \
      -cp "$android_jar:$jar" \
      -d "$work/classes" \
      "$here/src/org/qtproject/qt/android/QtEmbeddedDelegate.java" \
      "$here/src/org/qtproject/qt/android/QtView.java"

( cd "$work/classes" && jar uf "$jar" \
      org/qtproject/qt/android/QtEmbeddedDelegate.class \
      org/qtproject/qt/android/QtView.class )
[ -f "$work/classes/org/qtproject/qt/android/QtEmbeddedDelegate\$1.class" ] && \
( cd "$work/classes" && jar uf "$jar" 'org/qtproject/qt/android/QtEmbeddedDelegate$1.class' ) || true

echo "after    : sha256=$(sha256sum "$jar" | cut -d' ' -f1) entries=$(unzip -l "$jar" | awk 'END{print $2}')"
echo "patched class entries in jar:"
unzip -l "$jar" | grep -E 'QtEmbeddedDelegate|QtView' || true
echo "patched class content sha256:"
got_delegate="$(class_sha org/qtproject/qt/android/QtEmbeddedDelegate.class)"
got_view="$(class_sha org/qtproject/qt/android/QtView.class)"
printf '%s  %s\n' "$got_delegate" org/qtproject/qt/android/QtEmbeddedDelegate.class
printf '%s  %s\n' "$got_view" org/qtproject/qt/android/QtView.class

# 门禁：编出来的字节必须等于仓库里登记的期望值。javac 版本漂移会让它失败——那时要显式
# 更新 EXPECTED.sha256 并重新验证设备行为，而不是让补丁静默变成别的字节。
if [ "$got_delegate" != "$want_delegate" ] || [ "$got_view" != "$want_view" ]; then
  echo "FAIL: patched class bytes differ from android/app/javapatch/EXPECTED.sha256" >&2
  echo "  want delegate=$want_delegate got=$got_delegate" >&2
  echo "  want view    =$want_view got=$got_view" >&2
  exit 2
fi
echo "verify   : OK (matches EXPECTED.sha256)"
