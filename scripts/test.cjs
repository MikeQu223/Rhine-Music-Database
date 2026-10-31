const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { app, resourceDirectory } = require('./app-layout.cjs');
process.chdir(path.resolve(__dirname, '..'));
const mac = process.platform === 'darwin';
const win = process.platform === 'win32';
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
// CI 已停用仓库边界检查；本地测试仍保留该检查。
if (process.env.CI !== 'true') {
    run(process.execPath, ['scripts/check-repository.cjs']);
}
run(python, ['scripts/check-qt-project.py']);
run(process.execPath, ['scripts/check-music-upstream.cjs']);

run('ctest', ['--test-dir', 'output/qt-build', '--output-on-failure']);
// 验证最终应用包
const resources = path.join(app, resourceDirectory);
const bridgeTests = [
    'Qt/tests/local-lyrics.cjs',
    'Qt/tests/ios-bridge.cjs',
    'Qt/tests/netease-client.mjs',
    'Qt/tests/qq-client.mjs',
    'Qt/tests/kugou-client.mjs',
];
run(process.execPath, ['scripts/check-packaged-bridge.cjs', resources + '/MusicBridge']);
for (const script of bridgeTests) {
    run(process.execPath, [script, resources + '/MusicBridge']);
}
if (mac) {
    run('codesign', ['--verify', '--deep', '--strict', app]);
}
run(python, ['scripts/audit-qt.py', app]);
run(process.execPath, ['scripts/check-packaged-app.cjs', app]);
console.log('Cross-platform offline regressions and application package audit passed');
