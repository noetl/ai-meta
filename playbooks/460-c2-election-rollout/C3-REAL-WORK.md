# C3 real work — putting the epoch fence on the path the writer uses

Proposal only. **No prod changes, no rolls, no implementation started.**
Follows `C1-ENUMERATION.md`, which measured 624 appends / 290,440 commits
against **0** fence checks.

## The constraint that decides everything

⚠⚠ **Appends do not go through `DurableSubstrate`.** `part.rs` carries **14
direct file-I/O sites** and is the active-part writer; the substrate is used for
*sealed* parts, the manifest, the cursor and deletes. Measured:

| module | direct file I/O | substrate mutators |
| :-- | --: | --: |
| `part.rs` | **14** | 0 |
| `engine.rs` | 2 | 6 |
| `substrate.rs` | 4 | 12 |
| `cursor.rs` | 0 | 2 |
| `chain_store_durable.rs` | 0 | 6 |

So a fence at the substrate and a fence at the append path cover **different**
halves. Any single-seam option has a hole, and the dangerous part is that
`writes_checked` would climb through the covered half and read as complete —
a partially-covering fence reporting as a whole one, which is worse than today's
honest zero.

## Option A — `FencedSubstrate<S>` decorator

Mirror `FencedSharedBackend` one layer down.

- **Files:** `crates/ehdb-l0/src/substrate.rs` (new decorator beside the existing
  `CountingSubstrate<S>`, which already proves the seam), wiring in
  `crates/ehdb-l0/src/engine.rs` (`open`/`open_replicated`), and the two worker
  construction sites (`command_bus.rs`, `event_bus.rs`).
- **Covers:** sealed-part writes, manifest `LATEST` + versioned, cursor commits
  (`cursor.rs` uses the substrate), retention/reclaim `delete`.
- ❌ **Hole: the hot append path.** `part.rs` writes the active part directly.
- ⚠ `CountingSubstrate`'s own comment names the trap to copy: forward
  `failure_domain()`, never default it, or a validated replica set silently reads
  `Undeclared`.
- **Risk: medium-high, and mostly epistemic** — it would look like it worked.
- **Effort:** ~1 day + validation.

## Option B — `FeedWriter::append*`

- **Files:** `crates/ehdb-feed/src/lib.rs` — **three** entry points (`append`
  :383, `append_batch_reporting` :434, `append_batch` :461).
- **Covers:** the hot path only.
- ❌ **Holes:** seal, manifest, cursor, retention, merges — everything the engine
  does on its own schedule. ⚠ Three entry points is the M5 shape exactly: fence
  two and the third is the publish path nobody checked.
- **Risk: high** for the same reason as A, with a smaller covered fraction.
- **Effort:** ~0.5 day.

## ⭐ Option C — the `L0Engine` `&mut self` chokepoint (recommended)

- **Files:** `crates/ehdb-l0/src/engine.rs`; an epoch holder on `L0Config` /
  `L0Engine`; `command_bus.rs` + `event_bus.rs` to supply the token.
- **Covers: everything the engine owns** — the 12 `&mut self` methods:
  `append_record`, `append_writer_assigned`, both `*_reporting` variants,
  `flush_and_wait_uploads`, `seal_aged_parts`, `run_pending_merges`,
  `reclaim_orphans`, `apply_retention`, `apply_retention_keep_last`, plus
  `take_sync_handles` / `set_flush_policy`. Because `part.rs` is reached only
  from `engine.rs` (2 refs) and `chain_cert.rs` (1), the engine is the real
  chokepoint for file-level writes **and** for the substrate writes it makes.
- ⭐⭐ **The denominator is compiler-enforced.** Every durable mutation needs
  `&mut L0Engine`, so the enumeration is "the 12 `&mut self` methods" — checked
  by the borrow checker, not by a grep that can miss an idiom. That is a
  materially stronger guarantee than every other option here, and directly
  answers the C1 acceptance that defeated the current design.
- ❌ **Known hole: the cursor store.** `cursor` is re-exported from `ehdb-feed`
  as `CursorStore` and commits outside the engine. It must be fenced separately
  or explicitly scoped out — a stale cursor commit rewinds a resume position
  rather than corrupting the log, so it is a lesser harm, but it must be
  *stated*, not forgotten.
- **Risk: medium.** It touches the hot append path, so a bug is a dispatch
  outage. Mitigated by the fence being a cheap atomic compare before the write,
  and by shadow mode being a pure counter.
- **Effort:** ~2 days + validation.

## Option D — move the writer onto `durable_segment`

- **Files:** none in ehdb; set `NOETL_EHDB_EVENTLOG_BACKEND=durable_segment`
  and whatever `SharedTierEventLog` needs for the cmdbus/eventbus roles.
- **Covers:** everything the existing fence covers, for free.
- ❌ **It changes the writer's entire storage engine.** A different durability
  model, different recovery, different performance, on the one workload that
  hosts both buses, where ~5 h of appends and 290k commits currently flow
  through `L0Engine`. The fence is the smallest reason to do this.
- **Risk: very high.** ⚠ And it is not actually a C3 change — it is a storage
  migration that happens to bring a fence.
- **Effort:** weeks, with its own program.

## Kind validation that would prove coverage (identical for A–C)

The gate is coverage, so the validation must produce a **non-zero denominator**.
⚠ My first attempt at measuring this in kind was worthless because the kind
writer sat at `ehdb_l0_appends 0` — a flat fence counter against zero appends
proves nothing, the same "coverage was ~0 by construction" trap as #307.

1. **Generate real appends in kind** and prove it: `ehdb_l0_appends` on `:9102`
   must climb across two samples. This is the denominator and it comes first.
2. With `NOETL_EHDB_FENCING=shadow` and the election on, assert **together**:
   - `ehdb_fencing_writes_checked_total` **climbing**, and its delta
     commensurate with the append delta — not merely non-zero;
   - `ehdb_fencing_epoch_advances_total` **≥ 1** (the marker actually moved, so
     the fence received a real epoch rather than 0);
   - `ehdb_fencing_stale_observed_total` **0** with one writer.
3. ⭐ **A positive control for refusal.** Force a stale write and see it counted:
   run a second engine instance against the same directory with a lower epoch and
   assert `stale_observed` increments in shadow, then `stale_refused` under
   enforce. A fence that has never once refused is indistinguishable from one
   that cannot.
4. **Per-path coverage, not aggregate.** Exercise each of the 12 `&mut self`
   methods and assert the counter moves for each — otherwise "climbing" could be
   appends alone while seal and retention stay unfenced, which is precisely the
   partial-coverage failure this whole exercise is about.
5. Only then prod: shadow → observe for ≥ one seal interval → enforce.

## ⭐ How to finally measure δ (inter-node clock skew)

δ bounds the divergence window in `C3-BOUND.md` and is still unmeasured. My
read-only attempt (spread of kubelet-written node `Lease` renewTimes) conflates
skew with renewal staleness and bounded nothing.

**The adapter is already making the measurement available and discarding it.**
Every lease renewal is an HTTP round-trip to the API server, and the response
carries a `Date` header — a reading of the *same* reference clock from every
node. So:

1. In `KubeLeaseStore::send`, read the `Date` response header and record
   `local_now - server_date` as `ehdb_election_clock_offset_seconds`.
2. δ between any two writers is then `|offset_a − offset_b|`, both measured
   against one reference, which is exactly the quantity the bound needs.
3. ⚠ **Granularity is the honest limit.** HTTP-date is whole seconds, so this
   bounds δ to about ±1 s and cannot prove sub-second skew. For a 15 s lease that
   is sufficient — it turns "unmeasured" into "≤ ~1 s" — and the bound should be
   published as `lease + renew + 1 s` rather than implying better.
4. ⚠ Record the *offset*, not a corrected clock. Nothing should ever use this to
   adjust lease arithmetic; a self-correcting clock would make the two writers
   disagree about expiry in a way neither could observe.

## Recommendation

**Option C**, with the cursor store fenced in the same change or explicitly
scoped out in writing. It is the only option whose coverage claim is backed by
the type system rather than by a search, and C1's acceptance is precisely the
thing a search failed to establish for the current design.

Do **not** take Option D for fencing's sake.
