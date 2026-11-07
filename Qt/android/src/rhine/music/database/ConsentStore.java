package rhine.music.database;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Log;

import com.microsoft.clarity.Clarity;
import com.microsoft.clarity.ClarityConfig;
import com.microsoft.clarity.models.LogLevel;
import com.tencent.bugly.crashreport.CrashReport;

/**
 * 数据传输许可的存储与 SDK 启动闸门。
 *
 * 未同意时，任何会联网上报的 SDK 都不会初始化——不是"初始化后再暂停"，而是根本不创建。
 * 只有用户点了"同意"才会写入持久标记；"其他地区"（含判定超时）只是**本次运行**放行，
 * 下次启动会重新判定——地区判定不缓存，这是有意的。
 * 进程被后台任务唤醒（不经过 ConsentActivity）时，没有同意记录就不启动 SDK：宁可少采集。
 *
 * 两个 SDK 的适用范围不同：Clarity 在所有放行的情况下启动；Bugly 只在中国大陆用户
 * 同意后启动——欧盟地区的许可文案只写了 Clarity，其他地区则没有许可流程。
 */
public final class ConsentStore {
    private static final String TAG = "RhineConsent";
    private static final String PREFS = "rhine-consent";
    private static final String KEY_GRANTED = "granted";
    private static final String KEY_REGION = "region";
    private static final String CLARITY_PROJECT_ID = "z8vbz4b078";

    /** Bugly 控制台的 AppID。AppKey 只用于后台开放接口/符号表上传，不参与客户端初始化。 */
    private static final String BUGLY_APP_ID = "22c01c69b9";
    private static final boolean BUGLY_DEBUG = false;
    /**
     * native 崩溃由 Bugly 接管：它注册自己的 SIGSEGV/SIGBUS/SIGABRT handler 并上报
     * tombstone 现场。为此 Qt/src/main.cpp 里的 RHINE-SIGNAL 诊断链默认不编译
     * （RHINE_ANDROID_SIGNAL_DIAG=0）——两套 handler 抢同一组信号会让崩溃现场不可读。
     * 需要离线抓自有链现场时，把这个开关改回 false，并把 main.cpp 的宏改成 1。
     */
    private static final boolean BUGLY_NATIVE_MONITOR = true;

    // 分开记幂等标志：先按"其他地区"启动过 Clarity，随后又拿到 CN 同意时，
    // Bugly 不能被前一个标志挡掉。
    private static boolean clarityStarted;
    private static boolean buglyStarted;

    private ConsentStore() {
    }

    private static SharedPreferences preferences(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    public static boolean isGranted(Context context) {
        return preferences(context).getBoolean(KEY_GRANTED, false);
    }

    /**
     * 同意时记录的地区，仅用于排查。地区判定**不缓存**：未同意的每次启动都会重新请求，
     * 见 {@link GeoIp#resolveRegion}。
     */
    public static int grantedRegion(Context context) {
        return preferences(context).getInt(KEY_REGION, GeoIp.REGION_OTHER);
    }

    /** 用户点了"同意"。此后不再弹窗，也不再请求地区。 */
    public static void grant(Context context, int region) {
        preferences(context).edit()
                .putBoolean(KEY_GRANTED, true)
                .putInt(KEY_REGION, region)
                .apply();
    }

    /**
     * 启动本次放行的数据 SDK。只在获得许可后调用（用户同意，或地区判定无需弹窗）。
     * 幂等：Application 重建（后台任务唤醒进程）时也要能重新启动。
     *
     * @param region 本次启动判定的地区，决定 Bugly 是否启动。
     */
    public static synchronized void startSdks(Context context, int region) {
        final Context application = context.getApplicationContext();
        if (!clarityStarted) {
            clarityStarted = true;
            try {
                final ClarityConfig config = new ClarityConfig(CLARITY_PROJECT_ID);
                // None：平时不打日志。排查初始化问题时可临时改成 LogLevel.Verbose。
                config.setLogLevel(LogLevel.None);
                Clarity.initialize(application, config);
                Log.i(TAG, "Clarity initialized after consent");
            } catch (Throwable error) {
                // 分析 SDK 起不来不该拖垮应用。
                Log.w(TAG, "Clarity initialization failed", error);
            }
        }
        if (region != GeoIp.REGION_CN || buglyStarted) {
            return;
        }
        buglyStarted = true;
        try {
            final CrashReport.UserStrategy strategy = new CrashReport.UserStrategy(application);
            strategy.setEnableNativeCrashMonitor(BUGLY_NATIVE_MONITOR);
            // 官方要求「务必在用户授权隐私政策后再初始化」，且不要放到异步线程：
            // 本方法的调用点是 Application.onCreate 与 ConsentActivity，都在主线程。
            CrashReport.initCrashReport(application, BUGLY_APP_ID, BUGLY_DEBUG, strategy);
            Log.i(TAG, "Bugly initialized after consent (CN only)");
        } catch (Throwable error) {
            // 上报 SDK 起不来同样不该拖垮应用。
            Log.w(TAG, "Bugly initialization failed", error);
        }
    }

    /** 后台任务唤醒进程（不经过 ConsentActivity）时用：地区取自许可记录。 */
    public static synchronized void startSdks(Context context) {
        startSdks(context, isGranted(context) ? grantedRegion(context) : GeoIp.REGION_OTHER);
    }
}
