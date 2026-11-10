const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const html=fs.readFileSync('index.html','utf8');
const open=html.slice(html.indexOf('  window.cleanLankaOpenAccountJobChat='),html.indexOf('  async function sendChatMessage(role){'));
const send=html.slice(html.indexOf('  async function sendChatMessage(role){'),html.indexOf("  $('searchWorkersButton')?.addEventListener"));
function harness(existing=null){
 const elements=new Map(),calls=[],events=[];
 const el=id=>{if(!elements.has(id))elements.set(id,{id,value:'',textContent:'',hidden:false,disabled:false,classList:{remove(){}},querySelector(){return el(id+'Button')},after(node){elements.set(node.id,node)},setAttribute(name,value){this[name]=value}});return elements.get(id)};
 el('workerDashboard')._clShowTab=tab=>calls.push(['tab',tab]);
 const ctx={console,currentWorkerProfile:{is_available:true},workerAvailabilityEligibility:()=>({allowed:true,approved:true,clearanceVerified:true}),CustomEvent:class{constructor(type,init){this.type=type;this.detail=init.detail}},clWorkerChatId:null,clCustomerChatId:null,clWorkerJobContext:null,$:el,document:{createElement:()=>({})},say:(id,msg)=>{el(id).textContent=msg},stopChatRealtime:()=>calls.push(['stop']),subscribeChatRealtime:async id=>calls.push(['subscribe',id]),loadChatMessages:async id=>calls.push(['messages',id]),loadConversations:async role=>calls.push(['inbox',role]),getUser:async()=>({id:'worker-user'}),supabaseClient:{rpc:async(name,args)=>{calls.push(['rpc',name,args]);if(ctx.failSend&&args.p_message)return {error:{message:'Approval required'}};return {data:{conversation_id:args.p_message?'new-conversation':existing,job_title:'Cleaning',contact_name:'Customer Name',contact_district:'Jaffna',contact_public_id:'123456'}}},from:()=>({insert:payload=>{calls.push(['insert',payload]);return {select:()=>({single:async()=>({data:{id:'sent'}})})}}})}};
 ctx.window={loadWorkerDashboard:async()=>calls.push(['dashboard']),dispatchEvent:e=>events.push(e)};
 vm.createContext(ctx);vm.runInContext(open+send,ctx);
 return {ctx,el,calls,events};
}
(async()=>{
 let h=harness();
 await h.ctx.window.cleanLankaOpenAccountJobChat('job-one',{id:'worker-user'});
 assert.equal(h.el('workerChatTitle').textContent,'Customer Name');
 assert.match(h.el('workerJobChatContext').textContent,/123456.*Jaffna.*Cleaning/);
 assert.ok(h.events.some(e=>e.type==='cl-open-account-thread'));
 assert.equal(h.calls.filter(c=>c[0]==='insert').length,0);
 assert.equal(h.el('workerChatFormButton').disabled,false);
 h.el('workerChatInput').value='Interested';
 await h.ctx.sendChatMessage('worker');
 assert.equal(h.ctx.clWorkerChatId,'new-conversation');
 assert.equal(h.el('workerChatInput').value,'');
 assert.deepEqual(JSON.parse(JSON.stringify(h.calls.find(c=>c[0]==='rpc'&&c[2].p_message)[2])),{p_job_id:'job-one',p_message:'Interested'});
 assert.ok(h.calls.some(c=>c[0]==='subscribe'&&c[1]==='new-conversation'));
 h=harness();h.ctx.workerAvailabilityEligibility=()=>({allowed:false,approved:false,clearanceVerified:false});
 await h.ctx.window.cleanLankaOpenAccountJobChat('pending-worker-job',{id:'worker-user'});
 assert.equal(h.el('workerChatFormButton').disabled,true);
 assert.match(h.el('workerChatMessage').textContent,/pending approval/);
 h=harness('existing-conversation');
 await h.ctx.window.cleanLankaOpenAccountJobChat('job-two',{id:'worker-user'});
 assert.ok(h.calls.some(c=>c[0]==='messages'&&c[1]==='existing-conversation'));
 h.ctx.failSend=true;h.el('workerChatInput').value='Keep this draft';
 await h.ctx.sendChatMessage('worker');
 assert.equal(h.el('workerChatInput').value,'Keep this draft');
 assert.match(h.el('workerChatMessage').textContent,/Approval required/);
 assert.equal(h.el('workerChatFormButton').disabled,false);
 h.ctx.clWorkerJobContext=null;h.ctx.failSend=false;
 await h.ctx.sendChatMessage('worker');
 assert.equal(h.calls.filter(c=>c[0]==='insert').length,1);
 assert.equal(h.calls.find(c=>c[0]==='insert')[1].conversation_id,'existing-conversation');
 assert.ok(!html.includes('id="clJobChatForm"'));
 console.log('PASS: account routing, recipient and job identity, new/existing chats, application RPC, send failure draft, normal inbox replies, removed popup composer');
})().catch(e=>{console.error(e);process.exitCode=1});
// A direct Home → Apply thread must leave an inbox checkpoint for Android Back.
{
 const listeners={},nodes=new Map(),states=[];
 const el=id=>{if(!nodes.has(id)){const classes=new Set();nodes.set(id,{classList:{add:c=>classes.add(c),remove:c=>classes.delete(c),contains:c=>classes.has(c)},querySelector:()=>({}),scrollIntoView(){}})}return nodes.get(id)};
 const history={state:{cleanLankaDashboardEntry:true},replaceState(s){this.state=s;states.push(s)},pushState(s){this.state=s;states.push(s)}};
 const ctx={document:{getElementById:el,addEventListener(){}},window:{addEventListener:(name,fn)=>listeners[name]=fn,cleanLankaCaptureView:()=>({cleanLankaView:true,activeTabs:{worker:'messages'},visible:{workerChatWindow:true}})},history,location:{href:'https://example.test/'}};
 const script=html.match(/<script id="cl074-chat-navigation-script">([\s\S]*?)<\/script>/)[1];
 vm.createContext(ctx);vm.runInContext(script,ctx);
 listeners['cl-open-account-thread']({detail:{role:'worker'}});
 assert.equal(states[0].activeTabs.worker,'messages');
 assert.equal(states[0].visible.workerChatWindow,false);
 assert.equal(states[1].cl074Chat,true);
 listeners.popstate();
 assert.equal(el('workerChatPanel').classList.contains('cl074-thread-open'),false);
 console.log('PASS: direct job chat Back returns to account inbox');
}
