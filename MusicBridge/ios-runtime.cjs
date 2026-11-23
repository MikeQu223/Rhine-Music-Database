// 移动端的 Node 主线程只负责传输；每个音乐会话使用独立 Worker。
const net = require('node:net');
const { createHmac, randomUUID } = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const { MessageChannel, Worker } = require('node:worker_threads');
const port = Number(process.argv[2]);
const token = process.argv[3];
const shouldReconnect = process.argv[4] === '--reconnect';
const INITIAL_RECONNECT_DELAY_MS = 100;
const MAX_RECONNECT_DELAY_MS = 2000;
const HANDSHAKE_TIMEOUT_MS = 4000;
let reconnectDelayMs = INITIAL_RECONNECT_DELAY_MS;
let worker;
let session;
let commands = Promise.resolve();
const pluginControls = new Map();

/** 校验和初始化请求在独立 Worker 中执行，与当前音乐会话生命周期分离。 */
function startPluginControl(message, send) {
    const { requestId } = message;
    if (pluginControls.has(requestId)) {
        return;
    }
    const failed = { code: 'plugin.control', message: '插件校验运行时退出' };
    let control;
    try {
        control = new Worker(message.script, { stdout: true, stderr: true });
    } catch {
        send({ type: 'plugin-control-result', requestId, error: failed });
        return;
    }
    // 插件入口可以访问当前 Worker 的 parentPort，控制结果使用单独的回复端口。
    const { port1, port2 } = new MessageChannel();
    const stop = () => {
        port1.close();
        control.terminate().catch(() => {
            // Worker 已退出时无需再次终止。
        });
    };
    pluginControls.set(requestId, stop);
    const finish = (value) => {
        if (pluginControls.get(requestId) !== stop) {
            return;
        }
        pluginControls.delete(requestId);
        send({ type: 'plugin-control-result', requestId, result: value.result, error: value.error });
        stop();
    };
    control.stdout.resume();
    control.stderr.resume();
    port1.once('message', finish);
    control.once('exit', () => finish({ error: failed }));
    control.once('error', () => finish({ error: failed }));
    control.postMessage({ request: message.request, reply: port2 }, [port2]);
}

/** 串行销毁旧 Worker 后才建立新会话，旧连接和模块全局状态不会进入新账号。 */
async function execute(message, socket, send) {
    if (message.type === 'plugin-control') {
        startPluginControl(message, send);
    } else if (message.type === 'plugin-control-cancel') {
        const stop = pluginControls.get(message.requestId);
        if (stop) {
            pluginControls.delete(message.requestId);
            stop();
        }
    } else if (message.type === 'start') {
        if (worker) {
            await worker.terminate();
        }
        if (socket.destroyed) {
            return;
        }
        session = message.session;
        const current = session;
        // nodejs-mobile 的 Worker 把 env 选项与 workerData 全部丢弃（Android 真机实测，
        // worker 的 os.tmpdir() 退回 /tmp 并 EACCES）。进程内写 process.env 也不可靠
        // （worker 环境不继承运行时的 JS 层修改），所以把宿主环境落在 worker 脚本旁的
        // 文件里——文件系统是唯一可靠通道，worker 前奏会读它。iOS 上脚本目录只读，
        // 写失败被吞掉，由 worker 侧的探测兜底接手。
        // 代码签名的 .app 包不能写入
        const scriptDirectory = path.dirname(message.script);
        if (!scriptDirectory.includes('.app' + path.sep)) {
            try {
                fs.writeFileSync(
                    path.join(scriptDirectory, 'host-env.json'),
                    JSON.stringify(message.env || {}),
                    { flag: 'w' },
                );
            } catch {}
        }
        worker = new Worker(message.script, {
            env: { ...process.env, ...message.env },
            workerData: message.env || {},
            stdin: true,
            stdout: true,
            stderr: true,
        });
        const instance = worker;
        instance.stdin.on('error', () => {
            // Worker 退出时，已排队的 stdin 写入可能失败，宿主通过 exit 收到通知。
        });
        const environment = message.env || {};
        instance.stdin.write(
            JSON.stringify({
                control: 'plugins.configure',
                clientVersion: environment.RHINE_CLIENT_VERSION,
                platform: environment.RHINE_PLATFORM,
                userRoot: environment.RHINE_USER_PLUGINS,
                disabled: environment.RHINE_DISABLED_PLUGINS,
            }) + '\n',
        );
        instance.on('message', (message) => {
            if (message?.type === 'system-trust') {
                send({ ...message, session: current });
            }
        });
        instance.stdout.on('data', (bytes) => {
            send({ type: 'output', session: current, data: bytes.toString('base64') });
        });
        if (message.stderrLog) {
            // Android 没有可用的控制台，设备上的崩溃原因只能靠这条通道进 logcat。
            instance.stderr.on('data', (bytes) => {
                send({ type: 'stderr', session: current, data: bytes.toString('base64') });
            });
        } else {
            // 上游日志可能包含账号数据，沿用桌面端的静默策略。
            instance.stderr.resume();
        }
        instance.on('online', () => send({ type: 'started', session: current }));
        // 错误详情必须透传：设备上没有控制台，宿主只能靠它定位 spawn/加载失败。
        // detail/exitCode 是新增字段，桌面与 iOS 的宿主只按 type 分派，不受影响。
        instance.on('error', (error) => {
            send({ type: 'error', session: current, detail: String(error?.stack || error) });
        });
        instance.on('exit', (code) => {
            send({ type: 'finished', session: current, exitCode: code });
            if (worker === instance) {
                worker = undefined;
            }
        });
    } else if (message.session === session && worker) {
        if (message.type === 'system-trust-result') {
            worker.postMessage(message);
        } else if (message.type === 'input') {
            worker.stdin.write(Buffer.from(message.data, 'base64'));
        } else if (message.type === 'stop') {
            await worker.terminate();
        }
    }
}

/** 断线后终止旧会话和校验任务。新连接的命令排在这次清理之后。 */
async function stopDisconnectedSession() {
    for (const stop of pluginControls.values()) {
        stop();
    }
    pluginControls.clear();
    const previousWorker = worker;
    worker = undefined;
    session = undefined;
    if (previousWorker) {
        await previousWorker.terminate().catch(() => {
            // 已结束的 Worker 无需再次终止。
        });
    }
}

/** 每条连接重新认证，所有回复只能写入产生该请求的连接。 */
function connect() {
    const socket = net.connect(port, '127.0.0.1');
    let authenticated = !shouldReconnect;
    let challenged = false;
    const nonce = shouldReconnect ? randomUUID() : undefined;
    const handshakeTimer = shouldReconnect
        ? setTimeout(() => socket.destroy(), HANDSHAKE_TIMEOUT_MS)
        : undefined;
    const send = (message) => {
        if (!socket.destroyed && socket.writable) {
            socket.write(JSON.stringify(message) + '\n');
        }
    };
    socket.on('connect', () => send(shouldReconnect ? { type: 'hello', nonce } : { token }));
    socket.on('error', () => {
        // readline 关闭后，socket 仍可能报告在途写入失败。
    });
    const reader = readline.createInterface({ input: socket });
    reader.on('error', () => {
        // readline 会把 socket 的错误重新发出。两个事件都由控制器处理。
        socket.destroy();
    });
    reader.on('line', (line) => {
        let message;
        try {
            message = JSON.parse(line);
        } catch {
            // 忽略不完整的指令，避免影响随后到达的控制消息。
            return;
        }
        if (!authenticated) {
            const proof = (role, value) =>
                createHmac('sha256', token).update(`${role}:${value}`).digest('hex');
            if (
                !challenged &&
                message?.type === 'challenge' &&
                typeof message.nonce === 'string' &&
                message.proof === proof('server', nonce)
            ) {
                challenged = true;
                send({ type: 'proof', proof: proof('client', message.nonce) });
            } else if (challenged && message?.type === 'ready') {
                authenticated = true;
                clearTimeout(handshakeTimer);
            } else {
                socket.destroy();
            }
            return;
        }
        reconnectDelayMs = INITIAL_RECONNECT_DELAY_MS;
        // 探测独立于 Worker 的启动和清理，回包只表示传输通道仍可用。
        if (message?.type === 'ping') {
            send({ type: 'pong', id: message.id });
            return;
        }
        commands = commands
            .then(() => {
                if (!socket.destroyed) {
                    return execute(message, socket, send);
                }
            })
            .catch((error) => {
                // 启动阶段出错时保留诊断，由宿主按当前会话处理。
                send({ type: 'error', session, detail: String(error?.stack || error) });
            });
    });
    socket.once('close', () => {
        clearTimeout(handshakeTimer);
        reader.close();
        if (shouldReconnect) {
            commands = commands.then(stopDisconnectedSession).catch(() => {
                // 已断开的连接无需发送清理结果，后续仍可启动新会话。
            });
            setTimeout(connect, reconnectDelayMs);
            reconnectDelayMs = Math.min(reconnectDelayMs * 2, MAX_RECONNECT_DELAY_MS);
        }
    });
}

// Qt 结束时由宿主统一回收运行时，避免 Node 的退出路径结束整个应用。
setInterval(() => {}, 60000);
connect();
