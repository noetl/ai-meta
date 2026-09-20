# Where digest / projector / fencing / L0 stand — and what an ehdb release needs

**2026-09-20.** Nothing in this document has been deployed to prod. All four
flags (`NOETL_EHDB_FENCING`, `NOETL_EHDB_ELECTION`, `NOETL_EHDB_EVENTLOG_BACKEND`,
`NOETL_EHDB_TIER_BACKEND`, `NOETL_EHDB_HLC`) are **unset on all five prod
workloads**, no `ehdb-shard-*` Lease exists in prod, and every prod image digest
is unchanged. Verified read-only.

## 1. Status for a prod decision

| | state | proven by | my read |
| :-- | :-- | :-- | :-- |
| **digest** | ✅ fixed, **not deployed** | `digest_mismatch → 0` on big-parent through the REAL serve path (`ehdb_projection_fold.rs:1639`), RED→GREEN with a planted defect | **Ready to ship on its own merits.** The lowest-risk of the four. |
| **projector** | ⚠️ unblocked, **not proven on prod data** | the digest fix removes the gate it was waiting on | **Not ready.** Needs a prod-shaped coverage measurement first. |
| **fencing (M5)** | ✅ E3/E4/E6 proven in kind (35/35) — **after the gate found it did not fence** | `playbooks/332-m5-fencing/KIND-E3-RESULTS.md` | **Do not arm in prod yet.** Three reasons below. |
| **L0 (M0.5)** | ✅ E1–E5 complete, **inert** | `M05-E2-E5-RESULTS.md`, battery 7/7 | **Safe to merge; leave the flag at `local_reference`.** |

### digest — the one I would ship

Two changes in `ehdb_projection_fold.rs`: the recovery ladder's **spine** rung
now hydrates (it was the third un-hydrated leg), and `fold()` normalises null
JSON the same way `fold_with_body()` always did. Both are on the serve path, not
on `/api/ehdb/projection-fold/diff/{id}` — which folds tier EVENTS, not the
snapshot, and is not on the serve path at all.

Carries a positive control (`hydration_is_load_bearing_for_the_digest`) and two
"both entry points agree" properties, so a future divergence between the two
fold paths fails a test instead of a digest.

**Risk:** it changes what the serve path returns for executions whose events
carry references. That is the bug, but it is a behaviour change on a live read
path and deserves its own roll rather than riding with anything else.

### projector — the gate cleared, the evidence did not arrive

`NOETL_PROJECTOR_ENABLED` + `NOETL_PROJECTOR_OWNS_SNAPSHOT` were held on the
digest. The digest is fixed; **prod coverage is still unmeasured**. The
recorded precedent is exact: a 13-event execution can complete and
`noetl.projection_snapshot` gets no row, so "0 divergences" over a population
the mirror was never offered is the vacuous pass. Arming the projector before a
coverage denominator exists repeats that.

**What I would want first:** a shadow window with coverage as a denominator, not
divergence alone.

### fencing — proven, and still not ready for prod

The kind gate is genuinely end-to-end: real Kubernetes Lease, real CAS, a stale
writer refused on every append with the store's own `stale_epoch` text, zero
writes through, epoch monotone across a holder change, and a shadow arm proving
`enforce` is what refuses. But:

1. **The fix lives in the worker, not the engine.** The right home for the
   pre-append check is `SharedTierEventLog::append` in `ehdb-reference`. It is
   in the worker because that crate is consumed by a pin. Anything else opening
   that stack — the server's embedded engine, a future tier driver — is **not**
   protected by it.
2. **One arm is honestly uncovered:** the marker advancing between the
   precheck's read and the publish. Small window, real, untested.
3. **Prod has never run `durable_segment` at all.** Fencing only exists on that
   path. Arming fencing in prod means first arming a storage backend prod has
   never used — two changes, not one, and the second is the larger.

**Recommended order if the owner wants fencing in prod:** `durable_segment` on a
non-serving workload first → fencing `shadow` (which now genuinely counts, see
the results) → read `ehdb_fencing_precheck_stale_total` for a real window →
`enforce` only if that number is understood.

### L0 / M0.5 — done and deliberately inert

`NOETL_EHDB_TIER_BACKEND` defaults to `local_reference`, the dispatch is
byte-identical to today over 64 appends, a store written by one backend is
refused by the other rather than misparsed, and a broken `l0` store refuses
rather than silently falling back. `ehdb_tier_backend_info{backend}` says which
engine is running, pinned for both values.

**Safe to merge with the flag at its default.** Flipping it on the
`primary`-serving tier is a separate decision with a data-migration question
attached (the two backends do not share sequence semantics) — out of scope here
by the spec's own words.

## 2. What an ehdb release would need to contain

### The pins today

| consumer | crates | pinned by |
| :-- | :-- | :-- |
| **server** | `ehdb-feed`, `ehdb-l0` | **tag `v0.2.0`** |
| **worker** | `ehdb-core`, `ehdb-reference`, `ehdb-service`, `ehdb-feed` | **rev `49fdefcc`** |

Note the asymmetry: **the worker does not depend on `ehdb-l0` at all**, and the
server does not depend on `ehdb-reference`. That decides most of what follows.

### What is waiting on a release

Branch `feat/write-side-wiring` is **10 commits ahead of `origin/main`, 0
behind**, and touches exactly two crates: **`ehdb-l0`** (22 files) and
**`ehdb-core`** (3 files).

| milestone | crate | consumable by |
| :-- | :-- | :-- |
| M1 `Locality` on `ReplicaTarget` | `ehdb-l0` | server only |
| M4 `RegionPlacement` / `SurvivalGoal` | `ehdb-l0` | server only |
| M2 HLC clock + `EventRecord.commit_hlc` | `ehdb-core` + `ehdb-l0` | server (l0) and worker (core) |
| M2a membership policy over D8, M3 closed timestamps, M6/M7/M8 scaffolds | `ehdb-l0` | server only |

**M5 fencing needs no ehdb release.** `fencing.rs` and `election.rs` are already
in `ehdb-reference` at the pinned rev `49fdefcc`; everything I built for M5 is
worker-side. (Moving the pre-append check into `SharedTierEventLog::append`
*would* need one — that is the item worth a release, more than the wiring is.)

### A release would need, concretely

1. **Merge `feat/write-side-wiring` to `noetl/ehdb` main.** It is 0 behind, so
   this is a fast-forward-shaped merge.
2. **Tag it `v0.3.0`** — a minor bump. Everything in the range is additive: new
   types, new optional field, new flags defaulting off.
3. **Server** moves `ehdb-feed` + `ehdb-l0` from `tag = "v0.2.0"` to the new
   tag. This is the change that makes M1/M4/M2a/M3 consumable at all.
4. **Worker** moves its four crates from `rev = "49fdefcc"` to the same tag —
   optional for the wiring (it needs only `ehdb-core` for the HLC type), but
   it ends the drift the server's own comment warns about: *"the rev pins let
   two consumers drift 70 commits apart on the same engine … a corruption
   vector once both open engines against one on-disk layout."* `49fdefcc` is an
   **ancestor of v0.2.0**, so the worker is currently behind the server.

### Why this is a safe release to cut — checked, not assumed

- **`FORMAT_VERSION` is unchanged** across the range. The layout gate that
  "refuses a layout it cannot read" does not trip.
- **`EventRecord` has no `deny_unknown_fields`** (removed deliberately, with a
  comment saying why), so a binary predating `commit_hlc` tolerates a record
  carrying it instead of erroring.
- **`commit_hlc` is `Option<u64>` with `skip_serializing_if`**, and `HlcMode`
  defaults to **Off**. With `NOETL_EHDB_HLC` unset the field is not serialised
  at all, so the bytes are identical to today. Six tests hold that.
- **Every new flag is off by default** and `M6/M7/M8` refuse activation.

So the release is backward- and forward-compatible in both directions, and a
server that takes it without setting any flag behaves as it does now. That is
the property that makes it worth cutting *before* anyone wants the behaviour.

### What the release does NOT give you

Consuming it changes **nothing observable** until a flag is set. M1 locality is
declared and consulted by the placement check only when a survival goal is set;
M2 stamps only under `NOETL_EHDB_HLC`; M3/M2a/M6/M7/M8 are predicates and
scaffolds with no callers on a serving path. That is by design — but it means
the release is an *enabling* step, not a shippable improvement, and should be
judged as such.

## 3. Branches, all pushed, none merged

| repo | branch | head |
| :-- | :-- | :-- |
| server | `fix/verifier-reference-policy` | `eb31ef25` — the digest fix |
| worker | `feat/m5-kube-lease-store` | `11b9485` — election + fencing + the E3 fix |
| worker | `feat/m05-tier-backend` | `7195d47` — M0.5 E1–E5 |
| ehdb | `feat/write-side-wiring` | `271beaf` — M1/M2/M4 + the read-side session's M1/M2a/M3 |

## 4. One prod observation, not mine

`noetl-server-rust` is scaled to **0/0** and `noetl-server-rust-embedded` is
1/1. I did not touch prod; flagging it because the memory index still records a
single 1/1 server deployment, so one of the two representations is stale.
