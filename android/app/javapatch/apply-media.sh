#!/usr/bin/env bash
# 可重现的局部 jar 补丁（Qt6AndroidMultimedia.jar）。
#
# 与同目录的 apply.sh 同一套规矩：只改**本卡的 deploy 目录**里的那一份 jar，不动全局
# Qt SDK（output/dependencies/qt-android），不动任何冻结产物；从 src/ 现编现打，并核对
# class 的**内容** sha256（jar 级 sha 会随时间戳漂移，不能当补丁证据）。
#
# 被替换的类：org/qtproject/qt/android/multimedia/QtMultimediaUtils.class 与
# QtMultimediaUtils$OrientationListener.class。原因见
# src/org/qtproject/qt/android/multimedia/QtMultimediaUtils.java 的类注释：
# stock 的 setContext(Context) 把传进来的 Activity 存进 static m_context，且换 listener
# 时不 disable 旧的 —— 每过一个宿主周期就多一个指向已退休 Activity 的传感器回调，
# 静态字段又把 Activity 永久钉住。overlay 存 ApplicationContext 并显式退休旧 listener。
#
# **字节门禁**：本脚本不会安装"没登记过"的字节。EXPECTED.sha256 里没有 media: 两行时，
# 它会编出一份、把**它自己的** sha 打出来并以 3 退出（不碰 jar）。把这它打出来的两行
# 贴进 EXPECTED.sha256（或直接跑 --record 让它写），再重跑一次才会真正换进 jar。
# 这就是"recipe + EXPECTED + 源码三者可复现"的落地方式，也让 javac 版本漂移变成
# 显式失败而不是静默换字节。
#
# 用法：
#   android/app/javapatch/apply-media.sh [deploy-dir] [--record]
# deploy-dir 缺省 = $RHINE_QT_ANDROID_DEPLOY_DIR，再缺省 = 本卡 qt-build 的 staging。
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
card_root="$(cd "$here/../../.." && pwd)"
parity_root="$(cd "$card_root/../.." && pwd)"

deploy=""
record=0
for arg in "$@"; do
    case "$arg" in
        --record) record=1 ;;
        -*) echo "unknown option: $arg" >&2; exit 1 ;;
        *) deploy="$arg" ;;
    esac
done
deploy="${deploy:-${RHINE_QT_ANDROID_DEPLOY_DIR:-$parity_root/builds/NATIVE-RECOVERY-132/qt-build/Qt/android-build}}"

# androiddeployqt 只把实际链接到的 Qt 模块的 jar 放进 libs/。本工程链接 Qt6::Multimedia
# （Qt/src/AudioPlayer.cpp 用 QMediaPlayer），所以正常构建里它一定在；如果这一版构建确实
# 没带多媒体，跳过比硬失败诚实（也避免把补丁装到不存在的模块上）。
mjar="$deploy/libs/Qt6AndroidMultimedia.jar"

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
[ -f "$expected" ] || { echo "missing $expected" >&2; exit 1; }

utils_rel='org/qtproject/qt/android/multimedia/QtMultimediaUtils.class'
listener_rel='org/qtproject/qt/android/multimedia/QtMultimediaUtils$OrientationListener.class'
utils_src="$here/src/org/qtproject/qt/android/multimedia/QtMultimediaUtils.java"

echo "== javapatch (multimedia) =="
echo "deploy   : $deploy"
echo "jar      : $mjar"

if [ ! -f "$mjar" ]; then
    echo "status   : SKIP (Qt6AndroidMultimedia.jar is not deployed in this build)"
    exit 0
fi
[ -f "$utils_src" ] || { echo "missing $utils_src" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "android  : $android_jar"
echo "javac    : $(javac -version 2>&1)"
echo "src sha  : sha256sum=$(sha256sum "$utils_src" | cut -d' ' -f1)"

javac -nowarn -Xlint:-options --release 17 \
      -cp "$android_jar:$mjar" \
      -d "$work/classes" \
      "$utils_src"

[ -f "$work/classes/$utils_rel" ] || { echo "javac did not emit $utils_rel" >&2; exit 1; }
[ -f "$work/classes/$listener_rel" ] || { echo "javac did not emit $listener_rel" >&2; exit 1; }

compiled_utils="$(sha256sum "$work/classes/$utils_rel" | cut -d' ' -f1)"
compiled_listener="$(sha256sum "$work/classes/$listener_rel" | cut -d' ' -f1)"

want_utils="$(awk '$2 == "media:'"$utils_rel"'" {print $1}' "$expected")"
want_listener="$(awk '$2 == "media:'"$listener_rel"'" {print $1}' "$expected")"

echo "compiled : utils=$compiled_utils listener=$compiled_listener"
echo "expected : utils=${want_utils:-<none>} listener=${want_listener:-<none>}"

if [ -z "$want_utils" ] || [ -z "$want_listener" ]; then
    lines="$(printf '%s  media:%s\n%s  media:%s\n' \
        "$compiled_utils" "$utils_rel" "$compiled_listener" "$listener_rel")"
    if [ "$record" = "1" ]; then
        {
            { grep -v -F "media:$utils_rel" "$expected" || true; } | { grep -v -F "media:$listener_rel" || true; }
            printf '%s\n' "$lines"
        } > "$expected.new"
        mv "$expected.new" "$expected"
        echo "recorded : wrote 2 media: lines into $expected"
        echo "$lines"
        echo "status   : RECORDED ONLY — the jar was NOT modified."
        echo "next     : rerun without --record to install (and commit EXPECTED.sha256):"
        echo "           $0 $deploy"
        exit 0
    fi
    echo "FAIL: EXPECTED.sha256 has no media: entries for the multimedia overlay." >&2
    echo "  Paste these two lines into $expected and rerun, or run: $0 $deploy --record" >&2
    printf '%s\n' "$lines" >&2
    exit 3
fi

if [ "$compiled_utils" != "$want_utils" ] || [ "$compiled_listener" != "$want_listener" ]; then
    echo "FAIL: compiled class bytes differ from the recorded EXPECTED.sha256" >&2
    echo "  want utils=$want_utils got=$compiled_utils" >&2
    echo "  want listener=$want_listener got=$compiled_listener" >&2
    echo "  (javac drift or an edited overlay: re-record deliberately, then re-verify on device)" >&2
    exit 2
fi

echo "before   : sha256=$(sha256sum "$mjar" | cut -d' ' -f1) entries=$(unzip -l "$mjar" | awk 'END{print $2}')"
( cd "$work/classes" && jar uf "$mjar" "$utils_rel" "$listener_rel" )
echo "after    : sha256=$(sha256sum "$mjar" | cut -d' ' -f1) entries=$(unzip -l "$mjar" | awk 'END{print $2}')"

got_utils="$(unzip -p "$mjar" "$utils_rel" | sha256sum | cut -d' ' -f1)"
got_listener="$(unzip -p "$mjar" "$listener_rel" | sha256sum | cut -d' ' -f1)"
echo "patched class content sha256:"
printf '%s  %s\n' "$got_utils" "$utils_rel"
printf '%s  %s\n' "$got_listener" "$listener_rel"

if [ "$got_utils" != "$want_utils" ] || [ "$got_listener" != "$want_listener" ]; then
    echo "FAIL: jar entries do not match EXPECTED.sha256 after installation" >&2
    exit 2
fi
echo "verify   : OK (matches EXPECTED.sha256)"
