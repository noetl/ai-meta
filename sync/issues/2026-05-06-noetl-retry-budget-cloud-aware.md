# Future direction: cloud-aware retry budget for persisted diagnoses

**Date filed**: 2026-05-06
**Status**: Captured / not started
**Origin**: GKE Vertex AI six-run sweep
(`bridge/outbox/20260506-151733-vertex-model-reconciliation-green.result.json`)
**Related**: noetl#416, `docs/architecture/vertex_ai_triage_backend.md`
cloud-latency section, `docs/architecture/agent_failure_diagnostics.md`

## The ask

Tune `_fetch_persisted_diagnosis_from_doc` so cloud-managed triage
backends do not rely on the spike fixture's belt-and-suspenders poll
loop to bridge provider latency.

The current retry window is implicitly Ollama-tuned. In practice it is
roughly a sub-second persistence window, which was enough for
in-cluster Ollama inference and the noetl#416 retry race. Vertex AI
adds a network round trip plus provider-side processing, so the
persistent diagnosis can arrive after the NoETL-side retry budget has
already given up. The diagnosis is still correct; the fixture just has
to poll a few more times to find it.

Cloud backends should have an effective persisted-diagnosis lookup
budget around 5-8 seconds.

## Why this matters

The 2026-05-06 GKE Vertex AI validation completed six spike runs with
`source=vertex-ai` and `model=gemini-2.5-flash`. Four of six runs had
`diagnosis_lookup.attempts <= 1`. Two runs needed two to three attempts:

- `620875219263030195`
- `620877265538122480`

That is acceptable cloud-latency variance for the current fixture, but
the core NoETL agent should eventually absorb that variance itself.

## Architectural options

### Option A: lengthen the retry budget unconditionally

Increase the retry count or sleep interval around
`_fetch_persisted_diagnosis_from_doc` for every backend.

Trade-offs:

- simplest implementation;
- strictly improves cloud behavior;
- may add a small latency cost when local Ollama genuinely fails to
  produce a persisted diagnosis;
- avoids plumbing backend identity into the helper.

Recommendation: start here. This is the smallest fix and should be
harmless for local clusters.

### Option B: backend-aware budget

Read the workload's `triage_mcp_server` value and choose a short budget
for local backends such as `mcp/ollama`, and a longer budget for cloud
backends such as `mcp/vertex-ai`.

Trade-offs:

- preserves the shortest local path;
- gives cloud backends the budget they need;
- requires the retry helper or caller to carry backend identity;
- risks provider-name branching if the taxonomy is not kept clean.

### Option C: adaptive backoff

Start with the local-short retry window, then extend with backoff if
the persisted diagnosis event has not appeared, capped at a maximum.

Trade-offs:

- most flexible;
- avoids hard-coded backend lists;
- easiest to tune over time;
- most complex to reason about and test.

## Implementation outline

Look in `noetl/tools/agent/executor.py` around:

- `_fetch_persisted_diagnosis_from_doc`
- `_wait_for_sub_execution_terminal`

For option A, extend the persisted-diagnosis fetch loop by 5-10x. For
option B, thread the resolved `triage_mcp_server` into the retry
decision and choose local-short versus cloud-long constants. For option
C, add a capped adaptive backoff sequence.

Add a smoke or unit test that fakes a delayed persisted-event flush so
the helper succeeds only when the longer budget is active.

## Effort estimate

- Option A: 0.5 day.
- Option B: 1-2 days.
- Option C: 2-4 days.
- Add a GKE regression sweep after any option lands.

## When to start

Start this at the next operational pain point, such as a CI or GKE
validation run with `diagnosis_lookup.attempts > 5`, or schedule it as
part of a planned cloud-latency optimization pass.

