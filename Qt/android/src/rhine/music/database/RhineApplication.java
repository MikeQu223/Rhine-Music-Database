package rhine.music.database;

import android.util.Log;

import com.microsoft.clarity.Clarity;
import com.microsoft.clarity.ClarityConfig;
import com.microsoft.clarity.models.LogLevel;

import org.qtproject.qt.android.bindings.QtApplication;

/**
 * 应用进程入口：在 Qt 起来之前初始化 Microsoft Clarity（会话行为分析）。
 *
 * 为什么继承 {@link QtApplication} 而不是 android.app.Application：清单里原本的
 * android:name 就指向 Qt 的这个类，Qt 把活动生命周期回调一类的初始化挂在它身上，
 * 换成基类会把这些丢掉；这里只是扩展，父类实现照旧执行。
 *
 * 为什么放 Application 而不是 Activity：初始化要早于任何界面、且每个进程只做一次，
 * 与进程同生命周期——Activity 因配置变化重建时不会重复初始化。
 */
public class RhineApplication extends QtApplication {
    @Override
    public void onCreate() {
        super.onCreate();
        try {
            // projectId 是 Clarity 后台的项目标识，不是密钥，可以随包公开。
            ClarityConfig config = new ClarityConfig("z8vbz4b078");
            // None：平时不打日志。排查初始化问题时可临时改成 LogLevel.Verbose，
            // 用 adb logcat 能看到 SDK 自己的初始化过程。
            config.setLogLevel(LogLevel.None);
            Clarity.initialize(getApplicationContext(), config);
        } catch (Throwable error) {
            // 分析 SDK 起不来不该拖垮面板本身：记一行日志，应用照常启动。
            Log.w("RhineApplication", "Clarity initialization failed", error);
        }
    }
}
