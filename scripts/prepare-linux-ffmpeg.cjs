// Linux 随包提供自编的 FFmpeg：发行版 libavcodec 动态依赖 x265/aom/SvtAv1Enc 等
// 编码器库（合计约 55 MB），而应用只用 Qt 的 FFmpeg 后端解码音频，不需要任何编码器。
// 裁剪口径：只保留音频能力。编码器、复用器、avdevice、avfilter、命令行工具全部关闭，
// 解码器按 vendor/ffmpeg/decoders-linux.json 白名单启用（视频/字幕解码器一律不编，
// 其中 hevc/h264/vp9/av1 是 libavcodec 里体积最大的几块）；parser 与 bitstream filter
// 同样只留音频相关的部分。不自动探测外部库，因此不会链接 x264/x265/aom/dav1d。
// 解复用器保持全开：容器识别是打开文件的第一步，漏一个就直接播不了，而积压只有约 2 MB。
//
// 许可：不启用 --enable-gpl、不启用任何非自由组件时，FFmpeg 以 LGPL-2.1-or-later 构建。
// 脚本会在 configure 之后断言这一点，构建产物随包分发时同时保留许可与来源记录。
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const source = require('../vendor/ffmpeg/source.json');
const root = path.resolve(__dirname, '..');
const directory = path.join(root, 'output/dependencies/ffmpeg-linux');
const install = path.join(directory, 'install');
const build = path.join(directory, 'build');
// 仓库以 submodule 方式纳入 FFmpeg 时直接就地构建，省去下载且源码随仓库可得。
const submodule = path.join(root, 'third_party/ffmpeg');

function run(command, args, cwd = directory) {
    const result = spawnSync(command, args, { cwd, stdio: 'inherit' });
    if (result.error || result.status !== 0) {
        throw result.error || new Error(`${command} exited with ${result.status}`);
    }
}

function capture(command, args, cwd = directory) {
    const result = spawnSync(command, args, { cwd, encoding: 'utf8' });
    if (result.error || result.status !== 0) {
        throw result.error || new Error(`${command} exited with ${result.status}`);
    }
    return result.stdout;
}

/** 取出源码：优先 submodule，其次按锁定校验和下载发布包。 */
function prepareSourceTree() {
    // submodule 只作为快速克隆使用，源码保持上游原样：提交与锁定值不一致或工作树有改动时，
    // 一律回退到发布包，保证构建产物可复现。
    if (source.submodule && fs.existsSync(path.join(submodule, 'configure'))) {
        const git = (args) => spawnSync('git', ['-C', submodule, ...args], { encoding: 'utf8' });
        const revision = git(['rev-parse', 'HEAD']).stdout.trim();
        const dirty = git(['status', '--porcelain']).stdout.trim();
        if (dirty) {
            console.warn('third_party/ffmpeg has local modifications; use the release tarball');
        } else if (revision !== source.submodule.commit) {
            console.warn(
                `third_party/ffmpeg is at ${revision}, expected ${source.submodule.commit}; use the release tarball`,
            );
        } else {
            return {
                tree: submodule,
                provenance: { kind: 'submodule', tag: source.submodule.tag, revision },
            };
        }
    }
    const archive = path.join(directory, `ffmpeg-${source.version}.tar.xz`);
    fs.mkdirSync(directory, { recursive: true });
    if (!fs.existsSync(archive)) {
        run('curl', ['-L', '--fail', '--retry', '3', source.download, '-o', archive]);
    }
    const hash = createHash('sha256').update(fs.readFileSync(archive)).digest('hex');
    if (hash !== source.sha256) {
        throw new Error('FFmpeg source checksum mismatch');
    }
    const tree = path.join(directory, `ffmpeg-${source.version}`);
    if (!fs.existsSync(tree)) {
        run('tar', ['-xf', archive]);
    }
    return {
        tree,
        provenance: { kind: 'release', download: source.download, sha256: hash },
    };
}

// 解码器白名单：只有音频解码器，清单由源码的类型标注生成（见文件内 $comment）。
// RHINE_FFMPEG_EXTRA_DECODERS=a,b 可临时追加，用于上线后发现漏格式时免改脚本。
const decoderManifest = require('../vendor/ffmpeg/decoders-linux.json').decoders;
const extraDecoders = (process.env.RHINE_FFMPEG_EXTRA_DECODERS || '')
    .split(',')
    .map((name) => name.trim())
    .filter(Boolean);
const decoders = [...new Set([...decoderManifest, ...extraDecoders])];
// 音频 parser：裸流（ADTS/LATM、裸 MP3 帧、FLAC、DTS 等）与网络流的分帧依赖它。
const parsers = [
    'aac',
    'aac_latm',
    'ac3',
    'adx',
    'amr',
    'cook',
    'dca',
    'dolby_e',
    'dvaudio',
    'flac',
    'ftr',
    'g723_1',
    'g729',
    'gsm',
    'misc4',
    'mlp',
    'mpegaudio',
    'opus',
    'sbc',
    'sipr',
    'tak',
    'vorbis',
    'xma',
];
// avformat 在播放路径上可能自动插入的音频 bitstream filter。
// 不含 extract_extradata：它的 codec_ids 只有视频（AV1/H.264/HEVC/MPEG 系列/VC1/VVC），
// 纯音频流永远走不到，留着会白白拖进整套 cbs_* 码流解析模块。
const bsfs = [
    'null',
    'aac_adtstoasc',
    'dca_core',
    'eac3_core',
    'opus_metadata',
    'pcm_rechunk',
    'truehd_core',
    'dts2pts',
];

// 构建参数：shared 便于随包替换；关闭一切与音频解码无关的部分。
// --enable-small 把默认的 -O3 换成 -Os：音频解码的算力冗余很大，换来的结果是 avcodec 小一截。
// --enable-lto=auto 让 CFLAGS 带上 -flto=auto，链接期并行执行跨编译单元优化；不启用任何 GPL 组件，
//   许可断言不受影响。
// --extra-ldflags=-flto=auto 在链接期启用自动并行 LTO，避免裸 -flto 导致 LTRANS 串行编译。
// 显式传入也补 FFmpeg 自己的漏洞：它用 `check_ldflags $lto $cpuflags` 决定链接期
//   是否带 -flto，而 $cpuflags 默认是 -march=generic；GCC 16 起 generic 只允许出现在 -mtune 上，
//   该探测因此失败，-flto 被静默从 LDFLAGS 拿掉。此时对象是胖 LTO 对象（同时含 IR 与机器码），
//   链接器若没加载到插件就会直接跳到机器码，LTO 白开。显式写进 ldflags 后不依赖这个探测，也不
//   依赖 ld 的 /usr/lib/bfd-plugins 自动加载插件。
//   工具链确实不支持时用 RHINE_FFMPEG_LTO=0 关掉，该值同时进 fingerprint，切换会触发重编。
// --disable-x86asm 免去构建机需要 nasm，音频解码不依赖汇编加速。
const lto = process.env.RHINE_FFMPEG_LTO !== '0';
const configureArguments = [
    '--enable-shared',
    '--disable-static',
    '--disable-programs',
    '--disable-doc',
    '--disable-debug',
    '--disable-autodetect',
    '--enable-small',
    ...(lto ? ['--enable-lto=auto', '--extra-ldflags=-flto=auto'] : []),
    '--disable-encoders',
    '--disable-muxers',
    '--disable-avdevice',
    '--disable-avfilter',
    '--disable-hwaccels',
    '--disable-decoders',
    `--enable-decoder=${decoders.join(',')}`,
    '--disable-parsers',
    `--enable-parser=${parsers.join(',')}`,
    '--disable-bsfs',
    `--enable-bsf=${bsfs.join(',')}`,
    '--disable-x86asm',
    // 库都在 AppDir 的 usr/lib，运行时按 $ORIGIN 相互查找，不落到构建机的安装目录。
    // 写成 $$ORIGIN：configure 原样写入 config.mak，由 make 展开成 $ORIGIN。
    '--extra-ldflags=-Wl,-rpath,$$ORIGIN',
];

/**
 * 断言构建结果是 LGPL
 * 配成 GPL 或非自由组件后随包分发会改变整个应用的许可，必须在构建期拦住。
 */
function assertLgpl() {
    const markers = ['config.h', 'config_components.h', 'ffbuild/config.mak'];
    let inspected = false;
    for (const marker of markers) {
        const file = path.join(build, marker);
        if (!fs.existsSync(file)) {
            continue;
        }
        const content = fs.readFileSync(file, 'utf8');
        if (/CONFIG_(?:GPLV3|GPL|NONFREE)\s*(?:1|yes)/.test(content)) {
            throw new Error(`FFmpeg was configured with GPL or nonfree components (${marker})`);
        }
        if (/CONFIG_(?:GPL|NONFREE)/.test(content)) {
            inspected = true;
        }
    }
    if (!inspected) {
        console.warn('Cannot confirm the FFmpeg license from generated config; check configure output');
    }
}

/**
 * 断言构建结果只含音频解码能力
 * 白名单写错（或 configure 依赖把视频解码器带进来）会让体积悄悄回到 14 MB 量级，
 * 在构建期拦住比事后看包体积更可靠。
 */
function assertAudioOnly() {
    const file = path.join(build, 'config_components.h');
    if (!fs.existsSync(file)) {
        console.warn('Cannot confirm the decoder selection; check configure output');
        return;
    }
    const content = fs.readFileSync(file, 'utf8');
    const enabled = new Set(
        [...content.matchAll(/#define CONFIG_([A-Z0-9_]+)_DECODER 1/g)].map((m) => m[1].toLowerCase()),
    );
    const leftovers = ['hevc', 'h264', 'vp9', 'av1', 'vvc', 'mpeg4', 'mpeg2video', 'vc1'].filter((name) =>
        enabled.has(name),
    );
    if (leftovers.length > 0) {
        throw new Error(`video decoders are still enabled: ${leftovers.join(', ')}`);
    }
    const required = ['mp3', 'aac', 'alac', 'flac', 'vorbis', 'opus', 'ape', 'wavpack', 'pcm_s16le'];
    const missing = required.filter((name) => !enabled.has(name));
    if (missing.length > 0) {
        throw new Error(`audio decoders are missing: ${missing.join(', ')}`);
    }
    console.log(`FFmpeg decoders: ${enabled.size} enabled, video decoders disabled`);
}

/**
 * 断言 LTO 真的生效
 * configure 的 check_cflags/check_ldflags 对不认识的 flag 只记日志、不报错，缺插件时 -flto 被丢弃
 * 而构建照常成功。两个位置都要复核：CFLAGS 缺 -flto 等于没开 LTO；LDFLAGS 缺 -flto 则链接期不做
 * 跨单元优化（胖 LTO 对象会退回机器码），两者都算静默降级，一律拦住。
 */
function assertLto() {
    if (!lto) {
        console.warn('FFmpeg LTO disabled by RHINE_FFMPEG_LTO=0');
        return;
    }
    const file = path.join(build, 'ffbuild/config.mak');
    if (!fs.existsSync(file)) {
        console.warn('Cannot confirm the FFmpeg LTO flags; check configure output');
        return;
    }
    const content = fs.readFileSync(file, 'utf8');
    const flags = (name) => (content.match(new RegExp(`^${name}=(.*)$`, 'm')) || [, ''])[1];
    const missing = ['CFLAGS', 'LDFLAGS'].filter((name) => !/(?:^|\s)-flto/.test(flags(name)));
    if (missing.length > 0) {
        throw new Error(
            `FFmpeg LTO was requested but -flto is missing from ${missing.join(' and ')}; ` +
                'set RHINE_FFMPEG_LTO=0 only if this toolchain cannot do LTO',
        );
    }
    console.log('FFmpeg LTO: -flto present in CFLAGS and LDFLAGS');
}

function main() {
    const { tree, provenance } = prepareSourceTree();
    const stamp = path.join(install, '.build.json');
    const fingerprint =
        JSON.stringify(provenance) +
        '\n' +
        configureArguments.join(' ') +
        '\n' +
        createHash('sha256').update(fs.readFileSync(__filename)).digest('hex');
    if (fs.existsSync(stamp) && JSON.parse(fs.readFileSync(stamp, 'utf8')).fingerprint === fingerprint) {
        return;
    }
    fs.mkdirSync(build, { recursive: true });
    fs.rmSync(build, { recursive: true, force: true });
    fs.mkdirSync(build, { recursive: true });
    run(path.join(tree, 'configure'), [`--prefix=${install}`, ...configureArguments], build);
    assertLgpl();
    assertAudioOnly();
    assertLto();
    run('make', ['-j', process.env.RHINE_BUILD_JOBS || String(os.cpus().length)], build);
    run('make', ['install'], build);
    // 随包保留来源与构建参数，满足 LGPL 的源码可得性要求。
    fs.writeFileSync(
        stamp,
        JSON.stringify(
            {
                fingerprint,
                project: source.name,
                version: source.version,
                license: 'LGPL-2.1-or-later',
                licenseFile: source.license,
                ...provenance,
                configure: configureArguments,
            },
            null,
            4,
        ) + '\n',
    );
    fs.copyFileSync(stamp, path.join(install, 'build.json'));
}
main();
