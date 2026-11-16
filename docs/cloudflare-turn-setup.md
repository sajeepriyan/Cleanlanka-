# Clean Lanka Cloudflare TURN
Production endpoint: https://cleanlanka-turn.cleanlanka-audio.workers.dev

The website remains on Vercel and Supabase continues call signalling, account authentication and chat. The Cloudflare Worker authenticates the current Supabase user, requires confirmed email and conversation membership under RLS, and generates temporary TURN credentials. Its permanent key is a secret_text binding, never source code or client HTML.

Worker: cleanlanka-turn; account workers.dev subdomain: cleanlanka-audio.
Runtime sources: cloudflare/worker.mjs and cloudflare/handler.mjs.
Deploy as ES modules with compatibility_date 2026-11-16 and placement aws:ap-southeast-1.
Bindings: SUPABASE_URL and SUPABASE_ANON_KEY (public configuration), CLOUDFLARE_TURN_KEY_ID, CLOUDFLARE_TURN_API_TOKEN (secret), CALL_RATE_LIMITER (ratelimit namespace 1001, 10 attempts per 60 seconds per authenticated user at each Cloudflare location).
Preserve the permanent secret with an inherit binding on future uploads; never substitute an empty value.

Only cleanlanka.lk and www.cleanlanka.lk origins are allowed. Replies are no-store. Port 53 endpoints are filtered for browser compatibility. Credential TTL is 7500 seconds. No STUN-only fallback hides relay failure.
Observability logs and traces enabled with sampling; application code never logs credentials, authorization headers, SDP or messages.

Checks: node tests/cloudflare-turn.cjs; node tests/audio-calls.cjs; node tests/account-job-chat.cjs; node tests/job-ad-contact.cjs; node tests/selected-job-flow.cjs.
These mock external media and Auth traffic. Two real devices on separate networks must confirm bidirectional sound. The existing v1 Android APK denies microphone access in WebView; use an HTTPS browser for calls.

TURN usage beyond the provider allowance may be billed. This deployment does not implement a hard bandwidth cap or change the Cloudflare billing plan.
