# Travel v1 UX polish AMBER preflight

Date: 2026-05-13

Round:
- `bridge/inbox/delegated/20260513-100000-travel-v1-ux-polish.task.json`

Outcome:
- AMBER in phase 1 pre-handoff verification.
- Travel baseline validation passed:
  - `npm run smoke:widgets`
  - `npm run test`
  - `npm run type-check`
  - `npm run build`
  - `curl https://travel.mestumre.dev/`

Blocker:
- `travel-agent-widget-key` browser referrer restrictions include `https://travel.mestumre.dev/*`, so production photo loads are covered.
- The same key does not include `http://localhost:5173/*`, which the bridge task requires for local Vite photo smoke.
- The task explicitly says Codex verifies this setup and stops AMBER if missing rather than changing GCP API key restrictions.

Required action:
- Add `http://localhost:5173/*` to the `travel-agent-widget-key` HTTP referrer allowlist.
- Optional: also add `http://127.0.0.1:5173/*` for parity with local browser URLs used in prior auth debugging.

Notes:
- No product code changes were made.
- No secrets or token values were logged.
- Existing unrelated untracked Amadeus handoff files were left untouched.
