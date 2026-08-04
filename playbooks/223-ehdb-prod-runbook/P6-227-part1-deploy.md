# #227 part 1 — deployed to prod (worker v5.92.2)

**Rolled 2026-08-04 ~12:05–12:15 UTC on `shastaratech-noetl-prod`. Part 1 only
(rehydrate over EHDB). Parts 2 and 4 are NOT deployed — they are server-side and
held for an explicit decision.**

| | |
| :-- | :-- |
| Version | **v5.92.2** ([worker#213](https://github.com/noetl/worker/pull/213), merged `3ef5231`) |
| Deployed digest | `noetl-worker-rust@sha256:92aa90c5eb8764b4c8684413900b16ec5ae7dad04992c9bf650ca97dd6002f49` |
| amd64 child | `sha256:a1b468ab5561…` (AR == GHCR, verified) |
| Rollback | `sha256:aee71e87e061…` (v5.92.1) |
| Server / gateway | unchanged (v3.60.2 / v3.7.1) |

Release green except the expected `publish-ar` (ai-meta#211); crane was the
path. semantic-release cut the version — no manual bump (ai-meta#224).

Roll order: writer (StatefulSet) → user pool → both system pools, strategic
`set-image`, container `noetl-worker`. All 5 worker pods on the new digest, **0
restarts, 0 CrashLoopBackOff**. Writer resumed `clamped=false`.

## The assertion — partly proven, and I am not going to overstate it

**What is proven: the transport fix is live.**

```
BEFORE:  rehydrate{outcome="empty"}       4653 / 4827      served: never once
AFTER :  rehydrate{outcome="empty"}          0 /    0
         rehydrate{outcome="incomplete"}    94 /   88
```

`empty` was "connect died at DNS" — the NATS-era path. It is now **gone**, and
the counter moved to `incomplete`, which is only reachable *after* a successful
subscribe and replay. The old warn
(`cold-rebuild connect failed … Name does not resolve`) no longer appears; the
new `#227` log lines do, including the mid-replay handler firing during the
restart:

```
state-builder cold-rebuild feed dropped mid-replay (noetl/ai-meta#227)
  addr=noetl-cmdbus-writer-0.noetl.svc.cluster.local:9108 error=early eof
```

That is this change's own error path, working, against the EHDB face.

**What is NOT proven: `rehydrate{outcome="served"}` is still 0.**

It needs a miss whose events are **still in the retained feed**. In this window
neither condition co-occurred:

- The only executions exercising the rehydrate path are the **22 legacy stalled
  ones**, whose chain gaps are beyond retention — they correctly return
  `incomplete`.
- The **fresh** executions never missed. On reconnect the drain replays from
  cursor 0 and rebuilt the index first (`indexed_executions=139
  wal_events=5335`), so the drive was served from the index and rehydrate was
  never consulted.

That is the system behaving correctly — rehydrate is the *fallback* for what the
drain's replay does not cover — but it means the end-to-end `served` assertion
remains **unobserved**, not passed. It should appear the first time an execution
misses the index with its events still retained.

## Behavioural result — the thing that actually matters

12 executions submitted, writer SIGTERMed mid-flight with backlog in flight
(`group_lag 58`):

```
COMPLETED 11   FAILED 0   RUNNING 1
```

Against the v5.92.1 comparable (22 COMPLETED / 8 stalled of 30 = **27% stall**),
this run stalled **1 of 12 (8%)**. Directionally right, but **n=12** — one small
run is not a rate. Treat it as encouraging, not as a measured improvement.

Writer resume after that SIGTERM: `clamped=false`, `replay_records` 58/58/57,
all three groups at their persisted cursors.

## Post-roll health

`/api/health` → `{"status":"ok","database":"connected","nats":"removed"}`; all
group lags 0; `cursor_errors` 0; `out_of_order_appends` 0; `clamped=false`.

## Not changed

- The **22 stalled executions remain `RUNNING`** and were never expected to
  drain from part 1. They now fail rehydrate with `incomplete` rather than
  `empty` — a better diagnosis, not a recovery.
- The orphan-sweep guard is untouched.
- No terminal events were hand-written.
