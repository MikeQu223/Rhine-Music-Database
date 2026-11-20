'use strict';

const schema = require('./manifest.schema.json');
const contract = require('./contract-lock.json');
const { isRecord, schemaProblem } = require('./manifest-validation.cjs');

const HOST_API_VERSION = contract.apiVersion;
const LEGACY_API_VERSION = '2.0.0';
const SUPPORTED_PLATFORMS = ['windows', 'macos', 'linux', 'ios', 'android'];
const SEMVER =
    /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/;
const SHORT_SDK_VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const NUMERIC = /^\d+$/;
const PROVIDER_ID = /^[a-z0-9-]{1,40}$/;
const DEVICE_NAME = /^(con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)/i;

const HOST_FEATURES = Object.freeze({
    interfaces: Object.freeze([
        'cookies',
        'acceptCookies',
        'receivedCookies',
        'secretState',
        'delay',
        'authenticated',
        'env',
        'request',
        'diagnostics',
        'compatibility',
    ]),
    operations: Object.freeze([
        'search',
        'suggest',
        'resolveLink',
        'songs',
        'detail',
        'artistAlbums',
        'trackPage',
        'catalog',
        'playback',
        'preview',
        'lyrics',
        'account',
        'loginBegin',
        'loginPoll',
        'loginCancel',
        'loginSms',
        'loginSubmit',
        'logout',
        'vip',
        'userPlaylists',
        'likedIDs',
        'likedSongs',
        'likedAlbums',
        'likedState',
        'discover',
        'categories',
        'mutate',
        'comments',
        'commentReplies',
        'capabilities',
        'subscriptionStatus',
        'request',
        'mv',
        'mvVersions',
        'wiki',
    ]),
    capabilities: Object.freeze([
        'search',
        'suggest',
        'resolveLink',
        'detail',
        'playback',
        'preview',
        'lyrics',
        'comments',
        'account',
        'login',
        'vip',
        'discover',
        'categories',
        'userPlaylists',
        'likedSongs',
        'likedAlbums',
        'mv',
        'officialPlayback',
        'alternativeSource',
        'mutations',
        'playlistManagement',
    ]),
});

function parseVersion(value, sdkVersion = false) {
    if (typeof value !== 'string' || value.length > 120) {
        return null;
    }
    const text = sdkVersion && SHORT_SDK_VERSION.test(value) ? `${value}.0` : value;
    const match = SEMVER.exec(text);
    if (!match || match[0] !== text) {
        return null;
    }
    const prerelease = match[4]?.split('.') || [];
    if (prerelease.some((part) => NUMERIC.test(part) && part.length > 1 && part.startsWith('0'))) {
        return null;
    }
    return { core: match.slice(1, 4), prerelease };
}

function compareNumbers(left, right) {
    if (left.length !== right.length) {
        return left.length < right.length ? -1 : 1;
    }
    if (left === right) {
        return 0;
    }
    return left < right ? -1 : 1;
}

function compareParsed(left, right) {
    for (let index = 0; index < left.core.length; index++) {
        const comparison = compareNumbers(left.core[index], right.core[index]);
        if (comparison) {
            return comparison;
        }
    }
    if (!left.prerelease.length || !right.prerelease.length) {
        return Math.sign(Number(!left.prerelease.length) - Number(!right.prerelease.length));
    }
    for (let index = 0; index < Math.min(left.prerelease.length, right.prerelease.length); index++) {
        const leftPart = left.prerelease[index];
        const rightPart = right.prerelease[index];
        if (leftPart === rightPart) {
            continue;
        }
        const leftNumeric = NUMERIC.test(leftPart);
        const rightNumeric = NUMERIC.test(rightPart);
        if (leftNumeric && rightNumeric) {
            return compareNumbers(leftPart, rightPart);
        }
        if (leftNumeric !== rightNumeric) {
            return leftNumeric ? -1 : 1;
        }
        return leftPart < rightPart ? -1 : 1;
    }
    return Math.sign(left.prerelease.length - right.prerelease.length);
}

function compareVersions(left, right) {
    const leftVersion = parseVersion(left);
    const rightVersion = parseVersion(right);
    return leftVersion && rightVersion ? compareParsed(leftVersion, rightVersion) : null;
}

/** 支持完整比较符、空格交集和 || 并集；只有历史 SDK 声明允许 major.minor。 */
function parseRange(value, sdkVersion = false) {
    if (typeof value !== 'string' || !value.trim() || value.length > 120) {
        return null;
    }
    const sets = [];
    for (const part of value.split('||')) {
        const comparators = [];
        for (const token of part.trim().split(/\s+/)) {
            const match = /^(<=|>=|=|<|>)?(.*)$/.exec(token);
            const version = parseVersion(match?.[2], sdkVersion);
            if (!version) {
                return null;
            }
            comparators.push({ operation: match[1] || '=', version });
        }
        sets.push(comparators);
    }
    return sets;
}

const COMPARATORS = {
    '=': (comparison) => comparison === 0,
    '>': (comparison) => comparison > 0,
    '>=': (comparison) => comparison >= 0,
    '<': (comparison) => comparison < 0,
    '<=': (comparison) => comparison <= 0,
};

function satisfies(version, sets) {
    if (!version) {
        return false;
    }
    return sets.some((set) => {
        const matches = set.every((item) =>
            COMPARATORS[item.operation](compareParsed(version, item.version)),
        );
        const acceptsPrerelease = set.some(
            (item) =>
                item.version.prerelease.length &&
                item.version.core.every((part, index) => part === version.core[index]),
        );
        return matches && (!version.prerelease.length || acceptsPrerelease);
    });
}

function safeRelativePath(value) {
    if (typeof value !== 'string' || !value || value.length > 240 || /[\\:<>"|?*]/.test(value)) {
        return false;
    }
    if ([...value].some((character) => character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127)) {
        return false;
    }
    return value.split('/').every((part) => part && !/[. ]$/.test(part) && !DEVICE_NAME.test(part));
}

function result(code, message, legacy = false) {
    return { compatible: !code, legacy, code, message };
}

function invalid(message) {
    return result('manifest.invalid', message);
}

/** 检查可独立于宿主环境验证的声明，并识别经过验证的旧 API 2.0 基线。 */
function checkManifest(manifest, { legacy = true } = {}) {
    if (!isRecord(manifest)) {
        return invalid('插件 manifest 必须是对象');
    }
    if (manifest.schemaVersion !== contract.schemaVersion) {
        const actual = Number.isSafeInteger(manifest.schemaVersion) ? manifest.schemaVersion : '无有效声明';
        return result(
            'plugin.incompatible',
            `插件 manifest schema ${actual}，客户端要求 ${contract.schemaVersion}`,
        );
    }
    if (
        typeof manifest.id !== 'string' ||
        PROVIDER_ID.exec(manifest.id)?.[0] !== manifest.id ||
        ['local', 'siren'].includes(manifest.id) ||
        DEVICE_NAME.test(manifest.id)
    ) {
        return invalid('插件 ID 无效或保留');
    }
    if (!parseVersion(manifest.version)) {
        return invalid('插件版本必须是有效的 SemVer');
    }
    const api = parseVersion(manifest.apiVersion, true);
    if (!api) {
        return invalid('插件缺少有效的 SDK API 版本');
    }
    const isLegacyContract = legacy && compareParsed(api, parseVersion(LEGACY_API_VERSION)) === 0;
    const usesLegacyBaseline = isLegacyContract && manifest.requiresClient === undefined;
    if (manifest.kind === 'community' && isLegacyContract) {
        // API 2.0 已分发的旧标签等价于第三方，当前发布包须使用正式枚举值。
        manifest = { ...manifest, kind: 'third-party' };
    }
    if (usesLegacyBaseline && isRecord(manifest.display)) {
        // 旧客户端允许省略 label 和 detail，读取时分别回退到插件 ID 和空文本。
        manifest = { ...manifest, display: { label: manifest.id, detail: '', ...manifest.display } };
    }
    let problem;
    try {
        problem = schemaProblem(manifest, schema);
    } catch (error) {
        if (!(error instanceof RangeError)) {
            throw error;
        }
        return invalid('插件 manifest 含超出限制的嵌套结构');
    }
    if (problem) {
        return invalid(problem);
    }
    if (!safeRelativePath(manifest.entry.file) || !/\.(cjs|mjs|js)$/.test(manifest.entry.file)) {
        return invalid('插件入口须为包内的 JavaScript 文件');
    }
    if (!legacy && (!manifest.display?.name?.trim() || !manifest.capabilities)) {
        return invalid('插件 manifest 缺少显示名称或能力声明');
    }
    const listedPaths = [
        manifest.display?.icon,
        manifest.sbom,
        ...(manifest.files || []).map((file) => file.path),
    ];
    if (listedPaths.some((file) => file !== undefined && !safeRelativePath(file))) {
        return invalid('插件 manifest 含无效的包内文件路径');
    }
    if (manifest.requiresHost !== undefined && !parseRange(manifest.requiresHost, true)) {
        return invalid('requiresHost 必须是有效的 SDK API 版本范围');
    }
    if (manifest.requiresClient === undefined && !usesLegacyBaseline) {
        return result(
            'plugin.incompatible',
            '插件缺少 requiresClient 客户端版本范围，请安装发布者提供的新版插件',
        );
    }
    if (manifest.requiresClient !== undefined && !parseRange(manifest.requiresClient)) {
        return invalid('requiresClient 必须是有效的客户端 SemVer 范围');
    }
    if (manifest.runtime?.requiresVersion !== undefined && !parseRange(manifest.runtime.requiresVersion)) {
        return invalid('runtime.requiresVersion 必须是有效的 Node 版本范围');
    }
    return result('', '', usesLegacyBaseline);
}

function currentPlatform() {
    return { win32: 'windows', darwin: 'macos' }[process.platform] || process.platform;
}

function createHostContext({
    clientVersion,
    platform = currentPlatform(),
    runtimeVersion = process.versions.node,
    hosting = 'module',
    apiVersion = HOST_API_VERSION,
} = {}) {
    const mobile = platform === 'ios' || platform === 'android';
    // 与客户端的平台能力开关一致。移动端不提供官方客户端交付和 MV 界面。
    const features = mobile
        ? Object.freeze({
              ...HOST_FEATURES,
              capabilities: Object.freeze(
                  HOST_FEATURES.capabilities.filter((name) => name !== 'officialPlayback' && name !== 'mv'),
              ),
          })
        : HOST_FEATURES;
    return Object.freeze({
        clientVersion: parseVersion(clientVersion) ? clientVersion : null,
        apiVersion,
        platform: SUPPORTED_PLATFORMS.includes(platform) ? platform : 'unknown',
        runtime: Object.freeze({ name: 'node', version: runtimeVersion, hosting }),
        features,
    });
}

/** 安装、发现和初始化统一使用宿主提供的身份，静态校验期间只读取数据。 */
function checkCompatibility(manifest, host, options) {
    const checked = checkManifest(manifest, options);
    if (!checked.compatible) {
        return checked;
    }
    const requiredApi = parseVersion(manifest.apiVersion, true);
    const hostApi = parseVersion(host.apiVersion, true);
    const minimumApi = parseVersion(LEGACY_API_VERSION);
    if (
        !hostApi ||
        requiredApi.core[0] !== hostApi.core[0] ||
        compareParsed(requiredApi, minimumApi) < 0 ||
        compareParsed(requiredApi, hostApi) > 0
    ) {
        return result(
            'plugin.incompatible',
            `插件 SDK API ${manifest.apiVersion}；宿主支持 ${LEGACY_API_VERSION} 至 ${host.apiVersion ?? '未知'}`,
        );
    }
    if (manifest.requiresHost && !satisfies(hostApi, parseRange(manifest.requiresHost, true))) {
        return result(
            'plugin.incompatible',
            `宿主 SDK API ${host.apiVersion}；插件要求 ${manifest.requiresHost}`,
        );
    }
    if (
        manifest.requiresClient &&
        !satisfies(parseVersion(host.clientVersion), parseRange(manifest.requiresClient))
    ) {
        return result(
            'plugin.incompatible',
            `客户端版本 ${host.clientVersion ?? '未知'}；插件要求 ${manifest.requiresClient}，请安装兼容的客户端或插件版本`,
        );
    }
    const runtime = manifest.runtime || {};
    if (runtime.platforms && !runtime.platforms.includes(host.platform)) {
        return result(
            'plugin.platform',
            `当前平台 ${host.platform}；插件支持 ${runtime.platforms.join('、')}`,
        );
    }
    if (runtime.hosting && !runtime.hosting.includes(host.runtime.hosting)) {
        return result(
            'plugin.runtime',
            `当前宿主模式 ${host.runtime.hosting}；插件要求 ${runtime.hosting.join('、')}`,
        );
    }
    if (
        runtime.requiresVersion &&
        !satisfies(parseVersion(host.runtime.version), parseRange(runtime.requiresVersion))
    ) {
        return result(
            'plugin.runtime',
            `当前 Node 版本 ${host.runtime.version}；插件要求 ${runtime.requiresVersion}`,
        );
    }
    for (const [kind, supported] of Object.entries(host.features)) {
        const missing = (manifest.requiresHostFeatures?.[kind] || []).filter(
            (feature) => !supported.includes(feature),
        );
        if (missing.length) {
            return result(
                'plugin.features',
                `客户端 ${host.clientVersion ?? '未知'}（SDK ${host.apiVersion}）缺少插件要求的 ${kind}：${missing.join('、')}`,
            );
        }
    }
    return checked;
}

module.exports = { checkCompatibility, checkManifest, compareVersions, createHostContext, safeRelativePath };
