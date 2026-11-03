const fs = require('node:fs');
const path = require('node:path');

// Node 18 的移动端运行时（iOS 的 NodeMobile.framework、Android 的 libnode.so）缺两样桌面
// Node 22 自带的东西：
//   1. 全局 fetch —— 由 webApis 文件补上。两个平台的补丁不同：iOS 把 TLS 校验交回系统，
//      Android 用 Node 自带的根证书，所以这里由调用方指定注入哪一份。
//   2. node:buffer 的 isUtf8 —— 上游用 TextDecoder 自己实现了一遍，这里换成原生实现，
//      因为移动端的 TextDecoder 在 fatal 模式下的行为与上游假设不一致。
//
// 参数是注入到 worker.cjs 头部的 web API 补丁文件名。
module.exports = (webApis = 'ios-web-apis.cjs') => ({
    name: 'mobile-web-apis',
    setup(build) {
        build.onLoad({ filter: /\/MusicBridge\/worker\.cjs$/ }, (args) => ({
            contents:
                `require(${JSON.stringify(path.join(path.dirname(args.path), webApis))});\n` +
                fs.readFileSync(args.path, 'utf8'),
            loader: 'js',
        }));
        build.onLoad({ filter: /@neteasecloudmusicapienhanced\/api\/util\/crypto\.js$/ }, (args) => {
            const contents = fs.readFileSync(args.path, 'utf8');
            const decoder =
                /const decoder = new TextDecoder\('utf-8', \{ fatal: true \}\)\n\nconst isUtf8 = \(buf\) => \{\n  try \{\n    decoder.decode\(buf\)\n    return true\n  \} catch \{\n    return false\n  \}\n\}/g;
            const matches = [...contents.matchAll(decoder)];
            if (matches.length !== 1 || contents.match(/decoder\./g)?.length !== 1) {
                throw new Error(
                    'Upstream UTF-8 validator changed; review mobile runtime compatibility before building',
                );
            }
            return {
                contents: contents.replace(decoder, "const { isUtf8 } = require('node:buffer')"),
                loader: 'js',
            };
        });
    },
});
