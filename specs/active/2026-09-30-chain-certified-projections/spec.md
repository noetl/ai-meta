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

## Goals

- Answer "is this projection valid for this chain?" in O(1) rather than O(n) refold.
- Make projection convergence between replicas coordination-free, with a proof
  obligation discharged in §3 rather than asserted.
- Remove the per-poll chain read from the drive-decision path.
- Make a cross-region projection read local.
- Change **nothing** about the leaderful per-shard append path.

## Non-Goals

- Faster appends. The append path is single-writer + `fsync`; this touches neither.
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

### 2.2 The chain certificate

Add to each event's record body (C3-compliant: `Option<T>` +
`skip_serializing_if`):

```
chain_digest: Option<[u8; 32]>     // rolling SHA-256
chain_len:    Option<u32>          // 1 for the root
```

with

```
chain_digest(root)  = H( DOMAIN_TAG || canonical(event_root) )
chain_digest(n)     = H( DOMAIN_TAG || chain_digest(n-1) || canonical(event_n) )
```

`canonical(...)` is the existing deterministic serialisation (sorted keys, compact
separators) already used by `canonical_event_checksum`. `DOMAIN_TAG` is a fixed
constant so a digest from this construction can never collide with a digest from
another use of the same hash.

A **chain certificate** is then the triple

```
CERT = (execution_id, chain_len, chain_digest)
```

— 44 bytes, self-verifying, and monotone in `chain_len`.

⚠ **Why no version vector.** A vector exists to summarise *concurrent* histories per
replica. Under the #362 invariant an execution has exactly one root and no forks, so
its history is a single sequence and `chain_len` is a complete summary. If the
invariant is violated the vector would not save us either — §3.1 covers that case
explicitly.

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
| Append (within a shard) | Unchanged: single-writer serialised, gapless `global_sequence`, durable on `fsync`. |
| Projection read at a replica | **Prefix-consistent and self-certifying.** The answer is the deterministic fold of a chain prefix whose digest the replica verified. It may be *stale* (a shorter prefix) but is never *wrong* — it is never a fold of a chain the writer did not produce. |
| Projection read with a required freshness | Prefix-consistent **and** `chain_len ≥ L` for a caller-supplied `L`, or an explicit refusal. Monotone read-your-writes for a caller that remembers its own last `CERT`. |
| Projection convergence between replicas | Eventually equal, coordination-free, by §2.3. |
| Validity check of a cached projection | **O(1)**, by digest comparison, replacing an O(n) refold. |
| Detection of a divergent/forged chain | Any mismatch is caught at the first differing event; tamper-**evident**. |
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
second root. Under this design the restart is *also* caught by the certificate — a new
root has `chain_len = 1`, which is not `> current_len`, so a replica rejects it as
non-monotone instead of accepting a truncated chain. ⭐ **The certificate is a second,
independent check on the invariant the hydrator enforces.** Two mechanisms, different
failure modes.

**A4 — Events commit out of `event_id` order.**
The #362 mechanism: an event minted earlier commits later and lands in the middle of
an id-ordered read. **Unaffected by construction** — the digest chain follows links,
and no step of §2.2 compares two `event_id`s. This is the case that motivated the
whole design.

**A5 — Replay / duplicate delivery.**
`⊔` is idempotent: re-merging a prefix already contained is a no-op. Duplicates are
already handled at the storage layer by `ON CONFLICT DO NOTHING`.

**A6 — A replica lies, or storage corrupts a record.**
Caught at the first differing event, because the digest commits to every predecessor.
⚠ **Tamper-evident, not tamper-proof.** Without signatures, a replica that recomputes
the whole chain from forged events produces a self-consistent forgery. That is
acceptable inside one trust domain and must not be described as Byzantine tolerance.

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

### 3.2 Lower bounds this does not beat

Stated so the "faster" claim is scoped rather than impressive.

| Bound | Consequence | Honest position |
| :-- | :-- | :-- |
| **CAP / PACELC** | A linearizable cross-region write costs at least one cross-region round trip; under partition you choose consistency or availability. | **Not beaten.** Writes stay zone-local; the read path deliberately chooses staleness over unavailability. |
| **FLP** | No deterministic consensus in an asynchronous system with one faulty process. | **Not beaten — avoided.** Storage needs no consensus (C1). Lease *movement* still does, and stays open as F2b. |
| **Mutual exclusion is not monotone** | Preventing forks cannot be coordination-free. | **Not beaten.** Paid once at append, per C2. |
| **Ω(n) to fold n events from empty** | A digest makes *validation* O(1), not *folding* sublinear. | **Not beaten.** Amortised by incremental folds from a checkpoint: O(Δ) for Δ new events. |
| **Durability needs a device flush** | No algorithm removes the `fsync`. | **Not beaten.** Append latency is untouched. |
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
| **Append throughput (events/s/shard)** | — | **unchanged, ±2%** | A regression >2%: digest cost is on the hot path; move it off. |
| **Append p99** | — | **unchanged** | Any increase. |
| **Cross-region projection read p50/p99** | ≈1 RTT | ≈local read | — |
| **Cross-region commit latency** | ≈1 RTT | **unchanged, explicitly** | Any claim of improvement here is an error in the experiment. |
| **Bytes/event overhead** | — | +36 B body (`[u8;32]` + `u32`) | >1% of mean event size matters for the manifest-growth history. |
| **Storage for per-event digests** | — | quantify vs head-only | If per-event digests cost too much, head-only + walk-back is the fallback; measure both. |

### Gate

- Append throughput and p99 **not worse** (±2%), and
- refolds per 10⁴ events reduced by **≥90%**, and
- validation p99 flat in chain length over workload 2, and
- A8 and A9 controls both **fail** when their defect is planted.

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
4. **Nothing for writes.** Append latency, append throughput and cross-region commit
   latency are all unchanged by construction. Any benchmark claiming otherwise is
   measuring wrong.

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
- [ ] Benchmark gate in §4 met, reported with elapsed window and denominators.

## Open Questions

- **Per-event digests vs head-only.** Per-event gives O(1) prefix checks at a storage
  cost; head-only needs a walk-back. Decide by measurement (§4), not by preference.
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
