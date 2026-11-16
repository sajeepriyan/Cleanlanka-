const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const html=fs.readFileSync('index.html','utf8');
const code=html.match(/<script id="cl-audio-calls-script">([\s\S]*?)<\/script>/)[1];
const tick=async()=>{for(let i=0;i<12;i++)await new Promise(resolve=>setImmediate(resolve));};
const clone=x=>JSON.parse(JSON.stringify(x));
function server(){
 const calls=new Map(),signals=[],clients=[];let next=0,signalId=0;
 function notify(table,event,row){for(const client of clients)for(const listener of client.listeners){if(listener.table!==table||listener.event!=='*'&&listener.event!==event)continue;const [key,value]=String(listener.filter||'').split('=eq.');if(key&&row[key]!==value)continue;if(![row.caller_id,row.callee_id].includes(client.uid)&&table==='cl_audio_calls')continue;queueMicrotask(()=>listener.fn({new:clone(row)}));}}
 function client(uid){
  const c={uid,listeners:[],authCallback:null};clients.push(c);
  c.auth={getSession:async()=>({data:{session:{user:{id:uid},access_token:'test-token'}}}),onAuthStateChange:fn=>{c.authCallback=fn;}};
  c.channel=()=>{const channel={on(type,config,fn){c.listeners.push({...config,fn});return this;},subscribe(fn){queueMicrotask(()=>fn('SUBSCRIBED'));return this;}};return channel;};
  c.removeChannel=async()=>{c.listeners=[];};
  c.rpc=async(name,args={})=>{
   if(name==='cl_audio_ice_config')return {data:[{urls:'stun:test.invalid'}]};
   if(name==='cl_start_audio_call'){
    if([...calls.values()].some(row=>['ringing','accepted'].includes(row.status)))return {error:{message:'Already on another call'}};
    const row={id:'call-'+(++next),conversation_id:args.p_conversation_id,caller_id:uid,callee_id:uid==='customer'?'worker':'customer',caller_name:uid==='customer'?'Verified Customer':'Verified Worker',callee_name:uid==='customer'?'Verified Worker':'Verified Customer',offer_sdp:args.p_offer,answer_sdp:null,status:'ringing',created_at:new Date().toISOString(),expires_at:new Date(Date.now()+60000).toISOString()};calls.set(row.id,row);notify('cl_audio_calls','INSERT',row);return {data:clone(row)};
   }
   const row=calls.get(args.p_call_id);if(!row)return {error:{message:'Call not found'}};
   if(args.p_action==='accept'&&row.status==='ringing'){row.status='accepted';row.answer_sdp=args.p_answer;row.answered_at=new Date().toISOString();}
   else if(!['ping','timeout','accept'].includes(args.p_action)&&['ringing','accepted'].includes(row.status)){row.status=args.p_action==='end'?(row.status==='accepted'?'ended':uid===row.caller_id?'cancelled':'declined'):args.p_action==='fail'?'failed':args.p_action==='decline'?'declined':'cancelled';row.ended_at=new Date().toISOString();row.offer_sdp=null;row.answer_sdp=null;}
   else if(args.p_action==='timeout'&&Date.parse(row.expires_at)<=Date.now())row.status='missed';
   notify('cl_audio_calls','UPDATE',row);return {data:clone(row)};
  };
  c.from=table=>{
   const filters=[];let one=false,limit=100;
   const b={select(){return b;},eq(k,v){filters.push(r=>r[k]===v);return b;},neq(k,v){filters.push(r=>r[k]!==v);return b;},order(){return b;},limit(n){limit=n;return b;},maybeSingle(){one=true;return b;},insert:async input=>{const row={...input,id:++signalId,sender_id:uid};signals.push(row);notify(table,'INSERT',row);return {data:row};},then(resolve,reject){const rows=(table==='cl_audio_calls'?[...calls.values()].filter(r=>[r.caller_id,r.callee_id].includes(uid)):signals).filter(r=>filters.every(fn=>fn(r))).slice(0,limit);return Promise.resolve({data:clone(one?(rows[0]||null):rows)}).then(resolve,reject);}};return b;
  };return c;
 }
 return {calls,signals,client};
}
function page(sb, options={}){
 const elements=new Map(),events={},streams=[],peers=[],timers=new Map();let timerId=0,micCalls=0,denyMic=false,pendingMic=null;
 class Element{
  constructor(id=''){this._id=id;this.hidden=false;this.listeners={};this.dataset={};this.style={};this.textContent='';this.children=[];this.isConnected=true;this.srcObject=null;if(id)elements.set(id,this);}
  set id(id){this._id=id;elements.set(id,this);}get id(){return this._id;}
  set innerHTML(value){for(const match of value.matchAll(/<[^>]+\bid="([^"]+)"([^>]*)>/g)){const e=new Element(match[1]);e.hidden=/\bhidden\b/.test(match[2]);}}
  addEventListener(name,fn){this.listeners[name]=fn;}
  setAttribute(name,value){this[name]=value;}
  getAttribute(name){return this[name]??null;}
  removeAttribute(name){delete this[name];}
  appendChild(child){this.children.push(child);return child;}
  append(...children){this.children.push(...children);}
  closest(){return null;}
  after(...nodes){this.afterNodes=nodes;}
  replaceChildren(...children){this.children=children;}
  focus(){document.activeElement=this;}
  click(){return this.listeners.click?.({target:this});}
  querySelectorAll(){return [...elements.values()].filter(e=>e.id.startsWith('clAudio'));}
  pause(){}async play(){}
 }
 const get=id=>elements.get(id)||new Element(id);
 const history=[new Element('history-customer'),new Element('history-worker')];
 const toolbars=[new Element('customer-toolbar'),new Element('worker-toolbar')];
 const sound={oscillators:[],resumes:0};
 const document={body:new Element('body'),activeElement:null,hidden:false,createElement:()=>new Element(),getElementById:get,addEventListener:(name,fn)=>{events[name]=fn;},querySelectorAll:selector=>selector==='[data-cl-call-history]'?history:selector==='.cl-audio-chat-toolbar'?toolbars:selector==='[data-cl-call-sound]'?toolbars.flatMap(t=>t.children).filter(e=>'clCallSound' in e.dataset):[]};
 document.activeElement=document.body;
 function makeStream(){const track={enabled:true,stopped:false,stop(){this.stopped=true;}};const stream={track,getTracks:()=>[track],getAudioTracks:()=>[track]};streams.push(stream);return stream;}
 class Peer{
  constructor(){this.remoteDescription=null;this.connectionState='new';this.candidates=[];peers.push(this);}
  addTrack(){}async createOffer(){return {type:'offer',sdp:'v=0\r\nm=audio offer'};}async createAnswer(){return {type:'answer',sdp:'v=0\r\nm=audio answer-'+peers.length};}
  async setLocalDescription(value){this.localDescription=value;this.onicecandidate?.({candidate:{toJSON:()=>({candidate:'candidate:one',sdpMid:'0'})}});}
  async setRemoteDescription(value){this.remoteDescription=value;}
  async addIceCandidate(value){this.candidates.push(value);}
  close(){this.connectionState='closed';}connect(){this.connectionState='connected';this.onconnectionstatechange?.();}
 }
 const navigator={mediaDevices:{getUserMedia:async options=>{micCalls++;assert.equal(options.video,false);if(denyMic)throw Object.assign(new Error('Denied'),{name:'NotAllowedError'});if(pendingMic)return pendingMic;return makeStream();}}};
 const window={supabaseClient:sb,isSecureContext:true,RTCPeerConnection:Peer,addEventListener:(name,fn)=>{events['window:'+name]=fn;}};
 if(options.sound){window.AudioContext=class{
  constructor(){this.state='suspended';this.currentTime=0;this.destination={};sound.context=this;}
  async resume(){sound.resumes++;if(options.resumeDenied)throw new Error('gesture required');this.state='running';this.onstatechange?.();}
  createGain(){return {gain:{setValueAtTime(){},exponentialRampToValueAtTime(){}},connect(){},disconnect(){}};}
  createOscillator(){const oscillator={frequency:{value:0},stopped:false,connect(){},disconnect(){},start(){},stop(){this.stopped=true;}};sound.oscillators.push(oscillator);return oscillator;}
 };}
 const ctx={window,document,navigator,RTCPeerConnection:Peer,MediaStream:class{},console,Date,Set,Promise,fetch:async(url,options)=>{assert.equal(url,'https://cleanlanka-turn.cleanlanka-audio.workers.dev');assert.equal(options.headers.Authorization,'Bearer test-token');assert.equal(JSON.parse(options.body).conversation_id,'conversation');return {ok:true,json:async()=>({iceServers:[{urls:'turns:turn.cloudflare.com:5349',username:'temporary',credential:'temporary'}]})};},AbortSignal,SUPABASE_URL:'https://test.invalid',SUPABASE_PUBLISHABLE_KEY:'test-public-key',setInterval:fn=>{const id=++timerId;timers.set(id,fn);return id;},clearInterval:id=>timers.delete(id),setTimeout:(fn,ms)=>{if(!ms){queueMicrotask(fn);return 0;}const id=++timerId;timers.set(id,fn);return id;},clearTimeout:id=>timers.delete(id),alert:message=>{get('alert').textContent=message;}};
 vm.createContext(ctx);vm.runInContext(code,ctx);
 if(options.routing){get('clAudioRemote').sinkId='';get('clAudioRemote').setSinkId=async id=>{if(id==='denied')throw new Error('Denied');get('clAudioRemote').sinkId=id;};navigator.mediaDevices.enumerateDevices=async()=>[{kind:'audiooutput',deviceId:'speaker-1',label:'Speakers'},{kind:'audiooutput',deviceId:'headset-1',label:'Headset'}];}
 return {api:window.clAudioCalls,get,streams,peers,events,sb,makeStream,sound,toolbars,micCount:()=>micCalls,deny:()=>{denyMic=true;},allow:()=>{denyMic=false;},setViewport:(width,screenWidth,height=800)=>{window.innerWidth=width;window.innerHeight=height;window.screen={width:screenWidth};window.matchMedia=()=>({matches:true});},delayMic:promise=>{pendingMic=promise;},setInsecure:()=>{window.isSecureContext=false;}};
}
(async()=>{
 const db=server(),customer=page(db.client('customer')),worker=page(db.client('worker'));await tick();
 assert.equal(worker.micCount(),0);
 await customer.api.start('conversation','Untrusted UI label');await tick();
 assert.equal(customer.get('clAudioName').textContent,'Verified Worker');
 assert.equal(worker.get('clAudioName').textContent,'Verified Customer');
 assert.equal(worker.get('clAudioStatus').textContent,'Incoming audio call');
 assert.equal(worker.micCount(),0,'Incoming call must not open microphone before Accept');
 const workerRpc=worker.sb.rpc;
 worker.sb.rpc=async(name,args)=>{
  const response=await workerRpc(name,args);
  if(name==='cl_audio_call_action'&&args.p_action==='accept'){
   const pc=worker.peers[0];
   pc.localDescription={...pc.localDescription,sdp:pc.localDescription.sdp+'\r\na=candidate:late-gathered-route'};
  }
  return response;
 };
 await worker.api.accept();await tick();
 assert.notEqual(worker.get('clAudioStatus').textContent,'Answered on another device','Late ICE candidates must not make this phone lose its own accepted call');
 assert.equal(worker.streams[0].track.stopped,false,'Accepting phone must keep its microphone active during ICE gathering');
 assert.equal(worker.micCount(),1);assert.equal(customer.peers[0].remoteDescription.type,'answer');
 assert.ok(worker.peers[0].candidates.length>0,'Buffered network candidates must drain after answer');
 customer.peers[0].connect();worker.peers[0].connect();await tick();
 worker.get('clAudioMute').click();assert.equal(worker.streams[0].track.enabled,false);worker.get('clAudioMute').click();assert.equal(worker.streams[0].track.enabled,true);
 customer.get('clAudioMinimize').click();assert.equal(customer.get('clAudioOverlay').hidden,true);assert.equal(customer.get('clAudioPill').hidden,false);customer.get('clAudioPill').click();assert.equal(customer.get('clAudioOverlay').hidden,false);
 await customer.api.end();await tick();assert.equal(worker.get('clAudioStatus').textContent,'Call ended');assert.ok([...customer.streams,...worker.streams].every(s=>s.track.stopped));
 await worker.api.start('conversation');await tick();assert.equal(customer.get('clAudioName').textContent,'Verified Worker');const beforeDecline=customer.micCount();await customer.api.end('decline');await tick();assert.equal(customer.micCount(),beforeDecline);assert.match(worker.get('clAudioStatus').textContent,/declined/);
 const db2=server(),cancel=page(db2.client('customer'));await tick();let resolveMic;cancel.delayMic(new Promise(resolve=>{resolveMic=resolve;}));const starting=cancel.api.start('conversation');await tick();await cancel.api.end();const late=cancel.makeStream();resolveMic(late);await starting;assert.equal(late.track.stopped,true);assert.equal(db2.calls.size,0,'Cancelling while microphone opens must not initiate a remote call');
 const denied=page(db2.client('worker'));await tick();denied.deny();await denied.api.start('conversation');assert.match(denied.get('clAudioError').textContent,/Microphone access is blocked/);assert.match(denied.get('clAudioError').textContent,/Android Settings/);assert.equal(db2.calls.size,0);
 const retryDB=server(),retryCaller=page(retryDB.client('customer')),retryReceiver=page(retryDB.client('worker'));await tick();
 await retryCaller.api.start('conversation');await tick();retryReceiver.deny();await retryReceiver.api.accept();await tick();
 assert.equal(retryReceiver.get('clAudioStatus').textContent,'Incoming audio call');assert.equal(retryReceiver.get('clAudioAccept').hidden,false);assert.equal([...retryDB.calls.values()][0].status,'ringing');assert.equal(retryReceiver.streams.length,0);
 retryReceiver.allow();await retryReceiver.api.accept();await tick();assert.equal([...retryDB.calls.values()][0].status,'accepted');await retryReceiver.api.end();await tick();
 const scaled=page(server().client('customer'));await tick();scaled.setViewport(980,390,1800);await scaled.api.start('conversation');assert.ok(Number(scaled.get('clAudioDialog').style.zoom)>2.5);assert.ok(parseFloat(scaled.get('clAudioDialog').style.maxHeight)<800);await scaled.api.end();
 const normal=page(server().client('customer'));await tick();normal.setViewport(390,390);await normal.api.start('conversation');assert.equal(normal.get('clAudioDialog').style.zoom,'1');await normal.api.end();
 const desktopPhone=page(server().client('customer'));await tick();desktopPhone.setViewport(980,980,1800);await desktopPhone.api.start('conversation');assert.ok(Number(desktopPhone.get('clAudioDialog').style.zoom)>2.5);await desktopPhone.api.end();
 const insecure=page(db2.client('customer'));await tick();insecure.setInsecure();await insecure.api.start('conversation');assert.match(insecure.get('clAudioError').textContent,/https:\/\/cleanlanka.lk/);assert.equal(insecure.micCount(),0);
 const failureDB=server(),failed=page(failureDB.client('customer'));await tick();await failed.api.start('conversation');failed.peers[0].connectionState='failed';failed.peers[0].onconnectionstatechange();await tick();assert.equal(failed.streams[0].track.stopped,true);assert.equal([...failureDB.calls.values()][0].status,'failed');
 const multiDB=server(),multiCaller=page(multiDB.client('customer')),losingDevice=page(multiDB.client('worker'));await tick();
 await multiCaller.api.start('conversation');await tick();
 const losingRpc=losingDevice.sb.rpc;
 losingDevice.sb.rpc=(name,args)=>losingRpc(name,name==='cl_audio_call_action'&&args.p_action==='accept'?{...args,p_answer:'v=0\r\nm=audio answered-on-a-different-device'}:args);
 await losingDevice.api.accept();await tick();
 assert.equal(losingDevice.get('clAudioStatus').textContent,'Answered on another device','A genuinely different accepted answer must still release this device');
 assert.equal(losingDevice.streams[0].track.stopped,true);
 const audioDB=server(),audioCaller=page(audioDB.client('customer')),receiver=page(audioDB.client('worker'),{sound:true,routing:true});await tick();
 assert.equal(receiver.toolbars[0].children.length,2,'Only sound and microphone buttons belong in the toolbar');
 assert.equal(receiver.toolbars[0].afterNodes[0].className,'cl-call-mic-status','Permission feedback must be outside the toolbar');
 await receiver.toolbars[0].children[0].click();await tick();assert.equal(receiver.sound.context.state,'running');assert.equal(receiver.sound.oscillators.length,2,'Test sound must create an audible dual tone');
 await audioCaller.api.start('conversation');await tick();assert.ok(receiver.sound.oscillators.length>=4,'Incoming call must ring after sound is unlocked');assert.equal(receiver.micCount(),0);
 await receiver.api.accept();await tick();assert.ok(receiver.sound.oscillators.every(o=>o.stopped),'Answering must stop every ringtone oscillator');
 receiver.get('clAudioOutput').click();await tick();assert.equal(receiver.get('clAudioOutputSelect').hidden,false);assert.equal(receiver.get('clAudioOutputSelect').children.length,3);
 receiver.get('clAudioOutputSelect').value='headset-1';await receiver.get('clAudioOutputSelect').listeners.change();await tick();assert.equal(receiver.get('clAudioRemote').sinkId,'headset-1');
 receiver.get('clAudioOutputSelect').value='denied';await receiver.get('clAudioOutputSelect').listeners.change();await tick();assert.equal(receiver.get('clAudioRemote').sinkId,'headset-1');assert.match(receiver.get('clAudioOutputStatus').textContent,/Could not switch/);
 audioCaller.get('clAudioOutput').click();await tick();assert.match(audioCaller.get('clAudioOutputStatus').textContent,/does not offer speaker\/earpiece switching/,'Unsupported phones must get honest guidance instead of a fake speaker toggle');
 await receiver.api.end();await tick();assert.equal(receiver.get('clAudioOutputPanel').hidden,true);
 const blockedOptions={sound:true,resumeDenied:true},blocked=page(server().client('worker'),blockedOptions);await tick();await blocked.toolbars[0].children[0].click();await tick();assert.match(blocked.toolbars[0].children[0].getAttribute('aria-label'),/Tap again/);assert.equal(blocked.sound.oscillators.length,0,'Blocked autoplay must never be labeled as enabled');
 blockedOptions.resumeDenied=false;await blocked.toolbars[0].children[0].click();await tick();assert.equal(blocked.sound.oscillators.length,2);
 const setup=page(server().client('worker'));await tick();assert.equal(setup.micCount(),0,'No microphone request on page load');
 await setup.toolbars[0].children[1].click();assert.equal(setup.micCount(),1);assert.ok(setup.streams.every(s=>s.track.stopped),'Readiness test must release every microphone track');assert.match(setup.toolbars[0].afterNodes[0].textContent,/Microphone ready/);
 setup.deny();await setup.toolbars[0].children[1].click();assert.match(setup.toolbars[0].afterNodes[0].textContent,/no Allow popup/);assert.equal(setup.toolbars[0].children[1].disabled,false);
 setup.allow();await setup.toolbars[0].children[1].click();assert.match(setup.toolbars[0].afterNodes[0].textContent,/Microphone ready/);assert.ok(setup.streams.every(s=>s.track.stopped));
 assert.equal((html.match(/data-cl-audio-start="(?:customer|worker)"/g)||[]).length,2);
 const isolation=[...html.matchAll(/body\.(?:worker|customer|admin)-dashboard-mode\s*>\s*\*([^{}]+)\{\s*display\s*:\s*none\s*!important/gi)];
 assert.ok(isolation.length>=4,'Dashboard isolation rules must be covered by the call visibility check');
 assert.ok(isolation.every(match=>match[1].includes(':not(#clAudioCallRoot)')),'Dashboard isolation must preserve the shared incoming call panel');
 console.log('PASS: ringtone enable/test, incoming tone and cleanup, blocked autoplay recovery, supported output switching, failed routing and unsupported-device guidance; named incoming calls, consent before microphone, offer/answer and buffered candidates, mute, minimize for messages, end/decline cleanup, cancel during permission prompt, microphone denial, HTTPS requirement, network failure cleanup. WebRTC is mocked; real-device audio still needs testing.');
})().catch(error=>{console.error(error);process.exitCode=1;});

