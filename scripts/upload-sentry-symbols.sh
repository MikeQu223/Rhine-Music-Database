#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
    echo 'Sentry symbol upload skipped because SENTRY_AUTH_TOKEN is not set.'
    exit 0
fi
: "${SENTRY_ORG:?Set SENTRY_ORG for the project receiving crash events}"
: "${SENTRY_PROJECT:?Set SENTRY_PROJECT for the project receiving crash events}"
if [[ -z "${SENTRY_URL:-}" ]]; then
    unset SENTRY_URL
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
build=output/qt-build
cli_version=3.8.2
case "${RUNNER_OS}:${1:-}" in
    Windows:)
        asset=sentry-cli-Windows-x86_64.exe
        checksum=50009f23c49d6e9ff7624204c7035855303b49c5e326708ee783c1fdf783ac83
        check_sha256=(sha256sum -c)
        binaries=("$build/RhineMusicDatabase.exe" "$build/RhinePlaybackService.exe")
        debug_files=("$build/RhineMusicDatabase.pdb" "$build/RhinePlaybackService.pdb")
        ;;
    macOS:)
        bundle="$build/RhineMusicDatabase.app/Contents"
        application="$bundle/MacOS/RhineMusicDatabase"
        service="$bundle/Helpers/RhinePlaybackService.app/Contents/MacOS/RhinePlaybackService"
        # 主程序的 dSYM 由既有 Crashpad 打包步骤生成，独立播放服务使用同一次构建的二进制。
        dsymutil "$service" -o "$scratch/RhinePlaybackService.dSYM"
        binaries=("$application" "$service")
        debug_files=(
            "output/crash-symbol-archives/RhineMusicDatabase.dSYM/Contents/Resources/DWARF/RhineMusicDatabase"
            "$scratch/RhinePlaybackService.dSYM/Contents/Resources/DWARF/RhinePlaybackService"
        )
        ;;
    macOS:--ios)
        build=output/ios-device-build
        bundle="$build/Release/RhineMusicDatabase.app"
        binaries=("$bundle/RhineMusicDatabase")
        debug_files=("$bundle.dSYM/Contents/Resources/DWARF/RhineMusicDatabase")
        # XCFramework 内含同一官方发行包的符号，按设备 slice 上传。
        if [[ -f "$bundle/Frameworks/SentryObjC.framework/SentryObjC" ]]; then
            binaries+=("$bundle/Frameworks/SentryObjC.framework/SentryObjC")
            debug_files+=("$(cat "$build/sentry-config/ios-framework-debug-file.txt")")
        fi
        ;;
    *)
        echo "Sentry symbol upload is not configured for $RUNNER_OS ${1:-}." >&2
        exit 1
        ;;
esac
if [[ "$RUNNER_OS" == macOS ]]; then
    asset=sentry-cli-Darwin-arm64
    checksum=c80d92b6d34eb64fe7402f56cc7968fbb15aab1c763254ad428b55cc98ec7dcf
    check_sha256=(shasum -a 256 -c)
fi

cli="$scratch/$asset"
curl -fsSL --retry 3 "https://github.com/getsentry/sentry-cli/releases/download/$cli_version/$asset" -o "$cli"
echo "$checksum  $cli" | "${check_sha256[@]}"
chmod +x "$cli"

# 检查可用性，校验同次构建的调试 ID，再提交符号及可执行文件中的栈展开信息。
export SENTRY_DISABLE_UPDATE_CHECK=true
export SENTRY_LOAD_DOTENV=0
for index in "${!binaries[@]}"; do
    binary="${binaries[index]}"
    debug="${debug_files[index]}"
    binary_ids=$("$cli" debug-files check --json "$binary" | jq -cer '[.variants[].debug_id] | select(length > 0) | sort')
    debug_ids=$("$cli" debug-files check --json "$debug" | jq -cer '[.variants[].debug_id] | select(length > 0) | sort')
    if [[ "$binary_ids" != "$debug_ids" ]]; then
        echo "Sentry debug IDs do not match for $binary." >&2
        exit 1
    fi
done
"$cli" debug-files upload --wait "${binaries[@]}" "${debug_files[@]}"
