# noetl.ai DSL KB re-sync + resource and performance model for agents
- Timestamp: 2026-11-12T01:30:00Z
- Author: Kadyapam
- Tags: noetl.ai, dsl-kb, resource-model, server, worker, keda, docs

## Summary

This covers two pieces of work: a re-sync of the noetl.ai DSL knowledge base (KB), and a new machine-readable resource and performance model for AI agents at https://noetl.ai/dsl/resource-model.json. The model is generated in noetl/server (`orchestrate-core/src/resource_model.rs`), and the same `dsl_artifacts` byte-compare test that guards the schema and manifest guards it against drift.

Every figure is labelled MEASURED, DEFAULT, DEPLOYED, GUIDANCE, TARGET or NOT_YET_MEASURED, and every MEASURED figure cites a public source with its environment and date. Tests reject an unlabelled figure, a MEASURED figure with no source, and a NOT_YET_MEASURED item that carries a number. A negative control shows each check can fail. The rule is never to invent a number: a gap is recorded as a gap.

## Actions

**KB re-sync**
- server#578 (`4aa7b851`, `chore:`, no release) added three manifest sections:
  - `catalog_features.source_scheme_forms`: the `db://` and `ehdb://` forms;
  - `worker_runtime.wasm_limits`: fuel 10e9, 30000 ms, 1024 MiB, on by default;
  - `worker_runtime.agent`: playbook-bound `tools:`, 32 tool calls and 180 s per tool, and the `agent.turn` / `agent.tool_call` / `agent.final` events.
- noetl.ai#6 (`f450f8ce`) renders the new sections.
- noetl.ai#7 (`10db40d3`) re-pins the site. Deployed `2dd9fb5c`. (#8 was a duplicate, closed.)

**Resource model**
- server#580 (`62137e65`, `chore:`, no release) adds the model.
- noetl.ai#9 (`4ef8f263`) adds the sync and provenance changes (`source.json` gains `resource_model_digest`), the `llms.txt` section and an explorer card. The nightly `sync-dsl` job now diffs the model too.
- Deployed `714e219a-1215-4d60-a7a5-c9e753985deb`. The WAITLIST KV binding was verified intact before and after.

**The 7 NOT_YET_MEASURED gaps**
1. prod per-step latency of http, duckdb, postgres and mcp steps;
2. a hosted LLM call inside a real step;
3. sustained executions/s on prod;
4. worker slot occupancy over time;
5. KEDA ramp-up and scale-down time on the EHDB trigger;
6. catalog URI fetch latency;
7. unsaturated command-bus latency after 2026-07-30.

**Facts surfaced**

These are recorded in the model; none of them is fixed.
- `loop.spec.max_in_flight` is parsed but nothing reads it, so a parallel loop dispatches every item at once.
- The worker has no per-command timeout. python, shell, postgres, duckdb and rhai steps have no default timeout.
- WASM execution is serialized per worker process.
- `ops/ci/manifests` declares a system-pool ScaledObject (3–10) that does not exist on prod. The system pool is a fixed 2 × 2 slots.
- Prod user pool, as read on 2026-11-11: 2–20 replicas × 4 slots. KEDA uses metrics-api `ehdb_feed_subject_lag`.

**Traps**
- `/api/dsl/*` on noetl.ai passes through to the prod server, which reports v3.156.2 until prod is rolled. Those routes are computed live under the process's gates. The resource model is static only.
- Python urllib gets a 403 from noetl.ai (a Cloudflare UA block). Use curl.
- The model draws only on public sources; figures that exist only in private memory were left out.

## Repos
- noetl/server, noetl/noetl.ai, noetl-server-wiki (new `dsl-artifacts` page), ai-meta-wiki

## Related
- noetl/ai-meta#552 (opened after the fact and closed)
- https://github.com/noetl/server/wiki/dsl-artifacts
