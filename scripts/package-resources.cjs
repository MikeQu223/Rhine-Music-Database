// 按显式白名单组装干净的应用，禁止整目录复制暂存区。
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const assert = require('node:assert/strict');
const root = path.resolve('output/resources');
const out = path.resolve(process.argv[2]);
const files = [
    'archive-baked-surface.bin',
    'archive-baked-surface-bc7.bin',
    'archive-baked-light.bin',
    'archive-baked-normal.bin',
    'archive-cassette.bin',
    'archive-cassette-indices.bin',
    'archive-cassette.json',
    'archive-assembly.bin',
    'archive-assembly-indices.bin',
    'archive-assembly.json',
    'NotoSansSymbols2-Regular.ttf',
    'slots.json',
    'scene-fixture.json',
    'boot-lettering-art.json',
    ...[
        'netease-sq',
        'netease-hires',
        'netease-jymaster',
        'netease-jyeffect',
        'netease-sky',
        'qq-hq',
        'qq-sq',
        'kugou-hq',
        'kugou-sq',
        'kugou-hires',
    ].map((name) => `quality/${name}.png`),
    'quality/sources.json',
    'misans-glyphs.json',
    ...['light', 'regular', 'demibold', 'bold'].map((w) => `RhineMiSans-${w}.otf`),
];
fs.mkdirSync(out, {
    recursive: true,
});
for (const name of files) {
    fs.mkdirSync(path.dirname(path.join(out, name)), { recursive: true });
    fs.copyFileSync(path.join(root, name), path.join(out, name));
}
const bridge = path.join(root, 'MusicBridge');
const bundle = path.resolve('output/bridge-build');
const target = path.join(out, 'MusicBridge');
fs.mkdirSync(target, {
    recursive: true,
});
// 发布包只放单文件桥接；上游脚本和运行时数据保持可读。
fs.copyFileSync(path.join(bundle, 'MusicBridge/worker.cjs'), path.join(target, 'worker.cjs'));
fs.copyFileSync(path.join(bundle, 'MusicBridge/xhr-sync-worker.js'), path.join(target, 'xhr-sync-worker.js'));
for (const name of ['lyrics-source.json', 'LyricsKit-LICENSE', 'NODE-LICENSE']) {
    fs.copyFileSync(path.join(bridge, name), path.join(target, name));
}
const nodeName = process.platform === 'win32' ? 'node.exe' : 'node';
fs.copyFileSync(path.join(bridge, nodeName), path.join(target, nodeName));
fs.chmodSync(path.join(target, nodeName), 0o755);
fs.cpSync(path.join(bundle, 'MusicBridge/upstream'), path.join(target, 'upstream'), {
    recursive: true,
});
// 上游按相对位置读取中国 IP 段和替代音源占位模块，目录必须与桥接同级。
fs.cpSync(path.join(bundle, 'data'), path.join(out, 'data'), {
    recursive: true,
});
fs.cpSync(path.join(bundle, 'modules'), path.join(out, 'modules'), {
    recursive: true,
});
const worker = fs.readFileSync(path.join(bridge, 'worker.cjs'), 'utf8');
const routeBlock = worker.match(/const routes = Object.freeze\(\{([\s\S]*?)\}\);/)[1];
const endpoints = [...routeBlock.matchAll(/:\s*'([^']+)'/g)].map((m) => m[1]);
// 生成文件只包含 routes 引用的接口，避免把整个上游模块目录装进发布包。
const visited = new Set();

function collectPackage(name, from, optional = false) {
    if (name.startsWith('node:')) {
        return;
    }
    const req = createRequire(path.join(from, 'package.json'));
    const location = (req.resolve.paths(name + '/package.json') || [])
        .map((p) => path.join(p, name))
        .find((p) => fs.existsSync(path.join(p, 'package.json')));
    if (!location) {
        if (optional) {
            return;
        }
        throw new Error(`Missing runtime dependency: ${name}`);
    }

    assert(location.startsWith(bridge + path.sep));
    if (visited.has(location)) {
        return;
    }
    visited.add(location);
    const manifest = JSON.parse(fs.readFileSync(path.join(location, 'package.json'), 'utf8'));
    const optionalDeps = manifest.optionalDependencies || {};
    for (const dep of Object.keys({
        ...manifest.dependencies,
        ...optionalDeps,
    })) {
        collectPackage(dep, location, dep in optionalDeps);
    }
}
for (const name of [
    '@neteasecloudmusicapienhanced/api',
    '@yakult-green-tea/qq-music-api',
    'kugoumusicapi',
    'chardet',
]) {
    collectPackage(name, bridge);
}
fs.copyFileSync('NOTICE', path.join(out, 'NOTICE'));
// 许可证原样复制，不转换字体或替换资源。
fs.copyFileSync('licenses/NotoSansSymbols2-OFL.txt', path.join(out, 'NotoSansSymbols2-OFL.txt'));
fs.copyFileSync('licenses/MiSans-license.pdf', path.join(out, 'MiSans-license.pdf'));
fs.writeFileSync(
    path.join(out, 'runtime-packages.json'),
    JSON.stringify(
        {
            api: '4.41.1',
            qq: '3.3.1',
            kugou: 'ba3645f2c89e6b9d4fec82ff783c15287e4c5f43',
            endpoints,
            packages: [...visited]
                .map((p) => ({
                    path: path.relative(bridge, p),
                    version: JSON.parse(fs.readFileSync(path.join(p, 'package.json'))).version,
                }))
                .sort((a, b) => a.path.localeCompare(b.path)),
        },
        null,
        2,
    ) + '\n',
);
console.log(
    `Clean resources: ${files.length} files, ${endpoints.length} API endpoints, ${visited.size} dependency packages`,
);
