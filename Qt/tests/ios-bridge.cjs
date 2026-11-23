// 验证 iOS 核心传输及会话重建
const assert = require('node:assert/strict');
const { createHmac, randomUUID } = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const readline = require('node:readline');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');
const { bridgeRuntime, bridgeSourceDirectory } = require('./fixtures/bridge-runtime.cjs');

/** 模拟回环连接被重置，确认 readline 转发的异步错误不会结束宿主。 */
function checkTransportError(runtime) {
    const fixture = `
        const net = require('node:net');
        const { PassThrough } = require('node:stream');
        const socket = new PassThrough();
        net.connect = () => socket;
        require(process.argv[1]);
        socket.destroy(Object.assign(new Error('connection reset'), { code: 'ECONNRESET' }));
        setImmediate(() => process.exit(0));
    `;
    const result = spawnSync(runtime, ['-e', fixture, path.resolve('MusicBridge/ios-runtime.cjs')], {
        encoding: 'utf8',
        timeout: 5000,
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
}

async function main() {
    if (process.platform === 'darwin') {
        await require('./ios-system-trust.cjs').runSystemTrustChecks();
    }
    const { bridge, runtime } = bridgeRuntime();
    checkTransportError(runtime);
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'rhine-ios-bridge-'));
    const server = net.createServer();
    const token = 'fixture-token';
    let child;
    let socket;
    const responses = new Map();
    const buffers = new Map();
    let failure;
    const timeout = setTimeout(() => {
        failure = new Error('iOS bridge regression timed out');
    }, 25000);
    async function waitFor(predicate) {
        while (!predicate()) {
            if (failure) {
                throw failure;
            }
            await new Promise((resolve) => setTimeout(resolve, 10));
        }
    }
    function send(message) {
        socket.write(JSON.stringify(message) + '\n');
    }
    function readMessages(connection) {
        const messages = [];
        const reader = readline.createInterface({ input: connection });
        reader.on('error', (error) => {
            failure = error;
        });
        reader.on('line', (line) => {
            const message = JSON.parse(line);
            messages.push(message);
            if (message.type === 'system-trust') {
                failure = new Error('Offline fixture unexpectedly requested TLS: ' + message.hostname);
            }
            if (message.type === 'error') {
                failure = new Error('iOS Worker failed');
            }
            if (message.type !== 'output') {
                return;
            }
            let buffer = (buffers.get(message.session) || '') + Buffer.from(message.data, 'base64');
            let end;
            while ((end = buffer.indexOf('\n')) >= 0) {
                const response = JSON.parse(buffer.slice(0, end));
                responses.set(message.session + ':' + response.id, response);
                buffer = buffer.slice(end + 1);
            }
            buffers.set(message.session, buffer);
        });
        return messages;
    }
    async function authenticate(messages) {
        await waitFor(() => messages.length > 0);
        const hello = messages[0];
        assert.equal(hello.type, 'hello');
        assert.equal(typeof hello.nonce, 'string');
        assert(!Object.hasOwn(hello, 'token'));
        const nonce = randomUUID();
        const proof = (role, value) => createHmac('sha256', token).update(`${role}:${value}`).digest('hex');
        send({ type: 'challenge', nonce, proof: proof('server', hello.nonce) });
        await waitFor(() => messages.length > 1);
        assert.deepEqual(messages[1], { type: 'proof', proof: proof('client', nonce) });
        send({ type: 'ready' });
        send({ type: 'ping', id: 'foreground-test' });
        await waitFor(() =>
            messages.some((message) => message.type === 'pong' && message.id === 'foreground-test'),
        );
    }
    async function startSession(session, messages) {
        const directory = path.join(temporary, session);
        fs.mkdirSync(directory);
        send({
            type: 'start',
            session,
            script: path.join(bridge, 'worker.cjs'),
            env: { TMPDIR: directory },
        });
        await waitFor(() =>
            messages.some((message) => message.session === session && message.type === 'started'),
        );
    }
    function lyricsInput(session, id = session) {
        const request = { id, route: '/local/lyrics', params: { content: id } };
        return {
            type: 'input',
            session,
            data: Buffer.from(JSON.stringify(request) + '\n').toString('base64'),
        };
    }
    async function checkLyrics(session) {
        const key = session + ':' + session;
        send(lyricsInput(session));
        await waitFor(() => responses.has(key));
        const response = responses.get(key);
        assert.equal(response.body.code, 200);
        assert.equal(response.body.document.plainText, session);
    }
    try {
        server.listen(0, '127.0.0.1');
        await once(server, 'listening');
        const connection = once(server, 'connection', { signal: AbortSignal.timeout(25000) });
        child = spawn(
            runtime,
            [
                '--require',
                path.join(bridgeSourceDirectory(), 'ios-web-apis.cjs'),
                path.resolve('MusicBridge/ios-runtime.cjs'),
                String(server.address().port),
                token,
                '--reconnect',
            ],
            { stdio: ['ignore', 'ignore', 'pipe'] },
        );
        child.on('error', (error) => {
            failure = error;
        });
        child.on('exit', () => {
            failure = new Error('Embedded controller exited unexpectedly');
        });
        [socket] = await connection;
        const messages = readMessages(socket);
        await authenticate(messages);
        await startSession('first', messages);
        await checkLyrics('first');
        send({ type: 'stop', session: 'first' });
        // 不等待退出就发送下一次 start，控制器必须等待旧 Worker 销毁。
        await startSession('second', messages);
        await checkLyrics('second');
        const firstExit = messages.findIndex(
            (message) => message.session === 'first' && message.type === 'finished',
        );
        const secondStart = messages.findIndex(
            (message) => message.session === 'second' && message.type === 'started',
        );
        assert(firstExit >= 0 && firstExit < secondStart);

        // 旧会话仍在线时重绑监听器，再重置数据连接，覆盖两者各自的恢复路径。
        const listenPort = server.address().port;
        server.close();
        const listeningAgain = once(server, 'listening', { signal: AbortSignal.timeout(10000) });
        server.listen(listenPort, '127.0.0.1');
        await listeningAgain;
        const reconnect = once(server, 'connection', { signal: AbortSignal.timeout(10000) });
        await new Promise((resolve, reject) => {
            socket.write('{"type":', (error) => {
                if (error) {
                    reject(error);
                    return;
                }
                resolve();
            });
        });
        socket.resetAndDestroy();
        [socket] = await reconnect.catch((error) => {
            throw new Error('iOS controller did not reconnect after TCP reset', { cause: error });
        });
        const recovered = readMessages(socket);
        await authenticate(recovered);
        send(lyricsInput('second', 'stale'));
        await startSession('reconnected', recovered);
        await checkLyrics('reconnected');
        send({ type: 'stop', session: 'reconnected' });
        await waitFor(() =>
            recovered.some((message) => message.session === 'reconnected' && message.type === 'finished'),
        );
        assert(
            !recovered.some((message) => message.session === 'second'),
            'Old Worker messages reached the new connection',
        );
        console.log('iOS Worker session replacement and transport recovery passed');
    } finally {
        clearTimeout(timeout);
        child?.kill();
        socket?.destroy();
        server.close();
        fs.rmSync(temporary, { recursive: true, force: true });
    }
}
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
