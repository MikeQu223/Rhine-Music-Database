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

// 移动端 libnode 未编译完整 ICU：TextDecoder 的 fatal 选项会直接抛 ERR_NO_ICU，
// 而插件常拿它校验 UTF-8（网易云插件的上游 crypto 工具在加载阶段就构造）。
// 用 node:buffer 自带的 UTF-8 校验补回 fatal 语义；流式解码不检查跨块字节。
(function () {
    if (typeof TextDecoder !== "function") {
        return;
    }
    try {
        new TextDecoder("utf-8", { fatal: true });
        return;
    } catch {
        // 运行时没有 ICU，继续安装兼容实现。
    }
    const { isUtf8 } = require("node:buffer");
    const NativeTextDecoder = TextDecoder;
    const UTF8_LABEL = /^(?:utf-?8|unicode-1-1-utf-8)$/i;
    class FatalTextDecoder extends NativeTextDecoder {
        constructor(label, options) {
            const { fatal, ...rest } = options || {};
            super(label === undefined ? "utf-8" : label, rest);
            this.rhineFatalUtf8 = fatal === true && UTF8_LABEL.test(String(label || "utf-8"));
        }
        decode(input, options) {
            if (this.rhineFatalUtf8 && input && !options?.stream) {
                let bytes;
                if (input instanceof ArrayBuffer) {
                    bytes = new Uint8Array(input);
                } else if (ArrayBuffer.isView(input)) {
                    bytes = new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
                }
                if (bytes && !isUtf8(bytes)) {
                    throw new TypeError("The encoded data was not valid for encoding utf-8");
                }
            }
            return super.decode(input, options);
        }
    }
    Object.defineProperty(globalThis, "TextDecoder", {
        value: FatalTextDecoder,
        writable: true,
        configurable: true,
    });
})();

// nodejs-mobile 的 Worker env 选项不可靠（Android 真机实测：宿主传入的 TMPDIR 没进
// worker 的环境变量，os.tmpdir() 退回 /tmp，worker 在写 anonymous_token 时 EACCES 崩溃，
// 「音乐服务已退出」就是它）。运行时经 workerData 直传宿主环境作兜底：这段代码位于
// bundle 最顶部，先于 worker 主体与上游库的顶层求值，后续所有 os.tmpdir() 都能读对。
// 桌面以独立子进程运行 worker.cjs 且不打这个补丁；iOS 的 workerData 里没有 TMPDIR 时无操作。
try {
    const { workerData } = require("node:worker_threads");
    if (workerData && typeof workerData === "object") {
        for (const [name, value] of Object.entries(workerData)) {
            if (typeof value === "string" && value) {
                process.env[name] = value;
            }
        }
    }
} catch {
    // worker_threads 不可用的环境：保持现状，交给 env 选项或继承环境。
}

// nodejs-mobile 的 Worker 把 env 选项与 workerData 全都丢弃（Android 真机实测），且
// 更彻底的一点：worker 里 process.env 的 JS 层写入对 os.tmpdir() 也不可见（它读 C 层
// 环境），所以「写 env 修临时目录」整条路都走不通。这里探测出真正可写的目录后挂到
// globalThis.__rhineTmpdir，由打包插件把 bundle 里所有 os.tmpdir() 调用点改写成它。
// 三层来源按序尝试：workerData → 脚本旁的 host-env.json（运行时写入，env 通道的替代）
// → 脚本旁的 tmp/ 兜底。桌面 /tmp 可写，探测通过，行为不变。锚点取 require.main.filename
// （运行时 worker 脚本路径）；esbuild 会把 __dirname 重写成构建机路径，不能用。
(function () {
    const fs = require("node:fs");
    const os = require("node:os");
    const path = require("node:path");
    let anchor = "";
    try {
        anchor = (require.main && require.main.filename) || process.argv[1] || "";
    } catch {
    }
    // 通道一：workerData 直传（部分 nodejs-mobile 版本支持）。
    try {
        const { workerData } = require("node:worker_threads");
        if (workerData && typeof workerData === "object") {
            for (const [name, value] of Object.entries(workerData)) {
                if (typeof value === "string" && value) {
                    process.env[name] = value;
                }
            }
        }
    } catch {
    }
    // 通道二：运行时把宿主环境写在 worker 脚本旁的 host-env.json（iOS 脚本目录只读，
    // 运行时写不进去，这里静默跳过）。
    if (anchor) {
        try {
            const declared = JSON.parse(
                fs.readFileSync(path.join(path.dirname(anchor), "host-env.json"), "utf8"),
            );
            for (const [name, value] of Object.entries(declared)) {
                if (typeof value === "string" && value) {
                    process.env[name] = value;
                }
            }
        } catch {
        }
    }
    // 候选目录按优先级探测：先信 env 通道写进 process.env 的 TMPDIR（host-env.json 把
    // 它指到系统分配的缓存目录）——直接读 JS 对象，不经 os.tmpdir()（后者只认 C 层
    // 环境，见顶部说明）；再退 os.tmpdir()；都不行才落 worker 脚本旁的 tmp/ 兜底。
    const candidates = [];
    try {
        if (typeof process.env.TMPDIR === "string" && process.env.TMPDIR) {
            candidates.push(process.env.TMPDIR);
        }
    } catch {
    }
    try {
        candidates.push(os.tmpdir());
    } catch {
    }
    let resolved = "";
    for (const candidate of candidates) {
        try {
            const probe = path.join(candidate, ".rhine-tmp-probe");
            fs.writeFileSync(probe, "ok");
            fs.unlinkSync(probe);
            resolved = candidate;
            break;
        } catch {
        }
    }
    if (!resolved && anchor) {
        const fallback = path.join(path.dirname(path.dirname(anchor)), "tmp");
        try {
            fs.mkdirSync(fallback, { recursive: true });
            const inner = path.join(fallback, ".rhine-tmp-probe");
            fs.writeFileSync(inner, "ok");
            fs.unlinkSync(inner);
            resolved = fallback;
            for (const name of ["TMPDIR", "TMP", "TEMP"]) {
                process.env[name] = fallback;
            }
            // 此刻 console 尚未被 worker 主体静默，这行经 stderr 进宿主日志。
            console.error("[rhine] tmpdir fallback ->", fallback);
        } catch {
        }
    }
    Object.defineProperty(globalThis, "__rhineTmpdir", {
        value: resolved,
        writable: false,
        configurable: false,
    });
})();
