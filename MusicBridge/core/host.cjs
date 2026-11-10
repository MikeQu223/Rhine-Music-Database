'use strict';

/**
 * 通用插件 Host：把 worker 的 callback 风格 request 适配成插件 API。
 * 不包含平台语义；cookie/secretState 按请求透传。
 */
function createHost(message, request, recordDiagnostic) {
    const cookies = { ...(message.cookies || {}) };
    const env = { ...(message.env || {}) };
    const receivedCookies = [];
    const secretState = {};

    function acceptCookies(values) {
        let lines;
        try {
            lines = JSON.parse(values || '[]');
        } catch {
            lines = [];
        }
        for (const line of lines) {
            receivedCookies.push(line);
            const match = String(line).match(/^\s*([^=;]+)=([^;]*)/);
            if (match) {
                cookies[match[1]] = match[2];
            }
        }
    }

    return {
        cookies: () => ({ ...cookies }),
        delay: (milliseconds, callback) => setTimeout(callback, milliseconds),
        authenticated: () => message.authenticated !== false,
        env: () => ({ ...env }),
        acceptCookies,
        request(route, params, callback) {
            Promise.resolve(request({ ...message, route, params, cookies: { ...cookies } })).then(
                (response) => {
                    for (const line of response.cookies || []) {
                        acceptCookies(JSON.stringify([line]));
                    }
                    const { body, cookies: ignored, _epoch, _credentialKey, ...rest } = response;
                    Object.assign(secretState, rest);
                    callback(
                        JSON.stringify({
                            body,
                            cookies: response.cookies || [],
                            _epoch: 0,
                            ...rest,
                        }),
                        '',
                    );
                },
                (error) => callback('', error.message || '音乐接口请求失败'),
            );
        },
        receivedCookies: () => receivedCookies,
        secretState: () => secretState,
        diagnostics: {
            record: (fields) => recordDiagnostic?.(fields),
        },
    };
}

module.exports = { createHost };
