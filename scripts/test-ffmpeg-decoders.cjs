const assert = require('node:assert/strict');
const { test } = require('node:test');
const { spawnSync } = require('node:child_process');
const { assertDecoderSelection } = require('./prepare-linux-ffmpeg.cjs');
const manifest = require('../vendor/ffmpeg/decoders-linux.json');
const defaults = [...manifest.decoders, ...manifest.videoDecoders];
const config = (names) => names.map((name) => `#define CONFIG_${name.toUpperCase()}_DECODER 1`).join('\n');

test('Linux FFmpeg accepts the audio and MV decoder configuration', () => {
    assert.equal(assertDecoderSelection(config(defaults)), new Set(defaults).size);
});

test('Linux FFmpeg rejects unapproved video and subtitle decoders', () => {
    for (const name of ['vp9', 'av1', 'vvc', 'mpeg4', 'mpeg2video', 'vc1', 'theora', 'ass']) {
        assert.throws(
            () => assertDecoderSelection(config([...defaults, name])),
            new RegExp(`unexpected decoders are enabled: ${name}`),
        );
    }
});

test('Linux FFmpeg requires both MV codecs', () => {
    for (const name of ['h264', 'hevc']) {
        assert.throws(
            () => assertDecoderSelection(config(defaults.filter((value) => value !== name))),
            new RegExp(`MV decoders are missing: ${name}`),
        );
    }
});

test('Linux FFmpeg still requires common audio decoders', () => {
    for (const name of ['mp3', 'aac', 'alac', 'flac', 'vorbis', 'opus', 'ape', 'wavpack', 'pcm_s16le']) {
        assert.throws(
            () => assertDecoderSelection(config(defaults.filter((value) => value !== name))),
            new RegExp(`audio decoders are missing: ${name}`),
        );
    }
});

test('Disabled video decoders do not count as enabled', () => {
    assert.equal(
        assertDecoderSelection(
            `${config(defaults)}\n#define CONFIG_VP9_DECODER 0\n#define CONFIG_AV1_DECODER 0`,
        ),
        new Set(defaults).size,
    );
});

test('An explicitly requested extra decoder is permitted', () => {
    const result = spawnSync(
        process.execPath,
        [
            '-e',
            "const {assertDecoderSelection} = require('./scripts/prepare-linux-ffmpeg.cjs'); assertDecoderSelection(require('node:fs').readFileSync(0, 'utf8'));",
        ],
        {
            cwd: require('node:path').resolve(__dirname, '..'),
            env: { ...process.env, RHINE_FFMPEG_EXTRA_DECODERS: 'vp9' },
            input: config([...defaults, 'vp9']),
            encoding: 'utf8',
        },
    );
    assert.equal(result.status, 0, result.stderr);
});
