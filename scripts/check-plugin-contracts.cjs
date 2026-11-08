#!/usr/bin/env node
'use strict';

/**
 * P0 契约自检（report-only）。
 *
 * 校验：
 * - descriptor JSON 的基本形状、唯一 id、必填展示/能力字段
 * - fixture 的基本格式，并用 models.cjs 校验 response.body.value
 * - coverage.json 覆盖全部 operation
 *
 * 用法：
 *   node scripts/check-plugin-contracts.cjs
 *   node scripts/check-plugin-contracts.cjs --json
 *   node scripts/check-plugin-contracts.cjs --enforce
 */

const fs = require('node:fs');
const path = require('node:path');
const models = require('../MusicBridge/plugins/sdk/models.cjs');

const root = path.resolve(__dirname, '..');
const localBaseline = path.join(root, 'docs/PLUGIN');
const descriptorDir = path.join(localBaseline, 'descriptors');
const fixtureDir = path.join(localBaseline, 'fixtures');
const args = new Set(process.argv.slice(2));
const json = args.has('--json');
const enforce = args.has('--enforce');

if (!fs.existsSync(descriptorDir) || !fs.existsSync(fixtureDir)) {
    console.log('Local plugin baseline not found: docs/PLUGIN (gitignored).');
    console.log('P0 checks are local-only; nothing to validate on a clean checkout.');
    process.exit(0);
}

const OPERATIONS = [
    'mv',
    'mvVersions',
    'request',
    'search',
    'songs',
    'detail',
    'artistAlbums',
    'wiki',
    'account',
    'userPlaylists',
    'likedIDs',
    'likedSongs',
    'likedAlbums',
    'playback',
    'preview',
    'trackPage',
    'catalog',
    'discover',
    'categories',
    'lyrics',
    'mutate',
    'subscriptionStatus',
    'capabilities',
    'vip',
    'suggest',
    'resolveLink',
    'login',
];

const problems = [];
const notes = [];

function problem(scope, message) {
    problems.push({ scope, message });
}

function note(scope, message) {
    notes.push({ scope, message });
}

function readJson(file) {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function validateDescriptor(descriptor, file) {
    if (descriptor.schemaVersion !== 1) {
        problem(file, 'schemaVersion must be 1');
    }
    if (!/^[a-z0-9-]{1,40}$/.test(descriptor.id || '')) {
        problem(file, 'invalid id');
    }
    if (!descriptor.display || !descriptor.display.name || !descriptor.display.label) {
        problem(file, 'display.name/label required');
    }
    if (!descriptor.capabilities || typeof descriptor.capabilities !== 'object') {
        problem(file, 'capabilities required');
    }
    if (descriptor.operations !== undefined) {
        if (
            !descriptor.operations ||
            typeof descriptor.operations !== 'object' ||
            Array.isArray(descriptor.operations)
        ) {
            problem(file, 'operations must be an object');
        } else {
            for (const [name, enabled] of Object.entries(descriptor.operations)) {
                if (typeof enabled !== 'boolean') {
                    problem(file, 'operations.' + name + ' must be boolean');
                }
            }
        }
    }
    if (descriptor.quality) {
        if (!Array.isArray(descriptor.quality.options) || !descriptor.quality.options.length) {
            problem(file, 'quality.options must be a non-empty array');
        } else {
            const ids = new Set();
            for (const option of descriptor.quality.options) {
                if (!option.id || !option.label || !option.tier) {
                    problem(file, 'quality option requires id/label/tier');
                }
                if (ids.has(option.id)) {
                    problem(file, 'duplicate quality option id: ' + option.id);
                }
                ids.add(option.id);
            }
            if (!ids.has(descriptor.quality.default)) {
                problem(file, 'quality.default not in options: ' + descriptor.quality.default);
            }
        }
    }
    if (descriptor.library) {
        if (descriptor.library.columns && !Array.isArray(descriptor.library.columns)) {
            problem(file, 'library.columns must be an array');
        }
        if (descriptor.library.sourceOrder && !Array.isArray(descriptor.library.sourceOrder)) {
            problem(file, 'library.sourceOrder must be an array');
        }
    }
    if (descriptor.discover && descriptor.discover.enabled) {
        if (!Array.isArray(descriptor.discover.tabs) || !descriptor.discover.tabs.length) {
            problem(file, 'discover.enabled requires tabs');
        }
    }
}

function validateFixture(fixture, file) {
    if (fixture.schemaVersion !== 1) {
        problem(file, 'schemaVersion must be 1');
    }
    if (!fixture.provider || !fixture.operation) {
        problem(file, 'provider/operation required');
    }
    if (!Array.isArray(fixture.args)) {
        problem(file, 'args must be an array');
    }
    if (!fixture.response || !('body' in fixture.response)) {
        problem(file, 'response.body required');
        return;
    }
    const body = fixture.response.body;
    if (!body || typeof body !== 'object' || body.code !== 200) {
        note(file, 'fixture body is not a success envelope; skipping model validation');
        return;
    }
    if (fixture.operation.startsWith('route:')) {
        return;
    }
    try {
        models.validate(fixture.operation, body.value);
    } catch (error) {
        problem(file, 'model validation failed: ' + error.message);
    }
}

const descriptors = {};
for (const name of fs.readdirSync(descriptorDir).filter((entry) => entry.endsWith('.json'))) {
    const file = path.join('MusicBridge/plugins/sdk/descriptors', name);
    const descriptor = readJson(path.join(descriptorDir, name));
    if (descriptors[descriptor.id]) {
        problem(file, 'duplicate descriptor id: ' + descriptor.id);
    }
    descriptors[descriptor.id] = descriptor;
    validateDescriptor(descriptor, file);
}

let fixtureCount = 0;
for (const provider of fs.readdirSync(fixtureDir)) {
    const directory = path.join(fixtureDir, provider);
    if (!fs.statSync(directory).isDirectory()) {
        continue;
    }
    for (const name of fs.readdirSync(directory).filter((entry) => entry.endsWith('.json'))) {
        fixtureCount += 1;
        const file = path.join('docs/PLUGIN/fixtures', provider, name);
        validateFixture(readJson(path.join(directory, name)), file);
    }
}

const coverage = readJson(path.join(fixtureDir, 'coverage.json'));
for (const operation of OPERATIONS) {
    if (!coverage.operations || !coverage.operations[operation]) {
        problem('fixtures/coverage.json', 'missing operation: ' + operation);
    }
}

function supportsOperation(descriptor, operation) {
    if (operation === 'login') {
        return descriptor.capabilities?.login === true;
    }
    if (operation === 'suggest') {
        return descriptor.capabilities?.suggest === true;
    }
    if (operation === 'resolveLink') {
        return descriptor.capabilities?.resolveLink === true;
    }
    return descriptor.operations?.[operation] === true;
}

let covered = 0;
let notApplicable = 0;
for (const [providerId, descriptor] of Object.entries(descriptors)) {
    const directory = path.join(fixtureDir, providerId);
    const files = fs.existsSync(directory)
        ? fs.readdirSync(directory).filter((name) => name.endsWith('.json'))
        : [];
    for (const operation of OPERATIONS) {
        const status = coverage.operations?.[operation]?.[providerId];
        const supported = supportsOperation(descriptor, operation);
        if (supported) {
            if (status !== 'covered') {
                problem('coverage:' + providerId + ':' + operation, 'expected covered, got ' + status);
            }
            const hasFixture = files.some(
                (name) => name === operation + '.json' || name.startsWith(operation + '.'),
            );
            if (!hasFixture) {
                problem('coverage:' + providerId + ':' + operation, 'missing fixture file');
            } else {
                covered += 1;
            }
        } else {
            if (status !== 'n/a') {
                problem('coverage:' + providerId + ':' + operation, 'expected n/a, got ' + status);
            } else {
                notApplicable += 1;
            }
        }
    }
}

const summary = {
    descriptors: Object.keys(descriptors).length,
    fixtures: fixtureCount,
    operations: OPERATIONS.length,
    covered,
    notApplicable,
    problems: problems.length,
    notes: notes.length,
};

if (json) {
    process.stdout.write(JSON.stringify({ summary, problems, notes }, null, 2) + '\n');
} else {
    console.log('Rhine plugin contract self-check (' + (enforce ? 'enforce' : 'report-only') + ')');
    console.log(
        'descriptors=' +
            summary.descriptors +
            ' fixtures=' +
            summary.fixtures +
            ' operations=' +
            summary.operations,
    );
    console.log('coverage: covered=' + summary.covered + ' n/a=' + summary.notApplicable);
    for (const entry of problems) {
        console.log('  problem: ' + entry.scope + ': ' + entry.message);
    }
    for (const entry of notes) {
        console.log('  note: ' + entry.scope + ': ' + entry.message);
    }
    console.log('problems=' + summary.problems + ' notes=' + summary.notes);
    console.log('P0 is report-only; use --enforce to fail on problems.');
}

if (enforce && problems.length > 0) {
    process.exitCode = 1;
}
