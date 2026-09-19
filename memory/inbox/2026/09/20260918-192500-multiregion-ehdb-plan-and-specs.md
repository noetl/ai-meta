# Multi-region EHDB: plan + 12 specs, and four grounding corrections
- Timestamp: 2026-09-18T19:25:00Z
- Author: Claude
- Tags: ehdb,multiregion,design,specs,hlc,closed-timestamp,fencing,l0,grounding

## Summary

Design-only session. Produced a capability → EHDB-primitive mapping, a
dimensional model, a phased plan and 12 specs. (Naming: nothing here is branded
after another product; prior art is credited once in the plan doc.) **No prod change, no code
change, nothing merged.** Branch `design/multiregion-ehdb`.

Artefacts:

- `loops/active/2026-09-11-ehdb-resilient-core-phases/handover/MULTIREGION-EHDB-PLAN.md`
- `specs/active/2026-09-18-multiregion-ehdb/` — `spec.md` (umbrella) +
  M0, M0.5, M1, M2a, M2, M3, M4, M5, M6, M7, M8.

## The four grounding corrections — the durable value of the session

**1. ⚠⚠ The `primary`-serving event-log TIER does not run on `ehdb-l0` at all.**
`tier_store.rs:207 driver()` returns `ehdb_reference::LocalReferenceEventLogDriver`
(`ehdb-reference/src/eventlog.rs:339`), which composes `LocalReferenceRuntime` +
`ehdb_stream`. **`ehdb-reference` has no `ehdb-l0` dependency.** `ehdb-stream`
depends only on `ehdb-core`/`serde`/`serde_json` and stores via
`OpenOptions::append(true)` + `BufReader::lines()`; occurrence counts in its
`lib.rs`: `replica` 0, `seal` 0, `manifest` 0, `fsync` 0, `sync_data` 1.
`L0Engine` IS opened in the same process (`event_bus.rs:258`) and the tier
service is spawned from that same file (`:321`, `:358 serve_tier`) — **same
process, different storage stack, different port (9110 vs the buses).**
⇒ ReplicaTarget/N-way copy, FailureDomain, UnreplicatedTracker, sealed parts +
manifest, `seal_max_age`, cold-load are all **real and all on the BUS engines,
not on the tier**. This invalidated three phases of my own first draft; fixed by
inserting M0.5 (tier-backend dispatch). **Generalisable: "the primitive exists"
and "the primitive is on the path" are independent questions.**

**2. Prod's tier write path is the `Service` branch, so the durable write path
belongs in `tier_store.rs`, not `eventlog_backend.rs`.** (Re-confirmation of
what `TRACE-RESULTS.md` already established; `build_durable_stack`
(`eventlog_backend.rs:505`, `:609`) is on the pod-local path prod does not take,
and `NOETL_EHDB_EVENTLOG_BACKEND` is read by neither side of the tier path.)

**3. ⭐ The fencing epoch lives in a per-shard MARKER, not the frame header.**
`ehdb-reference/src/fencing.rs` deviates from spec §4.1 deliberately because
`FRAME_HEADER_LEN` is a fixed 12 bytes shared byte-identically with
`durable_eventlog.rs`. **No segment-key migration is needed and the docs saying
otherwise are stale.** This is what lets the epoch space widen for multi-region
leadership with no on-disk format break.

**4. `global_sequence` is PER-ENGINE, not a global order.** `engine.rs:732`
assigns `self.global_sequence + 1`; recovered as `manifest.max_sequence()`
(`:405`, `:483`); gapless only because a single writer serialises (`:712`). A
second region's engine mints the same integers. This is why the plan reaches for
an HLC rather than reusing the sequence.

## Stale claim corrected

The memory index carried *"`seal_max_age=None` AND `seal_aged_parts` has no prod
caller"*. **Both halves are now false.** Two call sites —
`worker/src/command_bus.rs:253` and `worker/src/event_bus.rs:276` — and
`ops/ci/manifests/noetl/cmdbus-writer-statefulset-prod.yaml:84` sets
`NOETL_EHDB_SEAL_MAX_AGE_MS: '5000'`. **VERIFIED in the manifest only; prod was
not touched.** ⚠ Narrow reading: this bounds the **bus** durability window. The
tier has no seal, no parts and no replication at all (correction 1).

## Absence claims, with the denominator

Searched **129 `.rs` files under `ehdb/crates`**: **0** hits for `hlc`,
`hybrid logical`, `truetime`, `external consist`, `commit_ts`, `leaseholder`,
`follower_read`. `raft` = 11 hits, **all prose** arguing against it. `locality`
= 1, a doc comment. `region` = 7 files, **all a segment of an opaque KV/object
key string** (`env=…/region=…/cell=…/shard=…/tenant=…`) that nothing parses —
keys are addressed through a SHA-256 subject digest. Reading that as existing
multi-region support would be the recurring error.

## Decisions taken inline (not blocked on)

- **HLC**, not bounded-ε hardware clocks (we have none) and not a global sequencer (a cross-region
  round trip on the write path, and the external-service dependency
  `self-sufficiency.md` forbids). External consistency via restart-on-uncertainty
  + a **fail-closed max-offset halt** — which needs a peer set, which is why D8 /
  foca adoption (M2a) is a hard prerequisite rather than a nice-to-have.
- **Leaderful per shard, never consensus-replicated ranges** (immutable parts do not conflict;
  `ehdb-l0/src/lib.rs:85` already retires per-shard Raft).
- **Re-derive** cross-region projections from the replicated log; do not
  replicate derived tiers.
- **No MVCC, no 2PC, no distributed transactions.**
- ⚠⚠ **F2b is genuinely open: reads reach REGION at M6/M7; writes stay ZONE.**
  The k8s Lease CAS is per-cluster. Option A (home-cluster authority) through
  M7; option C (embedded consensus scoped to lease records only) as its own RFC
  for M8; **option B (a CAS over a store with no agreement underneath) is never,
  not deferred.**

## Proof discipline baked into every spec

RED→GREEN with a **planted defect**, on a **green baseline**, with a **positive
control**. ⛔ The cross-store parity comparator and
`/api/ehdb/projection-fold/diff/{id}` are forbidden as instruments by name in
every spec — `digest_mismatch` reproduces with the projector OFF (19→20
measured) so it is open and not the projector's; `fold()` omits
`normalise_null_json` while `fold_with_body()` calls it; and the diff endpoint
folds events rather than the snapshot, so it is not on the serve path.
⚠ Do not classify mutants with `grep '^error'` — cargo prints
`error: test failed` for a **caught** mutant.
