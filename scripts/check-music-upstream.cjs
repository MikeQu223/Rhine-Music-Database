// 核心不再携带第三方平台上游包；插件包各自锁定版本与许可证。
// 本地存在插件包时，至少确保声明了依赖的插件同时提交 lockfile。
const fs = require('node:fs');
const path = require('node:path');
const corePackage = JSON.parse(fs.readFileSync(path.resolve('MusicBridge/package.json'), 'utf8'));
const allowedCoreDependencies = new Set(['chardet', 'form-data', 'node-fetch']);
for (const name of Object.keys(corePackage.dependencies || {})) {
    if (!allowedCoreDependencies.has(name)) {
        throw new Error('core MusicBridge dependency is not in the generic allowlist: ' + name);
    }
}
const localPlugins = path.resolve('MusicBridge/local-plugins');
if (!fs.existsSync(localPlugins)) {
    console.log('No local plugin packages; upstream pins are checked by plugin CI.');
    process.exit(0);
}
let checked = 0;
for (const entry of fs.readdirSync(localPlugins, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name === 'node_modules') {
        continue;
    }
    const directory = path.join(localPlugins, entry.name);
    const packageFile = path.join(directory, 'package.json');
    if (!fs.existsSync(packageFile)) {
        continue;
    }
    const manifest = JSON.parse(fs.readFileSync(packageFile, 'utf8'));
    if (manifest.dependencies && Object.keys(manifest.dependencies).length) {
        if (!fs.existsSync(path.join(directory, 'package-lock.json'))) {
            throw new Error(entry.name + ' declares dependencies but has no package-lock.json');
        }
        checked += 1;
    }
}
console.log('Local plugin dependency locks checked: ' + checked + ' package(s)');
