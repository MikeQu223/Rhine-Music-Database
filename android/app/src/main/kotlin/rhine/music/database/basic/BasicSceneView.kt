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
    private val theme: Double =
        ((argsMap["theme"] as? Number)?.toDouble() ?: 1.0).coerceIn(0.0, 1.0)

    private var channel: MethodChannel? = null
    private var disposed = false
    private var readyReported = false

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
            channel = MethodChannel(messenger, CHANNEL).also {
                it.setMethodCallHandler(::onMethodCall)
            }
        } ?: Log.e(
            TAG,
            "no BinaryMessenger; BasicSceneViewFactory.install(engine) must run in configureFlutterEngine",
        )

        webView.loadUrl(BasicSceneAssets.startUrl(modelAsset, initialYaw, theme))
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
                evaluate("window.__rhineBasicScene && window.__rhineBasicScene.setTheme(${formatNumber(value)})")
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
        }
        val outgoing = HashMap(payload)
        outgoing["viewId"] = viewId
        mainHandler.post {
            if (disposed) return@post
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
    private const val MODEL_DIR = "Assets/models/"

    val allowedModels: List<String> = listOf("archive-assembly.glb", "archive-cassette.glb")
    val allowedModelAssets: Set<String> = allowedModels.map { MODEL_DIR + it }.toSet()

    private val SEGMENT = Regex("^[A-Za-z0-9._-]+$")

    private const val CSP =
        "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; " +
            "img-src 'self' data: blob:; connect-src 'self' blob: data:; object-src 'none'; " +
            "base-uri 'none'; form-action 'none'"

    fun normalizeModel(value: Any?): String {
        val candidate = (value as? String)?.trim().orEmpty()
        return if (candidate in allowedModelAssets) candidate else DEFAULT_MODEL
    }

    fun startUrl(modelAsset: String, yaw: Double, theme: Double): String {
        val model = Uri.encode(modelAsset, "/")
        return "$ORIGIN/index.html?model=$model&yaw=${formatNumber(yaw)}" +
            "&theme=${formatNumber(theme.coerceIn(0.0, 1.0))}"
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
