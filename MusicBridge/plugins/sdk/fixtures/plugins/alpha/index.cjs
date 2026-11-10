'use strict';

// Synthetic adapter used only by contract/worker tests. It must never contain
// real platform behavior; alpha/beta are neutral fixture provider ids.
function track(id = '1') {
    return {
        provider: 'alpha',
        kind: 'song',
        id,
        key: 'alpha:song:' + id,
        title: 'Fixture Song ' + id,
        artist: 'Fixture Artist',
        artists: [{ id: 'artist-1', name: 'Fixture Artist' }],
        creatorID: '',
        albumID: 'album-1',
        album: 'Fixture Album',
        cover: 'https://cover.alpha.example/' + id + '.jpg',
        description: '',
        wiki: '',
        date: '2026-01-01',
        duration: 180000,
        trackCount: 0,
    };
}

function page(items, offset = 0, total = items.length) {
    return {
        items,
        rawCount: items.length,
        total,
        more: offset + items.length < total,
    };
}

function createRuntime(host) {
    const manifest = host.manifest || {};
    const operations = new Set(
        Object.entries(manifest.operations || {})
            .filter(([, enabled]) => enabled)
            .map(([operation]) => operation),
    );
    const api = {
        async search(text, kind) {
            const item = track('1');
            if (kind === 'song') {
                item.title = text || item.title;
                return page([item]);
            }
            return page([{ ...item, kind, key: 'alpha:' + kind + ':1' }]);
        },
        async suggest(text) {
            return [text || 'fixture'];
        },
        async resolveLink(text) {
            return /alpha\.example/.test(text) ? { provider: 'alpha', kind: 'song', id: '1' } : null;
        },
        async songs(ids) {
            return ids.map((id) => track(String(id)));
        },
        async detail(value) {
            return [value.kind === 'song' ? track(value.id) : { ...track(value.id), kind: value.kind }, [], []];
        },
        async artistAlbums() {
            return page([]);
        },
        async playback() {
            return {
                url: 'https://media.alpha.example/fixture.flac',
                tier: 'lossless',
                providerTier: 'fixture-lossless',
                format: 'flac',
                bitrate: 1000000,
                size: 1000,
            };
        },
        async preview() {
            return {
                url: 'https://media.alpha.example/preview.mp3',
                tier: 'standard',
                trial: true,
            };
        },
        async lyrics() {
            return {
                version: 1,
                source: 'alpha',
                timing: 'line',
                offsetMs: 0,
                lines: [{ startMs: 0, text: 'fixture lyric' }],
            };
        },
        async account() {
            return { uid: 'alpha-user', nickname: 'Alpha User' };
        },
        async loginBegin() {
            return { token: 'alpha-token', qrText: 'alpha://login/alpha-token', pollIntervalMs: 1000 };
        },
        async loginPoll() {
            return { code: 200, status: 'confirmed' };
        },
        async loginCancel() {
            return {};
        },
        async loginSms() {
            return { retryAfterMs: 60000 };
        },
        async loginSubmit() {
            return { code: 200 };
        },
        async userPlaylists() {
            return page([]);
        },
        async likedSongs() {
            return page([]);
        },
        async likedState() {
            return {};
        },
        async discover(tab) {
            return page([], 0, 0, { notice: 'fixture ' + tab });
        },
        async categories() {
            return [{ id: 'all', name: '全部' }];
        },
        async mutate(route) {
            return { applied: true, state: route === '/like' ? 'subscribed' : 'not-subscribed' };
        },
        async mixtape() {
            return { ok: true };
        },
        async capabilities() {
            return manifest.capabilities || {};
        },
    };
    return {
        async dispatchNative(operation, args) {
            if (!operations.has(operation) || typeof api[operation] !== 'function') {
                const error = new Error('unsupported operation');
                error.code = 400;
                throw error;
            }
            return api[operation](...(args || []));
        },
        async dispatchRoute(route, params) {
            return { code: 200, value: { route, params: params || {} } };
        },
        async capabilities() {
            return manifest.capabilities || {};
        },
        async dispose() {},
    };
}

module.exports = { create: createRuntime };
