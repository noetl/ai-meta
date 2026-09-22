# EHDB tier saturation stalls the writer, the server and the UI

- Timestamp: 2026-09-22T19:30:00Z
- Author: Claude
- Tags: ehdb,tier-service,cmdbus-writer,prod,latency,auth0,351,315,318,322,344

## Summary

Reported as "the travel service does not work" against the `team4.mestumre.dev`
UI on `noetl-prod-autopilot`. Two unrelated faults.

**1. Auth0 callback drift (fixed).** `https://travel.mestumre.dev/login` was not
in the Auth0 application's Allowed Callback URLs — `/authorize` returned 403
`unauthorized_client: Callback URL mismatch`. Nobody could log into the travel
SPA at all. The gateway's `GET /api/runtime/contract` still advertised that dead
`redirect_uri`. Added to the allowlist and verified: 403 -> 302. `team4`'s own
callback (`/chat`) was registered throughout, so this was never team4's problem.

**2. EHDB tier saturation (root cause, open as noetl/ai-meta#351).**
`noetl-cmdbus-writer-0` enters stall windows of tens of seconds during which
every face it serves stops answering. The server points **both** its command bus
and event bus at that one pod, so the server's whole HTTP surface stalls with
it — including `/api/auth/validate`, a Postgres lookup that never touches the
bus. Hence the hanging UI.

**The measurement that identified it**, all from one `:9090/metrics` scrape:

| tier op | count | mean | >1s | tail mean |
| :-- | --: | --: | --: | --: |
| `read_execution` | 7086 | 5.587s | 15.3% | **~36.4s** |
| `append` | 2607 | 2.217s | 12.1% | ~18.1s |
| `append_batch` | 593 | 3.774s | 11.8% | ~31.8s |
| `scan` | 1 | **75.92s** | 100% | 75.9s |
| `health` | 367 | **0.000376s** | 0% | — |

`health` at 0.38ms against `read_execution` at 5.6s, same process, same
listener, kills every "sick pod / deaf process" theory: the control path is
instant, the data path is not. 16.6% of tier connections are shed or fail
(`shed_busy` 805, `shed_waiters_full` 68, `write_error` 901 of 10656 accepted)
against `NOETL_EHDB_TIER_MAX_INFLIGHT=4`.

The coupling is the engine lock: `:9102/metrics` publishes
`ehdb_l0_durability_sample_ok` — *"or could not acquire the engine lock (0)"* —
so the lag endpoint takes that lock, and blocks behind a 36s read or a 76s scan.
That is what KEDA reports as "headers never arrived" (4,789 failures over 18h,
3s timeout, 10s poll), and what the server's bus calls queue behind.

**Proof of the coupling:** 20 paired samples of `:9102/metrics` and gateway
`POST /api/auth/validate`, back to back. Slow rows coincided exactly
(writer 20.0s / gateway 51.3s; writer 17.6s / gateway 64.7s), fast rows likewise
(19 rows, writer 0.20-1.53s, gateway 0.39-1.43s). Zero disagreements. Different
pods, so the link is functional, not a shared node.

**Measured rates** (two timestamped scrapes, 1h43m apart): arrivals 19.0
cmd/min, drained 17.6 cmd/min, backlog accumulating 1.46 cmd/min (455 -> 606),
drain ratio 93.1%. Only a 7.5% shortfall.

## Actions

- **Open question, and the one that matters:** `commands.shared.shard.0` has
  been **0 all day** — zero user work — yet the system pool takes **19
  commands/min continuously**. ~1,140/hour that the platform generates for
  itself. Fits noetl/ai-meta#315 (reconcile poller re-drives a stuck execution
  forever, no attempt cap, no eviction). **If that is the source, adding
  capacity is the wrong fix** — it closes the 7.5% gap and leaves the platform
  permanently burning 19 cmd/min and ~0.9 cores on work with no terminal state,
  with the defect intact and the symptom no longer readable.
- Before any pool sizing: check whether the same execution ids recur in those
  commands, and read the server's reconcile counters / `orch_cache` size.
- Fix list on #351: make the lag metric a cheap gauge read off its own path;
  make the expensive handler cancellation-aware; bounded timeout on the server's
  bus calls so a tier stall degrades dispatch instead of taking `/api/health`
  down; HTTP probes replacing the TCP-only pair on 9101.
- Latent risk surfaced in passing: `ehdb_replica_survives_node_loss 0`,
  `ehdb_election_active 0`, `ehdb_election_epoch 0`. Single point of failure,
  no independent replica, no fencing.

## Repos

- noetl/ai-meta — issue #351 filed (`ai-task`, `bug`, `repo:worker`,
  `repo:ehdb`), three follow-up comments carrying corrections.
- noetl/worker — `noetl_worker::ehdb::tier_service` is where the read latency
  lives. Writer running worker **6.1.6**; gateway **3.12.1** (repo HEAD 3.12.2).

## Related

- noetl/ai-meta#315 — reconcile re-drive; the likely source of the 19 cmd/min.
- noetl/ai-meta#318 — system pool fixed capacity, no autoscaler. Now measured,
  not theoretical: 606 commands queued.
- noetl/ai-meta#322 — TCP readiness weaker than liveness. Same class; here
  **both** probes are TCP-only on 9101, on a pod carrying both buses.
- noetl/ai-meta#343, #344 — tier frame cap and un-batched fan-out.
- noetl/ehdb#345 — the 2026-09-01 disk-full incident. Ruled out this time.

## Lessons worth not relearning

- **A denominator-free latency check lies both ways.** Curling the endpoint
  twice showed 0.2s and looked healthy; the first call had paid 38s and warmed
  it. Nineteen samples were taken before anyone read the response **body**, and
  the body is what named the mechanism in one scrape.
- **Pair the suspect metric with a control on the same process.** `health` at
  0.38ms next to `read_execution` at 5.6s did in a single line what six
  black-box hypotheses could not. Four were wrong before that: a hang, a cold
  cache, CPU throttling, and a KEDA feedback loop — each plausible, each killed
  by a measurement that cost seconds.
- **Check which label the autoscaler actually reads.** Hours were spent on
  `noetl-worker-rust` being "pinned at fallback 2" before the subject-level lag
  showed `shared`=0 and `system`=606. It was never the pool in trouble.
- **`df /data` measures the overlay, not the PVCs.** The mounts are
  `/data/cmdbus`, `/data/eventbus`, `/data/eventkv`. A wrong path produced a
  confident, irrelevant 13%.
- **A restart that already failed is not a mitigation.** KEDA's failures spanned
  18h while the pod was 6h59m old — the fault had already survived one restart
  before anyone proposed restarting.
- **Memory read once is a level, not a trend.** 2485 -> 3719 Mi was written up
  as "climbing ~1.2 GB in 40 min"; the next sample was 2667 Mi. It oscillates.
  The correction moved the hypothesis toward buffer-and-flush, which was right.
