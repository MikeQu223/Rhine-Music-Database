const fs = require('node:fs');
const path = require('node:path');

/** 在构建机展开 Unicode 类别，避免无 ICU 的 NodeMobile 在解析 Worker 时退出。 */
function titleSeparatorPattern() {
    const ranges = ['\\s'];
    let start = -1;
    for (let codePoint = 0; codePoint <= 0x110000; ++codePoint) {
        const matches = codePoint < 0x110000 && /[\p{P}\p{S}]/u.test(String.fromCodePoint(codePoint));
        if (matches && start < 0) {
            start = codePoint;
        }
        if (!matches && start >= 0) {
            const first = `\\u{${start.toString(16)}}`;
            const last = codePoint - 1;
            ranges.push(start === last ? first : `${first}-\\u{${last.toString(16)}}`);
            start = -1;
        }
    }
    return `/[${ranges.join('')}]/gu`;
}

// 避免 iOS 使用内置 Node.js 版本的 fetch
module.exports = {
    name: 'ios-utf8-validation',
    setup(build) {
        build.onLoad({ filter: /\/MusicBridge\/client\/netease\.mjs$/ }, (args) => {
            const contents = fs.readFileSync(args.path, 'utf8');
            const original = '/[\\s\\p{P}\\p{S}]/gu';
            if (contents.split(original).length !== 2) {
                throw new Error('MV title separators changed; review iOS Unicode compatibility');
            }
            return {
                contents: contents.replace(original, () => titleSeparatorPattern()),
                loader: 'js',
            };
        });
        build.onLoad({ filter: /\/MusicBridge\/worker\.cjs$/ }, (args) => ({
            contents:
                `require(${JSON.stringify(path.join(path.dirname(args.path), 'ios-web-apis.cjs'))});\n` +
                fs.readFileSync(args.path, 'utf8'),
            loader: 'js',
        }));
        build.onLoad({ filter: /@neteasecloudmusicapienhanced\/api\/util\/crypto\.js$/ }, (args) => {
            const contents = fs.readFileSync(args.path, 'utf8');
            const decoder =
                /const decoder = new TextDecoder\('utf-8', \{ fatal: true \}\)\n\nconst isUtf8 = \(buf\) => \{\n  try \{\n    decoder.decode\(buf\)\n    return true\n  \} catch \{\n    return false\n  \}\n\}/g;
            const matches = [...contents.matchAll(decoder)];
            if (matches.length !== 1 || contents.match(/decoder\./g)?.length !== 1) {
                throw new Error('Upstream UTF-8 validator changed; review iOS compatibility before building');
            }
            return {
                contents: contents.replace(decoder, "const { isUtf8 } = require('node:buffer')"),
                loader: 'js',
            };
        });
    },
};
