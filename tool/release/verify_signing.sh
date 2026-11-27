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
#   verify_signing.sh gradle <build.gradle.kts>    校验 release 不复用 debug 签名，且「缺材料 → 未签名」策略显式在场
#
# 退出码:
#   0 PASS | 1 用法/IO 错误 | 2 证书未知或不匹配 | 3 缺少只读工具 | 4 两个 APK 签名不同
#   5 缺签名材料/口令（BLOCKED） | 6 旧 Flutter 证书（不可覆盖安装） | 7 release 使用 debug 签名
#   8 静态断言不成立（FAIL_CLOSED_VERIFY_GAP）或 versionCode 非单调 | 9 applicationId 不是 rhine.music.database
set -eu

EXPECTED_QT_CERT_SHA256='39396cd06f2b7980302bad220ed071e09286540be4d224a2f9b047ca65205bdf'
OLD_FLUTTER_CERT_SHA256='7c514fe8cf95411117b6a4d1cba78768c1cda1d665c42f4828398d8587239dd4'
EXPECTED_PACKAGE='rhine.music.database'
QT_APK_VERSIONCODE_REF=1

# gradle 模式静态断言用的 POSIX ERE（只面向 android/app/build.gradle.kts 的 Kotlin DSL 文本）。
# 负向：只认赋值形式，不认注释或字符串里的字面量，避免假阳性/假阴性。
RE_DEBUG_SIGNING_CONFIG='signingConfig[[:space:]]*=[[:space:]]*signingConfigs\.(getByName\([[:space:]]*"debug"[[:space:]]*\)|debug)'
# 正向：release 签名配置、指向 release 的赋值、以及「缺材料时允许未签名」的显式策略必须同时在场。
RE_CREATE_RELEASE='create\([[:space:]]*"release"[[:space:]]*\)'
RE_GETBYNAME_RELEASE='getByName\([[:space:]]*"release"[[:space:]]*\)'
RE_RELEASE_SIGNING_CONFIG='signingConfig[[:space:]]*=[[:space:]]*signingConfigs\.getByName\([[:space:]]*"release"[[:space:]]*\)'
RE_UNSIGNED_ALLOWED='release 未配置签名，将产出未签名 APK'

log() { printf '%s\n' "$*"; }
die() { code=$1; shift; log "ERROR[$code] $*"; exit "$code"; }

usage() {
    cat <<'USAGE'
usage: verify_signing.sh <mode> ...
  apk <apk>                     APK SHA256 + 证书指纹 + 包名 + versionCode，并比对 Qt 证书
  keystore <keystore>           只读列出 keystore 别名与证书指纹（口令从 RHINE_KEYSTORE_PASSWORD 读）
  session <old.apk> <new.apk>   同签名 + versionCode 单调递增（覆盖安装前提）
  gradle <build.gradle.kts>     release 不得复用 debug signingConfig；未签名策略缺失即非零退出
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

# 剥掉 Kotlin DSL 的块注释（/* */，Kotlin 允许嵌套）与行注释（//）；字符串字面量内的符号原样保留。
# 逐行输出（整行注释变成空行），因此 grep -n 的行号与原文件一一对应。
# 只服务 android/app/build.gradle.kts 的静态断言：不调用 Gradle，不做编译期判断。
strip_kotlin_comments() {
    awk '
        BEGIN { depth = 0; mode = 0 }
        {
            line = $0
            out = ""
            i = 1
            n = length(line)
            while (i <= n) {
                if (depth > 0) {
                    if (substr(line, i, 2) == "*/") { depth -= 1; i += 2 }
                    else if (substr(line, i, 2) == "/*") { depth += 1; i += 2 }
                    else { i += 1 }
                    continue
                }
                if (mode == 3) {
                    if (substr(line, i, 3) == "\"\"\"") { mode = 0; i += 3 }
                    else { out = out substr(line, i, 1); i += 1 }
                    continue
                }
                if (mode != 0) {
                    ch = substr(line, i, 1)
                    out = out ch
                    if (ch == "\\") { out = out substr(line, i + 1, 1); i += 2; continue }
                    if (mode == 1 && ch == "\"") { mode = 0 }
                    if (mode == 2 && ch == "\047") { mode = 0 }
                    i += 1
                    continue
                }
                if (substr(line, i, 3) == "\"\"\"") { mode = 3; out = out substr(line, i, 3); i += 3; continue }
                ch = substr(line, i, 1)
                if (ch == "\"") { mode = 1; out = out ch; i += 1; continue }
                if (ch == "\047") { mode = 2; out = out ch; i += 1; continue }
                if (substr(line, i, 2) == "//") { break }
                if (substr(line, i, 2) == "/*") { depth = 1; i += 2; continue }
                out = out ch
                i += 1
            }
            if (mode == 1 || mode == 2) { mode = 0 }
            print out
        }
        END { if (depth > 0 || mode == 3) exit 3 }
    ' "$1"
}

mode_gradle() {
    f=$1
    [ -f "$f" ] || die 1 "文件不存在: $f"
    need_tool awk
    stripped=$(strip_kotlin_comments "$f") || {
        log "RELEASE_SIGNING=FAIL_CLOSED_VERIFY_GAP"
        die 8 "无法剥离 Kotlin DSL 注释（块注释或三引号原串未闭合？）: $f"
    }
    if [ -z "$stripped" ]; then
        log "RELEASE_SIGNING=FAIL_CLOSED_VERIFY_GAP"
        die 8 "剥离注释后无可判定内容: $f"
    fi

    # 负向断言：release 构建类型不得把 signingConfig 赋成 debug 配置（注释已剥离，不会误判注释里的字面量）。
    if hits=$(printf '%s\n' "$stripped" | grep -nE "$RE_DEBUG_SIGNING_CONFIG"); then
        log "RELEASE_SIGNING=DEBUG_KEY_BLOCKED"
        printf '%s\n' "$hits" | sed -n 's/^/  /p'
        die 7 "release 构建类型仍用 debug 签名：该 APK 无法覆盖 Qt 安装，发布门未满足"
    fi

    # 负向补充：同一赋值被换行拆开（signingConfig = 换行 signingConfigs.debug）时逐行匹配会漏判。
    joined=$(printf '%s\n' "$stripped" | tr '\n' ' ')
    if printf '%s\n' "$joined" | grep -qE "$RE_DEBUG_SIGNING_CONFIG"; then
        log "RELEASE_SIGNING=DEBUG_KEY_BLOCKED"
        log "  命中跨行 signingConfig 赋值：$f（无单一物理行可定位）"
        die 7 "release 构建类型仍用 debug 签名：该 APK 无法覆盖 Qt 安装，发布门未满足"
    fi

    # 正向断言：四项缺一即视为静态判定力缺失。
    missing=
    printf '%s\n' "$stripped" | grep -qE "$RE_CREATE_RELEASE" || missing="$missing create-release-config"
    printf '%s\n' "$stripped" | grep -qE "$RE_GETBYNAME_RELEASE" || missing="$missing getByName-release"
    printf '%s\n' "$stripped" | grep -qE "$RE_RELEASE_SIGNING_CONFIG" || missing="$missing release-signingConfig-assignment"
    printf '%s\n' "$stripped" | grep -qE "$RE_UNSIGNED_ALLOWED" || missing="$missing unsigned-release-policy"
    if [ -n "$missing" ]; then
        log "RELEASE_SIGNING=SIGNING_POLICY_VERIFY_GAP"
        log "缺少签名策略静态断言:$missing"
        die 8 "release 签名策略断言不成立：静态判定力缺失即视为不放行"
    fi

    log "RELEASE_SIGNING=NOT_DEBUG_CONFIGURED（仍需核对实际证书指纹，见 apk/keystore 模式）"
    return 0
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
