package lk.cleanlanka.earpiecetest;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.WindowInsets;
import android.webkit.*;
import android.widget.Toast;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.Set;

/** Foreground-only test client. Uses native communication routing, never a speaker fallback. */
public class MainActivity extends Activity {
 private WebView web;
 private AudioManager audio;
 private AudioFocusRequest focus;
 private final Handler handler=new Handler(Looper.getMainLooper());
 private boolean calling=false,foreground=false;
 private int previousMode=AudioManager.MODE_NORMAL,generation=0;
 private PermissionRequest microphoneRequest;
 private ValueCallback<Uri[]> fileResult;
 private static final int MIC=10, FILE=11;
 private final AudioManager.OnCommunicationDeviceChangedListener deviceListener=device->{
  if(calling && (device==null || device.getType()!=AudioDeviceInfo.TYPE_BUILTIN_EARPIECE)) failClosed();
 };

 @Override public void onCreate(Bundle saved){
  super.onCreate(saved);
  audio=getSystemService(AudioManager.class);
  web=new WebView(this);setContentView(web);
  web.setOnApplyWindowInsetsListener((view,insets)->{
   android.graphics.Insets bars=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout());
   view.setPadding(bars.left,bars.top,bars.right,bars.bottom);return insets;
  });
  WebSettings settings=web.getSettings();settings.setJavaScriptEnabled(true);settings.setDomStorageEnabled(true);
  settings.setAllowFileAccess(false);settings.setAllowContentAccess(false);
  settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
  settings.setMediaPlaybackRequiresUserGesture(false);
  CookieManager.getInstance().setAcceptCookie(true);
  web.setWebViewClient(new WebViewClient(){
   @Override public boolean shouldOverrideUrlLoading(WebView view,WebResourceRequest request){
    if(trusted(request.getUrl()))return false;
    if(request.isForMainFrame()){
     stopWebCall();
     String scheme=request.getUrl().getScheme();
     if("https".equals(scheme)||"tel".equals(scheme)||"mailto".equals(scheme)){
      try{startActivity(new Intent(Intent.ACTION_VIEW,request.getUrl()));}catch(Exception ignored){}
     }
    }
    return true;
   }
   @Override public void onReceivedSslError(WebView view,android.webkit.SslErrorHandler h,android.net.http.SslError e){h.cancel();}
  });
  web.setWebChromeClient(new WebChromeClient(){
   @Override public void onPermissionRequest(PermissionRequest request){
    runOnUiThread(()->{
     if(!foreground || !trusted(request.getOrigin())){request.deny();return;}
     boolean wantsAudio=false;
     for(String resource:request.getResources())if(PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(resource))wantsAudio=true;
     if(!wantsAudio){request.deny();return;}
     if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED){request.grant(new String[]{PermissionRequest.RESOURCE_AUDIO_CAPTURE});return;}
     if(microphoneRequest!=null)microphoneRequest.deny();
     microphoneRequest=request;requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO},MIC);
    });
   }
   @Override public void onPermissionRequestCanceled(PermissionRequest request){if(microphoneRequest==request)microphoneRequest=null;}
   @Override public boolean onShowFileChooser(WebView view,ValueCallback<Uri[]> result,FileChooserParams params){
    if(fileResult!=null)fileResult.onReceiveValue(null);fileResult=result;
    try{startActivityForResult(params.createIntent(),FILE);}catch(Exception e){fileResult.onReceiveValue(null);fileResult=null;}
    return true;
   }
  });
  if(!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)||!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)){
   Toast.makeText(this,"Update Android System WebView before using this test app.",Toast.LENGTH_LONG).show();finish();return;
  }
  Set<String> origins=Set.of("https://cleanlanka.lk","https://www.cleanlanka.lk");
  WebViewCompat.addWebMessageListener(web,"CleanLankaAudio",origins,(view,message,origin,mainFrame,reply)->{
   if(!mainFrame||!trusted(origin))return;
   try{
    JSONObject request=new JSONObject(message.getData());String id=request.getString("id"),action=request.getString("action");
    if("end".equals(action)){endAudio();reply.postMessage(response(id,true,""));return;}
    if(!"begin".equals(action)&&!"verify".equals(action)){reply.postMessage(response(id,false,"Unknown request"));return;}
    if(!foreground){reply.postMessage(response(id,false,"Keep the app open to call."));return;}
    boolean ok="begin".equals(action)?beginAudio():calling&&earpieceSelected();
    if(!ok){endAudio();reply.postMessage(response(id,false,"Earpiece routing unavailable. Call blocked."));return;}
    int token=generation;
    // Android routing is asynchronous. Confirm the selected device before JS may play audio.
    confirmRoute(token,0,success->reply.postMessage(response(id,success,success?"":"Earpiece route was not confirmed. Call blocked.")));
   }catch(Exception ignored){}
  });
  try{
   ByteArrayOutputStream buffer=new ByteArrayOutputStream();
   try(InputStream input=getAssets().open("call-bridge.js")){byte[] chunk=new byte[4096];int count;while((count=input.read(chunk))!=-1)buffer.write(chunk,0,count);}
   String script=buffer.toString(StandardCharsets.UTF_8.name());
   WebViewCompat.addDocumentStartJavaScript(web,script,origins);
  }catch(Exception e){Toast.makeText(this,"Call controls could not load.",Toast.LENGTH_LONG).show();finish();return;}
  audio.addOnCommunicationDeviceChangedListener(getMainExecutor(),deviceListener);
  web.loadUrl("https://cleanlanka.lk/?cl_android_earpiece=1");
 }
 private boolean trusted(Uri url){
  return "https".equals(url.getScheme()) && (url.getPort()==-1||url.getPort()==443) && ("cleanlanka.lk".equals(url.getHost())||"www.cleanlanka.lk".equals(url.getHost()));
 }
 private interface RouteCallback{void done(boolean ok);}
 private void confirmRoute(int token,int attempt,RouteCallback callback){
  if(token!=generation||!calling||!foreground){callback.done(false);return;}
  if(earpieceSelected()){callback.done(true);return;}
  if(attempt>=10){endAudio();callback.done(false);return;}
  handler.postDelayed(()->confirmRoute(token,attempt+1,callback),100);
 }
 private boolean earpieceSelected(){
  AudioDeviceInfo selected=audio.getCommunicationDevice();
  return audio.getMode()==AudioManager.MODE_IN_COMMUNICATION && selected!=null&&selected.getType()==AudioDeviceInfo.TYPE_BUILTIN_EARPIECE;
 }
 private boolean beginAudio(){
  if(calling)return earpieceSelected();
  AudioDeviceInfo ear=null;
  for(AudioDeviceInfo device:audio.getAvailableCommunicationDevices())if(device.getType()==AudioDeviceInfo.TYPE_BUILTIN_EARPIECE){ear=device;break;}
  if(ear==null)return false;
  previousMode=audio.getMode();generation++;
  focus=new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
   .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
   .setOnAudioFocusChangeListener(change->{if(change<0&&calling)failClosed();},handler).build();
  if(audio.requestAudioFocus(focus)!=AudioManager.AUDIOFOCUS_REQUEST_GRANTED){focus=null;return false;}
  try{
   audio.setMode(AudioManager.MODE_IN_COMMUNICATION);
   if(!audio.setCommunicationDevice(ear)){endAudio();return false;}
   calling=true;setVolumeControlStream(AudioManager.STREAM_VOICE_CALL);web.setKeepScreenOn(true);return true;
  }catch(Exception e){endAudio();return false;}
 }
 private void endAudio(){
  boolean hadAudio=calling||focus!=null;
  calling=false;generation++;
  if(hadAudio){try{audio.clearCommunicationDevice();audio.setMode(previousMode);}catch(Exception ignored){}}
  if(focus!=null){audio.abandonAudioFocusRequest(focus);focus=null;}
  if(web!=null)web.setKeepScreenOn(false);
  setVolumeControlStream(AudioManager.USE_DEFAULT_STREAM_TYPE);
 }
 private void stopWebCall(){stopWebCall("Call stopped because the app left the foreground.");}
 private void stopWebCall(String reason){if(web!=null)web.evaluateJavascript("window.__clStopNativeCall&&window.__clStopNativeCall("+JSONObject.quote(reason)+")",ignored->endAudio());else endAudio();}
 private void failClosed(){
  if(!calling)return;
  // Stop all call tracks and remote playback when Android reports loss of the earpiece.
  stopWebCall("Earpiece route lost. Call stopped.");
  Toast.makeText(this,"Earpiece route lost. Call stopped.",Toast.LENGTH_LONG).show();
 }
 private String response(String id,boolean ok,String error){
  try{return new JSONObject().put("id",id).put("ok",ok).put("error",error).toString();}catch(Exception e){return "{}";}
 }
 @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] results){
  super.onRequestPermissionsResult(request,permissions,results);
  if(request==MIC&&microphoneRequest!=null){
   PermissionRequest pending=microphoneRequest;microphoneRequest=null;
   if(results.length>0&&results[0]==PackageManager.PERMISSION_GRANTED){
    handler.postDelayed(()->{if(foreground&&!isFinishing())pending.grant(new String[]{PermissionRequest.RESOURCE_AUDIO_CAPTURE});else pending.deny();},150);
   }else pending.deny();
  }
 }
 @Override protected void onActivityResult(int request,int result,Intent data){
  super.onActivityResult(request,result,data);
  if(request==FILE&&fileResult!=null){fileResult.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(result,data));fileResult=null;}
 }
 @Override protected void onResume(){super.onResume();foreground=true;if(web!=null)web.onResume();}
 @Override protected void onPause(){foreground=false;if(calling){stopWebCall();}super.onPause();}
 @Override public void onBackPressed(){if(web.canGoBack())web.goBack();else super.onBackPressed();}
 @Override protected void onDestroy(){
  endAudio();audio.removeOnCommunicationDeviceChangedListener(deviceListener);
  if(microphoneRequest!=null)microphoneRequest.deny();if(fileResult!=null)fileResult.onReceiveValue(null);
  if(web!=null){web.stopLoading();web.destroy();}super.onDestroy();
 }
}
