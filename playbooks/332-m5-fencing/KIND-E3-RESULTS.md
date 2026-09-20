# M5 E3 / E4 / E6 — kind gate results

**Date:** 2026-09-20 · **Cluster:** kind-noetl · **Image:**
`localhost/noetl-worker-rust:m5fence`, built `--network none` from
worker branch `feat/m5-kube-lease-store`.

**Result: 35 / 35.** Reproduce with `./kind-gate.sh`.

**Prod was not touched.** Verified read-only on exit: `NOETL_EHDB_FENCING`,
`NOETL_EHDB_ELECTION`, `NOETL_EHDB_EVENTLOG_BACKEND`, `NOETL_EHDB_TIER_BACKEND`
and `NOETL_EHDB_HLC` are **unset on all five prod workloads**, no `ehdb-shard-*`
Lease exists in the prod namespace, and every image digest is unchanged.

## The headline is a finding, not the pass

The first run of this gate came back **21 / 4**, and the four failures were the
point.

The race was real: arm A won the Kubernetes Lease (epoch 1), advanced the shared
marker, published a segment; arm B lost the lease (epoch 0), ran with
`ehdb_fencing_active 1` and `ehdb_fencing_enforcing 1` against the same shared
root — and its three appends were **SERVED**, at sequences 1, 2, 3.
`ehdb_fencing_writes_checked_total` read **0**: the ledger was never consulted.

**M5 fencing did not fence.** `FencedSharedBackend` guards `append_segment`, and
`SharedTierEventLog::publish_shard` calls `append_segment` only when the local
segment is longer than what the shared object has already committed
(`if cur_len <= published_len { continue; }` — the incremental-publish
optimisation from ehdb#264). A superseded writer has its own local root, so its
segment is short, so the publish is skipped, so the guard never runs. The writer
is told `served` with a global sequence for an event that is never published and
never refused, living only in a pod-local store that dies with the pod.

A guard on a call that does not happen is the same defect class as a metric on
the wrong registry — and this is its third sighting in the program, after
"fencing is on no live path" and "the recorder exists, nothing calls it".

Two further defects fell out of fixing it, each caught by an added control:

- The refusal was counted nowhere, so `ehdb_fencing_stale_refused_total` read 0
  while every write was being refused. 0 reads as healthy.
- Once counted on the decorator's own series, a shadow-mode stale write that
  *did* publish was counted **twice** (`0 -> 2` for one append). The two vantage
  points measure different populations and are now different series.
- With the mode check at the top of the precheck, **shadow counted nothing at
  all** — a shadow period that answers "0 stale writes" by construction, in the
  mode whose only purpose is to answer that question before enforce is armed.

## What each phase established

| phase | established |
| :-- | :-- |
| the race happened | Both arms completed an election round; the Lease is held by A; A holds epoch 1, B holds 0. Checked **before** the outcome, because a lease nobody contended for would let both arms write and read as "no split brain". |
| E3 | A served 3 / fenced 0. B **fenced 3 / served 0**, refusal text `stale_epoch: shard 0 write at epoch 0 refused; store has already accepted epoch 1`. No split brain. |
| E4 | All six fencing series present and readable on both arms, including at 0. The decorator ran on the elected arm (`writes_checked=3`) and correctly **not** on the refused arm (refused before the append); `precheck_writes=3`, `precheck_stale=3`, `stale_refused=3` on the refused arm and `stale_refused 0` **present** on the elected one. |
| ⭐ negative control | The same race under `shadow`, identical in every other respect: equally stale (epoch 0), writes **SERVED**, refuses nothing — and still **counts** what enforce would have refused (`precheck_stale=3`). Without this arm the refusals above are equally explained by a broken store, a missing volume, or a backend that never worked. |
| E6 | Holder killed; the next acquirer comes back at epoch **2**, `leaseTransitions=2`, its writes served. Monotonic across the holder change — a reused epoch would let a superseded writer's in-flight writes through. |

## The design decisions, stated

- **The check moved to where the write is ACCEPTED**, not where it is published.
  "A stale writer is refused a write" is a statement about the append. The
  refused writer also writes no local segment — a refusal that still accepts the
  bytes is a refusal in name only, and the test asserts that.
- **`highest_epoch`, not `check_and_advance`.** Advancing in the check would
  make the check raise the marker — the shape of ai-meta#264, where the parity
  endpoint wrote the counter its own alert read.
- **The refusal text comes from the crate's own `stale_epoch_error`**, so it is
  byte-identical to the decorator's and `is_stale_epoch` recognises it. A second
  spelling of one condition is how this program lost a counter before.
- **A ledger that cannot be opened returns `None`.** Fencing must not become a
  new way for appends to fail.
- ⚠ **The long-term home is `SharedTierEventLog::append` in `ehdb-reference`.**
  It lives in the worker because that crate is consumed by a pin.

## E4's shape differs from the spec's wording, deliberately

The spec asks for `ehdb_fencing_refused_total{mode}` pinned at 0 for both modes.
The implementation has **no `{mode}` label**: the counter is
`ehdb_fencing_stale_refused_total`, unlabelled and always rendered, beside a
separate `ehdb_fencing_enforcing` gauge.

That is better here. The mode is a per-process configuration, not a property of
a write; a process can only be in one mode at a time. A `{mode="enforce"}`
series on a shadow pod would assert "this pod refused 0 writes in enforce mode"
— a claim about a mode it is not in. The implemented shape carries the same
information with no false series, and the gate pins every value at 0 and proves
each one moves.

## Mutation battery — 8 / 8 CAUGHT

`./mutation-battery.py <worker-checkout>`. Every arm asserts three things,
because each has produced a false SURVIVED in this program: the anchor was
found and the mutation applied, the test actually ran (`running N tests`, N>0),
and the verdict matched. Plus a green BASELINE arm — a red baseline makes every
mutant read CAUGHT.

| # | planted defect | caught by |
| :-- | :-- | :-- |
| F1 | the pre-append precheck is removed (the publish-skip gap returns) | the gap regression test |
| F2 | the precheck refuses under shadow too | the shadow control |
| F3 | the precheck refuses a writer that is not behind | the current-epoch test |
| F4 | the precheck opens the ledger under the local root | the gap regression test |
| F5 | the refusal text is hand-written, not the crate's constructor | the gap regression test |
| F6 | the refusal is not counted (`stale_refused 0` while fencing) | the gap regression test |
| F7 | shadow stops counting (a shadow period that reports 0 by construction) | the shadow control |
| F8 | the precheck sums into the decorator's counter again | the shadow control |

⚠ Three arms came back **ANCHOR NOT FOUND** on one run after a refactor moved
them. That is the battery's "did the mutation actually apply" assertion working
rather than reporting three false SURVIVED.

## One arm honestly uncovered

Deleting the decorator's own `is_stale_epoch` arm now **SURVIVES**, because the
precheck refuses first. That arm covers only the race window — the marker
advancing between the precheck's read and the publish — and no unit test here
can force that interleaving without a hook this code does not have. Said at the
call site rather than papered over with a test that only looks like it covers
it.

## What is NOT proven here

- **Nothing about prod.** kind only; prod flags remain unset.
- **Not the tier.** This is the event-log **bus** write path
  (`NOETL_EHDB_EVENTLOG_BACKEND=durable_segment`). The `primary`-serving tier
  store is a different stack (M0.5).
- **Not under load.** Three appends per arm, one shard, one node. The publish
  contention behaviour of two writers at rate is unmeasured.
- **Not the race window.** See above.
- **Not multi-shard.** Both arms pin `NOETL_SHARD_INDEX=0` deliberately — a
  shard each would elect both and prove nothing.
