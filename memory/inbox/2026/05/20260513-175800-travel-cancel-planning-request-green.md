# 2026-05-13 — Travel cancel planning request GREEN

Context: Kadyapam reported that when the Travel UI hangs at `Muno is planning...`, the input remains disabled and there is no way to cancel or submit anything else.

Fix shipped:
- `noetl/travel#27` merged at `b2966ae`.
- `ChatThread` now keeps an active `AbortController` per planning turn.
- The planning indicator includes a `Cancel` button.
- Cancelling aborts the active gateway access check, GraphQL execute request, SSE callback wait, direct REST execute fallback, and fallback execution polling.
- Pending playbook callbacks are removed on abort so late `playbook/result` frames do not keep the UI stuck.
- The input is re-enabled immediately and the UI shows `Request cancelled. You can send another message.`
- `noetlClient` now accepts an optional `AbortSignal` in `executePlaybook()` and `getExecution()`.

Validation:
- Local `npm run test` passed: 9 files, 19 tests.
- Local `npm run type-check` passed.
- Local `npm run smoke:widgets` passed.
- Local `npm run build` passed.
- PR checks passed.
- Cloudflare Pages production deploy `25835293466` passed for merge SHA `b2966ae`.

State:
- `repos/travel` now points at `b2966ae` locally in `ai-meta`.
- Browser smoke: hard-refresh `https://travel.mestumre.dev/`, sign in, submit a trip prompt, click `Cancel` while `Muno is planning...`, and confirm the input becomes usable again.
