package rhine.music.database.porting

import android.content.Context
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * 插件平台的 Node 传输桥。
 *
 * 协议真值是 `MusicBridge/ios-runtime.cjs`：内嵌 Node 启动后主动连回本机的
 * `ServerSocket`，首帧发 `{token}` 做握手，之后双方都按「一行一个 JSON」收发。
 * 业务请求走 `{id, route, params:{args}}`，响应回来是 `{id, body, cookies}`；
 * `body.code` 缺省 200，非 200 视为失败（`body.errorKey` / `body.message`）。
 *
 * 这条通道只服务**用户安装的插件平台**（siren/local 是 Qt 内置，不需要它）。
 */
object PluginBridge {
    private const val tag = "RhinePluginBridge"
    private const val handshakeTimeoutMs = 90_000L
    private const val requestTimeoutMs = 60_000L

    private val io = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "rhine-plugin-bridge").apply { isDaemon = true }
    }
    private val pending = ConcurrentHashMap<Int, CompletableFuture<JSONObject>>()
    private val sequence = AtomicInteger(1)
    private val outbox = LinkedBlockingQueue<String>()

    @Volatile private var server: ServerSocket? = null
    @Volatile private var writer: BufferedWriter? = null
    @Volatile private var session: String = ""
    @Volatile private var lastError: String = ""

    /** 启动互斥：同一时刻只有一次 `node::Start`，其余调用等它握手完成。 */
    private val startLock = Any()
    @Volatile private var starting = false
    @Volatile private var ready = java.util.concurrent.CountDownLatch(1)

    /** 资源根：Qt 侧 `AndroidAssets` 解包出来的 `MusicBridge/` 就在这下面。 */
    fun resourcesRoot(context: Context): File = File(context.filesDir, "resources")

    /** 用户插件目录：与 `PluginManager` 安装的位置保持一致（外部 `file/plugin`）。 */
    fun pluginRoot(context: Context): File {
        val external = context.getExternalFilesDir(null)
        return external?.parentFile?.let { File(File(it, "file"), "plugin") }
            ?: File(context.filesDir, "plugins")
    }

    fun status(context: Context): Map<String, Any?> {
        val root = resourcesRoot(context)
        return mapOf(
            "running" to (writer != null),
            "session" to session,
            "error" to lastError,
            "resources" to root.absolutePath,
            "plugins" to pluginRoot(context).absolutePath,
            "worker" to File(root, "MusicBridge/worker.cjs").exists(),
        )
    }

    /**
     * 首次调用才真正起 Node；之后只回报状态。
     *
     * 第一次调用会**阻塞到握手完成**（Node 在这台机器上要 ~90s）：否则并发的第二个
     * 请求会看到 `running=false` 而被判成「插件运行时不可用」——真机上表现为登录页
     * 一边显示二维码、一边把 `account()` 判成未登录。
     */
    fun ensureStarted(context: Context): Map<String, Any?> {
        if (writer != null) {
            return status(context)
        }
        val latch: java.util.concurrent.CountDownLatch
        synchronized(startLock) {
            if (writer != null) {
                return status(context)
            }
            if (!starting) {
                starting = true
                ready = java.util.concurrent.CountDownLatch(1)
                spawnLocked(context)
            }
            latch = ready
        }
        latch.await(handshakeTimeoutMs + 10_000L, TimeUnit.MILLISECONDS)
        return status(context)
    }

    /** 真正的启动动作；调用方必须持有 `startLock` 且已置 `starting = true`。 */
    private fun spawnLocked(context: Context) {
        val root = resourcesRoot(context)
        val runtime = File(root, "MusicBridge/ios-runtime.cjs")
        val worker = File(root, "MusicBridge/worker.cjs")
        if (!runtime.exists() || !worker.exists()) {
            lastError = "缺少 MusicBridge 运行时：${runtime.absolutePath}"
            finishStart()
            return
        }
        val plugins = pluginRoot(context)
        val disabled = readDisabledPlugins(plugins)
        val token = UUID.randomUUID().toString().replace("-", "")
        val socket = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        server = socket
        session = UUID.randomUUID().toString()
        lastError = ""
        val started = NodeHost.startNode(runtime.absolutePath, socket.localPort, token, root.absolutePath)
        if (!started) {
            lastError = "Node 运行时启动失败"
            runCatching { socket.close() }
            server = null
            finishStart()
            return
        }
        io.execute {
            try {
                socket.soTimeout = handshakeTimeoutMs.toInt()
                val client: Socket = socket.accept()
                client.soTimeout = 0
                val reader = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.UTF_8))
                val line = reader.readLine()
                if (line == null || !line.contains(token)) {
                    lastError = "运行时握手失败"
                    runCatching { client.close() }
                    finishStart()
                    return@execute
                }
                val out = BufferedWriter(OutputStreamWriter(client.getOutputStream(), Charsets.UTF_8))
                synchronized(startLock) { writer = out; starting = false }
                ready.countDown()
                Log.i(tag, "handshake ok, port=${socket.localPort}")
                out.write(JSONObject(
                    mapOf(
                        "type" to "start",
                        "session" to session,
                        "script" to worker.absolutePath,
                        "stderrLog" to true,
                        "env" to mapOf(
                            "RHINE_USER_PLUGINS" to plugins.absolutePath,
                            "RHINE_DISABLED_PLUGINS" to disabled,
                            "TMPDIR" to File(context.cacheDir, "rhine-node").apply { mkdirs() }.absolutePath,
                        ),
                    )
                ).toString())
                out.write("\n")
                out.flush()
                runCatching { socket.close() }  // 握手后不再需要监听套接字
                // 写线程：所有请求都排队到这里，避免多线程写乱序。
                val writerThread = Thread({
                    while (true) {
                        val payload = outbox.take()
                        // 真值：`MusicBridge/ios-runtime.cjs` 只把 `{type:'input',data:base64}`
                        // 写进 worker 的 stdin；业务请求必须先 base64 再套一层信封。
                        val envelope = JSONObject(
                            mapOf(
                                "type" to "input",
                                "session" to session,
                                "data" to Base64.encodeToString(
                                    (payload + "\n").toByteArray(Charsets.UTF_8),
                                    Base64.NO_WRAP,
                                ),
                            )
                        ).toString()
                        out.write(envelope)
                        out.write("\n")
                        out.flush()
                    }
                }, "rhine-plugin-writer").apply { isDaemon = true }
                writerThread.start()
                while (true) {
                    val reply = reader.readLine() ?: break
                    if (reply.isBlank()) continue
                    val json = runCatching { JSONObject(reply) }.getOrNull() ?: continue
                    when (json.optString("type")) {
                        "output" -> {
                            val text = runCatching {
                                String(Base64.decode(json.optString("data"), Base64.NO_WRAP), Charsets.UTF_8)
                            }.getOrNull() ?: ""
                            for (line in text.lineSequence()) {
                                if (line.isBlank()) continue
                                val payload = runCatching { JSONObject(line) }.getOrNull() ?: continue
                                if (payload.has("id")) {
                                    pending.remove(payload.optInt("id"))?.complete(payload)
                                }
                            }
                        }
                        "error" -> {
                            lastError = json.optString("detail").take(200)
                            Log.w(tag, "runtime error: ${json.optString("detail").take(400)}")
                        }
                        "finished" -> Log.w(tag, "worker exited: ${json.optInt("exitCode")}")
                        "started" -> Log.i(tag, "worker online")
                        "stderr" -> {
                            val text = runCatching {
                                String(Base64.decode(json.optString("data"), Base64.NO_WRAP), Charsets.UTF_8)
                            }.getOrDefault("")
                            Log.w(tag, "worker stderr: ${text.take(400)}")
                        }
                        else -> Unit
                    }
                }
            } catch (error: Throwable) {
                lastError = "传输中断：${error.message}"
                Log.w(tag, "bridge loop ended", error)
            } finally {
                synchronized(startLock) { writer = null; starting = false }
                ready.countDown()
                pending.values.forEach { it.completeExceptionally(IllegalStateException(lastError)) }
                pending.clear()
            }
        }
    }

    /** 启动失败/中断时收尾：放开互斥并唤醒等待者。 */
    private fun finishStart() {
        synchronized(startLock) { starting = false }
        ready.countDown()
    }

    /** 发一条 `/native/<provider>/<operation>` 请求，返回 `body`（已校验 code）。 */
    fun request(
        context: Context,
        provider: String,
        operation: String,
        args: Any?,
        cookies: Map<String, String>,
    ): Map<String, Any?> {
        val ready = ensureStarted(context)
        if (ready["running"] != true) {
            return mapOf("ok" to false, "error" to (lastError.ifEmpty { "插件运行时不可用" }))
        }
        val id = sequence.getAndIncrement()
        val future = CompletableFuture<JSONObject>()
        pending[id] = future
        outbox.put(
            JSONObject(
                mapOf(
                    "id" to id,
                    "route" to "/native/$provider/$operation",
                    "params" to mapOf("args" to args),
                    "cookies" to cookies,
                )
            ).toString()
        )
        val reply = try {
            future.get(requestTimeoutMs, TimeUnit.MILLISECONDS)
        } catch (error: Throwable) {
            pending.remove(id)
            return mapOf("ok" to false, "error" to (lastError.ifEmpty { error.message ?: "插件请求超时" }))
        }
        val body = reply.optJSONObject("body") ?: JSONObject()
        val code = if (body.has("code")) body.optInt("code", 200) else 200
        if (code != 200) {
            val message = body.optString("message").ifEmpty { body.optString("errorKey") }
            return mapOf(
                "ok" to false,
                "error" to message.ifEmpty { "插件返回 $code" },
                "errorKey" to body.optString("errorKey"),
                "code" to code,
            )
        }
        val value = body.opt("value")
        return mapOf(
            "ok" to true,
            "value" to jsonToPlain(value),
            "cookies" to jsonToPlain(reply.opt("cookies")),
        )
    }

    private fun jsonToPlain(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { jsonToPlain(value.opt(it)) }
        is org.json.JSONArray -> (0 until value.length()).map { jsonToPlain(value.opt(it)) }
        else -> value
    }

    private fun readDisabledPlugins(root: File): String {
        val state = File(root, "plugins-state.json")
        if (!state.exists()) return ""
        return runCatching {
            val json = JSONObject(state.readText())
            val array = json.optJSONArray("disabled") ?: return ""
            (0 until array.length()).joinToString(",") { array.optString(it) }
        }.getOrDefault("")
    }
}
