# T25 Manifest patch request

Status: NO_MANIFEST_DELTA_REQUIRED

This file is a patch request, not a manifest edit. T25 does not modify
android/app/src/main/AndroidManifest.xml. The manifest has a single writer in
this workspace; any future delta must be applied by that writer, not by the
media-session atom.

## Why no delta is needed

The two Flutter channels added by T25 are in-process binary messenger channels:

    rhine.music.database/media_session          (MethodChannel)
    rhine.music.database/media_session/events   (EventChannel)

They do not create an Android component, do not cross a process boundary, and
do not need a manifest entry, a permission, an intent filter, or a service
declaration of their own.

The foreground service and its permissions already exist in the current
manifest:

- android/app/src/main/AndroidManifest.xml:13  uses-permission
  android.permission.FOREGROUND_SERVICE
- android/app/src/main/AndroidManifest.xml:14  uses-permission
  android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK
- android/app/src/main/AndroidManifest.xml:15  uses-permission
  android.permission.POST_NOTIFICATIONS
- android/app/src/main/AndroidManifest.xml:54-57  service
  android:name="rhine.music.database.porting.MediaPlaybackService"
  android:exported="false"
  android:foregroundServiceType="mediaPlayback"

MediaSessionChannel.ensureStarted only calls
MediaSessionHost.ensureStarted(activity), which starts that already-declared
service from a foreground Activity. No new service, receiver, provider, or
activity is introduced.

## Requested delta

None.

    diff --git a/android/app/src/main/AndroidManifest.xml b/android/app/src/main/AndroidManifest.xml
    (no changes)

## Conditions that would require a future request

A future change needs a new patch request, reviewed and applied by the manifest
single writer, if any of the following becomes true:

1. The service class or its package name changes.
2. The service needs a different foregroundServiceType.
3. A new runtime permission is required (for example a media-button or
   notification-listener permission).
4. A new activity, receiver, or provider is added for media control.
5. The channels move out of the main Flutter engine into a separate process.

Until then, T25 is complete with the manifest untouched.
