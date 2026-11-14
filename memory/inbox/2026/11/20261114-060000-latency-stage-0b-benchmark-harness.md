# Latency plan Stage 0b: the kind benchmark harness is merged (ops#381)
- Timestamp: 2026-11-14T06:00:00Z
- Author: Kadyapam
- Tags: latency, benchmark, kind, ops, harness, ai-meta-557

## Summary

`ops/ci/kind/latency/` (ops#381, `12aa4b4`) is the before/after instrument for every stage of the latency-reduction plan (RFC #556, issues #557–#562). It stands up an isolated `*-lat` runtime inside the shared kind cluster, with its own database `noetl_lat`, writer, server and pools. The server env is overlaid with prod's dispatch path: offserver state builder, publish-only ingest, retrigger-on-clear. #557 is closed.

## Baseline (server 3.161.2, worker 6.15.0, two reps)

| Arm | Result |
|---|---|
| Orchestration per step, idle | 32–36 ms p50 |
| Drive hand-off, idle | 19–21 ms |
| Drive hand-off, 8 concurrent | ~125 ms p50, p95 250 ms (rep 1) |
| Pickup | 6–12 ms, flat under load |
| Awaited hop | ~2.04 s, ~1.95 s of it the tool's pre-poll sleep |
| Auth (`check_playbook_access`) | max 0.97 s |

## Lessons

- **Kind idle is not prod.** ~35 ms per step against ~0.95 s on prod. Judge each stage by its relative effect on the segment it targets.
- **Under load, the drive hand-off is the segment that grows.** Every drive queues on the 2-slot system pool, rebuilds from the full spine (~17 M WASM fuel) and runs behind a per-process WASM mutex.
- **Kind A does not run prod's offserver builder.** Measure on the lat stack, not on A.
- **The host load swings the loaded arm.** Rep 2 ran at a load average of 6–8 on 6 CPUs. `run.json` records host load; compare with `ab.sh` (interleaved).
- **Tool-list batching already exists.** A step's ordered tool list is already one `task_sequence` command; nothing to build for that half of #558.
- **Shared-cluster etiquette.** Other sessions use kind-noetl (a kuksin intake run landed today). Never swap A's images for a long measurement; use `stack.sh`.
