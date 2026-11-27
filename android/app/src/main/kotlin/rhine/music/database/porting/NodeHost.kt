package rhine.music.database.porting

/**
 * `libnodehost.so` 的 Kotlin 接缝：只负责把 `node::Start` 拉起来。
 *
 * 原生侧契约照抄 `Qt/src/BridgeProcessAndroid.cpp:96-152`：argv 是同一块可写缓冲里的
 * 4 段 NUL 分隔串、8 MiB 线程栈、`launch` 幂等。真正的 IPC（TCP 握手 + 行协议）在
 * [PluginBridge] 里，与 `MusicBridge/ios-runtime.cjs` 对齐。
 */
object NodeHost {
    init {
        System.loadLibrary("nodehost")
    }

    /**
     * 启动内嵌 Node 跑 [script]，监听 [port]，用 [token] 做首帧握手。
     *
     * @param cwd 工作目录（资源根，`worker.cjs` 的相对路径以它为基准）。
     * @return 线程是否成功创建；已启动过时直接返回 true（幂等）。
     */
    external fun startNode(script: String, port: Int, token: String, cwd: String): Boolean
}
