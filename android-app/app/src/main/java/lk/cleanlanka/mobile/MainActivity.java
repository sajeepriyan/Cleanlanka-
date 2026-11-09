package lk.cleanlanka.mobile;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Insets;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Message;
import android.os.SystemClock;
import android.os.Environment;
import android.provider.MediaStore;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.webkit.CookieManager;
import android.webkit.PermissionRequest;
import android.webkit.SslErrorHandler;
import android.net.http.SslError;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import androidx.core.content.FileProvider;

import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Clean Lanka Android client.
 *
 * Loads the existing HTTPS website; Supabase Auth, RLS, messaging, dashboards,
 * jobs and profile logic continue to run on the actual website.
 *
 * No JavaScript bridge is exposed. Untrusted websites never run inside the
 * authenticated WebView. Third-party cookies and file:// access are disabled.
 */
public final class MainActivity extends Activity {
    private static final String HOME_URL = "https://cleanlanka.lk/";
    private static final String HOST = "cleanlanka.lk";
    private static final int FILE_CHOOSER_REQUEST = 1407;

    private WebView webView;
    private ProgressBar progressBar;
    private LinearLayout connectionError;
    private ValueCallback<Uri[]> fileCallback;
    private Uri pendingCameraUri;
    private File pendingCameraFile;
    private long lastBackPress;
    private boolean mainFrameFailed;

    private int dp(float pixels) {
        return Math.round(pixels * getResources().getDisplayMetrics().density);
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // Target SDK 36 uses edge-to-edge. Keep WebView and buttons clear of
        // system status / navigation bars without changing the website itself.
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.rgb(243, 250, 246));
        if (Build.VERSION.SDK_INT >= 30) {
            root.setOnApplyWindowInsetsListener((view, windowInsets) -> {
                Insets edges = windowInsets.getInsets(WindowInsets.Type.systemBars());
                view.setPadding(edges.left, edges.top, edges.right, edges.bottom);
                return windowInsets;
            });
        }

        webView = new WebView(this);
        root.addView(webView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));

        progressBar = new ProgressBar(this, null,
                android.R.attr.progressBarStyleHorizontal);
        progressBar.setMax(100);
        progressBar.setProgress(5);
        FrameLayout.LayoutParams progressParams = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(3), Gravity.TOP);
        root.addView(progressBar, progressParams);

        connectionError = new LinearLayout(this);
        connectionError.setOrientation(LinearLayout.VERTICAL);
        connectionError.setGravity(Gravity.CENTER);
        connectionError.setPadding(dp(24), dp(24), dp(24), dp(24));
        connectionError.setBackgroundColor(Color.rgb(243, 250, 246));

        TextView title = new TextView(this);
        title.setText(R.string.offline_title);
        title.setTextColor(Color.rgb(15, 81, 50));
        title.setTextSize(23f);
        title.setGravity(Gravity.CENTER);
        title.setTypeface(null, android.graphics.Typeface.BOLD);
        connectionError.addView(title);

        TextView description = new TextView(this);
        description.setText(R.string.offline_message);
        description.setTextColor(Color.rgb(54, 83, 72));
        description.setTextSize(16f);
        description.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams descriptionParams =
                new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT);
        descriptionParams.setMargins(0, dp(15), 0, dp(20));
        connectionError.addView(description, descriptionParams);

        Button retry = new Button(this);
        retry.setAllCaps(false);
        retry.setText(R.string.retry);
        retry.setOnClickListener(v -> {
            connectionError.setVisibility(View.GONE);
            webView.setVisibility(View.VISIBLE);
            mainFrameFailed = false;
            webView.loadUrl(HOME_URL);
        });
        connectionError.addView(retry);

        root.addView(connectionError, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));
        connectionError.setVisibility(View.GONE);
        setContentView(root);

        removeOldCameraCaptures();
        setupWebView();

        if (savedInstanceState != null && webView.restoreState(savedInstanceState) != null) {
            // Restore WebView history following device rotation or process restore.
        } else {
            webView.loadUrl(HOME_URL);
        }
    }

    private boolean isCleanLankaHost(Uri address) {
        if (address == null || !"https".equalsIgnoreCase(address.getScheme())) {
            return false;
        }
        String host = address.getHost();
        return HOST.equalsIgnoreCase(host) || ("www." + HOST).equalsIgnoreCase(host);
    }

    private void externalLink(Uri address) {
        if (address == null) return;
        String scheme = address.getScheme();
        if (scheme == null) return;
        scheme = scheme.toLowerCase(Locale.ROOT);
        if (!("https".equals(scheme) || "tel".equals(scheme)
                || "mailto".equals(scheme) || "sms".equals(scheme))) {
            // Explicitly reject file://, content://, intent:// and unknown links.
            return;
        }
        try {
            Intent intent = new Intent(Intent.ACTION_VIEW, address);
            intent.addCategory(Intent.CATEGORY_BROWSABLE);
            startActivity(intent);
        } catch (ActivityNotFoundException | SecurityException ignored) {
            Toast.makeText(this, "No application can open this link",
                    Toast.LENGTH_SHORT).show();
        }
    }

    private void setupWebView() {
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setSupportMultipleWindows(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(true);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setMediaPlaybackRequiresUserGesture(true);
        if (Build.VERSION.SDK_INT >= 26) {
            settings.setSafeBrowsingEnabled(true);
        }

        CookieManager cookieManager = CookieManager.getInstance();
        cookieManager.setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, false);

        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG);

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri address = request.getUrl();
                if (isCleanLankaHost(address)) {
                    return false;
                }
                // Links leaving cleanlanka.lk open in Android's regular browser,
                // never inside the authenticated WebView.
                if (request.isForMainFrame()) {
                    externalLink(address);
                }
                return true;
            }

            @Override
            public void onPageStarted(WebView view, String url, android.graphics.Bitmap favicon) {
                mainFrameFailed = false;
                progressBar.setVisibility(View.VISIBLE);
                progressBar.setProgress(5);
                connectionError.setVisibility(View.GONE);
                webView.setVisibility(View.VISIBLE);
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                progressBar.setVisibility(View.GONE);
                if (mainFrameFailed) {
                    showConnectionError();
                }
                CookieManager.getInstance().flush();
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request,
                    WebResourceError error) {
                if (request.isForMainFrame()) {
                    mainFrameFailed = true;
                    showConnectionError();
                }
            }

            @Override
            public void onReceivedHttpError(WebView view, WebResourceRequest request,
                    WebResourceResponse response) {
                if (request.isForMainFrame() && response.getStatusCode() >= 500) {
                    mainFrameFailed = true;
                    showConnectionError();
                }
            }

            @Override
            public void onReceivedSslError(WebView view, SslErrorHandler handler,
                    SslError error) {
                // Never bypass certificate problems on a login/document site.
                handler.cancel();
                mainFrameFailed = true;
                showConnectionError();
            }
        });

        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onProgressChanged(WebView view, int progress) {
                if (!mainFrameFailed) {
                    progressBar.setProgress(progress);
                    progressBar.setVisibility(progress >= 100 ? View.GONE : View.VISIBLE);
                }
            }

            @Override
            public boolean onShowFileChooser(WebView source,
                    ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (!isCleanLankaHost(Uri.parse(source.getUrl() == null ? "" : source.getUrl()))) {
                    callback.onReceiveValue(null);
                    return true;
                }
                if (fileCallback != null) {
                    fileCallback.onReceiveValue(null);
                }
                fileCallback = callback;
                pendingCameraUri = null;
                pendingCameraFile = null;

                try {
                    Intent pickerIntent = params.createIntent();
                    Intent cameraIntent = null;
                    if (allowsImage(params)) {
                        cameraIntent = makePrivateCameraIntent();
                    }

                    Intent launch;
                    if (params.isCaptureEnabled() && cameraIntent != null) {
                        launch = cameraIntent;
                    } else {
                        launch = Intent.createChooser(pickerIntent,
                                getString(R.string.upload_choose_file));
                        if (cameraIntent != null) {
                            launch.putExtra(Intent.EXTRA_INITIAL_INTENTS,
                                    new Intent[]{cameraIntent});
                        }
                    }
                    startActivityForResult(launch, FILE_CHOOSER_REQUEST);
                    return true;
                } catch (ActivityNotFoundException | SecurityException | IOException e) {
                    if (fileCallback != null) {
                        fileCallback.onReceiveValue(null);
                        fileCallback = null;
                    }
                    discardPendingCameraFile();
                    Toast.makeText(MainActivity.this, "Cannot open the file picker",
                            Toast.LENGTH_SHORT).show();
                    return true;
                }
            }

            @Override
            public void onPermissionRequest(PermissionRequest request) {
                // WebRTC camera/microphone is intentionally disabled for v1.
                // Photo uploads use a user-initiated Android file/camera picker.
                runOnUiThread(request::deny);
            }

            @Override
            public void onGeolocationPermissionsShowPrompt(String origin,
                    android.webkit.GeolocationPermissions.Callback callback) {
                callback.invoke(origin, false, false);
            }

            @Override
            public boolean onCreateWindow(WebView view, boolean isDialog,
                    boolean isUserGesture, Message resultMessage) {
                if (!isUserGesture) return false;
                // Links using target=_blank open in the external browser.
                WebView popup = new WebView(MainActivity.this);
                popup.setWebViewClient(new WebViewClient() {
                    @Override
                    public boolean shouldOverrideUrlLoading(WebView child,
                            WebResourceRequest request) {
                        externalLink(request.getUrl());
                        child.post(child::destroy);
                        return true;
                    }

                    @Override
                    public void onPageStarted(WebView child, String url,
                            android.graphics.Bitmap favicon) {
                        externalLink(Uri.parse(url));
                        child.post(child::destroy);
                    }
                });
                WebView.WebViewTransport transport =
                        (WebView.WebViewTransport) resultMessage.obj;
                transport.setWebView(popup);
                resultMessage.sendToTarget();
                return true;
            }

            @Override
            public void onCloseWindow(WebView window) {
                window.destroy();
            }
        });

        webView.setDownloadListener((url, userAgent, contentDisposition, mimeType,
                contentLength) -> {
            Uri address = Uri.parse(url);
            // DownloadManager cannot automatically access private WebView sessions.
            // Use the browser for explicitly selected HTTPS downloads.
            if ("https".equalsIgnoreCase(address.getScheme())) {
                externalLink(address);
            } else {
                Toast.makeText(MainActivity.this,
                        "This download needs a browser-compatible link",
                        Toast.LENGTH_LONG).show();
            }
        });
    }

    private boolean allowsImage(WebChromeClient.FileChooserParams params) {
        for (String type : params.getAcceptTypes()) {
            if (type != null && type.toLowerCase(Locale.ROOT).contains("image")) {
                return true;
            }
        }
        return false;
    }

    private Intent makePrivateCameraIntent() throws IOException {
        Intent capture = new Intent(MediaStore.ACTION_IMAGE_CAPTURE);
        if (capture.resolveActivity(getPackageManager()) == null) return null;

        File pictureDir = getExternalFilesDir(Environment.DIRECTORY_PICTURES);
        if (pictureDir == null) return null;

        pendingCameraFile = File.createTempFile(
                "cl_upload_", ".jpg", pictureDir);
        pendingCameraUri = FileProvider.getUriForFile(this,
                getPackageName() + ".fileprovider", pendingCameraFile);

        capture.putExtra(MediaStore.EXTRA_OUTPUT, pendingCameraUri);
        capture.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
                | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        capture.setClipData(ClipData.newRawUri("Clean Lanka photo", pendingCameraUri));
        return capture;
    }

    private void showConnectionError() {
        progressBar.setVisibility(View.GONE);
        webView.setVisibility(View.GONE);
        connectionError.setVisibility(View.VISIBLE);
    }

    private static boolean isUserSelectedContent(Uri uri) {
        if (uri == null) return false;
        // System pickers and our FileProvider supply content:// URIs. Never
        // send file:// paths or https URLs to a WebView file upload callback.
        return "content".equalsIgnoreCase(uri.getScheme());
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != FILE_CHOOSER_REQUEST) return;

        Uri[] selected = null;
        if (resultCode == RESULT_OK) {
            List<Uri> items = new ArrayList<>();
            if (data != null && data.getClipData() != null) {
                ClipData clips = data.getClipData();
                for (int i = 0; i < clips.getItemCount(); i++) {
                    Uri uri = clips.getItemAt(i).getUri();
                    if (isUserSelectedContent(uri)) items.add(uri);
                }
            } else if (data != null && data.getData() != null) {
                Uri uri = data.getData();
                if (isUserSelectedContent(uri)) items.add(uri);
            } else if (pendingCameraUri != null && pendingCameraFile != null
                    && pendingCameraFile.length() > 0L) {
                items.add(pendingCameraUri);
            }
            if (!items.isEmpty()) {
                selected = items.toArray(new Uri[0]);
            }
        }

        if (fileCallback != null) {
            fileCallback.onReceiveValue(selected);
            fileCallback = null;
        }
        boolean keptCamera = false;
        if (selected != null && pendingCameraUri != null) {
            for (Uri uri : selected) {
                if (pendingCameraUri.equals(uri)) {
                    keptCamera = true;
                    break;
                }
            }
        }
        if (!keptCamera) discardPendingCameraFile();
        pendingCameraFile = null;
        pendingCameraUri = null;
    }

    private void discardPendingCameraFile() {
        if (pendingCameraFile != null) {
            // Only app-private camera files are deleted; never user documents.
            //noinspection ResultOfMethodCallIgnored
            pendingCameraFile.delete();
        }
        pendingCameraFile = null;
        pendingCameraUri = null;
    }

    private void removeOldCameraCaptures() {
        File folder = getExternalFilesDir(Environment.DIRECTORY_PICTURES);
        if (folder == null || !folder.isDirectory()) return;
        File[] files = folder.listFiles();
        if (files == null) return;
        long cutoff = System.currentTimeMillis() - (24L * 60 * 60 * 1000);
        for (File file : files) {
            if (file.isFile() && file.getName().startsWith("cl_upload_")
                    && file.getName().endsWith(".jpg")
                    && file.lastModified() < cutoff) {
                //noinspection ResultOfMethodCallIgnored
                file.delete();
            }
        }
    }

    @Override
    public void onBackPressed() {
        if (connectionError.getVisibility() == View.VISIBLE) {
            connectionError.setVisibility(View.GONE);
            webView.setVisibility(View.VISIBLE);
            webView.loadUrl(HOME_URL);
            return;
        }
        if (webView != null && webView.canGoBack()) {
            // Respects browser/SPA History API as used by Clean Lanka's
            // service pages, dashboards and in-page messages.
            webView.goBack();
            return;
        }
        String current = webView == null ? null : webView.getUrl();
        if (current != null && isCleanLankaHost(Uri.parse(current))
                && !HOME_URL.equals(current)
                && !("https://www.cleanlanka.lk/").equals(current)) {
            webView.loadUrl(HOME_URL);
            return;
        }
        if (SystemClock.elapsedRealtime() - lastBackPress < 2000) {
            super.onBackPressed();
        } else {
            lastBackPress = SystemClock.elapsedRealtime();
            Toast.makeText(this, R.string.back_again, Toast.LENGTH_SHORT).show();
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        if (webView != null) webView.saveState(outState);
        super.onSaveInstanceState(outState);
    }

    @Override
    protected void onDestroy() {
        if (fileCallback != null) {
            fileCallback.onReceiveValue(null);
            fileCallback = null;
        }
        if (webView != null) {
            webView.stopLoading();
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }
}
