package org.qtproject.qt.android.multimedia;

import android.app.Activity;
import android.content.Context;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.Environment;
import android.util.Log;
import android.view.OrientationEventListener;
import android.webkit.MimeTypeMap;

import java.io.File;

/**
 * Replacement for the stock {@code org.qtproject.qt.android.multimedia.QtMultimediaUtils}
 * (pinned SDK: {@code output/dependencies/qt-android/jar/Qt6AndroidMultimedia.jar},
 * {@code QtMultimediaUtils.class} 4746 bytes, {@code QtMultimediaUtils$OrientationListener.class}
 * 878 bytes — inspected with {@code javap -p} only, the SDK itself is never modified).
 *
 * <p>Why this file exists. The stock class keeps two statics:
 *
 * <pre>
 *   private static Context m_context;
 *   private static QtMultimediaUtils$OrientationListener m_orientationListener;
 * </pre>
 *
 * <p>and {@code setContext(Context)} does, bytecode-for-bytecode:
 *
 * <pre>
 *   putstatic m_context &lt;the context it was handed&gt;
 *   new OrientationListener(ctx); putstatic m_orientationListener &lt;the new listener&gt;
 * </pre>
 *
 * <p>Two lifecycle defects follow, and both are Activity-rooted:
 *
 * <ol>
 *   <li>the context is stored verbatim, so it is the Activity the Qt core passes in
 *       ({@code QtNative.activity()} on the JNI bootstrap path). A static field keeps the whole
 *       Activity alive for the process lifetime — the same root chain that
 *       {@code QtClipboardManager} had ({@code jni_global -> ...mContext -> MainActivity});</li>
 *   <li>the previous {@code OrientationEventListener} is replaced without {@code disable()}, so
 *       every host cycle registers one more sensor callback whose target is the retired Activity.
 *       Those listeners are never unregistered: the SensorManager keeps them, they keep the
 *       Activity, and after five cycles there are five of them.</li>
 * </ol>
 *
 * <p>Fix, and the only behavioural change in this overlay:
 * {@code setContext} downgrades to {@code context.getApplicationContext()} (falling back to the
 * given context when an application context is not available, never silently dropping) and
 * {@code disable()}s + releases the previous listener before it creates the replacement. The
 * replacement therefore never targets an Activity, so a retired host is collectable again without
 * any teardown hook — "release" is not something the app has to get right, it is the absence of a
 * strong reference to a host object.
 *
 * <p>{@code enableOrientationListener(boolean)} is made null-safe: the stock version calls the
 * static listener unconditionally and throws NPE when Qt enables orientation before any context
 * was set.
 *
 * <p>{@code null} arguments are ignored with a log line instead of pinning {@code null} into
 * {@code m_context} (the stock setter would leave {@code getCacheDirectory()} to throw NPE on
 * every later call).
 *
 * <p>Signatures and field names are kept identical to the stock class: the Qt core resolves
 * {@code setActivity}, {@code setContext}, {@code enableOrientationListener},
 * {@code getDeviceOrientation}, {@code getDefaultMediaDirectory}, {@code registerMediaFile},
 * {@code getCacheDirectory} and {@code getMimeType} through JNI by name + descriptor. The stock
 * class is package-private, so this overlay is too. The private helper
 * {@code getMediaCodecs()} of the stock class has no caller inside the class and cannot be called
 * through JNI (JNI only reaches fields/methods it looks up by name from native code and Qt never
 * looks up a private helper), so it is not reproduced here.
 *
 * <p>Never edit the SDK: this class is compiled from this file and swapped into the **deploy copy**
 * of {@code Qt6AndroidMultimedia.jar} by {@code ../apply-media.sh}.
 */
class QtMultimediaUtils {
    private static final String QtTAG = "QtMultimediaUtils";

    private static Context m_context = null;
    private static OrientationListener m_orientationListener = null;

    /**
     * Stock 6.12: an empty method (the orientation listener is created from the context instead).
     * Kept as a no-op so the JNI lookup still succeeds.
     */
    static void setActivity(Activity activity, Object options) {
        // Intentionally empty; see the class comment.
    }

    /**
     * Qt hands the current host context here on every bootstrap. Store an application context,
     * not the Activity, and retire the previous sensor listener first.
     */
    static void setContext(Context context) {
        if (context == null) {
            Log.w(QtTAG, "setContext(null) ignored; keeping the current context");
            return;
        }
        Context application = context.getApplicationContext();
        Context owned = application != null ? application : context;
        // Retire the previous listener BEFORE the field is overwritten: dropping the reference is
        // not enough, an enabled SensorEventListener stays registered with the SensorManager.
        OrientationListener previous = m_orientationListener;
        m_orientationListener = null;
        if (previous != null) {
            try {
                previous.disable();
            } catch (Throwable error) {
                Log.w(QtTAG, "could not disable the previous orientation listener: " + error);
            }
        }
        m_context = owned;
        m_orientationListener = new OrientationListener(owned);
    }

    /** Null-safe wrapper: the stock version dereferences the listener unconditionally. */
    static void enableOrientationListener(boolean enable) {
        OrientationListener listener = m_orientationListener;
        if (listener == null) {
            Log.w(QtTAG, "enableOrientationListener(" + enable + ") before setContext; ignored");
            return;
        }
        if (enable) {
            listener.enable();
        } else {
            listener.disable();
        }
    }

    static int getDeviceOrientation() {
        return OrientationListener.deviceOrientation;
    }

    /**
     * Public storage directory for the Qt media backends. Returns {@code null} when the platform
     * has no such directory, which the Qt side already treats as "unavailable".
     */
    static String getDefaultMediaDirectory(int type) {
        File directory;
        switch (type) {
            case 0:
                directory = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC);
                break;
            case 1:
                directory = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES);
                break;
            case 2:
                directory = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM);
                break;
            case 3:
                directory = new File(Environment.getExternalStorageDirectory(), "Sounds");
                break;
            default:
                Log.e(QtTAG, "getDefaultMediaDirectory: unknown type " + type);
                return null;
        }
        if (directory == null) {
            return null;
        }
        if (!directory.exists() && !directory.mkdirs()) {
            Log.e(QtTAG, "getDefaultMediaDirectory: could not create " + directory.getAbsolutePath());
            return null;
        }
        return directory.getAbsolutePath();
    }

    /** Hand a freshly written file to the media scanner. No-op when no context was set yet. */
    static void registerMediaFile(String path) {
        Context context = m_context;
        if (context == null) {
            Log.w(QtTAG, "registerMediaFile without a context: " + path);
            return;
        }
        try {
            MediaScannerConnection.scanFile(context, new String[] {path}, null, null);
        } catch (Throwable error) {
            Log.e(QtTAG, "registerMediaFile():" + error);
        }
    }

    /** Application cache dir; {@code null} instead of NPE when the context is not set yet. */
    static File getCacheDirectory() {
        Context context = m_context;
        if (context == null) {
            Log.w(QtTAG, "getCacheDirectory without a context");
            return null;
        }
        return context.getCacheDir();
    }

    /**
     * MIME type of a URL: content URIs go through the content resolver, everything else through
     * the extension map. Any failure is logged and reported as {@code null} (stock behaviour).
     */
    static String getMimeType(Context context, String url) {
        String mimeType = null;
        try {
            Uri uri = Uri.parse(url);
            String scheme = uri.getScheme();
            if (scheme != null && scheme.contains("content")) {
                mimeType = context.getContentResolver().getType(uri);
            } else {
                String extension = MimeTypeMap.getFileExtensionFromUrl(url);
                if (extension != null && !extension.isEmpty()) {
                    mimeType = MimeTypeMap.getSingleton()
                            .getMimeTypeFromExtension(extension.toLowerCase());
                }
            }
        } catch (Exception error) {
            Log.e(QtTAG, "getMimeType():" + error);
            mimeType = null;
        }
        return mimeType;
    }

    /**
     * Device rotation in degrees, fed by the framework. Static so the Qt side can read it without
     * an instance, exactly like the stock class.
     */
    static final class OrientationListener extends OrientationEventListener {
        static int deviceOrientation = 0;

        OrientationListener(Context context) {
            super(context);
        }

        @Override
        public void onOrientationChanged(int orientation) {
            if (orientation == ORIENTATION_UNKNOWN) {
                return;
            }
            deviceOrientation = orientation;
        }
    }
}
