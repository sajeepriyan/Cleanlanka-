# Cloudflare TURN adapter — setup pending

The server-only audio-turn adapter is prepared and its mock tests pass. Cloudflare authentication, key creation, Supabase secret configuration, frontend integration, deployment and real relay/media tests are still required. This branch does not change the live call provider.

Configure CLOUDFLARE_TURN_KEY_ID and CLOUDFLARE_TURN_API_TOKEN through Supabase Edge Function secrets. Never commit them or put them in HTML. The platform supplies SUPABASE_URL and SUPABASE_ANON_KEY. The handler validates the user with Supabase Auth and verifies the conversation under the user's RLS before asking Cloudflare for temporary ICE credentials. Deploy with gateway verify_jwt disabled only because this handler explicitly validates the bearer token through Auth; never remove that check.

The frontend will invoke audio-turn with body {conversation_id} using the signed-in Supabase client, then use the returned iceServers when creating the peer connection. Neither production secrets nor this frontend switch are included yet.

Run `node tests/cloudflare-turn.cjs` with Node 24. The test uses fake provider responses and makes no live provider requests. Before activation, confirm Cloudflare account billing controls and the free-tier limit. Cloudflare's published free allowance is shared with SFU and usage beyond the allowance can be charged; the adapter does not enforce a hard bandwidth cap.

Reference: https://developers.cloudflare.com/realtime/turn/generate-credentials/
