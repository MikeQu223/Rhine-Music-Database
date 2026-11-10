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
const routeOwners = new Map();
for (const entry of index.plugins || []) {
    const id = String(entry.id || '');
    if (!/^[a-z0-9-]{1,40}$/.test(id) || seen.has(id)) {
        failures.push('invalid or duplicate plugin id: ' + id);
        continue;
    }
    if (id === 'local' || id === 'siren') {
        failures.push('reserved plugin id: ' + id);
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
    if (manifest.schemaVersion !== 2) {
        failures.push('manifest schemaVersion must be 2: ' + id);
    }
    if (!/^2\.[0-9]+$/.test(String(manifest.apiVersion || ''))) {
        failures.push('manifest apiVersion must be 2.x: ' + id);
    }
    for (const field of ['version', 'apiVersion']) {
        if (!manifest[field]) {
            failures.push('manifest missing ' + field + ': ' + id);
        }
    }
    for (const [key, overlap] of [
        ['legacyRoutes', false],
        ['prefixes', true],
    ]) {
        const routes = manifest.routes?.[key] || [];
        if (!Array.isArray(routes)) {
            failures.push('manifest routes.' + key + ' must be an array: ' + id);
            continue;
        }
        for (const route of routes) {
            if (typeof route !== 'string' || !route.startsWith('/')) {
                failures.push('invalid route ' + route + ' in ' + id);
                continue;
            }
            for (const [owner, ownerRoutes] of routeOwners) {
                for (const existing of ownerRoutes) {
                    if (
                        existing === route ||
                        (overlap && (existing.startsWith(route + '/') || route.startsWith(existing + '/')))
                    ) {
                        failures.push('route conflict ' + route + ' between ' + id + ' and ' + owner);
                    }
                }
            }
            if (!routeOwners.has(id)) {
                routeOwners.set(id, []);
            }
            routeOwners.get(id).push(route);
        }
    }
    const entryFile = entry.entry?.file || manifest.entry?.file;
    if (!entryFile || !fs.existsSync(path.join(directory, entryFile))) {
        failures.push('missing entry file: ' + id);
    }
    const listed = new Set(['manifest.json', entryFile]);
    for (const file of entry.files || []) {
        const name = typeof file === 'string' ? file : file.path;
        if (!name || !fs.existsSync(path.join(directory, name))) {
            failures.push('missing listed file: ' + id + '/' + name);
        } else {
            listed.add(name);
        }
    }
    const walk = (current, prefix = '') => {
        for (const item of fs.readdirSync(current, { withFileTypes: true })) {
            if (item.name === '.DS_Store' || item.name === '.git' || item.name === 'node_modules') {
                continue;
            }
            const name = prefix ? prefix + '/' + item.name : item.name;
            if (item.isDirectory()) {
                walk(path.join(current, item.name), name);
            } else if (item.isFile() && !listed.has(name)) {
                failures.push('unlisted runtime file: ' + id + '/' + name);
            }
        }
    };
    walk(directory);
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
