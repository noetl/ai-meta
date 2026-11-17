---
spec: 2026-09-30-chain-certified-projections
status: draft
created: 2026-09-30T00:00:00Z
owner: claude
---

# Chain-Certified Projections — validate instead of re-fold

**DESIGN ONLY.** No code change, no prod change. Written against `main` as checked
out under `ai-meta/repos/` on 2026-09-30.

## Problem

EHDB establishes that a stored projection is valid by **re-folding the event chain
and comparing the output digest**. `ReFoldVerdict`
(`server/src/handlers/ehdb_projection_fold.rs:826`) is that oracle, and its
`DigestMismatch` / `StoredAheadOfSpine` / `StoredBehindSpine` variants are the
outcomes of a recomputation. Production measured **19,840 refolds** during the D3
serve work.

That is the cost this spec attacks, and the reason it exists is a gap in *what* is
digested:

> `canonical_state_digest` (`noetl_orchestrate_core::state`) digests the **folded
> output**. Nothing digests the **input chain**.

So "is this stored state still valid?" can only be answered by redoing the fold. A
digest over the *input* answers it in O(1) — and, less obviously, turns projection
replication into a monotone join, which is what makes it coordination-free.

⚠ **This is a constant-factor and coordination-elimination proposal, not an
asymptotic one.** §5 states that plainly, including the three things it does not
make faster at all.

## ⚠⚠ Revision 2026-09-30 — the benchmark falsified this spec's append claim

Measured in [noetl/server#480](https://github.com/noetl/server/pull/480). Recorded
here rather than quietly amended, because the falsified claim was the confident one.

**Confirmed:** validation O(n) → O(1) — ≥519× at 36 events to ≥59,818× at 10,000, with
p99 flat at ratio **1.00× over a 277× longer chain**. Refolds **99.80%** eliminated
(19,840 polls → 19,801 avoided, 39 genuine). Both gates met.

**Falsified:** *"append throughput unchanged **by construction**"*. It is not
unconditional, and "by construction" was the error — a claim about an
implementation I had not measured.

| events per fsync | baseline | certified | delta | ±2% gate |
| --: | --: | --: | --: | :-- |
| 1 | 240/s | 239/s | −0.73% | holds |
| 17 | 3,450/s | 3,434/s | −0.47% | holds |
| **512** | 78,920/s | 65,533/s | **−16.96%** | **BREAKS** |
| 2,000 | 163,017/s | 106,046/s | **−34.95%** | **BREAKS** |

The gate held only where one `fsync` covers one event, because a 3.0 ms `fsync`
(measured) dilutes everything. **EHDB group-commits**: `MAX_COMMIT_BATCH = 512`
(`ehdb-feed/src/publish.rs:46`), `EHDB_FEED_BATCH_LIMIT` default 2,000. Break-even is
~17 events per `fsync`, and the measured curve crosses where that predicts.

⚠ **And reusing the serialisation does not rescue it.** A floor arm digesting the bytes
the append already produced measured −27.37% against −26.84% — i.e. no better. **The
cost is SHA-256 itself, not duplicate serialisation.** That kills the "just reuse the
bytes" fix and forces the redesign in §2.2.

Decomposing 512-column: 6.49 ms → 7.81 ms per batch = **2.59 µs per event**. SHA-256
over a ~500 B body is ~0.39 µs at 1.3 GB/s, so roughly **2.2 µs of that is
per-invocation cost** (init, finalize, allocation) and only ~0.4 µs is bytes. That
split is what the redesign exploits.

## Goals

- Answer "is this projection valid for this chain?" in O(1) rather than O(n) refold.
- Make projection convergence between replicas coordination-free, with a proof
  obligation discharged in §3 rather than asserted.
- Remove the per-poll chain read from the drive-decision path.
- Make a cross-region projection read local.
- Keep the append cost **inside the ±2% gate at the 512-event commit batch** — by
  amortising the digest over the batch rather than paying it per event. ⚠ A *target to
  be measured*, not a construction claim; §5 says what falsifies it.
- Change nothing about the **ordering semantics** of the leaderful per-shard append
  path (single writer, gapless `global_sequence`).

## Non-Goals

- Faster appends. ⚠ **Revised:** the original wording here was "this touches neither",
  which the §0 benchmark falsified — the design *does* touch the append path, adding one
  8-byte `update` per event and one `finalize` per execution per commit batch. The
  non-goal is that appends get no *faster*; the obligation is that they get no
  measurably *slower* (±2% at the 512 batch), and that obligation is now a gate in §4
  rather than an assumption.
- Region-survivable **writes**. That is fork F2b in the multi-region plan and stays
  open. This spec buys reads and decisions, not write failover.
- Multi-key transactions, MVCC, or a query engine.
- Any external datastore, service, or new runtime dependency.

## Constraints inherited (not re-litigated here)

- **C1** — no consensus for storage. Immutable parts + N-way copy; per-shard Raft is
  retired (`ehdb-l0/src/lib.rs:85`).
- **C2** — ordering is **leaderful per shard**, and that is load-bearing:
  `global_sequence` is gapless and ascending *because one writer serialises*
  (`engine.rs:712`). One writer per shard globally, at any instant.
- **C3** — `FRAME_HEADER_LEN` is frozen at 12 bytes. Every new field goes in the
  record body as `Option<T>` + `skip_serializing_if`, or in an out-of-band marker.
- **The #362 chain invariant** — exactly one NULL-`prev_event_id` event per
  `execution_id`; every other event links to its predecessor; order comes from the
  links, never from sorting `event_id` (a snowflake minted before insert, so commit
  order is not id order).
- **Self-sufficiency** — EHDB is the internal database. `sha2` is already a workspace
  dependency (`ehdb-storage`, `ehdb-slm-context`), so the digest below adds **no new
  dependency**.

---

## 1. Prior art — what is new to the world, and what is only new here

⚠ **Nothing in the primitives below is new to the world.** Every mechanism is
decades old. Stating that first, because an originality claim without this section
is worthless.

| Mechanism | Established as | Status here |
| :-- | :-- | :-- |
| **Hash-linked records** — each entry commits to its predecessor, so a prefix is tamper-evident | Cryptographic hash chains; timestamping/notarisation literature from 1990–91 onward | **Not new.** Not present in EHDB: 0 hits for `merkle`/`prev_digest`/hash-chain across `ehdb/crates`. **New to this codebase only.** |
| **Prefix-verifiable append-only logs with a compact head** — a small signed/hashed head proves a prefix, so auditors converge without shipping the log | Transparency-log designs (Merkle tree heads, consistency proofs) | **Not new.** Directly analogous to the certificate in §2.2. |
| **Monotone programs need no coordination** — a program has a consistent coordination-free distributed implementation iff it is monotone | The CALM theorem (Hellerstein; Ameloot et al.) | **Not new.** Used here as the *proof technique*, and §3 takes it seriously enough to find where monotonicity fails. |
| **Join-semilattice replicated state** — merge is commutative, associative, idempotent, so replicas converge without agreement | Convergent/commutative replicated data types | **Not new.** The lattice in §2.3 is the standard prefix lattice; the only wrinkle is that its join is *partial*, which §3.1 attacks. |
| **Deterministic execution instead of agreement** — agree on the *input order* once, then every replica computes the same output with no further coordination | Deterministic-database designs (an input-log sequencer + deterministic replay) | **Not new, and the closest relative.** The difference is stated below. |
| **Chain replication** — a write traverses a fixed replica chain; reads at the tail are linearizable | Chain replication for high-throughput storage | **Not new.** Not adopted: it constrains the *write* path, which C2 already owns. |
| **The log is the database** — durable ordered log as the source of truth, all views derived | Log-structured / event-sourcing architecture writing | **Not new, and already EHDB's model.** This spec is a refinement inside it. |
| **Version vectors / epoch ordering** | Replica-divergence detection literature | **Not new.** Deliberately *not* used — §2.2 explains why a per-execution chain needs no vector. |

### What is actually new, stated narrowly

Not a primitive — a **composition**, and one that only pays off under EHDB's
particular invariants:

> **Because the #362 invariant makes each execution's event set a single-rooted
> chain, the causal order is already total *within the partition that projections are
> folded over*. So the chain itself — not a sequencer, not a timestamp, not a version
> vector — can carry the proof that a projection is current. That collapses
> "re-fold to check" into "compare one digest", and it makes projection merge a join
> on a totally-ordered lattice, which CALM then certifies as coordination-free.**

The nearest relative is the deterministic-database family: agree on input order once,
replay deterministically everywhere. The differences are real but modest:

1. Those designs use a **global** input sequencer, and the agreement is the expensive
   part. EHDB needs none, because the order is *already* given per execution by the
   links — the partition boundary and the causal order coincide. That coincidence is
   the whole leverage, and it is a property of this data model, not a general result.
2. They replay to obtain state. Here, replay is the *fallback*; the common path
   **validates** a cached state in O(1) and never replays.

⚠ So the honest claim is: **a new-to-this-codebase mechanism, in a composition I have
not seen applied to an execution-partitioned event store, resting entirely on
old primitives.** No claim of a new algorithm in the research sense.

---

## 2. The algorithm

### 2.1 Three orders are currently conflated

| Order | What needs it | Source today |
| :-- | :-- | :-- |
| **Causal order** within one execution | The drive decision; every projection fold | `prev_event_id` links (#362) |
| **Storage order** within a shard | Part pruning, cursors, the claim path | `global_sequence`, gapless via single writer (C2) |
| **Cross-shard comparison** | Multi-shard reads, read freshness | HLC (planned) |

The hot path — decide whether an execution advances — needs only the **first**. It
currently pays for the second (a read against the writer's ordered store) and, in
multi-region, would pay a round trip to the writer's region. Separating them is the
entire proposal.

### 2.2 The chain certificate — a streaming digest, finalised per commit batch

**Revised 2026-09-30 after the §0 benchmark.** The original construction hashed once
per event and cost −17% throughput at the 512-event commit batch. This version pays
one cheap `update` per event and one `finalize` per *batch*, not per event.

Two changes, and the second is the one that matters for cost.

**(1) The digest attests ORDER AND MEMBERSHIP, not payload bytes.**

```
D_n = SHA256( DOMAIN_TAG || event_id_1 || event_id_2 || … || event_id_n )
```

8 bytes per event instead of a ~500-byte body — a ~60× reduction in the byte term.
The link structure is implied by the order the ids are fed, which is chain order by
construction.

⚠ **This narrows a guarantee and the narrowing is real.** The chain digest no longer
detects a corrupted event *body*; it detects reordering, omission, insertion and
substitution of events. Body integrity is a different concern already served by
`canonical_event_checksum` and the storage layer. §3.1 A6 is rewritten accordingly —
this is a deliberate separation of concerns, not an oversight, but anyone reading the
certificate as a body-integrity proof would be wrong.

**(2) One live hasher per in-flight execution; `finalize` only at the batch boundary.**

SHA-256 is a streaming hash. The writer keeps a live hasher per active execution and
feeds it one id per event — an `update` of 8 bytes, with no `finalize` and no
allocation. At the commit-batch boundary it clones the hasher and finalises the clone
for each execution touched in that batch, emitting

```
CERT = (execution_id, chain_len, D_n)      // 44 bytes
```

⭐ **The digest is a pure function of the event sequence, so it is completely
independent of how events were batched.** `D_n` depends only on `id_1 … id_n`; nesting
per-batch roots would have made it batching-dependent and therefore not reproducible by
a replica that batched differently. That property is load-bearing for §2.3 and is why
this shape was chosen over a per-batch Merkle rollup.

⚠ **A fixed-K window per execution was considered and discarded on the data.** Windows
of K events with a certificate at each boundary would amortise equally well — but the
measured corpus has **36–174 events per execution**, so with K = 512 *no window would
ever complete and no certificate would ever be issued*. Any K large enough to amortise
is larger than most executions. The streaming hasher has no such coupling: the
certificate advances every batch regardless of execution length.

**Cost model, stated as arithmetic rather than assertion.** Per 512-event commit batch,
with `x` distinct executions touched:

```
digest cost  ≈  x · (init + finalize)  +  512 · 8 bytes of update
             ≈  x · 2.2 µs             +  3.2 µs
```

against a measured 6.49 ms baseline batch. So:

| executions per batch | predicted overhead | vs ±2% gate |
| --: | --: | :-- |
| 1 | 0.08% | holds |
| 6 | 0.25% | holds |
| 32 | 1.14% | holds |
| **58** | **~2.0%** | **the boundary** |
| 64 | 2.22% | breaks |

⚠⚠ **So the overhead scales with concurrent executions per batch, not with events.**
That is the honest cost model, it is a different shape from the original claim, and it
has a stated breaking point of roughly **58 concurrent executions per commit batch**.
At 2,000 events per batch the same `x` amortises further (12.27 ms baseline), so the
boundary moves out to ~170. The fan-out workload in §4 exists to find this boundary
rather than trust the arithmetic.

⚠ Fields remain additive `Option<T>` + `skip_serializing_if` per C3. `sha2` is already a
workspace dependency, so still no new dependency.

⚠ **Hasher state is process-local and must be recoverable.** A restart loses every live
hasher. Recovery re-streams the execution's existing ids once — O(n) per execution, once
per restart, never per event. §3.1 A3 covers what happens if it is wrong.

### 2.3 What becomes coordination-free, and the CALM argument

Let `C_e` be the set of prefixes of execution `e`'s chain, ordered by
prefix-inclusion. Define

```
A ⊔ B  =  A                    if B is a prefix of A
       =  B                    if A is a prefix of B
       =  ⊥ (undefined)        otherwise
```

Prefix-ness is decided in O(1) by the digest: `B` is a prefix of `A` at length
`len(B)` **iff** `A`'s digest at that length equals `B`'s digest. (Storing one digest
per event makes that lookup local; storing only the head digest requires walking
back, which is the space/time knob in §4.)

**Claim.** Under the #362 single-root/no-fork invariant, `(C_e, ⊑)` is a **total**
order, `⊔` is total, and `⊔` is commutative, associative and idempotent — a
join-semilattice. Projection state is a deterministic function of a chain prefix, so
the induced merge on projections is monotone.

**Therefore, by CALM:** projection *replication*, *merge* and *read* admit a
consistent, coordination-free distributed implementation. No agreement, no round
trip, no lease is required for a replica to serve a projection it can verify.

That is the load-bearing step, and §3 tries to break it rather than moving on.

### 2.4 Exact guarantees

| Operation | Guarantee |
| :-- | :-- |
| Append (within a shard) | Ordering semantics unchanged: single-writer serialised, gapless `global_sequence`, durable on `fsync`. ⚠ **Not free** — one 8-byte `update` per event plus one `finalize` per execution per commit batch. Target ≤2% at the 512 batch; see §2.2's cost model and its ~58-execution boundary. |
| Certificate granularity | **Per commit batch**, not per event. A certificate attests the chain prefix as of the last batch in which that execution appeared. |
| Read staleness floor | **≤ one commit batch.** An event appended but not yet batch-committed is uncertified, so a verifying reader does not see it. ⚠ This is a *floor on freshness*, not on correctness — the reader is behind, never wrong. |
| Projection read at a replica | **Prefix-consistent and self-certifying.** The answer is the deterministic fold of a chain prefix whose digest the replica verified. It may be *stale* (a shorter prefix) but is never *wrong* — it is never a fold of a chain the writer did not produce. |
| Projection read with a required freshness | Prefix-consistent **and** `chain_len ≥ L` for a caller-supplied `L`, or an explicit refusal. Monotone read-your-writes for a caller that remembers its own last `CERT`. |
| Projection convergence between replicas | Eventually equal, coordination-free, by §2.3. |
| Validity check of a cached projection | **O(1)**, by digest comparison, replacing an O(n) refold. |
| Detection of a divergent/forged chain | Reordering, omission, insertion and substitution of **events** are caught at the first differing position; tamper-**evident**. ⚠ **Payload-body corruption is NOT caught** — the digest covers ids, not bodies (§2.2 change 1). Body integrity stays with `canonical_event_checksum` and the storage layer. |
| Linearizable cross-region write | ⛔ **Not provided.** Unchanged from today; see §3.2. |
| Multi-key / cross-execution atomicity | ⛔ Not provided. Out of scope. |

### 2.5 What genuinely still needs coordination

Being precise here is the point of the section:

1. **Enforcing one writer per execution.** Preventing two writers from appending
   different events after the same predecessor is *mutual exclusion*, and mutual
   exclusion is not monotone — no amount of hashing removes it. EHDB already pays
   this, once, via leaderful per-shard writing (C2). **The proposal does not remove
   this coordination; it stops re-paying it on every read.**
2. **Moving the writer** (lease handover, including across regions). Genuinely
   consensus-shaped; fork F2b; untouched.
3. **Cross-shard/global ordering**, if ever needed. HLC gives comparison, not
   agreement.

⭐ The shape of the win: coordination is paid **once at append** and **zero times**
at read, merge, project, or validate. Today it is effectively re-paid on each of
19,840 refolds.

---

## 3. Adversarial correctness argument

The §2.3 claim is the one worth attacking. Each attack below is an attempt to make a
replica serve a projection that is *wrong* rather than merely stale, or to make two
replicas diverge permanently.

### 3.1 Attacks on the coordination-free claim

**A1 — Two concurrent writers append after the same predecessor (a fork).**
This **breaks** the claim, and it is the honest failure mode. With a fork, neither
chain is a prefix of the other, `⊔` is undefined, the order is not total, and
monotonicity fails — exactly as CALM predicts for a non-monotone program.

What the design does about it: **detects it, never resolves it silently.** Two events
with the same `prev_event_id` produce different digests at the same `chain_len`, so
the conflict is caught at the first differing event by any replica, with no
coordination. #362 already reports this as `Fork`, and the response is refusal +
fall-through to the authoritative store.

⚠ **I considered and rejected deterministic fork resolution** (pick the branch with
the lower `event_id`). It would restore totality and make the lattice monotone again —
and it would **discard the losing branch's events**, which on an append-only log is
data loss. Rejected on that ground alone. An alternative — fold over the DAG in a
deterministic topological order, retaining both branches — preserves the events and
determinism but changes the projection's meaning (an execution would have a
non-linear history), so it is recorded as an open question, not adopted.

**So the guarantee is conditional, and the condition is named:** coordination-free
projection is available *exactly* when the single-root invariant holds. That
invariant is now measured continuously (`noetl_chain_root_invariant`), which is what
makes the condition observable rather than assumed.

**A2 — Network partition; two replicas serve different prefixes.**
Both are prefix-consistent; the shorter is stale. On heal, `⊔` takes the longer after
verifying the shorter is its prefix. No divergence, no coordination. Availability is
preserved for reads; a caller needing freshness supplies `L` and gets a refusal rather
than a wrong answer. ⚠ This is a deliberate AP choice for the *read* path: **stale but
never wrong**, never *unavailable-but-fresh*.

**A3 — Writer restarts mid-chain.**
This was a real defect (#362): a lost in-memory head map stamped the next event as a
second root. The certificate catches it independently — a new root restarts the digest
at `chain_len = 1`, which is not `> current_len`, so a replica rejects it as
non-monotone instead of accepting a truncated chain. ⭐ Two mechanisms, different failure
modes.

⚠ **But the streaming hasher adds its own restart exposure, which the per-event
construction did not have.** Hasher state is process-local. On restart the writer must
re-stream each live execution's existing ids to rebuild it. Three ways that goes wrong:

- **Rebuilt from the wrong prefix** — if recovery streams ids in a different order (for
  instance by sorting on `event_id`, the very mistake #362 exists to prevent), the
  rebuilt digest diverges and *every* subsequent certificate for that execution
  mismatches. Recovery MUST walk the links. Acceptance criterion in §6.
- **Not rebuilt at all** — a fresh hasher would silently produce a digest for a
  suffix while claiming the full `chain_len`. That is the one failure in this design
  that yields a *wrong* certificate rather than a stale one, so it must fail closed:
  no certificate is emitted for an execution whose hasher was not positively rebuilt.
- **Rebuild cost** — O(n) per live execution per restart. Bounded and rare, but it is a
  restart-time cost the per-event construction did not have. Measure it (§4).

**A4 — Events commit out of `event_id` order.**
The #362 mechanism: an event minted earlier commits later and lands in the middle of
an id-ordered read. **Unaffected — and checkable, not merely asserted** (the acceptance criteria include a
test that no `event_id` comparison occurs on this path; "by construction" is exactly the
phrasing that produced the falsified append claim in §0, so it is not used as evidence
here). The digest chain follows links,
and no step of §2.2 compares two `event_id`s. This is the case that motivated the
whole design.

**A5 — Replay / duplicate delivery.**
`⊔` is idempotent: re-merging a prefix already contained is a no-op. Duplicates are
already handled at the storage layer by `ON CONFLICT DO NOTHING`.

**A6 — A replica lies, or storage corrupts a record.**
A corrupted or substituted **event id**, or any reordering, is caught at the first
differing position. ⚠ **A corrupted event BODY is not** — the digest covers ids only
(§2.2). That is a narrower claim than the first version of this spec made, and the
narrowing is the price of the cost fix. Body integrity is delegated to
`canonical_event_checksum` and the storage layer; the certificate must never be
described as a body-integrity proof.
⚠ **Tamper-evident, not tamper-proof.** Without signatures a replica that recomputes the
whole chain from forged ids produces a self-consistent forgery. Acceptable inside one
trust domain; not Byzantine tolerance.

**A7 — Hash collision.** SHA-256; treated as negligible. The `DOMAIN_TAG` prevents
cross-protocol collisions, which is the realistic version of this risk.

**A8 — `canonical()` is not actually deterministic.**
⚠ **The sharpest practical risk, and it is not hypothetical.** The program has already
been bitten by two producers reducing timestamps differently (one rounding, one
truncating) so the same logical event digested differently. If `canonical()` drifts
between producers or versions, digests mismatch and every validation degrades to a
refold — a performance cliff, not a correctness bug, but it would silently erase the
entire benefit. **Acceptance criterion:** a cross-producer digest-equality test, run
in CI, with a deliberately-planted divergence as its control.

**A9 — The certificate is present but nothing verifies it.**
The failure mode this codebase produces most often: a mechanism that exists, is
deployed, is instrumented, and never fires (a hydration fix recorded `head=0` across
4,270 decisions). **Acceptance criterion:** a counter for validations *taken* and
refolds *avoided*, with a positive control proving the validation path can fail. A
zero on "refolds avoided" must be distinguishable from "the path never ran".

**A10 — Batch-boundary dependence (the trap this design was shaped to avoid).**
A per-batch Merkle rollup, nesting each batch's root into the chain, would make the
digest depend on *how events were batched*. A replica that batched the same event
sequence differently would compute a different digest, every validation would mismatch,
and the whole benefit would silently degrade to refolds. **The streaming construction is
immune**: `D_n = SHA256(TAG || id_1 || … || id_n)` is a pure function of the sequence.
⚠ Acceptance criterion: a test that certifies the same 512-event sequence under two
*different* batch splits and asserts byte-identical digests, with a nested-rollup arm as
the planted control proving the test can fail.

**A11 — `chain_len` and `durable_len` are independent, and conflating them is a bug.**
The certificate boundary is the *commit batch*; durability is the `fsync`. They are
related in practice but they are not the same quantity, and I nearly wrote that they
were. A reader that needs both properties must take `min(certified_len, durable_len)`.
⚠ A certificate is **not** a durability receipt and must not be used as one.

**A12 — Uncertified tail read as absent.**
Events appended after the last batch boundary carry no certificate. A verifying reader
does not see them, which is correct (stale, not wrong) — but a caller that treats "not in
the certified prefix" as "does not exist" would be wrong, e.g. deciding an execution is
finished. The certified prefix answers *what is proven*, never *what exists*. ⚠ The
existing refusal path is the correct response for a caller needing the true head.

### 3.2 Lower bounds this does not beat

Stated so the "faster" claim is scoped rather than impressive.

| Bound | Consequence | Honest position |
| :-- | :-- | :-- |
| **CAP / PACELC** | A linearizable cross-region write costs at least one cross-region round trip; under partition you choose consistency or availability. | **Not beaten.** Writes stay zone-local; the read path deliberately chooses staleness over unavailability. |
| **FLP** | No deterministic consensus in an asynchronous system with one faulty process. | **Not beaten — avoided.** Storage needs no consensus (C1). Lease *movement* still does, and stays open as F2b. |
| **Mutual exclusion is not monotone** | Preventing forks cannot be coordination-free. | **Not beaten.** Paid once at append, per C2. |
| **Ω(n) to fold n events from empty** | A digest makes *validation* O(1), not *folding* sublinear. | **Not beaten.** Amortised by incremental folds from a checkpoint: O(Δ) for Δ new events. |
| **Durability needs a device flush** | No algorithm removes the `fsync`. | **Not beaten.** |
| **A hash must read every byte it commits to** | Digesting n events costs Ω(total bytes); batching removes per-invocation overhead, never the byte term. | **Not beaten — reduced.** Measured: ~2.2 µs of the 2.59 µs per event was per-invocation, ~0.4 µs bytes. §2.2 removes the former (one `finalize` per batch) and shrinks the latter ~60× (ids, not bodies). The residue is irreducible. |
| **Group commit amortises the flush, so everything else stops being free** | The larger the batch, the more any per-event cost dominates. | **Not beaten — it is the whole problem.** Break-even was ~17 events/`fsync`; EHDB batches 512–2,000, which is why the first design failed. |
| **Speed of light** | Cross-region RTT is ~30–80 ms intra-continent. | **Not beaten.** Made *irrelevant to reads* by serving locally; writes still pay it if they ever cross. |

⚠ **Therefore the claim is NOT "EHDB gets faster".** It is: *the projection and
decision path stops paying a cost it did not need to pay, and that path is measured to
be hot.*

---

## 4. Benchmark plan

⚠ Runs in the implementation repositories, not here. This spec defines what must be
measured and what would falsify it.

### Baseline

Current path at `server@main` + `ehdb@v0.4.5`: projections validated by refold
(`ReFoldVerdict`), drive decision reading the chain per poll, projections re-derived
per region.

### Workloads

1. **Recorded corpus** — the measured linked-era set: 63 executions / 2,327 events,
   36–174 events per execution, one root each. The realistic shape.
2. **Long chain** — a single execution grown to 10⁴ events, to separate O(1)
   validation from O(n) folding.
3. **Fan-out** — 6 concurrent executions × 400 events, the shape that produced the
   `dangling_prev` transients.
4. **Restart mid-emit** — the forced-restart harness, asserting the certificate
   catches a second root independently of the hydrator (A3).
5. **Simulated cross-region read** — an injected 60 ms RTT replica, comparing a local
   verified read against a round trip.

### Metrics

| Metric | Baseline | Expectation | Falsifies the design if |
| :-- | :-- | :-- | :-- |
| **Refolds per 10⁴ events** | 19,840 observed over the D3 window | → ~0 | Refolds persist: `canonical()` is not deterministic (A8) or validation is not wired (A9). |
| **Projection validation p50/p99** | O(n) refold | O(1), sub-ms, flat in chain length | p99 grows with chain length. |
| **Drive-decision p50/p99** | includes a chain read per poll | local, no store read | No improvement ⇒ the read was not the cost; abandon. |
| **Append throughput at 512/fsync** | **78,920/s measured**; per-event digest gave 65,533/s (−16.96%) | **within ±2%** via §2.2 | >2% at ≤32 executions/batch ⇒ the amortisation does not work; abandon or move the digest fully off-line. |
| **Append throughput at 2,000/fsync** | **163,017/s measured**; per-event gave 106,046/s (−34.95%) | within ±2% | as above. |
| **Overhead vs executions-per-batch** | not previously measured | linear in `x`, crossing 2% near **x ≈ 58** at 512/batch | The curve is not linear in `x`, or crosses far below 58 ⇒ the cost model in §2.2 is wrong and the prediction is void. |
| **Cost decomposition: invocation vs bytes** | derived as ~2.2 µs / ~0.4 µs | confirm the split directly | If bytes dominate after all, one `finalize` per batch buys little and only the id-not-body change matters. **Measure this before trusting the rest.** |
| **Hasher rebuild cost per restart** | n/a (new) | O(n) per live execution, once | Rebuild dominates restart, or recovery walks ids in the wrong order (A3). |
| **Cross-region projection read p50/p99** | ≈1 RTT | ≈local read | — |
| **Cross-region commit latency** | ≈1 RTT | **unchanged, explicitly** | Any claim of improvement here is an error in the experiment. |
| **Bytes/event overhead** | — | +36 B body (`[u8;32]` + `u32`) | >1% of mean event size matters for the manifest-growth history. |
| **Storage for per-event digests** | — | quantify vs head-only | If per-event digests cost too much, head-only + walk-back is the fallback; measure both. |

### Gate

- Append throughput within **±2% at the 512-event batch** at realistic concurrency
  (≤32 executions per batch), **and** the measured overhead-vs-`x` curve published with
  its crossing point — a single passing number is not enough, because the first version
  of this spec passed at 1 event/`fsync` and failed by 17× at 512;
- refolds per 10⁴ events reduced by **≥90%** (already measured at 99.80% — this is a
  no-regression check now, not an open question);
- validation p99 flat in chain length over workload 2 (already measured at ratio 1.00×
  over a 277× range — likewise);
- the A8, A9 and **A10** controls all **fail** when their defect is planted;
- hasher-rebuild-on-restart proven to walk **links**, not sorted ids (A3).

⚠ Reported with the **elapsed window** alongside every denominator. A previous
comparator reading of "772 comparisons, 100.00%" was taken over ten minutes against a
~1/hour phenomenon and did not hold; volume is not duration.

---

## 5. Honest verdict on "faster"

**There is no asymptotic win, and no win at all on the append path.**

What there is:

1. **A complexity reduction on validation: O(n) → O(1).** Real, and the largest
   effect, because validation is on the hot path and refolds were measured in the
   tens of thousands.
2. **Coordination elimination on the read/merge path**, argued via CALM and
   conditional on an invariant that is now continuously measured. Coordination is paid
   once at append instead of repeatedly at read.
3. **A cross-region read that is local rather than a round trip** — a large constant
   factor (tens of ms), and the practical payoff for multi-region reads.
4. **Writes: a measured cost, not a free ride.** ⚠ The claim that appends were
   "unchanged **by construction**" was **wrong and the benchmark proved it** — −16.96% at
   the 512-event commit batch, −34.95% at 2,000. "By construction" was the tell: it
   asserted a property of an implementation nobody had run.

   The revised construction (§2.2) targets ≤2% by paying one `finalize` per commit batch
   instead of per event, and by digesting ids rather than bodies. **That is a prediction
   with arithmetic behind it and a stated breaking point (~58 executions per batch), not
   a guarantee.** It is falsified by the §4 curve, and the honest posture until that runs
   is: the read-side win is measured, the write-side cost is bounded by design and
   unproven by measurement.

   Cross-region **commit** latency remains unchanged — that one really is structural,
   since nothing here touches the commit path.

If the benchmark shows the drive decision was not dominated by the chain read, the
correct conclusion is that this buys only the refold reduction, and the cross-region
read benefit remains contingent on multi-region actually shipping. **That would still
be worth landing for (1) alone, but it must not be described as making EHDB faster.**

## Acceptance Criteria

- [ ] `chain_digest` / `chain_len` added as additive `Option<T>` body fields; every
      existing segment still readable (C3 compat test).
- [ ] Rolling-digest construction with a domain tag; property test that link order
      and digest order agree, and that no `event_id` comparison occurs.
- [ ] Prefix-check in O(1) via digest; RED control proving a forged prefix is rejected.
- [ ] Cross-producer `canonical()` digest-equality test with a planted-divergence
      control (A8).
- [ ] Counters for validations taken / refolds avoided, pinned at 0, with a positive
      control proving the path can fail (A9).
- [ ] Certificate independently rejects a post-restart second root (A3), proven with
      the forced-restart harness, with the hydrator disabled so the two mechanisms are
      shown to be independent.
- [ ] Fork is refused, never silently resolved; existing #362 refusal taxonomy reused.
- [ ] **Batch-split invariance (A10):** the same 512-event sequence certified under two
      different batch splits yields byte-identical digests, with a nested-per-batch-rollup
      arm as the planted control proving the test can fail.
- [ ] **Hasher rebuild after restart (A3)** walks `prev_event_id` links, not sorted
      `event_id`; RED control planting a sort-based rebuild must fail. No certificate is
      emitted for an execution whose hasher was not positively rebuilt.
- [ ] `certified_len` is never used as a durability receipt (A11); a reader needing both
      takes `min(certified_len, durable_len)`.
- [ ] Append overhead measured **as a curve against executions-per-batch**, published
      with its 2% crossing point — not a single number.
- [ ] Benchmark gate in §4 met, reported with elapsed window and denominators.

## Open Questions

- ~~**Per-event digests vs head-only.**~~ **Settled by the benchmark, against
  per-event.** Per-event hashing costs −17% at the 512 batch and the floor arm proved the
  cost is SHA-256 itself, not duplicate serialisation. §2.2 now keeps a per-execution
  *streaming* hasher and finalises per batch — neither of the two options originally
  posed.
- **Does the per-execution hasher's memory cost bound concurrency?** ~120 B of state per
  in-flight execution is trivial per execution, but it is per *live* execution and the
  writer holds them all. Quantify at the fan-out ceiling.
- **DAG folding for forked executions.** Retains all events and stays deterministic,
  but changes what an execution's history *means*. Needs its own decision; not adopted.
- **Interaction with HLC.** The certificate orders *within* an execution; HLC compares
  *across*. They should not be conflated — does any consumer need a single order over
  both?
- **Does the drive decision actually dominate?** §4 workload 3 answers it. If not,
  scope collapses to the refold win, and the spec should say so rather than be
  defended.

## Related

- `docs/rfc/ehdb-execution-partitioned-event-store.md` — the partitioning this rests on.
- `specs/active/2026-09-11-ehdb-resilient-core/spec.md` — the layer map and C1.
- `loops/active/2026-09-11-ehdb-resilient-core-phases/handover/MULTIREGION-EHDB-PLAN.md`
  — C1/C2/C3, the read/write asymmetry, and fork F2b.
- `agents/rules/self-sufficiency.md` — why no external store appears here.
- `agents/rules/representation-drift.md` — "print the denominator", and volume is not
  duration.
