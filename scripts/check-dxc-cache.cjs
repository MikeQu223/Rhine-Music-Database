// Exercise real CMake consumers against the staged, source-built Windows toolchain.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const cache = fs.readFileSync(path.join(root, 'output/qt-build/CMakeCache.txt'), 'utf8');
if (!/^RHINE_ENABLE_D3D12_BACKEND:BOOL=ON$/m.test(cache)) {
    console.log('DXC cache checks skipped: D3D12 is disabled');
    process.exit(0);
}
const source = /^RHINE_DXC_SOURCE_DIR:PATH=(.*)$/m.exec(cache)?.[1].trim();
assert(source, 'DXC source path is missing from the application configuration');
const hostPython = /^RHINE_DXC_PYTHON_EXECUTABLE:FILEPATH=(.*)$/m.exec(cache)?.[1].trim();
const staged = path.join(root, 'generated/dxc');
const signature = fs.readFileSync(path.join(staged, 'dxc-source-revision.txt'), 'utf8');
assert.equal(
    fs.readFileSync(path.join(root, 'output/qt-build/rhine-dxc-signature.txt'), 'utf8'),
    signature,
    'Application and staged DXC signatures differ',
);
const bootstrapSignature = path.join(root, 'output/dxc-bootstrap/rhine-dxc-signature.txt');
if (fs.existsSync(bootstrapSignature)) {
    assert.equal(
        fs.readFileSync(bootstrapSignature, 'utf8'),
        signature,
        'Bootstrap and application must reuse the same DXC recipe',
    );
}
for (const file of ['dxc.exe', 'dxcompiler.dll', 'dxil.dll']) {
    assert(fs.statSync(path.join(staged, 'bin', file)).size > 0, `Staged tool is empty: ${file}`);
}
const output = path.join(root, 'output');
const temp = fs.mkdtempSync(path.join(output, 'dxc-cache-check-'));
assert.equal(path.dirname(temp), output);
function run(args, env = process.env) {
    const result = spawnSync('cmake', args, { cwd: root, encoding: 'utf8', env });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    return result.stdout;
}
function configure(name, extra = [], env = process.env) {
    return run(
        [
            '-S',
            'cmake/dxc-bootstrap',
            '-B',
            path.join(temp, name),
            '-G',
            'Ninja',
            '-DCMAKE_BUILD_TYPE=Debug',
            `-DRHINE_DXC_SOURCE_DIR=${source}`,
            ...(hostPython && !env.RHINE_DXC_PYTHON_EXECUTABLE
                ? [`-DRHINE_DXC_PYTHON_EXECUTABLE=${hostPython}`]
                : []),
            ...extra,
        ],
        env,
    );
}
try {
    const started = performance.now();
    const reused = configure('reuse');
    assert.match(reused, /DXC: 复用/);
    const commands = run(['--build', path.join(temp, 'reuse'), '--target', 'rhine_dxc']);
    assert.match(commands, /no work to do/);
    console.log(
        `DXC cache reused in a new Debug consumer: ${((performance.now() - started) / 1000).toFixed(2)}s`,
    );
    assert(hostPython, 'DXC host interpreter must be recorded in the application cache');
    const foreignPython = configure(
        'foreign-python',
        [`-DPython3_EXECUTABLE=${path.join(temp, 'application-python-do-not-use.exe')}`],
        {
            ...process.env,
            RHINE_DXC_PYTHON_EXECUTABLE: hostPython,
            pythonLocation: path.join(temp, 'qt-installed-another-python'),
        },
    );
    assert.match(foreignPython, /DXC: 复用/);
    assert.match(
        run(['--build', path.join(temp, 'foreign-python'), '--target', 'rhine_dxc']),
        /no work to do/,
    );
    console.log('DXC cache reused with an unrelated application Python selection');
    for (const scenario of ['missing-dll', 'wrong-signature']) {
        const fixture = path.join(temp, scenario, 'staged');
        fs.mkdirSync(path.join(fixture, 'bin'), { recursive: true });
        for (const name of ['dxc.exe', 'dxcompiler.dll', 'dxil.dll']) {
            if (scenario === 'missing-dll' && name === 'dxil.dll') {
                continue;
            }
            fs.writeFileSync(path.join(fixture, 'bin', name), 'fixture');
        }
        const marker = path.join(fixture, 'dxc-source-revision.txt');
        fs.writeFileSync(marker, scenario === 'wrong-signature' ? 'invalid signature' : signature);
        const text = configure(scenario, [
            `-DRHINE_DXC_OUTPUT_DIR=${path.join(fixture, 'bin')}`,
            `-DRHINE_DXC_REVISION_FILE=${marker}`,
        ]);
        assert.doesNotMatch(text, /DXC: 复用/);
        console.log(`DXC incomplete/stale cache rejected: ${scenario}`);
    }
} finally {
    assert.equal(path.dirname(temp), output);
    fs.rmSync(temp, { recursive: true, force: true });
}
