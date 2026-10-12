# C1 — every durable-state mutation path, and whether the fence covers it

noetl/ai-meta#460 C1, as the C3 precondition. Survey 2026-10-11, read-only.

**Result: C1's acceptance cannot be satisfied as stated, and C3 has a hard
blocker that is not RBAC and not availability.** Details below; the blocker is
§3.

## 1. The fenced trait — complete, and M5's narrow guard is already fixed

`ehdb_reference::fencing::FencedSharedBackend` decorates **`SharedSegmentBackend`**
(`crates/ehdb-reference/src/durable_eventlog_shared.rs:190`).

Denominator: the trait has **9 methods**, of which **4 mutate**. The decorator
overrides **9 of 9**.

| method | mutates | `self.guard(shard)?` |
| :-- | :-- | :-- |
| `put_segment` | yes | ✅ |
| `append_segment` | yes | ✅ |
| `put_reclaim_watermark` | yes | ✅ |
| `delete_segment` | yes | ✅ |
| `get_segment`, `list_segment_ids`, `reclaim_watermark`, `committed_len`, `backend_name` | no | pass-through (correct — fencing governs writes) |

⚠ **5 of the 9 have default bodies** (`append_segment`, `committed_len`,
`put_reclaim_watermark`, `reclaim_watermark`, `delete_segment`). A mutating
default the decorator did *not* override would run the trait's own body and
bypass `guard` entirely. It overrides all of them, so nothing leaks — but this is
the M5 shape exactly, one language feature lower, and it is why the check was
"9 of 9 overridden" rather than "the 4 mutators look guarded".

M5's finding (the guard sat on `append_segment` while the publish path skipped
it) is addressed: the in-code comments show `put_reclaim_watermark` and
`delete_segment` were added precisely because fencing only the two named methods
"would have left this and `delete_segment` open".

**So within its own trait the fence is airtight.**

## 2. Durable state mutated OUTSIDE the fence — substantial, and excluded by other means

⚠ `fencing.rs` mentions `DurableSubstrate` **zero** times. That is the L0 trait
(`crates/ehdb-l0/src/substrate.rs:49`) through which parts, manifests, cursors
and tail objects are written. Its three mutators:

| mutator | clobber-safe? | notable call sites |
| :-- | :-- | :-- |
| `put_if_absent` | ✅ write-once by construction | sealed parts, events, blobs, **versioned manifest snapshots** |
| `put_overwrite` | ❌ clobbers | **manifest `LATEST`** (`engine.rs:1879`), shard cursor (`cursor.rs:76`), chain head (`chain_store_durable.rs:196,287`), coverage keys (`chain_populator.rs:433,596`) |
| `delete` | ❌ destructive | manifest version pruning, tail reclaim, retention |

None of these pass the fence, and **they cannot** — the fence decorates a
different trait. So "every durable-state mutation passes the fence" is not an
achievable acceptance; the achievable one is *every mutation is excluded by a
named mechanism*:

| path | process | exclusion mechanism today |
| :-- | :-- | :-- |
| shared segment backend | writer | the fence (when on) **over** an RWO volume |
| L0 substrate, local | writer | ⭐ **`ReadWriteOnce` PVC attachment** — `premium-rwo`, verified on all three writer PVCs. Two pods physically cannot both mount it |
| L0 substrate, off-box GCS replica | **server**, not the writer | `replicas: 1`, and the server *cannot* be canaried (`NOETL_SERVER_MACHINE_ID=2` is pinned in the pod template, so a second replica duplicates `event_id`) |

⚠ I had this wrong at first and corrected it from the cluster: the GCS replica
env (`NOETL_EHDB_REPLICA_GCS_BUCKET`, `NOETL_EHDB_TAIL_REPLICATION`) is on
`sts/noetl-server-rust-embedded`. The **writer has no GCS or replica env at
all**. So the shared-object split-brain surface I expected to find on the writer
is not there.

RWO attachment is a real physical primitive, and stronger than the fence.
`replicas: 1` is an orchestration preference — which is the whole argument for
the election.

## 3. ⚠⚠ The C3 blocker: the election's epoch never reaches the fence

`FencedSharedBackend` learns the writer's token through **`set_epoch`**
(`fencing.rs:304`). Measured, with a working positive control (`with_metrics`,
found in 6 ehdb files and 1 worker file by the same grep):

> **`set_epoch` has one definition and ZERO non-test callers.**
> The only callers are `crates/ehdb-reference/tests/fencing_shadow.rs` and
> `crates/ehdb-reference/tests/election_drives_fencing.rs` — a test that
> demonstrates exactly the wiring production does not have.

The chain is broken in the middle:

```
election mints epoch -> ElectionState -> /metrics      ✅ (noetl/worker#353)
                                     -> set_epoch      ❌ NOTHING
                                     -> guard()        -> enforce
```

So `guard()` reads `self.epoch()` = **0**, and `check_and_advance(shard, 0)`
gives two regimes, both wrong:

- **Ledger empty** (prod today — fencing is `off`, so `shared_root/.fencing` was
  never created): `0 < 0` is false, `advanced = 0 > 0` is false ⇒
  `Fresh{advanced:false}`, the write proceeds, **and no marker is ever written**.
  `highest` stays 0 forever, so nothing can ever be stale. ⚠⚠ **An enforcing
  fence that cannot refuse anything, reporting `writes_checked` climbing and
  `stale_observed 0`** — which is precisely the reading an operator would accept
  as proof it works. The repo already knows this trap; the missing call
  reintroduces it one level up.
- **Ledger holds any marker > 0**: every mutating write is `Stale` ⇒ in enforce,
  `Err` on all of them. Immediate outage.

⭐ **`epoch_advances` is the discriminator.** If it stays 0 while
`writes_checked` climbs, the fence is inert regardless of what `stale_observed`
says. Any C3 acceptance must gate on `epoch_advances > 0`.

**C3 therefore needs a third code change** — feeding the election's token into
the fence — and it must feed **`token_valid`**, not `holds_lease`: a writer that
has lost API contact must stop asserting its token, and `holds_lease` would keep
asserting it.

This is the non-negotiable order made concrete: minting into a *gauge* is not
minting into the *fence*. "Election live and minting" was satisfiable by #353 at
the observability layer while leaving enforce exactly as unsafe as before.

## 4. Two latent weaknesses in the manifest path (independent of fencing)

Found while enumerating; neither is caused by C2/C3 and both affect recovery.

1. ⚠ **`LATEST` is the only manifest anything reads, and it is `put_overwrite`.**
   `write_manifest_to_all` also writes a write-once versioned snapshot per
   version — and `engine.rs:1891` states plainly that **nothing has ever read
   one**. So the artefact that could disambiguate a clobbered or stale `LATEST`
   exists, is retained, and is unreached.
   Credit where due: `prune_manifest_versions` always drops the **oldest** and
   keeps the newest N, so a lagging writer cannot delete a newer snapshot.
2. ⚠ **`load_durable_manifest` takes the first replica that has it, not the
   highest version** (`engine.rs:2001`), while `write_manifest_to_all` is
   best-effort per replica (`let _ = put_overwrite`). A replica that was
   unreachable during a write keeps its older `LATEST`; if it sorts earlier,
   recovery silently loads the older manifest. The parts referenced only by the
   newer one still exist as objects but become unreferenced — bounded
   consistent-prefix loss on recovery, exactly the property A2/A3 claims to
   bound, decided by replica *order* rather than by version.

Worth its own issue against noetl/ehdb regardless of the C2/C3 arc.

## 5. What C1 can honestly assert

- ✅ Every mutator of the fenced trait is guarded; 9/9 methods overridden; no
  default body bypasses the guard.
- ✅ Every durable-state mutation outside that trait is excluded today by a
  **named** mechanism — RWO attachment for the writer, `replicas: 1` plus the
  pinned machine-id for the server — not by the fence, and not by assumption.
- ❌ "Every mutation passes the fence" is **not achievable**: two traits mutate
  durable state and the fence decorates one.
- ⛔ **C3 is blocked on §3**, before any availability trade is even considered.

---

# ⛔ 2026-10-12 — C1 COMPLETED, AND IT FAILS THE C3 GATE

The enumeration above asked which mutators of the fenced trait are guarded. That
was the wrong question to stop at. The right one — **which paths the prod writer
actually uses** — has a worse answer.

## The fence is not on the live write path at all

`FencedSharedBackend` exists only inside `build_durable_stack`, which is reached
only from `EventLogStorageBackend::DurableSegment`:

```rust
EventLogStorageBackend::DurableSegment => { … let stack = build_durable_stack(env, contract)?; … }
```

That requires `NOETL_EHDB_EVENTLOG_BACKEND=durable_segment`. On the prod writer
that variable is **ABSENT** (so is `NOETL_EHDB_ENABLED`). And the live bus paths
never mention the trait:

| file | `SharedSegmentBackend` | `build_durable_stack` | `L0Engine`/`FeedWriter` |
| :-- | --: | --: | --: |
| `command_bus.rs` | **0** | **0** | 7 |
| `event_bus.rs` | **0** | **0** | 8 |

The command bus and event bus write through `L0Engine` + `FeedWriter` over
`LocalFsSubstrate` — i.e. through `DurableSubstrate`, which
[`fencing.rs` mentions zero times](#2-durable-state-mutated-outside-the-fence--substantial-and-excluded-by-other-means).

## ⭐ Measured on prod, with a denominator, and without a roll

`metrics_server.rs:171` renders the fencing block when
`fencing != Off || checked > 0`. Prod has `fencing == Off` **and the block is
absent**, so the second disjunct is false too — therefore `writes_checked == 0`.
Against that, the same writer's own counters:

| | |
| :-- | --: |
| `ehdb_l0_appends` (cmdbus engine) | **624** |
| `ehdb_feed_shard_committed{shard="0"}` | **290,440** |
| `ehdb_fencing_writes_checked_total` | **0** |

**624 real appends and 290,440 commits have passed through this writer, and not
one of them was checked by the fence.** That is coverage, not idleness — the
distinction my kind attempt could not make, because the kind writer showed
`ehdb_l0_appends 0` and a flat counter there would have proved nothing.

## Full path list for the prod writer

| durable-state mutation | reaches the fence? |
| :-- | :-- |
| `L0Engine::append_record*` / `append_writer_assigned*` via `FeedWriter` — the command- and event-bus hot path | ❌ |
| seal, on append and via `seal_aged_parts` (armed: `NOETL_EHDB_SEAL_MAX_AGE_MS=5000`) | ❌ |
| manifest `LATEST` (`put_overwrite`) + versioned snapshot (`put_if_absent`) | ❌ |
| shard cursor commit (`cursor.rs`, `put_overwrite`) | ❌ |
| `reclaim_orphans` / `apply_retention*` / substrate `delete` | ❌ |
| tier-service store writes (`:9110`, `NOETL_EHDB_TIER_SERVICE_DIR` set) | ❌ |
| `run_pending_merges`, `flush_and_wait_uploads` | ❌ |
| `SharedSegmentBackend::{put_segment, append_segment, put_reclaim_watermark, delete_segment}` | ✅ — **but unreachable on this deployment** |

> **0 of the live durable-mutation paths pass the fence.**

## What arming enforce would actually do

Nothing. The decorator is never constructed, so `guard()` is never called:
`writes_checked` stays 0, `epoch_advances` stays 0, `stale_observed` and
`stale_refused` stay 0, and `ehdb_fencing_active` reads **1**.

⚠⚠ A completely inert fence that reports as a healthy one. This is the M5 lesson
generalised one level up: M5 was *"the guard is on `append_segment` and the
publish path skips it"*; this is **"the guard is on a backend this deployment
does not use"**.

⭐ The acceptance table in [`C3-BOUND.md`](C3-BOUND.md) catches it — it requires
`writes_checked` **climbing** and `epoch_advances ≥ 1`, and neither can happen.
That gate was written before this was known and it fires correctly.

## What C3 would need

Not an env flip. The epoch check has to sit on the path the writer uses — inside
`FeedWriter::append` / `L0Engine`'s mutators, or on `DurableSubstrate` — which is
a design change in ehdb, with its own kind validation. Alternatively the writer
would have to be moved onto the `durable_segment` backend, which is a far larger
change than arming a flag.

**C2 is unaffected and remains live**: epoch 1, 3,424 renewals, 0 losses, 0
errors. The election mints a correct token. There is simply nothing on the write
path consuming it yet.
