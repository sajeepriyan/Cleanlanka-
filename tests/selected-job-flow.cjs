const assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm');
const html=fs.readFileSync('index.html','utf8');
const helper=html.match(/<script id="cl-selected-job-flow-20261110">([\s\S]*?)<\/script>/)[1];
const id='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
function page(storage=new Map()){
 const ctx={window:{},localStorage:{getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v)},Date};
 vm.createContext(ctx);vm.runInContext(helper,ctx);return ctx;
}
(async()=>{
 const storage=new Map();let ctx=page(storage);
 ctx.window.clRememberWorkerJob(id);
 const saved=ctx.window.clSelectedWorkerJob();
 assert.equal(saved.id,id);assert.equal(saved.resumeAfterAuth,true);
 ctx=page(storage);assert.equal(ctx.window.clSelectedWorkerJob().id,id,'refresh must retain selection');
 const user={id:'worker-one',user_metadata:{account_type:'worker',selected_job_id:id,selected_job_at:saved.selectedAt}};
 const otherDevice=page();assert.equal(otherDevice.window.clSelectedWorkerJob(user).id,id,'confirmation in another browser must recover signup selection');
 otherDevice.window.clMarkWorkerJobShown(user);
 assert.equal(otherDevice.window.clSelectedWorkerJob(user).resumeAfterAuth,false,'opening homepage again must not force Dashboard');
 assert.equal(otherDevice.window.clSelectedWorkerJob({id:'worker-two',user_metadata:{}}),null,'selection must not cross signed-in accounts');
 ctx.window.clRememberWorkerJob('invalid');assert.equal(ctx.window.clSelectedWorkerJob().id,id);
 const expired={id:'worker-old',user_metadata:{selected_job_id:id,selected_job_at:Date.now()-15*86400000}};
 assert.equal(page().window.clSelectedWorkerJob(expired),null);
 // Signup reads the stored public job reference, without applying or sending a message.
 assert.match(html,/selected_job_id: window.clSelectedWorkerJob\(\)\?\.id/);
 assert.ok(!html.includes('await window.cleanLankaOpenJobChat(window.clPendingHomeJobId);\n          window.clPendingHomeJobId = null;'));
 // Dashboard sorts the selected job first even when it is beyond the original 50-job slice.
 const start=html.indexOf('  async function loadWorkerJobs('),end=html.indexOf('  async function loadConversations(',start);
 const elements=new Map(),get=id=>{if(!elements.has(id))elements.set(id,{});return elements.get(id)};
 const jobs=Array.from({length:70},(_,i)=>({id:'job-'+i,service_title:'Job '+i,description:'Details',district:'Jaffna'}));jobs[69].id=id;
 const dashboard={window:{clCurrentUser:user,clSelectedWorkerJob:()=>({id}),clJobAdDetailsHTML:()=>'',clJobContactHTML:()=>'<button>Live Chat</button>'},activeWorkerProfileId:'profile',supabaseClient:{rpc:async()=>({data:jobs}),from:()=>({select:()=>({eq:async()=>({data:[]})})})},$:get,say:()=>{},esc:x=>String(x??''),money:x=>'LKR '+(x||0)};
 vm.createContext(dashboard);vm.runInContext(html.slice(start,end),dashboard);
 await dashboard.loadWorkerJobs();
 assert.match(get('workerOpenJobs').innerHTML,new RegExp('^<article data-worker-job-card="'+id+'"'));
 assert.match(get('workerOpenJobs').innerHTML,/View details/);assert.match(get('workerOpenJobs').innerHTML,/Live Chat/);
 assert.ok(!get('workerOpenJobs').innerHTML.includes('workerApplyForm'));
 // Resuming a confirmed account opens the job list; it never invokes the chat/application RPC.
 const resumeStart=html.indexOf('  window.cleanLankaFocusWorkerJob=');
 const resumeEnd=html.indexOf('  window.cleanLankaLoadCustomerFeatures=',resumeStart);
 const calls=[];
 const resume={window:{clSelectedWorkerJob:()=>({id}),clMarkWorkerJobShown:()=>calls.push('shown')},document:{getElementById:()=>({_clShowTab:t=>calls.push(t)})},loadWorkerJobs:async job=>calls.push(job)};
 vm.createContext(resume);vm.runInContext(html.slice(resumeStart,resumeEnd),resume);
 await resume.window.cleanLankaResumeWorkerJob(user);
 assert.deepEqual(calls,['jobs',id,'shown']);
 console.log('PASS: selection persists through refresh and email confirmation, account isolation, expiry, dashboard job priority, explicit Live Chat, resume creates no application');
})().catch(e=>{console.error(e);process.exitCode=1});
