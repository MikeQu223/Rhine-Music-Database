// core-only 发布包检查：不含第三方插件目录、上游协议文件或 provider npm 包。
const fs = require('node:fs');
const path = require('node:path');
const { app, resourceDirectory } = require('./app-layout.cjs');

const bridge = path.resolve(process.argv[2] || path.join(app, resourceDirectory, 'MusicBridge'));
const failures = [];
const check = (condition, message) => {
    if (!condition) {
        failures.push(message);
    }
};

check(fs.existsSync(path.join(bridge, 'worker.cjs')), 'worker.cjs missing');
check(!fs.existsSync(path.join(bridge, 'local-plugins')), 'local-plugins directory must be absent');
check(!fs.existsSync(path.join(bridge, 'node_modules')), 'node_modules must be absent');
check(!fs.existsSync(path.join(bridge, 'upstream')), 'upstream directory must be absent');

const descriptors = path.join(bridge, 'plugins/descriptors');
if (fs.existsSync(descriptors)) {
    const ids = fs
        .readdirSync(descriptors)
        .filter((name) => name.endsWith('.json'))
        .map((name) => name.slice(0, -5))
        .sort();
    check(
        ids.every((id) => id === 'local' || id === 'siren'),
        'core-only descriptors must only contain local/siren: ' + ids.join(','),
    );
} else {
    failures.push('plugins/descriptors missing');
}

if (failures.length) {
    for (const failure of failures) {
        console.error('core-only package failed: ' + failure);
    }
    process.exit(1);
}
console.log('Core-only package contains no provider plugins or protocol files');
