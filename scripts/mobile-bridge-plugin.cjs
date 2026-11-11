const fs = require('node:fs');
const path = require('node:path');

// nodejs-mobile 的 worker 里 process.env 的 JS 层写入对 os.tmpdir() 不可见（它读 C 层
// 环境，而 env 选项/workerData 又被整个丢弃），所以「写 env 修临时目录」在真机上无效。
// web-apis 前奏会把探测确认可写的目录挂到 globalThis.__rhineTmpdir，这里把 bundle 内
// 所有 os.tmpdir() 调用点改写成它。改写保持 require 兜底：前奏万一没跑，行为退回现状。
const tmpdirCall = /require\((['"])(?:node:)?os\1\)\.tmpdir\(\)/g;
const tmpdirReplacement = '(globalThis.__rhineTmpdir || require("os").tmpdir())';

// 平台插件的移动端构建差异由各插件自己的 build.cjs 提供；这里只保留所有插件共用的
// 运行时适配：注入 web API 补丁、改写 worker 与 transport 的临时目录。
module.exports = (webApis = 'ios-web-apis.cjs') => ({
    name: 'mobile-web-apis',
    setup(build) {
        build.onLoad({ filter: /[\\/]MusicBridge[\\/]worker\.cjs$/ }, (args) => {
            const contents = fs.readFileSync(args.path, 'utf8').replace(tmpdirCall, tmpdirReplacement);
            return {
                contents:
                    `require(${JSON.stringify(path.join(path.dirname(args.path), webApis))});\n` + contents,
                loader: 'js',
            };
        });
        build.onLoad({ filter: /[\\/][^\\/]+-transport\.cjs$/ }, (args) => ({
            contents: fs.readFileSync(args.path, 'utf8').replace(tmpdirCall, tmpdirReplacement),
            loader: 'js',
        }));
        // 移动 bundle 里每个 os.tmpdir() 调用点都必须是改写后的形式：少改一处就会
        // 在真机读 /tmp（Android 没有这个目录）。插件自己的上游模块改写也由各插件
        // 的 build.cjs 保证；这里只断言最终 bundle 没有裸调用。
        build.onEnd((result) => {
            if (result.errors.length > 0) {
                return;
            }
            const outfile = build.initialOptions.outfile;
            if (!outfile) {
                return;
            }
            const bundle = fs.readFileSync(outfile, 'utf8');
            const bare = bundle.match(/require\("(?:node:)?os"\)\.tmpdir\(\)/g) || [];
            const rewritten = bundle.match(/__rhineTmpdir \|\| require\("(?:node:)?os"\)\.tmpdir\(\)/g) || [];
            if (bare.length !== rewritten.length) {
                throw new Error(
                    `mobile bundle has ${bare.length - rewritten.length} unrewritten ` +
                        'os.tmpdir() call site(s); every one must read globalThis.__rhineTmpdir',
                );
            }
        });
    },
});
