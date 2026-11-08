// 从各插件的 manifest 提取 Qt 需要的纯数据 descriptor；不复制入口、签名或凭据配置。
const fs = require('node:fs');
const path = require('node:path');

const source = path.resolve(process.argv[2] || 'MusicBridge/local-plugins');
const output = path.resolve(process.argv[3] || 'output/resources/MusicBridge/plugins/descriptors');
const fields = [
    'schemaVersion',
    'id',
    'display',
    'capabilities',
    'library',
    'quality',
    'login',
    'discover',
    'lyrics',
    'media',
    'links',
    'strings',
    'search',
];

fs.mkdirSync(output, { recursive: true });
let count = 0;
if (fs.existsSync(source)) {
    for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
        if (!entry.isDirectory()) {
            continue;
        }
        const manifestFile = path.join(source, entry.name, 'manifest.json');
        if (!fs.existsSync(manifestFile)) {
            continue;
        }
        const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
        if (!manifest.id) {
            throw new Error('Plugin manifest is missing id: ' + manifestFile);
        }
        const descriptor = {};
        for (const field of fields) {
            if (manifest[field] !== undefined) {
                descriptor[field] = manifest[field];
            }
        }
        descriptor.schemaVersion ??= 1;
        fs.writeFileSync(
            path.join(output, manifest.id + '.json'),
            JSON.stringify(descriptor, null, 4) + '\n',
        );
        count++;
    }
}
console.log(`Exported ${count} plugin descriptor(s) to ${path.relative(process.cwd(), output)}`);
