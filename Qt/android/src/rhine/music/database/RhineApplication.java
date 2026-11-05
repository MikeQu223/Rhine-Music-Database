package rhine.music.database;

import org.qtproject.qt.android.bindings.QtApplication;

/**
 * 应用进程入口。
 *
 * 这里不直接初始化 Clarity：所有会传输数据的 SDK 统一由 {@link ConsentStore} 把关，
 * 只有用户点过"同意"才启动。判断放在 Application 是为了覆盖"后台任务唤醒进程、
 * 不经过 ConsentActivity"的情况——那种情况下也必须有同意记录才会创建 SDK。
 *
 * 继承 QtApplication 仍然是必须的：清单里的 android:name 指向它，Qt 的部分初始化
 * 挂在父类上。
 */
public class RhineApplication extends QtApplication {
    @Override
    public void onCreate() {
        super.onCreate();
        if (ConsentStore.isGranted(this)) {
            ConsentStore.startSdks(this);
        }
    }
}
