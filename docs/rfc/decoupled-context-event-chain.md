# Decoupled context + event chain — the live design, written down

**Status: retrospective.** This documents a design that is *already running in
production*, rather than proposing one. [noetl/ai-meta#115][i115] opened as an
RFC; the implementation shipped through phases 2–6 while the RFC itself was
never written. Every unticked box on that issue is a specification deliverable,
and this file is the attempt to close them against what the code actually does.

Written 2026-08-05 from the source and from measurements on
`shastaratech-noetl-prod`. Where the implementation and the intent disagree,
this file records the implementation and says so.

## Why write it now

The correctness properties below have all been *exercised* by production
incidents, and each was diagnosed from first principles because there was no
written invariant to check an implementation against:

| incident | property it stressed |
| :-- | :-- |
| [#116][i116] execution-affinity write ordering | append ordering across writers |
| [#118][i118] terminal-finalize chain fork | single-terminal / idempotent finalize |
| [#119][i119] WAL-drain cursor stall | drain liveness, cursor durability |
| [#123][i123] loop non-iterable wedge | deterministic drive errors terminate |
| [#203][i203] feed delivery loss | sort-key monotonicity |
| [#208][i208] writer restart | crash recovery, cursor clamping |
| [#227][i227] in-flight resume | rebuildability after restart |

A spec would not have prevented all of them. It would have made several
*checkable* — which is the argument for writing it even now.

## 1. The reference-only data model

A step result lives in one of two shapes in `noetl.event`:

- **inline** — the result JSON is in `event.result`.
- **externalised** — `event.result` carries a `reference` (a
  `noetl://execution/<eid>/result/<step>/<id>` URI) plus `extracted` metadata,
  and the payload lives in the result tier.

The split is a **byte budget**, not a type decision: results over the floor are
externalised, everything else stays inline. Measured on prod, 90 days:

```
call.done events            55,265
…carrying a `reference`        548   (≈1%)
```

So externalisation is the exception, which matters for the read path: a reader
that cannot resolve references still sees ~99% of results.

**Resolution is a read-side concern.** `hydrate_result_references` resolves a
reference when an execution is read back through the API. A reference that
cannot be resolved is left as-is rather than erroring — the event stays
truthful about what was stored.

> **Implementation note that contradicts a naive reading:** the same mechanism
> is used for *command context* (`__context_ref__`), not only results. See
> [#196][i196]. Both share `permanent_log_lean.rs`, and both are gated by one
> flag — so "reference-only results" and "reference-only context" are not
> independently switchable.

## 2. The one-level event chain

Each event carries `prev_event_id`, a single link to its predecessor **within
its execution**. There is no tree and no multi-parent merge: one level, one
pointer.

```
genesis <- e1 <- e2 <- … <- head          (per execution_id)
```

State reconstruction is a **chain walk**: start at the per-execution head,
follow `prev_event_id` to genesis — each hop a primary-key lookup — then feed
the collected events to `WorkflowState::from_events` in `event_id` order.

Measured on prod, 30 days:

```
events carrying prev_event_id   48,988 of 55,311   (88.6%)
```

The remainder are genesis events and event types outside the chained set.

**Why a chain rather than a scan:** the walk is O(chain length) in PK lookups
with no table scan and no `COUNT(*)`, and — critically — the chain is
append-only and immutable, so a spine built for a given head is valid *forever*.
That is what makes the cache below sound rather than best-effort.

## 3. The "never scan `noetl.event`" invariant — precisely scoped

The invariant is frequently stated too broadly. As implemented it is:

> **The orchestration drive path never reads `noetl.event`.**

It is *not* "nothing reads `noetl.event`". The API read path legitimately does,
and must.

| path | reads `noetl.event`? | why |
| :-- | :-- | :-- |
| worker `WalEventIndex` | **never** | sourced from the bus feed, not the materialized table |
| `ExecutionChain::chain_walk` | **never** | walks the in-memory index |
| off-server drive apply | **never** | needs only `catalog_id` + routing from the warm descriptor |
| `services::execution` API reads | **yes** | `get_status`, `is_cancelled`, `resolve_catalog_id`, the list endpoint — all scoped by `execution_id` or paginated |
| crash-recovery rebuild | **yes, deliberately** | the cold path when no warm descriptor exists |

`src/services/execution.rs` contains 13 `FROM noetl.event` references. **None
is a violation** — they are user-facing reads, scoped by execution id. Anyone
auditing the invariant by grepping for the table name will get a false positive,
which is why this section exists.

The honest form of the invariant is therefore about **the hot path and the
scan**: no drive decision may depend on an unbounded query over the event log.

## 4. The cache contract

The built spine is cached by the **immutable** key `(execution_id,
head_event_id)`. Because the chain is append-only, a cached entry for a head can
never become stale — it can only become *superseded* by a longer chain.

Each build reports one of four outcomes, and these are the observable states:

| outcome | meaning | cost |
| :-- | :-- | :-- |
| `CacheHit` | cached head == current head | sub-millisecond |
| `Incremental(n)` | current head extends cached head; only the new tail walked | proportional to `n` |
| `ColdRebuild(n)` | no usable cache — restart, or a pointer gap a tail walk cannot repair | proportional to chain length |
| `Incomplete` | a `prev_event_id` points at an event **not yet in the index** | — |

`Incomplete` is the interesting one and is **not an error**: it is the expected
reading when bus delivery and index application race. The drive must treat it as
*"not yet knowable"* and retry, never as *"the chain is broken"*. Conflating the
two is what [#119][i119] and [#227][i227] both looked like from the outside.

> Until [worker#225][w225] there was no latency measurement per outcome — the
> counter said which path was taken, nothing said what it cost. That is why
> [#156][i156] could quantify the per-hop floor in kind and not on prod.

## 5. Correctness properties

Stated as they are actually enforced, with the mechanism named.

### Ordering

Events are applied in `event_id` order, and `event_id` is an
application-generated snowflake — so ordering is established at *creation*, not
at insertion. A chain walk therefore yields the same order as a table scan
would, which is what makes the two builds equivalent ("parity by construction").

The bus layer adds a second ordering guarantee: the writer assigns the feed sort
key, and a key that fails to advance is a detected fault
(`ehdb_l0_out_of_order_appends`, steady state exactly 0) rather than silent
reordering — the [#203][i203] fix.

### Idempotency

- **Re-issue** is guarded by the `command.issued` fold: a step already in
  `CommandIssued` is not re-issued. This is **state-derived, not key-derived**,
  which means it provides no protection exactly when state cannot be rebuilt —
  see [#228][i228], where prod data shows 515 colliding
  `(execution_id, step, attempt)` groups but only 10 with more than one
  *executed* row. The guard is weak, not absent.
- **Terminal transitions** are once-only via the finalize guard ([#118][i118]).
- **Materialization** is idempotent on redelivery; the bus may redeliver, and
  duplicate keys make that safe.

### Crash recovery

- The writer seals on SIGTERM; an unsealed part is replayed on open and
  truncated to the last intact frame. `ehdb_l0_recovered_active_records > 0`
  means the previous exit did **not** seal ([#209][i209]).
- Consumer cursors are persisted and clamped to the reopened tip on restart, so
  a resumed consumer can never start beyond the data ([#208][i208]).
- A cold drive with no warm descriptor falls back to the rebuild path — the one
  place the drive *does* read `noetl.event`, deliberately.

### Cache vs. chain

The cache is never authoritative. It is an accelerator over an append-only
chain, and every entry is reconstructible by walking from the durable head. The
failure mode to guard is not staleness (impossible, by the immutable key) but
**unbounded growth**, which [#166][i166] Phase 1 addresses with TTL + byte
ceiling + rehydrate-on-miss — live in prod on both system pools.

## 6. What this file does not settle

- **`noetl.execution` is not part of this design.** It is a frozen Python-era
  table that no live code writes ([#235][i235]); status is derived from events.
  It is mentioned only so a reader does not treat it as state.
- **The reference tier's retention** is governed by the write-behind sink work
  ([#198][i198]/[#199][i199]), not here.
- **Whether the 13 API-side event reads should eventually be served from a
  projection** is an open design question, not a defect. Today they are correct.

[i115]: https://github.com/noetl/ai-meta/issues/115
[i116]: https://github.com/noetl/ai-meta/issues/116
[i118]: https://github.com/noetl/ai-meta/issues/118
[i119]: https://github.com/noetl/ai-meta/issues/119
[i123]: https://github.com/noetl/ai-meta/issues/123
[i156]: https://github.com/noetl/ai-meta/issues/156
[i166]: https://github.com/noetl/ai-meta/issues/166
[i196]: https://github.com/noetl/ai-meta/issues/196
[i198]: https://github.com/noetl/ai-meta/issues/198
[i199]: https://github.com/noetl/ai-meta/issues/199
[i203]: https://github.com/noetl/ai-meta/issues/203
[i208]: https://github.com/noetl/ai-meta/issues/208
[i209]: https://github.com/noetl/ai-meta/issues/209
[i227]: https://github.com/noetl/ai-meta/issues/227
[i228]: https://github.com/noetl/ai-meta/issues/228
[i235]: https://github.com/noetl/ai-meta/issues/235
[w225]: https://github.com/noetl/worker/pull/225
