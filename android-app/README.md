# Clean Lanka Android

This is a small, security-conscious Android WebView shell for the existing live
website at **https://cleanlanka.lk/**. It does **not** duplicate or change the
Supabase backend, authentication, RLS, website JavaScript, job posts, or chat.

## Features
- Home page and existing customer/worker/admin web flows
- WebView JavaScript and DOM storage, secure HTTPS only
- Android Back support via WebView browsing history
- Native file chooser for PDFs and photographs, including optional camera
- No broad file-storage or camera permissions (camera is handled by the external
  system Camera app; the temporary image is shared via private FileProvider)
- External telephone, email, WhatsApp, and other off-site links open in
  appropriate Android apps or the browser
- Basic loading indicator, offline notice, and retry
- Secure-by-default WebView settings; file:// access and HTTP are disabled
- Target Android 16 / API 36; minimum Android 8.0 / API 26

## Build using Android Studio
1. Install Android Studio, JDK 17, and Android SDK Platform 36.
2. Open the `android-app` directory as a project.
3. Allow Gradle sync to download dependencies (AGP 8.13.2 / Gradle 8.13).
4. Use **Build > Build Bundle(s) / APK(s) > Build APK(s)** or
   `gradle :app:assembleDebug`.
5. The test APK is at `app/build/outputs/apk/debug/app-debug.apk`.

## GitHub Actions
The workflow in `.github/workflows/build-android-apk.yml` builds the same
debug/testing APK and publishes it as an artifact under the Actions run.
Download that artifact ZIP, extract the APK, then install **only on a test phone**.

## Before Google Play release
- Debug APK is **not** a Play Store release. Set up your own permanent private
  Android signing key, store it only in secure CI secrets and make a signed AAB.
- Add and test Android App Links if you want email verification/reset links
  to return from the browser directly to the installed app.
- Conduct real-phone testing of Android Back, login, live chat, document upload,
  camera, PDF picker, accessibility, and mobile keyboard before release.
- Push notifications are not enabled. Site notifications in WebView do not
  automatically become native Android push notifications.
- App loads the **live** website and needs Internet. Its web functionality
  depends on cleanlanka.lk remaining available.
- Review Google Play privacy/data-safety declarations and platform policies.

**Security warning:** do not check in signing keys, Supabase service role keys,
user data, NIC documents, police clearance files, or administrator passwords.

**Repository backup branch:**
`backup-before-android-app-project-2026-11-09`
