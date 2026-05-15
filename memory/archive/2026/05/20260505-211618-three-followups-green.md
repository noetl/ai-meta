---
date: 2026-05-05T21:37:49Z
title: Three follow-ups landed GREEN — GHCR probe + projection audit + parity smoke
tags: [noetl, ops, docs, event-projection, parity, codex-bridge]
---

## Outcome

GREEN across all three sequenced phases. Cluster remains on
`v2.35.9` (no noetl release this round). ai-meta `main` is 1
commit ahead of origin (`45f920f chore(sync): add projection
parity smoke and bump ops/docs pointers`).

## What landed

### Phase A — GHCR-availability probe in `bump_image`

[noetl/ops#37](https://github.com/noetl/ops/pull/37) merged at
`827fb86b`. New `verify_image_available` step before the rollout
loop probes `HEAD https://ghcr.io/v2/noetl/noetl/manifests/<tag>`
for up to N attempts before triggering kubectl rollout. Configurable
via `ghcr_probe_attempts` / `ghcr_probe_sleep_seconds` workload
knobs; skipped automatically for kind/podman local registries
based on a string-prefix check on `$NEW_IMAGE`. Validated with:

- Negative test (exec `620331512323375641`): fake tag
  `ghcr.io/noetl/noetl:v9.99.99-fake` failed cleanly within the
  probe window with a structured error, NOT a kubectl rollout
  timeout. No deployment mutation.
- Positive test (exec `620331690296083052`): v2.35.9 idempotent
  run completed; all components reported "unchanged".

Codex also added a defensive in-step probe after discovering a
failed verify step could still fall through to the rollout loop
in some shell paths — caught and fixed within the single PR.

### Phase B — Worker event-projection audit

`bridge/outbox/event_projection_audit.md` written.
**Zero new CONFIRMED_BUGs** beyond the already-merged baseline
fix in noetl#417. The audit covered 13 code paths across worker
projection (`_extract_control_context`, `_externalize_event_value_if_needed`,
`_normalize_payload_reference_only`, `_emit_terminal_event_batch`,
etc.), server write path (`_validate_reference_only_payload`,
`_collect_compact_context`, `_bounded_context`,
`_build_reference_only_result`), and execution read path
(`_deserialize_event_row`, `_fetch_execution_events_page`,
`get_execution`, `get_execution_events`).

**Three documented POTENTIAL_RISK items** (no in-flight fix per
task rules — deferred for design pass):

1. `_extract_control_context` reduces arbitrary nested
   non-error dicts to scalar children. Safe for current
   contracts (the only nested control payload is
   `error.diagnosis` and it has an explicit carve-out), but
   any future nested control contract needs (a) an explicit
   carve-out, (b) an entry in the parity smoke's static
   fixtures, or both. This is the projection chokepoint.
2. Worker blocked data-plane keys (`data`, `response`,
   `result`, `payload`, `rows`, `columns`) are intentionally
   excluded from strict context. Future semantic control
   metadata accidentally placed under those names would be
   silently dropped.
3. Server `_collect_compact_context` is allow-list-only on
   top-level transport fields. Safe as a compact merge helper,
   but should not become the only persistence path for any
   future nested control metadata.

**Eight SAFE_BY_DESIGN paths confirmed** — agent envelope
preservation, agent diagnosis carve-out, task_sequence scalar
errors, MCP data-plane separation, playbook data-plane
isolation, externalized payload preservation, server
`_bounded_context` byte-bound preservation, and execution
read path JSON pass-through.

### Phase C — Live-vs-persisted parity smoke

`scripts/live_vs_persisted_parity_smoke.py` (Python 3 stdlib +
requests). Two modes:

- **Static** (no cluster): canned fixtures — v2.35.9-shape that
  must PASS, v2.35.8-regression-shape that must FAIL with
  `NESTED_DICT_LOSS at result.context.error.diagnosis`.
- **Cluster** (`--execution-id <id>`): walks /api/executions/<id>
  events, compares nested-dict key sets across terminal events
  for the same step. First terminal event is the live
  projection source; later events must retain the same nested
  control dicts.

Validated against execution `620335758527693503` (spike e2e,
GREEN): 6 terminal events processed, 4 step-pair comparisons,
all PASS.

[noetl/docs#27](https://github.com/noetl/docs/pull/27) merged at
`e9d1523b` — added "Detecting projection regressions" section to
`repos/docs/docs/architecture/agent_orchestration.md` covering
both invocations + the regression history.

## All 5 smokes PASS

- agent_envelope_carveout — 8/8
- gap41_diagnosis_wait — 7/7
- auto_troubleshoot — 9/9
- optional_ai — 6/6
- live_vs_persisted_parity — static 2/2 + cluster GREEN

## Architectural take

The audit's most valuable artifact is the explicit naming of the
**projection chokepoint**: `_extract_control_context()` decides
what nested metadata survives event persistence. Today it has
exactly one carve-out (`error.diagnosis`) on top of the generic
"scalars + reference wrappers" rule. The audit's POTENTIAL_RISK
findings collectively say: **the next nested control contract
needs an opinion before it ships**. The parity smoke is the
regression-detector that catches the failure mode at PR-time
rather than several releases later — when a future contributor
adds a nested dict, the static fixture should be updated to
include it AND the worker carve-out logic extended.

## Submodule pointers (committed locally in ai-meta, awaiting push)

```
ops    827fb86bc375894184e6c95459f7d28f0673f767   (ops#37 merged)
docs   e9d1523b7f4b7d826652d18d7f3e2de93ffa7c4c   (docs#27 merged)
noetl  8b641b056fc3867a515b3196913c0aa2febad937   (unchanged, v2.35.9 tip)
```

## Deferred for next round

Single deferred item from Phase B: a design pass for
`_extract_control_context` to either (a) generalise the
nested-dict carve-out beyond `error.diagnosis` (e.g. a
declarative allow-list of nested control paths), or (b) document
an explicit "add to parity fixtures + add to carve-out list"
contract for new nested control fields. Not blocking — the
current behaviour is safe for all reviewed contracts, and the
parity smoke makes the failure visible if anyone adds a new
contract without following the contract.

## Refs

- bridge/outbox/20260505-211618-three-followups-in-order.result.json
- bridge/outbox/event_projection_audit.md
- repos/docs/docs/architecture/agent_orchestration.md (PR #27)
- noetl/ops#37 (GHCR probe → bump_image)
- noetl/docs#27 (parity smoke documentation)
- noetl/noetl#417 (the baseline projection fix referenced
  throughout the audit)
