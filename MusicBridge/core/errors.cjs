'use strict';

// 插件边界的结构化错误；errorKey 只允许小写字母、点和短横线，可安全进入 Qt 诊断。
const ERROR_KEY = /^[a-z.-]{1,80}$/;

class PluginError extends Error {
    constructor(code, errorKey, message) {
        super(message);
        this.name = 'PluginError';
        this.code = code;
        this.errorKey = errorKey;
    }
}

/** 只复制插件 Error 上可直接展示的诊断字段，避免认证记录或原始响应外泄。 */
function safeDetails(source) {
    const result = {};
    if (!source || typeof source !== 'object') {
        return result;
    }
    for (const key of ['failureStage', 'failureReason', 'errorKey', 'upstreamErrorKey']) {
        if (typeof source[key] === 'string' && ERROR_KEY.test(source[key])) {
            result[key] = source[key];
        }
    }
    for (const key of [
        'retryAfterMs',
        'upstreamHttpStatus',
        'upstreamCode',
        'upstreamGlobalCode',
        'upstreamSubCode',
    ]) {
        if (typeof source[key] === 'number' && Number.isFinite(source[key])) {
            result[key] = source[key];
        }
    }
    for (const key of ['authExpired', 'retryable', 'writeAttempted']) {
        if (typeof source[key] === 'boolean') {
            result[key] = source[key];
        }
    }
    if (source.verification === 'unconfirmed') {
        result.verification = 'unconfirmed';
    }
    for (const key of ['lastFailure', 'primaryFailure']) {
        if (source[key] && typeof source[key] === 'object') {
            const nested = safeDetails(source[key]);
            if (Object.keys(nested).length) {
                result[key] = nested;
            }
        }
    }
    return result;
}

function errorBody(error, fallbackMessage = '插件请求失败') {
    const failure = error?.body && typeof error.body === 'object' ? error.body : {};
    let code = 503;
    if (typeof failure.code === 'number') {
        code = failure.code;
    } else if (typeof error?.code === 'number') {
        code = error.code;
    }
    const body = {
        ...failure,
        ...safeDetails(error),
        code,
        message: failure.message || error?.message || fallbackMessage,
    };
    if (typeof body.errorKey === 'string' && !ERROR_KEY.test(body.errorKey)) {
        delete body.errorKey;
    }
    return body;
}

function pluginMissing() {
    return errorBody(new PluginError(404, 'plugin.missing', '插件不可用'));
}

function routeUnknown() {
    return errorBody(new PluginError(404, 'route.unknown', '未知音乐路由'));
}

function routeInvalid() {
    return errorBody(new PluginError(400, 'route.invalid', '插件路由无效'));
}

function providerUnsupported(operation) {
    return errorBody(
        new PluginError(400, 'provider.unsupported', '插件不支持该接口：' + String(operation || '')),
    );
}

module.exports = {
    PluginError,
    errorBody,
    pluginMissing,
    providerUnsupported,
    routeInvalid,
    routeUnknown,
};
