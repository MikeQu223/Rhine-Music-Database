// Copyright (C) 2024 The Qt Company Ltd.
// SPDX-License-Identifier: LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only

package org.qtproject.qt.android;

import static org.qtproject.qt.android.QtNative.ApplicationState.*;

import android.app.Activity;
import android.app.Application;
import android.content.res.Resources;
import android.os.Build;
import android.os.Bundle;
import android.util.DisplayMetrics;
import android.util.Log;
import android.widget.PopupMenu;

import java.util.HashSet;

class QtEmbeddedDelegate extends QtActivityDelegateBase
        implements QtNative.AppStateDetailsListener, QtEmbeddedViewInterface, QtWindowInterface,
                   QtMenuInterface
{
    private static final String QtTAG = "QtEmbeddedDelegate";
    private final HashSet<QtView> m_views = new HashSet<>();
    private QtNative.ApplicationStateDetails m_stateDetails;
    private boolean m_backendsRegistered = false;

    QtEmbeddedDelegate(Activity context) {
        super(context);
        m_stateDetails = QtNative.getStateDetails();
        QtNative.registerAppStateListener(this);

        m_activity.getApplication().registerActivityLifecycleCallbacks(
        new Application.ActivityLifecycleCallbacks() {
            @Override
            public void onActivityCreated(Activity activity, Bundle savedInstanceState) {}

            @Override
            public void onActivityStarted(Activity activity) {}

            @Override
            public void onActivityResumed(Activity activity) {
                if (m_activity == activity && m_stateDetails.isStarted) {
                    QtNative.setApplicationState(ApplicationActive);
                    QtWindow.updateWindows();
                }
            }

            @Override
            public void onActivityPaused(Activity activity) {
                if (m_activity == activity && m_stateDetails.isStarted) {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N ||
                        !activity.isInMultiWindowMode()) {
                        QtNative.setApplicationState(ApplicationInactive);
                    }
                }
            }

            @Override
            public void onActivityStopped(Activity activity) {
                if (m_activity == activity && m_stateDetails.isStarted) {
                    QtNative.setApplicationState(ApplicationSuspended);
                }
            }

            @Override
            public void onActivitySaveInstanceState(Activity activity, Bundle outState) {}

            @Override
            public void onActivityDestroyed(Activity activity) {
                if (m_activity != activity) {
                    return;
                }
                // RHINE PATCH (DEVICE-VISUAL-131 seq5): a destroyed host Activity must not stay
                // reachable from the Application callback list, even when Qt keeps its runtime
                // alive across host restarts (isStarted == false here, set by RhineQtViews).
                // Stock Qt only unregisters inside the isStarted branch below, so every
                // Back/reopen cycle used to leak one destroyed Activity + delegate + QtView.
                m_activity.getApplication().unregisterActivityLifecycleCallbacks(this);
                QtNative.unregisterAppStateListener(QtEmbeddedDelegate.this);
                QtEmbeddedViewInterfaceFactory.remove(m_activity);
                // RHINE PATCH (NATIVE-RECOVERY-132R): 宿主销毁后本 delegate 自己也不该再握着
                // 视图/窗口：m_views 是 HashSet<QtView>（QtView.getContext() 就是那个 Activity），
                // m_topLevelWindows 握着 QtWindow。清掉它们，配合 RhineQtViews 注销监听 +
                // 摘除 factory，被销毁的一轮才可能整体可回收（对象根证据见 cycle N released）。
                m_views.clear();
                m_topLevelWindows.clear();
                // RHINE PATCH (FINAL-RECOVERY-138): break the framework-side GC root chain.
                //
                // 137 的堆证据：framework 的 DisplayManagerGlobal 持有一份全局回调 JNI 引用，
                // 它的 mDisplayListeners 里躺着 5 个 QtDisplayManager$1（每个都是被销毁那一轮
                // 注册的），$1 -m_activity-> MainActivity。于是**被销毁的宿主 Activity 一个都
                // 回收不了**（heap: 6x MainActivity/QtEmbeddedDelegate/QtDisplayManager/
                // RhineQtView/QtWindow 全部 strongly reachable）。stock Qt 只在
                // isStarted==true 的 teardown 分支里注销，而 RhineQtViews 为了让 Qt 运行时
                // 跨宿主存活，提前把 isStarted 置 false —— 注册因此永远没有对应注销。
                // 这里在宿主销毁时无条件注销本轮的 display listener：注销之后全局回调不再引用
                // QtDisplayManager$1，activity/delegate/view 整簇才可能被回收。
                try {
                    displayManager().unregisterDisplayListener();
                    Log.i(QtTAG, "released display listener for destroyed host");
                } catch (Throwable error) {
                    Log.w(QtTAG, "release display listener failed: " + error);
                }
                Log.i(QtTAG, "released activity lifecycle callback for destroyed host"
                        + " (isStarted=" + m_stateDetails.isStarted + ")");
                if (m_stateDetails.isStarted && !activity.isChangingConfigurations()) {
                    // Legacy path: Qt owns the process lifetime for this host, so tear it down.
                    QtNative.terminateQtNativeApplication();
                    QtNative.setActivity(null);
                }
            }
        });
    }

    @Override
    public void onAppStateDetailsChanged(QtNative.ApplicationStateDetails details) {
        synchronized (this) {
            m_stateDetails = details;
            if (details.isStarted && !m_backendsRegistered) {
                if (BackendRegister.isNull())
                    return;

                m_backendsRegistered = true;
                BackendRegister.registerBackend(QtWindowInterface.class, this);
                BackendRegister.registerBackend(QtMenuInterface.class, this);
                BackendRegister.registerBackend(QtInputInterface.class, m_inputDelegate);
            } else if (!details.isStarted && m_backendsRegistered) {
                m_backendsRegistered = false;

                if (BackendRegister.isNull())
                    return;

                BackendRegister.unregisterBackend(QtWindowInterface.class);
                BackendRegister.unregisterBackend(QtMenuInterface.class);
                BackendRegister.unregisterBackend(QtInputInterface.class);
            }
        }
    }

    @Override
    public void onNativePluginIntegrationReadyChanged(boolean ready)
    {
        if (ready) {
            QtNative.runAction(() -> {
                DisplayMetrics metrics = Resources.getSystem().getDisplayMetrics();
                QtDisplayManager.handleLayoutSizeChanged(metrics.widthPixels, metrics.heightPixels);
                m_displayManager.initDisplayProperties();
            });
        }
    }

    @Override
    void startNativeApplicationImpl(String appParams, String mainLib)
    {
        QtNative.startApplication(appParams, mainLib);
    }

    // QtEmbeddedViewInterface implementation begin
    @Override
    public void startQtApplication(String appParams, String mainLib)
    {
        super.startNativeApplication(appParams, mainLib);
    }

    @Override
    public void addView(QtView view)
    {
        if (m_views.add(view)) {
            QtNative.runAction(() -> createRootWindow(view));
        }
    }

    @Override
    public void removeView(QtView view)
    {
        m_views.remove(view);
    }
    // QtEmbeddedViewInterface implementation end

    // This gets called from Android thread
    private void createRootWindow(QtView view) {
        // No use in creating a QQuickView for a View that has been removed
        if (m_views.contains(view)) {
            QtView.createRootWindow(view, view.getLeft(), view.getTop(), view.getWidth(),
                                view.getHeight());
        }
    }

    // QtMenuInterface implementation begin
    @Override
    public void resetOptionsMenu() { QtNative.runAction(m_activity::invalidateOptionsMenu); }

    @Override
    public void openOptionsMenu() { QtNative.runAction(m_activity::openOptionsMenu); }

    @Override
    public void closeContextMenu() { QtNative.runAction(m_activity::closeContextMenu); }

    @Override
    public void openContextMenu(final int x, final int y, final int w, final int h)
    {
        final QtEditText focusedEditText = m_inputDelegate.getCurrentQtEditText();
        if (focusedEditText == null) {
            Log.w(QtTAG, "No focused view when trying to open context menu");
            return;
        }
        focusedEditText.postDelayed(() -> {
            PopupMenu popup = new PopupMenu(m_activity, focusedEditText);
            QtNative.fillContextMenu(popup.getMenu());
            popup.setOnMenuItemClickListener(m_activity::onContextItemSelected);
            popup.setOnDismissListener(popupMenu ->
                    m_activity.onContextMenuClosed(popupMenu.getMenu()));
            popup.show();
        }, 100);
    }
    // QtMenuInterface implementation end
}
