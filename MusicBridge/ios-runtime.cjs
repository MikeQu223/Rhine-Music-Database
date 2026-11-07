// iOS 的 Node 主线程只负责传输；每个音乐会话使用独立 Worker，注销时彻底销毁。
const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const { Worker } = require('node:worker_threads');
const socket = net.connect(Number(process.argv[2]), '127.0.0.1');
let worker;
let session;
let commands = Promise.resolve();

function send(message) {
    socket.write(JSON.stringify(message) + '\n');
}

socket.on('connect', () => send({ token: process.argv[3] }));
// Qt 结束时保持运行时存活到进程终止，禁止 Node 的退出路径结束整个应用。
socket.on('error', () => {
    // Qt 已退出时保持静默，由宿主进程统一回收运行时。
});
setInterval(() => {}, 60000);

/** 串行销毁旧 Worker 后才建立新会话，旧连接和模块全局状态不会进入新账号。 */
async function execute(message) {
    if (message.type === 'start') {
        if (worker) {
            await worker.terminate();
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
            } catch {
            }
        }
        worker = new Worker(message.script, {
            env: { ...process.env, ...message.env },
            workerData: message.env || {},
            stdin: true,
            stdout: true,
            stderr: true,
        });
        const instance = worker;
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

readline.createInterface({ input: socket }).on('line', (line) => {
    commands = commands
        .then(() => execute(JSON.parse(line)))
        .catch((error) => {
            // start 阶段的同步异常（路径不存在、参数非法）在这里出现；不带详情就等于黑箱。
            send({ type: 'error', session, detail: String(error?.stack || error) });
        });
});
