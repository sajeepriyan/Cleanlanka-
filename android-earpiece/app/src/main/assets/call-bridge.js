(() => {
 'use strict';
 if (window.top !== window || !window.CleanLankaAudio || window.__clEarpieceApp) return;
 window.__clEarpieceApp = true;
 let counter=0, blocked=false;
 const pending=new Map(), localTracks=new Set();
 function request(action) {
  return new Promise((resolve,reject)=>{
   const id=String(++counter);
   const timer=setTimeout(()=>{pending.delete(id);reject(new Error('Earpiece control did not respond.'));},5000);
   pending.set(id,{resolve,reject,timer});
   CleanLankaAudio.postMessage(JSON.stringify({id,action}));
  });
 }
 function stopCall(reason) {
  blocked=true;
  const audio=document.getElementById('clAudioRemote');
  if(audio){audio.muted=true;audio.pause();}
  for(const track of [...localTracks])track.stop();
  const end=document.getElementById('clAudioEnd');
  if(end&&!end.hidden)end.click();
  const error=document.getElementById('clAudioError');
  if(error)error.textContent=reason;
 }
 CleanLankaAudio.onmessage=event=>{
  let data;try{data=JSON.parse(event.data);}catch(_){return;}
  if(data.event==='routeLost'){stopCall('Earpiece unavailable. Call stopped to prevent speaker playback.');return;}
  const job=pending.get(data.id);if(!job)return;
  clearTimeout(job.timer);pending.delete(data.id);
  if(data.ok)job.resolve(data);else job.reject(new Error(data.error||'Earpiece unavailable.'));
 };
 const originalGetUserMedia=navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
 const originalStop=MediaStreamTrack.prototype.stop;
 MediaStreamTrack.prototype.stop=function(){
  originalStop.call(this);localTracks.delete(this);
  if(!localTracks.size)request('end').catch(()=>{});
 };
 navigator.mediaDevices.getUserMedia=async constraints=>{
  if(!constraints?.audio)return originalGetUserMedia(constraints);
  const stream=await originalGetUserMedia(constraints);
  try {
   await request('begin');blocked=false;
   stream.getAudioTracks().forEach(track=>localTracks.add(track));
   return stream;
  } catch(error) {stream.getTracks().forEach(track=>originalStop.call(track));await request('end').catch(()=>{});throw error;}
 };
 const originalPlay=HTMLMediaElement.prototype.play;
 HTMLMediaElement.prototype.play=function(){
  if(this.id!=='clAudioRemote')return originalPlay.call(this);
  return (async()=>{
   if(blocked)throw new Error('Call audio is blocked until the earpiece is available.');
   await request('verify');this.muted=false;
   return originalPlay.call(this);
  })().catch(error=>{stopCall(error.message);throw error;});
 };
 function configureCallUI(){
  const audio=document.getElementById('clAudioRemote');if(audio)audio.autoplay=false;
  const output=document.getElementById('clAudioOutput');if(output){output.hidden=true;output.disabled=true;}
 }
 new MutationObserver(configureCallUI).observe(document,{childList:true,subtree:true});
 document.addEventListener('DOMContentLoaded',()=>{
  const style=document.createElement('style');
  style.textContent='#clAudioOutput,#clAudioOutputPanel{display:none!important}';document.head.append(style);
  configureCallUI();
 });
 window.addEventListener('pagehide',()=>{for(const track of [...localTracks])track.stop();request('end').catch(()=>{});});
 window.__clStopNativeCall=reason=>stopCall(reason||'Call stopped because the app left the foreground.');
})();
