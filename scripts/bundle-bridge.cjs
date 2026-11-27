// 把 core 的 worker（host + 内置塞壬）打成一个 CommonJS 文件；第三方平台由独立插件包提供。
const fs = require('node:fs');
const path = require('node:path');
const esbuild = require('esbuild');

const root = path.resolve(__dirname, '..');
process.chdir(root);
const source = path.resolve(process.argv[2] || 'output/resources/MusicBridge');
const output = path.resolve(process.argv[3] || 'output/bridge-build');
const bridgeOutput = path.join(output, 'MusicBridge');
const mobileRuntime = process.env.RHINE_IOS_BUILD === '1' || process.env.RHINE_ANDROID_BUILD === '1';
const webApisFile = process.env.RHINE_ANDROID_BUILD === '1' ? 'android-web-apis.cjs' : 'ios-web-apis.cjs';

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
    fs.rmSync(bridgeOutput, { recursive: true, force: true });
    fs.mkdirSync(bridgeOutput, { recursive: true });
    for (const name of ['plugins', 'local-plugins']) {
        const directory = path.join(source, name);
        if (fs.existsSync(directory)) {
            fs.cpSync(directory, path.join(bridgeOutput, name), { recursive: true });
        }
    }
    const result = await esbuild.build({
        entryPoints: [path.join(source, 'worker.cjs')],
        outfile: path.join(bridgeOutput, 'worker.cjs'),
        absWorkingDir: source,
        bundle: true,
        platform: 'node',
        format: 'cjs',
        target: mobileRuntime ? 'node18' : 'node22',
        logLevel: 'warning',
        logOverride: { 'require-resolve-not-external': 'silent' },
        // 体积（docs/ANDROID.md §5.4）：bundle 进 /rhine-assets 的 worker.cjs 约
        // 14 MB，开空白与语法压缩预计砍掉四成。刻意不开 minifyIdentifiers——
        // jsdom 依赖函数名与类名（原型方法按名字查找），改标识符会崩；两个语法级
        // 开关不改导出名与属性名，语义等价。
        minifyWhitespace: true,
        minifySyntax: true,
        plugins: [...(mobileRuntime ? [require('./mobile-bridge-plugin.cjs')(webApisFile, '')] : [])],
    });
    failOnDynamicRequires(result);
    await esbuild.build({
        entryPoints: [path.join(source, 'plugin-control-cli.cjs')],
        outfile: path.join(bridgeOutput, 'plugin-control-cli.cjs'),
        bundle: true,
        platform: 'node',
        format: 'cjs',
        target: mobileRuntime ? 'node18' : 'node22',
        plugins: mobileRuntime ? [require('./mobile-bridge-plugin.cjs')(webApisFile)] : [],
    });
    const size = fs.statSync(path.join(bridgeOutput, 'worker.cjs')).size;
    console.log(`Bridge bundle: ${(size / 1024 / 1024).toFixed(2)} MB`);
}

main().catch((error) => {
    console.error(error.message);
    process.exit(1);
});
