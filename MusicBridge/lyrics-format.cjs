// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
// Adapted from LyricsKit (MxIris-LyricsX-Project), revision recorded in lyrics-source.json.
// Core only normalizes the neutral LRC format used by local files and the built-in source.
// Provider-specific wire formats (word timing, encoded translations, etc.) live in plugins.
const MAX_CONTENT_LENGTH = 1000000;

function cleanText(value) {
    return String(value || '')
        .replace(/&lt;/g, '<')
        .replace(/&gt;/g, '>')
        .replace(/&quot;/g, '"')
        .replace(/&apos;/g, "'")
        .replace(/&#(x[0-9a-f]+|\d+);/gi, (match, code) => {
            const point = code[0].toLowerCase() === 'x' ? parseInt(code.slice(1), 16) : Number(code);
            return point <= 0x10ffff ? String.fromCodePoint(point) : match;
        })
        .replace(/&amp;/g, '&')
        .replace(/\r\n?/g, '\n')
        .slice(0, MAX_CONTENT_LENGTH);
}

function parseTags(content) {
    const tags = {};
    for (const match of content.matchAll(/^\s*\[([a-z]+):([^\]\n]*)\]\s*$/gim)) {
        tags[match[1].toLowerCase()] ??= match[2].trim();
    }
    return tags;
}

/** Expand multi-timestamp LRC rows and keep empty lines as interlude boundaries. */
function parseLrc(input) {
    const content = cleanText(input);
    const lines = [];
    for (const row of content.split('\n')) {
        const match = /^\s*((?:\[[-+]?\d+:\d+(?:[.:]\d+)?\])+)(.*)$/.exec(row);
        if (!match) {
            continue;
        }
        const translation = /【(.*)】$/.exec(match[2]);
        const text = match[2].replace(/【.*】$/, '').trim();
        for (const stamp of match[1].matchAll(/\[([-+]?\d+):(\d+)(?:[.:](\d+))?\]/g)) {
            const startMs = Math.round(
                (Number(stamp[1]) * 60 + Number(stamp[2])) * 1000 + Number('0.' + (stamp[3] || '0')) * 1000,
            );
            lines.push({ startMs, endMs: null, text, translation: translation?.[1] || '', words: [] });
        }
    }
    return lines.sort((left, right) => left.startMs - right.startMs);
}

function attachTranslation(lines, translation) {
    const translated = parseLrc(translation);
    for (const line of lines) {
        if (!line.text) {
            continue;
        }
        let closest = null;
        let distance = 700;
        for (const candidate of translated) {
            const delta = Math.abs(line.startMs - candidate.startMs);
            if (candidate.text && delta < distance) {
                closest = candidate;
                distance = delta;
            }
        }
        if (closest) {
            line.translation = closest.text;
        }
    }
}

function isCreditLine(line, tags) {
    const text = line.text.trim();
    const role =
        /^(作词|作曲|编曲|制谱|演唱|制作人|录音棚|录音师|混音师|母带制作|民谣吉他|电吉他|手风琴|第一小提琴|第二小提琴|中提琴|大提琴|词|曲|lyrics by|composed by|written by|produced by|arranged by)(?:\s+[^:：]+)?\s*[:：]/i;
    if (role.test(text)) {
        return true;
    }
    const title = tags.ti?.trim();
    const artist = tags.ar?.trim();
    return !!title && !!artist && text === title + ' - ' + artist;
}

/**
 * Convert a neutral LRC payload into the public lyrics document.
 * `source` is only a document label; it must not select any platform-specific parser.
 */
function normalizeLyrics(source, body, metadata = {}) {
    const raw = body.response || body;
    if (raw.code !== undefined && ![0, 200].includes(raw.code)) {
        return { code: 502, message: '歌词来源暂不可用' };
    }
    const original = cleanText(
        raw.lrc?.lyric || (typeof raw.lrc === 'string' ? raw.lrc : '') || raw.lyric || raw.decodeContent || '',
    );
    const translation = cleanText(raw.tlyric?.lyric || raw.translation || '');
    const lines = parseLrc(original);
    attachTranslation(lines, translation);
    const tags = parseTags(original);
    tags.ti ||= metadata.title;
    tags.ar ||= metadata.artist;
    const filtered = lines.filter((line) => !isCreditLine(line, tags));
    const hasContent = filtered.some(
        (line) =>
            line.text &&
            !/^(作词|作曲|编曲|制作人|演唱|混音|录音)\s*[:：]/.test(line.text) &&
            !/^(纯音乐|此歌曲为没有填词的纯音乐)/.test(line.text),
    );
    const timed = hasContent && new Set(filtered.map((line) => line.startMs)).size > 1;
    const plainText = timed
        ? ''
        : original
              .replace(/^\[[a-z]+:.*\]\s*$/gim, '')
              .replace(/\[[^\]\n]+\]/g, '')
              .trim();
    const offsetMs = Number(tags.offset || 0);
    return {
        code: 200,
        document: {
            version: 1,
            source: String(source || 'local'),
            timing: timed ? 'line' : 'none',
            offsetMs: Number.isFinite(offsetMs) && Math.abs(offsetMs) <= 10000 ? offsetMs : 0,
            lines: timed ? filtered : [],
            plainText,
        },
    };
}

module.exports = { parseLrc, normalizeLyrics };
