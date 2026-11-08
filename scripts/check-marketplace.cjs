// 校验本地/CI 插件市场目录：索引、插件目录、manifest 与文件列表一致。
const fs = require('node:fs');
const path = require('node:path');

const indexFile = path.resolve(process.argv[2] || 'index.json');
const root = path.dirname(indexFile);
const failures = [];
const index = JSON.parse(fs.readFileSync(indexFile, 'utf8'));
if (index.schemaVersion !== 1 || !Array.isArray(index.plugins)) {
    failures.push('index.json schema is invalid');
}
const seen = new Set();
for (const entry of index.plugins || []) {
    const id = String(entry.id || '');
    if (!/^[a-z0-9-]{1,40}$/.test(id) || seen.has(id)) {
        failures.push('invalid or duplicate plugin id: ' + id);
        continue;
    }
    seen.add(id);
    const directory = path.join(root, entry.path || 'plugins/' + id);
    if (!fs.existsSync(directory)) {
        failures.push('missing plugin directory: ' + id);
        continue;
    }
    const manifestFile = path.join(directory, 'manifest.json');
    if (!fs.existsSync(manifestFile)) {
        failures.push('missing manifest: ' + id);
        continue;
    }
    const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
    if (manifest.id !== id) {
        failures.push('manifest id mismatch: ' + id);
    }
    for (const field of ['version', 'apiVersion']) {
        if (!manifest[field]) {
            failures.push('manifest missing ' + field + ': ' + id);
        }
    }
    const entryFile = entry.entry?.file || manifest.entry?.file;
    if (!entryFile || !fs.existsSync(path.join(directory, entryFile))) {
        failures.push('missing entry file: ' + id);
    }
    for (const file of entry.files || []) {
        const name = typeof file === 'string' ? file : file.path;
        if (!name || !fs.existsSync(path.join(directory, name))) {
            failures.push('missing listed file: ' + id + '/' + name);
        }
    }
    if (!manifest.display?.name || !manifest.capabilities) {
        failures.push('manifest missing display/capabilities: ' + id);
    }
}
if (failures.length) {
    for (const failure of failures) {
        console.error('marketplace: ' + failure);
    }
    process.exit(1);
}
console.log('Plugin marketplace ok: ' + seen.size + ' plugin(s)');
