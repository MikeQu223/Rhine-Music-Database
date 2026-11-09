#!/bin/sh
# tool/release/verify_signing.sh
#
# T53/C01-M12 离线签名门（只读核对）。计划 docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:726-732。
#
# 设计纪律（不可放宽，任何改动都属契约变更）：
#   * 只读取调用者给的本地文件；不联网、不下载、不安装/卸载、不改应用或用户数据、不写 APK。
#   * 不调用 adb / gradle / flutter / install / keytool -genkey / apksigner sign；
#     只用只读查询（apksigner verify --print-certs、keytool -printcert/-list、aapt dump badging）。
#   * 缺少签名材料时以非零码阻塞（BLOCKED），不伪造策略成功、不自造证书。
#
# 用法:
#   verify_signing.sh apk <apk>                    只读读出 APK 指纹/包名/versionCode 并比对 Qt 证书
#   verify_signing.sh keystore <keystore>          用 RHINE_KEYSTORE_PASSWORD 只读列出别名与证书指纹
#   verify_signing.sh session <old.apk> <new.apk>  校验同签名且 versionCode 单调递增
#   verify_signing.sh gradle <build.gradle.kts>    校验 release 不再使用 debug 签名配置
#
# 退出码:
#   0 PASS | 1 用法/IO 错误 | 2 证书未知或不匹配 | 3 缺少只读工具 | 4 两个 APK 签名不同
#   5 缺签名材料/口令（BLOCKED） | 6 旧 Flutter 证书（不可覆盖安装） | 7 release 使用 debug 签名
#   8 versionCode 非单调 | 9 applicationId 不是 rhine.music.database
set -eu

EXPECTED_QT_CERT_SHA256='39396cd06f2b7980302bad220ed071e09286540be4d224a2f9b047ca65205bdf'
OLD_FLUTTER_CERT_SHA256='7c514fe8cf95411117b6a4d1cba78768c1cda1d665c42f4828398d8587239dd4'
EXPECTED_PACKAGE='rhine.music.database'
QT_APK_VERSIONCODE_REF=1

log() { printf '%s\n' "$*"; }
die() { code=$1; shift; log "ERROR[$code] $*"; exit "$code"; }

usage() {
    cat <<'USAGE'
usage: verify_signing.sh <mode> ...
  apk <apk>                     APK SHA256 + 证书指纹 + 包名 + versionCode，并比对 Qt 证书
  keystore <keystore>           只读列出 keystore 别名与证书指纹（口令从 RHINE_KEYSTORE_PASSWORD 读）
  session <old.apk> <new.apk>   同签名 + versionCode 单调递增（覆盖安装前提）
  gradle <build.gradle.kts>     release 构建类型不得使用 debug signingConfig
只读脚本：不联网、不下载、不安装/卸载、不改数据、不签名、不构建。
USAGE
    exit 1
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 || die 3 "缺少只读工具: $1（拒绝用替代手段联网获取）"
}

# 打印 APK 的签名证书 SHA256（小写无冒号）。
apk_cert_sha256() {
    apk=$1
    [ -f "$apk" ] || die 1 "APK 不存在: $apk"
    [ -r "$apk" ] || die 1 "APK 不可读: $apk"
    if command -v apksigner >/dev/null 2>&1; then
        apksigner verify --print-certs "$apk" \
            | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -n 1
    else
        command -v keytool >/dev/null 2>&1 \
            || { printf 'ERROR[3] %s\n' "缺少只读工具: keytool（拒绝用替代手段联网获取）" >&2; exit 3; }
        keytool -printcert -jarfile "$apk" 2>/dev/null \
            | sed -n 's/^[[:space:]]*SHA256: //p' | head -n 1 | tr -d ':'
    fi | tr 'A-F' 'a-f'
}

# $1=apk $2=package|versionCode；工具缺失时返回 1（调用者决定是否阻塞）。
apk_manifest_field() {
    apk=$1
    field=$2
    [ -f "$apk" ] || die 1 "APK 不存在: $apk"
    if command -v aapt >/dev/null 2>&1; then
        case $field in
            package)
                aapt dump badging "$apk" 2>/dev/null \
                    | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n 1
                ;;
            versionCode)
                aapt dump badging "$apk" 2>/dev/null \
                    | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p" | head -n 1
                ;;
            *)
                return 1
                ;;
        esac
    elif command -v apkanalyzer >/dev/null 2>&1; then
        case $field in
            package) apkanalyzer manifest application-id "$apk" 2>/dev/null ;;
            versionCode) apkanalyzer manifest version-code "$apk" 2>/dev/null ;;
            *) return 1 ;;
        esac
    else
        return 1
    fi
}

# 返回码与 judge_cert 相同（0 匹配 Qt / 2 未知 / 6 旧 Flutter 证书）。
judge_cert() {
    cert=$1
    if [ "$cert" = "$EXPECTED_QT_CERT_SHA256" ]; then
        log "CERT=MATCH_QT_CERT sha256=$cert"
        return 0
    fi
    if [ "$cert" = "$OLD_FLUTTER_CERT_SHA256" ]; then
        log "CERT=INCOMPATIBLE_OLD_FLUTTER_CERT sha256=$cert"
        log "旧 Flutter 证书与 Qt 包签名不同：包名相同也必须拒装，禁止卸载/清数据/绕签名。"
        return 6
    fi
    log "CERT=UNKNOWN sha256=$cert"
    return 2
}

mode_apk() {
    apk=$1
    log "APK=$apk"
    need_tool sha256sum
    apk_sha=$(sha256sum "$apk") || die 1 "无法计算 APK SHA256: $apk"
    apk_sha=${apk_sha%% *}
    [ -n "$apk_sha" ] || die 1 "无法计算 APK SHA256: $apk"
    log "APK_SHA256=$apk_sha"
    cert=$(apk_cert_sha256 "$apk")
    [ -n "$cert" ] || die 2 "读不出证书指纹（APK 未签名？）"
    rc=0
    judge_cert "$cert" || rc=$?

    pkg=$(apk_manifest_field "$apk" package || true)
    vc=$(apk_manifest_field "$apk" versionCode || true)
    if [ -n "$pkg" ]; then
        log "PACKAGE=$pkg"
        if [ "$pkg" != "$EXPECTED_PACKAGE" ]; then
            log "PACKAGE_MISMATCH expected=$EXPECTED_PACKAGE：包名变化等同新应用，绝不承诺保留数据。"
            if [ "$rc" -eq 0 ]; then rc=9; fi
        fi
    else
        die 3 "无法只读读出 applicationId（缺 aapt/apkanalyzer）：未验证不得当成 PASS"
    fi
    if [ -n "$vc" ]; then
        log "VERSION_CODE=$vc"
        if [ "$vc" -lt "$QT_APK_VERSIONCODE_REF" ]; then
            log "VERSION_CODE 低于已安装 Qt 基线 $QT_APK_VERSIONCODE_REF：覆盖安装会被系统拒装。"
            if [ "$rc" -eq 0 ]; then rc=8; fi
        fi
    else
        die 3 "无法只读读出 versionCode（缺 aapt/apkanalyzer）：未验证不得当成 PASS"
    fi
    exit "$rc"
}

mode_keystore() {
    ks=$1
    [ -f "$ks" ] || die 5 "签名材料不可达（BLOCKED）: $ks；不得伪策略成功，交由 T53 owner 出正式迁移方案"
    if [ -z "${RHINE_KEYSTORE_PASSWORD:-}" ]; then
        die 5 "缺少 RHINE_KEYSTORE_PASSWORD（BLOCKED）：口令保管未核对完成，禁止绕过与自造证书"
    fi
    need_tool keytool
    out=$(keytool -list -v -keystore "$ks" -storepass:env RHINE_KEYSTORE_PASSWORD 2>&1) \
        || die 5 "keystore 不可读（别名/口令/保管缺失 → BLOCKED）"
    log "KEYSTORE_ALIASES:"
    printf '%s\n' "$out" | sed -n 's/^Alias name: /  /p'
    cert=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*SHA256: //p' | head -n 1 | tr -d ':' | tr 'A-F' 'a-f')
    [ -n "$cert" ] || die 5 "keystore 未给出可用证书指纹（BLOCKED）"
    log "KEYSTORE_CERT_SHA256=$cert"
    rc=0
    judge_cert "$cert" || rc=$?
    log "NOTE=口令只经 storepass:env 传入，本脚本不回显、不落盘、不改 keystore。"
    exit "$rc"
}

mode_session() {
    old=$1
    new=$2
    [ -f "$old" ] || die 1 "APK 不存在: $old"
    [ -f "$new" ] || die 1 "APK 不存在: $new"
    oldc=$(apk_cert_sha256 "$old")
    newc=$(apk_cert_sha256 "$new")
    log "OLD_CERT_SHA256=$oldc"
    log "NEW_CERT_SHA256=$newc"
    [ "$oldc" = "$newc" ] || die 4 "两个 APK 签名不同：不能覆盖安装，需走正式迁移（不可卸载/清数据绕过）"
    oldv=$(apk_manifest_field "$old" versionCode || true)
    newv=$(apk_manifest_field "$new" versionCode || true)
    if [ -z "$oldv" ] || [ -z "$newv" ]; then
        die 3 "缺少 aapt/apkanalyzer，无法只读读出 versionCode；不得改用 adb 查询"
    fi
    log "OLD_VERSION_CODE=$oldv"
    log "NEW_VERSION_CODE=$newv"
    [ "$newv" -gt "$oldv" ] || die 8 "versionCode 未严格递增：回滚包也必须用同签名更高 versionCode，不依赖 adb install -d"
    rc=0
    judge_cert "$newc" || rc=$?
    if [ "$rc" -eq 0 ]; then
        log "SESSION=SAME_SIGNER_AND_MONOTONIC_VERSION"
    fi
    exit "$rc"
}

mode_gradle() {
    f=$1
    [ -f "$f" ] || die 1 "文件不存在: $f"
    if grep -q 'signingConfigs.getByName("debug")' "$f"; then
        log "RELEASE_SIGNING=DEBUG_KEY_BLOCKED"
        grep -n 'signingConfigs.getByName("debug")' "$f" | sed -n 's/^/  /p'
        die 7 "release 构建类型仍用 debug 签名：该 APK 无法覆盖 Qt 安装，发布门未满足"
    fi
    log "RELEASE_SIGNING=NOT_DEBUG_CONFIGURED（仍需核对实际证书指纹，见 apk/keystore 模式）"
}

[ $# -ge 1 ] || usage
mode=$1
shift
case $mode in
    apk)
        [ $# -eq 1 ] || usage
        mode_apk "$1"
        ;;
    keystore)
        [ $# -eq 1 ] || usage
        mode_keystore "$1"
        ;;
    session)
        [ $# -eq 2 ] || usage
        mode_session "$1" "$2"
        ;;
    gradle)
        [ $# -eq 1 ] || usage
        mode_gradle "$1"
        ;;
    *)
        log "unknown mode: $mode"
        usage
        ;;
esac
