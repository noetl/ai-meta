# Handover — reading order

Four documents, append-only. Read them in this order; each corrects the one
before it, and the corrections are the point.

| # | Document | What it is | Trust |
| :-- | :-- | :-- | :-- |
| 1 | [`FENCING-SUBSTRATE-BUILD-HANDOVER.md`](FENCING-SUBSTRATE-BUILD-HANDOVER.md) | Stages 1–5 (projector, fencing, durable write path, migration, cutover). Written at the accuracy cliff | carries **two withdrawn claims**, both marked |
| 2 | [`TRACE-RESULTS.md`](TRACE-RESULTS.md) | The two gating traces, resolved by measurement | supersedes #1's open unknowns |
| 3 | [`MULTIREGION-EHDB-PLAN.md`](MULTIREGION-EHDB-PLAN.md) | Multi-region EHDB design + phased plan. **Read its §0 correction first** | §0 corrects §1.3/§5/§10 of its own first commit |
| 4 | [`../../../../specs/active/2026-09-18-multiregion-ehdb/`](../../../../specs/active/2026-09-18-multiregion-ehdb/) | 12 implementable specs, one per phase | derived from #3, post-correction |

⚠ **The handover at #1 points at the wrong path for itself.** These documents
are at `loops/active/2026-09-11-ehdb-resilient-core-phases/handover/`, not
`ai-meta/handover/`. The code clones are the ai-meta submodules
`repos/{ehdb,worker,server,ops}`.

## The four facts that cost the most to establish

Each was believed otherwise by a prior session, or by me.

1. ⚠⚠ **The `primary`-serving event-log TIER does not run on `ehdb-l0`.** It is
   `ehdb-reference::LocalReferenceEventLogDriver` over `ehdb-stream` — a
   line-oriented append-only file with `replica` 0, `seal` 0, `manifest` 0 in
   its `lib.rs`. `L0Engine` is in the **same process** (`event_bus.rs:258`) on a
   different port. So ReplicaTarget, FailureDomain, UnreplicatedTracker, parts,
   manifest, `seal_max_age` and cold-load are all real and all on the **bus**
   engines. *"The primitive exists" and "the primitive is on the path" are
   independent questions.*
2. **Prod is on the `Service` branch**, so the durable write path belongs in
   `tier_store.rs:207`, not `eventlog_backend.rs`.
   `NOETL_EHDB_EVENTLOG_BACKEND` is inert for the tier — not dangerous, inert.
3. ⭐ **The fencing epoch is in a per-shard marker, not the frame header**
   (`FRAME_HEADER_LEN` is a fixed 12 bytes shared with `durable_eventlog.rs`).
   **No segment-key migration is needed; the docs saying otherwise are stale.**
4. **`global_sequence` is per-engine, not a global order** (`engine.rs:732`,
   gapless only because one writer serialises, `:712`).

## Corrected stale claim

`NOETL_EHDB_SEAL_MAX_AGE_MS` — previously recorded as unset with no prod caller.
It has **two** call sites (`command_bus.rs:253`, `event_bus.rs:276`) and is set
to `5000` in `ops/ci/manifests/noetl/cmdbus-writer-statefulset-prod.yaml:84`.
**VERIFIED in the manifest only; prod not touched.** It bounds the **bus**
durability window, not the tier's — the tier has no seal at all.

## Still open, carried forward

- **Stage 1 is BLOCKED.** `digest_mismatch` reproduces with the projector **off**
  (19→20 measured), so it is a snapshot-writer-vs-verifier asymmetry, not the
  projector's. The `keep_refs` half is fixed on `noetl/server`
  `fix/verifier-reference-policy` (kind only); a residual `_store` / `extracted`
  split remains. Owner's bar is 0.
- ⛔ Consequently the cross-store parity comparator and
  `/api/ehdb/projection-fold/diff/{id}` are **forbidden as proof instruments**
  in every spec at #4.
- ⚠ `NOETL_PROJECTOR_OWNS_SNAPSHOT=true` with the projector **off** means
  *nobody* writes the snapshot — as wrong an intermediate state as the
  two-writer contention it was added to fix.
- ⚠ Rolling `cmdbus-writer` loses in-flight executions. Drain or quiesce.
