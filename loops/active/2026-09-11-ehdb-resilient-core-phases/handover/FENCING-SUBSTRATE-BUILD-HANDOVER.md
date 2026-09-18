# Handover — fencing, durable write path, migration, cutover

**Written 2026-09-18 by the outgoing session, which stopped at the accuracy
cliff rather than start stage 2.** Owner authorized the full build (kube
dependency included). Stages 2–5 are NOT started. Stage 1 is blocked on one
unexplained signal, described below.

Everything here is split into **VERIFIED** (I ran the command / read the code)
and **NOT VERIFIED** (plausible, untraced). Trust the first, re-check the second.
The outgoing session made two confident overclaims in its final turns — both from
generalising off a partial read — so the split is deliberate.

---

## ⚠ Two corrections the record must carry

1. **"Substrate D is not implemented" — WRONG, withdrawn.**
   `build_durable_stack` exists at `worker/src/ehdb/eventlog_backend.rs:505` and
   is called from the `EventLogStorageBackend::DurableSegment` arm at line 609.
   That file (1475 lines) is the worker's backend-selection seam and is called
   from `command_bus.rs`. **VERIFIED.**
   What *is* true and narrower: `worker/src/ehdb/tier_store.rs:207 driver()`
   returns `LocalReferenceEventLogDriver` as a **concrete type with no branch**,
   and `event_bus.rs` (the tier service, port 9110) writes through it. **VERIFIED.**
   ⚠ **NOT VERIFIED:** whether those two paths conflict under a flip. The
   outgoing session claimed a "read/write split" and withdrew it. **Trace which
   path the prod event-log tier actually appends through before believing either
   story.** This is the single most important unknown for stages 3–4.

2. **"The fencing mechanism must be built from scratch" — WRONG, withdrawn.**
   The spec docs are stale. See below.

---

## Stage 2 (fencing) — far more exists than the docs say

**VERIFIED, on `ehdb` main:**

| file | lines | state |
| :-- | --: | :-- |
| `crates/ehdb-reference/src/election.rs` | 398 | single-writer election + token issuance (ehdb#331 F1). Header: *"Wired, but NOT authoritative"* — issues tokens; single-writer still rests on `replicas: 1` until an owner-gated promotion |
| `crates/ehdb-reference/src/fencing.rs` | 404 | Invariant F epoch enforcement in the storage contract (ehdb#330 F2). Ships `FencingMode::Shadow` — stale epochs **counted and logged, write still succeeds**. `FencingMode::Enforce` is owner-gated |
| tests | — | `lease_election.rs`, `fencing_shadow.rs`, `election_drives_fencing.rs` |
| specs | — | `docs/spec/writer-election-and-fencing.md` (219 lines), `docs/spec/lease-election-k8s-binding.md` |

The worker already wires fencing: `worker/src/ehdb/eventlog_backend.rs:50-51`
imports `ehdb_reference::fencing`, and `metrics_server.rs:165-171` reads
`FencingSetting::from_env` + `FENCING_METRICS`. **VERIFIED.**

⭐ **No segment-key migration is needed, and the docs saying otherwise are
stale.** `fencing.rs` deliberately deviates from spec §4.1: the epoch lives in a
**per-shard fencing marker**, NOT the frame header, because `FRAME_HEADER_LEN` is
a fixed 12 bytes shared byte-identically with `durable_eventlog.rs` — widening it
would make every existing segment unreadable. That is the better decision and it
removes the key-format migration the outgoing session (and the issue) assumed.
**VERIFIED by reading the module header.**

### What actually remains for stage 2

1. **The `kube`/HTTP client dependency.** `grep kube|k8s-openapi` across
   `Cargo.toml` and `crates/*/Cargo.toml` returns **nothing**. **VERIFIED.**
   `docs/spec/lease-election-k8s-binding.md` has a section literally titled
   *"Why it is not built yet"*: pulling in `k8s-openapi`, `tower`, `hyper` and a
   TLS stack is called *"a dependency decision, not an implementation detail."*
   **The owner has now approved it.**
2. A `LeaseStore` adapter against a real API server. `LeaseStore` is described in
   the binding doc as "the seam that keeps the decision open, and the *only*
   thing the adapter has to satisfy." **NOT VERIFIED** — read the trait before
   estimating.
3. Two owner-gated promotions: `FencingMode::Enforce`, and election →
   authoritative.
4. RBAC — the binding doc has an "RBAC — owner-run" section.

**So stage 2 is adapter + promotion, not a consensus build.** Much smaller than
the issue implies. Re-read both spec docs first; parts are stale.

---

## Stage 1 (projector) — BLOCKED on one unexplained signal

**VERIFIED in kind, 10 executions, both flags on
(`NOETL_PROJECTOR_ENABLED` on the worker, `NOETL_PROJECTOR_OWNS_SNAPSHOT` on the
server):**

| signal | prod (projector flag only) | kind (both flags) |
| :-- | :-- | :-- |
| `crossstore_divergence{checksum,projection}` | 1 → 2 → 9 → 10, climbing | **0, flat** |
| `snapshot_gate{skipped_projector_owns}` | 0 | **20, climbing** |
| double-advance | none | none — projector 49 = server 49, exact |
| `projector_held_total` | 0 | 6, **static** (one `errors{partial}=1`, correctly held) |
| `serve_refusal{digest_mismatch}` | 0 → 27 | 2 → 4 → **7, climbing** |
| executions | clean | 10/10 COMPLETED |

✅ **The two-writer contention IS fixed by the second flag.** That was the
hypothesis and it holds: the orchestrator stops self-writing
(`skipped_projector_owns` climbing) and checksum divergence stays flat at 0.

🛑 **BUT `digest_mismatch` still climbs (~1 per execution), and the owner's
acceptance bar for stage 1 was 0.** Do not enable in prod until this is
explained.

**What `digest_mismatch` means — VERIFIED** from
`server/src/handlers/ehdb_projection_serve.rs`: `ServeGrant::evaluate(digests_agree,
stored_version, spine_version)` refuses with `DigestMismatch` when a **behind**
snapshot's digest **disagrees** with the spine. Its own test says *"behind is
servable, wrong is not."* So this is a **content disagreement, not lag**.

⚠ **Why that is surprising and worth chasing:** `advance_snapshot`
(`server/src/handlers/events.rs`) documents itself as reusing the block-b
machinery verbatim so "the snapshot the projector writes is byte-for-byte what
the orchestrator would have written itself." If that were exactly true the digest
should agree. **NOT VERIFIED:** whether the refusals predate the flag flip
(counters are cumulative since pod start and kind's baseline was already 4), or
whether the projector genuinely produces a different digest. **Establish that
first** — a per-execution check beats reading another counter.

**Prod is projector-OFF.** Kind is deliberately left with BOTH flags ON as a
staging state.

---

## Stage 5 (KV/object cutover) — rollback path CONFIRMED GOOD

**VERIFIED** from `worker/src/ehdb/kv.rs` module docs:

* Two independent rollback levers: flip `NOETL_EHDB_KV` back to `shadow`/`off`
  → incumbent NATS-KV authoritative again **instantly, no redeploy**; plus a
  compile-time `PRIMARY_SERVE_ACTIVATED` kill switch.
* *"Zero data loss: the primary path only ever appends to the derived EHDB
  `KeepAll` KV stream and never mutates/deletes anything NATS-KV owns."*
* `PRIMARY_SERVE_ACTIVATED = true` in both `kv.rs:84` and `object.rs:96`.

So the old store is intact and the cutover is genuinely reversible. It is gated
only on stage 2.

---

## Current prod state (all VERIFIED this session)

```
server      v3.112.3   sha256:73487c92…   + readiness gate
workers +   v6.1.0     sha256:728827e9…   (4 workloads)
cmdbus-writer
projector                 OFF  (rolled back after causing divergence)
PROJECTOR_OWNS_SNAPSHOT   unset (server)
FAIL_ON_STEP_ERROR        true on all four workloads
KV / OBJECT               shadow
EVENTLOG_BACKEND          unset → LocalReference
branch protection         test/test/test/rust required on worker/server/tools/ehdb
```

## Operational hazards worth knowing

* ⚠ **Rolling `cmdbus-writer` loses in-flight executions.** Seen three times
  this session: commands submitted during its restart window return
  `execution_id` but produce zero events. Single-writer consequence. Drain or
  quiesce before rolling it, or expect to re-run.
* ⚠ Two `git stash` entries in `noetl/worker` were resolved this session; the
  stash list is now empty. Do not `git add -A` in that repo — it has (had) large
  untracked build scratch; `target-*/` is now gitignored.
