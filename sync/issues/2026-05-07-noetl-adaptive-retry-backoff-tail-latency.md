# Future direction: adaptive retry backoff for diagnose sub-execution tail latency

**Date filed**: 2026-05-07
**Status**: Captured / not started
**Origin**: Round 3 of GKE Vertex AI arc closure
  (bridge/outbox/20260507-010751-retry-budget-cloud-aware.result.json)
**Related**:
- `sync/issues/2026-05-06-noetl-retry-budget-cloud-aware.md`
  (the parent issue; this is option (c) escalated to its own
  filing because option (a)'s static budget is not enough)
- noetl/noetl#418 (v2.36.0 — worker key-forwarding
  generalisation)
- noetl/noetl#419 (v2.36.1 — static budget bumped to 12s, this
  round)

## The ask

Replace the static retry budget in
`_fetch_persisted_diagnosis_from_doc` with an **adaptive backoff
strategy** that handles cloud-managed inference tail latency.
The static 12s budget shipped in v2.36.1 covers typical Vertex AI
calls (1-3s + flush window) but cannot absorb the tail latency we
observed on cold starts (~30s+ end-to-end).

## The empirical evidence behind this filing

GKE 3-run sweep on v2.36.1 (post-tuning):

```
621191024861250261: vertex-ai / gemini-2.5-flash / attempts=16
621192028121990042: vertex-ai / gemini-2.5-flash / attempts=0
621192385132757121: vertex-ai / gemini-2.5-flash / attempts=0
```

Cold-start signature: first run hit tail latency (`attempts=16`,
implying the diagnose sub-execution took ~30+ seconds), subsequent
runs at `attempts=0` (warm Vertex AI state). Static budgets at
any reasonable size can't reliably absorb both the cold case
(~30s) and the warm case (~1s) without making warm calls
gratuitously slow.

## Architectural option

**Option (c) from the parent sync issue: adaptive backoff.**

```
def _fetch_persisted_diagnosis_from_doc_adaptive(execution_id):
    sleep_seconds = 0.5      # start short
    deadline = now() + 60.0  # generous cap
    while now() < deadline:
        result = try_fetch(execution_id)
        if result:
            return result
        time.sleep(sleep_seconds)
        sleep_seconds = min(sleep_seconds * 1.5, 4.0)  # exponential, capped
    return None
```

This handles:
- **Warm path**: typical case completes within 1-3 polls
  (~0.5-2s wall time).
- **Cold path**: tail-latency case keeps polling with growing
  intervals up to the deadline. ~30s tail latency completes in
  ~10-12 polls.
- **Genuinely missing**: 60s max cap returns None cleanly.

## Open design questions

- **Initial sleep**: 0.5s is a reasonable start. Worth A/B'ing
  against 0.2s for warm-path latency optimization.
- **Backoff multiplier + cap**: 1.5x with 4s ceiling keeps poll
  cadence reasonable without bursting too fast. Worth measuring
  against 2x with 5s cap.
- **Deadline**: 60s feels right for cold-start tolerance. Could
  be operator-configurable per backend if cloud providers'
  SLAs differ.
- **Per-backend tuning**: option (b) from the parent sync issue
  was "backend-aware budget". Adaptive backoff is more general
  but could still vary deadline by backend (local 10s, cloud
  60s, escalation 90s) if measurements warrant it.
- **Telemetry**: emit the actual elapsed time + poll count to
  the diagnose envelope's `_meta` so we can observe the latency
  distribution per backend over time and tune the parameters
  with real production data.

## Implementation outline

1. Refactor `_fetch_persisted_diagnosis_from_doc` to use the
   adaptive loop. Constants pulled out as configurable
   defaults.
2. Add a regression test fixture exercising both warm path
   (~0.5s flush) and cold path (~25s flush) — both should
   complete cleanly.
3. Emit poll-count + elapsed-time telemetry in `_meta` of the
   diagnose envelope.
4. Run the GKE 3-run sweep with this fix; expect all 3 runs to
   complete cleanly even with the cold-start outlier (cold-run
   attempts ~10-12, warm-run attempts ~1-3).
5. Update `vertex_ai_triage_backend.md`'s cloud-latency section
   with the new adaptive profile (typical attempts now spans
   1-12 depending on warm/cold, deadline 60s).

## Effort estimate

~2-3 days focused work plus GKE-side validation. Larger than the
static-budget tuning because it's an algorithmic change and
deserves a proper test matrix.

## When to start

Pick this up when:
- Tail latency becomes a real operational concern (e.g. a
  diagnose call returns no diagnosis because the spike fixture
  ALSO timed out, not just the noetl-side budget), OR
- A cold-start cluster regularly hits `attempts > 5` in CI, OR
- A new cloud backend (AWS Bedrock, Azure OpenAI) ships and
  brings its own latency profile worth optimizing.

Until then, the spike fixture's belt-and-suspenders polling
loop continues to absorb tail latency — the architecture is
defense-in-depth and the AMBER outcome reflects the static
budget's documented limit, not a runtime failure.

## Filed-for-later, not blocking

The v2.36.1 stack ships and works. Cold-start runs complete
cleanly via the fixture's polling layer. This is captured for
future iteration when the tail-latency profile becomes worth
optimizing in noetl proper.
