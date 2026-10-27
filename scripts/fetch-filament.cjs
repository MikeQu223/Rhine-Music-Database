// 获取 Filament SDK（官方发布包 + 稀疏源码检出），供 -DRHINE_FILAMENT=ON 的构建使用。
// 幂等：目录已存在时直接跳过，可安全重复执行。
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const dist = path.join(root, 'third_party', 'filament-dist');
const src = path.join(root, 'third_party', 'filament-src');
const version = 'v1.78.1';
const archive = `filament-${version}-linux.tgz`;
const url = `https://github.com/google/filament/releases/download/${version}/${archive}`;
function run(command, args, cwd) {
    execFileSync(command, args, {
        cwd,
        stdio: 'inherit',
    });
}
fs.mkdirSync(path.join(root, 'third_party'), {
    recursive: true,
});
if (fs.existsSync(path.join(dist, 'bin', 'matc'))) {
    console.log(`Filament SDK 已就绪：${path.relative(root, dist)}`);
} else {
    const tarball = path.join(root, 'third_party', archive);
    if (!fs.existsSync(tarball)) {
        console.log(`下载 ${url}`);
        run('curl', ['-L', '--fail', '--retry', '3', '-o', tarball, url], root);
    }
    fs.rmSync(dist, { recursive: true, force: true });
    fs.mkdirSync(dist, { recursive: true });
    console.log('解包 SDK');
    run('tar', ['-xzf', tarball, '-C', dist, '--strip-components=1'], root);
    console.log(`Filament SDK:${path.relative(root, dist)}`);
}
// SDK 发布包缺少 VulkanPlatform.h 与 bluevk，用稀疏检出补齐。
if (fs.existsSync(path.join(src, 'filament', 'backend', 'include', 'backend', 'platforms', 'VulkanPlatform.h'))) {
    console.log(`Filament 源码头已就绪：${path.relative(root, src)}`);
} else {
    console.log('稀疏检出 Filament 源码头');
    fs.rmSync(src, { recursive: true, force: true });
    run('git', [
        'clone',
        '--depth',
        '1',
        '--branch',
        version,
        '--filter=blob:none',
        '--sparse',
        'https://github.com/google/filament.git',
        src,
    ], root);
    run('git', ['sparse-checkout', 'set', 'filament/include', 'filament/backend/include'], src);
    run('git', ['sparse-checkout', 'add', 'libs/bluevk'], src);
}
console.log('完成。用 -DRHINE_FILAMENT=ON 配置即可启用。');
