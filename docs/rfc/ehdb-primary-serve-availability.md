# Availability of the writer-fronted tier service — RFC #257 open question 2

**Status: decision brief. Nothing here has been executed.**
Written 2026-08-11 for [ai-meta#257](https://github.com/noetl/ai-meta/issues/257)
open question 2, which the RFC deferred with a provisional "accept it, revisit
before PR 5". PR 5 has landed, so it is now due.

> **The question.** The writer is `replicas: 1`. Fronting tier reads there puts
> the EHDB serve path behind a single pod. Accept it, make the writer HA, or
> fan out to read replicas?

**Recommendation: accept `replicas: 1`, and treat demote-to-incumbent as the
availability mechanism rather than a consolation prize.** Reasoning in §3;
the three things that would change this answer are in §5.

---

## 1. What is actually behind that pod today

Measured read-only on `shastaratech-noetl-prod`, 2026-08-11:

| face | port | who depends on it | fallback if the writer is gone |
| :-- | :-- | :-- | :-- |
| cmdbus ingest / claim / lag | 9100–9102 | server dispatch, both worker pools, the KEDA scaler | **none** — dispatch stops |
| events ingest / claim / lag | 9103, 9104, 9106 | event feed, materializer | **none** |
| events SSE | 9105 | gateway → browser live updates | **none** |
| KV | 9107 | **gateway session cache + request store** | **none** |
| WAL fan-out | 9108 | off-server state builder | **none** |
| *tier service (proposed)* | *9110* | *EHDB tiers in `primary`* | **the incumbent store** |

Supporting facts, all verified rather than assumed:

- `sts/noetl-cmdbus-writer` — 1 replica, `restartCount 0`, pod created
  2026-08-10T21:42:37Z.
- All four writer PVCs are `ReadWriteOnce` on `premium-rwo`. **A second replica
  cannot mount the same volume.** This is not a policy choice to revisit; it is
  the storage class.
- **No PodDisruptionBudget exists in namespace `noetl`** — for any workload.
- Prod runs GKE **Autopilot**, so node upgrades and bin-packing evictions are
  not fully under our control.

The last row of the table is the entire argument. Every existing dependency on
the writer is **unconditional**: if the pod is gone, that function stops. The
tier serve path is the **only** one with a working degraded mode —
`primary_serve::decide` returns `ServedByIncumbent { NoDurableService }` and the
caller is served correctly by the store that has all the history.

So the marginal availability cost of adding `:9110` is not "one more thing
behind a SPOF". It is **zero new unavailability**, because the failure it
introduces is already handled, by design, in the one component being added.

## 2. The options

### A. Leave `replicas: 1`; rely on demote-to-incumbent

Add the face, flip a tier, and accept that a writer outage means the tier stops
serving and the incumbent answers.

- **Cost of a writer outage, tier-wise:** one operation pays the client timeout
  (`NOETL_EHDB_TIER_SERVICE_TIMEOUT_MS`, default 2000 ms) and is then served by
  the incumbent — slower, not wrong. Every subsequent operation demotes
  immediately.
- **Recovery:** belief is restored only by a real successful operation, not by a
  clock ([worker#262](https://github.com/noetl/worker/pull/262) fixed the
  timer-based version, where five seconds of silence restored authority with
  nothing having been contacted).
- **What it does not fix:** the writer is still a SPOF for dispatch, SSE and the
  gateway's KV. That problem exists today and is untouched either way.

### B. Make the writer HA

- **Blocked on storage.** RWO means a second replica of the same shard cannot
  mount the log. Real HA needs either a shared RWX filesystem (Filestore —
  changing a live StatefulSet's storage class, and making concurrent writers a
  *correctness* problem, which §3.2 of the RFC already rejected) or a
  leader-elected pair with fencing, which is a distributed-systems project, not
  a manifest change.
- **Mis-shaped for the trigger.** Doing this *because of the tier service* means
  the least critical consumer justifies the largest infrastructure change, while
  the genuinely unprotected consumers (dispatch, SSE, KV) get it as a side
  effect. If writer HA is worth building — and eventually it is — it should be
  driven by the SSE/KV/dispatch exposure and scoped as its own program.

### C. Read-replica fan-out for tier reads

- **Premature.** There is no measured read load: no tier is `primary` anywhere,
  and the address is set nowhere. Sizing replicas against zero traffic is
  guesswork.
- **Adds a correctness surface.** A replica serving a stale segment while
  claiming to be authoritative is precisely the pod-local-fragment failure the
  writer-fronted design exists to eliminate. Replication lag would have to
  become an input to `decide()`.
- Reasonable **later**, once reads exist to measure and one tier has been
  primary long enough to know the access pattern.

## 3. Recommendation

**Take A now. Do not let it stand in for B.**

1. **The added risk is genuinely near zero.** Demote-to-incumbent is not a
   fallback bolted on for this decision — it is the safety property PR 5 was
   built around, and the PR-7 drill measured the incumbent receiving the
   complete event set throughout a primary window (37/37 executions, 13 events
   each). A writer outage costs one timeout and then costs nothing.
2. **The single-writer problem is real but is not this problem.** Fixing it
   properly means RWX or leader election plus fencing. Attaching that to the
   tier-service PR would block a reversible, verifiable change behind an
   unscoped one.
3. **A flip is reversible in a way HA work is not.** If A turns out to be wrong,
   the tier goes back to `shadow` with one env var. Nothing is stranded.

### Do these three alongside A — they are cheap and they are the actual gaps

- **Add a PodDisruptionBudget for the writer** (`minAvailable: 1`). There is
  none, for any workload. It will not survive a node deletion, but it stops
  voluntary evictions and Autopilot consolidation from taking the pod at an
  arbitrary moment. This is the highest-value item on the page and it is one
  manifest.
- **Alert on writer absence.** Prod had zero alerting until recently
  ([#238](https://github.com/noetl/ai-meta/issues/238)) and there is still no
  notification channel, so a firing rule reaches nobody. The `build_info` gauge
  makes "the writer is not running" expressible.
- **Instrument the tier service before flipping.** `src/ehdb/tier_service.rs`
  records **no metrics at all** — four `tracing` lines, three of them on failure
  paths. The serve path's *client* half is instrumented; its *server* half is
  invisible. Flipping a tier whose authoritative store cannot be observed is the
  same class of mistake as trusting a description that nothing forces to be
  true.

## 4. What this does not authorise

Accepting A is a decision about **availability posture**, not about flipping.
No tier goes `primary` until the cross-store comparator produces real parity
evidence against the authoritative log
([#258](https://github.com/noetl/ai-meta/issues/258)) **and** there is an
explicit per-tier go.

## 5. What would change this answer

- The writer starts restarting on its own (it is at `restartCount 0` today), or
  Autopilot begins evicting it — then the SPOF is live rather than theoretical
  and B gets promoted on its own merits.
- Tier reads land on a latency-sensitive path where one 2-second timeout per
  outage is not acceptable. Nothing proposed today is.
- The event-log tier goes primary *and* becomes the read path for replay, at
  which point "the incumbent answers" stops being a complete fallback.
