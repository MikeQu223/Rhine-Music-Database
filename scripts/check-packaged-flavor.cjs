// 验证 per-provider 产物只包含选中的插件，descriptor 与 manifest 一致。
const fs = require('node:fs');
const path = require('node:path');
const { app, resourceDirectory } = require('./app-layout.cjs');

const bridge = path.resolve(process.argv[2] || path.join(app, resourceDirectory, 'MusicBridge'));
const pluginsRoot = path.join(bridge, 'local-plugins');
const descriptors = path.join(bridge, 'plugins/descriptors');
const installed = fs.existsSync(pluginsRoot)
    ? fs
          .readdirSync(pluginsRoot, { withFileTypes: true })
          .filter(
              (entry) =>
                  entry.isDirectory() && fs.existsSync(path.join(pluginsRoot, entry.name, 'manifest.json')),
          )
          .map((entry) => entry.name)
          .sort()
    : [];
const described = fs.existsSync(descriptors)
    ? fs
          .readdirSync(descriptors)
          .filter((name) => name.endsWith('.json'))
          .map((name) => name.slice(0, -5))
          .filter((id) => id !== 'local' && id !== 'siren')
          .sort()
    : [];
const failures = [];
if (!installed.length) {
    failures.push('no plugin packages installed');
}
if (JSON.stringify(installed) !== JSON.stringify(described)) {
    failures.push(`installed and descriptor ids differ: ${installed.join(',')} vs ${described.join(',')}`);
}
for (const id of installed) {
    const directory = path.join(pluginsRoot, id);
    if (!fs.existsSync(path.join(directory, 'plugin.cjs'))) {
        failures.push(`plugin bundle missing: ${id}/plugin.cjs`);
    }
    const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'manifest.json'), 'utf8'));
    if (manifest.id !== id) {
        failures.push(`manifest id mismatch in ${id}: ${manifest.id}`);
    }
}
if (failures.length) {
    for (const failure of failures) {
        console.error('plugin flavor failed: ' + failure);
    }
    process.exit(1);
}
console.log('Plugin flavor contains exactly: ' + installed.join(', '));
