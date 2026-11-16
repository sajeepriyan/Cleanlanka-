# Clean Lanka Earpiece Test — Android 12+

This is a **foreground-only Android test client**, not a verified production calling app. It opens the existing Clean Lanka site for both Customer and Worker accounts. The existing site/browser behavior is unchanged.

The app uses Android AudioManager MODE_IN_COMMUNICATION and explicitly requests TYPE_BUILTIN_EARPIECE with setCommunicationDevice. The document-start bridge waits for native route confirmation before returning microphone capture to the website or playing remote call audio. It hides the website's speaker controls inside this app. No speaker fallback is requested. Missing earpiece, denied audio focus, failed routing, and leaving the foreground stop/refuse the call. Loss-of-route callbacks stop call tracks. Android/WebView/device behavior and callback timing require real phone testing; code/build success does not prove that sound physically comes from the earpiece, or guarantee zero audio leakage during an OS route transition.

## Build

Use JDK 17, Gradle 8.9, Android SDK platform 35 and build tools. From this folder run:

```
gradle :app:assembleDebug :app:lintDebug
node --test tests/bridge.test.cjs
```

Or run the repository's **Build Android earpiece test** GitHub Actions workflow on the `android-earpiece-test` branch. The artifact is `Clean-Lanka-Earpiece-Test-APK`, containing `app-debug.apk`. This is a debug-signed test APK and is not a Play Store release. Android 12 / API 31 or newer is required.

## Phone acceptance test — required, not yet performed

1. Install the APK on two physical Android 12+ phones. Update Android System WebView. Keep both apps visible.
2. Sign in as Customer on one and Worker on the other; allow microphone access when starting/answering a call.
3. Call in both directions. Confirm sound physically comes from the small receiver at the top of each phone without using a speaker button. Test with low volume first.
4. End calls from both sides; check the Android microphone indicator turns off and ordinary media volume/routing returns.
5. Try leaving the app, denying microphone permission, audio interruptions and a phone without an earpiece. The call must stop/refuse rather than continue over a loudspeaker.
6. Test photo/PDF uploads and Back navigation. Email verification/reset links opened in another browser do not automatically sign this app in; log in inside this app afterwards.

Not included: background incoming-call delivery, background calling, notifications, native CallKit/Telecom integration, Bluetooth/headset switching, Play Store signing/distribution. Do not infer those capabilities from the website. No secrets or Supabase service keys are embedded. The native bridge and microphone grants are limited to the main Clean Lanka HTTPS origin; other pages open externally. Camera requests are denied; photo upload uses Android's file picker.

## References

- https://developer.android.com/reference/android/media/AudioManager#setCommunicationDevice(android.media.AudioDeviceInfo)
- https://developer.android.com/reference/android/media/AudioDeviceInfo#TYPE_BUILTIN_EARPIECE
- https://developer.android.com/develop/ui/views/layout/webapps/native-api-access-jsbridge
