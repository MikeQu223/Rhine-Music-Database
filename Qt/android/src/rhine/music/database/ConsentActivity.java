package rhine.music.database;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.os.Bundle;
import android.text.method.LinkMovementMethod;
import android.util.Log;
import android.view.KeyEvent;
import android.widget.TextView;

import org.qtproject.qt.android.bindings.QtActivity;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/**
 * 启动闸门：先确认数据传输许可，再启动 Qt 界面。
 *
 * 清单里它是 LAUNCHER，QtActivity 不再对外暴露——所以"同意之前"Qt、Clarity、Bugly
 * 一个都没起来，不是先加载界面再补一个弹窗。
 *
 * 判定顺序：
 *   1. 已同意（SharedPreferences）→ 直接启动界面（Application 已负责启动 SDK）。
 *   2. 未同意 → 每次都实时取一次 IPv4（**不缓存**）查内置表，请求总预算 3 秒：
 *        · 中国大陆 / 欧洲 → 弹系统 AlertDialog，同意后启动界面；
 *        · 其他地区、或 3 秒内取不到地址（超时、断网、纯 IPv6）→ 按其他地区处理，
 *          不弹窗，直接启动界面与 SDK。
 *   3. 拒绝 → 退出应用。
 */
public class ConsentActivity extends Activity {
    private static final String TAG = "RhineConsent";

    private static final String CN_MESSAGE = """
            以下第三方 SDK 会处理必要的信息：

            · Microsoft Clarity
              服务提供：Microsoft
              可能收集：界面点击与浏览路径、设备型号、系统版本、屏幕尺寸、应用版本。
              上述数据可能会传输至中国境外的服务器，使用这些服务即代表授予数据跨境传输许可。

            · Bugly SDK
              服务提供：腾讯
              可能收集：手机型号、品牌、Android 系统版本与 API 等级、厂商系统版本、CPU 架构、是否 Root、磁盘/内存/存储占用、网络类型、应用进程名与 PID。
              收集的数据用于排查质量问题、提升应用运行质量。
              隐私政策：https://privacy.qq.com/document/preview/fc748b3d96224fdb825ea79e132c1a56

            仅适用于中国大陆联网使用。无互联网连接时将不会使用这些服务。
            """;

    private static final String EU_MESSAGE = """
            Before you agree, this app does not start its interface and does not transmit any data.

            With your consent, Microsoft Clarity (session analytics) collects de-identified
            interaction data — taps and navigation, device model, OS version, screen size and
            app version — and transfers it to servers outside the European Economic Area.

            You may decline; the app will then close and no data will be uploaded.
            You can use the app without connect to the internet.
            """;

    private AlertDialog dialog;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        if (ConsentStore.isGranted(this)) {
            proceed();
            return;
        }
        // 地区判定要取一次公网 IPv4。HttpURLConnection 的 connectTimeout 管不住 DNS 解析，
        // 所以判定整体再套一层硬闸门：超过 GeoIp.TOTAL_TIMEOUT_MS 就按其他地区放行，
        // 绝不让启动页卡在网络上。
        new Thread(() -> {
            int resolved = GeoIp.REGION_OTHER;
            final ExecutorService probe = Executors.newSingleThreadExecutor(runnable -> {
                final Thread worker = new Thread(runnable, "rhine-consent-region");
                worker.setDaemon(true);
                return worker;
            });
            try {
                resolved = probe.submit(() -> GeoIp.resolveRegion(getApplicationContext()))
                        .get(GeoIp.TOTAL_TIMEOUT_MS, TimeUnit.MILLISECONDS);
            } catch (TimeoutException timeout) {
                Log.w(TAG, "region probe exceeded " + GeoIp.TOTAL_TIMEOUT_MS + "ms; treat as other region");
            } catch (Throwable error) {
                Log.w(TAG, "region probe failed; treat as other region", error);
            } finally {
                probe.shutdownNow();
            }
            final int region = resolved;
            runOnUiThread(() -> {
                if (isFinishing() || isDestroyed()) {
                    return;
                }
                if (region == GeoIp.REGION_CN || region == GeoIp.REGION_EU) {
                    showConsentDialog(region);
                } else {
                    // 其他地区（含 3 秒内没取到地址的超时情况）：不需要弹许可，本次运行直接放行。
                    // 不写持久标记——下次启动会重新判定，这正是"不缓存地区"的含义。
                    Log.i(TAG, "region " + region + " (outside CN/EU or undetermined); start without prompt");
                    proceed();
                }
            });
        }, "rhine-consent-gate").start();
    }

    /**
     * 两个按钮、无法绕过的许可对话框：
     *   · 空白区域与返回键都不生效（{@code setCancelable(false)} + 显式关掉
     *     {@code canceledOnTouchOutside}），用户只能选"同意"或"退出"；
     *   · 同意后写 granted，此后**不再弹窗、也不再请求地区**——每个地区只需确认一次。
     */
    private void showConsentDialog(final int region) {
        final boolean mainland = region == GeoIp.REGION_CN;
        dialog = new AlertDialog.Builder(this)
                .setTitle(mainland ? "隐私与数据传输许可" : "Data Transfer Consent")
                .setMessage(mainland ? CN_MESSAGE : EU_MESSAGE)
                .setCancelable(false)
                .setPositiveButton(mainland ? "同意" : "Agree", (ignored, which) -> {
                    ConsentStore.grant(this, region);
                    proceed();
                })
                .setNegativeButton(mainland ? "退出" : "Exit", (ignored, which) -> finishAffinity())
                .create();
        // setCancelable(false) 已经涵盖这两条；显式再设一次，避免将来有人改成 true 后
        // 点一下空白就"默认同意"。
        dialog.setCanceledOnTouchOutside(false);
        dialog.setCancelable(false);
        // 返回键同样不关闭：这个窗口只能被两个按钮回答（安卓 14+ 的 predictive back
        // 也会走到这里）。
        dialog.setOnKeyListener((ignored, keyCode, event) -> keyCode == KeyEvent.KEYCODE_BACK);
        dialog.show();
        // AlertDialog 的 message 默认没有 MovementMethod，链接点不动；这里补上。
        final TextView message = dialog.findViewById(android.R.id.message);
        if (message != null) {
            message.setMovementMethod(LinkMovementMethod.getInstance());
        }
    }

    /** 启动 SDK 并进入 Qt 界面。走到这里说明要么已同意，要么本次运行判定无需许可。 */
    private void proceed() {
        ConsentStore.startSdks(this);
        // CLEAR_TOP + SINGLE_TOP：应用已在后台时再次点图标，不会叠出第二个 QtActivity
        // （Qt 的运行时是进程级的，多实例会互相踩）。
        final Intent intent = new Intent(this, QtActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        startActivity(intent);
        finish();
    }

    @Override
    public void onBackPressed() {
        if (ConsentStore.isGranted(this)) {
            super.onBackPressed();
        }
        // 未同意时返回键不生效：这个页面只能通过"退出"按钮离开；对话框本身也不可取消。
    }
}
