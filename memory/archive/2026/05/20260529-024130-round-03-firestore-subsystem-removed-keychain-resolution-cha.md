# Round 03 firestore subsystem removed + keychain resolution chain (3 PRs) + 10 ai-task issues closed
- Timestamp: 2026-05-29T02:41:30Z
- Author: claude
- Tags: noetl-keychain duffel-rotation firestore-removal calendar-event-touched gateway-cleanup cli-auth0 closeout-10-issues

## Summary
Massive multi-PR sprint closed 10 ai-task umbrella issues across 6 submodules. The session opened with a Duffel 401 access_token_not_found and traced it through three stacked fixes: noetl/ops#125 (playbook kind: credential_ref) → noetl/noetl#624 (worker detects $noetl_ref placeholders) → noetl/noetl#625 (producer scrub preserves $noetl_ref under sensitive keys) → noetl/noetl#628 (sanitize skips template/code-shaped strings, closes noetl/ai-meta#20 google-places NameError). End-to-end Duffel works on GKE: get_airlines returns 5 airlines, search_offers LAX→CDG returns 10 offers. noetl.keychain cache access_count proves the worker actually queries the cache now. Round 03 of noetl/ai-meta#23 removed the gateway-side Firestore subsystem entirely (548 lines deleted across noetl/gateway#17 + #18 + #19, plus noetl/travel#57 deleted gatewaySubscriptions.ts and switched the SPA SSE filter from playbook.completed to calendar.event.touched). Gateway image dropped from 17m22s to 5m16s build after removing the dead firestore-sidecar Python venv. SPA verified live at travel.mestumre.dev with calendarSubscription module. CLI Auth0 dashboard URL gained region-segment support (noetl/cli#18, 7 new tests). Ops cloudbuild.yaml for gateway fixed to match single-crate layout (noetl/ops#126). e2e fixtures audit (noetl/ai-meta#19) found .gitignore correctly excludes real-secret files — no exposure. Rules hardened: agents/rules/issue-tracking.md got Rules 1/1b/2 + sub-issue convention; agents/rules/commit-conventions.md gained a Critical callout warning that GitHub's Closes keyword ignores trailing qualifiers (Closes #23 Round 02 closed the whole umbrella, had to reopen). 11 PRs merged, 4 Cloud Builds + 4 Helm rollouts, 3 wikis updated. ai-task inbox is empty at session end.

## Actions
-

## Repos
-

## Related
-
