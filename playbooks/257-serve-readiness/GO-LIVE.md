# EHDB event-log tier — go-live decision package

**One pass, one decision.** Everything below is either measured in kind or
named as an open precondition. Assembled 2026-08-12.

> **Nothing has been pushed, merged, deployed or flipped.** Six branches across
> two repos and five ai-meta commits are staged locally. Prod is untouched:
> `NOETL_EHDB_EVENTLOG=shadow`, no `NOETL_EHDB_TIER_*`, no
> `NOETL_EHDB_EVENTLOG_MIRROR_SOURCE` on any workload. GitHub is reachable —
> the writes are withheld by instruction, not by availability.

**The decision this document supports is not "flip the tier".** It is
*"push the stack and open the PRs"*. The flip is four preconditions further
out, three of them prod-side, and each needs its own explicit go.

---

## 1. What is being decided, in one paragraph

The EHDB event-log tier can serve reads authoritatively instead of
`noetl.event`. Getting there took four changes that no single build had ever
contained together: a cross-store comparator, a server-authored mirror that
puts the *whole* event set in the tier, a read path that resolves through the
writer instead of each pod's own fragment, and observability for the writer's
half. Composing them exposed a P0 — the flip was **inert and silent** on
exactly the configuration that makes the tier correct — which is now fixed and
measured. The tier is ready to be *reviewed and released*. It is not ready to
be promoted, and this document says precisely what stands between the two.

---

## 2. The six proven gates

All in kind (`kind-noetl`), on **built images**, never `cargo run`. Every arm
has a discriminating negative control or a mutation, because an all-green
bundle with no failing arm measures nothing.

| # | gate | headline | what it rules out |
| :-- | :-- | :-- | :-- |
| 1 | **#258 full-set mirror** | **13 == 13**, `match`, **21/0**. Flag-off arm: tier holds **6 of 12**, `unmirrored_by_design 6`, server counter **0** | The tier held 6 of 13 events per execution. The flag-off arm proves the match is attributable to the change, not to the images, probe or cluster |
| 2 | **#258 mutation** | dropping `command.issued` from `mirror_rows` → tier **11**, **2 divergences**, `divergent`, 15/0 | A comparator that agrees with whatever it finds |
| 3 | **#260 tier-service metrics** | `up` arm **41/0**; `off` arm **11/0** (all 20 request series + histograms + store gauges **absent**, `/metrics` 291 vs 403 lines); mutation **38/2** | A renderer emitting pinned zeros unconditionally. The `off` arm is what makes the zeros mean anything |
| 4 | **#257 PR 4 — multi-replica reads** | `local` arm at 3 replicas: **0 / 13 / 0** records for one execution, all labelled `local`; comparator `divergent / match / divergent`. `service` arm: **13 / 13 / 13**, `match` from every replica, **22/0** | The single-replica measurement behind gate 1. At 3 replicas it had a **1-in-3 chance** of reading the full set and declaring success. Prod runs multiple replicas |
| 5 | **#257 serve-readiness bundle** | `service` **45/0**; flip `primary` **49/0** — `served_primary` **+13**, `serve_state=served_primary` at the endpoint, one log line per transition; `killswitch` **23/0** — `served_primary` **+0** while `unavailable` **+23/+41**, comparator `ehdb_unavailable` from all three and **never** `match`; recovery re-promotes on a real append with **restarts=0**; rollback **45/0** | The P0 itself. Three independent surfaces, because run 1 had all three silent at once |
| 6 | **#257 P0 mutation** | reinstating the bypass → **47 passed, 2 failed**, and the two are *exactly* the serve assertions. Restoring returns **49/0** | The 47 that still pass are the point: 13/13 from all three replicas, one verdict, `holds: true`, `divergences 0`, incumbent 3/3. A bundle without the serve assertions would have reported 47 green checks about a flip that changed nothing — which is run 1's state verbatim |

Unit gate: **660 tests pass** (`cargo test --lib`), including an eight-
combination property test asserting the new serve site's verdict equals
`primary_serve::decide`, so the two sites cannot drift about what `primary`
means, and a guard that the pinned label set covers every outcome the site
records.

### The P0, in one sentence each

* **Defect** — `primary_serve::decide` had two call sites and the serve-ready
  configuration (`MIRROR_SOURCE=server` + `TIER_QUERY_SOURCE=service`) routed
  around **both**, so a flip produced `served_primary = 0` — in fact the whole
  metric family **absent** — with no log line, while 13 events per execution
  flowed and landed correctly.
* **Fix** — a third call site at the append chokepoint that configuration does
  reach, calling the same `decide` with the same three conditions.
* **Why it was invisible** — an absent metric family renders identically to a
  build with no serve path. The family is now **pinned at 0** on `shadow` *and*
  `primary`, so the flip changes values, never which series exist.

---

## 3. The remaining preconditions for a first prod flip

P0–P4 are engineering and satisfied or shippable. **P5–P9 are the gate**, and
three of them are prod-side or human.

| # | precondition | state |
| :-- | :-- | :-- |
| P0 | reachable serve path on the configuration being flipped | ✅ **closed** by worker `8d46b33`, measured on three surfaces |
| P1 | all four changes in **one** build, on server + worker pool + writer | ⛔ needs the merge + release below; no build has ever contained all four |
| P2 | `MIRROR_SOURCE=server` on **both** server and worker pool | ⛔ not set on prod. One side only ⇒ tier gets nothing, or every event lands twice |
| P3 | `TIER_QUERY_SOURCE=service` on **every** replica, at the writer's stable per-pod DNS | ⛔ not set on prod. Without it the tier is N disjoint fragments — gate 4 |
| P4 | writer exposes `:9110` with its store on a **PVC** | ⛔ [ops#255](https://github.com/noetl/ops/pull/255) open, not applied. Pod-local dir dies with the pod |
| **P5** | **comparator `divergences == 0` over a real prod soak**, sampled from **more than one replica**, with positive `match` verdicts | ⛔ **not started** |
| **P6** | **[ops#252](https://github.com/noetl/ops/pull/252) applied in a quiet window** (7 rules + the events scrape), and the scrape confirmed to actually *select* the pods | ⛔ open. ⚠ prod has **zero notification channels** ([#238](https://github.com/noetl/ai-meta/issues/238)) — a firing rule reaches nobody. Either add a channel or accept a human watching dashboards, **and say which** |
| **P7** | **single-replica-writer availability posture accepted in writing** | ⛔ RWO volumes, **no PodDisruptionBudget anywhere in namespace `noetl`**. Accepted position is that demote-to-incumbent *is* the availability mechanism; the PDB is the cheap item that should ship alongside |
| P8 | flip-time signal not stale | 🟡 **half done.** The serve state is logged on transition both ways. `warn_primary_not_wired` is still wrong on `MIRROR_SOURCE=worker` — [worker#263](https://github.com/noetl/worker/pull/263), open. Note it would **not** have fixed P0: the same disarm routes around both |
| **P9** | **explicit per-tier go**, naming the tier and the window, recorded on [#257](https://github.com/noetl/ai-meta/issues/257) | ⛔ **not given.** Do not generalise a go for one tier to another |

> ⚠ **P6 correction, 2026-08-12.** The runbook previously cited **ops#255** for
> monitoring. That is the wrong PR — ops#255 declares the writer's `:9110`
> face, which is **P4**. Monitoring is **ops#252**. Applying ops#255 and
> ticking P6 would leave the flip entirely unalerted.

### The ordered path from here

```
push the stack  →  merge bottom-up  →  release cuts a version carrying all four
   →  deploy that version to prod (image only, no flag)          [P1]
   →  set MIRROR_SOURCE=server + TIER_QUERY_SOURCE=service       [P2, P3]
      + apply ops#255 for the writer's :9110 on a PVC            [P4]
   →  enable the comparator, soak, divergences == 0 from >1 replica  [P5]
   →  apply ops#252 in a quiet window, confirm the scrape selects     [P6]
   →  write down the availability posture                             [P7]
   →  explicit per-tier go                                            [P9]
   →  ONLY THEN: NOETL_EHDB_EVENTLOG=primary
```

Each arrow is a separate decision. **Never move the image and the flag in the
same step** — a regression would have two candidate causes and no way to
separate them.

---

## 4. The flip, and the rehearsed rollback

**Flip** — one variable, one workload, one tier:

```bash
kubectl -n noetl set env deploy/noetl-worker-rust NOETL_EHDB_EVENTLOG=primary
kubectl -n noetl rollout status deploy/noetl-worker-rust --timeout=300s
```

**Rollback** — one command, symmetric, no image change, no data migration:

```bash
kubectl -n noetl set env deploy/noetl-worker-rust NOETL_EHDB_EVENTLOG=shadow
kubectl -n noetl rollout status deploy/noetl-worker-rust --timeout=300s
```

Rehearsed in kind: the post-rollback `service` arm returned **45 passed, 0
failed** on the same cluster — 19/19 from all three replicas, one `match`,
`divergences: 0`, fresh pods pinning `served_primary` at 0 while `mirrored`
moves.

**It is safe because `primary` only ever appends, and the incumbent
(`noetl.event`) keeps receiving the complete event set throughout.** Measured,
not asserted: 3/3 executions reached `playbook.completed` with
`command.issued == command.completed` during the primary window, and 3/3 again
through the tier-service outage.

After rolling back, **leave `MIRROR_SOURCE=server` and
`TIER_QUERY_SOURCE=service` in place** — they are not part of the flip, and
reverting them would undo the full-set mirror and re-fragment the tier.

Abort triggers, from the watch table (RUNBOOK §3): any
`outcome="primary_divergence"`; comparator `divergent`; any shortfall in the
incumbent's completeness. `served_primary` **flat at 0 on every replica while
events flow** ⇒ roll back and do **not** flip again — that is P0's signature.

---

## 5. Two operational cautions

**(a) A writer roll can redeliver an in-flight command to a non-idempotent
step.** Observed for real on 2026-08-11: the 22:00 `system/scheduled_cleanup`
completed normally at 22:00:05, then its `end` step **ran again in full** at
22:00:33 — a 30.3 s gap against `NOETL_COMMAND_BUS_ACK_WAIT_SECS = 30`. An ack
was lost to the restart and the command was redelivered. At-least-once working
as designed, harmless for an idempotent step; **any writer roll can do this to
a non-idempotent one.** Rolling the writer last and on its own is right but
insufficient — also roll it **when the system is quiet**.

Corollary from the same roll: *a single slow execution right after a roll is
not a regression signal.* The mid-roll smoke took ~4 minutes; the same pods,
settled, took 7 s. Re-run before concluding anything.

**(b) The flip is event-log-only, because it is the only wired tier.** `kv`,
`object`, `projection` and `vector` each have a `serve_primary_cycle` whose
only caller is `bin/ehdb-selfcheck` — setting any of them to `primary` changes
nothing a caller can observe. The RFC's suggested order (KV first, event log
last) describes a blast-radius *intent*; as wired, the event log is the only
flip available. Do not read a green event-log flip as evidence about any other
tier.

---

## 6. Reading rules that cost a rehearsal each

* **Absent ≠ zero.** `Registry::gather` prunes empty metric families, so a
  labelled series does not exist until it fires. "Family absent" and "family at
  zero" mean different things — one is *no serve path*, the other is *no
  traffic*. `noetl_worker_build_info{version}` answers which.
* **`unknown` is a real answer.** The server's mirror hop resolves the pool's
  ClusterIP Service, so a replica that received none of an execution's appends
  has decided nothing. That is **not** `not_primary`.
* **A self-reported provenance label is not evidence.** A defect kept
  `tier_query_source: service` truthful-looking while serving the pod-local
  store. Compare **counts**, not labels.
* **Ask reachability, not existence.** `primary_serve::decide` existed, was
  registered, was tested and was documented while the serve-ready configuration
  reached neither of its call sites.
* **Read the original, not the copy.** Execution status comes from the event
  log; `noetl.execution.status` is a frozen Python-era column nothing in the
  Rust path writes ([#235](https://github.com/noetl/ai-meta/issues/235)) and
  has already caused one false-alarm abort.
* **`kubectl scale` does not hold** where a KEDA ScaledObject carries
  `autoscaling.keda.sh/paused-replicas` — it reverts within seconds, and a
  0-replica Deployment reports *"successfully rolled out"*. Assert
  `readyReplicas`.

---

## 7. Related

* `RUNBOOK.md` — the cutover procedure, P0–P9 in full, the watch table.
* `RESULTS.md` — the evidence bundle, both runs.
* `MERGE-ORDER.md` — the verified merge sequence and the push script.
* `../258-full-set-mirror/RESULTS.md`, `../260-tier-service-metrics/RESULTS.md`,
  `../261-tier-query-service/RESULTS.md` — gates 1–4.
* `../257-worker-5115-noop-roll/README.md` — caution (a), as observed.
* `docs/rfc/ehdb-primary-serve-path.md` §3.4 — cutover shape, wired-tier
  correction.
* `docs/rfc/ehdb-primary-serve-availability.md` — open question 2, the
  single-writer posture behind P7.
