# Cutover runbook — promoting the EHDB **event-log** tier to `primary`

RFC [ai-meta#257](https://github.com/noetl/ai-meta/issues/257) **PR 7**.
Rehearsed in kind on the composed stack, 2026-08-12 (`RESULTS.md`).

> **This runbook documents the flip. It does not perform it.**
> Every prod step below is gated on an explicit, per-tier human go. Nothing in
> this session touched prod, and no tier is `primary` anywhere.

> **Update 2026-08-12 (second session).** P0 — the hard blocker — is **closed**
> by worker `8d46b33`. The flip now reaches the serve path on the serve-ready
> configuration, and is observable on three independent surfaces. The remaining
> preconditions P1–P9 are unchanged and none of them is satisfied by that fix;
> P5, P6 and P9 are still prod-side and open.

---

## 0. Scope

**One tier: the event log.** It is the only tier with a runtime serve path.
`kv`, `object`, `projection` and `vector` each have a `serve_primary_cycle`
whose only caller is `bin/ehdb-selfcheck`, so setting them to `primary` changes
nothing a caller can observe — see the 2026-08-11 correction in RFC §3.4. The
suggested order in that section (KV first, event log last) describes a
blast-radius *intent*; as wired, the event log is the only flip available.

**The safety argument, in one line:** `primary` only ever **appends**, and the
incumbent (`noetl.event`) keeps receiving the complete event set throughout, so
rollback loses nothing. That is measured, not asserted — §5, 3/3 executions.

---

## 1. Preconditions

Every one of these is a **hard gate**. Each row says how to check it, because a
precondition nobody can verify is a wish.

### P0 — the flip must have a reachable serve path *on the configuration you are flipping*

**Satisfied as of worker `8d46b33` (2026-08-12).** It was the blocker, and the
history matters because the check below is the one that caught it.

The defect: `primary_serve::decide` had exactly two runtime call sites, and the
target configuration (`NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=server` +
`NOETL_EHDB_TIER_QUERY_SOURCE=service`) routed around **both**.

| call site | why it was not reached |
| :-- | :-- |
| `eventlog::mirror_live_event` (the worker's own hook) | `MIRROR_SOURCE=server` disarms the hook in `client/control_plane.rs` *before* the tier mode is consulted, so `runtime_hook_env` — the only caller of the flip-time signal — never runs |
| `metrics_server::ehdb_tier_append_handler`, `Resolution::Local` branch | `TIER_QUERY_SOURCE=service` takes the `Resolution::Service(client)` branch, which calls `client.append()` and never enters `mirror_event` |

So a flip produced `served_primary = 0` on every replica — in fact the whole
`noetl_ehdb_eventlog_ops_total` family was **absent** — with no log line, while
13 events per execution flowed and landed correctly. Neither of those two
changes was wrong on its own; the gap existed only in their composition, which
is why only a composed gate could find it.

The fix adds the third call site, at the append chokepoint that configuration
does reach, calling the same `decide` with the same three conditions.

**Verify before flipping.** Three readings, because the defect silenced all
three at once. All three must hold, from more than one replica:

```bash
# 1. the serve series must be PRESENT (pinned at 0 before traffic, > 0 after)
kubectl -n noetl exec <writer-pod> -- sh -c \
  "wget -q -O - http://<worker-pod-ip>:9090/metrics" \
  | grep '^noetl_ehdb_eventlog_ops_total'

# 2. the endpoint must say so — this cannot be "absent" the way a metric can
kubectl -n noetl exec <writer-pod> -- sh -c \
  "wget -q -O - 'http://<worker-pod-ip>:9090/ehdb/tiers/eventlog?execution=<id>'" \
  | jq -r '.serve_state'      # served_primary

# 3. the log line, once per transition, on the pods that served
kubectl -n noetl logs <worker-pod> | grep -E 'IS SERVING|is NOT serving'
```

Reading rules:

* **An absent family is not a zero.** Before this fix the family was absent,
  which is the same bytes as a build that has no serve path. It is now pinned:
  `served_primary 0` means "did not serve", nothing means "this binary predates
  the metric" — and `noetl_worker_build_info{version}` answers which.
* **`unknown` is a real answer.** The server's mirror hop resolves the pool's
  ClusterIP Service, so a replica that received none of an execution's appends
  has decided nothing. That is not `not_primary` and must not be read as one.
  Expect `served_primary` on the replicas that received appends and `unknown` on
  the rest; in the rehearsal that was 1–2 of 3 per execution.
* **Do not read the serve state as parity.** It is the tier's authority to
  answer. Cross-store parity against `noetl.event` is row 4 of §3.

### P1 — the composed stack is deployed everywhere it needs to be

Comparator + server-authored mirror + tier-service metrics + tier-query-service
must be in **one** build, on **server**, the **worker pool**, and the **writer**.
Before this session no build contained all four: `feat/260-tier-service-metrics`
and `feat/257-pr4-tier-query-service` were separate lineages off v5.115.3.

```bash
curl -s $SERVER/metrics       | grep '^noetl_server_build_info'
# and per worker/writer pod:
                                grep '^noetl_worker_build_info'
```

Match the version against the release that carries all four. The build-info
gauge exists precisely so "is this pod too old to have metric X?" is answerable
without reading a Deployment's image tag — a different representation, and one
that can disagree with what is running.

### P2 — server-authored mirroring on both ends

`NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=server` on the **server** *and* on the
**worker pool**. Set on only one side and either the tier gets nothing (worker
disarmed, server not mirroring) or every event lands twice.

Signal that it took, on each worker at startup:

```
NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=server — the worker's event-log mirror is
disarmed; the server's write chokepoint mirrors the full authoritative set
```

### P3 — every replica resolves reads through the writer

`NOETL_EHDB_TIER_QUERY_SOURCE=service` on **every** worker replica, with
`NOETL_EHDB_TIER_SERVICE_ADDR` at the writer's **stable per-pod DNS**
(`noetl-cmdbus-writer-0.noetl.svc.cluster.local:9110`), never the headless
Service — that round-robins, and the premise is one process.

Without this the tier is N disjoint pod-local fragments. The PR-4 gate measured
one execution answered three different ways at three replicas (0 / 13 / 0
records) with the identical `local` label on all three.

Verify on the reply, not on the env:

```bash
… /ehdb/tiers/eventlog?execution=<id> | jq -r '.tier_query_source'   # "service"
```

⚠ **The label alone is not evidence.** A defect can keep `source: service`
truthful-looking while serving the pod-local store — that mutation passed the
label check and failed only the data checks. Compare counts, not labels.

### P4 — the writer exposes the tier face, with its store on the PVC

`NOETL_EHDB_TIER_SERVICE_BIND=0.0.0.0:9110` and
`NOETL_EHDB_TIER_SERVICE_DIR` on a **PVC path**. The durable dir is pod-local by
default; without a volume the store dies with the pod.

The manifest half of this is [ops#255](https://github.com/noetl/ops/pull/255)
(*declare the writer's tier-service face (:9110), default OFF*), open and not
applied. It is a **port declaration**, not monitoring — see P6.

### P5 — comparator divergence == 0 over a real prod soak

`NOETL_EHDB_CROSSSTORE_PARITY_ENABLED=true`, then over the soak window:

* `unmirrored_by_design == 0`,
* `matched == authoritative_count` on healthy executions,
* zero `divergences`,
* **sampled from more than one replica** — a single-replica sample had a
  1-in-3 chance of reading the full set and declaring success.

A soak that produced no `divergent` verdict *and* no `match` verdict has
measured nothing; require positive matches.

### P6 — monitoring applied, during a quiet window

[ops#252](https://github.com/noetl/ops/pull/252) (7 rules + the events scrape)
applied. ⚠ **corrected 2026-08-12**: this line previously cited **ops#255**,
which is a different PR — *"declare the writer's tier-service face (:9110),
default OFF"*, the manifest half of **P4**, not monitoring. Both are needed and
they are not interchangeable: applying ops#255 and ticking P6 would leave the
flip entirely unalerted. Every other reference in these playbooks uses ops#255
correctly; this row was the only one wrong.

⚠ **Prod has zero notification channels**
([#238](https://github.com/noetl/ai-meta/issues/238)) — a firing rule reaches
nobody. Either add a channel or accept that the flip is watched by a human
looking at dashboards, and say which.

Also confirm the scrape actually **selects** the pods. An enumerated selector is
itself a representation: `podmonitoring-noetl.yaml` once listed four worker
`app` names, two of which never existed, and omitted the live #166 shard.

### P7 — availability posture accepted, in writing

Single-replica writer, RWO volumes, **no PodDisruptionBudget anywhere in
namespace `noetl`**. The accepted position
(`docs/rfc/ehdb-primary-serve-availability.md`) is that demote-to-incumbent is
the availability mechanism: the tier is the only writer face with a working
fallback. Adding the PDB is the cheap item that should ship alongside.

### P8 — the flip-time signal is not stale

Two separate signals, and only one of them is now handled.

**Handled.** On the serve-ready configuration the serve state is logged on
transition, in both directions, by the site P0 added:

```
NOETL_EHDB_EVENTLOG=primary IS SERVING: the event-log tier answered
authoritatively through the writer-fronted tier service
    serve_state="served_primary" outcome="served_primary"

NOETL_EHDB_EVENTLOG=primary is NOT serving — the incumbent answers
(demoted: no_durable_service)
    serve_state="no_durable_service" outcome="unavailable"
    detail="tier-service append failed: connect: Connection refused (os error 111)"
```

Transition-only is deliberate: an append happens 13 times per execution, and a
line on every one is a line nobody reads — which is operationally the same as no
line, the state P0 was found in.

**Still open.** `warn_primary_not_wired` predates PRs 5/6 and tells an operator
that `primary` did nothing, on a build that serves. It fires from
`runtime_hook_env`, which is reached only on `MIRROR_SOURCE=worker` — so it is
*unreachable on the serve-ready configuration* and cannot mislead there, but it
is still wrong on the other one. worker `fix/259-primary-flip-signal` is open as
**[worker#263](https://github.com/noetl/worker/pull/263)** (*"the flip-time
signal must describe the tier it fires for"*) — a PR, not just a pushed branch —
and replaces it with three distinct conditions
(`primary_not_wired` / `primary_no_tier_service` / `primary_armed`). Land it, and
note that landing it alone would **not** have fixed P0 — the same disarm that
routes around the serve decision routes around that warning.

### P9 — explicit per-tier go

Recorded on [ai-meta#257](https://github.com/noetl/ai-meta/issues/257), naming
the tier and the window. Do not generalise a go for one tier to another.

---

## 2. The flip

One variable, one workload, one tier.

```bash
kubectl -n noetl set env deploy/noetl-worker-rust NOETL_EHDB_EVENTLOG=primary
kubectl -n noetl rollout status deploy/noetl-worker-rust --timeout=300s
```

Notes that cost a rehearsal to learn:

* **The roll gives every replica a new pod IP.** Anything pinned at an old one —
  a relay URL, a scrape target, a probe — is now aimed at a dead pod, and the
  comparator will correctly answer `ehdb_unavailable` for a reason that has
  nothing to do with the flip. Reset relay pins after the roll.
* **`kubectl scale` does not hold a replica count** where a KEDA ScaledObject
  carries `autoscaling.keda.sh/paused-replicas` — it reverts within seconds, and
  a 0-replica Deployment reports *"successfully rolled out"*. Assert
  `readyReplicas`, never trust the rollout.
* **Do not change the image in the same step.** A flag flip diagnosed together
  with an image change is two variables.

---

## 3. What to watch, during and after

| # | signal | healthy | act if |
| :-- | :-- | :-- | :-- |
| 1 | `noetl_ehdb_eventlog_ops_total{operation="mirror",outcome="served_primary"}` | rising on the replicas receiving appends | **absent** ⇒ the binary predates the serve path (check `build_info`). **Flat at 0 on every replica while events flow** ⇒ the flip is inert. Roll back; do not flip again |
| 1b | `.serve_state` on `GET /ehdb/tiers/eventlog` | `served_primary` on ≥1 replica, `unknown` on the rest | `no_durable_service` / `parity_diverged` ⇒ rows 2/3. All `unknown` while events flow ⇒ as row 1 |
| 2 | same family, `outcome="unavailable"` (and `primary_unavailable`) | 0 | rising ⇒ appends are not reaching the tier service; the incumbent is answering. `unavailable` is the transport case, `primary_unavailable` is "reachable but nothing to serve from" |
| 3 | same family, `outcome="primary_divergence"` | 0 | **any** ⇒ roll back and investigate before the window ends. The tier store disagreed with itself (sequence/count), which is a store-integrity signal, not a cross-store one |
| 4 | `/api/ehdb/parity/executions/<id>` → `holds` | `true`, `matched == authoritative_count`, `divergences: []` | `divergent` ⇒ roll back |
| 5 | `noetl_ehdb_dataplane_ops_total{operation="tier_service.append",outcome="ok"}` | rising with traffic | flat while events flow ⇒ the mirror is not reaching the service |
| 6 | `…{operation="tier_service.append",outcome="error"}` / `"unavailable"` | 0 | rising ⇒ writer-side failure |
| 7 | `noetl_ehdb_tier_service_duration_seconds_{count,sum}` | count rises, **sum non-zero** | sum stuck at 0 with a rising count ⇒ a recorder measuring nothing |
| 8 | `noetl_ehdb_tier_service_store_{appends_total,sequence,bytes}` | rising | flat while (5) rises ⇒ the append is not landing on disk |
| 9 | `noetl_worker_ehdb_query_ops_total{operation="tier_query_source.read",outcome=…}` | `outcome="service"` | `downgraded_local` / `misconfigured` ⇒ a replica is reading the wrong store |
| 10 | **the incumbent** — every execution still reaches `playbook.completed` with `command.issued == command.completed` | always | any shortfall ⇒ roll back immediately; this is the invariant the whole rollback story rests on |

Two reading rules for this table:

* **Absent ≠ zero.** `Registry::gather` prunes empty metric families, so a
  labelled series does not exist until it fires. Row 1 absent and row 1 at zero
  mean different things — one is "no serve path", the other is "no traffic".
* **Read the original, not the copy.** Execution status comes from the event
  log; `noetl.execution.status` is a frozen Python-era column nothing in the
  Rust path writes ([#235](https://github.com/noetl/ai-meta/issues/235)) and has
  already caused one false-alarm abort.

---

## 4. Rollback

**One command. Symmetric with the flip. No image change, no data migration.**

```bash
kubectl -n noetl set env deploy/noetl-worker-rust NOETL_EHDB_EVENTLOG=shadow
kubectl -n noetl rollout status deploy/noetl-worker-rust --timeout=300s
```

It is safe because `primary` only appends and the incumbent was written
throughout. Nothing is stranded: the tier keeps whatever it holds, the
comparator keeps verifying, and reads go back to the incumbent.

After rolling back:

1. reset any relay/scrape pin left at an old pod IP (§2);
2. confirm executions still complete with a full set (row 10);
3. confirm the comparator still returns `match` from **more than one** replica;
4. leave `MIRROR_SOURCE=server` and `TIER_QUERY_SOURCE=service` **in place** —
   they are not part of the flip and rolling them back would undo the
   full-set mirror and re-fragment the tier.

**Full stack-down** (only if the images themselves are suspect) is the released
pair: server `3.79.2`, worker `5.115.3`, rolled **by digest**, with every
`NOETL_EHDB_TIER_*` unset.

---

## 5. The rehearsal that backs this

Kind (`kind-noetl`), composed images, **three worker replicas**, 2026-08-12.
Full detail in `RESULTS.md`.

Two runs. The first (images `capreal` / `pr4real`) found P0; the second
(`capp0` = worker `8d46b33`, same server image) closes it. Both at three
replicas on the same cluster.

**Run 2 — 2026-08-12, after the P0 fix:**

| step | result |
| :-- | :-- |
| serve-readiness bundle (`gate.sh service`) | **45 passed, 0 failed** — 19/19 from all 3 replicas, one `match` per pin, observability moving; plus the new pin check and the shadow negative control |
| the flip (`gate.sh primary`) | **49 passed, 0 failed** — `served_primary` **+13**, `serve_state=served_primary` at the endpoint, the serve line logged |
| bypass mutation (`mutation-p0.patch`) | **47 passed, 2 failed**, and the two are exactly the serve assertions. Everything else — 13/13 match from all three replicas, one verdict, observability, incumbent 3/3 — still passed, which is why only a composed gate finds this |
| restored (`capp0`) | **49 passed, 0 failed** — the failures are attributable to the mutation, not to drift |
| tier-service kill (`gate.sh killswitch`) | **23 passed, 0 failed** — `served_primary` **+0**, `unavailable` +23/+41, WARN naming `no_durable_service` with the transport cause; every replica alive and refusing the read; comparator `ehdb_unavailable` from all three, never `match`; 3/3 executions complete through the outage |
| recovery (`tierup`) | re-promoted on a real append: `served_primary` 39 → 41, `serve_state=served_primary`, **restarts=0** on every pod. Belief is restored by a successful operation, not a bounce or a timer — and the replica that received no append stayed demoted, which is correct: belief is per-process |
| rollback (`mode shadow`) | **45 passed, 0 failed** — same measured state as before the cycle, and fresh pods pin `served_primary` at 0 while `mirrored` moves |

**Run 1 — the same session's earlier bundle, kept because it is the evidence P0
existed:** `service` 41/0; composed mutation 25/15 (both families, restored to
41/0); `primary` 44/1, the one failure being `served_primary = 0` with the family
absent; `killswitch` 22/0; rollback 41/0. Full detail in `RESULTS.md`.

The flip and the rollback were each executed with the exact command pair in §2
and §4 — `deploy.sh mode primary` / `deploy.sh mode shadow` are one-line wrappers
around them, so this runbook cites commands that have been run rather than
composed by hand.

---

## 6. Traps this runbook exists to prevent

* Flipping a tier that has no runtime serve path, and reading the resulting
  silence as success. (P0 — found, then fixed. The reason it was silent is that
  an absent metric family and a build without the feature render identically;
  the pin and the `serve_state` reply field are both there to remove that.)
* Assuming a policy is *reached* because it exists, is registered, is tested and
  is documented. All four were true of `primary_serve::decide` while the
  serve-ready configuration reached neither of its call sites. Ask reachability,
  not existence.
* Flipping with `TIER_QUERY_SOURCE=local` at N>1 replicas: the tier is
  fragments, and two thirds of reads report it empty while one third reports a
  clean match.
* Trusting `tier_query_source: service` as evidence. It is necessary for
  attribution and insufficient as proof.
* Concluding "the tier is fine" from a single-replica sample.
* Diagnosing an image change and a flag flip together.
* Treating `kubectl rollout status` as "the endpoint is serving" — the old
  server pod answers `/api/health` with 200 while it terminates.

## Related

* `README.md` — the composed branch and how to run the gate.
* `RESULTS.md` — the evidence bundle.
* `docs/rfc/ehdb-primary-serve-path.md` §3.4 — cutover shape and the wired-tier
  correction.
* `docs/rfc/ehdb-primary-serve-availability.md` — open question 2, the
  single-writer posture.
* `agents/rules/deployment-validation.md` — kind before GKE, always.
