import { API } from '../../../MusicBridge/local-plugins/netease/netease.mjs';

/**
 * 为平台客户端测试提供本地假 Host。
 *
 * 每个响应按完整路由登记；未登记的路由直接报错，避免测试悄悄拿到空数据。
 * 响应可以是对象，也可以是 (参数) => 对象 的函数；返回 { body, cookies } 时额外交付 Cookie。
 */
export function createFakeHost({ responses = {}, authenticated = () => true, preference = () => '' } = {}) {
    const calls = [];
    const routes = new Map(Object.entries(responses));
    const host = {
        preference,
        setPreference() {},
        fromLink: () => '',
        cover() {},
        setProvider() {},
        authenticated,
        acceptCookies() {},
        hasCredential: () => true,
        saveCredential: () => '',
        mediaControl() {},
        mediaState: () => ({}),
        mediaLoad: () => true,
        qrImage: () => 'fixture-qr',
        delay(milliseconds, done) {
            done();
        },
        request(route, params, done) {
            calls.push({ route, params });
            const handler = routes.get(route);
            if (!handler) {
                done('', '未设置的本地响应：' + route);
                return;
            }
            try {
                const value = typeof handler === 'function' ? handler(params) : handler;
                const response =
                    value && typeof value === 'object' && 'body' in value ? value : { body: value };
                done(JSON.stringify({ cookies: [], ...response }), '');
            } catch (error) {
                done('', error?.message || String(error));
            }
        },
    };
    return {
        host,
        calls,
        respond(route, handler) {
            routes.set(route, handler);
        },
        callsTo(route) {
            return calls.filter((call) => call.route === route);
        },
        lastCall(route) {
            return calls.filter((call) => call.route === route).at(-1);
        },
        resetCalls() {
            calls.length = 0;
        },
    };
}

/**
 * 用真实 API 基类包裹假 Host。
 *
 * 平台客户端必须经过与生产相同的响应校验和 Cookie 交付顺序，不能只依赖鸭子类型。
 */
export function createClientHarness(options = {}) {
    const fake = createFakeHost(options);
    return { ...fake, api: new API(fake.host) };
}
