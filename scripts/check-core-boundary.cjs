#!/usr/bin/env node
'use strict';

/**
 * P0 core 边界扫描（report-only）。
 *
 * 目标：在迁移期持续量化 core 里还有多少平台协议代码/依赖/资产。
 * P0 只报告，不阻断；--enforce 时对 violations 返回 1（legacy 不计）。
 *
 * 用法：
 *   node scripts/check-core-boundary.cjs
 *   node scripts/check-core-boundary.cjs --json
 *   node scripts/check-core-boundary.cjs --enforce
 */

const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const args = new Set(process.argv.slice(2));
const json = args.has('--json');
const enforce = args.has('--enforce');

const configFile = path.join(root, 'docs/PLUGIN/config.json');
if (!fs.existsSync(configFile)) {
    console.log('Local plugin boundary config not found: docs/PLUGIN/config.json');
    console.log('This is expected on a clean checkout; core boundary checks are local-only in P0.');
    process.exit(0);
}
const config = JSON.parse(fs.readFileSync(configFile, 'utf8'));
const PROVIDER_IDS = config.providerIds || [];
const PROVIDER_PACKAGES = config.providerPackages || [];
const PROTOCOL_FILES = config.protocolFiles || [];
const LITERAL_ALLOW = (config.literalAllowPatterns || []).map((pattern) => new RegExp(pattern));
const LITERAL_LEGACY = (config.literalLegacyPatterns || []).map((pattern) => new RegExp(pattern));
const ASSET_DIRS = config.assetDirs || [];

const TEXT_EXTENSIONS = new Set(['.cjs', '.mjs', '.js', '.cpp', '.h', '.mm', '.json']);
const SKIP_DIRS = new Set([
    'node_modules',
    'output',
    '.git',
    'third_party',
    'vendor',
    'build',
    'PLUGIN',
    'local-plugins',
]);

function relative(file) {
    return path.relative(root, file).split(path.sep).join('/');
}

function readJson(file) {
    return JSON.parse(fs.readFileSync(path.join(root, file), 'utf8'));
}

function walk(dir, files = []) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        if (entry.name.startsWith('.') && entry.name !== '.github') {
            continue;
        }
        if (SKIP_DIRS.has(entry.name)) {
            continue;
        }
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            walk(full, files);
        } else if (TEXT_EXTENSIONS.has(path.extname(entry.name))) {
            files.push(full);
        }
    }
    return files;
}

function matchesAny(value, patterns) {
    return patterns.some((pattern) => pattern.test(value));
}

const report = {
    mode: enforce ? 'enforce' : 'report-only',
    generatedBy: 'scripts/check-core-boundary.cjs',
    dependencies: [],
    protocolFiles: [],
    literals: [],
    assets: [],
    summary: {
        violations: 0,
        legacy: 0,
        allowed: 0,
    },
};

// 1. core dependencies
const bridgePackage = readJson('MusicBridge/package.json');
for (const name of PROVIDER_PACKAGES) {
    if (bridgePackage.dependencies && bridgePackage.dependencies[name]) {
        report.dependencies.push({
            file: 'MusicBridge/package.json',
            package: name,
            version: bridgePackage.dependencies[name],
            severity: 'violation',
        });
    }
}

// 2. protocol files
for (const file of PROTOCOL_FILES) {
    if (fs.existsSync(path.join(root, file))) {
        report.protocolFiles.push({ file, severity: 'violation' });
    }
}

// 3. platform assets
for (const dir of ASSET_DIRS) {
    const full = path.join(root, dir);
    if (fs.existsSync(full)) {
        const files = fs.readdirSync(full);
        report.assets.push({
            file: dir,
            severity: 'legacy',
            note: '平台音质 badge 资产 ' + files.length + ' 个文件，目标迁入插件包',
        });
    }
}

// 4. provider literals in text sources
const literalPattern = PROVIDER_IDS.length ? new RegExp('"(' + PROVIDER_IDS.join('|') + ')"', 'g') : null;
for (const full of walk(root)) {
    const file = relative(full);
    if (file.startsWith('MusicBridge/plugins/') && !file.startsWith('MusicBridge/plugins/sdk/')) {
        continue;
    }
    const text = fs.readFileSync(full, 'utf8');
    const matches = literalPattern ? [...text.matchAll(literalPattern)] : [];
    if (!matches.length) {
        continue;
    }
    let severity = 'violation';
    if (matchesAny(file, LITERAL_ALLOW)) {
        severity = 'allowed';
    } else if (matchesAny(file, LITERAL_LEGACY)) {
        severity = 'legacy';
    }
    report.literals.push({
        file,
        count: matches.length,
        severity,
        samples: [...new Set(matches.map((match) => match[0]))].slice(0, 4),
    });
}

report.literals.sort((left, right) => right.count - left.count || left.file.localeCompare(right.file));

for (const entry of report.dependencies) {
    if (entry.severity === 'violation') {
        report.summary.violations += 1;
    }
}
report.summary.violations += report.protocolFiles.filter((entry) => entry.severity === 'violation').length;
for (const entry of report.literals) {
    if (entry.severity === 'violation') {
        report.summary.violations += 1;
    } else if (entry.severity === 'legacy') {
        report.summary.legacy += 1;
    } else {
        report.summary.allowed += 1;
    }
}

if (json) {
    process.stdout.write(JSON.stringify(report, null, 2) + '\n');
} else {
    console.log('Rhine core boundary report (' + report.mode + ')');
    console.log('');
    console.log('core dependencies');
    if (!report.dependencies.length) {
        console.log('  (none)');
    }
    for (const entry of report.dependencies) {
        console.log('  ' + entry.severity + ': ' + entry.package + '@' + entry.version + ' in ' + entry.file);
    }
    console.log('');
    console.log('protocol files in core');
    if (!report.protocolFiles.length) {
        console.log('  (none)');
    }
    for (const entry of report.protocolFiles) {
        console.log('  ' + entry.severity + ': ' + entry.file);
    }
    console.log('');
    console.log('platform assets');
    if (!report.assets.length) {
        console.log('  (none)');
    }
    for (const entry of report.assets) {
        console.log('  ' + entry.severity + ': ' + entry.file + ' — ' + entry.note);
    }
    console.log('');
    console.log('provider literals (top 40)');
    for (const entry of report.literals.slice(0, 40)) {
        console.log('  ' + entry.severity + ': ' + entry.count.toString().padStart(4) + '  ' + entry.file);
    }
    if (report.literals.length > 40) {
        console.log('  ... ' + (report.literals.length - 40) + ' more file(s)');
    }
    console.log('');
    console.log(
        'summary: violations=' +
            report.summary.violations +
            ' legacy=' +
            report.summary.legacy +
            ' allowed=' +
            report.summary.allowed,
    );
    console.log('P0 is report-only; use --enforce to fail on violations.');
}

if (enforce && report.summary.violations > 0) {
    process.exitCode = 1;
}
