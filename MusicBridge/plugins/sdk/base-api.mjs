import { safeLoginDetails } from './failure.mjs';

/**
 * 插件共用的 Host 请求适配。
 *
 * P1 先复用现有 callback 风格 Host API：request(route, params, callback)
 * 返回 JSON 字符串 {body, cookies, _epoch, _credentialKey}。
 * P3 的 credential v2 会替换这一层的凭据切片。
 */
export class BaseAPI {
    constructor(host, provider, label = provider) {
        this.host = host;
        this.provider = provider;
        this.label = label;
    }

    delay(milliseconds) {
        return new Promise((resolve) => this.host.delay(milliseconds, resolve));
    }

    request(route, values = {}, allow = [200], valid = () => true) {
        return new Promise((resolve, reject) =>
            this.host.request(route, values, (raw, error) => {
                if (error) {
                    reject(new Error(error));
                    return;
                }
                if (!valid()) {
                    reject(new Error('Stale operation'));
                    return;
                }
                let response;
                try {
                    response = JSON.parse(raw);
                } catch {
                    reject(new Error('元数据格式无效'));
                    return;
                }
                const body = response.body;
                if (!body || typeof body !== 'object') {
                    reject(new Error('元数据格式无效'));
                    return;
                }
                if (body.code !== undefined && !allow.includes(body.code)) {
                    const failure = new Error(
                        this.label + '返回 ' + body.code + '：' + (body.message ?? body.msg ?? '请稍后重试'),
                    );
                    failure.code = body.code;
                    Object.assign(failure, safeLoginDetails(body));
                    reject(failure);
                    return;
                }
                this.host.acceptCookies(
                    JSON.stringify(response.cookies || []),
                    response._epoch,
                    response._credentialKey || '',
                );
                resolve(body);
            }),
        );
    }
}
