const assert=require('node:assert/strict');
(async()=>{
 const worker=(await import('../cloudflare/worker.mjs')).default;
 const originalFetch=globalThis.fetch;
 const id='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
 const env={SUPABASE_URL:'https://auth.invalid',SUPABASE_ANON_KEY:'public',CLOUDFLARE_TURN_KEY_ID:'test',CLOUDFLARE_TURN_API_TOKEN:'server-only',CALL_RATE_LIMITER:{limit:async()=>({success:true})}};
 let mode='ok',providerCalls=0;
 globalThis.fetch=async function(url,options){
  'use strict';
  assert.ok(this===undefined||this===globalThis,'Native fetch must keep its global invocation context');
  if(url.includes('/auth/v1/user'))return mode==='invalid'?new Response(null,{status:401}):Response.json({id:'user',email_confirmed_at:'2026-11-01'});
  if(url.includes('/conversations'))return Response.json(mode==='outsider'?[]:[{id}]);
  providerCalls++;assert.equal(options.headers.Authorization,'Bearer server-only');
  return Response.json({iceServers:[{urls:['turns:turn.cloudflare.com:5349?transport=tcp'],username:'temporary',credential:'temporary'}]});
 };
 const req=()=>new Request('https://relay.invalid',{method:'POST',headers:{Origin:'https://www.cleanlanka.lk',Authorization:'Bearer user-token','Content-Type':'application/json'},body:JSON.stringify({conversation_id:id})});
 try {
  let r=await worker.fetch(req(),env);assert.equal(r.status,200);assert.equal((await r.json()).iceServers[0].username,'temporary');
  mode='invalid';r=await worker.fetch(req(),env);assert.equal(r.status,401);
  mode='outsider';r=await worker.fetch(req(),env);assert.equal(r.status,403);
  mode='ok';env.CALL_RATE_LIMITER.limit=async()=>({success:false});r=await worker.fetch(req(),env);assert.equal(r.status,429);assert.equal(providerCalls,1);
  console.log('PASS: Worker preserves native fetch context; valid participant gets temporary credentials, invalid sessions/nonparticipants/rate-limited users cannot reach provider. External requests mocked.');
 }finally{globalThis.fetch=originalFetch;}
})().catch(e=>{console.error(e);process.exitCode=1});
