package rhine.music.database.porting

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * `rhine.music/plugin_bridge` 通道：Dart 侧只用两个方法。
 *
 *  - `status`：运行时是否就绪、资源根、插件根、最近错误（面板上要显示真话）。
 *  - `request`：`{provider, operation, args}` → `{ok, value|error, cookies}`，
 *    等价于 Qt `MusicApi::call` 的 `send("/native/<provider>/<operation>", {{args}})`。
 *
 * 通道回调必须在主线程回复，但 Node 传输是阻塞的，所以真正的工作丢给单线程池；
 * 该线程池只做排队，真正的 IO 在 [PluginBridge] 自己的线程里。
 */
object PluginBridgeChannel {
    private const val channelName = "rhine.music/plugin_bridge"
    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "rhine-plugin-channel").apply { isDaemon = true }
    }

    fun install(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(PluginBridge.status(context))
                // Qt 的 `ProviderRegistry` 只扫 `<files>/MusicBridge/local-plugins`，
                // 而插件装在外部目录；Dart 侧要把 manifest 软链过去（封面域名白名单
                // 由 Qt 的 descriptor 决定），所以这里把 files 根给出去。
                "filesDir" -> result.success(context.filesDir.absolutePath)
                "request" -> handleRequest(call, result, context)
                else -> result.notImplemented()
            }
        }
    }

    private fun handleRequest(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val provider = call.argument<String>("provider") ?: ""
        val operation = call.argument<String>("operation") ?: ""
        @Suppress("UNCHECKED_CAST")
        // 位置参数数组（Qt `MusicApi::call` 的 `arguments` 就是数组）。
        val args: Any? = call.argument<Any?>("args")
        // host.cjs 期望 `{name: value}` 对象（数组会被摊成数字键）。
        val cookies: Map<String, String> =
            (call.argument<Map<String, String>>("cookies")) ?: emptyMap()
        if (provider.isEmpty() || operation.isEmpty()) {
            result.success(mapOf("ok" to false, "error" to "缺少 provider 或 operation"))
            return
        }
        worker.execute {
            val reply = runCatching { PluginBridge.request(context, provider, operation, args, cookies) }
                .getOrElse { error ->
                    mapOf("ok" to false, "error" to (error.message ?: "插件请求失败"))
                }
            android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(reply) }
        }
    }
}
