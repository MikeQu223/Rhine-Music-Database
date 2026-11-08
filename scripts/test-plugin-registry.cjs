const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { PluginRegistry } = require('../MusicBridge/core/registry.cjs');

const DEFAULT_ENTRY = `module.exports = {
    create(host) {
        globalThis.__registryCreateCalls = (globalThis.__registryCreateCalls || 0) + 1;
        return {
            host,
            dispatchNative: async (operation) => ({ operation, provider: host.manifest.id }),
            dispatchRoute: async (route) => ({ route }),
        };
    },
};`;

function manifest(id, routes = {}, extra = {}) {
    return {
        schemaVersion: 1,
        apiVersion: '1.0',
        id,
        version: '1.0.0',
        entry: { file: 'entry.cjs' },
        routes,
        ...extra,
    };
}

function createRegistry(t, plugins, options) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rhine-registry-'));
    for (const [name, plugin] of Object.entries(plugins)) {
        const directory = path.join(root, name);
        fs.mkdirSync(directory, { recursive: true });
        const value = plugin.manifest;
        fs.writeFileSync(
            path.join(directory, 'manifest.json'),
            typeof value === 'string' ? value : JSON.stringify(value),
        );
        if (plugin.entry !== null) {
            fs.writeFileSync(path.join(directory, 'entry.cjs'), plugin.entry ?? DEFAULT_ENTRY);
        }
    }
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    return new PluginRegistry(root, options);
}

test('discovers manifests and resolves legacy, prefix and status lookups', (t) => {
    const registry = createRegistry(t, {
        first: { manifest: manifest('first', { legacyRoutes: ['/alpha'], prefixes: ['/first'] }) },
        second: { manifest: manifest('second', { legacyRoutes: ['/beta'], prefixes: ['/second'] }) },
    });
    assert.deepEqual(
        registry.list().map((entry) => entry.id),
        ['first', 'second'],
    );
    assert.equal(registry.has('first'), true);
    assert.equal(registry.has('missing'), false);
    assert.equal(registry.status('first'), 'bundled');
    assert.equal(registry.status('missing'), 'missing');
    assert.equal(registry.legacyProvider('/alpha'), 'first');
    assert.equal(registry.legacyProvider('/nope'), null);
    assert.deepEqual(registry.prefixProvider('/first/song/url'), {
        provider: 'first',
        route: '/song/url',
    });
    assert.deepEqual(registry.prefixProvider('/second'), { provider: 'second', route: '/' });
    assert.equal(registry.prefixProvider('/firstly'), null);
    assert.deepEqual(registry.getProblems(), []);
});

test('resolves default and capability only when unambiguous', (t) => {
    const registry = createRegistry(t, {
        alpha: {
            manifest: manifest(
                'alpha',
                {},
                {
                    display: { default: true },
                    operations: { search: true },
                    capabilities: { playback: true },
                },
            ),
        },
        beta: { manifest: manifest('beta') },
    });
    assert.equal(registry.default(), 'alpha');
    assert.equal(registry.can('alpha', 'search'), true);
    assert.equal(registry.can('alpha', 'playback'), true);
    assert.equal(registry.can('alpha', 'mutate'), false);
    assert.equal(registry.can('missing', 'search'), false);
});

test('returns no default when none or several plugins claim it', (t) => {
    const none = createRegistry(t, { plugin: { manifest: manifest('plugin') } });
    assert.equal(none.default(), null);
    const several = createRegistry(t, {
        first: { manifest: manifest('first', {}, { display: { default: true } }) },
        second: { manifest: manifest('second', {}, { display: { default: true } }) },
    });
    assert.equal(several.default(), null);
});

test('user plugin root overrides bundled plugins with the same id', (t) => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rhine-registry-'));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    const write = (directory, version) => {
        fs.mkdirSync(directory, { recursive: true });
        fs.writeFileSync(
            path.join(directory, 'manifest.json'),
            JSON.stringify(manifest('plugin', { legacyRoutes: ['/search'] }, { version })),
        );
        fs.writeFileSync(path.join(directory, 'entry.cjs'), DEFAULT_ENTRY);
    };
    const bundled = path.join(root, 'bundled');
    const user = path.join(root, 'user');
    write(path.join(bundled, 'plugin'), '1.0.0');
    write(path.join(user, 'plugin'), '2.0.0');
    const registry = new PluginRegistry(bundled, { userRoot: user });
    assert.equal(registry.list()[0].version, '2.0.0');
    assert.equal(registry.legacyProvider('/search'), 'plugin');
});

test('skips disabled plugins', (t) => {
    const registry = createRegistry(
        t,
        { plugin: { manifest: manifest('plugin', { legacyRoutes: ['/search'] }) } },
        { disabled: ['plugin'] },
    );
    assert.deepEqual(registry.list(), []);
    assert.equal(registry.has('plugin'), false);
    assert.equal(registry.legacyProvider('/search'), null);
});

test('ignores staging and backup directories', (t) => {
    const registry = createRegistry(t, {
        '.staging-plugin': { manifest: manifest('plugin', { legacyRoutes: ['/one'] }) },
        '.backup-plugin': { manifest: manifest('plugin', { legacyRoutes: ['/two'] }) },
        plugin: { manifest: manifest('plugin', { legacyRoutes: ['/three'] }) },
    });
    assert.deepEqual(
        registry.list().map((entry) => entry.id),
        ['plugin'],
    );
    assert.equal(registry.legacyProvider('/three'), 'plugin');
    assert.deepEqual(registry.getProblems(), []);
});

test('rejects duplicate provider ids', (t) => {
    const registry = createRegistry(t, {
        first: { manifest: manifest('duplicate', { legacyRoutes: ['/one'] }) },
        second: { manifest: manifest('duplicate', { legacyRoutes: ['/two'] }) },
    });
    assert.deepEqual(
        registry.list().map((entry) => entry.id),
        ['duplicate'],
    );
    assert.equal(registry.legacyProvider('/one'), 'duplicate');
    assert.equal(registry.legacyProvider('/two'), null);
    assert.deepEqual(
        registry.getProblems().map(({ directory, code }) => ({ directory, code })),
        [{ directory: 'second', code: 'plugin.conflict' }],
    );
});

test('rejects duplicate and overlapping routes', (t) => {
    const registry = createRegistry(t, {
        first: {
            manifest: manifest('first', { legacyRoutes: ['/search'], prefixes: ['/qq'] }),
        },
        legacy: { manifest: manifest('legacy', { legacyRoutes: ['/search'] }) },
        prefix: { manifest: manifest('prefix', { prefixes: ['/qq'] }) },
        nested: { manifest: manifest('nested', { prefixes: ['/qq/extra'] }) },
    });
    assert.deepEqual(
        registry.list().map((entry) => entry.id),
        ['first'],
    );
    assert.deepEqual(
        registry.getProblems().map(({ directory, code }) => ({ directory, code })),
        [
            { directory: 'legacy', code: 'route.duplicate' },
            { directory: 'nested', code: 'route.duplicate' },
            { directory: 'prefix', code: 'route.duplicate' },
        ],
    );
});

test('rejects incompatible schema and api versions', (t) => {
    const registry = createRegistry(t, {
        current: { manifest: manifest('current') },
        'newer-minor': { manifest: manifest('newer-minor', {}, { apiVersion: '1.1' }) },
        'newer-major': { manifest: manifest('newer-major', {}, { apiVersion: '2.0' }) },
        'old-schema': { manifest: manifest('old-schema', {}, { schemaVersion: 2 }) },
    });
    assert.deepEqual(
        registry.list().map((entry) => entry.id),
        ['current'],
    );
    assert.deepEqual(
        registry.getProblems().map(({ code }) => code),
        ['plugin.incompatible', 'plugin.incompatible', 'plugin.incompatible'],
    );
});

test('rejects malformed manifests without blocking valid plugins', (t) => {
    const registry = createRegistry(t, {
        'broken-json': { manifest: '{' },
        'missing-id': { manifest: manifest(undefined) },
        'missing-entry': { manifest: { ...manifest('missing-entry'), entry: undefined } },
        'bad-routes': { manifest: manifest('bad-routes', { prefixes: '/bad' }) },
        valid: { manifest: manifest('valid') },
    });
    assert.deepEqual(
        registry.list().map((entry) => entry.id),
        ['valid'],
    );
    assert.deepEqual(
        registry.getProblems().map(({ code }) => code),
        ['manifest.invalid', 'manifest.invalid', 'manifest.invalid', 'manifest.invalid'],
    );
});

test('loads each request with the current host and a fresh adapter', async (t) => {
    globalThis.__registryCreateCalls = 0;
    const registry = createRegistry(t, { plugin: { manifest: manifest('plugin') } });
    const first = { tag: 'first' };
    const second = { tag: 'second' };
    const firstAdapter = await registry.load('plugin', first);
    const secondAdapter = await registry.load('plugin', second);
    assert.notEqual(firstAdapter, secondAdapter);
    assert.equal(globalThis.__registryCreateCalls, 2);
    assert.equal(firstAdapter.host, first);
    assert.equal(secondAdapter.host, second);
    assert.equal(first.manifest.id, 'plugin');
    assert.equal(second.manifest.id, 'plugin');
    assert.equal(await registry.load('missing', first), null);
});

test('dispatches existing plugins and reports missing ones', async (t) => {
    const registry = createRegistry(t, { plugin: { manifest: manifest('plugin') } });
    const host = {};
    assert.deepEqual(await registry.dispatchNative('plugin', 'search', [], host), {
        operation: 'search',
        provider: 'plugin',
    });
    assert.deepEqual(await registry.dispatchRoute('plugin', '/search', {}, host), {
        route: '/search',
    });
    for (const call of [
        () => registry.dispatchNative('missing', 'search', [], {}),
        () => registry.dispatchRoute('missing', '/search', {}, {}),
    ]) {
        await assert.rejects(call, (error) => error.code === 404 && error.errorKey === 'plugin.missing');
    }
});

test('reports broken entries as plugin.load-failed', async (t) => {
    const registry = createRegistry(t, {
        'no-create': { manifest: manifest('no-create'), entry: 'module.exports = {};' },
        'missing-file': {
            manifest: manifest('missing-file'),
            entry: null,
        },
        throws: {
            manifest: manifest('throws'),
            entry: 'module.exports = { create() { throw new Error("boom"); } };',
        },
    });
    for (const id of ['no-create', 'missing-file', 'throws']) {
        await assert.rejects(
            () => registry.load(id, {}),
            (error) => error.code === 503 && error.errorKey === 'plugin.load-failed',
        );
    }
});
