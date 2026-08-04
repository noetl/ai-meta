# The under-load writer-restart proof — worker v5.92.1, on prod

**Run 2026-08-04 07:04–07:15 UTC against `shastaratech-noetl-prod`.
noetl/ai-meta#226 and #225 are FIXED and proven on the real cluster under load.**

This is the caveat the fix session flagged — the in-process tests could not
reproduce the two-tokio-worker-thread starvation that produced #226 — and it is
the P4 precondition.

## What shipped

| | |
| :-- | :-- |
| ehdb | **`704a9bd`** ([ehdb#312](https://github.com/noetl/ehdb/pull/312), merge commit) |
| worker | **v5.92.1** ([worker#212](https://github.com/noetl/worker/pull/212), merged `abf9ca5`) |
| Deployed digest | `noetl-worker-rust@sha256:aee71e87e061ee81f3848a295f3e68dcbe77fda9369e50f32a06074bf21310f6` |
| amd64 child | `sha256:a0dd6a7ee5f069ba286d39068244eb94b4e0380f4881051558536887da08fabd` (AR == GHCR) |
| Rollback target | `sha256:ad1e96063bf53b44869deab2cd3afec0152b033bd7f28d528299db7b65781725` (v5.92.0) |
| Server / gateway | unchanged (v3.60.2 / v3.7.1) |

Two things needed fixing to get the release out:

- **ehdb#312 CI was red on `cargo fmt --all --check`** — `pub use kv::{…}` sat
  between `group` and `groups`. One line moved (`deeec55`), deliberately not a
  blanket `cargo fmt --all`, which reflows unrelated files across these crates.
- Then it went red on `crates/ehdb-feed/tests/latency.rs`: *"bus p99 94835 us is
  implausibly high"*. p50 was 589 µs and p90 1849 µs — healthy — and the test's
  own instrumentation reported posture-A fsync p99 at **122 ms on the runner
  FS**, which mechanically dominates a 94 ms bus p99. A re-run passed. Runner
  variance, not a regression.
- worker#212 pinned ehdb `211869c` (the pre-fmt PR head); all four ehdb crates
  were re-pinned together to `704a9bd` (`19190df`). 584 tests pass on the new
  rev.

**semantic-release cut v5.92.1 correctly** — it computes from the highest git
tag (v5.92.0), not from `Cargo.toml`, so noetl/ai-meta#224's version regression
did **not** bite. `verify-version` passed. `publish-ar` red as always
(noetl/ai-meta#211); crane is the path.

## The roll

Drain first. The bus could not be made fully quiet — 16 executions stalled from
earlier runs generate a steady ~1.2 rec/s via the guardrail
(noetl/ai-meta#227) — but `cmd_lag` returned to 0 repeatedly and events lag was
a static 0, so there was no unsealed backlog. Order: **writer → pools**, server
skipped (no new rev), `kubectl set image` (strategic; **never `--type merge`**),
container targeted **by name**. Nothing connected to `:9104`/`:9107`/`:9108`.

All pods came up on the new digest, 0 restarts, 0 CrashLoopBackOff.

> The first writer resume after the roll showed `clamped=true, stored=3747,
> tip=3103`. That is the **outgoing v5.92.0** writer's buggy shutdown — the
> expected, unavoidable residue of rolling off the broken image, not a failure
> of the new one. The events log tip had been pinned at 3103 since the 02:28
> incident for exactly this reason.

Post-roll synthetic execution: **COMPLETED**, `grp_committed 3103 → 3134`
(+31), durable events for that execution **31** — exact paired match, all lags
0, `cursor_errors` 0.

## THE PROOF — mid-burst graceful restart under load

30 executions submitted in 1.3 s; writer SIGTERMed 14 s later with backlog in
flight (`state_materializer` lag 53).

### #226 — both hosts seal, and the phasing is visible

```
07:09:00.324142  SIGTERM received
07:09:00.324373  sealing EHDB writer hosts before exit          hosts=2
07:09:00.324702  EHDB events ingest face stopped — listener closed
07:09:00.324788  EHDB command-bus ingest face stopped — listener closed
07:09:00.324927  EHDB command-bus ingest listener closed
07:09:00.324966  EHDB events-feed ingest listener closed
07:09:00.585552  EHDB command-bus cursor persisted on shutdown
07:09:00.585615  EHDB events-feed cursor persisted on shutdown
07:09:00.625070  EHDB command-bus log sealed on shutdown
07:09:00.640678  EHDB events-feed log sealed on shutdown
07:09:00.640814  EHDB writer hosts all sealed — shutdown complete  hosts=2
07:09:00.640843  Worker stopped
```

**316 ms for both hosts, under load.** The phases interleave across hosts —
both ingest faces stop, then both cursors persist, then both seal — which is
`graceful::seal_all` doing exactly what it was written to do. The new
`hosts all sealed — shutdown complete` line is the #226 observability, backed by
the `noetl_worker_shutdown_hosts_sealed` / `_total` gauges now exposed on
`:9090`.

Compare v5.92.0 under load, which stopped dead after host 1 with no events-feed
lines and no `Worker stopped`.

### The number that matters — the resume

```
noetl_materializer         stored_cursor=3329  tip=3330  from_cursor=3329  clamped=false  replay_records=1
noetl_result_materializer  stored_cursor=3330  tip=3331  from_cursor=3330  clamped=false  replay_records=1
command bus                resume_from=49939   tip=50015  stored=49939     clamped=false  replay_records=76
```

**`clamped=false`, and the tip is AHEAD of the persisted cursor** — the sealed
log retained everything and then some. That is the exact inverse of the v5.92.0
failure, where tip (3103) came back **390 below** stored (3493) with
`clamped=true`. `replay_records` 1 and 76 are at-least-once redelivery of
in-flight records, which is correct, not loss.

| | v5.92.0 under load | **v5.92.1 under load** |
| :-- | :-- | :-- |
| hosts sealed | 1 of 2 | **2 of 2** |
| events log on reopen | **390 below** cursor | **1 above** cursor |
| `clamped` | `true` | **`false`** |
| seal duration | n/a (never finished) | **316 ms** |

### #225 — consumers detect, redial, drain

```
noetl-worker-system-pool          client=6  writer_sees=6   ✅
noetl-worker-system-pool-shard1   client=6  writer_sees=6   ✅
```

No half-open sockets — the signature of the wedge (6 client-side vs 3
writer-side) is absent. The backlog drained on its own: `grp_committed`
3134 → 4083, ending **lag 0/0/0** with `cmd_lag 0`. No silent park, no manual
restart needed.

### Paired evidence

| Gate | Result | |
| :-- | :-- | :-- |
| Executions | **23 COMPLETED, 0 FAILED**, 7 stalled (see #227) | ⚠ |
| Duplicate event ids | **0** | ✅ |
| `ehdb_l0_out_of_order_appends` | **0** peak | ✅ |
| `ehdb_events_cursor_errors` | **0** across 435 s | ✅ |
| Every group cursor → lag 0 | yes, all three | ✅ |
| **Exposure `min(1024, lag)`** | **commands peak 245 / p99 219; events peak 326 / p99 297** | ✅ far under the 1024 cap |
| Hard-kill | **NOT run** — non-destructive bound only | ✅ |

KEDA scaled the user pool 2 → 13 on the backlog, which is the autoscaler
working as intended (Autopilot was still provisioning nodes for several).

## The one thing that is still wrong — noetl/ai-meta#227

Seven executions stalled in `RUNNING` and never recovered; flat event counts
across a 60 s re-sample. **This is not a #225/#226 failure** — nothing was lost,
nothing clamped, nothing parked. It is a drive/resume gap: an execution whose
in-flight command is interrupted by a writer restart does not get re-driven,
and the guardrail re-issues for it indefinitely (~2 rec/s on an idle cluster).

It predates this fix — the identical burst on v5.92.0 gave **19 COMPLETED / 2
FAILED / 9 stalled** — and it improved here (0 FAILED). Sixteen executions are
currently stalled on prod across the two runs and should be cleaned up.

## Verdict

**Deployed and under-load-validated.** The rollback criteria — any events-log
loss, any clamp, any silent park — were **all** clean, so no rollback.

**On the #225/#226 criteria, P4 is clear:** the writer-pod drop that P4b's
Deployment→StatefulSet handover performs is now proven survivable under load —
both logs seal, the reopened log loses nothing, and the consumers reattach on
their own.

The caveat to weigh before triggering P4 is **#227**: a converge taken with
executions in flight will likely strand some of them. It is not data loss and
not a topology risk, but a quiet window matters more than it did.

Rollback if ever needed:

```
kubectl -n noetl set image deploy/noetl-cmdbus-writer-0 noetl-worker=<v5.92.0 digest>
# then the three pools, container name noetl-worker on all of them
```
