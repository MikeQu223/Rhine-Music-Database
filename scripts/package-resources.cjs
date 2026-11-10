// 按显式白名单组装干净的应用，禁止整目录复制暂存区。
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve('output/resources');
const out = path.resolve(process.argv[2]);
// Android 的 3D 资源（模型导出、场景/槽位配置、烘焙贴图）取自独立副本目录，
// 由 scripts/build-android.cjs 从 Assets/android-3d/ 生成；其余文件仍走公共资源。
// 桌面与 iOS 不设置 RHINE_ANDROID_BUILD，下面的分支完全不会命中。
const androidRuntime = process.env.RHINE_ANDROID_BUILD === '1';
const android3dRoot = path.resolve('output/android-3d');
const android3dSource = path.resolve('Assets/android-3d');
const android3dFiles = new Set([
    'archive-baked-surface.bin',
    // 不再要求 archive-baked-surface-etc2.bin：那套手写编码器有字节序与位布局缺陷
    // （标准解码器 PSNR 5.7 dB，真机花屏），运行时已默认关闭，产物也不再烘焙。
    'archive-baked-light.bin',
    'archive-baked-normal.bin',
    'archive-cassette.bin',
    'archive-cassette-indices.bin',
    'archive-cassette.json',
    'archive-assembly.bin',
    'archive-assembly-indices.bin',
    'archive-assembly.json',
    'slots.json',
    'scene-fixture.json',
]);
const files = [
    'archive-baked-surface.bin',
    // BC7 只有桌面 / macOS 用：GLES 上 isTextureFormatSupported(BC7) 恒为 false，
    // RhiScene 会直接跳过它。这一份 1.4 MB 在 Android 包里是纯死重，不带。
    ...(androidRuntime ? [] : ['archive-baked-surface-bc7.bin']),
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
    'misans-glyphs.json',
    ...['light', 'regular', 'demibold', 'bold'].map((w) => `RhineMiSans-${w}.otf`),
];
fs.mkdirSync(out, {
    recursive: true,
});
if (androidRuntime) {
    // 缺文件要在打包前报清楚：否则只抛一个 ENOENT，很难联想到是 3D 副本没生成。
    for (const name of android3dFiles) {
        const expected = path.join(android3dRoot, name);
        assert(
            fs.existsSync(expected),
            `Android 3D resource missing: ${expected} (run npm run build:android to generate output/android-3d)`,
        );
    }
}
for (const name of files) {
    let source = root;
    if (androidRuntime && android3dFiles.has(name)) {
        // 副本目录里放了同名文件就以它为准（将来单独换某张烘焙贴图/配置时不必改脚本），
        // 否则用构建期从副本重新导出的产物。两条来源都只在 Android 下生效。
        source = fs.existsSync(path.join(android3dSource, name)) ? android3dSource : android3dRoot;
    }
    fs.mkdirSync(path.dirname(path.join(out, name)), { recursive: true });
    fs.copyFileSync(path.join(source, name), path.join(out, name));
}
const bridge = path.join(root, 'MusicBridge');
const bundle = path.resolve('output/bridge-build');
const target = path.join(out, 'MusicBridge');
fs.mkdirSync(target, {
    recursive: true,
});
// 发布包只放单文件桥接；平台插件目录单独复制。
fs.copyFileSync(path.join(bundle, 'MusicBridge/worker.cjs'), path.join(target, 'worker.cjs'));
// Android 的运行时是 libnode.so：没有独立 node 可执行文件，Node 的许可证改用仓库里的那一份
// （APK 仍然分发 libnode.so，许可证不能省）。androidRuntime 在文件开头已定义。
for (const name of ['lyrics-source.json', 'LyricsKit-LICENSE']) {
    fs.copyFileSync(path.join(bridge, name), path.join(target, name));
}
fs.copyFileSync(
    androidRuntime ? 'licenses/nodejs-mobile/LICENSE' : path.join(bridge, 'NODE-LICENSE'),
    path.join(target, 'NODE-LICENSE'),
);
if (!androidRuntime) {
    const nodeName = process.platform === 'win32' ? 'node.exe' : 'node';
    fs.copyFileSync(path.join(bridge, nodeName), path.join(target, nodeName));
    fs.chmodSync(path.join(target, nodeName), 0o755);
}
for (const name of ['plugins', 'local-plugins']) {
    const source = path.join(bundle, 'MusicBridge', name);
    if (fs.existsSync(source)) {
        fs.cpSync(source, path.join(target, name), { recursive: true });
    }
}
fs.copyFileSync('NOTICE', path.join(out, 'NOTICE'));
// 许可证原样复制，不转换字体或替换资源。
fs.copyFileSync('licenses/NotoSansSymbols2-OFL.txt', path.join(out, 'NotoSansSymbols2-OFL.txt'));
fs.copyFileSync('licenses/MiSans-license.pdf', path.join(out, 'MiSans-license.pdf'));
fs.writeFileSync(path.join(out, 'runtime-packages.json'), JSON.stringify({ core: true }, null, 2) + '\n');
console.log(`Clean resources: ${files.length} files, core bridge`);
