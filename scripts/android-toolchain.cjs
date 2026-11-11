// 两个 Android 脚本（构建 kit、打包 APK）共用的工具链定位。
//
// 这里集中三条约定，避免两边各写一份后走偏：
//   1. SDK 优先取 ANDROID_SDK_ROOT / ANDROID_HOME，否则 ~/Android/Sdk；
//   2. NDK 必须在 SDK 的 ndk/ 目录下——AGP 是按版本号去那里找的，
//      指向 /opt 之类的外部路径会在 Gradle 阶段报 "NDK not configured"；
//   3. build-tools 取版本号最大的一套。
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function sdkRoot() {
    return process.env.ANDROID_SDK_ROOT || process.env.ANDROID_HOME || path.join(os.homedir(), 'Android/Sdk');
}

/** 返回 SDK 内可用的最高版本 NDK；一个都没有时退回 $ANDROID_NDK_ROOT（可能为空串）。 */
function ndkRoot(sdk) {
    if (process.env.RHINE_ANDROID_NDK) {
        return process.env.RHINE_ANDROID_NDK;
    }
    const base = path.join(sdk, 'ndk');
    const installed = fs.existsSync(base)
        ? fs.readdirSync(base).filter((name) => fs.existsSync(path.join(base, name, 'source.properties')))
        : [];
    if (installed.length > 0) {
        installed.sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
        return path.join(base, installed[installed.length - 1]);
    }
    return process.env.ANDROID_NDK_ROOT || '';
}

/** 版本号最大的一套 build-tools；目录名形如 36.0.0。 */
function buildToolsRoot(sdk) {
    const base = path.join(sdk, 'build-tools');
    if (!fs.existsSync(base)) {
        return '';
    }
    const versions = fs
        .readdirSync(base)
        .filter((name) => /^\d+\.\d+\.\d+$/.test(name))
        .sort((a, b) => Number(a.split('.')[0]) - Number(b.split('.')[0]) || a.localeCompare(b));
    return versions.length === 0 ? '' : path.join(base, versions[versions.length - 1]);
}

/**
 * Gradle 需要 JDK 17–21（AGP 不接受更高的运行时）。JAVA_HOME 优先；否则在工作区里找
 * 解压好的 jdk-* 目录——脚本会把 Temurin 解到 output/android-work/jdk/jdk-<版本>/。
 */
function jdkHome(workDirectory) {
    const candidates = [];
    if (process.env.JAVA_HOME) {
        candidates.push(process.env.JAVA_HOME);
    }
    const base = path.join(workDirectory, 'jdk');
    if (fs.existsSync(base)) {
        for (const name of fs.readdirSync(base)) {
            candidates.push(path.join(base, name));
        }
        candidates.push(base);
    }
    return (
        candidates.find((item) => fs.existsSync(path.join(item, 'bin', 'java'))) ||
        path.join(workDirectory, 'jdk')
    );
}

module.exports = { sdkRoot, ndkRoot, buildToolsRoot, jdkHome };
