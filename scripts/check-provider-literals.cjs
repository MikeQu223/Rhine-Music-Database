// 扫描 Qt 业务代码里残留的第三方平台标识。平台 id/名称来自已安装插件 manifest，
// 因此 core-only 仓库本身不含平台名单；发布流水线通过 --plugins 指向插件 checkout。
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const sourceRoot = path.join(root, 'Qt/src');
const enforce = process.argv.includes('--enforce');

const pluginRoots = [];
for (let index = 2; index < process.argv.length; ++index) {
    if (process.argv[index] === '--plugins' && process.argv[index + 1]) {
        pluginRoots.push(path.resolve(process.argv[++index]));
    }
}
if (process.env.RHINE_PLUGIN_ROOTS) {
    pluginRoots.push(
        ...process.env.RHINE_PLUGIN_ROOTS.split(path.delimiter)
            .filter(Boolean)
            .map((value) => path.resolve(value)),
    );
}
if (!pluginRoots.length) {
    pluginRoots.push(path.join(root, 'MusicBridge/local-plugins'));
}

function walk(directory) {
    const result = [];
    if (!fs.existsSync(directory)) {
        return result;
    }
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        const full = path.join(directory, entry.name);
        if (entry.isDirectory()) {
            result.push(...walk(full));
        } else if (/\.(cpp|h|mm|json)$/.test(entry.name)) {
            result.push(full);
        }
    }
    return result;
}

const literals = new Set();
for (const pluginRoot of pluginRoots) {
    if (!fs.existsSync(pluginRoot)) {
        continue;
    }
    for (const entry of fs.readdirSync(pluginRoot, { withFileTypes: true })) {
        if (!entry.isDirectory()) {
            continue;
        }
        const manifestFile = path.join(pluginRoot, entry.name, 'manifest.json');
        if (!fs.existsSync(manifestFile)) {
            continue;
        }
        try {
            const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
            if (typeof manifest.id === 'string') {
                literals.add(manifest.id);
            }
            const name = manifest.display?.name;
            if (typeof name === 'string' && name.length > 1) {
                literals.add(name);
            }
        } catch {
            // 无法解析的插件不参与扫描；安装/校验阶段会单独报错。
        }
    }
}

if (!literals.size) {
    console.log('Rhine provider literal report: no plugin manifests found; nothing to scan');
    process.exit(0);
}

const patterns = [...literals].map((value) => ({
    value,
    pattern: new RegExp(value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g'),
}));
const findings = [];
const sourceRoots = [sourceRoot, path.join(root, 'MusicBridge/plugins/descriptors')];
for (const scanRoot of sourceRoots) {
    for (const file of walk(scanRoot)) {
        const name = path.relative(root, file).split(path.sep).join('/');
        const text = fs.readFileSync(file, 'utf8');
        const counts = {};
        for (const { value, pattern } of patterns) {
            const count = (text.match(pattern) || []).length;
            if (count) {
                counts[value] = count;
            }
        }
        if (Object.keys(counts).length) {
            findings.push({ file: name, counts });
        }
    }
}

console.log('Rhine provider literal report (' + (enforce ? 'enforce' : 'report-only') + ')');
for (const finding of findings.sort((left, right) => left.file.localeCompare(right.file))) {
    console.log(
        '  violation ' +
            finding.file +
            ': ' +
            Object.entries(finding.counts)
                .map(([id, count]) => `${id}=${count}`)
                .join(' '),
    );
}
console.log('summary: violations=' + findings.length);
if (enforce && findings.length > 0) {
    process.exit(1);
}
