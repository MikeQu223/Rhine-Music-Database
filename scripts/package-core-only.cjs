// 从完整桥接资源生成 core-only 检查副本：去掉第三方插件目录和 descriptor。
const fs = require('node:fs');
const path = require('node:path');
const { app, resourceDirectory } = require('./app-layout.cjs');

const source = path.resolve(process.argv[2] || path.join(app, resourceDirectory, 'MusicBridge'));
const destination = path.resolve(process.argv[3] || 'output/core-only/MusicBridge');
if (!fs.existsSync(source)) {
    throw new Error('Source bridge directory is missing: ' + source);
}
fs.rmSync(destination, { recursive: true, force: true });
fs.cpSync(source, destination, { recursive: true });
fs.rmSync(path.join(destination, 'local-plugins'), { recursive: true, force: true });
fs.rmSync(path.join(destination, 'upstream'), { recursive: true, force: true });
fs.rmSync(path.join(destination, 'node_modules'), { recursive: true, force: true });
const descriptors = path.join(destination, 'plugins/descriptors');
if (fs.existsSync(descriptors)) {
    for (const name of fs.readdirSync(descriptors)) {
        if (!['local.json', 'siren.json'].includes(name)) {
            fs.rmSync(path.join(descriptors, name), { force: true });
        }
    }
}
console.log('Core-only bridge prepared: ' + path.relative(process.cwd(), destination));
