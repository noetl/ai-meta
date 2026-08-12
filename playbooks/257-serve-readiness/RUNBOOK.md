# Cutover runbook — promoting the EHDB **event-log** tier to `primary`

RFC [ai-meta#257](https://github.com/noetl/ai-meta/issues/257) **PR 7**.
Rehearsed in kind on the composed stack, 2026-08-12 (`RESULTS.md`).

> **This runbook documents the flip. It does not perform it.**
> Every prod step below is gated on an explicit, per-tier human go. Nothing in
> this session touched prod, and no tier is `primary` anywhere.

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

### P0 — ⛔ the flip must have a reachable serve path *on the configuration you are flipping*

**This is currently NOT satisfied, and it is the blocker.** The rehearsal
measured it: with the target configuration
(`NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=server` +
`NOETL_EHDB_TIER_QUERY_SOURCE=service`), setting the event-log tier to `primary`
produced **`served_primary = 0` across every replica** — in fact the whole
`noetl_ehdb_eventlog_ops_total` family was **absent**, so nothing in the tier's
own metric family fired at all, while 13 events per execution flowed and landed
correctly in the tier.

`primary_serve::decide` has exactly two live call sites, and the target
configuration reaches neither:

| call site | why it is not reached |
| :-- | :-- |
| `eventlog::mirror_live_event` (the worker's own hook) | `MIRROR_SOURCE=server` disarms the hook in `client/control_plane.rs` *before* the tier mode is consulted, so `runtime_hook_env` — the only caller of the flip-time signal — never runs |
| `metrics_server::ehdb_tier_append_handler`, `Resolution::Local` branch | `TIER_QUERY_SOURCE=service` takes the `Resolution::Service(client)` branch, which calls `client.append()` and never enters `mirror_event` |

Verify before flipping (must be **non-zero**, from every replica):

```bash
kubectl -n noetl exec <writer-pod> -- sh -c \
  "wget -q -O - http://<worker-pod-ip>:9090/metrics" \
  | grep '^noetl_ehdb_eventlog_ops_total'
```

An **absent** family is not a zero. If nothing prints, the flip will be inert
and you will have no signal saying so.

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

[ops#255](https://github.com/noetl/ops/pull/255) (7 rules + the events scrape)
applied. ⚠ **Prod has zero notification channels**
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

`warn_primary_not_wired` predates PRs 5/6 and tells an operator that `primary`
did nothing on a build that serves. worker `fix/259-primary-flip-signal`
replaces it with three distinct conditions (`primary_not_wired` /
`primary_no_tier_service` / `primary_armed`). Land it first, or the one log line
emitted at the moment of the flip is misleading.

⚠ On the composed configuration the rehearsal saw something worse than
misleading: **no line at all**, for the P0 reason above.

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
| 1 | `noetl_ehdb_eventlog_ops_total{operation="mirror",outcome="served_primary"}` | rising | **absent or flat** ⇒ the flip is inert (P0). Roll back; do not flip again |
| 2 | same family, `outcome="primary_unavailable"` | 0 | rising ⇒ the tier service is unreachable; the incumbent is answering |
| 3 | same family, `outcome="parity_diverged"` | 0 | **any** ⇒ roll back and investigate before the window ends |
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

| step | result |
| :-- | :-- |
| serve-readiness bundle (`gate.sh service`) | **41 passed, 0 failed** — full-set match from all 3 replicas, observability moving on the right labels |
| composed mutation | **25 passed, 15 failed**, exit 1 — failures in **both** families; restoring the real image returned it to 41/0 |
| the flip (`gate.sh primary`) | **44 passed, 1 failed** — the one failure is P0: `served_primary = 0`, family absent |
| incumbent through the primary window | **3/3** executions complete, `playbook.completed` present, `issued == completed` |
| tier-service kill (`gate.sh killswitch`) | **22 passed, 0 failed** — metric surface entirely absent (9/9), every replica alive and **refusing** the read, comparator `ehdb_unavailable` from all three and never `match`, 3/3 executions completing with a complete set during the outage |
| recovery (`tierup`) | 20 series back; all 3 replicas 13/13 `source=service`; comparator `match` — **with no worker restart**, so belief was restored by real successful operations, not by a process bounce or a timer |
| rollback (`mode shadow`) | executed; post-rollback `gate.sh service` = **41 passed, 0 failed** — the cluster is in the same measured state after the cycle as before it |

The flip and the rollback were each executed with the exact command pair in §2
and §4 — `deploy.sh mode primary` / `deploy.sh mode shadow` are one-line wrappers
around them, so this runbook cites commands that have been run rather than
composed by hand.

---

## 6. Traps this runbook exists to prevent

* Flipping a tier that has no runtime serve path, and reading the resulting
  silence as success. (P0 — and it is the current state.)
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
