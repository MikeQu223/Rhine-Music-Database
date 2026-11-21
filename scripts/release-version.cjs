const { execFileSync } = require('node:child_process');
const path = require('node:path');

// 发布标识
const distributionPlatforms = [
    'macOS-arm64.zip',
    'Windows-x64-Setup.exe',
    'Linux-x86_64.AppImage',
    'ios-unsigned.ipa',
];

/** 发布 tag 在编译前确定；普通构建明确标记为开发版，避免缓存上次的发布身份。 */
function buildVersion(value = process.env.RHINE_VERSION) {
    if (!value) {
        let commitSha = 'unknown';
        try {
            commitSha = execFileSync('git', ['rev-parse', '--short=12', 'HEAD'], {
                cwd: path.resolve(__dirname, '..'),
                encoding: 'utf8',
                stdio: ['ignore', 'pipe', 'ignore'],
            }).trim();
        } catch {
            // 源码归档可能没有 Git 元数据；明确标记未知提交，不冒用正式版本。
        }
        return { version: '0.0.0', release: false, commitSha };
    }
    if (!/^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(value)) {
        throw new Error('Release version must use vMAJOR.MINOR.PATCH, e.g. v1.0.0');
    }
    const version = value.replace(/^v/, '');
    if (version.split('.').some((segment) => Number(segment) > 65535)) {
        throw new Error('Release version components must be at most 65535 for Windows VERSIONINFO');
    }
    return { version, release: true };
}
function packageIdentity(version = buildVersion()) {
    return version.release ? `v${version.version}` : version.commitSha;
}

/** 正式版本默认进入 production，开发版和源码归档默认进入 development。 */
function sentryEnvironment(version = buildVersion(), explicit = process.env.RHINE_SENTRY_ENVIRONMENT) {
    const override = (explicit || '').trim();
    return override || (version.release ? 'production' : 'development');
}

module.exports = { buildVersion, packageIdentity, sentryEnvironment, distributionPlatforms };
