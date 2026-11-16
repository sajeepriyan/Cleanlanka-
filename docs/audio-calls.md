# Clean Lanka audio calls

The Customer and Worker dashboards now have **Calls & Messages**. Open an existing conversation and select **Audio Call**. The recipient sees the caller's profile name with **Accept** and **Decline**. During a call, either person can mute their microphone, return to messages, reopen the call panel, or end the call. Calls appear in a private call history.

This is a browser audio-call implementation. Both people must be signed in, keep the HTTPS Clean Lanka page open, and allow microphone access. It does not provide an operating-system incoming-call screen, push delivery while the website is closed, or call recording. The existing Android v1 WebView intentionally denies WebRTC microphone permission; use the website in Chrome/Safari for this version. An Android client update is required before using calls inside that APK.

## Backend

The setup in `supabase/audio_calls.sql` has already been applied to the Clean Lanka project. Do not run it again on that project. It is retained to reproduce the setup on a new database.

- RLS restricts calls and ICE candidates to the two conversation participants. Direct call-row writes are not granted to clients.
- Private, authenticated functions resolve both user IDs and display names from the existing conversation and profiles. The browser cannot choose a caller name or recipient ID.
- Server-side locks prevent overlapping calls. Only the called participant can accept or decline. Both sides can end a call.
- Ringing expires after 60 seconds. Accepted calls expire if the other endpoint stops heartbeating for 60 seconds, and have a two-hour maximum. The clients reconcile state through Realtime and polling; subsequent call attempts also expire stale records.
- Ended calls retain names/status/timestamps for history; SDP and ICE candidates are cleared when the server closes or reconciles them. No audio recording is stored.
- Microphone tracks stop immediately on end, network failure, sign-out, and navigation, even if signalling fails. Remote notification of an offline hangup remains best effort.

## Network configuration

The initial ICE configuration contains **STUN only**. A direct WebRTC route may work, but calls across restrictive mobile networks, symmetric NAT, and firewalls can fail. This release has not been verified with two real phones. Add a TURN relay and complete real-device testing before describing calls as reliable across networks.

The protected `cl_call_private.rtc_config` table owns the `ice_servers` JSON array. Configure a TURN service there through an administrator connection; do not put a provider API secret into the HTML or repository. Browsers retrieve the required ICE configuration only after sign-in using `cl_audio_ice_config()`. Prefer short-lived TURN credentials for production. No paid relay service was provisioned by this change.

## Verification

From the repository root:

```sh
node tests/audio-calls.cjs
node tests/account-job-chat.cjs
node tests/job-ad-contact.cjs
node tests/selected-job-flow.cjs
```

`tests/audio-call-transactions.sql` verifies participant authorization, names, both call directions, accept/decline/cancel/end, busy protection, and candidate cleanup inside a rolled-back transaction. It does not send a real call.

The JavaScript call test mocks WebRTC and checks microphone consent, signalling transitions, buffered ICE candidates, mute, returning to messages, microphone denial, cancellation during permission prompts, HTTPS requirements, and network failure cleanup. It is not an acoustic or network test.

For acceptance, use a confirmed Customer account and a confirmed Worker account in separate phones/browsers. Check both call directions, caller names, two-way sound, declined/missed calls, mute/unmute, ending from each side, microphone denial, logout, and Wi-Fi-to-mobile operation with TURN configured. Confirm normal messages and job/application flows still work.
