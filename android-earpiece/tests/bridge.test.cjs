const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const source=fs.readFileSync(new URL('../app/src/main/assets/call-bridge.js',`file://${__filename}`),'utf8');
function fixture({route=true}={}){
 let stopped=0,played=0,ended=0;const actions=[];
 class Track{stop(){stopped++;}}
 class Media{play(){played++;return Promise.resolve();}pause(){}}
 const track=new Track(),stream={getAudioTracks:()=>[track],getTracks:()=>[track]};
 const audio=new Media();audio.id='clAudioRemote';audio.muted=true;
 const elements={clAudioRemote:audio,clAudioEnd:{hidden:false,click(){ended++;}}};
 const bridge={postMessage(raw){const data=JSON.parse(raw);actions.push(data.action);queueMicrotask(()=>bridge.onmessage({data:JSON.stringify({id:data.id,ok:data.action==='end'||route,error:'No earpiece'})}));}};
 const document={getElementById:id=>elements[id]||null,addEventListener(){}};
 const window={CleanLankaAudio:bridge,addEventListener(){}};window.top=window;window.window=window;
 const context={window,CleanLankaAudio:bridge,document,navigator:{mediaDevices:{getUserMedia:async()=>stream}},MediaStreamTrack:Track,HTMLMediaElement:Media,MutationObserver:class{observe(){}},setTimeout,clearTimeout,Map,Set,console};
 vm.runInNewContext(source,context);
 return {context,stream,audio,actions,counts:()=>({stopped,played,ended})};
}
test('no remote playback when native earpiece verification fails',async()=>{
 const f=fixture({route:false});await assert.rejects(f.audio.play(),/No earpiece/);
 assert.equal(f.counts().played,0);assert.equal(f.audio.muted,true);
});
test('failed begin releases microphone and refuses call setup',async()=>{
 const f=fixture({route:false});await assert.rejects(f.context.navigator.mediaDevices.getUserMedia({audio:true}),/No earpiece/);
 assert.equal(f.counts().stopped,1);assert.deepEqual(f.actions,['begin','end']);
});
test('call media waits for native verification and ending releases routing',async()=>{
 const f=fixture();await f.context.navigator.mediaDevices.getUserMedia({audio:true});await f.audio.play();
 assert.deepEqual(f.actions,['begin','verify']);assert.equal(f.counts().played,1);
 f.stream.getTracks()[0].stop();await new Promise(setImmediate);assert.equal(f.actions.at(-1),'end');
});
test('leaving foreground stops remote playback and local microphone',async()=>{
 const f=fixture();await f.context.navigator.mediaDevices.getUserMedia({audio:true});
 f.context.window.__clStopNativeCall();assert.equal(f.counts().stopped,1);assert.equal(f.counts().ended,1);assert.equal(f.audio.muted,true);
});
