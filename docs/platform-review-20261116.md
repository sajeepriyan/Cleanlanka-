# Clean Lanka platform review — 16 November 2026

## Changes

- Confirmed worker registration creates a pending profile on the server, without depending on a later password login. Recovered two confirmed workers whose profiles were missing.
- Worker dashboard status text reflects pending, approved, more information required and rejected states.
- Customer homepage avatar uses the existing private customer-profile-photos bucket, rather than requesting nonexistent profile columns.
- Worker list refresh also refreshes Admin member counts.
- New job and application creation timestamps default to now(). Historical missing dates were not invented.
- Audio test DOM mocks now support attributes and check the accessible label of icon-only controls.

## Validation

The transaction in tests/platform-regression-20261116.sql passed all 33 assertions and rolled back its temporary test users and data. It checks confirmed/unconfirmed profiles, worker editing and protected fields, Admin approval reversals, temporary eligibility, applications and assignment, two-way messages, message notifications, private phone display, call signalling and outsider access controls. It fails if an assertion is false.

All six existing Node suites passed: account-job-chat, audio-calls, cloudflare-turn, cloudflare-worker, job-ad-contact and selected-job-flow. All 55 inline JavaScript scripts parsed.

A live public browser check verified worker registration navigation and return to Home, current public workers/jobs, and opening and closing the job details modal. The browser was signed out; authenticated dashboards were not manually exercised in that browser.

## Limits and remaining verification

- WebRTC and relay provider interactions in code tests are mocked. Real Android/iPhone microphone, ringtone, speaker/earpiece routing, weak-network behavior, and background notifications still require two-device testing.
- Database notification delivery is verified; live websocket delivery across two signed-in browsers was not exercised.
- Password-reset/login logic was reviewed, but no real user password was changed and no test email was sent.
- Actual photo/PDF byte uploads and signed downloads were not exercised; ownership policies and profile paths were reviewed/tested.
- Email domain authentication is present and the supplied Gmail security details show a cleanlanka.lk signature. Exact spam classification remains unresolved; Inbox placement cannot be guaranteed.
- Existing Supabase advisories remain; no new public callable registration helper was introduced.
