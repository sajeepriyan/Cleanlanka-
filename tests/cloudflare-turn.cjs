const assert=require('node:assert/strict');
const conversation='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const secrets={SUPABASE_URL:'https://test.invalid',SUPABASE_ANON_KEY:'test-anon',CLOUDFLARE_TURN_KEY_ID:'test-key',CLOUDFLARE_TURN_API_TOKEN:'test-server-token'};
const request=()=>new Request('https://function.invalid',{method:'POST',headers:{Origin:'https://www.cleanlanka.lk',Authorization:'Bearer test-user-token','Content-Type':'application/json'},body:JSON.stringify({conversation_id:conversation})});
(async()=>{
 const {createHandler}=await import('../cloudflare/handler.mjs');
 let callCount=0,mode='ok';
 const fakeFetch=async(url,options)=>{
  if(url.includes('/auth/v1/user'))return Response.json({id:'test-user',email_confirmed_at:'2026-11-01'});
  if(url.includes('/rest/v1/conversations'))return Response.json(mode==='outsider'?[]:[{id:conversation}]);
  callCount++;assert.equal(options.headers.Authorization,'Bearer test-server-token');assert.equal(JSON.parse(options.body).ttl,7500);
  if(mode==='failure')return new Response('private provider error',{status:500});
  return Response.json({iceServers:[{urls:['stun:stun.cloudflare.com:3478']},{urls:['turns:turn.cloudflare.com:443?transport=tcp','turn:turn.cloudflare.com:53?transport=udp'],username:'temporary-user',credential:'temporary-password'}]});
 };
 const handler=createHandler({get:key=>secrets[key]},{fetch:fakeFetch});
 let response=await handler(request());assert.equal(response.status,200);const data=await response.json();assert.equal(data.iceServers[1].urls.length,1);assert.equal(data.iceServers[1].credential,'temporary-password');assert.equal(JSON.stringify(data).includes('test-server-token'),false);
 mode='outsider';response=await handler(request());assert.equal(response.status,403);assert.equal(callCount,1,'Nonparticipants must never receive TURN credentials');
 mode='failure';response=await handler(request());assert.equal(response.status,502);assert.equal((await response.text()).includes('private provider error'),false);
 response=await handler(new Request('https://function.invalid',{method:'POST'}));assert.equal(response.status,401);
 mode='ok';const noKey=createHandler({get:key=>key==='CLOUDFLARE_TURN_API_TOKEN'?undefined:secrets[key]},{fetch:fakeFetch});response=await noKey(request());assert.equal(response.status,503);
 response=await handler(new Request('https://function.invalid',{method:'OPTIONS',headers:{Origin:'https://www.cleanlanka.lk'}}));assert.equal(response.status,204);
 console.log('PASS: confirmed-account and conversation authorization, server-only token, temporary relay credentials, blocked-port filtering, provider-error redaction and missing-key handling. No real provider requests made.');
})().catch(error=>{console.error(error);process.exitCode=1;});
