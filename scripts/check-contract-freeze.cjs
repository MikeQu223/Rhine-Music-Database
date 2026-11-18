#!/usr/bin/env node
'use strict';

/**
 * 契约冻结检查。
 *
 * 主仓库的通用插件契约一旦冻结，任何改动都必须显式更新 contract-lock.json，
 * 并按版本策略处理（同 major 只加字段；破坏性改动 bump apiVersion/schemaVersion）。
 *
 * 用法：
 *   node scripts/check-contract-freeze.cjs
 *   node scripts/check-contract-freeze.cjs --json
 *   node scripts/check-contract-freeze.cjs --write   # 仅在有意变更契约后运行
 */

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const root = path.resolve(__dirname, '..');
const lockPath = path.join(root, 'MusicBridge/plugins/sdk/contract-lock.json');
const args = new Set(process.argv.slice(2));
const json = args.has('--json');
const write = args.has('--write');

const CONTRACT_FILES = [
    'MusicBridge/plugins/sdk/port.d.ts',
    'MusicBridge/plugins/sdk/registry.d.ts',
    'MusicBridge/plugins/sdk/manifest.schema.json',
    'MusicBridge/plugins/sdk/descriptor.schema.json',
    'MusicBridge/plugins/sdk/models.schema.json',
    'MusicBridge/plugins/sdk/models.cjs',
    'MusicBridge/plugins/sdk/base-api.mjs',
    'MusicBridge/plugins/sdk/failure.mjs',
    'MusicBridge/plugins/sdk/fixtures/fixture.schema.json',
];

function hash(file) {
    return crypto
        .createHash('sha256')
        .update(fs.readFileSync(path.join(root, file)))
        .digest('hex');
}

if (write) {
    const lock = {
        schemaVersion: 2,
        apiVersion: '2.0',
        frozenAt: '2026-11-09',
        note: 'Any contract change must update this file and follow the version policy in docs/PLUGIN/P0-FREEZE.md.',
        files: Object.fromEntries(CONTRACT_FILES.map((file) => [file, hash(file)])),
    };
    fs.writeFileSync(lockPath, JSON.stringify(lock, null, 4) + '\n');
    console.log('contract lock written: MusicBridge/plugins/sdk/contract-lock.json');
    process.exit(0);
}

if (!fs.existsSync(lockPath)) {
    console.error('contract lock missing: MusicBridge/plugins/sdk/contract-lock.json');
    console.error('Run node scripts/check-contract-freeze.cjs --write after freezing the contract.');
    process.exit(1);
}

const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
const problems = [];
for (const file of CONTRACT_FILES) {
    const expected = lock.files && lock.files[file];
    if (!expected) {
        problems.push({ file, expected: null, actual: hash(file), problem: 'missing from lock' });
        continue;
    }
    const actual = hash(file);
    if (actual !== expected) {
        problems.push({ file, expected, actual, problem: 'hash mismatch' });
    }
}
for (const file of Object.keys(lock.files || {})) {
    if (!CONTRACT_FILES.includes(file)) {
        problems.push({ file, expected: lock.files[file], actual: null, problem: 'stale lock entry' });
    }
}

const result = {
    schemaVersion: lock.schemaVersion,
    apiVersion: lock.apiVersion,
    frozenAt: lock.frozenAt,
    files: CONTRACT_FILES.length,
    problems,
};

if (json) {
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
} else if (problems.length === 0) {
    console.log(
        'contract freeze ok: schemaVersion=' +
            result.schemaVersion +
            ' apiVersion=' +
            result.apiVersion +
            ' files=' +
            result.files +
            ' frozenAt=' +
            result.frozenAt,
    );
} else {
    console.error('contract freeze check failed:');
    for (const entry of problems) {
        console.error('  ' + entry.problem + ': ' + entry.file);
        if (entry.expected) {
            console.error('    expected ' + entry.expected);
        }
        if (entry.actual) {
            console.error('    actual   ' + entry.actual);
        }
    }
    console.error('');
    console.error('If the change is intentional: bump apiVersion/schemaVersion as needed, add an ADR,');
    console.error('then run node scripts/check-contract-freeze.cjs --write.');
}

if (problems.length > 0) {
    process.exitCode = 1;
}
