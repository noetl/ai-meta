# Latency plan Stage 2: push completion + park the await, merged flag-off (server v3.163.0, tools v4.7.0, worker v6.17.0)
- Timestamp: 2026-11-14T14:00:00Z
- Author: Kadyapam
- Tags: latency, await, park, kind-playbook, server, tools, worker, kind, ai-meta-559, ai-meta-570

## Summary

An awaited `kind: playbook` child's completion is pushed to the parent instead of found by the tool's 2 s poll, and the parent can give its slot back while it waits.
- **PRs:** server#585, tools#120, worker#403 (pins tools 4.7.0), ops#383 / #384.
- **Flags (default off):** `NOETL_EXECUTION_WAIT`, `NOETL_PLAYBOOK_AWAIT_PARK` (server + worker), `NOETL_CATALOG_REMOTE_PUSH` (server).
- **Enablement precondition:** `NOETL_STATE_BUILDER=offserver`; see #570.
- **Rollback:** flags off, or pin v3.162.0 / v6.16.0.
- **Prod:** nothing enabled. #559 is closed.

## Measured on kind (lat stack, prod topology, interleaved)

| Measure | Off | On |
|---|---|---|
| Awaited hop p50 | 2040 ms | 108 ms |
| `hop.notice` | 1940 ms | 8.5 ms |
| 6 awaiting parents on 4 slots | 4/6 failed | 6/6 |

Auth max is 0.86 s.

## Lessons

- **Wake on the WRITE, not the emit.** Under publish-only, `/status` reads materialized rows: notify from `insert_rows` and `events_project`.
- **The 2 s poll hid a materialization-order race.** The terminal row can land before the result `call.done`. Any push-woken reader must settle on the `call.done` (server resume and tools wait path both do now), or it returns a `command.completed` envelope.
- **A failed park resume must emit `call.error` + `command.failed`.** A FAILED `call.done` lets the DAG advance.
- **The entry step has no `step.enter`.** On a server-side builder a parked `start` re-issues (63×). Never park `start`.
- **Kind A runs the SERVER-side builder; prod runs offserver.** Flags-on delegate e2e on A gives 42–49/50 (#570), while the lat stack (offserver) is clean. Validate on the lat stack's topology first.
- **Kind A workers OOM at 768Mi** (11 kills per e2e, flags on and off). Use `E2E_WORKER_MEM=2Gi`; at 2Gi the flags-off e2e is 50/50.
- **zsh does not word-split `$var`.** A loop passing `$args` to `stack.sh set` silently applied nothing. Run harness loops under bash.
