# The two gating traces — RESOLVED by measurement

Written 2026-09-17 by the incoming session. Every claim here is either a read of
the tree at a cited line, or a counter delta from a run I performed. Where I was
wrong mid-trace I say so, because the wrong turn is itself a finding.

⚠ **Correction to the handover's own pointer:** the handover is NOT at
`ai-meta/handover/`. It is at
`loops/active/2026-09-11-ehdb-resilient-core-phases/handover/`. Likewise the
code clones are the ai-meta submodules `repos/{ehdb,worker,server}` (build
caches intact: worker 15G, server 6.0G, ehdb 2.4G), **not** `/Volumes/X10/projects/adiona/`.

---

## TRACE A — the append path. There is no read/write split. There is a TWO-STORE split.

**Resolved. The prior session's withdrawn "read/write split" was withdrawn
correctly, and the replacement is not the one the OPEN-QUEUE's pre-flight
section assumes either.**

### The two paths are selected by `Resolution`, per request

`worker/src/ehdb/tier_query_source.rs:141 resolve()` returns one of four
`Resolution` values. Two matter:

| Resolution | append goes to | reads go to | branches on backend? |
| :-- | :-- | :-- | :-- |
| `Local` | `eventlog::mirror_event` (`metrics_server.rs:1030`) | `query::run_query` (`metrics_server.rs:392`) | **YES** — both |
| `Service(client)` | forwarded to the writer's tier service :9110 | forwarded to :9110 | **NO** — neither |

On the `Service` branch the worker never enters `mirror_event` and never enters
`run_query` — `metrics_server.rs:387` shows `run_query` is reached only on
`Resolution::Local`. The comment at `metrics_server.rs:810` says this in the
tree's own words: *"`Resolution::Service` never enters `mirror_event`, which is
where the other call site lives."*

On the writer side the service resolves to:

```
tier_service.rs:381  tier_store::append
tier_store.rs:207    fn driver(..) -> LocalReferenceEventLogDriver   // concrete, no match
```

`tier_service.rs` routes **append (381), append_batch (388), read_execution
(426) and scan (430)** all through `tier_store`. So the tier service's read and
write are *both* unbranched, and they are consistent with each other.

### What prod is actually configured as — VERIFIED from the live objects

Both worker pools carry `NOETL_EHDB_TIER_QUERY_SOURCE=service` and
`NOETL_EHDB_TIER_SERVICE_ADDR=noetl-cmdbus-writer-0.noetl.svc.cluster.local:9110`.
⇒ **prod is on the `Service` branch.**

`NOETL_EHDB_EVENTLOG_BACKEND` is **absent from all three workloads**, and
`envFrom` is `None` on every container — so the inline env is the complete
picture and this is a true absence, not a filtered one.

The writer itself has no `NOETL_EHDB_ENABLED`, no `NOETL_EHDB_EVENTLOG` and no
`TIER_QUERY_SOURCE`. It is purely the tier **service** plus both buses.

### The consequence — and it corrects the OPEN-QUEUE

The OPEN-QUEUE pre-flight says setting `NOETL_EHDB_EVENTLOG_BACKEND=durable_segment`
would "make the READ path expect a format the WRITE path never produces — a
read/write split on a tier that is `primary` and RF=1."

**That is not what would happen.** On prod's `Service` branch the flag is read by
neither side of the tier path. Setting it would be **inert for the event-log
tier**, not corrupting. The flag only has teeth on `Resolution::Local`, which
prod does not use for the tier.

So the exposure is *smaller* than recorded — but the conclusion "do not flip it,
it migrates nothing" stands, for a different and more precise reason.

### What this means for stage 3 — the actionable part

⭐ **The durable write path must be implemented in `tier_store.rs`, not in
`eventlog_backend.rs`.** `build_durable_stack` exists and is genuinely
constructed (`eventlog_backend.rs:505`, `:609`) — the handover is right that it
is not "unimplemented" — but it is wired into the **pod-local** path, which the
production tier does not traverse. Stage 3 is: give `tier_store::driver()` a
backend dispatch and a `DurableSegment` driver, so the tier service can write the
durable format. Nothing in `eventlog_backend.rs` needs to change for prod to
benefit; it is the reference implementation to reuse.

---

## TRACE B — digest_mismatch is REAL, is NOT the projector, and `test/simple_loop` cannot see it

**Resolved by measurement, in kind, both flags as the handover left them.**

### ⚠ My own wrong turn, recorded because it is the point

My first measurement ran **5 × `test/simple_loop`** and found `digest_mismatch`
**flat at 7**, with 14 grants issued through the real comparison — and I was
about to report "the counter predates the flip, the projector is clean."

That would have been the handover's error repeated. `test/simple_loop` produces
**zero reference envelopes**: results under
`NOETL_PERMANENT_LOG_INLINE_MAX_BYTES` (default **512**) stay inline, so the
fixture is structurally incapable of exhibiting the defect. A fixture that cannot
exhibit the failure makes the test decorative.

### The measurement that can see it

`muno/probe/big-parent`, one run, same config:

| counter | 5 × simple_loop | 1 × big-parent |
| :-- | --: | --: |
| `projection_refold_total{verdict=digest_mismatch}` | **+0** | **+7** |
| `projection_read_total{outcome=digest_mismatch}` | **+0** | **+7** |
| `projection_serve_refusal_total{reason=digest_mismatch}` | **+0** | **+2** |
| `crossstore_divergence{checksum,projection}` | +0 | +0 (flat 0 throughout) |

### The cause, from the fold-diff endpoint (`?source=tier`)

```
/steps/fetch/result/context/result/context/data/_ref        (only in tier)
/steps/fetch/result/context/result/context/data/_uri        (only in tier)
/steps/fetch/result/reference                               (only in tier)
/steps/fetch/result/context/result/context/data/count       (only in postgres)
/steps/fetch/result/context/result/context/data/hotels      (only in postgres)
/steps/fetch/result/context/result/context/data/meta        (only in postgres)
/steps/fetch/result/context/result/context/status           (only in postgres)
```

The stored snapshot carries the **unresolved reference envelope**; the
verification leg folds **hydrated** Postgres
(`ehdb_projection_fold.rs:198 events_from_postgres_hydrated` →
`hydrate_result_references(.., keep_refs=false)`). The two therefore disagree
**by construction** on every result over 512 bytes.

### ⭐ The control that settles ownership — projector OFF, same fixture

Projector disabled on the kind system pool, rolled, same playbook:

```
projection_refold_total{verdict="digest_mismatch"}  19 -> 20   (+1, still climbing)
projection_read_total{outcome="digest_mismatch"}    19 -> 20
```

**It reproduces with the projector off.** `digest_mismatch` is a **pre-existing
content asymmetry between the snapshot writer and the snapshot verifier**, and
is orthogonal to the projector.

What the projector *does* contribute is **reachability**: its async writes make
snapshots lag, which raises `stored_behind_spine`, which is the only gate that
lets `grant_for_behind` run at all (`ehdb_projection_fold.rs:1718`). That is why
`serve_refusal{digest_mismatch}` moved from a structural 0 to a visible number
when the projector was switched on. The refusals were always latent; the
projector made the check execute.

### Two further corrections to the handover's reasoning

1. **`DigestMismatch` does not mean "content disagreement" alone.**
   `bounded_fold_agrees` (`:1569`) requires **both** `b.version == stored_version`
   **and** `b.digest == stored_digest`. A pure *version* mismatch is reported
   under the digest label. The handover inferred "content, not lag" from a doc
   comment; the predicate covers both. (Here it does turn out to be content —
   but that was measured, not inferred.)
2. **`fold()` (`:636`) omits `normalise_null_json`; `fold_with_body()` (`:579`)
   calls it.** `bounded_fold_at` uses `fold()`. `normalise_null_json`'s own doc
   says it "erases it on both sides" — it is not on both sides. This is a second,
   independent asymmetry on the same comparison. Not the cause of what I
   measured, but it is live and should be closed with it.

### ⚠ A hazardous combination this exposed

`NOETL_PROJECTOR_OWNS_SNAPSHOT=true` on the server **with the projector off**
means the orchestrator has stopped self-writing and nothing has replaced it:
`snapshot_gate{skipped_projector_owns}` keeps climbing while
`projection_advanced_total` is frozen. **Nobody writes the snapshot.** That is
the mirror image of the two-writer contention the second flag was added to fix,
and it is just as much a wrong intermediate state.

### Verdict for stage 1

The owner's acceptance bar — `digest_mismatch` at 0 — **cannot be met by fixing
the projector**, because the projector does not cause it. Stage 1 as written is
blocked on a defect that belongs to the snapshot-vs-verifier contract. Either the
snapshot is written hydrated, or the verifier folds unhydrated; they must agree.
That is a separate fix and it is an owner-visible change to what a snapshot
contains.

**Prod was not touched by any of this — reads only.** Kind is restored to both
projector flags ON, as the handover left it.
