'use strict';

const { createInterface } = require('node:readline');
const { parentPort } = require('node:worker_threads');
const { executePluginControl } = require('./plugin-control.cjs');

function controlError(error) {
    const code = typeof error?.code === 'string' && /^[a-z0-9.-]{1,80}$/.test(error.code) ? error.code : '';
    if (!code) {
        return { code: 'plugin.control', message: '插件校验未能完成' };
    }
    return { code, message: String(error.message).slice(0, 600) };
}

async function run(request, send) {
    let response;
    try {
        response = { result: await executePluginControl(request) };
    } catch (error) {
        response = { error: controlError(error) };
    }
    send(response);
}

// 初始化中第三方日志不进入校验 IPC，实际结果使用预先取得的发送函数。
if (parentPort) {
    parentPort.once('message', ({ request, reply }) => {
        const send = reply.postMessage.bind(reply);
        run(request, send);
    });
} else {
    const write = process.stdout.write.bind(process.stdout);
    const send = (value) => {
        write(JSON.stringify(value) + '\n', () => process.exit(0));
    };
    const input = createInterface({ input: process.stdin });
    input.once('line', (line) => {
        input.close();
        let request;
        try {
            request = JSON.parse(line);
        } catch {
            send({ error: { code: 'plugin.control', message: '插件校验请求无效' } });
            return;
        }
        process.stdout.write = () => true;
        run(request, send);
    });
}
