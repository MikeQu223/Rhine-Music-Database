// 把桥接入口、接口实现和依赖闭包打成一个 CommonJS 文件，发布包不再携带 node_modules
const fs = require('node:fs');
const path = require('node:path');
const esbuild = require('esbuild');

const root = path.resolve(__dirname, '..');
process.chdir(root);
const source = path.resolve(process.argv[2] || 'output/resources/MusicBridge');
const output = path.resolve(process.argv[3] || 'output/bridge-build');
const bridgeOutput = path.join(output, 'MusicBridge');
const neteasePackage = path.join(source, 'node_modules/@neteasecloudmusicapienhanced/api');
const kugouPackage = path.join(source, 'node_modules/kugoumusicapi');
// 移动端两个平台用的都是 Node 18（nodejs-mobile 18.20.4），语法目标与 API 补丁必须一起切换：
// 只改 target 会让 esbuild 输出 node18 不认识的语法，只打补丁不降 target 又会让新语法漏进去。
const mobileRuntime = process.env.RHINE_IOS_BUILD === '1' || process.env.RHINE_ANDROID_BUILD === '1';
const webApisFile = process.env.RHINE_ANDROID_BUILD === '1' ? 'android-web-apis.cjs' : 'ios-web-apis.cjs';
const unblockPackage = path.join(source, 'node_modules/@neteasecloudmusicapienhanced/unblockmusic-utils');

/** 写入构建期生成文件，内容完全由已安装的上游包和分派表决定。 */
function writeGenerated(file, contents) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, contents);
}

/** 读取 worker 的路由表，生成文件与运行时分派使用同一份接口清单。 */
function readEndpointNames() {
    const worker = fs.readFileSync(path.join(source, 'worker.cjs'), 'utf8');
    const block = /const routes = Object\.freeze\(\{([\s\S]*?)\}\);/.exec(worker);
    if (!block) {
        throw new Error('Unable to locate the bridge routes definition');
    }
    return [...block[1].matchAll(/:\s*'([^']+)'/g)].map((match) => match[1]);
}

/** 生成网易云接口注册表；缺少接口文件时立即失败，避免发布包静默缺功能。 */
function generateNeteaseEndpoints(names) {
    const entries = names.map((name) => {
        const relative = `./node_modules/@neteasecloudmusicapienhanced/api/module/${name}.js`;
        if (!fs.existsSync(path.join(source, relative))) {
            throw new Error(`Missing NetEase endpoint module: ${name}`);
        }
        return `    '${name}': require('${relative}'),`;
    });
    writeGenerated(
        path.join(source, 'netease-endpoints.cjs'),
        [
            '// 由 scripts/bundle-bridge.cjs 生成，勿手工修改。',
            'module.exports = {',
            ...entries,
            '};',
            '',
        ].join('\n'),
    );
}

/** 生成酷狗接口注册表，复刻上游 main.js 的 cookie 转换和请求注入。 */
function generateKugouPackage() {
    const modules = fs
        .readdirSync(path.join(kugouPackage, 'module'))
        .filter((name) => name.endsWith('.js') && !name.startsWith('_'))
        .reverse();
    const entries = modules.map((name) => {
        const key = name.split('.').shift();
        return `    '${key}': wrap(require('./node_modules/kugoumusicapi/module/${name}')),`;
    });
    const header = [
        '// 由 scripts/bundle-bridge.cjs 生成，勿手工修改。',
        '// 上游 main.js 依赖运行时扫描目录，这里改成静态注册以便单文件打包。',
        "const { cookieToJson } = require('./node_modules/kugoumusicapi/util/index.js');",
        'function wrap(fileModule) {',
        '    return (data = {}) => {',
        "        if (typeof data.cookie === 'string') {",
        '            data.cookie = cookieToJson(data.cookie);',
        '        }',
        '        return fileModule({ ...data, cookie: data.cookie ? data.cookie : {} }, (...args) => {',
        "            const { createRequest } = require('./node_modules/kugoumusicapi/util/request.js');",
        '            return createRequest(...args);',
        '        });',
        '    };',
        '}',
        'module.exports = {',
    ];
    writeGenerated(path.join(source, 'kugou-package.cjs'), [...header, ...entries, '};', ''].join('\n'));
}

/**
 * 生成替代音源注册表与占位文件。
 * 上游按目录扫描并 require 模块，发布包用占位文件满足路径检查，
 * 启动时再把真实模块放进 require 缓存。
 */
function generateUnblockModules() {
    const modules = fs
        .readdirSync(path.join(unblockPackage, 'modules'))
        .filter((name) => name.endsWith('.js'))
        .map((name) => name.split('.').shift());
    const entries = modules.map(
        (name) =>
            `    '${name}': require('./node_modules/@neteasecloudmusicapienhanced/unblockmusic-utils/modules/${name}.js'),`,
    );
    writeGenerated(
        path.join(source, 'unblock-modules.cjs'),
        [
            '// 由 scripts/bundle-bridge.cjs 生成，勿手工修改。',
            'module.exports = {',
            ...entries,
            '};',
            '',
        ].join('\n'),
    );
    fs.mkdirSync(path.join(output, 'modules'), { recursive: true });
    for (const name of modules) {
        writeGenerated(
            path.join(output, 'modules', name + '.js'),
            '// 占位文件：实现已编入 worker.cjs，由启动时预置的 require 缓存提供。\n',
        );
    }
}

/** 复制只有运行时才读取的数据文件；其余依赖全部内联。 */
function copyRuntimeFiles() {
    fs.mkdirSync(path.join(output, 'data'), { recursive: true });
    fs.copyFileSync(
        path.join(neteasePackage, 'data/china_ip_ranges.txt'),
        path.join(output, 'data/china_ip_ranges.txt'),
    );
    fs.cpSync(path.join(source, 'upstream'), path.join(bridgeOutput, 'upstream'), { recursive: true });
}

/** 让打包后的请求模块可以丢弃密钥缓存，效果等同原来的缓存删除。 */
// 移动端由 mobile-bridge-plugin 接管 request.js（它还要改写 os.tmpdir()），
// 两边必须写入同一段钩子，这里保持唯一来源。
const requestResetHook = [
    '',
    '// 打包后模块常驻，提供只清空密钥缓存的构建钩子。',
    'module.exports.__rhineResetXeapiKeyCache = () => {',
    '    xeapi_public_key = null;',
    '};',
    '',
].join('\n');
const requestResetPlugin = {
    name: 'netease-request-reset',
    setup(build) {
        const requestFile = path.join(neteasePackage, 'util/request.js');
        build.onLoad({ filter: /util[\\/]request\.js$/ }, (args) => {
            if (path.resolve(args.path) !== requestFile) {
                return;
            }
            // 移动端交给移动插件：esbuild 对同一文件只执行第一个命中的 onLoad，
            // 这里返回 undefined 才会继续后面的插件。历史上的顺序错误让
            // request.js 的 os.tmpdir() 改写整个失效，真机读 /tmp/anonymous_token
            // 直接 ENOENT，所有网易云请求在模块加载时失败（登录 503）。
            if (mobileRuntime) {
                return;
            }
            const contents = fs.readFileSync(args.path, 'utf8');
            return {
                contents: contents + requestResetHook,
                loader: 'js',
            };
        });
    },
};

/**
 * 移动端 bundle 里每个 os.tmpdir() 调用点都必须是改写后的形式。
 * 少改一处就会在真机上去读 /tmp（Android 没有这个目录），anonymous_token 直接
 * ENOENT，所有网易云请求在模块加载时失败——表现为登录时"503 音乐请求失败"。
 * 历史上 request.js 就是被 netease-request-reset 的 onLoad 抢先接管漏掉的。
 */
function assertMobileTmpdirRewrites() {
    if (!mobileRuntime) {
        return;
    }
    const bundle = fs.readFileSync(path.join(bridgeOutput, 'worker.cjs'), 'utf8');
    const bare = bundle.match(/require\("(?:node:)?os"\)\.tmpdir\(\)/g) || [];
    const rewritten = bundle.match(/__rhineTmpdir \|\| require\("(?:node:)?os"\)\.tmpdir\(\)/g) || [];
    if (bare.length !== rewritten.length) {
        throw new Error(
            `Mobile bundle has ${bare.length - rewritten.length} unrewritten os.tmpdir() call site(s); ` +
                'all of them must read globalThis.__rhineTmpdir (see mobile-bridge-plugin.cjs)',
        );
    }
}

/** 校验 esbuild 没有留下无法打包的动态 require，避免发布后才暴露缺模块。 */
function failOnDynamicRequires(result) {
    const dynamic = result.warnings.filter((warning) => /will not be bundled/.test(warning.text));
    if (!dynamic.length) {
        return;
    }
    const details = dynamic.map((warning) => `${warning.location?.file || '?'}: ${warning.text}`);
    throw new Error('Unbundled dynamic require found:\n' + details.join('\n'));
}

async function main() {
    if (!fs.existsSync(path.join(source, 'node_modules'))) {
        throw new Error('Bridge dependencies are missing; run npm run build first');
    }
    for (const directory of [output, bridgeOutput]) {
        fs.rmSync(directory, { recursive: true, force: true });
    }
    fs.mkdirSync(bridgeOutput, { recursive: true });
    const names = readEndpointNames();
    generateNeteaseEndpoints(names);
    generateKugouPackage();
    generateUnblockModules();
    copyRuntimeFiles();
    const result = await esbuild.build({
        entryPoints: [path.join(source, 'worker.cjs')],
        outfile: path.join(bridgeOutput, 'worker.cjs'),
        absWorkingDir: source,
        bundle: true,
        platform: 'node',
        format: 'cjs',
        target: mobileRuntime ? 'node18' : 'node22',
        logLevel: 'warning',
        // jsdom 的同步 XHR worker 由下面的第二个产物提供，路径在发布包内仍然有效。
        logOverride: { 'require-resolve-not-external': 'silent' },
        plugins: [
            requestResetPlugin,
            ...(mobileRuntime ? [require('./mobile-bridge-plugin.cjs')(webApisFile, requestResetHook)] : []),
        ],
    });
    failOnDynamicRequires(result);
    assertMobileTmpdirRewrites();
    // jsdom 的同步 XHR 会 require.resolve 一个独立 worker 文件；
    // 单独打包到同一目录，保持 require.resolve 的相对路径可用。
    const syncWorker = await esbuild.build({
        entryPoints: [path.join(source, 'node_modules/jsdom/lib/jsdom/living/xhr/xhr-sync-worker.js')],
        outfile: path.join(bridgeOutput, 'xhr-sync-worker.js'),
        absWorkingDir: source,
        bundle: true,
        platform: 'node',
        format: 'cjs',
        target: mobileRuntime ? 'node18' : 'node22',
        logLevel: 'warning',
        logOverride: { 'require-resolve-not-external': 'silent' },
    });
    failOnDynamicRequires(syncWorker);
    if (!fs.existsSync(path.join(bridgeOutput, 'xhr-sync-worker.js'))) {
        throw new Error('jsdom sync XHR worker was not generated');
    }
    const size = fs.statSync(path.join(bridgeOutput, 'worker.cjs')).size;
    console.log(`Bridge bundle: ${names.length} NetEase endpoints, ${(size / 1024 / 1024).toFixed(2)} MB`);
}

main().catch((error) => {
    console.error(error.message);
    process.exit(1);
});
