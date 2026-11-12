package rhine.music.database.basic

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * BASIC-89 lane C — factory for the Siren 3D preview PlatformView.
 *
 * The view type is frozen by the cross-lane contract:
 *   Flutter side: `basicSceneViewType` in lib/basic/scene_preview.dart
 *   Kotlin side:  [VIEW_TYPE] below (both are exactly "rhine/basic_scene").
 *
 * [install] is called once from MainActivity.configureFlutterEngine (owned by
 * lane B). Installing before any Dart frame exists is what makes the messenger
 * available to [BasicSceneView], whose constructor signature is frozen to
 * (context, viewId, args) by the contract.
 */
class BasicSceneViewFactory private constructor(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    init {
        // The view is constructed later by [create]; keep the engine messenger
        // in a process-wide slot instead of widening the frozen view ctor.
        BasicSceneMessenger.install(messenger)
    }

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        BasicSceneView(context, viewId, args)

    companion object {
        /** Must match the Dart constant exactly (contract v1). */
        const val VIEW_TYPE = "rhine/basic_scene"

        /**
         * Registers this factory on the engine's platform-view registry.
         * Called by MainActivity.configureFlutterEngine; B owns that call.
         */
        fun install(engine: FlutterEngine) {
            val messenger = engine.dartExecutor.binaryMessenger
            BasicSceneMessenger.install(messenger)
            engine.platformViewsController.registry.registerViewFactory(
                VIEW_TYPE,
                BasicSceneViewFactory(messenger),
            )
        }
    }
}

/**
 * Process-wide holder for the engine messenger.
 *
 * A Flutter app in this repository runs a single engine, and install() is
 * invoked from configureFlutterEngine before Dart can mount a PlatformView,
 * so one slot is sufficient. It is deliberately internal: no lane outside C
 * should depend on it.
 */
internal object BasicSceneMessenger {
    @Volatile
    private var messenger: BinaryMessenger? = null

    fun install(value: BinaryMessenger) {
        messenger = value
    }

    fun current(): BinaryMessenger? = messenger
}
