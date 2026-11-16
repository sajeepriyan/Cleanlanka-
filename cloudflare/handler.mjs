// Server-only Cloudflare TURN adapter. Deploy after configuring the two secrets.
// This file contains no real API tokens and does not activate paid services.
                                                             
                                                                                          
const ALLOWED_ORIGINS = new Set(['https://cleanlanka.lk', 'https://www.cleanlanka.lk']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function createHandler(env             , dependencies               = { fetch: (url, options) => fetch(url, options) }) {
 return async (request         )                    => {
  const origin = request.headers.get('Origin');
  const headers                        = {
   'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'Vary': 'Origin',
   'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
   'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };
  if (origin && ALLOWED_ORIGINS.has(origin)) headers['Access-Control-Allow-Origin'] = origin;
  const reply = (status        , body         ) => new Response(JSON.stringify(body), {status,headers});
  if (origin && !ALLOWED_ORIGINS.has(origin)) return reply(403, {error:'Origin is not allowed.'});
  if (request.method === 'OPTIONS') return new Response(null,{status:204,headers});
  if (request.method !== 'POST') return reply(405,{error:'Use POST.'});
  const authorization = request.headers.get('Authorization') || '';
  if (!/^Bearer \S+$/.test(authorization)) return reply(401,{error:'Please sign in.'});
  const apiUrl = env.get('SUPABASE_URL');
  const anonKey = env.get('SUPABASE_ANON_KEY');
  if (!apiUrl || !anonKey) return reply(503,{error:'Audio service is not configured.'});
  let conversationId        ;
  try {
   const raw = await request.text();
   if (raw.length > 1024) return reply(400,{error:'Invalid request.'});
   const body = JSON.parse(raw);
   conversationId = body?.conversation_id;
   if (!UUID.test(conversationId || '')) return reply(400,{error:'A conversation is required.'});
  } catch (_) { return reply(400,{error:'Invalid request.'}); }
  const requestHeaders = {Authorization:authorization,apikey:anonKey};
  let stage = 'auth';
  try {
   // Validate the actual user with Auth. Never authorize through user metadata.
   const authResponse = await dependencies.fetch(apiUrl+'/auth/v1/user',{
    headers:requestHeaders,signal:AbortSignal.timeout(10000),
   });
   if (!authResponse.ok) return reply(401,{error:'Please sign in again.'});
   const user = await authResponse.json();
   if (!user?.id || !user.email_confirmed_at) return reply(403,{error:'Confirm your email before calling.'});
   // Use the caller's JWT, so existing conversation RLS checks membership.
   stage = 'conversation';
   const conversationResponse = await dependencies.fetch(
    apiUrl+'/rest/v1/conversations?select=id&id=eq.'+encodeURIComponent(conversationId)+'&limit=1',
    {headers:requestHeaders,signal:AbortSignal.timeout(10000)},
   );
   if (!conversationResponse.ok) return reply(403,{error:'This conversation is unavailable.'});
   const conversations = await conversationResponse.json();
   if (!Array.isArray(conversations) || !conversations.some(row=>row.id===conversationId)) {
    return reply(403,{error:'This conversation is unavailable.'});
   }
   stage = 'rate_limit';
   if (dependencies.allow && !await dependencies.allow(user.id)) return reply(429,{error:'Too many call attempts. Please wait a minute.'});
   const keyId = env.get('CLOUDFLARE_TURN_KEY_ID');
   const apiToken = env.get('CLOUDFLARE_TURN_API_TOKEN');
   if (!keyId || !apiToken) return reply(503,{error:'Audio relay setup is pending.'});
   stage = 'relay';
   const upstream = await dependencies.fetch(
    'https://rtc.live.cloudflare.com/v1/turn/keys/'+encodeURIComponent(keyId)+'/credentials/generate-ice-servers',
    {method:'POST',headers:{Authorization:'Bearer '+apiToken,'Content-Type':'application/json'},
     body:JSON.stringify({ttl:7500}),signal:AbortSignal.timeout(12000)},
   );
   if (!upstream.ok) return reply(502,{error:'Audio relay is temporarily unavailable.'});
   const result = await upstream.json();
   if (!Array.isArray(result?.iceServers)) return reply(502,{error:'Audio relay settings are unavailable.'});
   const iceServers = result.iceServers.flatMap((server                        )=>{
    const urls = (Array.isArray(server.urls)?server.urls:[server.urls])
     .filter((url         )=>typeof url==='string' && /^(stun|turn|turns):/.test(url) && !/:53(?:\?|$)/.test(url));
    if (!urls.length) return [];
    if (urls.some((url        )=>/^turns?:/.test(url))) {
     if(typeof server.username!=='string'||typeof server.credential!=='string') return [];
     return [{urls,username:server.username,credential:server.credential}];
    }
    return [{urls}];
   });
   if (!iceServers.some((server                  )=>server.urls.some(url=>/^turns?:/.test(url)))) {
    return reply(502,{error:'Audio relay settings are unavailable.'});
   }
   return reply(200,{iceServers,ttl:7500});
  } catch (error) {
   const reason = /illegal invocation|incorrect this/i.test(String(error?.message)) ? 'runtime_context' : error?.name === 'TimeoutError' ? 'timeout' : 'request_failed';
   console.error(JSON.stringify({event:'audio_relay_failure',stage,reason}));
   return reply(502,{error:'Audio relay is temporarily unavailable. Please try again.',code:'CALL_'+stage.toUpperCase()+'_UNAVAILABLE'});
  }
 };
}

