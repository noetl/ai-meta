# EHDB-only kind soak — result, 2026-08-02

Local kind (`kind-noetl`, podman `noetl-dev`, arm64). No prod, no gcloud.

Images built locally because GHCR publishes server/gateway **amd64-only**:
`localhost/noetl-server-rust:ehdbonly` (server v3.60.2) and
`localhost/noetl-worker:h5209b` (worker v5.91.2 + the three fixes below).

## Verdict: PASS on every paired-evidence gate

```
fired=360  accepted=360  errors=0  dup_ids=0
published_delta=6840      projected_delta=6840          <- equal
group=noetl_materializer         committed_delta=6840  final_lag=0
group=noetl_result_materializer  committed_delta=6840  final_lag=0
group=noetl_state_materializer   committed_delta=6840  final_lag=0
cursor_errors=0
out_of_order_appends=0
unreadable_lag_reads=0
sse_subscriber_1 frames=7864
sse_subscriber_2 frames=7864
sse_subscriber_3 frames=7864
kv_ops_total=880 put=400 get=400 scan=20 delete=60 mismatch=0 err=0
kv_ops_per_s=2627.1  p50=13.40ms  p99=40.60ms
wal_established_conns=1
```

6 rounds x 60 executions @ concurrency 30. Every round drained to residual
lag 0 before the next began.

`published == projected == all three group cursors`, exactly, is the gate that
matters — it is the one that would have caught the two silent defects the NATS
deletion produced (`should_publish` falling through to synchronous
`insert_rows`, and the un-inventoried fourth WAL consumer). A green execution
count would have passed either of those.

`publish_errors` reads `NA` because the counter family is not rendered until
non-zero; it is cross-checked by `accepted == fired` and `errors=0`.

### SSE fan-out

Three concurrent subscribers, **identical** 7864 frames each. That is the
broadcast property — one subscriber cannot distinguish fan-out from a queue,
and competing-consumer behaviour would have shown as three unequal counts.

### KV face (:9107)

Exercised through the real wire protocol (4-byte BE length + tagged JSON) by
`kv-exercise.py`, over the two buckets the gateway actually uses. Values are
verified on read-back, not just status flags: **0 mismatches**. The gateway
itself is not in this rig, so without that client the face would have been
bound and idle — "bound" is not evidence.

## Writer restart

| | graceful (SIGTERM) | hard (SIGKILL, mid-burst) | hard (quiesce attempt) |
|---|---|---|---|
| fired / accepted | 120 / 120 | 120 / 120 | 200 |
| publish errors | 0 | 0 | 0 |
| tip at kill | 7781 (committed 7211, **lag 570**) | 8048 | 9188 |
| reopened tip | **7781** | 8053 | 9191 |
| unsealed tail lost | **0** | 0 (not resolvable) | -3 (not resolvable) |
| `resume_origin` | persisted | persisted | persisted |
| `resume_clamped` | **false** | false | false |
| `out_of_order_appends` | 0 | 0 | 0 |

**Graceful is a clean proof of the #209 fix.** `tip_at_kill == reopened_tip`
exactly, with 570 records sitting in the unsealed region at the moment of
SIGTERM. All 570 survived. `clamped=false` is ehdb's own corroboration: the
persisted cursor never outran the reopened log, so nothing had to be clamped
away.

### The hard-kill number could NOT be measured in kind, and why

Both hard kills report "no detectable loss", and that result should **not** be
read as "the crash exposure is closed". Two independent reasons:

1. **The measurement cannot resolve it.** `reopened_tip` came back *higher*
   than `tip_at_kill` (8053 > 8048; 9191 > 9188) — the sample is already stale
   by the time the kill lands, so the arithmetic cannot see a loss smaller than
   the sampling window's growth. The quiesced variant
   (`hard-kill-measure.sh`) was written to remove that ambiguity and could not:
   see below.

2. **The exposure is masked by consumption lag.** Under this backlog the
   committed cursor trails the tip by ~1100 records — *more* than
   `seal_max_records` (1024, the ceiling; observed cadence 20-140 records).
   Anything lost from an unsealed active part had
   therefore not been consumed yet, so the resumed cursor simply redelivers it
   and no loss is observable.

Point 2 has an uncomfortable corollary worth stating plainly: **a healthy,
low-backlog system is MORE exposed than this rig, not less.** The loss becomes
observable exactly when the consumption lag is *smaller* than the unsealed
window — which is the normal state of prod.

The precise bound therefore comes from the deterministic unit test in
`noetl/worker`, `tests/cmdbus_writer_graceful_shutdown.rs`:

- `sigterm_seals_the_active_part_with_no_acked_record_lost` — **300/300** survive.
- `without_the_seal_the_unsealed_tail_is_lost_the_hard_kill_exposure` —
  **0/300** survive. The entire unsealed active part is lost, bounded by
  `seal_max_records` = 1024 per shard. **That is the ceiling, not the typical
  case** — measured 2026-08-04, this writer's recent sealed parts hold 20-140
  records, so real exposure is tens, not ~1000 (noetl/ai-meta#209).

### Why the cluster would not quiesce

`noetl.command` on this kind cluster holds **229,982 rows spanning
2026-06-20 → 2026-08-03** — six weeks of prior test accumulation, pre-existing
and unrelated to this soak. On top of that, `ehdb_feed_shard_lag` is a
**whole-shard prefix cursor**: one command that is never acked pins it, and
every subsequent append grows the lag forever. That is the known
[ehdb#303](https://github.com/noetl/ehdb/issues/303) behaviour. Lag reached 0
after every soak round and only stopped doing so after the hard kills, which is
consistent with a kill-window command left unclaimable and pinning the cursor —
itself worth noting against #209.

Scaling the pools 3x did not drain it, confirming the growth is cursor pinning,
not capacity.

## Kind's ceiling — what this does and does not prove

**The bus was never the bottleneck.** Shard lag sat at 0 through every round
while the pool (2 replicas x `WORKER_MAX_CONCURRENT=4` = 8 slots) was the
limiter. This is the same reason
[#205](https://github.com/noetl/ai-meta/issues/205) could not be reproduced in
kind: a saturating burst here measures the worker pool, not the bus.

Proven: **correctness under concurrency** and **graceful-shutdown behaviour**.

Not proven, still requires the prod soak after gcloud re-auth:

- Bus throughput and dispatch latency at prod concurrency.
- The hard-kill unsealed-tail loss at prod's low consumption lag, where it is
  observable rather than masked.
- KV and SSE under the *gateway's* real traffic (sessions/requests from real
  logins), rather than a synthetic client.
- Whether `ehdb_events_cursor_errors` stays at 0 at prod event rates — it was 0
  here across 6840 events, but prod previously saw 26
  ([#216](https://github.com/noetl/ai-meta/issues/216)).

## Defects found

1. **[ehdb#311](https://github.com/noetl/ehdb/issues/311) — one malformed
   connection permanently kills the WAL fan-out face, silently.**
   `ehdb_feed::serve` handshakes *inside* its accept loop, so `read_frame(..)?`
   and `serde_json::from_slice(..)?` escape the whole function and drop the
   listener. Reproduced deterministically: listener present → one HTTP-shaped
   frame → listener gone, no log line, no restart. Found by my own soak probe.
   Worker-side mitigation shipped (every face now supervised and logs at ERROR
   when its accept loop ends); the real fix belongs in ehdb.

2. **`NOETL_STATE_BUILDER=shadow` silently means Off.** `builder_mode()` only
   recognises `offserver` on that variable and otherwise falls through to a
   *separate* flag (`NOETL_STATE_BUILDER_SHADOW`). A perfectly sensible-looking
   value therefore disables the drain, and :9108 never gets a client. Same
   silent-default class as H5 ([#221](https://github.com/noetl/ai-meta/issues/221)).

3. **No EHDB-only IaC exists.** `repos/ops` `origin/main` contains **zero**
   occurrences of `NOETL_COMMAND_BUS`. The prod topology was applied
   imperatively during the 2026-07-31/08-01 cutover and never written back,
   which is why this rig had to reconstruct it from source. Bigger than
   [ops#241](https://github.com/noetl/ops/pull/241), which that PR does not
   address.

## Harness bugs worth not repeating

Three of my own, all of which produced *false passes* before being caught —
the same failure shape the soak exists to detect:

- `GROUPS` is a bash special variable (the caller's Unix gids). Assigning to it
  is dropped, so the harness snapshotted `committed_399` / `lag_400` and every
  lag read returned `NA`, which the drain-wait coerced to 0 and "drained"
  instantly.
- A bare `wait` also waits on the port-forward and SSE background jobs, which
  never exit. Round 1 fired its first batch and then blocked forever, silently.
- Exact-matching a metric name fails on labelled series
  (`ehdb_feed_shard_resume_from{shard="0",origin="persisted"}`), returning `NA`
  — and an `NA` treated as a pass is exactly the thing being guarded against.

`NA` now counts as *not drained*, and the harness reports
`unreadable_lag_reads` so a blind poll cannot masquerade as a clean one.
