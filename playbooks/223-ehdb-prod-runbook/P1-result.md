# P1 — release and roll worker#211: RESULT

**Run 2026-08-03 against `shastaratech-noetl-prod`. Completed. Prod is healthy
on worker v5.92.0.** Held before P2 (soak) and P4 (IaC) as instructed.

## What shipped

| | |
| :-- | :-- |
| Version | **v5.92.0** |
| PR | [noetl/worker#211](https://github.com/noetl/worker/pull/211), merged (merge commit) as `ddb4de8` |
| Tag commit | `ddb4de8e2467e7bd435327b4ca03f8238e1f2b83` |
| GHCR | `ghcr.io/noetl/worker:5.92.0` — OCI index, `linux/amd64` + `linux/arm64` |
| **Deployed digest** | `us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:ad1e96063bf53b44869deab2cd3afec0152b033bd7f28d528299db7b65781725` |
| amd64 child digest | `sha256:21f4b892091f2cb0a62d69403c9a68cda56e7702a07a4d721dad2af222a2f2f5` (AR == GHCR, verified) |
| Server / gateway | **not rolled** — no new rev; server stays v3.60.2, gateway v3.7.1 |

The three fixes: fail-loud internal bus source (#221), sequenced writer seal
**and stop-ingest** on SIGTERM (#209 graceful half), face supervision
(mitigation for ehdb#311).

## P1a — gate

Re-run on the final tip `c44ebf2`:

```
cargo test    580 passed, 0 failed, 2 ignored, 13 binaries
cargo clippy  exit 0 (1 warning: unnecessary clone in a lib test; no clippy gate in CI)
```

Plus 8 consecutive full-suite runs, 0 failures — the condition that previously
exposed the lost-wakeup race. 32 clean gate runs counting the author's 24.

`publish-ar` failed red as expected (ai-meta#211, build SA cannot stage source
in the `_cloudbuild` bucket). Every artefact of record was green:
`verify-version`, `publish-image` amd64 **and** arm64, `publish-manifest`,
`publish-crate`, `github-release`.

## P1b — GHCR → AR via crane

`crane copy` of the manifest list; AR's `linux/amd64` child digest matches
GHCR's exactly. Deployed by digest, never by tag.

## P1c — env precondition

Re-checked immediately before the roll. All four consumers on both system pools
carry their `_SOURCE=ehdb`; the user pool and the writer enable none of the four
and demand nothing. Writer `terminationGracePeriodSeconds=90`, far above the
15 s `NOETL_EHDB_SHUTDOWN_TIMEOUT_MS` default. No `kubectl set env` remedy was
needed.

## The drain / roll sequence actually used

The writer being replaced was still the **old** image, so on the way out it
carried both the unsealed-tail bug and the lost-wakeup bug. Draining first is
what made the one old→new transition clean.

1. **Drain to a stable, quiet tip.** Six samples ~5 s apart, all identical:
   `cmd_committed=39148`, `cmd_lag=0`, `total_lag=0`, all three group cursors
   `3072`, `group_lag=0`, `cursor_errors=0`. Exposure (`min(1024, lag)`) = **0**,
   so there was no in-flight unsealed tail to lose.
2. **Writer** — `kubectl set image deploy/noetl-cmdbus-writer-0 noetl-worker=<digest>`.
   `set image` is a strategic patch; **`--type merge` was never used** (it
   replaces the containers array wholesale and wipes env, ports, volumeMounts
   and probes).
3. **Server** — skipped. No new server rev, so the runbook's step 2 is a no-op.
4. **Pools**, last, against an already-running writer:
   `noetl-worker-rust`, `noetl-worker-system-pool`,
   `noetl-worker-system-pool-shard1` — each targeting container `noetl-worker`
   **by name**, never a wildcard (the `wait-for-api` init container is
   `curlimages/curl:8.7.1` and a wildcard would swap it for the worker image).

No connect was ever made to `:9104`, `:9107` or `:9108` (ehdb#311). Face
liveness was read from the pod's own `netstat -ltn`.

### Roll result

All five worker pods Running on the new digest, **0 restarts, 0
CrashLoopBackOff**. Writer resume across the drop was exact:

```
pre-roll  cmd_committed = 39148
resume    from_cursor   = 39148  origin="persisted"  clamped=false  replay_records=0
groups    stored=3072 tip=3072 from=3072 clamped=false replay=false   (all three)
```

## Post-roll paired evidence

Synthetic execution `342802954006306816` (`vars_test/test_vars_block` — pure
Python, no external I/O, no writes) → **COMPLETED**.

| Measure | Before | After | Delta |
| :-- | --: | --: | --: |
| `ehdb_feed_shard_committed` | 39148 | 39167 | +19 commands |
| `noetl_materializer` cursor | 3072 | 3103 | **+31** |
| `noetl_result_materializer` | 3072 | 3103 | **+31** |
| `noetl_state_materializer` | 3072 | 3103 | **+31** |
| durable events for that execution | — | **31** | matches exactly |

All three groups advanced by the same delta and ended at **lag 0**;
`ehdb_events_cursor_errors 0`, `ehdb_l0_out_of_order_appends 0`. The durable log
carries `playbook.completed COMPLETED`. Published == projected == 31 — paired
evidence, not a green count.

Bus: `/api/health` → `{"status":"ok","database":"connected","nats":"removed"}`.
All ten faces listening (9090, 9100–9108).

## The payoff — SIGTERM seals AND stops ingest

A controlled graceful restart (`kubectl delete pod`, grace 90 s) of the **new**
writer, from a verified-stable tip (`cmd_committed=39171`, groups `3103`, lag 0):

```
23:00:45.545  Shutdown signal received
23:00:45.545  sealing EHDB writer hosts before exit           hosts=2
23:00:45.545  EHDB command-bus ingest face stopped — listener closed
23:00:45.547  EHDB command-bus ingest listener closed         label="command-bus"
23:00:45.801  EHDB command-bus cursor persisted on shutdown
23:00:45.834  EHDB command-bus log sealed on shutdown
23:00:45.834  EHDB events ingest face stopped — listener closed
23:00:45.835  EHDB events-feed ingest listener closed         label="events-feed"
23:00:46.087  EHDB events-feed cursor persisted on shutdown
23:00:46.113  EHDB events-feed log sealed on shutdown
23:00:46.113  Worker stopped
```

Three things this proves, in the order they matter:

1. **`hosts=2` — the events writer sealed.** Before this release it never
   sealed under any circumstance, and it is the sole writer of the durable
   `noetl.event` log (the server runs `NOETL_EVENT_INGEST_PUBLISH_ONLY=true` and
   writes zero rows).
2. **The listener is closed *before* the cursor and the seal, and the close is
   acknowledged, not assumed** — `face stopped — listener closed` is emitted by
   the acceptor after its fd is dropped. That is the c44ebf2 fix working in
   prod. No accepted-then-hung publisher.
3. **568 ms total**, against a 15 s budget and a 90 s grace period.

Zero loss on the way back up:

```
pre-SIGTERM  cmd_committed = 39171           groups = 3103 / 3103 / 3103
resume       from_cursor   = 39171  tip=39171  stored=39171  clamped=false  replay_records=0
groups       stored=3103 tip=3103 from=3103  clamped=false  replay=false    (all three)
```

`clamped=false` everywhere is the point: the persisted cursor did **not** need
clamping to a reopened tip, because the log was sealed properly.

A second execution after the restart (`342804578565103616`) → **COMPLETED**,
groups advanced 3103 → 3137, lag 0, `cursor_errors 0`.

**Gateway / SSE.** The gateway logged `EHDB lifecycle feed error; reconnecting
… cursor=3103` for the ~2 minutes the writer was absent, then went silent at
23:02:38 when the SSE face came back — it holds its cursor across the reconnect,
so no frames are skipped. This is the benign one-shot the runbook already
predicts; it is more alarming than the condition.

## ⚠ Finding: semantic-release fought the manual version bump

24 seconds after the merge, `semantic-release` pushed
`b11e6d5 chore(release): version 5.91.3 [skip ci]`, which rewrote `Cargo.toml`
from **5.92.0 back down to 5.91.3** and tagged `v5.91.3`. It computed a patch
bump from 5.91.2 off the `fix:` commits, with no knowledge of the manual bump
the runbook's P1a requires.

Consequences:

- Worker `main`'s tip now claims **5.91.3**, a *lower* version than the newest
  published tag (**v5.92.0**), and contradicts what prod runs.
- Two images exist with byte-identical code: `5.91.3` and `5.92.0`.
- The next semantic-release will compute from 5.91.3 and produce something like
  5.91.4, which sorts **below** 5.92.0.

Prod is unaffected — the deployed image was built from the `v5.92.0` tag at
`ddb4de8` and was deployed by digest, verified against GHCR.

**The ai-meta pointer is therefore `ddb4de8`, not worker `main`'s tip**, because
that is the commit the running image was built from.

This is a real conflict in the runbook: P1a says to bump `Cargo.toml` manually
because `verify-version` hard-fails on a tag/Cargo mismatch, but this repo's
versioning is owned by semantic-release. Both cannot be right. Needs a decision
before the next release — either let semantic-release own the version and drive
the release from its tag, or disable it for this repo.

## Rollback (not used)

Image rollback only — there is no bus fallback.

```
PREV_WORKER=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:0d1866feafb79adcb9c6f80939572edf0d0bbc03da76ea7258e94d6e41ee83cb
```

Container name on every worker workload is `noetl-worker`. Roll the writer
first, then the pools.

## Gate

| Gate | Result |
| :-- | :-- |
| Pods | 5/5 on the new digest, 0 CrashLoopBackOff, 0 restarts ✅ |
| Execution | 2/2 COMPLETED ✅ |
| `published == projected` | 31 == 31 ✅ |
| Every enabled group cursor | +31 each, ending lag 0 ✅ |
| `ehdb_events_cursor_errors` | 0 ✅ |
| `ehdb_l0_out_of_order_appends` | 0 ✅ |
| Face liveness | all ten, read from inside the pod ✅ |
| SIGTERM seal | both hosts, 568 ms, zero loss, `clamped=false` ✅ |

**Held. P2 (soak) and P4 (IaC converge) await an explicit go.**
