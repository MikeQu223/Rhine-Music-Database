// 扫描 Qt 业务代码里残留的第三方平台 ID；P4 先报告，P5/P6 删除分支后转阻断。
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const sourceRoot = path.join(root, 'Qt/src');
const providers = ['netease', 'qq', 'kugou'];
const allow = [/^ProviderRegistry\.(cpp|h)$/, /^Host\.cpp$/, /^MusicApi\.cpp$/];
const legacy = [
    /^NativeHudModal\.cpp$/,
    /^NativeHud\.cpp$/,
    /^NativeHudDetail\.cpp$/,
    /^NativeHudLibrary\.cpp$/,
    /^NativeHudDiscover\.cpp$/,
    /^NativeHudSettings\.cpp$/,
    /^NativeHudMusic\.cpp$/,
    /^NativeHudController\.cpp$/,
    /^MusicAccount\.cpp$/,
    /^MusicLibrary\.cpp$/,
    /^MusicLocal\.cpp$/,
    /^MusicDiscover\.cpp$/,
    /^MusicPlayer\.cpp$/,
    /^MusicMutation\.cpp$/,
    /^LyricsController\.cpp$/,
    /^AudioPlayer\.cpp$/,
    /^MvController\.cpp$/,
    /^PlaybackQueue\.cpp$/,
    /^SettingsSchema\.cpp$/,
    /^PlaybackService\.cpp$/,
    /^MusicApi\.h$/,
    /^MusicData\.h$/,
    /^MusicDirectory\.cpp$/,
    /^ResponsiveHudPages\.cpp$/,
    /^Platform\.(mm|cpp)$/,
    /^PlatformIOS\.mm$/,
    /^PlatformWindows\.cpp$/,
    /^PlatformLinux\.cpp$/,
    /^PlatformAndroid\.cpp$/,
];

function walk(directory) {
    const result = [];
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        const full = path.join(directory, entry.name);
        if (entry.isDirectory()) {
            result.push(...walk(full));
        } else if (/\.(cpp|h|mm)$/.test(entry.name)) {
            result.push(full);
        }
    }
    return result;
}

function severity(name) {
    if (allow.some((pattern) => pattern.test(name))) {
        return 'allowed';
    }
    if (legacy.some((pattern) => pattern.test(name))) {
        return 'legacy';
    }
    return 'violation';
}

const findings = [];
for (const file of walk(sourceRoot)) {
    const name = path.relative(sourceRoot, file).split(path.sep).join('/');
    const text = fs.readFileSync(file, 'utf8');
    const counts = {};
    for (const provider of providers) {
        const count = (text.match(new RegExp(`"${provider}"`, 'g')) || []).length;
        if (count) {
            counts[provider] = count;
        }
    }
    if (Object.keys(counts).length) {
        findings.push({ file: name, counts, severity: severity(path.basename(name)) });
    }
}

const summary = { violations: 0, legacy: 0, allowed: 0 };
for (const finding of findings) {
    summary[finding.severity === 'violation' ? 'violations' : finding.severity] += 1;
}
const enforce = process.argv.includes('--enforce');
console.log('Rhine provider literal report (' + (enforce ? 'enforce' : 'report-only') + ')');
for (const finding of findings.sort((left, right) => left.file.localeCompare(right.file))) {
    console.log(
        `  ${finding.severity.padEnd(9)} ${finding.file}: ` +
            Object.entries(finding.counts)
                .map(([id, count]) => `${id}=${count}`)
                .join(' '),
    );
}
console.log(`summary: violations=${summary.violations} legacy=${summary.legacy} allowed=${summary.allowed}`);
if (enforce && summary.violations > 0) {
    process.exit(1);
}
