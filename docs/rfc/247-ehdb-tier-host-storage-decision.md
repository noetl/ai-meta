# RFC — where the EHDB storage tiers run, and on what disk

**Decision needed from:** the user (infrastructure + design)
**Blocks:** [ai-meta#247](https://github.com/noetl/ai-meta/issues/247) — every
phase 6–10 tier flip, **including `shadow`**
**Status:** open. Nothing enabled; prod is tier-off on all five tiers.

---

## 1. The decision in one paragraph

The five EHDB storage tiers (event-log, projection, KV, object, vector) are
code-complete and `PRIMARY_SERVE_ACTIVATED = true` in the released worker. They
cannot be turned on — not even in `shadow` — because **the process that would
write them has no durable disk, and the process that has durable disk does not
author the events**. That is one decision (where do the tiers live), and it is
not a config change.

## 2. Why `shadow` is blocked too, which was not obvious

`shadow` is "dual-write + compare, never serve". It sounds free. It is not:
shadow writes the mirror to local disk, and the mirror **is** the artefact the
parity evidence is computed from.

Worse than losing data, it produces *misleading* evidence. The parity check is
primarily the engine's own gapless-from-1 invariant:

> the engine's own invariant `global_sequence == log_record_count` proves no gap
> and no double-write for THIS append … Sequence parity against the
> authoritative log is enforced **when known**.

A pod that is scaled down and replaced starts a fresh mirror at sequence 1 —
and that invariant still holds. So shadow on ephemeral disk would very likely
keep reporting **clean parity while having silently lost history**. A green
shadow on ephemeral storage is not a weaker signal than a green shadow on
durable storage; it is a different claim wearing the same colour.

## 3. The two facts that constrain every option

**(a) The worker pools have no persistent volume.**

```
noetl-worker-rust:        volumes = dshm     pvc = (none)
noetl-worker-system-pool: volumes = dshm     pvc = (none)
```

and their KEDA ScaledObject is `min 2 / max 20`. A pod-local tier there is not
a cache that occasionally cold-starts; it is storage that is routinely
discarded.

**(b) The writer, which does have durable volumes, authors no events.**

`ehdb::eventlog::mirror_live_event` is called from
`worker/src/client/control_plane.rs`, inside **`emit_event`** — its own comment
calls this "the authoritative event-emit chokepoint every worker path funnels
through". A process mirrors events only if it *emits* them.

Measured — one real execution, both pods sampled before and after:

| pod | before | after |
| :-- | :-- | :-- |
| `noetl-worker-rust` | `dispatch{tool_kind="noop"} 3` | **4** |
| `noetl-cmdbus-writer-0` | all dispatch/pull counters `0` | **all still `0`** |

The writer runs the full `noetl-worker` binary and has `NOETL_SERVER_URL`, so
the hook *would* arm — but it has processed **zero** pulls and zero dispatches.
It hosts the two bus writers and nothing else.

**So enabling `NOETL_EHDB_EVENTLOG=shadow` on the writer would mirror nothing**
while reading as "tier 1 shadow enabled".

> This corrects an earlier recommendation of mine on #247, which proposed the
> writer as "the cheapest correct step for shadow" on durability grounds and
> skipped the reachability question. Recorded because the reasoning error is
> more reusable than the conclusion.

## 4. The options

### Option A — give the worker pools durable per-replica storage

| | |
| :-- | :-- |
| **Change** | Deployment → StatefulSet for `noetl-worker-rust` (+ system pools), with `volumeClaimTemplates` |
| **Cost** | Up to 20 PVCs at max scale; per-replica PVC lifecycle to operate; orphaned PVCs on scale-down are an ongoing cost |
| **Blast radius** | **Touches the autoscaling path** that #210/#194 stabilised. Ordered scale-up/down changes dispatch latency characteristics under burst |
| **Reversibility** | Poor-to-moderate. Converting back is another workload replacement; the PVCs outlive it |
| **Gets you** | Tiers colocated with the compute that uses them; scales horizontally |

### Option B — run the tiers on the `noetl-cmdbus-writer` StatefulSet

| | |
| :-- | :-- |
| **Change** | Set the tier flags on the writer only |
| **Cost** | Near-zero infrastructure — `cmdbus-data`, `eventbus-data`, `eventbus-kv` (20–50 Gi `premium-rwo`) already exist |
| **Blast radius** | Concentrates more state on the one `replicas: 1` workload that already hosts **both** buses and whose restart already produces visible gateway `Connection refused` bursts |
| **Reversibility** | Excellent — unset the flags |
| **Gets you** | **Nothing, for the event-log tier.** Per §3(b) the writer emits no events, so the mirror stays empty |

### Option C — a dedicated tier workload

| | |
| :-- | :-- |
| **Change** | New StatefulSet with its own PVCs, running the worker binary with tier flags set |
| **Cost** | New workload to define, size, monitor, and roll |
| **Blast radius** | Smallest — isolated failure domain, no change to the autoscaling path or to the writer |
| **Reversibility** | Excellent — delete the workload |
| **Gets you** | Durable tiers **only if it is also on the event-emit path**, i.e. it must be a *dispatching* worker, not a bus host |

### Option D — move where the mirror hook fires

Make a durable, non-dispatching process able to mirror the authoritative log —
e.g. hook the materializer rather than `emit_event`. This is a **design
change**, not configuration, and would need its own RFC. Listed because it is
the only option that decouples "durable" from "dispatching", which is the
tension the other three are all working around.

## 5. Recommendation

**Option C, scoped as a dispatching worker**, with the tier flags set only
there.

Reasoning: the requirement is the conjunction of *durable disk* and *on the
event-emit path*. Option B satisfies the first and fails the second. Option A
satisfies both but pays for it by changing the autoscaling path — the one part
of this system that has been stabilised twice (#210, #194) and that a tier
experiment should not be allowed to destabilise. Option C satisfies both in a
failure domain that can be deleted.

**A caveat that may make all of this cheaper:** the RFC's own framing says a
writer's local data is a *hot cache, not the source of truth*, with sealed parts
shipped to a replicated object store. If that holds, the durability requirement
may be "reachable object store + somewhere to keep the hot part", which could be
satisfied without per-replica PVCs at all. **That reading should be confirmed
before anyone builds Option A**, because it is the difference between a new
StatefulSet and a config value.

## 6. Sequencing once the decision is made

1. Stand up the chosen host.
2. Enable `shadow` per tier, cheapest signal first: projection → KV → object →
   vector → **event-log last**.
3. Collect parity evidence per tier: `published == projected == cursors`, zero
   dup/gap/out-of-order, `cursor_errors == 0`, group lag 0, a real execution
   completing while the tier mirrors, and **a watch window spanning at least one
   scale event** — scale-down is the failure mode the storage gap creates, so
   surviving one validates the decision empirically rather than by argument.
4. Then `primary`, one tier at a time, rollback one flag away
   (`primary` → `shadow` is documented zero-data-loss: primary only *appends* to
   the EHDB log and never mutates what the incumbent owns), with
   `PRIMARY_SERVE_ACTIVATED` as the second lever.

**The event-log tier deserves its own gate at step 4.** It is the only one where
"serving from EHDB" means the append-only platform log, which is the system's
source of truth.
