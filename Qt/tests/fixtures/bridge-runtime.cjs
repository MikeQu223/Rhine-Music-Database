// 所有真实桥接测试共用打包目录和随包 Node，不回退到源码依赖或系统运行时。
const fs = require('node:fs');
const path = require('node:path');

/** 返回待测桥接和随包 Node；缺少构建产物时立即报告具体文件。 */
function bridgeRuntime(directory = process.argv[2]) {
    if (!directory) {
        throw new Error('Bridge directory is required; run npm test to test the deployed application');
    }
    const bridge = path.resolve(directory);
    const runtime = path.join(bridge, process.platform === 'win32' ? 'node.exe' : 'node');
    for (const file of [runtime, path.join(bridge, 'worker.cjs')]) {
        if (!fs.existsSync(file)) {
            throw new Error('Missing packaged bridge resource; run npm run build first: ' + file);
        }
    }
    return { bridge, runtime };
}

/** 返回构建期的桥接依赖目录；发布包已不携带 node_modules，夹具从这里读取纯函数模块。 */
function bridgeSourceDirectory() {
    return path.resolve(__dirname, '../../../output/resources/MusicBridge');
}
module.exports = { bridgeRuntime, bridgeSourceDirectory };
