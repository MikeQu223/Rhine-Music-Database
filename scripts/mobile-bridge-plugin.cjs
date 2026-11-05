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
// 参数是注入到 worker.cjs 头部的 web API 补丁文件名。第二个参数是 request.js
// 末尾要追加的密钥缓存重置钩子：移动端由本插件接管 request.js（见下），
// bundle-bridge 的 netease-request-reset 插件在移动模式下会让位。
module.exports = (webApis = 'ios-web-apis.cjs', requestResetHook = '') => ({
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
        // request.js 还兼着 netease-request-reset 的职责：esbuild 对同一文件只跑第一个
        // 命中的 onLoad，本插件必须在这里补上同一段钩子，否则密钥刷新会退化成重新 require。
        build.onLoad(
            { filter: /@neteasecloudmusicapienhanced\/api\/(util\/(neapiKey|request)|app|generateConfig|main|server)\.js$/ },
            (args) => {
                let contents = fs.readFileSync(args.path, 'utf8').replace(tmpdirCall, tmpdirReplacement);
                if (/util[\\/]request\.js$/.test(args.path)) {
                    contents += requestResetHook;
                }
                return {
                    contents,
                    loader: 'js',
                };
            },
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
        // QQ 音乐 API 的桌面 explorer 会把会话标记写进 os.tmpdir()。当前 bundle 里
        // 这条分支没有任何调用点（AUTO_OPEN_EXPLORER 未开，getOpenCommand 也没有
        // android 分支），但上游一旦接上调用就会在真机写 /tmp 失败。esbuild 的
        // default 互操作形态是 node_os_1.default.tmpdir()，统一改写到 __rhineTmpdir；
        // 命中次数必须恰好 1，上游改字时让构建失败而不是静默退回 /tmp。
        build.onLoad(
            { filter: /@yakult-green-tea\/qq-music-api\/.*util[\\/]openExplorer\.js$/ },
            (args) => {
                const contents = fs.readFileSync(args.path, 'utf8');
                const tmpdirCall = /node_os_1\.default\.tmpdir\(\)/g;
                const matches = [...contents.matchAll(tmpdirCall)];
                if (matches.length !== 1) {
                    throw new Error(
                        'qq-music-api openExplorer changed; review the mobile tmpdir rewrite before building',
                    );
                }
                return {
                    contents: contents.replace(
                        tmpdirCall,
                        '(globalThis.__rhineTmpdir || node_os_1.default.tmpdir())',
                    ),
                    loader: 'js',
                };
            },
        );
    },
});
