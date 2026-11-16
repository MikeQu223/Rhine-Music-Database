package rhine.music.database.porting

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * SETTINGS-148：Flutter 基本版设置面板的真实持久化 / 版本真值 / 外链通道。
 *
 * 为什么需要这条通道：
 *  - Qt 侧设置落在 QSettings（Qt/src/Host.cpp:1061-1106 的 panel/<key>），Flutter 基本版
 *    不能在 Dart 里猜 QSettings 的 Android 绝对路径（T07 契约 §5.1 把它列为 DEVICE_BLOCKED），
 *    也不引入 shared_preferences 之外的新依赖。因此宿主自己开一个 SharedPreferences 文件，
 *    由 Dart 侧 PreferencePort 逐键读写——这是**真实落盘**，进程重启后读回同一份值。
 *  - 键空间与 Qt 完全一致：Dart 侧始终传 `<prefix><panel key>`（Host.cpp:1075 的 "panel/" + key），
 *    本文件不加工、不改写、不补默认值，只做存取。缺键返回 null，与 Host::preference 的
 *    「缺键 = 空」在 Dart 侧 PreferenceStore 里统一收敛。
 *  - 版本真值不猜：versionName / versionCode / debuggable / packageName / applicationId 全部来自
 *    PackageManager 对**本 APK** 的读取；Dart 侧不写死任何版本号。
 *  - 外链（项目与开源参考 8 条）：Qt 用 QDesktopServices::openUrl（NativeHudMusic.cpp:266-292
 *    的那 8 个 URL）。Android 上的等价物是 ACTION_VIEW；本文件先 resolve 再启动，
 *    没有可处理的 App 时返回 false，由 Dart 侧如实提示，不假装打开成功。
 *
 * 通道名是跨语言契约：Dart 侧 lib/basic/basic_settings_store.dart 的
 * basicSettingsChannelName 与下面 CHANNEL 必须逐字相同。
 */
class BasicSettingsChannel private constructor(
    private val contextProvider: () -> Context,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "rhine.music.database/basic_settings"

        /** 自有偏好文件名：与 Qt 的 QSettings 文件互不覆盖（也互不冒充）。 */
        const val PREFERENCES_NAME = "rhine_basic_settings"

        private const val TAG = "RhineBasicSettings"

        @Volatile
        private var installed: BasicSettingsChannel? = null

        /** install 时装上的 messenger；engine 重建后据此把 handler 迁到新 messenger。 */
        @Volatile
        private var installedMessenger: BinaryMessenger? = null

        /**
         * 装配一次。传 contextProvider 而不是 Context：通道对象不长期握着 Activity
         * （Application context 可以，Activity 不行——那会把已销毁的宿主钉在进程里）。
         */
        fun install(messenger: BinaryMessenger, contextProvider: () -> Context): BasicSettingsChannel {
            val existing = installed
            if (existing != null) {
                val previous = installedMessenger
                if (previous === messenger) {
                    return existing
                }
                //  新 engine（Activity 重建 / 旋转）：把同一个 handler 迁到新 messenger 上。
                //  不迁的话 handler 挂在已销毁的 engine 上，重建后版本/外链调用全变成
                //  MissingPluginException——真机上表现为版本行回到「未知版本」。
                if (previous != null) {
                    MethodChannel(previous, CHANNEL).setMethodCallHandler(null)
                }
                MethodChannel(messenger, CHANNEL).setMethodCallHandler(existing)
                installedMessenger = messenger
                return existing
            }
            val channel = BasicSettingsChannel(contextProvider)
            val methodChannel = MethodChannel(messenger, CHANNEL)
            methodChannel.setMethodCallHandler(channel)
            installed = channel
            installedMessenger = messenger
            return channel
        }

        fun uninstall(messenger: BinaryMessenger?) {
            if (installed == null) {
                return
            }
            val owner = installedMessenger
            //  归属校验：旧宿主的 onDestroy 不能拆掉新宿主刚装上的通道（Activity 重建时
            //  安装与销毁的先后顺序不保证）。只有 "要卸的 messenger 就是当前 owner" 才卸。
            if (owner != null && messenger != null && owner !== messenger) {
                return
            }
            val target = owner ?: messenger
            if (target != null) {
                MethodChannel(target, CHANNEL).setMethodCallHandler(null)
            }
            installed = null
            installedMessenger = null
        }
    }

    private fun prefs() = contextProvider().getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "read" -> {
                    val key = call.argument<String>("key")
                    if (key == null) {
                        result.error("bad_args", "read 需要 key", null)
                        return
                    }
                    result.success(prefs().getString(key, null))
                }
                "write" -> {
                    val key = call.argument<String>("key")
                    val value = call.argument<String>("value")
                    if (key == null || value == null) {
                        result.error("bad_args", "write 需要 key 与 value", null)
                        return
                    }
                    // commit 而不是 apply：设置面板必须在返回 true 之后读回同一个值。
                    val ok = prefs().edit().putString(key, value).commit()
                    result.success(ok)
                }
                "remove" -> {
                    val key = call.argument<String>("key")
                    if (key == null) {
                        result.error("bad_args", "remove 需要 key", null)
                        return
                    }
                    prefs().edit().remove(key).commit()
                    result.success(null)
                }
                "all" -> {
                    val out = HashMap<String, String>()
                    for ((k, v) in prefs().all) {
                        if (v is String) {
                            out[k] = v
                        }
                    }
                    result.success(out)
                }
                "packageInfo" -> result.success(packageInfo())
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    if (url == null || url.isEmpty()) {
                        result.error("bad_args", "openUrl 需要 url", null)
                        return
                    }
                    result.success(openUrl(url))
                }
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            // 不把异常吞成"成功"：设置存取失败必须能被 Dart 看见（PreferenceStore 会把它
            // 收敛成 write=false / read=''，那正是 Qt 的静默丢弃语义）。
            Log.w(TAG, "method " + call.method + " failed", error)
            result.error("settings_failed", error.toString(), null)
        }
    }

    private fun packageInfo(): Map<String, Any?> {
        val context = contextProvider()
        val pm = context.packageManager
        val info = pm.getPackageInfo(context.packageName, 0)
        val versionName = info.versionName ?: ""
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        val applicationInfo = context.applicationInfo
        val debuggable = (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        return mapOf(
            "packageName" to context.packageName,
            "versionName" to versionName,
            "versionCode" to versionCode,
            "debuggable" to debuggable,
        )
    }

    private fun openUrl(url: String): Boolean {
        val context = contextProvider()
        val uri = Uri.parse(url)
        val intent = Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val resolved = context.packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
        if (resolved == null) {
            Log.w(TAG, "openUrl: no activity for " + url)
            return false
        }
        context.startActivity(intent)
        return true
    }
}
