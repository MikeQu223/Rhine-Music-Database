// Android 的 Node 18 运行时同样没有全局 fetch / Web Crypto，需要和 iOS 一样补上。
//
// 与 ios-web-apis.cjs 的唯一差别：不装 ios-system-trust.cjs。
// 那份补丁把 TLS 校验交给 Apple 的 Security.framework，走的是 Qt 与 Node 之间的私有通道；
// Android 没有等价通道，装载它只会让每次握手都等一次永远不来的 system-trust-result。
// Android 侧改用 Node 自带的 Mozilla 根证书包（编译进 libnode.so），代价是用户
// 自己装进系统信任库的 CA 不会被采纳——这一点写在 docs/ANDROID.md 里。
const fetch = require('node-fetch');

// 保留 QQ 回环响应的多个 Set-Cookie
fetch.Headers.prototype.getSetCookie = function () {
    return [...(this.raw()['set-cookie'] || [])];
};
fetch.Response.json = function (body, init = {}) {
    const headers = new fetch.Headers(init.headers);
    if (!headers.has('content-type')) {
        headers.set('content-type', 'application/json');
    }
    return new fetch.Response(JSON.stringify(body), { ...init, headers });
};

for (const [name, value] of Object.entries({
    fetch,
    Headers: fetch.Headers,
    Request: fetch.Request,
    Response: fetch.Response,
    FormData: require('form-data'),
    // 为 QQ 音乐暴露 Web Crypto
    crypto: require('node:crypto').webcrypto,
})) {
    Object.defineProperty(globalThis, name, { value, writable: true, configurable: true });
}
