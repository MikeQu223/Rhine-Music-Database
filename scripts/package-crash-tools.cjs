// 生成与当前二进制匹配的离线符号，并部署采集器、报告器、解析器及第三方许可证。
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { directory, manifest } = require('./prepare-crash-tools.cjs');

function findFile(folder, filename) {
    for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
        const file = path.join(folder, entry.name);
        if (entry.isDirectory()) {
            const found = findFile(file, filename);
            if (found) {
                return found;
            }
        } else if (entry.name === filename) {
            return file;
        }
    }
    return '';
}

/** 由上游工具合并同一构建的代码与调试信息，拒绝缺行号或展开信息的符号库。 */
function writeSymbols(tool, binary, debugFile, store, sourcePattern) {
    const args = ['--verbose', 'off', '--inlines', '--check-cfi', '--store', store];
    if (sourcePattern) {
        args.push('--mapping-src', sourcePattern, '--mapping-dest', '{1}');
    }
    execFileSync(tool, [...args, binary, debugFile], { stdio: 'inherit' });
    const modules = fs.readdirSync(store);
    if (modules.length !== 1) {
        throw new Error('Crash symbol module mismatch');
    }
    const modulePath = path.join(store, modules[0]);
    const builds = fs.readdirSync(modulePath);
    if (builds.length !== 1) {
        throw new Error('Crash symbol debug ID mismatch');
    }
    const symbolsPath = path.join(modulePath, builds[0]);
    const file = fs.readdirSync(symbolsPath).find((name) => name.endsWith('.sym'));
    const text = file ? fs.readFileSync(path.join(symbolsPath, file), 'utf8') : '';
    if (!/^FILE /m.test(text) || !/^FUNC /m.test(text) || !/^STACK (CFI|WIN)/m.test(text)) {
        throw new Error('Crash symbols require source lines, functions and unwind information');
    }
}

/** 缺工具或缺符号时使构建失败，避免发布只有地址、无法还原源码行的诊断功能。 */
function packageCrashTools(binary, handler, reporter, source, pdb, wer) {
    const destination = path.dirname(binary);
    const suffix = process.platform === 'win32' ? '.exe' : '';
    const platform = manifest.platforms[`${process.platform}-${process.arch}`];
    if (!platform) {
        throw new Error(`Crash tools unavailable for ${process.platform}-${process.arch}`);
    }
    const stackwalk = findFile(
        path.join(directory, `minidump-stackwalk-${manifest.stackwalkVersion}-${platform.target}`),
        `minidump-stackwalk${suffix}`,
    );
    const symbols = findFile(
        path.join(directory, `dump_syms-${manifest.symbolsVersion}-${platform.target}`),
        `dump_syms${suffix}`,
    );
    if (!stackwalk || !symbols) {
        throw new Error('Run node scripts/prepare-crash-tools.cjs before building');
    }
    const mac = process.platform === 'darwin';
    const tools = mac ? destination : path.join(destination, 'crash-tools');
    const licenses = mac
        ? path.resolve(destination, '../Resources/CrashDiagnostics-Licenses')
        : path.join(tools, 'licenses');
    if (mac) {
        // MacOS 目录只放可执行文件；符号和许可证必须放进 Resources，遵守签名布局。
        fs.rmSync(path.join(destination, 'crash-tools'), { recursive: true, force: true });
        fs.rmSync(path.join(destination, 'crash-symbols'), { recursive: true, force: true });
    }
    fs.mkdirSync(licenses, { recursive: true });
    fs.copyFileSync(stackwalk, path.join(tools, path.basename(stackwalk)));
    for (const executable of [handler, reporter]) {
        const target = path.join(destination, path.basename(executable));
        if (path.resolve(target) !== path.resolve(executable)) {
            fs.copyFileSync(executable, target);
        }
    }
    if (wer) {
        fs.copyFileSync(wer, path.join(destination, 'crashpad_wer.dll'));
    }
    for (const [name, folder] of [
        ['crashpad', source],
        ['mini_chromium', path.join(source, 'third_party/mini_chromium/mini_chromium')],
        ['mpack', path.join(source, 'third_party/mpack')],
        ['zlib', path.join(source, 'third_party/zlib/zlib')],
        ['minidump-stackwalk', path.dirname(stackwalk)],
        ['dump_syms', path.dirname(symbols)],
    ]) {
        for (const file of fs.readdirSync(folder).filter((file) => /^(LICENSE|COPYING|NOTICE)/.test(file))) {
            if (fs.statSync(path.join(folder, file)).isFile()) {
                fs.copyFileSync(path.join(folder, file), path.join(licenses, `${name}-${file}`));
            }
        }
    }
    let input = pdb;
    if (process.platform === 'darwin') {
        const dsym = path.join(
            path.resolve(__dirname, '../output/crash-symbol-archives'),
            `${path.basename(binary)}.dSYM`,
        );
        fs.mkdirSync(path.dirname(dsym), { recursive: true });
        fs.rmSync(`${binary}.dSYM`, { recursive: true, force: true });
        execFileSync('dsymutil', [binary, '-o', dsym], { stdio: 'inherit' });
        input = path.join(dsym, 'Contents/Resources/DWARF', path.basename(binary));
    }
    if (!input || !fs.existsSync(input)) {
        throw new Error('Native crash reports require matching dSYM/PDB debug information');
    }
    const store = mac
        ? path.resolve(destination, '../Resources/crash-symbols')
        : path.join(destination, 'crash-symbols');
    fs.rmSync(store, { recursive: true, force: true });
    fs.mkdirSync(store, { recursive: true });
    const sourceRoot = path.resolve(__dirname, '..').replaceAll('\\', '/');
    const sourcePattern = sourceRoot.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '/(.*)';
    writeSymbols(symbols, binary, input, store, sourcePattern);
}

if (require.main === module) {
    packageCrashTools(...process.argv.slice(2));
}
module.exports = { packageCrashTools, writeSymbols };
