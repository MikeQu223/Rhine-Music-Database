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
        code,
        message: failure.message || error?.message || fallbackMessage,
    };
    if (typeof error?.errorKey === 'string' && ERROR_KEY.test(error.errorKey)) {
        body.errorKey = error.errorKey;
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

module.exports = { PluginError, errorBody, pluginMissing, routeInvalid, routeUnknown };
