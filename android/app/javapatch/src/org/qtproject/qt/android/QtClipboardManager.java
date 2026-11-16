package org.qtproject.qt.android;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.net.Uri;
import android.os.Build;
import android.util.Log;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;

/**
 * Replacement for the stock {@code org.qtproject.qt.android.QtClipboardManager}.
 *
 * <p>Why this file exists: the stock class builds its {@link ClipboardManager} from whatever
 * {@link Context} the Qt core hands it, i.e. the Activity. {@code ClipboardManager} keeps that
 * context in its final {@code mContext} field and registers a framework listener that is held by
 * a JNI global, so the very first host Activity of a process can never be collected even after it
 * is destroyed (verified: heap-141-0841 root chain
 * {@code jni_global QtClipboardManager -> ClipboardManager.mContext -> cold-first MainActivity}).
 * Every later host is fine because the Qt runtime is retained instead of rebuilt.
 *
 * <p>Fix: always resolve the service (and therefore the listener) from
 * {@code context.getApplicationContext()}, which lives as long as the process. Behaviour for the
 * actual clipboard operations is unchanged; this app does not use the clipboard at all, so the
 * only thing that matters is that no Activity ends up in {@code mContext}.
 *
 * <p>Signatures are kept byte-for-byte compatible with the stock class because the Qt core looks
 * them up by name and descriptor through JNI.
 */
class QtClipboardManager {
    private static final String TAG = "QtClipboardManager";

    private ClipboardManager m_clipboardManager;
    private boolean m_usePrimaryClip = false;
    private final long m_nativePointer;

    // Kept in a field: the framework only holds a weak-ish reference through the listener list,
    // and the stock class relies on the native side keeping it alive as well.
    private ClipboardManager.OnPrimaryClipChangedListener m_listener;

    static native void onClipboardDataChanged(long nativePointer);

    QtClipboardManager(Context context, long nativePointer) {
        m_nativePointer = nativePointer;
        registerClipboardManager(context);
    }

    private void registerClipboardManager(final Context context) {
        if (context == null) {
            return;
        }
        // The whole point of the patch: never hand an Activity to the framework clipboard.
        final Context application = context.getApplicationContext();
        final Context safe = application != null ? application : context;
        Log.i(TAG, "clipboard host context=" + context.getClass().getName()
                + " application=" + (application != null) + " patched=application-context");
        final CountDownLatch latch = new CountDownLatch(1);
        QtNative.runAction(new Runnable() {
            @Override
            public void run() {
                try {
                    m_clipboardManager =
                            (ClipboardManager) safe.getSystemService(Context.CLIPBOARD_SERVICE);
                    if (m_clipboardManager != null) {
                        m_listener = new ClipboardManager.OnPrimaryClipChangedListener() {
                            @Override
                            public void onPrimaryClipChanged() {
                                onClipboardDataChanged(m_nativePointer);
                            }
                        };
                        m_clipboardManager.addPrimaryClipChangedListener(m_listener);
                    }
                } finally {
                    latch.countDown();
                }
            }
        });
        try {
            latch.await();
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        }
    }

    void clearClipData() {
        if (m_clipboardManager == null) {
            return;
        }
        try {
            if (Build.VERSION.SDK_INT >= 28) {
                m_clipboardManager.clearPrimaryClip();
            } else {
                m_clipboardManager.setPrimaryClip(ClipData.newPlainText("", ""));
            }
        } catch (RuntimeException exception) {
            Log.w(TAG, "clearClipData failed", exception);
        }
    }

    void setClipboardText(Context context, String text) {
        if (m_clipboardManager == null) {
            return;
        }
        m_clipboardManager.setPrimaryClip(ClipData.newPlainText("text", text));
        m_usePrimaryClip = false;
    }

    static boolean hasClipboardText(Context context) {
        if (context == null) {
            return false;
        }
        try {
            ClipboardManager manager =
                    (ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
            return manager != null && manager.hasPrimaryClip();
        } catch (RuntimeException exception) {
            Log.w(TAG, "hasClipboardText failed", exception);
            return false;
        }
    }

    boolean hasClipboardText() {
        if (m_clipboardManager == null) {
            return false;
        }
        try {
            return m_clipboardManager.hasPrimaryClip();
        } catch (RuntimeException exception) {
            Log.w(TAG, "hasClipboardText failed", exception);
            return false;
        }
    }

    String getClipboardText() {
        if (m_clipboardManager == null) {
            return "";
        }
        try {
            final ClipData clip = m_clipboardManager.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0) {
                return "";
            }
            final CharSequence text = clip.getItemAt(0).coerceToText(null);
            return text == null ? "" : text.toString();
        } catch (RuntimeException exception) {
            Log.w(TAG, "getClipboardText failed", exception);
            return "";
        }
    }

    private void updatePrimaryClip(ClipData clip, Context context) {
        if (m_clipboardManager == null) {
            return;
        }
        m_clipboardManager.setPrimaryClip(clip);
        m_usePrimaryClip = false;
    }

    void setClipboardHtml(Context context, String html, String text) {
        if (m_clipboardManager == null) {
            return;
        }
        final ClipData clip = ClipData.newHtmlText("html", text, html);
        m_clipboardManager.setPrimaryClip(clip);
        m_usePrimaryClip = false;
    }

    private boolean hasClipboardMimeType(String mimeType) {
        if (m_clipboardManager == null || mimeType == null) {
            return false;
        }
        try {
            final ClipData clip = m_clipboardManager.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0) {
                return false;
            }
            final ClipData.Item item = clip.getItemAt(0);
            return item != null && item.getHtmlText() != null ? "text/html".equals(mimeType) : false;
        } catch (RuntimeException exception) {
            Log.w(TAG, "hasClipboardMimeType failed", exception);
            return false;
        }
    }

    boolean hasClipboardHtml() {
        return hasClipboardMimeType("text/html");
    }

    String getClipboardHtml() {
        if (m_clipboardManager == null) {
            return "";
        }
        try {
            final ClipData clip = m_clipboardManager.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0) {
                return "";
            }
            final CharSequence html = clip.getItemAt(0).getHtmlText();
            return html == null ? "" : html.toString();
        } catch (RuntimeException exception) {
            Log.w(TAG, "getClipboardHtml failed", exception);
            return "";
        }
    }

    void setClipboardUri(Context context, String uriString) {
        if (m_clipboardManager == null) {
            return;
        }
        m_clipboardManager.setPrimaryClip(ClipData.newRawUri("uri", Uri.parse(uriString)));
        m_usePrimaryClip = false;
    }

    boolean hasClipboardUri() {
        return getClipboardUris().length > 0;
    }

    private String[] getClipboardUris() {
        if (m_clipboardManager == null) {
            return new String[0];
        }
        try {
            final ClipData clip = m_clipboardManager.getPrimaryClip();
            if (clip == null) {
                return new String[0];
            }
            final List<String> uris = new ArrayList<>();
            for (int index = 0; index < clip.getItemCount(); ++index) {
                final Uri uri = clip.getItemAt(index).getUri();
                if (uri != null) {
                    uris.add(uri.toString());
                }
            }
            return uris.toArray(new String[0]);
        } catch (RuntimeException exception) {
            Log.w(TAG, "getClipboardUris failed", exception);
            return new String[0];
        }
    }
}
