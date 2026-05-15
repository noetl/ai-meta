---
date: 2026-05-07T01:50:00Z
title: GKE Vertex AI arc closed AMBER — round 3 ships v2.36.1, tail-latency limit documented, adaptive backoff filed
tags: [noetl, gke, vertex-ai, retry-budget, tail-latency, adaptive-backoff, codex-bridge, arc-closed-amber]
---

## Outcome

AMBER. Round 3 of 3 shipped, GKE arc is closed at the architectural
limit of static-budget tuning. Production stack is healthy
(`v2.36.1`); typical workload paths complete cleanly; tail-latency
events fall through to the spike fixture's polling layer and
finish correctly. Adaptive backoff filed as the architectural
follow-up when tail latency becomes a real operational concern.

## What round 3 shipped

- **[noetl/noetl#419](https://github.com/noetl/noetl/pull/419)**
  merged. Made the diagnosis-fetch retry budget explicit and
  extended it from the previously-implicit 10s to 12s. Regression
  test proves an 11s persisted-diagnosis flush is now covered.
- **Released as `v2.36.1`** (semantic-release picked patch from
  `perf:` commit type — let CI choose the tag, lesson held).
- **Deployed to GKE** noetl-server + noetl-worker via the
  `bump_image` lifecycle agent.
- **Six existing smokes + the new executor-side regression test
  all pass.**

## The architectural finding worth keeping

**My round 3 task spec premise was stale.** I assumed the budget
was ~600ms based on early-arc context. It was already 10s in
v2.36.0 (bumped by some prior round without me knowing — possibly
during the Gap 4.1 work or as part of noetl#418's worker fix).
Codex caught this and made the smallest correct fix: 10s → 12s
with explicit constants and a regression test, rather than
implementing a much larger change that wasn't actually needed.

**Lesson for drafting follow-up tasks**: have Codex check current
state before assuming. The repository state moves fast across
multi-round arcs and "what we said the value was N rounds ago" is
often outdated.

## The architectural limit of static budgets

3-run GKE sweep on v2.36.1:

```
621191024861250261: attempts=16    ← cold-start outlier (~30s+ tail)
621192028121990042: attempts=0     ← warm Vertex AI state
621192385132757121: attempts=0     ← warm Vertex AI state
```

The cold-start signature is unmistakable: first run after a
deploy hits tail latency, subsequent runs reuse warm Vertex
state. **A static budget cannot reliably absorb 30s tail latency
without making the warm path gratuitously slow.** This is the
ceiling for option (a) from the parent sync issue — extending
the budget further hits diminishing returns and bad latency on
the warm path.

## Defense-in-depth saved this

Even with the cold-start outlier, all 3 runs completed GREEN
functionally. The spike fixture's polling loop (originally added
in e2e#8 as a workaround for Gap 4.1's missing wait, now retained
as belt-and-suspenders after the noetl-side fix) absorbed the
tail-latency case — `attempts=16` proves the fixture polled past
where noetl's budget exhausted, and the diagnosis was eventually
read. **The architecture is layered**, and that's why a
single-layer limit (static budget) doesn't cause a runtime
failure.

## New sync issue filed

`sync/issues/2026-05-07-noetl-adaptive-retry-backoff-tail-latency.md`
captures the proper architectural fix:

- **Adaptive backoff**: start short (~0.5s), exponential extension
  (1.5x, capped at 4s), generous deadline (~60s).
- Handles both warm path (~1-3 polls) and cold path (~10-12 polls)
  cleanly without per-backend configuration.
- Effort: ~2-3 days plus GKE validation.
- When to start: operator-driven — when tail latency causes a
  real failure (not just `attempts > 1`), or when a new cloud
  backend ships and makes the algorithmic improvement worth
  doing once.

## The arc, three rounds, in summary

| Round | Change | Release | Verdict |
|---|---|---|---|
| 1 | Worker forwards triage_* generically [noetl#418] | v2.36.0 | GREEN |
| 2 | Deprecated ollama_* aliases removed [ops#42] | (no release) | GREEN |
| 3 | Static retry budget tuned to 12s [noetl#419] | v2.36.1 | AMBER (tail latency) |

The dispatch chain is now canonical-only end to end. The naming
surface is clean. The static-budget tuning is at its sensible
ceiling. Adaptive backoff is the next architectural step when
warranted.

## Submodule pointers (committed locally in ai-meta, awaiting push)

```
M  bridge/outbox/codex-spike-green-validation.md  (Claude-appended close-out paragraph)
M  repos/noetl                                    (noetl#419 → v2.36.1, staged at 3d74265a)
+  sync/issues/2026-05-07-noetl-adaptive-retry-backoff-tail-latency.md  (new)
```

Plus this memory entry.

## What's actually production-ready

- GKE Vertex AI integration with `gemini-2.5-flash` for triage
- Workload Identity → Vertex AI confirmed
- `mcp/gcp/gke` observability MCP (15 tools)
- Frontend gateway docs at `repos/docs/docs/gateway/frontend-quickstart.md`
- Three releases shipped (v2.36.0, v2.36.1)
- Six smoke regression detectors
- One canonical validation log capturing the full chronological
  state of the AI-OS spike from RED through to AMBER-with-known-
  limits

## What's filed but not done (in priority order)

1. **Adaptive retry backoff** for tail-latency tolerance —
   `sync/issues/2026-05-07-noetl-adaptive-retry-backoff-tail-latency.md`
2. (Originally three follow-ups; rounds 1+2 completed; round 3
   reached static-budget ceiling and re-filed as adaptive backoff.)

## Refs

- bridge/outbox/20260507-010751-retry-budget-cloud-aware.result.json
- bridge/outbox/codex-spike-green-validation.md (chronological
  arc record, now closed at AMBER)
- noetl/noetl#419 (v2.36.1 — static budget tuning)
- sync/issues/2026-05-07-noetl-adaptive-retry-backoff-tail-latency.md
  (the architectural follow-up)
