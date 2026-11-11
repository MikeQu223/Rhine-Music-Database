// 发布树只包含应用源码、资源、构建测试与必要的法律归属文件。
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
process.chdir(path.resolve(__dirname, '..'));
const files = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z'], {
    encoding: 'utf8',
})
    .split('\0')
    .filter((file) => file && fs.existsSync(file));
assert(files.length, 'Repository is empty');
// 根目录采用明确清单，避免临时笔记换成其他扩展名后绕过文档检查。
const rootFiles = new Set([
    '.clang-format',
    '.cmake-format.json',
    '.editorconfig',
    '.gitattributes',
    '.gitignore',
    '.gitmodules',
    '.prettierignore',
    '.prettierrc.json',
    'CMakeLists.txt',
    // FidelityFX SDK 以 submodule 记录，源码随递归检出获得。
    'FidelityFX-SDK',
    'LICENSE',
    'NOTICE',
    'README.md',
    'build.sh',
    'eslint.config.mjs',
    'package-lock.json',
    'package.json',
    'pyproject.toml',
    'requirements-format.txt',
    'share.sh',
]);
const sourceDirectories = new Set([
    '.github',
    'Assets',
    'MusicBridge',
    'Qt',
    'Resources',
    // 图形后端与着色器工具的 CMake 模块。
    'cmake',
    // 入库的 FSR Vulkan 置换头，缺 dxc/glslang 时也能直接构建。
    'generated',
    'licenses',
    'scripts',
    // dxc 与 glslang 以 submodule 记录。
    'third_party',
    // 帧率与绘制态测量脚手架，与它测量的渲染代码同仓维护。
    'tools',
    'vendor',
]);
// 公开文档只保留应用说明，开发规范、整改方案和会话记录留在本机。
// tools/perf/README.md 是测量脚手架的用法说明，属于随工具发布的运行文档。
const documentation = ['README.md', 'tools/perf/README.md'];
assert.deepEqual(
    files.filter((file) => /\.md$/i.test(file)).sort(),
    documentation,
    'Unexpected public documentation',
);
for (const file of files) {
    const separator = file.indexOf('/');
    assert(
        separator < 0 ? rootFiles.has(file) : sourceDirectories.has(file.slice(0, separator)),
        `Unexpected public file: ${file}`,
    );
    assert(
        !/(^|\/)(?:\.codex|\.agents|\.claude|node_modules|output|screenshots|captures|prototypes|verification|design|docs|notes|sessions|memories)(?:\/|$)/i.test(
            file,
        ),
        `Local artifact: ${file}`,
    );
    assert(
        !/(?:^|\/)(?:\.env(?:\..*)?|\.DS_Store|credentials\.json|cookies\.json|account\.dpapi)$/i.test(file),
        `Local configuration: ${file}`,
    );
    assert(!/\.(?:log|tmp|swift|app|dSYM|blend|mp4|mov)$/i.test(file), `Non-source artifact: ${file}`);
    assert(!/^vendor\/node-[^/]+\/node(?:\.exe)?$/.test(file), `Local runtime: ${file}`);
    assert(fs.existsSync(file), `Missing tracked file: ${file}`);
    if (/\.(?:cpp|h|mm|qml|js|cjs|mjs|ts|py|sh|yml|json|md)$/.test(file)) {
        const text = fs.readFileSync(file, 'utf8');
        assert(!/\/Users\/[A-Za-z0-9_.-]+\//.test(text), `Personal absolute path: ${file}`);
        assert(
            !/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{30,}|gh[pousr]_[A-Za-z0-9]{30,}/.test(
                text,
            ),
            `Credential material: ${file}`,
        );
    }
}
for (const name of [
    'LICENSE',
    'NOTICE',
    'licenses/source-manifest.json',
    'MusicBridge/LyricsKit-LICENSE',
    'MusicBridge/lyrics-source.json',
]) {
    assert(files.includes(name), `Required attribution: ${name}`);
}
console.log(
    `Public repository audit passed: ${files.length} files, approved documentation, no local artifacts`,
);
