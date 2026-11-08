const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { app, resourceDirectory } = require('./app-layout.cjs');
process.chdir(path.resolve(__dirname, '..'));
const mac = process.platform === 'darwin';
const win = process.platform === 'win32';
const resources = path.join(app, resourceDirectory);
const bridgeRoot = path.join(resources, 'MusicBridge');
const pluginRoot = path.join(bridgeRoot, 'local-plugins');
const installedPlugins = fs.existsSync(pluginRoot)
    ? fs
          .readdirSync(pluginRoot, { withFileTypes: true })
          .filter(
              (entry) =>
                  entry.isDirectory() &&
                  !entry.name.startsWith('.') &&
                  fs.existsSync(path.join(pluginRoot, entry.name, 'manifest.json')),
          )
          .map((entry) => entry.name)
    : [];
const fullPlugins = ['netease', 'qq', 'kugou'].every((id) => installedPlugins.includes(id));
const coreOnly = installedPlugins.length === 0;
// 统一使用 python3：多数发行版不再提供 python 命令。
const python = process.env.PYTHON || (win ? 'python' : 'python3');
function run(command, args, env = {}) {
    const result = spawnSync(command, args, {
        stdio: 'inherit',
        env: {
            ...process.env,
            ...env,
        },
    });
    if (result.error) {
        throw result.error;
    }
    if (result.status !== 0) {
        process.exit(result.status || 1);
    }
}
// 仓库边界检查已停用，需要时手动运行 node scripts/check-repository.cjs。
run(python, ['scripts/check-qt-project.py']);
run(process.execPath, ['scripts/check-music-upstream.cjs']);
run(process.execPath, ['--test', 'scripts/test-ffmpeg-decoders.cjs']);
run(process.execPath, ['--test', 'scripts/test-ios-bridge-plugin.cjs']);
run(process.execPath, ['--test', 'scripts/test-plugin-registry.cjs']);
run(process.execPath, ['--test', 'scripts/test-plugin-package.cjs']);

run(
    'ctest',
    coreOnly || !fullPlugins
        ? ['--test-dir', 'output/qt-build', '--output-on-failure', '-R', 'qt_offline']
        : ['--test-dir', 'output/qt-build', '--output-on-failure'],
);
if (win) {
    run(process.execPath, ['scripts/check-dxc-cache.cjs']);
}
// 验证最终应用包
const bridgeTests = ['Qt/tests/local-lyrics.cjs', 'Qt/tests/ios-bridge.cjs'];
if (fullPlugins) {
    run(process.execPath, ['scripts/check-packaged-bridge.cjs', bridgeRoot]);
} else if (installedPlugins.length) {
    run(process.execPath, ['scripts/check-packaged-flavor.cjs', bridgeRoot]);
    console.log('Per-provider package; full provider bridge regressions skipped.');
} else {
    run(process.execPath, ['scripts/check-packaged-core.cjs', bridgeRoot]);
    console.log('Core-only package; provider bridge regressions skipped.');
}
for (const script of bridgeTests) {
    run(process.execPath, [script, bridgeRoot]);
}
if (mac) {
    run('codesign', ['--verify', '--deep', '--strict', app]);
}
run(python, ['scripts/audit-qt.py', app]);
run(process.execPath, ['scripts/check-packaged-app.cjs', app]);
console.log('Cross-platform offline regressions and application package audit passed');
