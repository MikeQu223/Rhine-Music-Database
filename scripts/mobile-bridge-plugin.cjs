const fs = require('node:fs');
const path = require('node:path');

// nodejs-mobile 的 worker 里 process.env 的 JS 层写入对 os.tmpdir() 不可见（它读 C 层
// 环境，而 env 选项/workerData 又被整个丢弃），所以「写 env 修临时目录」在真机上无效。
// web-apis 前奏会把探测确认可写的目录挂到 globalThis.__rhineTmpdir，这里把 bundle 内
// 所有 os.tmpdir() 调用点改写成它。改写保持 require 兜底：前奏万一没跑，行为退回现状。
const tmpdirCall = /require\((['"])(?:node:)?os\1\)\.tmpdir\(\)/g;
const tmpdirReplacement = '(globalThis.__rhineTmpdir || require("os").tmpdir())';

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
        build.onLoad({ filter: /\/MusicBridge\/worker\.cjs$/ }, (args) => {
            const contents = fs.readFileSync(args.path, 'utf8').replace(tmpdirCall, tmpdirReplacement);
            return {
                contents:
                    `require(${JSON.stringify(path.join(path.dirname(args.path), webApis))});\n` +
                    contents,
                loader: 'js',
            };
        });
        // 上游库把临时目录解析提升到模块顶层（anonymous_token、xeapi_public_key、neapi_key
        // 都落在那里），worker 主体还没跑就先崩；这些调用点必须一并改写。
        build.onLoad(
            { filter: /@neteasecloudmusicapienhanced\/api\/(util\/(neapiKey|request)|app|generateConfig|main|server)\.js$/ },
            (args) => ({
                contents: fs.readFileSync(args.path, 'utf8').replace(tmpdirCall, tmpdirReplacement),
                loader: 'js',
            }),
        );
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
