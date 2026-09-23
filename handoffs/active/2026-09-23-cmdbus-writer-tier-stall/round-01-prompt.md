---
thread: 2026-09-23-cmdbus-writer-tier-stall
round: 1
from: claude
to: dispatcher-assigned
created: 2026-09-23T06:50:00Z
status: open
expects_result_at: round-01-result.md
tracks: noetl/ai-meta#351
wait_phrase: "ship the writer change"
---

# Land the worker-wiki page, then find what generates 19 cmd/min on an idle platform

> **Predecessor:** none. This is round 1, opened from the 2026-09-22 prod
> diagnosis recorded in [noetl/ai-meta#351](https://github.com/noetl/ai-meta/issues/351)
> and `memory/inbox/2026/09/20260922-193000-ehdb-tier-saturation-stalls-writer-server-and-ui.md`
> (ai-meta@02c5273).

Two deliverables. **Phase A is a blocked chore and takes ten minutes. Phase B
is the real work and is open-ended.** Do them in that order, because A is
finished work that is merely stuck and losing it would be waste.

A user reported "the travel service does not work" against the `team4.mestumre.dev`
UI on GKE `noetl-prod-autopilot` (project `shastaratech-noetl-prod`). Two
unrelated faults were found. One is fixed. The other was root-caused to the EHDB
tier service on `noetl-cmdbus-writer-0`, but the *source of its load* is still
unexplained, and that unknown is what decides the fix.

**Everything in the Background below is a measurement, not a conclusion — except
where marked "hypothesis". Re-verify anything you are about to act on.** The
prior session was wrong four times before it was right (it called the stall a
hang, then a cold cache, then CPU throttling, then a KEDA feedback loop); each
was killed by a cheap measurement. Prefer the same.

## Background

### Fixed already — do not re-investigate

`https://travel.mestumre.dev/login` was missing from the Auth0 application's
Allowed Callback URLs (client `Jqop7Yoa…`, tenant `mestumre-development.us.auth0.com`),
so `/authorize` returned 403 `unauthorized_client: Callback URL mismatch` and
nobody could log into the travel SPA. Added and verified 403 -> 302 on
2026-09-22. `team4`'s own callback (`.../chat`) was registered throughout and
was never affected. ⚠ The gateway's `GET /api/runtime/contract` still advertises
`redirect_uri: https://travel.mestumre.dev/login`; that is now correct again,
but note it is a hand-maintained copy.

### Root cause established — the EHDB tier service is saturated

`noetl-cmdbus-writer-0` (StatefulSet, worker image `6.1.6`) hosts the command
bus, the event bus and the tier service in one pod. From one `:9090/metrics`
scrape:

| `tier_service` op | count | mean | >1s | tail mean |
| :-- | --: | --: | --: | --: |
| `read_execution` | 7086 | 5.587s | 15.3% | ~36.4s |
| `append` | 2607 | 2.217s | 12.1% | ~18.1s |
| `append_batch` | 593 | 3.774s | 11.8% | ~31.8s |
| `scan` | 1 | 75.92s | 100% | 75.9s |
| `health` | 367 | **0.000376s** | 0% | — |

`health` at 0.38ms beside `read_execution` at 5.6s, same process and listener,
is the finding: the control path is instant, the data path is contended.
Connection outcomes against `NOETL_EHDB_TIER_MAX_INFLIGHT=4`
(`max_waiters=32`, `shed_after_ms=1000`): `accepted=10656`, `shed_busy=805`,
`shed_waiters_full=68`, `write_error=901` — 16.6% shed or failed.

**The coupling to everything else is the engine lock.** `:9102/metrics` samples
the durability window and takes it — the endpoint publishes
`ehdb_l0_durability_sample_ok` ("or could not acquire the engine lock (0)").
The server points `NOETL_COMMAND_BUS_WRITER_ADDRS` and
`NOETL_EVENT_BUS_WRITER_ADDRS` at this one pod, so a slow tier op stalls the
server's HTTP surface too — including `/api/auth/validate`, a Postgres lookup
that never touches the bus.

Proof, 20 paired back-to-back samples of `:9102/metrics` and gateway
`POST /api/auth/validate`:

```
17:07:17  writer=20.006*  gateway=51.311    <- stall
17:07:19 .. 17:07:42      19 rows: writer 0.20-1.53, gateway 0.39-1.43
17:09:04  writer=17.587   gateway=64.713    <- stall
```

`*` capped at `-m 20`. Zero disagreements. Different pods, so the link is
functional, not a shared node.

### Ruled out, with evidence — do not re-run these

| candidate | evidence against |
| :-- | :-- |
| Volume full (noetl/ehdb#345 recurrence) | `/data/cmdbus` 5%, `/data/eventbus` 24%, `/data/eventkv` 0%. ⚠ `df /data` measures the container overlay, **not** the PVCs — use the three mount points. |
| Cluster DNS | in-cluster probe `dns=0.005-0.010 conn=0.007-0.091`, all 200. `kubectl port-forward` reproduces the stall with no DNS in the path. |
| CFS CPU throttling | over 60s: `nr_periods +612`, `nr_throttled +6`, `throttled_usec +19.1ms`. |
| Cold cache / first-request cost | a block starting with a success then three failures; warm-up does not stick. |
| KEDA polls generating the load | with `autoscaling.keda.sh/paused=true`: CPU unchanged (0.92 -> 0.88 cores), stalls continued (59.5s observed). Scaler has since been unpaused. |
| Node pressure / server starvation | nodes 4-23% CPU, 9-19% memory; `noetl-server-rust-embedded-0` at 37m CPU / 25Mi against limits 2 cores / 1Gi. |
| System-pool liveness kills (noetl/ai-meta#322 shape) | `noetl-worker-system-pool-...-sfk8r` 1/1, 0 restarts, 6h51m. |

### The open question — this is Phase B

`ehdb_feed_subject_lag{subject="commands.shared.shard.0"}` was **0 in every
sample across the whole day**: no user-submitted work at all. Yet the system
pool received a steady stream. Two timestamped `:9102` scrapes 1h43m apart:

```
17:35:09   appends 4823   committed 109334   system lag 455
19:18:37   appends 6784   committed 111159   system lag 606

arrivals 0.3159/s = 19.0 cmd/min
drained  0.2940/s = 17.6 cmd/min
backlog accumulating 1.46 cmd/min      drain ratio 93.1%
```

So the shortfall is only **7.5%**, and backlog reaches 1000 in ~4.5h at that
rate. Meanwhile the writer burns **~0.9 cores continuously** (confirmed twice
via `cpu.stat` `usage_usec` deltas) with no user workload, and its RSS
oscillates in a 2485-3719 Mi band (it does **not** climb — an earlier
"memory climbing" claim in the issue body was corrected).

**Hypothesis, unconfirmed:** the ~19 cmd/min are self-generated re-drives, i.e.
[noetl/ai-meta#315](https://github.com/noetl/ai-meta/issues/315) — *"Reconcile
poller re-drives a permanently-stuck execution forever: no attempt cap, no
eviction, unbounded orch_cache growth"*. A perpetual re-drive loop would produce
exactly this: a command stream uncorrelated with users, that cannot converge.

**Why this gates the fix.** If the hypothesis holds, adding system-pool capacity
closes the 7.5% gap, stops the queue growing, and leaves the platform burning
19 cmd/min and ~0.9 cores forever on work with no terminal state — defect
intact, symptom no longer readable. That is the failure mode
`agents/rules/representation-drift.md` exists to prevent. Do not size a pool
before answering this.

### Access notes

- `noetl-worker-system-pool` and `noetl-worker-system-pool-shard1` carry
  **different `app` labels**; a selector on one misses the other.
- `noetl-cmdbus-writer-0`'s image has **no `curl`**. Use
  `kubectl port-forward` from your workstation, and re-establish the forward per
  sample — a backgrounded forward died mid-run three times in the prior session.
- Ports on the writer: 9100 cmdbus-ingest, 9101 cmdbus-claim, 9102 cmdbus-lag,
  9103 events-ingest, 9104 events-claim, 9105 events-sse, 9106 events-lag,
  9107 events-kv, 9108 events-wal, 9110 tier-service, 9090 worker metrics.

## Phases

### Phase A — land the worker-wiki page (blocked chore, ~10 min)

The page is **written, reviewed and committed** as `f4a41ea`; it could not be
pushed from the cloud session because GitHub does not expose `.wiki` as a
repository to its API, so the egress proxy will not authorize
`noetl/worker.wiki` and `add_repo` rejects it. Any workstation with normal
GitHub credentials can push it. This is required by
`agents/rules/change-documentation.md` (every change documented in its own
repo's wiki, not only centrally).

1. `git clone https://github.com/noetl/worker.wiki.git && cd worker.wiki`
2. `git am <path>/attachments/worker-wiki-f4a41ea.patch`
   (if `git am` conflicts, the new page is also attached standalone as
   `attachments/cmdbus-writer-tier-service.md`; the patch additionally edits
   `deployment-specification.md` — the `:9102` ports row and a writer-probe
   subsection under *Health probes* — plus `Home.md` and `_Sidebar.md`
   cross-links)
3. `git push`
4. Record the resulting wiki SHA in the result file.

No prod state is touched. Run unattended.

### Phase B — identify the source of the ~19 cmd/min (read-only)

5. Re-measure to confirm the rate still holds — two `:9102` scrapes ≥10 min
   apart, reading `ehdb_l0_appends`, `ehdb_feed_shard_committed` and
   **`ehdb_feed_subject_lag` per subject** (not the total; `commands.shared`
   and `commands.system` diverge and reading the total attributes the backlog
   to the wrong pool).
6. Determine what is producing them. Sample the command records or subjects and
   check **whether the same `execution_id`s recur**. Read the server's reconcile
   / re-drive counters and `orch_cache` size against noetl/ai-meta#315.
7. Answer, explicitly, in the result: **are these re-drives of stuck executions,
   or legitimate periodic system work (outbox publish, projection)?** Cite the
   evidence. "Probably" is not an answer — say what you measured.
8. Separately, characterise why `tier_service.read_execution` costs ~36s in its
   tail while `health` costs 0.38ms. `/data/eventbus` holds only ~76 MB of
   eventlog and ~29 MB of projection in the tier store, so this looks
   algorithmic or lock-related rather than volume-driven. `RUST_LOG=...,ehdb=debug`
   on the writer would give seal/append timings but **needs a restart** — treat
   that as a Phase C action, not a Phase B one.

Read-only. Run unattended.

### Phase C — mitigation

> ***Run only after explicit human go-ahead. Wait phrase: `ship the writer change`.***

9. Pick the lever **from Phase B's answer, not from the queue depth**:
   - re-drives -> the fix belongs with noetl/ai-meta#315; do not resize the pool.
   - legitimate work -> one additional system-pool replica closes a 7.5% gap;
     noetl/ai-meta#318 is the tracking issue. Note the tier ran at only ~41% of
     its inflight capacity on average, so the earlier worry that new workers
     would merely convert into `shed_busy` was overstated.
10. Any writer restart, `NOETL_EHDB_TIER_MAX_INFLIGHT` change, replica change or
    manifest apply is gated by this phase. `agents/rules/apply-safety.md`
    applies in full: **diff the whole rendered object against live before
    applying, never only the field you changed.** A targeted dry-run cost a
    55-minute outage on 2026-09-08.
11. ⚠ A restart is **not** a mitigation on its own: KEDA's failures spanned 18h
    while the pod was 6h59m old, so the fault already survived one restart, and
    `/data/eventbus` persists across restarts.

## Also worth raising (not this round's work)

- The writer's deployed probes are **TCP-only for liveness *and* readiness**, on
  `:9101` rather than any face that stalls. That is why an 18-hour degradation
  alerted nobody. Same class as noetl/ai-meta#322, worse instance. Phase A's page
  documents it; fixing it is a separate change.
- `ehdb_replica_survives_node_loss 0`, `ehdb_election_active 0`,
  `ehdb_election_epoch 0` — single point of failure, no independent replica, no
  fencing. Not this outage, but this pod took the product down when it degraded.
- Something is speaking HTTP to the binary tier port: `tier-service frame of
  1195725856 bytes exceeds the 1048576-byte cap`. `1195725856` = `0x47455420` =
  ASCII `"GET "`. Find what scrapes 9110.

## FINAL REPORT

Write the body of `round-01-result.md` with frontmatter:

```yaml
---
thread: 2026-09-23-cmdbus-writer-tier-stall
round: 1
from: <executor>
to: claude
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

One H2 per phase (A, B, C), plus `## Issues observed` and
`## Manual escalation needed`. Include grep-able fingerprints — real error
strings, exit codes, metric values with their as-of timestamps. Do not
paraphrase numbers; a rate with no interval is not evidence.

## Hard rules for this thread

- Never push to `origin/main` on any repo unless this prompt says so.
- Never force-push. Never merge PRs yourself.
- No prod mutation outside Phase C, and only after the wait phrase.
- Respect `AGENTS.md` and `agents/rules/` — in particular `apply-safety.md`,
  `representation-drift.md` and `change-documentation.md`.
- This repo is public: no tokens, credentials or customer data in any file.
- If preconditions are not met, stop and report. Do not improvise around
  blockers.
