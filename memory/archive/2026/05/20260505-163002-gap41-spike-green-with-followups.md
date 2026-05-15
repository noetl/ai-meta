---
date: 2026-05-05T17:42:24Z
title: Gap 4.1 wait+fetch landed → spike GREEN on v2.35.8 with 4 follow-ups
tags: [noetl, gap-4.1, mcp, spike, deploy, codex-bridge, v2.35.8]
---

## Outcome

Spike e2e GREEN on v2.35.8. The architectural success signal:
**`diagnosis_lookup.attempts == 0`** — `error.diagnosis` arrives
populated on first read in the agent envelope, the e2e fixture's
30-attempt poll workaround is no longer load-bearing (and can be
dropped in a future cleanup PR).

Final spike execution: `620216619129635308`, diagnosis source
`ollama`, parent_status `error` (expected — the spike intentionally
exercises a failing sub-playbook), `smoke_status: ok`.

## What landed in this round

The bridge task (20260505-163002-gap41-three-prs-spike-still-green)
was scoped to 3 PRs but the cluster smoke surfaced 4 additional
runtime blockers Codex landed inline:

**Originally scoped:**
- ops#35 — POSIX-safe `bump_image.yaml` (`declare -A` → tmpfile +
  `while read`); corrected `diagnose_execution.yaml` defaults
  (`noetl_url` → `http://noetl.noetl.svc.cluster.local:8082`,
  `ollama_model` → `gemma3:4b`).
- e2e#8 — spike fixture's async-diagnosis poll workaround
  (tactical, supersedable once Gap 4.1 wait+fetch lands).
- noetl#413 (v2.35.5) — `_dispatch_troubleshoot_diagnosis` waits
  for terminal + extracts persisted diagnosis from
  `persist_diagnosis` event. Mirrors v2.35.3's wait-for-terminal
  pattern. Adds `_fetch_persisted_diagnosis_from_doc` helper +
  `_REQUIRED_DIAGNOSIS_KEYS` constants.

**Surfaced + landed inline (each a real cluster blocker):**
- ops#36 — Ollama MCP endpoint default wired into the
  `diagnose_execution` tool config. The diagnose playbook was
  failing to reach Ollama because the MCP endpoint wasn't pointed
  at the in-cluster bridge.
- noetl#414 (v2.35.6) — stateless JSON-RPC MCP servers
  (`noetl/tools/mcp/executor.py`). The auto-troubleshoot path
  needs the MCP server to handle JSON-RPC without per-call session
  state.
- noetl#415 (v2.35.7) — attach persisted-fallback diagnosis from
  inferred diagnostic runs. When the troubleshoot playbook's
  inference pass produces a diagnosis without explicitly running
  `persist_diagnosis`, the executor now falls back to the inferred
  result.
- noetl#416 (v2.35.8) — retry persisted-diagnosis fetch after
  terminal. Race condition: `_wait_for_sub_execution_terminal`
  returned `completed` before the events stream had flushed
  `persist_diagnosis` to the doc. Codex added a small retry loop in
  `_fetch_persisted_diagnosis_from_doc` to bridge the gap.

## Smokes (all GREEN)

- `gap41_diagnosis_wait_smoke.py` — 7/7
- `auto_troubleshoot_smoke.py` — 9/9
- `optional_ai_smoke.py` — 6/6
- `agent_envelope_carveout_smoke.py` — 8/8

## Submodule pointers (committed locally in ai-meta, awaiting push)

```
ops    0a8d03f811e7cd78662ce83bb49b9125cd062e82
e2e    83405ae547e1b362729e577d4a397c2829a20e01
noetl  ee196cfd1ca4634f2062e42425ffbb7bbae9f34a   (v2.35.8 tip)
```

Three commits queued on ai-meta `main` (3 commits ahead of origin):

```
ac08a75 chore(sync): bump noetl pointer for diagnosis fetch race fix
19ab7fa chore(sync): bump ops + noetl pointers for spike green follow-up
0059042 chore(sync): bump ops + e2e + noetl pointers for Gap 4.1 follow-up
```

User pushes ai-meta themselves (per the standing constraint).

## Architectural notes

- The Gap 4.1 wait+fetch pattern is now production-validated, and
  the e2e fixture can drop its tactical poll loop. The poll's
  `attempts == 0` telemetry is the cleanest way to confirm: when
  it stays 0 across runs, the noetl-side fix is working; if it
  ever climbs back up, that's a regression signal.
- The MCP server's `stateless JSON-RPC` mode (#414) is now the
  baseline for any agent dispatch that runs through the troubleshoot
  hook — per-call session state was incompatible with the wait+fetch
  contract.
- `persist_diagnosis` step name is now formalised as a config knob
  (`task_config.on_failure.diagnosis_step` /
  `NOETL_TROUBLESHOOT_DIAGNOSIS_STEP`) so bespoke troubleshoot
  playbooks can name the persisting step differently.

## Follow-ups (not blocking)

1. e2e cleanup PR — drop the 30-attempt poll loop in
   `spike_e2e_test.yaml` once we have a few GREEN runs at
   `attempts == 0`. Keep the `diagnosis_lookup` telemetry as a
   regression detector.
2. Document the wait+fetch contract in
   `repos/docs/agents/auto-troubleshoot.md` (or wherever the Gap
   4.1 hook is documented).
3. Three orphan empty files at the ai-meta root (`Read`, `after`,
   `and`) appear to be artifacts of a shell mishap — clean up
   before next push.

## Refs

- bridge/outbox/20260505-163002-gap41-three-prs-spike-still-green.result.json
  (full iteration log, 9 iterations)
- bridge/outbox/codex-spike-green-validation.md (appended GREEN
  follow-up paragraph for v2.35.8)
- ops#35, ops#36
- e2e#8
- noetl#413 (v2.35.5), noetl#414 (v2.35.6), noetl#415 (v2.35.7),
  noetl#416 (v2.35.8)
- Patches Claude pre-wrote (now landed):
  scripts/gap41_diagnosis_wait.patch,
  scripts/gap41_diagnosis_wait_msg.txt,
  scripts/gap41_diagnosis_wait_smoke.py
