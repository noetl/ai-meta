# Latency plan Stage 1: worker-local drive merged flag-off (server v3.162.0, worker v6.16.0)
- Timestamp: 2026-11-14T10:00:00Z
- Author: Kadyapam
- Tags: latency, orchestration, local-drive, server, worker, kind, ai-meta-558

## Summary

The worker that completes a step now drives the next one itself and runs it on the same slot (server#584 → v3.162.0, worker#402 → v6.16.0).
- **Flags (default off):** server `NOETL_SERVER_ADVANCE_API`; worker `NOETL_WORKER_LOCAL_DRIVE`, `NOETL_LOCAL_DRIVE_MIN_FREE_SLOTS` (1).
- **Rollback:** flags off, or pin v3.161.2 / v6.15.0.
- **Prod:** nothing enabled. #558 is closed.

**Measured** on kind (interleaved A/B, prod pool CPU shape), flags off → on, p50:

| Arm | Off | On |
|---|---|---|
| Drive, sequential | 23 ms | 15 ms |
| Orchestration per step | 41 ms | 33 ms |
| 8-concurrent wall (3 reps) | 31.0 s | 19.8 s |
| Auth | 800 ms | 357 ms |

Auth worst case was 3.9 s against the 15 s budget.

## Design (re-usable for #561 Stage 4)

- **Header-keyed claim.** `x-noetl-local-drive` on `command.completed`. `trigger_orchestrator` skips that event; the reconcile poller is untouched.
- **`advance`, `begin` phase.** Returns the SAME `__orchestrate__` args plus the tail ring (`chain_tails`, depth 256).
- **`advance`, `apply` phase.**
  - Runs the SAME `apply_worker_orchestration`.
  - The handoff claims the first same-subject command for the driver and never publishes it.
- **`advance`, `abort` phase.** Falls back to today's dispatch.

## Lessons

- **A direct claim races the feed.** The feed delivers in milliseconds, so a post-apply claim lost the race every time: the server must claim inside `apply`, before publish.
- **The server's claim is idempotent for the same worker id.** So a command handed off AND delivered by the feed runs twice unless the worker dedups (claim-once per process).
- **The drive moves CPU onto the user pool and holds the slot.** Gate it on a spare slot, or a saturated pool starves queued executions.
- **Kind's 500m user-pool cap is not prod's 2 CPU.** It throttled the moved drive (250/446 CFS periods). Always measure with `stack.sh` at prod's shape (default since ops#382).
- **Host contention.** The VM load average is ~10, giving 1–3 s stalls on both A/B sides. Judge on p50 and per-step segments over interleaved reps; tail p95s are noise.
