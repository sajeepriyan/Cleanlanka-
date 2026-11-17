const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync('index.html','utf8');
const helper=html.slice(html.indexOf('  function showRegistrationConfirmation('),html.indexOf('  function showMessage('));
const register=html.slice(html.indexOf('  async function registerAccount('),html.indexOf('  // Resend is separate'));
const worker=html.slice(html.indexOf("  const workerFormClean = document.getElementById('workerRegisterForm');"),html.indexOf('  // Create the worker profile once'));
function harness(apiResult={data:{user:{identities:[{id:'test'}]}}}){
 const nodes=new Map();let requests=0,opened=0;
 class E{
  constructor(id=''){this._id=id;this.children=[];this.queries=new Map();this.events={};this.value='';this.hidden=false;this.dataset={};this.checked=true;this.textContent='';this.disabled=false;this.classes=new Set();this.classList={add:c=>this.classes.add(c),remove:c=>this.classes.delete(c),toggle:(c,v)=>v?this.classes.add(c):this.classes.delete(c)};if(id)nodes.set(id,this);}
  set id(v){this._id=v;nodes.set(v,this);}get id(){return this._id;}
  setAttribute(k,v){this[k]=v;}
  addEventListener(k,fn){this.events[k]=fn;}
  click(){return this.events.click?.();}
  append(...els){for(const e of els){if(e.parent)e.parent.children=e.parent.children.filter(x=>x!==e);e.parent=this;this.children.push(e);}}
  after(e){this.afterNode=e;}
  querySelector(q){if(!this.queries.has(q))this.queries.set(q,new E());return this.queries.get(q);}
  focus(){this.focused=true;}scrollIntoView(){this.scrolled=true;}
  reset(){for(const n of nodes.values())if(n.id.startsWith(this.id.startsWith('worker')?'worker':'customer'))n.value='';}
 }
 const get=id=>nodes.get(id)||new E(id);
 const ctx={document:{getElementById:id=>nodes.get(id)||null,createElement:()=>new E(),body:new E('body')},window:{clSelectedWorkerJob:()=>null},showMessage:(e,t)=>e.textContent=t,openLoginPage:()=>opened++,supabaseClient:{auth:{signUp:async()=>{requests++;return apiResult;}}},console};
 vm.createContext(ctx);vm.runInContext(helper,ctx);
 for(const role of ['customer','worker']){get(role+'TermsAccepted');get(role+'Email').value=role+'@example.invalid';get(role+'Name').value='Test';get(role+'Phone').value='0712345678';get(role+'District').value='Colombo';get(role+'Address').value='Test area';get(role+'Password').value='testing123';get(role+'ConfirmPassword').value='testing123';get(role+'Skills').value='Cleaning';get(role+'Experience').value='1';get(role+'Price').value='1000';get(role+'Gender').value='';get(role+'RegisterForm').append(get(role+'RegisterMessage'),get(role+'ResendConfirmation'));}
 get('loginEmail');get('loginRole');
 return {ctx,get,vm,requests:()=>requests,opened:()=>opened};
}
(async()=>{
 for(const role of ['customer','worker']){
  const h=harness();h.ctx.document.body.classList.add('registration-mode');
  if(role==='customer'){vm.runInContext(register,h.ctx);await h.ctx.registerAccount({formId:'customerRegisterForm',nameId:'customerName',emailId:'customerEmail',passwordId:'customerPassword',confirmId:'customerConfirmPassword',messageId:'customerRegisterMessage',role});}
  else vm.runInContext(worker,h.ctx);
  await h.get(role+'RegisterForm').events.submit({preventDefault(){}});
  const panel=h.get(role+'ConfirmationPanel'),form=h.get(role+'RegisterForm');assert.equal(h.requests(),1);assert.equal(form.hidden,true);assert.equal(panel.hidden,false);assert.equal(panel.querySelector('.cl-confirm-email').textContent,role+'@example.invalid');assert.equal(h.get(role+'Email').value,role+'@example.invalid');
  assert.equal(h.get(role+'RegisterMessage').parent,panel.querySelector('.cl-confirm-feedback'));assert.equal(h.get(role+'ResendConfirmation').parent,panel.querySelector('.cl-confirm-actions'));assert(panel.scrolled&&panel.focused);
  panel.querySelector('.cl-confirm-login').click();assert.equal(h.opened(),1);assert.equal(h.get('loginEmail').value,role+'@example.invalid');assert.equal(h.get('loginRole').value,role);assert(!h.ctx.document.body.classes.has('registration-mode'));
  panel.querySelector('.cl-confirm-back').click();assert.equal(form.hidden,false);assert.equal(panel.hidden,true);assert.equal(h.get(role+'RegisterMessage').parent,form);assert.equal(h.get(role+'ResendConfirmation').parent,form);
  h.ctx.showRegistrationConfirmation(role,'another@example.invalid');assert.equal(h.get(role+'ConfirmationPanel'),panel);assert.equal(panel.querySelector('.cl-confirm-email').textContent,'another@example.invalid');
 }
 for(const result of [{error:{message:'Email service unavailable'}},{data:{user:{identities:[]}}}]){
  const h=harness(result);vm.runInContext(register,h.ctx);await h.ctx.registerAccount({formId:'customerRegisterForm',nameId:'customerName',emailId:'customerEmail',passwordId:'customerPassword',confirmId:'customerConfirmPassword',messageId:'customerRegisterMessage',role:'customer'});await h.get('customerRegisterForm').events.submit({preventDefault(){}});assert.equal(h.get('customerRegisterForm').hidden,false);assert.equal(h.get('customerConfirmationPanel').afterNode,undefined);
 }
 for(const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)){if(!/src=|application\/(ld\+)?json/.test(m[1]))new vm.Script(m[2]);}
 console.log('PASS: both registration success flows show exact email and required confirmation; resend and feedback remain visible; Login prefills correct email/role; Back restores form; repeated panel reuses nodes; service errors and duplicates keep the form; all inline scripts parse. No accounts created or emails sent.');
})().catch(e=>{console.error(e);process.exit(1);});
