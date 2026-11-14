package rhine.music.database.basic

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.IOException
import java.util.Locale

/**
 * BASIC-89 lane C — real, revocable 3D preview for Siren.
 *
 * The view hosts a plain android.webkit.WebView (no third-party plugin) whose
 * only permitted origin is the virtual [BasicSceneAssets.ORIGIN]. Every request
 * is answered by [BasicSceneAssets.responseFor] from the APK's flutter_assets
 * bundle; file:// and remote navigation never get a chance to load.
 *
 * Evidence for the scene itself (camera / materials / lights / floor) lives in
 * web/basic_preview/renderer.js and cites Qt/src line numbers there. This file
 * only owns the transport and the security boundary.
 *
 * Contract v1 (frozen):
 *   viewType        "rhine/basic_scene"        (BasicSceneViewFactory.VIEW_TYPE)
 *   MethodChannel   "rhine.music.database/basic_scene"
 *   Dart->native    setYaw {radians}, resetView, setTheme {theme}
 *   Dart->native v2 setScene {viewId, theme?, mode?}  (additive; mode is
 *                   "archive" | "detail" | "boot" and drives both the Qt
 *                   detail blend and the archive lens gate; an unknown value
 *                   normalises to "archive" and never to "boot")
 *   native->Dart    ready, selection, yaw, error  (each payload carries viewId)
 *   JS bridge       window.RhineSceneBridge.postMessage(json)
 */
@SuppressLint("AddJavascriptInterface", "SetJavaScriptEnabled")
class BasicSceneView(
    context: Context,
    private val viewId: Int,
    args: Any?,
) : PlatformView {

    private val hostContext: Context = context
    private val container = FrameLayout(context)
    private val webView = WebView(context)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val argsMap: Map<*, *> = args as? Map<*, *> ?: emptyMap<Any?, Any?>()

    private val modelAsset: String = BasicSceneAssets.normalizeModel(argsMap["model"])
    private val initialYaw: Double =
        normalizeYaw((argsMap["initialYaw"] as? Number)?.toDouble() ?: 0.0)
    private var theme: Double =
        ((argsMap["theme"] as? Number)?.toDouble() ?: 1.0).coerceIn(0.0, 1.0)
    private var mode: String = BasicSceneAssets.normalizeMode(argsMap["mode"])

    private var channel: MethodChannel? = null
    private var disposed = false
    private var readyReported = false

    /**
     * True once the page reported ready.
     *
     * Until then the renderer's bridge may not exist yet, so setScene/setTheme
     * only remember the newest values; they are applied in one replay as soon
     * as the page can accept them. A reload would be the obvious alternative
     * and is deliberately not used: it would throw away the mounted GLB and
     * violate the one-platform-view contract.
     */
    @Volatile
    private var sceneReady = false
    private var pendingSceneReplay = false

    init {
        container.addView(
            webView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        webView.setBackgroundColor(Color.rgb(0x11, 0x18, 0x1b))
        webView.overScrollMode = View.OVER_SCROLL_NEVER
        webView.isVerticalScrollBarEnabled = false
        webView.isHorizontalScrollBarEnabled = false
        webView.setOnLongClickListener { true }
        configureSettings(webView.settings)

        webView.webViewClient = SceneWebViewClient()
        webView.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean {
                Log.d(
                    TAG,
                    "js: ${consoleMessage.message()} @${consoleMessage.sourceId()}:${consoleMessage.lineNumber()}",
                )
                return true
            }
        }
        webView.addJavascriptInterface(SceneBridge(), BRIDGE_NAME)

        BasicSceneMessenger.current()?.let { messenger ->
            // One channel per platform view. The engine messenger keeps a single
            // handler per channel name, so a shared name let the newest view
            // replace every older one: an update addressed to a still-live view
            // could only be dropped by the receiver, and two previews could
            // never be updated independently.
            channel = MethodChannel(messenger, BasicSceneAssets.channelName(viewId)).also {
                it.setMethodCallHandler(::onMethodCall)
            }
        } ?: Log.e(
            TAG,
            "no BinaryMessenger; BasicSceneViewFactory.install(engine) must run in configureFlutterEngine",
        )

        webView.loadUrl(BasicSceneAssets.startUrl(modelAsset, initialYaw, theme, mode))
    }

    override fun getView(): View = container

    override fun dispose() {
        if (disposed) return
        disposed = true
        channel?.setMethodCallHandler(null)
        channel = null
        container.removeAllViews()
        webView.apply {
            stopLoading()
            removeJavascriptInterface(BRIDGE_NAME)
            webViewClient = WebViewClient()
            webChromeClient = null
            destroy()
        }
    }

    // ------------------------------------------------------------------
    // Dart -> native
    // ------------------------------------------------------------------

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("disposed", "BasicSceneView has been disposed", null)
            return
        }
        when (call.method) {
            "setYaw" -> {
                val radians = normalizeYaw(call.doubleArg("radians"))
                evaluate("window.__rhineBasicScene && window.__rhineBasicScene.setYaw(${formatNumber(radians)})")
                result.success(null)
            }
            "resetView" -> {
                evaluate("window.__rhineBasicScene && window.__rhineBasicScene.resetView()")
                result.success(null)
            }
            "setTheme" -> {
                val value = call.doubleArg("theme").coerceIn(0.0, 1.0)
                theme = value
                if (sceneReady) {
                    evaluate("window.__rhineBasicScene && window.__rhineBasicScene.setTheme(${formatNumber(value)})")
                }
                result.success(null)
            }
            "setScene" -> {
                val next = call.arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
                // The channel is already per view, so a view id can only be
                // wrong when the caller addressed a different preview. That is
                // a caller bug, not a no-op: reporting success would let a
                // dropped update look applied.
                val target = (next["viewId"] as? Number)?.toInt()
                if (target != null && target != viewId) {
                    result.error(
                        "wrong_view",
                        "setScene for view $target reached view $viewId",
                        null,
                    )
                    return
                }
                val requestedTheme = (next["theme"] as? Number)?.toDouble()
                if (requestedTheme != null && requestedTheme.isFinite()) {
                    theme = requestedTheme.coerceIn(0.0, 1.0)
                }
                if (next.containsKey("mode")) {
                    mode = BasicSceneAssets.normalizeMode(next["mode"])
                }
                if (sceneReady) {
                    pushScene()
                } else {
                    // Latest wins: the replay reads theme/mode when it runs, so
                    // an early update is neither lost nor queued twice.
                    pendingSceneReplay = true
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun MethodCall.doubleArg(key: String): Double =
        ((arguments as? Map<*, *>)?.get(key) as? Number)?.toDouble() ?: 0.0

    private fun evaluate(script: String) {
        if (disposed) return
        webView.evaluateJavascript(script, null)
    }

    /**
     * Applies the current theme/mode to a page that is already running.
     *
     * The creation values travel in the load URL; this is the incremental path
     * for everything after it, so a phase or theme change never reloads the
     * page and never recreates the platform view.
     */
    private fun pushScene() {
        evaluate(
            "window.__rhineBasicScene && window.__rhineBasicScene.setScene({" +
                "\"theme\":${formatNumber(theme)},\"mode\":\"$mode\"})",
        )
    }

    private fun replayPendingScene() {
        if (!pendingSceneReplay) return
        pendingSceneReplay = false
        pushScene()
    }

    // ------------------------------------------------------------------
    // JS bridge -> Dart
    // ------------------------------------------------------------------

    private inner class SceneBridge {
        @JavascriptInterface
        fun postMessage(message: String?) {
            if (disposed || message.isNullOrBlank() || message.length > MAX_BRIDGE_MESSAGE) return
            val parsed = try {
                JSONObject(message)
            } catch (error: Exception) {
                Log.w(TAG, "bridge: malformed json (${error.message})")
                return
            }
            val type = parsed.optString("type", "")
            val payload = sanitize(type, parsed) ?: return
            dispatch(type, payload)
        }
    }

    /**
     * Whitelists the bridge message types and copies only known, bounded fields
     * into the StandardMessageCodec payload. Anything else is dropped instead of
     * being forwarded to Dart.
     */
    private fun sanitize(type: String, raw: JSONObject): Map<String, Any?>? {
        val payload = HashMap<String, Any?>()
        payload["viewId"] = viewId
        when (type) {
            TYPE_READY -> {
                payload["model"] = raw.optString("model", modelAsset).take(200)
                payload["meshes"] = raw.optInt("meshes", 0).coerceAtLeast(0)
                payload["triangles"] = raw.optInt("triangles", 0).coerceAtLeast(0)
                payload["webgl2"] = raw.optBoolean("webgl2", false)
                val fov = raw.optDouble("fovDeg", Double.NaN)
                if (fov.isFinite()) payload["fovDeg"] = fov
                payload["yaw"] = normalizeYaw(raw.optDouble("yaw", 0.0))
                payload["parts"] = readParts(raw.optJSONArray("parts"))
                raw.optJSONObject("bounds")?.let { payload["bounds"] = jsonToMap(it) }
            }
            TYPE_SELECTION -> {
                payload["partName"] = raw.optString("partName", "").take(MAX_PART_NAME)
                payload["meshIndex"] = raw.optInt("meshIndex", -1)
                raw.optJSONObject("point")?.let { payload["point"] = jsonToMap(it) }
            }
            TYPE_YAW -> payload["radians"] = normalizeYaw(raw.optDouble("radians", 0.0))
            TYPE_ERROR -> {
                payload["stage"] = raw.optString("stage", "unknown").take(40)
                payload["message"] = raw.optString("message", "").take(MAX_ERROR_MESSAGE)
            }
            else -> return null
        }
        return payload
    }

    private fun readParts(array: JSONArray?): List<String> {
        if (array == null) return emptyList()
        val count = minOf(array.length(), MAX_PARTS)
        val parts = ArrayList<String>(count)
        for (index in 0 until count) {
            val name = array.optString(index, "").trim()
            if (name.isNotEmpty()) parts.add(name.take(MAX_PART_NAME))
        }
        return parts
    }

    private fun jsonToMap(source: JSONObject): HashMap<String, Any?> {
        val result = HashMap<String, Any?>()
        val keys = source.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            result[key] = jsonValue(source.opt(key))
        }
        return result
    }

    private fun jsonValue(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> jsonToMap(value)
        is JSONArray -> (0 until value.length()).map { index -> jsonValue(value.opt(index)) }
        else -> value
    }

    private fun dispatch(type: String, payload: Map<String, Any?>) {
        if (disposed) return
        if (type == TYPE_READY) {
            if (readyReported) return
            readyReported = true
            sceneReady = true
        }
        val outgoing = HashMap(payload)
        outgoing["viewId"] = viewId
        mainHandler.post {
            if (disposed) return@post
            if (type == TYPE_READY) {
                // This callback arrives on the JS bridge thread, where
                // evaluateJavascript is illegal, so the replay hops onto the UI
                // thread first - the same thread setScene writes its pending
                // flag from. It runs before the ready event reaches Dart, whose
                // ready handler then re-asserts the same values.
                replayPendingScene()
            }
            channel?.invokeMethod(type, outgoing)
        }
    }

    private fun dispatchError(stage: String, message: String) {
        dispatch(
            TYPE_ERROR,
            hashMapOf(
                "viewId" to viewId,
                "stage" to stage.take(40),
                "message" to message.take(MAX_ERROR_MESSAGE),
            ),
        )
    }

    // ------------------------------------------------------------------
    // Security boundary
    // ------------------------------------------------------------------

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureSettings(settings: WebSettings) {
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.databaseEnabled = false
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        settings.allowFileAccessFromFileURLs = false
        settings.allowUniversalAccessFromFileURLs = false
        settings.javaScriptCanOpenWindowsAutomatically = false
        settings.setSupportMultipleWindows(false)
        settings.setSupportZoom(false)
        settings.builtInZoomControls = false
        settings.displayZoomControls = false
        settings.mediaPlaybackRequiresUserGesture = true
        settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        settings.cacheMode = WebSettings.LOAD_DEFAULT
        settings.setGeolocationEnabled(false)
        settings.safeBrowsingEnabled = false
    }

    private inner class SceneWebViewClient : WebViewClient() {
        override fun shouldInterceptRequest(
            view: WebView,
            request: WebResourceRequest,
        ): WebResourceResponse = BasicSceneAssets.responseFor(hostContext, request.url)

        override fun shouldOverrideUrlLoading(
            view: WebView,
            request: WebResourceRequest,
        ): Boolean {
            val allowed = BasicSceneAssets.isAllowed(request.url)
            if (!allowed) Log.w(TAG, "blocked navigation: ${request.url}")
            return !allowed
        }

        @Suppress("DEPRECATION")
        override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean {
            val uri = try {
                Uri.parse(url)
            } catch (error: Exception) {
                return true
            }
            return !BasicSceneAssets.isAllowed(uri)
        }

        override fun onReceivedError(
            view: WebView,
            request: WebResourceRequest,
            error: WebResourceError,
        ) {
            if (!request.isForMainFrame) return
            dispatchError("network", "WebView error ${error.errorCode}: ${error.description}")
        }

        override fun onReceivedHttpError(
            view: WebView,
            request: WebResourceRequest,
            errorResponse: WebResourceResponse,
        ) {
            if (!request.isForMainFrame) return
            dispatchError("http", "HTTP ${errorResponse.statusCode} for ${request.url}")
        }

        override fun onRenderProcessGone(
            view: WebView,
            detail: RenderProcessGoneDetail,
        ): Boolean {
            dispatchError(
                "renderer",
                "WebView render process gone (crashed=${detail.didCrash()})",
            )
            return true
        }
    }

    companion object {
        private const val TAG = "BasicSceneView"

        /** MethodChannel shared with lib/basic/scene_preview.dart. */
        const val CHANNEL = "rhine.music.database/basic_scene"

        /** JavaScript interface name exposed to the bundled page. */
        const val BRIDGE_NAME = "RhineSceneBridge"

        const val TYPE_READY = "ready"
        const val TYPE_SELECTION = "selection"
        const val TYPE_YAW = "yaw"
        const val TYPE_ERROR = "error"

        private const val MAX_BRIDGE_MESSAGE = 32 * 1024
        private const val MAX_PART_NAME = 120
        private const val MAX_PARTS = 64
        private const val MAX_ERROR_MESSAGE = 400
    }
}

private fun formatNumber(value: Double): String = String.format(Locale.US, "%.6f", value)

private fun normalizeYaw(value: Double): Double =
    if (!value.isFinite()) 0.0 else Math.atan2(Math.sin(value), Math.cos(value))

/**
 * The only origin the preview WebView may load, plus the exact asset mapping
 * used by shouldInterceptRequest. Kept in this file so the security boundary
 * and the transport live together; every deny path returns a real
 * WebResourceResponse (never null) with a 4xx status.
 */
internal object BasicSceneAssets {
    const val SCHEME = "https"
    const val HOST = "basic-preview.local"
    const val ORIGIN = "https://basic-preview.local"

    const val ASSET_ROOT = "web/basic_preview"
    const val FLUTTER_ASSET_PREFIX = "flutter_assets/"
    const val DEFAULT_MODEL = "Assets/models/archive-assembly.glb"
    const val MODE_ARCHIVE = "archive"
    const val MODE_DETAIL = "detail"
    const val MODE_BOOT = "boot"
    private const val MODEL_DIR = "Assets/models/"

    val allowedModels: List<String> = listOf("archive-assembly.glb", "archive-cassette.glb")
    val allowedModelAssets: Set<String> = allowedModels.map { MODEL_DIR + it }.toSet()

    private val SEGMENT = Regex("^[A-Za-z0-9._-]+$")

    private const val CSP =
        "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; " +
            "img-src 'self' data: blob:; connect-src 'self' blob: data:; object-src 'none'; " +
            "base-uri 'none'; form-action 'none'"

    /**
     * Channel name for one platform view.
     *
     * The suffix is the platform view id: Dart derives the same name from the id
     * it was handed (lib/basic/scene_preview.dart `basicSceneChannelFor`), which
     * is what gives every mounted preview its own handler slot. Both parts must
     * stay in sync — the transport test asserts the shared literal.
     */
    fun channelName(viewId: Int): String = "${BasicSceneView.CHANNEL}/$viewId"

    fun normalizeModel(value: Any?): String {
        val candidate = (value as? String)?.trim().orEmpty()
        return if (candidate in allowedModelAssets) candidate else DEFAULT_MODEL
    }

    /**
     * Exactly the three strings Qt compares against (NativeSceneCamera.cpp:101
     * `m_mode == "boot"`, NativeScene.cpp:188), with no trimming: " boot " is
     * not boot here either, and every other spelling — including an absent
     * mode — falls back to archive. Trimming would let a malformed value reach
     * the renderer as an explicit boot while Dart already decoded it as
     * archive, so the two layers would disagree about the same mount.
     */
    fun normalizeMode(value: Any?): String = when (value) {
        MODE_BOOT -> MODE_BOOT
        MODE_DETAIL -> MODE_DETAIL
        else -> MODE_ARCHIVE
    }

    fun startUrl(
        modelAsset: String,
        yaw: Double,
        theme: Double,
        mode: String = MODE_ARCHIVE,
    ): String {
        val model = Uri.encode(modelAsset, "/")
        val resolved = normalizeMode(mode)
        val detail = if (resolved == MODE_DETAIL) 1 else 0
        // The detail flag stays the legacy creation hint; the mode itself has
        // to travel too, because only an explicit mode can separate boot from
        // archive (Qt/src/NativeSceneCamera.cpp:101). An unknown mode was
        // already normalised to archive above, so the URL cannot smuggle boot.
        return "$ORIGIN/index.html?model=$model&yaw=${formatNumber(yaw)}" +
            "&theme=${formatNumber(theme.coerceIn(0.0, 1.0))}&detail=$detail&mode=$resolved"
    }

    fun isAllowed(uri: Uri): Boolean {
        if (!SCHEME.equals(uri.scheme, ignoreCase = true)) return false
        if (!HOST.equals(uri.host, ignoreCase = true)) return false
        val port = uri.port
        if (port != -1 && port != 443) return false
        if (!uri.userInfo.isNullOrEmpty()) return false
        val path = uri.path ?: return false
        if (path.isEmpty() || path.length > 512) return false
        if (path == "/" || path == "/index.html") return true
        if (!path.startsWith("/")) return false
        if (path.contains("//")) return false
        val segments = path.substring(1).split('/')
        if (segments.isEmpty()) return false
        for (segment in segments) {
            if (segment.isEmpty() || segment == "." || segment == "..") return false
            if (!SEGMENT.matches(segment)) return false
        }
        return true
    }

    fun assetKeyFor(uri: Uri): String? {
        if (!isAllowed(uri)) return null
        val path = uri.path ?: return null
        if (path == "/") return "$ASSET_ROOT/index.html"
        if (path.startsWith("/$MODEL_DIR")) {
            val key = path.substring(1)
            return if (key in allowedModelAssets) key else null
        }
        if (path == "/index.html" || path == "/renderer.js" || path.startsWith("/vendor/three/")) {
            return ASSET_ROOT + path
        }
        return null
    }

    fun mimeTypeFor(assetKey: String): String? {
        val extension = assetKey.substringAfterLast('.', "").lowercase(Locale.US)
        return when (extension) {
            "html" -> "text/html"
            "js", "mjs" -> "text/javascript"
            "css" -> "text/css"
            "json" -> "application/json"
            "glb" -> "model/gltf-binary"
            "gltf" -> "model/gltf+json"
            "wasm" -> "application/wasm"
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "svg" -> "image/svg+xml"
            "txt", "md" -> "text/plain"
            else -> null
        }
    }

    fun responseFor(context: Context, uri: Uri): WebResourceResponse {
        val assetKey = assetKeyFor(uri) ?: return errorResponse(403, "Forbidden")
        val mimeType = mimeTypeFor(assetKey) ?: return errorResponse(415, "Unsupported Media Type")
        return try {
            val stream = context.assets.open(FLUTTER_ASSET_PREFIX + assetKey)
            val headers = HashMap<String, String>()
            headers["Cache-Control"] = "no-store"
            headers["X-Content-Type-Options"] = "nosniff"
            if (mimeType == "text/html") headers["Content-Security-Policy"] = CSP
            WebResourceResponse(mimeType, charsetFor(mimeType), 200, "OK", headers, stream)
        } catch (error: IOException) {
            Log.w(TAG_ASSETS, "missing asset $assetKey: ${error.message}")
            errorResponse(404, "Not Found")
        }
    }

    private fun charsetFor(mimeType: String): String? = when (mimeType) {
        "text/html", "text/javascript", "text/css", "text/plain", "application/json" -> "utf-8"
        else -> null
    }

    private fun errorResponse(status: Int, reason: String): WebResourceResponse {
        val headers = HashMap<String, String>()
        headers["Cache-Control"] = "no-store"
        headers["X-Content-Type-Options"] = "nosniff"
        val body = "$status $reason".toByteArray(Charsets.UTF_8)
        return WebResourceResponse(
            "text/plain",
            "utf-8",
            status,
            reason,
            headers,
            ByteArrayInputStream(body),
        )
    }

    private const val TAG_ASSETS = "BasicSceneAssets"
}
