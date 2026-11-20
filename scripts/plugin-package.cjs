#!/usr/bin/env node
'use strict';

const { isBuiltin } = require('node:module');
const path = require('node:path');
const { parseArgs } = require('node:util');
const {
    installPackage,
    packPlugin,
    rollbackPackage,
    verifyPackage,
} = require('../MusicBridge/plugin-package.cjs');
const { createHostContext } = require('../MusicBridge/plugins/sdk/compatibility.cjs');

/** 静态解析入口依赖图，防止解析到开发机上未随包交付的依赖。 */
async function validateDependencies(directory, manifest, files) {
    const esbuild = require('esbuild');
    let result;
    try {
        result = await esbuild.build({
            absWorkingDir: directory,
            entryPoints: [manifest.entry.file],
            bundle: true,
            format: 'esm',
            platform: 'node',
            target: 'node18',
            write: false,
            metafile: true,
            logLevel: 'silent',
        });
    } catch (error) {
        const missing = error.errors?.map((detail) => detail.text).join('\n');
        throw new Error('插件入口依赖校验失败\n' + (missing || error.message));
    }
    const allowed = new Set(files);
    for (const filename of Object.keys(result.metafile.inputs)) {
        if (!allowed.has(filename)) {
            throw new Error('插件入口依赖未包含在文件清单中 ' + filename);
        }
    }

    // Node 内置模块随宿主提供，esbuild 允许带错误回退的可选依赖。
    // require.resolve 的静态文件需要核实，因为 esbuild 不会把该目标打入 bundle。
    for (const warning of result.warnings) {
        if (warning.id !== 'require-resolve-not-external') {
            continue;
        }
        const target = /"([^"]+)"/.exec(warning.text)?.[1];
        if (!target || isBuiltin(target)) {
            continue;
        }
        const directoryForFile = path.resolve(directory, path.dirname(warning.location.file));
        const resolved = require.resolve(target, { paths: [directoryForFile] });
        const relative = path.relative(directory, resolved).split(path.sep).join('/');
        if (!allowed.has(relative)) {
            throw new Error('插件引导依赖未包含在文件清单中 ' + target);
        }
    }
}

async function runCli(argv) {
    const [command, ...args] = argv;
    const {
        values: options,
        positionals: [source],
    } = parseArgs({
        args,
        allowPositionals: true,
        options: {
            plugins: { type: 'string' },
            out: { type: 'string' },
            'client-version': { type: 'string' },
            platform: { type: 'string' },
        },
    });
    if (command === 'pack' && source) {
        const output = await packPlugin(source, options.out, { validateDependencies });
        console.log('已打包 ' + output);
    } else if (command === 'verify' && source) {
        const { manifest } = await verifyPackage(source);
        console.log('已验证 ' + manifest.id + '@' + manifest.version);
    } else if (['install', 'rollback'].includes(command) && source && options.plugins) {
        const host = createHostContext({
            clientVersion: options['client-version'],
            platform: options.platform,
        });
        if (command === 'install') {
            const result = await installPackage(source, { plugins: options.plugins, host });
            console.log('已安装 ' + result.id + '@' + result.version);
        } else {
            await rollbackPackage(source, { plugins: options.plugins, host });
            console.log('已回滚 ' + source);
        }
    } else {
        throw new Error(
            '用法: plugin-package.cjs pack <dir> [--out <file>] | verify <file> | ' +
                'install <file> --plugins <dir> [--client-version <version>] | ' +
                'rollback <id> --plugins <dir> [--client-version <version>]',
        );
    }
}

runCli(process.argv.slice(2)).catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
});
