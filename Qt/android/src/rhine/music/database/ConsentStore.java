package rhine.music.database;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Log;

import com.microsoft.clarity.Clarity;
import com.microsoft.clarity.ClarityConfig;
import com.microsoft.clarity.models.LogLevel;

/**
 * 数据传输许可的存储与 SDK 启动闸门。
 *
 * 未同意时，任何会联网上报的 SDK 都不会初始化——不是"初始化后再暂停"，而是根本不创建。
 * 只有用户点了"同意"才会写入持久标记；"其他地区"（含判定超时）只是**本次运行**放行，
 * 下次启动会重新判定——地区判定不缓存，这是有意的。
 * 进程被后台任务唤醒（不经过 ConsentActivity）时，没有同意记录就不启动 SDK：宁可少采集。
 */
public final class ConsentStore {
    private static final String TAG = "RhineConsent";
    private static final String PREFS = "rhine-consent";
    private static final String KEY_GRANTED = "granted";
    private static final String KEY_REGION = "region";
    private static final String CLARITY_PROJECT_ID = "z8vbz4b078";

    private static boolean sdksStarted;

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
     * 启动所有会传输数据的 SDK。只在获得许可后调用（用户同意，或地区判定无需弹窗）。
     * 幂等：Application 重建（后台任务唤醒进程）时也要能重新启动。
     */
    public static synchronized void startSdks(Context context) {
        if (sdksStarted) {
            return;
        }
        sdksStarted = true;
        final Context application = context.getApplicationContext();
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
        // Bugly 接入后在这里初始化，同样必须在同意之后，且与 Clarity 保持同一顺序。
    }
}
